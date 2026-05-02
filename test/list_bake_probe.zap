@doc = """
  Coverage for compile-time list baking through `quote { ... unquote(_list) ... }`.

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
  @requires = [:reflect_source, :read_file]

  pub macro __using__(_opts :: Expr) -> Expr {
    _baked = ["Atom", "Stringable"]

    # Build the same shape via a for-comprehension to compare against
    # the literal-list baking. Each element is also a literal string,
    # so the only thing that differs is the list-of-strings ctor path.
    _from_for = for _name <- ["Atom", "Stringable"] {
      _name
    }

    # And via a for-comprehension that does a transformation (mirrors
    # the Zap.Doc.Builder shape that drives names out of reflection
    # results).
    _from_for_transform = for _name <- ["Atom", "Stringable"] {
      _name <> ""
    }

    # Now drive from real reflection results to surface the shape the
    # Zap.Doc.Builder actually produces. Each ref → struct_info → :name.
    _refs = source_graph_structs("lib/atom.zap")
    _from_reflection = for _ref <- _refs {
      map_get(struct_info(_ref), :name, "?")
    }

    # Replicate the Zap.Doc.Builder shape exactly: nested
    # list_flattens + multi-step ref resolution.
    _patterns = ["lib/atom.zap"]
    _source_paths = list_flatten(for _pattern <- _patterns {
      Path.glob(_pattern)
    })
    _struct_refs = list_flatten(for _path <- _source_paths {
      source_graph_structs(_path)
    })
    _from_builder_shape = for _ref <- _struct_refs {
      map_get(struct_info(_ref), :name, "?")
    }

    # Bisect step 1: just Path.glob + list_flatten, no reflection.
    _just_glob_paths = list_flatten(for _pattern <- _patterns {
      Path.glob(_pattern)
    })
    _just_glob_count = list_length(_just_glob_paths)

    # Bisect step 2: list_flatten over reflection results (no name extraction).
    _flat_refs = list_flatten(for _path <- _just_glob_paths {
      source_graph_structs(_path)
    })
    _flat_refs_count = list_length(_flat_refs)

    # Bisect step 3: walk _flat_refs into names.
    _flat_names = for _ref <- _flat_refs {
      map_get(struct_info(_ref), :name, "?")
    }
    _flat_names_count = list_length(_flat_names)
    _flat_names_first = list_at(_flat_names, 0)

    quote {
      pub fn baked_list() -> [String] {
        unquote(_baked)
      }

      pub fn baked_list_from_for() -> [String] {
        unquote(_from_for)
      }

      pub fn baked_list_from_for_transform() -> [String] {
        unquote(_from_for_transform)
      }

      pub fn baked_list_from_reflection() -> [String] {
        unquote(_from_reflection)
      }

      pub fn baked_list_from_builder_shape() -> [String] {
        unquote(_from_builder_shape)
      }

      pub fn baked_just_glob_count() -> i64 {
        unquote(_just_glob_count)
      }

      pub fn baked_flat_refs_count() -> i64 {
        unquote(_flat_refs_count)
      }

      pub fn baked_flat_names_count() -> i64 {
        unquote(_flat_names_count)
      }

      pub fn baked_flat_names_first() -> String {
        unquote(_flat_names_first)
      }
    }
  }
}
