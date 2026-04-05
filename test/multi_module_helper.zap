pub module Test.MultiModuleHelper {
  pub fn double(x :: i64) -> i64 {
    x + x
  }

  pub fn greet(name :: String) -> String {
    "Hello, " <> name <> "!"
  }
}
