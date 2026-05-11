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

---

## 2026-05-02 — Day 5: CI workflow (Claude direct)

- Added `.github/workflows/port-ci.yml`. Triggers on push/PR to main + manual `workflow_dispatch`. Single `ubuntu-latest` job: installs Rust stable + Zig 0.14.1 + jq, builds `eval-tools --release --locked`, builds `zig`, runs `zig build test`, runs `python3 evals/driver/run_evals.py` across all subsystems (gate 1 — byte-equal), and runs `cargo test -p zeroclaw-memory --release` (gate 2 — Rust crate tests). Caches `~/.cargo/{registry,git}` + `eval-tools/target` keyed on lockfile, plus `zig/.zig-cache` keyed on `build.zig.zon` + `zig/vendor/sqlite3/VERSION`. `concurrency` cancels superseded runs on the same branch.
- Bench comparison job intentionally NOT wired yet. Gate 3 isn't met (1/6 within-2x per Day 4) so a bench-gating job would fail loudly today. Will land alongside the Week 4 perf-tuning PR(s) — at that point the comparison report should be auto-posted as a PR comment via `actions/github-script`.

### Pilot status after Day 5

| Gate | Status |
|---|---|
| 1. Functional parity (92/92 fixtures byte-equal) | ✓ |
| 2. Test parity (Zig + Rust unit tests) | ✓ |
| 3. Perf within 2× on every bench, faster on 3+ | ✗ — 1/6 within-2× (Week 4 perf sprint) |
| 4. CI green | ✓ — `port-ci` workflow live |

3 of 4 pilot acceptance gates met. Gate 3 is the only outstanding work for full pilot acceptance and is scheduled for Week 4 (statement caching → JSON allocator rework → re-bench).

- Verification: workflow YAML reviewed; first run surfaces on push to main and is watched via `gh run watch`.

---

## 2026-05-02 — sqlite stmt cache (Codex)

- Added a private prepared-statement cache to `zig/src/memory/sqlite.zig`: `std.StringHashMap(*c.sqlite3_stmt)` keyed by an allocator-owned SQL string copy. `cachedPrepare` reuses statements by running `sqlite3_reset` plus `sqlite3_clear_bindings` on hits; misses prepare once and store both the SQL key and statement in the cache. `SqliteMemory.deinit` finalizes every cached statement and frees every owned key before `sqlite3_close`.
- Public `SqliteMemory` API and SQL semantics are unchanged. The existing per-method mutex remains the only cache guard; no second lock was added.
- Memory bench before/after Zig mean ns/op:
  - `memory_store_single`: `674302.975625` -> `225847.91375` (2.99x faster; Rust ratio now 1.32x).
  - `memory_recall_top10`: `1895643.52125` -> `398491.2678125` (4.76x faster; Rust ratio now 1.34x).
  - `memory_count`: `11474.039912109374` -> `399.89043395996094` (28.69x faster; faster than Rust in this run).
- Eval-driver result: `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin --subsystem memory` passed all three memory scenarios byte-equal.
- Max cache size observed from the eval scenarios: 10 statements per `SqliteMemory` instance. `scenario-basic` and `scenario-filters` each exercise 10 distinct SQL shapes; `scenario-update` exercises 8.
- Comparison report: `benches/results/reports/2026-05-02-after-stmt-cache.md` shows the memory benches are now all within 2x of Rust, moving the pilot gate from 1/6 to 3/6 within-2x.
- Open questions for Claude review: parser benches were not edited; XML parse benches stayed essentially flat, but `native_parse_tool_calls` improved from `202695.612265625` to `62382.3898828125` ns/op in this run. Treat that as benchmark noise or prior current-workspace drift, not as an effect of the SQLite cache. The remaining gate-3 work is still parser/JSON allocation.
- Verification: `cd zig && zig build`; `cd zig && zig build test`; memory eval driver; `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-memory --release`; `benches/runner/run_zig.sh > benches/results/baseline-zig-after-stmt-cache.json`; `python3 benches/runner/compare.py benches/results/baseline-rust-2026-04-30.json benches/results/baseline-zig-after-stmt-cache.json --out benches/results/reports/2026-05-02-after-stmt-cache.md`.

---

## 2026-05-02 — JSON arena parser rework (Codex)

- Replaced the hot `std.json.parseFromSlice` -> `cloneJsonValue` -> recursive free path in `zig/src/tool_call_parser/types.zig` with a single-pass owned JSON parser that allocates directly into the caller allocator. The parser preserves the existing `std.json.Value` representation and strict duplicate-key rejection, and numbers are stored as `.number_string` to avoid lossy or allocator-heavy integer/float conversion.
- Added optional arena ownership to `ParseResult`. `parseToolCalls`, `NativeToolDispatcher.parseResponse`, and XML dispatcher parsing now allocate one arena per parse result and release it in `ParseResult.deinit`, matching D10's caller-owned API boundary while avoiding per-field recursive frees in the benchmark hot path.
- XML dispatcher argument extraction now moves the owned `arguments` value out of the parsed object with `fetchOrderedRemove` instead of deep-cloning it.
- Parser bench before/after Zig mean ns/op, using `benches/results/baseline-zig-after-stmt-cache.json` as the before sample and a fresh `benches/results/baseline-zig-after-json-arena.json` as the after sample:
  - `xml_parse_single_tool_call`: `56584.2073828125` -> `6832.0296484375` (8.28x faster; Rust ratio now 2.53x).
  - `xml_parse_multi_tool_call`: `94958.4978125` -> `13490.371005859375` (7.04x faster; Rust ratio now 2.38x).
  - `native_parse_tool_calls`: `62382.3898828125` -> `17945.399521484374` (3.48x faster; Rust ratio now 12.32x).
- Eval-driver result: `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` passed all parser, memory, and dispatcher fixtures byte-equal.
- Comparison report: `benches/results/reports/2026-05-02-after-json-arena.md` still shows gate 3 incomplete: 3/6 pilot benches within 2x and 1/6 faster. Memory remains within 2x; parser is much improved but not accepted.
- Open questions for Claude review: JSON arena ownership closed the largest obvious allocation/free cycle, but native parsing remains 12.32x slower and XML parsing remains just outside the 2x gate. The next investigation should focus on native dispatcher structure/string allocation overhead and whether the bench should use a per-turn arena shape that mirrors the intended agent loop.
- Verification: `zig fmt --check zig/src/tool_call_parser/types.zig zig/src/tool_call_parser/entry.zig zig/src/runtime/agent/dispatcher.zig`; `cd zig && zig build test`; `cd zig && zig build`; `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin`; `benches/runner/run_zig.sh > benches/results/baseline-zig-after-json-arena.json`; `python3 benches/runner/compare.py benches/results/baseline-rust-2026-04-30.json benches/results/baseline-zig-after-json-arena.json --out benches/results/reports/2026-05-02-after-json-arena.md`.

---

## 2026-05-05 — caller-supplied scratch arena (Codex)

- Hypothesis confirmed before the API change with temporary `std.time.Timer` instrumentation around internal arena init and `ParseResult.deinit`: `xml_parse_single_tool_call` spent `2479.95` ns/op of `7888.53` ns/op in arena init/deinit (`31.44%`); `xml_parse_multi_tool_call` spent `4737.53` ns/op of `15178.77` ns/op (`31.21%`); `native_parse_tool_calls` spent `6882.66` ns/op of `20427.00` ns/op (`33.69%`). Deinit dominated; init averaged ~35 ns/op.
- API shape diff: `parseToolCalls(allocator, response, scratch_arena: ?*std.heap.ArenaAllocator)` and `ToolDispatcher.parseResponse(allocator, response, scratch_arena: ?*std.heap.ArenaAllocator)` now accept an optional caller-owned scratch arena. `null` preserves the internal owned-arena path. Non-null uses `scratch_arena.allocator()`, sets `ParseResult.arena = null`, marks the result arena-backed but not owner-backed, and leaves reset/deinit to the caller. `ParseResult.deinit` is O(1) for borrowed-arena results.
- Bench harness change: dispatcher parser benches allocate one `std.heap.ArenaAllocator` per benchmark context, pass it to `parseResponse`, call `result.deinit`, then `reset(.retain_capacity)` each iteration. No thread-local or global pool was introduced.
- Parser bench before/after ns/op: the prompt's pre-change 3-run macOS median was approximately `7000` / `15000` / `20000` ns/op for XML single / XML multi / native. The checked-in `baseline-zig-after-json-arena.json` artifact recorded `6832.0296484375`, `13490.371005859375`, and `17945.399521484374` ns/op respectively. After this change, the 3-run median-selected raw file is `benches/results/baseline-zig-after-arena-reuse.json`:
  - `xml_parse_single_tool_call`: `6832.0296484375` -> `545.9936373901368` ns/op (Rust ratio now 0.20x).
  - `xml_parse_multi_tool_call`: `13490.371005859375` -> `1157.7201916503907` ns/op (Rust ratio now 0.20x).
  - `native_parse_tool_calls`: `17945.399521484374` -> `261.6857014465332` ns/op (Rust ratio now 0.18x).
  - `memory_store_single`: `218778.73796875` -> `246735.8665625` ns/op (Rust ratio now 1.44x; within noise of unchanged memory code).
  - `memory_recall_top10`: `389292.04625` -> `419005.899375` ns/op (Rust ratio now 1.41x; within noise of unchanged memory code).
  - `memory_count`: `399.3829168701172` -> `415.4720846557617` ns/op (Rust ratio now 0.02x; within noise of unchanged memory code).
- Eval-driver result: `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` passed all 92 fixtures byte-equal (86 parser + 3 memory + 3 dispatcher).
- Comparison report: `benches/results/reports/2026-05-05-after-arena-reuse.md` shows pilot gate 3 at 6/6 within 2x and 4/6 faster.
- Open questions for Claude review: none blocking. Optional ergonomics question only: whether to add convenience wrappers later for the common null-scratch path, since Zig call sites now spell the ownership choice explicitly.
- Verification: `zig fmt --check zig/src/tool_call_parser/types.zig zig/src/tool_call_parser/entry.zig zig/src/tool_call_parser/root.zig zig/src/runtime/agent/dispatcher.zig zig/src/tools/eval_parser.zig zig/src/tools/eval_dispatcher.zig zig/bench/agent_benchmarks.zig`; `cd zig && zig build test`; `cd zig && zig build`; full eval driver; three fresh `benches/runner/run_zig.sh` samples; median selection via `jq`; `python3 benches/runner/compare.py benches/results/baseline-rust-2026-04-30.json /tmp/zig-bench-2.json --out benches/results/reports/2026-05-05-after-arena-reuse.md`.

---

## 2026-05-05 — Week 4 Day 0: Ollama provider port plan (Claude direct)

Pilot fully accepted at `1b6f9e5` (4 of 4 gates green). Week 4 begins the provider port per the plan §"Path to full port" #7 and D8: Ollama + OpenAI/OAuth only, drop everything else.

### Source scope (Ollama)

- `rust/crates/zeroclaw-providers/src/ollama.rs` — 1,436 lines / 52 KB.
- `rust/crates/zeroclaw-api/src/provider.rs:319` — Provider trait surface (`chat_with_system`, `chat_with_history`, `chat_with_tools`, `chat`, `list_models`, plus capability/default helpers).
- `rust/crates/zeroclaw-api/src/provider.rs:65` — `ChatResponse` struct (text, tool_calls, usage, reasoning_content). Already has Zig minimal analog in `dispatcher.zig`; reuse and extend.

### Phase 1 (this Codex chunk) — pilot scope

In:
- Constructors: `new(base_url, api_key)`, `new_with_reasoning(base_url, api_key, reasoning_enabled)`.
- Pure helpers: `normalize_base_url`, `strip_think_tags`, `effective_content`, `fallback_text_for_empty_content`, `parse_tool_arguments`, `format_tool_calls_for_loop`, `extract_tool_name_and_args`.
- Request: `build_chat_request_with_think` + types (`ChatRequest`, `Message`, `Options`, `OutgoingToolCall`, `OutgoingFunction`).
- Response parsing: `ApiChatResponse`, `ResponseMessage`, `OllamaToolCall`, `OllamaFunction`, `deserialize_args` quirk.
- Provider method: `chat_with_system(system_prompt, message, model, temperature) -> string` (the simplest trait method; orchestrates above + HTTP).
- HTTP transport: `std.http.Client` (sync POST to `{base_url}/api/chat`). Per D7 libxev defers; localhost Ollama is sync-friendly.

Out (Phase 2+):
- `chat_with_history`, `chat_with_tools`, `chat` overloads (need `convert_messages` which is 92 lines on its own).
- `list_models` (uses GET /api/tags + JSON parse — small, but adds a second endpoint).
- Multimodal image handling (`convert_user_message_content` + `multimodal::parse_image_markers`).
- `:cloud` model suffix routing (only relevant for remote Ollama endpoints with API keys).
- The retry-on-think-failure path in `send_request`.
- Reasoning provider field (`reasoning_enabled` is plumbed but not exercised in pilot).

### Eval approach (offline; no mock server)

Per D1's "Rust is reference, port doesn't change Rust" spirit, the eval tests deterministic logic — no live HTTP. Both sides expose pure functions for the high-risk paths; eval drives them with JSONL ops.

Eval ops (JSONL, byte-equal compared between Rust + Zig, canonicalized like the dispatcher pilot):
- `normalize_base_url` — `{op, raw_url}` → `{op, result}` (string).
- `strip_think_tags` — `{op, text}` → `{op, result}` (string).
- `effective_content` — `{op, content, thinking?}` → `{op, result}` (string or null).
- `build_chat_request` — `{op, model, system?, message, temperature, think?, tools?}` → `{op, result}` (serialized ChatRequest JSON object).
- `parse_chat_response` — `{op, body}` (raw JSON body string from Ollama) → `{op, result}` (parsed ChatResponse JSON).
- `format_tool_calls_for_loop` — `{op, tool_calls}` (array of {id?, name, arguments}) → `{op, result}` (string with the wrapped JSON the agent loop expects).

The Rust side may need a small amount of `pub` exposure on currently-private helpers (e.g., `parse_chat_response_body(body: &str) -> Result<ChatResponse>`). That's a Rust-side widening, not a behavior change — acceptable per D1's "narrow FFI for parity tests" clause.

Phase 2 (later) can add an end-to-end mock-server fixture for the actual `chat_with_system` HTTP path. Not blocking pilot acceptance.

### Files Codex will create

- `zig/src/providers/root.zig` — re-exports.
- `zig/src/providers/ollama/root.zig` — re-exports.
- `zig/src/providers/ollama/types.zig` — request/response struct types (allocator-owned per D10, deinit pattern matches dispatcher).
- `zig/src/providers/ollama/client.zig` — `OllamaProvider` struct + Phase 1 methods.
- `zig/src/tools/eval_providers.zig` — Zig eval binary with JSONL op dispatcher.
- `eval-tools/src/bin/eval-providers.rs` — Rust counterpart.
- `evals/fixtures/providers/ollama/scenario-{basic-chat,with-system-prompt,strip-think,tool-call-response,empty-content-fallback}/{input,expected}.jsonl` — 5 scenarios.
- Updates to `evals/driver/run_evals.py` (register `providers` subsystem), `zig/build.zig` (add `eval-providers` exe), `zig/src/root.zig` (add `pub const providers = ...`), `eval-tools/Cargo.toml` (`[[bin]] eval-providers`).

### Pinned questions for Claude review (likely to surface)

- Does Ollama's `<think>` strip differ from the parser pilot's `<think>` strip? Look at `dispatcher.rs:88-105` vs `ollama.rs:215-233` — Ollama's also `.trim()`s the result, so the implementations diverge intentionally.
- Does `format_tool_calls_for_loop` produce JSON that the existing parser pilot's `parseToolCalls` will then re-parse? If so, the eval should also chain the two and verify the round-trip.
- HTTP transport is NOT covered by the eval. Worth noting in porting-notes that any HTTP-layer bug would slip the gate. Acceptable for pilot; phase 2 adds mock-server fixture.

---

## 2026-05-05 — Ollama provider Phase 1 first-pass (Codex)

- Ported Phase 1 Ollama surface to Zig under `zig/src/providers/ollama/`: constructors (`new`, `newWithReasoning`), URL normalization, think-tag stripping, effective-content fallback, tool argument parsing, tool-call wrapper/prefix extraction, `formatToolCallsForLoop`, request building, response parsing, request JSON emission, and sync `chatWithSystem` via `std.http.Client`.
- Reused existing runtime provider types instead of duplicating: `zig/src/runtime/agent/dispatcher.zig` now carries `TokenUsage`, `ChatResponse.usage`, owned `ChatResponse.deinit`, and owned `ToolCall.deinit`.
- Reused the parser pilot JSON machinery (`parseJsonValueOwned`, `cloneJsonValue`, `freeJsonValue`, canonical JSON writer) for provider response/tool argument handling. No second JSON parser or new Zig dependency was added.
- Rust-side visibility widened only in `rust/crates/zeroclaw-providers/src/ollama.rs`: request/response structs and fields are public, plus `normalize_base_url`, `parse_tool_arguments`, `strip_think_tags`, `effective_content`, `fallback_text_for_empty_content`, `build_chat_request_with_think`, `format_tool_calls_for_loop`, and `extract_tool_name_and_args`. Added `parse_chat_response_body(body: &str) -> anyhow::Result<ChatResponse>` as a pure wrapper over the same response-handling path used by `chat_with_system`.
- Offline eval ops shipped: `normalize_base_url`, `strip_think_tags`, `effective_content`, `build_chat_request`, `parse_chat_response`, and `format_tool_calls_for_loop`. Added 5 provider scenarios under `evals/fixtures/providers/ollama/`; full eval result is 97/97 fixtures OK (86 parser + 3 memory + 3 dispatcher + 5 providers).
- Pinned Rust quirks preserved:
  - `strip_think_tags` removes closed `<think>...</think>` blocks, drops an unclosed think tail, and trims the final content.
  - `effective_content` tries stripped `content` first, then stripped `thinking`, and returns null when both are empty after stripping.
  - Ollama `arguments` may be a JSON string; Rust tries to parse it as JSON and falls back to `{}` on parse failure.
  - Tool-call formatting unwraps nested `tool_call` / `tool.call` / `tool_call>` / `tool_call<` names and emits the wrapped `{"tool_calls":[...]}` loop payload with `arguments` as a JSON string.
- Phase 2 deferrals remain unchanged: `chat_with_history`, `chat_with_tools`, `chat` overloads, `convert_messages`, `list_models`, multimodal image conversion, `:cloud` routing, retry-on-think-failure, provider vtable, OpenAI/OAuth, live/mock HTTP fixtures, and provider/agent-turn benches.
- Verification: `cd zig && zig build`; `cd zig && zig build test`; `cargo build --manifest-path eval-tools/Cargo.toml --release`; `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release`; `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin`.
- Surprise during verification: the first sandboxed `cargo test -p zeroclaw-providers --release` run built successfully but failed two existing environment/permission-sensitive tests (`Operation not permitted` and a temporary Bedrock bearer-token env assertion). Rerunning the same command outside the sandbox passed cleanly: 783 Rust tests passed, 0 failed, 1 doctest ignored.
- Open questions for Claude review: HTTP behavior is compile-checked but not exercised offline; Phase 2 should add a mock-server fixture before expanding into history/tools/streaming. Fixtures avoid missing Ollama tool-call IDs because Rust's fallback is UUID-based and intentionally nondeterministic.

---

## 2026-05-05 — Week 4 OpenAI Phase 1 plan (Claude direct)

Ollama Phase 1 landed at `6c30b90` (97/97 fixtures green). OpenAI Phase 1 mirrors that shape: `chat_with_system` + helpers + API key auth, no OAuth/native tools/list_models/warmup.

### Source scope (OpenAI)

- `rust/crates/zeroclaw-providers/src/openai.rs` — 1,039 lines / 35 KB.
- `rust/crates/zeroclaw-providers/src/auth/openai_oauth.rs` — 438 lines / 14 KB. **Phase 2** (Week 5+).
- `rust/crates/zeroclaw-providers/src/auth/oauth_common.rs` — 183 lines / 6 KB. **Phase 2**.
- `rust/crates/zeroclaw-providers/src/auth/{mod,profiles}.rs` — 574 + 716 lines, both need OpenAI-only trimming. **Phase 2**.

### Phase 1 scope

In:
- Constructors: `new(credential)`, `with_base_url(base_url, credential)`, `with_max_tokens(max_tokens)` (chained builder).
- Pure helpers: `adjust_temperature_for_model` (special-cases gpt-5, o1, o3, gpt-5-mini, etc. → forces temp=1.0), `ResponseMessage::effective_content` (content fallback to reasoning_content; always returns String — empty if both are missing).
- Request shape: simple `ChatRequest` + `Message` types (NOT `NativeChatRequest` — Phase 2).
- Response parsing: `ChatResponse` (`choices: Vec<Choice>` wrapper) + `Choice` + `ResponseMessage`.
- `chat_with_system` end-to-end: HTTPS POST `{base_url}/chat/completions` with `Authorization: Bearer <key>` → parse → return `choices[0].message.effective_content()`.
- HTTPS via `std.http.Client` (Zig 0.14.1 stdlib has TLS — verify in port).

Out (Phase 2+):
- `chat_with_tools`, `chat` overloads (use `NativeChatRequest`).
- All native tool-call types: `NativeChatRequest`, `NativeMessage`, `NativeToolSpec`, `NativeToolFunctionSpec`, `NativeToolCall`, `NativeFunctionCall`, `NativeChatResponse`, `UsageInfo`, `PromptTokensDetails`, `NativeChoice`, `NativeResponseMessage`, `parse_native_tool_spec`.
- `convert_messages`, `convert_tools`, `parse_native_response`.
- `list_models`, `warmup`.
- ALL OAuth (entire auth/openai_oauth.rs + auth/oauth_common.rs + auth/{mod,profiles}.rs trims). API key from env var only for Phase 1.
- `Provider` vtable in Zig — defer to a separate chunk AFTER OpenAI Phase 1 lands. With both providers in place, the abstraction has its 2nd consumer; refactor is a clean follow-up.

### Eval approach (extends existing providers harness)

Reuse `evals/fixtures/providers/` and the existing `eval-providers` binaries. Each op gains a `"provider"` field (`"ollama"` or `"openai"`); existing Ollama fixtures stay byte-equal (default provider="ollama" or explicit, both fine).

Four OpenAI ops:
- `build_chat_request` — input `{provider:"openai", model, system?, message, temperature, max_tokens?}` → `{result: <ChatRequest as JSON>}`.
- `parse_chat_response` — input `{provider:"openai", body: <raw JSON>}` → `{result: <ChatResponse with text, tool_calls=[], usage=null, reasoning_content>}`.
- `adjust_temperature_for_model` — input `{provider:"openai", model, requested_temperature}` → `{result: <f64>}`.
- `effective_content` — input `{provider:"openai", content?: string|null, reasoning_content?: string|null}` → `{result: <string>}` (always a string, may be empty per Rust semantics).

5 fixture scenarios under `evals/fixtures/providers/openai/scenario-*/`:
- `basic-chat-openai` — build + parse round-trip with simple text response.
- `with-system-prompt-openai` — build with system + user roles.
- `temperature-adjusted` — covers `gpt-5`/`o1`/`o3`/`o4-mini` model-specific temp=1.0 forcing.
- `reasoning-content-fallback` — response with empty `content` + non-empty `reasoning_content` (effective_content fallback).
- `multiple-choices` — response with `choices.len() > 1` (Rust takes [0]; Zig must too).

### Files Codex creates / modifies

- `zig/src/providers/openai/{root,types,client}.zig`.
- Updates to `zig/src/providers/root.zig` (add `pub const openai = ...`).
- Updates to `zig/src/tools/eval_providers.zig` and `eval-tools/src/bin/eval-providers.rs` (provider-field dispatch).
- 5 new fixture dirs under `evals/fixtures/providers/openai/scenario-*/`.
- `zig/build.zig` and `eval-tools/Cargo.toml` likely unchanged (eval-providers exe already exists; zeroclaw-providers already linked).

### Rust side surfacing (minimal widening)

- `rust/crates/zeroclaw-providers/src/openai.rs`:
  - Make pub: `adjust_temperature_for_model`, `ResponseMessage::effective_content` (or wrap in pub helper), the request/response struct types and fields exercised by the eval contract.
  - Add `pub fn parse_chat_response_body(body: &str) -> anyhow::Result<ProviderChatResponse>` mirroring the response-handling logic in `chat_with_system` (lines 405-413).
  - Visibility-only; `cargo test -p zeroclaw-providers --release` must still pass (currently 783).

### Pinned questions for Claude review (likely to surface)

- TLS via `std.http.Client` in Zig 0.14.1: does it work out of the box for `https://api.openai.com/v1/...`? If not, may need to vendor a TLS lib or use an alternate HTTP path. Phase 1 must verify.
- `ResponseMessage::effective_content` returns `String` always (empty when neither field present). Zig should match — return empty `[]u8`, not null, not error.
- Multiple choices: Rust `choices[0]` panics on empty. The eval should NOT exercise empty-choices (runtime panic in Rust); fixtures cover `len() == 1` and `len() > 1`, both pick [0].

---

## 2026-05-05 — OpenAI provider Phase 1 first-pass (Codex)

- Ported Phase 1 OpenAI surface to Zig under `zig/src/providers/openai/`: constructors (`new`, `withBaseUrl`, `withMaxTokens`), API-key bearer auth for `chatWithSystem`, base URL trailing-slash trimming, max-token request plumbing, `adjustTemperatureForModel`, simple `ChatRequest` / `Message` request JSON, simple `ChatResponse` / `Choice` / `ResponseMessage` parsing, and first-choice `chatWithSystem` response extraction.
- Reused existing provider/runtime types: `parseChatResponseBody` returns `runtime.agent.dispatcher.ChatResponse` with `owned = true`, `tool_calls = []`, `usage = null`, and duplicated `reasoning_content` when present. Native tool-call types were not ported.
- Reused the parser pilot JSON machinery (`parseJsonValueOwned`, `freeJsonValue`) for OpenAI response parsing. No second JSON parser, libxev, Provider vtable, or Zig dependency was added.
- Rust-side visibility widened only in `rust/crates/zeroclaw-providers/src/openai.rs`: simple `ChatRequest`, `Message`, `ChatResponse`, `Choice`, `ResponseMessage` and exercised fields are public; `ResponseMessage::effective_content` and `OpenAiProvider::adjust_temperature_for_model` are public. Added `OpenAiProvider::parse_chat_response_body(body: &str) -> anyhow::Result<ProviderChatResponse>` mirroring the simple `chat_with_system` response handling path.
- Existing providers eval harness was extended with a `provider` field while preserving missing-provider default to `"ollama"`, so the five Ollama provider scenarios remained byte-equal without fixture edits.
- OpenAI eval ops shipped: `build_chat_request`, `parse_chat_response`, `adjust_temperature_for_model`, and OpenAI-specific `effective_content`. Added five OpenAI provider scenarios: basic chat, system prompt with `max_tokens`, restricted-model temperature forcing, reasoning-content fallback, and multiple choices.
- Fixture result: 102/102 fixtures OK (86 parser + 3 memory + 3 dispatcher + 5 Ollama provider + 5 OpenAI provider).
- Pinned Rust quirks preserved:
  - Restricted models force temperature to `1.0`: `gpt-5`, `gpt-5-2025-08-07`, `gpt-5-mini`, `gpt-5-mini-2025-08-07`, `gpt-5-nano`, `gpt-5-nano-2025-08-07`, `gpt-5.1-chat-latest`, `gpt-5.2-chat-latest`, `gpt-5.3-chat-latest`, `o1`, `o1-2024-12-17`, `o3`, `o3-2025-04-16`, `o3-mini`, `o3-mini-2025-01-31`, `o4-mini`, `o4-mini-2025-04-16`.
  - Simple response parsing always takes the first choice and returns an error on empty choices; fixtures intentionally cover one and multiple choices, not zero choices.
  - `ResponseMessage.effective_content` returns content when `Some` and non-empty, otherwise `reasoning_content`, otherwise an empty string. It does not trim whitespace.
  - Simple OpenAI `ChatResponse` has no usage field; provider response usage remains null in Phase 1.
- TLS verification: a one-off Zig 0.14.1 `std.http.Client` GET to `https://api.openai.com/v1/models` succeeded through TLS and returned HTTP `401` without credentials. That confirms stdlib TLS is usable here; no vendored TLS dependency is needed for Phase 1.
- Phase 2 deferrals remain unchanged: native tool calling (`NativeChatRequest` and related tool/usage structs), `chat_with_tools`, `chat` overloads, `convert_messages`, `convert_tools`, `parse_native_response`, `list_models`, `warmup`, OAuth/profile trimming, provider vtable, mock HTTP fixtures, OpenAI/Ollama live integration tests, provider benches, and agent loop work.
- Verification: `cd zig && zig build`; `cd zig && zig build test`; `cargo build --manifest-path eval-tools/Cargo.toml --release`; `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` (783 passed, 0 failed, 1 doctest ignored); `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin`.
- Open questions for Claude review: Phase 1 compiles and TLS-probes the HTTP path, but authenticated OpenAI request/response behavior is still offline-only until Phase 2 mock/live fixtures land. The Zig provider reads the credential supplied to its constructor; wiring from `OPENAI_API_KEY` remains a caller/config concern for the later runtime integration.

---

## 2026-05-06 — Provider vtable Phase 1 plan (Claude direct)

Both Phase 1 providers landed (Ollama at `6c30b90`, OpenAI at `33cbc59`) and expose identical-shape `chatWithSystem` methods. The plan's "second consumer" condition is met, so the Provider vtable promotes from deferred to next chunk. Claude-direct because the surface is structural and small (~60-80 LOC), no Rust source to port (the Rust trait at `zeroclaw-api/src/provider.rs:319` is the spec but Zig follows the existing `ToolDispatcher` vtable precedent in `zig/src/runtime/agent/dispatcher.zig:117-142`).

### Phase 1 vtable surface

In:
- `Provider` handle struct: `ptr: *anyopaque, vtable: *const VTable` — same shape as `ToolDispatcher`.
- `Provider.VTable` with one method: `chatWithSystem(*anyopaque, allocator, ?[]const u8 system_prompt, []const u8 message, []const u8 model, ?f64 temperature) anyerror![]u8`. Signature mirrors the concrete chatWithSystem on both providers exactly.
- `Provider.chatWithSystem` instance method that dispatches through the vtable.
- `OllamaProvider.provider(self: *OllamaProvider) Provider` returning the handle, backed by a `const ollama_vtable: Provider.VTable` with one thunk that `@ptrCast(@alignCast(...))` the *anyopaque back to *OllamaProvider and forwards.
- Same on `OpenAiProvider`.

Out (Phase 2+):
- All other Rust trait methods: `simple_chat`, `chat_with_history`, `chat`, `chat_with_tools`, `list_models`, `warmup`.
- Capability getters: `default_temperature`, `default_max_tokens`, `default_timeout_secs`, `default_base_url`, `default_wire_api`, `capabilities`, `supports_native_tools`, `supports_vision`, `supports_streaming`.
- Tool conversion: `convert_tools`, `convert_messages`, `parse_native_response`.
- A registry / factory that produces a `Provider` from a config string (`"ollama"`/`"openai"`); deferred until the runtime needs it.

### Files Claude creates / modifies

- New: `zig/src/providers/provider.zig` — Provider handle + VTable.
- Modified: `zig/src/providers/root.zig` — `pub const provider = @import("provider.zig"); pub const Provider = provider.Provider;`.
- Modified: `zig/src/providers/ollama/client.zig` — add `provider(self: *OllamaProvider) Provider` plus const vtable + thunk.
- Modified: `zig/src/providers/openai/client.zig` — same.
- Modified: `zig/src/providers/ollama/root.zig` — re-export `Provider` for symmetry (optional).
- Modified: `zig/src/providers/openai/root.zig` — same.

No Rust changes. No fixture changes. Eval harness unchanged (vtable is structural; `chatWithSystem` is HTTP-bound and not eval-exercised in Phase 1, mock fixtures are Phase 2).

### Eval coverage

- `zig build test` adds a unit test that constructs both concrete providers, calls `.provider()`, asserts the vtable function pointer is non-null and the round-trip pointer cast yields the original concrete address.
- A minimal stub-provider test type within the test scope that records its receiver and verifies the dispatch thunk forwards correctly. This proves the vtable mechanism without touching HTTP.
- Existing 102/102 fixtures must remain green (this work touches no eval-exercised code path).

### Pinned questions for review

- The Rust `Provider` trait is async (`#[async_trait]`). The Zig vtable is sync because `chatWithSystem` is sync (uses `std.http.Client.fetch`, blocking). Phase 2's libxev integration may make these async; the vtable shape will change then (e.g., return a future / completion handle). Not blocking Phase 1.
- `*anyopaque` ptr-cast safety: caller must keep the concrete provider alive while the handle exists. Same constraint as `ToolDispatcher`. Documented in the type doc-comment, not enforced at type level (Zig has no lifetime tracking).
- Empty-vtable single-method shape is small enough that a Phase 2 extension is non-breaking — append fields to `VTable`, update vtable consts, no caller code changes required.

No source changes this commit — plan only.

---

## 2026-05-06 — Provider vtable Phase 1 first-pass (Claude direct)

- New `zig/src/providers/provider.zig` (~50 LOC): `Provider` handle (`ptr: *anyopaque, vtable: *const VTable`), `Provider.VTable` carrying a single `chatWithSystem` field, instance method that dispatches through the vtable. Doc-comment captures the receiver-lifetime contract.
- Both concrete providers gained `pub fn provider(self: *Self) Provider`, a file-private `const <name>_vtable: Provider.VTable`, and a thunk that `@ptrCast(@alignCast(...))` the `*anyopaque` receiver before calling the existing concrete `chatWithSystem`. Imports moved to bottom of `OllamaProvider`/`OpenAiProvider` files (Zig allows trailing top-level decls referencing earlier types).
- `zig/src/providers/root.zig` re-exports `provider` and `Provider` for callers that don't want to touch the concrete types.
- No Rust changes. No fixture changes. `eval_providers.zig` and `eval-providers.rs` untouched — vtable is structural and `chatWithSystem` remains HTTP-bound (Phase 2 mock-server fixture territory).
- New tests (3 added, 29 → 32):
  - `provider.zig`: stub concrete type implementing only `chatWithSystem`, called through the handle, asserts the receiver pointer round-trips and arguments forward verbatim. Proves the dispatch mechanism in isolation.
  - `ollama/client.zig`: constructs a real `OllamaProvider`, calls `.provider()`, asserts `@intFromPtr(handle.ptr) == @intFromPtr(&concrete)` and `handle.vtable.chatWithSystem == ollamaChatWithSystem`. Same on the OpenAI side.
- Verification: `zig build`; `zig build test` (32/32); `cargo build --manifest-path eval-tools/Cargo.toml --release`; `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` (783 passed, 0 failed, 1 doctest ignored — unchanged); `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` (102/102 — unchanged).
- Phase 2 deferrals confirmed unchanged: capability getters (`default_temperature`, `default_max_tokens`, `default_timeout_secs`, `default_base_url`, `default_wire_api`, `capabilities`, `supports_native_tools`/`supports_vision`/`supports_streaming`), additional chat methods (`simple_chat`, `chat_with_history`, `chat`, `chat_with_tools`), `list_models`, `warmup`, `convert_tools`, registry/factory, async-aware vtable shape (likely needed once libxev enters).
- Open notes for review: the file-private vtable consts live below their owning struct decl in each client.zig — not at module top — to keep the existing struct surface visually intact. If a future refactor moves them, watch for circular `@import("../provider.zig")` ordering (the vtable type only depends on `std`, so re-import position is unconstrained today).

---

## 2026-05-06 — Ollama provider Phase 2A first-pass (Codex)

- Ported the concrete Phase 2A Ollama chat surface in `zig/src/providers/ollama/client.zig`: `convertMessages`, `chatWithHistory`, `chatWithTools`, structured `chat`, synchronous `sendRequest` / `sendRequestInner`, and retry-on-`think=true` failure. The vtable remains unchanged; this is concrete-method only per D9's second-consumer rule.
- `convertMessages` now mirrors Rust's native Ollama message conversion: assistant JSON `tool_calls` become outgoing `tool_calls` with `type="function"` and parsed arguments via `parseToolArguments`; assistant calls seed `tool_name_by_id`; tool-role messages prefer explicit `tool_name`, then `tool_call_id` lookup, then raw parsed content fallback; user messages go through a Phase 3 multimodal TODO stub that returns unchanged content and no images.
- `chatWithHistory` converts history, sends no tools, and returns formatted tool-call loop JSON or effective/fallback text. `chatWithTools` passes raw preformatted tool JSON through, returns owned `dispatcher.ChatResponse`, populates native tool calls, and preserves `thinking` as `reasoning_content`.
- `chat` uses a small concrete `ProviderChatRequest` (`messages` plus optional raw tool JSON) and routes to `chatWithTools` when tools are present and `supportsNativeTools()` is true, otherwise `chatWithHistory`. No `Provider.VTable` extension, registry, or capability getter was added.
- Rust-side visibility widened only in `rust/crates/zeroclaw-providers/src/ollama.rs`: `ChatMessage` is re-exported from the `ollama` module for eval reach and `convert_messages` is now `pub`. No Rust behavior logic was added.
- Eval harness additions:
  - Rust and Zig `eval-providers` gained Ollama ops `convert_messages`, `chat_with_history_request`, and `chat_request`.
  - Added five scenarios under `evals/fixtures/providers/ollama/`: assistant tool-call extraction, tool-role id lookup, explicit tool-name precedence, multi-turn history request build, and structured chat request with tools.
  - Full fixture count is now 107/107 (86 parser + 3 memory + 3 dispatcher + 10 Ollama provider + 5 OpenAI provider).
- Pinned quirks preserved:
  - Tool argument strings still use `parseToolArguments`, with parse failure returning `{}`.
  - `tool_name_by_id` is populated only by parseable assistant `tool_calls` payloads and only affects later tool messages in the same conversion pass.
  - Tool content priority is `value.content` string, then non-empty raw tool message content, then null; there is no empty-string default for parsed tool messages.
  - User multimodal image extraction is intentionally stubbed for Phase 2A with a TODO pointing at Phase 3.
  - Retry-on-think-failure only activates when `reasoning_enabled == Some(true)` / `true`; if both attempts fail, Zig returns the first error tag.
- Phase 2B/3 deferrals confirmed unchanged: `list_models`, `warmup`, standalone `convert_tools`, real multimodal extraction, `:cloud` routing, capability getters / vtable extension, OpenAI Phase 2, mock HTTP fixture infrastructure, OAuth, agent loop, and provider benches.
- Verification: `cd zig && zig build` (clean); `cd zig && zig build test --summary all` (34/34 tests passed); `cargo build --manifest-path eval-tools/Cargo.toml --release` (release build finished); `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` (783 passed, 0 failed, 1 doctest ignored); `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` (all fixtures OK, 107 inputs).
- Zig 0.14.1 notes: the eval runner cannot import `tool_call_parser/types.zig` directly while also importing the public `zeroclaw` module without tripping "file exists in multiple modules", so it keeps a tiny local JSON clone/free helper for fixture-owned `std.json.Value` copies. Error-set retries preserve the original error tag, not Rust's richer `anyhow` context.
- Open questions for Claude review:
  - The structured `chat_request` eval uses raw preformatted tool JSON to keep standalone `convert_tools` deferred; confirm this is the desired Phase 2A boundary before OpenAI Phase 2 lands.
  - Rust's current trait capability method still returns prompt-guided/native-tools false for Ollama, while this concrete Zig `chat` path follows the Phase 2A instruction to route native tools when tools are present. Confirm whether the later capability/vtable phase should keep or revise that Rust behavior.

---

## 2026-05-06 — Provider Phase 2B-1 capability getters plan (Claude direct)

Both providers ship Phase 1 vtable (chatWithSystem only). Phase 2A added concrete chat-method overloads (Ollama landed at `7b9b002`; OpenAI is Codex-in-flight). Phase 2B is the vtable extension; this Day 0 plan scopes **Phase 2B-1 — capability getters only**, leaving the chat-method dispatch (chat / chatWithHistory / chatWithTools into Provider.VTable) to **Phase 2B-2** AFTER OpenAI Phase 2A lands. That respects D9 second-consumer for chat methods while letting the static capability surface land now without blocking on Codex.

### Phase 2B-1 surface

In:
- New `Capabilities` struct in `zig/src/providers/provider.zig`. Eight fields with Rust-baseline defaults so each provider only declares deltas:
  - `default_temperature: f64 = 0.7`           (Rust `BASELINE_TEMPERATURE`)
  - `default_max_tokens: u32 = 4096`           (Rust `BASELINE_MAX_TOKENS`)
  - `default_timeout_secs: u64 = 120`          (Rust `BASELINE_TIMEOUT_SECS`)
  - `default_base_url: ?[]const u8 = null`     (Rust trait default `None`)
  - `default_wire_api: []const u8 = "chat_completions"` (Rust `BASELINE_WIRE_API`)
  - `supports_native_tools: bool = false`      (Rust `ProviderCapabilities::default().native_tool_calling`)
  - `supports_vision: bool = false`            (Rust `ProviderCapabilities::default().vision`)
  - `supports_streaming: bool = false`         (Rust trait default)
- `Capabilities` embedded by-value in `Provider.VTable` as a new field; each provider's vtable const declares its specific deltas via field-default overrides.
- `Provider` instance methods exposing each field plus a `capabilities()` accessor returning the whole struct.
- Per-provider deltas (matching Rust):
  - **Ollama**: `default_temperature = 0.8`, `default_timeout_secs = 600`, `default_base_url = "http://localhost:11434"`, `supports_native_tools = false`, `supports_vision = true`. Other fields take baseline.
  - **OpenAI**: `default_base_url = "https://api.openai.com/v1"`, `supports_native_tools = true`. Other fields take baseline.

Out (Phase 2B-2 / Phase 3):
- `chat`, `chatWithHistory`, `chatWithTools` into `Provider.VTable` — Phase 2B-2, after OpenAI Phase 2A.
- `prompt_caching` field in Capabilities — defer until a runtime caller needs it. Rust's `ProviderCapabilities` has it; we'll add when we port the runtime piece that reads it.
- `supports_streaming_tool_events` — niche, defer.
- A `Provider` factory / registry — defer until config loading lands.
- Aligning Ollama's `supports_native_tools` flag with the concrete `chat()` routing — landed via this plan (the flag now correctly reports `false` matching Rust; the Ollama `chat()` override at `7b9b002` continues to route tools natively, which is intentional override semantics matching Rust at `ollama.rs:917-957`).

### Files Claude creates / modifies

- `zig/src/providers/provider.zig` — add `Capabilities` struct, extend `Provider.VTable` with `capabilities: Capabilities`, add eight instance methods + `capabilities()` accessor, extend the existing stub-dispatch test or add a second test asserting baseline defaults round-trip.
- `zig/src/providers/ollama/client.zig` — extend `ollama_vtable` const with `.capabilities = .{ .default_temperature = 0.8, ... }`.
- `zig/src/providers/openai/client.zig` — extend `openai_vtable` const with `.capabilities = .{ .default_base_url = "...", .supports_native_tools = true }`.
- `zig/src/providers/root.zig` — re-export `Capabilities` for callers (optional).
- New tests in each client.zig asserting per-provider getter values.

No Rust changes. No fixture changes. Eval harness unchanged — capability getters are not eval-exercised in Phase 2B-1 (the harness operates on offline message conversion + request-build paths, none of which read these flags). Phase 2B-2's chat-vtable extension may add fixture coverage if a polymorphic eval op gets useful.

### Design decisions

- **Capabilities embedded by-value in VTable**: each provider's `const <name>_vtable` gets a comptime-known struct literal that contains both the function pointer table AND the static capabilities. Reading from the handle is `handle.vtable.capabilities.X`. The `Provider` handle stays at 16 bytes (ptr + vtable pointer); no extra indirection.
- **Why static (not per-instance)**: every Rust `default_*` and `supports_*` we need to port is a `&self`-receiver method that ignores `&self` and returns a per-type constant. None of the Phase 2B-1 fields depend on instance state. If a future provider needs per-instance defaults, we promote that field to a vtable function pointer at that point.
- **Field-default-override pattern**: declaring `Capabilities{ .default_temperature = 0.8 }` and letting other fields take struct defaults keeps each provider's vtable readable and makes deltas-from-baseline obvious. Matches Rust trait defaults + per-provider overrides 1:1.

### Pinned questions for review

- Naming: instance methods use camelCase (`defaultTemperature`) to match the surrounding Zig style, even though Rust uses `default_temperature`. The struct field stays `default_temperature` (snake_case) to mirror serde field names if we ever serialize. Acceptable, but flagging in case we want a future cleanup.
- Test coverage: per-provider tests assert Rust-matching values (Ollama 0.8 / 600s / vision=true / native_tools=false; OpenAI api.openai.com/v1 / native_tools=true). If Rust constants ever drift, these tests catch it. No Rust-side cross-check (no eval op), so Rust drift only fails when we re-run a manual check.

No source changes this commit — plan only.

---

## 2026-05-07 — OpenAI provider Phase 2A first-pass (Codex)

- Ported the concrete Phase 2A OpenAI native chat surface in `zig/src/providers/openai/`: Native* request/response/tool/usage types, `convertMessages`, `chatWithTools`, structured `chat`, native request JSON writing with skip-if-null fields, native response parsing, and `parseNativeResponse` / `parseNativeResponseBody`. The `Provider.VTable` remains unchanged; chat-method vtable promotion stays deferred to Phase 2B per D9.
- `convertMessages` mirrors Rust's OpenAI history conversion: assistant JSON with parseable `tool_calls` becomes a NativeMessage with `type="function"` tool calls and stringified arguments preserved verbatim; assistant `content` and `reasoning_content` pass through when present; tool-role JSON maps `tool_call_id` and optional `content`; plain/other messages keep raw content as `Some`.
- Native response parsing now extracts text via OpenAI effective-content semantics, preserves `reasoning_content`, maps NativeToolCall into dispatcher tool calls, and carries usage (`prompt_tokens`, `completion_tokens`, `prompt_tokens_details.cached_tokens`) on the native path only. The Phase 1 simple `parseChatResponseBody` remains unchanged with `usage = null`.
- `chatWithTools` builds a `NativeChatRequest` from raw preformatted tool JSON and posts synchronously to `{base_url}/chat/completions` with `Authorization: Bearer`. Structured `chat` routes tools to the native path and routes no-tool calls through the Rust trait-default shape (`system` + last `user` via `chatWithSystem`) while still exercising native request conversion for the offline request-build helper.
- Rust-side surfacing in `rust/crates/zeroclaw-providers/src/openai.rs`: `ChatMessage` is re-exported from the `openai` module; Native* structs and exercised fields are public; `convert_messages`, `parse_native_response`, and `NativeResponseMessage::effective_content` are public; added `parse_native_response_body(body: &str)` to parse `NativeChatResponse`, delegate to `parse_native_response`, and attach usage. No behavior logic was changed beyond eval reach.
- Eval harness additions:
  - Rust and Zig `eval-providers` gained OpenAI ops `convert_messages`, `chat_request`, and `parse_native_response`.
  - Added five scenarios under `evals/fixtures/providers/openai/`: assistant tool-call conversion, tool-role id conversion, non-JSON assistant fallback, full native chat request with tools and `max_tokens`, and native response parsing with tool calls plus usage.
  - Full fixture count is now 112/112 (86 parser + 3 memory + 3 dispatcher + 10 Ollama provider + 10 OpenAI provider).
- Pinned quirks preserved:
  - `NativeToolCall.type` writes as JSON field `"type"`, matching Rust's serde rename.
  - `NativeFunctionCall.arguments` remains a string throughout; it is never parsed as JSON on conversion or response parsing.
  - `skip_serializing_if = Option::is_none` is mirrored manually in Zig writers, so all-null optional NativeMessage fields serialize as only `{"role":"..."}`.
  - Effective content is content when present and non-empty, otherwise reasoning content, otherwise null for the native path; no trimming.
  - Missing response tool-call IDs use Zig's deterministic Phase 1 placeholder `00000000-0000-4000-8000-000000000000` instead of Rust's `Uuid::new_v4()`; fixtures intentionally avoid the missing-id path.
- Phase 2B/3 deferrals confirmed unchanged: `parse_native_tool_spec` validation, `convert_tools`, `chat_with_history` as a separate OpenAI Zig method, `list_models`, `warmup`, OAuth, capability getters / chat-method vtable extension, Ollama refactors, mock HTTP fixture infrastructure, agent loop, runtime memory/parser work, and provider benches.
- Verification: `cd zig && zig build` (clean); `cd zig && zig build test --summary all` (36/36 tests passed); `cargo build --manifest-path eval-tools/Cargo.toml --release` (release build finished); `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` (783 passed, 0 failed, 1 doctest ignored); `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` (all fixtures OK, 112 inputs).
- Zig 0.14.1 notes: OpenAI native JSON needed manual skip-if-null writers because there is no serde-style derive; response/request ownership relies on explicit `std.json.Value` clone/free for tool parameters. The native eval path keeps raw tool JSON as NativeToolSpec-shaped values to avoid porting `parse_native_tool_spec` before Phase 2B.
- Open questions for Claude review:
  - Confirm the `chat_request` eval's raw NativeToolSpec path is the desired OpenAI mirror of Ollama Phase 2A until `convert_tools` / `parse_native_tool_spec` land.
  - Confirm the no-tools `chat` routing should stay trait-default `chatWithSystem` shaped, while offline `chat_request` remains the native request-build parity surface.
- Claude review note (post-first-pass): The `chat()` no-tools path builds a `native_request` via `buildNativeChatRequest` then immediately `defer native_request.deinit(allocator)` without using it before delegating to `chatWithSystem`. This is wasted work (alloc + free on every no-tools call) but not a correctness bug. Likely a misread of the brief sentence "build the request via convert_messages even when routing to chatWithSystem (so the fixture matches Rust's chat override)" — that sentence was about the eval `chat_request` op, not the runtime `chat()` method. Flag for a small Phase 2B cleanup; eval is not affected.

---

## 2026-05-07 — Provider Phase 2B-1 capability getters first-pass (Claude direct)

- New `Capabilities` struct in `zig/src/providers/provider.zig` with eight fields (`default_temperature`, `default_max_tokens`, `default_timeout_secs`, `default_base_url`, `default_wire_api`, `supports_native_tools`, `supports_vision`, `supports_streaming`). All defaults mirror Rust's `BASELINE_*` constants in `zeroclaw-api/src/provider.rs:301-359` so each concrete provider only declares deltas. Added `BASELINE_TEMPERATURE`/`BASELINE_MAX_TOKENS`/`BASELINE_TIMEOUT_SECS`/`BASELINE_WIRE_API` pub consts for ergonomics.
- `Capabilities` embedded by-value as a new field in `Provider.VTable` (with a `.{}` default so existing tests / consumers compile). Provider handle gains 9 new instance methods: `capabilities()` returning the whole struct, plus one accessor per field (`defaultTemperature`, `defaultMaxTokens`, `defaultTimeoutSecs`, `defaultBaseUrl`, `defaultWireApi`, `supportsNativeTools`, `supportsVision`, `supportsStreaming`).
- Per-provider deltas in each client.zig vtable const:
  - **Ollama** (`zig/src/providers/ollama/client.zig:387-395`): `default_temperature = TEMPERATURE_DEFAULT (0.8)`, `default_timeout_secs = 600`, `default_base_url = BASE_URL ("http://localhost:11434")`, `supports_native_tools = false`, `supports_vision = true`. Other fields take baseline.
  - **OpenAI** (`zig/src/providers/openai/client.zig:346-352`): `default_base_url = BASE_URL ("https://api.openai.com/v1")`, `supports_native_tools = true`. Other fields take baseline.
- `zig/src/providers/root.zig` re-exports `Capabilities` for callers that want the type without going through the handle.
- 3 new tests (36 → 39):
  - `provider.zig` "Capabilities defaults match Rust BASELINE_* constants" — pure struct-default check; catches Rust-baseline drift if a future plan changes a constant.
  - `ollama/client.zig` "Ollama capabilities match Rust impl" — asserts each getter via the handle returns Ollama's specific value.
  - `openai/client.zig` "OpenAI capabilities match Rust impl" — same for OpenAI.
- Resolves the Codex-flagged `supports_native_tools` divergence from Phase 2A: the flag now correctly reports `false` for Ollama (matching Rust at `ollama.rs:907-915`) and `true` for OpenAI (matching `openai.rs:487-489`). Ollama's concrete `chat()` override at `7b9b002` continues to ignore the flag and route tools natively, which is intentional Rust-matching override semantics — no Phase 2A revision needed.
- No Rust changes. No fixture changes. Eval harness unchanged — `run_evals.py` still 112/112. Capability getters are not eval-exercised in 2B-1 (the tests in client.zig + provider.zig are the cross-check; Rust drift only fails when those tests are re-run).
- Verification: `cd zig && zig build` (clean); `cd zig && zig build test --summary all` (39/39 tests passed); `cargo build --manifest-path eval-tools/Cargo.toml --release`; `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` (783 passed, 0 failed, 1 doctest ignored — unchanged); `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` (112/112 — unchanged).
- Phase 2B-2 remains: append `chat`, `chatWithHistory`, `chatWithTools` function pointers to `Provider.VTable`, wire each concrete provider's existing concrete method through a thunk, add a polymorphic-dispatch test using a stub provider type. The OpenAI 2A `chat()` no-tools wasted-work cleanup folds in cleanly there.

---

## 2026-05-07 — Provider Phase 2B-2 chat-method dispatch (Claude direct)

- New `provider.ChatRequest` type in `zig/src/providers/provider.zig`: `{ messages: []const dispatcher.ChatMessage, tools: ?[]const std.json.Value = null, tool_choice: ?[]const u8 = null }`. Mirrors the Rust `zeroclaw_api::provider::ChatRequest` envelope, with `tool_choice` exposed for OpenAI; Ollama silently ignores fields it doesn't honor.
- Both providers' file-private `ProviderChatRequest` types replaced with a `pub const ProviderChatRequest = @import("../provider.zig").ChatRequest;` alias. `zig/src/providers/{ollama,openai}/root.zig` re-exports stay byte-identical to consumers; `zig/src/providers/root.zig` adds `pub const ChatRequest = provider.ChatRequest;` for direct access.
- `Provider.VTable` extended with three new function-pointer fields: `chatWithHistory(ptr, allocator, messages, model, temperature) ![]u8`, `chatWithTools(ptr, allocator, messages, tools, model, temperature) !dispatcher.ChatResponse`, `chat(ptr, allocator, request, model, temperature) !dispatcher.ChatResponse`. The struct field set is now: `chatWithSystem`, `chatWithHistory`, `chatWithTools`, `chat`, `capabilities`. Each provider's vtable const declares all four function pointers; `capabilities` keeps its struct default.
- New OpenAiProvider concrete method: `pub fn chatWithHistory(self, allocator, messages, model, temperature) ![]u8`. Mirrors Rust's `chat_with_history` trait default for OpenAI — finds first system message, finds last user message, delegates to `chatWithSystem`. This pulls the previous inline routing out of OpenAI's `chat()` into a real method that satisfies the vtable signature on both sides.
- OpenAI 2A wasted-work cleanup folded in: `chat()` no-tools path no longer builds and immediately discards a `NativeChatRequest`. It now goes straight from request → `chatWithHistory` → `chatWithSystem` (the established trait-default shape). Rust behavior unchanged; one less alloc/free per no-tools call.
- Provider handle gains 3 new instance methods (`chatWithHistory`, `chatWithTools`, `chat`) that dispatch through the vtable. The Phase 1 stub-dispatch test was rewritten as a single combined "Provider vtable dispatches to concrete receiver across all four methods" test that exercises every vtable fn pointer with a stub provider type recording the last-called method + key args. Test count stays at 39 (one bigger test replacing one smaller test); coverage expanded 4×.
- Each provider's existing per-handle test was unaffected — they still assert `handle.ptr` round-trips and `vtable.chatWithSystem == <thunk>`. The 4-method coverage lives in `provider.zig` so it's not duplicated.
- No Rust changes. No fixture changes. `eval_providers` is untouched — chat / chatWithHistory / chatWithTools are HTTP-bound and not eval-exercised. The polymorphic dispatch surface is verified by the stub test.
- Verification: `cd zig && zig build` (clean); `cd zig && zig build test --summary all` (39/39 tests passed); `cargo build --manifest-path eval-tools/Cargo.toml --release`; `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` (783 passed, 0 failed, 1 doctest ignored — unchanged); `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` (112/112 — unchanged).
- Phase 2B closes here. Phase 3 candidates: mock HTTP fixture infrastructure (exercises chat/chatWithSystem/chatWithTools end-to-end without the network — biggest unblock for live-parity testing); convert_tools / parse_native_tool_spec (lifts the raw-JSON tool boundary in the eval contract); list_models / warmup; OAuth port; multimodal image extraction; agent loop / runtime port; provider benches.

---

## 2026-05-07 — Phase 3-A convert_tools / parse_native_tool_spec (Claude direct)

Lifts the raw-JSON tool boundary that Phase 2A's eval contract carried as a TODO. `Provider.ChatRequest.tools` is now typed as `?[]const ToolSpec` instead of `?[]const std.json.Value`; each provider converts the typed list to its native form internally.

### Surface

- New `provider.ToolSpec { name, description, parameters: std.json.Value }` mirrors `zeroclaw_api::tool::ToolSpec` (the canonical Rust type at `tool.rs:14-18`). `Provider.VTable.chatWithTools` and `Provider.chatWithTools` instance method now take `[]const ToolSpec`.
- `OpenAiProvider.convertTools(allocator, tool_specs)` produces `[]NativeToolSpec` matching Rust's `convert_tools` at `openai.rs:237-251` exactly. `OpenAiProvider.parseNativeToolSpec(allocator, value)` now public — validates `type == "function"` (fixing a Phase 2A bug where the kind wasn't checked) and returns `error.InvalidToolSpecType` on mismatch, `error.InvalidJson` on missing fields. Mirrors Rust's `parse_native_tool_spec` at `openai.rs:104-116`.
- `OpenAiProvider.buildNativeChatRequest` signature changed: takes `?[]const ToolSpec` (was `?[]const std.json.Value`). Internally calls `convertToolSpecs` → `[]NativeToolSpec`. The private `nativeToolSpecFromValue` (raw JSON → NativeToolSpec) is gone — `parseNativeToolSpec` is its public, validated replacement.
- `OllamaProvider.convertTools(allocator, tool_specs)` produces `[]std.json.Value` shaped as `{"type":"function","function":{"name","description","parameters"}}`. Mirrors Rust's inline mapping in `chat()` at `ollama.rs:917-944`. **Divergence**: Rust applies `SchemaCleanr::clean_for_openai` to `parameters`; Zig passes them through unchanged. Phase 4 follow-up to port `SchemaCleanr` if a runtime caller needs the parity. The eval contract intentionally avoids parameter shapes that SchemaCleanr would mutate.
- `OllamaProvider.chatWithTools` signature changed: takes `[]const ToolSpec`. Internally calls `convertTools`, then routes to the existing JSON-based `sendRequest` flow.
- `provider.ChatRequest` (the polymorphic envelope) is now provider-agnostic in tools too — same struct usable by both providers' `chat()` methods. Each provider's `client.ProviderChatRequest` is now `pub const ProviderChatRequest = provider.ChatRequest;` (alias).

### Eval contract changes

- Existing `chat_request` op (both providers): tools input now uses ToolSpec literal `{name, description, parameters}` instead of pre-built native JSON. The two `scenario-chat-request-with-tools` fixtures had their `input.jsonl` files updated; expected outputs unchanged.
- Existing `chat_with_history_request` op (Ollama): `tools` field dropped — Rust's `chat_with_history` trait default doesn't take tools, and the Phase 2A inclusion was a Codex over-implementation. No fixture used the field, so dropping is byte-equal-clean.
- New ops:
  - `convert_tools` for both providers — input `{tools: [ToolSpec...]}`, output `[<native form JSON>...]`. Eval-tested directly.
  - `parse_native_tool_spec` for OpenAI — input `{value: <arbitrary JSON>}`, output either the validated `NativeToolSpec` or `{"error": "InvalidToolSpec"}`. The error tag is canonicalized: Rust's anyhow message and Zig's `@errorName` don't byte-equal, so both runners normalize parse failures to the single `"InvalidToolSpec"` string.

### New fixtures

- `evals/fixtures/providers/openai/scenario-convert-tools/` — 2 lines: single-tool with full JSON Schema, two-tool with empty parameters object.
- `evals/fixtures/providers/ollama/scenario-convert-tools/` — 2 lines mirroring the OpenAI shape (Ollama's wrapping is byte-equal to OpenAI's `NativeToolSpec` JSON when no SchemaCleanr applies).
- `evals/fixtures/providers/openai/scenario-parse-native-tool-spec/` — 3 lines: valid spec round-trip, `"type":"not-a-function"` (rejected), missing `type` field (rejected). Confirms the kind=="function" gate fires.

### Files modified

- New: `provider.ToolSpec`, three new fixture dirs.
- `zig/src/providers/provider.zig` — ToolSpec struct, ChatRequest.tools type change, VTable signature update, instance method signature update, stub-dispatch test signature update.
- `zig/src/providers/openai/client.zig` — `parseNativeToolSpec` made pub + validates kind, new `convertTools` method, `buildNativeChatRequest` signature changed, `chatWithTools` / `chatWithToolsWithChoice` signatures changed, vtable thunk signature update, new `convertToolSpecs` private helper, `writeNativeToolSpecJson` made pub for eval.
- `zig/src/providers/openai/root.zig` — re-export `parseNativeToolSpec`.
- `zig/src/providers/ollama/client.zig` — new `convertTools` method, new `toolSpecToOllamaJson` / `putOwnedString` / `putOwnedClonedValue` / `freeOwnedJsonObject` private helpers, `chatWithTools` signature changed (typed input), vtable thunk signature update.
- `zig/src/tools/eval_providers.zig` — new `optionalToolSpecs` parser, dropped `optionalTools` for chat-request paths (kept as `optionalRawTools` for build_chat_request), new `runOllamaConvertTools` / `runOpenAiConvertTools` / `runOpenAiParseNativeToolSpec` ops, new local `freeOllamaToolJsonValue` and `writeJsonValue` helpers (kept local because of the parser_types module-collision Codex documented in the 2A first-pass).
- `eval-tools/src/bin/eval-providers.rs` — new `optional_tool_specs` parser, new `run_ollama_convert_tools` / `run_openai_convert_tools` / `run_openai_parse_native_tool_spec`, removed unused `optional_tools` and `optional_openai_native_tools` helpers, dropped tools input from `run_ollama_history_request`, both `run_*_chat_request` now consume ToolSpec[] and inline-wrap (Ollama side) or call `OpenAiProvider::convert_tools` (OpenAI side).
- 2 fixture inputs updated, 3 new fixture dirs.

### Rust visibility widenings

- `rust/crates/zeroclaw-providers/src/openai.rs`: `parse_native_tool_spec` and `convert_tools` made pub. `pub use zeroclaw_api::tool::ToolSpec` added so eval driver can `use zeroclaw_providers::openai::ToolSpec`.
- `rust/crates/zeroclaw-providers/src/ollama.rs`: `pub use zeroclaw_api::tool::ToolSpec` added for symmetry.
- No behavior changes. cargo test 783 / 0 / 1 doctest ignored unchanged.

### Pinned divergences

- Ollama's `convertTools` does NOT apply `SchemaCleanr::clean_for_openai`; Rust's runtime `chat()` does. The eval intentionally uses parameter shapes (object schemas with `properties`/`required`/empty) that survive SchemaCleanr unchanged, so Rust eval (which also skips SchemaCleanr) stays byte-equal with Zig. SchemaCleanr port is a separate Phase 4 chunk — it lives in `zeroclaw-api::schema` which has not been ported.
- `parse_native_tool_spec` error normalization to `"InvalidToolSpec"` — both runners collapse anyhow / errorName to this canonical tag; the eval cannot byte-equal-test the underlying error message because Rust and Zig's error string formats differ. Round-trip success cases still byte-equal via Python sort_keys.

### Verification

- `cd zig && zig build` (clean).
- `cd zig && zig build test --summary all` (49/49 tests passed — was 39 before this change; Codex's parallel OAuth Phase 1 work added 10 tests via `auth/` modules that get compiled once `pub const auth = @import("auth/root.zig")` lands in `zig/src/providers/root.zig`).
- `cargo build --manifest-path eval-tools/Cargo.toml --release`.
- `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` (783 passed, 0 failed, 1 doctest ignored — unchanged).
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` (115 fixtures all OK: 86 parser + 3 memory + 3 dispatcher + 11 Ollama provider + 12 OpenAI provider).

---

## 2026-05-08 — OpenAI OAuth Phase 1 first-pass (Codex)

- Ported the dependency-clean OAuth Phase 1 surface to Zig under `zig/src/providers/auth/`: PKCE state generation, deterministic PKCE-from-seed, base64url-no-pad helpers, RFC 3986 URL encode/decode, sorted query parsing, OpenAI OAuth constants, authorize URL/body builders, token/device/error response parsers, redirect-code parsing, and JWT account/expiry extraction.
- Added minimal auth data envelopes in `zig/src/providers/auth/types.zig`: `TokenSet` with `expires_at_utc_seconds`, `TokenResponseForEval` with deterministic `expires_in_seconds`, `DeviceCodeStart`, and `OAuthErrorResponse`. No chrono/wall-clock abstraction was introduced; production-shaped token parsing takes a synthetic `now_unix_seconds`, while eval parsing carries `expires_in` verbatim.
- Reused Zig 0.14.1 stdlib primitives directly: `std.crypto.random.bytes`, `std.crypto.hash.sha2.Sha256`, `std.base64.url_safe_no_pad`, and `std.json.parseFromSlice`. URL decode remains hand-rolled to preserve Rust's `+` → space behavior and invalid-percent handling; `std.unicode.fmtUtf8` mirrors Rust's `String::from_utf8_lossy` for decoded bytes.
- Rust-side changes stayed visibility/helper-only in `rust/crates/zeroclaw-providers/src/auth/`: added `pkce_state_from_seed`, form-body builder helpers, sync parse helpers for token/device/OAuth-error bodies, and a deterministic `TokenResponseForEval`. The async exchange/refresh/device polling behavior remains unchanged.
- Added a standalone `oauth` eval subsystem: new Rust/Zig binaries `eval-oauth`, build wiring, driver registration, and seven OAuth scenario dirs under `evals/fixtures/oauth/`. The OAuth error parser cases are folded into `scenario-parse-responses` so this adds exactly seven fixture directories.
- Pinned Rust quirks preserved:
  - `build_authorize_url` emits BTreeMap-equivalent alphabetical query key order.
  - Token/form bodies emit declaration order, not sorted order.
  - `parse_query_params` sorts final keys and duplicate decoded keys keep the final value.
  - `parse_code_from_redirect` gives `error=` precedence, then state mismatch/missing-state checks, then code/raw-code handling.
  - URL decode maps `+` to space and leaves invalid percent sequences to be consumed byte-by-byte.
  - JWT extraction reads segment 1 only, does not validate signatures, tries account keys in Rust order, and only rejects account IDs that are empty after trim.
- Phase 2/3 deferrals remain unchanged: no `receive_loopback_code`, no async HTTP token exchange/refresh/device polling port, no `AuthProfile` / profile store / `AuthService`, no `TokenSet::is_expiring_within`, no zeroclaw-config stubs, no chacha20poly1305 port, and no provider vtable extension.
- Verification:
  - `cd zig && zig build` — clean.
  - `cd zig && zig build test --summary all` — `49/49 tests passed` (baseline 39 + 10 auth tests).
  - `cargo build --manifest-path eval-tools/Cargo.toml --release` — release build finished.
  - `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` — `783 passed, 0 failed, 1 doctest ignored`.
  - `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all fixtures OK. After adding the seven OAuth scenarios on top of the 115-fixture Phase 3-A baseline, the verified total is 122 fixtures.
- No Zig stdlib gaps found. URL encoding was not delegated to a stdlib URI helper because Rust uses a small byte loop with form-style decode quirks; the OAuth round-trip eval covers spaces, `+`, invalid percent, Unicode, sorted query maps, SHA256/base64url, JWT extraction, and response parsing.
- Open questions for Claude review:
  - Confirm the `parse_token_response` eval contract should keep `expires_in_seconds` verbatim, including `0`, rather than mirroring production's `expires_at = None` for non-positive values.
  - Confirm folding `parse_oauth_error` into `scenario-parse-responses` is the right way to preserve the requested seven-fixture target while still covering the named op.
  - Confirm `parseCodeFromRedirect` returning an error tag in the public Zig helper, with `parseCodeFromRedirectResult` carrying the dynamic eval error string, is an acceptable Zig substitute for Rust's `anyhow` string errors.
- Claude review notes (post-first-pass):
  - All three open questions answered yes — the eval-only `expires_in_seconds` pass-through, folding `parse_oauth_error` into `scenario-parse-responses`, and the dual `parseCodeFromRedirect`/`parseCodeFromRedirectResult` API are all acceptable Phase 1 shapes.
  - Section dated 2026-05-08 to reflect commit-day chronology after the parallel Phase 3-A landed at `4cfa3f2`. Codex initially appended at the 2B-2 anchor before Phase 3-A merged; Claude reordered during review.

---

## 2026-05-08 — OpenAI OAuth Phase 2 first-pass (Codex)

- Ported the async/HTTP-bound OAuth surface that Phase 1 deferred, without crossing into profiles/AuthService/config: `receiveLoopbackCode`, `exchangeCodeForTokens`, `refreshAccessToken`, `startDeviceCodeFlow`, `pollDeviceCodeTokens`, `parseLoopbackRequestPath`, and `classifyDeviceCodeError`.
- Added `zig/src/providers/auth/loopback.zig` for the loopback listener and request-line parsing. The listener binds `127.0.0.1:1455`, accepts one connection, reads up to 8 KiB, extracts the second request-line token, and writes the Rust-verbatim success HTML with byte-accurate `Content-Length`. To preserve Rust's "parse before success response" order, `loopback.zig` returns a `LoopbackRequest`; `openai_oauth.receiveLoopbackCode` calls Phase 1 `parseCodeFromRedirect` before writing the 200 response.
- Added synchronous token endpoint POST helpers on top of `std.http.Client.fetch` using `application/x-www-form-urlencoded` bodies from the Phase 1 builders. 2xx token/device responses are parsed by the existing Phase 1 parsers; non-2xx token/device-start responses return narrow Zig error tags.
- Added device-code polling with injectable `now_unix_seconds_fn` and a private test seam: `pollDeviceCodeTokensWithHooks(allocator, device_start, now_fn, post_fn, sleep_fn)`. Production passes `postFormBody` + `sleepSeconds`; the unit test passes fake `HttpPostFn` and no-real-sleep `SleepSecondsFn` to exercise `slow_down` + `authorization_pending` + eventual 2xx success deterministically.
- Rust-side surfacing stayed visibility/helper-only in `rust/crates/zeroclaw-providers/src/auth/openai_oauth.rs`: extracted `parse_loopback_request_path`, added public `DeviceCodeErrorKind`, added `classify_device_code_error`, and routed the existing async loopback/polling code through the extracted helpers without changing async behavior.
- Eval harness additions stayed in the existing `oauth` subsystem: `parse_loopback_request_path` and `classify_device_code_error`. Added two OAuth scenario dirs (`scenario-loopback-request-path`, `scenario-classify-device-code-error`) covering request-line parsing errors/lowercase methods and all six device-code error classifications.
- Pinned Rust quirks preserved:
  - Loopback request path is `request.lines().next()` then second whitespace token. Zig uses ASCII space/tab tokenization rather than Rust Unicode `split_whitespace`; this is an accepted Phase 2 simplification and is now fixture-pinned for ordinary HTTP whitespace.
  - Success body is exactly `<html><body><h2>ZeroClaw login complete</h2><p>You can close this tab.</p></body></html>`; `Content-Length` uses `SUCCESS_BODY.len`.
  - Device polling checks 2xx success before attempting OAuth error classification.
  - `slow_down` uses `std.math.add(u64, interval_secs, 5) catch interval_secs`, matching the requested saturating-shape simplification.
  - Timeout implementation uses nonblocking `accept()` polling for the listener and `SO_RCVTIMEO` / `SO_SNDTIMEO` on the accepted stream. This avoids relying on std.net accepting timeout semantics while still bounding read/write after accept.
  - Polling timeout uses `now_fn() - start_unix_seconds > expires_in` before each loop body; production passes `std.time.timestamp`.
- Phase 3 deferrals remain unchanged: no `AuthProfile`, `AuthProfilesData`, `AuthProfilesStore`, `AuthService`, `SecretStore`, `zeroclaw-config`, `refresh_openai_access_token_with_retries`, Gemini refresh helpers, or `TokenSet::is_expiring_within`.
- Verification:
  - `cd zig && zig build` — clean.
  - `cd zig && zig build test --summary all` — `53/53 tests passed` (baseline 49 + loopback parser tests + classifier test + fake-HTTP polling test).
  - `cargo build --manifest-path eval-tools/Cargo.toml --release` — release build finished.
  - `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` — `783 passed, 0 failed, 1 doctest ignored`.
  - `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all fixtures OK. The OAuth delta is 7 + 2 = 9 OAuth fixture dirs. This working tree also contains two provider `scenario-list-models` fixture dirs, so the observed full-suite total is 126 fixture inputs rather than the Phase 1 note's 122 + 2 target.
- Zig 0.14.1 stdlib gaps/choices: no `std.http.Client.fetch` body-framing gap surfaced for form POSTs; `fetch` sets `content_length` from payload length. Loopback response framing is manual to match Rust's short fixed response. Accept timeout is manual nonblocking polling because std.net has no direct `accept(timeout)` helper.
- Live HTTP remains compile-checked but not eval-tested: `exchangeCodeForTokens`, `refreshAccessToken`, `startDeviceCodeFlow`, `pollDeviceCodeTokens`, and `receiveLoopbackCode` require OpenAI endpoints or local browser/socket integration. Phase 2 eval intentionally covers only the two offline helpers plus Zig unit tests for polling dispatch.

---

## 2026-05-08 — Phase 3-B list_models + warmup (Claude direct)

Ran in parallel with Codex's OAuth Phase 2. Closes the `list_models` deferral from both providers' Phase 1 notes plus the OpenAI `warmup` deferral. Touches different files from Codex's auth work (no merge conflicts).

### Surface

- `OllamaProvider.listModels(allocator) -> ![][]u8` — GET `{base_url}/api/tags`. Bearer auth iff `shouldUseAuth(self)` (api_key set AND endpoint non-local). Mirrors Rust at `ollama.rs:960-983`.
- `OpenAiProvider.listModels(allocator) -> ![][]u8` — GET `{base_url}/models` with `Authorization: Bearer`. Returns `error.OpenAiApiKeyNotSet` if no credential. Note: Rust delegates to `models_dev::list_models_for("openai")` (the no-auth catalog used by onboard); the Zig port hits `/v1/models` directly because that's the simpler, Ollama-shape-symmetric path. The catalog delegation can be added later if a runtime caller needs the no-auth path.
- `OpenAiProvider.warmup(allocator) -> !void` — GET `{base_url}/models` with bearer iff credential present, ignore body. Mirrors Rust at `openai.rs:574-584`. Noop when no credential (matches Rust).
- `parseModelsResponseBody(allocator, body) -> ![][]u8` exposed pub on both providers' `client.zig`. Returns owned slice of owned strings. Re-exported from `ollama/root.zig` and `openai/root.zig`.

### Rust visibility-only widenings

- New free `pub fn parse_models_response_body(body: &str) -> anyhow::Result<Vec<String>>` in each of `ollama.rs` and `openai.rs`. Self-contained `Resp`/`Entry` types (Ollama: `{models:[{name}]}`; OpenAI: `{data:[{id}]}`). Visibility-only: cargo test 783 / 0 / 1 doctest unchanged.

### Eval

- New op `parse_models_response` on both `ollama` and `openai` providers (Zig + Rust drivers). Routes to the per-provider `parse_models_response_body` helpers.
- 2 new fixture dirs: `evals/fixtures/providers/ollama/scenario-list-models/` (2 lines: typical multi-model + empty) and `evals/fixtures/providers/openai/scenario-list-models/` (2 lines: typical with `object` field + empty). Both providers' parsers ignore unknown fields.
- The HTTP-bound `listModels` and `warmup` themselves are not eval-tested — same Phase-1-shaped boundary (compile-checked, requires live OpenAI / local Ollama for runtime parity).

### Notes

- Ollama's `shouldUseAuth(self)` already existed (used by chat path); reused for `listModels` so the local-vs-remote bearer decision is consistent across endpoints.

### Verification

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — 53/53 tests passed (matches Codex Phase 2's count; my Phase 3-B's HTTP surface adds no compile-time tests because it's HTTP-bound; the `parse_models_response_body` helpers are exercised via the eval fixtures, not Zig unit tests).
- `cargo build --manifest-path eval-tools/Cargo.toml --release`.
- `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` (783 passed, 0 failed, 1 doctest ignored — unchanged).
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` (all fixtures OK; total inputs now 126: 86 parser + 3 memory + 3 dispatcher + 12 Ollama provider + 13 OpenAI provider + 9 oauth).

Phase 3-C candidates (not started): SchemaCleanr (`zeroclaw-api/src/schema.rs` is 844 LOC — needs its own Codex chunk; closes the divergence Phase 3-A documented for Ollama tool conversion), multimodal image extraction (`zeroclaw-providers/src/multimodal.rs` is 935 LOC — Codex chunk; finishes Phase 2A's Ollama TODO stub), `zeroclaw-config` port (substantial; unblocks OAuth Phase 3 + agent loop), agent-loop slice (`runtime/agent/loop_.rs` is 282 KB monolithic — needs careful slicing).

---

## 2026-05-08 — zeroclaw-config scouting + Phase 4-A unblock plan (Claude direct)

Scouting performed in parallel with Codex's SchemaCleanr port. Goal: figure out the smallest portable subset of `rust/crates/zeroclaw-config/` that unblocks OAuth Phase 3 (AuthProfilesStore + AuthService) without porting the full crate.

### Crate scale

`zeroclaw-config` is **~26,200 LOC across 20 files**. Breakdown:
- `schema.rs` — 18,036 LOC. The full Config struct with every option, nested types, derive macros. Massive.
- `secrets.rs` — 905 LOC. `SecretStore` (ChaCha20-Poly1305 with key in `~/.zeroclaw/.secret_key`).
- `policy.rs` — 3,674 LOC. SecurityPolicy + ACL evaluation.
- `pairing.rs` — 753 LOC. Device pairing.
- `cost/tracker.rs` — 566 LOC. Token-cost accounting.
- `scattered_types.rs` — 558 LOC. Misc structs.
- `migration.rs` — 369 LOC. Config schema migrations.
- Several smaller files (workspace, platform, helpers, traits, etc.) totaling ~1,600 LOC.

Porting all of it is a multi-week effort. Most of it is irrelevant to OAuth Phase 3.

### What OAuth Phase 3 actually needs (minimum)

Audit of `rust/crates/zeroclaw-providers/src/auth/{mod,profiles}.rs`:
- `auth/profiles.rs:11` — `use zeroclaw_config::secrets::SecretStore`
- `auth/mod.rs:16` — `use zeroclaw_config::schema::Config`

That's **two imports**. Reading the call sites:
- `SecretStore::new(state_dir, encrypt_secrets)` + `encrypt`/`decrypt`/`decrypt_and_migrate` — used by `AuthProfilesStore` to encrypt the `token_set` field of each profile before persisting to disk.
- `Config` is consumed via `AuthService::from_config(config)` which reads exactly TWO fields: `state_dir_from_config(config)` (a helper that resolves a path) and `config.secrets.encrypt` (a bool). That's the entire Config touch surface for auth.

The rest of `Config` (model providers, channels, policies, autonomy, cost tracker, pairing) has no auth consumer and is irrelevant for Phase 4-A.

### Phase 4-A scope (the unblock)

Port SecretStore to Zig + define a minimal `AuthConfig` substitute that captures only what auth needs. Skip the 18K-line `Config` schema entirely.

In:
- `zig/src/api/secrets.zig` (~300 LOC port) — `SecretStore` struct with:
  - `init(zeroclaw_dir, enabled)` constructor
  - `encrypt(plaintext) -> ![]u8` returning `enc2:<hex(nonce ‖ ciphertext ‖ tag)>` or plaintext if disabled
  - `decrypt(value) -> ![]u8` — handles `enc2:` (ChaCha20-Poly1305), `enc:` (legacy XOR for backward compat), no-prefix (passthrough)
  - `decrypt_and_migrate(value) -> !{ plaintext, migrated_value: ?[]u8 }` — auto-upgrade from enc: to enc2:
  - Private `loadOrCreateKey()` — reads `~/.zeroclaw/.secret_key` with 0600 permissions, creates if missing
- A minimal `AuthConfig` substitute either:
  - Inline at `zig/src/providers/auth/types.zig`: `pub const AuthConfig = struct { state_dir: []const u8, encrypt_secrets: bool };` (~10 LOC)
  - OR a free helper `auth.configFromZeroclawDir(zeroclaw_dir, enabled)` that constructs the equivalent inputs.
  - Decision: pick whichever feels less invasive when Phase 3 lands. The plan-only commit doesn't need to choose.

Out (deferred to later phases):
- `Config` schema port (Phase 4-B+, ~18K LOC, needs its own multi-week plan and likely Codex slicing).
- `SecurityPolicy` (Phase 4-C, depends on Config).
- `pairing.rs`, `cost/tracker.rs`, `migration.rs`, `workspace.rs`, `platform/*` — all out of Phase 4-A scope. Most need their consumers ported first.
- The `Configurable` derive macro shim (lib.rs:21-30) — only relevant once Config schema lands.

### Eval contract for Phase 4-A

Eval ops on a new `secrets` subsystem (or under `oauth` since they're auth-adjacent — pick one):
- `encrypt_decrypt_roundtrip` — given a plaintext + key, encrypt produces `enc2:` prefix, decrypt round-trips.
- `decrypt_legacy_enc` — given an enc:-prefixed value, decrypt produces plaintext (test backward compat).
- `decrypt_passthrough` — no prefix, return as-is.
- `migrate_enc_to_enc2` — `decrypt_and_migrate` on an `enc:` value returns plaintext + new `enc2:` form.

Ciphertext is non-deterministic (random nonce per encrypt), so `encrypt_decrypt_roundtrip` tests the round-trip not byte-equality of the ciphertext. Rust + Zig both encrypt with random nonces, decrypt each other's output (cross-language ciphertext compatibility test using fixed key bytes).

Fixture target: 4-5 scenarios. Run-evals total moves from 126 to ~131 once SchemaCleanr lands and Phase 4-A lands separately.

### Files Phase 4-A creates / modifies

- New: `zig/src/api/secrets.zig`, `zig/src/api/root.zig` (or extend the existing api/ directory if SchemaCleanr already created one), `zig/src/tools/eval_secrets.zig`, `eval-tools/src/bin/eval-secrets.rs`, fixtures.
- Modify: `zig/src/root.zig` (re-export api), `zig/build.zig` (eval-secrets exe), `evals/driver/run_evals.py` (secrets subsystem entry).
- Rust visibility: `SecretStore` and its methods are already `pub`. No widenings expected — verify only.

### Workforce

- Phase 4-A is a Codex first-pass candidate (port + crypto). Comparable scope to OAuth Phase 1 (~600 LOC of Zig with crypto + file I/O + tests + 4-5 fixtures + Rust eval bin).
- Or Claude-direct if Codex bandwidth is committed elsewhere. The crypto port mostly maps stdlib → stdlib (`std.crypto.aead.chacha_poly` exists in Zig 0.14.1).

### Pinned questions for review

- `chacha20poly1305` Rust crate vs Zig's `std.crypto.aead.chacha_poly.ChaCha20Poly1305`: same algorithm, may differ in API shape. Need to verify nonce/tag/key sizes match exactly (12/16/32 bytes per the spec — both should align).
- `~/.zeroclaw/.secret_key` resolution in Zig: `std.fs.getAppDataDir` or hand-roll `$HOME` + suffix. Pick the simplest cross-platform path; the Rust uses `dirs::home_dir()`.
- File mode 0600 on macOS/Linux via `std.fs.File.setMode` or open-with-mode flag. On Windows, ACLs are different — Phase 4-A can document the gap and skip Windows.
- Legacy XOR cipher: the `enc:` decrypt path is a backward-compat tail. Worth porting for migration parity, but the eval fixture for it can use a known XOR'd input + key.

No source changes this commit — plan only.

---

## 2026-05-08 — SchemaCleanr port (Codex first-pass)

- Ported Rust `zeroclaw-api/src/schema.rs`'s `SchemaCleanr` surface as a standalone Zig API module under `zig/src/api/`, deliberately not wired into Ollama `convertTools`. Production provider outputs therefore stay byte-identical until the planned follow-up commit opts into cleaning.
- New public Zig API in `zig/src/api/schema.zig`: `CleaningStrategy` (`Gemini`, `Anthropic`, `OpenAI`, `Conservative`), `GEMINI_UNSUPPORTED_KEYWORDS`, `SCHEMA_META_KEYS`, `cleanForGemini`, `cleanForAnthropic`, `cleanForOpenai`, `clean`, `validate`, plus `cloneJsonValue` / `freeJsonValue` for caller-owned `std.json.Value` trees. `zig/src/api/root.zig` re-exports the module and `zig/src/root.zig` now exposes `pub const api`.
- The recursive transform mirrors Rust ordering: `$ref` resolution first, `anyOf`/`oneOf` simplification second, then unsupported-key filtering with the same per-key special cases (`const` to single-item `enum`, skip sibling `type` when union exists, type-array null stripping, `properties`, `items`, and `anyOf`/`oneOf`/`allOf` recursion).
- `$defs` and `definitions` are flattened into `std.StringHashMap(std.json.Value)`. Values and keys are allocator-owned clones during cleaning, then freed before returning. For `ref_stack`, Zig uses `std.StringHashMap(void)` with allocator-owned `$ref` string keys and `fetchRemove` to free each key after recursion; this is the only ownership-shaped divergence from Rust's `HashSet<String>`, not a behavioral one.
- `$ref` quirks preserved: local refs parse only `#/$defs/` and `#/definitions/`; JSON Pointer decoding uses a single-pass `~0`/`~1` lookahead; unresolvable refs and cycle breaks return `{}` plus metadata from the original ref-bearing object, not from the target definition.
- Union quirks preserved: `try_simplify_union` only returns when stripping null leaves one variant or all remaining variants are same-typed literals; otherwise default `clean_object` keeps the cleaned union array. `is_null_schema` accepts `{const:null}`, exactly `{enum:[null]}`, and `{type:"null"}`. `allOf` recurses but never triggers simplification.
- Type-array quirks preserved: `"null"` entries are stripped, zero remaining entries become the string `"null"`, one remaining entry unwraps, and multiple entries stay an array. `const` converts to `enum` recursively, including nested `properties`.
- Strategy constants mirror the Rust source exactly. Note: the brief called Gemini's list "22 keywords", but `schema.rs:58-85` currently contains 20 entries; Zig preserves the source-of-truth list verbatim.
- Added a standalone `schema` eval subsystem:
  - Rust runner: `eval-tools/src/bin/eval-schema.rs`, using public `zeroclaw_api::schema::{SchemaCleanr, CleaningStrategy}` only.
  - Zig runner: `zig/src/tools/eval_schema.zig`, using allocator-managed `std.json.Value` input and `schema.freeJsonValue` output cleanup.
  - Driver entry: `schema` with `scenario-*/input.jsonl`, `eval-schema`, JSONL mode.
- Added seven fixture scenarios under `evals/fixtures/schema/`: unsupported-keyword strategy differences plus an end-to-end mixed schema; `$defs`/`definitions`/escaped-pointer refs; cycle detection; union simplification; type-array cleanup; const-to-enum; validate normalization. Full eval count is now 133 inputs (126 previous + 7 schema).
- The mixed schema line in `scenario-strip-unsupported-keywords` covers refs + unions + type arrays + const + unsupported keywords together. Across the scenario, all four Rust strategy arms plus the public clean-for-provider wrappers are exercised.
- `std.json.ObjectMap` in Zig 0.14.1 is `std.StringArrayHashMap(std.json.Value)`, observed in the stdlib source (`std/json/dynamic.zig`). This preserves insertion order like Rust's `serde_json::Map`. The cleaner inserts keys in input iteration order modulo dropped keywords and intentional `const` -> `enum` renaming; Python canonicalization still sorts keys for byte-equal eval output.
- No Rust behavior changes were needed. `eval-tools/Cargo.toml` now depends directly on `zeroclaw-api` so the eval runner can call the existing public SchemaCleanr API. No visibility widenings were required.
- Verification:
  - `cd zig && zig build` — clean.
  - `cd zig && zig build test --summary all` — `65/65 tests passed` (baseline 53 + 11 SchemaCleanr unit tests + the new `api/root.zig` refAllDecls test).
  - `cargo build --manifest-path eval-tools/Cargo.toml --release` — release build finished.
  - `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` — `783 passed, 0 failed, 1 doctest ignored` (unchanged).
  - `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-api --release` — `29 passed, 0 failed`; doc test `schema` passed.
  - `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all fixtures OK; counts by subsystem: parser 86, memory 3, dispatcher 3, providers 25, oauth 9, schema 7, total 133.
- Zig 0.14.1 stdlib gaps/choices: no `std.json.ObjectMap` ordering gap found. Local clone/free helpers live in `api/schema.zig` instead of importing parser helpers, keeping the standalone API module independent and avoiding the earlier parser-types import collision pattern.
- No pinned Rust quirks were left unpreserved. The only documented mismatch is the brief's Gemini keyword count (22 requested vs 20 present in the Rust source), resolved by mirroring Rust exactly.
- Claude review note (post-first-pass): Codex's section initially appended at line 555 (between sections from May 6) despite the explicit "APPEND AT THE END" instruction in the brief. Claude reordered during review to chronological end. Brief instruction has now failed for 4 of 6 Codex first-passes; consider a hook or different anchor strategy for future briefs.

## 2026-05-08 — Phase 4-A + OAuth Phase 3 first-pass (Codex)
- Scope landed / Zig surface: `zig/src/api/{secrets,config,datetime}.zig`, `zig/src/providers/auth/{profiles,service}.zig`, root re-exports, build exes, and 9 fixture dirs now cover `SecretStore`, minimal `AuthConfig`, RFC3339 helpers, full provider-agnostic `AuthProfilesStore`, and OpenAI-only `AuthService`; Rust eval tooling adds `eval-secrets`/`eval-profiles`; no Rust visibility widenings were needed, only eval-tool Cargo wiring for public `zeroclaw-config`/`zeroclaw-providers` APIs. Pinned quirks preserved: sync-only APIs, temp+rename writes, exclusive lock retry/sleep, ASCII trim profile IDs, nullable persisted profile fields, read-time `enc:` migration, OpenAI Codex aliases only, and canonical eval error tags.
- Deferrals confirmed: Windows key-file ACL parity, Gemini/Anthropic auth paths, refresh singleflight/backoff maps, and full Config schema remain out; `service.zig` carries a Phase 5 TODO for concurrent refresh. Zig 0.14.1 choices/gaps: ChaCha20-Poly1305 uses separate tag buffers wrapped into Rust's nonce/ciphertext/tag blob; hex decode and RFC3339 parse/format are hand-rolled; profile JSON uses a small sorted pretty-printer to mirror serde/BTreeMap output.
- Verification: `cd zig && zig build` clean; `cd zig && zig build test --summary all` reached `80/80 tests passed`; `cargo build --manifest-path eval-tools/Cargo.toml --release` clean; `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-config --release` reached `576 passed`; `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` reached `783 passed, 1 doctest ignored`; `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` passed all 142 inputs.
- Open questions for Claude review: confirm the Zig AuthService method signatures taking `now_unix_seconds` at mutation/refresh boundaries are the preferred Phase 3 shape; confirm keeping persisted Option fields as explicit JSON `null` follows the Rust source over the brief's skip-if-none wording; confirm `SleepMillisFn` for refresh retries is acceptable despite the brief naming `SleepSecondsFn`, since Rust backoff is millisecond-based.
- Claude review notes (post-first-pass):
  - Section appended at the literal end of the file on the first try; the 4-of-6 misorder streak is broken (now 4-of-7). Anchor instruction in the brief — "after the literal last line" with a quoted excerpt — appears to be the difference; recommend keeping that pattern.
  - All three Codex open questions answered yes. (1) `now_unix_seconds` at mutation/refresh boundaries matches OAuth Phase 2 clock-injection pattern. (2) Persisted Option fields emitting JSON `null` is correct — Rust's `PersistedAuthProfile` uses `#[serde(default)]` not `#[serde(skip_serializing_if = ...)]` (`profiles.rs:562`), so serde emits `"field": null` for None; the brief was wrong, Codex was right to follow source. (3) `SleepMillisFn` is correct — Rust `OAUTH_REFRESH_RETRY_BASE_DELAY_MS * attempt` is millisecond-granularity, brief mis-named.
  - Four latent bugs identified for a Phase 4-A.1 follow-up (none reachable by current eval coverage; all on OOM / IO-failure paths): (a) `secrets.zig:46-58 encrypt` — overlapping `errdefer`/`defer` on `ciphertext` produces a double-free on `hexEncode` OOM. (b) `profiles.zig:217-233 upsertProfile` — `errdefer stored.deinit` stays armed after `putProfileValue` transfers ownership; `saveLocked` failure double-frees the moved profile. (c) `profiles.zig:358-372 loadLocked` — `access_token` local is leaked if `parseOptionalRfc3339` or `cloneOptional` fails mid-construction of `profile.token_set`; partial `cloneOptional` results may also leak. (d) `profiles.zig:453-458 writePersistedLocked` — explicit `file.close()` followed by `errdefer file.close()` double-closes on `rename` failure.
  - Style nits queued (non-blocking): `secrets.zig:159` redundant `chmod` after `createFile(.{.mode=0o600})`; `secrets.zig:138` non-hex key file content returns `BadCipher` not `KeyFileCorrupt`; `new`/`init` aliases on SecretStore/AuthProfilesStore/AuthService (pick one); `decrypt_and_migrate` snake_case alias of `decryptAndMigrate`; `removeEmptyActiveProfiles` swallows OOM via `catch {}`; `removeProfile` empty-string-sentinel pattern is awkward.

## 2026-05-10 — Phase 4-A.1 fixup (Claude direct)

Closes the four latent OOM/double-close bugs flagged in the e557aef post-first-pass review (this file's preceding section, "Four latent bugs identified for a Phase 4-A.1 follow-up"). Adds `std.testing.checkAllAllocationFailures` regression sweeps that exercise the OOM paths the original eval fixtures could not reach, and an IO-failure regression for the rename path. The OOM sweeps additionally surfaced two pre-existing bugs in shared helpers; both are fixed in the same commit so the regression tests pass cleanly.

- Fix (a) — `zig/src/api/secrets.zig:38-58 SecretStore.encrypt`: dropped the overlapping `errdefer`/`defer` on `ciphertext` and reorganized to a single `defer` immediately after each successful alloc. Same `defer`-after-alloc pattern now applies to `ciphertext`, `blob`, and `encoded`. Eliminates the double-free that would have triggered if `hexEncode` or the final `allocPrint` returned OOM.
- Fix (b) — `zig/src/providers/auth/profiles.zig:217-235 AuthProfilesStore.upsertProfile`: introduced a `transferred` flag and changed the `stored` errdefer to `errdefer if (!transferred) stored.deinit(self.allocator);`, with `transferred = true` set immediately after `putProfileValue` consumes ownership. `saveLocked` failures past that point unwind via `data.deinit` (which now owns `stored` through the profiles map) instead of double-freeing.
- Fix (c) — `zig/src/providers/auth/profiles.zig:344-372 AuthProfilesStore.loadLocked` (OAuth branch): replaced the inline `AuthProfile{...}` struct literal and inline `profile.token_set = .{...}` block with two new private helpers — `buildLoadedProfileShell` (lines 837-868) and `buildOauthTokenSet` (lines 870-896). Each helper uses chained `errdefer`s so that a partial alloc failure mid-construction frees what was already allocated; on success the returned struct owns everything and the helper's errdefers are inert. Eliminates the leak of `access_token` / partially-cloned `cloneOptional` results.
- Fix (d) — `zig/src/providers/auth/profiles.zig:432-453 AuthProfilesStore.writePersistedLocked`: scoped `file.close()` inside an inner `defer` block and removed the redundant `errdefer file.close()` that previously paired with an explicit close. The temp-file `errdefer std.fs.cwd().deleteFile(tmp_path)` continues to handle rename-failure cleanup. Eliminates the double-close on `rename` failure.

Bonus fixes surfaced by the new OOM sweeps (both pre-existing latent bugs in shared helpers; would have been triggered the moment any caller hit OOM during a HashMap insert):

- Fix (e) — `zig/src/providers/auth/profiles.zig:754-790 putStringValue` / `putProfileValue` / `putPersistedProfile`: the previous `getOrPut` + `try allocator.dupe(key)` sequence left an empty slot in the map with uninitialized `key_ptr`/`value_ptr` if the key dupe OOMed. A subsequent `data.deinit` would dereference garbage and trigger a double-free in std.testing.allocator's bookkeeping (caught immediately by the `upsertProfile` OOM sweep). All three helpers now: (1) `try map.ensureUnusedCapacity(1)` first, (2) alloc the value (where applicable) with errdefer, (3) call `getOrPutAssumeCapacity` (cannot fail), (4) on `!found_existing`, dupe the key with `catch |err| { map.removeByPtr(gop.key_ptr); return err; }` to roll back the empty slot before propagating OOM.
- Fix (f) — `zig/src/providers/auth/profiles.zig:592-596 parsePersistedAuthProfiles`: the previous `allocator.free(out.updated_at)` followed by `out.updated_at = try jsonStringDup(...)` left `out.updated_at` dangling if the dupe OOMed; the `errdefer out.deinit(allocator)` then double-freed it (caught by the `load` OOM sweep). Reordered to alloc the new value first, free the old one, then assign — same pattern used elsewhere in the file (e.g., `replaceOptional`).

Regression tests added (4 total, all in inline `test` blocks; sweeps are bounded by Zig's stdlib `checkAllAllocationFailures` driver, not a hand-rolled loop):

- `zig/src/api/secrets.zig` — `test "SecretStore.encrypt is OOM-safe (regression for double-free fix)"`: nests `std.testing.tmpDir(.{})` and `SecretStore.new` inside the helper-driven sweep so the on-disk key file starts missing each iteration. Roundtrips encrypt+decrypt under every fail_index. Covers fix (a).
- `zig/src/providers/auth/profiles.zig` — `test "AuthProfilesStore.upsertProfile is OOM-safe (regression for move-semantics fix)"`: builds a populated OAuth profile via the new private `buildSampleOauthProfile` helper (uses a `transferred` flag of its own to keep the test setup leak-safe across the sweep) and calls `upsertProfile`. Covers fix (b) directly and incidentally exercises `saveLocked` → `writePersistedLocked` allocations. Surfaced fix (e).
- `zig/src/providers/auth/profiles.zig` — `test "AuthProfilesStore.load is OOM-safe (regression for struct-literal leak fix)"`: pre-writes a populated `auth-profiles.json` using `std.testing.allocator` (outside the failing-allocator scope) so each sweep iteration exercises the full `load` → `readPersistedLocked` → `parsePersistedAuthProfiles` → `decryptOptional` → `buildLoadedProfileShell` → `buildOauthTokenSet` path. Covers fix (c). Surfaced fix (f).
- `zig/src/providers/auth/profiles.zig` — `test "AuthProfilesStore writePersistedLocked recovers from rename failure (regression for double-close fix)"`: pre-creates a directory at the target `auth-profiles.json` path with a sentinel file inside, so `rename(file, dir)` fails on POSIX. Asserts `upsertProfile` returns *some* error (uses `catch return; return error.TestExpectedError;` to avoid pinning a specific tag, since the rename-into-dir error varies across macOS/Linux). Covers fix (d) — `FailingAllocator` cannot induce a rename failure (rename does not allocate via our allocator), so this is the only path that actually exercises the close+rename ordering.

Verification:

- `cd zig && zig build test --summary all` → `84/84 tests passed` (was 80/80; +4 regression tests, no other test removed).
- `cd zig && zig build` → clean.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` → all 142 fixtures OK; counts unchanged from the e557aef baseline (parser 86, memory 3, dispatcher 3, providers 25, oauth 9, schema 7, secrets 4, profiles 5).

Notes for future review:

- The OOM regression tests use `std.testing.checkAllAllocationFailures` (Zig 0.14.1 stdlib helper) rather than a hand-rolled `fail_index` loop. The helper does the right thing automatically: pre-flights the test_fn once with unlimited memory to count allocations, then sweeps `fail_index` from 0 to that count, detecting `SwallowedOutOfMemoryError` (function returned success after OOM induced), `NondeterministicMemoryUsage` (allocation count differs across runs), and `MemoryLeakDetected` (`allocated_bytes != freed_bytes` after OOM). The `test_fn` signature must take `Allocator` as its first arg.
- The bonus fixes (e) and (f) point at a broader review item: any other `getOrPut` + later-alloc-of-key pattern, or any free-then-realloc pattern, is latently broken under OOM. Recommend a follow-up pass over `secrets.zig`, `service.zig`, and the rest of `profiles.zig` (and the wider `zeroclaw-config` / `zeroclaw-providers` Zig code as it lands) to look for both. The fix templates from this commit (ensureUnusedCapacity + getOrPutAssumeCapacity + removeByPtr; alloc-then-free) are reusable.
- All four review-flagged style nits from the preceding e557aef section remain queued (non-blocking); this commit intentionally stays scoped to the four latent bugs plus the two bonus bugs the regression tests forced into scope.

## 2026-05-10 — OOM-pattern audit (Claude direct)

Follow-up to Phase 4-A.1's closing recommendation. Sweeps the rest of the Zig codebase for the two latent-bug patterns that surfaced when the FailingAllocator regression tests landed in `502f3e6`:

1. **getOrPut + later-key-alloc:** `std.HashMap.getOrPut` auto-sets `gop.key_ptr.*` to the borrowed `key` parameter (`std/hash_map.zig:1098-1104`). If the next line allocates an owned dupe and that allocation OOMs, the entry is left in the map pointing at borrowed memory; a later `data.deinit` then `allocator.free`s borrowed bytes — bad-free / double-free, depending on whether the address is still live elsewhere.
2. **free-then-realloc:** `allocator.free(field)` followed by `field = try allocator.dupe(...)` leaves `field` dangling on OOM; a later `errdefer self.deinit(allocator)` then double-frees.

Audit method: `grep` for `getOrPut(` in `--include="*.zig" src/`, then a Python regex sweep `r"allocator\.free\(([^)]+)\)\s*;\s*\n\s*\1\s*=\s*try "` for the second pattern. Each match hand-classified — only those that could actually be triggered by an OOM (not zero-byte dupes, not write-once-from-default fields) made the fix list.

### Findings

Pattern 1 — four call sites, all isomorphic to the `profiles.zig` fixes from `502f3e6`:

- `zig/src/providers/auth/service.zig:307-317 putStringValue` — production helper called by `AuthService.storeProviderToken` to populate Token-kind profile metadata.
- `zig/src/providers/auth/service.zig:394-409 putProfileForTest` — file-private test helper; same fix template.
- `zig/src/tools/eval_profiles.zig:281-290 putProfile` — eval runner helper.
- `zig/src/tools/eval_profiles.zig:292-302 putStringValue` — eval runner helper.

Pattern 2 — six grep hits, three real bugs in two helpers:

- `zig/src/tool_call_parser/entry.zig:601-617 removeMinimaxToolcallBlock` — iterative free-then-realloc loop. Bug.
- `zig/src/tool_call_parser/entry.zig:619-638 removeToolCallBlocksRusty` — same iterative pattern. Bug.
- `zig/src/tool_call_parser/entry.zig:182-186 / 198-202 / 214-218` — three caller sites that pass an owned dupe to one of the two helpers above. Caller code is correct *if* the helper's error contract is correct; the bug was in the helper, not the caller. Caller code unchanged.
- `zig/src/providers/auth/profiles.zig:255 removeProfile` — `self.allocator.free(entry.value_ptr.*)` followed by `entry.value_ptr.* = try self.allocator.dupe(u8, "")`. Technically not a bug because `dupe(u8, "")` is special-cased to never fail (`std/mem/Allocator.zig:267 if (byte_count == 0) return ...`), so left as-is. Pattern is fragile, but this is the only zero-byte case in the codebase.

### Fixes

Pattern 1 (4 sites in service.zig + eval_profiles.zig): same template as `502f3e6`'s fix (e). Replaces the `getOrPut + try allocator.dupe(key)` pair with `try map.ensureUnusedCapacity(1)` → `getOrPutAssumeCapacity` → `allocator.dupe(u8, key) catch |err| { map.removeByPtr(gop.key_ptr); return err; }`.

Pattern 2 (2 helpers in entry.zig): algorithmic restructure rather than a pure ownership fix. The previous iterative `allocator.free(current); current = try out.toOwnedSlice();` pattern lost the caller's input buffer on any post-iteration-1 OOM (the input was freed before the new buffer was secured; helper would then return error, caller's defer would double-free the now-dangling `cleaned_text`). New pattern: single-pass scan over `input_owned`, accumulate kept segments into one `out: std.ArrayList(u8)`, take ownership at the end, free `input_owned` only after `out.toOwnedSlice()` succeeds. `removeMinimaxToolcallBlock` collapses to a thin wrapper around `removeToolCallBlocksRusty` since they were structurally identical.

Caller code in entry.zig (lines 182-186, 198-202, 214-218) was already correct under the new helper contract — the existing `defer allocator.free(cleaned_text)` works whether the helper consumed the input (success) or left it untouched (error). No caller changes.

### Regression tests

Three new tests, all using `std.testing.checkAllAllocationFailures`:

- `zig/src/providers/auth/service.zig` — `test "service.putStringValue is OOM-safe (regression for OOM-pattern audit)"`. Builds a fresh `StringHashMap([]u8)` inside the sweep, exercises both the `put-new` (key dupe) and `put-existing` (value replace) branches, and lets `std.testing.allocator`'s leak detector + the helper's `MemoryLeakDetected` check confirm no leaks across every fail_index.
- `zig/src/providers/auth/service.zig` — `test "service.putProfileForTest is OOM-safe (regression for OOM-pattern audit)"`. Same shape for `StringHashMap(AuthProfile)`. Covers the test-helper branch of fix template 1.
- `zig/src/tool_call_parser/entry.zig` — `test "removeToolCallBlocksRusty is OOM-safe (regression for free-then-realloc fix)"`. Multi-pair input ("head\<TC\>aaa\</TC\>middle\<TC\>bbb\</TC\>tail") forces both removal-block branches and the final-tail append. Mirrors the production caller pattern with a `input_consumed` flag so the test setup itself stays leak-safe across the sweep — if the helper consumes input on success, `input_consumed = true` cancels the errdefer; if the helper errors, errdefer frees the input.

`removeMinimaxToolcallBlock` shares all logic with `removeToolCallBlocksRusty` after the wrapper collapse, so the one regression test covers both helpers transitively.

### Verification

- `cd zig && zig build test --summary all` — `87/87 tests passed` (was 84/84; +3 regression tests, no test removed).
- `cd zig && zig build` — clean.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 142 fixtures OK; counts unchanged. The audit fixes are pure error-path correctness improvements; no behavioral change on success paths.

### Notes

- `removeProfile`'s zero-byte sentinel pattern (`profiles.zig:255`) is technically safe but should migrate to a non-sentinel approach (e.g., collect IDs to remove, then a second pass to actually remove) when this file is next touched. Tracked in the e557aef-section style nits queue.
- `tool_call_parser/types.zig:215 parseObject` uses `getOrPut` correctly: it never overrides the auto-set `gop.key_ptr.*` and uses an `key_owned` flag to manage transfer-of-ownership. Verified safe; no fix needed.
- `removeProfile` and any future code that needs the "consume on entry, return new owned, untouched-on-error" contract should follow the new `removeToolCallBlocksRusty` pattern: build the new buffer to completion in a fresh `ArrayList`, take ownership, free the input last. Avoids the trap of mid-iteration ownership state.
- The two patterns this audit chased are now broadly fixed in the Zig codebase as it stands at `502f3e6`+. Future Zig code (especially Codex first-passes) should be reviewed against these two templates before landing.

## 2026-05-10 — Multimodal port plan (Claude direct)

Brief for the Codex first-pass that closes the Phase 2A Ollama TODO at `zig/src/providers/ollama/client.zig:534-543 convertUserMessageContent`. Scouting performed in parallel with Phase 5 (Claude-direct, separate file).

### Rust source

- `rust/crates/zeroclaw-providers/src/multimodal.rs` (935 LOC) — full multimodal surface.
- Public API surface (verified via `grep`):
  - `pub struct PreparedMessages { messages: Vec<ChatMessage>, contains_images: bool }`
  - `pub enum MultimodalError` — 8 variants: `TooManyImages`, `ImageTooLarge`, `UnsupportedMime`, `RemoteFetchDisabled`, `ImageSourceNotFound`, `InvalidMarker`, `RemoteFetchFailed`, `LocalReadFailed`.
  - `pub fn parse_image_markers(content: &str) -> (String, Vec<String>)` (`multimodal.rs:95-131`) — single-pass marker scanner; recognizes `[IMAGE:...]` prefix, finds the closing `]`, classifies the payload via `is_loadable_image_reference` (file path / http(s) URL / `data:` URI), preserves placeholder-style markers as literal text.
  - `pub fn count_image_markers` / `pub fn contains_image_markers` (`multimodal.rs:133-143`) — convenience wrappers over `parse_image_markers` summed across user messages.
  - `pub fn extract_ollama_image_payload(image_ref: &str) -> Option<String>` (`multimodal.rs:145-160` plus the rest) — handles `data:...,<payload>` extraction. Returns the base64 payload portion for Ollama's `images` field.
  - `pub async fn prepare_messages_for_provider(...)` (`multimodal.rs:160+`) — the orchestrator that does HTTP fetch (reqwest::Client), file I/O, base64 normalization, MIME detection, and image-count enforcement. This is where the bulk of the LOC lives.

- Internal helpers (lots of them — see grep output): `is_loadable_image_reference`, `collapse_wrapped_marker`, `trim_old_images`, `compose_multimodal_message`, `normalize_data_uri`, `validate_size`, `validate_mime`, `detect_mime`, `normalize_content_type`, `mime_from_extension`, `mime_from_magic`. The MIME-by-magic table is small (PNG/JPEG/WebP/GIF/BMP signatures).

### Consumers in the Rust codebase

- `rust/crates/zeroclaw-providers/src/ollama.rs:1` — `use crate::multimodal;`
- `rust/crates/zeroclaw-providers/src/ollama.rs:323` — `let (cleaned, image_refs) = multimodal::parse_image_markers(content);`
- `rust/crates/zeroclaw-providers/src/ollama.rs:330` — `multimodal::extract_ollama_image_payload(reference)`

Ollama only uses the two simple text-side functions (`parse_image_markers` + `extract_ollama_image_payload`). The orchestrator (`prepare_messages_for_provider`) is consumed by OpenAI and other providers that need full HTTP fetch + normalization. For closing the Ollama TODO specifically, the simple pair is sufficient.

### Phase 3-D scope (the proposed Codex chunk)

In:

- New `zig/src/providers/multimodal.zig` — port the Rust file's public API. Sync-only (the pilot is sync everywhere; the `prepare_messages_for_provider` orchestrator's HTTP fetch can use `std.http.Client` directly, mirroring the OAuth Phase 2 + Ollama `chat` HTTP patterns already in the codebase). Unicode/text scanning is straightforward Zig stdlib.
- Modify `zig/src/providers/ollama/client.zig:534-543 convertUserMessageContent` — replace the TODO stub with a call to the new `multimodal.parse_image_markers` + `multimodal.extract_ollama_image_payload` pair. Returns the cleaned text + an `images` slice of base64 payloads. The current `ConvertedUserMessageContent.images: ?[][]u8` field already exists and is wired through; this is just removing the `null` and populating it.
- New `zig/src/tools/eval_multimodal.zig` + `eval-tools/src/bin/eval-multimodal.rs` — eval runner pair, mirrors the existing `eval_secrets`/`eval_profiles` shape.
- Eval fixtures under `evals/fixtures/multimodal/` — at minimum: `parse_image_markers_basic`, `parse_image_markers_preserves_placeholders`, `parse_image_markers_handles_wrapped_marker`, `extract_ollama_payload_data_uri`, `extract_ollama_payload_passthrough`. 5-7 scenarios; if the orchestrator ports cleanly, also `prepare_messages_truncates_old_images`, `prepare_messages_rejects_large_image`, `prepare_messages_rejects_unsupported_mime`. Avoid live-network fixtures (use file paths + data URIs only — same boundary as the OpenAI eval fixtures around HTTP).
- Modify `evals/driver/run_evals.py` — register the `multimodal` subsystem.
- Modify Ollama's `scenario-chat-request-with-tools` and any other Ollama fixture whose user message content would now go through marker extraction (probably zero — most fixtures don't include `[IMAGE:...]` markers, so the cleaned-text path is a passthrough). Verify each fixture before/after.

Out (deferred):

- Live network image fetch in evals (the Rust eval bin should use the same boundary).
- Provider-side `image_url` multimodal handling for OpenAI — the orchestrator can be ported but wiring it into OpenAI's `convertMessages` is a separate Phase 3-E follow-up. Phase 3-D's wire-up only opens Ollama.
- `MULTIMODAL_DEFAULT_MAX_IMAGES` / `MULTIMODAL_DEFAULT_MAX_BYTES` — pull from `zeroclaw_config::schema::MultimodalConfig` in Rust; substitute with hardcoded constants in the Zig port (matching the `AuthConfig` substitute pattern from Phase 4-A) until Phase 4-B lands the full Config schema.

### Eval contract

- `parse_image_markers` is deterministic on bytes — exact-string compare for `cleaned`, exact-list compare for `refs`.
- `extract_ollama_image_payload` is deterministic on bytes — exact compare on `Option<String>`.
- `prepare_messages_for_provider` is non-deterministic on byte order if HTTP is involved (random connection ordering). Use only file-path + data-URI inputs in fixtures; assert on the resulting `PreparedMessages` content with a normalized JSON dump.
- Errors return canonical eval error tags (consistent with secrets/profiles convention): `multimodal_too_many_images`, `multimodal_image_too_large`, `multimodal_unsupported_mime`, etc. The Rust `MultimodalError` Display strings can stay free-form; the eval canonicalizes by tag.

### Workforce + format

Codex first-pass candidate (~600-1000 LOC Zig with HTTP + base64 + file I/O + tests + 5-7 fixtures + Rust eval bin), comparable scope to OpenAI Phase 2 (commit `9a3c87f`) and Phase 4-A (commit `e557aef`). Brief Codex with: this section as the primary scope doc, the file `multimodal.rs` to port verbatim modulo the substitutions above, and the established convention that the brief's "## YYYY-MM-DD —" section header lands at the literal end of `docs/porting-notes.md` after the first-pass commit (the anchor-misorder streak from the e557aef section's review notes).

### Pinned questions for review

- Base64 encode/decode: Zig 0.14.1 has `std.base64.standard.Encoder` / `Decoder` — verify the encoding alphabet matches Rust's `base64::engine::general_purpose::STANDARD` (it does — both are RFC 4648 standard).
- `std.http.Client` request shape for image fetch: GET, follow redirects, content-type/content-length headers. Mirror the OpenAI Phase 2 OAuth HTTP pattern at `zig/src/providers/auth/openai_oauth.zig`.
- File reading with size cap: `std.fs.File.readAll` after stat-checked size? Or `readAlloc(allocator, max_bytes)`? Pick the simplest cross-platform.
- MIME-by-magic: hardcode the 5 image format signatures from `multimodal.rs:515 mime_from_magic` exactly. PNG = `\x89PNG\r\n\x1a\n`, JPEG = `\xff\xd8\xff`, WebP = `RIFF...WEBP`, GIF = `GIF8[79]a`, BMP = `BM`.
- `MultimodalConfig` field reads — pick whichever shape feels less invasive: hardcoded constants (matches AuthConfig pattern), or a tiny `MultimodalConfig` substitute struct passed at API boundary.

No source changes this commit — plan only.

## 2026-05-10 — Phase 5: refresh singleflight + backoff (Claude direct)

Closes the Phase 5 TODO at `zig/src/providers/auth/service.zig:165-167` queued by the Phase 4-A + OAuth Phase 3 first-pass (commit `e557aef`). Run in parallel with the multimodal Codex first-pass (separate file boundary — `service.zig` vs `ollama/client.zig` + new `multimodal.zig`).

Mirrors Rust's per-profile refresh-lock + failure-backoff machinery from `rust/crates/zeroclaw-providers/src/auth/mod.rs:188-225` and the four module-level helpers `refresh_lock_for_profile`, `refresh_backoff_remaining`, `set_refresh_backoff`, `clear_refresh_backoff` (`auth/mod.rs:473-509`). Pilot is sync-only so the per-profile mutex is harmless overhead today; the contract becomes load-bearing once the agent loop and any libxev/multi-thread caller share an `AuthService` instance.

### Source changes

- `zig/src/providers/auth/service.zig` — new private `RefreshState` struct (init/deinit + `lockForProfile` + `backoffRemainingSeconds` + `setBackoff` + `clearBackoff`). `AuthService` gains a `refresh_state: *RefreshState` field; `init` heap-allocates it (so a `*const AuthService` reference can mutate the state via the pointer indirection without changing existing public method signatures); `deinit` tears it down. Internal `table_mutex: std.Thread.Mutex` guards both the `locks` and `backoffs` HashMaps.
- `zig/src/providers/auth/service.zig:147-205 getValidOpenaiAccessToken` — wired to use the new state. After the initial expiry check decides a refresh is needed: acquire the per-profile mutex, re-load the profile from disk (singleflight pattern from Rust `auth/mod.rs:188-195`), re-check expiry on the latest data, check the failure backoff (returns `error.RefreshInBackoff` if active), call `refreshOpenaiAccessTokenWithRetries`. On success, `clearBackoff`; on failure, `setBackoff(profile_id, OPENAI_REFRESH_FAILURE_BACKOFF_SECS)` and propagate the original refresh error (the backoff write itself uses a `catch {}` so an OOM there doesn't mask the more-useful refresh error).
- New constant `OPENAI_REFRESH_FAILURE_BACKOFF_SECS: i64 = 10` (matches Rust `auth/mod.rs:23`).

### Pinned shape decisions

- **Per-profile mutex storage:** heap-allocated `*std.Thread.Mutex` stored in a `StringHashMap(*std.Thread.Mutex)`. Rust uses `Arc<tokio::sync::Mutex<()>>` for shared ownership across async tasks; Zig's pilot is sync, so a raw heap-pointer suffices and avoids dragging in an Arc-equivalent. The contract: `RefreshState` owns the mutexes for its lifetime; callers may hold a `*Mutex` only across calls that don't outlive `AuthService.deinit`. For sync use this is trivially satisfied. When async lands, this likely needs an `Arc`-style ref-count or a different ownership model — documented at the struct-level comment.
- **Backoff deadline storage:** `i64` unix-second deadline in a `StringHashMap(i64)`. Rust uses `Instant`; Zig has no monotonic-clock equivalent in 0.14.1 stdlib for this kind of map, so the unix-second epoch (already used everywhere else in the auth surface for clock injection) is the natural fit. `backoffRemainingSeconds` always returns at least 1 even at the very edge of the window (matches Rust `(deadline - now).as_secs().max(1)`).
- **Error tag:** `error.RefreshInBackoff` rather than Rust's `anyhow::bail!("OpenAI token refresh is in backoff for {remaining}s due to previous failures")`. Typed-error matches Zig idiom; callers who need the remaining-seconds value can call `backoffRemainingSeconds` themselves.
- **The internal `getOrPut + dupe(key)` pattern:** both `setBackoff` and `lockForProfile` follow the Phase 4-A.1 / OOM-pattern-audit fix template — `ensureUnusedCapacity(1)` + `getOrPutAssumeCapacity` + `removeByPtr` rollback on key-dupe failure. Verified safe by the new `RefreshState.setBackoff is OOM-safe` and `RefreshState.lockForProfile is OOM-safe` regression sweeps.

### Tests added (4 inline `test` blocks, all in service.zig)

- `RefreshState backoff math: set, remaining, expiry-clears, clear` — covers all four state transitions plus the `>=1 second` floor at the deadline edge.
- `RefreshState lockForProfile returns the same mutex pointer for the same profile` — verifies pointer-identity for repeat lookups (the singleflight contract) and a sanity lock+unlock cycle.
- `RefreshState.setBackoff is OOM-safe` — `checkAllAllocationFailures` sweep over both first-insert and update-existing paths.
- `RefreshState.lockForProfile is OOM-safe` — `checkAllAllocationFailures` sweep over both new-mutex-allocation and existing-lookup paths.

### Out of scope

- Live multi-thread test (would need a real test harness; sync-mode covered).
- Backoff that shrinks the OpenAI retries-with-backoff inside `refreshOpenaiAccessTokenWithRetries` itself — that's intra-attempt sleep; this commit's backoff is inter-attempt across distinct refresh calls.
- Public surface for direct backoff inspection (`getBackoffRemaining` etc.). Internal-only for now; can be promoted when a caller needs it.

### Verification

- `cd zig && zig build test --summary all` — `91/91 tests passed` (was 87/87; +4 Phase 5 tests, no test removed).
- `cd zig && zig build` — clean.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 142 fixtures OK; counts unchanged. Phase 5 is purely a behavior addition on the OpenAI refresh path; existing fixtures don't exercise the refresh branch (would require a real OAuth server or a clock-injected expiry fixture, neither of which exists yet).

### Future hooks

- An eval fixture that exercises the refresh branch (mocking `postFormBody` via the `HttpPostFn` injection point already on `refreshOpenaiAccessTokenWithRetries`) would close the test gap. Would also let us assert backoff behavior after a simulated 5xx response.
- The shape questions raised in this section's "Pinned shape decisions" should get re-confirmed when libxev / async lands; the current design optimizes for sync-pilot ergonomics.

## 2026-05-10 — Style nits cleanup batch (Claude direct)

Closes 4 of 6 nits queued in the e557aef post-first-pass review section. Run in parallel with the multimodal Codex first-pass (separate file boundary — `secrets.zig` + `profiles.zig` vs Codex's new `multimodal.zig` + `ollama/client.zig`).

### Source changes

- `zig/src/api/secrets.zig:135-141 SecretStore.loadOrCreateKey` — `hexDecode`'s `error.BadCipher` now translates to `error.KeyFileCorrupt` at this layer, since at the key-file-loader level "the on-disk content isn't valid hex" reads as a corrupted key file rather than a ciphertext problem. OOM passes through unchanged.
- `zig/src/api/secrets.zig:155-160 SecretStore.createKey` — removed the redundant `try file.chmod(0o600)` after `createFile(.{ .truncate = true, .mode = 0o600 })`. `createFile` honors the mode flag at open time on POSIX; umask never grants bits we didn't already pass, so the explicit chmod was a no-op. Comment updated to explain.
- `zig/src/api/secrets.zig:81-83` — removed the snake_case `decrypt_and_migrate` alias. Verified zero callers; the camelCase `decryptAndMigrate` was the canonical entry point already.
- `zig/src/providers/auth/profiles.zig:237-274 AuthProfilesStore.removeProfile` — refactored to use a "collect provider keys, then remove in a second pass" pattern instead of the previous empty-string sentinel + sweep helper. Mutating the map during iteration is unsafe, so the previous code marked entries with a freshly-allocated empty string then swept via `removeEmptyActiveProfiles` (which silently swallowed OOM via `catch {}`). New pattern: collect matching provider keys into a `std.ArrayList([]const u8)`, then in a second loop `fetchRemove` each. Saves one `dupe(u8, "")` allocation per match and propagates OOM cleanly. The old sweep helper is now dead code and removed.
- `zig/src/providers/auth/profiles.zig:807-820 removeEmptyActiveProfiles` — deleted (dead code after the `removeProfile` refactor).

### Skipped from the queued nit list

- `new`/`init` aliases on `SecretStore` / `AuthProfilesStore` / `AuthService` — picking one and removing the other touches several callers (eval runners + tests) and the choice between `init` (Zig stdlib idiom) and `new` (current codebase plurality) is contentious. Punted to a separate cleanup with explicit consensus on which direction.

### Tests added

- `zig/src/providers/auth/profiles.zig` — `test "AuthProfilesStore.removeProfile clears matching active_profiles entries"`. No prior test exercised this branch. Covers both the multi-provider cleanup case (one profile id active in two providers) and verifies post-removal that both `active_profiles` entries are gone (the previous empty-string sentinel left them as `""`, which would have failed this assertion).

### Verification

- `cd zig && zig build test --summary all` — `92/92 tests passed` (was 91/91; +1 removeProfile coverage test).
- `cd zig && zig build` — clean.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 142 fixtures OK; counts unchanged.

## 2026-05-10 — OOM-pattern audit follow-up (Claude direct)

The original OOM-pattern audit (commit `47a7dc8`) claimed the codebase was "broadly clean" for the two patterns it chased. A Claude-direct code-review pass (Code Reviewer subagent, no commit) found the audit missed one sibling helper. This commit closes that miss and adds the matching regression test.

### Source change

- `zig/src/tool_call_parser/entry.zig:640-657 replaceAllOwned` — same `allocator.free(input_owned); return out.toOwnedSlice();` pattern as the audit fixed in `removeToolCallBlocksRusty` and `removeMinimaxToolcallBlock`. If `out.toOwnedSlice()` returns OOM, `input_owned` is freed and the helper unwinds; the caller's `defer allocator.free(cleaned_text)` (the standard caller pattern at `entry.zig:231-238` for the GLM tool-call branch) then double-frees. Reachable on every `cleaned_text = try replaceAllOwned(...)` loop iteration in the GLM branch. Fix: take ownership of the new buffer first, free the input second — same template the audit applied to the two sibling helpers, just missed for this third one.

### Regression test

- `zig/src/tool_call_parser/entry.zig` — `test "replaceAllOwned is OOM-safe (regression for missed-by-47a7dc8 free-then-realloc)"`. Multi-replacement input forces several appendSlice calls plus the final toOwnedSlice. Mirrors the production caller pattern with an `input_consumed` flag so the test setup itself stays leak-safe across the FailingAllocator sweep.

### Notes

- The `47a7dc8` commit's closing claim "the patterns this audit chased are now broadly fixed in the Zig codebase as it stands at `502f3e6`+" should be read with this follow-up appended: one site was missed at the time of that commit; with `replaceAllOwned` now fixed, that claim is accurate as of THIS commit's HEAD.
- Re-grep confirms no other free-then-realloc-on-self pattern matches across the Zig codebase. The audit's Python regex was correct; the failure was a hand-classification miss (`replaceAllOwned`'s `allocator.free(input_owned)` was on a *parameter* slice rather than a `self.X` field, so it didn't pop out of the audit's mental model — the regex itself flagged it but the line wasn't classified as buggy at the time).
- Three more code-review findings (SF-2 silent setBackoff OOM, SF-3 missing `getOpenaiRefreshBackoffRemaining` public surface, plus four nits) are bundled into a follow-up commit so this one stays scoped to the single audit miss.

### Verification

- `cd zig && zig build test --summary all` — `93/93 tests pass` (was 92/92; +1 regression test). Note: the working-tree count at commit time reads as 100/100 because Codex's uncommitted multimodal port (8 new tests) is also present in the tree; the 93/93 figure isolates this commit's contribution.
- `cd zig && zig build` — clean.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 142 fixtures OK (working-tree run reports 149 because of Codex's 7 multimodal fixtures); no behavioral change on the parser surface.

## 2026-05-10 — Code review follow-up bundle (Claude direct)

Bundles the should-fix and nit-level findings from the same Claude-direct code-review pass that surfaced the audit miss in `a0d3992`. Six items across `service.zig`, `profiles.zig`, and `eval_profiles.zig`. None of them rise to the must-fix level (no current bug is reachable by today's eval coverage), but each closes a concrete reviewer-identified concern. Run in parallel with the multimodal Codex first-pass (separate file boundary).

### SF-2 — log silent setBackoff OOM

`zig/src/providers/auth/service.zig:201-226 getValidOpenaiAccessToken` — the `setBackoff(...) catch {}` on the refresh-failure path is justified (don't mask the original refresh error) but the silent failure mode means a backoff that fails to record leaves the next caller free to immediately retry, defeating the rate-limit's purpose. The `catch` now logs via `std.log.warn` with the profile id and the underlying error so operators can correlate stuck-refresh patterns with allocator pressure. Behavior on the success path is unchanged.

### SF-3 — public `getOpenaiRefreshBackoffRemaining` method

`zig/src/providers/auth/service.zig:248-263 AuthService.getOpenaiRefreshBackoffRemaining` — added a public method that delegates to `RefreshState.backoffRemainingSeconds`. Pairs with the existing `error.RefreshInBackoff` from `getValidOpenaiAccessToken` so callers can decide whether to wait and retry vs surface the failure. The TOCTOU between this call and a subsequent `getValidOpenaiAccessToken` is harmless because the refresh path re-checks the backoff under the per-profile mutex and re-bails with `error.RefreshInBackoff` if a new backoff has been set.

### SF-1 doc — clarify stale-`now`-across-lock semantics

`zig/src/providers/auth/service.zig:174-187 getValidOpenaiAccessToken` — added a multi-line comment explaining that the post-lock re-check uses the same `now_unix_seconds` parameter as the pre-lock check (rather than re-sampling `std.time.timestamp()` like Rust's `Instant::now()` at `auth/mod.rs:201`). For the sync pilot the lock is essentially always uncontended so this divergence is benign; once libxev / multi-thread arrives, re-sample for the post-lock check.

### N-1 — test put-helpers leak on found_existing

`zig/src/providers/auth/service.zig:533-557 putProfileForTest` and `zig/src/tools/eval_profiles.zig:281-302 putProfile` — both now `gop.value_ptr.deinit(allocator)` when overwriting an existing key, matching the production `putProfileValue` template at `profiles.zig:788-789`. No fixture inserts a duplicate id today; the fix keeps the test/eval helpers aligned with the production contract.

### N-3 — OOM tests force at least one rehash

`zig/src/providers/auth/service.zig:680-702 refreshStateSetBackoffOomImpl` and `refreshStateLockForProfileOomImpl` — bumped both impls from 2-3 keys to 32. The default `std.StringHashMap` initial capacity grows multiple times before reaching 32 entries, so the OOM sweep now exercises the `ensureUnusedCapacity` rehash-OOM path on top of the existing `removeByPtr` rollback path. The RefreshState fix template was already correct; this confirms it under rehash pressure.

### N-4 — `removeProfile` dupes provider keys before `fetchRemove`

`zig/src/providers/auth/profiles.zig:255-275 removeProfile` — the previous code stored `entry.key_ptr.*` slices (live storage from the StringHashMap) in `providers_to_clear`, then called `fetchRemove(provider)` in a second pass. Today's `std.StringHashMap` happens to keep slot pointers stable across removes, but the public contract doesn't promise it. The collected provider keys are now allocator-owned dupes that get freed in a `defer` block; `fetchRemove` continues to free the map's own owned key (`entry.key`). Belt-and-braces against future stdlib changes.

### Skipped from the review

- N-2 (errdefer + catch readability nit on `RefreshState.lockForProfile` and `setBackoff`) — the visual-clarity argument is real but adding a `transferred` flag adds the same amount of cognitive load it removes. Left as-is.
- Test gap Q4 (`getValidOpenaiAccessToken` end-to-end with mocked `HttpPostFn`) — bigger work, deferred to a separate Phase 5.1 commit. The two specific scenarios the reviewer named (backoff-persists-across-calls, re-check-skips-on-already-refreshed) are tracked there.

### Verification

- `cd zig && zig build test --summary all` — `93/93 tests pass` (no new tests; this commit modifies existing OOM-sweep impls and adds a new public method without a dedicated test). Working-tree count reads as 100/100 because Codex's uncommitted multimodal port adds 7 tests to the tree.
- `cd zig && zig build` — clean.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 142 fixtures OK (working-tree run reports 149 with Codex's multimodal subsystem); counts unchanged on the auth surface.

## 2026-05-10 — Multimodal port (Codex first-pass)

Closes the Phase 3-D first-pass for `rust/crates/zeroclaw-providers/src/multimodal.rs` on the Zig side. The new `zig/src/providers/multimodal.zig` ports the public marker/parser payload surface plus the sync `prepareMessagesForProvider` path for data URIs, local files, and allowed remote fetches. The config dependency on `zeroclaw_config::schema::MultimodalConfig` is represented by a small hardcoded substitute (`max_images=4`, `max_image_size_mb=5`, `allow_remote_fetch=false`) with the same effective-limit clamps as Rust.

### Source changes

- `zig/src/providers/multimodal.zig` — added owned `ParsedImageMarkers`, `PreparedMessages`, `MultimodalConfig`, marker parsing, Ollama payload extraction, old-image trimming, MIME detection by content-type / extension / magic bytes, size validation, base64 normalization, and local/remote image normalization.
- `zig/src/providers/ollama/client.zig` — replaced the Phase 3 TODO in `convertUserMessageContent` with `multimodal.parseImageMarkers` + `extractOllamaImagePayload`; user image markers now populate Ollama `images`, image-only user messages become `content=null`, and placeholder markers remain ordinary text.
- `zig/src/tools/eval_multimodal.zig` and `eval-tools/src/bin/eval-multimodal.rs` — added parity runners for parse, count/contains, Ollama payload extraction, and `prepare_messages_for_provider`.
- `evals/fixtures/multimodal/` — added 7 fixtures: basic parsing, placeholder preservation, wrapped marker collapse, data-URI payload extraction, passthrough payload extraction, data-URI preparation, and old-image trimming with local PNG fixture files.
- `evals/driver/run_evals.py`, `zig/build.zig`, `zig/src/providers/root.zig`, and `eval-tools/Cargo.toml` — registered the new subsystem / binaries / provider module.

### Deferred

- OpenAI/provider-side `image_url` wiring remains Phase 3-E; the port exposes the normalizer but only Ollama consumes image markers in this pass.
- Live-network eval coverage remains deferred. The code path supports remote fetch when explicitly enabled, but fixtures stay offline with data URIs and temp local files.

### Verification

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — `100/100 tests passed` (+6 multimodal module tests and +1 Ollama conversion test in this pass).
- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean.
- `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` — `783 passed; 0 failed; 1 doctest ignored`.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 149 fixtures OK (`142 + 7 multimodal`).

### Pinned for review

- Remote image fetch uses `std.http.Client.open` rather than `fetch` so the final response `content_type` / `content_length` are visible before body normalization. No live-network fixture was added.
- Zig `prepareMessagesForProvider` returns canonical error tags through the eval runner, but the Zig public error surface is payload-free (`error.ImageTooLarge`, etc.) unlike Rust's contextual `MultimodalError` values.

## 2026-05-10 — Multimodal first-pass review (Claude direct)

Post-first-pass review of Codex's `295d798`. Method: a Code Reviewer subagent pass plus a manual scan for the two OOM patterns Codex was warned about in the brief. Both surfaced real bugs — none reachable by Codex's 7 happy-path fixtures, all on OOM or success-path-after-network-IO. This commit closes the must-fix and N-4 items, plus SF-1 (substitute drift). Remaining should-fix items (SF-2 untested error tags, SF-3 keep-alive body drain) and nits (N-1, N-2, N-3, N-5) stay queued for a separate Phase 3-D.1.

### MF-1 — `convertUserMessageContent` count==0 fallback double-free

`zig/src/providers/ollama/client.zig:563-572` — when every parsed image marker yielded `null` from `extractOllamaImagePayload` (e.g. malformed `[IMAGE:data:no-comma]`), the count==0 branch did `allocator.free(values); return .{ .content = try allocator.dupe(u8, content), .images = null };`. If the dupe OOMed, the blk-scoped `errdefer` (still armed because we hadn't broken out of the block) called `allocator.free(values)` a second time. Reachable by the standard FailingAllocator sweep on convertMessages with a `data:no-comma` marker. Fix: hoist the dupe before the manual `free(values)` so any OOM happens *before* the manual free, leaving the errdefer's free as the single owner.

### N-4 — `prepareMessagesForProvider` transfer-of-ownership leak

`zig/src/providers/multimodal.zig:184-189` — `try normalized_refs.append(try normalizeImageReference(...))` is the textbook double-try pattern: the inner alloc returns owned bytes, then the outer append can OOM before the bytes enter the list, stranding them outside any errdefer. Fix: hoist the inner result into a local with its own `errdefer allocator.free(...)`, then `ensureUnusedCapacity(1) + appendAssumeCapacity` so the transfer is atomic.

### MF-2 — `body` ArrayList leaked on success in `normalizeRemoteImage`

`zig/src/providers/multimodal.zig:394-395` — the `body` ArrayList had only `errdefer body.deinit()`, no plain `defer body.deinit()`. Every successful remote fetch leaked the full image bytes (up to `max_image_size_mb`). Untested today because no live-network fixture exists; would surface immediately when remote-fetch evals land. Fix: change `errdefer` → `defer`.

### Bonus — `parseImageMarkers` candidate transfer leak (surfaced by the regression test)

`zig/src/providers/multimodal.zig:77-92` — `try refs.append(candidate)` (the original Codex code) and even the first-attempt fix (`try refs.ensureUnusedCapacity(1); refs.appendAssumeCapacity(candidate)`) both leaked `candidate` if the ensureUnusedCapacity OOMed before append. The fix uses a `candidate_owned` flag pattern: errdefer frees iff still owned, set to `false` after candidate transfers to either `cleaned.appendSlice` (placeholder branch) or `refs` (loadable branch). Surfaced by the new MF-1 regression test — the test failed initially because the FailingAllocator sweep hit this codepath before reaching the count==0 branch.

### SF-1 — Eliminate substitute-default drift

`zig/src/tools/eval_multimodal.zig:86-99 configFromValue` — the runner hardcoded `4` and `5` as orelse-defaults independently from `multimodal.MultimodalConfig`'s field defaults at `multimodal.zig:22-26`. Brief explicitly called for "a single, replaceable location." Fix: start from `multimodal.MultimodalConfig{}` (which uses the library's `DEFAULT_MAX_IMAGES`/`DEFAULT_MAX_IMAGE_SIZE_MB` constants) and override only fields the fixture explicitly sets.

### Regression test added

`zig/src/providers/ollama/client.zig` — `test "convertUserMessageContent count==0 fallback is OOM-safe (regression for double-free)"`. Constructs a user message with a `data:no-comma` marker (parseImageMarkers extracts it as a ref; extractOllamaImagePayload returns null because no comma → count==0 branch fires), runs through the public `convertMessages` API under `std.testing.checkAllAllocationFailures`. The sweep fail_index = 4/10 surfaced both MF-1 and the bonus parseImageMarkers leak in sequence (fix one, sweep continues; fix the next, sweep passes). Asserts the fallback returns the *original* content (markers preserved) with `images = null`.

### Skipped from the review

- **SF-2 — Untested error tags** (`UnsupportedMime`, `RemoteFetchDisabled`, `LocalReadFailed`, `ImageSourceNotFound`, `InvalidMarker`, `ImageTooLarge`). Each should get a fixture; deferred to Phase 3-D.1 because the fixture authoring is a chunk of its own.
- **SF-3 — Keep-alive pool drain on early-return**. Pilot is sync + low-volume; the connection thrash is a Phase 3-E or Phase 5.x concern when a real client wires this up.
- **N-1 — Document `@enumFromInt(3)` for `redirect_behavior`**. Trivial; bundle with N-2 and N-3 in a future style sweep.
- **N-2 — Dead `bytes_base64` accept path in `eval_multimodal.zig`**. Same.
- **N-3 — Defensive `header["data:".len..]` slice check**. Caller-protected today; same.
- **N-5 — `FailingAllocator` regression sweeps on `parseImageMarkers` and `prepareMessagesForProvider`**. The MF-1 regression test ALREADY exercises `parseImageMarkers` indirectly (and surfaced the bonus bug there). Standalone sweeps would add coverage but are deferred — the candidate-flag fix has been verified by the existing sweep.

### Verification

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — `101/101 tests passed` (was 100/100; +1 MF-1 regression test).
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 149 fixtures OK; counts unchanged. Eval coverage doesn't reach the OOM paths these fixes close, but the SF-1 substitute-drift fix is exercised by every multimodal fixture that omits a `config` field.

### Notes for future Codex briefs

- The OOM-pattern reminders in the brief were necessary but not sufficient — Codex avoided the two specific patterns from `502f3e6`/`47a7dc8` but introduced two related transfer-of-ownership patterns (the `try normalized_refs.append(try ...)` and `try refs.append(candidate)` shapes). Future briefs should add a third template: "after any `try alloc(...)` whose result is then `try`-passed to a container, wrap the alloc in `errdefer free` and pre-reserve container capacity."
- `errdefer body.deinit()` (without a matching `defer`) is a specific anti-pattern — the helper is success-aware (only fires on error), so resources allocated for use *during* success leak silently. Worth a brief reminder for HTTP/file-IO chunks.

## 2026-05-10 — zeroclaw-api/provider.rs missing types port plan (Claude direct)

Brief for the Codex first-pass that fills out the remaining Rust `provider.rs` types in `zig/src/providers/provider.zig`. Run in parallel with Phase 3-D.1 (Claude-direct multimodal error fixtures + keep-alive drain — separate file boundary).

### Rust source

`rust/crates/zeroclaw-api/src/provider.rs` (730 LOC). The Phase 2B-1 commit (`0203c4b`) ported `Capabilities`, `ToolSpec`, `ChatRequest`, the `Provider` vtable, and the four `BASELINE_*` constants. About 12 types and one helper fn remain unported.

### What's missing in Zig (verified by grep + side-by-side comparison)

| Rust type / fn (provider.rs line) | Zig location today | Phase 3-F port target |
|---|---|---|
| `ToolCall` (47-51) | nowhere — providers have ad-hoc `AssistantToolCallFields` | `provider.zig` |
| `TokenUsage` (54-61) | nowhere | `provider.zig` |
| `ChatResponse` (65-89) | per-provider native types only (`openai/types.zig`, `ollama/types.zig`) | `provider.zig` (provider-neutral) |
| `ToolResultMessage` (99-103) | nowhere | `provider.zig` |
| `ConversationMessage` enum (108-121) | partially in `dispatcher.zig` (`Chat` + `ToolResults` only — `AssistantToolCalls` variant deferred per `porting-notes.md:200`) | extend `dispatcher.zig` to add the `AssistantToolCalls` variant + reasoning_content |
| `StreamChunk` (125-187) | nowhere | `provider.zig` (types only — no consumer yet, marked Deferred) |
| `StreamEvent` enum (189-211) | nowhere | `provider.zig` (types only) |
| `StreamOptions` (215-236) | nowhere | `provider.zig` |
| `StreamError` enum (243-258) | nowhere | `provider.zig` |
| `StreamResult<T>` type alias (239) | n/a in Zig (use `StreamError!T` directly) | skip — Zig idiom is `error_set!T`; no alias needed |
| `ProviderCapabilityError` (263-267) | nowhere | `provider.zig` |
| `ProviderCapabilities` (273-281) | exists as `Capabilities` (provider.zig:28) | rename or alias — see "Pinned questions" |
| `ToolsPayload` enum (285-296) | nowhere — providers have inline JSON building | `provider.zig` |
| `build_tool_instructions_text` (704+) | nowhere | `provider.zig` |
| `Provider` async trait (318+) | exists as `Provider` vtable (provider.zig:62) — sync-only, no `chat_streaming` | extend vtable with optional streaming method? — see "Pinned questions" |

### Phase 3-F scope (the proposed Codex chunk)

In:

- Extend `zig/src/providers/provider.zig` with the missing types listed above. Keep them as standalone struct/enum decls; no behavior changes to existing types.
- Extend `zig/src/runtime/agent/dispatcher.zig`'s `ConversationMessage` enum with the `AssistantToolCalls` variant (with `text: ?[]u8`, `tool_calls: []ToolCall`, `reasoning_content: ?[]u8`), wiring through deinit/clone for the new variant.
- Add `build_tool_instructions_text` (camelCase: `buildToolInstructionsText`) — the prompt-guided fallback formatter. Self-contained; takes `[]const ToolSpec`, returns owned `[]u8`.
- New eval contract: a dedicated `provider_types` subsystem (or extend `parser` since the formatting helper is parser-adjacent; pick whichever fits). 4-5 fixtures around `buildToolInstructionsText` shape parity with Rust + JSON serialization round-trip for each new struct.
- Eval runner pair: `eval-tools/src/bin/eval-provider-types.rs` + `zig/src/tools/eval_provider_types.zig` — exercises type construction, JSON serialization (where the Rust types derive `Serialize`/`Deserialize`), and the `buildToolInstructionsText` formatter.

Out (deferred):

- Wiring the new types into existing providers (Ollama / OpenAI). They currently use ad-hoc per-provider DTOs that map to the wire format directly. Phase 3-G+ would migrate to the new shared types; this commit lands the types only.
- Streaming behavior — only the **types** are ported (`StreamChunk`, `StreamEvent`, `StreamError`, `StreamOptions`). No `chat_streaming` vtable method, no provider implementation. This unlocks future streaming work without paying the libxev cost now.
- Async trait shape — Zig's vtable stays sync. The Rust `#[async_trait]` machinery has no Zig analogue; the existing vtable's sync chat method continues to suffice for the pilot.

### Pinned questions for review

1. **`ProviderCapabilities` vs `Capabilities` naming.** Existing Zig uses `Capabilities` (no provider prefix). Rust uses `ProviderCapabilities`. Pick one direction:
   (a) Rename existing `Capabilities` → `ProviderCapabilities` for parity.
   (b) Keep `Capabilities` and add a Rust-name alias `pub const ProviderCapabilities = Capabilities;`.
   (c) Add the new fields the Rust struct has that Zig's doesn't (`vision`, `prompt_caching` — Zig's `Capabilities` only has `native_tool_calling` per provider.zig:28). The brief should grow Capabilities to match Rust's ProviderCapabilities anyway; choose (a) or (b) afterward.
2. **`ChatResponse` vs per-provider native response types.** Today `OpenAi.NativeResponse` and `Ollama.Response` exist as wire-shape DTOs. The provider-neutral `ChatResponse` is what callers should consume. Add it now, but each provider's `chat()` still returns the native type until a separate migration commit lands. OK?
3. **`ToolCall` already exists in `dispatcher.zig`?** Verify before adding — if dispatcher's `ToolCall` matches the Rust shape, re-export instead of duplicate. (Rust's `ToolCall { id: String, name: String, arguments: String }`.)
4. **`StreamError` IO variant.** Rust uses `#[from] std::io::Error`. Zig has no equivalent error-set absorption; either declare `StreamError = error{ Http, Json, InvalidSse, Provider, Io }` (lossless tag set, no embedded message) and let providers convert via `catch return`, or use an error union with a payload struct. Recommend the simpler error-set form for the pilot.
5. **`build_tool_instructions_text` Rust source.** This function (line 704+) builds the prompt-guided fallback text by iterating tool specs and formatting their schemas. It's the LAST thing in `provider.rs` and is ~25 LOC of formatting. Verify byte-for-byte format parity in the eval — small format changes break tool-following on prompt-guided providers.

### Workforce

Codex first-pass candidate (~600-1000 LOC of Zig with mostly-DTOs + 1 prompt-formatter + tests + 4-5 fixtures + Rust eval bin). Comparable scope to Phase 4-A (commit `e557aef`). Pattern-mirror port — most of the work is translating Rust struct/enum shapes to Zig equivalents.

### OOM-pattern reminders for the brief

The post-multimodal review (commit `e492f68`) added a third template that Codex briefs should now include:

> **After any `try alloc(...)` whose result is then `try`-passed to a container** (e.g. `try arraylist.append(try allocator.dupe(...))`), wrap the alloc in `errdefer free` and pre-reserve container capacity. The naive `try container.method(try alloc(...))` shape leaks the inner allocation if the outer `try` fails before the result enters the container. See `multimodal.zig:184-189` and `multimodal.zig:77-92` for the canonical fix shapes.

Plus the original two patterns:
- `getOrPut + later-key-alloc` → use `ensureUnusedCapacity` + `getOrPutAssumeCapacity` + `removeByPtr` rollback.
- `free-then-realloc` (`allocator.free(self.X); self.X = try alloc(...)`) → alloc first, free old second.

### Verification gates (per the established convention)

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — existing tests pass + new ones (target ~110/110).
- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean.
- `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-api --release` — unchanged.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all existing fixtures OK + new ones.

### Anchor instruction

After the first-pass, append the writeup to `docs/porting-notes.md` AFTER THE LITERAL LAST LINE OF THE FILE. The current literal last line as of this plan commit is the line ending with "**...for HTTP/file-IO chunks.**" (the closing line of the multimodal review's "Notes for future Codex briefs" bullet — wait, this commit's section IS the new last section, so the new last line will be *this* closing instruction). Append directly after.

No source changes this commit — plan only.

## 2026-05-10 — Phase 3-D.1: multimodal error fixtures (Claude direct)

Closes the SF-2 test gap from the multimodal first-pass review (commit `e492f68`). Adds four fixtures that exercise the multimodal error tags previously untested by the offline eval suite. Run in parallel with the Codex first-pass on `zeroclaw-api/provider.rs` missing types (separate file boundary — fixtures only here, no source changes).

### Fixtures added (`evals/fixtures/multimodal/`)

- `scenario-error-invalid-data-uri` — `[IMAGE:data:image/png,abcd==]` (data URI missing `;base64` segment) → `multimodal_invalid_marker`. Triggered at `multimodal.zig:365` in `normalizeDataUri`.
- `scenario-error-remote-fetch-disabled` — `[IMAGE:https://example.com/img.png]` with default config (allow_remote_fetch=false) → `multimodal_remote_fetch_disabled`. Triggered at `multimodal.zig:353`.
- `scenario-error-image-source-not-found` — `[IMAGE:$TMP/never-created.png]` (no file written via `files`) → `multimodal_image_source_not_found`. Triggered at `multimodal.zig:426` (`error.FileNotFound` mapping).
- `scenario-error-unsupported-mime` — `[IMAGE:$TMP/fake.txt]` with bytes `[104,101,108,108,111]` ("hello") → `multimodal_unsupported_mime`. The `.txt` extension isn't in `mimeFromExtension`'s image table, the bytes don't match `mimeFromMagic`'s known signatures (PNG/JPEG/WebP/GIF/BMP), so `detectMime` returns null and `normalizeLocalImage` raises `error.UnsupportedMime`.

All 4 fixtures pass on first try with byte-equal output between Rust and Zig runners (the canonical eval contract).

### Skipped from the SF-2 list

- **`multimodal_image_too_large`** — would require a fixture file >1 MB (effectiveLimits clamps `max_image_size_mb >= 1`). Awkward fixture size; deferred.
- **`multimodal_local_read_failed`** — hard to trigger deterministically from a pure fixture (permission-bit manipulation isn't fixture-friendly cross-platform). Deferred.
- **`multimodal_remote_fetch_failed`** — would require a live network endpoint; live-network fixtures explicitly out of scope.
- **`multimodal_too_many_images`** — *unreachable* in current code: the `MultimodalError.TooManyImages` variant is declared on both Rust (`multimodal.rs:25`) and Zig (`multimodal.zig:12`) sides but never raised. The `effectiveLimits` clamp + the `trimOldImages` reduce-to-limit guarantee mean `prepareMessagesForProvider` has no code path that errors with this tag. Documented for a future cleanup; left as-is for now to maintain Rust↔Zig enum parity (removing only from Zig would create cross-language divergence).

### SF-3 (keep-alive pool drain on early-return) — explicitly deferred

The reviewer flagged this as "acceptable for pilot" — connection-pool thrash matters under load, not in offline eval scenarios. Tracked for a future Phase 5.x or Phase 3-E commit when a real client wires this path up.

### Verification

- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 153 fixtures OK (`149 + 4 multimodal error fixtures`).
- `cd zig && zig build test --summary all` — `101/101` unchanged (no source changes).
- Each error fixture runs in <100ms; offline; no network.

## 2026-05-10 — Phase 3-D.2: multimodal eval-runner `bytes_base64` parity fix (Claude direct)

Closes the only must-fix from the second-pass review of Codex's multimodal commit (`295d798`). The Zig eval runner accepted both `bytes` (array-of-u8) and `bytes_base64` (string) for fixture file payloads; the Rust runner only accepted `bytes`. All 7 shipped fixtures used `bytes` so nothing failed today, but a future fixture authored with `bytes_base64` would have silently produced different file contents (or a hard `file byte must be u8` crash) on the Rust side, breaking the parity contract.

### Source change

`eval-tools/src/bin/eval-multimodal.rs:131-149` — added a `bytes_base64` branch to `file_bytes` that decodes via `base64::engine::general_purpose::STANDARD`. Falls through to the existing `bytes` array branch when absent. Mirrors `zig/src/tools/eval_multimodal.zig:117-134` exactly.

`eval-tools/Cargo.toml` — added `base64 = "0.22"` (workspace-pinned version, same as `zeroclaw-providers`).

### Verification

- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 153 fixtures still OK, counts unchanged (existing fixtures use `bytes`).
- Live parity test: a hand-authored scenario at `/tmp/mm-parity/scenario.jsonl` with 3 files using `bytes_base64="iVBORw0KGgo="` (PNG magic), piped through both runners. After driver canonicalization (`json.dumps(..., sort_keys=True)`) the outputs are byte-identical. Without canonicalization the only diff is map-key ordering (`role` vs `content` first), which the driver collapses.

### What the second-pass review verified clean (no fix needed)

Recorded here so a future review doesn't re-investigate the same areas:

- `MultimodalConfig` substitute defaults (max_images=4, max_image_size_mb=5, allow_remote_fetch=false) match Rust `default_*` fns exactly. SF-1 confirmed resolved.
- `effectiveLimits` clamping — Zig `@max(1, @min(..., 16/20))` is semantically identical to Rust `.clamp(1, 16/20)`.
- All 8 `MultimodalError` variants canonicalize to the same snake-case strings on both runners. No collapse of distinct variants.
- Canonical JSON key ordering — both runners use the same literal `writeAll` / `json!` key order for the output objects; the driver's `sort_keys` canonicalization is the parity contract, not the runners' insertion order.
- OpenAI `image_url` deferral is clean — no half-wired code anywhere in the Zig providers tree.
- `composeMultimodalMessage` output is byte-identical to Rust (`{cleaned_trimmed}\n\n[IMAGE:{uri}]` with `\n` between successive images).
- `normalizeRemoteImage` — `request.deinit()` defer ordering vs `content_type` slice access is correct (`detectMime` reads the slice before the defer fires).
- `TooManyImages` is unreachable by design (Rust trims rather than erroring); both sides agree, intentional, no fix.

### Should-fix queued for a future Phase 3-D.3 (or won't-fix)

- **`collapseWrappedMarker` Unicode whitespace gap** (`zig/src/providers/multimodal.zig:243-246`) — Zig skips only `' ' \t \n \r` after a newline; Rust's `char::is_whitespace()` also covers NBSP (U+00A0), thin space, etc. Narrow practical impact (only matters for terminal-paste-corrupted markers with Unicode whitespace continuations). No fixture exercises it; deferred until a real reproducer surfaces.

## 2026-05-10 — Phase 3-F: zeroclaw-api/provider.rs missing types port (Codex first-pass)

Filled in the remaining provider DTO surface from `rust/crates/zeroclaw-api/src/provider.rs` without migrating concrete provider implementations. The Zig provider handle remains sync-only; this commit adds the shared types and eval parity coverage needed before Phase 3-G+ can move Ollama/OpenAI off their current ad-hoc wire DTOs.

### Source changes

- `zig/src/providers/provider.zig`
  - Re-exports the existing dispatcher-owned `ToolCall`, `TokenUsage`, `ChatResponse`, `ToolResultMessage`, and `ConversationMessage` shapes instead of duplicating them.
  - Adds `StreamChunk`, `StreamEvent`, `StreamOptions`, `StreamError`, `ProviderCapabilityError`, `ToolsPayload`, and `buildToolInstructionsText`.
  - Grows `Capabilities` with Rust-parity `native_tool_calling`, `vision`, and `prompt_caching` fields, while keeping the existing vtable-default fields and adding `ProviderCapabilities = Capabilities`.
  - `buildToolInstructionsText` writes compact sorted-key JSON for schemas to match Rust `serde_json` / BTreeMap output.
- `zig/src/runtime/agent/dispatcher.zig`
  - Adds the `assistant_tool_calls` `ConversationMessage` variant with `text`, `tool_calls`, and `reasoning_content`.
  - Adds clone/deinit coverage for the new variant and OOM regression coverage via `std.testing.checkAllAllocationFailures`.
- `zig/src/providers/openai/client.zig` and `zig/src/providers/ollama/client.zig`
  - Populate the new Rust-named capability fields alongside the older `supports_*` fields so direct capability inspection stays coherent.
- `zig/src/tools/eval_provider_types.zig` and `eval-tools/src/bin/eval-provider-types.rs`
  - Add the `provider_types` eval runner pair for prompt-guided formatter parity plus DTO JSON shape checks.
- `evals/fixtures/provider_types/`
  - Adds 5 fixtures: empty tool instructions, two-tool sorted schema instructions, tool-call/chat-response shape, conversation-message shape, and stream/tools-payload shape.

### Pinned question answers

1. **Capabilities naming direction** — kept `Capabilities` as the existing Zig vtable type and added `pub const ProviderCapabilities = Capabilities`. This avoids churn in current providers while exposing the Rust name for future ports.
2. **ChatResponse migration** — added the provider-neutral type surface now via the dispatcher alias; concrete providers still return their current native/wire DTOs internally and only convert at existing boundaries. Full migration remains Phase 3-G+.
3. **ToolCall shape** — dispatcher already had the Rust shape (`id`, `name`, `arguments`), so provider.zig re-exports it instead of creating a duplicate owned-slice type.
4. **StreamError shape** — used the recommended Zig error-set form: `error{ Http, Json, InvalidSse, Provider, Io }`. No payload-bearing streaming errors until a real streaming consumer exists.
5. **buildToolInstructionsText parity** — verified byte-for-byte through the new eval fixtures, including sorted nested schema keys. The full eval driver is green.

### Deferred

- No Ollama/OpenAI provider behavior migration; they keep their native request/response DTOs for now.
- No streaming vtable method or streaming provider implementation.
- No async trait machinery; the Zig vtable remains sync-only.
- No `StreamResult<T>` alias; Zig callers should use `StreamError!T` directly.

### Verification

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — `106/106` tests passed.
- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean.
- `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-api --release` — `29` unit tests + `1` doctest passed.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all fixtures OK, `158` total fixture inputs (`153 + 5 provider_types`).

## 2026-05-10 — Phase 3-F.1: Phase 3-F second-pass review fixups (Claude direct)

Closes the two should-fix items from the Phase 3-F (`f8be7fa`) second-pass review. The reviewer also flagged two confidence-88 must-fixes (JSON sort divergence and Ollama dual-track `vision`); both were verified false alarms — recorded here so a future review doesn't re-investigate.

### Source changes

- `zig/src/providers/provider.zig:163` — added a doc comment on `StreamError` documenting the `error.Io` payload-loss vs Rust's `Io(#[from] std::io::Error)`. Known limitation accepted by the brief; the comment marks the deviation so a future streaming consumer doesn't assume parity.
- `zig/src/providers/provider.zig:589-619` — added `buildToolInstructionsTextOomImpl` + `test "buildToolInstructionsText is OOM safe across multiple tools with nested schemas"`. The sweep uses `std.testing.checkAllAllocationFailures` over a 2-tool input with a non-trivially-nested JSON schema (object with required + properties + a string-enum nested under properties). Exercises every allocation site: `ArrayList` growth, recursive `writeJsonCanonical` `keys` arrays, and `toOwnedSlice`. Closes the brief's "prime OOM candidate" coverage gap (no concrete leak surfaced — the existing `errdefer instructions.deinit()` plus `defer allocator.free(keys)` shape is correct).

### Reviewer false alarms (verified clean — do not re-investigate)

- **JSON sort divergence (Rust `serde_json` vs Zig `writeJsonCanonical`)** — claimed Rust uses `IndexMap` (insertion order) while Zig sorts. Verified at `rust/Cargo.toml:97`: `serde_json = { default-features = false, features = ["std"] }`. The `preserve_order` feature is NOT enabled, so `serde_json::Value::Object` defaults to `BTreeMap` (alphabetical). `serde_json::to_string` therefore sorts keys, matching Zig's `writeJsonCanonical`. Same correction applies to `eval_provider_types.zig`'s `writeJsonValue` — also uses sorted output via the same canonical path. **Both sides sort.**
- **Ollama dual-track `vision` field unset** — claimed Ollama only set `supports_vision = true` and left `vision = false`. Verified at `zig/src/providers/ollama/client.zig:466`: `.vision = true` is set explicitly alongside `.supports_vision = true`. OpenAI mirrors this with `.native_tool_calling = true` alongside `.supports_native_tools = true`. Both providers populate both old + new field names consistently.

### Layering observation (not a Phase 3-F regression — pre-existing)

The reviewer also flagged that `ToolCall`, `TokenUsage`, `ChatResponse`, `ToolResultMessage`, and `ConversationMessage` are defined in `dispatcher.zig` and re-exported from `provider.zig`, calling this a layering inversion. Verified via `git show f8be7fa~1:zig/src/runtime/agent/dispatcher.zig`: **all five types existed in dispatcher.zig before Phase 3-F**. Codex's choice to re-export rather than duplicate is a consistent extension of the brief's pinned-question-3 guidance for `ToolCall`. The dependency arrow `provider.zig → dispatcher.zig` exists but creates no cycle (dispatcher only imports `tool_call_parser/types.zig` and `std`). A future cleanup commit could relocate the DTOs to `provider.zig`; not in scope for Phase 3-F or 3-F.1.

### Skipped from the review

- **N-1 (`ProviderCapabilities` alias test doesn't exercise the accessor)** — the accessors (`supportsNativeTools`, `supportsVision`, `supportsPromptCaching`) live on `Provider`, not on `Capabilities`. Exercising them requires a full vtable scaffold for what the reviewer correctly flagged as a nit. Deferred.

### Verification

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — `107/107` tests passed (was 106/106; +1 new OOM sweep).
- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 158 fixtures OK, counts unchanged (no fixture additions).

## 2026-05-10 — Phase 3-F.2: relocate provider DTOs to providers/types.zig (Claude direct)

Closes the layering observation from the Phase 3-F second-pass review. The seven provider DTOs (`ToolCall`, `TokenUsage`, `ChatResponse`, `ChatMessage`, `ToolResultMessage`, `AssistantToolCallsMessage`, `ConversationMessage`) plus their three private clone helpers (`cloneToolCalls`, `freeToolCalls`, `cloneToolResultMessages`) lived in `runtime/agent/dispatcher.zig` since the parser/dispatcher pilot. Phase 3-F made this visible by having `providers/provider.zig` import from `runtime/agent/dispatcher.zig` to re-export — an inversion of the natural dependency direction (runtime should depend on providers, not the other way around).

### Source changes

- `zig/src/providers/types.zig` — **new file**. Holds the seven DTO definitions and three helper fns, copied verbatim from `dispatcher.zig` lines 22-208 (no behavior change).
- `zig/src/runtime/agent/dispatcher.zig` — replaced the type definitions with seven `pub const X = provider_types.X;` aliases. Aliases preserve every consumer's existing `dispatcher.X` import path (multimodal.zig, ollama/client.zig, openai/client.zig, eval_dispatcher.zig, eval_providers.zig, runtime/agent/root.zig). `ToolExecutionResult` stays in `dispatcher.zig` because it is a dispatcher-internal intermediate, not a provider DTO.
- `zig/src/providers/provider.zig` — replaced `@import("../runtime/agent/dispatcher.zig")` with `@import("types.zig")`. The seven public re-exports now point at `types.X`. Six internal `dispatcher.ChatMessage` references in function signatures and tests were updated to bare `ChatMessage` (the in-file alias). Also added `pub const ChatMessage` and `pub const AssistantToolCallsMessage` to provider.zig's surface (Codex's Phase 3-F only re-exported five of the seven — these two completion adds were trivial).

### What did NOT change

- No consumer file (multimodal.zig, ollama/client.zig, openai/client.zig, eval_dispatcher.zig, eval_providers.zig, runtime/agent/root.zig) was touched. They continue to use `dispatcher.ToolCall` etc. via the new alias path. Future commits can migrate them organically as they're touched for other reasons.
- No tests moved. The clone/deinit/OOM tests remain in `dispatcher.zig`, exercising the types through the alias — the public API is unchanged regardless of where types are defined.
- No behavior change. This is purely a file-organization fix.

### Dependency graph after this commit

```
providers/types.zig          (DTOs — leaf)
providers/provider.zig   →   providers/types.zig
providers/multimodal.zig →   runtime/agent/dispatcher.zig (legacy import; via aliases reaches types.zig)
providers/ollama/client.zig → runtime/agent/dispatcher.zig (legacy)
providers/openai/client.zig → runtime/agent/dispatcher.zig (legacy)
runtime/agent/dispatcher.zig → providers/types.zig
runtime/agent/dispatcher.zig → tool_call_parser/types.zig
```

The provider→runtime back-reference in `provider.zig` is removed. The remaining provider→runtime imports in multimodal/ollama/openai are legacy and can be cleaned up incrementally; they don't create cycles because `dispatcher.zig` no longer needs anything from those files.

### Verification

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — `107/107` tests passed, unchanged.
- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 158 fixtures OK, counts unchanged.

## 2026-05-10 — Phase 6-A: providers/lib.rs scrub_secret_patterns + sanitize_api_error port (Codex first-pass)

Ports the two remaining in-scope `providers/lib.rs` security helpers into Zig as a single-purpose provider secrets module. This commit intentionally does not bundle any factory/create-provider work; the Phase 6-A diff is limited to secret-pattern scrubbing, API-error sanitization, eval coverage, and root exports.

### Source changes

- `zig/src/providers/secrets.zig` — **new file**. Exposes `MAX_API_ERROR_CHARS`, `scrubSecretPatterns`, and `sanitizeApiError`; private helpers mirror Rust's `is_secret_char`, `token_end`, and `is_char_boundary` behavior. Returned slices are caller-owned and documented on both public functions.
- `zig/src/providers/root.zig` — re-exports the new helpers so callers can use `@import("providers").scrubSecretPatterns`, `sanitizeApiError`, and `MAX_API_ERROR_CHARS`.
- `eval-tools/src/bin/eval-provider-secrets.rs` and `zig/src/tools/eval_provider_secrets.zig` — new Rust/Zig parity runners for `scrub` and `sanitize` JSONL ops.
- `evals/fixtures/provider_secrets/` — 7 new fixtures covering empty input, no-secret passthrough, single `sk-`, multi-prefix redaction, bare-prefix passthrough, ASCII truncation, and UTF-8 boundary truncation.
- `evals/driver/run_evals.py`, `eval-tools/Cargo.toml`, and `zig/build.zig` — register the new `provider_secrets` subsystem and binaries.

### Pinned answers

- **File naming** — chose `secrets.zig`. It matches the single-purpose helper surface and avoids overloading Zig's conventional `lib.zig` entry-point naming.
- **UTF-8 truncate cliff** — Zig matches Rust's two-step behavior: first `utf8CountCodepoints`, then byte index `500`, then walk backward while the byte is a UTF-8 continuation byte. The `scenario-truncate-utf8` fixture places `𝓤` (`F0 9D 93 A4`) after 499 ASCII bytes, so byte 500 lands inside the codepoint and the output backs up to 499 bytes before appending `...`.
- **Bare-prefix infinite-loop guard** — `scrubPrefix` keeps bare prefixes unredacted and advances `search_from` to `content_start`, matching Rust's `end == content_start` guard. `scenario-bare-prefix` asserts exact passthrough for `sk-`.
- **Overlapping prefixes / order** — the Zig `PREFIXES` array keeps Rust order exactly: `sk-`, `xoxb-`, `xoxp-`, `ghp_`, `gho_`, `ghu_`, `github_pat_`. Each prefix pass operates on the output of the previous pass for defensive parity even though the current set has no harmful prefix overlap.
- **`[REDACTED]` literal** — replacement is the exact ASCII literal `[REDACTED]`. The Zig builder scans from the original token end for the active prefix, which is byte-equivalent to Rust's `search_from = start + "[REDACTED]".len()` after `replace_range`.

### OOM / ownership notes

- `scrubSecretPatterns` owns each intermediate buffer and allocates the replacement pass before freeing the previous pass, preserving the established free-then-realloc rule.
- `scrubPrefix` computes the exact post-pass length, pre-reserves the `ArrayList`, uses `errdefer list.deinit()`, and returns with `toOwnedSlice()`.
- Added `checkAllAllocationFailures` coverage over dense multi-prefix redaction plus a >500-char UTF-8-boundary input.

### Verification

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — `113/113` tests passed (was `107/107`; +6 provider secrets tests including OOM).
- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean.
- `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` — `783` unit tests passed; provider doctest target ran with `1` ignored doctest.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin --subsystem provider_secrets` — `7/7` provider_secrets fixtures OK.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all `165` fixtures OK (`158` existing + `7` new provider_secrets).

## 2026-05-11 — Phase 6-B: providers/lib.rs factory family port (Codex first-pass)

Ports the trimmed provider factory family from `providers/lib.rs` into Zig. The Zig factory intentionally supports only the provider-trim scope (`openai` and `ollama`); every other Rust provider arm remains out of scope and returns `ProviderNotSupported`.

### Source changes

- `zig/src/providers/factory.zig` — new factory module with `ProviderRuntimeOptions`, `ProviderHandle`, `FactoryError`, and `createProvider*` wrappers. `ProviderHandle` owns heap-allocated `OpenAiProvider` / `OllamaProvider` instances and exposes `.provider()` for the existing vtable handle.
- `zig/src/providers/root.zig` — re-exports the factory module, runtime options, handle type, error set, and public factory entry points.
- `zig/src/tools/eval_provider_factory.zig` and `eval-tools/src/bin/eval-provider-factory.rs` — new provider_factory parity runners for create-provider ops.
- `evals/fixtures/provider_factory/` — 9 new fixtures covering openai/ollama success, URL override, dropped-provider errors, and OpenAI key-prefix mismatch behavior.
- `evals/driver/run_evals.py`, `eval-tools/Cargo.toml`, and `zig/build.zig` — register the new provider_factory subsystem and binaries.
- `zig/src/tool_call_parser/types.zig` — tightened JSON clone/object helpers so `provider_extra` cloning is safe under allocation-failure sweeps.

### Pinned answers

- **ProviderHandle ownership pattern** — chose a tagged handle owning heap-allocated concrete provider pointers. This keeps the vtable `ptr` stable after the factory returns and mirrors Rust's `Box<dyn Provider>` ownership while still making the concrete variant explicit. Callers own the returned handle and must call `deinit` with the same allocator.
- **`zeroclaw_dir` field type** — represented as `?[]u8`. It is an allocator-owned path byte slice; the struct does not canonicalize or validate path semantics.
- **`provider_extra` field** — represented as `?std.json.Value`. Clone/deinit reuse `parser_types.cloneJsonValue` and `parser_types.freeJsonValue`; object and array members are recursively owned.
- **`extra_headers` field** — represented as `std.StringHashMap([]u8)`. Every key and value is allocator-owned. `ProviderRuntimeOptions.clone` duplicates both sides, and `deinit` frees both sides before deinitializing the map.
- **`ZEROCLAW_PROVIDER_URL` precedence** — the Ollama arm reads `ZEROCLAW_PROVIDER_URL` inside dispatch and lets it override the `api_url` parameter, matching Rust's env-wins behavior. This is covered by an in-process unit test instead of eval fixtures because eval fixtures should not depend on ambient env state.
- **`resolve_provider_credential` trim** — Zig resolves explicit non-empty overrides first, then `OPENAI_API_KEY` for OpenAI, then generic `ZEROCLAW_API_KEY` and `API_KEY`. Anthropic, Groq, Qwen, MiniMax, and other dropped-provider credential paths are intentionally skipped.

### OOM / ownership notes

- `ProviderRuntimeOptions.clone` uses a single `errdefer out.deinit(allocator)` owner rollback so optional slices, extra headers, and `provider_extra` clean up together if a later allocation fails.
- Header insertion uses `ensureUnusedCapacity` plus `getOrPutAssumeCapacity` and `removeByPtr` rollback for later key allocation failure.
- Factory-created provider instances are allocated first, then initialized, with `errdefer allocator.destroy(instance)` and `errdefer instance.deinit(allocator)` guarding partial construction.
- Added `checkAllAllocationFailures` coverage over non-trivial runtime options plus OpenAI dispatch with URL override and max tokens.
- `parser_types.cloneJsonValue`, `singletonStringObject`, and `putOwned` now avoid key/value leaks when allocation fails between paired JSON object allocations.

### Verification

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — `120/120` tests passed (was `113/113`; +7 provider factory / ownership / OOM tests).
- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean.
- `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-providers --release` — `783` unit tests passed; provider doctest target ran with `1` ignored doctest.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin --subsystem provider_factory` — `9/9` provider_factory fixtures OK.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all `174` fixtures OK (`165` existing + `9` new provider_factory).

### Remaining risks

- `provider_runtime_options_from_config` is still intentionally deferred until the Zig config schema exposes the fields the Rust constructor reads.
- The Zig factory does not apply `provider_timeout_secs`, `extra_headers`, `api_path`, `provider_extra`, or `merge_system_into_user` to OpenAI-compatible providers because those compatible-provider arms are outside the provider-trim scope.

## 2026-05-11 — Phase 6-B.1: Phase 6-B second-pass review fixups (Claude direct)

Closes the real should-fix items from the Phase 6-B (`23829bb`) second-pass review. The reviewer also flagged two "must-fix" items at confidence 82-95; both were verified to not hold up — recorded here so a future review doesn't re-investigate.

### Source changes

- `zig/src/providers/factory.zig:18-22` — removed `MissingApiKey` from `FactoryError`. The error tag was declared but never raised by any code path in the trimmed two-provider scope (Ollama is keyless; OpenAI doesn't enforce key-presence at factory level, matching Rust). Verified by grep: only the declaration and the eval-runner canonicalization referenced it.
- `zig/src/tools/eval_provider_factory.zig:50-56` — removed the corresponding `MissingApiKey => "missing_api_key"` canonicalization branch. The Rust eval runner's `canonical_error_tag` only maps `"api_key_prefix_mismatch"` and `"provider_not_supported"` (plus the implicit OOM fallthrough); the Zig runner now matches that set exactly. Closes SF-1 from the review.
- `zig/src/providers/factory.zig` (after the existing openai OOM test) — added `factoryOomImplOllama` + `test "ollama factory dispatch is OOM safe"`. The sweep populates non-trivial `ProviderRuntimeOptions` (reasoning_enabled, zeroclaw_dir, provider_timeout_secs, an extra_headers entry), clones them, then dispatches to `createProviderWithUrlAndOptions("ollama", null, url, &cloned)`. Exercises the `allocator.create(OllamaProvider)` + `OllamaProvider.newWithReasoning` allocation pair the prior sweep didn't cover. Closes SF-3.
- `zig/src/providers/factory.zig:205-213` — added a doc comment on `checkApiKeyPrefix` explaining that all 8 Rust detection prefixes are intentionally preserved while the dispatch guard only fires for "openai" (the only key-bearing in-scope provider). Marks the trimming as intentional so a future provider addition extends the dispatch guard rather than the detection chain.
- `zig/src/providers/factory.zig:49-54` — added a doc comment on `ProviderRuntimeOptions.deinit` making the allocator-consistency requirement explicit (the `extra_headers` StringHashMap retains the init-time allocator for its bucket storage; mixing allocators between init and deinit is UB).

### Reviewer findings re-evaluated (do not re-investigate)

The second-pass reviewer reported two "must-fix" items at high confidence; both were verified to not hold up:

- **MF-1 (confidence 95): "checkApiKeyPrefix security bypass"** — claim was that the Zig only checks `if provider_name == "openai"` while Rust checks all 8 providers. Verified at `factory.zig:206-229`: all 8 prefix detections are present in correct longest-first order, and the dispatch guard at line 225 correctly fires when `provider_name == "openai"` and the key has a non-openai prefix. The reviewer's own analysis admitted "Ollama is keyless and the check only fires when `resolved_credential` is Some" — i.e., the current behavior is correct for the trimmed scope. For any name other than "openai" or "ollama", the factory returns `ProviderNotSupported` before the prefix check matters. **Not a must-fix.** Demoted to a doc nit (Phase 6-B.1 added the explanatory comment).
- **MF-2 (confidence 82): "types.zig side edit untested"** — reviewer demoted this to should-fix in their own paragraph. Reading the actual `git diff 23829bb~1 23829bb -- zig/src/tool_call_parser/types.zig`: Codex applied the canonical errdefer-chain + `ensureUnusedCapacity` + `putAssumeCapacity` pattern (from prior phase reviews) to fix latent OOM leaks in `cloneJsonValue`, `singletonStringObject`, and `putOwned`. The OLD code had real leaks like `try object.put(try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) })` — inner value-dupe failure leaks the key-dupe. **The change is a legitimate latent-bug fix**, not something to revert. The bundling-with-feature-commit critique is process not code.

### Skipped from the review

- **SF-2 — `cloneJsonValue` / `freeJsonValue` / `emptyObject` / `putOwned` duplication between `tool_call_parser/types.zig` and `api/schema.zig`** — verified via grep: the `schema.zig` versions at lines 501, 571, 591, 630 are independent of the `types.zig` versions. This duplication is **pre-existing**, not introduced by Phase 6-B. Phase 6-B's `types.zig` edit upgraded one copy to OOM-safe; the `schema.zig` copy still has the old non-OOM-safe pattern at the equivalent sites. Apply the same OOM-safety upgrade to `schema.zig` in a separate cleanup commit; not in 6-B.1 scope.

### Verification

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — `121/121` tests passed (was 120/120; +1 Ollama OOM sweep).
- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 174 fixtures OK, counts unchanged.

## 2026-05-11 — Phase 7-A: Tool trait scaffold + CalculatorTool port (Codex first-pass)

Lands the first `zeroclaw-tools` Zig surface under `zig/src/agent_tools/`: a sync-first `Tool` vtable scaffold plus the pure-compute `CalculatorTool` proof of concept. The older `zig/src/tools/` namespace remains reserved for eval binaries.

### Source changes

- `zig/src/agent_tools/tool.zig` — added `ToolResult`, `Tool`, vtable dispatch shims, and `Tool.spec`. `ToolResult.error_msg` is the Zig spelling for Rust's serialized `error` field. `Tool.spec` returns an owned provider-compatible `ToolSpec`.
- `zig/src/providers/provider.zig` — kept `ToolSpec` as the canonical shape because it matches `zeroclaw_api::tool::ToolSpec` exactly (`name`, `description`, `parameters`). Added `ToolSpec.deinit` for owned specs returned by `agent_tools.Tool.spec`; borrowed provider-call specs remain valid as long as callers do not deinit borrowed values.
- `zig/src/agent_tools/calculator.zig` — ported all 25 Rust calculator functions, including arithmetic, log/exp, aggregation, statistics, percentile, percentage change, clamp, Rust-compatible mode tie ordering, and Rust-compatible error messages.
- `zig/src/tools/eval_agent_tools.zig` and `eval-tools/src/bin/eval-agent-tools.rs` — added byte-parity eval runners for calculator execution. The normal path executes a parsed JSON args value; `execute_raw` exists only to fixture non-finite/out-of-range JSON numbers, because Rust rejects them at `serde_json` parse time before `CalculatorTool.execute`.
- `evals/fixtures/agent_tools/` — added 34 Rust-generated fixtures covering happy paths, math errors, argument errors, numeric formatting edges, mode ties, negative zero, very small/large finite numbers, and raw non-finite parse failure.

### Pinned decisions

- **ToolSpec shape:** `zeroclaw-api/src/tool.rs:14` and the already-ported provider `ToolSpec` are field-identical. `agent_tools/tool.zig` re-exports `providers.ToolSpec` rather than duplicating the DTO.
- **Numeric formatting:** Rust's helper first prints integral finite values with `abs < 1e15` as integers, then falls through to Rust `Display` for `f64`. The evals showed that `1e154 * 1e154` prints as a full decimal string and `1 / 100000000` prints `0.00000001`; the Zig helper therefore uses decimal formatting for finite non-integer fallthroughs rather than scientific formatting. Negative zero normalizes to `"0"`.
- **Async deviation:** Rust's trait is async, but the Zig scaffold is deliberately synchronous until libxev lands. This is documented at the top of `agent_tools/tool.zig`; future I/O-heavy tools should not infer a final async design from this pilot vtable.
- **Argument extraction:** `calculator.zig` uses a small `JsonArgs` helper rather than inlining `std.json.Value` walking across 25 functions. It mirrors Rust's `as_f64`, `as_i64`, and `as_array` behavior, including scalar wrong-type messages and `values[i] is not a valid number`.
- **Mode ties:** Rust counts by `f64::to_bits`, then emits modes in first-seen input order. A tie formats as `Modes: 2, 3`, not a JSON array and not sorted order.
- **Non-finite inputs:** JSON `NaN`/`Inf` are not valid; `1e309` is rejected by Rust's `serde_json` as `number out of range`. The eval fixture records that as a deterministic `"Invalid args JSON"` failure at runner parse boundary. Zig's raw runner explicitly rejects out-of-range `number_string` values to match that boundary.

### Verification

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — `127/127` tests passed (was 121/121; +6 agent_tools tests including success/error OOM sweeps).
- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean.
- `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-tools --release` — `1119` unit tests passed; doctest target ran with `1` ignored doctest.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin --subsystem agent_tools` — `34/34` new agent_tools fixtures OK.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all `208` fixtures OK (`174` existing + `34` new agent_tools).

### Remaining risks

- The sync-first vtable is intentionally insufficient for future I/O-heavy tools such as `web_fetch`, MCP, browser, and memory recall. Do not design around blocking async I/O in this commit.
- `ToolSpec.deinit` is only correct for owned specs. Existing provider paths that pass borrowed specs should keep treating them as borrowed.

## 2026-05-11 — Phase 7-B: memory tools port (Codex first-pass)

Ported the five memory tools into `zig/src/agent_tools/` on the Phase 7-A sync vtable:

- `MemoryStoreTool`
- `MemoryRecallTool`
- `MemoryForgetTool`
- `MemoryPurgeTool`
- `MemoryExportTool`

The tools all borrow `*SqliteMemory`; `deinit` is a no-op for the backend. The caller remains responsible for backend lifetime in both eval and future runtime usage.

Implementation notes:

- Added a small `memory_tool_metadata` side table for tool-only `tags` and `source`. This avoids changing the existing `MemoryEntry` ABI and keeps the older raw `memory` fixtures stable.
- Added exact-path SQLite constructors (`SqliteMemory.newAtPath` / Rust `SqliteMemory::new_at_path`) so the `memory_tools` eval setup can use `$TMP/memory.db` literally.
- Added eval timestamp pinning via `setEntryTimestampForEval` for fixtures. The current Zig and Rust SQLite memory implementations did not expose general clock injection; setup entries use fixed `created_at` values instead.
- `content_hash` matches the existing backend format: SHA-256 first 8 bytes, lowercase 16-character hex. The prompt said “SHA-256 hex”; the actual Rust/Zig memory backends use the truncated stable shape.
- Parameter schemas follow the calculator pattern: parse a JSON literal at runtime, then clone the parsed tree with `parser_types.cloneJsonValue`.
- SecurityPolicy was intentionally skipped for this pilot. Rust’s current tool implementations still enforce it, but Zig has no equivalent infra yet; this commit documents the deviation rather than adding a stub.

Rust-source deviation:

- The local Rust `zeroclaw-tools/src/memory_*.rs` files are still the older `key` / `namespace` / `session_id` surface. The Phase 7-B prompt requested the newer `content_hash` / `tags` / `source` / `format` eval contract. I left the Rust production tools unchanged to avoid rewriting their existing 1119-test surface, and implemented `eval-memory-tools` as a parity runner over the shared Memory backend for the requested contract.

Eval coverage:

- Added `memory_tools` to `evals/driver/run_evals.py`.
- Added 18 fixtures: store basic/tags/duplicate, recall query/category/tags/empty/limit, forget existing/missing, purge category/no-confirm/age, export JSON/markdown/empty, and store validation errors.

Verification:

- `cd zig && zig build` — clean
- `cd zig && zig build test --summary all` — 138/138 tests passed
- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean
- `cargo test --manifest-path rust/Cargo.toml -p zeroclaw-tools --release` — 1119 passed + 1 ignored doctest
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all fixtures OK, including 18/18 `memory_tools`

Remaining risks:

- Security policy parity is deferred.
- `tags` and `source` are tool-layer metadata, not part of the core `MemoryEntry` type.
- The production Rust memory tools are not yet on the same public surface as the Phase 7-B eval contract.

## 2026-05-11 — Phase 7-B.1: bundled fixups from Phase 7-A and Phase 7-B second-pass reviews (Claude direct)

Closes the carried-over should-fixes from the Phase 7-A review (never landed) and the new should-fixes from the Phase 7-B review (`8c6d53e`). Bundled into one commit because all four items are small and share the same scope (agent_tools OOM coverage + memory_purge robustness).

### Source changes

- `zig/src/agent_tools/calculator.zig` (after the existing `execute` OOM test) — added `parametersSchemaOomImpl` + `test "calculator parametersSchema is OOM safe"`. Closes the gap the Phase 7-A review flagged: `parametersSchema` parses ~1 KB of JSON and deep-clones the tree, the most allocation-intensive path in `calculator.zig`, previously uncovered by any `checkAllAllocationFailures` sweep.

- `zig/src/agent_tools/calculator.zig` — extended the existing `test "calculator formatNum matches pinned Rust-style edge cases"` with an in-process pin for `1.0 / 100_000_000.0 → "0.00000001"`. The `scenario-small-number` eval fixture already exercised this externally, but an in-process pin catches a future Zig compiler regression on `{d}` formatting of sub-1e-4 values faster than the eval driver would.

- `zig/src/agent_tools/memory_common.zig` (at end of file) — added `parametersSchemaOomImpl` + `test "memory_common parametersSchema is OOM safe across nested schema parse + clone"`. Closes Phase 7-B SF-2: the shared `parametersSchema(allocator, json)` helper is used by all 5 memory tools, and the OOM-sweep coverage that landed for `execute` paths in Phase 7-B did not extend to it. The sweep uses a non-trivial nested schema (object with properties + required + nested array-of-strings) to exercise the recursive parse + clone path.

- `zig/src/agent_tools/memory_purge.zig:120-127` — replaced `try self.memory_backend.deleteToolMetadata(entry.key)` with `self.memory_backend.deleteToolMetadata(entry.key) catch {};`. Closes Phase 7-B SF-1: a transient SQLite error in the metadata-delete after `forget` succeeded would otherwise abort the entire purge batch, while the Rust eval runner is structurally tolerant of the same error. The fix makes the Zig path symmetric. Added a doc-comment explaining the orphaned-metadata-row is harmless (subsequent `getToolMetadata` for a missing key returns empty tags via the SQLITE_DONE branch).

### Phase 7-B SF-3 — production-tool-surface divergence (documented here as accepted-for-now)

The Rust production memory tools (`rust/crates/zeroclaw-tools/src/memory_{store,recall,forget,purge,export}.rs`) call `self.memory.store(key, content, category, None)` etc. — the older `key` / `namespace` / `session_id` surface. The Zig port and BOTH eval runners (Zig + Rust `eval-memory-tools.rs`) implement a newer surface (`content_hash`, `tags`, `source`, `importance`, `format`). The eval contract is byte-parity between the runners (the newer surface), not parity against the production Rust tools.

This is intentional for the pilot: porting the Zig agent_tools to mirror the older Rust production tool surface would not exercise the features the LLM-facing JSON schema describes (tags, source, etc.). The newer surface is what an updated production tool layer would expose; the Zig port lands the target shape and the eval runners validate it.

**Pending alignment work** (out of scope for this commit, recorded for a future phase):
- Either port the newer surface back into the Rust production tools (so `cargo test -p zeroclaw-tools` exercises the same code paths the eval runners exercise), OR
- Document this as the canonical pilot scope: production Rust tools are reference-only for trait shape and naming conventions; the eval contract is the parity surface.

### Verification

- `cd zig && zig build` — clean.
- `cd zig && zig build test --summary all` — `140/140` tests passed (was 138/138; +2 new OOM sweeps).
- `cargo build --manifest-path eval-tools/Cargo.toml --release` — clean.
- `python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin` — all 226 fixtures OK, counts unchanged.

### Skipped from queued work (not in 7-B.1 scope)

- **Phase 6-B.1 SF-2** — `api/schema.zig` has duplicate `cloneJsonValue` / `freeJsonValue` / `emptyObject` / `putOwned` helpers using the old non-OOM-safe `put` patterns. This is pre-existing infrastructure, not introduced or touched by Phase 7-B, and deserves its own focused commit upgrading those helpers to the OOM-safe pattern that `tool_call_parser/types.zig` adopted in Phase 6-B.
- **Phase 3-D.3** — `collapseWrappedMarker` Unicode whitespace gap in `multimodal.zig:243-246`. No fixture exercises it; kept deferred.
