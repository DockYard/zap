# Phase 0: the same-TypeId invariant observed at the value level. A value
# returned with the alias type `Thunk` (= `fn() -> i64`) flows directly
# into a parameter declared with the inline `fn() -> i64` type and is
# invoked — the two spellings name the EXACT same function TypeId, so an
# aliased-type value and an inline-type slot interoperate with no coercion.
#
# (A higher-order parameter typed `fn(i64) -> i64` taking a *bare* named-
# function reference is a separate, pre-existing #201/Gap-E concern and is
# unrelated to alias resolution — it fails identically whether the param
# is written `Adder` or `fn(i64) -> i64`. The unit test
# "function-type alias resolves to the same TypeId as the inline form"
# asserts the TypeId equality directly.)
#
# Expected output:
#   7

type Thunk = fn() -> i64

pub struct Factory {
  # Returns a closure typed by the alias `Thunk`.
  pub fn make_seven() -> Thunk {
    fn() -> i64 { 7 }
  }

  # Accepts the closure through the INLINE function type and calls it.
  pub fn run(f :: fn() -> i64) -> i64 {
    f()
  }
}

fn main(_args :: [String]) -> u8 {
  # The `Thunk`-typed result of `make_seven` is accepted by `run`'s
  # `fn() -> i64` parameter without conversion — same TypeId.
  IO.puts(Integer.to_string(Factory.run(Factory.make_seven())))
  0
}
