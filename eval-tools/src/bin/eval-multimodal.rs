//! eval-multimodal — offline multimodal helper parity runner.

use std::fs;
use std::io::{self, Read, Write};
use std::path::Path;

use anyhow::{Context, Result};
use serde_json::Value;
use zeroclaw_api::provider::ChatMessage;
use zeroclaw_config::schema::MultimodalConfig;
use zeroclaw_providers::multimodal;

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
        run_op(&mut output, op, &value).await?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

async fn run_op(output: &mut Vec<u8>, op: &str, value: &Value) -> Result<()> {
    match op {
        "parse_image_markers" => {
            let (cleaned, refs) =
                multimodal::parse_image_markers(required_string(value, "content")?);
            write_result(
                output,
                op,
                serde_json::json!({
                    "cleaned": cleaned,
                    "refs": refs,
                }),
            );
        }
        "count_image_markers" => {
            let messages = messages_from_value(required_array(value, "messages")?)?;
            write_result(
                output,
                op,
                serde_json::json!({
                    "count": multimodal::count_image_markers(&messages),
                }),
            );
        }
        "contains_image_markers" => {
            let messages = messages_from_value(required_array(value, "messages")?)?;
            write_result(
                output,
                op,
                serde_json::json!({
                    "contains": multimodal::contains_image_markers(&messages),
                }),
            );
        }
        "extract_ollama_image_payload" => {
            write_result(
                output,
                op,
                serde_json::json!({
                    "payload": multimodal::extract_ollama_image_payload(required_string(value, "image_ref")?),
                }),
            );
        }
        "prepare_messages_for_provider" => {
            write_scenario_files(value)?;
            let messages = messages_from_value(required_array(value, "messages")?)?;
            let config = config_from_value(value)?;
            match multimodal::prepare_messages_for_provider(&messages, &config).await {
                Ok(prepared) => write_result(
                    output,
                    op,
                    serde_json::json!({
                        "contains_images": prepared.contains_images,
                        "messages": prepared.messages,
                    }),
                ),
                Err(err) => {
                    let tag = multimodal_error_tag(&err).unwrap_or("multimodal_unknown_error");
                    write_result(output, op, serde_json::json!({ "error": tag }));
                }
            }
        }
        _ => anyhow::bail!("unknown multimodal op: {op}"),
    }
    Ok(())
}

fn config_from_value(value: &Value) -> Result<MultimodalConfig> {
    let mut config = MultimodalConfig::default();
    let Some(obj) = value.get("config").and_then(Value::as_object) else {
        return Ok(config);
    };
    if let Some(max_images) = obj.get("max_images").and_then(Value::as_u64) {
        config.max_images = usize::try_from(max_images).unwrap_or(usize::MAX);
    }
    if let Some(max_image_size_mb) = obj.get("max_image_size_mb").and_then(Value::as_u64) {
        config.max_image_size_mb = usize::try_from(max_image_size_mb).unwrap_or(usize::MAX);
    }
    if let Some(allow_remote_fetch) = obj.get("allow_remote_fetch").and_then(Value::as_bool) {
        config.allow_remote_fetch = allow_remote_fetch;
    }
    Ok(config)
}

fn write_scenario_files(value: &Value) -> Result<()> {
    let Some(files) = value.get("files").and_then(Value::as_array) else {
        return Ok(());
    };
    for file in files {
        let path = Path::new(required_string(file, "path")?);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, file_bytes(file)?)?;
    }
    Ok(())
}

fn file_bytes(value: &Value) -> Result<Vec<u8>> {
    let bytes = required_array(value, "bytes")?;
    let mut out = Vec::with_capacity(bytes.len());
    for item in bytes {
        let byte = item.as_u64().context("file byte must be u8")?;
        if byte > u8::MAX as u64 {
            anyhow::bail!("file byte must be u8");
        }
        out.push(byte as u8);
    }
    Ok(out)
}

fn messages_from_value(items: &[Value]) -> Result<Vec<ChatMessage>> {
    let mut messages = Vec::with_capacity(items.len());
    for item in items {
        messages.push(ChatMessage {
            role: required_string(item, "role")?.to_string(),
            content: required_string(item, "content")?.to_string(),
        });
    }
    Ok(messages)
}

fn multimodal_error_tag(error: &anyhow::Error) -> Option<&'static str> {
    let typed = error.downcast_ref::<multimodal::MultimodalError>()?;
    Some(match typed {
        multimodal::MultimodalError::TooManyImages { .. } => "multimodal_too_many_images",
        multimodal::MultimodalError::ImageTooLarge { .. } => "multimodal_image_too_large",
        multimodal::MultimodalError::UnsupportedMime { .. } => "multimodal_unsupported_mime",
        multimodal::MultimodalError::RemoteFetchDisabled { .. } => {
            "multimodal_remote_fetch_disabled"
        }
        multimodal::MultimodalError::ImageSourceNotFound { .. } => {
            "multimodal_image_source_not_found"
        }
        multimodal::MultimodalError::InvalidMarker { .. } => "multimodal_invalid_marker",
        multimodal::MultimodalError::RemoteFetchFailed { .. } => "multimodal_remote_fetch_failed",
        multimodal::MultimodalError::LocalReadFailed { .. } => "multimodal_local_read_failed",
    })
}

fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .with_context(|| format!("{key} missing"))
}

fn required_array<'a>(value: &'a Value, key: &str) -> Result<&'a Vec<Value>> {
    value
        .get(key)
        .and_then(Value::as_array)
        .with_context(|| format!("{key} missing"))
}

fn write_result(output: &mut Vec<u8>, op: &str, result: Value) {
    let value = serde_json::json!({"op": op, "result": result});
    output.extend_from_slice(canonical_dump(&value).as_bytes());
    output.push(b'\n');
}

fn canonical_dump(value: &Value) -> String {
    match value {
        Value::Null => "null".to_string(),
        Value::Bool(inner) => inner.to_string(),
        Value::Number(inner) => inner.to_string(),
        Value::String(inner) => serde_json::to_string(inner).unwrap(),
        Value::Array(items) => {
            let rendered: Vec<String> = items.iter().map(canonical_dump).collect();
            format!("[{}]", rendered.join(","))
        }
        Value::Object(object) => {
            let mut keys: Vec<&String> = object.keys().collect();
            keys.sort();
            let rendered: Vec<String> = keys
                .iter()
                .map(|key| {
                    format!(
                        "{}:{}",
                        serde_json::to_string(key).unwrap(),
                        canonical_dump(&object[*key])
                    )
                })
                .collect();
            format!("{{{}}}", rendered.join(","))
        }
    }
}
