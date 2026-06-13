@doc = """
  Tuple-backed SIMD operations.

  Simd exposes Zap tuples as the public SIMD value shape and delegates the
  actual lane operations to Zig's `@Vector` builtins through `:zig.Simd`.
  No Zap vector type is introduced: `{f32, f32, f32, f32}` remains an
  ordinary tuple, and SIMD behavior is only available through this module.
  """

pub struct Simd {
  macro typed_vector_call(lanes_expression :: Expr, lane_type :: Type, raw_call :: Expr) -> Expr {
    vector_type = type_tuple(lane_type, lanes_expression)
    typed_call = type_annotate(raw_call, vector_type)

    quote { unquote(typed_call) }
  }

  @doc = """
    Type-checks a homogeneous tuple as an SIMD lane tuple.

    `Simd.vector(4, f32, {1.0, 2.0, 3.0, 4.0})` returns a
    `{f32, f32, f32, f32}` tuple after validating the shape through
    Zig's SIMD runtime bridge.
    """

  pub macro vector(lanes :: Integer, lane_type :: Type, tuple_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    vector_type = type_tuple(lane_type, lanes)
    typed_tuple = type_annotate(tuple_expression, vector_type)
    raw_call = quote {
      :zig.Simd.vector(unquote(typed_tuple))
    }
    typed_call = type_annotate(raw_call, vector_type)

    quote { unquote(typed_call) }
  }

  @doc = """
    Builds a homogeneous SIMD tuple by repeating one lane value.

    `Simd.splat(4, i32, 7)` returns `{7, 7, 7, 7}` as an
    `{i32, i32, i32, i32}` tuple.
    """

  pub macro splat(lanes :: Integer, i8, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_i8(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, i8, raw_call)
  }

  pub macro splat(lanes :: Integer, i16, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_i16(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, i16, raw_call)
  }

  pub macro splat(lanes :: Integer, i32, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_i32(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, i32, raw_call)
  }

  pub macro splat(lanes :: Integer, i64, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_i64(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, i64, raw_call)
  }

  pub macro splat(lanes :: Integer, i128, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_i128(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, i128, raw_call)
  }

  pub macro splat(lanes :: Integer, u8, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_u8(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, u8, raw_call)
  }

  pub macro splat(lanes :: Integer, u16, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_u16(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, u16, raw_call)
  }

  pub macro splat(lanes :: Integer, u32, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_u32(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, u32, raw_call)
  }

  pub macro splat(lanes :: Integer, u64, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_u64(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, u64, raw_call)
  }

  pub macro splat(lanes :: Integer, u128, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_u128(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, u128, raw_call)
  }

  pub macro splat(lanes :: Integer, usize, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_usize(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, usize, raw_call)
  }

  pub macro splat(lanes :: Integer, isize, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_isize(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, isize, raw_call)
  }

  pub macro splat(lanes :: Integer, f16, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_f16(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, f16, raw_call)
  }

  pub macro splat(lanes :: Integer, f32, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_f32(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, f32, raw_call)
  }

  pub macro splat(lanes :: Integer, f64, scalar_expression :: Expr) -> Expr if lanes in [2, 3, 4, 8, 16] {
    raw_call = quote { :zig.Simd.splat_f64(unquote(lanes), unquote(scalar_expression)) }

    Simd.typed_vector_call(quote { unquote(lanes) }, f64, raw_call)
  }

  @doc = """
    Reduces a lane tuple with `:add`, `:min`, or `:max`.
    """

  pub macro reduce(:add, value :: Expr) -> Expr {
    quote { Simd.reduce_add(unquote(value)) }
  }

  pub macro reduce(:min, value :: Expr) -> Expr {
    quote { Simd.reduce_min(unquote(value)) }
  }

  pub macro reduce(:max, value :: Expr) -> Expr {
    quote { Simd.reduce_max(unquote(value)) }
  }

  @doc = """
    Adds two SIMD tuples element-wise.
    """

  pub fn add(left :: {lane, lane}, right :: {lane, lane}) -> {lane, lane} {
    :zig.Simd.add(left, right)
  }

  pub fn add(left :: {lane, lane, lane}, right :: {lane, lane, lane}) -> {lane, lane, lane} {
    :zig.Simd.add(left, right)
  }

  pub fn add(left :: {lane, lane, lane, lane}, right :: {lane, lane, lane, lane}) -> {lane, lane, lane, lane} {
    :zig.Simd.add(left, right)
  }

  pub fn add(left :: {lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> {lane, lane, lane, lane, lane, lane, lane, lane} {
    :zig.Simd.add(left, right)
  }

  pub fn add(left :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane} {
    :zig.Simd.add(left, right)
  }

  @doc = """
    Subtracts two SIMD tuples element-wise.
    """

  pub fn sub(left :: {lane, lane}, right :: {lane, lane}) -> {lane, lane} {
    :zig.Simd.sub(left, right)
  }

  pub fn sub(left :: {lane, lane, lane}, right :: {lane, lane, lane}) -> {lane, lane, lane} {
    :zig.Simd.sub(left, right)
  }

  pub fn sub(left :: {lane, lane, lane, lane}, right :: {lane, lane, lane, lane}) -> {lane, lane, lane, lane} {
    :zig.Simd.sub(left, right)
  }

  pub fn sub(left :: {lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> {lane, lane, lane, lane, lane, lane, lane, lane} {
    :zig.Simd.sub(left, right)
  }

  pub fn sub(left :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane} {
    :zig.Simd.sub(left, right)
  }

  @doc = """
    Multiplies two SIMD tuples element-wise.
    """

  pub fn mul(left :: {lane, lane}, right :: {lane, lane}) -> {lane, lane} {
    :zig.Simd.mul(left, right)
  }

  pub fn mul(left :: {lane, lane, lane}, right :: {lane, lane, lane}) -> {lane, lane, lane} {
    :zig.Simd.mul(left, right)
  }

  pub fn mul(left :: {lane, lane, lane, lane}, right :: {lane, lane, lane, lane}) -> {lane, lane, lane, lane} {
    :zig.Simd.mul(left, right)
  }

  pub fn mul(left :: {lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> {lane, lane, lane, lane, lane, lane, lane, lane} {
    :zig.Simd.mul(left, right)
  }

  pub fn mul(left :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane} {
    :zig.Simd.mul(left, right)
  }

  @doc = """
    Compares two SIMD tuples lane-wise for equality.
    """

  pub fn eq(left :: {lane, lane}, right :: {lane, lane}) -> {Bool, Bool} {
    :zig.Simd.eq(left, right)
  }

  pub fn eq(left :: {lane, lane, lane}, right :: {lane, lane, lane}) -> {Bool, Bool, Bool} {
    :zig.Simd.eq(left, right)
  }

  pub fn eq(left :: {lane, lane, lane, lane}, right :: {lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool} {
    :zig.Simd.eq(left, right)
  }

  pub fn eq(left :: {lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.eq(left, right)
  }

  pub fn eq(left :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.eq(left, right)
  }

  @doc = """
    Compares two SIMD tuples lane-wise for inequality.
    """

  pub fn ne(left :: {lane, lane}, right :: {lane, lane}) -> {Bool, Bool} {
    :zig.Simd.ne(left, right)
  }

  pub fn ne(left :: {lane, lane, lane}, right :: {lane, lane, lane}) -> {Bool, Bool, Bool} {
    :zig.Simd.ne(left, right)
  }

  pub fn ne(left :: {lane, lane, lane, lane}, right :: {lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool} {
    :zig.Simd.ne(left, right)
  }

  pub fn ne(left :: {lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.ne(left, right)
  }

  pub fn ne(left :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.ne(left, right)
  }

  @doc = """
    Compares whether each lane in the left tuple is less than the matching right lane.
    """

  pub fn lt(left :: {lane, lane}, right :: {lane, lane}) -> {Bool, Bool} {
    :zig.Simd.lt(left, right)
  }

  pub fn lt(left :: {lane, lane, lane}, right :: {lane, lane, lane}) -> {Bool, Bool, Bool} {
    :zig.Simd.lt(left, right)
  }

  pub fn lt(left :: {lane, lane, lane, lane}, right :: {lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool} {
    :zig.Simd.lt(left, right)
  }

  pub fn lt(left :: {lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.lt(left, right)
  }

  pub fn lt(left :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.lt(left, right)
  }

  @doc = """
    Compares whether each lane in the left tuple is less than or equal to the matching right lane.
    """

  pub fn lte(left :: {lane, lane}, right :: {lane, lane}) -> {Bool, Bool} {
    :zig.Simd.lte(left, right)
  }

  pub fn lte(left :: {lane, lane, lane}, right :: {lane, lane, lane}) -> {Bool, Bool, Bool} {
    :zig.Simd.lte(left, right)
  }

  pub fn lte(left :: {lane, lane, lane, lane}, right :: {lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool} {
    :zig.Simd.lte(left, right)
  }

  pub fn lte(left :: {lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.lte(left, right)
  }

  pub fn lte(left :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.lte(left, right)
  }

  @doc = """
    Compares whether each lane in the left tuple is greater than the matching right lane.
    """

  pub fn gt(left :: {lane, lane}, right :: {lane, lane}) -> {Bool, Bool} {
    :zig.Simd.gt(left, right)
  }

  pub fn gt(left :: {lane, lane, lane}, right :: {lane, lane, lane}) -> {Bool, Bool, Bool} {
    :zig.Simd.gt(left, right)
  }

  pub fn gt(left :: {lane, lane, lane, lane}, right :: {lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool} {
    :zig.Simd.gt(left, right)
  }

  pub fn gt(left :: {lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.gt(left, right)
  }

  pub fn gt(left :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.gt(left, right)
  }

  @doc = """
    Compares whether each lane in the left tuple is greater than or equal to the matching right lane.
    """

  pub fn gte(left :: {lane, lane}, right :: {lane, lane}) -> {Bool, Bool} {
    :zig.Simd.gte(left, right)
  }

  pub fn gte(left :: {lane, lane, lane}, right :: {lane, lane, lane}) -> {Bool, Bool, Bool} {
    :zig.Simd.gte(left, right)
  }

  pub fn gte(left :: {lane, lane, lane, lane}, right :: {lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool} {
    :zig.Simd.gte(left, right)
  }

  pub fn gte(left :: {lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.gte(left, right)
  }

  pub fn gte(left :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}, right :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool} {
    :zig.Simd.gte(left, right)
  }

  @doc = """
    Selects lane-wise between two SIMD tuples with a Bool mask tuple.
    """

  pub fn select(mask :: {Bool, Bool}, when_true :: {lane, lane}, when_false :: {lane, lane}) -> {lane, lane} {
    :zig.Simd.select(mask, when_true, when_false)
  }

  pub fn select(mask :: {Bool, Bool, Bool}, when_true :: {lane, lane, lane}, when_false :: {lane, lane, lane}) -> {lane, lane, lane} {
    :zig.Simd.select(mask, when_true, when_false)
  }

  pub fn select(mask :: {Bool, Bool, Bool, Bool}, when_true :: {lane, lane, lane, lane}, when_false :: {lane, lane, lane, lane}) -> {lane, lane, lane, lane} {
    :zig.Simd.select(mask, when_true, when_false)
  }

  pub fn select(mask :: {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool}, when_true :: {lane, lane, lane, lane, lane, lane, lane, lane}, when_false :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> {lane, lane, lane, lane, lane, lane, lane, lane} {
    :zig.Simd.select(mask, when_true, when_false)
  }

  pub fn select(mask :: {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool}, when_true :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}, when_false :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane} {
    :zig.Simd.select(mask, when_true, when_false)
  }

  @doc = """
    Adds all lanes in a SIMD tuple.
    """

  pub fn reduce_add(value :: {lane, lane}) -> lane {
    :zig.Simd.reduce_add(value)
  }

  pub fn reduce_add(value :: {lane, lane, lane}) -> lane {
    :zig.Simd.reduce_add(value)
  }

  pub fn reduce_add(value :: {lane, lane, lane, lane}) -> lane {
    :zig.Simd.reduce_add(value)
  }

  pub fn reduce_add(value :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> lane {
    :zig.Simd.reduce_add(value)
  }

  pub fn reduce_add(value :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> lane {
    :zig.Simd.reduce_add(value)
  }

  @doc = """
    Returns the minimum lane in a SIMD tuple.
    """

  pub fn reduce_min(value :: {lane, lane}) -> lane {
    :zig.Simd.reduce_min(value)
  }

  pub fn reduce_min(value :: {lane, lane, lane}) -> lane {
    :zig.Simd.reduce_min(value)
  }

  pub fn reduce_min(value :: {lane, lane, lane, lane}) -> lane {
    :zig.Simd.reduce_min(value)
  }

  pub fn reduce_min(value :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> lane {
    :zig.Simd.reduce_min(value)
  }

  pub fn reduce_min(value :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> lane {
    :zig.Simd.reduce_min(value)
  }

  @doc = """
    Returns the maximum lane in a SIMD tuple.
    """

  pub fn reduce_max(value :: {lane, lane}) -> lane {
    :zig.Simd.reduce_max(value)
  }

  pub fn reduce_max(value :: {lane, lane, lane}) -> lane {
    :zig.Simd.reduce_max(value)
  }

  pub fn reduce_max(value :: {lane, lane, lane, lane}) -> lane {
    :zig.Simd.reduce_max(value)
  }

  pub fn reduce_max(value :: {lane, lane, lane, lane, lane, lane, lane, lane}) -> lane {
    :zig.Simd.reduce_max(value)
  }

  pub fn reduce_max(value :: {lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane, lane}) -> lane {
    :zig.Simd.reduce_max(value)
  }
}
