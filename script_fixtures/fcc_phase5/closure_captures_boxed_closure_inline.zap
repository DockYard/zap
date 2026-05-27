# FCC Phase 5 — the inline-bound-then-invoked form of capturing a boxed
# closure (the documented Phase-5 residual edge #2).
#
# `g` is a BOXED capturing `Callable` (a factory-returned local). A NEW closure
# `once = fn(x){ g(x) }` CAPTURES `g` and is bound to a local AND invoked INLINE
# in the SAME function (not returned from a factory). `once` is non-escaping, so
# it is DEVIRTUALIZED — its captured-environment struct (`__ClosureEnv_N`) holds
# the boxed `g` as a `ProtocolBox` field. That compound capture-field type
# previously raised `EmitFailed` (the env type could only carry primitives);
# the streaming named-struct-decl emission resolves it.
#
# A nested form (`twice = fn(x){ once(once(x)) }` is NOT used here — capturing a
# DEVIRTUALIZED closure is a separate representation; this fixture pins the
# documented boxed-closure-capture residual). Expected (both managers):
#   6    (once(1) = g(1) = 1 + 5)
# exit 0, leak-free — the boxed `g`'s heap env is deep-released exactly once.

pub struct N {
  pub fn mk(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(_args :: [String]) -> u8 {
  g = N.mk(5)
  once = fn(x :: i64) -> i64 { g(x) }
  IO.puts(Integer.to_string(once(1)))
  0
}
