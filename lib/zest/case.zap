pub module Zest.Case {
  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Case
    }
  }

  pub macro describe(_name :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(body)
    }
  }

  pub macro test(_name :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(body)
      IO.print_str(".")
    }
  }

  pub fn assert(value :: Bool) -> String {
    case value {
      true -> "."
      false -> panic("assertion failed")
    }
  }

  pub fn assert(value :: Bool, message :: String) -> String {
    case value {
      true -> "."
      false -> panic(message)
    }
  }

  pub fn reject(value :: Bool) -> String {
    case value {
      false -> "."
      true -> panic("rejection failed: expected false, got true")
    }
  }

  pub fn reject(value :: Bool, message :: String) -> String {
    case value {
      false -> "."
      true -> panic(message)
    }
  }
}
