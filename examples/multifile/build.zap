pub module Multifile.Builder {
  pub fn manifest(env :: Zap.Env) :: Zap.Manifest {
    case env.target {
      :multifile ->
        %Zap.Manifest{
          name: "multifile",
          version: "0.1.0",
          kind: :bin,
          root: "App.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'multifile'")
    }
  }
}
