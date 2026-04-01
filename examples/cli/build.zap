defmodule Cli.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :cli ->
        %Zap.Manifest{
          name: "cli",
          version: "0.1.0",
          kind: :bin,
          root: "Cli.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'cli'")
    end
  end
end
