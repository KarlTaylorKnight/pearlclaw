//! eval-data-management — offline data_management parity runner.

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use filetime::{set_file_mtime, FileTime};
use serde_json::{Map, Value};
use zeroclaw_api::tool::{Tool, ToolResult};
use zeroclaw_tools::data_management::DataManagementTool;

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
            anyhow::bail!("unknown data_management op: {op}");
        }

        let tool = required_string(&value, "tool")?;
        if tool != "data_management" {
            anyhow::bail!("unknown data_management tool: {tool}");
        }

        let setup = required_field(&value, "setup")?;
        apply_setup(setup)?;
        let workspace = workspace_path(setup)?;
        let retention_days = optional_u64(setup, "retention_days").unwrap_or(90);
        let args = required_field(&value, "args")?.clone();
        let mut result = DataManagementTool::new(workspace, retention_days)
            .execute(args)
            .await?;
        normalize_output(&mut result)?;
        write_execute_result(&mut output, tool, result)?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn apply_setup(setup: &Value) -> Result<()> {
    if let Some(workspace) = optional_string(setup, "workspace") {
        std::fs::create_dir_all(workspace)?;
    }

    if let Some(home) = optional_string(setup, "home") {
        std::fs::create_dir_all(home)?;
        std::env::set_var("HOME", home);
    }

    if let Some(files) = setup.get("files") {
        let files = files.as_array().context("setup files must be an array")?;
        for file in files {
            let path = required_string(file, "path")?;
            let content = required_string(file, "content")?;
            if let Some(parent) = Path::new(path).parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(path, content)?;
        }
    }

    if let Some(file_mtimes) = setup.get("file_mtimes") {
        let file_mtimes = file_mtimes
            .as_object()
            .context("setup file_mtimes must be an object")?;
        for (path, epoch) in file_mtimes {
            let epoch = epoch
                .as_i64()
                .or_else(|| epoch.as_u64().and_then(|v| i64::try_from(v).ok()))
                .context("file_mtimes values must be integer unix timestamps")?;
            set_file_mtime(path, FileTime::from_unix_time(epoch, 0))?;
        }
    }

    Ok(())
}

fn workspace_path(setup: &Value) -> Result<PathBuf> {
    optional_string(setup, "workspace")
        .map(PathBuf::from)
        .or_else(|| optional_string(setup, "home").map(PathBuf::from))
        .context("setup workspace missing")
}

fn normalize_output(result: &mut ToolResult) -> Result<()> {
    let Ok(mut value) = serde_json::from_str::<Value>(&result.output) else {
        return Ok(());
    };
    if let Some(subdirectories) = value
        .get_mut("subdirectories")
        .and_then(Value::as_object_mut)
    {
        let mut entries: Vec<_> = std::mem::take(subdirectories).into_iter().collect();
        entries.sort_by(|(left, _), (right, _)| left.cmp(right));
        for (key, value) in entries {
            subdirectories.insert(key, value);
        }
    }
    result.output = serde_json::to_string(&value)?;
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

fn optional_string<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn optional_u64(value: &Value, key: &str) -> Option<u64> {
    value.get(key).and_then(Value::as_u64)
}
