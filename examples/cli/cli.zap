# CLI argument handling
#
# main(args) receives CLI arguments as a list of strings.
# Uses arg_count and arg_at to process arguments.
#
# Run with:
#   zap run cli

defmodule Cli do
  def main(_args :: [String]) :: String do
    IO.puts("Hello from CLI!")
    IO.puts("Arg count: " <> Integer.to_string(System.arg_count()))
  end
end
