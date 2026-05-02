const std = @import("std");
const mvzr = @import("mvzr");
const types = @import("types.zig");
const json = @import("json.zig");
const glm = @import("glm.zig");

const XML_OPEN_TAG_RE = mvzr.compile("<[a-zA-Z_][a-zA-Z0-9_-]*>").?;

pub const TOOL_CALL_OPEN_TAGS = [_][]const u8{
    "<tool_call>",
    "<toolcall>",
    "<tool-call>",
    "<invoke>",
    "<minimax:tool_call>",
    "<minimax:toolcall>",
};

pub const TOOL_CALL_CLOSE_TAGS = [_][]const u8{
    "</tool_call>",
    "</toolcall>",
    "</tool-call>",
    "</invoke>",
    "</minimax:tool_call>",
    "</minimax:toolcall>",
};

pub const XmlPair = struct {
    tag_name: []const u8,
    inner: []const u8,
};

pub const FoundTag = struct {
    start: usize,
    tag: []const u8,
};

pub fn isXmlMetaTag(tag: []const u8) bool {
    return eqlIgnoreCase(tag, "tool_call") or
        eqlIgnoreCase(tag, "toolcall") or
        eqlIgnoreCase(tag, "tool-call") or
        eqlIgnoreCase(tag, "invoke") or
        eqlIgnoreCase(tag, "thinking") or
        eqlIgnoreCase(tag, "thought") or
        eqlIgnoreCase(tag, "analysis") or
        eqlIgnoreCase(tag, "reasoning") or
        eqlIgnoreCase(tag, "reflection");
}

pub fn extractXmlPairs(allocator: std.mem.Allocator, input: []const u8) ![]XmlPair {
    var results = std.ArrayList(XmlPair).init(allocator);
    errdefer results.deinit();

    var search_start: usize = 0;
    while (search_start < input.len) {
        const open_match = XML_OPEN_TAG_RE.match(input[search_start..]) orelse break;
        const open_slice = open_match.slice;
        const tag_name = open_slice[1 .. open_slice.len - 1];
        const open_end = search_start + open_match.end;

        const closing_tag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag_name});
        defer allocator.free(closing_tag);

        if (std.mem.indexOf(u8, input[open_end..], closing_tag)) |close_pos| {
            const inner = std.mem.trim(u8, input[open_end .. open_end + close_pos], " \t\r\n");
            try results.append(.{ .tag_name = tag_name, .inner = inner });
            search_start = open_end + close_pos + closing_tag.len;
        } else {
            search_start = open_end;
        }
    }

    return results.toOwnedSlice();
}

pub fn parseXmlToolCalls(
    allocator: std.mem.Allocator,
    xml_content: []const u8,
) types.ParserError!?[]types.ParsedToolCall {
    var calls = std.ArrayList(types.ParsedToolCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }

    const trimmed = std.mem.trim(u8, xml_content, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '<' or std.mem.indexOfScalar(u8, trimmed, '>') == null) {
        return null;
    }

    const pairs = try extractXmlPairs(allocator, trimmed);
    defer allocator.free(pairs);

    for (pairs) |pair| {
        if (isXmlMetaTag(pair.tag_name) or pair.inner.len == 0) continue;

        var arguments: std.json.Value = undefined;
        var has_arguments = false;

        const json_values = try json.extractJsonValues(allocator, pair.inner);
        defer {
            for (json_values) |*value| types.freeJsonValue(allocator, value);
            allocator.free(json_values);
        }
        if (json_values.len != 0) {
            if (json_values[0] == .object) {
                arguments = try types.cloneJsonValue(allocator, json_values[0]);
            } else {
                var args = std.json.ObjectMap.init(allocator);
                errdefer {
                    var tmp = std.json.Value{ .object = args };
                    types.freeJsonValue(allocator, &tmp);
                }
                try types.putOwned(allocator, &args, "value", try types.cloneJsonValue(allocator, json_values[0]));
                arguments = .{ .object = args };
            }
            has_arguments = true;
        }

        if (!has_arguments) {
            var args = std.json.ObjectMap.init(allocator);
            errdefer {
                var tmp = std.json.Value{ .object = args };
                types.freeJsonValue(allocator, &tmp);
            }

            const inner_pairs = try extractXmlPairs(allocator, pair.inner);
            defer allocator.free(inner_pairs);
            for (inner_pairs) |inner_pair| {
                if (isXmlMetaTag(inner_pair.tag_name) or inner_pair.inner.len == 0) continue;
                try types.putOwned(
                    allocator,
                    &args,
                    inner_pair.tag_name,
                    .{ .string = try allocator.dupe(u8, inner_pair.inner) },
                );
            }

            if (args.count() == 0) {
                try types.putOwned(allocator, &args, "content", .{ .string = try allocator.dupe(u8, pair.inner) });
            }
            arguments = .{ .object = args };
        }

        try appendOwnedCall(allocator, &calls, pair.tag_name, &arguments);
    }

    if (calls.items.len == 0) {
        calls.deinit();
        return null;
    }
    const out = try calls.toOwnedSlice();
    return out;
}

pub fn parseXmlAttributeToolCalls(
    allocator: std.mem.Allocator,
    response: []const u8,
) types.ParserError![]types.ParsedToolCall {
    // MVZR_GAP: Rust `(?s)<invoke\s+name="([^"]+)"[^>]*>(.*?)</invoke>` and
    // `<parameter\s+name="([^"]+)"[^>]*>([^<]*)</parameter>` need captures.
    // Fallback scans invoke/parameter tags and extracts double-quoted attrs.
    var calls = std.ArrayList(types.ParsedToolCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }

    var pos: usize = 0;
    while (std.mem.indexOf(u8, response[pos..], "<invoke")) |rel| {
        const start = pos + rel;
        const open_end_rel = std.mem.indexOfScalar(u8, response[start..], '>') orelse break;
        const open_end = start + open_end_rel + 1;
        const close_rel = std.mem.indexOf(u8, response[open_end..], "</invoke>") orelse break;
        const close_start = open_end + close_rel;
        const open_tag = response[start..open_end];
        const inner = response[open_end..close_start];
        pos = close_start + "</invoke>".len;

        const raw_name = attrValue(open_tag, "name") orelse continue;
        if (raw_name.len == 0) continue;

        var args = std.json.ObjectMap.init(allocator);
        var args_owned = true;
        errdefer if (args_owned) {
            var tmp = std.json.Value{ .object = args };
            types.freeJsonValue(allocator, &tmp);
        };

        var param_pos: usize = 0;
        while (std.mem.indexOf(u8, inner[param_pos..], "<parameter")) |p_rel| {
            const p_start = param_pos + p_rel;
            const p_open_end_rel = std.mem.indexOfScalar(u8, inner[p_start..], '>') orelse break;
            const p_open_end = p_start + p_open_end_rel + 1;
            const p_close_rel = std.mem.indexOf(u8, inner[p_open_end..], "</parameter>") orelse break;
            const p_close = p_open_end + p_close_rel;
            const p_open_tag = inner[p_start..p_open_end];
            const param_name = attrValue(p_open_tag, "name") orelse {
                param_pos = p_close + "</parameter>".len;
                continue;
            };
            const param_value = inner[p_open_end..p_close];
            if (param_name.len != 0) {
                try types.putOwned(allocator, &args, param_name, .{ .string = try allocator.dupe(u8, param_value) });
            }
            param_pos = p_close + "</parameter>".len;
        }

        if (args.count() != 0) {
            args_owned = false;
            var arguments = std.json.Value{ .object = args };
            try appendOwnedCall(allocator, &calls, glm.mapToolNameAlias(raw_name), &arguments);
        } else {
            args_owned = false;
            args.deinit();
        }
    }

    const out = try calls.toOwnedSlice();
    return out;
}

pub fn findFirstTag(haystack: []const u8, tags: []const []const u8) ?FoundTag {
    var best: ?FoundTag = null;
    for (tags) |tag| {
        if (std.mem.indexOf(u8, haystack, tag)) |idx| {
            if (best == null or idx < best.?.start) {
                best = .{ .start = idx, .tag = tag };
            }
        }
    }
    return best;
}

pub fn stripLeadingCloseTags(input: []const u8) []const u8 {
    var rest = input;
    while (true) {
        const trimmed = std.mem.trimLeft(u8, rest, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "</")) return trimmed;
        const close_end = std.mem.indexOfScalar(u8, trimmed, '>') orelse return "";
        rest = trimmed[close_end + 1 ..];
    }
}

pub fn matchingCloseTag(open_tag: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, open_tag, "<tool_call>")) return "</tool_call>";
    if (std.mem.eql(u8, open_tag, "<toolcall>")) return "</toolcall>";
    if (std.mem.eql(u8, open_tag, "<tool-call>")) return "</tool-call>";
    if (std.mem.eql(u8, open_tag, "<invoke>")) return "</invoke>";
    if (std.mem.eql(u8, open_tag, "<minimax:tool_call>")) return "</minimax:tool_call>";
    if (std.mem.eql(u8, open_tag, "<minimax:toolcall>")) return "</minimax:toolcall>";
    return null;
}

fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOf(u8, tag[pos..], name)) |rel| {
        const start = pos + rel;
        const after_name = start + name.len;
        var i = after_name;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i >= tag.len or tag[i] != '=') {
            pos = after_name;
            continue;
        }
        i += 1;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i >= tag.len or tag[i] != '"') return null;
        i += 1;
        const end_rel = std.mem.indexOfScalar(u8, tag[i..], '"') orelse return null;
        return tag[i .. i + end_rel];
    }
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
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
    const pairs = try extractXmlPairs(std.testing.allocator, "<shell>{\"command\":\"pwd\"}</shell>");
    defer std.testing.allocator.free(pairs);
    try std.testing.expectEqual(@as(usize, 1), pairs.len);
    try std.testing.expectEqualStrings("shell", pairs[0].tag_name);
}
