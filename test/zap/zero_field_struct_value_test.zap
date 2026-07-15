@doc = """
  Regression coverage for constructing a FIELD-LESS struct as a runtime
  VALUE. Zero-field structs parse and work as namespaces, but constructing
  one — `\#{%ConcreteZero{}}` (concrete) or `\#{%ParamZero(i64, i64){}}`
  (parametric) — and passing it as a value failed ZIR emission with
  `no module named 'ConcreteZero' available within module ...`: under the
  selective-emission (`zap test`) path, a struct with no methods AND no
  fields was skipped by both the function-bearing-struct emission and the
  fields-only-struct emission (a `fields.len == 0` short-circuit), so no
  canonical `struct_decl` module existed for the `@import` the construction
  site emits.

  The fix emits a canonical (empty) `struct_decl` module for field-less
  structs alongside fields-only structs. This drives a field-less struct
  through construction, a by-value pass to a function, a struct-field
  round-trip, and a return, for BOTH a concrete and a parametric field-less
  struct — the `EmptyStage` terminal-sentinel shape the Stream design uses.
  """

pub struct ConcreteZero {
}

pub struct ParamZero(input, output) {
}

pub struct HoldsZero {
  marker :: ConcreteZero
}

pub struct Zap.ZeroFieldStructValueTest {
  use Zest.Case

  describe("concrete field-less struct value") {
    test("constructed and passed by value") {
      zero = %ConcreteZero{}
      assert(concrete_accepts(zero))
    }

    test("round-tripped through a struct field and returned") {
      holder = %HoldsZero{marker: %ConcreteZero{}}
      recovered = holder.marker
      assert(concrete_accepts(recovered))
    }
  }

  describe("parametric field-less struct value") {
    test("constructed at a concrete instantiation and passed by value") {
      zero = %ParamZero(i64, i64){}
      assert(param_accepts(zero))
    }

    test("constructed at a second instantiation and returned") {
      zero = make_param_zero()
      assert(param_string_accepts(zero))
    }
  }

  fn concrete_accepts(_zero :: ConcreteZero) -> Bool {
    true
  }

  fn param_accepts(_zero :: ParamZero(i64, i64)) -> Bool {
    true
  }

  fn param_string_accepts(_zero :: ParamZero(String, Bool)) -> Bool {
    true
  }

  fn make_param_zero() -> ParamZero(String, Bool) {
    %ParamZero(String, Bool){}
  }
}
