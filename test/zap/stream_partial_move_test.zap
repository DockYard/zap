@doc = """
  Regression coverage for the boxed-existential-field partial-move
  double-free. A struct that stores a concrete-parametric protocol box
  field (`Enumerable(i64)`) and then CONSUMES it — passing `self.field`
  to a `unique`-receiver dispatch or a `unique`-parameter function —
  partially moves that field out. The compiler does not track per-field
  moves, so the struct's scope-exit whole-struct drop would re-release the
  moved box (a double free), and a box-only / box+scalar struct would be
  misclassified non-owning and LEAK its other owned fields.

  The fix classifies a concrete-parametric protocol box FIELD as
  ARC-managed (so the struct drops) and routes every consumed / re-stored
  box-field extraction through the manager-adaptive clone-on-share (so the
  consumed value owns an independent inner and the parent's field is
  released exactly once). These structs deliberately mirror the Stream
  stdlib `Stream.Transform` adapter but use only the language surface — no stdlib
  Stream name — so the coverage is general.
  """

# (i) Boxed source + a bare refcounted List sibling field.
pub struct ListSiblingAdapter {
  source :: Enumerable(i64)
  pending :: [i64]
}

pub impl Enumerable(i64) for ListSiblingAdapter {
  pub fn next(adapter :: unique ListSiblingAdapter) -> {Atom, i64, ListSiblingAdapter} {
    case Enumerable.next(adapter.source) {
      {:done, _, exhausted} -> {:done, 0, %ListSiblingAdapter{source: exhausted, pending: adapter.pending}}
      {:cont, item, next_source} -> {:cont, item, %ListSiblingAdapter{source: next_source, pending: adapter.pending}}
    }
  }

  pub fn dispose(adapter :: unique ListSiblingAdapter) -> Nil {
    Enumerable.dispose(adapter.source)
    nil
  }
}

# (iii) Stream.Transform-like: TWO boxed existential fields + a bare List buffer.
pub struct TransformLike {
  source :: Enumerable(i64)
  stage :: Enumerable(i64)
  pending :: [i64]
}

pub impl Enumerable(i64) for TransformLike {
  pub fn next(transform :: unique TransformLike) -> {Atom, i64, TransformLike} {
    case Enumerable.next(transform.source) {
      {:done, _, exhausted} -> {:done, 0, %TransformLike{source: exhausted, stage: transform.stage, pending: transform.pending}}
      {:cont, item, next_source} -> {:cont, item, %TransformLike{source: next_source, stage: transform.stage, pending: transform.pending}}
    }
  }

  pub fn dispose(transform :: unique TransformLike) -> Nil {
    Enumerable.dispose(transform.source)
    Enumerable.dispose(transform.stage)
    nil
  }
}

# (iv) General partial-move: a box field moved into a consuming FUNCTION
# (call_direct with a `unique` box parameter), the wrapper then dropped.
pub struct BoxOnlyWrapper {
  inner :: Enumerable(i64)
}

pub struct Zap.StreamPartialMoveTest {
  use Zest.Case

  pub fn drain(stream :: unique Enumerable(i64)) -> i64 {
    List.length(Enum.to_list(stream))
  }

  pub fn count_via_field(wrapper :: unique BoxOnlyWrapper) -> i64 {
    Zap.StreamPartialMoveTest.drain(wrapper.inner)
  }

  describe("boxed-existential field + bare List sibling (partial move via consuming dispatch)") {
    test("driven to :done through the Enumerable protocol") {
      adapter = %ListSiblingAdapter{source: [7, 8, 9], pending: [99]}
      collected = Enum.to_list(adapter)
      assert(List.length(collected) == 3)
      assert(List.head(collected) == 7)
    }

    test("early-disposed after a partial take") {
      adapter = %ListSiblingAdapter{source: [7, 8, 9], pending: [99]}
      taken = Enum.take(adapter, 1)
      assert(List.length(taken) == 1)
      assert(List.head(taken) == 7)
    }
  }

  describe("two boxed-existential fields + bare List buffer (Stream.Transform adapter shape)") {
    test("driven to :done carrying a second boxed existential and a List buffer") {
      transform = %TransformLike{source: [3, 4, 5], stage: [1, 2], pending: [0]}
      collected = Enum.to_list(transform)
      assert(List.length(collected) == 3)
      assert(List.head(collected) == 3)
    }

    test("early-disposed carrying a second boxed existential and a List buffer") {
      transform = %TransformLike{source: [3, 4, 5], stage: [1, 2], pending: [0]}
      taken = Enum.take(transform, 2)
      assert(List.length(taken) == 2)
    }
  }

  describe("general partial move: box field moved into a consuming function") {
    test("box field consumed by a unique-parameter function, wrapper then dropped") {
      wrapper = %BoxOnlyWrapper{inner: [10, 20, 30]}
      total = Zap.StreamPartialMoveTest.count_via_field(wrapper)
      assert(total == 3)
    }
  }
}
