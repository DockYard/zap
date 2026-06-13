pub struct Point {
  x :: i64
  y :: i64
}

pub struct Config {
  name :: String
  count :: i64 = 0
  enabled :: Bool = true
}

pub struct Shape {
  sides :: i64
}

pub struct Rectangle extends Shape {
  width :: i64
  height :: i64
}

pub struct LinkedNode {
  value :: i64
  next :: LinkedNode | nil
}

## Two structs that reach each other through a non-self field —
## the SCC-aware storage analyzer must give BOTH fields
## `FieldStorage.indirect` so neither lays out inline. Without
## SCC, only direct self-cycles get the indirection and these
## land at infinite-size.
pub struct CycleA {
  tag :: i64
  partner :: CycleB | nil
}

pub struct CycleB {
  weight :: i64
  back :: CycleA | nil
}

pub struct GenericBox(t) {
  value :: t
}

pub struct GenericPair(left_type, right_type) {
  left :: left_type
  right :: right_type
}

pub struct GenericCounter(t) {
  value :: t
  step :: i64 = 1
}


pub struct StructTest {
  use Zest.Case

  describe("Struct creation") {
    test("struct created in helper function") {
      result = get_x_from_inline()
      assert(result == 42)
    }

    test("struct created inline in test via helper") {
      result = sum_point(make_point(3, 4))
      assert(result == 7)
    }
  }

  describe("Struct return types") {
    test("function returns a struct") {
      point = make_point(5, 7)
      assert(point.x == 5)
      assert(point.y == 7)
    }

    test("returned struct fields can be used in expressions") {
      point = make_point(3, 4)
      sum = point.x + point.y
      assert(sum == 7)
    }
  }

  describe("Struct as function parameter") {
    test("function accepts struct from another function") {
      point = make_point(3, 4)
      result = sum_point(point)
      assert(result == 7)
    }

    test("struct created directly in test body") {
      point = %Point{x: 99, y: 88}
      assert(point.x == 99)
      assert(point.y == 88)
    }

    test("struct created and accessed inline") {
      point = make_point(10, 20)
      assert(point.x == 10)
      assert(point.y == 20)
    }
  }

  fn make_point(x_val :: i64, y_val :: i64) -> Point {
    %Point{x: x_val, y: y_val}
  }

  fn sum_point(point :: Point) -> i64 {
    point.x + point.y
  }

  describe("Struct pattern matching") {
    test("destructure struct in function parameter") {
      point = make_point(8, 13)
      result = extract_x(point)
      assert(result == 8)
    }

    test("destructure multiple fields") {
      point = make_point(5, 12)
      result = add_fields(point)
      assert(result == 17)
    }

    ## Perceus reuse / reset opportunity exercised INSIDE a `case` arm
    ## (regression for audit findings perceus-region--02 and
    ## arc-param--01). `reflect_in_branch` takes an OWNED `Point`, matches
    ## a discriminator with a `case`, and in the matched arm deconstructs
    ## the owned point and reconstructs a same-shape `Point` via update
    ## syntax — a textbook Perceus reuse pair whose deconstruction and
    ## construction both live in a NESTED case-arm stream.
    ##
    ## perceus-region--02: Phase-2 construction discovery and drop-spec
    ## generation must resolve the deconstruction by walking the
    ## coordinate `path` into the arm body, not by indexing the top-level
    ## block with a nested-stream `instr_index`. The mirror reconstruction
    ## must pair correctly so the reset token is consumed on the path the
    ## reset ran.
    ##
    ## arc-param--01: in release tiers the recorded insertion coordinates
    ## are consumed AFTER ownership-rewrite / drop-insertion / contification
    ## reshape the stream; the materializer must place `.reset` at the
    ## intended program point (identity-verified), not a shifted one.
    ## Correct results here (and corpus leak-freedom under
    ## `Memory.Tracking`, gated by run_tracking_leak_freedom.sh) prove the
    ## reuse pair is materialized soundly.
    test("reuse pair inside a case arm reflects point coordinates") {
      assert(reflect_in_branch(%Point{x: 3, y: 7}, 1) == 7)
      assert(reflect_in_branch(%Point{x: 3, y: 7}, 0) == 3)
    }

    test("reuse pair inside a nested case arm shifts point coordinates") {
      ## Two levels of nesting: the reconstruction lives in an arm of an
      ## inner `case`, so the recorded coordinate path has depth >= 2.
      shifted = shift_in_nested_branch(%Point{x: 10, y: 20}, true, 5)
      assert(shifted == 15)
      same = shift_in_nested_branch(%Point{x: 10, y: 20}, false, 5)
      assert(same == 10)
    }
  }

  fn extract_x(%{x: x_val} :: Point) -> i64 {
    x_val
  }

  fn add_fields(%{x: x_val, y: y_val} :: Point) -> i64 {
    x_val + y_val
  }

  ## Owned `point` is consumed by the `case`; the matched arm rebuilds a
  ## `Point` (deconstruct + reconstruct => Perceus reuse pair) and reads a
  ## field off the reused cell. The reconstruction is in a nested arm body.
  fn reflect_in_branch(point :: Point, pick :: i64) -> i64 {
    case pick {
      0 -> {
        reflected = %Point{point | x: point.x, y: point.y}
        reflected.x
      }
      _ -> {
        swapped = %Point{point | x: point.y, y: point.x}
        swapped.x
      }
    }
  }

  ## Reconstruction nested two `case` levels deep, so the Perceus
  ## insertion coordinate carries a multi-step `path`.
  fn shift_in_nested_branch(point :: Point, go_deep :: Bool, delta :: i64) -> i64 {
    case go_deep {
      true -> case delta {
        0 -> point.x
        d -> {
          shifted = %Point{point | x: point.x + d}
          shifted.x
        }
      }
      false -> {
        unchanged = %Point{point | x: point.x}
        unchanged.x
      }
    }
  }

  describe("Struct field defaults") {
    test("uses default value when field omitted") {
      config = make_config("test")
      assert(config.count == 0)
      assert(config.enabled == true)
    }

    test("overrides default when field provided") {
      config = make_config_full("prod", 5, false)
      assert(config.count == 5)
      assert(config.enabled == false)
    }
  }

  fn make_config(config_name :: String) -> Config {
    %Config{name: config_name}
  }

  fn make_config_full(config_name :: String, config_count :: i64, is_enabled :: Bool) -> Config {
    %Config{name: config_name, count: config_count, enabled: is_enabled}
  }

  describe("Struct update syntax") {
    test("updates a single field") {
      original = make_point(3, 4)
      updated = update_x(original, 10)
      assert(updated.x == 10)
      assert(updated.y == 4)
    }

    test("updates multiple fields") {
      original = make_point(1, 2)
      updated = update_both(original, 10, 20)
      assert(updated.x == 10)
      assert(updated.y == 20)
    }

    test("original is unchanged after update") {
      original = make_point(5, 6)
      _updated = update_x(original, 99)
      assert(original.x == 5)
    }
  }

  fn update_x(point :: Point, new_x :: i64) -> Point {
    %Point{point | x: new_x}
  }

  fn update_both(point :: Point, new_x :: i64, new_y :: i64) -> Point {
    %Point{point | x: new_x, y: new_y}
  }

  describe("Struct inheritance") {
    test("child struct has parent fields") {
      rect = make_rectangle(4, 10, 5)
      assert(rect.sides == 4)
      assert(rect.width == 10)
      assert(rect.height == 5)
    }

    test("child struct update via function") {
      rect = make_rectangle(4, 10, 5)
      wider = widen_rectangle(rect, 20)
      assert(wider.sides == 4)
      assert(wider.width == 20)
      assert(wider.height == 5)
    }

    test("child struct update inline in test") {
      rect = make_rectangle(4, 10, 5)
      wider = %Rectangle{rect | width: 20}
      assert(wider.width == 20)
      assert(wider.sides == 4)
    }
  }

  fn widen_rectangle(rect :: Rectangle, new_width :: i64) -> Rectangle {
    %Rectangle{rect | width: new_width}
  }

  fn make_rectangle(num_sides :: i64, rect_width :: i64, rect_height :: i64) -> Rectangle {
    %Rectangle{sides: num_sides, width: rect_width, height: rect_height}
  }

  fn get_x_from_inline() -> i64 {
    point = %Point{x: 42, y: 99}
    point.x
  }

  describe("Parametric structs") {
    test("distinct instantiations preserve field types") {
      int_box = make_explicit_int_box()
      string_box = make_explicit_string_box()

      assert(read_int_box(int_box) == 42)
      assert(read_string_box(string_box) == "ok")
    }

    test("multiple type parameters preserve both fields") {
      pair = make_pair_box()

      assert(pair.left == 7)
      assert(pair.right == "hi")
    }

    test("return type drives omitted type-argument literal instantiation") {
      assert(make_int_box().value == 99)
      assert(make_string_box().value == "yep")
    }

    test("concrete defaults survive parametric instantiation") {
      counter = %GenericCounter(i64){value: 0}

      assert(counter.value == 0)
      assert(counter.step == 1)
    }

    test("nested parametric structs round-trip") {
      inner = %GenericBox(i64){value: 7}
      outer = %GenericBox(GenericBox(i64)){value: inner}

      assert(outer.value.value == 7)
    }
  }

  fn read_int_box(box :: GenericBox(i64)) -> i64 {
    box.value
  }

  fn read_string_box(box :: GenericBox(String)) -> String {
    box.value
  }

  fn make_explicit_int_box() -> GenericBox(i64) {
    %GenericBox(i64){value: 42}
  }

  fn make_explicit_string_box() -> GenericBox(String) {
    %GenericBox(String){value: "ok"}
  }

  fn make_pair_box() -> GenericPair(i64, String) {
    %GenericPair(i64, String){left: 7, right: "hi"}
  }

  fn make_int_box() -> GenericBox(i64) {
    %GenericBox{value: 99}
  }

  fn make_string_box() -> GenericBox(String) {
    %GenericBox{value: "yep"}
  }

  describe("Lists of structs") {
    test("list of points length") {
      assert(point_list_length() == 2)
    }

    test("head of point list") {
      assert(first_point_x() == 1)
    }

    test("last of point list") {
      assert(last_point_y() == 4)
    }
  }

  fn point_list_length() -> i64 {
    points = [%Point{x: 1, y: 2}, %Point{x: 3, y: 4}]
    List.length(points)
  }

  fn first_point_x() -> i64 {
    points = [%Point{x: 1, y: 2}, %Point{x: 3, y: 4}]
    first = List.head(points)
    first.x
  }

  fn last_point_y() -> i64 {
    points = [%Point{x: 1, y: 2}, %Point{x: 3, y: 4}]
    last = List.last(points)
    last.y
  }

  describe("Maps of structs") {
    test("map with struct values") {
      assert(get_origin_x() == 0)
    }

    test("map with struct values size") {
      assert(point_map_size() == 2)
    }
  }

  fn get_origin_x() -> i64 {
    points = %{origin: %Point{x: 0, y: 0}, end: %Point{x: 10, y: 20}}
    origin = Map.get(points, :origin, %Point{x: -1, y: -1})
    origin.x
  }

  fn point_map_size() -> i64 {
    points = %{a: %Point{x: 1, y: 2}, b: %Point{x: 3, y: 4}}
    Map.size(points)
  }

  describe("Struct list pattern dispatch") {
    test("extract x from head of point list") {
      assert(first_point_x_via_pattern() == 10)
    }
  }

  fn first_point_x_via_pattern() -> i64 {
    points = [%Point{x: 10, y: 20}, %Point{x: 30, y: 40}]
    first = List.head(points)
    extract_x(first)
  }

  describe("Map get with struct values") {
    test("get struct from map and access field") {
      assert(get_origin_y() == 0)
    }
  }

  fn get_origin_y() -> i64 {
    points = %{origin: %Point{x: 0, y: 0}, end: %Point{x: 10, y: 20}}
    origin = Map.get(points, :origin, %Point{x: -1, y: -1})
    origin.y
  }

  describe("Optional dispatch f(nil) / f(t :: T)") {
    test("nil clause selected for nil arg") {
      assert(StructTest.classify(nil) == 0)
    }

    test("struct clause selected for non-nil arg") {
      n = %LinkedNode{value: 7, next: nil}
      assert(StructTest.classify_indirect(n) == 7)
    }

    test("indirect-storage field passes through optional dispatch") {
      tail = %LinkedNode{value: 9, next: nil}
      head = %LinkedNode{value: 5, next: tail}
      assert(StructTest.classify_indirect(head.next) == 9)
      assert(StructTest.classify_indirect(tail.next) == 0)
    }
  }

  pub fn classify(nil) -> i64 {
    0 :: i64
  }

  pub fn classify(_n :: LinkedNode) -> i64 {
    1 :: i64
  }

  pub fn classify_indirect(nil) -> i64 {
    0 :: i64
  }

  pub fn classify_indirect(n :: LinkedNode) -> i64 {
    n.value
  }

  ## GAP #302 — RESOLVED (recursive-struct Tracking leak).
  ## Under `-Dmemory=Memory.Tracking` (INDIVIDUAL_NO_REFCOUNT | CLONE_ON_SHARE)
  ## the `LinkedNode` recursive-struct tests below (notably "recursive build
  ## outlives constructing frames" — a chain double-walked by `chain_length` +
  ## `chain_sum`) USED to leak 6 `%LinkedNode{}` deinit survivors.
  ##
  ## Root cause (per-call-INSTANCE ownership ambiguity): `chain_length` and
  ## `chain_sum` share ONE IR body that must serve two distinct call instances.
  ## The "recursive build" test calls BOTH on the same `list`, so `chain_length`
  ## is entered with a value the caller only borrows (the sibling `chain_sum`
  ## reuses `list`, so the IR builder hands `chain_length` a fresh share-CLONE)
  ## while `chain_sum` is the last use of `list` (moved in). Convention
  ## inference left `chain_length` `.borrowed` (its top caller fails the
  ## at-last-use consume gate), which SUPPRESSES its param scope-exit release —
  ## but that release is exactly the one that must free the recursion's per-level
  ## `node.next` clones, so they orphaned. `chain_sum` (move-entry, promoted to
  ## `.owned`) frees them; identical IR, opposite outcome. ARC sidesteps this via
  ## its runtime refcount; clone-on-share has no runtime signal, so ownership had
  ## to be resolved STATICALLY per call instance.
  ##
  ## Fix (`src/arc_param_convention.zig` `specializeRecursiveOwnershipVariants`,
  ## gated on clone-on-share so ARC stays byte-identical): the leaking
  ## self-recursive walker is split into a second `.owned`-ENTRY variant and the
  ## recursion edge is retargeted to it, so the recursion MOVES `node.next` (no
  ## per-level clone) exactly like `chain_sum`. The original `.borrowed` variant
  ## is preserved for the genuine borrowers. Leak-freedom is gated by
  ## `script_fixtures/run_tracking_leak_freedom.sh`, which now asserts the WHOLE
  ## corpus is leak-free under Tracking (zero deinit survivors — including these
  ## `%LinkedNode{}` cells). The tests stay un-wrapped by `assert_no_leaks` to
  ## avoid over-reporting GAP-A mid-scope sampling artifacts; the deinit survivor
  ## count is the ground truth.
  ##
  ## (Historical note: the corpus once also reported six 40-byte survivors that
  ## were mis-attributed to the error-system `raise`/`rescue` corpus
  ## [`AlphaError`/`BetaError`]. A runtime trace proved every boxed-error inner
  ## is freed; the real survivors were `MapIter(K,V)` cursor cells from
  ## `for`-comprehension / `Enum.reduce` walks over a `Map`, whose
  ## no-REFCOUNT_V1 free was elided. RESOLVED under task #323 by freeing the iter
  ## cell at the `Map.next` DONE transition under `individual_no_refcount`. The
  ## corpus is now fully leak-free under Tracking.)
  describe("Recursive struct field auto-deref") {
    test("indirect-storage field reads as source-level optional") {
      head = build_two_node_list()
      assert(head.value == 1)
      assert(head_next_is_set(head))
    }

    test("indirect-storage field nil compares cleanly") {
      tail = %LinkedNode{value: 99, next: nil}
      assert(tail.next == nil)
    }

    test("indirect field passes through to ?T parameter") {
      head = build_two_node_list()
      assert(StructTest.next_is_present(head.next))
      assert(StructTest.next_is_present(nil) == false)
    }

    test("mutual recursion via SCC analysis") {
      ## CycleA.partner -> CycleB -> CycleA closes a cycle through
      ## a SECOND struct, not through self-reference. The SCC walker
      ## must detect this and mark both indirect fields with hidden
      ## pointers; without it, layout is infinite and either type-
      ## checking or codegen errors out.
      b = %CycleB{weight: 11, back: nil}
      a = %CycleA{tag: 5, partner: b}
      assert(a.tag == 5)
      assert(a.partner != nil)
      assert(b.weight == 11)
      assert(b.back == nil)
    }

    test("recursive build outlives constructing frames") {
      ## Builds a 4-node chain across 4 stack frames, then walks
      ## the whole list. With stack-allocated heap-promote the
      ## intermediate nodes' pointers would dangle as soon as the
      ## constructing function returned and we'd segfault on the
      ## first descent. The runtime allocator path keeps every
      ## promoted node live for the life of the program.
      list = build_chain_of_four()
      assert(StructTest.chain_length(list) == 4)
      assert(StructTest.chain_sum(list) == 10)
    }
  }

  fn build_two_node_list() -> LinkedNode {
    tail = %LinkedNode{value: 2, next: nil}
    %LinkedNode{value: 1, next: tail}
  }

  fn build_chain_of_four() -> LinkedNode {
    a = %LinkedNode{value: 4, next: nil}
    b = %LinkedNode{value: 3, next: a}
    c = %LinkedNode{value: 2, next: b}
    %LinkedNode{value: 1, next: c}
  }

  fn head_next_is_set(node :: LinkedNode) -> Bool {
    node.next != nil
  }

  pub fn next_is_present(maybe :: LinkedNode | nil) -> Bool {
    maybe != nil
  }

  pub fn chain_length(nil) -> i64 {
    0 :: i64
  }

  pub fn chain_length(node :: LinkedNode) -> i64 {
    one = 1 :: i64
    one + StructTest.chain_length(node.next)
  }

  pub fn chain_sum(nil) -> i64 {
    0 :: i64
  }

  pub fn chain_sum(node :: LinkedNode) -> i64 {
    node.value + StructTest.chain_sum(node.next)
  }
}
