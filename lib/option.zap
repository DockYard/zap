@doc = """
  An optional value: either `Some(T)` carrying a value of type `T`, or
  `None` representing the absence of a value.

  Use `Option(T)` whenever a value may be absent — return type of a
  partial lookup, an optional argument, a field that may not yet be
  initialised. Pattern-match on the variant to extract or compose with
  the helpers shipped under the `Opt` companion module.

  ## Examples

      opt = Option(i64).Some(42)
      Opt.is_some?(opt)                # => true
      Opt.is_none?(Option(i64).None)   # => true
      Opt.unwrap_or(opt, 0)            # => 42

  ## Why `Opt.` not `Option.`?

  The Phase 1.1.5 namespace model registers a single TypeId per
  qualified name, so a hypothetical `pub struct Option { ... }`
  alongside `pub union Option(t)` would collide at registration
  time and shadow the union — making `Option(i64).Some(42)`
  unresolvable. Until the type registry is taught to merge a
  struct+union name pair (a Phase 1.2 follow-up alongside the
  `pub error` keyword's similar shape), the helpers live in the
  `Opt` companion struct so they remain composable today without
  blocking variant construction.
  """

pub union Option(t) {
  Some :: t
  None
}

pub struct Opt {
  @doc = """
    Returns `true` when `opt` is a `Some(...)` value, `false` when
    it is `None`.

    ## Examples

        Opt.is_some?(Option(i64).Some(42))   # => true
        Opt.is_some?(Option(i64).None)       # => false
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

        Opt.is_none?(Option(i64).None)       # => true
        Opt.is_none?(Option(i64).Some(42))   # => false
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

        Opt.unwrap_or(Option(i64).Some(42), 0)   # => 42
        Opt.unwrap_or(Option(i64).None, 0)       # => 0
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
        Opt.map(opt, fn(payload :: i64) -> i64 { payload * payload })
        # => Option(i64).Some(4)

        Opt.map(Option(i64).None, fn(payload :: i64) -> i64 { payload * payload })
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

        Opt.and_then(Option(i64).Some(4), fn(payload :: i64) -> Option(i64) { Option(i64).Some(payload + 1) })
        # => Option(i64).Some(5)

        Opt.and_then(Option(i64).None, fn(payload :: i64) -> Option(i64) { Option(i64).Some(payload + 1) })
        # => Option(i64).None

        Opt.and_then(Option(i64).Some(4), fn(_ :: i64) -> Option(i64) { Option(i64).None })
        # => Option(i64).None
    """

  pub fn and_then(opt :: Option(value), f :: (value -> Option(mapped))) -> Option(mapped) {
    case opt {
      Option.Some(payload) -> f(payload)
      Option.None -> Option.None
    }
  }
}
