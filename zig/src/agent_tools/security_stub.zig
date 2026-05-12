//! Minimal SecurityPolicy stand-in for Phase 7 filesystem-adjacent tools.
//!
//! TODO(SecurityPolicy port): replace this shim once the Rust SecurityPolicy
//! surface exists in Zig.

const std = @import("std");
const common = @import("fs_common.zig");

pub const SecurityStub = struct {
    workspace_dir: []const u8,
    rate_limited: bool = false,
    action_budget: i64 = std.math.maxInt(i64),
    allow_absolute_under_root: bool = false,
    allow_resolved_outside_workspace: bool = false,
    extra_blocked_paths: []const []const u8 = &.{},

    pub fn isRateLimited(self: *const SecurityStub) bool {
        return self.rate_limited;
    }

    pub fn recordAction(self: *SecurityStub) bool {
        if (self.action_budget <= 0) return false;
        self.action_budget -= 1;
        return true;
    }

    pub fn isUnderAllowedRoot(self: *const SecurityStub, path: []const u8) bool {
        return self.allow_absolute_under_root and std.mem.startsWith(u8, path, self.workspace_dir);
    }

    pub fn isPathAllowed(self: *const SecurityStub, path: []const u8) bool {
        for (self.extra_blocked_paths) |blocked| {
            if (std.mem.eql(u8, path, blocked)) return false;
        }
        return true;
    }

    pub fn resolveToolPath(self: *const SecurityStub, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const expanded = try common.expandTilde(allocator, path);
        errdefer allocator.free(expanded);
        if (std.fs.path.isAbsolute(expanded)) return expanded;
        const joined = try std.fs.path.join(allocator, &.{ self.workspace_dir, expanded });
        allocator.free(expanded);
        return joined;
    }

    pub fn isResolvedPathAllowed(self: *const SecurityStub, resolved: []const u8) bool {
        return self.allow_resolved_outside_workspace or std.mem.startsWith(u8, resolved, self.workspace_dir);
    }
};
