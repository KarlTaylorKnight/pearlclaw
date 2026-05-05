//! eval-providers — offline provider eval runner.
//!
//! Reads JSONL provider ops from stdin, runs deterministic Ollama Phase 1
//! helpers, writes one canonical JSON response per op to stdout.

use std::io::{self, Read, Write};

use anyhow::{Context, Result};
use serde_json::Value;
use zeroclaw_providers::ollama::{Message, OllamaFunction, OllamaProvider, OllamaToolCall};
use zeroclaw_providers::{ChatResponse, ToolCall};

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

        match op {
            "normalize_base_url" => {
                let raw_url = op_value
                    .get("raw_url")
                    .and_then(Value::as_str)
                    .context("raw_url missing")?;
                write_result(
                    &mut output,
                    op,
                    serde_json::json!(OllamaProvider::normalize_base_url(raw_url)),
                );
            }
            "strip_think_tags" => {
                let text = op_value
                    .get("text")
                    .and_then(Value::as_str)
                    .context("text missing")?;
                write_result(
                    &mut output,
                    op,
                    serde_json::json!(OllamaProvider::strip_think_tags(text)),
                );
            }
            "effective_content" => {
                let content = op_value
                    .get("content")
                    .and_then(Value::as_str)
                    .context("content missing")?;
                let thinking = op_value.get("thinking").and_then(Value::as_str);
                write_result(
                    &mut output,
                    op,
                    serde_json::to_value(OllamaProvider::effective_content(content, thinking))?,
                );
            }
            "build_chat_request" => {
                let result = run_build_chat_request(&op_value)?;
                write_result(&mut output, op, result);
            }
            "parse_chat_response" => {
                let body = op_value
                    .get("body")
                    .and_then(Value::as_str)
                    .context("body missing")?;
                let response = OllamaProvider::parse_chat_response_body(body)?;
                write_result(&mut output, op, chat_response_to_json(&response));
            }
            "format_tool_calls_for_loop" => {
                let provider = OllamaProvider::new(None, None);
                let calls = tool_calls_from_json(&op_value)?;
                write_result(
                    &mut output,
                    op,
                    serde_json::json!(provider.format_tool_calls_for_loop(&calls)),
                );
            }
            _ => anyhow::bail!("unknown op: {op}"),
        }
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn run_build_chat_request(op: &Value) -> Result<Value> {
    let model = op
        .get("model")
        .and_then(Value::as_str)
        .context("model missing")?;
    let message = op
        .get("message")
        .and_then(Value::as_str)
        .context("message missing")?;
    let temperature = op
        .get("temperature")
        .and_then(Value::as_f64)
        .context("temperature missing")?;
    let think = op.get("think").and_then(Value::as_bool);
    let tools: Option<Vec<Value>> = match op.get("tools") {
        Some(Value::Null) | None => None,
        Some(Value::Array(items)) => Some(items.clone()),
        _ => anyhow::bail!("tools must be array or null"),
    };

    let mut messages = Vec::new();
    if let Some(system) = op.get("system").and_then(Value::as_str) {
        messages.push(Message {
            role: "system".to_string(),
            content: Some(system.to_string()),
            images: None,
            tool_calls: None,
            tool_name: None,
        });
    }
    messages.push(Message {
        role: "user".to_string(),
        content: Some(message.to_string()),
        images: None,
        tool_calls: None,
        tool_name: None,
    });

    let provider = OllamaProvider::new(None, None);
    let request =
        provider.build_chat_request_with_think(messages, model, temperature, tools.as_deref(), think);
    Ok(serde_json::to_value(request)?)
}

fn tool_calls_from_json(op: &Value) -> Result<Vec<OllamaToolCall>> {
    let arr = op
        .get("tool_calls")
        .and_then(Value::as_array)
        .context("tool_calls missing")?;
    arr.iter()
        .map(|entry| -> Result<OllamaToolCall> {
            let name = entry
                .get("name")
                .and_then(Value::as_str)
                .context("tool_call.name missing")?;
            let arguments = entry
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}));
            Ok(OllamaToolCall {
                id: entry.get("id").and_then(Value::as_str).map(String::from),
                function: OllamaFunction {
                    name: name.to_string(),
                    arguments,
                },
            })
        })
        .collect()
}

fn chat_response_to_json(response: &ChatResponse) -> Value {
    serde_json::json!({
        "text": response.text,
        "tool_calls": response.tool_calls.iter().map(tool_call_to_json).collect::<Vec<_>>(),
        "usage": response.usage.as_ref().map(|usage| serde_json::json!({
            "input_tokens": usage.input_tokens,
            "output_tokens": usage.output_tokens,
            "cached_input_tokens": usage.cached_input_tokens,
        })),
        "reasoning_content": response.reasoning_content,
    })
}

fn tool_call_to_json(call: &ToolCall) -> Value {
    serde_json::json!({
        "id": call.id,
        "name": call.name,
        "arguments": call.arguments,
    })
}

fn write_result(output: &mut Vec<u8>, op: &str, result: Value) {
    let value = serde_json::json!({"op": op, "result": result});
    output.extend_from_slice(canonical_dump(&value).as_bytes());
    output.push(b'\n');
}

fn canonical_dump(value: &Value) -> String {
    match value {
        Value::Null => "null".to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => serde_json::to_string(s).unwrap(),
        Value::Array(arr) => {
            let items: Vec<String> = arr.iter().map(canonical_dump).collect();
            format!("[{}]", items.join(","))
        }
        Value::Object(obj) => {
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
