#!/usr/bin/env bash
# Follow-up #342 acceptance harness — the ARC and Tracking memory managers use
# atomics that are an OPTIONAL target feature on wasm32; this gates the
# guarantee that they lower + run correctly on single-threaded wasm32-wasi.
#
#   * ARC      — refcounts via `@atomicRmw(u32, .Add/.Sub, .monotonic/.acq_rel)`
#                (src/memory/arc/manager.zig ~949).
#   * Tracking — spinlock via `@cmpxchgStrong(.acquire, .monotonic)` +
#                `@atomicStore(.release)` (src/memory/tracking/manager.zig).
#
# On single-threaded wasm32-wasi LLVM lowers these ordered atomics to plain
# non-atomic loads/stores, so no `+atomics` feature and no ordering relaxation
# is required — this harness PROVES that empirically and keeps it gated:
#   * NATIVE: each fixture runs under its manager and prints the expected rows
#     (regression anchor — the fixtures genuinely drive the atomic refcount /
#     spinlock paths).
#   * WASI: each fixture cross-builds `-Dtarget=wasm32-wasi`, links as a wasm
#     MVP binary, and runs under `wasmtime` with byte-identical output, exit 0,
#     and NO leak / double-free diagnostic (a miscompiled atomic would deadlock,
#     corrupt the tracking table, or prematurely free a refcounted value).
#   * Arena / Leak: spot-confirmed to still cross-build for wasm (the
#     atomics-free baseline — all non-GC managers are wasm-portable).
#
# Usage: script_fixtures/run_wasm_atomic_managers.sh
# Requires a freshly built `zig-out/bin/zap` and `wasmtime` on PATH.
set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
ARC_FIXTURE=script_fixtures/wasm_arc_atomic_refcount.zap
TRACKING_FIXTURE=script_fixtures/wasm_tracking_atomic_spinlock.zap

# The two fixtures share the canonical `[{String, i64}]` sort+each shape, so
# both expect the same descending-by-count rows.
EXPECTED=$'AT 150\nAC 100\nGT 50'

# Never let an ambient override mask the embedded fork stdlib.
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR

fail=0
check() { # check "<desc>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  PASS: $1"; else
    echo "  FAIL: $1"; echo "    expected to contain: $3"; echo "    got: $2"; fail=1; fi
}

check_absent() { # check_absent "<desc>" "<haystack>" "<forbidden-regex>"
  if printf '%s' "$2" | grep -qiE -- "$3"; then
    echo "  FAIL: $1"; echo "    forbidden pattern present: $3"; echo "    got: $2"; fail=1
  else echo "  PASS: $1"; fi
}

artifact_of() { # artifact_of "<cross-build output>"
  printf '%s' "$1" | grep -oE '/Users/[^ ]*/script' | head -1
}

# run_manager_matrix "<manager>" "<fixture>"  — native run + wasm cross + wasmtime
run_manager_matrix() {
  local manager="$1" fixture="$2"

  echo "-- NATIVE ($manager) --"
  local nout
  nout=$("$ZAP" run -Dmemory="$manager" "$fixture" 2>&1)
  echo "$nout"
  check "native rows ($manager)" "$nout" "$EXPECTED"
  check_absent "native no leak/double-free ($manager)" "$nout" 'leak summary|memory leak:|double[ -]?free'

  echo "-- WASI cross-build + wasmtime ($manager) --"
  local build art out rc
  build=$("$ZAP" run -Dmemory="$manager" -Dtarget=wasm32-wasi "$fixture" 2>&1)
  check "wasm cross-build succeeded ($manager)" "$build" "Cross-compiled for 'wasm32-wasi'"
  art=$(artifact_of "$build")
  if [ -z "$art" ] || [ ! -f "$art" ]; then
    echo "  FAIL: no wasm artifact produced ($manager)"; echo "$build"; fail=1; return
  fi
  check "wasm artifact format ($manager)" "$(file "$art" 2>/dev/null)" "WebAssembly"
  out=$(wasmtime --dir=. "$art" 2>&1); rc=$?
  echo "$out"
  check "wasmtime rows ($manager)" "$out" "$EXPECTED"
  check_absent "wasmtime no leak/double-free/trap ($manager)" "$out" \
    'leak summary|memory leak:|double[ -]?free|wasm backtrace|trap|unreachable'
  if [ "$rc" -ne 0 ]; then echo "  FAIL: wasmtime exit $rc ($manager)"; fail=1
  else echo "  PASS: wasmtime exit 0 ($manager)"; fi
}

if ! command -v wasmtime >/dev/null 2>&1; then
  echo "SKIP: wasmtime not installed — cannot run the wasm half of the matrix"
  exit 0
fi

echo "== 1) ARC atomic refcount (@atomicRmw .monotonic/.acq_rel) on wasm32-wasi =="
run_manager_matrix Memory.ARC "$ARC_FIXTURE"

echo
echo "== 2) Tracking atomic spinlock (@cmpxchgStrong + @atomicStore) on wasm32-wasi =="
run_manager_matrix Memory.Tracking "$TRACKING_FIXTURE"

echo
echo "== 3) Arena / Leak still cross-build for wasm (atomics-free baseline) =="
for mgr in Memory.Arena Memory.Leak; do
  build=$("$ZAP" run -Dmemory="$mgr" -Dtarget=wasm32-wasi "$ARC_FIXTURE" 2>&1)
  check "$mgr cross-builds for wasm" "$build" "Cross-compiled for 'wasm32-wasi'"
  art=$(artifact_of "$build")
  if [ -n "$art" ] && [ -f "$art" ]; then
    out=$(wasmtime --dir=. "$art" 2>&1)
    check "$mgr wasmtime rows" "$out" "$EXPECTED"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL WASM ATOMIC-MANAGER CHECKS PASSED (ARC + Tracking lower + run on wasm32-wasi)"
else
  echo "WASM ATOMIC-MANAGER CHECKS: FAILURES ABOVE"
  exit 1
fi
