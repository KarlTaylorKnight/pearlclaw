const std = @import("std");

pub const ParserError = error{OutOfMemory};

pub const ParsedToolCall = struct {
    name: []u8,
    arguments: std.json.Value,
    tool_call_id: ?[]u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        freeJsonValue(allocator, &self.arguments);
        if (self.tool_call_id) |id| allocator.free(id);
        self.* = undefined;
    }
};

pub const ParseResult = struct {
    text: []u8,
    calls: []ParsedToolCall,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.calls) |*call| call.deinit(allocator);
        allocator.free(self.calls);
        self.* = undefined;
    }
};

pub fn dupTrimmed(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return allocator.dupe(u8, std.mem.trim(u8, value, " \t\r\n"));
}

pub fn emptyObject(allocator: std.mem.Allocator) std.json.Value {
    return .{ .object = std.json.ObjectMap.init(allocator) };
}

pub fn singletonStringObject(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !std.json.Value {
    var object = std.json.ObjectMap.init(allocator);
    errdefer {
        var tmp = std.json.Value{ .object = object };
        freeJsonValue(allocator, &tmp);
    }
    try object.put(try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
    return .{ .object = object };
}

pub fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ParserError!std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |inner| .{ .bool = inner },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .number_string => |inner| .{ .number_string = try allocator.dupe(u8, inner) },
        .string => |inner| .{ .string = try allocator.dupe(u8, inner) },
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            errdefer {
                var tmp = std.json.Value{ .array = cloned };
                freeJsonValue(allocator, &tmp);
            }
            for (array.items) |item| {
                try cloned.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned = std.json.ObjectMap.init(allocator);
            errdefer {
                var tmp = std.json.Value{ .object = cloned };
                freeJsonValue(allocator, &tmp);
            }
            var it = object.iterator();
            while (it.next()) |entry| {
                try cloned.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = cloned };
        },
    };
}

pub fn freeJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .null, .bool, .integer, .float => {},
        .number_string => |s| allocator.free(s),
        .string => |s| allocator.free(s),
        .array => |*array| {
            for (array.items) |*item| freeJsonValue(allocator, item);
            array.deinit();
        },
        .object => |*object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
    }
}

pub fn parseJsonValueOwned(allocator: std.mem.Allocator, raw: []const u8) ParserError!?std.json.Value {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    return try cloneJsonValue(allocator, parsed.value);
}

pub fn putOwned(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) ParserError!void {
    errdefer {
        var tmp = value;
        freeJsonValue(allocator, &tmp);
    }
    try object.put(try allocator.dupe(u8, key), value);
}

test "smoke" {
    var value = try singletonStringObject(std.testing.allocator, "command", "pwd");
    defer freeJsonValue(std.testing.allocator, &value);
    try std.testing.expect(value.object.contains("command"));
}
