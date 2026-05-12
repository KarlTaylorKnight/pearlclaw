//! eval-hardware-memory-map — offline hardware_memory_map parity runner.
//!
//! Drops the `#[cfg(feature="probe")]` probe-rs branch entirely — datasheet
//! static-lookup parity only. See docs/porting-notes.md Phase 7-G.

use std::io::{self, Read, Write};

use anyhow::{Context, Result};
use serde_json::{Map, Value};
use zeroclaw_api::tool::{Tool, ToolResult};
use zeroclaw_tools::hardware_memory_map::HardwareMemoryMapTool;

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
            anyhow::bail!("unknown hardware_memory_map op: {op}");
        }

        let tool_name = required_string(&value, "tool")?;
        if tool_name != "hardware_memory_map" {
            anyhow::bail!("unknown hardware tool: {tool_name}");
        }

        let setup = required_field(&value, "setup")?;
        let boards = collect_boards(setup)?;
        let args = required_field(&value, "args")?.clone();
        let result = HardwareMemoryMapTool::new(boards).execute(args).await?;
        write_execute_result(&mut output, tool_name, result)?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn collect_boards(setup: &Value) -> Result<Vec<String>> {
    let Some(boards) = setup.get("boards") else {
        return Ok(Vec::new());
    };
    let boards = boards
        .as_array()
        .context("setup boards must be an array")?;
    let mut out = Vec::with_capacity(boards.len());
    for board in boards {
        let s = board.as_str().context("setup boards items must be strings")?;
        out.push(s.to_string());
    }
    Ok(out)
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
