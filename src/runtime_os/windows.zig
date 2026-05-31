//! Windows runtime-OS backend (`runtime_os` seam).
//!
//! Windows addresses the console by `HANDLE` rather than a small-integer
//! file descriptor (the `caps.console_handle` distinction), and has no
//! POSIX signal model — hardware faults arrive through Vectored Exception
//! Handling (VEH), which the crash handler (Domain B) wires in Phase D.
//! This Phase-A backend covers console write/read, time, exit, atexit,
//! and argv so a trivial `IO.puts` program **links** as a Windows PE
//! (and runs where a Windows host / wine is available).
//!
//! Console I/O uses the synchronous `NtWriteFile`/`NtReadFile` path on
//! the PEB standard handles — exactly the handles `std.Io.File.stdout()`
//! resolves to on Windows — so it does not assume libc's fd layer.
//! Time and exit route through `std.time` / `std.process.exit`, which
//! already carry the Windows backends (`QueryPerformanceCounter`-class
//! timing, `RtlExitUserProcess`).
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
    // ZAP_RUNTIME_OS_BODY_BEGIN windows
    /// Capability model for the Windows backend.
    pub const caps = struct {
        /// Windows delivers hardware faults via Vectored Exception
        /// Handling. The crash handler (Phase D) installs a VEH; until
        /// then the default disposition stands (the `runtime.zig` call
        /// site additionally gates on `zap_signal_handlers_supported`,
        /// which is false on Windows because the fork's POSIX
        /// `sigaction` path is absent — so Phase A never installs
        /// anything on Windows).
        pub const supports_signals: bool = true;

        /// Windows raw-mode is `SetConsoleMode`, not termios; the
        /// termios path is unavailable, so raw-mode degrades until the
        /// console-mode backend lands.
        pub const supports_termios: bool = false;

        /// Symbolization follows the fork's `SelfInfo` (PE/PDB on
        /// Windows; degrades to `void` → raw addresses otherwise).
        pub const supports_backtrace: bool = std.debug.SelfInfo != void;

        /// Windows console primitives address streams by `HANDLE`.
        pub const console_handle: type = std.os.windows.HANDLE;
    };

    /// The standard-stream handles, read from the PEB process
    /// parameters — the same source `std.Io.File.stdout()` uses on
    /// Windows. These are synchronous console handles.
    pub fn stdoutHandle() caps.console_handle {
        return std.os.windows.peb().ProcessParameters.hStdOutput;
    }
    pub fn stderrHandle() caps.console_handle {
        return std.os.windows.peb().ProcessParameters.hStdError;
    }
    pub fn stdinHandle() caps.console_handle {
        return std.os.windows.peb().ProcessParameters.hStdInput;
    }

    /// Write all of `bytes` to the console `handle` via synchronous
    /// `NtWriteFile`, looping over partial writes. The PEB standard
    /// handles are synchronous, so `.SUCCESS` completes the write
    /// immediately and the byte count lives in the IO_STATUS_BLOCK.
    /// Any non-success status (or a zero-byte advance) ends the loop —
    /// matching the POSIX backend's "stop on error" shape.
    pub fn consoleWrite(handle: caps.console_handle, bytes: []const u8) void {
        const windows = std.os.windows;
        var written: usize = 0;
        while (written < bytes.len) {
            const chunk = bytes[written..];
            // NtWriteFile's Length is a ULONG (u32); cap each syscall.
            const len: u32 = if (chunk.len > std.math.maxInt(u32))
                std.math.maxInt(u32)
            else
                @intCast(chunk.len);
            var iosb: windows.IO_STATUS_BLOCK = undefined;
            const status = windows.ntdll.NtWriteFile(
                handle,
                null, // Event
                null, // ApcRoutine
                null, // ApcContext
                &iosb,
                chunk.ptr,
                len,
                null, // ByteOffset (synchronous handle ⇒ current position)
                null, // Key
            );
            if (status != .SUCCESS) break;
            const advanced = iosb.Information;
            if (advanced == 0) break;
            written += advanced;
        }
    }

    /// Read up to `buf.len` bytes from the console `handle` via
    /// synchronous `NtReadFile`. Returns the number of bytes read, or
    /// `0` on EOF/error.
    pub fn consoleRead(handle: caps.console_handle, buf: []u8) usize {
        const windows = std.os.windows;
        if (buf.len == 0) return 0;
        const len: u32 = if (buf.len > std.math.maxInt(u32))
            std.math.maxInt(u32)
        else
            @intCast(buf.len);
        var iosb: windows.IO_STATUS_BLOCK = undefined;
        const status = windows.ntdll.NtReadFile(
            handle,
            null,
            null,
            null,
            &iosb,
            buf.ptr,
            len,
            null,
            null,
        );
        if (status != .SUCCESS) return 0;
        return iosb.Information;
    }

    /// Write all of `bytes` to stdout (the PEB `hStdOutput` handle).
    pub fn writeStdout(bytes: []const u8) void {
        consoleWrite(stdoutHandle(), bytes);
    }

    /// Write all of `bytes` to stderr (the PEB `hStdError` handle).
    pub fn writeStderr(bytes: []const u8) void {
        consoleWrite(stderrHandle(), bytes);
    }

    /// Read up to `buf.len` bytes from stdin (the PEB `hStdInput` handle).
    pub fn readStdin(buf: []u8) usize {
        return consoleRead(stdinHandle(), buf);
    }

    /// Whether stderr is an interactive console. Windows has no
    /// `isatty`; `GetConsoleMode` succeeds only for a real console
    /// handle, so a successful call is the TTY signal. kernel32 is
    /// always linked on Windows, so the direct extern is safe.
    pub fn stderrIsTty() bool {
        const k = struct {
            extern "kernel32" fn GetConsoleMode(
                hConsoleHandle: std.os.windows.HANDLE,
                lpMode: *std.os.windows.DWORD,
            ) callconv(.winapi) std.os.windows.BOOL;
        };
        var mode: std.os.windows.DWORD = 0;
        // `BOOL` is the typed `Bool(c_int)` enum in std; `.toBool()` is
        // the correct truthiness test (a raw `!= 0` compares an enum to
        // an int and a `!= .FALSE`/`== .TRUE` is flagged as a bug).
        return k.GetConsoleMode(stderrHandle(), &mode).toBool();
    }

    /// 100-ns ticks between 1601-01-01 (the Windows FILETIME epoch) and
    /// 1970-01-01 (the Unix epoch): 11644473600 seconds × 10^7.
    const FILETIME_TO_UNIX_100NS: u64 = 116444736000000000;

    /// Current wall-clock time in nanoseconds since the Unix epoch via
    /// kernel32 `GetSystemTimeAsFileTime`. The bundled std has no
    /// `std.time.nanoTimestamp`, so the Win32 call is made directly
    /// (kernel32 is always linked on Windows). FILETIME is 100-ns ticks
    /// since 1601; we rebase to 1970 and scale to nanoseconds.
    pub fn nowNanos() u64 {
        const k = struct {
            extern "kernel32" fn GetSystemTimeAsFileTime(
                lpSystemTimeAsFileTime: *std.os.windows.FILETIME,
            ) callconv(.winapi) void;
        };
        var ft: std.os.windows.FILETIME = undefined;
        k.GetSystemTimeAsFileTime(&ft);
        const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
        if (ticks <= FILETIME_TO_UNIX_100NS) return 0;
        return (ticks - FILETIME_TO_UNIX_100NS) * 100;
    }

    /// Sleep for `nanoseconds` via kernel32 `Sleep` (millisecond
    /// resolution; the bundled std has no `std.time.sleep`). Sub-
    /// millisecond requests round up to 1 ms so a positive request never
    /// becomes a no-op.
    pub fn sleepNanos(nanoseconds: u64) void {
        if (nanoseconds == 0) return;
        const k = struct {
            extern "kernel32" fn Sleep(dwMilliseconds: std.os.windows.DWORD) callconv(.winapi) void;
        };
        const ms_u64 = (nanoseconds + 999_999) / 1_000_000;
        const ms: std.os.windows.DWORD = if (ms_u64 > std.math.maxInt(std.os.windows.DWORD))
            std.math.maxInt(std.os.windows.DWORD)
        else
            @intCast(ms_u64);
        k.Sleep(ms);
    }

    /// Terminate the process with `code`. `std.process.exit` lowers to
    /// `RtlExitUserProcess` on Windows (or libc `exit` when libc is
    /// linked, as on `*-windows-gnu`).
    pub fn exitProcess(code: u8) noreturn {
        std.process.exit(code);
    }

    /// Register a C-ABI handler to run at normal process exit via libc
    /// `atexit`. `*-windows-gnu` links mingw libc, which provides
    /// `atexit`. Returns 0 on success.
    pub fn registerAtExit(handler: *const fn () callconv(.c) void) c_int {
        const c = struct {
            extern "c" fn atexit(handler: *const fn () callconv(.c) void) c_int;
        };
        return c.atexit(handler);
    }

    /// Process argv on Windows. The argument vector lives in the PEB as
    /// a single WTF-16 `CommandLine` UNICODE_STRING; recovering a
    /// `[*:0]const u8`-style argv requires tokenizing it (quote/backslash
    /// rules) and transcoding WTF-16 → UTF-8 into stable storage. That
    /// transcode is the one piece of the argv domain that does not map to
    /// an allocation-free static-cache lift the way the POSIX
    /// `/proc/self/cmdline` and macOS `_NSGetArgv` paths do, so under the
    /// capability model it DEGRADES to an empty argv on Windows for now
    /// (a program that does not read its arguments — like the Phase-A
    /// `IO.puts` fixture — is unaffected). The CommandLine tokenizer +
    /// WTF-16 transcode into a static cache is the tracked Windows-argv
    /// follow-up; it is deliberately NOT the mingw `__argv`/`__argc` CRT
    /// globals (those are not defined under Zap's object-based Windows
    /// link, producing `undefined symbol` link errors).
    pub fn argv() []const [*:0]const u8 {
        return &.{};
    }
    // ZAP_RUNTIME_OS_BODY_END windows
};

test "windows backend caps use HANDLE and degrade termios" {
    try std.testing.expect(!Backend.caps.supports_termios);
    try std.testing.expectEqual(std.os.windows.HANDLE, Backend.caps.console_handle);
}
