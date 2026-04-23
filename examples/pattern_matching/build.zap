pub struct PatternMatching.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :pattern_matching ->
        %Zap.Manifest{
          name: "pattern_matching",
          version: "0.1.0",
          kind: :bin,
          root: "PatternMatching.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'pattern_matching'")
    }
  }
}
