# Zig 0.16 Transition Plan

## Overview

This document is the comprehensive plan for upgrading the Zap Zig fork from Zig 0.15.2 to Zig 0.16.0. The fork exposes a C-ABI surface (82 exported functions across ~5,100 lines) that lets Zap emit ZIR programmatically into Zig's compilation pipeline. The upgrade requires rebasing this fork onto the 0.16.0 tag from upstream, updating all internal API usage, and migrating Zap's own codebase to the new standard library.

## Git Strategy

### Current State
- Fork origin: `https://github.com/DockYard/zig` (based on Zig 0.15.2)
- Upstream remote `codeberg`: `https://codeberg.org/ziglang/zig` (already added to the fork repo)
- Current fork branch: `zap-zir-library` (contains all Zap C-ABI additions on top of 0.15.2)
- Fork adds 2 new files (`src/zir_api.zig`, `src/zir_builder.zig`) and modifies 5 files (`build.zig`, `src/main.zig`, `src/Compilation.zig`, `src/Zcu.zig`, `src/Zcu/PerThread.zig`)

### Rebase Plan
```sh
cd ~/projects/zig

# The codeberg remote is already configured:
#   git remote add codeberg https://codeberg.org/ziglang/zig.git

# Fetch the 0.16.0 tag from upstream
git fetch codeberg --tags

# Create a new branch from the upstream 0.16.0 tag
git checkout -b zap-zir-library-0.16 0.16.0

# Identify the fork commits on the current branch
git log --oneline origin/zap-zir-library --not 0.15.2
# This shows the commits that need to be ported

# Cherry-pick each fork commit onto the 0.16 base
git cherry-pick <commit-hash-1>    # initial zir_api.zig + zir_builder.zig
git cherry-pick <commit-hash-2>    # build.zig lib target
git cherry-pick <commit-hash-3>    # Compilation.zig zir_injected bypass
# ... resolve conflicts in each modified file

# Once all commits are ported and conflicts resolved:
git push origin zap-zir-library-0.16

# After validation, update the main working branch:
git branch -m zap-zir-library zap-zir-library-0.15  # archive the old branch
git branch -m zap-zir-library-0.16 zap-zir-library   # promote the new one
git push origin zap-zir-library --force-with-lease
```

The fork's modifications are isolated — two new files and small surgical changes to five upstream files. Cherry-picking is cleaner than merging because it avoids pulling in the entire 0.15.2 history. The `codeberg` remote provides direct access to upstream tags without needing a separate clone.

## Bootstrap Update

### Current Process (0.15.2)
```sh
git clone --depth 1 --branch 0.15.2 \
  https://codeberg.org/ziglang/zig-bootstrap.git ~/zig-bootstrap-0.15.2
cd ~/zig-bootstrap-0.15.2 && ./build aarch64-macos-none baseline
```

### New Process (0.16.0)
```sh
git clone https://codeberg.org/ziglang/zig-bootstrap.git ~/zig-bootstrap-0.16.0
cd ~/zig-bootstrap-0.16.0 && ./build aarch64-macos-none baseline
```

There is no dedicated 0.16.0 tag on zig-bootstrap yet. Use master, which contains Zig 0.16.0 with LLVM 21.1.0.

The bootstrap process itself is unchanged. The `./build` script handles:
1. Host LLVM 21.1.0 build (~20 min)
2. Host Zig 0.16.0 bootstrap via wasm2c → zig1 → zig2 → stage3 (~15 min)
3. Target LLVM rebuild with Zig as compiler (~30 min)

Total: ~65 minutes per target.

### Build libzap_compiler.a
```sh
cd ~/projects/zig
ROOTDIR="$HOME/zig-bootstrap-0.16.0"
TARGET="aarch64-macos-none"
ZIG="$ROOTDIR/out/host/bin/zig"

$ZIG build lib \
  --search-prefix "$ROOTDIR/out/$TARGET-baseline" \
  -Dstatic-llvm \
  -Doptimize=ReleaseSafe \
  -Dtarget="$TARGET" \
  -Dcpu=baseline \
  -Dversion-string="0.16.0"
```

The `zig build lib` command is unchanged. Output: `zig-out/lib/libzap_compiler.a`.

### Targets to Build
- `aarch64-macos-none` (development, CI)
- `aarch64-linux-gnu` (CI, production)
- `x86_64-linux-gnu` (CI, production)

## Fork Modifications: File-by-File Port

### New Files (copy and update)

#### `src/zir_api.zig` (2,206 lines, 82 exported functions)

This is the main C-ABI surface. It wraps Zig compiler internals. Every internal API call must be verified against 0.16.

**Compilation lifecycle functions (9):**
- `zir_compilation_create` — wraps `Compilation`, `Zcu`, `Package.Module`. Verify struct field changes.
- `zir_compilation_update` — wraps `Compilation.update()`. Signature likely stable but internal Sema behavior changed fundamentally (DAG-based type resolution).
- `zir_compilation_add_module_source` — wraps `Zcu.File`, `intern_pool.createFile()`. Verify InternPool API.
- `zir_compilation_add_module` — wraps `Package.Module.create()`, `module_roots`. Verify module registration.
- `zir_compilation_add_link_lib` — wraps `link.Input`. Verify linker type changes.
- `zir_compilation_destroy` — cleanup. Should be straightforward.
- `zir_compilation_print_errors` — wraps `ErrorBundle`. Verify error format.
- `zir_compilation_set_builder_entry` — builder mode config.

**ZIR builder functions (73):**

These wrap `FuncBody` and `Builder` methods that emit ZIR instructions. The critical dependency is on `Zir.Inst.Tag`, `Zir.Inst.Ref`, and `Zir.Inst.Data`.

Research indicates the core ZIR instruction tags (`.block`, `.condbr`, `.call`, `.import`, `.field_val`, `.param`, `.ret_node`, `.int`, `.float`, `.str`, etc.) remain stable in 0.16. The AstGen/ZIR rewrite (issue #22565) is tracked as a multi-release effort not complete for 0.16.

**Action items:**
1. Verify every `Zir.Inst.Tag` value used still exists in 0.16's `lib/std/zig/Zir.zig`
2. Verify every `Zir.Inst.Ref` named constant still has the same enum position
3. Verify `Zir.Inst.Data` union layout hasn't changed
4. Verify extra data encoding format for each payload type

#### `src/zir_builder.zig` (2,825 lines, 72 public methods)

The type-safe Zig API for ZIR construction. Depends on the same `Zir.Inst.*` types.

**Action items:**
Same as zir_api.zig — verify all instruction tags, refs, and data encodings.

### Modified Files (resolve conflicts)

#### `build.zig`
- Lines 377-456: `lib` target and `addCompilerLibStep()`. Verify `b.addLibrary()` API in 0.16.
- Lines 652-679: Test step for zir_api. Verify test API.
- The `aro` and `aro_translate_c` module imports may have changed.

#### `src/main.zig`
- Lines 39-51: `@import("zir_api.zig")` and comptime export block. Should port cleanly — just import and force-export.

#### `src/Compilation.zig`
- Lines ~5518-5520: `if (file.zir_injected) return;` in `workerUpdateFile()`. Find the equivalent location in 0.16's Compilation.zig and add the same check.

#### `src/Zcu.zig`
- `zir_injected: bool = false` field on `Zcu.File`. Find the File struct in 0.16 and add the field.

#### `src/Zcu/PerThread.zig`
- AstGen bypass for `zir_injected` files. Find the equivalent AstGen entry point and add the bypass.

## ZIR Instruction Compatibility

### Tags Used by Zap (verify each exists in 0.16)

**Control flow:** `.block`, `.block_inline`, `.condbr`, `.condbr_inline`, `.break_inline`, `.@"break"`
**Functions:** `.param`, `.param_anytype`, `.call`, `.ret_node`, `.ret_implicit`
**Literals:** `.int`, `.float`, `.str`, `.enum_literal`, `.error_value`
**Arithmetic:** `.add`, `.sub`, `.mul`, `.div_trunc`, `.mod_rem`, `.addwrap`, `.subwrap`, `.mulwrap`
**Comparison:** `.cmp_eq`, `.cmp_neq`, `.cmp_lt`, `.cmp_gt`, `.cmp_lte`, `.cmp_gte`
**Bitwise:** `.bit_and`, `.bit_or`
**Logic:** `.negate`, `.bool_not`
**Types:** `.as_node`, `.ptr_cast`, `.optional_type`, `.error_union_type`
**Imports:** `.import`, `.field_val`, `.field_ptr`, `.decl_val`
**Aggregates:** `.struct_init_anon`, `.struct_init`, `.union_init`, `.array_init_anon`, `.elem_val_imm`
**Optional/Error:** `.is_non_null`, `.optional_payload_unsafe`, `.optional_payload_safe`, `.try`, `.catch_`, `.is_non_err`, `.err_union_payload_unsafe`
**Memory:** `.store_node`
**Debug:** `.dbg_stmt`
**Extended:** `.struct_decl`, `.ptr_cast_full`, `.switch_block`, `.union_decl`

### Refs Used by Zap (verify enum positions stable)

**Types:** `.bool_type`, `.i8_type` through `.i64_type`, `.u8_type` through `.u64_type`, `.usize_type`, `.isize_type`, `.f16_type`, `.f32_type`, `.f64_type`, `.slice_const_u8_type`, `.void_type`, `.anyerror_type`
**Values:** `.void_value`, `.unreachable_value`, `.null_value`, `.bool_true`, `.bool_false`
**Special:** `.none`

### Call Modifier Values
- `3` = no_optimizations
- `4` = always_tail

Verify these enum values haven't shifted.

## Sema Changes Impact

### Type Resolution Redesign (PR #31403)

The 30,000-line type resolution redesign changes Sema from cyclic to DAG-based dependency resolution. Impact on Zap's injected ZIR:

**Lazy field analysis:** Container types only resolve fields when size or field type is needed. Unused types serve as namespaces without triggering analysis. This benefits Zap — modules that import zap_runtime but only use some types won't force full analysis.

**Stricter dependency loops:** The compiler now detects and rejects circular dependencies that were previously tolerated. Zap must ensure:
- zap_runtime doesn't reference Zap-generated modules
- Injected modules don't have circular @import chains
- Return type declarations via `@import("zap_runtime").ListType` resolve before the function body is analyzed

**Detailed error messages:** Dependency loop errors now show the exact chain. This will make debugging injection issues much easier.

### Condbr/Block Analysis

Zap uses `block + condbr` extensively for pattern dispatch. Sema's branch analysis is stricter in 0.16 — both branches must produce compatible types. The `addCondBranchWithBodies` function in the fork (block_inline + condbr with no break in the then-branch) needs validation against 0.16 Sema.

## Zap Codebase Migration

### src/runtime.zig

The runtime is linked into compiled Zap programs. It uses these deprecated/changed APIs:

| Current API | 0.16 Replacement | Occurrences |
|---|---|---|
| `std.fs.File.stdout().deprecatedWriter()` | New writer via `std.Io` | 5 |
| `std.atomic.Value(u32)` | Verify API stable | Throughout ARC |
| `std.mem.eql`, `std.mem.readInt` | Stable | Throughout |
| `std.fmt.bufPrint` | Stable | Throughout |

The runtime's core functionality (bump allocation, ListCell, MapCell, atom interning) uses low-level memory operations that should be stable. The I/O operations (stdout/stderr writes) need migration.

### src/main.zig

The CLI entry point uses many APIs that changed:

| Current API | 0.16 Replacement | Occurrences |
|---|---|---|
| `std.fs.File.stderr().deprecatedWriter()` | New writer via `std.Io` | 15+ |
| `std.process.argsAlloc()` | Verify stable or use `std.process.Init` | 1 |
| `std.process.getEnvVarOwned()` | Verify stable | 3 |
| `std.fs.selfExePathAlloc()` | `std.process.executablePathAlloc()` | 1 |
| `std.fs.cwd()` | Verify stable or migrate to `std.Io.Dir` | 10+ |
| `std.fs.path.join()` | Verify stable | 10+ |

### src/zir_backend.zig

| Current API | Issue | Action |
|---|---|---|
| Hardcoded `.asdf/installs/zig/0.15.2/lib` path | Version-specific | Update to 0.16.0 or detect dynamically |

### build.zig

| Current API | 0.16 Status | Action |
|---|---|---|
| `b.graph.zig_lib_directory` | **REMOVED** | Find alternative to detect Zig lib path |
| `b.graph.zig_exe` | Possibly changed | Verify field exists |
| All other APIs | Stable | No changes needed |

## LLVM 21 Considerations

### Changes from LLVM 20
- Loop vectorization disabled due to regression (Zig workaround)
- New optimization passes for generated code
- Updated target support

### Impact on Zap
- Compiled Zap programs get LLVM 21 codegen (potentially better native performance)
- Loop vectorization disabled means some numeric-heavy Zap programs may be slower until the LLVM regression is fixed
- New targets available: loongarch32, aarch64-maccatalyst, x86_64-maccatalyst

### Linking Changes
- New ELF linker: faster, more correct linking on Linux
- Can generate import libraries from .def files without LLVM
- Zap links 200+ LLVM/Clang/LLD static libraries — all need to be from the LLVM 21 bootstrap

## New Zig 0.16 Features Zap Should Adopt

### Immediate Value

**Lazy field analysis.** Reduces compile times for multi-module Zap projects where not all imported types are used.

**Better error messages.** Dependency loop errors now show exact chains. Compilation errors have better source location tracking.

**Thread-safe lock-free ArenaAllocator.** Free performance improvement for Zap's compilation pipeline.

**Pointer to comptime-only types now runtime.** `*comptime_int` is a valid runtime type. This may improve how Sema handles intermediate computations in condbr bodies — the class of `void vs comptime_int` issues we encountered may be reduced.

**Small integer coercion to floats.** Better ergonomics for numeric code in Zap programs.

### Future Value (Enables Concurrency Model)

**Io.Evented green threads.** Foundation for Zap's planned Erlang-style process model:
- `Future(T)` → process handles
- `Queue(T)` → process mailboxes
- `Select` → receive with timeout
- `Group` → supervisors
- `io.cancel()` → process shutdown

**Io.Uring (Linux), Io.Kqueue (BSD), Io.Dispatch (macOS GCD).** Platform-specific async backends for high-throughput I/O in Zap programs.

**Cancelation model.** `error.Canceled` + structured cleanup via defer/errdefer. Maps to process lifecycle management.

Note: Io.Evented networking is NOT yet complete in 0.16. File I/O, timers, and process spawning work. TCP/UDP support is experimental.

### Language Features

**Switch improvements.** Packed struct/union as prongs, decl literals, union tag captures for all prongs. Could simplify Zap's ZIR emission for union dispatch.

**`@Struct`, `@Union`, `@Enum` builtins.** Replace `@Type`. Could enable more powerful metaprogramming in Zap's runtime for generic type construction (ListCellOf, etc.).

## Removed/Deprecated Features to Handle

| Removed | Replacement | Impact on Zap |
|---|---|---|
| `@cImport` | `addTranslateC` in build system | None — Zap doesn't use C imports |
| `@intFromFloat` | `@trunc` | None — Zap uses explicit integer operations |
| `std.Thread.Pool` | Use `Io.Group` | None — Zap doesn't use thread pools |
| `std.Thread.Mutex.Recursive` | Removed entirely | None |
| `std.SegmentedList` | Removed | None |
| `std.meta.declList` | Removed | None |
| Oracle Solaris, IBM AIX, z/OS targets | Removed | None — not Zap targets |

## Updated Toolchain Versions

| Component | 0.15.2 | 0.16.0 |
|---|---|---|
| LLVM | 20.1.2 | 21.1.0 |
| musl | 1.2.4 | 1.2.5 |
| glibc | 2.41 | 2.43 |
| Linux headers | 6.13 | 6.19 |
| macOS headers | 26.1 | 26.4 |

## Execution Order

### Phase 1: Bootstrap (1 day)
1. Clone zig-bootstrap master (contains 0.16.0)
2. Build for aarch64-macos-none
3. Verify host Zig is 0.16.0: `out/host/bin/zig version`
4. Verify LLVM libs exist: `ls out/aarch64-macos-none-baseline/lib/`

### Phase 2: Port the Zig Fork (1-2 weeks)
1. Create `zig-0.16-port` branch from upstream 0.16.0 tag
2. Cherry-pick fork commits, resolving conflicts:
   - `src/zir_api.zig` — new file, no conflict, but verify all internal API calls
   - `src/zir_builder.zig` — new file, verify Zir.Inst.* usage
   - `build.zig` — merge lib target into 0.16's build.zig
   - `src/main.zig` — add import and comptime export block
   - `src/Compilation.zig` — add `zir_injected` bypass
   - `src/Zcu.zig` — add `zir_injected` field
   - `src/Zcu/PerThread.zig` — add AstGen bypass
3. Build libzap_compiler.a with the bootstrapped Zig
4. Run the fork's own tests: `zig build zir_api_tests`

### Phase 3: Migrate Zap Codebase (1-2 weeks)
1. Update `build.zig` — fix `b.graph.zig_lib_directory` removal, update version strings
2. Update `src/zir_backend.zig` — fix hardcoded 0.15.2 path
3. Update `src/runtime.zig` — migrate `deprecatedWriter()` to new I/O
4. Update `src/main.zig` — migrate all deprecated APIs
5. Update `src/zir_builder.zig` — verify all `Zir.Inst.Tag` and `Zir.Inst.Ref` usage compiles
6. Copy rebuilt libzap_compiler.a to `zap-deps/`
7. Build Zap: `zig build`

### Phase 4: Validate (1 week)
1. Run unit tests: `zig build test`
2. Run integration tests: verify all `zir_integration_tests.zig` pass
3. Run Zap test suite: `zap test` — all 352+ tests must pass
4. Run on all target platforms
5. Test for comprehensions, cons pattern dispatch, monomorphization
6. Performance comparison: compile time and binary size vs 0.15.2

### Phase 5: Release (1 day)
1. Build libzap_compiler.a for all three targets
2. Create GitHub release `v0.16.0-zap.1` with pre-built deps tarballs
3. Update Zap's README with 0.16.0 instructions
4. Update default download URLs in build.zig
5. Tag and push

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| ZIR instruction tags changed | Low | Critical | Verify every tag against 0.16 source before starting |
| Zir.Inst.Ref enum reordered | Low | Critical | Compare enum definitions side by side |
| Compilation.zig internals restructured | Medium | High | The `zir_injected` bypass is 3 lines — easy to relocate |
| Extra data encoding changed | Low | Critical | Test with simple ZIR injection first |
| Stricter dependency loops reject valid Zap ZIR | Medium | Medium | Audit zap_runtime dependency graph |
| New Sema rejects condbr patterns that worked in 0.15 | Low | High | Run all integration tests early in Phase 4 |
| LLVM 21 codegen regression | Low | Medium | Monitor binary correctness and performance |
| build.zig API breakage | Medium | Low | Only `b.graph.zig_lib_directory` is confirmed broken |

## Success Criteria

- All 352+ Zap tests pass
- All ZIR integration tests pass
- For comprehensions compile and run
- Cons pattern dispatch with arithmetic works
- No regressions in compile time (within 10%)
- No regressions in generated binary size (within 5%)
- Pre-built deps published for all three platforms
- README updated with 0.16.0 instructions
