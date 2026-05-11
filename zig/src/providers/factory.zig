//! Provider factory family ported from `zeroclaw-providers/src/lib.rs`.
//!
//! Trimmed Phase 6-B scope: only `openai` and `ollama` are constructible.
//! All other provider names return `FactoryError.ProviderNotSupported`.
//!
//! Ownership: `createProvider*` returns a `ProviderHandle` that owns a
//! heap-allocated concrete provider. Call `ProviderHandle.deinit` with the
//! same allocator when done. `ProviderHandle.provider()` returns the existing
//! provider vtable handle; that vtable pointer is only valid while the
//! `ProviderHandle` remains alive and before `deinit`.

const std = @import("std");
const parser_types = @import("../tool_call_parser/types.zig");
const provider_handle = @import("provider.zig");
const ollama_client = @import("ollama/client.zig");
const openai_client = @import("openai/client.zig");

pub const FactoryError = error{
    ProviderNotSupported,
    ApiKeyPrefixMismatch,
    OutOfMemory,
};

pub const ProviderRuntimeOptions = struct {
    const Self = @This();

    auth_profile_override: ?[]u8 = null,
    provider_api_url: ?[]u8 = null,
    zeroclaw_dir: ?[]u8 = null,
    secrets_encrypt: bool = true,
    reasoning_enabled: ?bool = null,
    reasoning_effort: ?[]u8 = null,
    provider_timeout_secs: ?u64 = null,
    extra_headers: std.StringHashMap([]u8),
    api_path: ?[]u8 = null,
    provider_max_tokens: ?u32 = null,
    merge_system_into_user: bool = false,
    provider_extra: ?std.json.Value = null,

    /// Matches Rust `Default::default()`. All owned fields start empty; when
    /// callers populate slices, map keys/values, or `provider_extra`, the
    /// bytes/JSON tree must be owned by the allocator later passed to
    /// `deinit`.
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .extra_headers = std.StringHashMap([]u8).init(allocator) };
    }

    /// Frees all owned slices, the `extra_headers` map (keys, values, and
    /// the map's internal buffers), and any `provider_extra` JSON tree.
    /// The `allocator` argument MUST match the allocator passed to `init` —
    /// `extra_headers` internally retains the init-time allocator for its
    /// bucket storage. Mixing allocators here is undefined behavior. The
    /// simplest safe pattern is to use one allocator end-to-end.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.auth_profile_override) |value| allocator.free(value);
        if (self.provider_api_url) |value| allocator.free(value);
        if (self.zeroclaw_dir) |value| allocator.free(value);
        if (self.reasoning_effort) |value| allocator.free(value);
        if (self.api_path) |value| allocator.free(value);
        deinitStringMap(allocator, &self.extra_headers);
        if (self.provider_extra) |*value| parser_types.freeJsonValue(allocator, value);
        self.* = undefined;
    }

    pub fn clone(self: *const Self, allocator: std.mem.Allocator) FactoryError!Self {
        var out = Self.init(allocator);
        errdefer out.deinit(allocator);

        out.auth_profile_override = try cloneOptional(allocator, self.auth_profile_override);
        out.provider_api_url = try cloneOptional(allocator, self.provider_api_url);
        out.zeroclaw_dir = try cloneOptional(allocator, self.zeroclaw_dir);
        out.secrets_encrypt = self.secrets_encrypt;
        out.reasoning_enabled = self.reasoning_enabled;
        out.reasoning_effort = try cloneOptional(allocator, self.reasoning_effort);
        out.provider_timeout_secs = self.provider_timeout_secs;
        try cloneStringMapInto(allocator, &out.extra_headers, self.extra_headers);
        out.api_path = try cloneOptional(allocator, self.api_path);
        out.provider_max_tokens = self.provider_max_tokens;
        out.merge_system_into_user = self.merge_system_into_user;
        out.provider_extra = if (self.provider_extra) |value|
            try parser_types.cloneJsonValue(allocator, value)
        else
            null;

        return out;
    }
};

pub const ProviderHandle = struct {
    const Self = @This();

    inner: union(enum) {
        ollama: *ollama_client.OllamaProvider,
        openai: *openai_client.OpenAiProvider,
    },

    pub fn provider(self: *Self) provider_handle.Provider {
        return switch (self.inner) {
            .ollama => |ptr| ptr.provider(),
            .openai => |ptr| ptr.provider(),
        };
    }

    pub fn providerName(self: *const Self) []const u8 {
        return switch (self.inner) {
            .ollama => "ollama",
            .openai => "openai",
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        switch (self.inner) {
            .ollama => |ptr| {
                ptr.deinit(allocator);
                allocator.destroy(ptr);
            },
            .openai => |ptr| {
                ptr.deinit(allocator);
                allocator.destroy(ptr);
            },
        }
        self.* = undefined;
    }
};

pub fn createProvider(
    allocator: std.mem.Allocator,
    name: []const u8,
    api_key: ?[]const u8,
) FactoryError!ProviderHandle {
    var options = ProviderRuntimeOptions.init(allocator);
    defer options.deinit(allocator);
    return createProviderWithOptions(allocator, name, api_key, &options);
}

pub fn createProviderWithOptions(
    allocator: std.mem.Allocator,
    name: []const u8,
    api_key: ?[]const u8,
    options: *const ProviderRuntimeOptions,
) FactoryError!ProviderHandle {
    return createProviderWithUrlAndOptions(allocator, name, api_key, null, options);
}

pub fn createProviderWithUrl(
    allocator: std.mem.Allocator,
    name: []const u8,
    api_key: ?[]const u8,
    api_url: ?[]const u8,
) FactoryError!ProviderHandle {
    var options = ProviderRuntimeOptions.init(allocator);
    defer options.deinit(allocator);
    return createProviderWithUrlAndOptions(allocator, name, api_key, api_url, &options);
}

fn createProviderWithUrlAndOptions(
    allocator: std.mem.Allocator,
    name: []const u8,
    api_key: ?[]const u8,
    api_url: ?[]const u8,
    options: *const ProviderRuntimeOptions,
) FactoryError!ProviderHandle {
    const resolved_credential = try resolveProviderCredential(allocator, name, api_key);
    defer if (resolved_credential) |credential| allocator.free(credential);

    if (resolved_credential) |key| {
        const is_custom =
            std.mem.startsWith(u8, name, "custom:") or
            std.mem.startsWith(u8, name, "anthropic-custom:");
        const has_custom_url = if (api_url) |url|
            std.mem.trim(u8, url, " \t\r\n").len != 0
        else
            false;
        if (!is_custom and !has_custom_url and checkApiKeyPrefix(name, key) != null) {
            return FactoryError.ApiKeyPrefixMismatch;
        }
    }

    if (std.mem.eql(u8, name, "openai")) {
        const instance = try allocator.create(openai_client.OpenAiProvider);
        errdefer allocator.destroy(instance);
        instance.* = try openai_client.OpenAiProvider.withBaseUrl(allocator, api_url, resolved_credential);
        errdefer instance.deinit(allocator);
        instance.* = instance.withMaxTokens(options.provider_max_tokens);
        return .{ .inner = .{ .openai = instance } };
    }

    if (std.mem.eql(u8, name, "ollama")) {
        const env_url = getEnvVarOwnedOrNull(allocator, "ZEROCLAW_PROVIDER_URL") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer if (env_url) |value| allocator.free(value);
        const selected_url = if (env_url) |value| value else api_url;

        const instance = try allocator.create(ollama_client.OllamaProvider);
        errdefer allocator.destroy(instance);
        instance.* = try ollama_client.OllamaProvider.newWithReasoning(
            allocator,
            selected_url,
            resolved_credential,
            options.reasoning_enabled,
        );
        errdefer instance.deinit(allocator);
        return .{ .inner = .{ .ollama = instance } };
    }

    return FactoryError.ProviderNotSupported;
}

/// Trimmed Phase 6-B scope: all 8 Rust detection prefixes are preserved
/// (anthropic, openrouter, openai, groq, perplexity, xai, nvidia, telnyx)
/// so that the mismatch warning surfaces a helpful "you gave provider X a
/// key that looks like provider Y" even when X is in scope but Y is not.
/// The dispatch guard below only fires for "openai" because that's the
/// only key-bearing provider currently constructible (Ollama is keyless,
/// so no key prefix to check). Adding a future factory arm requires
/// extending the dispatch guard, not the detection chain.
fn checkApiKeyPrefix(provider_name: []const u8, key: []const u8) ?[]const u8 {
    const likely_provider: []const u8 = if (std.mem.startsWith(u8, key, "sk-ant-"))
        "anthropic"
    else if (std.mem.startsWith(u8, key, "sk-or-"))
        "openrouter"
    else if (std.mem.startsWith(u8, key, "sk-"))
        "openai"
    else if (std.mem.startsWith(u8, key, "gsk_"))
        "groq"
    else if (std.mem.startsWith(u8, key, "pplx-"))
        "perplexity"
    else if (std.mem.startsWith(u8, key, "xai-"))
        "xai"
    else if (std.mem.startsWith(u8, key, "nvapi-"))
        "nvidia"
    else if (std.mem.startsWith(u8, key, "KEY-"))
        "telnyx"
    else
        return null;

    if (std.mem.eql(u8, provider_name, "openai")) {
        return if (std.mem.eql(u8, likely_provider, "openai")) null else likely_provider;
    }

    return null;
}

fn resolveProviderCredential(
    allocator: std.mem.Allocator,
    name: []const u8,
    credential_override: ?[]const u8,
) FactoryError!?[]u8 {
    if (credential_override) |raw_override| {
        const trimmed_override = std.mem.trim(u8, raw_override, " \t\r\n");
        if (trimmed_override.len != 0) return try allocator.dupe(u8, trimmed_override);
    }

    if (std.mem.eql(u8, name, "openai")) {
        if (try getTrimmedEnvVarOwned(allocator, "OPENAI_API_KEY")) |value| return value;
    }

    inline for (.{ "ZEROCLAW_API_KEY", "API_KEY" }) |env_var| {
        if (try getTrimmedEnvVarOwned(allocator, env_var)) |value| return value;
    }

    return null;
}

fn getTrimmedEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) FactoryError!?[]u8 {
    const raw = try getEnvVarOwnedOrNull(allocator, key);
    if (raw) |value| {
        errdefer allocator.free(value);
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) {
            allocator.free(value);
            return null;
        }
        if (trimmed.ptr == value.ptr and trimmed.len == value.len) return value;
        const cloned = try allocator.dupe(u8, trimmed);
        allocator.free(value);
        return cloned;
    }
    return null;
}

fn getEnvVarOwnedOrNull(allocator: std.mem.Allocator, key: []const u8) error{OutOfMemory}!?[]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn cloneOptional(allocator: std.mem.Allocator, value: ?[]const u8) FactoryError!?[]u8 {
    if (value) |inner| return try allocator.dupe(u8, inner);
    return null;
}

fn cloneStringMapInto(
    allocator: std.mem.Allocator,
    out: *std.StringHashMap([]u8),
    map: std.StringHashMap([]u8),
) FactoryError!void {
    var it = map.iterator();
    while (it.next()) |entry| {
        try putStringValue(allocator, out, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn putStringValue(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap([]u8),
    key: []const u8,
    value: []const u8,
) FactoryError!void {
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

fn deinitStringMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

test "ProviderRuntimeOptions defaults match Rust default" {
    var options = ProviderRuntimeOptions.init(std.testing.allocator);
    defer options.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?[]u8, null), options.auth_profile_override);
    try std.testing.expectEqual(@as(?[]u8, null), options.provider_api_url);
    try std.testing.expectEqual(@as(?[]u8, null), options.zeroclaw_dir);
    try std.testing.expect(options.secrets_encrypt);
    try std.testing.expectEqual(@as(?bool, null), options.reasoning_enabled);
    try std.testing.expectEqual(@as(?[]u8, null), options.reasoning_effort);
    try std.testing.expectEqual(@as(?u64, null), options.provider_timeout_secs);
    try std.testing.expectEqual(@as(usize, 0), options.extra_headers.count());
    try std.testing.expectEqual(@as(?[]u8, null), options.api_path);
    try std.testing.expectEqual(@as(?u32, null), options.provider_max_tokens);
    try std.testing.expect(!options.merge_system_into_user);
    try std.testing.expectEqual(@as(?std.json.Value, null), options.provider_extra);
}

test "ProviderRuntimeOptions clone deep-copies owned fields" {
    const allocator = std.testing.allocator;
    var options = ProviderRuntimeOptions.init(allocator);
    defer options.deinit(allocator);

    options.auth_profile_override = try allocator.dupe(u8, "work");
    options.provider_api_url = try allocator.dupe(u8, "https://api.example.test");
    options.zeroclaw_dir = try allocator.dupe(u8, "/tmp/zeroclaw");
    options.reasoning_enabled = true;
    options.reasoning_effort = try allocator.dupe(u8, "high");
    options.provider_timeout_secs = 42;
    try putStringValue(allocator, &options.extra_headers, "X-Test", "yes");
    options.api_path = try allocator.dupe(u8, "/chat/completions");
    options.provider_max_tokens = 123;
    options.merge_system_into_user = true;
    options.provider_extra = try parser_types.singletonStringObject(allocator, "mode", "strict");

    var cloned = try options.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqualStrings("work", cloned.auth_profile_override.?);
    try std.testing.expect(options.auth_profile_override.?.ptr != cloned.auth_profile_override.?.ptr);
    try std.testing.expectEqualStrings("https://api.example.test", cloned.provider_api_url.?);
    try std.testing.expectEqualStrings("/tmp/zeroclaw", cloned.zeroclaw_dir.?);
    try std.testing.expectEqual(@as(?bool, true), cloned.reasoning_enabled);
    try std.testing.expectEqualStrings("high", cloned.reasoning_effort.?);
    try std.testing.expectEqual(@as(?u64, 42), cloned.provider_timeout_secs);
    try std.testing.expectEqualStrings("yes", cloned.extra_headers.get("X-Test").?);
    try std.testing.expectEqualStrings("/chat/completions", cloned.api_path.?);
    try std.testing.expectEqual(@as(?u32, 123), cloned.provider_max_tokens);
    try std.testing.expect(cloned.merge_system_into_user);
    try std.testing.expectEqualStrings("strict", cloned.provider_extra.?.object.get("mode").?.string);
}

test "factory creates ollama and openai provider handles" {
    const allocator = std.testing.allocator;

    var ollama = try createProvider(allocator, "ollama", null);
    defer ollama.deinit(allocator);
    try std.testing.expectEqualStrings("ollama", ollama.providerName());
    _ = ollama.provider();

    var openai = try createProvider(allocator, "openai", "sk-test");
    defer openai.deinit(allocator);
    try std.testing.expectEqualStrings("openai", openai.providerName());
    try std.testing.expectEqualStrings(openai_client.BASE_URL, openai.inner.openai.base_url);
    try std.testing.expectEqualStrings("sk-test", openai.inner.openai.credential.?);
}

test "factory applies openai url override and max tokens" {
    const allocator = std.testing.allocator;
    var options = ProviderRuntimeOptions.init(allocator);
    defer options.deinit(allocator);
    options.provider_max_tokens = 321;

    var handle = try createProviderWithUrlAndOptions(
        allocator,
        "openai",
        " sk-test \n",
        "https://gateway.example/v1/",
        &options,
    );
    defer handle.deinit(allocator);

    try std.testing.expectEqualStrings("https://gateway.example/v1", handle.inner.openai.base_url);
    try std.testing.expectEqualStrings("sk-test", handle.inner.openai.credential.?);
    try std.testing.expectEqual(@as(?u32, 321), handle.inner.openai.max_tokens);
}

test "factory rejects dropped providers and openai key prefix mismatches" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        FactoryError.ProviderNotSupported,
        createProvider(allocator, "anthropic", "sk-ant-test"),
    );
    try std.testing.expectError(
        FactoryError.ProviderNotSupported,
        createProvider(allocator, "gemini", null),
    );
    try std.testing.expectError(
        FactoryError.ApiKeyPrefixMismatch,
        createProvider(allocator, "openai", "sk-ant-test"),
    );
    try std.testing.expectError(
        FactoryError.ApiKeyPrefixMismatch,
        createProvider(allocator, "openai", "sk-or-test"),
    );

    var handle = try createProvider(allocator, "openai", "bogus-format-key");
    defer handle.deinit(allocator);
    try std.testing.expectEqualStrings("openai", handle.providerName());
}

test "ollama ZEROCLAW_PROVIDER_URL env var wins over api_url parameter" {
    const allocator = std.testing.allocator;
    const key = "ZEROCLAW_PROVIDER_URL";

    const previous = try getEnvVarOwnedOrNull(allocator, key);
    defer if (previous) |value| allocator.free(value);
    defer restoreEnv(key, previous);

    try setEnv(key, "http://env-host:11434/api");

    var handle = try createProviderWithUrl(allocator, "ollama", null, "http://param-host:11434");
    defer handle.deinit(allocator);

    try std.testing.expectEqualStrings("http://env-host:11434", handle.inner.ollama.base_url);
}

fn factoryOomImpl(allocator: std.mem.Allocator) !void {
    var options = ProviderRuntimeOptions.init(allocator);
    defer options.deinit(allocator);
    options.provider_api_url = try allocator.dupe(u8, "https://ignored.example/v1");
    options.zeroclaw_dir = try allocator.dupe(u8, "/tmp/zeroclaw");
    options.reasoning_effort = try allocator.dupe(u8, "medium");
    options.provider_timeout_secs = 77;
    options.provider_max_tokens = 222;
    options.api_path = try allocator.dupe(u8, "/responses");
    try putStringValue(allocator, &options.extra_headers, "X-Trace", "abc");
    try putStringValue(allocator, &options.extra_headers, "X-Mode", "eval");
    options.provider_extra = try parser_types.singletonStringObject(allocator, "flag", "on");

    var cloned = try options.clone(allocator);
    defer cloned.deinit(allocator);

    var handle = try createProviderWithUrlAndOptions(
        allocator,
        "openai",
        "sk-test",
        "https://gateway.example/v1",
        &cloned,
    );
    defer handle.deinit(allocator);
}

test "ProviderRuntimeOptions clone and openai factory dispatch are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, factoryOomImpl, .{});
}

fn factoryOomImplOllama(allocator: std.mem.Allocator) !void {
    var options = ProviderRuntimeOptions.init(allocator);
    defer options.deinit(allocator);
    options.reasoning_enabled = true;
    options.zeroclaw_dir = try allocator.dupe(u8, "/tmp/zeroclaw");
    options.provider_timeout_secs = 60;
    try putStringValue(allocator, &options.extra_headers, "X-Source", "ollama-test");

    var cloned = try options.clone(allocator);
    defer cloned.deinit(allocator);

    var handle = try createProviderWithUrlAndOptions(
        allocator,
        "ollama",
        null,
        "https://remote.example/api",
        &cloned,
    );
    defer handle.deinit(allocator);
}

test "ollama factory dispatch is OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, factoryOomImplOllama, .{});
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setEnv(key: []const u8, value: []const u8) !void {
    var key_buf: [64:0]u8 = undefined;
    var value_buf: [256:0]u8 = undefined;
    if (key.len >= key_buf.len or value.len >= value_buf.len) return error.NameTooLong;
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    @memcpy(value_buf[0..value.len], value);
    value_buf[value.len] = 0;
    if (setenv(&key_buf, &value_buf, 1) != 0) return error.SetEnvFailed;
}

fn unsetEnv(key: []const u8) void {
    var key_buf: [64:0]u8 = undefined;
    if (key.len >= key_buf.len) return;
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    _ = unsetenv(&key_buf);
}

fn restoreEnv(key: []const u8, previous: ?[]const u8) void {
    if (previous) |value| {
        setEnv(key, value) catch unsetEnv(key);
    } else {
        unsetEnv(key);
    }
}
