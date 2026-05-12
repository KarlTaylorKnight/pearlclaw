//! ContentSearchTool port of `zeroclaw-tools/src/content_search.rs`.

const std = @import("std");
const common = @import("fs_common.zig");
const process_common = @import("process_common.zig");
const security_stub = @import("security_stub.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;
pub const SecurityStub = security_stub.SecurityStub;

const NAME = "content_search";
const DESCRIPTION =
    "Search file contents by regex pattern within the workspace. " ++
    "Supports ripgrep (rg) with grep fallback. " ++
    "Output modes: 'content' (matching lines with context), " ++
    "'files_with_matches' (file paths only), 'count' (match counts per file). " ++
    "Example: pattern='fn main', include='*.rs', output_mode='content'.";

const MAX_RESULTS: usize = 1000;
const MAX_OUTPUT_BYTES: usize = 1_048_576;
const TIMEOUT_SECS: u64 = 30;
const TIMEOUT_NS: u64 = TIMEOUT_SECS * std.time.ns_per_s;
const MAX_PIPE_BYTES: usize = 4 * 1024 * 1024;

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": {
    \\      "type": "string",
    \\      "description": "Regular expression pattern to search for"
    \\    },
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Directory to search in, relative to workspace root. Defaults to '.'",
    \\      "default": "."
    \\    },
    \\    "output_mode": {
    \\      "type": "string",
    \\      "description": "Output format: 'content' (matching lines), 'files_with_matches' (paths only), 'count' (match counts)",
    \\      "enum": ["content", "files_with_matches", "count"],
    \\      "default": "content"
    \\    },
    \\    "include": {
    \\      "type": "string",
    \\      "description": "File glob filter, e.g. '*.rs', '*.{ts,tsx}'"
    \\    },
    \\    "case_sensitive": {
    \\      "type": "boolean",
    \\      "description": "Case-sensitive matching. Defaults to true",
    \\      "default": true
    \\    },
    \\    "context_before": {
    \\      "type": "integer",
    \\      "description": "Lines of context before each match (content mode only)",
    \\      "default": 0
    \\    },
    \\    "context_after": {
    \\      "type": "integer",
    \\      "description": "Lines of context after each match (content mode only)",
    \\      "default": 0
    \\    },
    \\    "multiline": {
    \\      "type": "boolean",
    \\      "description": "Enable multiline matching (ripgrep only, errors on grep fallback)",
    \\      "default": false
    \\    },
    \\    "max_results": {
    \\      "type": "integer",
    \\      "description": "Maximum number of results to return. Defaults to 1000",
    \\      "default": 1000
    \\    }
    \\  },
    \\  "required": ["pattern"]
    \\}
;

pub const ContentSearchTool = struct {
    security: ?SecurityStub,
    has_rg: bool,
    mock_stdout: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) ContentSearchTool {
        const rg_path = process_common.findExecutableOnPath(allocator, "rg") catch null;
        if (rg_path) |path| allocator.free(path);
        return .{
            .security = null,
            .has_rg = rg_path != null,
            .mock_stdout = null,
        };
    }

    pub fn initWithBackend(security: SecurityStub, has_rg: bool) ContentSearchTool {
        return .{ .security = security, .has_rg = has_rg, .mock_stdout = null };
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
        const self: *ContentSearchTool = @ptrCast(@alignCast(ptr));
        return common.resultFromReturn(allocator, try self.dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ContentSearchTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }

    fn dispatch(self: *ContentSearchTool, allocator: std.mem.Allocator, args: std.json.Value) !common.FsReturn {
        if (self.security) |*security| {
            return dispatchWithSecurity(allocator, args, security, self.has_rg, self.mock_stdout);
        }

        const workspace_canon = std.fs.cwd().realpathAlloc(allocator, ".") catch |err| {
            return common.failureFmt(allocator, "Cannot resolve path '.': {s}", .{common.rustIoError(err)});
        };
        defer allocator.free(workspace_canon);

        var security = SecurityStub{ .workspace_dir = workspace_canon };
        return dispatchWithSecurity(allocator, args, &security, self.has_rg, self.mock_stdout);
    }
};

const OutputMode = enum {
    content,
    files_with_matches,
    count,
};

fn dispatchWithSecurity(
    allocator: std.mem.Allocator,
    args: std.json.Value,
    security: *SecurityStub,
    has_rg: bool,
    mock_stdout: ?[]const u8,
) !common.FsReturn {
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

    if (security.isRateLimited()) {
        return common.failure(allocator, "Rate limit exceeded: too many actions in the last hour");
    }

    if (std.fs.path.isAbsolute(search_path) and !security.isUnderAllowedRoot(search_path)) {
        return common.failure(allocator, "Absolute paths are not allowed. Use a relative path.");
    }

    if (std.mem.eql(u8, search_path, "..") or
        std.mem.indexOf(u8, search_path, "../") != null or
        std.mem.indexOf(u8, search_path, "..\\") != null)
    {
        return common.failure(allocator, "Path traversal ('..') is not allowed.");
    }

    if (!security.isPathAllowed(search_path)) {
        return common.failureFmt(allocator, "Path '{s}' is not allowed by security policy.", .{search_path});
    }

    if (!security.recordAction()) {
        return common.failure(allocator, "Rate limit exceeded: action budget exhausted");
    }

    const resolved_path = try security.resolveToolPath(allocator, search_path);
    defer allocator.free(resolved_path);

    const resolved_canon = std.fs.cwd().realpathAlloc(allocator, resolved_path) catch |err| {
        return common.failureFmt(allocator, "Cannot resolve path '{s}': {s}", .{ search_path, common.rustIoError(err) });
    };
    defer allocator.free(resolved_canon);

    if (!security.isResolvedPathAllowed(resolved_canon)) {
        return common.failureFmt(
            allocator,
            "Resolved path for '{s}' is outside the allowed workspace.",
            .{search_path},
        );
    }

    if (multiline and !has_rg) {
        return common.failure(allocator, "Multiline matching requires ripgrep (rg), which is not available.");
    }

    const workspace_canon = std.fs.cwd().realpathAlloc(allocator, security.workspace_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try allocator.dupe(u8, security.workspace_dir),
    };
    defer allocator.free(workspace_canon);

    var command = CommandArgs.init(allocator);
    defer command.deinit();
    if (has_rg) {
        try buildRgCommand(
            &command,
            pattern,
            resolved_canon,
            output_mode,
            include,
            case_sensitive,
            context_before,
            context_after,
            multiline,
        );
    } else {
        try buildGrepCommand(
            &command,
            pattern,
            resolved_canon,
            output_mode,
            include,
            case_sensitive,
            context_before,
            context_after,
        );
    }

    if (mock_stdout) |raw| {
        return formatSearchOutput(allocator, raw, workspace_canon, output_mode, max_results, has_rg);
    }

    var process = process_common.runWithTimeout(allocator, command.argv.items, .{
        .timeout_ns = TIMEOUT_NS,
        .max_pipe_bytes = MAX_PIPE_BYTES,
        .env_keys = &.{ "PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE" },
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return common.failureFmt(allocator, "Failed to execute search command: {s}", .{@errorName(err)}),
    };
    defer process.deinit(allocator);

    if (process.timed_out) {
        return common.failure(allocator, "Search timed out after 30 seconds.");
    }

    if (process.exit_code >= 2 or process.exit_code < 0) {
        const stderr_trimmed = std.mem.trim(u8, process.stderr, " \t\r\n");
        return common.failureFmt(allocator, "Search error: {s}", .{stderr_trimmed});
    }

    return formatSearchOutput(allocator, process.stdout, workspace_canon, output_mode, max_results, has_rg);
}

fn formatSearchOutput(
    allocator: std.mem.Allocator,
    raw_stdout: []const u8,
    workspace_canon: []const u8,
    output_mode: OutputMode,
    max_results: usize,
    has_rg: bool,
) !common.FsReturn {
    const formatted = if (has_rg)
        try formatRgOutput(allocator, raw_stdout, workspace_canon, output_mode, max_results)
    else
        try formatGrepOutput(allocator, raw_stdout, workspace_canon, output_mode, max_results);
    errdefer allocator.free(formatted);

    if (formatted.len > MAX_OUTPUT_BYTES) {
        const trimmed = truncateUtf8(formatted, MAX_OUTPUT_BYTES);
        var final_output = std.ArrayList(u8).init(allocator);
        errdefer final_output.deinit();
        try final_output.appendSlice(trimmed);
        try final_output.appendSlice("\n\n[Output truncated: exceeded 1 MB limit]");
        const owned = try final_output.toOwnedSlice();
        allocator.free(formatted);
        return .{ .output = owned };
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

fn buildRgCommand(
    command: *CommandArgs,
    pattern: []const u8,
    search_path: []const u8,
    output_mode: OutputMode,
    include: ?[]const u8,
    case_sensitive: bool,
    context_before: usize,
    context_after: usize,
    multiline: bool,
) !void {
    try command.append("rg");
    try command.append("--no-heading");
    try command.append("--line-number");
    try command.append("--with-filename");

    switch (output_mode) {
        .files_with_matches => try command.append("--files-with-matches"),
        .count => try command.append("--count"),
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
    if (multiline) {
        try command.append("-U");
        try command.append("--multiline-dotall");
    }
    if (include) |glob| {
        try command.append("--glob");
        try command.append(glob);
    }
    try command.append("--");
    try command.append(pattern);
    try command.append(search_path);
}

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

fn formatRgOutput(
    allocator: std.mem.Allocator,
    raw: []const u8,
    workspace_canon: []const u8,
    output_mode: OutputMode,
    max_results: usize,
) ![]u8 {
    return formatLineOutput(allocator, raw, workspace_canon, output_mode, max_results);
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

fn expectExecute(
    json: []const u8,
    security: SecurityStub,
    has_rg: bool,
    success: bool,
    output_substr: []const u8,
    error_substr: ?[]const u8,
) !void {
    var parsed = try parseArgs(std.testing.allocator, json);
    defer parsed.deinit();

    var tool_impl = ContentSearchTool.initWithBackend(security, has_rg);
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
    try expectExecute(
        "{\"pattern\":\"needle\",\"path\":\".\"}",
        .{ .workspace_dir = dir },
        false,
        true,
        "notes.txt:2:needle",
        null,
    );
}

test "content_search rejects security failures in Rust order" {
    try expectExecute(
        "{\"pattern\":\"\"}",
        .{ .workspace_dir = "." },
        false,
        false,
        "",
        "Empty pattern is not allowed.",
    );
    try expectExecute(
        "{\"pattern\":\"needle\"}",
        .{ .workspace_dir = ".", .rate_limited = true },
        false,
        false,
        "",
        "Rate limit exceeded: too many actions in the last hour",
    );
    try expectExecute(
        "{\"pattern\":\"needle\",\"path\":\"/etc\"}",
        .{ .workspace_dir = "." },
        false,
        false,
        "",
        "Absolute paths are not allowed. Use a relative path.",
    );
    try expectExecute(
        "{\"pattern\":\"needle\",\"path\":\"../../../etc\"}",
        .{ .workspace_dir = "." },
        false,
        false,
        "",
        "Path traversal ('..') is not allowed.",
    );
}

test "content_search rejects grep multiline and budget exhaustion" {
    const cwd = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    try expectExecute(
        "{\"pattern\":\"needle\",\"multiline\":true}",
        .{ .workspace_dir = cwd },
        false,
        false,
        "",
        "Multiline matching requires ripgrep",
    );
    try expectExecute(
        "{\"pattern\":\"needle\"}",
        .{ .workspace_dir = ".", .action_budget = 0 },
        false,
        false,
        "",
        "Rate limit exceeded: action budget exhausted",
    );
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

test "content_search parses count paths with colons" {
    const parsed = parseCountLine("dir:with:colon/file.rs:12").?;
    try std.testing.expectEqualStrings("dir:with:colon/file.rs", parsed.path);
    try std.testing.expectEqual(@as(usize, 12), parsed.count);
}

test "content_search truncates utf8 at character boundary" {
    try std.testing.expectEqualStrings("abc", truncateUtf8("abc你好", 4));
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "oom.txt", .data = "needle\n" });

    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var parsed = try parseArgs(std.testing.allocator, "{\"pattern\":\"needle\",\"path\":\".\"}");
    defer parsed.deinit();

    var tool_impl = ContentSearchTool.initWithBackend(.{ .workspace_dir = dir }, false);
    tool_impl.mock_stdout = "oom.txt:1:needle\n";
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    var parsed = try parseArgs(std.testing.allocator, "{\"pattern\":\"\"}");
    defer parsed.deinit();
    var tool_impl = ContentSearchTool.initWithBackend(.{ .workspace_dir = "." }, false);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    var tool_impl = ContentSearchTool.initWithBackend(.{ .workspace_dir = "." }, false);
    defer tool_impl.deinit(allocator);
    var value = try tool_impl.tool().parametersSchema(allocator);
    defer @import("../tool_call_parser/types.zig").freeJsonValue(allocator, &value);
}

test "content_search execute and parametersSchema are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}
