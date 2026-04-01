defmodule TailCall.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :tail_call ->
        %Zap.Manifest{
          name: "tail_call",
          version: "0.1.0",
          kind: :bin,
          root: "TailCall.main/1",
          paths: ["./*.zap"], deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      _ ->
        panic("Unknown target: use 'tail_call'")
    end
  end
end
