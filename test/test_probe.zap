@doc = """
  Compile-time probe used by `test/reflection_test.zap`.

  The `__using__` macro reflects on `ReflectionSubject` at compile time
  and bakes the reflected values into runtime accessor functions so that
  Zest can assert on them with plain string equality.
  """

pub struct TestProbe {
  @requires = [:reflect_source]

  pub macro __using__(_opts :: Expr) -> Expr {
    _ignore = _opts
    _funcs = struct_functions(ReflectionSubject)
    _macros = struct_macros(ReflectionSubject)
    _add_docs = for _f <- _funcs, map_get(_f, :name, "") == "add" {
      map_get(_f, :doc, "MISSING")
    }
    _multiply_docs = for _f <- _funcs, map_get(_f, :name, "") == "multiply" {
      map_get(_f, :doc, "MISSING")
    }
    _no_doc_docs = for _f <- _funcs, map_get(_f, :name, "") == "no_doc" {
      map_get(_f, :doc, "MISSING")
    }
    _twice_docs = for _m <- _macros, map_get(_m, :name, "") == "twice" {
      map_get(_m, :doc, "MISSING")
    }
    _func_count = list_length(_funcs)
    _macro_count = list_length(_macros)

    _add_source_files = for _f <- _funcs, map_get(_f, :name, "") == "add" {
      map_get(_f, :source_file, "MISSING")
    }
    _add_source_lines = for _f <- _funcs, map_get(_f, :name, "") == "add" {
      map_get(_f, :source_line, 0)
    }
    _twice_source_lines = for _m <- _macros, map_get(_m, :name, "") == "twice" {
      map_get(_m, :source_line, 0)
    }

    _add_signatures = for _f <- _funcs, map_get(_f, :name, "") == "add" {
      list_at(map_get(_f, :signatures, []), 0)
    }
    _twice_signatures = for _m <- _macros, map_get(_m, :name, "") == "twice" {
      list_at(map_get(_m, :signatures, []), 0)
    }

    # Reference ReflectionProtocol by name so the file-graph discovery
    # picks up `test/reflection_protocol.zap` even though it does not
    # match the `*_test.zap` build glob.
    _proto_marker = ReflectionProtocol
    _union_marker = ReflectionUnion
    _protocol_refs = source_graph_protocols("test/reflection_protocol.zap")
    _protocol_count = list_length(_protocol_refs)
    _proto_info = struct_info(list_at(_protocol_refs, 0))
    _proto_name = map_get(_proto_info, :name, "MISSING")

    _union_refs = source_graph_unions("test/reflection_union.zap")
    _union_count = list_length(_union_refs)
    _union_info = struct_info(list_at(_union_refs, 0))
    _union_name = map_get(_union_info, :name, "MISSING")

    # Verify the source-graph impls intrinsic returns a list shape even
    # when no impls are declared in the path. A separate test (once a
    # working impl fixture lands) will cover the populated case.
    _impl_entries = source_graph_impls("test/no_impls_here.zap")
    _impl_count = list_length(_impl_entries)

    _info = struct_info(ReflectionSubject)
    _info_name = map_get(_info, :name, "MISSING")
    _info_source = map_get(_info, :source_file, "MISSING")
    _info_doc = map_get(_info, :doc, "MISSING")
    _info_private = map_get(_info, :is_private, true)

    quote {
      pub fn add_doc() -> String {
        unquote(list_at(_add_docs, 0))
      }

      pub fn multiply_doc() -> String {
        unquote(list_at(_multiply_docs, 0))
      }

      pub fn no_doc_doc() -> String {
        unquote(list_at(_no_doc_docs, 0))
      }

      pub fn twice_doc() -> String {
        unquote(list_at(_twice_docs, 0))
      }

      pub fn function_count() -> i64 {
        unquote(_func_count)
      }

      pub fn macro_count() -> i64 {
        unquote(_macro_count)
      }

      pub fn subject_name() -> String {
        unquote(_info_name)
      }

      pub fn subject_source_file() -> String {
        unquote(_info_source)
      }

      pub fn subject_doc() -> String {
        unquote(_info_doc)
      }

      pub fn subject_is_private() -> Bool {
        unquote(_info_private)
      }

      pub fn add_source_file() -> String {
        unquote(list_at(_add_source_files, 0))
      }

      pub fn add_source_line() -> i64 {
        unquote(list_at(_add_source_lines, 0))
      }

      pub fn twice_source_line() -> i64 {
        unquote(list_at(_twice_source_lines, 0))
      }

      pub fn add_signature() -> String {
        unquote(list_at(_add_signatures, 0))
      }

      pub fn twice_signature() -> String {
        unquote(list_at(_twice_signatures, 0))
      }

      pub fn protocol_count() -> i64 {
        unquote(_protocol_count)
      }

      pub fn first_protocol_name() -> String {
        unquote(_proto_name)
      }

      pub fn union_count() -> i64 {
        unquote(_union_count)
      }

      pub fn first_union_name() -> String {
        unquote(_union_name)
      }

      pub fn impl_count() -> i64 {
        unquote(_impl_count)
      }
    }
  }
}
