const std = @import("std");
const api = @import("../../api/root.zig");
const datetime = api.datetime;
const secrets = api.secrets;
const types = @import("types.zig");

pub const TokenSet = types.TokenSet;

const CURRENT_SCHEMA_VERSION: u32 = 1;
const PROFILES_FILENAME = "auth-profiles.json";
const LOCK_FILENAME = "auth-profiles.lock";
const LOCK_WAIT_MS: u64 = 50;
const LOCK_TIMEOUT_MS: u64 = 10_000;

pub const AuthProfileKind = enum {
    OAuth,
    Token,

    pub fn fromString(value: []const u8) !AuthProfileKind {
        if (std.mem.eql(u8, value, "oauth")) return .OAuth;
        if (std.mem.eql(u8, value, "token")) return .Token;
        return error.InvalidProfileKind;
    }

    pub fn asString(self: AuthProfileKind) []const u8 {
        return switch (self) {
            .OAuth => "oauth",
            .Token => "token",
        };
    }
};

pub const AuthProfile = struct {
    id: []u8,
    provider: []u8,
    profile_name: []u8,
    kind: AuthProfileKind,
    account_id: ?[]u8 = null,
    workspace_id: ?[]u8 = null,
    token_set: ?TokenSet = null,
    token: ?[]u8 = null,
    metadata: std.StringHashMap([]u8),
    created_at_unix_seconds: i64,
    updated_at_unix_seconds: i64,

    pub fn newOauth(
        allocator: std.mem.Allocator,
        provider_value: []const u8,
        profile_name_value: []const u8,
        token_set: TokenSet,
        now_unix_seconds: i64,
    ) !AuthProfile {
        const id = try profileId(allocator, provider_value, profile_name_value);
        errdefer allocator.free(id);
        const provider_owned = try allocator.dupe(u8, provider_value);
        errdefer allocator.free(provider_owned);
        const profile_name_owned = try allocator.dupe(u8, profile_name_value);
        errdefer allocator.free(profile_name_owned);
        return .{
            .id = id,
            .provider = provider_owned,
            .profile_name = profile_name_owned,
            .kind = .OAuth,
            .token_set = token_set,
            .metadata = std.StringHashMap([]u8).init(allocator),
            .created_at_unix_seconds = now_unix_seconds,
            .updated_at_unix_seconds = now_unix_seconds,
        };
    }

    pub fn newToken(
        allocator: std.mem.Allocator,
        provider_value: []const u8,
        profile_name_value: []const u8,
        token_value: []const u8,
        now_unix_seconds: i64,
    ) !AuthProfile {
        const token_owned = try allocator.dupe(u8, token_value);
        errdefer allocator.free(token_owned);
        const id = try profileId(allocator, provider_value, profile_name_value);
        errdefer allocator.free(id);
        const provider_owned = try allocator.dupe(u8, provider_value);
        errdefer allocator.free(provider_owned);
        const profile_name_owned = try allocator.dupe(u8, profile_name_value);
        errdefer allocator.free(profile_name_owned);
        return .{
            .id = id,
            .provider = provider_owned,
            .profile_name = profile_name_owned,
            .kind = .Token,
            .token = token_owned,
            .metadata = std.StringHashMap([]u8).init(allocator),
            .created_at_unix_seconds = now_unix_seconds,
            .updated_at_unix_seconds = now_unix_seconds,
        };
    }

    pub fn deinit(self: *AuthProfile, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.provider);
        allocator.free(self.profile_name);
        if (self.account_id) |value| allocator.free(value);
        if (self.workspace_id) |value| allocator.free(value);
        if (self.token_set) |*value| value.deinit(allocator);
        if (self.token) |value| allocator.free(value);
        deinitStringMap(allocator, &self.metadata);
        self.* = undefined;
    }

    pub fn clone(self: AuthProfile, allocator: std.mem.Allocator) !AuthProfile {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        const provider_owned = try allocator.dupe(u8, self.provider);
        errdefer allocator.free(provider_owned);
        const profile_name_owned = try allocator.dupe(u8, self.profile_name);
        errdefer allocator.free(profile_name_owned);
        const account_id = if (self.account_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (account_id) |value| allocator.free(value);
        const workspace_id = if (self.workspace_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (workspace_id) |value| allocator.free(value);
        const token_set = if (self.token_set) |value| try value.clone(allocator) else null;
        errdefer if (token_set) |value| {
            var tmp = value;
            tmp.deinit(allocator);
        };
        const token = if (self.token) |value| try allocator.dupe(u8, value) else null;
        errdefer if (token) |value| allocator.free(value);
        var metadata = try cloneStringMap(allocator, self.metadata);
        errdefer deinitStringMap(allocator, &metadata);
        return .{
            .id = id,
            .provider = provider_owned,
            .profile_name = profile_name_owned,
            .kind = self.kind,
            .account_id = account_id,
            .workspace_id = workspace_id,
            .token_set = token_set,
            .token = token,
            .metadata = metadata,
            .created_at_unix_seconds = self.created_at_unix_seconds,
            .updated_at_unix_seconds = self.updated_at_unix_seconds,
        };
    }
};

pub const AuthProfilesData = struct {
    schema_version: u32 = CURRENT_SCHEMA_VERSION,
    updated_at_unix_seconds: i64,
    active_profiles: std.StringHashMap([]u8),
    profiles: std.StringHashMap(AuthProfile),

    pub fn init(allocator: std.mem.Allocator, now_unix_seconds: i64) AuthProfilesData {
        return .{
            .updated_at_unix_seconds = now_unix_seconds,
            .active_profiles = std.StringHashMap([]u8).init(allocator),
            .profiles = std.StringHashMap(AuthProfile).init(allocator),
        };
    }

    pub fn deinit(self: *AuthProfilesData, allocator: std.mem.Allocator) void {
        deinitStringMap(allocator, &self.active_profiles);
        var it = self.profiles.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.profiles.deinit();
        self.* = undefined;
    }
};

pub const AuthProfilesStore = struct {
    allocator: std.mem.Allocator,
    path_value: []u8,
    lock_path: []u8,
    secret_store: secrets.SecretStore,

    pub fn new(allocator: std.mem.Allocator, state_dir: []const u8, encrypt_secrets: bool) !AuthProfilesStore {
        const path_value = try std.fs.path.join(allocator, &.{ state_dir, PROFILES_FILENAME });
        errdefer allocator.free(path_value);
        const lock_path = try std.fs.path.join(allocator, &.{ state_dir, LOCK_FILENAME });
        errdefer allocator.free(lock_path);
        const secret_store = try secrets.SecretStore.new(allocator, state_dir, encrypt_secrets);
        errdefer {
            var tmp = secret_store;
            tmp.deinit();
        }
        return .{
            .allocator = allocator,
            .path_value = path_value,
            .lock_path = lock_path,
            .secret_store = secret_store,
        };
    }

    pub fn init(allocator: std.mem.Allocator, state_dir: []const u8, encrypt_secrets: bool) !AuthProfilesStore {
        return new(allocator, state_dir, encrypt_secrets);
    }

    pub fn deinit(self: *AuthProfilesStore) void {
        self.allocator.free(self.path_value);
        self.allocator.free(self.lock_path);
        self.secret_store.deinit();
        self.* = undefined;
    }

    pub fn path(self: *const AuthProfilesStore) []const u8 {
        return self.path_value;
    }

    pub fn load(self: *const AuthProfilesStore) !AuthProfilesData {
        var lock = try self.acquireLock();
        defer lock.deinit();
        return self.loadLocked();
    }

    pub fn upsertProfile(self: *const AuthProfilesStore, profile: *const AuthProfile, set_active: bool, now_unix_seconds: i64) !void {
        var lock = try self.acquireLock();
        defer lock.deinit();
        var data = try self.loadLocked();
        defer data.deinit(self.allocator);

        var stored = try profile.clone(self.allocator);
        var transferred = false;
        errdefer if (!transferred) stored.deinit(self.allocator);
        stored.updated_at_unix_seconds = now_unix_seconds;
        if (data.profiles.get(profile.id)) |existing| {
            stored.created_at_unix_seconds = existing.created_at_unix_seconds;
        }
        if (set_active) try putStringValue(self.allocator, &data.active_profiles, stored.provider, stored.id);
        try putProfileValue(self.allocator, &data.profiles, stored.id, stored);
        transferred = true;
        data.updated_at_unix_seconds = now_unix_seconds;
        try self.saveLocked(&data);
    }

    pub fn removeProfile(self: *const AuthProfilesStore, id: []const u8, now_unix_seconds: i64) !bool {
        var lock = try self.acquireLock();
        defer lock.deinit();
        var data = try self.loadLocked();
        defer data.deinit(self.allocator);

        var removed = false;
        if (data.profiles.fetchRemove(id)) |entry| {
            self.allocator.free(entry.key);
            var profile = entry.value;
            profile.deinit(self.allocator);
            removed = true;
        }
        if (!removed) return false;

        var it = data.active_profiles.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, id)) {
                self.allocator.free(entry.value_ptr.*);
                entry.value_ptr.* = try self.allocator.dupe(u8, "");
            }
        }
        removeEmptyActiveProfiles(self.allocator, &data.active_profiles);
        data.updated_at_unix_seconds = now_unix_seconds;
        try self.saveLocked(&data);
        return true;
    }

    pub fn setActiveProfile(self: *const AuthProfilesStore, provider: []const u8, id: []const u8, now_unix_seconds: i64) !void {
        var lock = try self.acquireLock();
        defer lock.deinit();
        var data = try self.loadLocked();
        defer data.deinit(self.allocator);
        if (!data.profiles.contains(id)) return error.ProfileNotFound;
        try putStringValue(self.allocator, &data.active_profiles, provider, id);
        data.updated_at_unix_seconds = now_unix_seconds;
        try self.saveLocked(&data);
    }

    pub fn clearActiveProfile(self: *const AuthProfilesStore, provider: []const u8, now_unix_seconds: i64) !void {
        var lock = try self.acquireLock();
        defer lock.deinit();
        var data = try self.loadLocked();
        defer data.deinit(self.allocator);
        if (data.active_profiles.fetchRemove(provider)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        data.updated_at_unix_seconds = now_unix_seconds;
        try self.saveLocked(&data);
    }

    pub fn updateProfile(
        self: *const AuthProfilesStore,
        profile_id_value: []const u8,
        now_unix_seconds: i64,
        context: anytype,
        comptime updater: fn (@TypeOf(context), *AuthProfile) anyerror!void,
    ) !AuthProfile {
        var lock = try self.acquireLock();
        defer lock.deinit();
        var data = try self.loadLocked();
        defer data.deinit(self.allocator);

        const profile = data.profiles.getPtr(profile_id_value) orelse return error.ProfileNotFound;
        try updater(context, profile);
        profile.updated_at_unix_seconds = now_unix_seconds;
        const updated = try profile.clone(self.allocator);
        errdefer {
            var tmp = updated;
            tmp.deinit(self.allocator);
        }
        data.updated_at_unix_seconds = now_unix_seconds;
        try self.saveLocked(&data);
        return updated;
    }

    fn loadLocked(self: *const AuthProfilesStore) !AuthProfilesData {
        var persisted = try self.readPersistedLocked();
        defer persisted.deinit(self.allocator);
        var migrated = false;
        const now = std.time.timestamp();
        var data = AuthProfilesData.init(self.allocator, datetime.parseRfc3339WithFallback(persisted.updated_at, now));
        errdefer data.deinit(self.allocator);
        data.schema_version = persisted.schema_version;
        try cloneStringMapInto(self.allocator, &data.active_profiles, persisted.active_profiles);

        var it = persisted.profiles.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const p = entry.value_ptr;
            var access = try self.decryptOptional(&p.access_token, &migrated);
            errdefer freeOptional(self.allocator, access);
            var refresh = try self.decryptOptional(&p.refresh_token, &migrated);
            errdefer freeOptional(self.allocator, refresh);
            var id_token = try self.decryptOptional(&p.id_token, &migrated);
            errdefer freeOptional(self.allocator, id_token);
            var token = try self.decryptOptional(&p.token, &migrated);
            errdefer freeOptional(self.allocator, token);

            if (access.migrated) |value| try replaceOptional(self.allocator, &p.access_token, value);
            access.migrated = null;
            if (refresh.migrated) |value| try replaceOptional(self.allocator, &p.refresh_token, value);
            refresh.migrated = null;
            if (id_token.migrated) |value| try replaceOptional(self.allocator, &p.id_token, value);
            id_token.migrated = null;
            if (token.migrated) |value| try replaceOptional(self.allocator, &p.token, value);
            token.migrated = null;

            const kind = try AuthProfileKind.fromString(p.kind);
            var profile = try buildLoadedProfileShell(self.allocator, id, p, kind, now);
            errdefer profile.deinit(self.allocator);

            switch (kind) {
                .OAuth => {
                    const access_token = access.plaintext orelse return error.BadProfile;
                    access.plaintext = null;
                    const refresh_pt = refresh.plaintext;
                    refresh.plaintext = null;
                    const id_token_pt = id_token.plaintext;
                    id_token.plaintext = null;
                    profile.token_set = try buildOauthTokenSet(
                        self.allocator,
                        p,
                        access_token,
                        refresh_pt,
                        id_token_pt,
                    );
                },
                .Token => {
                    profile.token = token.plaintext;
                    token.plaintext = null;
                },
            }
            try putProfileValue(self.allocator, &data.profiles, profile.id, profile);
        }

        if (migrated) try self.writePersistedLocked(&persisted);
        return data;
    }

    fn saveLocked(self: *const AuthProfilesStore, data: *const AuthProfilesData) !void {
        var persisted = try PersistedAuthProfiles.init(self.allocator, data.updated_at_unix_seconds);
        defer persisted.deinit(self.allocator);
        try cloneStringMapInto(self.allocator, &persisted.active_profiles, data.active_profiles);

        var it = data.profiles.iterator();
        while (it.next()) |entry| {
            const profile = entry.value_ptr.*;
            var persisted_profile = PersistedAuthProfile.init(self.allocator);
            errdefer persisted_profile.deinit(self.allocator);
            persisted_profile.provider = try self.allocator.dupe(u8, profile.provider);
            persisted_profile.profile_name = try self.allocator.dupe(u8, profile.profile_name);
            persisted_profile.kind = try self.allocator.dupe(u8, profile.kind.asString());
            persisted_profile.account_id = try cloneOptional(self.allocator, profile.account_id);
            persisted_profile.workspace_id = try cloneOptional(self.allocator, profile.workspace_id);
            if (profile.kind == .OAuth) {
                if (profile.token_set) |token_set| {
                    persisted_profile.access_token = try self.encryptOptional(token_set.access_token);
                    persisted_profile.refresh_token = try self.encryptOptional(token_set.refresh_token);
                    persisted_profile.id_token = try self.encryptOptional(token_set.id_token);
                    if (token_set.expires_at_utc_seconds) |expires_at| {
                        persisted_profile.expires_at = try datetime.formatRfc3339(self.allocator, expires_at);
                    }
                    persisted_profile.token_type = try cloneOptional(self.allocator, token_set.token_type);
                    persisted_profile.scope = try cloneOptional(self.allocator, token_set.scope);
                }
            }
            persisted_profile.token = try self.encryptOptional(profile.token);
            persisted_profile.created_at = try datetime.formatRfc3339(self.allocator, profile.created_at_unix_seconds);
            persisted_profile.updated_at = try datetime.formatRfc3339(self.allocator, profile.updated_at_unix_seconds);
            persisted_profile.metadata = try cloneStringMap(self.allocator, profile.metadata);
            try putPersistedProfile(self.allocator, &persisted.profiles, entry.key_ptr.*, persisted_profile);
        }
        try self.writePersistedLocked(&persisted);
    }

    fn readPersistedLocked(self: *const AuthProfilesStore) !PersistedAuthProfiles {
        const now = std.time.timestamp();
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, self.path_value, 64 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return try PersistedAuthProfiles.init(self.allocator, now),
            else => return err,
        };
        defer self.allocator.free(bytes);
        if (bytes.len == 0) return try PersistedAuthProfiles.init(self.allocator, now);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        var persisted = try parsePersistedAuthProfiles(self.allocator, parsed.value, now);
        errdefer persisted.deinit(self.allocator);
        if (persisted.schema_version == 0) persisted.schema_version = CURRENT_SCHEMA_VERSION;
        if (persisted.schema_version > CURRENT_SCHEMA_VERSION) return error.UnsupportedSchemaVersion;
        return persisted;
    }

    fn writePersistedLocked(self: *const AuthProfilesStore, persisted: *const PersistedAuthProfiles) !void {
        if (std.fs.path.dirname(self.path_value)) |parent| try std.fs.cwd().makePath(parent);
        var json = std.ArrayList(u8).init(self.allocator);
        defer json.deinit();
        try writePersistedAuthProfiles(json.writer(), self.allocator, persisted);

        const pid: i32 = if (@hasDecl(std.c, "getpid")) std.c.getpid() else 0;
        const tmp_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.tmp.{d}.{d}",
            .{ self.path_value, pid, std.time.nanoTimestamp() },
        );
        defer self.allocator.free(tmp_path);

        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
        {
            var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(json.items);
        }
        try std.fs.cwd().rename(tmp_path, self.path_value);
    }

    fn encryptOptional(self: *const AuthProfilesStore, value: ?[]const u8) !?[]u8 {
        if (value) |inner| {
            if (inner.len == 0) return null;
            return try self.secret_store.encrypt(inner);
        }
        return null;
    }

    fn decryptOptional(self: *const AuthProfilesStore, value: *?[]u8, migrated_any: *bool) !DecryptedOptional {
        if (value.*) |inner| {
            if (inner.len == 0) return .{};
            const result = try self.secret_store.decryptAndMigrate(inner);
            if (result.migrated != null) migrated_any.* = true;
            return .{ .plaintext = result.plaintext, .migrated = result.migrated };
        }
        return .{};
    }

    fn acquireLock(self: *const AuthProfilesStore) !AuthProfileLockGuard {
        if (std.fs.path.dirname(self.lock_path)) |parent| try std.fs.cwd().makePath(parent);
        var waited: u64 = 0;
        while (true) {
            const file = std.fs.cwd().createFile(self.lock_path, .{ .exclusive = true, .truncate = false }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    if (waited >= LOCK_TIMEOUT_MS) return error.LockTimeout;
                    std.Thread.sleep(LOCK_WAIT_MS * std.time.ns_per_ms);
                    waited = std.math.add(u64, waited, LOCK_WAIT_MS) catch LOCK_TIMEOUT_MS;
                    continue;
                },
                else => return err,
            };
            var writable = file;
            errdefer writable.close();
            try writable.writer().print("pid={d}\n", .{if (@hasDecl(std.c, "getpid")) std.c.getpid() else 0});
            writable.close();
            return .{ .lock_path = self.lock_path };
        }
    }
};

const AuthProfileLockGuard = struct {
    lock_path: []const u8,

    fn deinit(self: *AuthProfileLockGuard) void {
        std.fs.cwd().deleteFile(self.lock_path) catch {};
        self.* = undefined;
    }
};

const DecryptedOptional = struct {
    plaintext: ?[]u8 = null,
    migrated: ?[]u8 = null,
};

const PersistedAuthProfiles = struct {
    schema_version: u32,
    updated_at: []u8,
    active_profiles: std.StringHashMap([]u8),
    profiles: std.StringHashMap(PersistedAuthProfile),

    fn init(allocator: std.mem.Allocator, now_unix_seconds: i64) !PersistedAuthProfiles {
        return .{
            .schema_version = CURRENT_SCHEMA_VERSION,
            .updated_at = try datetime.formatRfc3339(allocator, now_unix_seconds),
            .active_profiles = std.StringHashMap([]u8).init(allocator),
            .profiles = std.StringHashMap(PersistedAuthProfile).init(allocator),
        };
    }

    fn deinit(self: *PersistedAuthProfiles, allocator: std.mem.Allocator) void {
        allocator.free(self.updated_at);
        deinitStringMap(allocator, &self.active_profiles);
        var it = self.profiles.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.profiles.deinit();
        self.* = undefined;
    }
};

const PersistedAuthProfile = struct {
    provider: []u8 = &.{},
    profile_name: []u8 = &.{},
    kind: []u8 = &.{},
    account_id: ?[]u8 = null,
    workspace_id: ?[]u8 = null,
    access_token: ?[]u8 = null,
    refresh_token: ?[]u8 = null,
    id_token: ?[]u8 = null,
    token: ?[]u8 = null,
    expires_at: ?[]u8 = null,
    token_type: ?[]u8 = null,
    scope: ?[]u8 = null,
    created_at: []u8 = &.{},
    updated_at: []u8 = &.{},
    metadata: std.StringHashMap([]u8),

    fn init(allocator: std.mem.Allocator) PersistedAuthProfile {
        return .{ .metadata = std.StringHashMap([]u8).init(allocator) };
    }

    fn deinit(self: *PersistedAuthProfile, allocator: std.mem.Allocator) void {
        if (self.provider.len != 0) allocator.free(self.provider);
        if (self.profile_name.len != 0) allocator.free(self.profile_name);
        if (self.kind.len != 0) allocator.free(self.kind);
        if (self.account_id) |value| allocator.free(value);
        if (self.workspace_id) |value| allocator.free(value);
        if (self.access_token) |value| allocator.free(value);
        if (self.refresh_token) |value| allocator.free(value);
        if (self.id_token) |value| allocator.free(value);
        if (self.token) |value| allocator.free(value);
        if (self.expires_at) |value| allocator.free(value);
        if (self.token_type) |value| allocator.free(value);
        if (self.scope) |value| allocator.free(value);
        if (self.created_at.len != 0) allocator.free(self.created_at);
        if (self.updated_at.len != 0) allocator.free(self.updated_at);
        deinitStringMap(allocator, &self.metadata);
        self.* = undefined;
    }
};

pub fn profileId(allocator: std.mem.Allocator, provider_value: []const u8, profile_name_value: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}:{s}",
        .{ std.mem.trim(u8, provider_value, " \t\r\n"), std.mem.trim(u8, profile_name_value, " \t\r\n") },
    );
}

pub const profile_id = profileId;

fn parsePersistedAuthProfiles(allocator: std.mem.Allocator, value: std.json.Value, now_unix_seconds: i64) !PersistedAuthProfiles {
    if (value != .object) return error.InvalidJson;
    var out = try PersistedAuthProfiles.init(allocator, now_unix_seconds);
    errdefer out.deinit(allocator);
    if (value.object.get("schema_version")) |schema| out.schema_version = @intCast(try jsonI64(schema));
    if (value.object.get("updated_at")) |updated_at| {
        const new_updated_at = try jsonStringDup(allocator, updated_at);
        allocator.free(out.updated_at);
        out.updated_at = new_updated_at;
    }
    if (value.object.get("active_profiles")) |active| {
        if (active != .object) return error.InvalidJson;
        var it = active.object.iterator();
        while (it.next()) |entry| try putStringValue(allocator, &out.active_profiles, entry.key_ptr.*, try jsonString(entry.value_ptr.*));
    }
    if (value.object.get("profiles")) |profiles_value| {
        if (profiles_value != .object) return error.InvalidJson;
        var it = profiles_value.object.iterator();
        while (it.next()) |entry| {
            var profile = try parsePersistedAuthProfile(allocator, entry.value_ptr.*, now_unix_seconds);
            errdefer profile.deinit(allocator);
            try putPersistedProfile(allocator, &out.profiles, entry.key_ptr.*, profile);
        }
    }
    return out;
}

fn parsePersistedAuthProfile(allocator: std.mem.Allocator, value: std.json.Value, now_unix_seconds: i64) !PersistedAuthProfile {
    if (value != .object) return error.InvalidJson;
    var out = PersistedAuthProfile.init(allocator);
    errdefer out.deinit(allocator);
    out.provider = try requiredJsonStringDup(allocator, value, "provider");
    out.profile_name = try requiredJsonStringDup(allocator, value, "profile_name");
    out.kind = try requiredJsonStringDup(allocator, value, "kind");
    out.account_id = try optionalJsonStringDup(allocator, value, "account_id");
    out.workspace_id = try optionalJsonStringDup(allocator, value, "workspace_id");
    out.access_token = try optionalJsonStringDup(allocator, value, "access_token");
    out.refresh_token = try optionalJsonStringDup(allocator, value, "refresh_token");
    out.id_token = try optionalJsonStringDup(allocator, value, "id_token");
    out.token = try optionalJsonStringDup(allocator, value, "token");
    out.expires_at = try optionalJsonStringDup(allocator, value, "expires_at");
    out.token_type = try optionalJsonStringDup(allocator, value, "token_type");
    out.scope = try optionalJsonStringDup(allocator, value, "scope");
    out.created_at = if (value.object.get("created_at")) |v| try jsonStringDup(allocator, v) else try datetime.formatRfc3339(allocator, now_unix_seconds);
    out.updated_at = if (value.object.get("updated_at")) |v| try jsonStringDup(allocator, v) else try datetime.formatRfc3339(allocator, now_unix_seconds);
    if (value.object.get("metadata")) |metadata| {
        if (metadata != .object) return error.InvalidJson;
        var it = metadata.object.iterator();
        while (it.next()) |entry| try putStringValue(allocator, &out.metadata, entry.key_ptr.*, try jsonString(entry.value_ptr.*));
    }
    return out;
}

fn writePersistedAuthProfiles(writer: anytype, allocator: std.mem.Allocator, persisted: *const PersistedAuthProfiles) !void {
    try writer.writeAll("{\n");
    try writeIndent(writer, 2);
    try writer.print("\"schema_version\": {d},\n", .{persisted.schema_version});
    try writeIndent(writer, 2);
    try writer.writeAll("\"updated_at\": ");
    try std.json.stringify(persisted.updated_at, .{}, writer);
    try writer.writeAll(",\n");
    try writeIndent(writer, 2);
    try writer.writeAll("\"active_profiles\": ");
    try writeStringMapPretty(writer, allocator, persisted.active_profiles, 2);
    try writer.writeAll(",\n");
    try writeIndent(writer, 2);
    try writer.writeAll("\"profiles\": ");
    try writePersistedProfilesMap(writer, allocator, persisted.profiles, 2);
    try writer.writeAll("\n}");
}

fn writePersistedProfilesMap(writer: anytype, allocator: std.mem.Allocator, map: std.StringHashMap(PersistedAuthProfile), indent: usize) !void {
    if (map.count() == 0) return writer.writeAll("{}");
    const keys = try sortedKeys(allocator, map);
    defer allocator.free(keys);
    try writer.writeAll("{\n");
    for (keys, 0..) |key, i| {
        if (i != 0) try writer.writeAll(",\n");
        try writeIndent(writer, indent + 2);
        try std.json.stringify(key, .{}, writer);
        try writer.writeAll(": ");
        try writePersistedAuthProfile(writer, allocator, map.get(key).?, indent + 2);
    }
    try writer.writeByte('\n');
    try writeIndent(writer, indent);
    try writer.writeByte('}');
}

fn writePersistedAuthProfile(writer: anytype, allocator: std.mem.Allocator, profile: PersistedAuthProfile, indent: usize) !void {
    try writer.writeAll("{\n");
    var wrote = false;
    try writeRequiredStringPretty(writer, &wrote, indent + 2, "provider", profile.provider);
    try writeRequiredStringPretty(writer, &wrote, indent + 2, "profile_name", profile.profile_name);
    try writeRequiredStringPretty(writer, &wrote, indent + 2, "kind", profile.kind);
    try writeOptionalStringPretty(writer, &wrote, indent + 2, "account_id", profile.account_id);
    try writeOptionalStringPretty(writer, &wrote, indent + 2, "workspace_id", profile.workspace_id);
    try writeOptionalStringPretty(writer, &wrote, indent + 2, "access_token", profile.access_token);
    try writeOptionalStringPretty(writer, &wrote, indent + 2, "refresh_token", profile.refresh_token);
    try writeOptionalStringPretty(writer, &wrote, indent + 2, "id_token", profile.id_token);
    try writeOptionalStringPretty(writer, &wrote, indent + 2, "token", profile.token);
    try writeOptionalStringPretty(writer, &wrote, indent + 2, "expires_at", profile.expires_at);
    try writeOptionalStringPretty(writer, &wrote, indent + 2, "token_type", profile.token_type);
    try writeOptionalStringPretty(writer, &wrote, indent + 2, "scope", profile.scope);
    try writeRequiredStringPretty(writer, &wrote, indent + 2, "created_at", profile.created_at);
    try writeRequiredStringPretty(writer, &wrote, indent + 2, "updated_at", profile.updated_at);
    try writeFieldPrefix(writer, &wrote, indent + 2, "metadata");
    try writeStringMapPretty(writer, allocator, profile.metadata, indent + 2);
    try writer.writeByte('\n');
    try writeIndent(writer, indent);
    try writer.writeByte('}');
}

fn writeStringMapPretty(writer: anytype, allocator: std.mem.Allocator, map: std.StringHashMap([]u8), indent: usize) !void {
    if (map.count() == 0) return writer.writeAll("{}");
    const keys = try sortedKeys(allocator, map);
    defer allocator.free(keys);
    try writer.writeAll("{\n");
    for (keys, 0..) |key, i| {
        if (i != 0) try writer.writeAll(",\n");
        try writeIndent(writer, indent + 2);
        try std.json.stringify(key, .{}, writer);
        try writer.writeAll(": ");
        try std.json.stringify(map.get(key).?, .{}, writer);
    }
    try writer.writeByte('\n');
    try writeIndent(writer, indent);
    try writer.writeByte('}');
}

fn writeRequiredStringPretty(writer: anytype, wrote: *bool, indent: usize, key: []const u8, value: []const u8) !void {
    try writeFieldPrefix(writer, wrote, indent, key);
    try std.json.stringify(value, .{}, writer);
}

fn writeOptionalStringPretty(writer: anytype, wrote: *bool, indent: usize, key: []const u8, value: ?[]const u8) !void {
    try writeFieldPrefix(writer, wrote, indent, key);
    if (value) |inner| try std.json.stringify(inner, .{}, writer) else try writer.writeAll("null");
}

fn writeFieldPrefix(writer: anytype, wrote: *bool, indent: usize, key: []const u8) !void {
    if (wrote.*) try writer.writeAll(",\n");
    try writeIndent(writer, indent);
    try std.json.stringify(key, .{}, writer);
    try writer.writeAll(": ");
    wrote.* = true;
}

fn writeIndent(writer: anytype, indent: usize) !void {
    try writer.writeByteNTimes(' ', indent);
}

fn sortedKeys(allocator: std.mem.Allocator, map: anytype) ![][]const u8 {
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

fn putStringValue(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8), key: []const u8, value: []const u8) !void {
    try map.ensureUnusedCapacity(1);
    const value_owned = try allocator.dupe(u8, value);
    errdefer allocator.free(value_owned);
    const gop = map.getOrPutAssumeCapacity(key);
    if (gop.found_existing) {
        allocator.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = allocator.dupe(u8, key) catch |err| {
            // Roll back the empty slot so deinit doesn't free uninitialized key/value pointers.
            map.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    gop.value_ptr.* = value_owned;
}

fn putProfileValue(allocator: std.mem.Allocator, map: *std.StringHashMap(AuthProfile), key: []const u8, value: AuthProfile) !void {
    try map.ensureUnusedCapacity(1);
    const gop = map.getOrPutAssumeCapacity(key);
    if (gop.found_existing) {
        gop.value_ptr.deinit(allocator);
    } else {
        gop.key_ptr.* = allocator.dupe(u8, key) catch |err| {
            map.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    gop.value_ptr.* = value;
}

fn putPersistedProfile(allocator: std.mem.Allocator, map: *std.StringHashMap(PersistedAuthProfile), key: []const u8, value: PersistedAuthProfile) !void {
    try map.ensureUnusedCapacity(1);
    const gop = map.getOrPutAssumeCapacity(key);
    if (gop.found_existing) {
        gop.value_ptr.deinit(allocator);
    } else {
        gop.key_ptr.* = allocator.dupe(u8, key) catch |err| {
            map.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    gop.value_ptr.* = value;
}

fn cloneStringMap(allocator: std.mem.Allocator, map: std.StringHashMap([]u8)) !std.StringHashMap([]u8) {
    var out = std.StringHashMap([]u8).init(allocator);
    errdefer deinitStringMap(allocator, &out);
    try cloneStringMapInto(allocator, &out, map);
    return out;
}

fn cloneStringMapInto(allocator: std.mem.Allocator, out: *std.StringHashMap([]u8), map: std.StringHashMap([]u8)) !void {
    var it = map.iterator();
    while (it.next()) |entry| try putStringValue(allocator, out, entry.key_ptr.*, entry.value_ptr.*);
}

fn deinitStringMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn removeEmptyActiveProfiles(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8)) void {
    var to_remove = std.ArrayList([]u8).init(allocator);
    defer to_remove.deinit();
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.len == 0) to_remove.append(entry.key_ptr.*) catch {};
    }
    for (to_remove.items) |key| {
        if (map.fetchRemove(key)) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
    }
}

fn cloneOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    if (value) |inner| return try allocator.dupe(u8, inner);
    return null;
}

fn freeOptional(allocator: std.mem.Allocator, value: DecryptedOptional) void {
    if (value.plaintext) |inner| allocator.free(inner);
    if (value.migrated) |inner| allocator.free(inner);
}

fn replaceOptional(allocator: std.mem.Allocator, slot: *?[]u8, value: []u8) !void {
    if (slot.*) |old| allocator.free(old);
    slot.* = value;
}

fn buildLoadedProfileShell(
    allocator: std.mem.Allocator,
    id: []const u8,
    p: *const PersistedAuthProfile,
    kind: AuthProfileKind,
    now_unix_seconds: i64,
) !AuthProfile {
    const id_owned = try allocator.dupe(u8, id);
    errdefer allocator.free(id_owned);
    const provider_owned = try allocator.dupe(u8, p.provider);
    errdefer allocator.free(provider_owned);
    const profile_name_owned = try allocator.dupe(u8, p.profile_name);
    errdefer allocator.free(profile_name_owned);
    const account_id = try cloneOptional(allocator, p.account_id);
    errdefer if (account_id) |value| allocator.free(value);
    const workspace_id = try cloneOptional(allocator, p.workspace_id);
    errdefer if (workspace_id) |value| allocator.free(value);
    var metadata = try cloneStringMap(allocator, p.metadata);
    errdefer deinitStringMap(allocator, &metadata);

    return .{
        .id = id_owned,
        .provider = provider_owned,
        .profile_name = profile_name_owned,
        .kind = kind,
        .account_id = account_id,
        .workspace_id = workspace_id,
        .metadata = metadata,
        .created_at_unix_seconds = datetime.parseRfc3339WithFallback(p.created_at, now_unix_seconds),
        .updated_at_unix_seconds = datetime.parseRfc3339WithFallback(p.updated_at, now_unix_seconds),
    };
}

fn buildOauthTokenSet(
    allocator: std.mem.Allocator,
    p: *const PersistedAuthProfile,
    access_token_owned: []u8,
    refresh_plaintext: ?[]u8,
    id_token_plaintext: ?[]u8,
) !TokenSet {
    // On error: free the three "owned" inputs that were transferred to us.
    // On success: returned TokenSet owns them; caller takes responsibility.
    errdefer allocator.free(access_token_owned);
    errdefer if (refresh_plaintext) |value| allocator.free(value);
    errdefer if (id_token_plaintext) |value| allocator.free(value);

    const expires_at = try datetime.parseOptionalRfc3339(p.expires_at);
    const token_type = try cloneOptional(allocator, p.token_type);
    errdefer if (token_type) |value| allocator.free(value);
    const scope = try cloneOptional(allocator, p.scope);

    return .{
        .access_token = access_token_owned,
        .refresh_token = refresh_plaintext,
        .id_token = id_token_plaintext,
        .expires_at_utc_seconds = expires_at,
        .token_type = token_type,
        .scope = scope,
    };
}

fn jsonString(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidJson;
    return value.string;
}

fn jsonStringDup(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return allocator.dupe(u8, try jsonString(value));
}

fn requiredJsonStringDup(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]u8 {
    return jsonStringDup(allocator, value.object.get(key) orelse return error.InvalidJson);
}

fn optionalJsonStringDup(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) !?[]u8 {
    const inner = value.object.get(key) orelse return null;
    if (inner == .null) return null;
    return try jsonStringDup(allocator, inner);
}

fn jsonI64(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |inner| inner,
        else => error.InvalidJson,
    };
}

test "profileId trims ASCII whitespace" {
    const id = try profileId(std.testing.allocator, " openai-codex ", "\tdefault\n");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("openai-codex:default", id);
}

test "AuthProfile constructors set kind and owned id" {
    const token_set = TokenSet{
        .access_token = try std.testing.allocator.dupe(u8, "access"),
    };
    var oauth = try AuthProfile.newOauth(std.testing.allocator, "openai-codex", "default", token_set, 10);
    defer oauth.deinit(std.testing.allocator);
    try std.testing.expectEqual(AuthProfileKind.OAuth, oauth.kind);
    try std.testing.expectEqualStrings("openai-codex:default", oauth.id);

    var token = try AuthProfile.newToken(std.testing.allocator, "openai", "api", "sk-token", 11);
    defer token.deinit(std.testing.allocator);
    try std.testing.expectEqual(AuthProfileKind.Token, token.kind);
    try std.testing.expectEqualStrings("openai:api", token.id);
}

test "AuthProfilesStore rejects unsupported schema version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(state_dir);
    const profiles_path = try std.fs.path.join(std.testing.allocator, &.{ state_dir, PROFILES_FILENAME });
    defer std.testing.allocator.free(profiles_path);
    var file = try std.fs.cwd().createFile(profiles_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\"schema_version\":99,\"updated_at\":\"2023-11-14T22:13:20+00:00\",\"active_profiles\":{},\"profiles\":{}}");

    var store = try AuthProfilesStore.new(std.testing.allocator, state_dir, false);
    defer store.deinit();
    try std.testing.expectError(error.UnsupportedSchemaVersion, store.load());
}

test "AuthProfilesStore roundtrips encrypted OAuth profile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(state_dir);

    var store = try AuthProfilesStore.new(std.testing.allocator, state_dir, true);
    defer store.deinit();

    var profile = try AuthProfile.newOauth(std.testing.allocator, "openai-codex", "default", .{
        .access_token = try std.testing.allocator.dupe(u8, "access-123"),
        .refresh_token = try std.testing.allocator.dupe(u8, "refresh-123"),
        .token_type = try std.testing.allocator.dupe(u8, "Bearer"),
        .scope = try std.testing.allocator.dupe(u8, "openid offline_access"),
        .expires_at_utc_seconds = 1_800_000_000,
    }, 1_700_000_000);
    defer profile.deinit(std.testing.allocator);
    profile.account_id = try std.testing.allocator.dupe(u8, "acct_123");

    try store.upsertProfile(&profile, true, 1_700_000_010);
    var data = try store.load();
    defer data.deinit(std.testing.allocator);
    const loaded = data.profiles.get(profile.id).?;
    try std.testing.expectEqualStrings("acct_123", loaded.account_id.?);
    try std.testing.expectEqualStrings("refresh-123", loaded.token_set.?.refresh_token.?);

    const raw = try std.fs.cwd().readFileAlloc(std.testing.allocator, store.path(), 1024 * 1024);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "enc2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "refresh-123") == null);
}

// Build a populated OAuth AuthProfile while staying leak-safe under
// FailingAllocator sweeps. Uses a `transferred` flag so newOauth's consumption
// of the TokenSet on success doesn't double-free with the errdefer above it.
fn buildSampleOauthProfile(allocator: std.mem.Allocator) !AuthProfile {
    var token_set = TokenSet{ .access_token = try allocator.dupe(u8, "access-123") };
    var token_owned_by_profile = false;
    errdefer if (!token_owned_by_profile) token_set.deinit(allocator);

    token_set.refresh_token = try allocator.dupe(u8, "refresh-123");
    token_set.token_type = try allocator.dupe(u8, "Bearer");
    token_set.scope = try allocator.dupe(u8, "openid offline_access");
    token_set.expires_at_utc_seconds = 1_800_000_000;

    var profile = try AuthProfile.newOauth(
        allocator,
        "openai-codex",
        "default",
        token_set,
        1_700_000_000,
    );
    token_owned_by_profile = true;
    errdefer profile.deinit(allocator);

    profile.account_id = try allocator.dupe(u8, "acct_123");
    return profile;
}

fn upsertOomImpl(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const state_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(state_dir);

    var store = try AuthProfilesStore.new(allocator, state_dir, true);
    defer store.deinit();

    var profile = try buildSampleOauthProfile(allocator);
    defer profile.deinit(allocator);

    try store.upsertProfile(&profile, true, 1_700_000_010);
}

test "AuthProfilesStore.upsertProfile is OOM-safe (regression for move-semantics fix)" {
    // Sweeps fail_index across the full upsert path: clone, putStringValue,
    // putProfileValue, saveLocked (which writes encrypted JSON to disk).
    // The previous always-armed errdefer would double-free `stored` once
    // putProfileValue had moved ownership into the profiles map and a later
    // saveLocked failure unwound back through it.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, upsertOomImpl, .{});
}

fn loadOomImpl(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Stage a populated profiles.json with std.testing.allocator (outside the
    // failing-allocator sweep) so that load() under the failing allocator
    // exercises the full read+decrypt+rebuild path on every iteration.
    {
        const setup_alloc = std.testing.allocator;
        const setup_state_dir = try tmp.dir.realpathAlloc(setup_alloc, ".");
        defer setup_alloc.free(setup_state_dir);
        var setup_store = try AuthProfilesStore.new(setup_alloc, setup_state_dir, true);
        defer setup_store.deinit();
        var setup_profile = try buildSampleOauthProfile(setup_alloc);
        defer setup_profile.deinit(setup_alloc);
        try setup_store.upsertProfile(&setup_profile, true, 1_700_000_010);
    }

    const state_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(state_dir);

    var store = try AuthProfilesStore.new(allocator, state_dir, true);
    defer store.deinit();

    var data = try store.load();
    defer data.deinit(allocator);
}

test "AuthProfilesStore.load is OOM-safe (regression for struct-literal leak fix)" {
    // Sweeps fail_index across the load path: JSON parse, decrypt, build the
    // AuthProfile shell, then build the TokenSet. The previous inline struct
    // literal leaked partially-allocated owned strings if any later field's
    // alloc failed mid-construction.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadOomImpl, .{});
}

test "AuthProfilesStore writePersistedLocked recovers from rename failure (regression for double-close fix)" {
    // The fix changed an explicit file.close() followed by `errdefer file.close()`
    // into a scoped `defer file.close()`. To trigger the rename-failure path
    // we pre-create a non-empty directory at the auth-profiles.json path so
    // rename(file, dir) fails on POSIX. Don't pin a specific error tag —
    // rename-into-dir errors vary across macOS/Linux/Zig versions. The pass
    // criterion is "any error returned, no double-close crash".
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const state_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(state_dir);

    const profiles_path = try std.fs.path.join(std.testing.allocator, &.{ state_dir, PROFILES_FILENAME });
    defer std.testing.allocator.free(profiles_path);
    try std.fs.cwd().makePath(profiles_path);
    const sentinel_path = try std.fs.path.join(std.testing.allocator, &.{ profiles_path, ".keep" });
    defer std.testing.allocator.free(sentinel_path);
    {
        var sentinel = try std.fs.cwd().createFile(sentinel_path, .{ .truncate = true });
        sentinel.close();
    }

    var store = try AuthProfilesStore.new(std.testing.allocator, state_dir, true);
    defer store.deinit();

    var profile = try buildSampleOauthProfile(std.testing.allocator);
    defer profile.deinit(std.testing.allocator);

    store.upsertProfile(&profile, true, 1_700_000_010) catch return;
    return error.TestExpectedError;
}
