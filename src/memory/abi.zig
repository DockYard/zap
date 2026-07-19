//! Memory Manager ABI v1.x — canonical Zig source for shared extern types.
//!
//! This module is the single source of truth on the Zig side for the
//! `.zapmem` metadata structures defined in `docs/memory-manager-abi.md`
//! sections 3, 4, and 8. Both the section parser (`section_parser.zig`)
//! and any future Zig-side manager runtime should import these types
//! from here rather than redeclaring them locally.
//!
//! `runtime.zig` redeclares the same shapes — but for a different
//! reason: `runtime.zig` is `@embedFile`'d into the Zap compiler and
//! injected into every Zap user binary as a standalone source unit with
//! no sibling files (it can only import `std` and `builtin`). The
//! redeclaration there is unavoidable; the `comptime` size asserts in
//! both modules tripwire any accidental drift.
//!
//! Any field rename, reorder, or size change here must be accompanied by
//! a corresponding update to the spec doc, the matching runtime-side
//! shape in `src/runtime.zig` (search for `pub const AbiV1 = struct`),
//! and an ABI minor/major bump per spec section 2.3.
//!
//! ## Version history
//!
//! - `abi_major = 1`, `abi_minor = 0` (initial v1.0 release): `retain`
//!   and `release` only — `ZapRefcountCapabilityV1` is 16 bytes.
//! - `abi_major = 1`, `abi_minor = 1` (Phase 4.x extension): appends
//!   `retain_sized`, `release_sized`, `allocate_refcounted`, and
//!   `refcount_sized` to `ZapRefcountCapabilityV1`. Bytes 0..16 are
//!   layout-identical to v1.0 so a v1.0 consumer that reads only the
//!   first two slots (per the `size`-field forward-extension contract
//!   in spec §2.3) remains compatible.
//! - REFC descriptor tier **v1.2** (spec §8.6, concurrency P3-J5):
//!   appends `detach_region`, `adopt_region`, and `free_detached_region`
//!   to `ZapRefcountCapabilityV1` (the same-model O(1) region-move
//!   relocate extension), growing it from six to nine pointer slots
//!   (48→72 bytes on 64-bit). This is a §2.3 size-field forward
//!   extension of the REFC capability vtable, NOT a core/meta struct
//!   change: the tier is advertised through the REFC descriptor's
//!   `desc.size` (72), and the runtime gates the relocate path on
//!   `desc.size >= REFCOUNT_V1_SIZE_V1_2` — never on `abi_minor`. The
//!   first-party managers that ship it (ARC, ORC) therefore keep
//!   `abi_minor = 1` while advertising the 72-byte vtable. Bytes 0..48
//!   are layout-identical to v1.1.

const std = @import("std");
const builtin = @import("builtin");

/// `ZMEM` FourCC magic, read as a little-endian u32. The byte sequence
/// `5A 4D 45 4D` spells `Z`, `M`, `E`, `M` in either byte order; the
/// integer constant below is the little-endian interpretation.
pub const ZMEM_MAGIC_LE: u32 = 0x4D454D5A;

/// `REFC` capability tag (spec section 7.1) read at the target's native
/// endianness. The spec mandates that managers use `std.mem.readInt(u32,
/// "REFC", target_endianness)` rather than hand-computed hex literals so
/// the constant resolves correctly on either byte order.
pub const REFC_TAG: u32 = std.mem.readInt(u32, "REFC", builtin.target.cpu.arch.endian());

/// `REFCOUNT_V1` bit in `declared_caps` (spec section 7.1). Bit 0.
pub const REFCOUNT_V1_BIT: u64 = 0x0000_0000_0000_0001;

// ===========================================================================
// Capability axes in `declared_caps` (capability-driven memory model).
//
// `declared_caps` is a structured `u64`. Beyond the single `REFCOUNT_V1`
// capability flag (bit 0), the value encodes two orthogonal *axes* that the
// compiler reads — never the manager's name — to gate memory-op codegen:
//
//   bit  0      : REFCOUNT_V1 capability flag (the historical refcounted
//                 signal). Set iff the manager implements the refcount vtable.
//   bits 1..2   : Axis A — reclamation model (the FREE-MODEL selector, a
//                 2-bit field). Only consulted when bit 0 is clear; when bit 0
//                 is set the model is REFCOUNTED and this field MUST be the
//                 REFCOUNTED encoding (`0b00`).
//   bit  3      : Axis B — sharing strategy. Only meaningful when Axis A ==
//                 INDIVIDUAL_NO_REFCOUNT.
//   bits 4..63  : reserved (must be zero; rejected at build).
//
// ---------------------------------------------------------------------------
// Axis A — reclamation model (mutually exclusive). Four models:
//
//   | Model                  | bit 0 | bits 1..2 | declared_caps |
//   |------------------------|-------|-----------|---------------|
//   | REFCOUNTED             |   1   |   0b00    | 0x1           |
//   | BULK_OR_NEVER          |   0   |   0b00    | 0x0           |
//   | INDIVIDUAL_NO_REFCOUNT |   0   |   0b01    | 0x2           |
//   | TRACED                 |   0   |   0b10    | 0x4           |
//   | (reserved)             |   0   |   0b11    | 0x6           |
//
// REFCOUNTED is signalled by **bit 0** (the canonical refcount capability
// flag), with the Axis-A field held at its zero encoding (`0b00`). This is
// what keeps the model byte-compatible with the pre-axes ABI: `Memory.ARC`
// stays `declared_caps = 0x1` and every other v1.0 manager that declared
// `0x0` is, by construction, BULK_OR_NEVER (bit 0 clear, field `0b00`) — the
// strictly-conservative "elide all individual frees" model. The Axis-A field
// is therefore a *free-model* selector consulted only when bit 0 is clear; its
// `0b00` value means "bulk/never free" (the safe default for a non-refcounted
// manager). `reclamationModel`/`shouldEmitRefcountOps` in
// `src/memory/elision.zig` are the single source of truth for the decode and
// are proven to return numerically identical results to the pre-axes
// `(caps & REFCOUNT_V1_BIT) != 0` gate for every value a v1.0 manager could
// declare (see the elision unit tests).
//
// The `0b11` Axis-A code is reserved (no model assigned) and rejected at
// build by `driver.zig`'s axis-aware validation; it exists only so the 2-bit
// field has a defined forward-compatible "unknown model" slot.
//
// ---------------------------------------------------------------------------
// Axis B — sharing strategy (only when Axis A == INDIVIDUAL_NO_REFCOUNT):
//
//   | Strategy        | bit 3 | meaning                                      |
//   |-----------------|-------|----------------------------------------------|
//   | CLONE_ON_SHARE  |   0   | a persistent second owner gets a deep clone  |
//   | MOVE_ONLY       |   1   | sharing forbidden; ownership strictly moves  |
//
// Bit 3 set when Axis A != INDIVIDUAL_NO_REFCOUNT is an inconsistent combo
// and is rejected at build.
//
// ABI: this is a pure reinterpretation of bits inside the existing `u64`
// `declared_caps` field — no struct layout, offset, or fork C-ABI change.
// ===========================================================================

/// Bit position of the low bit of the Axis-A (reclamation-model) field within
/// `declared_caps`. The field is `RECLAMATION_MODEL_MASK` wide starting here.
pub const RECLAMATION_MODEL_SHIFT: u6 = 1;

/// Width mask (pre-shift) of the Axis-A reclamation-model field: 2 bits.
pub const RECLAMATION_MODEL_MASK: u64 = 0b11;

/// The Axis-A reclamation-model field, shifted into place within
/// `declared_caps` (bits 1..2). Used by validation to isolate the field.
pub const RECLAMATION_MODEL_FIELD_MASK: u64 = RECLAMATION_MODEL_MASK << RECLAMATION_MODEL_SHIFT;

/// Axis-A encoding (pre-shift, 2-bit) — REFCOUNTED. Carried by `Memory.ARC`
/// together with `REFCOUNT_V1_BIT`. Numerically `0b00`, so an ARC manager's
/// `declared_caps` is `REFCOUNT_V1_BIT | (RECLAMATION_REFCOUNTED << SHIFT)`
/// `== 0x1` (byte-identical to the pre-axes ABI).
pub const RECLAMATION_REFCOUNTED: u64 = 0b00;

/// Axis-A encoding (pre-shift, 2-bit) — BULK_OR_NEVER. Bulk free at program
/// exit (Arena) or never free (NoOp/Leak); individual frees are elided. This
/// is the field's zero value, so a non-refcounted manager declaring `0x0`
/// resolves to BULK_OR_NEVER.
pub const RECLAMATION_BULK_OR_NEVER: u64 = 0b00;

/// Axis-A encoding (pre-shift, 2-bit) — INDIVIDUAL_NO_REFCOUNT. Static
/// free-at-last-use, no refcount header (Tracking). Pairs with Axis B.
pub const RECLAMATION_INDIVIDUAL_NO_REFCOUNT: u64 = 0b01;

/// Axis-A encoding (pre-shift, 2-bit) — TRACED. Tracing GC reclaims; codegen
/// reuses the BULK_OR_NEVER elision (no retain/release/free, no header).
/// Declared by `Memory.GC` (the conservative stop-the-world mark-sweep
/// collector, `src/memory/gc/manager.zig`) and accepted at build (plan Phase 5
/// shipped). A fully-declared TRACED manager's `declared_caps` is
/// `RECLAMATION_TRACED << RECLAMATION_MODEL_SHIFT == 0x4`.
pub const RECLAMATION_TRACED: u64 = 0b10;

/// Axis-A encoding (pre-shift, 2-bit) — reserved/unknown model. No reclamation
/// model is assigned to `0b11`; the build rejects any manager declaring it.
pub const RECLAMATION_RESERVED: u64 = 0b11;

/// `declared_caps` value for a fully-declared BULK_OR_NEVER manager
/// (Arena/NoOp/Leak): bit 0 clear, Axis-A field `0b00`. Equals `0x0`.
pub const CAPS_BULK_OR_NEVER: u64 = RECLAMATION_BULK_OR_NEVER << RECLAMATION_MODEL_SHIFT;

/// `declared_caps` value for a fully-declared INDIVIDUAL_NO_REFCOUNT manager
/// with the default `CLONE_ON_SHARE` sharing strategy (Tracking). Equals `0x2`.
pub const CAPS_INDIVIDUAL_NO_REFCOUNT: u64 = RECLAMATION_INDIVIDUAL_NO_REFCOUNT << RECLAMATION_MODEL_SHIFT;

/// `declared_caps` value for a REFCOUNTED manager (`Memory.ARC`): the
/// REFCOUNT_V1 capability flag plus the REFCOUNTED Axis-A encoding. Equals
/// `0x1` — byte-identical to the pre-axes ABI so the host runtime default and
/// every ARC build are unchanged.
pub const CAPS_REFCOUNTED: u64 = REFCOUNT_V1_BIT | (RECLAMATION_REFCOUNTED << RECLAMATION_MODEL_SHIFT);

/// Axis-B sharing-strategy bit within `declared_caps` (bit 3). Clear =
/// `CLONE_ON_SHARE` (default), set = `MOVE_ONLY`. Only meaningful when Axis A
/// == INDIVIDUAL_NO_REFCOUNT.
pub const SHARING_MOVE_ONLY_BIT: u64 = 0x0000_0000_0000_0008;

/// Mask of every `declared_caps` bit that carries a defined meaning in the
/// capability model: the REFCOUNT_V1 flag (bit 0), the Axis-A field (bits
/// 1..2), and the Axis-B bit (bit 3). Any bit OUTSIDE this mask is reserved
/// and rejected at build. Bits 4..63 = `0xFFFF_FFFF_FFFF_FFF0`.
pub const KNOWN_CAPS_MASK: u64 =
    REFCOUNT_V1_BIT | RECLAMATION_MODEL_FIELD_MASK | SHARING_MOVE_ONLY_BIT;

comptime {
    // The defined axes must occupy bits 0..3 and nothing else.
    if (KNOWN_CAPS_MASK != 0x0000_0000_0000_000F) @compileError(
        "abi: KNOWN_CAPS_MASK must cover exactly bits 0..3 (REFCOUNT_V1 | Axis-A field | Axis-B)",
    );
    if (RECLAMATION_MODEL_FIELD_MASK != 0x6) @compileError(
        "abi: RECLAMATION_MODEL_FIELD_MASK must be bits 1..2 (0x6)",
    );
    if (CAPS_REFCOUNTED != REFCOUNT_V1_BIT) @compileError(
        "abi: a REFCOUNTED manager's declared_caps must equal REFCOUNT_V1_BIT (0x1) to stay byte-identical to the pre-axes ABI",
    );
    if (CAPS_BULK_OR_NEVER != 0) @compileError(
        "abi: BULK_OR_NEVER must be the all-zero declared_caps value (0x0)",
    );
}

/// `.zapmem` metadata header. Spec section 3.5. The exact 32-byte
/// layout is normative for ABI v1.0; the `comptime` assertion below
/// guards against accidental drift.
pub const ZapMemoryManagerMetaV1 = extern struct {
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

comptime {
    if (@sizeOf(ZapMemoryManagerMetaV1) != 32) @compileError(
        "abi: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
    if (@offsetOf(ZapMemoryManagerMetaV1, "magic") != 0) @compileError(
        "abi: ZapMemoryManagerMetaV1.magic must be at offset 0",
    );
    if (@offsetOf(ZapMemoryManagerMetaV1, "abi_major") != 4) @compileError(
        "abi: ZapMemoryManagerMetaV1.abi_major must be at offset 4",
    );
    if (@offsetOf(ZapMemoryManagerMetaV1, "abi_minor") != 6) @compileError(
        "abi: ZapMemoryManagerMetaV1.abi_minor must be at offset 6",
    );
    if (@offsetOf(ZapMemoryManagerMetaV1, "size") != 8) @compileError(
        "abi: ZapMemoryManagerMetaV1.size must be at offset 8",
    );
    if (@offsetOf(ZapMemoryManagerMetaV1, "_reserved2") != 10) @compileError(
        "abi: ZapMemoryManagerMetaV1._reserved2 must be at offset 10",
    );
    if (@offsetOf(ZapMemoryManagerMetaV1, "desc_count") != 12) @compileError(
        "abi: ZapMemoryManagerMetaV1.desc_count must be at offset 12",
    );
    if (@offsetOf(ZapMemoryManagerMetaV1, "declared_caps") != 16) @compileError(
        "abi: ZapMemoryManagerMetaV1.declared_caps must be at offset 16",
    );
    if (@offsetOf(ZapMemoryManagerMetaV1, "core_vtable_offset") != 24) @compileError(
        "abi: ZapMemoryManagerMetaV1.core_vtable_offset must be at offset 24",
    );
    if (@offsetOf(ZapMemoryManagerMetaV1, "reserved") != 28) @compileError(
        "abi: ZapMemoryManagerMetaV1.reserved must be at offset 28",
    );
}

/// Options passed to the manager's `init` entry point. Spec section 4.1.
///
/// Unlike `ZapMemoryManagerMetaV1`, `ZapCapabilityDescV1`, and
/// `ZapMemoryManagerCoreV1` — which are versioned by structural layout
/// and grow new `*V2` siblings on minor bumps — `ZapInitOptions` evolves
/// in place via the leading `size` field. Callers pass `size = sizeof(<their
/// known options>)`; managers compiled against newer versions read up to
/// `size` bytes and ignore the trailer, and managers compiled against
/// older versions read up to `sizeof(<known options>)` bytes and ignore
/// the trailing fields the caller doesn't yet know about. The naming
/// drops the `V1` suffix to make this single-concept evolution explicit.
pub const ZapInitOptions = extern struct {
    size: u32,
    reserved: u32,
};

comptime {
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "abi: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
    if (@offsetOf(ZapInitOptions, "size") != 0) @compileError(
        "abi: ZapInitOptions.size must be at offset 0",
    );
    if (@offsetOf(ZapInitOptions, "reserved") != 4) @compileError(
        "abi: ZapInitOptions.reserved must be at offset 4",
    );
}

/// Capability descriptor record embedded in the manager's `.zapmem`
/// metadata block (after the meta header). Spec section 3.6.
pub const ZapCapabilityDescV1 = extern struct {
    id: u32,
    version: u16,
    size: u16,
    flags: u32,
    vtable: *const anyopaque,
};

/// Native pointer width in bytes. The vtable-bearing ABI structs carry
/// function/data pointers whose size and alignment are pointer-width
/// dependent, so their layout asserts below are expressed RELATIVE to
/// `PTR` rather than as 64-bit-only literals. On the 64-bit targets
/// (`PTR == 8`) every derived offset/size reduces to the original v1.0
/// constants (24/56/48), so the wire/runtime contract is byte-identical;
/// on wasm32 (`PTR == 4`) the in-memory vtable descriptors are correctly
/// smaller. The wire-format section payload (`ZapMemoryManagerMetaV1`,
/// all fixed-width integers) is pointer-INDEPENDENT and keeps its literal
/// 32-byte assert.
pub const PTR: usize = @sizeOf(*const anyopaque);

comptime {
    // id:u32(0) version:u16(4) size:u16(6) flags:u32(8) then the
    // pointer, aligned to `PTR`. The integer prefix is 12 bytes; the
    // pointer sits at the next `PTR`-aligned offset and the struct's
    // size is that offset plus one pointer.
    const desc_vtable_off = std.mem.alignForward(usize, 12, PTR);
    if (@sizeOf(ZapCapabilityDescV1) != desc_vtable_off + PTR) @compileError(
        "abi: ZapCapabilityDescV1 size must be its pointer offset plus one pointer width",
    );
    if (@offsetOf(ZapCapabilityDescV1, "id") != 0) @compileError(
        "abi: ZapCapabilityDescV1.id must be at offset 0",
    );
    if (@offsetOf(ZapCapabilityDescV1, "version") != 4) @compileError(
        "abi: ZapCapabilityDescV1.version must be at offset 4",
    );
    if (@offsetOf(ZapCapabilityDescV1, "size") != 6) @compileError(
        "abi: ZapCapabilityDescV1.size must be at offset 6",
    );
    if (@offsetOf(ZapCapabilityDescV1, "flags") != 8) @compileError(
        "abi: ZapCapabilityDescV1.flags must be at offset 8",
    );
    if (@offsetOf(ZapCapabilityDescV1, "vtable") != desc_vtable_off) @compileError(
        "abi: ZapCapabilityDescV1.vtable must follow the integer prefix at PTR alignment",
    );
}

/// Compiler-emitted deep-walk callback. When the refcount of an object
/// drops to zero, the manager's release function invokes this callback
/// (if non-null) to release the object's children. Spec section 8.
///
/// Calling convention is `callconv(.c)` so the callback pointer is
/// ABI-stable and can be stored in cell headers alongside type tags.
pub const ZapDeepWalkFn = *const fn (object: *anyopaque) callconv(.c) void;

/// Core capability vtable. Spec section 4.2.
///
/// Function-pointer fields are typed (rather than `*const anyopaque`)
/// so callers obtain compile-time argument and return-type checking at
/// every dispatch site. The `extern struct` layout still matches the
/// ABI: typed function pointers occupy the same 8 bytes as a raw
/// `*const anyopaque` on the supported 64-bit targets.
pub const ZapMemoryManagerCoreV1 = extern struct {
    abi_major: u16,
    abi_minor: u16,
    size: u32,
    declared_caps: u64,
    init: *const fn (options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque,
    deinit: *const fn (ctx: *anyopaque) callconv(.c) void,
    allocate: *const fn (ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8,
    deallocate: *const fn (ctx: *anyopaque, ptr: [*]u8, size: usize, alignment: u32) callconv(.c) void,
    get_capability_desc: *const fn (ctx: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1,
};

comptime {
    // Integer prefix is 16 bytes (abi_major:u16, abi_minor:u16,
    // size:u32, declared_caps:u64), then five function pointers each
    // `PTR` wide. On 64-bit (`PTR == 8`) this is the original 56-byte
    // layout with the pointers at 16/24/32/40/48.
    const core_ptr_base: usize = 16;
    // The `u64 declared_caps` gives the struct 8-byte alignment, so on
    // wasm32 (4-byte pointers) the five trailing pointers leave tail
    // padding to the next 8-byte boundary; account for it via
    // `alignForward`. On 64-bit this is exactly 56.
    if (@sizeOf(ZapMemoryManagerCoreV1) != std.mem.alignForward(usize, core_ptr_base + 5 * PTR, @alignOf(ZapMemoryManagerCoreV1))) @compileError(
        "abi: ZapMemoryManagerCoreV1 size must be its 16-byte prefix plus five pointers (aligned)",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "abi_major") != 0) @compileError(
        "abi: ZapMemoryManagerCoreV1.abi_major must be at offset 0",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "abi_minor") != 2) @compileError(
        "abi: ZapMemoryManagerCoreV1.abi_minor must be at offset 2",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "size") != 4) @compileError(
        "abi: ZapMemoryManagerCoreV1.size must be at offset 4",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "declared_caps") != 8) @compileError(
        "abi: ZapMemoryManagerCoreV1.declared_caps must be at offset 8",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "init") != core_ptr_base + 0 * PTR) @compileError(
        "abi: ZapMemoryManagerCoreV1.init must follow the 16-byte prefix",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != core_ptr_base + 1 * PTR) @compileError(
        "abi: ZapMemoryManagerCoreV1.deinit must be the second pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != core_ptr_base + 2 * PTR) @compileError(
        "abi: ZapMemoryManagerCoreV1.allocate must be the third pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != core_ptr_base + 3 * PTR) @compileError(
        "abi: ZapMemoryManagerCoreV1.deallocate must be the fourth pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != core_ptr_base + 4 * PTR) @compileError(
        "abi: ZapMemoryManagerCoreV1.get_capability_desc must be the fifth pointer slot",
    );
}

/// `REFCOUNT_V1` capability vtable. Spec section 8. Pointed at by a
/// `ZapCapabilityDescV1` whose `id == REFC_TAG` and `version == 1`.
///
/// The first two slots are the original v1.0 inline-header path:
/// `retain` increments the reference count, `release` decrements and,
/// on the zero-transition, invokes `deep_walk(object)` (if non-null)
/// before freeing the cell's storage. The manager owns the full
/// freeing path for refcounted cells — see spec section 8.2.
///
/// The trailing four slots are the Phase 4.x (ABI v1.1) extension for
/// generic `Arc(T)` cells whose storage lives in a side-table slab
/// pool rather than inline with the user payload:
///
///   * `retain_sized` / `release_sized` — locate the cell's slab from
///     a 64-KiB-aligned base mask, read the size class from the slab
///     header, and operate on a side-table refcount entry.
///   * `allocate_refcounted` — allocate a fresh side-table cell with
///     refcount initialised to 1.
///   * `refcount_sized` — read the side-table refcount (used by the
///     Perceus reuse path so a uniquely-owned cell can be reused in
///     place rather than freed and reallocated).
///
/// A v1.0 manager remains compatible: its descriptor advertises `size
/// = 16` and the runtime reads only the first two slots, dispatching
/// generic `Arc(T)` allocations through `core.allocate` instead. A
/// v1.1+ manager advertises `size = 48` (or larger if it appends
/// further trailing fields) and the runtime takes the fast path through
/// `allocate_refcounted` / `retain_sized` / `release_sized` / `refcount_sized`.
pub const ZapRefcountCapabilityV1 = extern struct {
    // v1.0 base (16 bytes, slots 0–1):
    retain: *const fn (ctx: *anyopaque, object: *anyopaque) callconv(.c) void,
    release: *const fn (ctx: *anyopaque, object: *anyopaque, deep_walk: ?ZapDeepWalkFn) callconv(.c) void,
    // v1.1 extension (32 additional bytes, slots 2–5; total 48 bytes):
    retain_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void,
    release_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32, deep_walk: ?ZapDeepWalkFn) callconv(.c) void,
    allocate_refcounted: *const fn (ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8,
    refcount_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32,
    // v1.2 relocate extension (24 additional bytes on 64-bit, slots 6–8; total
    // 72 bytes): the same-model O(1) region-move send (plan item 6.1, P3-J5).
    //
    //   * `detach_region` — detach a container buffer (a `core.allocate` block,
    //     e.g. a `List`/`String` backing) from the owning context so a same-model
    //     receiver can adopt it WITHOUT copying. Returns `true` when the buffer
    //     is relocatable (a standalone page-backed block re-parented in O(1)),
    //     `false` when it is slab-interleaved and the caller must copy instead
    //     (the R4 degradation — the copy send stays for slab-backed graphs).
    //   * `adopt_region` — adopt a detached buffer into this context so this
    //     context's teardown and the buffer's eventual free reclaim it. The
    //     buffer's refcount is untouched (the mover proved rc == 1).
    //
    // A v1.1 manager advertises `desc.size == REFCOUNT_V1_SIZE_V1_1` and the
    // runtime falls back to the copy send (it never reads these slots); a v1.2+
    // manager advertises `desc.size >= REFCOUNT_V1_SIZE_V1_2`.
    detach_region: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) bool,
    adopt_region: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void,
    // `free_detached_region` — reclaim a detached-but-never-adopted buffer (an
    // undelivered move: dead-lettered, or a mailbox drained at receiver
    // teardown). Context-free and race-free (no tracking-list surgery; reads the
    // size/alignment from the block itself), so it is safe to call from any
    // thread with no current process quantum.
    free_detached_region: *const fn (object: *anyopaque) callconv(.c) void,
};

/// The legacy v1.0 byte length of `ZapRefcountCapabilityV1` — the first
/// two pointer slots (`retain`, `release`). A manager built against ABI
/// v1.0 advertises `desc.size == REFCOUNT_V1_SIZE_V1_0`; the runtime
/// accepts any `desc.size >= REFCOUNT_V1_SIZE_V1_0` per the size-field
/// forward-extension contract in spec §2.3. Pointer-width relative
/// (`2 * PTR`): 16 bytes on 64-bit targets, 8 on wasm32. The manager and
/// the runtime that compares this value are always compiled for the SAME
/// target, so the advertised size is internally consistent.
pub const REFCOUNT_V1_SIZE_V1_0: u16 = @intCast(2 * PTR);

/// The v1.1 byte length of `ZapRefcountCapabilityV1`, including the four
/// side-table extension slots (all six pointer slots). A v1.1+ manager
/// advertises `desc.size >= REFCOUNT_V1_SIZE_V1_1` so the runtime can
/// dispatch generic `Arc(T)` allocations through the sized API path.
/// Pointer-width relative (`6 * PTR`): 48 bytes on 64-bit, 24 on wasm32.
pub const REFCOUNT_V1_SIZE_V1_1: u16 = @intCast(6 * PTR);

/// The v1.2 byte length of `ZapRefcountCapabilityV1`, including the three
/// relocate-extension slots (`detach_region`, `adopt_region`,
/// `free_detached_region`) — all nine pointer slots. A v1.2+ manager
/// advertises `desc.size >= REFCOUNT_V1_SIZE_V1_2`
/// so the runtime can attempt the same-model O(1) region-move send; a manager
/// advertising less falls back to the copy send. Pointer-width relative
/// (`9 * PTR`): 72 bytes on 64-bit, 36 on wasm32.
pub const REFCOUNT_V1_SIZE_V1_2: u16 = @intCast(9 * PTR);

comptime {
    if (@sizeOf(ZapRefcountCapabilityV1) != 9 * PTR) @compileError(
        "abi: ZapRefcountCapabilityV1 (ABI v1.2) must be exactly nine pointer slots wide",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "retain") != 0 * PTR) @compileError(
        "abi: ZapRefcountCapabilityV1.retain must be the first pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "release") != 1 * PTR) @compileError(
        "abi: ZapRefcountCapabilityV1.release must be the second pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "retain_sized") != 2 * PTR) @compileError(
        "abi: ZapRefcountCapabilityV1.retain_sized must be the third pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "release_sized") != 3 * PTR) @compileError(
        "abi: ZapRefcountCapabilityV1.release_sized must be the fourth pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "allocate_refcounted") != 4 * PTR) @compileError(
        "abi: ZapRefcountCapabilityV1.allocate_refcounted must be the fifth pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "refcount_sized") != 5 * PTR) @compileError(
        "abi: ZapRefcountCapabilityV1.refcount_sized must be the sixth pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "detach_region") != 6 * PTR) @compileError(
        "abi: ZapRefcountCapabilityV1.detach_region must be the seventh pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "adopt_region") != 7 * PTR) @compileError(
        "abi: ZapRefcountCapabilityV1.adopt_region must be the eighth pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "free_detached_region") != 8 * PTR) @compileError(
        "abi: ZapRefcountCapabilityV1.free_detached_region must be the ninth pointer slot",
    );
    if (REFCOUNT_V1_SIZE_V1_1 != 6 * PTR) @compileError(
        "abi: REFCOUNT_V1_SIZE_V1_1 must remain the six-slot v1.1 length",
    );
    if (REFCOUNT_V1_SIZE_V1_2 != @sizeOf(ZapRefcountCapabilityV1)) @compileError(
        "abi: REFCOUNT_V1_SIZE_V1_2 must match the current ZapRefcountCapabilityV1 size",
    );
}

// ===========================================================================
// `ARSR` — arena watermark/reset capability (descriptor-only, spec §9).
//
// The bulk-reclamation entry points for BULK_OR_NEVER managers (plan item
// 6.4, P6-J4): the receive-back-edge arena auto-reset and any future scoped
// arena lifetime discover these through `core.get_capability_desc(ARSR_TAG)`.
// Descriptor-only per spec §7.2 (the `CYCL` precedent): the §7.1 bit stays
// RESERVED and `declared_caps` is untouched — no compiler codegen keys on the
// capability's presence (the emitted reset call dispatches at runtime through
// the process's manager binding, and a manager without the descriptor makes
// the call a no-op).
// ===========================================================================

/// `ARSR` capability tag (spec §9), read at the target's native endianness —
/// same discipline as `REFC_TAG` (never hand-compute the hex literal).
pub const ARSR_TAG: u32 = std.mem.readInt(u32, "ARSR", builtin.target.cpu.arch.endian());

/// A point-in-time position of a BULK_OR_NEVER manager's bulk set, captured
/// by `ZapArenaResetCapabilityV1.watermark` and consumed by
/// `reset_to_watermark`. OPAQUE to every consumer: the four fields are the
/// manager's private cursor state (for the first-party chunked bump arena:
/// the chunk-list head, the bump cursor, the chunk end, and the geometric
/// schedule cursor), and a consumer must never interpret or fabricate them —
/// only round-trip a value obtained from the SAME manager context. The struct
/// is `extern` so it can be embedded in kernel-side per-process state and
/// cross the C ABI by pointer.
pub const ZapArenaWatermarkV1 = extern struct {
    /// Manager-private position word 0 (chunked bump arena: the chunk-list
    /// head at capture; null when no chunk was mapped yet).
    chunk: ?*anyopaque,
    /// Manager-private position word 1 (bump cursor at capture).
    bump_cursor: usize,
    /// Manager-private position word 2 (current chunk end at capture).
    chunk_end: usize,
    /// Manager-private position word 3 (geometric schedule cursor at
    /// capture). Captured for completeness; the first-party arena's reset
    /// deliberately does NOT restore it — the growth schedule is sizing
    /// POLICY, not position (see `arenaResetToWatermark`).
    next_chunk_size: usize,
};

/// `ARSR` capability vtable (spec §9). Pointed at by a `ZapCapabilityDescV1`
/// whose `id == ARSR_TAG` and `version == 1`.
///
/// Contract (single-owner, like `core.allocate`): both entry points may only
/// be called by the context's one owning thread. `reset_to_watermark` frees —
/// in O(chunks-allocated-since) — EVERY allocation made through
/// `core.allocate` after the watermark was captured, and restores the
/// allocation cursor so subsequent allocations reuse the reclaimed address
/// space. Allocations made BEFORE the capture are untouched. The CALLER owns
/// the soundness proof that nothing allocated after the watermark is still
/// reachable — for the receive-back-edge auto-reset that proof is the
/// compiler's iteration-closure check (`src/receive_reset.zig`); a reset
/// without such a proof is a use-after-free.
pub const ZapArenaResetCapabilityV1 = extern struct {
    /// Capture the context's current bulk-set position into `out_watermark`.
    watermark: *const fn (ctx: *anyopaque, out_watermark: *ZapArenaWatermarkV1) callconv(.c) void,
    /// Free every allocation made after `watermark` was captured and restore
    /// the cursor to it. `watermark` MUST have been produced by `watermark`
    /// on this same `ctx`, and no allocation made after the capture may be
    /// live (caller-owned proof).
    reset_to_watermark: *const fn (ctx: *anyopaque, watermark: *const ZapArenaWatermarkV1) callconv(.c) void,
};

/// Byte length of the v1.0 `ZapArenaResetCapabilityV1` vtable — the value a
/// conforming descriptor advertises in `desc.size`.
pub const ARENA_RESET_V1_SIZE: u16 = @intCast(2 * PTR);

// ===========================================================================
// `STAT` — manager-side allocation statistics (descriptor-only, spec §10).
//
// The per-process heap-bytes observability seam (plan item 1.6 / P1-J5): the
// kernel's `ManagerVTable.heapByteCount` thunk resolves through this
// descriptor when the bound manager provides it, and reports 0 otherwise
// (the pre-P6-J4 behavior). Descriptor-only for the same §7.2 reasons as
// `ARSR`; the §7.1 `STAT` bit stays RESERVED.
// ===========================================================================

/// `STAT` capability tag (spec §10), read at the target's native endianness.
pub const STAT_TAG: u32 = std.mem.readInt(u32, "STAT", builtin.target.cpu.arch.endian());

/// `STAT` capability vtable (spec §10). Pointed at by a `ZapCapabilityDescV1`
/// whose `id == STAT_TAG` and `version == 1`.
pub const ZapStatsCapabilityV1 = extern struct {
    /// Bytes currently held by this context's heap, at manager-defined
    /// granularity (the first-party arena reports RESERVED chunk bytes —
    /// growth, which is what boundedness assertions need — not the bump
    /// cursor's consumed bytes). Unlike the single-owner allocation slots,
    /// this entry MUST be safe to call from any thread while the owner
    /// allocates (introspection snapshots read other processes' managers):
    /// implementations back it with a monotonic atomic counter.
    heap_byte_count: *const fn (ctx: *anyopaque) callconv(.c) usize,
};

/// Byte length of the v1.0 `ZapStatsCapabilityV1` vtable.
pub const STATS_V1_SIZE: u16 = @intCast(1 * PTR);

comptime {
    if (@sizeOf(ZapArenaResetCapabilityV1) != 2 * PTR) @compileError(
        "abi: ZapArenaResetCapabilityV1 must be exactly two pointer slots wide",
    );
    if (@offsetOf(ZapArenaResetCapabilityV1, "watermark") != 0 * PTR) @compileError(
        "abi: ZapArenaResetCapabilityV1.watermark must be the first pointer slot",
    );
    if (@offsetOf(ZapArenaResetCapabilityV1, "reset_to_watermark") != 1 * PTR) @compileError(
        "abi: ZapArenaResetCapabilityV1.reset_to_watermark must be the second pointer slot",
    );
    if (@sizeOf(ZapStatsCapabilityV1) != 1 * PTR) @compileError(
        "abi: ZapStatsCapabilityV1 must be exactly one pointer slot wide",
    );
    if (@sizeOf(ZapArenaWatermarkV1) != 4 * PTR) @compileError(
        "abi: ZapArenaWatermarkV1 must be exactly four pointer-width words",
    );
    if (ARENA_RESET_V1_SIZE != @sizeOf(ZapArenaResetCapabilityV1)) @compileError(
        "abi: ARENA_RESET_V1_SIZE must match the current ZapArenaResetCapabilityV1 size",
    );
    if (STATS_V1_SIZE != @sizeOf(ZapStatsCapabilityV1)) @compileError(
        "abi: STATS_V1_SIZE must match the current ZapStatsCapabilityV1 size",
    );
}

test "ZapMemoryManagerMetaV1 layout is exactly 32 bytes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ZapMemoryManagerMetaV1));
}

test "ZapInitOptions layout is exactly 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ZapInitOptions));
}

// These host tests pin the canonical 64-bit ABI layout (the host is a
// 64-bit target). The pointer-width-RELATIVE comptime asserts above (in
// terms of `PTR`) are what hold the layout correct on other widths such
// as wasm32; here we lock the 64-bit numbers explicitly so a refactor
// that accidentally changed the 64-bit layout still fails the test
// suite.
test "ZapCapabilityDescV1 layout is exactly 24 bytes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ZapCapabilityDescV1));
}

test "ZapMemoryManagerCoreV1 layout is exactly 56 bytes" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(ZapMemoryManagerCoreV1));
}

test "ZapRefcountCapabilityV1 layout is exactly 72 bytes (ABI v1.2)" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(ZapRefcountCapabilityV1));
}

test "ZapRefcountCapabilityV1 retain/release prefix matches v1.0 byte layout" {
    // The v1.1 extension is purely additive — the first 16 bytes must
    // remain bit-identical to v1.0 so a v1.0 manager binary (which only
    // emits the retain + release slots) is byte-compatible with a v1.1
    // consumer reading just the prefix.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ZapRefcountCapabilityV1, "retain"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ZapRefcountCapabilityV1, "release"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ZapRefcountCapabilityV1, "retain_sized"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(ZapRefcountCapabilityV1, "release_sized"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(ZapRefcountCapabilityV1, "allocate_refcounted"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(ZapRefcountCapabilityV1, "refcount_sized"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(ZapRefcountCapabilityV1, "detach_region"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(ZapRefcountCapabilityV1, "adopt_region"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(ZapRefcountCapabilityV1, "free_detached_region"));
}

test "REFCOUNT_V1 size constants" {
    try std.testing.expectEqual(@as(u16, 16), REFCOUNT_V1_SIZE_V1_0);
    try std.testing.expectEqual(@as(u16, 48), REFCOUNT_V1_SIZE_V1_1);
    try std.testing.expectEqual(@as(u16, 72), REFCOUNT_V1_SIZE_V1_2);
    try std.testing.expectEqual(@as(u16, @intCast(@sizeOf(ZapRefcountCapabilityV1))), REFCOUNT_V1_SIZE_V1_2);
}

test "ZMEM_MAGIC_LE is little-endian 'ZMEM'" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, ZMEM_MAGIC_LE, .little);
    try std.testing.expectEqualStrings("ZMEM", &buf);
}

test "REFC_TAG round-trips through native endian" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, REFC_TAG, builtin.target.cpu.arch.endian());
    try std.testing.expectEqualStrings("REFC", &buf);
}

test "ARSR_TAG and STAT_TAG round-trip through native endian" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, ARSR_TAG, builtin.target.cpu.arch.endian());
    try std.testing.expectEqualStrings("ARSR", &buf);
    std.mem.writeInt(u32, &buf, STAT_TAG, builtin.target.cpu.arch.endian());
    try std.testing.expectEqualStrings("STAT", &buf);
}

test "ARSR/STAT capability vtables lock their 64-bit layouts" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ZapArenaResetCapabilityV1));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ZapStatsCapabilityV1));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ZapArenaWatermarkV1));
    try std.testing.expectEqual(@as(u16, 16), ARENA_RESET_V1_SIZE);
    try std.testing.expectEqual(@as(u16, 8), STATS_V1_SIZE);
}

test "REFCOUNT_V1_BIT is bit 0" {
    try std.testing.expectEqual(@as(u64, 1), REFCOUNT_V1_BIT);
}

test "capability-axis bit assignments" {
    // Axis-A field occupies bits 1..2.
    try std.testing.expectEqual(@as(u6, 1), RECLAMATION_MODEL_SHIFT);
    try std.testing.expectEqual(@as(u64, 0b11), RECLAMATION_MODEL_MASK);
    try std.testing.expectEqual(@as(u64, 0x6), RECLAMATION_MODEL_FIELD_MASK);
    // Axis-B is bit 3.
    try std.testing.expectEqual(@as(u64, 0x8), SHARING_MOVE_ONLY_BIT);
    // The defined axes cover exactly bits 0..3.
    try std.testing.expectEqual(@as(u64, 0x0000_0000_0000_000F), KNOWN_CAPS_MASK);
}

test "capability-axis declared_caps values" {
    // REFCOUNTED is byte-identical to the pre-axes ABI (bit 0 only).
    try std.testing.expectEqual(@as(u64, 0x1), CAPS_REFCOUNTED);
    try std.testing.expectEqual(REFCOUNT_V1_BIT, CAPS_REFCOUNTED);
    // BULK_OR_NEVER is the all-zero value (Arena/NoOp/Leak).
    try std.testing.expectEqual(@as(u64, 0x0), CAPS_BULK_OR_NEVER);
    // INDIVIDUAL_NO_REFCOUNT with default CLONE_ON_SHARE (Tracking) is 0x2.
    try std.testing.expectEqual(@as(u64, 0x2), CAPS_INDIVIDUAL_NO_REFCOUNT);
    // The Axis-A field of each value decodes as expected.
    try std.testing.expectEqual(
        RECLAMATION_REFCOUNTED,
        (CAPS_REFCOUNTED >> RECLAMATION_MODEL_SHIFT) & RECLAMATION_MODEL_MASK,
    );
    try std.testing.expectEqual(
        RECLAMATION_INDIVIDUAL_NO_REFCOUNT,
        (CAPS_INDIVIDUAL_NO_REFCOUNT >> RECLAMATION_MODEL_SHIFT) & RECLAMATION_MODEL_MASK,
    );
}
