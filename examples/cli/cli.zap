# CLI argument pattern matching
#
# main(args) receives CLI arguments as a list of strings.
# Multi-clause dispatch matches on the argument list.
#
# Run with:
#   zap run cli -- greet Alice
#   zap run cli -- version
#   zap run cli

defmodule Cli do
  def main(["greet", name]) :: String do
    IO.puts("Hello, " <> name <> "!")
  end

  def main(["version"]) :: String do
    IO.puts("zap-cli v0.1.0")
  end

  def main(_) :: String do
    IO.puts("Usage:")
    IO.puts("  cli greet <name>")
    IO.puts("  cli version")
  end
end
