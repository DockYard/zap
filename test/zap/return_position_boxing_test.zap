@doc = """
  Regression coverage for return-position boxing of a PARAMETRIC-struct
  instantiation as a protocol existential (the gap that blocked the Stream
  layer). A function whose declared return type is a protocol existential
  (`-> Enumerable(i64)`) that RETURNS a parametric-struct instantiation
  literal (`\#{%OneWrap(i64){...}}`) failed ZIR emission with `expected type
  'zap_runtime.ProtocolBox', found 'OneWrap_i64'`: the concrete->box
  coercion had no `BoxedImplSpec` to consult because the monomorphizer's
  forced-specialization pass rejected the whole impl the moment one of its
  methods was an impl-private helper — a boxed-dispatch router whose first
  parameter is a DIFFERENT protocol, not the target-typed receiver.

  The fix force-specializes only the impl's PROTOCOL methods (the vtable
  methods, bound by receiver-unification against the target) and lets the
  private helpers be specialized transitively. It also handles a
  2-type-parameter adapter whose extra parameter is NOT determined by the
  protocol argument (`EmptyTransform(input, output)` implementing
  `Enumerable(output)` leaves `input` free after binding `output`): the
  concrete `input` is fixed only at the construction site, so the pass
  enumerates the concrete struct instantiations present in the store.

  Both the 1-parameter (fully-determined target) and the 2-parameter
  (under-determined target, distinct `input`/`output`) shapes are boxed at a
  return position, driven end-to-end, and their produced values asserted.
  """

pub struct OneWrap(element) {
  source :: Enumerable(element)
}

pub impl Enumerable(element) for OneWrap(element) {
  fn step(source :: unique Enumerable(element)) -> {Atom, element, OneWrap(element)} {
    case Enumerable.next(source) {
      {:done, exhausted_value, exhausted} -> {:done, exhausted_value, %OneWrap(element){source: exhausted}}
      {:cont, item, rest} -> {:cont, item, %OneWrap(element){source: rest}}
    }
  }

  fn drop_source(source :: unique Enumerable(element)) -> Nil {
    Enumerable.dispose(source)
    nil
  }

  pub fn next(self :: unique OneWrap(element)) -> {Atom, element, OneWrap(element)} {
    OneWrap.step(self.source)
  }

  pub fn dispose(self :: unique OneWrap(element)) -> Nil {
    OneWrap.drop_source(self.source)
    nil
  }
}

pub struct EmptyTransform(input, output) {
  source :: Enumerable(input)
}

pub impl Enumerable(output) for EmptyTransform(input, output) {
  pub fn next(self :: unique EmptyTransform(input, output)) -> {Atom, output, EmptyTransform(input, output)} {
    EmptyTransform.drain(self.source)
  }

  fn drain(source :: unique Enumerable(input)) -> {Atom, output, EmptyTransform(input, output)} {
    Enumerable.dispose(source)
    case Enumerable.next(([] :: [output])) {
      {_atom, manufactured, spent} -> EmptyTransform.finish(manufactured, spent)
    }
  }

  fn finish(manufactured :: output, spent :: unique Enumerable(output)) -> {Atom, output, EmptyTransform(input, output)} {
    Enumerable.dispose(spent)
    {:done, manufactured, %EmptyTransform(input, output){source: ([] :: [input])}}
  }

  pub fn dispose(self :: unique EmptyTransform(input, output)) -> Nil {
    EmptyTransform.drop_source(self.source)
  }

  fn drop_source(source :: unique Enumerable(input)) -> Nil {
    Enumerable.dispose(source)
    nil
  }
}

pub struct Zap.ReturnPositionBoxingTest {
  use Zest.Case

  describe("1-type-parameter adapter returned as a protocol existential") {
    test("boxed at a return position and drained") {
      drained = Enum.to_list(one_wrap([10, 20, 30]))
      assert(List.length(drained) == 3)
      assert(List.head(drained) == 10)
      assert(List.last(drained) == 30)
    }

    test("boxed at a return position and partially consumed") {
      taken = Enum.take(one_wrap([1, 2, 3, 4]), 2)
      assert(List.length(taken) == 2)
      assert(List.head(taken) == 1)
      assert(List.last(taken) == 2)
    }
  }

  describe("2-type-parameter adapter (under-determined target) returned as Enumerable(output)") {
    test("i64 source boxed as Enumerable(String) drains empty") {
      drained = Enum.to_list(empty_transform([1, 2, 3]))
      assert(List.length(drained) == 0)
    }
  }

  fn one_wrap(source :: unique Enumerable(i64)) -> Enumerable(i64) {
    %OneWrap(i64){source: source}
  }

  fn empty_transform(source :: unique Enumerable(i64)) -> Enumerable(String) {
    %EmptyTransform(i64, String){source: source}
  }
}
