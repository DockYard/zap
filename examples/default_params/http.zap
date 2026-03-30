# Default parameter values
#
# Trailing parameters can have defaults. The compiler generates
# wrapper functions for each valid shorter arity.

defmodule Http do
  def request(url :: String, method :: String = "GET", _timeout :: i64 = 30) :: String do
    method <> " " <> url
  end
end
