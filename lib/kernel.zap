defmodule Kernel do
  def inspect(value :: i64) :: i64 do
    :zig.inspect(value)
  end

  def inspect(value :: f64) :: f64 do
    :zig.inspect(value)
  end

  def inspect(value :: String) :: String do
    :zig.inspect(value)
  end

  def inspect(value :: Bool) :: Bool do
    :zig.inspect(value)
  end

  defmacro if(condition :: Expr, then_body :: Expr) :: Nil do
    quote do
      case unquote(condition) do
        true ->
          unquote(then_body)
        false ->
          nil
      end
    end
  end

  defmacro if(condition :: Expr, then_body :: Expr, else_body :: Expr) :: Nil do
    quote do
      case unquote(condition) do
        true ->
          unquote(then_body)
        false ->
          unquote(else_body)
      end
    end
  end

  defmacro unless(condition :: Expr, body :: Expr) :: Nil do
    quote do
      if not unquote(condition) do
        unquote(body)
      end
    end
  end
end
