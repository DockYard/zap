defmodule Attributes.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :attributes ->
        %Zap.Manifest{
          name: "attributes",
          version: "0.1.0",
          kind: :bin,
          root: "Attributes.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'attributes'")
    end
  end
end
