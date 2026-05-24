@doc = """
  A recoverable computation outcome: either `Ok(t)` carrying the
  success payload of type `t`, or `Error(e)` carrying the failure
  payload of type `e`.

  `Result(t, e)` is the canonical type for functions that can fail
  in a recoverable way. Pair it with the `with` expression to chain
  several `Result`-returning steps and short-circuit on the first
  `Error(e)`, with `raise` for ad-hoc error construction, and with
  the helpers below to compose `Result`-returning pipelines without
  nested `case` expressions.

  ## Examples

      r = Result(i64, ParseError).Ok(42)
      Result.is_ok?(r)                          # => true
      Result.unwrap_or(r, 0)                    # => 42
      Result.map(r, fn(v :: i64) -> i64 { v * 2 })
      # => Result(i64, ParseError).Ok(84)

  ## Struct + union under one name

  As with `Option(T)`, `Result(t, e)` is a `pub union` (for
  pattern matching and runtime variant identity) paired with a
  same-name `pub struct` that hosts the helper functions
  (`Result.is_ok?/1`, `Result.map/2`, …). Phase 1.1.5 round 2
  introduced this idiom; the `with` expression and the `~>`
  rewrite both rely on it.
  """

pub union Result(t, e) {
  Ok :: t
  Error :: e
}

pub struct Result {
  @doc = """
    Migration shim (Phase 1.4): convert a legacy `{:ok, v}` / `{:error, e}`
    tuple into the canonical `Result` variants.

        tuple_to_result({:ok, v})    # => Result.Ok(v)
        tuple_to_result({:error, e}) # => Result.Error(e)

    Bare `{:ok, _}` / `{:error, _}` tuples are the pre-`Result` idiom for
    fallible outcomes. This shim bridges code that still produces them to
    the `Result(t, e)` type so it can flow through `?`, `~>`, and the
    `Result.*` combinators. The compiler emits a warn-only deprecation
    lint on bare-tuple `{:ok, _}` / `{:error, _}` patterns pointing here.

    The success and failure payloads share one type parameter, so this
    shim applies to tuples whose `:ok` and `:error` payloads are the same
    type; heterogeneous tuples should construct `Result` variants directly.

    ## Examples

        Result.tuple_to_result({:ok, 42})
        # => Result(i64, i64).Ok(42)

        Result.tuple_to_result({:error, 7})
        # => Result(i64, i64).Error(7)
    """

  pub fn tuple_to_result(tuple :: {Atom, payload}) -> Result(payload, payload) {
    case tuple {
      {:ok, value} -> Result(payload, payload).Ok(value)
      {:error, reason} -> Result(payload, payload).Error(reason)
    }
  }

  @doc = """
    Returns `true` when `r` is `Ok(...)`, `false` when it is
    `Error(...)`.

    ## Examples

        Result.is_ok?(Result(i64, ParseError).Ok(42))   # => true
        Result.is_ok?(Result(i64, ParseError).Error(err)) # => false
    """

  pub fn is_ok?(r :: Result(value, err)) -> Bool {
    case r {
      Result.Ok(_) -> true
      Result.Error(_) -> false
    }
  }

  @doc = """
    Returns `true` when `r` is `Error(...)`, `false` when it is
    `Ok(...)`. Logical complement of `is_ok?/1`.

    ## Examples

        Result.is_error?(Result(i64, ParseError).Error(err)) # => true
        Result.is_error?(Result(i64, ParseError).Ok(42))     # => false
    """

  pub fn is_error?(r :: Result(value, err)) -> Bool {
    case r {
      Result.Ok(_) -> false
      Result.Error(_) -> true
    }
  }

  @doc = """
    Returns the payload of `Ok(...)`, or `default` when `r` is
    `Error(...)`. The default must have the same type as the
    success payload; there is no implicit conversion.

    ## Examples

        Result.unwrap_or(Result(i64, ParseError).Ok(42), 0)        # => 42
        Result.unwrap_or(Result(i64, ParseError).Error(err), 0)    # => 0
    """

  pub fn unwrap_or(r :: Result(value, err), default :: value) -> value {
    case r {
      Result.Ok(payload) -> payload
      Result.Error(_) -> default
    }
  }

  @doc = """
    Applies `f` to the payload of an `Ok(...)` value, wrapping the
    result back in `Ok`. Passes `Error(...)` through unchanged.
    Lets callers transform the success value without leaving the
    `Result` container or touching the error variant.

    ## Examples

        r = Result(i64, ParseError).Ok(2)
        Result.map(r, fn(payload :: i64) -> i64 { payload * payload })
        # => Result(i64, ParseError).Ok(4)

        Result.map(Result(i64, ParseError).Error(err), fn(payload :: i64) -> i64 { payload + 1 })
        # => Result(i64, ParseError).Error(err)
    """

  pub fn map(r :: Result(value, err), f :: fn(value) -> mapped) -> Result(mapped, err) {
    case r {
      Result.Ok(payload) -> Result.Ok(f(payload))
      Result.Error(reason) -> Result.Error(reason)
    }
  }

  @doc = """
    Applies `f` to the payload of an `Error(...)` value, wrapping
    the result back in `Error`. Passes `Ok(...)` through unchanged.
    Lets callers transform the failure value — for example, to
    enrich an inner error with context or to convert between error
    types — without touching the success variant.

    ## Examples

        r = Result(i64, ParseError).Error(parse_err)
        Result.map_error(r, fn(e :: ParseError) -> WrappedError { WrappedError.wrap(e) })
        # => Result(i64, WrappedError).Error(WrappedError.wrap(parse_err))
    """

  pub fn map_error(r :: Result(value, err), f :: fn(err) -> mapped_err) -> Result(value, mapped_err) {
    case r {
      Result.Ok(payload) -> Result.Ok(payload)
      Result.Error(reason) -> Result.Error(f(reason))
    }
  }

  @doc = """
    Monadic flatMap on `Ok(...)`: applies `f` to the success
    payload, returning whichever `Result` the function produces.
    `Error(...)` passes through unchanged. The key combinator for
    chaining `Result`-returning operations without nesting `case`
    expressions — the same role `and_then/2` plays for `Option`.

    ## Examples

        Result.and_then(Result(i64, ParseError).Ok(4),
                        fn(payload :: i64) -> Result(i64, ParseError) {
                          Result(i64, ParseError).Ok(payload + 1)
                        })
        # => Result(i64, ParseError).Ok(5)

        Result.and_then(Result(i64, ParseError).Error(err),
                        fn(payload :: i64) -> Result(i64, ParseError) {
                          Result(i64, ParseError).Ok(payload + 1)
                        })
        # => Result(i64, ParseError).Error(err)
    """

  pub fn and_then(r :: Result(value, err), f :: fn(value) -> Result(mapped, err)) -> Result(mapped, err) {
    case r {
      Result.Ok(payload) -> f(payload)
      Result.Error(reason) -> Result.Error(reason)
    }
  }
}
