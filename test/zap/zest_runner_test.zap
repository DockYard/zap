pub struct Zap.ZestRunnerTest {
  use Zest.Case
  import Zest.Runner

  describe("Zest.Runner options") {
    test("nil normalizes to an empty list") {
      assert(normalized_option_count(nil) == 0)
    }

    test("empty list stays empty") {
      assert(normalized_option_count([]) == 0)
    }

    test("keyword option list stays a list") {
      assert(normalized_option_count([{:pattern, "test/**/*_test.zap"}]) == 1)
    }

    test("single option is wrapped in a list") {
      assert(normalized_option_count({:pattern, "test/**/*_test.zap"}) == 1)
    }
  }

  @fndoc = """
    Returns the length of `Zest.Runner.options/1` for compile-time tests.
    """

  pub macro normalized_option_count(opts :: Expr) -> Expr {
    normalized = options(opts)
    count = __zap_list_len__(normalized)

    quote { unquote(count) }
  }
}
