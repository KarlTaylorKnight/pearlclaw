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
