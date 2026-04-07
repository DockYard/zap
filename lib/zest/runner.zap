pub module Zest.Runner {
  @moduledoc = """
    Test runner for the Zest test framework.

    Provides the `run/0` function that finalizes test output.
    Use `use Zest.Runner` in your test runner module.

    ## Examples

        pub module Test.TestRunner {
          use Zest.Runner

          pub fn main(_args :: [String]) -> String {
            Test.MyTest.run()
            Zest.Runner.run()
          }
        }
    """
  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Runner
    }
  }

  @doc = """
    Finalizes the test run by printing a newline after the dot output.

    Call this as the last line of the test runner's `main` function.

    ## Examples

        pub fn main(_args :: [String]) -> String {
          Test.MyTest.run()
          Zest.Runner.run()
        }
    """
  pub fn run() -> String {
    IO.puts("")
    "done"
  }
}
