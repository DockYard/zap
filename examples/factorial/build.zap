defmodule Factorial.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :factorial ->
        %Zap.Manifest{
          name: "factorial",
          version: "0.1.0",
          kind: :bin,
          root: "Factorial.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'factorial'")
    end
  end
end
