//! DataManagementTool port of `zeroclaw-tools/src/data_management.rs`.

const std = @import("std");
const common = @import("fs_common.zig");
const datetime = @import("../api/datetime.zig");
const parser_types = @import("../tool_call_parser/types.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "data_management";
const DESCRIPTION = "Workspace data retention, purge, and storage statistics";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {
    \\      "type": "string",
    \\      "enum": ["retention_status", "purge", "stats"],
    \\      "description": "Data management command"
    \\    },
    \\    "dry_run": {
    \\      "type": "boolean",
    \\      "description": "If true, purge only lists what would be deleted (default true)"
    \\    }
    \\  },
    \\  "required": ["command"]
    \\}
;

pub const DataManagementTool = struct {
    workspace_dir: []const u8,
    retention_days: u64,

    pub fn init(_: std.mem.Allocator, workspace_dir: []const u8, retention_days: u64) DataManagementTool {
        return .{ .workspace_dir = workspace_dir, .retention_days = retention_days };
    }

    pub fn deinit(_: *DataManagementTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *DataManagementTool) Tool {
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
        const self: *DataManagementTool = @ptrCast(@alignCast(ptr));
        return common.resultFromReturn(allocator, try self.dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *DataManagementTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }

    fn dispatch(self: *DataManagementTool, allocator: std.mem.Allocator, args: std.json.Value) !common.FsReturn {
        var reader = common.JsonArgs{ .allocator = allocator, .value = args };
        defer reader.deinit();

        const command = reader.requiredString("command") catch |err| return common.invalidResult(&reader, err);
        if (std.mem.eql(u8, command, "retention_status")) {
            return self.cmdRetentionStatus(allocator);
        }
        if (std.mem.eql(u8, command, "purge")) {
            const dry_run = optionalBool(reader, "dry_run", true);
            return self.cmdPurge(allocator, dry_run);
        }
        if (std.mem.eql(u8, command, "stats")) {
            return self.cmdStats(allocator);
        }
        return common.failureFmt(allocator, "Unknown command: {s}", .{command});
    }

    fn cmdRetentionStatus(self: *DataManagementTool, allocator: std.mem.Allocator) !common.FsReturn {
        const cutoff = cutoffEpoch(std.time.timestamp(), self.retention_days);
        const cutoff_text = try datetime.formatRfc3339(allocator, @intCast(cutoff));
        defer allocator.free(cutoff_text);
        const affected = try countFilesOlderThan(allocator, self.workspace_dir, cutoff);

        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        var writer = out.writer();
        // serde_json without preserve_order serializes object keys lexicographically.
        try writer.print("{{\"affected_files\":{d},\"cutoff\":", .{affected});
        try std.json.stringify(cutoff_text, .{}, writer);
        try writer.print(",\"retention_days\":{d}}}", .{self.retention_days});
        return .{ .output = try out.toOwnedSlice() };
    }

    fn cmdPurge(self: *DataManagementTool, allocator: std.mem.Allocator, dry_run: bool) !common.FsReturn {
        const cutoff = cutoffEpoch(std.time.timestamp(), self.retention_days);
        const purged = try purgeOldFiles(allocator, self.workspace_dir, cutoff, dry_run);
        const human = try formatBytes(allocator, purged.bytes);
        defer allocator.free(human);

        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        var writer = out.writer();
        try writer.print("{{\"bytes_freed\":{d},\"bytes_freed_human\":", .{purged.bytes});
        try std.json.stringify(human, .{}, writer);
        try writer.print(",\"dry_run\":{},\"files\":{d}}}", .{ dry_run, purged.files });
        return .{ .output = try out.toOwnedSlice() };
    }

    fn cmdStats(self: *DataManagementTool, allocator: std.mem.Allocator) !common.FsReturn {
        var stats = try dirStats(allocator, self.workspace_dir);
        defer stats.deinit(allocator);
        const human = try formatBytes(allocator, stats.total_bytes);
        defer allocator.free(human);

        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        var writer = out.writer();
        try writer.writeAll("{\"subdirectories\":{");
        for (stats.subdirectories.items, 0..) |subdir, idx| {
            if (idx != 0) try writer.writeByte(',');
            const subdir_human = try formatBytes(allocator, subdir.size);
            defer allocator.free(subdir_human);
            try std.json.stringify(subdir.name, .{}, writer);
            try writer.print(":{{\"files\":{d},\"size\":{d},\"size_human\":", .{ subdir.files, subdir.size });
            try std.json.stringify(subdir_human, .{}, writer);
            try writer.writeByte('}');
        }
        try writer.print("}},\"total_files\":{d},\"total_size\":{d},\"total_size_human\":", .{
            stats.total_files,
            stats.total_bytes,
        });
        try std.json.stringify(human, .{}, writer);
        try writer.writeByte('}');
        return .{ .output = try out.toOwnedSlice() };
    }
};

const PurgeResult = struct {
    files: usize,
    bytes: u64,
};

const CountResult = struct {
    files: usize,
    bytes: u64,
};

const SubdirStat = struct {
    name: []u8,
    files: usize,
    size: u64,

    fn deinit(self: *SubdirStat, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }

    fn lessThan(_: void, a: SubdirStat, b: SubdirStat) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

const DirStats = struct {
    total_files: usize,
    total_bytes: u64,
    subdirectories: std.ArrayList(SubdirStat),

    fn deinit(self: *DirStats, allocator: std.mem.Allocator) void {
        for (self.subdirectories.items) |*subdir| subdir.deinit(allocator);
        self.subdirectories.deinit();
        self.* = undefined;
    }
};

const FileMeta = struct {
    is_dir: bool,
    size: u64,
    mtime_sec: u64,
};

fn optionalBool(reader: common.JsonArgs, key: []const u8, default: bool) bool {
    const raw = reader.field(key) orelse return default;
    if (raw != .bool) return default;
    return raw.bool;
}

fn cutoffEpoch(now: i64, retention_days: u64) u64 {
    if (now <= 0) return 0;
    const now_u: u64 = @intCast(now);
    const retention_seconds = std.math.mul(u64, retention_days, std.time.s_per_day) catch return 0;
    if (retention_seconds >= now_u) return 0;
    return now_u - retention_seconds;
}

fn formatBytes(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * KB;
    const GB: u64 = 1024 * MB;
    if (bytes >= GB) {
        return std.fmt.allocPrint(allocator, "{d:.1} GB", .{@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(GB))});
    }
    if (bytes >= MB) {
        return std.fmt.allocPrint(allocator, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(MB))});
    }
    if (bytes >= KB) {
        return std.fmt.allocPrint(allocator, "{d:.1} KB", .{@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(KB))});
    }
    return std.fmt.allocPrint(allocator, "{d} B", .{bytes});
}

fn countFilesOlderThan(allocator: std.mem.Allocator, dir_path: []const u8, cutoff_epoch: u64) !usize {
    const root_meta = metadata(dir_path) orelse return 0;
    if (!root_meta.is_dir) return 0;

    var dir = try openDir(dir_path);
    defer dir.close();

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(child_path);
        const meta = metadata(child_path) orelse continue;
        if (meta.is_dir) {
            count += try countFilesOlderThan(allocator, child_path, cutoff_epoch);
        } else if (meta.mtime_sec < cutoff_epoch) {
            count += 1;
        }
    }
    return count;
}

fn purgeOldFiles(allocator: std.mem.Allocator, dir_path: []const u8, cutoff_epoch: u64, dry_run: bool) !PurgeResult {
    const root_meta = metadata(dir_path) orelse return .{ .files = 0, .bytes = 0 };
    if (!root_meta.is_dir) return .{ .files = 0, .bytes = 0 };

    var dir = try openDir(dir_path);
    defer dir.close();

    var result = PurgeResult{ .files = 0, .bytes = 0 };
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(child_path);
        const meta = metadata(child_path) orelse continue;
        if (meta.is_dir) {
            const child = try purgeOldFiles(allocator, child_path, cutoff_epoch, dry_run);
            result.files += child.files;
            result.bytes += child.bytes;
        } else if (meta.mtime_sec < cutoff_epoch) {
            result.files += 1;
            result.bytes += meta.size;
            if (!dry_run) deleteFile(child_path) catch {};
        }
    }
    return result;
}

fn dirStats(allocator: std.mem.Allocator, root_path: []const u8) !DirStats {
    var stats = DirStats{
        .total_files = 0,
        .total_bytes = 0,
        .subdirectories = std.ArrayList(SubdirStat).init(allocator),
    };
    errdefer stats.deinit(allocator);

    const root_meta = metadata(root_path) orelse return stats;
    if (!root_meta.is_dir) return stats;

    var root = try openDir(root_path);
    defer root.close();

    var it = root.iterate();
    while (try it.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(child_path);
        const meta = metadata(child_path) orelse continue;
        if (meta.is_dir) {
            const contents = try countDirContents(allocator, child_path);
            stats.total_files += contents.files;
            stats.total_bytes += contents.bytes;
            {
                const name = try allocator.dupe(u8, entry.name);
                errdefer allocator.free(name);
                try stats.subdirectories.append(.{
                    .name = name,
                    .files = contents.files,
                    .size = contents.bytes,
                });
            }
        } else {
            stats.total_files += 1;
            stats.total_bytes += meta.size;
        }
    }

    std.mem.sort(SubdirStat, stats.subdirectories.items, {}, SubdirStat.lessThan);
    return stats;
}

fn countDirContents(allocator: std.mem.Allocator, dir_path: []const u8) !CountResult {
    var dir = try openDir(dir_path);
    defer dir.close();

    var result = CountResult{ .files = 0, .bytes = 0 };
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(child_path);
        const meta = metadata(child_path) orelse continue;
        if (meta.is_dir) {
            const child = try countDirContents(allocator, child_path);
            result.files += child.files;
            result.bytes += child.bytes;
        } else {
            result.files += 1;
            result.bytes += meta.size;
        }
    }
    return result;
}

fn metadata(path: []const u8) ?FileMeta {
    const stat = std.posix.fstatat(std.fs.cwd().fd, path, 0) catch return null;
    const mode = stat.mode & std.posix.S.IFMT;
    const size: u64 = if (stat.size <= 0) 0 else @intCast(stat.size);
    const mtime = stat.mtime();
    const mtime_sec: u64 = if (mtime.sec <= 0) 0 else @intCast(mtime.sec);
    return .{
        .is_dir = mode == std.posix.S.IFDIR,
        .size = size,
        .mtime_sec = mtime_sec,
    };
}

fn openDir(path: []const u8) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) return std.fs.openDirAbsolute(path, .{ .iterate = true });
    return std.fs.cwd().openDir(path, .{ .iterate = true });
}

fn deleteFile(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) return std.fs.deleteFileAbsolute(path);
    return std.fs.cwd().deleteFile(path);
}

fn parseArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

fn executeTool(workspace_dir: []const u8, retention_days: u64, json: []const u8) !ToolResult {
    var parsed = try parseArgs(std.testing.allocator, json);
    defer parsed.deinit();
    var tool_impl = DataManagementTool.init(std.testing.allocator, workspace_dir, retention_days);
    defer tool_impl.deinit(std.testing.allocator);
    return tool_impl.tool().execute(std.testing.allocator, parsed.value);
}

fn setFileMtime(dir: std.fs.Dir, path: []const u8, epoch: u64) !void {
    var file = try dir.openFile(path, .{});
    defer file.close();
    const ns = @as(i128, @intCast(epoch)) * std.time.ns_per_s;
    try file.updateTimes(ns, ns);
}

test "data_management reports retention status with JSON output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "old.txt", .data = "old" });
    try setFileMtime(tmp.dir, "old.txt", 0);
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    var result = try executeTool(dir, 30, "{\"command\":\"retention_status\"}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"affected_files\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"retention_days\":30") != null);
}

test "data_management purge dry_run false removes old files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "old.txt", .data = "old" });
    try setFileMtime(tmp.dir, "old.txt", 0);
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    var result = try executeTool(dir, 30, "{\"command\":\"purge\",\"dry_run\":false}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("{\"bytes_freed\":3,\"bytes_freed_human\":\"3 B\",\"dry_run\":false,\"files\":1}", result.output);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("old.txt", .{}));
}

test "data_management stats sorts subdirectories lexicographically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("beta");
    try tmp.dir.makePath("alpha");
    try tmp.dir.writeFile(.{ .sub_path = "beta/b.txt", .data = "bb" });
    try tmp.dir.writeFile(.{ .sub_path = "alpha/a.txt", .data = "a" });
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    var result = try executeTool(dir, 90, "{\"command\":\"stats\"}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(
        "{\"subdirectories\":{\"alpha\":{\"files\":1,\"size\":1,\"size_human\":\"1 B\"},\"beta\":{\"files\":1,\"size\":2,\"size_human\":\"2 B\"}},\"total_files\":2,\"total_size\":3,\"total_size_human\":\"3 B\"}",
        result.output,
    );
}

test "data_management RFC3339 and format_bytes edge cases match Rust expectations" {
    const epoch = try datetime.formatRfc3339(std.testing.allocator, 0);
    defer std.testing.allocator.free(epoch);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00+00:00", epoch);

    const sample = try datetime.formatRfc3339(std.testing.allocator, 1700000000);
    defer std.testing.allocator.free(sample);
    try std.testing.expectEqualStrings("2023-11-14T22:13:20+00:00", sample);

    const bytes = try formatBytes(std.testing.allocator, 1023);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("1023 B", bytes);
    const kb = try formatBytes(std.testing.allocator, 1536);
    defer std.testing.allocator.free(kb);
    try std.testing.expectEqualStrings("1.5 KB", kb);
    const mb = try formatBytes(std.testing.allocator, 1_572_864);
    defer std.testing.allocator.free(mb);
    try std.testing.expectEqualStrings("1.5 MB", mb);
    const gb = try formatBytes(std.testing.allocator, 1_610_612_736);
    defer std.testing.allocator.free(gb);
    try std.testing.expectEqualStrings("1.5 GB", gb);
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "old.txt", .data = "old" });
    try setFileMtime(tmp.dir, "old.txt", 0);
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    var parsed = try parseArgs(std.testing.allocator, "{\"command\":\"retention_status\"}");
    defer parsed.deinit();
    var tool_impl = DataManagementTool.init(allocator, dir, 30);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    var parsed = try parseArgs(std.testing.allocator, "{\"command\":\"nonsense\"}");
    defer parsed.deinit();
    var tool_impl = DataManagementTool.init(allocator, dir, 30);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    var tool_impl = DataManagementTool.init(allocator, dir, 30);
    defer tool_impl.deinit(allocator);
    var value = try tool_impl.tool().parametersSchema(allocator);
    defer parser_types.freeJsonValue(allocator, &value);
}

test "data_management execute and parametersSchema are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}
