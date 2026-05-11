//! Sync-first agent tool vtable.
//!
//! Rust's `zeroclaw_api::tool::Tool` executes with `async fn execute`.
//! This Zig pilot deliberately exposes a synchronous `execute` slot because
//! libxev integration is deferred. Future I/O-heavy ports should treat this
//! as a Phase 7-A compatibility scaffold, not a final async design; when
//! libxev lands, the vtable can grow an `executeAsync` variant or migrate
//! wholesale.

const std = @import("std");
const providers = @import("../providers/root.zig");
const parser_types = @import("../tool_call_parser/types.zig");

pub const ToolSpec = providers.ToolSpec;

pub const ToolResult = struct {
    success: bool,
    output: []u8,
    error_msg: ?[]u8 = null,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.error_msg) |msg| allocator.free(msg);
        self.* = undefined;
    }
};

pub const Tool = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        description: *const fn (ptr: *anyopaque) []const u8,
        parametersSchema: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror!std.json.Value,
        execute: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            args: std.json.Value,
        ) anyerror!ToolResult,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn name(self: Tool) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn description(self: Tool) []const u8 {
        return self.vtable.description(self.ptr);
    }

    pub fn parametersSchema(self: Tool, allocator: std.mem.Allocator) !std.json.Value {
        return self.vtable.parametersSchema(self.ptr, allocator);
    }

    pub fn execute(self: Tool, allocator: std.mem.Allocator, args: std.json.Value) !ToolResult {
        return self.vtable.execute(self.ptr, allocator, args);
    }

    pub fn deinit(self: Tool, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    /// Equivalent to Rust's `spec()` default method. The field shape is
    /// identical to `zeroclaw_api::tool::ToolSpec` and the already-ported
    /// provider `ToolSpec`, so this module re-exports the provider DTO as the
    /// canonical Zig shape. The returned spec owns all fields; call
    /// `ToolSpec.deinit` when done.
    pub fn spec(self: Tool, allocator: std.mem.Allocator) !ToolSpec {
        const name_owned = try allocator.dupe(u8, self.name());
        errdefer allocator.free(name_owned);

        const description_owned = try allocator.dupe(u8, self.description());
        errdefer allocator.free(description_owned);

        var parameters = try self.parametersSchema(allocator);
        errdefer parser_types.freeJsonValue(allocator, &parameters);

        return .{
            .name = name_owned,
            .description = description_owned,
            .parameters = parameters,
        };
    }
};
