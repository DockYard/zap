pub module Zest.Runner {
  # Zest.Runner executes test modules and reports results.
  #
  # Usage in test/test_runner.zap:
  #   pub module Test.TestRunner {
  #     use Zest.Runner
  #
  #     pub fn main(_args :: [String]) -> String {
  #       run([
  #         Test.MyTest.run(),
  #         Test.OtherTest.run()
  #       ])
  #     }
  #   }

  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Runner
    }
  }

  pub fn run() -> String {
    Zest.summary()
  }
}
