# Phase 4.a acceptance (ERT display / #201): a cross-function `raise` that
# propagates THREE frames deep and reaches the top unrescued must show the
# error-return trace — the c -> b -> a propagation chain — in the crash
# report, not just the abort terminus.
#
# `Chain.c` raises `ChainError`; `Chain.b` calls `c`; `Chain.a` calls `b`.
# Each is a `raises ChainError` function, so the raise propagates via the
# `error.ZapRaise` cross-function control signal and the boxed error rides
# the runtime side-channel. `main` neither rescues nor re-propagates, so the
# compiler routes the unhandled raise to `Kernel.abort_recoverable_raise`,
# which produces the Phase 2 crash report.
#
# BEFORE Phase 4.a the report showed only the abort site, because the
# backtrace was captured AFTER `a`, `b`, `c` had already returned
# `error.ZapRaise`:
#
#   ** (chain_error) born in c
#     Kernel.abort_recoverable_raise/0
#     script.main
#
# AFTER Phase 4.a the error-return trace is captured at the RAISE ORIGIN
# (inside `Kernel.recoverable_raise`, while the chain is live on the stack)
# and rendered as a dedicated section:
#
#   ** (chain_error) born in c
#     Kernel.abort_recoverable_raise/0
#     script.main
#   error return trace:
#     Chain.c at phase_4a_ert_chain_display.zap:<line>
#     Chain.b at phase_4a_ert_chain_display.zap:<line>
#     Chain.a at phase_4a_ert_chain_display.zap:<line>
#     script.main at phase_4a_ert_chain_display.zap:<line>
#
# This fixture aborts non-zero; it never reaches the `0` return.

@code Z3010
pub error ChainError {
  detail :: String = "boom"

  pub fn message(self :: ChainError) -> String {
    self.detail
  }
}

pub struct Chain {
  pub fn c(n :: i64) -> i64 raises ChainError {
    case n > 0 {
      true -> n
      false -> raise %ChainError{detail: "born in c"}
    }
  }

  pub fn b(n :: i64) -> i64 raises ChainError {
    Chain.c(n)
  }

  pub fn a(n :: i64) -> i64 raises ChainError {
    Chain.b(n)
  }
}

fn main(_args :: [String]) -> u8 {
  result = Chain.a(0)
  IO.puts(Integer.to_string(result))
  0
}
