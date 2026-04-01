pub module BinaryPatterns.Builder {
  pub fn manifest(env :: Zap.Env) :: Zap.Manifest {
    case env.target {
      :binary_patterns ->
        %Zap.Manifest{
          name: "binary_patterns",
          version: "0.1.0",
          kind: :bin,
          root: "BinaryPatterns.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'binary_patterns'")
    }
  }
}
