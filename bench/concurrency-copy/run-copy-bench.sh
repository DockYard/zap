#!/bin/sh
# E6 copy-crossover benchmark runner (plan item 2.8 / P2-J9).
#
# Builds `bench.zig` against the REAL runtime (`src/runtime.zig`) linked to the
# REAL production ARC manager (`src/memory/arc/manager.zig`), then runs each
# mode foreground, printing `uptime` immediately before every invocation (the
# ledger's quiet-machine discipline). Results go to `docs/concurrency-bench-
# results.md` § E6.
#
# Usage:  ./run-copy-bench.sh [reps]           # default reps = 7
#         ZAP_FORK_ZIG=/path/to/zig ./run-copy-bench.sh
#
# MUST build with the Zap Zig fork (ledger convention for the concurrency
# series; the fork also provides the `std.process.Init.Minimal` entry). This
# bench uses NO fibers, so the fork's x30-clobber fix is not itself required.
set -e

FORK_ZIG="${ZAP_FORK_ZIG:-$HOME/projects/zig/zig-out/bin/zig}"
REPS="${1:-7}"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo "# fork compiler: $FORK_ZIG ($("$FORK_ZIG" version))"
echo "# building bench (ReleaseFast, real runtime + real ARC manager)..."

# Bind the REAL ARC manager as the `zap_active_manager` SOURCE MODULE with
# `RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT` rewritten to true on a build-local
# runtime copy — the production binding every compiler-driven user binary
# uses. (The original weak-linker-symbol binding died when the manager's
# `zap_memory_section` export became `.Obj`-gated with P3-J3's per-spawn
# managers; an `.Exe` build like this bench no longer emits the symbol.)
BUILD_DIR=".copy-bench-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
grep -q 'const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = false;' ../../src/runtime.zig || {
  echo "error: RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT marker not found in src/runtime.zig" >&2
  exit 1
}
sed -e 's/const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = false;/const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = true;/' \
  ../../src/runtime.zig > "$BUILD_DIR/runtime_bound.zig"

"$FORK_ZIG" build-exe -OReleaseFast --name bench \
  --dep zapruntime \
  -Mmain=bench.zig \
  --dep zap_active_manager \
  "-Mzapruntime=$BUILD_DIR/runtime_bound.zig" \
  -Mzap_active_manager=../../src/memory/arc/manager.zig \
  --cache-dir "$BUILD_DIR/zig-cache"

for mode in clock list map string; do
  echo
  echo "# ==== mode=$mode reps=$REPS ===="
  uptime
  ./bench "$mode" "$REPS"
done
