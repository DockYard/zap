# Phase 4.e acceptance — the `@expect_leak` test attribute, driven from a
# script `main/1` under `-Dmemory=Memory.Tracking`.
#
# `@expect_leak` marks a `test` group as expected-to-leak: it INVERTS the
# whole-case leak assertion for every case in that group. A marked case PASSES
# if it leaks (a net live-allocation remains after the case body) and FAILS if
# it does NOT leak — a test that claims it leaks but no longer does is a stale
# expectation that should be removed. This is the mechanism that handles the
# intentional `FieldStorage.indirect` leak: a test exercising a recursive-struct
# teardown that intentionally leaks is marked `@expect_leak`, so the leak does
# not turn the suite red while still being asserted to actually occur.
#
# Expected (under -Dmemory=Memory.Tracking):
#   * the marked group whose case abandons a boxed value (a real net leak)
#     PASSES (the inversion).
#   * the marked group whose case does NOT leak FAILS, because the
#     @expect_leak expectation went stale.
#   * the Zest summary reports exactly 1 assertion failure.

@code Z9401
pub error Inner {}

@code Z9402
pub error Outer {}

pub struct Test.ExpectLeak {
  use Zest.Case

  test("a group that leaks passes when marked expected-to-leak") {
    @expect_leak
    case("abandons a boxed value") {
      leaked = %Outer{cause: Option.Some(%Inner{})}
      IO.puts("intentional-leak")
    }
  }

  test("a marked group that does NOT leak fails") {
    @expect_leak
    case("pure arithmetic, no allocation") {
      clean = 10 + 20
      assert(clean == 30)
    }
  }
}

fn main(_args :: [String]) -> u8 {
  Test.ExpectLeak.run()
  failures = :zig.Zest.summary()
  if failures == 0 {
    0
  } else {
    1
  }
}
