const std = @import("std");

pub const MemoryError = error{
    Sqlite,
    InvalidInput,
    OutOfMemory,
};

pub const MemoryCategory = union(enum) {
    core,
    daily,
    conversation,
    custom: []u8,

    pub fn fromString(allocator: std.mem.Allocator, value: []const u8) !MemoryCategory {
        if (std.mem.eql(u8, value, "core")) return .core;
        if (std.mem.eql(u8, value, "daily")) return .daily;
        if (std.mem.eql(u8, value, "conversation")) return .conversation;
        return .{ .custom = try allocator.dupe(u8, value) };
    }

    pub fn deinit(self: *MemoryCategory, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .custom => |value| allocator.free(value),
            else => {},
        }
        self.* = undefined;
    }

    pub fn asString(self: MemoryCategory) []const u8 {
        return switch (self) {
            .core => "core",
            .daily => "daily",
            .conversation => "conversation",
            .custom => |value| value,
        };
    }

    pub fn clone(self: MemoryCategory, allocator: std.mem.Allocator) !MemoryCategory {
        return switch (self) {
            .core => .core,
            .daily => .daily,
            .conversation => .conversation,
            .custom => |value| .{ .custom = try allocator.dupe(u8, value) },
        };
    }
};

pub const MemoryEntry = struct {
    id: []u8,
    key: []u8,
    content: []u8,
    category: MemoryCategory,
    timestamp: []u8,
    session_id: ?[]u8,
    score: ?f64,
    namespace: []u8,
    importance: ?f64,
    superseded_by: ?[]u8,

    pub fn deinit(self: *MemoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.key);
        allocator.free(self.content);
        self.category.deinit(allocator);
        allocator.free(self.timestamp);
        if (self.session_id) |value| allocator.free(value);
        allocator.free(self.namespace);
        if (self.superseded_by) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ExportFilter = struct {
    namespace: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    category: ?MemoryCategory = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,

    pub fn deinit(self: *ExportFilter, allocator: std.mem.Allocator) void {
        if (self.category) |*category| category.deinit(allocator);
    }
};

pub const ProceduralMessage = struct {
    role: []const u8,
    content: []const u8,
    name: ?[]const u8 = null,
};
