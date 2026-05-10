//! eval-provider-types — offline provider DTO / formatter parity runner.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const provider = zeroclaw.providers.provider;

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
    if (std.mem.eql(u8, op, "build_tool_instructions_text")) {
        const tools = try toolSpecsFromValue(allocator, parsed.value);
        defer if (tools.len != 0) allocator.free(tools);

        const instructions = try provider.buildToolInstructionsText(allocator, tools);
        defer allocator.free(instructions);

        try writer.writeAll("{\"op\":\"build_tool_instructions_text\",\"result\":{\"instructions\":");
        try std.json.stringify(instructions, .{}, writer);
        try writer.writeAll("}}\n");
    } else if (std.mem.eql(u8, op, "serialize_tool_call")) {
        const call = try toolCallFromValue(parsed.value);
        try writer.writeAll("{\"op\":\"serialize_tool_call\",\"result\":");
        try writeToolCall(writer, call);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, op, "serialize_chat_response")) {
        try runSerializeChatResponse(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, op, "serialize_conversation_message")) {
        try runSerializeConversationMessage(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, op, "stream_shapes")) {
        try runStreamShapes(parsed.value, writer);
    } else if (std.mem.eql(u8, op, "tools_payload")) {
        try runToolsPayload(parsed.value, writer);
    } else {
        return EvalError.InvalidScenario;
    }
}

fn runSerializeChatResponse(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    writer: anytype,
) !void {
    const response_value = getField(value, "response") orelse return EvalError.InvalidScenario;
    if (response_value != .object) return EvalError.InvalidScenario;

    var calls = std.ArrayList(provider.ToolCall).init(allocator);
    defer calls.deinit();
    if (getField(response_value, "tool_calls")) |tool_calls_value| {
        if (tool_calls_value != .array) return EvalError.InvalidScenario;
        for (tool_calls_value.array.items) |item| {
            try calls.append(try toolCallFromValue(item));
        }
    }

    const response = provider.ChatResponse{
        .text = getOptionalString(response_value, "text"),
        .tool_calls = calls.items,
        .usage = tokenUsageFromValue(response_value),
        .reasoning_content = getOptionalString(response_value, "reasoning_content"),
    };

    try writer.writeAll("{\"op\":\"serialize_chat_response\",\"result\":{\"has_tool_calls\":");
    try writer.writeAll(if (response.hasToolCalls()) "true" else "false");
    try writer.writeAll(",\"text_or_empty\":");
    try std.json.stringify(response.textOrEmpty(), .{}, writer);
    try writer.writeAll(",\"value\":");
    try writeChatResponse(writer, response);
    try writer.writeAll("}}\n");
}

fn runSerializeConversationMessage(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    writer: anytype,
) !void {
    const message_value = getField(value, "message") orelse return EvalError.InvalidScenario;
    if (message_value != .object) return EvalError.InvalidScenario;
    const kind = getString(message_value, "type") orelse return EvalError.InvalidScenario;
    const data = getField(message_value, "data") orelse return EvalError.InvalidScenario;

    if (std.mem.eql(u8, kind, "Chat")) {
        if (data != .object) return EvalError.InvalidScenario;
        const msg = provider.ConversationMessage{ .chat = .{
            .role = getString(data, "role") orelse return EvalError.InvalidScenario,
            .content = getString(data, "content") orelse return EvalError.InvalidScenario,
        } };
        try writeConversationResult(writer, msg);
    } else if (std.mem.eql(u8, kind, "AssistantToolCalls")) {
        if (data != .object) return EvalError.InvalidScenario;
        var calls = std.ArrayList(provider.ToolCall).init(allocator);
        defer calls.deinit();
        const tool_calls_value = getArray(data, "tool_calls") orelse return EvalError.InvalidScenario;
        for (tool_calls_value.items) |item| {
            try calls.append(try toolCallFromValue(item));
        }
        const msg = provider.ConversationMessage{ .assistant_tool_calls = .{
            .text = getOptionalString(data, "text"),
            .tool_calls = calls.items,
            .reasoning_content = getOptionalString(data, "reasoning_content"),
        } };
        try writeConversationResult(writer, msg);
    } else if (std.mem.eql(u8, kind, "ToolResults")) {
        if (data != .array) return EvalError.InvalidScenario;
        var results = std.ArrayList(provider.ToolResultMessage).init(allocator);
        defer results.deinit();
        for (data.array.items) |item| {
            if (item != .object) return EvalError.InvalidScenario;
            try results.append(.{
                .tool_call_id = getString(item, "tool_call_id") orelse return EvalError.InvalidScenario,
                .content = getString(item, "content") orelse return EvalError.InvalidScenario,
            });
        }
        const msg = provider.ConversationMessage{ .tool_results = results.items };
        try writeConversationResult(writer, msg);
    } else {
        return EvalError.InvalidScenario;
    }
}

fn runStreamShapes(value: std.json.Value, writer: anytype) !void {
    const delta_text = getString(value, "delta") orelse "hello stream";
    const reasoning_text = getString(value, "reasoning") orelse "thinking";
    const error_text = getString(value, "error") orelse "provider failed";
    const enabled = getBool(value, "enabled") orelse true;

    const delta = provider.StreamChunk.initDelta(delta_text).withTokenEstimate();
    const reasoning = provider.StreamChunk.initReasoning(reasoning_text);
    const final_chunk = provider.StreamChunk.finalChunk();
    const error_chunk = provider.StreamChunk.initError(error_text);
    const options = provider.StreamOptions.init(enabled).withTokenCount();
    const default_options = provider.StreamOptions{};
    const capability_error = provider.ProviderCapabilityError{
        .provider = "ollama",
        .capability = "vision",
        .message = "not available",
    };
    const caps = provider.ProviderCapabilities{
        .native_tool_calling = true,
        .vision = true,
        .prompt_caching = false,
    };

    try writer.writeAll("{\"op\":\"stream_shapes\",\"result\":{\"capabilities\":");
    try writeProviderCapabilities(writer, caps);
    try writer.writeAll(",\"chunks\":{\"delta\":");
    try writeStreamChunk(writer, delta);
    try writer.writeAll(",\"reasoning\":");
    try writeStreamChunk(writer, reasoning);
    try writer.writeAll(",\"final\":");
    try writeStreamChunk(writer, final_chunk);
    try writer.writeAll(",\"error\":");
    try writeStreamChunk(writer, error_chunk);
    try writer.writeAll("},\"events\":{\"from_delta\":");
    try writeStreamEvent(writer, provider.StreamEvent.fromChunk(delta));
    try writer.writeAll(",\"from_final\":");
    try writeStreamEvent(writer, provider.StreamEvent.fromChunk(final_chunk));
    try writer.writeAll(",\"pre_executed_tool_call\":");
    try writeStreamEvent(writer, .{ .pre_executed_tool_call = .{ .name = "shell", .args = "{\"cmd\":\"pwd\"}" } });
    try writer.writeAll(",\"pre_executed_tool_result\":");
    try writeStreamEvent(writer, .{ .pre_executed_tool_result = .{ .name = "shell", .output = "ok" } });
    try writer.writeAll(",\"tool_call\":");
    try writeStreamEvent(writer, .{ .tool_call = .{ .id = "tc1", .name = "lookup", .arguments = "{\"q\":\"zig\"}" } });
    try writer.writeAll("},\"options\":{\"default\":");
    try writeStreamOptions(writer, default_options);
    try writer.writeAll(",\"custom\":");
    try writeStreamOptions(writer, options);
    try writer.writeAll("},\"provider_capability_error\":");
    try writeProviderCapabilityError(writer, capability_error);
    try writer.writeAll(",\"stream_error_tags\":[\"Http\",\"Json\",\"InvalidSse\",\"Provider\",\"Io\"]}}\n");
}

fn runToolsPayload(value: std.json.Value, writer: anytype) !void {
    const payload_value = getField(value, "payload") orelse return EvalError.InvalidScenario;
    if (payload_value != .object) return EvalError.InvalidScenario;
    const kind = getString(payload_value, "type") orelse return EvalError.InvalidScenario;
    const data = getField(payload_value, "data") orelse return EvalError.InvalidScenario;

    const payload: provider.ToolsPayload = if (std.mem.eql(u8, kind, "Gemini")) blk: {
        const items = getArray(data, "function_declarations") orelse return EvalError.InvalidScenario;
        break :blk .{ .gemini = .{ .function_declarations = items.items } };
    } else if (std.mem.eql(u8, kind, "Anthropic")) blk: {
        const items = getArray(data, "tools") orelse return EvalError.InvalidScenario;
        break :blk .{ .anthropic = .{ .tools = items.items } };
    } else if (std.mem.eql(u8, kind, "OpenAI")) blk: {
        const items = getArray(data, "tools") orelse return EvalError.InvalidScenario;
        break :blk .{ .openai = .{ .tools = items.items } };
    } else if (std.mem.eql(u8, kind, "PromptGuided")) blk: {
        break :blk .{ .prompt_guided = .{ .instructions = getString(data, "instructions") orelse return EvalError.InvalidScenario } };
    } else return EvalError.InvalidScenario;

    try writer.writeAll("{\"op\":\"tools_payload\",\"result\":");
    try writeToolsPayload(writer, payload);
    try writer.writeAll("}\n");
}

fn writeConversationResult(writer: anytype, msg: provider.ConversationMessage) !void {
    try writer.writeAll("{\"op\":\"serialize_conversation_message\",\"result\":");
    try writeConversationMessage(writer, msg);
    try writer.writeAll("}\n");
}

fn toolSpecsFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]provider.ToolSpec {
    const tools_value = getArray(value, "tools") orelse return &.{};
    if (tools_value.items.len == 0) return &.{};

    const tools = try allocator.alloc(provider.ToolSpec, tools_value.items.len);
    errdefer allocator.free(tools);
    for (tools_value.items, 0..) |item, i| {
        if (item != .object) return EvalError.InvalidScenario;
        const name = getField(item, "name") orelse return EvalError.InvalidScenario;
        const description = getField(item, "description") orelse return EvalError.InvalidScenario;
        const parameters = getField(item, "parameters") orelse return EvalError.InvalidScenario;
        if (name != .string or description != .string) return EvalError.InvalidScenario;
        tools[i] = .{
            .name = name.string,
            .description = description.string,
            .parameters = parameters,
        };
    }
    return tools;
}

fn tokenUsageFromValue(value: std.json.Value) ?provider.TokenUsage {
    const usage = getField(value, "usage") orelse return null;
    if (usage == .null) return null;
    if (usage != .object) return null;
    return .{
        .input_tokens = getOptionalU64(usage, "input_tokens"),
        .output_tokens = getOptionalU64(usage, "output_tokens"),
        .cached_input_tokens = getOptionalU64(usage, "cached_input_tokens"),
    };
}

fn toolCallFromValue(value: std.json.Value) !provider.ToolCall {
    if (value != .object) return EvalError.InvalidScenario;
    return .{
        .id = getString(value, "id") orelse return EvalError.InvalidScenario,
        .name = getString(value, "name") orelse return EvalError.InvalidScenario,
        .arguments = getString(value, "arguments") orelse return EvalError.InvalidScenario,
    };
}

fn writeChatResponse(writer: anytype, response: provider.ChatResponse) !void {
    try writer.writeAll("{\"text\":");
    if (response.text) |text| try std.json.stringify(text, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"tool_calls\":[");
    for (response.tool_calls, 0..) |call, i| {
        if (i != 0) try writer.writeByte(',');
        try writeToolCall(writer, call);
    }
    try writer.writeAll("],\"usage\":");
    if (response.usage) |usage| try writeTokenUsage(writer, usage) else try writer.writeAll("null");
    try writer.writeAll(",\"reasoning_content\":");
    if (response.reasoning_content) |reasoning| try std.json.stringify(reasoning, .{}, writer) else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn writeToolCall(writer: anytype, call: provider.ToolCall) !void {
    try writer.writeAll("{\"id\":");
    try std.json.stringify(call.id, .{}, writer);
    try writer.writeAll(",\"name\":");
    try std.json.stringify(call.name, .{}, writer);
    try writer.writeAll(",\"arguments\":");
    try std.json.stringify(call.arguments, .{}, writer);
    try writer.writeByte('}');
}

fn writeTokenUsage(writer: anytype, usage: provider.TokenUsage) !void {
    try writer.writeAll("{\"input_tokens\":");
    try writeOptionalU64(writer, usage.input_tokens);
    try writer.writeAll(",\"output_tokens\":");
    try writeOptionalU64(writer, usage.output_tokens);
    try writer.writeAll(",\"cached_input_tokens\":");
    try writeOptionalU64(writer, usage.cached_input_tokens);
    try writer.writeByte('}');
}

fn writeConversationMessage(writer: anytype, msg: provider.ConversationMessage) !void {
    switch (msg) {
        .chat => |chat| {
            try writer.writeAll("{\"type\":\"Chat\",\"data\":{\"role\":");
            try std.json.stringify(chat.role, .{}, writer);
            try writer.writeAll(",\"content\":");
            try std.json.stringify(chat.content, .{}, writer);
            try writer.writeAll("}}");
        },
        .assistant_tool_calls => |message| {
            try writer.writeAll("{\"type\":\"AssistantToolCalls\",\"data\":{\"text\":");
            if (message.text) |text| try std.json.stringify(text, .{}, writer) else try writer.writeAll("null");
            try writer.writeAll(",\"tool_calls\":[");
            for (message.tool_calls, 0..) |call, i| {
                if (i != 0) try writer.writeByte(',');
                try writeToolCall(writer, call);
            }
            try writer.writeAll("],\"reasoning_content\":");
            if (message.reasoning_content) |reasoning| try std.json.stringify(reasoning, .{}, writer) else try writer.writeAll("null");
            try writer.writeAll("}}");
        },
        .tool_results => |results| {
            try writer.writeAll("{\"type\":\"ToolResults\",\"data\":[");
            for (results, 0..) |result, i| {
                if (i != 0) try writer.writeByte(',');
                try writer.writeAll("{\"tool_call_id\":");
                try std.json.stringify(result.tool_call_id, .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.stringify(result.content, .{}, writer);
                try writer.writeByte('}');
            }
            try writer.writeAll("]}");
        },
    }
}

fn writeStreamChunk(writer: anytype, chunk: provider.StreamChunk) !void {
    try writer.writeAll("{\"delta\":");
    try std.json.stringify(chunk.delta, .{}, writer);
    try writer.writeAll(",\"reasoning\":");
    if (chunk.reasoning) |reasoning| try std.json.stringify(reasoning, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"is_final\":");
    try writer.writeAll(if (chunk.is_final) "true" else "false");
    try writer.print(",\"token_count\":{d}}}", .{chunk.token_count});
}

fn writeStreamEvent(writer: anytype, event: provider.StreamEvent) !void {
    switch (event) {
        .text_delta => |chunk| {
            try writer.writeAll("{\"type\":\"TextDelta\",\"data\":");
            try writeStreamChunk(writer, chunk);
            try writer.writeByte('}');
        },
        .tool_call => |call| {
            try writer.writeAll("{\"type\":\"ToolCall\",\"data\":");
            try writeToolCall(writer, call);
            try writer.writeByte('}');
        },
        .pre_executed_tool_call => |call| {
            try writer.writeAll("{\"type\":\"PreExecutedToolCall\",\"data\":{\"name\":");
            try std.json.stringify(call.name, .{}, writer);
            try writer.writeAll(",\"args\":");
            try std.json.stringify(call.args, .{}, writer);
            try writer.writeAll("}}");
        },
        .pre_executed_tool_result => |result| {
            try writer.writeAll("{\"type\":\"PreExecutedToolResult\",\"data\":{\"name\":");
            try std.json.stringify(result.name, .{}, writer);
            try writer.writeAll(",\"output\":");
            try std.json.stringify(result.output, .{}, writer);
            try writer.writeAll("}}");
        },
        .final => try writer.writeAll("{\"type\":\"Final\"}"),
    }
}

fn writeStreamOptions(writer: anytype, options: provider.StreamOptions) !void {
    try writer.writeAll("{\"enabled\":");
    try writer.writeAll(if (options.enabled) "true" else "false");
    try writer.writeAll(",\"count_tokens\":");
    try writer.writeAll(if (options.count_tokens) "true" else "false");
    try writer.writeByte('}');
}

fn writeProviderCapabilities(writer: anytype, caps: provider.ProviderCapabilities) !void {
    try writer.writeAll("{\"native_tool_calling\":");
    try writer.writeAll(if (caps.native_tool_calling) "true" else "false");
    try writer.writeAll(",\"vision\":");
    try writer.writeAll(if (caps.vision) "true" else "false");
    try writer.writeAll(",\"prompt_caching\":");
    try writer.writeAll(if (caps.prompt_caching) "true" else "false");
    try writer.writeByte('}');
}

fn writeProviderCapabilityError(writer: anytype, err: provider.ProviderCapabilityError) !void {
    try writer.writeAll("{\"provider\":");
    try std.json.stringify(err.provider, .{}, writer);
    try writer.writeAll(",\"capability\":");
    try std.json.stringify(err.capability, .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.stringify(err.message, .{}, writer);
    try writer.writeAll(",\"display\":");
    try writer.print(
        "\"provider_capability_error provider={s} capability={s} message={s}\"",
        .{ err.provider, err.capability, err.message },
    );
    try writer.writeByte('}');
}

fn writeToolsPayload(writer: anytype, payload: provider.ToolsPayload) !void {
    switch (payload) {
        .gemini => |inner| {
            try writer.writeAll("{\"type\":\"Gemini\",\"data\":{\"function_declarations\":");
            try writeJsonArray(writer, inner.function_declarations);
            try writer.writeAll("}}");
        },
        .anthropic => |inner| {
            try writer.writeAll("{\"type\":\"Anthropic\",\"data\":{\"tools\":");
            try writeJsonArray(writer, inner.tools);
            try writer.writeAll("}}");
        },
        .openai => |inner| {
            try writer.writeAll("{\"type\":\"OpenAI\",\"data\":{\"tools\":");
            try writeJsonArray(writer, inner.tools);
            try writer.writeAll("}}");
        },
        .prompt_guided => |inner| {
            try writer.writeAll("{\"type\":\"PromptGuided\",\"data\":{\"instructions\":");
            try std.json.stringify(inner.instructions, .{}, writer);
            try writer.writeAll("}}");
        },
    }
}

fn writeJsonArray(writer: anytype, values: []const std.json.Value) anyerror!void {
    try writer.writeByte('[');
    for (values, 0..) |item, i| {
        if (i != 0) try writer.writeByte(',');
        try writeJsonValue(writer, item);
    }
    try writer.writeByte(']');
}

fn writeJsonValue(writer: anytype, value: std.json.Value) anyerror!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |inner| try writer.writeAll(if (inner) "true" else "false"),
        .integer => |inner| try writer.print("{d}", .{inner}),
        .float => |inner| try std.json.stringify(inner, .{}, writer),
        .number_string => |inner| try writer.writeAll(inner),
        .string => |inner| try std.json.stringify(inner, .{}, writer),
        .array => |array| try writeJsonArray(writer, array.items),
        .object => |object| {
            try writer.writeByte('{');
            var first = true;
            var it = object.iterator();
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try std.json.stringify(entry.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeOptionalU64(writer: anytype, value: ?u64) !void {
    if (value) |inner| try writer.print("{d}", .{inner}) else try writer.writeAll("null");
}

fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
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

fn getArray(value: std.json.Value, key: []const u8) ?std.json.Array {
    const field = getField(value, key) orelse return null;
    if (field != .array) return null;
    return field.array;
}

fn getBool(value: std.json.Value, key: []const u8) ?bool {
    const field = getField(value, key) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn getOptionalU64(value: std.json.Value, key: []const u8) ?u64 {
    const field = getField(value, key) orelse return null;
    if (field == .null) return null;
    if (field != .integer or field.integer < 0) return null;
    return @intCast(field.integer);
}
