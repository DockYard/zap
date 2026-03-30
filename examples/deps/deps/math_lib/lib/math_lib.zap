defmodule MathLib do
  def add(a :: i64, b :: i64) :: i64 do
    MathLib.Helpers.internal_add(a, b)
  end
end
