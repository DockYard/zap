@doc = """
  Compile-time access to source-level declarations.

  Source graph functions are intended for macros and other compile-time
  code that need to inspect declarations from known source paths.
  """

pub struct SourceGraph {
  @requires = [:reflect_source]

  @doc = """
    Returns struct references declared in the exact source paths provided.

    Each returned reference can be unquoted into generated code as a
    qualified struct name. Pass a string path or a list of string paths.
    """

  pub macro structs(paths :: Expr) -> Expr {
    quote {
      source_graph_structs(unquote(paths))
    }
  }

  @doc = """
    Returns protocol references declared in the exact source paths
    provided. Each ref carries the protocol's qualified name in the
    same `__aliases__` AST shape as `structs/1` results. Combine with
    `Struct.info/1` to retrieve protocol-level metadata.
    """

  pub macro protocols(paths :: Expr) -> Expr {
    quote {
      source_graph_protocols(unquote(paths))
    }
  }

  @doc = """
    Returns union references declared in the exact source paths
    provided. Top-level dotted unions (e.g. `pub union IO.Mode`) keep
    their fully qualified name; nested unions declared inside a struct
    appear with their local name here — qualify them with the parent
    struct yourself when rendering.
    """

  pub macro unions(paths :: Expr) -> Expr {
    quote {
      source_graph_unions(unquote(paths))
    }
  }

  @doc = """
    Returns public protocol-impl entries declared in the supplied
    source paths. Each entry is a compile-time map with `:protocol`
    (qualified name), `:target` (qualified type name), `:source_file`,
    and `:is_private`. Doc generation reads this list to render the
    per-type "Implements" row.
    """

  pub macro impls(paths :: Expr) -> Expr {
    quote {
      source_graph_impls(unquote(paths))
    }
  }
}
