@doc = """
  One step in a manifest build pipeline.

  Exactly one action field should be set. Use `compile:` to compile the
  current manifest artifact and `run:` to execute the artifact produced
  by an earlier compile step.
  """

pub struct Zap.Build.Step {
  compile :: Zap.Build.Compile | Nil = nil
  run :: Zap.Build.Run | Nil = nil
}
