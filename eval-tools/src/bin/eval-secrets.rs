//! eval-secrets — SecretStore parity runner.

use std::fs;
use std::io::{self, Read, Write};
use std::path::PathBuf;

use anyhow::{Context, Result};
use serde_json::Value;
use zeroclaw_config::secrets::SecretStore;

fn main() -> Result<()> {
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
        run_op(&mut output, index, op, &value)?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn run_op(output: &mut Vec<u8>, index: usize, op: &str, value: &Value) -> Result<()> {
    if op == "decrypt_passthrough" {
        let state_dir = make_temp_state_dir(index, "secrets-rust")?;
        let store = SecretStore::new(&state_dir, true);
        let plaintext = store.decrypt(required_string(value, "value")?)?;
        write_result(
            output,
            op,
            serde_json::json!({ "plaintext": plaintext }),
        );
        let _ = fs::remove_dir_all(state_dir);
        return Ok(());
    }

    let key_hex = required_string(value, "key_hex")?;
    let state_dir = make_temp_state_dir(index, "secrets-rust")?;
    write_key_file(&state_dir, key_hex)?;
    let enabled = value.get("enabled").and_then(Value::as_bool).unwrap_or(true);
    let store = SecretStore::new(&state_dir, enabled);

    match op {
        "encrypt_decrypt_roundtrip" => {
            let plaintext = required_string(value, "plaintext")?;
            let encrypted = store.encrypt(plaintext)?;
            let decrypted = store.decrypt(&encrypted)?;
            let prefix = if encrypted.starts_with("enc2:") { "enc2:" } else { "" };
            write_result(
                output,
                op,
                serde_json::json!({ "matches": decrypted == plaintext, "prefix": prefix }),
            );
        }
        "decrypt_legacy_enc" => {
            let legacy = format!("enc:{}", required_string(value, "hex_ciphertext")?);
            let plaintext = store.decrypt(&legacy)?;
            write_result(output, op, serde_json::json!({ "plaintext": plaintext }));
        }
        "migrate_enc_to_enc2" => {
            let (plaintext, migrated) = store.decrypt_and_migrate(required_string(value, "enc_value")?)?;
            let migrated = migrated.context("migration expected")?;
            let migrated_re_decrypted = store.decrypt(&migrated)?;
            let prefix = if migrated.starts_with("enc2:") { "enc2:" } else { "" };
            write_result(
                output,
                op,
                serde_json::json!({
                    "plaintext": plaintext,
                    "migrated_re_decrypted": migrated_re_decrypted,
                    "migrated_prefix": prefix,
                }),
            );
        }
        _ => anyhow::bail!("unknown secrets op: {op}"),
    }

    let _ = fs::remove_dir_all(state_dir);
    Ok(())
}

fn make_temp_state_dir(index: usize, prefix: &str) -> Result<PathBuf> {
    let path = std::env::temp_dir().join(format!("{prefix}-{}-{index}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path)?;
    Ok(path)
}

fn write_key_file(state_dir: &std::path::Path, key_hex: &str) -> Result<()> {
    fs::write(state_dir.join(".secret_key"), key_hex)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(state_dir.join(".secret_key"), fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .with_context(|| format!("{key} missing"))
}

fn write_result(output: &mut Vec<u8>, op: &str, result: Value) {
    let value = serde_json::json!({ "op": op, "result": result });
    serde_json::to_writer(&mut *output, &value).expect("serialize eval result");
    output.push(b'\n');
}
