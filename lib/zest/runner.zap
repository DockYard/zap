pub module Zest.Runner {
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
