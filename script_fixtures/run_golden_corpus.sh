#!/usr/bin/env bash
# Phase 4.e — the Zap-native golden diagnostic corpus harness.
#
# This is the PRIMARY regression benchmark for the whole error system: a curated
# set of small Zap programs that each trigger one diagnostic domain (parse,
# type, name, runtime panic, ERT chain, contract, arithmetic/index trap, leak),
# captured as snapshot-stable rendered output in BOTH the human text form and
# the `--error-format=json` schema-v1 form. The deterministic renderer + JSON
# schema (Phase 4.a) make the snapshots stable; this harness re-runs every
# fixture, normalizes the few intrinsically non-deterministic tokens (ASLR
# addresses, compiler-internal `__anon_<n>` ids, the absolute on-disk path of
# the fixture and its private script-cache staging dir), and DIFFS the result
# against the committed golden files. Any drift fails the harness.
#
# Usage:
#   script_fixtures/run_golden_corpus.sh            # verify against goldens
#   script_fixtures/run_golden_corpus.sh --update   # regenerate the goldens
#
# Requires a freshly-built `zig-out/bin/zap`.
#
# ## Cycle-report coverage
#
# A reference cycle is NOT constructible from today's fully-immutable Zap
# surface (the Phase-5 caveat), so a `domain=cycle` report cannot be produced
# from a `.zap` fixture. Its text + JSON shape is golden-locked elsewhere: the
# render tests in `src/memory/cycle_detector.zig` pin the exact bytes, and
# `tools/cycle_detector_drift_test.zig` byte-locks the runtime mirror to them.
# Both run under `zig build test`. The cycle domain is therefore covered by the
# test suite rather than this script.
#
# ## ICE coverage
#
# An internal-compiler-error (ICE) is, by definition, not reliably triggerable
# from valid-looking source without a compiler bug to exploit, so it is not a
# corpus fixture. The ICE diagnostic class + its routing are covered by the
# Phase 4.b unit tests.

set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
CORPUS_DIR=script_fixtures/golden_corpus
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

# Never let an inherited knob perturb a capture; the harness sets the format
# per-case explicitly via the CLI flag.
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR ZAP_ERROR_FORMAT ZAP_LEAKS_FATAL ZAP_BACKTRACE ZAP_CYCLE_CHECK

# Always recompile from source so a stale script-cache binary never masks a
# behavior change.
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true

fail=0
checked=0

# Normalize the intrinsically non-deterministic bits of a capture so the golden
# is byte-stable across machines and runs:
#   * ANSI SGR color escapes (defensive; captures already pass NO_COLOR)
#   * ASLR hex addresses                       0x... -> 0xADDR
#   * compiler-internal anonymous-fn ids       __anon_1234 -> __anon_N
#   * the fixture's own absolute path          -> <FIXTURE>
#   * the private per-run script-cache staging path -> <STAGING>
#   * the trailing run-local cache hash dir under .cache/zap
normalize() { # normalize <fixture_relpath>
  local fixture_abs
  fixture_abs="$(pwd)/$1"
  sed -E \
    -e 's/\x1b\[[0-9;]*m//g' \
    -e 's/0x[0-9a-fA-F]+/0xADDR/g' \
    -e 's/__anon_[0-9]+/__anon_N/g' \
    -e "s#${fixture_abs}#<FIXTURE>#g" \
    -e "s#${1}#<FIXTURE>#g" \
    -e 's#/[^ ]*/\.cache/zap/[^ ]*#<STAGING>#g' \
    -e 's#/[^ ]*/\.zap-cache/[^ ]*#<STAGING>#g'
}

# Run one capture, normalize it, and either write the golden (--update) or diff
# against it.
#   capture <name> <golden_suffix> <fixture_relpath> -- <zap args...>
capture() {
  local name="$1" suffix="$2" fixture="$3"
  shift 3
  [ "$1" = "--" ] && shift
  local golden="${CORPUS_DIR}/${name}.${suffix}"
  local raw normalized
  raw="$(NO_COLOR=1 "$ZAP" "$@" 2>&1)"
  normalized="$(printf '%s\n' "$raw" | normalize "$fixture")"

  if [ "$UPDATE" -eq 1 ]; then
    printf '%s\n' "$normalized" > "$golden"
    echo "  WROTE  ${golden}"
    return
  fi

  checked=$((checked + 1))
  if [ ! -f "$golden" ]; then
    echo "  FAIL   ${name} (${suffix}): golden missing — run with --update"
    fail=1
    return
  fi
  if diff -u "$golden" <(printf '%s\n' "$normalized") > /tmp/golden_diff.$$ 2>&1; then
    echo "  PASS   ${name} (${suffix})"
  else
    echo "  FAIL   ${name} (${suffix}): output drifted from golden"
    sed 's/^/      /' /tmp/golden_diff.$$
    fail=1
  fi
  rm -f /tmp/golden_diff.$$
}

# A compile-error fixture: capture BOTH the text render and the JSON projection.
# `zap run` on a fixture that fails to compile prints the diagnostics and exits
# non-zero; we only snapshot the diagnostic text, so trailing post-diagnostic
# noise (the ZIR-stage "undeclared identifier" follow-on) is dropped by the
# golden capturing only the rendered diagnostic block. To keep that stable we
# capture the full stream and let the golden pin it.
compile_case() { # compile_case <name>
  local name="$1"
  local fixture="${CORPUS_DIR}/${name}.zap"
  capture "$name" txt  "$fixture" -- run "$fixture"
  capture "$name" json "$fixture" -- run -Derror-format=json "$fixture"
}

# A runtime fixture: capture text and the JSON projection (runtime reports
# honor ZAP_ERROR_FORMAT, which the run path sets from -Derror-format). Extra
# `-D` flags (e.g. the memory manager) are passed through.
runtime_case() { # runtime_case <name> [extra -D flags...]
  local name="$1"; shift
  local fixture="${CORPUS_DIR}/${name}.zap"
  capture "$name" txt  "$fixture" -- run "$@" "$fixture"
  capture "$name" json "$fixture" -- run "$@" -Derror-format=json "$fixture"
}

echo "== Zap-native golden diagnostic corpus =="
echo

echo "-- compile-time diagnostics (text + JSON schema v1) --"
compile_case parse_error
compile_case type_error_two_sided
compile_case undefined_name

echo
echo "-- runtime diagnostics (text + JSON) --"
runtime_case runtime_raise
runtime_case assertion_error
runtime_case arithmetic_overflow
runtime_case index_error
runtime_case leak_report -Dmemory=Memory.Tracking

echo
if [ "$UPDATE" -eq 1 ]; then
  echo "GOLDEN CORPUS: goldens regenerated. Review the diff before committing."
  exit 0
fi
if [ "$fail" -eq 0 ]; then
  echo "GOLDEN CORPUS: ALL ${checked} SNAPSHOTS MATCH"
else
  echo "GOLDEN CORPUS: DRIFT DETECTED (see diffs above)"
fi
exit "$fail"
