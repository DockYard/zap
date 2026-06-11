pub struct ClosureTest {
  use Zest.Case

  describe("closures") {
    test("apply doubles value") {
      assert(apply(21, doubler) == 42)
    }

    test("apply with add_one") {
      assert(apply(41, add_one) == 42)
    }

    test("apply_twice") {
      assert(apply_twice(10, add_one) == 12)
    }

    test("apply_twice with doubler") {
      assert(apply_twice(10, doubler) == 40)
    }

    test("chain via apply") {
      assert(apply(apply(20, add_one), doubler) == 42)
    }

    test("anonymous function as callback") {
      assert(apply(21, fn(x :: i64) -> i64 { x * 2 }) == 42)
    }

    test("anonymous function addition") {
      assert(apply(40, fn(x :: i64) -> i64 { x + 2 }) == 42)
    }

    test("lambda-lifted local def can be called") {
      assert(local_def_value() == 42)
    }

    test("function-local captured closure can be called") {
      assert(make_adder_result(32) == 42)
    }

    test("aliased function-local captured closure can be called repeatedly") {
      assert(compute_offsets(10) == 28)
    }

    test("captured closures can be selected through multiple paths") {
      assert(select_captured(100, 1) == 110)
      assert(select_captured(100, 2) == 120)
    }

    test("struct function ref call resolves statically") {
      assert(&ClosureTest.double_ref/1(21) == 42)
    }

    test("local function ref call resolves statically") {
      assert(&double_ref/1(21) == 42)
    }

    test("static Function struct literal call resolves statically") {
      assert(%Function{struct: ClosureTest, name: :double_ref, arity: 1}(21) == 42)
    }

    test("static local function ref captures environment") {
      assert(make_and_apply_ref(32) == 42)
    }

    test("anonymous closure captures environment") {
      offset = 10
      add_offset = fn(x :: i64) -> i64 { x + offset }

      assert(apply(32, add_offset) == 42)
    }
  }

  fn add_one(x :: i64) -> i64 {
    x + 1
  }

  fn doubler(x :: i64) -> i64 {
    x * 2
  }

  fn multiply(x :: i64, y :: i64) -> i64 {
    x * y
  }

  pub fn double_ref(x :: i64) -> i64 {
    x * 2
  }

  fn apply(value :: i64, callback :: fn(i64) -> i64) -> i64 {
    callback(value)
  }

  fn apply_twice(value :: i64, callback :: fn(i64) -> i64) -> i64 {
    callback(callback(value))
  }

  fn test_anon_fn() -> i64 {
    apply(21, fn(x :: i64) -> i64 { x * 2 })
  }

  fn local_def_value() -> i64 {
    pub fn forty_two() -> i64 {
      42
    }

    forty_two()
  }

  fn make_adder_result(base :: i64) -> i64 {
    pub fn add(value :: i64) -> i64 {
      base + value
    }

    add(10)
  }

  fn compute_offsets(base :: i64) -> i64 {
    pub fn offset(value :: i64) -> i64 {
      base + value
    }

    offset(5) + offset(3)
  }

  fn select_captured(base :: i64, mode :: i64) -> i64 {
    pub fn add_ten(value :: i64) -> i64 {
      base + value + 10
    }

    pub fn add_twenty(value :: i64) -> i64 {
      base + value + 20
    }

    case mode {
      1 -> add_ten(0)
      _ -> add_twenty(0)
    }
  }

  fn make_and_apply_ref(base :: i64) -> i64 {
    pub fn add_base(value :: i64) -> i64 {
      base + value
    }

    &add_base/1(10)
  }

  describe("zero-arg callback") {
    test("wrap_call returns callback result") {
      assert(wrap_test() == 42)
    }
  }

  fn wrap_test() -> i64 {
    wrap_call(fn() -> i64 { 42 })
  }

  fn wrap_call(callback :: fn() -> i64) -> i64 {
    callback()
  }

  describe("closure values in type positions") {
    test("returned closure can be called") {
      callback = ClosureTestFactory.make_adder()
      assert(callback() == 42)
    }

    test("closure stored in struct field can be called") {
      handler = %ClosureTestHandler{action: fn() -> i64 { 7 }}
      assert(handler.action() == 7)
    }

    test("closure-typed field with parameter receives argument") {
      transform = %ClosureTestTransform{op: fn(value :: i64) -> i64 { value * 2 }}
      assert(transform.op(21) == 42)
    }

    test("struct returned from function can carry callable closure field") {
      handler = ClosureTestFactory.build_handler()
      assert(handler.action() == 99)
    }

    test("higher-order function can return and accept closures together") {
      returned = ClosureTestFunctionSurface.make_five()
      first = returned()
      second = ClosureTestFunctionSurface.run_nullary(fn() -> i64 { 37 })

      assert(first + second == 42)
    }

    test("function type surface works in param field and return positions") {
      nullary = ClosureTestFunctionSurface.run_nullary(fn() -> i64 { 10 })
      binary = ClosureTestFunctionSurface.run_binary(fn(left :: i64, right :: i64) -> i64 { left + right })
      holder = %ClosureTestTransform{op: fn(value :: i64) -> i64 { value * 2 }}
      returned = ClosureTestFunctionSurface.make()

      assert(nullary + binary + holder.op(9) + returned() == 43)
    }
  }

  describe("cross-struct generic callback") {
    test("IO.mode/2 returns callback result") {
      assert(mode_test() == 42)
    }
  }

  fn mode_test() -> i64 {
    IO.mode(IO.Mode.Normal, fn() -> i64 { 42 })
  }
}
