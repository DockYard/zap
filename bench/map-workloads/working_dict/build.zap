pub struct WorkingDict.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :working_dict ->
        %Zap.Manifest{
          name: "working_dict",
          version: "0.1.0",
          kind: :bin,
          root: "WorkingDict.main/1",
          paths: ["./*.zap"],
          deps: [{:zap_stdlib, {:path, "/Users/bcardarella/projects/zap/lib"}}]
        }
      _ ->
        panic("Unknown target: use 'working_dict'")
    }
  }
}
