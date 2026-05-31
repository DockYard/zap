# Runtime OS-Portability — Implementation Plan

Status: **proposed, awaiting approval.** Branch `main`. This is **Phase 0 (design)** of an
approved campaign to make Zap's embedded runtime OS-portable. No runtime/compiler code changes
in this phase — this document is the foundation for the multi-phase implementation (tasks
#336/#337/#338 are the downstream cross-compile/port phases this design feeds).

## Principle (non-negotiable)

Zap's embedded runtime must compile **and run** on **everything Zig builds for**. The runtime is
**`@embedFile`'d into every Zap user binary** (`src/compiler.zig:14` → registered as the
`zap_runtime` struct source at `src/zir_backend.zig:630`), so any POSIX assumption in it is a
POSIX assumption in *every* Zap program. OS-specific behavior routes through a **comptime-selected
backend seam** (`runtime_os/{posix,windows,wasi}.zig`, dispatched by `builtin.os.tag` /
`builtin.object_format`), exposing only the primitives **std does not already abstract**. Where
std *does* have a per-OS backend (`std.fs.File`, `std.process`, `std.time`, `std.debug`,
`std.heap.page_allocator`), the runtime calls **std's portable API** rather than raw `std.c` /
`std.posix`. The seam carries a **capability model** so an OS that cannot support a domain (WASI
has no signals, no process spawn) **degrades cleanly at comptime** — it must never fail to compile
and never silently do the wrong thing.

This is consistent with CLAUDE.md: the runtime primitives that physically cannot be Zap (stdout,
signals, syscalls) are the legitimate Zig surface; `runtime_os` is exactly that surface, factored
so it is OS-portable. **No manager names, no Zap struct names** enter the seam — it is a
general-purpose OS-primitive layer, not Zap-domain logic.

## What ships in a user binary (the full port surface)

Two — and only two — Zig sources are compiled into every Zap user binary:

1. **`src/runtime.zig`** (22,333 lines) — registered as `zap_runtime` (`src/zir_backend.zig:630`)
   after three comptime-marker rewrites in `src/compiler.zig`
   (`getRuntimeSourceForRuntimeControls` → `rewriteRuntimeSource`, lines 10182–10300+): the
   `declared_caps` bitmask, the instrumentation flag, and the active-manager-source binding. This
   is **the** port surface.
2. **The selected memory-manager backend `.zig`** — registered as `zap_active_manager` *by file
   path* (`src/zir_backend.zig:646`, `options.active_manager_source_path`). One of
   `src/memory/{arc,arena,tracking,no_op,leak,gc}/manager.zig`, or a project-custom backend. These
   ship as a sibling compilation unit, so their OS surface is in scope too.

The managers are in **good shape already**: every production manager allocates through
`std.heap.page_allocator` (portable — `mmap` on POSIX, `NtAllocateVirtualMemory` on Windows;
documented at `src/memory/arc/manager.zig:567-577`, `arena/manager.zig:96-101`,
`leak/manager.zig:64-70`, `tracking/manager.zig:96-103`). `no_op` has **zero** OS coupling. The
**GC** backend (`src/memory/gc/manager.zig`) is the sole manager with deep OS coupling
(inline-asm register flush at :610-624, Mach-O `_mh_execute_header` / ELF self-info at :682-695,
`@frameAddress`-avoiding SP read) — but it is **already capability-gated** (`TRACED`, declared
caps `0x4`) and **already single-platform-v1** (darwin/aarch64 + linux/x86_64, with a documented
stack-only fallback on unsupported targets per the capability-memory-model plan Phase 5). The GC
manager's broader OS port is therefore **out of scope for this campaign** — it is its own
capability-gated subsystem with its own platform-matrix follow-up. This campaign ports
**`runtime.zig`** and confirms the **non-GC managers** already cross-compile (which task #336
verified for Windows COFF).

`src/memory/abi.zig` (the `.zapmem` layout) is `@embedFile`'d into the **compiler**
(`abi.zig:15`), not the user binary, so it is not part of the runtime port surface.

## The POSIX-surface inventory (by domain, file:line)

All line numbers are `src/runtime.zig` unless noted. Host-test-only code (inside `test { … }`
blocks — e.g. the `pipe`/`dup`/`dup2` stdin-redirect harness at :20890-20927) does **not** ship in
user binaries and is excluded from the port surface; it is noted where relevant.

### Domain A — console write (stdout / stderr)

The single hottest path: `IO.puts`/`println`/`inspect` and the `[zap-arc-stats]` diagnostic lines
all funnel through two helpers that call **raw `std.c.write(fd, …)`**.

| Site | What it does |
|---|---|
| `:34-36` | `STDOUT_FD`/`STDERR_FD`/`STDIN_FD` = `std.posix.STDOUT_FILENO` etc. (raw int fd constants) |
| `:44-51` `posixWrite(fd, bytes)` | the universal write primitive — `std.c.write(fd, ptr, len)` loop |
| `:85-95` `flushStdoutBuf` | 64 KiB buffered-stdout flush via `std.c.write(STDOUT_FD, …)` |
| `:125-144` `stdoutBufferedWrite`/`…Byte` | buffered-write entry; calls `posixWrite(STDOUT_FD, …)` |
| `:151-154` `stderrWriteFlushed` | flush stdout then `posixWrite(STDERR_FD, …)` |
| `:3257-3339` arc-stats | `[zap-arc-stats] …` lines → `posixWrite(STDERR_FD, …)` |
| `:9104-9369` crash report | the entire crash printer writes via `posixWrite(STDERR_FD, …)` (see Domain B) |

Roughly **40+ call sites** ultimately bottleneck on `posixWrite` + `std.c.write`. The fd-int
abstraction (`fd: std.posix.fd_t`) is the POSIX-ism: Windows has no small-int fds, WASI fds are
`u32` handles.

### Domain B — crash handling / backtrace / symbolization (the deep one)

Built in the error-system campaign. Three sub-layers, already **partially** comptime-gated:

| Site | What it does | OS-coupling |
|---|---|---|
| `:10740-10743` `zap_signal_handlers_supported` | **the existing comptime capability gate** (`have_segfault_handling_support and os.tag != .windows and cpu_context.Native != noreturn`) | already gates the whole subsystem |
| `:10837-10852` `installZapSignalHandlers` | `std.posix.sigaction(.SEGV/.BUS/.FPE/.ILL/.TRAP, …)` ×5 with `SA.SIGINFO\|RESETHAND\|ONSTACK` | POSIX signals — **no Windows/WASI equivalent** |
| `:10797-10827` `zapSignalHandler` | `SA_SIGINFO` handler: reads `std.posix.siginfo_t` + CPU context, captures backtrace, emits report, `_exit` | POSIX signal ABI |
| `:10751-10774` `zapSignalKind`/`Message` | maps `std.posix.SIG` enum → kind/message strings | POSIX `SIG` enum |
| `:8663-8668` `captureBacktraceFromContext` | `std.debug.captureCurrentStackTrace(.{.context=ctx}, out)` | **std-portable** (gated by `allow_stack_tracing`) |
| `:8678-8695` `symbolizeAddress` | `std.debug.SelfInfo.getSymbols` (the fork's DWARF reader) | **std-portable** (`SelfInfo == void` → degrade) |
| `:8721-8741` `symbolizeAddressInlineChain` | leak cold-path inline-frame symbolizer, same `SelfInfo` API | **std-portable** |
| `:9006-9030` `mainImageSlide` | ASLR slide: macos `std.c._dyld_get_image_vmaddr_slide(0)`, linux `std.c.dl_iterate_phdr` | **already comptime-switched** (`else => 0`) |
| `:9055` `zapCrashReporterInit` | `std.c.isatty(STDERR_FD)` for color decision | POSIX `isatty` |
| `:9123` `stripSymbolUnderscore` | `comptime builtin.object_format == .macho` underscore strip | already gated |
| `:8982-8993` `loadZapSymbols` | reads the `.zap-symbols` sidecar via **`std.process.executablePath` + `std.Io.Dir.readFile`** | **already std-portable** |
| `:10316-10333` `doubleFaultAbort` | `std.c._exit(ZAP_DOUBLE_FAULT_EXIT_CODE)` | POSIX `_exit` |

**Key insight:** the symbolization + sidecar layers are **already delegated to std** and already
degrade (`SelfInfo == void` → mangled names). The genuinely Zap-specific, genuinely non-portable
part is **only the signal-install + signal-handler entry** (Windows needs VEH; WASI has no signal
model at all). And it is **already comptime-gated** by `zap_signal_handlers_supported` — on an
unsupported target `installZapSignalHandlers` is a no-op and the default disposition stands.

### Domain C — file I/O (open / read / write / stat / unlink, AT-relative)

The `File` struct (`:17964-18046`) — `IO.File.read/write/exists/rm/mkdir/rmdir/rename/cp/is_dir/
is_regular`. **Every** method drops to raw `std.c` + `std.posix.toPosixPath`:

| Site | Raw call |
|---|---|
| `:17966` `File.read` | `toPosixPath` → `std.c.open(.RDONLY)` → `std.c.fstat(std.c.Stat)` → `std.posix.read` → `std.c.close` |
| `:17987` `File.write` | `toPosixPath` → `std.c.open(.WRONLY\|CREAT\|TRUNC, 0o644)` → `std.c.write` → `std.c.close` |
| `:18001` `exists` | `std.c.faccessat(std.posix.AT.FDCWD, …, F_OK, 0)` |
| `:18006` `rm` | `std.c.unlinkat(AT.FDCWD, …, 0)` |
| `:18011` `mkdir` | `std.c.mkdirat(AT.FDCWD, …, 0o755)` |
| `:18016` `rmdir` | `std.c.unlinkat(AT.FDCWD, …, AT_REMOVEDIR)` |
| `:18021` `rename` | `std.c.renameat(AT.FDCWD, …, AT.FDCWD, …)` |
| `:18033` `is_dir` | `std.c.fstatat(AT.FDCWD, …)` + `std.posix.S.IFMT/IFDIR` |
| `:18040` `is_regular` | `std.c.fstatat(AT.FDCWD, …)` + `S.IFMT/IFREG` |
| `:18356` `getcwd` | `std.c.getcwd(&buf, len)` |

Counts: **`toPosixPath` ×12**, **`AT.FDCWD`/`AT_*` ×7**, `std.c.Stat`/`fstat`/`fstatat` ×4. This is
the **largest single cheap-to-port** domain: `std.fs.Dir`/`std.fs.File` already abstract every one
of these per-OS.

### Domain D — stdin / console read / terminal (termios)

| Site | What it does |
|---|---|
| `:53-55` `posixRead` | `std.posix.read(fd, buf)` |
| `:186-272` `stdinRefill`/`loadLinuxCmdline` | buffered stdin refill via `std.posix.read`; `:258-264` `std.c.open`/`close` of `/proc/self/cmdline` |
| `:17814-17833` `try_get_char` | `std.posix.poll(std.c.pollfd{…}, 0)` non-blocking probe |
| `:362` + `:17773-17791` raw-mode | `original_termios: std.posix.termios`; `posix.tcgetattr`/`tcsetattr`, `ICANON`/`ECHO`/`V.MIN`/`V.TIME` |

Termios raw-mode is POSIX-only; Windows uses console-mode APIs; WASI has neither (no controlling
terminal) — degrade.

### Domain E — process / argv / exec

| Site | What it does | Note |
|---|---|---|
| `:301-319` `getArgv` | **already comptime-switched**: macos `_NSGetArgv`/`_NSGetArgc`, linux `/proc/self/cmdline`, **`else => &.{}`** | seam pattern already here |
| `:247-294` `loadLinuxCmdline` | parse `/proc/self/cmdline` into static cache | linux-specific arm of the above |
| `:3820-3822`, `:3924-3926`, `:8076-8078` | `getArgv()` consumers (binary name, manifest, builder env) | route through the abstraction above |
| (no `fork`/`exec`/`spawn` in `runtime.zig`) | — | the only `pipe`/`dup` is **host-test-only** (`:20890`) |

No process *spawn* in the runtime — the only "process" surface is **argv recovery**, already
seam-shaped.

### Domain F — time / clock / sleep

| Site | What it does |
|---|---|
| `:3497-3498` map-instrumentation timestamp | `std.c.clock_gettime(std.c.CLOCK.REALTIME, …)` |
| `:11886-11899` `sleep(ms)` | `std.posix.timespec` + `std.c.nanosleep` loop on `.INTR` |
| `:11956-11962` `Zest.nowNs` | `std.c.clock_gettime(CLOCK.REALTIME)` |
| `:11969-11978` `Zest.get_seed` | `std.c.clock_gettime(CLOCK.REALTIME)` for default seed |

All four are `std.c.*`; **`std.time`** (`std.time.nanoTimestamp`, `std.time.sleep`) abstracts every
one per-OS.

### Domain G — memory / mmap

| Site | What it does | Note |
|---|---|---|
| `:2137-2166` `mmapAlignedSlab`/`unmapSlab` | raw `std.posix.mmap`/`munmap` | **host-test-only** (`TestOnlyArcSlabPool`); production ARC uses `page_allocator.rawAlloc` |
| `:359` `runtime_arena` | `std.heap.ArenaAllocator.init(std.heap.c_allocator)` | **portable** (libc malloc; cross-platform) |
| `:2346/2369` test pool | `std.heap.page_allocator.rawAlloc/rawFree` | **portable** |

The runtime's **production** allocation is portable (`page_allocator` / `c_allocator`); the only
raw `mmap` is host-test scaffolding. **This domain is effectively already portable.**

### Domain H — entropy / random

| Site | What it does |
|---|---|
| `:13341-13353` `osEntropy` | **already comptime-switched**: linux `std.os.linux.getrandom`, **`else => return 0`** (DENSE_MAP hash seed) |

Already seam-shaped and degrading; `std.crypto.random` / `std.posix.getrandom` would generalize it.

### Domain I — process lifecycle (atexit / _exit)

| Site | What it does |
|---|---|
| `:110` | `extern "c" fn atexit(handler) c_int` (declared directly; `std.c.atexit` not public in 0.16) |
| `:112-116` `ensureStdoutAtexit` | lazy `atexit(stdoutAtexitFlush)` |
| `:3012` | `atexit(zapMemoryShutdownAtexit)` |
| `:3372` | `atexit(arcStatsAtexit)` |
| `:3515` | `atexit(mapInstrumentationAtexit)` |
| `:10333/10391/10436` | `std.c._exit(code)` (crash/double-fault abort) |

`atexit` is in the C standard library and is available on Windows (libc) and most WASI libcs, but
**WASI/wasm has no `_exit` with the POSIX shape** and atexit semantics differ — route through the
seam with a `proc_exit`/`abort` degrade.

### Domain summary

| Domain | Rough call-count | Cheap (→ std-portable) vs Deep (→ `runtime_os` backend) |
|---|---|---|
| A. console write | 40+ (via 2 helpers) | **mostly std-portable** (`std.fs.File.stdout()/stderr()`); fd-int seam for Windows handle |
| B. crash / backtrace / symbolization | ~20 | **symbolization already std-portable + degrading**; **signals = deep backend** (VEH / trap) |
| C. file I/O | ~25 (12× `toPosixPath`, 7× `AT_*`) | **all std-portable** (`std.fs.Dir`/`File`) |
| D. stdin / termios | ~8 | read = std-portable; **termios = backend** (or degrade) |
| E. process / argv | ~6 | **already seam-shaped** (`getArgv` comptime arms) |
| F. time / clock / sleep | 4 | **all std-portable** (`std.time`) |
| G. memory / mmap | 3 (prod) | **already portable** (`page_allocator`); test-only raw mmap |
| H. entropy | 1 | **already seam-shaped + degrading** |
| I. atexit / _exit | 8 | libc (Windows ok); **backend for WASI** `proc_exit` |

The headline: **the majority of the surface is "stop calling raw `std.c`/`std.posix`; call std's
portable API"** (Domains A, C, D-read, F, G — already portable). The genuinely Zap-specific,
genuinely OS-divergent work is **Domain B's signal layer** (POSIX sigaction vs Windows VEH vs WASI
nothing) plus small backend bits (termios, the console fd/handle, the WASI exit shape).

## The abstraction-seam design (`runtime_os`)

### Shape: one comptime-selected backend module, mirroring how std structures `std.posix`

```zig
// inside runtime.zig (the embedded source), near the top:
const runtime_os = @import("runtime_os/dispatch.zig");
//   dispatch.zig:  pub usingnamespace switch (builtin.os.tag) {
//                      .windows => @import("windows.zig"),
//                      .wasi    => @import("wasi.zig"),
//                      else     => @import("posix.zig"),   // linux, macos, *bsd, …
//                  };
```

**Embedding note (the one real mechanical wrinkle).** `runtime.zig` is `@embedFile`'d as a *single*
standalone source unit (it has no sibling files in the emission cache — see the comment at
`runtime.zig:21-32` explaining why it can't even `@import("env.zig")`). So `runtime_os` cannot be a
separate `@import`'d *file* the way it would be in a normal Zig project. **Decision: the seam is a
single comptime `switch` block emitted inline into the embedded runtime source**, structured as one
`RuntimeOs` namespace whose members are selected by `builtin.os.tag`. Concretely, the three backends
live as `src/runtime_os/{posix,windows,wasi}.zig` **in the compiler tree for review/testing**, and
the embedded-source assembly (`compiler.zig`'s `rewriteRuntimeSource`) **concatenates the
selected-or-all-three backend bodies into the emitted `zap_runtime` source** — exactly the same
mechanism that already rewrites `RUNTIME_DECLARED_CAPS_DEFAULT` and binds `zap_active_manager`.
This keeps the backends as real, separately-testable Zig files in `src/` while still shipping a
single self-contained runtime unit. (Alternative considered and rejected: registering each backend
as another sibling struct source like `zap_active_manager` — rejected because it multiplies the
emission/link surface for what is logically one module, and the rewrite-concatenation path already
exists and is proven.)

### Capability model

The seam exposes, per backend, a comptime capability struct so callers degrade at comptime:

```zig
pub const caps = struct {
    pub const supports_signals: bool   = …;  // posix:true  windows:true(VEH) wasi:false
    pub const supports_termios: bool   = …;  // posix:true  windows:false      wasi:false
    pub const supports_backtrace: bool = …;  // = (std.debug.SelfInfo != void) per target
    pub const supports_argv: bool      = …;  // posix(macos/linux):true windows:true wasi:true(args_get)
    pub const console_handle: type     = …;  // posix/wasi: fd int; windows: HANDLE
};
```

This generalizes the **four seam fragments that already exist** (`zap_signal_handlers_supported`,
the `getArgv` comptime arms, `mainImageSlide`'s switch, `osEntropy`'s switch) into one place.

### The interface (functions, signatures, routing)

Routing column legend: **std** = call std's portable API directly (no seam needed, just stop using
raw `std.c`); **seam** = goes through `runtime_os`.

| Function (seam or std) | Signature | posix | windows | wasi | Route |
|---|---|---|---|---|---|
| **console** | | | | | |
| `writeStdout(bytes)` | `([]const u8) void` | `write(1,…)` | `WriteFile(GetStdHandle(-11),…)` | `fd_write(1,…)` | **std** `std.fs.File.stdout().writeAll` *or* seam if buffering needs raw handle |
| `writeStderr(bytes)` | `([]const u8) void` | `write(2,…)` | `WriteFile(GetStdHandle(-12),…)` | `fd_write(2,…)` | **std**/seam |
| `stderrIsTty()` | `() bool` | `isatty(2)` | `GetConsoleMode` | `false` | **seam** (replaces `std.c.isatty` at :9055) |
| **file I/O** | | | | | |
| `readFileInto(path, buf)` | `([]const u8,[]u8) ?[]u8` | open/fstat/read | CreateFileW/ReadFile | path_open/fd_read | **std** `std.fs.cwd().readFile` |
| `writeFile(path, bytes)` | `([]const u8,[]const u8) bool` | open/write | CreateFileW/WriteFile | path_open/fd_write | **std** `std.fs.cwd().writeFile` |
| `pathExists/remove/mkdir/rmdir/rename/statKind/cwd` | per current `File.*` | `*at` syscalls | Win32 | preview1 path ops | **std** `std.fs.Dir.*` |
| **stdin** | | | | | |
| `readStdin(buf)` | `([]u8) usize` | `read(0,…)` | `ReadFile` | `fd_read(0,…)` | **std**/seam |
| `pollStdinReady()` | `() bool` | `poll` | `WaitForSingleObject` | `poll_oneoff` | **seam** (replaces :17823) |
| `enterRawMode()/exitRawMode()` | `() void` | termios | SetConsoleMode | no-op (degrade) | **seam** (`caps.supports_termios`) |
| **time** | | | | | |
| `nowNanos()` | `() u64` | clock_gettime | QueryPerformanceCounter/GetSystemTimeAsFileTime | clock_time_get | **std** `std.time.nanoTimestamp` |
| `sleepMillis(ms)` | `(u64) void` | nanosleep | Sleep | poll_oneoff timeout | **std** `std.time.sleep` |
| **process** | | | | | |
| `argv()` | `() []const [*:0]const u8` | `_NSGetArgv`/cmdline | `__wargv`/CommandLineToArgvW | `args_get` | **seam** (already the `getArgv` shape) |
| `exitProcess(code)` | `(u8) noreturn` | `_exit` | `ExitProcess` | `proc_exit` | **seam** (replaces `std.c._exit`) |
| `registerAtExit(fn)` | `(*const fn() callconv(.c) void) void` | `atexit` | `atexit` (libc) | `atexit`/manual | **seam** (replaces the bare `extern "c" atexit`) |
| **entropy** | | | | | |
| `osEntropy()` | `() u64` | getrandom/getentropy | RtlGenRandom | random_get | **std**/seam (already the `osEntropy` shape) |
| **crash (deep — Phase D)** | | | | | |
| `installCrashHandlers()` | `() void` | sigaction ×5 | AddVectoredExceptionHandler | no-op (degrade) | **seam** (`caps.supports_signals`) |
| `captureBacktrace(ctx)` / `symbolize(addr)` | as today | std.debug | RtlCaptureStackBackTrace + PE | trap (degrade) | **std** where `SelfInfo != void`; seam for capture-from-exception-context |

**The split, stated plainly:** Domains A, C, D-read, F, G, H route through **std's portable
APIs** (the fix is "stop calling raw `std.c`/`std.posix`"). The **seam** carries only what std does
*not* abstract uniformly: the TTY probe, stdin readiness poll, raw-mode, argv recovery, process
exit, atexit, and the **crash-handler signal/VEH install + capture-from-exception-context** (the
one deep Zap-specific primitive).

## Per-OS backend specifics

**posix.zig** (linux, macos, *bsd — the current behavior, refactored *in place*): exactly today's
calls, lifted behind the interface. `sigaction` ×5; `termios`; `_NSGetArgv`/`/proc/self/cmdline`;
`getrandom`/`getentropy`; `isatty`; `_exit`; `atexit`.

**windows.zig**: `WriteFile`/`GetStdHandle(STD_OUTPUT_HANDLE)` for console (handle, not fd — the
`console_handle` cap); `CreateFileW`/`ReadFile`/`GetFileAttributesW`/`MoveFileExW`/
`CreateDirectoryW`/`RemoveDirectoryW`/`DeleteFileW` for files (or `std.fs` which already does this);
**`AddVectoredExceptionHandler` (VEH)** for crash handling (translate `EXCEPTION_ACCESS_VIOLATION`/
`EXCEPTION_ILLEGAL_INSTRUCTION`/`EXCEPTION_INT_DIVIDE_BY_ZERO` → the same Zap kind atoms);
**`RtlCaptureStackBackTrace`** for the backtrace; PE/COFF self-info for symbolization (std's
`SelfInfo` already has a PDB/COFF path — prefer it, degrade to addresses if void);
`QueryPerformanceCounter`/`GetSystemTimeAsFileTime` for time (or `std.time`); `__wargv` /
`CommandLineToArgvW` for argv; `GetConsoleMode`/`SetConsoleMode` for TTY + raw-mode;
`ExitProcess`; libc `atexit`. (Task #336 already proved the *managers* compile for Windows COFF;
this is the runtime underneath them.)

**wasi.zig** (wasm32-wasi, preview1): `fd_write`/`fd_read`/`path_open` for console+file (or
`std.fs`/`std.Io` which target WASI); **NO signals** — `supports_signals = false`, so
`installCrashHandlers` is a comptime no-op and a fatal fault becomes `@trap`/`unreachable`/`abort`
(the crash *report* still renders for the recoverable-`raise`/`@panic` paths, which don't depend on
signals; only the hardware-fault interception is lost). **NO termios** (`supports_termios = false`
→ raw-mode no-op). **NO process spawn** (already absent). `clock_time_get` for time; `args_get`/
`args_sizes_get` for argv; `random_get` for entropy; `proc_exit` for exit. Most non-trivial domains
degrade with a clear comptime story, exactly as the principle requires.

## Phase breakdown (ordered by "what makes a runnable foreign binary soonest")

Each phase is independently verifiable; **native (darwin/aarch64 + linux/x86_64) stays green
throughout** (`zig build test` + `zap test` corpus). Verification **never** uses `zig build
zir-test` (the user runs that). "Foreign run" means: build the target, `file` the artifact to
confirm format, and run it where a runner exists (`wasmtime`/`wasm3` for wasi; `wine` or a Windows
box for PE — run-if-possible, else link+`file` is the bar).

### Phase A — seam skeleton + console write + std-portable migration (the "hello world abroad" phase)
**Goal:** a trivial `IO.puts("hello")` program **links and runs** as `wasm32-wasi` and links (runs
if a runner is available) as `x86_64-windows-gnu`.
- Introduce `src/runtime_os/{dispatch,posix,windows,wasi}.zig` + the `caps` struct; wire the
  rewrite-concatenation into `compiler.zig`.
- Route **Domain A** (console write) and the cheap std-portable domains that block a trivial
  program: **Domain F** (time — `std.time`), **Domain I** `exitProcess`/`atexit` through the seam,
  **Domain E** `argv` through the seam (generalize the existing `getArgv` arms).
- posix backend = byte-for-byte today's behavior (native must be unchanged).
- **Done =** native green; `IO.puts` program: `file` shows `WebAssembly (wasi)` and `wasmtime`
  prints `hello`; `file` shows `PE32+` for windows (run under wine if present).

### Phase B — file I/O (Domain C)
**Goal:** `IO.File.read`/`write`/`exists`/… work on a foreign binary.
- Replace the `File` struct's raw `std.c`/`toPosixPath`/`AT_*` calls with `std.fs.Dir`/`std.fs.File`
  (portable) — the cheapest, highest-line-count domain.
- Migrate Domain D-read stdin reads to std-portable; route `pollStdinReady`/raw-mode through the
  seam (`caps.supports_termios` → wasi/windows degrade for raw-mode).
- **Done =** native green (the full `File`/`IO` corpus); a file-roundtrip fixture runs under
  `wasmtime --dir=.`; links for windows.

### Phase C — time/entropy/atexit edges + misc (Domain F/H/I close-out)
**Goal:** every non-crash domain is portable; nothing left calling raw `std.c`/`std.posix` outside
the seam (except the deliberately host-test-only mmap pool).
- Finish Domain H (`osEntropy` via seam/`std.crypto.random`), Domain I atexit edge cases
  (WASI `proc_exit` shape), the `[zap-arc-stats]` and instrumentation write/timestamp paths.
- Add a CI grep-gate: no raw `std.c.`/`std.posix.` in `runtime.zig` outside `runtime_os` usage and
  `test{}` blocks.
- **Done =** native green; the grep-gate passes; the `Zest` timing path works on wasi (timeout
  fixtures).

### Phase D — crash handler (the deep domain; Domain B)
**Goal:** Windows gets a real crash report via VEH; WASI degrades cleanly (no compile error, trap
on fatal fault).
- **windows:** `AddVectoredExceptionHandler` translating exception codes → Zap kind atoms;
  `RtlCaptureStackBackTrace` for the address list; lean on std's `SelfInfo` PE/PDB path for
  symbolization, degrade to raw addresses if `SelfInfo == void`; the `.zap-symbols` sidecar reader
  is already std-portable (`executablePath` + `Io.Dir`).
- **wasi:** `caps.supports_signals = false` → `installCrashHandlers` is a comptime no-op; a fatal
  fault traps. The recoverable-`raise`/`@panic`/explicit-crash-report paths (which don't need
  signals) still render their report through the now-portable console write.
- Generalize `mainImageSlide` (already switched) and the `object_format` underscore-strip (already
  gated) into the seam for completeness.
- **Done =** native crash reports byte-identical (the error-system corpus); a windows
  divide-by-zero/segfault fixture produces a Zap-format report (run-if-possible); a wasi fixture
  with a deliberate fault traps cleanly and an explicit `@panic` still prints a report.

Phase ordering rationale: A delivers a *runnable* foreign binary fastest (console + exit + time +
argv are the minimum for "it runs"); B and C broaden the runnable surface with the
cheap-because-std-portable domains; D is last because it is the deep, OS-divergent one and is
**non-blocking for a runnable binary** (it is already comptime-gated to degrade, so a foreign
binary built after Phase A already *runs* — it just lacks rich crash reports until D).

## Decisions (defaults proposed; confirm before Phase A)

1. **std-portable-first.** Where std has a per-OS backend (`std.fs`, `std.time`, `std.process`,
   `std.debug`, `page_allocator`), call it directly and delete the raw `std.c`/`std.posix` call.
   The `runtime_os` seam carries **only** what std does not abstract uniformly (TTY probe, stdin
   poll, raw-mode, argv, exit, atexit, crash-signal/VEH install + capture-from-exception-context).
2. **Seam shape = inline comptime `switch` assembled by the existing source-rewrite path**, with
   the three backends living as real `src/runtime_os/*.zig` files for review/testing (concatenated
   into the embedded `zap_runtime` source by `compiler.zig`, mirroring the `declared_caps` /
   `zap_active_manager` rewrites). Not separate sibling struct-sources (rejected: multiplies
   emission/link surface for one logical module).
3. **Capability model = comptime `caps` booleans/types** (`supports_signals`, `supports_termios`,
   `supports_backtrace`, `console_handle`), generalizing the four seam fragments that already exist.
   An unsupported domain is a **comptime no-op / degrade**, never a compile error.
4. **WASI crash handling = trap/degrade.** No signal model on wasm; `supports_signals = false`;
   fatal faults trap; recoverable-`raise`/`@panic` reports still render. This is loss-of-rich-crash,
   not loss-of-correctness.
5. **GC manager OS port is out of scope.** It is its own capability-gated (`TRACED`) subsystem with
   its own single-platform-v1 + platform-matrix follow-up (capability-memory-model plan Phase 5).
   This campaign ports `runtime.zig` and relies on the non-GC managers already being portable
   (page_allocator/c_allocator), as task #336 verified for Windows COFF.
6. **Native is the regression anchor.** posix backend is byte-for-byte today's behavior; every
   phase keeps `zig build test` + `zap test` green on darwin/aarch64 + linux/x86_64.

## Risks

- **Domain B (crash/symbolization) is the deep one** (highest risk). The signal→VEH translation and
  capture-from-exception-context are genuinely OS-divergent. *Mitigation:* it is **already
  comptime-gated** and **already degrades**, and symbolization is **already delegated to std's
  `SelfInfo`** (which has Windows PE/PDB support and degrades to addresses). The new code is the VEH
  install + exception-code→kind mapping; everything downstream is reused. It is **last** and
  **non-blocking** for a runnable binary.
- **WASI's missing surface** (medium): no signals, no termios, no controlling terminal, exit/atexit
  differ. *Mitigation:* the capability model makes each absence a clean comptime degrade; most of
  the runnable surface (console/file/time/argv) maps to wasi preview1 directly via std.
- **The embedding wrinkle** (low-medium): `runtime.zig` ships as one standalone unit, so the seam is
  assembled by source-rewrite, not a normal `@import`. *Mitigation:* the rewrite path already exists
  and is proven (caps/instrument/manager-binding); the backends stay real testable files in `src/`.
- **Native regression** (low but unacceptable if it happens): posix backend must be byte-identical.
  *Mitigation:* posix.zig is a pure lift of today's calls; full native corpus gate every phase.
- **Windows console = handles not fds** (low): the `console_handle` cap abstracts the fd-int vs
  HANDLE difference; std's `std.fs.File.stdout()` already encapsulates it, so prefer std.
- **Fork-touch** (low): no Zig-fork ABI change is anticipated — the fork's `std.debug.SelfInfo` /
  `captureCurrentStackTrace` already carry the per-OS backends; if a Windows VEH gap surfaces in the
  fork's `cpu_context`, that is a fork fix (allowed per CLAUDE.md), tracked separately.

## Verification matrix (per phase)

| Target | Build | Format check | Run check |
|---|---|---|---|
| darwin/aarch64 (native) | `zig build test` + `zap test` corpus | — | full corpus green, **every phase** |
| linux/x86_64 (native) | `zig build test` + `zap test` | — | corpus green |
| x86_64-windows-gnu | cross-build a fixture | `file` → `PE32+` | run under wine/Windows if available (else link+`file`) |
| wasm32-wasi | cross-build a fixture | `file` → `WebAssembly … wasi` | `wasmtime`/`wasm3` runs the fixture |

**Never `zig build zir-test`** (the user runs it). Validate through the ZIR path (the only codegen
path), not generated-source strings.
