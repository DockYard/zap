@doc = """
  The `Error` protocol — every value that can be raised or returned as an
  error implements `Error`. It exposes a uniform interface for inspecting
  presentable text, programmatic identity, the causal chain, and a stable
  numeric code without committing callers to a concrete error type.

  ## Auto-implemented by `pub error`

  The Zap compiler auto-implements `Error` for every `pub error`
  declaration. The desugar in `src/desugar.zig` rewrites

      pub error ParseError {
        message :: String = "parse error"
        line :: u32
        column :: u32
      }

  into a `pub struct ParseError` whose fields carry the user-declared
  fields plus the auto-injected `message :: String = "<TypeName>"` and
  `cause :: Option(Error) = Option.None`, together with a
  `pub impl Error for ParseError` whose methods read those fields and the
  desugared type name. User-supplied inline methods on the `pub error`
  body override the auto-generated defaults (same name and arity).

  ## Implementing `Error` for an existing type

  Non-`pub error` types can opt in to `Error` the same way they opt in to
  any other protocol — write `pub impl Error for SomeStruct { ... }`
  manually. This is the escape hatch for foreign types that pre-date
  Phase 1.2 or whose layout you want to keep untouched.

  ## Methods

      Error.message(e)   # presentable description (String)
      Error.kind(e)      # programmatic identity (Atom — snake_cased type name)
      Error.source(e)    # causal chain (Option(Error))
      Error.code(e)      # stable numeric code (Option(Atom), e.g. Option.Some(:Z3041))

  ## Examples

      pub error TimeoutError {}
      e = %TimeoutError{}
      Error.message(e)   # => "TimeoutError"
      Error.kind(e)      # => :timeout_error
      Error.source(e)    # => Option.None
      Error.code(e)      # => Option.None
  """

pub protocol Error {
  @doc = """
    The presentable description of this error — a human-readable
    `String` suitable for diagnostic output. `pub error` declarations
    auto-generate a `message/1` that returns the `self.message` field,
    whose default is the bare type name (`"TimeoutError"`) unless the
    user supplies their own default.
    """

  fn message(e) -> String

  @doc = """
    The programmatic identity of this error — an `Atom` derived from
    the snake-cased type name (`:parse_error`, `:io_error`,
    `:xml_parser`). Used for fast equality checks and dispatching on
    error kind without parsing the message string.
    """

  fn kind(e) -> Atom

  @doc = """
    The next link in the causal chain. `Option.Some(inner)` when this
    error was raised in response to another; `Option.None` when this
    is the originating cause. The Phase 2 crash printer walks `source/1`
    to render the full chain; Phase 1.2 only requires the chain to be
    queryable.
    """

  fn source(e) -> Option(Error)

  @doc = """
    The stable numeric code for this error, if any — `Option.Some(:Z3041)`
    when the declaration carried `@code Z3041`, `Option.None` otherwise.
    Codes are part of the public diagnostic surface and are CI-linted as
    required on any `pub error` reaching a `pub` API boundary (linting
    lands in Phase 1.5; the attribute mechanism itself lands here).
    """

  fn code(e) -> Option(Atom)
}

@doc = """
  The default error type for ad-hoc, unstructured failures.

  `RuntimeError` is the target of the `raise "string"` shorthand
  (Phase 1.4): the compiler desugars

      raise "boom"

  into

      raise %RuntimeError{message: "boom"}

  routing through the Error-aware `Kernel.do_raise/1` abort. It is a
  plain `pub error` declaration, so the Phase 1.2 desugar auto-injects
  its `message :: String = "RuntimeError"` and
  `cause :: Option(Error) = Option.None` fields and the four `Error`
  protocol methods. Its `kind/1` is the snake-cased type name
  (`:runtime_error`).

  `RuntimeError` is kept deliberately for ergonomic scripting and test
  code. Production code reaching a `pub` API surface should prefer a
  named `pub error`; the `raise "string"` shorthand on `pub` functions
  is CI-linted (warn-only) toward that end.

  ## Examples

      e = %RuntimeError{message: "disk full"}
      Error.message(e)   # => "disk full"
      Error.kind(e)      # => :runtime_error
  """

@code Z1001
pub error RuntimeError {}

@doc = """
  Raised when a function receives an argument that is the wrong shape,
  out of its accepted domain, or otherwise invalid in a way the type
  system did not catch. Use it at validation boundaries to reject bad
  input with a descriptive message.

  Distinct from `ArithmeticError` / `IndexError`, which the runtime
  raises from its arithmetic and bounds safety checks rather than from
  explicit validation.

  ## Examples

      raise %ArgumentError{message: "expected a positive integer"}
      # ** (argument_error) expected a positive integer
  """

@code Z1002
pub error ArgumentError {}

@doc = """
  Raised when integer arithmetic overflows its result type. This is the
  trap target for the per-optimize-mode overflow policy (Phase 1.5):

  * In Debug and ReleaseSafe builds, an overflowing `+`, `-`, or `*`
    traps and aborts with `** (arithmetic_error) ...` — overflow never
    silently corrupts a value.
  * In ReleaseFast and ReleaseSmall builds, integer arithmetic wraps
    (two's-complement), matching Zig's optimize-mode model; no trap is
    emitted.

  The trap routes through the runtime abort path, so the observable
  shape matches `raise %ArithmeticError{...}`. See `zap explain Z1003`.

  ## Examples

      x = 9223372036854775807   # i64 max
      y = x + 1                 # ReleaseSafe: ** (arithmetic_error) ...
  """

@code Z1003
pub error ArithmeticError {}

@doc = """
  Raised when a list or array is indexed outside its valid
  `0..length` range. This is the trap target for the per-optimize-mode
  bounds policy (Phase 1.5):

  * In Debug and ReleaseSafe builds, an out-of-bounds index traps and
    aborts with `** (index_error) ...`.
  * In ReleaseFast and ReleaseSmall builds, the compiler elides the
    bounds check where it can prove safety, matching Zig's model — it
    never introduces undefined behavior beyond what Zig itself permits.

  The `index` and `length` fields record the offending access for
  diagnostics. See `zap explain Z1004`.

  ## Examples

      items = [1, 2, 3]
      items[5]   # ReleaseSafe: ** (index_error) ...
  """

@code Z1004
pub error IndexError {
  index :: i64
  length :: i64
}

@doc = """
  Raised when a contract assertion fails. This is the abort target for
  the three-tier contract macros (Phase 2.c): `assert`, `debug_assert`,
  and `precondition` (all defined in `Kernel`).

  The three tiers differ only in *which optimize modes* check the
  contract; a failure in any of them raises `AssertionError` with the
  same observable shape:

  * `assert(cond[, message])` — always-on. The contract is checked in
    every optimize mode (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall).
  * `debug_assert(cond[, message])` — checked in Debug only; the
    condition is **not evaluated** (compiled away) in the release modes.
  * `precondition(cond[, message])` — checked in Debug and ReleaseSafe;
    the condition is **not evaluated** in ReleaseFast and ReleaseSmall.

  The macro renders the stringified failing condition, the optional
  user message, and the call-site source location into the `message`
  field, so the crash report shows exactly what was asserted and where:

      ** (assertion_error) assertion failed: x > 0 (at app.zap:42)

  The abort routes through `Kernel.do_raise/1` and the Phase 2 crash
  printer, so an unrescued failure prints the `** (assertion_error) ...`
  header plus a symbolized Zap backtrace. See `zap explain Z1005`.

  ## Examples

      assert(false)
      # ** (assertion_error) assertion failed: false (at app.zap:1)

      assert(x > 0, "x must be positive")
      # ** (assertion_error) x must be positive: x > 0 (at app.zap:1)
  """

@code Z1005
pub error AssertionError {}
