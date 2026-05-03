pub struct Zap.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :test ->
        %Zap.Manifest{
          name: "zap_test",
          version: "0.1.0",
          kind: :bin,
          root: "TestRunner.main/1",
          paths: ["test/**/*_test.zap"],
          deps: [{:zap_stdlib, {:path, "lib"}}]
        }
      :doc ->
        %Zap.Manifest{
          name: "zap_docs",
          version: "0.1.0",
          kind: :bin,
          root: "Zap.DocsRunner.main/1",
          paths: ["lib/**/*.zap"],
          source_url: "https://github.com/DockYard/zap",
          landing_page: "README.md",
          deps: [{:zap_stdlib, {:path, "lib"}}]
        }
      _ ->
        panic("Unknown target: use 'test' or 'doc'")
    }
  }
}
