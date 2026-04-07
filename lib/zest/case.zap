pub module Zest.Case {
  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Case
    }
  }

  pub macro describe(name :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(body)
    }
  }

  pub macro test(name :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(body)
      IO.print_str("\x1b[1;32m.\x1b[0m")
    }
  }

  pub fn assert(value :: Bool) -> String {
    case value {
      true -> "."
      false -> panic("assertion failed")
    }
  }

  pub fn reject(value :: Bool) -> String {
    case value {
      false -> "."
      true -> panic("rejection failed")
    }
  }
}
