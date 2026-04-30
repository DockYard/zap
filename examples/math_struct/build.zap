pub struct MathStruct.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :math_struct ->
        %Zap.Manifest{
          name: "math_struct",
          version: "0.1.0",
          kind: :bin,
          root: "MathStruct.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'math_struct'")
    }
  }
}
