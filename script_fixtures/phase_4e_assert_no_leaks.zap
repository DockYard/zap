# Phase 4.e acceptance — `assert_no_leaks { <block> }` Zest primitive driven
# directly from a script `main/1` under `-Dmemory=Memory.Tracking`.
#
# `assert_no_leaks` reads the live-allocation checkpoint (count + bytes) the
# active Tracking manager exposes through the runtime, runs the block, then
# asserts the net live-allocation delta attributable to the block is zero. A
# clean block (no surviving heap allocation) passes; a leaking block (an
# abandoned `%Outer{cause: Some(%Inner{})}` whose boxed inner survives) fails
# with the attributed leak count + bytes as the failure detail.
#
# Expected (under -Dmemory=Memory.Tracking):
#   * "clean-block: PASS"  — assert_no_leaks over a non-leaking block passes
#   * "leak-block: FAIL"   — assert_no_leaks over a leaking block fails, and
#     the recorded failure names the net leaked allocation count.
#   * a final summary line with exactly 1 assertion failure.

@code Z9201
pub error Inner {}

@code Z9202
pub error Outer {}

pub struct Test.AssertNoLeaks {
  use Zest.Case

  test("assert_no_leaks") {
    case("clean block reports no leak") {
      assert_no_leaks {
        sum = 1 + 2 + 3
        assert(sum == 6)
      }
    }

    case("leaking block is caught") {
      assert_no_leaks {
        leaked = %Outer{cause: Option.Some(%Inner{})}
        IO.puts("constructed-leak")
      }
    }
  }
}

fn main(_args :: [String]) -> u8 {
  Test.AssertNoLeaks.run()
  failures = :zig.Zest.summary()
  if failures == 0 {
    0
  } else {
    1
  }
}
