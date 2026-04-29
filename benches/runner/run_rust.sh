#!/usr/bin/env bash
# Capture Rust criterion bench results into the common JSON schema.
#
# Usage:  benches/runner/run_rust.sh [--quick] > benches/results/raw-rust-<date>.json
#
# Looks at rust/target/criterion/<bench_id>/new/estimates.json for each
# benchmark in scope. Run `cargo bench` first to populate.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRITERION_ROOT="${REPO_ROOT}/rust/target/criterion"

if [[ ! -d "${CRITERION_ROOT}" ]]; then
  echo "no criterion data at ${CRITERION_ROOT}; run \`cargo bench\` first" >&2
  exit 1
fi

# In-scope benchmark IDs (mirrored on the Zig side).
PILOT_IDS=(
  "xml_parse_tool_calls"
  "native_parse_tool_calls"
  "memory_store_single"
  "memory_recall_top10"
  "memory_count"
)

# Host metadata.
OS="$(sw_vers -productName 2>/dev/null || uname)"
OS_VER="$(sw_vers -productVersion 2>/dev/null || uname -r)"
ARCH="$(uname -m)"
CPU="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || lscpu | awk -F: '/Model name/ {print $2; exit}' | xargs || echo unknown)"
RUSTC_VER="$(rustc --version)"
TIMESTAMP="$(date -u +%FT%TZ)"

# Convert criterion estimates.json (per bench) → common schema.
{
  printf '{\n'
  printf '  "lang":"rust",\n'
  printf '  "version":%s,\n' "$(jq -Rn --arg v "${RUSTC_VER}" '$v')"
  printf '  "host":{"os":%s,"arch":%s,"cpu":%s},\n' \
    "$(jq -Rn --arg v "${OS}-${OS_VER}" '$v')" \
    "$(jq -Rn --arg v "${ARCH}" '$v')" \
    "$(jq -Rn --arg v "${CPU}" '$v')"
  printf '  "timestamp":%s,\n' "$(jq -Rn --arg v "${TIMESTAMP}" '$v')"
  printf '  "build_profile":"release",\n'
  printf '  "benchmarks":['

  first=1
  for id in "${PILOT_IDS[@]}"; do
    est="${CRITERION_ROOT}/${id}/new/estimates.json"
    [[ -f "${est}" ]] || continue
    [[ ${first} -eq 0 ]] && printf ','
    first=0
    # criterion estimates.json: we extract mean/median/std_dev point estimates.
    jq -c --arg id "${id}" '
      {
        id: $id,
        samples: 100,
        iterations_per_sample: null,
        ns_per_op: {
          mean: .mean.point_estimate,
          median: .median.point_estimate,
          stddev: .std_dev.point_estimate,
          p99: null
        }
      }' "${est}"
  done
  printf ']\n}\n'
}
