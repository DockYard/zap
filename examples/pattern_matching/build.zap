defmodule PatternMatching.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :pattern_matching ->
        %Zap.Manifest{
          name: "pattern_matching",
          version: "0.1.0",
          kind: :bin,
          root: "PatternMatching.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'pattern_matching'")
    end
  end
end
