//! MemoryRecallTool port for searching long-term memories.

const std = @import("std");
const common = @import("memory_common.zig");
const memory = @import("../memory/root.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "memory_recall";
const DESCRIPTION =
    "Retrieve matching long-term memories by query, category, tags, limit, or recent age. The memory backend is borrowed by the tool and remains owned by the caller.";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "properties": {
    \\    "category": { "type": "string" },
    \\    "limit": { "type": "integer" },
    \\    "query": { "type": "string" },
    \\    "since_days": { "type": "integer" },
    \\    "tags": {
    \\      "items": { "type": "string" },
    \\      "type": "array"
    \\    }
    \\  },
    \\  "type": "object"
    \\}
;

/// Recalls memories through a borrowed `SqliteMemory`.
/// The caller owns the memory backend; `deinit` must not free it.
pub const MemoryRecallTool = struct {
    memory_backend: *memory.SqliteMemory,

    pub fn init(_: std.mem.Allocator, memory_backend: *memory.SqliteMemory) MemoryRecallTool {
        return .{ .memory_backend = memory_backend };
    }

    pub fn deinit(_: *MemoryRecallTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *MemoryRecallTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable: Tool.VTable = .{
        .name = nameImpl,
        .description = descriptionImpl,
        .parametersSchema = parametersSchemaImpl,
        .execute = executeImpl,
        .deinit = deinitImpl,
    };

    fn nameImpl(_: *anyopaque) []const u8 {
        return NAME;
    }

    fn descriptionImpl(_: *anyopaque) []const u8 {
        return DESCRIPTION;
    }

    fn parametersSchemaImpl(_: *anyopaque, allocator: std.mem.Allocator) anyerror!std.json.Value {
        return parametersSchema(allocator);
    }

    fn executeImpl(ptr: *anyopaque, allocator: std.mem.Allocator, args: std.json.Value) anyerror!ToolResult {
        const self: *MemoryRecallTool = @ptrCast(@alignCast(ptr));
        return common.resultFromReturn(allocator, try self.dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *MemoryRecallTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }

    fn dispatch(self: *MemoryRecallTool, allocator: std.mem.Allocator, args: std.json.Value) !common.MemoryReturn {
        var reader = common.JsonArgs{ .allocator = allocator, .value = args };
        defer reader.deinit();

        const query = reader.optionalString("query") orelse "";
        const category_str = reader.optionalString("category");
        const tags = reader.optionalTags() catch |err| return common.invalidResult(&reader, err);
        defer allocator.free(tags);
        const limit_i = reader.optionalInteger("limit") orelse 5;
        if (limit_i < 0) return common.failure(allocator, "limit must be non-negative");
        const limit: usize = @intCast(limit_i);
        const fetch_limit = @max(limit, @as(usize, 1000));

        var since: ?[]u8 = null;
        if (reader.optionalInteger("since_days")) |days| {
            since = common.timestampDaysAgo(allocator, days) catch |err| {
                if (err == error.InvalidArgument) return common.failure(allocator, "since_days must be non-negative");
                return err;
            };
        }
        defer if (since) |value| allocator.free(value);

        var category: ?memory.MemoryCategory = null;
        if (category_str) |raw| {
            category = try common.categoryFromString(allocator, raw);
        }
        defer if (category) |*cat| cat.deinit(allocator);

        const entries = if (std.mem.trim(u8, query, " \t\r\n").len == 0)
            try self.memory_backend.exportEntries(allocator, .{
                .category = category,
                .since = since,
            })
        else
            try self.memory_backend.recall(allocator, query, fetch_limit, null, since, null);
        defer memory.sqlite.freeEntries(allocator, entries);

        sortEntriesDesc(entries);
        return .{ .output = try formatRecall(allocator, self.memory_backend, entries, category_str, tags, limit) };
    }
};

fn sortEntriesDesc(entries: []memory.MemoryEntry) void {
    std.sort.heap(memory.MemoryEntry, entries, {}, struct {
        fn lessThan(_: void, lhs: memory.MemoryEntry, rhs: memory.MemoryEntry) bool {
            return std.mem.order(u8, lhs.timestamp, rhs.timestamp) == .gt;
        }
    }.lessThan);
}

fn formatRecall(
    allocator: std.mem.Allocator,
    memory_backend: *memory.SqliteMemory,
    entries: []const memory.MemoryEntry,
    category_filter: ?[]const u8,
    tags_filter: []const []const u8,
    limit: usize,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var count: usize = 0;
    for (entries) |entry| {
        if (count >= limit) break;
        if (category_filter) |category| {
            if (!std.mem.eql(u8, entry.category.asString(), category)) continue;
        }

        var metadata = try memory_backend.getToolMetadata(allocator, entry.key);
        defer metadata.deinit(allocator);
        if (!common.tagsContainAll(metadata.tags, tags_filter)) continue;

        if (count == 0) {
            try out.appendSlice("content | category | tags | created_at\n");
        }

        const tag_list = try common.formatTagList(allocator, metadata.tags);
        defer allocator.free(tag_list);
        try out.writer().print("{s} | {s} | {s} | {s}\n", .{
            entry.content,
            entry.category.asString(),
            tag_list,
            entry.timestamp,
        });
        count += 1;
    }

    if (count == 0) return allocator.dupe(u8, "No memories found.");
    return out.toOwnedSlice();
}

fn parseArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

fn tempMemory() !struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    mem: memory.SqliteMemory,
} {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "memory.db" });
    errdefer std.testing.allocator.free(path);
    var mem = try memory.SqliteMemory.newAtPath(std.testing.allocator, path);
    errdefer mem.deinit();
    return .{ .tmp = tmp, .path = path, .mem = mem };
}

fn seed(
    mem: *memory.SqliteMemory,
    content: []const u8,
    category_name: []const u8,
    timestamp: []const u8,
    tags: []const []const u8,
) ![]u8 {
    const hash = try memory.contentHash(std.testing.allocator, content);
    var category = try memory.MemoryCategory.fromString(std.testing.allocator, category_name);
    defer category.deinit(std.testing.allocator);
    try mem.storeWithMetadata(std.testing.allocator, hash, content, category, null, null, null);
    try mem.setToolMetadata(std.testing.allocator, hash, tags, null);
    try mem.setEntryTimestampForEval(hash, timestamp);
    return hash;
}

test "memory_recall filters by category and tags and sorts newest first" {
    var fixture = try tempMemory();
    defer fixture.mem.deinit();
    defer std.testing.allocator.free(fixture.path);
    defer fixture.tmp.cleanup();

    const tags_project = [_][]const u8{"zig"};
    const tags_other = [_][]const u8{"rust"};
    const h1 = try seed(&fixture.mem, "Old Zig note", "project", "2026-05-01T00:00:00Z", &tags_project);
    defer std.testing.allocator.free(h1);
    const h2 = try seed(&fixture.mem, "New Zig memory", "project", "2026-05-03T00:00:00Z", &tags_project);
    defer std.testing.allocator.free(h2);
    const h3 = try seed(&fixture.mem, "Rust note", "project", "2026-05-02T00:00:00Z", &tags_other);
    defer std.testing.allocator.free(h3);

    var parsed = try parseArgs(std.testing.allocator, "{\"category\":\"project\",\"tags\":[\"zig\"],\"limit\":5}");
    defer parsed.deinit();
    var tool_impl = MemoryRecallTool.init(std.testing.allocator, &fixture.mem);
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(std.testing.allocator, parsed.value);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "New Zig memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Old Zig note") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Rust note") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "New Zig memory").? <
        std.mem.indexOf(u8, result.output, "Old Zig note").?);
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var fixture = try tempMemory();
    defer fixture.mem.deinit();
    defer std.testing.allocator.free(fixture.path);
    defer fixture.tmp.cleanup();

    const tags = [_][]const u8{"zig"};
    const hash = try seed(&fixture.mem, "OOM recall", "project", "2026-05-01T00:00:00Z", &tags);
    defer std.testing.allocator.free(hash);

    var parsed = try parseArgs(std.testing.allocator, "{\"query\":\"OOM\",\"limit\":1}");
    defer parsed.deinit();
    var tool_impl = MemoryRecallTool.init(std.testing.allocator, &fixture.mem);
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    var fixture = try tempMemory();
    defer fixture.mem.deinit();
    defer std.testing.allocator.free(fixture.path);
    defer fixture.tmp.cleanup();

    var parsed = try parseArgs(std.testing.allocator, "{\"tags\":\"zig\"}");
    defer parsed.deinit();
    var tool_impl = MemoryRecallTool.init(std.testing.allocator, &fixture.mem);
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "memory_recall execute is OOM safe for success and validation errors" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
}
