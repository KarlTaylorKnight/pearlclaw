# Rust vs Zig benchmark comparison

- Rust: `rustc 1.95.0 (59807616e 2026-04-14)` on `Intel(R) Xeon(R) W-2191B CPU @ 2.30GHz` (release)
- Zig:  `0.14.1` on `Intel(R) Xeon(R) W-2191B CPU @ 2.30GHz` (ReleaseFast)
- Rust ts: 2026-04-30T06:38:25Z  /  Zig ts: 2026-05-02T06:54:17Z

| Benchmark | Rust mean | Zig mean | Ratio | Verdict |
|---|---:|---:|---:|---|
| `agent_turn_text_only` | 59.99 µs | - | - | rust-only |
| `agent_turn_with_tool_call` | 70.06 µs | - | - | rust-only |
| `memory_count` | 19.92 µs | 399.4 ns | 0.02x | faster |
| `memory_recall_top10` | 296.55 µs | 389.29 µs | 1.31x | slower |
| `memory_store_single` | 171.61 µs | 218.78 µs | 1.27x | slower |
| `native_parse_tool_calls` | 1.46 µs | 17.95 µs | 12.32x | MUCH SLOWER |
| `xml_parse_multi_tool_call` | 5.67 µs | 13.49 µs | 2.38x | MUCH SLOWER |
| `xml_parse_single_tool_call` | 2.70 µs | 6.83 µs | 2.53x | MUCH SLOWER |

## Pilot acceptance gate

- Within-2x on every pilot bench: **3 / 6**
- Faster on at least 3 pilot benches: **1 / 6**
