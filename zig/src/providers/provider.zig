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

test "Provider vtable dispatches to concrete receiver" {
    const Stub = struct {
        last_system: ?[]const u8 = null,
        last_message: []const u8 = "",
        last_model: []const u8 = "",
        last_temperature: ?f64 = null,

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
            self.last_system = system_prompt;
            self.last_message = message;
            self.last_model = model;
            self.last_temperature = temperature;
            return try allocator.dupe(u8, "stub-response");
        }

        const vtable: Provider.VTable = .{ .chatWithSystem = chatWithSystem };

        fn provider(self: *Self) Provider {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
    };

    var stub = Stub{};
    const handle = stub.provider();

    const reply = try handle.chatWithSystem(
        std.testing.allocator,
        "you are a test",
        "ping",
        "model-x",
        0.4,
    );
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("stub-response", reply);
    try std.testing.expectEqualStrings("you are a test", stub.last_system.?);
    try std.testing.expectEqualStrings("ping", stub.last_message);
    try std.testing.expectEqualStrings("model-x", stub.last_model);
    try std.testing.expectEqual(@as(?f64, 0.4), stub.last_temperature);
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
