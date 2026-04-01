defmodule Fibonacci.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
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
    end
  end
end
