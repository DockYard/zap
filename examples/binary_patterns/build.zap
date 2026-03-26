defmodule BinaryPatterns.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :binary_patterns ->
        %Zap.Manifest{
          name: "binary_patterns",
          version: "0.1.0",
          kind: :bin,
          root: "BinaryPatterns.main/0",
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'binary_patterns'")
    end
  end
end
