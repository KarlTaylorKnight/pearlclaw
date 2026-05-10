//! eval-provider-types — offline provider DTO / formatter parity runner.

use std::io::{self, Read, Write};

use anyhow::{Context, Result};
use serde_json::Value;
use zeroclaw_api::provider::{
    build_tool_instructions_text, ChatResponse, ConversationMessage, ProviderCapabilities,
    ProviderCapabilityError, StreamChunk, StreamEvent, StreamOptions, ToolCall, ToolResultMessage,
    ToolsPayload,
};
use zeroclaw_api::tool::ToolSpec;

fn main() -> Result<()> {
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
        run_op(&mut output, op, &value)?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn run_op(output: &mut Vec<u8>, op: &str, value: &Value) -> Result<()> {
    match op {
        "build_tool_instructions_text" => {
            let tools = tool_specs_from_value(value)?;
            write_result(
                output,
                op,
                serde_json::json!({
                    "instructions": build_tool_instructions_text(&tools),
                }),
            );
        }
        "serialize_tool_call" => {
            write_result(
                output,
                op,
                serde_json::to_value(tool_call_from_value(value)?)?,
            );
        }
        "serialize_chat_response" => {
            let response = chat_response_from_value(required_field(value, "response")?)?;
            write_result(
                output,
                op,
                serde_json::json!({
                    "has_tool_calls": response.has_tool_calls(),
                    "text_or_empty": response.text_or_empty(),
                    "value": chat_response_to_json(&response),
                }),
            );
        }
        "serialize_conversation_message" => {
            let message = conversation_message_from_value(required_field(value, "message")?)?;
            write_result(output, op, serde_json::to_value(message)?);
        }
        "stream_shapes" => {
            let delta_text = value
                .get("delta")
                .and_then(Value::as_str)
                .unwrap_or("hello stream");
            let reasoning_text = value
                .get("reasoning")
                .and_then(Value::as_str)
                .unwrap_or("thinking");
            let error_text = value
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("provider failed");
            let enabled = value
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(true);

            let delta = StreamChunk::delta(delta_text).with_token_estimate();
            let reasoning = StreamChunk::reasoning(reasoning_text);
            let final_chunk = StreamChunk::final_chunk();
            let error_chunk = StreamChunk::error(error_text);
            let options = StreamOptions::new(enabled).with_token_count();
            let default_options = StreamOptions::default();
            let capability_error = ProviderCapabilityError {
                provider: "ollama".to_string(),
                capability: "vision".to_string(),
                message: "not available".to_string(),
            };
            let caps = ProviderCapabilities {
                native_tool_calling: true,
                vision: true,
                prompt_caching: false,
            };

            write_result(
                output,
                op,
                serde_json::json!({
                    "capabilities": provider_capabilities_to_json(&caps),
                    "chunks": {
                        "delta": stream_chunk_to_json(&delta),
                        "reasoning": stream_chunk_to_json(&reasoning),
                        "final": stream_chunk_to_json(&final_chunk),
                        "error": stream_chunk_to_json(&error_chunk),
                    },
                    "events": {
                        "from_delta": stream_event_to_json(&StreamEvent::from_chunk(delta.clone())),
                        "from_final": stream_event_to_json(&StreamEvent::from_chunk(final_chunk.clone())),
                        "pre_executed_tool_call": stream_event_to_json(&StreamEvent::PreExecutedToolCall {
                            name: "shell".to_string(),
                            args: "{\"cmd\":\"pwd\"}".to_string(),
                        }),
                        "pre_executed_tool_result": stream_event_to_json(&StreamEvent::PreExecutedToolResult {
                            name: "shell".to_string(),
                            output: "ok".to_string(),
                        }),
                        "tool_call": stream_event_to_json(&StreamEvent::ToolCall(ToolCall {
                            id: "tc1".to_string(),
                            name: "lookup".to_string(),
                            arguments: "{\"q\":\"zig\"}".to_string(),
                        })),
                    },
                    "options": {
                        "default": stream_options_to_json(default_options),
                        "custom": stream_options_to_json(options),
                    },
                    "provider_capability_error": provider_capability_error_to_json(&capability_error),
                    "stream_error_tags": ["Http", "Json", "InvalidSse", "Provider", "Io"],
                }),
            );
        }
        "tools_payload" => {
            let payload = tools_payload_from_value(required_field(value, "payload")?)?;
            write_result(output, op, tools_payload_to_json(&payload));
        }
        _ => anyhow::bail!("unknown provider_types op: {op}"),
    }
    Ok(())
}

fn tool_specs_from_value(value: &Value) -> Result<Vec<ToolSpec>> {
    let Some(tools) = value.get("tools").and_then(Value::as_array) else {
        return Ok(Vec::new());
    };
    tools
        .iter()
        .map(|item| {
            Ok(ToolSpec {
                name: required_string(item, "name")?.to_string(),
                description: required_string(item, "description")?.to_string(),
                parameters: required_field(item, "parameters")?.clone(),
            })
        })
        .collect()
}

fn tool_call_from_value(value: &Value) -> Result<ToolCall> {
    Ok(ToolCall {
        id: required_string(value, "id")?.to_string(),
        name: required_string(value, "name")?.to_string(),
        arguments: required_string(value, "arguments")?.to_string(),
    })
}

fn chat_response_from_value(value: &Value) -> Result<ChatResponse> {
    let tool_calls = if let Some(items) = value.get("tool_calls").and_then(Value::as_array) {
        items
            .iter()
            .map(tool_call_from_value)
            .collect::<Result<Vec<_>>>()?
    } else {
        Vec::new()
    };
    Ok(ChatResponse {
        text: optional_string(value, "text").map(ToString::to_string),
        tool_calls,
        usage: token_usage_to_json(value).map(|usage| zeroclaw_api::provider::TokenUsage {
            input_tokens: usage.get("input_tokens").and_then(Value::as_u64),
            output_tokens: usage.get("output_tokens").and_then(Value::as_u64),
            cached_input_tokens: usage.get("cached_input_tokens").and_then(Value::as_u64),
        }),
        reasoning_content: optional_string(value, "reasoning_content").map(ToString::to_string),
    })
}

fn conversation_message_from_value(value: &Value) -> Result<ConversationMessage> {
    let kind = required_string(value, "type")?;
    let data = required_field(value, "data")?;
    match kind {
        "Chat" => Ok(ConversationMessage::Chat(
            zeroclaw_api::provider::ChatMessage {
                role: required_string(data, "role")?.to_string(),
                content: required_string(data, "content")?.to_string(),
            },
        )),
        "AssistantToolCalls" => {
            let tool_calls = required_array(data, "tool_calls")?
                .iter()
                .map(tool_call_from_value)
                .collect::<Result<Vec<_>>>()?;
            Ok(ConversationMessage::AssistantToolCalls {
                text: optional_string(data, "text").map(ToString::to_string),
                tool_calls,
                reasoning_content: optional_string(data, "reasoning_content")
                    .map(ToString::to_string),
            })
        }
        "ToolResults" => {
            let items = data.as_array().context("ToolResults data must be array")?;
            let results = items
                .iter()
                .map(|item| {
                    Ok(ToolResultMessage {
                        tool_call_id: required_string(item, "tool_call_id")?.to_string(),
                        content: required_string(item, "content")?.to_string(),
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(ConversationMessage::ToolResults(results))
        }
        _ => anyhow::bail!("unknown ConversationMessage variant: {kind}"),
    }
}

fn tools_payload_from_value(value: &Value) -> Result<ToolsPayload> {
    let kind = required_string(value, "type")?;
    let data = required_field(value, "data")?;
    match kind {
        "Gemini" => Ok(ToolsPayload::Gemini {
            function_declarations: required_array(data, "function_declarations")?.clone(),
        }),
        "Anthropic" => Ok(ToolsPayload::Anthropic {
            tools: required_array(data, "tools")?.clone(),
        }),
        "OpenAI" => Ok(ToolsPayload::OpenAI {
            tools: required_array(data, "tools")?.clone(),
        }),
        "PromptGuided" => Ok(ToolsPayload::PromptGuided {
            instructions: required_string(data, "instructions")?.to_string(),
        }),
        _ => anyhow::bail!("unknown ToolsPayload variant: {kind}"),
    }
}

fn chat_response_to_json(response: &ChatResponse) -> Value {
    serde_json::json!({
        "text": &response.text,
        "tool_calls": &response.tool_calls,
        "usage": response.usage.as_ref().map(token_usage_struct_to_json),
        "reasoning_content": &response.reasoning_content,
    })
}

fn token_usage_to_json(value: &Value) -> Option<Value> {
    value.get("usage").filter(|usage| !usage.is_null()).cloned()
}

fn token_usage_struct_to_json(usage: &zeroclaw_api::provider::TokenUsage) -> Value {
    serde_json::json!({
        "input_tokens": usage.input_tokens,
        "output_tokens": usage.output_tokens,
        "cached_input_tokens": usage.cached_input_tokens,
    })
}

fn stream_chunk_to_json(chunk: &StreamChunk) -> Value {
    serde_json::json!({
        "delta": chunk.delta,
        "reasoning": chunk.reasoning,
        "is_final": chunk.is_final,
        "token_count": chunk.token_count,
    })
}

fn stream_event_to_json(event: &StreamEvent) -> Value {
    match event {
        StreamEvent::TextDelta(chunk) => {
            serde_json::json!({"type": "TextDelta", "data": stream_chunk_to_json(chunk)})
        }
        StreamEvent::ToolCall(call) => {
            serde_json::json!({"type": "ToolCall", "data": call})
        }
        StreamEvent::PreExecutedToolCall { name, args } => {
            serde_json::json!({"type": "PreExecutedToolCall", "data": {"name": name, "args": args}})
        }
        StreamEvent::PreExecutedToolResult { name, output } => {
            serde_json::json!({"type": "PreExecutedToolResult", "data": {"name": name, "output": output}})
        }
        StreamEvent::Final => serde_json::json!({"type": "Final"}),
    }
}

fn stream_options_to_json(options: StreamOptions) -> Value {
    serde_json::json!({
        "enabled": options.enabled,
        "count_tokens": options.count_tokens,
    })
}

fn provider_capabilities_to_json(caps: &ProviderCapabilities) -> Value {
    serde_json::json!({
        "native_tool_calling": caps.native_tool_calling,
        "vision": caps.vision,
        "prompt_caching": caps.prompt_caching,
    })
}

fn provider_capability_error_to_json(error: &ProviderCapabilityError) -> Value {
    serde_json::json!({
        "provider": &error.provider,
        "capability": &error.capability,
        "message": &error.message,
        "display": error.to_string(),
    })
}

fn tools_payload_to_json(payload: &ToolsPayload) -> Value {
    match payload {
        ToolsPayload::Gemini {
            function_declarations,
        } => serde_json::json!({
            "type": "Gemini",
            "data": {"function_declarations": function_declarations},
        }),
        ToolsPayload::Anthropic { tools } => serde_json::json!({
            "type": "Anthropic",
            "data": {"tools": tools},
        }),
        ToolsPayload::OpenAI { tools } => serde_json::json!({
            "type": "OpenAI",
            "data": {"tools": tools},
        }),
        ToolsPayload::PromptGuided { instructions } => serde_json::json!({
            "type": "PromptGuided",
            "data": {"instructions": instructions},
        }),
    }
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
