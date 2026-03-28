defmodule CaseExpr do
  def check(result) :: String do
    case result do
      {:ok, v} ->
        v
      {:error, e} ->
        e
      _ ->
        "unknown"
    end
  end

  def main() :: String do
    CaseExpr.check({:ok, "hello"})
    |> IO.puts()

    CaseExpr.check({:error, "oops"})
    |> IO.puts()

    CaseExpr.check(:something)
    |> IO.puts()
  end
end
