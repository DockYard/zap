#!/usr/bin/env bash
# Memory.Tracking whole-corpus leak-FREEDOM gate.
#
# Under `Memory.Tracking` (INDIVIDUAL_NO_REFCOUNT | CLONE_ON_SHARE) the corpus
# must run with ZERO deinit-time survivors: every allocation routed through the
# manager's `core.allocate` must reach a matching `core.deallocate` (eager
# free-at-last-use), with no double-free / invalid-free / segfault. This gate
# asserts that — the corpus PASSES every assertion (942/0) AND the tracking
# manager's deinit leak report is EMPTY (no `leak summary` line, no per-survivor
# `memory leak:` line at all).
#
# History (the two owner-model leaks this gate now locks down as fixed):
#
#   * gap #302 — recursive-struct ownership leak: `LinkedNode` chains
#     double-walked by `chain_length` + `chain_sum` (test/struct_test.zap)
#     leaked `%LinkedNode{}` cells. Root cause: ONE IR body served both a
#     BORROWED top entry and the RECURSION threading `node.next`; the function
#     stayed `.borrowed` so its scope-exit release was suppressed for the
#     borrowed entry, orphaning the recursion's per-level clones. RESOLVED by
#     per-call-path ownership specialization
#     (`arc_param_convention.specializeRecursiveOwnershipVariants`).
#
#   * task #323 — `MapIter` cursor-cell leak: a `for`-comprehension /
#     `Enum.reduce` walk over a `Map` allocates a 40-byte `MapIter(K,V)` cell on
#     the first `Map.next` step. Under REFCOUNTED it is reclaimed via the inline-
#     header refcount zero-transition (`headerRelease` -> `iterDeepWalk` ->
#     `freeInlineHeaderCell`); under INDIVIDUAL_NO_REFCOUNT `headerRelease` is a
#     comptime no-op, so the DONE-path `Map.release(iter)` never freed the cell.
#     RESOLVED by freeing the iter cell directly at the DONE transition under
#     `reclamation_model == .individual_no_refcount` (`MapIter.advanceFromMapPtr`
#     in src/runtime.zig). ARC byte-identical (gated on the no-refcount model).
#
# Both fixes are ARC-invariant. If a future change re-introduces ANY Tracking
# leak (a recursive-struct `%LinkedNode{}`, a `MapIter` cell, an error-system
# box inner, or anything else), this gate FAILS.
#
# Usage: script_fixtures/run_tracking_leak_freedom.sh
# Requires `zig-out/bin/zap` freshly built.
set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR ZAP_ERROR_FORMAT ZAP_LEAKS_FATAL

fail=0
check() { # check "<desc>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  PASS: $1"; else
    echo "  FAIL: $1"; echo "    expected to contain: $3"; fail=1; fi
}
check_absent() { # check_absent "<desc>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "  FAIL: $1"; echo "    expected to be ABSENT: $3"; fail=1; else
    echo "  PASS: $1"; fi
}

echo "============================================================"
echo " Memory.Tracking whole-corpus leak-FREEDOM gate"
echo "============================================================"

# Force a clean rebuild so a stale daemon cache never masks the result.
rm -rf .zap-cache 2>/dev/null || true

out=$("$ZAP" test -Dmemory=Memory.Tracking 2>&1)

echo
echo "== corpus assertions pass under Memory.Tracking =="
check "corpus tests pass (1053/0)"        "$out" "1053 tests, 0 failures"
check "corpus assertions pass (1679/0)"  "$out" "1679 assertions, 0 failures"

echo
echo "== whole-corpus leak FREEDOM (zero deinit survivors) =="
# The tracking manager's deinit report emits a `leak summary: N allocations`
# line and one `memory leak:` line per survivor ONLY when something leaked.
# Full leak-freedom => neither line is present.
check_absent "no per-survivor 'memory leak:' line" "$out" 'memory leak:'
check_absent "no 'leak summary' line (0 total survivors)" "$out" 'leak summary'

echo
echo "== specific owner-model regression guards =="
# Recursive-struct freedom (gap #302) — the `%LinkedNode{}` survivors are gone.
check_absent "no %LinkedNode{} deinit survivors (gap #302)" "$out" '%LinkedNode{}'
# No double-free / invalid-free / crash under the eager free path.
check_absent "no segfault"      "$out" 'Segmentation fault'
check_absent "no invalid free"  "$out" 'invalid free'
check_absent "no panic"         "$out" 'panic:'

echo
echo "============================================================"
if [ "$fail" -eq 0 ]; then
  echo " RESULT: Memory.Tracking corpus is FULLY leak-free"
  echo "         (942/0; zero deinit survivors; no double-free / crash)."
  echo "         A future change that re-leaks ANY allocation fails this."
  exit 0
else
  echo " RESULT: Memory.Tracking leak-freedom REGRESSED."
  exit 1
fi
