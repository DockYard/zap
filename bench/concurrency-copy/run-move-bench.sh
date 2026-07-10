#!/bin/sh
# E6 re-run driver (P6-J1): build + run the O(1) region-move vs copy bench
# (`move-bench.zig`) against a GATE-ON, STATS-ON build of the real runtime.
#
# The concurrency gate (`RUNTIME_CONCURRENCY_DEFAULT`) and the stat-counter
# collection flag (`COLLECT_ARC_STATS_DEFAULT`) are source-level markers the
# Zap compiler rewrites for user binaries (`src/compiler.zig`, rewrite stages).
# This script performs the SAME textual marker rewrite on a build-local copy
# of `runtime.zig` (the file is standalone — its only imports are module
# dependencies supplied on the command line), so the bench exercises the
# exact gated code paths a concurrent Zap binary runs, with the
# `region_move_*` counters live for the bench's move-vs-copy assertions.
#
# Protocol: one measurement at a time, foreground, `uptime` recorded before
# each mode (ledger convention). `ZAP_SCHED_CORES=1` pins the kernel to ONE
# scheduler so the ping-pong measures the SAME-SCHEDULER round trip — the
# discipline every E6/E5/E1 number in the ledger uses — and keeps the plain
# `u64` stat counters single-threaded (their documented Phase-3 shape).
#
# Usage: ./run-move-bench.sh [mode] [reps]     (mode: move|copy|small|all)

set -eu

ZIG="${ZIG:-$HOME/projects/zig/zig-out/bin/zig}"
MODE="${1:-all}"
REPS="${2:-5}"

cd "$(dirname "$0")"

BUILD_DIR=".move-bench-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Marker rewrites, applied to a build-local copy (the compiler's rewrite
# stages for user binaries): the stage-7 concurrency gate, the stats flag
# (live `region_move_*` counters for the move-vs-copy assertions), and the
# stage-3 source-manager binding (the runtime binds the REAL ARC manager
# through the `zap_active_manager` source module — the production dispatch;
# the weak-linker-symbol path is dead in `.Exe` builds since the manager's
# `.Obj`-gated export, docs in `src/memory/arc/manager.zig`). Fail loudly if
# a marker drifted.
grep -q 'const RUNTIME_CONCURRENCY_DEFAULT: bool = false;' ../../src/runtime.zig || {
    echo "error: RUNTIME_CONCURRENCY_DEFAULT marker not found in src/runtime.zig" >&2
    exit 1
}
grep -q 'const COLLECT_ARC_STATS_DEFAULT: bool = builtin.is_test;' ../../src/runtime.zig || {
    echo "error: COLLECT_ARC_STATS_DEFAULT marker not found in src/runtime.zig" >&2
    exit 1
}
grep -q 'const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = false;' ../../src/runtime.zig || {
    echo "error: RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT marker not found in src/runtime.zig" >&2
    exit 1
}
sed -e 's/const RUNTIME_CONCURRENCY_DEFAULT: bool = false;/const RUNTIME_CONCURRENCY_DEFAULT: bool = true;/' \
    -e 's/const COLLECT_ARC_STATS_DEFAULT: bool = builtin.is_test;/const COLLECT_ARC_STATS_DEFAULT: bool = true;/' \
    -e 's/const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = false;/const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = true;/' \
    ../../src/runtime.zig > "$BUILD_DIR/runtime_gated.zig"

echo "== build (fork zig, ReleaseFast, gate-ON + stats-ON + source-bound-ARC runtime) =="
"$ZIG" build-exe -OReleaseFast --name move-bench \
    --dep zapruntime --dep zapkernel \
    -Mmain=move-bench.zig \
    --dep zap_active_manager \
    "-Mzapruntime=$BUILD_DIR/runtime_gated.zig" \
    -Mzapkernel=../../src/runtime/concurrency/abi.zig \
    -Mzap_active_manager=../../src/memory/arc/manager.zig \
    --cache-dir "$BUILD_DIR/zig-cache" \
    "-femit-bin=$BUILD_DIR/move-bench"

echo "== run (mode=$MODE reps=$REPS, ZAP_SCHED_CORES=1) =="
uptime
ZAP_SCHED_CORES=1 "$BUILD_DIR/move-bench" "$MODE" "$REPS"
