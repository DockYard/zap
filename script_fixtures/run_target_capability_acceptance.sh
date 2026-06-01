#!/usr/bin/env bash
# Phase 2 acceptance — language-level target-capability GATING (`@available_on`
# + the `target_capability` diagnostic + the comptime-`@target` escape hatch).
# Task #355. Mirrors run_target_comptime_acceptance.sh (Phase 1) and
# run_phase_d_crash_portability.sh.
#
# The principle (docs/target-capability-model-plan.md): a feature that does not
# make sense for a target fails at COMPILE TIME, naming the missing CAPABILITY
# (not the OS), unless guarded by a comptime `@target` branch (the escape
# hatch). Native has every capability → every gate satisfied → ZERO behavior
# change (the regression anchor).
#
# Validates through the real ZIR path: `zap run` natively + cross-build, an
# expected-COMPILE-FAILURE harness for the gated cases, and `wasmtime` for the
# escape-hatch cases. NEVER uses `zig build zir-test` (the user runs that).
#
# Usage: script_fixtures/run_target_capability_acceptance.sh
# Requires a freshly built `zig-out/bin/zap` (re-embeds lib/io.zap's gate).
set -u
cd "$(dirname "$0")/.."

ZAP="$(pwd)/zig-out/bin/zap"
F=script_fixtures

unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR ZAP_ERROR_FORMAT ZAP_LEAKS_FATAL
pkill -9 -f "__manifest-incremental-daemon" >/dev/null 2>&1 || true

fail=0
clearcache() { rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true; }
check()  { if printf '%s' "$2" | grep -qF -- "$3"; then echo "  PASS: $1"; else
             echo "  FAIL: $1"; echo "    expected to contain: $3"; echo "    got: $2"; fail=1; fi; }
refute() { if printf '%s' "$2" | grep -qF -- "$3"; then
             echo "  FAIL: $1"; echo "    must NOT contain: $3"; echo "    got: $2"; fail=1
           else echo "  PASS: $1"; fi; }
artifact_of() { printf '%s' "$1" | grep -oE '/[^ ]*/scripts/[0-9a-f]+/script' | head -1; }

# A build that MUST fail to compile (non-zero exit) with a needle. Captures
# stdout+stderr; a zero exit (binary produced) is itself a failure.
expect_compile_fail() { # expect_compile_fail "<desc>" "<-Dtarget or empty>" "<file>" "<needle>"
  clearcache
  local out rc
  out=$("$ZAP" run $2 "$3" </dev/null 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  FAIL: $1 (expected a COMPILE ERROR, but the build succeeded)"; echo "    got: $out"; fail=1; return
  fi
  check "$1" "$out" "$4"
}

case "$(uname -s)" in
  Darwin) HOST_OS=macos ;;
  Linux)  HOST_OS=linux ;;
  *)      HOST_OS=unknown ;;
esac
HAVE_WASMTIME=0; command -v wasmtime >/dev/null 2>&1 && HAVE_WASMTIME=1

echo "== 1) GATED-OUT -> clean COMPILE ERROR naming the capability (wasm32-wasi) =="
# The exact `target_capability` diagnostic: names the API, the target, the
# `:terminal` capability, and the `@target` guard hint. NOT "undefined".
out=$("$ZAP" run -Dtarget=wasm32-wasi "$F/target_cap_gated_direct.zap" </dev/null 2>&1)
[ $? -ne 0 ] || { echo "  FAIL: gated direct ref compiled on wasi"; fail=1; }
check  "names the gated API + target"        "$out" "\`IO.get_char/0\` is unavailable on \`wasm32-wasi\`"
check  "names the missing :terminal cap"     "$out" "this target lacks the \`:terminal\` capability"
check  "gives the @target guard hint"        "$out" "guard the call with \`if @target.os != :wasi"
refute "is NOT the undefined/not-found path" "$out" "I cannot find"

echo
echo "== 2) ESCAPE HATCH (if-guard): SAME ref compiles for wasi + runs under wasmtime =="
clearcache
ebuild=$("$ZAP" run -Dtarget=wasm32-wasi "$F/target_cap_escape_hatch_if.zap" </dev/null 2>&1)
refute "if-guarded ref does NOT trip the gate" "$ebuild" "is unavailable on"
eart=$(artifact_of "$ebuild")
check  "if-guard wasi artifact is WebAssembly" "$(file "$eart" 2>/dev/null)" "WebAssembly"
if [ "$HAVE_WASMTIME" -eq 1 ] && [ -n "$eart" ]; then
  erun=$(wasmtime --dir=. "$eart" 2>&1)
  check "if-guard wasi runs the live else branch" "$erun" "escape-hatch-if-ok: wasi"
else echo "  SKIP: wasmtime not installed (link bar met)"; fi

echo
echo "== 3) ESCAPE HATCH (case-guard): direct \`case @target.os\` form also compiles =="
clearcache
cbuild=$("$ZAP" run -Dtarget=wasm32-wasi "$F/target_cap_escape_hatch_case.zap" </dev/null 2>&1)
refute "case-guarded ref does NOT trip the gate" "$cbuild" "is unavailable on"
cart=$(artifact_of "$cbuild")
if [ "$HAVE_WASMTIME" -eq 1 ] && [ -n "$cart" ]; then
  crun=$(wasmtime --dir=. "$cart" 2>&1)
  check "case-guard wasi runs the live clause" "$crun" "escape-hatch-case-ok: wasi"
else echo "  SKIP: wasmtime not installed"; fi

echo
echo "== 4) AVAILABLE PATH + NATIVE ZERO-IMPACT: the gated API works natively =="
# Native has :terminal, so the gated `IO.get_char` compiles + runs exactly as
# before (we feed a byte on stdin; the program echoes it, proving the API ran).
clearcache
nout=$(printf 'Z' | "$ZAP" run "$F/target_cap_gated_direct.zap" 2>&1); nrc=$?
[ "$nrc" -eq 0 ] && echo "  PASS: gated API compiles + runs natively (exit 0)" || { echo "  FAIL: native exit $nrc"; echo "$nout"; fail=1; }
# The if- and case-guarded fixtures also compile + run natively (the LIVE
# branch is the real get_char path).
clearcache
nif=$(printf 'Z' | "$ZAP" run "$F/target_cap_escape_hatch_if.zap" 2>&1); [ $? -eq 0 ] && echo "  PASS: if-guard fixture runs natively" || { echo "  FAIL native if-guard"; echo "$nif"; fail=1; }

echo
echo "== 5) GENUINE-UNDEFINED is UNAFFECTED (still 'undefined', never the cap path) =="
clearcache
uout=$("$ZAP" run -Dtarget=wasm32-wasi "$F/target_cap_genuine_undefined.zap" </dev/null 2>&1)
[ $? -ne 0 ] || { echo "  FAIL: typo compiled"; fail=1; }
refute "typo does NOT get the capability diagnostic" "$uout" "target_capability"
refute "typo does NOT say 'unavailable on'"          "$uout" "is unavailable on"
refute "typo does NOT name a :capability"            "$uout" "capability; guard the call"

echo
echo "== 6) MULTIPLE caps: reports the FIRST missing (:terminal), :filesystem satisfied =="
expect_compile_fail "multi-cap names first-missing :terminal on wasi" "-Dtarget=wasm32-wasi" "$F/target_cap_multi.zap" "lacks the \`:terminal\` capability"
clearcache
m_native=$("$ZAP" run "$F/target_cap_multi.zap" </dev/null 2>&1); [ $? -eq 0 ] && check "multi-cap runs natively" "$m_native" "combo-ok" || { echo "  FAIL multi native"; echo "$m_native"; fail=1; }

echo
echo "== 7) ARITY BROADCAST: a gate on raw/1 also gates the called raw/2 on wasi =="
expect_compile_fail "raw/2 gated via broadcast" "-Dtarget=wasm32-wasi" "$F/target_cap_arity.zap" "\`Term.raw/2\` is unavailable"
clearcache
a_native=$("$ZAP" run "$F/target_cap_arity.zap" </dev/null 2>&1); [ $? -eq 0 ] && check "both arities run natively" "$a_native" "arity-ok" || { echo "  FAIL arity native"; echo "$a_native"; fail=1; }

echo
echo "== 8) STRUCT-level gate covers an un-annotated member on wasi =="
expect_compile_fail "struct gate covers Tty.read_key/0" "-Dtarget=wasm32-wasi" "$F/target_cap_struct_level.zap" "\`Tty.read_key/0\` is unavailable"
clearcache
s_native=$("$ZAP" run "$F/target_cap_struct_level.zap" </dev/null 2>&1); [ $? -eq 0 ] && check "struct-gated member runs natively" "$s_native" "tty-ok" || { echo "  FAIL struct native"; echo "$s_native"; fail=1; }

echo
echo "== 9) UNKNOWN capability atom -> precise error on EVERY target =="
expect_compile_fail "unknown cap (native)" ""                     "$F/target_cap_unknown.zap" "unknown capability \`:telepathy\`"
expect_compile_fail "unknown cap (wasi)"   "-Dtarget=wasm32-wasi" "$F/target_cap_unknown.zap" "unknown capability \`:telepathy\`"

echo
echo "== 10) @available_on on a MACRO is rejected (category error) on EVERY target =="
expect_compile_fail "macro gate rejected (native)" ""                     "$F/target_cap_macro_rejected.zap" "cannot gate a macro"
expect_compile_fail "macro gate rejected (wasi)"   "-Dtarget=wasm32-wasi" "$F/target_cap_macro_rejected.zap" "cannot gate a macro"

echo
echo "== 11) x86_64-windows-gnu: :terminal gated-out (no termios) links nothing; guard compiles =="
# Windows has :signals(VEH)/:filesystem/:processes/:network but NOT :terminal,
# so the unguarded gated ref must fail to compile there too — proving the gate
# is CAPABILITY-keyed (windows has a process model yet still lacks :terminal),
# not OS-keyed.
expect_compile_fail "windows lacks :terminal too (capability-keyed)" "-Dtarget=x86_64-windows-gnu" "$F/target_cap_gated_direct.zap" "lacks the \`:terminal\` capability"
# The if-guard (os != :wasi is TRUE on windows) keeps the real get_char path,
# which DOES need :terminal — so on windows the guarded build must ALSO fail
# (the guard only elides on wasi). This proves the guard is comptime-correct,
# not a blanket suppressor.
expect_compile_fail "windows if-guard still needs :terminal (guard is wasi-specific)" "-Dtarget=x86_64-windows-gnu" "$F/target_cap_escape_hatch_if.zap" "lacks the \`:terminal\` capability"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL target-capability Phase-2 acceptance checks PASSED"
else
  echo "SOME target-capability Phase-2 acceptance checks FAILED"
fi
exit "$fail"
