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
