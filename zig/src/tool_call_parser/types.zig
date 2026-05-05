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
    arena: ?std.heap.ArenaAllocator = null,
    arena_backed: bool = false,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.arena) |*arena| {
            arena.deinit();
            self.* = undefined;
            return;
        }
        if (self.arena_backed) {
            self.* = undefined;
            return;
        }
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
    var parser = JsonParser{
        .allocator = allocator,
        .input = raw,
    };
    return parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return null,
    };
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

const JsonParseError = error{ OutOfMemory, InvalidJson };

const JsonParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    fn parse(self: *JsonParser) JsonParseError!std.json.Value {
        self.skipWhitespace();
        var value = try self.parseValue();
        errdefer freeJsonValue(self.allocator, &value);
        self.skipWhitespace();
        if (self.pos != self.input.len) return error.InvalidJson;
        return value;
    }

    fn parseValue(self: *JsonParser) JsonParseError!std.json.Value {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.InvalidJson;
        return switch (self.input[self.pos]) {
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            '"' => .{ .string = try self.parseStringOwned() },
            't' => blk: {
                try self.consumeLiteral("true");
                break :blk .{ .bool = true };
            },
            'f' => blk: {
                try self.consumeLiteral("false");
                break :blk .{ .bool = false };
            },
            'n' => blk: {
                try self.consumeLiteral("null");
                break :blk .null;
            },
            '-', '0'...'9' => .{ .number_string = try self.parseNumberOwned() },
            else => error.InvalidJson,
        };
    }

    fn parseObject(self: *JsonParser) JsonParseError!std.json.Value {
        try self.expectByte('{');
        var object = std.json.ObjectMap.init(self.allocator);
        errdefer {
            var tmp = std.json.Value{ .object = object };
            freeJsonValue(self.allocator, &tmp);
        }

        self.skipWhitespace();
        if (self.consumeByte('}')) return .{ .object = object };

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != '"') return error.InvalidJson;
            const key = try self.parseStringOwned();
            var key_owned = true;
            errdefer if (key_owned) self.allocator.free(key);

            self.skipWhitespace();
            try self.expectByte(':');

            var value = try self.parseValue();
            var value_owned = true;
            errdefer if (value_owned) freeJsonValue(self.allocator, &value);

            const gop = try object.getOrPut(key);
            if (gop.found_existing) return error.InvalidJson;
            gop.value_ptr.* = value;
            key_owned = false;
            value_owned = false;

            self.skipWhitespace();
            if (self.consumeByte('}')) break;
            try self.expectByte(',');
        }

        return .{ .object = object };
    }

    fn parseArray(self: *JsonParser) JsonParseError!std.json.Value {
        try self.expectByte('[');
        var array = std.json.Array.init(self.allocator);
        errdefer {
            var tmp = std.json.Value{ .array = array };
            freeJsonValue(self.allocator, &tmp);
        }

        self.skipWhitespace();
        if (self.consumeByte(']')) return .{ .array = array };

        while (true) {
            var value = try self.parseValue();
            var value_owned = true;
            errdefer if (value_owned) freeJsonValue(self.allocator, &value);
            try array.append(value);
            value_owned = false;

            self.skipWhitespace();
            if (self.consumeByte(']')) break;
            try self.expectByte(',');
        }

        return .{ .array = array };
    }

    fn parseStringOwned(self: *JsonParser) JsonParseError![]u8 {
        try self.expectByte('"');
        const start = self.pos;
        while (self.pos < self.input.len) : (self.pos += 1) {
            const ch = self.input[self.pos];
            if (ch == '"') {
                const out = try self.allocator.dupe(u8, self.input[start..self.pos]);
                self.pos += 1;
                return out;
            }
            if (ch == '\\') break;
            if (ch < 0x20) return error.InvalidJson;
        }

        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice(self.input[start..self.pos]);

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '"') {
                self.pos += 1;
                return try out.toOwnedSlice();
            }
            if (ch < 0x20) return error.InvalidJson;
            if (ch != '\\') {
                try out.append(ch);
                self.pos += 1;
                continue;
            }

            self.pos += 1;
            if (self.pos >= self.input.len) return error.InvalidJson;
            const escaped = self.input[self.pos];
            self.pos += 1;
            switch (escaped) {
                '"', '\\', '/' => try out.append(escaped),
                'b' => try out.append(0x08),
                'f' => try out.append(0x0c),
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                'u' => {
                    const codepoint = try self.parseUnicodeEscape();
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidJson;
                    try out.appendSlice(buf[0..len]);
                },
                else => return error.InvalidJson,
            }
        }

        return error.InvalidJson;
    }

    fn parseUnicodeEscape(self: *JsonParser) JsonParseError!u21 {
        const high = try self.parseHexQuad();
        if (high >= 0xD800 and high <= 0xDBFF) {
            if (self.pos + 2 > self.input.len or self.input[self.pos] != '\\' or self.input[self.pos + 1] != 'u') {
                return error.InvalidJson;
            }
            self.pos += 2;
            const low = try self.parseHexQuad();
            if (low < 0xDC00 or low > 0xDFFF) return error.InvalidJson;
            return 0x10000 + (((high - 0xD800) << 10) | (low - 0xDC00));
        }
        if (high >= 0xDC00 and high <= 0xDFFF) return error.InvalidJson;
        return high;
    }

    fn parseHexQuad(self: *JsonParser) JsonParseError!u21 {
        if (self.pos + 4 > self.input.len) return error.InvalidJson;
        var value: u21 = 0;
        for (self.input[self.pos .. self.pos + 4]) |ch| {
            value = (value << 4) | (hexValue(ch) orelse return error.InvalidJson);
        }
        self.pos += 4;
        return value;
    }

    fn parseNumberOwned(self: *JsonParser) JsonParseError![]u8 {
        const start = self.pos;
        if (self.consumeByte('-') and self.pos >= self.input.len) return error.InvalidJson;

        if (self.consumeByte('0')) {
            if (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                return error.InvalidJson;
            }
        } else {
            try self.consumeDigits();
        }

        if (self.consumeByte('.')) {
            try self.consumeDigits();
        }

        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.pos += 1;
            _ = self.consumeByte('-') or self.consumeByte('+');
            try self.consumeDigits();
        }

        return try self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    fn consumeDigits(self: *JsonParser) JsonParseError!void {
        const start = self.pos;
        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
            self.pos += 1;
        }
        if (self.pos == start) return error.InvalidJson;
    }

    fn consumeLiteral(self: *JsonParser, literal: []const u8) JsonParseError!void {
        if (!std.mem.startsWith(u8, self.input[self.pos..], literal)) return error.InvalidJson;
        self.pos += literal.len;
    }

    fn expectByte(self: *JsonParser, expected: u8) JsonParseError!void {
        if (!self.consumeByte(expected)) return error.InvalidJson;
    }

    fn consumeByte(self: *JsonParser, expected: u8) bool {
        if (self.pos >= self.input.len or self.input[self.pos] != expected) return false;
        self.pos += 1;
        return true;
    }

    fn skipWhitespace(self: *JsonParser) void {
        while (self.pos < self.input.len and switch (self.input[self.pos]) {
            ' ', '\t', '\r', '\n' => true,
            else => false,
        }) {
            self.pos += 1;
        }
    }
};

fn hexValue(ch: u8) ?u21 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => 10 + ch - 'a',
        'A'...'F' => 10 + ch - 'A',
        else => null,
    };
}
