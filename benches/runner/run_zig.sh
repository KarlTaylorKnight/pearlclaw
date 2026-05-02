#!/usr/bin/env bash
# Capture Zig bench results into the common JSON schema.
#
# Usage:  benches/runner/run_zig.sh [--quick] > benches/results/raw-zig-<date>.json
#
# Builds + runs zig/bench/agent_benchmarks.zig in ReleaseFast, then enriches the
# bare {lang, version, build_profile, benchmarks} blob the binary emits with
# host metadata and a UTC timestamp via jq, mirroring run_rust.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ZIG_DIR="${REPO_ROOT}/zig"

if [[ ! -f "${ZIG_DIR}/build.zig" ]]; then
  echo "no zig/build.zig at ${ZIG_DIR}" >&2
  exit 1
fi

# Host metadata (same shape as run_rust.sh).
OS="$(sw_vers -productName 2>/dev/null || uname)"
OS_VER="$(sw_vers -productVersion 2>/dev/null || uname -r)"
ARCH="$(uname -m)"
CPU="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || lscpu | awk -F: '/Model name/ {print $2; exit}' | xargs || echo unknown)"
TIMESTAMP="$(date -u +%FT%TZ)"

# Run the bench binary; only its stdout is the JSON blob (build chatter goes to stderr).
RAW="$(cd "${ZIG_DIR}" && zig build bench -Doptimize=ReleaseFast 2>/dev/null)"

if [[ -z "${RAW}" ]]; then
  echo "zig build bench produced no output" >&2
  exit 1
fi

echo "${RAW}" | jq \
  --arg os "${OS}-${OS_VER}" \
  --arg arch "${ARCH}" \
  --arg cpu "${CPU}" \
  --arg ts "${TIMESTAMP}" \
  '. + {host: {os: $os, arch: $arch, cpu: $cpu}, timestamp: $ts}'
