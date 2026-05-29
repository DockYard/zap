#!/usr/bin/env bash
# Recursive-struct Tracking-leak FREEDOM gate (gap #302 / task #302).
#
# Gap #302 was the recursive-struct ownership leak: under `Memory.Tracking`
# (INDIVIDUAL_NO_REFCOUNT | CLONE_ON_SHARE) the `LinkedNode` recursive-struct
# tests in `test/struct_test.zap` (the chain double-walked by `chain_length` +
# `chain_sum`) leaked 6 `%LinkedNode{}` deinit survivors. The root cause was a
# per-call-INSTANCE ownership ambiguity: ONE IR body served both a BORROWED top
# entry (the sibling reuses `list`, so the IR builder hands the callee a fresh
# share-CLONE) and the RECURSION threading `node.next`; the function stayed
# `.borrowed` (so its param scope-exit release was suppressed for the borrowed
# entry), but that same release is the one that must free the recursion's
# per-level clones — so they orphaned.
#
# RESOLVED by per-call-path ownership specialization
# (`src/arc_param_convention.zig` `specializeRecursiveOwnershipVariants`, gated on
# clone-on-share): the leaking self-recursive walker is split into a second
# `.owned`-ENTRY variant and the recursion edge is retargeted to it, so the
# recursion MOVES `node.next` (no per-level clone) exactly like the move-entry
# `chain_sum`. ARC is byte-identical (no variant created under REFCOUNTED).
#
# THIS GATE asserts the recursive-struct leak stays ELIMINATED: the corpus
# under `Memory.Tracking` PASSES every assertion (942/0) AND the deinit-time
# leak report contains ZERO `%LinkedNode{}` survivors (recursive-struct
# freedom). If a future change re-introduces a recursive-struct leak, this gate
# FAILS.
#
# NOTE on the residual error-cell leak (NOT gap #302, NOT a recursive-struct
# leak): the corpus still reports a small number of 40-byte `AlphaError`/
# `BetaError`-class survivors from the error-system `raise`/`rescue` corpus
# (e.g. `test/rescue_literal_arms_test.zap`). That is a PRE-EXISTING, systemic
# error-system leak (present on pristine, untouched by the gap-#302 fix, which
# only specializes the recursive-struct walker under clone-on-share). It is
# tracked separately under the error-system work, not here. This gate therefore
# checks recursive-struct freedom SPECIFICALLY (no `%LinkedNode{}` survivors),
# not whole-corpus leak-freedom.
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
check_absent() { # check_absent "<desc>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "  FAIL: $1"; echo "    expected to be ABSENT: $3"; fail=1; else
    echo "  PASS: $1"; fi
}

echo "============================================================"
echo " Recursive-struct Tracking leak FREEDOM gate (gap #302)"
echo "============================================================"

# Force a clean rebuild so a stale daemon cache never masks the result.
rm -rf .zap-cache 2>/dev/null || true

out=$("$ZAP" test -Dmemory=Memory.Tracking 2>&1)

echo
echo "== corpus assertions pass under Memory.Tracking =="
check "corpus tests pass (942/0)"        "$out" "942 tests, 0 failures"
check "corpus assertions pass (1366/0)"  "$out" "1366 assertions, 0 failures"

echo
echo "== recursive-struct leak is ELIMINATED (gap #302) =="
# The recursive-struct survivors were the `%LinkedNode{}` cells. The fix frees
# them; the deinit leak report must contain NONE.
check_absent "no %LinkedNode{} deinit survivors" "$out" '%LinkedNode{}'

echo
echo "============================================================"
if [ "$fail" -eq 0 ]; then
  echo " RESULT: gap #302 RESOLVED — recursive-struct leak eliminated"
  echo "         (corpus 942/0; zero %LinkedNode{} survivors under Tracking)."
  echo "         A future regression that re-leaks a recursive struct fails this."
  exit 0
else
  echo " RESULT: recursive-struct leak FREEDOM regressed — gap #302 re-opened."
  exit 1
fi
