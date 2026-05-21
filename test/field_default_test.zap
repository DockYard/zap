## Acceptance tests for the general-purpose `field :: Type = expr`
## syntax on `pub struct` declarations. This is Phase 1.1 of the
## error-system roadmap (field defaults are the foundation `pub error`
## later builds on, but the feature is intentionally generic and
## independent of any error machinery).
##
## The five acceptance cases (A–E) come from the Phase 1.1 spec in
## `docs/error-system-research-brief.md`. Test D (default expression
## whose type does not match the declared field type) is a compile
## error — it lives as a Zig-side typechecker test in
## `src/types.zig`, not here, because a failing-to-compile fixture
## cannot sit inside a runtime test suite.

## Test A: numeric defaults.
pub struct Counter {
  value :: i64 = 0
}

## Test B: String and collection defaults. The empty list literal
## `[]` only types correctly when the field's declared `[String]`
## type is pushed down into the default expression.
pub struct ConfigB {
  host :: String = "localhost"
  port :: u16 = 8080
  timeout :: i64 = 5000
  tags :: [String] = []
}

## Test C: mixed defaulted and required fields. Required field
## (`host`) must still be supplied; defaulted fields may be omitted.
pub struct ServerC {
  port :: u16 = 8080
  host :: String
}

## Test E: nested struct constructed by a default. The default
## expression evaluates at every construction site, so `%Inner{}`
## produces a fresh inner value per outer literal.
pub struct InnerE {
  v :: i64 = 7
}

pub struct OuterE {
  inner :: InnerE = %InnerE{}
}

pub struct FieldDefaultTest {
  use Zest.Case

  describe("Test A — numeric defaults") {
    test("default applies when field omitted") {
      c = %Counter{}
      assert(c.value == 0)
    }

    test("explicit value overrides default") {
      c = %Counter{value: 42}
      assert(c.value == 42)
    }
  }

  describe("Test B — String and collection defaults") {
    test("string default applies when field omitted") {
      cfg = %ConfigB{}
      assert(cfg.host == "localhost")
    }

    test("narrow integer default applies when field omitted") {
      cfg = %ConfigB{}
      assert(cfg.port == 8080)
    }

    test("wide integer default applies when field omitted") {
      cfg = %ConfigB{}
      assert(cfg.timeout == 5000)
    }

    test("empty list default applies when field omitted") {
      cfg = %ConfigB{}
      assert(List.length(cfg.tags) == 0)
    }

    test("every defaulted field can be overridden at construction") {
      cfg = %ConfigB{host: "example.org", port: 9000, timeout: 100, tags: ["a", "b"]}
      assert(cfg.host == "example.org")
      assert(cfg.port == 9000)
      assert(cfg.timeout == 100)
      assert(List.length(cfg.tags) == 2)
    }
  }

  describe("Test C — mixed defaulted and required fields") {
    test("supplying the required field uses defaults for the rest") {
      s = %ServerC{host: "0.0.0.0"}
      assert(s.port == 8080)
      assert(s.host == "0.0.0.0")
    }

    test("supplying all fields overrides every default") {
      s = %ServerC{host: "1.1.1.1", port: 9090}
      assert(s.port == 9090)
      assert(s.host == "1.1.1.1")
    }
  }

  describe("Test E — nested struct default") {
    test("nested default constructs the inner struct at outer construction") {
      o = %OuterE{}
      assert(o.inner.v == 7)
    }

    test("each construction site builds a fresh nested value") {
      o1 = %OuterE{}
      o2 = %OuterE{}
      ## Inner is a value struct so equality is by-content; both
      ## values were built independently from the default expression
      ## and must end up structurally equal.
      assert(o1.inner.v == 7)
      assert(o2.inner.v == 7)
    }

    test("explicit inner overrides the nested default") {
      o = %OuterE{inner: %InnerE{v: 99}}
      assert(o.inner.v == 99)
    }
  }
}
