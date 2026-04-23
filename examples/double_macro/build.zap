pub struct DoubleMacro.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :double_macro ->
        %Zap.Manifest{
          name: "double_macro",
          version: "0.1.0",
          kind: :bin,
          root: "DoubleMacro.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'double_macro'")
    }
  }
}
