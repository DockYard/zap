defmodule DoubleMacro.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :double_macro ->
        %Zap.Manifest{
          name: "double_macro",
          version: "0.1.0",
          kind: :bin,
          root: "DoubleMacro.main/0",
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'double_macro'")
    end
  end
end
