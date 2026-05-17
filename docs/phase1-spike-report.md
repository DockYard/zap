# Phase 1 spike report — Memory Manager ABI

Spike commits:

* Zig fork: `b8f0506156` — `zir_api: add zap_fork_compile_zig_to_object primitive`
* Zap: `9538c7317` — `feat(memory): Phase 1 spike — .zapmem emission, parser, in-process compile`

Spike code lives in `/Users/bcardarella/projects/zap/spike/` and the
parser at `/Users/bcardarella/projects/zap/src/memory/section_parser.zig`.

Tested target: `aarch64-macos-none` (Darwin 25.2.0) for both Mach-O
native compilation and cross-compiled aarch64-linux-gnu ELF object
emission. The cross-compiled ELF object was parsed by the macOS-host
parser (real `std.elf` parsing — not mocked).

---

## 1. Outcomes summary

| Item | Status | Notes |
|------|--------|-------|
| (1) In-process Zig-fork compile primitive | **PASS** | New `zap_fork_compile_zig_to_object` C-ABI added; smoke test compiles `spike/manager_v1/src/manager.zig` in-process and verifies the resulting `.o` contains the expected `.zapmem` section. |
| (2) `.zapmem` section emission + cross-platform parsing | **PASS** | Same Zig source produces correct sections on both Mach-O (`__DATA,__zapmem`) and ELF (`.zapmem`). Parser at `src/memory/section_parser.zig` extracts the section via `std.elf` and `std.macho` with no allocation. |
| (3) No-op manager codegen audit | **PASS (analysis only)** | Phase 6 elision hook identified — `shouldSkipArc` in `src/zir_builder.zig:658` is the natural extension point. No elision implemented in this spike (Phase 6 deliverable). |

All three items met their derisking criterion. The Phase 2 contract-in-
runtime work has a green light to proceed.

Test suite status: `zig build test --summary all` reports
`6/6 steps succeeded; 1040/1040 tests passed` on `main` post-spike.

---

## 2. Item (1) deep-dive — in-process Zig compile primitive

### Implementation

Added at `~/projects/zig/src/zir_api.zig`:

* `pub const ZapForkTarget = extern struct { arch_tag: u16, os_tag: u16, abi_tag: u16, _reserved: u16 }` — wire-format target descriptor per ABI v1.0 Appendix C.
* `pub const ZapForkOptimize = enum(c_int) { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall }` — mirrors `std.builtin.OptimizeMode`.
* `pub const ZapForkResult = enum(c_int) { Ok = 0, SourceNotFound = 1, CompilationFailed = 2, TargetUnsupported = 3, InternalError = 99 }`.
* `pub export fn zap_fork_compile_zig_to_object(source_path, *target, optimize, out_object_path, ?out_diag_buf, diag_cap, ?zig_lib_dir_opt) callconv(.c) ZapForkResult`.
* Private helper `compileToObjectImpl` drives a standalone `Compilation` instance per call: opens caller-supplied or auto-detected `zig_lib_dir`, sets up an arena allocator + `Io.Threaded`, resolves the target query, constructs a `Compilation.Config` with `output_mode = .Obj`, `link_libc = false`, `skip_linker_dependencies = true`, instantiates the root `Package.Module` pointed at the caller's Zig source file directly, calls `Compilation.create` + `compilation.update`, and surfaces error bundles via `dumpErrorBundle` on failure.

### Spec deviation from section 10.1.1

The spec signature reads:

```zig
pub extern fn zap_fork_compile_zig_to_object(
    source_path: [*:0]const u8,
    target: *const ZapForkTarget,
    optimize: ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
) callconv(.c) ZapForkResult;
```

The implementation adds a **seventh parameter** `zig_lib_dir_opt: ?[*:0]const u8`.
Rationale: the Zap binary embeds its pinned Zig stdlib in a tar archive
that gets unpacked to a temp directory at runtime (see Zap's
`extractEmbeddedZigLib` flow in `src/main.zig:2109`). The running binary
is therefore NOT laid out like a normal Zig install, so
`introspect.findZigLibDir` cannot find the stdlib relative to the
self-exe path. The parameter is `?[*:0]const u8` so passing `null`
falls back to the auto-detect path, preserving the spec's behavior for
callers that *are* laid out as a normal install.

**Spec gap (logged below)**: section 10.1.1 needs a `zig_lib_dir` parameter
or the spec needs to acknowledge that Zap's embedded-stdlib pattern
requires a passable override. The cleanest fix is to add `zig_lib_dir:
?[*:0]const u8` as a documented parameter; if null, the primitive auto-
detects.

### Smoke test

`spike/test_driver/test_in_process_compile.zig` is a standalone Zig
binary linked against `libzap_compiler.a` plus the full LLVM/Clang/LLD
static stack. It:

1. Reads `ZIG_LIB_DIR` from the environment.
2. Calls `zap_fork_compile_zig_to_object` to compile
   `spike/manager_v1/src/manager.zig` to
   `spike/manager_v1/manager_inproc.o`.
3. Reads the resulting `.o`, calls `parser.extractSection`, casts the
   first 32 bytes to `ZapMemoryManagerMetaV1`, validates magic/version/
   declared_caps invariants.

Output (`ZIG_LIB_DIR=/Users/bcardarella/projects/zig/lib`):

```
zap_fork_compile_zig_to_object OK
output object: 17472 bytes
detected format: macho
meta.magic         = 0x4d454d5a
meta.abi_major     = 1
meta.abi_minor     = 0
meta.desc_count    = 0
meta.declared_caps = 0x0000000000000000
OK: in-process compile + section parse round-trips
```

### LLVM-context reentrancy

Not exercised. The Zap build orchestrator drives this primitive from
the top level — before any other `Compilation` is alive — so the
"Roc's well-known failure mode" of nested LLVM contexts within an
active codegen pipeline is not on the path. If Phase 6+ needs nested
manager compilation (compiling a manager from within an existing
Compilation that's already running codegen), the design can fall back
to the sub-compilation mechanism that `Compilation.zig` already uses at
multiple sites (e.g., `src/Compilation.zig:5032`, `:7474`, `:7612` for
docs/libc/compiler-rt sub-builds). Those sub-compilations already run
in-process under LLVM with no observed contention; the same pattern
would extend to manager compilation if needed.

### Files touched

* `~/projects/zig/src/zir_api.zig` — 388-line addition. The new entry
  point is callable from Zap's `main.zig` via the existing
  `libzap_compiler.a` link (symbol verified via `nm`:
  `_zap_fork_compile_zig_to_object` is `T` after the rebuild).

No changes to `Compilation.zig`, `link.zig`, or other compiler internals.
The new entry uses the existing public API of `Compilation`.

---

## 3. Item (2) deep-dive — `.zapmem` section emission and parsing

### Mach-O (aarch64-macos-none)

Built via `zig build-obj` of `spike/manager_v1/src/manager.zig`.
`otool -l` of the resulting object reports:

```
Section
  sectname __zapmem
   segname __DATA
      addr 0x0000000000000068
      size 0x0000000000000058    (= 88 bytes = 32 meta + 56 core)
    offset 832
     align 2^3 (8)
    reloff 1360
    nreloc 5                      (relocations for 5 function pointers)
```

`otool -s __DATA __zapmem` of the same object:

```
0000000000000068  4d454d5a 00000001 00000020 00000000   <- meta start
0000000000000078  00000000 00000000 00000020 00000000
0000000000000088  00000001 00000038 00000000 00000000   <- core start
0000000000000098  00000000 00000000 00000000 00000000
00000000000000a8  00000000 00000000 00000000 00000000
00000000000000b8  00000000 00000000
```

* Bytes 0..3: `4d 45 4d 5a` = 0x4D454D5A = `'ZMEM'` little-endian magic.
* Bytes 4..5: `01 00` = abi_major = 1.
* Bytes 6..7: `00 00` = abi_minor = 0.
* Bytes 8..9: `20 00` = size = 32.
* Bytes 10..11: `00 00` = _reserved2 = 0.
* Bytes 12..15: `00 00 00 00` = desc_count = 0.
* Bytes 16..23: `00 00 00 00 00 00 00 00` = declared_caps = 0.
* Bytes 24..27: `20 00 00 00` = core_vtable_offset = 32.
* Bytes 28..31: `00 00 00 00` = reserved = 0.
* Bytes 32..33: `01 00` = core.abi_major = 1.
* Bytes 34..35: `00 00` = core.abi_minor = 0.
* Bytes 36..39: `38 00 00 00` = core.size = 56.
* Bytes 40..47: `00 00 00 00 00 00 00 00` = core.declared_caps = 0.
* Bytes 48..87: 5 × 8 byte function pointers, all zero in the `.o`
  (resolved by the linker via the 5 relocations at `reloff 1360`).

Section name in source: `__DATA,__zapmem`. Zig's `linksection` accepts
this syntactic form directly — no extra attributes needed. The
resulting section is `S_REGULAR` and lives inside the `__DATA` segment
as the spec requires (section 3.1).

### ELF (aarch64-linux-gnu cross-compiled from macOS)

Built via `zig build-obj -target aarch64-linux-gnu`. `objdump -h`:

```
Idx Name            Size     Type
  4 .zapmem         00000058 DATA
  5 .rela.zapmem    00000078        (relocations: 5 entries × 24 bytes)
```

`objdump -s -j .zapmem` of the same object:

```
 0000 5a4d454d 01000000 20000000 00000000  ZMEM.... .......
 0010 00000000 00000000 20000000 00000000  ........ .......
 0020 01000000 38000000 00000000 00000000  ....8...........
 0030 00000000 00000000 00000000 00000000  ................
 0040 00000000 00000000 00000000 00000000  ................
 0050 00000000 00000000                    ........
```

The bytes are bit-identical to the Mach-O dump after byte-swap of the
magic display column. The same Zig source produces the same content on
both formats — the section name dispatch in
`spike/manager_v1/src/manager.zig` is the only target-conditional code.

Section attributes:
* ELF: `SHT_PROGBITS | SHF_ALLOC` (Zig's `linksection` produces this
  automatically for an `extern const` global, since the data is
  loaded into the image's address space at runtime).
* Mach-O: `S_REGULAR` (Zig default for `extern const` linkage).

Neither matches the spec's "loaded into the image's address space at
runtime — required so the section survives static linking" requirement
*by accident*; both produce it as a natural consequence of `linksection`
on a `pub export const ...`. No special attributes needed.

### Parser

`src/memory/section_parser.zig` is a 290-line module that exports:

* `pub fn detectFormat(bytes: []const u8) ObjectFormat` — magic-byte
  dispatch.
* `pub fn extractSection(bytes: []const u8) ![]const u8` — returns a
  slice into the input buffer pointing at the `.zapmem` content. No
  allocation; the parser only reads the section header table.
* `pub const ZapMemoryManagerMetaV1 = extern struct { ... }` — mirror
  of the spec's meta header so callers can `@memcpy` the prefix bytes
  into one without needing a separate import.

Implementation details:

* **ELF**: uses `std.elf.Header.read(&std.Io.Reader.fixed(bytes))` for
  the file header, then `header.iterateSectionHeadersBuffer(bytes)`
  twice — once to find the section-header string table at index
  `header.shstrndx`, then once more to locate the section named
  `.zapmem`. Returns `bytes[sh.sh_offset..sh.sh_offset + sh.sh_size]`.
  Handles 32-bit and 64-bit ELF; rejects unknown classes.
* **Mach-O**: parses the `mach_header_64` directly, walks
  `LC_SEGMENT_64` load commands, and for each iterates the
  `section_64` table inside. Matches `(segname = "__DATA", sectname =
  "__zapmem")`. Handles both `MH_MAGIC_64` and `MH_CIGAM_64`
  (byte-swapped) headers. 32-bit Mach-O returns `UnsupportedFormat`
  (v1.0 supports only 64-bit per Appendix C).
* **COFF**: returns `UnsupportedFormat` for now. The interface is
  structured so adding COFF in Phase 4 is purely additive — no
  changes to ELF/Mach-O paths needed.

The parser has 4 unit tests covering format detection. The end-to-end
test driver (`spike/test_driver/test_section_parse.zig`) validates that
extracting the section from real ELF + Mach-O objects round-trips with
the expected meta-header invariants:

```
=== macOS Mach-O aarch64 ===
  detected format: macho
  section size: 88 bytes
  meta.magic            = 0x4d454d5a (expected 0x4d454d5a)
  meta.abi_major        = 1
  meta.abi_minor        = 0
  meta.size             = 32
  meta._reserved2       = 0
  meta.desc_count       = 0
  meta.declared_caps    = 0x0000000000000000
  meta.core_vtable_offset = 32
  meta.reserved         = 0
  core vtable region    = 56 bytes (at offset 32)
  OK

=== Linux ELF aarch64 ===
  [identical invariants]
  OK
```

No quirks observed. The composite-extern-struct pattern from the
spec's section 14.1 (no_op manager) works as documented on both
formats — Zig's `linksection` preserves the relative order of the
`meta` and `core` fields within the single exported global.

---

## 4. Item (3) deep-dive — codegen elision hook for Phase 6

The spike does NOT implement codegen elision (that's Phase 6); it
identifies where the work goes.

### Where retain/release are emitted today

The retain/release emission pipeline is three layers deep:

1. **Analysis** (`src/perceus.zig`, `src/arc_optimizer.zig`,
   `src/escape_lattice.zig`) — populates
   `AnalysisContext.arc_ops` with `{ kind: .retain | .release | ...,
   value: LocalId, insertion_point: InsertionPoint }` records. These
   are pure analysis output; no IR emission yet.

2. **IR materialization** (`src/arc_materialize.zig:144
   materializeAnalysisArcOps`) — converts analysis records into
   first-class IR instructions `.retain { value, kind }` and
   `.release { value, kind }` inserted into the function body at the
   exact `InsertionPoint`. Reads `analysis_context.arc_ops` and emits
   IR. Field-drops from `analysis_context.drop_specializations` also
   land as `.release` instructions here.

3. **ZIR lowering** (`src/zir_builder.zig:6586` and `:6616`) — the IR
   `.retain` and `.release` instructions lower to ZIR calls into
   `zap_runtime.arc_runtime.retainAny` / `releaseAny` / `freeAny`
   (depending on the IR `kind` field). These calls eventually resolve
   to `src/runtime.zig:2280 freeAny` and `:2317 releaseAny` —
   pool-aware generic helpers that decrement the inline `ArcHeader`
   refcount and free via the per-type `ArcPool`.

### The natural elision hook

`src/zir_builder.zig:658 fn shouldSkipArc(self, local) bool` already
exists. It's currently used by the escape-lattice pass to elide arc
ops on stack-eligible locals:

```zig
fn shouldSkipArc(self: *const ZirDriver, local: ir.LocalId) bool {
    if (self.arc_managed_locals.contains(local)) return false;

    const lattice = @import("escape_lattice.zig");
    if (self.analysis_context) |actx| {
        const vkey = lattice.ValueKey{
            .function = self.current_function_id,
            .local = local,
        };
        if (actx.escape_states.get(vkey)) |state| {
            return state.isStackEligible();
        }
    }
    return false;
}
```

For Phase 6, the extension is:

* Thread a `manager_caps: u64` field through `ZirDriver` (populated
  from the parsed manager `.zapmem` section's `declared_caps`).
* In `shouldSkipArc`, add an early return: if
  `(manager_caps & CAP_REFCOUNT_V1_BIT) == 0`, return `true`
  unconditionally — the active manager has no refcount capability, so
  no retain/release should ever be emitted. The `arc_managed_locals`
  check still wins (those types only make sense under REFCOUNT_V1
  managers, and the type-layout choice happens earlier in HIR — if
  REFCOUNT_V1 is off, those types never get the inline header anyway).

This is also the right place to elide the inline `ArcHeader` field
from the type layout (spec section 10.1 step 6: "If REFCOUNT_V1 is
unset: the type omits the refcount field entirely; the first user
field begins at offset 0."). That's a HIR/type-elaboration concern
that lives elsewhere (around the `runtime.zig` Arc layout helpers and
the per-type cell-allocator generation); the codegen-elision hook
above is the *call-site* half of the same conditional.

### Allocation flow under no-op manager

The spec requires that *only* retain/release be elided when
`declared_caps = 0`. The `allocate` and `deallocate` paths still flow
through the manager. Today's Zap compiler emits allocate via
generated cell-construction code (Map/List/String constructors) and
deallocate via the field-drop / `.release` flow at scope exit. Once
Phase 2 wires the runtime contract, those calls land on
`zap_memory_manager_context.allocate(...)` and
`zap_memory_manager_context.deallocate(...)` (per the spec's section
4.2 / 10.2 storage convention). For the no-op manager, the first
`allocate` call returns null and the runtime aborts — proving that
allocate is actually invoked.

### Spec contract for elision

Re-reading spec section 8.5 ("No-op when capability absent"):

> If a manager does not declare `REFCOUNT_V1`, the compiler statically
> elides every retain and release in user code (the calls simply do not
> appear in the emitted IR).

That's the contract we need to honor in Phase 6. The current emission
pipeline emits a *ZIR call* (`arc_runtime.retainAny(...)`) at every
`.retain` / `.release` IR instruction. To make the elision truly
zero-overhead, the natural design is:

* **At step 2** (materialization), guard the `.retain` / `.release`
  insertion on `manager_caps`. If REFCOUNT_V1 is absent, *don't insert
  the IR instruction at all*. This is cleaner than guarding at step 3
  because it makes the IR itself reflect the active manager —
  downstream passes (verifier, drop-insertion, etc.) see a function
  body with no retain/release work, exactly as if Perceus had decided
  every value was stack-eligible.
* Step 3's `shouldSkipArc` would then remain a fast-path defense in
  case any retain/release slips through (e.g., from a future analysis
  pass that doesn't yet honor `manager_caps`).

Both edits are surgical. The compiler will need to thread the active
`manager_caps` through `AnalysisContext` (or a sibling struct) so both
the materialization pass and the ZIR builder can read it without
re-parsing the `.zapmem` section. The natural source is the spec's
build-pipeline step 4 — the compiler already needs to parse the
section at step 5 (validation), so the parsed `declared_caps` value is
in hand by step 6 (HIR elaboration) and step 7 (codegen) where the
elision hook fires.

---

## 5. Spec gaps surfaced

Issues discovered during the spike, ordered by section:

* **`docs/memory-manager-abi.md:1055`** (section 10.1.1, signature) —
  The `zap_fork_compile_zig_to_object` C-ABI signature in the spec is
  missing a `zig_lib_dir` parameter. The implementation needs one
  because Zap embeds its stdlib tar-archive and unpacks at runtime; the
  running binary is not laid out like a normal Zig install, so
  `findZigLibDir`'s self-exe heuristic fails. Recommended: add
  `zig_lib_dir: ?[*:0]const u8` (last parameter for forward
  compatibility), document that null means "auto-detect via the
  primitive's own runtime context".

* **`docs/memory-manager-abi.md:1067`** (section 10.1.1, package deps) —
  Already acknowledged ("The primitive does not currently accept
  package dependencies"). The spike does not need this; Phase 4
  (third-party manager loader) will. No spec change recommended now;
  add a `dependencies: ?*const ZapForkDeps` parameter when the
  third-party loader work begins.

* **`docs/memory-manager-abi.md:131`** (section 3.1, ELF flags) — The
  spec says "`SHT_PROGBITS`, `SHF_ALLOC` (loaded into the image's
  address space at runtime — required so the section survives static
  linking)". The spike confirms Zig's `linksection` produces both flags
  automatically for an `extern const` with `pub export`. The spec
  could note that the recommended emission pattern (composite extern
  struct via `pub export const linksection(...)`) produces the
  required flags by construction; no manager-side work needed.

* **`docs/memory-manager-abi.md:132`** (section 3.1, Mach-O section
  type) — The spec says "`S_REGULAR`". The spike confirms Zig produces
  exactly `S_REGULAR` by default. Same note as above applies — the
  recommended emission pattern is self-documenting on this.

* **`docs/memory-manager-abi.md:140`** (section 3.2, "fixed order")
  vs. **`docs/memory-manager-abi.md:148`** ("`core_vtable_offset` field
  gives the byte offset") — The spec phrases the layout as both
  *positional* ("placed in fixed order") and *explicit* (read offset
  from `core_vtable_offset`). The spike confirms both work — the
  composite extern struct guarantees positional layout AND
  `@offsetOf(...)` produces the correct explicit offset. Suggest
  collapsing to "the layout is positional; `core_vtable_offset`
  exists only so future minor versions may grow the meta header
  without breaking core-vtable lookup."

* **`docs/memory-manager-abi.md:561`** (section 4.5, "release owns the
  free path") vs. **`docs/memory-manager-abi.md:832`** (section 8.1,
  "User pointer IS the cell's first byte; bytes [0..4] are the atomic
  refcount") — These two are subtly tangled. The spike doesn't yet
  exercise a refcount manager, but reading them together: the cell
  layout per section 8.1 makes `user_ptr[0..4]` the refcount and
  `user_ptr[4..size]` the user data. Section 4.5's "release owns the
  free path" implies release returns `[user_ptr, user_ptr + size)` to
  the allocator. But the spec's worked example (section 15) shows the
  manager prepending a private 16-byte header at `user_ptr - 16` and
  freeing `[user_ptr - 16, user_ptr - 16 + block_size)` — a strictly
  larger region. Both are valid because the manager owns negative
  offsets entirely, but the spec could clarify that "release's free
  path" means the manager's internal freeing logic and the `size`
  parameter is the *user payload size including refcount*, NOT the
  underlying block size. (Reading section 15.1 carefully, this is
  implied — but easy to miss on first read.)

* **`docs/memory-manager-abi.md:1077`** (section 10.2, defining vs.
  consuming declaration) — The spec gives two Zig declarations:
  defining `pub export var zap_memory_manager_context: ?*anyopaque =
  null;` and consuming `pub extern var zap_memory_manager_context:
  ?*anyopaque;`. The spike doesn't exercise this yet (Phase 2 work),
  but a question: where does the *defining* declaration live? The
  spec says "in the Zap runtime" — that's `runtime.zig` in the
  compiler, but the compiler-emitted user code also produces consuming
  declarations as Zig modules. The mechanics of how the linker
  reconciles a runtime-defined `?*anyopaque = null` with multiple
  user-module `extern var` references is straightforward (just a
  COMMON / extern resolution), but the spec doesn't say *which Zig
  module* in Zap's runtime layout owns the defining declaration. Phase
  2 will need to pick a location — likely a new
  `src/runtime/memory.zig` or similar. The spec should name the file.

* **`docs/memory-manager-abi.md:1089`** (section 10.2, panic message)
  — "the unwrap compiles to a single not-null branch on every target;
  the cold panic path emits a deterministic abort with a clear
  diagnostic". The spike doesn't exercise this; Phase 2 will. Note for
  Phase 2: the unwrap idiom `zap_memory_manager_context orelse
  @panic(...)` lowers to a Zig `@panic` which in turn calls the
  std.builtin panic handler — which under Zap's existing runtime is
  the `panic` struct in `src/zir_api.zig:778`. The panic struct
  currently has a single `call(msg, _)` that writes to fd 2 and traps.
  That'll work for the not-initialized panic but the Zap runtime may
  want a more specific exit path for OOM aborts (so they can be
  distinguished from other panics in CI). Not a spec gap, but worth
  flagging for Phase 2 design.

* **`docs/memory-manager-abi.md:704`** (section 7.1, "RESERVED" GCOL
  bit) — The spec rejects managers that declare reserved bits at build
  time (section 3.5). Good — the no-op manager declares 0, so it
  passes trivially. Recommendation: when Phase 4 adds the third-party
  manager loader, the compiler's rejection diagnostic should name
  exactly which reserved bit was declared (the spec says
  `<TAG>` placeholder at line 1115 — confirmed, no gap).

* **Other implementation notes**:
  - The spike's parser at `src/memory/section_parser.zig` returns
    `ExtractError.SectionNotFound | SectionTooSmall | UnsupportedFormat
    | InvalidObject`. Phase 2 needs a more structured error type that
    maps to the spec's section 10.4 diagnostic table. Easy to extend.
  - The composite-extern-struct emission pattern (section 14.1) is
    confirmed working. Recommend the spec promotes it from
    "recommended" to "normative" in section 3.2 — multi-declaration
    emission is documented as implementation-defined and a third-party
    manager that goes that route risks per-linker breakage.

---

## 6. Recommendation for Phase 2

**GO** for Phase 2 (Contract in Runtime).

What Phase 2 should do, refined based on spike findings:

1. **Defining declaration for `zap_memory_manager_context`** — pick a
   stable location. Recommend `src/runtime/memory.zig` (new file). It
   exports the `?*anyopaque` var, the startup hook that calls
   `manager.core.init(null)`, and the validation logic for the
   returned context pointer (null = init failure, abort).

2. **Consuming declaration emission** — extend `zir_builder.zig` to
   inject `pub extern var zap_memory_manager_context: ?*anyopaque;`
   into every Zap-emitted module that touches retain/release/allocate/
   deallocate. Today every emitted module imports `zap_runtime`; the
   extern var declaration goes alongside.

3. **Compiler-side manager parser** — wire `src/memory/section_parser.zig`
   (kept from the spike) into the compile pipeline at the build step.
   The active implementation resolves the manifest's `memory:` adapter
   from the parsed source graph: `Memory.Manager` is a zero-method
   conformance marker, and `resolveMemoryManagerBackendFromSourceGraph`
   takes the source file declaring `impl Memory.Manager for <selected>`
   as the adapter source, then validates the convention-resolved backend
   source. There is no `backend/1` call. Neither the earlier
   attribute-based lookup nor a callable backend resolver was adopted.

4. **Validation + diagnostic surface** — implement spec section 3.5
   validations as Phase 2 work. The diagnostics in section 10.4 form
   the canonical list. Recommendation: a new `src/memory/validate.zig`
   that takes the parsed section bytes + the corresponding manager
   path, runs every validation, and emits diagnostics through Zap's
   existing diagnostic machinery (`src/diagnostics.zig`).

5. **Allocate/deallocate call sites** — Phase 2 doesn't need to wire
   the new manager into every cell-allocation site yet. Today's Zap
   uses per-type `ArcPool` allocators rooted in `runtime.zig`. Phase 2
   can stop short of replacing those — wire the runtime context
   global, ship the parser-integration, and leave the cell-allocator
   redirect for Phase 4 (the ARC-as-manager refactor). That keeps
   Phase 2's scope tight and verifiable.

6. **Memory Manager primitive sig change** — Phase 2 should also
   commit a one-line spec update to section 10.1.1 adding the
   `zig_lib_dir` parameter. The implementation already has it; the
   spec just needs to match. Optional: rename to `dependencies` for
   forward-compat with Phase 4's package-deps need.

No design pivots needed. The three derisking items all hit their
green criterion; the spec ambiguities surfaced are minor and tracked
above.

---

## 7. Pointers for the next person picking this up

* `/Users/bcardarella/projects/zap/spike/manager_v1/src/manager.zig` —
  reference no-op manager; copy this into Phase 4 as the basis for the
  first-party `Memory.NoOp` reference and the `Memory.Arena`
  starting point.
* `/Users/bcardarella/projects/zap/src/memory/section_parser.zig` —
  kept after the spike. Phase 2 integrates this into the build pipeline.
* `/Users/bcardarella/projects/zig/src/zir_api.zig` lines ~400–760 —
  the new `zap_fork_compile_zig_to_object` entry. Phase 4 calls this
  from Zap to compile each project's manager source into an object.
* `/Users/bcardarella/projects/zap/src/zir_builder.zig:658
  shouldSkipArc` — Phase 6's elision hook entry point.
* `/Users/bcardarella/projects/zap/src/arc_materialize.zig:144
  materializeAnalysisArcOps` — Phase 6's elision hook entry point on
  the IR-emission side.

To rerun the spike from scratch:

```sh
# Rebuild the Zig fork's libzap_compiler.a with the new entry:
cd ~/projects/zig
zig build lib \
  --search-prefix ~/zig-bootstrap-0.16.0/out/aarch64-macos-none-baseline \
  -Dstatic-llvm -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-macos-none -Dcpu=baseline -Dversion-string=0.16.0

cp zig-out/lib/libzap_compiler.a ~/projects/zap/zap-deps/aarch64-macos-none/

# Build a fresh manager.o for inspection:
cd ~/projects/zap
zig build-obj spike/manager_v1/src/manager.zig \
  -OReleaseSafe -target aarch64-macos -mcpu baseline \
  -fstrip -fno-stack-check -fno-stack-protector \
  --name manager --cache-dir /tmp/zap-spike-cache
mv manager.o spike/manager_v1/manager_macho.o

# Build the cross-compile ELF version:
zig build-obj spike/manager_v1/src/manager.zig \
  -OReleaseSafe -target aarch64-linux-gnu -mcpu baseline \
  -fstrip -fno-stack-check -fno-stack-protector \
  --name manager_linux --cache-dir /tmp/zap-spike-cache
mv manager_linux.o spike/manager_v1/manager_linux.o

# Verify the parser:
zig run --dep section_parser \
  -Mroot=spike/test_driver/test_section_parse.zig \
  -Msection_parser=src/memory/section_parser.zig

# Verify the in-process compile primitive (heavy build):
cd spike/test_driver && zig build -Doptimize=ReleaseSafe
cd ../..
ZIG_LIB_DIR=$HOME/projects/zig/lib \
  ./spike/test_driver/zig-out/bin/test_in_process_compile
```
