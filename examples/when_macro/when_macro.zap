defmodule Guards do
  defmacro when_positive(value :: i64, result :: String) :: String | nil do
    quote do
      if unquote(value) > 0 do
        unquote(result)
      else
        nil
      end
    end
  end

  def check(n :: i64) :: String | nil do
    when_positive(n, "yes")
  end
end

defmodule WhenMacro do
  def main() :: String do
    Guards.check(10)!
    |> IO.puts()
  end
end
