const std = @import("std");

// Standard library module sources.
// These are the canonical Zap definitions for IO, Kernel, etc.
// The lib/ directory contains the same sources for editor tooling.

pub const lib_io =
    \\defmodule IO do
    \\  def puts(message :: String) :: String do
    \\    :zig.println(message)
    \\  end
    \\end
    \\
;

pub const lib_kernel =
    \\defmodule Kernel do
    \\  def inspect(value :: String) :: String do
    \\    :zig.inspect(value)
    \\  end
    \\
    \\  defmacro if(condition, then_body) :: Nil do
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
    \\  defmacro if(condition, then_body, else_body) :: Nil do
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
    \\  defmacro unless(condition, body) :: Nil do
    \\    quote do
    \\      if not unquote(condition) do
    \\        unquote(body)
    \\      end
    \\    end
    \\  end
    \\end
    \\
;

pub const lib_system =
    \\defmodule System do
    \\  def arg_count() :: i64 do
    \\    :zig.arg_count()
    \\  end
    \\
    \\  def arg_at(index :: i64) :: String do
    \\    :zig.arg_at(index)
    \\  end
    \\
    \\  def get_env(name :: String) :: String do
    \\    :zig.get_env(name)
    \\  end
    \\end
    \\
;

pub const lib_atom =
    \\defmodule Atom do
    \\  def to_string(atom :: Atom) :: String do
    \\    :zig.atom_name(atom)
    \\  end
    \\end
    \\
;

pub const lib_integer =
    \\defmodule Integer do
    \\  def to_string(value :: i64) :: String do
    \\    :zig.i64_to_string(value)
    \\  end
    \\end
    \\
;

pub const lib_float =
    \\defmodule Float do
    \\  def to_string(value :: f64) :: String do
    \\    :zig.f64_to_string(value)
    \\  end
    \\end
    \\
;

pub const lib_string =
    \\defmodule String do
    \\  def to_atom(name :: String) :: Atom do
    \\    :zig.to_atom(name)
    \\  end
    \\
    \\  def to_existing_atom(name :: String) :: Atom do
    \\    :zig.to_existing_atom(name)
    \\  end
    \\end
    \\
;

pub const lib_zap =
    \\defstruct Zap.Env do
    \\  target :: Atom
    \\  os :: Atom
    \\  arch :: Atom
    \\end
    \\
    \\defstruct Zap.Manifest do
    \\  name :: String
    \\  version :: String
    \\  kind :: Atom
    \\  root :: String = ""
    \\  asset_name :: String = ""
    \\end
    \\
;

pub const PrependResult = struct {
    source: []const u8,
    stdlib_line_count: u32,
};

/// Prepend standard library source to user source for unified parsing.
/// Returns the combined source and the number of lines the stdlib occupies,
/// so error reporting can subtract the offset for user-facing line numbers.
pub fn prependStdlib(allocator: std.mem.Allocator, user_source: []const u8) !PrependResult {
    const stdlib_source = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n", .{
        lib_kernel, lib_io, lib_system, lib_string, lib_atom, lib_integer, lib_float, lib_zap,
    });
    var line_count: u32 = 0;
    for (stdlib_source) |c| {
        if (c == '\n') line_count += 1;
    }
    const full = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stdlib_source, user_source });
    return .{ .source = full, .stdlib_line_count = line_count };
}
