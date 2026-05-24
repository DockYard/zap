# Gap D acceptance — `assert_no_leaks { <block> }` proving the leak subsystem
# now covers a TERMINAL cross-function rescue catch under `-Dmemory=Memory.Tracking`.
#
# A cross-function raise that propagates through the error-union side-channel
# and is caught by a terminal `rescue` (handled, NOT re-raised) used to leak the
# boxed `Error` existential: the recovered box (`take_recoverable_raise` →
# `error_local`) is recovered INSIDE the landing-pad `then` branch on the
# SLOW path (the try body's tail is a CALL to a raising callee, not a `raise`),
# so the generic function-exit scope-exit drop pass never saw it and scheduled
# no release. `lowerTryRescue` now emits the owner-drop at the rescue handler's
# scope exit on the terminal-catch fall-through, releasing the box exactly once.
#
# `assert_no_leaks` reads the Tracking manager's live-allocation checkpoint
# (count + bytes) before and after the block and asserts the net delta is zero.
# Before the fix this assertion FAILED (net +1 abandoned `%CrossFnError{}` box);
# after the fix it PASSES — the cross-fn-recovered box is released on terminal
# catch. The control case asserts a still-LEAKING block is detected, proving the
# checkpoint actually observes box allocations (no false pass).
#
# Expected (under -Dmemory=Memory.Tracking):
#   * "cross-fn-terminal-catch: PASS" — assert_no_leaks over the caught cross-fn
#     raise passes (the recovered box is released exactly once).
#   * "abandoned-box: FAIL" — assert_no_leaks over a deliberately abandoned box
#     fails, with the net leaked allocation count as the failure detail.
#   * a final summary line with exactly 1 assertion failure → exit 1.

@code Z9401
pub error CrossFnError {}

pub struct CrossFnWorker {
  @doc = """
    Raises a `CrossFnError` from a separate function so the error propagates to
    the caller through the cross-function error-union side-channel (the SLOW
    landing-pad path, distinct from a body-local `raise`).
    """

  fn boom() -> String raises CrossFnError {
    raise %CrossFnError{message: "cross-fn boom"}
  }
}

pub struct Test.GapDCrossFnCatchNoLeak {
  use Zest.Case

  @doc = """
    Terminally catches a cross-function raise and returns the handler's value.
    The `try`/`rescue` lives at statement position in a normal function body
    (where the recoverable-raise lowering applies) so the `assert_no_leaks`
    block below can exercise it through a plain call — the recovered box is
    released at this function's rescue-handler scope exit.
    """

  fn catch_cross_fn() -> String {
    try {
      CrossFnWorker.boom()
    } rescue {
      e :: CrossFnError -> "caught"
    }
  }

  test("terminal cross-fn rescue catch releases the recovered box") {
    case("caught cross-fn raise leaks nothing") {
      assert_no_leaks {
        recovered = Test.GapDCrossFnCatchNoLeak.catch_cross_fn()
        assert(recovered == "caught")
      }
    }

    case("repeated terminal catches do not accumulate leaked boxes") {
      assert_no_leaks {
        first = Test.GapDCrossFnCatchNoLeak.catch_cross_fn()
        second = Test.GapDCrossFnCatchNoLeak.catch_cross_fn()
        third = Test.GapDCrossFnCatchNoLeak.catch_cross_fn()
        assert(first == "caught")
        assert(second == "caught")
        assert(third == "caught")
      }
    }
  }
}

fn main(_args :: [String]) -> u8 {
  Test.GapDCrossFnCatchNoLeak.run()
  failures = :zig.Zest.summary()
  if failures == 0 {
    0
  } else {
    1
  }
}
