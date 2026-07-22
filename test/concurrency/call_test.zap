pub struct Concurrency.CallTest {
  use Zest.Case

  describe("Process.call round trips") {
    test("calls a server and gets the typed reply, twice through one loop") {
      server = Concurrency.CallTest.start_adder(2)
      first = (Process.call(server, 41) :: i64)
      assert(first == 42)
      second = (Process.call(server, 8) :: i64)
      assert(second == 9)
    }

    test("round-trips a rich String request and reply") {
      server_bits = Process.spawn(&Concurrency.CallTest.echo_string_server_entry/0)
      server = (Pid.of(server_bits) :: Pid(Call(String)))
      greeting = (Process.call(server, "hello") :: String)
      assert(greeting == "pong: hello")
    }
  }

  describe("Process.call failure surface (Elixir-aligned exits)") {
    test("a call to a dead server exits :noproc immediately (monitor, not timeout)") {
      # The caller uses a 60 s timeout: only the monitor's immediate
      # :noproc DOWN can end this test promptly.
      _observer = Process.spawn_monitor(&Concurrency.CallTest.calls_dead_server_entry/0)
      reason = Process.await_signal()
      assert(reason == :noproc)
    }

    test("a server dying mid-call exits the caller with the server's reason, not :timeout") {
      _observer = Process.spawn_monitor(&Concurrency.CallTest.calls_crashing_server_entry/0)
      reason = Process.await_signal()
      assert(reason == :server_boom)
    }

    test("a silent-but-alive server exits the caller with :timeout") {
      _observer = Process.spawn_monitor(&Concurrency.CallTest.calls_silent_server_entry/0)
      reason = Process.await_signal()
      assert(reason == :timeout)
    }
  }

  describe("the ref-trick O(1) correlation skip (research R8)") {
    test("a 10k-message backlog is skipped in O(1) from the mark and preserved in order") {
      server = Concurrency.CallTest.start_adder(1)
      _flooded = Concurrency.CallTest.flood_self(0, 10000)

      visits_before = Process.correlated_receive_visits()
      started_millis = Process.monotonic_millis()
      reply = (Process.call(server, 41) :: i64)
      elapsed_millis = Process.monotonic_millis() - started_millis
      visits = Process.correlated_receive_visits() - visits_before

      assert(reply == 42)
      # THE O(1) PROOF (operation count, not vibes): the correlated
      # receive started at the receive-mark and examined only post-mark
      # envelopes — the reply plus at most a few wake-rescan visits —
      # never the 10_000-message backlog an O(N) head scan would walk.
      assert(visits < 10)
      _report = IO.puts("\nR8 ref-trick: call over a 10k backlog examined #{visits} envelope(s) in #{elapsed_millis} ms (an O(N) scan examines 10001+)")

      # No loss, no reorder: the skipped backlog drains in send order
      # through the steady-state receive.
      drained = Concurrency.CallTest.drain_in_order(0, 10000)
      assert(drained == 10000)
    }
  }

  # -- servers ------------------------------------------------------------------

  pub fn start_adder(calls_to_serve :: i64) -> Pid(Call(i64)) {
    server_bits = Process.spawn(&Concurrency.CallTest.adder_server_entry/0)
    _count_sent = Process.send(Process.pid(i64, server_bits), calls_to_serve)
    (Pid.of(server_bits) :: Pid(Call(i64)))
  }

  pub fn adder_server_entry() -> Nil {
    calls_to_serve = receive i64 { n -> n }
    Concurrency.CallTest.adder_loop(calls_to_serve)
  }

  pub fn adder_loop(remaining :: i64) -> Nil {
    case remaining == 0 {
      true -> nil
      false ->
        {
          call = receive Call(i64) { c -> c }
          _replied = Process.reply(call, call.request + 1)
          Concurrency.CallTest.adder_loop(remaining - 1)
        }
    }
  }

  pub fn echo_string_server_entry() -> Nil {
    call = receive Call(String) { c -> c }
    request_text = (call.request :: String)
    _replied = Process.reply(call, "pong: #{request_text}")
    nil
  }

  pub fn crashing_server_entry() -> Nil {
    _call = receive Call(i64) { c -> c }
    Process.exit_with(:server_boom)
  }

  pub fn silent_server_entry() -> Nil {
    _call = receive Call(i64) { c -> c }
    # Stay alive but never reply (nobody ever sends the i64).
    _hold = receive i64 { n -> n }
    nil
  }

  pub fn immediate_exit_entry() -> Nil {
    nil
  }

  # -- observer entries (their exit reason is the assertion surface) -----------

  pub fn calls_dead_server_entry() -> Nil {
    {dead_bits, _dead_ref} = Process.spawn_monitor(&Concurrency.CallTest.immediate_exit_entry/0)
    # Consume the DOWN so the server is PROVABLY dead before the call.
    _down = Process.await_signal()
    server = (Pid.of(dead_bits) :: Pid(Call(i64)))
    _never = (Process.call(server, 1, 60000) :: i64)
    nil
  }

  pub fn calls_crashing_server_entry() -> Nil {
    server_bits = Process.spawn(&Concurrency.CallTest.crashing_server_entry/0)
    server = (Pid.of(server_bits) :: Pid(Call(i64)))
    _never = (Process.call(server, 1, 60000) :: i64)
    nil
  }

  pub fn calls_silent_server_entry() -> Nil {
    server_bits = Process.spawn(&Concurrency.CallTest.silent_server_entry/0)
    server = (Pid.of(server_bits) :: Pid(Call(i64)))
    _never = (Process.call(server, 1, 30) :: i64)
    nil
  }

  # -- backlog helpers (tail-recursive) -----------------------------------------

  pub fn flood_self(index :: i64, count :: i64) -> Bool {
    case index == count {
      true -> true
      false ->
        {
          _sent = Process.send(Process.pid(i64, Process.self()), index)
          Concurrency.CallTest.flood_self(index + 1, count)
        }
    }
  }

  pub fn drain_in_order(expected :: i64, count :: i64) -> i64 {
    case expected == count {
      true -> expected
      false ->
        {
          got = receive i64 { n -> n }
          case got == expected {
            true -> Concurrency.CallTest.drain_in_order(expected + 1, count)
            false -> -1
          }
        }
    }
  }
}
