pub struct HttpClient.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :http_client ->
        %Zap.Manifest{
          name: "http_client_example",
          version: "0.1.0",
          kind: :bin,
          root: &HttpClient.main/1,
          optimize: :debug,
          runtime_concurrency: true,
          paths: ["./http_client.zap"]
        }
      _ ->
        panic("Unknown target: use 'http_client'")
    }
  }
}
