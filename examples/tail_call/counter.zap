defmodule Counter do
  def countdown(0 :: i64) :: i64 do
    0
  end

  def countdown(n :: i64) :: i64 do
    countdown(n - 1)
  end
end
