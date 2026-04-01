# Environment variable access
#
# System.get_env/1 reads environment variables at runtime.
# Returns an empty string if the variable is not set.
#
# Run with:
#   APP_NAME=demo APP_PORT=8080 zap run env_config

defmodule EnvConfig do
  def main(_args :: [String]) :: String do
    IO.puts("App name: " <> System.get_env("APP_NAME"))
    IO.puts("Port: " <> System.get_env("APP_PORT"))

    case System.get_env("DEBUG") do
      "" ->
        IO.puts("Debug mode: off")
      val ->
        IO.puts("Debug mode: " <> val)
    end
  end
end
