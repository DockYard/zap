pub struct Types.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :types ->
        %Zap.Manifest{
          name: "types",
          version: "0.1.0",
          kind: :bin,
          root: "Types.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'types'")
    }
  }
}
