defmodule WhenMacro.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :when_macro ->
        %Zap.Manifest{
          name: "when_macro",
          version: "0.1.0",
          kind: :bin,
          root: "WhenMacro.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'when_macro'")
    end
  end
end
