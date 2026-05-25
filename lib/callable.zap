@doc = """
  The `Callable` protocol — the existential interface every first-class
  closure value implements. A `fn(A) -> B`-typed value that must outlive
  the frame that produced it (a capturing closure stored in a collection,
  a struct field, or returned across a call boundary) is a `Callable`
  existential at runtime: a `ProtocolBox` whose `data_ptr` holds the
  captured environment and whose vtable `call` slot is the closure body.

  ## Arity is encoded as a brace-tuple

  The protocol's first type parameter `args` is the closure's argument
  list packed into a static-arity Zap tuple, so a single `call` method
  serves every arity:

  | Surface (you write) | `Callable` instantiation |
  |---|---|
  | `fn() -> R`            | `Callable({}, R)`           |
  | `fn(A) -> R`           | `Callable({A}, R)`          |
  | `fn(A, B) -> R`        | `Callable({A, B}, R)`       |

  The empty tuple `{}` is a genuine zero-element tuple type (distinct from
  `void`), so a zero-argument closure has a well-typed `args`. Because Zap
  tuples are brace-delimited and zero-overhead (see `lib/tuple.zap`), the
  pack at the call boundary and the unpack inside `call` are compile-time
  and optimized away on the devirtualized direct-call path.

  ## Auto-implemented by the closure desugar

  The Zap compiler synthesizes the `Callable` impl for a capturing closure
  literal that escapes. The desugar in `src/desugar.zig` rewrites

      fn(x :: i64) -> i64 { x + n }

  (capturing `n`) into a compiler-generated `struct __closure_N { n :: i64 }`
  whose fields are the captured free variables, plus a
  `pub impl Callable({i64}, i64) for __closure_N` whose `call` method is the
  closure body with the named parameter `x` rewritten to the tuple slot
  `args.0` and the capture `n` rewritten to `self.n`. The closure
  expression itself becomes a construction `%__closure_N{ n: n }`, boxed as
  a `Callable` existential where it flows into a `fn`-typed slot that
  requires an owning, type-erased representation.

  ## Invoking a `Callable`

  A call `f(x, y)` whose callee `f` is statically a boxed `Callable`
  dispatches through the protocol-box vtable `call` slot as
  `Callable.call(f, {x, y})` — the arguments packed into the `args` tuple.

  ## Implementing `Callable` for an existing type

  Any type can opt in to being directly callable by writing
  `pub impl Callable({A, B}, R) for MyType { fn call(self, args :: {A, B}) -> R { ... } }`
  manually — the same escape hatch every other protocol offers.
  """

pub protocol Callable(args, result) {
  @doc = """
    Invoke the callable with its arguments packed into the `args` tuple,
    returning a `result`. For a closure, `self` carries the captured
    environment and the body reads its parameters from the tuple slots
    (`arguments.0`, `arguments.1`, ...).
    """

  fn call(self, arguments :: args) -> result
}
