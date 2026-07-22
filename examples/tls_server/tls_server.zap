@doc = """
  A minimal gate-ON TLS 1.3 echo server for real-world-client interop testing
  (e.g. `openssl s_client`). Binds an ephemeral loopback port, prints
  `LISTENING <port>` on stdout, then accepts one TLS connection, echoes one
  payload, and exits.

  Run: `cd examples/tls_server && zap run tls_server` (with the local fork libs
  passed via -Dzap-compiler-lib / -Dllvm-lib-path).
  """

pub struct TlsServer {
  fn cert_pem() -> String {
    """
    -----BEGIN CERTIFICATE-----
    MIIBmjCCAT+gAwIBAgIUMMaoyKUPtk7DddXMceDO4Ct8JHkwCgYIKoZIzj0EAwIw
    FDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDcxODE5Mjc0MFoXDTM2MDcxNTE5
    Mjc0MFowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0D
    AQcDQgAEB2lsyvra4RAWZq/DqY2o0mxFVhRTYqCNHQepl87hKcH+FvAKtYvMBaeT
    vEdS1EHOoOmcVGvIPFV3JIf4K4+gTqNvMG0wHQYDVR0OBBYEFLyBFnPNF3GlffBT
    AixjsBkC5VSvMB8GA1UdIwQYMBaAFLyBFnPNF3GlffBTAixjsBkC5VSvMA8GA1Ud
    EwEB/wQFMAMBAf8wGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMAoGCCqGSM49
    BAMCA0kAMEYCIQDQKSD7MMuxS+Vr1sRd0xlrZR8QSNSEne+zFc+MVdALoAIhAJQN
    kxKtmLXPi6qM6KTlgO9hDglv/Qhl4YFCte+fZJAM
    -----END CERTIFICATE-----
    """
  }

  fn key_pem() -> String {
    """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEILFOeSNPKzUGGtZB1xBhwiKdj5ofWZ8eqpouy+3I/h60oAoGCCqGSM49
    AwEHoUQDQgAEB2lsyvra4RAWZq/DqY2o0mxFVhRTYqCNHQepl87hKcH+FvAKtYvM
    BaeTvEdS1EHOoOmcVGvIPFV3JIf4K4+gTg==
    -----END EC PRIVATE KEY-----
    """
  }

  # Echo one payload over an accepted TLS connection, then close. Returns an
  # exit-code contribution (0 on success).
  fn echo_once(conn :: Socket) -> u8 {
    case Socket.recv(conn, 0, 15000) {
      Socket.Recv.Chunk(bytes) ->
        {
          _sent = Socket.send(conn, bytes)
          _c = Socket.close(conn)
          (0 :: u8)
        }
      Socket.Recv.Closed ->
        {
          _c = Socket.close(conn)
          (0 :: u8)
        }
      Socket.Recv.TimedOut(_p) ->
        {
          _c = Socket.close(conn)
          (0 :: u8)
        }
      Socket.Recv.Failed(_e) ->
        {
          _c = Socket.close(conn)
          (0 :: u8)
        }
    }
  }

  pub fn main(_args :: [String]) -> u8 {
    config = %TlsServerConfig{cert_pem: TlsServer.cert_pem(), key_pem: TlsServer.key_pem(), alpn: ["http/1.1"]}
    case Tls.listen(Socket.Address.loopback(44330), config, 16) {
      Result.Error(_e) ->
        {
          _p = IO.puts("LISTEN_FAILED")
          (1 :: u8)
        }
      Result.Ok(listener) ->
        {
          port = Socket.Listener.local_port(listener)
          _p = IO.puts("LISTENING " <> Integer.to_string(port))
          result = case Tls.accept(listener, 180000) {
            Result.Ok(conn) -> TlsServer.echo_once(conn)
            Result.Error(_e) -> (2 :: u8)
          }
          _closed = Socket.Listener.close(listener)
          result
        }
    }
  }
}
