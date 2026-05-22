#!/usr/bin/env bash
# Phase 2.a acceptance harness. Exercises the crash reporter end-to-end via
# `zap run` and a ReleaseSafe `zap build`, across ZAP_BACKTRACE modes.
#
# Usage: script_fixtures/run_phase_2a_acceptance.sh
#
# Requires `zig-out/bin/zap` to be freshly built against the Phase 2.a fork.
set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
FIXTURE=script_fixtures/phase_2a_raise_backtrace.zap

echo "============================================================"
echo "1) default ZAP_BACKTRACE (short) — header + symbolized Zap backtrace"
echo "============================================================"
unset ZAP_BACKTRACE
"$ZAP" run "$FIXTURE" 2>&1; echo "[exit=$?]"

echo
echo "============================================================"
echo "2) ZAP_BACKTRACE=0 — header only, NO backtrace"
echo "============================================================"
ZAP_BACKTRACE=0 "$ZAP" run "$FIXTURE" 2>&1; echo "[exit=$?]"

echo
echo "============================================================"
echo "3) ZAP_BACKTRACE=full — header + ALL frames"
echo "============================================================"
ZAP_BACKTRACE=full "$ZAP" run "$FIXTURE" 2>&1; echo "[exit=$?]"

echo
echo "============================================================"
echo "4) ReleaseSafe build — symbolized Zap backtrace (DWARF + side-table)"
echo "============================================================"
OUT=$(mktemp -d)/demo_phase2a
"$ZAP" build "$FIXTURE" -Doptimize=ReleaseSafe -femit-bin="$OUT" 2>&1 | tail -3
echo "--- side-table present? ---"
ls -la "${OUT}.zap-symbols" 2>/dev/null || echo "(no sidecar)"
echo "--- running ReleaseSafe binary ---"
"$OUT" 2>&1; echo "[exit=$?]"
