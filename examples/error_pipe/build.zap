pub struct ErrorPipe.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :error_pipe ->
        %Zap.Manifest{
          name: "error_pipe",
          version: "0.1.0",
          kind: :bin,
          root: "ErrorPipe.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'error_pipe'")
    }
  }
}
