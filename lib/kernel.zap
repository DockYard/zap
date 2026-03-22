defmodule Kernel do
  def inspect(value) do
    :zig.inspect(value)
  end

  defmacro if(condition, then_body) do
    quote do
      case unquote(condition) do
        true ->
          unquote(then_body)
        false ->
          nil
      end
    end
  end

  defmacro if(condition, then_body, else_body) do
    quote do
      case unquote(condition) do
        true ->
          unquote(then_body)
        false ->
          unquote(else_body)
      end
    end
  end

  defmacro unless(condition, body) do
    quote do
      if not unquote(condition) do
        unquote(body)
      end
    end
  end
end
