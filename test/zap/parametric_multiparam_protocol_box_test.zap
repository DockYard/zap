@doc = """
  Regression coverage for the parametric-target MULTI-parameter-protocol
  boxing gap. A PARAMETRIC struct (`Mapper(input, output)`) that implements a
  TWO-type-parameter protocol (`Stage(input, output)`) and is GENUINELY
  boxed — passed to a helper whose parameter is `unique Stage(...)`, then
  dispatched through the synthesized existential vtable — failed ZIR
  emission before the fix. The monomorphizer publishes the force-
  specialized impl method (`Mapper_step__i64_String__2`) in the parametric
  head module `Mapper`, whose receiver type must resolve to the SAME nominal
  type the box cell imports (`@import("Mapper_i64_String")`). The ZIR
  backend's `classifyTypeDef` wrongly treated the dot-free monomorph
  sibling `Mapper_i64_String` as a NESTED decl of the head `Mapper` (prefix
  match), emitting a DUPLICATE `Mapper.Mapper_i64_String` type — so the vtable
  adapter's `ImplMod.Mapper_step__i64_String__2(inner.*, …)` call bound
  `inner : *Mapper_i64_String` (top-level) against a receiver typed
  `Mapper.Mapper_i64_String` (nested), a nominal `expected 'Mapper.Mapper_i64_String',
  found 'Mapper_i64_String'` mismatch. Classification is now keyed on the
  original name carrying a dot (genuine nesting) vs. a dot-free top-level
  module, matching the emission steps' own nested/top-level split.

  This drives TWO distinct instantiations of the same parametric head
  (`Mapper(i64, String)` and `Mapper(i64, i64)`), each boxed and dispatched via
  `Stage.step` / `Stage.flush`, asserting the produced values. The closure
  field is ARC-managed, so boxed multi-param dispatch also exercises the
  vtable `__drop__` / release paths (leak-free under `Memory.Tracking`).
  """

pub protocol MultiParamStage(input, output) {
  @doc = """
    Consume one input item, emitting zero or more outputs and the next
    stage state.
    """

  fn step(x :: unique MultiParamStage(input, output), item :: input) -> {Atom, [output], MultiParamStage(input, output)}

  @doc = """
    Signal end-of-input, emitting any buffered outputs.
    """

  fn flush(x :: unique MultiParamStage(input, output)) -> {Atom, [output]}
}

@doc = """
  A parametric mapping stage: applies a stored closure to each input item,
  emitting the single transformed output.
  """

pub struct Mapper(input, output) {
  transform :: fn(input) -> output
}

pub impl MultiParamStage(input, output) for Mapper(input, output) {
  @doc = """
    step: apply the closure to `item`, emit the single output, keep going.
    """

  pub fn step(x :: unique Mapper(input, output), item :: input) -> {Atom, [output], Mapper(input, output)} {
    {:cont, [x.transform(item)], x}
  }

  @doc = """
    flush: a mapping stage buffers nothing, so it emits no trailing
    outputs and reports completion.
    """

  pub fn flush(x :: unique Mapper(input, output)) -> {Atom, [output]} {
    Mapper.drop_transform(x)
    {:done, ([] :: [output])}
  }

  @doc = """
    Release the stored closure when the stage is flushed.
    """

  fn drop_transform(x :: unique Mapper(input, output)) -> Nil {
    nil
  }
}

pub struct Zap.ParametricMultiparamProtocolBoxTest {
  use Zest.Case

  describe("parametric struct implementing a 2-param protocol, boxed") {
    test("Mapper(i64, String) boxed as Stage(i64, String) and driven to :done") {
      stage = %Mapper(i64, String){transform: fn(value :: i64) -> String { Integer.to_string(value) <> "!" }}
      {atom, outputs} = drive_to_string(stage, 1, 2)
      assert(atom == :done)
      assert(List.length(outputs) == 2)
      assert(List.head(outputs) == "1!")
      assert(List.last(outputs) == "2!")
    }

    test("Mapper(i64, i64) boxed as Stage(i64, i64) and driven to :done") {
      stage = %Mapper(i64, i64){transform: fn(value :: i64) -> i64 { value * 10 }}
      {atom, outputs} = drive_to_int(stage, 3, 4)
      assert(atom == :done)
      assert(List.length(outputs) == 2)
      assert(List.head(outputs) == 30)
      assert(List.last(outputs) == 40)
    }
  }

  @doc = """
    Feed two items through a boxed `Stage(i64, String)`, threading the
    consumed receiver, then flush — collecting every emitted output.
    """

  fn drive_to_string(stage :: unique MultiParamStage(i64, String), first :: i64, second :: i64) -> {Atom, [String]} {
    case MultiParamStage.step(stage, first) {
      {_cont_a, outputs_a, next_a} ->
        case MultiParamStage.step(next_a, second) {
          {_cont_b, outputs_b, next_b} ->
            case MultiParamStage.flush(next_b) {
              {done_atom, outputs_flush} -> {done_atom, (outputs_a <> outputs_b) <> outputs_flush}
            }
        }
    }
  }

  @doc = """
    The `Stage(i64, i64)` counterpart of `drive_to_string`, proving the
    fix generalizes across distinct instantiations of the same parametric
    head.
    """

  fn drive_to_int(stage :: unique MultiParamStage(i64, i64), first :: i64, second :: i64) -> {Atom, [i64]} {
    case MultiParamStage.step(stage, first) {
      {_cont_a, outputs_a, next_a} ->
        case MultiParamStage.step(next_a, second) {
          {_cont_b, outputs_b, next_b} ->
            case MultiParamStage.flush(next_b) {
              {done_atom, outputs_flush} -> {done_atom, (outputs_a <> outputs_b) <> outputs_flush}
            }
        }
    }
  }
}
