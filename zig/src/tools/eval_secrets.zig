const std = @import("std");
const zeroclaw = @import("zeroclaw");
const secrets = zeroclaw.api.secrets;

const EvalError = error{InvalidScenario};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.io.getStdIn().readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(input);

    const stdout = std.io.getStdOut().writer();
    var lines = std.mem.splitScalar(u8, input, '\n');
    var index: usize = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        try runOp(allocator, line, stdout, index);
        index += 1;
    }
}

fn runOp(allocator: std.mem.Allocator, line: []const u8, writer: anytype, index: usize) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const op = getString(parsed.value, "op") orelse return EvalError.InvalidScenario;

    if (std.mem.eql(u8, op, "decrypt_passthrough")) {
        const value = getString(parsed.value, "value") orelse return EvalError.InvalidScenario;
        const state_dir = try makeTempStateDir(allocator, index);
        defer cleanupTempStateDir(allocator, state_dir);
        var store = try secrets.SecretStore.new(allocator, state_dir, true);
        defer store.deinit();
        const plaintext = try store.decrypt(value);
        defer allocator.free(plaintext);
        try writer.writeAll("{\"op\":\"decrypt_passthrough\",\"result\":{\"plaintext\":");
        try std.json.stringify(plaintext, .{}, writer);
        try writer.writeAll("}}\n");
        return;
    }

    const key_hex = getString(parsed.value, "key_hex") orelse return EvalError.InvalidScenario;
    const state_dir = try makeTempStateDir(allocator, index);
    defer cleanupTempStateDir(allocator, state_dir);
    try writeKeyFile(allocator, state_dir, key_hex);
    var store = try secrets.SecretStore.new(allocator, state_dir, getBool(parsed.value, "enabled") orelse true);
    defer store.deinit();

    if (std.mem.eql(u8, op, "encrypt_decrypt_roundtrip")) {
        const plaintext = getString(parsed.value, "plaintext") orelse return EvalError.InvalidScenario;
        const encrypted = try store.encrypt(plaintext);
        defer allocator.free(encrypted);
        const decrypted = try store.decrypt(encrypted);
        defer allocator.free(decrypted);
        try writer.writeAll("{\"op\":\"encrypt_decrypt_roundtrip\",\"result\":{\"matches\":");
        try writer.writeAll(if (std.mem.eql(u8, plaintext, decrypted)) "true" else "false");
        try writer.writeAll(",\"prefix\":");
        const prefix = if (std.mem.startsWith(u8, encrypted, "enc2:")) "enc2:" else "";
        try std.json.stringify(prefix, .{}, writer);
        try writer.writeAll("}}\n");
    } else if (std.mem.eql(u8, op, "decrypt_legacy_enc")) {
        const hex_ciphertext = getString(parsed.value, "hex_ciphertext") orelse return EvalError.InvalidScenario;
        const value = try std.fmt.allocPrint(allocator, "enc:{s}", .{hex_ciphertext});
        defer allocator.free(value);
        const plaintext = try store.decrypt(value);
        defer allocator.free(plaintext);
        try writer.writeAll("{\"op\":\"decrypt_legacy_enc\",\"result\":{\"plaintext\":");
        try std.json.stringify(plaintext, .{}, writer);
        try writer.writeAll("}}\n");
    } else if (std.mem.eql(u8, op, "migrate_enc_to_enc2")) {
        const enc_value = getString(parsed.value, "enc_value") orelse return EvalError.InvalidScenario;
        var migrated = try store.decryptAndMigrate(enc_value);
        defer migrated.deinit(allocator);
        const migrated_value = migrated.migrated orelse "";
        const migrated_plaintext = try store.decrypt(migrated_value);
        defer allocator.free(migrated_plaintext);
        try writer.writeAll("{\"op\":\"migrate_enc_to_enc2\",\"result\":{\"plaintext\":");
        try std.json.stringify(migrated.plaintext, .{}, writer);
        try writer.writeAll(",\"migrated_re_decrypted\":");
        try std.json.stringify(migrated_plaintext, .{}, writer);
        try writer.writeAll(",\"migrated_prefix\":");
        const prefix = if (std.mem.startsWith(u8, migrated_value, "enc2:")) "enc2:" else "";
        try std.json.stringify(prefix, .{}, writer);
        try writer.writeAll("}}\n");
    } else {
        return EvalError.InvalidScenario;
    }
}

fn makeTempStateDir(allocator: std.mem.Allocator, index: usize) ![]u8 {
    const dir = try std.fmt.allocPrint(
        allocator,
        "/tmp/zeroclaw-eval-secrets-zig-{d}-{d}",
        .{ if (@hasDecl(std.c, "getpid")) std.c.getpid() else 0, index },
    );
    errdefer allocator.free(dir);
    std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir);
    return dir;
}

fn cleanupTempStateDir(allocator: std.mem.Allocator, path: []u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    allocator.free(path);
}

fn writeKeyFile(allocator: std.mem.Allocator, state_dir: []const u8, key_hex: []const u8) !void {
    const key_path = try std.fs.path.join(allocator, &.{ state_dir, ".secret_key" });
    defer allocator.free(key_path);
    var file = try std.fs.cwd().createFile(key_path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(key_hex);
    try file.chmod(0o600);
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const inner = value.object.get(key) orelse return null;
    if (inner != .string) return null;
    return inner.string;
}

fn getBool(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const inner = value.object.get(key) orelse return null;
    if (inner != .bool) return null;
    return inner.bool;
}
