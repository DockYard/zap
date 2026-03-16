const std = @import("std");

// Standard library module sources.
// These are the canonical Zap definitions for IO, Kernel, etc.
// The lib/ directory contains the same sources for editor tooling.

pub const lib_io =
    \\defmodule IO do
    \\  def puts(message :: String) do
    \\    :zig.println(message)
    \\  end
    \\end
    \\
;

pub const lib_kernel =
    \\defmodule Kernel do
    \\  def inspect(value) do
    \\    :zig.inspect(value)
    \\  end
    \\
    \\  defmacro if(condition, then_body) do
    \\    quote do
    \\      case unquote(condition) do
    \\        true ->
    \\          unquote(then_body)
    \\        false ->
    \\          nil
    \\      end
    \\    end
    \\  end
    \\
    \\  defmacro if(condition, then_body, else_body) do
    \\    quote do
    \\      case unquote(condition) do
    \\        true ->
    \\          unquote(then_body)
    \\        false ->
    \\          unquote(else_body)
    \\      end
    \\    end
    \\  end
    \\
    \\  defmacro unless(condition, body) do
    \\    quote do
    \\      if not unquote(condition) do
    \\        unquote(body)
    \\      end
    \\    end
    \\  end
    \\end
    \\
;

/// Prepend standard library source to user source for unified parsing.
pub fn prependStdlib(allocator: std.mem.Allocator, user_source: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ lib_kernel, lib_io, user_source });
}
