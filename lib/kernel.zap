pub module Kernel {
  @moduledoc = """
    The default module imported into every Zap module.

    Kernel provides the fundamental language constructs implemented
    as macros: control flow (`if`, `unless`), boolean operators
    (`and`, `or`), the pipe operator (`|>`), sigils (`~s`, `~S`,
    `~w`, `~W`), and declaration macros (`fn`, `struct`, `union`).

    You don't need to `import Kernel` — its macros are available
    everywhere automatically.
    """

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

    Splits the string on whitespace and returns a list of strings.
    Lowercase allows `\#{}` interpolation before splitting.

    ## Examples

        ~w"foo bar baz"  # => ["foo", "bar", "baz"]
        ~w"hello world"  # => ["hello", "world"]
    """

  pub macro sigil_w(content :: Expr, _opts :: Expr) -> Expr {
    split_words(content)
  }

  @doc = """
    Word list sigil without interpolation.

    Splits the string on whitespace and returns a list of strings.
    Uppercase suppresses `\#{}` interpolation.

    ## Examples

        ~W"foo bar baz"  # => ["foo", "bar", "baz"]
    """

  pub macro sigil_W(content :: Expr, _opts :: Expr) -> Expr {
    split_words(content)
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

  pub fn raise(message :: String) -> Never {
    :zig.Kernel.raise(message)
  }

}
