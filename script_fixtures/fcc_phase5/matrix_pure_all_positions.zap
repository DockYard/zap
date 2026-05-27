# FCC Phase 5 — Item 7 (final matrix). PURE capturing closures across the
# field / list / map / return positions, plus a NON-capturing direct combinator
# callback — all in one program. Gates the {pure} × {capturing, non-capturing}
# × {field, list, map, return, param} cells under BOTH managers, and confirms
# pure closures gain NO spurious `raises` (no rescue needed, clean run). The
# combinator (DIRECT/devirtualized) is placed FIRST so the boxed locals' drops
# are not separated from `ret` by it (see the documented ARC-ordering edge).
#
# Expected (both managers): prints
#   20  (Enum.map [10] doubled, element 0 = 20 — DIRECT combinator)
#   11  (field-stored pure closure: 10 + 1)
#   12  (list-element pure closure: 10 + 2)
#   14  (map-value pure closure: 10 + 4)
#   15  (returned pure closure: 10 + 5)
# exit 0, leak-free.

pub struct Maker {
  pub fn adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

pub struct Box {
  op :: fn(i64) -> i64
}

fn main(_args :: [String]) -> u8 {
  # DIRECT non-capturing combinator callback (devirtualized) — placed first.
  doubled = Enum.map([10], fn(v :: i64) -> i64 { v * 2 })
  IO.puts(Integer.to_string(List.get(doubled, 0)))

  bf = %Box{op: Maker.adder(1)}
  IO.puts(Integer.to_string(bf.op(10)))

  ops = [Maker.adder(2)]
  IO.puts(Integer.to_string(List.get(ops, 0)(10)))

  handlers = %{:a => Maker.adder(4)}
  IO.puts(Integer.to_string(Map.get(handlers, :a, Maker.adder(0))(10)))

  add5 = Maker.adder(5)
  IO.puts(Integer.to_string(add5(10)))
  0
}
