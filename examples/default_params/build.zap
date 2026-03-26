defmodule DefaultParams.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :default_params ->
        %Zap.Manifest{
          name: "default_params",
          version: "0.1.0",
          kind: :bin,
          root: "DefaultParams.main/0",
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'default_params'")
    end
  end
end
