//! POSIX runtime-OS backend (`runtime_os` seam) — linux, macOS, and the
//! BSDs.
//!
//! This backend is the **native regression anchor** for the runtime
//! OS-portability campaign: every primitive here is a byte-for-byte lift
//! of the call `src/runtime.zig` made before the seam existed, so the
//! native (darwin/aarch64 + linux/x86_64) runtime behaves identically
//! whether the seam is present or not.
//!
//! ## Embedding contract
//!
//! `src/runtime.zig` ships into every Zap user binary as a single
//! standalone `@embedFile`'d source unit with no sibling files in the
//! emission cache (see the header comment in `runtime.zig`). It therefore
//! cannot `@import("runtime_os/posix.zig")`. Instead the compiler's
//! source-rewrite path (`src/compiler.zig`'s `rewriteRuntimeSource`)
//! splices the **body** of this backend — the text between the
//! `ZAP_RUNTIME_OS_BODY_BEGIN`/`END` sentinels — inline into the emitted
//! runtime as one arm of the comptime-selected `RuntimeOs` namespace.
//!
//! The body must therefore reference only names that are in scope inside
//! `runtime.zig` (`std`, `builtin`, and the seam-local helpers it
//! defines). It must not introduce top-level `@import`s, and every
//! declaration it needs that is not already in `runtime.zig` must be
//! declared inside the body itself.
//!
//! For standalone review and type-checking (`zig build test` compiles
//! this file as part of the runtime-os test aggregate), the file wraps
//! the body in `pub const Backend = struct { ... };` with the `std` and
//! `builtin` imports above it. The splice ignores everything outside the
//! sentinels.

const std = @import("std");
const builtin = @import("builtin");

pub const Backend = struct {
    // ZAP_RUNTIME_OS_BODY_BEGIN posix
    /// Capability model for the POSIX backend. POSIX has signals,
    /// termios, and small-integer file descriptors, and `std.debug`'s
    /// `SelfInfo` carries DWARF symbolization for the native targets.
    pub const caps = struct {
        /// POSIX delivers hardware faults as signals; the crash handler
        /// (Domain B, Phase D) installs `sigaction` handlers. Gated
        /// further at the `runtime.zig` call site by
        /// `zap_signal_handlers_supported`, which also requires the
        /// fork's `cpu_context.Native` to be a real type.
        pub const supports_signals: bool = true;

        /// POSIX terminals support raw mode through `termios`.
        pub const supports_termios: bool = true;

        /// DWARF symbolization is available when the fork's `SelfInfo`
        /// resolves to a real type for this target (it degrades to
        /// `void` on targets the fork cannot unwind).
        pub const supports_backtrace: bool = std.debug.SelfInfo != void;

        /// POSIX console primitives address files by small-integer
        /// descriptor (`std.posix.fd_t`).
        pub const console_handle: type = std.posix.fd_t;
    };

    /// The standard-stream descriptors. On POSIX these are the
    /// well-known small integers `0`, `1`, `2`.
    pub const stdout_handle: caps.console_handle = std.posix.STDOUT_FILENO;
    pub const stderr_handle: caps.console_handle = std.posix.STDERR_FILENO;
    pub const stdin_handle: caps.console_handle = std.posix.STDIN_FILENO;

    /// Write all of `bytes` to the console descriptor `handle`, looping
    /// over partial writes. A non-positive `write(2)` return (EOF or an
    /// unrecoverable error) ends the loop — identical to the previous
    /// `posixWrite` helper this lifts. Uses `std.c.write` because Zap
    /// binaries link libc unconditionally on POSIX targets.
    pub fn consoleWrite(handle: caps.console_handle, bytes: []const u8) void {
        var written: usize = 0;
        while (written < bytes.len) {
            const rc = std.c.write(handle, bytes[written..].ptr, bytes[written..].len);
            if (rc <= 0) break;
            written += @intCast(rc);
        }
    }

    /// Read up to `buf.len` bytes from the console descriptor `handle`.
    /// Returns the number of bytes read, or `0` on EOF/error. Lifts the
    /// previous `posixRead` helper.
    pub fn consoleRead(handle: caps.console_handle, buf: []u8) usize {
        return std.posix.read(handle, buf) catch 0;
    }

    /// Write all of `bytes` to stdout. Stream-targeted entry point used
    /// by the runtime so a raw descriptor/handle never escapes the seam.
    pub fn writeStdout(bytes: []const u8) void {
        consoleWrite(stdout_handle, bytes);
    }

    /// Write all of `bytes` to stderr.
    pub fn writeStderr(bytes: []const u8) void {
        consoleWrite(stderr_handle, bytes);
    }

    /// Read up to `buf.len` bytes from stdin; returns the count read.
    pub fn readStdin(buf: []u8) usize {
        return consoleRead(stdin_handle, buf);
    }

    /// Whether stderr is an interactive terminal (`isatty(2)`). Drives
    /// the crash reporter's color decision.
    pub fn stderrIsTty() bool {
        return std.c.isatty(stderr_handle) != 0;
    }

    /// Current wall-clock time in nanoseconds since the Unix epoch via
    /// `clock_gettime(CLOCK.REALTIME)` — a byte-for-byte lift of the
    /// runtime's previous direct call. The embedded runtime's bundled
    /// std does NOT carry `std.time.nanoTimestamp`, so the seam calls
    /// `std.c.clock_gettime` directly (the original mechanism). Clamped
    /// to non-negative and `u64` to match the prior helper.
    pub fn nowNanos() u64 {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const total_ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
        if (total_ns <= 0) return 0;
        return @intCast(total_ns);
    }

    /// Sleep for `nanoseconds` via `nanosleep`, retrying on `EINTR` — a
    /// byte-for-byte lift of the runtime's previous `nanosleep` loop
    /// (the bundled std has no `std.time.sleep`).
    pub fn sleepNanos(nanoseconds: u64) void {
        if (nanoseconds == 0) return;
        var ts = std.posix.timespec{
            .sec = @intCast(nanoseconds / 1_000_000_000),
            .nsec = @intCast(nanoseconds % 1_000_000_000),
        };
        while (true) {
            const rc = std.c.nanosleep(&ts, &ts);
            if (rc == 0) break;
            if (std.posix.errno(rc) != .INTR) break;
        }
    }

    /// Terminate the process with `code`, running no further user code
    /// in this thread. `std.process.exit` lowers to libc `exit` when
    /// libc is linked (the POSIX case for Zap), matching the prior
    /// behavior. NOTE: the crash-handler double-fault path keeps its own
    /// async-signal-safe `std.c._exit` (Domain B, Phase D) — this seam
    /// primitive is the *normal* exit path only.
    pub fn exitProcess(code: u8) noreturn {
        std.process.exit(code);
    }

    /// Register a C-ABI handler to run at normal process exit. Declares
    /// the libc `atexit` symbol directly because `std.c.atexit` is not
    /// part of the public `std.c` surface in 0.16; Zap binaries link
    /// libc unconditionally on POSIX. Returns 0 on success (matching
    /// libc `atexit`).
    pub fn registerAtExit(handler: *const fn () callconv(.c) void) c_int {
        const c = struct {
            extern "c" fn atexit(handler: *const fn () callconv(.c) void) c_int;
        };
        return c.atexit(handler);
    }

    /// Process argv. macOS recovers it via the `_NSGetArgv`/`_NSGetArgc`
    /// crt globals; linux parses `/proc/self/cmdline` (libc-independent,
    /// works for static/dynamic and musl/glibc) through the
    /// `loadLinuxCmdline` helper already present in `runtime.zig`. The
    /// remaining POSIX targets (the BSDs) have no uniform libc-free
    /// recovery, so they degrade to an empty slice — identical to the
    /// previous `getArgv` `else` arm.
    pub fn argv() []const [*:0]const u8 {
        if (comptime builtin.os.tag == .macos) {
            const c = struct {
                extern "c" fn _NSGetArgc() *c_int;
                extern "c" fn _NSGetArgv() *[*]const [*:0]const u8;
            };
            const argc: usize = @intCast(c._NSGetArgc().*);
            const args = c._NSGetArgv().*;
            return args[0..argc];
        } else if (comptime builtin.os.tag == .linux) {
            loadLinuxCmdline();
            return linux_cmdline_ptrs[0..linux_cmdline_argc];
        } else {
            return &.{};
        }
    }

    /// Current working directory absolute path, written into `out_buffer`;
    /// returns the populated sub-slice, or `null` on failure / when the
    /// buffer is too small. `getcwd` has no portable `std.fs`/`std.Io`
    /// abstraction (the `Dir.cwd()` handle is the `AT.FDCWD` sentinel, not
    /// a real fd `realPath` can resolve, and WASI's capability model has no
    /// canonical cwd at all), so it is an OS primitive carried by the seam.
    /// POSIX: a byte-for-byte lift of the prior `std.c.getcwd(&buf, len)` —
    /// returns the NUL-terminated path's slice (native anchor).
    pub fn cwd(out_buffer: []u8) ?[]const u8 {
        const ptr = std.c.getcwd(out_buffer.ptr, out_buffer.len) orelse return null;
        const len = std.mem.sliceTo(ptr, 0).len;
        return out_buffer[0..len];
    }

    /// Read up to `buf.len` bytes of OS entropy into `buf`; returns the
    /// number of bytes obtained (`0` if unavailable). Entropy has no
    /// uniform `std`-portable surface in the embedded runtime's bundled
    /// std (no `std.posix.getrandom`/`std.crypto.random` reachable), so it
    /// is an OS primitive carried by the seam. POSIX is a byte-for-byte
    /// lift of the runtime's previous `Random.osEntropy`: linux uses the
    /// `getrandom(2)` syscall; the BSDs/macOS degrade to `0` (the previous
    /// `else => return 0` arm), so the SplitMix64 seed falls back to
    /// `@returnAddress` ASLR entropy alone there, exactly as before.
    pub fn osEntropy(buf: []u8) usize {
        switch (comptime builtin.os.tag) {
            .linux => {
                const rc = std.os.linux.getrandom(buf.ptr, buf.len, 0);
                return if (rc <= buf.len) rc else 0;
            },
            else => return 0,
        }
    }

    /// Whether stdin has at least one byte ready WITHOUT blocking, via a
    /// zero-timeout `poll(POLLIN)` — a byte-for-byte lift of the runtime's
    /// previous `try_get_char` probe. A poll error degrades to `false`.
    pub fn pollStdinReady() bool {
        const POLLIN: i16 = 0x0001;
        var fds = [_]std.c.pollfd{.{
            .fd = stdin_handle,
            .events = POLLIN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, 0) catch return false;
        return ready != 0;
    }

    /// Saved pre-raw-mode terminal attributes and a capture flag. POSIX-only
    /// state for `enterRawMode`/`exitRawMode` (the `termios` type is itself
    /// POSIX-only), lifted from the runtime's previous module globals.
    var original_termios: std.posix.termios = undefined;
    var raw_mode_saved: bool = false;

    /// Put the terminal into raw mode (no canonical buffering, no echo,
    /// `V.MIN=1`/`V.TIME=0`), saving the prior attributes on first entry.
    /// A byte-for-byte lift of the runtime's previous
    /// `set_terminal_mode("Raw")` arm; `tcgetattr`/`tcsetattr` errors
    /// degrade silently.
    pub fn enterRawMode() void {
        var termios = std.posix.tcgetattr(stdin_handle) catch return;
        if (!raw_mode_saved) {
            original_termios = termios;
            raw_mode_saved = true;
        }
        termios.lflag.ICANON = false;
        termios.lflag.ECHO = false;
        termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(stdin_handle, .FLUSH, termios) catch return;
    }

    /// Restore the attributes saved by the first `enterRawMode` (no-op if
    /// raw mode was never entered). Byte-for-byte lift of the prior restore.
    pub fn exitRawMode() void {
        if (raw_mode_saved) {
            std.posix.tcsetattr(stdin_handle, .FLUSH, original_termios) catch return;
        }
    }

    /// Look up environment variable `name`. POSIX uses libc `getenv` on a
    /// NUL-terminated copy of `name` (Zap links libc on POSIX) — a
    /// byte-for-byte lift of the runtime's previous `envGetRuntime`. Names
    /// at or beyond the 256-byte scratch are rejected. The returned slice
    /// references the process environ block (process-lifetime).
    pub fn getEnv(name: []const u8) ?[]const u8 {
        var buf: [256]u8 = undefined;
        if (name.len >= buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const name_z: [*:0]const u8 = buf[0..name.len :0];
        const ptr = std.c.getenv(name_z) orelse return null;
        return std.mem.span(ptr);
    }

    // ---- Domain B: crash handling / backtrace / signals (Phase D) --------
    //
    // The crash REPORT renderers, the DWARF symbolizer, the `.zap-symbols`
    // sidecar reader, the double-fault guard, and the `Backtrace` capture
    // primitive all live in `runtime.zig` and are already portable (they
    // use `posixWrite` → the console seam and `std.debug.SelfInfo`, which
    // degrades to raw addresses). Only the genuinely OS-divergent surface
    // is carried here: the ASLR image slide, the async-signal-safe abort,
    // and the hardware-fault interception (POSIX `sigaction`; Windows VEH;
    // WASI none). The handler trampoline calls back into the runtime's
    // portable sink (`crashFromFault`) and capture primitive
    // (`Backtrace.captureFromContext`) — both top-level `runtime.zig`
    // symbols in scope where this body is spliced.

    /// Compute the main executable's runtime ASLR slide ONCE, at startup
    /// (NOT from a signal context — the loader queries take loader locks
    /// and are not async-signal-safe). The crash path subtracts this from
    /// each return address before the `0x<addr>` fallback so the report
    /// emits STATIC (file-relative) addresses (brief VI.B #9). A
    /// byte-for-byte lift of the runtime's previous `mainImageSlide`.
    ///
    /// macOS: image index 0 is the main executable;
    /// `_dyld_get_image_vmaddr_slide(0)` returns its slide. Linux/ELF: the
    /// first object `dl_iterate_phdr` visits is the main program; its
    /// `dlpi_addr` is the load bias. Other POSIX targets (or a static
    /// no-PIE image): slide is 0 (static == runtime).
    pub fn imageSlide() usize {
        switch (comptime builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos => {
                if (std.c._dyld_image_count() == 0) return 0;
                return std.c._dyld_get_image_vmaddr_slide(0);
            },
            .linux => {
                if (comptime builtin.object_format != .elf) return 0;
                const Finder = struct {
                    /// `dl_iterate_phdr` visits the main program first;
                    /// capture its load bias and stop (non-zero ends it).
                    fn callback(info: *std.c.dl_phdr_info, size: usize, data: ?*anyopaque) callconv(.c) c_int {
                        _ = size;
                        const out: *usize = @ptrCast(@alignCast(data.?));
                        out.* = @intCast(info.addr);
                        return 1;
                    }
                };
                var slide: usize = 0;
                _ = std.c.dl_iterate_phdr(Finder.callback, &slide);
                return slide;
            },
            else => return 0,
        }
    }

    /// Terminate the process IMMEDIATELY with `code`, running NO `atexit`
    /// handlers and performing no flushing — the async-signal-safe abort
    /// the crash path uses (a fault handler must not run `atexit`, which is
    /// not async-signal-safe). A byte-for-byte lift of the runtime's prior
    /// `std.c._exit(code)`. Distinct from `exitProcess`, which is the
    /// NORMAL exit and DOES run `atexit`.
    pub fn abortProcess(code: u8) noreturn {
        std.c._exit(code);
    }

    /// Map a fault signal to its Zap crash-report kind atom. SIGFPE is an
    /// `arithmetic_error` (the hardware sibling of the software
    /// divide-by-zero/overflow checks); the memory/instruction faults each
    /// get a dedicated kind. Snake-case to match the `Error.kind`
    /// convention. A verbatim lift of the runtime's prior `zapSignalKind`.
    fn signalKind(sig: std.posix.SIG) []const u8 {
        return switch (sig) {
            .SEGV => "segmentation_fault",
            .BUS => "bus_error",
            .FPE => "arithmetic_error",
            .ILL => "illegal_instruction",
            .TRAP => "trap",
            else => "fatal_signal",
        };
    }

    /// A human-readable description of the fault for the report's message
    /// slot. Mirrors the fork's own signal names. A verbatim lift of the
    /// runtime's prior `zapSignalMessage`.
    fn signalMessage(sig: std.posix.SIG) []const u8 {
        return switch (sig) {
            .SEGV => "segmentation fault (invalid memory access)",
            .BUS => "bus error (misaligned or non-existent memory access)",
            .FPE => "arithmetic exception",
            .ILL => "illegal instruction",
            .TRAP => "trace/breakpoint trap",
            else => "fatal signal",
        };
    }

    /// True on targets where the fork's `captureCurrentStackTrace` can
    /// unwind from a POSIX signal's saved CPU context. `cpu_context.Native`
    /// is `noreturn` on unsupported targets (and `CpuContextPtr` follows),
    /// so this gates the whole signal-handler subsystem at comptime; on an
    /// unsupported target `installCrashHandlers` is a no-op and the default
    /// signal disposition stands. A verbatim lift of the runtime's prior
    /// `zap_signal_handlers_supported` (minus the `os.tag != .windows`
    /// term, which is implicit: this body is the non-Windows arm).
    const signal_handlers_supported =
        std.debug.have_segfault_handling_support and
        std.debug.cpu_context.Native != noreturn;

    /// Whether hardware-fault interception is wired on this target. The
    /// `runtime.zig` call site reads this to decide whether to install the
    /// handler at startup; it is the seam-level generalization of the
    /// prior `zap_signal_handlers_supported` gate.
    pub const supports_fault_handlers: bool = signal_handlers_supported;

    var signal_handlers_installed: bool = false;

    /// The `SA_SIGINFO` handler installed for every hardware-fault signal.
    /// Async-signal-safe: reads the saved CPU context, captures a backtrace
    /// from the faulting frame, and routes to the runtime's shared crash
    /// sink (`crashFromFault`), which terminates via `abortProcess`. The
    /// double-fault observe-without-claim happens in `crashFromFault`, but
    /// a report already in progress is short-circuited HERE (before the
    /// context read/unwind, which can themselves fault) — a verbatim lift
    /// of the runtime's prior `zapSignalHandler`.
    fn faultSignalHandler(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) noreturn {
        _ = info;

        // A report is already underway: this signal interrupted the crash
        // printer (or a sibling fatal signal beat it here). Divert to the
        // minimal abort BEFORE the context read/unwind. `@atomicLoad` (not
        // a claiming RMW) so we observe-without-claiming; the single claim
        // stays in `crashFromFault`.
        if (crashReportInProgress()) doubleFaultAbort();

        const kind = signalKind(sig);
        const message = signalMessage(sig);

        if (comptime signal_handlers_supported) {
            if (std.debug.cpu_context.fromPosixSignalContext(ctx_ptr)) |cpu_ctx| {
                // `fromPosixSignalContext` returns a by-value
                // `cpu_context.Native`; bind it so the unwinder can take
                // its address. The PC seeds the first frame, so the trace
                // begins at the faulting instruction, not this handler.
                const ctx_local = cpu_ctx;
                const bt = captureFaultBacktrace(&ctx_local);
                crashFromFault(kind, message, bt);
            }
        }

        // No usable CPU context (extraction failed): still emit the
        // unified header so the fault is reported in the Zap format, just
        // without a symbolized backtrace.
        crashFromFault(kind, message, emptyBacktrace());
    }

    /// Install the `SA_SIGINFO` Zap crash handler for the hardware-fault
    /// signals (SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP). Idempotent and a
    /// comptime no-op on targets that cannot unwind a signal context.
    /// `SA_ONSTACK` so a stack-overflow SIGSEGV is handled on the alternate
    /// signal stack; `SA_RESETHAND` as defense-in-depth behind the
    /// runtime's explicit `crash_report_in_progress` double-fault guard. A
    /// verbatim lift of the runtime's prior `installZapSignalHandlers`.
    pub fn installCrashHandlers() void {
        if (comptime !signal_handlers_supported) return;
        if (signal_handlers_installed) return;
        signal_handlers_installed = true;

        const act: std.posix.Sigaction = .{
            .handler = .{ .sigaction = faultSignalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO | std.posix.SA.RESETHAND | std.posix.SA.ONSTACK,
        };
        std.posix.sigaction(.SEGV, &act, null);
        std.posix.sigaction(.BUS, &act, null);
        std.posix.sigaction(.FPE, &act, null);
        std.posix.sigaction(.ILL, &act, null);
        std.posix.sigaction(.TRAP, &act, null);
    }
    // ZAP_RUNTIME_OS_BODY_END posix
};

// The standalone test build needs the `loadLinuxCmdline` symbol and its
// backing state to exist so `Backend.argv` type-checks. Inside the
// embedded runtime these are already defined (the runtime owns the
// `/proc/self/cmdline` cache); the splice references the runtime's
// copies and never sees the stubs below (they live outside the
// sentinels). They are deliberately minimal — the production
// implementation is in `runtime.zig`.
var linux_cmdline_ptrs: [1][*:0]const u8 = undefined;
var linux_cmdline_argc: usize = 0;
fn loadLinuxCmdline() void {
    linux_cmdline_argc = 0;
}

// Standalone stubs for the crash-handler seam↔runtime contract. The spliced
// body (between the BODY sentinels) calls back into these `runtime.zig`
// top-level symbols — the portable crash-report sink, the double-fault guard,
// and the `Backtrace` capture primitive — which are all in scope where the
// body is spliced. For the standalone type-check build (`zig build test`
// compiling this file via `Backend = struct{}`) the same names must exist, so
// these minimal stubs stand in; the splice never sees them (they live outside
// the sentinels). The production implementations are in `runtime.zig`.
const StubBacktrace = extern struct { addresses: [1]usize, len: usize };
fn crashReportInProgress() bool {
    return false;
}
fn doubleFaultAbort() noreturn {
    std.c._exit(137);
}
fn captureFaultBacktrace(ctx: std.debug.CpuContextPtr) StubBacktrace {
    _ = ctx;
    return .{ .addresses = undefined, .len = 0 };
}
fn emptyBacktrace() StubBacktrace {
    return .{ .addresses = undefined, .len = 0 };
}
fn crashFromFault(kind: []const u8, message: []const u8, bt: StubBacktrace) noreturn {
    _ = kind;
    _ = message;
    _ = bt;
    std.c._exit(1);
}

test "posix backend caps describe a POSIX target" {
    // POSIX always has signals and termios; console handles are fds.
    try std.testing.expect(Backend.caps.supports_signals);
    try std.testing.expect(Backend.caps.supports_termios);
    try std.testing.expectEqual(std.posix.fd_t, Backend.caps.console_handle);
}

test "posix backend nowNanos is monotonic-ish and non-zero" {
    // A wall clock read should be far above zero on any real host.
    const t = Backend.nowNanos();
    try std.testing.expect(t > 0);
}
