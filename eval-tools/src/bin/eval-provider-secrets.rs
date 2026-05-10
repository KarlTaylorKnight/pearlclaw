//! eval-provider-secrets — provider error secret-scrubbing parity runner.

use std::io::{self, Read, Write};

use anyhow::{Context, Result};
use serde_json::Value;
use zeroclaw_providers::{sanitize_api_error, scrub_secret_patterns};

fn main() -> Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let mut output = Vec::new();

    for raw_line in input.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let value: Value = serde_json::from_str(line).context("invalid scenario JSON")?;
        let op = required_string(&value, "op")?;
        run_op(&mut output, op, &value)?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn run_op(output: &mut Vec<u8>, op: &str, value: &Value) -> Result<()> {
    let input = required_string(value, "input")?;
    match op {
        "scrub" => write_result(output, op, scrub_secret_patterns(input)),
        "sanitize" => write_result(output, op, sanitize_api_error(input)),
        _ => anyhow::bail!("unknown provider_secrets op: {op}"),
    }
    Ok(())
}

fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .with_context(|| format!("{key} missing"))
}

fn write_result(output: &mut Vec<u8>, op: &str, sanitized: String) {
    let value = serde_json::json!({ "op": op, "result": { "output": sanitized } });
    serde_json::to_writer(&mut *output, &value).expect("serialize eval result");
    output.push(b'\n');
}
