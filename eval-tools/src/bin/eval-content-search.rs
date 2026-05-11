//! eval-content-search — offline content_search parity runner.

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use serde_json::{Map, Value};
use zeroclaw_api::tool::{Tool, ToolResult};
use zeroclaw_config::policy::SecurityPolicy;
use zeroclaw_tools::content_search::ContentSearchTool;

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
            anyhow::bail!("unknown content_search op: {op}");
        }

        let tool = required_string(&value, "tool")?;
        if tool != "content_search" {
            anyhow::bail!("unknown content search tool: {tool}");
        }

        let setup = required_field(&value, "setup")?;
        apply_setup(setup)?;
        let workspace = workspace_path(setup)?;
        let security = Arc::new(security_policy(setup, workspace));
        let args = required_field(&value, "args")?.clone();
        let result = execute_tool(security, args).await;
        write_execute_result(&mut output, tool, result)?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

async fn execute_tool(security: Arc<SecurityPolicy>, args: Value) -> ToolResult {
    match ContentSearchTool::new_with_backend(security, false)
        .execute(args)
        .await
    {
        Ok(result) => result,
        Err(err) => ToolResult {
            success: false,
            output: String::new(),
            error: Some(err.to_string()),
        },
    }
}

fn security_policy(setup: &Value, workspace: PathBuf) -> SecurityPolicy {
    let security = setup.get("security");
    let allow_absolute_under_root =
        optional_bool(security, "allow_absolute_under_root").unwrap_or(false);
    let allow_resolved_outside_workspace =
        optional_bool(security, "allow_resolved_outside_workspace").unwrap_or(false);
    let rate_limited = optional_bool(security, "rate_limited").unwrap_or(false);

    let mut forbidden_paths = SecurityPolicy::default().forbidden_paths;
    if let Some(extra_blocked_paths) = optional_string_array(security, "extra_blocked_paths") {
        forbidden_paths.extend(extra_blocked_paths);
    }

    SecurityPolicy {
        allowed_roots: if allow_absolute_under_root {
            vec![workspace.clone()]
        } else {
            Vec::new()
        },
        workspace_dir: workspace,
        workspace_only: !allow_resolved_outside_workspace,
        forbidden_paths,
        max_actions_per_hour: if rate_limited { 0 } else { 1000 },
        ..SecurityPolicy::default()
    }
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

    Ok(())
}

fn workspace_path(setup: &Value) -> Result<PathBuf> {
    optional_string(setup, "workspace")
        .map(PathBuf::from)
        .or_else(|| optional_string(setup, "home").map(PathBuf::from))
        .context("setup workspace missing")
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

fn optional_bool(value: Option<&Value>, key: &str) -> Option<bool> {
    value?.get(key).and_then(Value::as_bool)
}

fn optional_string_array(value: Option<&Value>, key: &str) -> Option<Vec<String>> {
    let items = value?.get(key)?.as_array()?;
    let mut output = Vec::with_capacity(items.len());
    for item in items {
        output.push(item.as_str()?.to_string());
    }
    Some(output)
}
