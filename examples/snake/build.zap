pub module Snake.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :snake ->
        %Zap.Manifest{
          name: "snake",
          version: "0.1.0",
          kind: :bin,
          root: "Snake.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'snake'")
    }
  }
}
