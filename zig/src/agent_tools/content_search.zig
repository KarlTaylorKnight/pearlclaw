//! ContentSearchTool grep-only port of `zeroclaw-tools/src/content_search.rs`.

const std = @import("std");
const common = @import("fs_common.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "content_search";
const DESCRIPTION =
    "Search file contents by regex pattern within the workspace. " ++
    "Supports ripgrep (rg) with grep fallback. " ++
    "Output modes: 'content' (matching lines with context), " ++
    "'files_with_matches' (file paths only), 'count' (match counts per file). " ++
    "Example: pattern='fn main', include='*.rs', output_mode='content'.";

const MAX_RESULTS: usize = 1000;
const MAX_OUTPUT_BYTES: usize = 1_048_576;
const RAW_CAPTURE_LIMIT: usize = MAX_OUTPUT_BYTES * 2;
const TIMEOUT_MS: i64 = 30_000;
const POLL_INTERVAL_MS: i32 = 100;
const SIGTERM_GRACE_MS: i64 = 1_000;

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "properties": {
    \\    "case_sensitive": {
    \\      "default": true,
    \\      "description": "Case-sensitive matching. Defaults to true",
    \\      "type": "boolean"
    \\    },
    \\    "context_after": {
    \\      "default": 0,
    \\      "description": "Lines of context after each match (content mode only)",
    \\      "type": "integer"
    \\    },
    \\    "context_before": {
    \\      "default": 0,
    \\      "description": "Lines of context before each match (content mode only)",
    \\      "type": "integer"
    \\    },
    \\    "include": {
    \\      "description": "File glob filter, e.g. '*.rs', '*.{ts,tsx}'",
    \\      "type": "string"
    \\    },
    \\    "max_results": {
    \\      "default": 1000,
    \\      "description": "Maximum number of results to return. Defaults to 1000",
    \\      "type": "integer"
    \\    },
    \\    "multiline": {
    \\      "default": false,
    \\      "description": "Enable multiline matching (ripgrep only, errors on grep fallback)",
    \\      "type": "boolean"
    \\    },
    \\    "output_mode": {
    \\      "default": "content",
    \\      "description": "Output format: 'content' (matching lines), 'files_with_matches' (paths only), 'count' (match counts)",
    \\      "enum": ["content", "files_with_matches", "count"],
    \\      "type": "string"
    \\    },
    \\    "path": {
    \\      "default": ".",
    \\      "description": "Directory to search in, relative to workspace root. Defaults to '.'",
    \\      "type": "string"
    \\    },
    \\    "pattern": {
    \\      "description": "Regular expression pattern to search for",
    \\      "type": "string"
    \\    }
    \\  },
    \\  "required": ["pattern"],
    \\  "type": "object"
    \\}
;

pub const ContentSearchTool = struct {
    pub fn init(_: std.mem.Allocator) ContentSearchTool {
        return .{};
    }

    pub fn deinit(_: *ContentSearchTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *ContentSearchTool) Tool {
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
        _ = @as(*ContentSearchTool, @ptrCast(@alignCast(ptr)));
        return common.resultFromReturn(allocator, try dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ContentSearchTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }
};

const OutputMode = enum {
    content,
    files_with_matches,
    count,
};

fn dispatch(allocator: std.mem.Allocator, args: std.json.Value) !common.FsReturn {
    var reader = common.JsonArgs{ .allocator = allocator, .value = args };
    defer reader.deinit();

    const pattern = reader.requiredString("pattern") catch |err| return common.invalidResult(&reader, err);
    if (pattern.len == 0) {
        return common.failure(allocator, "Empty pattern is not allowed.");
    }

    const search_path = optionalString(reader, "path") orelse ".";
    const output_mode_raw = optionalString(reader, "output_mode") orelse "content";
    const output_mode = parseOutputMode(output_mode_raw) orelse {
        return common.failureFmt(
            allocator,
            "Invalid output_mode '{s}'. Allowed values: content, files_with_matches, count.",
            .{output_mode_raw},
        );
    };
    const include = optionalString(reader, "include");
    const case_sensitive = optionalBool(reader, "case_sensitive", true);
    const context_before = optionalUsize(reader, "context_before", 0);
    const context_after = optionalUsize(reader, "context_after", 0);
    const multiline = optionalBool(reader, "multiline", false);
    const max_results = @min(optionalUsize(reader, "max_results", MAX_RESULTS), MAX_RESULTS);

    if (multiline) {
        return common.failure(allocator, "Multiline matching requires ripgrep (rg), which is not available.");
    }

    const expanded_path = try common.expandTilde(allocator, search_path);
    defer allocator.free(expanded_path);

    const resolved_path = std.fs.realpathAlloc(allocator, expanded_path) catch |err| {
        return common.failureFmt(allocator, "Cannot resolve path '{s}': {s}", .{ search_path, common.rustIoError(err) });
    };
    defer allocator.free(resolved_path);

    const workspace_canon = std.fs.cwd().realpathAlloc(allocator, ".") catch |err| {
        return common.failureFmt(allocator, "Cannot resolve path '.': {s}", .{common.rustIoError(err)});
    };
    defer allocator.free(workspace_canon);

    if (!isWithinWorkspace(resolved_path, workspace_canon)) {
        return common.failureFmt(
            allocator,
            "Resolved path for '{s}' is outside the allowed workspace.",
            .{search_path},
        );
    }

    var args_builder = CommandArgs.init(allocator);
    defer args_builder.deinit();
    try buildGrepCommand(
        &args_builder,
        pattern,
        resolved_path,
        output_mode,
        include,
        case_sensitive,
        context_before,
        context_after,
    );

    var env = try safeEnv(allocator);
    defer env.deinit();

    var process = runCommand(allocator, args_builder.argv.items, &env) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return common.failureFmt(allocator, "Failed to execute search command: {s}", .{@errorName(err)}),
    };
    defer process.deinit(allocator);

    if (process.timed_out) {
        return common.failureFmt(allocator, "Search timed out after {d} seconds.", .{TIMEOUT_MS / 1000});
    }

    if (process.exit_code >= 2 and !process.stdout_capped) {
        return common.failureFmt(allocator, "Search error: {s}", .{std.mem.trim(u8, process.stderr, " \t\r\n")});
    }

    const formatted = try formatGrepOutput(allocator, process.stdout, workspace_canon, output_mode, max_results);
    errdefer allocator.free(formatted);

    if (formatted.len > MAX_OUTPUT_BYTES or process.stdout_capped) {
        const end = truncateUtf8(formatted, MAX_OUTPUT_BYTES);
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();
        try output.appendSlice(end);
        try output.appendSlice("\n\n[Output truncated: exceeded 1 MB limit]");
        allocator.free(formatted);
        return .{ .output = try output.toOwnedSlice() };
    }

    return .{ .output = formatted };
}

fn optionalString(reader: common.JsonArgs, key: []const u8) ?[]const u8 {
    const raw = reader.field(key) orelse return null;
    if (raw != .string) return null;
    return raw.string;
}

fn optionalBool(reader: common.JsonArgs, key: []const u8, default: bool) bool {
    const raw = reader.field(key) orelse return default;
    if (raw != .bool) return default;
    return raw.bool;
}

fn optionalUsize(reader: common.JsonArgs, key: []const u8, default: usize) usize {
    const raw = reader.field(key) orelse return default;
    if (raw != .integer or raw.integer < 0) return default;
    return std.math.cast(usize, raw.integer) orelse default;
}

fn parseOutputMode(raw: []const u8) ?OutputMode {
    if (std.mem.eql(u8, raw, "content")) return .content;
    if (std.mem.eql(u8, raw, "files_with_matches")) return .files_with_matches;
    if (std.mem.eql(u8, raw, "count")) return .count;
    return null;
}

fn isWithinWorkspace(path: []const u8, workspace: []const u8) bool {
    if (std.mem.eql(u8, path, workspace)) return true;
    if (!std.mem.startsWith(u8, path, workspace)) return false;
    if (path.len == workspace.len) return true;
    return path[workspace.len] == '/' or path[workspace.len] == '\\';
}

const CommandArgs = struct {
    allocator: std.mem.Allocator,
    argv: std.ArrayList([]const u8),
    owned: std.ArrayList([]u8),

    fn init(allocator: std.mem.Allocator) CommandArgs {
        return .{
            .allocator = allocator,
            .argv = std.ArrayList([]const u8).init(allocator),
            .owned = std.ArrayList([]u8).init(allocator),
        };
    }

    fn deinit(self: *CommandArgs) void {
        for (self.owned.items) |arg| self.allocator.free(arg);
        self.owned.deinit();
        self.argv.deinit();
    }

    fn append(self: *CommandArgs, arg: []const u8) !void {
        try self.argv.append(arg);
    }

    fn appendOwned(self: *CommandArgs, arg: []u8) !void {
        errdefer self.allocator.free(arg);
        try self.owned.ensureUnusedCapacity(1);
        try self.argv.ensureUnusedCapacity(1);
        self.owned.appendAssumeCapacity(arg);
        self.argv.appendAssumeCapacity(arg);
    }

    fn appendUsize(self: *CommandArgs, value: usize) !void {
        const text = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
        try self.appendOwned(text);
    }
};

fn buildGrepCommand(
    command: *CommandArgs,
    pattern: []const u8,
    search_path: []const u8,
    output_mode: OutputMode,
    include: ?[]const u8,
    case_sensitive: bool,
    context_before: usize,
    context_after: usize,
) !void {
    try command.append("grep");
    try command.append("-r");
    try command.append("-n");
    try command.append("-E");
    try command.append("--binary-files=without-match");

    switch (output_mode) {
        .files_with_matches => try command.append("-l"),
        .count => try command.append("-c"),
        .content => {
            if (context_before > 0) {
                try command.append("-B");
                try command.appendUsize(context_before);
            }
            if (context_after > 0) {
                try command.append("-A");
                try command.appendUsize(context_after);
            }
        },
    }

    if (!case_sensitive) try command.append("-i");
    if (include) |glob| {
        try command.append("--include");
        try command.append(glob);
    }
    try command.append("--");
    try command.append(pattern);
    try command.append(search_path);
}

fn safeEnv(allocator: std.mem.Allocator) !std.process.EnvMap {
    var env = std.process.EnvMap.init(allocator);
    errdefer env.deinit();

    const keys = [_][]const u8{ "PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE" };
    for (keys) |key| {
        const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => continue,
            error.OutOfMemory => return err,
            else => continue,
        };
        defer allocator.free(value);
        try env.put(key, value);
    }
    return env;
}

const ProcessOutput = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: i32,
    timed_out: bool,
    stdout_capped: bool,

    fn deinit(self: *ProcessOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, env: *const std.process.EnvMap) !ProcessOutput {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = env;

    try child.spawn();
    var spawned = true;
    errdefer if (spawned) {
        _ = child.kill() catch {};
    };
    try child.waitForSpawn();

    var stdout = std.ArrayList(u8).init(allocator);
    errdefer stdout.deinit();
    var stderr = std.ArrayList(u8).init(allocator);
    errdefer stderr.deinit();

    var stdout_open = child.stdout != null;
    var stderr_open = child.stderr != null;
    var stdout_capped = false;
    var stderr_capped = false;
    var exited = false;
    var status: u32 = 0;
    var sent_term = false;
    var sent_kill = false;
    var timed_out = false;
    var term_sent_at: i64 = 0;
    const started_at = std.time.milliTimestamp();

    while (!exited or stdout_open or stderr_open) {
        if (!exited) {
            const res = std.posix.waitpid(child.id, std.posix.W.NOHANG);
            if (res.pid == child.id) {
                exited = true;
                status = res.status;
                spawned = false;
            }
        }

        const now = std.time.milliTimestamp();
        if (!exited and !sent_term and (now - started_at >= TIMEOUT_MS or stdout_capped or stderr_capped)) {
            timed_out = now - started_at >= TIMEOUT_MS;
            std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
            sent_term = true;
            term_sent_at = now;
        }
        if (!exited and sent_term and !sent_kill and now - term_sent_at >= SIGTERM_GRACE_MS) {
            std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            sent_kill = true;
        }

        var pollfds = [_]std.posix.pollfd{
            .{ .fd = if (stdout_open) child.stdout.?.handle else -1, .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR, .revents = 0 },
            .{ .fd = if (stderr_open) child.stderr.?.handle else -1, .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR, .revents = 0 },
        };

        if (stdout_open or stderr_open) {
            _ = try std.posix.poll(&pollfds, POLL_INTERVAL_MS);
        } else if (!exited) {
            std.time.sleep(10 * std.time.ns_per_ms);
        }

        if (stdout_open and (pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            if (child.stdout) |*file| {
                stdout_open = try readPipe(file, &stdout, &stdout_capped);
                if (!stdout_open) child.stdout = null;
            }
        }

        if (stderr_open and (pollfds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            if (child.stderr) |*file| {
                stderr_open = try readPipe(file, &stderr, &stderr_capped);
                if (!stderr_open) child.stderr = null;
            }
        }
    }

    if (child.stdout) |*file| file.close();
    child.stdout = null;
    if (child.stderr) |*file| file.close();
    child.stderr = null;

    const stdout_slice = try stdout.toOwnedSlice();
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try stderr.toOwnedSlice();
    errdefer allocator.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .exit_code = exitCode(status),
        .timed_out = timed_out,
        .stdout_capped = stdout_capped,
    };
}

fn readPipe(file: *std.fs.File, output: *std.ArrayList(u8), capped: *bool) !bool {
    var buf: [8192]u8 = undefined;
    const n = try std.posix.read(file.handle, &buf);
    if (n == 0) {
        file.close();
        return false;
    }
    if (output.items.len < RAW_CAPTURE_LIMIT) {
        const remaining = RAW_CAPTURE_LIMIT - output.items.len;
        const take = @min(remaining, n);
        try output.appendSlice(buf[0..take]);
        if (take < n) capped.* = true;
    } else {
        capped.* = true;
    }
    return true;
}

fn exitCode(status: u32) i32 {
    if (std.posix.W.IFEXITED(status)) return std.posix.W.EXITSTATUS(status);
    return -1;
}

fn formatGrepOutput(
    allocator: std.mem.Allocator,
    raw: []const u8,
    workspace_canon: []const u8,
    output_mode: OutputMode,
    max_results: usize,
) ![]u8 {
    return formatLineOutput(allocator, raw, workspace_canon, output_mode, max_results);
}

const ParsedContentLine = struct {
    path: []const u8,
    is_match: bool,
};

const ParsedCountLine = struct {
    path: []const u8,
    count: usize,
};

fn formatLineOutput(
    allocator: std.mem.Allocator,
    raw: []const u8,
    workspace_canon: []const u8,
    output_mode: OutputMode,
    max_results: usize,
) ![]u8 {
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) {
        return allocator.dupe(u8, "No matches found.");
    }

    var lines = std.ArrayList([]u8).init(allocator);
    defer freeOwnedSlices(allocator, &lines);
    var files = std.ArrayList([]u8).init(allocator);
    defer freeOwnedSlices(allocator, &files);

    var total_matches: usize = 0;
    var truncated = false;
    var raw_lines = std.mem.splitScalar(u8, raw, '\n');
    while (raw_lines.next()) |line_with_cr| {
        const line = std.mem.trimRight(u8, line_with_cr, "\r");
        if (line.len == 0) continue;

        const relativized = try relativizePath(allocator, line, workspace_canon);
        var relativized_owned = true;
        errdefer if (relativized_owned) allocator.free(relativized);

        switch (output_mode) {
            .files_with_matches => {
                const path = std.mem.trim(u8, relativized, " \t\r\n");
                if (!containsOwned(files.items, path)) {
                    try appendOwnedDupe(allocator, &files, path);
                    try appendOwnedDupe(allocator, &lines, path);
                }
                allocator.free(relativized);
                relativized_owned = false;
            },
            .count => {
                if (parseCountLine(relativized)) |parsed| {
                    if (parsed.count > 0) {
                        try addUniqueFile(allocator, &files, parsed.path);
                        const formatted = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ parsed.path, parsed.count });
                        try appendOwnedSlice(allocator, &lines, formatted);
                        total_matches += parsed.count;
                    }
                }
                allocator.free(relativized);
                relativized_owned = false;
            },
            .content => {
                if (std.mem.eql(u8, relativized, "--")) {
                    relativized_owned = false;
                    try appendOwnedSlice(allocator, &lines, relativized);
                } else if (parseContentLine(relativized)) |parsed| {
                    try addUniqueFile(allocator, &files, parsed.path);
                    if (parsed.is_match) total_matches += 1;
                    relativized_owned = false;
                    try appendOwnedSlice(allocator, &lines, relativized);
                } else {
                    total_matches += 1;
                    relativized_owned = false;
                    try appendOwnedSlice(allocator, &lines, relativized);
                }
            },
        }

        if (lines.items.len >= max_results) {
            truncated = true;
            break;
        }
    }

    if (lines.items.len == 0) {
        return allocator.dupe(u8, "No matches found.");
    }

    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    for (lines.items, 0..) |line, i| {
        if (i > 0) try output.append('\n');
        try output.appendSlice(line);
    }
    if (truncated) {
        try output.writer().print("\n\n[Results truncated: showing first {d} results]", .{max_results});
    }

    switch (output_mode) {
        .files_with_matches => try output.writer().print("\n\nTotal: {d} files", .{files.items.len}),
        .count => try output.writer().print("\n\nTotal: {d} matches in {d} files", .{ total_matches, files.items.len }),
        .content => try output.writer().print("\n\nTotal: {d} matching lines in {d} files", .{ total_matches, files.items.len }),
    }

    return output.toOwnedSlice();
}

fn freeOwnedSlices(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit();
}

fn containsOwned(items: []const []u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn appendOwnedDupe(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8) !void {
    const copy = try allocator.dupe(u8, value);
    try appendOwnedSlice(allocator, list, copy);
}

fn appendOwnedSlice(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []u8) !void {
    errdefer allocator.free(value);
    try list.append(value);
}

fn addUniqueFile(allocator: std.mem.Allocator, files: *std.ArrayList([]u8), path: []const u8) !void {
    if (!containsOwned(files.items, path)) try appendOwnedDupe(allocator, files, path);
}

fn relativizePath(allocator: std.mem.Allocator, line: []const u8, workspace_prefix: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, line, workspace_prefix)) return allocator.dupe(u8, line);
    var rest = line[workspace_prefix.len..];
    if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
    return allocator.dupe(u8, rest);
}

fn parseContentLine(line: []const u8) ?ParsedContentLine {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == ':' and digitsThen(line, i + 1, ':')) {
            return .{ .path = line[0..i], .is_match = true };
        }
    }

    i = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '-' and digitsThen(line, i + 1, '-')) {
            return .{ .path = line[0..i], .is_match = false };
        }
    }

    return null;
}

fn parseCountLine(line: []const u8) ?ParsedCountLine {
    const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse return null;
    if (colon + 1 >= line.len) return null;
    const count_text = std.mem.trimRight(u8, line[colon + 1 ..], " \t\r\n");
    if (count_text.len == 0) return null;
    for (count_text) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
    }
    const count = std.fmt.parseInt(usize, count_text, 10) catch return null;
    return .{ .path = line[0..colon], .count = count };
}

fn digitsThen(line: []const u8, start: usize, delimiter: u8) bool {
    if (start >= line.len or !std.ascii.isDigit(line[start])) return false;
    var i = start + 1;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    return i < line.len and line[i] == delimiter;
}

fn truncateUtf8(input: []const u8, max_bytes: usize) []const u8 {
    if (input.len <= max_bytes) return input;
    var end = max_bytes;
    while (end > 0 and (input[end] & 0b1100_0000) == 0b1000_0000) {
        end -= 1;
    }
    return input[0..end];
}

fn parseArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

fn expectExecute(json: []const u8, success: bool, output_substr: []const u8, error_substr: ?[]const u8) !void {
    var parsed = try parseArgs(std.testing.allocator, json);
    defer parsed.deinit();

    var tool_impl = ContentSearchTool.init(std.testing.allocator);
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

test "content_search searches content with grep backend" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "alpha\nneedle\nomega\n" });

    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.posix.chdir(dir);
    defer std.posix.fchdir(old_cwd.fd) catch unreachable;

    try expectExecute("{\"pattern\":\"needle\",\"path\":\".\"}", true, "notes.txt:2:needle", null);
}

test "content_search rejects grep multiline and empty pattern" {
    try expectExecute("{\"pattern\":\"needle\",\"multiline\":true}", false, "", "Multiline matching requires ripgrep");
    try expectExecute("{\"pattern\":\"\"}", false, "", "Empty pattern is not allowed.");
}

test "content_search parses grep output modes and relativizes paths" {
    const workspace = "/tmp/work";
    const raw =
        "/tmp/work/src/a.txt:1:alpha\n" ++
        "/tmp/work/src/a.txt-2-beta\n" ++
        "/tmp/work/src/b.txt:3:alpha\n";
    const formatted = try formatGrepOutput(std.testing.allocator, raw, workspace, .content, 100);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "src/a.txt:1:alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Total: 2 matching lines in 2 files") != null);

    const counts = try formatGrepOutput(std.testing.allocator, "/tmp/work/a.txt:2\n/tmp/work/b.txt:0\n", workspace, .count, 100);
    defer std.testing.allocator.free(counts);
    try std.testing.expectEqualStrings("a.txt:2\n\nTotal: 2 matches in 1 files", counts);
}

test "content_search truncates utf8 at character boundary" {
    const text = "ab\xE2\x82\xACcd";
    try std.testing.expectEqualStrings("ab", truncateUtf8(text, 4));
    try std.testing.expectEqualStrings("ab\xE2\x82\xAC", truncateUtf8(text, 5));
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "oom.txt", .data = "needle\n" });

    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.posix.chdir(dir);
    defer std.posix.fchdir(old_cwd.fd) catch unreachable;

    var parsed = try parseArgs(std.testing.allocator, "{\"pattern\":\"needle\",\"path\":\".\"}");
    defer parsed.deinit();
    var tool_impl = ContentSearchTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    var parsed = try parseArgs(std.testing.allocator, "{\"path\":\".\"}");
    defer parsed.deinit();
    var tool_impl = ContentSearchTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    var tool_impl = ContentSearchTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var value = try tool_impl.tool().parametersSchema(allocator);
    defer @import("../tool_call_parser/types.zig").freeJsonValue(allocator, &value);
}

test "content_search execute and parametersSchema are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}
