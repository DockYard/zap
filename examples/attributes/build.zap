pub struct Attributes.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :attributes ->
        %Zap.Manifest{
          name: "attributes",
          version: "0.1.0",
          kind: :bin,
          root: "Attributes.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'attributes'")
    }
  }
}
