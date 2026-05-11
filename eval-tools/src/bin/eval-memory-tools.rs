//! eval-memory-tools — offline memory tool execution parity runner.

use std::io::{self, Read, Write};
use std::path::Path;

use anyhow::{Context, Result};
use chrono::{Duration, Utc};
use serde_json::{Map, Value};
use zeroclaw_memory::{Memory, MemoryCategory, MemoryEntry, SqliteMemory};

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
            anyhow::bail!("unknown memory_tools op: {op}");
        }

        let tool = required_string(&value, "tool")?;
        let setup = required_field(&value, "setup")?;
        let args = required_field(&value, "args")?;
        let db_path = required_string(setup, "db_path")?;
        let memory = SqliteMemory::new_at_path(Path::new(db_path))?;
        apply_setup(&memory, setup).await?;

        let result = execute_tool(&memory, tool, args).await?;
        write_execute_result(&mut output, tool, result)?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

#[derive(Debug)]
struct ToolResultLike {
    success: bool,
    output: String,
    error: Option<String>,
}

#[derive(Debug)]
struct Metadata {
    tags: Vec<String>,
    source: Option<String>,
}

async fn execute_tool(memory: &SqliteMemory, tool: &str, args: &Value) -> Result<ToolResultLike> {
    match tool {
        "memory_store" => memory_store(memory, args).await,
        "memory_recall" => memory_recall(memory, args).await,
        "memory_forget" => memory_forget(memory, args).await,
        "memory_purge" => memory_purge(memory, args).await,
        "memory_export" => memory_export(memory, args).await,
        _ => anyhow::bail!("unknown memory tool: {tool}"),
    }
}

async fn memory_store(memory: &SqliteMemory, args: &Value) -> Result<ToolResultLike> {
    let content = match required_non_empty_string(args, "content") {
        Ok(value) => value,
        Err(message) => return Ok(failure("", &message)),
    };
    let category_raw = match required_non_empty_string(args, "category") {
        Ok(value) => value,
        Err(message) => return Ok(failure("", &message)),
    };
    let tags = match optional_tags(args) {
        Ok(value) => value,
        Err(message) => return Ok(failure("", &message)),
    };
    let source = optional_string(args, "source");
    let importance = optional_f64(args, "importance");
    let hash = SqliteMemory::content_hash(content);
    let category = category_from_str(category_raw);

    memory
        .store_with_metadata(&hash, content, category, None, None, importance)
        .await?;
    set_metadata(memory, &hash, &tags, source)?;

    Ok(success(format!(
        "Stored memory {hash} in category {category_raw}"
    )))
}

async fn memory_recall(memory: &SqliteMemory, args: &Value) -> Result<ToolResultLike> {
    let query = optional_string(args, "query").unwrap_or("");
    let category_filter = optional_string(args, "category");
    let tags_filter = match optional_tags(args) {
        Ok(value) => value,
        Err(message) => return Ok(failure("", &message)),
    };
    let limit = optional_i64(args, "limit").unwrap_or(5);
    if limit < 0 {
        return Ok(failure("", "limit must be non-negative"));
    }
    let limit = limit as usize;
    let since = match optional_i64(args, "since_days") {
        Some(days) if days < 0 => return Ok(failure("", "since_days must be non-negative")),
        Some(days) => Some(timestamp_days_ago(days)),
        None => None,
    };

    let mut entries = if query.trim().is_empty() {
        let filter = zeroclaw_memory::ExportFilter {
            category: category_filter.map(category_from_str),
            since,
            ..Default::default()
        };
        memory.export(&filter).await?
    } else {
        memory
            .recall(query, limit.max(1000), None, since.as_deref(), None)
            .await?
    };

    entries.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    let output = format_recall(memory, &entries, category_filter, &tags_filter, limit)?;
    Ok(success(output))
}

async fn memory_forget(memory: &SqliteMemory, args: &Value) -> Result<ToolResultLike> {
    let hash = match required_non_empty_string(args, "content_hash") {
        Ok(value) => value,
        Err(message) => return Ok(failure("", &message)),
    };
    if memory.forget(hash).await? {
        delete_metadata(memory, hash)?;
        Ok(success(format!("Forgot memory {hash}")))
    } else {
        Ok(failure("Memory not found", "Memory not found"))
    }
}

async fn memory_purge(memory: &SqliteMemory, args: &Value) -> Result<ToolResultLike> {
    let confirm = match required_bool(args, "confirm") {
        Ok(value) => value,
        Err(message) => return Ok(failure("", &message)),
    };
    if !confirm {
        return Ok(failure("", "confirm:true required"));
    }

    let category_filter = optional_string(args, "category");
    let older_than_days = optional_i64(args, "older_than_days");
    let tags_filter = match optional_tags(args) {
        Ok(value) => value,
        Err(message) => return Ok(failure("", &message)),
    };
    if category_filter.is_none() && older_than_days.is_none() && tags_filter.is_empty() {
        return Ok(failure("", "At least one purge filter required"));
    }

    let cutoff = match older_than_days {
        Some(days) if days < 0 => {
            return Ok(failure("", "older_than_days must be non-negative"));
        }
        Some(days) => Some(timestamp_days_ago(days)),
        None => None,
    };

    let filter = zeroclaw_memory::ExportFilter {
        category: category_filter.map(category_from_str),
        ..Default::default()
    };
    let entries = memory.export(&filter).await?;

    let mut deleted = 0usize;
    for entry in entries {
        if let Some(ref cutoff) = cutoff {
            if entry.timestamp >= *cutoff {
                continue;
            }
        }
        let metadata = get_metadata(memory, &entry.key)?;
        if !tags_contain_all(&metadata.tags, &tags_filter) {
            continue;
        }
        if memory.forget(&entry.key).await? {
            delete_metadata(memory, &entry.key)?;
            deleted += 1;
        }
    }

    Ok(success(format!("Purged {deleted} memories")))
}

async fn memory_export(memory: &SqliteMemory, args: &Value) -> Result<ToolResultLike> {
    let format = match required_non_empty_string(args, "format") {
        Ok(value) => value,
        Err(message) => return Ok(failure("", &message)),
    };
    if format != "json" && format != "markdown" {
        return Ok(failure("", "format must be 'json' or 'markdown'"));
    }

    let since = match optional_i64(args, "since_days") {
        Some(days) if days < 0 => return Ok(failure("", "since_days must be non-negative")),
        Some(days) => Some(timestamp_days_ago(days)),
        None => None,
    };
    let filter = zeroclaw_memory::ExportFilter {
        category: optional_string(args, "category").map(category_from_str),
        since,
        ..Default::default()
    };
    let entries = memory.export(&filter).await?;
    let output = if format == "json" {
        format_json(memory, &entries)?
    } else {
        format_markdown(memory, &entries)?
    };
    Ok(success(output))
}

async fn apply_setup(memory: &SqliteMemory, setup: &Value) -> Result<()> {
    let Some(entries) = setup.get("entries") else {
        return Ok(());
    };
    if entries.is_null() {
        return Ok(());
    }
    let entries = entries
        .as_array()
        .context("setup entries must be an array")?;

    for entry in entries {
        let content = required_string(entry, "content")?;
        let hash = optional_string(entry, "content_hash")
            .map(str::to_owned)
            .unwrap_or_else(|| SqliteMemory::content_hash(content));
        let category = optional_string(entry, "category")
            .map(category_from_str)
            .unwrap_or(MemoryCategory::Core);
        let tags = optional_tags(entry).map_err(anyhow::Error::msg)?;
        let source = optional_string(entry, "source");
        memory
            .store_with_metadata(
                &hash,
                content,
                category,
                None,
                None,
                optional_f64(entry, "importance"),
            )
            .await?;
        set_metadata(memory, &hash, &tags, source)?;
        if let Some(timestamp) = optional_string(entry, "created_at") {
            set_timestamp(memory, &hash, timestamp)?;
        }
    }
    Ok(())
}

fn format_recall(
    memory: &SqliteMemory,
    entries: &[MemoryEntry],
    category_filter: Option<&str>,
    tags_filter: &[String],
    limit: usize,
) -> Result<String> {
    let mut out = String::new();
    let mut count = 0usize;
    for entry in entries {
        if count >= limit {
            break;
        }
        if let Some(category) = category_filter {
            if entry.category.to_string() != category {
                continue;
            }
        }
        let metadata = get_metadata(memory, &entry.key)?;
        if !tags_contain_all(&metadata.tags, tags_filter) {
            continue;
        }
        if count == 0 {
            out.push_str("content | category | tags | created_at\n");
        }
        out.push_str(&format!(
            "{} | {} | {} | {}\n",
            entry.content,
            entry.category,
            metadata.tags.join(", "),
            entry.timestamp
        ));
        count += 1;
    }
    if count == 0 {
        Ok("No memories found.".to_string())
    } else {
        Ok(out)
    }
}

fn format_json(memory: &SqliteMemory, entries: &[MemoryEntry]) -> Result<String> {
    let mut out = String::from("[");
    for (i, entry) in entries.iter().enumerate() {
        if i != 0 {
            out.push(',');
        }
        let metadata = get_metadata(memory, &entry.key)?;
        out.push_str("{\"category\":");
        out.push_str(&serde_json::to_string(&entry.category.to_string())?);
        out.push_str(",\"content\":");
        out.push_str(&serde_json::to_string(&entry.content)?);
        out.push_str(",\"content_hash\":");
        out.push_str(&serde_json::to_string(&entry.key)?);
        out.push_str(",\"created_at\":");
        out.push_str(&serde_json::to_string(&entry.timestamp)?);
        out.push_str(",\"importance\":");
        if let Some(importance) = entry.importance {
            out.push_str(&importance.to_string());
        } else {
            out.push_str("null");
        }
        out.push_str(",\"source\":");
        if let Some(source) = metadata.source {
            out.push_str(&serde_json::to_string(&source)?);
        } else {
            out.push_str("null");
        }
        out.push_str(",\"tags\":[");
        for (tag_i, tag) in metadata.tags.iter().enumerate() {
            if tag_i != 0 {
                out.push(',');
            }
            out.push_str(&serde_json::to_string(tag)?);
        }
        out.push_str("]}");
    }
    out.push(']');
    Ok(out)
}

fn format_markdown(memory: &SqliteMemory, entries: &[MemoryEntry]) -> Result<String> {
    let mut out = String::from(
        "| content_hash | category | tags | created_at | content |\n| --- | --- | --- | --- | --- |\n",
    );
    for entry in entries {
        let metadata = get_metadata(memory, &entry.key)?;
        out.push_str("| ");
        out.push_str(&markdown_escape(&entry.key));
        out.push_str(" | ");
        out.push_str(&markdown_escape(&entry.category.to_string()));
        out.push_str(" | ");
        out.push_str(&markdown_escape(&metadata.tags.join(", ")));
        out.push_str(" | ");
        out.push_str(&markdown_escape(&entry.timestamp));
        out.push_str(" | ");
        out.push_str(&markdown_escape(&entry.content));
        out.push_str(" |\n");
    }
    Ok(out)
}

fn ensure_metadata_schema(memory: &SqliteMemory) -> Result<()> {
    let conn = memory.connection().lock();
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS memory_tool_metadata (
            key       TEXT PRIMARY KEY,
            tags_json TEXT NOT NULL DEFAULT '[]',
            source    TEXT
        );",
    )?;
    Ok(())
}

fn set_metadata(
    memory: &SqliteMemory,
    key: &str,
    tags: &[String],
    source: Option<&str>,
) -> Result<()> {
    ensure_metadata_schema(memory)?;
    let tags_json = serde_json::to_string(tags)?;
    let conn = memory.connection().lock();
    conn.execute(
        "INSERT INTO memory_tool_metadata (key, tags_json, source)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(key) DO UPDATE SET
            tags_json = excluded.tags_json,
            source = excluded.source",
        (key, tags_json, source),
    )?;
    Ok(())
}

fn get_metadata(memory: &SqliteMemory, key: &str) -> Result<Metadata> {
    ensure_metadata_schema(memory)?;
    let conn = memory.connection().lock();
    let mut stmt =
        conn.prepare("SELECT tags_json, source FROM memory_tool_metadata WHERE key = ?1")?;
    let mut rows = stmt.query([key])?;
    if let Some(row) = rows.next()? {
        let tags_json: String = row.get(0)?;
        let source: Option<String> = row.get(1)?;
        let tags: Vec<String> = serde_json::from_str(&tags_json)?;
        Ok(Metadata { tags, source })
    } else {
        Ok(Metadata {
            tags: Vec::new(),
            source: None,
        })
    }
}

fn delete_metadata(memory: &SqliteMemory, key: &str) -> Result<()> {
    ensure_metadata_schema(memory)?;
    let conn = memory.connection().lock();
    conn.execute("DELETE FROM memory_tool_metadata WHERE key = ?1", [key])?;
    Ok(())
}

fn set_timestamp(memory: &SqliteMemory, key: &str, timestamp: &str) -> Result<()> {
    let conn = memory.connection().lock();
    conn.execute(
        "UPDATE memories SET created_at = ?1, updated_at = ?1 WHERE key = ?2",
        (timestamp, key),
    )?;
    Ok(())
}

fn tags_contain_all(entry_tags: &[String], required_tags: &[String]) -> bool {
    required_tags
        .iter()
        .all(|required| entry_tags.iter().any(|tag| tag == required))
}

fn markdown_escape(value: &str) -> String {
    value
        .chars()
        .map(|ch| match ch {
            '|' => "\\|".to_string(),
            '\n' | '\r' => " ".to_string(),
            _ => ch.to_string(),
        })
        .collect()
}

fn timestamp_days_ago(days: i64) -> String {
    (Utc::now() - Duration::days(days))
        .format("%Y-%m-%dT%H:%M:%SZ")
        .to_string()
}

fn category_from_str(value: &str) -> MemoryCategory {
    match value {
        "core" => MemoryCategory::Core,
        "daily" => MemoryCategory::Daily,
        "conversation" => MemoryCategory::Conversation,
        other => MemoryCategory::Custom(other.to_string()),
    }
}

fn success(output: String) -> ToolResultLike {
    ToolResultLike {
        success: true,
        output,
        error: None,
    }
}

fn failure(output: &str, error: &str) -> ToolResultLike {
    ToolResultLike {
        success: false,
        output: output.to_string(),
        error: Some(error.to_string()),
    }
}

fn required_non_empty_string<'a>(
    value: &'a Value,
    key: &str,
) -> std::result::Result<&'a str, String> {
    let Some(raw) = value.get(key).and_then(Value::as_str) else {
        return Err(format!("Missing required parameter: {key}"));
    };
    if raw.trim().is_empty() {
        return Err(format!("{key} must not be empty"));
    }
    Ok(raw)
}

fn required_bool(value: &Value, key: &str) -> std::result::Result<bool, String> {
    value
        .get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| format!("Missing required parameter: {key}"))
}

fn optional_tags(value: &Value) -> std::result::Result<Vec<String>, String> {
    let Some(raw) = value.get("tags") else {
        return Ok(Vec::new());
    };
    if raw.is_null() {
        return Ok(Vec::new());
    }
    let Some(items) = raw.as_array() else {
        return Err("Parameter 'tags' must be an array of strings".to_string());
    };
    let mut tags = Vec::with_capacity(items.len());
    for item in items {
        let Some(tag) = item.as_str() else {
            return Err("Parameter 'tags' must be an array of strings".to_string());
        };
        tags.push(tag.to_string());
    }
    Ok(tags)
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

fn optional_i64(value: &Value, key: &str) -> Option<i64> {
    value.get(key).and_then(Value::as_i64)
}

fn optional_f64(value: &Value, key: &str) -> Option<f64> {
    value.get(key).and_then(Value::as_f64)
}

fn write_execute_result(output: &mut Vec<u8>, tool: &str, result: ToolResultLike) -> Result<()> {
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
