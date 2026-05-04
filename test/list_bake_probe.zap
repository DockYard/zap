@doc = """
  Coverage for compile-time list baking through `quote { ... unquote(list) ... }`.

  Bakes runtime accessor functions for several list shapes:
  literal `[String]`, for-comprehension identity, for-comprehension
  transform, reflection-driven, and the `Zap.Doc.Builder`-shape
  pipeline (`Path.glob` -> `list_flatten` -> `source_graph_structs`
  -> `struct_info`). Tests in `test/list_bake_test.zap` then exercise
  every accessor (`List.head`, `List.length`, `List.contains?`,
  `Enum.any?`) so a divergence between accessors surfaces as a
  focused failure.
  """

pub struct ListBakeProbe {
  pub macro __using__(_opts :: Expr) -> Expr {
    baked = ["Atom", "Stringable"]

    # Build the same shape via a for-comprehension to compare against
    # the literal-list baking. Each element is also a literal string,
    # so the only thing that differs is the list-of-strings ctor path.
    from_for = for name <- ["Atom", "Stringable"] {
      name
    }

    # And via a for-comprehension that does a transformation (mirrors
    # the Zap.Doc.Builder shape that drives names out of reflection
    # results).
    from_for_transform = for name <- ["Atom", "Stringable"] {
      name <> ""
    }

    # Now drive from real reflection results to surface the shape the
    # Zap.Doc.Builder actually produces. Each ref → struct_info → :name.
    refs = source_graph_structs("lib/atom.zap")
    from_reflection = for ref <- refs {
      map_get(struct_info(ref), :name, "?")
    }

    # Replicate the Zap.Doc.Builder shape exactly: nested
    # list_flattens + multi-step ref resolution.
    glob_patterns = ["lib/atom.zap"]
    source_paths = list_flatten(for pattern <- glob_patterns {
      Path.glob(pattern)
    })
    struct_refs = list_flatten(for path <- source_paths {
      source_graph_structs(path)
    })
    from_builder_shape = for ref <- struct_refs {
      map_get(struct_info(ref), :name, "?")
    }

    # Bisect step 1: just Path.glob + list_flatten, no reflection.
    just_glob_paths = list_flatten(for pattern <- glob_patterns {
      Path.glob(pattern)
    })
    just_glob_count = list_length(just_glob_paths)

    # Bisect step 2: list_flatten over reflection results (no name extraction).
    flat_refs = list_flatten(for path <- just_glob_paths {
      source_graph_structs(path)
    })
    flat_refs_count = list_length(flat_refs)

    # Bisect step 3: walk flat_refs into names.
    flat_names = for ref <- flat_refs {
      map_get(struct_info(ref), :name, "?")
    }
    flat_names_count = list_length(flat_names)
    flat_names_first = list_at(flat_names, 0)

    quote {
      pub fn baked_list() -> [String] {
        unquote(baked)
      }

      pub fn baked_list_from_for() -> [String] {
        unquote(from_for)
      }

      pub fn baked_list_from_for_transform() -> [String] {
        unquote(from_for_transform)
      }

      pub fn baked_list_from_reflection() -> [String] {
        unquote(from_reflection)
      }

      pub fn baked_list_from_builder_shape() -> [String] {
        unquote(from_builder_shape)
      }

      pub fn baked_just_glob_count() -> i64 {
        unquote(just_glob_count)
      }

      pub fn baked_flat_refs_count() -> i64 {
        unquote(flat_refs_count)
      }

      pub fn baked_flat_names_count() -> i64 {
        unquote(flat_names_count)
      }

      pub fn baked_flat_names_first() -> String {
        unquote(flat_names_first)
      }
    }
  }
}
