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
    Parses `--seed` from CLI arguments and applies it to the
    test tracker. If `--seed <integer>` is present, sets the
    seed explicitly for reproducible ordering. Otherwise the
    tracker generates a seed from the system clock.

    Call this before running any tests to ensure the seed is
    set for deterministic ordering.
    """

  pub fn configure() -> Atom {
    parse_seed_arg(0, System.arg_count())
  }

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
    sets the test tracker seed when found.
    """

  pub fn parse_seed_arg(index :: i64, count :: i64) -> Atom {
    if index >= count {
      :ok
    } else {
      if System.arg_at(index) == "--seed" {
        if index + 1 < count {
          :zig.TestTracker.set_seed(Integer.parse(System.arg_at(index + 1)))
          :ok
        } else {
          :ok
        }
      } else {
        parse_seed_arg(index + 1, count)
      }
    }
  }
}
