#!/usr/bin/env bash
# Phase 1 acceptance — comptime `@target` introspection + `%Zap.Env`
# host->target fix. Gates the language-level target-capability model
# foundation (task #354): `@target.os`/`.arch`/`.abi` are comptime atoms
# that FOLD per target, the dead branch is ELIDED before ZIR lowering, and
# the build-manifest env reports the REQUESTED target.
#
# Usage: script_fixtures/run_target_comptime_acceptance.sh
# Requires a freshly built `zig-out/bin/zap`.
#
# NEVER uses `zig build zir-test` (the user runs that). Validates through
# the real ZIR path: `zap run` natively + cross-build, `wasmtime` for wasi,
# `file` for the windows PE link, and a project `zap build` for `%Zap.Env`.
set -u
cd "$(dirname "$0")/.."

# Absolute path: section 5 invokes `$ZAP` from inside the probe project
# directory (a `cd` subshell), where a repo-root-relative `./zig-out/...`
# would not resolve.
ZAP="$(pwd)/zig-out/bin/zap"
BRANCH=script_fixtures/target_comptime_branch.zap
ELISION=script_fixtures/target_dead_branch_elision.zap
ENV_PROBE=script_fixtures/target_env_probe

# Never let an ambient override mask the embedded fork stdlib.
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR ZAP_ERROR_FORMAT ZAP_LEAKS_FATAL

fail=0
check() { # check "<desc>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  PASS: $1"; else
    echo "  FAIL: $1"; echo "    expected to contain: $3"; echo "    got: $2"; fail=1; fi
}
refute() { # refute "<desc>" "<haystack>" "<needle-that-must-be-absent>"
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "  FAIL: $1"; echo "    must NOT contain: $3"; echo "    got: $2"; fail=1
  else echo "  PASS: $1"; fi
}
artifact_of() { printf '%s' "$1" | grep -oE '/[^ ]*/scripts/[0-9a-f]+/script' | head -1; }
# Best-effort: ensure no stale manifest daemon (old binary) serves cached
# results across this run's target switches.
pkill -9 -f "__manifest-incremental-daemon" >/dev/null 2>&1 || true

# Host OS atom (for the native expectations below).
case "$(uname -s)" in
  Darwin) HOST_OS=macos ;;
  Linux)  HOST_OS=linux ;;
  *)      HOST_OS=unknown ;;
esac

echo "== 1) NATIVE: @target.os selects the host branch and folds =="
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true
nout=$("$ZAP" run "$BRANCH" 2>&1)
check "native prints the host-os branch" "$nout" "target-os: ${HOST_OS}"
refute "native does NOT print the wasi branch"    "$nout" "target-os: wasi"
refute "native does NOT print the windows branch" "$nout" "target-os: windows"

echo
echo "== 2) NATIVE: the dead branch is ELIDED (escape-hatch proof) =="
# The non-matching `else` branch calls a :zig. primitive that does not
# exist. It type-checks (bridge calls resolve at ZIR), so the build only
# succeeds if that branch is comptime-folded away before ZIR lowering.
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true
eout=$("$ZAP" run "$ELISION" 2>&1)
check "native elision fixture runs (dead :zig. branch elided)" "$eout" "elision-ok: ${HOST_OS}"
refute "native elision build did NOT hit the bogus primitive" "$eout" "zap_nonexistent_probe_xyz"

echo
echo "== 3) WASM32-WASI: @target folds the wasi branch and RUNS under wasmtime =="
if command -v wasmtime >/dev/null 2>&1; then
  rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true
  wbuild=$("$ZAP" run -Dtarget=wasm32-wasi "$BRANCH" 2>&1)
  wart=$(artifact_of "$wbuild")
  check "wasi artifact is WebAssembly" "$(file "$wart" 2>/dev/null)" "WebAssembly"
  wrun=$(wasmtime --dir=. "$wart" 2>&1)
  check "wasi run prints the wasi branch (requested target, not host)" "$wrun" "target-os: wasi"
  refute "wasi run does NOT print the host branch" "$wrun" "target-os: ${HOST_OS}"

  # Escape hatch under cross-compile: the elision fixture's dead `else`
  # (bogus :zig.) must be elided for the wasi build to link + run.
  rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true
  ewbuild=$("$ZAP" run -Dtarget=wasm32-wasi "$ELISION" 2>&1)
  ewart=$(artifact_of "$ewbuild")
  ewrun=$(wasmtime --dir=. "$ewart" 2>&1)
  check "wasi elision fixture runs (dead branch elided cross-target)" "$ewrun" "elision-ok: wasi"
else
  echo "  SKIP: wasmtime not installed"
fi

echo
echo "== 4) X86_64-WINDOWS-GNU: @target folds the windows branch and links PE32+ =="
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true
winbuild=$("$ZAP" run -Dtarget=x86_64-windows-gnu "$BRANCH" 2>&1)
winart=$(artifact_of "$winbuild")
check "windows artifact links as PE32+" "$(file "$winart" 2>/dev/null)" "PE32+ executable"
# The elision fixture must also link (dead branch elided) for windows.
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true
ewinbuild=$("$ZAP" run -Dtarget=x86_64-windows-gnu "$ELISION" 2>&1)
ewinart=$(artifact_of "$ewinbuild")
check "windows elision fixture links PE32+ (dead branch elided)" "$(file "$ewinart" 2>/dev/null)" "PE32+ executable"

echo
echo "== 5) %Zap.Env: the build-manifest env reports the REQUESTED target =="
# The probe's manifest derives the project NAME from env.os. The on-disk
# artifact name therefore reveals what os the manifest saw.
env_name_for() { # env_name_for "<-Dtarget arg or empty>"
  pkill -9 -f "__manifest-incremental-daemon" >/dev/null 2>&1 || true
  ( cd "$ENV_PROBE" && rm -rf zap-out .zap-cache >/dev/null 2>&1
    "$ZAP" build $1 >/dev/null 2>&1
    find . -name "env-os-*" -type f ! -name "*.zap-symbols" -not -path "*/.zap-cache/*" -not -path "*.dSYM*" 2>/dev/null | head -1 )
}
native_env=$(env_name_for "")
check "native env.os is the host"           "$native_env" "env-os-${HOST_OS}"
wasi_env=$(env_name_for "-Dtarget=wasm32-wasi")
check "wasi env.os is wasi (NOT the host)"  "$wasi_env" "env-os-wasi"
refute "wasi env.os is NOT the host"        "$wasi_env" "env-os-${HOST_OS}"
win_env=$(env_name_for "-Dtarget=x86_64-windows-gnu")
check "windows env.os is windows"           "$win_env" "env-os-windows"
( cd "$ENV_PROBE" && rm -rf zap-out .zap-cache >/dev/null 2>&1 ) || true
pkill -9 -f "__manifest-incremental-daemon" >/dev/null 2>&1 || true

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL @target / %Zap.Env Phase-1 acceptance checks PASSED"
else
  echo "SOME @target / %Zap.Env Phase-1 acceptance checks FAILED"
fi
exit "$fail"
