//! Provider vtable handle. Concrete providers (OllamaProvider,
//! OpenAiProvider) expose `provider(self: *Self) Provider` returning
//! a handle that callers can use polymorphically.
//!
//! Phase 1 surface: chatWithSystem only. Phase 2 will append fields to
//! VTable for chat_with_history, chat, chat_with_tools, list_models,
//! warmup, and capability getters.
//!
//! The handle's ptr aliases the concrete provider; the caller is
//! responsible for keeping the concrete instance alive while the handle
//! is in use. Same lifetime contract as runtime/agent/dispatcher's
//! ToolDispatcher.

const std = @import("std");

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
