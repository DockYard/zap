## Acceptance tests for the Phase 1.2 `pub error` / `error` declaration
## form. The front-end desugar in `src/desugar.zig` rewrites every
## error declaration into the canonical `pub struct + pub impl Error`
## pair before any downstream stage sees the program, so these tests
## exercise the visible end-to-end behaviour: construction, the four
## auto-generated `Error` protocol methods (`message/1`, `kind/1`,
## `source/1`, `code/1`), the inline-method override path, and
## visibility flow-through.
##
## The cases mirror the Phase 1.2 acceptance list in
## `docs/error-system-research-brief.md`:
##
##   A. Minimal `pub error` — auto-generated message and kind.
##   B. Custom default `message` field.
##   D. Inline `pub fn message/1` overrides the auto-generated body
##      while `kind/1` still resolves to the snake-cased type name.
##   F. Bare `error` desugars to non-`pub` struct + impl; construction
##      and protocol dispatch still work from within the declaring file.
##
## Test C (`@code Zxxxx`) and E (cause chain) — status after the
## Phase 1.2.5 Gap-Analysis round:
##
## - This file assigns codes to its public error fixtures so the public API
##   lint stays clean and `Error.code/1` is covered alongside message/kind.
##   The original focused `@code Zxxxx` acceptance fixture remains as a
##   `zap run`-exercised script fixture.
## - The auto-injected `cause :: Option(Error) = Option.None` field
##   IS now functional thanks to Phase 1.2.5 protocol existentials
##   + Gap 1 (synthetic-source `zap_runtime` import for parametric
##   union specializations that carry a `protocol_box` payload) +
##   Gap 2 (protocol-method return-type resolution through
##   `protocol_constraint` receivers); a minimal `pub error MyError
##   {}` + `%MyError{}` round-trips through `zap run` cleanly.
## - Tests C and E remain as `zap run`-exercised script fixtures in
##   `script_fixtures/phase_1_2_5_*`; the full Test E cause-chain
##   end-to-end blocks on call-site auto-boxing (Phase 1 gap analysis
##   loop) — the type-checker accepts the program now, but the
##   construction-site auto-box only fires on struct/union literal
##   payload positions, not yet on regular call arguments.

## Test A: minimal `pub error TimeoutError {}`.
@code Z7401
pub error TimeoutError {}

## Test B: custom default `message` field.
@code Z7402
pub error NotConnected {
  message :: String = "no active connection"
}

## Test D: inline `pub fn message/1` overrides the auto-generated body
## while `kind/1` still produces the snake-cased atom.
@code Z7403
pub error KeyError {
  key :: Atom
  pub fn message(self :: KeyError) -> String {
    "key " <> Atom.to_string(self.key) <> " not found"
  }
}

## Test F: bare `error` — non-`pub` struct + non-`pub` impl. The type
## is still callable as an `Error` from inside its declaring file but
## cannot be pattern-matched from outside (pattern-side enforcement
## lands later — this Phase 1.2 fixture only proves the desugar
## emits the type and impl).
error InternalIce {
  message :: String = "internal"
}

pub struct PubErrorHolder {
  cause :: Option(Error) = Option.None
}

pub struct PubErrorTest {
  use Zest.Case

  describe("Test A — minimal pub error TimeoutError") {
    test("Error.message returns the bare type name as the default") {
      e = %TimeoutError{}
      assert(Error.message(e) == "TimeoutError")
    }

    test("Error.kind returns the snake_cased type name as an atom") {
      e = %TimeoutError{}
      assert(Error.kind(e) == :timeout_error)
    }

    test("Error.code returns the declared stable code") {
      e = %TimeoutError{}
      assert(Option.unwrap_or(Error.code(e), :Z0000) == :Z7401)
    }
  }

  describe("Test B — custom default `message` field") {
    test("Error.message reads the user-declared default") {
      e = %NotConnected{}
      assert(Error.message(e) == "no active connection")
    }

    test("explicit construction value overrides the default") {
      e = %NotConnected{message: "custom"}
      assert(Error.message(e) == "custom")
    }

    test("Error.kind still derives from the type name") {
      e = %NotConnected{}
      assert(Error.kind(e) == :not_connected)
    }

    test("Error.code returns the declared stable code") {
      e = %NotConnected{}
      assert(Option.unwrap_or(Error.code(e), :Z0000) == :Z7402)
    }
  }

  describe("Test D — inline pub fn message/1 override") {
    test("Error.message invokes the user-supplied body") {
      e = %KeyError{key: :missing}
      assert(Error.message(e) == "key missing not found")
    }

    test("Error.kind stays auto-generated from the type name") {
      e = %KeyError{key: :missing}
      assert(Error.kind(e) == :key_error)
    }

    test("Error.code returns the declared stable code") {
      e = %KeyError{key: :missing}
      assert(Option.unwrap_or(Error.code(e), :Z0000) == :Z7403)
    }
  }

  describe("Test F — bare `error InternalIce`") {
    test("non-pub error type is constructible inside its declaring file") {
      e = %InternalIce{}
      assert(Error.message(e) == "internal")
    }

    test("Error.kind on a private error type still snake_cases the name") {
      e = %InternalIce{}
      assert(Error.kind(e) == :internal_ice)
    }
  }

  describe("Option(Error) fields") {
    test("default cause accepts Option.None") {
      holder = %PubErrorHolder{}

      assert(Option.is_none?(holder.cause))
    }

    test("cause accepts Some boxed error") {
      holder = %PubErrorHolder{cause: Option.Some(%NotConnected{})}

      assert(Option.is_some?(holder.cause))
    }
  }
}
