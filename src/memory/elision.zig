//! Phase 6 — Codegen elision predicate.
//!
//! Centralises the "should the compiler emit refcount ops?" decision so
//! every consumer (the ZIR builder's retain/release emission sites, the
//! IR-materialiser's ARC-op insertion, future layout-decision passes)
//! reads the same predicate. The active manager's `declared_caps`
//! bitmask is the single source of truth — set by the build driver
//! from the resolved manager's `.zapmem` core vtable
//! (`src/memory/driver.zig`), threaded through `CompileOptions`
//! (`src/zir_backend.zig`), and into the ZIR builder
//! (`src/zir_builder.zig:ZirDriver.declared_caps`).
//!
//! See `docs/memory-manager-abi.md` section 10 (build pipeline) and
//! section 8.5 (no-op when REFCOUNT_V1 absent) for the normative
//! contract.

const std = @import("std");
const abi = @import("abi.zig");

/// Axis A — the manager's reclamation model, decoded from `declared_caps`.
/// Mutually exclusive. This is the codegen-relevant projection of the
/// capability bits: every memory-op gating decision keys off this value (and,
/// for `individual_no_refcount`, off `sharingStrategy`), never off the
/// manager's name.
///
/// See `src/memory/abi.zig` ("Capability axes in `declared_caps`") for the
/// bit encoding.
pub const ReclamationModel = enum {
    /// Reference-counted (ARC). Retain/release dispatch, free-at-zero, inline
    /// `ArcHeader`. Signalled by `REFCOUNT_V1_BIT` (bit 0).
    refcounted,
    /// Bulk free at program exit (Arena) or never free (NoOp/Leak). Retain,
    /// release, and individual free are all elided; no `ArcHeader`.
    bulk_or_never,
    /// Individual free, no refcount (Tracking). Static free-at-last-use; the
    /// declared `sharingStrategy` resolves shared ownership; no `ArcHeader`.
    individual_no_refcount,
    /// Tracing garbage collection. The manager reclaims via collection;
    /// codegen reuses the `bulk_or_never` elision (no retain/release/free, no
    /// `ArcHeader`). Reserved-and-rejected at build until the GC manager ships.
    traced,
};

/// Axis B — the sharing strategy for an `individual_no_refcount` manager,
/// decoded from `declared_caps` bit 3. Only meaningful when
/// `reclamationModel(caps) == .individual_no_refcount`.
pub const SharingStrategy = enum {
    /// A persistent second owner receives an independent deep clone (the
    /// Tracking default). `declared_caps` bit 3 clear.
    clone_on_share,
    /// Sharing is forbidden; ownership strictly moves. `declared_caps` bit 3
    /// set. Relies on move-analysis completeness.
    move_only,
};

/// Decodes Axis A — the manager's reclamation model — from its
/// `declared_caps` bitmask. The single source of truth for the reclamation
/// projection.
///
/// Decode order is significant: `REFCOUNT_V1_BIT` (bit 0) is the canonical
/// refcounted signal and is checked first, so `refcounted` is returned iff
/// bit 0 is set — exactly the pre-axes `shouldEmitRefcountOps` predicate. When
/// bit 0 is clear, the Axis-A field (bits 1..2) selects the free model; its
/// zero value (`0b00`) is `bulk_or_never` (the conservative "elide all
/// individual frees" default), so a v1.0 manager that declared `0x0` resolves
/// to `bulk_or_never` and `shouldEmitRefcountOps` stays `false` for it.
///
/// The `0b11` Axis-A code carries no assigned model; `driver.zig`'s axis-aware
/// validation rejects any manager declaring it. This pure query maps it
/// conservatively to `bulk_or_never` (elide everything) so the function is
/// total for any `u64` input even though such a value can never reach codegen.
pub fn reclamationModel(caps: u64) ReclamationModel {
    if ((caps & abi.REFCOUNT_V1_BIT) != 0) return .refcounted;
    const field = (caps >> abi.RECLAMATION_MODEL_SHIFT) & abi.RECLAMATION_MODEL_MASK;
    return switch (field) {
        abi.RECLAMATION_BULK_OR_NEVER => .bulk_or_never,
        abi.RECLAMATION_INDIVIDUAL_NO_REFCOUNT => .individual_no_refcount,
        abi.RECLAMATION_TRACED => .traced,
        abi.RECLAMATION_RESERVED => .bulk_or_never,
        else => unreachable, // 2-bit field; the four arms above are exhaustive.
    };
}

/// Decodes Axis B — the sharing strategy — from `declared_caps` bit 3. The
/// value is only consulted by codegen when `reclamationModel(caps) ==
/// .individual_no_refcount`; for any other reclamation model the bit is
/// required to be clear (validated at build) and this returns the
/// `clone_on_share` default.
pub fn sharingStrategy(caps: u64) SharingStrategy {
    return if ((caps & abi.SHARING_MOVE_ONLY_BIT) != 0) .move_only else .clone_on_share;
}

/// Returns `true` when the compiler should emit refcount-aware
/// instructions (`retain` / `release` / `freeAny` / `prepareReleaseAny`,
/// inline `ArcHeader` field, side-table refcounts) for the given
/// manager capability bitmask.
///
/// When this returns `false` the compiler elides every retain/release
/// call site at IR materialization time, omits the inline `ArcHeader`
/// from `Map`/`List`/`MapIter` cell layouts, and routes `Arc(T)`
/// allocations through the manager's `core.allocate` instead of the
/// typed slab pool's side-table.
///
/// Defined as `reclamationModel(caps) == .refcounted`. Because
/// `reclamationModel` checks `REFCOUNT_V1_BIT` first, this is *numerically
/// identical* to the pre-axes predicate `(caps & REFCOUNT_V1_BIT) != 0` for
/// every `u64` — `refcounted` is returned iff bit 0 is set, and no other
/// reclamation model maps to `refcounted`. Phase 0 introduces the
/// reclamation/sharing axes with zero behavior change; the codegen consumers
/// (`zir_builder.zig`, `arc_materialize.zig`) still gate on this predicate.
pub fn shouldEmitRefcountOps(caps: u64) bool {
    return reclamationModel(caps) == .refcounted;
}

test "shouldEmitRefcountOps returns true under REFCOUNT_V1" {
    try std.testing.expect(shouldEmitRefcountOps(abi.REFCOUNT_V1_BIT));
    try std.testing.expect(shouldEmitRefcountOps(abi.REFCOUNT_V1_BIT | 0x1000));
}

test "shouldEmitRefcountOps returns false under no-cap manager" {
    try std.testing.expect(!shouldEmitRefcountOps(0));
    // Non-REFCOUNT capability bits set: the predicate still returns
    // false because v1.x only honours REFCOUNT_V1 in the elision
    // decision.
    try std.testing.expect(!shouldEmitRefcountOps(0x10));
}

test "shouldEmitRefcountOps is numerically identical to the pre-axes bit-0 gate" {
    // The proof obligation for the Phase-0 redefinition: for EVERY u64,
    // `reclamationModel(caps) == .refcounted` must equal the legacy
    // `(caps & REFCOUNT_V1_BIT) != 0`. Exhaustively check the entire
    // low-nibble cap space (every combination of the defined axis bits 0..3),
    // plus those values OR'd with arbitrary reserved high bits.
    var low: u64 = 0;
    while (low < 0x10) : (low += 1) {
        const legacy = (low & abi.REFCOUNT_V1_BIT) != 0;
        try std.testing.expectEqual(legacy, shouldEmitRefcountOps(low));
        // Reserved high bits must not perturb the decision.
        try std.testing.expectEqual(legacy, shouldEmitRefcountOps(low | 0x1000));
        try std.testing.expectEqual(legacy, shouldEmitRefcountOps(low | 0xFFFF_FFFF_FFFF_FFF0));
    }
}

test "reclamationModel decodes each defined model" {
    // REFCOUNTED — ARC (bit 0). Bits 1..2 are at the REFCOUNTED encoding.
    try std.testing.expectEqual(ReclamationModel.refcounted, reclamationModel(abi.CAPS_REFCOUNTED));
    try std.testing.expectEqual(ReclamationModel.refcounted, reclamationModel(abi.REFCOUNT_V1_BIT));
    // BULK_OR_NEVER — Arena/NoOp/Leak (all-zero).
    try std.testing.expectEqual(ReclamationModel.bulk_or_never, reclamationModel(abi.CAPS_BULK_OR_NEVER));
    try std.testing.expectEqual(ReclamationModel.bulk_or_never, reclamationModel(0));
    // INDIVIDUAL_NO_REFCOUNT — Tracking. Default CLONE_ON_SHARE, and with the
    // MOVE_ONLY sharing bit set the reclamation model is unchanged.
    try std.testing.expectEqual(
        ReclamationModel.individual_no_refcount,
        reclamationModel(abi.CAPS_INDIVIDUAL_NO_REFCOUNT),
    );
    try std.testing.expectEqual(
        ReclamationModel.individual_no_refcount,
        reclamationModel(abi.CAPS_INDIVIDUAL_NO_REFCOUNT | abi.SHARING_MOVE_ONLY_BIT),
    );
    // TRACED — reserved GC model.
    try std.testing.expectEqual(
        ReclamationModel.traced,
        reclamationModel(abi.RECLAMATION_TRACED << abi.RECLAMATION_MODEL_SHIFT),
    );
    // Reserved Axis-A code (0b11) maps conservatively to bulk_or_never.
    try std.testing.expectEqual(
        ReclamationModel.bulk_or_never,
        reclamationModel(abi.RECLAMATION_RESERVED << abi.RECLAMATION_MODEL_SHIFT),
    );
}

test "sharingStrategy decodes Axis B bit 3" {
    // Default is clone_on_share when the bit is clear.
    try std.testing.expectEqual(SharingStrategy.clone_on_share, sharingStrategy(0));
    try std.testing.expectEqual(
        SharingStrategy.clone_on_share,
        sharingStrategy(abi.CAPS_INDIVIDUAL_NO_REFCOUNT),
    );
    // move_only when bit 3 is set.
    try std.testing.expectEqual(SharingStrategy.move_only, sharingStrategy(abi.SHARING_MOVE_ONLY_BIT));
    try std.testing.expectEqual(
        SharingStrategy.move_only,
        sharingStrategy(abi.CAPS_INDIVIDUAL_NO_REFCOUNT | abi.SHARING_MOVE_ONLY_BIT),
    );
}
