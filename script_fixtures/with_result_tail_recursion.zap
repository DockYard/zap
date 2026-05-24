# Tail-call preservation under `with` Result propagation.
#
# `count_down/2` is self-recursive in tail position through a `with`
# chain: `with Ok(next) <- step(n)` unwraps the `Ok` and the
# recursive `count_down(next, acc + 1)` sits in tail position inside
# the success body. With ERT recording emitted as a guarded
# out-of-line call (not inline in the hot return path), the
# self-tail-call is still rewritten to `tail_call` and the deep
# recursion runs in O(1) stack.
#
# 2_000_000 iterations would blow a non-TCO stack; under TCO it
# returns cleanly.
#
# Expected output:
#
#     2000000

pub struct Deep {
  pub fn step(n :: i64) -> Result(i64, String) {
    case n > 0 {
      true -> Result(i64, String).Ok(n - 1)
      false -> Result(i64, String).Error("done")
    }
  }

  pub fn count_down(n :: i64, acc :: i64) -> Result(i64, String) {
    case n > 0 {
      true -> {
        with Result.Ok(next) <- Deep.step(n) {
          Deep.count_down(next, acc + 1)
        } else {
          Result.Error(reason) -> Result(i64, String).Error(reason)
        }
      }
      false -> Result(i64, String).Ok(acc)
    }
  }
}

fn main(_args :: [String]) -> u8 {
  case Deep.count_down(2000000, 0) {
    Result.Ok(total) -> IO.puts(Integer.to_string(total))
    Result.Error(reason) -> IO.puts(reason)
  }
  0
}
