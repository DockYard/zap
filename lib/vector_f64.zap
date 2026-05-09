@native_type = "vector_f64"

@doc = """
  Mutable, ARC-managed, COW-aware contiguous vector of `f64`.

  Backed by `Vector(f64)` in the runtime — single-allocation flat
  buffer (`[ ArcHeader | header { len, cap } | data: [cap]f64 ]`)
  through the system allocator. Companion to `VectorI64`; designed
  for floating-point kernels (e.g. spectral-norm's power-iteration
  `(A · v)`) with refcount-aware in-place mutation: when the
  caller is the unique owner every `set`, `push`, `pop`, `append`
  rewrites the live buffer with no allocation; when the receiver
  is shared the buffer is cloned with deep-retain of every element
  first, so the original observer stays valid.

  ## Examples

      values = VectorF64.new_filled(3, 0.0 :: f64)
      values = VectorF64.set(values, 0, 1.0 :: f64)
      values = VectorF64.set(values, 1, 2.5 :: f64)
      VectorF64.get(values, 1)    # => 2.5
      VectorF64.length(values)    # => 3
  """

pub struct VectorF64 {
  @doc = """
    Allocate a fresh mutable `f64` vector of `size` slots, with
    every slot initialised to `init`.

    ## Examples

        VectorF64.new_filled(4, 0.0 :: f64)   # 4-slot vector of 0.0
        VectorF64.new_filled(2, 1.0 :: f64)   # [1.0, 1.0]
    """

  pub fn new_filled(size :: i64, init :: f64) -> VectorF64 {
    :zig.VectorF64.new_filled(size, init)
  }

  @doc = """
    Allocate an empty mutable `f64` vector with the given reserved
    capacity. The returned vector has `len == 0` and `cap >=
    initial_capacity`.

    ## Examples

        VectorF64.new_empty(8)   # capacity reserved, length 0
    """

  pub fn new_empty(initial_capacity :: i64) -> VectorF64 {
    :zig.VectorF64.new_empty(initial_capacity)
  }

  @doc = """
    Read the element at zero-based `index`. Panics on out-of-bounds
    access.

    ## Examples

        v = VectorF64.new_filled(3, 1.5 :: f64)
        VectorF64.get(v, 0)  # => 1.5
    """

  pub fn get(vec :: VectorF64, index :: i64) -> f64 {
    :zig.VectorF64.get(vec, index)
  }

  @doc = """
    Write `value` at zero-based `index`. Refcount-aware: rc==1
    mutates in place; rc>1 deep-retain clones first. Returns the
    resulting vector for chaining.

    ## Examples

        v = VectorF64.new_filled(3, 0.0 :: f64)
        v = VectorF64.set(v, 1, 3.5 :: f64)
        VectorF64.get(v, 1)  # => 3.5
    """

  pub fn set(vec :: VectorF64, index :: i64, value :: f64) -> VectorF64 {
    :zig.VectorF64.set(vec, index, value)
  }

  @doc = """
    Append `value` to the end. Refcount-aware in the same way as
    `set`. Buffer doubles when capacity is exhausted on the rc==1
    fast path.

    ## Examples

        v = VectorF64.new_empty(4)
        v = VectorF64.push(v, 1.0 :: f64)
        v = VectorF64.push(v, 2.0 :: f64)
        VectorF64.length(v)  # => 2
    """

  pub fn push(vec :: VectorF64, value :: f64) -> VectorF64 {
    :zig.VectorF64.push(vec, value)
  }

  @doc = """
    Remove the last element. Refcount-aware. Returns the resulting
    (shorter) vector; panics on an empty vector. The popped value
    is NOT returned — call `get` first if you need it.

    ## Examples

        v = VectorF64.new_filled(3, 7.0 :: f64)
        v = VectorF64.pop(v)
        VectorF64.length(v)  # => 2
    """

  pub fn pop(vec :: VectorF64) -> VectorF64 {
    :zig.VectorF64.pop(vec)
  }

  @doc = """
    Concatenate two vectors. Refcount-aware: when `a` is uniquely
    owned and has reserved capacity for `len(a) + len(b)`, B's
    elements are appended in place; otherwise a fresh buffer is
    allocated. The caller still owns `b`'s reference after the
    call.

    ## Examples

        a = VectorF64.push(VectorF64.new_empty(0), 1.0 :: f64)
        b = VectorF64.push(VectorF64.new_empty(0), 2.0 :: f64)
        VectorF64.append(a, b)  # => [1.0, 2.0]
    """

  pub fn append(a :: VectorF64, b :: VectorF64) -> VectorF64 {
    :zig.VectorF64.append(a, b)
  }

  @doc = """
    Number of populated elements in the vector.

    ## Examples

        VectorF64.length(VectorF64.new_filled(5, 0.0 :: f64))  # => 5
    """

  pub fn length(vec :: VectorF64) -> i64 {
    :zig.VectorF64.length(vec)
  }

  @doc = """
    Total capacity (number of element slots in the buffer).
    Always `>= length`.

    ## Examples

        VectorF64.capacity(VectorF64.new_empty(8))  # => 8 (or larger)
    """

  pub fn capacity(vec :: VectorF64) -> i64 {
    :zig.VectorF64.capacity(vec)
  }
}
