# CLI input handling
#
# Run with: zap run cli.zap -- Alice Bob Charlie
#
# System.arg_count() returns the number of inputs (excluding the binary name)
# System.arg_at(n) returns the nth input as a String (0-indexed)

defmodule Cli do
  def greet_all(index :: i64, count :: i64) :: nil do
    if index < count do
      IO.puts("Hello, " <> System.arg_at(index) <> "!")
      greet_all(index + 1, count)
    end
  end
end

def main() do
  count = System.arg_count()

  if count == 0 do
    IO.puts("Usage: zap run cli.zap -- <name1> <name2> ...")
  else
    Cli.greet_all(0 :: i64, count)
  end
end
