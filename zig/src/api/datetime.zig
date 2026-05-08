const std = @import("std");

pub const DateParts = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub fn formatRfc3339(allocator: std.mem.Allocator, unix_seconds: i64) ![]u8 {
    const parts = partsFromUnixSeconds(unix_seconds);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00",
        .{ @as(u32, @intCast(parts.year)), parts.month, parts.day, parts.hour, parts.minute, parts.second },
    );
}

pub fn writeRfc3339(writer: anytype, unix_seconds: i64) !void {
    const parts = partsFromUnixSeconds(unix_seconds);
    try writer.print(
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00",
        .{ @as(u32, @intCast(parts.year)), parts.month, parts.day, parts.hour, parts.minute, parts.second },
    );
}

pub fn parseRfc3339(value: []const u8) !i64 {
    if (value.len < "1970-01-01T00:00:00Z".len) return error.InvalidRfc3339;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') {
        return error.InvalidRfc3339;
    }

    const year = try parseDigits(i32, value[0..4]);
    const month = try parseDigits(u8, value[5..7]);
    const day = try parseDigits(u8, value[8..10]);
    const hour = try parseDigits(u8, value[11..13]);
    const minute = try parseDigits(u8, value[14..16]);
    const second = try parseDigits(u8, value[17..19]);
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) or hour > 23 or minute > 59 or second > 60) {
        return error.InvalidRfc3339;
    }

    var cursor: usize = 19;
    if (cursor < value.len and value[cursor] == '.') {
        cursor += 1;
        const frac_start = cursor;
        while (cursor < value.len and std.ascii.isDigit(value[cursor])) cursor += 1;
        if (cursor == frac_start) return error.InvalidRfc3339;
    }
    if (cursor >= value.len) return error.InvalidRfc3339;

    var offset_seconds: i64 = 0;
    if (value[cursor] == 'Z') {
        cursor += 1;
    } else if (value[cursor] == '+' or value[cursor] == '-') {
        if (cursor + 6 != value.len or value[cursor + 3] != ':') return error.InvalidRfc3339;
        const sign: i64 = if (value[cursor] == '+') 1 else -1;
        const offset_hour = try parseDigits(u8, value[cursor + 1 .. cursor + 3]);
        const offset_minute = try parseDigits(u8, value[cursor + 4 .. cursor + 6]);
        if (offset_hour > 23 or offset_minute > 59) return error.InvalidRfc3339;
        offset_seconds = sign * (@as(i64, offset_hour) * 3600 + @as(i64, offset_minute) * 60);
        cursor += 6;
    } else {
        return error.InvalidRfc3339;
    }
    if (cursor != value.len) return error.InvalidRfc3339;

    const local = unixSecondsFromParts(.{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = @min(second, 59),
    });
    return local - offset_seconds;
}

pub fn parseOptionalRfc3339(value: ?[]const u8) !?i64 {
    if (value) |inner| return try parseRfc3339(inner);
    return null;
}

pub fn parseRfc3339WithFallback(value: []const u8, fallback_unix_seconds: i64) i64 {
    return parseRfc3339(value) catch fallback_unix_seconds;
}

fn parseDigits(comptime T: type, bytes: []const u8) !T {
    if (bytes.len == 0) return error.InvalidRfc3339;
    var value: T = 0;
    for (bytes) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidRfc3339;
        value = value * 10 + @as(T, @intCast(byte - '0'));
    }
    return value;
}

fn unixSecondsFromParts(parts: DateParts) i64 {
    var days: i64 = 0;
    var year: i32 = 1970;
    if (parts.year >= 1970) {
        while (year < parts.year) : (year += 1) days += daysInYear(year);
    } else {
        while (year > parts.year) {
            year -= 1;
            days -= daysInYear(year);
        }
    }

    var month: u8 = 1;
    while (month < parts.month) : (month += 1) days += daysInMonth(parts.year, month);
    days += @as(i64, parts.day) - 1;

    return days * 86400 + @as(i64, parts.hour) * 3600 + @as(i64, parts.minute) * 60 + @as(i64, parts.second);
}

fn partsFromUnixSeconds(unix_seconds: i64) DateParts {
    var days = @divFloor(unix_seconds, 86400);
    var seconds_of_day = @mod(unix_seconds, 86400);
    var year: i32 = 1970;

    if (days >= 0) {
        while (true) {
            const year_days = daysInYear(year);
            if (days < year_days) break;
            days -= year_days;
            year += 1;
        }
    } else {
        while (days < 0) {
            year -= 1;
            days += daysInYear(year);
        }
    }

    var month: u8 = 1;
    while (true) {
        const month_days = daysInMonth(year, month);
        if (days < month_days) break;
        days -= month_days;
        month += 1;
    }

    const hour: u8 = @intCast(@divFloor(seconds_of_day, 3600));
    seconds_of_day = @mod(seconds_of_day, 3600);
    const minute: u8 = @intCast(@divFloor(seconds_of_day, 60));
    const second: u8 = @intCast(@mod(seconds_of_day, 60));

    return .{
        .year = year,
        .month = month,
        .day = @as(u8, @intCast(days + 1)),
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

fn daysInYear(year: i32) i64 {
    return if (isLeapYear(year)) 366 else 365;
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}

test "RFC3339 format and parse UTC seconds" {
    const formatted = try formatRfc3339(std.testing.allocator, 0);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00+00:00", formatted);
    try std.testing.expectEqual(@as(i64, 0), try parseRfc3339(formatted));
    try std.testing.expectEqual(@as(i64, 0), try parseRfc3339("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 0), try parseRfc3339("1970-01-01T01:30:00+01:30"));
}

test "RFC3339 parser accepts fractions and fallback handles invalid input" {
    try std.testing.expectEqual(@as(i64, 0), try parseRfc3339("1970-01-01T00:00:00.123456789Z"));
    try std.testing.expectEqual(@as(i64, 3600), try parseRfc3339("1970-01-01T03:00:00+02:00"));
    try std.testing.expectEqual(@as(i64, 42), parseRfc3339WithFallback("not-a-date", 42));
}
