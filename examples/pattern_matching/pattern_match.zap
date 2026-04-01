defmodule PatternMatch do
  def describe(_ :: Atom) :: String do
    "HEY YO!"
  end

  def describe(0 :: i64) :: String do
    "zero"
  end

  def describe(:ok :: Atom) :: String do
    "success"
  end

  def describe(:error :: Atom) :: String do
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
