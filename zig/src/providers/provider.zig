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
const dispatcher = @import("../runtime/agent/dispatcher.zig");

pub const BASELINE_TEMPERATURE: f64 = 0.7;
pub const BASELINE_MAX_TOKENS: u32 = 4096;
pub const BASELINE_TIMEOUT_SECS: u64 = 120;
pub const BASELINE_WIRE_API: []const u8 = "chat_completions";

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
};

/// Provider-agnostic tool descriptor mirroring
/// `zeroclaw_api::tool::ToolSpec`. Each provider's `convertTools` turns
/// these into its native form (OpenAI `NativeToolSpec`, Ollama
/// `{"type":"function","function":{...}}` JSON).
///
/// Lifetime: `name`, `description`, and `parameters` borrow from the
/// caller; `convertTools` deep-copies them into provider-owned form.
pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

/// Polymorphic chat-request envelope used by `Provider.chat`. Mirrors the
/// `zeroclaw_api::provider::ChatRequest` shape, with `tool_choice` exposed
/// for providers that need it (OpenAI). Providers that don't honor a field
/// (e.g., Ollama ignores `tool_choice`) silently drop it.
pub const ChatRequest = struct {
    messages: []const dispatcher.ChatMessage,
    tools: ?[]const ToolSpec = null,
    tool_choice: ?[]const u8 = null,
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
            messages: []const dispatcher.ChatMessage,
            model: []const u8,
            temperature: ?f64,
        ) anyerror![]u8,
        chatWithTools: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            messages: []const dispatcher.ChatMessage,
            tools: []const ToolSpec,
            model: []const u8,
            temperature: ?f64,
        ) anyerror!dispatcher.ChatResponse,
        chat: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            request: ChatRequest,
            model: []const u8,
            temperature: ?f64,
        ) anyerror!dispatcher.ChatResponse,
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
        messages: []const dispatcher.ChatMessage,
        model: []const u8,
        temperature: ?f64,
    ) ![]u8 {
        return self.vtable.chatWithHistory(self.ptr, allocator, messages, model, temperature);
    }

    pub fn chatWithTools(
        self: Provider,
        allocator: std.mem.Allocator,
        messages: []const dispatcher.ChatMessage,
        tools: []const ToolSpec,
        model: []const u8,
        temperature: ?f64,
    ) !dispatcher.ChatResponse {
        return self.vtable.chatWithTools(self.ptr, allocator, messages, tools, model, temperature);
    }

    pub fn chat(
        self: Provider,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: ?f64,
    ) !dispatcher.ChatResponse {
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
        return self.vtable.capabilities.supports_native_tools;
    }

    pub fn supportsVision(self: Provider) bool {
        return self.vtable.capabilities.supports_vision;
    }

    pub fn supportsStreaming(self: Provider) bool {
        return self.vtable.capabilities.supports_streaming;
    }
};

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
            messages: []const dispatcher.ChatMessage,
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
            messages: []const dispatcher.ChatMessage,
            tools: []const ToolSpec,
            model: []const u8,
            temperature: ?f64,
        ) anyerror!dispatcher.ChatResponse {
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
        ) anyerror!dispatcher.ChatResponse {
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
        const history = [_]dispatcher.ChatMessage{
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
        const history = [_]dispatcher.ChatMessage{.{ .role = "user", .content = "x" }};
        const tools = [_]ToolSpec{};
        var resp = try handle.chatWithTools(std.testing.allocator, &history, &tools, "m", 0.5);
        defer resp.deinit(std.testing.allocator);
        try std.testing.expect(stub.last_method == .tools);
        try std.testing.expectEqual(@as(usize, 0), stub.last_tools_len);
    }

    {
        const history = [_]dispatcher.ChatMessage{.{ .role = "user", .content = "x" }};
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
}
