defmodule Pipes.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :pipes ->
        %Zap.Manifest{
          name: "pipes",
          version: "0.1.0",
          kind: :bin,
          root: "Pipes.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'pipes'")
    end
  end
end
