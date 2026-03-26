defmodule Fibonacci.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :fibonacci ->
        %Zap.Manifest{
          name: "fibonacci",
          version: "0.1.0",
          kind: :bin,
          root: "Fibonacci.main/0",
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'fibonacci'")
    end
  end
end
