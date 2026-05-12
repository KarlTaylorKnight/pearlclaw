//! eval-report-template — offline report_template parity runner.
//!
//! Mirrors the Zig runner under `zig/src/tools/eval_report_template.zig`.
//! Each input line is `{"op":"execute","tool":"report_template","args":{...}}`;
//! the runner dispatches to the production `ReportTemplateTool`, then
//! writes a canonical `{"op":"execute","tool":"report_template","result":{...}}`
//! line to stdout.

use std::io::{self, Read, Write};

use anyhow::{Context, Result};
use serde_json::{Map, Value};
use zeroclaw_api::tool::{Tool, ToolResult};
use zeroclaw_tools::report_template_tool::ReportTemplateTool;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
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
        if op != "execute" {
            anyhow::bail!("unknown report_template op: {op}");
        }

        let tool_name = required_string(&value, "tool")?;
        if tool_name != "report_template" {
            anyhow::bail!("unknown tool: {tool_name}");
        }

        let args = required_field(&value, "args")?.clone();
        let result = match ReportTemplateTool::new().execute(args).await {
            Ok(r) => r,
            Err(err) => ToolResult {
                success: false,
                output: String::new(),
                error: Some(err.to_string()),
            },
        };
        write_execute_result(&mut output, tool_name, result)?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn write_execute_result(output: &mut Vec<u8>, tool: &str, result: ToolResult) -> Result<()> {
    let mut result_obj = Map::new();
    result_obj.insert("success".to_string(), Value::Bool(result.success));
    result_obj.insert("output".to_string(), Value::String(result.output));
    if let Some(error) = result.error {
        result_obj.insert("error".to_string(), Value::String(error));
    }

    let value = serde_json::json!({
        "op": "execute",
        "tool": tool,
        "result": Value::Object(result_obj),
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
