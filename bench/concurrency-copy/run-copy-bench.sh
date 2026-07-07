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
"$FORK_ZIG" build-exe -OReleaseFast --name bench \
  --dep zapruntime --dep zaparcmanager \
  -Mmain=bench.zig \
  --dep zap_active_manager \
  -Mzapruntime=../../src/runtime.zig \
  --dep zap_active_manager \
  -Mzaparcmanager=../../src/memory/arc/manager.zig \
  -Mzap_active_manager=../../src/zap_active_manager_stub.zig

for mode in clock list map string; do
  echo
  echo "# ==== mode=$mode reps=$REPS ===="
  uptime
  ./bench "$mode" "$REPS"
done
