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
    }
  }
}
