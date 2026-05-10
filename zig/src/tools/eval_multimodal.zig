//! eval-multimodal — offline multimodal helper parity runner.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const multimodal = zeroclaw.providers.multimodal;
const dispatcher = zeroclaw.runtime.agent.dispatcher;

const EvalError = error{InvalidScenario};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.io.getStdIn().readToEndAlloc(allocator, 32 * 1024 * 1024);
    defer allocator.free(input);

    const stdout = std.io.getStdOut().writer();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        try runOp(allocator, line, stdout);
    }
}

fn runOp(allocator: std.mem.Allocator, line: []const u8, writer: anytype) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const op = getString(parsed.value, "op") orelse return EvalError.InvalidScenario;
    if (std.mem.eql(u8, op, "parse_image_markers")) {
        const content = getString(parsed.value, "content") orelse return EvalError.InvalidScenario;
        var result = try multimodal.parseImageMarkers(allocator, content);
        defer result.deinit(allocator);
        try writer.writeAll("{\"op\":\"parse_image_markers\",\"result\":{\"cleaned\":");
        try std.json.stringify(result.cleaned, .{}, writer);
        try writer.writeAll(",\"refs\":");
        try writeStringList(writer, result.refs);
        try writer.writeAll("}}\n");
    } else if (std.mem.eql(u8, op, "count_image_markers")) {
        const messages = try messagesFromField(allocator, parsed.value, "messages");
        defer freeMessages(allocator, messages);
        const count = try multimodal.countImageMarkers(allocator, messages);
        try writer.print("{{\"op\":\"count_image_markers\",\"result\":{{\"count\":{d}}}}}\n", .{count});
    } else if (std.mem.eql(u8, op, "contains_image_markers")) {
        const messages = try messagesFromField(allocator, parsed.value, "messages");
        defer freeMessages(allocator, messages);
        const contains = try multimodal.containsImageMarkers(allocator, messages);
        try writer.writeAll("{\"op\":\"contains_image_markers\",\"result\":{\"contains\":");
        try writer.writeAll(if (contains) "true" else "false");
        try writer.writeAll("}}\n");
    } else if (std.mem.eql(u8, op, "extract_ollama_image_payload")) {
        const image_ref = getString(parsed.value, "image_ref") orelse return EvalError.InvalidScenario;
        const payload = try multimodal.extractOllamaImagePayload(allocator, image_ref);
        defer if (payload) |value| allocator.free(value);
        try writer.writeAll("{\"op\":\"extract_ollama_image_payload\",\"result\":{\"payload\":");
        if (payload) |value| try std.json.stringify(value, .{}, writer) else try writer.writeAll("null");
        try writer.writeAll("}}\n");
    } else if (std.mem.eql(u8, op, "prepare_messages_for_provider")) {
        try writeScenarioFiles(allocator, parsed.value);
        const messages = try messagesFromField(allocator, parsed.value, "messages");
        defer freeMessages(allocator, messages);
        const config = configFromValue(parsed.value);
        var prepared = multimodal.prepareMessagesForProvider(allocator, messages, config) catch |err| {
            if (multimodalErrorTag(err)) |tag| {
                try writer.writeAll("{\"op\":\"prepare_messages_for_provider\",\"result\":{\"error\":");
                try std.json.stringify(tag, .{}, writer);
                try writer.writeAll("}}\n");
                return;
            }
            return err;
        };
        defer prepared.deinit(allocator);

        try writer.writeAll("{\"op\":\"prepare_messages_for_provider\",\"result\":{\"contains_images\":");
        try writer.writeAll(if (prepared.contains_images) "true" else "false");
        try writer.writeAll(",\"messages\":");
        try writeMessages(writer, prepared.messages);
        try writer.writeAll("}}\n");
    } else {
        return EvalError.InvalidScenario;
    }
}

fn configFromValue(value: std.json.Value) multimodal.MultimodalConfig {
    // Start from the library defaults, then override only fields the
    // fixture explicitly set. Avoids the previous drift where the eval
    // runner hardcoded `4` and `5` independently from the library's
    // DEFAULT_MAX_IMAGES / DEFAULT_MAX_IMAGE_SIZE_MB constants.
    var config = multimodal.MultimodalConfig{};
    const config_value = getField(value, "config") orelse return config;
    if (config_value != .object) return config;
    if (getUsize(config_value, "max_images")) |v| config.max_images = v;
    if (getUsize(config_value, "max_image_size_mb")) |v| config.max_image_size_mb = v;
    if (getBool(config_value, "allow_remote_fetch")) |v| config.allow_remote_fetch = v;
    return config;
}

fn writeScenarioFiles(allocator: std.mem.Allocator, value: std.json.Value) !void {
    const files = getArray(value, "files") orelse return;
    for (files.items) |file_value| {
        if (file_value != .object) return EvalError.InvalidScenario;
        const path = getString(file_value, "path") orelse return EvalError.InvalidScenario;
        const bytes = try fileBytesFromValue(allocator, file_value);
        defer allocator.free(bytes);

        if (std.fs.path.dirname(path)) |parent| {
            try std.fs.cwd().makePath(parent);
        }
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
    }
}

fn fileBytesFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    if (getString(value, "bytes_base64")) |bytes_base64| {
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(bytes_base64) catch return EvalError.InvalidScenario;
        const bytes = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(bytes);
        std.base64.standard.Decoder.decode(bytes, bytes_base64) catch return EvalError.InvalidScenario;
        return bytes;
    }

    const byte_values = getArray(value, "bytes") orelse return EvalError.InvalidScenario;
    const bytes = try allocator.alloc(u8, byte_values.items.len);
    errdefer allocator.free(bytes);
    for (byte_values.items, 0..) |item, i| {
        if (item != .integer or item.integer < 0 or item.integer > 255) return EvalError.InvalidScenario;
        bytes[i] = @intCast(item.integer);
    }
    return bytes;
}

fn messagesFromField(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
) ![]dispatcher.ChatMessage {
    const messages_value = getField(value, key) orelse return EvalError.InvalidScenario;
    if (messages_value != .array) return EvalError.InvalidScenario;

    var messages = std.ArrayList(dispatcher.ChatMessage).init(allocator);
    errdefer {
        for (messages.items) |*message| message.deinit(allocator);
        messages.deinit();
    }

    for (messages_value.array.items) |message_value| {
        if (message_value != .object) return EvalError.InvalidScenario;
        const role = getString(message_value, "role") orelse return EvalError.InvalidScenario;
        const content = getString(message_value, "content") orelse return EvalError.InvalidScenario;
        const role_owned = try allocator.dupe(u8, role);
        errdefer allocator.free(role_owned);
        const content_owned = try allocator.dupe(u8, content);
        errdefer allocator.free(content_owned);
        try messages.append(.{ .role = role_owned, .content = content_owned });
    }

    return messages.toOwnedSlice();
}

fn writeMessages(writer: anytype, messages: []const dispatcher.ChatMessage) !void {
    try writer.writeByte('[');
    for (messages, 0..) |message, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.writeAll("{\"role\":");
        try std.json.stringify(message.role, .{}, writer);
        try writer.writeAll(",\"content\":");
        try std.json.stringify(message.content, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeStringList(writer: anytype, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, i| {
        if (i != 0) try writer.writeByte(',');
        try std.json.stringify(value, .{}, writer);
    }
    try writer.writeByte(']');
}

fn freeMessages(allocator: std.mem.Allocator, messages: []dispatcher.ChatMessage) void {
    for (messages) |*message| message.deinit(allocator);
    allocator.free(messages);
}

fn multimodalErrorTag(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.TooManyImages => "multimodal_too_many_images",
        error.ImageTooLarge => "multimodal_image_too_large",
        error.UnsupportedMime => "multimodal_unsupported_mime",
        error.RemoteFetchDisabled => "multimodal_remote_fetch_disabled",
        error.ImageSourceNotFound => "multimodal_image_source_not_found",
        error.InvalidMarker => "multimodal_invalid_marker",
        error.RemoteFetchFailed => "multimodal_remote_fetch_failed",
        error.LocalReadFailed => "multimodal_local_read_failed",
        else => null,
    };
}

fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn getArray(value: std.json.Value, key: []const u8) ?std.json.Array {
    const field = getField(value, key) orelse return null;
    if (field != .array) return null;
    return field.array;
}

fn getBool(value: std.json.Value, key: []const u8) ?bool {
    const field = getField(value, key) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn getUsize(value: std.json.Value, key: []const u8) ?usize {
    const field = getField(value, key) orelse return null;
    if (field != .integer) return null;
    if (field.integer < 0) return null;
    return @intCast(field.integer);
}
