defmodule Multifile.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :multifile ->
        %Zap.Manifest{
          name: "multifile",
          version: "0.1.0",
          kind: :bin,
          root: "App.main/0",
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'multifile'")
    end
  end
end
