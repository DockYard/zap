# Turing machine simulator (in progress — surfaces compiler gaps)

A general Turing machine simulator written in Zap. The design is
sound and is intended to demonstrate Turing-completeness — given an
arbitrary transition table, run it on a bidirectionally infinite
tape, halt when no rule matches.

**Current status: does not compile.** The implementation surfaces
several real bugs in the Zap → Zig fork pipeline that haven't been
fixed yet. Each is reproducible from a much smaller program.

## Conceptual design

- **Tape** is a 4-tuple `{left, current, right, blank}`. `left` and
  `right` are `[String]` lists of cells, head-adjacent first;
  `current` is the symbol under the head; `blank` is the symbol
  reported off the ends of the written portion.
- **Transition** is a 5-tuple
  `{state, read, next_state, write, direction}` — all strings.
  `direction` is `"L"` | `"R"` | `"S"`.
- **Machine state** is threaded as separate parameters to `run`
  rather than bundled into one big tuple (avoids one of the bugs
  below).
- The first transition matching `(state, current)` fires; the
  machine halts when no row matches.

Two example transition tables ship with the source: a binary
incrementer (`scan` → `carry` → `done`) and a unary doubler
(`find` → `mark` → `write` → `back` → `rewind` → `cleanup`).

## Compiler gaps this example surfaces

These were independently reproduced from minimal programs while
implementing the simulator.

### Gap A: struct literals in typed lists produce anonymous per-site types

Minimal repro:

```zap
pub struct Foo.Item {
  name :: String
}

pub struct Foo {
  pub fn make_two() -> [Foo.Item] {
    [%Foo.Item{name: "a"}, %Foo.Item{name: "b"}]
  }
}
```

Compiler error:

```
error: expected type 'Foo.Item', found 'Foo.make_two__0__struct_19231'
```

Each `%Foo.Item{...}` literal site receives a fresh anonymous struct
type tagged with a unique id, and the resulting list type fails to
unify with the declared `[Foo.Item]` return type. Variants tried:

- single-line `[%Foo.Item{}, %Foo.Item{}]` — fails
- pipe `… |> List.push(%Foo.Item{…})` — fails per-step
- explicit ascription `(%Foo.Item{…} :: Foo.Item)` — fails
- helper `fn make_item(...) -> Foo.Item { %Foo.Item{...} }` — same anonymous-type error

This forced the simulator to use tuple `{String, String, String, String, String}`
for transitions instead of a named `Transition` struct.

### Gap B: Sema null `inst_map` lookup on nested mixed-type tuples in fn signatures

Minimal repro:

```zap
pub fn make_machine() -> {String, {[String], String, [String], String}, [{String, String, String, String, String}], Bool, i64} {
  …
}
```

Compiler crash:

```
thread … panic: attempt to use null value
zig/src/Sema.zig:2038 in resolveInst
zig/src/Sema.zig:1396 in analyzeBodyInner  (.tuple_decl)
…
```

The Sema phase resolves a tuple type and tries to look up an
inst_map entry that hasn't been populated yet, then unwraps it with
`.?`. Triggered by tuples that nest another tuple and a list of
tuples among other types.

Working around it required threading the machine's `state`, `tape`,
`transitions`, `steps`, `max_steps` as separate parameters to `run`
rather than bundling them.

### Gap C: multi-line list literals don't parse

```zap
items = [
  1,
  2,
  3
]
```

```
error: I was not expecting a newline here
```

Worked around with `([] :: [T]) |> List.push(...) |> List.push(...)`,
which forces the list expression to span via pipe chaining.

### Gap D: empty list `[]` in mixed contexts infers as `u0`

Without explicit ascription, an empty list literal in tuple/return
position infers to `u0` rather than `List(T)`, then collides with
sibling List(T) values:

```
error: struct field '2' has conflicting types
note: incompatible types: '?*const zap_runtime.List([]const u8)'
                      and '?*const zap_runtime.List(i64)'
```

Worked around with `([] :: [String])` everywhere.

### Gap E: arc_verifier rejects tail-recursion through `if/else`

A function whose only recursive call sits in the `else` of an
`if` (other arm returns) is rejected by the structural verifier:

```
arc_verifier: function 'TuringMachine__apply_first_match__2' violates V6 (structural):
  self-recursive call at arm-internal index 4, inside if_expr at stream index 10
  the construct's dest feeds the function's ret, so the arm is in tail position;
  the IrBuilder's tryRewriteTailThroughBranch should have collapsed it into `tail_call`.
```

The verifier knows the arm is in tail position but the rewriter
didn't transform it. Worked around by splitting the function into
two multi-clause heads (matching `[]` vs `[head | tail]`) with a
guard on the second.

### Gap F: backend (Zcu/PerThread.zig) crash on tuple-pattern-bind + flat tuple return

After the above workarounds, the backend still crashes inside
`PerThread.update` → `analyze and generate fn body`. The
function in question pattern-destructures a 5-tuple transition row
inside the parameter list and returns a flat 3-tuple. Smaller
repros are pending; this needs the Zig fork debugged to triage.

## Files

- `turing_machine.zap` — the simulator (does not currently compile;
  see gaps A/B/F above).
- `build.zap` — manifest with `:default` (bin) and `:test` targets.
- `turing_machine_test.zap` — Zest test cases (does not yet run for
  the same reasons).
- `test_runner.zap` — Zest.Runner glue.

## Reproducing the compiler gaps

```sh
cd examples/turing_machine
rm -rf .zap-cache zap-out
zap run    # triggers gap B or gap F
```

Each minimal repro under "Gaps" above can also be tried in a fresh
project to isolate the failure from this example's surface area.
