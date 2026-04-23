pub struct Deps.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :deps ->
        %Zap.Manifest{name: "deps", version: "0.1.0", kind: :bin, root: "App.main/1", deps: [{:zap_stdlib, {:path, "../../lib"}}, {:math_lib, {:path, "deps/math_lib"}}]}
      _ ->
        panic("Unknown target: use 'deps'")
    }
  }
}
