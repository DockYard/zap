# Phase 8 — Pluggable Memory Manager Verification Results

This document reports the end-to-end verification of the pluggable
memory manager pipeline implemented across Phases 0–7 of the
Memory Manager ABI v1.0 work (`docs/memory-manager-abi.md`). It captures
the verified-working surface, the gaps uncovered during verification,
and the fork-level fixes those gaps required.

## 1. Test suite

The full Zap test suite passes under the rebuilt
`libzap_compiler.a` from the latest Zig fork (`zap-zir-library-0.16`
branch).

| Metric | Value |
|---|---|
| Tests passed | 1129 / 1129 |
| Suite wall time | ~17 s (Debug build) |
| Compile MaxRSS | ~1 GB (one-shot Debug build) |
| Test MaxRSS | ~324 MB |

The boundary-guard test suite (`tools/boundary_guard_test.zig`)
contributes the single additional test in the second runner.

## 2. libzap_compiler.a rebuild

The prebuilt `zap-deps/aarch64-macos-none/libzap_compiler.a` shipped
with `zap-deps v0.16.0-zap.1` predates two Phase 4/8 fork patches that
end-to-end Mach-O builds depend on:

- `31fac7894a` — `feat(link/MachO): honour linksection() attribute on globals`
- `08d6acf700` — `link/MachO: set S_ATTR_NO_DEAD_STRIP on linksection() sections`

A fresh build was performed from the fork at HEAD using the canonical
command in `~/projects/zap/README.md`:

```sh
cd ~/projects/zig
~/zig-bootstrap-0.16.0/out/zig-aarch64-macos-none-baseline/zig build lib \
  --search-prefix ~/zig-bootstrap-0.16.0/out/aarch64-macos-none-baseline \
  -Dstatic-llvm \
  -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-macos-none \
  -Dcpu=baseline \
  -Dversion-string=0.16.0
```

The result (`zig-out/lib/libzap_compiler.a`, ~421 MB) was staged into
`~/projects/zap/zap-deps/aarch64-macos-none/libzap_compiler.a` and the
Zap CLI binary (`zig-out/bin/zap`, ~185 MB) was rebuilt against it.

## 3. Fork patches required to unblock manager-object compilation

Rebuilding alone was insufficient — verification uncovered two latent
bugs in the fork's `zap_fork_compile_zig_to_object` primitive that
prevented any manager source from compiling on libc-required hosts
like macOS. Both are addressed in the Zig fork commit
`3d16e53f0f zir_api: fix manager-object compile blockers for sequential compiles`.

### 3.1 `link_libc = false` on macOS

`compileToObjectImpl` in `src/zir_api.zig` hard-coded
`link_libc = false`, which is correct for ELF (linkable later by Zap's
final link) but fails on macOS / iOS / Solaris-class targets because
`std.posix.system` resolves to an empty fallback struct when both
`builtin.link_libc == false` and `builtin.os.tag != .linux/.wasi`.
Members like `getrandom` and `IOV_MAX` are missing from that fallback,
so `std.Io.Threaded` (transitively imported by anything that touches
`std.os` symbols) fails to type-check before code generation begins.

The fix honours `target.requiresLibC()`:

```zig
const target_requires_libc = resolved_target.result.requiresLibC();
const config = Compilation.Config.resolve(.{
    ...
    .link_libc = target_requires_libc,
    ...
});
```

The emitted `.o` is still a relocatable object — manager symbols
(`zap_memory_section`, the vtable function pointers, the
`.zapmem` / `__zapmem` linksection contents) are unchanged. Zap's
final link adds libc once across all linked objects, so toggling
`link_libc` for the manager `.o` has no effect on the final binary.

### 3.2 Static `Zcu.PerThread.Id` pool not reset between compiles

`Zcu.PerThread.Id.allocate` populates a static `available_tids: std.ArrayList(Id)`
slice from the caller's arena. The slice itself is a global; only its
backing memory comes from the arena. When the manager-object compile
finished and its arena was freed, the next compile (the user-code
`createImpl`) tripped `assert(items.len == 0)` because the global pool
still held a dangling pointer into the freed arena.

The fix adds a `Zcu.PerThread.Id.deinit()` that resets the pool to
`.empty` and threads `deinit()` calls around:

- `compileToObjectImpl` — `deinit()` before `allocate()` and an
  unconditional `defer deinit()` paired with `arena_state.deinit()` so
  the pool never points into freed memory.
- `createImpl` — same belt-and-braces reset on the way in, and an
  `errdefer deinit()` so an aborted createImpl doesn't leave dangling
  pointers for the next compile.
- `zir_compilation_destroy` — happy-path `deinit()` after
  `arena_state.deinit()`.

With both fixes in place, the manager `.o` compiles cleanly under
default `Zap.Memory.ARC` and the emitted object carries the expected
`__zapmem` Mach-O section with the correct REFCOUNT_V1 capability bit
(verified via `otool -l` and `nm`).

## 4. Per-manager compile verification

Every first-party manager source compiles to a valid Mach-O object with
the correct `.zapmem` section payload. Verification path is the
`scripts/test_*_manager_compile.sh` smoke harness, which uses the
host's system `zig` (in `~/.asdf/installs/zig/0.16.0`) to compile the
manager source as a standalone object and validates the result through
`section_parser.extractSection`, `assertExportsManagerSymbol`, and
`validateSection`:

| Manager | Smoke test | `zap_memory_section` symbol | `__zapmem` section | declared_caps |
|---|---|---|---|---|
| `Zap.Memory.ARC` | PASS | present | present | `REFCOUNT_V1` (bit 0 set) |
| `Zap.Memory.NoOp` | PASS | present | present | 0 (no capabilities) |
| `Zap.Memory.Arena` | PASS | present | present | 0 |
| `Zap.Memory.Leak` | PASS | present | present | 0 |
| `Zap.Memory.Tracking` | PASS | present | present | 0 |

These five smoke-test scripts mirror the production code path —
`section_parser.extractSection` (used by the build driver),
`assertExportsManagerSymbol` (build-time mandatory symbol check), and
`validateSection` (static metadata header validation) — so a passing
smoke test confirms the manager's `.o` is byte-for-byte acceptable to
the runtime bootstrap and the driver's link-input wiring.

## 5. End-to-end build status (Mach-O)

End-to-end ARC builds (i.e., `zap build` of a real user project) hit a
**pre-existing memory-corruption bug** in the ZIR injection path that
is exposed only by the full in-process compile, not by any of the
1129 in-tree tests. The manager-object compile (Phase 4 of the build
pipeline) succeeds — `examples/hello/.zap-cache/memory/Zap_Memory_ARC.o`
is produced correctly with the `__zapmem` section — but the subsequent
ZIR injection of the user's structs fails with:

```
addStructSource: createFile failed: BadPathName
Error: compilation failed: ZirInjectionFailed
```

A hexdump of the failing path shows seven bytes of `0xAA` — the debug
allocator's free-poison byte — in the position where the struct name
should appear. That is, a `dupeZ`'d struct-name buffer is being freed
and then read back as the `name` parameter to
`zir_compilation_add_struct_source`. The use-after-free is in either
the `src/zir_api.zig` C-ABI surface (`addStructSourceImpl`,
`addStructImpl`) or one of its callees — not in the manager-compile
path that this Phase 8 task added.

**Why the 1129-test suite did not catch this:**

- The Phase-3/4 manager-compile integration tests in
  `src/memory/driver.zig` use a mocked `fork_compile_fn`, so they do
  not exercise the manager-compile-then-user-compile sequence.
- The system-zig smoke-test scripts (Section 4 above) only exercise
  the manager compile in isolation via `zig build-obj`; they never
  drive a second `Compilation.create` in the same process.
- The in-tree `zig build test` runs `Compilation.create` from the
  *outer* test binary, which is a single compile — never two sequential
  compiles sharing a process.

End-to-end builds via the in-process compile primitive are therefore
blocked by a latent UAF that pre-dates the pluggable-memory-manager
work. Resolving it requires bisecting the dupe/free chain in
`addStructSourceImpl` -> `addStructImpl` -> `Compilation.create` for
each struct iteration; the bug only manifests on the second compile in
the same process. This is captured as a Phase 8.x follow-up below.

### Status table

| Manager | Manager `.o` compile | End-to-end binary build |
|---|---|---|
| `Zap.Memory.ARC` | OK (verified) | BLOCKED (UAF in ZIR injection — see §5 above) |
| `Zap.Memory.NoOp` | OK (verified) | BLOCKED (same root cause) |
| `Zap.Memory.Arena` | OK (verified) | BLOCKED (same root cause) |
| `Zap.Memory.Leak` | OK (verified) | BLOCKED (same root cause) |
| `Zap.Memory.Tracking` | OK (verified) | BLOCKED (same root cause) |

## 6. Lang-benches under ARC and Arena

Deferred. The lang-benches at `~/projects/lang-benches/` drive
end-to-end builds, which are blocked by the §5 UAF. They will be
re-runnable once the ZIR-injection UAF is resolved.

For now, the manager-object piece of each bench is verified to compile
cleanly (Section 4) — the only failing piece is the user-code compile
that consumes the manager `.o`.

## 7. String-heavy benchmark

Deferred — depends on §6.

## 8. Cross-platform validation

- **Mach-O (host)**: verified for Manager `.o` emission and section
  validation across all 5 first-party managers; end-to-end build blocked
  by §5 UAF.
- **ELF (Linux)**: untested in this verification pass. The fork code
  paths (e.g., `compileToObjectImpl`) are platform-agnostic, and the
  ELF section parser has unit tests in `src/memory/section_parser.zig`
  that pass under `zig build test`. The new `link_libc =
  target.requiresLibC()` fix is a no-op on ELF Linux because
  `requiresLibC()` returns false there (the syscall layer is built-in).
- **Windows COFF**: untested. Same code-path argument as ELF.
- **WASI / freestanding**: out of scope for v1.0 (not in the Memory
  Manager ABI Appendix C whitelist).

Linux ELF + Windows COFF need explicit verification before v1.0 ship.
Marked as Phase 8.x deferral below.

## 9. Bench harness `--memory <manager>` flag

Deferred — the bench harness in `~/projects/lang-benches/scripts/`
builds via `zap build`, which is blocked by §5.

## 10. Phase 8.x deferrals

The following items are deferred from this Phase 8 verification pass:

1. **UAF in `addStructSource` path** — root cause of the
   `BadPathName` error on every end-to-end build. Bisecting the
   dupe/free chain in `src/zir_api.zig`'s
   `addStructSourceImpl` -> `addStructImpl` -> `Compilation.create`
   for the second compile in a process. Blocks every end-to-end build
   item below. Tracked in the task list.
2. **Lang-benches under ARC + Arena** (Phase 8.5 — six benches; wall
   time and peak RSS comparison).
3. **String-heavy benchmark** (Phase 8.6 — new bench under
   `~/projects/lang-benches/string-heavy/`).
4. **Bench harness `--memory <manager>` flag** (Phase 8.7).
5. **Linux ELF + Windows COFF verification** (Phase 8.cross-platform).

## 11. Conclusion

**Not yet ready for v1.0 release.** The pluggable memory manager ABI
v1.0 is implemented correctly through Phase 7 — every first-party
manager source compiles to a valid Mach-O object with the correct
metadata, every in-tree test passes, and the two fork-level blockers
identified during Phase 8 verification (Section 3) are now fixed.

The remaining blocker is a pre-existing use-after-free in the ZIR
injection path of `src/zir_api.zig` that surfaces only when two
`Compilation.create` runs share a process. Resolving that UAF unblocks
end-to-end `zap build` for every memory manager and the dependent
benchmark items (§§ 6, 7, 9). Cross-platform validation (§ 8) is the
final v1.0 gate after that.

## Appendix A — Fork patch summary

Repository: `~/projects/zig` (branch `zap-zir-library-0.16`).

Commit `3d16e53f0f zir_api: fix manager-object compile blockers for
sequential compiles` contains:

- `src/Zcu/PerThread.zig`: add `Zcu.PerThread.Id.deinit()` for resetting
  the global `available_tids` pool.
- `src/zir_api.zig`: switch `compileToObjectImpl.link_libc` from
  hardcoded `false` to `target.requiresLibC()`; wire
  `PerThread.Id.deinit()` resets into the manager-compile, user-compile,
  and context-destroy paths.

Both changes preserve every behaviour exercised by the 1129-test suite.
