pub module Zest.Runner {
  # Zest.Runner discovers and runs test modules.
  #
  # Usage:
  #   pub module Test.TestRunner {
  #     use Zest.Runner
  #
  #     pub fn main(_args :: [String]) -> String {
  #       Zest.Runner.run_all([
  #         Test.HelloWorldTest.run(),
  #         Test.ArithmeticTest.run()
  #       ])
  #     }
  #   }
  #
  # Output (default dot format):
  #   Running tests...
  #   ..........
  #   22 tests, 22 passed, 0 failed

  pub fn run_all(results :: [String]) -> String {
    IO.puts("Running tests...")
    print_results(results)
    "done"
  }

  fn print_results([] :: [String]) -> String {
    ""
  }

  fn print_results([h | t] :: [String]) -> String {
    IO.puts(h)
    print_results(t)
  }
}
