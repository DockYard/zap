@compile_after_glob = "*_test.zap"

pub struct TestRunner {
  use Zest.Runner, pattern: "*_test.zap"
}
