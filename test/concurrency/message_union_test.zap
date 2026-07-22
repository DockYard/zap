pub struct Concurrency.MessageUnionTest {
  use Zest.Case

  # A closed, payload-free message union — the Phase-2 shape of a
  # per-process message type `M`. Its variants ARE `u32` atom ids at
  # runtime, so a `PingPong` value travels over the ordinary scalar send
  # transport and decodes through the atom receive primitive. A `receive
  # PingPong { ... }` must handle every variant (or carry a catch-all), and
  # `Process.send(pid :: Pid(PingPong), msg)` type-checks `msg` against
  # `PingPong` at the send site. Payload-free union variants match as
  # atom-literal patterns (`:Ping`), the shape of their atom-id runtime
  # representation.
  pub union PingPong {
    Ping,
    Pong
  }

  describe("union message self round-trip") {
    test("an exhaustive receive over a self-sent union value dispatches by variant") {
      self_pid = (Pid.of(Process.self()) :: Pid(PingPong))
      _sent = Process.send(self_pid, PingPong.Ping)
      result = receive PingPong {
        :Ping -> 1
        :Pong -> 2
      after
        0 -> -1
      }
      assert(result == 1)
    }

    test("the other variant reaches its own arm") {
      self_pid = (Pid.of(Process.self()) :: Pid(PingPong))
      _sent = Process.send(self_pid, PingPong.Pong)
      result = receive PingPong {
        :Ping -> 1
        :Pong -> 2
      after
        0 -> -1
      }
      assert(result == 2)
    }
  }

  describe("union receive — catch-all opt-out") {
    test("a catch-all arm satisfies exhaustiveness and absorbs the unlisted variant") {
      self_pid = (Pid.of(Process.self()) :: Pid(PingPong))
      _sent = Process.send(self_pid, PingPong.Pong)
      result = receive PingPong {
        :Ping -> 10
        _ -> 20
      after
        0 -> -1
      }
      assert(result == 20)
    }

    test("the explicitly-handled variant still takes its own arm under a catch-all") {
      self_pid = (Pid.of(Process.self()) :: Pid(PingPong))
      _sent = Process.send(self_pid, PingPong.Ping)
      result = receive PingPong {
        :Ping -> 10
        _ -> 20
      after
        0 -> -1
      }
      assert(result == 10)
    }
  }

  describe("union-typed ping-pong across two processes") {
    test("a Ping round-trips as a Pong through a responder process") {
      responder_bits = Process.spawn(&Concurrency.MessageUnionTest.pong_responder/0)
      # hand the responder our reply channel as raw bits (u64 transport)
      reply_channel = Process.pid(u64, responder_bits)
      _delivered = Process.send(reply_channel, Process.self())
      # send it a typed union message
      signal_channel = (Pid.of(responder_bits) :: Pid(PingPong))
      _pinged = Process.send(signal_channel, PingPong.Ping)
      reply = receive PingPong {
        :Ping -> "ping"
        :Pong -> "pong"
      }
      assert(reply == "pong")
    }
  }

  # The responder first receives the parent's raw pid bits (the `u64`
  # reply-channel handshake), re-types them as a `Pid(PingPong)`, then
  # exhaustively receives a `PingPong` and replies with the opposite variant.
  pub fn pong_responder() -> Nil {
    parent_bits = receive u64 {
      bits -> bits
    }
    parent = (Pid.of(parent_bits) :: Pid(PingPong))
    reply = receive PingPong {
      :Ping -> PingPong.Pong
      :Pong -> PingPong.Ping
    }
    _sent = Process.send(parent, reply)
    nil
  }
}
