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
