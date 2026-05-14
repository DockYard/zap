pub struct TuringMachineTest {
  use Zest.Case

  describe("tape construction") {
    test("empty tape has blank under head") {
      tape = TuringMachine.tape_new([], "_")
      assert(tape.current == "_")
      assert(List.empty?(tape.left))
      assert(List.empty?(tape.right))
    }

    test("non-empty tape places head on first symbol") {
      tape = TuringMachine.tape_new(["1", "0", "1"], "_")
      assert(tape.current == "1")
      assert(List.empty?(tape.left))
      assert(List.length(tape.right) == 2)
    }
  }

  describe("tape movement") {
    test("move_right pushes current onto left, pops from right") {
      start = TuringMachine.tape_new(["A", "B", "C"], "_")
      moved = TuringMachine.move_right(start)
      assert(moved.current == "B")
      assert(List.length(moved.left) == 1)
      assert(List.length(moved.right) == 1)
    }

    test("move_right past the end yields a blank cell") {
      start = TuringMachine.tape_new(["A"], "_")
      moved = TuringMachine.move_right(start)
      assert(moved.current == "_")
    }

    test("move_left at the start yields a blank cell") {
      start = TuringMachine.tape_new(["A"], "_")
      moved = TuringMachine.move_left(start)
      assert(moved.current == "_")
    }

    test("move_right then move_left returns to the original") {
      start = TuringMachine.tape_new(["A", "B", "C"], "_")
      round_trip = TuringMachine.move_left(TuringMachine.move_right(start))
      assert(round_trip.current == "A")
      assert(List.length(round_trip.left) == 0)
      assert(List.length(round_trip.right) == 2)
    }

    test("write_tape only changes the current cell") {
      start = TuringMachine.tape_new(["A", "B"], "_")
      written = TuringMachine.write_tape(start, "Z")
      assert(written.current == "Z")
      assert(List.length(written.right) == 1)
    }
  }

  describe("move_tape dispatch") {
    test("L moves left") {
      start = TuringMachine.tape_new(["A", "B"], "_")
      right = TuringMachine.move_right(start)
      left = TuringMachine.move_tape(right, "L")
      assert(left.current == "A")
    }

    test("R moves right") {
      start = TuringMachine.tape_new(["A", "B"], "_")
      moved = TuringMachine.move_tape(start, "R")
      assert(moved.current == "B")
    }

    test("S leaves the head in place") {
      start = TuringMachine.tape_new(["A", "B"], "_")
      stayed = TuringMachine.move_tape(start, "S")
      assert(stayed.current == "A")
    }
  }

  describe("transition matching") {
    test("apply_first_match with empty table halts the machine") {
      tape = TuringMachine.tape_new(["1"], "_")
      machine = TuringMachine.new_machine("q0", tape, [])
      stepped = TuringMachine.step(machine)
      assert(stepped.halted)
    }

    test("apply_first_match with no matching row halts the machine") {
      tape = TuringMachine.tape_new(["1"], "_")
      transitions = ([] :: [TuringMachine.Transition]) |> List.push(TuringMachine.transition("qX", "1", "qY", "0", "R"))
      machine = TuringMachine.new_machine("q0", tape, transitions)
      stepped = TuringMachine.step(machine)
      assert(stepped.halted)
    }

    test("apply_first_match applies the matching row") {
      tape = TuringMachine.tape_new(["0"], "_")
      transitions = ([] :: [TuringMachine.Transition]) |> List.push(TuringMachine.transition("q0", "0", "q1", "1", "R"))
      machine = TuringMachine.new_machine("q0", tape, transitions)
      stepped = TuringMachine.step(machine)
      assert(stepped.state == "q1")
      assert(stepped.halted == false)
      assert(stepped.steps == 1)
    }

    test("apply_first_match uses the first row that matches") {
      tape = TuringMachine.tape_new(["1"], "_")
      transitions = ([] :: [TuringMachine.Transition])
        |> List.push(TuringMachine.transition("q0", "1", "first", "1", "R"))
        |> List.push(TuringMachine.transition("q0", "1", "second", "1", "R"))
      machine = TuringMachine.new_machine("q0", tape, transitions)
      stepped = TuringMachine.step(machine)
      assert(stepped.state == "first")
    }
  }

  describe("run") {
    test("already-halted machine is returned unchanged") {
      tape = TuringMachine.tape_new(["1"], "_")
      machine = TuringMachine.halt(TuringMachine.new_machine("q0", tape, []))
      finished = TuringMachine.run(machine, 100)
      assert(finished.halted)
      assert(finished.steps == 0)
    }

    test("max_steps caps the run when the machine cannot halt") {
      tape = TuringMachine.tape_new(["1"], "_")
      transitions = ([] :: [TuringMachine.Transition]) |> List.push(TuringMachine.transition("q0", "1", "q0", "1", "R"))
      machine = TuringMachine.new_machine("q0", tape, transitions)
      finished = TuringMachine.run(machine, 5)
      assert(finished.halted == false)
      assert(finished.steps == 5)
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
    test("string_to_symbols splits a string into single-char symbols") {
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
