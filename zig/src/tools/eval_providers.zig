//! eval-providers — offline provider eval runner.
//!
//! Reads JSONL provider ops from stdin, runs deterministic Ollama Phase 1
//! helpers, writes canonical-comparable JSONL to stdout.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const ollama = zeroclaw.providers.ollama;
const ollama_types = ollama.types;
const dispatcher = zeroclaw.runtime.agent.dispatcher;
const parser_types = @import("../tool_call_parser/types.zig");

const EvalError = error{InvalidScenario};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.io.getStdIn().readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(input);

    const stdout = std.io.getStdOut().writer();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        try runOp(allocator, line, stdout);
    }
}

fn runOp(allocator: std.mem.Allocator, line: []const u8, writer: anytype) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const op = getString(parsed.value, "op") orelse return EvalError.InvalidScenario;

    if (std.mem.eql(u8, op, "normalize_base_url")) {
        const raw_url = getString(parsed.value, "raw_url") orelse return EvalError.InvalidScenario;
        const result = try ollama.normalizeBaseUrl(allocator, raw_url);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, op, "strip_think_tags")) {
        const text = getString(parsed.value, "text") orelse return EvalError.InvalidScenario;
        const result = try ollama.stripThinkTags(allocator, text);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, op, "effective_content")) {
        const content = getString(parsed.value, "content") orelse return EvalError.InvalidScenario;
        const thinking = getOptionalString(parsed.value, "thinking");
        const result = try ollama.effectiveContent(allocator, content, thinking);
        defer if (result) |value| allocator.free(value);
        try writer.writeAll("{\"op\":\"effective_content\",\"result\":");
        if (result) |value| {
            try std.json.stringify(value, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, op, "build_chat_request")) {
        try runBuildChatRequest(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, op, "parse_chat_response")) {
        const body = getString(parsed.value, "body") orelse return EvalError.InvalidScenario;
        var result = try ollama.parseChatResponseBody(allocator, body);
        defer result.deinit(allocator);
        try writer.writeAll("{\"op\":\"parse_chat_response\",\"result\":");
        try writeChatResponse(writer, result);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, op, "format_tool_calls_for_loop")) {
        const calls = try toolCallsFromOp(allocator, parsed.value);
        defer freeOllamaToolCalls(allocator, calls);
        const result = try ollama.formatToolCallsForLoop(allocator, calls);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else {
        return EvalError.InvalidScenario;
    }
}

fn runBuildChatRequest(allocator: std.mem.Allocator, op_value: std.json.Value, writer: anytype) !void {
    const model = getString(op_value, "model") orelse return EvalError.InvalidScenario;
    const system = getOptionalString(op_value, "system");
    const message = getString(op_value, "message") orelse return EvalError.InvalidScenario;
    const temperature = getF64(op_value, "temperature") orelse return EvalError.InvalidScenario;
    const think = getOptionalBool(op_value, "think");

    const tools = if (getField(op_value, "tools")) |tools_value| blk: {
        if (tools_value == .null) break :blk null;
        if (tools_value != .array) return EvalError.InvalidScenario;
        break :blk tools_value.array.items;
    } else null;

    var messages = std.ArrayList(ollama_types.Message).init(allocator);
    errdefer {
        for (messages.items) |*entry| entry.deinit(allocator);
        messages.deinit();
    }
    if (system) |sys| try messages.append(try ollama_types.Message.init(allocator, "system", sys));
    try messages.append(try ollama_types.Message.init(allocator, "user", message));

    var provider = try ollama.OllamaProvider.new(allocator, null, null);
    defer provider.deinit(allocator);

    var request = try provider.buildChatRequestWithThink(
        allocator,
        try messages.toOwnedSlice(),
        model,
        temperature,
        tools,
        think,
    );
    defer request.deinit(allocator);
    messages = std.ArrayList(ollama_types.Message).init(allocator);

    try writer.writeAll("{\"op\":\"build_chat_request\",\"result\":");
    try ollama.client.writeChatRequestJson(allocator, request, writer);
    try writer.writeAll("}\n");
}

fn toolCallsFromOp(allocator: std.mem.Allocator, op_value: std.json.Value) ![]ollama_types.OllamaToolCall {
    const calls_value = getField(op_value, "tool_calls") orelse return EvalError.InvalidScenario;
    if (calls_value != .array) return EvalError.InvalidScenario;

    var calls = std.ArrayList(ollama_types.OllamaToolCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }

    for (calls_value.array.items) |entry| {
        if (entry != .object) return EvalError.InvalidScenario;
        const name = getStringValue(entry, "name") orelse return EvalError.InvalidScenario;
        {
            var arguments = if (getField(entry, "arguments")) |value|
                try parser_types.cloneJsonValue(allocator, value)
            else
                parser_types.emptyObject(allocator);
            errdefer parser_types.freeJsonValue(allocator, &arguments);
            const id = if (getField(entry, "id")) |id_value| blk: {
                if (id_value == .string) break :blk try allocator.dupe(u8, id_value.string);
                break :blk null;
            } else null;
            errdefer if (id) |owned_id| allocator.free(owned_id);
            const name_owned = try allocator.dupe(u8, name);
            errdefer allocator.free(name_owned);
            try calls.append(.{
                .id = id,
                .function = .{
                    .name = name_owned,
                    .arguments = arguments,
                },
            });
        }
    }

    return calls.toOwnedSlice();
}

fn freeOllamaToolCalls(allocator: std.mem.Allocator, calls: []ollama_types.OllamaToolCall) void {
    for (calls) |*call| call.deinit(allocator);
    allocator.free(calls);
}

fn writeStringResult(writer: anytype, op: []const u8, result: []const u8) !void {
    try writer.writeAll("{\"op\":");
    try std.json.stringify(op, .{}, writer);
    try writer.writeAll(",\"result\":");
    try std.json.stringify(result, .{}, writer);
    try writer.writeAll("}\n");
}

fn writeChatResponse(writer: anytype, response: dispatcher.ChatResponse) !void {
    try writer.writeAll("{\"text\":");
    if (response.text) |text| {
        try std.json.stringify(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"tool_calls\":[");
    for (response.tool_calls, 0..) |call, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try std.json.stringify(call.id, .{}, writer);
        try writer.writeAll(",\"name\":");
        try std.json.stringify(call.name, .{}, writer);
        try writer.writeAll(",\"arguments\":");
        try std.json.stringify(call.arguments, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"usage\":");
    if (response.usage) |usage| {
        try writer.writeAll("{\"input_tokens\":");
        try writeOptionalU64(writer, usage.input_tokens);
        try writer.writeAll(",\"output_tokens\":");
        try writeOptionalU64(writer, usage.output_tokens);
        try writer.writeAll(",\"cached_input_tokens\":");
        try writeOptionalU64(writer, usage.cached_input_tokens);
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"reasoning_content\":");
    if (response.reasoning_content) |reasoning| {
        try std.json.stringify(reasoning, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn writeOptionalU64(writer: anytype, value: ?u64) !void {
    if (value) |inner| {
        try writer.print("{d}", .{inner});
    } else {
        try writer.writeAll("null");
    }
}

fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    return getStringValue(value, key);
}

fn getStringValue(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn getOptionalString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .null => null,
        .string => |inner| inner,
        else => null,
    };
}

fn getOptionalBool(value: std.json.Value, key: []const u8) ?bool {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .null => null,
        .bool => |inner| inner,
        else => null,
    };
}

fn getF64(value: std.json.Value, key: []const u8) ?f64 {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .float => |inner| inner,
        .integer => |inner| @floatFromInt(inner),
        .number_string => |raw| std.fmt.parseFloat(f64, raw) catch null,
        else => null,
    };
}
