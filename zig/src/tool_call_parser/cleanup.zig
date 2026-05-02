const std = @import("std");

// MVZR_GAP: Rust patterns `(?s)<tool_result[^>]*>.*?</tool_result>`,
// `(?s)<thinking>.*?</thinking>`, `(?s)<think>.*?</think>`, and
// `(?m)^\[Tool results\]\s*\n?` rely on dotall/lazy/multiline behavior.
// mvzr exposes whole matches only, so these are implemented with bounded
// std.mem.indexOf scans.

pub fn stripThinkTags(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var rest = s;
    while (true) {
        if (std.mem.indexOf(u8, rest, "<think>")) |start| {
            try result.appendSlice(rest[0..start]);
            if (std.mem.indexOf(u8, rest[start..], "</think>")) |end| {
                rest = rest[start + end + "</think>".len ..];
            } else {
                break;
            }
        } else {
            try result.appendSlice(rest);
            break;
        }
    }

    const trimmed = std.mem.trim(u8, result.items, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

pub fn stripToolResultBlocks(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const result = try removeTaggedBlocks(allocator, text, "<tool_result", "</tool_result>");
    defer allocator.free(result);

    const without_thinking = try removeExactTaggedBlocks(allocator, result, "<thinking>", "</thinking>");
    defer allocator.free(without_thinking);

    const without_think = try removeExactTaggedBlocks(allocator, without_thinking, "<think>", "</think>");
    defer allocator.free(without_think);

    const without_prefix = try removeToolResultsPrefix(allocator, without_think);
    defer allocator.free(without_prefix);

    const collapsed = try collapseBlankLines(allocator, std.mem.trim(u8, without_prefix, " \t\r\n"));
    defer allocator.free(collapsed);

    return allocator.dupe(u8, collapsed);
}

fn removeTaggedBlocks(
    allocator: std.mem.Allocator,
    text: []const u8,
    open_prefix: []const u8,
    close_tag_without_gt: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var rest = text;
    const close_tag = try std.fmt.allocPrint(allocator, "{s}>", .{close_tag_without_gt});
    defer allocator.free(close_tag);

    while (true) {
        const start = std.mem.indexOf(u8, rest, open_prefix) orelse {
            try out.appendSlice(rest);
            break;
        };
        try out.appendSlice(rest[0..start]);
        const after_open = rest[start..];
        const close_rel = std.mem.indexOf(u8, after_open, close_tag) orelse {
            try out.appendSlice(after_open);
            break;
        };
        rest = after_open[close_rel + close_tag.len ..];
    }
    return out.toOwnedSlice();
}

fn removeExactTaggedBlocks(
    allocator: std.mem.Allocator,
    text: []const u8,
    open_tag: []const u8,
    close_tag: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var rest = text;
    while (true) {
        const start = std.mem.indexOf(u8, rest, open_tag) orelse {
            try out.appendSlice(rest);
            break;
        };
        try out.appendSlice(rest[0..start]);
        const after_open = rest[start + open_tag.len ..];
        const close_rel = std.mem.indexOf(u8, after_open, close_tag) orelse {
            try out.appendSlice(rest[start..]);
            break;
        };
        rest = after_open[close_rel + close_tag.len ..];
    }
    return out.toOwnedSlice();
}

fn removeToolResultsPrefix(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var pos: usize = 0;
    var at_line_start = true;
    while (pos < text.len) {
        if (at_line_start and std.mem.startsWith(u8, text[pos..], "[Tool results]")) {
            pos += "[Tool results]".len;
            while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t' or text[pos] == '\r')) pos += 1;
            if (pos < text.len and text[pos] == '\n') {
                pos += 1;
                at_line_start = true;
            }
            continue;
        }
        const ch = text[pos];
        try out.append(ch);
        at_line_start = ch == '\n';
        pos += 1;
    }
    return out.toOwnedSlice();
}

fn collapseBlankLines(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var newline_run: usize = 0;
    for (text) |ch| {
        if (ch == '\n') {
            newline_run += 1;
            if (newline_run <= 2) try out.append(ch);
        } else {
            newline_run = 0;
            try out.append(ch);
        }
    }
    return out.toOwnedSlice();
}

test "smoke" {
    const stripped = try stripThinkTags(std.testing.allocator, "<think>hidden</think> visible ");
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings("visible", stripped);
}

test "strip tool result keeps unclosed block" {
    const input = "before <tool_result name=\"shell\">unterminated";
    const stripped = try stripToolResultBlocks(std.testing.allocator, input);
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings(input, stripped);
}
