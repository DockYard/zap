defmodule Types.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :types ->
        %Zap.Manifest{
          name: "types",
          version: "0.1.0",
          kind: :bin,
          root: "Types.main/0",
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'types'")
    end
  end
end
