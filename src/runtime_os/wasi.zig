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

    /// Register a C-ABI handler to run at normal process exit via libc
    /// `atexit`. wasi-libc (which a hosted Zap wasm binary links) provides
    /// `atexit`, and its crt0 calls `exit()` on a normal `main` return,
    /// which runs registered handlers — so the buffered-stdout flush
    /// fires before the instance terminates, exactly as on POSIX. Returns
    /// 0 on success.
    pub fn registerAtExit(handler: *const fn () callconv(.c) void) c_int {
        const c = struct {
            extern "c" fn atexit(handler: *const fn () callconv(.c) void) c_int;
        };
        return c.atexit(handler);
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

    /// WASI preview1 is capability-based: a module reaches the filesystem
    /// only through host-granted preopened directories, and there is no
    /// canonical absolute "current working directory" path to report. So
    /// `cwd` degrades to `null` (the `System.cwd` Zap contract surfaces
    /// this as `""`), consistent with the campaign's comptime-degrade
    /// capability model.
    pub fn cwd(out_buffer: []u8) ?[]const u8 {
        _ = out_buffer;
        return null;
    }

    /// Read up to `buf.len` bytes of OS entropy into `buf` via preview1
    /// `random_get`; returns the number of bytes obtained (`0` on error).
    /// `random_get` fills the entire buffer on success (it has no partial-
    /// fill semantics), so a `.SUCCESS` errno means `buf.len` bytes; any
    /// other errno yields `0` (the seed then degrades to `@returnAddress`
    /// entropy alone, per the comptime-degrade contract).
    pub fn osEntropy(buf: []u8) usize {
        if (buf.len == 0) return 0;
        const rc = std.os.wasi.random_get(buf.ptr, buf.len);
        return if (rc == .SUCCESS) buf.len else 0;
    }

    /// Whether stdin has data ready WITHOUT blocking. WASI has no `poll`;
    /// `poll_oneoff` blocks until an event, so to probe without blocking we
    /// submit TWO subscriptions — an `FD_READ` on stdin (fd 0) and a
    /// zero-duration relative MONOTONIC clock — so the call returns
    /// immediately (the zero timer always fires). Stdin is "ready" iff the
    /// returned events include the `FD_READ` subscription (identified by its
    /// `userdata` tag) with no error. The two subscriptions are tagged via
    /// `userdata` (0 = stdin read, 1 = the wake clock). Any errno degrades
    /// to `false`.
    pub fn pollStdinReady() bool {
        const STDIN_USERDATA: std.os.wasi.userdata_t = 0;
        const CLOCK_USERDATA: std.os.wasi.userdata_t = 1;
        const subs = [_]std.os.wasi.subscription_t{
            .{
                .userdata = STDIN_USERDATA,
                .u = .{ .tag = .FD_READ, .u = .{ .fd_read = .{ .fd = stdin_handle } } },
            },
            .{
                .userdata = CLOCK_USERDATA,
                .u = .{ .tag = .CLOCK, .u = .{ .clock = .{
                    .id = .MONOTONIC,
                    .timeout = 0, // zero relative timeout ⇒ return immediately
                    .precision = 0,
                    .flags = 0,
                } } },
            },
        };
        var events: [2]std.os.wasi.event_t = undefined;
        var nevents: usize = 0;
        const rc = std.os.wasi.poll_oneoff(&subs[0], &events[0], subs.len, &nevents);
        if (rc != .SUCCESS) return false;
        var i: usize = 0;
        while (i < nevents) : (i += 1) {
            const ev = events[i];
            if (ev.userdata == STDIN_USERDATA and ev.@"error" == .SUCCESS and ev.fd_readwrite.nbytes > 0) {
                return true;
            }
        }
        return false;
    }

    /// Raw terminal mode. WASI has no controlling terminal
    /// (`caps.supports_termios == false`), so raw-mode DEGRADES to a no-op
    /// — the campaign's comptime-degrade contract. Line-mode `gets` still
    /// works; character-at-a-time input is simply unavailable under WASI.
    pub fn enterRawMode() void {}

    /// Restore from raw mode — a no-op on WASI (see `enterRawMode`).
    pub fn exitRawMode() void {}

    /// Fixed environment cache. WASI hands the full environ block to the
    /// module at startup via `environ_get`; we snapshot it once into static
    /// storage (no allocator on the startup path) and scan it on each
    /// lookup. 32 KiB of bytes with up to 256 entries matches the argv
    /// cache's order of magnitude.
    const WASI_ENVIRON_BUF_SIZE: usize = 32 * 1024;
    const WASI_ENVIRON_MAX_VARS: usize = 256;

    var wasi_environ_buf: [WASI_ENVIRON_BUF_SIZE]u8 = undefined;
    var wasi_environ_ptrs: [WASI_ENVIRON_MAX_VARS][*:0]u8 = undefined;
    var wasi_environ_count: usize = 0;
    var wasi_environ_loaded: bool = false;

    /// Populate the environ cache from preview1 `environ_get`. Idempotent.
    /// Degrades to an empty environ (no vars) if the block does not fit the
    /// fixed cache, rather than overrunning.
    fn loadWasiEnviron() void {
        if (wasi_environ_loaded) return;
        wasi_environ_loaded = true;
        wasi_environ_count = 0;

        var count: usize = 0;
        var buf_size: usize = 0;
        if (std.os.wasi.environ_sizes_get(&count, &buf_size) != .SUCCESS) return;
        if (count == 0) return;
        if (count > WASI_ENVIRON_MAX_VARS or buf_size > WASI_ENVIRON_BUF_SIZE) return;
        if (std.os.wasi.environ_get(&wasi_environ_ptrs, &wasi_environ_buf) != .SUCCESS) return;
        wasi_environ_count = count;
    }

    /// Look up environment variable `name` by scanning the cached WASI
    /// environ block for a `name=value` entry. Returns the value slice
    /// (into the process-lifetime cache) or `null` if unset. Each cached
    /// entry is a `[*:0]u8` `name=value` string.
    pub fn getEnv(name: []const u8) ?[]const u8 {
        loadWasiEnviron();
        var i: usize = 0;
        while (i < wasi_environ_count) : (i += 1) {
            const entry = std.mem.span(wasi_environ_ptrs[i]);
            if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
                if (std.mem.eql(u8, entry[0..eq], name)) {
                    return entry[eq + 1 ..];
                }
            }
        }
        return null;
    }

    // ---- Domain B: crash handling (Phase D — degrade) --------------------
    //
    // WASM has NO signal/exception model, so there is no way to intercept a
    // hardware fault: `supports_fault_handlers = false`, `installCrashHandlers`
    // is a comptime no-op, and a fatal fault traps (`unreachable`/`abort` in
    // the wasm runtime). This is loss-of-rich-crash, NOT loss-of-correctness:
    // the RECOVERABLE `raise`/`@panic`/explicit-crash-report paths do not go
    // through the OS fault interceptor — they call the runtime's portable
    // crash sink directly — so they STILL render a full report through the
    // `consoleWrite` (`fd_write`) console seam. Only the hardware-fault
    // interception is unavailable. (Mirrors `caps.supports_signals = false`.)

    /// No ASLR / dynamic load bias under wasm linear memory: the slide is
    /// always 0 (static == runtime), so the crash report's de-slide
    /// subtraction is the identity. The `SelfInfo` symbolizer (when the fork
    /// carries a wasm unwinder) and the `.zap-symbols` side-table render the
    /// recoverable-path backtrace; otherwise it degrades to raw addresses.
    pub fn imageSlide() usize {
        return 0;
    }

    /// Terminate the process IMMEDIATELY with `code` via preview1
    /// `proc_exit`, running no `atexit` handlers — the WASI analog of the
    /// async-signal-safe abort the crash path uses. `proc_exit` does not
    /// return, so the trailing `unreachable` is never reached (it satisfies
    /// the `noreturn` contract for the verifier).
    pub fn abortProcess(code: u8) noreturn {
        std.os.wasi.proc_exit(code);
        unreachable;
    }

    /// WASM has no hardware-fault interception model, so fault handlers are
    /// unsupported; the `runtime.zig` call site reads this to make
    /// `installCrashHandlers` a comptime no-op. A fatal hardware fault traps.
    pub const supports_fault_handlers: bool = false;

    /// No-op: WASM cannot intercept hardware faults (see the section note).
    /// The recoverable `raise`/`@panic` crash reports still render — they do
    /// not depend on this install. Matches the campaign's comptime-degrade
    /// contract, never a compile error.
    pub fn installCrashHandlers() void {}

    /// Phase B per-test hard timeout — a no-op on WASI (no SIGALRM). The
    /// in-process `check_timeout` still catches slow-but-returning tests. See
    /// the POSIX backend for the real implementation.
    pub fn alarmSeconds(seconds: u32) void {
        _ = seconds;
    }
    // ZAP_RUNTIME_OS_BODY_END wasi
};

test "wasi backend caps degrade signals and termios" {
    try std.testing.expect(!Backend.caps.supports_signals);
    try std.testing.expect(!Backend.caps.supports_termios);
    try std.testing.expectEqual(std.os.wasi.fd_t, Backend.caps.console_handle);
}
