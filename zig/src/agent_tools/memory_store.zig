//! MemoryStoreTool port for storing content-addressed long-term memories.

const std = @import("std");
const common = @import("memory_common.zig");
const memory = @import("../memory/root.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "memory_store";
const DESCRIPTION =
    "Store a fact, preference, or note in long-term memory. The memory backend is borrowed by the tool and remains owned by the caller.";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "properties": {
    \\    "category": { "type": "string" },
    \\    "content": { "type": "string" },
    \\    "importance": { "type": "number" },
    \\    "source": { "type": "string" },
    \\    "tags": {
    \\      "items": { "type": "string" },
    \\      "type": "array"
    \\    }
    \\  },
    \\  "required": ["content", "category"],
    \\  "type": "object"
    \\}
;

/// Stores memories through a borrowed `SqliteMemory`.
/// The caller owns the memory backend; `deinit` must not free it.
pub const MemoryStoreTool = struct {
    memory_backend: *memory.SqliteMemory,

    pub fn init(_: std.mem.Allocator, memory_backend: *memory.SqliteMemory) MemoryStoreTool {
        return .{ .memory_backend = memory_backend };
    }

    pub fn deinit(_: *MemoryStoreTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *MemoryStoreTool) Tool {
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
        const self: *MemoryStoreTool = @ptrCast(@alignCast(ptr));
        return common.resultFromReturn(allocator, try self.dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *MemoryStoreTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }

    fn dispatch(self: *MemoryStoreTool, allocator: std.mem.Allocator, args: std.json.Value) !common.MemoryReturn {
        var reader = common.JsonArgs{ .allocator = allocator, .value = args };
        defer reader.deinit();

        const content = reader.requiredNonEmptyString("content") catch |err| return common.invalidResult(&reader, err);
        const category_str = reader.requiredNonEmptyString("category") catch |err| return common.invalidResult(&reader, err);
        const tags = reader.optionalTags() catch |err| return common.invalidResult(&reader, err);
        defer allocator.free(tags);
        const source = reader.optionalString("source");
        const importance = reader.optionalNumber("importance");

        const hash = try memory.contentHash(allocator, content);
        defer allocator.free(hash);

        var category = try common.categoryFromString(allocator, category_str);
        defer category.deinit(allocator);

        try self.memory_backend.storeWithMetadata(
            allocator,
            hash,
            content,
            category,
            null,
            null,
            importance,
        );
        try self.memory_backend.setToolMetadata(allocator, hash, tags, source);

        return .{
            .output = try std.fmt.allocPrint(
                allocator,
                "Stored memory {s} in category {s}",
                .{ hash, category_str },
            ),
        };
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

test "memory_store stores content by hash and records metadata" {
    var fixture = try tempMemory();
    defer fixture.mem.deinit();
    defer std.testing.allocator.free(fixture.path);
    defer fixture.tmp.cleanup();

    var parsed = try parseArgs(
        std.testing.allocator,
        "{\"content\":\"Remember the Zig port\",\"category\":\"project\",\"tags\":[\"zig\",\"memory\"],\"source\":\"test\",\"importance\":0.8}",
    );
    defer parsed.deinit();

    var tool_impl = MemoryStoreTool.init(std.testing.allocator, &fixture.mem);
    defer tool_impl.deinit(std.testing.allocator);

    var result = try tool_impl.tool().execute(std.testing.allocator, parsed.value);
    defer result.deinit(std.testing.allocator);

    const expected_hash = try memory.contentHash(std.testing.allocator, "Remember the Zig port");
    defer std.testing.allocator.free(expected_hash);
    const expected_output = try std.fmt.allocPrint(
        std.testing.allocator,
        "Stored memory {s} in category project",
        .{expected_hash},
    );
    defer std.testing.allocator.free(expected_output);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(expected_output, result.output);

    var entry = (try fixture.mem.get(std.testing.allocator, expected_hash)).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Remember the Zig port", entry.content);
    try std.testing.expectEqualStrings("project", entry.category.asString());
    try std.testing.expectEqual(@as(?f64, 0.8), entry.importance);

    var metadata = try fixture.mem.getToolMetadata(std.testing.allocator, expected_hash);
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), metadata.tags.len);
    try std.testing.expectEqualStrings("zig", metadata.tags[0]);
    try std.testing.expectEqualStrings("memory", metadata.tags[1]);
    try std.testing.expectEqualStrings("test", metadata.source.?);
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var fixture = try tempMemory();
    defer fixture.mem.deinit();
    defer std.testing.allocator.free(fixture.path);
    defer fixture.tmp.cleanup();

    var parsed = try parseArgs(
        std.testing.allocator,
        "{\"content\":\"OOM safe store\",\"category\":\"project\",\"tags\":[\"zig\"]}",
    );
    defer parsed.deinit();

    var tool_impl = MemoryStoreTool.init(std.testing.allocator, &fixture.mem);
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

    var parsed = try parseArgs(std.testing.allocator, "{\"category\":\"project\"}");
    defer parsed.deinit();

    var tool_impl = MemoryStoreTool.init(std.testing.allocator, &fixture.mem);
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "memory_store execute is OOM safe for success and validation errors" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
}
