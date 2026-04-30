pub struct Struct {
  @structdoc = """
    Compile-time helpers for reflected struct declarations.

    Functions in this struct accept references returned by `SourceGraph`
    reflection APIs.
    """

  @requires = [:reflect_source]

  @fndoc = """
    Returns the public functions declared on a reflected struct.

    Each result is a compile-time map with `:name`, `:arity`, and
    `:visibility` entries.
    """

  pub macro functions(struct_ref :: Expr) -> Expr {
    quote {
      __zap_struct_functions__(unquote(struct_ref))
    }
  }

  @fndoc = """
    Returns true when a reflected struct exposes a public function with
    the given name and arity.
    """

  pub macro has_function?(struct_ref :: Expr, function_name :: Expr, function_arity :: Expr) -> Expr {
    _matches = for _function <- functions(struct_ref), __zap_map_get__(_function, :name, "") == function_name and __zap_map_get__(_function, :arity, -1) == function_arity {
      _function
    }

    __zap_list_len__(_matches) > 0
  }
}
