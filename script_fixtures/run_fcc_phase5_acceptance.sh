#!/usr/bin/env bash
# FCC Phase 5 acceptance harness — hardening, breadth, and the accumulated
# precision items. Each fixture runs under BOTH `Memory.ARC` (default) and
# `-Dmemory=Memory.Tracking`, asserting the expected printed lines, ZERO leaks,
# and no double-free / use-after-free canary. Exits non-zero on any mismatch.
#
# Usage: script_fixtures/run_fcc_phase5_acceptance.sh
# Requires `zig-out/bin/zap` to be freshly built.
set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR ZAP_ERROR_FORMAT ZAP_LEAKS_FATAL ZAP_BACKTRACE

fail=0
DIR=script_fixtures/fcc_phase5

# run_clean "<fixture>" "<expected-substr-1>" ["<expected-substr-2>" ...]
# Asserts, under BOTH managers, that the fixture prints the expected lines,
# leaves ZERO leaks, and triggers no double-free / use-after-free canary.
# Each fixture gets per-run script-cache isolation (the shared cache races
# under concurrency — a pre-existing test-infra issue noted in the plan).
run_clean() {
  local fixture="$1"; shift
  for mgr in "" "-Dmemory=Memory.Tracking"; do
    local label="${mgr:-Memory.ARC}"
    local out
    rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true
    out=$("$ZAP" run $mgr "$DIR/$fixture" 2>&1)
    for needle in "$@"; do
      if printf '%s' "$out" | grep -qF -- "$needle"; then
        echo "  PASS: $fixture [$label] prints '$needle'"
      else
        echo "  FAIL: $fixture [$label] missing '$needle'"; fail=1
        printf '%s\n' "$out" | tail -6 | sed 's/^/        > /'
      fi
    done
    for bad in "memory leak:" "INVALID FREE" "invalid free" "USE-AFTER-FREE" "double fault" "panic: reached"; do
      if printf '%s' "$out" | grep -qF -- "$bad"; then
        echo "  FAIL: $fixture [$label] hit '$bad'"; fail=1
      fi
    done
  done
}

# run_compile_error "<fixture>" "<expected-diagnostic-substr>"
# Asserts the fixture FAILS to compile (a closure effect undischarged at
# compile time) with the expected diagnostic. Only meaningful under ARC (the
# compile failure is manager-independent).
run_compile_error() {
  local fixture="$1"; shift
  local out
  rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true
  out=$("$ZAP" run "$DIR/$fixture" 2>&1)
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  FAIL: $fixture compiled but a compile error was expected"; fail=1
    return
  fi
  for needle in "$@"; do
    if printf '%s' "$out" | grep -qF -- "$needle"; then
      echo "  PASS: $fixture rejected with '$needle'"
    else
      echo "  FAIL: $fixture rejected but missing '$needle'"; fail=1
      printf '%s\n' "$out" | tail -8 | sed 's/^/        > /'
    fi
  done
}

echo "== FCC Phase 5: type-alias-named fn-type in RETURN position (Item 2) =="
run_clean aliased_fn_return_noncapturing.zap "11"
run_clean aliased_fn_return_capturing.zap "110"
run_clean aliased_fn_return_raising.zap "202"
run_clean aliased_fn_return_alias_of_alias.zap "57"

echo "== FCC Phase 5: boxed-path effect precision (Item 3) =="
# 3(a): per-error-type rescue discrimination on the boxed path is precise.
run_clean boxed_per_error_discrimination.zap "alpha-detail" "7"
# 3(b): a CAPTURING returned raising closure invoked undischarged is
# COMPILE-FLAGGED (not runtime-abort), like the bare-fn-ptr case.
run_compile_error boxed_capturing_undischarged_flagged.zap "raises"

echo
if [ "$fail" -eq 0 ]; then
  echo "FCC PHASE 5 ACCEPTANCE: ALL PASS"
else
  echo "FCC PHASE 5 ACCEPTANCE: FAILURES ABOVE"
fi
exit "$fail"
