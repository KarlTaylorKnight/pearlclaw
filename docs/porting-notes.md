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
