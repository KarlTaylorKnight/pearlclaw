//! Tool dispatcher pilot port — mirrors rust/crates/zeroclaw-runtime/src/agent/dispatcher.rs.
//!
//! Two dispatchers (XmlToolDispatcher, NativeToolDispatcher) expose a common
//! ToolDispatcher vtable per the plan §"Pilot port: dispatcher". Out of scope
//! for the pilot per R11 / dispatcher.rs trait surface:
//!   - prompt_instructions(&[Box<dyn Tool>]) — needs the out-of-scope tools crate
//!   - to_provider_messages(history) — needs the AssistantToolCalls history
//!     variant which only lands when the agent loop ports
//!
//! The XML parser inside this module is INTENTIONALLY simpler than the
//! tool_call_parser pilot — it matches the Rust dispatcher's embedded
//! parse_xml_tool_calls (dispatcher.rs:33-85), not the heavyweight
//! parse_tool_calls in zeroclaw-tool-call-parser. Pinned quirks documented in
//! docs/porting-notes.md.

const std = @import("std");
const parser_types = @import("../../tool_call_parser/types.zig");

pub const ParsedToolCall = parser_types.ParsedToolCall;
pub const ParseResult = parser_types.ParseResult;

/// Raw tool call as emitted by an LLM provider. Strings are caller-borrowed on
/// input; eval/test fixtures own their own backing memory.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8, // JSON string

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

    pub fn deinit(self: *ChatMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    content: []const u8,

    pub fn deinit(self: *ToolResultMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.content);
        self.* = undefined;
    }
};

/// Result of executing a tool, fed to format_results.
pub const ToolExecutionResult = struct {
    name: []const u8,
    output: []const u8,
    success: bool,
    tool_call_id: ?[]const u8 = null,
};

/// Subset of zeroclaw_api::provider::ConversationMessage exercised by the
/// pilot. AssistantToolCalls deferred — only used by to_provider_messages
/// which is not in pilot scope.
pub const ConversationMessage = union(enum) {
    chat: ChatMessage,
    tool_results: []ToolResultMessage,

    pub fn deinit(self: *ConversationMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .chat => |*m| m.deinit(allocator),
            .tool_results => |results| {
                for (results) |*r| r.deinit(allocator);
                allocator.free(results);
            },
        }
        self.* = undefined;
    }
};

/// Vtable handle. Concrete dispatchers expose `dispatcher()` returning this.
pub const ToolDispatcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        parseResponse: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, response: ChatResponse, scratch_arena: ?*std.heap.ArenaAllocator) anyerror!ParseResult,
        formatResults: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, results: []const ToolExecutionResult) anyerror!ConversationMessage,
        shouldSendToolSpecs: *const fn (ptr: *anyopaque) bool,
    };

    pub fn parseResponse(
        self: ToolDispatcher,
        allocator: std.mem.Allocator,
        response: ChatResponse,
        scratch_arena: ?*std.heap.ArenaAllocator,
    ) !ParseResult {
        return self.vtable.parseResponse(self.ptr, allocator, response, scratch_arena);
    }
    pub fn formatResults(self: ToolDispatcher, allocator: std.mem.Allocator, results: []const ToolExecutionResult) !ConversationMessage {
        return self.vtable.formatResults(self.ptr, allocator, results);
    }
    pub fn shouldSendToolSpecs(self: ToolDispatcher) bool {
        return self.vtable.shouldSendToolSpecs(self.ptr);
    }
};

pub const XmlToolDispatcher = struct {
    pub fn dispatcher(self: *XmlToolDispatcher) ToolDispatcher {
        return .{ .ptr = @ptrCast(self), .vtable = &xml_vtable };
    }

    const xml_vtable: ToolDispatcher.VTable = .{
        .parseResponse = xmlParseResponse,
        .formatResults = xmlFormatResults,
        .shouldSendToolSpecs = xmlShouldSendToolSpecs,
    };

    fn xmlParseResponse(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        response: ChatResponse,
        scratch_arena: ?*std.heap.ArenaAllocator,
    ) anyerror!ParseResult {
        return parseXmlToolCalls(allocator, response.text orelse "", scratch_arena);
    }

    fn xmlFormatResults(_: *anyopaque, allocator: std.mem.Allocator, results: []const ToolExecutionResult) anyerror!ConversationMessage {
        var content = std.ArrayList(u8).init(allocator);
        defer content.deinit();
        for (results) |result| {
            const status: []const u8 = if (result.success) "ok" else "error";
            try content.writer().print(
                "<tool_result name=\"{s}\" status=\"{s}\">\n{s}\n</tool_result>\n",
                .{ result.name, status, result.output },
            );
        }
        const owned = try std.fmt.allocPrint(allocator, "[Tool results]\n{s}", .{content.items});
        errdefer allocator.free(owned);
        const role = try allocator.dupe(u8, "user");
        return .{ .chat = .{ .role = role, .content = owned } };
    }

    fn xmlShouldSendToolSpecs(_: *anyopaque) bool {
        return false;
    }
};

pub const NativeToolDispatcher = struct {
    pub fn dispatcher(self: *NativeToolDispatcher) ToolDispatcher {
        return .{ .ptr = @ptrCast(self), .vtable = &native_vtable };
    }

    const native_vtable: ToolDispatcher.VTable = .{
        .parseResponse = nativeParseResponse,
        .formatResults = nativeFormatResults,
        .shouldSendToolSpecs = nativeShouldSendToolSpecs,
    };

    fn nativeParseResponse(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        response: ChatResponse,
        scratch_arena: ?*std.heap.ArenaAllocator,
    ) anyerror!ParseResult {
        if (scratch_arena) |arena| {
            var result = try nativeParseResponseInner(arena.allocator(), response);
            result.arena_backed = true;
            return result;
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        var result = try nativeParseResponseInner(arena_allocator, response);
        result.arena = arena;
        return result;
    }

    fn nativeParseResponseInner(allocator: std.mem.Allocator, response: ChatResponse) anyerror!ParseResult {
        const text_owned = try allocator.dupe(u8, response.text orelse "");

        var calls = std.ArrayList(ParsedToolCall).init(allocator);
        errdefer {
            for (calls.items) |*c| c.deinit(allocator);
            calls.deinit();
        }

        for (response.tool_calls) |tc| {
            // Match Rust: parse arguments JSON; on failure, default to {}
            // (dispatcher.rs:181-188 — tracing::warn! + Value::Object empty).
            var arguments: std.json.Value = blk: {
                if (try parser_types.parseJsonValueOwned(allocator, tc.arguments)) |v| {
                    break :blk v;
                }
                break :blk parser_types.emptyObject(allocator);
            };
            errdefer parser_types.freeJsonValue(allocator, &arguments);

            const name_owned = try allocator.dupe(u8, tc.name);
            const id_owned = try allocator.dupe(u8, tc.id);

            try calls.append(.{
                .name = name_owned,
                .arguments = arguments,
                .tool_call_id = id_owned,
            });
        }

        return .{
            .text = text_owned,
            .calls = try calls.toOwnedSlice(),
        };
    }

    fn nativeFormatResults(_: *anyopaque, allocator: std.mem.Allocator, results: []const ToolExecutionResult) anyerror!ConversationMessage {
        var msgs = std.ArrayList(ToolResultMessage).init(allocator);
        errdefer {
            for (msgs.items) |*m| m.deinit(allocator);
            msgs.deinit();
        }
        for (results) |result| {
            const tcid = try allocator.dupe(u8, result.tool_call_id orelse "unknown");
            errdefer allocator.free(tcid);
            const content = try allocator.dupe(u8, result.output);
            errdefer allocator.free(content);
            try msgs.append(.{ .tool_call_id = tcid, .content = content });
        }
        return .{ .tool_results = try msgs.toOwnedSlice() };
    }

    fn nativeShouldSendToolSpecs(_: *anyopaque) bool {
        return true;
    }
};

// ─── XML parsing helpers ──────────────────────────────────────────────────

fn parseXmlToolCalls(
    allocator: std.mem.Allocator,
    response: []const u8,
    scratch_arena: ?*std.heap.ArenaAllocator,
) !ParseResult {
    if (scratch_arena) |arena| {
        var result = try parseXmlToolCallsInner(arena.allocator(), response);
        result.arena_backed = true;
        return result;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var result = try parseXmlToolCallsInner(arena.allocator(), response);
    result.arena = arena;
    return result;
}

fn parseXmlToolCallsInner(allocator: std.mem.Allocator, response: []const u8) !ParseResult {
    const cleaned = try stripThinkTags(allocator, response);
    defer allocator.free(cleaned);

    var text_parts = std.ArrayList([]u8).init(allocator);
    defer {
        for (text_parts.items) |part| allocator.free(part);
        text_parts.deinit();
    }

    var calls = std.ArrayList(ParsedToolCall).init(allocator);
    errdefer {
        for (calls.items) |*c| c.deinit(allocator);
        calls.deinit();
    }

    var remaining: []const u8 = cleaned;
    while (std.mem.indexOf(u8, remaining, "<tool_call>")) |start| {
        const before_trimmed = std.mem.trim(u8, remaining[0..start], " \t\r\n");
        if (before_trimmed.len > 0) {
            try text_parts.append(try allocator.dupe(u8, before_trimmed));
        }

        const after_open = remaining[start + "<tool_call>".len ..];
        if (std.mem.indexOf(u8, after_open, "</tool_call>")) |end_rel| {
            const inner_trimmed = std.mem.trim(u8, after_open[0..end_rel], " \t\r\n");
            const advance = end_rel + "</tool_call>".len;

            // Try to parse JSON inside the tag. On failure, silently drop the
            // call (dispatcher.rs:70-72 — tracing::warn! + falls through to
            // the post-match remaining advance).
            if (try parser_types.parseJsonValueOwned(allocator, inner_trimmed)) |parsed| {
                var parsed_mut = parsed;
                defer parser_types.freeJsonValue(allocator, &parsed_mut);

                // Extract name (must be non-empty string).
                const name_str: []const u8 = blk: {
                    if (parsed_mut != .object) break :blk "";
                    const name_v = parsed_mut.object.get("name") orelse break :blk "";
                    if (name_v != .string) break :blk "";
                    break :blk name_v.string;
                };

                if (name_str.len > 0) {
                    var arguments: std.json.Value = if (parsed_mut == .object) blk: {
                        if (parsed_mut.object.fetchOrderedRemove("arguments")) |removed| {
                            allocator.free(removed.key);
                            break :blk removed.value;
                        }
                        break :blk parser_types.emptyObject(allocator);
                    } else parser_types.emptyObject(allocator);
                    errdefer parser_types.freeJsonValue(allocator, &arguments);

                    const name_owned = try allocator.dupe(u8, name_str);
                    errdefer allocator.free(name_owned);

                    try calls.append(.{
                        .name = name_owned,
                        .arguments = arguments,
                        .tool_call_id = null,
                    });
                }
            }

            remaining = after_open[advance..];
        } else {
            // Unmatched <tool_call> open — break, leave the rest as `remaining`
            // for the trailing-text handling below. Matches dispatcher.rs:75-77.
            break;
        }
    }

    const remaining_trimmed = std.mem.trim(u8, remaining, " \t\r\n");
    if (remaining_trimmed.len > 0) {
        try text_parts.append(try allocator.dupe(u8, remaining_trimmed));
    }

    // Join text_parts with "\n" (dispatcher.rs:84 — text_parts.join("\n")).
    var total: usize = 0;
    for (text_parts.items, 0..) |part, i| {
        total += part.len;
        if (i + 1 < text_parts.items.len) total += 1;
    }
    const text = try allocator.alloc(u8, total);
    errdefer allocator.free(text);
    var idx: usize = 0;
    for (text_parts.items, 0..) |part, i| {
        @memcpy(text[idx .. idx + part.len], part);
        idx += part.len;
        if (i + 1 < text_parts.items.len) {
            text[idx] = '\n';
            idx += 1;
        }
    }

    return .{
        .text = text,
        .calls = try calls.toOwnedSlice(),
    };
}

fn stripThinkTags(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var rest: []const u8 = source;
    while (true) {
        if (std.mem.indexOf(u8, rest, "<think>")) |start| {
            try result.appendSlice(rest[0..start]);
            const after_open = rest[start..];
            if (std.mem.indexOf(u8, after_open, "</think>")) |end_rel| {
                rest = after_open[end_rel + "</think>".len ..];
            } else {
                // dispatcher.rs:96-97 — unmatched <think> breaks; everything
                // from <think> onward is silently discarded.
                break;
            }
        } else {
            try result.appendSlice(rest);
            break;
        }
    }

    return result.toOwnedSlice();
}

// ─── Tests (mirror dispatcher.rs::tests) ──────────────────────────────────

test "xml dispatcher parses tool call" {
    const allocator = std.testing.allocator;
    var x = XmlToolDispatcher{};
    const dispatch = x.dispatcher();

    const response = ChatResponse{
        .text = "Checking\n<tool_call>{\"name\":\"shell\",\"arguments\":{\"command\":\"ls\"}}</tool_call>",
    };
    var result = try dispatch.parseResponse(allocator, response, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
}

test "xml dispatcher strips think tags before parsing" {
    const allocator = std.testing.allocator;
    var x = XmlToolDispatcher{};
    const dispatch = x.dispatcher();

    const response = ChatResponse{
        .text = "<think>I should list files</think>\n<tool_call>{\"name\":\"shell\",\"arguments\":{\"command\":\"ls\"}}</tool_call>",
    };
    var result = try dispatch.parseResponse(allocator, response, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "<think>") == null);
}

test "xml dispatcher think only returns no calls" {
    const allocator = std.testing.allocator;
    var x = XmlToolDispatcher{};
    const dispatch = x.dispatcher();

    const response = ChatResponse{ .text = "<think>Just thinking</think>" };
    var result = try dispatch.parseResponse(allocator, response, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "native dispatcher round-trip" {
    const allocator = std.testing.allocator;
    var n = NativeToolDispatcher{};
    const dispatch = n.dispatcher();

    const tcs = [_]ToolCall{.{ .id = "tc1", .name = "file_read", .arguments = "{\"path\":\"a.txt\"}" }};
    const response = ChatResponse{ .text = "ok", .tool_calls = &tcs };
    var result = try dispatch.parseResponse(allocator, response, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("tc1", result.calls[0].tool_call_id.?);
    try std.testing.expectEqualStrings("file_read", result.calls[0].name);
}

test "xml format_results contains tool_result tags" {
    const allocator = std.testing.allocator;
    var x = XmlToolDispatcher{};
    const dispatch = x.dispatcher();

    const results = [_]ToolExecutionResult{.{
        .name = "shell",
        .output = "ok",
        .success = true,
        .tool_call_id = null,
    }};
    var msg = try dispatch.formatResults(allocator, &results);
    defer msg.deinit(allocator);

    try std.testing.expect(msg == .chat);
    try std.testing.expect(std.mem.indexOf(u8, msg.chat.content, "<tool_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.chat.content, "shell") != null);
}

test "native format_results keeps tool_call_id" {
    const allocator = std.testing.allocator;
    var n = NativeToolDispatcher{};
    const dispatch = n.dispatcher();

    const results = [_]ToolExecutionResult{.{
        .name = "shell",
        .output = "ok",
        .success = true,
        .tool_call_id = "tc-1",
    }};
    var msg = try dispatch.formatResults(allocator, &results);
    defer msg.deinit(allocator);

    try std.testing.expect(msg == .tool_results);
    try std.testing.expectEqual(@as(usize, 1), msg.tool_results.len);
    try std.testing.expectEqualStrings("tc-1", msg.tool_results[0].tool_call_id);
}

test "should_send_tool_specs flags" {
    var x = XmlToolDispatcher{};
    var n = NativeToolDispatcher{};
    try std.testing.expect(!x.dispatcher().shouldSendToolSpecs());
    try std.testing.expect(n.dispatcher().shouldSendToolSpecs());
}
