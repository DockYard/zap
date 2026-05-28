@doc = """
`Custom.BulkArena` — a custom (non-stdlib) memory manager adapter declaring
the BULK_OR_NEVER reclamation model.

The zero-method `impl Memory.Manager for Custom.BulkArena {}` is the
conformance marker; the package-convention resolver binds its backend at
`src/custom_managers/bulk_arena/manager.zig`, whose `.zapmem` section declares
`declared_caps = 0x0` — byte-identical to `Memory.Arena`. The compiler reads
those caps (never this name) and gives every program built with this manager
the identical Arena elision: zero retain/release ZIR ops, no `ArcHeader`,
bulk-free at process exit.
"""

pub struct Custom.BulkArena {
}

pub impl Memory.Manager for Custom.BulkArena {}
