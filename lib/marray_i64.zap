@doc = """
  Mutable, contiguous-storage, ARC-managed array of `i64`.

  Backed by `MArrayOf(i64)` in the runtime — Arc-managed `Inner`
  through a thread-local `MemoryPool`, payload allocated through
  `page_allocator`. Designed for random-access integer inner
  loops (fannkuch-redux, spectral-norm) that defeat persistent
  `List`'s `O(N)` `at`.

  ## Examples

      values = MArrayI64.new(3, 0 :: i64)
      _ = MArrayI64.set(values, 0, 10 :: i64)
      _ = MArrayI64.set(values, 1, 20 :: i64)
      _ = MArrayI64.set(values, 2, 30 :: i64)
      MArrayI64.get(values, 1)    # => 20
      MArrayI64.length(values)    # => 3
  """

pub struct MArrayI64 {
  @doc = """
    Allocate a fresh mutable `i64` array of `size` slots, with
    every slot initialised to `init`.

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
