defmodule Config do
  @timeout :: i64 = 5000
  def timeout() :: i64 do
    @timeout
  end

  @max_retries :: i64 = 3
  def max_retries() :: i64 do
    @max_retries
  end

  @app_name :: String = "my_app"
  def app_name() :: String do
    @app_name
  end
end
