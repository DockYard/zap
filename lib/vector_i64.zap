@native_type = "vector_i64"

@doc = """
  Mutable, ARC-managed, COW-aware contiguous vector of `i64`.

  Backed by `Vector(i64)` in the runtime — single-allocation flat
  buffer (`[ ArcHeader | header { len, cap } | data: [cap]i64 ]`)
  through the system allocator. Designed for random-access integer
  kernels (fannkuch-redux's permutation buffer, spectral-norm-style
  code paths) with refcount-aware in-place mutation: when the
  caller is the unique owner every `set`, `push`, `pop`, `append`
  rewrites the live buffer with no allocation; when the receiver
  is shared the buffer is cloned with deep-retain of every element
  first, so the original observer stays valid.

  ## Examples

      values = VectorI64.new_filled(3, 0 :: i64)
      values = VectorI64.set(values, 0, 10 :: i64)
      values = VectorI64.set(values, 1, 20 :: i64)
      values = VectorI64.set(values, 2, 30 :: i64)
      VectorI64.get(values, 1)    # => 20
      VectorI64.length(values)    # => 3
  """

pub struct VectorI64 {
  @doc = """
    Allocate a fresh mutable `i64` vector of `size` slots, with
    every slot initialised to `init`.

    ## Examples

        VectorI64.new_filled(4, 0 :: i64)   # 4-slot vector of zeros
        VectorI64.new_filled(2, 7 :: i64)   # [7, 7]
    """

  pub fn new_filled(size :: i64, init :: i64) -> VectorI64 {
    :zig.VectorI64.new_filled(size, init)
  }

  @doc = """
    Allocate an empty mutable `i64` vector with the given reserved
    capacity. The returned vector has `len == 0` and `cap >=
    initial_capacity`. Useful when the call site knows the final
    size up-front and wants to skip the per-push capacity-grow
    loop.

    ## Examples

        VectorI64.new_empty(8)   # capacity reserved, length 0
    """

  pub fn new_empty(initial_capacity :: i64) -> VectorI64 {
    :zig.VectorI64.new_empty(initial_capacity)
  }

  @doc = """
    Read the element at zero-based `index`. Panics on out-of-bounds
    access.

    ## Examples

        v = VectorI64.new_filled(3, 5 :: i64)
        VectorI64.get(v, 0)  # => 5
    """

  pub fn get(vec :: VectorI64, index :: i64) -> i64 {
    :zig.VectorI64.get(vec, index)
  }

  @doc = """
    Write `value` at zero-based `index`. Refcount-aware: when
    `vec` is uniquely owned the buffer is mutated in place and the
    same handle is returned; otherwise a deep-retain clone is
    made, mutated, and returned. Returns the resulting vector so
    the call chains naturally:

        v = VectorI64.set(v, i, x)

    ## Examples

        v = VectorI64.new_filled(3, 0 :: i64)
        v = VectorI64.set(v, 1, 42 :: i64)
        VectorI64.get(v, 1)  # => 42
    """

  pub fn set(vec :: VectorI64, index :: i64, value :: i64) -> VectorI64 {
    :zig.VectorI64.set(vec, index, value)
  }

  @doc = """
    Append `value` to the end. Refcount-aware: on rc==1 the
    buffer is mutated in place (capacity doubled if exhausted);
    on rc>1 a deep-retain clone with sufficient capacity is
    allocated first.

    ## Examples

        v = VectorI64.new_empty(4)
        v = VectorI64.push(v, 1 :: i64)
        v = VectorI64.push(v, 2 :: i64)
        VectorI64.length(v)  # => 2
    """

  pub fn push(vec :: VectorI64, value :: i64) -> VectorI64 {
    :zig.VectorI64.push(vec, value)
  }

  @doc = """
    Remove the last element. Refcount-aware in the same way as
    `set` and `push`. Returns the resulting (shorter) vector;
    panics on an empty vector. The popped value is NOT returned —
    callers that need it should `get` first.

    ## Examples

        v = VectorI64.new_filled(3, 7 :: i64)
        v = VectorI64.pop(v)
        VectorI64.length(v)  # => 2
    """

  pub fn pop(vec :: VectorI64) -> VectorI64 {
    :zig.VectorI64.pop(vec)
  }

  @doc = """
    Concatenate two vectors. The result is logically `a ++ b`.
    Refcount-aware: when `a` is uniquely owned and has reserved
    capacity for `len(a) + len(b)`, B's elements are appended in
    place; otherwise a fresh buffer is allocated. The caller still
    owns `b`'s reference after the call (mirrors `Map.merge`'s
    ABI).

    ## Examples

        a = VectorI64.push(VectorI64.new_empty(0), 1 :: i64)
        b = VectorI64.push(VectorI64.new_empty(0), 2 :: i64)
        VectorI64.append(a, b)  # => [1, 2]
    """

  pub fn append(a :: VectorI64, b :: VectorI64) -> VectorI64 {
    :zig.VectorI64.append(a, b)
  }

  @doc = """
    Number of populated elements in the vector.

    ## Examples

        VectorI64.length(VectorI64.new_filled(7, 0 :: i64))  # => 7
    """

  pub fn length(vec :: VectorI64) -> i64 {
    :zig.VectorI64.length(vec)
  }

  @doc = """
    Total capacity (number of element slots in the buffer).
    Always `>= length`. Use this when planning resize-free
    insertion patterns.

    ## Examples

        VectorI64.capacity(VectorI64.new_empty(8))  # => 8 (or larger)
    """

  pub fn capacity(vec :: VectorI64) -> i64 {
    :zig.VectorI64.capacity(vec)
  }
}
