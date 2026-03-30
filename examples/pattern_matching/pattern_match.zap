defmodule PatternMatch do
  def describe(_) :: String do
    "HEY YO!"
  end

  def describe(0 :: i64) :: String do
    "zero"
  end

  def describe(:ok) :: String do
    "success"
  end

  def describe(:error) :: String do
    "failure"
  end

  def describe(n :: i64) :: String do
    if n > 0 do
      "positive"
    else
      "negative"
    end
  end
end
