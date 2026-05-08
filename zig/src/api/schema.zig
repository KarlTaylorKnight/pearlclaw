//! JSON Schema cleaning and validation for LLM tool-calling compatibility.
//!
//! Public cleaning functions return a new `std.json.Value` tree owned by the
//! allocator passed to the function. Callers must release returned values with
//! `freeJsonValue(allocator, &value)`.

const std = @import("std");

pub const GEMINI_UNSUPPORTED_KEYWORDS = [_][]const u8{
    "$ref",
    "$schema",
    "$id",
    "$defs",
    "definitions",
    "additionalProperties",
    "patternProperties",
    "minLength",
    "maxLength",
    "pattern",
    "format",
    "minimum",
    "maximum",
    "multipleOf",
    "minItems",
    "maxItems",
    "uniqueItems",
    "minProperties",
    "maxProperties",
    "examples",
};

pub const SCHEMA_META_KEYS = [_][]const u8{ "description", "title", "default" };

const ANTHROPIC_UNSUPPORTED_KEYWORDS = [_][]const u8{ "$ref", "$defs", "definitions" };
const OPENAI_UNSUPPORTED_KEYWORDS = [_][]const u8{};
const CONSERVATIVE_UNSUPPORTED_KEYWORDS = [_][]const u8{ "$ref", "$defs", "definitions", "additionalProperties" };

pub const CleaningStrategy = enum {
    Gemini,
    Anthropic,
    OpenAI,
    Conservative,

    pub fn unsupportedKeywords(self: CleaningStrategy) []const []const u8 {
        return switch (self) {
            .Gemini => &GEMINI_UNSUPPORTED_KEYWORDS,
            .Anthropic => &ANTHROPIC_UNSUPPORTED_KEYWORDS,
            .OpenAI => &OPENAI_UNSUPPORTED_KEYWORDS,
            .Conservative => &CONSERVATIVE_UNSUPPORTED_KEYWORDS,
        };
    }
};

pub fn cleanForGemini(allocator: std.mem.Allocator, schema: std.json.Value) anyerror!std.json.Value {
    return clean(allocator, schema, .Gemini);
}

pub fn cleanForAnthropic(allocator: std.mem.Allocator, schema: std.json.Value) anyerror!std.json.Value {
    return clean(allocator, schema, .Anthropic);
}

pub fn cleanForOpenai(allocator: std.mem.Allocator, schema: std.json.Value) anyerror!std.json.Value {
    return clean(allocator, schema, .OpenAI);
}

pub fn clean(allocator: std.mem.Allocator, schema: std.json.Value, strategy: CleaningStrategy) anyerror!std.json.Value {
    var defs = std.StringHashMap(std.json.Value).init(allocator);
    defer deinitDefs(allocator, &defs);

    if (schema == .object) {
        try extractDefs(allocator, schema.object, &defs);
    }

    var ref_stack = std.StringHashMap(void).init(allocator);
    defer deinitRefStack(allocator, &ref_stack);

    return cleanWithDefs(allocator, schema, &defs, strategy, &ref_stack);
}

pub fn validate(schema: std.json.Value) !void {
    if (schema != .object) return error.InvalidSchema;
    if (!schema.object.contains("type")) return error.SchemaMissingType;
}

fn extractDefs(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    defs: *std.StringHashMap(std.json.Value),
) anyerror!void {
    if (obj.get("$defs")) |defs_value| {
        if (defs_value == .object) {
            try extractDefObject(allocator, defs_value.object, defs);
        }
    }

    if (obj.get("definitions")) |defs_value| {
        if (defs_value == .object) {
            try extractDefObject(allocator, defs_value.object, defs);
        }
    }
}

fn extractDefObject(
    allocator: std.mem.Allocator,
    defs_obj: std.json.ObjectMap,
    defs: *std.StringHashMap(std.json.Value),
) anyerror!void {
    var iterator = defs_obj.iterator();
    while (iterator.next()) |entry| {
        try putDefinition(allocator, defs, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn cleanWithDefs(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    defs: *const std.StringHashMap(std.json.Value),
    strategy: CleaningStrategy,
    ref_stack: *std.StringHashMap(void),
) anyerror!std.json.Value {
    return switch (value) {
        .object => |object| cleanObject(allocator, object, defs, strategy, ref_stack),
        .array => |array| cleanArray(allocator, array, defs, strategy, ref_stack),
        else => cloneJsonValue(allocator, value),
    };
}

fn cleanArray(
    allocator: std.mem.Allocator,
    array: std.json.Array,
    defs: *const std.StringHashMap(std.json.Value),
    strategy: CleaningStrategy,
    ref_stack: *std.StringHashMap(void),
) anyerror!std.json.Value {
    var cleaned = std.json.Array.init(allocator);
    errdefer {
        var tmp = std.json.Value{ .array = cleaned };
        freeJsonValue(allocator, &tmp);
    }

    for (array.items) |item| {
        try appendOwned(allocator, &cleaned, try cleanWithDefs(allocator, item, defs, strategy, ref_stack));
    }

    return .{ .array = cleaned };
}

fn cleanObject(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    defs: *const std.StringHashMap(std.json.Value),
    strategy: CleaningStrategy,
    ref_stack: *std.StringHashMap(void),
) anyerror!std.json.Value {
    if (obj.get("$ref")) |ref_value| {
        if (ref_value == .string) {
            return resolveRef(allocator, ref_value.string, obj, defs, strategy, ref_stack);
        }
    }

    if (obj.contains("anyOf") or obj.contains("oneOf")) {
        if (try trySimplifyUnion(allocator, obj, defs, strategy, ref_stack)) |simplified| {
            return simplified;
        }
    }

    var cleaned = std.json.ObjectMap.init(allocator);
    errdefer {
        var tmp = std.json.Value{ .object = cleaned };
        freeJsonValue(allocator, &tmp);
    }

    const unsupported = strategy.unsupportedKeywords();
    const has_union = obj.contains("anyOf") or obj.contains("oneOf");

    var iterator = obj.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        if (containsKeyword(unsupported, key)) continue;

        if (std.mem.eql(u8, key, "const")) {
            var enum_values = std.json.Array.init(allocator);
            var enum_values_moved = false;
            errdefer if (!enum_values_moved) {
                var tmp = std.json.Value{ .array = enum_values };
                freeJsonValue(allocator, &tmp);
            };
            try appendOwned(allocator, &enum_values, try cloneJsonValue(allocator, value));
            enum_values_moved = true;
            try putOwned(allocator, &cleaned, "enum", .{ .array = enum_values });
        } else if (std.mem.eql(u8, key, "type") and has_union) {
            continue;
        } else if (std.mem.eql(u8, key, "type") and value == .array) {
            try putOwned(allocator, &cleaned, key, try cleanTypeArray(allocator, value));
        } else if (std.mem.eql(u8, key, "properties")) {
            try putOwned(allocator, &cleaned, key, try cleanProperties(allocator, value, defs, strategy, ref_stack));
        } else if (std.mem.eql(u8, key, "items")) {
            try putOwned(allocator, &cleaned, key, try cleanWithDefs(allocator, value, defs, strategy, ref_stack));
        } else if (std.mem.eql(u8, key, "anyOf") or std.mem.eql(u8, key, "oneOf") or std.mem.eql(u8, key, "allOf")) {
            try putOwned(allocator, &cleaned, key, try cleanUnion(allocator, value, defs, strategy, ref_stack));
        } else if (value == .object or value == .array) {
            try putOwned(allocator, &cleaned, key, try cleanWithDefs(allocator, value, defs, strategy, ref_stack));
        } else {
            try putOwned(allocator, &cleaned, key, try cloneJsonValue(allocator, value));
        }
    }

    return .{ .object = cleaned };
}

fn resolveRef(
    allocator: std.mem.Allocator,
    ref_value: []const u8,
    obj: std.json.ObjectMap,
    defs: *const std.StringHashMap(std.json.Value),
    strategy: CleaningStrategy,
    ref_stack: *std.StringHashMap(void),
) anyerror!std.json.Value {
    if (ref_stack.contains(ref_value)) {
        return preserveMeta(allocator, obj, emptyObject(allocator));
    }

    if (try parseLocalRef(allocator, ref_value)) |def_name| {
        defer allocator.free(def_name);
        if (defs.get(def_name)) |definition| {
            try pushRefStack(allocator, ref_stack, ref_value);
            defer popRefStack(allocator, ref_stack, ref_value);

            const cleaned = try cleanWithDefs(allocator, definition, defs, strategy, ref_stack);
            return preserveMeta(allocator, obj, cleaned);
        }
    }

    return preserveMeta(allocator, obj, emptyObject(allocator));
}

pub fn parseLocalRef(allocator: std.mem.Allocator, ref_value: []const u8) anyerror!?[]u8 {
    if (std.mem.startsWith(u8, ref_value, "#/$defs/")) {
        return try decodeJsonPointer(allocator, ref_value["#/$defs/".len..]);
    }
    if (std.mem.startsWith(u8, ref_value, "#/definitions/")) {
        return try decodeJsonPointer(allocator, ref_value["#/definitions/".len..]);
    }
    return null;
}

pub fn decodeJsonPointer(allocator: std.mem.Allocator, segment: []const u8) anyerror![]u8 {
    if (std.mem.indexOfScalar(u8, segment, '~') == null) {
        return allocator.dupe(u8, segment);
    }

    var decoded = std.ArrayList(u8).init(allocator);
    errdefer decoded.deinit();

    var index: usize = 0;
    while (index < segment.len) {
        const byte = segment[index];
        if (byte == '~' and index + 1 < segment.len) {
            const next = segment[index + 1];
            if (next == '0') {
                try decoded.append('~');
                index += 2;
                continue;
            }
            if (next == '1') {
                try decoded.append('/');
                index += 2;
                continue;
            }
        }
        try decoded.append(byte);
        index += 1;
    }

    return decoded.toOwnedSlice();
}

fn trySimplifyUnion(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    defs: *const std.StringHashMap(std.json.Value),
    strategy: CleaningStrategy,
    ref_stack: *std.StringHashMap(void),
) anyerror!?std.json.Value {
    const union_value = if (obj.get("anyOf")) |value|
        value
    else if (obj.get("oneOf")) |value|
        value
    else
        return null;

    if (union_value != .array) return null;

    var non_null = std.json.Array.init(allocator);
    defer {
        var tmp = std.json.Value{ .array = non_null };
        freeJsonValue(allocator, &tmp);
    }

    for (union_value.array.items) |variant| {
        var cleaned = try cleanWithDefs(allocator, variant, defs, strategy, ref_stack);
        if (isNullSchema(cleaned)) {
            freeJsonValue(allocator, &cleaned);
            continue;
        }
        try appendOwned(allocator, &non_null, cleaned);
    }

    if (non_null.items.len == 1) {
        const simplified = try cloneJsonValue(allocator, non_null.items[0]);
        return try preserveMeta(allocator, obj, simplified);
    }

    if (try tryFlattenLiteralUnion(allocator, non_null.items)) |flattened| {
        return try preserveMeta(allocator, obj, flattened);
    }

    return null;
}

fn isNullSchema(value: std.json.Value) bool {
    if (value != .object) return false;

    if (value.object.get("const")) |const_value| {
        if (const_value == .null) return true;
    }

    if (value.object.get("enum")) |enum_value| {
        if (enum_value == .array and enum_value.array.items.len == 1 and enum_value.array.items[0] == .null) {
            return true;
        }
    }

    if (value.object.get("type")) |type_value| {
        if (type_value == .string and std.mem.eql(u8, type_value.string, "null")) {
            return true;
        }
    }

    return false;
}

fn tryFlattenLiteralUnion(
    allocator: std.mem.Allocator,
    variants: []const std.json.Value,
) anyerror!?std.json.Value {
    if (variants.len == 0) return null;

    var enum_values = std.json.Array.init(allocator);
    var enum_values_moved = false;
    defer if (!enum_values_moved) {
        var tmp = std.json.Value{ .array = enum_values };
        freeJsonValue(allocator, &tmp);
    };

    var common_type: ?[]const u8 = null;

    for (variants) |variant| {
        if (variant != .object) return null;

        const literal_value = if (variant.object.get("const")) |const_value|
            const_value
        else if (variant.object.get("enum")) |enum_value| blk: {
            if (enum_value != .array or enum_value.array.items.len != 1) return null;
            break :blk enum_value.array.items[0];
        } else {
            return null;
        };

        const type_value = variant.object.get("type") orelse return null;
        if (type_value != .string) return null;

        if (common_type) |known| {
            if (!std.mem.eql(u8, known, type_value.string)) return null;
        } else {
            common_type = type_value.string;
        }

        try appendOwned(allocator, &enum_values, try cloneJsonValue(allocator, literal_value));
    }

    var object = std.json.ObjectMap.init(allocator);
    errdefer {
        var tmp = std.json.Value{ .object = object };
        freeJsonValue(allocator, &tmp);
    }

    try putOwned(allocator, &object, "type", .{ .string = try allocator.dupe(u8, common_type.?) });
    enum_values_moved = true;
    try putOwned(allocator, &object, "enum", .{ .array = enum_values });

    return .{ .object = object };
}

fn cleanTypeArray(allocator: std.mem.Allocator, value: std.json.Value) anyerror!std.json.Value {
    if (value != .array) return cloneJsonValue(allocator, value);

    var non_null = std.json.Array.init(allocator);
    errdefer {
        var tmp = std.json.Value{ .array = non_null };
        freeJsonValue(allocator, &tmp);
    }

    for (value.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, "null")) continue;
        try appendOwned(allocator, &non_null, try cloneJsonValue(allocator, item));
    }

    switch (non_null.items.len) {
        0 => {
            non_null.deinit();
            return .{ .string = try allocator.dupe(u8, "null") };
        },
        1 => {
            const only = non_null.items[0];
            non_null.clearAndFree();
            return only;
        },
        else => return .{ .array = non_null },
    }
}

fn cleanProperties(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    defs: *const std.StringHashMap(std.json.Value),
    strategy: CleaningStrategy,
    ref_stack: *std.StringHashMap(void),
) anyerror!std.json.Value {
    if (value != .object) return cloneJsonValue(allocator, value);

    var cleaned = std.json.ObjectMap.init(allocator);
    errdefer {
        var tmp = std.json.Value{ .object = cleaned };
        freeJsonValue(allocator, &tmp);
    }

    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        try putOwned(
            allocator,
            &cleaned,
            entry.key_ptr.*,
            try cleanWithDefs(allocator, entry.value_ptr.*, defs, strategy, ref_stack),
        );
    }

    return .{ .object = cleaned };
}

fn cleanUnion(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    defs: *const std.StringHashMap(std.json.Value),
    strategy: CleaningStrategy,
    ref_stack: *std.StringHashMap(void),
) anyerror!std.json.Value {
    if (value != .array) return cloneJsonValue(allocator, value);

    var cleaned = std.json.Array.init(allocator);
    errdefer {
        var tmp = std.json.Value{ .array = cleaned };
        freeJsonValue(allocator, &tmp);
    }

    for (value.array.items) |variant| {
        try appendOwned(allocator, &cleaned, try cleanWithDefs(allocator, variant, defs, strategy, ref_stack));
    }

    return .{ .array = cleaned };
}

fn preserveMeta(
    allocator: std.mem.Allocator,
    source_obj: std.json.ObjectMap,
    target_value: std.json.Value,
) anyerror!std.json.Value {
    var target = target_value;
    errdefer freeJsonValue(allocator, &target);

    if (target == .object) {
        for (SCHEMA_META_KEYS) |key| {
            if (source_obj.get(key)) |value| {
                try putOwned(allocator, &target.object, key, try cloneJsonValue(allocator, value));
            }
        }
    }

    return target;
}

fn containsKeyword(keywords: []const []const u8, key: []const u8) bool {
    for (keywords) |keyword| {
        if (std.mem.eql(u8, keyword, key)) return true;
    }
    return false;
}

fn emptyObject(allocator: std.mem.Allocator) std.json.Value {
    return .{ .object = std.json.ObjectMap.init(allocator) };
}

fn putDefinition(
    allocator: std.mem.Allocator,
    defs: *std.StringHashMap(std.json.Value),
    key: []const u8,
    value: std.json.Value,
) anyerror!void {
    const cloned = try cloneJsonValue(allocator, value);
    errdefer {
        var tmp = cloned;
        freeJsonValue(allocator, &tmp);
    }

    if (defs.getPtr(key)) |existing| {
        freeJsonValue(allocator, existing);
        existing.* = cloned;
        return;
    }

    const key_owned = try allocator.dupe(u8, key);
    errdefer allocator.free(key_owned);
    try defs.put(key_owned, cloned);
}

fn pushRefStack(
    allocator: std.mem.Allocator,
    ref_stack: *std.StringHashMap(void),
    ref_value: []const u8,
) anyerror!void {
    const ref_owned = try allocator.dupe(u8, ref_value);
    errdefer allocator.free(ref_owned);
    try ref_stack.put(ref_owned, {});
}

fn popRefStack(
    allocator: std.mem.Allocator,
    ref_stack: *std.StringHashMap(void),
    ref_value: []const u8,
) void {
    if (ref_stack.fetchRemove(ref_value)) |entry| {
        allocator.free(entry.key);
    }
}

fn deinitDefs(allocator: std.mem.Allocator, defs: *std.StringHashMap(std.json.Value)) void {
    var iterator = defs.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeJsonValue(allocator, entry.value_ptr);
    }
    defs.deinit();
}

fn deinitRefStack(allocator: std.mem.Allocator, ref_stack: *std.StringHashMap(void)) void {
    var iterator = ref_stack.keyIterator();
    while (iterator.next()) |key| {
        allocator.free(key.*);
    }
    ref_stack.deinit();
}

fn appendOwned(allocator: std.mem.Allocator, array: *std.json.Array, value: std.json.Value) anyerror!void {
    var owned = value;
    errdefer freeJsonValue(allocator, &owned);
    try array.append(owned);
}

fn putOwned(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) anyerror!void {
    var owned = value;
    errdefer freeJsonValue(allocator, &owned);

    if (object.getPtr(key)) |existing| {
        freeJsonValue(allocator, existing);
        existing.* = owned;
        return;
    }

    const key_owned = try allocator.dupe(u8, key);
    errdefer allocator.free(key_owned);
    try object.put(key_owned, owned);
}

pub fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) anyerror!std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |inner| .{ .bool = inner },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .number_string => |inner| .{ .number_string = try allocator.dupe(u8, inner) },
        .string => |inner| .{ .string = try allocator.dupe(u8, inner) },
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            errdefer {
                var tmp = std.json.Value{ .array = cloned };
                freeJsonValue(allocator, &tmp);
            }
            for (array.items) |item| {
                try appendOwned(allocator, &cloned, try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned = std.json.ObjectMap.init(allocator);
            errdefer {
                var tmp = std.json.Value{ .object = cloned };
                freeJsonValue(allocator, &tmp);
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try putOwned(
                    allocator,
                    &cloned,
                    entry.key_ptr.*,
                    try cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = cloned };
        },
    };
}

pub fn freeJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .null, .bool, .integer, .float => {},
        .number_string => |inner| allocator.free(inner),
        .string => |inner| allocator.free(inner),
        .array => |*array| {
            for (array.items) |*item| freeJsonValue(allocator, item);
            array.deinit();
        },
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
    }
}

fn parseTestValue(raw: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
}

test "CleaningStrategy unsupported keyword sets match Rust" {
    try std.testing.expectEqual(@as(usize, 20), GEMINI_UNSUPPORTED_KEYWORDS.len);
    try std.testing.expect(containsKeyword(CleaningStrategy.Gemini.unsupportedKeywords(), "minLength"));
    try std.testing.expect(containsKeyword(CleaningStrategy.Anthropic.unsupportedKeywords(), "$defs"));
    try std.testing.expectEqual(@as(usize, 0), CleaningStrategy.OpenAI.unsupportedKeywords().len);
    try std.testing.expect(containsKeyword(CleaningStrategy.Conservative.unsupportedKeywords(), "additionalProperties"));
}

test "decodeJsonPointer uses JSON Pointer escaping single pass" {
    const allocator = std.testing.allocator;
    const decoded = try decodeJsonPointer(allocator, "Foo~1Bar~0Baz~01");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("Foo/Bar~Baz~1", decoded);

    const parsed = (try parseLocalRef(allocator, "#/definitions/A~1B")).?;
    defer allocator.free(parsed);
    try std.testing.expectEqualStrings("A/B", parsed);
}

test "ref resolution preserves metadata and decodes escaped names" {
    var parsed = try parseTestValue(
        \\{
        \\  "$ref": "#/$defs/Foo~1Bar",
        \\  "description": "local description",
        \\  "title": "Local title",
        \\  "$defs": {
        \\    "Foo/Bar": { "type": "string", "minimum": 1 }
        \\  }
        \\}
    );
    defer parsed.deinit();

    var cleaned = try cleanForGemini(std.testing.allocator, parsed.value);
    defer freeJsonValue(std.testing.allocator, &cleaned);

    try std.testing.expectEqualStrings("string", cleaned.object.get("type").?.string);
    try std.testing.expectEqualStrings("local description", cleaned.object.get("description").?.string);
    try std.testing.expectEqualStrings("Local title", cleaned.object.get("title").?.string);
    try std.testing.expect(!cleaned.object.contains("minimum"));
}

test "cycle detection returns empty object with ref metadata" {
    var parsed = try parseTestValue(
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "root": { "$ref": "#/$defs/A", "description": "root ref" }
        \\  },
        \\  "$defs": {
        \\    "A": { "type": "object", "properties": { "b": { "$ref": "#/$defs/B", "title": "B ref" } } },
        \\    "B": { "type": "object", "properties": { "a": { "$ref": "#/$defs/A", "default": null } } }
        \\  }
        \\}
    );
    defer parsed.deinit();

    var cleaned = try cleanForGemini(std.testing.allocator, parsed.value);
    defer freeJsonValue(std.testing.allocator, &cleaned);

    const root = cleaned.object.get("properties").?.object.get("root").?;
    try std.testing.expectEqualStrings("object", root.object.get("type").?.string);
    try std.testing.expectEqualStrings("root ref", root.object.get("description").?.string);
    const cycle_break = root.object.get("properties").?.object.get("b").?.object.get("properties").?.object.get("a").?;
    try std.testing.expect(cycle_break.object.contains("default"));
    try std.testing.expect(!cycle_break.object.contains("type"));
}

test "union simplification unwraps nullable and flattens literals" {
    var nullable = try parseTestValue(
        \\{"anyOf":[{"type":"string"},{"type":"null"}],"description":"maybe string"}
    );
    defer nullable.deinit();
    var cleaned_nullable = try cleanForGemini(std.testing.allocator, nullable.value);
    defer freeJsonValue(std.testing.allocator, &cleaned_nullable);
    try std.testing.expectEqualStrings("string", cleaned_nullable.object.get("type").?.string);
    try std.testing.expectEqualStrings("maybe string", cleaned_nullable.object.get("description").?.string);
    try std.testing.expect(!cleaned_nullable.object.contains("anyOf"));

    var literals = try parseTestValue(
        \\{"oneOf":[{"type":"string","const":"admin"},{"type":"string","const":"user"}]}
    );
    defer literals.deinit();
    var cleaned_literals = try cleanForGemini(std.testing.allocator, literals.value);
    defer freeJsonValue(std.testing.allocator, &cleaned_literals);
    try std.testing.expectEqualStrings("string", cleaned_literals.object.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 2), cleaned_literals.object.get("enum").?.array.items.len);
}

test "non-simplifiable unions keep variants and strip sibling type" {
    var parsed = try parseTestValue(
        \\{
        \\  "type": "object",
        \\  "anyOf": [
        \\    { "type": "string", "minLength": 1 },
        \\    { "type": "integer", "minimum": 1 }
        \\  ]
        \\}
    );
    defer parsed.deinit();

    var cleaned = try cleanForGemini(std.testing.allocator, parsed.value);
    defer freeJsonValue(std.testing.allocator, &cleaned);

    try std.testing.expect(!cleaned.object.contains("type"));
    try std.testing.expectEqual(@as(usize, 2), cleaned.object.get("anyOf").?.array.items.len);
    try std.testing.expect(!cleaned.object.get("anyOf").?.array.items[0].object.contains("minLength"));
    try std.testing.expect(!cleaned.object.get("anyOf").?.array.items[1].object.contains("minimum"));
}

test "type arrays remove null and retain Rust fallback" {
    var parsed = try parseTestValue(
        \\{"properties":{"a":{"type":["string","null"]},"b":{"type":["null"]},"c":{"type":["string","integer"]},"d":{"type":["null","null"]}}}
    );
    defer parsed.deinit();

    var cleaned = try cleanForGemini(std.testing.allocator, parsed.value);
    defer freeJsonValue(std.testing.allocator, &cleaned);

    const props = cleaned.object.get("properties").?.object;
    try std.testing.expectEqualStrings("string", props.get("a").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("null", props.get("b").?.object.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 2), props.get("c").?.object.get("type").?.array.items.len);
    try std.testing.expectEqualStrings("null", props.get("d").?.object.get("type").?.string);
}

test "const converts to enum recursively" {
    var parsed = try parseTestValue(
        \\{"type":"object","properties":{"mode":{"type":"string","const":"fast"}},"const":"top"}
    );
    defer parsed.deinit();

    var cleaned = try cleanForOpenai(std.testing.allocator, parsed.value);
    defer freeJsonValue(std.testing.allocator, &cleaned);

    try std.testing.expect(!cleaned.object.contains("const"));
    try std.testing.expectEqualStrings("top", cleaned.object.get("enum").?.array.items[0].string);
    const mode = cleaned.object.get("properties").?.object.get("mode").?;
    try std.testing.expect(!mode.object.contains("const"));
    try std.testing.expectEqualStrings("fast", mode.object.get("enum").?.array.items[0].string);
}

test "strategy differences preserve OpenAI and filter stricter providers" {
    var parsed = try parseTestValue(
        \\{"type":"string","minLength":1,"additionalProperties":false,"$defs":{"X":{"type":"string"}},"description":"field"}
    );
    defer parsed.deinit();

    var gemini = try cleanForGemini(std.testing.allocator, parsed.value);
    defer freeJsonValue(std.testing.allocator, &gemini);
    try std.testing.expect(!gemini.object.contains("minLength"));
    try std.testing.expect(!gemini.object.contains("additionalProperties"));
    try std.testing.expect(!gemini.object.contains("$defs"));

    var anthropic = try cleanForAnthropic(std.testing.allocator, parsed.value);
    defer freeJsonValue(std.testing.allocator, &anthropic);
    try std.testing.expect(anthropic.object.contains("minLength"));
    try std.testing.expect(anthropic.object.contains("additionalProperties"));
    try std.testing.expect(!anthropic.object.contains("$defs"));

    var openai = try cleanForOpenai(std.testing.allocator, parsed.value);
    defer freeJsonValue(std.testing.allocator, &openai);
    try std.testing.expect(openai.object.contains("minLength"));
    try std.testing.expect(openai.object.contains("additionalProperties"));
    try std.testing.expect(openai.object.contains("$defs"));

    var conservative = try clean(std.testing.allocator, parsed.value, .Conservative);
    defer freeJsonValue(std.testing.allocator, &conservative);
    try std.testing.expect(conservative.object.contains("minLength"));
    try std.testing.expect(!conservative.object.contains("additionalProperties"));
    try std.testing.expect(!conservative.object.contains("$defs"));
}

test "validate mirrors Rust error and warning shape" {
    var valid = try parseTestValue("{\"type\":\"object\",\"properties\":{}}");
    defer valid.deinit();
    try validate(valid.value);

    var missing_type = try parseTestValue("{\"properties\":{}}");
    defer missing_type.deinit();
    try std.testing.expectError(error.SchemaMissingType, validate(missing_type.value));

    var object_without_properties = try parseTestValue("{\"type\":\"object\"}");
    defer object_without_properties.deinit();
    try validate(object_without_properties.value);

    var not_object = try parseTestValue("[\"object\"]");
    defer not_object.deinit();
    try std.testing.expectError(error.InvalidSchema, validate(not_object.value));
}

test "mixed schema cleans refs unions type arrays const and unsupported keywords end to end" {
    var parsed = try parseTestValue(
        \\{
        \\  "type": "object",
        \\  "additionalProperties": false,
        \\  "properties": {
        \\    "kind": {
        \\      "oneOf": [
        \\        { "type": "string", "const": "alpha" },
        \\        { "type": "string", "const": "beta" },
        \\        { "type": "null" }
        \\      ]
        \\    },
        \\    "name": { "$ref": "#/$defs/Name", "description": "display name" },
        \\    "maybe": { "type": ["integer", "null"], "minimum": 0 }
        \\  },
        \\  "$defs": {
        \\    "Name": { "type": "string", "minLength": 1, "const": "Ada" }
        \\  }
        \\}
    );
    defer parsed.deinit();

    var gemini = try cleanForGemini(std.testing.allocator, parsed.value);
    defer freeJsonValue(std.testing.allocator, &gemini);
    const gemini_props = gemini.object.get("properties").?.object;
    try std.testing.expect(!gemini.object.contains("additionalProperties"));
    try std.testing.expect(!gemini.object.contains("$defs"));
    try std.testing.expectEqual(@as(usize, 2), gemini_props.get("kind").?.object.get("enum").?.array.items.len);
    try std.testing.expectEqualStrings("Ada", gemini_props.get("name").?.object.get("enum").?.array.items[0].string);
    try std.testing.expectEqualStrings("display name", gemini_props.get("name").?.object.get("description").?.string);
    try std.testing.expectEqualStrings("integer", gemini_props.get("maybe").?.object.get("type").?.string);
    try std.testing.expect(!gemini_props.get("maybe").?.object.contains("minimum"));

    var openai = try cleanForOpenai(std.testing.allocator, parsed.value);
    defer freeJsonValue(std.testing.allocator, &openai);
    const openai_props = openai.object.get("properties").?.object;
    try std.testing.expect(openai.object.contains("$defs"));
    try std.testing.expect(openai.object.contains("additionalProperties"));
    try std.testing.expectEqualStrings("integer", openai_props.get("maybe").?.object.get("type").?.string);
    try std.testing.expect(openai_props.get("maybe").?.object.contains("minimum"));
}
