//! MemoryForgetTool port for deleting one memory by content hash.

const std = @import("std");
const common = @import("memory_common.zig");
const memory = @import("../memory/root.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "memory_forget";
const DESCRIPTION =
    "Delete a single long-term memory by content_hash. The memory backend is borrowed by the tool and remains owned by the caller.";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "properties": {
    \\    "content_hash": { "type": "string" }
    \\  },
    \\  "required": ["content_hash"],
    \\  "type": "object"
    \\}
;

/// Deletes memories through a borrowed `SqliteMemory`.
/// The caller owns the memory backend; `deinit` must not free it.
pub const MemoryForgetTool = struct {
    memory_backend: *memory.SqliteMemory,

    pub fn init(_: std.mem.Allocator, memory_backend: *memory.SqliteMemory) MemoryForgetTool {
        return .{ .memory_backend = memory_backend };
    }

    pub fn deinit(_: *MemoryForgetTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *MemoryForgetTool) Tool {
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
        const self: *MemoryForgetTool = @ptrCast(@alignCast(ptr));
        return common.resultFromReturn(allocator, try self.dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *MemoryForgetTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }

    fn dispatch(self: *MemoryForgetTool, allocator: std.mem.Allocator, args: std.json.Value) !common.MemoryReturn {
        var reader = common.JsonArgs{ .allocator = allocator, .value = args };
        defer reader.deinit();

        const hash = reader.requiredNonEmptyString("content_hash") catch |err| return common.invalidResult(&reader, err);
        const removed = try self.memory_backend.forget(hash);
        if (!removed) return common.failureWithOutput(allocator, "Memory not found", "Memory not found");
        try self.memory_backend.deleteToolMetadata(hash);
        return .{ .output = try std.fmt.allocPrint(allocator, "Forgot memory {s}", .{hash}) };
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

test "memory_forget removes existing memory and metadata" {
    var fixture = try tempMemory();
    defer fixture.mem.deinit();
    defer std.testing.allocator.free(fixture.path);
    defer fixture.tmp.cleanup();

    const content = "temporary";
    const hash = try memory.contentHash(std.testing.allocator, content);
    defer std.testing.allocator.free(hash);
    const category = memory.MemoryCategory.conversation;
    try fixture.mem.storeWithMetadata(std.testing.allocator, hash, content, category, null, null, null);
    const tags = [_][]const u8{"tmp"};
    try fixture.mem.setToolMetadata(std.testing.allocator, hash, &tags, null);

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"content_hash\":\"{s}\"}}", .{hash});
    defer std.testing.allocator.free(args);
    var parsed = try parseArgs(std.testing.allocator, args);
    defer parsed.deinit();
    var tool_impl = MemoryForgetTool.init(std.testing.allocator, &fixture.mem);
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(std.testing.allocator, parsed.value);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("Forgot memory ", result.output[0.."Forgot memory ".len]);
    var after = try fixture.mem.get(std.testing.allocator, hash);
    defer if (after) |*entry| entry.deinit(std.testing.allocator);
    try std.testing.expect(after == null);
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var fixture = try tempMemory();
    defer fixture.mem.deinit();
    defer std.testing.allocator.free(fixture.path);
    defer fixture.tmp.cleanup();

    const content = "OOM forget";
    const hash = try memory.contentHash(std.testing.allocator, content);
    defer std.testing.allocator.free(hash);
    const category = memory.MemoryCategory.core;
    try fixture.mem.storeWithMetadata(std.testing.allocator, hash, content, category, null, null, null);

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"content_hash\":\"{s}\"}}", .{hash});
    defer std.testing.allocator.free(args);
    var parsed = try parseArgs(std.testing.allocator, args);
    defer parsed.deinit();
    var tool_impl = MemoryForgetTool.init(std.testing.allocator, &fixture.mem);
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
    var tool_impl = MemoryForgetTool.init(std.testing.allocator, &fixture.mem);
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    var value = try MemoryForgetTool.parametersSchema(allocator);
    defer @import("../tool_call_parser/types.zig").freeJsonValue(allocator, &value);
}

test "memory_forget execute and parametersSchema are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}
