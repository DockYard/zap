pub struct TuringMachine.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :test ->
        %Zap.Manifest{
          name: "turing_machine_test",
          version: "0.1.0",
          kind: :bin,
          root: &TestRunner.main/1,
          paths: ["*_test.zap", "turing_machine.zap"]
        }
      _ ->
        %Zap.Manifest{
          name: "turing_machine",
          version: "0.1.0",
          kind: :bin,
          root: &TuringMachine.main/1,
          paths: ["./turing_machine.zap"],
          optimize: :release_fast
        }
    }
  }
}
