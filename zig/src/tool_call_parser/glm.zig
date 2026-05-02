const std = @import("std");
const types = @import("types.zig");

pub const GlmParsedCall = struct {
    name: []u8,
    arguments: std.json.Value,
    raw: ?[]u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        types.freeJsonValue(allocator, &self.arguments);
        if (self.raw) |raw| allocator.free(raw);
        self.* = undefined;
    }
};

pub fn mapToolNameAlias(tool_name: []const u8) []const u8 {
    if (anyOf(tool_name, &.{ "shell", "bash", "sh", "exec", "command", "cmd", "browser_open", "browser", "web_search" })) return "shell";
    if (anyOf(tool_name, &.{ "send_message", "sendmessage" })) return "message_send";
    if (anyOf(tool_name, &.{ "fileread", "file_read", "readfile", "read_file", "file" })) return "file_read";
    if (anyOf(tool_name, &.{ "filewrite", "file_write", "writefile", "write_file" })) return "file_write";
    if (anyOf(tool_name, &.{ "filelist", "file_list", "listfiles", "list_files" })) return "file_list";
    if (anyOf(tool_name, &.{ "memoryrecall", "memory_recall", "recall", "memrecall" })) return "memory_recall";
    if (anyOf(tool_name, &.{ "memorystore", "memory_store", "store", "memstore" })) return "memory_store";
    if (anyOf(tool_name, &.{ "memoryforget", "memory_forget", "forget", "memforget" })) return "memory_forget";
    if (anyOf(tool_name, &.{ "http_request", "http", "fetch", "curl", "wget" })) return "http_request";
    return tool_name;
}

pub fn buildCurlCommand(allocator: std.mem.Allocator, url: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return null;
    }
    for (url) |ch| {
        if (std.ascii.isWhitespace(ch)) return null;
    }

    var escaped = std.ArrayList(u8).init(allocator);
    defer escaped.deinit();
    for (url) |ch| {
        if (ch == '\'') {
            try escaped.appendSlice("'\\\\''");
        } else {
            try escaped.append(ch);
        }
    }
    return try std.fmt.allocPrint(allocator, "curl -s '{s}'", .{escaped.items});
}

pub fn parseGlmStyleToolCalls(
    allocator: std.mem.Allocator,
    text: []const u8,
) types.ParserError![]GlmParsedCall {
    var calls = std.ArrayList(GlmParsedCall).init(allocator);
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit();
    }

    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const slash = std.mem.indexOfScalar(u8, line, '/') orelse continue;
        const tool_part = line[0..slash];
        const rest = line[slash + 1 ..];
        if (!isToolName(tool_part)) continue;
        const tool_name = mapToolNameAlias(tool_part);

        if (std.mem.indexOfScalar(u8, rest, '>')) |gt_pos| {
            const param_name = std.mem.trim(u8, rest[0..gt_pos], " \t\r\n");
            const value = std.mem.trim(u8, rest[gt_pos + 1 ..], " \t\r\n");
            if (value.len == 0) continue;

            var arguments = (try argsForParamValue(allocator, tool_name, param_name, value)) orelse continue;
            try appendOwnedGlmCall(allocator, &calls, tool_name, &arguments, line);
            continue;
        }

        if (std.mem.startsWith(u8, rest, "{")) {
            if (try types.parseJsonValueOwned(allocator, rest)) |json_args| {
                var arguments = json_args;
                try appendOwnedGlmCall(allocator, &calls, tool_name, &arguments, line);
            }
        }
    }

    return calls.toOwnedSlice();
}

pub fn defaultParamForTool(tool: []const u8) []const u8 {
    if (anyOf(tool, &.{ "shell", "bash", "sh", "exec", "command", "cmd" })) return "command";
    if (anyOf(tool, &.{ "file_read", "fileread", "readfile", "read_file", "file", "file_write", "filewrite", "writefile", "write_file", "file_edit", "fileedit", "editfile", "edit_file", "file_list", "filelist", "listfiles", "list_files" })) return "path";
    if (anyOf(tool, &.{ "memory_recall", "memoryrecall", "recall", "memrecall", "memory_forget", "memoryforget", "forget", "memforget", "web_search_tool", "web_search", "websearch", "search" })) return "query";
    if (anyOf(tool, &.{ "memory_store", "memorystore", "store", "memstore" })) return "content";
    if (anyOf(tool, &.{ "http_request", "http", "fetch", "curl", "wget", "browser_open", "browser" })) return "url";
    return "input";
}

pub fn parseGlmShortenedBody(
    allocator: std.mem.Allocator,
    body_raw: []const u8,
) types.ParserError!?types.ParsedToolCall {
    const body = std.mem.trim(u8, body_raw, " \t\r\n");
    if (body.len == 0) return null;

    var tool_raw: []const u8 = undefined;
    var value_part: []const u8 = undefined;

    if (functionStyle(body)) |parts| {
        tool_raw = parts.tool;
        value_part = parts.args;
    } else if (std.mem.indexOf(u8, body, "=\"") != null) {
        const split_pos = firstWhitespace(body) orelse body.len;
        tool_raw = std.mem.trim(u8, body[0..split_pos], " \t\r\n");
        value_part = trimTrailingSelfClose(std.mem.trim(u8, body[split_pos..], " \t\r\n"));
    } else if (std.mem.indexOfScalar(u8, body, '>')) |gt_pos| {
        tool_raw = std.mem.trim(u8, body[0..gt_pos], " \t\r\n");
        value_part = trimTrailingSelfClose(std.mem.trim(u8, body[gt_pos + 1 ..], " \t\r\n"));
    } else {
        return null;
    }

    tool_raw = std.mem.trimRight(u8, tool_raw, " \t\r\n");
    if (tool_raw.len == 0 or !isToolName(tool_raw)) return null;
    const tool_name = mapToolNameAlias(tool_raw);

    if (std.mem.indexOf(u8, value_part, "=\"") != null) {
        var args = std.json.ObjectMap.init(allocator);
        errdefer {
            var tmp = std.json.Value{ .object = args };
            types.freeJsonValue(allocator, &tmp);
        }

        var rest = value_part;
        while (std.mem.indexOf(u8, rest, "=\"")) |eq_pos| {
            const before = rest[0..eq_pos];
            const key_start = lastWhitespace(before) orelse 0;
            const raw_key = if (key_start == 0) before else before[key_start + 1 ..];
            const key = std.mem.trim(u8, raw_key, " \t\r\n,;");
            const after_quote = rest[eq_pos + 2 ..];
            const end_quote = std.mem.indexOfScalar(u8, after_quote, '"') orelse break;
            const value = after_quote[0..end_quote];
            if (key.len != 0) {
                try types.putOwned(allocator, &args, key, .{ .string = try allocator.dupe(u8, value) });
            }
            rest = after_quote[end_quote + 1 ..];
        }

        if (args.count() != 0) {
            return .{
                .name = try allocator.dupe(u8, tool_name),
                .arguments = .{ .object = args },
                .tool_call_id = null,
            };
        }
        args.deinit();
    }

    if (std.mem.indexOfScalar(u8, value_part, '\n') != null) {
        var args = std.json.ObjectMap.init(allocator);
        errdefer {
            var tmp = std.json.Value{ .object = args };
            types.freeJsonValue(allocator, &tmp);
        }

        var lines = std.mem.splitScalar(u8, value_part, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon], " \t\r\n");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
            if (key.len == 0 or value.len == 0) continue;
            const json_value: std.json.Value = if (anyOf(value, &.{ "true", "yes" }))
                .{ .bool = true }
            else if (anyOf(value, &.{ "false", "no" }))
                .{ .bool = false }
            else
                .{ .string = try allocator.dupe(u8, value) };
            try types.putOwned(allocator, &args, key, json_value);
        }

        if (args.count() != 0) {
            return .{
                .name = try allocator.dupe(u8, tool_name),
                .arguments = .{ .object = args },
                .tool_call_id = null,
            };
        }
        args.deinit();
    }

    if (value_part.len == 0) return null;

    var arguments = (try argsForSingleValue(allocator, tool_name, tool_raw, value_part)) orelse return null;
    var arguments_owned = true;
    errdefer if (arguments_owned) types.freeJsonValue(allocator, &arguments);
    const dup_name = try allocator.dupe(u8, tool_name);
    errdefer if (arguments_owned) allocator.free(dup_name);
    arguments_owned = false;
    return .{ .name = dup_name, .arguments = arguments, .tool_call_id = null };
}

fn appendOwnedGlmCall(
    allocator: std.mem.Allocator,
    calls: *std.ArrayList(GlmParsedCall),
    name_source: []const u8,
    arguments: *std.json.Value,
    raw_source: []const u8,
) !void {
    var arguments_owned = true;
    errdefer if (arguments_owned) types.freeJsonValue(allocator, arguments);

    const dup_name = try allocator.dupe(u8, name_source);
    errdefer if (arguments_owned) allocator.free(dup_name);

    const dup_raw = try allocator.dupe(u8, raw_source);
    errdefer if (arguments_owned) allocator.free(dup_raw);

    try calls.append(.{
        .name = dup_name,
        .arguments = arguments.*,
        .raw = dup_raw,
    });
    arguments_owned = false;
}

fn argsForParamValue(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    param_name: []const u8,
    value: []const u8,
) !?std.json.Value {
    if (std.mem.eql(u8, tool_name, "shell")) {
        if (std.mem.eql(u8, param_name, "url")) {
            const command = (try buildCurlCommand(allocator, value)) orelse return null;
            return try stringObjectTakingValue(allocator, "command", command);
        }
        if (std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://")) {
            if (try buildCurlCommand(allocator, value)) |command| {
                return try stringObjectTakingValue(allocator, "command", command);
            }
        }
        const object = try types.singletonStringObject(allocator, "command", value);
        return object;
    }

    if (std.mem.eql(u8, tool_name, "http_request")) {
        var object = std.json.ObjectMap.init(allocator);
        errdefer {
            var tmp = std.json.Value{ .object = object };
            types.freeJsonValue(allocator, &tmp);
        }
        try types.putOwned(allocator, &object, "url", .{ .string = try allocator.dupe(u8, value) });
        try types.putOwned(allocator, &object, "method", .{ .string = try allocator.dupe(u8, "GET") });
        return .{ .object = object };
    }

    const object = try types.singletonStringObject(allocator, param_name, value);
    return object;
}

fn argsForSingleValue(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    tool_raw: []const u8,
    value: []const u8,
) !?std.json.Value {
    if (std.mem.eql(u8, tool_name, "shell")) {
        if (std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://")) {
            if (try buildCurlCommand(allocator, value)) |command| {
                return try stringObjectTakingValue(allocator, "command", command);
            }
        }
        const object = try types.singletonStringObject(allocator, "command", value);
        return object;
    }
    if (std.mem.eql(u8, tool_name, "http_request")) {
        return try argsForParamValue(allocator, tool_name, "url", value);
    }
    const object = try types.singletonStringObject(allocator, defaultParamForTool(tool_raw), value);
    return object;
}

fn stringObjectTakingValue(allocator: std.mem.Allocator, key: []const u8, value_owned: []u8) !std.json.Value {
    errdefer allocator.free(value_owned);
    var object = std.json.ObjectMap.init(allocator);
    errdefer object.deinit();
    try object.put(try allocator.dupe(u8, key), .{ .string = value_owned });
    return .{ .object = object };
}

fn anyOf(value: []const u8, comptime candidates: []const []const u8) bool {
    inline for (candidates) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn isToolName(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn firstWhitespace(value: []const u8) ?usize {
    for (value, 0..) |ch, i| {
        if (std.ascii.isWhitespace(ch)) return i;
    }
    return null;
}

fn lastWhitespace(value: []const u8) ?usize {
    var i = value.len;
    while (i > 0) {
        i -= 1;
        if (std.ascii.isWhitespace(value[i])) return i;
    }
    return null;
}

fn trimTrailingSelfClose(value: []const u8) []const u8 {
    var out = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.endsWith(u8, out, "/>")) out = std.mem.trimRight(u8, out[0 .. out.len - 2], " \t\r\n");
    if (std.mem.endsWith(u8, out, ">")) out = std.mem.trimRight(u8, out[0 .. out.len - 1], " \t\r\n");
    if (std.mem.endsWith(u8, out, "/")) out = std.mem.trimRight(u8, out[0 .. out.len - 1], " \t\r\n");
    return out;
}

fn functionStyle(body: []const u8) ?struct { tool: []const u8, args: []const u8 } {
    const open = std.mem.indexOfScalar(u8, body, '(') orelse return null;
    if (!std.mem.endsWith(u8, body, ")") or open == 0) return null;
    return .{
        .tool = std.mem.trim(u8, body[0..open], " \t\r\n"),
        .args = std.mem.trim(u8, body[open + 1 .. body.len - 1], " \t\r\n"),
    };
}

test "smoke" {
    var call = (try parseGlmShortenedBody(std.testing.allocator, "shell>pwd")).?;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("shell", call.name);
}
