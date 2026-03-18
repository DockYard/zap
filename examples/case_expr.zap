defmodule CaseExample do
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
end

def main() do
  CaseExample.check({:ok, "hello"})
  |> IO.puts()

  CaseExample.check({:error, "oops"})
  |> IO.puts()

  CaseExample.check(:something)
  |> IO.puts()
end
