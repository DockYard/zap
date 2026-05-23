#!/usr/bin/env bash
# Phase 4.c acceptance harness — the leak-attribution subsystem end-to-end
# via `zap run -Dmemory=Memory.Tracking`. Exits non-zero on any mismatch.
#
# Usage: script_fixtures/run_phase_4c_acceptance.sh
#
# Requires `zig-out/bin/zap` to be freshly built.
set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR ZAP_ERROR_FORMAT ZAP_LEAKS_FATAL

# Always recompile from source so a stale script-cache binary never masks a
# behavior change.
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true

fail=0
check() { # check "<desc>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  PASS: $1"; else
    echo "  FAIL: $1"; echo "    expected to contain: $3"; fail=1; fi
}
refute() { # refute "<desc>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "  FAIL: $1"; echo "    expected NOT to contain: $3"; fail=1; else echo "  PASS: $1"; fi
}
expect_exit() { # expect_exit "<desc>" <actual> <expected>
  if [ "$2" -eq "$3" ]; then echo "  PASS: $1 (exit $2)"; else
    echo "  FAIL: $1 — exit $2, expected $3"; fail=1; fi
}

echo "== 1) deliberate leak: attributed unified report (text) =="
out=$("$ZAP" run -Dmemory=Memory.Tracking script_fixtures/phase_4c_deliberate_leak.zap 2>&1)
check  "program ran"            "$out" "built"
check  "unified leak header"    "$out" "warning: memory leak: Leaked 1"
check  "Zap type attributed"    "$out" "%Inner{}"
check  "size + refcount"        "$out" "(40 B), refcount 1"
check  "gutter bar"             "$out" $'│'
check  "allocated-here lead-in" "$out" "allocated here:"
check  "footer corner"          "$out" $'└─'
check  "summary table"          "$out" "leak summary: 1 allocation, 40 bytes total"
check  "per-type rollup"        "$out" "1 x \`%Inner{}\` (40 B)"

echo
echo "== 2) deliberate leak: JSON projection (--error-format=json) =="
out=$("$ZAP" run -Dmemory=Memory.Tracking -Derror-format=json script_fixtures/phase_4c_deliberate_leak.zap 2>&1)
check  "json domain=leak"       "$out" '"domain":"leak"'
check  "json trace_policy"      "$out" '"trace_policy":"allocation"'
check  "json machine_data type" "$out" '"type":"Inner"'
check  "json bytes"             "$out" '"bytes":40'
check  "json refcount"          "$out" '"refcount":1'

echo
echo "== 3) --leaks-fatal: nonzero exit on a leak, zero on a clean run =="
"$ZAP" run -Dmemory=Memory.Tracking -Dleaks-fatal script_fixtures/phase_4c_deliberate_leak.zap >/dev/null 2>&1
expect_exit "leak + --leaks-fatal" $? 7
"$ZAP" run -Dmemory=Memory.Tracking -Dleaks-fatal script_fixtures/phase_4c_clean_program.zap >/dev/null 2>&1
expect_exit "clean + --leaks-fatal" $? 0

echo
echo "== 4) box-in-struct cause-chain: ZERO leaks under Tracking (the #4 fix) =="
out=$("$ZAP" run -Dmemory=Memory.Tracking script_fixtures/phase_1_2_5_e_cause_chain.zap 2>&1)
check  "program output (cause)"  "$out" "inner"
check  "program output (none)"   "$out" "no_cause"
refute "no leak report"          "$out" "memory leak:"
refute "no raw LEAK line"        "$out" "LEAK: ptr="

echo
echo "== 5) clean program: no report, exit 0 =="
out=$("$ZAP" run -Dmemory=Memory.Tracking script_fixtures/phase_4c_clean_program.zap 2>&1)
check  "program output"          "$out" "clean"
refute "no leak report"          "$out" "memory leak:"

echo
echo "== 6) box-ownership stress: no leak, no double-free (canary) under Tracking =="
out=$("$ZAP" run -Dmemory=Memory.Tracking script_fixtures/phase_4c_box_ownership_stress.zap 2>&1)
refute "no leak report"          "$out" "memory leak:"
refute "no invalid free"         "$out" "INVALID FREE"
refute "no use-after-free"       "$out" "USE-AFTER-FREE"
refute "no double fault"         "$out" "double fault"

echo
echo "== 7) determinism: identical report across two runs (modulo ASLR) =="
norm() { "$ZAP" run -Dmemory=Memory.Tracking script_fixtures/phase_4c_deliberate_leak.zap 2>&1 \
  | grep -E "memory leak|leak summary|x \`%" | sed -E 's/0x[0-9a-f]+/0xADDR/g'; }
r1=$(norm); r2=$(norm)
if [ "$r1" = "$r2" ]; then echo "  PASS: deterministic report"; else
  echo "  FAIL: report differs across runs"; fail=1; fi

echo
if [ "$fail" -eq 0 ]; then
  echo "PHASE 4.c ACCEPTANCE: ALL PASS"
else
  echo "PHASE 4.c ACCEPTANCE: FAILURES ABOVE"
fi
exit "$fail"
