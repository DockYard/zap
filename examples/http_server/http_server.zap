# A BEAM-style HTTP/1.1 server: one Zap process per inbound connection.
#
# The shape (the S3 socket-server architecture, straight from the stdlib):
#
#   * the ROOT process binds the listener and runs the accept loop under the
#     `SocketServer` policy helpers (trap-exits, capacity gate, dead-handler
#     reaping, graceful drain);
#   * every accepted connection is MOVED (`Process.send_move`) to a freshly
#     `Process.spawn_link`ed HANDLER process, which adopts it via
#     `receive Socket` — the acceptor never touches the connection again;
#   * a handler crash is an EXIT signal delivered to the (trapping) acceptor
#     and reaped on its next turn — one bad connection can NEVER take down
#     the server or its sibling connections. `GET /crash` demonstrates this
#     live: the handler dies mid-request, the server keeps serving.
#
# Run with:
#   zap run http_server                 # listens on http://127.0.0.1:8080
#   zap run http_server -- 9000         # any port
#
# Then, from another terminal:
#   curl http://127.0.0.1:8080/          # hello page, shows the handler's pid
#   curl http://127.0.0.1:8080/crash     # kills THAT handler only
#   curl http://127.0.0.1:8080/          # ...and the server is still up

@doc = """
  A parsed HTTP request line: the method, the request target (path), and
  everything needed to route. Header fields beyond the request line are
  received (the handler reads the full head) but not interpreted — this is
  a routing example, not a general HTTP library.
  """

pub struct HttpRequest {
  method :: String
  path :: String
}

@doc = """
  The per-connection-process HTTP server: root-process accept loop under the
  `SocketServer` policy helpers, one spawned handler process per connection,
  socket ownership transferred by move.
  """

pub struct HttpServer {
  @doc = """
    Binds the listener (port from the first CLI argument, default 8080) and
    runs the accept loop in the root process. Returns 1 only when the bind
    itself fails; the serving loop runs until the process is stopped.
    """

  pub fn main(_args :: [String]) -> u8 {
    port = HttpServer.requested_port()
    case Socket.listen(SocketAddress.loopback(port), 128) {
      Result.Error(bind_error) ->
        {
          IO.puts("bind failed on port " <> Integer.to_string(port) <> ": " <> Atom.to_string(bind_error.reason))
          1
        }
      Result.Ok(listener) ->
        {
          IO.puts("Listening on http://127.0.0.1:" <> Integer.to_string(SocketListener.local_port(listener)))
          IO.puts("Every connection is served by its own Zap process — try GET /crash.")
          # A server never exits, so the buffered banner must be flushed to
          # become visible now rather than at process teardown.
          _flushed = IO.flush()
          # `SocketServer.init` traps exits so handler crashes arrive as
          # reapable EXIT signals; the options are (accept_poll_ms,
          # max_connections, shutdown_timeout_ms).
          state = SocketServer.init(SocketServer.options(100, 256, 5000))
          HttpServer.accept_loop(state, listener)
          0
        }
    }
  }

  @doc = """
    One accept-loop turn: reap dead handlers, honor a drain request, hold at
    the capacity gate, otherwise accept the next connection and hand it — by
    MOVE — to a fresh handler process.

    Deliberately a SINGLE self-recursive function: every "keep serving" step
    is a tail call to `accept_loop` ITSELF, which the compiler loopifies into
    a constant-stack loop. Splitting the turn across mutually-recursive
    helpers would defeat the self-recursion TCO and grow one fiber-stack
    frame per accepted connection — a latent DoS on a long-lived server.
    """

  pub fn accept_loop(state :: SocketServerState, listener :: SocketListener) -> Nil {
    reaped = SocketServer.reap_signals(state)
    case SocketServer.draining?(reaped) {
      true ->
        {
          # Graceful drain: refuse new connections immediately, give
          # in-flight handlers the shutdown grace, then force-reclaim.
          _closed = SocketListener.close(listener)
          _drained = SocketServer.drain(reaped)
          nil
        }
      false ->
        case SocketServer.at_capacity?(reaped) {
          true -> HttpServer.accept_loop(SocketServer.wait_for_slot(reaped), listener)
          false ->
            case Socket.accept(listener, reaped.options.accept_poll_ms) {
              Result.Ok(conn) ->
                {
                  # One process per connection: the socket MOVES to the
                  # handler (`conn` is consumed here); the handler adopts it
                  # with `receive Socket` and owns its whole lifetime.
                  handler = Process.spawn_link(&HttpServer.handler_entry/0)
                  _moved = Process.send_move((Pid.of(handler) :: Pid(Socket)), conn)
                  HttpServer.accept_loop(SocketServer.admitted(reaped, handler), listener)
                }
              # `:etimedout` is the quiet-poll heartbeat — loop and re-reap.
              Result.Error(_accept_error) -> HttpServer.accept_loop(reaped, listener)
            }
        }
    }
  }

  @doc = """
    The per-connection handler process body: adopt the moved connection,
    read one request, respond, close. Runs in its OWN process — an
    unhandled failure here is an EXIT the acceptor reaps, never a server
    crash.
    """

  pub fn handler_entry() -> Nil {
    conn = receive Socket {
      moved_connection -> moved_connection
    }
    HttpServer.serve(conn)
  }

  # ---- request handling (inside the handler process) -----------------------

  # Read the request head, route it, respond, close. One request per
  # connection (`Connection: close`) keeps the example free of keep-alive
  # bookkeeping.
  fn serve(conn :: Socket) -> Nil {
    head = HttpServer.read_request_head(conn, "")
    case String.length(head) == 0 {
      true ->
        {
          _closed = Socket.close(conn)
          nil
        }
      false -> HttpServer.route(conn, HttpServer.parse_request_line(head))
    }
  }

  # Accumulate received chunks until the blank line that ends the head
  # (`CRLF CRLF`) is seen. Single self-recursive function (constant stack via
  # the self-recursion TCO — same rule as `accept_loop`). Returns "" on a
  # peer that closes, times out, or errors before completing a head.
  fn read_request_head(conn :: Socket, accumulated :: String) -> String {
    case String.contains?(accumulated, "\r\n\r\n") {
      true -> accumulated
      false ->
        case Socket.recv(conn, 0, 10000) {
          SocketRecv.Chunk(bytes) -> HttpServer.read_request_head(conn, accumulated <> bytes)
          SocketRecv.Closed -> ""
          SocketRecv.TimedOut(_partial) -> ""
          SocketRecv.Failed(_recv_error) -> ""
        }
    }
  }

  # `"GET /path HTTP/1.1" -> %HttpRequest{method: "GET", path: "/path"}`;
  # malformed request lines parse as an empty method, which routes to 400.
  fn parse_request_line(head :: String) -> HttpRequest {
    line_end = String.index_of(head, "\r\n")
    request_line = case line_end >= 0 {
      true -> String.slice(head, 0, line_end)
      false -> head
    }
    tokens = String.split(request_line, " ")
    case List.length(tokens) >= 2 {
      true -> %HttpRequest{method: List.at(tokens, 0), path: List.at(tokens, 1)}
      false -> %HttpRequest{method: "", path: ""}
    }
  }

  # The router. `/crash` deliberately kills THIS handler process mid-request
  # to demonstrate per-connection isolation: the client sees a dropped
  # connection, the acceptor reaps the EXIT, and the server keeps serving.
  fn route(conn :: Socket, request :: HttpRequest) -> Nil {
    case request.method == "GET" {
      false ->
        case String.length(request.method) == 0 {
          true -> HttpServer.respond(conn, "400 Bad Request", "malformed request line\n")
          false -> HttpServer.respond(conn, "405 Method Not Allowed", "this example serves GET only\n")
        }
      true ->
        case request.path {
          "/" -> HttpServer.respond(conn, "200 OK", HttpServer.hello_page())
          "/crash" -> Process.exit_with(:demo_crash)
          _ -> HttpServer.respond(conn, "404 Not Found", "no route for " <> request.path <> "\n")
        }
    }
  }

  # The hello page names the HANDLER process serving this exact connection —
  # hit `/` twice and the pid changes: two connections, two processes.
  fn hello_page() -> String {
    pid_text = Integer.to_string(Process.self())
    page_open = "<!doctype html><html><head><title>Zap HTTP</title></head><body>"
    page_open <> HttpServer.page_body(pid_text) <> "</body></html>\n"
  }

  fn page_body(pid_text :: String) -> String {
    "<h1>Hello from Zap</h1><p>This connection is served by its own Zap process: <code>pid " <> pid_text <> "</code></p><p><a href=\"/crash\">/crash</a> kills this handler (and only this handler).</p>"
  }

  # One complete HTTP/1.1 response: status line, minimal headers with an
  # exact Content-Length, `Connection: close`, then the body — and close.
  fn respond(conn :: Socket, status :: String, body :: String) -> Nil {
    status_line = "HTTP/1.1 " <> status <> "\r\n"
    headers = "Content-Type: text/html; charset=utf-8\r\nContent-Length: " <> Integer.to_string(String.length(body)) <> "\r\nConnection: close\r\n\r\n"
    _sent = Socket.send_all(conn, status_line <> headers <> body, 10000)
    _closed = Socket.close(conn)
    nil
  }

  # The listen port: first CLI argument, default 8080 (multi-clause dispatch
  # on the `i64 | nil` parse result).
  fn requested_port() -> i64 {
    case System.arg_count() >= 1 {
      true -> HttpServer.port_or_default(String.to_integer(System.arg_at(0)))
      false -> 8080
    }
  }

  fn port_or_default(nil) -> i64 {
    8080
  }

  fn port_or_default(parsed_port :: i64) -> i64 {
    parsed_port
  }
}
