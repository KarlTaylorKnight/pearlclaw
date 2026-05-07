//! eval-providers — offline provider eval runner.
//!
//! Reads JSONL provider ops from stdin, runs deterministic Ollama Phase 1
//! helpers, writes canonical-comparable JSONL to stdout.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const ollama = zeroclaw.providers.ollama;
const ollama_types = ollama.types;
const openai = zeroclaw.providers.openai;
const openai_types = openai.types;
const dispatcher = zeroclaw.runtime.agent.dispatcher;
const provider_handle = zeroclaw.providers.provider;

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
    const provider = getString(parsed.value, "provider") orelse "ollama";

    if (std.mem.eql(u8, provider, "ollama") and std.mem.eql(u8, op, "normalize_base_url")) {
        const raw_url = getString(parsed.value, "raw_url") orelse return EvalError.InvalidScenario;
        const result = try ollama.normalizeBaseUrl(allocator, raw_url);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, provider, "ollama") and std.mem.eql(u8, op, "strip_think_tags")) {
        const text = getString(parsed.value, "text") orelse return EvalError.InvalidScenario;
        const result = try ollama.stripThinkTags(allocator, text);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, provider, "ollama") and std.mem.eql(u8, op, "effective_content")) {
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
    } else if (std.mem.eql(u8, provider, "openai") and std.mem.eql(u8, op, "effective_content")) {
        const content = getOptionalString(parsed.value, "content");
        const reasoning_content = getOptionalString(parsed.value, "reasoning_content");
        const result = try openai.effectiveContent(allocator, content, reasoning_content);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, provider, "ollama") and std.mem.eql(u8, op, "build_chat_request")) {
        try runOllamaBuildChatRequest(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, provider, "ollama") and std.mem.eql(u8, op, "convert_messages")) {
        try runOllamaConvertMessages(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, provider, "ollama") and std.mem.eql(u8, op, "chat_with_history_request")) {
        try runOllamaHistoryRequest(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, provider, "ollama") and std.mem.eql(u8, op, "chat_request")) {
        try runOllamaChatRequest(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, provider, "openai") and std.mem.eql(u8, op, "build_chat_request")) {
        try runOpenAiBuildChatRequest(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, provider, "openai") and std.mem.eql(u8, op, "convert_messages")) {
        try runOpenAiConvertMessages(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, provider, "openai") and std.mem.eql(u8, op, "chat_request")) {
        try runOpenAiChatRequest(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, provider, "ollama") and std.mem.eql(u8, op, "convert_tools")) {
        try runOllamaConvertTools(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, provider, "openai") and std.mem.eql(u8, op, "convert_tools")) {
        try runOpenAiConvertTools(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, provider, "openai") and std.mem.eql(u8, op, "parse_native_tool_spec")) {
        try runOpenAiParseNativeToolSpec(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, provider, "ollama") and std.mem.eql(u8, op, "parse_chat_response")) {
        const body = getString(parsed.value, "body") orelse return EvalError.InvalidScenario;
        var result = try ollama.parseChatResponseBody(allocator, body);
        defer result.deinit(allocator);
        try writer.writeAll("{\"op\":\"parse_chat_response\",\"result\":");
        try writeChatResponse(writer, result);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, provider, "openai") and std.mem.eql(u8, op, "parse_chat_response")) {
        const body = getString(parsed.value, "body") orelse return EvalError.InvalidScenario;
        var result = try openai.parseChatResponseBody(allocator, body);
        defer result.deinit(allocator);
        try writer.writeAll("{\"op\":\"parse_chat_response\",\"result\":");
        try writeChatResponse(writer, result);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, provider, "openai") and std.mem.eql(u8, op, "parse_native_response")) {
        const body = getString(parsed.value, "body") orelse return EvalError.InvalidScenario;
        var result = try openai.parseNativeResponseBody(allocator, body);
        defer result.deinit(allocator);
        try writer.writeAll("{\"op\":\"parse_native_response\",\"result\":");
        try writeChatResponse(writer, result);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, provider, "openai") and std.mem.eql(u8, op, "adjust_temperature_for_model")) {
        const model = getString(parsed.value, "model") orelse return EvalError.InvalidScenario;
        const requested_temperature = getF64(parsed.value, "requested_temperature") orelse return EvalError.InvalidScenario;
        try writer.writeAll("{\"op\":\"adjust_temperature_for_model\",\"result\":");
        try std.json.stringify(openai.adjustTemperatureForModel(model, requested_temperature), .{}, writer);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, provider, "ollama") and std.mem.eql(u8, op, "format_tool_calls_for_loop")) {
        const calls = try toolCallsFromOp(allocator, parsed.value);
        defer freeOllamaToolCalls(allocator, calls);
        const result = try ollama.formatToolCallsForLoop(allocator, calls);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else {
        return EvalError.InvalidScenario;
    }
}

fn runOllamaBuildChatRequest(allocator: std.mem.Allocator, op_value: std.json.Value, writer: anytype) !void {
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

fn runOllamaConvertMessages(allocator: std.mem.Allocator, op_value: std.json.Value, writer: anytype) !void {
    const messages = try chatMessagesFromField(allocator, op_value, "messages");
    defer freeChatMessages(allocator, messages);

    var provider = try ollama.OllamaProvider.new(allocator, null, null);
    defer provider.deinit(allocator);

    const converted = try provider.convertMessages(allocator, messages);
    defer freeOllamaMessages(allocator, converted);

    try writer.writeAll("{\"op\":\"convert_messages\",\"result\":");
    try ollama.client.writeMessagesJson(allocator, converted, writer);
    try writer.writeAll("}\n");
}

fn runOllamaHistoryRequest(allocator: std.mem.Allocator, op_value: std.json.Value, writer: anytype) !void {
    const model = getString(op_value, "model") orelse return EvalError.InvalidScenario;
    const temperature = getF64(op_value, "temperature") orelse return EvalError.InvalidScenario;
    const messages = try chatMessagesFromField(allocator, op_value, "messages");
    defer freeChatMessages(allocator, messages);

    var provider = try ollama.OllamaProvider.new(allocator, null, null);
    defer provider.deinit(allocator);

    const converted = try provider.convertMessages(allocator, messages);
    defer freeOllamaMessages(allocator, converted);

    var request = try provider.buildChatRequestWithThink(
        allocator,
        try cloneOllamaMessages(allocator, converted),
        model,
        temperature,
        null,
        null,
    );
    defer request.deinit(allocator);

    try writer.writeAll("{\"op\":\"chat_with_history_request\",\"result\":");
    try ollama.client.writeChatRequestJson(allocator, request, writer);
    try writer.writeAll("}\n");
}

fn runOllamaChatRequest(allocator: std.mem.Allocator, op_value: std.json.Value, writer: anytype) !void {
    const model = getString(op_value, "model") orelse return EvalError.InvalidScenario;
    const temperature = getF64(op_value, "temperature") orelse return EvalError.InvalidScenario;
    const request_value = getField(op_value, "request") orelse return EvalError.InvalidScenario;
    if (request_value != .object) return EvalError.InvalidScenario;

    const messages = try chatMessagesFromField(allocator, request_value, "messages");
    defer freeChatMessages(allocator, messages);
    const tool_specs = try optionalToolSpecs(allocator, request_value);
    defer if (tool_specs) |s| allocator.free(s);

    var provider = try ollama.OllamaProvider.new(allocator, null, null);
    defer provider.deinit(allocator);

    const converted = try provider.convertMessages(allocator, messages);
    defer freeOllamaMessages(allocator, converted);

    var converted_tools: ?[]std.json.Value = null;
    defer if (converted_tools) |values| {
        for (values) |*v| freeOllamaToolJsonValue(allocator, v);
        allocator.free(values);
    };
    if (tool_specs) |specs| {
        converted_tools = try provider.convertTools(allocator, specs);
    }

    var request = try provider.buildChatRequestWithThink(
        allocator,
        try cloneOllamaMessages(allocator, converted),
        model,
        temperature,
        converted_tools,
        null,
    );
    defer request.deinit(allocator);

    try writer.writeAll("{\"op\":\"chat_request\",\"result\":");
    try ollama.client.writeChatRequestJson(allocator, request, writer);
    try writer.writeAll("}\n");
}

fn runOllamaConvertTools(allocator: std.mem.Allocator, op_value: std.json.Value, writer: anytype) !void {
    const tool_specs = (try optionalToolSpecs(allocator, op_value)) orelse return EvalError.InvalidScenario;
    defer allocator.free(tool_specs);

    var provider = try ollama.OllamaProvider.new(allocator, null, null);
    defer provider.deinit(allocator);

    const converted = try provider.convertTools(allocator, tool_specs);
    defer {
        for (converted) |*v| freeOllamaToolJsonValue(allocator, v);
        allocator.free(converted);
    }

    try writer.writeAll("{\"op\":\"convert_tools\",\"result\":[");
    for (converted, 0..) |tool, i| {
        if (i != 0) try writer.writeByte(',');
        try writeJsonValue(writer, tool);
    }
    try writer.writeAll("]}\n");
}

fn runOpenAiBuildChatRequest(allocator: std.mem.Allocator, op_value: std.json.Value, writer: anytype) !void {
    const model = getString(op_value, "model") orelse return EvalError.InvalidScenario;
    const system = getOptionalString(op_value, "system");
    const message = getString(op_value, "message") orelse return EvalError.InvalidScenario;
    const temperature = getF64(op_value, "temperature") orelse return EvalError.InvalidScenario;
    const max_tokens = getOptionalU32(op_value, "max_tokens");

    var messages = std.ArrayList(openai_types.Message).init(allocator);
    errdefer {
        for (messages.items) |*entry| entry.deinit(allocator);
        messages.deinit();
    }
    if (system) |sys| try messages.append(try openai_types.Message.init(allocator, "system", sys));
    try messages.append(try openai_types.Message.init(allocator, "user", message));

    var provider = try openai.OpenAiProvider.new(allocator, "test-openai-key");
    defer provider.deinit(allocator);

    var request = try provider.buildChatRequest(
        allocator,
        try messages.toOwnedSlice(),
        model,
        temperature,
        max_tokens,
    );
    defer request.deinit(allocator);
    messages = std.ArrayList(openai_types.Message).init(allocator);

    try writer.writeAll("{\"op\":\"build_chat_request\",\"result\":");
    try openai.client.writeChatRequestJson(request, writer);
    try writer.writeAll("}\n");
}

fn runOpenAiConvertMessages(allocator: std.mem.Allocator, op_value: std.json.Value, writer: anytype) !void {
    const messages = try chatMessagesFromField(allocator, op_value, "messages");
    defer freeChatMessages(allocator, messages);

    var provider = try openai.OpenAiProvider.new(allocator, "test-openai-key");
    defer provider.deinit(allocator);

    const converted = try provider.convertMessages(allocator, messages);
    defer freeOpenAiNativeMessages(allocator, converted);

    try writer.writeAll("{\"op\":\"convert_messages\",\"result\":");
    try openai.client.writeNativeMessagesJson(allocator, converted, writer);
    try writer.writeAll("}\n");
}

fn runOpenAiChatRequest(allocator: std.mem.Allocator, op_value: std.json.Value, writer: anytype) !void {
    const model = getString(op_value, "model") orelse return EvalError.InvalidScenario;
    const temperature = getF64(op_value, "temperature") orelse return EvalError.InvalidScenario;
    const max_tokens = getOptionalU32(op_value, "max_tokens");
    const request_value = getField(op_value, "request") orelse return EvalError.InvalidScenario;
    if (request_value != .object) return EvalError.InvalidScenario;

    const messages = try chatMessagesFromField(allocator, request_value, "messages");
    defer freeChatMessages(allocator, messages);
    const tool_specs = try optionalToolSpecs(allocator, request_value);
    defer if (tool_specs) |s| allocator.free(s);
    const tool_choice = getOptionalString(request_value, "tool_choice");

    var provider = try openai.OpenAiProvider.new(allocator, "test-openai-key");
    defer provider.deinit(allocator);

    var request = try provider.buildNativeChatRequest(
        allocator,
        messages,
        tool_specs,
        tool_choice,
        model,
        temperature,
        max_tokens,
    );
    defer request.deinit(allocator);

    try writer.writeAll("{\"op\":\"chat_request\",\"result\":");
    try openai.client.writeNativeChatRequestJson(allocator, request, writer);
    try writer.writeAll("}\n");
}

fn runOpenAiConvertTools(allocator: std.mem.Allocator, op_value: std.json.Value, writer: anytype) !void {
    const tool_specs = (try optionalToolSpecs(allocator, op_value)) orelse return EvalError.InvalidScenario;
    defer allocator.free(tool_specs);

    var provider = try openai.OpenAiProvider.new(allocator, "test-openai-key");
    defer provider.deinit(allocator);

    const converted = try provider.convertTools(allocator, tool_specs);
    defer {
        for (converted) |*tool| {
            var owned = tool.*;
            owned.deinit(allocator);
        }
        allocator.free(converted);
    }

    try writer.writeAll("{\"op\":\"convert_tools\",\"result\":[");
    for (converted, 0..) |tool, i| {
        if (i != 0) try writer.writeByte(',');
        try openai.client.writeNativeToolSpecJson(allocator, tool, writer);
    }
    try writer.writeAll("]}\n");
}

fn runOpenAiParseNativeToolSpec(allocator: std.mem.Allocator, op_value: std.json.Value, writer: anytype) !void {
    const value_field = getField(op_value, "value") orelse {
        try writer.writeAll("{\"op\":\"parse_native_tool_spec\",\"result\":{\"error\":\"InvalidToolSpec\"}}\n");
        return;
    };

    // Both eval runners normalize parse failures to a single
    // "InvalidToolSpec" tag — Rust's anyhow message and Zig's @errorName
    // don't byte-equal, so the eval contract collapses both to one
    // canonical string.
    const result = openai.parseNativeToolSpec(allocator, value_field) catch {
        try writer.writeAll("{\"op\":\"parse_native_tool_spec\",\"result\":{\"error\":\"InvalidToolSpec\"}}\n");
        return;
    };
    var owned = result;
    defer owned.deinit(allocator);

    try writer.writeAll("{\"op\":\"parse_native_tool_spec\",\"result\":");
    try openai.client.writeNativeToolSpecJson(allocator, owned, writer);
    try writer.writeAll("}\n");
}

fn chatMessagesFromField(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
) ![]dispatcher.ChatMessage {
    const messages_value = getField(value, key) orelse return EvalError.InvalidScenario;
    if (messages_value != .array) return EvalError.InvalidScenario;

    var messages = std.ArrayList(dispatcher.ChatMessage).init(allocator);
    errdefer {
        for (messages.items) |*message| message.deinit(allocator);
        messages.deinit();
    }

    for (messages_value.array.items) |message_value| {
        if (message_value != .object) return EvalError.InvalidScenario;
        const role = getStringValue(message_value, "role") orelse return EvalError.InvalidScenario;
        const content = getStringValue(message_value, "content") orelse return EvalError.InvalidScenario;
        try messages.append(.{
            .role = try allocator.dupe(u8, role),
            .content = try allocator.dupe(u8, content),
        });
    }

    return messages.toOwnedSlice();
}

fn freeChatMessages(allocator: std.mem.Allocator, messages: []dispatcher.ChatMessage) void {
    for (messages) |*message| message.deinit(allocator);
    allocator.free(messages);
}

/// Mirrors parser_types.freeJsonValue — kept local to avoid the
/// "file exists in multiple modules" import collision documented in the
/// 2026-05-06 Ollama 2A first-pass section.
fn freeOllamaToolJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .null, .bool, .integer, .float => {},
        .number_string => |s| allocator.free(s),
        .string => |s| allocator.free(s),
        .array => |*array| {
            for (array.items) |*item| freeOllamaToolJsonValue(allocator, item);
            array.deinit();
        },
        .object => |*object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeOllamaToolJsonValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
    }
}

/// Minimal JSON value writer for offline eval output. Object keys are
/// emitted in iteration order; downstream Python canonicalization sorts.
fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try std.json.stringify(f, .{}, writer),
        .number_string => |s| try writer.writeAll(s),
        .string => |s| try std.json.stringify(s, .{}, writer),
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
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

fn optionalRawTools(value: std.json.Value) ?[]const std.json.Value {
    const tools_value = getField(value, "tools") orelse return null;
    if (tools_value == .null) return null;
    if (tools_value != .array or tools_value.array.items.len == 0) return null;
    return tools_value.array.items;
}

/// Parse the `tools` field as a list of provider-agnostic ToolSpec values.
/// Returned slice and field strings BORROW from the parsed JSON tree
/// passed in (which the eval driver keeps alive via `parsed.deinit()`).
/// Returns null when the field is missing, null, or empty.
fn optionalToolSpecs(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !?[]provider_handle.ToolSpec {
    const tools_value = getField(value, "tools") orelse return null;
    if (tools_value == .null) return null;
    if (tools_value != .array or tools_value.array.items.len == 0) return null;

    const specs = try allocator.alloc(provider_handle.ToolSpec, tools_value.array.items.len);
    errdefer allocator.free(specs);
    for (tools_value.array.items, 0..) |item, i| {
        if (item != .object) return EvalError.InvalidScenario;
        const name = item.object.get("name") orelse return EvalError.InvalidScenario;
        const description = item.object.get("description") orelse return EvalError.InvalidScenario;
        const parameters = item.object.get("parameters") orelse return EvalError.InvalidScenario;
        if (name != .string or description != .string) return EvalError.InvalidScenario;
        specs[i] = .{
            .name = name.string,
            .description = description.string,
            .parameters = parameters,
        };
    }
    return specs;
}

fn cloneOllamaMessages(allocator: std.mem.Allocator, messages: []const ollama_types.Message) ![]ollama_types.Message {
    const cloned = try allocator.alloc(ollama_types.Message, messages.len);
    var count: usize = 0;
    errdefer {
        for (cloned[0..count]) |*message| message.deinit(allocator);
        allocator.free(cloned);
    }

    for (messages) |message| {
        cloned[count] = try cloneOllamaMessage(allocator, message);
        count += 1;
    }
    return cloned;
}

fn cloneOllamaMessage(allocator: std.mem.Allocator, message: ollama_types.Message) !ollama_types.Message {
    const role = try allocator.dupe(u8, message.role);
    errdefer allocator.free(role);
    const content = if (message.content) |value| try allocator.dupe(u8, value) else null;
    errdefer if (content) |value| allocator.free(value);
    const images = if (message.images) |value| try cloneImages(allocator, value) else null;
    errdefer if (images) |value| freeImages(allocator, value);
    const tool_calls = if (message.tool_calls) |value| try cloneOutgoingToolCalls(allocator, value) else null;
    errdefer if (tool_calls) |value| freeOutgoingToolCalls(allocator, value);
    const tool_name = if (message.tool_name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (tool_name) |value| allocator.free(value);

    return .{
        .role = role,
        .content = content,
        .images = images,
        .tool_calls = tool_calls,
        .tool_name = tool_name,
    };
}

fn cloneImages(allocator: std.mem.Allocator, images: []const []const u8) ![][]u8 {
    const cloned = try allocator.alloc([]u8, images.len);
    var count: usize = 0;
    errdefer {
        for (cloned[0..count]) |image| allocator.free(image);
        allocator.free(cloned);
    }
    for (images) |image| {
        cloned[count] = try allocator.dupe(u8, image);
        count += 1;
    }
    return cloned;
}

fn cloneOutgoingToolCalls(
    allocator: std.mem.Allocator,
    calls: []const ollama_types.OutgoingToolCall,
) ![]ollama_types.OutgoingToolCall {
    const cloned = try allocator.alloc(ollama_types.OutgoingToolCall, calls.len);
    var count: usize = 0;
    errdefer {
        for (cloned[0..count]) |*call| call.deinit(allocator);
        allocator.free(cloned);
    }
    for (calls) |call| {
        {
            const kind = try allocator.dupe(u8, call.kind);
            errdefer allocator.free(kind);
            const name = try allocator.dupe(u8, call.function.name);
            errdefer allocator.free(name);
            var arguments = try cloneJsonValue(allocator, call.function.arguments);
            errdefer freeJsonValue(allocator, &arguments);

            cloned[count] = .{
                .kind = kind,
                .function = .{
                    .name = name,
                    .arguments = arguments,
                },
            };
            count += 1;
        }
    }
    return cloned;
}

fn freeOllamaMessages(allocator: std.mem.Allocator, messages: []ollama_types.Message) void {
    for (messages) |*message| message.deinit(allocator);
    allocator.free(messages);
}

fn freeOpenAiNativeMessages(allocator: std.mem.Allocator, messages: []openai_types.NativeMessage) void {
    for (messages) |*message| message.deinit(allocator);
    allocator.free(messages);
}

fn freeImages(allocator: std.mem.Allocator, images: [][]u8) void {
    for (images) |image| allocator.free(image);
    allocator.free(images);
}

fn freeOutgoingToolCalls(allocator: std.mem.Allocator, calls: []ollama_types.OutgoingToolCall) void {
    for (calls) |*call| call.deinit(allocator);
    allocator.free(calls);
}

fn emptyObject(allocator: std.mem.Allocator) std.json.Value {
    return .{ .object = std.json.ObjectMap.init(allocator) };
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |inner| .{ .bool = inner },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .number_string => |inner| .{ .number_string = try allocator.dupe(u8, inner) },
        .string => |inner| .{ .string = try allocator.dupe(u8, inner) },
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            errdefer {
                var tmp = std.json.Value{ .array = cloned };
                freeJsonValue(allocator, &tmp);
            }
            for (array.items) |item| {
                try cloned.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned = std.json.ObjectMap.init(allocator);
            errdefer {
                var tmp = std.json.Value{ .object = cloned };
                freeJsonValue(allocator, &tmp);
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try cloned.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = cloned };
        },
    };
}

fn freeJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .null, .bool, .integer, .float => {},
        .number_string => |inner| allocator.free(inner),
        .string => |inner| allocator.free(inner),
        .array => |*array| {
            for (array.items) |*item| freeJsonValue(allocator, item);
            array.deinit();
        },
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
    }
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
                try cloneJsonValue(allocator, value)
            else
                emptyObject(allocator);
            errdefer freeJsonValue(allocator, &arguments);
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

fn getOptionalU32(value: std.json.Value, key: []const u8) ?u32 {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .null => null,
        .integer => |inner| if (inner >= 0 and inner <= std.math.maxInt(u32)) @intCast(inner) else null,
        .number_string => |raw| std.fmt.parseInt(u32, raw, 10) catch null,
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
