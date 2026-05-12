//! Shared subprocess helpers for agent_tools ports.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: i32,
    timed_out: bool,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const RunOpts = struct {
    timeout_ns: u64,
    max_pipe_bytes: usize,
    /// Env var names to forward from the parent process to the child.
    /// Anything not in this list is excluded (env_clear semantics).
    env_keys: []const []const u8,
};

/// Run an external command with a hard timeout, capturing stdout+stderr.
/// On timeout: SIGKILL the child, wait to reap, return with `timed_out=true`.
/// On stdout/stderr exceeding `max_pipe_bytes`: SIGKILL + wait, return
/// `error.StdoutStreamTooLong` / `error.StderrStreamTooLong`.
/// Exit codes: caller interprets -- 0/1/2+ semantics belong to the caller.
pub fn runWithTimeout(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    opts: RunOpts,
) !RunResult {
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    for (opts.env_keys) |key| {
        if (std.process.getEnvVarOwned(allocator, key)) |val| {
            defer allocator.free(val);
            try env_map.put(key, val);
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            error.OutOfMemory => return err,
            else => {},
        }
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = &env_map;
    try child.spawn();
    var child_running = true;
    errdefer if (child_running) {
        posix.kill(child.id, posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
    };

    const Pipe = enum { stdout, stderr };
    var poller = std.io.poll(allocator, Pipe, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(opts.timeout_ns));
    var timed_out = false;
    while (true) {
        const now = std.time.nanoTimestamp();
        if (now >= deadline) {
            timed_out = true;
            break;
        }
        const remaining: u64 = @intCast(deadline - now);
        const had_event = try poller.pollTimeout(remaining);
        if (!had_event) break;
        if (poller.fifo(.stdout).count > opts.max_pipe_bytes) {
            posix.kill(child.id, posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
            child_running = false;
            return error.StdoutStreamTooLong;
        }
        if (poller.fifo(.stderr).count > opts.max_pipe_bytes) {
            posix.kill(child.id, posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
            child_running = false;
            return error.StderrStreamTooLong;
        }
    }

    const so_fifo = poller.fifo(.stdout);
    const se_fifo = poller.fifo(.stderr);
    if (so_fifo.head != 0) so_fifo.realign();
    if (se_fifo.head != 0) se_fifo.realign();
    const stdout_owned = try allocator.dupe(u8, so_fifo.buf[0..so_fifo.count]);
    errdefer allocator.free(stdout_owned);
    const stderr_owned = try allocator.dupe(u8, se_fifo.buf[0..se_fifo.count]);
    errdefer allocator.free(stderr_owned);

    if (timed_out) {
        posix.kill(child.id, posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
        child_running = false;
        return .{
            .stdout = stdout_owned,
            .stderr = stderr_owned,
            .exit_code = -1,
            .timed_out = true,
        };
    }

    const term = try child.wait();
    child_running = false;
    const exit_code: i32 = switch (term) {
        .Exited => |code| @intCast(code),
        else => -1,
    };
    return .{
        .stdout = stdout_owned,
        .stderr = stderr_owned,
        .exit_code = exit_code,
        .timed_out = false,
    };
}

/// Walk PATH and return the first executable absolute path matching `name`.
/// Caller owns the returned path. Returns null if no executable is found.
pub fn findExecutableOnPath(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const path_value = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        error.OutOfMemory => return err,
        else => return null,
    };
    defer allocator.free(path_value);
    if (path_value.len == 0) return null;

    const delimiter: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var parts = std.mem.splitScalar(u8, path_value, delimiter);
    while (parts.next()) |part| {
        const dir = if (part.len == 0) "." else part;
        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(candidate);

        posix.access(candidate, posix.X_OK) catch continue;
        if (std.fs.path.isAbsolute(candidate)) return @as(?[]u8, try allocator.dupe(u8, candidate));
        return @as(?[]u8, try std.fs.cwd().realpathAlloc(allocator, candidate));
    }
    return null;
}

test "process_common findExecutableOnPath returns absolute executable path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("bin");
    var file = try tmp.dir.createFile("bin/demo-tool", .{ .truncate = true, .mode = 0o755 });
    try file.writeAll("#!/bin/sh\necho ok\n");
    try file.chmod(0o755);
    file.close();

    const bin = try tmp.dir.realpathAlloc(std.testing.allocator, "bin");
    defer std.testing.allocator.free(bin);
    const original_path = std.process.getEnvVarOwned(std.testing.allocator, "PATH") catch null;
    defer if (original_path) |value| std.testing.allocator.free(value);
    try setEnvForTest("PATH", bin);
    defer restoreEnvForTest("PATH", original_path);

    const found = (try findExecutableOnPath(std.testing.allocator, "demo-tool")).?;
    defer std.testing.allocator.free(found);
    try std.testing.expect(std.fs.path.isAbsolute(found));
    try std.testing.expect(std.mem.endsWith(u8, found, "/demo-tool"));
}

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
