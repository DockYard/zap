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

  # Short-circuit boolean: and expands to case
  pub macro and(left :: Expr, right :: Expr) -> Expr {
    quote {
      case unquote(left) {
        false -> false
        _ -> unquote(right)
      }
    }
  }

  # Short-circuit boolean: or expands to case
  pub macro or(left :: Expr, right :: Expr) -> Expr {
    quote {
      case unquote(left) {
        false -> unquote(right)
        _ -> unquote(left)
      }
    }
  }

  # Pipe operator: x |> f(y) → f(x, y)
  # Injects left as the first argument of the right-hand call.
  pub macro |>(left :: Expr, right :: Expr) -> Expr {
    name = elem(right, 0)
    meta = elem(right, 1)
    args = elem(right, 2)
    new_args = prepend(args, left)
    tuple(name, meta, new_args)
  }
}
