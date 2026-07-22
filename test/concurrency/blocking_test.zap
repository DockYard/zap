pub struct TestConcurrency.BlockingTest {
  use Zest.Case

  # `Process.blocking` (P4-J3): run a blocking / long-running leaf on the
  # dirty-scheduler pool, off the calling process's core, and get its result
  # back after the process re-attaches. The RUNTIME mechanism (co-scheduled
  # progress during a block, the detach/re-attach scheduler-local-invariant
  # handoff, pool sizing, the E7 manager-blocking verdict) is proven exhaustively
  # by the kernel harness (`src/runtime/concurrency/blocking_stress.zig`,
  # `e7_manager_blocking.zig`); these gate-on cases prove the Zap SURFACE — that
  # `Process.blocking(&f/0)` runs `f` off-core and round-trips its `i64` result
  # (including the boxing edges: zero, negative, and beyond 32 bits).

  describe("Process.blocking") {
    test("runs a named i64-returning function off-core and returns its result") {
      answer = Process.blocking(&TestConcurrency.BlockingTest.answer_entry/0)
      assert(answer == 42)
    }

    test("round-trips a computed result across the off-core detour") {
      product = Process.blocking(&TestConcurrency.BlockingTest.product_entry/0)
      assert(product == 1806)
    }

    test("round-trips a zero result (the null-pointer boxing edge)") {
      zero = Process.blocking(&TestConcurrency.BlockingTest.zero_entry/0)
      assert(zero == 0)
    }

    test("round-trips a negative result (the high-bit boxing edge)") {
      negative = Process.blocking(&TestConcurrency.BlockingTest.negative_entry/0)
      assert(negative == -7)
    }

    test("round-trips a result beyond 32 bits (full i64 width survives boxing)") {
      wide = Process.blocking(&TestConcurrency.BlockingTest.wide_entry/0)
      assert(wide == 9_000_000_000)
    }
  }

  # -- blocking-op leaves (zero-parameter, i64-returning) ------------------

  pub fn answer_entry() -> i64 {
    42
  }

  pub fn product_entry() -> i64 {
    42 * 43
  }

  pub fn zero_entry() -> i64 {
    0
  }

  pub fn negative_entry() -> i64 {
    -7
  }

  pub fn wide_entry() -> i64 {
    9_000_000_000
  }
}
