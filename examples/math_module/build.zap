pub module MathModule.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :math_module ->
        %Zap.Manifest{
          name: "math_module",
          version: "0.1.0",
          kind: :bin,
          root: "MathModule.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'math_module'")
    }
  }
}
