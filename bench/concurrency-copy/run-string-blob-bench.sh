#!/bin/sh
# P6-J3 string-blob crossover benchmark runner (plan item 6.3).
#
# Builds `string-blob-bench.zig` against the REAL runtime (`src/runtime.zig`,
# real ARC manager binding — identical module graph to `run-copy-bench.sh`)
# plus the REAL blob domain (`src/runtime/concurrency/blob.zig`), then runs
# each mode foreground with `uptime` recorded before every invocation.
# Results go to `docs/concurrency-bench-results.md` § "P6-J3 string-blob
# crossover"; the measured crossover sets `string_blob_promotion_threshold`
# in `src/runtime.zig`.
#
# Usage:  ./run-string-blob-bench.sh [reps]     # default reps = 7
#         ZAP_FORK_ZIG=/path/to/zig ./run-string-blob-bench.sh
set -e

FORK_ZIG="${ZAP_FORK_ZIG:-$HOME/projects/zig/zig-out/bin/zig}"
REPS="${1:-7}"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo "# fork compiler: $FORK_ZIG ($("$FORK_ZIG" version))"
echo "# building string-blob bench (ReleaseFast, real runtime + real ARC manager + real blob domain)..."

BUILD_DIR=".string-blob-bench-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
grep -q 'const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = false;' ../../src/runtime.zig || {
  echo "error: RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT marker not found in src/runtime.zig" >&2
  exit 1
}
sed -e 's/const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = false;/const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = true;/' \
  ../../src/runtime.zig > "$BUILD_DIR/runtime_bound.zig"

"$FORK_ZIG" build-exe -OReleaseFast --name string-blob-bench \
  --dep zapruntime \
  --dep blobdomain \
  -Mmain=string-blob-bench.zig \
  --dep zap_active_manager \
  "-Mzapruntime=$BUILD_DIR/runtime_bound.zig" \
  -Mzap_active_manager=../../src/memory/arc/manager.zig \
  -Mblobdomain=../../src/runtime/concurrency/blob.zig \
  --cache-dir "$BUILD_DIR/zig-cache"

for mode in send append; do
  echo
  echo "# ==== mode=$mode reps=$REPS ===="
  uptime
  ./string-blob-bench "$mode" "$REPS"
done
