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

---

## D12 — Memory determinism: normalize timestamps + UUIDs in the eval driver, defer trait refactor

**Date:** 2026-04-30
**Decision:** The Rust `Memory` trait impls hardcode `chrono::Local::now().to_rfc3339()`
and `Uuid::new_v4()` inside `store`/`store_with_metadata` (sqlite.rs:286,
585, 587, 1113, 1115; audit.rs:87, 100). For pilot fixture parity, the
eval driver normalizes these incidental fields **after** capturing both
sides' output, before byte-diff:

- `id` field: replace any UUID v4 (`/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/`) → `"<UUID>"`.
- Any `*_at` / `timestamp` field at any nesting level: replace any RFC3339 string → `"<TS>"`.
- Order of array elements is preserved (recall ranking is the actual signal under test).

The cleaner trait refactor (`Clock + IdGen` injected at construction) is
deferred — it would touch `zeroclaw-api`, every `Memory` impl, every
constructor, and the pilot doesn't need it.

**Why:** R9 mitigation in the plan said "refactor Rust ... before
porting if it doesn't already" but didn't specify cost. The trait
refactor is a multi-crate change to the *reference* implementation,
which violates D1's "Rust is reference, port doesn't change it" spirit.
Normalization in the eval driver achieves the same parity goal with no
upstream churn.

**Tradeoff:** Eval driver carries memory-specific normalization logic
that the parser eval driver does not. Acceptable — memory is the only
pilot subsystem with a wall-clock dependency.

**Implication for `Memory.export()` ordering:** the trait says "Returns
entries ordered by creation time (ascending)." With normalized
timestamps that ordering is **only verifiable structurally** (insertion
order via id sort or row order), not by comparing timestamp strings.
Eval-memory captures `created_at` *before* normalization for the
ordering assertion, then strips it for the diff.

**Status:** accepted

---

## D13 — Memory schema versioning: introspection migrations, not `PRAGMA user_version`

**Date:** 2026-04-30
**Decision:** The Zig SQLite memory port matches the Rust pattern:
schema migrations are guarded by `sqlite_master` SQL introspection (e.g.
`SELECT sql FROM sqlite_master WHERE name='memories'` then
`!schema_sql.contains("session_id")` → `ALTER TABLE`). Do not introduce
`PRAGMA user_version`.

**Erratum to plan:** Plan §"Pilot port: memory" said "PRAGMA
`user_version` numbers preserved so Zig and Rust can read each other's
databases." That was wrong — the Rust crate has no `user_version`
anywhere. The reference pattern is column-introspection migrations
(sqlite.rs:206-234, four ALTER blocks for `session_id`, `namespace`,
`importance`, `superseded_by`).

**Why:** Matching the reference exactly is the cheapest path to
cross-readable databases. Introducing `user_version` only on the Zig
side would mean Rust-written DBs open by Zig at user_version=0,
triggering a no-op re-migration that's cosmetic noise. Introducing it
on both sides means changing the Rust reference (violates D1).

**Tradeoff:** introspection-driven migrations don't scale beyond ~10
columns before the cumulative `IF NOT EXISTS` checks become a smell.
The Rust crate is already at 4 ALTERs; if it gets to 10+, both sides
should adopt `user_version` together. Tracked as a future revisit, not
a pilot blocker.

**Status:** accepted

---

## D14 — SQLite version: vendor amalgamation in Zig, drop "bundled" from rusqlite

**Date:** 2026-04-30
**Decision:** Pin a single SQLite C source for both sides:

1. Vendor `sqlite-amalgamation-VERSION/sqlite3.{c,h}` under
   `zig/vendor/sqlite3/`. Build it as a static library in `build.zig`
   with `linkLibC()`.
2. Modify `rust/crates/zeroclaw-memory/Cargo.toml`:
   `rusqlite = { version = "0.37", features = [] }` (drop "bundled"),
   then add `[dependencies] libsqlite3-sys = { version = "0.30", features = ["bundled"] }`
   pointing at the same amalgamation version.

Both sides use the **same pinned SQLite C source**. The exact version
gets recorded in `zig/vendor/sqlite3/VERSION` and a matching pin appears
in `Cargo.lock`.

This **supersedes the relevant clause of D6** ("link `linkSystemLibrary("sqlite3")`").
D6 stays in effect for the *interface* (direct `@cImport`, no Zig
wrapper crate) — only the linking strategy changes.

**Why:** macOS system sqlite on the dev host is 3.43.2; rusqlite's
"bundled" feature ships ~3.46+. FTS5 BM25 ranking and tokenizer
behavior can differ between versions enough to break byte-equal recall
ordering. Pinning eliminates this as a parity risk and removes a
host-environment dependency from CI.

**Tradeoff:** ~9 MB of vendored C source in the repo (single file,
amalgamated, doesn't churn). Build time goes up by a few seconds for
first-build warm cache misses. Worth it for parity guarantees.

**Acceptance check:** record `sqlite_version()` in both Rust and Zig
bench output JSON; CI fails if they don't match.

**Status:** accepted, supersedes D6 linking clause

---

## D15 — Audit decorator (`audit.rs`) deferred from pilot scope

**Date:** 2026-04-30
**Decision:** The pilot Zig memory port does not include `AuditedMemory`
(rust/crates/zeroclaw-memory/src/audit.rs, 293 lines). It will be ported
post-pilot when audit becomes load-bearing for compliance work.

**Why:** Audit is a decorator pattern wrapping any `Memory` impl,
writes to a separate `audit.db`, and is not exercised by the three
criterion bench IDs the pilot must hit (`memory_store_single`,
`memory_recall_top10`, `memory_count`). Porting it now is ~9 KB of work
that doesn't move the acceptance gates.

**Implication:** `eval-memory` operates against an unaudited
`SqliteMemory` directly. When audit ports later, add a scenario op
`{"op":"open_audited","path":"...","audit_path":"..."}` and an
`audit_count` op to the eval contract; existing scenarios continue to
work.

**Status:** accepted

---

## D16 — Memory pilot calls `SqliteMemory.new` directly; no factory port

**Date:** 2026-04-30
**Decision:** The pilot does not port the `create_memory` /
`create_memory_with_storage` / `create_memory_with_storage_and_routes`
factory tree from `lib.rs:295-463`. Eval and bench binaries on both
sides instantiate `SqliteMemory` directly via its constructor.

**Why:** The factory exists to dispatch on a backend-name string
(`"sqlite"`, `"postgres"`, `"markdown"`, `"lucid"`, `"none"`); the pilot
only has SQLite. Porting the factory means also porting (or stubbing)
`backend.rs` plus the `resolve_embedding_config` provider-routing
machinery — neither of which is exercised by the bench IDs.

**Implication:**
- `backend.rs` (185 lines, F9) deferred along with the factory.
- `lib.rs` port reduces to the four pure helpers used elsewhere:
  `is_assistant_autosave_key`, `is_user_autosave_key`,
  `should_skip_autosave_content`, and possibly nothing else for the
  pilot. Move these to `zig/src/memory/autosave.zig` if needed; skip
  entirely if no caller in pilot scope references them.

When the runtime port begins (Week 11+) and needs the factory for
config-driven backend selection, port it then with all the postgres /
markdown / lucid backend stubs returning "not yet ported" errors, same
shape as `purge_namespace`'s default.

**Status:** accepted

---

## D17 — Memory tool surface: formalize Rust-production vs. Zig+eval divergence as canonical pilot scope

**Date:** 2026-05-11
**Decision:** Accept the existing divergence as canonical for the pilot
phase. Production Rust memory tools
(`rust/crates/zeroclaw-tools/src/memory_{store,recall,forget,purge,export}.rs`)
keep the older `key` / `content` / `category` surface. The Zig port
(`zig/src/agent_tools/memory_*.zig`) and both eval runners
(Rust `eval-memory-tools.rs` and Zig `eval_memory_tools.zig`) keep the newer
content-addressed surface with `tags` / `source` / `importance` / `format`.
**The eval contract is byte-parity between the two runners — it is not parity
against the production Rust tools.** Defer alignment until a concrete
production-runtime need arises.

**The divergence (concrete, as of 2026-05-11):**

Rust `MemoryStoreTool.parameters_schema` (`memory_store.rs:31-50`):
`{ "properties": { key, content, category }, "required": ["key","content"] }`.

Zig `MemoryStoreTool.parametersSchema` (`memory_store.zig:14-29`) and both
eval runners:
`{ "properties": { category, content, importance, source, tags }, "required": ["content","category"] }`.

Differences:
1. **Identification model.** Rust uses caller-supplied `key`; Zig+eval is
   content-addressed (SHA-256(content)[..8] hash, lowercase 16-char hex).
2. **Metadata fields.** Zig+eval has `tags` / `source` / `importance`; Rust
   has none.
3. **Backing storage.** Zig SqliteMemory has a `memory_tool_metadata` side
   table (Phase 7-B); Rust SqliteMemory does not. Tags and source have no
   place to live on the Rust side without a backend migration.
4. **Required fields.** Differ in list and semantics.
5. **Return value text.** Rust: `"Stored memory: {key}"`. Zig:
   `"Stored memory {hash} in category {category}"`.

Equivalent deltas exist in `memory_recall`, `memory_forget`, `memory_purge`,
`memory_export`. See Phase 7-B SF-3 framing in
`docs/porting-notes.md:1812-1820`.

**Why this and not "port newer surface back to Rust now":**

D1 frames Rust as the reference implementation and the Zig binary as the
port. Rewriting production Rust to match the port surface inverts that
framing — it makes the port the reference and the existing Rust the
port-of-the-port. That inversion is reasonable when the pilot concludes and
the Zig port becomes canonical, but it is not the pilot's job.

The eval contract is already the parity surface — every memory_tools fixture
validates Rust↔Zig byte-equality on the newer surface (18/18 green at
commit `8c6d53e`). The in-tree Rust production tests (1119 passing) validate
the older surface against the older SqliteMemory backend. Both pass today.
No fixture or test is broken by accepting the divergence; only documentation
is unclear.

**Tradeoff:**

Production memory tools will not exercise the LLM-facing JSON schema features
(tags, source, importance). If a future LLM agent flow on the Rust runtime
side assumes those fields are honored by `MemoryStoreTool`, that assumption
will break against the current production tools.

**Trigger conditions for revisiting (flip to Option A — port newer surface
back into Rust production tools):**

Adopt Option A when **any** of these become true. These are advisory — no CI
gate enforces them in this commit; the ADR is the contract.

1. Production runtime code (outside `eval-*` binaries) calls
   `MemoryStoreTool::execute` with a `tags` / `source` / `importance`
   field. Detection: grep production Rust callers for these field names.
2. `cargo test -p zeroclaw-tools` is expected to certify the LLM-facing
   schema as a release gate.
3. The pilot concludes per the project plan and the Zig port becomes the
   canonical implementation. At that point Rust is the port-of-the-port and
   naturally aligns to the Zig surface.

**Related:**
- D1 (parallel binaries, Rust = reference)
- D9 (workforce + porting-notes audit trail)
- Phase 7-B SF-3 framing in `docs/porting-notes.md:1812-1820` (this ADR
  resolves that pending item)

**Status:** accepted

---

## D18 — CLI-discovery eval fixtures own Unix stub scripts and PATH overrides

**Date:** 2026-05-12
**Decision:** Eval fixtures that need deterministic CLI discovery may use
runner-owned `setup.shell_scripts` plus `input.path_override`. Each runner
creates parent directories, writes the script bytes, chmods them `0755`, and
sets `PATH` for the call under test. This convention is Unix-only: shebang
scripts are the fixture format, and Windows `.bat` handling is deferred.

For `cli_discovery`, fixtures that isolate `PATH` to a synthetic bin directory
also provide a stub `which` script. The canonical Rust source resolves tools
by spawning `which`, so without the stub an isolated PATH cannot discover the
stub CLIs. The Zig port deliberately uses a pure PATH walk in
`process_common.findExecutableOnPath`, but the fixtures keep Rust and Zig
byte-parity by making the Rust resolver deterministic too.

The eval driver adds an opt-in `strip_tmp_paths` normalization flag for
subsystems whose outputs intentionally expose absolute temp paths as result
data. `cli_discovery` uses it so committed goldens can write `$TMP/bin/git`;
existing `strip_tmp_ids` behavior remains unchanged for older subsystems.

**Why:** Host PATH contents are not stable enough for discovery fixtures.
Stub scripts make version output, executable presence, and multi-argument
commands deterministic without changing production constructors or adding
fixture-only hooks to the library code.

**Tradeoff:** The convention is POSIX-only and assumes executable bits are
honored by the filesystem. That matches the current pilot fixture scope and
the earlier Unix symlink convention; Windows parity remains a future decision.

**Status:** accepted
