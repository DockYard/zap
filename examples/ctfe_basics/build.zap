pub module CtfeBasics.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :ctfe_basics ->
        %Zap.Manifest{
          name: "ctfe_basics",
          version: "0.1.0",
          kind: :bin,
          root: "CtfeBasics.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'ctfe_basics'")
    }
  }
}
