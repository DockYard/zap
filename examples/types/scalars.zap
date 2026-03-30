defmodule Scalars do
  def int() :: i64 do
    42
  end

  def negative() :: i64 do
    -7
  end

  def float() :: f64 do
    3.14
  end

  def string() :: String do
    "hello"
  end

  def boolean_true() :: Bool do
    true
  end

  def boolean_false() :: Bool do
    false
  end

  def hex() :: i64 do
    0xFF
  end
end
