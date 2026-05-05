const std = @import("std");
const types = @import("types.zig");
const parser_types = @import("../../tool_call_parser/types.zig");
const parser_json = @import("../../tool_call_parser/json.zig");
const dispatcher = @import("../../runtime/agent/dispatcher.zig");

pub const BASE_URL = "http://localhost:11434";
pub const TEMPERATURE_DEFAULT: f64 = 0.8;

pub const OllamaProvider = struct {
    base_url: []u8,
    api_key: ?[]u8 = null,
    reasoning_enabled: ?bool = null,

    pub fn new(
        allocator: std.mem.Allocator,
        base_url: ?[]const u8,
        api_key: ?[]const u8,
    ) !OllamaProvider {
        return newWithReasoning(allocator, base_url, api_key, null);
    }

    pub fn newWithReasoning(
        allocator: std.mem.Allocator,
        base_url: ?[]const u8,
        api_key: ?[]const u8,
        reasoning_enabled: ?bool,
    ) !OllamaProvider {
        const normalized = try normalizeBaseUrl(allocator, base_url orelse BASE_URL);
        errdefer allocator.free(normalized);

        const owned_key = blk: {
            if (api_key) |value| {
                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                if (trimmed.len != 0) break :blk try allocator.dupe(u8, trimmed);
            }
            break :blk null;
        };

        return .{
            .base_url = normalized,
            .api_key = owned_key,
            .reasoning_enabled = reasoning_enabled,
        };
    }

    pub fn deinit(self: *OllamaProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        if (self.api_key) |key| allocator.free(key);
        self.* = undefined;
    }

    pub fn buildChatRequestWithThink(
        self: *const OllamaProvider,
        allocator: std.mem.Allocator,
        messages: []types.Message,
        model: []const u8,
        temperature: f64,
        tools: ?[]const std.json.Value,
        think: ?bool,
    ) !types.ChatRequest {
        _ = self;
        errdefer {
            for (messages) |*message| message.deinit(allocator);
            allocator.free(messages);
        }

        var owned_tools: ?[]std.json.Value = null;
        errdefer if (owned_tools) |items| {
            for (items) |*item| parser_types.freeJsonValue(allocator, item);
            allocator.free(items);
        };

        if (tools) |tool_values| {
            const cloned = try allocator.alloc(std.json.Value, tool_values.len);
            var cloned_count: usize = 0;
            errdefer {
                for (cloned[0..cloned_count]) |*item| parser_types.freeJsonValue(allocator, item);
                allocator.free(cloned);
            }
            for (tool_values) |tool| {
                cloned[cloned_count] = try parser_types.cloneJsonValue(allocator, tool);
                cloned_count += 1;
            }
            owned_tools = cloned;
        }

        const model_owned = try allocator.dupe(u8, model);
        errdefer allocator.free(model_owned);

        return .{
            .model = model_owned,
            .messages = messages,
            .stream = false,
            .options = .{ .temperature = temperature },
            .think = think,
            .tools = owned_tools,
        };
    }

    pub fn chatWithSystem(
        self: *const OllamaProvider,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: ?f64,
    ) ![]u8 {
        var messages = std.ArrayList(types.Message).init(allocator);
        errdefer {
            for (messages.items) |*entry| entry.deinit(allocator);
            messages.deinit();
        }

        if (system_prompt) |sys| {
            try messages.append(try types.Message.init(allocator, "system", sys));
        }
        try messages.append(try types.Message.init(allocator, "user", message));

        var request = try self.buildChatRequestWithThink(
            allocator,
            try messages.toOwnedSlice(),
            model,
            temperature orelse TEMPERATURE_DEFAULT,
            null,
            self.reasoning_enabled,
        );
        defer request.deinit(allocator);
        messages = std.ArrayList(types.Message).init(allocator);

        var payload = std.ArrayList(u8).init(allocator);
        defer payload.deinit();
        try writeChatRequestJson(allocator, request, payload.writer());

        const url = try std.fmt.allocPrint(allocator, "{s}/api/chat", .{self.base_url});
        defer allocator.free(url);

        var body = std.ArrayList(u8).init(allocator);
        defer body.deinit();

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        var bearer: ?[]u8 = null;
        defer if (bearer) |value| allocator.free(value);
        const auth_header: std.http.Client.Request.Headers.Value = blk: {
            if (self.api_key) |key| {
                if (!isLocalEndpoint(self.base_url)) {
                    bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
                    break :blk .{ .override = bearer.? };
                }
            }
            break :blk .default;
        };

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload.items,
            .response_storage = .{ .dynamic = &body },
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = auth_header,
            },
        });
        if (result.status.class() != .success) return error.OllamaHttpError;

        var response = try parseApiChatResponseBody(allocator, body.items);
        defer response.deinit(allocator);

        if (response.message.tool_calls.len != 0) {
            return try formatToolCallsForLoop(allocator, response.message.tool_calls);
        }

        if (try effectiveContent(allocator, response.message.content, response.message.thinking)) |content| {
            return content;
        }

        return try fallbackTextForEmptyContent(allocator, model, response.message.thinking);
    }
};

pub fn normalizeBaseUrl(allocator: std.mem.Allocator, raw_url: []const u8) ![]u8 {
    const trimmed_left = std.mem.trim(u8, raw_url, " \t\r\n");
    const trimmed = std.mem.trimRight(u8, trimmed_left, "/");
    if (trimmed.len == 0) return try allocator.dupe(u8, "");

    var without_api = trimmed;
    if (std.mem.endsWith(u8, without_api, "/api/chat")) {
        without_api = without_api[0 .. without_api.len - "/api/chat".len];
    } else if (std.mem.endsWith(u8, without_api, "/api")) {
        without_api = without_api[0 .. without_api.len - "/api".len];
    }
    without_api = std.mem.trimRight(u8, without_api, "/");
    return try allocator.dupe(u8, without_api);
}

pub fn stripThinkTags(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var rest = text;
    while (true) {
        if (std.mem.indexOf(u8, rest, "<think>")) |start| {
            try result.appendSlice(rest[0..start]);
            const after_open = rest[start..];
            if (std.mem.indexOf(u8, after_open, "</think>")) |end| {
                rest = after_open[end + "</think>".len ..];
            } else {
                break;
            }
        } else {
            try result.appendSlice(rest);
            break;
        }
    }

    const trimmed = std.mem.trim(u8, result.items, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

pub fn effectiveContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    thinking: ?[]const u8,
) !?[]u8 {
    const stripped = try stripThinkTags(allocator, content);
    errdefer allocator.free(stripped);
    if (std.mem.trim(u8, stripped, " \t\r\n").len != 0) return stripped;
    allocator.free(stripped);

    if (thinking) |raw_thinking| {
        const thinking_trimmed = std.mem.trim(u8, raw_thinking, " \t\r\n");
        if (thinking_trimmed.len != 0) {
            const stripped_thinking = try stripThinkTags(allocator, thinking_trimmed);
            errdefer allocator.free(stripped_thinking);
            if (std.mem.trim(u8, stripped_thinking, " \t\r\n").len != 0) return stripped_thinking;
            allocator.free(stripped_thinking);
        }
    }

    return null;
}

pub fn fallbackTextForEmptyContent(
    allocator: std.mem.Allocator,
    model: []const u8,
    thinking: ?[]const u8,
) ![]u8 {
    _ = model;
    if (thinking) |raw_thinking| {
        const thinking_trimmed = std.mem.trim(u8, raw_thinking, " \t\r\n");
        if (thinking_trimmed.len != 0) {
            const excerpt = firstUtf8Scalars(thinking_trimmed, 200);
            return try std.fmt.allocPrint(
                allocator,
                "I was thinking about this: {s}... but I didn't complete my response. Could you try asking again?",
                .{excerpt},
            );
        }
    }
    return try allocator.dupe(
        u8,
        "I couldn't get a complete response from Ollama. Please try again or switch to a different model.",
    );
}

pub fn parseToolArguments(allocator: std.mem.Allocator, arguments: []const u8) !std.json.Value {
    if (try parser_types.parseJsonValueOwned(allocator, arguments)) |value| return value;
    return parser_types.emptyObject(allocator);
}

pub const ExtractedTool = struct {
    name: []u8,
    arguments: std.json.Value,

    pub fn deinit(self: *ExtractedTool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        parser_types.freeJsonValue(allocator, &self.arguments);
        self.* = undefined;
    }
};

pub fn extractToolNameAndArgs(
    allocator: std.mem.Allocator,
    tool_call: types.OllamaToolCall,
) !ExtractedTool {
    const name = tool_call.function.name;
    const args = tool_call.function.arguments;

    if (std.mem.eql(u8, name, "tool_call") or
        std.mem.eql(u8, name, "tool.call") or
        std.mem.startsWith(u8, name, "tool_call>") or
        std.mem.startsWith(u8, name, "tool_call<"))
    {
        if (getObjectString(args, "name")) |nested_name| {
            var nested_args = if (getObjectField(args, "arguments")) |value|
                try parser_types.cloneJsonValue(allocator, value)
            else
                parser_types.emptyObject(allocator);
            errdefer parser_types.freeJsonValue(allocator, &nested_args);
            const name_owned = try allocator.dupe(u8, nested_name);
            return .{
                .name = name_owned,
                .arguments = nested_args,
            };
        }
    }

    if (std.mem.startsWith(u8, name, "tool.")) {
        const name_owned = try allocator.dupe(u8, name["tool.".len..]);
        errdefer allocator.free(name_owned);
        return .{
            .name = name_owned,
            .arguments = try parser_types.cloneJsonValue(allocator, args),
        };
    }

    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);
    return .{
        .name = name_owned,
        .arguments = try parser_types.cloneJsonValue(allocator, args),
    };
}

pub fn formatToolCallsForLoop(
    allocator: std.mem.Allocator,
    tool_calls: []const types.OllamaToolCall,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{\"content\":\"\",\"tool_calls\":[");
    for (tool_calls, 0..) |tool_call, i| {
        if (i != 0) try writer.writeByte(',');
        var extracted = try extractToolNameAndArgs(allocator, tool_call);
        defer extracted.deinit(allocator);

        var args = std.ArrayList(u8).init(allocator);
        defer args.deinit();
        try parser_json.writeCanonicalJsonValue(allocator, extracted.arguments, args.writer());

        try writer.writeAll("{\"function\":{\"arguments\":");
        try std.json.stringify(args.items, .{}, writer);
        try writer.writeAll(",\"name\":");
        try std.json.stringify(extracted.name, .{}, writer);
        try writer.writeAll("},\"id\":");
        if (tool_call.id) |id| {
            try std.json.stringify(id, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"type\":\"function\"}");
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

pub fn parseApiChatResponseBody(allocator: std.mem.Allocator, body: []const u8) !types.ApiChatResponse {
    var root = (try parser_types.parseJsonValueOwned(allocator, body)) orelse return error.InvalidJson;
    defer parser_types.freeJsonValue(allocator, &root);

    const message_value = getObjectField(root, "message") orelse return error.InvalidJson;
    const content = try allocator.dupe(u8, getObjectString(message_value, "content") orelse "");
    errdefer allocator.free(content);

    const thinking = if (getObjectField(message_value, "thinking")) |value| blk: {
        if (value == .string) break :blk try allocator.dupe(u8, value.string);
        break :blk null;
    } else null;
    errdefer if (thinking) |value| allocator.free(value);

    var tool_calls = std.ArrayList(types.OllamaToolCall).init(allocator);
    errdefer {
        for (tool_calls.items) |*call| call.deinit(allocator);
        tool_calls.deinit();
    }

    if (getObjectField(message_value, "tool_calls")) |tool_calls_value| {
        if (tool_calls_value == .array) {
            for (tool_calls_value.array.items) |item| {
                try tool_calls.append(try parseOllamaToolCall(allocator, item));
            }
        }
    }

    return .{
        .message = .{
            .content = content,
            .tool_calls = try tool_calls.toOwnedSlice(),
            .thinking = thinking,
        },
        .prompt_eval_count = getObjectU64(root, "prompt_eval_count"),
        .eval_count = getObjectU64(root, "eval_count"),
    };
}

pub fn parseChatResponseBody(allocator: std.mem.Allocator, body: []const u8) !dispatcher.ChatResponse {
    var api_response = try parseApiChatResponseBody(allocator, body);
    defer api_response.deinit(allocator);
    return try apiResponseToChatResponse(allocator, api_response, "ollama");
}

pub fn apiResponseToChatResponse(
    allocator: std.mem.Allocator,
    api_response: types.ApiChatResponse,
    model: []const u8,
) !dispatcher.ChatResponse {
    const usage: ?dispatcher.TokenUsage =
        if (api_response.prompt_eval_count != null or api_response.eval_count != null)
            .{
                .input_tokens = api_response.prompt_eval_count,
                .output_tokens = api_response.eval_count,
                .cached_input_tokens = null,
            }
        else
            null;

    if (api_response.message.tool_calls.len != 0) {
        var calls = std.ArrayList(dispatcher.ToolCall).init(allocator);
        errdefer {
            for (calls.items) |*call| call.deinit(allocator);
            calls.deinit();
        }
        for (api_response.message.tool_calls) |tool_call| {
            var extracted = try extractToolNameAndArgs(allocator, tool_call);
            defer extracted.deinit(allocator);

            var args = std.ArrayList(u8).init(allocator);
            defer args.deinit();
            try parser_json.writeCanonicalJsonValue(allocator, extracted.arguments, args.writer());

            {
                const id_owned = try allocator.dupe(u8, tool_call.id orelse "00000000-0000-4000-8000-000000000000");
                errdefer allocator.free(id_owned);
                const name_owned = try allocator.dupe(u8, extracted.name);
                errdefer allocator.free(name_owned);
                const args_owned = try args.toOwnedSlice();
                errdefer allocator.free(args_owned);
                try calls.append(.{
                    .id = id_owned,
                    .name = name_owned,
                    .arguments = args_owned,
                });
            }
        }

        const text = try normalizeResponseText(allocator, api_response.message.content);
        return .{
            .text = text,
            .tool_calls = try calls.toOwnedSlice(),
            .usage = usage,
            .reasoning_content = null,
            .owned = true,
        };
    }

    const text = if (try effectiveContent(allocator, api_response.message.content, api_response.message.thinking)) |content|
        content
    else
        try fallbackTextForEmptyContent(allocator, model, api_response.message.thinking);

    return .{
        .text = text,
        .tool_calls = &.{},
        .usage = usage,
        .reasoning_content = null,
        .owned = true,
    };
}

pub fn writeChatRequestJson(
    allocator: std.mem.Allocator,
    request: types.ChatRequest,
    writer: anytype,
) !void {
    try writer.writeAll("{\"model\":");
    try std.json.stringify(request.model, .{}, writer);
    try writer.writeAll(",\"messages\":[");
    for (request.messages, 0..) |message, i| {
        if (i != 0) try writer.writeByte(',');
        try writeMessageJson(allocator, message, writer);
    }
    try writer.writeAll("],\"stream\":false,\"options\":{\"temperature\":");
    try std.json.stringify(request.options.temperature, .{}, writer);
    try writer.writeByte('}');
    if (request.think) |think| {
        try writer.writeAll(",\"think\":");
        try writer.writeAll(if (think) "true" else "false");
    }
    if (request.tools) |tools| {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |tool, i| {
            if (i != 0) try writer.writeByte(',');
            try parser_json.writeCanonicalJsonValue(allocator, tool, writer);
        }
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

fn writeMessageJson(
    allocator: std.mem.Allocator,
    message: types.Message,
    writer: anytype,
) !void {
    try writer.writeAll("{\"role\":");
    try std.json.stringify(message.role, .{}, writer);
    if (message.content) |content| {
        try writer.writeAll(",\"content\":");
        try std.json.stringify(content, .{}, writer);
    }
    if (message.images) |images| {
        try writer.writeAll(",\"images\":[");
        for (images, 0..) |image, i| {
            if (i != 0) try writer.writeByte(',');
            try std.json.stringify(image, .{}, writer);
        }
        try writer.writeByte(']');
    }
    if (message.tool_calls) |calls| {
        try writer.writeAll(",\"tool_calls\":[");
        for (calls, 0..) |call, i| {
            if (i != 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":");
            try std.json.stringify(call.kind, .{}, writer);
            try writer.writeAll(",\"function\":{\"name\":");
            try std.json.stringify(call.function.name, .{}, writer);
            try writer.writeAll(",\"arguments\":");
            try parser_json.writeCanonicalJsonValue(allocator, call.function.arguments, writer);
            try writer.writeAll("}}");
        }
        try writer.writeByte(']');
    }
    if (message.tool_name) |tool_name| {
        try writer.writeAll(",\"tool_name\":");
        try std.json.stringify(tool_name, .{}, writer);
    }
    try writer.writeByte('}');
}

fn parseOllamaToolCall(allocator: std.mem.Allocator, value: std.json.Value) !types.OllamaToolCall {
    const function_value = getObjectField(value, "function") orelse return error.InvalidJson;
    const name = getObjectString(function_value, "name") orelse return error.InvalidJson;
    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);
    var arguments = try parseArgumentsValue(allocator, getObjectField(function_value, "arguments"));
    errdefer parser_types.freeJsonValue(allocator, &arguments);

    return .{
        .id = if (getObjectField(value, "id")) |id_value| blk: {
            if (id_value == .string) break :blk try allocator.dupe(u8, id_value.string);
            break :blk null;
        } else null,
        .function = .{
            .name = name_owned,
            .arguments = arguments,
        },
    };
}

fn parseArgumentsValue(allocator: std.mem.Allocator, value: ?std.json.Value) !std.json.Value {
    const raw = value orelse return parser_types.emptyObject(allocator);
    if (raw == .string) {
        if (try parser_types.parseJsonValueOwned(allocator, raw.string)) |parsed| return parsed;
        return parser_types.emptyObject(allocator);
    }
    return try parser_types.cloneJsonValue(allocator, raw);
}

fn normalizeResponseText(allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
    const stripped = try stripThinkTags(allocator, content);
    errdefer allocator.free(stripped);
    if (std.mem.trim(u8, stripped, " \t\r\n").len == 0) {
        allocator.free(stripped);
        return null;
    }
    return stripped;
}

fn getObjectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getObjectField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn getObjectU64(value: std.json.Value, key: []const u8) ?u64 {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .number_string => |raw| std.fmt.parseInt(u64, raw, 10) catch null,
        else => null,
    };
}

fn firstUtf8Scalars(value: []const u8, limit: usize) []const u8 {
    var iter = std.unicode.Utf8Iterator{ .bytes = value, .i = 0 };
    var count: usize = 0;
    var end: usize = 0;
    while (count < limit) : (count += 1) {
        const start = iter.i;
        if (iter.nextCodepoint()) |_| {
            end = iter.i;
        } else {
            return value[0..end];
        }
        if (iter.i == start) break;
    }
    return value[0..end];
}

fn isLocalEndpoint(base_url: []const u8) bool {
    const uri = std.Uri.parse(base_url) catch return false;
    const host = uri.host orelse return false;
    const raw = switch (host) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    return std.mem.eql(u8, raw, "localhost") or
        std.mem.eql(u8, raw, "127.0.0.1") or
        std.mem.eql(u8, raw, "::1");
}

test "strip think tags drops unclosed tail" {
    const result = try stripThinkTags(std.testing.allocator, "visible<think>hidden");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("visible", result);
}
