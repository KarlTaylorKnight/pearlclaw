//! eval-profiles — AuthProfilesStore/AuthService helper parity runner.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde_json::{Map, Value};
use zeroclaw_providers::auth::profiles::{AuthProfile, AuthProfilesData, AuthProfilesStore, TokenSet};
use zeroclaw_providers::auth::select_profile_id;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let mut output = Vec::new();

    for (index, raw_line) in input.lines().enumerate() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let value: Value = serde_json::from_str(line).context("invalid scenario JSON")?;
        let op = required_string(&value, "op")?;
        run_op(&mut output, index, op, &value).await?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

async fn run_op(output: &mut Vec<u8>, index: usize, op: &str, value: &Value) -> Result<()> {
    match op {
        "roundtrip_oauth_profile" => roundtrip_oauth(output, index, op, value).await,
        "roundtrip_token_profile" => roundtrip_token(output, index, op, value).await,
        "select_profile_id" => select_profile(output, op, value),
        "migrate_legacy_enc_in_profile" => migrate_legacy(output, index, op, value).await,
        "schema_version_mismatch" => schema_version_mismatch(output, index, op, value).await,
        _ => anyhow::bail!("unknown profiles op: {op}"),
    }
}

async fn roundtrip_oauth(output: &mut Vec<u8>, index: usize, op: &str, value: &Value) -> Result<()> {
    let encrypt_secrets = value.get("encrypt_secrets").and_then(Value::as_bool).unwrap_or(true);
    let state_dir = make_temp_state_dir(index, "profiles-oauth-rust")?;
    if let Some(key_hex) = value.get("key_hex").and_then(Value::as_str) {
        write_key_file(&state_dir, key_hex)?;
    }
    let store = AuthProfilesStore::new(&state_dir, encrypt_secrets);
    let mut profile = oauth_profile_from_value(required_object(value, "profile")?)?;
    store.upsert_profile(profile.clone(), true).await?;
    let data = store.load().await?;
    profile = data.profiles.get(&profile.id).context("profile missing")?.clone();
    write_result(output, op, serde_json::json!({ "profile": profile_json(&profile) }));
    let _ = fs::remove_dir_all(state_dir);
    Ok(())
}

async fn roundtrip_token(output: &mut Vec<u8>, index: usize, op: &str, value: &Value) -> Result<()> {
    let encrypt_secrets = value.get("encrypt_secrets").and_then(Value::as_bool).unwrap_or(true);
    let state_dir = make_temp_state_dir(index, "profiles-token-rust")?;
    if let Some(key_hex) = value.get("key_hex").and_then(Value::as_str) {
        write_key_file(&state_dir, key_hex)?;
    }
    let store = AuthProfilesStore::new(&state_dir, encrypt_secrets);
    let mut profile = token_profile_from_value(required_object(value, "profile")?)?;
    store.upsert_profile(profile.clone(), true).await?;
    let data = store.load().await?;
    profile = data.profiles.get(&profile.id).context("profile missing")?.clone();
    write_result(output, op, serde_json::json!({ "profile": profile_json(&profile) }));
    let _ = fs::remove_dir_all(state_dir);
    Ok(())
}

fn select_profile(output: &mut Vec<u8>, op: &str, value: &Value) -> Result<()> {
    let mut data = AuthProfilesData::default();
    for item in required_array(value, "profiles")? {
        let provider = required_string(item, "provider")?;
        let name = required_string(item, "name")?;
        let profile = AuthProfile::new_token(provider, name, "token".to_string());
        data.profiles.insert(profile.id.clone(), profile);
    }
    if let Some(active) = value.get("active_map").and_then(Value::as_object) {
        for (provider, id) in active {
            data.active_profiles
                .insert(provider.clone(), id.as_str().context("active id must be string")?.to_string());
        }
    }
    let provider = required_string(value, "query_provider")?;
    let profile_override = optional_string(value, "override")?;
    let resolved = select_profile_id(&data, provider, profile_override.as_deref());
    write_result(output, op, serde_json::json!({ "resolved_id": resolved }));
    Ok(())
}

async fn migrate_legacy(output: &mut Vec<u8>, index: usize, op: &str, value: &Value) -> Result<()> {
    let state_dir = make_temp_state_dir(index, "profiles-migrate-rust")?;
    write_key_file(&state_dir, required_string(value, "key_hex")?)?;
    write_profiles_file(&state_dir, required_string(value, "file_json")?)?;
    let store = AuthProfilesStore::new(&state_dir, true);
    let data = store.load().await?;
    let profile = data
        .profiles
        .get(required_string(value, "profile_id")?)
        .context("profile missing")?;
    let access_token = profile
        .token_set
        .as_ref()
        .context("token set missing")?
        .access_token
        .clone();
    let raw = fs::read_to_string(store.path())?;
    write_result(
        output,
        op,
        serde_json::json!({
            "access_token": access_token,
            "file_now_enc2": raw.contains("\"access_token\": \"enc2:"),
        }),
    );
    let _ = fs::remove_dir_all(state_dir);
    Ok(())
}

async fn schema_version_mismatch(output: &mut Vec<u8>, index: usize, op: &str, value: &Value) -> Result<()> {
    let state_dir = make_temp_state_dir(index, "profiles-schema-rust")?;
    write_profiles_file(&state_dir, required_string(value, "file_json")?)?;
    let store = AuthProfilesStore::new(&state_dir, false);
    let result = match store.load().await {
        Ok(_) => serde_json::json!({ "error": "None" }),
        Err(err) if err.to_string().contains("Unsupported auth profile schema version") => {
            serde_json::json!({ "error": "UnsupportedSchemaVersion" })
        }
        Err(err) => serde_json::json!({ "error": err.to_string() }),
    };
    write_result(output, op, result);
    let _ = fs::remove_dir_all(state_dir);
    Ok(())
}

fn oauth_profile_from_value(value: &Value) -> Result<AuthProfile> {
    let token_set = TokenSet {
        access_token: required_string(value, "access_token")?.to_string(),
        refresh_token: optional_string(value, "refresh_token")?,
        id_token: optional_string(value, "id_token")?,
        expires_at: None,
        token_type: optional_string(value, "token_type")?,
        scope: optional_string(value, "scope")?,
    };
    let mut profile = AuthProfile::new_oauth(
        required_string(value, "provider")?,
        required_string(value, "name")?,
        token_set,
    );
    profile.account_id = optional_string(value, "account_id")?;
    profile.workspace_id = optional_string(value, "workspace_id")?;
    profile.metadata = metadata_from_value(value)?;
    Ok(profile)
}

fn token_profile_from_value(value: &Value) -> Result<AuthProfile> {
    let mut profile = AuthProfile::new_token(
        required_string(value, "provider")?,
        required_string(value, "name")?,
        required_string(value, "token")?.to_string(),
    );
    profile.account_id = optional_string(value, "account_id")?;
    profile.workspace_id = optional_string(value, "workspace_id")?;
    profile.metadata = metadata_from_value(value)?;
    Ok(profile)
}

fn profile_json(profile: &AuthProfile) -> Value {
    let mut result = Map::new();
    result.insert("id".to_string(), serde_json::json!(profile.id));
    result.insert("provider".to_string(), serde_json::json!(profile.provider));
    result.insert("profile_name".to_string(), serde_json::json!(profile.profile_name));
    result.insert("kind".to_string(), serde_json::json!(match profile.kind {
        zeroclaw_providers::auth::profiles::AuthProfileKind::OAuth => "oauth",
        zeroclaw_providers::auth::profiles::AuthProfileKind::Token => "token",
    }));
    result.insert("account_id".to_string(), serde_json::to_value(&profile.account_id).unwrap());
    result.insert("workspace_id".to_string(), serde_json::to_value(&profile.workspace_id).unwrap());
    result.insert(
        "token_set".to_string(),
        profile
            .token_set
            .as_ref()
            .map(token_set_json)
            .unwrap_or(Value::Null),
    );
    result.insert("token".to_string(), serde_json::to_value(&profile.token).unwrap());
    result.insert("metadata".to_string(), serde_json::to_value(&profile.metadata).unwrap());
    result.insert("created_at".to_string(), serde_json::json!(profile.created_at.to_rfc3339()));
    result.insert("updated_at".to_string(), serde_json::json!(profile.updated_at.to_rfc3339()));
    Value::Object(result)
}

fn token_set_json(token_set: &TokenSet) -> Value {
    serde_json::json!({
        "access_token": token_set.access_token,
        "refresh_token": token_set.refresh_token,
        "id_token": token_set.id_token,
        "expires_at": token_set.expires_at.map(|dt| dt.to_rfc3339()),
        "token_type": token_set.token_type,
        "scope": token_set.scope,
    })
}

fn metadata_from_value(value: &Value) -> Result<BTreeMap<String, String>> {
    let mut map = BTreeMap::new();
    if let Some(metadata) = value.get("metadata").and_then(Value::as_object) {
        for (key, value) in metadata {
            map.insert(key.clone(), value.as_str().context("metadata value must be string")?.to_string());
        }
    }
    Ok(map)
}

fn make_temp_state_dir(index: usize, prefix: &str) -> Result<PathBuf> {
    let path = std::env::temp_dir().join(format!("{prefix}-{}-{index}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path)?;
    Ok(path)
}

fn write_key_file(state_dir: &Path, key_hex: &str) -> Result<()> {
    fs::write(state_dir.join(".secret_key"), key_hex)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(state_dir.join(".secret_key"), fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

fn write_profiles_file(state_dir: &Path, contents: &str) -> Result<()> {
    fs::create_dir_all(state_dir)?;
    fs::write(state_dir.join("auth-profiles.json"), contents)?;
    Ok(())
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

fn required_object<'a>(value: &'a Value, key: &str) -> Result<&'a Value> {
    let inner = value.get(key).with_context(|| format!("{key} missing"))?;
    if !inner.is_object() {
        anyhow::bail!("{key} must be object");
    }
    Ok(inner)
}

fn required_array<'a>(value: &'a Value, key: &str) -> Result<&'a Vec<Value>> {
    value
        .get(key)
        .and_then(Value::as_array)
        .with_context(|| format!("{key} missing"))
}

fn write_result(output: &mut Vec<u8>, op: &str, result: Value) {
    let value = serde_json::json!({ "op": op, "result": result });
    serde_json::to_writer(&mut *output, &value).expect("serialize eval result");
    output.push(b'\n');
}
