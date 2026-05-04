@doc = """
  `Dog` extends `Animal` — it inherits `species` and `legs` from the
  parent struct and adds its own `name` and `good_boy` fields. Field
  inheritance composes the two field lists in declaration order with
  the parent's fields first.
  """

pub struct Dog extends Animal {
  name :: String
  good_boy :: Bool = true
}
