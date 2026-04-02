pub module Kernel {
  pub fn inspect(_value :: i64) -> i64 {
    :zig.inspect(_value)
  }

  pub fn inspect(_value :: f64) -> f64 {
    :zig.inspect(_value)
  }

  pub fn inspect(_value :: String) -> String {
    :zig.inspect(_value)
  }

  pub fn inspect(_value :: Bool) -> Bool {
    :zig.inspect(_value)
  }

  pub macro if(condition :: Expr, then_body :: Expr) -> Nil {
    quote {
      case unquote(condition) {
        true -> unquote(then_body)
        false -> nil
      }
    }
  }

  pub macro if(condition :: Expr, then_body :: Expr, else_body :: Expr) -> Nil {
    quote {
      case unquote(condition) {
        true -> unquote(then_body)
        false -> unquote(else_body)
      }
    }
  }

  pub macro unless(condition :: Expr, body :: Expr) -> Nil {
    quote {
      if not unquote(condition) {
        unquote(body)
      }
    }
  }
}
