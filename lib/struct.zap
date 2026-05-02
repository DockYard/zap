@doc = """
  Compile-time helpers for reflected struct declarations.

  Functions in this struct accept references returned by `SourceGraph`
  reflection APIs.
  """

pub struct Struct {
  @doc = """
    Returns the public functions declared on a reflected struct.

    Each result is a compile-time map with `:name`, `:arity`,
    `:visibility`, and `:doc` entries. The `:doc` value is the
    function's `@doc` attribute string (heredoc indentation stripped),
    or an empty string when no `@doc` is attached.
    """

  pub macro functions(struct_ref :: Expr) -> Expr {
    quote {
      struct_functions(unquote(struct_ref))
    }
  }

  @doc = """
    Returns the public macros declared on a reflected struct, with the
    same map shape as `functions/1`. Language hooks like `__using__`
    and `__before_compile__` are excluded — they are not part of the
    public API surface.
    """

  pub macro macros(struct_ref :: Expr) -> Expr {
    quote {
      struct_macros(unquote(struct_ref))
    }
  }

  @doc = """
    Returns struct-level metadata for a reflected struct as a compile-time
    map: `:name`, `:source_file` (project-relative path), `:is_private`,
    and `:doc` (the struct's `@doc` attribute, heredoc-stripped, or
    empty when missing).
    """

  pub macro info(struct_ref :: Expr) -> Expr {
    quote {
      struct_info(unquote(struct_ref))
    }
  }

  @doc = """
    Returns the variants of a reflected union as a list of compile-time
    maps with `:name` and `:signature` (the rendered Zap-syntax form,
    `Variant` for bare variants and `Variant :: TypeExpr` for typed
    payloads).
    """

  pub macro union_variants(union_ref :: Expr) -> Expr {
    quote {
      union_variants(unquote(union_ref))
    }
  }

  @doc = """
    Returns the required functions a protocol declares as a list of
    compile-time maps with `:name` and `:signature`. Signatures use
    the same renderer the doc generator drives.
    """

  pub macro protocol_required_functions(protocol_ref :: Expr) -> Expr {
    quote {
      protocol_required_functions(unquote(protocol_ref))
    }
  }

  @doc = """
    Returns true when a reflected struct exposes a public function with
    the given name and arity.
    """

  pub macro has_function?(struct_ref :: Expr, function_name :: Expr, function_arity :: Expr) -> Expr {
    _matches = for _function <- functions(struct_ref), map_get(_function, :name, "") == function_name and map_get(_function, :arity, -1) == function_arity {
      _function
    }

    list_length(_matches) > 0
  }
}
