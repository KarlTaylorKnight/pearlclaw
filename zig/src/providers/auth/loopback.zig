const std = @import("std");

pub const LOOPBACK_PORT: u16 = 1455;
pub const SUCCESS_BODY = "<html><body><h2>ZeroClaw login complete</h2><p>You can close this tab.</p></body></html>";

pub const LoopbackRequest = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    path: []u8,

    pub fn deinit(self: *LoopbackRequest) void {
        self.stream.close();
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn writeSuccessResponse(self: *LoopbackRequest) !void {
        try self.stream.writer().print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ SUCCESS_BODY.len, SUCCESS_BODY },
        );
    }
};

pub fn parseLoopbackRequestPath(input: []const u8) ![]const u8 {
    const line_end = std.mem.indexOfScalar(u8, input, '\n') orelse input.len;
    var first_line = input[0..line_end];
    if (first_line.len > 0 and first_line[first_line.len - 1] == '\r') {
        first_line = first_line[0 .. first_line.len - 1];
    }

    var cursor: usize = 0;
    _ = nextAsciiWhitespaceToken(first_line, &cursor) orelse return error.InvalidLoopbackRequest;
    return nextAsciiWhitespaceToken(first_line, &cursor) orelse error.InvalidLoopbackRequest;
}

pub fn receiveLoopbackRequest(allocator: std.mem.Allocator, timeout_ms: u64) !LoopbackRequest {
    const address = try std.net.Address.parseIp4("127.0.0.1", LOOPBACK_PORT);
    var server = try address.listen(.{
        .reuse_address = true,
        .kernel_backlog = 1,
        .force_nonblocking = true,
    });
    defer server.deinit();

    const start_ms = std.time.milliTimestamp();
    while (true) {
        const remaining_ms = remainingTimeoutMs(start_ms, timeout_ms) orelse return error.OAuthLoopbackTimeout;
        const accepted = server.accept() catch |err| switch (err) {
            error.WouldBlock => {
                const sleep_ms: u64 = @min(remaining_ms, @as(u64, 10));
                if (sleep_ms == 0) return error.OAuthLoopbackTimeout;
                std.time.sleep(sleep_ms * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };

        errdefer accepted.stream.close();
        try setStreamTimeouts(accepted.stream, @max(remaining_ms, 1));

        var buffer: [8192]u8 = undefined;
        const bytes_read = accepted.stream.read(&buffer) catch |err| switch (err) {
            error.WouldBlock => return error.OAuthLoopbackTimeout,
            else => return err,
        };
        const path = parseLoopbackRequestPath(buffer[0..bytes_read]) catch return error.InvalidLoopbackRequest;
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        return .{
            .allocator = allocator,
            .stream = accepted.stream,
            .path = owned_path,
        };
    }
}

fn nextAsciiWhitespaceToken(line: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < line.len and isAsciiTokenWhitespace(line[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= line.len) return null;

    const start = cursor.*;
    while (cursor.* < line.len and !isAsciiTokenWhitespace(line[cursor.*])) {
        cursor.* += 1;
    }
    return line[start..cursor.*];
}

fn isAsciiTokenWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn remainingTimeoutMs(start_ms: i64, timeout_ms: u64) ?u64 {
    const now_ms = std.time.milliTimestamp();
    const elapsed_ms: u64 = if (now_ms <= start_ms) 0 else @intCast(now_ms - start_ms);
    if (elapsed_ms >= timeout_ms) return null;
    return timeout_ms - elapsed_ms;
}

fn setStreamTimeouts(stream: std.net.Stream, timeout_ms: u64) !void {
    var tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    for ([_]u32{ std.posix.SO.RCVTIMEO, std.posix.SO.SNDTIMEO }) |optname| {
        try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, optname, std.mem.asBytes(&tv));
    }
}

test "parseLoopbackRequestPath extracts the second request-line token" {
    try std.testing.expectEqualStrings(
        "/auth/callback?code=x&state=y",
        try parseLoopbackRequestPath("GET /auth/callback?code=x&state=y HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"),
    );
    try std.testing.expectEqualStrings(
        "/auth/callback",
        try parseLoopbackRequestPath("GET /auth/callback HTTP/1.1\r\n"),
    );
    try std.testing.expectEqualStrings(
        "/auth/callback?code=lower&state=s",
        try parseLoopbackRequestPath("get\t/auth/callback?code=lower&state=s\tHTTP/1.1\r\n"),
    );
}

test "parseLoopbackRequestPath rejects malformed request lines" {
    try std.testing.expectError(error.InvalidLoopbackRequest, parseLoopbackRequestPath(""));
    try std.testing.expectError(error.InvalidLoopbackRequest, parseLoopbackRequestPath("\n"));
    try std.testing.expectError(error.InvalidLoopbackRequest, parseLoopbackRequestPath("GET\r\n"));
}
