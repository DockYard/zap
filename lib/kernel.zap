@doc = """
  The default struct imported into every Zap struct.

  Kernel provides the fundamental language constructs implemented
  as macros: control flow (`if`, `unless`), boolean operators
  (`and`, `or`), the pipe operator (`|>`), sigils (`~s`, `~S`,
  `~w`, `~W`), and declaration macros (`fn`, `struct`, `union`).

  You don't need to `import Kernel` — its macros are available
  everywhere automatically.
  """

pub struct Kernel {
  @doc = """
    Conditional expression with a single branch.

    Evaluates `condition` and executes `then_body` if truthy.
    Returns `nil` if the condition is false.

    ## Examples

        if x > 0 {
          "positive"
        }
    """

  pub macro if(condition :: Expr, then_body :: Expr) -> Nil {
    quote {
      case unquote(condition) {
        true -> unquote(then_body)
        false -> nil
      }
    }
  }

  @doc = """
    Conditional expression with both branches.

    Evaluates `condition` and executes `then_body` if truthy,
    `else_body` if falsy.

    ## Examples

        if x > 0 {
          "positive"
        } else {
          "non-positive"
        }
    """

  pub macro if(condition :: Expr, then_body :: Expr, else_body :: Expr) -> Nil {
    quote {
      case unquote(condition) {
        true -> unquote(then_body)
        false -> unquote(else_body)
      }
    }
  }

  @doc = """
    Negated conditional. Executes the body when the condition is false.

    ## Examples

        unless done {
          IO.puts("still working...")
        }
    """

  pub macro unless(condition :: Expr, body :: Expr) -> Nil {
    quote {
      if not unquote(condition) {
        unquote(body)
      }
    }
  }

  @doc = """
    Short-circuit logical AND.

    Returns `false` immediately if the left operand is false.
    Otherwise evaluates and returns the right operand.

    ## Examples

        true and true    # => true
        true and false   # => false
        false and expr   # => false (expr not evaluated)
    """

  pub macro and(left :: Expr, right :: Expr) -> Expr {
    quote {
      case unquote(left) {
        false -> false
        _ -> unquote(right)
      }
    }
  }

  @doc = """
    Short-circuit logical OR.

    Returns the left operand immediately if it is truthy.
    Otherwise evaluates and returns the right operand.

    ## Examples

        false or true   # => true
        false or false  # => false
        true or expr    # => true (expr not evaluated)
    """

  pub macro or(left :: Expr, right :: Expr) -> Expr {
    quote {
      case unquote(left) {
        false -> unquote(right)
        _ -> unquote(left)
      }
    }
  }

  @doc = """
    Declaration macro for function definitions.

    Receives the full function declaration AST and returns it.
    Identity transform — provides a hook point for future
    customization such as validation, instrumentation, or
    compile-time checks.
    """

  pub macro fn(decl :: Expr) -> Expr {
    quote { unquote(decl) }
  }

  @doc = """
    Declaration macro for struct definitions.

    Receives the full struct declaration AST and returns it.
    Identity transform — hook point for future customization.
    """

  pub macro struct(decl :: Expr) -> Expr {
    quote { unquote(decl) }
  }

  @doc = """
    Declaration macro for union/enum definitions.

    Receives the full union declaration AST and returns it.
    Identity transform — hook point for future customization.
    """

  pub macro union(decl :: Expr) -> Expr {
    quote { unquote(decl) }
  }

  # Sigils

  @doc = """
    String sigil with interpolation support.

    `~s"hello \#{name}"` is equivalent to `"hello \#{name}"`.
    Lowercase sigils allow `\#{}` interpolation.

    ## Examples

        ~s"hello"         # => "hello"
        ~s"count: \#{42}" # => "count: 42"
    """

  pub macro sigil_s(content :: Expr, _opts :: Expr) -> Expr {
    content
  }

  @doc = """
    Raw string sigil without interpolation.

    `~S"hello \#{name}"` keeps `\#{name}` as literal characters.
    Uppercase sigils suppress interpolation.

    ## Examples

        ~S"hello"          # => "hello"
        ~S"no \#{interp}"   # => "no \#{interp}" (literal)
    """

  pub macro sigil_S(content :: Expr, _opts :: Expr) -> Expr {
    content
  }

  @doc = """
    Word list sigil with interpolation support.

    Splits the string on a single space and returns a list of strings.
    Lowercase allows `\#{}` interpolation before splitting.

    ## Examples

        ~w"foo bar baz"  # => ["foo", "bar", "baz"]
        ~w"hello world"  # => ["hello", "world"]
    """

  pub macro sigil_w(content :: Expr, _opts :: Expr) -> Expr {
    quote {
      String.split(unquote(content), " ")
    }
  }

  @doc = """
    Word list sigil without interpolation.

    Splits the string on a single space and returns a list of strings.
    Uppercase suppresses `\#{}` interpolation.

    ## Examples

        ~W"foo bar baz"  # => ["foo", "bar", "baz"]
    """

  pub macro sigil_W(content :: Expr, _opts :: Expr) -> Expr {
    quote {
      String.split(unquote(content), " ")
    }
  }

  @doc = """
    Pipe operator. Passes the left value as the first argument
    to the function call on the right.

    `x |> f(y)` becomes `f(x, y)`.

    ## Examples

        5 |> add_one()              # => add_one(5)
        "hello" |> String.length()  # => String.length("hello")
        x |> f() |> g()            # => g(f(x))
    """

  pub macro |>(left :: Expr, right :: Expr) -> Expr {
    name = elem(right, 0)
    meta = elem(right, 1)
    args = elem(right, 2)
    new_args = prepend(args, left)
    tuple(name, meta, new_args)
  }

  @doc = """
    Concatenation operator. Dispatches through the `Concatenable`
    protocol — any type implementing `Concatenable.concat/2` (built-in:
    `String`, `List`, `Map`) supports `<>`. A local `pub fn <>` (or
    `pub macro <>`) in the call-site struct still shadows this default,
    so users can override `<>` for their own types directly.

    ## Examples

        "hello, " <> "world"   # String
        [1, 2] <> [3, 4]       # List
        %{a: 1} <> %{b: 2}     # Map
    """

  pub macro <>(left :: Expr, right :: Expr) -> Expr {
    quote { Concatenable.concat(unquote(left), unquote(right)) }
  }

  @doc = """
    Returns true if the value is an integer type (i8, i16, i32, i64, i128, u8, u16, u32, u64, u128).
    """

  pub fn is_integer?(value :: any) -> Bool {
    :zig.Kernel.is_integer(value)
  }

  @doc = """
    Returns true if the value is a float type (f16, f32, f64, f80, f128).
    """

  pub fn is_float?(value :: any) -> Bool {
    :zig.Kernel.is_float(value)
  }

  @doc = """
    Returns true if the value is a number (integer or float).
    """

  pub fn is_number?(value :: any) -> Bool {
    :zig.Kernel.is_number(value)
  }

  @doc = """
    Returns true if the value is a boolean.
    """

  pub fn is_boolean?(value :: any) -> Bool {
    :zig.Kernel.is_boolean(value)
  }

  @doc = """
    Returns true if the value is a string.
    """

  pub fn is_string?(value :: any) -> Bool {
    :zig.Kernel.is_string(value)
  }

  @doc = """
    Returns true if the value is an atom.
    """

  pub fn is_atom?(value :: any) -> Bool {
    :zig.Kernel.is_atom(value)
  }

  @doc = """
    Returns true if the value is nil.
    """

  pub fn is_nil?(value :: any) -> Bool {
    :zig.Kernel.is_nil(value)
  }

  @doc = """
    Returns true if the value is a list.
    """

  pub fn is_list?(value :: any) -> Bool {
    :zig.Kernel.is_list(value)
  }

  @doc = """
    Returns true if the value is a tuple.
    """

  pub fn is_tuple?(value :: any) -> Bool {
    :zig.Kernel.is_tuple(value)
  }

  @doc = """
    Returns true if the value is a map.
    """

  pub fn is_map?(value :: any) -> Bool {
    :zig.Kernel.is_map(value)
  }

  @doc = """
    Returns true if the value is a struct.
    """

  pub fn is_struct?(value :: any) -> Bool {
    :zig.Kernel.is_struct(value)
  }

  @doc = """
    Raises a runtime error with the provided message.

    This is the low-level string form. The surface `raise` keyword is
    Error-aware (Phase 1.4): `raise "boom"` desugars to
    `Kernel.do_raise(%RuntimeError{message: "boom"})` and `raise %E{...}`
    desugars to `Kernel.do_raise(%E{...})`, routing through `do_raise/1`
    so the abort carries the value's programmatic `Error.kind` tag.
    """

  pub fn raise(message :: String) -> Never {
    :zig.Kernel.raise(message)
  }

  @doc = """
    Error-aware abort backing the surface `raise` keyword (Phase 1.4).

    Accepts any value whose type implements the `Error` protocol,
    extracts its presentable `Error.message/1` and programmatic
    `Error.kind/1` (rendered as a string), and aborts the process
    non-zero, printing `** (<kind>) <message>` to stderr.

    The compiler's `raise` desugar (`src/desugar.zig`) lowers both the
    `raise "string"` shorthand (after wrapping the string in a
    `%RuntimeError{...}`) and the `raise %CustomError{...}` form to a
    call of this function. Returns `Never` — it does not return.

    Phase 2 extends the abort with backtrace capture and a structured
    crash report; Phase 1.4 is intentionally message-only.
    """

  pub fn do_raise(error_value :: Error) -> Never {
    kind_string = Atom.to_string(Error.kind(error_value))
    error_message = Error.message(error_value)
    :zig.Kernel.raise_with_kind(kind_string, error_message)
  }

  @doc = """
    Recoverable raise sink backing a `raise` lexically inside a
    `try { … } rescue { … }` body (Phase 3.a).

    Unlike `do_raise/1` — which renders the error and aborts via the
    crash printer — this stashes the full `Error` value into the
    runtime's raise side-channel and sets the pending flag. Control then
    returns to the `try` body, which immediately hits the handler landing
    pad the compiler emits after the body (`Kernel.raise_occurred()`):
    seeing the flag set, it recovers the value and dispatches it through
    the `rescue` arms. The compiler's HIR `raise` lowering
    (`src/hir.zig`) selects this sink over `do_raise/1` whenever a `try`
    scope is active; outside any handler the abort path is kept so an
    unhandled `raise` still produces the Phase 2 crash report.

    Returns `Nil` (not `Never`): the recoverable path's non-local exit is
    realized by the compiler-emitted landing-pad branch, not by this
    function diverging — so it must be allowed to return after stashing.
    """

  pub fn recoverable_raise(error_value :: Error) -> Nil {
    :zig.Kernel.recoverable_raise(error_value)
    nil
  }

  @doc = """
    True when a `recoverable_raise` has fired in the current `try` body and
    has not yet been consumed by a handler (Phase 3.a). The compiler emits
    a test of this immediately after a `try` body to decide whether to run
    the `rescue` arms or yield the body's normal value. Internal compiler
    support for `try`/`rescue`; not intended for direct use.
    """

  pub fn raise_occurred() -> Bool {
    :zig.Kernel.raise_occurred()
  }

  @doc = """
    Read and clear the pending recoverable-raise `Error` value (Phase 3.a).
    The compiler's `try`/`rescue` lowering calls this in the handler landing
    pad to recover the raised value and pattern-match it against the `rescue`
    arms. Internal compiler support for `try`/`rescue`; not intended for
    direct use.
    """

  pub fn take_recoverable_raise() -> Error {
    :zig.Kernel.take_recoverable_raise()
  }

  @doc = """
    Abort the process with an `%AssertionError{}` describing a failed
    contract. This is the runtime sink the three-tier contract macros
    (`assert`, `debug_assert`, `precondition`) expand to on the failure
    branch — it is never called on the success branch, so it costs
    nothing when a contract holds.

    `condition_source` is the stringified failing condition (captured by
    the macro via `source_text`), `message` is the optional user message
    (empty string when none was supplied), and `location` is the
    call-site `path:line` (captured by the macro via `source_location`).
    The three are rendered into a single presentable description:

        assertion failed: <condition_source> (at <location>)
        <message>: <condition_source> (at <location>)   # when message present

    The abort routes through `Kernel.do_raise/1`, so an unrescued
    contract violation prints the `** (assertion_error) ...` header plus
    a symbolized Zap backtrace. Returns `Never` — it does not return.
    """

  fn contract_location_suffix(location :: String) -> String {
    if location == "" {
      ""
    } else {
      :zig.String.concat(:zig.String.concat(" (at ", location), ")")
    }
  }

  fn contract_message_prefix(condition_source :: String, message :: String) -> String {
    if message == "" {
      :zig.String.concat("assertion failed: ", condition_source)
    } else {
      :zig.String.concat(:zig.String.concat(message, ": "), condition_source)
    }
  }

  pub fn contract_violation(condition_source :: String, message :: String, location :: String) -> Never {
    rendered = :zig.String.concat(contract_message_prefix(condition_source, message), contract_location_suffix(location))
    do_raise(%AssertionError{message: rendered})
  }

  @doc = """
    Always-on contract assertion. Aborts with `%AssertionError{}` when
    `condition` evaluates to a falsy value, in **every** optimize mode
    (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall). This is the "I
    always want this checked" tier — it is never elided.

    The crash report carries the stringified failing condition so the
    diagnostic shows exactly what was asserted:

        ** (assertion_error) assertion failed: x > 0 (at app.zap:42)

    `condition` is evaluated exactly once (it is the `case` scrutinee).

    ## Examples

        assert(x > 0)
        assert(list_length(items) == expected)
    """

  pub macro assert(condition :: Expr) -> Expr {
    code = source_text(condition)
    location = source_location(condition)

    quote {
      case unquote(condition) {
        false -> Kernel.contract_violation(unquote(code), "", unquote(location))
        _ -> nil
      }
    }
  }

  @doc = """
    Always-on contract assertion with a custom message. Identical to
    `assert/1` but the supplied `message` is rendered ahead of the
    stringified condition in the crash report:

        ** (assertion_error) x must be positive: x > 0 (at app.zap:42)

    The `message` expression is evaluated only on the failure branch.

    ## Examples

        assert(x > 0, "x must be positive")
    """

  pub macro assert(condition :: Expr, message :: Expr) -> Expr {
    code = source_text(condition)
    location = source_location(condition)

    quote {
      case unquote(condition) {
        false -> Kernel.contract_violation(unquote(code), unquote(message), unquote(location))
        _ -> nil
      }
    }
  }

  @doc = """
    Debug-only contract assertion. Checked in Debug builds; **elided**
    (compiled to nothing, the condition NOT evaluated) in ReleaseSafe,
    ReleaseFast, and ReleaseSmall. This is the "expensive dev-only
    invariant" tier — use it for checks too costly to keep in any
    release build.

    Elision happens at macro-expansion time: in a release mode the macro
    expands to `nil`, so the condition expression is never placed in the
    program, never lowered, and never evaluated (no side effects, no
    cost). When it fires (Debug only) it aborts exactly like `assert`.

    `condition` is evaluated exactly once, and only in Debug.

    ## Examples

        debug_assert(expensive_invariant_check())
    """

  pub macro debug_assert(condition :: Expr) -> Expr {
    if optimize_mode() == "debug" {
      code = source_text(condition)
      location = source_location(condition)

      quote {
        case unquote(condition) {
          false -> Kernel.contract_violation(unquote(code), "", unquote(location))
          _ -> nil
        }
      }
    } else {
      quote { nil }
    }
  }

  @doc = """
    Debug-only contract assertion with a custom message. Identical to
    `debug_assert/1` but renders `message` ahead of the condition when
    it fires. Checked in Debug; elided (condition not evaluated) in all
    release modes.

    ## Examples

        debug_assert(cache_consistent?(), "cache invariant violated")
    """

  pub macro debug_assert(condition :: Expr, message :: Expr) -> Expr {
    if optimize_mode() == "debug" {
      code = source_text(condition)
      location = source_location(condition)

      quote {
        case unquote(condition) {
          false -> Kernel.contract_violation(unquote(code), unquote(message), unquote(location))
          _ -> nil
        }
      }
    } else {
      quote { nil }
    }
  }

  @doc = """
    API-contract assertion. Checked in Debug and ReleaseSafe; **elided**
    (compiled to nothing, the condition NOT evaluated) in ReleaseFast
    and ReleaseSmall. This is the "validate the API contract, drop it in
    optimized prod" tier — it mirrors Swift's `precondition`.

    Elision happens at macro-expansion time: in ReleaseFast/ReleaseSmall
    the macro expands to `nil`, so the condition expression is never
    placed in the program, never lowered, and never evaluated. When it
    fires (Debug or ReleaseSafe) it aborts exactly like `assert`.

    `condition` is evaluated exactly once, and only in Debug/ReleaseSafe.

    ## Examples

        precondition(index >= 0)
    """

  pub macro precondition(condition :: Expr) -> Expr {
    if optimize_mode() == "debug" or optimize_mode() == "release_safe" {
      code = source_text(condition)
      location = source_location(condition)

      quote {
        case unquote(condition) {
          false -> Kernel.contract_violation(unquote(code), "", unquote(location))
          _ -> nil
        }
      }
    } else {
      quote { nil }
    }
  }

  @doc = """
    API-contract assertion with a custom message. Identical to
    `precondition/1` but renders `message` ahead of the condition when
    it fires. Checked in Debug and ReleaseSafe; elided (condition not
    evaluated) in ReleaseFast and ReleaseSmall.

    ## Examples

        precondition(denominator != 0, "denominator must be non-zero")
    """

  pub macro precondition(condition :: Expr, message :: Expr) -> Expr {
    if optimize_mode() == "debug" or optimize_mode() == "release_safe" {
      code = source_text(condition)
      location = source_location(condition)

      quote {
        case unquote(condition) {
          false -> Kernel.contract_violation(unquote(code), unquote(message), unquote(location))
          _ -> nil
        }
      }
    } else {
      quote { nil }
    }
  }

  @doc = """
    Suspends the current process for the given number of milliseconds.

    Returns the number of milliseconds slept. Useful for game loops,
    rate limiting, and timed delays.

    ## Examples

        sleep(100)    # pause for 100ms
        sleep(1000)   # pause for 1 second
    """

  pub fn sleep(milliseconds :: i64) -> i64 {
    :zig.Kernel.sleep(milliseconds)
  }

  @doc = """
    Converts any value to its string representation.

    Used by string interpolation to convert interpolated expressions
    to strings. Handles all Zap types: integers, floats, booleans,
    atoms, strings, and structs.

    ## Examples

        to_string(42)       # => "42"
        to_string(true)     # => "true"
        to_string(:hello)   # => "hello"
    """

  pub fn to_string(value :: any) -> String {
    :zig.Kernel.to_string(value)
  }

  @doc = """
    Print a value's string representation to stdout, followed by a newline.

    Equivalent to `IO.puts(Kernel.to_string(value))`. Useful for quick
    debugging or examples that need a value rendered.

    ## Examples

        Kernel.inspect(42)       # prints "42\\n"
        Kernel.inspect(true)     # prints "true\\n"
        Kernel.inspect(:hello)   # prints "hello\\n"
    """

  pub fn inspect(value :: any) -> String {
    IO.puts(to_string(value))
  }

}
