pub module Kernel {
  pub fn inspect(value :: i64) :: i64 {
    :zig.inspect(value)
  }

  pub fn inspect(value :: f64) :: f64 {
    :zig.inspect(value)
  }

  pub fn inspect(value :: String) :: String {
    :zig.inspect(value)
  }

  pub fn inspect(value :: Bool) :: Bool {
    :zig.inspect(value)
  }

  pub macro if(condition :: Expr, then_body :: Expr) :: Nil {
    quote {
      case unquote(condition) {
        true -> unquote(then_body)
        false -> nil
      }
    }
  }

  pub macro if(condition :: Expr, then_body :: Expr, else_body :: Expr) :: Nil {
    quote {
      case unquote(condition) {
        true -> unquote(then_body)
        false -> unquote(else_body)
      }
    }
  }

  pub macro unless(condition :: Expr, body :: Expr) :: Nil {
    quote {
      if not unquote(condition) {
        unquote(body)
      }
    }
  }
}
