#!/usr/bin/env bash
# Phase 4.f acceptance — the unrecoverable abort surfaces (runtime raise +
# safety-trap panics) MUST serialize to the schema-v1 JSON record under
# `--error-format=json`, exactly as the compile-error and leak surfaces already
# do. Acceptance criterion #1 ("one renderer + ONE JSON schema across all five
# surfaces") requires runtime panics + ERT traces to round-trip through JSON,
# not just text.
#
# This is a behavioral assertion (not a snapshot): for each abort fixture run
# with `-Derror-format=json`, the diagnostic line MUST begin with the canonical
# schema-v1 record envelope `{"domain":"..."`. Before the Phase-4.f fix the
# abort printer ignored the format knob and always emitted the `** (kind)` text
# crash report, so every case below FAILS pre-fix and PASSES post-fix.
#
# Usage:  script_fixtures/run_phase_4f_panic_json.sh
# Requires a freshly-built `zig-out/bin/zap`.

set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
CORPUS_DIR=script_fixtures/golden_corpus
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR ZAP_ERROR_FORMAT ZAP_LEAKS_FATAL ZAP_BACKTRACE
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true

fail=0
checked=0

# assert_json_domain <fixture> <expected_domain> [extra -D flags...]
# Runs the fixture with JSON format, finds the first diagnostic line (skipping
# script-cache + benign program output), and asserts it is a schema-v1 record
# of the expected domain.
assert_json_domain() {
  local fixture="$1" expected_domain="$2"; shift 2
  checked=$((checked + 1))
  local out diagline
  out="$(NO_COLOR=1 "$ZAP" run "$@" -Derror-format=json "$fixture" 2>&1)"
  # The abort diagnostic is the first line that is neither a cache notice nor
  # the program's own stdout ("done", blank). It must be the JSON record.
  diagline="$(printf '%s\n' "$out" | grep -vE '^\[script-cache|^$|^done$' | head -1)"
  if printf '%s' "$diagline" | grep -qE "^\{\"domain\":\"${expected_domain}\""; then
    echo "  PASS   $(basename "$fixture") -> domain=${expected_domain}"
  else
    echo "  FAIL   $(basename "$fixture"): expected schema-v1 JSON domain=${expected_domain}, got:"
    echo "         ${diagline:0:120}"
    fail=1
  fi
}

echo "== Phase 4.f abort-surface JSON acceptance =="
echo
# A user `raise` that reaches the top unrescued is domain=runtime; the ERT
# chain rides inside machine_data.error_return_trace.
assert_json_domain "${CORPUS_DIR}/runtime_raise.zap"       runtime
# In a SAFE build the Zap stdlib's own contract / arithmetic / index
# operations deliberately `raise` the corresponding typed stdlib error
# (AssertionError / ArithmeticError / IndexError) via
# `Kernel.raise_with_kind` — so they are `rescue`-able recoverable raises, and
# reaching the top unrescued is domain=runtime (NOT domain=panic). The
# `ZapPanic` / domain=panic path is reserved for genuinely-unrecoverable
# Zig-level safety violations (raw `unreachable`, null-unwrap, untyped overflow
# in compiler-emitted code, hardware-fault signals).
assert_json_domain "${CORPUS_DIR}/assertion_error.zap"     runtime
assert_json_domain "${CORPUS_DIR}/arithmetic_overflow.zap" runtime
assert_json_domain "${CORPUS_DIR}/index_error.zap"         runtime

echo
if [ "$fail" -eq 0 ]; then
  echo "PHASE 4.f PANIC-JSON: ALL ${checked} ABORT SURFACES EMIT SCHEMA-V1 JSON"
else
  echo "PHASE 4.f PANIC-JSON: FAILURES (see above)"
fi
exit "$fail"
