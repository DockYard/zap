defmodule CaseExpr.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :case_expr ->
        %Zap.Manifest{
          name: "case_expr",
          version: "0.1.0",
          kind: :bin,
          root: "CaseExpr.main/0",
          paths: ["./*.zap"]
        }
      _ ->
        panic("Unknown target: use 'case_expr'")
    end
  end
end
