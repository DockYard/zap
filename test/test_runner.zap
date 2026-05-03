@compile_after_glob = "test/**/*_test.zap"

pub struct TestRunner {
  use Zest.Runner, pattern: "test/**/*_test.zap"
}
