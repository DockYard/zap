//! WASI (wasm32-wasi, preview1) runtime-OS backend (`runtime_os` seam).
//!
//! WASI has no signal model and no controlling terminal, so the crash
//! handler (Domain B) and raw-mode (Domain D) degrade to comptime no-ops
//! through the capability model — never a compile error (campaign
//! Decision 3/4). Console I/O, time, exit, and argv map directly to
//! wasi preview1 syscalls (`fd_write`/`fd_read`/`clock_time_get`/
//! `proc_exit`/`args_get`), which are part of the wasm import ABI and do
//! not depend on libc being linked.
//!
//! ## Embedding contract
//!
//! See `posix.zig`'s header: the body between the
//! `ZAP_RUNTIME_OS_BODY_BEGIN`/`END` sentinels is spliced inline into the
//! embedded runtime by `compiler.zig`. The body references only `std`,
//! `builtin`, and declarations it makes itself.

const std = @import("std");
const builtin = @import("builtin");

pub const Backend = struct {
    // ZAP_RUNTIME_OS_BODY_BEGIN wasi
    /// Capability model for the WASI backend. wasm has neither a signal
    /// model nor a controlling terminal, so the two genuinely
    /// OS-divergent domains degrade at comptime.
    pub const caps = struct {
        /// No hardware-fault signal delivery on wasm: a fatal fault
        /// traps. The crash handler is a comptime no-op; recoverable
        /// `raise`/`@panic` reports still render through `consoleWrite`.
        pub const supports_signals: bool = false;

        /// No controlling terminal: raw-mode is a comptime no-op.
        pub const supports_termios: bool = false;

        /// Symbolization follows the fork's `SelfInfo` for wasm (degrades
        /// to `void` → raw addresses when the fork has no wasm unwinder).
        pub const supports_backtrace: bool = std.debug.SelfInfo != void;

        /// WASI addresses streams by preview1 file descriptor (`i32`).
        pub const console_handle: type = std.os.wasi.fd_t;
    };

    /// Preview1 fixes the standard streams to descriptors 0/1/2.
    pub const stdout_handle: caps.console_handle = 1;
    pub const stderr_handle: caps.console_handle = 2;
    pub const stdin_handle: caps.console_handle = 0;

    /// Write all of `bytes` to `handle` via `fd_write`, looping over
    /// partial writes. A zero-byte write or any non-`SUCCESS` errno ends
    /// the loop (matching the POSIX backend's "stop on error" shape).
    pub fn consoleWrite(handle: caps.console_handle, bytes: []const u8) void {
        var written: usize = 0;
        while (written < bytes.len) {
            const chunk = bytes[written..];
            const iov = [_]std.os.wasi.ciovec_t{.{ .base = chunk.ptr, .len = chunk.len }};
            var nwritten: usize = 0;
            const rc = std.os.wasi.fd_write(handle, &iov, iov.len, &nwritten);
            if (rc != .SUCCESS or nwritten == 0) break;
            written += nwritten;
        }
    }

    /// Read up to `buf.len` bytes from `handle` via `fd_read`. Returns
    /// the number of bytes read, or `0` on EOF/error.
    pub fn consoleRead(handle: caps.console_handle, buf: []u8) usize {
        if (buf.len == 0) return 0;
        const iov = [_]std.os.wasi.iovec_t{.{ .base = buf.ptr, .len = buf.len }};
        var nread: usize = 0;
        const rc = std.os.wasi.fd_read(handle, &iov, iov.len, &nread);
        if (rc != .SUCCESS) return 0;
        return nread;
    }

    /// Write all of `bytes` to stdout (preview1 fd 1).
    pub fn writeStdout(bytes: []const u8) void {
        consoleWrite(stdout_handle, bytes);
    }

    /// Write all of `bytes` to stderr (preview1 fd 2).
    pub fn writeStderr(bytes: []const u8) void {
        consoleWrite(stderr_handle, bytes);
    }

    /// Read up to `buf.len` bytes from stdin (preview1 fd 0).
    pub fn readStdin(buf: []u8) usize {
        return consoleRead(stdin_handle, buf);
    }

    /// WASI has no controlling terminal, so stderr is never a TTY. The
    /// crash reporter therefore never colorizes under WASI.
    pub fn stderrIsTty() bool {
        return false;
    }

    /// Current wall-clock time in nanoseconds since the Unix epoch via
    /// `clock_time_get(REALTIME)`. `std.time.nanoTimestamp` also targets
    /// WASI, but calling the syscall directly keeps the backend
    /// self-contained and avoids depending on std's per-OS dispatch
    /// resolving identically here.
    pub fn nowNanos() u64 {
        var ts: std.os.wasi.timestamp_t = 0;
        const rc = std.os.wasi.clock_time_get(.REALTIME, 1, &ts);
        if (rc != .SUCCESS) return 0;
        return ts;
    }

    /// Sleep for `nanoseconds` via `poll_oneoff` with a single relative
    /// MONOTONIC clock subscription (flags 0 ⇒ relative timeout). The
    /// bundled std has no `std.time.sleep`, so the wasi primitive is
    /// called directly. A non-success errno is treated as "slept" (best
    /// effort) since there is no recovery for a failed timer wait.
    pub fn sleepNanos(nanoseconds: u64) void {
        if (nanoseconds == 0) return;
        const sub = std.os.wasi.subscription_t{
            .userdata = 0,
            .u = .{
                .tag = .CLOCK,
                .u = .{ .clock = .{
                    .id = .MONOTONIC,
                    .timeout = nanoseconds,
                    .precision = 0,
                    .flags = 0, // relative timeout
                } },
            },
        };
        var event: std.os.wasi.event_t = undefined;
        var nevents: usize = 0;
        _ = std.os.wasi.poll_oneoff(&sub, &event, 1, &nevents);
    }

    /// Terminate the wasm instance with `code` via `proc_exit`.
    pub fn exitProcess(code: u8) noreturn {
        std.os.wasi.proc_exit(@as(std.os.wasi.exitcode_t, code));
    }

    /// WASI has no `atexit` in the import ABI. There is no portable
    /// preview1 process-exit hook, so registration is a no-op that
    /// reports failure (non-zero). The runtime's only `atexit` use is
    /// the stdout flush; under WASI the runtime flushes explicitly on
    /// the normal-exit path instead of relying on this hook (the trivial
    /// Phase-A fixture flushes before `exitProcess`).
    pub fn registerAtExit(handler: *const fn () callconv(.c) void) c_int {
        _ = handler;
        return -1;
    }

    /// Process argv via `args_sizes_get` + `args_get`. The pointers and
    /// their backing bytes are cached in module-static storage on first
    /// call (idempotent), mirroring the linux `/proc/self/cmdline`
    /// cache. Returns an empty slice if the host provides no args or the
    /// arg data does not fit the fixed cache.
    pub fn argv() []const [*:0]const u8 {
        loadWasiArgs();
        return wasi_argv_ptrs[0..wasi_argv_argc];
    }

    /// Fixed argv cache sizes. WASI command lines are bounded in
    /// practice; a 4 KiB byte buffer with up to 256 args matches the
    /// linux cmdline cache's order of magnitude without an allocator
    /// (the runtime startup path must not allocate).
    const WASI_ARGV_BUF_SIZE: usize = 4096;
    const WASI_ARGV_MAX_ARGS: usize = 256;

    var wasi_argv_buf: [WASI_ARGV_BUF_SIZE]u8 = undefined;
    var wasi_argv_ptrs: [WASI_ARGV_MAX_ARGS][*:0]const u8 = undefined;
    var wasi_argv_argc: usize = 0;
    var wasi_argv_loaded: bool = false;

    /// Populate the argv cache from preview1 `args_get`. Idempotent.
    fn loadWasiArgs() void {
        if (wasi_argv_loaded) return;
        wasi_argv_loaded = true;
        wasi_argv_argc = 0;

        var argc: usize = 0;
        var buf_size: usize = 0;
        if (std.os.wasi.args_sizes_get(&argc, &buf_size) != .SUCCESS) return;
        if (argc == 0) return;
        if (argc > WASI_ARGV_MAX_ARGS or buf_size > WASI_ARGV_BUF_SIZE) {
            // Too large for the static cache; degrade to no argv rather
            // than overrun. The Phase-A fixture's argv is tiny.
            return;
        }

        // `args_get` writes `argc` NUL-terminated strings into the byte
        // buffer and fills the pointer array with pointers into it. The
        // pointer array's element type is `[*:0]u8`; we expose it as
        // `[*:0]const u8`.
        var ptrs: [WASI_ARGV_MAX_ARGS][*:0]u8 = undefined;
        if (std.os.wasi.args_get(&ptrs, &wasi_argv_buf) != .SUCCESS) return;

        var i: usize = 0;
        while (i < argc) : (i += 1) {
            wasi_argv_ptrs[i] = ptrs[i];
        }
        wasi_argv_argc = argc;
    }
    // ZAP_RUNTIME_OS_BODY_END wasi
};

test "wasi backend caps degrade signals and termios" {
    try std.testing.expect(!Backend.caps.supports_signals);
    try std.testing.expect(!Backend.caps.supports_termios);
    try std.testing.expectEqual(std.os.wasi.fd_t, Backend.caps.console_handle);
}
