const std = @import("std");
const dispatcher = @import("../runtime/agent/dispatcher.zig");

const IMAGE_MARKER_PREFIX = "[IMAGE:";
const DEFAULT_MAX_IMAGES: usize = 4;
const DEFAULT_MAX_IMAGE_SIZE_MB: usize = 5;
const MAX_LIMIT_IMAGES: usize = 16;
const MAX_LIMIT_IMAGE_SIZE_MB: usize = 20;
const IMAGE_REMOVED_PLACEHOLDER = "[image removed from history]";

pub const MultimodalError = error{
    TooManyImages,
    ImageTooLarge,
    UnsupportedMime,
    RemoteFetchDisabled,
    ImageSourceNotFound,
    InvalidMarker,
    RemoteFetchFailed,
    LocalReadFailed,
};

pub const MultimodalConfig = struct {
    max_images: usize = DEFAULT_MAX_IMAGES,
    max_image_size_mb: usize = DEFAULT_MAX_IMAGE_SIZE_MB,
    allow_remote_fetch: bool = false,

    pub fn effectiveLimits(self: MultimodalConfig) struct { max_images: usize, max_image_size_mb: usize } {
        return .{
            .max_images = @max(1, @min(self.max_images, MAX_LIMIT_IMAGES)),
            .max_image_size_mb = @max(1, @min(self.max_image_size_mb, MAX_LIMIT_IMAGE_SIZE_MB)),
        };
    }
};

pub const ParsedImageMarkers = struct {
    cleaned: []u8,
    refs: [][]u8,

    pub fn deinit(self: *ParsedImageMarkers, allocator: std.mem.Allocator) void {
        allocator.free(self.cleaned);
        freeStringSlice(allocator, self.refs);
        self.* = undefined;
    }
};

pub const PreparedMessages = struct {
    messages: []dispatcher.ChatMessage,
    contains_images: bool,

    pub fn deinit(self: *PreparedMessages, allocator: std.mem.Allocator) void {
        freeChatMessages(allocator, self.messages);
        self.* = undefined;
    }
};

pub fn parseImageMarkers(allocator: std.mem.Allocator, content: []const u8) !ParsedImageMarkers {
    var refs = std.ArrayList([]u8).init(allocator);
    var cleaned = std.ArrayList(u8).init(allocator);
    errdefer {
        for (refs.items) |value| allocator.free(value);
        refs.deinit();
        cleaned.deinit();
    }

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, IMAGE_MARKER_PREFIX)) |start| {
        try cleaned.appendSlice(content[cursor..start]);

        const marker_start = start + IMAGE_MARKER_PREFIX.len;
        const rel_end = std.mem.indexOfScalar(u8, content[marker_start..], ']') orelse {
            try cleaned.appendSlice(content[start..]);
            cursor = content.len;
            break;
        };
        const end = marker_start + rel_end;

        const candidate = try collapseWrappedMarker(allocator, content[marker_start..end]);
        if (candidate.len == 0 or !isLoadableImageReference(candidate)) {
            allocator.free(candidate);
            try cleaned.appendSlice(content[start .. end + 1]);
        } else {
            try refs.append(candidate);
        }

        cursor = end + 1;
    }

    if (cursor < content.len) {
        try cleaned.appendSlice(content[cursor..]);
    }

    const refs_owned = try refs.toOwnedSlice();
    errdefer freeStringSlice(allocator, refs_owned);
    const raw_cleaned = try cleaned.toOwnedSlice();
    errdefer allocator.free(raw_cleaned);

    const trimmed = std.mem.trim(u8, raw_cleaned, " \t\r\n");
    if (trimmed.len == raw_cleaned.len) {
        return .{ .cleaned = raw_cleaned, .refs = refs_owned };
    }

    const cleaned_owned = try allocator.dupe(u8, trimmed);
    allocator.free(raw_cleaned);
    return .{ .cleaned = cleaned_owned, .refs = refs_owned };
}

pub fn countImageMarkers(allocator: std.mem.Allocator, messages: []const dispatcher.ChatMessage) !usize {
    var count: usize = 0;
    for (messages) |message| {
        if (!std.mem.eql(u8, message.role, "user")) continue;
        var parsed = try parseImageMarkers(allocator, message.content);
        defer parsed.deinit(allocator);
        count += parsed.refs.len;
    }
    return count;
}

pub fn containsImageMarkers(allocator: std.mem.Allocator, messages: []const dispatcher.ChatMessage) !bool {
    return (try countImageMarkers(allocator, messages)) > 0;
}

pub fn extractOllamaImagePayload(allocator: std.mem.Allocator, image_ref: []const u8) !?[]u8 {
    if (std.mem.startsWith(u8, image_ref, "data:")) {
        const comma_idx = std.mem.indexOfScalar(u8, image_ref, ',') orelse return null;
        const payload = std.mem.trim(u8, image_ref[comma_idx + 1 ..], " \t\r\n");
        if (payload.len == 0) return null;
        return try allocator.dupe(u8, payload);
    }

    const trimmed = std.mem.trim(u8, image_ref, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub fn prepareMessagesForProvider(
    allocator: std.mem.Allocator,
    messages: []const dispatcher.ChatMessage,
    config: MultimodalConfig,
) !PreparedMessages {
    const limits = config.effectiveLimits();
    const max_bytes = limits.max_image_size_mb * 1024 * 1024;
    const total_images = try countImageMarkers(allocator, messages);

    if (total_images == 0) {
        return .{
            .messages = try cloneChatMessages(allocator, messages),
            .contains_images = false,
        };
    }

    const trimmed = if (total_images > limits.max_images)
        try trimOldImages(allocator, messages, limits.max_images)
    else
        try cloneChatMessages(allocator, messages);
    defer freeChatMessages(allocator, trimmed);

    var normalized_messages = std.ArrayList(dispatcher.ChatMessage).init(allocator);
    errdefer {
        for (normalized_messages.items) |*message| message.deinit(allocator);
        normalized_messages.deinit();
    }

    var remote_client = std.http.Client{ .allocator = allocator };
    defer remote_client.deinit();

    for (trimmed) |message| {
        if (!std.mem.eql(u8, message.role, "user")) {
            try normalized_messages.append(try cloneChatMessage(allocator, message));
            continue;
        }

        var parsed = try parseImageMarkers(allocator, message.content);
        defer parsed.deinit(allocator);
        if (parsed.refs.len == 0) {
            try normalized_messages.append(try cloneChatMessage(allocator, message));
            continue;
        }

        var normalized_refs = std.ArrayList([]u8).init(allocator);
        errdefer {
            for (normalized_refs.items) |value| allocator.free(value);
            normalized_refs.deinit();
        }
        for (parsed.refs) |reference| {
            try normalized_refs.append(try normalizeImageReference(allocator, reference, config, max_bytes, &remote_client));
        }
        const normalized_refs_owned = try normalized_refs.toOwnedSlice();
        defer freeStringSlice(allocator, normalized_refs_owned);

        const content = try composeMultimodalMessage(allocator, parsed.cleaned, normalized_refs_owned);
        errdefer allocator.free(content);
        const role = try allocator.dupe(u8, message.role);
        errdefer allocator.free(role);
        try normalized_messages.append(.{ .role = role, .content = content });
    }

    return .{
        .messages = try normalized_messages.toOwnedSlice(),
        .contains_images = true,
    };
}

pub const parse_image_markers = parseImageMarkers;
pub const count_image_markers = countImageMarkers;
pub const contains_image_markers = containsImageMarkers;
pub const extract_ollama_image_payload = extractOllamaImagePayload;
pub const prepare_messages_for_provider = prepareMessagesForProvider;

fn isLoadableImageReference(candidate: []const u8) bool {
    return std.mem.startsWith(u8, candidate, "/") or
        std.mem.startsWith(u8, candidate, "http://") or
        std.mem.startsWith(u8, candidate, "https://") or
        std.mem.startsWith(u8, candidate, "data:");
}

fn collapseWrappedMarker(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, raw, "\n\r") == null) {
        return try allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var skip_ws = false;
    for (raw) |byte| {
        if (byte == '\n' or byte == '\r') {
            skip_ws = true;
            continue;
        }
        if (skip_ws) {
            if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') {
                continue;
            }
            skip_ws = false;
        }
        try out.append(byte);
    }

    const raw_owned = try out.toOwnedSlice();
    errdefer allocator.free(raw_owned);
    const trimmed = std.mem.trim(u8, raw_owned, " \t\r\n");
    if (trimmed.len == raw_owned.len) return raw_owned;

    const owned_trimmed = try allocator.dupe(u8, trimmed);
    allocator.free(raw_owned);
    return owned_trimmed;
}

fn trimOldImages(
    allocator: std.mem.Allocator,
    messages: []const dispatcher.ChatMessage,
    max_images: usize,
) ![]dispatcher.ChatMessage {
    var strip = try allocator.alloc(bool, messages.len);
    defer allocator.free(strip);
    @memset(strip, false);

    var counts = try allocator.alloc(usize, messages.len);
    defer allocator.free(counts);
    @memset(counts, 0);

    var total: usize = 0;
    for (messages, 0..) |message, i| {
        if (!std.mem.eql(u8, message.role, "user")) continue;
        var parsed = try parseImageMarkers(allocator, message.content);
        defer parsed.deinit(allocator);
        counts[i] = parsed.refs.len;
        total += parsed.refs.len;
    }

    var to_drop = total -| max_images;
    for (counts, 0..) |count, i| {
        if (to_drop == 0) break;
        if (count == 0) continue;
        strip[i] = true;
        to_drop = to_drop -| count;
    }

    var result = std.ArrayList(dispatcher.ChatMessage).init(allocator);
    errdefer {
        for (result.items) |*message| message.deinit(allocator);
        result.deinit();
    }

    for (messages, 0..) |message, i| {
        if (!strip[i]) {
            try result.append(try cloneChatMessage(allocator, message));
            continue;
        }

        var parsed = try parseImageMarkers(allocator, message.content);
        defer parsed.deinit(allocator);
        const text = if (std.mem.trim(u8, parsed.cleaned, " \t\r\n").len == 0)
            IMAGE_REMOVED_PLACEHOLDER
        else
            parsed.cleaned;

        const role = try allocator.dupe(u8, message.role);
        errdefer allocator.free(role);
        const content = try allocator.dupe(u8, text);
        errdefer allocator.free(content);
        try result.append(.{ .role = role, .content = content });
    }

    return result.toOwnedSlice();
}

fn composeMultimodalMessage(allocator: std.mem.Allocator, text: []const u8, data_uris: []const []const u8) ![]u8 {
    var content = std.ArrayList(u8).init(allocator);
    errdefer content.deinit();

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len != 0) {
        try content.appendSlice(trimmed);
        try content.appendSlice("\n\n");
    }

    for (data_uris, 0..) |data_uri, index| {
        if (index != 0) try content.append('\n');
        try content.appendSlice(IMAGE_MARKER_PREFIX);
        try content.appendSlice(data_uri);
        try content.append(']');
    }

    return content.toOwnedSlice();
}

fn normalizeImageReference(
    allocator: std.mem.Allocator,
    source: []const u8,
    config: MultimodalConfig,
    max_bytes: usize,
    remote_client: *std.http.Client,
) ![]u8 {
    if (std.mem.startsWith(u8, source, "data:")) {
        return normalizeDataUri(allocator, source, max_bytes);
    }

    if (std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://")) {
        if (!config.allow_remote_fetch) return error.RemoteFetchDisabled;
        return normalizeRemoteImage(allocator, source, max_bytes, remote_client);
    }

    return normalizeLocalImage(allocator, source, max_bytes);
}

fn normalizeDataUri(allocator: std.mem.Allocator, source: []const u8, max_bytes: usize) ![]u8 {
    const comma_idx = std.mem.indexOfScalar(u8, source, ',') orelse return error.InvalidMarker;
    const header = source[0..comma_idx];
    const payload = std.mem.trim(u8, source[comma_idx + 1 ..], " \t\r\n");

    if (std.mem.indexOf(u8, header, ";base64") == null) return error.InvalidMarker;

    const mime_part = std.mem.trim(u8, header["data:".len..], " \t\r\n");
    const semi_idx = std.mem.indexOfScalar(u8, mime_part, ';') orelse mime_part.len;
    const mime = try std.ascii.allocLowerString(allocator, std.mem.trim(u8, mime_part[0..semi_idx], " \t\r\n"));
    defer allocator.free(mime);

    try validateMime(mime);

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(payload) catch return error.InvalidMarker;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, payload) catch return error.InvalidMarker;

    try validateSize(decoded.len, max_bytes);

    const encoded = try encodeBase64(allocator, decoded);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime, encoded });
}

fn normalizeRemoteImage(
    allocator: std.mem.Allocator,
    source: []const u8,
    max_bytes: usize,
    remote_client: *std.http.Client,
) ![]u8 {
    const uri = std.Uri.parse(source) catch return error.RemoteFetchFailed;
    var server_header_buffer: [16 * 1024]u8 = undefined;
    var request = remote_client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .redirect_behavior = @enumFromInt(3),
    }) catch return error.RemoteFetchFailed;
    defer request.deinit();

    request.send() catch return error.RemoteFetchFailed;
    request.finish() catch return error.RemoteFetchFailed;
    request.wait() catch return error.RemoteFetchFailed;

    if (request.response.status.class() != .success) return error.RemoteFetchFailed;
    if (request.response.content_length) |content_length| try validateSize(sizeToUsize(content_length), max_bytes);

    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();
    request.reader().readAllArrayList(&body, max_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.ImageTooLarge,
        else => return error.RemoteFetchFailed,
    };

    try validateSize(body.items.len, max_bytes);
    const mime = (try detectMime(allocator, null, body.items, request.response.content_type)) orelse return error.UnsupportedMime;
    defer allocator.free(mime);
    try validateMime(mime);

    const encoded = try encodeBase64(allocator, body.items);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime, encoded });
}

fn normalizeLocalImage(allocator: std.mem.Allocator, source: []const u8, max_bytes: usize) ![]u8 {
    var file = openLocalFile(source) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.ImageSourceNotFound,
        else => return error.LocalReadFailed,
    };
    defer file.close();

    const stat = file.stat() catch return error.LocalReadFailed;
    if (stat.kind != .file) return error.ImageSourceNotFound;
    try validateSize(sizeToUsize(stat.size), max_bytes);

    const bytes = file.readToEndAlloc(allocator, max_bytes) catch |err| switch (err) {
        error.FileTooBig => return error.ImageTooLarge,
        else => return error.LocalReadFailed,
    };
    defer allocator.free(bytes);
    try validateSize(bytes.len, max_bytes);

    const mime = (try detectMime(allocator, source, bytes, null)) orelse return error.UnsupportedMime;
    defer allocator.free(mime);
    try validateMime(mime);

    const encoded = try encodeBase64(allocator, bytes);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime, encoded });
}

fn openLocalFile(source: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(source)) {
        return std.fs.openFileAbsolute(source, .{});
    }
    return std.fs.cwd().openFile(source, .{});
}

fn validateSize(size_bytes: usize, max_bytes: usize) !void {
    if (size_bytes > max_bytes) return error.ImageTooLarge;
}

fn validateMime(mime: []const u8) !void {
    if (std.mem.eql(u8, mime, "image/png") or
        std.mem.eql(u8, mime, "image/jpeg") or
        std.mem.eql(u8, mime, "image/webp") or
        std.mem.eql(u8, mime, "image/gif") or
        std.mem.eql(u8, mime, "image/bmp"))
    {
        return;
    }
    return error.UnsupportedMime;
}

fn detectMime(
    allocator: std.mem.Allocator,
    path: ?[]const u8,
    bytes: []const u8,
    header_content_type: ?[]const u8,
) !?[]u8 {
    if (header_content_type) |content_type| {
        if (try normalizeContentType(allocator, content_type)) |mime| {
            return mime;
        }
    }

    if (path) |path_value| {
        const ext = std.fs.path.extension(path_value);
        if (mimeFromExtension(if (std.mem.startsWith(u8, ext, ".")) ext[1..] else ext)) |mime| {
            return try allocator.dupe(u8, mime);
        }
    }

    if (mimeFromMagic(bytes)) |mime| {
        return try allocator.dupe(u8, mime);
    }

    return null;
}

fn normalizeContentType(allocator: std.mem.Allocator, content_type: []const u8) !?[]u8 {
    const semi_idx = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    const mime = std.mem.trim(u8, content_type[0..semi_idx], " \t\r\n");
    if (mime.len == 0) return null;
    return try std.ascii.allocLowerString(allocator, mime);
}

fn mimeFromExtension(ext: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(ext, "png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, "webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, "gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, "bmp")) return "image/bmp";
    return null;
}

fn mimeFromMagic(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.startsWith(u8, bytes, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' })) {
        return "image/png";
    }

    if (bytes.len >= 3 and std.mem.startsWith(u8, bytes, &.{ 0xff, 0xd8, 0xff })) {
        return "image/jpeg";
    }

    if (bytes.len >= 6 and (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a"))) {
        return "image/gif";
    }

    if (bytes.len >= 12 and std.mem.startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        return "image/webp";
    }

    if (bytes.len >= 2 and std.mem.startsWith(u8, bytes, "BM")) {
        return "image/bmp";
    }

    return null;
}

fn encodeBase64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const len = std.base64.standard.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn cloneChatMessages(allocator: std.mem.Allocator, messages: []const dispatcher.ChatMessage) ![]dispatcher.ChatMessage {
    const cloned = try allocator.alloc(dispatcher.ChatMessage, messages.len);
    var count: usize = 0;
    errdefer {
        for (cloned[0..count]) |*message| message.deinit(allocator);
        allocator.free(cloned);
    }

    for (messages) |message| {
        cloned[count] = try cloneChatMessage(allocator, message);
        count += 1;
    }

    return cloned;
}

fn cloneChatMessage(allocator: std.mem.Allocator, message: dispatcher.ChatMessage) !dispatcher.ChatMessage {
    const role = try allocator.dupe(u8, message.role);
    errdefer allocator.free(role);
    const content = try allocator.dupe(u8, message.content);
    errdefer allocator.free(content);
    return .{ .role = role, .content = content };
}

fn freeChatMessages(allocator: std.mem.Allocator, messages: []dispatcher.ChatMessage) void {
    for (messages) |*message| message.deinit(allocator);
    allocator.free(messages);
}

fn freeStringSlice(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn sizeToUsize(value: u64) usize {
    return if (value > std.math.maxInt(usize)) std.math.maxInt(usize) else @intCast(value);
}

test "parseImageMarkers extracts multiple markers" {
    var parsed = try parseImageMarkers(
        std.testing.allocator,
        "Check this [IMAGE:/tmp/a.png] and this [IMAGE:https://example.com/b.jpg]",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Check this  and this", parsed.cleaned);
    try std.testing.expectEqual(@as(usize, 2), parsed.refs.len);
    try std.testing.expectEqualStrings("/tmp/a.png", parsed.refs[0]);
    try std.testing.expectEqualStrings("https://example.com/b.jpg", parsed.refs[1]);
}

test "parseImageMarkers preserves placeholder markers" {
    var parsed = try parseImageMarkers(
        std.testing.allocator,
        "example: `[IMAGE:...]` or `[IMAGE:<path>]` or `[IMAGE:example.png]`",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), parsed.refs.len);
    try std.testing.expect(std.mem.indexOf(u8, parsed.cleaned, "[IMAGE:...]") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.cleaned, "[IMAGE:<path>]") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.cleaned, "[IMAGE:example.png]") != null);
}

test "parseImageMarkers collapses wrapped marker" {
    var parsed = try parseImageMarkers(
        std.testing.allocator,
        "from logs\n  [IMAGE:/home/user/signal_i\n  nbound/attachment.jpg] done",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.refs.len);
    try std.testing.expectEqualStrings("/home/user/signal_inbound/attachment.jpg", parsed.refs[0]);
}

test "extractOllamaImagePayload supports data URI and passthrough" {
    const payload = (try extractOllamaImagePayload(std.testing.allocator, "data:image/png;base64,abcd==")).?;
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualStrings("abcd==", payload);

    const path = (try extractOllamaImagePayload(std.testing.allocator, "  /tmp/photo.jpg\n")).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/photo.jpg", path);
}

test "prepareMessagesForProvider normalizes local image" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "sample.png" });
    defer std.testing.allocator.free(path);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });

    const content = try std.fmt.allocPrint(std.testing.allocator, "Please inspect [IMAGE:{s}]", .{path});
    defer std.testing.allocator.free(content);
    const messages = [_]dispatcher.ChatMessage{.{ .role = "user", .content = content }};

    var prepared = try prepareMessagesForProvider(std.testing.allocator, &messages, .{});
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.contains_images);
    try std.testing.expectEqual(@as(usize, 1), prepared.messages.len);
    try std.testing.expectEqualStrings(
        "Please inspect\n\n[IMAGE:data:image/png;base64,iVBORw0KGgo=]",
        prepared.messages[0].content,
    );
}

test "prepareMessagesForProvider trims old images before normalization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    var paths: [3][]u8 = undefined;
    defer for (paths) |path| std.testing.allocator.free(path);
    for (&paths, 0..) |*path_slot, i| {
        path_slot.* = try std.fs.path.join(std.testing.allocator, &.{ dir, switch (i) {
            0 => "old.png",
            1 => "mid.png",
            else => "new.png",
        } });
        var file = try std.fs.cwd().createFile(path_slot.*, .{ .truncate = true });
        defer file.close();
        try file.writeAll(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    }

    const old_content = try std.fmt.allocPrint(std.testing.allocator, "[IMAGE:{s}]\nOld", .{paths[0]});
    defer std.testing.allocator.free(old_content);
    const mid_content = try std.fmt.allocPrint(std.testing.allocator, "[IMAGE:{s}]\nMid", .{paths[1]});
    defer std.testing.allocator.free(mid_content);
    const new_content = try std.fmt.allocPrint(std.testing.allocator, "[IMAGE:{s}]\nNew", .{paths[2]});
    defer std.testing.allocator.free(new_content);

    const messages = [_]dispatcher.ChatMessage{
        .{ .role = "user", .content = old_content },
        .{ .role = "user", .content = mid_content },
        .{ .role = "user", .content = new_content },
    };

    var prepared = try prepareMessagesForProvider(std.testing.allocator, &messages, .{ .max_images = 2 });
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Old", prepared.messages[0].content);
    try std.testing.expect(std.mem.indexOf(u8, prepared.messages[1].content, "data:image/png;base64,iVBORw0KGgo=") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.messages[2].content, "data:image/png;base64,iVBORw0KGgo=") != null);
}
