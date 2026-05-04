@doc = """
  Parent struct used to demonstrate field inheritance via `extends`.
  Sub-types pick up `species` and `legs` from the `Animal` shape and
  layer their own fields on top.
  """

pub struct Animal {
  species :: String
  legs :: i64
}
