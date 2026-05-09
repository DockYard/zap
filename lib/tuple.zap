@native_type = "tuple"

pub struct Tuple {
  @structdoc = """
  Heterogeneous fixed-arity product type.

  Tuples are anonymous structural shapes. `{i64, String, Bool}` is a
  distinct type from `{i64, String, Bool, Atom}`. Slot access is
  compile-time only with numeric fields such as `tuple.0` and
  `tuple.1`; runtime indexing is intentionally unsupported because
  tuple slots can have different static types.
  """

  @fndoc = """
  Returns the number of slots in a tuple.

  The result is determined from the tuple's static arity. This is a
  macro so heterogeneous tuple values can be passed without widening
  them to a nominal wrapper type.
  """

  pub macro size(tuple_expression :: Expr) -> Expr {
    quote {
      :zig.Tuple.size(unquote(tuple_expression))
    }
  }
}
