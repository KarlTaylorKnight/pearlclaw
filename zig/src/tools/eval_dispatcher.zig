//! eval-dispatcher — language-agnostic dispatcher pilot eval runner.
//!
//! Reads JSONL ops from stdin, runs each through XmlToolDispatcher or
//! NativeToolDispatcher, writes one canonical-JSON response per data-returning
//! op to stdout. Mirrors eval-tools/src/bin/eval-dispatcher.rs.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const dispatcher = zeroclaw.runtime.agent.dispatcher;

const EvalError = error{InvalidScenario};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.io.getStdIn().readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(input);

    const stdout = std.io.getStdOut().writer();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        try runOp(allocator, line, stdout);
    }
}

fn runOp(allocator: std.mem.Allocator, line: []const u8, writer: anytype) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const op = getString(parsed.value, "op") orelse return EvalError.InvalidScenario;
    const dispatcher_kind = getString(parsed.value, "dispatcher") orelse return EvalError.InvalidScenario;

    if (std.mem.eql(u8, op, "parse_response")) {
        try runParseResponse(allocator, parsed.value, dispatcher_kind, writer);
    } else if (std.mem.eql(u8, op, "format_results")) {
        try runFormatResults(allocator, parsed.value, dispatcher_kind, writer);
    } else if (std.mem.eql(u8, op, "should_send_tool_specs")) {
        try runShouldSendToolSpecs(dispatcher_kind, writer);
    } else {
        return EvalError.InvalidScenario;
    }
}

fn runParseResponse(
    allocator: std.mem.Allocator,
    op_value: std.json.Value,
    dispatcher_kind: []const u8,
    writer: anytype,
) !void {
    const response_value = getField(op_value, "response") orelse return EvalError.InvalidScenario;
    const text = getOptionalString(response_value, "text");
    const tool_calls_value = getField(response_value, "tool_calls");

    var tool_calls = std.ArrayList(dispatcher.ToolCall).init(allocator);
    defer tool_calls.deinit();
    if (tool_calls_value) |tcv| {
        if (tcv == .array) {
            for (tcv.array.items) |tc| {
                if (tc != .object) return EvalError.InvalidScenario;
                try tool_calls.append(.{
                    .id = getString(tc, "id") orelse return EvalError.InvalidScenario,
                    .name = getString(tc, "name") orelse return EvalError.InvalidScenario,
                    .arguments = getString(tc, "arguments") orelse return EvalError.InvalidScenario,
                });
            }
        }
    }

    const response = dispatcher.ChatResponse{
        .text = text,
        .tool_calls = tool_calls.items,
    };

    var result = try invokeParseResponse(allocator, dispatcher_kind, response);
    defer result.deinit(allocator);

    try writer.writeAll("{\"op\":\"parse_response\",\"result\":");
    try writeParseResult(writer, result);
    try writer.writeAll("}\n");
}

fn runFormatResults(
    allocator: std.mem.Allocator,
    op_value: std.json.Value,
    dispatcher_kind: []const u8,
    writer: anytype,
) !void {
    const results_value = getField(op_value, "results") orelse return EvalError.InvalidScenario;
    if (results_value != .array) return EvalError.InvalidScenario;

    var results = std.ArrayList(dispatcher.ToolExecutionResult).init(allocator);
    defer results.deinit();
    for (results_value.array.items) |entry| {
        if (entry != .object) return EvalError.InvalidScenario;
        const success_v = getField(entry, "success") orelse return EvalError.InvalidScenario;
        if (success_v != .bool) return EvalError.InvalidScenario;
        try results.append(.{
            .name = getString(entry, "name") orelse return EvalError.InvalidScenario,
            .output = getString(entry, "output") orelse return EvalError.InvalidScenario,
            .success = success_v.bool,
            .tool_call_id = getOptionalString(entry, "tool_call_id"),
        });
    }

    var msg = try invokeFormatResults(allocator, dispatcher_kind, results.items);
    defer msg.deinit(allocator);

    try writer.writeAll("{\"op\":\"format_results\",\"result\":");
    try writeConversationMessage(writer, msg);
    try writer.writeAll("}\n");
}

fn runShouldSendToolSpecs(dispatcher_kind: []const u8, writer: anytype) !void {
    const result = blk: {
        if (std.mem.eql(u8, dispatcher_kind, "xml")) {
            var x = dispatcher.XmlToolDispatcher{};
            break :blk x.dispatcher().shouldSendToolSpecs();
        } else if (std.mem.eql(u8, dispatcher_kind, "native")) {
            var n = dispatcher.NativeToolDispatcher{};
            break :blk n.dispatcher().shouldSendToolSpecs();
        } else return EvalError.InvalidScenario;
    };
    try writer.writeAll("{\"op\":\"should_send_tool_specs\",\"result\":");
    try writer.writeAll(if (result) "true" else "false");
    try writer.writeAll("}\n");
}

fn invokeParseResponse(
    allocator: std.mem.Allocator,
    dispatcher_kind: []const u8,
    response: dispatcher.ChatResponse,
) !dispatcher.ParseResult {
    if (std.mem.eql(u8, dispatcher_kind, "xml")) {
        var x = dispatcher.XmlToolDispatcher{};
        return x.dispatcher().parseResponse(allocator, response);
    } else if (std.mem.eql(u8, dispatcher_kind, "native")) {
        var n = dispatcher.NativeToolDispatcher{};
        return n.dispatcher().parseResponse(allocator, response);
    }
    return EvalError.InvalidScenario;
}

fn invokeFormatResults(
    allocator: std.mem.Allocator,
    dispatcher_kind: []const u8,
    results: []const dispatcher.ToolExecutionResult,
) !dispatcher.ConversationMessage {
    if (std.mem.eql(u8, dispatcher_kind, "xml")) {
        var x = dispatcher.XmlToolDispatcher{};
        return x.dispatcher().formatResults(allocator, results);
    } else if (std.mem.eql(u8, dispatcher_kind, "native")) {
        var n = dispatcher.NativeToolDispatcher{};
        return n.dispatcher().formatResults(allocator, results);
    }
    return EvalError.InvalidScenario;
}

// ─── JSON output helpers ──────────────────────────────────────────────────

fn writeParseResult(writer: anytype, result: dispatcher.ParseResult) !void {
    try writer.writeAll("{\"text\":");
    try std.json.stringify(result.text, .{}, writer);
    try writer.writeAll(",\"calls\":[");
    for (result.calls, 0..) |call, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try std.json.stringify(call.name, .{}, writer);
        try writer.writeAll(",\"arguments\":");
        try std.json.stringify(call.arguments, .{}, writer);
        try writer.writeAll(",\"tool_call_id\":");
        if (call.tool_call_id) |id| {
            try std.json.stringify(id, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
}

fn writeConversationMessage(writer: anytype, msg: dispatcher.ConversationMessage) !void {
    // Mirrors serde tag="type", content="data" on
    // zeroclaw_api::provider::ConversationMessage.
    switch (msg) {
        .chat => |chat| {
            try writer.writeAll("{\"type\":\"Chat\",\"data\":{\"role\":");
            try std.json.stringify(chat.role, .{}, writer);
            try writer.writeAll(",\"content\":");
            try std.json.stringify(chat.content, .{}, writer);
            try writer.writeAll("}}");
        },
        .tool_results => |results| {
            try writer.writeAll("{\"type\":\"ToolResults\",\"data\":[");
            for (results, 0..) |r, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.writeAll("{\"tool_call_id\":");
                try std.json.stringify(r.tool_call_id, .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.stringify(r.content, .{}, writer);
                try writer.writeAll("}");
            }
            try writer.writeAll("]}");
        },
    }
}

// ─── JSON input helpers ───────────────────────────────────────────────────

fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn getOptionalString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .null => null,
        .string => |inner| inner,
        else => null,
    };
}
