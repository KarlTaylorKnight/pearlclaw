const std = @import("std");
const types = @import("types.zig");
const parser_types = @import("../../tool_call_parser/types.zig");
const parser_json = @import("../../tool_call_parser/json.zig");
const dispatcher = @import("../../runtime/agent/dispatcher.zig");

pub const BASE_URL = "http://localhost:11434";
pub const TEMPERATURE_DEFAULT: f64 = 0.8;

pub const ProviderChatRequest = @import("../provider.zig").ChatRequest;

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

        const api_messages = try messages.toOwnedSlice();
        defer freeMessages(allocator, api_messages);
        messages = std.ArrayList(types.Message).init(allocator);

        var response = try self.sendRequest(
            allocator,
            api_messages,
            model,
            temperature orelse TEMPERATURE_DEFAULT,
            null,
        );
        defer response.deinit(allocator);

        if (response.message.tool_calls.len != 0) {
            return try formatToolCallsForLoop(allocator, response.message.tool_calls);
        }

        if (try effectiveContent(allocator, response.message.content, response.message.thinking)) |content| {
            return content;
        }

        return try fallbackTextForEmptyContent(allocator, model, response.message.thinking);
    }

    pub fn convertMessages(
        self: *const OllamaProvider,
        allocator: std.mem.Allocator,
        messages: []const dispatcher.ChatMessage,
    ) ![]types.Message {
        _ = self;
        var tool_name_by_id = std.StringHashMap([]u8).init(allocator);
        defer freeToolNameMap(allocator, &tool_name_by_id);

        var converted = std.ArrayList(types.Message).init(allocator);
        errdefer {
            for (converted.items) |*entry| entry.deinit(allocator);
            converted.deinit();
        }

        for (messages) |message| {
            if (std.mem.eql(u8, message.role, "assistant")) {
                if (try convertAssistantMessage(allocator, message, &tool_name_by_id)) |api_message| {
                    try converted.append(api_message);
                    continue;
                }
            }

            if (std.mem.eql(u8, message.role, "tool")) {
                if (try convertToolMessage(allocator, message, &tool_name_by_id)) |api_message| {
                    try converted.append(api_message);
                    continue;
                }
            }

            if (std.mem.eql(u8, message.role, "user")) {
                {
                    const role_owned = try allocator.dupe(u8, "user");
                    errdefer allocator.free(role_owned);
                    var converted_user = try convertUserMessageContent(allocator, message.content);
                    errdefer converted_user.deinit(allocator);
                    try converted.append(.{
                        .role = role_owned,
                        .content = converted_user.content,
                        .images = converted_user.images,
                        .tool_calls = null,
                        .tool_name = null,
                    });
                }
                continue;
            }

            try converted.append(try types.Message.init(allocator, message.role, message.content));
        }

        return converted.toOwnedSlice();
    }

    pub fn chatWithHistory(
        self: *const OllamaProvider,
        allocator: std.mem.Allocator,
        messages: []const dispatcher.ChatMessage,
        model: []const u8,
        temperature: ?f64,
    ) ![]u8 {
        const api_messages = try self.convertMessages(allocator, messages);
        defer freeMessages(allocator, api_messages);

        var response = try self.sendRequest(
            allocator,
            api_messages,
            model,
            temperature orelse TEMPERATURE_DEFAULT,
            null,
        );
        defer response.deinit(allocator);

        if (response.message.tool_calls.len != 0) {
            return try formatToolCallsForLoop(allocator, response.message.tool_calls);
        }

        if (try effectiveContent(allocator, response.message.content, response.message.thinking)) |content| {
            return content;
        }

        return try fallbackTextForEmptyContent(allocator, model, response.message.thinking);
    }

    pub fn chatWithTools(
        self: *const OllamaProvider,
        allocator: std.mem.Allocator,
        messages: []const dispatcher.ChatMessage,
        tools: []const provider_handle.ToolSpec,
        model: []const u8,
        temperature: ?f64,
    ) !dispatcher.ChatResponse {
        const api_messages = try self.convertMessages(allocator, messages);
        defer freeMessages(allocator, api_messages);

        var converted_tools: ?[]std.json.Value = null;
        defer if (converted_tools) |values| {
            for (values) |*v| parser_types.freeJsonValue(allocator, v);
            allocator.free(values);
        };
        if (tools.len != 0) {
            converted_tools = try self.convertTools(allocator, tools);
        }
        const tools_opt: ?[]const std.json.Value = converted_tools;

        var response = try self.sendRequest(
            allocator,
            api_messages,
            model,
            temperature orelse TEMPERATURE_DEFAULT,
            tools_opt,
        );
        defer response.deinit(allocator);

        return try apiResponseToToolChatResponse(allocator, response, model);
    }

    /// Convert provider-agnostic `ToolSpec`s into Ollama's request-tools
    /// JSON shape: `{"type":"function","function":{"name","description","parameters"}}`.
    /// Mirrors Rust's inline mapping at ollama.rs:917-944.
    pub fn convertTools(
        self: *const OllamaProvider,
        allocator: std.mem.Allocator,
        tool_specs: []const provider_handle.ToolSpec,
    ) ![]std.json.Value {
        _ = self;
        const owned = try allocator.alloc(std.json.Value, tool_specs.len);
        var count: usize = 0;
        errdefer {
            for (owned[0..count]) |*v| parser_types.freeJsonValue(allocator, v);
            allocator.free(owned);
        }
        for (tool_specs) |spec| {
            owned[count] = try toolSpecToOllamaJson(allocator, spec);
            count += 1;
        }
        return owned;
    }

    pub fn chat(
        self: *const OllamaProvider,
        allocator: std.mem.Allocator,
        request: ProviderChatRequest,
        model: []const u8,
        temperature: ?f64,
    ) !dispatcher.ChatResponse {
        if (request.tools) |tools| {
            if (tools.len != 0 and self.supportsNativeTools()) {
                return try self.chatWithTools(allocator, request.messages, tools, model, temperature);
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

    pub fn supportsNativeTools(self: *const OllamaProvider) bool {
        _ = self;
        return true;
    }

    pub fn sendRequest(
        self: *const OllamaProvider,
        allocator: std.mem.Allocator,
        messages: []const types.Message,
        model: []const u8,
        temperature: f64,
        tools: ?[]const std.json.Value,
    ) !types.ApiChatResponse {
        return self.sendRequestInner(
            allocator,
            messages,
            model,
            temperature,
            shouldUseAuth(self),
            tools,
            self.reasoning_enabled,
        ) catch |first_err| {
            if (self.reasoning_enabled == true) {
                return self.sendRequestInner(
                    allocator,
                    messages,
                    model,
                    temperature,
                    shouldUseAuth(self),
                    tools,
                    null,
                ) catch {
                    return first_err;
                };
            }
            return first_err;
        };
    }

    fn sendRequestInner(
        self: *const OllamaProvider,
        allocator: std.mem.Allocator,
        messages: []const types.Message,
        model: []const u8,
        temperature: f64,
        should_auth: bool,
        tools: ?[]const std.json.Value,
        think: ?bool,
    ) !types.ApiChatResponse {
        const request_messages = try cloneMessages(allocator, messages);
        var request = try self.buildChatRequestWithThink(
            allocator,
            request_messages,
            model,
            temperature,
            tools,
            think,
        );
        defer request.deinit(allocator);

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
            if (should_auth) {
                if (self.api_key) |key| {
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

        return try parseApiChatResponseBody(allocator, body.items);
    }

    /// GET `{base_url}/api/tags`. Bearer auth iff the endpoint is non-local
    /// AND `api_key` is set. Returns the model name list. Mirrors Rust at
    /// ollama.rs:960-983.
    pub fn listModels(
        self: *const OllamaProvider,
        allocator: std.mem.Allocator,
    ) ![][]u8 {
        const url = try std.fmt.allocPrint(allocator, "{s}/api/tags", .{self.base_url});
        defer allocator.free(url);

        var body = std.ArrayList(u8).init(allocator);
        defer body.deinit();

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        var bearer: ?[]u8 = null;
        defer if (bearer) |value| allocator.free(value);
        const auth_header: std.http.Client.Request.Headers.Value = blk: {
            if (shouldUseAuth(self)) {
                if (self.api_key) |key| {
                    bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
                    break :blk .{ .override = bearer.? };
                }
            }
            break :blk .default;
        };

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_storage = .{ .dynamic = &body },
            .headers = .{ .authorization = auth_header },
        });
        if (result.status.class() != .success) return error.OllamaHttpError;

        return try parseModelsResponseBody(allocator, body.items);
    }

    pub fn provider(self: *OllamaProvider) provider_handle.Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &ollama_vtable };
    }
};

const provider_handle = @import("../provider.zig");

const ollama_vtable: provider_handle.Provider.VTable = .{
    .chatWithSystem = ollamaChatWithSystem,
    .chatWithHistory = ollamaChatWithHistory,
    .chatWithTools = ollamaChatWithTools,
    .chat = ollamaChat,
    .capabilities = .{
        .default_temperature = TEMPERATURE_DEFAULT,
        .default_timeout_secs = 600,
        .default_base_url = BASE_URL,
        .supports_native_tools = false,
        .supports_vision = true,
    },
};

fn ollamaChatWithSystem(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    system_prompt: ?[]const u8,
    message: []const u8,
    model: []const u8,
    temperature: ?f64,
) anyerror![]u8 {
    const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
    return self.chatWithSystem(allocator, system_prompt, message, model, temperature);
}

fn ollamaChatWithHistory(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    messages: []const dispatcher.ChatMessage,
    model: []const u8,
    temperature: ?f64,
) anyerror![]u8 {
    const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
    return self.chatWithHistory(allocator, messages, model, temperature);
}

fn ollamaChatWithTools(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    messages: []const dispatcher.ChatMessage,
    tools: []const provider_handle.ToolSpec,
    model: []const u8,
    temperature: ?f64,
) anyerror!dispatcher.ChatResponse {
    const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
    return self.chatWithTools(allocator, messages, tools, model, temperature);
}

fn ollamaChat(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: provider_handle.ChatRequest,
    model: []const u8,
    temperature: ?f64,
) anyerror!dispatcher.ChatResponse {
    const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
    return self.chat(allocator, request, model, temperature);
}

const ConvertedUserMessageContent = struct {
    content: ?[]u8 = null,
    images: ?[][]u8 = null,

    fn deinit(self: *ConvertedUserMessageContent, allocator: std.mem.Allocator) void {
        if (self.content) |content| allocator.free(content);
        if (self.images) |images| {
            for (images) |image| allocator.free(image);
            allocator.free(images);
        }
        self.* = undefined;
    }
};

const AssistantToolCallFields = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

fn convertUserMessageContent(
    allocator: std.mem.Allocator,
    content: []const u8,
) !ConvertedUserMessageContent {
    // TODO(Phase 3: multimodal image extraction): parse image markers into Ollama images.
    return .{
        .content = try allocator.dupe(u8, content),
        .images = null,
    };
}

fn convertAssistantMessage(
    allocator: std.mem.Allocator,
    message: dispatcher.ChatMessage,
    tool_name_by_id: *std.StringHashMap([]u8),
) !?types.Message {
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

    var outgoing = std.ArrayList(types.OutgoingToolCall).init(allocator);
    errdefer {
        for (outgoing.items) |*call| call.deinit(allocator);
        outgoing.deinit();
    }

    for (parsed_calls.items) |parsed| {
        var arguments = try parseToolArguments(allocator, parsed.arguments);
        errdefer parser_types.freeJsonValue(allocator, &arguments);
        const kind_owned = try allocator.dupe(u8, "function");
        errdefer allocator.free(kind_owned);
        const name_owned = try allocator.dupe(u8, parsed.name);
        errdefer allocator.free(name_owned);

        try rememberToolNameById(allocator, tool_name_by_id, parsed.id, parsed.name);
        try outgoing.append(.{
            .kind = kind_owned,
            .function = .{
                .name = name_owned,
                .arguments = arguments,
            },
        });
    }

    const calls = try outgoing.toOwnedSlice();
    errdefer {
        for (calls) |*call| call.deinit(allocator);
        allocator.free(calls);
    }

    const role_owned = try allocator.dupe(u8, "assistant");
    errdefer allocator.free(role_owned);
    const content_owned = if (getObjectString(root, "content")) |content|
        try allocator.dupe(u8, content)
    else
        null;
    errdefer if (content_owned) |content| allocator.free(content);

    return .{
        .role = role_owned,
        .content = content_owned,
        .images = null,
        .tool_calls = calls,
        .tool_name = null,
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
    tool_name_by_id: *std.StringHashMap([]u8),
) !?types.Message {
    var root = (try parser_types.parseJsonValueOwned(allocator, message.content)) orelse return null;
    defer parser_types.freeJsonValue(allocator, &root);

    const tool_name_owned = blk: {
        if (getObjectString(root, "tool_name")) |tool_name| {
            break :blk try allocator.dupe(u8, tool_name);
        }
        if (getObjectString(root, "tool_call_id")) |id| {
            if (tool_name_by_id.get(id)) |tool_name| {
                break :blk try allocator.dupe(u8, tool_name);
            }
        }
        break :blk null;
    };
    errdefer if (tool_name_owned) |tool_name| allocator.free(tool_name);

    const content_owned = blk: {
        if (getObjectString(root, "content")) |content| {
            break :blk try allocator.dupe(u8, content);
        }
        if (std.mem.trim(u8, message.content, " \t\r\n").len != 0) {
            break :blk try allocator.dupe(u8, message.content);
        }
        break :blk null;
    };
    errdefer if (content_owned) |content| allocator.free(content);

    const role_owned = try allocator.dupe(u8, "tool");
    errdefer allocator.free(role_owned);

    return .{
        .role = role_owned,
        .content = content_owned,
        .images = null,
        .tool_calls = null,
        .tool_name = tool_name_owned,
    };
}

fn rememberToolNameById(
    allocator: std.mem.Allocator,
    tool_name_by_id: *std.StringHashMap([]u8),
    id: []const u8,
    name: []const u8,
) !void {
    const id_owned = try allocator.dupe(u8, id);
    errdefer allocator.free(id_owned);
    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);

    if (tool_name_by_id.fetchRemove(id)) |old| {
        allocator.free(old.key);
        allocator.free(old.value);
    }
    try tool_name_by_id.put(id_owned, name_owned);
}

fn freeToolNameMap(
    allocator: std.mem.Allocator,
    tool_name_by_id: *std.StringHashMap([]u8),
) void {
    var iterator = tool_name_by_id.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    tool_name_by_id.deinit();
}

fn cloneMessages(allocator: std.mem.Allocator, messages: []const types.Message) ![]types.Message {
    var cloned = std.ArrayList(types.Message).init(allocator);
    errdefer {
        for (cloned.items) |*message| message.deinit(allocator);
        cloned.deinit();
    }
    for (messages) |message| {
        try cloned.append(try cloneMessage(allocator, message));
    }
    return cloned.toOwnedSlice();
}

fn cloneMessage(allocator: std.mem.Allocator, message: types.Message) !types.Message {
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
    calls: []const types.OutgoingToolCall,
) ![]types.OutgoingToolCall {
    const cloned = try allocator.alloc(types.OutgoingToolCall, calls.len);
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
            var arguments = try parser_types.cloneJsonValue(allocator, call.function.arguments);
            errdefer parser_types.freeJsonValue(allocator, &arguments);

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

fn freeMessages(allocator: std.mem.Allocator, messages: []const types.Message) void {
    for (messages) |message| {
        var owned = message;
        owned.deinit(allocator);
    }
    allocator.free(messages);
}

fn freeImages(allocator: std.mem.Allocator, images: [][]u8) void {
    for (images) |image| allocator.free(image);
    allocator.free(images);
}

fn freeOutgoingToolCalls(allocator: std.mem.Allocator, calls: []types.OutgoingToolCall) void {
    for (calls) |*call| call.deinit(allocator);
    allocator.free(calls);
}

fn shouldUseAuth(self: *const OllamaProvider) bool {
    return self.api_key != null and !isLocalEndpoint(self.base_url);
}

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

fn toolSpecToOllamaJson(
    allocator: std.mem.Allocator,
    spec: provider_handle.ToolSpec,
) !std.json.Value {
    // parser_types.freeJsonValue frees both keys and values via the
    // allocator, so every key here must be allocator-duped (NOT a string
    // literal). Each block scopes the per-key/value errdefers so they
    // expire once `put` succeeds — the outer `function_obj` / `outer_obj`
    // errdefer takes over as the owner.
    var function_obj = std.json.ObjectMap.init(allocator);
    errdefer freeOwnedJsonObject(allocator, &function_obj);

    try putOwnedString(allocator, &function_obj, "name", spec.name);
    try putOwnedString(allocator, &function_obj, "description", spec.description);
    try putOwnedClonedValue(allocator, &function_obj, "parameters", spec.parameters);

    var outer_obj = std.json.ObjectMap.init(allocator);
    errdefer freeOwnedJsonObject(allocator, &outer_obj);

    try putOwnedString(allocator, &outer_obj, "type", "function");
    // Reserve capacity so the final put can't fail — once it succeeds,
    // function_obj is owned by outer_obj. Failure here would leave both
    // function_obj and outer_obj live, double-freeing on errdefer.
    try outer_obj.ensureUnusedCapacity(1);
    {
        const function_key = try allocator.dupe(u8, "function");
        errdefer allocator.free(function_key);
        outer_obj.putAssumeCapacity(function_key, .{ .object = function_obj });
    }

    return .{ .object = outer_obj };
}

fn putOwnedString(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: []const u8,
) !void {
    const key_owned = try allocator.dupe(u8, key);
    errdefer allocator.free(key_owned);
    const value_owned = try allocator.dupe(u8, value);
    errdefer allocator.free(value_owned);
    try object.ensureUnusedCapacity(1);
    object.putAssumeCapacity(key_owned, .{ .string = value_owned });
}

fn putOwnedClonedValue(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) !void {
    const key_owned = try allocator.dupe(u8, key);
    errdefer allocator.free(key_owned);
    var cloned = try parser_types.cloneJsonValue(allocator, value);
    errdefer parser_types.freeJsonValue(allocator, &cloned);
    try object.ensureUnusedCapacity(1);
    object.putAssumeCapacity(key_owned, cloned);
}

fn freeOwnedJsonObject(allocator: std.mem.Allocator, object: *std.json.ObjectMap) void {
    var it = object.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        var v = entry.value_ptr.*;
        parser_types.freeJsonValue(allocator, &v);
    }
    object.deinit();
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

/// Parse Ollama's `/api/tags` response: `{"models": [{"name": "..."}, ...]}`.
/// Returns the list of model names; caller owns each name and the outer
/// slice. Mirrors Rust at ollama.rs:972-982.
pub fn parseModelsResponseBody(allocator: std.mem.Allocator, body: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const models_value = getObjectField(parsed.value, "models") orelse return error.InvalidJson;
    if (models_value != .array) return error.InvalidJson;

    var names = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit();
    }

    for (models_value.array.items) |item| {
        if (item != .object) return error.InvalidJson;
        const name = item.object.get("name") orelse return error.InvalidJson;
        if (name != .string) return error.InvalidJson;
        try names.append(try allocator.dupe(u8, name.string));
    }

    return try names.toOwnedSlice();
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

fn apiResponseToToolChatResponse(
    allocator: std.mem.Allocator,
    api_response: types.ApiChatResponse,
    model: []const u8,
) !dispatcher.ChatResponse {
    const usage = usageFromApiResponse(api_response);
    const reasoning_content = if (api_response.message.thinking) |thinking|
        try allocator.dupe(u8, thinking)
    else
        null;
    errdefer if (reasoning_content) |reasoning| allocator.free(reasoning);

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

        const text = try effectiveContent(allocator, api_response.message.content, api_response.message.thinking);
        errdefer if (text) |content| allocator.free(content);
        return .{
            .text = text,
            .tool_calls = try calls.toOwnedSlice(),
            .usage = usage,
            .reasoning_content = reasoning_content,
            .owned = true,
        };
    }

    const text = if (try effectiveContent(allocator, api_response.message.content, api_response.message.thinking)) |content|
        content
    else
        try fallbackTextForEmptyContent(allocator, model, api_response.message.thinking);
    errdefer allocator.free(text);

    return .{
        .text = text,
        .tool_calls = &.{},
        .usage = usage,
        .reasoning_content = reasoning_content,
        .owned = true,
    };
}

fn usageFromApiResponse(api_response: types.ApiChatResponse) ?dispatcher.TokenUsage {
    return if (api_response.prompt_eval_count != null or api_response.eval_count != null)
        .{
            .input_tokens = api_response.prompt_eval_count,
            .output_tokens = api_response.eval_count,
            .cached_input_tokens = null,
        }
    else
        null;
}

pub fn writeMessagesJson(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    writer: anytype,
) !void {
    try writer.writeByte('[');
    for (messages, 0..) |message, i| {
        if (i != 0) try writer.writeByte(',');
        try writeMessageJson(allocator, message, writer);
    }
    try writer.writeByte(']');
}

pub fn writeChatRequestJson(
    allocator: std.mem.Allocator,
    request: types.ChatRequest,
    writer: anytype,
) !void {
    try writer.writeAll("{\"model\":");
    try std.json.stringify(request.model, .{}, writer);
    try writer.writeAll(",\"messages\":");
    try writeMessagesJson(allocator, request.messages, writer);
    try writer.writeAll(",\"stream\":false,\"options\":{\"temperature\":");
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

test "provider() handle aliases the concrete OllamaProvider" {
    var concrete = try OllamaProvider.new(std.testing.allocator, null, null);
    defer concrete.deinit(std.testing.allocator);

    const handle = concrete.provider();
    try std.testing.expectEqual(@intFromPtr(&concrete), @intFromPtr(handle.ptr));
    try std.testing.expect(handle.vtable.chatWithSystem == ollamaChatWithSystem);
}

test "Ollama capabilities match Rust impl" {
    var concrete = try OllamaProvider.new(std.testing.allocator, null, null);
    defer concrete.deinit(std.testing.allocator);

    const handle = concrete.provider();
    try std.testing.expectEqual(@as(f64, 0.8), handle.defaultTemperature());
    try std.testing.expectEqual(@as(u32, 4096), handle.defaultMaxTokens());
    try std.testing.expectEqual(@as(u64, 600), handle.defaultTimeoutSecs());
    try std.testing.expectEqualStrings("http://localhost:11434", handle.defaultBaseUrl().?);
    try std.testing.expectEqualStrings("chat_completions", handle.defaultWireApi());
    try std.testing.expect(!handle.supportsNativeTools());
    try std.testing.expect(handle.supportsVision());
    try std.testing.expect(!handle.supportsStreaming());
}

test "convertMessages extracts assistant tool calls" {
    var provider = try OllamaProvider.new(std.testing.allocator, null, null);
    defer provider.deinit(std.testing.allocator);

    const history = [_]dispatcher.ChatMessage{.{
        .role = "assistant",
        .content = "{\"content\":\"checking\",\"tool_calls\":[{\"id\":\"call_1\",\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}]}",
    }};

    const converted = try provider.convertMessages(std.testing.allocator, &history);
    defer freeMessages(std.testing.allocator, converted);

    try std.testing.expectEqual(@as(usize, 1), converted.len);
    try std.testing.expectEqualStrings("assistant", converted[0].role);
    try std.testing.expectEqualStrings("checking", converted[0].content.?);
    try std.testing.expectEqual(@as(usize, 1), converted[0].tool_calls.?.len);
    try std.testing.expectEqualStrings("function", converted[0].tool_calls.?[0].kind);
    try std.testing.expectEqualStrings("shell", converted[0].tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings(
        "pwd",
        converted[0].tool_calls.?[0].function.arguments.object.get("command").?.string,
    );
}

test "convertMessages resolves tool role name by assistant id" {
    var provider = try OllamaProvider.new(std.testing.allocator, null, null);
    defer provider.deinit(std.testing.allocator);

    const history = [_]dispatcher.ChatMessage{
        .{
            .role = "assistant",
            .content = "{\"content\":\"\",\"tool_calls\":[{\"id\":\"call_shell\",\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}]}",
        },
        .{
            .role = "tool",
            .content = "{\"tool_call_id\":\"call_shell\",\"content\":\"/tmp/project\"}",
        },
    };

    const converted = try provider.convertMessages(std.testing.allocator, &history);
    defer freeMessages(std.testing.allocator, converted);

    try std.testing.expectEqual(@as(usize, 2), converted.len);
    try std.testing.expectEqualStrings("tool", converted[1].role);
    try std.testing.expectEqualStrings("/tmp/project", converted[1].content.?);
    try std.testing.expectEqualStrings("shell", converted[1].tool_name.?);
}
