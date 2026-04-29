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
      [--subsystem parser|memory|dispatcher] \\
      [--update-golden]   # only with --rust; rewrites *.expected.json from Rust output
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import subprocess
import sys
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
    # "memory": ... (added when memory pilot lands)
    # "dispatcher": ... (added when dispatcher pilot lands)
}


def canonicalize(blob: bytes) -> str:
    """Parse JSON and re-emit with sorted keys / no whitespace.

    Rust's eval-parser already emits this form, but normalize defensively
    so a missing \\n or trailing whitespace doesn't fail the diff.
    """
    text = blob.decode("utf-8").strip()
    if not text:
        return ""
    obj = json.loads(text)
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
        stem = inp.name.removesuffix(".input.txt")
        expected = inp.with_name(stem + cfg["expected_suffix"])

        with open(inp, "rb") as f:
            input_bytes = f.read()

        rust_out: str | None = None
        zig_out: str | None = None

        if rust_bin and rust_bin.exists():
            stdout, stderr, rc = run_runner(rust_bin, input_bytes)
            if rc != 0:
                print(f"[{name}/{stem}] rust runner failed (rc={rc}): {stderr.decode(errors='replace')}")
                failures += 1
                continue
            rust_out = canonicalize(stdout)

        if zig_bin and zig_bin.exists():
            stdout, stderr, rc = run_runner(zig_bin, input_bytes)
            if rc != 0:
                print(f"[{name}/{stem}] zig runner failed (rc={rc}): {stderr.decode(errors='replace')}")
                failures += 1
                continue
            zig_out = canonicalize(stdout)

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
