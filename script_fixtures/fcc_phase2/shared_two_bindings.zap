# FCC Phase 2 — Shared boxed closure via two bindings. `add5` is bound,
# then aliased into a second binding `also`; BOTH are invoked. Each binding
# is an independent owner of the boxed environment, so under a no-refcount
# manager the share CLONES the inner (each owner drops its own exactly once)
# and under a refcount manager the share bumps the inner's refcount.
#
# Before the fix this double-freed under `-Dmemory=Memory.Tracking`
# (`invalid free`): two owners of the same heap env, both eagerly freed.
#
# Expected under BOTH managers: prints `15` then `15`, ZERO leaks, exit 0.

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(_args :: [String]) -> u8 {
  add5 = Maker.make_adder(5)
  also = add5
  IO.puts(Integer.to_string(add5(10)))
  IO.puts(Integer.to_string(also(10)))
  0
}
