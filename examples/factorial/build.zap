defmodule Factorial.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :factorial ->
        %Zap.Manifest{
          name: "factorial",
          version: "0.1.0",
          kind: :bin,
          root: "Factorial.main/0",
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'factorial'")
    end
  end
end
