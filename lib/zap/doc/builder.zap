@doc = """
  Compile-time entry point for the Zap-side documentation generator.

  `use Zap.Doc.Builder, paths: ["lib/**/*.zap"]` reflects on the
  structs, protocols, and unions reachable from the supplied path
  patterns and bakes manifest functions returning the qualified
  module names. A runtime caller can iterate those manifests, feed
  each name back through `Struct.info/1` and `Struct.functions/1`,
  and drive `Zap.Doc` page rendering. Mirrors the `Zest.Runner`
  pattern: reflection at expansion time, plain Zap function bodies
  at runtime.
  """

pub struct Zap.Doc.Builder {
  @doc = """
    Reflect on the supplied source paths (a single string or a list
    of strings) and emit manifest functions returning the qualified
    names of every public struct, protocol, and union declared in
    any matching file.
    """

  pub macro __using__(opts :: Expr) -> Expr {
    _options = options(opts)
    _patterns = patterns(_options)
    _source_paths = list_flatten(for _pattern <- _patterns {
      Path.glob(_pattern)
    })
    _struct_refs = list_flatten(for _path <- _source_paths {
      source_graph_structs(_path)
    })
    _protocol_refs = list_flatten(for _path <- _source_paths {
      source_graph_protocols(_path)
    })
    _union_refs = list_flatten(for _path <- _source_paths {
      source_graph_unions(_path)
    })
    _struct_names = for _ref <- _struct_refs {
      map_get(struct_info(_ref), :name, "")
    }
    _protocol_names = for _ref <- _protocol_refs {
      map_get(struct_info(_ref), :name, "")
    }
    _union_names = for _ref <- _union_refs {
      map_get(struct_info(_ref), :name, "")
    }

    _struct_summaries = for _ref <- _struct_refs {
      %{
        name: map_get(struct_info(_ref), :name, ""),
        doc: map_get(struct_info(_ref), :doc, ""),
        source_file: map_get(struct_info(_ref), :source_file, ""),
        is_private: map_get(struct_info(_ref), :is_private, false),
        functions: struct_functions(_ref),
        macros: struct_macros(_ref),
      }
    }

    _protocol_summaries = for _ref <- _protocol_refs {
      %{
        name: map_get(struct_info(_ref), :name, ""),
        doc: map_get(struct_info(_ref), :doc, ""),
        source_file: map_get(struct_info(_ref), :source_file, ""),
        is_private: map_get(struct_info(_ref), :is_private, false),
        required_functions: protocol_required_functions(_ref),
      }
    }

    _union_summaries = for _ref <- _union_refs {
      %{
        name: map_get(struct_info(_ref), :name, ""),
        doc: map_get(struct_info(_ref), :doc, ""),
        source_file: map_get(struct_info(_ref), :source_file, ""),
        is_private: map_get(struct_info(_ref), :is_private, false),
        variants: union_variants(_ref),
      }
    }

    quote {
      pub fn manifest_structs() -> [String] {
        unquote(_struct_names)
      }

      pub fn manifest_protocols() -> [String] {
        unquote(_protocol_names)
      }

      pub fn manifest_unions() -> [String] {
        unquote(_union_names)
      }

      pub fn manifest_struct_summaries() -> [%{Atom => Term}] {
        unquote(_struct_summaries)
      }

      pub fn manifest_protocol_summaries() -> [%{Atom => Term}] {
        unquote(_protocol_summaries)
      }

      pub fn manifest_union_summaries() -> [%{Atom => Term}] {
        unquote(_union_summaries)
      }

      pub fn render_first_struct_html() -> String {
        _summary = List.head(manifest_struct_summaries())
        _name = Map.get(_summary, :name, "")
        _doc = Map.get(_summary, :doc, "")
        _content = "<h1>" <> Zap.Doc.escape_html(_name) <> "</h1>\n<p>" <> Zap.Doc.escape_html(_doc) <> "</p>\n"
        _sidebar = Zap.Doc.sidebar(manifest_structs(), manifest_protocols(), manifest_unions(), _name, "")
        Zap.Doc.struct_page("Zap", "0.0.0", _name, "", "", _sidebar, _content, "")
      }
    }
  }

  @doc = """
    Normalize the option list passed to `use Zap.Doc.Builder`. `nil`
    and `[]` collapse to the empty list; a single keyword pair gets
    wrapped in a one-element list; an existing list passes through.
    Same shape `Zest.Runner.options/1` accepts.
    """

  pub macro options(opts :: Expr) -> Expr {
    if opts == nil {
      []
    } else {
      if opts == [] {
        []
      } else {
        if list_length(opts) == 0 {
          [opts]
        } else {
          opts
        }
      }
    }
  }

  @doc = """
    Pull the `:paths` (or `:path`) glob list out of the use options.
    A single string is wrapped into a one-element list; a list of
    strings passes through. When neither key is present, fall back
    to `lib/**/*.zap`.
    """

  pub macro patterns(options :: Expr) -> Expr {
    _groups = for _option <- options {
      option_patterns(_option)
    }
    _patterns = list_flatten(_groups)
    if _patterns == [] {
      ["lib/**/*.zap"]
    } else {
      _patterns
    }
  }

  pub macro option_patterns(option :: Expr) -> Expr {
    if elem(option, 0) == :paths {
      pattern_values(elem(option, 1))
    } else {
      if elem(option, 0) == :path {
        pattern_values(elem(option, 1))
      } else {
        []
      }
    }
  }

  pub macro pattern_values(value :: Expr) -> Expr {
    if value == [] {
      []
    } else {
      if list_length(value) == 0 {
        [value]
      } else {
        value
      }
    }
  }
}
