pub struct Cli.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :cli ->
        %Zap.Manifest{
          name: "cli",
          version: "0.1.0",
          kind: :bin,
          root: "Cli.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'cli'")
    }
  }
}
