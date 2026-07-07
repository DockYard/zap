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
    /// Tracing garbage collection (`Memory.GC`). The manager reclaims via
    /// stop-the-world conservative mark-sweep collection; codegen reuses the
    /// `bulk_or_never` elision (no retain/release/free, no `ArcHeader`).
    /// Accepted at build — the conservative collector backend
    /// (`src/memory/gc/manager.zig`) has shipped (plan Phase 5).
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

/// Inverse of `reclamationModel`: the canonical `declared_caps` bitmask that
/// projects back to `model`. The per-spawn manager-monomorphization axis
/// (`src/monomorphize.zig`) keys a specialization on the reclamation *model*
/// (Axis A), never on manager identity — Arena/NoOp/Leak all share
/// `BULK_OR_NEVER`, so they share one specialization. When the ZIR builder
/// emits a model-tagged specialization it needs the caps value that model
/// implies so every elision predicate (`shouldEmitRefcountOps`,
/// `reclamationModel`, `sharingStrategy`, `cloneOnShareActive`) decodes to the
/// specialization's model rather than the binary-wide manifest manager's.
///
/// The mapping is the representative caps for each model:
///   - `refcounted`             → `CAPS_REFCOUNTED` (`0x1`, bit 0 set)
///   - `bulk_or_never`          → `CAPS_BULK_OR_NEVER` (`0x0`)
///   - `individual_no_refcount` → `CAPS_INDIVIDUAL_NO_REFCOUNT` (`0x2`,
///     Axis B defaulting to `CLONE_ON_SHARE` — the sole codegen-live sharing
///     strategy, since `MOVE_ONLY` is an upstream compile error)
///   - `traced`                 → `RECLAMATION_TRACED << SHIFT` (`0x4`)
///
/// The round-trip identity `reclamationModel(canonicalCaps(m)) == m` holds for
/// every model (proven exhaustively in the unit test below), which is what
/// makes the per-specialization decode sound.
pub fn canonicalCaps(model: ReclamationModel) u64 {
    return switch (model) {
        .refcounted => abi.CAPS_REFCOUNTED,
        .bulk_or_never => abi.CAPS_BULK_OR_NEVER,
        .individual_no_refcount => abi.CAPS_INDIVIDUAL_NO_REFCOUNT,
        .traced => abi.RECLAMATION_TRACED << abi.RECLAMATION_MODEL_SHIFT,
    };
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

test "canonicalCaps round-trips through reclamationModel for every model" {
    // The soundness obligation for the per-spawn monomorphization axis: a
    // model-tagged specialization emitted with `canonicalCaps(m)` must decode
    // back to model `m` in every elision predicate. Exhaustive over the 4
    // Axis-A models.
    const models = [_]ReclamationModel{
        .refcounted,
        .bulk_or_never,
        .individual_no_refcount,
        .traced,
    };
    for (models) |model| {
        try std.testing.expectEqual(model, reclamationModel(canonicalCaps(model)));
    }

    // The representative caps values match the ABI constants exactly.
    try std.testing.expectEqual(abi.CAPS_REFCOUNTED, canonicalCaps(.refcounted));
    try std.testing.expectEqual(abi.CAPS_BULK_OR_NEVER, canonicalCaps(.bulk_or_never));
    try std.testing.expectEqual(abi.CAPS_INDIVIDUAL_NO_REFCOUNT, canonicalCaps(.individual_no_refcount));
    try std.testing.expectEqual(@as(u64, 0x4), canonicalCaps(.traced));

    // `refcounted` is the only model for which `shouldEmitRefcountOps` holds —
    // exactly the hot/elide split the specialization axis is built to preserve.
    try std.testing.expect(shouldEmitRefcountOps(canonicalCaps(.refcounted)));
    try std.testing.expect(!shouldEmitRefcountOps(canonicalCaps(.bulk_or_never)));
    try std.testing.expect(!shouldEmitRefcountOps(canonicalCaps(.individual_no_refcount)));
    try std.testing.expect(!shouldEmitRefcountOps(canonicalCaps(.traced)));

    // Every canonical caps value is inside the known-caps mask (no reserved
    // bits leak into a specialization's declared caps).
    for (models) |model| {
        try std.testing.expectEqual(@as(u64, 0), canonicalCaps(model) & ~abi.KNOWN_CAPS_MASK);
    }
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

test "custom manager caps map identically to the matching stdlib manager (adapter-bounded)" {
    // The formal companion to the end-to-end custom-manager acceptance proof
    // (`script_fixtures/run_custom_manager_proof.sh` and the `zir-test`
    // integration tests). The codegen-projection functions are TOTAL pure
    // functions of `declared_caps`, so two managers declaring the same caps —
    // regardless of name — are indistinguishable to every codegen gate.
    //
    // `Custom.BulkArena` (test fixture) declares `declared_caps == 0x0`,
    // byte-identical to `Memory.Arena`. Therefore its reclamation model,
    // sharing strategy, and refcount-emission decision are identical to Arena's.
    const custom_bulk_caps: u64 = 0x0; // == Custom.BulkArena's `.zapmem` declared_caps
    try std.testing.expectEqual(reclamationModel(abi.CAPS_BULK_OR_NEVER), reclamationModel(custom_bulk_caps));
    try std.testing.expectEqual(sharingStrategy(abi.CAPS_BULK_OR_NEVER), sharingStrategy(custom_bulk_caps));
    try std.testing.expectEqual(shouldEmitRefcountOps(abi.CAPS_BULK_OR_NEVER), shouldEmitRefcountOps(custom_bulk_caps));
    try std.testing.expectEqual(ReclamationModel.bulk_or_never, reclamationModel(custom_bulk_caps));
    try std.testing.expect(!shouldEmitRefcountOps(custom_bulk_caps));

    // `Custom.TrackingPool` (test fixture) declares `declared_caps == 0x2`,
    // byte-identical to `Memory.Tracking`. Therefore its codegen contract is
    // identical to Tracking's: individual_no_refcount + clone_on_share, no
    // refcount ops.
    const custom_tracking_caps: u64 = 0x2; // == Custom.TrackingPool's `.zapmem` declared_caps
    try std.testing.expectEqual(reclamationModel(abi.CAPS_INDIVIDUAL_NO_REFCOUNT), reclamationModel(custom_tracking_caps));
    try std.testing.expectEqual(sharingStrategy(abi.CAPS_INDIVIDUAL_NO_REFCOUNT), sharingStrategy(custom_tracking_caps));
    try std.testing.expectEqual(shouldEmitRefcountOps(abi.CAPS_INDIVIDUAL_NO_REFCOUNT), shouldEmitRefcountOps(custom_tracking_caps));
    try std.testing.expectEqual(ReclamationModel.individual_no_refcount, reclamationModel(custom_tracking_caps));
    try std.testing.expectEqual(SharingStrategy.clone_on_share, sharingStrategy(custom_tracking_caps));
    try std.testing.expect(!shouldEmitRefcountOps(custom_tracking_caps));
}
