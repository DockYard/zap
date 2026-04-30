@doc = """
  Terminal input mode used by `IO.mode/1` and `IO.mode/2`.
  """

pub union IO.Mode {
  Raw,
  Normal
}
