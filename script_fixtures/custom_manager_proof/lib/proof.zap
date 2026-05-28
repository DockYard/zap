@doc = """
The custom-manager proof program.

Exercises the refcounted-type surfaces that, under a manager declaring
REFCOUNTED, would emit retain/release ZIR ops:

  * a recursive `LinkedNode` chain (heap-promoted, walked across recursion),
  * the head+tail-both-live ALIASED shape (`head = %LinkedNode{next: tail}`
    with `tail` still a live binding — the clone-on-share / deep-walk shape),
  * a `List(i64)` (inline-header refcounted cell).

Built with `Custom.BulkArena` (BULK_OR_NEVER) the compiler must elide every
refcount op (Arena-identical); built with `Custom.TrackingPool`
(INDIVIDUAL_NO_REFCOUNT | CLONE_ON_SHARE) it must elide refcount ops and emit
static free-at-last-use + clone-on-share (Tracking-identical). Both backends'
retain/release slots are `@panic` stubs, so a wrongly-emitted refcount op
aborts the run; `Custom.TrackingPool` additionally reports any allocation
surviving to deinit. Identical correct output under both managers, with no
panic and no survivor, is the end-to-end proof that codegen keyed off the
declared caps and never the manager name.
"""

pub struct LinkedNode {
  value :: i64
  next :: LinkedNode | nil
}

pub struct Proof {
  pub fn chain_sum(nil) -> i64 {
    0 :: i64
  }

  pub fn chain_sum(node :: LinkedNode) -> i64 {
    node.value + Proof.chain_sum(node.next)
  }

  pub fn head_value(nil) -> i64 {
    0 :: i64
  }

  pub fn head_value(node :: LinkedNode) -> i64 {
    node.value
  }

  pub fn main(_args :: [String]) -> u8 {
    ## Head+tail-both-live ALIASED shape: `tail` stays live AND is aliased by
    ## head.next. Under INDIVIDUAL_NO_REFCOUNT this is the clone-on-share /
    ## deep-walk shape; under BULK_OR_NEVER it is pure elision. Either way the
    ## program must read both correctly and reclaim everything.
    tail = %LinkedNode{value: 9, next: nil}
    head = %LinkedNode{value: 5, next: tail}
    aliased_total = Proof.head_value(head.next) + Proof.head_value(tail)

    ## Recursive chain built locally then summed across recursion frames.
    a = %LinkedNode{value: 4, next: nil}
    b = %LinkedNode{value: 3, next: a}
    c = %LinkedNode{value: 2, next: b}
    list = %LinkedNode{value: 1, next: c}
    chain_total = Proof.chain_sum(list)

    ## A refcounted inline-header List cell.
    items = [10, 20, 30]
    items_len = List.length(items)

    IO.puts(Integer.to_string(aliased_total + chain_total + items_len))
    0
  }
}
