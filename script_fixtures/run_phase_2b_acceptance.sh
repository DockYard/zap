#!/usr/bin/env bash
# Phase 2.b acceptance harness. Verifies that Zig-level panics and raw
# hardware faults route through the unified Zap crash printer (the root
# `panic` namespace + the hardware-fault signal handlers added in Phase
# 2.b), producing `** (<kind>) <message>` + a symbolized Zap backtrace.
# Exits non-zero on any mismatch.
#
# Usage: script_fixtures/run_phase_2b_acceptance.sh
#
# Requires `zig-out/bin/zap` to be freshly built (it embeds the runtime
# whose ZapPanic namespace + signal handlers this exercises, and links the
# fork lib carrying the begin/end_const_decl C-ABI that injects the root
# `panic` namespace).
set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
DIV0_FIXTURE=script_fixtures/phase_2b_divide_by_zero.zap
SEGV_FIXTURE=script_fixtures/phase_2b_stack_overflow_sigsegv.zap

# A clean lib resolution: never let an ambient override mask the embedded
# fork stdlib path the crash reporter relies on.
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR

fail=0
check() {
  # check "<description>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1"
    echo "    expected to contain: $3"
    fail=1
  fi
}
refute() {
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "  FAIL: $1"
    echo "    expected NOT to contain: $3"
    fail=1
  else
    echo "  PASS: $1"
  fi
}

echo "== 1) integer divide-by-zero (Debug) routes through Zig's panic interface =="
out=$(ZAP_BACKTRACE= "$ZAP" run "$DIV0_FIXTURE" 2>&1)
echo "$out"
check  "arithmetic_error header"     "$out" "** (arithmetic_error) division by zero"
check  "faulting op frame"           "$out" "Kernel.divide_i64"
check  "user divide frame+loc"       "$out" "DivCrash.divide/2 at "
check  "user crash frame"            "$out" "DivCrash.crash/0 at "
check  "user main frame"             "$out" "phase_2b_divide_by_zero.zap:34"
refute "panic plumbing suppressed"   "$out" "ZapPanic"

echo
echo "== 2) divide-by-zero ZAP_BACKTRACE=0: header only =="
out=$(ZAP_BACKTRACE=0 "$ZAP" run "$DIV0_FIXTURE" 2>&1)
echo "$out"
check  "header present"              "$out" "** (arithmetic_error) division by zero"
refute "no backtrace frames"         "$out" "DivCrash.divide"

echo
echo "== 3) divide-by-zero ReleaseSafe still symbolizes =="
out=$(ZAP_BACKTRACE= "$ZAP" run -Doptimize=ReleaseSafe "$DIV0_FIXTURE" 2>&1)
echo "$out"
check  "ReleaseSafe header"          "$out" "** (arithmetic_error) division by zero"

echo
echo "== 4) hardware fault (stack-overflow SIGSEGV) caught by the signal handler =="
out=$(ZAP_BACKTRACE= "$ZAP" run "$SEGV_FIXTURE" 2>&1)
echo "$out"
check  "segmentation_fault header"   "$out" "** (segmentation_fault)"
check  "faulting Zap frame+loc"      "$out" "Recurse.descend/1 at "
check  "faulting source line"        "$out" "phase_2b_stack_overflow_sigsegv.zap:22"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL PHASE 2.b ACCEPTANCE CHECKS PASSED"
else
  echo "PHASE 2.b ACCEPTANCE: FAILURES ABOVE"
fi
exit "$fail"
