//! Report template engine — port of `zeroclaw-tools/src/report_templates.rs`.
//!
//! Pure-Rust string templating: builds a Markdown document by substituting
//! `{{key}}` placeholders into language-specific section tables. No FS, no
//! net, no async. Phase 7-H parity targets:
//!
//!   - 4 built-in templates: weekly_status, sprint_review, risk_register,
//!     milestone_report.
//!   - 4 languages: en (default), de, fr, it. Unknown languages silently
//!     fall back to English to match Rust's `match lang { ... _ => en }`
//!     branch.
//!   - Markdown output only. The Rust `ReportFormat::Html` branch exists
//!     but is never produced by `render_template`; this port preserves the
//!     Markdown rendering path and exposes the Html branch as
//!     `ReportFormat.html` for completeness so future ports can reuse it.
//!   - Single-pass `{{key}}` substitution: unknown placeholders are emitted
//!     verbatim, values containing `{{...}}` are not re-expanded. Mirrors
//!     the Rust byte-walking scanner exactly for ASCII templates (the
//!     ported tables are pure ASCII).
//!
//! See docs/porting-notes.md Phase 7-H for pinned decisions.

const std = @import("std");

/// Supported output formats. `render_template` only ever produces
/// Markdown today; `html` is wired through for byte-equal parity with the
/// Rust enum.
pub const ReportFormat = enum {
    markdown,
    html,
};

/// A single named section within a template: a heading line plus a body
/// block. Both strings may contain `{{key}}` placeholders.
pub const TemplateSection = struct {
    heading: []const u8,
    body: []const u8,
};

/// Built-in template descriptor. The `name` field mirrors the Rust
/// `ReportTemplate::name` field (the human-readable title in the target
/// language); it is not emitted into the rendered output but is exposed
/// for parity with the Rust struct shape.
pub const ReportTemplate = struct {
    name: []const u8,
    sections: []const TemplateSection,
    format: ReportFormat,

    /// Render the template by substituting `{{key}}` placeholders with
    /// values from `vars`. The returned slice is owned by `allocator`.
    pub fn render(
        self: ReportTemplate,
        allocator: std.mem.Allocator,
        vars: std.StringHashMap([]const u8),
    ) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        for (self.sections) |section| {
            const heading = try substitute(allocator, section.heading, vars);
            defer allocator.free(heading);
            const body = try substitute(allocator, section.body, vars);
            defer allocator.free(body);

            switch (self.format) {
                .markdown => {
                    try buffer.writer().print("## {s}\n\n{s}\n\n", .{ heading, body });
                },
                .html => {
                    const heading_escaped = try escapeHtml(allocator, heading);
                    defer allocator.free(heading_escaped);
                    const body_escaped = try escapeHtml(allocator, body);
                    defer allocator.free(body_escaped);
                    try buffer.writer().print(
                        "<h2>{s}</h2>\n<p>{s}</p>\n",
                        .{ heading_escaped, body_escaped },
                    );
                },
            }
        }

        // Match Rust's `out.trim_end().to_string()`: drop trailing ASCII
        // whitespace (space, tab, CR, LF, FF, VT). The Rust implementation
        // uses `str::trim_end` which strips Unicode whitespace, but every
        // section emits the same ASCII suffix so ASCII trimming is
        // sufficient and byte-equal.
        var end = buffer.items.len;
        while (end > 0) : (end -= 1) {
            const ch = buffer.items[end - 1];
            if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r' and ch != 0x0B and ch != 0x0C) break;
        }
        buffer.shrinkRetainingCapacity(end);
        return buffer.toOwnedSlice();
    }
};

/// Single-pass `{{key}}` substitution. Mirrors the Rust scanner:
///   - At each byte, look for `{{`.
///   - If found, search for the next `}}` in the remainder.
///   - If a closing `}}` exists, look up the key in `vars`; on hit, append
///     the value; on miss, emit the literal `{{key}}` verbatim.
///   - Otherwise, append the current byte and advance one byte.
///
/// Values that themselves contain `{{...}}` are NOT re-expanded.
fn substitute(
    allocator: std.mem.Allocator,
    template: []const u8,
    vars: std.StringHashMap([]const u8),
) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, template.len);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '{') {
            // Search for the closing `}}` in the remainder.
            const remainder = template[i + 2 ..];
            if (std.mem.indexOf(u8, remainder, "}}")) |close_offset| {
                const key = remainder[0..close_offset];
                if (vars.get(key)) |value| {
                    try result.appendSlice(value);
                } else {
                    // Unknown placeholder: emit `{{key}}` literally.
                    try result.appendSlice(template[i .. i + 2 + close_offset + 2]);
                }
                i += 2 + close_offset + 2;
                continue;
            }
        }
        try result.append(template[i]);
        i += 1;
    }

    return result.toOwnedSlice();
}

/// HTML escape for safe inclusion in `<h2>`/`<p>` output. Mirrors the
/// Rust `escape_html` helper. Exposed `pub` for unit tests.
pub fn escapeHtml(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, s.len);
    errdefer out.deinit();
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice("&amp;"),
            '<' => try out.appendSlice("&lt;"),
            '>' => try out.appendSlice("&gt;"),
            '"' => try out.appendSlice("&quot;"),
            '\'' => try out.appendSlice("&#x27;"),
            else => try out.append(c),
        }
    }
    return out.toOwnedSlice();
}

// ── Built-in templates ────────────────────────────────────────────
//
// Each template returns a `ReportTemplate` whose `sections` slice points
// into one of the module-level static arrays below. The data tables are
// pure ASCII and shared across renders. Strings are byte-copied from the
// Rust source to guarantee parity.

const WEEKLY_STATUS_EN = [_]TemplateSection{
    .{ .heading = "Summary", .body = "Project: {{project_name}} | Period: {{period}}" },
    .{ .heading = "Completed", .body = "{{completed}}" },
    .{ .heading = "In Progress", .body = "{{in_progress}}" },
    .{ .heading = "Blocked", .body = "{{blocked}}" },
    .{ .heading = "Next Steps", .body = "{{next_steps}}" },
};

const WEEKLY_STATUS_DE = [_]TemplateSection{
    .{ .heading = "Zusammenfassung", .body = "Projekt: {{project_name}} | Zeitraum: {{period}}" },
    .{ .heading = "Erledigt", .body = "{{completed}}" },
    .{ .heading = "In Bearbeitung", .body = "{{in_progress}}" },
    .{ .heading = "Blockiert", .body = "{{blocked}}" },
    .{ .heading = "Naechste Schritte", .body = "{{next_steps}}" },
};

const WEEKLY_STATUS_FR = [_]TemplateSection{
    .{ .heading = "Resume", .body = "Projet: {{project_name}} | Periode: {{period}}" },
    .{ .heading = "Termine", .body = "{{completed}}" },
    .{ .heading = "En cours", .body = "{{in_progress}}" },
    .{ .heading = "Bloque", .body = "{{blocked}}" },
    .{ .heading = "Prochaines etapes", .body = "{{next_steps}}" },
};

const WEEKLY_STATUS_IT = [_]TemplateSection{
    .{ .heading = "Riepilogo", .body = "Progetto: {{project_name}} | Periodo: {{period}}" },
    .{ .heading = "Completato", .body = "{{completed}}" },
    .{ .heading = "In corso", .body = "{{in_progress}}" },
    .{ .heading = "Bloccato", .body = "{{blocked}}" },
    .{ .heading = "Prossimi passi", .body = "{{next_steps}}" },
};

const SPRINT_REVIEW_EN = [_]TemplateSection{
    .{ .heading = "Sprint", .body = "{{sprint_dates}}" },
    .{ .heading = "Completed", .body = "{{completed}}" },
    .{ .heading = "In Progress", .body = "{{in_progress}}" },
    .{ .heading = "Blocked", .body = "{{blocked}}" },
    .{ .heading = "Velocity", .body = "{{velocity}}" },
};

const SPRINT_REVIEW_DE = [_]TemplateSection{
    .{ .heading = "Sprint", .body = "{{sprint_dates}}" },
    .{ .heading = "Erledigt", .body = "{{completed}}" },
    .{ .heading = "In Bearbeitung", .body = "{{in_progress}}" },
    .{ .heading = "Blockiert", .body = "{{blocked}}" },
    .{ .heading = "Velocity", .body = "{{velocity}}" },
};

const SPRINT_REVIEW_FR = [_]TemplateSection{
    .{ .heading = "Sprint", .body = "{{sprint_dates}}" },
    .{ .heading = "Termine", .body = "{{completed}}" },
    .{ .heading = "En cours", .body = "{{in_progress}}" },
    .{ .heading = "Bloque", .body = "{{blocked}}" },
    .{ .heading = "Velocite", .body = "{{velocity}}" },
};

const SPRINT_REVIEW_IT = [_]TemplateSection{
    .{ .heading = "Sprint", .body = "{{sprint_dates}}" },
    .{ .heading = "Completato", .body = "{{completed}}" },
    .{ .heading = "In corso", .body = "{{in_progress}}" },
    .{ .heading = "Bloccato", .body = "{{blocked}}" },
    .{ .heading = "Velocita", .body = "{{velocity}}" },
};

const RISK_REGISTER_EN = [_]TemplateSection{
    .{ .heading = "Project", .body = "{{project_name}}" },
    .{ .heading = "Risks", .body = "{{risks}}" },
    .{ .heading = "Mitigations", .body = "{{mitigations}}" },
};

const RISK_REGISTER_DE = [_]TemplateSection{
    .{ .heading = "Projekt", .body = "{{project_name}}" },
    .{ .heading = "Risiken", .body = "{{risks}}" },
    .{ .heading = "Massnahmen", .body = "{{mitigations}}" },
};

const RISK_REGISTER_FR = [_]TemplateSection{
    .{ .heading = "Projet", .body = "{{project_name}}" },
    .{ .heading = "Risques", .body = "{{risks}}" },
    .{ .heading = "Mesures", .body = "{{mitigations}}" },
};

const RISK_REGISTER_IT = [_]TemplateSection{
    .{ .heading = "Progetto", .body = "{{project_name}}" },
    .{ .heading = "Rischi", .body = "{{risks}}" },
    .{ .heading = "Mitigazioni", .body = "{{mitigations}}" },
};

const MILESTONE_REPORT_EN = [_]TemplateSection{
    .{ .heading = "Project", .body = "{{project_name}}" },
    .{ .heading = "Milestones", .body = "{{milestones}}" },
    .{ .heading = "Status", .body = "{{status}}" },
};

const MILESTONE_REPORT_DE = [_]TemplateSection{
    .{ .heading = "Projekt", .body = "{{project_name}}" },
    .{ .heading = "Meilensteine", .body = "{{milestones}}" },
    .{ .heading = "Status", .body = "{{status}}" },
};

const MILESTONE_REPORT_FR = [_]TemplateSection{
    .{ .heading = "Projet", .body = "{{project_name}}" },
    .{ .heading = "Jalons", .body = "{{milestones}}" },
    .{ .heading = "Statut", .body = "{{status}}" },
};

const MILESTONE_REPORT_IT = [_]TemplateSection{
    .{ .heading = "Progetto", .body = "{{project_name}}" },
    .{ .heading = "Milestone", .body = "{{milestones}}" },
    .{ .heading = "Stato", .body = "{{status}}" },
};

/// Return the built-in weekly status template for the given language.
/// Unknown languages silently default to English (mirrors Rust `_ => en`).
pub fn weeklyStatusTemplate(lang: []const u8) ReportTemplate {
    if (std.mem.eql(u8, lang, "de")) {
        return .{ .name = "Wochenstatus", .sections = &WEEKLY_STATUS_DE, .format = .markdown };
    }
    if (std.mem.eql(u8, lang, "fr")) {
        return .{ .name = "Statut hebdomadaire", .sections = &WEEKLY_STATUS_FR, .format = .markdown };
    }
    if (std.mem.eql(u8, lang, "it")) {
        return .{ .name = "Stato settimanale", .sections = &WEEKLY_STATUS_IT, .format = .markdown };
    }
    return .{ .name = "Weekly Status", .sections = &WEEKLY_STATUS_EN, .format = .markdown };
}

/// Return the built-in sprint review template for the given language.
pub fn sprintReviewTemplate(lang: []const u8) ReportTemplate {
    if (std.mem.eql(u8, lang, "de")) {
        return .{ .name = "Sprint-Uebersicht", .sections = &SPRINT_REVIEW_DE, .format = .markdown };
    }
    if (std.mem.eql(u8, lang, "fr")) {
        return .{ .name = "Revue de sprint", .sections = &SPRINT_REVIEW_FR, .format = .markdown };
    }
    if (std.mem.eql(u8, lang, "it")) {
        return .{ .name = "Revisione sprint", .sections = &SPRINT_REVIEW_IT, .format = .markdown };
    }
    return .{ .name = "Sprint Review", .sections = &SPRINT_REVIEW_EN, .format = .markdown };
}

/// Return the built-in risk register template for the given language.
pub fn riskRegisterTemplate(lang: []const u8) ReportTemplate {
    if (std.mem.eql(u8, lang, "de")) {
        return .{ .name = "Risikoregister", .sections = &RISK_REGISTER_DE, .format = .markdown };
    }
    if (std.mem.eql(u8, lang, "fr")) {
        return .{ .name = "Registre des risques", .sections = &RISK_REGISTER_FR, .format = .markdown };
    }
    if (std.mem.eql(u8, lang, "it")) {
        return .{ .name = "Registro dei rischi", .sections = &RISK_REGISTER_IT, .format = .markdown };
    }
    return .{ .name = "Risk Register", .sections = &RISK_REGISTER_EN, .format = .markdown };
}

/// Return the built-in milestone report template for the given language.
pub fn milestoneReportTemplate(lang: []const u8) ReportTemplate {
    if (std.mem.eql(u8, lang, "de")) {
        return .{ .name = "Meilensteinbericht", .sections = &MILESTONE_REPORT_DE, .format = .markdown };
    }
    if (std.mem.eql(u8, lang, "fr")) {
        return .{ .name = "Rapport de jalons", .sections = &MILESTONE_REPORT_FR, .format = .markdown };
    }
    if (std.mem.eql(u8, lang, "it")) {
        return .{ .name = "Report milestone", .sections = &MILESTONE_REPORT_IT, .format = .markdown };
    }
    return .{ .name = "Milestone Report", .sections = &MILESTONE_REPORT_EN, .format = .markdown };
}

/// `RenderError.UnknownTemplate` is the parity for Rust's
/// `anyhow::bail!("unsupported template: {name}")`. The tool wrapper maps
/// this to a `ToolResult` failure with the same byte-for-byte message.
pub const RenderError = error{UnknownTemplate};

/// Look up a template by name and render it. Unknown template names
/// return `error.UnknownTemplate`; unknown languages silently use the
/// English fallback (matches Rust).
///
/// Caller owns the returned slice.
pub fn renderTemplate(
    allocator: std.mem.Allocator,
    template_name: []const u8,
    language: []const u8,
    vars: std.StringHashMap([]const u8),
) ![]u8 {
    const tpl = templateByName(template_name, language) orelse return RenderError.UnknownTemplate;
    return tpl.render(allocator, vars);
}

/// Resolve a template by `(name, language)`. Returns `null` for unknown
/// templates so callers can construct the exact Rust error message
/// (which includes the unknown name).
pub fn templateByName(name: []const u8, language: []const u8) ?ReportTemplate {
    if (std.mem.eql(u8, name, "weekly_status")) return weeklyStatusTemplate(language);
    if (std.mem.eql(u8, name, "sprint_review")) return sprintReviewTemplate(language);
    if (std.mem.eql(u8, name, "risk_register")) return riskRegisterTemplate(language);
    if (std.mem.eql(u8, name, "milestone_report")) return milestoneReportTemplate(language);
    return null;
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn mapFromPairs(pairs: []const [2][]const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(testing.allocator);
    for (pairs) |pair| {
        try map.put(pair[0], pair[1]);
    }
    return map;
}

test "weekly_status renders English headings and substitutes variables" {
    var vars = try mapFromPairs(&.{
        .{ "project_name", "ZeroClaw" },
        .{ "period", "2026-W10" },
        .{ "completed", "- Task A\n- Task B" },
        .{ "in_progress", "- Task C" },
        .{ "blocked", "None" },
        .{ "next_steps", "- Task D" },
    });
    defer vars.deinit();

    const tpl = weeklyStatusTemplate("en");
    const rendered = try tpl.render(testing.allocator, vars);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "## Summary") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Project: ZeroClaw") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Period: 2026-W10") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "- Task A") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "## Completed") != null);
    // Trailing whitespace stripped — last char is the last char of the body.
    try testing.expect(rendered[rendered.len - 1] != '\n');
}

test "weekly_status renders German, French, Italian headings" {
    var vars = std.StringHashMap([]const u8).init(testing.allocator);
    defer vars.deinit();

    const de = try weeklyStatusTemplate("de").render(testing.allocator, vars);
    defer testing.allocator.free(de);
    try testing.expect(std.mem.indexOf(u8, de, "## Zusammenfassung") != null);
    try testing.expect(std.mem.indexOf(u8, de, "## Erledigt") != null);
    try testing.expect(std.mem.indexOf(u8, de, "## Naechste Schritte") != null);

    const fr = try weeklyStatusTemplate("fr").render(testing.allocator, vars);
    defer testing.allocator.free(fr);
    try testing.expect(std.mem.indexOf(u8, fr, "## Resume") != null);
    try testing.expect(std.mem.indexOf(u8, fr, "## Termine") != null);
    try testing.expect(std.mem.indexOf(u8, fr, "## Prochaines etapes") != null);

    const it = try weeklyStatusTemplate("it").render(testing.allocator, vars);
    defer testing.allocator.free(it);
    try testing.expect(std.mem.indexOf(u8, it, "## Riepilogo") != null);
    try testing.expect(std.mem.indexOf(u8, it, "## Completato") != null);
    try testing.expect(std.mem.indexOf(u8, it, "## Prossimi passi") != null);
}

test "sprint_review template includes Velocity section in all languages" {
    inline for (.{ "en", "de", "fr", "it" }) |lang| {
        const tpl = sprintReviewTemplate(lang);
        try testing.expect(tpl.sections.len == 5);
    }
    try testing.expectEqualStrings("Velocity", sprintReviewTemplate("en").sections[4].heading);
    try testing.expectEqualStrings("Velocity", sprintReviewTemplate("de").sections[4].heading);
    try testing.expectEqualStrings("Velocite", sprintReviewTemplate("fr").sections[4].heading);
    try testing.expectEqualStrings("Velocita", sprintReviewTemplate("it").sections[4].heading);
}

test "risk_register and milestone_report have correct section counts" {
    inline for (.{ "en", "de", "fr", "it" }) |lang| {
        try testing.expect(riskRegisterTemplate(lang).sections.len == 3);
        try testing.expect(milestoneReportTemplate(lang).sections.len == 3);
    }
}

test "substitute leaves unknown placeholders as-is" {
    var vars = std.StringHashMap([]const u8).init(testing.allocator);
    defer vars.deinit();

    const out = try substitute(testing.allocator, "Hello {{name}}", vars);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hello {{name}}", out);
}

test "substitute replaces all occurrences without re-expanding values" {
    var vars = std.StringHashMap([]const u8).init(testing.allocator);
    defer vars.deinit();
    try vars.put("x", "1");
    const out = try substitute(testing.allocator, "{{x}} and {{x}}", vars);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("1 and 1", out);
}

test "substitute does not re-expand placeholder values" {
    var vars = std.StringHashMap([]const u8).init(testing.allocator);
    defer vars.deinit();
    try vars.put("a", "{{b}}");
    try vars.put("b", "BAD");
    const out = try substitute(testing.allocator, "{{a}}", vars);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{{b}}", out);
}

test "substitute handles unterminated brace prefix" {
    var vars = std.StringHashMap([]const u8).init(testing.allocator);
    defer vars.deinit();
    try vars.put("x", "1");

    const out = try substitute(testing.allocator, "{{x", vars);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{{x", out);
}

test "renderTemplate returns UnknownTemplate for unsupported names" {
    var vars = std.StringHashMap([]const u8).init(testing.allocator);
    defer vars.deinit();
    try testing.expectError(
        RenderError.UnknownTemplate,
        renderTemplate(testing.allocator, "mystery", "en", vars),
    );
}

test "renderTemplate accepts unknown language and falls back to English" {
    var vars = try mapFromPairs(&.{
        .{ "project_name", "X" },
        .{ "period", "P" },
        .{ "completed", "C" },
        .{ "in_progress", "I" },
        .{ "blocked", "B" },
        .{ "next_steps", "N" },
    });
    defer vars.deinit();
    const rendered = try renderTemplate(testing.allocator, "weekly_status", "ja", vars);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "## Summary") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Project: X") != null);
}

test "escapeHtml encodes ampersand, lt, gt, quote, apostrophe" {
    const out = try escapeHtml(testing.allocator, "<script>\"&'");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("&lt;script&gt;&quot;&amp;&#x27;", out);
}

test "html format renders <h2>/<p> wrappers around escaped content" {
    var vars = try mapFromPairs(&.{
        .{ "project_name", "Test" },
        .{ "period", "W1" },
        .{ "completed", "Done" },
        .{ "in_progress", "WIP" },
        .{ "blocked", "None" },
        .{ "next_steps", "Next" },
    });
    defer vars.deinit();

    var tpl = weeklyStatusTemplate("en");
    tpl.format = .html;
    const rendered = try tpl.render(testing.allocator, vars);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "<h2>Summary</h2>") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "<p>Project: Test | Period: W1</p>") != null);
}
