@native_type = "marray_f64"

@doc = """
  Mutable, contiguous-storage, ARC-managed array of `f64`.

  Backed by `MArrayOf(f64)` in the runtime — Arc-managed `Inner`
  through a thread-local `MemoryPool`, payload allocated through
  `page_allocator`. Companion to `MArrayI64`; designed for the
  random-access floating-point kernels (e.g. spectral-norm's
  power-iteration `(A · v)`) that defeat persistent `List`'s
  `O(N)` `at`.

  ## Examples

      values = MArrayF64.new(3, 0.0 :: f64)
      _ = MArrayF64.set(values, 0, 1.0 :: f64)
      _ = MArrayF64.set(values, 1, 2.5 :: f64)
      MArrayF64.get(values, 1)    # => 2.5
      MArrayF64.length(values)    # => 3
  """

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
