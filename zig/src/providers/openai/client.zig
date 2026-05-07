const std = @import("std");
const types = @import("types.zig");
const parser_types = @import("../../tool_call_parser/types.zig");
const parser_json = @import("../../tool_call_parser/json.zig");
const dispatcher = @import("../../runtime/agent/dispatcher.zig");

pub const BASE_URL = "https://api.openai.com/v1";
pub const TEMPERATURE_DEFAULT: f64 = 0.8;
const MISSING_TOOL_CALL_ID = "00000000-0000-4000-8000-000000000000";

pub const ProviderChatRequest = @import("../provider.zig").ChatRequest;

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

    pub fn buildNativeChatRequest(
        self: *const OpenAiProvider,
        allocator: std.mem.Allocator,
        messages: []const dispatcher.ChatMessage,
        tool_specs: ?[]const provider_handle.ToolSpec,
        tool_choice: ?[]const u8,
        model: []const u8,
        temperature: f64,
        max_tokens: ?u32,
    ) !types.NativeChatRequest {
        _ = self;
        const native_messages = try convertChatMessages(allocator, messages);
        errdefer freeNativeMessages(allocator, native_messages);

        var native_tools: ?[]types.NativeToolSpec = null;
        errdefer if (native_tools) |tools| freeNativeToolSpecs(allocator, tools);

        if (tool_specs) |specs| {
            if (specs.len != 0) {
                native_tools = try convertToolSpecs(allocator, specs);
            }
        }

        const tool_choice_owned = blk: {
            if (tool_choice) |choice| break :blk try allocator.dupe(u8, choice);
            if (native_tools != null) break :blk try allocator.dupe(u8, "auto");
            break :blk null;
        };
        errdefer if (tool_choice_owned) |choice| allocator.free(choice);

        const model_owned = try allocator.dupe(u8, model);
        errdefer allocator.free(model_owned);

        return .{
            .model = model_owned,
            .messages = native_messages,
            .temperature = adjustTemperatureForModel(model, temperature),
            .tools = native_tools,
            .tool_choice = tool_choice_owned,
            .max_tokens = max_tokens,
        };
    }

    /// Convert provider-agnostic `ToolSpec`s into OpenAI's native form.
    /// Mirrors Rust's `OpenAiProvider::convert_tools` at openai.rs:237-251.
    /// Each spec becomes a `NativeToolSpec{ kind: "function", function: ... }`.
    pub fn convertTools(
        self: *const OpenAiProvider,
        allocator: std.mem.Allocator,
        tool_specs: []const provider_handle.ToolSpec,
    ) ![]types.NativeToolSpec {
        _ = self;
        return convertToolSpecs(allocator, tool_specs);
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

    pub fn convertMessages(
        self: *const OpenAiProvider,
        allocator: std.mem.Allocator,
        messages: []const dispatcher.ChatMessage,
    ) ![]types.NativeMessage {
        _ = self;
        return convertChatMessages(allocator, messages);
    }

    pub fn chatWithTools(
        self: *const OpenAiProvider,
        allocator: std.mem.Allocator,
        messages: []const dispatcher.ChatMessage,
        tools: []const provider_handle.ToolSpec,
        model: []const u8,
        temperature: ?f64,
    ) !dispatcher.ChatResponse {
        return self.chatWithToolsWithChoice(allocator, messages, tools, null, model, temperature);
    }

    /// Mirrors Rust's `chat_with_history` trait default for OpenAI: pluck
    /// the first system message and the last user message, delegate to
    /// `chatWithSystem`. Used by `chat()` and the polymorphic vtable.
    pub fn chatWithHistory(
        self: *const OpenAiProvider,
        allocator: std.mem.Allocator,
        messages: []const dispatcher.ChatMessage,
        model: []const u8,
        temperature: ?f64,
    ) ![]u8 {
        const system_prompt = findFirstMessageContent(messages, "system");
        const user_message = findLastMessageContent(messages, "user") orelse "";
        return self.chatWithSystem(allocator, system_prompt, user_message, model, temperature);
    }

    pub fn chat(
        self: *const OpenAiProvider,
        allocator: std.mem.Allocator,
        request: ProviderChatRequest,
        model: []const u8,
        temperature: ?f64,
    ) !dispatcher.ChatResponse {
        if (request.tools) |tools| {
            if (tools.len != 0) {
                return self.chatWithToolsWithChoice(
                    allocator,
                    request.messages,
                    tools,
                    request.tool_choice,
                    model,
                    temperature,
                );
            }
        }

        const text = try self.chatWithHistory(allocator, request.messages, model, temperature);
        errdefer allocator.free(text);
        return .{
            .text = text,
            .tool_calls = &.{},
            .usage = null,
            .reasoning_content = null,
            .owned = true,
        };
    }

    pub fn provider(self: *OpenAiProvider) provider_handle.Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &openai_vtable };
    }

    fn chatWithToolsWithChoice(
        self: *const OpenAiProvider,
        allocator: std.mem.Allocator,
        messages: []const dispatcher.ChatMessage,
        tools: []const provider_handle.ToolSpec,
        tool_choice: ?[]const u8,
        model: []const u8,
        temperature: ?f64,
    ) !dispatcher.ChatResponse {
        _ = self.credential orelse return error.OpenAiApiKeyNotSet;

        var request = try self.buildNativeChatRequest(
            allocator,
            messages,
            tools,
            tool_choice,
            model,
            temperature orelse TEMPERATURE_DEFAULT,
            self.max_tokens,
        );
        defer request.deinit(allocator);

        var response = try self.sendNativeRequest(allocator, request);
        defer response.deinit(allocator);

        return try nativeChatResponseToChatResponse(allocator, response);
    }

    fn sendNativeRequest(
        self: *const OpenAiProvider,
        allocator: std.mem.Allocator,
        request: types.NativeChatRequest,
    ) !types.NativeChatResponse {
        const credential = self.credential orelse return error.OpenAiApiKeyNotSet;

        var payload = std.ArrayList(u8).init(allocator);
        defer payload.deinit();
        try writeNativeChatRequestJson(allocator, request, payload.writer());

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

        return try parseNativeApiChatResponseBody(allocator, body.items);
    }
};

const provider_handle = @import("../provider.zig");

const openai_vtable: provider_handle.Provider.VTable = .{
    .chatWithSystem = openAiChatWithSystem,
    .chatWithHistory = openAiChatWithHistory,
    .chatWithTools = openAiChatWithTools,
    .chat = openAiChat,
    .capabilities = .{
        .default_base_url = BASE_URL,
        .supports_native_tools = true,
    },
};

fn openAiChatWithSystem(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    system_prompt: ?[]const u8,
    message: []const u8,
    model: []const u8,
    temperature: ?f64,
) anyerror![]u8 {
    const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));
    return self.chatWithSystem(allocator, system_prompt, message, model, temperature);
}

fn openAiChatWithHistory(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    messages: []const dispatcher.ChatMessage,
    model: []const u8,
    temperature: ?f64,
) anyerror![]u8 {
    const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));
    return self.chatWithHistory(allocator, messages, model, temperature);
}

fn openAiChatWithTools(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    messages: []const dispatcher.ChatMessage,
    tools: []const provider_handle.ToolSpec,
    model: []const u8,
    temperature: ?f64,
) anyerror!dispatcher.ChatResponse {
    const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));
    return self.chatWithTools(allocator, messages, tools, model, temperature);
}

fn openAiChat(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: provider_handle.ChatRequest,
    model: []const u8,
    temperature: ?f64,
) anyerror!dispatcher.ChatResponse {
    const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));
    return self.chat(allocator, request, model, temperature);
}

const AssistantToolCallFields = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

fn convertChatMessages(
    allocator: std.mem.Allocator,
    messages: []const dispatcher.ChatMessage,
) ![]types.NativeMessage {
    var converted = std.ArrayList(types.NativeMessage).init(allocator);
    errdefer {
        for (converted.items) |*message| message.deinit(allocator);
        converted.deinit();
    }

    for (messages) |message| {
        if (std.mem.eql(u8, message.role, "assistant")) {
            if (try convertAssistantMessage(allocator, message)) |api_message| {
                try converted.append(api_message);
                continue;
            }
        }

        if (std.mem.eql(u8, message.role, "tool")) {
            if (try convertToolMessage(allocator, message)) |api_message| {
                try converted.append(api_message);
                continue;
            }
        }

        try converted.append(try types.NativeMessage.init(allocator, message.role, message.content));
    }

    return converted.toOwnedSlice();
}

fn convertAssistantMessage(
    allocator: std.mem.Allocator,
    message: dispatcher.ChatMessage,
) !?types.NativeMessage {
    var root = (try parser_types.parseJsonValueOwned(allocator, message.content)) orelse return null;
    defer parser_types.freeJsonValue(allocator, &root);

    const tool_calls_value = getObjectField(root, "tool_calls") orelse return null;
    if (tool_calls_value != .array) return null;

    var parsed_calls = std.ArrayList(AssistantToolCallFields).init(allocator);
    defer parsed_calls.deinit();
    for (tool_calls_value.array.items) |item| {
        const parsed = parseAssistantToolCallFields(item) orelse return null;
        try parsed_calls.append(parsed);
    }

    var native_calls = std.ArrayList(types.NativeToolCall).init(allocator);
    errdefer {
        for (native_calls.items) |*call| call.deinit(allocator);
        native_calls.deinit();
    }

    for (parsed_calls.items) |parsed| {
        const id_owned = try allocator.dupe(u8, parsed.id);
        errdefer allocator.free(id_owned);
        const kind_owned = try allocator.dupe(u8, "function");
        errdefer allocator.free(kind_owned);
        const name_owned = try allocator.dupe(u8, parsed.name);
        errdefer allocator.free(name_owned);
        const arguments_owned = try allocator.dupe(u8, parsed.arguments);
        errdefer allocator.free(arguments_owned);

        try native_calls.append(.{
            .id = id_owned,
            .kind = kind_owned,
            .function = .{
                .name = name_owned,
                .arguments = arguments_owned,
            },
        });
    }

    const tool_calls = try native_calls.toOwnedSlice();
    errdefer {
        for (tool_calls) |*call| call.deinit(allocator);
        allocator.free(tool_calls);
    }

    const role_owned = try allocator.dupe(u8, "assistant");
    errdefer allocator.free(role_owned);
    const content_owned = if (getObjectString(root, "content")) |content|
        try allocator.dupe(u8, content)
    else
        null;
    errdefer if (content_owned) |content| allocator.free(content);
    const reasoning_owned = if (getObjectString(root, "reasoning_content")) |reasoning|
        try allocator.dupe(u8, reasoning)
    else
        null;
    errdefer if (reasoning_owned) |reasoning| allocator.free(reasoning);

    return .{
        .role = role_owned,
        .content = content_owned,
        .tool_call_id = null,
        .tool_calls = tool_calls,
        .reasoning_content = reasoning_owned,
    };
}

fn parseAssistantToolCallFields(value: std.json.Value) ?AssistantToolCallFields {
    if (value != .object) return null;
    const id = getObjectString(value, "id") orelse return null;
    const name = getObjectString(value, "name") orelse return null;
    const arguments = getObjectString(value, "arguments") orelse return null;
    return .{ .id = id, .name = name, .arguments = arguments };
}

fn convertToolMessage(
    allocator: std.mem.Allocator,
    message: dispatcher.ChatMessage,
) !?types.NativeMessage {
    var root = (try parser_types.parseJsonValueOwned(allocator, message.content)) orelse return null;
    defer parser_types.freeJsonValue(allocator, &root);

    const role_owned = try allocator.dupe(u8, "tool");
    errdefer allocator.free(role_owned);
    const content_owned = if (getObjectString(root, "content")) |content|
        try allocator.dupe(u8, content)
    else
        null;
    errdefer if (content_owned) |content| allocator.free(content);
    const tool_call_id_owned = if (getObjectString(root, "tool_call_id")) |tool_call_id|
        try allocator.dupe(u8, tool_call_id)
    else
        null;
    errdefer if (tool_call_id_owned) |tool_call_id| allocator.free(tool_call_id);

    return .{
        .role = role_owned,
        .content = content_owned,
        .tool_call_id = tool_call_id_owned,
        .tool_calls = null,
        .reasoning_content = null,
    };
}

fn convertToolSpecs(
    allocator: std.mem.Allocator,
    tool_specs: []const provider_handle.ToolSpec,
) ![]types.NativeToolSpec {
    const owned = try allocator.alloc(types.NativeToolSpec, tool_specs.len);
    var count: usize = 0;
    errdefer {
        for (owned[0..count]) |*tool| tool.deinit(allocator);
        allocator.free(owned);
    }
    for (tool_specs) |spec| {
        const kind_owned = try allocator.dupe(u8, "function");
        errdefer allocator.free(kind_owned);
        const name_owned = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name_owned);
        const description_owned = try allocator.dupe(u8, spec.description);
        errdefer allocator.free(description_owned);
        var parameters_owned = try parser_types.cloneJsonValue(allocator, spec.parameters);
        errdefer parser_types.freeJsonValue(allocator, &parameters_owned);
        owned[count] = .{
            .kind = kind_owned,
            .function = .{
                .name = name_owned,
                .description = description_owned,
                .parameters = parameters_owned,
            },
        };
        count += 1;
    }
    return owned;
}

/// Validates a JSON value as a NativeToolSpec — mirrors Rust's
/// `parse_native_tool_spec` at openai.rs:104-116. Requires `type` to
/// be exactly `"function"`; any other value yields
/// `error.InvalidToolSpecType`.
pub fn parseNativeToolSpec(allocator: std.mem.Allocator, value: std.json.Value) !types.NativeToolSpec {
    const kind = getObjectString(value, "type") orelse return error.InvalidJson;
    if (!std.mem.eql(u8, kind, "function")) return error.InvalidToolSpecType;
    const function_value = getObjectField(value, "function") orelse return error.InvalidJson;
    const name = getObjectString(function_value, "name") orelse return error.InvalidJson;
    const description = getObjectString(function_value, "description") orelse return error.InvalidJson;
    const parameters = getObjectField(function_value, "parameters") orelse return error.InvalidJson;

    const kind_owned = try allocator.dupe(u8, kind);
    errdefer allocator.free(kind_owned);
    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);
    const description_owned = try allocator.dupe(u8, description);
    errdefer allocator.free(description_owned);
    var parameters_owned = try parser_types.cloneJsonValue(allocator, parameters);
    errdefer parser_types.freeJsonValue(allocator, &parameters_owned);

    return .{
        .kind = kind_owned,
        .function = .{
            .name = name_owned,
            .description = description_owned,
            .parameters = parameters_owned,
        },
    };
}

fn freeNativeMessages(allocator: std.mem.Allocator, messages: []types.NativeMessage) void {
    for (messages) |*message| message.deinit(allocator);
    allocator.free(messages);
}

fn freeNativeToolSpecs(allocator: std.mem.Allocator, tools: []types.NativeToolSpec) void {
    for (tools) |*tool| tool.deinit(allocator);
    allocator.free(tools);
}

pub fn parseNativeResponse(
    allocator: std.mem.Allocator,
    message: types.NativeResponseMessage,
) !dispatcher.ChatResponse {
    const text = try message.effectiveContent(allocator);
    errdefer if (text) |value| allocator.free(value);

    const reasoning_content = if (message.reasoning_content) |reasoning|
        try allocator.dupe(u8, reasoning)
    else
        null;
    errdefer if (reasoning_content) |reasoning| allocator.free(reasoning);

    var calls = std.ArrayList(dispatcher.ToolCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }

    if (message.tool_calls) |native_calls| {
        for (native_calls) |call| {
            const id_owned = try allocator.dupe(u8, call.id orelse MISSING_TOOL_CALL_ID);
            errdefer allocator.free(id_owned);
            const name_owned = try allocator.dupe(u8, call.function.name);
            errdefer allocator.free(name_owned);
            const arguments_owned = try allocator.dupe(u8, call.function.arguments);
            errdefer allocator.free(arguments_owned);

            try calls.append(.{
                .id = id_owned,
                .name = name_owned,
                .arguments = arguments_owned,
            });
        }
    }

    return .{
        .text = text,
        .tool_calls = if (calls.items.len == 0) &.{} else try calls.toOwnedSlice(),
        .usage = null,
        .reasoning_content = reasoning_content,
        .owned = true,
    };
}

pub fn parseNativeResponseBody(allocator: std.mem.Allocator, body: []const u8) !dispatcher.ChatResponse {
    var api_response = try parseNativeApiChatResponseBody(allocator, body);
    defer api_response.deinit(allocator);
    return try nativeChatResponseToChatResponse(allocator, api_response);
}

pub fn parseNativeApiChatResponseBody(allocator: std.mem.Allocator, body: []const u8) !types.NativeChatResponse {
    var root = (try parser_types.parseJsonValueOwned(allocator, body)) orelse return error.InvalidJson;
    defer parser_types.freeJsonValue(allocator, &root);

    const choices_value = getObjectField(root, "choices") orelse return error.InvalidJson;
    if (choices_value != .array) return error.InvalidJson;

    var choices = std.ArrayList(types.NativeChoice).init(allocator);
    errdefer {
        for (choices.items) |*choice| choice.deinit(allocator);
        choices.deinit();
    }

    for (choices_value.array.items) |choice_value| {
        try choices.append(try parseNativeChoice(allocator, choice_value));
    }

    const choices_owned = try choices.toOwnedSlice();
    errdefer {
        for (choices_owned) |*choice| choice.deinit(allocator);
        allocator.free(choices_owned);
    }
    const usage = if (getObjectField(root, "usage")) |usage_value|
        try parseUsageInfo(usage_value)
    else
        null;

    return .{
        .choices = choices_owned,
        .usage = usage,
    };
}

fn nativeChatResponseToChatResponse(
    allocator: std.mem.Allocator,
    api_response: types.NativeChatResponse,
) !dispatcher.ChatResponse {
    if (api_response.choices.len == 0) return error.NoResponseFromOpenAI;
    var result = try parseNativeResponse(allocator, api_response.choices[0].message);
    result.usage = usageFromNativeResponse(api_response);
    return result;
}

fn parseNativeChoice(allocator: std.mem.Allocator, choice_value: std.json.Value) !types.NativeChoice {
    const message_value = getObjectField(choice_value, "message") orelse return error.InvalidJson;
    return .{ .message = try parseNativeResponseMessage(allocator, message_value) };
}

fn parseNativeResponseMessage(
    allocator: std.mem.Allocator,
    message_value: std.json.Value,
) !types.NativeResponseMessage {
    const content = try optionalStringField(allocator, message_value, "content");
    errdefer if (content) |value| allocator.free(value);
    const reasoning_content = try optionalStringField(allocator, message_value, "reasoning_content");
    errdefer if (reasoning_content) |value| allocator.free(value);

    var tool_calls: ?[]types.NativeToolCall = null;
    errdefer if (tool_calls) |calls| {
        for (calls) |*call| call.deinit(allocator);
        allocator.free(calls);
    };

    if (getObjectField(message_value, "tool_calls")) |tool_calls_value| {
        if (tool_calls_value == .array) {
            var calls = std.ArrayList(types.NativeToolCall).init(allocator);
            errdefer {
                for (calls.items) |*call| call.deinit(allocator);
                calls.deinit();
            }
            for (tool_calls_value.array.items) |call_value| {
                try calls.append(try parseNativeToolCall(allocator, call_value));
            }
            tool_calls = try calls.toOwnedSlice();
        } else if (tool_calls_value != .null) {
            return error.InvalidJson;
        }
    }

    return .{
        .content = content,
        .reasoning_content = reasoning_content,
        .tool_calls = tool_calls,
    };
}

fn parseNativeToolCall(allocator: std.mem.Allocator, value: std.json.Value) !types.NativeToolCall {
    const function_value = getObjectField(value, "function") orelse return error.InvalidJson;
    const name = getObjectString(function_value, "name") orelse return error.InvalidJson;
    const arguments = getObjectString(function_value, "arguments") orelse return error.InvalidJson;

    const id_owned = try optionalStringField(allocator, value, "id");
    errdefer if (id_owned) |id| allocator.free(id);
    const kind_owned = try optionalStringField(allocator, value, "type");
    errdefer if (kind_owned) |kind| allocator.free(kind);
    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);
    const arguments_owned = try allocator.dupe(u8, arguments);
    errdefer allocator.free(arguments_owned);

    return .{
        .id = id_owned,
        .kind = kind_owned,
        .function = .{
            .name = name_owned,
            .arguments = arguments_owned,
        },
    };
}

fn parseUsageInfo(value: std.json.Value) !?types.UsageInfo {
    if (value == .null) return null;
    if (value != .object) return error.InvalidJson;
    return .{
        .prompt_tokens = getObjectU64(value, "prompt_tokens"),
        .completion_tokens = getObjectU64(value, "completion_tokens"),
        .prompt_tokens_details = if (getObjectField(value, "prompt_tokens_details")) |details|
            try parsePromptTokensDetails(details)
        else
            null,
    };
}

fn parsePromptTokensDetails(value: std.json.Value) !?types.PromptTokensDetails {
    if (value == .null) return null;
    if (value != .object) return error.InvalidJson;
    return .{ .cached_tokens = getObjectU64(value, "cached_tokens") };
}

fn usageFromNativeResponse(api_response: types.NativeChatResponse) ?dispatcher.TokenUsage {
    const usage = api_response.usage orelse return null;
    return .{
        .input_tokens = usage.prompt_tokens,
        .output_tokens = usage.completion_tokens,
        .cached_input_tokens = if (usage.prompt_tokens_details) |details| details.cached_tokens else null,
    };
}

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

pub fn writeNativeMessagesJson(
    allocator: std.mem.Allocator,
    messages: []const types.NativeMessage,
    writer: anytype,
) !void {
    try writer.writeByte('[');
    for (messages, 0..) |message, i| {
        if (i != 0) try writer.writeByte(',');
        try writeNativeMessageJson(allocator, message, writer);
    }
    try writer.writeByte(']');
}

pub fn writeNativeChatRequestJson(
    allocator: std.mem.Allocator,
    request: types.NativeChatRequest,
    writer: anytype,
) !void {
    try writer.writeAll("{\"model\":");
    try std.json.stringify(request.model, .{}, writer);
    try writer.writeAll(",\"messages\":");
    try writeNativeMessagesJson(allocator, request.messages, writer);
    try writer.writeAll(",\"temperature\":");
    try std.json.stringify(request.temperature, .{}, writer);
    if (request.tools) |tools| {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |tool, i| {
            if (i != 0) try writer.writeByte(',');
            try writeNativeToolSpecJson(allocator, tool, writer);
        }
        try writer.writeByte(']');
    }
    if (request.tool_choice) |tool_choice| {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.stringify(tool_choice, .{}, writer);
    }
    if (request.max_tokens) |max_tokens| {
        try writer.writeAll(",\"max_tokens\":");
        try writer.print("{d}", .{max_tokens});
    }
    try writer.writeByte('}');
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

fn writeNativeMessageJson(
    allocator: std.mem.Allocator,
    message: types.NativeMessage,
    writer: anytype,
) !void {
    try writer.writeAll("{\"role\":");
    try std.json.stringify(message.role, .{}, writer);
    if (message.content) |content| {
        try writer.writeAll(",\"content\":");
        try std.json.stringify(content, .{}, writer);
    }
    if (message.tool_call_id) |tool_call_id| {
        try writer.writeAll(",\"tool_call_id\":");
        try std.json.stringify(tool_call_id, .{}, writer);
    }
    if (message.tool_calls) |calls| {
        try writer.writeAll(",\"tool_calls\":[");
        for (calls, 0..) |call, i| {
            if (i != 0) try writer.writeByte(',');
            try writeNativeToolCallJson(allocator, call, writer);
        }
        try writer.writeByte(']');
    }
    if (message.reasoning_content) |reasoning| {
        try writer.writeAll(",\"reasoning_content\":");
        try std.json.stringify(reasoning, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeNativeToolCallJson(
    allocator: std.mem.Allocator,
    call: types.NativeToolCall,
    writer: anytype,
) !void {
    _ = allocator;
    try writer.writeByte('{');
    var wrote_field = false;
    if (call.id) |id| {
        try writer.writeAll("\"id\":");
        try std.json.stringify(id, .{}, writer);
        wrote_field = true;
    }
    if (call.kind) |kind| {
        if (wrote_field) try writer.writeByte(',');
        try writer.writeAll("\"type\":");
        try std.json.stringify(kind, .{}, writer);
        wrote_field = true;
    }
    if (wrote_field) try writer.writeByte(',');
    try writer.writeAll("\"function\":{\"name\":");
    try std.json.stringify(call.function.name, .{}, writer);
    try writer.writeAll(",\"arguments\":");
    try std.json.stringify(call.function.arguments, .{}, writer);
    try writer.writeAll("}}");
}

pub fn writeNativeToolSpecJson(
    allocator: std.mem.Allocator,
    tool: types.NativeToolSpec,
    writer: anytype,
) !void {
    try writer.writeAll("{\"type\":");
    try std.json.stringify(tool.kind, .{}, writer);
    try writer.writeAll(",\"function\":{\"name\":");
    try std.json.stringify(tool.function.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.stringify(tool.function.description, .{}, writer);
    try writer.writeAll(",\"parameters\":");
    try parser_json.writeCanonicalJsonValue(allocator, tool.function.parameters, writer);
    try writer.writeAll("}}");
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

fn getObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getObjectField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn getObjectU64(value: std.json.Value, key: []const u8) ?u64 {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .integer => |inner| if (inner >= 0) @intCast(inner) else null,
        .number_string => |raw| std.fmt.parseInt(u64, raw, 10) catch null,
        else => null,
    };
}

fn findFirstMessageContent(messages: []const dispatcher.ChatMessage, role: []const u8) ?[]const u8 {
    for (messages) |message| {
        if (std.mem.eql(u8, message.role, role)) return message.content;
    }
    return null;
}

fn findLastMessageContent(messages: []const dispatcher.ChatMessage, role: []const u8) ?[]const u8 {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, messages[i].role, role)) return messages[i].content;
    }
    return null;
}

test "temperature adjustment matches restricted models" {
    try std.testing.expectEqual(@as(f64, 1.0), adjustTemperatureForModel("gpt-5", 0.2));
    try std.testing.expectEqual(@as(f64, 0.2), adjustTemperatureForModel("gpt-4o", 0.2));
}

test "provider() handle aliases the concrete OpenAiProvider" {
    var concrete = try OpenAiProvider.new(std.testing.allocator, "test-key");
    defer concrete.deinit(std.testing.allocator);

    const handle = concrete.provider();
    try std.testing.expectEqual(@intFromPtr(&concrete), @intFromPtr(handle.ptr));
    try std.testing.expect(handle.vtable.chatWithSystem == openAiChatWithSystem);
}

test "OpenAI capabilities match Rust impl" {
    var concrete = try OpenAiProvider.new(std.testing.allocator, "test-key");
    defer concrete.deinit(std.testing.allocator);

    const handle = concrete.provider();
    try std.testing.expectEqual(@as(f64, 0.7), handle.defaultTemperature());
    try std.testing.expectEqual(@as(u32, 4096), handle.defaultMaxTokens());
    try std.testing.expectEqual(@as(u64, 120), handle.defaultTimeoutSecs());
    try std.testing.expectEqualStrings("https://api.openai.com/v1", handle.defaultBaseUrl().?);
    try std.testing.expectEqualStrings("chat_completions", handle.defaultWireApi());
    try std.testing.expect(handle.supportsNativeTools());
    try std.testing.expect(!handle.supportsVision());
    try std.testing.expect(!handle.supportsStreaming());
}

test "convertMessages extracts assistant native tool calls" {
    const messages = [_]dispatcher.ChatMessage{.{
        .role = "assistant",
        .content = "{\"content\":\"checking\",\"reasoning_content\":\"thinking\",\"tool_calls\":[{\"id\":\"call_1\",\"name\":\"shell.exec\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}]}",
    }};

    var provider = try OpenAiProvider.new(std.testing.allocator, "test-key");
    defer provider.deinit(std.testing.allocator);

    const converted = try provider.convertMessages(std.testing.allocator, &messages);
    defer freeNativeMessages(std.testing.allocator, converted);

    try std.testing.expectEqual(@as(usize, 1), converted.len);
    try std.testing.expectEqualStrings("assistant", converted[0].role);
    try std.testing.expectEqualStrings("checking", converted[0].content.?);
    try std.testing.expectEqualStrings("thinking", converted[0].reasoning_content.?);
    try std.testing.expectEqual(@as(usize, 1), converted[0].tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", converted[0].tool_calls.?[0].id.?);
    try std.testing.expectEqualStrings("function", converted[0].tool_calls.?[0].kind.?);
    try std.testing.expectEqualStrings("shell.exec", converted[0].tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", converted[0].tool_calls.?[0].function.arguments);
}

test "parseNativeResponseBody maps tool calls and usage" {
    const body =
        \\{"choices":[{"message":{"content":"","reasoning_content":"thinking","tool_calls":[{"id":"call_1","type":"function","function":{"name":"shell.exec","arguments":"{\"command\":\"pwd\"}"}}]}}],"usage":{"prompt_tokens":12,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":3}}}
    ;

    var response = try parseNativeResponseBody(std.testing.allocator, body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("thinking", response.text.?);
    try std.testing.expectEqualStrings("thinking", response.reasoning_content.?);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", response.tool_calls[0].id);
    try std.testing.expectEqualStrings("shell.exec", response.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", response.tool_calls[0].arguments);
    try std.testing.expectEqual(@as(?u64, 12), response.usage.?.input_tokens);
    try std.testing.expectEqual(@as(?u64, 5), response.usage.?.output_tokens);
    try std.testing.expectEqual(@as(?u64, 3), response.usage.?.cached_input_tokens);
}
