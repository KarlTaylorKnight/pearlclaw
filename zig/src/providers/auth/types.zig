const std = @import("std");

pub const TokenSet = struct {
    access_token: []u8,
    refresh_token: ?[]u8 = null,
    id_token: ?[]u8 = null,
    expires_at_utc_seconds: ?i64 = null,
    token_type: ?[]u8 = null,
    scope: ?[]u8 = null,

    pub fn deinit(self: *TokenSet, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        if (self.refresh_token) |value| allocator.free(value);
        if (self.id_token) |value| allocator.free(value);
        if (self.token_type) |value| allocator.free(value);
        if (self.scope) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const TokenResponseForEval = struct {
    access_token: []u8,
    refresh_token: ?[]u8 = null,
    id_token: ?[]u8 = null,
    expires_in_seconds: ?i64 = null,
    token_type: ?[]u8 = null,
    scope: ?[]u8 = null,

    pub fn deinit(self: *TokenResponseForEval, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        if (self.refresh_token) |value| allocator.free(value);
        if (self.id_token) |value| allocator.free(value);
        if (self.token_type) |value| allocator.free(value);
        if (self.scope) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const DeviceCodeStart = struct {
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    verification_uri_complete: ?[]u8 = null,
    expires_in: u64,
    interval: u64,
    message: ?[]u8 = null,

    pub fn deinit(self: *DeviceCodeStart, allocator: std.mem.Allocator) void {
        allocator.free(self.device_code);
        allocator.free(self.user_code);
        allocator.free(self.verification_uri);
        if (self.verification_uri_complete) |value| allocator.free(value);
        if (self.message) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const OAuthErrorResponse = struct {
    err: []u8,
    error_description: ?[]u8 = null,

    pub fn deinit(self: *OAuthErrorResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.err);
        if (self.error_description) |value| allocator.free(value);
        self.* = undefined;
    }
};

test "TokenSet owns optional fields" {
    var token = TokenSet{
        .access_token = try std.testing.allocator.dupe(u8, "access"),
        .refresh_token = try std.testing.allocator.dupe(u8, "refresh"),
        .id_token = null,
        .expires_at_utc_seconds = 123,
        .token_type = try std.testing.allocator.dupe(u8, "Bearer"),
        .scope = null,
    };
    defer token.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("access", token.access_token);
    try std.testing.expectEqual(@as(?i64, 123), token.expires_at_utc_seconds);
}
