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

    /// Fixed argv cache sizes for the Windows backend. A Windows command
    /// line is capped at 32 767 WTF-16 code units (`CreateProcess`'s
    /// documented `lpCommandLine` limit). Each UTF-8 byte is at most 1.5×
    /// the WTF-16 size for BMP text and never exceeds 4 bytes per code
    /// point, but a per-arg NUL terminator is added, so a 128 KiB byte
    /// buffer is a generous bound that covers the worst-case transcode of
    /// the longest legal command line without an allocator (the runtime's
    /// startup path must not allocate). The argument count is likewise
    /// bounded well above any realistic argv (the same order of magnitude
    /// as the linux `/proc/self/cmdline` cache's 4096-arg table).
    const WINDOWS_ARGV_BUF_SIZE: usize = 128 * 1024;
    const WINDOWS_ARGV_MAX_ARGS: usize = 4096;

    /// Process-static argv cache: the transcoded UTF-8 argument bytes
    /// (each NUL-terminated), the pointer table into them, the count, and
    /// the idempotency flag. argv is immutable process-global, so it is
    /// parsed once on first call and reused thereafter — a process-lifetime
    /// static buffer (leaked-once, never freed), which is the correct free
    /// model for argv and matches the seam contract (the POSIX `_NSGetArgv`
    /// slice and the linux `/proc/self/cmdline` cache are equally
    /// process-lifetime and unfreed).
    var windows_argv_buf: [WINDOWS_ARGV_BUF_SIZE]u8 = undefined;
    var windows_argv_ptrs: [WINDOWS_ARGV_MAX_ARGS][*:0]const u8 = undefined;
    var windows_argv_argc: usize = 0;
    var windows_argv_loaded: bool = false;

    /// Process argv on Windows. The argument vector lives in the PEB as a
    /// single WTF-16 `CommandLine` UNICODE_STRING (the same PEB the
    /// standard-handle accessors read), so argv is recovered by reading
    /// `ProcessParameters.CommandLine` — preferred over `GetCommandLineW`
    /// (no extra kernel32 import; identical bytes) and over
    /// `CommandLineToArgvW` (no shell32 dependency, and the splitter is
    /// then unit-testable on the host without Windows). The slice is
    /// tokenized by `splitCommandLineWtf16` following the documented
    /// `CommandLineToArgvW` quote/backslash rules and each argument is
    /// transcoded WTF-16 → UTF-8 (WTF, not strict UTF-16, so an unpaired
    /// surrogate in a path/arg is preserved rather than rejected) into the
    /// process-static cache. The result is cached on first call (argv is
    /// immutable process-global) and reused thereafter — matching the
    /// linux/wasi backends' idempotent static-cache shape. Deliberately
    /// NOT the mingw `__argv`/`__argc` CRT globals: those are undefined
    /// under Zap's object-based Windows link (`undefined symbol` errors).
    pub fn argv() []const [*:0]const u8 {
        if (windows_argv_loaded) return windows_argv_ptrs[0..windows_argv_argc];
        windows_argv_loaded = true;
        windows_argv_argc = 0;

        // The PEB `CommandLine` is a WTF-16 UNICODE_STRING; `.slice()`
        // yields its `[]const u16` code units (empty if the field is
        // unset). The same `peb()` accessor backs the standard handles.
        const command_line: []const u16 = std.os.windows.peb().ProcessParameters.CommandLine.slice();
        windows_argv_argc = splitCommandLineWtf16(
            command_line,
            &windows_argv_buf,
            &windows_argv_ptrs,
        );
        return windows_argv_ptrs[0..windows_argv_argc];
    }

    /// Tokenize a Windows WTF-16 command line into argv, transcoding each
    /// argument WTF-16 → UTF-8 into `out_bytes` (NUL-terminating each) and
    /// filling `out_ptrs` with `[*:0]const u8` pointers into `out_bytes`.
    /// Returns the argument count (`argc`).
    ///
    /// Pure (PEB-independent) so it is unit-testable on any host with
    /// synthetic WTF-16 input. Faithfully implements the documented
    /// `CommandLineToArgvW` algorithm:
    ///
    ///   * **argv[0]** (the program name) parses by SPECIAL rules:
    ///     backslashes are literal (never escapes), and a `"` simply toggles
    ///     in/out of a quoted region; the token ends at the first unquoted
    ///     whitespace (or the closing quote / end of string).
    ///   * **Subsequent arguments** parse by the backslash/quote rules:
    ///       - `2n` backslashes followed by `"` → `n` literal backslashes and
    ///         the `"` toggles the in-quotes state (the `"` is NOT emitted);
    ///       - `2n+1` backslashes followed by `"` → `n` literal backslashes
    ///         and a LITERAL `"` (the quote is escaped, state unchanged);
    ///       - backslashes NOT followed by `"` are all literal;
    ///       - inside a quoted region, a `""` pair emits ONE literal `"` and
    ///         stays in-quotes (the post-2005 CRT rule);
    ///       - unquoted whitespace (space or tab) separates arguments;
    ///         leading/trailing/repeated separators collapse (no empty args).
    ///   * An empty command line yields `argc == 0`.
    ///
    /// Overflow is bounded, never overrun: if the pointer table or the byte
    /// buffer would overflow, tokenization stops and the arguments parsed so
    /// far are returned (the static cache is sized for the longest legal
    /// Windows command line, so this is a defensive bound, not an expected
    /// path).
    ///
    /// `pub` so the native splitter unit test
    /// (`src/runtime_os/windows_argv_test.zig`, wired into `zig build test`)
    /// can exercise the WTF-16 → UTF-8 quote/backslash parsing on the host
    /// WITHOUT a Windows runtime or wine: the function is pure (PEB-free), so
    /// the host can run it and assert exact argv output. (Inside the spliced
    /// embedded runtime, `pub` on a backend-body helper is harmless — the
    /// body becomes a private `struct` arm of the comptime `RuntimeOs`
    /// switch, never re-exported.)
    pub fn splitCommandLineWtf16(
        command_line: []const u16,
        out_bytes: []u8,
        out_ptrs: [][*:0]const u8,
    ) usize {
        const space: u16 = ' ';
        const tab: u16 = '\t';
        const quote: u16 = '"';
        const backslash: u16 = '\\';

        var argc: usize = 0;
        var write_pos: usize = 0; // next free byte in out_bytes
        var i: usize = 0; // read cursor into command_line

        // Transcode/emit helpers. Content is emitted in maximal RUNS — a
        // contiguous `[]const u16` sub-slice of `command_line` — so a UTF-16
        // surrogate PAIR within a run is transcoded together in a single
        // `wtf16LeToWtf8` call (recombining into a 4-byte sequence). A
        // run is only ever broken by a STRUCTURAL code unit (`"`, the `\`
        // that precedes a `"`, or an unquoted separator), all of which are
        // BMP non-surrogates, so a surrogate pair is never split across runs
        // and each run is independently valid WTF-16. The only synthesized
        // bytes (an escaped literal `\` or `"` from the backslash rule, and
        // the `""`-in-quotes literal `"`) are pure ASCII, emitted directly.
        const Emit = struct {
            /// Transcode the WTF-16 span `units` to WTF-8 and append at
            /// `pos.*`. Returns false on output overflow (the caller then
            /// stops and leaves room for its own NUL terminator). A
            /// zero-length span is a no-op. The exact WTF-8 length is
            /// computed first (`calcWtf8Len`) so the capacity check is
            /// precise and the infallible `wtf16LeToWtf8` — which asserts
            /// the destination is large enough — never trips that assert.
            fn run(bytes: []u8, pos: *usize, units: []const u16) bool {
                if (units.len == 0) return true;
                const needed = std.unicode.calcWtf8Len(units);
                if (pos.* + needed > bytes.len) return false;
                const n = std.unicode.wtf16LeToWtf8(bytes[pos.*..], units);
                pos.* += n;
                return true;
            }

            /// Append a single ASCII byte at `pos.*`. Returns false on
            /// overflow.
            fn byte(bytes: []u8, pos: *usize, b: u8) bool {
                if (pos.* >= bytes.len) return false;
                bytes[pos.*] = b;
                pos.* += 1;
                return true;
            }
        };

        // ---- argv[0]: program name (special quoting; backslash literal) ---
        // Per CommandLineToArgvW, argv[0] is only parsed when the command
        // line is non-empty; an all-whitespace or empty line yields no args.
        // Skip leading whitespace first (CommandLineToArgvW tolerates it).
        while (i < command_line.len and (command_line[i] == space or command_line[i] == tab)) : (i += 1) {}

        if (i < command_line.len) {
            if (argc >= out_ptrs.len or write_pos >= out_bytes.len) return argc;
            const arg0_start = write_pos;
            var in_quotes = false;
            var overflowed0 = false;
            while (i < command_line.len) {
                const c = command_line[i];
                if (c == quote) {
                    in_quotes = !in_quotes;
                    i += 1;
                    continue;
                }
                if (!in_quotes and (c == space or c == tab)) break;
                // Maximal content run up to the next structural unit
                // (quote, or — when unquoted — a separator). Backslash is
                // literal in argv[0], so it does NOT break a run.
                const run_start = i;
                while (i < command_line.len) : (i += 1) {
                    const r = command_line[i];
                    if (r == quote) break;
                    if (!in_quotes and (r == space or r == tab)) break;
                }
                if (!Emit.run(out_bytes, &write_pos, command_line[run_start..i])) {
                    overflowed0 = true;
                    break;
                }
            }
            if (overflowed0) return argc;
            // NUL-terminate argv[0].
            if (write_pos >= out_bytes.len) return argc;
            out_bytes[write_pos] = 0;
            out_ptrs[argc] = out_bytes[arg0_start..write_pos :0];
            argc += 1;
            write_pos += 1;
        }

        // ---- argv[1..]: backslash/quote rules ----------------------------
        while (true) {
            // Skip separators between arguments.
            while (i < command_line.len and (command_line[i] == space or command_line[i] == tab)) : (i += 1) {}
            if (i >= command_line.len) break;

            if (argc >= out_ptrs.len or write_pos >= out_bytes.len) break;
            const arg_start = write_pos;
            var in_quotes = false;
            var overflowed = false;

            scan_arg: while (i < command_line.len) {
                const c = command_line[i];

                if (c == backslash) {
                    // Count the run of backslashes.
                    const bs_start = i;
                    while (i < command_line.len and command_line[i] == backslash) : (i += 1) {}
                    const nbackslash = i - bs_start;
                    if (i < command_line.len and command_line[i] == quote) {
                        // `2n` backslashes → n literal `\`, quote toggles;
                        // `2n+1` → n literal `\`, then a literal `"`. The
                        // backslashes are ASCII, emitted directly.
                        var k: usize = 0;
                        while (k < nbackslash / 2) : (k += 1) {
                            if (!Emit.byte(out_bytes, &write_pos, '\\')) {
                                overflowed = true;
                                break :scan_arg;
                            }
                        }
                        if (nbackslash % 2 == 1) {
                            // Escaped quote: emit a literal `"`, consume it.
                            if (!Emit.byte(out_bytes, &write_pos, '"')) {
                                overflowed = true;
                                break :scan_arg;
                            }
                            i += 1; // consume the `"`
                        } else {
                            // Even backslashes: the quote is structural.
                            in_quotes = !in_quotes;
                            i += 1; // consume the `"`
                        }
                    } else {
                        // Backslashes not followed by a quote are all literal.
                        var k: usize = 0;
                        while (k < nbackslash) : (k += 1) {
                            if (!Emit.byte(out_bytes, &write_pos, '\\')) {
                                overflowed = true;
                                break :scan_arg;
                            }
                        }
                    }
                    continue;
                }

                if (c == quote) {
                    if (in_quotes and i + 1 < command_line.len and command_line[i + 1] == quote) {
                        // `""` inside quotes → one literal `"`, stay in-quotes.
                        if (!Emit.byte(out_bytes, &write_pos, '"')) {
                            overflowed = true;
                            break :scan_arg;
                        }
                        i += 2;
                        continue;
                    }
                    in_quotes = !in_quotes;
                    i += 1;
                    continue;
                }

                if (!in_quotes and (c == space or c == tab)) break :scan_arg;

                // Maximal content run up to the next structural unit
                // (backslash, quote, or — when unquoted — a separator).
                const run_start = i;
                while (i < command_line.len) : (i += 1) {
                    const r = command_line[i];
                    if (r == backslash or r == quote) break;
                    if (!in_quotes and (r == space or r == tab)) break;
                }
                if (!Emit.run(out_bytes, &write_pos, command_line[run_start..i])) {
                    overflowed = true;
                    break :scan_arg;
                }
            }

            if (overflowed) break;

            // NUL-terminate this argument.
            if (write_pos >= out_bytes.len) break;
            out_bytes[write_pos] = 0;
            out_ptrs[argc] = out_bytes[arg_start..write_pos :0];
            argc += 1;
            write_pos += 1;
        }

        return argc;
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

    // ---- Domain B: crash handling / backtrace / VEH (Phase D) ------------
    //
    // Windows has no POSIX signal model — hardware faults arrive through
    // Vectored Exception Handling. `installCrashHandlers` registers a VEH
    // with `RtlAddVectoredExceptionHandler`; the handler maps the
    // `EXCEPTION_RECORD.ExceptionCode` to the SAME Zap crash-kind atom the
    // POSIX `signalKind` path produces, builds the unwinder context from the
    // `EXCEPTION_POINTERS.ContextRecord` via the fork's
    // `cpu_context.fromWindowsContext` (symmetric to POSIX's
    // `fromPosixSignalContext`), captures the backtrace, and routes to the
    // runtime's shared portable crash sink (`crashFromFault`). Symbolization
    // flows through std's `SelfInfo` PE/PDB path (degrades to raw addresses
    // when `SelfInfo == void` or no PDB is present — address-level reporting,
    // which is the documented Phase-D Windows v1 bar). The crash REPORT
    // renderers themselves are unchanged and target-agnostic.

    /// No meaningful ASLR-slide story to thread into the offline-resolution
    /// fallback on Windows: the report's de-slide subtraction is the
    /// identity (0), so the no-symbol fallback prints the raw runtime
    /// address. std's `SelfInfo` keys symbolization against the module's own
    /// loaded base, so symbolized frames are unaffected. (A
    /// `GetModuleHandleW(null)`-based PE-base story for the addr2line
    /// fallback is a tracked Windows-symbolization follow-up.)
    pub fn imageSlide() usize {
        return 0;
    }

    /// Terminate the process IMMEDIATELY with `code`, running NO `atexit` /
    /// CRT / DLL-detach handlers — the Windows analog of the POSIX `_exit`
    /// the crash path uses. `TerminateProcess(GetCurrentProcess(), code)` is
    /// the most direct kill available from a VEH context (unlike
    /// `ExitProcess`, which runs loader detach + CRT atexit and is therefore
    /// not safe from a half-destroyed crash context). kernel32 is always
    /// linked on Windows.
    pub fn abortProcess(code: u8) noreturn {
        const k = struct {
            extern "kernel32" fn GetCurrentProcess() callconv(.winapi) std.os.windows.HANDLE;
            extern "kernel32" fn TerminateProcess(
                hProcess: std.os.windows.HANDLE,
                uExitCode: std.os.windows.UINT,
            ) callconv(.winapi) std.os.windows.BOOL;
        };
        _ = k.TerminateProcess(k.GetCurrentProcess(), code);
        // `TerminateProcess` on the current process does not return; satisfy
        // the `noreturn` contract for the verifier.
        unreachable;
    }

    /// Windows NTSTATUS exception codes not (yet) re-exported by the fork's
    /// `std.os.windows`. These are stable, documented Win32 constants
    /// (`winnt.h`); declaring them here keeps the backend self-contained
    /// without a fork edit. `EXCEPTION_ACCESS_VIOLATION`,
    /// `EXCEPTION_ILLEGAL_INSTRUCTION`, `EXCEPTION_STACK_OVERFLOW`, and
    /// `EXCEPTION_DATATYPE_MISALIGNMENT` ARE in std and are used from there.
    const EXCEPTION_BREAKPOINT: u32 = 0x80000003;
    const EXCEPTION_INT_DIVIDE_BY_ZERO: u32 = 0xC0000094;
    const EXCEPTION_INT_OVERFLOW: u32 = 0xC0000095;
    const EXCEPTION_FLT_DIVIDE_BY_ZERO: u32 = 0xC000008E;
    const EXCEPTION_FLT_OVERFLOW: u32 = 0xC0000091;
    const EXCEPTION_FLT_UNDERFLOW: u32 = 0xC0000093;
    const EXCEPTION_FLT_INVALID_OPERATION: u32 = 0xC0000090;
    const EXCEPTION_PRIV_INSTRUCTION: u32 = 0xC0000096;

    /// Map a Windows exception code to its Zap crash-report kind atom — the
    /// SAME snake_case kinds the POSIX `signalKind` produces, so a Windows
    /// crash report and a POSIX crash report name the fault identically:
    ///   * access violation / stack overflow → `segmentation_fault`
    ///     (a wild/overflowing memory access — the SIGSEGV analog)
    ///   * datatype misalignment            → `bus_error` (SIGBUS analog)
    ///   * integer/float divide, overflow, invalid op → `arithmetic_error`
    ///     (the SIGFPE analog, matching `ZapPanic`'s arithmetic kinds)
    ///   * illegal / privileged instruction → `illegal_instruction`
    ///   * breakpoint                       → `trap` (SIGTRAP analog)
    /// Returns `null` for any other code, so the VEH continues the search
    /// (the exception was not one this handler claims).
    fn exceptionKind(code: u32) ?[]const u8 {
        const windows = std.os.windows;
        return switch (code) {
            windows.EXCEPTION_ACCESS_VIOLATION, windows.EXCEPTION_STACK_OVERFLOW => "segmentation_fault",
            windows.EXCEPTION_DATATYPE_MISALIGNMENT => "bus_error",
            EXCEPTION_INT_DIVIDE_BY_ZERO,
            EXCEPTION_INT_OVERFLOW,
            EXCEPTION_FLT_DIVIDE_BY_ZERO,
            EXCEPTION_FLT_OVERFLOW,
            EXCEPTION_FLT_UNDERFLOW,
            EXCEPTION_FLT_INVALID_OPERATION,
            => "arithmetic_error",
            windows.EXCEPTION_ILLEGAL_INSTRUCTION, EXCEPTION_PRIV_INSTRUCTION => "illegal_instruction",
            EXCEPTION_BREAKPOINT => "trap",
            else => null,
        };
    }

    /// A human-readable description of the fault for the report's message
    /// slot, mirroring the POSIX `signalMessage` wording where the faults
    /// correspond so the two surfaces read alike.
    fn exceptionMessage(code: u32) []const u8 {
        const windows = std.os.windows;
        return switch (code) {
            windows.EXCEPTION_ACCESS_VIOLATION => "segmentation fault (invalid memory access)",
            windows.EXCEPTION_STACK_OVERFLOW => "stack overflow",
            windows.EXCEPTION_DATATYPE_MISALIGNMENT => "bus error (misaligned memory access)",
            EXCEPTION_INT_DIVIDE_BY_ZERO, EXCEPTION_FLT_DIVIDE_BY_ZERO => "division by zero",
            EXCEPTION_INT_OVERFLOW => "integer overflow",
            EXCEPTION_FLT_OVERFLOW, EXCEPTION_FLT_UNDERFLOW, EXCEPTION_FLT_INVALID_OPERATION => "arithmetic exception",
            windows.EXCEPTION_ILLEGAL_INSTRUCTION => "illegal instruction",
            EXCEPTION_PRIV_INSTRUCTION => "privileged instruction",
            EXCEPTION_BREAKPOINT => "trace/breakpoint trap",
            else => "fatal signal",
        };
    }

    /// Windows backtrace capture from a fault context can use the fork's
    /// `SelfInfo`-aware unwinder when `cpu_context` resolves to a real type
    /// for this target; on a target where the fork has no Windows unwinder
    /// (`cpu_context.Native == noreturn`) the VEH still installs and emits an
    /// address-less header (the Phase-D degrade). This gate mirrors the
    /// POSIX `signal_handlers_supported`, minus the segfault-handling term
    /// (which is POSIX-specific).
    const context_unwind_supported = std.debug.cpu_context.Native != noreturn;

    /// Windows can always intercept hardware faults via VEH (it has no
    /// `cpu_context`-dependent install step the way POSIX `sigaction` is
    /// gated), so fault handlers are supported even when symbolization /
    /// context unwinding is not — the report then degrades to the
    /// address-less header. The `runtime.zig` call site reads this.
    pub const supports_fault_handlers: bool = true;

    var veh_handle: ?std.os.windows.LPVOID = null;

    /// The Vectored Exception Handler. Fires for EVERY exception raised in
    /// the process, so it claims ONLY the hardware-fault codes
    /// `exceptionKind` recognizes and returns `EXCEPTION_CONTINUE_SEARCH`
    /// for everything else (letting the program's own `__try`/SEH or the
    /// default handler run). For a claimed fault it captures the backtrace
    /// from the `ContextRecord` and routes to the runtime's portable crash
    /// sink, which terminates via `abortProcess` — so this path is
    /// `noreturn` for a claimed fault and never actually returns a
    /// disposition in that case (the `c_long` return type is the VEH ABI).
    fn vehHandler(info: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
        const code = info.ExceptionRecord.ExceptionCode;
        const kind = exceptionKind(code) orelse return std.os.windows.EXCEPTION_CONTINUE_SEARCH;
        const message = exceptionMessage(code);

        // A report is already underway (a fault re-entered the printer, or a
        // sibling fatal exception beat it here): divert to the minimal abort
        // BEFORE the context read/unwind, which can themselves fault.
        if (crashReportInProgress()) doubleFaultAbort();

        if (comptime context_unwind_supported) {
            // `fromWindowsContext` returns a by-value `cpu_context.Native`;
            // bind it so the unwinder can take its address. The saved PC
            // seeds the first frame, so the trace begins at the faulting
            // instruction, not this VEH trampoline (symmetric to the POSIX
            // `fromPosixSignalContext` path).
            const ctx_local = std.debug.cpu_context.fromWindowsContext(info.ContextRecord);
            const bt = captureFaultBacktrace(&ctx_local);
            crashFromFault(kind, message, bt);
        }

        // No usable unwinder for this target: still emit the unified header
        // (address-less) so the fault is reported in the Zap format.
        crashFromFault(kind, message, emptyBacktrace());
    }

    /// Install the Vectored Exception Handler for hardware faults.
    /// Idempotent. `First = 1` (TRUE) registers the handler at the FRONT of
    /// the VEH chain so the Zap crash report fires before any later-added
    /// handler. kernel32/ntdll are always linked on Windows.
    pub fn installCrashHandlers() void {
        if (veh_handle != null) return;
        veh_handle = std.os.windows.ntdll.RtlAddVectoredExceptionHandler(1, vehHandler);
    }
    // ZAP_RUNTIME_OS_BODY_END windows
};

// Standalone stubs for the crash-handler seam↔runtime contract. The spliced
// body (between the BODY sentinels) calls back into these `runtime.zig`
// top-level symbols — the portable crash-report sink, the double-fault guard,
// and the `Backtrace` capture primitive — which are in scope where the body is
// spliced. For the standalone compile-check build (`zig build test` building
// this file via `Backend = struct{}` for `x86_64-windows-gnu`) the same names
// must exist, so these minimal stubs stand in; the splice never sees them
// (they live outside the sentinels). The production code is in `runtime.zig`.
const StubBacktrace = extern struct { addresses: [1]usize, len: usize };
fn crashReportInProgress() bool {
    return false;
}
fn doubleFaultAbort() noreturn {
    Backend.abortProcess(137);
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
    Backend.abortProcess(1);
}

test "windows backend caps use HANDLE and degrade termios" {
    try std.testing.expect(!Backend.caps.supports_termios);
    try std.testing.expectEqual(std.os.windows.HANDLE, Backend.caps.console_handle);
}
