## Phase C (Domain F sleep edge) cross-target fixture.
##
## Exercises the Domain-F sleep edge migrated to the `runtime_os` seam:
## `Kernel.sleep(ms)` lowers to `RuntimeOs.sleepNanos` (posix `nanosleep`,
## windows `Sleep`, wasi `poll_oneoff` relative-timeout). A foreign-target
## run proves the per-OS sleep backend actually runs (not just links) — it
## returns and the program continues to completion.
##
## (The Domain-H entropy and Domain-F clock-read edges — `RuntimeOs.osEntropy`
## and `RuntimeOs.nowNanos` — are exercised internally by the `Zest` test
## framework's seed/timing on every `zap test` run; this fixture covers the
## directly-Zap-callable sleep edge end to end on a foreign target.)
##
## Expected stdout (exactly):
##
##     before-sleep
##     after-sleep: returned

fn main(_args :: [String]) -> u8 {
  IO.puts("before-sleep")
  sleep(1)
  IO.puts("after-sleep: returned")
  0
}
