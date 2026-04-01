pub module Fibonacci.Builder {
  pub fn manifest(env :: Zap.Env) :: Zap.Manifest {
    case env.target {
      :fibonacci ->
        %Zap.Manifest{
          name: "fibonacci",
          version: "0.1.0",
          kind: :bin,
          root: "Fibonacci.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'fibonacci'")
    }
  }
}
