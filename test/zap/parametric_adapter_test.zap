@doc = """
  Regression coverage for the parametric-adapter ZIR-emission gap
  (gap-c). A user-defined PARAMETRIC struct `T(element)` that carries a
  boxed `Enumerable(element)` field and implements `Enumerable(element)`
  itself — an adapter — failed ZIR emission under `zap test` (the Zest
  suite compile path) while compiling and running fine under `zap run`
  (script mode). The failure surfaced as
  `ZIR emit failed resolving call_direct target function id N`.

  Root cause: the macro-engine AST<->quoted-term reflection for the `%`
  struct-literal form (`exprToCtValue` / `ctValueToExpr` in
  `src/ast_data.zig`) dropped the instantiation-site `type_args`. When
  the Zest `test`/`describe` macros quoted a test body containing
  `%Adapter(i64){...}`, the `(i64)` was lost, so the rehydrated literal
  typed as the bare generic head `Adapter` instead of `Adapter(i64)`.
  The monomorphizer then keyed `Enum.to_list` on the unconcretized
  `Adapter`, producing a malformed specialization that was never lowered
  to IR — leaving the rewritten `call_direct` dangling at emission. The
  `%` reflection now round-trips `type_args` (and the explicit-parens
  flag) exactly as the `__aliases__` (struct_ref) form already did.

  This drives BOTH a concrete `Enumerable` adapter and the parametric
  adapter through `Enum.to_list` and `Enum.map`, across two distinct
  element types (`i64` and `String`), asserting the produced values. A
  user-defined adapter (not a stdlib type) proves the fix is general
  rather than keyed to any struct name.
  """

pub struct Zap.ParametricAdapterTest {
  use Zest.Case

  describe("concrete Enumerable adapter driven via Enum") {
    test("Enum.to_list drains a concrete adapter") {
      drained = Enum.to_list(%ConcreteAdapter{source: [10, 20, 30]})
      assert(List.length(drained) == 3)
      assert(List.head(drained) == 10)
      assert(List.last(drained) == 30)
    }

    test("Enum.map transforms a concrete adapter") {
      mapped = Enum.map(%ConcreteAdapter{source: [1, 2, 3]}, double)
      assert(List.length(mapped) == 3)
      assert(List.head(mapped) == 2)
      assert(List.last(mapped) == 6)
    }
  }

  describe("parametric Enumerable adapter driven via Enum") {
    test("Enum.to_list drains the parametric adapter at i64") {
      drained = Enum.to_list(%Adapter(i64){source: [1, 2, 3]})
      assert(List.length(drained) == 3)
      assert(List.head(drained) == 1)
      assert(List.last(drained) == 3)
    }

    test("Enum.map transforms the parametric adapter at i64") {
      mapped = Enum.map(%Adapter(i64){source: [4, 5, 6]}, double)
      assert(List.length(mapped) == 3)
      assert(List.head(mapped) == 8)
      assert(List.last(mapped) == 12)
    }

    test("Enum.to_list drains the parametric adapter at String") {
      drained = Enum.to_list(%Adapter(String){source: ["a", "b", "c"]})
      assert(List.length(drained) == 3)
      assert(List.head(drained) == "a")
      assert(List.last(drained) == "c")
    }
  }

  fn double(value :: i64) -> i64 {
    value * 2
  }
}

@doc = """
  A CONCRETE (non-parametric) iterating adapter: a field-only struct
  wrapping a boxed `Enumerable(i64)` source. Exercises the boxed-
  existential-field adapter shape without generics, so the regression
  pins that `Enum`-driven adapters work whether or not the adapter
  itself is parametric.
  """

pub struct ConcreteAdapter {
  source :: Enumerable(i64)
}

@doc = """
  `Enumerable` implementation for the concrete adapter. A concrete
  receiver may dispatch inline on its boxed field, so no helper routing
  is needed.
  """

pub impl Enumerable(i64) for ConcreteAdapter {
  @doc = """
    Advances the wrapped source by one element, re-boxing the remaining
    source into a fresh adapter state.
    """

  pub fn next(self :: unique ConcreteAdapter) -> {Atom, i64, ConcreteAdapter} {
    case Enumerable.next(self.source) {
      {:done, d, exhausted} -> {:done, d, %ConcreteAdapter{source: exhausted}}
      {:cont, item, rest} -> {:cont, item, %ConcreteAdapter{source: rest}}
    }
  }

  @doc = """
    Releases the wrapped source when a caller stops iterating early.
    """

  pub fn dispose(self :: unique ConcreteAdapter) -> Nil {
    Enumerable.dispose(self.source)
    nil
  }
}

@doc = """
  A PARAMETRIC iterating adapter: a field-only generic struct
  `Adapter(element)` wrapping a boxed `Enumerable(element)` source. This
  is the exact shape that failed ZIR emission under `zap test` before
  the `type_args` round-trip fix — the same shape the forthcoming
  `Stream.transform` combinator returns.
  """

pub struct Adapter(element) {
  source :: Enumerable(element)
}

@doc = """
  `Enumerable` implementation for the parametric adapter — a
  parametric-target impl (`impl Enumerable(element) for Adapter(element)`)
  whose monomorphized method instances must be emitted in the Zest
  compile path exactly as in script mode. Inline protocol dispatch on a
  boxed parametric field is rejected, so `next`/`dispose` route through
  the impl's private `step`/`drop_source` helpers.
  """

pub impl Enumerable(element) for Adapter(element) {
  fn step(source :: unique Enumerable(element)) -> {Atom, element, Adapter(element)} {
    case Enumerable.next(source) {
      {:done, d, exhausted} -> {:done, d, %Adapter(element){source: exhausted}}
      {:cont, item, rest} -> {:cont, item, %Adapter(element){source: rest}}
    }
  }

  fn drop_source(source :: unique Enumerable(element)) -> Nil {
    Enumerable.dispose(source)
    nil
  }

  @doc = """
    Advances the wrapped source by one element, re-boxing the remaining
    source into a fresh adapter state.
    """

  pub fn next(self :: unique Adapter(element)) -> {Atom, element, Adapter(element)} {
    Adapter.step(self.source)
  }

  @doc = """
    Releases the wrapped source when a caller stops iterating early.
    """

  pub fn dispose(self :: unique Adapter(element)) -> Nil {
    Adapter.drop_source(self.source)
    nil
  }
}
