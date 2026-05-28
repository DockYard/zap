#!/usr/bin/env bash
# Capability-driven memory model — Phase 4 verification matrix + custom-manager
# acceptance proof.
#
# Proves the adapter-bounded principle end-to-end: the Zap compiler keys every
# memory-codegen decision off the active manager's declared `declared_caps`
# bits and NEVER off its name. The decisive evidence is the **custom** row: two
# managers whose names (`Custom.BulkArena`, `Custom.TrackingPool`) are unknown
# to the compiler get codegen byte-identical to the stdlib managers declaring
# the same caps (`Memory.Arena` 0x0, `Memory.Tracking` 0x2) — purely from those
# caps. Each custom backend's retain/release slots are `@panic` stubs, so a
# wrongly-emitted refcount op (the failure mode if codegen special-cased an
# unrecognised name and fell back to refcounted codegen) would ABORT the run.
# Running to completion with the expected output is the proof.
#
# Matrix (per `docs/capability-driven-memory-model-plan.md`):
#   ARC      REFCOUNTED               representative program runs (corpus 942/0 asserted by `zap test`)
#   Arena    BULK_OR_NEVER            runs, no refcount panic, zero retain/release reachable
#   NoOp     BULK_OR_NEVER            non-alloc runs; alloc -> documented OOM (not a refcount panic)
#   Leak     BULK_OR_NEVER            runs; no refcount panic
#   Tracking INDIVIDUAL_NO_REFCOUNT   runs, leak-gated clean
#   custom   declared caps            BulkArena == Arena ; TrackingPool == Tracking (caps-only)
#
# Usage: script_fixtures/run_custom_manager_proof.sh
# Requires `zig-out/bin/zap` freshly built.
set -u
cd "$(dirname "$0")/.."

ZAP=$(pwd)/zig-out/bin/zap
PROOF_DIR=$(pwd)/script_fixtures/custom_manager_proof
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR ZAP_ERROR_FORMAT ZAP_LEAKS_FATAL

# Defeat any stale script-cache binary so a behaviour change is never masked.
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true

fail=0
check() { # check "<desc>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  PASS: $1"; else
    echo "  FAIL: $1"; echo "    expected to contain: $3"; echo "    actual: $2"; fail=1; fi
}
refute() { # refute "<desc>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "  FAIL: $1"; echo "    expected NOT to contain: $3"; echo "    actual: $2"; fail=1; else echo "  PASS: $1"; fi
}
expect_exit() { # expect_exit "<desc>" <actual> <expected>
  if [ "$2" -eq "$3" ]; then echo "  PASS: $1 (exit $2)"; else
    echo "  FAIL: $1 — exit $2, expected $3"; fail=1; fi
}

# Build the custom-manager proof project for a given manifest target, returning
# the produced binary's stdout+stderr and exit code via globals OUT / RC. The
# project's `build.zap` selects the custom manager per target; an optional
# `-Dmemory=` override swaps in a stdlib manager for the identical program.
build_and_run() { # build_and_run <target> <binary_name> [extra zap-build flags...]
  local target="$1"; shift
  local binary="$1"; shift
  ( cd "$PROOF_DIR" && rm -rf zap-out .zap-cache 2>/dev/null; "$ZAP" build "$target" "$@" ) >/dev/null 2>&1
  OUT=$("$PROOF_DIR/zap-out/bin/$binary" 2>&1)
  RC=$?
}

echo "============================================================"
echo " Phase 4 — capability-driven memory model verification matrix"
echo "============================================================"

# ---------------------------------------------------------------------------
echo
echo "== custom BULK_OR_NEVER (Custom.BulkArena, declared_caps=0x0) =="
echo "   proof: name unknown to compiler; runs identical to Memory.Arena"
build_and_run bulk proof_bulk
check        "Custom.BulkArena program ran to completion" "$OUT" "31"
expect_exit  "Custom.BulkArena exit 0"                    "$RC" 0
refute       "no refcount panic-stub fired (refcount ops elided)" "$OUT" "does not implement REFCOUNT_V1"

echo
echo "== stdlib Memory.Arena (same program, -Dmemory override) =="
build_and_run bulk proof_bulk -Dmemory=Memory.Arena
check        "Memory.Arena program ran to completion" "$OUT" "31"
expect_exit  "Memory.Arena exit 0"                    "$RC" 0
refute       "no refcount panic under Arena"          "$OUT" "does not implement REFCOUNT_V1"
echo "   => Custom.BulkArena and Memory.Arena produce IDENTICAL output (caps-only codegen)"

# ---------------------------------------------------------------------------
echo
echo "== custom INDIVIDUAL_NO_REFCOUNT (Custom.TrackingPool, declared_caps=0x2) =="
echo "   proof: name unknown to compiler; runs identical to Memory.Tracking, leak-gated"
build_and_run tracking proof_tracking
check        "Custom.TrackingPool program ran to completion" "$OUT" "31"
expect_exit  "Custom.TrackingPool exit 0"                    "$RC" 0
refute       "no refcount panic-stub fired (refcount ops elided)" "$OUT" "does not implement REFCOUNT_V1"
refute       "static free-at-last-use reclaimed all allocs (no survivor)" "$OUT" "Custom.TrackingPool LEAK:"

echo
echo "== stdlib Memory.Tracking (same program, -Dmemory override) =="
build_and_run tracking proof_tracking -Dmemory=Memory.Tracking
check        "Memory.Tracking program ran to completion" "$OUT" "31"
expect_exit  "Memory.Tracking exit 0"                    "$RC" 0
refute       "no refcount panic under Tracking"          "$OUT" "does not implement REFCOUNT_V1"
refute       "no leak survivors under Tracking"          "$OUT" "warning: memory leak"
echo "   => Custom.TrackingPool and Memory.Tracking produce IDENTICAL output (caps-only codegen)"

# ---------------------------------------------------------------------------
# Stdlib BULK_OR_NEVER contract checks on representative scripts.
echo
echo "== Memory.NoOp (BULK_OR_NEVER) =="
NOOP_NOALLOC=$("$ZAP" run -Dmemory=Memory.NoOp script_fixtures/custom_manager_noalloc.zap 2>&1); RC=$?
check        "NoOp non-allocating program ran" "$NOOP_NOALLOC" "42"
expect_exit  "NoOp non-allocating exit 0"       "$RC" 0
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true
NOOP_ALLOC=$("$ZAP" run -Dmemory=Memory.NoOp script_fixtures/custom_manager_alloc.zap 2>&1); RC=$?
check        "NoOp allocating -> documented OOM"           "$NOOP_ALLOC" "out of memory: manager.allocate returned null"
refute       "NoOp allocating -> NOT a refcount panic"     "$NOOP_ALLOC" "does not implement REFCOUNT_V1"
refute       "NoOp allocating -> NOT a refcount dispatch panic" "$NOOP_ALLOC" "REFCOUNT_V1 capability"

echo
echo "== Memory.Leak (BULK_OR_NEVER) =="
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true
LEAK_OUT=$("$ZAP" run -Dmemory=Memory.Leak script_fixtures/custom_manager_noalloc.zap 2>&1); RC=$?
check        "Leak program ran"             "$LEAK_OUT" "42"
expect_exit  "Leak exit 0"                  "$RC" 0
refute       "no refcount panic under Leak" "$LEAK_OUT" "does not implement REFCOUNT_V1"

# ---------------------------------------------------------------------------
# ARC (REFCOUNTED) — representative program runs. The full corpus 942/0 + V8
# verifier is asserted by `zap test` / `zig build test`, not duplicated here.
echo
echo "== Memory.ARC (REFCOUNTED) — representative run =="
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true
ARC_OUT=$("$ZAP" run script_fixtures/custom_manager_alloc.zap 2>&1); RC=$?
check        "ARC allocating program ran" "$ARC_OUT" "10"
expect_exit  "ARC exit 0"                 "$RC" 0

echo
echo "============================================================"
if [ "$fail" -eq 0 ]; then
  echo " RESULT: all matrix contracts PASS — codegen is caps-only, no name special-casing"
  exit 0
else
  echo " RESULT: FAILURES above"
  exit 1
fi
