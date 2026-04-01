# String concatenation and function calls

defmodule Http do
  def get(url :: String) :: String do
    "GET " <> url
  end

  def post(url :: String) :: String do
    "POST " <> url
  end
end
