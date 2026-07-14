# Regression coverage for empty-list element-type inference in
# composite/expected-typed return positions (the Stage/Filter shape).
#
# An empty list literal `[]` appearing where the expected type is
# `[SomeElement]` — from a declared composite return annotation, or from
# unifying with a sibling `if`/`else`/`case` arm — must take the EXPECTED
# element type, NOT default to `i64`. Before the fix, a stage whose one arm
# yielded `{..., [], ...}` lowered that `[]` to `List(i64)`, conflicting with
# the sibling arm's concrete `List(String)` (or `List(Marker)`,
# `List({Atom, i64})`, …) and failing to compile.

pub protocol EmptyListStage(input, output) {
  @doc = """
    Advance a stage by one item, yielding a control atom, the produced
    outputs (possibly `[]`), and the next stage. The `[output]` slot is the
    inference site under test — one arm produces `[]`.
    """

  fn run_step(stage :: unique EmptyListStage(input, output), item :: input) -> {Atom, [output], EmptyListStage(input, output)}
}

@doc = """
  A user struct used as a list element type, to prove empty-list inference
  works for element types that are user-defined structs (not just String).
  """

pub struct Marker {
  id :: i64
}

@doc = """
  A stage whose output element type is `String`. Its `false` branch yields
  the empty list — the reproducer #1 (Filter) shape.
  """

pub struct StringFilter {
  keep_flag :: Bool
}

pub impl EmptyListStage(String, String) for StringFilter {
  @doc = """
    Keep-branch yields `[item]` (`List(String)`); drop-branch yields `[]`,
    which must infer `List(String)` from the declared return, not `List(i64)`.
    """

  pub fn run_step(stage :: unique StringFilter, item :: String) -> {Atom, [String], StringFilter} {
    if stage.keep_flag {
      {:cont, [item], stage}
    } else {
      {:cont, [], stage}
    }
  }
}

@doc = """
  A stage whose output element type is the user struct `Marker`. Proves the
  empty-list inference is general over any element type, not just String.
  """

pub struct MarkerFilter {
  keep_flag :: Bool
}

pub impl EmptyListStage(i64, Marker) for MarkerFilter {
  @doc = """
    Keep-branch yields `[%Marker{...}]` (`List(Marker)`); drop-branch yields
    `[]`, which must infer `List(Marker)` from the declared return.
    """

  pub fn run_step(stage :: unique MarkerFilter, item :: i64) -> {Atom, [Marker], MarkerFilter} {
    if stage.keep_flag {
      {:cont, [%Marker{id: item}], stage}
    } else {
      {:cont, [], stage}
    }
  }
}

pub struct EmptyListInferenceTest {
  use Zest.Case

  describe("if/else arm-join in a composite return with an empty arm") {
    test("String element: drop-branch empty list has element type String, length 0") {
      probe = %StringFilter{keep_flag: false}
      result = EmptyListStage.run_step(probe, "keep-me")
      assert(result.0 == :cont)
      assert(List.length(result.1) == 0)
    }

    test("String element: keep-branch preserves the concrete String output") {
      probe = %StringFilter{keep_flag: true}
      result = EmptyListStage.run_step(probe, "keep-me")
      outputs = result.1
      assert(result.0 == :cont)
      assert(List.length(outputs) == 1)
      assert(List.head(outputs) == "keep-me")
    }

    test("user-struct element: drop-branch empty list infers List(Marker)") {
      probe = %MarkerFilter{keep_flag: false}
      result = EmptyListStage.run_step(probe, 42)
      assert(List.length(result.1) == 0)
    }

    test("user-struct element: keep-branch preserves the concrete Marker output") {
      probe = %MarkerFilter{keep_flag: true}
      result = EmptyListStage.run_step(probe, 42)
      outputs = result.1
      assert(List.length(outputs) == 1)
      marker = List.head(outputs)
      assert(marker.id == 42)
    }

    test("tuple element: [{Atom, i64}] with an empty done-arm (reproducer #2)") {
      done = EmptyListInferenceTest.produce_pairs(false)
      assert(done.0 == :done)
      assert(List.length(done.1) == 0)
      assert(done.2 == 0)

      more = EmptyListInferenceTest.produce_pairs(true)
      pairs = more.1
      assert(more.0 == :more)
      assert(List.length(pairs) == 2)
      assert(more.2 == 1)
      first = List.head(pairs)
      assert(first.0 == :even)
      assert(first.1 == 2)
    }
  }

  describe("direct single return of a composite containing an empty list") {
    test("always-empty branch: [] infers List(String) from the declared return") {
      result = EmptyListInferenceTest.always_empty("ignored")
      assert(result.0 == :cont)
      assert(List.length(result.1) == 0)
      assert(result.2 == 7)
    }
  }

  describe("nested composite where the list element is itself a tuple") {
    test("done-arm [] infers List({Atom, i64}) inside {Atom, [{Atom, i64}], Marker}") {
      done = EmptyListInferenceTest.produce_nested(false)
      assert(done.0 == :done)
      assert(List.length(done.1) == 0)
      marker = done.2
      assert(marker.id == 99)

      more = EmptyListInferenceTest.produce_nested(true)
      assert(List.length(more.1) == 1)
    }
  }

  describe("case arm-join (not if/else) yielding an empty list") {
    test("empty done-arm nested in a tuple infers List(String)") {
      done = EmptyListInferenceTest.case_join(0)
      assert(done.0 == :done)
      assert(List.length(done.1) == 0)

      cont = EmptyListInferenceTest.case_join(5)
      outputs = cont.1
      assert(cont.0 == :cont)
      assert(List.length(outputs) == 1)
      assert(List.head(outputs) == "a")
    }
  }

  describe("bare empty-list whole return (sanity)") {
    test("[] returned directly for a [String] function is List(String)") {
      assert(List.length(EmptyListInferenceTest.bare_empty()) == 0)
    }
  }

  fn produce_pairs(flag :: Bool) -> {Atom, [{Atom, i64}], i64} {
    if flag {
      {:more, [{:even, 2}, {:odd, 3}], 1}
    } else {
      {:done, [], 0}
    }
  }

  fn always_empty(item :: String) -> {Atom, [String], i64} {
    {:cont, [], 7}
  }

  fn produce_nested(flag :: Bool) -> {Atom, [{Atom, i64}], Marker} {
    marker = %Marker{id: 99}
    if flag {
      {:more, [{:even, 2}], marker}
    } else {
      {:done, [], marker}
    }
  }

  fn case_join(n :: i64) -> {Atom, [String]} {
    case n {
      0 -> {:done, []}
      _ -> {:cont, ["a"]}
    }
  }

  fn bare_empty() -> [String] {
    []
  }
}
