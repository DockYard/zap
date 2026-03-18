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

def main() do
  check({:ok, "hello"})
  |> IO.puts()

  check({:error, "oops"})
  |> IO.puts()

  check(:something)
  |> IO.puts()
end
