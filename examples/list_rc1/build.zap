pub struct ListRc1.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :list_rc1 ->
        %Zap.Manifest{
          name: "list_rc1",
          version: "0.1.0",
          kind: :bin,
          root: &ListRc1.main/1,
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'list_rc1'")
    }
  }
}
