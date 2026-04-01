defmodule EnvConfig.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :env_config ->
        %Zap.Manifest{
          name: "env_config",
          version: "0.1.0",
          kind: :bin,
          root: "EnvConfig.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'env_config'")
    end
  end
end
