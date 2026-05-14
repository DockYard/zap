pub struct Versioned.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :versioned ->
        %Zap.Manifest{
          name: "versioned",
          version: "0.1.0",
          kind: :bin,
          root: &Versioned.main/1,
          paths: ["./*.zap"],
          deps: [{:zap_stdlib, {:path, "/Users/bcardarella/projects/zap/lib"}}]
        }
      _ ->
        panic("Unknown target: use 'versioned'")
    }
  }
}
