@doc = """
`Custom.TrackingPool` — a custom (non-stdlib) memory manager adapter declaring
the INDIVIDUAL_NO_REFCOUNT reclamation model with the CLONE_ON_SHARE sharing
strategy.

The zero-method `impl Memory.Manager for Custom.TrackingPool {}` is the
conformance marker; the package-convention resolver binds its backend at
`src/custom_managers/tracking_pool/manager.zig`, whose `.zapmem` section
declares `declared_caps = 0x2` — byte-identical to `Memory.Tracking`. The
compiler reads those caps (never this name) and gives every program built with
this manager the identical Tracking codegen: refcount ops elided, no
`ArcHeader`, static free-at-last-use, and clone-on-share for persistent second
owners. The backend really frees each block individually and reports any
survivor at deinit, so the static-free codegen is observably leak-gated.
"""

pub struct Custom.TrackingPool {
}

pub impl Memory.Manager for Custom.TrackingPool {}
