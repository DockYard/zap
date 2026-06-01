#!/usr/bin/env bash
# Consolidated target-capability VERIFICATION MATRIX — the standing gate for
# the whole language-level target-capability campaign (task #360, Phase 4
# lock-in; docs/target-capability-model-plan.md).
#
# This is the campaign's single orchestrating harness. It does NOT duplicate
# the per-phase checks — it RUNS them, plus the two Zig CI lock-in tests, and
# aggregates one PASS/FAIL verdict:
#
#   1. AUDIT (capability-not-OS-name lock-in) — `zig build target-capability-audit`
#      (src/target_capability_audit.zig): every `@available_on` in lib/**/*.zap
#      names a CAPABILITY not an OS, and the ctfe.zig gate-decision region
#      smuggles no OS-name literal.
#   2. SINGLE-SOURCE invariant — the target_caps ↔ RuntimeOs.caps test, asserting
#      every runtime-primitive cap (:signals/:terminal/:backtrace) matches the
#      RuntimeOs backend truth for every supported target (drift-proof).
#   3. PHASE 1 acceptance — comptime `@target` folding (native/wasi/windows).
#   4. PHASE 2 acceptance — `@available_on` gating + the target_capability
#      diagnostic + the escape hatch (native/wasi/windows).
#   5. PHASE 3 acceptance — the target-sensitive stdlib SWEEP (native/wasi/windows).
#
# The per-phase harnesses each already span the native / wasm32-wasi /
# x86_64-windows-gnu matrix internally (native folding + cross-build `file`
# PE32+/WebAssembly checks + `wasmtime` runs + expected-compile-failure cases),
# so running them here is the cross-target matrix. NEVER uses `zig build
# zir-test` (the user runs that); every behavioral check goes through the real
# ZIR path via `zap run` / cross-build / `wasmtime`, exactly as the phase
# harnesses do.
#
# Usage:
#   script_fixtures/run_target_capability_matrix.sh
#
# Requirements:
#   * A freshly built `zig-out/bin/zap` (the phase harnesses re-embed the
#     stdlib's gates into it). Build it first with `zig build` per the README.
#   * `zig` on PATH and the Zap Zig fork lib dir. Override the fork lib dir with
#     ZAP_FORK_ZIG_LIB_DIR=/path/to/zig/lib if it is not at ~/projects/zig/lib.
#   * `wasmtime` is OPTIONAL: the phase harnesses link-check (`file`) without it
#     and SKIP the run-checks if it is absent (they still PASS the link bar).
set -u
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
ZAP="$ROOT/zig-out/bin/zap"
FORK_ZIG_LIB_DIR="${ZAP_FORK_ZIG_LIB_DIR:-$HOME/projects/zig/lib}"

# Don't let an ambient override mask the embedded fork stdlib in the sub-checks.
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR ZAP_ERROR_FORMAT ZAP_LEAKS_FATAL
pkill -9 -f "__manifest-incremental-daemon" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight_ok=1
if ! command -v zig >/dev/null 2>&1; then
  echo "PREFLIGHT FAIL: 'zig' not found on PATH (needed for the audit + single-source tests)."
  preflight_ok=0
fi
if [ ! -f "$FORK_ZIG_LIB_DIR/std/std.zig" ]; then
  echo "PREFLIGHT FAIL: fork zig-lib-dir not found at '$FORK_ZIG_LIB_DIR'."
  echo "  Set ZAP_FORK_ZIG_LIB_DIR=/path/to/zig/lib (the Zap Zig fork's lib/)."
  preflight_ok=0
fi
if [ ! -x "$ZAP" ]; then
  echo "PREFLIGHT FAIL: '$ZAP' missing. Build it first: 'zig build' (see README)."
  echo "  The Phase 1/2/3 acceptance harnesses run this binary and need the"
  echo "  current stdlib gates embedded in it."
  preflight_ok=0
fi
if [ "$preflight_ok" -ne 1 ]; then
  echo
  echo "MATRIX ABORTED: preflight requirements unmet (see above)."
  exit 2
fi

HAVE_WASMTIME=0; command -v wasmtime >/dev/null 2>&1 && HAVE_WASMTIME=1
[ "$HAVE_WASMTIME" -eq 1 ] || echo "NOTE: wasmtime not installed — phase harnesses link-check only (still gate)."

# ---------------------------------------------------------------------------
# Sub-check runner: run a labeled command, capture rc, tail output on failure.
# ---------------------------------------------------------------------------
fail_total=0
pass_total=0
declare -a RESULTS=()

run_check() { # run_check "<label>" <command...>
  local label="$1"; shift
  echo "============================================================"
  echo " RUN: $label"
  echo "============================================================"
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -eq 0 ]; then
    pass_total=$((pass_total + 1))
    RESULTS+=("PASS  $label")
    echo "-> PASS: $label"
  else
    fail_total=$((fail_total + 1))
    RESULTS+=("FAIL  $label (rc=$rc)")
    echo "-> FAIL: $label (rc=$rc)"
  fi
  echo
}

# 1. AUDIT — capability-not-OS-name lock-in (scans lib/**/*.zap + ctfe.zig).
run_check "1. capability-not-OS-name audit (zig build target-capability-audit)" \
  zig build target-capability-audit --zig-lib-dir "$FORK_ZIG_LIB_DIR"

# 2. SINGLE-SOURCE invariant — target_caps <-> RuntimeOs.caps, all primitive
#    caps x all supported targets (run the one focused test for speed).
run_check "2. single-source invariant (target_caps <-> RuntimeOs.caps, incl. :backtrace)" \
  zig test src/target_caps.zig --zig-lib-dir "$FORK_ZIG_LIB_DIR" --test-filter "single-source"

# 3-5. The per-phase acceptance harnesses (each spans native/wasi/windows).
run_check "3. Phase 1 acceptance — comptime @target folding" \
  bash script_fixtures/run_target_comptime_acceptance.sh

run_check "4. Phase 2 acceptance — @available_on gating + diagnostic + escape hatch" \
  bash script_fixtures/run_target_capability_acceptance.sh

run_check "5. Phase 3 acceptance — target-sensitive stdlib sweep" \
  bash script_fixtures/run_target_capability_phase3_acceptance.sh

# ---------------------------------------------------------------------------
# Aggregate verdict
# ---------------------------------------------------------------------------
echo "============================================================"
echo " TARGET-CAPABILITY VERIFICATION MATRIX — SUMMARY"
echo "============================================================"
for r in "${RESULTS[@]}"; do
  printf '  %s\n' "$r"
done
echo "------------------------------------------------------------"
echo " TOTAL: PASS=$pass_total FAIL=$fail_total"
echo "============================================================"
if [ "$fail_total" -eq 0 ]; then
  echo "ALL target-capability matrix checks PASSED — the model is ENFORCED:"
  echo "  audit (capability-not-name) + single-source (no codegen/comptime drift)"
  echo "  + Phase 1/2/3 acceptance across native/wasm32-wasi/x86_64-windows-gnu."
else
  echo "SOME target-capability matrix checks FAILED (see SUMMARY above)."
fi
exit "$fail_total"
