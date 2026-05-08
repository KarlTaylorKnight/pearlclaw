//! eval-oauth — offline OAuth helper parity runner.
//!
//! Reads JSONL OAuth ops from stdin, runs deterministic Rust reference
//! helpers, writes one canonical JSON response per op to stdout.

use std::io::{self, Read, Write};

use anyhow::{Context, Result};
use serde_json::{Map, Value};
use zeroclaw_providers::auth::oauth_common::{
    parse_query_params, pkce_state_from_seed, url_decode, url_encode, PkceState,
};
use zeroclaw_providers::auth::openai_oauth::{
    build_authorize_url, build_device_code_poll_body, build_device_code_request_body,
    build_token_request_body_authorization_code, build_token_request_body_refresh_token,
    classify_device_code_error, extract_account_id_from_jwt, extract_expiry_from_jwt,
    parse_code_from_redirect, parse_device_code_response_body, parse_loopback_request_path,
    parse_oauth_error_body, parse_token_response_body_for_eval, DeviceCodeErrorKind,
};

fn main() -> Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
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
            .context("op missing")?;

        match op {
            "url_encode" => {
                let input = required_string(&op_value, "input")?;
                write_result(&mut output, op, serde_json::json!(url_encode(input)));
            }
            "url_decode" => {
                let input = required_string(&op_value, "input")?;
                write_result(&mut output, op, serde_json::json!(url_decode(input)));
            }
            "parse_query_params" => {
                let input = required_string(&op_value, "input")?;
                write_result(
                    &mut output,
                    op,
                    serde_json::json!(parse_query_params(input)),
                );
            }
            "pkce_from_seed" => {
                let verifier_seed = decode_hex(required_string(&op_value, "verifier_seed_hex")?)?;
                let state_seed = decode_hex(required_string(&op_value, "state_seed_hex")?)?;
                let pkce = pkce_state_from_seed(&verifier_seed, &state_seed);
                write_result(
                    &mut output,
                    op,
                    serde_json::json!({
                        "code_verifier": pkce.code_verifier,
                        "code_challenge": pkce.code_challenge,
                        "state": pkce.state,
                    }),
                );
            }
            "build_authorize_url" => {
                let pkce = pkce_from_value(&op_value)?;
                write_result(
                    &mut output,
                    op,
                    serde_json::json!(build_authorize_url(&pkce)),
                );
            }
            "build_token_body_authorization_code" => {
                let pkce = PkceState {
                    code_verifier: required_string(&op_value, "code_verifier")?.to_string(),
                    code_challenge: String::new(),
                    state: String::new(),
                };
                let code = required_string(&op_value, "code")?;
                write_result(
                    &mut output,
                    op,
                    serde_json::json!(build_token_request_body_authorization_code(code, &pkce)),
                );
            }
            "build_token_body_refresh_token" => {
                let refresh_token = required_string(&op_value, "refresh_token")?;
                write_result(
                    &mut output,
                    op,
                    serde_json::json!(build_token_request_body_refresh_token(refresh_token)),
                );
            }
            "build_device_code_body" => {
                write_result(
                    &mut output,
                    op,
                    serde_json::json!(build_device_code_request_body()),
                );
            }
            "build_device_code_poll_body" => {
                let device_code = required_string(&op_value, "device_code")?;
                write_result(
                    &mut output,
                    op,
                    serde_json::json!(build_device_code_poll_body(device_code)),
                );
            }
            "parse_code_from_redirect" => {
                let input = required_string(&op_value, "input")?;
                let expected_state = optional_string(&op_value, "expected_state")?;
                let result = match parse_code_from_redirect(input, expected_state.as_deref()) {
                    Ok(code) => serde_json::json!({ "code": code }),
                    Err(err) => serde_json::json!({ "error": err.to_string() }),
                };
                write_result(&mut output, op, result);
            }
            "parse_loopback_request_path" => {
                let input = required_string(&op_value, "input")?;
                let result = match parse_loopback_request_path(input) {
                    Ok(path) => serde_json::json!({ "path": path }),
                    Err(_) => serde_json::json!({ "error": "InvalidLoopbackRequest" }),
                };
                write_result(&mut output, op, result);
            }
            "parse_token_response" => {
                let body = required_string(&op_value, "body")?;
                let parsed = parse_token_response_body_for_eval(body)?;
                write_result(&mut output, op, serde_json::to_value(parsed)?);
            }
            "parse_device_code_response" => {
                let body = required_string(&op_value, "body")?;
                let parsed = parse_device_code_response_body(body)?;
                let mut result = Map::new();
                result.insert(
                    "device_code".to_string(),
                    serde_json::json!(parsed.device_code),
                );
                result.insert("user_code".to_string(), serde_json::json!(parsed.user_code));
                result.insert(
                    "verification_uri".to_string(),
                    serde_json::json!(parsed.verification_uri),
                );
                if let Some(value) = parsed.verification_uri_complete {
                    result.insert(
                        "verification_uri_complete".to_string(),
                        serde_json::json!(value),
                    );
                }
                result.insert(
                    "expires_in".to_string(),
                    serde_json::json!(parsed.expires_in),
                );
                result.insert("interval".to_string(), serde_json::json!(parsed.interval));
                if let Some(value) = parsed.message {
                    result.insert("message".to_string(), serde_json::json!(value));
                }
                write_result(&mut output, op, Value::Object(result));
            }
            "parse_oauth_error" => {
                let body = required_string(&op_value, "body")?;
                let parsed = parse_oauth_error_body(body)?;
                let mut result = Map::new();
                result.insert("error".to_string(), serde_json::json!(parsed.error));
                if let Some(value) = parsed.error_description {
                    result.insert("error_description".to_string(), serde_json::json!(value));
                }
                write_result(&mut output, op, Value::Object(result));
            }
            "classify_device_code_error" => {
                let body = required_string(&op_value, "body")?;
                let parsed = parse_oauth_error_body(body).ok();
                let description = parsed.and_then(|err| err.error_description);
                write_result(
                    &mut output,
                    op,
                    serde_json::json!({
                        "kind": device_code_error_kind_name(classify_device_code_error(body)),
                        "description": description,
                    }),
                );
            }
            "extract_account_id_from_jwt" => {
                let token = required_string(&op_value, "token")?;
                write_result(
                    &mut output,
                    op,
                    serde_json::to_value(extract_account_id_from_jwt(token))?,
                );
            }
            "extract_expiry_from_jwt" => {
                let token = required_string(&op_value, "token")?;
                write_result(
                    &mut output,
                    op,
                    serde_json::to_value(extract_expiry_from_jwt(token).map(|dt| dt.timestamp()))?,
                );
            }
            _ => anyhow::bail!("unknown oauth op: {op}"),
        }
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn pkce_from_value(value: &Value) -> Result<PkceState> {
    Ok(PkceState {
        code_verifier: required_string(value, "code_verifier")?.to_string(),
        code_challenge: required_string(value, "code_challenge")?.to_string(),
        state: required_string(value, "state")?.to_string(),
    })
}

fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .with_context(|| format!("{key} missing"))
}

fn optional_string(value: &Value, key: &str) -> Result<Option<String>> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(inner)) => Ok(Some(inner.clone())),
        Some(_) => anyhow::bail!("{key} must be string or null"),
    }
}

fn decode_hex(input: &str) -> Result<Vec<u8>> {
    if input.len() % 2 != 0 {
        anyhow::bail!("hex input length must be even");
    }
    let mut out = Vec::with_capacity(input.len() / 2);
    let mut i = 0;
    while i < input.len() {
        let byte = u8::from_str_radix(&input[i..i + 2], 16)
            .with_context(|| format!("invalid hex byte at offset {i}"))?;
        out.push(byte);
        i += 2;
    }
    Ok(out)
}

fn device_code_error_kind_name(kind: DeviceCodeErrorKind) -> &'static str {
    match kind {
        DeviceCodeErrorKind::Pending => "Pending",
        DeviceCodeErrorKind::SlowDown => "SlowDown",
        DeviceCodeErrorKind::Denied => "Denied",
        DeviceCodeErrorKind::Expired => "Expired",
        DeviceCodeErrorKind::Other => "Other",
        DeviceCodeErrorKind::Unparseable => "Unparseable",
    }
}

fn write_result(output: &mut Vec<u8>, op: &str, result: Value) {
    let value = serde_json::json!({"op": op, "result": result});
    output.extend_from_slice(canonical_dump(&value).as_bytes());
    output.push(b'\n');
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
