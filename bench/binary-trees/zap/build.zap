pub struct BinaryTrees.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :binary_trees ->
        %Zap.Manifest{
          name: "binary_trees",
          version: "0.1.0",
          kind: :bin,
          root: "BinaryTrees.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'binary_trees'")
    }
  }
}
