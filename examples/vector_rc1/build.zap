pub struct VectorRc1.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :vector_rc1 ->
        %Zap.Manifest{
          name: "vector_rc1",
          version: "0.1.0",
          kind: :bin,
          root: "VectorRc1.main/1",
          paths: ["./*.zap"],
          deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'vector_rc1'")
    }
  }
}
