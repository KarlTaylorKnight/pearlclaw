const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const KEY_LEN = Aead.key_length;
const NONCE_LEN = Aead.nonce_length;
const TAG_LEN = Aead.tag_length;

pub const DecryptAndMigrateResult = struct {
    plaintext: []u8,
    migrated: ?[]u8 = null,

    pub fn deinit(self: *DecryptAndMigrateResult, allocator: std.mem.Allocator) void {
        allocator.free(self.plaintext);
        if (self.migrated) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const SecretStore = struct {
    allocator: std.mem.Allocator,
    key_path: []u8,
    enabled: bool,

    pub fn new(allocator: std.mem.Allocator, zeroclaw_dir: []const u8, enabled: bool) !SecretStore {
        const key_path = try std.fs.path.join(allocator, &.{ zeroclaw_dir, ".secret_key" });
        return .{ .allocator = allocator, .key_path = key_path, .enabled = enabled };
    }

    pub fn init(allocator: std.mem.Allocator, zeroclaw_dir: []const u8, enabled: bool) !SecretStore {
        return new(allocator, zeroclaw_dir, enabled);
    }

    pub fn deinit(self: *SecretStore) void {
        self.allocator.free(self.key_path);
        self.* = undefined;
    }

    pub fn encrypt(self: *const SecretStore, plaintext: []const u8) ![]u8 {
        if (!self.enabled or plaintext.len == 0) return self.allocator.dupe(u8, plaintext);

        const key = try self.loadOrCreateKey();
        var nonce: [NONCE_LEN]u8 = undefined;
        std.crypto.random.bytes(&nonce);

        const ciphertext = try self.allocator.alloc(u8, plaintext.len);
        errdefer self.allocator.free(ciphertext);
        var tag: [TAG_LEN]u8 = undefined;
        Aead.encrypt(ciphertext, &tag, plaintext, "", nonce, key);

        var blob = try self.allocator.alloc(u8, NONCE_LEN + ciphertext.len + TAG_LEN);
        defer self.allocator.free(ciphertext);
        @memcpy(blob[0..NONCE_LEN], &nonce);
        @memcpy(blob[NONCE_LEN .. NONCE_LEN + ciphertext.len], ciphertext);
        @memcpy(blob[NONCE_LEN + ciphertext.len ..], &tag);
        defer self.allocator.free(blob);

        const encoded = try hexEncode(self.allocator, blob);
        defer self.allocator.free(encoded);
        return std.fmt.allocPrint(self.allocator, "enc2:{s}", .{encoded});
    }

    pub fn decrypt(self: *const SecretStore, value: []const u8) ![]u8 {
        if (std.mem.startsWith(u8, value, "enc2:")) return self.decryptChacha20(value["enc2:".len..]);
        if (std.mem.startsWith(u8, value, "enc:")) return self.decryptLegacyXor(value["enc:".len..]);
        return self.allocator.dupe(u8, value);
    }

    pub fn decryptAndMigrate(self: *const SecretStore, value: []const u8) !DecryptAndMigrateResult {
        if (std.mem.startsWith(u8, value, "enc2:")) {
            return .{ .plaintext = try self.decryptChacha20(value["enc2:".len..]) };
        }
        if (std.mem.startsWith(u8, value, "enc:")) {
            std.log.warn("Decrypting legacy XOR-encrypted secret; migrating to enc2", .{});
            const plaintext = try self.decryptLegacyXor(value["enc:".len..]);
            errdefer self.allocator.free(plaintext);
            const migrated = try self.encrypt(plaintext);
            return .{ .plaintext = plaintext, .migrated = migrated };
        }
        return .{ .plaintext = try self.allocator.dupe(u8, value) };
    }

    pub fn decrypt_and_migrate(self: *const SecretStore, value: []const u8) !DecryptAndMigrateResult {
        return self.decryptAndMigrate(value);
    }

    pub fn needsMigration(value: []const u8) bool {
        return std.mem.startsWith(u8, value, "enc:");
    }

    pub fn isEncrypted(value: []const u8) bool {
        return std.mem.startsWith(u8, value, "enc2:") or std.mem.startsWith(u8, value, "enc:");
    }

    pub fn isSecureEncrypted(value: []const u8) bool {
        return std.mem.startsWith(u8, value, "enc2:");
    }

    fn decryptChacha20(self: *const SecretStore, hex_str: []const u8) ![]u8 {
        const blob = try hexDecode(self.allocator, hex_str);
        defer self.allocator.free(blob);
        if (blob.len <= NONCE_LEN + TAG_LEN) return error.BadCipher;

        var nonce: [NONCE_LEN]u8 = undefined;
        @memcpy(&nonce, blob[0..NONCE_LEN]);
        const ciphertext = blob[NONCE_LEN .. blob.len - TAG_LEN];
        var tag: [TAG_LEN]u8 = undefined;
        @memcpy(&tag, blob[blob.len - TAG_LEN ..]);
        const key = try self.loadOrCreateKey();

        const plaintext = try self.allocator.alloc(u8, ciphertext.len);
        errdefer self.allocator.free(plaintext);
        Aead.decrypt(plaintext, ciphertext, tag, "", nonce, key) catch return error.BadCipher;
        if (!std.unicode.utf8ValidateSlice(plaintext)) return error.BadCipher;
        return plaintext;
    }

    fn decryptLegacyXor(self: *const SecretStore, hex_str: []const u8) ![]u8 {
        const ciphertext = try hexDecode(self.allocator, hex_str);
        defer self.allocator.free(ciphertext);
        const key = try self.loadOrCreateKey();
        const plaintext = try xorCipher(self.allocator, ciphertext, &key);
        errdefer self.allocator.free(plaintext);
        if (!std.unicode.utf8ValidateSlice(plaintext)) return error.BadCipher;
        return plaintext;
    }

    fn loadOrCreateKey(self: *const SecretStore) ![KEY_LEN]u8 {
        const cwd = std.fs.cwd();
        const contents = cwd.readFileAlloc(self.allocator, self.key_path, 4096) catch |err| switch (err) {
            error.FileNotFound => return self.createKey(),
            else => return err,
        };
        defer self.allocator.free(contents);

        const trimmed = std.mem.trim(u8, contents, " \t\r\n");
        const decoded = try hexDecode(self.allocator, trimmed);
        defer self.allocator.free(decoded);
        if (decoded.len != KEY_LEN) return error.KeyFileCorrupt;
        var key: [KEY_LEN]u8 = undefined;
        @memcpy(&key, decoded);
        return key;
    }

    fn createKey(self: *const SecretStore) ![KEY_LEN]u8 {
        var key: [KEY_LEN]u8 = undefined;
        std.crypto.random.bytes(&key);

        if (std.fs.path.dirname(self.key_path)) |parent| {
            try std.fs.cwd().makePath(parent);
        }
        const encoded = try hexEncode(self.allocator, &key);
        defer self.allocator.free(encoded);

        // Unix ports set the key file mode to 0600. The Rust Windows ACL path
        // is intentionally deferred for the Zig pilot.
        var file = try std.fs.cwd().createFile(self.key_path, .{ .truncate = true, .mode = 0o600 });
        defer file.close();
        try file.writeAll(encoded);
        try file.chmod(0o600);
        return key;
    }
};

fn xorCipher(allocator: std.mem.Allocator, data: []const u8, key: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, data.len);
    if (key.len == 0) {
        @memcpy(out, data);
        return out;
    }
    for (data, 0..) |byte, i| out[i] = byte ^ key[i % key.len];
    return out;
}

pub fn hexEncode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, data.len * 2);
    var cursor: usize = 0;
    for (data) |byte| {
        _ = try std.fmt.bufPrint(out[cursor .. cursor + 2], "{x:0>2}", .{byte});
        cursor += 2;
    }
    return out;
}

pub fn hexDecode(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if ((hex.len & 1) != 0) return error.BadCipher;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        out[i / 2] = (try hexNibble(hex[i])) << 4 | try hexNibble(hex[i + 1]);
    }
    return out;
}

fn hexNibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.BadCipher,
    };
}

test "SecretStore encrypt/decrypt roundtrip and migration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const state_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(state_dir);

    var store = try SecretStore.new(std.testing.allocator, state_dir, true);
    defer store.deinit();

    const encrypted = try store.encrypt("secret");
    defer std.testing.allocator.free(encrypted);
    try std.testing.expect(std.mem.startsWith(u8, encrypted, "enc2:"));

    const decrypted = try store.decrypt(encrypted);
    defer std.testing.allocator.free(decrypted);
    try std.testing.expectEqualStrings("secret", decrypted);

    const key = try store.loadOrCreateKey();
    const legacy_cipher = try xorCipher(std.testing.allocator, "legacy", &key);
    defer std.testing.allocator.free(legacy_cipher);
    const legacy_hex = try hexEncode(std.testing.allocator, legacy_cipher);
    defer std.testing.allocator.free(legacy_hex);
    const legacy_value = try std.fmt.allocPrint(std.testing.allocator, "enc:{s}", .{legacy_hex});
    defer std.testing.allocator.free(legacy_value);

    var migrated = try store.decryptAndMigrate(legacy_value);
    defer migrated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("legacy", migrated.plaintext);
    try std.testing.expect(migrated.migrated != null);
    try std.testing.expect(SecretStore.isSecureEncrypted(migrated.migrated.?));
}

test "SecretStore disabled and empty encryption passthrough" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(state_dir);

    var store = try SecretStore.new(std.testing.allocator, state_dir, false);
    defer store.deinit();
    const plaintext = try store.encrypt("sk-disabled");
    defer std.testing.allocator.free(plaintext);
    try std.testing.expectEqualStrings("sk-disabled", plaintext);

    var enabled = try SecretStore.new(std.testing.allocator, state_dir, true);
    defer enabled.deinit();
    const empty = try enabled.encrypt("");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "SecretStore prefix helpers and bad hex" {
    try std.testing.expect(SecretStore.needsMigration("enc:aabb"));
    try std.testing.expect(SecretStore.isEncrypted("enc:aabb"));
    try std.testing.expect(SecretStore.isEncrypted("enc2:aabb"));
    try std.testing.expect(SecretStore.isSecureEncrypted("enc2:aabb"));
    try std.testing.expect(!SecretStore.isSecureEncrypted("enc:aabb"));
    try std.testing.expectError(error.BadCipher, hexDecode(std.testing.allocator, "abc"));
    try std.testing.expectError(error.BadCipher, hexDecode(std.testing.allocator, "zz"));
}
