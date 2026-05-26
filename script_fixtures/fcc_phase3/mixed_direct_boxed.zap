# FCC Phase 3 — Item 3: a single program mixing a DEVIRTUALIZED direct call and
# a BOXED `Callable` call — each takes the correct representation.
#
# Direct (devirtualized) path: `Enum.map(nums, fn(x) { x * 2 })` over a [i64]
# with an INLINE NON-capturing closure. The callback has no captures and is
# passed directly as a call argument, so it stays on the #201/Gap-E direct path:
# the monomorphizer binds the callback's effect_var to a CONCRETE `ZigType.function`
# (a bare fn-ptr), NOT a boxed `Callable`. No box is allocated for it.
#
# Boxed path: `make_adder(n)` returns a CAPTURING closure stored into a
# `[fn(i64) -> i64]` list element, forcing a boxed `ProtocolBox(Callable)`
# existential, dispatched through the box `call` slot.
#
# Both coexist in one `main`; each is lowered to its correct representation,
# validated through the ZIR/IR path (ZAP_DUMP_IR_FN), never source strings:
#   - DIRECT: `main` lowers the inline callback as `make_closure` (the
#     {call_fn, env} direct-closure struct) passed as a `.share` call arg; the
#     `Enum_map_next__i64_i64_List` specialization's callback param is `.trivial`
#     (a bare fn-ptr `ZigType.function`) and the callback fires via `call_closure`
#     — NO `box_as_protocol`, NO `protocol_dispatch`, NO `ProtocolBox`.
#   - BOXED: `make_adder(100)` -> a list element -> the extracted value is a
#     `ProtocolBox` (`copy_value` + `retain{protocol_box_retain}`) dispatched via
#     `protocol_dispatch` through the box `call` slot.
#
# Expected (both managers):
#   doubled = [2, 4, 6]; sum 12
#   stored boxed adder make_adder(100) applied to 5 => 105
#   prints 12, 105, exit 0, ZERO leaks.

pub struct Mixed {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn sum_list(xs :: [i64]) -> i64 {
    Enum.reduce(xs, 0, fn(acc :: i64, x :: i64) -> i64 { acc + x })
  }
}

fn main(args :: [String]) -> u8 {
  # Direct devirtualized path: inline non-capturing closure as a call arg.
  nums = [1, 2, 3]
  doubled = Enum.map(nums, fn(x :: i64) -> i64 { x * 2 })
  IO.puts(Integer.to_string(Mixed.sum_list(doubled)))

  # Boxed path: a capturing closure stored into a list element (forces a box).
  adders = [Mixed.make_adder(100)]
  IO.puts(Integer.to_string(List.get(adders, 0)(5)))
  0
}
