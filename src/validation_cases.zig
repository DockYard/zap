pub const borrowed_closure_arg =
    \\defmodule Test do
    \\  opaque Handle = String
    \\
    \\  def run(use_fn :: (borrowed Handle -> Handle), handle :: Handle) :: Handle do
    \\    use_fn(handle)
    \\  end
    \\end
;

pub const shared_closure_arg =
    \\defmodule Test do
    \\  opaque Handle = String
    \\
    \\  def run(use_fn :: (shared Handle -> Handle), handle :: Handle) :: Handle do
    \\    use_fn(handle)
    \\  end
    \\end
;

pub const switch_dispatch =
    \\defmodule Foo do
    \\  def inc(x :: i64) :: i64 do
    \\    x + 1
    \\  end
    \\
    \\  def dec(x :: i64) :: i64 do
    \\    x - 1
    \\  end
    \\
    \\  def apply(f :: (i64 -> i64), value :: i64) :: i64 do
    \\    f(value)
    \\  end
    \\
    \\  def choose(flag :: Bool) :: (i64 -> i64) do
    \\    if flag do
    \\      inc
    \\    else
    \\      dec
    \\    end
    \\  end
    \\
    \\  def run(flag :: Bool) :: i64 do
    \\    apply(choose(flag), 10)
    \\  end
    \\end
;

pub const non_escaping_closure =
    \\defmodule Foo do
    \\  def run(x :: i64) :: i64 do
    \\    f = fn(y :: i64) :: i64 do
    \\      x + y
    \\    end
    \\    f(2)
    \\  end
    \\end
;
