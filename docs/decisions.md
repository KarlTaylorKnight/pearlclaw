# Decision log (ADRs)

Living record of design decisions. New entries at the bottom. Each entry
has: date, decision, rationale, status (accepted / superseded by #N / reverted).

---

## D1 — Repo layout: parallel `rust/` and `zig/` (not nested, not FFI-linked)

**Date:** 2026-04-29
**Decision:** Build the Zig version as a separate parallel binary. Rust binary
under `rust/` stays the reference implementation. No FFI bridge between
running Rust and Zig at the workspace boundary; tests may FFI in narrow
ways (passing JSON bytes through `extern "C"`) for parity.
**Why:** Crossing async runtimes (Tokio ↔ libxev) is a known footgun.
Zig 0.x ABI is not stable. Whole-binary benchmarks are the comparison the
user actually wants.
**Status:** accepted

---

## D2 — Rust toolchain: stable, not 1.87

**Date:** 2026-04-29
**Decision:** Use `rustup default stable` (1.95 at the time of this
decision) for the workspace build, not the 1.87 declared in
`rust/Cargo.toml`'s `rust-version`.
**Why:** The workspace's transitive dependencies require rustc ≥ 1.90
(`wasmtime-internal-*` crates) and ≥ 1.88 (`zip`). 1.87 will not link.
The project's declared MSRV refers to what zeroclaw itself publishes,
not what the current dep graph resolves on.
**Tradeoff:** Bench numbers are sensitive to compiler version. Cross-
language Zig vs Rust comparisons must record `rustc --version` so we can
spot drift across runs.
**Status:** accepted

---

## D3 — Zig pin: 0.14.1

**Date:** 2026-04-29
**Decision:** Pin Zig 0.14.1 for the duration of the pilot. Defer 0.15 /
master upgrade until after the parser + memory + dispatcher pilots land.
**Why:** Zig is pre-1.0; 0.14.x is the most recent stable line. libxev's
main branch tracks 0.14. mvzr supports 0.14. Allocating a dedicated
upgrade week per minor release is cheaper than chasing breakage during
active port work.
**Status:** accepted

---

## D4 — Regex: mvzr first, PCRE2 fallback

**Date:** 2026-04-29
**Decision:** Use `mvzr` (pure Zig regex) as the default. If audit shows
>10% of the parser's regex patterns need workarounds, escalate to PCRE2
via FFI for those specific patterns only.
**Why:** Pure-Zig keeps the dep graph clean. mvzr covers the common
PCRE subset. PCRE2 FFI escalation is well-understood and only needed for
patterns that mvzr can't express (lookaround, backrefs, complex Unicode).
**Status:** accepted — pending pattern audit at parser port time

---

## D5 — JSON: comptime helper, not a third-party serde-equivalent

**Date:** 2026-04-29
**Decision:** Build `zig/src/json_helpers.zig` (~150 LOC, one-time) using
`@typeInfo` to walk struct fields, parse from `std.json`, and emit
canonical JSON output. Reused across all ported crates.
**Why:** Zig has no `serde` derive. Hand-writing `parse`/`emit` for every
struct is mechanical but lossy; comptime metaprogramming gives us
struct-driven JSON without taking a third-party dep that may not survive
0.x churn.
**Status:** accepted

---

## D6 — SQLite: system libsqlite3 via @cImport, no Zig wrapper

**Date:** 2026-04-29
**Decision:** Link `linkSystemLibrary("sqlite3")` + `linkLibC()`. Use
`@cImport({ @cInclude("sqlite3.h"); })` directly. Wrap with thin Zig
functions (`open`, `prepare`, `step`, `bind_*`, `column_*`, `finalize`,
`exec`) where it pays for itself.
**Why:** macOS ships libsqlite3 in the SDK; no Homebrew install needed.
Third-party Zig SQLite wrappers add abstraction without earning their
keep at this scale, and add a 0.x-churn dep.
**Status:** accepted

---

## D7 — Pilot is sync-only; libxev enters at memory full port

**Date:** 2026-04-29
**Decision:** The pilot (parser + memory SQLite subset + dispatcher) uses
synchronous APIs only. The criterion benchmarks the pilot mirrors are
blocking, so async wrappers add no value. libxev is introduced when the
full memory port begins (postgres, qdrant, embeddings, async I/O) and
becomes load-bearing at provider port (HTTP).
**Status:** accepted

---

## D8 — LLM provider scope: Ollama + OpenAI (OAuth), drop the rest

**Date:** 2026-04-29
**Decision:** When the provider port begins, port only:
- `crates/zeroclaw-providers/src/ollama.rs` (52 KB)
- `crates/zeroclaw-providers/src/openai.rs` (35 KB)
- `auth/openai_oauth.rs` (14 KB) + `auth/oauth_common.rs` (6 KB)
- Trim `auth/mod.rs` (20 KB → ~10 KB) to OpenAI-relevant pieces.
- Trim `auth/profiles.rs` (24 KB → ~10 KB) to OpenAI-relevant pieces.

Drop entirely: `anthropic.rs`, `azure_openai.rs`, `bedrock.rs`,
`claude_code.rs`, `compatible.rs`, `copilot.rs`, `gemini.rs`,
`gemini_cli.rs`, `glm.rs`, `kilocli.rs`, `openai_codex.rs`,
`openrouter.rs`, `telnyx.rs`, `auth/anthropic_token.rs`,
`auth/gemini_oauth.rs`. Likely also `reliable.rs`; `router.rs` decision
deferred until read.

**Why:** User wants only local LLM (Ollama) + ChatGPT/OpenAI OAuth.
~770 KB removed from scope (10× smaller `zeroclaw-providers`).
**Status:** accepted

---

## D9 — Workforce: parallel Claude subagents + Codex as worker

**Date:** 2026-04-29
**Decision:** Use Claude subagents in parallel (3 at a time, single
message) for independent port targets. Use Codex via `/codex:rescue` as a
primary worker for chunks >800 LOC or files >50 KB. Claude reviews
Codex; Codex reviews Claude.
**Audit trail:** every port chunk records in `docs/porting-notes.md`:
which engine wrote first pass, which engine reviewed, what disagreement
arose, what the resolution was.
**Status:** accepted

---

## D10 — Memory ownership: caller-owns at API boundaries; arenas internally

**Date:** 2026-04-29 (TBC at first port)
**Decision:** Public Zig APIs take an `std.mem.Allocator` parameter and
return owned memory; the caller is responsible for freeing. Provide an
arena-allocator helper for batch-free patterns (typical agent loop:
parse, dispatch, free everything at end of turn).
**Why:** Matches Zig idiom; explicit; benchmark-friendly (the caller
controls the allocator). Internal hot paths use arena allocators where
short-lived allocations dominate.
**Status:** tentative — finalize during parser port

---

## D11 — Channel scope: orchestrator + cli + utilities only for pilot

**Date:** 2026-04-30
**Decision:** Apply the same shrinking logic to `zeroclaw-channels` that D8
applied to `zeroclaw-providers`, but preserve the feature-gate mechanism
on the Zig side via `build.zig` build options.

**In scope for the Zig pilot (always compiled):**
- `orchestrator/` (479 KB / 12,248 lines — see correction below)
- `util.rs`
- `cli` channel
- `link_enricher.rs`, `transcription.rs`, `tts.rs`

**On-demand after pilot (port one at a time when actually needed, in this priority order):**
- `discord` (91 KB) — most-requested for agent runtimes
- `slack` (190 KB)
- `telegram` (211 KB)

**Drop initially (revisit only if user need surfaces):** nostr, bluesky, voice_call, voice_wake, whatsapp_web, whatsapp_storage, mochat, dingtalk, qq, wechat, wecom, lark, line, irc, imessage, mattermost, signal, notion, twitter, reddit, linq, wati, nextcloud_talk, email_channel, gmail_push, clawdtalk, webhook, acp_server.

This drops ~26 channels totalling ~1.7 MB of source. The pilot Zig channels
crate is roughly **600 KB in scope** vs the 2.4 MB Rust crate (~75% reduction).

**Correction to plan:** the plan called `loop_.rs` (282 KB) "the actual
project." That's wrong — `orchestrator/mod.rs` at 479 KB is significantly
larger and equally load-bearing. Both warrant Codex first-pass per D9, with
multi-pass refinement along function boundaries. Treat orchestrator port as
its own multi-PR effort, scheduled at the same priority as `loop_.rs` (Week 11+ in the
crate-ordering table).

**Why:** Channels are already opt-in via Cargo features (unlike LLM
providers which were always-compiled). The Zig port can mirror this via
`build.zig` options; users enable channels they need. Keeps the pilot
binary lean, defers heavy work that doesn't gate eval/bench parity.
**Status:** accepted
