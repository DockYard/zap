@doc = """
  An optional value: either `Some(T)` carrying a value of type `T`, or
  `None` representing the absence of a value.

  Use `Option(T)` whenever a value may be absent — return type of a
  partial lookup, an optional argument, a field that may not yet be
  initialised. Pattern-match on the variant to extract or compose with
  the helpers shipped directly under `Option`.

  ## Examples

      opt = Option(i64).Some(42)
      Option.is_some?(opt)                 # => true
      Option.is_none?(Option(i64).None)    # => true
      Option.unwrap_or(opt, 0)             # => 42

  ## Struct + union under one name

  Phase 1.1.5 round 2 made `pub union Foo(...)` and `pub struct Foo`
  composable under one identifier: the union owns the type identity
  (its variants are the runtime values of the type) and the struct
  contributes an associated-function namespace
  (`Foo.member_fn` resolves through the struct's function table).
  Pattern matching reads the union; member calls read the struct.
  This is the foundation Phase 1.2's `pub error Foo` desugar reuses.
  """

pub union Option(t) {
  Some :: t
  None
}

pub struct Option {
  @doc = """
    Returns `true` when `opt` is a `Some(...)` value, `false` when
    it is `None`.

    ## Examples

        Option.is_some?(Option(i64).Some(42))   # => true
        Option.is_some?(Option(i64).None)       # => false
    """

  pub fn is_some?(opt :: Option(value)) -> Bool {
    case opt {
      Option.Some(_) -> true
      Option.None -> false
    }
  }

  @doc = """
    Returns `true` when `opt` is `None`, `false` when it carries a
    `Some(...)` value. Logical complement of `is_some?/1`.

    ## Examples

        Option.is_none?(Option(i64).None)       # => true
        Option.is_none?(Option(i64).Some(42))   # => false
    """

  pub fn is_none?(opt :: Option(value)) -> Bool {
    case opt {
      Option.Some(_) -> false
      Option.None -> true
    }
  }

  @doc = """
    Returns the payload of a `Some(...)` value, or `default` when
    `opt` is `None`. `default` must be of the same type the option
    is parameterised on — there is no implicit conversion.

    ## Examples

        Option.unwrap_or(Option(i64).Some(42), 0)   # => 42
        Option.unwrap_or(Option(i64).None, 0)       # => 0
    """

  pub fn unwrap_or(opt :: Option(value), default :: value) -> value {
    case opt {
      Option.Some(payload) -> payload
      Option.None -> default
    }
  }

  @doc = """
    Applies `f` to the payload of a `Some(...)` value, wrapping the
    result back in `Some`. Passes `None` through unchanged. Lets
    callers transform the inner value without leaving the `Option`
    container.

    ## Examples

        opt = Option(i64).Some(2)
        Option.map(opt, fn(payload :: i64) -> i64 { payload * payload })
        # => Option(i64).Some(4)

        Option.map(Option(i64).None, fn(payload :: i64) -> i64 { payload * payload })
        # => Option(i64).None
    """

  pub fn map(opt :: Option(value), f :: (value -> mapped)) -> Option(mapped) {
    case opt {
      Option.Some(payload) -> Option.Some(f(payload))
      Option.None -> Option.None
    }
  }

  @doc = """
    Monadic flatMap: applies `f` to the payload of a `Some(...)`
    value, returning whichever `Option` the function produces.
    `None` passes through unchanged. The key combinator for chaining
    `Option`-returning operations without nesting matches.

    ## Examples

        Option.and_then(Option(i64).Some(4), fn(payload :: i64) -> Option(i64) { Option(i64).Some(payload + 1) })
        # => Option(i64).Some(5)

        Option.and_then(Option(i64).None, fn(payload :: i64) -> Option(i64) { Option(i64).Some(payload + 1) })
        # => Option(i64).None

        Option.and_then(Option(i64).Some(4), fn(_ :: i64) -> Option(i64) { Option(i64).None })
        # => Option(i64).None
    """

  pub fn and_then(opt :: Option(value), f :: (value -> Option(mapped))) -> Option(mapped) {
    case opt {
      Option.Some(payload) -> f(payload)
      Option.None -> Option.None
    }
  }
}
