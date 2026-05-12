//! eval-cli-discovery — offline cli_discovery parity runner.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const agent_tools = zeroclaw.agent_tools;

const EvalError = error{InvalidScenario};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

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
    if (!std.mem.eql(u8, op, "discover")) return EvalError.InvalidScenario;
    const setup = getField(parsed.value, "setup") orelse return EvalError.InvalidScenario;
    const input = getField(parsed.value, "input") orelse return EvalError.InvalidScenario;

    const original_path = std.process.getEnvVarOwned(allocator, "PATH") catch null;
    defer if (original_path) |value| allocator.free(value);
    defer restoreEnv(allocator, "PATH", original_path);

    try applySetup(setup);
    if (getString(input, "path_override")) |path_override| {
        try setEnv(allocator, "PATH", path_override);
    }

    const additional = try getStringArray(allocator, input, "additional");
    defer allocator.free(additional);
    const excluded = try getStringArray(allocator, input, "excluded");
    defer allocator.free(excluded);

    const results = try agent_tools.discoverCliTools(allocator, additional, excluded);
    defer deinitDiscoveredSlice(allocator, results);
    try writeResults(writer, results);
    try writer.writeByte('\n');
}

fn applySetup(setup: std.json.Value) !void {
    if (getField(setup, "shell_scripts")) |scripts| {
        if (scripts != .object) return EvalError.InvalidScenario;
        var it = scripts.object.iterator();
        while (it.next()) |entry| {
            const content = if (entry.value_ptr.* == .string) entry.value_ptr.string else return EvalError.InvalidScenario;
            try writeShellScript(entry.key_ptr.*, content);
        }
    }
}

fn writeShellScript(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.fs.cwd().makePath(parent);
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o755 })
    else
        try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o755 });
    defer file.close();
    try file.writeAll(content);
    try file.chmod(0o755);
}

fn writeResults(writer: anytype, results: []const agent_tools.DiscoveredCli) !void {
    try writer.writeByte('[');
    for (results, 0..) |result, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"category\":");
        try std.json.stringify(result.category.serializeName(), .{}, writer);
        try writer.writeAll(",\"name\":");
        try std.json.stringify(result.name, .{}, writer);
        try writer.writeAll(",\"path\":");
        try std.json.stringify(result.path, .{}, writer);
        try writer.writeAll(",\"version\":");
        if (result.version) |version| {
            try std.json.stringify(version, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn deinitDiscoveredSlice(allocator: std.mem.Allocator, items: []agent_tools.DiscoveredCli) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn setEnv(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    const value_z = try allocator.dupeZ(u8, value);
    defer allocator.free(value_z);
    if (setenv(name_z.ptr, value_z.ptr, 1) != 0) return error.Unexpected;
}

fn restoreEnv(allocator: std.mem.Allocator, name: []const u8, value: ?[]const u8) void {
    const name_z = allocator.dupeZ(u8, name) catch return;
    defer allocator.free(name_z);
    if (value) |inner| {
        const value_z = allocator.dupeZ(u8, inner) catch return;
        defer allocator.free(value_z);
        _ = setenv(name_z.ptr, value_z.ptr, 1);
    } else {
        _ = unsetenv(name_z.ptr);
    }
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

fn getStringArray(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]const []const u8 {
    const inner = getField(value, key) orelse return allocator.alloc([]const u8, 0);
    if (inner != .array) return EvalError.InvalidScenario;

    const items = try allocator.alloc([]const u8, inner.array.items.len);
    errdefer allocator.free(items);
    for (inner.array.items, 0..) |item, idx| {
        if (item != .string) return EvalError.InvalidScenario;
        items[idx] = item.string;
    }
    return items;
}
