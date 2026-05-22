# Phase 2.d acceptance (intentional NEGATIVE): `raise` is unrecoverable
# (Phase 2.a/2.b). It routes through the crash printer and `_exit`s the
# process WITHOUT stack unwinding, so scheduled `defer`/`errdefer`
# cleanup deliberately does NOT run on the raise/panic/contract abort
# path. This is correct and intentional — defers run only on the
# value-return control flow (normal return + the `?` Error early-return).
#
# The `defer IO.puts("should-not-print")` here must NEVER fire: the
# process aborts non-zero with the unified Zap crash report
# (`** (runtime_error) kaboom` + a symbolized backtrace) and
# "should-not-print" is absent from stdout.

pub struct RaiseNoDefer {
  pub fn boom() -> Nil {
    defer IO.puts("should-not-print")
    raise "kaboom"
  }
}

fn main(_args :: [String]) -> u8 {
  RaiseNoDefer.boom()
  0
}
