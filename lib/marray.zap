@doc = """
  Mutable, contiguous-storage, ARC-managed arrays.

  Two specialised element types are exposed today: `MArrayI64`
  for signed 64-bit integers, and `MArrayF64` for double-precision
  floats. Both are backed by a generic `MArrayOf(T)` template in
  the runtime, so adding a new element type later (e.g.
  `MArrayString`) is a one-line `pub const MArrayString =
  MArrayOf(String)` addition in the runtime plus a mirrored Zap
  struct here.

  Designed for random-access numeric inner loops (fannkuch-redux,
  spectral-norm) that defeat persistent `List`'s `O(N)` `at`.

  ## Examples

      values = MArrayI64.new(3, 0 :: i64)
      _ = MArrayI64.set(values, 0, 10 :: i64)
      _ = MArrayI64.set(values, 1, 20 :: i64)
      _ = MArrayI64.set(values, 2, 30 :: i64)
      MArrayI64.get(values, 1)   # => 20
      MArrayI64.length(values)   # => 3
  """

pub struct MArrayI64 {
  @doc = """
    Allocate a fresh mutable `i64` array of `size` slots, with
    every slot initialised to `init`. Both arguments must be
    statically `i64`-typed.

    ## Examples

        MArrayI64.new(4, 0 :: i64)   # 4-slot array of zeros
        MArrayI64.new(2, 7 :: i64)   # [7, 7]
    """

  pub fn new(size :: i64, init :: i64) -> MArrayI64 {
    :zig.MArrayI64.new(size, init)
  }

  @doc = """
    Read the element at zero-based `index`. Panics on
    out-of-bounds access.

    ## Examples

        arr = MArrayI64.new(3, 5 :: i64)
        MArrayI64.get(arr, 0)  # => 5
    """

  pub fn get(arr :: MArrayI64, index :: i64) -> i64 {
    :zig.MArrayI64.get(arr, index)
  }

  @doc = """
    Write `value` at zero-based `index`, mutating the array
    in place. Returns `value` so the call can be chained or
    used in expression position.

    ## Examples

        arr = MArrayI64.new(3, 0 :: i64)
        _ = MArrayI64.set(arr, 1, 42 :: i64)
        MArrayI64.get(arr, 1)  # => 42
    """

  pub fn set(arr :: MArrayI64, index :: i64, value :: i64) -> i64 {
    :zig.MArrayI64.set(arr, index, value)
  }

  @doc = """
    Number of elements in the array.

    ## Examples

        MArrayI64.length(MArrayI64.new(7, 0 :: i64))  # => 7
    """

  pub fn length(arr :: MArrayI64) -> i64 {
    :zig.MArrayI64.length(arr)
  }
}

pub struct MArrayF64 {
  @doc = """
    Allocate a fresh mutable `f64` array of `size` slots, with
    every slot initialised to `init`. `size` is `i64`; `init`
    must be statically `f64`-typed.

    ## Examples

        MArrayF64.new(4, 0.0 :: f64)   # 4-slot array of 0.0
        MArrayF64.new(2, 1.0 :: f64)   # [1.0, 1.0]
    """

  pub fn new(size :: i64, init :: f64) -> MArrayF64 {
    :zig.MArrayF64.new(size, init)
  }

  @doc = """
    Read the element at zero-based `index`. Panics on
    out-of-bounds access.

    ## Examples

        arr = MArrayF64.new(3, 1.0 :: f64)
        MArrayF64.get(arr, 0)  # => 1.0
    """

  pub fn get(arr :: MArrayF64, index :: i64) -> f64 {
    :zig.MArrayF64.get(arr, index)
  }

  @doc = """
    Write `value` at zero-based `index`, mutating the array
    in place. Returns `value` so the call can be chained or
    used in expression position.

    ## Examples

        arr = MArrayF64.new(3, 0.0 :: f64)
        _ = MArrayF64.set(arr, 1, 3.5 :: f64)
        MArrayF64.get(arr, 1)  # => 3.5
    """

  pub fn set(arr :: MArrayF64, index :: i64, value :: f64) -> f64 {
    :zig.MArrayF64.set(arr, index, value)
  }

  @doc = """
    Number of elements in the array.

    ## Examples

        MArrayF64.length(MArrayF64.new(5, 0.0 :: f64))  # => 5
    """

  pub fn length(arr :: MArrayF64) -> i64 {
    :zig.MArrayF64.length(arr)
  }
}
