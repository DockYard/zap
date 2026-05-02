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
    _add_docs = for _f <- _funcs, map_get(_f, :name, "") == "add" {
      map_get(_f, :doc, "MISSING")
    }
    _multiply_docs = for _f <- _funcs, map_get(_f, :name, "") == "multiply" {
      map_get(_f, :doc, "MISSING")
    }
    _no_doc_docs = for _f <- _funcs, map_get(_f, :name, "") == "no_doc" {
      map_get(_f, :doc, "MISSING")
    }

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
    }
  }
}
