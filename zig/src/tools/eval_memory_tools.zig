//! eval-memory-tools — offline memory tool execution parity runner.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const agent_tools = zeroclaw.agent_tools;
const memory = zeroclaw.memory;

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
    if (!std.mem.eql(u8, op, "execute")) return EvalError.InvalidScenario;
    const tool_name = getString(parsed.value, "tool") orelse return EvalError.InvalidScenario;
    const setup = getField(parsed.value, "setup") orelse return EvalError.InvalidScenario;
    const args = getField(parsed.value, "args") orelse return EvalError.InvalidScenario;

    const db_path = getString(setup, "db_path") orelse return EvalError.InvalidScenario;
    var mem = try memory.SqliteMemory.newAtPath(allocator, db_path);
    defer mem.deinit();
    try applySetup(allocator, &mem, setup);

    var result = try executeTool(allocator, tool_name, &mem, args);
    defer result.deinit(allocator);
    try writeExecuteResult(writer, tool_name, result);
}

fn executeTool(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    mem: *memory.SqliteMemory,
    args: std.json.Value,
) !agent_tools.ToolResult {
    if (std.mem.eql(u8, tool_name, "memory_store")) {
        var tool_impl = agent_tools.MemoryStoreTool.init(allocator, mem);
        defer tool_impl.deinit(allocator);
        return tool_impl.tool().execute(allocator, args);
    }
    if (std.mem.eql(u8, tool_name, "memory_recall")) {
        var tool_impl = agent_tools.MemoryRecallTool.init(allocator, mem);
        defer tool_impl.deinit(allocator);
        return tool_impl.tool().execute(allocator, args);
    }
    if (std.mem.eql(u8, tool_name, "memory_forget")) {
        var tool_impl = agent_tools.MemoryForgetTool.init(allocator, mem);
        defer tool_impl.deinit(allocator);
        return tool_impl.tool().execute(allocator, args);
    }
    if (std.mem.eql(u8, tool_name, "memory_purge")) {
        var tool_impl = agent_tools.MemoryPurgeTool.init(allocator, mem);
        defer tool_impl.deinit(allocator);
        return tool_impl.tool().execute(allocator, args);
    }
    if (std.mem.eql(u8, tool_name, "memory_export")) {
        var tool_impl = agent_tools.MemoryExportTool.init(allocator, mem);
        defer tool_impl.deinit(allocator);
        return tool_impl.tool().execute(allocator, args);
    }
    return EvalError.InvalidScenario;
}

fn applySetup(allocator: std.mem.Allocator, mem: *memory.SqliteMemory, setup: std.json.Value) !void {
    const entries = getField(setup, "entries") orelse return;
    if (entries == .null) return;
    if (entries != .array) return EvalError.InvalidScenario;

    for (entries.array.items) |entry| {
        if (entry != .object) return EvalError.InvalidScenario;
        const content = getString(entry, "content") orelse return EvalError.InvalidScenario;
        const hash = if (getString(entry, "content_hash")) |existing|
            try allocator.dupe(u8, existing)
        else
            try memory.contentHash(allocator, content);
        defer allocator.free(hash);

        var category = try memory.MemoryCategory.fromString(
            allocator,
            getString(entry, "category") orelse "core",
        );
        defer category.deinit(allocator);

        try mem.storeWithMetadata(
            allocator,
            hash,
            content,
            category,
            null,
            null,
            optionalF64(entry, "importance"),
        );

        const tags = try parseTags(allocator, entry);
        defer allocator.free(tags);
        try mem.setToolMetadata(allocator, hash, tags, getOptionalString(entry, "source"));

        if (getString(entry, "created_at")) |timestamp| {
            try mem.setEntryTimestampForEval(hash, timestamp);
        }
    }
}

fn parseTags(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    const raw = getField(value, "tags") orelse return try allocator.alloc([]const u8, 0);
    if (raw == .null) return try allocator.alloc([]const u8, 0);
    if (raw != .array) return EvalError.InvalidScenario;
    const tags = try allocator.alloc([]const u8, raw.array.items.len);
    errdefer allocator.free(tags);
    for (raw.array.items, 0..) |item, i| {
        if (item != .string) return EvalError.InvalidScenario;
        tags[i] = item.string;
    }
    return tags;
}

fn writeExecuteResult(writer: anytype, tool_name: []const u8, result: agent_tools.ToolResult) !void {
    try writer.writeAll("{\"op\":\"execute\",\"tool\":");
    try std.json.stringify(tool_name, .{}, writer);
    try writer.writeAll(",\"result\":{\"success\":");
    try writer.writeAll(if (result.success) "true" else "false");
    try writer.writeAll(",\"output\":");
    try std.json.stringify(result.output, .{}, writer);
    if (result.error_msg) |msg| {
        try writer.writeAll(",\"error\":");
        try std.json.stringify(msg, .{}, writer);
    }
    try writer.writeAll("}}\n");
}

fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const inner = getField(value, key) orelse return null;
    if (inner != .string) return null;
    return inner.string;
}

fn getOptionalString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const inner = getField(value, key) orelse return null;
    return switch (inner) {
        .null => null,
        .string => |string| string,
        else => null,
    };
}

fn optionalF64(value: std.json.Value, key: []const u8) ?f64 {
    const inner = getField(value, key) orelse return null;
    return switch (inner) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |string| std.fmt.parseFloat(f64, string) catch null,
        else => null,
    };
}
