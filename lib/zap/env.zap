@doc = """
  Build environment passed to `Zap.Builder.manifest/1`.

  The environment identifies the requested target and host platform.
  """

pub struct Zap.Env {
  target :: Atom
  os :: Atom
  arch :: Atom
}
