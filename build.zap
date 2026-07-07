pub struct Zap.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :test ->
        %Zap.Manifest{
          name: "zap_test",
          version: "0.1.0",
          kind: :bin,
          root: &TestRunner.main/1,
          paths: ["test/**/*_test.zap"],
          deps: [%Zap.Dep{name: "zap_stdlib", path: "lib"}],
          optimize: :debug,
          pipeline: %Zap.Build.Pipeline{
            steps: [%Zap.Build.Step{compile: %Zap.Build.Compile{}}, %Zap.Build.Step{run: %Zap.Build.Run{forward_args: true}}]
          }
        }
      :test_concurrency ->
        %Zap.Manifest{
          name: "zap_test_concurrency",
          version: "0.1.0",
          kind: :bin,
          root: &TestConcurrency.TestRunner.main/1,
          paths: ["test_concurrency/**/*_test.zap"],
          deps: [%Zap.Dep{name: "zap_stdlib", path: "lib"}],
          optimize: :debug,
          runtime_concurrency: true,
          pipeline: %Zap.Build.Pipeline{
            steps: [%Zap.Build.Step{compile: %Zap.Build.Compile{}}, %Zap.Build.Step{run: %Zap.Build.Run{forward_args: true}}]
          }
        }
      :doc ->
        %Zap.Manifest{
          name: "zap_docs",
          version: "0.1.0",
          kind: :bin,
          root: &Zap.Doc.Runner.main/1,
          paths: ["tools/**/*.zap"],
          source_url: "https://github.com/DockYard/zap",
          landing_page: "README.md",
          deps: [%Zap.Dep{name: "zap_stdlib", path: "lib"}]
        }
      _ ->
        panic("Unknown target: use 'test', 'test_concurrency', or 'doc'")
    }
  }
}
