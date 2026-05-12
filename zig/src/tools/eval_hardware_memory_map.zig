//! eval-hardware-memory-map — offline hardware_memory_map parity runner.
//!
//! Scenario shape (JSONL, one op per line):
//!   {"op":"execute","tool":"hardware_memory_map","setup":{"boards":[...]},"args":{...}}
//!
//! No filesystem setup is required — these tools are pure static-lookup
//! tables. `setup.boards` mirrors Rust's constructor argument
//! (`Vec<String>`); the eval runner builds an owned `[]const []const u8`
//! and passes it to the tool, exactly matching the Rust runner.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const agent_tools = zeroclaw.agent_tools;

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
    if (!std.mem.eql(u8, tool_name, "hardware_memory_map")) return EvalError.InvalidScenario;
    const setup = getField(parsed.value, "setup") orelse return EvalError.InvalidScenario;
    const args = getField(parsed.value, "args") orelse return EvalError.InvalidScenario;

    const boards = try collectBoards(allocator, setup);
    defer allocator.free(boards);

    var tool_impl = agent_tools.HardwareMemoryMapTool.init(allocator, boards);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, args);
    defer result.deinit(allocator);
    try writeExecuteResult(writer, tool_name, result);
}

fn collectBoards(allocator: std.mem.Allocator, setup: std.json.Value) ![]const []const u8 {
    const boards_field = getField(setup, "boards") orelse return allocator.alloc([]const u8, 0);
    if (boards_field != .array) return EvalError.InvalidScenario;

    const items = try allocator.alloc([]const u8, boards_field.array.items.len);
    errdefer allocator.free(items);
    for (boards_field.array.items, 0..) |item, idx| {
        if (item != .string) return EvalError.InvalidScenario;
        items[idx] = item.string;
    }
    return items;
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
