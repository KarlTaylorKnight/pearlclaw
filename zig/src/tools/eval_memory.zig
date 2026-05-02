//! eval-memory — language-agnostic SQLite memory eval runner.
//!
//! Reads JSONL scenario operations from stdin, applies them to a direct
//! `SqliteMemory` instance, and writes one JSON object per data-returning op.

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const memory = zeroclaw.memory;

const EvalError = error{InvalidScenario};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.io.getStdIn().readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(input);

    var active: ?memory.SqliteMemory = null;
    defer if (active) |*mem| mem.deinit();

    const stdout = std.io.getStdOut().writer();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const op = getString(parsed.value, "op") orelse return EvalError.InvalidScenario;

        if (std.mem.eql(u8, op, "open")) {
            if (active) |*mem| {
                mem.deinit();
                active = null;
            }
            const path = getString(parsed.value, "path") orelse return EvalError.InvalidScenario;
            active = try memory.SqliteMemory.new(allocator, path);
        } else if (std.mem.eql(u8, op, "close")) {
            if (active) |*mem| mem.deinit();
            active = null;
        } else if (std.mem.eql(u8, op, "store")) {
            var mem = activePtr(&active);
            var category = try categoryFromField(allocator, parsed.value, "category");
            defer category.deinit(allocator);
            try mem.store(
                allocator,
                getString(parsed.value, "key") orelse return EvalError.InvalidScenario,
                getString(parsed.value, "content") orelse return EvalError.InvalidScenario,
                category,
                getOptionalString(parsed.value, "session_id"),
            );
        } else if (std.mem.eql(u8, op, "store_with_metadata")) {
            var mem = activePtr(&active);
            var category = try categoryFromField(allocator, parsed.value, "category");
            defer category.deinit(allocator);
            try mem.storeWithMetadata(
                allocator,
                getString(parsed.value, "key") orelse return EvalError.InvalidScenario,
                getString(parsed.value, "content") orelse return EvalError.InvalidScenario,
                category,
                getOptionalString(parsed.value, "session_id"),
                getOptionalString(parsed.value, "namespace"),
                getOptionalFloat(parsed.value, "importance"),
            );
        } else if (std.mem.eql(u8, op, "recall")) {
            var mem = activePtr(&active);
            const entries = try mem.recall(
                allocator,
                getString(parsed.value, "query") orelse return EvalError.InvalidScenario,
                getUsize(parsed.value, "limit") orelse return EvalError.InvalidScenario,
                getOptionalString(parsed.value, "session_id"),
                getOptionalString(parsed.value, "since"),
                getOptionalString(parsed.value, "until"),
            );
            defer memory.sqlite.freeEntries(allocator, entries);
            try writeEntryArrayResult(stdout, op, entries);
        } else if (std.mem.eql(u8, op, "recall_namespaced")) {
            var mem = activePtr(&active);
            const entries = try mem.recallNamespaced(
                allocator,
                getString(parsed.value, "namespace") orelse return EvalError.InvalidScenario,
                getString(parsed.value, "query") orelse return EvalError.InvalidScenario,
                getUsize(parsed.value, "limit") orelse return EvalError.InvalidScenario,
                getOptionalString(parsed.value, "session_id"),
                getOptionalString(parsed.value, "since"),
                getOptionalString(parsed.value, "until"),
            );
            defer memory.sqlite.freeEntries(allocator, entries);
            try writeEntryArrayResult(stdout, op, entries);
        } else if (std.mem.eql(u8, op, "get")) {
            var mem = activePtr(&active);
            var entry = try mem.get(
                allocator,
                getString(parsed.value, "key") orelse return EvalError.InvalidScenario,
            );
            defer if (entry) |*value| value.deinit(allocator);
            try writeResultPrefix(stdout, op);
            if (entry) |value| {
                try writeEntry(stdout, value);
            } else {
                try stdout.writeAll("null");
            }
            try stdout.writeAll("}\n");
        } else if (std.mem.eql(u8, op, "list")) {
            var mem = activePtr(&active);
            var category = try optionalCategoryFromField(allocator, parsed.value, "category");
            defer if (category) |*cat| cat.deinit(allocator);
            const entries = try mem.list(
                allocator,
                category,
                getOptionalString(parsed.value, "session_id"),
            );
            defer memory.sqlite.freeEntries(allocator, entries);
            try writeEntryArrayResult(stdout, op, entries);
        } else if (std.mem.eql(u8, op, "forget")) {
            var mem = activePtr(&active);
            const removed = try mem.forget(getString(parsed.value, "key") orelse return EvalError.InvalidScenario);
            try writeBoolResult(stdout, op, removed);
        } else if (std.mem.eql(u8, op, "purge_namespace")) {
            var mem = activePtr(&active);
            const removed = try mem.purgeNamespace(getString(parsed.value, "namespace") orelse return EvalError.InvalidScenario);
            try writeIntResult(stdout, op, removed);
        } else if (std.mem.eql(u8, op, "purge_session")) {
            var mem = activePtr(&active);
            const removed = try mem.purgeSession(getString(parsed.value, "session_id") orelse return EvalError.InvalidScenario);
            try writeIntResult(stdout, op, removed);
        } else if (std.mem.eql(u8, op, "count")) {
            var mem = activePtr(&active);
            try writeIntResult(stdout, op, try mem.count());
        } else if (std.mem.eql(u8, op, "health")) {
            var mem = activePtr(&active);
            try writeBoolResult(stdout, op, mem.healthCheck());
        } else if (std.mem.eql(u8, op, "export")) {
            var mem = activePtr(&active);
            var filter = try exportFilterFromOp(allocator, parsed.value);
            defer filter.deinit(allocator);
            const entries = try mem.exportEntries(allocator, filter);
            defer memory.sqlite.freeEntries(allocator, entries);
            try writeEntryArrayResult(stdout, op, entries);
        } else {
            return EvalError.InvalidScenario;
        }
    }
}

fn activePtr(active: *?memory.SqliteMemory) *memory.SqliteMemory {
    return if (active.*) |*mem| mem else @panic("memory scenario used backend before open");
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

fn getUsize(value: std.json.Value, key: []const u8) ?usize {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .integer => |inner| if (inner < 0) null else @intCast(inner),
        else => null,
    };
}

fn getOptionalFloat(value: std.json.Value, key: []const u8) ?f64 {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .null => null,
        .float => |inner| inner,
        .integer => |inner| @floatFromInt(inner),
        else => null,
    };
}

fn categoryFromField(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
) !memory.MemoryCategory {
    const raw = getString(value, key) orelse return EvalError.InvalidScenario;
    return memory.MemoryCategory.fromString(allocator, raw);
}

fn optionalCategoryFromField(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
) !?memory.MemoryCategory {
    const field = getField(value, key) orelse return null;
    if (field == .null) return null;
    if (field != .string) return EvalError.InvalidScenario;
    return try memory.MemoryCategory.fromString(allocator, field.string);
}

fn exportFilterFromOp(allocator: std.mem.Allocator, op: std.json.Value) !memory.ExportFilter {
    const filter_value = getField(op, "filter") orelse return .{};
    if (filter_value == .null) return .{};
    if (filter_value != .object) return EvalError.InvalidScenario;
    return .{
        .namespace = getOptionalString(filter_value, "namespace"),
        .session_id = getOptionalString(filter_value, "session_id"),
        .category = try optionalCategoryFromField(allocator, filter_value, "category"),
        .since = getOptionalString(filter_value, "since"),
        .until = getOptionalString(filter_value, "until"),
    };
}

fn writeResultPrefix(writer: anytype, op: []const u8) !void {
    try writer.writeAll("{\"op\":");
    try std.json.stringify(op, .{}, writer);
    try writer.writeAll(",\"result\":");
}

fn writeEntryArrayResult(writer: anytype, op: []const u8, entries: []const memory.MemoryEntry) !void {
    try writeResultPrefix(writer, op);
    try writer.writeByte('[');
    for (entries, 0..) |entry, i| {
        if (i != 0) try writer.writeByte(',');
        try writeEntry(writer, entry);
    }
    try writer.writeAll("]}\n");
}

fn writeBoolResult(writer: anytype, op: []const u8, result: bool) !void {
    try writeResultPrefix(writer, op);
    try writer.writeAll(if (result) "true" else "false");
    try writer.writeAll("}\n");
}

fn writeIntResult(writer: anytype, op: []const u8, result: usize) !void {
    try writeResultPrefix(writer, op);
    try writer.print("{d}", .{result});
    try writer.writeAll("}\n");
}

fn writeEntry(writer: anytype, entry: memory.MemoryEntry) !void {
    try writer.writeAll("{\"id\":");
    try std.json.stringify(entry.id, .{}, writer);
    try writer.writeAll(",\"key\":");
    try std.json.stringify(entry.key, .{}, writer);
    try writer.writeAll(",\"content\":");
    try std.json.stringify(entry.content, .{}, writer);
    try writer.writeAll(",\"category\":");
    try std.json.stringify(entry.category.asString(), .{}, writer);
    try writer.writeAll(",\"timestamp\":");
    try std.json.stringify(entry.timestamp, .{}, writer);
    try writer.writeAll(",\"session_id\":");
    if (entry.session_id) |value| {
        try std.json.stringify(value, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"score\":");
    if (entry.score) |value| {
        try writer.print("{d}", .{value});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"namespace\":");
    try std.json.stringify(entry.namespace, .{}, writer);
    try writer.writeAll(",\"importance\":");
    if (entry.importance) |value| {
        try writer.print("{d}", .{value});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"superseded_by\":");
    if (entry.superseded_by) |value| {
        try std.json.stringify(value, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}
