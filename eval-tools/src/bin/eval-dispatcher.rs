//! eval-dispatcher — language-agnostic dispatcher pilot eval runner.
//!
//! Reads JSONL ops from stdin, runs each through XmlToolDispatcher or
//! NativeToolDispatcher, writes one canonical-JSON response per data-returning
//! op to stdout. Mirrors zig/src/tools/eval_dispatcher.zig.

use std::io::{self, Read, Write};

use anyhow::{Context, Result};
use serde_json::Value;
use zeroclaw_providers::{ChatResponse, ToolCall};
use zeroclaw_runtime::agent::dispatcher::{
    NativeToolDispatcher, ParsedToolCall, ToolDispatcher, ToolExecutionResult, XmlToolDispatcher,
};

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
        let dispatcher_kind = op_value
            .get("dispatcher")
            .and_then(Value::as_str)
            .context("dispatcher missing")?;
        let dispatcher = make_dispatcher(dispatcher_kind)?;

        match op {
            "parse_response" => {
                let response = chat_response_from_json(&op_value)?;
                let (text, calls) = dispatcher.parse_response(&response);
                let calls_json: Vec<Value> = calls.iter().map(parsed_call_to_json).collect();
                let result = serde_json::json!({"text": text, "calls": calls_json});
                write_result(&mut output, op, result);
            }
            "format_results" => {
                let results = tool_execution_results_from_json(&op_value)?;
                let msg = dispatcher.format_results(&results);
                write_result(&mut output, op, serde_json::to_value(msg)?);
            }
            "should_send_tool_specs" => {
                write_result(
                    &mut output,
                    op,
                    serde_json::json!(dispatcher.should_send_tool_specs()),
                );
            }
            _ => anyhow::bail!("unknown op: {op}"),
        }
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn make_dispatcher(kind: &str) -> Result<Box<dyn ToolDispatcher>> {
    match kind {
        "xml" => Ok(Box::new(XmlToolDispatcher)),
        "native" => Ok(Box::new(NativeToolDispatcher)),
        _ => anyhow::bail!("unknown dispatcher kind: {kind}"),
    }
}

fn chat_response_from_json(op: &Value) -> Result<ChatResponse> {
    let response = op.get("response").context("response missing")?;
    let text = response
        .get("text")
        .and_then(Value::as_str)
        .map(String::from);
    let tool_calls: Vec<ToolCall> = if let Some(arr) =
        response.get("tool_calls").and_then(Value::as_array)
    {
        arr.iter()
            .map(|tc| -> Result<ToolCall> {
                Ok(ToolCall {
                    id: tc
                        .get("id")
                        .and_then(Value::as_str)
                        .context("tool_call.id missing")?
                        .to_string(),
                    name: tc
                        .get("name")
                        .and_then(Value::as_str)
                        .context("tool_call.name missing")?
                        .to_string(),
                    arguments: tc
                        .get("arguments")
                        .and_then(Value::as_str)
                        .context("tool_call.arguments missing")?
                        .to_string(),
                })
            })
            .collect::<Result<Vec<_>>>()?
    } else {
        Vec::new()
    };
    Ok(ChatResponse {
        text,
        tool_calls,
        usage: None,
        reasoning_content: None,
    })
}

fn tool_execution_results_from_json(op: &Value) -> Result<Vec<ToolExecutionResult>> {
    let arr = op
        .get("results")
        .and_then(Value::as_array)
        .context("results missing")?;
    arr.iter()
        .map(|r| -> Result<ToolExecutionResult> {
            Ok(ToolExecutionResult {
                name: r
                    .get("name")
                    .and_then(Value::as_str)
                    .context("name missing")?
                    .to_string(),
                output: r
                    .get("output")
                    .and_then(Value::as_str)
                    .context("output missing")?
                    .to_string(),
                success: r
                    .get("success")
                    .and_then(Value::as_bool)
                    .context("success missing")?,
                tool_call_id: r
                    .get("tool_call_id")
                    .and_then(Value::as_str)
                    .map(String::from),
            })
        })
        .collect()
}

fn parsed_call_to_json(call: &ParsedToolCall) -> Value {
    serde_json::json!({
        "name": call.name,
        "arguments": call.arguments,
        "tool_call_id": call.tool_call_id,
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
