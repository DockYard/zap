defmodule Pipes.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :pipes ->
        %Zap.Manifest{
          name: "pipes",
          version: "0.1.0",
          kind: :bin,
          root: "Pipes.main/0",
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'pipes'")
    end
  end
end
