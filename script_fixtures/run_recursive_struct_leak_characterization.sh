#!/usr/bin/env bash
# Recursive-struct Tracking-leak CHARACTERIZATION harness (gap #302 / task #302).
#
# This is a TRACKED-KNOWN-GAP harness, not a leak-freedom test. It asserts that
# the corpus, built under `Memory.Tracking` (INDIVIDUAL_NO_REFCOUNT |
# CLONE_ON_SHARE), still PASSES every test assertion (942/0) while the
# deinit-time leak report surfaces the EXACT known recursive-struct leak: 12
# survivor allocations / 336 bytes (6 `%LinkedNode{}` cells + 6 anonymous
# 40-byte cells). The leaking shape lives in `test/struct_test.zap` (the
# `LinkedNode` recursive-struct tests, esp. "recursive build outlives
# constructing frames" — a chain double-walked by `chain_length` + `chain_sum`).
#
# WHY a harness instead of `assert_no_leaks` in the corpus:
#   * The leak is a DEINIT-TIME survivor, not an assertion failure, so it must
#     not fail the corpus (the corpus stays 942/0 — the no-regression gate).
#   * Wrapping the tests in `assert_no_leaks` ALSO trips on GAP-A-style
#     mid-scope sampling artifacts (drops parked at function scope-exit, freed
#     after the assertion's after-sample), which are NOT real leaks — it would
#     over-report. The deinit survivor count is the ground truth.
#
# ROOT CAUSE (see test/struct_test.zap's gap-#302 comment for the full writeup):
#   `src/ir.zig` `extractRetainKind` classifies every non-list/map aggregate
#   extraction (`node.next`) as `RetainKind.persistent`, which under
#   clone-on-share DEEP-CLONES the recursive struct even when the extracted
#   value flows only into a `.borrowed` (non-owning) recursive call. The
#   spurious per-recursion-level clones and the outer clone's deep-walk-free do
#   not reconcile, orphaning 6 cells. A sound fix (downgrade `.persistent` ->
#   `.normal`/borrow when the extract feeds only borrowing consumers, with
#   post-`arc_liveness` escape analysis, ARC byte-identical) is the
#   consumed-vs-standalone owner model of task #302 — out of Phase-4 scope.
#
# TRIPWIRE: if a future owner-model fix ELIMINATES the leak, this harness FAILS
# (the expected-leak assertions no longer match) — the intended signal to
# update/retire this characterization and flip the corpus to leak-free.
#
# Usage: script_fixtures/run_recursive_struct_leak_characterization.sh
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

echo "============================================================"
echo " Recursive-struct Tracking leak characterization (gap #302)"
echo "============================================================"

# Force a clean rebuild so a stale daemon cache never masks the result.
rm -rf .zap-cache 2>/dev/null || true

out=$("$ZAP" test -Dmemory=Memory.Tracking 2>&1)

echo
echo "== corpus assertions still pass under Memory.Tracking =="
check "corpus tests pass (942/0)"        "$out" "942 tests, 0 failures"
check "corpus assertions pass (1366/0)"  "$out" "1366 assertions, 0 failures"

echo
echo "== the known recursive-struct leak is surfaced at deinit =="
check "deinit leak summary present"      "$out" "leak summary: 12 allocations, 336 bytes total"
check "leaked recursive-struct cell"     "$out" '%LinkedNode{}'

echo
echo "============================================================"
if [ "$fail" -eq 0 ]; then
  echo " RESULT: gap #302 characterized as expected (corpus 942/0; 12-alloc"
  echo "         deinit leak present). A future owner-model fix that removes"
  echo "         the leak will FAIL this harness — update it then."
  exit 0
else
  echo " RESULT: characterization drift — the leak shape changed."
  echo "         If the leak was FIXED, retire this harness and flip the"
  echo "         corpus to leak-free. If it changed, re-characterize."
  exit 1
fi
