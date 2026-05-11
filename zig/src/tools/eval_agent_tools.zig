//! eval-agent-tools — offline agent tool execution parity runner.

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

    var calculator = agent_tools.CalculatorTool.init(allocator);
    defer calculator.deinit(allocator);

    const stdout = std.io.getStdOut().writer();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        try runOp(allocator, calculator.tool(), line, stdout);
    }
}

fn runOp(
    allocator: std.mem.Allocator,
    tool: agent_tools.Tool,
    line: []const u8,
    writer: anytype,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const op = getString(parsed.value, "op") orelse return EvalError.InvalidScenario;
    const label = getString(parsed.value, "function") orelse return EvalError.InvalidScenario;

    if (std.mem.eql(u8, op, "execute")) {
        const args = getField(parsed.value, "args") orelse return EvalError.InvalidScenario;
        var result = try tool.execute(allocator, args);
        defer result.deinit(allocator);
        try writeExecuteResult(writer, label, result);
    } else if (std.mem.eql(u8, op, "execute_raw")) {
        const args_json = getString(parsed.value, "args_json") orelse return EvalError.InvalidScenario;
        var parsed_args = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
            try writeExecuteParseError(writer, label);
            return;
        };
        defer parsed_args.deinit();
        if (containsNonFiniteNumber(parsed_args.value)) {
            try writeExecuteParseError(writer, label);
            return;
        }

        var result = try tool.execute(allocator, parsed_args.value);
        defer result.deinit(allocator);
        try writeExecuteResult(writer, label, result);
    } else {
        return EvalError.InvalidScenario;
    }
}

fn writeExecuteResult(writer: anytype, label: []const u8, result: agent_tools.ToolResult) !void {
    try writer.writeAll("{\"op\":\"execute\",\"function\":");
    try std.json.stringify(label, .{}, writer);
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

fn writeExecuteParseError(writer: anytype, label: []const u8) !void {
    try writer.writeAll("{\"op\":\"execute\",\"function\":");
    try std.json.stringify(label, .{}, writer);
    try writer.writeAll(",\"result\":{\"success\":false,\"output\":\"\",\"error\":\"Invalid args JSON\"}}\n");
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

fn containsNonFiniteNumber(value: std.json.Value) bool {
    switch (value) {
        .null, .bool, .integer, .string => return false,
        .float => |inner| return !std.math.isFinite(inner),
        .number_string => |inner| {
            const parsed = std.fmt.parseFloat(f64, inner) catch return true;
            return !std.math.isFinite(parsed);
        },
        .array => |array| {
            for (array.items) |item| {
                if (containsNonFiniteNumber(item)) return true;
            }
            return false;
        },
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                if (containsNonFiniteNumber(entry.value_ptr.*)) return true;
            }
            return false;
        },
    }
}
