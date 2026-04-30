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
}
