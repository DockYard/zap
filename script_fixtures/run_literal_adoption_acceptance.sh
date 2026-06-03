#!/usr/bin/env bash
# task #361 acceptance harness: an untyped numeric literal adopts the type its
# context expects, range-checked, in EVERY position. Exercises function-arg,
# nested-call arg, float arg, list/map element, and return/if/case positions
# end-to-end via `zap run`, plus the negative anchors (overflow, typed binding,
# negative-into-unsigned). Exits non-zero on any mismatch.
#
# Usage: script_fixtures/run_literal_adoption_acceptance.sh
#
# Requires `zig-out/bin/zap` to be freshly built.
set -u
cd "$(dirname "$0")/.."

ZAP=./zig-out/bin/zap
export ZAP_LIB_DIR="$(pwd)/lib"

fail=0
check() {
  # check "<description>" "<haystack>" "<needle>"
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1"
    echo "    expected to contain: $3"
    fail=1
  fi
}

run_fixture() {
  # run_fixture <fixture.zap>  -> sets `out` and `code`
  out=$("$ZAP" run "script_fixtures/$1" 2>&1)
  code=$?
}

echo "== 1) function-arg: untyped int literal adopts u8 =="
run_fixture literal_adopt_arg_int.zap
echo "$out"
check "exit 0"        "$code" "0"
check "prints 5"      "$out"  "5"

echo
echo "== 2) function-arg: untyped float literal adopts f32 =="
run_fixture literal_adopt_arg_float.zap
echo "$out"
check "exit 0"        "$code" "0"
check "prints 3.5"    "$out"  "3.5"

echo
echo "== 3) nested-call arg: literal adopts u8 through nesting =="
run_fixture literal_adopt_arg_nested.zap
echo "$out"
check "exit 0"        "$code" "0"
check "prints 5"      "$out"  "5"

echo
echo "== 4) list element: literals adopt u8 from [u8] parameter =="
run_fixture literal_adopt_list_element.zap
echo "$out"
check "exit 0"        "$code" "0"
check "length 3"      "$out"  "3"

echo
echo "== 5) map value: literal adopts u8 from Map(Atom,u8) parameter =="
run_fixture literal_adopt_map_value.zap
echo "$out"
check "exit 0"        "$code" "0"
check "size 1"        "$out"  "1"

echo
echo "== 5b) tuple element: literals adopt position-wise from {u8,u8} parameter =="
run_fixture literal_adopt_tuple_element.zap
echo "$out"
check "exit 0"        "$code" "0"
check "prints ok"     "$out"  "ok"

echo
echo "== 5c) map KEY: literal adopts u8 from Map(u8,Atom) key position =="
run_fixture literal_adopt_map_key.zap
echo "$out"
check "exit 0"        "$code" "0"
check "size 1"        "$out"  "1"

echo
echo "== 5d) nested list: literals adopt through [[u8]] =="
run_fixture literal_adopt_nested_list.zap
echo "$out"
check "exit 0"        "$code" "0"
check "length 2"      "$out"  "2"

echo
echo "== 6) return / if / case: literals adopt declared non-i64 return =="
run_fixture literal_adopt_return_ifcase.zap
echo "$out"
check "exit 0"        "$code" "0"
check "three 5s"      "$out"  $'5\n5\n5'

echo
echo "== 6b) if-expr in ARGUMENT position: both arms adopt u8 =="
run_fixture literal_adopt_if_arg.zap
echo "$out"
check "exit 0"        "$code" "0"
check "prints 5"      "$out"  "5"

echo
echo "== 6c) case in ARGUMENT position: every arm adopts u8 =="
run_fixture literal_adopt_case_arg.zap
echo "$out"
check "exit 0"        "$code" "0"
check "prints 200"    "$out"  "200"

echo
echo "== 6d) negated literal adopts a SIGNED type (-5, -128 into i8) =="
run_fixture literal_adopt_negative_signed.zap
echo "$out"
check "exit 0"        "$code" "0"
check "length 3"      "$out"  "3"

echo
echo "== 7) NEGATIVE: arg literal that does not fit u8 is an overflow error =="
run_fixture literal_adopt_arg_overflow.zap
echo "$out"
check "non-zero exit"        "$code" "1"
check "names the value 9999" "$out"  "9999"
check "names the type u8"    "$out"  "u8"

echo
echo "== 8) NEGATIVE: a typed i64 binding into a u8 param still errors =="
run_fixture literal_adopt_typed_binding_rejected.zap
echo "$out"
check "non-zero exit"            "$code" "1"
check "argument type mismatch"   "$out"  "argument 1 expects \`u8\`, got \`i64\`"

echo
echo "== 9) NEGATIVE: a negative literal cannot adopt an unsigned param =="
run_fixture literal_adopt_negative_unsigned.zap
echo "$out"
check "non-zero exit"        "$code" "1"
check "names the value -5"   "$out"  "-5"
check "names the type u8"    "$out"  "u8"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL LITERAL-ADOPTION ACCEPTANCE CHECKS PASSED"
else
  echo "LITERAL-ADOPTION ACCEPTANCE: FAILURES ABOVE"
fi
exit "$fail"
