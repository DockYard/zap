pub struct BooleanTest {
  use Zest.Case

  describe("booleans") {
    test("true equals true") {
      assert(true == true)
    }

    test("false does not equal true") {
      reject(false == true)
    }

    test("false equals false") {
      assert(false == false)
    }

    test("greater than produces true") {
      assert((5 > 3) == true)
    }

    test("less than produces false") {
      assert((3 > 5) == false)
    }

    test("equality produces true") {
      assert((5 == 5) == true)
    }

    test("inequality produces true") {
      assert((5 != 3) == true)
    }

    test("and with both true") {
      assert(true and true)
    }

    test("and with true and false") {
      reject(true and false)
    }

    test("and with false and true") {
      reject(false and true)
    }

    test("or with true and false") {
      assert(true or false)
    }

    test("or with false and true") {
      assert(false or true)
    }

    test("or with both false") {
      reject(false or false)
    }
  }

  # ------------------------------------------------------------------
  # Short-circuit single-evaluation regression tests (stdlib-core--01)
  #
  # The `or`/`and` operator macros must evaluate their left operand
  # EXACTLY ONCE. A prior defect expanded `a or b` to a form that
  # mentioned `a` twice (`case a { false -> b; _ -> a }`), so a truthy
  # left operand with a side effect ran twice.
  #
  # Zap user code is purely immutable, so the only deterministic,
  # memory-manager-independent way to observe how many times an operand
  # is evaluated is through a real side effect: each evaluation of the
  # left operand appends one byte to a counter file, and the test reads
  # the file length afterward. One byte == one evaluation; two bytes ==
  # the double-evaluation bug. A second file tracks the right operand so
  # short-circuit behavior (right NOT evaluated when the left
  # short-circuits) is asserted directly.
  # ------------------------------------------------------------------
  describe("short-circuit single evaluation") {
    test("or evaluates a truthy left operand exactly once") {
      left_path = "zap_sc_or_truthy_left.tmp"
      right_path = "zap_sc_or_truthy_right.tmp"
      reset_counter(left_path)
      reset_counter(right_path)

      result = record_and_return(left_path, true) or record_and_return(right_path, true)

      # `or` returns the truthy left operand and short-circuits.
      assert(result == true)
      # Left operand evaluated exactly once (the bug made this 2).
      assert(eval_count(left_path) == 1)
      # Right operand NOT evaluated — left was truthy.
      assert(eval_count(right_path) == 0)

      clear_counter(left_path)
      clear_counter(right_path)
    }

    test("or evaluates a falsy left operand once and then the right") {
      left_path = "zap_sc_or_falsy_left.tmp"
      right_path = "zap_sc_or_falsy_right.tmp"
      reset_counter(left_path)
      reset_counter(right_path)

      result = record_and_return(left_path, false) or record_and_return(right_path, true)

      # `or` returns the right operand when the left is falsy.
      assert(result == true)
      # Left operand evaluated exactly once.
      assert(eval_count(left_path) == 1)
      # Right operand evaluated exactly once (left did not short-circuit).
      assert(eval_count(right_path) == 1)

      clear_counter(left_path)
      clear_counter(right_path)
    }

    test("and evaluates a truthy left operand once and then the right") {
      left_path = "zap_sc_and_truthy_left.tmp"
      right_path = "zap_sc_and_truthy_right.tmp"
      reset_counter(left_path)
      reset_counter(right_path)

      result = record_and_return(left_path, true) and record_and_return(right_path, false)

      # `and` returns the right operand when the left is truthy.
      assert(result == false)
      # Left operand evaluated exactly once.
      assert(eval_count(left_path) == 1)
      # Right operand evaluated exactly once (left did not short-circuit).
      assert(eval_count(right_path) == 1)

      clear_counter(left_path)
      clear_counter(right_path)
    }

    test("and evaluates a falsy left operand once and short-circuits") {
      left_path = "zap_sc_and_falsy_left.tmp"
      right_path = "zap_sc_and_falsy_right.tmp"
      reset_counter(left_path)
      reset_counter(right_path)

      result = record_and_return(left_path, false) and record_and_return(right_path, true)

      # `and` returns the falsy left operand and short-circuits.
      assert(result == false)
      # Left operand evaluated exactly once.
      assert(eval_count(left_path) == 1)
      # Right operand NOT evaluated — left was falsy.
      assert(eval_count(right_path) == 0)

      clear_counter(left_path)
      clear_counter(right_path)
    }
  }

  describe("macro hygiene") {
    test("or does not capture a user variable named like its temporary") {
      # The fixed `or` macro binds its left operand to a hygienic
      # temporary before branching. A user binding that happens to share
      # that internal name must remain its own distinct binding: if the
      # macro-introduced temporary captured this `short_circuit_value`,
      # the `false or true` expansion would rebind it to its left operand
      # (`false`) and the assertion below would fail.
      short_circuit_value = true
      result = false or true
      assert(result == true)
      assert(short_circuit_value == true)
    }

    test("and does not capture a user variable named like its temporary") {
      short_circuit_value = false
      result = true and true
      assert(result == true)
      assert(short_circuit_value == false)
    }
  }

  describe("more booleans") {
    test("check_positive with positive number") {
      assert(check_positive(5) == "positive")
    }

    test("check_positive with negative number") {
      assert(check_positive(-3) == "not positive")
    }
  }

  describe("negate/1") {
    test("will negate bool") {
      assert(Bool.negate(false))
      reject(Bool.negate(true))
    }
  }

  fn check_positive(x :: i64) -> String {
    case x > 0 {
      true -> "positive"
      false -> "not positive"
    }
  }

  # Counter helpers for the short-circuit single-evaluation tests.
  # Each evaluation of `record_and_return` appends exactly one byte to
  # the counter file at `path`; `eval_count` reports the number of
  # evaluations as that file's length. File I/O is the only
  # deterministic, memory-manager-independent observable side effect
  # available to immutable Zap user code, so it is what lets the test
  # distinguish a single evaluation from a double evaluation.

  fn reset_counter(path :: String) -> Bool {
    File.rm(path)
  }

  fn clear_counter(path :: String) -> Bool {
    File.rm(path)
  }

  fn record_and_return(path :: String, return_value :: Bool) -> Bool {
    existing = File.read(path)
    File.write(path, existing <> "x")
    return_value
  }

  fn eval_count(path :: String) -> i64 {
    String.length(File.read(path))
  }
}
