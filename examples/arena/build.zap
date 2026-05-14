pub struct Arena.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :arena ->
        %Zap.Manifest{
          name: "arena",
          version: "0.1.0",
          kind: :bin,
          root: "Arena.main/1",
          paths: ["./*.zap"],
          memory: Memory.Arena
        }
      _ ->
        panic("Unknown target: use 'arena'")
    }
  }
}
