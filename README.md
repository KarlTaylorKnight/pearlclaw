# Zero-Rust-2-ZIG

Rust → Zig port of [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) with side-by-side eval and benchmark harness.

The Rust workspace under `rust/` is the reference implementation. The Zig workspace under `zig/` is the new implementation. `evals/` holds language-agnostic golden fixtures; `benches/` holds the cross-language benchmark runner.

## Layout

```
rust/         extracted ZeroClaw Rust workspace (reference, READ-MOSTLY)
zig/          new Zig workspace
eval-tools/   standalone Rust binaries that produce golden fixture outputs
evals/        fixtures + Python driver for byte-equal parity tests
benches/      cross-language benchmark runner + normalized results
scripts/      one-shot setup helpers
docs/         porting-notes.md, decisions.md (running logs)
```

## Quick start

```bash
# 1. Toolchains
. "$HOME/.cargo/env"
rustc --version    # 1.87.0
zig version        # 0.14.1

# 2. Rust baseline
cd rust && cargo bench --bench agent_benchmarks
cd .. && benches/runner/run_rust.sh > benches/results/baseline-rust-$(date +%F).json

# 3. Zig pilot (after pilot lands)
cd zig && zig build test
zig build bench -Doptimize=ReleaseFast > ../benches/results/raw-zig-$(date +%F).json

# 4. Eval parity
python3 evals/driver/run_evals.py --rust eval-tools/target/release --zig zig/zig-out/bin

# 5. Comparison report
python3 benches/runner/compare.py \
  benches/results/baseline-rust-$(date +%F).json \
  benches/results/raw-zig-$(date +%F).json \
  > benches/results/reports/$(date +%F)-comparison.md
```

See [the plan](/Users/mac/.claude/plans/i-want-to-convert-eventual-trinket.md) for context, scope, and acceptance gates.
