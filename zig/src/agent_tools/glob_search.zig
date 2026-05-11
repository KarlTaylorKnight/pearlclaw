//! GlobSearchTool port of `zeroclaw-tools/src/glob_search.rs`.

const std = @import("std");
const common = @import("fs_common.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "glob_search";
const DESCRIPTION =
    "Search for files matching a glob pattern within the workspace. " ++
    "Returns a sorted list of matching file paths relative to the workspace root. " ++
    "Examples: '**/*.rs' (all Rust files), 'src/**/mod.rs' (all mod.rs in src).";
const MAX_RESULTS: usize = 1000;

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "properties": {
    \\    "pattern": {
    \\      "description": "Glob pattern to match files, e.g. '**/*.rs', 'src/**/mod.rs'",
    \\      "type": "string"
    \\    }
    \\  },
    \\  "required": ["pattern"],
    \\  "type": "object"
    \\}
;

pub const GlobSearchTool = struct {
    pub fn init(_: std.mem.Allocator) GlobSearchTool {
        return .{};
    }

    pub fn deinit(_: *GlobSearchTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *GlobSearchTool) Tool {
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
        _ = @as(*GlobSearchTool, @ptrCast(@alignCast(ptr)));
        return common.resultFromReturn(allocator, try dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *GlobSearchTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }
};

const SearchPlan = struct {
    output_base: []u8,
    root: []u8,
    rel_pattern: []u8,

    fn deinit(self: *SearchPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.output_base);
        allocator.free(self.root);
        allocator.free(self.rel_pattern);
    }
};

fn dispatch(allocator: std.mem.Allocator, args: std.json.Value) !common.FsReturn {
    var reader = common.JsonArgs{ .allocator = allocator, .value = args };
    defer reader.deinit();

    const raw_pattern = reader.requiredString("pattern") catch |err| return common.invalidResult(&reader, err);
    if (std.mem.eql(u8, raw_pattern, "..") or
        std.mem.indexOf(u8, raw_pattern, "../") != null or
        std.mem.indexOf(u8, raw_pattern, "..\\") != null)
    {
        return common.failure(allocator, "Path traversal ('..') is not allowed in glob patterns.");
    }

    const expanded = try common.expandTilde(allocator, raw_pattern);
    defer allocator.free(expanded);
    validateGlob(expanded) catch |err| switch (err) {
        error.InvalidGlob => return common.failure(allocator, "Invalid glob pattern: invalid character class"),
    };

    var plan = try buildSearchPlan(allocator, expanded);
    defer plan.deinit(allocator);

    var results = std.ArrayList([]u8).init(allocator);
    defer results.deinit();
    defer freeResults(allocator, results.items);
    var truncated = false;
    try collectMatches(allocator, &plan, plan.root, &results, &truncated);
    std.sort.heap([]u8, results.items, {}, stringLessThan);

    if (results.items.len == 0) {
        return .{ .output = try std.fmt.allocPrint(
            allocator,
            "No files matching pattern '{s}' found in workspace.",
            .{raw_pattern},
        ) };
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (results.items, 0..) |result, i| {
        if (i != 0) try out.append('\n');
        try out.appendSlice(result);
    }
    if (truncated) {
        try out.writer().print("\n\n[Results truncated: showing first {d} of more matches]", .{MAX_RESULTS});
    }
    try out.writer().print("\n\nTotal: {d} files", .{results.items.len});
    return .{ .output = try out.toOwnedSlice() };
}

fn buildSearchPlan(allocator: std.mem.Allocator, pattern: []const u8) !SearchPlan {
    const output_base = if (std.fs.path.isAbsolute(pattern))
        try absoluteOutputBase(allocator, pattern)
    else
        try std.fs.cwd().realpathAlloc(allocator, ".");
    errdefer allocator.free(output_base);

    const rel_pattern = if (std.fs.path.isAbsolute(pattern))
        try relativeToBase(allocator, output_base, pattern)
    else
        try allocator.dupe(u8, pattern);
    errdefer allocator.free(rel_pattern);

    const root_rel = fixedDirectoryPrefix(rel_pattern);
    const root = if (root_rel.len == 0)
        try allocator.dupe(u8, output_base)
    else
        try std.fs.path.join(allocator, &.{ output_base, root_rel });
    errdefer allocator.free(root);

    return .{
        .output_base = output_base,
        .root = root,
        .rel_pattern = rel_pattern,
    };
}

fn absoluteOutputBase(allocator: std.mem.Allocator, pattern: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";
    if (cwd.len > 0 and pathStartsWith(pattern, cwd)) {
        return allocator.dupe(u8, cwd);
    }

    const prefix = fixedDirectoryPrefix(pattern);
    if (prefix.len == 0) return allocator.dupe(u8, "/");
    return allocator.dupe(u8, prefix);
}

fn relativeToBase(allocator: std.mem.Allocator, base: []const u8, pattern: []const u8) ![]u8 {
    if (pathStartsWith(pattern, base)) {
        var rel = pattern[base.len..];
        while (std.mem.startsWith(u8, rel, "/")) rel = rel[1..];
        if (rel.len == 0) return allocator.dupe(u8, ".");
        return allocator.dupe(u8, rel);
    }
    return allocator.dupe(u8, std.fs.path.basename(pattern));
}

fn fixedDirectoryPrefix(pattern: []const u8) []const u8 {
    var last_slash_before_glob: ?usize = null;
    var last_slash: ?usize = null;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '/') last_slash = i;
        if (c == '*' or c == '?' or c == '[') {
            return if (last_slash_before_glob) |idx| pattern[0..idx] else if (last_slash) |idx| pattern[0..idx] else "";
        }
        if (c == '/') last_slash_before_glob = i;
    }
    return if (last_slash) |idx| pattern[0..idx] else "";
}

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or prefix.len == 0 or prefix[prefix.len - 1] == '/' or path[prefix.len] == '/';
}

fn collectMatches(
    allocator: std.mem.Allocator,
    plan: *const SearchPlan,
    dir_path: []const u8,
    results: *std.ArrayList([]u8),
    truncated: *bool,
) !void {
    if (results.items.len >= MAX_RESULTS) {
        truncated.* = true;
        return;
    }

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (results.items.len >= MAX_RESULTS) {
            truncated.* = true;
            return;
        }
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        const child_abs = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(child_abs);

        switch (entry.kind) {
            .directory => try collectMatches(allocator, plan, child_abs, results, truncated),
            .file, .sym_link, .unknown => try maybeAppendMatch(allocator, plan, child_abs, results),
            else => {},
        }
    }
}

fn maybeAppendMatch(
    allocator: std.mem.Allocator,
    plan: *const SearchPlan,
    child_abs: []const u8,
    results: *std.ArrayList([]u8),
) !void {
    var file = std.fs.openFileAbsolute(child_abs, .{}) catch return;
    defer file.close();
    const stat = file.stat() catch return;
    if (stat.kind == .directory) return;

    const rel = try relativeToBase(allocator, plan.output_base, child_abs);
    errdefer allocator.free(rel);
    const matched = matchGlob(plan.rel_pattern, rel) catch |err| switch (err) {
        error.InvalidGlob => return,
        else => return err,
    };
    if (!matched) {
        allocator.free(rel);
        return;
    }

    try results.ensureUnusedCapacity(1);
    results.appendAssumeCapacity(rel);
}

fn validateGlob(pattern: []const u8) !void {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '[') {
            i += 1;
            if (i >= pattern.len) return error.InvalidGlob;
            if (pattern[i] == '!' or pattern[i] == '^') i += 1;
            var closed = false;
            while (i < pattern.len) : (i += 1) {
                if (pattern[i] == ']') {
                    closed = true;
                    break;
                }
            }
            if (!closed) return error.InvalidGlob;
        }
    }
}

fn matchGlob(pattern: []const u8, text: []const u8) !bool {
    if (pattern.len == 0) return text.len == 0;

    if (std.mem.startsWith(u8, pattern, "**/")) {
        if (try matchGlob(pattern[3..], text)) return true;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '/' and try matchGlob(pattern[3..], text[i + 1 ..])) return true;
        }
        return false;
    }

    if (std.mem.startsWith(u8, pattern, "**")) {
        // Bare `**` (not followed by `/`) matches zero-or-more bytes including
        // path separators. Distinct from the `**/` arm above, which iterates
        // per-segment. Correct for trailing-`**` patterns like `src/**`
        // meaning "anything under src" — current fixtures all use `**/...`
        // so this branch isn't exercised, but it preserves Rust glob-crate
        // parity for bare-`**` patterns.
        if (try matchGlob(pattern[2..], text)) return true;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (try matchGlob(pattern[2..], text[i + 1 ..])) return true;
        }
        return false;
    }

    return switch (pattern[0]) {
        '*' => blk: {
            if (try matchGlob(pattern[1..], text)) break :blk true;
            var i: usize = 0;
            while (i < text.len and text[i] != '/') : (i += 1) {
                if (try matchGlob(pattern[1..], text[i + 1 ..])) break :blk true;
            }
            break :blk false;
        },
        '?' => text.len > 0 and text[0] != '/' and try matchGlob(pattern[1..], text[1..]),
        '[' => blk: {
            if (text.len == 0 or text[0] == '/') break :blk false;
            const end = std.mem.indexOfScalar(u8, pattern, ']') orelse return error.InvalidGlob;
            if (!classMatches(pattern[1..end], text[0])) break :blk false;
            break :blk try matchGlob(pattern[end + 1 ..], text[1..]);
        },
        else => text.len > 0 and pattern[0] == text[0] and try matchGlob(pattern[1..], text[1..]),
    };
}

fn classMatches(raw_class: []const u8, byte: u8) bool {
    var negate = false;
    var class = raw_class;
    if (class.len > 0 and (class[0] == '!' or class[0] == '^')) {
        negate = true;
        class = class[1..];
    }

    var matched = false;
    var i: usize = 0;
    while (i < class.len) : (i += 1) {
        if (i + 2 < class.len and class[i + 1] == '-') {
            if (byte >= class[i] and byte <= class[i + 2]) matched = true;
            i += 2;
        } else if (class[i] == byte) {
            matched = true;
        }
    }
    return if (negate) !matched else matched;
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn freeResults(allocator: std.mem.Allocator, results: []const []u8) void {
    for (results) |result| allocator.free(result);
}

fn parseArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "glob matcher supports star, recursive star, question, and character classes" {
    try std.testing.expect(try matchGlob("*.txt", "a.txt"));
    try std.testing.expect(try matchGlob("**/*.rs", "root.rs"));
    try std.testing.expect(try matchGlob("**/*.rs", "src/deep/lib.rs"));
    try std.testing.expect(try matchGlob("file-?.txt", "file-a.txt"));
    try std.testing.expect(try matchGlob("[ab].txt", "a.txt"));
    try std.testing.expect(!try matchGlob("[ab].txt", "c.txt"));
}

test "glob_search returns sorted file matches only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.makeDir("subdir");

    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.posix.chdir(dir);
    defer std.posix.fchdir(old_cwd.fd) catch unreachable;

    var parsed = try parseArgs(std.testing.allocator, "{\"pattern\":\"*.txt\"}");
    defer parsed.deinit();
    var tool_impl = GlobSearchTool.init(std.testing.allocator);
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(std.testing.allocator, parsed.value);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("a.txt\nb.txt\n\nTotal: 2 files", result.output);
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "oom.txt", .data = "" });
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.posix.chdir(dir);
    defer std.posix.fchdir(old_cwd.fd) catch unreachable;

    var parsed = try parseArgs(std.testing.allocator, "{\"pattern\":\"*.txt\"}");
    defer parsed.deinit();
    var tool_impl = GlobSearchTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    var parsed = try parseArgs(std.testing.allocator, "{\"pattern\":\"..\"}");
    defer parsed.deinit();
    var tool_impl = GlobSearchTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    var tool_impl = GlobSearchTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var value = try tool_impl.tool().parametersSchema(allocator);
    defer @import("../tool_call_parser/types.zig").freeJsonValue(allocator, &value);
}

test "glob_search execute and parametersSchema are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}
