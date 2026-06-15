pub struct PatternMatchingTest {
  use Zest.Case

  describe("pattern matching") {
    test("matches ok atom to success") {
      assert(describe(:ok) == "success")
    }

    test("matches error atom to failure") {
      assert(describe(:error) == "failure")
    }

    test("matches wildcard atom to unknown") {
      assert(describe(:other) == "unknown")
    }
  }

  describe("list cons vs fixed-length pattern dispatch") {
    # Regression for audit finding hir-1--01 / TY-01: a fixed-length list
    # row (`[x]`) declared BEFORE a cons row (`[h|t]`) must not be dropped
    # from the decision tree. Pre-fix, `[x]` vanished and `[5]` wrongly
    # matched the `[h|t]` arm (returning :many).
    test("single-element list matches the fixed-length arm, not the cons arm") {
      assert(classify_length([5]) == :one)
    }

    test("multi-element list falls through the fixed-length arm to the cons arm") {
      assert(classify_length([5, 6]) == :many)
    }

    test("empty list matches the wildcard arm") {
      assert(classify_length([]) == :none)
    }

    # The reversed declaration order must still be correct: the cons arm
    # declared first matches every non-empty list (first-match wins), so a
    # single-element list takes the cons arm here.
    test("cons arm declared first wins for a single-element list") {
      assert(classify_cons_first([5]) == :many)
    }

    test("cons arm declared first still lets the empty list reach the wildcard") {
      assert(classify_cons_first([]) == :none)
    }
  }

  describe("mixed head-count cons clause dispatch") {
    # Regression for audit finding hir-1--01 / TY-01 (misalignment half):
    # a two-head cons clause (`[a, b | t]`) declared before a one-head cons
    # clause (`[x | t]`) must dispatch each input at its correct head count.
    # Pre-fix, head_count was taken from the FIRST cons row only, so the
    # one-head row was expanded against a two-head scrutinee decomposition
    # and a single-element list spuriously failed to match.
    test("single-element list matches the one-head clause, not the two-head clause") {
      assert(head_kind([1]) == :single)
    }

    test("two-element list matches the two-head clause") {
      assert(head_kind([1, 2]) == :pair)
    }

    test("three-element list matches the two-head clause (open tail)") {
      assert(head_kind([1, 2, 3]) == :pair)
    }

    test("empty list matches the empty clause") {
      assert(head_kind([]) == :empty)
    }

    # The first two heads are bound correctly by the two-head clause even
    # when a longer list flows in — proves head/tail alignment, not just
    # arm selection.
    test("two-head clause binds the first two elements correctly") {
      assert(sum_first_two([10, 20, 30, 40]) == 30)
    }

    test("two-head clause binds exactly two elements for a two-element list") {
      assert(sum_first_two([7, 8]) == 15)
    }
  }

  describe("fixed-length multi-element list patterns mixed with cons") {
    test("exact two-element list matches the fixed-length-two arm") {
      assert(shape([1, 2]) == :pair_exact)
    }

    test("three-element list falls through to the cons arm") {
      assert(shape([1, 2, 3]) == :longer)
    }

    test("single-element list matches the fixed-length-one arm") {
      assert(shape([1]) == :one_exact)
    }
  }

  fn describe(:ok :: Atom) -> String {
    "success"
  }

  fn describe(:error :: Atom) -> String {
    "failure"
  }

  fn describe(_ :: Atom) -> String {
    "unknown"
  }

  # `[x]` (fixed length 1) BEFORE `[h | t]` (cons). The fixed-length arm
  # must win for a single-element list.
  fn classify_length(list :: [i64]) -> Atom {
    case list {
      [] -> :none
      [_x] -> :one
      [_h | _t] -> :many
    }
  }

  # `[h | t]` (cons) BEFORE the fixed-length-1 arm. First-match wins, so the
  # cons arm matches every non-empty list.
  fn classify_cons_first(list :: [i64]) -> Atom {
    case list {
      [] -> :none
      [_h | _t] -> :many
      [_x] -> :one
    }
  }

  # Two-head cons clause declared before a one-head cons clause, exercising
  # mixed head-count dispatch in multi-clause function heads.
  fn head_kind([] :: [i64]) -> Atom {
    :empty
  }

  fn head_kind([_a, _b | _t] :: [i64]) -> Atom {
    :pair
  }

  fn head_kind([_x | _t] :: [i64]) -> Atom {
    :single
  }

  # Binds the first two heads; the open tail absorbs any remaining elements.
  fn sum_first_two([a, b | _t] :: [i64]) -> i64 {
    a + b
  }

  fn sum_first_two(_other :: [i64]) -> i64 {
    0
  }

  # Fixed-length arms of distinct lengths mixed with an open cons arm.
  fn shape(list :: [i64]) -> Atom {
    case list {
      [_a] -> :one_exact
      [_a, _b] -> :pair_exact
      [_h | _t] -> :longer
    }
  }
}
