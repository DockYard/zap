pub struct TuringMachineTest {
  use Zest.Case

  describe("tape construction") {
    test("empty tape has blank under head") {
      {left, current, right, _blank} = TuringMachine.tape_new(([] :: [String]), "_")
      assert(current == "_")
      assert(List.empty?(left))
      assert(List.empty?(right))
    }

    test("non-empty tape places head on first symbol") {
      {left, current, right, _blank} = TuringMachine.tape_new(["1", "0", "1"], "_")
      assert(current == "1")
      assert(List.empty?(left))
      assert(List.length(right) == 2)
    }
  }

  describe("tape movement") {
    test("move_right pushes current onto left and pops from right") {
      moved = TuringMachine.move_right(TuringMachine.tape_new(["A", "B", "C"], "_"))
      {left, current, right, _blank} = moved
      assert(current == "B")
      assert(List.length(left) == 1)
      assert(List.length(right) == 1)
    }

    test("move_right past the end yields a blank cell") {
      {_left, current, _right, _blank} = TuringMachine.move_right(TuringMachine.tape_new(["A"], "_"))
      assert(current == "_")
    }

    test("move_left at the start yields a blank cell") {
      {_left, current, _right, _blank} = TuringMachine.move_left(TuringMachine.tape_new(["A"], "_"))
      assert(current == "_")
    }

    test("move_right then move_left returns to the original head") {
      round_trip = TuringMachine.move_left(TuringMachine.move_right(TuringMachine.tape_new(["A", "B", "C"], "_")))
      {_left, current, right, _blank} = round_trip
      assert(current == "A")
      assert(List.length(right) == 2)
    }

    test("write_tape only changes the current cell") {
      written = TuringMachine.write_tape(TuringMachine.tape_new(["A", "B"], "_"), "Z")
      {_left, current, right, _blank} = written
      assert(current == "Z")
      assert(List.length(right) == 1)
    }
  }

  describe("move_tape dispatch") {
    test("L moves left") {
      right = TuringMachine.move_right(TuringMachine.tape_new(["A", "B"], "_"))
      {_left, current, _right, _blank} = TuringMachine.move_tape(right, "L")
      assert(current == "A")
    }

    test("R moves right") {
      {_left, current, _right, _blank} = TuringMachine.move_tape(TuringMachine.tape_new(["A", "B"], "_"), "R")
      assert(current == "B")
    }

    test("S leaves the head in place") {
      {_left, current, _right, _blank} = TuringMachine.move_tape(TuringMachine.tape_new(["A", "B"], "_"), "S")
      assert(current == "A")
    }
  }

  describe("transition matching") {
    test("empty table halts the machine") {
      tape = TuringMachine.tape_new(["1"], "_")
      {state, _new_tape, halted} = TuringMachine.lookup_and_step("q0", tape, ([] :: [{String, String, String, String, String}]), ([] :: [{String, String, String, String, String}]))
      assert(state == "q0")
      assert(halted)
    }

    test("no matching row halts the machine") {
      tape = TuringMachine.tape_new(["1"], "_")
      transitions = ([] :: [{String, String, String, String, String}])
        |> List.push(TuringMachine.t("qX", "1", "qY", "0", "R"))
      {state, _new_tape, halted} = TuringMachine.lookup_and_step("q0", tape, transitions, transitions)
      assert(state == "q0")
      assert(halted)
    }

    test("matching row writes, moves, and changes state") {
      tape = TuringMachine.tape_new(["0"], "_")
      transitions = ([] :: [{String, String, String, String, String}])
        |> List.push(TuringMachine.t("q0", "0", "q1", "1", "R"))
      {state, moved_tape, halted} = TuringMachine.lookup_and_step("q0", tape, transitions, transitions)
      {_left, current, _right, _blank} = moved_tape
      assert(state == "q1")
      assert(halted == false)
      assert(current == "_")
    }

    test("first matching row wins") {
      tape = TuringMachine.tape_new(["1"], "_")
      transitions = ([] :: [{String, String, String, String, String}])
        |> List.push(TuringMachine.t("q0", "1", "first", "1", "R"))
        |> List.push(TuringMachine.t("q0", "1", "second", "1", "R"))
      {state, _new_tape, _halted} = TuringMachine.lookup_and_step("q0", tape, transitions, transitions)
      assert(state == "first")
    }
  }

  describe("run") {
    test("machine with no matching transition stops immediately") {
      tape = TuringMachine.tape_new(["1"], "_")
      {state, _final_tape, steps} = TuringMachine.run("q0", tape, ([] :: [{String, String, String, String, String}]), 0, 100)
      assert(state == "q0")
      assert(steps == 0)
    }

    test("max_steps caps a machine that cannot halt") {
      tape = TuringMachine.tape_new(["1"], "_")
      transitions = ([] :: [{String, String, String, String, String}])
        |> List.push(TuringMachine.t("q0", "1", "q0", "1", "R"))
      {_state, _final_tape, steps} = TuringMachine.run("q0", tape, transitions, 0, 5)
      assert(steps == 5)
    }
  }

  describe("binary increment") {
    test("0 + 1 = 1") {
      assert(TuringMachine.binary_increment("0") == "1")
    }

    test("1 + 1 = 10") {
      assert(TuringMachine.binary_increment("1") == "10")
    }

    test("10 + 1 = 11") {
      assert(TuringMachine.binary_increment("10") == "11")
    }

    test("1011 + 1 = 1100") {
      assert(TuringMachine.binary_increment("1011") == "1100")
    }

    test("11111 + 1 = 100000") {
      assert(TuringMachine.binary_increment("11111") == "100000")
    }

    test("100000 + 1 = 100001") {
      assert(TuringMachine.binary_increment("100000") == "100001")
    }
  }

  describe("unary doubler") {
    test("1 -> 2") {
      assert(TuringMachine.unary_double(1) == "11")
    }

    test("2 -> 4") {
      assert(TuringMachine.unary_double(2) == "1111")
    }

    test("3 -> 6") {
      assert(TuringMachine.unary_double(3) == "111111")
    }

    test("5 -> 10") {
      assert(TuringMachine.unary_double(5) == "1111111111")
    }
  }

  describe("rendering") {
    test("render_tape shows the head position in brackets") {
      tape = TuringMachine.tape_new(["A", "B", "C"], "_")
      right = TuringMachine.move_right(tape)
      assert(TuringMachine.render_tape(right) == "A[B]C")
    }

    test("tape_to_string strips leading and trailing blanks") {
      tape = TuringMachine.tape_new(["_", "_", "1", "0", "_"], "_")
      assert(TuringMachine.tape_to_string(tape) == "10")
    }
  }

  describe("symbol helpers") {
    test("string_to_symbols splits a string into single-character symbols") {
      symbols = TuringMachine.string_to_symbols("101")
      assert(List.length(symbols) == 3)
      assert(List.at(symbols, 0) == "1")
      assert(List.at(symbols, 1) == "0")
      assert(List.at(symbols, 2) == "1")
    }

    test("string_to_symbols of empty string is empty list") {
      assert(List.empty?(TuringMachine.string_to_symbols("")))
    }

    test("concat_symbols is the inverse of string_to_symbols") {
      assert(TuringMachine.concat_symbols(TuringMachine.string_to_symbols("hello")) == "hello")
    }
  }
}
