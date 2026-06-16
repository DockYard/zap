#!/usr/bin/env bash
# Memory.Tracking whole-corpus leak-FREEDOM gate.
#
# Under `Memory.Tracking` (INDIVIDUAL_NO_REFCOUNT | CLONE_ON_SHARE) the corpus
# must run with ZERO deinit-time survivors: every allocation routed through the
# manager's `core.allocate` must reach a matching `core.deallocate` (eager
# free-at-last-use), with no double-free / invalid-free / segfault. This gate
# asserts that — the corpus PASSES every assertion (zero failures) AND the
# tracking manager's deinit leak report contains nothing beyond the single
# documented benign survivor (see FU-6 below).
#
# Test/assertion TOTALS are NOT hardcoded. The gate asserts the load-bearing
# invariant ("0 failures") and the actual totals are extracted from the run
# output and printed for the record, so ordinary corpus growth never causes a
# spurious count-drift failure. (Historical hardcoded `942 tests` / `1366
# assertions` were stale once the corpus grew to ~1178 / ~1890.)
#
# FU-6 — one benign survivor is tolerated: the Zest test harness leaks exactly
# one 40-byte `%NotConnected{}` box (allocated at lib/zest/case.zap:1). The
# tolerance is EXACT: the leak summary must describe that single 40-byte
# `%NotConnected{}` allocation and nothing else. ANY other survivor (a different
# type, a second allocation, or a larger byte total) fails the gate.
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
# Counts are NOT hardcoded: assert the "0 failures" invariant and surface the
# actual totals. `grep -oE` pulls the canonical summary lines the runner always
# emits ("<N> tests, <M> failures" / "<N> assertions, <M> failures").
tests_line=$(printf '%s\n' "$out" | grep -oE '[0-9]+ tests, [0-9]+ failures' | tail -1)
assertions_line=$(printf '%s\n' "$out" | grep -oE '[0-9]+ assertions, [0-9]+ failures' | tail -1)
if [ -n "$tests_line" ]; then echo "    (observed: $tests_line)"; fi
if [ -n "$assertions_line" ]; then echo "    (observed: $assertions_line)"; fi
check "corpus tests report 0 failures"       "$tests_line"      ", 0 failures"
check "corpus assertions report 0 failures"  "$assertions_line" ", 0 failures"

echo
echo "== whole-corpus leak FREEDOM (only the documented benign survivor) =="
# The tracking manager's deinit report emits a `leak summary: N allocation[s]`
# line plus one per-survivor `memory leak:` line ONLY when something survived.
# The sole tolerated survivor is FU-6's 40-byte `%NotConnected{}` Zest box.
#
# Strategy: collect every leak-report line, then drop the lines that constitute
# exactly the benign FU-6 survivor — its per-survivor `memory leak:`/`N x` lines
# (which name `%NotConnected{}`) AND its summary header (`leak summary: 1
# allocation, 40 bytes total`, whose type name lives on the following `N x`
# line, so it must be excluded by its exact 1-allocation/40-byte text). Any line
# that remains is a real, non-tolerated survivor and fails the gate.
leak_residue=$(printf '%s\n' "$out" \
  | grep -E 'memory leak:|leak summary|^[[:space:]]*[0-9]+ x ' \
  | grep -vF '%NotConnected{}' \
  | grep -vF 'leak summary: 1 allocation, 40 bytes total')
check_absent "no leak evidence beyond the benign %NotConnected{} survivor (FU-6)" "$leak_residue" 'leak'
# Pin the benign survivor's shape EXACTLY: a single 40-byte allocation. A second
# allocation or a larger byte total means a real leak rode in alongside it.
benign_summary=$(printf '%s\n' "$out" | grep -E 'leak summary' | tail -1)
if printf '%s' "$out" | grep -qF '%NotConnected{}'; then
  check "benign survivor is exactly 1 allocation, 40 bytes" "$benign_summary" "1 allocation, 40 bytes total"
fi

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
  echo " RESULT: Memory.Tracking corpus is leak-free"
  echo "         (0 failures; no deinit survivor beyond the benign"
  echo "         %NotConnected{} box; no double-free / invalid-free / crash)."
  echo "         A future change that re-leaks ANY other allocation fails this."
  exit 0
else
  echo " RESULT: Memory.Tracking leak-freedom REGRESSED."
  exit 1
fi
