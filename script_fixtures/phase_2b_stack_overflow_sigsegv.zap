# Phase 2.b acceptance: a raw hardware fault (here, a SIGSEGV from
# unbounded non-tail recursion exhausting the stack) must be caught by
# the Zap signal handlers and produce the unified Zap crash report —
# `** (segmentation_fault) ...` plus a symbolized Zap backtrace from the
# faulting frame — instead of the process dying silently or with a bare
# OS signal.
#
# `Recurse.descend/1` calls itself and then adds to the result, so the
# call is NOT in tail position and the optimizer cannot turn it into a
# loop: each call consumes a real stack frame, so the stack overflows
# and the guard page fault delivers SIGSEGV.
#
# Expected (default ZAP_BACKTRACE=short):
#   ** (segmentation_fault) segmentation fault (invalid memory access)
#     Recurse.descend/1 at phase_2b_stack_overflow_sigsegv.zap:<line>
#     ... (repeated) ...
#
# This fixture aborts via signal; it never reaches the `0` return.

pub struct Recurse {
  pub fn descend(depth :: i64) -> i64 {
    1 + Recurse.descend(depth + 1)
  }
}

fn main(_args :: [String]) -> u8 {
  Recurse.descend(0)
  0
}
