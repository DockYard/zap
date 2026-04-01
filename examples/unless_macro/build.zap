defmodule UnlessMacro.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :unless_macro ->
        %Zap.Manifest{
          name: "unless_macro",
          version: "0.1.0",
          kind: :bin,
          root: "UnlessMacro.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'unless_macro'")
    end
  end
end
