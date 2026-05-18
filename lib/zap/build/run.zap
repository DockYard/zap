@doc = """
  Run the artifact produced by an earlier compile step.

  `args:` are passed to the executable before any command-line runtime
  arguments. When `forward_args:` is true, runtime arguments supplied to
  the Zap command are appended after `args:`.
  """

pub struct Zap.Build.Run {
  args :: [String] = []
  forward_args :: Bool = true
}
