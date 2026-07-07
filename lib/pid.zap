@doc = """
  A typed process handle: `Pid(message_type)` identifies a process
  together with the type of message its mailbox carries, the analogue
  of Gleam's typed `Subject`. `Process.send` only accepts a `Pid(m)`
  paired with a message of type `m`, so sending a value the receiver
  cannot decode is a compile error at the send site.

  ## The typed-handle model

  The handle wraps the kernel's raw pid encoding (`raw`, a packed
  `u64` of slot/generation/model/node bits) and adds a phantom
  `message_type` parameter — the parameter appears in no field, so
  every `Pid(...)` instantiation has the identical one-word runtime
  layout while remaining a distinct type to the checker.

  Because pids are plain one-word scalars, a pid may itself travel
  inside a message: send the `raw` bits (a `u64`) and let the
  receiver re-type them. That re-typing — `Process.pid(m, bits)` —
  is the Phase 2 untyped escape hatch: raw bits carry no message
  type, and stamping one on is an assertion the compiler cannot
  check yet. A first-class untyped `Pid` variant (usable behind a
  `catch_all`-required receive) is deliberately deferred to the
  registry/dynamic-use work (plan item 2.1's untyped-pid half,
  P2-J4) rather than approximated here.

  ## Examples

      echo = Process.pid(i64, Process.spawn(&MyServer.echo_loop/0))
      Process.send(echo, 42)              # type-checked against i64
      Process.send(echo, "hi")            # compile error

  """

pub struct Pid(message_type) {
  raw :: u64

  @doc = """
    Types raw pid bits (`u64` kernel encoding) as a `Pid(message_type)`
    handle for a caller-chosen message type. Annotate (or bind against)
    the target `Pid(M)` to pin the message type: `(Pid.of(bits) ::
    Pid(Signal))` yields a `Pid(Signal)`. This is the general re-typing
    constructor — the analogue of `Process.pid`'s per-token scalar
    clauses, but open to ANY sendable message type including a payload-
    free message union, which the scalar `Process.pid(<token>, bits)`
    macro set cannot name. Like every pid re-typing, the stamp is an
    unchecked assertion about what the target process expects (P2-J4
    message-union typing).

    ## Examples

        responder = (Pid.of(Process.spawn(&Server.loop/0)) :: Pid(Signal))
        Process.send(responder, Signal.Ping)   # type-checked against Signal

    """

  pub fn of(raw_bits :: u64) -> Pid(message_type) {
    %Pid{raw: raw_bits}
  }
}
