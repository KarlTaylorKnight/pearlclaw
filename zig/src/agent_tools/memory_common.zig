const std = @import("std");
const tool_mod = @import("tool.zig");
const memory = @import("../memory/root.zig");
const parser_types = @import("../tool_call_parser/types.zig");

pub const Tool = tool_mod.Tool;
pub const ToolResult = tool_mod.ToolResult;
pub const SqliteMemory = memory.SqliteMemory;
pub const MemoryCategory = memory.MemoryCategory;
pub const MemoryEntry = memory.MemoryEntry;

pub const MemoryReturn = union(enum) {
    output: []u8,
    failure: Failure,
};

pub const Failure = struct {
    output: []u8,
    error_msg: []u8,
};

pub const JsonArgs = struct {
    allocator: std.mem.Allocator,
    value: std.json.Value,
    error_msg: ?[]u8 = null,

    pub fn deinit(self: *JsonArgs) void {
        if (self.error_msg) |msg| self.allocator.free(msg);
        self.error_msg = null;
    }

    pub fn takeError(self: *JsonArgs) []u8 {
        const msg = self.error_msg.?;
        self.error_msg = null;
        return msg;
    }

    pub fn setError(self: *JsonArgs, message: []const u8) !void {
        self.error_msg = try self.allocator.dupe(u8, message);
    }

    pub fn setErrorFmt(self: *JsonArgs, comptime fmt: []const u8, args: anytype) !void {
        self.error_msg = try std.fmt.allocPrint(self.allocator, fmt, args);
    }

    pub fn field(self: JsonArgs, key: []const u8) ?std.json.Value {
        if (self.value != .object) return null;
        return self.value.object.get(key);
    }

    pub fn requiredString(self: *JsonArgs, key: []const u8) ![]const u8 {
        const raw = self.field(key) orelse {
            try self.setErrorFmt("Missing required parameter: {s}", .{key});
            return error.InvalidArgument;
        };
        if (raw != .string) {
            try self.setErrorFmt("Missing required parameter: {s}", .{key});
            return error.InvalidArgument;
        }
        return raw.string;
    }

    pub fn requiredNonEmptyString(self: *JsonArgs, key: []const u8) ![]const u8 {
        const value = try self.requiredString(key);
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) {
            try self.setErrorFmt("{s} must not be empty", .{key});
            return error.InvalidArgument;
        }
        return value;
    }

    pub fn optionalString(self: JsonArgs, key: []const u8) ?[]const u8 {
        const raw = self.field(key) orelse return null;
        return switch (raw) {
            .null => null,
            .string => |inner| inner,
            else => null,
        };
    }

    pub fn optionalNumber(self: JsonArgs, key: []const u8) ?f64 {
        const raw = self.field(key) orelse return null;
        return valueAsF64(raw);
    }

    pub fn optionalInteger(self: JsonArgs, key: []const u8) ?i64 {
        const raw = self.field(key) orelse return null;
        return switch (raw) {
            .integer => |inner| inner,
            else => null,
        };
    }

    pub fn requiredBool(self: *JsonArgs, key: []const u8) !bool {
        const raw = self.field(key) orelse {
            try self.setErrorFmt("Missing required parameter: {s}", .{key});
            return error.InvalidArgument;
        };
        if (raw != .bool) {
            try self.setErrorFmt("Missing required parameter: {s}", .{key});
            return error.InvalidArgument;
        }
        return raw.bool;
    }

    pub fn optionalTags(self: *JsonArgs) ![]const []const u8 {
        const raw = self.field("tags") orelse return try self.allocator.alloc([]const u8, 0);
        if (raw == .null) return try self.allocator.alloc([]const u8, 0);
        if (raw != .array) {
            try self.setError("Parameter 'tags' must be an array of strings");
            return error.InvalidArgument;
        }

        const tags = try self.allocator.alloc([]const u8, raw.array.items.len);
        errdefer self.allocator.free(tags);
        for (raw.array.items, 0..) |item, i| {
            if (item != .string) {
                try self.setError("Parameter 'tags' must be an array of strings");
                return error.InvalidArgument;
            }
            tags[i] = item.string;
        }
        return tags;
    }
};

pub fn parametersSchema(allocator: std.mem.Allocator, json: []const u8) !std.json.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    return parser_types.cloneJsonValue(allocator, parsed.value);
}

pub fn resultFromReturn(allocator: std.mem.Allocator, value: MemoryReturn) !ToolResult {
    return switch (value) {
        .output => |output| .{
            .success = true,
            .output = output,
            .error_msg = null,
        },
        .failure => |failed| blk: {
            errdefer allocator.free(failed.output);
            errdefer allocator.free(failed.error_msg);
            break :blk .{
                .success = false,
                .output = failed.output,
                .error_msg = failed.error_msg,
            };
        },
    };
}

pub fn failure(allocator: std.mem.Allocator, message: []const u8) !MemoryReturn {
    const output = try allocator.dupe(u8, "");
    errdefer allocator.free(output);
    const error_msg = try allocator.dupe(u8, message);
    return .{ .failure = .{ .output = output, .error_msg = error_msg } };
}

pub fn failureWithOutput(allocator: std.mem.Allocator, output_message: []const u8, error_message: []const u8) !MemoryReturn {
    const output = try allocator.dupe(u8, output_message);
    errdefer allocator.free(output);
    const error_msg = try allocator.dupe(u8, error_message);
    return .{ .failure = .{ .output = output, .error_msg = error_msg } };
}

pub fn invalidResult(reader: *JsonArgs, err: anyerror) anyerror!MemoryReturn {
    if (err == error.InvalidArgument) {
        const msg = reader.takeError();
        errdefer reader.allocator.free(msg);
        const output = try reader.allocator.dupe(u8, "");
        return .{ .failure = .{ .output = output, .error_msg = msg } };
    }
    return err;
}

pub fn categoryFromString(allocator: std.mem.Allocator, category: []const u8) !MemoryCategory {
    return MemoryCategory.fromString(allocator, category);
}

pub fn tagsContainAll(entry_tags: []const []u8, required_tags: []const []const u8) bool {
    for (required_tags) |required| {
        var found = false;
        for (entry_tags) |tag| {
            if (std.mem.eql(u8, tag, required)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

pub fn timestampDaysAgo(allocator: std.mem.Allocator, days: i64) ![]u8 {
    if (days < 0) return error.InvalidArgument;
    const now = std.time.timestamp();
    const delta = days * std.time.s_per_day;
    const cutoff = if (delta >= now) 0 else now - delta;
    return formatEpochSeconds(allocator, @intCast(cutoff));
}

pub fn formatTagList(allocator: std.mem.Allocator, tags: []const []u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    for (tags, 0..) |tag, i| {
        if (i != 0) try out.appendSlice(", ");
        try out.appendSlice(tag);
    }
    return out.toOwnedSlice();
}

pub fn jsonEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return std.json.stringifyAlloc(allocator, value, .{});
}

pub fn writeMarkdownEscaped(writer: anytype, value: []const u8) !void {
    for (value) |byte| {
        if (byte == '|') try writer.writeByte('\\');
        if (byte == '\n' or byte == '\r') {
            try writer.writeByte(' ');
        } else {
            try writer.writeByte(byte);
        }
    }
}

fn valueAsF64(value: std.json.Value) ?f64 {
    const n: f64 = switch (value) {
        .integer => |inner| @floatFromInt(inner),
        .float => |inner| inner,
        .number_string => |inner| std.fmt.parseFloat(f64, inner) catch return null,
        else => return null,
    };
    if (!std.math.isFinite(n)) return null;
    return n;
}

fn formatEpochSeconds(allocator: std.mem.Allocator, seconds: u64) ![]u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            @as(u8, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}
