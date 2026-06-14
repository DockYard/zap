pub struct ClosureTest {
  use Zest.Case

  describe("closures") {
    test("apply doubles value") {
      assert(apply(21, doubler) == 42)
    }

    test("apply with add_one") {
      assert(apply(41, add_one) == 42)
    }

    test("apply_twice") {
      assert(apply_twice(10, add_one) == 12)
    }

    test("apply_twice with doubler") {
      assert(apply_twice(10, doubler) == 40)
    }

    test("chain via apply") {
      assert(apply(apply(20, add_one), doubler) == 42)
    }

    test("anonymous function as callback") {
      assert(apply(21, fn(x :: i64) -> i64 { x * 2 }) == 42)
    }

    test("anonymous function addition") {
      assert(apply(40, fn(x :: i64) -> i64 { x + 2 }) == 42)
    }

    test("lambda-lifted local def can be called") {
      assert(local_def_value() == 42)
    }

    test("function-local captured closure can be called") {
      assert(make_adder_result(32) == 42)
    }

    test("aliased function-local captured closure can be called repeatedly") {
      assert(compute_offsets(10) == 28)
    }

    test("captured closures can be selected through multiple paths") {
      assert(select_captured(100, 1) == 110)
      assert(select_captured(100, 2) == 120)
    }

    test("struct function ref call resolves statically") {
      assert(&ClosureTest.double_ref/1(21) == 42)
    }

    test("local function ref call resolves statically") {
      assert(&double_ref/1(21) == 42)
    }

    test("static Function struct literal call resolves statically") {
      assert(%Function{struct: ClosureTest, name: :double_ref, arity: 1}(21) == 42)
    }

    test("static local function ref captures environment") {
      assert(make_and_apply_ref(32) == 42)
    }

    test("anonymous closure captures environment") {
      offset = 10
      add_offset = fn(x :: i64) -> i64 { x + offset }

      assert(apply(32, add_offset) == 42)
    }
  }

  fn add_one(x :: i64) -> i64 {
    x + 1
  }

  fn doubler(x :: i64) -> i64 {
    x * 2
  }

  fn multiply(x :: i64, y :: i64) -> i64 {
    x * y
  }

  pub fn double_ref(x :: i64) -> i64 {
    x * 2
  }

  fn apply(value :: i64, callback :: fn(i64) -> i64) -> i64 {
    callback(value)
  }

  fn apply_twice(value :: i64, callback :: fn(i64) -> i64) -> i64 {
    callback(callback(value))
  }

  fn test_anon_fn() -> i64 {
    apply(21, fn(x :: i64) -> i64 { x * 2 })
  }

  fn local_def_value() -> i64 {
    pub fn forty_two() -> i64 {
      42
    }

    forty_two()
  }

  fn make_adder_result(base :: i64) -> i64 {
    pub fn add(value :: i64) -> i64 {
      base + value
    }

    add(10)
  }

  fn compute_offsets(base :: i64) -> i64 {
    pub fn offset(value :: i64) -> i64 {
      base + value
    }

    offset(5) + offset(3)
  }

  fn select_captured(base :: i64, mode :: i64) -> i64 {
    pub fn add_ten(value :: i64) -> i64 {
      base + value + 10
    }

    pub fn add_twenty(value :: i64) -> i64 {
      base + value + 20
    }

    case mode {
      1 -> add_ten(0)
      _ -> add_twenty(0)
    }
  }

  fn make_and_apply_ref(base :: i64) -> i64 {
    pub fn add_base(value :: i64) -> i64 {
      base + value
    }

    &add_base/1(10)
  }

  describe("zero-arg callback") {
    test("wrap_call returns callback result") {
      assert(wrap_test() == 42)
    }
  }

  fn wrap_test() -> i64 {
    wrap_call(fn() -> i64 { 42 })
  }

  fn wrap_call(callback :: fn() -> i64) -> i64 {
    callback()
  }

  describe("closure values in type positions") {
    test("returned closure can be called") {
      callback = ClosureTestFactory.make_adder()
      assert(callback() == 42)
    }

    test("closure stored in struct field can be called") {
      handler = %ClosureTestHandler{action: fn() -> i64 { 7 }}
      assert(handler.action() == 7)
    }

    test("closure-typed field with parameter receives argument") {
      transform = %ClosureTestTransform{op: fn(value :: i64) -> i64 { value * 2 }}
      assert(transform.op(21) == 42)
    }

    test("struct returned from function can carry callable closure field") {
      handler = ClosureTestFactory.build_handler()
      assert(handler.action() == 99)
    }

    test("higher-order function can return and accept closures together") {
      returned = ClosureTestFunctionSurface.make_five()
      first = returned()
      second = ClosureTestFunctionSurface.run_nullary(fn() -> i64 { 37 })

      assert(first + second == 42)
    }

    test("function type surface works in param field and return positions") {
      nullary = ClosureTestFunctionSurface.run_nullary(fn() -> i64 { 10 })
      binary = ClosureTestFunctionSurface.run_binary(fn(left :: i64, right :: i64) -> i64 { left + right })
      holder = %ClosureTestTransform{op: fn(value :: i64) -> i64 { value * 2 }}
      returned = ClosureTestFunctionSurface.make()

      assert(nullary + binary + holder.op(9) + returned() == 43)
    }
  }

  describe("cross-struct generic callback") {
    test("IO.mode/2 returns callback result") {
      assert(mode_test() == 42)
    }
  }

  fn mode_test() -> i64 {
    IO.mode(IO.Mode.Normal, fn() -> i64 { 42 })
  }

  # Runtime guard for the value-escape ownership contract closed by audit
  # findings uniqueness--02 / arc-param--02. `mutate_receiver` is a named,
  # owned-mutating function (it forwards its Map receiver straight into
  # `Map.put`, the dense-Map in-place-mutation sink). Here it is taken as
  # a VALUE (`make_closure`) and invoked through that value with a
  # receiver that is ALSO parked in an outer aggregate, so the cell is
  # shared (rc>=2). The interprocedural uniqueness fixpoint and the
  # parameter-convention inference must both treat a value-escaping
  # function conservatively (not unique-on-entry, not `.owned`), so the
  # shared cell is COW-cloned rather than mutated in place. These tests
  # assert the parked alias survives unchanged through the escaped call,
  # under default ARC and `Memory.Tracking`, locking in that contract so
  # a future regression that re-promotes a value-escaping function would
  # corrupt the parked alias (and surface here) instead of silently.
  describe("value-escape ownership soundness (uniqueness--02 / arc-param--02)") {
    test("escaped owned-mutating fn does not corrupt a parked shared receiver") {
      assert(escape_preserves_parked_alias())
    }

    test("escaped owned-mutating fn still returns its own mutation") {
      assert(escape_result_has_mutation())
    }
  }

  fn mutate_receiver(receiver :: %{Atom => i64}) -> %{Atom => i64} {
    Map.put(receiver, :added, 999)
  }

  fn escape_preserves_parked_alias() -> Bool {
    shared_map = %{kept: 7}
    parked = [shared_map]
    escaped = mutate_receiver
    _result = escaped(shared_map)
    observed = List.get(parked, 0)
    not Map.has_key?(observed, :added) and Map.has_key?(observed, :kept)
  }

  fn escape_result_has_mutation() -> Bool {
    base = %{origin: 1}
    escaped = mutate_receiver
    produced = escaped(base)
    Map.has_key?(produced, :added)
  }

  # FU-13 (P2J1b) end-to-end soundness guard for uniqueness--02 /
  # arc-param--02. `mutate_via_put` is a named, owned-mutating function
  # (forwards its Map receiver straight into `Map.put`) exercised through
  # BOTH paths that, before P2J1, disagreed about its receiver convention:
  #   (a) a DIRECT consuming call (`direct_mutate`) — the path that would
  #       promote the receiver to `.owned`; and
  #   (b) a VALUE escape (`make_closure` via `escaped = mutate_via_put`)
  #       invoked indirectly — the path P2J1 vetoes, because an indirect
  #       caller may hand it a shared cell.
  # When both coexist, P2J1's value-escape veto keeps the receiver
  # `.borrowed`, and the convention fixpoint CASCADES that demotion through
  # `Map.put` (a borrowing caller forces `Map.put`'s receiver `.borrowed`
  # too), so the merged IR forwards the receiver by share (rc-checked) and
  # the runtime copy-on-writes — no in-place mutation of the caller's
  # shared cell. This test pins that end-to-end safety: the receiver is
  # parked in an outer aggregate (rc>=2), so any unsound in-place mutation
  # would corrupt the parked alias and surface here. (The narrower IR
  # shape FU-13 directly reconciles — a `move_value` of a value-escape-
  # demoted `.borrowed` source feeding an `.owned` `call_named`/
  # `call_direct` slot, which V6 rejects pre-fix — is proven
  # fail-pre/pass-post by the deterministic unit test
  # "rewriteOwnedConsumeSites copies-on-write a borrowed-param share into
  # an owned slot (FU-13)" in src/arc_ownership.zig; the convention
  # cascade prevents that exact shape from arising in this Map-forwarding
  # corpus case, so this test passes both pre- and post-fix and stands as
  # the runtime soundness complement.)
  describe("value-escape + direct-consume reconciliation (FU-13)") {
    test("escaped + directly-consumed owned-mutating fn leaves parked alias intact") {
      assert(escape_and_direct_call_preserves_alias())
    }

    test("escaped + directly-consumed owned-mutating fn still returns its mutation") {
      assert(escape_and_direct_call_has_mutation())
    }
  }

  fn mutate_via_put(receiver :: %{Atom => i64}) -> %{Atom => i64} {
    Map.put(receiver, :added, 999)
  }

  # Direct consuming caller: builds a fresh map, hands it to `mutate_via_put`
  # at last-use, and uses the result. This is the call shape that, before
  # P2J1, promoted `mutate_via_put`'s receiver to `.owned`.
  fn direct_mutate() -> Bool {
    fresh = %{seed: 1}
    produced = mutate_via_put(fresh)
    Map.has_key?(produced, :added)
  }

  fn escape_and_direct_call_preserves_alias() -> Bool {
    direct_ok = direct_mutate()
    shared_map = %{kept: 7}
    parked = [shared_map]
    escaped = mutate_via_put
    _result = escaped(shared_map)
    observed = List.get(parked, 0)
    direct_ok and not Map.has_key?(observed, :added) and Map.has_key?(observed, :kept)
  }

  fn escape_and_direct_call_has_mutation() -> Bool {
    direct_ok = direct_mutate()
    base = %{origin: 1}
    escaped = mutate_via_put
    produced = escaped(base)
    direct_ok and Map.has_key?(produced, :added)
  }

  # End-to-end runtime soundness complement for audit finding
  # uniqueness--03. A `~>` catch basin lowers to a `try_call_named` whose
  # dest is the if-else MERGE of the success-arm value and the handler-arm
  # value. The uniqueness analyzer used to classify that dest unique from
  # the SUCCESS-callee contract alone, ignoring that the handler (no-match)
  # arm can bind a SHARED/aliased value to the same dest; a later
  # owned-mutating `Map.put` on the basin result could then be rewritten to
  # `put_owned_unchecked` and mutate an rc>=2 cell in place on the error
  # path -- silent heap corruption.
  #
  # `step_enrich` is a partial, owned-mutating dispatch (it forwards its
  # Map receiver straight into `Map.put`; the `:go` clause is the only
  # match), exercised through BOTH a DIRECT consuming call (`direct_step`,
  # the shape that promotes the receiver toward `.owned`) and the catch
  # basin below. In the basin the dispatch atom `:stop` matches no clause,
  # so the handler runs and yields the parked `shared_map` (rc>=2); the
  # subsequent `Map.put` on the basin result is at its last use. The parked
  # alias must survive unchanged on the no-match path, under default ARC and
  # `Memory.Tracking`.
  #
  # Honesty note: this corpus case passes both pre- AND post-fix. The
  # convention cascade keeps the basin-result `Map.put` receiver
  # COW-classified for this catch-basin shape (the same cascade the FU-13
  # case above documents), so the analyzer-level false-uniqueness does not
  # reach a `*_owned_unchecked` emission here end to end. The authoritative
  # fail-pre/pass-post proof for uniqueness--03 is the deterministic
  # analyzer unit test
  # "uniqueness--03: try_call_named dest is NOT unique when the handler arm
  # yields a shared value" in src/uniqueness.zig, which asserts the dest
  # classification directly. This runtime guard locks in the no-corruption
  # behavior under both managers and is the regression complement: a future
  # change that both re-introduces the analyzer bug AND removes the cascade
  # masking would corrupt the parked alias and surface here. The
  # matched-clause case confirms the success path still produces its own
  # mutation.
  describe("catch-basin handler-arm aliasing soundness (uniqueness--03)") {
    test("no-match catch basin does not corrupt a parked shared alias") {
      assert(catch_basin_handler_preserves_parked_alias())
    }

    test("matched catch basin still returns the success mutation") {
      assert(catch_basin_success_has_mutation())
    }
  }

  fn step_enrich(receiver :: %{Atom => i64}, :go :: Atom) -> %{Atom => i64} {
    Map.put(receiver, :stepped, 999)
  }

  # Direct consuming caller: the call shape that promotes `step_enrich`'s
  # receiver slot to `.owned`, which is what makes the catch-basin dest
  # look unique from the success contract.
  fn direct_step() -> Bool {
    fresh = %{seed: 1}
    produced = step_enrich(fresh, :go)
    Map.has_key?(produced, :stepped)
  }

  fn catch_basin_handler_preserves_parked_alias() -> Bool {
    direct_ok = direct_step()
    shared_map = %{kept: 7}
    parked = [shared_map]
    # `:stop` matches no `step_enrich` clause -> the handler runs and
    # yields the SHARED `shared_map` (rc>=2). The basin result is that
    # shared cell on this path. Owned-mutating site on the basin result
    # at its last use must COW (it is the rc>=2 shared cell on the
    # no-match path), so the parked alias survives unchanged.
    basin = shared_map
    |> step_enrich(:stop)
    ~> {
      _ -> shared_map
    }
    _mutated = Map.put(basin, :added, 1)
    observed = List.get(parked, 0)
    direct_ok and not Map.has_key?(observed, :added) and Map.has_key?(observed, :kept)
  }

  fn catch_basin_success_has_mutation() -> Bool {
    base = %{origin: 1}
    # `:go` matches -> success path returns `Map.put(base, :stepped, 999)`.
    basin = base
    |> step_enrich(:go)
    ~> {
      _ -> base
    }
    Map.has_key?(basin, :stepped)
  }

  # End-to-end runtime soundness complement for audit finding
  # uniqueness--04. A call's dest was marked definitely-unique purely from
  # the callee's `.owned`-receiver-slot + `.owned`-result convention pair,
  # ignoring that the callee BODY can ALIAS its returned value. The
  # canonical refutation is a self-recursive accumulator: in the base case
  # it returns its accumulator parameter UNCHANGED (an alias), so the
  # `.owned`/`.owned` convention pair holds yet the result is the SAME cell
  # the caller passed in. When the caller has parked an alias of that cell
  # (rc>=2) and hits the base path, the result is the shared cell; a later
  # owned-mutating `Map.put` on it, if rewritten to `put_owned_unchecked`,
  # would corrupt the parked alias in place.
  #
  # `accumulate` is a two-clause self-recursive Map accumulator: the
  # base clause `accumulate(m, 0) -> m` returns the receiver alias; the
  # recursive clause forwards the receiver into `Map.put` (the owned-sink
  # consume that promotes the receiver slot toward `.owned`). It is
  # exercised through BOTH a DIRECT consuming call with iterations
  # (`direct_accumulate`, the shape that promotes the slot) and the
  # zero-iteration base path below where the receiver is a parked rc>=2
  # cell. The parked alias must survive unchanged, under default ARC and
  # `Memory.Tracking`.
  #
  # Honesty note: like the uniqueness--02 / uniqueness--03 corpus guards
  # above, this case passes both pre- AND post-fix. The convention cascade
  # keeps the result `Map.put` receiver COW-classified for this
  # accumulator shape end to end, so the analyzer-level false-uniqueness
  # does not reach a `*_owned_unchecked` emission in this corpus path. The
  # authoritative fail-pre/pass-post proof for uniqueness--04 is the
  # deterministic analyzer unit test
  # "uniqueness--04: alias-returning owned callee does NOT make dest unique
  # when the receiver was shared at the call site" in src/uniqueness.zig,
  # which asserts the dest classification directly (it FAILS pre-fix and
  # PASSES post-fix). This runtime guard locks in the no-corruption
  # behavior under both managers; a future change that both re-introduces
  # the convention-pair false-uniqueness AND removes the cascade masking
  # would corrupt the parked alias and surface here. The companion test
  # confirms the multi-iteration path still produces its mutation.
  describe("convention-pair alias-return soundness (uniqueness--04)") {
    test("zero-iteration accumulator base path does not corrupt a parked shared alias") {
      assert(accumulator_base_preserves_parked_alias())
    }

    test("multi-iteration accumulator still returns its mutation") {
      assert(accumulator_iterations_have_mutation())
    }
  }

  # Base clause: returns the receiver parameter UNCHANGED (alias). This is
  # the path that makes the `.owned`/`.owned` convention pair lie about
  # result freshness.
  fn accumulate(m :: %{Atom => i64}, 0 :: i64) -> %{Atom => i64} {
    m
  }

  # Recursive clause: forwards the receiver into `Map.put` (owned sink),
  # the consume anchor that promotes the receiver slot toward `.owned`.
  fn accumulate(m :: %{Atom => i64}, n :: i64) -> %{Atom => i64} {
    stepped = Map.put(m, :count, n)
    ClosureTest.accumulate(stepped, n - 1)
  }

  # Direct consuming caller with real iterations: the call shape that
  # promotes `accumulate`'s receiver slot to `.owned`.
  fn direct_accumulate() -> Bool {
    fresh = %{seed: 1}
    produced = ClosureTest.accumulate(fresh, 3)
    Map.has_key?(produced, :count)
  }

  fn accumulator_base_preserves_parked_alias() -> Bool {
    direct_ok = direct_accumulate()
    shared_map = %{kept: 7}
    parked = [shared_map]
    # Zero iterations -> the base clause returns `shared_map` UNCHANGED
    # (the rc>=2 parked cell). The owned-mutating `Map.put` on that result
    # at its last use must COW (it is the rc>=2 shared cell on the base
    # path), so the parked alias survives unchanged.
    result = ClosureTest.accumulate(shared_map, 0)
    _mutated = Map.put(result, :added, 1)
    observed = List.get(parked, 0)
    direct_ok and not Map.has_key?(observed, :added) and Map.has_key?(observed, :kept)
  }

  fn accumulator_iterations_have_mutation() -> Bool {
    base = %{origin: 1}
    produced = ClosureTest.accumulate(base, 2)
    Map.has_key?(produced, :count)
  }

  # End-to-end runtime soundness complement for audit finding escape--01.
  # Lambda-set 0-CFA propagation used to drop value-aliasing and aggregate
  # opcodes (move_value/copy_value/share_value/field_get/index_get/…), so a
  # closure that reached a call site ONLY through an aggregate read or an
  # alias contributed the EMPTY set; when unioned with a tracked closure the
  # merged lambda set could look wrongly SINGLETON, and the ZIR backend
  # (release-mode lambda specialization) would then DIRECT-dispatch to that
  # lone member with no runtime tag check — calling the WRONG function on the
  # path the aggregate/aliased closure actually took.
  #
  # `pick_via_field` selects between TWO closures that each reach the call
  # site through a `ClosureTestTransform` struct field (the previously-
  # dropped `field_get` aggregate edge), with DISTINCT behavior (+1 vs +100).
  # `pick_via_alias` selects between two closures that reach the call through
  # a local alias of a field read (the `move_value`/`share_value`-style edge
  # propagation also dropped). Both arms share the boxed closure type so the
  # `if` is well-typed. If aggregate/alias edges are dropped, these calls
  # lose their lambda sets entirely; the fix restores correct membership so
  # dispatch selects the right target on each path.
  #
  # Honesty note: lambda specialization is enabled only in release frontend
  # modes (debug skips it), so under the default `zap test` (debug) this
  # test passes both pre- and post-fix. The authoritative fail-pre/pass-post
  # proofs for escape--01 are the deterministic analyzer unit tests
  # "escape--01: lambda set propagates through move_value aliasing (not
  # wrongly singleton)" and "escape--01: lambda set propagates through
  # aggregate store/load (index_get)" in src/lambda_sets.zig, which assert
  # the merged set is NOT singleton (they CRASH pre-fix on the dropped
  # edge's null set and PASS post-fix). This runtime guard locks in correct
  # dispatch through aggregate/alias edges end to end and is the release-mode
  # regression complement.
  describe("lambda-set aggregate/alias dispatch soundness (escape--01)") {
    test("closure selected from a struct field dispatches to the correct target") {
      assert(pick_via_field(0) == 1)
      assert(pick_via_field(1) == 100)
    }

    test("closure selected through a local alias dispatches to the correct target") {
      assert(pick_via_alias(0) == 2)
      assert(pick_via_alias(1) == 200)
    }
  }

  fn pick_via_field(flag :: i64) -> i64 {
    # `flag` selects WHICH closure is stored into the aggregate (struct), then
    # `holder.op` reads it back out — the `struct_init` write + `field_get`
    # read edges lambda-set propagation used to drop. Exactly one closure is
    # constructed and consumed (no unused closure left to leak under
    # Memory.Tracking). The lambda set at `holder.op` must carry BOTH possible
    # closures (the struct came from either branch), so dispatch resolves the
    # correct target on each path.
    holder = if flag == 0 {
      %ClosureTestTransform{op: fn(value :: i64) -> i64 { value + 1 }}
    } else {
      %ClosureTestTransform{op: fn(value :: i64) -> i64 { value + 100 }}
    }
    holder.op(0)
  }

  fn pick_via_alias(flag :: i64) -> i64 {
    # `flag` selects which closure-bearing struct is built; `aliased` re-binds
    # that aggregate (a value-forwarding move/share/copy — the alias edge
    # lambda-set propagation used to drop), and `aliased.op` reads the closure
    # back out. The closure's set must follow it through the aggregate AND the
    # alias for dispatch to resolve correctly. Exactly one closure is
    # constructed and consumed.
    holder = if flag == 0 {
      %ClosureTestTransform{op: fn(value :: i64) -> i64 { value + 2 }}
    } else {
      %ClosureTestTransform{op: fn(value :: i64) -> i64 { value + 200 }}
    }
    aliased = holder
    aliased.op(0)
  }

  # End-to-end runtime soundness complement for audit findings escape--03 /
  # zirb-1--01. The per-call-site specialization table was keyed by a
  # positional `(block, instr_index)` coordinate. The lambda-set analyzer
  # encoded a NESTED call_closure's index as `outer_index + body_offset`,
  # while the ZIR backend looked it up using only the TOP-LEVEL instruction
  # index (`current_instr_index` is never updated during nested-stream
  # emission). A `call_closure` that is the FIRST instruction of an if/case
  # branch therefore keyed at the enclosing if/case's own index, and the
  # then/else branches collided at one key — so a nested closure call bound
  # to an UNRELATED call's specialization and direct-dispatched to the wrong
  # target. The fix keys on the stable, position-free `(function, callee)`
  # identity, which is collision-free and agrees between producer and
  # consumer.
  #
  # `branch_dispatch` calls two DIFFERENT closure-valued parameters in
  # opposite branches of a `case`, each call the first instruction of its
  # arm — the exact colliding shape. With distinct closures passed for the
  # two params, a key collision would make both arms call the same target.
  #
  # Honesty note: like escape--01 above, this is release-gated (lambda
  # specialization is off in debug), so it passes both pre- and post-fix
  # under the default debug `zap test`. The authoritative fail-pre/pass-post
  # proof is the deterministic unit test
  # "escape--03/zirb-1--01: nested closure calls in opposite branches get
  # distinct keys" in src/lambda_sets.zig, which asserts the two nested call
  # sites resolve to DISTINCT keys each bound to its own callee's set (it
  # references the new key shape that does not exist pre-fix). This runtime
  # guard locks in correct per-branch dispatch end to end.
  describe("nested vs top-level call-site key distinctness (escape--03 / zirb-1--01)") {
    test("closures called in opposite case branches each bind their own target") {
      assert(branch_dispatch(0, fn(x :: i64) -> i64 { x + 3 }, fn(x :: i64) -> i64 { x + 7 }) == 13)
      assert(branch_dispatch(1, fn(x :: i64) -> i64 { x + 3 }, fn(x :: i64) -> i64 { x + 7 }) == 17)
    }

    test("a nested branch closure call and a top-level closure call bind distinct targets") {
      assert(nested_and_toplevel(0) == 1041)
      assert(nested_and_toplevel(1) == 1071)
    }
  }

  fn branch_dispatch(mode :: i64, left :: fn(i64) -> i64, right :: fn(i64) -> i64) -> i64 {
    case mode {
      0 -> left(10)
      _ -> right(10)
    }
  }

  fn nested_and_toplevel(mode :: i64) -> i64 {
    # A top-level closure call ...
    top = apply(1000, fn(x :: i64) -> i64 { x + 1 })
    # ... alongside a nested closure call selected per branch. Pre-fix the
    # nested call (first instruction of each arm) collided with the
    # if_expr/case key; post-fix each binds its own callee identity.
    branch = case mode {
      0 -> apply(40, fn(x :: i64) -> i64 { x + 0 })
      _ -> apply(70, fn(x :: i64) -> i64 { x + 0 })
    }
    top + branch
  }

}
