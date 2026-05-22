#!/usr/bin/env bash
# Phase 2.a acceptance harness. Exercises the async-signal-safe crash
# reporter end-to-end via `zap run`, across ZAP_BACKTRACE modes and optimize
# levels, asserting the expected output. Exits non-zero on any mismatch.
#
# Usage: script_fixtures/run_phase_2a_acceptance.sh
#
# Requires `zig-out/bin/zap` to be freshly built (it embeds the fork stdlib
# whose std.debug dSYM fallback the crash reporter relies on).
set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
ERR_FIXTURE=script_fixtures/phase_2a_raise_backtrace.zap
STR_FIXTURE=script_fixtures/phase_2a_raise_string_backtrace.zap

# A clean lib resolution: never let an ambient override mask the embedded
# fork stdlib path we are validating.
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

echo "== 1) default ZAP_BACKTRACE (short): header + symbolized Zap backtrace =="
out=$(ZAP_BACKTRACE= "$ZAP" run "$ERR_FIXTURE" 2>&1)
echo "$out"
check  "kind+message header"        "$out" "** (boom_error) kaboom from deeper"
check  "deeper frame qualified+loc" "$out" "Demo.deeper/0 at "
check  "deeper frame source line"   "$out" "phase_2a_raise_backtrace.zap:32"
check  "blow_up frame"              "$out" "Demo.blow_up/0 at "
refute "raise plumbing suppressed"  "$out" "do_raise"
refute "Zig startup glue trimmed"   "$out" "callMain"

echo
echo "== 2) ZAP_BACKTRACE=0: header only, NO backtrace =="
out=$(ZAP_BACKTRACE=0 "$ZAP" run "$ERR_FIXTURE" 2>&1)
echo "$out"
check  "header present"             "$out" "** (boom_error) kaboom from deeper"
refute "no backtrace frames"        "$out" "Demo.deeper/0"

echo
echo "== 3) ZAP_BACKTRACE=full: header + all Zap frames =="
out=$(ZAP_BACKTRACE=full "$ZAP" run "$ERR_FIXTURE" 2>&1)
echo "$out"
check  "deeper frame"               "$out" "Demo.deeper/0 at "
check  "blow_up frame"              "$out" "Demo.blow_up/0 at "

echo
echo "== 4) ReleaseSafe: symbolized Zap backtrace (dSYM + side-table) =="
out=$(ZAP_BACKTRACE= "$ZAP" run -Doptimize=ReleaseSafe "$ERR_FIXTURE" 2>&1)
echo "$out"
check  "ReleaseSafe header"         "$out" "** (boom_error) kaboom from deeper"
check  "ReleaseSafe Zap symbol+loc" "$out" "Demo.deeper/0 at "

echo
echo "== 5) legacy string raise: RuntimeError kind + symbolized backtrace =="
out=$("$ZAP" run "$STR_FIXTURE" 2>&1)
echo "$out"
check  "runtime_error header"       "$out" "** (runtime_error) string boom from inner"
check  "inner frame"                "$out" "Helper.inner/0 at "
check  "outer frame"                "$out" "Helper.outer/0 at "
refute "raise plumbing suppressed"  "$out" "Kernel.raise"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL PHASE 2.a ACCEPTANCE CHECKS PASSED"
else
  echo "PHASE 2.a ACCEPTANCE: FAILURES ABOVE"
fi
exit "$fail"
