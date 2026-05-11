const std = @import("std");
const tool_mod = @import("tool.zig");
const parser_types = @import("../tool_call_parser/types.zig");

pub const Tool = tool_mod.Tool;
pub const ToolResult = tool_mod.ToolResult;

pub const FsReturn = union(enum) {
    output: []u8,
    failure: Failure,
};

pub const Failure = struct {
    output: []u8,
    error_msg: []u8,
};

pub const JsonArgs = struct {
    allocator: std.mem.Allocator,
    value: std.json.Value,
    error_msg: ?[]u8 = null,

    pub fn deinit(self: *JsonArgs) void {
        if (self.error_msg) |msg| self.allocator.free(msg);
        self.error_msg = null;
    }

    pub fn takeError(self: *JsonArgs) []u8 {
        const msg = self.error_msg.?;
        self.error_msg = null;
        return msg;
    }

    pub fn setErrorFmt(self: *JsonArgs, comptime fmt: []const u8, args: anytype) !void {
        self.error_msg = try std.fmt.allocPrint(self.allocator, fmt, args);
    }

    pub fn field(self: JsonArgs, key: []const u8) ?std.json.Value {
        if (self.value != .object) return null;
        return self.value.object.get(key);
    }

    pub fn requiredString(self: *JsonArgs, key: []const u8) ![]const u8 {
        const raw = self.field(key) orelse {
            try self.setErrorFmt("Missing '{s}' parameter", .{key});
            return error.InvalidArgument;
        };
        if (raw != .string) {
            try self.setErrorFmt("Missing '{s}' parameter", .{key});
            return error.InvalidArgument;
        }
        return raw.string;
    }
};

pub fn parametersSchema(allocator: std.mem.Allocator, json: []const u8) !std.json.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    return parser_types.cloneJsonValue(allocator, parsed.value);
}

pub fn resultFromReturn(allocator: std.mem.Allocator, value: FsReturn) !ToolResult {
    return switch (value) {
        .output => |output| .{
            .success = true,
            .output = output,
            .error_msg = null,
        },
        .failure => |failed| blk: {
            errdefer allocator.free(failed.output);
            errdefer allocator.free(failed.error_msg);
            break :blk .{
                .success = false,
                .output = failed.output,
                .error_msg = failed.error_msg,
            };
        },
    };
}

pub fn failure(allocator: std.mem.Allocator, message: []const u8) !FsReturn {
    const output = try allocator.dupe(u8, "");
    errdefer allocator.free(output);
    const error_msg = try allocator.dupe(u8, message);
    return .{ .failure = .{ .output = output, .error_msg = error_msg } };
}

pub fn failureFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !FsReturn {
    const output = try allocator.dupe(u8, "");
    errdefer allocator.free(output);
    const error_msg = try std.fmt.allocPrint(allocator, fmt, args);
    return .{ .failure = .{ .output = output, .error_msg = error_msg } };
}

pub fn invalidResult(reader: *JsonArgs, err: anyerror) anyerror!FsReturn {
    if (err == error.InvalidArgument) {
        const msg = reader.takeError();
        errdefer reader.allocator.free(msg);
        const output = try reader.allocator.dupe(u8, "");
        return .{ .failure = .{ .output = output, .error_msg = msg } };
    }
    return err;
}

pub fn expandTilde(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    if (std.mem.eql(u8, raw_path, "~")) {
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            return home;
        } else |_| {
            return allocator.dupe(u8, raw_path);
        }
    }

    if (std.mem.startsWith(u8, raw_path, "~/")) {
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, raw_path[2..] });
        } else |_| {
            return allocator.dupe(u8, raw_path);
        }
    }

    return allocator.dupe(u8, raw_path);
}

pub fn resolvedTarget(allocator: std.mem.Allocator, path: []const u8, create_parent: bool) ![]u8 {
    const parent = std.fs.path.dirname(path) orelse ".";
    if (create_parent) {
        try std.fs.cwd().makePath(parent);
    }

    const resolved_parent = std.fs.cwd().realpathAlloc(allocator, parent) catch |err| {
        return err;
    };
    defer allocator.free(resolved_parent);

    const file_name = std.fs.path.basename(path);
    if (file_name.len == 0 or std.mem.eql(u8, file_name, "/")) return error.InvalidPath;
    return std.fs.path.join(allocator, &.{ resolved_parent, file_name });
}

pub fn isSymlink(path: []const u8) !bool {
    const stat = std.posix.fstatat(std.fs.cwd().fd, path, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return (stat.mode & std.posix.S.IFMT) == std.posix.S.IFLNK;
}

pub fn rustIoError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory (os error 2)",
        error.AccessDenied => "Permission denied (os error 13)",
        error.IsDir => "Is a directory (os error 21)",
        error.NotDir => "Not a directory (os error 20)",
        error.NameTooLong => "File name too long (os error 63)",
        error.SymLinkLoop => "Too many levels of symbolic links (os error 62)",
        else => @errorName(err),
    };
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    const schema_json =
        \\{"properties":{"path":{"description":"x","type":"string"}},"required":["path"],"type":"object"}
    ;
    var value = try parametersSchema(allocator, schema_json);
    defer parser_types.freeJsonValue(allocator, &value);
}

test "fs_common parametersSchema is OOM safe across nested schema parse + clone" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}
