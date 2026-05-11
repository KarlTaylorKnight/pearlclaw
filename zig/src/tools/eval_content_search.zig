//! eval-content-search — offline content_search parity runner.

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
    if (!std.mem.eql(u8, tool_name, "content_search")) return EvalError.InvalidScenario;
    const setup = getField(parsed.value, "setup") orelse return EvalError.InvalidScenario;
    const args = getField(parsed.value, "args") orelse return EvalError.InvalidScenario;

    try applySetup(allocator, setup);
    const workspace = getString(setup, "workspace") orelse getString(setup, "home") orelse return EvalError.InvalidScenario;
    try std.posix.chdir(workspace);

    var tool_impl = agent_tools.ContentSearchTool.init(allocator);
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
