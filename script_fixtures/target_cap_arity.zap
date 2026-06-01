# Phase 2 acceptance — the capability gate broadcasts across ALL arities of a
# gated name (no bypass via a different arity). `@available_on(:terminal)` is
# written before `raw/1`, but `raw/2` is a separately-declared clause of the
# same name. The gate must cover BOTH arities on wasi (gating `raw/1` while
# leaving `raw/2` callable would let a caller reach the same target-unavailable
# feature through `raw/2`). On native both compile + run.
#
# Expected: native prints "arity-ok"; wasm32-wasi FAILS naming `Term.raw/2`
# (the called arity) — proving the broadcast reached the un-annotated arity.

pub struct Term {
  @available_on(:terminal)

  pub fn raw(flag :: Bool) -> String { "raw1" }

  pub fn raw(flag :: Bool, extra :: String) -> String { extra }
}

fn main(args :: [String]) -> u8 {
  IO.puts(Term.raw(true, "arity-ok"))
  0
}
