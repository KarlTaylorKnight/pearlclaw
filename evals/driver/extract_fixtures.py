#!/usr/bin/env python3
"""Extract parser test inputs from Rust unit tests into fixture files.

Walks a Rust source file, finds `#[test]` blocks, extracts the first
`let response = ...;` string literal in each test, and writes it to
`evals/fixtures/parser/NNN-<test_name>.input.txt`.

After running this, run the Rust eval-parser on each fixture to produce
the matching `*.expected.json` golden files:

  python3 evals/driver/run_evals.py --rust eval-tools/target/release \\
      --subsystem parser --update-golden

Usage:
  python3 evals/driver/extract_fixtures.py \\
      rust/crates/zeroclaw-tool-call-parser/src/lib.rs \\
      evals/fixtures/parser
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

TEST_RE = re.compile(r"^\s*#\[test\]\s*$", re.MULTILINE)
FN_HEAD_RE = re.compile(r"^\s*fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", re.MULTILINE)


def parse_rust_string_at(src: str, start: int) -> tuple[str, int] | None:
    """Parse a Rust string literal starting at `src[start]`.

    Handles `"..."`, `r"..."`, and `r#"..."#` (with arbitrary # count).
    Returns (decoded_value, end_offset) or None if no string found.
    """
    i = start
    n = len(src)
    if i >= n:
        return None

    # Raw string: r"..." or r#"..."# etc.
    if src[i] == "r":
        j = i + 1
        hashes = 0
        while j < n and src[j] == "#":
            j += 1
            hashes += 1
        if j < n and src[j] == '"':
            j += 1
            close_marker = '"' + ("#" * hashes)
            end = src.find(close_marker, j)
            if end < 0:
                return None
            return src[j:end], end + len(close_marker)
        return None

    # Regular string: "..."
    if src[i] == '"':
        j = i + 1
        out = []
        while j < n:
            c = src[j]
            if c == "\\" and j + 1 < n:
                nxt = src[j + 1]
                if nxt == "n":
                    out.append("\n")
                elif nxt == "t":
                    out.append("\t")
                elif nxt == "r":
                    out.append("\r")
                elif nxt == "\\":
                    out.append("\\")
                elif nxt == '"':
                    out.append('"')
                elif nxt == "'":
                    out.append("'")
                elif nxt == "0":
                    out.append("\x00")
                else:
                    # \x.., \u{..}, etc. — pass through as-is. Edge case;
                    # most tests don't use these.
                    out.append(c)
                    out.append(nxt)
                j += 2
            elif c == '"':
                return "".join(out), j + 1
            else:
                out.append(c)
                j += 1
        return None

    return None


def find_response_literal(fn_body: str) -> str | None:
    """Find the first `let response = <literal>;` in a function body."""
    m = re.search(r"let\s+response\s*=\s*", fn_body)
    if not m:
        return None
    start = m.end()
    parsed = parse_rust_string_at(fn_body, start)
    if parsed is None:
        return None
    value, _end = parsed
    return value


def extract_test_blocks(src: str) -> list[tuple[str, int, int]]:
    """Returns list of (test_name, body_start, body_end) for each #[test] fn."""
    blocks = []
    for m in TEST_RE.finditer(src):
        # Find the next `fn name(...) {` after this attribute.
        fn_m = FN_HEAD_RE.search(src, m.end())
        if not fn_m:
            continue
        name = fn_m.group(1)
        # Find the opening '{' after the function name.
        brace = src.find("{", fn_m.end())
        if brace < 0:
            continue
        # Walk braces to find the matching '}'.
        depth = 1
        i = brace + 1
        in_str = None  # None | '"' | 'r#...'
        while i < len(src) and depth > 0:
            c = src[i]
            if in_str is None:
                if c == "{":
                    depth += 1
                    i += 1
                elif c == "}":
                    depth -= 1
                    i += 1
                elif c == "/" and i + 1 < len(src) and src[i + 1] == "/":
                    nl = src.find("\n", i)
                    i = nl + 1 if nl >= 0 else len(src)
                elif c == '"' or (c == "r" and i + 1 < len(src) and src[i + 1] in '"#'):
                    parsed = parse_rust_string_at(src, i)
                    if parsed is None:
                        i += 1
                    else:
                        _v, end = parsed
                        i = end
                else:
                    i += 1
            else:
                i += 1
        if depth == 0:
            blocks.append((name, brace + 1, i - 1))
    return blocks


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src_path = Path(sys.argv[1]).resolve()
    out_dir = Path(sys.argv[2]).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    src = src_path.read_text()
    blocks = extract_test_blocks(src)

    extracted = 0
    skipped = []
    for idx, (name, start, end) in enumerate(blocks, 1):
        body = src[start:end]
        literal = find_response_literal(body)
        if literal is None:
            skipped.append(name)
            continue
        fname = f"{idx:03d}-{name}.input.txt"
        (out_dir / fname).write_text(literal)
        extracted += 1

    print(f"extracted {extracted}/{len(blocks)} fixtures into {out_dir}")
    if skipped:
        print(f"\nskipped {len(skipped)} tests (no `let response = ...` literal):")
        for s in skipped:
            print(f"  - {s}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
