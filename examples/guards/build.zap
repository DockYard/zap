pub module Guards.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :guards ->
        %Zap.Manifest{
          name: "guards",
          version: "0.1.0",
          kind: :bin,
          root: "Guards.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'guards'")
    }
  }
}
