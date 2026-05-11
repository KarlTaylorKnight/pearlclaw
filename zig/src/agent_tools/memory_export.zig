//! MemoryExportTool port for JSON or markdown exports.

const std = @import("std");
const common = @import("memory_common.zig");
const memory = @import("../memory/root.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "memory_export";
const DESCRIPTION =
    "Export long-term memories as JSON or markdown. The memory backend is borrowed by the tool and remains owned by the caller.";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "properties": {
    \\    "category": { "type": "string" },
    \\    "format": {
    \\      "enum": ["json", "markdown"],
    \\      "type": "string"
    \\    },
    \\    "since_days": { "type": "integer" }
    \\  },
    \\  "required": ["format"],
    \\  "type": "object"
    \\}
;

/// Exports memories through a borrowed `SqliteMemory`.
/// The caller owns the memory backend; `deinit` must not free it.
pub const MemoryExportTool = struct {
    memory_backend: *memory.SqliteMemory,

    pub fn init(_: std.mem.Allocator, memory_backend: *memory.SqliteMemory) MemoryExportTool {
        return .{ .memory_backend = memory_backend };
    }

    pub fn deinit(_: *MemoryExportTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *MemoryExportTool) Tool {
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
        const self: *MemoryExportTool = @ptrCast(@alignCast(ptr));
        return common.resultFromReturn(allocator, try self.dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *MemoryExportTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }

    fn dispatch(self: *MemoryExportTool, allocator: std.mem.Allocator, args: std.json.Value) !common.MemoryReturn {
        var reader = common.JsonArgs{ .allocator = allocator, .value = args };
        defer reader.deinit();

        const format = reader.requiredNonEmptyString("format") catch |err| return common.invalidResult(&reader, err);
        if (!std.mem.eql(u8, format, "json") and !std.mem.eql(u8, format, "markdown")) {
            return common.failure(allocator, "format must be 'json' or 'markdown'");
        }

        var since: ?[]u8 = null;
        if (reader.optionalInteger("since_days")) |days| {
            since = common.timestampDaysAgo(allocator, days) catch |err| {
                if (err == error.InvalidArgument) return common.failure(allocator, "since_days must be non-negative");
                return err;
            };
        }
        defer if (since) |value| allocator.free(value);

        var category: ?memory.MemoryCategory = null;
        if (reader.optionalString("category")) |raw| category = try common.categoryFromString(allocator, raw);
        defer if (category) |*cat| cat.deinit(allocator);

        const entries = try self.memory_backend.exportEntries(allocator, .{
            .category = category,
            .since = since,
        });
        defer memory.sqlite.freeEntries(allocator, entries);

        const output = if (std.mem.eql(u8, format, "json"))
            try formatJson(allocator, self.memory_backend, entries)
        else
            try formatMarkdown(allocator, self.memory_backend, entries);
        return .{ .output = output };
    }
};

pub fn formatJson(
    allocator: std.mem.Allocator,
    memory_backend: *memory.SqliteMemory,
    entries: []const memory.MemoryEntry,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try out.append('[');
    for (entries, 0..) |entry, i| {
        if (i != 0) try out.append(',');
        var metadata = try memory_backend.getToolMetadata(allocator, entry.key);
        defer metadata.deinit(allocator);

        try out.appendSlice("{\"category\":");
        try std.json.stringify(entry.category.asString(), .{}, out.writer());
        try out.appendSlice(",\"content\":");
        try std.json.stringify(entry.content, .{}, out.writer());
        try out.appendSlice(",\"content_hash\":");
        try std.json.stringify(entry.key, .{}, out.writer());
        try out.appendSlice(",\"created_at\":");
        try std.json.stringify(entry.timestamp, .{}, out.writer());
        try out.appendSlice(",\"importance\":");
        if (entry.importance) |importance| {
            try out.writer().print("{d}", .{importance});
        } else {
            try out.appendSlice("null");
        }
        try out.appendSlice(",\"source\":");
        if (metadata.source) |source| {
            try std.json.stringify(source, .{}, out.writer());
        } else {
            try out.appendSlice("null");
        }
        try out.appendSlice(",\"tags\":[");
        for (metadata.tags, 0..) |tag, tag_i| {
            if (tag_i != 0) try out.append(',');
            try std.json.stringify(tag, .{}, out.writer());
        }
        try out.appendSlice("]}");
    }
    try out.append(']');
    return out.toOwnedSlice();
}

pub fn formatMarkdown(
    allocator: std.mem.Allocator,
    memory_backend: *memory.SqliteMemory,
    entries: []const memory.MemoryEntry,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("| content_hash | category | tags | created_at | content |\n");
    try out.appendSlice("| --- | --- | --- | --- | --- |\n");
    for (entries) |entry| {
        var metadata = try memory_backend.getToolMetadata(allocator, entry.key);
        defer metadata.deinit(allocator);
        const tag_list = try common.formatTagList(allocator, metadata.tags);
        defer allocator.free(tag_list);

        try out.appendSlice("| ");
        try common.writeMarkdownEscaped(out.writer(), entry.key);
        try out.appendSlice(" | ");
        try common.writeMarkdownEscaped(out.writer(), entry.category.asString());
        try out.appendSlice(" | ");
        try common.writeMarkdownEscaped(out.writer(), tag_list);
        try out.appendSlice(" | ");
        try common.writeMarkdownEscaped(out.writer(), entry.timestamp);
        try out.appendSlice(" | ");
        try common.writeMarkdownEscaped(out.writer(), entry.content);
        try out.appendSlice(" |\n");
    }
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
    try mem.storeWithMetadata(std.testing.allocator, hash, content, category, null, null, 0.7);
    try mem.setToolMetadata(std.testing.allocator, hash, tags, "test");
    try mem.setEntryTimestampForEval(hash, timestamp);
    return hash;
}

test "memory_export emits JSON array with metadata" {
    var fixture = try tempMemory();
    defer fixture.mem.deinit();
    defer std.testing.allocator.free(fixture.path);
    defer fixture.tmp.cleanup();

    const tags = [_][]const u8{"zig"};
    const hash = try seed(&fixture.mem, "Export me", "project", "2026-05-01T00:00:00Z", &tags);
    defer std.testing.allocator.free(hash);

    var parsed = try parseArgs(std.testing.allocator, "{\"format\":\"json\",\"category\":\"project\"}");
    defer parsed.deinit();
    var tool_impl = MemoryExportTool.init(std.testing.allocator, &fixture.mem);
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(std.testing.allocator, parsed.value);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"content\":\"Export me\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"tags\":[\"zig\"]") != null);
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var fixture = try tempMemory();
    defer fixture.mem.deinit();
    defer std.testing.allocator.free(fixture.path);
    defer fixture.tmp.cleanup();

    const tags = [_][]const u8{"zig"};
    const hash = try seed(&fixture.mem, "OOM export", "project", "2026-05-01T00:00:00Z", &tags);
    defer std.testing.allocator.free(hash);

    var parsed = try parseArgs(std.testing.allocator, "{\"format\":\"markdown\"}");
    defer parsed.deinit();
    var tool_impl = MemoryExportTool.init(std.testing.allocator, &fixture.mem);
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

    var parsed = try parseArgs(std.testing.allocator, "{}");
    defer parsed.deinit();
    var tool_impl = MemoryExportTool.init(std.testing.allocator, &fixture.mem);
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "memory_export execute is OOM safe for success and validation errors" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
}
