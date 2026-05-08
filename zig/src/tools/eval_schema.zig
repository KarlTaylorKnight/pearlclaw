//! eval-schema — offline SchemaCleanr parity runner.
//!
//! Reads JSONL schema-cleaning ops from stdin and writes one JSON response per
//! op. The Python eval driver canonicalizes output before byte comparison.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const schema_api = zeroclaw.api.schema;

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
    const schema_value = getField(parsed.value, "schema") orelse return EvalError.InvalidScenario;

    if (std.mem.eql(u8, op, "clean_for_gemini")) {
        var cleaned = try schema_api.cleanForGemini(allocator, schema_value);
        defer schema_api.freeJsonValue(allocator, &cleaned);
        try writeJsonResult(writer, op, cleaned);
    } else if (std.mem.eql(u8, op, "clean_for_anthropic")) {
        var cleaned = try schema_api.cleanForAnthropic(allocator, schema_value);
        defer schema_api.freeJsonValue(allocator, &cleaned);
        try writeJsonResult(writer, op, cleaned);
    } else if (std.mem.eql(u8, op, "clean_for_openai")) {
        var cleaned = try schema_api.cleanForOpenai(allocator, schema_value);
        defer schema_api.freeJsonValue(allocator, &cleaned);
        try writeJsonResult(writer, op, cleaned);
    } else if (std.mem.eql(u8, op, "clean_conservative")) {
        var cleaned = try schema_api.clean(allocator, schema_value, .Conservative);
        defer schema_api.freeJsonValue(allocator, &cleaned);
        try writeJsonResult(writer, op, cleaned);
    } else if (std.mem.eql(u8, op, "validate")) {
        try writer.writeAll("{\"op\":\"validate\",\"result\":{");
        schema_api.validate(schema_value) catch {
            try writer.writeAll("\"error\":\"InvalidSchema\"}}\n");
            return;
        };
        try writer.writeAll("\"ok\":true}}\n");
    } else {
        return EvalError.InvalidScenario;
    }
}

fn writeJsonResult(writer: anytype, op: []const u8, result: std.json.Value) !void {
    try writer.writeAll("{\"op\":");
    try std.json.stringify(op, .{}, writer);
    try writer.writeAll(",\"result\":");
    try writeJsonValue(writer, result);
    try writer.writeAll("}\n");
}

fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |inner| try writer.writeAll(if (inner) "true" else "false"),
        .integer => |inner| try writer.print("{d}", .{inner}),
        .float => |inner| try std.json.stringify(inner, .{}, writer),
        .number_string => |inner| try writer.writeAll(inner),
        .string => |inner| try std.json.stringify(inner, .{}, writer),
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            try writer.writeByte('{');
            var first = true;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try std.json.stringify(entry.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
    }
}

fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}
