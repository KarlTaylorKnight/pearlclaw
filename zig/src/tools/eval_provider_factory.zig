//! eval-provider-factory — trimmed provider factory parity runner.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const factory = zeroclaw.providers.factory;

const EvalError = error{InvalidScenario};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.io.getStdIn().readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(input);

    const stdout = std.io.getStdOut().writer();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        try runOp(allocator, line, stdout);
    }
}

fn runOp(allocator: std.mem.Allocator, line: []const u8, writer: anytype) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const op = getString(parsed.value, "op") orelse return EvalError.InvalidScenario;
    if (!std.mem.eql(u8, op, "create")) return EvalError.InvalidScenario;

    const name = getString(parsed.value, "name") orelse return EvalError.InvalidScenario;
    const api_key = getOptionalString(parsed.value, "api_key");
    const url = getOptionalString(parsed.value, "url");

    if (factory.createProviderWithUrl(allocator, name, api_key, url)) |handle_value| {
        var handle = handle_value;
        defer handle.deinit(allocator);
        try writer.writeAll("{\"op\":\"create\",\"result\":{\"ok\":true,\"provider_name\":");
        try std.json.stringify(handle.providerName(), .{}, writer);
        try writer.writeAll("}}\n");
    } else |err| {
        try writer.writeAll("{\"op\":\"create\",\"result\":{\"ok\":false,\"error\":");
        try std.json.stringify(errorTag(err), .{}, writer);
        try writer.writeAll("}}\n");
    }
}

fn errorTag(err: anyerror) []const u8 {
    return switch (err) {
        factory.FactoryError.ProviderNotSupported => "provider_not_supported",
        factory.FactoryError.ApiKeyPrefixMismatch => "api_key_prefix_mismatch",
        factory.FactoryError.MissingApiKey => "missing_api_key",
        else => "out_of_memory",
    };
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const inner = value.object.get(key) orelse return null;
    if (inner != .string) return null;
    return inner.string;
}

fn getOptionalString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const inner = value.object.get(key) orelse return null;
    return switch (inner) {
        .string => inner.string,
        .null => null,
        else => null,
    };
}
