//! eval-memory — language-agnostic SQLite memory eval runner.

use std::io::{self, Read, Write};
use std::path::Path;

use anyhow::{Context, Result};
use serde_json::Value;
use zeroclaw_memory::{ExportFilter, Memory, MemoryCategory, SqliteMemory};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;

    let mut memory: Option<SqliteMemory> = None;
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
            .context("scenario op missing")?;

        match op {
            "open" => {
                drop(memory.take());
                let path = str_field(&op_value, "path")?;
                memory = Some(SqliteMemory::new(Path::new(path))?);
            }
            "close" => {
                memory = None;
            }
            "store" => {
                let mem = active(memory.as_ref())?;
                mem.store(
                    str_field(&op_value, "key")?,
                    str_field(&op_value, "content")?,
                    category_field(&op_value, "category")?,
                    optional_str_field(&op_value, "session_id"),
                )
                .await?;
            }
            "store_with_metadata" => {
                let mem = active(memory.as_ref())?;
                mem.store_with_metadata(
                    str_field(&op_value, "key")?,
                    str_field(&op_value, "content")?,
                    category_field(&op_value, "category")?,
                    optional_str_field(&op_value, "session_id"),
                    optional_str_field(&op_value, "namespace"),
                    optional_f64_field(&op_value, "importance"),
                )
                .await?;
            }
            "recall" => {
                let mem = active(memory.as_ref())?;
                let result = mem
                    .recall(
                        str_field(&op_value, "query")?,
                        usize_field(&op_value, "limit")?,
                        optional_str_field(&op_value, "session_id"),
                        optional_str_field(&op_value, "since"),
                        optional_str_field(&op_value, "until"),
                    )
                    .await?;
                write_result(&mut output, op, serde_json::to_value(result)?)?;
            }
            "recall_namespaced" => {
                let mem = active(memory.as_ref())?;
                let result = mem
                    .recall_namespaced(
                        str_field(&op_value, "namespace")?,
                        str_field(&op_value, "query")?,
                        usize_field(&op_value, "limit")?,
                        optional_str_field(&op_value, "session_id"),
                        optional_str_field(&op_value, "since"),
                        optional_str_field(&op_value, "until"),
                    )
                    .await?;
                write_result(&mut output, op, serde_json::to_value(result)?)?;
            }
            "get" => {
                let mem = active(memory.as_ref())?;
                let result = mem.get(str_field(&op_value, "key")?).await?;
                write_result(&mut output, op, serde_json::to_value(result)?)?;
            }
            "list" => {
                let mem = active(memory.as_ref())?;
                let category = optional_category_field(&op_value, "category")?;
                let result = mem
                    .list(
                        category.as_ref(),
                        optional_str_field(&op_value, "session_id"),
                    )
                    .await?;
                write_result(&mut output, op, serde_json::to_value(result)?)?;
            }
            "forget" => {
                let mem = active(memory.as_ref())?;
                let result = mem.forget(str_field(&op_value, "key")?).await?;
                write_result(&mut output, op, serde_json::json!(result))?;
            }
            "purge_namespace" => {
                let mem = active(memory.as_ref())?;
                let result = mem
                    .purge_namespace(str_field(&op_value, "namespace")?)
                    .await?;
                write_result(&mut output, op, serde_json::json!(result))?;
            }
            "purge_session" => {
                let mem = active(memory.as_ref())?;
                let result = mem
                    .purge_session(str_field(&op_value, "session_id")?)
                    .await?;
                write_result(&mut output, op, serde_json::json!(result))?;
            }
            "count" => {
                let mem = active(memory.as_ref())?;
                write_result(&mut output, op, serde_json::json!(mem.count().await?))?;
            }
            "health" => {
                let mem = active(memory.as_ref())?;
                write_result(&mut output, op, serde_json::json!(mem.health_check().await))?;
            }
            "export" => {
                let mem = active(memory.as_ref())?;
                let filter: ExportFilter = op_value
                    .get("filter")
                    .cloned()
                    .map(serde_json::from_value)
                    .transpose()?
                    .unwrap_or_default();
                let result = mem.export(&filter).await?;
                write_result(&mut output, op, serde_json::to_value(result)?)?;
            }
            _ => anyhow::bail!("unknown scenario op: {op}"),
        }
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn active(memory: Option<&SqliteMemory>) -> Result<&SqliteMemory> {
    memory.context("scenario used memory before open")
}

fn str_field<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .with_context(|| format!("missing string field {key}"))
}

fn optional_str_field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn usize_field(value: &Value, key: &str) -> Result<usize> {
    value
        .get(key)
        .and_then(Value::as_u64)
        .map(|v| v as usize)
        .with_context(|| format!("missing usize field {key}"))
}

fn optional_f64_field(value: &Value, key: &str) -> Option<f64> {
    value.get(key).and_then(Value::as_f64)
}

fn category_field(value: &Value, key: &str) -> Result<MemoryCategory> {
    serde_json::from_value(value.get(key).context("missing category")?.clone())
        .context("invalid category")
}

fn optional_category_field(value: &Value, key: &str) -> Result<Option<MemoryCategory>> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(raw) => serde_json::from_value(raw.clone())
            .map(Some)
            .context("invalid optional category"),
    }
}

fn write_result(output: &mut Vec<u8>, op: &str, result: Value) -> Result<()> {
    let value = serde_json::json!({ "op": op, "result": result });
    output.extend_from_slice(canonical_dump(&value).as_bytes());
    output.push(b'\n');
    Ok(())
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
