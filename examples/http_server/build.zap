pub struct HttpServer.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :http_server ->
        %Zap.Manifest{
          name: "http_server_example",
          version: "0.1.0",
          kind: :bin,
          root: &HttpServer.main/1,
          optimize: :debug,
          runtime_concurrency: true,
          paths: ["./http_server.zap"]
        }
      _ ->
        panic("Unknown target: use 'http_server'")
    }
  }
}
