//! MemoryPurgeTool port for bulk deleting filtered memories.

const std = @import("std");
const common = @import("memory_common.zig");
const memory = @import("../memory/root.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "memory_purge";
const DESCRIPTION =
    "Delete memories by category, age, or tags after explicit confirmation. The memory backend is borrowed by the tool and remains owned by the caller.";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "properties": {
    \\    "category": { "type": "string" },
    \\    "confirm": { "type": "boolean" },
    \\    "older_than_days": { "type": "integer" },
    \\    "tags": {
    \\      "items": { "type": "string" },
    \\      "type": "array"
    \\    }
    \\  },
    \\  "required": ["confirm"],
    \\  "type": "object"
    \\}
;

/// Purges memories through a borrowed `SqliteMemory`.
/// The caller owns the memory backend; `deinit` must not free it.
pub const MemoryPurgeTool = struct {
    memory_backend: *memory.SqliteMemory,

    pub fn init(_: std.mem.Allocator, memory_backend: *memory.SqliteMemory) MemoryPurgeTool {
        return .{ .memory_backend = memory_backend };
    }

    pub fn deinit(_: *MemoryPurgeTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *MemoryPurgeTool) Tool {
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
        const self: *MemoryPurgeTool = @ptrCast(@alignCast(ptr));
        return common.resultFromReturn(allocator, try self.dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *MemoryPurgeTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }

    fn dispatch(self: *MemoryPurgeTool, allocator: std.mem.Allocator, args: std.json.Value) !common.MemoryReturn {
        var reader = common.JsonArgs{ .allocator = allocator, .value = args };
        defer reader.deinit();

        const confirm = reader.requiredBool("confirm") catch |err| return common.invalidResult(&reader, err);
        if (!confirm) return common.failure(allocator, "confirm:true required");

        const category_str = reader.optionalString("category");
        const older_than_days = reader.optionalInteger("older_than_days");
        const tags = reader.optionalTags() catch |err| return common.invalidResult(&reader, err);
        defer allocator.free(tags);
        if (category_str == null and older_than_days == null and tags.len == 0) {
            return common.failure(allocator, "At least one purge filter required");
        }

        var cutoff: ?[]u8 = null;
        if (older_than_days) |days| {
            cutoff = common.timestampDaysAgo(allocator, days) catch |err| {
                if (err == error.InvalidArgument) return common.failure(allocator, "older_than_days must be non-negative");
                return err;
            };
        }
        defer if (cutoff) |value| allocator.free(value);

        var category: ?memory.MemoryCategory = null;
        if (category_str) |raw| category = try common.categoryFromString(allocator, raw);
        defer if (category) |*cat| cat.deinit(allocator);

        const entries = try self.memory_backend.exportEntries(allocator, .{ .category = category });
        defer memory.sqlite.freeEntries(allocator, entries);

        var deleted: usize = 0;
        for (entries) |entry| {
            if (cutoff) |value| {
                if (std.mem.order(u8, entry.timestamp, value) != .lt) continue;
            }

            var metadata = try self.memory_backend.getToolMetadata(allocator, entry.key);
            defer metadata.deinit(allocator);
            if (!common.tagsContainAll(metadata.tags, tags)) continue;

            if (try self.memory_backend.forget(entry.key)) {
                // Tolerate a metadata-delete failure: the primary row is gone
                // and an orphaned metadata row is harmless (queried by key only,
                // returns empty tags on miss). A transient SQLite error here
                // would otherwise abort the whole purge mid-batch. Mirrors the
                // Rust eval runner's tolerance for the same failure mode.
                self.memory_backend.deleteToolMetadata(entry.key) catch {};
                deleted += 1;
            }
        }

        return .{ .output = try std.fmt.allocPrint(allocator, "Purged {d} memories", .{deleted}) };
    }
};

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

test "memory_purge deletes category entries only when confirmed" {
    var fixture = try tempMemory();
    defer fixture.mem.deinit();
    defer std.testing.allocator.free(fixture.path);
    defer fixture.tmp.cleanup();

    const tags = [_][]const u8{"cleanup"};
    const h1 = try seed(&fixture.mem, "Delete me", "project", "2020-01-01T00:00:00Z", &tags);
    defer std.testing.allocator.free(h1);
    const h2 = try seed(&fixture.mem, "Keep me", "core", "2020-01-01T00:00:00Z", &tags);
    defer std.testing.allocator.free(h2);

    var parsed = try parseArgs(std.testing.allocator, "{\"category\":\"project\",\"confirm\":true}");
    defer parsed.deinit();
    var tool_impl = MemoryPurgeTool.init(std.testing.allocator, &fixture.mem);
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(std.testing.allocator, parsed.value);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("Purged 1 memories", result.output);
    try std.testing.expectEqual(@as(usize, 1), try fixture.mem.count());
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var fixture = try tempMemory();
    defer fixture.mem.deinit();
    defer std.testing.allocator.free(fixture.path);
    defer fixture.tmp.cleanup();

    const tags = [_][]const u8{"cleanup"};
    const hash = try seed(&fixture.mem, "OOM purge", "project", "2020-01-01T00:00:00Z", &tags);
    defer std.testing.allocator.free(hash);

    var parsed = try parseArgs(std.testing.allocator, "{\"category\":\"project\",\"confirm\":true}");
    defer parsed.deinit();
    var tool_impl = MemoryPurgeTool.init(std.testing.allocator, &fixture.mem);
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

    var parsed = try parseArgs(std.testing.allocator, "{\"category\":\"project\",\"confirm\":false}");
    defer parsed.deinit();
    var tool_impl = MemoryPurgeTool.init(std.testing.allocator, &fixture.mem);
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    var value = try MemoryPurgeTool.parametersSchema(allocator);
    defer @import("../tool_call_parser/types.zig").freeJsonValue(allocator, &value);
}

test "memory_purge execute and parametersSchema are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}
