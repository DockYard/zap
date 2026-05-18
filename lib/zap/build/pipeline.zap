@doc = """
  Build pipeline declaration used by `Zap.Manifest`.

  A pipeline is an ordered list of build steps. When a manifest leaves
  `pipeline:` as `nil`, Zap keeps the default behavior and compiles the
  manifest artifact only.
  """

pub struct Zap.Build.Pipeline {
  steps :: [Zap.Build.Step] = []
}
