defmodule Guards do
  def check(n :: i64) :: String if n > 0 do
    "positive"
  end

  def check(_ :: i64) :: String do
    "not positive"
  end
end
