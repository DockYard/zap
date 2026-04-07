pub module Zest.Runner {
  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Runner
      import Zest.Runtime
    }
  }

  pub fn run() -> String {
    Zest.Runtime.summary()
  }
}
