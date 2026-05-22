# Per-optimize-mode overflow & bounds policy (Phase 1.5)

Zap's integer arithmetic and array/list indexing follow a
per-optimize-mode safety policy modeled on Zig's, with the trap path
routed to Zap's structured error abort.

## Arithmetic overflow

| Optimize mode  | Integer `+` `-` `*` on overflow                          |
| -------------- | -------------------------------------------------------- |
| `Debug`        | **Traps** → `** (arithmetic_error) integer overflow`, exit ≠ 0 |
| `ReleaseSafe`  | **Traps** → `** (arithmetic_error) integer overflow`, exit ≠ 0 |
| `ReleaseFast`  | **Wraps** (two's-complement), no trap                    |
| `ReleaseSmall` | **Wraps** (two's-complement), no trap                    |

The trap output shape is byte-for-byte identical to an explicit
`raise %ArithmeticError{}` (stdlib code `Z1003`) — see
`zap explain Z1003`. The safe modes never silently corrupt a value; the
fast modes wrap rather than invoke undefined behavior, matching Zig's
model while guaranteeing defined wrapping semantics.

Division-by-zero, exact-division remainder, and shift-amount overflow
follow the same safe-mode → `arithmetic_error` routing.

## Array / list bounds

| Optimize mode  | Index outside `0..length`                                |
| -------------- | -------------------------------------------------------- |
| `Debug`        | **Traps** → `** (index_error) index out of bounds`, exit ≠ 0 |
| `ReleaseSafe`  | **Traps** → `** (index_error) index out of bounds`, exit ≠ 0 |
| `ReleaseFast`  | Bounds check elided where the compiler proves safety; otherwise still checked |
| `ReleaseSmall` | Bounds check elided where the compiler proves safety; otherwise still checked |

The trap shape matches an explicit `raise %IndexError{...}` (stdlib code
`Z1004`) — see `zap explain Z1004`. Fast modes never introduce undefined
behavior beyond what Zig itself permits.

## How it is wired

1. **Tag selection** — `src/zir_builder.zig`'s `mapBinopTag` chooses the
   checked ZIR arithmetic tags (`add`/`sub`/`mul`) in safe modes and the
   wrapping tags (`addwrap`/`subwrap`/`mulwrap`) in fast modes, driven by
   `ZirDriver.arithmetic_overflow_traps`.
2. **Mode source of truth** —
   `frontend_policy.FrontendOptimizeMode.arithmeticOverflowTraps` (and the
   numeric mirror `zir_backend.arithmeticOverflowTrapsForMode`) decide the
   bool; the build pipeline forwards it through `buildAndInject` /
   `buildAndInjectSelected`.
3. **Trap routing** — the Zig fork's executable root stub
   (`zap_exe_stub_source` in `~/projects/zig/src/zir_api.zig`) defines the
   program's `panic` namespace. The `integerOverflow` / `shlOverflow` /
   `shrOverflow` / `divideByZero` handlers print
   `** (arithmetic_error) ...`; `outOfBounds` / `integerOutOfBounds` /
   `startGreaterThanEnd` print `** (index_error) ...`. Both exit non-zero
   via `std.c.exit(1)`, exactly mirroring `runtime.Kernel.raise_with_kind`.

No backtrace is captured on the trap path yet — that lands in Phase 2
alongside the structured crash printer.
