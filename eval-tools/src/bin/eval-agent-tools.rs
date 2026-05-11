//! eval-agent-tools — offline agent tool execution parity runner.

use std::io::{self, Read, Write};

use anyhow::{Context, Result};
use serde_json::{Map, Value};
use zeroclaw_api::tool::Tool;
use zeroclaw_tools::calculator::CalculatorTool;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let mut output = Vec::new();
    let tool = CalculatorTool::new();

    for raw_line in input.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let value: Value = serde_json::from_str(line).context("invalid scenario JSON")?;
        let op = required_string(&value, "op")?;
        match op {
            "execute" => {
                let label = required_string(&value, "function")?;
                let args = required_field(&value, "args")?.clone();
                let result = tool.execute(args).await?;
                write_execute_result(&mut output, label, result)?;
            }
            "execute_raw" => {
                let label = required_string(&value, "function")?;
                let args_json = required_string(&value, "args_json")?;
                match serde_json::from_str::<Value>(args_json) {
                    Ok(args) => {
                        let result = tool.execute(args).await?;
                        write_execute_result(&mut output, label, result)?;
                    }
                    Err(_) => write_execute_parse_error(&mut output, label)?,
                }
            }
            _ => anyhow::bail!("unknown agent_tools op: {op}"),
        }
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn write_execute_result(
    output: &mut Vec<u8>,
    label: &str,
    result: zeroclaw_api::tool::ToolResult,
) -> Result<()> {
    let mut result_obj = Map::new();
    result_obj.insert("success".to_string(), Value::Bool(result.success));
    result_obj.insert("output".to_string(), Value::String(result.output));
    if let Some(error) = result.error {
        result_obj.insert("error".to_string(), Value::String(error));
    }

    let value = serde_json::json!({
        "op": "execute",
        "function": label,
        "result": Value::Object(result_obj),
    });
    serde_json::to_writer(&mut *output, &value)?;
    output.push(b'\n');
    Ok(())
}

fn write_execute_parse_error(output: &mut Vec<u8>, label: &str) -> Result<()> {
    let value = serde_json::json!({
        "op": "execute",
        "function": label,
        "result": {
            "success": false,
            "output": "",
            "error": "Invalid args JSON",
        },
    });
    serde_json::to_writer(&mut *output, &value)?;
    output.push(b'\n');
    Ok(())
}

fn required_field<'a>(value: &'a Value, key: &str) -> Result<&'a Value> {
    value.get(key).with_context(|| format!("{key} missing"))
}

fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .with_context(|| format!("{key} missing"))
}
