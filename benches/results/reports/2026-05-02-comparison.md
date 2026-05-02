# Rust vs Zig benchmark comparison

- Rust: `rustc 1.95.0 (59807616e 2026-04-14)` on `Intel(R) Xeon(R) W-2191B CPU @ 2.30GHz` (release)
- Zig:  `0.14.1` on `Intel(R) Xeon(R) W-2191B CPU @ 2.30GHz` (ReleaseFast)
- Rust ts: 2026-04-30T06:38:25Z  /  Zig ts: 2026-05-02T04:23:10Z

| Benchmark | Rust mean | Zig mean | Ratio | Verdict |
|---|---:|---:|---:|---|
| `agent_turn_text_only` | 59.99 µs | - | - | rust-only |
| `agent_turn_with_tool_call` | 70.06 µs | - | - | rust-only |
| `memory_count` | 19.92 µs | 11.47 µs | 0.58x | faster |
| `memory_recall_top10` | 296.55 µs | 1.90 ms | 6.39x | MUCH SLOWER |
| `memory_store_single` | 171.61 µs | 674.30 µs | 3.93x | MUCH SLOWER |
| `native_parse_tool_calls` | 1.46 µs | 202.70 µs | 139.12x | MUCH SLOWER |
| `xml_parse_multi_tool_call` | 5.67 µs | 95.35 µs | 16.82x | MUCH SLOWER |
| `xml_parse_single_tool_call` | 2.70 µs | 56.00 µs | 20.74x | MUCH SLOWER |

## Pilot acceptance gate

- Within-2x on every pilot bench: **1 / 6**
- Faster on at least 3 pilot benches: **1 / 6**
