pub struct EnvConfig.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :env_config ->
        %Zap.Manifest{
          name: "env_config",
          version: "0.1.0",
          kind: :bin,
          root: &EnvConfig.main/1,
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'env_config'")
    }
  }
}
