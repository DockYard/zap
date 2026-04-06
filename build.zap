pub module Zap.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :test ->
        %Zap.Manifest{
          name: "zap_test",
          version: "0.1.0",
          kind: :bin,
          root: "Test.TestRunner.main/1",
          paths: ["test/**/*.zap", "lib/zest.zap"],
          deps: [{:zap_stdlib, {:path, "lib"}}]
        }
      _ ->
        panic("Unknown target: use 'test'")
    }
  }
}
