# CLI argument pattern matching
#
# main(args) receives CLI arguments as a list of strings.
# Multi-clause dispatch matches on the argument list.
#
# Run with:
#   zap run cli.zap -- greet Alice
#   zap run cli.zap -- version
#   zap run cli.zap

defmodule Cli do
  def run(["greet", name]) do
    IO.puts("Hello, " <> name <> "!")
  end

  def run(["version"]) do
    IO.puts("zap-cli v0.1.0")
  end

  def run(_) do
    IO.puts("Usage:")
    IO.puts("  cli greet <name>")
    IO.puts("  cli version")
  end
end

def main(args) do
  Cli.run(args)
end
