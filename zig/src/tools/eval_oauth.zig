//! eval-oauth — offline OAuth helper parity runner.
//!
//! Reads JSONL OAuth ops from stdin, runs deterministic Zig Phase 1
//! helpers, writes canonical-comparable JSONL to stdout.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const auth = zeroclaw.providers.auth;
const oauth = auth.openai_oauth;

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

    if (std.mem.eql(u8, op, "url_encode")) {
        const input = getString(parsed.value, "input") orelse return EvalError.InvalidScenario;
        const result = try auth.urlEncode(allocator, input);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, op, "url_decode")) {
        const input = getString(parsed.value, "input") orelse return EvalError.InvalidScenario;
        const result = try auth.urlDecode(allocator, input);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, op, "parse_query_params")) {
        const input = getString(parsed.value, "input") orelse return EvalError.InvalidScenario;
        var result = try auth.parseQueryParams(allocator, input);
        defer result.deinit(allocator);
        try writer.writeAll("{\"op\":\"parse_query_params\",\"result\":");
        try writeQueryParams(writer, result);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, op, "pkce_from_seed")) {
        const verifier_seed_hex = getString(parsed.value, "verifier_seed_hex") orelse return EvalError.InvalidScenario;
        const state_seed_hex = getString(parsed.value, "state_seed_hex") orelse return EvalError.InvalidScenario;
        const verifier_seed = try decodeHex(allocator, verifier_seed_hex);
        defer allocator.free(verifier_seed);
        const state_seed = try decodeHex(allocator, state_seed_hex);
        defer allocator.free(state_seed);

        var pkce = try auth.pkceStateFromSeed(allocator, verifier_seed, state_seed);
        defer pkce.deinit(allocator);
        try writer.writeAll("{\"op\":\"pkce_from_seed\",\"result\":");
        try writePkce(writer, pkce);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, op, "build_authorize_url")) {
        var pkce = try pkceFromValue(allocator, parsed.value);
        defer pkce.deinit(allocator);
        const result = try oauth.buildAuthorizeUrl(allocator, pkce);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, op, "build_token_body_authorization_code")) {
        const code = getString(parsed.value, "code") orelse return EvalError.InvalidScenario;
        const verifier = getString(parsed.value, "code_verifier") orelse return EvalError.InvalidScenario;
        var pkce = auth.PkceState{
            .code_verifier = try allocator.dupe(u8, verifier),
            .code_challenge = try allocator.dupe(u8, ""),
            .state = try allocator.dupe(u8, ""),
        };
        defer pkce.deinit(allocator);
        const result = try oauth.buildTokenRequestBodyAuthorizationCode(allocator, code, pkce);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, op, "build_token_body_refresh_token")) {
        const refresh_token = getString(parsed.value, "refresh_token") orelse return EvalError.InvalidScenario;
        const result = try oauth.buildTokenRequestBodyRefreshToken(allocator, refresh_token);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, op, "build_device_code_body")) {
        const result = try oauth.buildDeviceCodeRequestBody(allocator);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, op, "build_device_code_poll_body")) {
        const device_code = getString(parsed.value, "device_code") orelse return EvalError.InvalidScenario;
        const result = try oauth.buildDeviceCodePollBody(allocator, device_code);
        defer allocator.free(result);
        try writeStringResult(writer, op, result);
    } else if (std.mem.eql(u8, op, "parse_code_from_redirect")) {
        const input = getString(parsed.value, "input") orelse return EvalError.InvalidScenario;
        const expected_state = getOptionalString(parsed.value, "expected_state");
        var result = try oauth.parseCodeFromRedirectResult(allocator, input, expected_state);
        defer result.deinit(allocator);
        try writer.writeAll("{\"op\":\"parse_code_from_redirect\",\"result\":{");
        switch (result) {
            .code => |code| {
                try writer.writeAll("\"code\":");
                try std.json.stringify(code, .{}, writer);
            },
            .err => |err| {
                try writer.writeAll("\"error\":");
                try std.json.stringify(err, .{}, writer);
            },
        }
        try writer.writeAll("}}\n");
    } else if (std.mem.eql(u8, op, "parse_loopback_request_path")) {
        const input = getString(parsed.value, "input") orelse return EvalError.InvalidScenario;
        try writer.writeAll("{\"op\":\"parse_loopback_request_path\",\"result\":{");
        const path = oauth.parseLoopbackRequestPath(input) catch {
            try writer.writeAll("\"error\":\"InvalidLoopbackRequest\"}}\n");
            return;
        };
        try writer.writeAll("\"path\":");
        try std.json.stringify(path, .{}, writer);
        try writer.writeAll("}}\n");
    } else if (std.mem.eql(u8, op, "parse_token_response")) {
        const body = getString(parsed.value, "body") orelse return EvalError.InvalidScenario;
        var result = try oauth.parseTokenResponseBodyForEval(allocator, body);
        defer result.deinit(allocator);
        try writer.writeAll("{\"op\":\"parse_token_response\",\"result\":");
        try writeTokenResponseForEval(writer, result);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, op, "parse_device_code_response")) {
        const body = getString(parsed.value, "body") orelse return EvalError.InvalidScenario;
        var result = try oauth.parseDeviceCodeResponseBody(allocator, body);
        defer result.deinit(allocator);
        try writer.writeAll("{\"op\":\"parse_device_code_response\",\"result\":");
        try writeDeviceCodeStart(writer, result);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, op, "parse_oauth_error")) {
        const body = getString(parsed.value, "body") orelse return EvalError.InvalidScenario;
        var result = try oauth.parseOAuthErrorBody(allocator, body);
        defer result.deinit(allocator);
        try writer.writeAll("{\"op\":\"parse_oauth_error\",\"result\":");
        try writeOAuthError(writer, result);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, op, "classify_device_code_error")) {
        const body = getString(parsed.value, "body") orelse return EvalError.InvalidScenario;
        var result = try oauth.classifyDeviceCodeError(allocator, body);
        defer result.deinit(allocator);
        try writer.writeAll("{\"op\":\"classify_device_code_error\",\"result\":");
        try writeDeviceCodeErrorClassification(writer, result);
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, op, "extract_account_id_from_jwt")) {
        const token = getString(parsed.value, "token") orelse return EvalError.InvalidScenario;
        const result = try oauth.extractAccountIdFromJwt(allocator, token);
        defer if (result) |value| allocator.free(value);
        try writer.writeAll("{\"op\":\"extract_account_id_from_jwt\",\"result\":");
        if (result) |value| {
            try std.json.stringify(value, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}\n");
    } else if (std.mem.eql(u8, op, "extract_expiry_from_jwt")) {
        const token = getString(parsed.value, "token") orelse return EvalError.InvalidScenario;
        const result = try oauth.extractExpiryFromJwt(allocator, token);
        try writer.writeAll("{\"op\":\"extract_expiry_from_jwt\",\"result\":");
        if (result) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}\n");
    } else {
        return EvalError.InvalidScenario;
    }
}

fn pkceFromValue(allocator: std.mem.Allocator, value: std.json.Value) !auth.PkceState {
    const verifier = getString(value, "code_verifier") orelse return EvalError.InvalidScenario;
    const challenge = getString(value, "code_challenge") orelse return EvalError.InvalidScenario;
    const state = getString(value, "state") orelse return EvalError.InvalidScenario;
    const code_verifier = try allocator.dupe(u8, verifier);
    errdefer allocator.free(code_verifier);
    const code_challenge = try allocator.dupe(u8, challenge);
    errdefer allocator.free(code_challenge);
    const state_owned = try allocator.dupe(u8, state);
    errdefer allocator.free(state_owned);
    return .{
        .code_verifier = code_verifier,
        .code_challenge = code_challenge,
        .state = state_owned,
    };
}

fn decodeHex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, input);
    return out;
}

fn writeStringResult(writer: anytype, op: []const u8, result: []const u8) !void {
    try writer.writeAll("{\"op\":");
    try std.json.stringify(op, .{}, writer);
    try writer.writeAll(",\"result\":");
    try std.json.stringify(result, .{}, writer);
    try writer.writeAll("}\n");
}

fn writePkce(writer: anytype, pkce: auth.PkceState) !void {
    try writer.writeAll("{\"code_challenge\":");
    try std.json.stringify(pkce.code_challenge, .{}, writer);
    try writer.writeAll(",\"code_verifier\":");
    try std.json.stringify(pkce.code_verifier, .{}, writer);
    try writer.writeAll(",\"state\":");
    try std.json.stringify(pkce.state, .{}, writer);
    try writer.writeByte('}');
}

fn writeQueryParams(writer: anytype, params: auth.QueryParams) !void {
    try writer.writeByte('{');
    for (params.entries, 0..) |entry, i| {
        if (i != 0) try writer.writeByte(',');
        try std.json.stringify(entry.key, .{}, writer);
        try writer.writeByte(':');
        try std.json.stringify(entry.value, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeTokenResponseForEval(writer: anytype, token: auth.TokenResponseForEval) !void {
    try writer.writeByte('{');
    var wrote = false;
    try writeRequiredStringField(writer, &wrote, "access_token", token.access_token);
    try writeOptionalStringField(writer, &wrote, "refresh_token", token.refresh_token);
    try writeOptionalStringField(writer, &wrote, "id_token", token.id_token);
    if (token.expires_in_seconds) |value| {
        try writeComma(writer, &wrote);
        try writer.writeAll("\"expires_in_seconds\":");
        try writer.print("{d}", .{value});
    }
    try writeOptionalStringField(writer, &wrote, "token_type", token.token_type);
    try writeOptionalStringField(writer, &wrote, "scope", token.scope);
    try writer.writeByte('}');
}

fn writeDeviceCodeStart(writer: anytype, device: auth.DeviceCodeStart) !void {
    try writer.writeByte('{');
    var wrote = false;
    try writeRequiredStringField(writer, &wrote, "device_code", device.device_code);
    try writeRequiredStringField(writer, &wrote, "user_code", device.user_code);
    try writeRequiredStringField(writer, &wrote, "verification_uri", device.verification_uri);
    try writeOptionalStringField(writer, &wrote, "verification_uri_complete", device.verification_uri_complete);
    try writeComma(writer, &wrote);
    try writer.print("\"expires_in\":{d}", .{device.expires_in});
    try writeComma(writer, &wrote);
    try writer.print("\"interval\":{d}", .{device.interval});
    try writeOptionalStringField(writer, &wrote, "message", device.message);
    try writer.writeByte('}');
}

fn writeOAuthError(writer: anytype, oauth_error: auth.OAuthErrorResponse) !void {
    try writer.writeByte('{');
    var wrote = false;
    try writeRequiredStringField(writer, &wrote, "error", oauth_error.err);
    try writeOptionalStringField(writer, &wrote, "error_description", oauth_error.error_description);
    try writer.writeByte('}');
}

fn writeDeviceCodeErrorClassification(writer: anytype, classification: oauth.DeviceCodeErrorClassification) !void {
    try writer.writeAll("{\"description\":");
    if (classification.description) |description| {
        try std.json.stringify(description, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"kind\":");
    try std.json.stringify(deviceCodeErrorKindString(classification.kind), .{}, writer);
    try writer.writeByte('}');
}

fn deviceCodeErrorKindString(kind: oauth.DeviceCodeErrorKind) []const u8 {
    return switch (kind) {
        .Pending => "Pending",
        .SlowDown => "SlowDown",
        .Denied => "Denied",
        .Expired => "Expired",
        .Other => "Other",
        .Unparseable => "Unparseable",
    };
}

fn writeRequiredStringField(writer: anytype, wrote: *bool, key: []const u8, value: []const u8) !void {
    try writeComma(writer, wrote);
    try std.json.stringify(key, .{}, writer);
    try writer.writeByte(':');
    try std.json.stringify(value, .{}, writer);
}

fn writeOptionalStringField(writer: anytype, wrote: *bool, key: []const u8, value: ?[]const u8) !void {
    if (value) |inner| try writeRequiredStringField(writer, wrote, key, inner);
}

fn writeComma(writer: anytype, wrote: *bool) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
}

fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn getOptionalString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .null => null,
        .string => |inner| inner,
        else => null,
    };
}
