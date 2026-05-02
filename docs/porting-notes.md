# Porting notes

Running log of gotchas, surprises, and per-crate progress. Append-only.

---

## 2026-04-29 — bootstrapping

- Rust toolchain: switched default from 1.87 → stable (1.95) because
  workspace transitive deps require ≥ 1.90 (`wasmtime-internal-*`) and
  ≥ 1.88 (`zip`). See `docs/decisions.md` D2.
- Zig 0.14.1 installed via `zigup`; `zig` symlink at `/usr/local/bin/zig`.
- Codex verified: `codex-cli 0.125.0`, authenticated.
- Parser at-a-glance: `zeroclaw-tool-call-parser/src/lib.rs` is 2,773
  lines / ~99 KB. Of that, **1,505 lines are parser code** (~50 KB) and
  **1,267 lines are tests** (102 `#[test]` functions). The "monolith" is
  smaller than it looks once tests are subtracted.
- Public surface of the parser:
  - `pub struct ParsedToolCall { name, arguments, tool_call_id }`
  - `pub fn parse_tool_calls(response: &str) -> (String, Vec<ParsedToolCall>)` (line 995, main entry)
  - `pub fn canonicalize_json_for_tool_signature(value)` (line 46)
  - `pub fn strip_think_tags(s)` (line 1390)
  - `pub fn strip_tool_result_blocks(text)` (line 1412)
  - `pub fn detect_tool_call_parse_issue(...)` (line 1433)
  - `pub fn build_native_assistant_history_from_parsed_calls(...)` (line 1469)
- Internal section map (private fns), planned Zig module split:
  - `types.zig`: `ParsedToolCall`, error enums
  - `json.zig`: `parse_arguments_value`, `parse_tool_call_id`, `parse_tool_call_value`, `parse_tool_calls_from_json_value`, `extract_first_json_value_with_end`, `extract_json_values`, `find_json_end`, `canonicalize_json_for_tool_signature`
  - `xml.zig`: `is_xml_meta_tag`, `extract_xml_pairs`, `parse_xml_tool_calls`, `parse_xml_attribute_tool_calls`, `find_first_tag`, `strip_leading_close_tags`
  - `minimax.zig`: `parse_minimax_invoke_calls`
  - `perl.zig`: `parse_perl_style_tool_calls`, `parse_function_call_tool_calls`
  - `glm.zig`: `parse_glm_style_tool_calls`, `parse_glm_shortened_body`, `default_param_for_tool`, `map_tool_name_alias`, `build_curl_command`
  - `cleanup.zig`: `strip_think_tags`, `strip_tool_result_blocks`
  - `entry.zig`: `parse_tool_calls`, `detect_tool_call_parse_issue`, `build_native_assistant_history_from_parsed_calls`
- Test fixture extraction strategy: each `#[test]` has `let response = r#"..."#;` followed by `parse_tool_calls(response)` and assertions. Approach: extract just the input string literal; let `eval-tools/eval-parser` produce expected outputs by running the Rust parser on each input and serializing the result.

---

## 2026-04-30 — eval harness end-to-end + edge-case fixtures

- Rust baseline captured: `benches/results/baseline-rust-2026-04-30.json`. All 8 in-scope bench IDs match the source: `xml_parse_single_tool_call` / `xml_parse_multi_tool_call` (the plan called these `xml_parse_tool_calls` but criterion split them), `native_parse_tool_calls`, `memory_store_single`, `memory_recall_top10`, `memory_count`, `agent_turn_text_only`, `agent_turn_with_tool_call`. `benches/runner/run_rust.sh` updated to mirror the split + new agent_turn IDs.
- Auto-extracted parser corpus: 56 fixtures (numeric prefixes 001-035, 041-043, 047-048, 057-065, 068-071, 073-075). Gaps are tests whose input was constructed procedurally (no single `let response = r#"..."#;` literal — the Python extractor skips them). Acceptable for now; can backfill specific gaps if needed.
- Eval harness verified end-to-end: `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin --subsystem parser` runs all fixtures through both runners, the Rust runner produces real parser output, the Zig stub returns `{"calls":[],"text":""}`. 52 of 56 diverge as expected (the 4 that match are the ones whose Rust output is itself empty).
- Hand-curated 30 edge-case fixtures (numeric prefixes 100-129) covering: Unicode (emoji/CJK/RTL/zero-width/4-byte UTF-8), malformed XML, deeply nested JSON, 1 MB pre-text and 1 MB argument values, mixed formats, boundary cases, prompt-injection variants, type variations (null/array/OpenAI tool_call_id), whitespace (CRLF/tabs/BOM). Goldens captured via `--update-golden`.

### Pinned Rust parser quirks (Zig port MUST match exactly)

These behaviors were not obvious from the Rust source and are now pinned by edge-case fixtures. The Zig port has to reproduce them byte-for-byte to pass eval parity.

- **`<tool_call    >` (whitespace in tag delimiter) is NOT recognized.** Parser requires the exact `<tool_call>` open form. Whitespace inside the tag → entire input falls through to `text`. (fixture 106)
- **Multiple format precedence — XML wins.** When OpenAI JSON `{"tool_calls":[...]}` and `<tool_call>...</tool_call>` coexist, only XML is extracted; the OpenAI JSON stays in `text`. Same for ```` ```tool ```` GLM fences vs XML — XML wins. (fixtures 115, 116)
- **Literal `</tool_call>` inside an argument-string value breaks parsing.** The XML parser is not JSON-string-aware; the first `</tool_call>` ends the tag regardless. Result: 0 calls extracted, the JSON tail spills into `text`. (fixtures 117, 121)
- **`<tool_result>` block does NOT shield interior `<tool_call>` tags from extraction.** Both the inner and outer calls are extracted; only the `<tool_result>` literal tags themselves are stripped/preserved as text framing. Asymmetric vs `<think>`. (fixture 123)
- **`<think>` block DOES shield interior tool_calls** — they are dropped. (fixture 122)
- **Leading BOM (U+FEFF) is NOT stripped.** It is preserved in `text`. (fixture 129)
- **CRLF line endings are tolerated** — call still extracted. (fixture 127)
- **Missing closing `</tool_call>` is tolerated** — parser still extracts the call. (fixture 105)
- **Mismatched closing tag (`</tool>` instead of `</tool_call>`) is tolerated.** (fixture 108)
- **Empty body `<tool_call></tool_call>` produces zero calls (silent skip), not an error.** (fixture 120)
- **Output JSON keys are sorted alphabetically by `canonicalize_json_for_tool_signature`** at every nesting level — verified across all fixtures (e.g., fixture 101 reorders `src`/`lang` → `lang`/`src`).
- **Tab and multi-line indentation inside the inner JSON is tolerated** — parser is whitespace-tolerant. (fixture 128)
- **`null` and array values inside arguments are preserved as-is.** (fixtures 124, 125)
- **OpenAI `tool_call_id` is preserved** when present in the OpenAI-style top-level JSON. (fixture 126)

### Open question for Week 2 porter

Behaviors 4 and 5 (`</tool_call>` in arg, `<tool_result>` not shielding) look like genuine bugs in the Rust parser but are nonetheless its observable behavior. Per D14 risk register, eval fixtures may capture buggy Rust output as "expected." Options for the Zig port:

1. **Match exactly** (current default per acceptance gates) — Zig is byte-equal to Rust including bugs.
2. **Document divergence** — Zig fixes the bug, the fixture is marked `*.bug.input.txt` with a separate expected and the driver tolerates it. Adds infrastructure complexity.
3. **Fix in Rust first** — submit a PR upstream, regenerate goldens, port the fix.

Recommendation: option 1 for the pilot (just ship parity). Revisit after Week 3 when we know whether real Rust users hit these bugs.

---

## 2026-04-30 — channel scope decided (D11)

- `zeroclaw-channels/` is 2.4 MB across ~30 channels, all already feature-gated in `Cargo.toml`. This is structurally different from providers (D8) which were always-compiled.
- `orchestrator/mod.rs` is **479 KB / 12,248 lines** — the largest single file in the entire repo, larger than `loop_.rs` (282 KB) which the plan called "the actual project." Plan correction recorded in D11.
- Pilot channel scope: orchestrator + cli + util/link_enricher/transcription/tts only. Discord/Slack/Telegram in priority queue post-pilot. ~26 channels dropped initially.
- The `Channel` trait and `start_channels()` live in `orchestrator/mod.rs`. Internal-heavy file (only 1 top-level pub fn — `conversation_history_key`) so its surface is well-encapsulated; that's good news for porting since most of the contents will be private impls of the trait.
- Pilot budget for channels: defer entirely until Week 5+ per the post-pilot crate ordering. Pilot only needs CLI for end-to-end agent demo, and CLI doesn't depend on the orchestrator (it's always-compiled).

---

## 2026-05-01 — Week 2 Day 1: parser scaffolding + mvzr wired

- **mvzr 0.3.9 fetched** (`zig fetch --save`). Note: upstream default branch is `trunk`, not `main` — the plan and earlier instructions were wrong about the URL. Pinned hash recorded in `zig/build.zig.zon`. `libxev` still deferred per D7.
- **build.zig** wires `mvzr` into the core `zeroclaw_mod` so any file under `zig/src/` can `@import("mvzr")`.
- **zig/src/root.zig** replaced — was the default `add(a,b)` template from `zig init`. Now re-exports `tool_call_parser`. Other pilot subsystem re-exports land as their ports reach green.
- **Build verified:** `zig build`, `zig build test`, eval-parser stub roundtrip, eval driver end-to-end (79 of 86 fixtures diverge as expected — the 7 passing are inputs whose Rust output is itself empty, so the empty-stub matches).
- **Parser outline pinned:** `docs/parser-pilot/rust-outline.txt` captures every top-level `pub fn`/`fn`/`struct` in the 2,773-line monolith with line numbers. Confirms the planned module split:
  - `types.zig` (line 16): `ParsedToolCall`
  - `json.zig` (lines 22-141): `parse_arguments_value`, `parse_tool_call_id`, `parse_tool_call_value`, `parse_tool_calls_from_json_value`, `extract_first_json_value_with_end`, `extract_json_values`, `find_json_end`, `canonicalize_json_for_tool_signature`
  - `xml.zig` (lines 144-261, 511-571): `is_xml_meta_tag`, `extract_xml_pairs`, `parse_xml_tool_calls`, `parse_xml_attribute_tool_calls`, `find_first_tag`, `strip_leading_close_tags`
  - `minimax.zig` (lines 263-376): `parse_minimax_invoke_calls`
  - `perl.zig` (lines 572-697): `parse_perl_style_tool_calls`, `parse_function_call_tool_calls`
  - `glm.zig` (lines 698-993): `map_tool_name_alias`, `build_curl_command`, `parse_glm_style_tool_calls`, `default_param_for_tool`, `parse_glm_shortened_body`
  - `cleanup.zig` (lines 1390-1431): `strip_think_tags`, `strip_tool_result_blocks`
  - `entry.zig` (lines 995-1505): `parse_tool_calls`, `detect_tool_call_parse_issue`, `build_native_assistant_history_from_parsed_calls`
- **Of 2,773 total lines, ~1,505 are parser code and ~1,267 are tests.** The "99 KB monolith" is closer to ~50 KB of actual implementation once the test block is subtracted; still over the 50 KB / 800 LOC threshold for Codex first-pass per D9.

---

## 2026-05-01 — parser first-pass Zig implementation

- Codex first-pass landed the parser split under `zig/src/tool_call_parser/`: `types.zig`, `json.zig`, `xml.zig`, `minimax.zig`, `perl.zig`, `glm.zig`, `cleanup.zig`, and `entry.zig`. Public API is caller-owned via `parseToolCalls(allocator, response) -> ParseResult`, and `eval_parser.zig` now emits canonical sorted-key JSON directly from the Zig parser.
- Non-obvious parity choices intentionally match Rust/eval fixtures: exact `<tool_call>` delimiter matching (no `<tool_call    >`), XML precedence over OpenAI/GLM mixed formats, `</tool_call>` inside JSON strings ending the XML tag early, `<think>` shielding tool calls, `<tool_result>` not shielding tool calls, and leading BOM preservation.
- `std.json.Value` is the internal argument representation. Values crossing API boundaries are deep-cloned into caller-owned memory and recursively freed by `ParsedToolCall.deinit` / `ParseResult.deinit`; short-lived parse trees still use `std.json.parseFromSlice` arenas internally.
- `mvzr` is used where its whole-match API fits (`xml.zig` open-tag discovery). `MVZR_GAP` fallbacks were left for capture-heavy/dotall/lazy Rust patterns:
  - `cleanup.zig`: strip `<tool_result>`, `<thinking>`, `<think>`, `[Tool results]`, and excess blank lines with direct scans.
  - `minimax.zig`: attributed `<invoke>` / `<parameter>` captures with dotall/case-insensitive flags.
  - `xml.zig`: XML attribute-style `<invoke name="...">` and `<parameter name="...">` captures.
  - `perl.zig`: Perl/hash-ref `TOOL_CALL` and `<FunctionCall>` capture patterns.
  - `entry.zig`: markdown `tool_call`/`invoke` fences and named ```` ```tool <name> ```` fences.
- No `TODO(claude-refine)` comments were left because the current parser fixture suite is green.
- Verification: `cd zig && zig build`; `cd zig && zig build test`; `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin --subsystem parser` (86/86 parser fixtures OK).

---

## 2026-04-30 — parser error-path hardening

- Fixed the OpenAI JSON dispatch ownership transfer in `zig/src/tool_call_parser/entry.zig:39-47` using `transferCallSlice` / `appendOwnedCall` helpers at `entry.zig:362-404`; the same transfer path now covers JSON recovery, markdown, XML-attribute, Perl, FunctionCall, and GLM fallback branches (`entry.zig:83-229`, `entry.zig:329-355`, `entry.zig:459-530`).
- Removed the double `ArrayList.deinit` risk from `buildCurlCommand` by keeping only one `defer escaped.deinit()` in `zig/src/tool_call_parser/glm.zig:38-47`.
- Reworked OOM-sensitive append sites to move owned names/arguments only after successful append: GLM fallback (`entry.zig:214-218`), XML (`xml.zig:144`, `xml.zig:208-212`), MiniMax (`minimax.zig:50-107`, `minimax.zig:191-209`), Perl/FunctionCall (`perl.zig:37-48`, `perl.zig:84-105`, `perl.zig:215-233`), and GLM line parsing (`glm.zig:75-83`, `glm.zig:210-227`). `json.zig:97-119` and `json.zig:157-170` got the same treatment for owned parsed calls/values.
- Fixed `args_string` ownership in native assistant history construction with a moved flag around `types.putOwned` at `entry.zig:302-309`.
- Fixed ordered block removal so close markers are searched only after their matching open marker, and multiple blocks are handled, at `entry.zig:582-619`.
- Added `errdefer allocator.free(text)` before `calls.toOwnedSlice()` in `finish` at `entry.zig:553-555`.
- Changed canonical JSON emission to take the caller allocator instead of `std.heap.page_allocator` at `json.zig:234-265`; JSON value-end scanning now uses the caller allocator too (`json.zig:124-188`, `json.zig:272-295`). Re-exported the writer at `root.zig:19`, and switched `eval_parser.zig:29-34` to call the public parser surface.
- Minor cleanup: `stripToolResultBlocks` no longer double-trims and no longer truncates unmatched tags (`cleanup.zig:45-48`, `cleanup.zig:70-97`); MiniMax wrapper stripping is now one pass (`minimax.zig:118-123`, `minimax.zig:159-188`).
- Verification: `cd zig && zig build`; `cd zig && zig build test`; `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin --subsystem parser` (86/86 parser fixtures OK).

---

## 2026-05-01 — sqlite.rs first-pass (Codex)

- Ported the pilot SQLite backend to `zig/src/memory/sqlite.zig` with caller-owned `MemoryEntry`/`MemoryCategory` types in `zig/src/memory/types.zig`. Implemented `SqliteMemory.new`/`newNamed`, `store`, `storeWithMetadata`, `recall`, `recallNamespaced`, `get`, `list`, `forget`, `purgeNamespace`, `purgeSession`, `count`, `healthCheck`, `exportEntries`, `contentHash`, and the noop-embedding path by storing `NULL` embeddings.
- Schema is copied from Rust and initialized through direct `@cImport("sqlite3.h")` calls. Migrations remain introspection-driven per D13: 4 guarded `ALTER TABLE` checks (`session_id`, `namespace`, `importance`, `superseded_by`), no `PRAGMA user_version`.
- Vendored SQLite 3.50.2 from `libsqlite3-sys-0.35.0` under `zig/vendor/sqlite3/` and wired `build.zig` to compile the amalgamation with FTS5 enabled. This satisfies the Zig half of D14; Rust still uses its `rusqlite` bundled build through the eval tool dependency graph.
- `mvzr` gaps: none for memory. The SQLite backend uses SQL/FTS5 plus hand-built query strings; no Rust regex behavior was ported in this chunk.
- Added `eval-memory` on both sides (`eval-tools/src/bin/eval-memory.rs`, `zig/src/tools/eval_memory.zig`) and extended `evals/driver/run_evals.py` with JSONL scenario support, per-runner temp path substitution, and D12 UUID/RFC3339 normalization.
- Added three memory scenarios: `scenario-basic`, `scenario-filters`, and `scenario-update`, with normalized goldens. Fixture pass rate: 3/3 memory scenarios OK; full registered eval suite is 86/86 parser fixtures + 3/3 memory scenarios OK.
- Wired Zig benchmark IDs `memory_store_single`, `memory_recall_top10`, and `memory_count` to the new backend in `zig/bench/agent_benchmarks.zig`. Smoke run succeeded via `zig build bench`.
- Open questions for review: FTS5 score parity depends on keeping the Rust/Zig SQLite amalgamation versions aligned; Zig mirrors Rust's `f64 -> f32 -> f64` BM25 score cast. Advanced embedding/vector/reindex paths remain intentionally out of pilot scope per D15/D16 prep notes.
- Verification: `cd zig && zig build`; `cd zig && zig build test`; `cargo build --manifest-path eval-tools/Cargo.toml --release`; `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin`; `cd zig && zig build bench`.

---

## 2026-05-02 — sqlite memory pilot review (Claude)

- Reviewed Codex's first-pass: `zig/src/memory/{root,types,sqlite}.zig`, `zig/src/tools/eval_memory.zig`, `eval-tools/src/bin/eval-memory.rs`, the `build.zig` amalgamation wiring, and the `evals/driver/run_evals.py` JSONL+normalize extension. All four gates re-run from the review session: `zig build`, `zig build test`, `cargo build --release`, eval driver — 86/86 parser + 3/3 memory OK.
- Schema (`zig/src/memory/sqlite.zig:415-456`) is byte-equal to `rust/crates/zeroclaw-memory/src/sqlite.rs:161-203` — tables, indexes, FTS5 virtual table, all three sync triggers, embedding_cache. The 4 introspection migrations at `sqlite.zig:459-482` correctly probe `sqlite_master` and `ALTER` only when the column is missing, matching Rust per D13. PRAGMAs at `sqlite.zig:68-74` match `rust/sqlite.rs:61-65`.
- Memory ownership (D10) is consistent: caller-owned `MemoryEntry`, `deinit` covers all 9 owned slices including `category.custom`; `rowToEntry` uses an `errdefer` chain so partial-failure column extraction does not leak; `freeEntries` / `freeScoredSlice` mirror the parser pilot's `ParseResult.deinit` pattern.

### Pinned Rust SQLite memory parity quirks (Zig port MUST match exactly)

Same precedent as the parser quirks list — observable Rust behavior the Zig port has to reproduce, including apparent bugs.

- **`purge_namespace` deletes `WHERE category = ?1`, NOT `WHERE namespace = ?1`.** `rust/sqlite.rs:957-959` mirrored at `zig/src/memory/sqlite.zig:333-342`. The function name says namespace, the SQL says category — almost certainly an upstream Rust bug. `evals/fixtures/memory/scenario-update` exercises this path (`{"op":"purge_namespace","namespace":"daily"}` → `result: 1`); both sides delete the row whose category is `daily`. Preserve in the Zig port. Reconsider only if a Rust upstream fix lands.
- **BM25 scores round-trip through f32.** `zig/src/memory/sqlite.zig:562-563` narrows the SQLite f64 BM25 score to f32, then back to f64. Rust appears to do the same downcast — the eval-captured score `2.323144599358784e-06` is the exact f32-roundtrip value of the underlying f64. Documented here so future maintainers know it is intentional, not an idiom slip.
- **FTS5 errors degrade silently to empty results.** Rust's `Self::fts5_search(...).unwrap_or_default()` is mirrored by Zig's `catch blk: { break :blk allocator.alloc(ScoredId, 0) }` at `sqlite.zig:196-198`. Errors during MATCH parsing (e.g., unbalanced quotes) yield 0 keyword hits rather than failing the recall.
- **LIKE fallback runs only when FTS5 keyword hits == 0** (`sqlite.zig:227-229`). Matches Rust's merge-then-fallback shape; do not change to "always-fallback" or "fallback when < limit" without re-capturing fixtures.

### Open follow-ups (not blocking commit)

- **D14 is half-done.** `zig/vendor/sqlite3/VERSION` pins 3.50.2 (sourced from `libsqlite3-sys-0.35.0`); `rust/crates/zeroclaw-memory/Cargo.toml` still uses `rusqlite = { version = "0.37", features = ["bundled"] }` which ships its own amalgamation, version transitively determined. Today's FTS5 score parity is coincidence unless `cargo tree` confirms both sides resolve to the same SQLite C source. Drop the rusqlite "bundled" feature and add an explicit `libsqlite3-sys = { version = "=0.35.0", features = ["bundled"] }` dependency to lock both sides to 3.50.2. Verify by re-running the memory eval driver after the change — must remain 3/3 OK with no score drift on the in-scope fixtures.
- **eval-parser over-links sqlite3.c.** `zig/build.zig:18-27` attaches `sqlite3.c` to the shared `zeroclaw_mod`, so the eval-parser binary pays a 9 MB amalgamation link cost it does not use. Fix by splitting `zeroclaw_mod` into per-subsystem modules (parser_mod / memory_mod) when the dispatcher pilot lands and a third subsystem makes the split worthwhile.
- **Bench JSON schema is incomplete.** `zig/bench/agent_benchmarks.zig:56-60` emits `{lang, version, build_profile, benchmarks}` but the plan §"Common JSON schema" requires `host` and `timestamp` too. `compare.py` will need both before the comparison report can render. Add when wiring `compare.py` (Week 3 Day 4).
- **Bench methodology note.** `memoryStoreBody` (`agent_benchmarks.zig:201-211`) inserts into a growing table across 100 samples × N iters. Rust criterion likely has the same shape if it uses `iter`; reconcile when Rust criterion JSON is captured for the comparison report. If Rust uses `iter_batched` with per-batch DB reset, Zig should match.

### Nits (not actioned)

- `forget` does not take an allocator (`sqlite.zig:322`), unlike the rest of the API surface. Deliberate (no allocations) and acceptable.
- `eval_memory.zig` prints f64 score/importance via `{d}` (lines 270, 278). Eval driver round-trips through `json.loads` / `json.dumps` so trailing-zero or precision differences are normalized away; safe today.
- Zig opens connections with `SQLITE_OPEN_FULLMUTEX` (`sqlite.zig:55`) and also wraps writes in `std.Thread.Mutex`. Belt and braces; parity-safe.

- Verification (Claude side): `cd zig && zig build`; `cd zig && zig build test`; `cargo build --manifest-path eval-tools/Cargo.toml --release`; `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` (86/86 parser + 3/3 memory OK).

---

## 2026-05-02 — D14 Rust pin complete (Codex)

- Resolver baseline before any edit: `cargo tree --manifest-path rust/Cargo.toml -p zeroclaw-memory -e all` showed `rusqlite v0.37.0` resolving `libsqlite3-sys v0.35.0` through the `bundled` feature path.
- Resolver check after the D14 pass: unchanged, still `rusqlite v0.37.0` and `libsqlite3-sys v0.35.0`. This matches `zig/vendor/sqlite3/VERSION` (`3.50.2`), whose amalgamation was sourced from `libsqlite3-sys-0.35.0`.
- Exact diff to `rust/crates/zeroclaw-memory/Cargo.toml`: none. The task's step 2 applied: because `libsqlite3-sys` already resolved to `0.35.0`, the Rust side was already on the same SQLite C source as Zig and no manifest or `rust/Cargo.lock` churn was required.
- Eval-driver result: `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin --subsystem memory` passed all three memory scenarios (`scenario-basic`, `scenario-filters`, `scenario-update`).
- FTS5 score parity remained unchanged against the checked-in goldens: `scenario-basic` stayed `2.323144599358784e-06`; `scenario-filters` stayed `1.9599108327383874e-06`.
- Verification: `cargo build --manifest-path rust/Cargo.toml -p zeroclaw-memory --release`; `cargo build --manifest-path eval-tools/Cargo.toml --release`; memory eval driver; `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-memory` (283 passed).
- Open question for Claude review: D14's historical text still says to drop `rusqlite`'s `bundled` feature and add a direct `libsqlite3-sys` pin, but the current lock already pins the desired `0.35.0` source. Decide whether the ADR should be amended to bless "lockfile-resolved `libsqlite3-sys-0.35.0`" as sufficient, or whether a future cleanup should still add an explicit direct dependency purely for manifest-level clarity.

---

## 2026-05-02 — dispatcher pilot (Claude direct port)

- Ported `rust/crates/zeroclaw-runtime/src/agent/dispatcher.rs` (443 lines, 16 KB) to `zig/src/runtime/agent/dispatcher.zig` directly (no Codex hand-off — under D9's >800 LOC / >50 KB threshold; plan §"Pilot port: dispatcher" said small enough for one Claude subagent, single-turn was faster).
- Vtable-struct over tagged union per the plan: `ToolDispatcher.VTable` exposes `parseResponse`, `formatResults`, `shouldSendToolSpecs`. `XmlToolDispatcher` and `NativeToolDispatcher` each provide `pub fn dispatcher(self: *Self) ToolDispatcher`. Reuses `tool_call_parser.types.{ParsedToolCall, ParseResult, cloneJsonValue, freeJsonValue, parseJsonValueOwned, emptyObject}` — single source of truth for the parsed-call type and JSON ownership helpers since the dispatcher's `ParsedToolCall` is structurally identical to the parser pilot's.
- Out of pilot scope per R11 / plan:
  - `prompt_instructions(&[Box<dyn Tool>])` — needs the out-of-scope `zeroclaw-runtime::tools` crate; not ported and not in the eval contract.
  - `to_provider_messages(history)` — only used by the agent loop port; not ported. The `ConversationMessage::AssistantToolCalls` variant is therefore deferred (only `Chat` + `ToolResults` are present in the Zig union).
- Eval contract under `evals/fixtures/dispatcher/scenario-{xml,native,edges}/`: JSONL ops `{op, dispatcher, ...}` covering `parse_response`, `format_results`, `should_send_tool_specs`. Both `eval-tools/src/bin/eval-dispatcher.rs` (uses real `zeroclaw-runtime` + `zeroclaw-providers`) and `zig/src/tools/eval_dispatcher.zig` emit canonical JSON with `ConversationMessage` serialized as `{"type":"<variant>","data":<inner>}` matching the Rust serde tag/content shape on `zeroclaw-api::provider::ConversationMessage`.

### Pinned Rust dispatcher quirks (Zig port MUST match exactly)

Same precedent as the parser/memory quirks lists. All confirmed by fixture goldens captured from the Rust runner.

- **Unmatched `<tool_call>` open duplicates the leading text.** When the parser hits `<tool_call>` with no matching `</tool_call>`, the loop pushes `before.trim()` to `text_parts` and breaks WITHOUT advancing `remaining`. The trailing-text handler then pushes the whole `remaining` (which still contains `before` + the unmatched `<tool_call>...`) again. Result: text contains the prefix twice and the literal `<tool_call>` body. Captured by `scenario-edges` line 4: input `"prefix\n<tool_call>{\"name\":\"a\",\"arguments\":{}}\nnever closes"` → output text `"prefix\nprefix\n<tool_call>{\"name\":\"a\",\"arguments\":{}}\nnever closes"`. Probable Rust upstream bug; preserved for parity.
- **Unmatched `<think>` discards the rest** (`dispatcher.rs:96-97`). `strip_think_tags` breaks on missing `</think>` without re-adding the unmatched portion. Captured by `scenario-edges` line 3: input `"prefix <think>unclosed thinking that never ends"` → output text `"prefix"`.
- **Empty `name` after JSON parse causes silent skip** (`dispatcher.rs:56-59`). `scenario-edges` line 1: `<tool_call>{"name":"","arguments":{}}</tool_call>` → 0 calls, empty text.
- **Malformed JSON inside `<tool_call>` causes silent skip** (`dispatcher.rs:70-72` — `tracing::warn!` only). `scenario-edges` line 2: `<tool_call>this is not json at all</tool_call>` → 0 calls, empty text.
- **Native dispatcher: malformed `arguments` JSON defaults to `{}`** (`dispatcher.rs:181-188` — `tracing::warn!` + `Value::Object::new()`). `scenario-native` line 3: `arguments: "this is not json"` → call kept with `arguments: {}`.
- **Native `format_results` substitutes `"unknown"` for `None` `tool_call_id`** (`dispatcher.rs:199-204`). `scenario-native` line 5: input `tool_call_id: null` → output `tool_call_id: "unknown"`.
- **XML `format_results` always emits `[Tool results]\n<tool_result name="..." status="ok|error">\n<output>\n</tool_result>\n` per result** (the trailing `\n` per result comes from `writeln!` on each iteration; `dispatcher.rs:120-127`). Captured by `scenario-xml` lines 4–5.

### Open follow-ups (not blocking commit)

- **Bench IDs `agent_turn_text_only` / `agent_turn_with_tool_call` not yet ported.** Per `benches/runner/run_rust.sh`, the Rust criterion suite has these two dispatcher-using benches (`rust/benches/agent_benchmarks.rs:282-303` — `bench_agent_turn`). The Zig side has the bench infrastructure (`zig/bench/agent_benchmarks.zig`) but not these specific bench bodies — they exercise the full `Agent` + `AgentBuilder` which is post-pilot runtime/loop_ work. Defer to that port.
- **`to_provider_messages` and `prompt_instructions` deferred per R11.** When the agent loop port begins, both methods need ports plus the `ConversationMessage::AssistantToolCalls` variant. Eval contract should grow a `to_provider_messages` op at that time.
- **`eval-tools/Cargo.lock` grew to absorb the full `zeroclaw-runtime` + `zeroclaw-providers` dep tree.** First build is slow (multiple minutes); subsequent incremental builds are fast.

- Verification (this session): `cd zig && zig build`; `cd zig && zig build test`; `cargo build --manifest-path eval-tools/Cargo.toml --release --bin eval-dispatcher`; `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` (86 parser + 3 memory + 3 dispatcher = 92/92 fixtures OK).

---

## 2026-05-02 — Day 4: Zig benches + first comparison report (Claude direct)

- Added the 3 parser benches to `zig/bench/agent_benchmarks.zig` (`xml_parse_single_tool_call`, `xml_parse_multi_tool_call`, `native_parse_tool_calls`) with inputs byte-equal to the Rust criterion sources at `rust/benches/agent_benchmarks.rs:152-216`. The 3 memory benches were already wired from Week 3 Day 1. `agent_turn_*` deferred per the dispatcher porting-notes.
- Added `benches/runner/run_zig.sh` mirroring `run_rust.sh`: builds + runs `zig build bench -Doptimize=ReleaseFast`, then enriches the bare `{lang, version, build_profile, benchmarks}` JSON with `{host: {os, arch, cpu}, timestamp}` via `jq`. Both sides now emit the same common schema.
- Fixed `benches/runner/compare.py` `pilot_5` → `pilot_set` constant: the plan's "5 of 5" rule was authored before criterion split `xml_parse_tool_calls` into `single`/`multi`, which left the pilot acceptance gate matching zero benches. The set is now the 6 IDs that actually exist on both sides.
- Captured first Zig baseline at `benches/results/baseline-zig-2026-05-02.json` and rendered the first comparison report at `benches/results/reports/2026-05-02-comparison.md`.

### Performance gap discovered (gate 3 not yet met)

| Benchmark | Rust mean | Zig mean | Ratio | Verdict |
|---|---:|---:|---:|---|
| `xml_parse_single_tool_call` | 2.70 µs | 56.00 µs | 20.74x | MUCH SLOWER |
| `xml_parse_multi_tool_call` | 5.67 µs | 95.35 µs | 16.82x | MUCH SLOWER |
| `native_parse_tool_calls` | 1.46 µs | 202.70 µs | 139.12x | MUCH SLOWER |
| `memory_store_single` | 171.61 µs | 674.30 µs | 3.93x | MUCH SLOWER |
| `memory_recall_top10` | 296.55 µs | 1.90 ms | 6.39x | MUCH SLOWER |
| `memory_count` | 19.92 µs | 11.47 µs | 0.58x | faster |

Plan acceptance gate 3 (Zig within 2x on every bench AND faster on at least 3 of the pilot benches): currently **1/6 within-2x, 1/6 faster**. The pilot does not yet meet gate 3. Functional parity (gate 1) and test parity (gate 2) are met; CI (gate 4) is unwired.

### Hypothesized perf causes — investigations to launch in Week 4

- **Parser benches (16–139× slower):** every iteration calls `dispatcher.parseResponse(allocator, ...)` which (a) `std.json.parseFromSlice`-arenas the inner JSON, (b) deep-clones the parsed `arguments` value via `parser_types.cloneJsonValue`, then (c) `freeJsonValue`s the recursive structure on `result.deinit`. Two allocations per JSON value plus full traversal-on-free. Rust's `serde_json::Value` likely allocates once and uses cheaper traversal on drop. The 139× ratio on `native_parse_tool_calls` (which parses TWO `arguments` JSON values per iteration) is consistent with this hypothesis — the per-call overhead is amplified by the parse-count.
- **SQLite benches (4–7× slower):** every store/recall call goes through `prepare → bind → step → finalize`. Statement compilation is repeated per iteration. `rusqlite`'s `cached_statement` caches prepared statements; the Zig port has no cache. Adding a tiny LRU keyed by SQL string in `sqlite.zig` is the obvious fix.
- **`memory_count` (0.58× — Zig faster):** the only bench with no per-call allocation and a tiny prepared statement (`SELECT COUNT(*) FROM memories`). When allocation/preparation aren't dominant, Zig competes well — supporting the optimization hypotheses above.

### Open follow-ups (ordered by expected impact)

1. **Statement caching in `sqlite.zig`.** Small LRU keyed by SQL string; store `?*c.sqlite3_stmt`, use `sqlite3_reset` between calls instead of `sqlite3_finalize`. Expected impact: 2–4× speedup on memory_store/recall. Single-day Claude effort.
2. **Reduce JSON double-allocation in dispatcher / parser.** Replace the `parseFromSlice` + `cloneJsonValue` pattern with single-pass parsing that allocates directly into the caller allocator, or hand the caller the arena from `parseFromSlice`. Expected impact: 5–20× speedup on parser benches. Touches `tool_call_parser/types.zig` + the dispatcher's `parseXmlToolCalls`; Codex first-pass plus Claude review fits.
3. **Arena-per-bench-iteration in benches** (and eventually agent loop). The `GeneralPurposeAllocator`'s per-alloc metadata is overhead the bench will never benefit from; arena-per-turn matches the parser pilot's intent. Lower-effort win that may close part of the parser gap.
4. **Cross-check with `hyperfine`** on whole-binary timing once #1 + #2 land — confirms the in-process bench harness isn't itself biased.

### Day 5 recommended scope (unchanged)

Defer the perf-tuning sprint to Week 4. Day 5 keeps the planned scope: `.github/workflows/port-ci.yml` + first PR + provider port (Ollama) handoff. The comparison report being honest about the gap is the correct Day 4 outcome — gate 3 was always going to need a tuning pass after first-pass correctness was established.

- Verification: `cd zig && zig build`; `benches/runner/run_zig.sh > benches/results/baseline-zig-2026-05-02.json` (rebuilt fresh from this session); `python3 benches/runner/compare.py benches/results/baseline-rust-2026-04-30.json benches/results/baseline-zig-2026-05-02.json --out benches/results/reports/2026-05-02-comparison.md` (1/6 within-2x, 1/6 faster).
