# Zap diagnostic JSON schema (`--error-format=json`)

**Schema version: 1** (`schema_version` field). Additive fields do NOT bump the
version; a backward-incompatible change (renamed/removed field, changed type)
bumps it. Consumers should pin against `schema_version` and tolerate unknown
fields.

This is the stable, machine-readable projection of Zap's **canonical Error IR**
(`src/error_ir.zig`). It is produced by `src/error_json.zig` and emitted on
**stdout** when the compiler runs with `-Derror-format=json` (the human text
renderer stays on stderr). Every diagnostic surface — compile errors today,
and runtime panics / error-return traces / leak reports as later Phase 4
sub-phases route through the canonical IR — serializes through this one schema.

The shape is a deliberate **union of two consumers** so neither needs a
translation layer:

- the **LSP `Diagnostic`** shape (`range`, numeric `lsp_severity`, `code`,
  `code_description`, `message`, `related_information`); and
- **rustc's `--error-format=json`** shape (a stable `code`, a fully `rendered`
  string, `suggestions[]` each carrying an `applicability` tag).

## Top-level document

```jsonc
{
  "schema_version": 1,
  "diagnostics": [ /* Diagnostic objects, in canonical deterministic order */ ]
}
```

Diagnostics are emitted in the renderer's **canonical order** — sorted by
`(source_id, line, column, code, message)` — and exact duplicates are dropped,
so the document is **snapshot-stable**: the same compilation produces
byte-identical JSON across runs (brief VI.B #11).

## Diagnostic object

```jsonc
{
  // ── classification ──
  "domain": "typecheck",          // parse|name|typecheck|borrow|effect|runtime|
                                  //   panic|oom|leak|cycle|ffi|io|ice
  "severity": "error",            // error|warning|note|help (Zap names)
  "lsp_severity": 1,              // LSP numeric: 1=Error 2=Warning 3=Info 4=Hint
  "code": "Z0100",                // stable Zxxxx code, when the diagnostic has one
  "code_description": {           // present iff `code` present
    "href": "zap explain Z0100"   // command that prints the full explanation
  },
  "message": "I cannot find a function named `bar/1`",
  "trace_policy": "none",         // none|lightweight|full|allocation
  "visibility": "public",         // public|internal

  // ── primary span (LSP range + rustc one-based + byte offsets) ──
  "primary_span": { /* Span object, see below */ },

  // ── LSP relatedInformation (secondary + related spans) ──
  "related_information": [
    { "location": { /* Span */ }, "message": "did you mean `name`?" }
  ],

  // ── notes ──
  "notes": [
    { "message": "...", "span": { /* Span, optional */ } }
  ],

  // ── free-form help (optional) ──
  "help": "add `do` after the signature",

  // ── rustc suggestions (legacy suggestion + canonical fixits) ──
  "suggestions": [
    {
      "span": { /* Span */ },
      "replacement": "name",
      "description": "did you mean `name`?",
      "applicability": "machine_applicable"
        // machine_applicable | maybe_incorrect | has_placeholders | unspecified
    }
  ],

  // ── cause chain (wrapped underlying causes) ──
  "cause_chain": [
    { "code": "Z1002", "message": "ArgumentError: invalid host", "span": { /* optional */ } }
  ],

  // ── machine-only structured payload (never in the human text) ──
  "machine_data": {
    "expected_type": "i64",
    "got_type": "String"
  },

  // ── the human-rendered text for THIS diagnostic ──
  "rendered": "error: ...\n  │\n2 │   bar()\n  │   ^^^ ...\n  └─ app.zap:2:3\n\n"
}
```

### Span object

Carries **both** coordinate systems plus byte offsets and the resolved file
path, so an LSP client reads `range` and a rustc-style consumer reads
`line`/`column`:

```jsonc
{
  "file": "app.zap",              // resolved path; null when no source is known.
                                  //   Under the user-safe security tier this is
                                  //   the basename only (release builds never
                                  //   leak absolute filesystem layout — VI.B #9).
  "range": {                      // LSP Position: ZERO-based line and character
    "start": { "line": 1, "character": 2 },
    "end":   { "line": 1, "character": 5 }
  },
  "line": 2,                      // rustc-style: ONE-based line a human expects
  "column": 3,                    // rustc-style: ONE-based column
  "byte_start": 17,               // byte offset into the source
  "byte_end": 20,
  "label": "not found in this scope"  // optional underline label (primary span only)
}
```

LSP `Position` is zero-based for both line and character; Zap's internal
`SourceSpan` is one-based. The serializer converts (`lsp_line = line − 1`,
`character = column − 1`, clamped at zero) and keeps the one-based
`line`/`column` for human-oriented tools.

## Field reference

| Field | Source (canonical IR) | Consumer |
| --- | --- | --- |
| `domain` | `Diagnostic.domain` | routing / filtering |
| `severity` / `lsp_severity` | `Diagnostic.severity` | LSP `Diagnostic.severity` |
| `code` / `code_description` | `Diagnostic.code` | LSP `code` / `codeDescription` |
| `message` | `Diagnostic.message` | LSP `message` |
| `trace_policy` | `Diagnostic.trace_policy` | tooling (ERT/leak depth) |
| `visibility` | `Diagnostic.visibility` | API-surface gating |
| `primary_span` | `Diagnostic.span` | LSP `range` + rustc `spans[0]` |
| `related_information` | `secondary_spans` + `related_spans` | LSP `relatedInformation` |
| `notes` | `Diagnostic.notes` | rendered notes |
| `help` | `Diagnostic.help` | rendered help |
| `suggestions` | `suggestion` + `fixits` | rustc `suggestions`; LSP `CodeAction` |
| `cause_chain` | `Diagnostic.cause_chain` | wrapped-error provenance |
| `machine_data` | `Diagnostic.machine_data` | structured tool payload |
| `rendered` | the text renderer | rustc `rendered`; preview |

`rendered` is produced by running the diagnostic through the **same** text
renderer the human sees (with color forced off), so the JSON's `rendered`
string is byte-identical to the terminal output for that diagnostic — one
renderer, one visual language, mirrored into JSON.

## Applicability (`suggestions[].applicability`)

rustc's taxonomy (brief Part V):

- `machine_applicable` — definitely correct and complete; an LSP client / `zap
  fix` may apply it automatically.
- `maybe_incorrect` — a reasonable guess; present it, do not auto-apply.
- `has_placeholders` — contains placeholders the human must fill in.
- `unspecified` — applicability unknown.

## Consumers

- **LSP server** (future): reads `range`, `lsp_severity`, `code`,
  `code_description`, `message`, `related_information`; projects
  `machine_applicable` suggestions into auto-applicable `CodeAction`s.
- **CI gates**: assert on `code` / `domain` / `severity`; the deterministic
  ordering makes the document diffable.
- **`zap fix`** (future): applies `machine_applicable` suggestions by `span` +
  `replacement`.

## Stability contract

A `Zxxxx` `code` is public API: once assigned, it is never reused for a
different error (enforced by `src/error_codes.zig`'s collision registry). The
JSON `code` field therefore is a stable key tools can match against across Zap
releases.
