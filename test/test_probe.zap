@doc = """
  Compile-time probe used by `test/reflection_test.zap`.

  The `__using__` macro reflects on `ReflectionSubject` at compile time
  and bakes the reflected values into runtime accessor functions so that
  Zest can assert on them with plain string equality.
  """

pub struct TestProbe {
  pub macro __using__(_opts :: Expr) -> Expr {
    funcs = struct_functions(ReflectionSubject)
    macros = struct_macros(ReflectionSubject)
    add_docs = for f <- funcs, map_get(f, :name, "") == "add" {
      map_get(f, :doc, "MISSING")
    }
    multiply_docs = for f <- funcs, map_get(f, :name, "") == "multiply" {
      map_get(f, :doc, "MISSING")
    }
    no_doc_docs = for f <- funcs, map_get(f, :name, "") == "no_doc" {
      map_get(f, :doc, "MISSING")
    }
    twice_docs = for m <- macros, map_get(m, :name, "") == "twice" {
      map_get(m, :doc, "MISSING")
    }
    func_count = list_length(funcs)
    macro_count_val = list_length(macros)

    add_source_files = for f <- funcs, map_get(f, :name, "") == "add" {
      map_get(f, :source_file, "MISSING")
    }
    add_source_lines = for f <- funcs, map_get(f, :name, "") == "add" {
      map_get(f, :source_line, 0)
    }
    twice_source_lines = for m <- macros, map_get(m, :name, "") == "twice" {
      map_get(m, :source_line, 0)
    }

    add_signatures = for f <- funcs, map_get(f, :name, "") == "add" {
      list_at(map_get(f, :signatures, []), 0)
    }
    twice_signatures = for m <- macros, map_get(m, :name, "") == "twice" {
      list_at(map_get(m, :signatures, []), 0)
    }

    # Reference ReflectionProtocol by name so the file-graph discovery
    # picks up `test/reflection_protocol.zap` even though it does not
    # match the `*_test.zap` build glob.
    _proto_marker = ReflectionProtocol
    _union_marker = ReflectionUnion
    protocol_refs = source_graph_protocols("test/reflection_protocol.zap")
    protocol_count_val = list_length(protocol_refs)
    proto_info = struct_info(list_at(protocol_refs, 0))
    proto_name = map_get(proto_info, :name, "MISSING")
    proto_required = protocol_required_functions(list_at(protocol_refs, 0))
    proto_required_count = list_length(proto_required)
    proto_required_signature = map_get(list_at(proto_required, 0), :signature, "MISSING")

    union_refs = source_graph_unions("test/reflection_union.zap")
    union_count_val = list_length(union_refs)
    union_info = struct_info(list_at(union_refs, 0))
    union_name = map_get(union_info, :name, "MISSING")
    union_variants_list = union_variants(list_at(union_refs, 0))
    union_variant_count_val = list_length(union_variants_list)
    first_variant_signature = map_get(list_at(union_variants_list, 0), :signature, "MISSING")
    last_variant_signature = map_get(list_at(union_variants_list, 2), :signature, "MISSING")

    # Verify the source-graph impls intrinsic returns a list shape even
    # when no impls are declared in the path. A separate test (once a
    # working impl fixture lands) will cover the populated case.
    impl_entries = source_graph_impls("test/no_impls_here.zap")
    impl_count_val = list_length(impl_entries)

    # Verify path-filter resolution works for stdlib paths.
    stdlib_lib_atom_refs = source_graph_structs("lib/atom.zap")
    stdlib_lib_atom_count = list_length(stdlib_lib_atom_refs)

    info = struct_info(ReflectionSubject)
    info_name = map_get(info, :name, "MISSING")
    info_source = map_get(info, :source_file, "MISSING")
    info_doc = map_get(info, :doc, "MISSING")
    info_private = map_get(info, :is_private, true)

    quote {
      pub fn add_doc() -> String {
        unquote(list_at(add_docs, 0))
      }

      pub fn multiply_doc() -> String {
        unquote(list_at(multiply_docs, 0))
      }

      pub fn no_doc_doc() -> String {
        unquote(list_at(no_doc_docs, 0))
      }

      pub fn twice_doc() -> String {
        unquote(list_at(twice_docs, 0))
      }

      pub fn function_count() -> i64 {
        unquote(func_count)
      }

      pub fn macro_count() -> i64 {
        unquote(macro_count_val)
      }

      pub fn subject_name() -> String {
        unquote(info_name)
      }

      pub fn subject_source_file() -> String {
        unquote(info_source)
      }

      pub fn subject_doc() -> String {
        unquote(info_doc)
      }

      pub fn subject_is_private() -> Bool {
        unquote(info_private)
      }

      pub fn add_source_file() -> String {
        unquote(list_at(add_source_files, 0))
      }

      pub fn add_source_line() -> i64 {
        unquote(list_at(add_source_lines, 0))
      }

      pub fn twice_source_line() -> i64 {
        unquote(list_at(twice_source_lines, 0))
      }

      pub fn add_signature() -> String {
        unquote(list_at(add_signatures, 0))
      }

      pub fn twice_signature() -> String {
        unquote(list_at(twice_signatures, 0))
      }

      pub fn protocol_count() -> i64 {
        unquote(protocol_count_val)
      }

      pub fn first_protocol_name() -> String {
        unquote(proto_name)
      }

      pub fn protocol_required_count() -> i64 {
        unquote(proto_required_count)
      }

      pub fn protocol_required_signature() -> String {
        unquote(proto_required_signature)
      }

      pub fn union_count() -> i64 {
        unquote(union_count_val)
      }

      pub fn first_union_name() -> String {
        unquote(union_name)
      }

      pub fn union_variant_count() -> i64 {
        unquote(union_variant_count_val)
      }

      pub fn union_variant_first_signature() -> String {
        unquote(first_variant_signature)
      }

      pub fn union_variant_last_signature() -> String {
        unquote(last_variant_signature)
      }

      pub fn impl_count() -> i64 {
        unquote(impl_count_val)
      }

      pub fn stdlib_lib_atom_count() -> i64 {
        unquote(stdlib_lib_atom_count)
      }
    }
  }
}
