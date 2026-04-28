pub impl Stringable for Atom {
  @doc = """
    Render an atom as the bare name string. `:hello` becomes
    `"hello"`. Calls the runtime helper directly because
    `Atom.to_string` resolves back to this impl method — using the
    Zap-level dispatch would loop forever.
    """

  pub fn to_string(value :: Atom) -> String {
    :zig.Atom.to_string(value)
  }
}
