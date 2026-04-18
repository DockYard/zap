# Zest.Runner

Finalizes test execution and prints the summary report.

Delegates to `:zig.TestTracker.summary()` which prints an
ExUnit-style summary with test count, assertion count, and
failure count, then exits with a non-zero code if any tests
failed.

Supports seed-based deterministic test ordering. Pass
`--seed <integer>` on the command line to reproduce a
specific test run. Without `--seed`, a random seed is
generated from the system clock.

## Examples

    pub module Test.TestRunner {
      use Zest.Runner

      pub fn main(_args :: [String]) -> String {
        Test.MyTest.run()
        Zest.Runner.run()
      }
    }

## Functions

### configure/0

```zap
pub fn configure() -> Atom
```

Parses `--seed` and `--timeout` from CLI arguments and applies
them to the test tracker. If `--seed <integer>` is present,
sets the seed explicitly for reproducible ordering. Otherwise
the tracker generates a seed from the system clock.

If `--timeout <milliseconds>` is present, sets a per-test
timeout. Tests exceeding the timeout are marked as failed
with a yellow "T" indicator.

Call this before running any tests to ensure the seed and
timeout are set.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/runner.zap#L53)

---

### run/0

```zap
pub fn run() -> String
```

Prints the test summary with counts and exits with a
failure code if any tests failed.

Call this as the last line of the test runner's `main`
function. It invokes `:zig.TestTracker.summary()` which
outputs the final report to stdout, including the seed
used for test ordering.

## Examples

    pub fn main(_args :: [String]) -> String {
      Zest.Runner.configure()
      Test.MyTest.run()
      Zest.Runner.run()
    }

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/runner.zap#L75)

---

### parse_cli_args/2

```zap
pub fn parse_cli_args(index :: i64, count :: i64) -> Atom
```

Recursively scans CLI arguments for `--seed <value>` and
`--timeout <milliseconds>`, applying each to the test tracker.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/runner.zap#L85)

---

