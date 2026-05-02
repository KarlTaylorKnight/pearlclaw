const std = @import("std");
const types = @import("types.zig");
const glm = @import("glm.zig");

// MVZR_GAP: Rust Perl/FunctionCall regexes use capture groups:
// `(?s)(?:\[TOOL_CALL\]|TOOL_CALL)\s*\{(.+?)\}\}\s*(?:\[/TOOL_CALL\]|/TOOL_CALL)`,
// `tool\s*=>\s*"([^"]+)"`, `(?s)args\s*=>\s*\{(.+?)(?:\}|$)`,
// `--(\w+)\s+"([^"]+)"`, and the FunctionCall block pattern.
// mvzr does not expose capture groups, so the first-pass port scans markers.

pub fn parsePerlStyleToolCalls(
    allocator: std.mem.Allocator,
    response: []const u8,
) types.ParserError![]types.ParsedToolCall {
    var calls = std.ArrayList(types.ParsedToolCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }

    var pos: usize = 0;
    while (findNextPerlBlock(response[pos..])) |block| {
        const absolute_end = pos + block.end;
        pos += block.start_after_marker;

        const content = block.content;
        const tool_name_raw = findQuotedAfter(content, "tool", "=>") orelse {
            pos = absolute_end;
            continue;
        };
        if (tool_name_raw.len == 0) {
            pos = absolute_end;
            continue;
        }

        const args_block = findArgsBlock(content);
        var args = std.json.ObjectMap.init(allocator);
        var args_owned = true;
        errdefer if (args_owned) {
            var tmp = std.json.Value{ .object = args };
            types.freeJsonValue(allocator, &tmp);
        };
        parseDashArgs(allocator, &args, args_block) catch |err| return err;

        if (args.count() != 0) {
            args_owned = false;
            var arguments = std.json.Value{ .object = args };
            try appendOwnedCall(allocator, &calls, glm.mapToolNameAlias(tool_name_raw), &arguments);
        } else {
            args_owned = false;
            args.deinit();
        }
        pos = absolute_end;
    }

    return calls.toOwnedSlice();
}

pub fn parseFunctionCallToolCalls(
    allocator: std.mem.Allocator,
    response: []const u8,
) types.ParserError![]types.ParsedToolCall {
    var calls = std.ArrayList(types.ParsedToolCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }

    var pos: usize = 0;
    while (std.mem.indexOf(u8, response[pos..], "<FunctionCall>")) |rel| {
        const start = pos + rel;
        const body_start = start + "<FunctionCall>".len;
        const close_rel = std.mem.indexOf(u8, response[body_start..], "</FunctionCall>") orelse break;
        const body = response[body_start .. body_start + close_rel];
        pos = body_start + close_rel + "</FunctionCall>".len;

        const code_start_rel = std.mem.indexOf(u8, body, "<code>") orelse continue;
        const code_start = code_start_rel + "<code>".len;
        const code_end_rel = std.mem.indexOf(u8, body[code_start..], "</code>") orelse continue;
        const tool_name = std.mem.trim(u8, body[0..code_start_rel], " \t\r\n");
        const args_text = body[code_start .. code_start + code_end_rel];
        if (tool_name.len == 0 or !isWord(tool_name)) continue;

        var args = std.json.ObjectMap.init(allocator);
        var args_owned = true;
        errdefer if (args_owned) {
            var tmp = std.json.Value{ .object = args };
            types.freeJsonValue(allocator, &tmp);
        };

        var lines = std.mem.splitScalar(u8, args_text, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            const gt = std.mem.indexOfScalar(u8, line, '>') orelse continue;
            const key = std.mem.trim(u8, line[0..gt], " \t\r\n");
            const value = std.mem.trim(u8, line[gt + 1 ..], " \t\r\n");
            if (key.len != 0 and value.len != 0) {
                try types.putOwned(allocator, &args, key, .{ .string = try allocator.dupe(u8, value) });
            }
        }

        if (args.count() != 0) {
            args_owned = false;
            var arguments = std.json.Value{ .object = args };
            try appendOwnedCall(allocator, &calls, glm.mapToolNameAlias(tool_name), &arguments);
        } else {
            args_owned = false;
            args.deinit();
        }
    }

    return calls.toOwnedSlice();
}

fn findNextPerlBlock(input: []const u8) ?struct {
    content: []const u8,
    start_after_marker: usize,
    end: usize,
} {
    const square = std.mem.indexOf(u8, input, "[TOOL_CALL]");
    const plain = std.mem.indexOf(u8, input, "TOOL_CALL");
    const use_square = if (square) |s|
        if (plain) |p| s <= p else true
    else
        false;

    const marker_start = if (use_square) square.? else plain orelse return null;
    const marker = if (use_square) "[TOOL_CALL]" else "TOOL_CALL";
    const close_marker = if (use_square) "[/TOOL_CALL]" else "/TOOL_CALL";
    const content_start = marker_start + marker.len;
    const close_rel = std.mem.indexOf(u8, input[content_start..], close_marker) orelse return null;
    const close_start = content_start + close_rel;
    return .{
        .content = input[content_start..close_start],
        .start_after_marker = content_start,
        .end = close_start + close_marker.len,
    };
}

fn findQuotedAfter(content: []const u8, key: []const u8, separator: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOf(u8, content[pos..], key)) |rel| {
        const start = pos + rel + key.len;
        var i = start;
        while (i < content.len and std.ascii.isWhitespace(content[i])) i += 1;
        if (!std.mem.startsWith(u8, content[i..], separator)) {
            pos = start;
            continue;
        }
        i += separator.len;
        while (i < content.len and std.ascii.isWhitespace(content[i])) i += 1;
        if (i >= content.len or content[i] != '"') return null;
        i += 1;
        const end_rel = std.mem.indexOfScalar(u8, content[i..], '"') orelse return null;
        return content[i .. i + end_rel];
    }
    return null;
}

fn findArgsBlock(content: []const u8) []const u8 {
    const args_pos = std.mem.indexOf(u8, content, "args") orelse return "";
    const after_args = content[args_pos + "args".len ..];
    const arrow = std.mem.indexOf(u8, after_args, "=>") orelse return "";
    const after_arrow = after_args[arrow + 2 ..];
    const open = std.mem.indexOfScalar(u8, after_arrow, '{') orelse return "";
    const args_start = open + 1;
    const rest = after_arrow[args_start..];
    const close = std.mem.indexOfScalar(u8, rest, '}') orelse rest.len;
    return rest[0..close];
}

fn parseDashArgs(
    allocator: std.mem.Allocator,
    args: *std.json.ObjectMap,
    input: []const u8,
) types.ParserError!void {
    var pos: usize = 0;
    while (std.mem.indexOf(u8, input[pos..], "--")) |rel| {
        const key_start = pos + rel + 2;
        var key_end = key_start;
        while (key_end < input.len and (std.ascii.isAlphanumeric(input[key_end]) or input[key_end] == '_')) {
            key_end += 1;
        }
        if (key_end == key_start) {
            pos = key_start;
            continue;
        }
        const key = input[key_start..key_end];
        var quote_pos = key_end;
        while (quote_pos < input.len and std.ascii.isWhitespace(input[quote_pos])) quote_pos += 1;
        if (quote_pos >= input.len or input[quote_pos] != '"') {
            pos = quote_pos;
            continue;
        }
        const value_start = quote_pos + 1;
        const value_end_rel = std.mem.indexOfScalar(u8, input[value_start..], '"') orelse return;
        const value_end = value_start + value_end_rel;
        try types.putOwned(
            allocator,
            args,
            key,
            .{ .string = try allocator.dupe(u8, input[value_start..value_end]) },
        );
        pos = value_end + 1;
    }
}

fn isWord(value: []const u8) bool {
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return value.len != 0;
}

fn appendOwnedCall(
    allocator: std.mem.Allocator,
    calls: *std.ArrayList(types.ParsedToolCall),
    name_source: []const u8,
    arguments: *std.json.Value,
) !void {
    var arguments_owned = true;
    errdefer if (arguments_owned) types.freeJsonValue(allocator, arguments);

    const dup_name = try allocator.dupe(u8, name_source);
    errdefer if (arguments_owned) allocator.free(dup_name);

    try calls.append(.{
        .name = dup_name,
        .arguments = arguments.*,
        .tool_call_id = null,
    });
    arguments_owned = false;
}

test "smoke" {
    const calls = try parsePerlStyleToolCalls(
        std.testing.allocator,
        "[TOOL_CALL]{tool => \"shell\", args => {--command \"echo hello\"}}[/TOOL_CALL]",
    );
    defer {
        for (calls) |*call| call.deinit(std.testing.allocator);
        std.testing.allocator.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
}
