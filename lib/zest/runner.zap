pub module Zest.Runner {
  @moduledoc = """
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
    """

  @doc = """
    Imports `Zest.Runner` into the calling module.

    Called automatically when you write `use Zest.Runner`.
    """

  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Runner
    }
  }

  @doc = """
    Parses `--seed` and `--timeout` from CLI arguments and applies
    them to the test tracker. If `--seed <integer>` is present,
    sets the seed explicitly for reproducible ordering. Otherwise
    the tracker generates a seed from the system clock.

    If `--timeout <milliseconds>` is present, sets a per-test
    timeout. Tests exceeding the timeout are marked as failed
    with a yellow "T" indicator.

    Call this before running any tests to ensure the seed and
    timeout are set.
    """

  pub fn configure() -> Atom {
    parse_cli_args(0, System.arg_count())
  end

  @doc = """
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
    """

  pub fn run() -> String {
    :zig.TestTracker.summary()
    "done"
  }

  @doc = """
    Recursively scans CLI arguments for `--seed <value>` and
    `--timeout <milliseconds>`, applying each to the test tracker.
    """

  pub fn parse_cli_args(index :: i64, count :: i64) -> Atom {
    if index >= count {
      :ok
    } else {
      if System.arg_at(index) == "--seed" {
        if index + 1 < count {
          :zig.TestTracker.set_seed(Integer.parse(System.arg_at(index + 1)))
          parse_cli_args(index + 2, count)
        } else {
          :ok
        }
      } else {
        if System.arg_at(index) == "--timeout" {
          if index + 1 < count {
            :zig.TestTracker.set_timeout(Integer.parse(System.arg_at(index + 1)))
            parse_cli_args(index + 2, count)
          } else {
            :ok
          }
        } else {
          parse_cli_args(index + 1, count)
        }
      }
    }
  end
}
