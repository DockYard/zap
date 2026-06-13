pub struct UnionTest {
  use Zest.Case

  pub union Color {
    Red,
    Green,
    Blue
  }

  pub union CatchallShape(t) {
    Circle :: t
    Square :: t
    Triangle :: t
  }

  describe("unions") {
    test("Red variant name") {
      assert(color_name(Color.Red) == "red")
    }

    test("Green variant name") {
      assert(color_name(Color.Green) == "green")
    }

    test("Blue variant name") {
      assert(color_name(Color.Blue) == "blue")
    }
  }

  fn color_name(Color.Red :: Color) -> String {
    "red"
  }

  fn color_name(Color.Green :: Color) -> String {
    "green"
  }

  fn color_name(Color.Blue :: Color) -> String {
    "blue"
  }

  describe("Lists of enums") {
    test("list of colors length") {
      assert(color_list_length() == 3)
    }

    test("head of color list used in dispatch") {
      assert(first_color_name() == "red")
    }
  }

  fn color_list_length() -> i64 {
    colors = [Color.Red, Color.Green, Color.Blue]
    List.length(colors)
  }

  fn first_color_name() -> String {
    colors = [Color.Red, Color.Green, Color.Blue]
    first = List.head(colors)
    color_name(first)
  }

  describe("Maps of enums") {
    test("map with enum values size") {
      assert(color_map_size() == 2)
    }
  }

  fn color_map_size() -> i64 {
    favorites = %{first: Color.Red, second: Color.Blue}
    Map.size(favorites)
  }

  # ----------------------------------------------------------------------
  # Regression coverage for the `union_switch.else_instrs` (catch-all `_` arm)
  # ARC traversal defect (audit findings arc-drop-verify--01, arc-liveness--01,
  # arc-own-1--01, arc-own-2--01, uniqueness--01).
  #
  # A `case` over a tagged union with a real `_` catch-all arm lowers to a
  # `union_switch` with `has_else == true` and a non-empty `else_instrs` body.
  # The arc_liveness analyzer numbers that body into the `InstructionId` space,
  # but every other ARC/ownership/uniqueness/verifier walker historically
  # recursed only into `cases` and SKIPPED `else_instrs`. Two corruptions
  # followed for any function containing such a `case`:
  #   1. Every instruction AFTER the `union_switch` in flatten order was
  #      mis-keyed by the size of the skipped else-subtree, so scope-exit drops
  #      either vanished (leak) or fired against the wrong terminator's live set
  #      (premature free / double-free / use-after-free).
  #   2. The catch-all body itself was never analyzed, normalized, drop-inserted,
  #      or verified — its ARC `local_get`/retain pairs got no scope-exit release.
  #
  # These tests build ARC-managed values (String/List/Map) inside catch-all arms,
  # return a borrowed parameter from a catch-all arm, and hold an ARC local across
  # the `case`. They must FAIL before the canonical-enumerator fix (wrong values /
  # crash / leak) and PASS after it. The `assert_no_leaks` blocks make the omitted
  # scope-exit releases observable under `Memory.Tracking`; they are a documented
  # no-op under the refcounted `Memory.ARC` corpus manager.
  describe("catch-all arm over a tagged union — functional correctness") {
    test("catch-all builds an ARC String and the post-case local survives") {
      assert(UnionTest.label_or_default(CatchallShape(i64).Triangle(7)) == "many-sided")
      assert(UnionTest.label_or_default(CatchallShape(i64).Circle(1)) == "round")
    }

    test("post-case ARC local is read correctly after a catch-all hit") {
      assert(UnionTest.tag_then_keep(CatchallShape(i64).Triangle(7)) == "kept")
      assert(UnionTest.tag_then_keep(CatchallShape(i64).Circle(1)) == "kept")
    }

    test("catch-all arm returns a borrowed parameter") {
      assert(UnionTest.describe_or_fallback(CatchallShape(i64).Triangle(7), "fallback-text") == "fallback-text")
      assert(UnionTest.describe_or_fallback(CatchallShape(i64).Circle(1), "fallback-text") == "circle")
    }

    test("catch-all builds an ARC List and returns its length") {
      assert(UnionTest.elements_or_pair(CatchallShape(i64).Triangle(7)) == 2)
      assert(UnionTest.elements_or_pair(CatchallShape(i64).Circle(1)) == 1)
    }

    test("catch-all builds an ARC Map and returns its size") {
      assert(UnionTest.attrs_or_default(CatchallShape(i64).Triangle(7)) == 2)
      assert(UnionTest.attrs_or_default(CatchallShape(i64).Circle(1)) == 1)
    }
  }

  describe("catch-all arm over a tagged union — leak freedom") {
    test("ARC String built in a catch-all arm is released (no leak)") {
      assert_no_leaks {
        held = "outer-string-held-across-case"
        result = UnionTest.label_or_default(CatchallShape(i64).Triangle(7))
        assert(result == "many-sided")
        assert(String.length(held) == 29)
      }
    }

    test("ARC List built in a catch-all arm is released (no leak)") {
      assert_no_leaks {
        held = [10, 20, 30]
        count = UnionTest.elements_or_pair(CatchallShape(i64).Triangle(7))
        assert(count == 2)
        assert(List.length(held) == 3)
      }
    }

    test("ARC Map built in a catch-all arm is released (no leak)") {
      assert_no_leaks {
        held = %{alpha: 1, beta: 2}
        size = UnionTest.attrs_or_default(CatchallShape(i64).Triangle(7))
        assert(size == 2)
        assert(Map.size(held) == 2)
      }
    }

    test("borrowed-parameter return from a catch-all arm is balanced (no leak)") {
      assert_no_leaks {
        outer = "the-fallback"
        picked = UnionTest.describe_or_fallback(CatchallShape(i64).Triangle(7), outer)
        assert(picked == "the-fallback")
      }
    }
  }

  # Matches the two payload-bearing variants explicitly; everything else
  # (Triangle, here) falls through to the `_` catch-all, which yields a fresh
  # ARC String. The post-case `kept` local forces the analyzer to track an ARC
  # value live across the whole `union_switch`.
  fn label_or_default(shape :: CatchallShape(i64)) -> String {
    kept = "round"
    label = case shape {
      CatchallShape.Circle(_) -> "round"
      CatchallShape.Square(_) -> "square"
      _ -> "many-sided"
    }
    case shape {
      CatchallShape.Circle(_) -> kept
      _ -> label
    }
  }

  # Holds an ARC String local (`kept`) ACROSS the case and reads it afterwards.
  # The catch-all arm builds a throwaway ARC String, so the else prong has its
  # own ARC bookkeeping that must be normalized and drop-balanced.
  fn tag_then_keep(shape :: CatchallShape(i64)) -> String {
    kept = "kept"
    _tag = case shape {
      CatchallShape.Circle(_) -> "c"
      CatchallShape.Square(_) -> "s"
      _ -> "t" <> "riangle"
    }
    kept
  }

  # The `_` arm returns the BORROWED `fallback` parameter. The named arms build
  # fresh ARC Strings. Returning a borrowed parameter from the else prong is the
  # exact return-source borrow shape the audit calls out.
  fn describe_or_fallback(shape :: CatchallShape(i64), fallback :: String) -> String {
    case shape {
      CatchallShape.Circle(_) -> "circle"
      CatchallShape.Square(_) -> "square"
      _ -> fallback
    }
  }

  # The `_` arm builds a fresh ARC List of two elements inside the catch-all
  # body and yields its length; the named arm builds a one-element list.
  # Building and consuming a List inside the else prong forces the prong's ARC
  # bookkeeping (the list-init owner and its scope-exit release) to be analyzed
  # and drop-balanced.
  fn elements_or_pair(shape :: CatchallShape(i64)) -> i64 {
    case shape {
      CatchallShape.Circle(_) -> {
        single = [1]
        List.length(single)
      }
      _ -> {
        pair = [1, 2]
        List.length(pair)
      }
    }
  }

  # The `_` arm builds a fresh ARC Map of two entries inside the catch-all body
  # and yields its size; the named arm builds a one-entry map.
  fn attrs_or_default(shape :: CatchallShape(i64)) -> i64 {
    case shape {
      CatchallShape.Circle(_) -> {
        one = %{sides: 0}
        Map.size(one)
      }
      _ -> {
        two = %{sides: 3, name: 99}
        Map.size(two)
      }
    }
  }
}
