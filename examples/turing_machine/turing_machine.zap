@doc = """
  A Turing machine simulator.

  Demonstrates that Zap is Turing-complete: takes a Turing-machine
  specification (states, tape, transition table) and runs it to
  completion, which is sufficient to compute any Turing-computable
  function.

  ## Representations

  Encoded as flat tuples and lists of strings. The compiler currently
  rejects struct literals placed into typed lists (they produce
  anonymous per-site types that fail to unify with the declared
  struct) and crashes on deeply nested mixed-type tuples; this
  implementation avoids both by:

    * representing the transition table as `[{String,String,String,String,String}]`
    * threading the machine's `state`/`tape`/`steps` as separate
      parameters rather than bundling them into one big tuple.

  Type aliases for readability:

      symbol      = String                       # one tape cell
      direction   = String                       # "L" | "R" | "S"
      tape        = {[String], String, [String], String}
                  # {left, current, right, blank}
                  # `left` and `right` hold cells nearest the head first.
                  # cells past the ends read as `blank`.
      transition  = {String, String, String, String, String}
                  # {state, read, next_state, write, direction}

  A transition `{state, read, next_state, write, direction}` says:
  when in `state` reading `read`, write `write`, move `direction`,
  and enter `next_state`. The machine halts when no transition
  matches the current `(state, read)` pair.

  Run the demo with:

      cd examples/turing_machine && zap run
  """

pub struct TuringMachine {

  @doc = """
    Construct a fresh tape from an initial list of symbols. The head
    starts on the first symbol; if `initial` is empty, the head starts
    on a blank cell.
    """

  pub fn tape_new([] :: [String], blank :: String) -> {[String], String, [String], String} {
    {([] :: [String]), blank, ([] :: [String]), blank}
  }

  pub fn tape_new([head | tail] :: [String], blank :: String) -> {[String], String, [String], String} {
    {([] :: [String]), head, tail, blank}
  }

  @doc = """
    Move the head one cell to the right.
    """

  pub fn move_right({left, current, right, blank} :: {[String], String, [String], String}) -> {[String], String, [String], String} {
    new_left = [current | left]
    case right {
      [] -> {new_left, blank, ([] :: [String]), blank}
      [next | rest] -> {new_left, next, rest, blank}
    }
  }

  @doc = """
    Move the head one cell to the left.
    """

  pub fn move_left({left, current, right, blank} :: {[String], String, [String], String}) -> {[String], String, [String], String} {
    new_right = [current | right]
    case left {
      [] -> {([] :: [String]), blank, new_right, blank}
      [prev | rest] -> {rest, prev, new_right, blank}
    }
  }

  @doc = """
    Write `symbol` under the head.
    """

  pub fn write_tape({left, _current, right, blank} :: {[String], String, [String], String}, symbol :: String) -> {[String], String, [String], String} {
    {left, symbol, right, blank}
  }

  @doc = """
    Move the tape in the named direction. `"L"` and `"R"` move the
    head; any other value (including `"S"`) leaves the head in place.
    """

  pub fn move_tape(tape :: {[String], String, [String], String}, "L") -> {[String], String, [String], String} {
    TuringMachine.move_left(tape)
  }

  pub fn move_tape(tape :: {[String], String, [String], String}, "R") -> {[String], String, [String], String} {
    TuringMachine.move_right(tape)
  }

  pub fn move_tape(tape :: {[String], String, [String], String}, _direction :: String) -> {[String], String, [String], String} {
    tape
  }

  @doc = """
    Read the symbol currently under the head.
    """

  pub fn tape_current({_left, current, _right, _blank} :: {[String], String, [String], String}) -> String {
    current
  }

  @doc = """
    Build a 5-tuple transition row.
    """

  pub fn t(state :: String, read :: String, next_state :: String, write :: String, direction :: String) -> {String, String, String, String, String} {
    {state, read, next_state, write, direction}
  }

  @doc = """
    Apply the first transition in `table` matching `(state, read)`.
    Returns `{next_state, new_tape, halted}`. When no row matches,
    returns the same state with `halted = true`.
    """

  pub fn lookup_and_step(state :: String, tape :: {[String], String, [String], String}, [] :: [{String, String, String, String, String}], _all :: [{String, String, String, String, String}]) -> {String, {[String], String, [String], String}, Bool} {
    {state, tape, true}
  }

  pub fn lookup_and_step(state :: String, tape :: {[String], String, [String], String}, [{t_state, t_read, t_next, t_write, t_dir} | _rest] :: [{String, String, String, String, String}], all :: [{String, String, String, String, String}]) -> {String, {[String], String, [String], String}, Bool}
    if t_state == state
    and t_read == TuringMachine.tape_current(tape) {
    {t_next, TuringMachine.move_tape(TuringMachine.write_tape(tape, t_write), t_dir), false}
  }

  pub fn lookup_and_step(state :: String, tape :: {[String], String, [String], String}, [_ignored | rest] :: [{String, String, String, String, String}], all :: [{String, String, String, String, String}]) -> {String, {[String], String, [String], String}, Bool} {
    TuringMachine.lookup_and_step(state, tape, rest, all)
  }

  @doc = """
    Run the machine until it halts or `max_steps` is reached.
    Returns `{final_state, final_tape, steps_taken}`.
    """

  pub fn run(state :: String, tape :: {[String], String, [String], String}, transitions :: [{String, String, String, String, String}], steps :: i64, max_steps :: i64) -> {String, {[String], String, [String], String}, i64} {
    if steps >= max_steps {
      {state, tape, steps}
    } else {
      {next_state, next_tape, halted} = TuringMachine.lookup_and_step(state, tape, transitions, transitions)
      if halted {
        {next_state, next_tape, steps}
      } else {
        one = 1
        TuringMachine.run(next_state, next_tape, transitions, steps + one, max_steps)
      }
    }
  }

  @doc = """
    Concatenate a list of single-character strings.
    """

  pub fn concat_symbols([] :: [String]) -> String {
    ""
  }

  pub fn concat_symbols([head | rest] :: [String]) -> String {
    head <> TuringMachine.concat_symbols(rest)
  }

  @doc = """
    Render the full tape as `"left[current]right"`. Useful for tracing.
    """

  pub fn render_tape({left, current, right, _blank} :: {[String], String, [String], String}) -> String {
    TuringMachine.concat_symbols(List.reverse(left)) <> "[" <> current <> "]" <> TuringMachine.concat_symbols(right)
  }

  @doc = """
    Return the tape contents with leading and trailing blanks trimmed.
    """

  pub fn tape_to_string({left, current, right, blank} :: {[String], String, [String], String}) -> String {
    raw = TuringMachine.concat_symbols(List.reverse(left)) <> current <> TuringMachine.concat_symbols(right)
    TuringMachine.trim_blanks(raw, blank)
  }

  pub fn trim_blanks(s :: String, blank :: String) -> String {
    TuringMachine.trim_trailing_blanks(TuringMachine.trim_leading_blanks(s, blank), blank)
  }

  pub fn trim_leading_blanks(s :: String, blank :: String) -> String {
    one = 1
    len = String.length(s)
    if len == 0 {
      s
    } else {
      if String.slice(s, 0, one) == blank {
        TuringMachine.trim_leading_blanks(String.slice(s, one, len), blank)
      } else {
        s
      }
    }
  }

  pub fn trim_trailing_blanks(s :: String, blank :: String) -> String {
    one = 1
    len = String.length(s)
    if len == 0 {
      s
    } else {
      if String.slice(s, len - one, len) == blank {
        TuringMachine.trim_trailing_blanks(String.slice(s, 0, len - one), blank)
      } else {
        s
      }
    }
  }

  @doc = """
    Split a string into single-character symbols.
    """

  pub fn string_to_symbols(s :: String) -> [String] {
    TuringMachine.explode(s, 0, String.length(s), ([] :: [String]))
  }

  pub fn explode(_s :: String, index :: i64, length :: i64, acc :: [String]) -> [String] if index >= length {
    List.reverse(acc)
  }

  pub fn explode(s :: String, index :: i64, length :: i64, acc :: [String]) -> [String] {
    one = 1
    char = String.slice(s, index, index + one)
    TuringMachine.explode(s, index + one, length, [char | acc])
  }

  @doc = """
    Transition table for a binary-increment Turing machine.

    `scan` walks the head right to the end of the input; `carry`
    walks back left applying the +1 with carry. `done` halts.
    """

  pub fn binary_increment_transitions() -> [{String, String, String, String, String}] {
    ([] :: [{String, String, String, String, String}])
    |> List.push(TuringMachine.t("scan",  "0", "scan",  "0", "R"))
    |> List.push(TuringMachine.t("scan",  "1", "scan",  "1", "R"))
    |> List.push(TuringMachine.t("scan",  "_", "carry", "_", "L"))
    |> List.push(TuringMachine.t("carry", "0", "done",  "1", "S"))
    |> List.push(TuringMachine.t("carry", "1", "carry", "0", "L"))
    |> List.push(TuringMachine.t("carry", "_", "done",  "1", "S"))
  }

  @doc = """
    Run the binary-increment TM on the digits of `bits` and return
    the resulting tape contents.
    """

  pub fn binary_increment(bits :: String) -> String {
    tape = TuringMachine.tape_new(TuringMachine.string_to_symbols(bits), "_")
    transitions = TuringMachine.binary_increment_transitions()
    {_final_state, final_tape, _steps} = TuringMachine.run("scan", tape, transitions, 0, 1000000)
    TuringMachine.tape_to_string(final_tape)
  }

  @doc = """
    Transition table for a unary doubler: `n` ones → `2n` ones. Uses
    a marker `x` to remember which source ones have already been
    duplicated.
    """

  pub fn unary_double_transitions() -> [{String, String, String, String, String}] {
    ([] :: [{String, String, String, String, String}])
    |> List.push(TuringMachine.t("find",    "1", "mark",    "x", "R"))
    |> List.push(TuringMachine.t("find",    "_", "cleanup", "_", "L"))
    |> List.push(TuringMachine.t("mark",    "1", "mark",    "1", "R"))
    |> List.push(TuringMachine.t("mark",    "_", "write",   "_", "R"))
    |> List.push(TuringMachine.t("write",   "1", "write",   "1", "R"))
    |> List.push(TuringMachine.t("write",   "_", "back",    "1", "L"))
    |> List.push(TuringMachine.t("back",    "1", "back",    "1", "L"))
    |> List.push(TuringMachine.t("back",    "_", "rewind",  "_", "L"))
    |> List.push(TuringMachine.t("rewind",  "1", "rewind",  "1", "L"))
    |> List.push(TuringMachine.t("rewind",  "x", "find",    "x", "R"))
    |> List.push(TuringMachine.t("cleanup", "x", "cleanup", "1", "L"))
    |> List.push(TuringMachine.t("cleanup", "_", "halt",    "_", "R"))
  }

  pub fn unary_double(n :: i64) -> String {
    tape = TuringMachine.tape_new(TuringMachine.unary_ones(n, ([] :: [String])), "_")
    transitions = TuringMachine.unary_double_transitions()
    {_final_state, final_tape, _steps} = TuringMachine.run("find", tape, transitions, 0, 1000000)
    TuringMachine.tape_to_string(final_tape)
  }

  pub fn unary_ones(0, acc :: [String]) -> [String] {
    acc
  }

  pub fn unary_ones(n :: i64, acc :: [String]) -> [String] {
    one = 1
    TuringMachine.unary_ones(n - one, ["1" | acc])
  }

  pub fn main(_args :: [String]) -> u8 {
    IO.puts("Turing machine demo")
    IO.puts("===================")
    IO.puts("")
    IO.puts("binary increment:")
    _ = TuringMachine.demo_increment("0")
    _ = TuringMachine.demo_increment("1")
    _ = TuringMachine.demo_increment("10")
    _ = TuringMachine.demo_increment("1011")
    _ = TuringMachine.demo_increment("11111")
    _ = TuringMachine.demo_increment("100000")
    IO.puts("")
    IO.puts("unary doubler (n -> 2n, as runs of 1s):")
    _ = TuringMachine.demo_double(1)
    _ = TuringMachine.demo_double(2)
    _ = TuringMachine.demo_double(3)
    _ = TuringMachine.demo_double(5)
    ""
    0
  }

  pub fn demo_increment(input :: String) -> String {
    output = TuringMachine.binary_increment(input)
    IO.puts("  " <> input <> " + 1 = " <> output)
  }

  pub fn demo_double(n :: i64) -> String {
    input = TuringMachine.concat_symbols(TuringMachine.unary_ones(n, ([] :: [String])))
    output = TuringMachine.unary_double(n)
    IO.puts("  " <> Integer.to_string(n) <> " -> " <> Integer.to_string(String.length(output)) <> " (" <> input <> " -> " <> output <> ")")
  }
}
