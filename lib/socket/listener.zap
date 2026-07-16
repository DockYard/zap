@doc = """
  `SocketListener` — a value-threaded handle to a LISTENING socket, a type
  DISTINCT from `Socket` (Phase S1, the Ranch/Thousand-Island lesson).

  A listener and a data socket wrap the same one-word, single-owner,
  generation-validated `zap_socket_handle`, but they are separate Zap types on
  purpose: the type system alone forbids the classic category errors — there is
  no `SocketListener.send`/`recv` (you cannot read or write a listener) and no
  `Socket.accept` (you cannot accept on a data socket). `Socket.listen` yields
  a `SocketListener`; `Socket.accept(listener)` yields a `Socket`. (`accept`
  lives on `Socket` — the type it produces — so that `SocketListener` holds NO
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

      case Socket.listen(SocketAddress.loopback(0), 128) {
        Result.Ok(listener) -> {
          case SocketListener.accept(listener) {
            Result.Ok(connection) -> serve(connection)
            Result.Error(_error)  -> :accept_failed
          }
        }
        Result.Error(_error) -> :listen_failed
      }
  """

@available_on(:network)

pub struct SocketListener {
  zap_socket_handle :: u64

  @doc = """
    Returns the local (bound) port of the listener — the ephemeral port a
    `listen(_, 0)` was assigned. Panics on a closed or stale handle.

    ## Examples

        SocketListener.local_port(listener)   # => e.g. 54233
    """

  @available_on(:network)

  pub fn local_port(listener :: SocketListener) -> i64 {
    :zig.SocketRuntime.local_port(listener.zap_socket_handle)
  }

  @doc = """
    Returns the local (bound) `SocketAddress` of the listener via
    `getsockname`. Panics on a closed or stale handle.

    ## Examples

        SocketListener.local_address(listener)
    """

  @available_on(:network)

  pub fn local_address(listener :: SocketListener) -> SocketAddress {
    SocketAddress.from_packed(:zig.SocketRuntime.endpoint(listener.zap_socket_handle, 0))
  }

  @doc = """
    Closes the listener: recycles its domain slot (every outstanding copy of
    the handle goes stale) and closes the fd. Pending `accept`s on this
    listener abort with `:closed`. Panics on a closed or stale handle.

    ## Examples

        SocketListener.close(listener)
    """

  @available_on(:network)

  pub fn close(listener :: SocketListener) -> Bool {
    :zig.SocketRuntime.close(listener.zap_socket_handle)
  }

  @doc = """
    Returns `true` while the listener is still open and owned by this program,
    `false` once it has been closed. Never panics.

    ## Examples

        SocketListener.open?(listener)
    """

  @available_on(:network)

  pub fn open?(listener :: SocketListener) -> Bool {
    :zig.SocketRuntime.is_live(listener.zap_socket_handle)
  }
}
