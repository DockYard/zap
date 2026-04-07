pub module Zest.Case {
  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Case
      import Zest.Runtime
    }
  }

  pub macro describe(name :: Expr, body :: Expr) -> Expr {
    quote {
      Zest.Runtime.begin_describe(unquote(name))
      unquote(body)
      Zest.Runtime.end_describe()
    }
  }

  pub macro test(name :: Expr, body :: Expr) -> Expr {
    quote {
      Zest.Runtime.begin_test()
      unquote(body)
      Zest.Runtime.end_test(unquote(name))
    }
  }

  # Assertions — record failure without killing the process

  pub fn assert(value :: Bool) -> String {
    case value {
      true -> "."
      false -> Zest.Runtime.fail("assertion failed")
    }
  }

  pub fn reject(value :: Bool) -> String {
    case value {
      false -> "."
      true -> Zest.Runtime.fail("rejection failed: expected false, got true")
    }
  }
}
