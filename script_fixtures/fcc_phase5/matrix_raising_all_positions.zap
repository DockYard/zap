# FCC Phase 5 — Item 7 (final matrix). RAISING capturing closures across the
# field / list / map / return positions, each discharged by a `rescue`, in one
# well-ordered program. Gates the {raising} × {capturing} × {field, list, map,
# return} × {discharge} cells of the closure matrix under BOTH managers.
#
# Expected (both managers): prints
#   11  (field-stored raising closure, rescued)
#   22  (list-element raising closure, rescued)
#   33  (map-value raising closure, rescued)
#   44  (returned raising closure, rescued)
# exit 0, leak-free.

@code Z9701
pub error Boom {}

pub struct Maker {
  pub fn risky(limit :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 {
      if x > limit {
        raise %Boom{message: "over"}
      }
      x + limit
    }
  }
}

pub struct Box {
  op :: fn(i64) -> i64
}

fn main(_args :: [String]) -> u8 {
  bf = %Box{op: Maker.risky(5)}
  r1 = try { bf.op(99) } rescue { e :: Boom -> 11 }
  IO.puts(Integer.to_string(r1))

  ops = [Maker.risky(5)]
  r2 = try { List.get(ops, 0)(99) } rescue { e :: Boom -> 22 }
  IO.puts(Integer.to_string(r2))

  hs = %{:a => Maker.risky(5)}
  r3 = try { Map.get(hs, :a, Maker.risky(0))(99) } rescue { e :: Boom -> 33 }
  IO.puts(Integer.to_string(r3))

  action = Maker.risky(5)
  r4 = try { action(99) } rescue { e :: Boom -> 44 }
  IO.puts(Integer.to_string(r4))
  0
}
