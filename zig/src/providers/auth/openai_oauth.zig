const std = @import("std");
const oauth_common = @import("oauth_common.zig");
const types = @import("types.zig");

pub const PkceState = oauth_common.PkceState;
pub const DeviceCodeStart = types.DeviceCodeStart;
pub const TokenSet = types.TokenSet;
pub const TokenResponseForEval = types.TokenResponseForEval;
pub const OAuthErrorResponse = types.OAuthErrorResponse;

pub const OPENAI_OAUTH_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const OPENAI_OAUTH_AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
pub const OPENAI_OAUTH_TOKEN_URL = "https://auth.openai.com/oauth/token";
pub const OPENAI_OAUTH_DEVICE_CODE_URL = "https://auth.openai.com/oauth/device/code";
pub const OPENAI_OAUTH_REDIRECT_URI = "http://localhost:1455/auth/callback";
pub const OPENAI_OAUTH_SCOPE = "openid profile email offline_access";

pub const RedirectParseResult = union(enum) {
    code: []u8,
    err: []u8,

    pub fn deinit(self: *RedirectParseResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .code => |value| allocator.free(value),
            .err => |value| allocator.free(value),
        }
        self.* = undefined;
    }
};

const Pair = struct {
    key: []const u8,
    value: []const u8,
};

pub fn buildAuthorizeUrl(allocator: std.mem.Allocator, pkce: PkceState) ![]u8 {
    const query = try buildFormBody(allocator, &.{
        .{ .key = "client_id", .value = OPENAI_OAUTH_CLIENT_ID },
        .{ .key = "code_challenge", .value = pkce.code_challenge },
        .{ .key = "code_challenge_method", .value = "S256" },
        .{ .key = "codex_cli_simplified_flow", .value = "true" },
        .{ .key = "id_token_add_organizations", .value = "true" },
        .{ .key = "redirect_uri", .value = OPENAI_OAUTH_REDIRECT_URI },
        .{ .key = "response_type", .value = "code" },
        .{ .key = "scope", .value = OPENAI_OAUTH_SCOPE },
        .{ .key = "state", .value = pkce.state },
    });
    defer allocator.free(query);

    return try std.fmt.allocPrint(allocator, "{s}?{s}", .{ OPENAI_OAUTH_AUTHORIZE_URL, query });
}

pub fn buildTokenRequestBodyAuthorizationCode(
    allocator: std.mem.Allocator,
    code: []const u8,
    pkce: PkceState,
) ![]u8 {
    return buildFormBody(allocator, &.{
        .{ .key = "grant_type", .value = "authorization_code" },
        .{ .key = "code", .value = code },
        .{ .key = "client_id", .value = OPENAI_OAUTH_CLIENT_ID },
        .{ .key = "redirect_uri", .value = OPENAI_OAUTH_REDIRECT_URI },
        .{ .key = "code_verifier", .value = pkce.code_verifier },
    });
}

pub fn buildTokenRequestBodyRefreshToken(
    allocator: std.mem.Allocator,
    refresh_token: []const u8,
) ![]u8 {
    return buildFormBody(allocator, &.{
        .{ .key = "grant_type", .value = "refresh_token" },
        .{ .key = "refresh_token", .value = refresh_token },
        .{ .key = "client_id", .value = OPENAI_OAUTH_CLIENT_ID },
    });
}

pub fn buildDeviceCodeRequestBody(allocator: std.mem.Allocator) ![]u8 {
    return buildFormBody(allocator, &.{
        .{ .key = "client_id", .value = OPENAI_OAUTH_CLIENT_ID },
        .{ .key = "scope", .value = OPENAI_OAUTH_SCOPE },
    });
}

pub fn buildDeviceCodePollBody(allocator: std.mem.Allocator, device_code: []const u8) ![]u8 {
    return buildFormBody(allocator, &.{
        .{ .key = "grant_type", .value = "urn:ietf:params:oauth:grant-type:device_code" },
        .{ .key = "device_code", .value = device_code },
        .{ .key = "client_id", .value = OPENAI_OAUTH_CLIENT_ID },
    });
}

pub fn parseTokenResponseBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    now_unix_seconds: i64,
) !TokenSet {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const access_token = try requiredStringDup(allocator, root, "access_token");
    errdefer allocator.free(access_token);
    const refresh_token = try optionalStringDup(allocator, root, "refresh_token");
    errdefer if (refresh_token) |value| allocator.free(value);
    const id_token = try optionalStringDup(allocator, root, "id_token");
    errdefer if (id_token) |value| allocator.free(value);
    const token_type = try optionalStringDup(allocator, root, "token_type");
    errdefer if (token_type) |value| allocator.free(value);
    const scope = try optionalStringDup(allocator, root, "scope");
    errdefer if (scope) |value| allocator.free(value);

    const expires_at_utc_seconds = if (optionalI64(root, "expires_in")) |seconds| blk: {
        if (seconds <= 0) break :blk null;
        break :blk try std.math.add(i64, now_unix_seconds, seconds);
    } else null;

    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .id_token = id_token,
        .expires_at_utc_seconds = expires_at_utc_seconds,
        .token_type = token_type,
        .scope = scope,
    };
}

pub fn parseTokenResponseBodyForEval(
    allocator: std.mem.Allocator,
    body: []const u8,
) !TokenResponseForEval {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const access_token = try requiredStringDup(allocator, root, "access_token");
    errdefer allocator.free(access_token);
    const refresh_token = try optionalStringDup(allocator, root, "refresh_token");
    errdefer if (refresh_token) |value| allocator.free(value);
    const id_token = try optionalStringDup(allocator, root, "id_token");
    errdefer if (id_token) |value| allocator.free(value);
    const token_type = try optionalStringDup(allocator, root, "token_type");
    errdefer if (token_type) |value| allocator.free(value);
    const scope = try optionalStringDup(allocator, root, "scope");
    errdefer if (scope) |value| allocator.free(value);

    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .id_token = id_token,
        .expires_in_seconds = optionalI64(root, "expires_in"),
        .token_type = token_type,
        .scope = scope,
    };
}

pub fn parseDeviceCodeResponseBody(
    allocator: std.mem.Allocator,
    body: []const u8,
) !DeviceCodeStart {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const device_code = try requiredStringDup(allocator, root, "device_code");
    errdefer allocator.free(device_code);
    const user_code = try requiredStringDup(allocator, root, "user_code");
    errdefer allocator.free(user_code);
    const verification_uri = try requiredStringDup(allocator, root, "verification_uri");
    errdefer allocator.free(verification_uri);
    const verification_uri_complete = try optionalStringDup(allocator, root, "verification_uri_complete");
    errdefer if (verification_uri_complete) |value| allocator.free(value);
    const message = try optionalStringDup(allocator, root, "message");
    errdefer if (message) |value| allocator.free(value);

    const expires_in = requiredU64(root, "expires_in") orelse return error.InvalidJson;
    const raw_interval = optionalU64(root, "interval") orelse 5;

    return .{
        .device_code = device_code,
        .user_code = user_code,
        .verification_uri = verification_uri,
        .verification_uri_complete = verification_uri_complete,
        .expires_in = expires_in,
        .interval = @max(raw_interval, 1),
        .message = message,
    };
}

pub fn parseOAuthErrorBody(allocator: std.mem.Allocator, body: []const u8) !OAuthErrorResponse {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const err = try requiredStringDup(allocator, parsed.value, "error");
    errdefer allocator.free(err);
    const description = try optionalStringDup(allocator, parsed.value, "error_description");
    errdefer if (description) |value| allocator.free(value);

    return .{ .err = err, .error_description = description };
}

pub fn parseCodeFromRedirect(
    allocator: std.mem.Allocator,
    input: []const u8,
    expected_state: ?[]const u8,
) ![]u8 {
    const result = try parseCodeFromRedirectResult(allocator, input, expected_state);
    switch (result) {
        .code => |code| return code,
        .err => |message| {
            allocator.free(message);
            return error.InvalidOAuthRedirect;
        },
    }
}

pub fn parseCodeFromRedirectResult(
    allocator: std.mem.Allocator,
    input: []const u8,
    expected_state: ?[]const u8,
) !RedirectParseResult {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        return .{ .err = try allocator.dupe(u8, "No OAuth code provided") };
    }

    const query = if (std.mem.indexOfScalar(u8, trimmed, '?')) |idx| trimmed[idx + 1 ..] else trimmed;
    var params = try oauth_common.parseQueryParams(allocator, query);
    defer params.deinit(allocator);

    const is_callback_payload = std.mem.indexOfScalar(u8, trimmed, '?') != null or
        params.contains("code") or
        params.contains("state") or
        params.contains("error");

    if (params.get("error")) |err| {
        const desc = params.get("error_description") orelse "OAuth authorization failed";
        return .{ .err = try std.fmt.allocPrint(
            allocator,
            "OpenAI OAuth error: {s} ({s})",
            .{ err, desc },
        ) };
    }

    if (expected_state) |expected| {
        if (params.get("state")) |got| {
            if (!std.mem.eql(u8, got, expected)) {
                return .{ .err = try allocator.dupe(u8, "OAuth state mismatch") };
            }
        } else if (is_callback_payload) {
            return .{ .err = try allocator.dupe(u8, "Missing OAuth state in callback") };
        }
    }

    if (params.get("code")) |code| {
        return .{ .code = try allocator.dupe(u8, code) };
    }

    if (!is_callback_payload) {
        return .{ .code = try allocator.dupe(u8, trimmed) };
    }

    return .{ .err = try allocator.dupe(u8, "Missing OAuth code in callback") };
}

pub fn extractAccountIdFromJwt(allocator: std.mem.Allocator, token: []const u8) !?[]u8 {
    const payload = jwtPayloadSegment(token) orelse return null;
    const decoded = oauth_common.decodeBase64UrlNoPad(allocator, payload) catch return null;
    defer allocator.free(decoded);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return null;
    defer parsed.deinit();

    const keys = [_][]const u8{
        "account_id",
        "accountId",
        "acct",
        "sub",
        "https://api.openai.com/account_id",
    };
    for (keys) |key| {
        if (getObjectString(parsed.value, key)) |value| {
            if (std.mem.trim(u8, value, " \t\r\n").len != 0) {
                return try allocator.dupe(u8, value);
            }
        }
    }

    return null;
}

pub fn extractExpiryFromJwt(allocator: std.mem.Allocator, token: []const u8) !?i64 {
    const payload = jwtPayloadSegment(token) orelse return null;
    const decoded = oauth_common.decodeBase64UrlNoPad(allocator, payload) catch return null;
    defer allocator.free(decoded);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return null;
    defer parsed.deinit();

    return getObjectI64(parsed.value, "exp");
}

fn buildFormBody(allocator: std.mem.Allocator, pairs: []const Pair) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    for (pairs, 0..) |pair, i| {
        if (i != 0) try out.append('&');

        const key = try oauth_common.urlEncode(allocator, pair.key);
        defer allocator.free(key);
        const value = try oauth_common.urlEncode(allocator, pair.value);
        defer allocator.free(value);

        try out.appendSlice(key);
        try out.append('=');
        try out.appendSlice(value);
    }

    return try out.toOwnedSlice();
}

fn jwtPayloadSegment(token: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return null;
    return parts.next();
}

fn getObjectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getObjectField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn requiredStringDup(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]u8 {
    const raw = getObjectString(value, key) orelse return error.InvalidJson;
    return try allocator.dupe(u8, raw);
}

fn optionalStringDup(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) !?[]u8 {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .null => null,
        .string => |inner| try allocator.dupe(u8, inner),
        else => error.InvalidJson,
    };
}

fn requiredU64(value: std.json.Value, key: []const u8) ?u64 {
    return optionalU64(value, key);
}

fn optionalU64(value: std.json.Value, key: []const u8) ?u64 {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .integer => |inner| if (inner >= 0) @intCast(inner) else null,
        else => null,
    };
}

fn optionalI64(value: std.json.Value, key: []const u8) ?i64 {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .integer => |inner| inner,
        else => null,
    };
}

fn getObjectI64(value: std.json.Value, key: []const u8) ?i64 {
    return optionalI64(value, key);
}

test "authorize URL uses Rust BTreeMap key order" {
    var pkce = PkceState{
        .code_verifier = try std.testing.allocator.dupe(u8, "verifier"),
        .code_challenge = try std.testing.allocator.dupe(u8, "challenge"),
        .state = try std.testing.allocator.dupe(u8, "state"),
    };
    defer pkce.deinit(std.testing.allocator);

    const url = try buildAuthorizeUrl(std.testing.allocator, pkce);
    defer std.testing.allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://auth.openai.com/oauth/authorize?client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_challenge=challenge&code_challenge_method=S256&codex_cli_simplified_flow=true&id_token_add_organizations=true&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&response_type=code&scope=openid%20profile%20email%20offline_access&state=state",
        url,
    );
}

test "token request bodies preserve declaration order" {
    var pkce = PkceState{
        .code_verifier = try std.testing.allocator.dupe(u8, "verifier+space value"),
        .code_challenge = try std.testing.allocator.dupe(u8, "challenge"),
        .state = try std.testing.allocator.dupe(u8, "state"),
    };
    defer pkce.deinit(std.testing.allocator);

    const body = try buildTokenRequestBodyAuthorizationCode(std.testing.allocator, "code=1", pkce);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "grant_type=authorization_code&code=code%3D1&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&code_verifier=verifier%2Bspace%20value",
        body,
    );
}

test "parseCodeFromRedirect preserves error precedence and state check" {
    var err_result = try parseCodeFromRedirectResult(
        std.testing.allocator,
        "/auth/callback?code=x&error=access_denied&error_description=user+cancelled&state=wrong",
        "expected",
    );
    defer err_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "OpenAI OAuth error: access_denied (user cancelled)",
        err_result.err,
    );

    var mismatch = try parseCodeFromRedirectResult(
        std.testing.allocator,
        "/auth/callback?code=x&state=wrong",
        "expected",
    );
    defer mismatch.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("OAuth state mismatch", mismatch.err);

    const code = try parseCodeFromRedirect(std.testing.allocator, "raw-code", null);
    defer std.testing.allocator.free(code);
    try std.testing.expectEqualStrings("raw-code", code);
}

test "parse token and device-code responses" {
    var token = try parseTokenResponseBody(std.testing.allocator, "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_in\":60,\"token_type\":\"Bearer\"}", 1000);
    defer token.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a", token.access_token);
    try std.testing.expectEqualStrings("r", token.refresh_token.?);
    try std.testing.expectEqual(@as(?i64, 1060), token.expires_at_utc_seconds);

    var device = try parseDeviceCodeResponseBody(std.testing.allocator, "{\"device_code\":\"dev\",\"user_code\":\"user\",\"verification_uri\":\"https://example.test\",\"expires_in\":900,\"interval\":0}");
    defer device.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dev", device.device_code);
    try std.testing.expectEqual(@as(u64, 1), device.interval);
}

test "JWT extractors read payload segment only" {
    const header = try oauth_common.base64UrlNoPad(std.testing.allocator, "{}");
    defer std.testing.allocator.free(header);
    const payload = try oauth_common.base64UrlNoPad(std.testing.allocator, "{\"sub\":\"acct_sub\",\"exp\":1710000000}");
    defer std.testing.allocator.free(payload);
    const token = try std.fmt.allocPrint(std.testing.allocator, "{s}.{s}.sig", .{ header, payload });
    defer std.testing.allocator.free(token);

    const account = try extractAccountIdFromJwt(std.testing.allocator, token);
    defer std.testing.allocator.free(account.?);
    try std.testing.expectEqualStrings("acct_sub", account.?);

    try std.testing.expectEqual(@as(?i64, 1710000000), try extractExpiryFromJwt(std.testing.allocator, token));
}
