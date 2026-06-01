#!/usr/bin/env bash
# Phase D acceptance harness — the crash handler (Domain B) is now in the
# `runtime_os` seam, per-OS. This verifies the portability matrix:
#
#   * NATIVE: a real hardware SIGSEGV and a software panic still produce the
#     unified Zap crash report + symbolized backtrace, byte-identical to
#     pre-Phase-D (delegated to the existing Phase-2.b harness, which exercises
#     the migrated `RuntimeOs.installCrashHandlers` -> `faultSignalHandler`
#     -> `crashFromFault` path).
#   * WASI: `installCrashHandlers` is a comptime no-op (`supports_signals=false`),
#     yet a RECOVERABLE `raise` STILL renders its crash report through the
#     portable console seam under `wasmtime`; a HARDWARE fault traps cleanly.
#   * WINDOWS: the VEH crash backend (`AddVectoredExceptionHandler` + the
#     exception-code -> Zap-kind map + `cpu_context.fromWindowsContext`) links
#     as a PE32+; if `wine` is available, a faulting fixture emits a Zap crash
#     report (address-level OK), else link + `file` is the bar.
#
# Usage: script_fixtures/run_phase_d_crash_portability.sh
# Requires a freshly built `zig-out/bin/zap` (re-embeds the runtime + seam).
set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
WASI_RAISE=script_fixtures/phase_d_wasi_recoverable_raise.zap
WASI_FAULT=script_fixtures/phase_2b_stack_overflow_sigsegv.zap
WIN_FAULT=script_fixtures/phase_2b_divide_by_zero.zap

# Never let an ambient override mask the embedded fork stdlib the crash
# reporter relies on.
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR

fail=0
check() { # check "<desc>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  PASS: $1"; else
    echo "  FAIL: $1"; echo "    expected to contain: $3"; fail=1; fi
}

artifact_of() { # artifact_of "<cross-build output>"
  printf '%s' "$1" | grep -oE '/Users/[^ ]*/script[^ .]*' | head -1
}

echo "== 0) NATIVE crash reports (delegates to the Phase-2.b acceptance) =="
if bash script_fixtures/run_phase_2b_acceptance.sh >/tmp/phase_d_native.log 2>&1; then
  echo "  PASS: native SIGSEGV + panic crash reports (see /tmp/phase_d_native.log)"
else
  echo "  FAIL: native Phase-2.b acceptance regressed"; cat /tmp/phase_d_native.log; fail=1
fi

echo
echo "== 1) WASI: recoverable raise STILL renders a crash report under wasmtime =="
if command -v wasmtime >/dev/null 2>&1; then
  build=$("$ZAP" run -Dtarget=wasm32-wasi "$WASI_RAISE" 2>&1)
  art=$(artifact_of "$build")
  check "wasm artifact format" "$(file "$art" 2>/dev/null)" "WebAssembly"
  out=$(wasmtime "$art" 2>&1)
  echo "$out"
  check "wasi stdout (console seam works)" "$out" "phase-d wasi: before raise"
  check "wasi recoverable crash report"    "$out" "** (runtime_error) deliberate wasi raise"

  echo
  echo "== 2) WASI: a hardware fault traps cleanly (degrade, no silent hang) =="
  fbuild=$("$ZAP" run -Dtarget=wasm32-wasi "$WASI_FAULT" 2>&1)
  fart=$(artifact_of "$fbuild")
  fout=$(wasmtime "$fart" 2>&1)
  # A wasm trap is a non-zero exit + a wasm backtrace; that is the acceptable
  # degrade (no signal model on wasm).
  if printf '%s' "$fout" | grep -qiE 'wasm backtrace|trap|unreachable|call stack exhausted'; then
    echo "  PASS: wasi hardware fault trapped cleanly"
  else
    echo "  FAIL: wasi hardware fault did not produce a clean trap"; echo "$fout"; fail=1
  fi
else
  echo "  SKIP: wasmtime not installed"
fi

echo
echo "== 3) WINDOWS: the VEH crash backend links as a PE32+ =="
wbuild=$("$ZAP" run -Dtarget=x86_64-windows-gnu "$WIN_FAULT" 2>&1)
wart=$(artifact_of "$wbuild")
check "windows PE32+ link" "$(file "$wart" 2>/dev/null)" "PE32+ executable"
if command -v wine >/dev/null 2>&1; then
  wout=$(wine "$wart" 2>&1 || true)
  echo "$wout"
  check "windows VEH crash report (arithmetic_error)" "$wout" "** (arithmetic_error)"
else
  echo "  NOTE: wine not available — link + file is the Windows bar (met above)."
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL PHASE D CRASH-PORTABILITY CHECKS PASSED"
else
  echo "PHASE D CRASH-PORTABILITY: FAILURES ABOVE"
  exit 1
fi
