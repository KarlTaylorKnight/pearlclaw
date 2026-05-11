//! FileWriteTool port of `zeroclaw-tools/src/file_write.rs`.

const std = @import("std");
const common = @import("fs_common.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "file_write";
const DESCRIPTION = "Write contents to a file in the workspace";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "properties": {
    \\    "content": {
    \\      "description": "Content to write to the file",
    \\      "type": "string"
    \\    },
    \\    "path": {
    \\      "description": "Path to the file. Relative paths resolve from workspace; outside paths require policy allowlist.",
    \\      "type": "string"
    \\    }
    \\  },
    \\  "required": ["path", "content"],
    \\  "type": "object"
    \\}
;

pub const FileWriteTool = struct {
    pub fn init(_: std.mem.Allocator) FileWriteTool {
        return .{};
    }

    pub fn deinit(_: *FileWriteTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *FileWriteTool) Tool {
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
        _ = @as(*FileWriteTool, @ptrCast(@alignCast(ptr)));
        return common.resultFromReturn(allocator, try dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *FileWriteTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }
};

fn dispatch(allocator: std.mem.Allocator, args: std.json.Value) !common.FsReturn {
    var reader = common.JsonArgs{ .allocator = allocator, .value = args };
    defer reader.deinit();

    const raw_path = reader.requiredString("path") catch |err| return common.invalidResult(&reader, err);
    const content = reader.requiredString("content") catch |err| return common.invalidResult(&reader, err);

    const path = try common.expandTilde(allocator, raw_path);
    defer allocator.free(path);

    const target = common.resolvedTarget(allocator, path, true) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidPath => return common.failure(allocator, "Invalid path: missing file name"),
        else => return common.failureFmt(allocator, "Failed to resolve file path: {s}", .{common.rustIoError(err)}),
    };
    defer allocator.free(target);

    if (try common.isSymlink(target)) {
        return common.failureFmt(allocator, "Refusing to write through symlink: {s}", .{target});
    }

    std.fs.cwd().writeFile(.{ .sub_path = target, .data = content }) catch |err| {
        return common.failureFmt(allocator, "Failed to write file: {s}", .{common.rustIoError(err)});
    };

    return .{ .output = try std.fmt.allocPrint(allocator, "Written {d} bytes to {s}", .{ content.len, raw_path }) };
}

fn parseArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

fn expectExecute(json: []const u8, success: bool, output_substr: []const u8, error_substr: ?[]const u8) !void {
    var parsed = try parseArgs(std.testing.allocator, json);
    defer parsed.deinit();

    var tool_impl = FileWriteTool.init(std.testing.allocator);
    defer tool_impl.deinit(std.testing.allocator);

    var result = try tool_impl.tool().execute(std.testing.allocator, parsed.value);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(success, result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, output_substr) != null);
    if (error_substr) |needle| {
        try std.testing.expect(result.error_msg != null);
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, needle) != null);
    } else {
        try std.testing.expect(result.error_msg == null);
    }
}

test "file_write writes content and creates parent directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    try std.posix.chdir(dir);
    defer std.posix.fchdir(old_cwd.fd) catch unreachable;

    try expectExecute("{\"path\":\"nested/out.txt\",\"content\":\"written!\"}", true, "Written 8 bytes", null);
    const content = try tmp.dir.readFileAlloc(std.testing.allocator, "nested/out.txt", 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("written!", content);
}

test "file_write rejects symlink targets before writing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "target.txt", .data = "original" });
    try tmp.dir.symLink("target.txt", "link.txt", .{});

    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.posix.chdir(dir);
    defer std.posix.fchdir(old_cwd.fd) catch unreachable;

    try expectExecute("{\"path\":\"link.txt\",\"content\":\"bad\"}", false, "", "Refusing to write through symlink");
    const content = try tmp.dir.readFileAlloc(std.testing.allocator, "target.txt", 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("original", content);
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    try std.posix.chdir(dir);
    defer std.posix.fchdir(old_cwd.fd) catch unreachable;

    var parsed = try parseArgs(std.testing.allocator, "{\"path\":\"oom.txt\",\"content\":\"ok\"}");
    defer parsed.deinit();
    var tool_impl = FileWriteTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    var parsed = try parseArgs(std.testing.allocator, "{\"content\":\"missing path\"}");
    defer parsed.deinit();
    var tool_impl = FileWriteTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    var tool_impl = FileWriteTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var value = try tool_impl.tool().parametersSchema(allocator);
    defer @import("../tool_call_parser/types.zig").freeJsonValue(allocator, &value);
}

test "file_write execute and parametersSchema are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}
