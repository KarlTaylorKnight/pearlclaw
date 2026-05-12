//! ReportTemplateTool port of `zeroclaw-tools/src/report_template_tool.rs`.
//!
//! Standalone access to the report template engine. Pure-compute,
//! synchronous tool — see Phase 7-H notes in docs/porting-notes.md.
//!
//! Parameter schema and error strings are byte-copied from Rust:
//!   - `template` (string, enum, required): weekly_status, sprint_review,
//!     risk_register, milestone_report.
//!   - `language` (string, enum, default "en"): en, de, fr, it.
//!   - `variables` (object, required): map of placeholder names to values.
//!
//! Non-string variable values are coerced to strings exactly as Rust's
//! `serde_json::Value::to_string` does:
//!   - Number → JSON number literal (e.g. `3` → `"3"`, `3.14` → `"3.14"`).
//!   - Bool → `"true"` / `"false"`.
//!   - Null, Array, Object → empty string.

const std = @import("std");
const common = @import("fs_common.zig");
const parser_types = @import("../tool_call_parser/types.zig");
const report_templates = @import("report_templates.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "report_template";
const DESCRIPTION =
    "Render a report template with custom variables. Supports weekly_status, sprint_review, risk_register, milestone_report in en/de/fr/it.";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "template": {
    \\      "type": "string",
    \\      "enum": ["weekly_status", "sprint_review", "risk_register", "milestone_report"],
    \\      "description": "Template name"
    \\    },
    \\    "language": {
    \\      "type": "string",
    \\      "enum": ["en", "de", "fr", "it"],
    \\      "default": "en",
    \\      "description": "Language code"
    \\    },
    \\    "variables": {
    \\      "type": "object",
    \\      "description": "Map of placeholder names to values (e.g., {\"project_name\": \"Acme\"})"
    \\    }
    \\  },
    \\  "required": ["template", "variables"]
    \\}
;

pub const ReportTemplateTool = struct {
    pub fn init(_: std.mem.Allocator) ReportTemplateTool {
        return .{};
    }

    pub fn deinit(_: *ReportTemplateTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *ReportTemplateTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable: Tool.VTable = .{
        .name = nameImpl,
        .description = descriptionImpl,
        .parametersSchema = parametersSchemaImpl,
        .execute = executeImpl,
        .deinit = deinitImpl,
    };

    fn nameImpl(_: *anyopaque) []const u8 {
        return NAME;
    }

    fn descriptionImpl(_: *anyopaque) []const u8 {
        return DESCRIPTION;
    }

    fn parametersSchemaImpl(_: *anyopaque, allocator: std.mem.Allocator) anyerror!std.json.Value {
        return parametersSchema(allocator);
    }

    fn executeImpl(ptr: *anyopaque, allocator: std.mem.Allocator, args: std.json.Value) anyerror!ToolResult {
        _ = @as(*ReportTemplateTool, @ptrCast(@alignCast(ptr)));
        return common.resultFromReturn(allocator, try dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ReportTemplateTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }
};

fn dispatch(allocator: std.mem.Allocator, args: std.json.Value) !common.FsReturn {
    if (args != .object) {
        return common.failure(allocator, "missing template");
    }

    const template_value = args.object.get("template") orelse {
        return common.failure(allocator, "missing template");
    };
    if (template_value != .string) {
        return common.failure(allocator, "missing template");
    }
    const template_name = template_value.string;

    const language = blk: {
        const raw = args.object.get("language") orelse break :blk "en";
        if (raw != .string) break :blk "en";
        break :blk raw.string;
    };

    const variables_value = args.object.get("variables") orelse {
        return common.failure(allocator, "variables must be object");
    };
    if (variables_value != .object) {
        return common.failure(allocator, "variables must be object");
    }

    var var_map = std.StringHashMap([]const u8).init(allocator);
    defer cleanupVarMap(allocator, &var_map);

    // Track allocated coerced strings so we can free them on error.
    var allocated_values = std.ArrayList([]u8).init(allocator);
    defer {
        for (allocated_values.items) |slice| allocator.free(slice);
        allocated_values.deinit();
    }

    var it = variables_value.object.iterator();
    while (it.next()) |entry| {
        // Reserve capacity before allocating the value to avoid a window
        // where the coerced slice has no owner. Once ensureUnusedCapacity
        // succeeds, the subsequent appendAssumeCapacity is infallible, so
        // the slice transfers cleanly into allocated_values which the
        // outer defer drains.
        try allocated_values.ensureUnusedCapacity(1);
        const value_owned = try coerceToString(allocator, entry.value_ptr.*);
        allocated_values.appendAssumeCapacity(value_owned);
        try var_map.put(entry.key_ptr.*, value_owned);
    }

    const rendered = report_templates.renderTemplate(
        allocator,
        template_name,
        language,
        var_map,
    ) catch |err| switch (err) {
        report_templates.RenderError.UnknownTemplate => {
            return common.failureFmt(
                allocator,
                "unsupported template: {s}",
                .{template_name},
            );
        },
        else => return err,
    };

    return .{ .output = rendered };
}

fn cleanupVarMap(_: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    map.deinit();
}

/// Coerce a JSON value to a Rust-compatible string representation.
///
/// Mirrors the Rust match in `report_template_tool.rs::execute`:
///   - String → use as-is.
///   - Number → `n.to_string()`.
///   - Bool → `"true"` / `"false"`.
///   - Null / Array / Object → empty string.
///
/// The number formatting must match `serde_json::Number::to_string`. Zig's
/// `std.json` exposes integers as `.integer`, floats as `.float`, and any
/// number that doesn't fit either as `.number_string` (the raw lexed
/// literal). For `.float` we mirror serde_json's `f64::to_string` via the
/// `{d}` formatter, which yields the shortest round-trip form (matching
/// `ryu`-style behavior that serde_json uses under the hood for the
/// happy-path numbers exercised by the eval fixtures).
fn coerceToString(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |s| allocator.dupe(u8, s),
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .number_string => |raw| allocator.dupe(u8, raw),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        .null, .array, .object => allocator.dupe(u8, ""),
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────

fn parseArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

fn executeJson(json: []const u8) !ToolResult {
    var parsed = try parseArgs(std.testing.allocator, json);
    defer parsed.deinit();
    var tool_impl = ReportTemplateTool.init(std.testing.allocator);
    defer tool_impl.deinit(std.testing.allocator);
    return tool_impl.tool().execute(std.testing.allocator, parsed.value);
}

test "report_template renders weekly_status with English variables" {
    var result = try executeJson(
        \\{
        \\  "template": "weekly_status",
        \\  "language": "en",
        \\  "variables": {
        \\    "project_name": "ZeroClaw",
        \\    "period": "W1",
        \\    "completed": "Done",
        \\    "in_progress": "WIP",
        \\    "blocked": "None",
        \\    "next_steps": "Next"
        \\  }
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Project: ZeroClaw") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Period: W1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## Completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## Next Steps") != null);
}

test "report_template defaults missing language to English" {
    var result = try executeJson(
        \\{
        \\  "template": "weekly_status",
        \\  "variables": {
        \\    "project_name": "Test"
        \\  }
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## Summary") != null);
}

test "report_template renders sprint_review with Velocity section" {
    var result = try executeJson(
        \\{
        \\  "template": "sprint_review",
        \\  "language": "en",
        \\  "variables": {
        \\    "sprint_dates": "2026-W10",
        \\    "completed": "X",
        \\    "in_progress": "Y",
        \\    "blocked": "Z",
        \\    "velocity": "42"
        \\  }
        \\}
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## Velocity") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "report_template renders German milestone_report" {
    var result = try executeJson(
        \\{
        \\  "template": "milestone_report",
        \\  "language": "de",
        \\  "variables": {
        \\    "project_name": "Acme",
        \\    "milestones": "M1",
        \\    "status": "on track"
        \\  }
        \\}
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## Projekt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## Meilensteine") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Acme") != null);
}

test "report_template fails on missing template field" {
    var result = try executeJson(
        \\{"variables": {"project_name": "Test"}}
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("", result.output);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expectEqualStrings("missing template", result.error_msg.?);
}

test "report_template fails on missing variables field" {
    var result = try executeJson(
        \\{"template": "weekly_status"}
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("", result.output);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expectEqualStrings("variables must be object", result.error_msg.?);
}

test "report_template fails on unknown template name" {
    var result = try executeJson(
        \\{"template": "mystery", "variables": {}}
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("", result.output);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expectEqualStrings("unsupported template: mystery", result.error_msg.?);
}

test "report_template coerces non-string variable values" {
    var result = try executeJson(
        \\{
        \\  "template": "risk_register",
        \\  "variables": {
        \\    "project_name": "Acme",
        \\    "risks": 3,
        \\    "mitigations": true
        \\  }
        \\}
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    // Number coerced to "3".
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## Risks\n\n3") != null);
    // Bool coerced to "true".
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## Mitigations\n\ntrue") != null);
}

test "report_template coerces null/array/object variable values to empty string" {
    var result = try executeJson(
        \\{
        \\  "template": "risk_register",
        \\  "variables": {
        \\    "project_name": null,
        \\    "risks": [1, 2],
        \\    "mitigations": {"k": "v"}
        \\  }
        \\}
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    // Each section's body should now be empty: `## Heading\n\n\n\n`.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## Project\n\n\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## Risks\n\n\n\n") != null);
}

test "report_template HTML-escape edge case in variable values" {
    // Variables are inserted *into* Markdown output, not HTML. Rust does
    // NOT escape Markdown bodies; only the Html branch escapes. So a
    // variable containing `<script>` is emitted verbatim in Markdown.
    var result = try executeJson(
        \\{
        \\  "template": "risk_register",
        \\  "variables": {
        \\    "project_name": "<script>alert(1)</script>",
        \\    "risks": "&amp;",
        \\    "mitigations": ""
        \\  }
        \\}
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<script>alert(1)</script>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "&amp;") != null);
}

test "report_template spec exposes name, description, parameters" {
    var tool_impl = ReportTemplateTool.init(std.testing.allocator);
    defer tool_impl.deinit(std.testing.allocator);

    var spec = try tool_impl.tool().spec(std.testing.allocator);
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(NAME, spec.name);
    try std.testing.expectEqualStrings(DESCRIPTION, spec.description);
    try std.testing.expect(spec.parameters == .object);
    try std.testing.expect(spec.parameters.object.contains("properties"));
    try std.testing.expect(spec.parameters.object.contains("required"));
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    const json =
        \\{"template":"weekly_status","language":"en","variables":{"project_name":"X","period":"P","completed":"C","in_progress":"I","blocked":"B","next_steps":"N"}}
    ;
    var parsed = try parseArgs(std.testing.allocator, json);
    defer parsed.deinit();

    var tool_impl = ReportTemplateTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    const json =
        \\{"template":"mystery","variables":{}}
    ;
    var parsed = try parseArgs(std.testing.allocator, json);
    defer parsed.deinit();

    var tool_impl = ReportTemplateTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    var tool_impl = ReportTemplateTool.init(allocator);
    defer tool_impl.deinit(allocator);
    var value = try tool_impl.tool().parametersSchema(allocator);
    defer parser_types.freeJsonValue(allocator, &value);
}

test "report_template execute and parametersSchema are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}
