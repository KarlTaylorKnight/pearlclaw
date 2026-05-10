//! eval-provider-secrets — provider error secret-scrubbing parity runner.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const provider_secrets = zeroclaw.providers;

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
    const input = getString(parsed.value, "input") orelse return EvalError.InvalidScenario;

    if (std.mem.eql(u8, op, "scrub")) {
        const output = try provider_secrets.scrubSecretPatterns(allocator, input);
        defer allocator.free(output);
        try writeOutput(writer, op, output);
    } else if (std.mem.eql(u8, op, "sanitize")) {
        const output = try provider_secrets.sanitizeApiError(allocator, input);
        defer allocator.free(output);
        try writeOutput(writer, op, output);
    } else {
        return EvalError.InvalidScenario;
    }
}

fn writeOutput(writer: anytype, op: []const u8, output: []const u8) !void {
    try writer.writeAll("{\"op\":");
    try std.json.stringify(op, .{}, writer);
    try writer.writeAll(",\"result\":{\"output\":");
    try std.json.stringify(output, .{}, writer);
    try writer.writeAll("}}\n");
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const inner = value.object.get(key) orelse return null;
    if (inner != .string) return null;
    return inner.string;
}
