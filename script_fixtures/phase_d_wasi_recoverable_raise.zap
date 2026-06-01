# Phase D acceptance (WASI degrade): WASM has NO signal/exception model, so
# `RuntimeOs.installCrashHandlers` is a comptime no-op on wasm32-wasi
# (`caps.supports_signals = false`) and a HARDWARE fault would trap. But a
# RECOVERABLE `raise` that reaches the top unrescued does NOT go through the
# OS fault interceptor — it funnels through the portable crash sink
# (`crashReport` -> `emitCrashReportWithBacktrace`), which writes via the
# `runtime_os` console seam (`fd_write` on WASI). So the crash report STILL
# renders on WASI; only hardware-fault interception is lost.
#
# This fixture prints a line first (proving the WASI console-write seam works),
# then raises a string error that reaches `main` unrescued, which must produce
# the unified `** (RuntimeError) ...` crash report on stderr under
# `wasmtime`.
#
# Expected stdout:
#   phase-d wasi: before raise
# Expected stderr (default ZAP_BACKTRACE=short):
#   ** (RuntimeError) deliberate wasi raise
#     Boom.inner/0 at phase_d_wasi_recoverable_raise.zap:<line>
#     Boom.outer/0 at phase_d_wasi_recoverable_raise.zap:<line>
#     ...

pub struct Boom {
  pub fn inner() -> Never {
    raise "deliberate wasi raise"
  }

  pub fn outer() -> Never {
    Boom.inner()
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts("phase-d wasi: before raise")
  Boom.outer()
  0
}
