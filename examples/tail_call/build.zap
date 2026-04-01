pub module TailCall.Builder {
  pub fn manifest(env :: Zap.Env) :: Zap.Manifest {
    case env.target {
      :tail_call ->
        %Zap.Manifest{
          name: "tail_call",
          version: "0.1.0",
          kind: :bin,
          root: "TailCall.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'tail_call'")
    }
  }
}
