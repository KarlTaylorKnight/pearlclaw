//! Provider DTO types — mirrors rust/crates/zeroclaw-api/src/provider.rs.
//!
//! Relocated from runtime/agent/dispatcher.zig in Phase 3-F.2 to fix the
//! layering inversion the second-pass review of Phase 3-F flagged: these
//! types are part of the provider API surface, so they live in providers/.
//! dispatcher.zig now re-exports them as aliases for consumer backward
//! compatibility; future commits can migrate consumers to import from here
//! directly.

const std = @import("std");

/// Raw tool call as emitted by an LLM provider. Strings are caller-borrowed on
/// input; eval/test fixtures own their own backing memory.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8, // JSON string

    pub fn clone(self: ToolCall, allocator: std.mem.Allocator) !ToolCall {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const arguments = try allocator.dupe(u8, self.arguments);
        return .{ .id = id, .name = name, .arguments = arguments };
    }

    pub fn deinit(self: *ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
        self.* = undefined;
    }
};

pub const TokenUsage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cached_input_tokens: ?u64 = null,
};

/// Provider response. text is optional; tool_calls may be empty.
pub const ChatResponse = struct {
    text: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    usage: ?TokenUsage = null,
    reasoning_content: ?[]const u8 = null,
    owned: bool = false,

    pub fn hasToolCalls(self: ChatResponse) bool {
        return self.tool_calls.len != 0;
    }

    pub fn textOrEmpty(self: ChatResponse) []const u8 {
        return self.text orelse "";
    }

    pub fn deinit(self: *ChatResponse, allocator: std.mem.Allocator) void {
        if (!self.owned) {
            self.* = undefined;
            return;
        }
        if (self.text) |text| allocator.free(text);
        for (self.tool_calls) |call| {
            var owned_call = call;
            owned_call.deinit(allocator);
        }
        if (self.tool_calls.len != 0) allocator.free(self.tool_calls);
        if (self.reasoning_content) |reasoning| allocator.free(reasoning);
        self.* = undefined;
    }
};

/// A single chat message — mirrors zeroclaw_api::provider::ChatMessage.
pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,

    pub fn clone(self: ChatMessage, allocator: std.mem.Allocator) !ChatMessage {
        const role = try allocator.dupe(u8, self.role);
        errdefer allocator.free(role);
        const content = try allocator.dupe(u8, self.content);
        return .{ .role = role, .content = content };
    }

    pub fn deinit(self: *ChatMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    content: []const u8,

    pub fn clone(self: ToolResultMessage, allocator: std.mem.Allocator) !ToolResultMessage {
        const tool_call_id = try allocator.dupe(u8, self.tool_call_id);
        errdefer allocator.free(tool_call_id);
        const content = try allocator.dupe(u8, self.content);
        return .{ .tool_call_id = tool_call_id, .content = content };
    }

    pub fn deinit(self: *ToolResultMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const AssistantToolCallsMessage = struct {
    text: ?[]const u8 = null,
    tool_calls: []ToolCall = &.{},
    reasoning_content: ?[]const u8 = null,

    pub fn clone(self: AssistantToolCallsMessage, allocator: std.mem.Allocator) !AssistantToolCallsMessage {
        const text = if (self.text) |value| try allocator.dupe(u8, value) else null;
        errdefer if (text) |value| allocator.free(value);

        const tool_calls = try cloneToolCalls(allocator, self.tool_calls);
        errdefer freeToolCalls(allocator, tool_calls);

        const reasoning_content = if (self.reasoning_content) |value| try allocator.dupe(u8, value) else null;

        return .{
            .text = text,
            .tool_calls = tool_calls,
            .reasoning_content = reasoning_content,
        };
    }

    pub fn deinit(self: *AssistantToolCallsMessage, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        freeToolCalls(allocator, self.tool_calls);
        if (self.reasoning_content) |reasoning| allocator.free(reasoning);
        self.* = undefined;
    }
};

/// Subset of zeroclaw_api::provider::ConversationMessage exercised by the
/// pilot. The AssistantToolCalls variant preserves native tool-call history
/// for future provider-message conversion.
pub const ConversationMessage = union(enum) {
    chat: ChatMessage,
    assistant_tool_calls: AssistantToolCallsMessage,
    tool_results: []ToolResultMessage,

    pub fn clone(self: ConversationMessage, allocator: std.mem.Allocator) !ConversationMessage {
        return switch (self) {
            .chat => |message| .{ .chat = try message.clone(allocator) },
            .assistant_tool_calls => |message| .{ .assistant_tool_calls = try message.clone(allocator) },
            .tool_results => |results| .{ .tool_results = try cloneToolResultMessages(allocator, results) },
        };
    }

    pub fn deinit(self: *ConversationMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .chat => |*m| m.deinit(allocator),
            .assistant_tool_calls => |*m| m.deinit(allocator),
            .tool_results => |results| {
                for (results) |*r| r.deinit(allocator);
                if (results.len != 0) allocator.free(results);
            },
        }
        self.* = undefined;
    }
};

fn cloneToolCalls(allocator: std.mem.Allocator, calls: []const ToolCall) ![]ToolCall {
    if (calls.len == 0) return &.{};

    const owned = try allocator.alloc(ToolCall, calls.len);
    var count: usize = 0;
    errdefer {
        for (owned[0..count]) |*call| call.deinit(allocator);
        allocator.free(owned);
    }

    for (calls) |call| {
        owned[count] = try call.clone(allocator);
        count += 1;
    }

    return owned;
}

fn freeToolCalls(allocator: std.mem.Allocator, calls: []ToolCall) void {
    for (calls) |*call| call.deinit(allocator);
    if (calls.len != 0) allocator.free(calls);
}

fn cloneToolResultMessages(
    allocator: std.mem.Allocator,
    results: []const ToolResultMessage,
) ![]ToolResultMessage {
    if (results.len == 0) return &.{};

    const owned = try allocator.alloc(ToolResultMessage, results.len);
    var count: usize = 0;
    errdefer {
        for (owned[0..count]) |*result| result.deinit(allocator);
        allocator.free(owned);
    }

    for (results) |result| {
        owned[count] = try result.clone(allocator);
        count += 1;
    }

    return owned;
}
