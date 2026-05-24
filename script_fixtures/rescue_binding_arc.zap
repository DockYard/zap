# Gap A acceptance — ARC balance of a concrete-typed rescue binding.
#
# When a rescue arm filters on a concrete error type (`e :: MyError`), the
# binding `e` is the UNBOXED concrete value (Elixir's `rescue e in [MyError]`
# semantics): the runtime type-discrimination confirms the boxed `Error` IS a
# `MyError`, then `protocol_box_unbox` recovers a BORROWED view of the concrete
# struct. The box still owns the heap cell and deep-releases it at the rescue
# landing pad's scope exit; the unboxed binding takes neither a retain nor a
# scope-exit release, so there is no double-free of the inner's `message`
# String / `cause` fields.
#
# This fixture stresses that path under the DEFAULT ARC manager (which performs
# real retain/release plus use-after-free / double-free canary checks): it
# recovers + unboxes a fresh boxed error many times, consuming it through both
# a protocol method (`Error.message(e)`) and a concrete field (`e.status`). An
# ARC imbalance on the unbox/borrow path (a double-free of the inner, or a
# leaked box) would trip the canary or corrupt the heap within the loop. A
# clean run prints each accessor's value and exits 0.
#
# NOTE: a `zap test`-style `assert_no_leaks { ... }` under
# `-Dmemory=Memory.Tracking` is the stronger check, but it is currently BLOCKED
# by a SEPARATE, PRE-EXISTING defect: the Memory.Tracking manager segfaults when
# freeing a recovered protocol-box's inner error value (reproduces on the
# unmodified `test/fixtures/try_rescue/discriminate_struct_bind.zap` against the
# parent commit — i.e. independent of this rescue-binding fix). That box-inner-
# free-under-Tracking crash is tracked as a follow-up; it is orthogonal to the
# rescue-binding representation fix this fixture covers.

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

  pub fn stress(remaining :: i64) -> i64 {
    case remaining {
      0 -> 0
      _ -> {
        message = Probe.rescued_message()
        status = Probe.rescued_status()
        if message == "not found" and status == "404" {
          Probe.stress(remaining - 1)
        } else {
          -1
        }
      }
    }
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts("msg=" <> Probe.rescued_message())
  IO.puts("status=" <> Probe.rescued_status())
  result = Probe.stress(500)
  if result == 0 {
    IO.puts("arc-balanced: 500 unbox/recover cycles clean")
    0
  } else {
    IO.puts("arc-balanced: FAILED")
    1
  }
}
