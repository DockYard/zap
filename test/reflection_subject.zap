@doc = """
  Test fixture for compile-time reflection tests.

  Each function carries a distinctive `@doc` shape so the reflection
  tests can verify the doc-text retrieval path end to end.
  """

pub struct ReflectionSubject {
  @doc = "Adds two integers."
  pub fn add(a :: i64, b :: i64) -> i64 {
    a + b
  }

  @doc = """
    Multiplies two integers.

    The doc body is multi-line so the heredoc-stripping path is exercised.
    """
  pub fn multiply(a :: i64, b :: i64) -> i64 {
    a * b
  }

  pub fn no_doc(value :: i64) -> i64 {
    value
  }

  @doc = "Doubles its argument at compile time."
  pub macro twice(value :: Expr) -> Expr {
    quote {
      unquote(value) + unquote(value)
    }
  }
}
