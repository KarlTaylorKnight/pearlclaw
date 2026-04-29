//! eval-parser — language-agnostic parser eval runner.
//!
//! Reads a tool-call response from stdin, runs `parse_tool_calls`, writes
//! canonical JSON to stdout. Used by the eval driver to capture golden
//! fixtures and to verify byte-equal parity between Rust and Zig
//! implementations.
//!
//! Output schema:
//!   { "text": "<remaining text>", "calls": [
//!       { "name": "...", "arguments": <json value>, "tool_call_id": "..." | null }
//!   ] }

use std::io::{self, Read, Write};
use zeroclaw_tool_call_parser::{parse_tool_calls, ParsedToolCall};

fn main() {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .expect("read stdin failed");

    let (text, calls) = parse_tool_calls(&input);

    let calls_json: Vec<serde_json::Value> = calls
        .iter()
        .map(parsed_to_json)
        .collect();

    let output = serde_json::json!({
        "text": text,
        "calls": calls_json,
    });

    let canonical = canonical_dump(&output);
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    handle
        .write_all(canonical.as_bytes())
        .expect("write stdout failed");
    handle.write_all(b"\n").ok();
}

fn parsed_to_json(call: &ParsedToolCall) -> serde_json::Value {
    serde_json::json!({
        "name": call.name,
        "arguments": call.arguments,
        "tool_call_id": call.tool_call_id,
    })
}

/// Sorted-keys, no-whitespace canonical JSON encoding.
/// Matches `python -c "import json; json.dumps(obj, sort_keys=True, separators=(',',':'))"`.
fn canonical_dump(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::Null => "null".to_string(),
        serde_json::Value::Bool(b) => b.to_string(),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::String(s) => serde_json::to_string(s).unwrap(),
        serde_json::Value::Array(arr) => {
            let items: Vec<String> = arr.iter().map(canonical_dump).collect();
            format!("[{}]", items.join(","))
        }
        serde_json::Value::Object(obj) => {
            let mut keys: Vec<&String> = obj.keys().collect();
            keys.sort();
            let items: Vec<String> = keys
                .iter()
                .map(|k| {
                    format!(
                        "{}:{}",
                        serde_json::to_string(k).unwrap(),
                        canonical_dump(&obj[*k])
                    )
                })
                .collect();
            format!("{{{}}}", items.join(","))
        }
    }
}
