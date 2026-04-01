defmodule Hello.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :hello ->
        %Zap.Manifest{
          name: "hello",
          version: "0.1.0",
          kind: :bin,
          root: "Hello.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'hello'")
    end
  end
end
