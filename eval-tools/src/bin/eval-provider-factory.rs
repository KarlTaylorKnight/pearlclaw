//! eval-provider-factory — trimmed provider factory parity runner.

use std::io::{self, Read, Write};

use anyhow::{Context, Result};
use serde_json::Value;
use zeroclaw_providers::create_provider_with_url;

fn main() -> Result<()> {
    // Keep the eval deterministic even when the developer shell has provider
    // credentials configured. The parent process is unaffected.
    for key in [
        "OPENAI_API_KEY",
        "ZEROCLAW_API_KEY",
        "API_KEY",
        "ZEROCLAW_PROVIDER_URL",
    ] {
        std::env::remove_var(key);
    }

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
    match op {
        "create" => {
            let name = required_string(value, "name")?;
            let api_key = optional_string(value, "api_key");
            let url = optional_string(value, "url");
            write_create_result(output, name, create_trimmed(name, api_key, url));
        }
        _ => anyhow::bail!("unknown provider_factory op: {op}"),
    }
    Ok(())
}

fn create_trimmed(
    name: &str,
    api_key: Option<&str>,
    url: Option<&str>,
) -> Result<(), &'static str> {
    match name {
        "openai" | "ollama" => create_provider_with_url(name, api_key, url)
            .map(|_| ())
            .map_err(|err| canonical_error_tag(&err.to_string())),
        _ => Err("provider_not_supported"),
    }
}

fn canonical_error_tag(message: &str) -> &'static str {
    if message.contains("API key prefix mismatch") {
        "api_key_prefix_mismatch"
    } else {
        "provider_not_supported"
    }
}

fn write_create_result(
    output: &mut Vec<u8>,
    provider_name: &str,
    result: Result<(), &'static str>,
) {
    let value = match result {
        Ok(()) => serde_json::json!({
            "op": "create",
            "result": { "ok": true, "provider_name": provider_name },
        }),
        Err(error) => serde_json::json!({
            "op": "create",
            "result": { "ok": false, "error": error },
        }),
    };
    serde_json::to_writer(&mut *output, &value).expect("serialize eval result");
    output.push(b'\n');
}

fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .with_context(|| format!("{key} missing"))
}

fn optional_string<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}
