# Zap-native golden diagnostic corpus

This directory is the **primary regression benchmark for the whole Zap error
system** (research brief Part VIII, Phase 4). It is a curated set of small Zap
programs that each trigger exactly one diagnostic domain, paired with their
expected rendered output captured as snapshot-stable golden files in BOTH the
human text form (`.txt`) and the `--error-format=json` schema-v1 form (`.json`).

Every diagnostic Zap emits — compile error, runtime panic, ERT trace, leak
report — round-trips through one JSON schema and one renderer (Phase 4.a). The
determinism that buys is what makes these snapshots stable, and this corpus is
the authoritative guard that the rendering never silently drifts.

## Running

```sh
# Verify every fixture's render against its golden (fails on any drift):
zig build golden-corpus
#   ...or directly:
script_fixtures/run_golden_corpus.sh

# Regenerate the goldens after an INTENTIONAL renderer/schema change:
script_fixtures/run_golden_corpus.sh --update
# then review the diff before committing.
```

The harness (`script_fixtures/run_golden_corpus.sh`) runs each fixture through
the freshly-built `zig-out/bin/zap`, normalizes the few intrinsically
non-deterministic tokens, and diffs against the golden.

## Normalization

To keep the goldens byte-stable across machines and runs, the harness rewrites:

| token | normalized to |
| --- | --- |
| ANSI SGR color escapes | removed (captures already run under `NO_COLOR`) |
| ASLR hex addresses (`0x…`) | `0xADDR` |
| compiler-internal anon-fn ids (`__anon_1234`) | `__anon_N` |
| the fixture's own absolute path | `<FIXTURE>` |
| the per-run private script-cache staging path | `<STAGING>` |

Everything else — the diagnostic prose, the gutter glyphs, the JSON schema
fields, the symbolized Zap backtrace frames, the per-type leak rollup — is
asserted verbatim.

## Coverage

| fixture | domain / shape |
| --- | --- |
| `parse_error` | `domain=parse` — assignment with no RHS |
| `type_error_two_sided` | `domain=type` — two-sided `TypeProvenance` (got vs declared-here) |
| `undefined_name` | `domain=name` — undefined fn + `did you mean …?` fix-it |
| `runtime_raise` | `domain=panic` runtime `raise` crash + cross-fn `error return trace:` |
| `arithmetic_overflow` | `domain=panic`, `sub_kind=arithmetic_error` overflow trap (safe build) |
| `index_error` | `domain=panic`, `sub_kind=index_error` out-of-bounds `List.get` |
| `leak_report` | `domain=leak` — attributed survivor under `-Dmemory=Memory.Tracking` |

One diagnostic domain is covered by the unit-test suite rather than a
fixture here, because it is not reliably triggerable from a `.zap` source:

- **ICE** (internal compiler error) — by definition not triggerable from
  valid-looking source without a compiler bug; the ICE diagnostic class and its
  routing are covered by the Phase 4.b unit tests.

(There is no `domain=cycle`: a reference cycle is not constructible from Zap's
fully-immutable surface — every value references only strictly-older values, so
the points-to graph is always a DAG and pure reference counting reclaims it
completely. This is a language guarantee, not a gap, so there is no cycle
collector to cover.)

## Adding a fixture

1. Add `<name>.zap` here triggering the new diagnostic.
2. Register it in `run_golden_corpus.sh` with `compile_case <name>` (compile
   error) or `runtime_case <name> [extra -D flags]` (runtime).
3. Run `script_fixtures/run_golden_corpus.sh --update` to write `<name>.txt`
   and `<name>.json`, review them, and commit fixture + goldens together.
