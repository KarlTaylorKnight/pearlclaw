#!/usr/bin/env python3
"""Eval driver — language-agnostic byte-equal parity check.

For each fixture in evals/fixtures/<subsystem>/:
  1. Pipe the input through the Rust runner subprocess.
  2. Pipe the same input through the Zig runner subprocess.
  3. Both outputs are canonical JSON. Compare byte-equal.
  4. Optional: also compare against committed *.expected.json (golden).

Exit non-zero on any mismatch. Prints unified diffs for failures.

Usage:
  python3 evals/driver/run_evals.py \\
      --rust eval-tools/target/release \\
      --zig zig/zig-out/bin \\
      [--subsystem parser|memory|memory_tools|file_tools|content_search|data_management|image_info|cli_discovery|dispatcher|providers|oauth|schema|secrets|profiles|multimodal|provider_types|provider_secrets|provider_factory|agent_tools|hardware_memory_map|hardware_board_info] \\
      [--update-golden]   # only with --rust; rewrites *.expected.json from Rust output
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES_DIR = REPO_ROOT / "evals" / "fixtures"

SUBSYSTEMS = {
    "parser": {
        "fixture_glob": "*.input.txt",
        "expected_suffix": ".expected.json",
        "rust_bin": "eval-parser",
        "zig_bin": "eval-parser",
    },
    "memory": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-memory",
        "zig_bin": "eval-memory",
        "jsonl": True,
        "temp_paths": True,
    },
    "memory_tools": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-memory-tools",
        "zig_bin": "eval-memory-tools",
        "jsonl": True,
        "temp_paths": True,
    },
    "file_tools": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-file-tools",
        "zig_bin": "eval-file-tools",
        "jsonl": True,
        "temp_paths": True,
        "strip_tmp_ids": True,
    },
    "content_search": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-content-search",
        "zig_bin": "eval-content-search",
        "jsonl": True,
        "temp_paths": True,
        "strip_tmp_ids": True,
    },
    "data_management": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-data-management",
        "zig_bin": "eval-data-management",
        "jsonl": True,
        "temp_paths": True,
        "normalize_timestamps": True,
    },
    "image_info": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-image-info",
        "zig_bin": "eval-image-info",
        "jsonl": True,
        "temp_paths": True,
        "strip_tmp_ids": True,
    },
    "cli_discovery": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-cli-discovery",
        "zig_bin": "eval-cli-discovery",
        "jsonl": True,
        "temp_paths": True,
        "strip_tmp_ids": True,
        "strip_tmp_paths": True,
    },
    "dispatcher": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-dispatcher",
        "zig_bin": "eval-dispatcher",
        "jsonl": True,
    },
    "providers": {
        "fixture_glob": "*/scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-providers",
        "zig_bin": "eval-providers",
        "jsonl": True,
    },
    "oauth": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-oauth",
        "zig_bin": "eval-oauth",
        "jsonl": True,
    },
    "schema": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-schema",
        "zig_bin": "eval-schema",
        "jsonl": True,
    },
    "secrets": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-secrets",
        "zig_bin": "eval-secrets",
        "jsonl": True,
    },
    "profiles": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-profiles",
        "zig_bin": "eval-profiles",
        "jsonl": True,
        "normalize_timestamps": True,
        "strip_tmp_ids": True,
    },
    "multimodal": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-multimodal",
        "zig_bin": "eval-multimodal",
        "jsonl": True,
        "temp_paths": True,
        "strip_tmp_ids": True,
    },
    "provider_types": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-provider-types",
        "zig_bin": "eval-provider-types",
        "jsonl": True,
    },
    "provider_secrets": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-provider-secrets",
        "zig_bin": "eval-provider-secrets",
        "jsonl": True,
    },
    "provider_factory": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-provider-factory",
        "zig_bin": "eval-provider-factory",
        "jsonl": True,
    },
    "agent_tools": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-agent-tools",
        "zig_bin": "eval-agent-tools",
        "jsonl": True,
    },
    "hardware_memory_map": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-hardware-memory-map",
        "zig_bin": "eval-hardware-memory-map",
        "jsonl": True,
    },
    "hardware_board_info": {
        "fixture_glob": "scenario-*/input.jsonl",
        "expected_name": "expected.jsonl",
        "rust_bin": "eval-hardware-board-info",
        "zig_bin": "eval-hardware-board-info",
        "jsonl": True,
    },
}


UUID_V4_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)
RFC3339_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"
)


def normalize_memory_value(value, key: str | None = None):
    if isinstance(value, dict):
        return {k: normalize_memory_value(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [normalize_memory_value(v, key) for v in value]
    if isinstance(value, str):
        if key == "output" and value[:1] in ("{", "["):
            try:
                inner = json.loads(value)
            except json.JSONDecodeError:
                pass
            else:
                inner = normalize_memory_value(inner)
                return json.dumps(inner, separators=(",", ":"), ensure_ascii=False)
        if key == "id" and UUID_V4_RE.match(value):
            return "<UUID>"
        if (
            key == "timestamp"
            or key == "cutoff"
            or (key and key.endswith("_at"))
        ) and RFC3339_RE.match(value):
            return "<TS>"
    return value


TMP_ID_RE = re.compile(
    r"zeroclaw-eval-[A-Za-z0-9_.:-]+-(?:rust|zig)-[A-Za-z0-9_]+"
    r"|zeroclaw-eval-[A-Za-z0-9_.:-]+-\d+-\d+"
)
TMP_PATH_RE = re.compile(
    r"(?:/[^/\"'\s]+)*/"
    r"(?:zeroclaw-eval-[A-Za-z0-9_.:-]+-(?:rust|zig)-[A-Za-z0-9_]+"
    r"|zeroclaw-eval-[A-Za-z0-9_.:-]+-\d+-\d+)"
)


def normalize_tmp_ids(value, *, strip_tmp_paths: bool = False):
    if isinstance(value, dict):
        return {k: normalize_tmp_ids(v, strip_tmp_paths=strip_tmp_paths) for k, v in value.items()}
    if isinstance(value, list):
        return [normalize_tmp_ids(v, strip_tmp_paths=strip_tmp_paths) for v in value]
    if isinstance(value, str):
        if strip_tmp_paths:
            value = TMP_PATH_RE.sub("$TMP", value)
        return TMP_ID_RE.sub("zeroclaw-eval-<TMP>", value)
    return value


def canonicalize(blob: bytes, *, jsonl: bool = False, normalize_memory: bool = False, strip_tmp_ids: bool = False, strip_tmp_paths: bool = False) -> str:
    """Parse JSON and re-emit with sorted keys / no whitespace.

    Rust's eval-parser already emits this form, but normalize defensively
    so a missing \\n or trailing whitespace doesn't fail the diff.
    """
    text = blob.decode("utf-8").strip()
    if not text:
        return ""
    if jsonl:
        lines = []
        for line in text.splitlines():
            if not line.strip():
                continue
            obj = json.loads(line)
            if normalize_memory:
                obj = normalize_memory_value(obj)
            if strip_tmp_ids:
                obj = normalize_tmp_ids(obj, strip_tmp_paths=strip_tmp_paths)
            lines.append(json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
        return "\n".join(lines)
    obj = json.loads(text)
    if normalize_memory:
        obj = normalize_memory_value(obj)
    if strip_tmp_ids:
        obj = normalize_tmp_ids(obj, strip_tmp_paths=strip_tmp_paths)
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def run_runner(binary: Path, input_bytes: bytes) -> tuple[bytes, bytes, int]:
    proc = subprocess.run(
        [str(binary)],
        input=input_bytes,
        capture_output=True,
        timeout=60,
    )
    return proc.stdout, proc.stderr, proc.returncode


def diff(label_a: str, a: str, label_b: str, b: str) -> str:
    return "\n".join(
        difflib.unified_diff(
            a.splitlines(),
            b.splitlines(),
            fromfile=label_a,
            tofile=label_b,
            lineterm="",
        )
    )


def run_subsystem(name: str, rust_dir: Path | None, zig_dir: Path | None,
                  update_golden: bool) -> int:
    cfg = SUBSYSTEMS[name]
    fixtures_root = FIXTURES_DIR / name
    if not fixtures_root.exists():
        print(f"[{name}] no fixtures directory at {fixtures_root}; skipping")
        return 0

    inputs = sorted(fixtures_root.glob(cfg["fixture_glob"]))
    if not inputs:
        print(f"[{name}] no fixtures matched {cfg['fixture_glob']}; skipping")
        return 0

    rust_bin = (rust_dir / cfg["rust_bin"]) if rust_dir else None
    zig_bin = (zig_dir / cfg["zig_bin"]) if zig_dir else None

    failures = 0
    for inp in inputs:
        if "expected_name" in cfg:
            stem = inp.parent.name
            expected = inp.with_name(cfg["expected_name"])
        else:
            stem = inp.name.removesuffix(".input.txt")
            expected = inp.with_name(stem + cfg["expected_suffix"])

        with open(inp, "rb") as f:
            input_bytes = f.read()

        rust_out: str | None = None
        zig_out: str | None = None

        if rust_bin and rust_bin.exists():
            runner_input = input_bytes
            with tempfile.TemporaryDirectory(prefix=f"zeroclaw-eval-{name}-{stem}-rust-") as tmp:
                if cfg.get("temp_paths"):
                    runner_input = input_bytes.replace(b"$TMP", str(Path(tmp)).encode())
                stdout, stderr, rc = run_runner(rust_bin, runner_input)
            if rc != 0:
                print(f"[{name}/{stem}] rust runner failed (rc={rc}): {stderr.decode(errors='replace')}")
                failures += 1
                continue
            rust_out = canonicalize(
                stdout,
                jsonl=cfg.get("jsonl", False),
                normalize_memory=(name == "memory" or cfg.get("normalize_timestamps", False)),
                strip_tmp_ids=cfg.get("strip_tmp_ids", False),
                strip_tmp_paths=cfg.get("strip_tmp_paths", False),
            )

        if zig_bin and zig_bin.exists():
            runner_input = input_bytes
            with tempfile.TemporaryDirectory(prefix=f"zeroclaw-eval-{name}-{stem}-zig-") as tmp:
                if cfg.get("temp_paths"):
                    runner_input = input_bytes.replace(b"$TMP", str(Path(tmp)).encode())
                stdout, stderr, rc = run_runner(zig_bin, runner_input)
            if rc != 0:
                print(f"[{name}/{stem}] zig runner failed (rc={rc}): {stderr.decode(errors='replace')}")
                failures += 1
                continue
            zig_out = canonicalize(
                stdout,
                jsonl=cfg.get("jsonl", False),
                normalize_memory=(name == "memory" or cfg.get("normalize_timestamps", False)),
                strip_tmp_ids=cfg.get("strip_tmp_ids", False),
                strip_tmp_paths=cfg.get("strip_tmp_paths", False),
            )

        if update_golden and rust_out is not None:
            with open(expected, "w") as f:
                f.write(rust_out + "\n")
            print(f"[{name}/{stem}] golden updated")
            continue

        if rust_out is not None and zig_out is not None and rust_out != zig_out:
            print(f"[{name}/{stem}] FAIL: Rust vs Zig diverge")
            print(diff("rust", rust_out, "zig", zig_out))
            failures += 1
            continue

        if expected.exists():
            golden = expected.read_text().strip()
            for label, out in (("rust", rust_out), ("zig", zig_out)):
                if out is not None and out != golden:
                    print(f"[{name}/{stem}] FAIL: {label} vs golden diverge")
                    print(diff("golden", golden, label, out))
                    failures += 1

        if rust_out is not None or zig_out is not None:
            print(f"[{name}/{stem}] OK")

    return failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rust", type=Path, help="dir containing Rust eval binaries")
    ap.add_argument("--zig", type=Path, help="dir containing Zig eval binaries")
    ap.add_argument("--subsystem", choices=list(SUBSYSTEMS.keys()))
    ap.add_argument("--update-golden", action="store_true")
    args = ap.parse_args()

    if args.update_golden and not args.rust:
        print("--update-golden requires --rust", file=sys.stderr)
        return 2
    if not args.rust and not args.zig:
        print("at least one of --rust or --zig is required", file=sys.stderr)
        return 2

    targets = [args.subsystem] if args.subsystem else list(SUBSYSTEMS.keys())
    total_failures = 0
    for sub in targets:
        total_failures += run_subsystem(sub, args.rust, args.zig, args.update_golden)

    if total_failures:
        print(f"\n{total_failures} fixture(s) failed")
        return 1
    print("\nall fixtures OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
