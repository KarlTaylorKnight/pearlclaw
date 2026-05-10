const std = @import("std");

pub const MAX_API_ERROR_CHARS: usize = 500;

const REDACTED = "[REDACTED]";
const PREFIXES = [_][]const u8{
    "sk-",
    "xoxb-",
    "xoxp-",
    "ghp_",
    "gho_",
    "ghu_",
    "github_pat_",
};

/// Scrub known secret-like token prefixes from provider error strings.
///
/// Returns a caller-owned slice allocated with `allocator`; the caller must
/// free the returned slice with the same allocator.
pub fn scrubSecretPatterns(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var scrubbed = try allocator.dupe(u8, input);
    errdefer allocator.free(scrubbed);

    for (PREFIXES) |prefix| {
        const next = try scrubPrefix(allocator, scrubbed, prefix);
        allocator.free(scrubbed);
        scrubbed = next;
    }

    return scrubbed;
}

/// Scrub secrets from provider API error text and truncate long messages.
///
/// Returns a caller-owned slice allocated with `allocator`; the caller must
/// free the returned slice with the same allocator.
pub fn sanitizeApiError(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const ellipsis = "...";
    var scrubbed = try scrubSecretPatterns(allocator, input);
    errdefer allocator.free(scrubbed);

    if ((try std.unicode.utf8CountCodepoints(scrubbed)) <= MAX_API_ERROR_CHARS) {
        return scrubbed;
    }

    var end: usize = MAX_API_ERROR_CHARS;
    while (end > 0 and !isCharBoundary(scrubbed, end)) {
        end -= 1;
    }

    var sanitized = std.ArrayList(u8).init(allocator);
    errdefer sanitized.deinit();
    try sanitized.ensureTotalCapacity(end + ellipsis.len);
    sanitized.appendSliceAssumeCapacity(scrubbed[0..end]);
    sanitized.appendSliceAssumeCapacity(ellipsis);

    const output = try sanitized.toOwnedSlice();
    allocator.free(scrubbed);
    return output;
}

fn scrubPrefix(allocator: std.mem.Allocator, input: []const u8, prefix: []const u8) ![]u8 {
    const final_len = scrubbedLengthForPrefix(input, prefix);

    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    try list.ensureTotalCapacity(final_len);

    var cursor: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, input, search_from, prefix)) |start| {
        const content_start = start + prefix.len;
        const end = tokenEnd(input, content_start);

        if (end == content_start) {
            search_from = content_start;
            continue;
        }

        list.appendSliceAssumeCapacity(input[cursor..start]);
        list.appendSliceAssumeCapacity(REDACTED);
        cursor = end;
        search_from = end;
    }
    list.appendSliceAssumeCapacity(input[cursor..]);

    std.debug.assert(list.items.len == final_len);
    return list.toOwnedSlice();
}

fn scrubbedLengthForPrefix(input: []const u8, prefix: []const u8) usize {
    var final_len = input.len;
    var search_from: usize = 0;

    while (std.mem.indexOfPos(u8, input, search_from, prefix)) |start| {
        const content_start = start + prefix.len;
        const end = tokenEnd(input, content_start);

        if (end == content_start) {
            search_from = content_start;
            continue;
        }

        final_len -= end - start;
        final_len += REDACTED.len;
        search_from = end;
    }

    return final_len;
}

fn isSecretChar(c: u21) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', ':' => true,
        else => false,
    };
}

fn tokenEnd(input: []const u8, from: usize) usize {
    var end = from;
    var index = from;

    while (index < input.len) {
        const codepoint_len = std.unicode.utf8ByteSequenceLength(input[index]) catch break;
        if (index + codepoint_len > input.len) break;
        const codepoint = std.unicode.utf8Decode(input[index .. index + codepoint_len]) catch break;
        if (!isSecretChar(codepoint)) break;

        index += codepoint_len;
        end = index;
    }

    return end;
}

fn isCharBoundary(input: []const u8, index: usize) bool {
    if (index == 0 or index == input.len) return true;
    if (index > input.len) return false;
    return (input[index] & 0xC0) != 0x80;
}

fn expectScrub(input: []const u8, expected: []const u8) !void {
    const output = try scrubSecretPatterns(std.testing.allocator, input);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

fn expectSanitize(input: []const u8, expected: []const u8) !void {
    const output = try sanitizeApiError(std.testing.allocator, input);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "scrubSecretPatterns redacts Rust prefixes in order" {
    try expectScrub(
        "openai sk-alpha slack xoxb-bot xoxp-user github ghp_repo gho_oauth ghu_user pat github_pat_token",
        "openai [REDACTED] slack [REDACTED] [REDACTED] github [REDACTED] [REDACTED] [REDACTED] pat [REDACTED]",
    );
}

test "scrubSecretPatterns leaves bare prefixes and continues scanning" {
    try expectScrub("bare sk- then sk-live_token", "bare sk- then [REDACTED]");
}

test "sanitizeApiError scrubs before truncating" {
    try expectSanitize("provider rejected sk-live_token", "provider rejected [REDACTED]");
}

test "sanitizeApiError truncates ASCII at byte 500" {
    var input = std.ArrayList(u8).init(std.testing.allocator);
    defer input.deinit();
    try input.appendNTimes('a', MAX_API_ERROR_CHARS + 1);

    var expected = std.ArrayList(u8).init(std.testing.allocator);
    defer expected.deinit();
    try expected.appendNTimes('a', MAX_API_ERROR_CHARS);
    try expected.appendSlice("...");

    try expectSanitize(input.items, expected.items);
}

test "sanitizeApiError backs up to a UTF-8 boundary at byte 500" {
    var input = std.ArrayList(u8).init(std.testing.allocator);
    defer input.deinit();
    try input.appendNTimes('a', MAX_API_ERROR_CHARS - 1);
    try input.appendSlice("𝓤tail");

    var expected = std.ArrayList(u8).init(std.testing.allocator);
    defer expected.deinit();
    try expected.appendNTimes('a', MAX_API_ERROR_CHARS - 1);
    try expected.appendSlice("...");

    try expectSanitize(input.items, expected.items);
}

fn providerSecretsOomImpl(allocator: std.mem.Allocator, input: []const u8) !void {
    const scrubbed = try scrubSecretPatterns(allocator, input);
    defer allocator.free(scrubbed);

    const sanitized = try sanitizeApiError(allocator, input);
    defer allocator.free(sanitized);
}

test "provider secret scrub and sanitize are OOM safe on dense redaction plus UTF-8 truncation" {
    var input = std.ArrayList(u8).init(std.testing.allocator);
    defer input.deinit();
    try input.appendSlice("sk-alpha ghp_beta xoxb-bot xoxp-user ");
    try input.appendNTimes('a', MAX_API_ERROR_CHARS - 1);
    try input.appendSlice("𝓤tail github_pat_token");

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        providerSecretsOomImpl,
        .{@as([]const u8, input.items)},
    );
}
