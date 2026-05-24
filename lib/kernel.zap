@doc = """
  The default struct imported into every Zap struct.

  Kernel provides the fundamental language constructs implemented
  as macros: control flow (`if`, `unless`), boolean operators
  (`and`, `or`), the pipe operator (`|>`), sigils (`~s`, `~S`,
  `~w`, `~W`), and declaration macros (`fn`, `struct`, `union`).

  Kernel also provides the multi-step pattern-match composition
  `with` (Elixir-style):

      with Result.Ok(a) <- step1(),
           Result.Ok(b) <- step2(a) {
        Result.Ok(use(a, b))
      } else {
        Result.Error(e) -> Result.Error(wrap(e))
      }

  Each `pattern <- expr` step evaluates `expr` and matches it; on the
  first non-matching step the whole `with` short-circuits to the
  `else` clauses (or, with no `else`, to the non-matching value). The
  `do` body runs only when every step matched. Like the
  `cond`/`for`/`try` block forms, `with` is a variadic construct, so —
  unlike the fixed-arity `if` macro — it is not expressible as a
  single Kernel macro; it is a contextual keyword desugared to nested
  `case` expressions in the same bootstrap layer that lowers
  `if`/`cond`. It introduces no new runtime mechanism — pure sugar
  over `case`.

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
    Unhandled-`raise` terminus (Phase 3.b cross-function propagation).

    When a `raise` propagates across function boundaries — as the
    `error.ZapRaise` tag the compiler returns from a `raises`-row function,
    with the boxed `Error` riding the thread-local side-channel — and
    reaches a frame that neither rescues nor further propagates it (the
    top-level `main`, which cannot return an error union), the compiler
    routes the call-site `catch` here. It recovers the stashed `Error` from
    the side-channel and aborts through `do_raise/1`, producing the same
    Phase 2 crash report (`** (kind) message` + backtrace) an unrecovered
    `raise` would. Diverges (`Never`).
    """

  pub fn abort_recoverable_raise() -> Never {
    do_raise(peek_recoverable_raise())
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
    The compiler-emitted handler landing pad (`Kernel.raise_occurred()` test
    after the body) is what actually diverts control to the `rescue` arms.
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
    Read the pending recoverable-raise `Error` value WITHOUT clearing the
    side-channel or the captured error-return trace (Phase 4.a, ERT display).

    Used only by `abort_recoverable_raise/0`: the unhandled-`raise` terminus
    needs the boxed value to render the `** (kind) message` crash header, but
    must leave the error-return trace — captured at the raise origin in
    `recoverable_raise/1` — intact so the crash printer can render the c→b→a
    propagation chain. The process aborts immediately after, so not clearing
    is safe (the rescue path uses `take_recoverable_raise/0`, which clears).
    Internal compiler support; not intended for direct use.
    """

  pub fn peek_recoverable_raise() -> Error {
    :zig.Kernel.peek_recoverable_raise()
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
