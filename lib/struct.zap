@doc = """
  Compile-time helpers for reflected struct declarations.

  Functions in this struct accept references returned by `SourceGraph`
  reflection APIs.
  """

pub struct Struct {
  @requires = [:reflect_source]

  @doc = """
    Returns the public functions declared on a reflected struct.

    Each result is a compile-time map with `:name`, `:arity`, and
    `:visibility` entries.
    """

  pub macro functions(struct_ref :: Expr) -> Expr {
    quote {
      struct_functions(unquote(struct_ref))
    }
  }

  @doc = """
    Returns true when a reflected struct exposes a public function with
    the given name and arity.
    """

  @requires = [:reflect_source]

  pub macro has_function?(struct_ref :: Expr, function_name :: Expr, function_arity :: Expr) -> Expr {
    _matches = for _function <- functions(struct_ref), map_get(_function, :name, "") == function_name and map_get(_function, :arity, -1) == function_arity {
      _function
    }

    list_length(_matches) > 0
  }
}
