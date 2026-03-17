const std = @import("std");

// Standard library module sources.
// These are the canonical Zap definitions for IO, Kernel, etc.
// The lib/ directory contains the same sources for editor tooling.

pub const lib_io =
    \\defmodule IO do
    \\  def puts(message) do
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

pub const PrependResult = struct {
    source: []const u8,
    stdlib_line_count: u32,
};

/// Prepend standard library source to user source for unified parsing.
/// Returns the combined source and the number of lines the stdlib occupies,
/// so error reporting can subtract the offset for user-facing line numbers.
pub fn prependStdlib(allocator: std.mem.Allocator, user_source: []const u8) !PrependResult {
    const stdlib_source = try std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ lib_kernel, lib_io });
    var line_count: u32 = 0;
    for (stdlib_source) |c| {
        if (c == '\n') line_count += 1;
    }
    const full = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stdlib_source, user_source });
    return .{ .source = full, .stdlib_line_count = line_count };
}
