pub module Kernel {
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

  pub macro and(left :: Expr, right :: Expr) -> Expr {
    quote {
      case unquote(left) {
        false -> false
        _ -> unquote(right)
      }
    }
  }

  pub macro or(left :: Expr, right :: Expr) -> Expr {
    quote {
      case unquote(left) {
        false -> unquote(right)
        _ -> unquote(left)
      }
    }
  }

  pub macro fn(decl :: Expr) -> Expr {
    quote { unquote(decl) }
  }

  pub macro struct(decl :: Expr) -> Expr {
    quote { unquote(decl) }
  }

  pub macro union(decl :: Expr) -> Expr {
    quote { unquote(decl) }
  }

  pub macro |>(left :: Expr, right :: Expr) -> Expr {
    _name = elem(right, 0)
    _meta = elem(right, 1)
    _args = elem(right, 2)
    _new_args = prepend(_args, left)
    tuple(_name, _meta, _new_args)
  }
}
