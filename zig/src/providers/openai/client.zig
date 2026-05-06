const std = @import("std");
const types = @import("types.zig");
const parser_types = @import("../../tool_call_parser/types.zig");
const dispatcher = @import("../../runtime/agent/dispatcher.zig");

pub const BASE_URL = "https://api.openai.com/v1";
pub const TEMPERATURE_DEFAULT: f64 = 0.8;

pub const OpenAiProvider = struct {
    base_url: []u8,
    credential: ?[]u8 = null,
    max_tokens: ?u32 = null,

    pub fn new(allocator: std.mem.Allocator, credential: ?[]const u8) !OpenAiProvider {
        return withBaseUrl(allocator, null, credential);
    }

    pub fn withBaseUrl(
        allocator: std.mem.Allocator,
        base_url: ?[]const u8,
        credential: ?[]const u8,
    ) !OpenAiProvider {
        const raw_url = base_url orelse BASE_URL;
        const trimmed_url = std.mem.trimRight(u8, raw_url, "/");
        const owned_url = try allocator.dupe(u8, trimmed_url);
        errdefer allocator.free(owned_url);

        const owned_credential = if (credential) |value|
            try allocator.dupe(u8, value)
        else
            null;

        return .{
            .base_url = owned_url,
            .credential = owned_credential,
            .max_tokens = null,
        };
    }

    pub fn withMaxTokens(self: OpenAiProvider, max_tokens: ?u32) OpenAiProvider {
        var copy = self;
        copy.max_tokens = max_tokens;
        return copy;
    }

    pub fn deinit(self: *OpenAiProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        if (self.credential) |credential| allocator.free(credential);
        self.* = undefined;
    }

    pub fn buildChatRequest(
        self: *const OpenAiProvider,
        allocator: std.mem.Allocator,
        messages: []types.Message,
        model: []const u8,
        temperature: f64,
        max_tokens: ?u32,
    ) !types.ChatRequest {
        _ = self;
        errdefer {
            for (messages) |*message| message.deinit(allocator);
            allocator.free(messages);
        }

        const model_owned = try allocator.dupe(u8, model);
        errdefer allocator.free(model_owned);

        return .{
            .model = model_owned,
            .messages = messages,
            .temperature = temperature,
            .max_tokens = max_tokens,
        };
    }

    pub fn chatWithSystem(
        self: *const OpenAiProvider,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: ?f64,
    ) ![]u8 {
        const credential = self.credential orelse return error.OpenAiApiKeyNotSet;
        const adjusted_temperature = adjustTemperatureForModel(
            model,
            temperature orelse TEMPERATURE_DEFAULT,
        );

        var messages = std.ArrayList(types.Message).init(allocator);
        errdefer {
            for (messages.items) |*entry| entry.deinit(allocator);
            messages.deinit();
        }

        if (system_prompt) |sys| {
            try messages.append(try types.Message.init(allocator, "system", sys));
        }
        try messages.append(try types.Message.init(allocator, "user", message));

        var request = try self.buildChatRequest(
            allocator,
            try messages.toOwnedSlice(),
            model,
            adjusted_temperature,
            self.max_tokens,
        );
        defer request.deinit(allocator);
        messages = std.ArrayList(types.Message).init(allocator);

        var payload = std.ArrayList(u8).init(allocator);
        defer payload.deinit();
        try writeChatRequestJson(request, payload.writer());

        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.base_url});
        defer allocator.free(url);

        const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{credential});
        defer allocator.free(bearer);

        var body = std.ArrayList(u8).init(allocator);
        defer body.deinit();

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload.items,
            .response_storage = .{ .dynamic = &body },
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = bearer },
            },
        });
        if (result.status.class() != .success) return error.OpenAiHttpError;

        var response = try parseApiChatResponseBody(allocator, body.items);
        defer response.deinit(allocator);

        if (response.choices.len == 0) return error.NoResponseFromOpenAI;
        return response.choices[0].message.effectiveContent(allocator);
    }
};

pub fn adjustTemperatureForModel(model: []const u8, requested_temperature: f64) f64 {
    const requires_1_0 = std.mem.eql(u8, model, "gpt-5") or
        std.mem.eql(u8, model, "gpt-5-2025-08-07") or
        std.mem.eql(u8, model, "gpt-5-mini") or
        std.mem.eql(u8, model, "gpt-5-mini-2025-08-07") or
        std.mem.eql(u8, model, "gpt-5-nano") or
        std.mem.eql(u8, model, "gpt-5-nano-2025-08-07") or
        std.mem.eql(u8, model, "gpt-5.1-chat-latest") or
        std.mem.eql(u8, model, "gpt-5.2-chat-latest") or
        std.mem.eql(u8, model, "gpt-5.3-chat-latest") or
        std.mem.eql(u8, model, "o1") or
        std.mem.eql(u8, model, "o1-2024-12-17") or
        std.mem.eql(u8, model, "o3") or
        std.mem.eql(u8, model, "o3-2025-04-16") or
        std.mem.eql(u8, model, "o3-mini") or
        std.mem.eql(u8, model, "o3-mini-2025-01-31") or
        std.mem.eql(u8, model, "o4-mini") or
        std.mem.eql(u8, model, "o4-mini-2025-04-16");

    return if (requires_1_0) 1.0 else requested_temperature;
}

pub fn effectiveContent(
    allocator: std.mem.Allocator,
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
) ![]u8 {
    if (content) |value| {
        if (value.len != 0) return try allocator.dupe(u8, value);
    }
    if (reasoning_content) |value| return try allocator.dupe(u8, value);
    return try allocator.dupe(u8, "");
}

pub fn parseApiChatResponseBody(allocator: std.mem.Allocator, body: []const u8) !types.ChatResponse {
    var root = (try parser_types.parseJsonValueOwned(allocator, body)) orelse return error.InvalidJson;
    defer parser_types.freeJsonValue(allocator, &root);

    const choices_value = getObjectField(root, "choices") orelse return error.InvalidJson;
    if (choices_value != .array) return error.InvalidJson;

    var choices = std.ArrayList(types.Choice).init(allocator);
    errdefer {
        for (choices.items) |*choice| choice.deinit(allocator);
        choices.deinit();
    }

    for (choices_value.array.items) |choice_value| {
        try choices.append(.{ .message = try parseResponseMessage(allocator, choice_value) });
    }

    return .{ .choices = try choices.toOwnedSlice() };
}

pub fn parseChatResponseBody(allocator: std.mem.Allocator, body: []const u8) !dispatcher.ChatResponse {
    var api_response = try parseApiChatResponseBody(allocator, body);
    defer api_response.deinit(allocator);

    if (api_response.choices.len == 0) return error.NoResponseFromOpenAI;
    const message = api_response.choices[0].message;
    const text = try message.effectiveContent(allocator);
    errdefer allocator.free(text);
    const reasoning = if (message.reasoning_content) |value|
        try allocator.dupe(u8, value)
    else
        null;

    return .{
        .text = text,
        .tool_calls = &.{},
        .usage = null,
        .reasoning_content = reasoning,
        .owned = true,
    };
}

pub fn writeChatRequestJson(request: types.ChatRequest, writer: anytype) !void {
    try writer.writeAll("{\"model\":");
    try std.json.stringify(request.model, .{}, writer);
    try writer.writeAll(",\"messages\":[");
    for (request.messages, 0..) |message, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.writeAll("{\"role\":");
        try std.json.stringify(message.role, .{}, writer);
        try writer.writeAll(",\"content\":");
        try std.json.stringify(message.content, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"temperature\":");
    try std.json.stringify(request.temperature, .{}, writer);
    if (request.max_tokens) |max_tokens| {
        try writer.writeAll(",\"max_tokens\":");
        try writer.print("{d}", .{max_tokens});
    }
    try writer.writeByte('}');
}

fn parseResponseMessage(allocator: std.mem.Allocator, choice_value: std.json.Value) !types.ResponseMessage {
    const message_value = getObjectField(choice_value, "message") orelse return error.InvalidJson;
    const content = try optionalStringField(allocator, message_value, "content");
    errdefer if (content) |value| allocator.free(value);
    const reasoning_content = try optionalStringField(allocator, message_value, "reasoning_content");
    return .{
        .content = content,
        .reasoning_content = reasoning_content,
    };
}

fn optionalStringField(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
) !?[]u8 {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .null => null,
        .string => |inner| try allocator.dupe(u8, inner),
        else => error.InvalidJson,
    };
}

fn getObjectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

test "temperature adjustment matches restricted models" {
    try std.testing.expectEqual(@as(f64, 1.0), adjustTemperatureForModel("gpt-5", 0.2));
    try std.testing.expectEqual(@as(f64, 0.2), adjustTemperatureForModel("gpt-4o", 0.2));
}
