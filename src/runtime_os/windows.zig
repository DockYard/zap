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

    /// Current working directory absolute path, written into `out_buffer`;
    /// returns the populated sub-slice, or `null` on failure / when the
    /// buffer is too small. `getcwd` has no uniform `std.fs`/`std.Io`
    /// abstraction, so it is an OS primitive carried by the seam. Windows
    /// uses kernel32 `GetCurrentDirectoryA` (kernel32 is always linked):
    /// it writes a NUL-terminated path and returns the length WITHOUT the
    /// terminator on success, or — when the buffer is too small — the
    /// required size INCLUDING the terminator (a value `>= out_buffer.len`),
    /// which we treat as failure (`null`). A `0` return is also failure.
    /// The byte (`A`) variant matches the `[]const u8` byte-path contract
    /// of `System.cwd`; a `W`-variant + WTF-16→UTF-8 transcode (for
    /// non-ANSI paths) is the same deferred work as the Windows-argv
    /// follow-up and is not required for the ASCII-path common case.
    pub fn cwd(out_buffer: []u8) ?[]const u8 {
        const k = struct {
            extern "kernel32" fn GetCurrentDirectoryA(
                nBufferLength: std.os.windows.DWORD,
                lpBuffer: [*]u8,
            ) callconv(.winapi) std.os.windows.DWORD;
        };
        const len_dword: std.os.windows.DWORD = if (out_buffer.len > std.math.maxInt(std.os.windows.DWORD))
            std.math.maxInt(std.os.windows.DWORD)
        else
            @intCast(out_buffer.len);
        const written = k.GetCurrentDirectoryA(len_dword, out_buffer.ptr);
        if (written == 0 or written >= out_buffer.len) return null;
        return out_buffer[0..written];
    }

    /// Read up to `buf.len` bytes of OS entropy into `buf`; returns the
    /// number of bytes obtained (`0` on failure). Windows exposes the
    /// system CSPRNG as `RtlGenRandom` (advapi32 ordinal `SystemFunction036`,
    /// the primitive `BCryptGenRandom`/`RtlGenRandom` and Rust's `getrandom`
    /// crate use on Windows); advapi32 is linkable on `*-windows-gnu`. A
    /// `TRUE` return means the whole buffer was filled, so the byte count is
    /// `buf.len`; `FALSE` yields `0` (the seed then degrades to
    /// `@returnAddress` entropy alone, matching the campaign's
    /// comptime-degrade contract).
    pub fn osEntropy(buf: []u8) usize {
        if (buf.len == 0) return 0;
        const advapi = struct {
            extern "advapi32" fn SystemFunction036(
                RandomBuffer: [*]u8,
                RandomBufferLength: std.os.windows.ULONG,
            ) callconv(.winapi) std.os.windows.BOOLEAN;
        };
        const len: std.os.windows.ULONG = if (buf.len > std.math.maxInt(std.os.windows.ULONG))
            std.math.maxInt(std.os.windows.ULONG)
        else
            @intCast(buf.len);
        const ok = advapi.SystemFunction036(buf.ptr, len);
        // `BOOLEAN` is the typed `Bool(BYTE)` enum in std; `.toBool()` is
        // the correct truthiness test (a raw `!= 0` would compare an enum
        // to an int). Success means the requested `len` bytes were written.
        return if (ok.toBool()) len else 0;
    }

    /// Whether stdin has input ready WITHOUT blocking. Windows has no
    /// `poll`; `WaitForSingleObject(hStdInput, 0)` returns `WAIT_OBJECT_0`
    /// (0) when the handle is signaled — for a console input handle this
    /// means an input record is queued. Any other return (timeout
    /// `WAIT_TIMEOUT`/`0x102`, or `WAIT_FAILED`/`0xFFFFFFFF`) means "not
    /// ready". kernel32 is always linked on Windows. (A console signaled
    /// state can include non-key events; faithfully filtering those needs
    /// `PeekConsoleInput`, the same console-input enrichment deferred with
    /// raw-mode — for the readiness gate the wait is the correct primitive
    /// and never blocks.)
    pub fn pollStdinReady() bool {
        const k = struct {
            extern "kernel32" fn WaitForSingleObject(
                hHandle: std.os.windows.HANDLE,
                dwMilliseconds: std.os.windows.DWORD,
            ) callconv(.winapi) std.os.windows.DWORD;
        };
        const WAIT_OBJECT_0: std.os.windows.DWORD = 0;
        return k.WaitForSingleObject(stdinHandle(), 0) == WAIT_OBJECT_0;
    }

    /// Raw terminal mode. Windows uses `SetConsoleMode` (clearing
    /// `ENABLE_LINE_INPUT`/`ENABLE_ECHO_INPUT`) rather than termios, so
    /// `caps.supports_termios` is `false` and this DEGRADES to a no-op: the
    /// console stays in its default line-buffered mode (input still works;
    /// it is just not character-at-a-time). The `SetConsoleMode` raw-input
    /// backend is the tracked Windows console-mode follow-up, parallel to
    /// the Windows-argv work. A no-op here is the campaign's comptime-
    /// degrade contract, never a compile error.
    pub fn enterRawMode() void {}

    /// Restore from raw mode — a no-op on Windows (see `enterRawMode`).
    pub fn exitRawMode() void {}

    /// Static storage for the most-recent `getEnv` value (the byte `A`
    /// variant writes here). The runtime reads env vars one at a time on
    /// the startup/diagnostic paths and copies anything it needs to keep,
    /// so a single process-static value buffer (single-threaded runtime)
    /// satisfies the "process-lifetime slice" contract without an
    /// allocator. 32 KiB is the documented Windows environment-variable
    /// maximum.
    var env_value_buf: [32 * 1024]u8 = undefined;

    /// Look up environment variable `name` via kernel32
    /// `GetEnvironmentVariableA` (kernel32 is always linked). The name is
    /// copied NUL-terminated into a stack scratch; the value is written
    /// into the process-static `env_value_buf` and returned as a slice of
    /// it. A `0` return means unset (or error); a return `>= buf.len` means
    /// the value did not fit and is treated as unset. The byte (`A`)
    /// variant matches the `[]const u8` contract; a `W`-variant +
    /// WTF-16→UTF-8 transcode is the same deferred work as Windows-argv and
    /// is not needed for ASCII env names/values (the runtime's env keys are
    /// all ASCII, e.g. `ZAP_BACKTRACE`).
    pub fn getEnv(name: []const u8) ?[]const u8 {
        var name_buf: [256]u8 = undefined;
        if (name.len >= name_buf.len) return null;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        const k = struct {
            extern "kernel32" fn GetEnvironmentVariableA(
                lpName: [*:0]const u8,
                lpBuffer: [*]u8,
                nSize: std.os.windows.DWORD,
            ) callconv(.winapi) std.os.windows.DWORD;
        };
        const name_z: [*:0]const u8 = name_buf[0..name.len :0];
        const cap: std.os.windows.DWORD = @intCast(env_value_buf.len);
        const written = k.GetEnvironmentVariableA(name_z, &env_value_buf, cap);
        // `written` excludes the NUL on success; `0` is unset/error; a
        // value `>= cap` means truncation (didn't fit) → treat as unset.
        if (written == 0 or written >= cap) return null;
        return env_value_buf[0..written];
    }
    // ZAP_RUNTIME_OS_BODY_END windows
};

test "windows backend caps use HANDLE and degrade termios" {
    try std.testing.expect(!Backend.caps.supports_termios);
    try std.testing.expectEqual(std.os.windows.HANDLE, Backend.caps.console_handle);
}
