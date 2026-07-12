# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- BEAM-style concurrency runtime behind a compile-time gate
  (`runtime_concurrency: true` in `Zap.Manifest`, or
  `-Druntime-concurrency=on` on `zap build`/`zap run`/script mode). Gate-off
  binaries contain none of the runtime — no kernel object, no scheduler
  threads, no safepoint instructions — and are byte-identical to
  pre-concurrency output.
- Lightweight processes scheduled M:N over CPU cores:
  `Process.spawn`/`send`/`receive` with per-process mailboxes,
  `receive ... after` timeouts, and preemptive scheduling via
  compiler-emitted cooperative safepoints.
- Typed pids and message unions: `Pid(M)` handles make an ill-typed send a
  compile error at the send site; `receive` over a message union is
  exhaustiveness-checked, and unexpected dynamic messages dead-letter instead
  of crashing the program.
- Request/response and workers: `Process.call`/`Process.reply` typed
  synchronous calls and `Task.async`/`Task.await` one-shot monitored workers.
- Fault tolerance: links, monitors, `trap_exit`, `spawn_link`/`spawn_monitor`,
  named processes with send-by-name, and OTP-style supervisors
  (`Supervisor`) with restart strategies, restart intensity, and shutdown
  protocols — implemented in pure Zap.
- Per-spawn memory managers: every process owns its own heap, and each spawn
  site can choose its manager at compile time. The roster: `Memory.ARC`
  (default, atomic refcounting), `Memory.Arena` (bulk-freed, with automatic
  receive-loop reset and `Process.hibernate` for bounded servers),
  `Memory.ORC` (ARC plus a per-process Bacon–Rajan cycle collector),
  `Memory.GC` (conservative per-process mark-sweep), and
  `Memory.Tracking`/`Memory.NoOp`/`Memory.Leak` for diagnostics. The chosen
  reclamation model is monomorphized into spawn-reachable code, so hot
  allocation paths carry no per-allocation dispatch.
- O(1) large-payload message moves: `Process.send_move` transfers a large
  uniquely-owned flat `List`/`Map`'s backing region between process heaps in
  constant time (a 1 MB map round trip measures ~255 ns moved vs ~5.2 ms
  copied), degrading transparently to copy where a move is unsound.
- `Blob`: the sanctioned shared immutable byte tier — atomically refcounted,
  deeply immutable, shared by pointer across processes — with an atom-keyed
  global registry (`Blob.put_global`/`get_global`/`fetch_global`), copy-out
  slices, and loud generation-validated misuse panics. Sent strings at or
  above 64 KiB promote to the blob tier automatically (one copy, then ~42 ns
  flat re-sends).
- `Process.blocking`: the dirty-scheduler escape hatch — moves a blocking FFI
  or long CPU-bound call onto a dedicated blocking-pool thread so it cannot
  stall a scheduler core.
- Observability: `RuntimeInfo` process listing (state, mailbox depth, heap
  bytes), per-core scheduler utilization and run-queue depths, dead-letter
  telemetry, optional zero-cost-when-off message-flow tracing
  (`runtime_tracing: true` / `-Druntime-tracing=on`, ~10–15 ns per event when
  on), and built-in deadlock and starvation detectors
  (`ZAP_DEADLOCK_ACTION=stop|panic` opts into fail-fast).
- Platform capability gate for gate-on builds: aarch64/x86_64 on
  macOS and Linux. macOS on Apple Silicon is validated end-to-end; Linux is
  compile-validated (`x86_64-linux-gnu` kernel object + final link) with
  execution validation pending the Linux CI leg. Unsupported gate-on targets
  (wasm32, 32-bit ARM, riscv64, Windows) are rejected at compile time with an
  actionable diagnostic. Gate-off builds keep the full pre-existing
  cross-target matrix, including `wasm32-wasi` and `x86_64-windows-gnu`.
- New manifest fields `runtime_concurrency` and `runtime_tracing`, with
  matching CLI overrides `-Druntime-concurrency=on|off` and
  `-Druntime-tracing=on|off`.
- User-facing concurrency guide (`docs/guides/concurrency.md`) covering the
  runtime surface plus the FFI safety contract, the message-versioning
  posture, and the preemption-latency bounds; curated benchmark results
  published in-repo (`docs/benchmarks.md`, raw ledger
  `docs/concurrency-bench-results.md`).

### Changed

- `zig build` now fails with a hard configure error when the Zig fork's
  standard library cannot be found, naming the expected path and the explicit
  outs (`-Dzig-fork-root=...`, `-Dzig-lib-dir=...`). Previously it silently
  fell back to the building Zig's own stdlib, which could embed the wrong
  standard library into the compiler. `zig build setup` on a fresh checkout
  is unaffected.
- Exit-signal delivery under memory pressure now panics instead of silently
  dropping the signal (guaranteed-or-panic). A dropped exit/`DOWN` signal
  could previously leave supervisors and monitors waiting forever; a runtime
  that cannot deliver exit signals has lost supervision soundness.

### Fixed

- `Option(user-struct)` values miscompiled (or crashed the compiler) in
  gate-on builds; option specialization payloads are now importable across
  struct boundaries.

[Unreleased]: https://github.com/DockYard/zap/commits/main
