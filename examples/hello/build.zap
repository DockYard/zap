pub struct Hello.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :hello ->
        %Zap.Manifest{
          name: "hello",
          version: "0.1.0",
          kind: :bin,
          root: "Hello.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'hello'")
    }
  }
}
