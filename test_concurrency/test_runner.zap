@compile_after_glob = "test_concurrency/**/*_test.zap"
pub struct TestConcurrency.TestRunner {
  use Zest.Runner, pattern: "test_concurrency/**/*_test.zap"
}
