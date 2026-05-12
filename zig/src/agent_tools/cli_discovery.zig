//! CLI tool auto-discovery port of `zeroclaw-tools/src/cli_discovery.rs`.

const std = @import("std");
const process_common = @import("process_common.zig");

const VERSION_TIMEOUT_NS: u64 = 5 * std.time.ns_per_s;
const VERSION_MAX_PIPE_BYTES: usize = 64 * 1024;
const VERSION_ENV_KEYS = &.{"PATH"};

pub const CliCategory = enum {
    version_control,
    language,
    package_manager,
    container,
    build,
    cloud,
    ai_agent,
    productivity,

    pub fn serializeName(self: CliCategory) []const u8 {
        return switch (self) {
            .version_control => "VersionControl",
            .language => "Language",
            .package_manager => "PackageManager",
            .container => "Container",
            .build => "Build",
            .cloud => "Cloud",
            .ai_agent => "AiAgent",
            .productivity => "Productivity",
        };
    }

    pub fn displayName(self: CliCategory) []const u8 {
        return switch (self) {
            .version_control => "Version Control",
            .language => "Language",
            .package_manager => "Package Manager",
            .container => "Container",
            .build => "Build",
            .cloud => "Cloud",
            .ai_agent => "AI Agent",
            .productivity => "Productivity",
        };
    }
};

pub const DiscoveredCli = struct {
    name: []u8,
    path: []u8,
    version: ?[]u8,
    category: CliCategory,

    pub fn deinit(self: *DiscoveredCli, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        if (self.version) |version| allocator.free(version);
    }
};

const KnownCli = struct {
    name: []const u8,
    version_args: []const []const u8,
    category: CliCategory,
};

const KNOWN_CLIS = [_]KnownCli{
    .{ .name = "git", .version_args = &.{"--version"}, .category = .version_control },
    .{ .name = "python", .version_args = &.{"--version"}, .category = .language },
    .{ .name = "python3", .version_args = &.{"--version"}, .category = .language },
    .{ .name = "node", .version_args = &.{"--version"}, .category = .language },
    .{ .name = "npm", .version_args = &.{"--version"}, .category = .package_manager },
    .{ .name = "pip", .version_args = &.{"--version"}, .category = .package_manager },
    .{ .name = "pip3", .version_args = &.{"--version"}, .category = .package_manager },
    .{ .name = "docker", .version_args = &.{"--version"}, .category = .container },
    .{ .name = "cargo", .version_args = &.{"--version"}, .category = .build },
    .{ .name = "make", .version_args = &.{"--version"}, .category = .build },
    .{ .name = "kubectl", .version_args = &.{ "version", "--client", "--short" }, .category = .cloud },
    .{ .name = "rustc", .version_args = &.{"--version"}, .category = .language },
    .{ .name = "claude", .version_args = &.{"--version"}, .category = .ai_agent },
    .{ .name = "gemini", .version_args = &.{"--version"}, .category = .ai_agent },
    .{ .name = "kilo", .version_args = &.{"--version"}, .category = .ai_agent },
    .{ .name = "gws", .version_args = &.{"--version"}, .category = .productivity },
};

/// Mirror of Rust `discover_cli_tools`. Caller owns the returned slice and
/// each DiscoveredCli's owned fields.
pub fn discoverCliTools(
    allocator: std.mem.Allocator,
    additional: []const []const u8,
    excluded: []const []const u8,
) ![]DiscoveredCli {
    var results = std.ArrayList(DiscoveredCli).init(allocator);
    errdefer {
        for (results.items) |*result| result.deinit(allocator);
        results.deinit();
    }

    for (KNOWN_CLIS) |known| {
        if (containsString(excluded, known.name)) continue;
        if (try probeCli(allocator, known.name, known.version_args, known.category)) |cli| {
            try appendDiscovered(allocator, &results, cli);
        }
    }

    for (additional) |tool_name| {
        if (containsString(excluded, tool_name)) continue;
        if (containsDiscoveredName(results.items, tool_name)) continue;
        if (try probeCli(allocator, tool_name, &.{"--version"}, .build)) |cli| {
            try appendDiscovered(allocator, &results, cli);
        }
    }

    return results.toOwnedSlice();
}

fn appendDiscovered(
    allocator: std.mem.Allocator,
    results: *std.ArrayList(DiscoveredCli),
    cli: DiscoveredCli,
) !void {
    var owned = cli;
    errdefer owned.deinit(allocator);
    try results.append(owned);
}

fn probeCli(
    allocator: std.mem.Allocator,
    name: []const u8,
    version_args: []const []const u8,
    category: CliCategory,
) !?DiscoveredCli {
    const path = (try process_common.findExecutableOnPath(allocator, name)) orelse return null;
    errdefer allocator.free(path);

    const version = try getVersion(allocator, name, version_args);
    errdefer if (version) |inner| allocator.free(inner);

    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);

    return .{
        .name = name_owned,
        .path = path,
        .version = version,
        .category = category,
    };
}

fn getVersion(
    allocator: std.mem.Allocator,
    name: []const u8,
    args: []const []const u8,
) !?[]u8 {
    var argv_buf: [8][]const u8 = undefined;
    if (args.len + 1 > argv_buf.len) return null;
    argv_buf[0] = name;
    for (args, 0..) |arg, idx| argv_buf[idx + 1] = arg;

    var result = process_common.runWithTimeout(allocator, argv_buf[0 .. args.len + 1], .{
        .timeout_ns = VERSION_TIMEOUT_NS,
        .max_pipe_bytes = VERSION_MAX_PIPE_BYTES,
        .env_keys = VERSION_ENV_KEYS,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer result.deinit(allocator);

    if (result.timed_out) return null;
    return extractVersionLine(allocator, result.stdout, result.stderr);
}

fn extractVersionLine(
    allocator: std.mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
) !?[]u8 {
    const stdout_trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    const text = if (stdout_trimmed.len == 0)
        std.mem.trim(u8, stderr, " \t\r\n")
    else
        stdout_trimmed;
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first_raw = lines.next() orelse return null;
    const first = std.mem.trim(u8, first_raw, " \t\r\n");
    if (first.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, first));
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn containsDiscoveredName(items: []const DiscoveredCli, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, needle)) return true;
    }
    return false;
}

fn deinitDiscoveredSlice(allocator: std.mem.Allocator, items: []DiscoveredCli) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

test "cli_discovery category names match Rust serialize and Display forms" {
    try std.testing.expectEqualStrings("VersionControl", CliCategory.version_control.serializeName());
    try std.testing.expectEqualStrings("Version Control", CliCategory.version_control.displayName());
    try std.testing.expectEqualStrings("PackageManager", CliCategory.package_manager.serializeName());
    try std.testing.expectEqualStrings("Package Manager", CliCategory.package_manager.displayName());
    try std.testing.expectEqualStrings("AiAgent", CliCategory.ai_agent.serializeName());
    try std.testing.expectEqualStrings("AI Agent", CliCategory.ai_agent.displayName());
}

test "cli_discovery discovers known tools in known-list order" {
    var env = try TempPathEnv.init();
    defer env.deinit();
    try env.writeScript("git", "#!/bin/sh\necho 'git version 2.42.0'\n");
    try env.writeScript("python3", "#!/bin/sh\necho 'Python 3.12.0'\n");
    try env.writeScript("cargo", "#!/bin/sh\necho 'cargo 1.95.0'\n");

    const results = try discoverCliTools(std.testing.allocator, &.{}, &.{});
    defer deinitDiscoveredSlice(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("git", results[0].name);
    try std.testing.expectEqualStrings("python3", results[1].name);
    try std.testing.expectEqualStrings("cargo", results[2].name);
    try std.testing.expectEqualStrings("git version 2.42.0", results[0].version.?);
}

test "cli_discovery additional tools use Build category and skip duplicates" {
    var env = try TempPathEnv.init();
    defer env.deinit();
    try env.writeScript("git", "#!/bin/sh\necho 'git version 2.42.0'\n");
    try env.writeScript("mytool", "#!/bin/sh\necho 'mytool 1.0.0'\n");

    const results = try discoverCliTools(std.testing.allocator, &.{ "git", "mytool" }, &.{});
    defer deinitDiscoveredSlice(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("git", results[0].name);
    try std.testing.expectEqualStrings("mytool", results[1].name);
    try std.testing.expectEqual(CliCategory.build, results[1].category);
}

test "cli_discovery captures stderr versions and empty version as null" {
    var env = try TempPathEnv.init();
    defer env.deinit();
    try env.writeScript("pip", "#!/bin/sh\necho 'pip 24.0' >&2\n");
    try env.writeScript("node", "#!/bin/sh\nexit 0\n");

    const results = try discoverCliTools(std.testing.allocator, &.{}, &.{});
    defer deinitDiscoveredSlice(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("node", results[0].name);
    try std.testing.expect(results[0].version == null);
    try std.testing.expectEqualStrings("pip", results[1].name);
    try std.testing.expectEqualStrings("pip 24.0", results[1].version.?);
}

fn discoverHappyOomImpl(allocator: std.mem.Allocator) !void {
    var env = try TempPathEnv.init();
    defer env.deinit();
    try env.writeScript("git", "#!/bin/sh\necho 'git version 2.42.0'\n");

    const results = try discoverCliTools(allocator, &.{}, &.{});
    defer deinitDiscoveredSlice(allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
}

fn discoverErrorOomImpl(allocator: std.mem.Allocator) !void {
    const original_path = std.process.getEnvVarOwned(std.testing.allocator, "PATH") catch null;
    defer if (original_path) |value| std.testing.allocator.free(value);
    try setEnvForTest("PATH", "");
    defer restoreEnvForTest("PATH", original_path);

    const results = try discoverCliTools(allocator, &.{}, &.{});
    defer deinitDiscoveredSlice(allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "cli_discovery is OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, discoverHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, discoverErrorOomImpl, .{});
}

const TempPathEnv = struct {
    tmp: std.testing.TmpDir,
    bin: []u8,
    original_path: ?[]u8,

    fn init() !TempPathEnv {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.makeDir("bin");
        const bin = try tmp.dir.realpathAlloc(std.testing.allocator, "bin");
        errdefer std.testing.allocator.free(bin);
        const original_path = std.process.getEnvVarOwned(std.testing.allocator, "PATH") catch null;
        errdefer if (original_path) |value| std.testing.allocator.free(value);
        try setEnvForTest("PATH", bin);
        return .{ .tmp = tmp, .bin = bin, .original_path = original_path };
    }

    fn deinit(self: *TempPathEnv) void {
        restoreEnvForTest("PATH", self.original_path);
        if (self.original_path) |value| std.testing.allocator.free(value);
        std.testing.allocator.free(self.bin);
        self.tmp.cleanup();
    }

    fn writeScript(self: *TempPathEnv, name: []const u8, content: []const u8) !void {
        const path = try std.fmt.allocPrint(std.testing.allocator, "bin/{s}", .{name});
        defer std.testing.allocator.free(path);
        var file = try self.tmp.dir.createFile(path, .{ .truncate = true, .mode = 0o755 });
        defer file.close();
        try file.writeAll(content);
        try file.chmod(0o755);
    }
};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setEnvForTest(name: []const u8, value: []const u8) !void {
    const name_z = try std.testing.allocator.dupeZ(u8, name);
    defer std.testing.allocator.free(name_z);
    const value_z = try std.testing.allocator.dupeZ(u8, value);
    defer std.testing.allocator.free(value_z);
    if (setenv(name_z.ptr, value_z.ptr, 1) != 0) return error.Unexpected;
}

fn restoreEnvForTest(name: []const u8, value: ?[]const u8) void {
    const name_z = std.testing.allocator.dupeZ(u8, name) catch return;
    defer std.testing.allocator.free(name_z);
    if (value) |inner| {
        const value_z = std.testing.allocator.dupeZ(u8, inner) catch return;
        defer std.testing.allocator.free(value_z);
        _ = setenv(name_z.ptr, value_z.ptr, 1);
    } else {
        _ = unsetenv(name_z.ptr);
    }
}
