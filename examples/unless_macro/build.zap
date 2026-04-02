pub module UnlessMacro.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :unless_macro ->
        %Zap.Manifest{
          name: "unless_macro",
          version: "0.1.0",
          kind: :bin,
          root: "UnlessMacro.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'unless_macro'")
    }
  }
}
