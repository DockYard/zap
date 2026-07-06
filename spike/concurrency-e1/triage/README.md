# E1 triage: residual `Io.Evented` (Dispatch) `spawn-serial` SIGSEGV — raw captures

Gap-resolution job G2 of the concurrency campaign (2026-07-05). Evidence
record for the intermittent crash documented in the †-note of the E1
post-fix section of `docs/concurrency-bench-results.md`. **Classification:
Dispatch-specific fiber-lifetime race in `lib/std/Io/Dispatch.zig`; not the
shared `lib/std/Io/fiber.zig` context-switch machinery; not libdispatch.**
Triage only — nothing was fixed.

## Protocol

- Machine/session: same host as E1/E9 (Apple M4, macOS 26.2), 1-min load
  ~3.0 at session start.
- Fork: `~/projects/zig` @ `6a425dbaeb` (both clobber fixes in), clean tree.
- Build: `~/projects/zig/zig-out/bin/zig build-exe --zig-lib-dir
  ~/projects/zig/lib -OReleaseFast ../bench.zig` (and once with
  `-OReleaseSafe`), built into a scratch dir.
- Each attempt ran foreground under
  `timeout 150 lldb --batch -o run -k "thread info" -k "bt all"
  -k "register read" -k "disassemble --pc --count 32" ...`
  (`-k` crash-commands, because lldb batch mode skips remaining `-o`
  commands after a crash — which is why `cap-00` is partial).

## Tally

| Invocation | Build | Attempts | Crashes | Captures |
|---|---|---:|---:|---|
| `evented spawn-serial 100000 5 1` | ReleaseFast | 7 | 6 | cap-00-partial, cap-01, cap-02, cap-04, cap-05, cap-06 (attempt 3 passed, no file) |
| `evented spawn-serial 100000 5 1` | ReleaseSafe | 4 | 0 | none — no crash and **no safety panic**; ReleaseSafe evidently perturbs the race timing, it does not classify it |
| `evented pingpong 100000 5 1` (control) | ReleaseFast | 3 | 0 | ctrl-pingpong-1 (RESULT: 735.7 / 722.8 ns) |
| `evented spawn 100000 5 1` windowed (control) | ReleaseFast | 1 | 0 | ctrl-spawn-windowed (RESULT: 22,295 / 17,982 ns) |

## Crash signatures (all on GCD worker threads, queue `org.ziglang.std.Io.Dispatch`)

1. **cap-00**: `EXC_BAD_ACCESS (code=1, address=0x104a8c008)` with pc inside
   `Io.fiber.contextSwitch` (fiber.zig:30) — load/store on **unmapped
   fiber-allocation memory** (Dispatch fiber allocations are single
   62,930,944-byte mmaps; `Fiber.destroy` munmaps them).
2. **cap-01/04/05**: wild jump, `pc=0, lr=0, fp=0`, every callee-saved
   register zeroed, `sp=0x108xxxba0` (fiber-stack-top region); x3/x5 still
   hold contextSwitch resume labels (`Dispatch.yield+124` /
   `Fiber.resume+124`) — execution resumed into **zero-filled, freshly
   re-mmapped fiber memory** (a munmapped region re-mapped by the next
   `Fiber.create` returns zero pages).
3. **cap-02/06**: `EXC_BAD_ACCESS (code=2)` — **execute fault jumping to a
   pthread-workqueue stack address** (`0x16fe87180` / `0x16ff13180`). Each
   of these two addresses also appears as a *data* register in the other
   capture (cap-02 x27 = 0x16ff13180; cap-06 x27 = 0x16fe87180), i.e. they
   are stable per-worker-thread pointers, consistent with the threadlocal
   `Thread.main_context` (wq-thread TLS sits at the top of the workqueue
   stack, and `yield`/`Fiber.resume` put `&thread.main_context` in every
   `SwitchMessage`). A `Context.pc` slot contained a pointer value —
   offset/type confusion through recycled `SwitchMessage`/`Context` memory
   on a freed fiber stack.

## The register-level smoking gun (cap-06)

At the instant of the crash, the awaiter thread (main fiber, running
`benchSpawnSerial`) is inside `Io.Dispatch.await` (Dispatch.zig:1114) →
`Fiber.destroy(fiber=0x0000000104a84000)` → `munmap`, while the **crashing
worker thread's x21 = 0x0000000104a84000 — the exact fiber being freed**.
cap-02 shows the complementary half: another worker concurrently inside
`Fiber.create` → `mmap(62930944)` recycling the address range while the
crash fires.

## Mechanism (triage-level candidate, not a verified root cause)

`AsyncClosure.call` (Dispatch.zig:1029–1031) publishes `Fiber.finished`
via `@atomicRmw(.Xchg, ...)` and only *afterwards* leaves the fiber's stack
via `ev.yield(.nothing)`. `await`'s fast path (Dispatch.zig:1111–1114) sees
`finished`, copies the result, and immediately `Fiber.destroy`s the 60 MB
allocation — while the finishing task can still be executing
`yield`/`contextSwitch` **on that fiber's stack** (and `mainLoop`,
Dispatch.zig:621, still reads the `SwitchMessage` that lives on it). The
slow path has the same shape: the task's `ev.queue.async(awaiter, resume)`
can run the awaiter before the task's final `yield` executes.

This predicts the observed distribution exactly: `spawn-serial` races
await against the just-finishing task every op (crashes); windowed `spawn`
(await distance 64) and `pingpong` (heavy contextSwitch volume through the
same shared asm + GCD glue, but zero per-op fiber create/destroy) never
crash.

## Why this exonerates `fiber.zig` and libdispatch

- `lib/std/Io/fiber.zig` is a 3-word `Context` plus a leaf asm block with
  no lifecycle logic; every fault consumed freed/recycled *data* owned and
  scheduled by Dispatch.zig. The same asm executed millions of times per
  control run (pingpong) without incident on the same binary/session.
- libdispatch frames appear only parked/idle (`semaphore_wait`,
  `workq_kernreturn`) in every capture; no crash inside libdispatch code.

**Phase 1 impact: not an entry blocker.** The bespoke scheduler builds on
`fiber.zig` only and owns its own fiber lifecycle; the lesson it must carry
is a design invariant, not a fix: a finished fiber's stack may not be
freed (or recycled) until the finishing fiber has provably left it — i.e.
completion publication must happen off-stack, or destruction must be
deferred through the scheduler.
