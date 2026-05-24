# Gap A acceptance — ARC correctness of a concrete-typed rescue binding.
#
# When a rescue arm filters on a concrete error type (`e :: MyError`), the
# binding `e` is the UNBOXED concrete value (Elixir's `rescue e in [MyError]`
# semantics): the runtime type-discrimination confirms the boxed `Error` IS a
# `MyError`, then `protocol_box_unbox` recovers a borrowed view of the concrete
# struct so both protocol-method calls (`Error.message(e)`) and concrete-field
# access (`e.status`) work on the same binding. The box still owns the heap
# cell and releases it at the rescue landing pad's scope exit; the unboxed
# binding is a borrow, so there is no double-free.
#
# This fixture drives that path under `-Dmemory=Memory.Tracking` inside an
# `assert_no_leaks { ... }` block: each call constructs a boxed error, recovers
# + unboxes it, consumes it (protocol method on one path, concrete field on the
# other), and must leave zero surviving heap allocations. The `try`/`rescue`
# lives in helper functions (the `assert_no_leaks` macro body cannot itself host
# a `try`/`rescue`), so the measured block is a pair of ordinary calls.
#
# Expected (under -Dmemory=Memory.Tracking):
#   * "msg=not found" / "status=404"  — both accessor forms render correctly
#   * a final summary line with 0 assertion failures (ARC balanced: no leak).

@code Z9351
pub error HttpError {
  status :: i64 = 0
}

pub struct Probe {
  pub fn rescued_message() -> String {
    try {
      raise %HttpError{status: 404, message: "not found"}
    } rescue {
      e :: HttpError -> Error.message(e)
    }
  }

  pub fn rescued_status() -> String {
    try {
      raise %HttpError{status: 404, message: "not found"}
    } rescue {
      e :: HttpError -> Integer.to_string(e.status)
    }
  }
}

pub struct Test.RescueBindingArc {
  use Zest.Case

  test("concrete-typed rescue binding is ARC-balanced") {
    case("unboxed binding supports protocol method and field access") {
      assert_no_leaks {
        message = Probe.rescued_message()
        IO.puts("msg=" <> message)
        status = Probe.rescued_status()
        IO.puts("status=" <> status)
        assert(message == "not found")
        assert(status == "404")
      }
    }
  }
}

fn main(_args :: [String]) -> u8 {
  Test.RescueBindingArc.run()
  failures = :zig.Zest.summary()
  if failures == 0 {
    0
  } else {
    1
  }
}
