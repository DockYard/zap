@doc = """
  Regression coverage for parametric-protocol vtable synthesis with
  COMPOSITE method signatures (the `anytype`-slot defect).

  Boxing a parametric protocol as an existential synthesizes a
  per-instantiation vtable whose method slots substitute the protocol's
  formal type parameters with the instantiation's concrete types. The
  substitution must recurse through composite annotations — tuples
  containing a formal, lists of a formal, and nested applications of the
  protocol itself (which lower to the boxed representation). A
  user-defined protocol (deliberately NOT `Enumerable`) proves the fix
  is general rather than keyed to any stdlib name.
  """

pub struct Zap.ProtocolBoxCompositeTest {
  use Zest.Case

  describe("boxed parametric protocol with composite signatures") {
    test("tuple-of-formal slot substitutes and dispatches through the box") {
      emitter = Zap.ProtocolBoxCompositeTest.make_counter_emitter()
      assert(Zap.ProtocolBoxCompositeTest.first_emitted(emitter) == 7)
    }

    test("nested self-application slot re-boxes the advanced state") {
      emitter = Zap.ProtocolBoxCompositeTest.make_counter_emitter()
      assert(Zap.ProtocolBoxCompositeTest.second_emitted(emitter) == 8)
    }

    test("list-of-formal slot substitutes concretely") {
      emitter = Zap.ProtocolBoxCompositeTest.make_counter_emitter()
      batch = Zap.ProtocolBoxCompositeTest.batch_of(emitter)
      assert(List.length(batch) == 2)
      assert(List.head(batch) == 7)
      assert(List.last(batch) == 8)
    }

    test("boxed emitter drives to completion through a struct field") {
      carrier = %EmitterCarrier{source: Zap.ProtocolBoxCompositeTest.make_counter_emitter()}
      total = Zap.ProtocolBoxCompositeTest.drain_total(carrier.source, 0)
      assert(total == 15)
    }
  }

  describe("multi-formal boxed parametric protocol") {
    test("two formals interleaved with a container in one tuple slot dispatch twice") {
      weaver = Zap.ProtocolBoxCompositeTest.make_label_weaver()
      total = Zap.ProtocolBoxCompositeTest.weave_twice(weaver)
      assert(total == 34)
    }
  }

  fn make_counter_emitter() -> Emitter(i64) {
    %CountingEmitter{current: 7, remaining: 2}
  }

  fn first_emitted(state :: unique Emitter(i64)) -> i64 {
    case Emitter.emit(state) {
      {:more, value, next_state} -> dispose_emitter_and_return(next_state, value)
      {:stop, _, _} -> -1
    }
  }

  fn second_emitted(state :: unique Emitter(i64)) -> i64 {
    case Emitter.emit(state) {
      {:more, _, next_state} -> first_emitted(next_state)
      {:stop, _, _} -> -1
    }
  }

  fn batch_of(state :: unique Emitter(i64)) -> [i64] {
    Emitter.batch(state)
  }

  fn drain_total(state :: unique Emitter(i64), total :: i64) -> i64 {
    case Emitter.emit(state) {
      {:more, value, next_state} -> drain_total(next_state, total + value)
      {:stop, _, final_state} -> dispose_emitter_and_return(final_state, total)
    }
  }

  fn dispose_emitter_and_return(state :: unique Emitter(element), value :: result) -> result {
    Emitter.finish(state)
    value
  }

  fn make_label_weaver() -> Weaver(String, i64) {
    %LabelCounter{label: "tick", counter: 5}
  }

  fn weave_twice(state :: unique Weaver(String, i64)) -> i64 {
    case Weaver.weave(state) {
      {label, values, next_state} -> weave_second(label, values, next_state)
    }
  }

  fn weave_second(label :: String, values :: [i64], state :: unique Weaver(String, i64)) -> i64 {
    case Weaver.weave(state) {
      {label2, values2, next_state} -> halt_and_sum(label, label2, values, values2, next_state)
    }
  }

  fn halt_and_sum(label :: String, label2 :: String, values :: [i64], values2 :: [i64], state :: unique Weaver(String, i64)) -> i64 {
    Weaver.halt(state)
    String.length(label) + String.length(label2) + List.head(values) + List.last(values) + List.head(values2) + List.last(values2)
  }
}

@doc = """
  A user-defined parametric protocol whose method signatures exercise
  every composite substitution shape: `emit` returns a tuple containing
  the bare formal AND a nested self-application (`Emitter(element)` —
  the boxed representation inside its own vtable); `batch` returns a
  list of the formal; `finish` consumes the receiver.
  """

pub protocol Emitter(element) {
  fn emit(state :: unique Emitter(element)) -> {Atom, element, Emitter(element)}
  fn batch(state :: unique Emitter(element)) -> [element]
  fn finish(state :: unique Emitter(element)) -> Nil
}

@doc = """
  Concrete emitter state: yields `current`, `current + 1`, ... while
  `remaining` counts down; stops with a zero value once exhausted.
  """

pub struct CountingEmitter {
  current :: i64
  remaining :: i64
}

@doc = """
  A struct field carrying the boxed existential — exercises boxing in
  field position in addition to return/argument positions.
  """

pub struct EmitterCarrier {
  source :: Emitter(i64)
}

@doc = """
  `Emitter` implementation for `CountingEmitter` — a concrete-target
  impl of a parametric protocol whose composite return slots must
  bridge concrete state to the boxed representation.
  """

pub impl Emitter(i64) for CountingEmitter {
  @doc = """
    Yields the current value and the advanced emitter, or stops when
    no values remain.
    """

  pub fn emit(state :: unique CountingEmitter) -> {Atom, i64, CountingEmitter} {
    if state.remaining > 0 {
      {:more, state.current, %CountingEmitter{current: state.current + 1, remaining: state.remaining - 1}}
    } else {
      {:stop, state.current, state}
    }
  }

  @doc = """
    Returns the remaining values as a list without consuming them one
    at a time.
    """

  pub fn batch(state :: unique CountingEmitter) -> [i64] {
    if state.remaining >= 2 {
      [state.current, state.current + 1]
    } else {
      if state.remaining == 1 { [state.current] } else { [] }
    }
  }

  @doc = """
    Disposes an emitter state. Counting emitters own no resources, so
    disposal is a no-op.
    """

  pub fn finish(_state :: unique CountingEmitter) -> Nil {
    nil
  }
}

@doc = """
  A MULTI-FORMAL parametric protocol (two type parameters interleaved
  with a container in one tuple slot). Exercises formal substitution
  across several formals at once AND the tuple-extraction ownership of
  a dispatch result that carries an ARC container (`[b]`) NEXT TO the
  boxed next state — the shape whose box component must not be swept
  into the sibling container's aggregate-component release.
  """

pub protocol Weaver(a, b) {
  fn weave(state :: unique Weaver(a, b)) -> {a, [b], Weaver(a, b)}
  fn halt(state :: unique Weaver(a, b)) -> Nil
}

@doc = """
  Concrete weaver state: a `String` label paired with a counting
  cursor, so both formals bind to distinct concrete types.
  """

pub struct LabelCounter {
  label :: String
  counter :: i64
}

@doc = """
  `Weaver` implementation for `LabelCounter` — each step yields the
  label, a two-element window over the counter, and the advanced
  state re-boxed through the consuming receiver's cell.
  """

pub impl Weaver(String, i64) for LabelCounter {
  @doc = """
    Yields the label, the current counter window, and the advanced
    weaver state.
    """

  pub fn weave(state :: unique LabelCounter) -> {String, [i64], LabelCounter} {
    {state.label, [state.counter, state.counter + 1], %LabelCounter{label: state.label, counter: state.counter + 2}}
  }

  @doc = """
    Disposes a weaver state. Label counters own no cursor resources,
    so disposal is a no-op.
    """

  pub fn halt(_state :: unique LabelCounter) -> Nil {
    nil
  }
}
