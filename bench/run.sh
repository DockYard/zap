#!/usr/bin/env bash
# Benchmark harness for Zap vs peer native compilers (C / Rust / Zig).
#
# Each `bench/<benchmark>/<lang>/` directory contains a self-contained
# implementation of the benchmark. The harness:
#
#   1. Builds every implementation in release / `-O2` / `ReleaseFast`.
#   2. Runs each implementation `RUNS` times at the same `BENCH_DEPTH`.
#   3. Verifies every implementation produces byte-identical output —
#      a divergence is treated as a benchmark failure rather than a
#      "fast but wrong" win.
#   4. Records the best (minimum) wall-clock time per implementation.
#   5. Emits a JSON results document under `bench/results/`.
#
# Usage: bench/run.sh [depth] [runs]
#   depth  default 18  (passes via BENCH_DEPTH env)
#   runs   default 3   (best-of-N timing)

set -euo pipefail

DEPTH="${1:-18}"
RUNS="${2:-3}"
BENCH_ROOT="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$BENCH_ROOT/results"
TMP_DIR="$(mktemp -d -t zap-bench.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$RESULTS_DIR"

ZAP_BIN="$BENCH_ROOT/../zig-out/bin/zap"
ZIG_BIN="${ZIG:-zig}"
CARGO_BIN="${CARGO:-cargo}"
CC_BIN="${CC:-clang}"

# `gdate` (GNU coreutils) gives nanosecond resolution on macOS, but
# isn't shipped — fall back to `python3 -c 'time.time()'` everywhere
# so the harness needs nothing beyond a POSIX shell, the language
# toolchains, and Python.
now_ns() {
  python3 -c 'import time; print(int(time.time_ns()))'
}

# Run a benchmark `RUNS` times. Writes the program's last-run stdout
# to `$TMP_DIR/<label>.out` and the best wall-clock time (ns) to
# `$TMP_DIR/<label>.ns`. The split-file layout dodges shell word-
# splitting on multiline stdout, which the prior pipe-delimited
# variant got wrong.
bench_run() {
  local label="$1"; shift
  local cwd="$1"; shift
  local cmd=("$@")

  local best_ns=""
  for ((i = 0; i < RUNS; i++)); do
    local start end
    start=$(now_ns)
    (cd "$cwd" && BENCH_DEPTH="$DEPTH" "${cmd[@]}") > "$TMP_DIR/$label.out"
    end=$(now_ns)
    local elapsed=$((end - start))
    if [[ -z "$best_ns" || "$elapsed" -lt "$best_ns" ]]; then
      best_ns="$elapsed"
    fi
  done
  printf '%s' "$best_ns" > "$TMP_DIR/$label.ns"
}

build_zap() {
  echo ">> building zap binary_trees" >&2
  cd "$BENCH_ROOT/binary-trees/zap"
  rm -rf zap-out .zap-cache
  "$ZAP_BIN" build binary_trees >/dev/null 2>&1
}

build_c() {
  echo ">> building c binary_trees" >&2
  "$CC_BIN" -O2 -o "$BENCH_ROOT/binary-trees/c/binary_trees" "$BENCH_ROOT/binary-trees/c/binary_trees.c"
}

build_rust() {
  echo ">> building rust binary_trees" >&2
  cd "$BENCH_ROOT/binary-trees/rust"
  "$CARGO_BIN" build --release --quiet
}

build_zig() {
  echo ">> building zig binary_trees" >&2
  cd "$BENCH_ROOT/binary-trees/zig"
  "$ZIG_BIN" build-exe -O ReleaseFast -lc binary_trees.zig
}

build_zap
build_c
build_rust
build_zig

bench_run "zap"  "$BENCH_ROOT/binary-trees/zap"  "./zap-out/bin/binary_trees"
bench_run "c"    "$BENCH_ROOT/binary-trees/c"    "./binary_trees"
bench_run "rust" "$BENCH_ROOT/binary-trees/rust" "./target/release/binary_trees"
bench_run "zig"  "$BENCH_ROOT/binary-trees/zig"  "./binary_trees"

# Cross-check: the C output is the reference. Any divergence aborts
# the run rather than letting a "fast but wrong" implementation
# claim a win.
for label in zap rust zig; do
  if ! diff -q "$TMP_DIR/c.out" "$TMP_DIR/$label.out" >/dev/null; then
    echo "FAIL: $label output diverges from c reference" >&2
    diff "$TMP_DIR/c.out" "$TMP_DIR/$label.out" >&2 || true
    exit 1
  fi
done

# Emit JSON. No jq dependency — the structure is stable enough that
# hand-formatting is fine.
out_path="$RESULTS_DIR/binary-trees-d$DEPTH.json"
{
  printf '{\n'
  printf '  "benchmark": "binary-trees",\n'
  printf '  "depth": %s,\n' "$DEPTH"
  printf '  "runs": %s,\n' "$RUNS"
  printf '  "results": [\n'
  first=1
  for label in zap c rust zig; do
    ns=$(cat "$TMP_DIR/$label.ns")
    [[ $first -eq 1 ]] || printf ',\n'
    printf '    {"lang": "%s", "best_ns": %s}' "$label" "$ns"
    first=0
  done
  printf '\n  ]\n'
  printf '}\n'
} > "$out_path"

echo "wrote $out_path" >&2
cat "$out_path"
