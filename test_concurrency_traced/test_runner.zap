@compile_after_glob = "test_concurrency_traced/**/*_test.zap"
pub struct TestConcurrencyTraced.TestRunner {
  use Zest.Runner, pattern: "test_concurrency_traced/**/*_test.zap"
}
