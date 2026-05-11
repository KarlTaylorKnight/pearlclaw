//! FileEditTool port of `zeroclaw-tools/src/file_edit.rs`.

const std = @import("std");
const common = @import("fs_common.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "file_edit";
const DESCRIPTION = "Edit a file by replacing an exact string match with new content";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "properties": {
    \\    "new_string": {
    \\      "description": "The replacement text (empty string to delete the matched text)",
    \\      "type": "string"
    \\    },
    \\    "old_string": {
    \\      "description": "The exact text to find and replace (must appear exactly once in the file)",
    \\      "type": "string"
    \\    },
    \\    "path": {
    \\      "description": "Path to the file. Relative paths resolve from workspace; outside paths require policy allowlist.",
    \\      "type": "string"
    \\    }
    \\  },
    \\  "required": ["path", "old_string", "new_string"],
    \\  "type": "object"
    \\}
;

pub const FileEditTool = struct {
    pub fn init(_: std.mem.Allocator) FileEditTool {
        return .{};
    }

    pub fn deinit(_: *FileEditTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *FileEditTool) Tool {
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
        _ = @as(*FileEditTool, @ptrCast(@alignCast(ptr)));
        return common.resultFromReturn(allocator, try dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *FileEditTool = @ptrCast(@alignCast(ptr));
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
    const old_string = reader.requiredString("old_string") catch |err| return common.invalidResult(&reader, err);
    const new_string = reader.requiredString("new_string") catch |err| return common.invalidResult(&reader, err);

    if (old_string.len == 0) {
        return common.failure(allocator, "old_string must not be empty");
    }

    const path = try common.expandTilde(allocator, raw_path);
    defer allocator.free(path);

    const target = common.resolvedTarget(allocator, path, false) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidPath => return common.failure(allocator, "Invalid path: missing file name"),
        else => return common.failureFmt(allocator, "Failed to resolve file path: {s}", .{common.rustIoError(err)}),
    };
    defer allocator.free(target);

    if (try common.isSymlink(target)) {
        return common.failureFmt(allocator, "Refusing to edit through symlink: {s}", .{target});
    }

    const content = std.fs.cwd().readFileAlloc(allocator, target, std.math.maxInt(usize)) catch |err| {
        if (err == error.OutOfMemory) return err;
        return common.failureFmt(allocator, "Failed to read file: {s}", .{common.rustIoError(err)});
    };
    defer allocator.free(content);

    const match_count = std.mem.count(u8, content, old_string);
    if (match_count == 0) return common.failure(allocator, "old_string not found in file");
    if (match_count > 1) {
        return common.failureFmt(
            allocator,
            "old_string matches {d} times; must match exactly once",
            .{match_count},
        );
    }

    const index = std.mem.indexOf(u8, content, old_string).?;
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    try output.ensureTotalCapacity(content.len - old_string.len + new_string.len);
    output.appendSliceAssumeCapacity(content[0..index]);
    output.appendSliceAssumeCapacity(new_string);
    output.appendSliceAssumeCapacity(content[index + old_string.len ..]);
    const new_content = try output.toOwnedSlice();
    defer allocator.free(new_content);

    std.fs.cwd().writeFile(.{ .sub_path = target, .data = new_content }) catch |err| {
        return common.failureFmt(allocator, "Failed to write file: {s}", .{common.rustIoError(err)});
    };

    return .{
        .output = try std.fmt.allocPrint(
            allocator,
            "Edited {s}: replaced 1 occurrence ({d} bytes)",
            .{ raw_path, new_content.len },
        ),
    };
}

fn parseArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

fn expectExecute(json: []const u8, success: bool, output_substr: []const u8, error_substr: ?[]const u8) !void {
    var parsed = try parseArgs(std.testing.allocator, json);
    defer parsed.deinit();

    var tool_impl = FileEditTool.init(std.testing.allocator);
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

test "file_edit replaces one exact match and rejects ambiguous matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "target.txt", .data = "hello world" });
    try tmp.dir.writeFile(.{ .sub_path = "multi.txt", .data = "aaa bbb aaa" });

    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.posix.chdir(dir);
    defer std.posix.fchdir(old_cwd.fd) catch unreachable;

    try expectExecute("{\"path\":\"target.txt\",\"old_string\":\"hello\",\"new_string\":\"goodbye\"}", true, "replaced 1 occurrence", null);
    try expectExecute("{\"path\":\"multi.txt\",\"old_string\":\"aaa\",\"new_string\":\"ccc\"}", false, "", "matches 2 times");

    const content = try tmp.dir.readFileAlloc(std.testing.allocator, "target.txt", 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("goodbye world", content);
}

test "file_edit rejects empty old_string and symlink targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "target.txt", .data = "hello" });
    try tmp.dir.symLink("target.txt", "link.txt", .{});

    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.posix.chdir(dir);
    defer std.posix.fchdir(old_cwd.fd) catch unreachable;

    try expectExecute("{\"path\":\"target.txt\",\"old_string\":\"\",\"new_string\":\"x\"}", false, "", "old_string must not be empty");
    try expectExecute("{\"path\":\"link.txt\",\"old_string\":\"hello\",\"new_string\":\"bad\"}", false, "", "Refusing to edit through symlink");
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "oom.txt", .data = "hello world" });
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.posix.chdir(dir);
    defer std.posix.fchdir(old_cwd.fd) catch unreachable;

    var parsed = try parseArgs(std.testing.allocator, "{\"path\":\"oom.txt\",\"old_string\":\"world\",\"new_string\":\"zig\"}");
    defer parsed.deinit();
    var tool_impl = FileEditTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    var parsed = try parseArgs(std.testing.allocator, "{\"path\":\"x\",\"old_string\":\"\",\"new_string\":\"z\"}");
    defer parsed.deinit();
    var tool_impl = FileEditTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "file_edit execute is OOM safe for success and validation errors" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
}
