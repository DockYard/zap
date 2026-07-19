pub struct TlsServer.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :tls_server ->
        %Zap.Manifest{
          name: "tls_server_example",
          version: "0.1.0",
          kind: :bin,
          root: &TlsServer.main/1,
          optimize: :debug,
          runtime_concurrency: true,
          deps: [%Zap.Dep{name: "zap_stdlib", path: "../../lib"}],
          paths: ["./tls_server.zap"]
        }
      _ ->
        panic("Unknown target: use 'tls_server'")
    }
  }
}
