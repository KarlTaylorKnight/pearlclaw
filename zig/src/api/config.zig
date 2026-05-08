const std = @import("std");

pub const AuthConfig = struct {
    state_dir: []const u8,
    encrypt_secrets: bool,

    pub fn fromZeroclawDir(zeroclaw_dir: []const u8, encrypt_secrets: bool) AuthConfig {
        return .{ .state_dir = zeroclaw_dir, .encrypt_secrets = encrypt_secrets };
    }
};

pub fn stateDirFromConfig(allocator: std.mem.Allocator, config: AuthConfig) ![]u8 {
    return allocator.dupe(u8, config.state_dir);
}

test "AuthConfig duplicates state dir for callers" {
    const config = AuthConfig.fromZeroclawDir("/tmp/zeroclaw", true);
    const state_dir = try stateDirFromConfig(std.testing.allocator, config);
    defer std.testing.allocator.free(state_dir);

    try std.testing.expectEqualStrings("/tmp/zeroclaw", state_dir);
}
