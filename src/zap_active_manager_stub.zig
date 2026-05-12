//! Stub registered as `zap_active_manager` when the build selects a
//! third-party memory manager. The runtime's `.third_party` comptime
//! branch never references symbols from this module; it routes through
//! the manager `.o`'s `.zapmem`-registered vtable instead. This stub
//! exists solely so the runtime's top-level
//! `@import("zap_active_manager")` resolves cleanly.
//!
//! ## Source-of-truth note
//!
//! The bytes of this file are `@embedFile`'d by `src/compiler.zig` as
//! `THIRD_PARTY_ACTIVE_MANAGER_STUB` (consumed by the user-binary
//! build via `getActiveManagerSourceBytes(.third_party)`) AND
//! registered as the `zap_active_manager` sibling module in
//! `build.zig` (consumed by the host test suite that loads
//! `runtime.zig` as a Zig module). Both consumers MUST point at this
//! same file — never duplicate the contents inline.

const std = @import("std");
