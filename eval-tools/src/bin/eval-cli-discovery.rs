//! eval-cli-discovery — offline cli_discovery parity runner.

use std::io::{self, Read, Write};
use std::path::Path;

use anyhow::{Context, Result};
use serde_json::{Map, Value};
use zeroclaw_tools::cli_discovery::{discover_cli_tools, DiscoveredCli};

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
        if op != "discover" {
            anyhow::bail!("unknown cli_discovery op: {op}");
        }

        let setup = required_field(&value, "setup")?;
        let input = required_field(&value, "input")?;
        apply_setup(setup)?;
        if let Some(path_override) = optional_string(input, "path_override") {
            std::env::set_var("PATH", path_override);
        }

        let additional = optional_string_array(input, "additional").unwrap_or_default();
        let excluded = optional_string_array(input, "excluded").unwrap_or_default();
        let results = discover_cli_tools(&additional, &excluded);
        write_results(&mut output, results)?;
    }

    io::stdout().lock().write_all(&output)?;
    Ok(())
}

fn apply_setup(setup: &Value) -> Result<()> {
    if let Some(shell_scripts) = setup.get("shell_scripts") {
        let shell_scripts = shell_scripts
            .as_object()
            .context("setup shell_scripts must be an object")?;
        for (path, content) in shell_scripts {
            let content = content
                .as_str()
                .context("setup shell_scripts values must be strings")?;
            write_shell_script(path, content)?;
        }
    }
    Ok(())
}

fn write_shell_script(path: &str, content: &str) -> Result<()> {
    #[cfg(not(unix))]
    anyhow::bail!("cli_discovery shell_scripts fixtures are Unix-only");

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        if let Some(parent) = Path::new(path).parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, content)?;
        let mut perms = std::fs::metadata(path)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms)?;
        Ok(())
    }
}

fn write_results(output: &mut Vec<u8>, results: Vec<DiscoveredCli>) -> Result<()> {
    let mut values = Vec::with_capacity(results.len());
    for cli in results {
        let category = serde_json::to_value(&cli.category)?;
        let mut obj = Map::new();
        obj.insert("category".to_string(), category);
        obj.insert("name".to_string(), Value::String(cli.name));
        obj.insert(
            "path".to_string(),
            Value::String(cli.path.to_string_lossy().into_owned()),
        );
        obj.insert(
            "version".to_string(),
            cli.version.map(Value::String).unwrap_or(Value::Null),
        );
        values.push(Value::Object(obj));
    }
    serde_json::to_writer(&mut *output, &Value::Array(values))?;
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

fn optional_string_array(value: &Value, key: &str) -> Option<Vec<String>> {
    let items = value.get(key)?.as_array()?;
    let mut output = Vec::with_capacity(items.len());
    for item in items {
        output.push(item.as_str()?.to_string());
    }
    Some(output)
}
