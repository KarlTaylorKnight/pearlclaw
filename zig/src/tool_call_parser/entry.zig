const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");
const xml = @import("xml.zig");
const minimax = @import("minimax.zig");
const perl = @import("perl.zig");
const glm = @import("glm.zig");
const cleanup = @import("cleanup.zig");

pub const ParseResult = types.ParseResult;
const FoundNeedle = struct {
    start: usize,
    needle: []const u8,
};

pub fn parseToolCalls(
    allocator: std.mem.Allocator,
    response_raw: []const u8,
    scratch_arena: ?*std.heap.ArenaAllocator,
) types.ParserError!types.ParseResult {
    if (scratch_arena) |arena| {
        var result = try parseToolCallsInner(arena.allocator(), response_raw);
        result.arena_backed = true;
        return result;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var result = try parseToolCallsInner(arena.allocator(), response_raw);
    result.arena = arena;
    return result;
}

fn parseToolCallsInner(
    allocator: std.mem.Allocator,
    response_raw: []const u8,
) types.ParserError!types.ParseResult {
    const cleaned = try cleanup.stripThinkTags(allocator, response_raw);
    defer allocator.free(cleaned);
    const response = cleaned;

    var text_parts = std.ArrayList([]u8).init(allocator);
    defer {
        for (text_parts.items) |part| allocator.free(part);
        text_parts.deinit();
    }
    var calls = std.ArrayList(types.ParsedToolCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }

    const trimmed_response = std.mem.trim(u8, response, " \t\r\n");
    if (try types.parseJsonValueOwned(allocator, trimmed_response)) |json_value| {
        var value = json_value;
        defer types.freeJsonValue(allocator, &value);
        const parsed_calls = try json.parseToolCallsFromJsonValue(allocator, value);
        defer allocator.free(parsed_calls);
        if (parsed_calls.len != 0) {
            try transferCallSlice(allocator, &calls, parsed_calls);
            if (json.getStringField(value, "content")) |content| {
                const content_trimmed = std.mem.trim(u8, content, " \t\r\n");
                if (content_trimmed.len != 0) try text_parts.append(try allocator.dupe(u8, content_trimmed));
            }
            return finish(allocator, &text_parts, &calls);
        }
    }

    if (try minimax.parseMinimaxInvokeCalls(allocator, response)) |result| {
        if (result.calls.len != 0) return result;
        var mutable = result;
        mutable.deinit(allocator);
    }

    var remaining: []const u8 = response;
    while (xml.findFirstTag(remaining, xml.TOOL_CALL_OPEN_TAGS[0..])) |found| {
        const before = std.mem.trim(u8, remaining[0..found.start], " \t\r\n");
        if (before.len != 0) try text_parts.append(try allocator.dupe(u8, before));

        const close_tag = xml.matchingCloseTag(found.tag) orelse break;
        const after_open = remaining[found.start + found.tag.len ..];
        if (std.mem.indexOf(u8, after_open, close_tag)) |close_idx| {
            const inner = after_open[0..close_idx];
            _ = try parseTaggedInner(allocator, inner, &calls);
            remaining = after_open[close_idx + close_tag.len ..];
        } else {
            var resolved = false;
            if (xml.findFirstTag(after_open, xml.TOOL_CALL_CLOSE_TAGS[0..])) |cross| {
                const inner = after_open[0..cross.start];
                if (try parseTaggedInner(allocator, inner, &calls)) {
                    remaining = after_open[cross.start + cross.tag.len ..];
                    resolved = true;
                }
            }
            if (resolved) continue;

            if (try json.findJsonEnd(allocator, after_open)) |json_end| {
                if (try types.parseJsonValueOwned(allocator, after_open[0..json_end])) |value_owned| {
                    var value = value_owned;
                    defer types.freeJsonValue(allocator, &value);
                    const parsed_calls = try json.parseToolCallsFromJsonValue(allocator, value);
                    defer allocator.free(parsed_calls);
                    if (parsed_calls.len != 0) {
                        try transferCallSlice(allocator, &calls, parsed_calls);
                        remaining = xml.stripLeadingCloseTags(after_open[json_end..]);
                        continue;
                    }
                }
            }

            if (try json.extractFirstJsonValueWithEnd(allocator, after_open)) |found_json| {
                var value = found_json.value;
                defer types.freeJsonValue(allocator, &value);
                const parsed_calls = try json.parseToolCallsFromJsonValue(allocator, value);
                defer allocator.free(parsed_calls);
                if (parsed_calls.len != 0) {
                    try transferCallSlice(allocator, &calls, parsed_calls);
                    remaining = xml.stripLeadingCloseTags(after_open[found_json.end..]);
                    continue;
                }
            }

            const glm_input = std.mem.trim(u8, after_open, " \t\r\n");
            if (try glm.parseGlmShortenedBody(allocator, glm_input)) |glm_call| {
                var call = glm_call;
                try appendParsedCall(allocator, &calls, &call);
                remaining = "";
                continue;
            }

            remaining = remaining[found.start..];
            break;
        }
    }

    if (calls.items.len == 0) {
        if (try parseMarkdownToolCallFences(allocator, response)) |raw_md_result| {
            const md_result = raw_md_result;
            var md_text_owned = true;
            defer {
                if (md_text_owned) freeTextPartSlice(allocator, md_result.text_parts);
            }
            var md_calls_owned = true;
            defer {
                if (md_calls_owned) freeCallItems(allocator, md_result.calls);
                allocator.free(md_result.calls);
            }
            try replaceTextParts(allocator, &text_parts, md_result.text_parts);
            md_text_owned = false;
            md_calls_owned = false;
            try transferCallSlice(allocator, &calls, md_result.calls);
            remaining = "";
        }
    }

    if (calls.items.len == 0) {
        if (try parseMarkdownNamedToolFences(allocator, response)) |raw_md_result| {
            const md_result = raw_md_result;
            var md_text_owned = true;
            defer {
                if (md_text_owned) freeTextPartSlice(allocator, md_result.text_parts);
            }
            var md_calls_owned = true;
            defer {
                if (md_calls_owned) freeCallItems(allocator, md_result.calls);
                allocator.free(md_result.calls);
            }
            try replaceTextParts(allocator, &text_parts, md_result.text_parts);
            md_text_owned = false;
            md_calls_owned = false;
            try transferCallSlice(allocator, &calls, md_result.calls);
            remaining = "";
        }
    }

    if (calls.items.len == 0) {
        const xml_calls = try xml.parseXmlAttributeToolCalls(allocator, remaining);
        if (xml_calls.len != 0) {
            defer allocator.free(xml_calls);
            try transferCallSlice(allocator, &calls, xml_calls);
            var cleaned_text = try allocator.dupe(u8, remaining);
            defer allocator.free(cleaned_text);
            cleaned_text = try removeMinimaxToolcallBlock(allocator, cleaned_text);
            const trimmed = std.mem.trim(u8, cleaned_text, " \t\r\n");
            if (trimmed.len != 0) try text_parts.append(try allocator.dupe(u8, trimmed));
            remaining = "";
        } else {
            allocator.free(xml_calls);
        }
    }

    if (calls.items.len == 0) {
        const perl_calls = try perl.parsePerlStyleToolCalls(allocator, remaining);
        if (perl_calls.len != 0) {
            defer allocator.free(perl_calls);
            try transferCallSlice(allocator, &calls, perl_calls);
            var cleaned_text = try allocator.dupe(u8, remaining);
            defer allocator.free(cleaned_text);
            cleaned_text = try removeToolCallBlocksRusty(allocator, cleaned_text, "TOOL_CALL", "/TOOL_CALL");
            const trimmed = std.mem.trim(u8, cleaned_text, " \t\r\n");
            if (trimmed.len != 0) try text_parts.append(try allocator.dupe(u8, trimmed));
            remaining = "";
        } else {
            allocator.free(perl_calls);
        }
    }

    if (calls.items.len == 0) {
        const func_calls = try perl.parseFunctionCallToolCalls(allocator, remaining);
        if (func_calls.len != 0) {
            defer allocator.free(func_calls);
            try transferCallSlice(allocator, &calls, func_calls);
            var cleaned_text = try allocator.dupe(u8, remaining);
            defer allocator.free(cleaned_text);
            cleaned_text = try removeToolCallBlocksRusty(allocator, cleaned_text, "<FunctionCall>", "</FunctionCall>");
            const trimmed = std.mem.trim(u8, cleaned_text, " \t\r\n");
            if (trimmed.len != 0) try text_parts.append(try allocator.dupe(u8, trimmed));
            remaining = "";
        } else {
            allocator.free(func_calls);
        }
    }

    if (calls.items.len == 0) {
        const glm_calls = try glm.parseGlmStyleToolCalls(allocator, remaining);
        if (glm_calls.len != 0) {
            defer allocator.free(glm_calls);
            var glm_consumed: usize = 0;
            errdefer for (glm_calls[glm_consumed..]) |*gcall| gcall.deinit(allocator);
            var cleaned_text = try allocator.dupe(u8, remaining);
            defer allocator.free(cleaned_text);
            for (glm_calls) |*gcall| {
                var arguments = try types.cloneJsonValue(allocator, gcall.arguments);
                try appendOwnedCall(allocator, &calls, gcall.name, &arguments);
                if (gcall.raw) |raw| {
                    cleaned_text = try replaceAllOwned(allocator, cleaned_text, raw, "");
                }
                gcall.deinit(allocator);
                glm_consumed += 1;
            }
            const trimmed = std.mem.trim(u8, cleaned_text, " \t\r\n");
            if (trimmed.len != 0) try text_parts.append(try allocator.dupe(u8, trimmed));
            remaining = "";
        } else {
            allocator.free(glm_calls);
        }
    }

    const trailing = std.mem.trim(u8, remaining, " \t\r\n");
    if (trailing.len != 0) try text_parts.append(try allocator.dupe(u8, trailing));

    return finish(allocator, &text_parts, &calls);
}

pub fn detectToolCallParseIssue(
    allocator: std.mem.Allocator,
    response: []const u8,
    parsed_calls: []const types.ParsedToolCall,
) !?[]u8 {
    if (parsed_calls.len != 0) return null;
    const trimmed = std.mem.trim(u8, response, " \t\r\n");
    if (trimmed.len == 0) return null;

    const looks_like_tool_payload =
        std.mem.indexOf(u8, trimmed, "<tool_call") != null or
        std.mem.indexOf(u8, trimmed, "<toolcall") != null or
        std.mem.indexOf(u8, trimmed, "<tool-call") != null or
        std.mem.indexOf(u8, trimmed, "```tool_call") != null or
        std.mem.indexOf(u8, trimmed, "```toolcall") != null or
        std.mem.indexOf(u8, trimmed, "```tool-call") != null or
        std.mem.indexOf(u8, trimmed, "```tool file_") != null or
        std.mem.indexOf(u8, trimmed, "```tool shell") != null or
        std.mem.indexOf(u8, trimmed, "```tool web_") != null or
        std.mem.indexOf(u8, trimmed, "```tool memory_") != null or
        std.mem.indexOf(u8, trimmed, "```tool ") != null or
        std.mem.indexOf(u8, trimmed, "\"tool_calls\"") != null or
        std.mem.indexOf(u8, trimmed, "TOOL_CALL") != null or
        std.mem.indexOf(u8, trimmed, "[TOOL_CALL]") != null or
        std.mem.indexOf(u8, trimmed, "<FunctionCall>") != null;

    if (!looks_like_tool_payload) return null;
    return try allocator.dupe(u8, "response resembled a tool-call payload but no valid tool call could be parsed");
}

pub fn buildNativeAssistantHistoryFromParsedCalls(
    allocator: std.mem.Allocator,
    text: []const u8,
    tool_calls: []const types.ParsedToolCall,
    reasoning_content: ?[]const u8,
) !?[]u8 {
    for (tool_calls) |call| {
        if (call.tool_call_id == null) return null;
    }

    var root = std.json.ObjectMap.init(allocator);
    errdefer {
        var tmp = std.json.Value{ .object = root };
        types.freeJsonValue(allocator, &tmp);
    }

    const text_trimmed = std.mem.trim(u8, text, " \t\r\n");
    const content_value: std.json.Value = if (text_trimmed.len == 0)
        .null
    else
        .{ .string = try allocator.dupe(u8, text_trimmed) };
    try types.putOwned(allocator, &root, "content", content_value);

    var calls_array = std.json.Array.init(allocator);
    errdefer {
        var tmp = std.json.Value{ .array = calls_array };
        types.freeJsonValue(allocator, &tmp);
    }
    for (tool_calls) |call| {
        const id = call.tool_call_id orelse return null;
        var call_obj = std.json.ObjectMap.init(allocator);
        errdefer {
            var tmp = std.json.Value{ .object = call_obj };
            types.freeJsonValue(allocator, &tmp);
        }
        const args_string = try std.json.stringifyAlloc(allocator, call.arguments, .{});
        var args_string_owned = true;
        errdefer if (args_string_owned) allocator.free(args_string);
        try types.putOwned(allocator, &call_obj, "id", .{ .string = try allocator.dupe(u8, id) });
        try types.putOwned(allocator, &call_obj, "name", .{ .string = try allocator.dupe(u8, call.name) });
        args_string_owned = false;
        try types.putOwned(allocator, &call_obj, "arguments", .{ .string = args_string });
        try calls_array.append(.{ .object = call_obj });
    }
    try types.putOwned(allocator, &root, "tool_calls", .{ .array = calls_array });

    if (reasoning_content) |rc| {
        try types.putOwned(allocator, &root, "reasoning_content", .{ .string = try allocator.dupe(u8, rc) });
    }

    var root_value = std.json.Value{ .object = root };
    defer types.freeJsonValue(allocator, &root_value);
    return try std.json.stringifyAlloc(allocator, root_value, .{});
}

fn parseTaggedInner(
    allocator: std.mem.Allocator,
    inner: []const u8,
    calls: *std.ArrayList(types.ParsedToolCall),
) types.ParserError!bool {
    var parsed_any = false;

    const json_values = try json.extractJsonValues(allocator, inner);
    defer {
        for (json_values) |*value| types.freeJsonValue(allocator, value);
        allocator.free(json_values);
    }
    for (json_values) |value| {
        const parsed_calls = try json.parseToolCallsFromJsonValue(allocator, value);
        defer allocator.free(parsed_calls);
        if (parsed_calls.len != 0) {
            parsed_any = true;
            try transferCallSlice(allocator, calls, parsed_calls);
        }
    }

    if (!parsed_any) {
        if (try xml.parseXmlToolCalls(allocator, inner)) |xml_calls| {
            defer allocator.free(xml_calls);
            try transferCallSlice(allocator, calls, xml_calls);
            parsed_any = true;
        }
    }

    if (!parsed_any) {
        if (try glm.parseGlmShortenedBody(allocator, inner)) |glm_call| {
            var call = glm_call;
            try appendParsedCall(allocator, calls, &call);
            parsed_any = true;
        }
    }

    return parsed_any;
}

fn transferCallSlice(
    allocator: std.mem.Allocator,
    calls: *std.ArrayList(types.ParsedToolCall),
    source: []types.ParsedToolCall,
) !void {
    var transferred: usize = 0;
    errdefer freeCallItems(allocator, source[transferred..]);
    while (transferred < source.len) {
        try calls.append(source[transferred]);
        transferred += 1;
    }
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

fn freeCallItems(allocator: std.mem.Allocator, source: []types.ParsedToolCall) void {
    for (source) |*call| call.deinit(allocator);
}

fn freeTextPartSlice(allocator: std.mem.Allocator, source: [][]u8) void {
    for (source) |part| allocator.free(part);
    allocator.free(source);
}

const MarkdownResult = struct {
    text_parts: [][]u8,
    calls: []types.ParsedToolCall,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.text_parts) |part| allocator.free(part);
        allocator.free(self.text_parts);
        for (self.calls) |*call| call.deinit(allocator);
        allocator.free(self.calls);
    }
};

fn parseMarkdownToolCallFences(allocator: std.mem.Allocator, response: []const u8) types.ParserError!?MarkdownResult {
    // MVZR_GAP: Rust pattern
    // `(?s)```(?:tool[_-]?call|invoke)\s*\n(.*?)(?:```|</tool[_-]?call>|</toolcall>|</invoke>|</minimax:toolcall>)`
    // needs capture groups and lazy dotall. Fallback scans known fence labels.
    var text_parts = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (text_parts.items) |part| allocator.free(part);
        text_parts.deinit();
    }
    var calls = std.ArrayList(types.ParsedToolCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }

    var last_end: usize = 0;
    var pos: usize = 0;
    while (findNextAny(response[pos..], &.{ "```tool_call", "```tool-call", "```toolcall", "```invoke" })) |found| {
        const start = pos + found.start;
        const line_end_rel = std.mem.indexOfScalar(u8, response[start..], '\n') orelse break;
        const inner_start = start + line_end_rel + 1;
        const terminator = findNextAny(response[inner_start..], &.{ "```", "</tool_call>", "</tool-call>", "</toolcall>", "</invoke>", "</minimax:toolcall>" }) orelse break;
        const inner = response[inner_start .. inner_start + terminator.start];
        const before = std.mem.trim(u8, response[last_end..start], " \t\r\n");
        if (before.len != 0) try text_parts.append(try allocator.dupe(u8, before));

        const json_values = try json.extractJsonValues(allocator, inner);
        defer {
            for (json_values) |*value| types.freeJsonValue(allocator, value);
            allocator.free(json_values);
        }
        for (json_values) |value| {
            const parsed = try json.parseToolCallsFromJsonValue(allocator, value);
            defer allocator.free(parsed);
            if (parsed.len != 0) try transferCallSlice(allocator, &calls, parsed);
        }
        last_end = inner_start + terminator.start + terminator.needle.len;
        pos = last_end;
    }

    if (calls.items.len == 0) {
        for (text_parts.items) |part| allocator.free(part);
        text_parts.deinit();
        calls.deinit();
        return null;
    }

    const after = std.mem.trim(u8, response[last_end..], " \t\r\n");
    if (after.len != 0) try text_parts.append(try allocator.dupe(u8, after));
    return .{ .text_parts = try text_parts.toOwnedSlice(), .calls = try calls.toOwnedSlice() };
}

fn parseMarkdownNamedToolFences(allocator: std.mem.Allocator, response: []const u8) types.ParserError!?MarkdownResult {
    // MVZR_GAP: Rust pattern `(?s)```tool\s+(\w+)\s*\n(.*?)(?:```|$)`
    // needs captures and lazy dotall; fallback scans the fence header.
    var text_parts = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (text_parts.items) |part| allocator.free(part);
        text_parts.deinit();
    }
    var calls = std.ArrayList(types.ParsedToolCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }

    var last_end: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, response[pos..], "```tool")) |rel| {
        const start = pos + rel;
        var i = start + "```tool".len;
        if (i >= response.len or !std.ascii.isWhitespace(response[i])) {
            pos = i;
            continue;
        }
        while (i < response.len and std.ascii.isWhitespace(response[i]) and response[i] != '\n') i += 1;
        const name_start = i;
        while (i < response.len and (std.ascii.isAlphanumeric(response[i]) or response[i] == '_')) i += 1;
        if (i == name_start) {
            pos = i;
            continue;
        }
        const tool_name = response[name_start..i];
        while (i < response.len and response[i] != '\n') i += 1;
        if (i >= response.len) break;
        const inner_start = i + 1;
        const close_rel = std.mem.indexOf(u8, response[inner_start..], "```");
        const inner_end = if (close_rel) |close| inner_start + close else response.len;
        const full_end = if (close_rel) |close| inner_start + close + "```".len else response.len;

        const before = std.mem.trim(u8, response[last_end..start], " \t\r\n");
        if (before.len != 0) try text_parts.append(try allocator.dupe(u8, before));

        const json_values = try json.extractJsonValues(allocator, response[inner_start..inner_end]);
        defer {
            for (json_values) |*value| types.freeJsonValue(allocator, value);
            allocator.free(json_values);
        }
        for (json_values) |value| {
            var arguments = if (value == .object)
                try types.cloneJsonValue(allocator, value)
            else
                types.emptyObject(allocator);
            try appendOwnedCall(allocator, &calls, tool_name, &arguments);
        }
        last_end = full_end;
        pos = full_end;
    }

    if (calls.items.len == 0) {
        for (text_parts.items) |part| allocator.free(part);
        text_parts.deinit();
        calls.deinit();
        return null;
    }

    const after = std.mem.trim(u8, response[last_end..], " \t\r\n");
    if (after.len != 0) try text_parts.append(try allocator.dupe(u8, after));
    return .{ .text_parts = try text_parts.toOwnedSlice(), .calls = try calls.toOwnedSlice() };
}

fn finish(
    allocator: std.mem.Allocator,
    text_parts: *std.ArrayList([]u8),
    calls: *std.ArrayList(types.ParsedToolCall),
) !types.ParseResult {
    const text = try joinTextParts(allocator, text_parts.items);
    errdefer allocator.free(text);
    const owned_calls = try calls.toOwnedSlice();
    text_parts.clearRetainingCapacity();
    calls.* = std.ArrayList(types.ParsedToolCall).init(allocator);
    return .{ .text = text, .calls = owned_calls };
}

fn replaceTextParts(
    allocator: std.mem.Allocator,
    target: *std.ArrayList([]u8),
    replacement: [][]u8,
) !void {
    for (target.items) |part| allocator.free(part);
    target.clearRetainingCapacity();
    try target.appendSlice(replacement);
    allocator.free(replacement);
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

fn removeMinimaxToolcallBlock(allocator: std.mem.Allocator, input_owned: []u8) ![]u8 {
    return removeToolCallBlocksRusty(allocator, input_owned, "<minimax:toolcall>", "</minimax:toolcall>");
}

// Consumes input_owned on success (frees it) and returns a new owned buffer
// with all `start_marker..end_marker` pairs removed. On error, input_owned is
// left untouched so the caller's defer/errdefer can free it. Single-pass over
// input — never mutates input_owned and never frees it until success is
// guaranteed; the previous iterative free-then-realloc pattern lost the
// caller's input on any post-iteration-1 OOM.
fn removeToolCallBlocksRusty(
    allocator: std.mem.Allocator,
    input_owned: []u8,
    start_marker: []const u8,
    end_marker: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var cursor: usize = 0;
    while (std.mem.indexOf(u8, input_owned[cursor..], start_marker)) |rel_start| {
        const start = cursor + rel_start;
        const after_start = input_owned[start + start_marker.len ..];
        const end_rel = std.mem.indexOf(u8, after_start, end_marker) orelse break;
        const end_pos = start + start_marker.len + end_rel + end_marker.len;
        try out.appendSlice(input_owned[cursor..start]);
        cursor = end_pos;
    }
    try out.appendSlice(input_owned[cursor..]);

    const new_buffer = try out.toOwnedSlice();
    allocator.free(input_owned);
    return new_buffer;
}

fn replaceAllOwned(
    allocator: std.mem.Allocator,
    input_owned: []u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var rest = input_owned;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        try out.appendSlice(rest[0..idx]);
        try out.appendSlice(replacement);
        rest = rest[idx + needle.len ..];
    }
    try out.appendSlice(rest);
    // Take ownership of the new buffer FIRST, then free the input. The previous
    // order — free(input_owned); return out.toOwnedSlice(); — would orphan the
    // caller on toOwnedSlice OOM (input freed, no replacement returned, caller's
    // `defer allocator.free(cleaned_text)` at the call site double-frees). Same
    // template as removeToolCallBlocksRusty (audit commit 47a7dc8 missed this
    // sibling helper).
    const new_buffer = try out.toOwnedSlice();
    allocator.free(input_owned);
    return new_buffer;
}

fn findNextAny(haystack: []const u8, needles: []const []const u8) ?FoundNeedle {
    var best: ?FoundNeedle = null;
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle)) |idx| {
            if (best == null or idx < best.?.start) best = .{ .start = idx, .needle = needle };
        }
    }
    return best;
}

test "smoke" {
    var result = try parseToolCalls(std.testing.allocator, "<tool_call>{\"name\":\"shell\",\"arguments\":{\"command\":\"pwd\"}}</tool_call>", null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
}

fn removeToolCallBlocksRustyOomImpl(allocator: std.mem.Allocator) !void {
    // Multi-pair input forces the helper through both a removal-block branch
    // and a final-tail append, exercising every appendSlice + toOwnedSlice
    // alloc. Caller mirrors the production pattern: dupe the input, then
    // either the helper consumes it (success) or leaves it untouched (error).
    const input = try allocator.dupe(u8, "head<TC>aaa</TC>middle<TC>bbb</TC>tail");
    var input_consumed = false;
    errdefer if (!input_consumed) allocator.free(input);

    const cleaned = try removeToolCallBlocksRusty(allocator, input, "<TC>", "</TC>");
    input_consumed = true;
    defer allocator.free(cleaned);

    try std.testing.expectEqualStrings("headmiddletail", cleaned);
}

test "removeToolCallBlocksRusty is OOM-safe (regression for free-then-realloc fix)" {
    // Previous iterative-replace pattern freed `current` before the new
    // toOwnedSlice succeeded; a post-iteration-1 OOM left the helper
    // returning to a caller whose input was already freed, then the
    // caller's defer double-freed it. Regression sweep verifies that
    // for every fail_index, either the helper succeeds cleanly or the
    // caller's input is left intact for its own defer to free.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, removeToolCallBlocksRustyOomImpl, .{});
}

fn replaceAllOwnedOomImpl(allocator: std.mem.Allocator) !void {
    // Multiple replacements force the helper through several appendSlice
    // calls plus the final toOwnedSlice. Caller mirrors the production
    // pattern at entry.zig:231-238 (dupe + defer + reassign).
    const input = try allocator.dupe(u8, "abc<X>middle<X>tail<X>end");
    var input_consumed = false;
    errdefer if (!input_consumed) allocator.free(input);

    const cleaned = try replaceAllOwned(allocator, input, "<X>", "");
    input_consumed = true;
    defer allocator.free(cleaned);

    try std.testing.expectEqualStrings("abcmiddletailend", cleaned);
}

test "replaceAllOwned is OOM-safe (regression for missed-by-47a7dc8 free-then-realloc)" {
    // Audit commit 47a7dc8 missed this third sibling of removeToolCallBlocksRusty:
    // line 651 (pre-fix) freed input_owned BEFORE out.toOwnedSlice(); a
    // toOwnedSlice OOM then orphaned the caller. Regression sweep verifies
    // the alloc-then-free fix.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, replaceAllOwnedOomImpl, .{});
}
