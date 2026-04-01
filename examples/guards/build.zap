defmodule Guards.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :guards ->
        %Zap.Manifest{
          name: "guards",
          version: "0.1.0",
          kind: :bin,
          root: "Guards.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'guards'")
    end
  end
end
