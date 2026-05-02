const std = @import("std");
const types = @import("types.zig");

pub fn parseArgumentsValue(
    allocator: std.mem.Allocator,
    raw: ?std.json.Value,
) types.ParserError!std.json.Value {
    const value = raw orelse return types.emptyObject(allocator);
    if (value == .string) {
        if (try types.parseJsonValueOwned(allocator, value.string)) |parsed| {
            return parsed;
        }
        return types.emptyObject(allocator);
    }
    return types.cloneJsonValue(allocator, value);
}

pub fn parseToolCallId(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    function: ?std.json.Value,
) types.ParserError!?[]u8 {
    const candidates = [_]?std.json.Value{
        if (function) |func| getField(func, "id") else null,
        getField(root, "id"),
        getField(root, "tool_call_id"),
        getField(root, "call_id"),
    };

    for (candidates) |candidate| {
        if (candidate) |value| {
            if (value == .string) {
                const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
                if (trimmed.len != 0) return try allocator.dupe(u8, trimmed);
            }
        }
    }
    return null;
}

pub fn parseToolCallValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) types.ParserError!?types.ParsedToolCall {
    if (getField(value, "function")) |function| {
        const maybe_name = getStringField(function, "name");
        const name_trimmed = std.mem.trim(u8, maybe_name orelse "", " \t\r\n");
        if (name_trimmed.len != 0) {
            var call = types.ParsedToolCall{
                .name = try allocator.dupe(u8, name_trimmed),
                .arguments = undefined,
                .tool_call_id = null,
            };
            errdefer allocator.free(call.name);
            call.tool_call_id = try parseToolCallId(allocator, value, function);
            errdefer if (call.tool_call_id) |id| allocator.free(id);
            call.arguments = try parseArgumentsValue(
                allocator,
                getField(function, "arguments") orelse getField(function, "parameters"),
            );
            return call;
        }
    }

    const maybe_name = getStringField(value, "name");
    const name_trimmed = std.mem.trim(u8, maybe_name orelse "", " \t\r\n");
    if (name_trimmed.len == 0) return null;

    var call = types.ParsedToolCall{
        .name = try allocator.dupe(u8, name_trimmed),
        .arguments = undefined,
        .tool_call_id = null,
    };
    errdefer allocator.free(call.name);
    call.tool_call_id = try parseToolCallId(allocator, value, null);
    errdefer if (call.tool_call_id) |id| allocator.free(id);
    call.arguments = try parseArgumentsValue(
        allocator,
        getField(value, "arguments") orelse getField(value, "parameters"),
    );
    return call;
}

pub fn parseToolCallsFromJsonValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) types.ParserError![]types.ParsedToolCall {
    var calls = std.ArrayList(types.ParsedToolCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }

    if (getField(value, "tool_calls")) |tool_calls| {
        if (tool_calls == .array) {
            for (tool_calls.array.items) |item| {
                if (try parseToolCallValue(allocator, item)) |parsed| {
                    var call = parsed;
                    try appendParsedCall(allocator, &calls, &call);
                }
            }
            if (calls.items.len != 0) return calls.toOwnedSlice();
        }
    }

    if (value == .array) {
        for (value.array.items) |item| {
            if (try parseToolCallValue(allocator, item)) |parsed| {
                var call = parsed;
                try appendParsedCall(allocator, &calls, &call);
            }
        }
        return calls.toOwnedSlice();
    }

    if (try parseToolCallValue(allocator, value)) |parsed| {
        var call = parsed;
        try appendParsedCall(allocator, &calls, &call);
    }

    return calls.toOwnedSlice();
}

pub fn extractFirstJsonValueWithEnd(
    allocator: std.mem.Allocator,
    input: []const u8,
) types.ParserError!?struct { value: std.json.Value, end: usize } {
    const trimmed = std.mem.trimLeft(u8, input, " \t\r\n");
    const trim_offset = input.len - trimmed.len;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const ch = trimmed[i];
        if (ch != '{' and ch != '[') continue;
        const slice = trimmed[i..];
        if (try findJsonValueEnd(allocator, slice)) |end| {
            if (try types.parseJsonValueOwned(allocator, slice[0..end])) |value| {
                return .{ .value = value, .end = trim_offset + i + end };
            }
        }
    }
    return null;
}

pub fn extractJsonValues(
    allocator: std.mem.Allocator,
    input: []const u8,
) types.ParserError![]std.json.Value {
    var values = std.ArrayList(std.json.Value).init(allocator);
    errdefer {
        for (values.items) |*value| types.freeJsonValue(allocator, value);
        values.deinit();
    }

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return values.toOwnedSlice();

    if (try types.parseJsonValueOwned(allocator, trimmed)) |value| {
        var owned_value = value;
        try appendJsonValue(allocator, &values, &owned_value);
        return values.toOwnedSlice();
    }

    var idx: usize = 0;
    while (idx < trimmed.len) {
        const ch = trimmed[idx];
        if (ch == '{' or ch == '[') {
            const slice = trimmed[idx..];
            if (try findJsonValueEnd(allocator, slice)) |end| {
                if (try types.parseJsonValueOwned(allocator, slice[0..end])) |value| {
                    var owned_value = value;
                    try appendJsonValue(allocator, &values, &owned_value);
                    idx += end;
                    continue;
                }
            }
        }
        idx += 1;
    }

    return values.toOwnedSlice();
}

pub fn findJsonEnd(allocator: std.mem.Allocator, input: []const u8) types.ParserError!?usize {
    const trimmed = std.mem.trimLeft(u8, input, " \t\r\n");
    const offset = input.len - trimmed.len;
    if (!std.mem.startsWith(u8, trimmed, "{")) return null;
    return if (try findJsonValueEnd(allocator, trimmed)) |end| offset + end else null;
}

pub fn canonicalizeJsonForToolSignature(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) types.ParserError!std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |inner| .{ .bool = inner },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .number_string => |inner| .{ .number_string = try allocator.dupe(u8, inner) },
        .string => |inner| .{ .string = try allocator.dupe(u8, inner) },
        .array => |array| blk: {
            var out = std.json.Array.init(allocator);
            errdefer {
                var tmp = std.json.Value{ .array = out };
                types.freeJsonValue(allocator, &tmp);
            }
            for (array.items) |item| try out.append(try canonicalizeJsonForToolSignature(allocator, item));
            break :blk .{ .array = out };
        },
        .object => |object| blk: {
            var keys = std.ArrayList([]const u8).init(allocator);
            defer keys.deinit();
            var it = object.iterator();
            while (it.next()) |entry| try keys.append(entry.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, lessThanString);

            var out = std.json.ObjectMap.init(allocator);
            errdefer {
                var tmp = std.json.Value{ .object = out };
                types.freeJsonValue(allocator, &tmp);
            }
            for (keys.items) |key| {
                const child = object.get(key).?;
                try out.put(
                    try allocator.dupe(u8, key),
                    try canonicalizeJsonForToolSignature(allocator, child),
                );
            }
            break :blk .{ .object = out };
        },
    };
}

pub fn writeCanonicalJsonValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    writer: anytype,
) !void {
    switch (value) {
        .null, .bool, .integer, .float, .number_string, .string => {
            try std.json.stringify(value, .{}, writer);
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                try writeCanonicalJsonValue(allocator, item, writer);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            const keys = try allocator.alloc([]const u8, object.count());
            defer allocator.free(keys);

            var i: usize = 0;
            var it = object.iterator();
            while (it.next()) |entry| : (i += 1) keys[i] = entry.key_ptr.*;
            std.mem.sort([]const u8, keys, {}, lessThanString);

            try writer.writeByte('{');
            for (keys, 0..) |key, idx| {
                if (idx != 0) try writer.writeByte(',');
                try std.json.stringify(key, .{}, writer);
                try writer.writeByte(':');
                try writeCanonicalJsonValue(allocator, object.get(key).?, writer);
            }
            try writer.writeByte('}');
        },
    }
}

fn findJsonValueEnd(allocator: std.mem.Allocator, input: []const u8) types.ParserError!?usize {
    if (input.len == 0 or (input[0] != '{' and input[0] != '[')) return null;

    var stack = std.ArrayList(u8).init(allocator);
    defer stack.deinit();
    var in_string = false;
    var escape_next = false;

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const ch = input[i];
        if (escape_next) {
            escape_next = false;
            continue;
        }

        if (ch == '\\' and in_string) {
            escape_next = true;
            continue;
        }
        if (ch == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        if (ch == '{' or ch == '[') {
            try stack.append(ch);
            continue;
        }
        if (ch == '}' or ch == ']') {
            if (stack.items.len == 0) return null;
            const expected_open: u8 = if (ch == '}') '{' else '[';
            const actual = stack.pop().?;
            if (actual != expected_open) return null;
            if (stack.items.len == 0) return i + 1;
        }
    }
    return null;
}

pub fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

pub fn getStringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn appendParsedCall(
    allocator: std.mem.Allocator,
    calls: *std.ArrayList(types.ParsedToolCall),
    call: *types.ParsedToolCall,
) !void {
    var call_owned = true;
    errdefer if (call_owned) call.deinit(allocator);
    try calls.append(call.*);
    call_owned = false;
}

fn appendJsonValue(
    allocator: std.mem.Allocator,
    values: *std.ArrayList(std.json.Value),
    value: *std.json.Value,
) !void {
    var value_owned = true;
    errdefer if (value_owned) types.freeJsonValue(allocator, value);
    try values.append(value.*);
    value_owned = false;
}

test "smoke" {
    const values = try extractJsonValues(std.testing.allocator, "x {\"b\":2,\"a\":1} y");
    defer {
        for (values) |*value| types.freeJsonValue(std.testing.allocator, value);
        std.testing.allocator.free(values);
    }
    try std.testing.expectEqual(@as(usize, 1), values.len);
}
