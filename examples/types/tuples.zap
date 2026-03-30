defmodule Tuples do
  def pair() :: {i64, String} do
    {1, "one"}
  end

  def triple() :: {String, String, String} do
    {"a", "b", "c"}
  end

  def nested() :: {String, {i64, i64}} do
    {"point", {10, 20}}
  end

  def deep() :: {String, {String, {String, String}}} do
    {"root", {"branch", {"leaf1", "leaf2"}}}
  end
end
