pub struct ComputedAttributes.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :computed_attributes ->
        %Zap.Manifest{
          name: "computed_attributes",
          version: "0.1.0",
          kind: :bin,
          root: "ComputedAttributes.main/1",
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'computed_attributes'")
    }
  }
}
