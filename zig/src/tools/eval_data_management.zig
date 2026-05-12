//! eval-data-management — offline data_management parity runner.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const agent_tools = zeroclaw.agent_tools;

const EvalError = error{InvalidScenario};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

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
    if (!std.mem.eql(u8, tool_name, "data_management")) return EvalError.InvalidScenario;
    const setup = getField(parsed.value, "setup") orelse return EvalError.InvalidScenario;
    const args = getField(parsed.value, "args") orelse return EvalError.InvalidScenario;

    try applySetup(allocator, setup);
    const workspace = getString(setup, "workspace") orelse getString(setup, "home") orelse return EvalError.InvalidScenario;
    const retention_days = getU64(setup, "retention_days", 90);

    var tool_impl = agent_tools.DataManagementTool.init(allocator, workspace, retention_days);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, args);
    defer result.deinit(allocator);
    try writeExecuteResult(writer, tool_name, result);
}

fn applySetup(allocator: std.mem.Allocator, setup: std.json.Value) !void {
    if (getString(setup, "workspace")) |workspace| {
        try std.fs.cwd().makePath(workspace);
    }

    if (getString(setup, "home")) |home| {
        try std.fs.cwd().makePath(home);
        const key = try allocator.dupeZ(u8, "HOME");
        defer allocator.free(key);
        const value = try allocator.dupeZ(u8, home);
        defer allocator.free(value);
        if (setenv(key.ptr, value.ptr, 1) != 0) return error.Unexpected;
    }

    if (getField(setup, "files")) |files| {
        if (files != .array) return EvalError.InvalidScenario;
        for (files.array.items) |file| {
            if (file != .object) return EvalError.InvalidScenario;
            const path = getString(file, "path") orelse return EvalError.InvalidScenario;
            const content = getString(file, "content") orelse return EvalError.InvalidScenario;
            if (std.fs.path.dirname(path)) |parent| try std.fs.cwd().makePath(parent);
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
        }
    }

    if (getField(setup, "file_mtimes")) |file_mtimes| {
        if (file_mtimes != .object) return EvalError.InvalidScenario;
        var it = file_mtimes.object.iterator();
        while (it.next()) |entry| {
            const epoch = valueAsU64(entry.value_ptr.*) orelse return EvalError.InvalidScenario;
            try setFileMtime(entry.key_ptr.*, epoch);
        }
    }
}

fn setFileMtime(path: []const u8, epoch: u64) !void {
    var file = try openFile(path);
    defer file.close();
    const ns = @as(i128, @intCast(epoch)) * std.time.ns_per_s;
    try file.updateTimes(ns, ns);
}

fn openFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, .{});
    return std.fs.cwd().openFile(path, .{});
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

fn getU64(value: std.json.Value, key: []const u8, default: u64) u64 {
    const inner = getField(value, key) orelse return default;
    return valueAsU64(inner) orelse default;
}

fn valueAsU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |inner| if (inner < 0) null else std.math.cast(u64, inner),
        .number_string => |inner| std.fmt.parseInt(u64, inner, 10) catch null,
        else => null,
    };
}
