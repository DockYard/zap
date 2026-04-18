pub module Zap.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :test ->
        %Zap.Manifest{
          name: "zap_test",
          version: "0.1.0",
          kind: :bin,
          root: "Test.TestRunner.main/1",
          deps: [{:zap_stdlib, {:path, "lib"}}]
        }
      :doc ->
        %Zap.Manifest{
          name: "zap_stdlib",
          version: "0.1.0",
          kind: :doc,
          source_url: "https://github.com/DockYard/zap",
          landing_page: "README.md",
          deps: [{:zap_stdlib, {:path, "lib"}}]
        }
      _ ->
        panic("Unknown target: use 'test' or 'doc'")
    }
  }
}
