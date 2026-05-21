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
## Tests C (`@code Zxxxx`) and E (cause chain) are documented in the
## final report's "Gaps and open follow-ups" section — the `@code`
## attribute mechanism lands here (parser + desugar capture the value
## and synthesize the `code/1` body) but invoking `Error.code(e)` to
## read it back currently hits a pre-existing parametric-union codegen
## panic (Option(Atom) return-type Sema layout), and the auto-injected
## `cause :: Option(Error)` field is deferred to Phase 1.3 alongside
## the `Result(T,E)` parametric-union codegen fix.

## Test A: minimal `pub error TimeoutError {}`.
pub error TimeoutError {}

## Test B: custom default `message` field.
pub error NotConnected {
  message :: String = "no active connection"
}

## Test D: inline `pub fn message/1` overrides the auto-generated body
## while `kind/1` still produces the snake-cased atom.
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
}
