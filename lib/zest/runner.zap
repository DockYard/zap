pub module Zest.Runner {
  @moduledoc = """
    Finalizes test execution and prints the summary report.

    Delegates to `:zig.TestTracker.summary()` which prints an
    ExUnit-style summary with test count, assertion count, and
    failure count, then exits with a non-zero code if any tests
    failed.

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
    Prints the test summary with counts and exits with a
    failure code if any tests failed.

    Call this as the last line of the test runner's `main`
    function. It invokes `:zig.TestTracker.summary()` which
    outputs the final report to stdout.

    ## Examples

        pub fn main(_args :: [String]) -> String {
          Test.MyTest.run()
          Zest.Runner.run()
        }
    """

  pub fn run() -> String {
    :zig.TestTracker.summary()
    "done"
  }
}
