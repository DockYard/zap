pub module Zest.Runner {
  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Runner
    }
  }

  pub fn run() -> String {
    IO.puts("")
    "done"
  }
}
