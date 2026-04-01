defmodule System do
  def arg_count() :: i64 do
    :zig.arg_count()
  end

  def arg_at(index :: i64) :: String do
    :zig.arg_at(index)
  end

  def get_env(name :: String) :: String do
    :zig.get_env(name)
  end

  def get_build_opt(name :: String) :: String do
    :zig.get_build_opt(name)
  end
end
