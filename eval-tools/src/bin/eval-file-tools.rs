//! eval-file-tools — offline filesystem tool execution parity runner.

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use serde_json::{Map, Value};
use zeroclaw_api::tool::Tool;
use zeroclaw_config::policy::SecurityPolicy;
use zeroclaw_tools::file_edit::FileEditTool;
use zeroclaw_tools::file_write::FileWriteTool;
use zeroclaw_tools::glob_search::GlobSearchTool;

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
            anyhow::bail!("unknown file_tools op: {op}");
        }

        let tool = required_string(&value, "tool")?;
        let setup = required_field(&value, "setup")?;
        apply_setup(setup)?;
        let workspace = workspace_path(setup)?;
        let security = Arc::new(SecurityPolicy {
            allowed_roots: vec![workspace.clone()],
            workspace_dir: workspace,
            max_actions_per_hour: 1000,
            ..SecurityPolicy::default()
        });
        let args = required_field(&value, "args")?.clone();
        let result = execute_tool(security, tool, args).await?;
        write_execute_result(&mut output, tool, result)?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

async fn execute_tool(
    security: Arc<SecurityPolicy>,
    tool: &str,
    args: Value,
) -> Result<zeroclaw_api::tool::ToolResult> {
    match tool {
        "file_write" => FileWriteTool::new(security).execute(args).await,
        "file_edit" => FileEditTool::new(security).execute(args).await,
        "glob_search" => GlobSearchTool::new(security).execute(args).await,
        _ => anyhow::bail!("unknown file tool: {tool}"),
    }
}

fn apply_setup(setup: &Value) -> Result<()> {
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

    if let Some(symlinks) = setup.get("symlinks") {
        let symlinks = symlinks
            .as_array()
            .context("setup symlinks must be an array")?;
        for link in symlinks {
            let from = required_string(link, "from")?;
            let to = required_string(link, "to")?;
            if let Some(parent) = Path::new(from).parent() {
                std::fs::create_dir_all(parent)?;
            }
            #[cfg(unix)]
            std::os::unix::fs::symlink(to, from)?;
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

fn write_execute_result(
    output: &mut Vec<u8>,
    tool: &str,
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
