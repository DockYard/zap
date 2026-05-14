# Memory Manager ABI v1.0 — Normative Specification

**Status:** Normative. Final for v1.0. Any incompatible change requires an ABI major bump (v2.0).

**Audience:** Third-party authors of Zap memory managers, contributors to the Zap compiler and runtime, and authors of the stdlib `Memory.ARC` and `Memory.Arena` managers.

**Scope:** This document specifies the binary interface, build-time discovery protocol, and semantic contract that every Zap memory manager — stdlib or third-party — must implement. The specification is normative: ambiguity in this document is a defect of this document, not a license for implementer choice.

---

## 1. Overview

A Zap memory manager is a Zig package plus a Zap adapter struct. The
Zig package supplies runtime allocation, deallocation, and optionally
reference-counting, finalization, weak-reference, and other
memory-related primitives. The Zap adapter implements `Memory.Manager`
and gives the source-level program a stable, public manager name.
Exactly one manager is selected per binary at build time via the
project's `build.zap` manifest:

```
%Zap.Manifest{
  name: "my_app",
  memory: Memory.ARC,    # or Memory.Arena
  ...
}
```

The source model is adapter-driven: stdlib and project managers are
top-level structs that implement `Memory.Manager`. The selected adapter
value in `Zap.Manifest.memory` is evaluated at build time, and the
compiler obtains the public manager name, primitive Zig source
reference, and declared capability mask by calling the protocol
functions. No manager uses a special source attribute or a compiler name
table.

### 1.1 The build pipeline at a glance

```
Zap.Manifest.memory: Memory.ARC
        |
        v
Resolve adapter name
        |
        v
Evaluate Memory.Manager.name/1, primitive_source_path/1,
capability_mask/1, and refcount_v1?/1 through CTFE
        |
        v
Resolve primitive_source_path/1 using zap:, project:, or dep:<name>:
and compile the selected manager source to a validation object
        |
        v
Validate ZapMemoryManagerMetaV1 + embedded ZapMemoryManagerCoreV1
  (magic, abi_major, caps consistency, core vtable offset);
cross-check the validated .zapmem caps against adapter capability_mask/1
        |
        v
Thread declared_caps into HIR type elaboration
  (Map/List/String layout branches on REFCOUNT_V1)
        |
        v
Thread declared_caps into codegen
  (retain/release calls elided if REFCOUNT_V1 absent)
        |
        v
Register the selected primitive source as zap_active_manager in the final Zap binary
```

### 1.2 Stdlib manager locations

| Manager | Zap adapter | Zap source | Zig source |
|---|---|---|---|
| `Memory.ARC` | `Memory.ARC` | `lib/memory/arc.zap` | `src/memory/arc/manager.zig` |
| `Memory.Arena` | `Memory.Arena` | `lib/memory/arena.zap` | `src/memory/arena/manager.zig` |
| `Memory.NoOp` | `Memory.NoOp` | `lib/memory/no_op.zap` | `src/memory/no_op/manager.zig` |
| `Memory.Leak` | `Memory.Leak` | `lib/memory/leak.zap` | `src/memory/leak/manager.zig` |
| `Memory.Tracking` | `Memory.Tracking` | `lib/memory/tracking.zap` | `src/memory/tracking/manager.zig` |

Third-party managers follow the same `Memory.Manager` adapter contract.
Their primitive source reference normally uses `project:<path>` for
project-local code or `dep:<name>:<path>` for dependency-provided code.
Architectural conventions for a production manager (slab pooling,
size-class buckets, atomic per-cell headers) are out of scope for this
specification; the goal here is the wire contract, not implementation
guidance.

### 1.3 What this ABI does NOT cover

- **Per-process manager selection.** v1 ships a single manager per binary. The future BEAM-style `Process.spawn(memory: Memory.Arena)` model is reserved for v2.
- **Cross-manager object sharing.** Forbidden in v1 (see section 13).
- **Tracing garbage collection.** Reserved (see section 9); no v1 manager may implement it.
- **Region-based memory management.** Reserved; no v1 manager may implement it.
- **Finalizers, weak references.** Reserved; no v1 manager may implement them.

---

## 2. Versioning rules

### 2.1 ABI version

The ABI is identified by an `(abi_major, abi_minor)` pair, both `u16`.

- **Major version (`abi_major`)** changes when an incompatible change to the wire format or core vtable is made. The Zap compiler refuses to load a manager whose `abi_major` differs from its own. All v1.x releases have `abi_major = 1`.
- **Minor version (`abi_minor`)** changes when a backward-compatible change is made — for example, adding a new optional field to the end of a structure (using the `size` field convention; see 2.3). The Zap compiler accepts any manager whose `abi_minor` is less than or equal to its own.

Known v1.x minors:

| `abi_minor` | Date     | Change                                                                                                    |
|-------------|----------|-----------------------------------------------------------------------------------------------------------|
| 0           | initial  | Baseline ABI: meta header + core vtable + `REFCOUNT_V1` with two slots (`retain`, `release`).             |
| 1           | Phase 4.x | Extends `ZapRefcountCapabilityV1` to six slots (adds `retain_sized`, `release_sized`, `allocate_refcounted`, `refcount_sized`) for the side-table refcount path used by generic `Arc(T)`. Purely additive — a v1.0 manager remains valid; a v1.1 consumer reading a v1.0 manager observes `desc.size = 16` for the REFC descriptor and routes generic `Arc(T)` allocations through `core.allocate` instead of `allocate_refcounted`. See section 8 for details. |

### 2.2 Capability versioning

Each capability has its own independent version (a `u16` in the capability descriptor). The core ABI and a capability evolve separately.

A manager may embed multiple descriptors for the same capability ID at different versions. A v1.x compiler iterates the descriptors, selects the highest version it understands (v1.0 understands only `version = 1` for each capability), and uses that descriptor's vtable. The selection algorithm:

1. Scan all descriptors (embedded + any obtained via `get_capability_desc`) for the requested capability ID.
2. Discard any whose `version` exceeds the compiler's maximum supported version for that capability.
3. From the remainder, select the descriptor with the highest `version`.
4. If the remainder is empty but the capability bit is set in `declared_caps`, the manager is rejected at build time.

A manager that embeds only a higher-version descriptor for a capability declared in `declared_caps` is rejected at build time by an older compiler with a clear error:

```
zap: manager declares <CAPABILITY> at version <N>; this compiler supports only versions up to <M>;
     rebuild manager with version <M> support or upgrade the compiler
```

Future versions of a capability are introduced by adding a new descriptor with the new version, while keeping the older version in the descriptor list. The manager picks which versions to support; the compiler picks the highest mutually-understood version.

### 2.3 The `size` field convention

Every extensible structure (`ZapMemoryManagerMetaV1`, `ZapMemoryManagerCoreV1`, `ZapCapabilityDescV1`, and every capability vtable) carries an explicit `size` field. The size field gives the size in bytes of the struct as the manager understood it at compile time.

- A consumer that sees `size > sizeof(its known struct definition)` reads only the prefix it knows and ignores trailing bytes. This permits a manager built against `abi_minor = 1` (which adds new trailing fields) to be loaded by a compiler that only knows `abi_minor = 0`.
- A consumer that sees `size < sizeof(its known struct definition)` zero-fills the missing trailing bytes. The fields added in `abi_minor = 1` and later are *required* to have a sensible zero-meaning (typically "feature absent" or "default behavior").
- A consumer that sees `size = 0` rejects the structure as invalid.

This is the same forward-compatibility discipline used by Vulkan's `sType`/`pNext` chains and the Linux kernel's versioned ioctl structures.

---

## 3. The `.zapmem` metadata section

Every memory manager package emits a single contiguous metadata blob into a dedicated, named object-file section. The blob contains:

1. A `ZapMemoryManagerMetaV1` header (32 bytes in v1.0).
2. A `ZapMemoryManagerCoreV1` core vtable (56 bytes in v1.0 on a 64-bit target).
3. Zero or more `ZapCapabilityDescV1` embedded descriptors (24 bytes each).

The Zap compiler parses this section at build time using the Zig standard library's object-format readers (`std.elf`, `std.macho`, `std.coff`). The compiler discovers every required artifact by **section content**: the only symbol the manager must export at the linker level is the section itself. Symbol names within the section are advisory.

No subprocess (`nm`, `objdump`) is required and no symbol-name encoding tricks are used.

### 3.1 Section name by object format

| Object format | Section name      | Notes                                                          |
|---------------|-------------------|----------------------------------------------------------------|
| ELF           | `.zapmem`         | `SHT_PROGBITS`, `SHF_ALLOC` (loaded into the image's address space at runtime — required so the section survives static linking). |
| Mach-O        | `__DATA,__zapmem` | Segment `__DATA`, section `__zapmem`. Section type `S_REGULAR`. |
| COFF (PE)     | `.zapmem`         | Characteristics: `IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ`. |

The compiler determines the target object format from the manager's compiled object file (`std.elf.Header`, `std.macho.Header`, or `std.coff.Header`). The same Zig source produces the correct section name for every platform via Zig's `linksection` attribute combined with target-conditional naming. The worked examples in sections 14 and 15 show the canonical pattern.

### 3.2 Emission

The manager package places the meta header, the core vtable, and any embedded descriptors into the `.zapmem` section using Zig's `linksection` attribute. The three artifacts are placed in fixed order:

```
.zapmem layout:
    [ ZapMemoryManagerMetaV1                  ] @ section offset 0
    [ ZapMemoryManagerCoreV1                  ] @ section offset = meta.core_vtable_offset
    [ ZapCapabilityDescV1 * meta.desc_count   ] @ section offset = meta.core_vtable_offset + core.size
```

The header's `core_vtable_offset` field gives the byte offset (from the start of the section) at which the core vtable lives. In the canonical v1.0 layout `meta.core_vtable_offset == @sizeOf(ZapMemoryManagerMetaV1) == 32`. Embedded descriptors, if any, follow the core vtable.

**Recommended emission pattern: single composite extern struct.** The manager wraps the meta header, the core vtable, and any embedded descriptors into a single composite `extern struct` and emits that struct via one `export const ... linksection(...)` declaration. Wrapping into a single declaration is the only portable way to guarantee that the linker preserves the relative order of the three artifacts within the `.zapmem` section; emitting them as multiple separate declarations with the same `linksection` attribute leaves the relative ordering unspecified and may produce a section layout that does not match `meta.core_vtable_offset`. The composite-struct pattern looks like:

```zig
const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
    // ...optional embedded descriptors follow here, one field per entry.
};

pub export const zap_memory_section linksection(SECTION_NAME) = ZapMemorySection{
    .meta = .{
        // ...meta fields, including
        // .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
    },
    .core = .{
        // ...core fields.
    },
};
```

The composite struct's `@offsetOf(ZapMemorySection, "core")` provides the value for `meta.core_vtable_offset`, and `@offsetOf(...)` on any embedded descriptor field provides its section offset. Because Zig lays out an `extern struct` in declaration order and emits it as a single contiguous initializer, the resulting `.zapmem` section is guaranteed to match the layout in the table above.

**Composite struct with an embedded descriptor.** When the manager declares one or more capabilities and chooses to embed their descriptors rather than rely on runtime-only discovery (section 5.4), each embedded descriptor becomes an additional field in the same composite `extern struct`. For a refcounting-only manager that embeds a single `REFC` descriptor:

```zig
const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,    // 32 bytes, offset 0
    core: ZapMemoryManagerCoreV1,    // 56 bytes, offset 32
    desc_0: ZapCapabilityDescV1,     // 24 bytes, offset 88
};

pub export const zap_memory_section linksection(SECTION_NAME) = ZapMemorySection{
    .meta = .{
        // ...meta fields, including
        // .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),  // 32
        // .desc_count         = 1,
        // .declared_caps      = CAP_REFCOUNT_V1_BIT,
    },
    .core = .{
        // ...core fields, including
        // .declared_caps      = CAP_REFCOUNT_V1_BIT,
    },
    .desc_0 = .{
        .id      = REFC_TAG,
        .version = 1,
        .size    = @sizeOf(ZapRefcountCapabilityV1),
        .flags   = 0,
        .vtable  = &refcount_vtable,
    },
};
```

The resulting `.zapmem` byte layout is:

```
meta@0 (32 bytes) | core@32 (56 bytes) | desc_0@88 (24 bytes) | total 112 bytes
```

`@offsetOf(ZapMemorySection, "desc_0")` is 88 in the canonical v1.0 layout — exactly `meta.core_vtable_offset + core.size` (32 + 56). Multiple embedded descriptors append in declaration order: `desc_0` at offset 88, `desc_1` at offset 112, `desc_2` at offset 136, and so on. The compiler reads them starting at `meta.core_vtable_offset + core.size` and walks `meta.desc_count` entries.

The composite-struct symbol must have external linkage (the `export` keyword in Zig) so that the linker does not dead-strip it. The recommended symbol name is `zap_memory_section`, but the compiler does NOT rely on this name — it discovers all data purely by walking the section's contents starting at offset 0. Managers may also use multiple-declaration emission (one `export const` per artifact, each with the same `linksection`) provided they verify the produced section layout for every supported target; the resulting layout is implementation-defined and not portable across linkers.

A manager package emits exactly one `ZapMemoryManagerMetaV1` and exactly one `ZapMemoryManagerCoreV1` into the `.zapmem` section. Emitting zero or more than one of either is a manager defect; the compiler rejects such managers with a build-time error.

### 3.3 Discovery

The Zap compiler, after compiling the manager's Zig source to an object file, performs the following discovery steps:

1. Open the object file. Detect the object format from its magic bytes (`\x7fELF` for ELF, `0xFEEDFACE`/`0xFEEDFACF`/`0xCAFEBABE` for Mach-O, `MZ` for PE/COFF).
2. Locate the named section as listed in 3.1. Absence of the section is a build-time error.
3. Verify the section is at least `sizeof(ZapMemoryManagerMetaV1)` (32 bytes for v1.0; see appendix B). Smaller is a build-time error.
4. Read the first `sizeof(ZapMemoryManagerMetaV1)` bytes from the section as a `ZapMemoryManagerMetaV1` value (target endianness — the section is compiled for the same target as the final binary).
5. Validate the meta header per 3.5.
6. Read `sizeof(ZapMemoryManagerCoreV1)` bytes starting at `meta.core_vtable_offset` (relative to the start of the section) as a `ZapMemoryManagerCoreV1` value.
7. Validate the core vtable per 3.5.
8. If `meta.desc_count > 0`, read `desc_count` consecutive `ZapCapabilityDescV1` entries starting at `meta.core_vtable_offset + core.size`.
9. Validate each descriptor per 3.5.

### 3.4 Endianness

All multi-byte integers in the `.zapmem` section and all ABI structures are stored in the **target's native byte order**. The manager and the Zap-generated code are always compiled for the same target; there is no cross-target loading. Big-endian targets store the `magic` value as `0x5A4D454D`; little-endian targets store it as `0x4D454D5A`. The Zap compiler determines target endianness from the object file and reads accordingly.

### 3.5 Validation rules

The Zap compiler rejects the manager with a clear build-time error if any of the following is true:

- `meta.magic` does not equal the target-endianness-correct form of `'ZMEM'`.
- `meta.abi_major` does not equal the compiler's known ABI major (`1` for this spec).
- `meta.abi_minor > compiler.known_abi_minor` AND `meta.size < sizeof(compiler.known_meta)`: rejected with `zap: manager claims abi_minor <N> but provides metadata smaller than this compiler's known prefix; rebuild manager with a newer ABI minor or upgrade the compiler`. If `meta.size >= sizeof(compiler.known_meta)`, the compiler reads its known prefix and silently ignores any trailing bytes regardless of `abi_minor`. This is the size-field forward-extension contract (section 2.3).
- `meta.size < 32` (the v1.0 base size for the meta header; the compiler refuses partial structures).
- `meta.core_vtable_offset < meta.size` (the core vtable must follow the header without overlapping it).
- `meta.core_vtable_offset + sizeof(ZapMemoryManagerCoreV1)` exceeds the section size.
- `core.abi_major != meta.abi_major` or `core.abi_minor != meta.abi_minor` (header and core vtable must agree on version).
- `core.declared_caps != meta.declared_caps` (header and core vtable must agree on the capability bitmask).
- `core.size < 56` (the v1.0 base size for the core vtable on a 64-bit target).
- `meta.desc_count > 0` and the section is smaller than `meta.core_vtable_offset + core.size + meta.desc_count * sizeof(ZapCapabilityDescV1)`.
- A bit set in `meta.declared_caps` corresponds to a reserved-but-unimplemented capability (e.g., `GCOL` in v1.0). Reserved bits are reserved precisely because no v1 manager may declare them.
- `meta.desc_count > 0` and any embedded descriptor's `id` does not correspond to a bit set in `meta.declared_caps`. Embedding a descriptor for an undeclared capability is rejected: `zap: manager embeds descriptor for capability <TAG> but does not declare it in declared_caps`.
- `meta.desc_count > 0` and any embedded descriptor's `id == 0`: rejected with `zap: manager embeds descriptor with id == 0; descriptor ID 0 is reserved`. ID 0 is reserved (see section 5.5: `get_capability_desc` must return null for `id == 0`); embedding a descriptor under that ID is a manager defect.
- `meta.reserved` is non-zero.
- `meta._reserved2` is non-zero: rejected with `zap: manager metadata has non-zero reserved field _reserved2; the manager was built against a future ABI version`. The two reserved fields (`reserved`, `_reserved2`) are validated symmetrically — any non-zero value indicates a future-ABI bit the current compiler does not understand.

A v1.x compiler may encounter bits set in `meta.declared_caps` that are unknown to it (added in a later v1.y minor). Such unknown bits are silently ignored — they have no effect on HIR or codegen. The manager must still implement the corresponding capability for the bits to be useful; bits the compiler does not recognize simply produce no compiler-side hooks. This is forward-compatible only for additive capabilities. A capability requiring new compiler-side codegen (write barriers, region setup) cannot be exercised by an older compiler; managers must omit the bit when targeting compilers that do not support the capability.

### 3.6 The metadata structure

```zig
/// The .zapmem section header. Exactly one of these per manager package,
/// placed at section offset 0. All fields in target native byte order.
pub const ZapMemoryManagerMetaV1 = extern struct {
    /// FourCC 'ZMEM' (Z=0x5A, M=0x4D, E=0x45, M=0x4D).
    /// Little-endian targets see 0x4D454D5A.
    /// Big-endian targets see 0x5A4D454D.
    magic: u32,

    /// ABI major version. 1 for this spec.
    abi_major: u16,

    /// ABI minor version. 0 for this spec.
    abi_minor: u16,

    /// Size in bytes of this struct as the manager understood it at
    /// build time. Permits non-breaking forward extension. For v1.0
    /// this is exactly 32; for v1.x with x > 0 it may be larger.
    size: u16,

    /// Reserved. Must be 0 in v1.x. (Was `object_fmt` in pre-release
    /// drafts; the section format is implicit in the object format,
    /// so this field is unused.)
    _reserved2: u16,

    /// Number of ZapCapabilityDescV1 entries embedded in the section
    /// after the core vtable. If 0, descriptors are discovered
    /// exclusively at runtime via core.get_capability_desc. Embedding
    /// is recommended (see section 5.4).
    desc_count: u32,

    /// Bitmask of capability IDs this manager implements. See section 7
    /// for the canonical tag -> bit position mapping.
    declared_caps: u64,

    /// Byte offset (from the start of the .zapmem section) at which
    /// the ZapMemoryManagerCoreV1 struct lives. The compiler reads
    /// the core vtable from this offset; it does not rely on any
    /// symbol name.
    ///
    /// In a canonical v1.0 layout this is exactly `@sizeOf(meta)` = 32.
    /// The field is explicit (rather than implicit) so that future
    /// minor versions may extend the meta header without breaking the
    /// core vtable lookup.
    core_vtable_offset: u32,

    /// Reserved. Must be 0 in v1.x.
    reserved: u32,
};

comptime {
    // Lock in the v1.0 base size.
    if (@sizeOf(ZapMemoryManagerMetaV1) != 32) @compileError(
        "ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
}
```

The core vtable (section 4) immediately follows the meta header in the canonical v1.0 layout. Embedded descriptors, if present, follow the core vtable.

---

## 4. The core vtable: `ZapMemoryManagerCoreV1`

The core vtable is the always-present, mandatory interface for every manager. It lives inside the `.zapmem` section at the byte offset given by `meta.core_vtable_offset` (typically immediately after the meta header). The runtime locates it purely by section content; the recommended exported symbol name `zap_memory_manager_core` is advisory and not part of the discovery contract.

### 4.1 Init options

```zig
/// Initialization options passed to the manager's init function.
/// Reserved for forward extension. v1.0 carries no fields; the manager
/// receives a null pointer if no options are needed. The pointer is
/// valid only for the duration of the init call.
pub const ZapInitOptions = extern struct {
    /// Size of this struct as the caller built it. v1.0 base size is 8.
    size: u32,

    /// Reserved. Must be 0 in v1.x.
    reserved: u32,
};
```

**Cross-version `ZapInitOptions` discipline.** If the compiler/runtime is newer than the manager, the runtime may pass options with `size > sizeof(v1.0-options)`. The manager uses `options.size` to detect and ignore trailing fields. If the manager is newer than the compiler, the runtime passes `null` (or a smaller-than-current-manager options); the manager checks `options == null || options.size < sizeof(<known options>)` and proceeds with defaults.

### 4.2 The vtable

```zig
/// The mandatory core vtable. Every manager emits exactly one of these
/// into the .zapmem section at offset meta.core_vtable_offset.
pub const ZapMemoryManagerCoreV1 = extern struct {
    /// ABI major version this vtable conforms to. Must equal the value
    /// in the .zapmem metadata.
    abi_major: u16,

    /// ABI minor version this vtable conforms to. Must equal the value
    /// in the .zapmem metadata.
    abi_minor: u16,

    /// Size in bytes of this struct as the manager understood it at
    /// build time. For v1.0 this is the value of @sizeOf(ZapMemoryManagerCoreV1)
    /// computed against this exact definition (56 on a 64-bit target).
    size: u32,

    /// Bitmask of capability IDs. Must equal the value in the .zapmem
    /// metadata; the compiler enforces equality at build time.
    declared_caps: u64,

    /// Initialize the manager. Called exactly once, before any other
    /// vtable function on the manager is called and before user-code
    /// main runs.
    ///
    /// Returns an opaque context pointer that is threaded through all
    /// subsequent calls. Returning null indicates initialization
    /// failure; the runtime aborts with the diagnostic
    /// `zap: manager <name> failed to initialize` before user code runs.
    ///
    /// Managers with no per-process state must still return a non-null
    /// pointer; the conventional pattern is to return the address of
    /// an empty static struct. The runtime treats any non-null value
    /// as success and any null value as init failure.
    ///
    /// The manager MAY call its own `allocate` directly with its own
    /// context pointer during `init` to build internal data structures
    /// (free lists, slab pools, bookkeeping tables, etc.). Allocations
    /// made during init will be matched by `deallocate` calls made
    /// during deinit (or freed wholesale by the manager during deinit,
    /// at its discretion).
    ///
    /// The manager MUST NOT trigger compiler-emitted allocation paths
    /// during `init` — that is, the manager MUST NOT call into Zap
    /// user code or Zap stdlib that allocates (Map, List, String
    /// constructors, refcounted cell allocators, anything that lowers
    /// through the compiler-emitted allocation site), because the
    /// global `zap_memory_manager_context` (section 10.2) is not yet
    /// populated when `init` is running. Compiler-emitted alloc sites
    /// reached before startup completes will panic via the
    /// deterministic unwrap trap described in section 10.2.
    ///
    /// Thread-safety: called on the thread that invokes the Zap
    /// runtime startup. The runtime guarantees that during init, no
    /// other thread will call any function on this manager. Managers
    /// may assume single-threaded access to themselves during this
    /// phase.
    init: *const fn (options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque,

    /// Deinitialize the manager. See section 4.4 for the full
    /// lifecycle and termination-path specification.
    ///
    /// During `deinit`, the manager:
    ///   - MAY use any allocator NOT routed through its own
    ///     `core.allocate` (e.g., `std.heap.page_allocator` for scratch).
    ///   - MUST NOT call its own `core.allocate`, `core.retain`,
    ///     `core.release`, or `core.deallocate`. After `deinit` begins,
    ///     the runtime no longer routes user-level allocations through
    ///     this manager.
    ///   - MUST NOT return failure. If internal cleanup fails (e.g.,
    ///     scratch allocation fails for a diagnostic report), the
    ///     manager logs to stderr and returns normally.
    ///   - MAY take arbitrary time to complete. The runtime does not
    ///     enforce a timeout.
    ///
    /// Thread-safety: called on the same thread that called init. The
    /// runtime guarantees that during deinit, no other thread will
    /// call any function on this manager.
    deinit: *const fn (ctx: *anyopaque) callconv(.c) void,

    /// Allocate `size` bytes with at least `alignment` byte alignment.
    /// `alignment` is always a power of two and at least
    /// `@alignOf(usize)`. On success returns a non-null pointer to at
    /// least `size` writable bytes. On failure returns null; see
    /// section 4.3.1 for the out-of-memory protocol.
    ///
    /// The manager may return memory whose first usable address is
    /// already over-aligned; it must not return memory whose alignment
    /// is less than requested.
    ///
    /// There is no spec-imposed maximum allocation size. A manager
    /// that cannot fulfill a request of any size returns null.
    ///
    /// `allocate` may be called from `init` (for the manager's own
    /// internal setup) and is otherwise called only during program
    /// execution. `allocate` is never called during or after `deinit`.
    ///
    /// Thread-safety: may be called concurrently from any thread. The
    /// manager is responsible for any required synchronization.
    allocate: *const fn (
        ctx: *anyopaque,
        size: usize,
        alignment: u32,
    ) callconv(.c) ?[*]u8,

    /// Deallocate a previously allocated block. See section 4.5 for
    /// the allocation lifecycle pairing rules — in particular, this
    /// function is NEVER called for refcounted cells, only for raw
    /// allocations.
    ///
    /// The runtime guarantees:
    ///   - `ptr` is bit-identical to the value `allocate` returned
    ///     for this allocation.
    ///   - `size` equals the value passed to `allocate`. The compiler
    ///     tracks size alongside the allocation; managers that need
    ///     it may rely on it.
    ///   - `alignment` equals the value passed to `allocate`.
    ///   - `deallocate` is never called more than once per allocation.
    ///   - `deallocate` is never called with a pointer that was
    ///     returned to a `release`-and-free cycle.
    ///
    /// Manager-internal data layout (whether to prepend a header to
    /// the returned pointer, whether to bucket allocations by size)
    /// is at the manager's discretion. If the manager prepends a
    /// header, it owns the offset arithmetic in `allocate` and
    /// `deallocate`.
    ///
    /// A manager that performs no individual deallocation (e.g., a
    /// pure arena) provides a no-op implementation; the runtime still
    /// calls it for every raw block to permit accounting in
    /// diagnostic wrappers.
    ///
    /// Thread-safety: may be called concurrently from any thread.
    deallocate: *const fn (
        ctx: *anyopaque,
        ptr: [*]u8,
        size: usize,
        alignment: u32,
    ) callconv(.c) void,

    /// Look up the descriptor for a specific capability. The compiler
    /// queries capabilities only by canonical IDs from Appendix A.
    /// Managers must respond:
    ///
    ///   - For an ID in `declared_caps`: return a valid descriptor.
    ///   - For an ID NOT in `declared_caps`: return `null`.
    ///   - For `id = 0` or any non-canonical ID: return `null`.
    ///
    /// The v1.x FourCC namespace is closed to the canonical table in
    /// Appendix A. Vendor-private extensions must use a future
    /// capability ID assigned in a later ABI version. In v1.x,
    /// managers must not invent new tag IDs.
    ///
    /// The returned pointer is valid for the lifetime of the manager
    /// context and is read-only. The runtime may call this at any
    /// time after init returns and before deinit is called. Result
    /// pointers are stable and may be cached.
    ///
    /// Thread-safety: may be called concurrently from any thread. The
    /// returned descriptor and its vtable must be safe for concurrent
    /// read access.
    get_capability_desc: *const fn (
        ctx: *anyopaque,
        id: u32,
    ) callconv(.c) ?*const ZapCapabilityDescV1,
};

comptime {
    // Lock in the v1.0 base size. Adjust the constant when extending.
    // Layout on a 64-bit target with 8-byte pointer alignment:
    //   abi_major:u16 + abi_minor:u16 + size:u32 + declared_caps:u64
    //   + 5 function pointers * 8 = 56 bytes total.
    if (@sizeOf(ZapMemoryManagerCoreV1) != 56) @compileError(
        "ZapMemoryManagerCoreV1 v1.0 must be exactly 56 bytes on a " ++
        "64-bit target with 8-byte function-pointer alignment",
    );
}
```

### 4.3 Build-time vs. runtime split

`init`, `deinit`, `allocate`, `deallocate`, `retain`, `release`, and `get_capability_desc` are runtime functions. The Zap compiler reads only the `.zapmem` metadata section at build time (the meta header, the embedded `ZapMemoryManagerCoreV1` struct, and any embedded `ZapCapabilityDescV1` entries). The compiler invokes no function pointers at build time; it only reads static data. A manager wishing to influence build-time behavior must do so via fields in the static `ZapMemoryManagerMetaV1` and `ZapMemoryManagerCoreV1` constants.

#### 4.3.1 Out-of-memory protocol

When a manager cannot satisfy an `allocate` request:

1. Return `null`. Do not print, do not abort, do not exit.
2. The runtime detects the null return and aborts with a diagnostic of the form:
   ```
   zap: out of memory: requested <size> bytes (alignment <alignment>) from manager <manager_name>; aborting
   ```
   The `<manager_name>` is read from the manager's stdlib struct path (e.g., `Memory.ARC`).
3. Managers must not call `std.process.abort`, `std.process.exit`, or perform IO during the allocation path. The runtime owns the OOM diagnostic.
4. Behavior on allocation success but partial fill (e.g., backing-store partial failure) is undefined; managers must either fully succeed or return null.

v1 managers may not retry, swap heaps, or otherwise recover from OOM. Future ABI minor versions may add a `try_allocate` variant; v1.0 has only the abort-on-failure path.

A null return from `init` is fatal: the runtime aborts before user code runs with the diagnostic `zap: manager <name> failed to initialize`.

### 4.4 Deinit lifecycle and termination paths

`deinit` runs on the following termination paths:

1. **Normal main return.** `deinit` is called on the main thread after user code returns and after the runtime has joined all user-spawned threads.
2. **`std.process.exit(N)` / `@panic` / unhandled error / `abort()`.** `deinit` is NOT called. The OS reclaims memory; the manager is not given a chance to clean up.
3. **External signal (SIGTERM / SIGKILL / SIGINT default).** `deinit` is NOT called.

Managers must not rely on `deinit` running. Critical cleanup (file syncs, network flushes) must be performed by user code before `main` returns. `deinit` is an optimization for clean diagnostic reporting and resource teardown, not a guaranteed hook.

After `deinit` returns, the runtime does not call any function on this manager again, on any path.

### 4.5 Allocation lifecycle pairing

Every successful `allocate` call has exactly one matching call later. The matching call depends on whether the cell is *refcounted* or *raw*.

**Raw allocations** — cells whose type has no inline refcount header, transient scratch buffers, runtime-internal scratch. These are matched by `core.deallocate(ctx, ptr, size, alignment)`. The runtime tracks size and alignment alongside the allocation; managers that do not need them may ignore them.

**Refcounted allocations** — cells whose type carries an inline refcount header under a manager that declares `REFCOUNT_V1`. These are matched by `refcount.release` reaching count zero. The manager's `release` implementation is responsible for the entire freeing path: invoking `deep_walk` (if non-null) and then returning the cell's storage to its underlying allocator. The runtime will NEVER call `core.deallocate` on a refcounted cell. A manager wishing to route refcounted cell frees through its own `core.deallocate` may do so internally as a private implementation detail; this is an implementation choice with no spec implications.

The Zap compiler decides per-type at HIR elaboration whether each allocation is refcounted (i.e., whether the type carries an `ArcHeader` field). The choice depends on whether the active manager declares `REFCOUNT_V1`. Under a manager that declares no `REFCOUNT_V1`, all allocations are raw and matched by `core.deallocate`.

A manager that declares `REFCOUNT_V1` will see two distinct allocation populations at runtime: refcounted cells (matched by `release`) and raw allocations (matched by `deallocate`). The manager must support both. A manager may distinguish between them by its own bookkeeping (e.g., size class, presence of a per-cell header it owns); the runtime does not tag pointers.

### 4.6 Lifecycle summary

1. **Process start.** The Zap runtime invokes `core.init(null)` (or with init options for runtime-configurable managers; v1.0 always passes null). The runtime captures the returned context pointer and stores it in the global `zap_memory_manager_context` (see section 10.2).
2. **User code runs.** All raw allocations and deallocations from compiler-generated code, stdlib, and user code flow through `core.allocate` / `core.deallocate`. Refcounted cells flow through `core.allocate` for creation and `REFCOUNT_V1.retain` / `REFCOUNT_V1.release` for lifecycle, with `release` owning the free path when the count reaches zero.
3. **User code exits cleanly.** The runtime invokes `core.deinit(ctx)`. The manager releases all owned resources. After `deinit` returns, the runtime does not call any function on this manager again.
4. **Process aborts.** `deinit` does not run. See 4.4.

### 4.7 Thread safety

All managers shipped with v1.0 must be thread-safe — that is, `allocate`, `deallocate`, `get_capability_desc`, and capability vtable functions may be called concurrently from any thread.

`init` is called on the thread that invokes the Zap runtime startup. `deinit` is called on the same thread at shutdown. The runtime guarantees that during init and deinit, no other thread will call any function on this manager. Managers may assume single-threaded access to themselves during these phases.

Zig 0.16's `std.heap.ArenaAllocator` is not lock-free, so `Memory.Arena` wraps it with a mutex when called from the multi-threaded allocator path; managers built on lock-free pools may avoid the extra synchronization.

---

## 5. Capability descriptors: `ZapCapabilityDescV1`

A capability is an optional bundle of functionality, identified by a 4-byte FourCC tag (`u32`) and a per-capability version (`u16`). The descriptor structure carries metadata about the capability plus a typed-but-erased pointer to the capability's vtable.

```zig
/// The discovery and dispatch handle for a single capability.
/// One ZapCapabilityDescV1 per implemented capability.
pub const ZapCapabilityDescV1 = extern struct {
    /// FourCC capability tag (e.g., 'REFC' for refcount).
    /// See section 7 for the canonical tag list.
    id: u32,

    /// Per-capability struct version. The vtable that `vtable` points
    /// at is typed by the (id, version) pair: REFCOUNT_V1 always points
    /// at a ZapRefcountCapabilityV1, REFCOUNT_V2 (future) points at a
    /// ZapRefcountCapabilityV2, etc.
    version: u16,

    /// Size in bytes of the *vtable* pointed at by `vtable`, NOT the
    /// size of this descriptor. The descriptor itself is fixed at 24
    /// bytes for v1.x; growing the descriptor requires an abi_major
    /// bump.
    ///
    /// The `size` field enables forward-extension within a capability:
    /// `ZapRefcountCapabilityV2` may add fields after the v1 layout;
    /// a v1.0 compiler reads only the first `sizeof(ZapRefcountCapabilityV1)`
    /// bytes and ignores any tail.
    size: u16,

    /// Capability-specific flags. In v1.0, all flag bits are reserved.
    /// Managers SHOULD set `flags = 0` on every descriptor for forward
    /// compatibility; v1.x compilers ignore unknown flag bits regardless,
    /// so non-zero values do not cause rejection but are silently dropped.
    /// Future ABI minors may define specific bits per capability; managers
    /// built against a newer minor and run by an older compiler will see
    /// their bits silently dropped (the capability degrades to the
    /// older minor's behavior).
    ///
    /// Bits 0..3 are reserved for ABI-wide use across all capabilities;
    /// bits 4..31 are reserved for per-capability use, to be defined
    /// per-capability in future minor versions.
    flags: u32,

    /// Pointer to the capability vtable. Typed implicitly by
    /// (id, version): the compiler casts based on the descriptor's
    /// id and version. The vtable must remain valid for the lifetime
    /// of the manager context.
    vtable: *const anyopaque,
};

comptime {
    if (@sizeOf(ZapCapabilityDescV1) != 24) @compileError(
        "ZapCapabilityDescV1 v1.0 must be exactly 24 bytes",
    );
}
```

### 5.1 Discovery semantics

A capability descriptor is discoverable in two ways:

1. **Embedded in the `.zapmem` section.** Each entry consumes 24 bytes after the core vtable. Embedding is recommended: it makes capability metadata available to the compiler at build time without requiring the manager to be initialized first.
2. **Runtime via `core.get_capability_desc(ctx, id)`.** The compiler-emitted runtime calls this to obtain the descriptor for a specific capability when emitting code that uses it. Implementations should return a pointer to a static-lifetime descriptor (typically the same descriptor that was embedded in `.zapmem`).

If a capability is declared in `declared_caps` but `get_capability_desc` returns null for that id, the manager is malformed and the runtime aborts. If a capability is NOT declared in `declared_caps`, `get_capability_desc` must return null for that id.

### 5.2 Vtable typing

The `vtable: *const anyopaque` is implicitly typed by the `(id, version)` pair. Each capability section in this spec gives the exact Zig type that `vtable` points at for that capability's version. Implementations cast the pointer when calling into the vtable.

### 5.3 Descriptor stability

The descriptor pointer returned by `get_capability_desc` and the vtable pointer it carries must remain valid and stable for the lifetime of the manager context. The runtime is permitted to cache them after the first lookup.

### 5.4 Embedded vs. runtime descriptor discovery

Managers may embed capability descriptors directly in the `.zapmem` section (with `desc_count > 0`) or expose them only at runtime via `get_capability_desc` (with `desc_count = 0`). Both are valid.

**Embedded is recommended.** The compiler reads descriptors at build time and may specialize codegen for the manager's specific vtable layout (e.g., inline the offset of `release` within the refcount vtable). Embedded descriptors give the best runtime performance because retain/release sites are direct function calls to known vtable offsets.

**Runtime-only is permitted.** The compiler emits one indirect call to `get_capability_desc(REFC_TAG)` at program startup, caches the result, and retain/release sites load from the cached descriptor. The performance cost is one extra startup indirection; the runtime cost of retain/release is identical.

**Validation.** If `desc_count > 0`, every embedded descriptor's `id` must correspond to a bit set in `declared_caps`. If `declared_caps` has a bit set with no matching embedded descriptor, the compiler queries `get_capability_desc` for it at startup; the manager must respond non-null. A bit set in `declared_caps` with neither an embedded descriptor nor a non-null `get_capability_desc` response is a manager defect; the runtime aborts.

### 5.5 Unknown IDs

Managers must respond to `get_capability_desc(ctx, id)` with `null` for any ID that is not in `declared_caps`, including `id = 0`, IDs reserved-but-unimplemented in v1.0 (e.g., `GCOL`), and IDs not yet assigned in the canonical table. Managers must not invent ID values in v1.x; the FourCC namespace is closed to Appendix A.

---

## 6. Capability descriptor flags

The `flags` field of `ZapCapabilityDescV1` is partitioned into ABI-wide bits (0..3) and per-capability bits (4..31). In v1.0, every bit is reserved.

### 6.1 Reserved generic flag bits

| Bit  | Mask          | Meaning                                                          |
|------|---------------|------------------------------------------------------------------|
| 0    | `0x0000_0001` | Reserved. Must be 0 in v1.0.                                     |
| 1    | `0x0000_0002` | Reserved. Must be 0 in v1.0.                                     |
| 2    | `0x0000_0004` | Reserved. Must be 0 in v1.0.                                     |
| 3    | `0x0000_0008` | Reserved. Must be 0 in v1.0.                                     |

In v1.0, all flag bits are reserved. Managers SHOULD set `flags = 0` on every descriptor for forward compatibility; v1.x compilers ignore unknown flag bits regardless. Future ABI minors may define specific bits per capability; managers built against a newer minor and run by an older compiler will see their bits silently dropped. Bits 0..3 are reserved for ABI-wide use across all capabilities; bits 4..31 are reserved for per-capability use, to be defined per-capability in future minor versions.

---

## 7. Capability IDs and bit positions

Each capability is identified by a 4-byte ASCII FourCC tag stored as a `u32`. The `declared_caps` bitmask in `ZapMemoryManagerMetaV1` and `ZapMemoryManagerCoreV1` carries one bit per implemented capability. The mapping from FourCC tag to bit position is hand-curated and fixed for the lifetime of ABI v1.x.

### 7.1 Canonical table

This table is normative. Implementations must use exactly these bit positions; future minor versions may add new entries at unused positions but must never reassign existing ones.

| Bit | Mask                | FourCC | Tag value (LE u32) | Identifier (Zig const) | Status         | Capability                              |
|-----|---------------------|--------|--------------------|------------------------|----------------|-----------------------------------------|
| 0   | `0x0000_0000_0000_0001` | `REFC` | `0x4346_4552`      | `CAP_REFCOUNT_V1`      | **DEFINED v1.0** | Atomic refcount + deep walk             |
| 1   | `0x0000_0000_0000_0002` | `GCOL` | `0x4C4F_4347`      | `CAP_TRACING_GC_V1`    | RESERVED       | Tracing garbage collection              |
| 2   | `0x0000_0000_0000_0004` | `REGN` | `0x4E47_4552`      | `CAP_REGION_V1`        | RESERVED       | Region-based memory                     |
| 3   | `0x0000_0000_0000_0008` | `STAT` | `0x5441_5453`      | `CAP_STATS_V1`         | RESERVED       | Manager-side allocation statistics      |
| 4   | `0x0000_0000_0000_0010` | `FNLZ` | `0x5A4C_4E46`      | `CAP_FINALIZER_V1`     | RESERVED       | Object finalization                     |
| 5   | `0x0000_0000_0000_0020` | `WKRF` | `0x4652_4B57`      | `CAP_WEAK_REF_V1`      | RESERVED       | Weak references                         |
| 6   | `0x0000_0000_0000_0040` | `ARSR` | `0x5253_5241`      | `CAP_ARENA_RESET_V1`   | RESERVED       | Scoped/resettable arena lifetime        |
| 7   | `0x0000_0000_0000_0080` | `ARTS` | `0x5354_5241`      | `CAP_ARENA_THREAD_SAFE_V1` | RESERVED   | Thread-safe arena variant flag          |
| 8   | `0x0000_0000_0000_0100` | `SHHP` | `0x5048_4853`      | `CAP_SHARED_HEAP_V1`   | RESERVED       | Cross-process shared heap (BEAM-style)  |
| 9   | `0x0000_0000_0000_0200` | `TRAC` | `0x4341_5254`      | `CAP_TRACING_V1`       | RESERVED       | Write-barrier infrastructure for GC     |
| 10..63 | (unused)         | —      | —                  | —                      | UNUSED         | Reserved for future minor versions      |

The "Tag value (LE u32)" column shows the FourCC interpreted as a little-endian `u32` (i.e., the byte sequence `REFC` is `0x52, 0x45, 0x46, 0x43`, which read as little-endian is `0x4346_4552`). On big-endian targets the same bytes read as `0x5245_4643`.

**Always use the named tag constants in Appendix A.1 (`REFC_TAG`, `GCOL_TAG`, etc.) rather than hand-computed hex literals.** The named constants resolve at comptime via `std.mem.readInt(u32, "REFC", target_endianness)` and are correct on every target; hand-computed hex values silently fail on big-endian targets because they bake in the little-endian interpretation. The hex columns in the canonical table exist only for documentation and ABI-validator implementations that need to recognize the wire format directly; manager source code should never write the hex literal.

### 7.2 Reserved-vs-defined

A "DEFINED" capability has a normative struct shape in this spec. A v1.0 manager may implement it freely.

A "RESERVED" capability has a reserved tag and bit position but no committed struct shape. A v1.0 manager **must not** set its bit in `declared_caps`. The compiler rejects managers that declare reserved bits.

### 7.3 Why a hand-curated table

A hash-mod-64 scheme would risk collisions as the namespace grows; sequential hand-curated assignment guarantees stability and makes the relationship between tag and bit position trivially inspectable. The table is small enough that hand-curation is not a maintenance burden.

---

## 8. `ZapRefcountCapabilityV1`

This is the only fully-defined capability in v1.x. A manager that supports atomic reference counting declares the `REFC` bit and exposes a `ZapRefcountCapabilityV1` vtable.

The vtable evolved across two ABI minors:

- **v1.0** (`abi_minor = 0`) defines two function-pointer slots — `retain` and `release` — totalling 16 bytes. These cover the inline-header refcount path: the manager reads the refcount from a known offset inside the cell pointer the runtime passes in.
- **v1.1** (`abi_minor = 1`) appends four additional slots — `retain_sized`, `release_sized`, `allocate_refcounted`, and `refcount_sized` — totalling 48 bytes. These cover the side-table refcount path used by the runtime's generic `Arc(T)` cells (the cell's pointer addresses the user payload directly with no inline refcount header; the refcount lives in a separate side-table keyed by the cell's owning slab base).

The extension is purely additive. The first 16 bytes of the vtable are bit-identical between v1.0 and v1.1. A v1.0 consumer reading only the first two slots remains compatible with a v1.1 manager (per the size-field forward-extension contract in section 2.3). A v1.1+ consumer that loads a v1.0 manager observes `desc.size = 16`, treats the four trailing slots as absent, and routes generic `Arc(T)` allocations through `core.allocate` instead of `allocate_refcounted`.

```zig
/// Compiler-emitted deep-walk callback. When the refcount of an object
/// drops to zero, the manager's release function invokes this callback
/// (if non-null) to release the object's children.
///
/// The callback receives a pointer to the object being freed. For a
/// Map, the callback walks the entries and calls release on each value.
/// For a List, the callback walks the elements and calls release on
/// each. For a String (which has no refcounted children), the compiler
/// passes null and the manager never invokes this callback.
///
/// Calling convention is callconv(.c) so the callback can be stored in
/// the cell header alongside type tags.
pub const ZapDeepWalkFn = *const fn (object: *anyopaque) callconv(.c) void;

/// The REFCOUNT_V1 capability vtable. Pointed at by ZapCapabilityDescV1
/// when descriptor.id == 'REFC' and descriptor.version == 1.
///
/// Slots 0 and 1 (`retain`, `release`) are mandatory and define ABI v1.0.
/// Slots 2 through 5 (`retain_sized`, `release_sized`, `allocate_refcounted`,
/// `refcount_sized`) are the ABI v1.1 forward-extension; managers built
/// against v1.0 omit them and advertise `desc.size = 16`.
pub const ZapRefcountCapabilityV1 = extern struct {
    /// Increment the reference count of `object`. Must be atomic
    /// (relaxed/monotonic ordering is sufficient for retain; the
    /// release fence is in `release`).
    ///
    /// `object` points at an inline-header cell: the manager reads the
    /// refcount from a fixed offset within the cell. Behavior is
    /// undefined if `object` was not produced by this manager's
    /// `allocate` (cross-manager retains are forbidden; see section
    /// 13). Side-table cells use `retain_sized` instead (v1.1+).
    ///
    /// Thread-safety: may be called concurrently from any thread on
    /// the same object.
    retain: *const fn (
        ctx: *anyopaque,
        object: *anyopaque,
    ) callconv(.c) void,

    /// Decrement the reference count of `object`. If the count drops
    /// to zero, the manager:
    ///   1. Invokes `deep_walk(object)` if non-null. The deep-walk
    ///      callback is responsible for releasing all refcounted
    ///      children of the object.
    ///   2. Frees `object`'s storage by whatever internal mechanism
    ///      the manager uses. The manager owns this entire freeing
    ///      path; the runtime will not call `core.deallocate` on the
    ///      cell after release returns. See section 4.5.
    ///
    /// `object` points at an inline-header cell — see the discussion
    /// in `retain` above. Side-table cells use `release_sized` instead
    /// (v1.1+).
    ///
    /// The `deep_walk` callback may be null when the cell type has
    /// no refcounted children (e.g., a flat String).
    ///
    /// Must use acquire-release ordering: the final decrement that
    /// brings the count to zero must synchronize with all previous
    /// retains/releases so that the deep-walk and free see a
    /// consistent view of the object.
    ///
    /// Thread-safety: may be called concurrently from any thread on
    /// the same object. Exactly one caller observes the transition
    /// to zero and is responsible for the deep-walk + free.
    release: *const fn (
        ctx: *anyopaque,
        object: *anyopaque,
        deep_walk: ?ZapDeepWalkFn,
    ) callconv(.c) void,

    // -----------------------------------------------------------------
    // ABI v1.1 extension (slots 2-5). Managers built against v1.0 omit
    // these fields entirely and advertise `desc.size = 16`. Managers
    // built against v1.1+ MUST provide all four slots and advertise
    // `desc.size >= 48`.
    // -----------------------------------------------------------------

    /// Increment the side-table refcount for `object`. The runtime
    /// passes the cell's allocation size and alignment so the manager
    /// can locate the owning slab (e.g., via pointer mask) and the
    /// per-slot side-table entry. Atomic; monotonic ordering is
    /// sufficient.
    ///
    /// Used for generic `Arc(T)` cells whose layout omits the inline
    /// refcount header (the cell's bytes are entirely user payload).
    /// Inline-header cells (Map, List, MapIter under v1.x) continue
    /// to use `retain` instead.
    retain_sized: *const fn (
        ctx: *anyopaque,
        object: *anyopaque,
        size: usize,
        alignment: u32,
    ) callconv(.c) void,

    /// Decrement the side-table refcount for `object`. On the zero-
    /// transition, the manager invokes `deep_walk(object)` (if non-null)
    /// and frees the cell's storage — same semantics as `release` for
    /// inline-header cells. Acquire-release ordering is required.
    ///
    /// `size` and `alignment` are the original allocation parameters
    /// passed to `allocate_refcounted`. The manager uses them to
    /// recover the cell's slab and side-table slot.
    release_sized: *const fn (
        ctx: *anyopaque,
        object: *anyopaque,
        size: usize,
        alignment: u32,
        deep_walk: ?ZapDeepWalkFn,
    ) callconv(.c) void,

    /// Allocate `size` bytes with at least `alignment` byte alignment
    /// and initialise the cell's side-table refcount to 1 atomically.
    /// Returns null on OOM. The returned pointer addresses the user
    /// payload directly (no inline header).
    ///
    /// Distinct from `core.allocate`: that path returns a slot with
    /// refcount 0 (used for raw, non-refcounted scratch allocations).
    /// `allocate_refcounted` is the canonical entry point for
    /// constructing a refcounted cell with the side-table layout —
    /// every Zap `Arc(T)` cell originates here.
    allocate_refcounted: *const fn (
        ctx: *anyopaque,
        size: usize,
        alignment: u32,
    ) callconv(.c) ?[*]u8,

    /// Read the side-table refcount for `object` atomically (acquire
    /// ordering). Used by the runtime's `resetAny` / Perceus reuse
    /// path: a uniquely-owned cell (rc == 1) can be reused in place
    /// rather than freed and reallocated.
    ///
    /// The result is a snapshot; subsequent retains/releases from
    /// other threads may invalidate it. Callers that depend on the
    /// value must synchronise externally.
    refcount_sized: *const fn (
        ctx: *anyopaque,
        object: *anyopaque,
        size: usize,
        alignment: u32,
    ) callconv(.c) u32,
};

comptime {
    if (@sizeOf(ZapRefcountCapabilityV1) != 48) @compileError(
        "ZapRefcountCapabilityV1 (ABI v1.1) must be exactly 48 bytes on a " ++
        "64-bit target with 8-byte function-pointer alignment",
    );
}
```

### 8.0 Vtable versioning

A manager advertises which slots it provides through the `size` field of its `ZapCapabilityDescV1`:

| `desc.size` (bytes) | ABI minor | Slots provided                                                                                  |
|---------------------|-----------|-------------------------------------------------------------------------------------------------|
| `16`                | v1.0      | `retain`, `release`                                                                             |
| `48`                | v1.1      | `retain`, `release`, `retain_sized`, `release_sized`, `allocate_refcounted`, `refcount_sized`   |
| `> 48`              | future    | All v1.1 slots plus additional trailing fields. Consumers read up to their known size and ignore the trailer per section 2.3. |
| `< 16`              | invalid   | The compiler rejects the manager at section-validation time (`ValidationFailed`).               |

A v1.1+ consumer (the current Zap runtime) inspects `desc.size` at startup. When `desc.size >= 48` the runtime takes the side-table path for generic `Arc(T)` allocations: `allocate_refcounted` → `retain_sized` → `release_sized` → `refcount_sized`. When `desc.size == 16` (a v1.0 manager) the runtime instead routes those allocations through `core.allocate` (with the v1.0 manager owning whichever inline-header layout it prefers). The first two slots — `retain` and `release` — are used identically in both modes for inline-header cells (Map, List, MapIter).

Reserved upper bound: the compiler caps the accepted `desc.size` at `8 * sizeof(ZapRefcountCapabilityV1) = 384` bytes. A larger value is treated as a corrupt manager image and rejected at validation time. This matches the same upper-bound discipline applied to `meta.size` and `core.size` (see sections 3.5 and 4).

### 8.1 Object header expectations

The compiler-emitted layout for refcounted cells (under a manager that declares `REFCOUNT_V1`) includes an inline header carrying the refcount and a type tag. The exact layout is private to the compiler/runtime and may change between Zap releases; managers must treat the pointer passed to `retain` / `release` as opaque and may not inspect the cell's contents.

When a manager does NOT declare `REFCOUNT_V1`, the compiler omits the refcount header entirely from the cell layout. Object pointers in this configuration point directly at the first user field. This is the conditional-layout mechanism that makes `Memory.Arena` cell-overhead-free.

### 8.2 Who frees the cell

**`release` is the sole authority for freeing a refcounted cell.** When the final-count transition to zero is observed inside `release`, the manager's `release` implementation must:

1. Invoke `deep_walk(object)` if non-null, so children are released first.
2. Return the cell's storage to its underlying allocator (free the page, return the slot to a slab pool, etc.).

After `release` invokes `deep_walk` and frees the cell, the runtime does NOT call `core.deallocate` on the same pointer. There is no compiler-emitted wrapper that frees refcounted cells; the manager owns the entire freeing path.

To support this, the manager must be able to recover the original allocation size and alignment from the cell pointer. The standard pattern is to store size and alignment in the cell's inline header (alongside the refcount); section 15 shows a worked example.

### 8.3 Deep-walk semantics

The compiler chooses `deep_walk` **per refcounted type** at HIR elaboration time. For types with no refcounted children (e.g., a flat String, an `i64`), the compiler emits `null` in every `release` call site. For types with refcounted children (e.g., a `Map(String, User)`), the compiler emits a pointer to its per-type generated walk function. The manager sees the choice as a runtime callback; it does not dispatch on it itself.

The compiler-emitted walk function's job is to call `release(ctx, child, child_deep_walk)` for every refcounted child of the given object. Walking is shallow per call: a Map's deep-walk releases its values (which may themselves trigger recursive deep-walks via their own per-type callbacks); the manager does not need to know about transitive ownership.

The manager is the sole authority on *when* to invoke `deep_walk`. The compiler emits `release` calls; the manager invokes `deep_walk` only at the moment of the final-count transition to zero. This means a manager that batches frees (e.g., a generational arena that frees an entire generation at once) is free to call `deep_walk` for each freed object in any order, or not at all if the manager's discipline makes the deep-walk unnecessary (an arena, for example, does not need deep-walks: the entire arena is freed in one operation and refcounting is elided at compile time).

### 8.4 Reentrancy

`deep_walk` may transitively call `release` on this manager. The manager must support arbitrary recursion depth — there is no maximum nesting — within the limits of available stack space. Managers that wish to avoid deep stacks may implement worklist-based release internally and trampoline through `deep_walk`.

### 8.5 No-op when capability absent

If a manager does not declare `REFCOUNT_V1`, the compiler statically elides every retain and release in user code (the calls simply do not appear in the emitted IR). This is the central optimization that makes non-refcounting managers cell-overhead-free; see section 10 for how the elision is wired through the build pipeline.

---

## 9. Reserved capability shapes

This section sketches the *shapes* of capabilities that have reserved tags and bit positions but no committed normative struct definition in v1.0. The intent is to prevent v1.0 third parties from accidentally redefining the same tags with conflicting semantics. The shapes shown here may evolve before each capability's first DEFINED version ships; **third parties must not implement these capabilities in v1.0**.

### 9.1 `ZapTracingGCCapabilityV1` (RESERVED — tag `GCOL`, bit 1)

Tracing garbage collection. Expected v2 shape includes per-mutator allocation context (BEAM-style per-actor heaps map onto this), write barriers for generational and concurrent collectors, and explicit collection-request hooks.

```zig
// RESERVED. NOT FOR v1.0 IMPLEMENTATION. Shape will be finalized in
// a future ABI minor or major version. This sketch exists solely to
// reserve the namespace and signal forward intent.
pub const ZapTracingGCCapabilityV1_RESERVED = extern struct {
    // Per-thread / per-process mutator binding.
    mutator_bind: *const fn (
        ctx: *anyopaque,
        thread_id: u64,
    ) callconv(.c) ?*anyopaque,

    mutator_destroy: *const fn (
        ctx: *anyopaque,
        mutator: *anyopaque,
    ) callconv(.c) void,

    mutator_alloc: *const fn (
        ctx: *anyopaque,
        mutator: *anyopaque,
        size: usize,
        alignment: u32,
        semantics: u32,    // Default=0, Immortal=1, LargeObject=2
    ) callconv(.c) ?[*]u8,

    // Write barriers. write_barrier_pre is for SATB-style collectors;
    // managers that don't need it set the pointer to null.
    write_barrier: *const fn (
        ctx: *anyopaque,
        slot: **anyopaque,
        new_value: *anyopaque,
    ) callconv(.c) void,

    write_barrier_pre: ?*const fn (
        ctx: *anyopaque,
        slot: **anyopaque,
        old_value: *anyopaque,
    ) callconv(.c) void,

    // Collection control.
    gc_request: *const fn (
        ctx: *anyopaque,
        reason: u32,       // Heuristic=0, Forced=1, Emergency=2
    ) callconv(.c) void,

    gc_safepoint: *const fn (
        ctx: *anyopaque,
    ) callconv(.c) void,

    // Object tracing and finalization.
    trace_object: *const fn (
        ctx: *anyopaque,
        object: *anyopaque,
        visitor: *const fn (slot: **anyopaque) callconv(.c) void,
    ) callconv(.c) void,

    finalize_register: *const fn (
        ctx: *anyopaque,
        object: *anyopaque,
        finalizer: *const fn (object: *anyopaque) callconv(.c) void,
    ) callconv(.c) void,
};
```

### 9.2 Other reserved capabilities

The remaining reserved capabilities (`REGN`, `STAT`, `FNLZ`, `WKRF`, `ARSR`, `ARTS`, `SHHP`, `TRAC`) have only their tag and bit position reserved. Their struct shapes will be defined in future ABI minor or major versions. A v1.0 manager must not declare any of these bits.

---

## 10. Build pipeline ordering

This section describes the exact sequence of build-time operations the Zap compiler performs to integrate a memory manager into a binary. The ordering is normative: each step depends on the artifacts produced by the previous step.

### 10.1 Steps

```
Step 1. Parse the project's build.zap and load the manifest.
        The manifest's `memory:` field names a Zap memory adapter
        (e.g., Memory.ARC or Memory.Arena).

Step 2. Resolve the adapter metadata.
        The build CTFE interpreter evaluates the selected manifest
        value through the Memory.Manager protocol:
        name/1, primitive_source_path/1, capability_mask/1, and
        refcount_v1?/1.

Step 3. Compile the manager's Zig source to an object file.
        The compiler resolves primitive_source_path/1 and invokes the
        Zig-fork primitive `zap_fork_compile_zig_to_object` (see section
        10.1.2). This object is build-time validation evidence for every
        manager; the final binary registers the selected source path as
        `zap_active_manager`.

Step 4. Resolve metadata.
        The driver parses the .zapmem section from the object file using
        std.elf or std.macho (depending on detected object format).

Step 5. Validate the metadata per section 3.5.
        Any validation failure aborts the build with a diagnostic
        identifying the manager package and the specific defect. The
        validated declared_caps must exactly match the adapter's
        capability_mask/1 result.

Step 6. Thread declared_caps into HIR type elaboration.
        The compiler's HIR pass, when elaborating Map, List, String,
        and other refcountable types, branches on whether REFCOUNT_V1
        is declared:
          - If REFCOUNT_V1 is set: the type includes a refcount-header
            field (8 bytes on 64-bit) at offset 0.
          - If REFCOUNT_V1 is unset: the type omits the refcount header
            entirely; all fields shift down by the header size.

Step 7. Thread declared_caps into codegen.
        The IR pass that emits dup/drop nodes (the Perceus-style
        ownership tracking) branches on REFCOUNT_V1:
          - If REFCOUNT_V1 is set: emit calls to
            refcount_cap.retain / refcount_cap.release at the dup/drop
            sites, with the compiler-emitted deep-walk callback for
            the relevant type.
          - If REFCOUNT_V1 is unset: emit nothing. The dup/drop nodes
            are statically elided and produce no machine code.

Step 8. Emit the runtime startup hook.
        The compiler generates a small startup stub that calls the
        manager's `init` through the runtime bootstrap path and stores
        the returned context pointer in active manager runtime state
        (see section 10.2).

Step 9. Register the selected primitive source.
        The final binary registers the adapter's resolved source path as
        `zap_active_manager`. The runtime binds
        `zap_active_manager.zap_memory_section` at startup. The
        validation object from step 3 is not linked into the final
        binary.
```

#### 10.1.1 Primitive source reference resolution

`Memory.Manager.primitive_source_path/1` returns an opaque source
reference string, not a raw filesystem path. The build driver recognizes
exactly these schemes:

- `zap:<path>`: `<path>` is resolved relative to the Zap source tree
  root. Stdlib adapters use this for the built-in primitive sources.
- `project:<path>`: `<path>` is resolved relative to the project root.
  Project-local adapters use this.
- `dep:<name>:<path>`: `<path>` is resolved relative to the registered
  source root named `dep:<name>`. Dependency adapters use this.

The path part must be non-empty, relative, and may not contain `..`.
The driver checks that the resolved file exists before invoking the Zig
fork. These rules apply identically to stdlib, project, and dependency
managers.

#### 10.1.2 `zap_fork_compile_zig_to_object`

The Zig-fork primitive used in step 3 is a public C-ABI surface available to anyone calling into the Zig fork (not memory-manager-specific). Its full signature:

```zig
pub const ZapForkTarget = extern struct {
    /// Maps to std.Target.Cpu.Arch (Zig enum). See Appendix C for the
    /// canonical tag mapping for v1.0.
    arch_tag: u16,

    /// Maps to std.Target.Os.Tag.
    os_tag: u16,

    /// Maps to std.Target.Abi.
    abi_tag: u16,

    /// Reserved. Must be 0 in v1.0.
    _reserved: u16,
};

pub const ZapForkOptimize = enum(c_int) {
    Debug = 0,
    ReleaseSafe = 1,
    ReleaseFast = 2,
    ReleaseSmall = 3,
};

pub const ZapForkResult = enum(c_int) {
    Ok = 0,
    SourceNotFound = 1,
    CompilationFailed = 2,
    TargetUnsupported = 3,
    InternalError = 99,
};

pub extern fn zap_fork_compile_zig_to_object(
    source_path: [*:0]const u8,
    target: *const ZapForkTarget,
    optimize: ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
    zig_lib_dir_opt: ?[*:0]const u8,
    local_cache_dir_opt: ?[*:0]const u8,
    global_cache_dir_opt: ?[*:0]const u8,
) callconv(.c) ZapForkResult;
```

The diagnostic buffer receives a UTF-8 error message on non-`Ok` returns; pass `null` to discard. The function writes at most `out_diagnostic_capacity` bytes (including a trailing NUL if space permits) and truncates the message otherwise. On `Ok`, the buffer is left untouched.

On `CompilationFailed`, the diagnostic buffer is populated with the formatted contents of the Zig compiler's structured `ErrorBundle` — each error appears on its own line with source-location prefix where available (`[i] path:line:column: error: text`). If the buffer fills up before all errors fit, the remaining errors are summarized with a trailing `... [truncated, N more errors]` marker. On other non-`Ok` returns the buffer carries a human-readable explanation of the failure.

#### 10.1.2.1 Optional parameters

`zig_lib_dir_opt`
    Optional path to a Zig stdlib directory. If null, the primitive uses
    its compiled-in default (typically inferred from the executable
    location). Pass a non-null pointer when calling from a binary that
    unpacks its stdlib at runtime (e.g., Zap's build orchestrator) so
    the primitive can locate built-in modules like `@import("std")`.

`local_cache_dir_opt`
    Optional path to a local Zig build cache directory. If null, the
    primitive uses a platform-appropriate default:
    `/tmp/zap-fork-cache` on Linux and macOS, and
    `%TEMP%\zap-fork-cache` (or `%TMP%\zap-fork-cache` as a fallback)
    on Windows. On hosts without a documented default, the primitive
    returns `InternalError` with a diagnostic naming the OS; exotic-host
    callers must thread an explicit path through this argument. Callers
    driving many compilations (e.g., Zap's build orchestrator) should
    pass an explicit per-build cache directory through this argument so
    that repeated invocations share a stable cache root and do not
    collide with other tools' caches under the system temp directory.

`global_cache_dir_opt`
    Optional path to a global (cross-build) Zig cache directory. If
    null, the primitive uses the same default as `local_cache_dir_opt`.
    Pass an explicit path when the orchestrator wants global cache
    artifacts (e.g., libcxx, compiler_rt) to live alongside the rest
    of its tooling cache.

All three pointers are `?[*:0]const u8` and follow C-string conventions:
NUL-terminated UTF-8 paths or `null` to request the default. The
primitive never takes ownership of the buffers; the caller may free
them as soon as the call returns.

The primitive does not currently accept package dependencies (`build.zig.zon` deps arrays); see section 11.1.1 for the implication.

### 10.2 Runtime manager context storage

The Zap runtime exports a single global storage for the active manager's context. The symbol is split across two translation-unit roles: the Zap runtime is the sole *defining* TU and every compiler-emitted retain/release/allocate/deallocate site is a *consuming* TU. Zig 0.16 rejects an `extern var` with an initializer (`error: extern variables have no initializers`), so the two roles use distinct declarations against the same symbol name:

```zig
// In the Zap runtime (defining translation unit):
// The runtime defines and zero-initializes this global. It is written
// exactly once, immediately after `core.init` returns at program startup,
// before any compiler-emitted user code runs.
pub export var zap_memory_manager_context: ?*anyopaque = null;

// In compiler-emitted user code (consuming translation units):
// Compiler-emitted retain/release/allocate/deallocate sites declare and
// unwrap the runtime's global. Reaching a call site before startup
// completes traps deterministically.
pub extern var zap_memory_manager_context: ?*anyopaque;
```

The defining declaration places the symbol in the runtime's `.bss`/`.data` with an explicit `null` initializer; the consuming declarations carry no initializer (Zig forbids it on `extern`) and resolve at link time to the runtime's symbol. Both declarations name the same global, so every consumer observes the runtime's zero-initialized slot until startup writes through it.

The startup hook emitted in step 8 invokes the manager's `init`, validates that the returned context pointer is non-null (treating null as initialization failure per section 4.2), and writes the validated pointer into `zap_memory_manager_context` before transferring control to user-level main.

Every compiler-emitted retain/release/allocate/deallocate site unwraps the nullable using the canonical Zig idiom — for example, `const ctx = zap_memory_manager_context orelse @panic("zap: memory manager not initialized; allocation issued before startup completed")`. The unwrap compiles to a single not-null branch on every target; the cold panic path emits a deterministic abort with a clear diagnostic.

Reaching an allocation site before startup completes is a structural bug in the runtime (it indicates that user-visible allocation was triggered before `init` ran) rather than a recoverable condition; the panic surfaces the bug at the point of misuse. The global is written exactly once (immediately after `init` returns successfully) and read on every subsequent call site; it is never reassigned during the program's lifetime.

Multi-process binaries (future) will replace this global with a per-process slot loaded from the active process's runtime state; the change is reserved for ABI v2.0 and does not affect v1.x managers.

### 10.3 Build cache integration

The compiled `<manager>.o` is content-addressed by `(zig_fork_version, manager_source_hash, target, optimize)`. The compiler caches compiled manager objects in the same on-disk cache as Zap-generated objects; the cache miss happens only on first build or when one of the cache keys changes.

### 10.4 Failure modes and diagnostics

| Failure                                  | Stage   | Diagnostic                                                                           |
|------------------------------------------|---------|--------------------------------------------------------------------------------------|
| Adapter metadata missing                 | Step 2  | "build manifest did not evaluate a `Memory.Manager` adapter"                                |
| Primitive source reference invalid       | Step 2  | "invalid memory manager source reference `<ref>`: expected zap:<path>, project:<path>, or dep:<name>:<path>" |
| Manager Zig source missing               | Step 2  | "memory manager source not found at `<path>` (from adapter source reference `<ref>`)"       |
| Manager Zig source fails to compile      | Step 3  | Forwarded Zig compiler error, prefixed with the manager package name.                |
| `.zapmem` section absent from object     | Step 4  | "manager `<name>` did not emit a `.zapmem` metadata section; see docs/memory-manager-abi.md section 3" |
| Magic mismatch                           | Step 5  | "manager `<name>` has invalid magic (expected `'ZMEM'`, got `<bytes>`)"               |
| `abi_major` mismatch                     | Step 5  | "manager `<name>` declares ABI major `<n>`, compiler supports ABI major `1`"          |
| Capability version too new               | Step 5  | "manager `<name>` declares `<TAG>` at version `<n>`; this compiler supports only versions up to `<m>`" |
| Reserved capability bit declared         | Step 5  | "manager `<name>` declares reserved capability `<TAG>` (bit `<n>`), which has no committed v1.0 shape" |
| Embedded descriptor for undeclared cap   | Step 5  | "manager `<name>` embeds descriptor for capability `<TAG>` but does not declare it in declared_caps" |
| Embedded descriptor with `id == 0`       | Step 5  | "zap: manager embeds descriptor with id == 0; descriptor ID 0 is reserved"            |
| Embedded descriptor exceeds section size | Step 5  | "manager `<name>` declares `<n>` embedded descriptors but section is only `<bytes>` bytes" |
| `core.declared_caps != meta.declared_caps` | Step 5 | "manager `<name>` has mismatched declared_caps between meta header and core vtable"   |
| `meta._reserved2` non-zero               | Step 5  | "zap: manager metadata has non-zero reserved field _reserved2; the manager was built against a future ABI version" |
| `meta.reserved` non-zero                 | Step 5  | "manager `<name>` metadata reserved field is non-zero; the manager was built against a future ABI version" |
| Init returns null at runtime             | Runtime | "zap: manager `<name>` failed to initialize"                                          |
| `allocate` returns null at runtime       | Runtime | "zap: out of memory: requested `<size>` bytes (alignment `<alignment>`) from manager `<name>`; aborting" |

---

## 11. Extension model

The Zap source model is shared: memory managers are adapter structs
that implement `Memory.Manager`. Stdlib and third-party adapters use
the same compiler path: CTFE evaluates the protocol functions, the
driver resolves the primitive source reference, the selected source is
compiled for `.zapmem` validation, and the final binary registers the
same source path as `zap_active_manager`.

### 11.1 What a third party ships

A third-party manager is a Zap package containing:

1. A `<name>.zig` source file (path arbitrary, but typically `src/manager.zig`).
2. A `build.zig.zon` so the package can be referenced by Zap's dependency system.
3. A Zap adapter struct in `lib/<name>.zap` (or wherever the package
   exposes its public API) that implements `Memory.Manager`.

The user then references the Zap struct from their project's `build.zap`:

```
%Zap.Manifest{
  memory: ThirdParty.MyManager,
  deps: [{:third_party_manager, {:path, "../third_party_manager"}}],
  ...
}
```

The Zap compiler evaluates `ThirdParty.MyManager` through
`Memory.Manager`, resolves its primitive source reference, compiles the
named Zig file, validates the resulting `.zapmem` metadata, and threads
`declared_caps` into HIR and codegen.

#### 11.1.1 Third-party manager dependencies

v1.0 third-party managers may not declare Zig-package dependencies. The manager source must be self-contained: `@import("std")`, `@import("builtin")`, and the manager's own files (no `build.zig.zon` `dependencies` table). The `zap_fork_compile_zig_to_object` primitive is a flat C-ABI function whose signature is fixed for the lifetime of ABI v1.x; it carries no deps-array field and no size-extensible options struct, so dep support cannot be added under the `size`-field forward-extension convention used elsewhere in this spec (section 2.3 applies to extern structs, not flat C-ABI signatures).

Future ABI versions may add dep support by introducing a new C-ABI entry point (e.g., `zap_fork_compile_zig_to_object_v2`) that accepts a deps graph. The v1.0 primitive `zap_fork_compile_zig_to_object` will remain stable and continue to work for self-contained managers.

### 11.2 Versioning the third-party manager

The third party's package version is independent of Zap's ABI version. The third party declares the ABI version it builds against by setting `abi_major` / `abi_minor` in its emitted metadata. A v1.0-built third-party manager continues to work against any v1.x Zap compiler.

---

## 12. The Zap-side stdlib struct

For each memory manager, there is a field-free Zap adapter struct that
names the manager and implements `Memory.Manager`. The adapter is the
public source-level model. It exposes the manager's public name,
primitive source path, and declared capabilities through documented Zap
functions rather than through compiler-only attributes.

### 12.1 `Memory.Manager`

The top-level `Memory.Manager` protocol is the adapter contract:

- `name(manager) -> String`
- `primitive_source_path(manager) -> String`
- `capability_mask(manager) -> i64`
- `refcount_v1?(manager) -> Bool`

Stdlib and third-party adapters implement this protocol directly. The
adapter's `capability_mask/1` return value must match the validated
`.zapmem` metadata exactly.

### 12.2 Stdlib `Memory.ARC`

```
@doc = """
  Atomic reference counting memory manager.
  """

pub struct Memory.ARC {
}

@doc = """
  `Memory.Manager` adapter implementation for `Memory.ARC`.
  """

pub impl Memory.Manager for Memory.ARC {
  @doc = """
    Returns the public adapter name for the ARC manager.
    """

  pub fn name(_manager :: Memory.ARC) -> String {
    "Memory.ARC"
  }

  @doc = """
    Returns the primitive source path for the ARC manager.
    """

  pub fn primitive_source_path(_manager :: Memory.ARC) -> String {
    "zap:src/memory/arc/manager.zig"
  }

  @doc = """
    Returns the ARC manager's declared capability bitmask.
    """

  pub fn capability_mask(_manager :: Memory.ARC) -> i64 {
    1
  }

  @doc = """
    Returns true because ARC declares `REFCOUNT_V1`.
    """

  pub fn refcount_v1?(_manager :: Memory.ARC) -> Bool {
    true
  }
}
```

### 12.3 Stdlib `Memory.Arena`

```
@doc = """
  Whole-program arena memory manager.
  """

pub struct Memory.Arena {
}

@doc = """
  `Memory.Manager` adapter implementation for `Memory.Arena`.
  """

pub impl Memory.Manager for Memory.Arena {
  @doc = """
    Returns the public adapter name for the Arena manager.
    """

  pub fn name(_manager :: Memory.Arena) -> String {
    "Memory.Arena"
  }

  @doc = """
    Returns the primitive source path for the Arena manager.
    """

  pub fn primitive_source_path(_manager :: Memory.Arena) -> String {
    "zap:src/memory/arena/manager.zig"
  }

  @doc = """
    Returns the Arena manager's declared capability bitmask.
    """

  pub fn capability_mask(_manager :: Memory.Arena) -> i64 {
    0
  }

  @doc = """
    Returns false because Arena does not declare `REFCOUNT_V1`.
    """

  pub fn refcount_v1?(_manager :: Memory.Arena) -> Bool {
    false
  }
}
```

### 12.4 Adapter struct shape

Adapter structs are intentionally field-free. The behavior lives in the
`Memory.Manager` impl so the same protocol dispatch path can support
stdlib and third-party managers. Future APIs may accept values that
implement `Memory.Manager` for per-process selection; this document does
not define `Process` behavior.

---

## 13. Forbidden semantics

### 13.1 No shared mutable object graphs across managers

A v1 binary uses exactly one manager. Therefore, in v1, there is no possibility of cross-manager sharing. This is not a runtime check — it is a structural invariant enforced by the build system: the manifest selects exactly one `memory:` value, and the compiler emits all retain/release/allocate/deallocate calls against that single manager's vtable.

This restriction exists to make the future per-process model (v2's `Process.spawn(memory: ...)`) implementable without redesigning the v1 ABI. Under the future model, each process has its own manager, and messages between processes are deep-copied through the receiver's allocator (BEAM-style copy-on-send). Cross-manager pointer sharing would force every retain and release to dispatch through a manager-identity check at runtime — a cost that v1 must not bake in.

### 13.2 No manager swap at runtime

A binary's manager is fixed at link time. There is no API to swap managers, fork managers, or chain managers at runtime. Implementations of `init`, `deinit`, and `get_capability_desc` may assume they are the sole memory manager for the entire process lifetime.

### 13.3 No allocation from the manager's own code that bypasses `core.allocate`

If a manager needs internal heap storage (e.g., for its own bookkeeping tables), it may use `std.heap.page_allocator` or any other Zig-internal allocator directly. Such internal allocations are invisible to Zap and not accounted for as Zap allocations. The manager must not allocate user-visible objects (objects that the runtime may pass back to `core.deallocate`) through any path other than `core.allocate` returning to user code.

---

## 14. Worked example: no-op manager

This example shows the minimum viable manager: it declares zero capabilities, allocate returns null (allocation fails immediately), free is a no-op, init returns a non-null placeholder context, deinit is a no-op. It exists to validate the build pipeline end-to-end without any real allocation behavior.

### 14.1 Zig source: `noop/src/manager.zig`

```zig
const std = @import("std");
const builtin = @import("builtin");

const ZapMemoryManagerMetaV1 = extern struct {
    magic: u32,
    abi_major: u16,
    abi_minor: u16,
    size: u16,
    _reserved2: u16,
    desc_count: u32,
    declared_caps: u64,
    core_vtable_offset: u32,
    reserved: u32,
};

const ZapInitOptions = extern struct {
    size: u32,
    reserved: u32,
};

const ZapCapabilityDescV1 = extern struct {
    id: u32,
    version: u16,
    size: u16,
    flags: u32,
    vtable: *const anyopaque,
};

const ZapMemoryManagerCoreV1 = extern struct {
    abi_major: u16,
    abi_minor: u16,
    size: u32,
    declared_caps: u64,
    init: *const fn (?*const ZapInitOptions) callconv(.c) ?*anyopaque,
    deinit: *const fn (*anyopaque) callconv(.c) void,
    allocate: *const fn (*anyopaque, usize, u32) callconv(.c) ?[*]u8,
    deallocate: *const fn (*anyopaque, [*]u8, usize, u32) callconv(.c) void,
    get_capability_desc: *const fn (*anyopaque, u32) callconv(.c) ?*const ZapCapabilityDescV1,
};

// FourCC 'ZMEM' as a u32 in the target's endianness. Both branches
// produce the same byte sequence (5A 4D 45 4D); only the integer
// interpretation differs.
const ZMEM_MAGIC: u32 = switch (builtin.target.cpu.arch.endian()) {
    .little => 0x4D454D5A,
    .big => 0x5A4D454D,
};

const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    else => @compileError("unsupported object format for .zapmem section"),
};

// A non-null placeholder context so the runtime can tell init succeeded.
var noop_context_placeholder: u8 = 0;

fn noopInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    return @ptrCast(&noop_context_placeholder);
}

fn noopDeinit(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
}

fn noopAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    return null;
}

fn noopDeallocate(
    ctx: *anyopaque,
    ptr: [*]u8,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    _ = ctx;
    _ = ptr;
    _ = size;
    _ = alignment;
}

fn noopGetCapabilityDesc(
    ctx: *anyopaque,
    id: u32,
) callconv(.c) ?*const ZapCapabilityDescV1 {
    _ = ctx;
    _ = id;
    return null;
}

// Composite section payload: wraps the meta header and core vtable into
// a single extern struct so the linker emits them as one contiguous
// allocation in declaration order. This is the recommended emission
// pattern per section 3.2; it guarantees that `meta.core_vtable_offset`
// matches the actual layout regardless of linker quirks.
const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
};

pub export const zap_memory_section: ZapMemorySection
    linksection(SECTION_NAME) = .{
    .meta = .{
        .magic = ZMEM_MAGIC,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = 0,    // No capabilities declared.
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = 0,
        .init = noopInit,
        .deinit = noopDeinit,
        .allocate = noopAllocate,
        .deallocate = noopDeallocate,
        .get_capability_desc = noopGetCapabilityDesc,
    },
};
```

### 14.2 Zap source: `lib/memory/no_op.zap`

```
@doc = """
  No-op memory manager. Declares zero capabilities, the manager's
  `allocate` vtable slot returns null, and `deallocate` is a no-op.
  """

pub struct Memory.NoOp {
}

@doc = """
  `Memory.Manager` adapter implementation for `Memory.NoOp`.
  """

pub impl Memory.Manager for Memory.NoOp {
  @doc = """
    Returns the public adapter name for the NoOp manager.
    """

  pub fn name(_manager :: Memory.NoOp) -> String {
    "Memory.NoOp"
  }

  @doc = """
    Returns the primitive source path for the NoOp manager.
    """

  pub fn primitive_source_path(_manager :: Memory.NoOp) -> String {
    "zap:src/memory/no_op/manager.zig"
  }

  @doc = """
    Returns the NoOp manager's declared capability bitmask.
    """

  pub fn capability_mask(_manager :: Memory.NoOp) -> i64 {
    0
  }

  @doc = """
    Returns false because NoOp does not declare `REFCOUNT_V1`.
    """

  pub fn refcount_v1?(_manager :: Memory.NoOp) -> Bool {
    false
  }
}
```

### 14.3 Expected behavior

A program built with `memory: Memory.NoOp`:

1. Compiles cleanly. The `.zapmem` section is present, magic matches, `declared_caps = 0`.
2. The compiler elides every retain/release in HIR (because `REFCOUNT_V1` is not declared).
3. Map/List/String types are emitted without the refcount-header field.
4. At runtime, `init` returns the placeholder pointer.
5. The first allocation returns null, the runtime aborts with: `zap: out of memory: requested <size> bytes (alignment <alignment>) from manager Memory.NoOp; aborting`.

---

## 15. Worked example: minimal refcounting manager

This example shows a small but complete refcounting manager. It uses `std.heap.page_allocator` for backing storage. Each refcounted cell carries an inline header sitting immediately before the user pointer; the header stores the refcount along with enough metadata (the offset of the user pointer from the start of the original allocation block, the block's total size, and the user-requested alignment) to recover the original allocation precisely when the count reaches zero. The manager also handles raw allocations (those not produced for a refcounted type) by routing them through the same path; `tinyrefDeallocate` is exercised for transient scratch buffers and other non-refcounted allocations. It declares `REFCOUNT_V1`.

The header layout is sized to support arbitrary user-requested alignments, including alignments greater than the header's own size (for example 32-byte AVX vectors or 64-byte cacheline alignment). Production managers that target only small power-of-two alignments may shrink the header further; the layout shown here is the general-case template.

### 15.1 Zig source: `tinyref/src/manager.zig`

```zig
const std = @import("std");
const builtin = @import("builtin");

const ZapMemoryManagerMetaV1 = extern struct {
    magic: u32,
    abi_major: u16,
    abi_minor: u16,
    size: u16,
    _reserved2: u16,
    desc_count: u32,
    declared_caps: u64,
    core_vtable_offset: u32,
    reserved: u32,
};

const ZapInitOptions = extern struct {
    size: u32,
    reserved: u32,
};

const ZapCapabilityDescV1 = extern struct {
    id: u32,
    version: u16,
    size: u16,
    flags: u32,
    vtable: *const anyopaque,
};

const ZapDeepWalkFn = *const fn (*anyopaque) callconv(.c) void;

const ZapRefcountCapabilityV1 = extern struct {
    retain: *const fn (*anyopaque, *anyopaque) callconv(.c) void,
    release: *const fn (*anyopaque, *anyopaque, ?ZapDeepWalkFn) callconv(.c) void,
};

const ZapMemoryManagerCoreV1 = extern struct {
    abi_major: u16,
    abi_minor: u16,
    size: u32,
    declared_caps: u64,
    init: *const fn (?*const ZapInitOptions) callconv(.c) ?*anyopaque,
    deinit: *const fn (*anyopaque) callconv(.c) void,
    allocate: *const fn (*anyopaque, usize, u32) callconv(.c) ?[*]u8,
    deallocate: *const fn (*anyopaque, [*]u8, usize, u32) callconv(.c) void,
    get_capability_desc: *const fn (*anyopaque, u32) callconv(.c) ?*const ZapCapabilityDescV1,
};

const ZMEM_MAGIC: u32 = switch (builtin.target.cpu.arch.endian()) {
    .little => 0x4D454D5A,
    .big => 0x5A4D454D,
};
const REFC_TAG: u32 = switch (builtin.target.cpu.arch.endian()) {
    .little => 0x4346_4552,
    .big => 0x5245_4643,
};
const CAP_REFCOUNT_V1_BIT: u64 = 0x0000_0000_0000_0001;

const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    else => @compileError("unsupported object format"),
};

// Inline header placed immediately before the user pointer. The header
// is allocated into headroom carved out of the underlying page-allocator
// block, then offset-shifted by `tinyrefAllocate` so that the user
// pointer satisfies an arbitrary requested alignment (including 32-byte
// AVX or 64-byte cacheline alignments that exceed the header's own
// size).
//
// The header stores:
//   - `refcount`:     atomic refcount for REFCOUNT_V1 semantics.
//   - `size`:         user payload size, so `freeCell` can verify the
//                     runtime's `size` argument and so a future manager
//                     extension may grow the payload in place.
//   - `alignment`:    user-requested alignment, used to dispatch
//                     `page_allocator.free` against the same alignment
//                     the original alignedAlloc used.
//   - `block_offset`: distance in bytes from the start of the original
//                     page-allocator block to the user pointer; required
//                     to recover the original block address regardless
//                     of the alignment slack the allocator inserted.
//   - `block_size`:   total length (in bytes) of the original block,
//                     including header headroom and alignment slack;
//                     required to free the block as a precisely-sized
//                     slice.
//
// The header is larger than the 16 bytes used in earlier drafts: storing
// `block_offset` and `block_size` is mandatory to handle alignment > 16
// correctly. Production managers that pool allocations by size class can
// shrink the header by replacing `size`/`alignment`/`block_size` with a
// size-class index and reading the rest from a per-class descriptor; the
// general-case header below is sized for correctness over compactness.
const Header = extern struct {
    refcount: u32,        // atomic, accessed via @atomicRmw
    size: u32,            // user payload size in bytes
    alignment: u32,       // user-requested alignment, power of two
    block_offset: u32,    // bytes from block start to user pointer
    block_size: u64,      // total size of the page-allocator block
};
const HEADER_SIZE: usize = @sizeOf(Header);    // 24 bytes
const HEADER_ALIGN: u32 = @alignOf(Header);    // 8 bytes on 64-bit targets

// `block_size` is declared `u64` rather than `usize` deliberately. The
// 24-byte assertion below holds across the v1.0 supported targets (all
// 64-bit, per Appendix C); a future port to a 32-bit target would
// shrink `usize` to 4 bytes and quietly break the layout. Using a
// fixed-width `u64` keeps the assertion as a compile-time tripwire —
// the manager author is forced to update the layout deliberately
// rather than absorbing the change silently.
comptime {
    // Lock the header layout for this example. A production manager may
    // pick a different size — the only hard constraint is that
    // `tinyrefAllocate` reserves at least `HEADER_SIZE` bytes between the
    // block start and the user pointer.
    if (HEADER_SIZE != 24) @compileError("Header must be exactly 24 bytes");
}

// Per-manager context. The example carries a single atomic counter
// for diagnostics so that `ctx` is exercised meaningfully on every
// allocation path. A production manager would track per-size-class
// statistics, current high-water mark, etc.
const Context = struct {
    allocation_counter: std.atomic.Value(u64),
};

var context_storage: Context = .{
    .allocation_counter = std.atomic.Value(u64).init(0),
};

fn tinyrefInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    return @ptrCast(&context_storage);
}

fn tinyrefDeinit(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
    // No cleanup required — context_storage is statically allocated and
    // every Zap-issued allocation is freed via release/deallocate before
    // we get here.
}

// Allocate `size` bytes with at least `alignment` byte alignment for
// the returned user pointer. Handles arbitrary power-of-two alignment
// values, including alignments larger than HEADER_SIZE.
//
// Layout of the underlying block:
//
//     [ alignment slack ][ Header ][ user payload (size bytes) ]
//     ^                            ^
//     block_start                  user_start (aligned to `alignment`)
//
// The block is allocated at alignment = max(alignment, HEADER_ALIGN) so
// that, regardless of where in the block the user pointer ends up, the
// header behind it remains naturally aligned. We reserve worst-case
// padding (`padded_alignment`) ahead of the header so we always have
// room to advance the user pointer forward to satisfy `alignment`.
//
// The allocation uses `rawAlloc` / `rawFree` rather than `alignedAlloc`
// because the runtime alignment value cannot be passed through the
// comptime-alignment alloc helpers. The matching free in `freeCell` uses
// the same alignment, so the allocator's vtable dispatch is symmetric.
fn tinyrefAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const context: *Context = @ptrCast(@alignCast(ctx));
    _ = context.allocation_counter.fetchAdd(1, .monotonic);

    // `padded_alignment` is the alignment handed to the underlying
    // allocator; it must be at least `HEADER_ALIGN` so that the header
    // (placed immediately before the user pointer) is also naturally
    // aligned, and at least `alignment` so the user pointer can be
    // advanced forward to satisfy the request.
    const padded_alignment: u32 = @max(alignment, HEADER_ALIGN);
    const total: usize = HEADER_SIZE + size + padded_alignment;
    const allocator_alignment = std.mem.Alignment.fromByteUnits(padded_alignment);

    const block_ptr = std.heap.page_allocator.rawAlloc(
        total,
        allocator_alignment,
        @returnAddress(),
    ) orelse return null;

    // Place the user pointer at the next address that is aligned to the
    // requested `alignment` AND leaves at least HEADER_SIZE bytes behind
    // it for the header.
    const block_start = @intFromPtr(block_ptr);
    const user_start_min = block_start + HEADER_SIZE;
    const user_start = std.mem.alignForward(usize, user_start_min, alignment);

    // The header sits immediately before the user pointer. Because
    // `block_start` is aligned to `padded_alignment` (at least
    // HEADER_ALIGN) and `user_start` advances from there by a multiple
    // of `alignment` (also at least HEADER_ALIGN by `padded_alignment`'s
    // definition), `(user_start - HEADER_SIZE)` is HEADER_ALIGN-aligned.
    const header_ptr: *Header = @ptrFromInt(user_start - HEADER_SIZE);
    header_ptr.* = .{
        .refcount = 1,
        .size = @intCast(size),
        .alignment = alignment,
        .block_offset = @intCast(user_start - block_start),
        .block_size = @intCast(total),
    };

    return @ptrFromInt(user_start);
}

// Helper: free a cell whose Header is at `*header` and whose user
// pointer is at `user_ptr`. Used by both `release` (when the refcount
// reaches zero) and `tinyrefDeallocate` (for raw, non-refcounted
// allocations).
//
// Recovers the original block address via `header.block_offset` and
// frees the block as a slice of `header.block_size` bytes, passing the
// padded alignment used at allocation time so the allocator's vtable
// dispatch is symmetric with `rawAlloc`.
fn freeCell(header: *Header, user_ptr: [*]u8) void {
    const user_addr = @intFromPtr(user_ptr);
    const block_start_addr = user_addr - @as(usize, header.block_offset);
    const block_start: [*]u8 = @ptrFromInt(block_start_addr);
    const padded_alignment: u32 = @max(header.alignment, HEADER_ALIGN);
    const slice = block_start[0..@as(usize, header.block_size)];
    std.heap.page_allocator.rawFree(
        slice,
        std.mem.Alignment.fromByteUnits(padded_alignment),
        @returnAddress(),
    );
}

// Called for raw (non-refcounted) allocations only. The runtime never
// calls this for cells produced for a refcounted Zap type — those are
// freed exclusively via `release`. Examples of raw allocations:
// transient scratch buffers, runtime-internal bookkeeping, and any
// Zap-level allocations issued under a non-refcounted type.
fn tinyrefDeallocate(
    ctx: *anyopaque,
    ptr: [*]u8,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    _ = ctx;
    // The runtime passes back the exact `size` and `alignment` we were
    // called with at allocate-time. We could trust them, but we cross-
    // check against the inline header to catch double-frees and
    // mismatched sizes — a real production manager would compile this
    // check out under ReleaseFast.
    const header_ptr: *Header = @ptrFromInt(@intFromPtr(ptr) - HEADER_SIZE);
    std.debug.assert(header_ptr.size == size);
    std.debug.assert(header_ptr.alignment == alignment);
    freeCell(header_ptr, ptr);
}

fn tinyrefGetCapabilityDesc(
    ctx: *anyopaque,
    id: u32,
) callconv(.c) ?*const ZapCapabilityDescV1 {
    _ = ctx;
    if (id == REFC_TAG) return &refcount_desc;
    return null;
}

fn tinyrefRetain(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    const header_ptr: *Header = @ptrFromInt(@intFromPtr(object) - HEADER_SIZE);
    _ = @atomicRmw(u32, &header_ptr.refcount, .Add, 1, .monotonic);
}

// `release` is the sole authority for freeing a refcounted cell.
// When the final decrement brings the count to zero, this function
// must (1) invoke deep_walk if non-null and (2) return the cell's
// storage to its underlying allocator. The runtime will never call
// `deallocate` on a refcounted cell after `release` returns.
fn tinyrefRelease(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?ZapDeepWalkFn,
) callconv(.c) void {
    _ = ctx;
    const user_ptr: [*]u8 = @ptrCast(object);
    const header_ptr: *Header = @ptrFromInt(@intFromPtr(object) - HEADER_SIZE);
    const prev = @atomicRmw(u32, &header_ptr.refcount, .Sub, 1, .acq_rel);
    if (prev == 1) {
        // The decrement that took us to zero. Walk children first so
        // they observe the still-valid parent, then free the cell.
        if (deep_walk) |walk| walk(object);
        // Recover the original block address from header.block_offset
        // and free the page-allocator slice we originally allocated.
        freeCell(header_ptr, user_ptr);
    }
}

const refcount_vtable: ZapRefcountCapabilityV1 = .{
    .retain = tinyrefRetain,
    .release = tinyrefRelease,
};

const refcount_desc: ZapCapabilityDescV1 = .{
    .id = REFC_TAG,
    .version = 1,
    .size = @sizeOf(ZapRefcountCapabilityV1),
    .flags = 0,
    .vtable = &refcount_vtable,
};

// Composite section payload following the recommended emission pattern
// from section 3.2: wrapping the meta header and core vtable into a
// single extern struct so the linker emits them as one contiguous
// allocation in declaration order. `meta.core_vtable_offset` is derived
// from the struct layout via `@offsetOf`, so the section is always
// self-consistent regardless of linker behavior.
//
// This example uses runtime-only capability discovery (`desc_count = 0`):
// the compiler retrieves the refcount descriptor via `get_capability_desc`
// at startup rather than reading it directly from the .zapmem section.
// A manager that prefers embedded discovery would add a `desc_0:
// ZapCapabilityDescV1` field after `core` and set `desc_count = 1`.
const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
};

pub export const zap_memory_section: ZapMemorySection
    linksection(SECTION_NAME) = .{
    .meta = .{
        .magic = ZMEM_MAGIC,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = CAP_REFCOUNT_V1_BIT,
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = CAP_REFCOUNT_V1_BIT,
        .init = tinyrefInit,
        .deinit = tinyrefDeinit,
        .allocate = tinyrefAllocate,
        .deallocate = tinyrefDeallocate,
        .get_capability_desc = tinyrefGetCapabilityDesc,
    },
};
```

### 15.2 Zap source: `lib/tinyref.zap`

```
@doc = """
  Minimal example refcounting manager. Backs allocations with the
  page allocator and stores a 32-bit atomic refcount along with the
  original allocation's offset, size, and alignment in an inline
  header. Supports arbitrary user-requested alignment values.
  Demonstrates the smallest manager that declares REFCOUNT_V1 while
  still freeing cells correctly when the refcount reaches zero.
  """

pub struct TinyRef {
}

@doc = """
  `Memory.Manager` adapter implementation for `TinyRef`.
  """

pub impl Memory.Manager for TinyRef {
  @doc = """
    Returns the public adapter name for TinyRef.
    """

  pub fn name(_manager :: TinyRef) -> String {
    "TinyRef"
  }

  @doc = """
    Returns the primitive source reference for TinyRef.
    """

  pub fn primitive_source_path(_manager :: TinyRef) -> String {
    "project:src/manager.zig"
  }

  @doc = """
    Returns TinyRef's declared capability bitmask.
    """

  pub fn capability_mask(_manager :: TinyRef) -> i64 {
    1
  }

  @doc = """
    Returns true because TinyRef declares `REFCOUNT_V1`.
    """

  pub fn refcount_v1?(_manager :: TinyRef) -> Bool {
    true
  }
}
```

### 15.3 Notes on the example

- The 24-byte inline `Header` carries the refcount along with `size`, `alignment`, `block_offset`, and `block_size`. The first three fields suffice for fixed-alignment cells; the latter two are what enables this example to support arbitrary user-requested alignments (32, 64, or larger) without losing the ability to recover and free the original page-allocator block. A production manager that targets fixed-size cells (slab pool buckets) can shrink the header by replacing the inline `size`/`alignment`/`block_size` fields with a size-class index — the per-class descriptor then carries the same information for every cell in the class. The example uses the general layout for clarity; the comptime assertion on `HEADER_SIZE` is a soft lock specific to this example, not part of the ABI.
- `release` invokes `deep_walk` before freeing so children see a still-valid parent during their own release path. The compiler chooses `deep_walk` per refcounted type: cells with no refcounted children get `null` and never trigger the walk; cells with refcounted children get the per-type walk function the compiler generated.
- `tinyrefDeallocate` is reserved for raw allocations only. The runtime never calls it for refcounted cells — those go through `release` exclusively (section 4.5). The example uses it both to free scratch buffers and to demonstrate header-based size/alignment recovery in a non-refcounted path.
- The example uses `std.heap.page_allocator` directly. A production manager amortizes per-allocation syscalls with a slab pool: blocks of fixed-size cells per power-of-two size class, with O(1) allocation and free.
- `ctx` is used meaningfully on the allocation path: the example increments an atomic allocation counter on every `allocate` so the `ctx` parameter exercises the per-manager state path. On the retain/release/deallocate paths `ctx` is discarded with `_ = ctx` because the inline `Header` already carries everything those functions need; the discards are deliberate, not accidental. A truly stateless manager could pass a sentinel pointer from `init` and discard `ctx` in every vtable function, but realistic managers always have at least bookkeeping state.
- This example demonstrates: metadata section emission with the meta + core-vtable layout, capability declaration, capability descriptor, core vtable, refcount capability vtable, atomic refcount semantics, deep-walk integration, and `release`-owned freeing.

---

## 16. Diagnostic managers

Two non-user-facing managers ship with the Zap source tree as part of the test infrastructure:

| Manager           | Source                                            | Purpose                                              |
|-------------------|---------------------------------------------------|------------------------------------------------------|
| `Memory.Leak`     | `src/memory/leak/manager.zig`         | Allocates from the page allocator, never frees. Declares no capabilities. Used to verify that retain/release elision is complete under a non-refcounting manager. |
| `Memory.Tracking` | `src/memory/tracking/manager.zig`     | Wraps another manager and logs every allocate / deallocate / retain / release call. Used to detect missing or duplicated lifecycle events in compiler tests. |

These managers are not part of the public ABI surface in the sense that users do not select them via `memory:` in production builds. They are used by the Zap test runner to validate ABI-conformance properties (e.g., "every retain has a matching release") on every CI run. Their implementation follows the same ABI as `Memory.ARC` and `Memory.Arena`; no special compiler accommodation is needed.

---

## 17. Future work — explicitly out of scope for v1

The following are reserved for future ABI versions:

| Feature                                       | Reserved capability tag / bit | Earliest expected ABI |
|-----------------------------------------------|-------------------------------|------------------------|
| Tracing garbage collection                    | `GCOL` (bit 1)                | v2.0 or later          |
| Region-based memory management                | `REGN` (bit 2)                | v2.0 or later          |
| Manager-side allocation statistics            | `STAT` (bit 3)                | v1.x                   |
| Object finalization                           | `FNLZ` (bit 4)                | v1.x                   |
| Weak references                               | `WKRF` (bit 5)                | v1.x                   |
| Scoped / resettable arena lifetime            | `ARSR` (bit 6)                | v1.x                   |
| Thread-safe arena variant marker              | `ARTS` (bit 7)                | v1.x                   |
| Cross-process shared heap (BEAM-style)        | `SHHP` (bit 8)                | v2.x                   |
| Write-barrier infrastructure for tracing GC   | `TRAC` (bit 9)                | v2.0                   |
| Per-process `Process.spawn(memory:)`          | (no capability bit)           | v2.0                   |
| Multi-manager binaries                        | (no capability bit)           | Not currently planned  |

For each reserved bit, the tag and bit position are committed. The struct shape may evolve before the capability is first DEFINED; v1.x managers must not declare these bits.

The "Earliest expected ABI" column is indicative, not contractual; capabilities may move forward or backward as design clarifies.

---

## Appendix A. Capability tag to bit position table

This is the canonical, normative mapping from FourCC tag to bit position in `declared_caps`. The table is hand-curated and stable for the lifetime of ABI v1.x. Future minor versions may add entries at unused positions; no entry may be reassigned.

| Bit | FourCC | Tag bytes (in memory order) | Tag as LE u32 | Tag as BE u32 | Identifier               | v1.0 status     |
|-----|--------|-----------------------------|---------------|---------------|--------------------------|-----------------|
| 0   | `REFC` | `52 45 46 43`               | `0x4346_4552` | `0x5245_4643` | `CAP_REFCOUNT_V1`        | DEFINED         |
| 1   | `GCOL` | `47 43 4F 4C`               | `0x4C4F_4347` | `0x4743_4F4C` | `CAP_TRACING_GC_V1`      | RESERVED        |
| 2   | `REGN` | `52 45 47 4E`               | `0x4E47_4552` | `0x5245_474E` | `CAP_REGION_V1`          | RESERVED        |
| 3   | `STAT` | `53 54 41 54`               | `0x5441_5453` | `0x5354_4154` | `CAP_STATS_V1`           | RESERVED        |
| 4   | `FNLZ` | `46 4E 4C 5A`               | `0x5A4C_4E46` | `0x464E_4C5A` | `CAP_FINALIZER_V1`       | RESERVED        |
| 5   | `WKRF` | `57 4B 52 46`               | `0x4652_4B57` | `0x574B_5246` | `CAP_WEAK_REF_V1`        | RESERVED        |
| 6   | `ARSR` | `41 52 53 52`               | `0x5253_5241` | `0x4152_5352` | `CAP_ARENA_RESET_V1`     | RESERVED        |
| 7   | `ARTS` | `41 52 54 53`               | `0x5354_5241` | `0x4152_5453` | `CAP_ARENA_THREAD_SAFE_V1` | RESERVED      |
| 8   | `SHHP` | `53 48 48 50`               | `0x5048_4853` | `0x5348_4850` | `CAP_SHARED_HEAP_V1`     | RESERVED        |
| 9   | `TRAC` | `54 52 41 43`               | `0x4341_5254` | `0x5452_4143` | `CAP_TRACING_V1`         | RESERVED        |
| 10  | —      | —                           | —             | —             | UNUSED                   | —               |
| 11  | —      | —                           | —             | —             | UNUSED                   | —               |
| …   | —      | —                           | —             | —             | UNUSED                   | —               |
| 63  | —      | —                           | —             | —             | UNUSED                   | —               |

### A.1 Computing the bit mask from a tag

```zig
const std = @import("std");
const builtin = @import("builtin");

// FourCC tag constants matching the canonical table in Appendix A.
// `std.mem.readInt` with the target's native endian resolves each
// four-character literal at comptime to the target-endianness-correct
// u32 representation of the tag — exactly the integer value the manager
// metadata validator compares against.
const TAG_ENDIAN = builtin.target.cpu.arch.endian();
const REFC_TAG: u32 = std.mem.readInt(u32, "REFC", TAG_ENDIAN);
const GCOL_TAG: u32 = std.mem.readInt(u32, "GCOL", TAG_ENDIAN);
const REGN_TAG: u32 = std.mem.readInt(u32, "REGN", TAG_ENDIAN);
const STAT_TAG: u32 = std.mem.readInt(u32, "STAT", TAG_ENDIAN);
const FNLZ_TAG: u32 = std.mem.readInt(u32, "FNLZ", TAG_ENDIAN);
const WKRF_TAG: u32 = std.mem.readInt(u32, "WKRF", TAG_ENDIAN);
const ARSR_TAG: u32 = std.mem.readInt(u32, "ARSR", TAG_ENDIAN);
const ARTS_TAG: u32 = std.mem.readInt(u32, "ARTS", TAG_ENDIAN);
const SHHP_TAG: u32 = std.mem.readInt(u32, "SHHP", TAG_ENDIAN);
const TRAC_TAG: u32 = std.mem.readInt(u32, "TRAC", TAG_ENDIAN);

fn bit_for_tag(tag: u32) ?u6 {
    // Sequential search of the canonical table. The table is small
    // enough that linear scan is faster than any hashing scheme.
    return switch (tag) {
        // Match against the tag in the target's endianness.
        // The compiler builds for a single target so this branch
        // resolves at comptime.
        REFC_TAG => 0,
        GCOL_TAG => 1,
        REGN_TAG => 2,
        STAT_TAG => 3,
        FNLZ_TAG => 4,
        WKRF_TAG => 5,
        ARSR_TAG => 6,
        ARTS_TAG => 7,
        SHHP_TAG => 8,
        TRAC_TAG => 9,
        else => null,
    };
}
```

The Zap compiler's metadata validator uses an equivalent lookup against the target-endianness-correct tag values. The naming convention `<NAME>_TAG` matches the worked refcount example in section 15.

---

## Appendix B. `.zapmem` byte layout

This appendix gives the exact byte layout of the `.zapmem` section, by offset, for a 64-bit target with 8-byte alignment. All multi-byte fields are stored in the target's native byte order (see section 3.4).

The section is a single contiguous blob laid out as:

```
[ ZapMemoryManagerMetaV1                     ]  @ 0
[ ZapMemoryManagerCoreV1                     ]  @ meta.core_vtable_offset (32 in v1.0)
[ ZapCapabilityDescV1 * meta.desc_count      ]  @ meta.core_vtable_offset + core.size (88 in v1.0)
```

### B.1 `ZapMemoryManagerMetaV1` (32 bytes, at section offset 0x00)

```
Offset  Size  Field               Notes
------  ----  ------------------  ------------------------------------------
0x00    4     magic               'ZMEM' as u32 (target-endianness)
0x04    2     abi_major           1
0x06    2     abi_minor           0 (v1.0) or 1 (v1.1; see section 2.1)
0x08    2     size                32 in v1.x (sizeof(ZapMemoryManagerMetaV1))
0x0A    2     _reserved2          Reserved; must be 0
0x0C    4     desc_count          Number of embedded ZapCapabilityDescV1
0x10    8     declared_caps       Bitmask, see Appendix A
0x18    4     core_vtable_offset  Byte offset (from section start) of the
                                  ZapMemoryManagerCoreV1 struct. 32 in v1.0.
0x1C    4     reserved            Must be 0
0x20    -     -                   (end of meta; total 32 bytes)
```

The struct layout above places the `u64` `declared_caps` at offset 0x10 (8-byte aligned) without any explicit padding bytes — every preceding field naturally aligns the next.

### B.2 `ZapMemoryManagerCoreV1` (56 bytes, at section offset `meta.core_vtable_offset`)

In the canonical v1.0 layout, this begins at offset 0x20 (immediately after the meta header):

```
Offset  Size  Field                Notes
------  ----  -------------------  -----------------------------------------
0x00    2     abi_major            Must equal meta.abi_major
0x02    2     abi_minor            Must equal meta.abi_minor
0x04    4     size                 56 in v1.0 on a 64-bit target
0x08    8     declared_caps        Must equal meta.declared_caps
0x10    8     init                 Function pointer (callconv(.c))
0x18    8     deinit               Function pointer (callconv(.c))
0x20    8     allocate             Function pointer (callconv(.c))
0x28    8     deallocate           Function pointer (callconv(.c))
0x30    8     get_capability_desc  Function pointer (callconv(.c))
0x38    -     -                    (end of core vtable; total 56 bytes)
```

Section-absolute offsets in the canonical v1.0 layout: 0x20 .. 0x57.

### B.3 Embedded `ZapCapabilityDescV1` array (24 bytes per entry)

Starting at section offset `meta.core_vtable_offset + core.size` (= 0x58 in the canonical v1.0 layout), `meta.desc_count` entries follow:

```
Entry offset relative to start of entry:
0x00    4     id              FourCC tag as u32 (target-endianness)
0x04    2     version         Per-capability version
0x06    2     size            sizeof(vtable struct). For REFCOUNT_V1: 16
                                (v1.0) or 48 (v1.1). See section 8.
0x08    4     flags           Capability-specific; SHOULD be 0 in v1.0
                                (unknown bits are silently ignored)
0x0C    4     (padding)       Zero-filled; required for 8-byte align
0x10    8     vtable          Pointer to capability vtable
0x18    -     -               (end of entry; total 24 bytes)
```

### B.3a `ZapRefcountCapabilityV1` vtable byte layout

The `vtable` field of a REFCOUNT_V1 descriptor points at an out-of-section vtable whose length is given by `desc.size`. The byte layout of the vtable proper:

```
v1.0 (desc.size = 16, abi_minor = 0):
Offset  Size  Field        Notes
------  ----  -----------  -----------------------------------------
0x00    8     retain       Function pointer (callconv(.c))
0x08    8     release      Function pointer (callconv(.c))
0x10    -     -            (end of v1.0 vtable; total 16 bytes)

v1.1 (desc.size = 48, abi_minor = 1):
Offset  Size  Field                Notes
------  ----  -------------------  -----------------------------------------
0x00    8     retain               Function pointer (callconv(.c)). Identical
                                   to v1.0 slot 0.
0x08    8     release              Function pointer (callconv(.c)). Identical
                                   to v1.0 slot 1.
0x10    8     retain_sized         Function pointer (callconv(.c)). v1.1+.
0x18    8     release_sized        Function pointer (callconv(.c)). v1.1+.
0x20    8     allocate_refcounted  Function pointer (callconv(.c)). v1.1+.
0x28    8     refcount_sized       Function pointer (callconv(.c)). v1.1+.
0x30    -     -                    (end of v1.1 vtable; total 48 bytes)
```

The first 16 bytes are bit-identical across both minors — v1.1 is an additive extension. A consumer that knows only v1.0 reads `desc.size = 16` for a v1.0 manager (or `desc.size = 48` for a v1.1 manager and ignores the trailer per section 2.3). A v1.1+ consumer reads up to the slot count it understands and routes generic `Arc(T)` allocations to `allocate_refcounted` only when `desc.size >= 48`.

### B.4 Total `.zapmem` section size

The canonical v1.0 layout has a fixed prefix (meta + core = 88 bytes) and a variable-length descriptor tail. The total section size is therefore parametrized by `meta.desc_count`:

```
section_size = sizeof(meta) + sizeof(core) + 24 * meta.desc_count
             = 32 + 56 + 24 * meta.desc_count          # canonical v1.0
             = 88 + 24 * meta.desc_count
```

If `meta.desc_count = 0`, the section is exactly 88 bytes. If `meta.desc_count = 1` (e.g., a refcounting-only manager that embeds its single descriptor), the section is 112 bytes; each additional embedded descriptor adds 24 bytes. The total is not a single fixed value — it scales with the manager's chosen capability set.

### B.5 Alignment

The `.zapmem` section is aligned to 8 bytes (the natural alignment of `u64` and pointer). Zig's `linksection` attribute combined with the natural alignment of the exported structs produces correct alignment automatically; managers do not need explicit `@alignOf` annotations. The meta header, the core vtable, and each descriptor all begin on 8-byte boundaries in the canonical layout because each struct's size is a multiple of 8.

### B.6 Endianness summary

```
Little-endian targets (x86_64, aarch64, riscv64, wasm32, ...):
    magic = 0x4D454D5A     # bytes in memory: 5A 4D 45 4D

Big-endian targets (powerpc64be, s390x, ...):
    magic = 0x5A4D454D     # bytes in memory: 5A 4D 45 4D
```

The byte sequence `5A 4D 45 4D` is the same in both cases — the bytes spell `Z`, `M`, `E`, `M`. Only the interpretation as a `u32` differs. The Zap compiler reads the bytes as a `u32` in the target's native byte order and compares against the target-endianness-correct constant.

---

## Appendix C. `ZapForkTarget` tag mapping (v1.0)

The `arch_tag`, `os_tag`, and `abi_tag` fields of `ZapForkTarget` (section 10.1.2) carry the integer values of the Zap-pinned Zig fork's `std.Target.Cpu.Arch`, `std.Target.Os.Tag`, and `std.Target.Abi` enums, respectively. The Zig fork pins these enum definitions for the lifetime of ABI v1.x — adding new tags is permitted (appends to the end of the enum) but reordering or removing existing tags is prohibited. This guarantees that the integer values shown below are stable wire constants.

The values in this appendix are read directly from `lib/std/Target.zig` in the pinned Zig fork (`~/projects/zig`). Each enum begins at integer 0 and increments by 1 per declaration; the tables below give the discriminant of every supported tag.

### C.1 Supported target triples (v1.0)

The set of supported targets is the intersection of (a) targets the Zap-pinned Zig fork can compile and (b) targets for which the Zap runtime has been ported. v1.0 supports exactly five triples:

| Triple                  | `arch_tag` (u16) | `os_tag` (u16) | `abi_tag` (u16) |
|-------------------------|------------------|----------------|------------------|
| `x86_64-linux-gnu`      | 54 (`x86_64`)    | 9 (`linux`)    | 1 (`gnu`)        |
| `x86_64-macos-none`     | 54 (`x86_64`)    | 20 (`macos`)   | 0 (`none`)       |
| `aarch64-linux-gnu`     | 0 (`aarch64`)    | 9 (`linux`)    | 1 (`gnu`)        |
| `aarch64-macos-none`    | 0 (`aarch64`)    | 20 (`macos`)   | 0 (`none`)       |
| `x86_64-windows-msvc`   | 54 (`x86_64`)    | 24 (`windows`) | 22 (`msvc`)      |

A v1.0 caller that passes an unsupported `(arch_tag, os_tag, abi_tag)` triple receives `ZapForkResult.TargetUnsupported`. The diagnostic buffer carries a human-readable explanation including the rejected triple.

Special value: `arch_tag == 0xFFFF` (decimal 65535) requests the host
target. When set, `os_tag` and `abi_tag` are ignored; the primitive
selects the running compiler's native target. Useful for the common
case where the manager is compiled for the host (e.g., the Zap build
orchestrator targeting the same machine the build is running on). The
Zig fork exposes this sentinel as `ZAP_FORK_ARCH_NATIVE`. The
primitive verifies the resolved native host is itself in the v1.0
supported set above; if a developer is running on an experimental host
that does not appear in the table, the call is rejected with
`TargetUnsupported` and a diagnostic naming the host triple, rather
than silently emitting an unsupported binary.

The reserved field `ZapForkTarget._reserved` must be zero in v1.0. A
non-zero value indicates either a caller bug or a struct built against
a future ABI version that the v1.0 primitive cannot interpret safely;
the primitive rejects such inputs with `TargetUnsupported`. Future ABI
revisions may repurpose `_reserved` as a flags or option field;
existing callers that respect the v1.0 contract (`_reserved = 0`) will
continue to work under those revisions.

### C.2 `std.Target.Cpu.Arch` value table

The relevant subset of the pinned enum for v1.0 supported architectures:

| Identifier   | u16 value |
|--------------|-----------|
| `aarch64`    | 0         |
| `x86_64`     | 54        |

The full enum at the time of pinning is the 58-entry list at `lib/std/Target.zig:1326` in the Zig fork; only the two entries above are reachable through v1.0's supported target intersection.

### C.3 `std.Target.Os.Tag` value table

The relevant subset of the pinned enum for v1.0 supported operating systems:

| Identifier   | u16 value |
|--------------|-----------|
| `linux`      | 9         |
| `macos`      | 20        |
| `windows`    | 24        |

The full enum at the time of pinning is the 42-entry list at `lib/std/Target.zig:18` in the Zig fork; only the three entries above are reachable through v1.0's supported target intersection.

### C.4 `std.Target.Abi` value table

The relevant subset of the pinned enum for v1.0 supported ABIs:

| Identifier   | u16 value |
|--------------|-----------|
| `none`       | 0         |
| `gnu`        | 1         |
| `msvc`       | 22        |

The full enum at the time of pinning is the 27-entry list at `lib/std/Target.zig:762` in the Zig fork; only the three entries above are reachable through v1.0's supported target intersection.

### C.5 Stability contract

These integer values are normative for ABI v1.x. The Zap fork of Zig pins them in `lib/std/Target.zig`; any change to the Zig upstream that reorders the existing enum entries listed in C.2 through C.4 must be backed out during the fork-rebase rather than carried in. New architectures, operating systems, or ABIs added to upstream Zig append to the end of each enum and therefore preserve the existing values.

A v1.x manager source is expected to support every Zap-supported target via the comptime branches shown in sections 14 and 15. Managers that target a subset of platforms guard the unsupported branches with `@compileError`.

---

*End of Memory Manager ABI v1.0 specification.*
