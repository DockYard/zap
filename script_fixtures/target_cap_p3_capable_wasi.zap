# Phase 3 acceptance — the OVER-GATING guard. A program using ONLY the stdlib
# APIs that are genuinely available on wasm32-wasi must cross-build for wasi and
# RUN under wasmtime. This is the regression anchor for "did NOT over-gate":
#
#   * File I/O  — wasi HAS `:filesystem` via preopens (NOT gated; gating it
#                 would be the over-gating bug). Exercised with write/read/exists.
#   * String    — target-agnostic (NOT gated).
#   * List      — target-agnostic (NOT gated).
#   * IO.puts   — fd-based stdout, present on every target (NOT gated; only the
#                 raw-mode terminal-input cluster is gated, not all of IO).
#
# If any of these were wrongly gated on wasi, this fixture would FAIL TO COMPILE
# for wasm32-wasi — turning the over-gating bug into a loud failure.
#
# Expected: cross-builds for wasm32-wasi and prints "p3-capable-wasi-ok"
# under `wasmtime --dir=.`.

fn main(args :: [String]) -> u8 {
  # String + List (target-agnostic, ungated).
  parts = ["p3", "capable", "wasi"]
  part_count = List.length(parts)
  joined = String.join(parts, "-")
  joined_len = String.length(joined)

  # File I/O on the wasi preopen — :filesystem is present on wasi, so these
  # are NOT gated and must compile + run.
  File.write("p3_capable_wasi.tmp", joined)
  read_back = File.read("p3_capable_wasi.tmp")
  exists = File.exists?("p3_capable_wasi.tmp")
  File.rm("p3_capable_wasi.tmp")

  if exists and read_back == joined {
    IO.puts("p3-capable-wasi-ok")
  } else {
    IO.puts("p3-capable-wasi-FAILED")
  }
  0
}
