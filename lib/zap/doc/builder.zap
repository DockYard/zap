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
    normalized_options = options(opts)
    glob_patterns = patterns(normalized_options)
    source_paths = list_flatten(for pattern <- glob_patterns {
      Path.glob(pattern)
    })
    struct_refs = list_flatten(for path <- source_paths {
      source_graph_structs(path)
    })
    protocol_refs = list_flatten(for path <- source_paths {
      source_graph_protocols(path)
    })
    union_refs = list_flatten(for path <- source_paths {
      source_graph_unions(path)
    })
    struct_names = for ref <- struct_refs {
      map_get(struct_info(ref), :name, "")
    }
    protocol_names = for ref <- protocol_refs {
      map_get(struct_info(ref), :name, "")
    }
    union_names = for ref <- union_refs {
      map_get(struct_info(ref), :name, "")
    }

    struct_summaries = for ref <- struct_refs {
      %{
        name: map_get(struct_info(ref), :name, ""),
        doc: map_get(struct_info(ref), :doc, ""),
        source_file: map_get(struct_info(ref), :source_file, ""),
        is_private: map_get(struct_info(ref), :is_private, false),
      }
    }

    protocol_summaries = for ref <- protocol_refs {
      %{
        name: map_get(struct_info(ref), :name, ""),
        doc: map_get(struct_info(ref), :doc, ""),
        source_file: map_get(struct_info(ref), :source_file, ""),
        is_private: map_get(struct_info(ref), :is_private, false),
      }
    }

    union_summaries = for ref <- union_refs {
      %{
        name: map_get(struct_info(ref), :name, ""),
        doc: map_get(struct_info(ref), :doc, ""),
        source_file: map_get(struct_info(ref), :source_file, ""),
        is_private: map_get(struct_info(ref), :is_private, false),
      }
    }

    # Flat list of every public function across every reflected
    # struct, with the owning module qualified-name attached so the
    # walker can filter per-page. The per-clause typed signatures are
    # rendered to HTML at compile time and stored as a single
    # `:signatures_html` String — this avoids round-tripping a
    # `[String]` value through the `Term`-valued map slot, which the
    # runtime extraction path doesn't currently support.
    function_summaries = list_flatten(for ref <- struct_refs {
      for f <- struct_functions(ref) {
        %{
          module: map_get(struct_info(ref), :name, ""),
          name: map_get(f, :name, ""),
          arity: map_get(f, :arity, 0),
          doc: map_get(f, :doc, ""),
          source_file: map_get(f, :source_file, ""),
          source_line: map_get(f, :source_line, 0),
          signatures_joined: string_concat_list(for sig <- map_get(f, :signatures, []) {
            sig <> "\n"
          }),
        }
      }
    })

    macro_summaries = list_flatten(for ref <- struct_refs {
      for m <- struct_macros(ref) {
        %{
          module: map_get(struct_info(ref), :name, ""),
          name: map_get(m, :name, ""),
          arity: map_get(m, :arity, 0),
          doc: map_get(m, :doc, ""),
          source_file: map_get(m, :source_file, ""),
          source_line: map_get(m, :source_line, 0),
          signatures_joined: string_concat_list(for sig <- map_get(m, :signatures, []) {
            sig <> "\n"
          }),
        }
      }
    })

    impl_summaries = list_flatten(for path <- source_paths {
      for impl_decl <- source_graph_impls(path) {
        %{
          proto_name: map_get(impl_decl, :protocol, ""),
          target: map_get(impl_decl, :target, ""),
          # Bool value forces the map's value type to `Term` so it
          # composes with the other Term-valued summary lists in the
          # walker without requiring per-list type-narrowing.
          is_private: map_get(impl_decl, :is_private, false),
        }
      }
    })

    variant_summaries = list_flatten(for ref <- union_refs {
      for v <- union_variants(ref) {
        %{
          module: map_get(struct_info(ref), :name, ""),
          name: map_get(v, :name, ""),
          signature: map_get(v, :signature, ""),
          # Pin the value type to `Term` so the list composes with the
          # other Term-valued manifests; arity is unused for variants
          # but its presence keeps the inference stable.
          arity: 0,
        }
      }
    })

    required_function_summaries = list_flatten(for ref <- protocol_refs {
      for f <- protocol_required_functions(ref) {
        %{
          module: map_get(struct_info(ref), :name, ""),
          name: map_get(f, :name, ""),
          signature: map_get(f, :signature, ""),
          arity: 0,
        }
      }
    })

    # Embed the static stylesheet and theme/search JS at compile time
    # so the runtime walker can drop them next to the generated HTML
    # without any filesystem awareness of the original asset locations.
    # Authors who need to override these can set their own
    # `style.css` / `app.js` after `write_docs_to` writes the defaults.
    doc_css = read_file("assets/style.css")
    doc_js = read_file("assets/app.js")

    quote {
      pub fn manifest_structs() -> [String] {
        unquote(struct_names)
      }

      pub fn manifest_protocols() -> [String] {
        unquote(protocol_names)
      }

      pub fn manifest_unions() -> [String] {
        unquote(union_names)
      }

      pub fn manifest_struct_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(struct_summaries) > 0 { struct_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      pub fn manifest_protocol_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(protocol_summaries) > 0 { protocol_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      pub fn manifest_union_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(union_summaries) > 0 { union_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      @doc = "Flat list of every public function across reflected modules, each with `:module`, `:name`, `:arity`, `:doc`."
      pub fn manifest_function_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(function_summaries) > 0 { function_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      @doc = "Flat list of every public macro across reflected modules, same shape as `manifest_function_summaries`."
      pub fn manifest_macro_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(macro_summaries) > 0 { macro_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      @doc = "Flat list of every protocol-impl declared across reflected modules, each with `:proto_name` and `:target` qualified names."
      pub fn manifest_impl_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(impl_summaries) > 0 { impl_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      @doc = "Flat list of every union variant across reflected modules, each with `:module`, `:name`, `:signature`."
      pub fn manifest_variant_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(variant_summaries) > 0 { variant_summaries } else { quote { [] :: [%{Atom => Term}] } })
      }

      @doc = "Flat list of every protocol's required functions across reflected modules, each with `:module`, `:name`, `:signature`."
      pub fn manifest_required_function_summaries() -> [%{Atom => Term}] {
        unquote(if list_length(required_function_summaries) > 0 { required_function_summaries } else { quote { [] :: [%{Atom => Term}] } })
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
        write_docs_to(out_dir, project_name, project_version, source_url, "")
      }

      @doc = """
        Render every reflected module to `<out_dir>/<name>.html` and
        write `style.css` + `app.js` alongside, plus an `index.html`
        whose main column is the rendered `landing_md` markdown — pass
        the contents of the project's `README.md` to drop the README
        onto the docs landing page the way the legacy generator did
        when its manifest set `landing_page: \"README.md\"`. An empty
        `landing_md` falls back to the auto-generated struct-card grid.
        """
      pub fn write_docs_to(out_dir :: String, project_name :: String, project_version :: String, source_url :: String, landing_md :: String) -> i64 {
        _ = File.mkdir(out_dir)
        _ = File.write(out_dir <> "/style.css", unquote(doc_css))
        # `app.js` is written inside `Zap.Doc.write_pages_to` after the
        # search index has been rendered, so the bundled JS lands with
        # its `ZAP_SEARCH_DATA` corpus already inlined at the top.
        Zap.Doc.write_pages_to(out_dir, project_name, project_version, source_url, landing_md, manifest_struct_summaries(), manifest_protocol_summaries(), manifest_union_summaries(), manifest_function_summaries(), manifest_macro_summaries(), manifest_impl_summaries(), manifest_variant_summaries(), manifest_required_function_summaries(), unquote(doc_js))
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
    groups = for option <- options {
      option_patterns(option)
    }
    flattened_patterns = list_flatten(groups)
    if flattened_patterns == [] {
      ["lib/**/*.zap"]
    } else {
      flattened_patterns
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
