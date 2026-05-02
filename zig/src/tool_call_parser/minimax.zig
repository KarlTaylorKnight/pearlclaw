const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");

// MVZR_GAP: Rust patterns
// `(?is)<invoke\b[^>]*\bname\s*=\s*(?:"([^"]+)"|'([^']+)')[^>]*>(.*?)</invoke>`
// and the matching `<parameter ...>` pattern require captures plus dotall and
// case-insensitive flags. This fallback scans invoke/parameter tags directly.

pub fn parseMinimaxInvokeCalls(
    allocator: std.mem.Allocator,
    response: []const u8,
) types.ParserError!?types.ParseResult {
    var calls = std.ArrayList(types.ParsedToolCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }
    var text_parts = std.ArrayList([]u8).init(allocator);
    defer {
        for (text_parts.items) |part| allocator.free(part);
        text_parts.deinit();
    }

    var last_end: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, response[pos..], "<invoke")) |rel| {
        const start = pos + rel;
        const open_end_rel = std.mem.indexOfScalar(u8, response[start..], '>') orelse break;
        const open_end = start + open_end_rel + 1;
        const close_rel = std.mem.indexOf(u8, response[open_end..], "</invoke>") orelse break;
        const close_start = open_end + close_rel;
        const full_end = close_start + "</invoke>".len;

        const before = std.mem.trim(u8, response[last_end..start], " \t\r\n");
        if (before.len != 0) try text_parts.append(try allocator.dupe(u8, before));

        const open_tag = response[start..open_end];
        const name = attrValue(open_tag, "name") orelse {
            last_end = full_end;
            pos = full_end;
            continue;
        };
        const name_trimmed = std.mem.trim(u8, name, " \t\r\n");
        const body = std.mem.trim(u8, response[open_end..close_start], " \t\r\n");
        last_end = full_end;
        pos = full_end;
        if (name_trimmed.len == 0) continue;

        var args = std.json.ObjectMap.init(allocator);
        var args_owned = true;
        errdefer if (args_owned) {
            var tmp = std.json.Value{ .object = args };
            types.freeJsonValue(allocator, &tmp);
        };

        var param_pos: usize = 0;
        while (std.mem.indexOf(u8, body[param_pos..], "<parameter")) |p_rel| {
            const p_start = param_pos + p_rel;
            const p_open_end_rel = std.mem.indexOfScalar(u8, body[p_start..], '>') orelse break;
            const p_open_end = p_start + p_open_end_rel + 1;
            const p_close_rel = std.mem.indexOf(u8, body[p_open_end..], "</parameter>") orelse break;
            const p_close = p_open_end + p_close_rel;
            const p_open_tag = body[p_start..p_open_end];
            const key = attrValue(p_open_tag, "name") orelse {
                param_pos = p_close + "</parameter>".len;
                continue;
            };
            const key_trimmed = std.mem.trim(u8, key, " \t\r\n");
            const value_trimmed = std.mem.trim(u8, body[p_open_end..p_close], " \t\r\n");
            param_pos = p_close + "</parameter>".len;
            if (key_trimmed.len == 0 or value_trimmed.len == 0) continue;

            const parsed_values = try json.extractJsonValues(allocator, value_trimmed);
            defer {
                for (parsed_values) |*value| types.freeJsonValue(allocator, value);
                allocator.free(parsed_values);
            }
            const parsed_value = if (parsed_values.len != 0)
                try types.cloneJsonValue(allocator, parsed_values[0])
            else
                std.json.Value{ .string = try allocator.dupe(u8, value_trimmed) };
            try types.putOwned(allocator, &args, key_trimmed, parsed_value);
        }

        if (args.count() == 0) {
            const body_values = try json.extractJsonValues(allocator, body);
            defer {
                for (body_values) |*value| types.freeJsonValue(allocator, value);
                allocator.free(body_values);
            }
            if (body_values.len != 0) {
                if (body_values[0] == .object) {
                    const cloned = try types.cloneJsonValue(allocator, body_values[0]);
                    args.deinit();
                    args = cloned.object;
                } else {
                    try types.putOwned(allocator, &args, "value", try types.cloneJsonValue(allocator, body_values[0]));
                }
            } else if (body.len != 0) {
                try types.putOwned(allocator, &args, "content", .{ .string = try allocator.dupe(u8, body) });
            }
        }

        args_owned = false;
        var arguments = std.json.Value{ .object = args };
        try appendOwnedCall(allocator, &calls, name_trimmed, &arguments);
    }

    if (calls.items.len == 0) {
        calls.deinit();
        return null;
    }

    const after = std.mem.trim(u8, response[last_end..], " \t\r\n");
    if (after.len != 0) try text_parts.append(try allocator.dupe(u8, after));

    const joined = try joinTextParts(allocator, text_parts.items);
    defer allocator.free(joined);
    const stripped = try stripMinimaxWrapperTags(allocator, joined);
    defer allocator.free(stripped);
    const text = try allocator.dupe(u8, std.mem.trim(u8, stripped, " \t\r\n"));
    errdefer allocator.free(text);

    return .{ .text = text, .calls = try calls.toOwnedSlice() };
}

fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOf(u8, tag[pos..], name)) |rel| {
        const start = pos + rel;
        var i = start + name.len;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i >= tag.len or tag[i] != '=') {
            pos = start + name.len;
            continue;
        }
        i += 1;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i >= tag.len or (tag[i] != '"' and tag[i] != '\'')) return null;
        const quote = tag[i];
        i += 1;
        const end_rel = std.mem.indexOfScalar(u8, tag[i..], quote) orelse return null;
        return tag[i .. i + end_rel];
    }
    return null;
}

fn joinTextParts(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (parts, 0..) |part, i| {
        if (i != 0) try out.append('\n');
        try out.appendSlice(part);
    }
    return out.toOwnedSlice();
}

fn stripMinimaxWrapperTags(
    allocator: std.mem.Allocator,
    input: []const u8,
) ![]u8 {
    const needles = [_][]const u8{
        "<minimax:tool_call>",
        "</minimax:tool_call>",
        "<minimax:toolcall>",
        "</minimax:toolcall>",
    };
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var pos: usize = 0;
    while (pos < input.len) {
        var matched: ?[]const u8 = null;
        for (needles) |needle| {
            if (std.mem.startsWith(u8, input[pos..], needle)) {
                matched = needle;
                break;
            }
        }
        if (matched) |needle| {
            pos += needle.len;
            continue;
        }
        try out.append(input[pos]);
        pos += 1;
    }
    return out.toOwnedSlice();
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
    var result = (try parseMinimaxInvokeCalls(
        std.testing.allocator,
        "<invoke name=\"shell\"><parameter name=\"command\">pwd</parameter></invoke>",
    )).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
}
