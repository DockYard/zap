@doc = """
  `Socket.Listener` — a value-threaded handle to a LISTENING socket, a type
  DISTINCT from `Socket` (Phase S1, the Ranch/Thousand-Island lesson).

  A listener and a data socket wrap the same one-word, single-owner,
  generation-validated `zap_socket_handle`, but they are separate Zap types on
  purpose: the type system alone forbids the classic category errors — there is
  no `Socket.Listener.send`/`recv` (you cannot read or write a listener) and no
  `Socket.accept` (you cannot accept on a data socket). `Socket.listen` yields
  a `Socket.Listener`; `Socket.accept(listener)` yields a `Socket`. (`accept`
  lives on `Socket` — the type it produces — so that `Socket.Listener` holds NO
  back-reference to `Socket`: the two types form a one-directional dependency
  rather than a mutual cycle, which the current codegen cannot yet emit.)

  Accepted sockets INHERIT the listener's options (the accepted connection is
  configured like the listener that produced it).

  Move-only ownership is the same as `Socket`: a listener travels between
  processes only by `Process.send_move`, and a stale/foreign handle panics
  loudly (generation-validated, never memory-unsafe).

  ## Availability

  Every declaration requires the `:network` target capability; `wasm32-wasi`
  rejects socket code at compile time.

  ## Examples

      case Socket.listen(Socket.Address.loopback(0), 128) {
        Result.Ok(listener) -> {
          case Socket.Listener.accept(listener) {
            Result.Ok(connection) -> serve(connection)
            Result.Error(_error)  -> :accept_failed
          }
        }
        Result.Error(_error) -> :listen_failed
      }
  """

@available_on(:network)

pub struct Socket.Listener {
  zap_socket_handle :: u64

  @doc = """
    Returns the local (bound) port of the listener — the ephemeral port a
    `listen(_, 0)` was assigned. Panics on a closed or stale handle.

    ## Examples

        Socket.Listener.local_port(listener)   # => e.g. 54233
    """

  @available_on(:network)

  pub fn local_port(listener :: Socket.Listener) -> i64 {
    :zig.SocketRuntime.local_port(listener.zap_socket_handle)
  }

  @doc = """
    Returns the local (bound) `Socket.Address` of the listener via
    `getsockname`. Panics on a closed or stale handle.

    ## Examples

        Socket.Listener.local_address(listener)
    """

  @available_on(:network)

  pub fn local_address(listener :: Socket.Listener) -> Socket.Address {
    Socket.Address.from_packed(:zig.SocketRuntime.endpoint(listener.zap_socket_handle, 0))
  }

  @doc = """
    Closes the listener: recycles its domain slot (every outstanding copy of
    the handle goes stale) and closes the fd. Pending `accept`s on this
    listener abort with `:closed`. Panics on a closed or stale handle.

    ## Examples

        Socket.Listener.close(listener)
    """

  @available_on(:network)

  pub fn close(listener :: Socket.Listener) -> Bool {
    :zig.SocketRuntime.close(listener.zap_socket_handle)
  }

  @doc = """
    Returns `true` while the listener is still open and owned by this program,
    `false` once it has been closed. Never panics.

    ## Examples

        Socket.Listener.open?(listener)
    """

  @available_on(:network)

  pub fn open?(listener :: Socket.Listener) -> Bool {
    :zig.SocketRuntime.is_live(listener.zap_socket_handle)
  }
}
