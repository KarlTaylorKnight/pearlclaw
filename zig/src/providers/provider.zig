//! Provider vtable handle. Concrete providers (OllamaProvider,
//! OpenAiProvider) expose `provider(self: *Self) Provider` returning
//! a handle that callers can use polymorphically.
//!
//! Phase 1 surface: chatWithSystem.
//! Phase 2B-1 added: Capabilities embedded by-value in VTable for
//! provider-family static defaults (default_temperature, default_max_tokens,
//! default_timeout_secs, default_base_url, default_wire_api,
//! supports_native_tools, supports_vision, supports_streaming).
//! Phase 2B-2 will append: chat, chatWithHistory, chatWithTools.
//!
//! The handle's ptr aliases the concrete provider; the caller is
//! responsible for keeping the concrete instance alive while the handle
//! is in use. Same lifetime contract as runtime/agent/dispatcher's
//! ToolDispatcher.

const std = @import("std");
const parser_types = @import("../tool_call_parser/types.zig");
const types = @import("types.zig");

pub const BASELINE_TEMPERATURE: f64 = 0.7;
pub const BASELINE_MAX_TOKENS: u32 = 4096;
pub const BASELINE_TIMEOUT_SECS: u64 = 120;
pub const BASELINE_WIRE_API: []const u8 = "chat_completions";

pub const ToolCall = types.ToolCall;
pub const TokenUsage = types.TokenUsage;
pub const ChatResponse = types.ChatResponse;
pub const ChatMessage = types.ChatMessage;
pub const ToolResultMessage = types.ToolResultMessage;
pub const AssistantToolCallsMessage = types.AssistantToolCallsMessage;
pub const ConversationMessage = types.ConversationMessage;

/// Static, provider-family defaults. Each provider declares deltas from
/// the baseline; unset fields take the struct defaults below, which mirror
/// the Rust trait defaults in `zeroclaw-api/src/provider.rs:301-359`.
pub const Capabilities = struct {
    default_temperature: f64 = BASELINE_TEMPERATURE,
    default_max_tokens: u32 = BASELINE_MAX_TOKENS,
    default_timeout_secs: u64 = BASELINE_TIMEOUT_SECS,
    default_base_url: ?[]const u8 = null,
    default_wire_api: []const u8 = BASELINE_WIRE_API,
    supports_native_tools: bool = false,
    supports_vision: bool = false,
    supports_streaming: bool = false,
    native_tool_calling: bool = false,
    vision: bool = false,
    prompt_caching: bool = false,
};

pub const ProviderCapabilities = Capabilities;

/// Provider-agnostic tool descriptor mirroring
/// `zeroclaw_api::tool::ToolSpec`. Each provider's `convertTools` turns
/// these into its native form (OpenAI `NativeToolSpec`, Ollama
/// `{"type":"function","function":{...}}` JSON).
///
/// Lifetime: most provider call paths pass borrowed fields and let
/// `convertTools` deep-copy them into provider-owned form. Specs returned by
/// `agent_tools.Tool.spec` are owned and should be released with `deinit`.
pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,

    pub fn deinit(self: *ToolSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        parser_types.freeJsonValue(allocator, &self.parameters);
        self.* = undefined;
    }
};

/// Polymorphic chat-request envelope used by `Provider.chat`. Mirrors the
/// `zeroclaw_api::provider::ChatRequest` shape, with `tool_choice` exposed
/// for providers that need it (OpenAI). Providers that don't honor a field
/// (e.g., Ollama ignores `tool_choice`) silently drop it.
pub const ChatRequest = struct {
    messages: []const ChatMessage,
    tools: ?[]const ToolSpec = null,
    tool_choice: ?[]const u8 = null,
};

/// A chunk of content from a streaming response.
pub const StreamChunk = struct {
    delta: []const u8,
    reasoning: ?[]const u8 = null,
    is_final: bool = false,
    token_count: usize = 0,

    pub fn initDelta(text: []const u8) StreamChunk {
        return .{
            .delta = text,
            .reasoning = null,
            .is_final = false,
            .token_count = 0,
        };
    }

    pub fn initReasoning(text: []const u8) StreamChunk {
        return .{
            .delta = "",
            .reasoning = text,
            .is_final = false,
            .token_count = 0,
        };
    }

    pub fn finalChunk() StreamChunk {
        return .{
            .delta = "",
            .reasoning = null,
            .is_final = true,
            .token_count = 0,
        };
    }

    pub fn initError(message: []const u8) StreamChunk {
        return .{
            .delta = message,
            .reasoning = null,
            .is_final = true,
            .token_count = 0,
        };
    }

    pub fn withTokenEstimate(self: StreamChunk) StreamChunk {
        var result = self;
        result.token_count = std.math.divCeil(usize, self.delta.len, 4) catch unreachable;
        return result;
    }
};

/// Structured events emitted by provider streaming APIs.
pub const StreamEvent = union(enum) {
    text_delta: StreamChunk,
    tool_call: ToolCall,
    pre_executed_tool_call: PreExecutedToolCall,
    pre_executed_tool_result: PreExecutedToolResult,
    final,

    pub const PreExecutedToolCall = struct {
        name: []const u8,
        args: []const u8,
    };

    pub const PreExecutedToolResult = struct {
        name: []const u8,
        output: []const u8,
    };

    pub fn fromChunk(chunk: StreamChunk) StreamEvent {
        if (chunk.is_final) return .final;
        return .{ .text_delta = chunk };
    }
};

/// Options for streaming chat requests.
pub const StreamOptions = struct {
    enabled: bool = false,
    count_tokens: bool = false,

    pub fn init(enabled: bool) StreamOptions {
        return .{ .enabled = enabled, .count_tokens = false };
    }

    pub fn withTokenCount(self: StreamOptions) StreamOptions {
        var result = self;
        result.count_tokens = true;
        return result;
    }
};

/// Streaming error tags. Lossy vs Rust's `StreamError` (`provider.rs:243-258`):
/// the Rust `Io(#[from] std::io::Error)` variant carries the underlying OS
/// error code, kind, and message; the Zig `error.Io` form drops that payload.
/// Accepted per Phase 3-F brief — adequate for the type-only port; revisit
/// when a real streaming consumer needs to distinguish read-timeout from
/// connection-reset etc.
pub const StreamError = error{ Http, Json, InvalidSse, Provider, Io };

/// Structured error returned when a requested capability is not supported.
pub const ProviderCapabilityError = struct {
    provider: []const u8,
    capability: []const u8,
    message: []const u8,
};

/// Provider-specific tool payload formats.
pub const ToolsPayload = union(enum) {
    gemini: Gemini,
    anthropic: Anthropic,
    openai: OpenAI,
    prompt_guided: PromptGuided,

    pub const Gemini = struct {
        function_declarations: []const std.json.Value,
    };

    pub const Anthropic = struct {
        tools: []const std.json.Value,
    };

    pub const OpenAI = struct {
        tools: []const std.json.Value,
    };

    pub const PromptGuided = struct {
        instructions: []const u8,
    };
};

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        chatWithSystem: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            system_prompt: ?[]const u8,
            message: []const u8,
            model: []const u8,
            temperature: ?f64,
        ) anyerror![]u8,
        chatWithHistory: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            messages: []const ChatMessage,
            model: []const u8,
            temperature: ?f64,
        ) anyerror![]u8,
        chatWithTools: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            messages: []const ChatMessage,
            tools: []const ToolSpec,
            model: []const u8,
            temperature: ?f64,
        ) anyerror!ChatResponse,
        chat: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            request: ChatRequest,
            model: []const u8,
            temperature: ?f64,
        ) anyerror!ChatResponse,
        capabilities: Capabilities = .{},
    };

    pub fn chatWithSystem(
        self: Provider,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: ?f64,
    ) ![]u8 {
        return self.vtable.chatWithSystem(
            self.ptr,
            allocator,
            system_prompt,
            message,
            model,
            temperature,
        );
    }

    pub fn chatWithHistory(
        self: Provider,
        allocator: std.mem.Allocator,
        messages: []const ChatMessage,
        model: []const u8,
        temperature: ?f64,
    ) ![]u8 {
        return self.vtable.chatWithHistory(self.ptr, allocator, messages, model, temperature);
    }

    pub fn chatWithTools(
        self: Provider,
        allocator: std.mem.Allocator,
        messages: []const ChatMessage,
        tools: []const ToolSpec,
        model: []const u8,
        temperature: ?f64,
    ) !ChatResponse {
        return self.vtable.chatWithTools(self.ptr, allocator, messages, tools, model, temperature);
    }

    pub fn chat(
        self: Provider,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: ?f64,
    ) !ChatResponse {
        return self.vtable.chat(self.ptr, allocator, request, model, temperature);
    }

    pub fn capabilities(self: Provider) Capabilities {
        return self.vtable.capabilities;
    }

    pub fn defaultTemperature(self: Provider) f64 {
        return self.vtable.capabilities.default_temperature;
    }

    pub fn defaultMaxTokens(self: Provider) u32 {
        return self.vtable.capabilities.default_max_tokens;
    }

    pub fn defaultTimeoutSecs(self: Provider) u64 {
        return self.vtable.capabilities.default_timeout_secs;
    }

    pub fn defaultBaseUrl(self: Provider) ?[]const u8 {
        return self.vtable.capabilities.default_base_url;
    }

    pub fn defaultWireApi(self: Provider) []const u8 {
        return self.vtable.capabilities.default_wire_api;
    }

    pub fn supportsNativeTools(self: Provider) bool {
        return self.vtable.capabilities.supports_native_tools or
            self.vtable.capabilities.native_tool_calling;
    }

    pub fn supportsVision(self: Provider) bool {
        return self.vtable.capabilities.supports_vision or self.vtable.capabilities.vision;
    }

    pub fn supportsStreaming(self: Provider) bool {
        return self.vtable.capabilities.supports_streaming;
    }

    pub fn supportsPromptCaching(self: Provider) bool {
        return self.vtable.capabilities.prompt_caching;
    }
};

/// Build tool instructions text for prompt-guided tool calling.
pub fn buildToolInstructionsText(allocator: std.mem.Allocator, tools: []const ToolSpec) ![]u8 {
    var instructions = std.ArrayList(u8).init(allocator);
    errdefer instructions.deinit();
    const writer = instructions.writer();

    try instructions.appendSlice("## Tool Use Protocol\n\n");
    try instructions.appendSlice("To use a tool, wrap a JSON object in <tool_call></tool_call> tags:\n\n");
    try instructions.appendSlice("<tool_call>\n");
    try instructions.appendSlice("{\"name\": \"tool_name\", \"arguments\": {\"param\": \"value\"}}");
    try instructions.appendSlice("\n</tool_call>\n\n");
    try instructions.appendSlice("You may use multiple tool calls in a single response. ");
    try instructions.appendSlice("After tool execution, results appear in <tool_result> tags. ");
    try instructions.appendSlice("Continue reasoning with the results until you can give a final answer.\n\n");
    try instructions.appendSlice("### Available Tools\n\n");

    for (tools) |tool| {
        try writer.print("**{s}**: {s}\n", .{ tool.name, tool.description });
        try instructions.appendSlice("Parameters: `");
        try writeJsonCanonical(allocator, tool.parameters, writer);
        try instructions.appendSlice("`\n\n");
    }

    return instructions.toOwnedSlice();
}

fn writeJsonCanonical(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    writer: anytype,
) anyerror!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |inner| try writer.writeAll(if (inner) "true" else "false"),
        .integer => |inner| try writer.print("{d}", .{inner}),
        .float => |inner| try std.json.stringify(inner, .{}, writer),
        .number_string => |inner| try writer.writeAll(inner),
        .string => |inner| try std.json.stringify(inner, .{}, writer),
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                try writeJsonCanonical(allocator, item, writer);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            var len: usize = 0;
            var count_it = object.iterator();
            while (count_it.next()) |_| len += 1;

            const keys = try allocator.alloc([]const u8, len);
            defer allocator.free(keys);

            var fill_it = object.iterator();
            var i: usize = 0;
            while (fill_it.next()) |entry| {
                keys[i] = entry.key_ptr.*;
                i += 1;
            }
            std.mem.sort([]const u8, keys, {}, stringLessThan);

            try writer.writeByte('{');
            for (keys, 0..) |key, key_index| {
                if (key_index != 0) try writer.writeByte(',');
                try std.json.stringify(key, .{}, writer);
                try writer.writeByte(':');
                try writeJsonCanonical(allocator, object.get(key).?, writer);
            }
            try writer.writeByte('}');
        },
    }
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

test "Provider vtable dispatches to concrete receiver across all four methods" {
    const Stub = struct {
        last_method: enum { none, system, history, tools, chat } = .none,
        last_system: ?[]const u8 = null,
        last_message: []const u8 = "",
        last_model: []const u8 = "",
        last_temperature: ?f64 = null,
        last_history_len: usize = 0,
        last_tools_len: usize = 0,
        last_tool_choice: ?[]const u8 = null,

        const Self = @This();

        fn chatWithSystem(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            system_prompt: ?[]const u8,
            message: []const u8,
            model: []const u8,
            temperature: ?f64,
        ) anyerror![]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.last_method = .system;
            self.last_system = system_prompt;
            self.last_message = message;
            self.last_model = model;
            self.last_temperature = temperature;
            return try allocator.dupe(u8, "stub-system");
        }

        fn chatWithHistory(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            messages: []const ChatMessage,
            model: []const u8,
            temperature: ?f64,
        ) anyerror![]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.last_method = .history;
            self.last_history_len = messages.len;
            self.last_model = model;
            self.last_temperature = temperature;
            return try allocator.dupe(u8, "stub-history");
        }

        fn chatWithTools(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            messages: []const ChatMessage,
            tools: []const ToolSpec,
            model: []const u8,
            temperature: ?f64,
        ) anyerror!ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.last_method = .tools;
            self.last_history_len = messages.len;
            self.last_tools_len = tools.len;
            self.last_model = model;
            self.last_temperature = temperature;
            const text = try allocator.dupe(u8, "stub-tools");
            return .{ .text = text, .owned = true };
        }

        fn chat(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            request: ChatRequest,
            model: []const u8,
            temperature: ?f64,
        ) anyerror!ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.last_method = .chat;
            self.last_history_len = request.messages.len;
            self.last_tools_len = if (request.tools) |t| t.len else 0;
            self.last_tool_choice = request.tool_choice;
            self.last_model = model;
            self.last_temperature = temperature;
            const text = try allocator.dupe(u8, "stub-chat");
            return .{ .text = text, .owned = true };
        }

        const vtable: Provider.VTable = .{
            .chatWithSystem = chatWithSystem,
            .chatWithHistory = chatWithHistory,
            .chatWithTools = chatWithTools,
            .chat = chat,
        };

        fn provider(self: *Self) Provider {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
    };

    var stub = Stub{};
    const handle = stub.provider();

    {
        const reply = try handle.chatWithSystem(std.testing.allocator, "sys", "ping", "m", 0.4);
        defer std.testing.allocator.free(reply);
        try std.testing.expectEqualStrings("stub-system", reply);
        try std.testing.expect(stub.last_method == .system);
        try std.testing.expectEqualStrings("sys", stub.last_system.?);
    }

    {
        const history = [_]ChatMessage{
            .{ .role = "user", .content = "hi" },
            .{ .role = "assistant", .content = "hello" },
        };
        const reply = try handle.chatWithHistory(std.testing.allocator, &history, "m", null);
        defer std.testing.allocator.free(reply);
        try std.testing.expectEqualStrings("stub-history", reply);
        try std.testing.expect(stub.last_method == .history);
        try std.testing.expectEqual(@as(usize, 2), stub.last_history_len);
    }

    {
        const history = [_]ChatMessage{.{ .role = "user", .content = "x" }};
        const tools = [_]ToolSpec{};
        var resp = try handle.chatWithTools(std.testing.allocator, &history, &tools, "m", 0.5);
        defer resp.deinit(std.testing.allocator);
        try std.testing.expect(stub.last_method == .tools);
        try std.testing.expectEqual(@as(usize, 0), stub.last_tools_len);
    }

    {
        const history = [_]ChatMessage{.{ .role = "user", .content = "x" }};
        var resp = try handle.chat(
            std.testing.allocator,
            .{ .messages = &history, .tool_choice = "auto" },
            "m",
            null,
        );
        defer resp.deinit(std.testing.allocator);
        try std.testing.expect(stub.last_method == .chat);
        try std.testing.expectEqualStrings("auto", stub.last_tool_choice.?);
    }
}

test "Capabilities defaults match Rust BASELINE_* constants" {
    const caps = Capabilities{};
    try std.testing.expectEqual(@as(f64, 0.7), caps.default_temperature);
    try std.testing.expectEqual(@as(u32, 4096), caps.default_max_tokens);
    try std.testing.expectEqual(@as(u64, 120), caps.default_timeout_secs);
    try std.testing.expectEqual(@as(?[]const u8, null), caps.default_base_url);
    try std.testing.expectEqualStrings("chat_completions", caps.default_wire_api);
    try std.testing.expect(!caps.supports_native_tools);
    try std.testing.expect(!caps.supports_vision);
    try std.testing.expect(!caps.supports_streaming);
    try std.testing.expect(!caps.native_tool_calling);
    try std.testing.expect(!caps.vision);
    try std.testing.expect(!caps.prompt_caching);
}

test "Capabilities alias accepts Rust field names without breaking existing supports accessors" {
    const caps = ProviderCapabilities{
        .native_tool_calling = true,
        .vision = true,
        .prompt_caching = true,
    };
    try std.testing.expect(caps.native_tool_calling);
    try std.testing.expect(caps.vision);
    try std.testing.expect(caps.prompt_caching);
}

test "StreamChunk helpers mirror Rust constructor semantics" {
    const delta_chunk = StreamChunk.initDelta("hello world").withTokenEstimate();
    try std.testing.expectEqualStrings("hello world", delta_chunk.delta);
    try std.testing.expectEqual(@as(?[]const u8, null), delta_chunk.reasoning);
    try std.testing.expect(!delta_chunk.is_final);
    try std.testing.expectEqual(@as(usize, 3), delta_chunk.token_count);

    const reasoning = StreamChunk.initReasoning("thinking");
    try std.testing.expectEqualStrings("", reasoning.delta);
    try std.testing.expectEqualStrings("thinking", reasoning.reasoning.?);
    try std.testing.expect(!reasoning.is_final);

    const final_chunk = StreamChunk.finalChunk();
    try std.testing.expect(final_chunk.is_final);
    try std.testing.expect(StreamEvent.fromChunk(final_chunk) == .final);

    const event = StreamEvent.fromChunk(delta_chunk);
    try std.testing.expect(event == .text_delta);
    try std.testing.expectEqualStrings("hello world", event.text_delta.delta);
}

fn buildToolInstructionsTextOomImpl(allocator: std.mem.Allocator, tools: []const ToolSpec) !void {
    const text = try buildToolInstructionsText(allocator, tools);
    allocator.free(text);
}

test "buildToolInstructionsText is OOM safe across multiple tools with nested schemas" {
    const allocator = std.testing.allocator;
    var parsed_a = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"type\":\"object\",\"required\":[\"z\",\"a\"],\"properties\":{\"z\":{\"type\":\"string\"},\"a\":{\"type\":\"integer\"}}}",
        .{},
    );
    defer parsed_a.deinit();
    var parsed_b = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\",\"enum\":[\"x\",\"y\"]}}}",
        .{},
    );
    defer parsed_b.deinit();

    const tools = [_]ToolSpec{
        .{ .name = "lookup", .description = "Look up a thing", .parameters = parsed_a.value },
        .{ .name = "search", .description = "Search for items", .parameters = parsed_b.value },
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        buildToolInstructionsTextOomImpl,
        .{@as([]const ToolSpec, &tools)},
    );
}

test "buildToolInstructionsText matches Rust prompt-guided format with sorted JSON schema keys" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"type\":\"object\",\"required\":[\"z\"],\"properties\":{\"z\":{\"type\":\"string\"},\"a\":{\"type\":\"integer\"}}}",
        .{},
    );
    defer parsed.deinit();

    const tools = [_]ToolSpec{.{
        .name = "lookup",
        .description = "Look up a thing",
        .parameters = parsed.value,
    }};
    const instructions = try buildToolInstructionsText(allocator, &tools);
    defer allocator.free(instructions);

    const expected =
        "## Tool Use Protocol\n\n" ++
        "To use a tool, wrap a JSON object in <tool_call></tool_call> tags:\n\n" ++
        "<tool_call>\n" ++
        "{\"name\": \"tool_name\", \"arguments\": {\"param\": \"value\"}}\n" ++
        "</tool_call>\n\n" ++
        "You may use multiple tool calls in a single response. " ++
        "After tool execution, results appear in <tool_result> tags. " ++
        "Continue reasoning with the results until you can give a final answer.\n\n" ++
        "### Available Tools\n\n" ++
        "**lookup**: Look up a thing\n" ++
        "Parameters: `{\"properties\":{\"a\":{\"type\":\"integer\"},\"z\":{\"type\":\"string\"}},\"required\":[\"z\"],\"type\":\"object\"}`\n\n";
    try std.testing.expectEqualStrings(expected, instructions);
}
