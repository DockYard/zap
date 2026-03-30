defmodule Deps.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :deps ->
        %Zap.Manifest{name: "deps", version: "0.1.0", kind: :bin, root: "App.main/0", deps: [{:math_lib, {:path, "deps/math_lib"}}]}
      _ ->
        panic("Unknown target: use 'deps'")
    end
  end
end
