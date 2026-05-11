# Memory Manager ABI v1.0 — Normative Specification

**Status:** Normative. Final for v1.0. Any incompatible change requires an ABI major bump (v2.0).

**Audience:** Third-party authors of Zap memory managers, contributors to the Zap compiler and runtime, and authors of the first-party `Zap.ARC` and `Zap.Arena` managers.

**Scope:** This document specifies the binary interface, build-time discovery protocol, and semantic contract that every Zap memory manager — first-party or third-party — must implement. The specification is normative: ambiguity in this document is a defect of this document, not a license for implementer choice.

---

## 1. Overview

A Zap memory manager is a Zig package that supplies the runtime allocation, deallocation, and (optionally) reference-counting, finalization, weak-reference, and other memory-related primitives that a Zap binary needs. Exactly one manager is selected per binary at build time via the project's `build.zap` manifest:

```
%Zap.Manifest{
  name: "my_app",
  memory: Zap.ARC,    # or Zap.Arena, or any third-party Zap struct
  ...
}
```

The compiler treats first-party (`Zap.ARC`, `Zap.Arena`) and third-party managers identically. There is no hardcoded knowledge of any specific manager in the Zig compiler sources. Manager resolution is fully data-driven via the `@memory_manager_source` attribute on the Zap struct.

### 1.1 The build pipeline at a glance

```
Zap.Manifest.memory: Zap.ARC
        |
        v
Resolve struct -> @memory_manager_source attribute
        |
        v
Generic Zig-fork primitive: compile <manager>.zig to <manager>.o
        |
        v
Parse .zapmem section from <manager>.o (ELF/Mach-O/COFF)
        |
        v
Validate ZapMemoryManagerMetaV1 (magic, abi_major, caps consistency)
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
Link <manager>.o into final Zap binary
```

### 1.2 First-party manager locations

| Manager       | Zap struct        | Zap source                         | Zig source                                  |
|---------------|-------------------|------------------------------------|---------------------------------------------|
| `Zap.ARC`     | `Zap.ARC`         | `lib/zap/memory/arc.zap`           | `src/runtime/memory/arc/manager.zig`        |
| `Zap.Arena`   | `Zap.Arena`       | `lib/zap/memory/arena.zap`         | `src/runtime/memory/arena/manager.zig`      |

Third-party managers may live anywhere on the filesystem; the `@memory_manager_source` attribute carries the path.

### 1.3 What this ABI does NOT cover

- **Per-process manager selection.** v1 ships a single manager per binary. The future BEAM-style `Process.spawn(memory: Zap.Arena)` model is reserved for v2.
- **Cross-manager object sharing.** Forbidden in v1 (see section 13).
- **Tracing garbage collection.** Reserved (see section 9); no v1 manager may implement it.
- **Region-based memory management.** Reserved; no v1 manager may implement it.
- **Finalizers, weak references.** Reserved; no v1 manager may implement them.

---

## 2. Versioning rules

### 2.1 ABI version

The ABI is identified by an `(abi_major, abi_minor)` pair, both `u16`.

- **Major version (`abi_major`)** changes when an incompatible change to the wire format or core vtable is made. The Zap compiler refuses to load a manager whose `abi_major` differs from its own. v1.0 has `abi_major = 1`.
- **Minor version (`abi_minor`)** changes when a backward-compatible change is made — for example, adding a new optional field to the end of a structure (using the `size` field convention; see 2.3). The Zap compiler accepts any manager whose `abi_minor` is less than or equal to its own.

### 2.2 Capability versioning

Each capability has its own independent version (a `u16` in the capability descriptor). The core ABI and a capability evolve separately. A v1.0 manager may implement `REFCOUNT_V2` if and only if the running compiler supports `REFCOUNT_V2`; otherwise the descriptor is ignored. Capability version comparison is exact: a compiler that expects `REFCOUNT_V1` does not accept `REFCOUNT_V2` (the compiler must call `get_capability_desc` with a specific `(id, version)` expectation in future ABIs; in v1 the version is implicit at `1`).

### 2.3 The `size` field convention

Every extensible structure (`ZapMemoryManagerMetaV1`, `ZapMemoryManagerCoreV1`, `ZapCapabilityDescV1`, and every capability vtable) carries an explicit `size` field. The size field gives the size in bytes of the struct as the manager understood it at compile time.

- A consumer that sees `size > sizeof(its known struct definition)` reads only the prefix it knows and ignores trailing bytes. This permits a manager built against `abi_minor = 1` (which adds new trailing fields) to be loaded by a compiler that only knows `abi_minor = 0`.
- A consumer that sees `size < sizeof(its known struct definition)` zero-fills the missing trailing bytes. The fields added in `abi_minor = 1` and later are *required* to have a sensible zero-meaning (typically "feature absent" or "default behavior").
- A consumer that sees `size = 0` rejects the structure as invalid.

This is the same forward-compatibility discipline used by Vulkan's `sType`/`pNext` chains and the Linux kernel's versioned ioctl structures.

---

## 3. The `.zapmem` metadata section

Every memory manager package emits a fixed-size metadata blob into a dedicated, named object-file section. The Zap compiler parses this section at build time using the Zig standard library's object-format readers (`std.elf`, `std.macho`, `std.coff`). No subprocess (`nm`, `objdump`) is required and no symbol-name encoding tricks are used.

### 3.1 Section name by object format

| Object format | Section name      | Notes                                                          |
|---------------|-------------------|----------------------------------------------------------------|
| ELF           | `.zapmem`         | `SHT_PROGBITS`, `SHF_ALLOC` (loaded into the image's address space at runtime — required so the section survives static linking). |
| Mach-O        | `__DATA,__zapmem` | Segment `__DATA`, section `__zapmem`. Section type `S_REGULAR`. |
| COFF (PE)     | `.zapmem`         | Characteristics: `IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ`. |

The compiler determines the target object format from the manager's compiled object file (`std.elf.Header`, `std.macho.Header`, or `std.coff.Header`). The same Zig source produces the correct section name for every platform via Zig's `linksection` attribute combined with target-conditional naming. The worked examples in sections 14 and 15 show the canonical pattern.

### 3.2 Emission

The manager package emits a single `ZapMemoryManagerMetaV1` value as an exported, statically-initialized, C-ABI-compatible constant placed in `.zapmem` via Zig's `linksection` attribute. The constant must have external linkage (the `export` keyword in Zig) so that the linker does not dead-strip it. The recommended name is `zap_memory_manager_meta`, but the compiler does not rely on the symbol name — it discovers the data purely by section content.

A manager package emits exactly one `ZapMemoryManagerMetaV1` into the `.zapmem` section. Emitting zero or more than one is a manager defect; the compiler rejects such managers with a build-time error.

### 3.3 Discovery

The Zap compiler, after compiling the manager's Zig source to an object file, performs the following discovery steps:

1. Open the object file. Detect the object format from its magic bytes (`\x7fELF` for ELF, `0xFEEDFACE`/`0xFEEDFACF`/`0xCAFEBABE` for Mach-O, `MZ` for PE/COFF).
2. Locate the named section as listed in 3.1. Absence of the section is a build-time error.
3. Verify the section is at least `sizeof(ZapMemoryManagerMetaV1)` (32 bytes for v1.0; see appendix B). Smaller is a build-time error.
4. Read the first `sizeof(ZapMemoryManagerMetaV1)` bytes from the section as a `ZapMemoryManagerMetaV1` value (host endianness — the section is compiled for the same target as the final binary).
5. Validate the value per 3.5.

### 3.4 Endianness

All multi-byte integers in the `.zapmem` section and all ABI structures are stored in the **target's native byte order**. The manager and the Zap-generated code are always compiled for the same target; there is no cross-target loading. Big-endian targets store the `magic` value as `0x5A4D454D`; little-endian targets store it as `0x4D454D5A`. The Zap compiler determines target endianness from the object file and reads accordingly.

### 3.5 Validation rules

The Zap compiler rejects the manager with a clear build-time error if any of the following is true:

- `magic` does not equal the target-endianness-correct form of `'ZMEM'`.
- `abi_major` does not equal the compiler's known ABI major (`1` for this spec).
- `abi_minor` exceeds the compiler's known ABI minor *and* `size` does not include enough trailing zero-extension to make the missing-bytes interpretation safe. (In practice: the compiler accepts any `abi_minor` as long as it can read at least the prefix it understands.)
- `size < 32` (the v1.0 base size; the compiler refuses partial structures).
- `desc_count > 0` and the section is smaller than `size + desc_count * sizeof(ZapCapabilityDescV1)`.
- `declared_caps` references a reserved-but-unimplemented capability bit (e.g., `GCOL` in v1.0). Reserved bits are reserved precisely because no v1 manager may declare them.
- `reserved` is non-zero.

### 3.6 The metadata structure

```zig
/// The .zapmem section header. Exactly one of these per manager package.
/// All fields in target native byte order.
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

    /// Optional sanity-check marker for the source object format.
    /// 0 = unspecified; 1 = ELF; 2 = Mach-O; 3 = COFF.
    /// The compiler is not required to enforce this; it is a debug aid.
    object_fmt: u16,

    /// Bitmask of capability IDs this manager implements. See section 7
    /// for the canonical tag -> bit position mapping.
    declared_caps: u64,

    /// Number of ZapCapabilityDescV1 entries embedded immediately after
    /// this struct in the .zapmem section. If 0, descriptors are
    /// discovered exclusively at runtime via core.get_capability_desc.
    /// Embedding is recommended (faster validation, avoids the runtime
    /// load round-trip during compiler queries).
    desc_count: u32,

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

Embedded descriptors, if present, immediately follow the `ZapMemoryManagerMetaV1` value in the `.zapmem` section, each laid out as `ZapCapabilityDescV1` (section 6).

---

## 4. The core vtable: `ZapMemoryManagerCoreV1`

The core vtable is the always-present, mandatory interface for every manager. It is reachable via the manager's exported `zap_memory_manager_core` symbol, which is a `*const ZapMemoryManagerCoreV1`.

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

/// The mandatory core vtable. Every manager exports exactly one of these.
pub const ZapMemoryManagerCoreV1 = extern struct {
    /// ABI major version this vtable conforms to. Must equal the value
    /// in the .zapmem metadata.
    abi_major: u16,

    /// ABI minor version this vtable conforms to. Must equal the value
    /// in the .zapmem metadata.
    abi_minor: u16,

    /// Size in bytes of this struct as the manager understood it at
    /// build time. For v1.0 this is the value of @sizeOf(ZapMemoryManagerCoreV1)
    /// computed against this exact definition.
    size: u32,

    /// Bitmask of capability IDs. Must equal the value in the .zapmem
    /// metadata; the compiler enforces equality at build time.
    declared_caps: u64,

    /// Initialize the manager. Called exactly once, before any other
    /// function on the manager is called and before user-code main runs.
    /// Returns an opaque context pointer that is threaded through all
    /// subsequent calls. Returning null indicates initialization failure;
    /// the runtime aborts with a diagnostic.
    ///
    /// Thread-safety: called exactly once, on the main thread, before
    /// any user thread exists. No synchronization required.
    init: *const fn (options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque,

    /// Deinitialize the manager. Called exactly once, after user-code
    /// main returns (or the program aborts), and after all other user
    /// threads have joined. The manager must release all owned
    /// resources; the runtime makes no further calls afterward.
    ///
    /// Thread-safety: called exactly once, on the main thread.
    deinit: *const fn (ctx: *anyopaque) callconv(.c) void,

    /// Allocate `size` bytes with at least `alignment` byte alignment.
    /// `alignment` is always a power of two and at least
    /// `@alignOf(usize)`. On success returns a non-null pointer to at
    /// least `size` writable bytes. On failure returns null; the
    /// runtime treats null as a fatal out-of-memory condition.
    ///
    /// The manager may return memory whose first usable address is
    /// already aligned; it must not return memory whose alignment is
    /// less than requested.
    ///
    /// Thread-safety: may be called concurrently from any thread. The
    /// manager is responsible for any required synchronization.
    allocate: *const fn (
        ctx: *anyopaque,
        size: usize,
        alignment: u32,
    ) callconv(.c) ?[*]u8,

    /// Deallocate a previously allocated block. `ptr`, `size`, and
    /// `alignment` must exactly match the values from the call to
    /// `allocate` that produced this pointer (the runtime stores them
    /// alongside every allocation for managers that need them; managers
    /// that don't need them may ignore `size` and `alignment`).
    ///
    /// A manager that performs no individual deallocation (e.g., a
    /// pure arena) provides a no-op implementation; the runtime still
    /// calls it for every block to permit accounting in diagnostic
    /// wrappers.
    ///
    /// Thread-safety: may be called concurrently from any thread.
    deallocate: *const fn (
        ctx: *anyopaque,
        ptr: [*]u8,
        size: usize,
        alignment: u32,
    ) callconv(.c) void,

    /// Look up the descriptor for a specific capability. Returns null
    /// if the capability is not implemented by this manager. The
    /// returned pointer is valid for the lifetime of the manager
    /// context and is read-only.
    ///
    /// The runtime may call this at any time after init returns and
    /// before deinit is called. Result pointers are stable and may
    /// be cached.
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

### 4.1 Lifecycle

1. **Process start.** The Zap runtime invokes `core.init(null)` (or with init options for runtime-configurable managers; v1.0 always passes null). The runtime captures the returned context pointer.
2. **User code runs.** All allocations and deallocations from compiler-generated code, stdlib, and user code flow through `core.allocate` / `core.deallocate`. Capability vtables (e.g., `REFCOUNT_V1.retain` / `REFCOUNT_V1.release`) are called for capability-mediated operations.
3. **User code exits.** The runtime invokes `core.deinit(ctx)`. The manager releases all owned resources. After `deinit` returns, the runtime does not call any function on this manager again.

### 4.2 Thread safety

All managers shipped with v1.0 must be thread-safe — that is, `allocate`, `deallocate`, and `get_capability_desc` may be called concurrently from any thread. `init` and `deinit` are called exactly once each on the main thread, so they need not be reentrant.

Zig 0.16's `std.heap.ArenaAllocator` is lock-free; `Zap.Arena` may use it directly without additional synchronization.

### 4.3 Failure semantics

A null return from `allocate` is fatal: the runtime aborts with a diagnostic. v1 managers may not retry, swap heaps, or otherwise recover. Future ABI minor versions may add a `try_allocate` variant; v1.0 has only the abort-on-failure path.

A null return from `init` is fatal: the runtime aborts before user code runs.

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

    /// Size in bytes of the vtable pointed at by `vtable`. Permits
    /// non-breaking forward extension within a capability minor
    /// version. The compiler may refuse to load a manager whose
    /// descriptor `size` is smaller than the v1.0 baseline of the
    /// capability.
    size: u16,

    /// Capability-specific flags. The meaning of each bit is defined
    /// by the capability's own spec section. Unknown flag bits must
    /// be ignored by the compiler (forward-compatibility); unknown
    /// flag bits must not be set by a v1.0 manager.
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

1. **Embedded in the `.zapmem` section.** Each entry consumes 24 bytes after the `ZapMemoryManagerMetaV1` header. Embedding is recommended: it makes capability metadata available to the compiler at build time without requiring the manager to be initialized first.
2. **Runtime via `core.get_capability_desc(ctx, id)`.** The compiler-emitted runtime calls this to obtain the descriptor for a specific capability when emitting code that uses it. Implementations should return a pointer to a static-lifetime descriptor (typically the same descriptor that was embedded in `.zapmem`).

If a capability is declared in `declared_caps` but `get_capability_desc` returns null for that id, the manager is malformed and the runtime aborts. If a capability is NOT declared in `declared_caps`, `get_capability_desc` must return null for that id.

### 5.2 Vtable typing

The `vtable: *const anyopaque` is implicitly typed by the `(id, version)` pair. Each capability section in this spec gives the exact Zig type that `vtable` points at for that capability's version. Implementations cast the pointer when calling into the vtable.

### 5.3 Descriptor stability

The descriptor pointer returned by `get_capability_desc` and the vtable pointer it carries must remain valid and stable for the lifetime of the manager context. The runtime is permitted to cache them after the first lookup.

---

## 6. Capability descriptor flags

The `flags` field of `ZapCapabilityDescV1` is capability-specific. Generic bits reserved at the descriptor level (i.e., applicable across capabilities) are defined here; per-capability bits are defined in each capability's spec section.

### 6.1 Reserved generic flag bits

| Bit  | Mask          | Meaning                                                          |
|------|---------------|------------------------------------------------------------------|
| 0    | `0x0000_0001` | Reserved. Must be 0 in v1.0.                                     |
| 1    | `0x0000_0002` | Reserved. Must be 0 in v1.0.                                     |
| 2    | `0x0000_0004` | Reserved. Must be 0 in v1.0.                                     |
| 3    | `0x0000_0008` | Reserved. Must be 0 in v1.0.                                     |

Bits 4..31 are available for per-capability use. No capability in v1.0 defines any flag bit; managers must set `flags = 0` for every descriptor in v1.0.

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

### 7.2 Reserved-vs-defined

A "DEFINED" capability has a normative struct shape in this spec. A v1.0 manager may implement it freely.

A "RESERVED" capability has a reserved tag and bit position but no committed struct shape. A v1.0 manager **must not** set its bit in `declared_caps`. The compiler rejects managers that declare reserved bits.

### 7.3 Why a hand-curated table

A hash-mod-64 scheme would risk collisions as the namespace grows; sequential hand-curated assignment guarantees stability and makes the relationship between tag and bit position trivially inspectable. The table is small enough that hand-curation is not a maintenance burden.

---

## 8. `ZapRefcountCapabilityV1`

This is the only fully-defined capability in v1.0. A manager that supports atomic reference counting declares the `REFC` bit and exposes a `ZapRefcountCapabilityV1` vtable.

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
pub const ZapRefcountCapabilityV1 = extern struct {
    /// Increment the reference count of `object`. Must be atomic
    /// (relaxed ordering is sufficient for retain; the release fence
    /// is in `release`).
    ///
    /// Behavior is undefined if `object` was not produced by this
    /// manager's `allocate` (cross-manager retains are forbidden;
    /// see section 13).
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
    ///      the manager uses (typically `core.deallocate`).
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
};

comptime {
    if (@sizeOf(ZapRefcountCapabilityV1) != 16) @compileError(
        "ZapRefcountCapabilityV1 v1.0 must be exactly 16 bytes on a " ++
        "64-bit target with 8-byte function-pointer alignment",
    );
}
```

### 8.1 Object header expectations

The compiler-emitted layout for refcounted cells (under a manager that declares `REFCOUNT_V1`) includes an inline header carrying the refcount and a type tag. The exact layout is private to the compiler/runtime and may change between Zap releases; managers must treat the pointer passed to `retain` / `release` as opaque and may not inspect the cell's contents.

When a manager does NOT declare `REFCOUNT_V1`, the compiler omits the refcount header entirely from the cell layout. Object pointers in this configuration point directly at the first user field. This is the conditional-layout mechanism that makes Zap.Arena cell-overhead-free.

### 8.2 Deep-walk semantics

The compiler emits one deep-walk function per type that has refcounted children. The function's job is to call `release(ctx, child, child_deep_walk)` for every refcounted child of the given object. Walking is shallow per call: a Map's deep-walk releases its values (which may themselves trigger recursive deep-walks via their own per-type callbacks); the manager does not need to know about transitive ownership.

The manager is the sole authority on *when* to invoke `deep_walk`. The compiler emits `release` calls; the manager invokes `deep_walk` only at the moment of the final-count transition to zero. This means a manager that batches frees (e.g., a generational arena that frees an entire generation at once) is free to call `deep_walk` for each freed object in any order, or not at all if the manager's discipline makes the deep-walk unnecessary (an arena, for example, does not need deep-walks: the entire arena is freed in one operation and refcounting is elided at compile time).

### 8.3 Reentrancy

`deep_walk` may transitively call `release` on this manager. The manager must support arbitrary recursion depth — there is no maximum nesting — within the limits of available stack space. Managers that wish to avoid deep stacks may implement worklist-based release internally and trampoline through `deep_walk`.

### 8.4 No-op when capability absent

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
        The manifest's `memory:` field names a Zap struct
        (e.g., Zap.ARC, Zap.Arena, or any third-party struct).

Step 2. Resolve the struct reference to its source file.
        Read the struct's @memory_manager_source attribute, which
        contains a path to a Zig source file relative to either the
        Zap stdlib (for first-party managers) or the project root
        (for third-party managers).

Step 3. Compile the manager's Zig source to an object file.
        The compiler invokes a generic Zig-fork primitive:

            zig_fork_compile_zig_to_object(
                source_path: [*:0]const u8,
                target: *const Target,
                optimize: OptimizeMode,
                out_object_path: [*:0]const u8,
            ) c_int

        This primitive is general-purpose; it is not specific to
        memory managers. The result is an object file in the target
        platform's native format (ELF, Mach-O, or COFF).

Step 4. Parse the .zapmem section from the object file.
        The compiler uses std.elf, std.macho, or std.coff (depending
        on detected object format) to locate the .zapmem section
        and read its first sizeof(ZapMemoryManagerMetaV1) bytes
        plus any embedded ZapCapabilityDescV1 entries.

Step 5. Validate the metadata per section 3.5.
        Any validation failure aborts the build with a diagnostic
        identifying the manager package and the specific defect.

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

Step 8. Link the manager object alongside the Zap-generated objects.
        The final link step includes <manager>.o in its input set.
        The Zap-generated code references the manager via the
        manager's exported `zap_memory_manager_core` symbol.
```

### 10.2 Build cache integration

The compiled `<manager>.o` is content-addressed by `(zig_fork_version, manager_source_hash, target, optimize)`. The compiler caches compiled manager objects in the same on-disk cache as Zap-generated objects; the cache miss happens only on first build or when one of the cache keys changes.

### 10.3 Failure modes and diagnostics

| Failure                                  | Stage   | Diagnostic                                                                           |
|------------------------------------------|---------|--------------------------------------------------------------------------------------|
| Manager Zig source missing               | Step 2  | "memory manager source not found at `<path>` (from `@memory_manager_source` on `<struct>`)" |
| Manager Zig source fails to compile      | Step 3  | Forwarded Zig compiler error, prefixed with the manager package name.                |
| `.zapmem` section absent from object     | Step 4  | "manager `<name>` did not emit a `.zapmem` metadata section; see docs/memory-manager-abi.md section 3" |
| Magic mismatch                           | Step 5  | "manager `<name>` has invalid magic (expected `'ZMEM'`, got `<bytes>`)"               |
| `abi_major` mismatch                     | Step 5  | "manager `<name>` declares ABI major `<n>`, compiler supports ABI major `1`"          |
| Reserved capability bit declared         | Step 5  | "manager `<name>` declares reserved capability `<TAG>` (bit `<n>`), which has no committed v1.0 shape" |
| Embedded descriptor exceeds section size | Step 5  | "manager `<name>` declares `<n>` embedded descriptors but section is only `<bytes>` bytes" |

---

## 11. First-party / third-party symmetry

The Zap compiler has zero hardcoded knowledge of `Zap.ARC` or `Zap.Arena`. Both are resolved through exactly the same `@memory_manager_source` attribute mechanism as any third-party manager. There is no special-case code path, no name-based dispatch, no whitelist.

### 11.1 What a third party ships

A third-party manager is a Zig package containing:

1. A `<name>.zig` source file (path arbitrary, but typically `src/manager.zig`).
2. A `build.zig.zon` so the package can be referenced by Zap's dependency system.
3. A Zap struct declaration in `lib/<name>.zap` (or wherever the user wants) that points at the Zig source via `@memory_manager_source`.

The user then references the Zap struct from their project's `build.zap`:

```
%Zap.Manifest{
  memory: ThirdParty.MyManager,
  deps: [{:third_party_manager, {:path, "../third_party_manager"}}],
  ...
}
```

The Zap compiler resolves `ThirdParty.MyManager`, reads its `@memory_manager_source`, compiles the named Zig file, validates the resulting `.zapmem` metadata, and threads `declared_caps` into HIR and codegen — exactly as it does for `Zap.ARC`.

### 11.2 Versioning the third-party manager

The third party's package version is independent of Zap's ABI version. The third party declares the ABI version it builds against by setting `abi_major` / `abi_minor` in its emitted metadata. A v1.0-built third-party manager continues to work against any v1.x Zap compiler.

---

## 12. The Zap-side stdlib struct

For each memory manager, there is a Zap struct that names the manager and points at its Zig source. The struct itself is mostly metadata: it has no runtime fields. The compiler reads the `@memory_manager_source` attribute to find the Zig source file.

### 12.1 First-party `Zap.ARC`

```
@doc = """
  Atomic reference counting memory manager.

  Each refcounted cell carries an inline header storing the refcount
  and type tag. Retains and releases are atomic. When a release
  brings the count to zero, the runtime walks the cell's children
  and releases them before returning storage to the slab pool.

  Declared capabilities: REFCOUNT_V1.
  """

@memory_manager_source = "src/runtime/memory/arc/manager.zig"

pub struct Zap.ARC {
}
```

### 12.2 First-party `Zap.Arena`

```
@doc = """
  Whole-program arena memory manager.

  All allocations come from a single arena. Individual deallocations
  are no-ops; the entire arena is reclaimed at program exit. Because
  no per-cell refcount is tracked, the compiler omits the refcount
  header from Map, List, and String layouts, reducing per-cell
  overhead.

  Declared capabilities: none.
  """

@memory_manager_source = "src/runtime/memory/arena/manager.zig"

pub struct Zap.Arena {
}
```

### 12.3 The `@memory_manager_source` attribute

The attribute is a compile-time string literal. Its value is a path:

- **First-party managers**: path is relative to the Zap source tree root.
- **Third-party managers**: path is relative to the third-party package root (the directory containing the third party's `build.zig.zon`).

The compiler resolves the path against the package the struct is declared in; this gives first-party / third-party symmetry without ambiguity.

### 12.4 Pseudo-emptiness of the struct

The struct is intentionally empty. It exists purely as a typed reference for use in `Zap.Manifest.memory:` and to carry the `@memory_manager_source` attribute. Future ABI versions may add type-level methods to memory-manager structs (e.g., for per-process selection in v2), but v1.0 keeps them empty.

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

const ZapMemoryManagerMetaV1 = extern struct {
    magic: u32,
    abi_major: u16,
    abi_minor: u16,
    size: u16,
    object_fmt: u16,
    declared_caps: u64,
    desc_count: u32,
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

// FourCC 'ZMEM' as little-endian u32. Big-endian targets would use
// 0x5A4D454D; pick at comptime based on target endianness.
const ZMEM_MAGIC: u32 = switch (@import("builtin").target.cpu.arch.endian()) {
    .little => 0x4D454D5A,
    .big => 0x5A4D454D,
};

const SECTION_NAME = switch (@import("builtin").target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    else => @compileError("unsupported object format for .zapmem section"),
};

// The metadata blob. Placed in .zapmem by linksection.
export const zap_memory_manager_meta: ZapMemoryManagerMetaV1 linksection(SECTION_NAME) = .{
    .magic = ZMEM_MAGIC,
    .abi_major = 1,
    .abi_minor = 0,
    .size = @sizeOf(ZapMemoryManagerMetaV1),
    .object_fmt = 0,
    .declared_caps = 0,    // No capabilities declared.
    .desc_count = 0,
    .reserved = 0,
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

export const zap_memory_manager_core: ZapMemoryManagerCoreV1 = .{
    .abi_major = 1,
    .abi_minor = 0,
    .size = @sizeOf(ZapMemoryManagerCoreV1),
    .declared_caps = 0,
    .init = noopInit,
    .deinit = noopDeinit,
    .allocate = noopAllocate,
    .deallocate = noopDeallocate,
    .get_capability_desc = noopGetCapabilityDesc,
};
```

### 14.2 Zap source: `lib/zap/memory/noop.zap`

```
@doc = """
  No-op memory manager. Used only for compiler integration tests:
  allocation fails immediately, deallocation does nothing, no
  capabilities are declared.

  Programs built against this manager terminate as soon as they
  attempt to allocate. The purpose is to validate that the build
  pipeline accepts a minimal manager and that capability-elision
  removes all retain/release calls.
  """

@memory_manager_source = "src/runtime/memory/noop/manager.zig"

pub struct Zap.NoOp {
}
```

### 14.3 Expected behavior

A program built with `memory: Zap.NoOp`:

1. Compiles cleanly. The `.zapmem` section is present, magic matches, `declared_caps = 0`.
2. The compiler elides every retain/release in HIR (because `REFCOUNT_V1` is not declared).
3. Map/List/String types are emitted without the refcount-header field.
4. At runtime, `init` returns the placeholder pointer.
5. The first allocation returns null, the runtime aborts with an out-of-memory diagnostic.

---

## 15. Worked example: minimal refcounting manager

This example shows a small but complete refcounting manager. It uses `std.heap.page_allocator` for backing storage and a side table for refcounts (one atomic `u32` per allocation, keyed by allocation pointer). It declares `REFCOUNT_V1`.

### 15.1 Zig source: `tinyref/src/manager.zig`

```zig
const std = @import("std");
const builtin = @import("builtin");

const ZapMemoryManagerMetaV1 = extern struct {
    magic: u32,
    abi_major: u16,
    abi_minor: u16,
    size: u16,
    object_fmt: u16,
    declared_caps: u64,
    desc_count: u32,
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

// Per-allocation context: refcount stored adjacent to the user
// payload (allocation lays out [ refcount(4) | padding | user payload ]).
const HEADER_SIZE: usize = 16;    // 4 bytes refcount + 12 bytes padding
                                  // to keep user payload 16-byte aligned.

const Context = struct {
    // No per-context state; uses page_allocator directly. A real
    // manager would track allocations for diagnostics.
};

var context_storage: Context = .{};

fn tinyrefInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    return @ptrCast(&context_storage);
}

fn tinyrefDeinit(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
}

fn tinyrefAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    const total = HEADER_SIZE + size;
    const block = std.heap.page_allocator.alignedAlloc(
        u8,
        @intCast(@max(alignment, @as(u32, HEADER_SIZE))),
        total,
    ) catch return null;
    // Initialize refcount to 1.
    const refcount_ptr: *u32 = @ptrCast(@alignCast(block.ptr));
    refcount_ptr.* = 1;
    // Hand back a pointer past the header.
    return @ptrCast(&block.ptr[HEADER_SIZE]);
}

fn tinyrefDeallocate(
    ctx: *anyopaque,
    ptr: [*]u8,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    _ = ctx;
    _ = alignment;
    // Recover the block start by stepping back over the header.
    const block_start: [*]u8 = @ptrCast(&ptr[0]);
    const real_start = block_start - HEADER_SIZE;
    const total = HEADER_SIZE + size;
    std.heap.page_allocator.free(real_start[0..total]);
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
    const user_ptr: [*]u8 = @ptrCast(object);
    const refcount_ptr: *u32 = @ptrCast(@alignCast(user_ptr - HEADER_SIZE));
    _ = @atomicRmw(u32, refcount_ptr, .Add, 1, .monotonic);
}

fn tinyrefRelease(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?ZapDeepWalkFn,
) callconv(.c) void {
    const user_ptr: [*]u8 = @ptrCast(object);
    const refcount_ptr: *u32 = @ptrCast(@alignCast(user_ptr - HEADER_SIZE));
    const prev = @atomicRmw(u32, refcount_ptr, .Sub, 1, .acq_rel);
    if (prev == 1) {
        // The decrement that took us to zero. Walk children, then free.
        if (deep_walk) |walk| walk(object);
        // We don't know the original size or alignment here — a real
        // manager would store them in the header. For this minimal
        // example, deallocate uses the page allocator's size tracking.
        const ctx_typed: *Context = @ptrCast(@alignCast(ctx));
        _ = ctx_typed;
        // In practice, the runtime calls deallocate separately after
        // release returns; release is responsible only for the count
        // transition + deep-walk. The runtime's compiler-emitted
        // wrapper knows the cell's size and alignment.
        // Therefore we do nothing further here.
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

export const zap_memory_manager_meta: ZapMemoryManagerMetaV1
    linksection(SECTION_NAME) = .{
    .magic = ZMEM_MAGIC,
    .abi_major = 1,
    .abi_minor = 0,
    .size = @sizeOf(ZapMemoryManagerMetaV1),
    .object_fmt = 0,
    .declared_caps = CAP_REFCOUNT_V1_BIT,
    .desc_count = 0,
    .reserved = 0,
};

export const zap_memory_manager_core: ZapMemoryManagerCoreV1 = .{
    .abi_major = 1,
    .abi_minor = 0,
    .size = @sizeOf(ZapMemoryManagerCoreV1),
    .declared_caps = CAP_REFCOUNT_V1_BIT,
    .init = tinyrefInit,
    .deinit = tinyrefDeinit,
    .allocate = tinyrefAllocate,
    .deallocate = tinyrefDeallocate,
    .get_capability_desc = tinyrefGetCapabilityDesc,
};
```

### 15.2 Zap source: `lib/tinyref.zap`

```
@doc = """
  Minimal example refcounting manager. Backs allocations with the
  page allocator and stores a 32-bit atomic refcount in an inline
  header. Demonstrates the smallest manager that declares
  REFCOUNT_V1.
  """

@memory_manager_source = "src/manager.zig"

pub struct TinyRef {
}
```

### 15.3 Notes on the example

- The example uses a 16-byte inline header (4-byte refcount + 12 bytes padding) to keep user-payload alignment regardless of the host's pointer size. A production manager would size the header to match its target's natural alignment.
- The example uses `std.heap.page_allocator` directly. A production manager would use a slab pool (see `src/runtime/memory/arc/manager.zig`) to amortize syscall overhead.
- `release` does not call `deallocate` itself in this example; the runtime's compiler-emitted wrapper is responsible for that. A self-contained manager could call `deallocate` from `release` instead, at the cost of needing to know the cell's size and alignment (typically by stuffing them into the header).
- This entire example is under 200 lines and demonstrates: metadata section emission, capability declaration, capability descriptor, core vtable, refcount capability vtable, atomic refcount semantics, and deep-walk integration.

---

## 16. Diagnostic managers

Two non-user-facing managers ship with the Zap source tree as part of the test infrastructure:

| Manager           | Source                                            | Purpose                                              |
|-------------------|---------------------------------------------------|------------------------------------------------------|
| `Zap.Memory.Leak`     | `src/runtime/memory/leak/manager.zig`         | Allocates from the page allocator, never frees. Declares no capabilities. Used to verify that retain/release elision is complete under a non-refcounting manager. |
| `Zap.Memory.Tracking` | `src/runtime/memory/tracking/manager.zig`     | Wraps another manager and logs every allocate / deallocate / retain / release call. Used to detect missing or duplicated lifecycle events in compiler tests. |

These managers are not part of the public ABI surface in the sense that users do not select them via `memory:` in production builds. They are used by the Zap test runner to validate ABI-conformance properties (e.g., "every retain has a matching release") on every CI run. Their implementation follows the same ABI as `Zap.ARC` and `Zap.Arena`; no special compiler accommodation is needed.

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
fn bit_for_tag(tag: u32) ?u6 {
    // Sequential search of the canonical table. The table is small
    // enough that linear scan is faster than any hashing scheme.
    return switch (tag) {
        // Match against the tag in the target's endianness.
        // The compiler builds for a single target so this branch
        // resolves at comptime.
        TAG_REFC => 0,
        TAG_GCOL => 1,
        TAG_REGN => 2,
        TAG_STAT => 3,
        TAG_FNLZ => 4,
        TAG_WKRF => 5,
        TAG_ARSR => 6,
        TAG_ARTS => 7,
        TAG_SHHP => 8,
        TAG_TRAC => 9,
        else => null,
    };
}
```

The Zap compiler's metadata validator uses an equivalent lookup against the target-endianness-correct tag values.

---

## Appendix B. `.zapmem` byte layout

This appendix gives the exact byte layout of the `.zapmem` section, by offset, for a 64-bit target with 8-byte alignment. All multi-byte fields are stored in the target's native byte order (see section 3.4).

### B.1 `ZapMemoryManagerMetaV1` (32 bytes)

```
Offset  Size  Field           Notes
------  ----  --------------  --------------------------------------------
0x00    4     magic           'ZMEM' as u32 (target-endianness)
0x04    2     abi_major       1
0x06    2     abi_minor       0
0x08    2     size            32 in v1.0
0x0A    2     object_fmt      0..3 (0=unspecified)
0x0C    4     (padding)       Zero-filled; required by Zig's natural
                              alignment of the following u64 field
0x10    8     declared_caps   Bitmask, see Appendix A
0x18    4     desc_count      Number of embedded ZapCapabilityDescV1
0x1C    4     reserved        Must be 0
0x20    -     -               (end of struct; total 32 bytes)
```

### B.2 Embedded `ZapCapabilityDescV1` array (24 bytes per entry)

Starting at offset `0x20` (immediately after `ZapMemoryManagerMetaV1`), `desc_count` entries follow:

```
Entry offset relative to start of entry:
0x00    4     id              FourCC tag as u32 (target-endianness)
0x04    2     version         Per-capability version
0x06    2     size            sizeof(vtable struct)
0x08    4     flags           Capability-specific
0x0C    4     (padding)       Zero-filled; required for 8-byte align
0x10    8     vtable          Pointer to capability vtable
0x18    -     -               (end of entry; total 24 bytes)
```

### B.3 Total `.zapmem` section size

```
section_size = 32 + 24 * desc_count
```

If `desc_count = 0`, the section is exactly 32 bytes. If `desc_count = 1` (e.g., a refcounting-only manager that embeds its single descriptor), the section is 56 bytes.

### B.4 Alignment

The `.zapmem` section is aligned to 8 bytes (the natural alignment of `u64` and pointer). Zig's `linksection` attribute combined with the natural alignment of the exported struct produces correct alignment automatically; managers do not need explicit `@alignOf` annotations.

### B.5 Endianness summary

```
Little-endian targets (x86_64, aarch64, riscv64, wasm32, ...):
    magic = 0x4D454D5A     # bytes in memory: 5A 4D 45 4D

Big-endian targets (powerpc64be, s390x, ...):
    magic = 0x5A4D454D     # bytes in memory: 5A 4D 45 4D
```

The byte sequence `5A 4D 45 4D` is the same in both cases — the bytes spell `Z`, `M`, `E`, `M`. Only the interpretation as a `u32` differs. The Zap compiler reads the bytes as a `u32` in the target's native byte order and compares against the target-endianness-correct constant.

---

*End of Memory Manager ABI v1.0 specification.*
