const std = @import("std");
const zeroclaw = @import("zeroclaw");
const auth = zeroclaw.providers.auth;
const datetime = zeroclaw.api.datetime;

const EvalError = error{InvalidScenario};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.io.getStdIn().readToEndAlloc(allocator, 32 * 1024 * 1024);
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

    if (std.mem.eql(u8, op, "roundtrip_oauth_profile")) {
        try roundtripOauth(allocator, parsed.value, writer, index);
    } else if (std.mem.eql(u8, op, "roundtrip_token_profile")) {
        try roundtripToken(allocator, parsed.value, writer, index);
    } else if (std.mem.eql(u8, op, "select_profile_id")) {
        try selectProfile(allocator, parsed.value, writer);
    } else if (std.mem.eql(u8, op, "migrate_legacy_enc_in_profile")) {
        try migrateLegacy(allocator, parsed.value, writer, index);
    } else if (std.mem.eql(u8, op, "schema_version_mismatch")) {
        try schemaVersionMismatch(allocator, parsed.value, writer, index);
    } else {
        return EvalError.InvalidScenario;
    }
}

fn roundtripOauth(allocator: std.mem.Allocator, value: std.json.Value, writer: anytype, index: usize) !void {
    const encrypt_secrets = getBool(value, "encrypt_secrets") orelse true;
    const now = getI64(value, "now_unix_seconds") orelse 1_700_000_000;
    const profile_value = getObject(value, "profile") orelse return EvalError.InvalidScenario;
    const state_dir = try makeTempStateDir(allocator, "profiles-oauth", index);
    defer cleanupTempStateDir(allocator, state_dir);
    if (getString(value, "key_hex")) |key_hex| try writeKeyFile(allocator, state_dir, key_hex);

    var store = try auth.AuthProfilesStore.new(allocator, state_dir, encrypt_secrets);
    defer store.deinit();
    var profile = try oauthProfileFromJson(allocator, profile_value, now);
    defer profile.deinit(allocator);
    try store.upsertProfile(&profile, true, now);
    var data = try store.load();
    defer data.deinit(allocator);
    const loaded = data.profiles.get(profile.id).?;
    try writer.writeAll("{\"op\":\"roundtrip_oauth_profile\",\"result\":{\"profile\":");
    try writeProfileJson(writer, allocator, loaded);
    try writer.writeAll("}}\n");
}

fn roundtripToken(allocator: std.mem.Allocator, value: std.json.Value, writer: anytype, index: usize) !void {
    const encrypt_secrets = getBool(value, "encrypt_secrets") orelse true;
    const now = getI64(value, "now_unix_seconds") orelse 1_700_000_000;
    const profile_value = getObject(value, "profile") orelse return EvalError.InvalidScenario;
    const state_dir = try makeTempStateDir(allocator, "profiles-token", index);
    defer cleanupTempStateDir(allocator, state_dir);
    if (getString(value, "key_hex")) |key_hex| try writeKeyFile(allocator, state_dir, key_hex);

    var store = try auth.AuthProfilesStore.new(allocator, state_dir, encrypt_secrets);
    defer store.deinit();
    var profile = try tokenProfileFromJson(allocator, profile_value, now);
    defer profile.deinit(allocator);
    try store.upsertProfile(&profile, true, now);
    var data = try store.load();
    defer data.deinit(allocator);
    const loaded = data.profiles.get(profile.id).?;
    try writer.writeAll("{\"op\":\"roundtrip_token_profile\",\"result\":{\"profile\":");
    try writeProfileJson(writer, allocator, loaded);
    try writer.writeAll("}}\n");
}

fn selectProfile(allocator: std.mem.Allocator, value: std.json.Value, writer: anytype) !void {
    var data = auth.AuthProfilesData.init(allocator, 1_700_000_000);
    defer data.deinit(allocator);
    const profiles = getArray(value, "profiles") orelse return EvalError.InvalidScenario;
    for (profiles.items) |item| {
        const provider = getString(item, "provider") orelse return EvalError.InvalidScenario;
        const name = getString(item, "name") orelse return EvalError.InvalidScenario;
        var profile = try auth.AuthProfile.newToken(allocator, provider, name, "token", 1_700_000_000);
        defer profile.deinit(allocator);
        try putProfile(allocator, &data.profiles, &profile);
    }
    if (getObject(value, "active_map")) |active_map| {
        var it = active_map.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return EvalError.InvalidScenario;
            try putStringValue(allocator, &data.active_profiles, entry.key_ptr.*, entry.value_ptr.string);
        }
    }
    const provider = getString(value, "query_provider") orelse return EvalError.InvalidScenario;
    const override = getOptionalString(value, "override");
    const resolved = try auth.selectProfileId(allocator, &data, provider, override);
    defer if (resolved) |id| allocator.free(id);
    try writer.writeAll("{\"op\":\"select_profile_id\",\"result\":{\"resolved_id\":");
    if (resolved) |id| try std.json.stringify(id, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll("}}\n");
}

fn migrateLegacy(allocator: std.mem.Allocator, value: std.json.Value, writer: anytype, index: usize) !void {
    const state_dir = try makeTempStateDir(allocator, "profiles-migrate", index);
    defer cleanupTempStateDir(allocator, state_dir);
    try writeKeyFile(allocator, state_dir, getString(value, "key_hex") orelse return EvalError.InvalidScenario);
    try writeProfilesFile(allocator, state_dir, getString(value, "file_json") orelse return EvalError.InvalidScenario);
    var store = try auth.AuthProfilesStore.new(allocator, state_dir, true);
    defer store.deinit();
    var data = try store.load();
    defer data.deinit(allocator);
    const id = getString(value, "profile_id") orelse return EvalError.InvalidScenario;
    const profile = data.profiles.get(id) orelse return EvalError.InvalidScenario;
    const access_token = profile.token_set.?.access_token;
    const raw = try std.fs.cwd().readFileAlloc(allocator, store.path(), 1024 * 1024);
    defer allocator.free(raw);
    try writer.writeAll("{\"op\":\"migrate_legacy_enc_in_profile\",\"result\":{\"access_token\":");
    try std.json.stringify(access_token, .{}, writer);
    try writer.writeAll(",\"file_now_enc2\":");
    try writer.writeAll(if (std.mem.indexOf(u8, raw, "\"access_token\": \"enc2:") != null) "true" else "false");
    try writer.writeAll("}}\n");
}

fn schemaVersionMismatch(allocator: std.mem.Allocator, value: std.json.Value, writer: anytype, index: usize) !void {
    const state_dir = try makeTempStateDir(allocator, "profiles-schema", index);
    defer cleanupTempStateDir(allocator, state_dir);
    try writeProfilesFile(allocator, state_dir, getString(value, "file_json") orelse return EvalError.InvalidScenario);
    var store = try auth.AuthProfilesStore.new(allocator, state_dir, false);
    defer store.deinit();
    const result = store.load();
    if (result) |data| {
        var owned = data;
        owned.deinit(allocator);
        return EvalError.InvalidScenario;
    } else |err| {
        try writer.writeAll("{\"op\":\"schema_version_mismatch\",\"result\":{\"error\":");
        try std.json.stringify(@errorName(err), .{}, writer);
        try writer.writeAll("}}\n");
    }
}

fn oauthProfileFromJson(allocator: std.mem.Allocator, value: std.json.Value, now: i64) !auth.AuthProfile {
    var token_set = auth.TokenSet{
        .access_token = try dupStringField(allocator, value, "access_token"),
        .refresh_token = try dupOptionalStringField(allocator, value, "refresh_token"),
        .id_token = try dupOptionalStringField(allocator, value, "id_token"),
        .expires_at_utc_seconds = getI64(value, "expires_at_unix_seconds"),
        .token_type = try dupOptionalStringField(allocator, value, "token_type"),
        .scope = try dupOptionalStringField(allocator, value, "scope"),
    };
    errdefer token_set.deinit(allocator);
    var profile = try auth.AuthProfile.newOauth(
        allocator,
        getString(value, "provider") orelse return EvalError.InvalidScenario,
        getString(value, "name") orelse return EvalError.InvalidScenario,
        token_set,
        now,
    );
    errdefer profile.deinit(allocator);
    profile.account_id = try dupOptionalStringField(allocator, value, "account_id");
    profile.workspace_id = try dupOptionalStringField(allocator, value, "workspace_id");
    try fillMetadata(allocator, &profile.metadata, value);
    return profile;
}

fn tokenProfileFromJson(allocator: std.mem.Allocator, value: std.json.Value, now: i64) !auth.AuthProfile {
    var profile = try auth.AuthProfile.newToken(
        allocator,
        getString(value, "provider") orelse return EvalError.InvalidScenario,
        getString(value, "name") orelse return EvalError.InvalidScenario,
        getString(value, "token") orelse return EvalError.InvalidScenario,
        now,
    );
    errdefer profile.deinit(allocator);
    profile.account_id = try dupOptionalStringField(allocator, value, "account_id");
    profile.workspace_id = try dupOptionalStringField(allocator, value, "workspace_id");
    try fillMetadata(allocator, &profile.metadata, value);
    return profile;
}

fn writeProfileJson(writer: anytype, allocator: std.mem.Allocator, profile: auth.AuthProfile) !void {
    try writer.writeByte('{');
    var wrote = false;
    try writeStringField(writer, &wrote, "id", profile.id);
    try writeStringField(writer, &wrote, "provider", profile.provider);
    try writeStringField(writer, &wrote, "profile_name", profile.profile_name);
    try writeStringField(writer, &wrote, "kind", profile.kind.asString());
    try writeOptionalStringField(writer, &wrote, "account_id", profile.account_id);
    try writeOptionalStringField(writer, &wrote, "workspace_id", profile.workspace_id);
    try writeComma(writer, &wrote);
    try writer.writeAll("\"token_set\":");
    if (profile.token_set) |token_set| try writeTokenSetJson(writer, allocator, token_set) else try writer.writeAll("null");
    try writeOptionalStringField(writer, &wrote, "token", profile.token);
    try writeComma(writer, &wrote);
    try writer.writeAll("\"metadata\":");
    try writeStringMapJson(writer, allocator, profile.metadata);
    const created_at = try datetime.formatRfc3339(allocator, profile.created_at_unix_seconds);
    defer allocator.free(created_at);
    const updated_at = try datetime.formatRfc3339(allocator, profile.updated_at_unix_seconds);
    defer allocator.free(updated_at);
    try writeStringField(writer, &wrote, "created_at", created_at);
    try writeStringField(writer, &wrote, "updated_at", updated_at);
    try writer.writeByte('}');
}

fn writeTokenSetJson(writer: anytype, allocator: std.mem.Allocator, token_set: auth.TokenSet) !void {
    _ = allocator;
    try writer.writeByte('{');
    var wrote = false;
    try writeStringField(writer, &wrote, "access_token", token_set.access_token);
    try writeOptionalStringField(writer, &wrote, "refresh_token", token_set.refresh_token);
    try writeOptionalStringField(writer, &wrote, "id_token", token_set.id_token);
    try writeComma(writer, &wrote);
    try writer.writeAll("\"expires_at\":");
    if (token_set.expires_at_utc_seconds) |expires_at| {
        const formatted = try datetime.formatRfc3339(std.heap.page_allocator, expires_at);
        defer std.heap.page_allocator.free(formatted);
        try std.json.stringify(formatted, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writeOptionalStringField(writer, &wrote, "token_type", token_set.token_type);
    try writeOptionalStringField(writer, &wrote, "scope", token_set.scope);
    try writer.writeByte('}');
}

fn writeStringMapJson(writer: anytype, allocator: std.mem.Allocator, map: std.StringHashMap([]u8)) !void {
    const keys = try sortedKeys(allocator, map);
    defer allocator.free(keys);
    try writer.writeByte('{');
    for (keys, 0..) |key, i| {
        if (i != 0) try writer.writeByte(',');
        try std.json.stringify(key, .{}, writer);
        try writer.writeByte(':');
        try std.json.stringify(map.get(key).?, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeStringField(writer: anytype, wrote: *bool, key: []const u8, value: []const u8) !void {
    try writeComma(writer, wrote);
    try std.json.stringify(key, .{}, writer);
    try writer.writeByte(':');
    try std.json.stringify(value, .{}, writer);
}

fn writeOptionalStringField(writer: anytype, wrote: *bool, key: []const u8, value: ?[]const u8) !void {
    try writeComma(writer, wrote);
    try std.json.stringify(key, .{}, writer);
    try writer.writeByte(':');
    if (value) |inner| try std.json.stringify(inner, .{}, writer) else try writer.writeAll("null");
}

fn writeComma(writer: anytype, wrote: *bool) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
}

fn fillMetadata(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8), value: std.json.Value) !void {
    const metadata = getObject(value, "metadata") orelse return;
    var it = metadata.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return EvalError.InvalidScenario;
        try putStringValue(allocator, map, entry.key_ptr.*, entry.value_ptr.string);
    }
}

fn putProfile(allocator: std.mem.Allocator, map: *std.StringHashMap(auth.AuthProfile), profile: *const auth.AuthProfile) !void {
    const clone = try profile.clone(allocator);
    errdefer {
        var tmp = clone;
        tmp.deinit(allocator);
    }
    const gop = try map.getOrPut(profile.id);
    if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, profile.id);
    gop.value_ptr.* = clone;
}

fn putStringValue(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8), key: []const u8, value: []const u8) !void {
    const value_owned = try allocator.dupe(u8, value);
    errdefer allocator.free(value_owned);
    const gop = try map.getOrPut(key);
    if (gop.found_existing) {
        allocator.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try allocator.dupe(u8, key);
    }
    gop.value_ptr.* = value_owned;
}

fn sortedKeys(allocator: std.mem.Allocator, map: std.StringHashMap([]u8)) ![][]const u8 {
    var keys = try allocator.alloc([]const u8, map.count());
    var i: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        keys[i] = entry.key_ptr.*;
        i += 1;
    }
    std.mem.sort([]const u8, keys, {}, lessThanBytes);
    return keys;
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn makeTempStateDir(allocator: std.mem.Allocator, prefix: []const u8, index: usize) ![]u8 {
    const dir = try std.fmt.allocPrint(
        allocator,
        "/tmp/zeroclaw-eval-{s}-zig-{d}-{d}",
        .{ prefix, if (@hasDecl(std.c, "getpid")) std.c.getpid() else 0, index },
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
    const path = try std.fs.path.join(allocator, &.{ state_dir, ".secret_key" });
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(key_hex);
    try file.chmod(0o600);
}

fn writeProfilesFile(allocator: std.mem.Allocator, state_dir: []const u8, contents: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ state_dir, "auth-profiles.json" });
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
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
    if (inner == .null) return null;
    if (inner != .string) return null;
    return inner.string;
}

fn dupStringField(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]u8 {
    return allocator.dupe(u8, getString(value, key) orelse return EvalError.InvalidScenario);
}

fn dupOptionalStringField(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) !?[]u8 {
    if (getOptionalString(value, key)) |inner| return try allocator.dupe(u8, inner);
    return null;
}

fn getBool(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const inner = value.object.get(key) orelse return null;
    if (inner != .bool) return null;
    return inner.bool;
}

fn getI64(value: std.json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    const inner = value.object.get(key) orelse return null;
    if (inner != .integer) return null;
    return inner.integer;
}

fn getObject(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const inner = value.object.get(key) orelse return null;
    if (inner != .object) return null;
    return inner;
}

fn getArray(value: std.json.Value, key: []const u8) ?std.json.Array {
    if (value != .object) return null;
    const inner = value.object.get(key) orelse return null;
    if (inner != .array) return null;
    return inner.array;
}
