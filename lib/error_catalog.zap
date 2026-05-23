@doc = """
  The Zap diagnostic-code catalog — the long-form source backing
  `zap explain Zxxxx`.

  Each `pub error` that carries a stable `@code Zxxxx` may register a
  catalog entry here describing what the code means, why it fires, a
  minimal reproduction, and how to fix it. `zap explain Z1003` reads this
  file, finds the matching `[Z1003]` record, and prints the rendered
  explanation. Codes without an entry print a short "no explanation
  registered yet" message — the catalog grows over time, the scaffold is
  what matters.

  ## Numbering scheme

  Codes are written `Z<digits>` and partitioned into reserved bands so
  stdlib codes never collide with user codes:

  * `Z1xxx` — runtime / general failures (this band is the stdlib's).
  * `Z2xxx` — type-system / contract failures (reserved for the stdlib).
  * `Z3xxx`..`Z8xxx` — available for user-defined `pub error` types.
  * `Z9xxx` — internal compiler errors (ICE). Reserved for the compiler:
    a `Z9xxx` code always means a compiler bug, never a fault in the
    user's program. See `src/diagnostics.zig` `ICE_CODE_PREFIX`.

  Codes are append-only public API: once assigned, a code keeps its
  meaning forever and is never reused for a different error. The compiler
  enforces global uniqueness at build time (see `src/error_codes.zig`).

  ## Record format

  The catalog body below is a machine-readable record stream consumed by
  the `zap explain` reader in `src/main.zig`. Each record opens with a
  `[Zxxxx]` line in column zero and is followed by `key: value` lines.
  Recognized keys are `title`, `explanation`, `repro`, and `fix`. A value
  continues onto subsequent indented (two-space) lines until the next key
  or the next `[Zxxxx]` header. Lines outside any record (such as this
  documentation heredoc) are ignored by the reader, so this file stays a
  valid Zap source unit.

  [Z1001]
  title: RuntimeError — ad-hoc unstructured failure
  explanation: The default error type raised by the `raise "string"`
    shorthand. It carries only a message and is intended for scripts and
    test code. Production code that crosses a public API boundary should
    prefer a named `pub error` with its own `@code` so callers can match
    on the error type instead of parsing the message string.
  repro: raise "something went wrong"
  fix: Define a named error — `pub error DiskFullError {}` — and `raise
    %DiskFullError{}` so the failure is matchable and self-describing.

  [Z1002]
  title: ArgumentError — invalid argument passed to a function
  explanation: Raised when a function receives an argument that is the
    wrong shape, out of the accepted domain, or otherwise invalid in a
    way the type system did not catch. Distinct from ArithmeticError /
    IndexError, which are raised by the runtime's arithmetic and bounds
    checks rather than by explicit validation.
  repro: raise %ArgumentError{message: "expected a positive integer"}
  fix: Validate inputs at the boundary and raise ArgumentError with a
    message naming the offending parameter and the expected domain.

  [Z1003]
  title: ArithmeticError — integer overflow trap
  explanation: In Debug and ReleaseSafe builds, integer arithmetic that
    overflows the result type traps and aborts with `** (arithmetic_error)
    ...`. This is the per-optimize-mode overflow policy: safe modes trap
    so overflow never silently corrupts a value, while ReleaseFast and
    ReleaseSmall builds wrap (two's-complement) for speed, matching Zig's
    optimize-mode model.
  repro: # ReleaseSafe: traps. ReleaseFast: wraps.
    x = 9223372036854775807   # i64 max
    y = x + 1
  fix: Use a wider integer type, check the operands before the operation,
    or build with `-Doptimize=ReleaseFast` if wrapping is the intended
    semantics for a hot path.

  [Z1004]
  title: IndexError — array / list index out of bounds
  explanation: In Debug and ReleaseSafe builds, indexing a list or array
    outside its valid `0..length` range traps and aborts with
    `** (index_error) ...`. In ReleaseFast / ReleaseSmall the compiler
    elides the bounds check where it can prove safety, matching Zig's
    model — it never introduces undefined behavior beyond what Zig itself
    permits.
  repro: # ReleaseSafe: traps with index_error.
    items = [1, 2, 3]
    items[5]
  fix: Check the index against the collection length first, or use a
    safe accessor that returns `Option(t)` instead of trapping.

  [Z2001]
  title: Type mismatch — two-sided expected/got
  explanation: A value's type does not match the type required at its use
    site. Zap renders BOTH sides: the primary caret marks the offending
    expression (the "got" type), and a `= note:` line points at where the
    EXPECTED type came from — a return-type annotation or a parameter
    declaration. The structured `expected_type` / `got_type` ride in the
    JSON `machine_data` for tooling. This is the two-sided type error from
    the error-system design (TypeProvenance): you see not just what was
    wrong but why the compiler expected what it did.
  repro: pub struct Demo {
      pub fn takes_int(x :: i64) -> i64 { x }
      pub fn caller() -> i64 { Demo.takes_int("hello") }
    }
  fix: Convert the value to the expected type, or change the annotation
    that establishes the expectation (the one the `= note:` line points
    at) if the call site is the intended contract.

  [Z9100]
  title: Internal compiler error — script code-generation / link failed
  explanation: An INTERNAL failure (not a fault in your program) occurred
    while generating code or linking the binary for a `zap run` script.
    Nothing internal escapes as a bare string: the compiler reports this
    structured ICE with the failing pass and a stable code. A `Z9xxx`
    code always means a compiler bug — your source is not at fault.
  repro: # Not user-reproducible by design — this fires only on an
    # internal failure such as an out-of-memory condition or an
    # unexpected backend state during a `zap run <script>` compile.
  fix: This is a compiler bug. Please file a report with the smallest
    `.zap` script that triggers it and the full diagnostic (including the
    `Z9100` code) so the failing pass can be reproduced and fixed.

  [Z9101]
  title: Internal compiler error — project code-generation / link failed
  explanation: As `Z9100`, but for a manifest/project build (`zap build`)
    rather than a single-file script. An internal failure occurred while
    generating code or linking the project's binary. The user's program
    is not at fault; the structured ICE names the failing pass.
  repro: # Not user-reproducible by design — fires on an internal failure
    # during a `zap build` code-generation / link step.
  fix: This is a compiler bug. File a report with a minimal project that
    reproduces it and the full diagnostic (including the `Z9101` code).
  """

@doc = """
  Marker struct so `lib/error_catalog.zap` is a well-formed Zap source
  unit. The catalog data itself lives in the documentation heredoc above
  and is read by `zap explain`; this struct carries no runtime behavior.
  """

pub struct Zap.ErrorCatalog {}
