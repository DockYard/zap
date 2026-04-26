@doc = """
  The default module imported into every Zap module.

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
    _name = elem(right, 0)
    _meta = elem(right, 1)
    _args = elem(right, 2)
    _new_args = prepend(_args, left)
    tuple(_name, _meta, _new_args)
  }

  @doc = """
    String concatenation operator.

    Lowers to the runtime bump-allocator concat. A local `pub fn <>` (or
    `pub macro <>`) in the call-site module shadows this default, so users
    can override `<>` for their own types.

    ## Examples

        "hello, " <> "world"   # => "hello, world"
    """

  pub macro <>(left :: Expr, right :: Expr) -> Expr {
    quote { :zig.String.concat(unquote(left), unquote(right)) }
  }

  @doc = """
    Raises a runtime error with the given message.

    This terminates the program immediately. Use in `!` functions
    to signal unrecoverable errors.

    ## Examples

        raise("something went wrong")

        case File.read(path) {
          {:ok, contents} -> contents
          {:error, reason} -> raise("File.read! failed: " <> reason)
        }
    """

  @doc = """
    Returns true if the value is an integer type (i8, i16, i32, i64, u8, u16, u32, u64).
    """

  pub fn is_integer?(value :: any) -> Bool {
    :zig.Kernel.is_integer(value)
  }

  @doc = """
    Returns true if the value is a float type (f16, f32, f64).
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

  pub fn raise(message :: String) -> Never {
    :zig.Kernel.raise(message)
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

}
