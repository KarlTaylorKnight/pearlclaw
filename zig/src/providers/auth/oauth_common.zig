const std = @import("std");

const base64_url = std.base64.url_safe_no_pad;
const replacement_char = std.unicode.fmtUtf8;

pub const PkceState = struct {
    code_verifier: []u8,
    code_challenge: []u8,
    state: []u8,

    pub fn deinit(self: *PkceState, allocator: std.mem.Allocator) void {
        allocator.free(self.code_verifier);
        allocator.free(self.code_challenge);
        allocator.free(self.state);
        self.* = undefined;
    }
};

pub const QueryParam = struct {
    key: []u8,
    value: []u8,
};

pub const QueryParams = struct {
    entries: []QueryParam,

    pub fn get(self: QueryParams, key: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn contains(self: QueryParams, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn deinit(self: *QueryParams, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub fn generatePkceState(allocator: std.mem.Allocator) !PkceState {
    const code_verifier = try randomBase64Url(allocator, 64);
    errdefer allocator.free(code_verifier);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(code_verifier, &digest, .{});

    const code_challenge = try base64UrlNoPad(allocator, &digest);
    errdefer allocator.free(code_challenge);

    const state = try randomBase64Url(allocator, 24);
    errdefer allocator.free(state);

    return .{
        .code_verifier = code_verifier,
        .code_challenge = code_challenge,
        .state = state,
    };
}

pub fn pkceStateFromSeed(
    allocator: std.mem.Allocator,
    verifier_seed: []const u8,
    state_seed: []const u8,
) !PkceState {
    const code_verifier = try base64UrlNoPad(allocator, verifier_seed);
    errdefer allocator.free(code_verifier);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(code_verifier, &digest, .{});

    const code_challenge = try base64UrlNoPad(allocator, &digest);
    errdefer allocator.free(code_challenge);

    const state_len = @min(state_seed.len, 24);
    const state = try base64UrlNoPad(allocator, state_seed[0..state_len]);
    errdefer allocator.free(state);

    return .{
        .code_verifier = code_verifier,
        .code_challenge = code_challenge,
        .state = state,
    };
}

pub fn randomBase64Url(allocator: std.mem.Allocator, byte_len: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, byte_len);
    defer allocator.free(bytes);
    std.crypto.random.bytes(bytes);
    return base64UrlNoPad(allocator, bytes);
}

pub fn base64UrlNoPad(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const len = base64_url.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    _ = base64_url.Encoder.encode(out, bytes);
    return out;
}

pub fn decodeBase64UrlNoPad(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const len = try base64_url.Decoder.calcSizeForSlice(input);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try base64_url.Decoder.decode(out, input);
    return out;
}

pub fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(byte),
            else => {
                try out.append('%');
                try out.append(hex[byte >> 4]);
                try out.append(hex[byte & 0x0F]);
            },
        }
    }

    return try out.toOwnedSlice();
}

pub fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var raw = std.ArrayList(u8).init(allocator);
    defer raw.deinit();

    var i: usize = 0;
    while (i < input.len) {
        switch (input[i]) {
            '%' => {
                if (i + 2 < input.len) {
                    if (hexValue(input[i + 1])) |hi| {
                        if (hexValue(input[i + 2])) |lo| {
                            try raw.append((hi << 4) | lo);
                            i += 3;
                            continue;
                        }
                    }
                }
                try raw.append(input[i]);
                i += 1;
            },
            '+' => {
                try raw.append(' ');
                i += 1;
            },
            else => |byte| {
                try raw.append(byte);
                i += 1;
            },
        }
    }

    return try std.fmt.allocPrint(allocator, "{}", .{replacement_char(raw.items)});
}

pub fn parseQueryParams(allocator: std.mem.Allocator, input: []const u8) !QueryParams {
    var entries = std.ArrayList(QueryParam).init(allocator);
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        entries.deinit();
    }

    var pairs = std.mem.splitScalar(u8, input, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, pair, '=');
        const key_raw = if (eq_index) |idx| pair[0..idx] else pair;
        const value_raw = if (eq_index) |idx| pair[idx + 1 ..] else "";

        const key = try urlDecode(allocator, key_raw);
        errdefer allocator.free(key);
        const value = try urlDecode(allocator, value_raw);
        errdefer allocator.free(value);

        var replaced = false;
        for (entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                allocator.free(entry.value);
                allocator.free(key);
                entry.value = value;
                replaced = true;
                break;
            }
        }
        if (!replaced) try entries.append(.{ .key = key, .value = value });
    }

    const owned = try entries.toOwnedSlice();
    std.mem.sort(QueryParam, owned, {}, queryParamLessThan);
    return .{ .entries = owned };
}

fn queryParamLessThan(_: void, lhs: QueryParam, rhs: QueryParam) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "PKCE state from seed matches SHA256 challenge shape" {
    const verifier_seed = [_]u8{0x11} ** 64;
    const state_seed = [_]u8{0x22} ** 32;

    var pkce = try pkceStateFromSeed(std.testing.allocator, &verifier_seed, &state_seed);
    defer pkce.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "EREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREQ",
        pkce.code_verifier,
    );
    try std.testing.expectEqualStrings("IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIi", pkce.state);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pkce.code_verifier, &digest, .{});
    const expected_challenge = try base64UrlNoPad(std.testing.allocator, &digest);
    defer std.testing.allocator.free(expected_challenge);
    try std.testing.expectEqualStrings(expected_challenge, pkce.code_challenge);
}

test "URL encode and decode preserve Rust quirks" {
    const encoded = try urlEncode(std.testing.allocator, "hello world+a=b&snowman=☃");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("hello%20world%2Ba%3Db%26snowman%3D%E2%98%83", encoded);

    const decoded = try urlDecode(std.testing.allocator, "hello+world%2Bbad%25zz");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello world+bad%zz", decoded);
}

test "parseQueryParams sorts keys and keeps final duplicate" {
    var params = try parseQueryParams(std.testing.allocator, "z=last&a=1&z=final&space=hello+world");
    defer params.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), params.entries.len);
    try std.testing.expectEqualStrings("a", params.entries[0].key);
    try std.testing.expectEqualStrings("space", params.entries[1].key);
    try std.testing.expectEqualStrings("z", params.entries[2].key);
    try std.testing.expectEqualStrings("final", params.get("z").?);
    try std.testing.expectEqualStrings("hello world", params.get("space").?);
}
