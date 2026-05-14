pub struct Factorial.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :factorial ->
        %Zap.Manifest{
          name: "factorial",
          version: "0.1.0",
          kind: :bin,
          root: "Factorial.main/1",
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'factorial'")
    }
  }
}
