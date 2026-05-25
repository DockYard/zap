#!/usr/bin/env bash
# FCC Phase 2 acceptance harness — a boxed `Callable` closure's captured
# environment is heap-allocated and released EXACTLY ONCE at scope exit under
# BOTH `Memory.ARC` and `-Dmemory=Memory.Tracking`, deep-dropping captured ARC
# values, with no leak and no double-free. Exits non-zero on any mismatch.
#
# Usage: script_fixtures/run_fcc_phase2_acceptance.sh
# Requires `zig-out/bin/zap` to be freshly built.
set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
unset ZAP_ZIG_LIB_DIR ZIG_LIB_DIR ZAP_ERROR_FORMAT ZAP_LEAKS_FATAL
rm -rf "${HOME}/.cache/zap/scripts" 2>/dev/null || true

fail=0
DIR=script_fixtures/fcc_phase2

# run_clean "<fixture>" "<expected-substr-1>" ["<expected-substr-2>" ...]
# Asserts, under BOTH managers, that the fixture prints the expected lines,
# leaves ZERO leaks, and triggers no double-free / use-after-free canary.
run_clean() {
  local fixture="$1"; shift
  for mgr in "" "-Dmemory=Memory.Tracking"; do
    local label="${mgr:-Memory.ARC}"
    local out
    out=$("$ZAP" run $mgr "$DIR/$fixture" 2>&1)
    for needle in "$@"; do
      if printf '%s' "$out" | grep -qF -- "$needle"; then
        echo "  PASS: $fixture [$label] prints '$needle'"
      else
        echo "  FAIL: $fixture [$label] missing '$needle'"; fail=1
      fi
    done
    for bad in "memory leak:" "INVALID FREE" "invalid free" "USE-AFTER-FREE" "double fault" "panic: reached"; do
      if printf '%s' "$out" | grep -qF -- "$bad"; then
        echo "  FAIL: $fixture [$label] hit '$bad'"; fail=1
      fi
    done
  done
}

echo "== FCC Phase 2: boxed closure environments released exactly once =="
run_clean capture_i64_dropped.zap "15"
run_clean capture_string_deep_drop.zap "hello world"
run_clean heterogeneous_list_dropped.zap "11" "15"

echo "== FCC Phase 2: boxed elements in a dropped/partially-consumed List =="
# A ProtocolBox element stored in a List must be deep-released by the list-drop
# under BOTH managers, balanced with clone-on-share extraction: un-extracted
# elements are freed by the list-drop, extracted ones by their owner's drop.
run_clean list_partial_consume_dropped.zap "11"
run_clean list_no_extract_dropped.zap "3"
run_clean list_extract_some_iterate_rest.zap "11" "12"
run_clean list_string_capture_dropped.zap "hi alice"
run_clean nested_list_of_boxes_dropped.zap "11"

echo "== FCC Phase 2: SHARED boxed closures balanced under both managers =="
# A shared boxed closure (aliased to a second/third binding, or kept while
# also held in a container) must be balanced under BOTH managers: under a
# no-refcount manager each owner gets an independent CLONE of the env (no
# double-free, no leak); under a refcount manager the share bumps the env's
# refcount.
run_clean shared_two_bindings.zap "15"
run_clean shared_three_bindings.zap "15"
run_clean shared_string_closure.zap "hi there"
run_clean shared_struct_capture.zap "16"
run_clean shared_list_capture.zap "31"
run_clean shared_closure_retained.zap "15"
run_clean shared_list_and_binding.zap "15"
run_clean returned_and_kept.zap "7"

echo
if [ "$fail" -eq 0 ]; then
  echo "FCC PHASE 2 ACCEPTANCE: ALL PASS"
else
  echo "FCC PHASE 2 ACCEPTANCE: FAILURES ABOVE"
fi
exit "$fail"
