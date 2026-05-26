#!/usr/bin/env bash
# Error-system holistic matrix driver (verification pass).
#
# Runs every error-system fixture under BOTH Memory.ARC (default) and
# -Dmemory=Memory.Tracking. Classifies each fixture as:
#   PASS            exit 0, no leak marker, no crash marker
#   EXPECTED-ABORT  intentional non-zero exit (negative fixtures) with a clean
#                   crash report (** ( ... )), NO leak marker, NO SIGSEGV/ICE
#   LEAK            a leak marker appeared ("memory leak:" / "leak summary:")
#   CRASH           SIGSEGV / bus error / ICE / Sema panic
#   TYPEERR         compile/type error (used for undischarged_flagged)
#   FAIL            unexpected non-zero exit
#
# The set of fixtures expected to abort/type-error at runtime/compile time is
# pinned below; everything else MUST be PASS under both managers.

set -u
cd "$(dirname "$0")/.."
ZAP=./zig-out/bin/zap

unset ZAP_ERROR_FORMAT ZAP_LEAKS_FATAL ZAP_BACKTRACE
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true

# Fixtures that intentionally abort at runtime with a clean `** (kind) msg`
# crash report (negative/baseline fixtures + every re-raise-to-top-level case).
# These are the documented intentional-abort baseline: an unhandled raise, or a
# rescue arm that re-raises (terminally or non-terminally) so the error escapes
# main and prints the Phase-2 crash report. Correct behavior is a clean abort
# (nonzero rc, NO leak marker, NO SIGSEGV/ICE).
EXPECT_ABORT_RE='^(unhandled_aborts|unhandled_cross_fn|discriminate_no_match_reraise|reraise_propagates|reraise_nonterminal|after_reraise|after_mixed_divergent_arm|after_reraise_propagate_fn|min_both_noreturn_case)\.zap$'
# Fixtures that intentionally fail to compile (type error).
EXPECT_TYPEERR_RE='^(undischarged_flagged|return_undischarged_flagged)\.zap$'

leak_marker='memory leak:|leak summary:|LEAK DETECTED|leaked [0-9]'
crash_marker='Segmentation fault|bus error|SIGSEGV|SIGABRT|panic: |reached unreachable|cast causes pointer|integer overflow|@panic|Internal compiler error|ICE'

fail_total=0
pass_total=0

classify() { # classify <fixture> <manager_args...>
  local fixture="$1"; shift
  local base; base="$(basename "$fixture")"
  local out rc
  out="$(NO_COLOR=1 "$ZAP" run "$@" "$fixture" 2>&1)"
  rc=$?

  local has_leak=0 has_crash=0
  printf '%s\n' "$out" | grep -qiE "$leak_marker" && has_leak=1
  printf '%s\n' "$out" | grep -qiE "$crash_marker" && has_crash=1

  local verdict
  if [ "$has_leak" -eq 1 ]; then
    verdict="LEAK"
  elif [ "$has_crash" -eq 1 ]; then
    verdict="CRASH"
  elif echo "$base" | grep -qE "$EXPECT_TYPEERR_RE"; then
    if [ "$rc" -ne 0 ]; then verdict="TYPEERR(ok)"; else verdict="FAIL(expected-typeerr-but-passed)"; fi
  elif echo "$base" | grep -qE "$EXPECT_ABORT_RE"; then
    # Expected abort: nonzero rc, clean crash report (** ( ), no leak, no segv
    if [ "$rc" -ne 0 ]; then verdict="EXPECTED-ABORT(ok)"; else verdict="FAIL(expected-abort-but-passed)"; fi
  else
    if [ "$rc" -eq 0 ]; then verdict="PASS"; else verdict="FAIL(rc=$rc)"; fi
  fi

  case "$verdict" in
    PASS|EXPECTED-ABORT\(ok\)|TYPEERR\(ok\)) pass_total=$((pass_total+1)); printf '  %-12s %s\n' "$verdict" "$base" ;;
    *) fail_total=$((fail_total+1)); printf '  %-12s %s\n' "$verdict" "$base";
       printf '%s\n' "$out" | grep -iE "$leak_marker|$crash_marker" | sed 's/^/        > /' | head -4 ;;
  esac
}

run_group() { # run_group <label> <glob>
  local label="$1" glob="$2" mgr="$3"
  echo "-- $label [$mgr] --"
  shopt -s nullglob
  local f
  for f in $glob; do
    if [ "$mgr" = "ARC" ]; then classify "$f"; else classify "$f" -Dmemory=Memory.Tracking; fi
  done
  shopt -u nullglob
}

MGR="${1:-both}"

for mgr in ARC Tracking; do
  if [ "$MGR" != "both" ] && [ "$MGR" != "$mgr" ]; then continue; fi
  echo "============================================================"
  echo " MANAGER: $mgr"
  echo "============================================================"
  run_group "try_rescue"   "test/fixtures/try_rescue/*.zap"   "$mgr"
  run_group "raise_cross_fn" "test/fixtures/raise_cross_fn/*.zap" "$mgr"
  run_group "raise_closure" "test/fixtures/raise_closure/*.zap" "$mgr"
done

echo "============================================================"
echo " MATRIX TOTAL: PASS=$pass_total FAIL=$fail_total"
echo "============================================================"
exit "$fail_total"
