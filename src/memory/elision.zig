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
/// `caps` carries the active manager's `declared_caps` value
/// (`docs/memory-manager-abi.md` section 7). Bit 0
/// (`REFCOUNT_V1_BIT`) is the only capability that affects this
/// decision in v1.x — REFCOUNT_V2 / future refcount minors will
/// expand the mask but keep the predicate name stable.
pub fn shouldEmitRefcountOps(caps: u64) bool {
    return (caps & abi.REFCOUNT_V1_BIT) != 0;
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
