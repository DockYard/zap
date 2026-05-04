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
      }
    }

    _protocol_summaries = for _ref <- _protocol_refs {
      %{
        name: map_get(struct_info(_ref), :name, ""),
        doc: map_get(struct_info(_ref), :doc, ""),
        source_file: map_get(struct_info(_ref), :source_file, ""),
        is_private: map_get(struct_info(_ref), :is_private, false),
      }
    }

    _union_summaries = for _ref <- _union_refs {
      %{
        name: map_get(struct_info(_ref), :name, ""),
        doc: map_get(struct_info(_ref), :doc, ""),
        source_file: map_get(struct_info(_ref), :source_file, ""),
        is_private: map_get(struct_info(_ref), :is_private, false),
      }
    }

    # Flat list of every public function across every reflected
    # struct, with the owning module qualified-name attached so the
    # walker can filter per-page. The per-clause typed signatures are
    # rendered to HTML at compile time and stored as a single
    # `:signatures_html` String — this avoids round-tripping a
    # `[String]` value through the `Term`-valued map slot, which the
    # runtime extraction path doesn't currently support.
    _function_summaries = list_flatten(for _ref <- _struct_refs {
      for _f <- struct_functions(_ref) {
        %{
          module: map_get(struct_info(_ref), :name, ""),
          name: map_get(_f, :name, ""),
          arity: map_get(_f, :arity, 0),
          doc: map_get(_f, :doc, ""),
          source_file: map_get(_f, :source_file, ""),
          source_line: map_get(_f, :source_line, 0),
          signatures_joined: string_concat_list(for _sig <- map_get(_f, :signatures, []) {
            _sig <> "\n"
          }),
        }
      }
    })

    _macro_summaries = list_flatten(for _ref <- _struct_refs {
      for _m <- struct_macros(_ref) {
        %{
          module: map_get(struct_info(_ref), :name, ""),
          name: map_get(_m, :name, ""),
          arity: map_get(_m, :arity, 0),
          doc: map_get(_m, :doc, ""),
          source_file: map_get(_m, :source_file, ""),
          source_line: map_get(_m, :source_line, 0),
          signatures_joined: string_concat_list(for _sig <- map_get(_m, :signatures, []) {
            _sig <> "\n"
          }),
        }
      }
    })

    _impl_summaries = list_flatten(for _path <- _source_paths {
      for _impl <- source_graph_impls(_path) {
        %{
          proto_name: map_get(_impl, :protocol, ""),
          target: map_get(_impl, :target, ""),
          # Bool value forces the map's value type to `Term` so it
          # composes with the other Term-valued summary lists in the
          # walker without requiring per-list type-narrowing.
          is_private: map_get(_impl, :is_private, false),
        }
      }
    })

    _variant_summaries = list_flatten(for _ref <- _union_refs {
      for _v <- union_variants(_ref) {
        %{
          module: map_get(struct_info(_ref), :name, ""),
          name: map_get(_v, :name, ""),
          signature: map_get(_v, :signature, ""),
          # Pin the value type to `Term` so the list composes with the
          # other Term-valued manifests; arity is unused for variants
          # but its presence keeps the inference stable.
          arity: 0,
        }
      }
    })

    _required_function_summaries = list_flatten(for _ref <- _protocol_refs {
      for _f <- protocol_required_functions(_ref) {
        %{
          module: map_get(struct_info(_ref), :name, ""),
          name: map_get(_f, :name, ""),
          signature: map_get(_f, :signature, ""),
          arity: 0,
        }
      }
    })

    # Embed the static stylesheet and theme/search JS at compile time
    # so the runtime walker can drop them next to the generated HTML
    # without any filesystem awareness of the original asset locations.
    # Authors who need to override these can set their own
    # `style.css` / `app.js` after `write_docs_to` writes the defaults.
    _doc_css = read_file("assets/style.css")
    _doc_js = read_file("assets/app.js")

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
        unquote(if list_length(_struct_summaries) > 0 { _struct_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      pub fn manifest_protocol_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(_protocol_summaries) > 0 { _protocol_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      pub fn manifest_union_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(_union_summaries) > 0 { _union_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      @doc = "Flat list of every public function across reflected modules, each with `:module`, `:name`, `:arity`, `:doc`."
      pub fn manifest_function_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(_function_summaries) > 0 { _function_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      @doc = "Flat list of every public macro across reflected modules, same shape as `manifest_function_summaries`."
      pub fn manifest_macro_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(_macro_summaries) > 0 { _macro_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      @doc = "Flat list of every protocol-impl declared across reflected modules, each with `:proto_name` and `:target` qualified names."
      pub fn manifest_impl_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(_impl_summaries) > 0 { _impl_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      @doc = "Flat list of every union variant across reflected modules, each with `:module`, `:name`, `:signature`."
      pub fn manifest_variant_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(_variant_summaries) > 0 { _variant_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      @doc = "Flat list of every protocol's required functions across reflected modules, each with `:module`, `:name`, `:signature`."
      pub fn manifest_required_function_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(_required_function_summaries) > 0 { _required_function_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      pub fn render_first_struct_html() -> String {
        Zap.Doc.render_summary_page(List.head(manifest_struct_summaries()), :struct, "Zap", "0.0.0", "", manifest_structs(), manifest_protocols(), manifest_unions(), manifest_function_summaries(), manifest_macro_summaries(), manifest_impl_summaries(), manifest_variant_summaries(), manifest_required_function_summaries())
      }

      @doc = """
        Render every reflected module to `<out_dir>/<name>.html` and
        write `style.css` + `app.js` alongside. `project_name`,
        `project_version`, and `source_url` populate the topbar,
        title, and per-function `[Source]` links. Pass an empty
        string for `source_url` to suppress source links.
        """
      pub fn write_docs_to(out_dir :: String, project_name :: String, project_version :: String, source_url :: String) -> i64 {
        _ = File.mkdir(out_dir)
        _ = File.write(out_dir <> "/style.css", unquote(_doc_css))
        _ = File.write(out_dir <> "/app.js", unquote(_doc_js))
        Zap.Doc.write_pages_to(out_dir, project_name, project_version, source_url, manifest_struct_summaries(), manifest_protocol_summaries(), manifest_union_summaries(), manifest_function_summaries(), manifest_macro_summaries(), manifest_impl_summaries(), manifest_variant_summaries(), manifest_required_function_summaries())
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
