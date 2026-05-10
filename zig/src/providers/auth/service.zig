const std = @import("std");
const api = @import("../../api/root.zig");
const openai_oauth = @import("openai_oauth.zig");
const profiles_mod = @import("profiles.zig");
const types = @import("types.zig");

pub const AuthProfile = profiles_mod.AuthProfile;
pub const AuthProfileKind = profiles_mod.AuthProfileKind;
pub const AuthProfilesData = profiles_mod.AuthProfilesData;
pub const AuthProfilesStore = profiles_mod.AuthProfilesStore;
pub const TokenSet = types.TokenSet;

const OPENAI_CODEX_PROVIDER = "openai-codex";
const DEFAULT_PROFILE_NAME = "default";
const OPENAI_REFRESH_SKEW_SECS: u64 = 90;
const OPENAI_REFRESH_FAILURE_BACKOFF_SECS: i64 = 10;
const OAUTH_REFRESH_MAX_ATTEMPTS: usize = 3;
const OAUTH_REFRESH_RETRY_BASE_DELAY_MS: u64 = 350;

pub const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const HttpPostFn = *const fn (std.mem.Allocator, []const u8, []const u8) anyerror!HttpResponse;
pub const SleepMillisFn = *const fn (u64) void;

pub const AuthService = struct {
    allocator: std.mem.Allocator,
    store: AuthProfilesStore,
    refresh_state: *RefreshState,

    pub fn init(allocator: std.mem.Allocator, state_dir: []const u8, encrypt_secrets: bool) !AuthService {
        const refresh_state = try allocator.create(RefreshState);
        errdefer allocator.destroy(refresh_state);
        refresh_state.* = RefreshState.init(allocator);
        errdefer refresh_state.deinit();
        const store = try AuthProfilesStore.new(allocator, state_dir, encrypt_secrets);
        return .{
            .allocator = allocator,
            .store = store,
            .refresh_state = refresh_state,
        };
    }

    pub fn new(allocator: std.mem.Allocator, state_dir: []const u8, encrypt_secrets: bool) !AuthService {
        return init(allocator, state_dir, encrypt_secrets);
    }

    pub fn fromConfig(allocator: std.mem.Allocator, config: api.config.AuthConfig) !AuthService {
        const state_dir = try api.config.stateDirFromConfig(allocator, config);
        defer allocator.free(state_dir);
        return init(allocator, state_dir, config.encrypt_secrets);
    }

    pub fn deinit(self: *AuthService) void {
        self.refresh_state.deinit();
        self.allocator.destroy(self.refresh_state);
        self.store.deinit();
        self.* = undefined;
    }

    pub fn loadProfiles(self: *const AuthService) !AuthProfilesData {
        return self.store.load();
    }

    pub fn storeOpenaiTokens(
        self: *const AuthService,
        profile_name: []const u8,
        token_set: TokenSet,
        account_id: ?[]const u8,
        set_active: bool,
        now_unix_seconds: i64,
    ) !AuthProfile {
        var profile = try AuthProfile.newOauth(self.allocator, OPENAI_CODEX_PROVIDER, profile_name, token_set, now_unix_seconds);
        errdefer profile.deinit(self.allocator);
        if (account_id) |value| profile.account_id = try self.allocator.dupe(u8, value);
        try self.store.upsertProfile(&profile, set_active, now_unix_seconds);
        return profile;
    }

    pub fn storeProviderToken(
        self: *const AuthService,
        provider: []const u8,
        profile_name: []const u8,
        token: []const u8,
        metadata: std.StringHashMap([]u8),
        set_active: bool,
        now_unix_seconds: i64,
    ) !AuthProfile {
        const normalized = try normalizeProviderOwned(self.allocator, provider);
        defer self.allocator.free(normalized);
        var profile = try AuthProfile.newToken(self.allocator, normalized, profile_name, token, now_unix_seconds);
        errdefer profile.deinit(self.allocator);
        var it = metadata.iterator();
        while (it.next()) |entry| try putStringValue(self.allocator, &profile.metadata, entry.key_ptr.*, entry.value_ptr.*);
        try self.store.upsertProfile(&profile, set_active, now_unix_seconds);
        return profile;
    }

    pub fn setActiveProfile(
        self: *const AuthService,
        provider: []const u8,
        requested_profile: []const u8,
        now_unix_seconds: i64,
    ) ![]u8 {
        const normalized = try normalizeProviderOwned(self.allocator, provider);
        defer self.allocator.free(normalized);
        var data = try self.store.load();
        defer data.deinit(self.allocator);
        const id = try resolveRequestedProfileId(self.allocator, normalized, requested_profile);
        errdefer self.allocator.free(id);
        const profile = data.profiles.get(id) orelse return error.ProfileNotFound;
        if (!std.mem.eql(u8, profile.provider, normalized)) return error.ProviderMismatch;
        try self.store.setActiveProfile(normalized, id, now_unix_seconds);
        return id;
    }

    pub fn removeProfile(self: *const AuthService, provider: []const u8, requested_profile: []const u8, now_unix_seconds: i64) !bool {
        const normalized = try normalizeProviderOwned(self.allocator, provider);
        defer self.allocator.free(normalized);
        const id = try resolveRequestedProfileId(self.allocator, normalized, requested_profile);
        defer self.allocator.free(id);
        return self.store.removeProfile(id, now_unix_seconds);
    }

    pub fn getProfile(self: *const AuthService, provider: []const u8, profile_override: ?[]const u8) !?AuthProfile {
        const normalized = try normalizeProviderOwned(self.allocator, provider);
        defer self.allocator.free(normalized);
        var data = try self.store.load();
        defer data.deinit(self.allocator);
        const selected = try selectProfileId(self.allocator, &data, normalized, profile_override);
        defer if (selected) |id| self.allocator.free(id);
        if (selected) |id| {
            const profile = data.profiles.get(id) orelse return null;
            return try profile.clone(self.allocator);
        }
        return null;
    }

    pub fn getProviderBearerToken(self: *const AuthService, provider: []const u8, profile_override: ?[]const u8) !?[]u8 {
        var profile = (try self.getProfile(provider, profile_override)) orelse return null;
        defer profile.deinit(self.allocator);
        const credential = switch (profile.kind) {
            .Token => profile.token,
            .OAuth => if (profile.token_set) |token_set| token_set.access_token else null,
        } orelse return null;
        if (std.mem.trim(u8, credential, " \t\r\n").len == 0) return null;
        return try self.allocator.dupe(u8, credential);
    }

    pub fn getValidOpenaiAccessToken(
        self: *const AuthService,
        profile_override: ?[]const u8,
        now_unix_seconds: i64,
    ) !?[]u8 {
        var data = try self.store.load();
        defer data.deinit(self.allocator);
        const selected = try selectProfileId(self.allocator, &data, OPENAI_CODEX_PROVIDER, profile_override);
        defer if (selected) |id| self.allocator.free(id);
        const profile_id_value = selected orelse return null;
        const profile = data.profiles.get(profile_id_value) orelse return null;
        const token_set = profile.token_set orelse return error.BadProfile;

        if (!token_set.isExpiringWithin(now_unix_seconds, OPENAI_REFRESH_SKEW_SECS)) {
            return try self.allocator.dupe(u8, token_set.access_token);
        }
        const refresh_token_initial = token_set.refresh_token orelse return try self.allocator.dupe(u8, token_set.access_token);

        // Singleflight: acquire per-profile mutex so concurrent callers
        // serialize on this profile's refresh. After the lock, re-load
        // from disk in case another holder of the lock already refreshed
        // (matches Rust auth/mod.rs:188-195).
        const refresh_lock = try self.refresh_state.lockForProfile(profile_id_value);
        refresh_lock.lock();
        defer refresh_lock.unlock();

        var data2 = try self.store.load();
        defer data2.deinit(self.allocator);
        const latest_profile = data2.profiles.get(profile_id_value) orelse return null;
        const latest_token_set = latest_profile.token_set orelse return error.BadProfile;

        if (!latest_token_set.isExpiringWithin(now_unix_seconds, OPENAI_REFRESH_SKEW_SECS)) {
            return try self.allocator.dupe(u8, latest_token_set.access_token);
        }
        const latest_refresh_token = latest_token_set.refresh_token orelse refresh_token_initial;

        // Failure backoff: if a previous refresh failed within the backoff
        // window, bail rather than hammering the OAuth server. Rust uses
        // anyhow::bail! with a string; Zig returns a typed error so callers
        // can match on it without parsing.
        if (self.refresh_state.backoffRemainingSeconds(profile_id_value, now_unix_seconds) != null) {
            return error.RefreshInBackoff;
        }

        var refreshed = refreshOpenaiAccessTokenWithRetries(self.allocator, latest_refresh_token, postFormBody, sleepMillis) catch |err| {
            // setBackoff can itself OOM; if so the caller still surfaces the
            // original refresh error rather than a less useful OOM masking it.
            self.refresh_state.setBackoff(profile_id_value, now_unix_seconds, OPENAI_REFRESH_FAILURE_BACKOFF_SECS) catch {};
            return err;
        };
        defer refreshed.deinit(self.allocator);
        self.refresh_state.clearBackoff(profile_id_value);

        if (refreshed.refresh_token == null) {
            refreshed.refresh_token = try self.allocator.dupe(u8, latest_refresh_token);
        }

        var ctx = UpdateOpenaiContext{ .tokens = refreshed, .account_id = null };
        if (try openai_oauth.extractAccountIdFromJwt(self.allocator, refreshed.access_token)) |account_id| {
            ctx.account_id = account_id;
        } else if (latest_profile.account_id) |account_id| {
            ctx.account_id = try self.allocator.dupe(u8, account_id);
        }
        defer if (ctx.account_id) |account_id| self.allocator.free(account_id);

        var updated = try self.store.updateProfile(profile_id_value, now_unix_seconds, &ctx, updateOpenaiProfile);
        defer updated.deinit(self.allocator);
        if (updated.token_set) |updated_tokens| return try self.allocator.dupe(u8, updated_tokens.access_token);
        return null;
    }
};

// Per-profile refresh singleflight and failure backoff. Sync-only for the
// pilot; the per-profile mutex is harmless overhead in single-threaded
// callers and the documented contract once libxev / multi-thread arrives.
// The locks themselves live behind heap pointers (RefreshState owns them
// for its lifetime) so callers can safely hold a *std.Thread.Mutex across
// store I/O without worrying about the map being resized.
const RefreshState = struct {
    allocator: std.mem.Allocator,
    table_mutex: std.Thread.Mutex,
    locks: std.StringHashMap(*std.Thread.Mutex),
    backoffs: std.StringHashMap(i64),

    fn init(allocator: std.mem.Allocator) RefreshState {
        return .{
            .allocator = allocator,
            .table_mutex = .{},
            .locks = std.StringHashMap(*std.Thread.Mutex).init(allocator),
            .backoffs = std.StringHashMap(i64).init(allocator),
        };
    }

    fn deinit(self: *RefreshState) void {
        var locks_it = self.locks.iterator();
        while (locks_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.locks.deinit();
        var backoffs_it = self.backoffs.iterator();
        while (backoffs_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.backoffs.deinit();
        self.* = undefined;
    }

    fn lockForProfile(self: *RefreshState, profile_id: []const u8) !*std.Thread.Mutex {
        self.table_mutex.lock();
        defer self.table_mutex.unlock();
        try self.locks.ensureUnusedCapacity(1);
        const gop = self.locks.getOrPutAssumeCapacity(profile_id);
        if (!gop.found_existing) {
            const mutex_ptr = self.allocator.create(std.Thread.Mutex) catch |err| {
                self.locks.removeByPtr(gop.key_ptr);
                return err;
            };
            errdefer self.allocator.destroy(mutex_ptr);
            const key_owned = self.allocator.dupe(u8, profile_id) catch |err| {
                self.locks.removeByPtr(gop.key_ptr);
                return err;
            };
            mutex_ptr.* = .{};
            gop.key_ptr.* = key_owned;
            gop.value_ptr.* = mutex_ptr;
        }
        return gop.value_ptr.*;
    }

    fn backoffRemainingSeconds(self: *RefreshState, profile_id: []const u8, now_unix_seconds: i64) ?i64 {
        self.table_mutex.lock();
        defer self.table_mutex.unlock();
        const deadline = self.backoffs.get(profile_id) orelse return null;
        if (deadline <= now_unix_seconds) {
            if (self.backoffs.fetchRemove(profile_id)) |entry| {
                self.allocator.free(entry.key);
            }
            return null;
        }
        return @max(@as(i64, 1), deadline - now_unix_seconds);
    }

    fn setBackoff(self: *RefreshState, profile_id: []const u8, now_unix_seconds: i64, duration_seconds: i64) !void {
        self.table_mutex.lock();
        defer self.table_mutex.unlock();
        const deadline = std.math.add(i64, now_unix_seconds, duration_seconds) catch std.math.maxInt(i64);
        try self.backoffs.ensureUnusedCapacity(1);
        const gop = self.backoffs.getOrPutAssumeCapacity(profile_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, profile_id) catch |err| {
                self.backoffs.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = deadline;
    }

    fn clearBackoff(self: *RefreshState, profile_id: []const u8) void {
        self.table_mutex.lock();
        defer self.table_mutex.unlock();
        if (self.backoffs.fetchRemove(profile_id)) |entry| {
            self.allocator.free(entry.key);
        }
    }
};

const UpdateOpenaiContext = struct {
    tokens: TokenSet,
    account_id: ?[]u8,
};

fn updateOpenaiProfile(ctx: *UpdateOpenaiContext, profile: *AuthProfile) !void {
    const allocator = profile.metadata.allocator;
    if (profile.token_set) |*old| old.deinit(allocator);
    profile.token_set = try ctx.tokens.clone(allocator);
    profile.kind = .OAuth;
    if (profile.account_id) |old_account| allocator.free(old_account);
    profile.account_id = if (ctx.account_id) |account_id| try allocator.dupe(u8, account_id) else null;
}

pub fn normalizeProvider(allocator: std.mem.Allocator, provider: []const u8) ![]u8 {
    return normalizeProviderOwned(allocator, provider);
}

fn normalizeProviderOwned(allocator: std.mem.Allocator, provider: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, provider, " \t\r\n");
    if (trimmed.len == 0) return error.ProviderNameEmpty;
    const lower = try std.ascii.allocLowerString(allocator, trimmed);
    errdefer allocator.free(lower);
    if (std.mem.eql(u8, lower, "openai-codex") or
        std.mem.eql(u8, lower, "openai_codex") or
        std.mem.eql(u8, lower, "codex"))
    {
        allocator.free(lower);
        return allocator.dupe(u8, OPENAI_CODEX_PROVIDER);
    }
    return lower;
}

pub fn defaultProfileId(allocator: std.mem.Allocator, provider: []const u8) ![]u8 {
    return profiles_mod.profileId(allocator, provider, DEFAULT_PROFILE_NAME);
}

pub fn resolveRequestedProfileId(allocator: std.mem.Allocator, provider: []const u8, requested: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, requested, ':') != null) return allocator.dupe(u8, requested);
    return profiles_mod.profileId(allocator, provider, requested);
}

pub fn selectProfileId(
    allocator: std.mem.Allocator,
    data: *const AuthProfilesData,
    provider: []const u8,
    profile_override: ?[]const u8,
) !?[]u8 {
    if (profile_override) |override_profile| {
        const requested = try resolveRequestedProfileId(allocator, provider, override_profile);
        errdefer allocator.free(requested);
        if (data.profiles.contains(requested)) return requested;
        allocator.free(requested);
        return null;
    }

    if (data.active_profiles.get(provider)) |active| {
        if (data.profiles.contains(active)) return try allocator.dupe(u8, active);
    }

    const default_id = try defaultProfileId(allocator, provider);
    errdefer allocator.free(default_id);
    if (data.profiles.contains(default_id)) return default_id;
    allocator.free(default_id);

    const keys = try sortedProfileKeys(allocator, data.profiles);
    defer allocator.free(keys);
    for (keys) |key| {
        const profile = data.profiles.get(key).?;
        if (std.mem.eql(u8, profile.provider, provider)) return try allocator.dupe(u8, key);
    }
    return null;
}

pub fn refreshOpenaiAccessTokenWithRetries(
    allocator: std.mem.Allocator,
    refresh_token: []const u8,
    post_fn: HttpPostFn,
    sleep_fn: SleepMillisFn,
) !TokenSet {
    var last_error: ?anyerror = null;
    for (1..OAUTH_REFRESH_MAX_ATTEMPTS + 1) |attempt| {
        const body = try openai_oauth.buildTokenRequestBodyRefreshToken(allocator, refresh_token);
        defer allocator.free(body);
        var response = post_fn(allocator, openai_oauth.OPENAI_OAUTH_TOKEN_URL, body) catch |err| {
            last_error = err;
            if (attempt < OAUTH_REFRESH_MAX_ATTEMPTS) sleep_fn(OAUTH_REFRESH_RETRY_BASE_DELAY_MS * @as(u64, @intCast(attempt)));
            continue;
        };
        defer response.deinit(allocator);
        if (response.status.class() == .success) {
            return openai_oauth.parseTokenResponseBody(allocator, response.body, std.time.timestamp());
        }
        last_error = error.OAuthTokenRequestFailed;
        if (attempt < OAUTH_REFRESH_MAX_ATTEMPTS) sleep_fn(OAUTH_REFRESH_RETRY_BASE_DELAY_MS * @as(u64, @intCast(attempt)));
    }
    return last_error orelse error.OAuthTokenRequestFailed;
}

fn postFormBody(allocator: std.mem.Allocator, url: []const u8, request_body: []const u8) !HttpResponse {
    var response_body = std.ArrayList(u8).init(allocator);
    errdefer response_body.deinit();
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = request_body,
        .response_storage = .{ .dynamic = &response_body },
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
    });
    return .{ .status = result.status, .body = try response_body.toOwnedSlice() };
}

fn sleepMillis(ms: u64) void {
    std.Thread.sleep(std.math.mul(u64, ms, std.time.ns_per_ms) catch std.math.maxInt(u64));
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
            map.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    gop.value_ptr.* = value_owned;
}

fn sortedProfileKeys(allocator: std.mem.Allocator, map: std.StringHashMap(AuthProfile)) ![][]const u8 {
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

test "normalizeProvider keeps only OpenAI Codex aliases special" {
    const codex = try normalizeProvider(std.testing.allocator, " codex ");
    defer std.testing.allocator.free(codex);
    try std.testing.expectEqualStrings("openai-codex", codex);
    const claude = try normalizeProvider(std.testing.allocator, "claude");
    defer std.testing.allocator.free(claude);
    try std.testing.expectEqualStrings("claude", claude);
}

test "selectProfileId prefers override then active then default" {
    var data = AuthProfilesData.init(std.testing.allocator, 1_700_000_000);
    defer data.deinit(std.testing.allocator);
    var default_profile = try AuthProfile.newToken(std.testing.allocator, OPENAI_CODEX_PROVIDER, "default", "x", 1);
    defer default_profile.deinit(std.testing.allocator);
    var active_profile = try AuthProfile.newToken(std.testing.allocator, OPENAI_CODEX_PROVIDER, "work", "y", 1);
    defer active_profile.deinit(std.testing.allocator);
    try putProfileForTest(std.testing.allocator, &data.profiles, &default_profile);
    try putProfileForTest(std.testing.allocator, &data.profiles, &active_profile);
    try putStringValue(std.testing.allocator, &data.active_profiles, OPENAI_CODEX_PROVIDER, active_profile.id);

    const override_id = try selectProfileId(std.testing.allocator, &data, OPENAI_CODEX_PROVIDER, "default");
    defer std.testing.allocator.free(override_id.?);
    try std.testing.expectEqualStrings(default_profile.id, override_id.?);
    const active_id = try selectProfileId(std.testing.allocator, &data, OPENAI_CODEX_PROVIDER, null);
    defer std.testing.allocator.free(active_id.?);
    try std.testing.expectEqualStrings(active_profile.id, active_id.?);
}

test "resolveRequestedProfileId only prefixes bare names" {
    const bare = try resolveRequestedProfileId(std.testing.allocator, OPENAI_CODEX_PROVIDER, "default");
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("openai-codex:default", bare);

    const full = try resolveRequestedProfileId(std.testing.allocator, OPENAI_CODEX_PROVIDER, "other:default");
    defer std.testing.allocator.free(full);
    try std.testing.expectEqualStrings("other:default", full);
}

test "selectProfileId falls back to sorted provider match" {
    var data = AuthProfilesData.init(std.testing.allocator, 1_700_000_000);
    defer data.deinit(std.testing.allocator);
    var beta = try AuthProfile.newToken(std.testing.allocator, OPENAI_CODEX_PROVIDER, "zeta", "z", 1);
    defer beta.deinit(std.testing.allocator);
    var alpha = try AuthProfile.newToken(std.testing.allocator, OPENAI_CODEX_PROVIDER, "alpha", "a", 1);
    defer alpha.deinit(std.testing.allocator);
    try putProfileForTest(std.testing.allocator, &data.profiles, &beta);
    try putProfileForTest(std.testing.allocator, &data.profiles, &alpha);

    const selected = try selectProfileId(std.testing.allocator, &data, OPENAI_CODEX_PROVIDER, "missing");
    try std.testing.expect(selected == null);
    const fallback = try selectProfileId(std.testing.allocator, &data, OPENAI_CODEX_PROVIDER, null);
    defer std.testing.allocator.free(fallback.?);
    try std.testing.expectEqualStrings(alpha.id, fallback.?);
}

fn putProfileForTest(allocator: std.mem.Allocator, map: *std.StringHashMap(AuthProfile), profile: *const AuthProfile) !void {
    try map.ensureUnusedCapacity(1);
    const clone = try profile.clone(allocator);
    errdefer {
        var tmp = clone;
        tmp.deinit(allocator);
    }
    const gop = map.getOrPutAssumeCapacity(profile.id);
    if (!gop.found_existing) {
        gop.key_ptr.* = allocator.dupe(u8, profile.id) catch |err| {
            map.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    gop.value_ptr.* = clone;
}

fn putStringValueOomImpl(allocator: std.mem.Allocator) !void {
    var map = std.StringHashMap([]u8).init(allocator);
    defer {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    // Cover both put-new (key dupe) and put-existing (value replace) branches.
    try putStringValue(allocator, &map, "key1", "value1");
    try putStringValue(allocator, &map, "key2", "value2");
    try putStringValue(allocator, &map, "key1", "value1-updated");
}

test "service.putStringValue is OOM-safe (regression for OOM-pattern audit)" {
    // Regression for the audit's getOrPut + later-key-alloc pattern:
    // std.HashMap.getOrPut auto-sets gop.key_ptr.* to the borrowed key, so
    // a failed allocator.dupe(key) afterward left an entry pointing at
    // borrowed memory; a later deinit would free borrowed bytes. Now uses
    // ensureUnusedCapacity + getOrPutAssumeCapacity + removeByPtr rollback.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, putStringValueOomImpl, .{});
}

fn putProfileForTestOomImpl(allocator: std.mem.Allocator) !void {
    var map = std.StringHashMap(AuthProfile).init(allocator);
    defer {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        map.deinit();
    }

    var profile = try AuthProfile.newToken(allocator, OPENAI_CODEX_PROVIDER, "default", "secret", 1_700_000_000);
    defer profile.deinit(allocator);

    try putProfileForTest(allocator, &map, &profile);
}

test "service.putProfileForTest is OOM-safe (regression for OOM-pattern audit)" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, putProfileForTestOomImpl, .{});
}

test "RefreshState backoff math: set, remaining, expiry-clears, clear" {
    var state = RefreshState.init(std.testing.allocator);
    defer state.deinit();

    const now: i64 = 1_700_000_000;

    // No backoff yet.
    try std.testing.expect(state.backoffRemainingSeconds("openai-codex:default", now) == null);

    // Set 10s backoff.
    try state.setBackoff("openai-codex:default", now, 10);

    // 5s into the window, remaining should be 5.
    try std.testing.expectEqual(@as(?i64, 5), state.backoffRemainingSeconds("openai-codex:default", now + 5));

    // At the deadline, remaining should be null and the entry is purged.
    try std.testing.expect(state.backoffRemainingSeconds("openai-codex:default", now + 10) == null);
    try std.testing.expect(state.backoffRemainingSeconds("openai-codex:default", now + 5) == null);

    // Set again, then clearBackoff explicitly.
    try state.setBackoff("openai-codex:default", now, 10);
    state.clearBackoff("openai-codex:default");
    try std.testing.expect(state.backoffRemainingSeconds("openai-codex:default", now + 1) == null);

    // backoffRemainingSeconds always returns at least 1 even if very near the deadline.
    try state.setBackoff("openai-codex:default", now, 10);
    try std.testing.expectEqual(@as(?i64, 1), state.backoffRemainingSeconds("openai-codex:default", now + 9));
}

test "RefreshState lockForProfile returns the same mutex pointer for the same profile" {
    var state = RefreshState.init(std.testing.allocator);
    defer state.deinit();

    const a1 = try state.lockForProfile("openai-codex:default");
    const a2 = try state.lockForProfile("openai-codex:default");
    try std.testing.expectEqual(a1, a2);

    const b = try state.lockForProfile("openai-codex:other");
    try std.testing.expect(a1 != b);

    // Lock + unlock works (sanity check; no contention test in single-threaded run).
    a1.lock();
    a1.unlock();
}

fn refreshStateSetBackoffOomImpl(allocator: std.mem.Allocator) !void {
    var state = RefreshState.init(allocator);
    defer state.deinit();
    try state.setBackoff("openai-codex:default", 1_700_000_000, 10);
    try state.setBackoff("openai-codex:other", 1_700_000_000, 5);
    try state.setBackoff("openai-codex:default", 1_700_000_000, 20); // update path
}

test "RefreshState.setBackoff is OOM-safe" {
    // RefreshState's two maps use the same `getOrPut + dupe(key)` pattern as
    // the put helpers fixed in commit 47a7dc8. Sweep verifies the same
    // template applies here.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, refreshStateSetBackoffOomImpl, .{});
}

fn refreshStateLockForProfileOomImpl(allocator: std.mem.Allocator) !void {
    var state = RefreshState.init(allocator);
    defer state.deinit();
    _ = try state.lockForProfile("openai-codex:default");
    _ = try state.lockForProfile("openai-codex:other");
    _ = try state.lockForProfile("openai-codex:default"); // already-existing path
}

test "RefreshState.lockForProfile is OOM-safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, refreshStateLockForProfileOomImpl, .{});
}
