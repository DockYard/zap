pub struct ReadMostly.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :read_mostly ->
        %Zap.Manifest{
          name: "read_mostly",
          version: "0.1.0",
          kind: :bin,
          root: &ReadMostly.main/1,
          paths: ["./*.zap"],
          deps: [{:zap_stdlib, {:path, "/Users/bcardarella/projects/zap/lib"}}]
        }
      _ ->
        panic("Unknown target: use 'read_mostly'")
    }
  }
}
