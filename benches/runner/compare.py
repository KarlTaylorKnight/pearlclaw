#!/usr/bin/env python3
"""Compare two normalized benchmark JSON files (Rust vs Zig) and emit
a markdown table with per-benchmark ratio and verdict.

Usage:
  python3 benches/runner/compare.py rust.json zig.json [--out report.md]

Verdict rules:
  ratio = zig_mean / rust_mean
  - faster:    ratio < 0.95
  - parity:    0.95 <= ratio <= 1.05
  - slower:    ratio > 1.05
  - much slower (red flag): ratio > 2.00
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def fmt_ns(value: float | None) -> str:
    if value is None:
        return "-"
    if value >= 1_000_000:
        return f"{value/1_000_000:.2f} ms"
    if value >= 1_000:
        return f"{value/1_000:.2f} µs"
    return f"{value:.1f} ns"


def verdict(ratio: float) -> str:
    if ratio > 2.00:
        return "MUCH SLOWER"
    if ratio > 1.05:
        return "slower"
    if ratio < 0.95:
        return "faster"
    return "parity"


def index_by_id(blob: dict) -> dict[str, dict]:
    return {b["id"]: b for b in blob.get("benchmarks", [])}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("rust_json", type=Path)
    ap.add_argument("zig_json", type=Path)
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()

    rust = json.loads(args.rust_json.read_text())
    zig = json.loads(args.zig_json.read_text())

    rust_idx = index_by_id(rust)
    zig_idx = index_by_id(zig)
    all_ids = sorted(set(rust_idx.keys()) | set(zig_idx.keys()))

    lines: list[str] = []
    lines.append("# Rust vs Zig benchmark comparison")
    lines.append("")
    lines.append(f"- Rust: `{rust.get('version', '?')}` on `{rust.get('host', {}).get('cpu', '?')}` ({rust.get('build_profile', '?')})")
    lines.append(f"- Zig:  `{zig.get('version', '?')}` on `{zig.get('host', {}).get('cpu', '?')}` ({zig.get('build_profile', '?')})")
    lines.append(f"- Rust ts: {rust.get('timestamp', '?')}  /  Zig ts: {zig.get('timestamp', '?')}")
    lines.append("")
    lines.append("| Benchmark | Rust mean | Zig mean | Ratio | Verdict |")
    lines.append("|---|---:|---:|---:|---|")

    pilot_pass = 0
    pilot_fail = 0
    # The plan's "5 of 5" rule was authored before criterion split
    # xml_parse_tool_calls into single/multi. Treating both halves as one
    # logical pilot bench keeps the gate honest: all 6 of these IDs must be
    # within 2x, and at least 3 should be faster.
    pilot_set = {
        "xml_parse_single_tool_call",
        "xml_parse_multi_tool_call",
        "native_parse_tool_calls",
        "memory_store_single",
        "memory_recall_top10",
        "memory_count",
    }
    faster_count = 0

    for bid in all_ids:
        r = rust_idx.get(bid)
        z = zig_idx.get(bid)
        r_mean = r["ns_per_op"]["mean"] if r else None
        z_mean = z["ns_per_op"]["mean"] if z else None
        if r_mean and z_mean:
            ratio = z_mean / r_mean
            v = verdict(ratio)
            if bid in pilot_set:
                if ratio <= 2.0:
                    pilot_pass += 1
                else:
                    pilot_fail += 1
                if ratio < 0.95:
                    faster_count += 1
            lines.append(f"| `{bid}` | {fmt_ns(r_mean)} | {fmt_ns(z_mean)} | {ratio:.2f}x | {v} |")
        elif r_mean:
            lines.append(f"| `{bid}` | {fmt_ns(r_mean)} | - | - | rust-only |")
        elif z_mean:
            lines.append(f"| `{bid}` | - | {fmt_ns(z_mean)} | - | zig-only |")

    lines.append("")
    lines.append("## Pilot acceptance gate")
    lines.append("")
    lines.append(f"- Within-2x on every pilot bench: **{pilot_pass} / {pilot_pass + pilot_fail}**")
    lines.append(f"- Faster on at least 3 pilot benches: **{faster_count} / {len(pilot_set)}**")

    output = "\n".join(lines) + "\n"
    if args.out:
        args.out.write_text(output)
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
