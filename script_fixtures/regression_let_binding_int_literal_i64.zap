# Regression: a bare integer literal in a NON-TAIL let-binding inside a
# narrow-return function defaults to i64 — it must NOT inherit the
# enclosing function's return type.
#
# `main` returns `u8`. The binding `big = 2000000000` is a non-tail
# let-binding whose RHS is a bare integer literal with no annotation and
# no other type-expectation site, so it defaults to i64 (per the language
# spec: "Integer literals default to i64"). Before the fix the function's
# `u8` return type leaked into the binding RHS and codegen rejected it
# with `type 'u8' cannot represent integer value '2000000000'`.
#
# Companion to the #129 call-argument fix (which covered `D.f(2000000)`):
# this pins the let-binding case that #129 did not cover.
#
# Expected: stdout == "2000000001\n", exit code 0.

pub struct Plus {
  pub fn one(value :: i64) -> i64 {
    value + 1
  }
}

fn main(_args :: [String]) -> u8 {
  big = 2000000000
  result = Plus.one(big)
  IO.puts(Integer.to_string(result))
  0
}
