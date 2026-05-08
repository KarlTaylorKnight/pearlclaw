//! eval-schema — offline SchemaCleanr parity runner.
//!
//! Reads JSONL schema-cleaning ops from stdin and writes canonical JSONL.

use std::io::{self, Read, Write};

use anyhow::{Context, Result};
use serde_json::Value;
use zeroclaw_api::schema::{CleaningStrategy, SchemaCleanr};

fn main() -> Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let mut output = Vec::new();

    for raw_line in input.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }

        let op_value: Value = serde_json::from_str(line).context("invalid scenario JSON")?;
        let op = op_value
            .get("op")
            .and_then(Value::as_str)
            .context("op missing")?;
        let schema = op_value.get("schema").cloned().context("schema missing")?;

        match op {
            "clean_for_gemini" => {
                write_result(&mut output, op, SchemaCleanr::clean_for_gemini(schema));
            }
            "clean_for_anthropic" => {
                write_result(&mut output, op, SchemaCleanr::clean_for_anthropic(schema));
            }
            "clean_for_openai" => {
                write_result(&mut output, op, SchemaCleanr::clean_for_openai(schema));
            }
            "clean_conservative" => {
                write_result(
                    &mut output,
                    op,
                    SchemaCleanr::clean(schema, CleaningStrategy::Conservative),
                );
            }
            "validate" => {
                let result = match SchemaCleanr::validate(&schema) {
                    Ok(()) => serde_json::json!({ "ok": true }),
                    Err(_) => serde_json::json!({ "error": "InvalidSchema" }),
                };
                write_result(&mut output, op, result);
            }
            _ => anyhow::bail!("unknown schema op: {op}"),
        }
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn write_result(output: &mut Vec<u8>, op: &str, result: Value) {
    let value = serde_json::json!({"op": op, "result": result});
    output.extend_from_slice(canonical_dump(&value).as_bytes());
    output.push(b'\n');
}

fn canonical_dump(value: &Value) -> String {
    match value {
        Value::Null => "null".to_string(),
        Value::Bool(inner) => inner.to_string(),
        Value::Number(inner) => inner.to_string(),
        Value::String(inner) => serde_json::to_string(inner).unwrap(),
        Value::Array(items) => {
            let rendered: Vec<String> = items.iter().map(canonical_dump).collect();
            format!("[{}]", rendered.join(","))
        }
        Value::Object(object) => {
            let mut keys: Vec<&String> = object.keys().collect();
            keys.sort();
            let rendered: Vec<String> = keys
                .iter()
                .map(|key| {
                    format!(
                        "{}:{}",
                        serde_json::to_string(key).unwrap(),
                        canonical_dump(&object[*key])
                    )
                })
                .collect();
            format!("{{{}}}", rendered.join(","))
        }
    }
}
