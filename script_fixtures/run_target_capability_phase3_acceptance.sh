#!/usr/bin/env bash
# Phase 3 acceptance — the target-sensitive stdlib SWEEP (task #359).
# Mirrors run_target_capability_acceptance.sh (Phase 2). Phase 2 proved the
# `@available_on` gating MECHANISM on one API (`IO.get_char/0`); Phase 3 proves
# the SWEEP covers every genuinely target-divergent stdlib API: the IO raw-mode
# terminal-input cluster (`IO.try_get_char/0`, `IO.mode/1`, `IO.mode/2`), all
# gated `:terminal` in lib/io.zap.
#
# The principle (docs/target-capability-model-plan.md): a feature unavailable
# on a target fails at COMPILE TIME naming the missing CAPABILITY (not the OS),
# unless guarded by a comptime `@target` branch (the escape hatch). Native has
# every capability → every gate satisfied → ZERO behavior change.
#
# CRITICAL over-gating guard: a program using only wasi-AVAILABLE stdlib (File
# I/O — wasi has :filesystem via preopens — plus String/List/IO.puts) MUST
# still cross-build + run on wasi. If it fails, an API was wrongly gated.
#
# Validates through the real ZIR path: `zap run` natively + cross-build, an
# expected-COMPILE-FAILURE harness for the gated cases, and `wasmtime` for the
# capable + escape-hatch cases. NEVER uses `zig build zir-test`.
#
# Usage: script_fixtures/run_target_capability_phase3_acceptance.sh
# Requires a freshly built `zig-out/bin/zap` (re-embeds lib/io.zap's gates).
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

# A build that MUST fail to compile (non-zero exit) with a needle.
expect_compile_fail() { # expect_compile_fail "<desc>" "<-Dtarget or empty>" "<file>" "<needle>"
  clearcache
  local out rc
  out=$("$ZAP" run $2 "$3" </dev/null 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  FAIL: $1 (expected a COMPILE ERROR, but the build succeeded)"; echo "    got: $out"; fail=1; return
  fi
  check "$1" "$out" "$4"
}

HAVE_WASMTIME=0; command -v wasmtime >/dev/null 2>&1 && HAVE_WASMTIME=1

echo "== 1) SWEPT API IO.try_get_char/0 -> gated :terminal on wasi (clean compile error) =="
expect_compile_fail "try_get_char names API+target on wasi" "-Dtarget=wasm32-wasi" "$F/target_cap_p3_try_get_char.zap" "\`IO.try_get_char/0\` is unavailable on \`wasm32-wasi\`"
out=$("$ZAP" run -Dtarget=wasm32-wasi "$F/target_cap_p3_try_get_char.zap" </dev/null 2>&1)
check  "try_get_char names :terminal cap" "$out" "this target lacks the \`:terminal\` capability"
refute "try_get_char is NOT the not-found path" "$out" "I cannot find"

echo
echo "== 2) SWEPT API IO.mode/1 -> gated :terminal on wasi (direct attribute) =="
expect_compile_fail "mode/1 names API+target on wasi" "-Dtarget=wasm32-wasi" "$F/target_cap_p3_mode.zap" "\`IO.mode/1\` is unavailable on \`wasm32-wasi\`"
out=$("$ZAP" run -Dtarget=wasm32-wasi "$F/target_cap_p3_mode.zap" </dev/null 2>&1)
check  "mode/1 names :terminal cap" "$out" "this target lacks the \`:terminal\` capability"

echo
echo "== 3) ARITY BROADCAST: IO.mode/2 gated on wasi though only mode/1 is annotated =="
# mode/2 carries NO @available_on itself; the collector broadcasts the gate
# from mode/1 across all arities — a caller cannot bypass via the other arity.
expect_compile_fail "mode/2 gated via broadcast on wasi" "-Dtarget=wasm32-wasi" "$F/target_cap_p3_mode_callback.zap" "\`IO.mode/2\` is unavailable on \`wasm32-wasi\`"
out=$("$ZAP" run -Dtarget=wasm32-wasi "$F/target_cap_p3_mode_callback.zap" </dev/null 2>&1)
check  "mode/2 names :terminal cap" "$out" "this target lacks the \`:terminal\` capability"

echo
echo "== 4) ESCAPE HATCH covers the SWEEP: guarded try_get_char + mode/1 + mode/2 compile for wasi =="
clearcache
ebuild=$("$ZAP" run -Dtarget=wasm32-wasi "$F/target_cap_p3_escape_hatch.zap" </dev/null 2>&1)
refute "swept escape-hatch refs do NOT trip the gate" "$ebuild" "is unavailable on"
eart=$(artifact_of "$ebuild")
check  "escape-hatch wasi artifact is WebAssembly" "$(file "$eart" 2>/dev/null)" "WebAssembly"
if [ "$HAVE_WASMTIME" -eq 1 ] && [ -n "$eart" ]; then
  erun=$(wasmtime --dir=. "$eart" 2>&1)
  check "escape-hatch wasi runs the live else branch" "$erun" "p3-escape-hatch-ok: wasi"
else echo "  SKIP: wasmtime not installed"; fi

echo
echo "== 5) OVER-GATING GUARD: a wasi-CAPABLE program (File/String/List/IO.puts) cross-builds + runs =="
# File I/O is :filesystem (present on wasi via preopens) — NOT gated. If this
# fails to compile/run on wasi, an API was WRONGLY gated (the over-gating bug).
clearcache
cbuild=$("$ZAP" run -Dtarget=wasm32-wasi "$F/target_cap_p3_capable_wasi.zap" </dev/null 2>&1)
refute "capable-wasi program is NOT over-gated" "$cbuild" "is unavailable on"
cart=$(artifact_of "$cbuild")
check  "capable-wasi artifact is WebAssembly" "$(file "$cart" 2>/dev/null)" "WebAssembly"
if [ "$HAVE_WASMTIME" -eq 1 ] && [ -n "$cart" ]; then
  crun=$(wasmtime --dir=. "$cart" 2>&1)
  check "capable-wasi runs File/String/List/IO.puts under wasmtime" "$crun" "p3-capable-wasi-ok"
else echo "  SKIP: wasmtime not installed"; fi

echo
echo "== 6) NATIVE ZERO-IMPACT: every swept API compiles + runs natively (all caps satisfied) =="
for spec in \
  "try_get_char:try-get-char-ok" \
  "mode:mode-ok" \
  "mode_callback:mode-callback-ok" \
  "escape_hatch:p3-escape-hatch-native" \
  "capable_wasi:p3-capable-wasi-ok"; do
  f="${spec%%:*}"; needle="${spec##*:}"
  clearcache
  out=$(printf 'Z' | "$ZAP" run "$F/target_cap_p3_${f}.zap" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then check "native $f (exit 0 + output)" "$out" "$needle"
  else echo "  FAIL: native $f exited $rc"; echo "$out" | tail -3; fail=1; fi
done

echo
echo "== 7) WINDOWS lacks :terminal too (CAPABILITY-keyed, not OS-keyed) =="
# Windows has :signals(VEH)/:filesystem/:processes/:network but NOT :terminal
# (caps.supports_termios=false). The swept gate must fire on windows too —
# proving it keys off the capability, not `os == :wasi`.
expect_compile_fail "windows try_get_char lacks :terminal" "-Dtarget=x86_64-windows-gnu" "$F/target_cap_p3_try_get_char.zap" "lacks the \`:terminal\` capability"
expect_compile_fail "windows mode/1 lacks :terminal"       "-Dtarget=x86_64-windows-gnu" "$F/target_cap_p3_mode.zap"         "lacks the \`:terminal\` capability"
expect_compile_fail "windows mode/2 lacks :terminal"       "-Dtarget=x86_64-windows-gnu" "$F/target_cap_p3_mode_callback.zap" "lacks the \`:terminal\` capability"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL target-capability Phase-3 acceptance checks PASSED"
else
  echo "SOME target-capability Phase-3 acceptance checks FAILED"
fi
exit "$fail"
