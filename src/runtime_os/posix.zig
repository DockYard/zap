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
