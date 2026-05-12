const std = @import("std");
const builtin = @import("builtin");

/// The active memory manager's Zig source registered alongside this
/// runtime in the user-binary build. For first-party managers this
/// resolves to the actual manager source (so Phase 4's comptime branches
/// can call directly into the manager's hot paths and let LLVM inline
/// through the boundary); for third-party managers it resolves to a
/// stub registered by `compiler.getActiveManagerSourceBytes`, and the
/// runtime's `.third_party` comptime branch routes through the vtable
/// instead so the stub's symbols are never referenced.
///
/// The host test build (which loads `runtime.zig` as a Zig module via
/// `zig build test`) registers the same stub against this name through
/// `build.zig`'s `addAnonymousImport`, so the import resolves cleanly
/// in both contexts — there is no `if (builtin.is_test)` conditional
/// around the import itself. Zig 0.16 does NOT elide top-level
/// `@import` declarations during semantic analysis even when the bound
/// name is unused, so a missing registration would surface as a
/// "module not found" error at every user-binary compile.
const active_manager = @import("zap_active_manager");

/// Read an environment variable for a runtime-known name. The runtime
/// can't `@import("env.zig")` because runtime.zig is injected into Zap
/// binaries as standalone source — it has no sibling files in the
/// emission cache. Mirrors `src/env.zig`'s helper for the runtime side.
fn envGetRuntime(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const name_z: [*:0]const u8 = buf[0..name.len :0];
    const ptr = std.c.getenv(name_z) orelse return null;
    return std.mem.span(ptr);
}

const STDOUT_FD = std.posix.STDOUT_FILENO;
const STDERR_FD = std.posix.STDERR_FILENO;
const STDIN_FD = std.posix.STDIN_FILENO;

// Well-known atom IDs — must match the registration order in initGlobalAtomTable
// and AtomTable.init: nil=0, true=1, false=2, ok=3, error=4, cont=5, halt=6, done=7
pub const ATOM_CONT: u32 = 5;
pub const ATOM_HALT: u32 = 6;
pub const ATOM_DONE: u32 = 7;

fn posixWrite(fd: std.posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes[written..].ptr, bytes[written..].len);
        if (rc <= 0) break;
        written += @intCast(rc);
    }
}

fn posixRead(fd: std.posix.fd_t, buf: []u8) usize {
    return std.posix.read(fd, buf) catch 0;
}

// ============================================================
// Buffered stdout
//
// Every "write a single byte / small chunk to stdout" path used to
// hit `std.c.write(1, …)` directly; for byte-streamed output (e.g.
// the `mandelbrot` benchmark, which writes ~64 M bytes at N=8000)
// that's one syscall per byte. Adding a 64 KiB user-space buffer
// turns it into one syscall per ~64 KiB, matching the cost shape
// of libc's FILE buffer for stdout in C / Rust / Go / OCaml.
//
// Single-threaded by design — the buffer is a process-global byte
// array. Zap programs are single-threaded today; if that changes,
// guarding `stdout_buf_pos` with a mutex is the only addition
// needed (the buffer body has no aliasing concerns).
//
// `flushStdoutBuf()` is invoked:
//   * automatically at process exit via `atexit` (registered
//     lazily on first write);
//   * before every `gets()` so prompts ship before the read blocks;
//   * before every stderr write so error messages don't appear
//     out of order with respect to in-flight stdout content.
// All stderr writes still bypass the buffer — errors must be
// observable even if the program crashes mid-buffer.
const STDOUT_BUF_SIZE: usize = 64 * 1024;
var stdout_buf: [STDOUT_BUF_SIZE]u8 = undefined;
var stdout_buf_pos: usize = 0;
var stdout_atexit_registered: bool = false;

fn flushStdoutBuf() void {
    if (stdout_buf_pos == 0) return;
    var written: usize = 0;
    while (written < stdout_buf_pos) {
        const remaining = stdout_buf_pos - written;
        const rc = std.c.write(STDOUT_FD, stdout_buf[written..].ptr, remaining);
        if (rc <= 0) break;
        written += @intCast(rc);
    }
    stdout_buf_pos = 0;
}

/// Atexit handler: flushes the buffered stdout byte buffer through a
/// direct `write(2)` syscall. Does NOT perform any ARC dispatch
/// (`allocAny` / `freeAny` / `retainAny` / `releaseAny` /
/// `headerRetain` / `headerRelease`), so it is safe to run AFTER
/// `zapMemoryShutdownAtexit`. See the ordering contract on
/// `zapMemoryShutdownAtexit` for details.
fn stdoutAtexitFlush() callconv(.c) void {
    flushStdoutBuf();
}

// `std.c.atexit` isn't part of the public `std.c` surface in Zig
// 0.16; declare the libc symbol directly. Zap binaries link libc
// unconditionally (`main.zig` builds with `link_libc = true`).
extern "c" fn atexit(handler: *const fn () callconv(.c) void) c_int;

fn ensureStdoutAtexit() void {
    if (stdout_atexit_registered) return;
    stdout_atexit_registered = true;
    _ = atexit(stdoutAtexitFlush);
}

/// Write a slice of bytes to the buffered stdout, flushing once when
/// the slice is larger than the remaining buffer space. Slices
/// larger than the whole buffer bypass the buffer entirely (one
/// syscall) after flushing what was already pending — matches libc's
/// behaviour for over-buffer writes and avoids splitting a single
/// large user request across multiple syscalls when the buffer
/// wouldn't add value.
fn stdoutBufferedWrite(bytes: []const u8) void {
    ensureStdoutAtexit();
    if (bytes.len >= STDOUT_BUF_SIZE) {
        flushStdoutBuf();
        posixWrite(STDOUT_FD, bytes);
        return;
    }
    if (bytes.len > STDOUT_BUF_SIZE - stdout_buf_pos) {
        flushStdoutBuf();
    }
    @memcpy(stdout_buf[stdout_buf_pos..][0..bytes.len], bytes);
    stdout_buf_pos += bytes.len;
}

fn stdoutBufferedWriteByte(byte: u8) void {
    ensureStdoutAtexit();
    if (stdout_buf_pos == STDOUT_BUF_SIZE) flushStdoutBuf();
    stdout_buf[stdout_buf_pos] = byte;
    stdout_buf_pos += 1;
}

/// Flush stdout, then write to stderr unbuffered. Use this for any
/// runtime panic / halt / error path so an error message doesn't
/// race ahead of buffered stdout output the user already produced —
/// particularly important when the program is about to abort and
/// `atexit` may not run.
fn stderrWriteFlushed(bytes: []const u8) void {
    flushStdoutBuf();
    posixWrite(STDERR_FD, bytes);
}

// ============================================================
// Buffered stdin
//
// `IO.gets()`, `IO.get_char()`, and `IO.try_get_char()` used to call
// `read(STDIN_FD, &one_byte_buf, 1)` once per byte. On a workload like
// k-nucleotide — which streams 2.5 MB of FASTA through `IO.gets()` one
// line at a time — that's ~2.5 million syscalls, each carrying a kernel-
// boundary crossing cost of roughly 200–500 ns. Even on the line-oriented
// path the per-character read loop dominated runtime, leaving < 30 %
// for the actual k-mer counting logic.
//
// This buffer turns those reads into one `read()` per ~64 KiB. All three
// stdin entry points share the buffer so the FD position stays
// consistent regardless of which mix of line- and character-oriented
// reads the program makes. `try_get_char()` still honours its
// non-blocking contract: it returns buffered bytes first when any are
// available; only when the buffer is empty does it consult `poll()` and
// (if ready) perform a refill.
//
// Single-threaded by design — Zap programs are single-threaded today,
// and stdin reads are inherently sequential. If multi-threaded stdin
// access becomes a requirement, a mutex around the buffer fields is the
// only addition needed.
// ============================================================
const STDIN_BUF_SIZE: usize = 64 * 1024;
var stdin_buf: [STDIN_BUF_SIZE]u8 = undefined;
var stdin_buf_pos: usize = 0;
var stdin_buf_len: usize = 0;
var stdin_eof: bool = false;

/// Refill the stdin buffer from the FD. Returns the number of bytes now
/// available. On EOF this sets the sticky `stdin_eof` flag so subsequent
/// reads don't keep issuing zero-result syscalls; the buffer pos/len
/// fields are unchanged on EOF (callers see len-pos == 0).
fn stdinRefill() usize {
    if (stdin_eof) return 0;
    stdin_buf_pos = 0;
    stdin_buf_len = 0;
    const n = posixRead(STDIN_FD, stdin_buf[0..STDIN_BUF_SIZE]);
    if (n == 0) {
        stdin_eof = true;
        return 0;
    }
    stdin_buf_len = n;
    return n;
}

/// Return the number of bytes currently sitting in the stdin buffer,
/// without refilling.
inline fn stdinBuffered() usize {
    return stdin_buf_len - stdin_buf_pos;
}

/// Read a single byte from the buffered stdin. Returns `null` on EOF
/// (sticky once observed). Refills the buffer on demand.
fn stdinReadByte() ?u8 {
    if (stdinBuffered() == 0) {
        if (stdinRefill() == 0) return null;
    }
    const b = stdin_buf[stdin_buf_pos];
    stdin_buf_pos += 1;
    return b;
}

/// Platform-portable access to process argv (replacement for removed getArgv() in 0.16).
pub fn getArgv() []const [*:0]const u8 {
    if (comptime builtin.os.tag == .macos) {
        const c = struct {
            extern "c" fn _NSGetArgc() *c_int;
            extern "c" fn _NSGetArgv() *[*]const [*:0]const u8;
        };
        const argc: usize = @intCast(c._NSGetArgc().*);
        const argv = c._NSGetArgv().*;
        return argv[0..argc];
    } else if (comptime builtin.os.tag == .linux) {
        // On Linux, use /proc/self/cmdline as fallback or linker-provided __libc_argv.
        const c = struct {
            extern "c" var __libc_argc: c_int;
            extern "c" var __libc_argv: [*]const [*:0]const u8;
        };
        const argc: usize = @intCast(c.__libc_argc);
        return c.__libc_argv[0..argc];
    } else {
        return &.{};
    }
}

/// Write formatted output to stdout through the buffered writer.
fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stdoutBufferedWrite(msg);
}

/// Write raw bytes to stdout through the buffered writer.
fn stdoutWrite(bytes: []const u8) void {
    stdoutBufferedWrite(bytes);
}

// ============================================================
// Arena Allocator
// Uses std.heap.ArenaAllocator backed by c_allocator (libc malloc).
// Thread-safe and lock-free in Zig 0.16. Init is cheap (no
// allocation until first use), so no lazy initialization needed.
//
// Backed by `c_allocator` rather than `page_allocator` so the
// arena's internal `rawResize` calls can succeed when libc's
// view of block capacity (`malloc_usable_size`) shows slack. On
// macOS the `page_allocator`'s `rawResize` is hard-wired to
// `false` (no `mremap` available), so every arena grow used to
// orphan a previously-allocated node in `buffer_list`, pinning it
// for the rest of the program. With libc malloc, the arena can
// extend its current node when malloc's size-class has room, and
// freed arena nodes return to malloc's free list (where their
// pages become reusable for subsequent allocations) rather than
// staying mmap'd as orphaned page-allocator regions.
//
// This also enables the `String.concat` `Allocator.resize` fast
// path (which extends the most-recent arena allocation in place
// rather than allocating a fresh `a.len + b.len` buffer) to
// succeed across the arena's geometric-doubling boundaries when
// the current libc block carries slack from the previous size
// class. See `tryArenaExtend` and `String.concat` below.
// ============================================================

var runtime_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.c_allocator);

// Terminal mode state for raw/normal switching
var original_termios: std.posix.termios = undefined;
var raw_mode_saved: bool = false;

// ============================================================
// bumpAlloc instrumentation
//
// Tracks total bytes and per-callsite breakdown for arena allocations.
// Gated by env var `ZAP_BUMP_STATS=1` for emission; counters always
// update so the cost is one branchless atomic-free add per call. The
// arena on macOS lacks `mremap`, so old arena nodes pin until process
// exit — total bytes allocated equals (or exceeds) peak RSS contribution,
// and the per-callsite breakdown identifies which path produced the
// pages that never get freed.
// ============================================================

pub var bump_bytes_total: u64 = 0;
pub var bump_calls_total: u64 = 0;

/// Per-callsite breakdown. The tag enum corresponds to logical
/// allocation classes — adjust if a new high-volume callsite needs
/// distinct tracking.
pub const BumpSite = enum(u8) {
    other = 0,
    string_concat = 1,
    string_upcase = 2,
    string_downcase = 3,
    string_reverse = 4,
    string_replace = 5,
    string_pad_leading = 6,
    string_pad_trailing = 7,
    string_repeat = 8,
    string_capitalize = 9,
    string_split = 10,
    string_join = 11,
    interpolate_int = 12,
    interpolate_float = 13,
    integer_to_string = 14,
    float_to_string = 15,
    float_to_string_precision = 16,
    io_gets = 17,
    io_try_get_char = 18,
    io_get_char = 19,
    file_read = 20,
    path_join = 21,
    system_cwd = 22,
    system_get_env = 23,
    vector_sort = 24,
    list_concat_outer = 25,
    misc_slice = 26,
};

const BUMP_SITE_COUNT: usize = @typeInfo(BumpSite).@"enum".fields.len;

pub var bump_site_bytes: [BUMP_SITE_COUNT]u64 = .{0} ** BUMP_SITE_COUNT;
pub var bump_site_calls: [BUMP_SITE_COUNT]u64 = .{0} ** BUMP_SITE_COUNT;

inline fn recordBump(site: BumpSite, len: usize) void {
    bump_bytes_total += @as(u64, len);
    bump_calls_total += 1;
    const idx: usize = @intFromEnum(site);
    bump_site_bytes[idx] += @as(u64, len);
    bump_site_calls[idx] += 1;
}

fn bumpAlloc(len: usize) []u8 {
    // Use alignedAlloc with pointer alignment (8 on 64-bit) so that bump-allocated
    // memory can safely be cast to pointer types via @ptrCast(@alignCast(...)).
    const aligned = runtime_arena.allocator().alignedAlloc(u8, .@"8", len) catch return &.{};
    recordBump(.other, len);
    return @alignCast(aligned);
}

fn bumpAllocAt(comptime site: BumpSite, len: usize) []u8 {
    const aligned = runtime_arena.allocator().alignedAlloc(u8, .@"8", len) catch return &.{};
    recordBump(site, len);
    return @alignCast(aligned);
}

fn bumpAllocSlice(comptime T: type, len: usize) []T {
    const slice = runtime_arena.allocator().alloc(T, len) catch return &.{};
    recordBump(.other, len * @sizeOf(T));
    return slice;
}

/// Try to extend an arena allocation in place. Returns true on success;
/// the slice's underlying buffer now has `new_len` bytes available
/// (callers may treat `slice.ptr[0..new_len]` as a valid slice). Returns
/// false when the arena has no nodes yet, when `slice` is not the
/// most-recent allocation in the arena's current node (which includes
/// the case where `slice` lives in `.rodata` / a different allocator
/// entirely — the inner address check rejects those), or when the
/// current node has no spare capacity for the extension.
///
/// Guards the `runtime_arena.allocator().resize` call against the
/// stdlib's panic-on-null-first-node behaviour (`loadFirstNode().?`
/// inside `ArenaAllocator.resize`). Without this guard, calling
/// `String.concat("literal_a", "literal_b")` before any other arena
/// allocation has happened would panic because `used_list` is still
/// null. Once the arena has at least one node, the inner `resize`
/// safely returns `false` for non-tail / out-of-arena slices via its
/// own address comparison against `node.end_index`.
fn tryArenaExtend(slice: []const u8, new_len: usize) bool {
    if (runtime_arena.state.used_list == null) return false;
    return runtime_arena.allocator().resize(@constCast(slice), new_len);
}

pub fn resetAllocator() void {
    runtime_arena.reset(.retain_capacity);
}

// ============================================================
// Zap Runtime Support Struct (spec §21, §31.7)
//
// Provides runtime types for generated Zig code:
//   - Arc(T)       — generic ARC wrapper with atomic refcount
//   - Atom         — interned atom representation
//   - Closure      — fat pointer for function values
//   - ZapAllocator — allocator plumbing
//   - List(T)      — flat-buffer sequence
//   - Map(K, V)    — persistent map (HAMT-based)
//   - String       — owned string with length
// ============================================================

// ============================================================
// Map workload instrumentation comptime flag
//
// `instrument_map` is a comptime-known boolean that gates the entire
// Map(K, V) instrumentation overlay (see `docs/map-workload-
// instrumentation-plan.md`). When false, every hook compiles to nothing
// and the runtime is bit-identical to the un-instrumented build. When
// true, allocMap/retain/release/put/delete/merge/get hooks emit per-
// instance and per-lineage records, and an `atexit` handler writes a
// JSON summary to `$ZAP_INSTRUMENT_OUT` (default
// `./map-instrumentation.json`).
//
// Resolution order:
//   1. The build-system root (the compiler binary built by `zig build`)
//      can override the flag by declaring
//      `pub const zap_runtime_instrument_map_override: bool = ...;`.
//      `src/root.zig` re-exports the `-Dinstrument-map` build option
//      under that name, so a `zig build -Dinstrument-map=true` flips
//      the flag on for the host test suite.
//   2. The embedded-runtime root (a Zap user binary) does not declare
//      that override, so the flag falls back to the source-level
//      `INSTRUMENT_MAP_DEFAULT` constant. `compiler.zig` rewrites that
//      default at source-registration time when the host compiler was
//      itself built with `-Dinstrument-map=true`, so user binaries
//      inherit the flag from the toolchain build.
// ============================================================

const INSTRUMENT_MAP_DEFAULT: bool = false;

pub const instrument_map: bool = blk: {
    const root = @import("root");
    if (@hasDecl(root, "zap_runtime_instrument_map_override")) {
        break :blk @as(bool, root.zap_runtime_instrument_map_override);
    }
    break :blk INSTRUMENT_MAP_DEFAULT;
};

// ============================================================
// Phase 6 — ARC stat-counter collection comptime flag
//
// Every `retainAny` / `releaseAny` / `headerRetain` / `headerRelease`
// dispatcher historically unconditionally bumped a global `u64`
// counter (`arc_retains_total`, `arc_releases_total`,
// `arc_consumes_total`, `arc_return_elisions_total`). The store costs
// one memory write per ARC op — at ~600 M ops in the binarytrees
// benchmark this adds ~0.5-1.0s of measured overhead under no observer.
//
// `collect_arc_stats` gates every counter store behind
// `if (comptime collect_arc_stats) ...` so the store is dead-code-
// eliminated in release user binaries. Tests in `runtime.zig`'s test
// block depend on the counters reflecting real op counts and so the
// host-correct default below is `true` when `builtin.is_test`.
//
// Resolution:
//   * The source-level `COLLECT_ARC_STATS_DEFAULT` constant defaults
//     to `builtin.is_test`, so the host test suite (which loads
//     `runtime.zig` as a Zig module under `zig build test`) keeps the
//     counter increments — every existing counter-delta assertion in
//     the test block continues to observe per-op increments. Production
//     Zap user binaries have `builtin.is_test == false`, so the
//     embedded runtime resolves to `false` and the LLVM DCE pass elides
//     every counter store.
//
// `@import("root")` is intentionally NOT used here for the same reason
// as `runtime_declared_caps`: Zig 0.16's test runner makes
// `@import("root")` resolve to its own root in test builds, so a
// `root.zig` override would not be visible to runtime tests. The
// host-correct `builtin.is_test` default solves the same problem
// without the `@hasDecl` fragility.
//
// `noteConsume` / `noteReturnElision` are emitted by the compiler as
// explicit ZIR calls (not inline) and ARE gated by this flag — the
// counter store inside each function is dead-code-eliminated in
// release builds, leaving only the ensureArcStatsAtexit() guard
// (which is itself a single boolean compare after the first call).
// ============================================================

const COLLECT_ARC_STATS_DEFAULT: bool = builtin.is_test;

pub const collect_arc_stats: bool = COLLECT_ARC_STATS_DEFAULT;

// ============================================================
// Phase 6 — Active manager capability bitmask exposed to runtime
//
// Each Zap binary is compiled with exactly one memory manager whose
// `.zapmem` section declares a `declared_caps` bitmask (spec §3.5 /
// §7). Phase 6 makes that bitmask comptime-visible inside `runtime.zig`
// so the inline-header types (`Map(K,V)`, `List(T)`, `MapIter(K,V)`)
// can drop their `ArcHeader` field under managers that do not declare
// `REFCOUNT_V1`, and so the runtime's internal retain/release hot
// paths can comptime-elide their dispatch.
//
// Resolution:
//   * The source-level `RUNTIME_DECLARED_CAPS_DEFAULT` constant
//     defaults to `REFCOUNT_V1_BIT` so the host test suite (which
//     pulls `runtime.zig` in as a Zig module without going through
//     the user-binary `@embedFile` rewrite) sees the full inline-
//     header layout and the existing retain/release semantics — a
//     `Zap.Memory.ARC` build, byte-for-byte.
//   * For each Zap user binary, `compiler.getRuntimeSource(caps)`
//     rewrites the literal to the resolved manager's `declared_caps`
//     before injecting the source into the build. A binary that
//     selects `Zap.Memory.Arena` or `Zap.Memory.NoOp` therefore sees
//     `RUNTIME_DECLARED_CAPS_DEFAULT == 0`, which collapses
//     `refcount_v1_active` to `false` and drops the inline header
//     plus every internal retain/release dispatch.
//
// `@import("root")` is intentionally NOT used here. Zig 0.16's test
// runner makes `@import("root")` resolve to its own root in test
// builds, so a `root.zig` override would not be visible to runtime
// tests. The host-correct default solves the same problem without
// the `@hasDecl` fragility.
// ============================================================

const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0x0000_0000_0000_0001;

pub const runtime_declared_caps: u64 = RUNTIME_DECLARED_CAPS_DEFAULT;

/// Phase 6 codegen-elision predicate (mirrors `src/memory/elision.zig`).
/// Comptime-true when the active manager declares `REFCOUNT_V1`. Used
/// inside the runtime to gate retain/release method bodies and inline-
/// header struct layout.
pub const refcount_v1_active: bool = (runtime_declared_caps & 0x0000_0000_0000_0001) != 0;

// ============================================================
// ARC — Atomic Reference Counting (spec §31.4)
// ============================================================

/// Inline refcount header for `Map(K,V)` / `List(T)` / `MapIter(K,V)`
/// cells. Phase 6 makes the header's *shape* conditional on the active
/// manager: under a manager that declares `REFCOUNT_V1` the header is
/// a 4-byte atomic counter at cell offset 0 (the historical layout);
/// under a manager that does NOT declare `REFCOUNT_V1` the header
/// resolves to an empty struct (`@sizeOf == 0`) and the inline field
/// drops out of every cell's binary layout, satisfying the spec's
/// "cell-overhead-free under no REFCOUNT_V1" contract (§8.1, §8.5).
///
/// The atomic-counter variant retains its v1.x semantics: `init()`
/// produces rc=1, `retain()` is a `.monotonic` increment, `release()`
/// is an `.acq_rel` decrement returning `true` on the zero-transition.
/// The empty variant exposes the same method names with no-op bodies
/// so call-site source code can stay manager-agnostic.
///
/// The conditional struct definition keeps every consumer (Map/List/
/// MapIter, the AbiV1 dispatchers, the ARC manager's
/// `headerRetainOffsetZero` / `headerReleaseOffsetZero`) sourcing the
/// same `ArcHeader` symbol regardless of mode — there is no type-
/// switch upstream, only the implementation contracts shift between
/// modes.
pub const ArcHeader = if (refcount_v1_active) ArcHeaderRefcounted else ArcHeaderEmpty;

pub const ArcHeaderRefcounted = extern struct {
    ref_count: std.atomic.Value(u32),

    pub fn init() ArcHeaderRefcounted {
        return .{ .ref_count = std.atomic.Value(u32).init(1) };
    }

    pub fn retain(self: *ArcHeaderRefcounted) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *ArcHeaderRefcounted) bool {
        const prev = self.ref_count.fetchSub(1, .acq_rel);
        if (prev == 1) {
            return true; // caller should free
        }
        return false;
    }

    pub fn count(self: *const ArcHeaderRefcounted) u32 {
        return self.ref_count.load(.acquire);
    }
};

/// Empty-shape `ArcHeader` used under a manager that does not declare
/// `REFCOUNT_V1`. `@sizeOf(ArcHeaderEmpty) == 0`, so the inline
/// `header: ArcHeader` field on `Map(K,V)`, `List(T)`, and
/// `MapIter(K,V)` collapses to zero bytes — the spec's cell-overhead-
/// free shape (§8.1 last paragraph). The method bodies are all
/// no-ops; callers that still invoke them (e.g. construction-time
/// `ArcHeader.init()`) compile away to nothing.
pub const ArcHeaderEmpty = extern struct {
    pub fn init() ArcHeaderEmpty {
        return .{};
    }

    pub fn retain(self: *ArcHeaderEmpty) void {
        _ = self;
    }

    pub fn release(self: *ArcHeaderEmpty) bool {
        _ = self;
        return false;
    }

    pub fn count(self: *const ArcHeaderEmpty) u32 {
        _ = self;
        return 0;
    }
};

comptime {
    // Phase 6 layout invariants. The REFCOUNT_V1 shape is the
    // historical 4-byte atomic counter; the no-REFCOUNT_V1 shape is
    // a 0-byte empty struct so Map/List/MapIter cells lose the
    // inline header entirely.
    if (refcount_v1_active) {
        if (@sizeOf(ArcHeader) != 4) @compileError(
            "runtime: ArcHeader under REFCOUNT_V1 must be exactly 4 bytes",
        );
    } else {
        if (@sizeOf(ArcHeader) != 0) @compileError(
            "runtime: ArcHeader under no-REFCOUNT_V1 must be a 0-byte empty struct",
        );
    }
}

// ============================================================
// Atomic helper exposed to external memory managers.
//
// The first-party `src/memory/arc/manager.zig` is compiled by the
// Zig-fork primitive `zap_fork_compile_zig_to_object`, whose
// prebuilt `libzap_compiler.a` does NOT enable LLVM codegen
// (`have_llvm = false`). The self-hosted aarch64 backend in Zig
// 0.16 lacks `atomic_rmw` lowering (the AIR tag falls through to
// `unimplemented atomic_rmw` in `aarch64/Select.zig`), and its
// inline-asm machinery only accepts named-register constraints.
// The manager therefore cannot emit native atomic increment /
// decrement.
//
// The runtime IS LLVM-compiled (Zap's outer `zig build` uses the
// system Zig with full LLVM-backed codegen), so the runtime can
// emit native atomics fine. We expose a C-ABI helper here that the
// external manager calls in place of an inline `@atomicRmw`. The
// call site emits a plain C call (every self-hosted backend
// supports those), and the actual `LDAXR`/`STLXR` (aarch64) or
// `LOCK XADD` (x86_64) instruction is emitted inside this TU.
//
// The long-term fix is to add `atomic_rmw` codegen to the Zig
// fork's aarch64 self-hosted backend (see
// `aarch64/Select.zig`'s `analyzeUse`-only path at the `.atomic_rmw`
// case); this externalised helper is the Phase 4 stop-gap.
// ============================================================

export fn zap_runtime_atomic_add_u32_acq_rel(ptr: *u32, delta: u32) callconv(.c) u32 {
    // `acq_rel` ordering pairs with any retain's `monotonic`
    // ordering for the cell's final-release semantics. The runtime's
    // `ArcHeader.release` uses the same ordering (`acq_rel`) when
    // it operates directly on `header.ref_count` without dispatching
    // through the active manager.
    const atomic_ptr: *std.atomic.Value(u32) = @ptrCast(@alignCast(ptr));
    return atomic_ptr.fetchAdd(delta, .acq_rel);
}

// ============================================================
// Memory Manager ABI v1.0 — pluggable manager indirection layer.
//
// Spec: `docs/memory-manager-abi.md`. Canonical Zig-side definitions
// live in `src/memory/abi.zig`; the shapes are redeclared here because
// `runtime.zig` is `@embedFile`'d into the Zap compiler and injected
// into every Zap user binary as a standalone source unit with no
// sibling files (it can `@import("std")`, `@import("builtin")`, and
// the per-build `@import("zap_active_manager")` sibling registered by
// Phase 3 of the perf-recovery work).
// Any change to the canonical types in `src/memory/abi.zig` must be
// mirrored here; the `comptime` size asserts on each shape are the
// drift tripwire.
//
// The indirection layer (all fields of the module-private
// `active_manager_state` struct introduced in Phase 6):
//   * `active_manager_state.context` — populated by the active
//     manager's `init()` at startup, consumed by every call site as
//     the manager's per-process state pointer.
//   * `active_manager_state.core` — the active core vtable,
//     validated and bound at startup from the externally-linked
//     manager's `.zapmem` section.
//   * `active_manager_state.refcount_capability` — the active
//     REFCOUNT_V1 capability vtable when the manager declares the
//     bit; null otherwise.
//
// After Phase 4 there is no built-in ARC stub in the runtime: every
// Zap binary links a manager `.o` (the first-party
// `src/memory/arc/manager.zig` by default; `src/memory/no_op/manager.zig`
// or `src/memory/arena/manager.zig` when the manifest selects them;
// or any third-party package). The runtime discovers the manager by
// walking the linked-in `.zapmem` section.
//
// The `allocAny` / `retainAny` / `releaseAny` dispatchers in
// `ArcRuntime` validate the active vtable on every call. The
// inline-header retain/release path (`Map(K,V)`, `List(T)`,
// `MapIter`) routes through the manager's REFCOUNT_V1 vtable's
// original `retain` / `release` slots (atomic-on-offset-0 of the
// cell). The generic `Arc(T)` side-table path routes through the
// Phase 4.x extended `allocate_refcounted` / `retain_sized` /
// `release_sized` / `refcount_sized` slots, which the manager
// services from a byte-keyed multi-class slab pool. Both paths now
// flow end-to-end through the active manager — the Phase 4 vtable-
// bypass deferral that previously left `Arc(T)` cells in a runtime-
// owned typed slab pool is closed.
//
// The split-phase release API (`prepareReleaseAny` /
// `destroyPreparedAny`) was removed in Phase 4.x because the
// unified `release_sized` slot folds the refcount decrement, the
// per-type `deep_walk` callback, and the slot-return into a single
// vtable call. Callers that previously used the split-phase pair
// (only `releaseArcAny` inside the runtime) now use `release_sized`
// with a per-type deep-walk closure.
//
// ## Capability-missing panic contract
//
// When a dispatcher (`allocAny`, `freeAny`, `releaseAny`,
// `retainAny`, `retainAnyPersistent`, `headerRetain`,
// `headerRelease`) is invoked under a manager that does NOT declare
// REFCOUNT_V1, the dispatcher MUST panic with a message that names
// the missing capability literally as `REFCOUNT_V1` so the user can
// trace the failure back to the manifest's `memory:` selection. This
// is a normative source-side invariant: tooling (e.g. the
// `Zap.Memory.Arena` structdoc, the Phase 6 codegen-elision plan,
// any future diagnostics layer) relies on the `REFCOUNT_V1` token
// appearing verbatim in the panic text. Every panic site in this
// file that gates on `active_manager_state.refcount_capability == null` is
// audited to honor this contract; grep for `REFCOUNT_V1` to verify.
//
// **Refcount-read exemption.** `refCountAny` and similar refcount-READ
// dispatchers may return `0` instead of panicking when REFCOUNT_V1 is
// missing. They are not retain/release dispatchers and the `0` return
// models the absence of refcounting cleanly for Perceus reuse /
// `resetAny` callers (a `refCountAny == 1` check naturally returns
// false under a non-refcounting manager, so callers fall back to the
// non-reuse path without crashing). The panic contract applies only
// to retain/release/alloc/free hot paths — anywhere the runtime is
// MUTATING refcount state or DEPENDING on a slab return for
// correctness. Reads that report "no refcount info available" are
// soundness-preserving and intentionally graceful.
//
// (These panic paths cannot be exercised in standard `zig build
// test` because `@panic` aborts the test process. Coverage of the
// panic message text is by inspection — see the `headerRetain`
// coverage note. A Phase 6 fault-injection harness will exercise
// the panic paths under a child-process model.)
// ============================================================

// ============================================================
// Phase 3 — Active manager identity (mirrors `BuiltinManagerTag`)
//
// `ActiveManagerTag` mirrors `src/memory/driver.zig:BuiltinManagerTag`.
// The runtime can't `@import("memory/driver.zig")` because runtime.zig
// is injected into each Zap user binary as a standalone source unit
// with no sibling files (it can only `@import("std")`,
// `@import("builtin")`, and the per-build `@import("zap_active_manager")`
// stub registered by Phase 3). The mirror, the explicit `u8` ordinals,
// and the comptime tripwire below collectively pin the wire encoding:
// both sides must agree, and any drift in `BuiltinManagerTag`'s shape
// (adding, removing, or renaming a case) MUST be matched by a
// simultaneous change here and a bump of the expected count.
//
// Resolution:
//   * The source-level `RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT` constant
//     defaults to `.third_party` so the host test suite (which loads
//     `runtime.zig` as a Zig module without going through the
//     user-binary `@embedFile` rewrite) naturally exercises the
//     vtable path — the same path a third-party manager build follows.
//   * For each Zap user binary, `compiler.getRuntimeSource(caps, tag)`
//     rewrites the marker to the resolved manager's tag before
//     injecting the source into the build. A binary built against
//     `Zap.Memory.ARC` therefore sees `ACTIVE_MANAGER_TAG == .arc`,
//     which lets Phase 4's comptime branches call into the active
//     manager's hot paths directly through `@import("zap_active_manager")`.
// ============================================================

pub const ActiveManagerTag = enum(u8) {
    arc = 0,
    arena = 1,
    no_op = 2,
    leak = 3,
    tracking = 4,
    third_party = 5,
};

// Compile-time guard mirroring the `BuiltinManagerTag` symmetry assert
// in `src/memory/driver.zig`. The Phase 3 marker rewrite and the
// Phase 4 comptime dispatch both treat the tag as a closed set; a
// silent shape drift between the two enums would either alias a
// first-party manager to the wrong arm (incorrect codegen) or break
// the rewrite altogether (the user binary would fail to compile).
// Both failure modes are catastrophic, so the count is asserted at
// the runtime-module compile site.
comptime {
    if (@typeInfo(ActiveManagerTag).@"enum".fields.len != 6) @compileError(
        "runtime.ActiveManagerTag: case count drifted from BuiltinManagerTag — " ++
            "update both enums and the explicit ordinals in lock-step.",
    );
}

const RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT: ActiveManagerTag = .third_party;

/// The active memory manager's identity, comptime-visible inside
/// `runtime.zig`. Phase 4's hot-path dispatchers branch on this so a
/// first-party-manager build can call directly through
/// `@import("zap_active_manager")` (letting LLVM inline across the
/// boundary) while a `.third_party` build routes through the
/// `.zapmem`-registered vtable the way today's code does. The
/// indirect default-via-marker pattern mirrors
/// `RUNTIME_DECLARED_CAPS_DEFAULT` so the compiler's
/// `rewriteRuntimeSource` can edit a single literal per user binary.
pub const ACTIVE_MANAGER_TAG: ActiveManagerTag = RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT;

/// Comptime classifier — does the first-party manager identified by
/// `tag` declare the `REFCOUNT_V1` capability?
///
/// The Phase 4 hot-path dispatchers consult this predicate to decide
/// whether the first-party direct-call branch is allowed to invoke the
/// manager's `retain` / `release` / `retainSized` / `releaseSized` /
/// `allocateRefcounted` / `refcountSized` aliases. For managers that
/// DO declare the capability (`.arc` today) those aliases resolve to
/// real implementations. For managers that do NOT (`.arena`, `.no_op`,
/// `.leak`, `.tracking`) the aliases resolve to panic stubs that the
/// dispatcher MUST never call — under Phase 6's codegen elision the
/// runtime never emits a retain/release against a manager that omits
/// REFCOUNT_V1, but a future regression that bypasses elision would
/// still surface here rather than as an uninitialised vtable load.
///
/// The `.third_party` arm intentionally returns `false`: third-party
/// builds always route through the vtable, where the capability's
/// presence is checked dynamically via the `active_manager_state.refcount_capability`
/// global. The dispatcher uses that runtime check instead of this
/// comptime predicate under `.third_party`.
pub fn managerHasRefcountV1(comptime tag: ActiveManagerTag) bool {
    return switch (tag) {
        .arc => true,
        .arena, .no_op, .leak, .tracking => false,
        // Third-party builds dispatch through the vtable and check the
        // capability dynamically via `active_manager_state.refcount_capability`.
        .third_party => false,
    };
}

comptime {
    // Tripwire: every Phase 4 dispatcher in this file branches on
    // `ACTIVE_MANAGER_TAG` and consults `managerHasRefcountV1`. The
    // classifier's coverage must include every enum case explicitly;
    // a missing arm would surface here as a compile error rather than
    // as a silent miscompile in the dispatcher. The switch statement
    // above already provides exhaustiveness checking, but the cardinality
    // assert below additionally pins the case count so adding a new
    // manager forces a deliberate decision about its REFCOUNT_V1
    // declaration.
    if (@typeInfo(ActiveManagerTag).@"enum".fields.len != 6) @compileError(
        "runtime.managerHasRefcountV1: case count drifted from ActiveManagerTag — " ++
            "update both the switch and the cardinality assert in lock-step.",
    );
}

pub const AbiV1 = struct {
    /// `REFC` capability tag (spec section 7.1) read at the target's
    /// native endianness. Derived via `std.mem.readInt(u32, "REFC", endian)`
    /// per spec section 7.1 so the constant resolves correctly on either
    /// byte order without hand-computed hex literals.
    pub const REFC_TAG: u32 = std.mem.readInt(u32, "REFC", builtin.target.cpu.arch.endian());

    /// `REFCOUNT_V1` bit in `declared_caps` (spec section 7.1). Bit 0.
    pub const REFCOUNT_V1_BIT: u64 = 0x0000_0000_0000_0001;

    /// The legacy v1.0 byte length of `ZapRefcountCapabilityV1` —
    /// `retain` + `release` only (spec section 8.0). A v1.0 manager
    /// advertises `desc.size == REFCOUNT_V1_SIZE_V1_0`; the runtime
    /// falls back to `core.allocate` / `core.deallocate` for generic
    /// `Arc(T)` allocations under such a manager.
    pub const REFCOUNT_V1_SIZE_V1_0: u16 = 16;

    /// The v1.1 byte length of `ZapRefcountCapabilityV1`, including
    /// the side-table extension slots (`retain_sized`, `release_sized`,
    /// `allocate_refcounted`, `refcount_sized`). A v1.1+ manager
    /// advertises `desc.size >= REFCOUNT_V1_SIZE_V1_1`; the runtime
    /// routes generic `Arc(T)` allocations through the sized API.
    pub const REFCOUNT_V1_SIZE_V1_1: u16 = 48;

    /// Options passed to the manager's `init` entry point (spec
    /// section 4.1). Evolves in place via the leading `size` field.
    pub const ZapInitOptions = extern struct {
        size: u32,
        reserved: u32,
    };

    /// Capability descriptor record (spec section 3.6). Embedded in
    /// the manager's `.zapmem` metadata block; also returned from
    /// `core.get_capability_desc(tag)` for runtime-only discovery.
    pub const ZapCapabilityDescV1 = extern struct {
        id: u32,
        version: u16,
        size: u16,
        flags: u32,
        vtable: *const anyopaque,
    };

    /// Compiler-emitted deep-walk callback (spec section 8). The
    /// runtime/compiler passes a per-type walk function (or null when
    /// the cell has no refcounted children) to `release`. The manager
    /// invokes it once on the final zero-transition before freeing.
    pub const ZapDeepWalkFn = *const fn (object: *anyopaque) callconv(.c) void;

    /// Core capability vtable (spec section 4.2). All Phase 2 dispatch
    /// goes through a pointer to one of these.
    pub const ZapMemoryManagerCoreV1 = extern struct {
        abi_major: u16,
        abi_minor: u16,
        size: u32,
        declared_caps: u64,
        init: *const fn (options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque,
        deinit: *const fn (ctx: *anyopaque) callconv(.c) void,
        allocate: *const fn (ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8,
        deallocate: *const fn (ctx: *anyopaque, ptr: [*]u8, size: usize, alignment: u32) callconv(.c) void,
        get_capability_desc: *const fn (ctx: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1,
    };

    /// `REFCOUNT_V1` capability vtable (spec section 8). The first two
    /// slots are the original v1.0 inline-header path (operate on a
    /// 4-byte refcount at offset 0 of the cell). The trailing four
    /// slots are the Phase 4.x side-table path used by generic
    /// `Arc(T)` cells — `retain_sized` / `release_sized` recover the
    /// cell's slab from a 64-KiB-aligned mask and look up the side-
    /// table refcount; `allocate_refcounted` allocates a side-table
    /// cell with rc=1; `refcount_sized` reads the side-table refcount
    /// (used by `resetAny` / Perceus reuse). The descriptor's `size`
    /// field advertises the actual vtable length so a v1.0 runtime
    /// that only reads the first two slots continues to interoperate.
    pub const ZapRefcountCapabilityV1 = extern struct {
        retain: *const fn (ctx: *anyopaque, object: *anyopaque) callconv(.c) void,
        release: *const fn (ctx: *anyopaque, object: *anyopaque, deep_walk: ?ZapDeepWalkFn) callconv(.c) void,
        retain_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void,
        release_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32, deep_walk: ?ZapDeepWalkFn) callconv(.c) void,
        allocate_refcounted: *const fn (ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8,
        refcount_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32,
    };

    // Tripwire asserts mirroring `src/memory/abi.zig`. Any drift in
    // the canonical Zig-side types must be reflected here; these
    // asserts catch a missed sync at runtime-binary compile time.
    // Both `@sizeOf` and per-field `@offsetOf` are checked so a field
    // reorder (which preserves total size) cannot silently drift.
    comptime {
        if (@sizeOf(ZapInitOptions) != 8) @compileError(
            "runtime.AbiV1: ZapInitOptions v1.0 must be exactly 8 bytes",
        );
        if (@offsetOf(ZapInitOptions, "size") != 0) @compileError(
            "runtime.AbiV1: ZapInitOptions.size must be at offset 0",
        );
        if (@offsetOf(ZapInitOptions, "reserved") != 4) @compileError(
            "runtime.AbiV1: ZapInitOptions.reserved must be at offset 4",
        );

        if (@sizeOf(ZapCapabilityDescV1) != 24) @compileError(
            "runtime.AbiV1: ZapCapabilityDescV1 v1.0 must be exactly 24 bytes",
        );
        if (@offsetOf(ZapCapabilityDescV1, "id") != 0) @compileError(
            "runtime.AbiV1: ZapCapabilityDescV1.id must be at offset 0",
        );
        if (@offsetOf(ZapCapabilityDescV1, "version") != 4) @compileError(
            "runtime.AbiV1: ZapCapabilityDescV1.version must be at offset 4",
        );
        if (@offsetOf(ZapCapabilityDescV1, "size") != 6) @compileError(
            "runtime.AbiV1: ZapCapabilityDescV1.size must be at offset 6",
        );
        if (@offsetOf(ZapCapabilityDescV1, "flags") != 8) @compileError(
            "runtime.AbiV1: ZapCapabilityDescV1.flags must be at offset 8",
        );
        if (@offsetOf(ZapCapabilityDescV1, "vtable") != 16) @compileError(
            "runtime.AbiV1: ZapCapabilityDescV1.vtable must be at offset 16",
        );

        if (@sizeOf(ZapMemoryManagerCoreV1) != 56) @compileError(
            "runtime.AbiV1: ZapMemoryManagerCoreV1 v1.0 must be exactly 56 bytes",
        );
        if (@offsetOf(ZapMemoryManagerCoreV1, "abi_major") != 0) @compileError(
            "runtime.AbiV1: ZapMemoryManagerCoreV1.abi_major must be at offset 0",
        );
        if (@offsetOf(ZapMemoryManagerCoreV1, "abi_minor") != 2) @compileError(
            "runtime.AbiV1: ZapMemoryManagerCoreV1.abi_minor must be at offset 2",
        );
        if (@offsetOf(ZapMemoryManagerCoreV1, "size") != 4) @compileError(
            "runtime.AbiV1: ZapMemoryManagerCoreV1.size must be at offset 4",
        );
        if (@offsetOf(ZapMemoryManagerCoreV1, "declared_caps") != 8) @compileError(
            "runtime.AbiV1: ZapMemoryManagerCoreV1.declared_caps must be at offset 8",
        );
        if (@offsetOf(ZapMemoryManagerCoreV1, "init") != 16) @compileError(
            "runtime.AbiV1: ZapMemoryManagerCoreV1.init must be at offset 16",
        );
        if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != 24) @compileError(
            "runtime.AbiV1: ZapMemoryManagerCoreV1.deinit must be at offset 24",
        );
        if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 32) @compileError(
            "runtime.AbiV1: ZapMemoryManagerCoreV1.allocate must be at offset 32",
        );
        if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 40) @compileError(
            "runtime.AbiV1: ZapMemoryManagerCoreV1.deallocate must be at offset 40",
        );
        if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 48) @compileError(
            "runtime.AbiV1: ZapMemoryManagerCoreV1.get_capability_desc must be at offset 48",
        );

        if (@sizeOf(ZapRefcountCapabilityV1) != 48) @compileError(
            "runtime.AbiV1: ZapRefcountCapabilityV1 (Phase 4.x extended) must be exactly 48 bytes",
        );
        if (@offsetOf(ZapRefcountCapabilityV1, "retain") != 0) @compileError(
            "runtime.AbiV1: ZapRefcountCapabilityV1.retain must be at offset 0",
        );
        if (@offsetOf(ZapRefcountCapabilityV1, "release") != 8) @compileError(
            "runtime.AbiV1: ZapRefcountCapabilityV1.release must be at offset 8",
        );
        if (@offsetOf(ZapRefcountCapabilityV1, "retain_sized") != 16) @compileError(
            "runtime.AbiV1: ZapRefcountCapabilityV1.retain_sized must be at offset 16",
        );
        if (@offsetOf(ZapRefcountCapabilityV1, "release_sized") != 24) @compileError(
            "runtime.AbiV1: ZapRefcountCapabilityV1.release_sized must be at offset 24",
        );
        if (@offsetOf(ZapRefcountCapabilityV1, "allocate_refcounted") != 32) @compileError(
            "runtime.AbiV1: ZapRefcountCapabilityV1.allocate_refcounted must be at offset 32",
        );
        if (@offsetOf(ZapRefcountCapabilityV1, "refcount_sized") != 40) @compileError(
            "runtime.AbiV1: ZapRefcountCapabilityV1.refcount_sized must be at offset 40",
        );
        if (REFCOUNT_V1_SIZE_V1_0 != 16) @compileError(
            "runtime.AbiV1: REFCOUNT_V1_SIZE_V1_0 must equal 16 (v1.0 vtable length)",
        );
        if (REFCOUNT_V1_SIZE_V1_1 != @sizeOf(ZapRefcountCapabilityV1)) @compileError(
            "runtime.AbiV1: REFCOUNT_V1_SIZE_V1_1 must match the current ZapRefcountCapabilityV1 size",
        );
    }
};

// ----------------------------------------------------------------
// Active manager globals (spec section 10).
//
// Phase 4 onwards: the active manager is bound at startup by
// `maybeBindExternalManager`, which walks the linked-in `.zapmem`
// section to discover the manager `.o` the build pipeline produced.
// The compiler-emitted retain/release/alloc call sites consult these
// globals indirectly through the `ArcRuntime` dispatchers below.
//
// Test builds (`zig build test`) do not link a real manager `.o` —
// the runtime module is compiled directly, not through the
// production build driver. To keep tests green the runtime defines a
// minimal in-source ARC manager under `if (builtin.is_test)` below
// (`test_only_arc_core`) and binds it as the active manager at
// startup. The test-only fallback mirrors the production
// `Zap.Memory.ARC` manager byte-for-byte (same retain/release
// semantics, same REFCOUNT_V1 declaration); the two implementations
// are kept in lock-step via the spec contract and the shared
// `AbiV1` extern types.
// ----------------------------------------------------------------

/// Consolidated state for the active memory manager binding.
///
/// Phase 6 consolidation: the six loose globals that previously held the
/// dispatcher's state (`zap_memory_manager_context`,
/// `zap_active_manager_core`, `zap_active_refcount_capability`,
/// `zap_active_refcount_has_sized_extension`, `zap_memory_started`,
/// `zap_memory_shutdown_complete`) are now packed into this single
/// module-private struct as the fields `context`, `core`,
/// `refcount_capability`, `refcount_has_sized_extension`, `started`,
/// and `shutdown_complete`. Every previous field is preserved verbatim;
/// only the storage location changes.
///
/// ## Why a single struct
///
/// Before Phase 6 the dispatchers loaded each field via a separate
/// global load, and several of those globals were `pub export var`
/// because spec §10.2 historically described `zap_memory_manager_context`
/// as a cross-TU surface. In Zap's current architecture the runtime is
/// embedded as source into every user binary (the runtime is `@embedFile`'d
/// at compile time and the entire ARC dispatch graph compiles into one
/// translation unit — see `src/compiler.zig`). The runtime is therefore
/// the SOLE consumer of these globals at link time. With no external
/// consumers, exporting them prevents LLVM from CSE-ing the loads
/// across calls and from hoisting them out of loops. Consolidating into
/// a module-private struct removes that visibility constraint and lets
/// the optimizer treat the loads as ordinary internal-linkage memory.
///
/// ## Why this struct is "effectively const" after startup
///
/// `zapMemoryStartup` writes every field exactly once at first dispatch
/// (or at the first `ensureMemoryStartup` call from any other entry
/// point). After that, only `shutdown_complete` is updated, and only
/// when the atexit handler runs — strictly AFTER any user-visible ARC
/// dispatch could have happened. Spec §10.2 normatively guarantees that
/// the binding is written exactly once during the program's lifetime;
/// the runtime preserves observability of the post-shutdown state by
/// flipping `shutdown_complete` instead of nulling `core` / `context`
/// (so a misuse panics with a clear diagnostic instead of a null
/// dereference).
///
/// ## Threading
///
/// All fields are non-atomic. Zap is single-threaded today; if
/// concurrency lands later, `shutdown_complete` and `started` would
/// need to become atomics. The other fields are write-once-then-read-
/// only and so do not require atomicity even under concurrency — once
/// the startup write retires the value is publishable to readers via
/// any subsequent memory barrier in the runtime's atexit dance.
const ActiveManagerState = struct {
    /// Per-process context returned by the active manager's `init()`.
    /// Populated by `zapMemoryStartup` once startup completes;
    /// consumed by every dispatched vtable call as the manager's
    /// opaque state pointer. Null before startup; the dispatchers
    /// panic on null access. Written exactly once per spec §10.2.
    context: ?*anyopaque,

    /// The active manager's core vtable. In production this is bound
    /// at startup by `maybeBindExternalManager` from the linked-in
    /// `.zapmem` section. In test builds the compile-time default
    /// (`&test_only_arc_core`) is set in the initialiser below so
    /// dispatchers have a valid vtable from the moment
    /// `ensureMemoryStartup` runs.
    core: ?*const AbiV1.ZapMemoryManagerCoreV1,

    /// The active manager's REFCOUNT_V1 capability vtable, populated
    /// by `zapMemoryStartup` when the manager declares the bit. Null
    /// when the active manager does not implement refcounting.
    ///
    /// Only the leading two slots (`retain`, `release`) are guaranteed
    /// to be populated when non-null. The trailing four slots (the
    /// v1.1 side-table extension) are valid ONLY when
    /// `refcount_has_sized_extension == true`. Dispatchers that route
    /// generic `Arc(T)` allocations through `allocate_refcounted` /
    /// `retain_sized` / `release_sized` / `refcount_sized` MUST consult
    /// the extension flag first; under a v1.0 manager those calls must
    /// be routed through `core.allocate` / `core.deallocate` instead.
    refcount_capability: ?*const AbiV1.ZapRefcountCapabilityV1,

    /// Set to `true` by `zapMemoryStartup` when the active manager's
    /// REFCOUNT_V1 descriptor advertises `size >= sizeof(v1.1 vtable)` —
    /// i.e., the manager provides the side-table extension slots in
    /// addition to the v1.0 inline-header `retain` / `release` slots.
    refcount_has_sized_extension: bool,

    /// Idempotency guard for `zapMemoryStartup`. Dispatchers ensure
    /// startup runs exactly once on the first ARC-touching call from a
    /// Zap binary's main path; subsequent calls bypass the init path
    /// with a single boolean compare. NEVER reset on shutdown —
    /// `shutdown_complete` below is the post-shutdown discriminator.
    started: bool,

    /// Set to `true` after `zapMemoryShutdown` has completed the
    /// manager's `core.deinit(ctx)` call. Checked ahead of any other
    /// state in each dispatcher to detect the post-shutdown-dispatch
    /// bug. Setting it (instead of nulling `core` / `context`) preserves
    /// spec §10.2's "written exactly once" guarantee — the context
    /// keeps pointing at its last-known value so the post-shutdown
    /// state is observable rather than masked by null.
    shutdown_complete: bool,
};

/// Module-private storage for the active manager's binding. NOT `pub`,
/// NOT `export` — by keeping the symbol's linkage internal to the
/// runtime TU, LLVM can CSE loads across consecutive dispatcher calls
/// and hoist loads out of loops. Pre-Phase-6 the same fields were
/// declared as separate `pub export var` globals; every retain/release
/// in a hot loop forced a fresh memory load because external consumers
/// could in principle observe interleaved writes. Consolidation removes
/// that constraint.
///
/// Test builds default `core` to `&test_only_arc_core` so the
/// dispatchers have a working vtable from the moment of the first call;
/// `bindRefcountCapability` populates `refcount_capability` and
/// `refcount_has_sized_extension` during `zapMemoryStartup`. Production
/// builds null-initialise both and rely on `maybeBindExternalManager`
/// to discover the manager from the linked-in `.zapmem` section.
var active_manager_state: ActiveManagerState = .{
    .context = null,
    .core = if (builtin.is_test) &test_only_arc_core else null,
    .refcount_capability = null,
    .refcount_has_sized_extension = false,
    .started = false,
    .shutdown_complete = false,
};

// ----------------------------------------------------------------
// v1.0 REFCOUNT_V1 trap-stub plumbing.
//
// Under a v1.0 manager the REFCOUNT_V1 descriptor advertises only the
// first 16 bytes of `ZapRefcountCapabilityV1` (`retain` + `release`).
// The compiler-side struct is 48 bytes long because v1.1 added four
// trailing slots (`retain_sized`, `release_sized`,
// `allocate_refcounted`, `refcount_sized`). A typed
// `*const AbiV1.ZapRefcountCapabilityV1` cast over a 16-byte image
// would alias slots 2-5 over out-of-bounds memory; the current
// dispatchers gate every v1.1 slot access on
// `active_manager_state.refcount_has_sized_extension` so the aliased bytes are
// never actually read, but a future code change that drops the gate
// would dereference garbage.
//
// Defense-in-depth: when binding a v1.0 manager, the runtime copies
// the user-provided 16-byte head into a process-local writable v1.1-
// shaped vtable buffer (`v1_0_composed_refcount_vtable`) and stuffs
// trap stubs into slots 2-5. The trap stubs panic with a diagnostic
// that names the missing extension slot; the panic message catches
// the regression at the dispatch site rather than at the corruption
// downstream.
//
// `active_manager_state.refcount_capability` is then pointed at this composed
// buffer instead of at the raw user vtable. All dispatchers that
// consult the cap pointer therefore see a fully-populated 48-byte
// struct, and dropping the `has_sized_extension` gate would surface
// the trap-stub panic instead of arbitrary-memory dereference.
// ----------------------------------------------------------------

/// Process-local writable buffer that holds the composed v1.1-shaped
/// REFCOUNT_V1 vtable when the active manager advertises only the
/// v1.0 surface. Populated by `bindRefcountCapability` during
/// `zapMemoryStartup` and never reassigned for the program's lifetime
/// (spec §10.2's write-once binding contract). The buffer lives in
/// `.bss` so the trap-stub function pointers stabilise at program
/// load; subsequent runs see the same addresses.
var v1_0_composed_refcount_vtable: AbiV1.ZapRefcountCapabilityV1 = undefined;

/// Trap stub for the v1.1 `retain_sized` slot under a v1.0 manager.
/// Reaching this stub means a dispatcher consulted slot 2 of the
/// refcount capability vtable despite
/// `active_manager_state.refcount_has_sized_extension == false` — either the
/// dispatcher's gate is missing or a build-pipeline bug routed a
/// generic `Arc(T)` allocation through `retain_sized` under a v1.0
/// manager. Both cases are unrecoverable; panic loudly so the
/// regression is caught at the next test pass instead of as a silent
/// memory corruption.
fn v1_0_trap_retain_sized(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("zap runtime: REFCOUNT_V1 retain_sized invoked under v1.0 manager (missing has_sized_extension gate)");
}

/// Trap stub for the v1.1 `release_sized` slot under a v1.0 manager.
/// See `v1_0_trap_retain_sized` for the gating rationale.
fn v1_0_trap_release_sized(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
    deep_walk: ?AbiV1.ZapDeepWalkFn,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    _ = deep_walk;
    @panic("zap runtime: REFCOUNT_V1 release_sized invoked under v1.0 manager (missing has_sized_extension gate)");
}

/// Trap stub for the v1.1 `allocate_refcounted` slot under a v1.0
/// manager. See `v1_0_trap_retain_sized` for the gating rationale.
fn v1_0_trap_allocate_refcounted(
    ctx: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    @panic("zap runtime: REFCOUNT_V1 allocate_refcounted invoked under v1.0 manager (missing has_sized_extension gate)");
}

/// Trap stub for the v1.1 `refcount_sized` slot under a v1.0 manager.
/// See `v1_0_trap_retain_sized` for the gating rationale.
fn v1_0_trap_refcount_sized(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) u32 {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("zap runtime: REFCOUNT_V1 refcount_sized invoked under v1.0 manager (missing has_sized_extension gate)");
}

/// Bind the active manager's REFCOUNT_V1 capability. When the
/// descriptor advertises only the v1.0 surface (`desc.size <
/// REFCOUNT_V1_SIZE_V1_1`), copy the user-provided `retain` /
/// `release` slots into `v1_0_composed_refcount_vtable` and stuff
/// trap stubs into the v1.1 extension slots. Points
/// `active_manager_state.refcount_capability` at the composed buffer in that
/// case; otherwise points it directly at the user vtable.
///
/// Hoisted out of `zapMemoryStartup` so the test-only descriptor swap
/// (`setActiveRefcountCapabilityForTest`) can reuse the same composition
/// path without duplicating the trap-stub plumbing.
fn bindRefcountCapability(desc: *const AbiV1.ZapCapabilityDescV1) void {
    // For a v1.1+ descriptor the typed cast safely aliases the full
    // 48-byte image — slots 2-5 are real function pointers populated
    // by the manager. Bind directly.
    if (desc.size >= AbiV1.REFCOUNT_V1_SIZE_V1_1) {
        const cap_ptr: *const AbiV1.ZapRefcountCapabilityV1 = @ptrCast(@alignCast(desc.vtable));
        active_manager_state.refcount_capability = cap_ptr;
        active_manager_state.refcount_has_sized_extension = true;
        return;
    }
    // v1.0 path: only `retain` + `release` are guaranteed to be valid
    // in the user-supplied 16-byte image. Read those two slots
    // through a minimal v1.0-shaped cast that touches exactly the
    // first 16 bytes — the safe portion of the user vtable.
    const V1_0Head = extern struct {
        retain: *const fn (ctx: *anyopaque, object: *anyopaque) callconv(.c) void,
        release: *const fn (ctx: *anyopaque, object: *anyopaque, deep_walk: ?AbiV1.ZapDeepWalkFn) callconv(.c) void,
    };
    comptime {
        if (@sizeOf(V1_0Head) != AbiV1.REFCOUNT_V1_SIZE_V1_0) @compileError(
            "v1_0 head shape must match REFCOUNT_V1_SIZE_V1_0",
        );
    }
    const head_ptr: *const V1_0Head = @ptrCast(@alignCast(desc.vtable));
    v1_0_composed_refcount_vtable = .{
        .retain = head_ptr.retain,
        .release = head_ptr.release,
        .retain_sized = v1_0_trap_retain_sized,
        .release_sized = v1_0_trap_release_sized,
        .allocate_refcounted = v1_0_trap_allocate_refcounted,
        .refcount_sized = v1_0_trap_refcount_sized,
    };
    active_manager_state.refcount_capability = &v1_0_composed_refcount_vtable;
    active_manager_state.refcount_has_sized_extension = false;
}

// ----------------------------------------------------------------
// Test-only ARC manager fallback.
//
// Phase 4 ripped the built-in ARC stub out of the runtime so every
// production Zap binary links a real manager `.o` (the first-party
// `src/memory/arc/manager.zig` by default). Tests, however, are
// built by `zig build test`, which compiles the runtime module
// directly and does NOT exercise the production build pipeline that
// would normally compile and link `src/memory/arc/manager.zig`. To
// keep tests green the runtime carries a minimal in-source
// equivalent of the external ARC manager, guarded by
// `builtin.is_test`.
//
// `test_only_arc_*` mirrors `src/memory/arc/manager.zig`: the same
// REFCOUNT_V1 declaration and the same atomic-on-offset-0 retain/
// release semantics. The retain path uses `monotonic` ordering on the
// `std.atomic.Value(u32)` wrapper here, which lowers to the same
// `LDADD` / `LOCK XADD` instruction as the production manager's
// `acq_rel` `zap_runtime_atomic_add_u32_acq_rel` helper modulo the
// fence (the release fence in `acq_rel` is a no-op on the increment
// path because there is no prior writeback to publish); the divergence
// is documented because the test path cannot call into the production
// helper without re-entering its own atomic-helper export. The raw
// `allocate` / `deallocate` slots return null / no-op exactly like
// the production manager (the runtime never dispatches user-visible
// allocations through these slots in v1.0 — see the architecture
// note in `src/memory/arc/manager.zig`). Production builds compile
// this code out via the `is_test` guard; the symbol references
// survive because `active_manager_state.core`'s default initialiser
// depends on `test_only_arc_core` only when `builtin.is_test` is
// true.
//
// Drift risk: if `src/memory/arc/manager.zig` changes its retain or
// release semantics in a way that breaks observability in tests,
// this fallback must be updated in lock-step. The two
// implementations share the spec contract (§8.2 atomic decrement
// with deep_walk on zero-transition) plus the shared `AbiV1`
// extern types in this file, so drift produces an immediate test
// failure.
// ----------------------------------------------------------------

/// Test-only byte-keyed slab pool. Mirrors the production manager's
/// `SlabPool` in `src/memory/arc/manager.zig` so the test path through
/// `allocAny` / `retainAny` / `releaseAny` exercises the same vtable
/// surface as a production binary, including the Phase 4.x extended
/// `retain_sized` / `release_sized` / `allocate_refcounted` slots.
/// Production binaries route through the externally-linked manager
/// `.o`; the test runtime can't load that object (it would require a
/// child-process model — see the Phase 4 commentary above), so we
/// duplicate the slab-pool body here under `if (builtin.is_test)`.
///
/// The two implementations share the spec contract (atomic decrement
/// with deep_walk on zero-transition, size-class lookup keyed on
/// `(size, alignment)`, 64-KiB-aligned slab + side-table refcount
/// layout) so observable behaviour is byte-faithful. Any drift between
/// them produces an immediate test failure because every Arc(T) test
/// path runs against this fallback.
const TestOnlyArcSlabPool = if (builtin.is_test) struct {
    pub const SLAB_SIZE: usize = 64 * 1024;
    pub const SLAB_ALIGN: usize = SLAB_SIZE;
    pub const SLAB_MASK: usize = SLAB_SIZE - 1;
    pub const SLAB_BASE_MASK: usize = ~SLAB_MASK;
    pub const NULL_SLOT: u32 = 0xFFFFFFFF;
    pub const SLAB_MAGIC: u32 = 0x5A4D5342;
    pub const LARGE_MAGIC: u32 = 0x5A4D4C47;

    /// Size class table — same values as `src/memory/arc/manager.zig`'s
    /// `SLAB_CLASS_SIZES`. Drift in either side produces test failure
    /// because the slab layout and capacity computations depend on
    /// these values being identical.
    pub const SLAB_CLASS_SIZES = [_]u32{ 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096 };
    pub const SLAB_CLASS_COUNT = SLAB_CLASS_SIZES.len;
    pub const MAX_SLAB_CLASS_SIZE: u32 = SLAB_CLASS_SIZES[SLAB_CLASS_COUNT - 1];

    pub const SLAB_CLASS_ALIGNS: [SLAB_CLASS_COUNT]u32 = blk: {
        var aligns: [SLAB_CLASS_COUNT]u32 = undefined;
        var class_index: u32 = 0;
        while (class_index < SLAB_CLASS_COUNT) : (class_index += 1) {
            const size = SLAB_CLASS_SIZES[class_index];
            var align_val: u32 = 1;
            var bit: u32 = 0;
            while (bit < 32) : (bit += 1) {
                const probe: u32 = @as(u32, 1) << bit;
                if (probe > size) break;
                if (size % probe == 0) align_val = probe;
            }
            aligns[class_index] = align_val;
        }
        break :blk aligns;
    };

    pub inline fn slotAlignForClass(class_index: u32) u32 {
        return SLAB_CLASS_ALIGNS[class_index];
    }

    pub const SLAB_CLASS_LOOKUP_GRANULARITY: usize = 8;
    pub const SLAB_CLASS_LOOKUP_TABLE_LEN: usize = (MAX_SLAB_CLASS_SIZE + SLAB_CLASS_LOOKUP_GRANULARITY - 1) / SLAB_CLASS_LOOKUP_GRANULARITY;
    pub const SLAB_CLASS_LOOKUP_TABLE: [SLAB_CLASS_LOOKUP_TABLE_LEN]u32 = blk: {
        @setEvalBranchQuota(20000);
        var table: [SLAB_CLASS_LOOKUP_TABLE_LEN]u32 = undefined;
        var bucket: usize = 0;
        while (bucket < SLAB_CLASS_LOOKUP_TABLE_LEN) : (bucket += 1) {
            const upper_bound: u32 = @intCast((bucket + 1) * SLAB_CLASS_LOOKUP_GRANULARITY);
            var class_index: u32 = 0;
            while (class_index < SLAB_CLASS_COUNT) : (class_index += 1) {
                if (SLAB_CLASS_SIZES[class_index] >= upper_bound) break;
            }
            table[bucket] = class_index;
        }
        break :blk table;
    };

    pub inline fn lookupClass(size: usize, alignment: u32) ?u32 {
        if (size == 0 or size > MAX_SLAB_CLASS_SIZE) return null;
        const bucket: usize = (size - 1) / SLAB_CLASS_LOOKUP_GRANULARITY;
        var class_index: u32 = SLAB_CLASS_LOOKUP_TABLE[bucket];
        while (class_index < SLAB_CLASS_COUNT) : (class_index += 1) {
            if (SLAB_CLASS_ALIGNS[class_index] >= alignment) return class_index;
        }
        return null;
    }

    pub const SlabHeader = extern struct {
        magic: u32,
        class_index: u32,
        live_count: u32,
        free_list_head: u32,
        bump_index: u32,
        capacity: u32,
        prev: ?*SlabHeader,
        next: ?*SlabHeader,
        allocation_base: [*]align(std.heap.page_size_min) u8,
        owner: *anyopaque,
    };

    pub const SizeClass = extern struct {
        current: ?*SlabHeader,
        partials: ?*SlabHeader,
        cached_empty: ?*SlabHeader,
    };

    pub inline fn slotsOffsetForClass(class_index: u32, capacity: u32) usize {
        const refcount_bytes: usize = @as(usize, capacity) * @sizeOf(u32);
        const header_end: usize = @sizeOf(SlabHeader) + refcount_bytes;
        const align_v: usize = slotAlignForClass(class_index);
        return std.mem.alignForward(usize, header_end, align_v);
    }

    pub inline fn capacityForClass(class_index: u32) u32 {
        const slot_size: usize = SLAB_CLASS_SIZES[class_index];
        const slot_align: usize = slotAlignForClass(class_index);
        if (SLAB_SIZE <= @sizeOf(SlabHeader) + slot_align) return 0;
        const usable: usize = SLAB_SIZE - @sizeOf(SlabHeader) - slot_align;
        const per_slot: usize = slot_size + @sizeOf(u32);
        return @intCast(usable / per_slot);
    }

    pub const SlabPool = struct {
        classes: [SLAB_CLASS_COUNT]SizeClass,
    };

    pub inline fn slabPoolInit() SlabPool {
        var pool: SlabPool = undefined;
        var class_index: u32 = 0;
        while (class_index < SLAB_CLASS_COUNT) : (class_index += 1) {
            pool.classes[class_index] = .{
                .current = null,
                .partials = null,
                .cached_empty = null,
            };
        }
        return pool;
    }

    pub fn mmapAlignedSlab() ?[*]align(std.heap.page_size_min) u8 {
        const page_size = std.heap.page_size_min;
        std.debug.assert(SLAB_SIZE % page_size == 0);
        const overalloc_len: usize = SLAB_SIZE + SLAB_ALIGN - page_size;
        const raw = std.posix.mmap(
            null,
            overalloc_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return null;
        const raw_addr = @intFromPtr(raw.ptr);
        const aligned_addr = std.mem.alignForward(usize, raw_addr, SLAB_ALIGN);
        const head_bytes = aligned_addr - raw_addr;
        const tail_bytes = overalloc_len - head_bytes - SLAB_SIZE;
        if (head_bytes != 0) {
            std.posix.munmap(@alignCast(raw[0..head_bytes]));
        }
        if (tail_bytes != 0) {
            const tail_start = head_bytes + SLAB_SIZE;
            std.posix.munmap(@alignCast(raw[tail_start..(tail_start + tail_bytes)]));
        }
        const aligned_ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(aligned_addr);
        return aligned_ptr;
    }

    pub fn unmapSlab(base: [*]align(std.heap.page_size_min) u8) void {
        const slab_slice = base[0..SLAB_SIZE];
        std.posix.munmap(@alignCast(slab_slice));
    }

    pub fn slabInit(slab: *SlabHeader, class_index: u32, owner: *anyopaque, base: [*]align(std.heap.page_size_min) u8) void {
        const capacity = capacityForClass(class_index);
        slab.* = .{
            .magic = SLAB_MAGIC,
            .class_index = class_index,
            .live_count = 0,
            .free_list_head = NULL_SLOT,
            .bump_index = 0,
            .capacity = capacity,
            .prev = null,
            .next = null,
            .allocation_base = base,
            .owner = owner,
        };
        const refcount_ptr_byte: [*]u8 = @ptrCast(slab);
        const refcount_bytes_ptr = refcount_ptr_byte + @sizeOf(SlabHeader);
        const refcount_bytes_count: usize = @as(usize, capacity) * @sizeOf(u32);
        @memset(refcount_bytes_ptr[0..refcount_bytes_count], 0);
    }

    pub inline fn slabRefcountPtr(slab: *SlabHeader, index: u32) *u32 {
        const base: [*]u8 = @ptrCast(slab);
        const table: [*]u32 = @ptrCast(@alignCast(base + @sizeOf(SlabHeader)));
        return &table[index];
    }

    pub inline fn slabSlotPtr(slab: *SlabHeader, index: u32) [*]u8 {
        const base: [*]u8 = @ptrCast(slab);
        const offset = slotsOffsetForClass(slab.class_index, slab.capacity);
        const slot_size: usize = SLAB_CLASS_SIZES[slab.class_index];
        return base + offset + slot_size * @as(usize, index);
    }

    pub inline fn slabFromSlotPtr(ptr: *anyopaque) *SlabHeader {
        const ptr_addr = @intFromPtr(ptr);
        const slab_addr = ptr_addr & SLAB_BASE_MASK;
        const slab: *SlabHeader = @ptrFromInt(slab_addr);
        return slab;
    }

    pub inline fn slotIndexInSlab(slab: *SlabHeader, ptr: *anyopaque) u32 {
        const base_addr = @intFromPtr(slab);
        const ptr_addr = @intFromPtr(ptr);
        const offset = ptr_addr - base_addr - slotsOffsetForClass(slab.class_index, slab.capacity);
        const slot_size: usize = SLAB_CLASS_SIZES[slab.class_index];
        return @intCast(offset / slot_size);
    }

    pub fn pushPartial(class: *SizeClass, slab: *SlabHeader) void {
        slab.prev = null;
        slab.next = class.partials;
        if (class.partials) |head| {
            head.prev = slab;
        }
        class.partials = slab;
    }

    pub fn unlinkPartial(class: *SizeClass, slab: *SlabHeader) void {
        if (slab.prev) |prev_slab| {
            prev_slab.next = slab.next;
        } else if (class.partials == slab) {
            class.partials = slab.next;
        }
        if (slab.next) |next_slab| {
            next_slab.prev = slab.prev;
        }
        slab.prev = null;
        slab.next = null;
    }

    pub inline fn slabOnPartialList(class: *SizeClass, slab: *SlabHeader) bool {
        return slab.prev != null or class.partials == slab;
    }

    pub fn acquireSlab(pool: *SlabPool, class_index: u32) ?*SlabHeader {
        const class = &pool.classes[class_index];
        if (class.cached_empty) |cached| {
            class.cached_empty = null;
            cached.live_count = 0;
            cached.free_list_head = NULL_SLOT;
            cached.bump_index = 0;
            cached.prev = null;
            cached.next = null;
            const ref_ptr_byte: [*]u8 = @ptrCast(cached);
            const refcount_bytes_ptr = ref_ptr_byte + @sizeOf(SlabHeader);
            const refcount_bytes_count: usize = @as(usize, cached.capacity) * @sizeOf(u32);
            @memset(refcount_bytes_ptr[0..refcount_bytes_count], 0);
            return cached;
        }
        if (class.partials) |partial| {
            unlinkPartial(class, partial);
            return partial;
        }
        const aligned_base = mmapAlignedSlab() orelse return null;
        const slab: *SlabHeader = @ptrCast(@alignCast(aligned_base));
        slabInit(slab, class_index, @ptrCast(class), aligned_base);
        return slab;
    }

    pub fn slabAllocSlot(pool: *SlabPool, class_index: u32, init_refcount: u32) ?[*]u8 {
        const class = &pool.classes[class_index];
        var slab: *SlabHeader = class.current orelse blk: {
            const acquired = acquireSlab(pool, class_index) orelse return null;
            class.current = acquired;
            break :blk acquired;
        };
        while (true) {
            if (slab.free_list_head != NULL_SLOT) {
                const slot_index = slab.free_list_head;
                const slot_bytes = slabSlotPtr(slab, slot_index);
                const free_node: *u32 = @ptrCast(@alignCast(slot_bytes));
                slab.free_list_head = free_node.*;
                slab.live_count += 1;
                slabRefcountPtr(slab, slot_index).* = init_refcount;
                return slot_bytes;
            }
            if (slab.bump_index < slab.capacity) {
                const slot_index = slab.bump_index;
                slab.bump_index += 1;
                slab.live_count += 1;
                const slot_bytes = slabSlotPtr(slab, slot_index);
                slabRefcountPtr(slab, slot_index).* = init_refcount;
                return slot_bytes;
            }
            class.current = null;
            const fresh = acquireSlab(pool, class_index) orelse return null;
            class.current = fresh;
            slab = fresh;
        }
    }

    pub fn slabFreeSlot(pool: *SlabPool, slab: *SlabHeader, slot_index: u32) void {
        const class: *SizeClass = @ptrCast(@alignCast(slab.owner));
        _ = pool;
        const was_full = slab.free_list_head == NULL_SLOT and slab.bump_index >= slab.capacity;
        const slot_bytes = slabSlotPtr(slab, slot_index);
        const free_node: *u32 = @ptrCast(@alignCast(slot_bytes));
        free_node.* = slab.free_list_head;
        slab.free_list_head = slot_index;
        std.debug.assert(slab.live_count > 0);
        slab.live_count -= 1;
        slabRefcountPtr(slab, slot_index).* = 0;
        if (slab == class.current) return;
        if (slab.live_count == 0) {
            if (slabOnPartialList(class, slab)) {
                unlinkPartial(class, slab);
            }
            if (class.cached_empty == null) {
                class.cached_empty = slab;
            } else {
                unmapSlab(slab.allocation_base);
            }
            return;
        }
        if (was_full) {
            pushPartial(class, slab);
        }
    }

    pub const LargeHeader = extern struct {
        magic: u32,
        _pad0: u32,
        size: usize,
        alignment: u32,
        refcount: u32,
    };

    pub inline fn largeLeadingFor(alignment: u32) usize {
        const min_lead: usize = @sizeOf(LargeHeader);
        const aligned_lead: usize = std.mem.alignForward(usize, min_lead, alignment);
        return aligned_lead;
    }

    pub fn largeAlloc(size: usize, alignment: u32, init_refcount: u32) ?[*]u8 {
        const leading = largeLeadingFor(alignment);
        const total = std.math.add(usize, leading, size) catch return null;
        const inner_alignment: std.mem.Alignment = .fromByteUnits(@max(alignment, @as(u32, @intCast(std.heap.page_size_min))));
        const base = std.heap.page_allocator.rawAlloc(total, inner_alignment, @returnAddress()) orelse return null;
        const header_ptr: *LargeHeader = @ptrCast(@alignCast(base + leading - @sizeOf(LargeHeader)));
        header_ptr.* = .{
            .magic = LARGE_MAGIC,
            ._pad0 = 0,
            .size = size,
            .alignment = alignment,
            .refcount = init_refcount,
        };
        return base + leading;
    }

    pub fn largeFree(ptr: [*]u8) void {
        const header_ptr: *LargeHeader = @ptrCast(@alignCast(ptr - @sizeOf(LargeHeader)));
        // Mirror the production manager: magic mismatch is fatal
        // corruption — panic even in release rather than munmap an
        // arbitrary memory range.
        if (header_ptr.magic != LARGE_MAGIC) @panic("zap.test_arc: largeFree: corrupt LargeHeader magic (pointer not owned by this manager or double-free)");
        const alignment = header_ptr.alignment;
        const leading = largeLeadingFor(alignment);
        const total = leading + header_ptr.size;
        const base: [*]u8 = ptr - leading;
        const inner_alignment: std.mem.Alignment = .fromByteUnits(@max(alignment, @as(u32, @intCast(std.heap.page_size_min))));
        std.heap.page_allocator.rawFree(base[0..total], inner_alignment, @returnAddress());
    }

    pub inline fn largeHeader(ptr: *anyopaque) *LargeHeader {
        const byte_ptr: [*]u8 = @ptrCast(ptr);
        return @ptrCast(@alignCast(byte_ptr - @sizeOf(LargeHeader)));
    }
} else struct {};

/// Static context for the test-only ARC manager. Allocated as a fixed
/// global storage so it lives for the test process's lifetime; the
/// embedded `SlabPool` carries the actual byte-keyed allocation state.
/// Only present in test builds; `if (builtin.is_test)` is a comptime
/// constant so the variable is comptime-removed from production
/// binaries.
var test_only_arc_context_storage: if (builtin.is_test) struct {
    slab_pool: TestOnlyArcSlabPool.SlabPool,
} else void = if (builtin.is_test)
    .{ .slab_pool = TestOnlyArcSlabPool.slabPoolInit() }
else {};

fn testOnlyArcInit(options: ?*const AbiV1.ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    return @ptrCast(&test_only_arc_context_storage);
}

fn testOnlyArcDeinit(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
    // Tests deliberately do not free the slab pool — the test process
    // exits and the OS reclaims every mmap'd page. Mirrors how the
    // production manager's `arcDeinit` is best-effort.
}

/// Raw allocation slot. Routes through the test-only slab pool the
/// same way the production manager's `arcAllocate` does. Returns
/// `null` for zero-size allocations (spec §4.2 contract).
fn testOnlyArcAllocateRaw(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    if (size == 0) return null;
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    if (!builtin.is_test) return null;
    const tctx: *@TypeOf(test_only_arc_context_storage) = @ptrCast(@alignCast(ctx));
    if (TestOnlyArcSlabPool.lookupClass(size, alignment)) |class_index| {
        return TestOnlyArcSlabPool.slabAllocSlot(&tctx.slab_pool, class_index, 0);
    }
    return TestOnlyArcSlabPool.largeAlloc(size, alignment, 0);
}

/// Raw deallocation slot. Returns slab slots to the free list; unmaps
/// large allocations.
fn testOnlyArcDeallocateRaw(
    ctx: *anyopaque,
    ptr: [*]u8,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    if (size == 0) return;
    if (!builtin.is_test) return;
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    const tctx: *@TypeOf(test_only_arc_context_storage) = @ptrCast(@alignCast(ctx));
    if (TestOnlyArcSlabPool.lookupClass(size, alignment)) |_| {
        const slab = TestOnlyArcSlabPool.slabFromSlotPtr(ptr);
        std.debug.assert(slab.magic == TestOnlyArcSlabPool.SLAB_MAGIC);
        const slot_index = TestOnlyArcSlabPool.slotIndexInSlab(slab, ptr);
        TestOnlyArcSlabPool.slabFreeSlot(&tctx.slab_pool, slab, slot_index);
        return;
    }
    TestOnlyArcSlabPool.largeFree(ptr);
}

fn testOnlyArcAllocateRefcounted(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    if (size == 0) return null;
    if (!builtin.is_test) return null;
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    const tctx: *@TypeOf(test_only_arc_context_storage) = @ptrCast(@alignCast(ctx));
    if (TestOnlyArcSlabPool.lookupClass(size, alignment)) |class_index| {
        return TestOnlyArcSlabPool.slabAllocSlot(&tctx.slab_pool, class_index, 1);
    }
    return TestOnlyArcSlabPool.largeAlloc(size, alignment, 1);
}

fn testOnlyArcGetCapabilityDesc(
    ctx: *anyopaque,
    id: u32,
) callconv(.c) ?*const AbiV1.ZapCapabilityDescV1 {
    _ = ctx;
    if (id == AbiV1.REFC_TAG) return &test_only_arc_refcount_descriptor;
    return null;
}

/// REFCOUNT_V1 `retain` for cells with the refcount at offset 0.
/// Atomic increment on the 4-byte refcount with `monotonic` ordering
/// (the release fence lives in `testOnlyArcRelease`).
fn testOnlyArcRetain(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    const refcount_ptr: *std.atomic.Value(u32) = @ptrCast(@alignCast(object));
    _ = refcount_ptr.fetchAdd(1, .monotonic);
}

/// REFCOUNT_V1 `release` for cells with the refcount at offset 0.
/// Atomic decrement; on the zero-transition invoke `deep_walk(object)`
/// if non-null. Asserts `prev > 0` for symmetry with the production
/// `arcRelease` in `src/memory/arc/manager.zig`: releasing a cell whose
/// refcount is already zero is undefined under spec §8.2, so catch the
/// regression at the call site rather than at the corruption downstream.
fn testOnlyArcRelease(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?AbiV1.ZapDeepWalkFn,
) callconv(.c) void {
    _ = ctx;
    const refcount_ptr: *std.atomic.Value(u32) = @ptrCast(@alignCast(object));
    const prev = refcount_ptr.fetchSub(1, .acq_rel);
    std.debug.assert(prev > 0);
    if (prev == 1) {
        if (deep_walk) |walk| walk(object);
    }
}

fn testOnlyArcRetainSized(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    _ = ctx;
    if (!builtin.is_test) return;
    // Mirror the production manager's defensive checks
    // (`arcRetainSized` in `src/memory/arc/manager.zig`). The
    // testOnly pool exists to exercise the exact same vtable surface
    // as production, so the param-validation contract must match.
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    if (size == 0) return;
    if (TestOnlyArcSlabPool.lookupClass(size, alignment)) |class_index| {
        const slab = TestOnlyArcSlabPool.slabFromSlotPtr(object);
        std.debug.assert(slab.magic == TestOnlyArcSlabPool.SLAB_MAGIC);
        std.debug.assert(slab.class_index == class_index);
        const slot_index = TestOnlyArcSlabPool.slotIndexInSlab(slab, object);
        const refcount_ptr = TestOnlyArcSlabPool.slabRefcountPtr(slab, slot_index);
        const atomic_ptr: *std.atomic.Value(u32) = @ptrCast(@alignCast(refcount_ptr));
        _ = atomic_ptr.fetchAdd(1, .monotonic);
        return;
    }
    const header = TestOnlyArcSlabPool.largeHeader(object);
    if (header.magic != TestOnlyArcSlabPool.LARGE_MAGIC) @panic("zap.test_arc: retain_sized large path: corrupt LargeHeader magic");
    const atomic_ptr: *std.atomic.Value(u32) = @ptrCast(@alignCast(&header.refcount));
    _ = atomic_ptr.fetchAdd(1, .monotonic);
}

fn testOnlyArcReleaseSized(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
    deep_walk: ?AbiV1.ZapDeepWalkFn,
) callconv(.c) void {
    if (!builtin.is_test) return;
    const tctx: *@TypeOf(test_only_arc_context_storage) = @ptrCast(@alignCast(ctx));
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    if (size == 0) return;
    if (TestOnlyArcSlabPool.lookupClass(size, alignment)) |class_index| {
        const slab = TestOnlyArcSlabPool.slabFromSlotPtr(object);
        std.debug.assert(slab.magic == TestOnlyArcSlabPool.SLAB_MAGIC);
        std.debug.assert(slab.class_index == class_index);
        const slot_index = TestOnlyArcSlabPool.slotIndexInSlab(slab, object);
        const refcount_ptr = TestOnlyArcSlabPool.slabRefcountPtr(slab, slot_index);
        const atomic_ptr: *std.atomic.Value(u32) = @ptrCast(@alignCast(refcount_ptr));
        const prev = atomic_ptr.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
        if (prev == 1) {
            if (deep_walk) |walk| walk(object);
            TestOnlyArcSlabPool.slabFreeSlot(&tctx.slab_pool, slab, slot_index);
        }
        return;
    }
    const header = TestOnlyArcSlabPool.largeHeader(object);
    if (header.magic != TestOnlyArcSlabPool.LARGE_MAGIC) @panic("zap.test_arc: release_sized large path: corrupt LargeHeader magic");
    const atomic_ptr: *std.atomic.Value(u32) = @ptrCast(@alignCast(&header.refcount));
    const prev = atomic_ptr.fetchSub(1, .acq_rel);
    std.debug.assert(prev > 0);
    if (prev == 1) {
        if (deep_walk) |walk| walk(object);
        const byte_ptr: [*]u8 = @ptrCast(object);
        TestOnlyArcSlabPool.largeFree(byte_ptr);
    }
}

fn testOnlyArcRefcountSized(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) u32 {
    _ = ctx;
    if (!builtin.is_test) return 0;
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    if (size == 0) return 0;
    if (TestOnlyArcSlabPool.lookupClass(size, alignment)) |class_index| {
        const slab = TestOnlyArcSlabPool.slabFromSlotPtr(object);
        std.debug.assert(slab.magic == TestOnlyArcSlabPool.SLAB_MAGIC);
        std.debug.assert(slab.class_index == class_index);
        const slot_index = TestOnlyArcSlabPool.slotIndexInSlab(slab, object);
        const refcount_ptr = TestOnlyArcSlabPool.slabRefcountPtr(slab, slot_index);
        const atomic_ptr: *std.atomic.Value(u32) = @ptrCast(@alignCast(refcount_ptr));
        return atomic_ptr.load(.acquire);
    }
    const header = TestOnlyArcSlabPool.largeHeader(object);
    if (header.magic != TestOnlyArcSlabPool.LARGE_MAGIC) @panic("zap.test_arc: refcount_sized large path: corrupt LargeHeader magic");
    const atomic_ptr: *std.atomic.Value(u32) = @ptrCast(@alignCast(&header.refcount));
    return atomic_ptr.load(.acquire);
}

const test_only_arc_refcount_vtable: AbiV1.ZapRefcountCapabilityV1 = .{
    .retain = testOnlyArcRetain,
    .release = testOnlyArcRelease,
    .retain_sized = testOnlyArcRetainSized,
    .release_sized = testOnlyArcReleaseSized,
    .allocate_refcounted = testOnlyArcAllocateRefcounted,
    .refcount_sized = testOnlyArcRefcountSized,
};

const test_only_arc_refcount_descriptor: AbiV1.ZapCapabilityDescV1 = .{
    .id = AbiV1.REFC_TAG,
    .version = 1,
    .size = @sizeOf(AbiV1.ZapRefcountCapabilityV1),
    .flags = 0,
    .vtable = @ptrCast(&test_only_arc_refcount_vtable),
};

/// Test-only v1.0 REFCOUNT_V1 vtable shape: just `retain` and
/// `release`. The struct is exactly 16 bytes — matches
/// `REFCOUNT_V1_SIZE_V1_0` — so a descriptor referencing it
/// exercises the runtime's v1.0 forward-compatibility branch
/// (`!active_manager_state.refcount_has_sized_extension`).
///
/// The two slot functions are reused from the v1.1 vtable above
/// because the v1.0 contract is a subset: `retain(ctx, object)` /
/// `release(ctx, object, deep_walk)` operate on the inline 4-byte
/// refcount at offset 0 of the cell, which under the runtime's
/// v1.0 fallback is the `ArcHeader` at the cell base (laid out by
/// `LegacyArcInnerLayout`). The same functions service both
/// vtables without re-implementation.
const TestOnlyArcRefcountV1_0Vtable = extern struct {
    retain: *const fn (ctx: *anyopaque, object: *anyopaque) callconv(.c) void,
    release: *const fn (ctx: *anyopaque, object: *anyopaque, deep_walk: ?AbiV1.ZapDeepWalkFn) callconv(.c) void,
};

comptime {
    if (@sizeOf(TestOnlyArcRefcountV1_0Vtable) != AbiV1.REFCOUNT_V1_SIZE_V1_0) @compileError(
        "TestOnlyArcRefcountV1_0Vtable must be exactly REFCOUNT_V1_SIZE_V1_0 (16 bytes)",
    );
}

const test_only_arc_v1_0_refcount_vtable: TestOnlyArcRefcountV1_0Vtable = .{
    .retain = testOnlyArcRetain,
    .release = testOnlyArcRelease,
};

const test_only_arc_v1_0_refcount_descriptor: AbiV1.ZapCapabilityDescV1 = .{
    .id = AbiV1.REFC_TAG,
    .version = 1,
    .size = AbiV1.REFCOUNT_V1_SIZE_V1_0,
    .flags = 0,
    .vtable = @ptrCast(&test_only_arc_v1_0_refcount_vtable),
};

/// Test-only saved state for swapping the active REFCOUNT_V1
/// descriptor between v1.0 and v1.1 shapes during a single test.
/// `saveActiveRefcountCapabilityForTest` records the current
/// (cap_ptr, has_sized_extension) tuple into this storage so the
/// test's `defer` block can call
/// `restoreActiveRefcountCapabilityForTest` and put the runtime
/// back exactly the way the surrounding tests expect to find it.
///
/// Single-threaded by design — tests share a process. If parallel
/// tests are ever enabled, the swap APIs must take a per-thread
/// override map instead.
const TestOnlyArcCapabilitySaveSlot = struct {
    capability: ?*const AbiV1.ZapRefcountCapabilityV1,
    has_sized_extension: bool,
    composed_vtable_snapshot: AbiV1.ZapRefcountCapabilityV1,
};

var test_only_arc_capability_save_slot: TestOnlyArcCapabilitySaveSlot = undefined;

/// Test-only helper: install a new active REFCOUNT_V1 descriptor for
/// the duration of a test. Hooks into the same `bindRefcountCapability`
/// path the runtime startup uses, so v1.0 / v1.1 selection follows
/// the production logic. The save slot snapshots
/// `v1_0_composed_refcount_vtable` because the next bind call will
/// overwrite that buffer; restoring copies the snapshot back so any
/// dispatch that captured the cap pointer earlier in startup keeps
/// seeing the original bytes.
///
/// Returns a save token whose `restoreActiveRefcountCapabilityForTest`
/// call MUST run inside the test's `defer` block — even on a test
/// failure path — so the next test sees the pre-swap state.
fn saveActiveRefcountCapabilityForTest() void {
    test_only_arc_capability_save_slot = .{
        .capability = active_manager_state.refcount_capability,
        .has_sized_extension = active_manager_state.refcount_has_sized_extension,
        .composed_vtable_snapshot = v1_0_composed_refcount_vtable,
    };
}

fn restoreActiveRefcountCapabilityForTest() void {
    v1_0_composed_refcount_vtable = test_only_arc_capability_save_slot.composed_vtable_snapshot;
    active_manager_state.refcount_capability = test_only_arc_capability_save_slot.capability;
    active_manager_state.refcount_has_sized_extension = test_only_arc_capability_save_slot.has_sized_extension;
}

fn installRefcountCapabilityForTest(desc: *const AbiV1.ZapCapabilityDescV1) void {
    bindRefcountCapability(desc);
}

/// Test-only ARC core vtable. The compile-time default value of
/// `active_manager_state.core` points here in test builds; in
/// production builds the default is `null` and the externally-linked
/// manager `.o` provides the active vtable via the `.zapmem` section.
pub const test_only_arc_core: AbiV1.ZapMemoryManagerCoreV1 = .{
    .abi_major = 1,
    .abi_minor = 0,
    .size = @sizeOf(AbiV1.ZapMemoryManagerCoreV1),
    .declared_caps = AbiV1.REFCOUNT_V1_BIT,
    .init = testOnlyArcInit,
    .deinit = testOnlyArcDeinit,
    .allocate = testOnlyArcAllocateRaw,
    .deallocate = testOnlyArcDeallocateRaw,
    .get_capability_desc = testOnlyArcGetCapabilityDesc,
};

// ----------------------------------------------------------------
// External-manager bootstrap (Phase 3, spec section 10.2).
//
// Every production Zap binary links an external manager `.o` — the
// first-party `src/memory/arc/manager.zig` by default, or whatever
// the manifest's `memory:` field selects. That object's `.zapmem`
// section ships in the binary as a single composite
// `ZapMemorySection` symbol exported under the conventional name
// `zap_memory_section`. The runtime detects the symbol via a weakly-
// linked extern reference: when the symbol resolves, its `core` field
// becomes the active manager's core vtable. The weak-linkage choice
// is what makes the test-build path possible: `zig build test`
// compiles the runtime module directly without going through the
// production build pipeline, so no manager `.o` is linked and the
// weak symbol resolves to null. In that case the runtime falls
// through to the `test_only_arc_*` fallback defined above (see the
// "Test-only ARC manager fallback" block).
//
// We model only the leading prefix of the section here — the meta
// header followed by the core vtable — because the runtime never
// touches the trailing descriptor array; the build-time driver in
// `src/memory/driver.zig` validates the descriptor table before the
// link step, so the runtime treats `core` as the authoritative
// entrypoint.
//
// Weak linkage is critical: in a test build the symbol is genuinely
// absent. A strong extern would produce an unresolved-symbol link
// error. Weak references resolve to null when the symbol is missing —
// exactly the discrimination the bootstrap needs to fall back to the
// `test_only_arc_*` path.
//
// Phase 4 ripped the in-runtime ARC stub out entirely; the rebinding
// here is now the only path through which a production binary
// acquires a refcount-capable manager.
// ----------------------------------------------------------------

/// Shape of the external manager's `.zapmem` section payload. Mirrors
/// the composite struct documented in spec section 3.2 and the layout
/// the no-op manager at `src/memory/no_op/manager.zig` emits.
const ExternalMemorySectionPrefix = extern struct {
    meta: extern struct {
        magic: u32,
        abi_major: u16,
        abi_minor: u16,
        size: u16,
        _reserved2: u16,
        desc_count: u32,
        declared_caps: u64,
        core_vtable_offset: u32,
        reserved: u32,
    },
    core: AbiV1.ZapMemoryManagerCoreV1,
};

/// Weakly-linked external symbol exported by the active memory manager
/// object file. Every production Zap binary links exactly one such
/// `.o` — the first-party `src/memory/arc/manager.zig` by default,
/// or whatever the manifest's `memory:` field selects — so in
/// production this pointer always resolves to a real section.
///
/// Declared via `@extern` with `.linkage = .weak` so the linker accepts
/// "symbol not found" as a valid resolution that yields null. The
/// "yields null" branch is exercised only by `zig build test`, where
/// the runtime module compiles directly without going through the
/// libzap_compiler.a-driven binary pipeline that would otherwise
/// produce and link a manager `.o`.
///
/// In test builds the link step would still reject an undefined weak
/// reference, so the `is_test` gate substitutes a literal `null`.
/// The test path then falls through to the `test_only_arc_*` vtable
/// declared in the "Test-only ARC manager fallback" block above
/// (`active_manager_state.core` is initialised to `&test_only_arc_core`
/// when `builtin.is_test` is true). The compiler-driven binary
/// pipeline retains the real weak extern.
fn externalMemorySection() ?*const ExternalMemorySectionPrefix {
    if (builtin.is_test) return null;
    return @extern(
        ?*const ExternalMemorySectionPrefix,
        .{ .name = "zap_memory_section", .linkage = .weak },
    );
}

/// Re-point `active_manager_state.core` at the externally-linked manager
/// if one is present. Called once at the top of `zapMemoryStartup`
/// before any vtable function fires.
///
/// Validates the section header just enough to refuse to dispatch
/// against an obviously-corrupt manager — magic, ABI major, and core
/// size. The build-time driver already performed the full validation
/// matrix per spec section 3.5; this is a defensive double-check that
/// catches link-time mis-splicing (wrong file linked, accidental data
/// corruption, etc.).
fn maybeBindExternalManager() void {
    const section = externalMemorySection() orelse return;

    // The Phase 1 spike's `section_parser` writes the magic value at
    // section offset 0; reuse the same comparison here. Mismatches in
    // a binary that DID resolve the weak symbol indicate either a
    // build-driver bug or a deliberate corruption — neither path is
    // recoverable from at runtime.
    if (section.meta.magic != ZMEM_MAGIC_NATIVE) {
        @panic("zap runtime: external memory manager section has invalid magic");
    }
    if (section.meta.abi_major != 1) {
        @panic("zap runtime: external memory manager declares unsupported ABI major");
    }
    // Lower and upper bound on `meta.size`. The build-time driver applies
    // the same caps (`MAX_META_SIZE`). The runtime doesn't use `meta.size`
    // for offset arithmetic (the section parser handed off the bytes
    // already), so these checks are defensive depth — they catch a binary
    // that bypassed the driver entirely (hand-edited section, post-link
    // patch) and refuse to dispatch through a manager whose header looks
    // structurally implausible.
    const META_SIZE: usize = @sizeOf(@TypeOf(section.meta));
    if (section.meta.size < META_SIZE) {
        @panic("zap runtime: external memory manager metadata header is smaller than v1.0");
    }
    if (section.meta.size > 8 * META_SIZE) {
        @panic("zap runtime: external memory manager metadata header exceeds v1.x upper bound");
    }
    if (section.core.abi_major != 1) {
        @panic("zap runtime: external memory manager core declares unsupported ABI major");
    }
    if (section.core.size < @sizeOf(AbiV1.ZapMemoryManagerCoreV1)) {
        @panic("zap runtime: external memory manager core vtable is smaller than v1.0");
    }
    // Upper bound on `core.size`. The build-time driver applies the
    // same cap (`MAX_CORE_SIZE`); this runtime check guards against
    // a binary that bypassed the driver (e.g., a hand-edited section
    // patched in post-link) and prevents arbitrary-offset reads when
    // future code dispatches through the vtable.
    if (section.core.size > 8 * @sizeOf(AbiV1.ZapMemoryManagerCoreV1)) {
        @panic("zap runtime: external memory manager core vtable exceeds v1.x upper bound");
    }

    // Re-point the active core vtable. In production builds the
    // runtime had `active_manager_state.core` initialised to null and
    // this is the first non-null assignment. In test builds the
    // compile-time default pointed at `&test_only_arc_core`; this
    // function returns early on the `is_test` branch (via
    // `externalMemorySection`), so the test-only fallback survives.
    active_manager_state.core = &section.core;
}

/// FourCC `ZMEM` in the target's native byte order. Identical to the
/// constant the manager emits so the comparison is endianness-correct
/// without endian-conversion overhead at every check.
const ZMEM_MAGIC_NATIVE: u32 = switch (builtin.target.cpu.arch.endian()) {
    .little => 0x4D454D5A,
    .big => 0x5A4D454D,
};

// ----------------------------------------------------------------
// Startup / shutdown hooks.
//
// The Zap compiler does not yet emit a call to `zapMemoryStartup`
// at the top of user `main` (Phase 3 wires that). Phase 2 makes the
// startup hook self-arming: the `ArcRuntime` dispatchers below call
// `ensureMemoryStartup()` on entry, which runs init exactly once and
// registers `zapMemoryShutdownAtexit` via libc `atexit` so the
// matching deinit runs on process exit without any compiler help.
// Subsequent dispatcher calls pay a single boolean compare.
//
// This is the same pattern existing runtime subsystems use
// (`ensureStdoutAtexit`, `ensureArcStatsAtexit`) — the runtime opts
// into atexit registration on first use rather than requiring the
// compiler to emit an explicit `init` call.
// ----------------------------------------------------------------

fn zapMemoryStartup() void {
    if (active_manager_state.started) return;

    // Spec §10.2: walk the linked-in `.zapmem` section to discover
    // the active manager's vtable. Phase 4 removed the built-in ARC
    // stub from the runtime so this binding is the SOLE source of
    // the active manager in production builds. In test builds the
    // compile-time default of `active_manager_state.core` points at
    // the in-source `test_only_arc_core` fallback and
    // `maybeBindExternalManager` returns early (the weak extern is
    // not linked under `zig build test`).
    maybeBindExternalManager();

    const core = active_manager_state.core orelse {
        @panic("zap runtime: no active memory manager bound at startup");
    };
    if (core.abi_major != 1) {
        @panic("zap runtime: active memory manager declares an unsupported ABI major version (expected 1)");
    }
    // Lower bound: refuse a vtable struct smaller than the v1.0 base
    // size (catches truncated section payloads). The spec also allows
    // `core.size` to be LARGER than the v1.0 size when the manager
    // was built against a newer minor revision that added trailing
    // fields; the runtime only reads the v1.0 fields, so the trailer
    // is ignored. Upper-bound check below catches absurd sizes that
    // could mean the section was post-link patched or corrupted —
    // the same cap (`8 * sizeof(v1.0 core)`) the build-time driver
    // and `maybeBindExternalManager` apply, keeping all three
    // validation sites in sync.
    if (core.size < @sizeOf(AbiV1.ZapMemoryManagerCoreV1)) {
        @panic("zap runtime: active memory manager's core vtable is smaller than v1.0 (corrupt binary?)");
    }
    if (core.size > 8 * @sizeOf(AbiV1.ZapMemoryManagerCoreV1)) {
        @panic("zap runtime: active memory manager's core vtable exceeds v1.x upper bound (corrupt binary?)");
    }

    // `ZapInitOptions` plumbing: a Phase 5.x build-manifest extension
    // will carry per-manager configuration into a stack-resident
    // `ZapInitOptions` whose `size` field reflects the caller's
    // knowledge of the option layout (spec §4.1). Phase 4 has no
    // option-bearing manager — both `Zap.Memory.ARC` and the test
    // fallback ignore the parameter — so we pass `null` and the
    // forward-extension contract is satisfied by the spec's "older
    // manager / newer compiler" branch (`options == null`).
    const ctx = core.init(null) orelse {
        @panic("zap runtime: active memory manager's init() returned null");
    };
    active_manager_state.context = ctx;

    if ((core.declared_caps & AbiV1.REFCOUNT_V1_BIT) != 0) {
        const desc = core.get_capability_desc(ctx, AbiV1.REFC_TAG) orelse {
            @panic("zap runtime: active manager declares REFCOUNT_V1 but get_capability_desc(REFC) returned null");
        };
        if (desc.id != AbiV1.REFC_TAG) {
            @panic("zap runtime: REFCOUNT_V1 descriptor has wrong tag");
        }
        if (desc.version != 1) {
            @panic("zap runtime: REFCOUNT_V1 descriptor has unsupported version (expected 1)");
        }
        // The spec (§8.0) defines two named `desc.size` shapes:
        //   * `REFCOUNT_V1_SIZE_V1_0` (16): the v1.0 base — just
        //     `retain` and `release`. The runtime falls back to
        //     `core.allocate` / `core.deallocate` for generic `Arc(T)`
        //     under a v1.0 manager.
        //   * `REFCOUNT_V1_SIZE_V1_1` (48): the v1.1 extension —
        //     adds the side-table refcount slots. The runtime routes
        //     generic `Arc(T)` through `allocate_refcounted` /
        //     `retain_sized` / `release_sized` / `refcount_sized`.
        //
        // Per spec §2.3 forward-extension, any `desc.size` in the
        // closed interval [REFCOUNT_V1_SIZE_V1_0, 8 × sizeof(v1.1)]
        // is accepted. Sizes between v1.0 and v1.1 (e.g., 32 bytes)
        // are unusual but legal — the runtime treats them as v1.0
        // (sized extension absent) via the v1.1 threshold check
        // below (`desc.size >= REFCOUNT_V1_SIZE_V1_1`), so any vtable
        // shorter than the full v1.1 surface stays on the legacy
        // path. The build-time driver in `src/memory/driver.zig`
        // applies the identical bounds; the runtime mirrors the
        // checks as a defence-in-depth tripwire that catches any
        // path that bypasses driver validation (e.g., a future
        // plugin loader).
        if (desc.size < AbiV1.REFCOUNT_V1_SIZE_V1_0) {
            @panic("zap runtime: REFCOUNT_V1 vtable is smaller than v1.0 (16 bytes)");
        }
        if (desc.size > 8 * @sizeOf(AbiV1.ZapRefcountCapabilityV1)) {
            @panic("zap runtime: REFCOUNT_V1 vtable exceeds v1.x upper bound (corrupt binary?)");
        }
        // The v1.1 extension threshold: the manager must advertise
        // at least the full v1.1 vtable size to participate in the
        // side-table refcount path. A v1.0 manager (size == 16)
        // stays compatible — the runtime falls back to
        // `core.allocate` / `core.deallocate` for generic `Arc(T)`
        // and uses only the v1.0 `retain` / `release` slots for
        // inline-header types. `bindRefcountCapability` materialises a
        // composed 48-byte vtable image with trap stubs in slots 2-5
        // when the manager is v1.0, so a future code change that
        // drops the `has_sized_extension` gate would surface a clear
        // diagnostic panic instead of arbitrary-memory dereference.
        bindRefcountCapability(desc);
    }

    // libc's `atexit` returns 0 on success and non-zero on failure;
    // failure here means the C library refused to register the handler
    // (typically because the per-process atexit slot table is full).
    // Treat this as a programmer error in debug builds. The other
    // `ensure*Atexit` registration sites in this file likewise discard
    // the return value; this site asserts because shutdown is the only
    // hook that the spec mandates run before process exit (§10.2).
    //
    // Note: `std.debug.assert` is elided in `ReleaseFast` and
    // `ReleaseSmall`. In those modes a failing `atexit` registration
    // is silently tolerated and the shutdown handler is lost.
    // Acceptable trade-off — atexit failure is extreme and never
    // observed in practice on hosted Linux/macOS, where the slot
    // table is bounded only by available memory.
    std.debug.assert(atexit(zapMemoryShutdownAtexit) == 0);
    active_manager_state.started = true;
}

/// Atexit ordering contract for memory shutdown
/// =============================================
/// `atexit` handlers run in LIFO order: handlers registered last fire
/// first. `zapMemoryShutdownAtexit` is registered by
/// `zapMemoryStartup`, which is itself called by the first ARC
/// dispatch from user code. The existing self-arming atexit handlers
/// (`stdoutAtexitFlush`, `arcStatsAtexit`, `mapInstrumentationAtexit`)
/// are typically registered BEFORE the first ARC dispatch — they fire
/// on first stdout write, first ARC pool registration (when
/// `ZAP_ARC_STATS` is set), and first instrumented Map alloc — so
/// they sit BELOW `zapMemoryShutdownAtexit` on the atexit stack and
/// therefore fire AFTER it at exit time.
///
/// Contract: any atexit handler that may fire AFTER
/// `zapMemoryShutdownAtexit` MUST NOT trigger an ARC dispatch
/// (`allocAny` / `freeAny` / `retainAny` / `retainAnyPersistent` /
/// `releaseAny` / `headerRetain` / `headerRelease`). Doing so will
/// panic with "memory dispatch after shutdown" (Gap 1's guard) — the
/// shutdown deinit'd the active manager's context and dispatching
/// against a deinit'd manager is undefined.
///
/// Current handlers and their compliance with this contract:
///   * `stdoutAtexitFlush`              — only flushes a fixed-size
///                                        byte buffer via `write(2)`;
///                                        no ARC operations.
///   * `arcStatsAtexit`                 — formats counters into stderr;
///                                        no ARC operations (uses
///                                        local stack buffers).
///   * `mapInstrumentationAtexit`       — finalises in-memory records
///                                        and writes JSON via `write(2)`;
///                                        all backing allocations come
///                                        from `std.heap.page_allocator`,
///                                        not the ARC pool.
/// Each of these handler functions carries an explicit comment
/// attesting to that compliance at its header.
fn zapMemoryShutdownAtexit() callconv(.c) void {
    zapMemoryShutdown();
}

fn zapMemoryShutdown() void {
    if (!active_manager_state.started) return;
    if (active_manager_state.shutdown_complete) return;
    const core = active_manager_state.core orelse return;
    const ctx = active_manager_state.context orelse @panic(
        "zap runtime: shutdown invoked with a started manager but no live context (internal bug)",
    );
    core.deinit(ctx);
    // Deliberately do NOT reset `active_manager_state.started`, null
    // `active_manager_state.core`, or null `active_manager_state.context`.
    // The spec (§10.2) requires that the context be written exactly
    // once during the program's lifetime; observability of the
    // post-shutdown state is preserved by leaving the fields at
    // their last-known values. The dispatchers detect post-shutdown
    // dispatch via `active_manager_state.shutdown_complete` instead.
    active_manager_state.shutdown_complete = true;
}

/// Idempotent first-call self-arming wrapper used by every ARC
/// dispatcher. After the first call this is one boolean compare on
/// the hot path; the LLVM optimizer collapses repeated calls inside
/// the same function further.
///
/// Reentrancy and static initialisation guarantees:
///
///  1. Reentrancy: the first call enters `zapMemoryStartup`, which
///     guards its own body with `if (active_manager_state.started) return`
///     placed BEFORE any work runs. If anything inside
///     `zapMemoryStartup` (for example, the manager's `init()` or its
///     descriptor lookup) somehow re-entered `ensureMemoryStartup`,
///     the recursive call would observe `active_manager_state.started == false`
///     and re-enter `zapMemoryStartup` — at which point that nested
///     call would also see `active_manager_state.started == false` and proceed
///     to call `core.init()` a SECOND time. The flag is set at the
///     END of `zapMemoryStartup`, so the recursion guard is currently
///     defensive but does NOT prevent a misbehaved manager from being
///     re-initialised. We rely on the spec §4.2 contract that
///     managers MUST NOT trigger compiler-emitted allocation (and
///     therefore MUST NOT trigger any ARC dispatcher) from inside
///     their own `init`. If a manager violates this contract, the
///     resulting double-init is the manager's bug, not the runtime's.
///
///  2. Static initialisation: there are no static initialisers in
///     user code that reduce to runtime allocations. Zig comptime
///     collapses any such case before runtime startup — any
///     compile-time-known cell sits in `.rodata` or `.data` and
///     never touches an allocator. The first `ensureMemoryStartup`
///     call thus always happens from a user-controlled entry point
///     (typically `main` or the first ARC-touching call from main),
///     not from a hidden module-level initialiser.
inline fn ensureMemoryStartup() void {
    if (!active_manager_state.started) zapMemoryStartup();
}

// ============================================================
// ARC instrumentation counters (Phase 1 of the k-nucleotide RSS
// roadmap — see `docs/k-nucleotide-rss-gap-implementation-plan.md`).
//
// Pure measurement infrastructure: every ARC retain / release path
// in the runtime increments one of these counters, and every pool
// tracks its own per-thread high-water-mark of simultaneously-live
// cells. The Phase 4-5 ownership pass will later populate
// `arc_consumes_total` and `arc_return_elisions_total`; for now they
// stay zero so callers (tests, stat dumps, future passes) have stable
// hooks to drop into.
//
// Setting `ZAP_ARC_STATS=1` in the environment causes the program to
// dump these counters on exit through an `atexit` hook. The dump
// reports global counters, then per-pool registered stats — pool name
// (Zig type name) and per-pool live high-water-mark. Pool HWM is the
// load-bearing signal for the RSS gap: peak resident set ≈ Σ pool HWM,
// regardless of total alloc count, so a bounded HWM under tail
// recursion proves the leak has been closed.
//
// Threading: counters are plain `u64` — Zap is single-threaded today.
// If concurrency lands, swap each `u64` for `std.atomic.Value(u64)`.
// ============================================================

pub var arc_retains_total: u64 = 0;
pub var arc_releases_total: u64 = 0;
pub var arc_consumes_total: u64 = 0;
pub var arc_return_elisions_total: u64 = 0;
/// Number of dense-Map mutating calls (put/delete) that took the
/// rc-1 fast path (mutated the receiver in place).
pub var dense_map_rc1_fast_path_total: u64 = 0;
/// Total dense-Map mutating calls.
pub var dense_map_mut_calls_total: u64 = 0;
/// Number of dense-Map `*_owned_unchecked` calls — mutations the
/// uniqueness verifier proved statically uniquely owned, so the runtime
/// skipped the `header.count() == 1` branch entirely. Comparing
/// against `dense_map_mut_calls_total` gives the uniqueness-coverage ratio.
pub var dense_map_unchecked_total: u64 = 0;
/// Total dense-Map `cloneBufferRetainingChildren` calls — every time
/// we have to deep-retain-clone a Map buffer because a put/delete saw
/// shared ownership. Each clone is one full c_allocator allocation
/// proportional to the Map's capacity, so this counter directly
/// surfaces leak-shaped allocation pressure that escapes the rc=1
/// fast path.
pub var dense_map_retaining_clone_total: u64 = 0;
/// Total dense-Map clone bytes — sum of buffer sizes for every
/// `cloneBufferRetainingChildren` call. The difference between this
/// and the steady-state Map size shows how much c_allocator traffic
/// shared-clone shape is producing.
pub var dense_map_retaining_clone_bytes: u64 = 0;
/// Number of `MapIter` cells allocated. Map iteration through the
/// Enumerable protocol allocates one iter cell per iteration scope
/// (e.g. one per Enum.reduce on a Map). Each iter step is O(1) work
/// against the source map — no per-step allocation, no clones.
pub var dense_map_iter_alloc_total: u64 = 0;
/// Number of `MapIter` cells freed. Symmetric to
/// `dense_map_iter_alloc_total` — when iter rc hits zero the cell
/// is unmapped via its slab pool and the source map's refcount is
/// dropped.
pub var dense_map_iter_free_total: u64 = 0;
/// Total iter cursor advances across the lifetime of the process.
/// Each `Map.next` called on an iter cell increments this; the
/// always-clone fallback (commit 89775b0) is gone, so this counts
/// the O(1) advance steps that replaced O(N) clones.
pub var dense_map_iter_advance_total: u64 = 0;
/// Debug counter for `Map.release` dispatching to the iter-cell
/// release path (i.e., calls where the receiver's `capacity` was 0).
/// Used to diagnose iter-cell ARC discipline; usually matches
/// `dense_map_iter_free_total + (iter cells with rc>1 across release)`.
pub var map_release_iter_dispatch_total: u64 = 0;
/// Number of `List.set/push/pop/append` calls that took the rc-1
/// fast path (mutated the receiver in place rather than cloning).
pub var list_rc1_fast_path_total: u64 = 0;
/// Total `List.set/push/pop/append` calls. Comparing
/// `list_rc1_fast_path_total` against this gives the
/// share-vs-mutate ratio for List workloads, mirroring the
/// dense-Map counters.
pub var list_mut_calls_total: u64 = 0;
/// Number of List `*_owned_unchecked` calls — mutations that
/// uniqueness proved statically uniquely owned. See
/// `dense_map_unchecked_total` for the symmetric meaning on Maps.
pub var list_unchecked_total: u64 = 0;
/// Total List `cons` calls — `[head | tail]` syntax. Each cons
/// allocates a fresh buffer of size `tail_len + 1` and copies all of
/// `tail` into it, even on rc=1 ownership. High-volume cons traffic
/// in the user program creates intermediate buffers that may not be
/// freed quickly enough by the c_allocator (depending on call
/// patterns), so this counter exposes whether the workload depends
/// on cons.
pub var list_cons_calls_total: u64 = 0;
pub var list_cons_alloc_bytes: u64 = 0;
/// Total List `cloneBufferRetainingChildren` calls — the shared-path
/// clone that happens when push/append/set sees a multi-owner List.
/// Surfaces leak shapes that escape rc=1 fast paths.
pub var list_retaining_clone_total: u64 = 0;
pub var list_retaining_clone_bytes: u64 = 0;
/// List release that did NOT bring rc to zero (the cell stays
/// alive). When this count is high relative to allocations, the
/// program is holding shared owners somewhere and freed buffers
/// piling up at MALLOC_SMALL level is the visible symptom.
pub var list_release_kept_alive_total: u64 = 0;
/// List release that did bring rc to zero (the buffer is freed).
pub var list_release_freed_total: u64 = 0;
pub var list_cons_rc1_inplace_total: u64 = 0;
pub var list_cons_rc1_grow_total: u64 = 0;
pub var list_cons_shared_total: u64 = 0;

// Phase 4.x: `PoolStats` and `pool_stats_head` were removed. The
// per-type slab pool infrastructure (`ArcRuntime.ArcSlabPool(T)` /
// `ArcRuntime.ArcPool(T)`) registered into `pool_stats_head` for the
// `ZAP_ARC_STATS=1` dump; with that infrastructure gone, no caller
// remains. The byte-keyed slab pool inside the manager
// (`src/memory/arc/manager.zig` and the test-only mirror
// `TestOnlyArcSlabPool`) owns its own bookkeeping and exposes it via
// the manager's vtable rather than through this in-runtime registry.

/// Print the global ARC counters and every registered pool's
/// high-water-mark through `write_line`. The callback indirection lets
/// the same dump routine target stderr (the atexit hook) and arbitrary
/// future sinks (test capture buffers, log files) without depending on
/// the std.Io writer interface — this file is shared between the
/// compiler-host process and the Zap-binary runtime, and the latter
/// must avoid pulling in any std.Io infrastructure that the embedded
/// build doesn't link.
pub fn dumpArcStats(write_line: *const fn ([]const u8) void) void {
    var line_buf: [256]u8 = undefined;
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] retains_total={d} releases_total={d} consumes_total={d} return_elisions_total={d}\n", .{
        arc_retains_total,
        arc_releases_total,
        arc_consumes_total,
        arc_return_elisions_total,
    })) |line| {
        write_line(line);
    } else |_| {}
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] dense_map_mut_calls_total={d} dense_map_rc1_fast_path_total={d} dense_map_unchecked_total={d}\n", .{
        dense_map_mut_calls_total,
        dense_map_rc1_fast_path_total,
        dense_map_unchecked_total,
    })) |line| {
        write_line(line);
    } else |_| {}
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] dense_map_retaining_clone_total={d} dense_map_retaining_clone_bytes={d}\n", .{
        dense_map_retaining_clone_total,
        dense_map_retaining_clone_bytes,
    })) |line| {
        write_line(line);
    } else |_| {}
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] dense_map_iter_alloc_total={d} dense_map_iter_free_total={d} dense_map_iter_advance_total={d} map_release_iter_dispatch_total={d}\n", .{
        dense_map_iter_alloc_total,
        dense_map_iter_free_total,
        dense_map_iter_advance_total,
        map_release_iter_dispatch_total,
    })) |line| {
        write_line(line);
    } else |_| {}
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] list_mut_calls_total={d} list_rc1_fast_path_total={d} list_unchecked_total={d}\n", .{
        list_mut_calls_total,
        list_rc1_fast_path_total,
        list_unchecked_total,
    })) |line| {
        write_line(line);
    } else |_| {}
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] list_cons_calls_total={d} list_cons_alloc_bytes={d}\n", .{
        list_cons_calls_total,
        list_cons_alloc_bytes,
    })) |line| {
        write_line(line);
    } else |_| {}
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] list_cons_rc1_inplace_total={d} list_cons_rc1_grow_total={d} list_cons_shared_total={d}\n", .{
        list_cons_rc1_inplace_total,
        list_cons_rc1_grow_total,
        list_cons_shared_total,
    })) |line| {
        write_line(line);
    } else |_| {}
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] list_retaining_clone_total={d} list_retaining_clone_bytes={d}\n", .{
        list_retaining_clone_total,
        list_retaining_clone_bytes,
    })) |line| {
        write_line(line);
    } else |_| {}
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] list_release_kept_alive_total={d} list_release_freed_total={d}\n", .{
        list_release_kept_alive_total,
        list_release_freed_total,
    })) |line| {
        write_line(line);
    } else |_| {}
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] bump_calls_total={d} bump_bytes_total={d}\n", .{
        bump_calls_total,
        bump_bytes_total,
    })) |line| {
        write_line(line);
    } else |_| {}
    inline for (@typeInfo(BumpSite).@"enum".fields) |field| {
        const idx: usize = field.value;
        if (bump_site_calls[idx] != 0) {
            if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] bump_site={s} calls={d} bytes={d}\n", .{
                field.name,
                bump_site_calls[idx],
                bump_site_bytes[idx],
            })) |line| {
                write_line(line);
            } else |_| {}
        }
    }
}

fn writeLineToStderr(bytes: []const u8) void {
    posixWrite(STDERR_FD, bytes);
}

/// Convenience wrapper that writes the dump to stderr. Used by the
/// `atexit` hook so stats survive even if stdout was redirected to a
/// pipe that closed early.
pub fn dumpArcStatsToStderr() void {
    flushStdoutBuf();
    dumpArcStats(writeLineToStderr);
}

/// Atexit handler: dumps ARC counter values and per-pool HWM stats to
/// stderr. Reads counters/HWMs directly out of `pub var` globals and
/// renders into a stack buffer; does NOT perform any ARC dispatch
/// (`allocAny` / `freeAny` / `retainAny` / `releaseAny` /
/// `headerRetain` / `headerRelease`), so it is safe to run AFTER
/// `zapMemoryShutdownAtexit`. See the ordering contract on
/// `zapMemoryShutdownAtexit` for details.
fn arcStatsAtexit() callconv(.c) void {
    dumpArcStatsToStderr();
}

var arc_stats_atexit_registered: bool = false;

/// Register the `ZAP_ARC_STATS=1` exit hook on first pool registration.
/// Cheap to call repeatedly — the boolean guard short-circuits after
/// the first invocation. The env-var check is done once and cached
/// implicitly through the registered flag.
fn ensureArcStatsAtexit() void {
    if (arc_stats_atexit_registered) return;
    arc_stats_atexit_registered = true;
    const value = envGetRuntime("ZAP_ARC_STATS") orelse return;
    if (value.len == 0 or value[0] == '0') return;
    _ = atexit(arcStatsAtexit);
}

// ============================================================
// Map workload instrumentation runtime state
//
// The instrumentation state lives in this module rather than inside
// `Map(K, V)` so it is shared across every `(K, V)` instantiation. All
// records are keyed by Map cell pointer (cast to `usize`) and are
// independent of the key/value type — the analyzer only cares about
// allocation lifetimes, refcount transitions, and operation counts.
//
// The state must NOT use `runtime.zig::Map` itself (that would recurse
// infinitely through the very hooks we're emitting). It uses
// `std.AutoHashMap` backed by `std.heap.page_allocator` directly.
//
// All public entry points are no-ops at the call site when
// `instrument_map == false` because the call sites are themselves
// gated by `comptime if (instrument_map)`. The functions still exist
// in both build modes so call sites compile, but the bodies short-
// circuit immediately when the flag is false.
// ============================================================

/// Per-Map-instance lifetime record. Populated incrementally as the
/// cell is allocated, retained, mutated, queried, and finally released.
/// At release time the record is finalised, classified into S/W/V, and
/// either appended to the in-memory finalised list or streamed to the
/// optional JSONL detail file.
pub const MapInstanceRecord = struct {
    instance_id: u64,
    lineage_id: u64,
    parent_instance_id: u64,
    alloc_size: u32,
    creation_callsite: u64,
    puts: u32,
    deletes: u32,
    merges: u32,
    gets: u32,
    peak_strong_count: u32,
    had_share_event: bool,
    had_post_share_mutation: bool,
    alloc_time_ns: u64,
    release_time_ns: u64,
    size_at_release: u32,
    /// Class assigned at release time. 'S' (single — never shared),
    /// 'W' (working-dict — shared at some point but never mutated
    /// post-share), or 'V' (versioned — shared and post-share-mutated).
    class: u8,
};

/// Per-lineage running aggregate. A lineage groups every Map instance
/// that derived from one another via `put`/`delete`/`merge`. The
/// `live_count` rises on alloc within the lineage and falls on
/// release; `peak_concurrent_versions` records the historical maximum
/// of `live_count`.
pub const MapLineageState = struct {
    lineage_id: u64,
    live_count: u32,
    peak_concurrent_versions: u32,
    instance_count: u32,
    total_node_clones: u64,
};

const InstrumentationState = struct {
    initialised: bool = false,
    program_start_ns: u64 = 0,
    next_instance_id: u64 = 1,
    next_lineage_id: u64 = 1,
    /// Active per-instance records — one entry while the cell is alive,
    /// removed at release-zero.
    active: std.AutoHashMap(usize, MapInstanceRecord) = undefined,
    /// Finalised per-instance records (released cells). The summary
    /// emitter walks this list at exit; the optional detail-file
    /// emitter streams each record as it is added.
    finalised: std.ArrayListUnmanaged(MapInstanceRecord) = .empty,
    /// Per-lineage state. Lineages persist for the lifetime of the
    /// process so the lineage_id assigned in `allocMap` remains valid
    /// for every derived instance.
    lineages: std.AutoHashMap(u64, MapLineageState) = undefined,
    /// Thread-local "current parent" used to plumb lineage and parent
    /// instance ids from a mutation entry point (`put`/`delete`/
    /// `merge`) down to the fresh `allocMap` call without threading a
    /// new parameter through every internal helper. The mutation entry
    /// stashes the input map's id pair before invoking allocMap-bound
    /// code paths and clears it on return. Single-threaded today; if
    /// Zap goes multi-threaded the field becomes per-thread.
    parent_lineage_id: u64 = 0,
    parent_instance_id: u64 = 0,
    parent_active: bool = false,
    /// Counts release records where the input had `had_share_event`
    /// AND a post-share mutation was observed. Sum of per-instance
    /// `had_post_share_mutation` flags, materialised eagerly so the
    /// summary emitter does not re-walk every record.
    post_share_mutation_count: u64 = 0,
    /// Aggregate node-clone count across every lineage; mirrors the
    /// per-lineage `total_node_clones` so the summary can report a
    /// single workload-level number.
    total_node_clones: u64 = 0,
    /// Top-N callsite tally. Allocated lazily during the first record
    /// finalisation; key is the return-address fingerprint captured at
    /// `allocMap`, value is the total count of instances created at
    /// that site.
    callsite_counts: std.AutoHashMap(u64, u64) = undefined,
    atexit_registered: bool = false,
    /// Posix file descriptor for the optional `map-instrumentation.jsonl`
    /// detail file, or `-1` when no detail file is open. We use a raw
    /// fd rather than `std.fs.File` because the embedded user-binary
    /// runtime context exposes only a restricted std surface (the rest
    /// of `runtime.zig` follows the same pattern — see `File.write` at
    /// the bottom of this file).
    detail_fd: i32 = -1,
    detail_attempted: bool = false,
};

var instrumentation_state: InstrumentationState = .{};

fn instrumentationAllocator() std.mem.Allocator {
    // Page allocator avoids any chance of recursive instrumentation if
    // a future allocator integration goes through Map(K, V). Maps used
    // here are small (one entry per live cell), so the per-allocation
    // overhead is acceptable for measurement infrastructure.
    return std.heap.page_allocator;
}

fn instrumentationNowNs() u64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const total: i128 = @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    if (total < 0) return 0;
    return @intCast(total);
}

fn ensureInstrumentationInit() void {
    if (!instrument_map) return;
    if (instrumentation_state.initialised) return;
    const alloc = instrumentationAllocator();
    instrumentation_state.active = std.AutoHashMap(usize, MapInstanceRecord).init(alloc);
    instrumentation_state.lineages = std.AutoHashMap(u64, MapLineageState).init(alloc);
    instrumentation_state.callsite_counts = std.AutoHashMap(u64, u64).init(alloc);
    instrumentation_state.program_start_ns = instrumentationNowNs();
    instrumentation_state.initialised = true;
    if (!instrumentation_state.atexit_registered) {
        instrumentation_state.atexit_registered = true;
        _ = atexit(mapInstrumentationAtexit);
    }
    if (!instrumentation_state.detail_attempted) {
        instrumentation_state.detail_attempted = true;
        const detail_var = envGetRuntime("ZAP_INSTRUMENT_DETAIL");
        if (detail_var) |v| {
            if (v.len != 0 and v[0] != '0') {
                const path_z = std.posix.toPosixPath("map-instrumentation.jsonl") catch null;
                if (path_z) |pz| {
                    const fd = std.c.open(&pz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
                    if (fd >= 0) {
                        instrumentation_state.detail_fd = fd;
                    }
                }
            }
        }
    }
}

fn mapInstrumentationStartLineage() u64 {
    const id = instrumentation_state.next_lineage_id;
    instrumentation_state.next_lineage_id += 1;
    const entry = instrumentation_state.lineages.getOrPut(id) catch return id;
    if (!entry.found_existing) {
        entry.value_ptr.* = .{
            .lineage_id = id,
            .live_count = 0,
            .peak_concurrent_versions = 0,
            .instance_count = 0,
            .total_node_clones = 0,
        };
    }
    return id;
}

fn mapInstrumentationLineageBumpLive(lineage_id: u64) void {
    const entry = instrumentation_state.lineages.getOrPut(lineage_id) catch return;
    if (!entry.found_existing) {
        entry.value_ptr.* = .{
            .lineage_id = lineage_id,
            .live_count = 0,
            .peak_concurrent_versions = 0,
            .instance_count = 0,
            .total_node_clones = 0,
        };
    }
    entry.value_ptr.live_count += 1;
    entry.value_ptr.instance_count += 1;
    if (entry.value_ptr.live_count > entry.value_ptr.peak_concurrent_versions) {
        entry.value_ptr.peak_concurrent_versions = entry.value_ptr.live_count;
    }
}

fn mapInstrumentationLineageDropLive(lineage_id: u64) void {
    if (instrumentation_state.lineages.getPtr(lineage_id)) |state| {
        if (state.live_count > 0) state.live_count -= 1;
    }
}

fn mapInstrumentationLineageBumpClones(lineage_id: u64, n: u64) void {
    if (instrumentation_state.lineages.getPtr(lineage_id)) |state| {
        state.total_node_clones += n;
    }
    instrumentation_state.total_node_clones += n;
}

/// Record a fresh Map cell allocation. Returns the new instance_id so
/// the caller (the per-(K,V) `allocMap` wrapper) can stamp it on the
/// cell record, but the record itself is keyed by cell pointer.
pub fn mapInstrumentationOnAlloc(
    cell_ptr: usize,
    alloc_size: u32,
    creation_callsite: u64,
) void {
    if (!instrument_map) return;
    ensureInstrumentationInit();
    const instance_id = instrumentation_state.next_instance_id;
    instrumentation_state.next_instance_id += 1;

    const lineage_id = if (instrumentation_state.parent_active)
        instrumentation_state.parent_lineage_id
    else
        mapInstrumentationStartLineage();
    const parent_instance_id = if (instrumentation_state.parent_active)
        instrumentation_state.parent_instance_id
    else
        0;

    mapInstrumentationLineageBumpLive(lineage_id);

    const record: MapInstanceRecord = .{
        .instance_id = instance_id,
        .lineage_id = lineage_id,
        .parent_instance_id = parent_instance_id,
        .alloc_size = alloc_size,
        .creation_callsite = creation_callsite,
        .puts = 0,
        .deletes = 0,
        .merges = 0,
        .gets = 0,
        .peak_strong_count = 1,
        .had_share_event = false,
        .had_post_share_mutation = false,
        .alloc_time_ns = instrumentationNowNs(),
        .release_time_ns = 0,
        .size_at_release = 0,
        .class = 'S',
    };
    instrumentation_state.active.put(cell_ptr, record) catch {};
}

/// Hook invoked from `Map(K, V).retain` after the refcount bump. The
/// caller passes the post-bump strong count so the hook does not have
/// to re-read the atomic.
///
/// `Map.retain` is reached through two paths. Container-style
/// retains (List cons head retain, Map entry storage, struct field
/// assignment) route through `ArcRuntime.retainAnyPersistent`, which
/// dispatches to the type's `retain` method and therefore reaches
/// this hook. Transient borrow-pass retains emitted by the IR
/// verifier (the `share_value mode=retain` lowering paired with a
/// matching post-call release) route through `ArcRuntime.retainAny`,
/// which performs a direct header bump and never reaches this hook.
/// That split is what lets the Map workload classifier distinguish a
/// genuine concurrent owner (true sharing event) from temporary
/// borrow plumbing that resolves before the next mutation.
pub fn mapInstrumentationOnRetain(cell_ptr: usize, new_strong_count: u32) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    if (instrumentation_state.active.getPtr(cell_ptr)) |record| {
        if (new_strong_count > record.peak_strong_count) {
            record.peak_strong_count = new_strong_count;
        }
        if (new_strong_count >= 2 and !record.had_share_event) {
            record.had_share_event = true;
        }
    }
}

/// Hook invoked from `Map(K, V).release` immediately before the cell
/// is destroyed (after the zero-transition has been confirmed). The
/// caller passes the final size so the hook does not re-walk the
/// trie. Classifies the record into S/W/V and moves it to the
/// finalised list (and the optional detail file).
pub fn mapInstrumentationOnRelease(cell_ptr: usize, size_at_release: u32) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    const removed = instrumentation_state.active.fetchRemove(cell_ptr) orelse return;
    var record = removed.value;
    record.size_at_release = size_at_release;
    record.release_time_ns = instrumentationNowNs();
    record.class = if (!record.had_share_event)
        @as(u8, 'S')
    else if (record.had_post_share_mutation)
        @as(u8, 'V')
    else
        @as(u8, 'W');
    if (record.had_post_share_mutation) {
        instrumentation_state.post_share_mutation_count += 1;
    }
    mapInstrumentationLineageDropLive(record.lineage_id);

    // Tally callsite count.
    const callsite_entry = instrumentation_state.callsite_counts.getOrPut(record.creation_callsite) catch null;
    if (callsite_entry) |entry| {
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    instrumentation_state.finalised.append(instrumentationAllocator(), record) catch {};
    if (instrumentation_state.detail_fd >= 0) {
        writeRecordJsonLine(instrumentation_state.detail_fd, record) catch {};
    }
}

/// Hook invoked from `put`/`delete`/`merge`. Bumps the appropriate
/// per-instance counter on the *input* map. Returns the input
/// instance_id so the caller can plumb it as `parent_instance_id`
/// into the impending allocMap call via the thread-local context.
pub fn mapInstrumentationBumpMutation(
    cell_ptr: usize,
    op: enum { put, delete, merge },
) struct { instance_id: u64, lineage_id: u64, had_share_event: bool } {
    if (!instrument_map) return .{ .instance_id = 0, .lineage_id = 0, .had_share_event = false };
    if (!instrumentation_state.initialised) return .{ .instance_id = 0, .lineage_id = 0, .had_share_event = false };
    if (instrumentation_state.active.getPtr(cell_ptr)) |record| {
        switch (op) {
            .put => record.puts += 1,
            .delete => record.deletes += 1,
            .merge => record.merges += 1,
        }
        return .{
            .instance_id = record.instance_id,
            .lineage_id = record.lineage_id,
            .had_share_event = record.had_share_event,
        };
    }
    return .{ .instance_id = 0, .lineage_id = 0, .had_share_event = false };
}

/// After a mutation produces a fresh derived map at `result_ptr`,
/// mark the *input* map as having had a post-share mutation iff the
/// input was already classified as having had a share event and the
/// result is a distinct cell. Called from `put`/`delete`/`merge`
/// after the new cell pointer is known. The share-event flag is set
/// only by `mapInstrumentationOnRetain` for retains that route
/// through `retainAnyPersistent` — transient borrow-pass retains
/// (`retainAny`) never flip the flag, so a "post-share mutation"
/// here means a genuine concurrent owner observed the older
/// version.
pub fn mapInstrumentationNotePostShareMutation(input_cell_ptr: usize) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    if (instrumentation_state.active.getPtr(input_cell_ptr)) |record| {
        if (record.had_share_event and !record.had_post_share_mutation) {
            record.had_post_share_mutation = true;
        }
    }
}

/// Bump the `gets` counter on the receiver map. Called from `get`,
/// `getStr`, `hasKey`, and `size`.
pub fn mapInstrumentationOnGet(cell_ptr: usize) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    if (instrumentation_state.active.getPtr(cell_ptr)) |record| {
        record.gets += 1;
    }
}

/// Set the thread-local parent context before invoking allocMap from
/// inside a `put`/`delete`/`merge`. Pair with
/// `mapInstrumentationClearParent` after allocMap returns. The pair is
/// not nested — the outer mutation is the only owner of the slot.
pub fn mapInstrumentationSetParent(lineage_id: u64, instance_id: u64) void {
    if (!instrument_map) return;
    instrumentation_state.parent_lineage_id = lineage_id;
    instrumentation_state.parent_instance_id = instance_id;
    instrumentation_state.parent_active = true;
}

pub fn mapInstrumentationClearParent() void {
    if (!instrument_map) return;
    instrumentation_state.parent_active = false;
    instrumentation_state.parent_lineage_id = 0;
    instrumentation_state.parent_instance_id = 0;
}

/// Bump the per-lineage clone count. Historical name — invoked by the
/// HAMT path-copy code; kept as a stable instrumentation surface for
/// future allocators that want to flag every internal clone. The dense
/// Map does not call this hook in its current form (cloning is whole-
/// buffer, already counted via `mapInstrumentationOnAlloc`'s lineage
/// `instance_count`); the function stays a no-op-friendly surface for
/// callers that detect a buffer clone.
pub fn mapInstrumentationNoteNodeClone(input_cell_ptr: usize) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    if (instrumentation_state.active.getPtr(input_cell_ptr)) |record| {
        mapInstrumentationLineageBumpClones(record.lineage_id, 1);
    }
}

fn writeRecordJsonLine(fd: i32, record: MapInstanceRecord) !void {
    var buf: [768]u8 = undefined;
    const class_str: []const u8 = switch (record.class) {
        'S' => "S",
        'W' => "W",
        'V' => "V",
        else => "?",
    };
    const formatted = try std.fmt.bufPrint(&buf, "{{\"instance_id\":{d},\"lineage_id\":{d},\"parent_instance_id\":{d}," ++
        "\"alloc_size\":{d},\"creation_callsite\":{d},\"puts\":{d},\"deletes\":{d}," ++
        "\"merges\":{d},\"gets\":{d},\"peak_strong_count\":{d},\"had_share_event\":{},\"had_post_share_mutation\":{}," ++
        "\"alloc_time_ns\":{d},\"release_time_ns\":{d},\"size_at_release\":{d},\"class\":\"{s}\"}}\n", .{
        record.instance_id,        record.lineage_id,
        record.parent_instance_id, record.alloc_size,
        record.creation_callsite,  record.puts,
        record.deletes,            record.merges,
        record.gets,               record.peak_strong_count,
        record.had_share_event,    record.had_post_share_mutation,
        record.alloc_time_ns,      record.release_time_ns,
        record.size_at_release,    class_str,
    });
    _ = std.c.write(fd, formatted.ptr, formatted.len);
}

fn classifyHistogramSize(s: u32) usize {
    if (s == 0) return 0;
    if (s <= 7) return 1;
    if (s <= 31) return 2;
    if (s <= 127) return 3;
    if (s <= 1023) return 4;
    return 5;
}

fn classifyConcurrentVersions(p: u32) usize {
    if (p <= 1) return 0;
    if (p == 2) return 1;
    if (p <= 5) return 2;
    if (p <= 20) return 3;
    return 4;
}

fn workloadNameFromArgv0() []const u8 {
    const argv = getArgv();
    if (argv.len == 0) return "unknown";
    const path = std.mem.span(argv[0]);
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

fn writeJsonString(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    var hex_buf: [8]u8 = undefined;
                    const slc = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{@as(u16, c)}) catch continue;
                    try buf.appendSlice(alloc, slc);
                } else {
                    try buf.append(alloc, c);
                }
            },
        }
    }
    try buf.append(alloc, '"');
}

fn renderInstrumentationSummaryJson(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !void {
    const state = &instrumentation_state;
    const records = state.finalised.items;

    var class_counts: [3]u64 = .{ 0, 0, 0 }; // S, W, V
    var size_hist: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };
    var versions_hist: [5]u64 = .{ 0, 0, 0, 0, 0 };

    for (records) |rec| {
        const idx: usize = switch (rec.class) {
            'S' => 0,
            'W' => 1,
            'V' => 2,
            else => continue,
        };
        class_counts[idx] += 1;
        size_hist[classifyHistogramSize(rec.size_at_release)] += 1;
    }

    var lineage_class_S: u64 = 0;
    var lineage_class_W: u64 = 0;
    var lineage_class_V: u64 = 0;
    var lin_it = state.lineages.iterator();
    while (lin_it.next()) |entry| {
        versions_hist[classifyConcurrentVersions(entry.value_ptr.peak_concurrent_versions)] += 1;
        // Lineage class — derived from member-instance distribution.
        // S iff exactly one instance and it was class S.
        // V iff any instance class is V.
        // Otherwise W.
        var has_v = false;
        var has_w = false;
        var instance_total: u64 = 0;
        for (records) |rec| {
            if (rec.lineage_id != entry.value_ptr.lineage_id) continue;
            instance_total += 1;
            if (rec.class == 'V') has_v = true;
            if (rec.class == 'W') has_w = true;
        }
        if (instance_total == 0) continue;
        if (has_v) {
            lineage_class_V += 1;
        } else if (has_w or entry.value_ptr.peak_concurrent_versions >= 2) {
            lineage_class_W += 1;
        } else {
            lineage_class_S += 1;
        }
    }

    const total_records: u64 = @intCast(records.len);
    const total_lineages: u64 = state.lineages.count();

    // Sort callsites by count descending.
    const CallsiteEntry = struct { site: u64, count: u64 };
    var callsites: std.ArrayListUnmanaged(CallsiteEntry) = .empty;
    defer callsites.deinit(alloc);
    var cs_it = state.callsite_counts.iterator();
    while (cs_it.next()) |entry| {
        try callsites.append(alloc, .{ .site = entry.key_ptr.*, .count = entry.value_ptr.* });
    }
    std.mem.sort(CallsiteEntry, callsites.items, {}, struct {
        fn lessThan(_: void, a: CallsiteEntry, b: CallsiteEntry) bool {
            return a.count > b.count;
        }
    }.lessThan);

    const duration_ns = instrumentationNowNs() - state.program_start_ns;
    const workload = workloadNameFromArgv0();

    try buf.appendSlice(alloc, "{\n  \"workload\": ");
    try writeJsonString(buf, alloc, workload);
    try buf.appendSlice(alloc, ",\n  \"binary\": ");
    {
        const argv = getArgv();
        if (argv.len > 0) {
            try writeJsonString(buf, alloc, std.mem.span(argv[0]));
        } else {
            try buf.appendSlice(alloc, "\"\"");
        }
    }
    var line_buf: [256]u8 = undefined;
    {
        const slc = try std.fmt.bufPrint(&line_buf, ",\n  \"duration_ns\": {d},\n", .{duration_ns});
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "  \"summary\": {\n");
    {
        const slc = try std.fmt.bufPrint(&line_buf, "    \"total_instances\": {d},\n", .{total_records});
        try buf.appendSlice(alloc, slc);
    }
    {
        const slc = try std.fmt.bufPrint(&line_buf, "    \"total_lineages\": {d},\n", .{total_lineages});
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    \"by_class\": {\n");
    const denom: f64 = if (total_records == 0) 1.0 else @floatFromInt(total_records);
    {
        const slc = try std.fmt.bufPrint(&line_buf, "      \"S\": {{\"count\": {d}, \"frac\": {d:.4}}},\n", .{ class_counts[0], @as(f64, @floatFromInt(class_counts[0])) / denom });
        try buf.appendSlice(alloc, slc);
    }
    {
        const slc = try std.fmt.bufPrint(&line_buf, "      \"W\": {{\"count\": {d}, \"frac\": {d:.4}}},\n", .{ class_counts[1], @as(f64, @floatFromInt(class_counts[1])) / denom });
        try buf.appendSlice(alloc, slc);
    }
    {
        const slc = try std.fmt.bufPrint(&line_buf, "      \"V\": {{\"count\": {d}, \"frac\": {d:.4}}}\n", .{ class_counts[2], @as(f64, @floatFromInt(class_counts[2])) / denom });
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    },\n");
    try buf.appendSlice(alloc, "    \"by_lineage_class\": {\n");
    {
        const slc = try std.fmt.bufPrint(&line_buf, "      \"S\": {d},\n      \"W\": {d},\n      \"V\": {d}\n", .{ lineage_class_S, lineage_class_W, lineage_class_V });
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    },\n");

    const size_labels = [_][]const u8{ "0", "1-7", "8-31", "32-127", "128-1023", "1024+" };
    try buf.appendSlice(alloc, "    \"size_histogram\": {\n");
    inline for (size_labels, 0..) |label, i| {
        const sep: []const u8 = if (i + 1 < size_labels.len) "," else "";
        const slc = try std.fmt.bufPrint(&line_buf, "      \"{s}\": {d}{s}\n", .{ label, size_hist[i], sep });
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    },\n");

    const ver_labels = [_][]const u8{ "1", "2", "3-5", "6-20", "21+" };
    try buf.appendSlice(alloc, "    \"peak_concurrent_versions_histogram\": {\n");
    inline for (ver_labels, 0..) |label, i| {
        const sep: []const u8 = if (i + 1 < ver_labels.len) "," else "";
        const slc = try std.fmt.bufPrint(&line_buf, "      \"{s}\": {d}{s}\n", .{ label, versions_hist[i], sep });
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    },\n");

    {
        const slc = try std.fmt.bufPrint(&line_buf, "    \"post_share_mutation_count\": {d},\n", .{state.post_share_mutation_count});
        try buf.appendSlice(alloc, slc);
    }
    {
        const slc = try std.fmt.bufPrint(&line_buf, "    \"total_node_clones\": {d},\n", .{state.total_node_clones});
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    \"top_callsites_by_instance_count\": [\n");
    const top_n = @min(@as(usize, 20), callsites.items.len);
    for (callsites.items[0..top_n], 0..) |entry, idx| {
        const sep: []const u8 = if (idx + 1 < top_n) "," else "";
        const slc = try std.fmt.bufPrint(&line_buf, "      {{\"site\": \"0x{x}\", \"count\": {d}}}{s}\n", .{ entry.site, entry.count, sep });
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    ]\n");
    try buf.appendSlice(alloc, "  }\n}\n");
}

fn flushPendingActiveRecords() void {
    // Records still in `active` represent maps whose owners didn't run
    // a release before the program exited (e.g. globals, leaked refs).
    // Finalise them as-is so the summary reflects every observed
    // allocation. Class is computed from the bools as if release just
    // ran, with size_at_release left at 0 (we don't have a Self typed
    // pointer to read total_count from at this layer).
    var it = instrumentation_state.active.iterator();
    while (it.next()) |entry| {
        var record = entry.value_ptr.*;
        record.release_time_ns = instrumentationNowNs();
        record.class = if (!record.had_share_event)
            @as(u8, 'S')
        else if (record.had_post_share_mutation)
            @as(u8, 'V')
        else
            @as(u8, 'W');
        if (record.had_post_share_mutation) {
            instrumentation_state.post_share_mutation_count += 1;
        }
        instrumentation_state.finalised.append(instrumentationAllocator(), record) catch {};
        if (instrumentation_state.detail_fd >= 0) {
            writeRecordJsonLine(instrumentation_state.detail_fd, record) catch {};
        }
    }
    instrumentation_state.active.clearRetainingCapacity();
}

/// Atexit handler: finalises map instrumentation records and writes
/// a JSON summary via `write(2)`. The in-memory records live in a
/// `std.AutoHashMap` backed by `std.heap.page_allocator` (NOT the
/// ARC pool), and JSON rendering uses a `std.ArrayListUnmanaged`
/// also backed by `page_allocator`. Does NOT perform any ARC
/// dispatch (`allocAny` / `freeAny` / `retainAny` / `releaseAny` /
/// `headerRetain` / `headerRelease`), so it is safe to run AFTER
/// `zapMemoryShutdownAtexit`. See the ordering contract on
/// `zapMemoryShutdownAtexit` for details.
fn mapInstrumentationAtexit() callconv(.c) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    flushStdoutBuf();
    flushPendingActiveRecords();
    if (instrumentation_state.detail_fd >= 0) {
        _ = std.c.close(instrumentation_state.detail_fd);
        instrumentation_state.detail_fd = -1;
    }
    const out_path = envGetRuntime("ZAP_INSTRUMENT_OUT") orelse "map-instrumentation.json";
    const out_path_z = std.posix.toPosixPath(out_path) catch return;

    const alloc = instrumentationAllocator();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    renderInstrumentationSummaryJson(&buf, alloc) catch return;

    const fd = std.c.open(&out_path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var written: usize = 0;
    while (written < buf.items.len) {
        const n = std.c.write(fd, buf.items[written..].ptr, buf.items[written..].len);
        if (n <= 0) break;
        written += @intCast(n);
    }
}

/// Test-only helper: returns a copy of the finalised record matching
/// `cell_ptr`, or null. Walks the finalised list linearly (O(n)) — only
/// the unit tests use this, and they exit immediately after asserting.
pub fn mapInstrumentationFindFinalised(cell_ptr_used_at_alloc: usize, instance_id: u64) ?MapInstanceRecord {
    _ = cell_ptr_used_at_alloc;
    if (!instrument_map) return null;
    if (!instrumentation_state.initialised) return null;
    for (instrumentation_state.finalised.items) |rec| {
        if (rec.instance_id == instance_id) return rec;
    }
    return null;
}

/// Test-only helper: returns the active record's instance_id for the
/// most recently allocated cell.
pub fn mapInstrumentationLastInstanceId() u64 {
    if (!instrument_map) return 0;
    if (!instrumentation_state.initialised) return 0;
    return instrumentation_state.next_instance_id - 1;
}

// ============================================================
// ArcRuntime — Non-generic ARC helpers for ZIR (spec §31.4)
//
// ZIR cannot express generic instantiation, so ArcRuntime
// provides concrete helper functions that take comptime T via
// @TypeOf, making them callable from generated ZIR code.
// ============================================================

pub const ArcRuntime = struct {
    /// Increment the runtime `arc_consumes_total` counter. Emitted as a
    /// ZIR call from each `share_value(.consume)` lowering so the
    /// observable counter reflects every consume site that fired during
    /// program execution, mirroring how `retainAny` / `releaseAny` bump
    /// their respective counters from the hot path. The cost is one
    /// extern function call per consume; consume mode still saves the
    /// far more expensive retain/release pair, so net effect is a
    /// reduction in ARC traffic.
    ///
    /// Also ensures the `ZAP_ARC_STATS=1` atexit hook is registered so
    /// programs whose ARC-managed types use bump allocation (e.g.
    /// `List`) — and therefore never run the per-pool atexit-registration
    /// path — still emit the counter dump on exit when the env var is
    /// set. The `ensureArcStatsAtexit` guard is idempotent so the cost
    /// is one boolean compare-branch on every consume after the first.
    pub fn noteConsume() void {
        ensureArcStatsAtexit();
        if (comptime collect_arc_stats) {
            arc_consumes_total += 1;
        }
    }

    /// Increment the runtime `arc_return_elisions_total` counter.
    /// Emitted from the function-epilogue drop emission when a local's
    /// release is suppressed because it is the source of the function's
    /// `ret` instruction (Phase 5 wires the emission). Defined here in
    /// Phase 3 alongside `noteConsume` so phase 5 only has to emit the
    /// call site, not introduce the runtime symbol.
    ///
    /// Also ensures the `ZAP_ARC_STATS=1` atexit hook is registered so
    /// programs whose ARC-managed types use bump allocation — and
    /// therefore never run the per-pool atexit-registration path — still
    /// emit the counter dump on exit when the env var is set. The
    /// `ensureArcStatsAtexit` guard is idempotent so the cost is one
    /// boolean compare-branch on every elision after the first; mirrors
    /// the `noteConsume` symmetry so a return-elision-only workload
    /// (one that never fires a consume site) still dumps stats.
    pub fn noteReturnElision() void {
        ensureArcStatsAtexit();
        if (comptime collect_arc_stats) {
            arc_return_elisions_total += 1;
        }
    }


    /// Allocate and wrap a value in an Arc. Returns a pointer directly
    /// to the slab slot holding `value`; the slot's side-table refcount
    /// is initialised to 1 by the pool's `create`.
    ///
    /// The `allocator` parameter is preserved for ABI stability with
    /// existing ZIR call sites (`allocAny(@TypeOf(value), allocator,
    /// value)`) but is no longer the source of storage — `Arc(T)`
    /// allocations come from a per-type slab pool. Routing through the
    /// pool removes one libc-allocator round-trip per Arc node, which
    /// dominates Arc-heavy workloads (e.g., binarytrees `make`/`check`
    /// at ~600 M nodes per N=21 run).
    ///
    /// Dispatch validates that the active manager is bound and its
    /// core vtable is healthy before invoking the manager's
    /// `allocate_refcounted` slot. The slot returns a side-table-
    /// backed cell whose refcount has already been initialised to 1;
    /// the runtime writes `value` into the slot and returns its
    /// pointer (the slot's first byte — there is no per-cell ArcHeader
    /// under the side-table layout, so the slot is 100% user payload).
    /// Phase 4.x closed the previous typed-slab-pool bypass: every
    /// `Arc(T)` allocation now flows through the manager's vtable so
    /// tracking managers can observe the cell's lifecycle end-to-end.
    pub inline fn allocAny(comptime T: type, allocator: std.mem.Allocator, value: T) *T {
        // Phase 6: under no-REFCOUNT_V1 the slab pool's side-table
        // refcount layout has no semantic meaning, but the value
        // ITSELF still needs heap-backed storage so the indirect-
        // storage / boxed-recursive pointer remains live across
        // frames. Route through the active manager's `core.allocate`
        // — the manager's `core.deallocate` is the matching free
        // path (or, for an Arena manager, a no-op until program
        // exit). Phase 6 step 5 plan (b).
        if (comptime !refcount_v1_active) {
            // The `allocator` parameter is vestigial in the manager-
            // routed path. We don't `_ = allocator;` because the
            // REFCOUNT_V1 branch below uses it, and Zig errors on a
            // discard-of-used-param. Leave it untouched.
            //
            // Symmetric guards with the REFCOUNT_V1 branch: the
            // shutdown-complete check refuses any dispatch after
            // `core.deinit` has run (spec section 4.4 / 4.6); the
            // `ensureMemoryStartup` call binds the active manager
            // lazily on first dispatch. Without these guards, the
            // first `allocAny` call in an Arena/NoOp build would
            // observe `active_manager_state.core == null` (because
            // startup binding only happens inside `ensureMemoryStartup`)
            // and crash before the null-check below could produce a
            // useful panic message.
            if (active_manager_state.shutdown_complete) {
                @panic("zap runtime: memory dispatch after shutdown");
            }
            ensureMemoryStartup();
            if (active_manager_state.core == null) {
                @panic("zap runtime: allocAny dispatched with no active memory manager");
            }
            const ctx = active_manager_state.context orelse
                @panic("zap runtime: allocAny dispatched with null manager context");
            const size = @sizeOf(T);
            const alignment_bytes = @alignOf(T);
            const raw = blk: {
                if (comptime ACTIVE_MANAGER_TAG == .third_party) {
                    const core = active_manager_state.core orelse
                        @panic("zap runtime: allocAny dispatched with no active memory manager");
                    break :blk core.allocate(ctx, size, @intCast(alignment_bytes)) orelse
                        @panic("zap runtime: out of memory: manager.allocate returned null");
                } else {
                    break :blk active_manager.allocate(ctx, size, @intCast(alignment_bytes)) orelse
                        @panic("zap runtime: out of memory: manager.allocate returned null");
                }
            };
            const slot: *T = @ptrCast(@alignCast(raw));
            slot.* = value;
            return slot;
        }
        if (active_manager_state.shutdown_complete) {
            @panic("zap runtime: memory dispatch after shutdown");
        }
        ensureMemoryStartup();
        if (active_manager_state.core == null) {
            @panic("zap runtime: allocAny dispatched with no active memory manager");
        }
        if (active_manager_state.refcount_capability == null) {
            // `Arc(T)` cells are inherently refcounted; allocating one under a
            // manager that does not declare REFCOUNT_V1 would silently succeed
            // here and only blow up on the eventual `release` path, leaving a
            // misleading stack trace far from the original allocation site.
            // Panic loudly at the alloc-time call site instead — the same
            // soundness argument as `releaseAny` / `retainAny`.
            @panic("zap runtime: allocAny dispatched but active manager does not declare REFCOUNT_V1");
        }
        return dispatcherAllocImpl(T, allocator, value);
    }

    /// Runtime-side dispatcher implementation of `allocAny`. Phase 4.x:
    /// when the active manager exposes the v1.1 side-table extension
    /// (`active_manager_state.refcount_has_sized_extension`), routes through
    /// `allocate_refcounted` — the manager initialises the side-table
    /// refcount to 1 and returns a slot whose bytes are 100% user
    /// payload. Under a v1.0 manager (no extension) routes through
    /// `core.allocate` and embeds an inline `ArcHeader` so the
    /// per-cell refcount has somewhere to live.
    fn dispatcherAllocImpl(comptime T: type, allocator: std.mem.Allocator, value: T) *T {
        _ = allocator;
        if (active_manager_state.refcount_has_sized_extension) {
            const ctx = active_manager_state.context orelse
                @panic("zap runtime: allocAny dispatched with null manager context");
            const size = @sizeOf(T);
            const alignment_bytes = @alignOf(T);
            const raw = blk: {
                if (comptime ACTIVE_MANAGER_TAG == .third_party) {
                    const cap = active_manager_state.refcount_capability orelse
                        @panic("zap runtime: allocAny dispatched but active manager does not declare REFCOUNT_V1");
                    break :blk cap.allocate_refcounted(ctx, size, @intCast(alignment_bytes));
                } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
                    break :blk active_manager.allocateRefcounted(ctx, size, @intCast(alignment_bytes));
                } else {
                    @panic("zap runtime: allocAny dispatched but active manager does not declare REFCOUNT_V1");
                }
            } orelse @panic("zap runtime: out of memory: manager.allocate_refcounted returned null");
            const slot: *T = @ptrCast(@alignCast(raw));
            slot.* = value;
            return slot;
        }
        return dispatcherAllocLegacyV1_0(T, value);
    }

    /// Legacy v1.0 fallback for generic `Arc(T)` allocation: when the
    /// active manager advertises only the v1.0 vtable (no side-table
    /// extension), the runtime allocates an inline-header layout via
    /// `core.allocate` and writes `(rc=1, value)` into the slot. The
    /// matching `release` path is `releaseAnyLegacyV1_0`. Slow path —
    /// every byte of the side-table optimisation is forfeit — but
    /// keeps generic `Arc(T)` working under third-party v1.0 managers.
    fn dispatcherAllocLegacyV1_0(comptime T: type, value: T) *T {
        if (active_manager_state.core == null) {
            @panic("zap runtime: allocAny dispatched with no active memory manager");
        }
        const ctx = active_manager_state.context orelse
            @panic("zap runtime: allocAny dispatched with null manager context");
        const layout = LegacyArcInnerLayout(T);
        const raw = blk: {
            if (comptime ACTIVE_MANAGER_TAG == .third_party) {
                const core = active_manager_state.core orelse
                    @panic("zap runtime: allocAny dispatched with no active memory manager");
                break :blk core.allocate(ctx, layout.size, @intCast(layout.alignment));
            } else {
                break :blk active_manager.allocate(ctx, layout.size, @intCast(layout.alignment));
            }
        } orelse @panic("zap runtime: out of memory: manager.allocate returned null");
        // Header at offset 0, value at `value_offset`. Write each
        // field through its own typed pointer so the user payload's
        // alignment / layout requirements are honoured without
        // round-tripping through an `extern struct` (which would
        // refuse to compile when `T` has automatic layout — every
        // user-defined Zap struct).
        const header_ptr: *ArcHeader = @ptrCast(@alignCast(raw));
        header_ptr.* = ArcHeader.init();
        const value_ptr: *T = @ptrCast(@alignCast(raw + layout.value_offset));
        value_ptr.* = value;
        return value_ptr;
    }

    /// Byte-level layout description of the v1.0 fallback's inline-
    /// header cell. Stored as a value (not a type) so the runtime can
    /// host arbitrary `T` — including user-defined Zap structs whose
    /// automatic-layout shape forbids `extern struct` containment.
    ///
    /// Fields:
    ///   * `size` — total cell size in bytes
    ///                 (`value_offset + @sizeOf(T)`)
    ///   * `alignment` — cell alignment, the max of `@alignOf(ArcHeader)`
    ///                   (4 in REFCOUNT_V1 mode) and `@alignOf(T)`
    ///   * `value_offset` — byte offset of the user payload after the
    ///                      inline header (header lives at offset 0)
    ///
    /// The header sits at offset 0 so the v1.0 manager's `retain` /
    /// `release` slots — which operate on a 4-byte refcount at offset
    /// 0 of the supplied object pointer — can address it without any
    /// per-T fixup. The user-visible pointer points at the value;
    /// `legacyArcInnerHeaderFromValuePtr` walks back to the header
    /// via the same offset math.
    const LegacyArcInnerLayout_Info = struct {
        size: usize,
        alignment: u32,
        value_offset: usize,
    };

    fn LegacyArcInnerLayout(comptime T: type) LegacyArcInnerLayout_Info {
        const header_align: usize = @alignOf(ArcHeader);
        const value_align: usize = @alignOf(T);
        const cell_align: usize = if (value_align > header_align) value_align else header_align;
        const header_size: usize = @sizeOf(ArcHeader);
        const value_offset: usize = std.mem.alignForward(usize, header_size, value_align);
        const total: usize = value_offset + @sizeOf(T);
        return .{
            .size = total,
            .alignment = @intCast(cell_align),
            .value_offset = value_offset,
        };
    }

    /// Recover the inline `ArcHeader` from a user-visible `*T` under
    /// the v1.0 fallback. Mirrors the old `legacyArcInnerFromValuePtr`
    /// but returns the header directly instead of an `extern struct *`
    /// (which can't host non-extern `T`). The full cell base is
    /// `value_ptr - LegacyArcInnerLayout(T).value_offset` — that
    /// address is what `core.deallocate` receives in the deep-walk
    /// and shallow-free closures below.
    fn legacyArcInnerHeaderFromValuePtr(comptime T: type, value_ptr: *T) *ArcHeader {
        const layout = LegacyArcInnerLayout(T);
        const value_addr = @intFromPtr(value_ptr);
        const inner_base = value_addr - layout.value_offset;
        return @ptrFromInt(inner_base);
    }

    /// Recover the base address of the v1.0 fallback cell from a
    /// user-visible `*T`. Used by the deep-walk / shallow-free
    /// closures when they need to call `core.deallocate(base, size,
    /// alignment)` on the whole allocation.
    fn legacyArcInnerBaseFromValuePtr(comptime T: type, value_ptr: *T) [*]u8 {
        const layout = LegacyArcInnerLayout(T);
        const value_addr = @intFromPtr(value_ptr);
        return @ptrFromInt(value_addr - layout.value_offset);
    }

    /// Allocate a fixed-size inline-header cell `T` through the active
    /// manager's `core.allocate` slot. The cell's `T.header` field is
    /// **not** initialised here — the caller writes the full `T` value
    /// into the returned slot (including the `header` field). Pairs
    /// with `freeInlineHeaderCell` for the matching free.
    ///
    /// Distinct from `allocAny`: that path is for generic `Arc(T)`
    /// cells that the runtime owns end-to-end. `allocInlineHeaderCell`
    /// is for self-managed types (`MapIter`, future inline-header cell
    /// shapes) that carry their own `ArcHeader` and route retain/
    /// release through `headerRetain` / `headerRelease`. The manager's
    /// side-table refcount (when present) is irrelevant for these
    /// cells; the slab slot is freed back via `core.deallocate` once
    /// the inline header transitions to rc=0.
    ///
    /// Routing through `core.allocate` instead of a per-T slab pool
    /// closes the Phase 4 typed-slab-pool bypass: Tracking managers
    /// observe every inline-header cell allocation through their
    /// `core.allocate` interception hook.
    pub fn allocInlineHeaderCell(comptime T: type) *T {
        if (active_manager_state.shutdown_complete) {
            @panic("zap runtime: allocInlineHeaderCell dispatched after shutdown");
        }
        ensureMemoryStartup();
        if (active_manager_state.core == null) {
            @panic("zap runtime: allocInlineHeaderCell dispatched with no active memory manager");
        }
        const ctx = active_manager_state.context orelse
            @panic("zap runtime: allocInlineHeaderCell dispatched with null manager context");
        const size = @sizeOf(T);
        const alignment_bytes = @alignOf(T);
        const raw = blk: {
            if (comptime ACTIVE_MANAGER_TAG == .third_party) {
                const core = active_manager_state.core orelse
                    @panic("zap runtime: allocInlineHeaderCell dispatched with no active memory manager");
                break :blk core.allocate(ctx, size, @intCast(alignment_bytes));
            } else {
                break :blk active_manager.allocate(ctx, size, @intCast(alignment_bytes));
            }
        } orelse @panic("zap runtime: out of memory: manager.allocate returned null");
        return @ptrCast(@alignCast(raw));
    }

    /// Free a fixed-size inline-header cell `T` through the active
    /// manager's `core.deallocate` slot. Mirror of
    /// `allocInlineHeaderCell` — the caller has already deep-released
    /// the cell's children (if any) before invoking this entry.
    ///
    /// `ensureMemoryStartup()` is called for symmetry with
    /// `allocInlineHeaderCell`. In practice a free always follows an
    /// alloc that already armed startup, but a future code path that
    /// reaches this entry without a prior alloc (e.g., a tracking
    /// manager that buffers cell handles across atexit boundaries)
    /// still needs the active vtable bound before dispatch. Cheap —
    /// after the first invocation it is a single boolean compare.
    pub fn freeInlineHeaderCell(comptime T: type, ptr: *T) void {
        if (active_manager_state.shutdown_complete) {
            @panic("zap runtime: freeInlineHeaderCell dispatched after shutdown");
        }
        ensureMemoryStartup();
        if (active_manager_state.core == null) {
            @panic("zap runtime: freeInlineHeaderCell dispatched with no active memory manager");
        }
        const ctx = active_manager_state.context orelse
            @panic("zap runtime: freeInlineHeaderCell dispatched with null manager context");
        const size = @sizeOf(T);
        const alignment_bytes = @alignOf(T);
        const raw: [*]u8 = @ptrCast(@alignCast(ptr));
        if (comptime ACTIVE_MANAGER_TAG == .third_party) {
            const core = active_manager_state.core orelse
                @panic("zap runtime: freeInlineHeaderCell dispatched with no active memory manager");
            core.deallocate(ctx, raw, size, @intCast(alignment_bytes));
        } else {
            active_manager.deallocate(ctx, raw, size, @intCast(alignment_bytes));
        }
    }

    /// Generate a per-type deep-walk callback that the active manager's
    /// `release_sized` slot invokes on the zero-transition. The
    /// callback recursively releases every indirect-storage Arc'd
    /// child encountered by walking `T`'s fields at comptime. For
    /// types with no refcounted children the callback compiles to a
    /// no-op; the dispatcher passes `null` in that case to skip the
    /// indirect call entirely.
    fn DeepWalkFnFor(comptime T: type) AbiV1.ZapDeepWalkFn {
        const DeepWalkClosure = struct {
            fn walk(object: *anyopaque) callconv(.c) void {
                const typed: *T = @ptrCast(@alignCast(object));
                releaseChildrenAny(T, std.heap.page_allocator, typed.*);
            }
        };
        return DeepWalkClosure.walk;
    }

    /// Comptime predicate: does the type carry any indirect-storage
    /// Arc'd children whose release walker would do non-trivial work?
    /// Used to elide the `deep_walk` callback for flat types (no
    /// recursive pointer fields) — the dispatcher passes `null` and
    /// the manager skips the indirect call.
    fn typeHasArcChildren(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .@"struct" => |s| blk: {
                inline for (s.fields) |field| {
                    if (fieldTypeHasArcChild(field.type)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn fieldTypeHasArcChild(comptime FieldType: type) bool {
        return switch (@typeInfo(FieldType)) {
            .optional => |opt| fieldTypeHasArcChild(opt.child),
            .pointer => |p| p.size == .one,
            else => false,
        };
    }

    /// Element type of an Arc value pointer. The ZIR backend calls every
    /// public release helper with `(allocator, ptr)` — Zig's call-site
    /// inference cannot recover a `comptime T` slot from runtime arguments,
    /// so each helper receives `ptr: anytype` and asks `@typeInfo` for the
    /// element type instead. Centralised here so every helper agrees on
    /// "argument is a single-item pointer to T".
    fn arcPtrChild(comptime PtrT: type) type {
        const info = @typeInfo(PtrT);
        if (info == .optional) {
            const inner = @typeInfo(info.optional.child);
            if (inner == .pointer and inner.pointer.size == .one) {
                return inner.pointer.child;
            }
        }
        if (info != .pointer or info.pointer.size != .one) {
            @compileError("ArcRuntime helper expects a single-item pointer; got " ++ @typeName(PtrT));
        }
        return info.pointer.child;
    }

    fn arcPtrIsOptional(comptime PtrT: type) bool {
        return @typeInfo(PtrT) == .optional;
    }

    /// Returns true when `T` carries its own ARC header inline as the
    /// first field rather than relying on the generic side-table pool.
    /// Such types are responsible for their own allocation pool and
    /// destruction (via a `release` or `arcReleaseDeep` method) — typically
    /// because they own variable-length payload buffers (`Map(K, V)`,
    /// `List(T)`). Inline-header types bypass the side-table refcount
    /// path entirely: their refcount lives in the cell's own `header`
    /// field, allocated and freed through the type's bespoke pool.
    fn hasInlineArcHeader(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        if (info.@"struct".fields.len == 0) return false;
        const first = info.@"struct".fields[0];
        if (first.type != ArcHeader) return false;
        if (!std.mem.eql(u8, first.name, "header")) return false;
        return true;
    }

    /// Free an Arc-managed value given a pointer to the value field.
    /// Decrements the refcount and frees the inner allocation when it reaches zero.
    /// The `allocator` argument is vestigial — the inner allocation is owned
    /// by the per-type `ArcPool` and returns there on destruction.
    ///
    /// Validation mirrors `releaseAny` — the dispatcher refuses to
    /// dispatch against a manager that does not declare REFCOUNT_V1.
    pub inline fn freeAny(allocator: std.mem.Allocator, ptr: anytype) void {
        if (comptime !refcount_v1_active) {
            // Phase 6 lifecycle pairing: under no-REFCOUNT_V1, every
            // `allocAny` call routed through `core.allocate` (see the
            // non-REFCOUNT_V1 branch of `allocAny` above). Spec §4.5
            // mandates the matching call is `core.deallocate(ctx, ptr,
            // size, alignment)` — there are no refcounted cells in
            // this mode, so all allocations are "raw" and the alloc/
            // free pair flows entirely through the core vtable. The
            // refcount instrumentation (retain/release counters, deep-
            // walk callbacks, side-table refcount layout) is elided,
            // but the allocation lifecycle pairing is preserved so
            // tracking managers can observe matched alloc/free pairs.
            //
            // `_ = allocator;` would conflict with the REFCOUNT_V1
            // branch below (Zig errors on discard-of-used-param), so
            // leave the parameter untouched.
            return freeAnyNonRefcountedImpl(allocator, ptr);
        }
        if (active_manager_state.shutdown_complete) {
            @panic("zap runtime: memory dispatch after shutdown");
        }
        ensureMemoryStartup();
        if (active_manager_state.core == null) {
            @panic("zap runtime: freeAny dispatched with no active memory manager");
        }
        if (active_manager_state.refcount_capability == null) {
            @panic("zap runtime: freeAny dispatched but active manager does not declare REFCOUNT_V1");
        }
        dispatcherFreeImpl(allocator, ptr);
    }

    /// Phase 6 lifecycle-pairing dispatcher for `freeAny` under a manager
    /// that does NOT declare REFCOUNT_V1. The matching call to the
    /// non-REFCOUNT_V1 branch of `allocAny` (which routes through
    /// `core.allocate`); spec §4.5 requires this side to route through
    /// `core.deallocate(ctx, ptr, size, alignment)` so tracking managers
    /// see matched alloc/free pairs.
    ///
    /// Inline-header types (`Map(K,V)`, `List(T)`, …) own their own
    /// allocation pool and free path through their bespoke `release`
    /// method — the generic core-vtable round trip would double-free
    /// the cell's payload buffer. The compiler routes those types
    /// through `T.release(...)` independently; we still call it from
    /// here so the elided-IR path stays consistent with the REFCOUNT_V1
    /// `dispatcherFreeImpl` shape.
    fn freeAnyNonRefcountedImpl(allocator: std.mem.Allocator, ptr: anytype) void {
        if (comptime arcPtrIsOptional(@TypeOf(ptr))) {
            const unwrapped = ptr orelse return;
            return freeAnyNonRefcountedImpl(allocator, unwrapped);
        }
        @setEvalBranchQuota(2000);
        _ = &allocator;
        const T = arcPtrChild(@TypeOf(ptr));
        if (comptime hasInlineArcHeader(T)) {
            // Self-managed: T owns its own pool, allocated via the
            // type's bespoke `bufferAlloc`-style call that already
            // dispatches through `core.allocate`. T.release dispatches
            // through `core.deallocate` for the cell payload. Match
            // that semantic here so the generic-wrapper call site is
            // a single source of truth.
            if (@hasDecl(T, "release")) {
                T.release(@as(?*const T, ptr));
            } else if (@hasDecl(T, "arcReleaseDeep")) {
                T.arcReleaseDeep(std.heap.page_allocator, ptr);
            } else {
                @compileError("inline-header Arc type missing release/arcReleaseDeep: " ++ @typeName(T));
            }
            return;
        }
        // Generic Arc(T) raw allocation: the matching `allocAny` call
        // routed through `core.allocate(size, alignment)`; mirror that
        // through `core.deallocate(ptr, size, alignment)` so tracking
        // managers see balanced alloc/free pairs. For Arena (no-op
        // deallocate) and NoOp (no-op deallocate) this is free; for
        // future tracking managers it's the observable hook.
        if (active_manager_state.shutdown_complete) {
            // Memory dispatch after shutdown is a soundness violation
            // (spec §4.6). Panic loudly even under the lifecycle-only
            // path so the diagnostic surfaces at the call site rather
            // than as a silent leak.
            @panic("zap runtime: memory dispatch after shutdown");
        }
        ensureMemoryStartup();
        if (active_manager_state.core == null) {
            @panic("zap runtime: freeAny dispatched with no active memory manager");
        }
        const ctx = active_manager_state.context orelse
            @panic("zap runtime: freeAny dispatched with null manager context");
        const size = @sizeOf(T);
        const alignment_bytes = @alignOf(T);
        const raw: [*]u8 = @ptrCast(@constCast(ptr));
        if (comptime ACTIVE_MANAGER_TAG == .third_party) {
            const core = active_manager_state.core orelse
                @panic("zap runtime: freeAny dispatched with no active memory manager");
            core.deallocate(ctx, raw, size, @intCast(alignment_bytes));
        } else {
            active_manager.deallocate(ctx, raw, size, @intCast(alignment_bytes));
        }
    }

    /// Runtime-side dispatcher implementation of `freeAny`. Phase 4.x:
    /// routes through the active manager's `release_sized` slot with
    /// `deep_walk=null` so the manager performs the refcount decrement
    /// and (on the zero-transition) the slot return without recursing
    /// into children. Inline-header types continue through their
    /// dedicated `release` / `arcReleaseDeep` method.
    fn dispatcherFreeImpl(allocator: std.mem.Allocator, ptr: anytype) void {
        if (comptime arcPtrIsOptional(@TypeOf(ptr))) {
            const unwrapped = ptr orelse return;
            return dispatcherFreeImpl(allocator, unwrapped);
        }
        @setEvalBranchQuota(2000);
        _ = &allocator;
        const T = arcPtrChild(@TypeOf(ptr));
        if (comptime hasInlineArcHeader(T)) {
            // Self-managed: T owns its own pool. Release routes through
            // T's release method, which performs deep teardown including
            // any heap-allocated payload arrays. The refcount decrement
            // inside that path flows through the active manager's
            // REFCOUNT_V1 vtable via `headerRelease`.
            if (@hasDecl(T, "release")) {
                T.release(@as(?*const T, ptr));
            } else if (@hasDecl(T, "arcReleaseDeep")) {
                T.arcReleaseDeep(std.heap.page_allocator, ptr);
            } else {
                @compileError("inline-header Arc type missing release/arcReleaseDeep: " ++ @typeName(T));
            }
            return;
        }
        // Arc(T) side-table path. Shallow free — no children walk; the
        // manager observes the refcount decrement and on the zero-
        // transition returns the slot to the slab pool. Public entry
        // already validated globals.
        const ctx = active_manager_state.context orelse unreachable;
        if (!active_manager_state.refcount_has_sized_extension) {
            // v1.0 fallback: dispatch through `release` on the inline
            // ArcHeader at the cell base. The shallow-free closure
            // deallocates the cell without walking children (matching
            // the side-table path's shallow-free semantics).
            const header_ptr = legacyArcInnerHeaderFromValuePtr(T, @constCast(ptr));
            if (comptime ACTIVE_MANAGER_TAG == .third_party) {
                const cap = active_manager_state.refcount_capability orelse unreachable;
                cap.release(ctx, header_ptr, LegacyV1_0ShallowFreeClosure(T).run);
            } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
                active_manager.release(ctx, header_ptr, LegacyV1_0ShallowFreeClosure(T).run);
            } else {
                @panic("zap runtime: freeAny dispatched but active manager does not declare REFCOUNT_V1");
            }
            return;
        }
        const size = @sizeOf(T);
        const alignment_bytes = @alignOf(T);
        const slot_ptr: *T = @constCast(ptr);
        if (comptime ACTIVE_MANAGER_TAG == .third_party) {
            const cap = active_manager_state.refcount_capability orelse unreachable;
            cap.release_sized(ctx, slot_ptr, size, @intCast(alignment_bytes), null);
        } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
            active_manager.releaseSized(ctx, slot_ptr, size, @intCast(alignment_bytes), null);
        } else {
            @panic("zap runtime: freeAny dispatched but active manager does not declare REFCOUNT_V1");
        }
    }

    /// Comptime-generated shallow-free callback for the v1.0 fallback
    /// `release` path. Mirrors `LegacyV1_0ReleaseClosure` but skips
    /// the children walk — used by `freeAny` whose contract is shallow
    /// (the caller has already released children, or the type has
    /// none).
    fn LegacyV1_0ShallowFreeClosure(comptime T: type) type {
        return struct {
            fn run(header_obj: *anyopaque) callconv(.c) void {
                // `header_obj` aliases the inline `ArcHeader` at the
                // cell base — the manager passed in exactly the same
                // pointer we handed to `cap.release`. The cell extends
                // for `LegacyArcInnerLayout(T).size` bytes starting at
                // that address; deallocate the whole range.
                const layout = LegacyArcInnerLayout(T);
                if (active_manager_state.core == null) {
                    @panic("zap runtime: v1.0 legacy freeAny: no active manager core");
                }
                const ctx = active_manager_state.context orelse @panic(
                    "zap runtime: v1.0 legacy freeAny: null manager context",
                );
                const raw: [*]u8 = @ptrCast(@alignCast(header_obj));
                if (comptime ACTIVE_MANAGER_TAG == .third_party) {
                    const core = active_manager_state.core orelse @panic(
                        "zap runtime: v1.0 legacy freeAny: no active manager core",
                    );
                    core.deallocate(ctx, raw, layout.size, @intCast(layout.alignment));
                } else {
                    active_manager.deallocate(ctx, raw, layout.size, @intCast(layout.alignment));
                }
            }
        };
    }

    /// Release (decrement refcount) an Arc-managed value given a pointer to the
    /// value field. On the zero-transition, recursively releases any indirect-
    /// storage Arc'd children before destroying the inner allocation; for types
    /// without such fields the comptime walk degenerates to a shallow free.
    ///
    /// Accepts the pointer as `anytype` so the ZIR backend's two-argument
    /// call site (`releaseAny(allocator, ptr)`) compiles — Zig cannot infer
    /// a leading `comptime T: type` parameter from the runtime ptr argument.
    /// The element type is recovered via `@typeInfo`.
    ///
    /// The dispatcher validates the active manager and (for managers
    /// declaring REFCOUNT_V1) the active refcount capability before
    /// dispatching to the impl. See the header comment on `allocAny`
    /// for why the typed slab-pool path still uses the typed impl
    /// directly rather than the byte-level vtable.
    pub fn releaseAny(allocator: std.mem.Allocator, ptr: anytype) void {
        if (comptime !refcount_v1_active) {
            // Phase 6 lifecycle pairing: under no-REFCOUNT_V1, the
            // matching `allocAny` call routed through `core.allocate`
            // (spec §4.5 — all allocations are "raw" in this mode).
            // The refcount instrumentation (`releaseArcAny` deep walk,
            // `arc_releases_total` counter, side-table refcount
            // decrement) is elided, but the allocation lifecycle
            // pairing flows through `core.deallocate` so tracking
            // managers see balanced alloc/free pairs. Phase 7
            // diagnostic managers depend on this.
            return freeAnyNonRefcountedImpl(allocator, ptr);
        }
        if (active_manager_state.shutdown_complete) {
            @panic("zap runtime: memory dispatch after shutdown");
        }
        ensureMemoryStartup();
        if (active_manager_state.core == null) {
            @panic("zap runtime: releaseAny dispatched with no active memory manager");
        }
        if (active_manager_state.refcount_capability == null) {
            // Spec: when the active manager does not declare REFCOUNT_V1,
            // the compiler statically elides retain/release at HIR
            // elaboration time (section 8.5). Reaching this dispatcher
            // with no active refcount capability means the compiler
            // failed to elide, or a non-refcount manager is active and
            // an old call site survived — a soundness bug either way.
            @panic("zap runtime: releaseAny dispatched but active manager does not declare REFCOUNT_V1");
        }
        dispatcherReleaseImpl(allocator, ptr);
    }

    /// Runtime-side dispatcher implementation of `releaseAny`. Lives
    /// in the runtime so the comptime `T` can drive the per-type
    /// deep-walk callback that the manager's `release_sized` slot
    /// invokes on the zero-transition (inline-header types T route
    /// through `T.release` / `T.arcReleaseDeep` for the same reason).
    fn dispatcherReleaseImpl(allocator: std.mem.Allocator, ptr: anytype) void {
        if (comptime arcPtrIsOptional(@TypeOf(ptr))) {
            const unwrapped = ptr orelse return;
            return dispatcherReleaseImpl(allocator, unwrapped);
        }
        const T = arcPtrChild(@TypeOf(ptr));
        releaseArcAny(T, allocator, ptr);
        // Counter increments AFTER `releaseArcAny` returns so it only
        // ticks when the operation actually happened. Matches the
        // post-dispatch convention used by `headerRelease` and
        // `dispatcherRetainImpl`.
        //
        // Inline-header types (`Map(K, V)`, `List(T)`, ...) own
        // their own pool and bump `arc_releases_total` inside their
        // dedicated `release` method; if the generic wrapper also
        // bumped, every release routed through `releaseAny` would
        // double-count. Skip the bump here when `T` is self-managed —
        // the inner `T.release(...)` call inside `releaseArcAny`
        // accounts for this release. For Arc(T)-wrapped values the
        // wrapper is the only counter site, so the bump stays.
        if (comptime collect_arc_stats and !hasInlineArcHeader(T)) {
            arc_releases_total += 1;
        }
    }

    /// Deep-release an Arc-managed value. Walks the value's struct fields
    /// at comptime: every indirect-storage Arc'd field — encoded by the
    /// Zap codegen as a single-item const pointer (`?*const ChildT`) — is
    /// released recursively before the parent allocation is destroyed.
    ///
    /// For types without any indirect-storage fields, the comptime walk
    /// expands to nothing and behavior is identical to `releaseAny`.
    ///
    /// Recursion at the type level (e.g. `Tree` → `?*const Tree` → `Tree`)
    /// terminates because Zig memoizes generic instantiations by their
    /// comptime parameter values; the recursive reference reuses the same
    /// in-progress instance rather than expanding indefinitely.
    ///
    /// Phase 4.x: For Arc(T) types this is implemented as
    /// `cap.release_sized(ptr, size, alignment, deep_walk)` where
    /// `deep_walk` is a per-T callback that invokes
    /// `releaseChildrenAny(T, ...)` on the cell BEFORE the manager
    /// returns the slot to the slab pool. Inline-header types continue
    /// to go through their dedicated `release` / `arcReleaseDeep`
    /// method (which itself routes through `headerRelease`).
    pub fn releaseArcAny(comptime T: type, allocator: std.mem.Allocator, ptr: *const T) void {
        if (comptime hasInlineArcHeader(T)) {
            if (@hasDecl(T, "release")) {
                T.release(@as(?*const T, ptr));
            } else if (@hasDecl(T, "arcReleaseDeep")) {
                T.arcReleaseDeep(allocator, ptr);
            } else {
                @compileError("inline-header Arc type missing release/arcReleaseDeep: " ++ @typeName(T));
            }
            return;
        }
        // Arc(T) side-table path. Dispatch through the active manager's
        // `release_sized` slot; on the zero-transition the manager
        // invokes the per-T `deep_walk` callback (which recursively
        // releases children) and then frees the slot. The outer
        // `releaseAny` already validated globals before reaching this
        // type-specific dispatcher.
        const ctx = active_manager_state.context orelse unreachable;
        if (!active_manager_state.refcount_has_sized_extension) {
            // v1.0 fallback: the cell was allocated via
            // `dispatcherAllocLegacyV1_0` with an inline ArcHeader at
            // offset 0 of the cell, followed by the user payload at
            // `value_offset`. Dispatch through the v1.0 `release` slot
            // which operates on the inline header; on the zero-
            // transition the manager calls `LegacyV1_0ReleaseClosure(T).run`
            // to walk children and free the backing cell via
            // `core.deallocate`.
            const header_ptr = legacyArcInnerHeaderFromValuePtr(T, @constCast(ptr));
            const deep_walk: AbiV1.ZapDeepWalkFn = LegacyV1_0ReleaseClosure(T).run;
            if (comptime ACTIVE_MANAGER_TAG == .third_party) {
                const cap = active_manager_state.refcount_capability orelse unreachable;
                cap.release(ctx, header_ptr, deep_walk);
            } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
                active_manager.release(ctx, header_ptr, deep_walk);
            } else {
                @panic("zap runtime: releaseArcAny dispatched but active manager does not declare REFCOUNT_V1");
            }
            return;
        }
        const size = @sizeOf(T);
        const alignment_bytes = @alignOf(T);
        const slot_ptr: *T = @constCast(ptr);
        const deep_walk: ?AbiV1.ZapDeepWalkFn = if (comptime typeHasArcChildren(T))
            DeepWalkFnFor(T)
        else
            null;
        if (comptime ACTIVE_MANAGER_TAG == .third_party) {
            const cap = active_manager_state.refcount_capability orelse unreachable;
            cap.release_sized(ctx, slot_ptr, size, @intCast(alignment_bytes), deep_walk);
        } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
            active_manager.releaseSized(ctx, slot_ptr, size, @intCast(alignment_bytes), deep_walk);
        } else {
            @panic("zap runtime: releaseArcAny dispatched but active manager does not declare REFCOUNT_V1");
        }
    }

    /// Comptime-generated callback for the v1.0 fallback `release`
    /// path. The v1.0 vtable's `release` slot accepts only `(ctx,
    /// object, deep_walk)` — no `size` / `alignment`. The runtime
    /// therefore wires the per-T deep-walk + `core.deallocate` of the
    /// inline cell into a single closure that the manager invokes on
    /// the zero-transition. The closure reaches
    /// `core.allocate`/`core.deallocate` through the runtime globals —
    /// same pattern as `DeepWalkFnFor`.
    fn LegacyV1_0ReleaseClosure(comptime T: type) type {
        return struct {
            fn run(header_obj: *anyopaque) callconv(.c) void {
                // `header_obj` aliases the inline `ArcHeader` at the
                // cell base. Recover the user-payload pointer via the
                // layout-derived value offset, walk children, then
                // deallocate the whole cell.
                const layout = LegacyArcInnerLayout(T);
                const base_byte_ptr: [*]u8 = @ptrCast(@alignCast(header_obj));
                // Children walk first so they observe a still-valid
                // parent; mirrors the spec §8.2 ordering.
                if (comptime typeHasArcChildren(T)) {
                    const value_ptr: *T = @ptrCast(@alignCast(base_byte_ptr + layout.value_offset));
                    releaseChildrenAny(T, std.heap.page_allocator, value_ptr.*);
                }
                if (active_manager_state.core == null) {
                    @panic("zap runtime: v1.0 legacy release: no active manager core");
                }
                const ctx = active_manager_state.context orelse @panic(
                    "zap runtime: v1.0 legacy release: null manager context",
                );
                if (comptime ACTIVE_MANAGER_TAG == .third_party) {
                    const core = active_manager_state.core orelse @panic(
                        "zap runtime: v1.0 legacy release: no active manager core",
                    );
                    core.deallocate(ctx, base_byte_ptr, layout.size, @intCast(layout.alignment));
                } else {
                    active_manager.deallocate(ctx, base_byte_ptr, layout.size, @intCast(layout.alignment));
                }
            }
        };
    }

    /// Walk every field of an aggregate value at comptime and deep-release
    /// any indirect-storage Arc'd children encountered. Non-aggregates are
    /// a no-op; flat aggregates compile to nothing.
    pub fn releaseChildrenAny(comptime T: type, allocator: std.mem.Allocator, value: T) void {
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                inline for (s.fields) |field| {
                    releaseFieldChildAny(field.type, allocator, @field(value, field.name));
                }
            },
            else => {},
        }
    }

    fn releaseFieldChildAny(comptime FieldType: type, allocator: std.mem.Allocator, value: FieldType) void {
        switch (@typeInfo(FieldType)) {
            .optional => |opt| {
                if (value) |inner| releaseFieldChildAny(opt.child, allocator, inner);
            },
            .pointer => |p| {
                if (p.size == .one) {
                    releaseArcAny(p.child, allocator, @constCast(value));
                }
            },
            else => {},
        }
    }

    /// Walk every field of an aggregate value at comptime and deep-retain
    /// any indirect-storage Arc'd children encountered. Mirrors
    /// `releaseChildrenAny` exactly — every field shape that the release
    /// walker would decrement, this walker increments. Used at sites
    /// that hand a borrowed-by-pointer aggregate to a caller that will
    /// later own and release it (e.g. `List.next` returning `cell.head`
    /// when the cell still owns the same value).
    pub fn retainChildrenAny(comptime T: type, value: T) void {
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                inline for (s.fields) |field| {
                    retainFieldChildAny(field.type, @field(value, field.name));
                }
            },
            else => {},
        }
    }

    fn retainFieldChildAny(comptime FieldType: type, value: FieldType) void {
        switch (@typeInfo(FieldType)) {
            .optional => |opt| {
                if (value) |inner| retainFieldChildAny(opt.child, inner);
            },
            .pointer => |p| {
                if (p.size == .one) {
                    // Struct/aggregate field deep-retain represents a
                    // genuine new persistent owner of the inner ARC
                    // value (the parent aggregate). Route through the
                    // persistent path so type-specific instrumentation
                    // (Map share-event tracking) observes the share.
                    retainAnyPersistent(@as(*const p.child, value));
                }
            },
            else => {},
        }
    }

    /// Generic ARC retain used for *transient* borrow-pass plumbing —
    /// the IR `share_value mode=retain` lowering. This pairs with a
    /// matching post-call `releaseAny` so the retain represents
    /// temporary ownership that resolves before the next user-visible
    /// mutation. Type-specific instrumentation hooks (Map workload
    /// share-event classifier in particular) deliberately do *not*
    /// fire on this path. Use `retainAnyPersistent` instead when the
    /// retain represents a new long-lived owner — for example a List
    /// element slot, a Map entry's retained value, or a struct field
    /// assignment.
    ///
    /// Phase 2 indirection layer: the dispatcher validates the active
    /// manager + refcount capability before dispatching to either the
    /// inline-header `cap.retain` slot (for Map/List/MapIter cells)
    /// or the side-table `cap.retain_sized` slot (for `Arc(T)` cells).
    ///
    /// Naming convention: `retainAny` / `releaseAny` are the typed-
    /// pointer entry points used by codegen for `Arc(T)` cells, while
    /// `headerRetain` / `headerRelease` are the inline-header entry
    /// points used by `Map.retain`, `List.retain`, etc. Both families
    /// route through the same REFCOUNT_V1 capability; the inline-
    /// header family uses `retain` / `release` (atomic-on-offset-0 of
    /// the cell), and the Arc(T) family uses `retain_sized` /
    /// `release_sized` (slab-lookup via 64-KiB-aligned pointer mask
    /// + size class).
    pub inline fn retainAny(ptr: anytype) void {
        // Phase 6: codegen elides every retainAny call under no-REFCOUNT_V1.
        if (comptime !refcount_v1_active) return;
        // Phase 6 inline: the body is small enough (5 loads + 3 panics +
        // a tail call) that forcing the compiler to inline it lets LLVM
        // fold each consecutive call's preflight loads through CSE on
        // `active_manager_state`. Marked `inline` rather than `inline
        // callconv(.@"inline")` so the compiler can still split the
        // cold panic paths out of the inlined body.
        if (active_manager_state.shutdown_complete) {
            @panic("zap runtime: memory dispatch after shutdown");
        }
        ensureMemoryStartup();
        if (active_manager_state.core == null) {
            @panic("zap runtime: retainAny dispatched with no active memory manager");
        }
        if (active_manager_state.refcount_capability == null) {
            // See note in `releaseAny` on REFCOUNT_V1 absence; the same
            // soundness argument applies symmetrically here.
            @panic("zap runtime: retainAny dispatched but active manager does not declare REFCOUNT_V1");
        }
        dispatcherRetainImpl(ptr);
    }

    /// Runtime-side dispatcher implementation of `retainAny`. Phase 4.x:
    /// inline-header types route through `headerRetain` (atomic on the
    /// offset-0 ArcHeader); Arc(T) side-table types route through the
    /// active manager's `retain_sized` slot, which locates the cell's
    /// slab via pointer masking and atomic-increments the side-table
    /// refcount. The public entry (`retainAny`) has already validated
    /// `active_manager_state.refcount_capability != null` and
    /// `active_manager_state.context != null`; the dispatcher therefore
    /// reads both via unchecked unwrap with `.?`, letting the compiler
    /// fold the redundant null guard.
    fn dispatcherRetainImpl(ptr: anytype) void {
        if (comptime arcPtrIsOptional(@TypeOf(ptr))) {
            const unwrapped = ptr orelse return;
            return dispatcherRetainImpl(unwrapped);
        }
        const T = arcPtrChild(@TypeOf(ptr));
        if (comptime hasInlineArcHeader(T)) {
            const mut: *T = @constCast(ptr);
            headerRetain(&mut.header);
            return;
        }
        // Arc(T) side-table path. The public entry has already validated
        // both globals; the orelse unreachable lets release builds
        // elide the second null check.
        const ctx = active_manager_state.context orelse unreachable;
        if (!active_manager_state.refcount_has_sized_extension) {
            // v1.0 fallback: dispatch through `retain` on the inline
            // header at the cell base.
            const header_ptr = legacyArcInnerHeaderFromValuePtr(T, @constCast(ptr));
            if (comptime ACTIVE_MANAGER_TAG == .third_party) {
                const cap = active_manager_state.refcount_capability orelse unreachable;
                cap.retain(ctx, header_ptr);
            } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
                active_manager.retain(ctx, header_ptr);
            } else {
                @panic("zap runtime: retainAny dispatched but active manager does not declare REFCOUNT_V1");
            }
            if (comptime collect_arc_stats) {
                arc_retains_total += 1;
            }
            return;
        }
        const size = @sizeOf(T);
        const alignment_bytes = @alignOf(T);
        const slot_ptr: *T = @constCast(ptr);
        if (comptime ACTIVE_MANAGER_TAG == .third_party) {
            const cap = active_manager_state.refcount_capability orelse unreachable;
            cap.retain_sized(ctx, slot_ptr, size, @intCast(alignment_bytes));
        } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
            active_manager.retainSized(ctx, slot_ptr, size, @intCast(alignment_bytes));
        } else {
            @panic("zap runtime: retainAny dispatched but active manager does not declare REFCOUNT_V1");
        }
        if (comptime collect_arc_stats) {
            arc_retains_total += 1;
        }
    }

    /// Retain for *persistent* container ownership: the caller is
    /// stashing the ARC value inside another long-lived owner — a
    /// List element slot, a Map entry's value, a struct field. Routes
    /// through the type's public `retain` method when one exists so
    /// type-specific bookkeeping fires; in particular this is the
    /// retain path the Map workload instrumentation classifies as a
    /// real concurrent-owner share event. `retainAny` (above) covers
    /// the symmetric transient case.
    ///
    /// Validation pattern mirrors `retainAny`.
    pub inline fn retainAnyPersistent(ptr: anytype) void {
        // Phase 6: codegen elides every retainAnyPersistent call under no-REFCOUNT_V1.
        if (comptime !refcount_v1_active) return;
        // Phase 6 inline: same rationale as `retainAny`. Preflight body
        // is small enough that inlining lets LLVM CSE the
        // `active_manager_state` loads across consecutive calls.
        if (active_manager_state.shutdown_complete) {
            @panic("zap runtime: memory dispatch after shutdown");
        }
        ensureMemoryStartup();
        if (active_manager_state.core == null) {
            @panic("zap runtime: retainAnyPersistent dispatched with no active memory manager");
        }
        if (active_manager_state.refcount_capability == null) {
            @panic("zap runtime: retainAnyPersistent dispatched but active manager does not declare REFCOUNT_V1");
        }
        dispatcherRetainAnyPersistentImpl(ptr);
    }

    /// Runtime-side dispatcher implementation of `retainAnyPersistent`.
    /// Phase 4.x: inline-header types prefer the public `retain` method
    /// (which routes through `headerRetain` plus any type-specific
    /// bookkeeping like Map's share-event hook); falls back to
    /// `headerRetain` directly when the type does not expose a public
    /// `retain`. Arc(T) side-table types route through the active
    /// manager's `retain_sized` slot.
    fn dispatcherRetainAnyPersistentImpl(ptr: anytype) void {
        if (comptime arcPtrIsOptional(@TypeOf(ptr))) {
            const unwrapped = ptr orelse return;
            return dispatcherRetainAnyPersistentImpl(unwrapped);
        }
        const T = arcPtrChild(@TypeOf(ptr));
        if (comptime hasInlineArcHeader(T)) {
            if (comptime @hasDecl(T, "retain")) {
                _ = T.retain(@as(?*const T, ptr));
                return;
            }
            const mut: *T = @constCast(ptr);
            headerRetain(&mut.header);
            return;
        }
        // Arc(T) side-table path. Public entry already validated globals.
        const ctx = active_manager_state.context orelse unreachable;
        if (!active_manager_state.refcount_has_sized_extension) {
            // v1.0 fallback — same dispatch as the transient retain
            // path but with the persistent counter convention.
            const header_ptr = legacyArcInnerHeaderFromValuePtr(T, @constCast(ptr));
            if (comptime ACTIVE_MANAGER_TAG == .third_party) {
                const cap = active_manager_state.refcount_capability orelse unreachable;
                cap.retain(ctx, header_ptr);
            } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
                active_manager.retain(ctx, header_ptr);
            } else {
                @panic("zap runtime: retainAnyPersistent dispatched but active manager does not declare REFCOUNT_V1");
            }
            if (comptime collect_arc_stats) {
                arc_retains_total += 1;
            }
            return;
        }
        const size = @sizeOf(T);
        const alignment_bytes = @alignOf(T);
        const slot_ptr: *T = @constCast(ptr);
        if (comptime ACTIVE_MANAGER_TAG == .third_party) {
            const cap = active_manager_state.refcount_capability orelse unreachable;
            cap.retain_sized(ctx, slot_ptr, size, @intCast(alignment_bytes));
        } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
            active_manager.retainSized(ctx, slot_ptr, size, @intCast(alignment_bytes));
        } else {
            @panic("zap runtime: retainAnyPersistent dispatched but active manager does not declare REFCOUNT_V1");
        }
        if (comptime collect_arc_stats) {
            arc_retains_total += 1;
        }
    }

    /// Retain through an optional Arc pointer: `?*const T` becomes a no-op
    /// when null, otherwise unwraps and increments the refcount. Field-get
    /// on an indirect-storage recursive field (`?*const T`) emits this so
    /// the extracted reference and the parent both own the child Arc — a
    /// later deep release of either owner decrements once and only the
    /// final decrement frees the allocation.
    pub fn retainAnyOpt(ptr: anytype) void {
        const PtrT = @TypeOf(ptr);
        switch (@typeInfo(PtrT)) {
            .optional => if (ptr) |p| retainAny(p),
            .pointer => retainAny(ptr),
            else => @compileError("retainAnyOpt expects pointer or optional pointer; got " ++ @typeName(PtrT)),
        }
    }

    /// Dispatch a refcount retain on an inline-header cell through the
    /// active manager's REFCOUNT_V1 capability vtable. `header_ptr`
    /// must point at the `ArcHeader` at offset 0 of an inline-header
    /// cell (`Map(K,V)`, `List(T)`, `MapIter`, ...). The vtable's
    /// `retain(ctx, ptr)` slot, for the first-party `Zap.Memory.ARC`
    /// manager, performs an atomic `monotonic` increment on the 4-byte
    /// refcount at offset 0 of the cell. Future managers may use a
    /// completely different mechanism (e.g., generational refcounts).
    ///
    /// This is the inline-header counterpart to `retainAny` / typed
    /// dispatch. It exists so `Map.retain` and friends can route
    /// through the same vtable indirection that Phase 6 will need
    /// for codegen elision under non-refcounting managers — without
    /// requiring those types to take a `comptime T: type` parameter.
    /// The dispatcher bumps `arc_retains_total` so callers no longer
    /// need to do it themselves.
    pub inline fn headerRetain(header_ptr: *ArcHeader) void {
        // Phase 6: under a manager that does not declare REFCOUNT_V1
        // the inline `ArcHeader` field is omitted from cell layout
        // (`@sizeOf(ArcHeader) == 0`) and the codegen pipeline elides
        // every retain. Any *internal* call from runtime methods
        // (`Map.retain`, `List.retain`, `MapIter.create`, ...) is
        // comptime-eliminated here. The function body that remains is
        // unchanged for the REFCOUNT_V1 path.
        //
        // Phase 6 inline: the post-elision body is small enough (a few
        // loads + a tail call) that forcing inlining lets LLVM CSE the
        // `active_manager_state` loads across consecutive call sites
        // (e.g., inside `Map.retain`'s rc=1 fast path).
        if (comptime !refcount_v1_active) return;

        // Coverage note: the shutdown-complete and capability-null guard
        // paths below trigger `@panic`, which aborts the test process,
        // so they cannot be exercised under standard `zig build test`.
        // Coverage of these guards is by inspection today; if regression
        // testing becomes necessary, a separate fault-injection harness
        // that spawns child processes and asserts on the panic message
        // would be required. The same caveat applies to `headerRelease`
        // and the other `*Any` dispatchers in this file.
        //
        // (core, ctx, cap) non-snapshot rationale: spec §10.2 makes the
        // active manager binding write-once-then-read-only for the
        // program's lifetime, so the three loads cannot tear. A future
        // ABI version that supports per-process manager swap would
        // switch the read pattern to a single atomic acquire-load of a
        // manager-state record that holds (core, ctx, cap) as a triple;
        // v1.x is single-manager-per-binary and pays no such cost.
        if (active_manager_state.shutdown_complete) {
            @panic("zap runtime: memory dispatch after shutdown");
        }
        ensureMemoryStartup();
        if (active_manager_state.core == null) {
            @panic("zap runtime: headerRetain dispatched with no active memory manager");
        }
        const ctx = active_manager_state.context orelse {
            @panic("zap runtime: headerRetain dispatched with null manager context");
        };
        if (comptime ACTIVE_MANAGER_TAG == .third_party) {
            const cap = active_manager_state.refcount_capability orelse {
                @panic("zap runtime: headerRetain dispatched but active manager does not declare REFCOUNT_V1");
            };
            cap.retain(ctx, @ptrCast(header_ptr));
        } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
            active_manager.retain(ctx, @ptrCast(header_ptr));
        } else {
            @panic("zap runtime: headerRetain dispatched but active manager does not declare REFCOUNT_V1");
        }
        if (comptime collect_arc_stats) {
            arc_retains_total += 1;
        }
    }

    /// Dispatch a refcount release on an inline-header cell through the
    /// active manager's REFCOUNT_V1 capability vtable, invoking
    /// `deep_walk(header_ptr)` on the final zero-transition.
    ///
    /// `deep_walk` is the per-type callback the caller wants the
    /// manager to invoke once when the refcount reaches zero. For
    /// inline-header types in Zap, the storage free is part of the
    /// per-type `deep_walk` callback (the type-specific
    /// `bufferFreeDeep` walks elements and frees the c_allocator-
    /// backed buffer). This is an architectural choice documented
    /// in `src/memory/arc/manager.zig` — Phase 5+ may revisit it
    /// once the build pipeline can carry per-manager allocation
    /// options.
    ///
    /// The dispatcher bumps `arc_releases_total` so callers no longer
    /// need to do it themselves.
    pub inline fn headerRelease(
        header_ptr: *ArcHeader,
        deep_walk: ?AbiV1.ZapDeepWalkFn,
    ) void {
        // Phase 6: under a manager that does not declare REFCOUNT_V1
        // the inline `ArcHeader` field is omitted from cell layout
        // and the codegen pipeline elides every release. Any internal
        // call from runtime methods is comptime-eliminated here. The
        // deep-walk callback never fires in that mode either —
        // `bufferFreeDeep` would attempt to walk children that may
        // themselves require a non-existent allocator; freeing is
        // deferred to the arena's bulk reclamation at process exit.
        //
        // Phase 6 inline: the post-elision body is small (a few loads,
        // a vtable call, and a counter bump). Forcing inlining lets
        // LLVM CSE the `active_manager_state` loads across consecutive
        // call sites — important because release sites cluster (e.g.,
        // recursive `Tree` release fires every node's `headerRelease`
        // on the inline-header `List`-of-children).
        if (comptime !refcount_v1_active) return;

        // Same (core, ctx, cap) non-snapshot rationale as
        // `headerRetain` — manager binding is fixed for the program's
        // lifetime in ABI v1.x, so the three loads cannot tear.
        if (active_manager_state.shutdown_complete) {
            @panic("zap runtime: memory dispatch after shutdown");
        }
        ensureMemoryStartup();
        if (active_manager_state.core == null) {
            @panic("zap runtime: headerRelease dispatched with no active memory manager");
        }
        const ctx = active_manager_state.context orelse {
            @panic("zap runtime: headerRelease dispatched with null manager context");
        };
        if (comptime ACTIVE_MANAGER_TAG == .third_party) {
            const cap = active_manager_state.refcount_capability orelse {
                @panic("zap runtime: headerRelease dispatched but active manager does not declare REFCOUNT_V1");
            };
            cap.release(ctx, @ptrCast(header_ptr), deep_walk);
        } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
            active_manager.release(ctx, @ptrCast(header_ptr), deep_walk);
        } else {
            @panic("zap runtime: headerRelease dispatched but active manager does not declare REFCOUNT_V1");
        }
        // Counter increments AFTER the dispatched call so it only ticks
        // when the operation actually happened. Matches the convention
        // used by `dispatcherRetainImpl` (counter bump after
        // `ArcPool(T).retain`).
        if (comptime collect_arc_stats) {
            arc_releases_total += 1;
        }
    }

    /// Get the refcount of an Arc-managed value. Phase 4.x: inline-
    /// header types read directly from their offset-0 header; Arc(T)
    /// side-table types route through the active manager's
    /// `refcount_sized` slot, which looks up the slab and reads the
    /// side-table entry.
    pub fn refCountAny(ptr: anytype) u32 {
        if (comptime arcPtrIsOptional(@TypeOf(ptr))) {
            const unwrapped = ptr orelse return 0;
            return refCountAny(unwrapped);
        }
        const T = arcPtrChild(@TypeOf(ptr));
        if (comptime hasInlineArcHeader(T)) {
            return ptr.header.count();
        }
        if (comptime !refcount_v1_active) return 0;
        // The graceful `return 0` on a missing capability is preserved
        // for the third-party path so `resetAny`/Perceus-reuse remain
        // sound when running against a manager that hasn't bound a
        // REFCOUNT_V1 vtable yet. First-party builds always have the
        // capability wired (or it's a static `false` under managerHasRefcountV1
        // which short-circuits earlier).
        if (active_manager_state.refcount_capability == null) return 0;
        const ctx = active_manager_state.context orelse return 0;
        if (!active_manager_state.refcount_has_sized_extension) {
            // v1.0 fallback: the inline ArcHeader at the cell base
            // carries the refcount. Read it directly — v1.0 has no
            // `refcount_sized` slot.
            const header_ptr = legacyArcInnerHeaderFromValuePtr(T, @constCast(ptr));
            return header_ptr.count();
        }
        const size = @sizeOf(T);
        const alignment_bytes = @alignOf(T);
        const slot_ptr: *const T = ptr;
        if (comptime ACTIVE_MANAGER_TAG == .third_party) {
            const cap = active_manager_state.refcount_capability orelse return 0;
            return cap.refcount_sized(ctx, @ptrCast(@constCast(slot_ptr)), size, @intCast(alignment_bytes));
        } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
            return active_manager.refcountSized(ctx, @ptrCast(@constCast(slot_ptr)), size, @intCast(alignment_bytes));
        } else {
            return 0;
        }
    }

    /// Reset a value for Perceus-style reuse. If the reference count is 1,
    /// return an opaque reuse token for the existing allocation. Otherwise,
    /// release the current value and return null.
    pub fn resetAny(allocator: std.mem.Allocator, ptr: anytype) ?*anyopaque {
        if (refCountAny(ptr) == 1) {
            return @ptrCast(@constCast(ptr));
        }
        releaseAny(allocator, ptr);
        return null;
    }

    /// Convert a Perceus reuse token back into a typed allocation. If the token
    /// is present, reuse that storage; otherwise allocate a fresh value.
    pub fn reuseAllocByType(comptime T: type, allocator: std.mem.Allocator, token: ?*anyopaque) *T {
        if (token) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return allocator.create(T) catch @panic("ArcRuntime.reuseAllocByType: out of memory");
    }
};

fn listSumSimdLaneCount(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .int => std.simd.suggestVectorLength(T) orelse 1,
        else => 1,
    };
}

fn listSumScalar(comptime T: type, data: [*]const T, len: u32) T {
    var total: T = 0;
    var index: u32 = 0;
    while (index < len) : (index += 1) {
        total += data[index];
    }
    return total;
}

fn listSumIntegerSimd(comptime T: type, data: [*]const T, len: u32) T {
    comptime {
        if (@typeInfo(T) != .int) {
            @compileError("listSumIntegerSimd requires integer element type");
        }
    }

    const lane_count = comptime listSumSimdLaneCount(T);
    if (comptime lane_count <= 1) {
        return listSumScalar(T, data, len);
    }

    const SimdChunk = @Vector(lane_count, T);
    var lane_totals: SimdChunk = @splat(0);
    var index: u32 = 0;
    while (index + lane_count <= len) : (index += lane_count) {
        const chunk: SimdChunk = data[index..][0..lane_count].*;
        lane_totals += chunk;
    }

    var total: T = @reduce(.Add, lane_totals);
    while (index < len) : (index += 1) {
        total += data[index];
    }
    return total;
}

// ============================================================
// List(T) — single-allocation flat-buffer sequence.
//
// Single-allocation flat-buffer mutable array with COW semantics. The
// cell pointer (`?*const List(T)`) points to the buffer. `null` is
// the empty-list sentinel — no allocation until first `new_*`.
//
// Layout (single contiguous allocation through `c_allocator`):
//
//   [ Self    (header, len, capacity)         ]   <- buffer pointer
//   [ data: [capacity]T                        ]
//
// The first field is `header: ArcHeader` so `hasInlineArcHeader`
// recognises the type for ARC dispatch (same shape as `Map(K, V)`,
// `List(T)`).
//
// Mutation pattern (rc-1 fast path): every mutating function checks
// `header.count() == 1`; on the unique-owner branch it mutates the
// live buffer in place (possibly resized) and returns the same/new
// pointer; on the shared branch it deep-retain clones first so the
// original observer keeps a stable view.
//
// Why `c_allocator` instead of `page_allocator`: tiny lists with a few
// elements would each get a fresh 16 KiB page from
// `page_allocator`. libc malloc has size classes that pack small
// allocations efficiently — same choice the dense Map made.
// ============================================================

pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Element = T;

        // Inline buffer header. The cell pointer IS the buffer
        // pointer; `header: ArcHeader` lives at offset 0 so
        // `ArcRuntime.hasInlineArcHeader` recognises this type as
        // self-managed (same shape as List(T), Map(K, V) cells).

        /// ARC refcount. Initialised to 1 by `bufferAlloc`.
        header: ArcHeader,
        /// Number of populated elements (cursor for the next push).
        len: u32,
        /// Total capacity in elements (always >= len).
        cap: u32,

        // -------------------------------------------------------------------
        // Layout helpers
        // -------------------------------------------------------------------

        inline fn dataByteOffset() usize {
            return std.mem.alignForward(usize, @sizeOf(Self), @alignOf(T));
        }

        inline fn bufferSize(capacity_arg: u32) usize {
            return dataByteOffset() + @as(usize, capacity_arg) * @sizeOf(T);
        }

        inline fn bufferAlign() std.mem.Alignment {
            const a_self = std.mem.Alignment.of(Self);
            const a_t = std.mem.Alignment.of(T);
            return a_self.max(a_t);
        }

        inline fn dataPtr(self: *const Self) [*]T {
            const base: [*]u8 = @ptrCast(@constCast(self));
            return @as([*]T, @ptrCast(@alignCast(base + dataByteOffset())));
        }

        inline fn slotAt(self: *Self, idx: u32) *T {
            std.debug.assert(idx < self.len);
            return &self.dataPtr()[idx];
        }

        inline fn slotAtConst(self: *const Self, idx: u32) *const T {
            std.debug.assert(idx < self.len);
            return &self.dataPtr()[idx];
        }

        // -------------------------------------------------------------------
        // Buffer alloc / free
        // -------------------------------------------------------------------

        /// Allocate a freshly-initialised buffer with `capacity_arg`
        /// element slots and `len_arg` populated entries. The data
        /// region is left UNINITIALISED — callers fill the populated
        /// prefix before returning. Refcount starts at 1.
        fn bufferAlloc(capacity_arg: u32, len_arg: u32) ?*Self {
            std.debug.assert(len_arg <= capacity_arg);
            // Register the `ZAP_ARC_STATS=1` atexit hook on first
            // alloc so list-only programs (no Map, no pool-backed
            // type) still produce the runtime stats dump when the
            // user opts in. Idempotent.
            ensureArcStatsAtexit();
            const allocator = std.heap.c_allocator;
            const align_v = comptime bufferAlign();
            const total = bufferSize(capacity_arg);
            const raw = allocator.alignedAlloc(u8, align_v, total) catch return null;
            const self_ptr: *Self = @ptrCast(@alignCast(raw.ptr));
            self_ptr.* = .{
                .header = ArcHeader.init(),
                .len = len_arg,
                .cap = capacity_arg,
            };
            return self_ptr;
        }

        /// Free the buffer without deep-releasing T children. Used on
        /// the unique-owner resize path where children have been moved
        /// to the resized buffer.
        fn bufferFreeShallow(self: *Self) void {
            const allocator = std.heap.c_allocator;
            const total = bufferSize(self.cap);
            const align_v = comptime bufferAlign();
            const raw_ptr: [*]u8 = @ptrCast(self);
            const raw_slice = @as([*]align(align_v.toByteUnits()) u8, @alignCast(raw_ptr))[0..total];
            allocator.free(raw_slice);
        }

        /// Free the buffer after deep-releasing every populated element.
        /// Called on the zero-transition of `release`.
        fn bufferFreeDeep(self: *Self) void {
            const len = self.len;
            const data = self.dataPtr();
            const allocator = std.heap.c_allocator;
            for (0..len) |i| {
                releaseElement(data[i], allocator);
            }
            self.bufferFreeShallow();
        }

        // -------------------------------------------------------------------
        // Retain / release
        // -------------------------------------------------------------------

        /// Increment the refcount and return the same handle. Mirrors
        /// `Map(K, V).retain`.
        ///
        /// Routes through `ArcRuntime.headerRetain`, which dispatches
        /// to the active manager's REFCOUNT_V1 capability vtable.
        /// `arc_retains_total` is bumped inside the dispatcher.
        pub fn retain(vec: ?*const Self) ?*const Self {
            if (vec) |v| {
                const mut: *Self = @constCast(v);
                ArcRuntime.headerRetain(&mut.header);
            }
            return vec;
        }

        /// Decrement the refcount; on the zero-transition deep-release
        /// every element and free the buffer.
        ///
        /// Routes through `ArcRuntime.headerRelease`, passing a
        /// per-type `deep_walk` callback that performs the cell's
        /// teardown when the manager observes the final
        /// zero-transition. The dispatcher bumps `arc_releases_total`
        /// unconditionally; `list_release_kept_alive_total` /
        /// `list_release_freed_total` are adjusted inside this method
        /// — counting every release as "kept alive" optimistically
        /// and rolling it back to "freed" when the deep_walk callback
        /// actually fires.
        pub fn release(vec: ?*const Self) void {
            if (vec == null) return;
            const v = vec.?;
            const mut: *Self = @constCast(v);
            // Optimistically count as kept-alive; the deep_walk callback
            // rolls this back to "freed" on the zero-transition.
            if (comptime collect_arc_stats) {
                list_release_kept_alive_total += 1;
            }
            ArcRuntime.headerRelease(&mut.header, listDeepWalk);
        }

        /// Deep-walk callback invoked by the manager's `release` on
        /// the final zero-transition. Reverses the optimistic
        /// kept-alive bump in `release` and performs the cell's full
        /// teardown: deep-release of every element followed by
        /// freeing the buffer.
        fn listDeepWalk(ptr: *anyopaque) callconv(.c) void {
            const mut: *Self = @ptrCast(@alignCast(ptr));
            if (comptime collect_arc_stats) {
                list_release_kept_alive_total -= 1;
                list_release_freed_total += 1;
            }
            mut.bufferFreeDeep();
        }

        /// Inline-header dispatch hook used by the generic ARC
        /// machinery (`releaseFieldChildAny` / `releaseArcAny`).
        pub fn arcReleaseDeep(allocator: std.mem.Allocator, ptr: *const Self) void {
            _ = allocator;
            release(@as(?*const Self, ptr));
        }

        // -------------------------------------------------------------------
        // Clone helpers
        // -------------------------------------------------------------------

        /// Clone with deep-retain of element children. Used on the
        /// shared (rc>1) mutation path so the original cell stays
        /// valid while the clone takes the mutation.
        fn cloneBufferRetainingChildren(self: *const Self, new_capacity: u32) ?*Self {
            std.debug.assert(new_capacity >= self.len);
            const fresh = bufferAlloc(new_capacity, self.len) orelse return null;
            list_retaining_clone_total += 1;
            list_retaining_clone_bytes += bufferSize(new_capacity);
            const old_data = self.dataPtr();
            const new_data = fresh.dataPtr();
            for (0..self.len) |i| {
                new_data[i] = old_data[i];
                retainElement(old_data[i]);
            }
            return fresh;
        }

        /// Clone WITHOUT retaining element children. Used on the
        /// unique-owner resize path: the old buffer's elements
        /// transfer verbatim to the new buffer, and the old buffer is
        /// freed shallowly afterward (no per-element release).
        fn cloneBufferMovingChildren(self: *const Self, new_capacity: u32) ?*Self {
            std.debug.assert(new_capacity >= self.len);
            const fresh = bufferAlloc(new_capacity, self.len) orelse return null;
            const old_data = self.dataPtr();
            const new_data = fresh.dataPtr();
            for (0..self.len) |i| {
                new_data[i] = old_data[i];
            }
            return fresh;
        }

        // -------------------------------------------------------------------
        // Capacity selection
        // -------------------------------------------------------------------

        /// Pick the next power-of-two capacity that fits `target_len`.
        /// Default initial capacity is 4; larger workloads grow
        /// exponentially via doubling.
        fn pickCapacity(old_cap: u32, target_len: u32) u32 {
            var cap: u32 = if (old_cap == 0) 4 else old_cap;
            while (cap < target_len) cap *= 2;
            return cap;
        }

        // -------------------------------------------------------------------
        // Public introspection
        // -------------------------------------------------------------------

        /// Typed empty-list sentinel.
        pub fn empty() ?*const Self {
            return null;
        }

        /// Number of populated elements.
        pub fn length(vec: ?*const Self) i64 {
            const v = vec orelse return 0;
            return @intCast(v.len);
        }

        /// True when the list contains no elements. Both `null` and
        /// allocated zero-length buffers are empty.
        pub fn isEmpty(vec: ?*const Self) bool {
            const v = vec orelse return true;
            return v.len == 0;
        }

        /// Total capacity (number of element slots in the buffer).
        pub fn capacity(vec: ?*const Self) i64 {
            const v = vec orelse return 0;
            return @intCast(v.cap);
        }

        // -------------------------------------------------------------------
        // Allocation
        // -------------------------------------------------------------------

        /// Allocate a list of exactly `size` elements, each set to
        /// `init`.
        ///
        /// For ARC-managed `T`: the caller hands one +1 of `init` to
        /// the list. We need `size` durable owners (one per slot),
        /// so we retain `size - 1` additional times. The zero-element
        /// edge case requires the caller's +1 to be dropped.
        pub fn new_filled(size: i64, init: T) ?*const Self {
            if (size < 0) @panic("List.new_filled: negative size");
            const slot_count: u32 = @intCast(size);
            const fresh = bufferAlloc(slot_count, slot_count) orelse return null;
            const data = fresh.dataPtr();
            for (0..slot_count) |i| {
                data[i] = init;
            }
            // The caller's +1 covers slot 0; retain (slot_count - 1)
            // times for the remaining slots. For trivial T this loop
            // compiles to nothing.
            if (slot_count == 0) {
                releaseElement(init, std.heap.c_allocator);
            } else {
                var k: u32 = 1;
                while (k < slot_count) : (k += 1) retainElement(init);
            }
            return fresh;
        }

        /// Allocate an empty list with the given reserved capacity.
        /// The buffer is allocated but `len == 0`.
        pub fn new_empty(initial_capacity: i64) ?*const Self {
            if (initial_capacity < 0) @panic("List.new_empty: negative capacity");
            const cap_arg: u32 = @intCast(initial_capacity);
            const cap_final: u32 = if (cap_arg == 0) 4 else cap_arg;
            return bufferAlloc(cap_final, 0);
        }

        // -------------------------------------------------------------------
        // Get / set
        // -------------------------------------------------------------------

        /// Bounds-checked element read. Panics on null list or
        /// out-of-range index.
        pub fn get(vec: ?*const Self, index: i64) T {
            const v = vec orelse @panic("List.get: null list");
            const slot: u32 = @intCast(index);
            if (slot >= v.len) @panic("List.get: index out of bounds");
            const value = v.slotAtConst(slot).*;
            retainElement(value);
            return value;
        }

        /// Return the first element, or the element type's default for
        /// an empty list. The returned value is a fresh owner when `T`
        /// carries ARC-managed children.
        pub fn getHead(vec: ?*const Self) T {
            const v = vec orelse return defaultElement();
            if (v.len == 0) return defaultElement();
            const value = v.slotAtConst(0).*;
            retainElement(value);
            return value;
        }

        /// Return a freshly-owned list containing every element after
        /// the first. The source list remains valid and unchanged.
        pub fn getTail(vec: ?*const Self) ?*const Self {
            return sliceFrom(vec, 1);
        }

        /// Return a freshly-owned list containing elements starting at
        /// `start`. The source list remains valid and unchanged.
        pub fn sliceFrom(vec: ?*const Self, start: i64) ?*const Self {
            if (start < 0) @panic("List.sliceFrom: negative start");
            const v = vec orelse return null;
            const first: u32 = @intCast(start);
            if (first >= v.len) return null;
            return cloneRangeRetainingChildren(v, first, v.len - first);
        }

        /// Return the last element, or the element type's default for
        /// an empty list. The returned value is a fresh owner when `T`
        /// carries ARC-managed children.
        pub fn last(vec: ?*const Self) T {
            const v = vec orelse return defaultElement();
            if (v.len == 0) return defaultElement();
            const value = v.slotAtConst(v.len - 1).*;
            retainElement(value);
            return value;
        }

        /// Bounds-checked element write. Refcount-aware: on rc==1 the
        /// existing buffer is mutated in place and the same pointer is
        /// returned; on rc>1 the buffer is deep-retain cloned first so
        /// the original observer stays valid.
        pub fn set(vec: ?*const Self, index: i64, value: T) ?*const Self {
            const v = vec orelse @panic("List.set: null list");
            const slot: u32 = @intCast(index);
            if (slot >= v.len) @panic("List.set: index out of bounds");

            list_mut_calls_total += 1;
            if (v.header.count() == 1) {
                list_rc1_fast_path_total += 1;
                const mut: *Self = @constCast(v);
                const existing = mut.slotAt(slot).*;
                releaseElement(existing, std.heap.c_allocator);
                mut.slotAt(slot).* = value;
                return mut;
            }

            const clone = cloneBufferRetainingChildren(v, v.cap) orelse return null;
            const clone_existing = clone.slotAt(slot).*;
            releaseElement(clone_existing, std.heap.c_allocator);
            clone.slotAt(slot).* = value;
            return clone;
        }

        // -------------------------------------------------------------------
        // Push / pop / append
        // -------------------------------------------------------------------

        /// Append `value` to the end. Refcount-aware: on rc==1 the
        /// existing buffer is mutated in place (possibly resized — see
        /// note below); on rc>1 the buffer is deep-retain cloned first
        /// with sufficient capacity to hold the new element.
        ///
        /// Resize note: when the rc==1 path needs to grow capacity, we
        /// allocate a fresh buffer via `cloneBufferMovingChildren`
        /// (transferring elements verbatim with no per-element retain)
        /// and then `bufferFreeShallow` on the old buffer. The net
        /// effect on T's refcounts is zero: each element transitions
        /// from old-buffer ownership to new-buffer ownership without
        /// touching ARC counts.
        pub fn push(vec: ?*const Self, value: T) ?*const Self {
            list_mut_calls_total += 1;
            if (vec == null) {
                list_rc1_fast_path_total += 1;
                const fresh = bufferAlloc(pickCapacity(0, 1), 0) orelse return null;
                fresh.slotAtPtr(0).* = value;
                fresh.len = 1;
                return fresh;
            }
            const v = vec.?;

            if (v.header.count() == 1) {
                list_rc1_fast_path_total += 1;
                const mut: *Self = @constCast(v);
                if (mut.len < mut.cap) {
                    mut.slotAtPtr(mut.len).* = value;
                    mut.len += 1;
                    return mut;
                }
                // Need to grow. Move children to a fresh, larger
                // buffer; free the old buffer shallowly so the moved
                // children are not double-released.
                const new_cap = pickCapacity(mut.cap, mut.len + 1);
                const grown = cloneBufferMovingChildren(mut, new_cap) orelse return null;
                mut.bufferFreeShallow();
                grown.slotAtPtr(grown.len).* = value;
                grown.len += 1;
                return grown;
            }

            // Shared: deep-retain clone with sufficient capacity for
            // the appended element.
            const new_cap = pickCapacity(v.cap, v.len + 1);
            const clone = cloneBufferRetainingChildren(v, new_cap) orelse return null;
            clone.slotAtPtr(clone.len).* = value;
            clone.len += 1;
            return clone;
        }

        /// Remove the last element. Refcount-aware: on rc==1 the
        /// existing buffer is mutated in place; on rc>1 a deep-retain
        /// clone is made and pop'd. Returns the resulting list
        /// (NOT the popped value — mirrors the Roc-style `Dict.delete`
        /// in the dense Map). On an empty list this panics.
        pub fn pop(vec: ?*const Self) ?*const Self {
            const v = vec orelse @panic("List.pop: null list");
            if (v.len == 0) @panic("List.pop: empty list");

            list_mut_calls_total += 1;
            if (v.header.count() == 1) {
                list_rc1_fast_path_total += 1;
                const mut: *Self = @constCast(v);
                const removed_value = mut.slotAtPtr(mut.len - 1).*;
                releaseElement(removed_value, std.heap.c_allocator);
                mut.len -= 1;
                return mut;
            }

            const clone = cloneBufferRetainingChildren(v, v.cap) orelse return null;
            const removed_value = clone.slotAtPtr(clone.len - 1).*;
            releaseElement(removed_value, std.heap.c_allocator);
            clone.len -= 1;
            return clone;
        }

        /// Concatenate two lists. The result is logically `a ++ b`.
        /// Refcount-aware: when `rc(a) == 1` and `cap(a) >= len(a) +
        /// len(b)`, append B's elements into A's buffer in place;
        /// otherwise allocate a fresh buffer with adequate capacity
        /// (copying A's children with the appropriate retain
        /// semantics for the chosen path).
        ///
        /// `b`'s elements are deep-retained as they're copied (B
        /// retains its observers). The caller still owns the +1 on
        /// `b`; releasing `b` after the call is the caller's
        /// responsibility, mirroring `Map.merge`'s ABI.
        pub fn append(a: ?*const Self, b: ?*const Self) ?*const Self {
            if (a == null and b == null) return null;
            if (b == null) return retain(a);
            if (a == null) return cloneBufferRetainingChildren(b.?, b.?.len);
            const av = a.?;
            const bv = b.?;
            const total_len = av.len + bv.len;

            list_mut_calls_total += 1;
            if (av.header.count() == 1 and av.cap >= total_len) {
                list_rc1_fast_path_total += 1;
                const mut: *Self = @constCast(av);
                const dst_data = mut.dataPtr();
                const src_data = bv.dataPtr();
                var i: u32 = 0;
                while (i < bv.len) : (i += 1) {
                    dst_data[mut.len + i] = src_data[i];
                    retainElement(src_data[i]);
                }
                mut.len = total_len;
                return mut;
            }

            if (av.header.count() == 1) {
                list_rc1_fast_path_total += 1;
                const mut: *Self = @constCast(av);
                const same_buffer = av == bv;
                const b_len = bv.len;
                const new_cap = pickCapacity(av.cap, total_len);
                const grown = cloneBufferMovingChildren(mut, new_cap) orelse return null;
                mut.bufferFreeShallow();
                const grown_data = grown.dataPtr();
                var i: u32 = 0;
                while (i < b_len) : (i += 1) {
                    const value = if (same_buffer) grown_data[i] else bv.dataPtr()[i];
                    grown_data[grown.len + i] = value;
                    retainElement(value);
                }
                grown.len = total_len;
                return grown;
            }

            // Either A is shared (must clone) OR A's buffer is too
            // small (must grow). The unique-growth case was handled
            // above; this branch clones A/B and releases the consumed
            // A owner.
            const new_cap = pickCapacity(av.cap, total_len);
            const fresh = bufferAlloc(new_cap, total_len) orelse return null;
            const fresh_data = fresh.dataPtr();
            const a_data = av.dataPtr();
            const b_data = bv.dataPtr();
            var i: u32 = 0;
            while (i < av.len) : (i += 1) {
                fresh_data[i] = a_data[i];
                retainElement(a_data[i]);
            }
            while (i < total_len) : (i += 1) {
                fresh_data[i] = b_data[i - av.len];
                retainElement(b_data[i - av.len]);
            }
            return fresh;
        }

        /// Alias for `append`, kept for the protocol bridge and legacy
        /// Zap wrapper spelling.
        pub fn concat(a: ?*const Self, b: ?*const Self) ?*const Self {
            return append(a, b);
        }

        /// Construct `head :: tail`, returning the resulting flat
        /// buffer. `head` and `tail` are consumed.
        ///
        /// Refcount-aware fast paths:
        ///   * `tail == null` — allocate a fresh single-element
        ///     buffer; no allocation when an empty buffer is reused
        ///     downstream.
        ///   * `tail.rc == 1` and `tail.cap > tail.len` — shift
        ///     elements right by one slot and write `head` into
        ///     slot 0. No allocation, no per-element retain — the
        ///     existing buffer is reused and returned. Elements were
        ///     already owned by `tail` so the ARC counts are
        ///     unchanged.
        ///   * `tail.rc == 1` and `tail.cap == tail.len` — allocate a
        ///     larger buffer at `pickCapacity(tail.cap, tail.len + 1)`,
        ///     move elements verbatim (no retain — ownership transfers
        ///     to the new buffer), free the old buffer shallowly. This
        ///     keeps `cons` accumulators amortized O(log n) total
        ///     allocations instead of O(n) — matching the growth
        ///     pattern of `push`.
        ///   * `tail.rc > 1` — fallback to the historical
        ///     deep-retain clone: allocate a fresh buffer sized to
        ///     `tail.len + 1`, deep-retain copy every element, then
        ///     release the borrowed tail owner.
        ///
        /// The rc-aware fast paths mirror `List.push` and
        /// `Map.put`'s uniqueness fast paths. Without them, every
        /// `[head | tail]` in a tight loop would copy the entire
        /// tail even when the caller had unique ownership — a
        /// quadratic-allocation shape that pinned multi-GB of
        /// c_allocator buffers in benchmarks like k-nucleotide.
        pub fn cons(head: T, tail: ?*const Self) ?*const Self {
            list_cons_calls_total += 1;
            if (tail == null) {
                const fresh_cap = pickCapacity(0, 1);
                const fresh = bufferAlloc(fresh_cap, 1) orelse return null;
                list_cons_alloc_bytes += bufferSize(fresh_cap);
                fresh.dataPtr()[0] = head;
                return fresh;
            }
            const t = tail.?;
            if (t.header.count() == 1) {
                const mut: *Self = @constCast(t);
                if (mut.cap > mut.len) {
                    list_cons_rc1_inplace_total += 1;
                    // In-place shift: move elements right by one, then
                    // write head at slot 0. No buffer allocation.
                    const data = mut.dataPtr();
                    var i: u32 = mut.len;
                    while (i > 0) : (i -= 1) {
                        data[i] = data[i - 1];
                    }
                    data[0] = head;
                    mut.len += 1;
                    return mut;
                }
                list_cons_rc1_grow_total += 1;
                // Need to grow. Move children to a fresh larger
                // buffer (no per-element retain — children transfer
                // verbatim), shift them into slot 1.. and put head at
                // slot 0, then free the old buffer shallowly.
                const new_cap = pickCapacity(mut.cap, mut.len + 1);
                const grown = bufferAlloc(new_cap, mut.len + 1) orelse return null;
                list_cons_alloc_bytes += bufferSize(new_cap);
                const old_data = mut.dataPtr();
                const new_data = grown.dataPtr();
                new_data[0] = head;
                var i: u32 = 0;
                while (i < mut.len) : (i += 1) {
                    new_data[i + 1] = old_data[i];
                }
                mut.bufferFreeShallow();
                return grown;
            }
            list_cons_shared_total += 1;
            // Shared: deep-retain clone with an exact-fit capacity.
            // Each element gets a fresh retain since the source map
            // stays valid.
            const tail_len: u32 = t.len;
            const fresh_cap = pickCapacity(0, tail_len + 1);
            const fresh = bufferAlloc(fresh_cap, tail_len + 1) orelse return null;
            list_cons_alloc_bytes += bufferSize(fresh_cap);
            const data = fresh.dataPtr();
            data[0] = head;
            const tail_data = t.dataPtr();
            var i: u32 = 0;
            while (i < tail_len) : (i += 1) {
                data[i + 1] = tail_data[i];
                retainElement(tail_data[i]);
            }
            release(tail);
            return fresh;
        }

        /// Return a new list with element order reversed.
        pub fn reverse(vec: ?*const Self) ?*const Self {
            const v = vec orelse return null;
            if (v.len == 0) return null;
            const fresh = bufferAlloc(v.len, v.len) orelse return null;
            const source = v.dataPtr();
            const dest = fresh.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                const value = source[v.len - 1 - i];
                dest[i] = value;
                retainElement(value);
            }
            return fresh;
        }

        /// Return the first `count` elements as a fresh list.
        pub fn take(vec: ?*const Self, count: i64) ?*const Self {
            if (count <= 0) return null;
            const v = vec orelse return null;
            const requested: u32 = @intCast(count);
            const take_len = @min(requested, v.len);
            if (take_len == 0) return null;
            return cloneRangeRetainingChildren(v, 0, take_len);
        }

        /// Return the list after dropping the first `count` elements.
        pub fn drop(vec: ?*const Self, count: i64) ?*const Self {
            const v = vec orelse return null;
            if (count <= 0) return cloneRangeRetainingChildren(v, 0, v.len);
            const requested: u32 = @intCast(count);
            if (requested >= v.len) return null;
            return cloneRangeRetainingChildren(v, requested, v.len - requested);
        }

        /// True when any element equals `value`.
        pub fn contains(vec: ?*const Self, value: T) bool {
            const v = vec orelse return false;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                if (elementsEqual(data[i], value)) return true;
            }
            return false;
        }

        /// Return a new list with duplicate elements removed,
        /// preserving first-occurrence order.
        pub fn uniq(vec: ?*const Self) ?*const Self {
            const v = vec orelse return null;
            var result: ?*const Self = null;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                if (!contains(result, data[i])) {
                    retainElement(data[i]);
                    result = push(result, data[i]);
                }
            }
            return result;
        }

        /// Iterator protocol: returns `{tag, value, next_state}` where
        /// tag is `:cont` for non-empty and `:done` for empty.
        pub fn next(vec: ?*const Self) std.meta.Tuple(&.{ u32, T, ?*const Self }) {
            const v = vec orelse return .{ ATOM_DONE, defaultElement(), null };
            if (v.len == 0) return .{ ATOM_DONE, defaultElement(), null };
            const head = v.slotAtConst(0).*;
            retainElement(head);
            const tail = if (v.len > 1) cloneRangeRetainingChildren(v, 1, v.len - 1) else null;
            return .{ ATOM_CONT, head, tail };
        }

        // Higher-order helpers used by protocol bridges.
        pub fn mapFn(vec: ?*const Self, callback: anytype) ?*const Self {
            const v = vec orelse return null;
            var result: ?*const Self = null;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                result = push(result, call1WithOwnedElement(callback, data[i]));
            }
            return result;
        }

        pub fn filterFn(vec: ?*const Self, predicate: anytype) ?*const Self {
            const v = vec orelse return null;
            var result: ?*const Self = null;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                if (call1WithOwnedElement(predicate, data[i])) {
                    retainElement(data[i]);
                    result = push(result, data[i]);
                }
            }
            return result;
        }

        pub fn rejectFn(vec: ?*const Self, predicate: anytype) ?*const Self {
            const v = vec orelse return null;
            var result: ?*const Self = null;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                if (!call1WithOwnedElement(predicate, data[i])) {
                    retainElement(data[i]);
                    result = push(result, data[i]);
                }
            }
            return result;
        }

        pub fn enumReduceSimple(vec: ?*const Self, initial: T, callback: anytype) T {
            const v = vec orelse return initial;
            var acc: T = initial;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                acc = call2WithOwnedElement(callback, acc, data[i]);
            }
            return acc;
        }

        pub fn eachFn(vec: ?*const Self, callback: anytype) ?*const Self {
            const v = vec orelse return null;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                const callback_result = call1WithOwnedElement(callback, data[i]);
                releaseElementShape(@TypeOf(callback_result), callback_result, std.heap.c_allocator);
            }
            return vec;
        }

        pub fn findFn(vec: ?*const Self, default: T, predicate: anytype) T {
            const v = vec orelse return default;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                if (call1WithOwnedElement(predicate, data[i])) {
                    retainElement(data[i]);
                    return data[i];
                }
            }
            return default;
        }

        pub fn anyFn(vec: ?*const Self, predicate: anytype) bool {
            const v = vec orelse return false;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                if (call1WithOwnedElement(predicate, data[i])) return true;
            }
            return false;
        }

        pub fn allFn(vec: ?*const Self, predicate: anytype) bool {
            const v = vec orelse return true;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                if (!call1WithOwnedElement(predicate, data[i])) return false;
            }
            return true;
        }

        pub fn countFn(vec: ?*const Self, predicate: anytype) i64 {
            const v = vec orelse return 0;
            var count: i64 = 0;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                if (call1WithOwnedElement(predicate, data[i])) count += 1;
            }
            return count;
        }

        pub fn sortFn(vec: ?*const Self, comparator: anytype) ?*const Self {
            const v = vec orelse return null;
            if (v.len <= 1) return cloneRangeRetainingChildren(v, 0, v.len);
            const len: usize = @intCast(v.len);
            const arr = bumpAllocSlice(T, len);
            if (arr.len == 0) return null;
            const data = v.dataPtr();
            for (0..len) |i| arr[i] = data[i];
            const Comparator = @TypeOf(comparator);
            const ComparatorStorage = if (@typeInfo(Comparator) == .@"fn") *const Comparator else Comparator;
            const comparator_storage: ComparatorStorage = if (@typeInfo(Comparator) == .@"fn") &comparator else comparator;
            const Ctx = struct {
                cmp: ComparatorStorage,
                fn lessThan(ctx: @This(), a: T, b: T) bool {
                    return Self.call2WithOwnedElements(ctx.cmp, a, b);
                }
            };
            std.sort.pdq(T, arr, Ctx{ .cmp = comparator_storage }, Ctx.lessThan);
            var result: ?*const Self = null;
            for (arr) |value| {
                retainElement(value);
                result = push(result, value);
            }
            return result;
        }

        pub fn flatMapFn(vec: ?*const Self, callback: anytype) ?*const Self {
            const v = vec orelse return null;
            var result: ?*const Self = null;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) {
                const inner = call1WithOwnedElement(callback, data[i]);
                result = append(result, inner);
                release(inner);
            }
            return result;
        }

        pub fn sum(vec: ?*const Self) T {
            switch (comptime @typeInfo(T)) {
                .int, .float => {},
                else => @compileError("sum requires numeric element type"),
            }
            const v = vec orelse return 0;
            const data = v.dataPtr();
            return switch (comptime @typeInfo(T)) {
                .int => listSumIntegerSimd(T, data, v.len),
                .float => listSumScalar(T, data, v.len),
                else => unreachable,
            };
        }

        pub fn product(vec: ?*const Self) T {
            if (comptime @typeInfo(T) != .int) @compileError("product requires integer element type");
            const v = vec orelse return 1;
            var total: T = 1;
            const data = v.dataPtr();
            var i: u32 = 0;
            while (i < v.len) : (i += 1) total *= data[i];
            return total;
        }

        pub fn maxVal(vec: ?*const Self) T {
            if (comptime @typeInfo(T) != .int) @compileError("maxVal requires integer element type");
            const v = vec orelse return 0;
            if (v.len == 0) return 0;
            const data = v.dataPtr();
            var result = data[0];
            var i: u32 = 1;
            while (i < v.len) : (i += 1) {
                if (data[i] > result) result = data[i];
            }
            return result;
        }

        pub fn minVal(vec: ?*const Self) T {
            if (comptime @typeInfo(T) != .int) @compileError("minVal requires integer element type");
            const v = vec orelse return 0;
            if (v.len == 0) return 0;
            const data = v.dataPtr();
            var result = data[0];
            var i: u32 = 1;
            while (i < v.len) : (i += 1) {
                if (data[i] < result) result = data[i];
            }
            return result;
        }

        // -------------------------------------------------------------------
        // uniqueness unchecked-mutation variants
        //
        // These functions mutate the receiver in place WITHOUT loading
        // `header.count()`. The caller (codegen) must have proven via
        // uniqueness that the receiver is statically uniquely owned (refcount
        // == 1 by construction).
        //
        // Safety contract:
        //   * `vec` must be non-null.
        //   * `vec.header.ref_count` must be exactly 1.
        //
        // Violating either condition is undefined behavior (UB). The
        // uniqueness verifier in `arc_verifier.zig` enforces both at every
        // call site by construction. Tests may invoke these directly
        // for behavioural validation; production callers must always
        // route through uniqueness.
        //
        // Refcount semantics: the receiver enters with rc=1 and
        // returns with rc=1. The unchecked variants never bump or
        // decrement the cell's refcount; they only manipulate the
        // populated entries / element slots. On a resize (push that
        // exceeds capacity, append that exceeds capacity), the
        // function allocates a fresh buffer with rc=1, transfers
        // children verbatim with no per-element retain, and frees
        // the old buffer shallowly — the caller's +1 transfers from
        // the old buffer to the new one without any refcount
        // bookkeeping.
        // -------------------------------------------------------------------

        /// Like `set`, but skips the rc==1 check. Caller must have
        /// proven uniqueness via uniqueness. See safety contract above.
        pub fn set_owned_unchecked(vec: ?*const Self, index: i64, value: T) ?*const Self {
            const v = vec orelse @panic("List.set_owned_unchecked: null list");
            const slot: u32 = @intCast(index);
            if (slot >= v.len) @panic("List.set_owned_unchecked: index out of bounds");

            list_mut_calls_total += 1;
            list_unchecked_total += 1;
            const mut: *Self = @constCast(v);
            const existing = mut.slotAt(slot).*;
            releaseElement(existing, std.heap.c_allocator);
            mut.slotAt(slot).* = value;
            return mut;
        }

        /// Like `getHead`, but intended for uniqueness-proven list
        /// destructuring sites. This still returns a fresh owner for
        /// ARC-shaped elements; the matching `tail_owned_unchecked` /
        /// `slice_owned_unchecked` call can then release the skipped
        /// prefix while the extracted head remains valid.
        pub fn head_owned_unchecked(vec: ?*const Self) T {
            const v = vec orelse return defaultElement();
            if (v.len == 0) return defaultElement();
            const value = v.slotAtConst(0).*;
            retainElement(value);
            return value;
        }

        /// Like `getTail`, but skips the rc==1 check and consumes the
        /// receiver's unique ownership. The suffix is shifted into the
        /// existing buffer; skipped elements are released because their
        /// list-owned references leave the buffer.
        pub fn tail_owned_unchecked(vec: ?*const Self) ?*const Self {
            return slice_owned_unchecked(vec, 1);
        }

        /// Like `sliceFrom`, but skips the rc==1 check and consumes the
        /// receiver's unique ownership. A non-empty suffix reuses the
        /// same allocation by moving elements down; an empty suffix
        /// releases all remaining elements, frees the buffer, and
        /// returns the null empty-list sentinel.
        pub fn slice_owned_unchecked(vec: ?*const Self, start: i64) ?*const Self {
            if (start < 0) @panic("List.slice_owned_unchecked: negative start");
            const v = vec orelse return null;

            list_mut_calls_total += 1;
            list_unchecked_total += 1;

            const first: u32 = @intCast(start);
            const mut: *Self = @constCast(v);
            const data = mut.dataPtr();

            if (first >= mut.len) {
                var index: u32 = 0;
                while (index < mut.len) : (index += 1) {
                    releaseElement(data[index], std.heap.c_allocator);
                }
                mut.len = 0;
                mut.bufferFreeShallow();
                return null;
            }

            if (first == 0) return mut;

            var dropped_index: u32 = 0;
            while (dropped_index < first) : (dropped_index += 1) {
                releaseElement(data[dropped_index], std.heap.c_allocator);
            }

            const next_len = mut.len - first;
            var move_index: u32 = 0;
            while (move_index < next_len) : (move_index += 1) {
                data[move_index] = data[first + move_index];
            }
            mut.len = next_len;
            return mut;
        }

        /// Like `push`, but skips the rc==1 check. Caller must have
        /// proven uniqueness via uniqueness. The buffer may be reallocated to
        /// grow capacity — that is still in-place ownership transfer
        /// (the old buffer's children move to the new buffer; old
        /// buffer is freed shallowly). See safety contract above.
        pub fn push_owned_unchecked(vec: ?*const Self, value: T) ?*const Self {
            list_mut_calls_total += 1;
            list_unchecked_total += 1;
            if (vec == null) {
                const fresh = bufferAlloc(pickCapacity(0, 1), 0) orelse return null;
                fresh.slotAtPtr(0).* = value;
                fresh.len = 1;
                return fresh;
            }
            const v = vec.?;
            const mut: *Self = @constCast(v);
            if (mut.len < mut.cap) {
                mut.slotAtPtr(mut.len).* = value;
                mut.len += 1;
                return mut;
            }
            // Grow in place: the receiver's +1 transfers from the
            // old buffer to the resized one. No element retains
            // because the moved-children path keeps each element's
            // refcount unchanged.
            const new_cap = pickCapacity(mut.cap, mut.len + 1);
            const grown = cloneBufferMovingChildren(mut, new_cap) orelse return null;
            mut.bufferFreeShallow();
            grown.slotAtPtr(grown.len).* = value;
            grown.len += 1;
            return grown;
        }

        /// Like `pop`, but skips the rc==1 check. Caller must have
        /// proven uniqueness via uniqueness. Panics on empty list. See
        /// safety contract above.
        pub fn pop_owned_unchecked(vec: ?*const Self) ?*const Self {
            const v = vec orelse @panic("List.pop_owned_unchecked: null list");
            if (v.len == 0) @panic("List.pop_owned_unchecked: empty list");

            list_mut_calls_total += 1;
            list_unchecked_total += 1;
            const mut: *Self = @constCast(v);
            const removed_value = mut.slotAtPtr(mut.len - 1).*;
            releaseElement(removed_value, std.heap.c_allocator);
            mut.len -= 1;
            return mut;
        }

        /// Like `append`, but skips the rc==1 check on `a`. Caller
        /// must have proven uniqueness of `a` via uniqueness. `b` is BORROWED
        /// — its refcount is not consulted; its elements are
        /// deep-retained as they're copied (B's observers retain
        /// their references). See safety contract above.
        pub fn append_owned_unchecked(a: ?*const Self, b: ?*const Self) ?*const Self {
            if (a == null and b == null) return null;
            if (b == null) {
                // The caller proved uniqueness on `a`; we keep the
                // same buffer (caller's +1 stays in place) — symmetric
                // with the checked `append`'s `retain(a)` shape but
                // without bumping the refcount.
                return a;
            }
            if (a == null) {
                // No `a` to mutate; produce a fresh deep-retained
                // copy of `b`. The result has rc=1 by construction.
                return cloneBufferRetainingChildren(b.?, b.?.len);
            }
            const av = a.?;
            const bv = b.?;
            const total_len = av.len + bv.len;

            list_mut_calls_total += 1;
            list_unchecked_total += 1;
            const mut: *Self = @constCast(av);

            if (mut.cap >= total_len) {
                const dst_data = mut.dataPtr();
                const src_data = bv.dataPtr();
                var i: u32 = 0;
                while (i < bv.len) : (i += 1) {
                    dst_data[mut.len + i] = src_data[i];
                    retainElement(src_data[i]);
                }
                mut.len = total_len;
                return mut;
            }

            // Need to grow the buffer — still in-place ownership
            // transfer (old A's children move to fresh; old A is
            // freed shallowly). B's elements are deep-retained as
            // they're copied (B's observers retain).
            const new_cap = pickCapacity(av.cap, total_len);
            const grown = cloneBufferMovingChildren(mut, new_cap) orelse return null;
            const same_buffer = av == bv;
            const b_len = bv.len;
            mut.bufferFreeShallow();
            const grown_data = grown.dataPtr();
            var i: u32 = 0;
            while (i < b_len) : (i += 1) {
                const value = if (same_buffer) grown_data[i] else bv.dataPtr()[i];
                grown_data[grown.len + i] = value;
                retainElement(value);
            }
            grown.len = total_len;
            return grown;
        }

        // -------------------------------------------------------------------
        // Internal slot accessors (allow writes past `len` for push)
        // -------------------------------------------------------------------

        inline fn slotAtPtr(self: *Self, idx: u32) *T {
            std.debug.assert(idx < self.cap);
            return &self.dataPtr()[idx];
        }

        fn cloneRangeRetainingChildren(self: *const Self, start: u32, count: u32) ?*const Self {
            if (count == 0) return null;
            std.debug.assert(start <= self.len);
            std.debug.assert(start + count <= self.len);
            const fresh = bufferAlloc(count, count) orelse return null;
            const source = self.dataPtr();
            const dest = fresh.dataPtr();
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const value = source[start + i];
                dest[i] = value;
                retainElement(value);
            }
            return fresh;
        }

        fn defaultElement() T {
            return defaultElementOf(T);
        }

        fn elementsEqual(left: T, right: T) bool {
            if (T == Term) return Term.eql(left, right);
            if (T == []const u8) return std.mem.eql(u8, left, right);
            return std.mem.eql(u8, std.mem.asBytes(&left), std.mem.asBytes(&right));
        }

        // -------------------------------------------------------------------
        // ARC element walkers
        // -------------------------------------------------------------------

        inline fn releaseElement(value: T, allocator: std.mem.Allocator) void {
            releaseElementShape(T, value, allocator);
        }

        inline fn retainElement(value: T) void {
            retainElementShape(T, value);
        }

        inline fn call1WithOwnedElement(callback: anytype, value: T) CallableReturn(@TypeOf(callback)) {
            retainElement(value);
            return call1(callback, value);
        }

        inline fn call2WithOwnedElement(callback: anytype, arg0: anytype, value: T) CallableReturn(@TypeOf(callback)) {
            retainElement(value);
            return call2(callback, arg0, value);
        }

        inline fn call2WithOwnedElements(callback: anytype, left: T, right: T) CallableReturn(@TypeOf(callback)) {
            retainElement(left);
            retainElement(right);
            return call2(callback, left, right);
        }

        fn releaseElementShape(comptime ElemT: type, value: ElemT, allocator: std.mem.Allocator) void {
            switch (@typeInfo(ElemT)) {
                .optional => |opt| {
                    if (value) |inner| releaseElementShape(opt.child, inner, allocator);
                },
                .pointer => |p| {
                    if (p.size == .one) {
                        ArcRuntime.releaseArcAny(p.child, allocator, @constCast(value));
                    }
                },
                .@"struct" => {
                    ArcRuntime.releaseChildrenAny(ElemT, allocator, value);
                },
                else => {},
            }
        }

        fn retainElementShape(comptime ElemT: type, value: ElemT) void {
            switch (@typeInfo(ElemT)) {
                .optional => |opt| {
                    if (value) |inner| retainElementShape(opt.child, inner);
                },
                .pointer => |p| {
                    if (p.size == .one) {
                        ArcRuntime.retainAnyPersistent(@as(*const p.child, @constCast(value)));
                    }
                },
                .@"struct" => {
                    ArcRuntime.retainChildrenAny(ElemT, value);
                },
                else => {},
            }
        }
    };
}

// ============================================================
// Atom — Interned atom values (spec §5.6)
// ============================================================

pub const Atom = struct {
    id: u32,

    pub const nil_id: u32 = 0;
    pub const true_id: u32 = 1;
    pub const false_id: u32 = 2;
    pub const ok_id: u32 = 3;
    pub const error_id: u32 = 4;

    pub const nil: Atom = .{ .id = nil_id };
    pub const @"true": Atom = .{ .id = true_id };
    pub const @"false": Atom = .{ .id = false_id };
    pub const ok: Atom = .{ .id = ok_id };
    pub const @"error": Atom = .{ .id = error_id };

    pub fn eql(a: Atom, b: Atom) bool {
        return a.id == b.id;
    }

    pub fn to_string(id: anytype) []const u8 {
        const T = @TypeOf(id);
        if (T == u32) return atomToString(id);
        if (@typeInfo(T) == .int) return atomToString(@intCast(id));
        return "<not_an_atom>";
    }
};

pub const AtomTable = struct {
    allocator: std.mem.Allocator,
    strings: std.ArrayList([]const u8),
    lookup: std.StringHashMap(u32),

    pub fn init(allocator: std.mem.Allocator) AtomTable {
        var table = AtomTable{
            .allocator = allocator,
            .strings = .empty,
            .lookup = std.StringHashMap(u32).init(allocator),
        };
        // Register well-known atoms
        const builtins = [_][]const u8{ "nil", "true", "false", "ok", "error", "cont", "halt", "done" };
        for (builtins) |name| {
            table.strings.append(allocator, name) catch {};
            table.lookup.put(name, @intCast(table.strings.items.len - 1)) catch {};
        }
        return table;
    }

    pub fn deinit(self: *AtomTable) void {
        self.strings.deinit(self.allocator);
        self.lookup.deinit();
    }

    pub fn intern(self: *AtomTable, name: []const u8) !Atom {
        if (self.lookup.get(name)) |id| {
            return .{ .id = id };
        }
        const id: u32 = @intCast(self.strings.items.len);
        const duped = try self.allocator.dupe(u8, name);
        try self.strings.append(self.allocator, duped);
        try self.lookup.put(duped, id);
        return .{ .id = id };
    }

    pub fn getName(self: *const AtomTable, atom: Atom) []const u8 {
        if (atom.id < self.strings.items.len) {
            return self.strings.items[atom.id];
        }
        return "<unknown_atom>";
    }
};

// ============================================================
// Global Atom Table — process-wide interned atom registry
// ============================================================

// Simple atom table using fixed-size arrays to avoid std.HashMap/ArrayList
// which require operations not yet implemented in the Zig self-hosted backend.
const MAX_ATOMS = 256;
const MAX_ATOM_NAME_LEN = 64;

var atom_names: [MAX_ATOMS][MAX_ATOM_NAME_LEN]u8 = undefined;
var atom_lengths: [MAX_ATOMS]u32 = [_]u32{0} ** MAX_ATOMS;
var atom_count: u32 = 0;
var atom_table_initialized: bool = false;

fn initAtomTable() void {
    if (atom_table_initialized) return;
    // Register well-known atoms
    const builtins = [_][]const u8{ "nil", "true", "false", "ok", "error", "cont", "halt", "done" };
    for (builtins) |name| {
        const id = atom_count;
        const len: u32 = @intCast(name.len);
        @memcpy(atom_names[id][0..len], name);
        atom_lengths[id] = len;
        atom_count += 1;
    }
    atom_table_initialized = true;
}

/// Intern a string as an atom. Returns the atom's u32 ID.
pub fn atomIntern(name: [*]const u8, len: u32) u32 {
    initAtomTable();
    const name_slice = name[0..len];
    // Search existing atoms
    var i: u32 = 0;
    while (i < atom_count) : (i += 1) {
        if (atom_lengths[i] == len) {
            if (std.mem.eql(u8, atom_names[i][0..len], name_slice)) {
                return i;
            }
        }
    }
    // New atom
    if (atom_count >= MAX_ATOMS) return 0;
    const id = atom_count;
    @memcpy(atom_names[id][0..len], name_slice);
    atom_lengths[id] = len;
    atom_count += 1;
    return id;
}

/// Get the string name of an atom by its u32 ID.
pub fn atomToString(id: u32) []const u8 {
    initAtomTable();
    if (id < atom_count) {
        return atom_names[id][0..atom_lengths[id]];
    }
    return "<unknown_atom>";
}

/// Compare two atom IDs for equality.
pub fn atomEq(a: u32, b: u32) bool {
    return a == b;
}

// ============================================================
// Builder Runtime — entry point plumbing for build.zap builders
// ============================================================

pub const BuilderRuntime = struct {
    /// Construct Zap.Env from getArgv().
    /// argv[0] = binary, argv[1] = target, argv[2] = os, argv[3] = arch
    pub fn buildEnvFromArgv() struct { target: u32, os: u32, arch: u32 } {
        const argv = getArgv();
        return .{
            .target = if (argv.len > 1) atomIntern(argv[1], @intCast(std.mem.len(argv[1]))) else 0,
            .os = if (argv.len > 2) atomIntern(argv[2], @intCast(std.mem.len(argv[2]))) else 0,
            .arch = if (argv.len > 3) atomIntern(argv[3], @intCast(std.mem.len(argv[3]))) else 0,
        };
    }

    /// Serialize a manifest struct to stdout as key=value lines.
    pub fn serializeManifest(manifest: anytype) void {
        const T = @TypeOf(manifest);
        const info = @typeInfo(T);
        if (info != .@"struct") return; // void or non-struct — nothing to serialize
        inline for (info.@"struct".fields) |field| {
            const value = @field(manifest, field.name);
            const FT = @TypeOf(value);
            if (FT == []const u8) {
                stdoutPrint("{s}={s}\n", .{ field.name, value });
            } else if (FT == u32) {
                stdoutPrint("{s}={s}\n", .{ field.name, atomToString(value) });
            } else if (@typeInfo(FT) == .int) {
                stdoutPrint("{s}={d}\n", .{ field.name, value });
            } else if (FT == bool) {
                stdoutPrint("{s}={}\n", .{ field.name, value });
            }
        }
    }
};

// ============================================================
// Closure — Fat pointer for function values (spec §20.2, §31.3)
// ============================================================

pub fn Closure(comptime Args: type, comptime Ret: type) type {
    return struct {
        const Self = @This();

        call_fn: *const fn (*anyopaque, Args) Ret,
        env: *anyopaque,

        pub fn invoke(self: Self, args: Args) Ret {
            return self.call_fn(self.env, args);
        }
    };
}

/// Type-erased closure for dynamic dispatch
pub const DynClosure = struct {
    call_fn: *const anyopaque,
    env: ?*anyopaque,
    env_release: ?*const fn (*anyopaque) void,

    pub fn release(self: DynClosure) void {
        if (self.env_release) |rel| {
            if (self.env) |e| {
                rel(e);
            }
        }
    }
};

pub fn invokeDynClosure(comptime Ret: type, closure: DynClosure, args: anytype) Ret {
    const Fn = *const fn (?*anyopaque, @TypeOf(args)) Ret;
    const fn_ptr: Fn = @ptrCast(@alignCast(closure.call_fn));
    return fn_ptr(closure.env, args);
}

const testing = std.testing;

test "ArcRuntime.resetAny returns token for unique value" {
    const allocator = testing.allocator;
    const ptr = ArcRuntime.allocAny(i64, allocator, 42);
    const token = ArcRuntime.resetAny(allocator, ptr);
    try testing.expect(token != null);
    const reused = ArcRuntime.reuseAllocByType(i64, allocator, token);
    reused.* = 7;
    try testing.expectEqual(@as(i64, 7), reused.*);
    ArcRuntime.releaseArcAny(i64, allocator, reused);
}

test "ArcRuntime.resetAny releases shared value and yields null token" {
    const allocator = testing.allocator;
    const ptr = ArcRuntime.allocAny(i64, allocator, 10);
    ArcRuntime.retainAny(ptr);
    const token = ArcRuntime.resetAny(allocator, ptr);
    try testing.expect(token == null);
    ArcRuntime.releaseAny(allocator, ptr);
}

test "String.compare orders bytes lexicographically" {
    try testing.expectEqual(@as(i64, 0), String.compare("abc", "abc"));
    try testing.expectEqual(@as(i64, -1), String.compare("abc", "abd"));
    try testing.expectEqual(@as(i64, 1), String.compare("abd", "abc"));
    // shorter string compares less than its prefix-equal longer counterpart
    try testing.expectEqual(@as(i64, -1), String.compare("ab", "abc"));
    try testing.expectEqual(@as(i64, 1), String.compare("abc", "ab"));
    // empty boundary
    try testing.expectEqual(@as(i64, 0), String.compare("", ""));
    try testing.expectEqual(@as(i64, -1), String.compare("", "x"));
    try testing.expectEqual(@as(i64, 1), String.compare("x", ""));
}

// ============================================================
// String — String utilities
// ============================================================

/// Interned 256-byte table for single-byte string returns. Indexed by
/// the byte value, each `byte_intern_table[b..b+1]` is a stable
/// `[]const u8` slice of length 1 holding the byte `b`. Used by
/// `String.byte_at`, `String.from_byte`, and `String.next` to avoid
/// allocating a fresh 1-byte slice through `bumpAlloc` on every call
/// — a load-bearing optimization for benchmarks that walk a string
/// byte-by-byte (e.g., k-nucleotide reads each base of a ~250 KB
/// FASTA sequence 46×, producing ~11.5M would-be arena allocations
/// that pin pages until process exit on macOS where `mremap` is
/// absent and the arena's `realloc` orphans nodes instead of growing
/// them).
///
/// Lives in `.rodata` (constant initializer evaluated at compile
/// time), so it costs zero startup work and has a process-lifetime
/// lifetime — slices into it are safe to return from any helper
/// because the table itself never moves or expires.
const byte_intern_table: [256]u8 = init: {
    var table: [256]u8 = undefined;
    var b: u32 = 0;
    while (b < 256) : (b += 1) {
        table[b] = @intCast(b);
    }
    break :init table;
};

pub const String = struct {
    /// Convert a string to an atom, creating it if it doesn't exist.
    pub fn to_atom(name: []const u8) u32 {
        return atomIntern(name.ptr, @intCast(name.len));
    }

    /// Convert a string to an existing atom. Returns null (0xFFFFFFFF)
    /// if the atom has not been previously interned.
    pub fn to_existing_atom(name: []const u8) u32 {
        initAtomTable();
        var i: u32 = 0;
        while (i < atom_count) : (i += 1) {
            if (atom_lengths[i] == name.len) {
                if (std.mem.eql(u8, atom_names[i][0..name.len], name)) {
                    return i;
                }
            }
        }
        return 0xFFFFFFFF;
    }

    /// Concatenate two strings into an allocation backed by the runtime
    /// arena. Zap-emitted code calls this directly because Zap has no
    /// notion of allocators at the call site.
    ///
    /// Fast path: if `a` is the most-recent arena allocation, ask the
    /// arena to extend it in place (`Allocator.resize`). On success we
    /// only allocate / copy `b.len` bytes — the `a` prefix already
    /// lives at the right address. This collapses tail-recursive
    /// `acc <> ch` accumulator patterns (e.g. k-nucleotide's
    /// `clean_line`, which calls `concat(acc, single_byte)` once per
    /// FASTA sequence byte) from O(n²) cumulative arena pressure to
    /// O(n). Without this, a ~60-byte cleaned line allocates
    /// 1+2+3+…+60 ≈ 1830 bytes through the arena's geometric-doubling
    /// growth, and across ~37 k lines the arena's node list ends up
    /// pinning the largest doubled nodes (~33 MB on macOS, where
    /// `page_allocator` cannot remap and old nodes never reclaim).
    ///
    /// Semantics are preserved: the returned slice has length
    /// `a.len + b.len`. Existing observers of `a` still see the original
    /// `a.len` bytes — `resize` only extends the buffer, it does not
    /// move it, and the first `a.len` bytes are unchanged. The new
    /// slice's `[a.len .. a.len + b.len]` tail is written from `b`,
    /// matching the non-fast-path behaviour byte-for-byte.
    ///
    /// Soundness conditions for the in-place extend:
    ///   1. `a.ptr + a.len` is exactly at the arena's bump cursor.
    ///      `ArenaAllocator.resize` checks this internally
    ///      (`cur_buf.ptr + state.end_index == buf.ptr + buf.len`) and
    ///      returns `false` if not, so we fall back to the copy path.
    ///   2. `a` is not aliased — no other reference exists. Zap's
    ///      purely-functional semantics + uniqueness analysis enforce
    ///      this at the language level: in `acc = acc <> next`, the
    ///      rebinding consumes the previous binding, and uniqueness
    ///      analysis would have promoted to consume-mode if any
    ///      aliased read existed.
    ///   3. The extended bytes are appended, not modifying any prior
    ///      content. The `@memcpy` below only writes
    ///      `extended[a.len..a.len + b.len]`; existing pointers into
    ///      `a` see unchanged data.
    ///
    /// Aliasing of `b` with `a`'s buffer (e.g. `concat(s, s.slice(0,3))`)
    /// is also safe: the destination region `result[a.len ..]` lies
    /// strictly past `a`'s original end, so `b`'s source bytes are read
    /// from disjoint memory — `@memcpy`'s non-overlap precondition is
    /// satisfied.
    pub fn concat(a: []const u8, b: []const u8) []const u8 {
        if (b.len == 0) return a;
        if (a.len > 0 and tryArenaExtend(a, a.len + b.len)) {
            recordBump(.string_concat, b.len);
            const extended = @as([*]u8, @constCast(a.ptr))[0 .. a.len + b.len];
            @memcpy(extended[a.len..], b);
            return extended;
        }
        const result = bumpAllocAt(.string_concat, a.len + b.len);
        if (result.len == 0) return a; // fallback: return first string
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return result;
    }

    pub fn length(s: []const u8) i64 {
        return @intCast(s.len);
    }

    pub fn slice(s: []const u8, start: i64, end: i64) []const u8 {
        const safe_start: usize = if (start >= 0) @intCast(start) else 0;
        const safe_end: usize = if (end >= 0) @intCast(end) else 0;
        const s_end = @min(safe_end, s.len);
        const s_start = @min(safe_start, s_end);
        return s[s_start..s_end];
    }

    pub fn contains(haystack: []const u8, needle: []const u8) bool {
        return std.mem.find(u8, haystack, needle) != null;
    }

    pub fn startsWith(s: []const u8, prefix: []const u8) bool {
        return std.mem.startsWith(u8, s, prefix);
    }

    pub fn endsWith(s: []const u8, suffix: []const u8) bool {
        return std.mem.endsWith(u8, s, suffix);
    }

    pub fn trim(s: []const u8) []const u8 {
        return std.mem.trim(u8, s, " \t\n\r");
    }

    /// Get byte at index as a single-character string.
    pub fn byte_at(s: []const u8, index: i64) []const u8 {
        const i: usize = if (index >= 0) @intCast(index) else return "";
        if (i >= s.len) return "";
        // Return a slice into the process-lifetime interned table so
        // walking a string byte-by-byte does not pin one bump-arena
        // page per byte. The slice is byte-identical to a fresh
        // `bumpAlloc(1)` result — same content, same length — but
        // shared across all `byte_at` invocations for the same byte
        // value.
        const b = s[i];
        return byte_intern_table[b .. b + 1];
    }

    /// Construct a one-byte string from an integer 0..255. The inverse
    /// of `byte_at`. Higher bits of the input are masked off, so the
    /// result is always exactly one byte and never panics on out-of-
    /// range input. Lets Zap code emit raw binary (e.g., PBM image
    /// data) without needing a Zig primitive at the call site.
    pub fn from_byte(byte: i64) []const u8 {
        const b: u8 = @intCast(@as(u64, @bitCast(byte)) & 0xFF);
        return byte_intern_table[b .. b + 1];
    }

    /// Lexicographic byte-wise comparison. Returns a negative integer
    /// when `left` precedes `right`, zero when they are byte-identical,
    /// and a positive integer when `left` follows `right`. Equivalent
    /// in shape to C's `strcmp` and OCaml's `String.compare`. Useful
    /// as a comparator for `Enum.sort` over `String` keys when the
    /// protocol-based `<=` is too generic for the call-site to
    /// resolve cleanly.
    pub fn compare(left: []const u8, right: []const u8) i64 {
        return switch (std.mem.order(u8, left, right)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    /// Iterator protocol for strings. The slice itself is the iteration
    /// state — each call returns the first byte (as a single-character
    /// string) and the remaining slice. This lets `for ch <- "hello"`
    /// dispatch through `Enumerable.next/1` like every other container.
    ///
    /// Returns a slice into the process-lifetime interned table for
    /// the head byte (see `byte_intern_table`) so iterators don't
    /// pin one bump-arena page per character.
    pub fn next(s: []const u8) struct { u32, []const u8, []const u8 } {
        if (s.len == 0) return .{ ATOM_DONE, "", s };
        const b = s[0];
        return .{ ATOM_CONT, byte_intern_table[b .. b + 1], s[1..] };
    }

    pub fn upcase(s: []const u8) []const u8 {
        const result = bumpAllocAt(.string_upcase, s.len);
        if (result.len == 0) return s;
        for (s, 0..) |c, i| {
            result[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
        }
        return result;
    }

    pub fn downcase(s: []const u8) []const u8 {
        const result = bumpAllocAt(.string_downcase, s.len);
        if (result.len == 0) return s;
        for (s, 0..) |c, i| {
            result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return result;
    }

    pub fn reverse_string(s: []const u8) []const u8 {
        if (s.len == 0) return s;
        const result = bumpAllocAt(.string_reverse, s.len);
        if (result.len == 0) return s;
        for (s, 0..) |c, i| {
            result[s.len - 1 - i] = c;
        }
        return result;
    }

    pub fn replace_string(s: []const u8, pattern: []const u8, replacement: []const u8) []const u8 {
        if (pattern.len == 0) return s;
        var count: usize = 0;
        var pos: usize = 0;
        while (pos + pattern.len <= s.len) {
            if (std.mem.eql(u8, s[pos .. pos + pattern.len], pattern)) {
                count += 1;
                pos += pattern.len;
            } else {
                pos += 1;
            }
        }
        if (count == 0) return s;
        const new_len = s.len - (count * pattern.len) + (count * replacement.len);
        const result = bumpAllocAt(.string_replace, new_len);
        if (result.len == 0) return s;
        var src: usize = 0;
        var dst: usize = 0;
        while (src < s.len) {
            if (src + pattern.len <= s.len and std.mem.eql(u8, s[src .. src + pattern.len], pattern)) {
                @memcpy(result[dst .. dst + replacement.len], replacement);
                dst += replacement.len;
                src += pattern.len;
            } else {
                result[dst] = s[src];
                dst += 1;
                src += 1;
            }
        }
        return result;
    }

    pub fn index_of(haystack: []const u8, needle: []const u8) i64 {
        if (needle.len == 0) return 0;
        if (needle.len > haystack.len) return -1;
        if (std.mem.find(u8, haystack, needle)) |idx| {
            return @intCast(idx);
        }
        return -1;
    }

    pub fn pad_leading(s: []const u8, total_len: i64, pad_char: []const u8) []const u8 {
        const target: usize = if (total_len > 0) @intCast(total_len) else return s;
        if (s.len >= target) return s;
        const pad_count = target - s.len;
        const result = bumpAllocAt(.string_pad_leading, target);
        if (result.len == 0) return s;
        const fill: u8 = if (pad_char.len > 0) pad_char[0] else ' ';
        @memset(result[0..pad_count], fill);
        @memcpy(result[pad_count..target], s);
        return result;
    }

    pub fn pad_trailing(s: []const u8, total_len: i64, pad_char: []const u8) []const u8 {
        const target: usize = if (total_len > 0) @intCast(total_len) else return s;
        if (s.len >= target) return s;
        const result = bumpAllocAt(.string_pad_trailing, target);
        if (result.len == 0) return s;
        @memcpy(result[0..s.len], s);
        const fill: u8 = if (pad_char.len > 0) pad_char[0] else ' ';
        @memset(result[s.len..target], fill);
        return result;
    }

    pub fn repeat_string(s: []const u8, count: i64) []const u8 {
        if (count <= 0 or s.len == 0) return "";
        const n: usize = @intCast(count);
        const result = bumpAllocAt(.string_repeat, s.len * n);
        if (result.len == 0) return s;
        for (0..n) |i| {
            @memcpy(result[i * s.len .. (i + 1) * s.len], s);
        }
        return result;
    }

    pub fn capitalize(s: []const u8) []const u8 {
        if (s.len == 0) return s;
        const result = bumpAllocAt(.string_capitalize, s.len);
        if (result.len == 0) return s;
        result[0] = if (s[0] >= 'a' and s[0] <= 'z') s[0] - 32 else s[0];
        for (s[1..], 0..) |c, i| {
            result[i + 1] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return result;
    }

    pub fn trim_leading(s: []const u8) []const u8 {
        return std.mem.trimStart(u8, s, " \t\n\r");
    }

    pub fn trim_trailing(s: []const u8) []const u8 {
        return std.mem.trimEnd(u8, s, " \t\n\r");
    }

    pub fn string_count(haystack: []const u8, needle: []const u8) i64 {
        if (needle.len == 0) return 0;
        var count: i64 = 0;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) {
            if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
                count += 1;
                i += needle.len;
            } else {
                i += 1;
            }
        }
        return count;
    }

    pub fn split_to_list(s: []const u8, delimiter: []const u8) ?*const List([]const u8) {
        if (delimiter.len == 0) {
            return List([]const u8).push(null, s);
        }
        var result: ?*const List([]const u8) = null;
        var pos: usize = 0;
        var seg_start: usize = 0;
        while (pos < s.len) {
            if (pos + delimiter.len <= s.len and std.mem.eql(u8, s[pos .. pos + delimiter.len], delimiter)) {
                const seg = s[seg_start..pos];
                const seg_copy = bumpAllocAt(.string_split, seg.len);
                if (seg_copy.len > 0) @memcpy(seg_copy, seg);
                result = List([]const u8).push(result, seg_copy);
                pos += delimiter.len;
                seg_start = pos;
            } else {
                pos += 1;
            }
        }
        const last_seg = s[seg_start..];
        const last_copy = bumpAllocAt(.string_split, last_seg.len);
        if (last_copy.len > 0) @memcpy(last_copy, last_seg);
        result = List([]const u8).push(result, last_copy);
        return result;
    }

    pub fn string_join(list: ?*const List([]const u8), separator: []const u8) []const u8 {
        if (list == null) return "";
        var total: usize = 0;
        const count_i64 = List([]const u8).length(list);
        if (count_i64 <= 0) return "";
        const count: usize = @intCast(count_i64);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            total += List([]const u8).get(list, @intCast(index)).len;
        }
        total += separator.len * (count - 1);
        const result = bumpAllocAt(.string_join, total);
        if (result.len == 0) return "";
        var dst: usize = 0;
        var first = true;
        index = 0;
        while (index < count) : (index += 1) {
            const segment = List([]const u8).get(list, @intCast(index));
            if (!first and separator.len > 0) {
                @memcpy(result[dst..][0..separator.len], separator);
                dst += separator.len;
            }
            @memcpy(result[dst..][0..segment.len], segment);
            dst += segment.len;
            first = false;
        }
        return result[0..dst];
    }
};

// ============================================================
// Kernel functions (spec §30.2)
// ============================================================

pub fn panic(message: []const u8) noreturn {
    stderrWriteFlushed("** (NilError) ");
    posixWrite(STDERR_FD, message);
    posixWrite(STDERR_FD, "\n");
    std.process.exit(1);
}

pub const Range = struct {
    /// Iterator protocol for ranges.
    /// Uses the range struct as its own state — `start` is the current position.
    /// Returns {:cont, current, next_range} or {:done, 0, nil_range}.
    pub fn next(range: anytype) std.meta.Tuple(&.{ u32, i64, @TypeOf(range) }) {
        const start = range.start;
        const end_val = range.end;
        const step_mag = if (range.step < 0) -range.step else range.step;
        const direction: i64 = if (@hasField(@TypeOf(range), "direction") and range.direction != 0)
            range.direction
        else if (start <= end_val)
            1
        else
            -1;

        // Check if done
        const done = if (direction > 0) start > end_val else start < end_val;
        if (done) {
            return .{ ATOM_DONE, 0, range };
        }

        // Advance: create next range with updated start
        const step = direction * step_mag;
        var next_range = range;
        next_range.start = start + step;
        if (@hasField(@TypeOf(next_range), "direction")) {
            next_range.direction = direction;
        }
        return .{ ATOM_CONT, start, next_range };
    }

    /// Flip a range's direction by swapping `start` and `end`. The
    /// `step` magnitude is preserved; the implicit direction (derived
    /// from `start` vs `end` when `direction == 0`) flips because the
    /// endpoints swapped. Returns a fresh range value — the input is
    /// not mutated.
    pub fn reverse(range: anytype) @TypeOf(range) {
        var flipped = range;
        flipped.start = range.end;
        flipped.end = range.start;
        if (@hasField(@TypeOf(flipped), "direction")) {
            flipped.direction = 0;
        }
        return flipped;
    }
};

pub const Tuple = struct {
    pub fn size(tuple: anytype) i64 {
        const arity = switch (@typeInfo(@TypeOf(tuple))) {
            .@"struct" => |info| blk: {
                if (!info.is_tuple) @compileError("Tuple.size expects a tuple value");
                break :blk info.fields.len;
            },
            else => @compileError("Tuple.size expects a tuple value"),
        };
        return @intCast(arity);
    }
};

pub const Kernel = struct {
    /// Generic string conversion used by string interpolation. Strings
    /// pass through untouched; numbers/bools/enums are formatted via the
    /// runtime arena.
    pub fn to_string(value: anytype) []const u8 {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8 or (info == .pointer and @typeInfo(std.meta.Child(T)) == .array)) {
            return value;
        } else if (T == bool) {
            return if (value) "true" else "false";
        } else if (info == .int or info == .comptime_int) {
            var buf: [64]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
            const result = bumpAllocAt(.interpolate_int, slice.len);
            if (result.len == 0) return "?";
            @memcpy(result, slice);
            return result;
        } else if (info == .float or info == .comptime_float) {
            var buf: [64]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
            const result = bumpAllocAt(.interpolate_float, slice.len);
            if (result.len == 0) return "?";
            @memcpy(result, slice);
            return result;
        } else if (info == .@"enum") {
            return @tagName(value);
        } else {
            return "<value>";
        }
    }

    pub fn panic(message: []const u8) noreturn {
        stderrWriteFlushed("panic: ");
        posixWrite(STDERR_FD, message);
        posixWrite(STDERR_FD, "\n");
        std.process.exit(1);
    }

    pub fn halt(message: []const u8) noreturn {
        stderrWriteFlushed("halt: ");
        posixWrite(STDERR_FD, message);
        posixWrite(STDERR_FD, "\n");
        std.process.exit(1);
    }

    /// Call a callable value — either a bare function pointer or a
    /// closure struct with `{call_fn, env, env_release}` fields.
    pub inline fn callCallable0(callable: anytype) CallableReturn(@TypeOf(callable)) {
        if (comptime isZapClosure(@TypeOf(callable))) {
            return callable.call_fn(callable.env);
        }
        if (comptime isBareFunction(@TypeOf(callable))) {
            return callBare0(callable);
        }
        return callable();
    }

    pub inline fn callCallable1(callable: anytype, arg0: anytype) CallableReturn(@TypeOf(callable)) {
        if (comptime isZapClosure(@TypeOf(callable))) {
            return callable.call_fn(callable.env, arg0);
        }
        if (comptime isBareFunction(@TypeOf(callable))) {
            return callBare1(callable, arg0);
        }
        return callable(arg0);
    }

    pub inline fn callCallable2(callable: anytype, arg0: anytype, arg1: anytype) CallableReturn(@TypeOf(callable)) {
        if (comptime isZapClosure(@TypeOf(callable))) {
            return callable.call_fn(callable.env, arg0, arg1);
        }
        if (comptime isBareFunction(@TypeOf(callable))) {
            return callBare2(callable, arg0, arg1);
        }
        return callable(arg0, arg1);
    }

    pub inline fn callCallable3(callable: anytype, arg0: anytype, arg1: anytype, arg2: anytype) CallableReturn(@TypeOf(callable)) {
        if (comptime isZapClosure(@TypeOf(callable))) {
            return callable.call_fn(callable.env, arg0, arg1, arg2);
        }
        if (comptime isBareFunction(@TypeOf(callable))) {
            return callBare3(callable, arg0, arg1, arg2);
        }
        return callable(arg0, arg1, arg2);
    }

    pub fn is_integer(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        return info == .int or info == .comptime_int;
    }

    pub fn is_float(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        return info == .float or info == .comptime_float;
    }

    pub fn is_number(value: anytype) bool {
        return is_integer(value) or is_float(value);
    }

    pub fn is_boolean(value: anytype) bool {
        return @TypeOf(value) == bool;
    }

    pub fn is_string(value: anytype) bool {
        const T = @TypeOf(value);
        if (T == []const u8) return true;
        const info = @typeInfo(T);
        if (info == .pointer) {
            const child = std.meta.Child(T);
            return @typeInfo(child) == .array and std.meta.Elem(child) == u8;
        }
        return false;
    }

    pub fn is_atom(value: anytype) bool {
        // Atoms are represented as u32 at runtime
        return @TypeOf(value) == u32;
    }

    pub fn is_nil(value: anytype) bool {
        const T = @TypeOf(value);
        if (T == @TypeOf(null)) return true;
        const info = @typeInfo(T);
        if (info == .optional) {
            return value == null;
        }
        return false;
    }

    pub fn is_list(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        if (info == .optional) {
            const child = @typeInfo(info.optional.child);
            if (child == .pointer and child.pointer.size == .one) {
                return @hasField(child.pointer.child, "head") and @hasField(child.pointer.child, "tail");
            }
        }
        return false;
    }

    pub fn is_tuple(value: anytype) bool {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        return info == .@"struct" and info.@"struct".is_tuple;
    }

    pub fn is_map(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        if (info == .optional) {
            const child = @typeInfo(info.optional.child);
            if (child == .pointer and child.pointer.size == .one) {
                return @hasField(child.pointer.child, "entries") and @hasField(child.pointer.child, "size");
            }
        }
        return false;
    }

    pub fn is_struct(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        if (info == .@"struct" and !info.@"struct".is_tuple) return true;
        if (info == .pointer) {
            const child = @typeInfo(std.meta.Child(@TypeOf(value)));
            if (child == .@"struct" and !child.@"struct".is_tuple) return true;
        }
        return false;
    }

    pub fn raise(message: []const u8) noreturn {
        stderrWriteFlushed("** (RuntimeError) ");
        posixWrite(STDERR_FD, message);
        posixWrite(STDERR_FD, "\n");
        std.process.exit(1);
    }

    // Operator primitives backing the generic `pub fn ==`/`!=`/`<`/`>`/
    // `<=`/`>=` in lib/kernel.zap. The Zap monomorphizer specializes the
    // Kernel operator per concrete type pair, so each instantiation here
    // sees a concrete `T` and Zig's comptime dispatch picks the right
    // operation (`std.mem.eql` for slices, `==` for value types, etc.).

    pub fn eq(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return std.mem.eql(u8, a, b);
        return a == b;
    }

    pub fn neq(a: anytype, b: anytype) bool {
        return !eq(a, b);
    }

    pub fn lt(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return std.mem.lessThan(u8, a, b);
        return a < b;
    }

    pub fn gt(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return std.mem.lessThan(u8, b, a);
        return a > b;
    }

    pub fn lte(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return !std.mem.lessThan(u8, b, a);
        return a <= b;
    }

    pub fn gte(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return !std.mem.lessThan(u8, a, b);
        return a >= b;
    }

    pub fn add(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return a +% b;
        return a + b;
    }

    pub fn sub(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return a -% b;
        return a - b;
    }

    pub fn mul(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return a *% b;
        return a * b;
    }

    pub fn divide(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return @divTrunc(a, b);
        return a / b;
    }

    pub fn remainder(a: anytype, b: anytype) @TypeOf(a) {
        return @rem(a, b);
    }

    pub fn eq_i8(a: i8, b: i8) bool {
        return a == b;
    }
    pub fn eq_i16(a: i16, b: i16) bool {
        return a == b;
    }
    pub fn eq_i32(a: i32, b: i32) bool {
        return a == b;
    }
    pub fn eq_i64(a: i64, b: i64) bool {
        return a == b;
    }
    pub fn eq_i128(a: i128, b: i128) bool {
        return a == b;
    }
    pub fn eq_u8(a: u8, b: u8) bool {
        return a == b;
    }
    pub fn eq_u16(a: u16, b: u16) bool {
        return a == b;
    }
    pub fn eq_u32(a: u32, b: u32) bool {
        return a == b;
    }
    pub fn eq_u64(a: u64, b: u64) bool {
        return a == b;
    }
    pub fn eq_u128(a: u128, b: u128) bool {
        return a == b;
    }
    pub fn eq_f16(a: f16, b: f16) bool {
        return a == b;
    }
    pub fn eq_f32(a: f32, b: f32) bool {
        return a == b;
    }
    pub fn eq_f64(a: f64, b: f64) bool {
        return a == b;
    }
    pub fn eq_f80(a: f80, b: f80) bool {
        return a == b;
    }
    pub fn eq_f128(a: f128, b: f128) bool {
        return a == b;
    }

    pub fn neq_i8(a: i8, b: i8) bool {
        return a != b;
    }
    pub fn neq_i16(a: i16, b: i16) bool {
        return a != b;
    }
    pub fn neq_i32(a: i32, b: i32) bool {
        return a != b;
    }
    pub fn neq_i64(a: i64, b: i64) bool {
        return a != b;
    }
    pub fn neq_i128(a: i128, b: i128) bool {
        return a != b;
    }
    pub fn neq_u8(a: u8, b: u8) bool {
        return a != b;
    }
    pub fn neq_u16(a: u16, b: u16) bool {
        return a != b;
    }
    pub fn neq_u32(a: u32, b: u32) bool {
        return a != b;
    }
    pub fn neq_u64(a: u64, b: u64) bool {
        return a != b;
    }
    pub fn neq_u128(a: u128, b: u128) bool {
        return a != b;
    }
    pub fn neq_f16(a: f16, b: f16) bool {
        return a != b;
    }
    pub fn neq_f32(a: f32, b: f32) bool {
        return a != b;
    }
    pub fn neq_f64(a: f64, b: f64) bool {
        return a != b;
    }
    pub fn neq_f80(a: f80, b: f80) bool {
        return a != b;
    }
    pub fn neq_f128(a: f128, b: f128) bool {
        return a != b;
    }

    pub fn lt_i8(a: i8, b: i8) bool {
        return a < b;
    }
    pub fn lt_i16(a: i16, b: i16) bool {
        return a < b;
    }
    pub fn lt_i32(a: i32, b: i32) bool {
        return a < b;
    }
    pub fn lt_i64(a: i64, b: i64) bool {
        return a < b;
    }
    pub fn lt_i128(a: i128, b: i128) bool {
        return a < b;
    }
    pub fn lt_u8(a: u8, b: u8) bool {
        return a < b;
    }
    pub fn lt_u16(a: u16, b: u16) bool {
        return a < b;
    }
    pub fn lt_u32(a: u32, b: u32) bool {
        return a < b;
    }
    pub fn lt_u64(a: u64, b: u64) bool {
        return a < b;
    }
    pub fn lt_u128(a: u128, b: u128) bool {
        return a < b;
    }
    pub fn lt_f16(a: f16, b: f16) bool {
        return a < b;
    }
    pub fn lt_f32(a: f32, b: f32) bool {
        return a < b;
    }
    pub fn lt_f64(a: f64, b: f64) bool {
        return a < b;
    }
    pub fn lt_f80(a: f80, b: f80) bool {
        return a < b;
    }
    pub fn lt_f128(a: f128, b: f128) bool {
        return a < b;
    }

    pub fn gt_i8(a: i8, b: i8) bool {
        return a > b;
    }
    pub fn gt_i16(a: i16, b: i16) bool {
        return a > b;
    }
    pub fn gt_i32(a: i32, b: i32) bool {
        return a > b;
    }
    pub fn gt_i64(a: i64, b: i64) bool {
        return a > b;
    }
    pub fn gt_i128(a: i128, b: i128) bool {
        return a > b;
    }
    pub fn gt_u8(a: u8, b: u8) bool {
        return a > b;
    }
    pub fn gt_u16(a: u16, b: u16) bool {
        return a > b;
    }
    pub fn gt_u32(a: u32, b: u32) bool {
        return a > b;
    }
    pub fn gt_u64(a: u64, b: u64) bool {
        return a > b;
    }
    pub fn gt_u128(a: u128, b: u128) bool {
        return a > b;
    }
    pub fn gt_f16(a: f16, b: f16) bool {
        return a > b;
    }
    pub fn gt_f32(a: f32, b: f32) bool {
        return a > b;
    }
    pub fn gt_f64(a: f64, b: f64) bool {
        return a > b;
    }
    pub fn gt_f80(a: f80, b: f80) bool {
        return a > b;
    }
    pub fn gt_f128(a: f128, b: f128) bool {
        return a > b;
    }

    pub fn lte_i8(a: i8, b: i8) bool {
        return a <= b;
    }
    pub fn lte_i16(a: i16, b: i16) bool {
        return a <= b;
    }
    pub fn lte_i32(a: i32, b: i32) bool {
        return a <= b;
    }
    pub fn lte_i64(a: i64, b: i64) bool {
        return a <= b;
    }
    pub fn lte_i128(a: i128, b: i128) bool {
        return a <= b;
    }
    pub fn lte_u8(a: u8, b: u8) bool {
        return a <= b;
    }
    pub fn lte_u16(a: u16, b: u16) bool {
        return a <= b;
    }
    pub fn lte_u32(a: u32, b: u32) bool {
        return a <= b;
    }
    pub fn lte_u64(a: u64, b: u64) bool {
        return a <= b;
    }
    pub fn lte_u128(a: u128, b: u128) bool {
        return a <= b;
    }
    pub fn lte_f16(a: f16, b: f16) bool {
        return a <= b;
    }
    pub fn lte_f32(a: f32, b: f32) bool {
        return a <= b;
    }
    pub fn lte_f64(a: f64, b: f64) bool {
        return a <= b;
    }
    pub fn lte_f80(a: f80, b: f80) bool {
        return a <= b;
    }
    pub fn lte_f128(a: f128, b: f128) bool {
        return a <= b;
    }

    pub fn gte_i8(a: i8, b: i8) bool {
        return a >= b;
    }
    pub fn gte_i16(a: i16, b: i16) bool {
        return a >= b;
    }
    pub fn gte_i32(a: i32, b: i32) bool {
        return a >= b;
    }
    pub fn gte_i64(a: i64, b: i64) bool {
        return a >= b;
    }
    pub fn gte_i128(a: i128, b: i128) bool {
        return a >= b;
    }
    pub fn gte_u8(a: u8, b: u8) bool {
        return a >= b;
    }
    pub fn gte_u16(a: u16, b: u16) bool {
        return a >= b;
    }
    pub fn gte_u32(a: u32, b: u32) bool {
        return a >= b;
    }
    pub fn gte_u64(a: u64, b: u64) bool {
        return a >= b;
    }
    pub fn gte_u128(a: u128, b: u128) bool {
        return a >= b;
    }
    pub fn gte_f16(a: f16, b: f16) bool {
        return a >= b;
    }
    pub fn gte_f32(a: f32, b: f32) bool {
        return a >= b;
    }
    pub fn gte_f64(a: f64, b: f64) bool {
        return a >= b;
    }
    pub fn gte_f80(a: f80, b: f80) bool {
        return a >= b;
    }
    pub fn gte_f128(a: f128, b: f128) bool {
        return a >= b;
    }

    pub fn add_i8(a: i8, b: i8) i8 {
        return a +% b;
    }
    pub fn add_i16(a: i16, b: i16) i16 {
        return a +% b;
    }
    pub fn add_i32(a: i32, b: i32) i32 {
        return a +% b;
    }
    pub fn add_i64(a: i64, b: i64) i64 {
        return a +% b;
    }
    pub fn add_i128(a: i128, b: i128) i128 {
        return a +% b;
    }
    pub fn add_u8(a: u8, b: u8) u8 {
        return a +% b;
    }
    pub fn add_u16(a: u16, b: u16) u16 {
        return a +% b;
    }
    pub fn add_u32(a: u32, b: u32) u32 {
        return a +% b;
    }
    pub fn add_u64(a: u64, b: u64) u64 {
        return a +% b;
    }
    pub fn add_u128(a: u128, b: u128) u128 {
        return a +% b;
    }
    pub fn add_f16(a: f16, b: f16) f16 {
        return a + b;
    }
    pub fn add_f32(a: f32, b: f32) f32 {
        return a + b;
    }
    pub fn add_f64(a: f64, b: f64) f64 {
        return a + b;
    }
    pub fn add_f80(a: f80, b: f80) f80 {
        return a + b;
    }
    pub fn add_f128(a: f128, b: f128) f128 {
        return a + b;
    }

    pub fn sub_i8(a: i8, b: i8) i8 {
        return a -% b;
    }
    pub fn sub_i16(a: i16, b: i16) i16 {
        return a -% b;
    }
    pub fn sub_i32(a: i32, b: i32) i32 {
        return a -% b;
    }
    pub fn sub_i64(a: i64, b: i64) i64 {
        return a -% b;
    }
    pub fn sub_i128(a: i128, b: i128) i128 {
        return a -% b;
    }
    pub fn sub_u8(a: u8, b: u8) u8 {
        return a -% b;
    }
    pub fn sub_u16(a: u16, b: u16) u16 {
        return a -% b;
    }
    pub fn sub_u32(a: u32, b: u32) u32 {
        return a -% b;
    }
    pub fn sub_u64(a: u64, b: u64) u64 {
        return a -% b;
    }
    pub fn sub_u128(a: u128, b: u128) u128 {
        return a -% b;
    }
    pub fn sub_f16(a: f16, b: f16) f16 {
        return a - b;
    }
    pub fn sub_f32(a: f32, b: f32) f32 {
        return a - b;
    }
    pub fn sub_f64(a: f64, b: f64) f64 {
        return a - b;
    }
    pub fn sub_f80(a: f80, b: f80) f80 {
        return a - b;
    }
    pub fn sub_f128(a: f128, b: f128) f128 {
        return a - b;
    }

    pub fn mul_i8(a: i8, b: i8) i8 {
        return a *% b;
    }
    pub fn mul_i16(a: i16, b: i16) i16 {
        return a *% b;
    }
    pub fn mul_i32(a: i32, b: i32) i32 {
        return a *% b;
    }
    pub fn mul_i64(a: i64, b: i64) i64 {
        return a *% b;
    }
    pub fn mul_i128(a: i128, b: i128) i128 {
        return a *% b;
    }
    pub fn mul_u8(a: u8, b: u8) u8 {
        return a *% b;
    }
    pub fn mul_u16(a: u16, b: u16) u16 {
        return a *% b;
    }
    pub fn mul_u32(a: u32, b: u32) u32 {
        return a *% b;
    }
    pub fn mul_u64(a: u64, b: u64) u64 {
        return a *% b;
    }
    pub fn mul_u128(a: u128, b: u128) u128 {
        return a *% b;
    }
    pub fn mul_f16(a: f16, b: f16) f16 {
        return a * b;
    }
    pub fn mul_f32(a: f32, b: f32) f32 {
        return a * b;
    }
    pub fn mul_f64(a: f64, b: f64) f64 {
        return a * b;
    }
    pub fn mul_f80(a: f80, b: f80) f80 {
        return a * b;
    }
    pub fn mul_f128(a: f128, b: f128) f128 {
        return a * b;
    }

    pub fn divide_i8(a: i8, b: i8) i8 {
        return @divTrunc(a, b);
    }
    pub fn divide_i16(a: i16, b: i16) i16 {
        return @divTrunc(a, b);
    }
    pub fn divide_i32(a: i32, b: i32) i32 {
        return @divTrunc(a, b);
    }
    pub fn divide_i64(a: i64, b: i64) i64 {
        return @divTrunc(a, b);
    }
    pub fn divide_i128(a: i128, b: i128) i128 {
        return @divTrunc(a, b);
    }
    pub fn divide_u8(a: u8, b: u8) u8 {
        return @divTrunc(a, b);
    }
    pub fn divide_u16(a: u16, b: u16) u16 {
        return @divTrunc(a, b);
    }
    pub fn divide_u32(a: u32, b: u32) u32 {
        return @divTrunc(a, b);
    }
    pub fn divide_u64(a: u64, b: u64) u64 {
        return @divTrunc(a, b);
    }
    pub fn divide_u128(a: u128, b: u128) u128 {
        return @divTrunc(a, b);
    }
    pub fn divide_f16(a: f16, b: f16) f16 {
        return a / b;
    }
    pub fn divide_f32(a: f32, b: f32) f32 {
        return a / b;
    }
    pub fn divide_f64(a: f64, b: f64) f64 {
        return a / b;
    }
    pub fn divide_f80(a: f80, b: f80) f80 {
        return a / b;
    }
    pub fn divide_f128(a: f128, b: f128) f128 {
        return a / b;
    }

    pub fn remainder_i8(a: i8, b: i8) i8 {
        return @rem(a, b);
    }
    pub fn remainder_i16(a: i16, b: i16) i16 {
        return @rem(a, b);
    }
    pub fn remainder_i32(a: i32, b: i32) i32 {
        return @rem(a, b);
    }
    pub fn remainder_i64(a: i64, b: i64) i64 {
        return @rem(a, b);
    }
    pub fn remainder_i128(a: i128, b: i128) i128 {
        return @rem(a, b);
    }
    pub fn remainder_u8(a: u8, b: u8) u8 {
        return @rem(a, b);
    }
    pub fn remainder_u16(a: u16, b: u16) u16 {
        return @rem(a, b);
    }
    pub fn remainder_u32(a: u32, b: u32) u32 {
        return @rem(a, b);
    }
    pub fn remainder_u64(a: u64, b: u64) u64 {
        return @rem(a, b);
    }
    pub fn remainder_u128(a: u128, b: u128) u128 {
        return @rem(a, b);
    }
    pub fn remainder_f16(a: f16, b: f16) f16 {
        return @rem(a, b);
    }
    pub fn remainder_f32(a: f32, b: f32) f32 {
        return @rem(a, b);
    }
    pub fn remainder_f64(a: f64, b: f64) f64 {
        return @rem(a, b);
    }
    pub fn remainder_f80(a: f80, b: f80) f80 {
        return @rem(a, b);
    }
    pub fn remainder_f128(a: f128, b: f128) f128 {
        return @rem(a, b);
    }

    pub fn sleep(milliseconds: i64) i64 {
        if (milliseconds <= 0) return milliseconds;
        const ms: u64 = @intCast(milliseconds);
        var ts = std.posix.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        };
        while (true) {
            const rc = std.c.nanosleep(&ts, &ts);
            if (rc == 0) break;
            if (std.posix.errno(rc) != .INTR) break;
        }
        return milliseconds;
    }
};

/// Simple fixed-buffer writer for inspect formatting.
/// Replaces the std.Io.File writer with direct buffer writes.
const BufWriter = struct {
    buf: []u8,
    pos: usize,

    pub fn print(self: *BufWriter, comptime fmt: []const u8, args: anytype) !void {
        const remaining = self.buf[self.pos..];
        const result = std.fmt.bufPrint(remaining, fmt, args) catch return;
        self.pos += result.len;
    }
};

// ============================================================
// TestTracker — mutable counters for test/assertion reporting
// ============================================================

pub const Zest = struct {
    var test_count: i64 = 0;
    var test_failures: i64 = 0;
    var assertion_count: i64 = 0;
    var assertion_failures: i64 = 0;
    var current_test_failed: bool = false;
    var seed: i64 = 0;
    var seed_set: bool = false;
    var timeout_ms: i64 = 0; // per-test timeout in milliseconds (0 = no timeout)
    var test_start_ns: i96 = 0; // timestamp when current test started
    var timeout_count: i64 = 0; // number of tests that timed out

    pub fn set_seed(s: i64) void {
        seed = s;
        seed_set = true;
    }

    pub fn get_seed() i64 {
        if (!seed_set) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            const abs_nanos: i96 = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
            const positive = if (abs_nanos < 0) -abs_nanos else abs_nanos;
            seed = @intCast(positive & 0x7FFFFFFFFFFFFFFF);
            seed_set = true;
        }
        return seed;
    }

    pub fn set_timeout(ms: i64) void {
        timeout_ms = ms;
    }

    pub fn get_timeout() i64 {
        return timeout_ms;
    }

    pub fn begin_test() void {
        current_test_failed = false;
        test_count += 1;
        if (timeout_ms > 0) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            test_start_ns = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
        }
    }

    pub fn check_timeout() bool {
        if (timeout_ms <= 0) return false;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const now_ns: i96 = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
        const elapsed_ns = now_ns - test_start_ns;
        const timeout_ns: i96 = @as(i96, timeout_ms) * 1_000_000;
        if (elapsed_ns > timeout_ns) {
            current_test_failed = true;
            timeout_count += 1;
            stdoutPrint("\x1b[1;33mT\x1b[0m", .{}); // yellow T for timeout
            return true;
        }
        return false;
    }

    pub fn end_test() void {
        if (current_test_failed) {
            test_failures += 1;
        }
    }

    pub fn print_result() void {
        if (current_test_failed) {
            print_fail();
        } else {
            print_dot();
        }
    }

    pub fn pass_assertion() void {
        assertion_count += 1;
    }

    pub fn fail_assertion() void {
        assertion_count += 1;
        assertion_failures += 1;
        current_test_failed = true;
    }

    pub fn print_dot() void {
        stdoutPrint("\x1b[1;32m.\x1b[0m", .{});
    }

    pub fn print_fail() void {
        stdoutPrint("\x1b[1;31mF\x1b[0m", .{});
    }

    pub fn summary() i64 {
        stdoutPrint("\n\nSeed: ", .{});
        writeI64(get_seed());
        if (timeout_ms > 0) {
            stdoutPrint("\nTimeout: ", .{});
            writeI64(timeout_ms);
            stdoutPrint("ms", .{});
        }
        stdoutPrint("\n", .{});
        writeI64(test_count);
        stdoutPrint(" tests, ", .{});
        writeI64(test_failures);
        stdoutPrint(" failures", .{});
        if (timeout_count > 0) {
            stdoutPrint(" (", .{});
            writeI64(timeout_count);
            stdoutPrint(" timed out)", .{});
        }
        stdoutPrint("\n", .{});
        writeI64(assertion_count);
        stdoutPrint(" assertions, ", .{});
        writeI64(assertion_failures);
        stdoutPrint(" failures\n", .{});
        return test_failures;
    }

    fn writeI64(val: i64) void {
        if (val < 0) {
            stdoutPrint("-", .{});
            writeI64(-val);
            return;
        }
        if (val >= 10) {
            writeI64(@divTrunc(val, 10));
        }
        const digit: u8 = @intCast(@mod(val, 10));
        const buf = [1]u8{'0' + digit};
        stdoutWrite(&buf);
    }
};

// ============================================================
// BinaryHelpers — concrete binary pattern matching operations
// for ZIR builder (no generics, no comptime type params)
// ============================================================

pub const BinaryHelpers = struct {
    // --- Integer reads (byte-aligned) ---
    // Each function reads N bytes from data at the given byte offset
    // using big-endian byte order, returning a u64/i64.
    // The ZIR builder calls these because ZIR cannot express generic
    // std.mem.readInt calls with comptime type parameters.

    pub fn readIntU8(data: []const u8, offset: usize) i64 {
        if (offset >= data.len) return 0;
        return @intCast(data[offset]);
    }

    pub fn readIntU16Big(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(u16, data[offset..][0..2], .big));
    }

    pub fn readIntU16Little(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(u16, data[offset..][0..2], .little));
    }

    pub fn readIntU32Big(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(u32, data[offset..][0..4], .big));
    }

    pub fn readIntU32Little(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(u32, data[offset..][0..4], .little));
    }

    pub fn readIntU64Big(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return @bitCast(std.mem.readInt(u64, data[offset..][0..8], .big));
    }

    pub fn readIntU64Little(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return @bitCast(std.mem.readInt(u64, data[offset..][0..8], .little));
    }

    pub fn readIntI8(data: []const u8, offset: usize) i64 {
        if (offset >= data.len) return 0;
        return @intCast(@as(i8, @bitCast(data[offset])));
    }

    pub fn readIntI16Big(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(i16, data[offset..][0..2], .big));
    }

    pub fn readIntI16Little(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(i16, data[offset..][0..2], .little));
    }

    pub fn readIntI32Big(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(i32, data[offset..][0..4], .big));
    }

    pub fn readIntI32Little(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(i32, data[offset..][0..4], .little));
    }

    pub fn readIntI64Big(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return std.mem.readInt(i64, data[offset..][0..8], .big);
    }

    pub fn readIntI64Little(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return std.mem.readInt(i64, data[offset..][0..8], .little);
    }

    // Sub-byte read: extract `bits` bits from data[offset] >> bit_offset
    pub fn readBitsU(data: []const u8, offset: usize, bit_offset: u3, bits: u8) i64 {
        if (offset >= data.len) return 0;
        const shifted: u8 = data[offset] >> bit_offset;
        if (bits == 0 or bits >= 8) return @intCast(shifted);
        const mask: u8 = (@as(u8, 1) << @intCast(bits)) - 1;
        return @intCast(shifted & mask);
    }

    // --- Float reads ---
    pub fn readF32Big(data: []const u8, offset: usize) f64 {
        if (offset + 4 > data.len) return 0.0;
        const int_val = std.mem.readInt(u32, data[offset..][0..4], .big);
        return @floatCast(@as(f32, @bitCast(int_val)));
    }

    pub fn readF32Little(data: []const u8, offset: usize) f64 {
        if (offset + 4 > data.len) return 0.0;
        const int_val = std.mem.readInt(u32, data[offset..][0..4], .little);
        return @floatCast(@as(f32, @bitCast(int_val)));
    }

    pub fn readF64Big(data: []const u8, offset: usize) f64 {
        if (offset + 8 > data.len) return 0.0;
        const int_val = std.mem.readInt(u64, data[offset..][0..8], .big);
        return @bitCast(int_val);
    }

    pub fn readF64Little(data: []const u8, offset: usize) f64 {
        if (offset + 8 > data.len) return 0.0;
        const int_val = std.mem.readInt(u64, data[offset..][0..8], .little);
        return @bitCast(int_val);
    }

    // --- Slice ---
    // Returns data[offset..offset+length], or data[offset..] if length == 0 (sentinel for "rest")
    pub fn slice(data: []const u8, offset: usize, length: usize) []const u8 {
        const start = @min(offset, data.len);
        if (length == 0) return data[start..];
        const end = @min(std.math.add(usize, start, length) catch data.len, data.len);
        return data[start..end];
    }

    // --- UTF-8 reads ---
    // Returns the byte sequence length for the UTF-8 character at data[offset]
    pub fn utf8ByteLen(data: []const u8, offset: usize) u64 {
        if (offset >= data.len) return 1;
        return @intCast(std.unicode.utf8ByteSequenceLength(data[offset]) catch 1);
    }

    // Returns the decoded codepoint for the UTF-8 character at data[offset..offset+len]
    pub fn utf8Decode(data: []const u8, offset: usize, len: usize) u64 {
        if (offset + len > data.len or len == 0 or len > 4) return 0xFFFD;
        const end = offset + len;
        const byte_slice = data[offset..end];
        // utf8Decode expects a fixed-size array per length
        return switch (len) {
            1 => @intCast(byte_slice[0]),
            2 => @intCast(std.unicode.utf8Decode(byte_slice[0..2].*) catch 0xFFFD),
            3 => @intCast(std.unicode.utf8Decode(byte_slice[0..3].*) catch 0xFFFD),
            4 => @intCast(std.unicode.utf8Decode(byte_slice[0..4].*) catch 0xFFFD),
            else => 0xFFFD,
        };
    }

    // --- Prefix matching ---
    // Returns true if data starts with the expected prefix
    pub fn matchPrefix(data: []const u8, expected: []const u8) bool {
        if (data.len < expected.len) return false;
        return std.mem.eql(u8, data[0..expected.len], expected);
    }
};

// ============================================================
// Callable dispatch helpers.
// ============================================================

// ---- Callable dispatch helpers ----
// Handle both bare function pointers and Zap closure structs transparently.
// Used by List and Map higher-order helpers.

fn isZapClosure(comptime Callback: type) bool {
    return switch (@typeInfo(Callback)) {
        .@"struct" => @hasField(Callback, "call_fn") and @hasField(Callback, "env"),
        else => false,
    };
}

fn isBareFunction(comptime Callback: type) bool {
    return switch (@typeInfo(Callback)) {
        .@"fn" => true,
        .pointer => |pointer| @typeInfo(pointer.child) == .@"fn",
        else => false,
    };
}

inline fn callBare0(callable: anytype) CallableReturn(@TypeOf(callable)) {
    if (comptime @typeInfo(@TypeOf(callable)) == .pointer) return @call(.auto, callable, .{});
    return @call(.auto, &callable, .{});
}

inline fn callBare1(callable: anytype, arg0: anytype) CallableReturn(@TypeOf(callable)) {
    if (comptime @typeInfo(@TypeOf(callable)) == .pointer) return @call(.auto, callable, .{arg0});
    return @call(.auto, &callable, .{arg0});
}

inline fn callBare2(callable: anytype, arg0: anytype, arg1: anytype) CallableReturn(@TypeOf(callable)) {
    if (comptime @typeInfo(@TypeOf(callable)) == .pointer) return @call(.auto, callable, .{ arg0, arg1 });
    return @call(.auto, &callable, .{ arg0, arg1 });
}

inline fn callBare3(callable: anytype, arg0: anytype, arg1: anytype, arg2: anytype) CallableReturn(@TypeOf(callable)) {
    if (comptime @typeInfo(@TypeOf(callable)) == .pointer) return @call(.auto, callable, .{ arg0, arg1, arg2 });
    return @call(.auto, &callable, .{ arg0, arg1, arg2 });
}

fn CallableReturn(comptime Callback: type) type {
    return switch (@typeInfo(Callback)) {
        .@"struct" => if (@hasField(Callback, "call_fn") and @hasField(Callback, "env"))
            FunctionReturn(@FieldType(Callback, "call_fn"))
        else
            FunctionReturn(Callback),
        else => FunctionReturn(Callback),
    };
}

fn FunctionReturn(comptime Function: type) type {
    return switch (@typeInfo(Function)) {
        .pointer => |pointer| FunctionReturn(pointer.child),
        .@"fn" => |function| function.return_type orelse void,
        else => @compileError("callable value must be a function pointer or Zap closure, got " ++ @typeName(Function)),
    };
}

inline fn call1(callback: anytype, arg0: anytype) CallableReturn(@TypeOf(callback)) {
    if (comptime isZapClosure(@TypeOf(callback))) {
        return callback.call_fn(callback.env, arg0);
    }
    if (comptime isBareFunction(@TypeOf(callback))) {
        return callBare1(callback, arg0);
    }
    return callback(arg0);
}

inline fn call2(callback: anytype, arg0: anytype, arg1: anytype) CallableReturn(@TypeOf(callback)) {
    if (comptime isZapClosure(@TypeOf(callback))) {
        return callback.call_fn(callback.env, arg0, arg1);
    }
    if (comptime isBareFunction(@TypeOf(callback))) {
        return callBare2(callback, arg0, arg1);
    }
    return callback(arg0, arg1);
}

// ============================================================
// Type-derived Map/List dispatch helpers.
//
// These free functions accept `anytype` for the collection ref and
// reconstruct the underlying `Map(K, V)` / `List(T)` type at compile
// time via `@TypeOf` introspection. The Zap-side `:zig.Map.get(...)`
// and similar bridges route through these helpers so the call site's
// runtime type — including `Map(u32, Term)` — is preserved without
// the bridge needing to encode K/V into the call name.
// ============================================================

/// Extract the underlying `Map(K, V)` type from a `?*const Map(K, V)`
/// (or `*const Map(K, V)`) operand. Used by the dispatch helpers to
/// look up the right monomorph.
fn MapTypeOf(comptime MapPtr: type) type {
    const ti = @typeInfo(MapPtr);
    const ptr_inner = switch (ti) {
        .optional => |o| @typeInfo(o.child),
        .pointer => ti,
        else => @compileError("MapTypeOf: expected ?*const Map or *const Map, got " ++ @typeName(MapPtr)),
    };
    return switch (ptr_inner) {
        .pointer => |p| p.child,
        else => @compileError("MapTypeOf: expected ?*const Map, got " ++ @typeName(MapPtr)),
    };
}

fn ListTypeOf(comptime ListPtr: type) type {
    const ti = @typeInfo(ListPtr);
    const ptr_inner = switch (ti) {
        .optional => |o| @typeInfo(o.child),
        .pointer => ti,
        else => @compileError("ListTypeOf: expected ?*const List or *const List, got " ++ @typeName(ListPtr)),
    };
    return switch (ptr_inner) {
        .pointer => |p| p.child,
        else => @compileError("ListTypeOf: expected ?*const List, got " ++ @typeName(ListPtr)),
    };
}

/// Wrap a heterogeneous-friendly `Map.get` over an `anytype` default.
/// When the underlying Map's value type is `Term`, this wraps the
/// default into a Term, calls `Map.get`, then unwraps the resulting
/// Term back into the default's static type. When the value type is
/// already a concrete (homogeneous) type, the default is forwarded
/// unchanged. The return type matches whichever the caller passed —
/// string literals (`*const [N:0]u8`) are surfaced as `[]const u8`.
pub fn mapGet(map: anytype, key: anytype, default: anytype) MapGetReturnType(@TypeOf(map), @TypeOf(default)) {
    const M = MapTypeOf(@TypeOf(map));
    const V = @FieldType(M.MapEntry, "value");
    if (V == Term) {
        const wrapped = Term.from(default);
        const result = M.get(map, key, wrapped);
        return Term.toCoerced(result, default);
    }
    return M.get(map, key, default);
}

fn MapGetReturnType(comptime MapPtr: type, comptime DefaultT: type) type {
    const M = MapTypeOf(MapPtr);
    const V = @FieldType(M.MapEntry, "value");
    if (V == Term) {
        // String literals are returned as `[]const u8` slices.
        const dti = @typeInfo(DefaultT);
        if (dti == .pointer and dti.pointer.size == .one) {
            const child_info = @typeInfo(dti.pointer.child);
            if (child_info == .array and child_info.array.child == u8) {
                return []const u8;
            }
        }
        return DefaultT;
    }
    return V;
}

pub fn mapHasKey(map: anytype, key: anytype) bool {
    const M = MapTypeOf(@TypeOf(map));
    return M.hasKey(map, key);
}

pub fn mapPut(map: anytype, key: anytype, value: anytype) ?*const MapTypeOf(@TypeOf(map)) {
    const M = MapTypeOf(@TypeOf(map));
    const V = @FieldType(M.MapEntry, "value");
    if (V == Term) {
        return M.put(map, key, Term.from(value));
    }
    return M.put(map, key, value);
}

pub fn mapDelete(map: anytype, key: anytype) ?*const MapTypeOf(@TypeOf(map)) {
    const M = MapTypeOf(@TypeOf(map));
    return M.delete(map, key);
}

pub fn mapMerge(a: anytype, b: anytype) ?*const MapTypeOf(@TypeOf(a)) {
    const M = MapTypeOf(@TypeOf(a));
    return M.merge(a, b);
}

// ---------------------------------------------------------------
// uniqueness unchecked-mutation bridge helpers
// ---------------------------------------------------------------
//
// The codegen rewriter (`arc_ownership.rewriteUncheckedUniquenessSites`) emits
// `call_builtin "Map.put_owned_unchecked"` etc. for sites where uniqueness
// proves static uniqueness. The ZIR backend's generic-container path
// (`is_generic_container = mod_name == "Map"`) routes those calls
// through `mapBridgeMethodToHelper`, which dispatches to these
// `anytype`-typed helpers. Each helper recovers the concrete
// `Map(K, V)` type from `@TypeOf(map)` and calls the matching
// `*_owned_unchecked` method.
//
// Soundness contract: see `Map(K, V).put_owned_unchecked` in this
// module — the receiver MUST have refcount == 1 by construction.
// uniqueness enforces that gate at the codegen layer.

pub fn mapPutOwnedUnchecked(map: anytype, key: anytype, value: anytype) ?*const MapTypeOf(@TypeOf(map)) {
    const M = MapTypeOf(@TypeOf(map));
    const V = @FieldType(M.MapEntry, "value");
    if (V == Term) {
        return M.put_owned_unchecked(map, key, Term.from(value));
    }
    return M.put_owned_unchecked(map, key, value);
}

pub fn mapDeleteOwnedUnchecked(map: anytype, key: anytype) ?*const MapTypeOf(@TypeOf(map)) {
    const M = MapTypeOf(@TypeOf(map));
    return M.delete_owned_unchecked(map, key);
}

pub fn mapMergeOwnedUnchecked(a: anytype, b: anytype) ?*const MapTypeOf(@TypeOf(a)) {
    const M = MapTypeOf(@TypeOf(a));
    return M.merge_owned_unchecked(a, b);
}

pub fn mapSize(map: anytype) i64 {
    const M = MapTypeOf(@TypeOf(map));
    return M.size(map);
}

pub fn mapIsEmpty(map: anytype) bool {
    const M = MapTypeOf(@TypeOf(map));
    return M.isEmpty(map);
}

pub fn mapNext(map: anytype) std.meta.Tuple(&.{
    u32,
    std.meta.Tuple(&.{ MapKeyOf(@TypeOf(map)), MapValueOf(@TypeOf(map)) }),
    ?*const MapTypeOf(@TypeOf(map)),
}) {
    const M = MapTypeOf(@TypeOf(map));
    return M.next(map);
}

pub fn mapKeys(map: anytype) ?*const List(MapKeyOf(@TypeOf(map))) {
    const M = MapTypeOf(@TypeOf(map));
    return M.keys(map);
}

pub fn mapValues(map: anytype) ?*const List(MapValueOf(@TypeOf(map))) {
    const M = MapTypeOf(@TypeOf(map));
    return M.values(map);
}

pub fn mapEnumReduceValues(map: anytype, initial: i64, callback: anytype) i64 {
    const M = MapTypeOf(@TypeOf(map));
    return M.enumReduceValues(map, initial, callback);
}

fn MapValueOf(comptime MapPtr: type) type {
    const M = MapTypeOf(MapPtr);
    return @FieldType(M.MapEntry, "value");
}

fn MapKeyOf(comptime MapPtr: type) type {
    const M = MapTypeOf(MapPtr);
    return @FieldType(M.MapEntry, "key");
}

pub fn listGetHead(list: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.getHead(list);
}

pub fn listGetTail(list: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.getTail(list);
}

pub fn listSliceFrom(list: anytype, start: i64) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.sliceFrom(list, start);
}

pub fn listSliceOwnedUnchecked(list: anytype, start: i64) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.slice_owned_unchecked(list, start);
}

pub fn listIsEmpty(list: anytype) bool {
    const L = ListTypeOf(@TypeOf(list));
    return L.isEmpty(list);
}

pub fn listLength(list: anytype) i64 {
    const L = ListTypeOf(@TypeOf(list));
    return L.length(list);
}

pub fn listCapacity(list: anytype) i64 {
    const L = ListTypeOf(@TypeOf(list));
    return L.capacity(list);
}

pub fn listGet(list: anytype, index: i64) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.get(list, index);
}

pub fn listLast(list: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.last(list);
}

pub fn listReverse(list: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.reverse(list);
}

pub fn listConcat(a: anytype, b: anytype) @TypeOf(a) {
    const L = ListTypeOf(@TypeOf(a));
    return L.concat(a, b);
}

pub fn listSet(list: anytype, index: i64, value: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.set(list, index, listElementValue(L.Element, value));
}

pub fn listPush(list: anytype, value: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.push(list, listElementValue(L.Element, value));
}

pub fn listPop(list: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.pop(list);
}

pub fn listAppend(a: anytype, b: anytype) @TypeOf(a) {
    const L = ListTypeOf(@TypeOf(a));
    return L.append(a, b);
}

pub fn listSetOwnedUnchecked(list: anytype, index: i64, value: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.set_owned_unchecked(list, index, listElementValue(L.Element, value));
}

pub fn listPushOwnedUnchecked(list: anytype, value: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.push_owned_unchecked(list, listElementValue(L.Element, value));
}

pub fn listPopOwnedUnchecked(list: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.pop_owned_unchecked(list);
}

pub fn listAppendOwnedUnchecked(a: anytype, b: anytype) @TypeOf(a) {
    const L = ListTypeOf(@TypeOf(a));
    return L.append_owned_unchecked(a, b);
}

pub fn listContains(list: anytype, value: anytype) bool {
    const L = ListTypeOf(@TypeOf(list));
    return L.contains(list, listElementValue(L.Element, value));
}

pub fn listTake(list: anytype, count: i64) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.take(list, count);
}

pub fn listNext(list: anytype) std.meta.Tuple(&.{ u32, ListElementOf(@TypeOf(list)), @TypeOf(list) }) {
    const L = ListTypeOf(@TypeOf(list));
    return L.next(list);
}

pub fn listCons(head: anytype, tail: anytype) @TypeOf(tail) {
    const L = ListTypeOf(@TypeOf(tail));
    return L.cons(head, tail);
}

pub fn listDrop(list: anytype, count: i64) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.drop(list, count);
}

pub fn listUniq(list: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.uniq(list);
}

pub fn listMapFn(list: anytype, callback: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.mapFn(list, callback);
}

pub fn listFilterFn(list: anytype, predicate: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.filterFn(list, predicate);
}

pub fn listRejectFn(list: anytype, predicate: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.rejectFn(list, predicate);
}

pub fn listEnumReduceSimple(list: anytype, initial: ListElementOf(@TypeOf(list)), callback: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.enumReduceSimple(list, initial, callback);
}

pub fn listEachFn(list: anytype, callback: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.eachFn(list, callback);
}

pub fn listFindFn(list: anytype, default: anytype, predicate: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.findFn(list, default, predicate);
}

pub fn listAnyFn(list: anytype, predicate: anytype) bool {
    const L = ListTypeOf(@TypeOf(list));
    return L.anyFn(list, predicate);
}

pub fn listAllFn(list: anytype, predicate: anytype) bool {
    const L = ListTypeOf(@TypeOf(list));
    return L.allFn(list, predicate);
}

pub fn listCountFn(list: anytype, predicate: anytype) i64 {
    const L = ListTypeOf(@TypeOf(list));
    return L.countFn(list, predicate);
}

pub fn listSortFn(list: anytype, comparator: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.sortFn(list, comparator);
}

pub fn listFlatMapFn(list: anytype, callback: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.flatMapFn(list, callback);
}

pub fn listMaxVal(list: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.maxVal(list);
}

pub fn listMinVal(list: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.minVal(list);
}

pub fn listSum(list: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.sum(list);
}

fn ListElementOf(comptime ListPtr: type) type {
    const L = ListTypeOf(ListPtr);
    return L.Element;
}

fn listElementValue(comptime Element: type, value: anytype) Element {
    if (Element == Term) {
        return Term.from(value);
    }
    return value;
}

// ============================================================
// Term — heterogeneous value wrapper.
//
// Used as the storage type for collections whose elements are not
// homogeneously typed (e.g. `%{name: "Alice", age: 30}` where the
// values are `String` and `i64`). The compiler picks `Term` as the
// element type whenever the static element types disagree, then
// inserts wrapping (`Term.from(x)`) at construction sites and
// unwrapping (`Term.to(T, t, default)`) at consumption sites so the
// caller still sees a concrete value of the expected type.
//
// Homogeneous collections continue to instantiate the underlying
// `List(T)` / `Map(K, V)` directly with their concrete element
// types; `Term` is engaged only for the heterogeneous case.
// ============================================================

pub const Term = union(enum) {
    int: i64,
    float: f64,
    str: []const u8,
    bool_val: bool,
    atom: u32,
    nil: void,
    /// Erased ?*const List(Term). Stored as opaque pointer to avoid
    /// the recursive type definition; callers reinterpret via the
    /// helpers below.
    list: ?*const anyopaque,
    /// Erased ?*const Map(K, Term). The key type is irrelevant to
    /// `Term` itself — collection-specific code knows the key type.
    map: ?*const anyopaque,
    /// Owned slice of child terms (small fixed-size aggregates).
    tuple: []const Term,

    /// Wrap a Zig value of any supported type as a `Term`. Comptime
    /// dispatch keeps the call sites at the wrap point allocation-free
    /// for scalars and slices.
    pub fn from(value: anytype) Term {
        const T = @TypeOf(value);
        const ti = @typeInfo(T);
        return switch (ti) {
            .bool => .{ .bool_val = value },
            .int => |int_info| blk: {
                if (int_info.signedness == .signed) {
                    break :blk .{ .int = @intCast(value) };
                } else {
                    // u32 atoms — emitted Zap atoms are u32. Map them
                    // to the atom variant so equality and printing can
                    // round-trip correctly.
                    if (T == u32) break :blk .{ .atom = value };
                    break :blk .{ .int = @intCast(value) };
                }
            },
            .comptime_int => .{ .int = @intCast(value) },
            .float => .{ .float = @floatCast(value) },
            .comptime_float => .{ .float = @floatCast(value) },
            .pointer => |ptr_info| blk: {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    break :blk .{ .str = value };
                }
                if (ptr_info.size == .one) {
                    const child_info = @typeInfo(ptr_info.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        break :blk .{ .str = value[0..] };
                    }
                }
                break :blk .{ .nil = {} };
            },
            .optional => |opt_info| blk: {
                if (value) |v| {
                    // Re-enter `from` with the unwrapped value.
                    break :blk Term.from(v);
                }
                _ = opt_info;
                break :blk .{ .nil = {} };
            },
            .void => .{ .nil = {} },
            .null => .{ .nil = {} },
            else => blk: {
                if (T == Term) break :blk value;
                break :blk .{ .nil = {} };
            },
        };
    }

    /// Unwrap a `Term` into a concrete Zig value of type `T`. If the
    /// runtime variant does not match, returns the supplied default.
    /// Accepts `[]const u8` slices and `*const [N:0]u8` string-literal
    /// pointers transparently — both fan in to the `.str` variant.
    pub fn to(comptime T: type, t: Term, default: T) T {
        if (T == Term) return t;
        const ti = @typeInfo(T);
        return switch (ti) {
            .bool => if (t == .bool_val) t.bool_val else default,
            .int => |int_info| blk: {
                if (int_info.signedness == .unsigned and T == u32) {
                    break :blk if (t == .atom) t.atom else default;
                }
                if (t == .int) {
                    break :blk @intCast(t.int);
                }
                break :blk default;
            },
            .float => if (t == .float) @floatCast(t.float) else default,
            .pointer => |ptr_info| blk: {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    break :blk if (t == .str) t.str else default;
                }
                break :blk default;
            },
            .optional => blk: {
                if (t == .nil) break :blk null;
                break :blk default;
            },
            .void => {},
            else => default,
        };
    }

    /// Unwrap a `Term` to a value compatible with `default`'s static
    /// type, but always materialise the result as a `[]const u8` slice
    /// whenever the default is a string (slice or string-literal
    /// pointer). This sidesteps a Zig codegen quirk where parameters
    /// declared `anytype` keep their argument's literal pointer-to-
    /// array type instead of coercing to `[]const u8`, which would
    /// otherwise force `Term.to` to compare incompatible target types.
    pub fn toCoerced(t: Term, default: anytype) ToCoercedResult(@TypeOf(default)) {
        const D = @TypeOf(default);
        const dti = @typeInfo(D);
        if (dti == .pointer and dti.pointer.size == .one) {
            const child_info = @typeInfo(dti.pointer.child);
            if (child_info == .array and child_info.array.child == u8) {
                // String literal — return as []const u8.
                return if (t == .str) t.str else @as([]const u8, default);
            }
        }
        return Term.to(D, t, default);
    }

    pub fn ToCoercedResult(comptime D: type) type {
        const dti = @typeInfo(D);
        if (dti == .pointer and dti.pointer.size == .one) {
            const child_info = @typeInfo(dti.pointer.child);
            if (child_info == .array and child_info.array.child == u8) {
                return []const u8;
            }
        }
        return D;
    }

    pub fn eql(a: Term, b: Term) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .int => a.int == b.int,
            .float => a.float == b.float,
            .str => std.mem.eql(u8, a.str, b.str),
            .bool_val => a.bool_val == b.bool_val,
            .atom => a.atom == b.atom,
            .nil => true,
            .list => a.list == b.list,
            .map => a.map == b.map,
            .tuple => blk: {
                if (a.tuple.len != b.tuple.len) break :blk false;
                for (a.tuple, b.tuple) |ea, eb| {
                    if (!eql(ea, eb)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// FNV-1a hash seed for Term values. Used by `Map(K, Term)` to
    /// hash heterogeneous values when atoms-as-keys still need stable
    /// hashing of the value type for collision resolution diagnostics.
    pub fn hash(self: Term) u32 {
        return switch (self) {
            .int => |v| @truncate(@as(u64, @bitCast(v))),
            .float => |v| @truncate(@as(u64, @bitCast(v))),
            .str => |v| blk: {
                var h: u32 = 2166136261;
                for (v) |byte| {
                    h ^= byte;
                    h *%= 16777619;
                }
                break :blk h;
            },
            .bool_val => |v| if (v) @as(u32, 1) else @as(u32, 0),
            .atom => |v| v,
            .nil => 0,
            .list => 0,
            .map => 0,
            .tuple => |elems| blk: {
                var h: u32 = 2166136261;
                for (elems) |elem| {
                    h ^= hash(elem);
                    h *%= 16777619;
                }
                break :blk h;
            },
        };
    }
};

/// Coerce a value of any type back to the type produced by
/// `Term.ToCoercedResult(@TypeOf(default))`. When the value is itself a
/// `Term`, unwraps via `Term.toCoerced`. When the value is already
/// compatible with `default` (the homogeneous case where the runtime
/// collection's element type matches the declared type), returns it
/// as-is. Used by pattern lowering for heterogeneous keyword lists:
/// the function param's declared tuple slot may be `i64`, but the actual
/// runtime tuple may carry `Term` values (when the caller passed a
/// heterogeneous keyword list). One helper handles both shapes via a
/// comptime branch on `@TypeOf(value)`.
pub fn coerceFromMaybeTerm(value: anytype, default: anytype) Term.ToCoercedResult(@TypeOf(default)) {
    const V = @TypeOf(value);
    if (V == Term) {
        return Term.toCoerced(value, default);
    }
    return value;
}

// ============================================================
// wyhash — embedded hash function for the dense Map.
//
// Wraps Zig's stdlib production wyhash (the same `final v3` used by
// `ankerl::unordered_dense` by default) and adds a per-process random
// seed source. Inlined into runtime.zig (rather than imported from
// `wyhash.zig`) because runtime.zig is the single registered runtime
// source for every user binary — additional sibling files cannot be
// imported. The host build retains `src/wyhash.zig` for unit tests.
// ============================================================

const Wyhash = struct {
    const StdWyhash = std.hash.Wyhash;

    /// Strictly-monotonic counter bumped on every seed materialization.
    /// Combined with ASLR-derived entropy via SplitMix64 to produce a
    /// per-instance seed unpredictable to an attacker without process
    /// introspection.
    var seed_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    threadlocal var thread_seed_state: ?u64 = null;

    inline fn splitMix64(state: u64) u64 {
        var z = state +% 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn osEntropy() u64 {
        var buf: [8]u8 = undefined;
        switch (builtin.os.tag) {
            .linux => {
                const rc = std.os.linux.getrandom(&buf, buf.len, 0);
                if (rc == buf.len) {
                    return std.mem.readInt(u64, &buf, .little);
                }
            },
            else => {},
        }
        return 0;
    }

    pub fn nextSeed() u64 {
        const counter = seed_counter.fetchAdd(1, .monotonic);
        if (thread_seed_state == null) {
            const ra: u64 = @intCast(@returnAddress());
            thread_seed_state = splitMix64(ra ^ osEntropy() ^ 0xD1B54A32D192ED03);
        }
        thread_seed_state = splitMix64(thread_seed_state.? +% counter);
        return thread_seed_state.?;
    }

    /// Integer mixer based on SplitMix64's finalizer. See
    /// `src/wyhash.zig::hashInt` for the design rationale. Inlines to a
    /// handful of arithmetic instructions — three multiplies and three
    /// shifts — so the dense Map's per-put hash cost collapses from a
    /// byte-buffer roundtrip through full wyhash to a register-resident
    /// finalizer chain. Critical for integer-key workloads like the
    /// k-nucleotide benchmark, which performs millions of `Map(i64, i64)`
    /// `put`/`get` calls and was spending the majority of its hash budget
    /// in wyhash's variable-length prologue/epilogue.
    pub inline fn hashInt(seed: u64, value: u64) u64 {
        var z: u64 = value +% seed +% 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return (z ^ (z >> 31)) ^ seed;
    }

    pub inline fn hashU64(seed: u64, value: u64) u64 {
        return hashInt(seed, value);
    }

    pub inline fn hashU32(seed: u64, value: u32) u64 {
        return hashInt(seed, @as(u64, value));
    }

    pub inline fn hashBytes(seed: u64, bytes: []const u8) u64 {
        return StdWyhash.hash(seed, bytes);
    }

    /// Comptime-dispatched hasher matching `wyhash.zig::hash`.
    pub inline fn hash(seed: u64, value: anytype) u64 {
        const T = @TypeOf(value);
        const ti = @typeInfo(T);
        return switch (ti) {
            .int => |int_info| blk: {
                if (int_info.bits <= 32) {
                    break :blk hashU32(seed, @intCast(@as(std.meta.Int(.unsigned, int_info.bits), @bitCast(value))));
                }
                if (int_info.bits == 64) {
                    break :blk hashU64(seed, @bitCast(value));
                }
                var bytes: [@sizeOf(T)]u8 = undefined;
                std.mem.writeInt(T, &bytes, value, .little);
                break :blk hashBytes(seed, &bytes);
            },
            .comptime_int => hashU64(seed, @intCast(value)),
            .bool => hashInt(seed, @intFromBool(value)),
            .pointer => |ptr_info| blk: {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    break :blk hashBytes(seed, value);
                }
                break :blk hashU64(seed, @intCast(@intFromPtr(value)));
            },
            else => @compileError("wyhash.hash: unsupported key type " ++ @typeName(T)),
        };
    }
};

// ============================================================
// Dense Map constants. Layout described in
// `docs/dense-map-implementation-plan.md` §1.1.
// ============================================================

/// Empty bucket sentinel.
const DENSE_MAP_EMPTY: u32 = 0xFFFFFFFF;
/// Distance increment encoded in `dist_and_fingerprint` (high 24 bits).
const DENSE_MAP_DIST_INC: u32 = 0x100;
/// Mask for the 8-bit fingerprint (low byte of `dist_and_fingerprint`).
const DENSE_MAP_FINGERPRINT_MASK: u32 = 0xFF;
/// Initial capacity at first allocation (power of 2).
const DENSE_MAP_INITIAL_CAPACITY: u32 = 8;
/// Load factor numerator/denominator: resize when len+1 > cap*7/8.
const DENSE_MAP_LOAD_NUM: u32 = 7;
const DENSE_MAP_LOAD_DEN: u32 = 8;

/// Bucket — 8 bytes. `dist_and_fingerprint` packs distance (high 24 bits,
/// +1 shifted by `DENSE_MAP_DIST_INC` so home slot reads `0x100`) and
/// fingerprint (low 8 bits = high byte of the 64-bit hash).
pub const DenseMapBucket = extern struct {
    dist_and_fingerprint: u32,
    entry_idx: u32,
};

comptime {
    std.debug.assert(@sizeOf(DenseMapBucket) == 8);
}

// ============================================================
// Map — dense, insertion-ordered, open-addressed table.
//
// The cell pointer (`?*const Map(K, V)`) is the buffer pointer.
// `null` is the empty-map sentinel — no allocation until first put.
// The struct's first field is `header: ArcHeader` so the runtime's
// `hasInlineArcHeader` recognises it for ARC dispatch (same shape as
// `List(T)` cells and the legacy HAMT cell).
//
// Layout (single contiguous allocation):
//
//   [ Self            (header, len, capacity, entry_cap, hash_seed) ]
//   [ buckets[capacity] of DenseMapBucket                            ]
//   [ entries[entry_cap] of MapEntry { hash, key, value }            ]
//
// Robin Hood probing with a `(dist << 8) | fingerprint` packed metric
// drives insertion and lookup. Delete is swap-remove on entries plus
// backshift on buckets. Refcount-aware mutators dispatch on
// `header.count() == 1` for the rc-1 fast path.
// ============================================================

pub fn Map(comptime K: type, comptime V: type) type {
    // `extern struct` pins the field order so the first 24 bytes
    // of `Map(K, V)` are guaranteed binary-compatible with
    // `MapIter(K, V)`'s header prefix. The discriminator check
    // `capacity == 0` in `Map.next`/`Map.release` requires both
    // structs to land `capacity` at the same byte offset;
    // automatic-layout structs reorder fields by descending
    // alignment, which would put `hash_seed` first and break the
    // alias. Extern struct lays fields in declaration order.
    return extern struct {
        const Self = @This();

        // Inline buffer header. Self IS the header; the cell pointer is
        // the buffer pointer. `header: ArcHeader` lives at offset 0 so
        // `ArcRuntime.hasInlineArcHeader` recognises this type as
        // self-managed (same shape as List(T) cells).

        /// ARC refcount. Initialised to 1 by `bufferAlloc`.
        header: ArcHeader,
        /// Number of populated entries (also the cursor for the next entry).
        len: u32,
        /// Number of bucket slots (always a power of 2, >= INITIAL_CAPACITY).
        /// Special value: `capacity == 0` flags a `MapIter(K, V)` cell —
        /// the first 24 bytes of MapIter are binary-compatible with Map's
        /// header so `Map.next`/`Map.retain`/`Map.release` can detect iter
        /// cells via this field WITHOUT a separate tag byte. A real Map
        /// always has `capacity >= DENSE_MAP_INITIAL_CAPACITY` (= 8), so
        /// `capacity == 0` is unambiguous. See `MapIter(K, V)` below.
        capacity: u32,
        /// Number of entry slots (kept in lockstep with `capacity` here).
        entry_cap: u32,
        /// Per-instance hash seed sampled at construction. Used for every
        /// key hash so resize is deterministic.
        hash_seed: u64,

        /// Entry stored densely in insertion order. Plain (non-extern)
        /// struct so K and V can be slices, optionals, tagged unions, etc.
        pub const MapEntry = struct {
            hash: u64,
            key: K,
            value: V,
        };

        // -------------------------------------------------------------------
        // Layout helpers
        // -------------------------------------------------------------------

        inline fn bucketsByteOffset() usize {
            return std.mem.alignForward(usize, @sizeOf(Self), @alignOf(DenseMapBucket));
        }

        inline fn entriesByteOffset(capacity_arg: u32) usize {
            const after_buckets = bucketsByteOffset() + @as(usize, capacity_arg) * @sizeOf(DenseMapBucket);
            return std.mem.alignForward(usize, after_buckets, @alignOf(MapEntry));
        }

        inline fn bufferSize(capacity_arg: u32, entry_cap_arg: u32) usize {
            return entriesByteOffset(capacity_arg) + @as(usize, entry_cap_arg) * @sizeOf(MapEntry);
        }

        inline fn bufferAlign() std.mem.Alignment {
            const a_self = std.mem.Alignment.of(Self);
            const a_bucket = std.mem.Alignment.of(DenseMapBucket);
            const a_entry = std.mem.Alignment.of(MapEntry);
            return a_self.max(a_bucket).max(a_entry);
        }

        inline fn bucketsPtr(self: *const Self) [*]DenseMapBucket {
            const base: [*]u8 = @ptrCast(@constCast(self));
            return @as([*]DenseMapBucket, @ptrCast(@alignCast(base + bucketsByteOffset())));
        }

        inline fn entriesPtr(self: *const Self) [*]MapEntry {
            const base: [*]u8 = @ptrCast(@constCast(self));
            return @as([*]MapEntry, @ptrCast(@alignCast(base + entriesByteOffset(self.capacity))));
        }

        inline fn bucketAt(self: *Self, idx: u32) *DenseMapBucket {
            std.debug.assert(idx < self.capacity);
            return &self.bucketsPtr()[idx];
        }

        inline fn entryAt(self: *Self, idx: u32) *MapEntry {
            std.debug.assert(idx < self.len);
            return &self.entriesPtr()[idx];
        }

        inline fn entryAtConst(self: *const Self, idx: u32) *const MapEntry {
            std.debug.assert(idx < self.len);
            return &self.entriesPtr()[idx];
        }

        // -------------------------------------------------------------------
        // Public introspection
        // -------------------------------------------------------------------

        pub fn size(map: ?*const Self) i64 {
            if (map) |m| {
                // Iter-cell guard. A `MapIter` cell aliases `Map.Self`'s
                // first 24 bytes but its `capacity` field is always 0;
                // a real Map has `capacity >= DENSE_MAP_INITIAL_CAPACITY`
                // (8). Reading `m.len` on an iter cell would expose the
                // iter's zero-initialised `len_unused` field, which is
                // not the source map's length and would silently mislead
                // callers. `Map.size` is never meant to receive iter
                // cells — they are valid only as `Map.next` state.
                if (m.capacity == 0) @panic("Map.size: received MapIter cell; iter cells are only valid as Map.next state");
                if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(m));
                return @intCast(m.len);
            }
            return 0;
        }

        pub fn isEmpty(map: ?*const Self) bool {
            if (map) |m| {
                if (m.capacity == 0) @panic("Map.isEmpty: received MapIter cell; iter cells are only valid as Map.next state");
            }
            return map == null;
        }

        pub fn empty() ?*const Self {
            return null;
        }

        // -------------------------------------------------------------------
        // Buffer alloc / free
        // -------------------------------------------------------------------

        /// Allocate a freshly-zeroed buffer with the given capacity.
        /// Refcount=1, all buckets EMPTY, `len=0`.
        fn bufferAlloc(capacity_arg: u32, seed: u64, creation_callsite: u64) ?*Self {
            std.debug.assert(std.math.isPowerOfTwo(capacity_arg));
            const total = bufferSize(capacity_arg, capacity_arg);
            const allocator = std.heap.c_allocator;
            const align_v = comptime bufferAlign();
            const raw = allocator.alignedAlloc(u8, align_v, total) catch return null;
            const self_ptr: *Self = @ptrCast(@alignCast(raw.ptr));
            self_ptr.* = .{
                .header = ArcHeader.init(),
                .len = 0,
                .capacity = capacity_arg,
                .entry_cap = capacity_arg,
                .hash_seed = seed,
            };
            const buckets_ptr = self_ptr.bucketsPtr();
            for (0..capacity_arg) |i| {
                buckets_ptr[i] = .{ .dist_and_fingerprint = DENSE_MAP_EMPTY, .entry_idx = 0 };
            }
            if (comptime instrument_map) {
                mapInstrumentationOnAlloc(@intFromPtr(self_ptr), 0, creation_callsite);
            }
            return self_ptr;
        }

        /// Free the buffer without deep-releasing K/V children. Used on
        /// the unique-owner resize path where children have been moved.
        fn bufferFreeShallow(self: *Self) void {
            const allocator = std.heap.c_allocator;
            const total = bufferSize(self.capacity, self.entry_cap);
            const align_v = comptime bufferAlign();
            const raw_ptr: [*]u8 = @ptrCast(self);
            const raw_slice = @as([*]align(align_v.toByteUnits()) u8, @alignCast(raw_ptr))[0..total];
            allocator.free(raw_slice);
        }

        fn bufferFreeDeep(self: *Self) void {
            const len = self.len;
            const entries = self.entriesPtr();
            const allocator = std.heap.c_allocator;
            for (0..len) |i| {
                releaseEntryKey(entries[i].key, allocator);
                releaseEntryValue(entries[i].value, allocator);
            }
            self.bufferFreeShallow();
        }

        // -------------------------------------------------------------------
        // Retain / release
        // -------------------------------------------------------------------

        pub fn retain(map: ?*const Self) ?*const Self {
            if (map) |m| {
                // Iter-cell guard. `Map.retain` is the public ARC entry
                // point for real Map cells; iter cells manage their own
                // refcount via the slab pool's inline header and are
                // never meant to be retained through this path. Iter
                // cells are produced by `Map.next` and consumed by
                // either the next `Map.next` step or `Map.release` (via
                // the iter-cell dispatch). A retain on an iter cell
                // would silently bump the iter's rc without any
                // matching release path here — a leak. Panic instead.
                if (m.capacity == 0) @panic("Map.retain: received MapIter cell; iter cells are only valid as Map.next state");
                const mut: *Self = @constCast(m);
                ArcRuntime.headerRetain(&mut.header);
                if (comptime instrument_map) {
                    // The dispatcher just incremented the count; observe
                    // the post-retain value for instrumentation.
                    const new_count = mut.header.count();
                    mapInstrumentationOnRetain(@intFromPtr(m), new_count);
                }
            }
            return map;
        }

        pub fn release(map: ?*const Self) void {
            if (map == null) return;
            const m = map.?;
            // Iter-cell discriminator. A `MapIter` cell's first 24 bytes
            // are binary-compatible with `Map.Self`'s header but its
            // `capacity` field is always 0. Dispatch to the iter
            // release path so we free the iter cell via its own pool
            // and drop the retained source-map reference.
            if (m.capacity == 0) {
                map_release_iter_dispatch_total += 1;
                MapIter(K, V).releaseFromMapPtr(m);
                return;
            }
            const mut: *Self = @constCast(m);
            ArcRuntime.headerRelease(&mut.header, mapDeepWalk);
        }

        /// Deep-walk callback invoked by the manager's `release` on
        /// the final zero-transition. Performs the cell's full
        /// teardown: instrumentation notification (when compiled in),
        /// deep-release of every K/V pair, and freeing the buffer.
        fn mapDeepWalk(ptr: *anyopaque) callconv(.c) void {
            const mut: *Self = @ptrCast(@alignCast(ptr));
            if (comptime instrument_map) {
                mapInstrumentationOnRelease(@intFromPtr(mut), mut.len);
            }
            mut.bufferFreeDeep();
        }

        pub fn arcReleaseDeep(allocator: std.mem.Allocator, ptr: *const Self) void {
            _ = allocator;
            release(@as(?*const Self, ptr));
        }

        // -------------------------------------------------------------------
        // Clone helpers (deep-retain-children vs move-children)
        // -------------------------------------------------------------------

        fn cloneBufferRetainingChildren(self: *const Self, new_capacity: u32, creation_callsite: u64) ?*Self {
            std.debug.assert(std.math.isPowerOfTwo(new_capacity));
            std.debug.assert(new_capacity >= self.len);
            const fresh = bufferAlloc(new_capacity, self.hash_seed, creation_callsite) orelse return null;
            dense_map_retaining_clone_total += 1;
            dense_map_retaining_clone_bytes += bufferSize(new_capacity, new_capacity);

            const old_entries = self.entriesPtr();
            const new_entries = fresh.entriesPtr();
            for (0..self.len) |i| {
                new_entries[i] = old_entries[i];
                retainEntryKey(new_entries[i].key);
                retainEntryValue(new_entries[i].value);
            }
            fresh.len = self.len;

            if (new_capacity == self.capacity) {
                const old_buckets = self.bucketsPtr();
                const new_buckets = fresh.bucketsPtr();
                for (0..self.capacity) |i| {
                    new_buckets[i] = old_buckets[i];
                }
            } else {
                fresh.rebucketAll();
            }
            return fresh;
        }

        fn cloneBufferMovingChildren(self: *const Self, new_capacity: u32, creation_callsite: u64) ?*Self {
            std.debug.assert(std.math.isPowerOfTwo(new_capacity));
            std.debug.assert(new_capacity >= self.len);
            const fresh = bufferAlloc(new_capacity, self.hash_seed, creation_callsite) orelse return null;

            const old_entries = self.entriesPtr();
            const new_entries = fresh.entriesPtr();
            for (0..self.len) |i| {
                new_entries[i] = old_entries[i];
            }
            fresh.len = self.len;

            if (new_capacity == self.capacity) {
                const old_buckets = self.bucketsPtr();
                const new_buckets = fresh.bucketsPtr();
                for (0..self.capacity) |i| {
                    new_buckets[i] = old_buckets[i];
                }
            } else {
                fresh.rebucketAll();
            }
            return fresh;
        }

        fn rebucketAll(self: *Self) void {
            const len = self.len;
            for (0..len) |i| {
                const entry_idx: u32 = @intCast(i);
                const entry = self.entryAt(entry_idx);
                self.installBucket(entry.hash, entry_idx);
            }
        }

        // -------------------------------------------------------------------
        // Hash / probe helpers
        // -------------------------------------------------------------------

        inline fn hashKey(self: *const Self, key: K) u64 {
            if (K == Term) return hashTerm(self.hash_seed, key);
            return Wyhash.hash(self.hash_seed, key);
        }

        inline fn initialProbe(h: u64) u32 {
            const fp: u32 = @intCast(h >> 56);
            return DENSE_MAP_DIST_INC | fp;
        }

        inline fn homeSlot(self: *const Self, h: u64) u32 {
            const mask: u32 = self.capacity - 1;
            return @as(u32, @truncate(h)) & mask;
        }

        inline fn nextSlot(self: *const Self, slot: u32) u32 {
            const mask: u32 = self.capacity - 1;
            return (slot + 1) & mask;
        }

        // -------------------------------------------------------------------
        // Lookup
        // -------------------------------------------------------------------

        fn findEntry(map: ?*const Self, key: K) ?u32 {
            const self = map orelse return null;
            if (self.len == 0) return null;
            const h = self.hashKey(key);
            var probe = initialProbe(h);
            var slot = self.homeSlot(h);
            const buckets = self.bucketsPtr();
            const entries = self.entriesPtr();
            while (true) {
                const b = buckets[slot];
                if (b.dist_and_fingerprint == DENSE_MAP_EMPTY) return null;
                if (b.dist_and_fingerprint < probe) return null;
                if (b.dist_and_fingerprint == probe) {
                    const e = &entries[b.entry_idx];
                    if (e.hash == h and keysEqual(e.key, key)) return b.entry_idx;
                }
                probe += DENSE_MAP_DIST_INC;
                slot = self.nextSlot(slot);
            }
        }

        pub fn hasKey(map: ?*const Self, key: K) bool {
            if (map) |m| {
                if (m.capacity == 0) @panic("Map.hasKey: received MapIter cell; iter cells are only valid as Map.next state");
                if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(m));
            }
            return findEntry(map, key) != null;
        }

        pub fn get(map: ?*const Self, key: K, default: V) V {
            if (map) |m| {
                if (m.capacity == 0) @panic("Map.get: received MapIter cell; iter cells are only valid as Map.next state");
                if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(m));
            }
            const self = map orelse {
                retainEntryValue(default);
                return default;
            };
            const idx = findEntry(self, key) orelse {
                retainEntryValue(default);
                return default;
            };
            const value = self.entryAtConst(idx).value;
            retainEntryValue(value);
            return value;
        }

        /// Vestigial helper kept for HAMT-era callers that hardcoded a
        /// `[]const u8` default into the result. The legacy implementation
        /// always returned the default; we preserve the behaviour.
        pub fn getStr(map: ?*const Self, key: K, default: []const u8) []const u8 {
            _ = key;
            if (map) |m| {
                if (m.capacity == 0) @panic("Map.getStr: received MapIter cell; iter cells are only valid as Map.next state");
                if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(m));
            }
            return default;
        }

        // -------------------------------------------------------------------
        // Insert
        // -------------------------------------------------------------------

        pub fn put(map: ?*const Self, key: K, value: V) ?*const Self {
            if (map) |m| {
                if (m.capacity == 0) @panic("Map.put: received MapIter cell; iter cells are only valid as Map.next state");
            }
            const callsite = @returnAddress();
            if (comptime instrument_map) {
                if (map) |m| {
                    const ctx = mapInstrumentationBumpMutation(@intFromPtr(m), .put);
                    mapInstrumentationSetParent(ctx.lineage_id, ctx.instance_id);
                    defer mapInstrumentationClearParent();
                    const result = putInner(map, key, value, callsite);
                    if (ctx.had_share_event) {
                        if (result) |r| {
                            if (@intFromPtr(r) != @intFromPtr(m)) {
                                mapInstrumentationNotePostShareMutation(@intFromPtr(m));
                            }
                        }
                    }
                    return result;
                }
            }
            return putInner(map, key, value, callsite);
        }

        fn putInner(map: ?*const Self, key: K, value: V, callsite: u64) ?*const Self {
            if (map == null) {
                const fresh = bufferAlloc(DENSE_MAP_INITIAL_CAPACITY, Wyhash.nextSeed(), callsite) orelse return null;
                _ = putInPlaceInsert(fresh, key, value);
                return fresh;
            }
            const self = map.?;

            // Phase 4 (dense Map): refcount-aware fast path.
            //
            // When the caller has transferred ownership of `self`
            // (refcount == 1), mutate the buffer in place and return
            // the same pointer (or a resized buffer with children
            // moved over verbatim). When `self` is shared
            // (refcount > 1), fall back to the deep-retain clone path
            // so the original map stays valid. This is the central
            // optimisation behind the dense Map design — in working-
            // dictionary patterns the receiver is uniquely owned
            // essentially every time, so the fast path collapses
            // repeated put/delete into a stream of in-place mutations
            // with no allocation churn.
            //
            // The codegen's owned-mutating call-site rewrite (in
            // `arc_ownership.rewriteOwnedConsumeBuiltinSites` and
            // `rewriteOwnedConsumeSites` plus the param convention
            // promotion in `arc_param_convention.shouldPromoteSlot`)
            // ensures that last-use Map.put calls reach this function
            // with refcount == 1.
            dense_map_mut_calls_total += 1;
            if (self.header.count() == 1) {
                dense_map_rc1_fast_path_total += 1;
                const mut: *Self = @constCast(self);
                return putInPlace(mut, key, value, callsite);
            }

            const target_cap = pickCapacity(self.capacity, self.len + 1);
            const clone = cloneBufferRetainingChildren(self, target_cap, callsite) orelse return null;
            return putInPlace(clone, key, value, callsite);
        }

        fn putInPlace(target: *Self, key: K, value: V, callsite: u64) ?*const Self {
            if (findEntry(target, key)) |existing_idx| {
                const allocator = std.heap.c_allocator;
                const entry = target.entryAt(existing_idx);
                retainEntryValue(value);
                releaseEntryValue(entry.value, allocator);
                entry.value = value;
                return target;
            }

            const old_cap = target.capacity;
            const new_cap = pickCapacity(old_cap, target.len + 1);
            var dest: *Self = target;
            if (new_cap != old_cap) {
                dest = cloneBufferMovingChildren(target, new_cap, callsite) orelse return null;
                // Notify the instrumentation harness that the old
                // buffer is being retired before its zero-transition
                // release. The rc-1 fast-path resize transfers
                // children to a fresh buffer and then frees the old
                // one shallowly (no `release()` call), so the standard
                // `mapInstrumentationOnRelease` hook never fires for
                // these instances. Without this notification the
                // differential classifier would see every resize as a
                // class-V "lost" instance instead of the class-S
                // "single owner mutated in place" shape it actually
                // represents.
                if (comptime instrument_map) {
                    mapInstrumentationOnRelease(@intFromPtr(target), target.len);
                }
                target.bufferFreeShallow();
            }
            _ = putInPlaceInsert(dest, key, value);
            return dest;
        }

        fn putInPlaceInsert(dest: *Self, key: K, value: V) *Self {
            const h = dest.hashKey(key);
            const new_idx: u32 = dest.len;
            std.debug.assert(new_idx < dest.entry_cap);
            const entries = dest.entriesPtr();
            retainEntryKey(key);
            retainEntryValue(value);
            entries[new_idx] = .{ .hash = h, .key = key, .value = value };
            dest.len = new_idx + 1;
            dest.installBucket(h, new_idx);
            return dest;
        }

        // -------------------------------------------------------------------
        // Delete (swap-remove + Robin Hood backshift)
        // -------------------------------------------------------------------

        pub fn delete(map: ?*const Self, key: K) ?*const Self {
            if (map) |m| {
                if (m.capacity == 0) @panic("Map.delete: received MapIter cell; iter cells are only valid as Map.next state");
            }
            const callsite = @returnAddress();
            if (comptime instrument_map) {
                if (map) |m| {
                    const ctx = mapInstrumentationBumpMutation(@intFromPtr(m), .delete);
                    mapInstrumentationSetParent(ctx.lineage_id, ctx.instance_id);
                    defer mapInstrumentationClearParent();
                    const result = deleteInner(map, key, callsite);
                    if (ctx.had_share_event) {
                        if (result) |r| {
                            if (@intFromPtr(r) != @intFromPtr(m)) {
                                mapInstrumentationNotePostShareMutation(@intFromPtr(m));
                            }
                        } else {
                            mapInstrumentationNotePostShareMutation(@intFromPtr(m));
                        }
                    }
                    return result;
                }
            }
            return deleteInner(map, key, callsite);
        }

        fn deleteInner(map: ?*const Self, key: K, callsite: u64) ?*const Self {
            const self = map orelse return null;

            // Phase 4 (dense Map): refcount-aware fast path. On unique
            // ownership we mutate the live buffer in place (with
            // `deleteFoundInPlace` deep-releasing the removed entry's
            // K/V). On absent-key we still return the same handle
            // without allocating. On shared ownership we deep-retain
            // clone, then run the same swap-remove on the clone — the
            // source map stays unchanged.
            if (self.header.count() == 1) {
                const mut: *Self = @constCast(self);
                if (findEntry(mut, key)) |found_entry_idx| {
                    deleteFoundInPlace(mut, found_entry_idx);
                }
                return mut;
            }

            const clone = cloneBufferRetainingChildren(self, self.capacity, callsite) orelse return null;
            if (findEntry(clone, key)) |found_entry_idx| {
                deleteFoundInPlace(clone, found_entry_idx);
            }
            return clone;
        }

        fn deleteFoundInPlace(target: *Self, found_entry_idx: u32) void {
            const old_len = target.len;
            std.debug.assert(old_len > 0);

            const target_hash = target.entryAtConst(found_entry_idx).hash;
            const deleted_slot = target.findBucketSlotForEntry(target_hash, found_entry_idx);

            const allocator = std.heap.c_allocator;
            {
                const removed_entry = target.entryAtConst(found_entry_idx).*;
                releaseEntryKey(removed_entry.key, allocator);
                releaseEntryValue(removed_entry.value, allocator);
            }

            if (found_entry_idx != old_len - 1) {
                const tail_idx: u32 = old_len - 1;
                const tail_entry = target.entryAt(tail_idx).*;

                const tail_slot = target.findBucketSlotForEntry(tail_entry.hash, tail_idx);
                target.bucketAt(tail_slot).entry_idx = found_entry_idx;

                target.entryAt(found_entry_idx).* = tail_entry;
            }

            target.len = old_len - 1;

            const buckets = target.bucketsPtr();
            buckets[deleted_slot] = .{ .dist_and_fingerprint = DENSE_MAP_EMPTY, .entry_idx = 0 };
            var cur = deleted_slot;
            while (true) {
                const nxt = target.nextSlot(cur);
                const nxt_dnf = buckets[nxt].dist_and_fingerprint;
                if (nxt_dnf == DENSE_MAP_EMPTY) break;
                const nxt_dist = nxt_dnf >> 8;
                if (nxt_dist <= 1) break;
                const fp = nxt_dnf & DENSE_MAP_FINGERPRINT_MASK;
                const new_dist = nxt_dist - 1;
                buckets[cur] = .{
                    .dist_and_fingerprint = (new_dist << 8) | fp,
                    .entry_idx = buckets[nxt].entry_idx,
                };
                buckets[nxt] = .{ .dist_and_fingerprint = DENSE_MAP_EMPTY, .entry_idx = 0 };
                cur = nxt;
            }
        }

        // -------------------------------------------------------------------
        // Merge
        // -------------------------------------------------------------------

        pub fn merge(map_a: ?*const Self, map_b: ?*const Self) ?*const Self {
            if (map_a) |m| {
                if (m.capacity == 0) @panic("Map.merge: received MapIter cell; iter cells are only valid as Map.next state: map_a");
            }
            if (map_b) |m| {
                if (m.capacity == 0) @panic("Map.merge: received MapIter cell; iter cells are only valid as Map.next state: map_b");
            }
            if (comptime instrument_map) {
                if (map_a) |m| _ = mapInstrumentationBumpMutation(@intFromPtr(m), .merge);
                if (map_b) |m| _ = mapInstrumentationBumpMutation(@intFromPtr(m), .merge);
            }

            if (map_a == null and map_b == null) return null;
            if (map_a == null) return retain(map_b);
            if (map_b == null) return retain(map_a);

            // Both non-null: fold each entry of `b` into a result whose
            // initial state is `a` retained. Each `put` either returns
            // the same handle (rc-1 fast path on a unique-owner clone
            // we just made) or a fresh clone, in which case we release
            // the prior intermediate.
            var result: ?*const Self = retain(map_a);
            const b = map_b.?;
            const b_len = b.len;
            const b_entries = b.entriesPtr();
            var i: u32 = 0;
            while (i < b_len) : (i += 1) {
                const entry = b_entries[i];
                const next_result = put(result, entry.key, entry.value) orelse {
                    release(result);
                    return null;
                };
                if (next_result != result) {
                    release(result);
                    result = next_result;
                }
            }
            return result;
        }

        // -------------------------------------------------------------------
        // uniqueness unchecked-mutation variants
        //
        // These functions mutate the receiver in place WITHOUT loading
        // `header.count()`. The caller (codegen) must have proven via
        // uniqueness that the receiver is statically uniquely owned (refcount
        // == 1 by construction).
        //
        // Safety contract:
        //   * `map` (or `map_a` for merge) must be non-null.
        //   * The receiver's `header.ref_count` must be exactly 1.
        //
        // Violating either condition is undefined behavior. The uniqueness
        // verifier in `arc_verifier.zig` enforces both at every call
        // site. Tests may invoke these directly; production callers
        // must always route through uniqueness.
        //
        // Refcount semantics: the receiver enters with rc=1 and
        // returns with rc=1. The unchecked variants never bump or
        // decrement the cell's refcount; on a resize (put that
        // breaches the load factor) the function allocates a fresh
        // buffer with rc=1 and transfers children verbatim with no
        // per-entry retain — the caller's +1 transfers from the old
        // buffer to the new without any refcount bookkeeping.
        // -------------------------------------------------------------------

        /// Like `put`, but skips the rc==1 check. Caller must have
        /// proven uniqueness via uniqueness. See safety contract above.
        pub fn put_owned_unchecked(map: ?*const Self, key: K, value: V) ?*const Self {
            if (map) |m| {
                if (m.capacity == 0) @panic("Map.put_owned_unchecked: received MapIter cell; iter cells are only valid as Map.next state");
            }
            const callsite = @returnAddress();
            dense_map_mut_calls_total += 1;
            dense_map_unchecked_total += 1;
            if (map == null) {
                // Symmetric to `putInner`'s null path: allocate a
                // fresh buffer with rc=1 and insert. The unchecked
                // contract assumes a non-null receiver in steady
                // state, but supporting null here keeps the empty-
                // map seeding pattern (`Map.new()` returns null)
                // working under uniqueness without forcing the codegen to
                // emit a null check before the unchecked call.
                const fresh = bufferAlloc(DENSE_MAP_INITIAL_CAPACITY, Wyhash.nextSeed(), callsite) orelse return null;
                _ = putInPlaceInsert(fresh, key, value);
                return fresh;
            }
            const self = map.?;
            const mut: *Self = @constCast(self);
            return putInPlace(mut, key, value, callsite);
        }

        /// Like `delete`, but skips the rc==1 check. Caller must
        /// have proven uniqueness via uniqueness. See safety contract above.
        pub fn delete_owned_unchecked(map: ?*const Self, key: K) ?*const Self {
            if (map) |m| {
                if (m.capacity == 0) @panic("Map.delete_owned_unchecked: received MapIter cell; iter cells are only valid as Map.next state");
            }
            dense_map_mut_calls_total += 1;
            dense_map_unchecked_total += 1;
            const self = map orelse return null;
            const mut: *Self = @constCast(self);
            if (findEntry(mut, key)) |found_entry_idx| {
                deleteFoundInPlace(mut, found_entry_idx);
            }
            return mut;
        }

        /// Like `merge`, but skips the rc==1 check on `map_a`. Caller
        /// must have proven uniqueness of `map_a` via uniqueness. `map_b` is
        /// BORROWED — its entries' keys and values are deep-retained
        /// as they're copied into A. See safety contract above.
        ///
        /// Implementation: the unchecked merge folds B's entries into
        /// A in place via `put_owned_unchecked`. Each `put` either
        /// keeps the same buffer or grows in place (still A's +1).
        /// The result is always A's pointer (possibly after a
        /// transparent resize).
        pub fn merge_owned_unchecked(map_a: ?*const Self, map_b: ?*const Self) ?*const Self {
            if (map_a) |m| {
                if (m.capacity == 0) @panic("Map.merge_owned_unchecked: received MapIter cell; iter cells are only valid as Map.next state: map_a");
            }
            if (map_b) |m| {
                if (m.capacity == 0) @panic("Map.merge_owned_unchecked: received MapIter cell; iter cells are only valid as Map.next state: map_b");
            }
            if (map_a == null and map_b == null) return null;
            if (map_b == null) return map_a;
            if (map_a == null) {
                // No A to mutate; produce a fresh deep-retain clone
                // of B with rc=1.
                const callsite = @returnAddress();
                return cloneBufferRetainingChildren(map_b.?, map_b.?.capacity, callsite);
            }

            var result: ?*const Self = map_a;
            const b = map_b.?;
            const b_len = b.len;
            const b_entries = b.entriesPtr();
            var i: u32 = 0;
            while (i < b_len) : (i += 1) {
                const entry = b_entries[i];
                const next_result = put_owned_unchecked(result, entry.key, entry.value) orelse {
                    return null;
                };
                // Under uniqueness, put_owned_unchecked either
                // returns the same pointer (in-place) or a fresh
                // buffer with the previous A's children moved over.
                // Either way, no release on the prior result is
                // needed — the prior buffer was either reused (same
                // pointer) or freed shallowly inside the resize path.
                result = next_result;
            }
            return result;
        }

        fn findBucketSlotForEntry(self: *Self, h: u64, entry_idx: u32) u32 {
            var probe = initialProbe(h);
            var slot = self.homeSlot(h);
            const buckets = self.bucketsPtr();
            while (true) {
                const b = buckets[slot];
                std.debug.assert(b.dist_and_fingerprint != DENSE_MAP_EMPTY);
                std.debug.assert(b.dist_and_fingerprint >= probe);
                if (b.dist_and_fingerprint == probe and b.entry_idx == entry_idx) {
                    return slot;
                }
                probe += DENSE_MAP_DIST_INC;
                slot = self.nextSlot(slot);
            }
        }

        fn installBucket(self: *Self, h: u64, entry_idx: u32) void {
            var probe = initialProbe(h);
            var slot = self.homeSlot(h);
            var cur_entry_idx = entry_idx;
            const buckets = self.bucketsPtr();
            while (true) {
                const dnf = buckets[slot].dist_and_fingerprint;
                if (dnf == DENSE_MAP_EMPTY) {
                    buckets[slot] = .{ .dist_and_fingerprint = probe, .entry_idx = cur_entry_idx };
                    return;
                }
                if (dnf < probe) {
                    const displaced = buckets[slot];
                    buckets[slot] = .{ .dist_and_fingerprint = probe, .entry_idx = cur_entry_idx };
                    probe = displaced.dist_and_fingerprint;
                    cur_entry_idx = displaced.entry_idx;
                }
                probe += DENSE_MAP_DIST_INC;
                slot = self.nextSlot(slot);
            }
        }

        fn pickCapacity(old_cap: u32, target_len: u32) u32 {
            var cap: u32 = if (old_cap == 0) DENSE_MAP_INITIAL_CAPACITY else old_cap;
            while (target_len * DENSE_MAP_LOAD_DEN > cap * DENSE_MAP_LOAD_NUM) {
                cap *= 2;
            }
            return cap;
        }

        // -------------------------------------------------------------------
        // Key equality / Term hashing
        // -------------------------------------------------------------------

        inline fn keysEqual(a: K, b: K) bool {
            if (K == Term) return Term.eql(a, b);
            const ti = @typeInfo(K);
            return switch (ti) {
                .int, .comptime_int, .bool => a == b,
                .pointer => |p| if (p.size == .slice and p.child == u8)
                    std.mem.eql(u8, a, b)
                else
                    a == b,
                else => @compileError("Map: unsupported key type " ++ @typeName(K)),
            };
        }

        fn hashTerm(seed: u64, t: Term) u64 {
            return switch (t) {
                .int => |v| Wyhash.hashU64(seed, @bitCast(v)),
                .float => |v| Wyhash.hashU64(seed, @bitCast(v)),
                .str => |v| Wyhash.hashBytes(seed, v),
                .bool_val => |v| Wyhash.hashU32(seed, if (v) 1 else 0),
                .atom => |v| Wyhash.hashU32(seed, v),
                .nil => Wyhash.hashU64(seed, 0),
                .list => |v| Wyhash.hashU64(seed, @intFromPtr(v)),
                .map => |v| Wyhash.hashU64(seed, @intFromPtr(v)),
                .tuple => |elems| blk: {
                    var h: u64 = seed;
                    for (elems) |elem| {
                        h ^= hashTerm(h, elem);
                    }
                    break :blk h;
                },
            };
        }

        // -------------------------------------------------------------------
        // ARC child walkers
        // -------------------------------------------------------------------

        inline fn releaseEntryKey(key: K, allocator: std.mem.Allocator) void {
            releaseAnyShape(K, key, allocator);
        }

        inline fn releaseEntryValue(value: V, allocator: std.mem.Allocator) void {
            releaseAnyShape(V, value, allocator);
        }

        inline fn retainEntryKey(key: K) void {
            retainAnyShape(K, key);
        }

        inline fn retainEntryValue(value: V) void {
            retainAnyShape(V, value);
        }

        fn releaseAnyShape(comptime T: type, value: T, allocator: std.mem.Allocator) void {
            switch (@typeInfo(T)) {
                .optional => |opt| {
                    if (value) |inner| releaseAnyShape(opt.child, inner, allocator);
                },
                .pointer => |p| {
                    if (p.size == .one) {
                        ArcRuntime.releaseArcAny(p.child, allocator, @constCast(value));
                    }
                },
                .@"struct" => {
                    ArcRuntime.releaseChildrenAny(T, allocator, value);
                },
                else => {},
            }
        }

        fn retainAnyShape(comptime T: type, value: T) void {
            switch (@typeInfo(T)) {
                .optional => |opt| {
                    if (value) |inner| retainAnyShape(opt.child, inner);
                },
                .pointer => |p| {
                    if (p.size == .one) {
                        ArcRuntime.retainAnyPersistent(@as(*const p.child, @constCast(value)));
                    }
                },
                .@"struct" => {
                    ArcRuntime.retainChildrenAny(T, value);
                },
                else => {},
            }
        }

        // -------------------------------------------------------------------
        // Iteration API
        // -------------------------------------------------------------------

        pub fn keys(map: ?*const Self) ?*const List(K) {
            const self = map orelse return null;
            if (self.capacity == 0) @panic("Map.keys: received MapIter cell; iter cells are only valid as Map.next state");
            if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(self));
            const len = self.len;
            if (len == 0) return null;
            const entries = self.entriesPtr();
            var result: ?*const List(K) = null;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                retainEntryKey(entries[i].key);
                result = List(K).push(result, entries[i].key);
            }
            return result;
        }

        pub fn values(map: ?*const Self) ?*const List(V) {
            const self = map orelse return null;
            if (self.capacity == 0) @panic("Map.values: received MapIter cell; iter cells are only valid as Map.next state");
            if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(self));
            const len = self.len;
            if (len == 0) return null;
            const entries = self.entriesPtr();
            var result: ?*const List(V) = null;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                retainEntryValue(entries[i].value);
                result = List(V).push(result, entries[i].value);
            }
            return result;
        }

        /// Iteration protocol. Receives the receiver as a BORROWED
        /// reference — `Map.next` is NOT on the consume list, so
        /// the input's refcount is unaffected by this call.
        ///
        /// Three cases:
        ///
        ///   * map == null OR len == 0:
        ///       Source is empty. Return DONE with null state.
        ///
        ///   * map is a real Map (capacity != 0):
        ///       First step. Allocate a fresh `MapIter` cell that
        ///       retains the source. Return CONT with the iter as
        ///       next state. The caller's existing reference to
        ///       `map` is left untouched; the iter holds its own
        ///       +1 on `map`.
        ///
        ///   * map is an iter cell (capacity == 0):
        ///       Advance the cursor in place; the iter's rc is
        ///       unchanged. Return CONT with the iter as next
        ///       state, OR DONE when the cursor reaches the end —
        ///       on DONE the iter releases itself before returning
        ///       so iter cells produced by full iteration are
        ///       leak-free (see `MapIter.advanceFromMapPtr`).
        ///
        /// Refcount discipline: iteration to completion is
        /// leak-free — `advanceFromMapPtr` self-releases the iter
        /// on the DONE step, which dispatches back through
        /// `Map.release`'s iter-cell branch to free the slab cell
        /// and drop the source-map retain. Partial-iteration
        /// patterns (e.g. `Enum.first`, which only takes one step
        /// and discards `state`) leak one iter cell + a +1 on the
        /// source map per call. That leak is bounded by the number
        /// of partial-iteration call sites and is negligible in
        /// practice (~40 bytes per call).
        pub fn next(map: ?*const Self) struct {
            u32,
            struct { K, V },
            ?*const Self,
        } {
            if (map == null) {
                return .{ ATOM_DONE, .{ defaultK(), defaultV() }, null };
            }
            const self = map.?;
            // Iter-cell discriminator. A `MapIter` cell shares its
            // first 24 bytes with `Map.Self` (header + len + capacity
            // + entry_cap + hash_seed) but always sets `capacity = 0`.
            // Real maps have `capacity >= DENSE_MAP_INITIAL_CAPACITY`
            // so `capacity == 0` is unambiguous.
            if (self.capacity == 0) {
                return MapIter(K, V).advanceFromMapPtr(self);
            }
            if (self.len == 0) {
                return .{ ATOM_DONE, .{ defaultK(), defaultV() }, null };
            }
            // Real-map first step: allocate a fresh `MapIter` cell
            // that retains `self`. Each subsequent step advances the
            // cursor IN PLACE on the iter — O(1) work per step and
            // one allocation across the whole walk (versus the
            // always-clone O(N²) fallback from commit 89775b0).
            const first = self.entryAtConst(0).*;
            retainEntryKey(first.key);
            retainEntryValue(first.value);

            const iter = MapIter(K, V).create(self) orelse {
                releaseEntryKey(first.key, std.heap.c_allocator);
                releaseEntryValue(first.value, std.heap.c_allocator);
                return .{ ATOM_DONE, .{ defaultK(), defaultV() }, null };
            };
            iter.next_idx = 1;
            return .{ ATOM_CONT, .{ first.key, first.value }, iter.asMapPtr() };
        }

        inline fn defaultK() K {
            if (K == Term) return Term{ .nil = {} };
            return std.mem.zeroes(K);
        }

        inline fn defaultV() V {
            if (V == Term) return Term{ .nil = {} };
            return std.mem.zeroes(V);
        }

        // -------------------------------------------------------------------
        // fromPairs — bulk construction from parallel arrays
        // -------------------------------------------------------------------

        pub fn fromPairs(key_ids: []const K, vals: []const V, count: u32) ?*const Self {
            if (count == 0) return null;
            const callsite = @returnAddress();
            const cap = pickCapacity(0, count);
            const self = bufferAlloc(cap, Wyhash.nextSeed(), callsite) orelse return null;
            for (0..@intCast(count)) |i| {
                _ = putInPlaceInsert(self, key_ids[i], vals[i]);
            }
            return self;
        }

        // -------------------------------------------------------------------
        // Reductions
        // -------------------------------------------------------------------

        pub fn enumReduceSimple(map: ?*const Self, initial: i64, callback: anytype) i64 {
            if (map == null) return initial;
            const self = map.?;
            if (self.capacity == 0) @panic("Map.enumReduceSimple: received MapIter cell; iter cells are only valid as Map.next state");
            var acc: i64 = initial;
            const entries = self.entriesPtr();
            for (0..self.len) |i| {
                acc = callback(acc, @as(i64, @intCast(entries[i].key)), entries[i].value);
            }
            return acc;
        }

        pub fn enumReduceValues(map: ?*const Self, initial: i64, callback: anytype) i64 {
            if (map == null) return initial;
            const self = map.?;
            if (self.capacity == 0) @panic("Map.enumReduceValues: received MapIter cell; iter cells are only valid as Map.next state");
            var acc: i64 = initial;
            const entries = self.entriesPtr();
            for (0..self.len) |i| {
                acc = callback(acc, entries[i].value);
            }
            return acc;
        }
    }; // end of returned struct
} // end of Map

// ============================================================
// MapIter — cursor-based iterator for `Map(K, V)`.
//
// Why a separate type:
//   * Iteration must be O(N) total — the prior strategy of
//     cloning the whole Map on every step (commit 89775b0) was
//     O(N²) and catastrophic for large maps.
//   * The source Map MUST stay unchanged across the iteration —
//     the protocol contract demands functional semantics, and
//     `print_freq` in k-nucleotide re-reads the map after
//     `Enum.reduce` walks it via the Enumerable protocol.
//
// Design:
//   * `MapIter(K, V)` is its own ARC'd cell that retains a const
//     pointer to the source map. Each iter step yields the entry
//     at `next_idx` (with K/V deep-retained for the caller),
//     advances `next_idx` IN PLACE on the iter, and returns the
//     iter cell as the next state.
//   * The iter cell shares its first 24 bytes with `Map(K, V)`
//     (header + len + capacity + entry_cap + hash_seed) so the
//     value can be returned typed as `?*const Map(K, V)` — the
//     Zap-level Enumerable protocol's third tuple slot stays
//     `%{K=>V}` and dispatch resumes through `Map.next`. The
//     iter is distinguished from a real Map by `capacity == 0`;
//     real maps always have
//     `capacity >= DENSE_MAP_INITIAL_CAPACITY`. Both structs are
//     declared `extern struct` so Zig preserves field order and
//     the discriminator check lands at the same byte offset.
//
// Why share the layout (vs. a separate Zap type):
//   * Adding a separate `MapIter` Zap type would force the
//     for-comprehension's generated `__for_N(state)` helper to
//     accept two different param types (Map on the first call,
//     MapIter on subsequent recursive calls). The type system
//     doesn't support that polymorphism today.
//   * Sharing the layout costs 12 bytes per iter cell (the
//     unused `len_unused` / `entry_cap_unused` / `hash_seed_unused`
//     slots). Iter cells are short-lived and pool-allocated; the
//     overhead is negligible vs. correctness + simplicity.
//
// Cursor-mutation soundness:
//   * `Map.next` is called via the Enumerable protocol's recursive
//     pattern. Each step's returned iter is immediately consumed
//     by the next step — there is no aliasing of the iter cell
//     across a single iteration. So mutating `next_idx` in place
//     is sound regardless of the iter's refcount.
//   * The cursor-advance decision does NOT consult the iter's rc.
//     The bug in `Map.delete` (commit 89775b0) was that
//     `header.count() == 1` was misread under elided borrow;
//     MapIter sidesteps that entire failure mode by never reading
//     its own refcount for behavior selection.
//
// Refcount discipline:
//   * `Map.next(real_map)` allocates an iter via `MapIter.create`,
//     which retains `real_map` (+1). The iter starts at rc=1.
//   * `Map.next(iter)` advances `iter.next_idx` and returns the
//     same iter pointer — the iter's rc is unchanged.
//   * On the DONE step, `advanceFromMapPtr` self-releases the
//     iter (which routes back through `Map.release` ->
//     `releaseFromMapPtr` via the iter-cell discriminator). On
//     rc=0 the cell returns to its slab pool and the source
//     map's +1 is dropped — net rc change across the whole
//     iteration is zero.
// ============================================================

pub fn MapIter(comptime K: type, comptime V: type) type {
    // `extern struct` pins the field order so the iter's first 24
    // bytes alias `Map(K, V)`'s header layout. See `Map(K, V)` for
    // the rationale.
    return extern struct {
        const Self = @This();
        const MapT = Map(K, V);

        // First 24 bytes — binary-compatible with `Map(K, V).Self`'s
        // header prefix. Read-only after construction (zeroed by
        // `create`) but the field names match so the discriminator
        // check `capacity == 0` in `Map.next`/`Map.release` works.

        /// ARC refcount. Initialised to 1 by `create`.
        header: ArcHeader,
        /// Unused (zeroed). Matches `Map.Self.len` for layout
        /// compatibility — Zap callers must NEVER read `Map.size`
        /// on the third tuple slot of `Map.next`; that field is
        /// load-bearing only for real Map cells.
        len_unused: u32,
        /// Iter discriminator — ALWAYS 0. Real Maps have
        /// `capacity >= DENSE_MAP_INITIAL_CAPACITY` (= 8). See the
        /// `Map.Self.capacity` doc comment for the full rationale.
        capacity: u32,
        /// Unused (zeroed). Matches `Map.Self.entry_cap`.
        entry_cap_unused: u32,
        /// Unused (zeroed). Matches `Map.Self.hash_seed`.
        hash_seed_unused: u64,

        // Iter-specific fields — beyond the 24-byte Map prefix.

        /// Retained pointer to the source map. NULL only when the
        /// source was empty (in which case `Map.next` returns DONE
        /// directly without allocating an iter). The iter owns +1
        /// on this pointer's refcount; on `release` zero-transition,
        /// the source is released back.
        source_map: ?*const MapT,
        /// Next entry slot index to yield. In [0, source_map.len].
        /// `next_idx == source_map.len` ⇒ iteration done.
        next_idx: u32,

        // Lock the cell size so future field-ordering edits cannot
        // silently change the cell layout. 40 bytes = 4 (header)
        // + 4 (len_unused) + 4 (capacity) + 4 (entry_cap_unused) +
        // 8 (hash_seed_unused) + 8 (source_map) + 4 (next_idx) +
        // 4 (implicit tail pad to 8-byte alignment).
        comptime {
            std.debug.assert(@sizeOf(Self) == 40);
        }

        /// Allocate a fresh iter cell that retains `source`. Returns
        /// the iter with rc=1, `next_idx = 0`, and `source.rc += 1`.
        /// The iter owns the +1 on `source` for its entire lifetime;
        /// on rc=0 the `releaseFromMapPtr` path drops that +1.
        ///
        /// Routes the source-map retain through `ArcRuntime.headerRetain`
        /// rather than `MapT.retain` so the Map instrumentation hook is
        /// not triggered on iter creation (matches pre-Phase-2 behavior
        /// where the bare `header.retain()` skipped the hook).
        ///
        /// Phase 4.x: cell storage routes through
        /// `ArcRuntime.allocInlineHeaderCell` (a thin wrapper over the
        /// active manager's `core.allocate`) instead of a per-(K, V)
        /// typed slab pool. The manager observes every iter allocation
        /// — Tracking managers see iter cells through the same hook
        /// as every other allocation.
        pub fn create(source: *const MapT) ?*Self {
            const mut_source: *MapT = @constCast(source);
            ArcRuntime.headerRetain(&mut_source.header);
            dense_map_iter_alloc_total += 1;

            const cell: *Self = ArcRuntime.allocInlineHeaderCell(Self);
            cell.* = .{
                .header = ArcHeader.init(),
                .len_unused = 0,
                .capacity = 0,
                .entry_cap_unused = 0,
                .hash_seed_unused = 0,
                .source_map = source,
                .next_idx = 0,
            };
            return cell;
        }

        /// Re-interpret a `?*const MapT` whose `capacity == 0` as a
        /// `?*const Self`. Caller must have already verified the
        /// discriminator — debug builds assert it.
        inline fn fromMapPtr(map_ptr: *const MapT) *Self {
            std.debug.assert(map_ptr.capacity == 0);
            return @ptrCast(@constCast(map_ptr));
        }

        /// Re-interpret this iter as a `?*const Map(K, V)` so it can
        /// flow through the Enumerable protocol's third tuple slot
        /// without a Zap-level type change.
        pub inline fn asMapPtr(self: *Self) ?*const MapT {
            return @ptrCast(self);
        }

        /// Advance the cursor and yield the next entry, or DONE.
        /// Receives a `?*const MapT` because that's the type
        /// `Map.next`/the Enumerable protocol carries; the
        /// discriminator check has already verified iter-ness.
        ///
        /// Refcount discipline: the iter is BORROWED — `Map.next`
        /// is not on the consume list, so the iter's rc is
        /// unchanged by the borrowed-call ABI. On the CONT path
        /// the iter is returned as `next_state` for the next
        /// recursive helper call; on the DONE path the iter is
        /// RELEASED explicitly here so its slab cell + source-map
        /// reference are freed even when the caller's drop pass
        /// can't see state's last-use (because the
        /// `elideBorrowedPassThroughShares` rewrites at the call
        /// site swallow the post-call release).
        ///
        /// Safety: every Zap iteration pattern (the for-comp
        /// `__for_N` helper, the `Enum.reduce_next` /
        /// `Enum.map_next` shape) discards `state` after the
        /// `{:done, _, _}` arm. The caller does not read `state`
        /// after Map.next returns DONE, so releasing the iter
        /// here cannot cause a use-after-free.
        pub fn advanceFromMapPtr(map_ptr: *const MapT) struct {
            u32,
            struct { K, V },
            ?*const MapT,
        } {
            const self = fromMapPtr(map_ptr);
            const source = self.source_map orelse {
                return .{ ATOM_DONE, .{ defaultK(), defaultV() }, null };
            };
            if (self.next_idx >= source.len) {
                // Iteration complete. Release the iter cell — this
                // routes back into `Map.release` -> `releaseFromMapPtr`
                // via the `capacity == 0` discriminator. On rc=0 the
                // iter cell is returned to its slab pool and the
                // source map's rc is dropped by 1 (balancing the
                // retain done by `create`).
                MapT.release(map_ptr);
                return .{ ATOM_DONE, .{ defaultK(), defaultV() }, null };
            }
            const entry = source.entryAtConst(self.next_idx).*;
            MapT.retainEntryKey(entry.key);
            MapT.retainEntryValue(entry.value);
            dense_map_iter_advance_total += 1;
            self.next_idx += 1;
            return .{ ATOM_CONT, .{ entry.key, entry.value }, map_ptr };
        }

        /// Release path entered from `Map.release` when its argument
        /// is identified as an iter cell via `capacity == 0`. Dispatches
        /// the refcount drop through `ArcRuntime.headerRelease`; the
        /// `iterDeepWalk` callback performs the cleanup when the
        /// manager observes the zero-transition (drop the retained
        /// source-map reference and return the cell to its slab pool).
        pub fn releaseFromMapPtr(map_ptr: *const MapT) void {
            const self = fromMapPtr(map_ptr);
            ArcRuntime.headerRelease(&self.header, iterDeepWalk);
        }

        /// Deep-walk callback invoked by the manager's `release` on
        /// the final zero-transition. Drops the retained source-map
        /// reference and returns the iter cell to the manager via
        /// `core.deallocate`.
        ///
        /// Phase 4.x: the iter cell's slab slot returns through the
        /// active manager's `core.deallocate` slot (via
        /// `ArcRuntime.freeInlineHeaderCell`) instead of a per-(K, V)
        /// typed slab pool's `destroy` method. The manager observes
        /// the free through the same hook it sees every other
        /// `core.deallocate`.
        fn iterDeepWalk(ptr: *anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const source = self.source_map;
            self.source_map = null;
            self.next_idx = 0;
            dense_map_iter_free_total += 1;
            ArcRuntime.freeInlineHeaderCell(Self, self);
            if (source) |src| {
                // The source's `Map.release` handles its own rc;
                // recursively dispatches back through the active
                // manager — the external manager `.o` linked at build
                // time (`src/memory/arc/manager.zig` by default) in
                // production, or `test_only_arc_*` in test builds.
                MapT.release(src);
            }
        }

        inline fn defaultK() K {
            if (K == Term) return Term{ .nil = {} };
            return std.mem.zeroes(K);
        }

        inline fn defaultV() V {
            if (V == Term) return Term{ .nil = {} };
            return std.mem.zeroes(V);
        }
    };
}

// Layout assertions to catch silent struct-prefix drift between
// `Map(K, V).Self` and `MapIter(K, V).Self`. The discriminator
// check `capacity == 0` depends on `Map.capacity` and
// `MapIter.capacity` sitting at the same byte offset. If a future
// edit reorders Map's header fields, the iter cell will silently
// alias a non-`capacity` field and `Map.next` will misroute.
comptime {
    const M = Map(i64, i64);
    const I = MapIter(i64, i64);
    std.debug.assert(@offsetOf(M.Self, "header") == @offsetOf(I, "header"));
    std.debug.assert(@offsetOf(M.Self, "len") == @offsetOf(I, "len_unused"));
    std.debug.assert(@offsetOf(M.Self, "capacity") == @offsetOf(I, "capacity"));
    std.debug.assert(@offsetOf(M.Self, "entry_cap") == @offsetOf(I, "entry_cap_unused"));
    std.debug.assert(@offsetOf(M.Self, "hash_seed") == @offsetOf(I, "hash_seed_unused"));
}

// ============================================================
// Generic List factory — produces monomorphic list types
// for any element type T. Used for string lists, atom lists, etc.
// ============================================================

/// Compile-time default-value builder. Mirrors `std.mem.zeroes` but
/// recurses through aggregates (tuples and structs) instead of bit-zeroing
/// — so types containing `Term` (a tagged union without a zero variant)
/// produce a valid default. Used by `List(T).defaultElement` so list
/// fall-through paths work for heterogeneous keyword-list element types.
fn defaultElementOf(comptime T: type) T {
    if (T == Term) return Term{ .nil = {} };
    const ti = @typeInfo(T);
    switch (ti) {
        .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.fields) |field| {
                @field(result, field.name) = defaultElementOf(field.type);
            }
            return result;
        },
        .optional => return null,
        else => return std.mem.zeroes(T),
    }
}

// ============================================================
// MapHelpers — Operations on map values (anonymous structs of {key, value} entries)
//
// Maps in ZIR are represented as anonymous structs with numeric field names:
//   .{ .@"0" = .{ .key = k0, .value = v0 }, .@"1" = .{ .key = k1, .value = v1 }, ... }
//
// These helpers use @typeInfo + inline for to iterate entries at compile time,
// producing efficient code with no runtime overhead for small maps.
// ============================================================

pub const MapHelpers = struct {
    /// Get a value from a map by key. Returns the value if found, or a default.
    /// Usage: MapHelpers.get(map, key, default)
    pub fn get(map: anytype, key: anytype, default: anytype) @TypeOf(default) {
        const T = @TypeOf(map);
        const info = @typeInfo(T);
        if (info != .@"struct") return default;
        inline for (info.@"struct".fields) |field| {
            const entry = @field(map, field.name);
            const E = @TypeOf(entry);
            const e_info = @typeInfo(E);
            if (e_info == .@"struct") {
                // Check if this entry has key and value fields
                const is_kv_entry = comptime blk: {
                    for (e_info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, "key")) break :blk true;
                    }
                    break :blk false;
                };
                if (is_kv_entry) {
                    if (keysEqual(entry.key, key)) return entry.value;
                }
            }
        }
        return default;
    }

    /// Check if a map contains a key.
    pub fn has_key(map: anytype, key: anytype) bool {
        const T = @TypeOf(map);
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        inline for (info.@"struct".fields) |field| {
            const entry = @field(map, field.name);
            const E = @TypeOf(entry);
            const e_info = @typeInfo(E);
            if (e_info == .@"struct") {
                const is_entry = comptime blk: {
                    for (e_info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, "key")) break :blk true;
                    }
                    break :blk false;
                };
                if (is_entry) {
                    if (keysEqual(entry.key, key)) return true;
                }
            }
        }
        return false;
    }

    /// Get the number of entries in a map.
    pub fn size(map: anytype) i64 {
        const T = @TypeOf(map);
        const info = @typeInfo(T);
        if (info != .@"struct") return 0;
        return @intCast(info.@"struct".fields.len);
    }

    /// Create a new map with a key's value updated.
    /// Returns the same map type with the matching entry's value replaced.
    pub fn put(map: anytype, key: anytype, value: anytype) @TypeOf(map) {
        var result = map;
        const info = @typeInfo(@TypeOf(map));
        if (info != .@"struct") return result;
        inline for (info.@"struct".fields) |field| {
            const entry = @field(map, field.name);
            const E = @TypeOf(entry);
            const e_info = @typeInfo(E);
            if (e_info == .@"struct") {
                const is_kv = comptime blk: {
                    for (e_info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, "key")) break :blk true;
                    }
                    break :blk false;
                };
                if (is_kv) {
                    if (keysEqual(entry.key, key)) {
                        @field(result, field.name).value = value;
                    }
                }
            }
        }
        return result;
    }

    /// Compare two keys, handling atom IDs (u32), strings, and integers.
    fn keysEqual(a: anytype, b: anytype) bool {
        const A = @TypeOf(a);
        const B = @TypeOf(b);
        if (A == B) {
            if (A == []const u8) return std.mem.eql(u8, a, b);
            return a == b;
        }
        // Cross-type comparison for atom IDs
        if ((@typeInfo(A) == .int or @typeInfo(A) == .comptime_int) and
            (@typeInfo(B) == .int or @typeInfo(B) == .comptime_int))
        {
            return a == b;
        }
        return false;
    }
};

// ============================================================
// Type-grouped runtime namespaces
//
// These structs are the user-visible runtime entry points reached
// from Zap source via `:zig.<Namespace>.<fn>(args)`. They group the
// runtime helpers by the type they operate on (Integer, Float, Bool,
// String, IO, File, Path, System, Math, Atom).
// ============================================================

pub const Integer = struct {
    fn formatSignedDecimal(value: i128) []const u8 {
        var buf: [128]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAllocAt(.integer_to_string, slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    fn formatUnsignedDecimal(value: u128) []const u8 {
        var buf: [128]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAllocAt(.integer_to_string, slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    fn digitCountUnsigned(value: u128) i64 {
        var remaining = value;
        var count: i64 = 1;
        while (remaining >= 10) {
            remaining /= 10;
            count += 1;
        }
        return count;
    }

    fn absMagnitudeI8(value: i8) u8 {
        if (value >= 0) return @intCast(value);
        return @as(u8, @intCast(-(value + 1))) + 1;
    }

    fn absMagnitudeI16(value: i16) u16 {
        if (value >= 0) return @intCast(value);
        return @as(u16, @intCast(-(value + 1))) + 1;
    }

    fn absMagnitudeI32(value: i32) u32 {
        if (value >= 0) return @intCast(value);
        return @as(u32, @intCast(-(value + 1))) + 1;
    }

    fn absMagnitudeI64(value: i64) u64 {
        if (value >= 0) return @intCast(value);
        return @as(u64, @intCast(-(value + 1))) + 1;
    }

    fn absMagnitudeI128(value: i128) u128 {
        if (value >= 0) return @intCast(value);
        return @as(u128, @intCast(-(value + 1))) + 1;
    }

    /// Parse a string into i64, returning 0 on failure (non-optional).
    pub fn parse(s: []const u8) i64 {
        return std.fmt.parseInt(i64, s, 10) catch 0;
    }

    /// Parse a string into i64, returning null on failure.
    pub fn parse_optional(s: []const u8) ?i64 {
        return std.fmt.parseInt(i64, s, 10) catch null;
    }

    pub fn to_string(value: i64) []const u8 {
        return to_string_i64(value);
    }

    pub fn to_string_i8(value: i8) []const u8 {
        return formatSignedDecimal(value);
    }

    pub fn to_string_i16(value: i16) []const u8 {
        return formatSignedDecimal(value);
    }

    pub fn to_string_i32(value: i32) []const u8 {
        return formatSignedDecimal(value);
    }

    pub fn to_string_i64(value: i64) []const u8 {
        return formatSignedDecimal(value);
    }

    pub fn to_string_u8(value: u8) []const u8 {
        return formatUnsignedDecimal(value);
    }

    pub fn to_string_u16(value: u16) []const u8 {
        return formatUnsignedDecimal(value);
    }

    pub fn to_string_u32(value: u32) []const u8 {
        return formatUnsignedDecimal(value);
    }

    pub fn to_string_u64(value: u64) []const u8 {
        return formatUnsignedDecimal(value);
    }

    pub fn abs(value: i64) i64 {
        return abs_i64(value);
    }

    pub fn abs_i8(value: i8) i8 {
        return if (value < 0) 0 -% value else value;
    }

    pub fn abs_i16(value: i16) i16 {
        return if (value < 0) 0 -% value else value;
    }

    pub fn abs_i32(value: i32) i32 {
        return if (value < 0) 0 -% value else value;
    }

    pub fn abs_i64(value: i64) i64 {
        return if (value < 0) 0 -% value else value;
    }

    pub fn abs_u8(value: u8) u8 {
        return value;
    }

    pub fn abs_u16(value: u16) u16 {
        return value;
    }

    pub fn abs_u32(value: u32) u32 {
        return value;
    }

    pub fn abs_u64(value: u64) u64 {
        return value;
    }

    pub fn max(value: i64, other: i64) i64 {
        return max_i64(value, other);
    }

    pub fn max_i8(value: i8, other: i8) i8 {
        return @max(value, other);
    }

    pub fn max_i16(value: i16, other: i16) i16 {
        return @max(value, other);
    }

    pub fn max_i32(value: i32, other: i32) i32 {
        return @max(value, other);
    }

    pub fn max_i64(value: i64, other: i64) i64 {
        return @max(value, other);
    }

    pub fn max_u8(value: u8, other: u8) u8 {
        return @max(value, other);
    }

    pub fn max_u16(value: u16, other: u16) u16 {
        return @max(value, other);
    }

    pub fn max_u32(value: u32, other: u32) u32 {
        return @max(value, other);
    }

    pub fn max_u64(value: u64, other: u64) u64 {
        return @max(value, other);
    }

    pub fn min(value: i64, other: i64) i64 {
        return min_i64(value, other);
    }

    pub fn min_i8(value: i8, other: i8) i8 {
        return @min(value, other);
    }

    pub fn min_i16(value: i16, other: i16) i16 {
        return @min(value, other);
    }

    pub fn min_i32(value: i32, other: i32) i32 {
        return @min(value, other);
    }

    pub fn min_i64(value: i64, other: i64) i64 {
        return @min(value, other);
    }

    pub fn min_u8(value: u8, other: u8) u8 {
        return @min(value, other);
    }

    pub fn min_u16(value: u16, other: u16) u16 {
        return @min(value, other);
    }

    pub fn min_u32(value: u32, other: u32) u32 {
        return @min(value, other);
    }

    pub fn min_u64(value: u64, other: u64) u64 {
        return @min(value, other);
    }

    pub fn div(value: i64, divisor: i64) i64 {
        return div_i64(value, divisor);
    }

    pub fn div_i8(value: i8, divisor: i8) i8 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_i16(value: i16, divisor: i16) i16 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_i32(value: i32, divisor: i32) i32 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_i64(value: i64, divisor: i64) i64 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_u8(value: u8, divisor: u8) u8 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_u16(value: u16, divisor: u16) u16 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_u32(value: u32, divisor: u32) u32 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_u64(value: u64, divisor: u64) u64 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn rem(value: i64, divisor: i64) i64 {
        return rem_i64(value, divisor);
    }

    pub fn rem_i8(value: i8, divisor: i8) i8 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_i16(value: i16, divisor: i16) i16 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_i32(value: i32, divisor: i32) i32 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_i64(value: i64, divisor: i64) i64 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_u8(value: u8, divisor: u8) u8 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_u16(value: u16, divisor: u16) u16 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_u32(value: u32, divisor: u32) u32 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_u64(value: u64, divisor: u64) u64 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn pow_i8(base: i8, exponent: i8) i8 {
        var result: i8 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_i16(base: i16, exponent: i16) i16 {
        var result: i16 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_i32(base: i32, exponent: i32) i32 {
        var result: i32 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_i64(base: i64, exponent: i64) i64 {
        var result: i64 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_u8(base: u8, exponent: u8) u8 {
        var result: u8 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_u16(base: u16, exponent: u16) u16 {
        var result: u16 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_u32(base: u32, exponent: u32) u32 {
        var result: u32 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_u64(base: u64, exponent: u64) u64 {
        var result: u64 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn clamp_i8(value: i8, lower: i8, upper: i8) i8 {
        return min_i8(max_i8(value, lower), upper);
    }

    pub fn clamp_i16(value: i16, lower: i16, upper: i16) i16 {
        return min_i16(max_i16(value, lower), upper);
    }

    pub fn clamp_i32(value: i32, lower: i32, upper: i32) i32 {
        return min_i32(max_i32(value, lower), upper);
    }

    pub fn clamp_i64(value: i64, lower: i64, upper: i64) i64 {
        return min_i64(max_i64(value, lower), upper);
    }

    pub fn clamp_u8(value: u8, lower: u8, upper: u8) u8 {
        return min_u8(max_u8(value, lower), upper);
    }

    pub fn clamp_u16(value: u16, lower: u16, upper: u16) u16 {
        return min_u16(max_u16(value, lower), upper);
    }

    pub fn clamp_u32(value: u32, lower: u32, upper: u32) u32 {
        return min_u32(max_u32(value, lower), upper);
    }

    pub fn clamp_u64(value: u64, lower: u64, upper: u64) u64 {
        return min_u64(max_u64(value, lower), upper);
    }

    pub fn digits_i8(value: i8) i64 {
        return digitCountUnsigned(absMagnitudeI8(value));
    }

    pub fn digits_i16(value: i16) i64 {
        return digitCountUnsigned(absMagnitudeI16(value));
    }

    pub fn digits_i32(value: i32) i64 {
        return digitCountUnsigned(absMagnitudeI32(value));
    }

    pub fn digits_i64(value: i64) i64 {
        return digitCountUnsigned(absMagnitudeI64(value));
    }

    pub fn digits_u8(value: u8) i64 {
        return digitCountUnsigned(value);
    }

    pub fn digits_u16(value: u16) i64 {
        return digitCountUnsigned(value);
    }

    pub fn digits_u32(value: u32) i64 {
        return digitCountUnsigned(value);
    }

    pub fn digits_u64(value: u64) i64 {
        return digitCountUnsigned(value);
    }

    // `count_digits_*` was a synonym of `digits_*` — same body, same
    // result type. The duplicate surface was removed when the Zap-side
    // `Integer.count_digits/1` got dropped in favour of `Integer.digits/1`,
    // and these intrinsics had no other consumer.

    pub fn to_f64(value: i64) f64 {
        return to_f64_i64(value);
    }

    pub fn to_f64_i8(value: i8) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_i16(value: i16) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_i32(value: i32) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_i64(value: i64) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_u8(value: u8) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_u16(value: u16) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_u32(value: u32) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_u64(value: u64) f64 {
        return @floatFromInt(value);
    }

    pub fn clz(value: i64) i64 {
        return clz_i64(value);
    }

    pub fn clz_i8(value: i8) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_i16(value: i16) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_i32(value: i32) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_i64(value: i64) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_u8(value: u8) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_u16(value: u16) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_u32(value: u32) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_u64(value: u64) i64 {
        return @intCast(@clz(value));
    }

    pub fn ctz(value: i64) i64 {
        return ctz_i64(value);
    }

    pub fn ctz_i8(value: i8) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_i16(value: i16) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_i32(value: i32) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_i64(value: i64) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_u8(value: u8) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_u16(value: u16) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_u32(value: u32) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_u64(value: u64) i64 {
        return @intCast(@ctz(value));
    }

    pub fn popcount(value: i64) i64 {
        return popcount_i64(value);
    }

    pub fn popcount_i8(value: i8) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_i16(value: i16) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_i32(value: i32) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_i64(value: i64) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_u8(value: u8) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_u16(value: u16) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_u32(value: u32) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_u64(value: u64) i64 {
        return @intCast(@popCount(value));
    }

    pub fn byte_swap(value: i64) i64 {
        return byte_swap_i64(value);
    }

    pub fn byte_swap_i8(value: i8) i8 {
        return @byteSwap(value);
    }

    pub fn byte_swap_i16(value: i16) i16 {
        return @byteSwap(value);
    }

    pub fn byte_swap_i32(value: i32) i32 {
        return @byteSwap(value);
    }

    pub fn byte_swap_i64(value: i64) i64 {
        return @byteSwap(value);
    }

    pub fn byte_swap_u8(value: u8) u8 {
        return @byteSwap(value);
    }

    pub fn byte_swap_u16(value: u16) u16 {
        return @byteSwap(value);
    }

    pub fn byte_swap_u32(value: u32) u32 {
        return @byteSwap(value);
    }

    pub fn byte_swap_u64(value: u64) u64 {
        return @byteSwap(value);
    }

    pub fn bit_reverse(value: i64) i64 {
        return bit_reverse_i64(value);
    }

    pub fn bit_reverse_i8(value: i8) i8 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_i16(value: i16) i16 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_i32(value: i32) i32 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_i64(value: i64) i64 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_u8(value: u8) u8 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_u16(value: u16) u16 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_u32(value: u32) u32 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_u64(value: u64) u64 {
        return @bitReverse(value);
    }

    pub fn add_sat(value: i64, other: i64) i64 {
        return add_sat_i64(value, other);
    }

    pub fn add_sat_i8(value: i8, other: i8) i8 {
        return value +| other;
    }

    pub fn add_sat_i16(value: i16, other: i16) i16 {
        return value +| other;
    }

    pub fn add_sat_i32(value: i32, other: i32) i32 {
        return value +| other;
    }

    pub fn add_sat_i64(value: i64, other: i64) i64 {
        return value +| other;
    }

    pub fn add_sat_u8(value: u8, other: u8) u8 {
        return value +| other;
    }

    pub fn add_sat_u16(value: u16, other: u16) u16 {
        return value +| other;
    }

    pub fn add_sat_u32(value: u32, other: u32) u32 {
        return value +| other;
    }

    pub fn add_sat_u64(value: u64, other: u64) u64 {
        return value +| other;
    }

    pub fn sub_sat(value: i64, other: i64) i64 {
        return sub_sat_i64(value, other);
    }

    pub fn sub_sat_i8(value: i8, other: i8) i8 {
        return value -| other;
    }

    pub fn sub_sat_i16(value: i16, other: i16) i16 {
        return value -| other;
    }

    pub fn sub_sat_i32(value: i32, other: i32) i32 {
        return value -| other;
    }

    pub fn sub_sat_i64(value: i64, other: i64) i64 {
        return value -| other;
    }

    pub fn sub_sat_u8(value: u8, other: u8) u8 {
        return value -| other;
    }

    pub fn sub_sat_u16(value: u16, other: u16) u16 {
        return value -| other;
    }

    pub fn sub_sat_u32(value: u32, other: u32) u32 {
        return value -| other;
    }

    pub fn sub_sat_u64(value: u64, other: u64) u64 {
        return value -| other;
    }

    pub fn mul_sat(value: i64, other: i64) i64 {
        return mul_sat_i64(value, other);
    }

    pub fn mul_sat_i8(value: i8, other: i8) i8 {
        return value *| other;
    }

    pub fn mul_sat_i16(value: i16, other: i16) i16 {
        return value *| other;
    }

    pub fn mul_sat_i32(value: i32, other: i32) i32 {
        return value *| other;
    }

    pub fn mul_sat_i64(value: i64, other: i64) i64 {
        return value *| other;
    }

    pub fn mul_sat_u8(value: u8, other: u8) u8 {
        return value *| other;
    }

    pub fn mul_sat_u16(value: u16, other: u16) u16 {
        return value *| other;
    }

    pub fn mul_sat_u32(value: u32, other: u32) u32 {
        return value *| other;
    }

    pub fn mul_sat_u64(value: u64, other: u64) u64 {
        return value *| other;
    }

    pub fn band(value: i64, other: i64) i64 {
        return band_i64(value, other);
    }

    pub fn band_i8(value: i8, other: i8) i8 {
        return value & other;
    }

    pub fn band_i16(value: i16, other: i16) i16 {
        return value & other;
    }

    pub fn band_i32(value: i32, other: i32) i32 {
        return value & other;
    }

    pub fn band_i64(value: i64, other: i64) i64 {
        return value & other;
    }

    pub fn band_u8(value: u8, other: u8) u8 {
        return value & other;
    }

    pub fn band_u16(value: u16, other: u16) u16 {
        return value & other;
    }

    pub fn band_u32(value: u32, other: u32) u32 {
        return value & other;
    }

    pub fn band_u64(value: u64, other: u64) u64 {
        return value & other;
    }

    pub fn bor(value: i64, other: i64) i64 {
        return bor_i64(value, other);
    }

    pub fn bor_i8(value: i8, other: i8) i8 {
        return value | other;
    }

    pub fn bor_i16(value: i16, other: i16) i16 {
        return value | other;
    }

    pub fn bor_i32(value: i32, other: i32) i32 {
        return value | other;
    }

    pub fn bor_i64(value: i64, other: i64) i64 {
        return value | other;
    }

    pub fn bor_u8(value: u8, other: u8) u8 {
        return value | other;
    }

    pub fn bor_u16(value: u16, other: u16) u16 {
        return value | other;
    }

    pub fn bor_u32(value: u32, other: u32) u32 {
        return value | other;
    }

    pub fn bor_u64(value: u64, other: u64) u64 {
        return value | other;
    }

    pub fn bxor(value: i64, other: i64) i64 {
        return bxor_i64(value, other);
    }

    pub fn bxor_i8(value: i8, other: i8) i8 {
        return value ^ other;
    }

    pub fn bxor_i16(value: i16, other: i16) i16 {
        return value ^ other;
    }

    pub fn bxor_i32(value: i32, other: i32) i32 {
        return value ^ other;
    }

    pub fn bxor_i64(value: i64, other: i64) i64 {
        return value ^ other;
    }

    pub fn bxor_u8(value: u8, other: u8) u8 {
        return value ^ other;
    }

    pub fn bxor_u16(value: u16, other: u16) u16 {
        return value ^ other;
    }

    pub fn bxor_u32(value: u32, other: u32) u32 {
        return value ^ other;
    }

    pub fn bxor_u64(value: u64, other: u64) u64 {
        return value ^ other;
    }

    pub fn bnot(value: i64) i64 {
        return bnot_i64(value);
    }

    pub fn bnot_i8(value: i8) i8 {
        return ~value;
    }

    pub fn bnot_i16(value: i16) i16 {
        return ~value;
    }

    pub fn bnot_i32(value: i32) i32 {
        return ~value;
    }

    pub fn bnot_i64(value: i64) i64 {
        return ~value;
    }

    pub fn bnot_u8(value: u8) u8 {
        return ~value;
    }

    pub fn bnot_u16(value: u16) u16 {
        return ~value;
    }

    pub fn bnot_u32(value: u32) u32 {
        return ~value;
    }

    pub fn bnot_u64(value: u64) u64 {
        return ~value;
    }

    pub fn bsl(value: i64, amount: i64) i64 {
        return bsl_i64(value, amount);
    }

    pub fn bsl_i8(value: i8, amount: i8) i8 {
        if (amount < 0 or amount >= 8) return 0;
        const shift: u3 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_i16(value: i16, amount: i16) i16 {
        if (amount < 0 or amount >= 16) return 0;
        const shift: u4 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_i32(value: i32, amount: i32) i32 {
        if (amount < 0 or amount >= 32) return 0;
        const shift: u5 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_i64(value: i64, amount: i64) i64 {
        if (amount < 0 or amount >= 64) return 0;
        const shift: u6 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_u8(value: u8, amount: u8) u8 {
        if (amount >= 8) return 0;
        const shift: u3 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_u16(value: u16, amount: u16) u16 {
        if (amount >= 16) return 0;
        const shift: u4 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_u32(value: u32, amount: u32) u32 {
        if (amount >= 32) return 0;
        const shift: u5 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_u64(value: u64, amount: u64) u64 {
        if (amount >= 64) return 0;
        const shift: u6 = @intCast(amount);
        return value << shift;
    }

    pub fn bsr(value: i64, amount: i64) i64 {
        return bsr_i64(value, amount);
    }

    pub fn bsr_i8(value: i8, amount: i8) i8 {
        if (amount < 0 or amount >= 8) return if (value < 0) -1 else 0;
        const shift: u3 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_i16(value: i16, amount: i16) i16 {
        if (amount < 0 or amount >= 16) return if (value < 0) -1 else 0;
        const shift: u4 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_i32(value: i32, amount: i32) i32 {
        if (amount < 0 or amount >= 32) return if (value < 0) -1 else 0;
        const shift: u5 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_i64(value: i64, amount: i64) i64 {
        if (amount < 0 or amount >= 64) return if (value < 0) -1 else 0;
        const shift: u6 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_u8(value: u8, amount: u8) u8 {
        if (amount >= 8) return 0;
        const shift: u3 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_u16(value: u16, amount: u16) u16 {
        if (amount >= 16) return 0;
        const shift: u4 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_u32(value: u32, amount: u32) u32 {
        if (amount >= 32) return 0;
        const shift: u5 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_u64(value: u64, amount: u64) u64 {
        if (amount >= 64) return 0;
        const shift: u6 = @intCast(amount);
        return value >> shift;
    }

    pub fn sign(value: i64) i64 {
        return sign_i64(value);
    }

    pub fn sign_i8(value: i8) i8 {
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }

    pub fn sign_i16(value: i16) i16 {
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }

    pub fn sign_i32(value: i32) i32 {
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }

    pub fn sign_i64(value: i64) i64 {
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }

    pub fn sign_u8(value: u8) u8 {
        return if (value > 0) 1 else 0;
    }

    pub fn sign_u16(value: u16) u16 {
        return if (value > 0) 1 else 0;
    }

    pub fn sign_u32(value: u32) u32 {
        return if (value > 0) 1 else 0;
    }

    pub fn sign_u64(value: u64) u64 {
        return if (value > 0) 1 else 0;
    }

    pub fn is_even(value: i64) bool {
        return is_even_i64(value);
    }

    pub fn is_even_i8(value: i8) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_i16(value: i16) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_i32(value: i32) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_i64(value: i64) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_u8(value: u8) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_u16(value: u16) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_u32(value: u32) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_u64(value: u64) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_odd(value: i64) bool {
        return is_odd_i64(value);
    }

    pub fn is_odd_i8(value: i8) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_i16(value: i16) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_i32(value: i32) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_i64(value: i64) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_u8(value: u8) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_u16(value: u16) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_u32(value: u32) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_u64(value: u64) bool {
        return @rem(value, 2) != 0;
    }

    pub fn gcd(value: i64, other: i64) i64 {
        return gcd_i64(value, other);
    }

    pub fn gcd_i8(value: i8, other: i8) i8 {
        var x = abs_i8(value);
        var y = abs_i8(other);
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_i16(value: i16, other: i16) i16 {
        var x = abs_i16(value);
        var y = abs_i16(other);
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_i32(value: i32, other: i32) i32 {
        var x = abs_i32(value);
        var y = abs_i32(other);
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_i64(value: i64, other: i64) i64 {
        var x = abs_i64(value);
        var y = abs_i64(other);
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_u8(value: u8, other: u8) u8 {
        var x = value;
        var y = other;
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_u16(value: u16, other: u16) u16 {
        var x = value;
        var y = other;
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_u32(value: u32, other: u32) u32 {
        var x = value;
        var y = other;
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_u64(value: u64, other: u64) u64 {
        var x = value;
        var y = other;
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn lcm(value: i64, other: i64) i64 {
        return lcm_i64(value, other);
    }

    pub fn lcm_i8(value: i8, other: i8) i8 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_i8(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(abs_i8(value), divisor) *% abs_i8(other);
    }

    pub fn lcm_i16(value: i16, other: i16) i16 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_i16(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(abs_i16(value), divisor) *% abs_i16(other);
    }

    pub fn lcm_i32(value: i32, other: i32) i32 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_i32(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(abs_i32(value), divisor) *% abs_i32(other);
    }

    pub fn lcm_i64(value: i64, other: i64) i64 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_i64(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(abs_i64(value), divisor) *% abs_i64(other);
    }

    pub fn lcm_u8(value: u8, other: u8) u8 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_u8(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor) *% other;
    }

    pub fn lcm_u16(value: u16, other: u16) u16 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_u16(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor) *% other;
    }

    pub fn lcm_u32(value: u32, other: u32) u32 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_u32(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor) *% other;
    }

    pub fn lcm_u64(value: u64, other: u64) u64 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_u64(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor) *% other;
    }

    pub fn to_string_i128(value: i128) []const u8 {
        return formatSignedDecimal(value);
    }

    pub fn to_string_u128(value: u128) []const u8 {
        return formatUnsignedDecimal(value);
    }

    pub fn abs_i128(value: i128) i128 {
        return if (value < 0) 0 -% value else value;
    }

    pub fn abs_u128(value: u128) u128 {
        return value;
    }

    pub fn max_i128(value: i128, other: i128) i128 {
        return @max(value, other);
    }

    pub fn max_u128(value: u128, other: u128) u128 {
        return @max(value, other);
    }

    pub fn min_i128(value: i128, other: i128) i128 {
        return @min(value, other);
    }

    pub fn min_u128(value: u128, other: u128) u128 {
        return @min(value, other);
    }

    pub fn div_i128(value: i128, divisor: i128) i128 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_u128(value: u128, divisor: u128) u128 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn rem_i128(value: i128, divisor: i128) i128 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_u128(value: u128, divisor: u128) u128 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn pow_i128(base: i128, exponent: i128) i128 {
        var result: i128 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_u128(base: u128, exponent: u128) u128 {
        var result: u128 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn clamp_i128(value: i128, lower: i128, upper: i128) i128 {
        return min_i128(max_i128(value, lower), upper);
    }

    pub fn clamp_u128(value: u128, lower: u128, upper: u128) u128 {
        return min_u128(max_u128(value, lower), upper);
    }

    pub fn digits_i128(value: i128) i64 {
        return digitCountUnsigned(absMagnitudeI128(value));
    }

    pub fn digits_u128(value: u128) i64 {
        return digitCountUnsigned(value);
    }

    pub fn to_f64_i128(value: i128) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_u128(value: u128) f64 {
        return @floatFromInt(value);
    }

    pub fn clz_i128(value: i128) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_u128(value: u128) i64 {
        return @intCast(@clz(value));
    }

    pub fn ctz_i128(value: i128) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_u128(value: u128) i64 {
        return @intCast(@ctz(value));
    }

    pub fn popcount_i128(value: i128) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_u128(value: u128) i64 {
        return @intCast(@popCount(value));
    }

    pub fn byte_swap_i128(value: i128) i128 {
        return @byteSwap(value);
    }

    pub fn byte_swap_u128(value: u128) u128 {
        return @byteSwap(value);
    }

    pub fn bit_reverse_i128(value: i128) i128 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_u128(value: u128) u128 {
        return @bitReverse(value);
    }

    pub fn add_sat_i128(value: i128, other: i128) i128 {
        return value +| other;
    }

    pub fn add_sat_u128(value: u128, other: u128) u128 {
        return value +| other;
    }

    pub fn sub_sat_i128(value: i128, other: i128) i128 {
        return value -| other;
    }

    pub fn sub_sat_u128(value: u128, other: u128) u128 {
        return value -| other;
    }

    pub fn mul_sat_i128(value: i128, other: i128) i128 {
        return value *| other;
    }

    pub fn mul_sat_u128(value: u128, other: u128) u128 {
        return value *| other;
    }

    pub fn band_i128(value: i128, other: i128) i128 {
        return value & other;
    }

    pub fn band_u128(value: u128, other: u128) u128 {
        return value & other;
    }

    pub fn bor_i128(value: i128, other: i128) i128 {
        return value | other;
    }

    pub fn bor_u128(value: u128, other: u128) u128 {
        return value | other;
    }

    pub fn bxor_i128(value: i128, other: i128) i128 {
        return value ^ other;
    }

    pub fn bxor_u128(value: u128, other: u128) u128 {
        return value ^ other;
    }

    pub fn bnot_i128(value: i128) i128 {
        return ~value;
    }

    pub fn bnot_u128(value: u128) u128 {
        return ~value;
    }

    pub fn bsl_i128(value: i128, amount: i128) i128 {
        if (amount < 0 or amount >= 128) return 0;
        const shift: u7 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_u128(value: u128, amount: u128) u128 {
        if (amount >= 128) return 0;
        const shift: u7 = @intCast(amount);
        return value << shift;
    }

    pub fn bsr_i128(value: i128, amount: i128) i128 {
        if (amount < 0 or amount >= 128) return if (value < 0) -1 else 0;
        const shift: u7 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_u128(value: u128, amount: u128) u128 {
        if (amount >= 128) return 0;
        const shift: u7 = @intCast(amount);
        return value >> shift;
    }

    pub fn sign_i128(value: i128) i128 {
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }

    pub fn sign_u128(value: u128) u128 {
        return if (value > 0) 1 else 0;
    }

    pub fn is_even_i128(value: i128) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_u128(value: u128) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_odd_i128(value: i128) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_u128(value: u128) bool {
        return @rem(value, 2) != 0;
    }

    pub fn gcd_i128(value: i128, other: i128) i128 {
        var x = abs_i128(value);
        var y = abs_i128(other);
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_u128(value: u128, other: u128) u128 {
        var x = value;
        var y = other;
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn lcm_i128(value: i128, other: i128) i128 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_i128(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(abs_i128(value), divisor) *% abs_i128(other);
    }

    pub fn lcm_u128(value: u128, other: u128) u128 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_u128(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor) *% other;
    }
};

pub const Float = struct {
    pub fn to_string(value: f64) []const u8 {
        return to_string_f64(value);
    }

    pub fn to_string_f16(value: f16) []const u8 {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAllocAt(.float_to_string, slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    pub fn to_string_f32(value: f32) []const u8 {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAllocAt(.float_to_string, slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    pub fn to_string_f64(value: f64) []const u8 {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAllocAt(.float_to_string, slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    /// Fixed-precision float formatter matching C's
    /// `printf("%.<decimals>f", value)` rounding (round half away
    /// from zero — actually round-to-even via Zig's `{d:.N}` which
    /// uses ryu-like semantics; that matches glibc / POSIX printf
    /// for the reference outputs this is wired up to compare against).
    /// `decimals` is clamped to [0, 32].
    pub fn to_string_f64_precision(value: f64, decimals: i64) []const u8 {
        var buf: [128]u8 = undefined;
        const d: usize = if (decimals < 0) 0 else if (decimals > 32) 32 else @intCast(decimals);
        const slice = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ value, d }) catch return "?";
        const result = bumpAllocAt(.float_to_string_precision, slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    /// Parse a string into f64, returning 0.0 on failure (non-optional).
    pub fn parse(s: []const u8) f64 {
        return std.fmt.parseFloat(f64, s) catch 0.0;
    }

    /// Parse a string into f64, returning null on failure.
    pub fn parse_optional(s: []const u8) ?f64 {
        return std.fmt.parseFloat(f64, s) catch null;
    }

    pub fn abs(value: f64) f64 {
        return abs_f64(value);
    }

    pub fn abs_f16(value: f16) f16 {
        return @abs(value);
    }

    pub fn abs_f32(value: f32) f32 {
        return @abs(value);
    }

    pub fn abs_f64(value: f64) f64 {
        return @abs(value);
    }

    pub fn max(value: f64, other: f64) f64 {
        return max_f64(value, other);
    }

    pub fn max_f16(value: f16, other: f16) f16 {
        return @max(value, other);
    }

    pub fn max_f32(value: f32, other: f32) f32 {
        return @max(value, other);
    }

    pub fn max_f64(value: f64, other: f64) f64 {
        return @max(value, other);
    }

    pub fn min(value: f64, other: f64) f64 {
        return min_f64(value, other);
    }

    pub fn min_f16(value: f16, other: f16) f16 {
        return @min(value, other);
    }

    pub fn min_f32(value: f32, other: f32) f32 {
        return @min(value, other);
    }

    pub fn min_f64(value: f64, other: f64) f64 {
        return @min(value, other);
    }

    pub fn round(value: f64) f64 {
        return round_f64(value);
    }

    pub fn round_f16(value: f16) f16 {
        return @round(value);
    }

    pub fn round_f32(value: f32) f32 {
        return @round(value);
    }

    pub fn round_f64(value: f64) f64 {
        return @round(value);
    }

    pub fn floor(value: f64) f64 {
        return floor_f64(value);
    }

    pub fn floor_f16(value: f16) f16 {
        return @floor(value);
    }

    pub fn floor_f32(value: f32) f32 {
        return @floor(value);
    }

    pub fn floor_f64(value: f64) f64 {
        return @floor(value);
    }

    pub fn ceil(value: f64) f64 {
        return ceil_f64(value);
    }

    pub fn ceil_f16(value: f16) f16 {
        return @ceil(value);
    }

    pub fn ceil_f32(value: f32) f32 {
        return @ceil(value);
    }

    pub fn ceil_f64(value: f64) f64 {
        return @ceil(value);
    }

    pub fn trunc(value: f64) f64 {
        return trunc_f64(value);
    }

    pub fn trunc_f16(value: f16) f16 {
        return @trunc(value);
    }

    pub fn trunc_f32(value: f32) f32 {
        return @trunc(value);
    }

    pub fn trunc_f64(value: f64) f64 {
        return @trunc(value);
    }

    pub fn clamp_f16(value: f16, lower: f16, upper: f16) f16 {
        return min_f16(max_f16(value, lower), upper);
    }

    pub fn clamp_f32(value: f32, lower: f32, upper: f32) f32 {
        return min_f32(max_f32(value, lower), upper);
    }

    pub fn clamp_f64(value: f64, lower: f64, upper: f64) f64 {
        return min_f64(max_f64(value, lower), upper);
    }

    pub fn to_i64(value: f64) i64 {
        return to_i64_f64(value);
    }

    /// Convert a float to an i64 by truncating toward zero. Total over the
    /// finite-and-in-range float domain; panics on NaN, ±Inf, and values
    /// that don't round-trip into an i64 after truncation. The unchecked
    /// `@intFromFloat` builtin used previously was undefined behaviour on
    /// every one of those edges, so the surface conversion silently
    /// corrupted state when fed an upstream divide-by-zero or oversized
    /// magnitude. Each width gets its own helper because the safe upper
    /// bound depends on the float's mantissa precision — for f16 every
    /// finite value already fits in i64; for f32 the boundary is exactly
    /// 2^63 (representable); for f64 the closest representable value at
    /// the i64-max edge is 2^63 itself, which is i64 max + 1 and must be
    /// rejected.
    pub fn to_i64_f16(value: f16) i64 {
        if (std.math.isNan(value)) Kernel.raise("Float.to_integer: cannot convert NaN to integer");
        if (std.math.isInf(value)) Kernel.raise("Float.to_integer: cannot convert infinity to integer");
        return @intFromFloat(@trunc(value));
    }

    pub fn to_i64_f32(value: f32) i64 {
        if (std.math.isNan(value)) Kernel.raise("Float.to_integer: cannot convert NaN to integer");
        if (std.math.isInf(value)) Kernel.raise("Float.to_integer: cannot convert infinity to integer");
        const truncated = @trunc(value);
        if (truncated < -9.2233720368547758e18 or truncated >= 9.2233720368547758e18) {
            Kernel.raise("Float.to_integer: value out of i64 range");
        }
        return @intFromFloat(truncated);
    }

    pub fn to_i64_f64(value: f64) i64 {
        if (std.math.isNan(value)) Kernel.raise("Float.to_integer: cannot convert NaN to integer");
        if (std.math.isInf(value)) Kernel.raise("Float.to_integer: cannot convert infinity to integer");
        const truncated = @trunc(value);
        // i64 min == -2^63 is exactly representable as f64; i64 max == 2^63 - 1
        // is *not* — the closest f64 is 2^63, which would overflow. So the
        // upper bound is strict-less-than 2^63.
        const max_plus_one: f64 = 9.223372036854776e18;
        const min_value: f64 = -9.223372036854776e18;
        if (truncated < min_value or truncated >= max_plus_one) {
            Kernel.raise("Float.to_integer: value out of i64 range");
        }
        return @intFromFloat(truncated);
    }

    pub fn to_string_f80(value: f80) []const u8 {
        var buf: [128]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAllocAt(.float_to_string, slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    pub fn to_string_f128(value: f128) []const u8 {
        var buf: [128]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAllocAt(.float_to_string, slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    pub fn abs_f80(value: f80) f80 {
        return @abs(value);
    }

    pub fn abs_f128(value: f128) f128 {
        return @abs(value);
    }

    pub fn max_f80(value: f80, other: f80) f80 {
        return @max(value, other);
    }

    pub fn max_f128(value: f128, other: f128) f128 {
        return @max(value, other);
    }

    pub fn min_f80(value: f80, other: f80) f80 {
        return @min(value, other);
    }

    pub fn min_f128(value: f128, other: f128) f128 {
        return @min(value, other);
    }

    pub fn round_f80(value: f80) f80 {
        return @round(value);
    }

    pub fn round_f128(value: f128) f128 {
        return @round(value);
    }

    pub fn floor_f80(value: f80) f80 {
        return @floor(value);
    }

    pub fn floor_f128(value: f128) f128 {
        return @floor(value);
    }

    pub fn ceil_f80(value: f80) f80 {
        return @ceil(value);
    }

    pub fn ceil_f128(value: f128) f128 {
        return @ceil(value);
    }

    pub fn trunc_f80(value: f80) f80 {
        return @trunc(value);
    }

    pub fn trunc_f128(value: f128) f128 {
        return @trunc(value);
    }

    pub fn clamp_f80(value: f80, lower: f80, upper: f80) f80 {
        return min_f80(max_f80(value, lower), upper);
    }

    pub fn clamp_f128(value: f128, lower: f128, upper: f128) f128 {
        return min_f128(max_f128(value, lower), upper);
    }

    pub fn to_i64_f80(value: f80) i64 {
        if (std.math.isNan(value)) Kernel.raise("Float.to_integer: cannot convert NaN to integer");
        if (std.math.isInf(value)) Kernel.raise("Float.to_integer: cannot convert infinity to integer");
        const truncated = @trunc(value);
        const max_plus_one: f80 = 9.223372036854775808e18;
        const min_value: f80 = -9.223372036854775808e18;
        if (truncated < min_value or truncated >= max_plus_one) {
            Kernel.raise("Float.to_integer: value out of i64 range");
        }
        return @intFromFloat(truncated);
    }

    pub fn to_i64_f128(value: f128) i64 {
        if (std.math.isNan(value)) Kernel.raise("Float.to_integer: cannot convert NaN to integer");
        if (std.math.isInf(value)) Kernel.raise("Float.to_integer: cannot convert infinity to integer");
        const truncated = @trunc(value);
        const max_plus_one: f128 = 9.223372036854775808e18;
        const min_value: f128 = -9.223372036854775808e18;
        if (truncated < min_value or truncated >= max_plus_one) {
            Kernel.raise("Float.to_integer: value out of i64 range");
        }
        return @intFromFloat(truncated);
    }
};

pub const Math = struct {
    pub fn sqrt(x: f64) f64 {
        return sqrt_f64(x);
    }

    pub fn sqrt_i8(x: i8) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_i16(x: i16) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_i32(x: i32) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_i64(x: i64) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_i128(x: i128) f128 {
        return @sqrt(@as(f128, @floatFromInt(x)));
    }

    pub fn sqrt_u8(x: u8) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_u16(x: u16) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_u32(x: u32) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_u64(x: u64) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_u128(x: u128) f128 {
        return @sqrt(@as(f128, @floatFromInt(x)));
    }

    pub fn sqrt_f16(x: f16) f16 {
        return @sqrt(x);
    }

    pub fn sqrt_f32(x: f32) f32 {
        return @sqrt(x);
    }

    pub fn sqrt_f64(x: f64) f64 {
        return @sqrt(x);
    }

    pub fn sqrt_f80(x: f80) f80 {
        return @sqrt(x);
    }

    pub fn sqrt_f128(x: f128) f128 {
        return @sqrt(x);
    }

    pub fn sin(x: f64) f64 {
        return sin_f64(x);
    }

    pub fn sin_i8(x: i8) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_i16(x: i16) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_i32(x: i32) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_i64(x: i64) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_i128(x: i128) f128 {
        return @sin(@as(f128, @floatFromInt(x)));
    }

    pub fn sin_u8(x: u8) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_u16(x: u16) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_u32(x: u32) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_u64(x: u64) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_u128(x: u128) f128 {
        return @sin(@as(f128, @floatFromInt(x)));
    }

    pub fn sin_f16(x: f16) f16 {
        return @sin(x);
    }

    pub fn sin_f32(x: f32) f32 {
        return @sin(x);
    }

    pub fn sin_f64(x: f64) f64 {
        return @sin(x);
    }

    pub fn sin_f80(x: f80) f80 {
        return @sin(x);
    }

    pub fn sin_f128(x: f128) f128 {
        return @sin(x);
    }

    pub fn cos(x: f64) f64 {
        return cos_f64(x);
    }

    pub fn cos_i8(x: i8) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_i16(x: i16) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_i32(x: i32) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_i64(x: i64) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_i128(x: i128) f128 {
        return @cos(@as(f128, @floatFromInt(x)));
    }

    pub fn cos_u8(x: u8) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_u16(x: u16) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_u32(x: u32) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_u64(x: u64) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_u128(x: u128) f128 {
        return @cos(@as(f128, @floatFromInt(x)));
    }

    pub fn cos_f16(x: f16) f16 {
        return @cos(x);
    }

    pub fn cos_f32(x: f32) f32 {
        return @cos(x);
    }

    pub fn cos_f64(x: f64) f64 {
        return @cos(x);
    }

    pub fn cos_f80(x: f80) f80 {
        return @cos(x);
    }

    pub fn cos_f128(x: f128) f128 {
        return @cos(x);
    }

    pub fn tan(x: f64) f64 {
        return tan_f64(x);
    }

    pub fn tan_i8(x: i8) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_i16(x: i16) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_i32(x: i32) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_i64(x: i64) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_i128(x: i128) f128 {
        return @tan(@as(f128, @floatFromInt(x)));
    }

    pub fn tan_u8(x: u8) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_u16(x: u16) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_u32(x: u32) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_u64(x: u64) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_u128(x: u128) f128 {
        return @tan(@as(f128, @floatFromInt(x)));
    }

    pub fn tan_f16(x: f16) f16 {
        return @tan(x);
    }

    pub fn tan_f32(x: f32) f32 {
        return @tan(x);
    }

    pub fn tan_f64(x: f64) f64 {
        return @tan(x);
    }

    pub fn tan_f80(x: f80) f80 {
        return @tan(x);
    }

    pub fn tan_f128(x: f128) f128 {
        return @tan(x);
    }

    pub fn exp(x: f64) f64 {
        return exp_f64(x);
    }

    pub fn exp_i8(x: i8) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_i16(x: i16) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_i32(x: i32) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_i64(x: i64) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_i128(x: i128) f128 {
        return @exp(@as(f128, @floatFromInt(x)));
    }

    pub fn exp_u8(x: u8) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_u16(x: u16) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_u32(x: u32) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_u64(x: u64) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_u128(x: u128) f128 {
        return @exp(@as(f128, @floatFromInt(x)));
    }

    pub fn exp_f16(x: f16) f16 {
        return @exp(x);
    }

    pub fn exp_f32(x: f32) f32 {
        return @exp(x);
    }

    pub fn exp_f64(x: f64) f64 {
        return @exp(x);
    }

    pub fn exp_f80(x: f80) f80 {
        return @exp(x);
    }

    pub fn exp_f128(x: f128) f128 {
        return @exp(x);
    }

    pub fn exp2(x: f64) f64 {
        return exp2_f64(x);
    }

    pub fn exp2_i8(x: i8) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_i16(x: i16) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_i32(x: i32) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_i64(x: i64) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_i128(x: i128) f128 {
        return @exp2(@as(f128, @floatFromInt(x)));
    }

    pub fn exp2_u8(x: u8) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_u16(x: u16) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_u32(x: u32) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_u64(x: u64) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_u128(x: u128) f128 {
        return @exp2(@as(f128, @floatFromInt(x)));
    }

    pub fn exp2_f16(x: f16) f16 {
        return @exp2(x);
    }

    pub fn exp2_f32(x: f32) f32 {
        return @exp2(x);
    }

    pub fn exp2_f64(x: f64) f64 {
        return @exp2(x);
    }

    pub fn exp2_f80(x: f80) f80 {
        return @exp2(x);
    }

    pub fn exp2_f128(x: f128) f128 {
        return @exp2(x);
    }

    pub fn log(x: f64) f64 {
        return log_f64(x);
    }

    pub fn log_i8(x: i8) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_i16(x: i16) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_i32(x: i32) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_i64(x: i64) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_i128(x: i128) f128 {
        return @log(@as(f128, @floatFromInt(x)));
    }

    pub fn log_u8(x: u8) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_u16(x: u16) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_u32(x: u32) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_u64(x: u64) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_u128(x: u128) f128 {
        return @log(@as(f128, @floatFromInt(x)));
    }

    pub fn log_f16(x: f16) f16 {
        return @log(x);
    }

    pub fn log_f32(x: f32) f32 {
        return @log(x);
    }

    pub fn log_f64(x: f64) f64 {
        return @log(x);
    }

    pub fn log_f80(x: f80) f80 {
        return @log(x);
    }

    pub fn log_f128(x: f128) f128 {
        return @log(x);
    }

    pub fn log2(x: f64) f64 {
        return log2_f64(x);
    }

    pub fn log2_i8(x: i8) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_i16(x: i16) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_i32(x: i32) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_i64(x: i64) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_i128(x: i128) f128 {
        return @log2(@as(f128, @floatFromInt(x)));
    }

    pub fn log2_u8(x: u8) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_u16(x: u16) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_u32(x: u32) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_u64(x: u64) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_u128(x: u128) f128 {
        return @log2(@as(f128, @floatFromInt(x)));
    }

    pub fn log2_f16(x: f16) f16 {
        return @log2(x);
    }

    pub fn log2_f32(x: f32) f32 {
        return @log2(x);
    }

    pub fn log2_f64(x: f64) f64 {
        return @log2(x);
    }

    pub fn log2_f80(x: f80) f80 {
        return @log2(x);
    }

    pub fn log2_f128(x: f128) f128 {
        return @log2(x);
    }

    pub fn log10(x: f64) f64 {
        return log10_f64(x);
    }

    pub fn log10_i8(x: i8) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_i16(x: i16) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_i32(x: i32) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_i64(x: i64) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_i128(x: i128) f128 {
        return @log10(@as(f128, @floatFromInt(x)));
    }

    pub fn log10_u8(x: u8) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_u16(x: u16) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_u32(x: u32) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_u64(x: u64) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_u128(x: u128) f128 {
        return @log10(@as(f128, @floatFromInt(x)));
    }

    pub fn log10_f16(x: f16) f16 {
        return @log10(x);
    }

    pub fn log10_f32(x: f32) f32 {
        return @log10(x);
    }

    pub fn log10_f64(x: f64) f64 {
        return @log10(x);
    }

    pub fn log10_f80(x: f80) f80 {
        return @log10(x);
    }

    pub fn log10_f128(x: f128) f128 {
        return @log10(x);
    }

    // The legacy `floor_to_i64_*`, `ceil_to_i64_*`, and `round_to_i64_*`
    // intrinsics fused the rounding step with the i64 conversion. Now that
    // `Float.to_i64_f*` panics on NaN/±Inf/out-of-range, callers compose
    // `Float.to_integer(Float.floor(x))` and the optimizer is free to fuse
    // the rounding+convert when it can. Keeping a separate fused entry
    // would re-introduce the old "intrinsic doesn't validate, surface
    // function does" split that hid silent UB on edge values.
};

pub const Bool = struct {
    pub fn to_string(value: bool) []const u8 {
        return if (value) "true" else "false";
    }
};

pub const IO = struct {
    pub fn println(value: anytype) void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8 or (info == .pointer and @typeInfo(std.meta.Child(T)) == .array)) {
            stdoutPrint("{s}\n", .{value});
        } else if (info == .int or info == .comptime_int) {
            stdoutPrint("{d}\n", .{value});
        } else if (info == .float or info == .comptime_float) {
            stdoutPrint("{d}\n", .{value});
        } else if (T == bool) {
            stdoutPrint("{}\n", .{value});
        } else if (info == .@"enum") {
            stdoutPrint(":{s}\n", .{@tagName(value)});
        } else if (T == u32) {
            // Could be an atom ID — print as atom if it looks up
            const name = atomToString(value);
            if (!std.mem.eql(u8, name, "<unknown_atom>")) {
                stdoutPrint(":{s}\n", .{name});
            } else {
                stdoutPrint("{d}\n", .{value});
            }
        } else {
            // For tuples, structs, and other compound types, use inspect formatting
            var iw_buf: [4096]u8 = undefined;
            var iw = BufWriter{ .buf = &iw_buf, .pos = 0 };
            inspectWrite(&iw, value);
            stdoutBufferedWrite(iw_buf[0..iw.pos]);
            stdoutPrint("\n", .{});
        }
    }

    pub fn print_str(value: anytype) void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8 or (info == .pointer and @typeInfo(std.meta.Child(T)) == .array)) {
            stdoutPrint("{s}", .{value});
        } else {
            stdoutPrint("{any}", .{value});
        }
    }

    /// Append a single byte to the buffered stdout. Used by streaming
    /// output paths (e.g. the CLBG mandelbrot port) where building an
    /// intermediate `String` per byte would dominate cost. Returns the
    /// byte unchanged so it composes in pipe chains.
    pub fn write_byte(byte: i64) i64 {
        // Wrap to a u8 — Zap source-level i64 is the natural shape for
        // single-byte arithmetic (`byte_acc <<= 1`, `bor`, …) but the
        // wire shape is one byte.
        const b: u8 = @truncate(@as(u64, @bitCast(byte)));
        stdoutBufferedWriteByte(b);
        return byte;
    }

    /// Read a line from stdin. Returns the line without the trailing
    /// newline. Returns an empty string on EOF or error.
    ///
    /// Buffered through the process-global stdin buffer (see the
    /// `stdinRefill` / `stdinReadByte` family near the top of this
    /// file). The fast path scans for `'\n'` inside the buffer with a
    /// single `std.mem.indexOfScalar` per refill chunk, copying the
    /// matched slice into a freshly allocated arena buffer. When a line
    /// spans multiple refills the scratch buffer grows on demand and
    /// the accumulated bytes are concatenated at the end.
    pub fn gets() []const u8 {
        // Flush pending stdout so prompts ship before the read blocks.
        flushStdoutBuf();

        // Fast path: the line fits entirely inside the current refill.
        // Scan for a newline in what's already buffered; if found, copy
        // directly into the arena and bump past the newline.
        if (stdinBuffered() == 0) {
            if (stdinRefill() == 0) return "";
        }

        // Scratch for the slow path (line spans multiple refills). Sized
        // to comfortably hold typical input-stream lines; for the rare
        // longer-than-buffer line we fall through to a growable arena
        // accumulation pattern.
        var scratch: [STDIN_BUF_SIZE]u8 = undefined;
        var scratch_len: usize = 0;

        while (true) {
            const available = stdinBuffered();
            if (available == 0) break;
            const window = stdin_buf[stdin_buf_pos..][0..available];
            if (std.mem.indexOfScalar(u8, window, '\n')) |nl_idx| {
                if (scratch_len == 0) {
                    // Hot path — the whole line lives inside the
                    // current buffer window. One copy, one bump.
                    var line_len = nl_idx;
                    if (line_len > 0 and window[line_len - 1] == '\r') line_len -= 1;
                    if (line_len == 0) {
                        stdin_buf_pos += nl_idx + 1;
                        return "";
                    }
                    const result = bumpAllocAt(.io_gets, line_len);
                    if (result.len == 0) {
                        stdin_buf_pos += nl_idx + 1;
                        return "";
                    }
                    @memcpy(result, window[0..line_len]);
                    stdin_buf_pos += nl_idx + 1;
                    return result;
                }
                // Slow path — append the final chunk and emit.
                const take = nl_idx;
                if (scratch_len + take > scratch.len) break; // truncate at scratch capacity
                @memcpy(scratch[scratch_len..][0..take], window[0..take]);
                scratch_len += take;
                stdin_buf_pos += nl_idx + 1;
                break;
            }
            // No newline in this chunk — consume it whole into scratch
            // and refill. If the line outgrows our scratch buffer we
            // truncate (matches the previous unbuffered implementation's
            // implicit 4 KiB cap behaviour).
            const take = if (scratch_len + available > scratch.len) scratch.len - scratch_len else available;
            @memcpy(scratch[scratch_len..][0..take], window[0..take]);
            scratch_len += take;
            stdin_buf_pos += available;
            if (scratch_len == scratch.len) {
                // Scratch exhausted; consume the rest of the line so
                // the next gets() call doesn't pick up mid-line bytes.
                while (true) {
                    if (stdinBuffered() == 0) {
                        if (stdinRefill() == 0) break;
                    }
                    const tail = stdin_buf[stdin_buf_pos..][0..stdinBuffered()];
                    if (std.mem.indexOfScalar(u8, tail, '\n')) |nl| {
                        stdin_buf_pos += nl + 1;
                        break;
                    }
                    stdin_buf_pos += tail.len;
                }
                break;
            }
            if (stdinRefill() == 0) break;
        }

        // Strip trailing \r if present (Windows line endings).
        if (scratch_len > 0 and scratch[scratch_len - 1] == '\r') scratch_len -= 1;
        if (scratch_len == 0) return "";
        const result = bumpAllocAt(.io_gets, scratch_len);
        if (result.len == 0) return "";
        @memcpy(result, scratch[0..scratch_len]);
        return result;
    }

    /// Switch terminal mode. Accepts a u32 atom ID — checks atom name
    /// for "Raw" to enable raw mode (no canonical line buffering, no
    /// echo); any other value restores the saved original termios.
    pub fn set_terminal_mode(mode: u32) void {
        const posix = std.posix;
        const stdin_fd = posix.STDIN_FILENO;
        const is_raw = std.mem.eql(u8, atomToString(mode), "Raw");
        if (is_raw) {
            var termios = posix.tcgetattr(stdin_fd) catch return;
            if (!raw_mode_saved) {
                original_termios = termios;
                raw_mode_saved = true;
            }
            termios.lflag.ICANON = false;
            termios.lflag.ECHO = false;
            termios.cc[@intFromEnum(posix.V.MIN)] = 1;
            termios.cc[@intFromEnum(posix.V.TIME)] = 0;
            posix.tcsetattr(stdin_fd, .FLUSH, termios) catch return;
        } else {
            if (raw_mode_saved) {
                posix.tcsetattr(stdin_fd, .FLUSH, original_termios) catch return;
            }
        }
    }

    /// Non-blocking read of a single character from stdin. Returns a
    /// 1-byte string if a key is available, "" otherwise. Must be in
    /// raw mode for meaningful use.
    ///
    /// Buffered: if the shared stdin buffer holds any unread bytes
    /// (e.g. left over from a previous `gets()` refill), return the
    /// first one without calling `poll()`. Otherwise consult `poll()`
    /// with a zero-timeout and refill on `POLLIN`.
    pub fn try_get_char() []const u8 {
        if (stdinBuffered() > 0) {
            const b = stdin_buf[stdin_buf_pos];
            stdin_buf_pos += 1;
            const result_buf = bumpAllocAt(.io_try_get_char, 1);
            if (result_buf.len == 0) return "";
            result_buf[0] = b;
            return result_buf;
        }

        const posix = std.posix;
        const stdin_fd = posix.STDIN_FILENO;
        const POLLIN: i16 = 0x0001;

        var fds = [_]std.c.pollfd{.{
            .fd = stdin_fd,
            .events = POLLIN,
            .revents = 0,
        }};
        const ready = posix.poll(&fds, 0) catch return "";
        if (ready == 0) return "";

        if (stdinRefill() == 0) return "";
        const b = stdin_buf[stdin_buf_pos];
        stdin_buf_pos += 1;
        const result_buf = bumpAllocAt(.io_try_get_char, 1);
        if (result_buf.len == 0) return "";
        result_buf[0] = b;
        return result_buf;
    }

    /// Read a single character from stdin. Returns a 1-byte string.
    /// In raw mode, returns immediately after one keypress; in normal
    /// mode, blocks until Enter then returns the first character.
    ///
    /// Buffered through the shared stdin buffer so adjacent `gets()` /
    /// `get_char()` calls cooperate cleanly without leaking unread
    /// bytes back to the kernel.
    pub fn get_char() []const u8 {
        const b = stdinReadByte() orelse return "";
        const result = bumpAllocAt(.io_get_char, 1);
        if (result.len == 0) return "";
        result[0] = b;
        return result;
    }

    /// Write a string to stderr followed by a newline. Flushes pending
    /// stdout first so error messages don't leapfrog buffered output.
    pub fn warn(message: []const u8) void {
        flushStdoutBuf();
        posixWrite(STDERR_FD, message);
        posixWrite(STDERR_FD, "\n");
    }

    pub fn inspect(value: anytype) InspectReturn(@TypeOf(value)) {
        var iw_buf: [4096]u8 = undefined;
        var iw = BufWriter{ .buf = &iw_buf, .pos = 0 };
        inspectWrite(&iw, value);
        stdoutBufferedWrite(iw_buf[0..iw.pos]);
        stdoutPrint("\n", .{});
        const RT = InspectReturn(@TypeOf(value));
        if (RT == void) return;
        return value;
    }
};

/// Returns `void` for comptime-only types (enum literals, comptime_int,
/// etc.) so that `IO.inspect` can be called at runtime without forcing
/// comptime evaluation. For all other types, returns the input type
/// to support piping.
fn InspectReturn(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .enum_literal, .comptime_int, .comptime_float, .type, .null, .undefined => void,
        else => T,
    };
}

fn inspectWrite(writer: anytype, value: anytype) void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (T == []const u8) {
        writer.print("\"{s}\"", .{value}) catch {};
    } else if (info == .pointer) {
        const child_info = @typeInfo(info.pointer.child);
        if (child_info == .array) {
            if (child_info.array.child == u8) {
                writer.print("\"{s}\"", .{value}) catch {};
            } else {
                writer.print("[", .{}) catch {};
                for (0..child_info.array.len) |i| {
                    if (i > 0) writer.print(", ", .{}) catch {};
                    inspectWrite(writer, value[i]);
                }
                writer.print("]", .{}) catch {};
            }
        } else {
            writer.print("{any}", .{value}) catch {};
        }
    } else if (info == .int or info == .comptime_int) {
        writer.print("{d}", .{value}) catch {};
    } else if (info == .float or info == .comptime_float) {
        const rounded: i64 = @trunc(value);
        if (value == @as(@TypeOf(value), @floatFromInt(rounded))) {
            writer.print("{d}.0", .{rounded}) catch {};
        } else {
            writer.print("{d}", .{value}) catch {};
        }
    } else if (T == bool) {
        writer.print("{}", .{value}) catch {};
    } else if (info == .@"struct" and info.@"struct".is_tuple) {
        writer.print("{{", .{}) catch {};
        inline for (info.@"struct".fields, 0..) |field, i| {
            if (i > 0) writer.print(", ", .{}) catch {};
            inspectWrite(writer, @field(value, field.name));
        }
        writer.print("}}", .{}) catch {};
    } else if (info == .@"struct") {
        // Detect Zap map representation: struct of .{key, value} entry structs.
        const is_map = comptime blk: {
            if (info.@"struct".fields.len == 0) break :blk false;
            for (info.@"struct".fields) |f| {
                const inner = @typeInfo(f.type);
                if (inner != .@"struct") break :blk false;
                if (inner.@"struct".fields.len != 2) break :blk false;
                const has_key = for (inner.@"struct".fields) |ef| {
                    if (std.mem.eql(u8, ef.name, "key")) break true;
                } else false;
                const has_value = for (inner.@"struct".fields) |ef| {
                    if (std.mem.eql(u8, ef.name, "value")) break true;
                } else false;
                if (!has_key or !has_value) break :blk false;
            }
            break :blk true;
        };
        if (is_map) {
            writer.print("%{{", .{}) catch {};
            inline for (info.@"struct".fields, 0..) |field, i| {
                if (i > 0) writer.print(", ", .{}) catch {};
                const entry = @field(value, field.name);
                inspectWrite(writer, entry.key);
                writer.print(": ", .{}) catch {};
                inspectWrite(writer, entry.value);
            }
            writer.print("}}", .{}) catch {};
        } else {
            writer.print("%{{", .{}) catch {};
            inline for (info.@"struct".fields, 0..) |field, i| {
                if (i > 0) writer.print(", ", .{}) catch {};
                writer.print("{s}: ", .{field.name}) catch {};
                inspectWrite(writer, @field(value, field.name));
            }
            writer.print("}}", .{}) catch {};
        }
    } else if (info == .@"enum") {
        writer.print(":{s}", .{@tagName(value)}) catch {};
    } else {
        writer.print("{any}", .{value}) catch {};
    }
}

pub const File = struct {
    pub fn read(path: []const u8) []const u8 {
        const path_z = std.posix.toPosixPath(path) catch return "";
        const fd = std.c.open(&path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return "";
        defer _ = std.c.close(fd);
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return "";
        const file_size: usize = @intCast(@max(stat.size, 0));
        if (file_size == 0) return "";
        const read_size = @min(file_size, 1024 * 1024);
        const result = bumpAllocAt(.file_read, read_size);
        if (result.len == 0) return "";
        var total: usize = 0;
        while (total < read_size) {
            const n = std.posix.read(fd, result[total..read_size]) catch break;
            if (n == 0) break;
            total += n;
        }
        return result[0..total];
    }

    pub fn write(path: []const u8, content: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        const fd = std.c.open(&path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return false;
        defer _ = std.c.close(fd);
        var written: usize = 0;
        while (written < content.len) {
            const rc = std.c.write(fd, content[written..].ptr, content[written..].len);
            if (rc <= 0) return false;
            written += @intCast(rc);
        }
        return true;
    }

    pub fn exists(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        return std.c.faccessat(std.posix.AT.FDCWD, &path_z, std.posix.F_OK, 0) == 0;
    }

    pub fn rm(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        return std.c.unlinkat(std.posix.AT.FDCWD, &path_z, 0) == 0;
    }

    pub fn mkdir(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        return std.c.mkdirat(std.posix.AT.FDCWD, &path_z, 0o755) == 0;
    }

    pub fn rmdir(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        const AT_REMOVEDIR: u32 = 0x80; // POSIX standard
        return std.c.unlinkat(std.posix.AT.FDCWD, &path_z, AT_REMOVEDIR) == 0;
    }

    pub fn rename(old_path: []const u8, new_path: []const u8) bool {
        const old_z = std.posix.toPosixPath(old_path) catch return false;
        const new_z = std.posix.toPosixPath(new_path) catch return false;
        return std.c.renameat(std.posix.AT.FDCWD, &old_z, std.posix.AT.FDCWD, &new_z) == 0;
    }

    pub fn cp(src: []const u8, dest: []const u8) bool {
        const content = read(src);
        if (content.len == 0) return false;
        return write(dest, content);
    }

    pub fn is_dir(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        var stat: std.c.Stat = undefined;
        if (std.c.fstatat(std.posix.AT.FDCWD, &path_z, &stat, 0) != 0) return false;
        return stat.mode & std.posix.S.IFMT == std.posix.S.IFDIR;
    }

    pub fn is_regular(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        var stat: std.c.Stat = undefined;
        if (std.c.fstatat(std.posix.AT.FDCWD, &path_z, &stat, 0) != 0) return false;
        return stat.mode & std.posix.S.IFMT == std.posix.S.IFREG;
    }
};

pub const Prim = struct {
    pub fn glob(pattern: []const u8) ?*const List([]const u8) {
        const allocator = std.heap.page_allocator;
        const matches = globCollect(allocator, pattern) catch return null;
        defer {
            for (matches) |matched_path| allocator.free(matched_path);
            allocator.free(matches);
        }

        var result: ?*const List([]const u8) = null;
        var index: usize = 0;
        while (index < matches.len) : (index += 1) {
            const copied_path = bumpCopy(matches[index]);
            if (copied_path.len == 0 and matches[index].len != 0) return null;
            result = List([]const u8).push(result, copied_path);
        }
        return result;
    }

    fn bumpCopy(value: []const u8) []const u8 {
        const result = bumpAlloc(value.len);
        if (result.len == 0 and value.len != 0) return "";
        @memcpy(result, value);
        return result;
    }

    fn globCollect(allocator: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temporary_allocator = arena.allocator();

        const clean_pattern = stripLeadingCurrentDir(pattern);
        var results: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (results.items) |item| allocator.free(item);
            results.deinit(allocator);
        }

        if (!globHasMagic(clean_pattern)) {
            const access_path = try temporary_allocator.dupe(u8, clean_pattern);
            if (std.Io.Dir.cwd().access(std.Options.debug_io, access_path, .{})) |_| {
                try results.append(allocator, try allocator.dupe(u8, clean_pattern));
            } else |_| {}
            return results.toOwnedSlice(allocator);
        }

        const base_prefix = globBasePrefix(clean_pattern);
        const search_path = if (base_prefix.len == 0)
            try temporary_allocator.dupe(u8, ".")
        else
            try temporary_allocator.dupe(u8, base_prefix);
        const initial_prefix = stripTrailingSlash(base_prefix);

        try globWalk(
            allocator,
            temporary_allocator,
            search_path,
            initial_prefix,
            clean_pattern,
            &results,
        );

        globSort(results.items);
        return results.toOwnedSlice(allocator);
    }

    fn globWalk(
        result_allocator: std.mem.Allocator,
        temporary_allocator: std.mem.Allocator,
        dir_path: []const u8,
        relative_prefix: []const u8,
        pattern: []const u8,
        results: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(std.Options.debug_io);

        var iterator = dir.iterate();
        while (iterator.next(std.Options.debug_io) catch null) |entry| {
            const full_path = try std.fs.path.join(temporary_allocator, &.{ dir_path, entry.name });
            const relative_path = if (relative_prefix.len == 0)
                try temporary_allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(temporary_allocator, "{s}/{s}", .{ relative_prefix, entry.name });

            if (entry.kind == .directory) {
                if (globMatch(pattern, relative_path)) {
                    try results.append(result_allocator, try result_allocator.dupe(u8, relative_path));
                }
                try globWalk(result_allocator, temporary_allocator, full_path, relative_path, pattern, results);
                continue;
            }

            if (entry.kind == .file and globMatch(pattern, relative_path)) {
                try results.append(result_allocator, try result_allocator.dupe(u8, relative_path));
            }
        }
    }

    fn globMatch(pattern: []const u8, path: []const u8) bool {
        const clean_pattern = stripLeadingCurrentDir(pattern);
        const clean_path = stripLeadingCurrentDir(path);
        return globMatchSegments(clean_pattern, clean_path, 0, 0);
    }

    fn globMatchSegments(pattern: []const u8, path: []const u8, pattern_start: usize, path_start: usize) bool {
        if (pattern_start >= pattern.len) return path_start >= path.len;

        const pattern_segment = globNextSegment(pattern, pattern_start);
        if (std.mem.eql(u8, pattern_segment.value, "**")) {
            if (pattern_segment.next >= pattern.len) return true;
            if (globMatchSegments(pattern, path, pattern_segment.next, path_start)) return true;

            var current_path_start = path_start;
            while (current_path_start < path.len) {
                const path_segment = globNextSegment(path, current_path_start);
                if (globMatchSegments(pattern, path, pattern_segment.next, path_segment.next)) return true;
                current_path_start = path_segment.next;
            }
            return false;
        }

        if (path_start >= path.len) return false;
        const path_segment = globNextSegment(path, path_start);
        if (!globMatchSegment(pattern_segment.value, path_segment.value)) return false;
        return globMatchSegments(pattern, path, pattern_segment.next, path_segment.next);
    }

    const GlobSegment = struct {
        value: []const u8,
        next: usize,
    };

    fn globNextSegment(value: []const u8, start: usize) GlobSegment {
        var end = start;
        while (end < value.len and value[end] != '/') {
            end += 1;
        }
        return .{
            .value = value[start..end],
            .next = if (end < value.len) end + 1 else end,
        };
    }

    fn globMatchSegment(pattern: []const u8, value: []const u8) bool {
        var pattern_index: usize = 0;
        var value_index: usize = 0;
        var star_pattern_index: ?usize = null;
        var star_value_index: usize = 0;

        while (value_index < value.len) {
            if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
                star_pattern_index = pattern_index;
                star_value_index = value_index;
                pattern_index += 1;
                continue;
            }

            if (pattern_index < pattern.len and
                (pattern[pattern_index] == value[value_index] or pattern[pattern_index] == '?'))
            {
                pattern_index += 1;
                value_index += 1;
                continue;
            }

            if (star_pattern_index) |star_index| {
                pattern_index = star_index + 1;
                star_value_index += 1;
                value_index = star_value_index;
                continue;
            }

            return false;
        }

        while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            pattern_index += 1;
        }

        return pattern_index == pattern.len;
    }

    fn globSort(items: [][]const u8) void {
        std.mem.sort([]const u8, items, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan);
    }

    fn globBasePrefix(pattern: []const u8) []const u8 {
        var prefix_end: usize = 0;
        for (pattern, 0..) |character, index| {
            if (character == '*' or character == '?') break;
            if (character == '/') prefix_end = index + 1;
        }
        return pattern[0..prefix_end];
    }

    fn globHasMagic(pattern: []const u8) bool {
        for (pattern) |character| {
            if (character == '*' or character == '?') return true;
        }
        return false;
    }

    fn stripLeadingCurrentDir(path: []const u8) []const u8 {
        var result = path;
        while (std.mem.startsWith(u8, result, "./")) {
            result = result[2..];
        }
        return result;
    }

    fn stripTrailingSlash(path: []const u8) []const u8 {
        if (path.len > 0 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
        return path;
    }
};

pub const Path = struct {
    pub fn join(a: []const u8, b: []const u8) []const u8 {
        if (a.len == 0) return b;
        if (b.len == 0) return a;
        const need_sep = a[a.len - 1] != '/';
        const total = a.len + b.len + @as(usize, if (need_sep) 1 else 0);
        const result = bumpAllocAt(.path_join, total);
        if (result.len == 0) return "";
        @memcpy(result[0..a.len], a);
        if (need_sep) {
            result[a.len] = '/';
            @memcpy(result[a.len + 1 ..][0..b.len], b);
        } else {
            @memcpy(result[a.len..][0..b.len], b);
        }
        return result;
    }

    pub fn basename(path: []const u8) []const u8 {
        if (path.len == 0) return "";
        var i: usize = path.len;
        while (i > 0) {
            i -= 1;
            if (path[i] == '/') return path[i + 1 ..];
        }
        return path;
    }

    pub fn dirname(path: []const u8) []const u8 {
        if (path.len == 0) return ".";
        var i: usize = path.len;
        while (i > 0) {
            i -= 1;
            if (path[i] == '/') {
                if (i == 0) return "/";
                return path[0..i];
            }
        }
        return ".";
    }

    pub fn extname(path: []const u8) []const u8 {
        const base = basename(path);
        var i: usize = base.len;
        while (i > 0) {
            i -= 1;
            if (base[i] == '.') return base[i..];
        }
        return "";
    }
};

pub const System = struct {
    pub fn cwd() []const u8 {
        var buf: [4096]u8 = undefined;
        const ptr = std.c.getcwd(&buf, buf.len) orelse return "";
        const len = std.mem.sliceTo(ptr, 0).len;
        const result = bumpAllocAt(.system_cwd, len);
        if (result.len == 0) return "";
        @memcpy(result, buf[0..len]);
        return result;
    }

    pub fn get_env(name: []const u8) []const u8 {
        return envGetRuntime(name) orelse "";
    }

    /// Look up a build-time option provided via `-Dkey=value` on the
    /// command line. The compiler bakes these into a runtime-readable
    /// table per-target binary; absent that table (e.g. compiling a
    /// target with no `-D` flags), every name returns the empty
    /// string. Callers must not assume non-empty values exist.
    pub fn get_build_opt(_: []const u8) []const u8 {
        return "";
    }

    pub fn arg_count() i64 {
        const argv = getArgv();
        return if (argv.len > 0) @as(i64, @intCast(argv.len)) - 1 else 0;
    }

    pub fn arg_at(index: i64) []const u8 {
        const argv = getArgv();
        if (index < 0) return "";
        const idx: usize = @intCast(index);
        if (idx + 1 < argv.len) return std.mem.sliceTo(argv[idx + 1], 0);
        return "";
    }
};

// ============================================================
// Tests
// ============================================================

test "Tuple.size returns tuple arity" {
    try std.testing.expectEqual(@as(i64, 3), Tuple.size(.{ 1, "two", true }));
}

test "ArcRuntime.allocAny creates arc-managed value" {
    const val = ArcRuntime.allocAny(i64, std.testing.allocator, 42);
    defer ArcRuntime.freeAny(std.testing.allocator, val);
    try std.testing.expectEqual(@as(i64, 42), val.*);
}

test "ArcRuntime.retainAny and refCountAny" {
    const val = ArcRuntime.allocAny(i64, std.testing.allocator, 99);
    try std.testing.expectEqual(@as(u32, 1), ArcRuntime.refCountAny(val));

    ArcRuntime.retainAny(val);
    try std.testing.expectEqual(@as(u32, 2), ArcRuntime.refCountAny(val));

    // First free decrements but doesn't deallocate
    ArcRuntime.freeAny(std.testing.allocator, val);
    try std.testing.expectEqual(@as(u32, 1), ArcRuntime.refCountAny(val));

    // Second free deallocates
    ArcRuntime.freeAny(std.testing.allocator, val);
}

test "ArcRuntime.releaseAny invokes per-type deep-walk on the zero-transition" {
    // Phase 4.x: the split-phase `prepareReleaseAny` / `destroyPreparedAny`
    // API was removed in favour of a unified `cap.release_sized` slot
    // on the REFCOUNT_V1 vtable. The vtable's `release_sized` walks
    // children via the per-type deep-walk callback BEFORE returning
    // the slot to the slab pool, so the recursive teardown semantics
    // are preserved. This test asserts the manager-driven path
    // through `releaseAny`: alloc -> retain -> release (no-op) ->
    // release (zero-transition + free).
    const alloc = std.testing.allocator;
    const val = ArcRuntime.allocAny(i64, alloc, 7);
    // Second owner — refcount now 2.
    ArcRuntime.retainAny(val);
    try std.testing.expectEqual(@as(u32, 2), ArcRuntime.refCountAny(val));

    // First release decrements 2 -> 1. Cell stays alive.
    ArcRuntime.releaseAny(alloc, val);
    try std.testing.expectEqual(@as(u32, 1), ArcRuntime.refCountAny(val));

    // Second release decrements 1 -> 0; the manager invokes deep_walk
    // (no children for i64) and returns the slot to the slab pool.
    ArcRuntime.releaseAny(alloc, val);
}

test "Phase 4 ABI: ARC manager is bound by default in test builds" {
    // The compile-time default of `active_manager_state.core` points at
    // the test-only ARC fallback in test builds (production binaries
    // bind the externally-linked manager via `maybeBindExternalManager`).
    // Touching any ARC entry point arms the startup hook, validates
    // the vtable, and populates the context.
    _ = ArcRuntime.allocAny(i64, std.testing.allocator, 0);
    // The pre-decrement is the only side effect we care about — we
    // can't `freeAny` here without first validating that the manager
    // is initialised.
    try std.testing.expect(active_manager_state.core != null);
    try std.testing.expect(active_manager_state.context != null);
}

test "Phase 6: runtime_declared_caps defaults to REFCOUNT_V1 in host tests" {
    // The source-level default of `RUNTIME_DECLARED_CAPS_DEFAULT` is
    // `REFCOUNT_V1_BIT` so the host test suite (which loads
    // `runtime.zig` as a Zig module, bypassing the user-binary
    // `compiler.getRuntimeSource()` rewrite) sees the historical ARC-
    // shaped runtime. If this constant ever drifts to `0`, every
    // inline-header test would fail because `Map`/`List`/`MapIter`
    // would lose their `header: ArcHeader` field.
    try std.testing.expectEqual(@as(u64, 1), runtime_declared_caps);
    try std.testing.expect(refcount_v1_active);
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ArcHeader));
}

test "Phase 6: ArcHeaderRefcounted has the REFCOUNT_V1 4-byte shape" {
    // Independent of which variant `ArcHeader` aliases at host-test
    // time, verify the refcounted shape is exactly 4 bytes and the
    // empty shape is exactly 0 bytes. This pair of asserts is the
    // structural invariant the conditional layout depends on: any
    // future field rename, atomic-type swap, or padding drift in
    // either variant breaks Phase 6's layout switch.
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ArcHeaderRefcounted));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(ArcHeaderEmpty));
}

test "Phase 6: ArcHeaderEmpty method shapes match ArcHeaderRefcounted's surface" {
    // Both variants must expose the same method set with the same
    // signatures so call sites can be written manager-agnostically.
    // Verify by exercising each method on a stack instance — under
    // the empty shape they are comptime-no-ops; this test guards
    // against accidental signature drift.
    var empty = ArcHeaderEmpty.init();
    empty.retain();
    const did_free = empty.release();
    try std.testing.expect(!did_free);
    try std.testing.expectEqual(@as(u32, 0), empty.count());
}

test "Phase 6: active_manager_state startup invariants" {
    // Phase 6 packed the six loose dispatcher globals into a single
    // module-private struct (`ActiveManagerState`). This test pins the
    // post-startup invariants every ARC dispatcher depends on:
    //
    //   1. `started == true` (startup ran exactly once).
    //   2. `shutdown_complete == false` (no atexit handler has fired).
    //   3. `core` is non-null — the active manager's core vtable is
    //      bound (test build: `&test_only_arc_core`).
    //   4. `context` is non-null — `core.init()` returned a live
    //      context pointer per spec §4.2.
    //   5. `refcount_capability` is non-null — the test-only manager
    //      declares REFCOUNT_V1 so the dispatcher's refcount path is
    //      armed.
    //   6. `refcount_has_sized_extension` reflects whether the bound
    //      vtable advertises the v1.1 side-table extension. The
    //      test-only manager registers a v1.1 vtable so this is true.
    //
    // The struct is module-private so the dispatcher reads ride on the
    // optimizer's CSE/hoist for `active_manager_state.<field>` loads;
    // this test merely asserts the field-level binding is correct so
    // that drift in the struct shape (e.g., a field rename, a field
    // type change, an init-order regression in `zapMemoryStartup`)
    // surfaces as a test failure rather than as a silent crash on the
    // next ARC dispatch.
    ensureMemoryStartup();
    try std.testing.expect(active_manager_state.started);
    try std.testing.expect(!active_manager_state.shutdown_complete);
    try std.testing.expect(active_manager_state.core != null);
    try std.testing.expect(active_manager_state.context != null);
    try std.testing.expect(active_manager_state.refcount_capability != null);
    // The test-only manager registers the v1.1 surface
    // (`test_only_arc_capability_descriptor` advertises
    // `size == REFCOUNT_V1_SIZE_V1_1`), so the dispatcher's side-table
    // extension flag is set. Under a future test-only manager that
    // declares only the v1.0 surface this assertion would flip; the
    // assertion serves as a witness that startup correctly distinguishes
    // the two surfaces.
    try std.testing.expect(active_manager_state.refcount_has_sized_extension);
}

test "Phase 6: collect_arc_stats default for host tests" {
    // The host test build uses `builtin.is_test == true`, so the
    // source-level `COLLECT_ARC_STATS_DEFAULT` resolves to `true` and
    // every ARC counter increment is compiled in. Every test below in
    // this file that compares counter deltas (e.g.,
    // "Phase 4 ABI: ARC retain/release dispatches through capability")
    // depends on this resolution. A future regression that flips the
    // default surfaces here at the start of the suite instead of as a
    // mid-suite "expected 1, found 0" failure with no breadcrumb.
    try std.testing.expect(collect_arc_stats);
    try std.testing.expect(builtin.is_test);
}

test "Phase 4 ABI: ARC manager declares REFCOUNT_V1 capability" {
    // Force startup if it hasn't run yet.
    ensureMemoryStartup();
    const core = active_manager_state.core orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(u16, 1), core.abi_major);
    try std.testing.expect((core.declared_caps & AbiV1.REFCOUNT_V1_BIT) != 0);
    try std.testing.expect(active_manager_state.refcount_capability != null);
}

test "Phase 4 ABI: ARC retain/release dispatches through capability" {
    // Phase 6 deferral: this test observes counter side effects to
    // infer that dispatch happened, but it does not directly prove
    // the vtable function pointers were called — a dispatcher bug
    // that accidentally bypassed `cap.retain` / `cap.release` while
    // still bumping the counters would slip through. Phase 6 adds a
    // synthetic-capability dispatch test that swaps in a test-owned
    // `ZapRefcountCapabilityV1` whose `retain` / `release` slots
    // increment a private counter; observing that counter directly
    // proves the dispatched call reached the vtable. Deferred to
    // Phase 6 because it requires a manager-swap-during-program
    // surface that spec §10.2 forbids in v1.x — the test would have
    // to special-case test builds, which is uglier than waiting for
    // Phase 6's clean swap API.
    const alloc = std.testing.allocator;

    // List uses the inline-header retain/release path, which routes
    // through the active refcount capability vtable. Build a List,
    // retain, release, release — observe the runtime counters bumped
    // by the dispatcher.
    const start_retains = arc_retains_total;
    const start_releases = arc_releases_total;
    const start_freed = list_release_freed_total;
    const start_kept = list_release_kept_alive_total;

    const ListI64 = List(i64);
    const lst = ListI64.bufferAlloc(1, 0).?;
    _ = ListI64.retain(@as(?*const ListI64, lst));
    ListI64.release(@as(?*const ListI64, lst));
    ListI64.release(@as(?*const ListI64, lst));

    try std.testing.expectEqual(@as(u64, 1), arc_retains_total - start_retains);
    try std.testing.expectEqual(@as(u64, 2), arc_releases_total - start_releases);
    try std.testing.expectEqual(@as(u64, 1), list_release_freed_total - start_freed);
    try std.testing.expectEqual(@as(u64, 1), list_release_kept_alive_total - start_kept);

    _ = alloc;
}

test "Phase 4 ABI: test-only ARC core vtable shape matches spec" {
    // Compile-time invariants on the static vtable that backs the
    // test-only ARC fallback (the in-source equivalent of the
    // external `src/memory/arc/manager.zig`). These are runtime
    // asserts on values whose shape is locked by `AbiV1`'s `comptime`
    // size checks, but running them here makes drift fail loud on
    // the next test pass.
    const core = &test_only_arc_core;
    try std.testing.expectEqual(@as(u16, 1), core.abi_major);
    try std.testing.expectEqual(@as(u16, 0), core.abi_minor);
    try std.testing.expectEqual(@as(u32, @sizeOf(AbiV1.ZapMemoryManagerCoreV1)), core.size);
    try std.testing.expectEqual(@as(u64, 1), core.declared_caps);

    // Function-pointer identity asserts: catch a reorder of the
    // struct-field initialiser in `test_only_arc_core`'s declaration.
    // Without these, swapping (say) `init`'s slot with `deinit`'s
    // initialiser would compile cleanly — both have callconv(.c)
    // signatures the field types coerce into — and pass every
    // shape-level assertion above; only an actual dispatch would
    // surface the swap, and even then only on a slot that's invoked
    // in test (`init` runs via `zapMemoryStartup`, `deinit` only via
    // atexit, etc.). Comparing the function-pointer identity here
    // catches the drift at the next test pass.
    try std.testing.expectEqual(@as(@TypeOf(core.init), testOnlyArcInit), core.init);
    try std.testing.expectEqual(@as(@TypeOf(core.deinit), testOnlyArcDeinit), core.deinit);
    try std.testing.expectEqual(@as(@TypeOf(core.allocate), testOnlyArcAllocateRaw), core.allocate);
    try std.testing.expectEqual(@as(@TypeOf(core.deallocate), testOnlyArcDeallocateRaw), core.deallocate);
    try std.testing.expectEqual(
        @as(@TypeOf(core.get_capability_desc), testOnlyArcGetCapabilityDesc),
        core.get_capability_desc,
    );

    // Confirm that `get_capability_desc(REFC_TAG)` returns a
    // well-formed descriptor and that an unknown tag yields null.
    // Reuse the live context populated by `zapMemoryStartup` (which
    // earlier tests will have armed via their own ARC dispatches).
    ensureMemoryStartup();
    const ctx = active_manager_state.context orelse {
        try std.testing.expect(false);
        return;
    };
    const refc_desc = core.get_capability_desc(ctx, AbiV1.REFC_TAG) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(AbiV1.REFC_TAG, refc_desc.id);
    try std.testing.expectEqual(@as(u16, 1), refc_desc.version);
    try std.testing.expectEqual(@as(u16, @sizeOf(AbiV1.ZapRefcountCapabilityV1)), refc_desc.size);
    try std.testing.expectEqual(@as(u32, 0), refc_desc.flags);

    const unknown_tag: u32 = 0xDEADBEEF;
    try std.testing.expect(core.get_capability_desc(ctx, unknown_tag) == null);
}

test "Phase 4 dispatch: managerHasRefcountV1 partitions tags by capability declaration" {
    // Comptime classifier coverage. The Phase 4 hot-path dispatchers
    // use this predicate to decide whether the first-party direct-call
    // arm is allowed to call the manager's REFCOUNT_V1 aliases. ARC is
    // the only first-party manager that declares REFCOUNT_V1; every
    // other first-party manager (Arena, NoOp, Leak, Tracking) exposes
    // the uniform interface with panic stubs. The `.third_party` arm
    // also returns false — third-party builds dispatch through the
    // vtable and consult `active_manager_state.refcount_capability` dynamically
    // rather than relying on this comptime predicate. A change to any
    // of these answers would silently miscompile the runtime under one
    // of the affected managers; pin the classifier here so a future
    // regression surfaces immediately.
    try std.testing.expectEqual(true, managerHasRefcountV1(.arc));
    try std.testing.expectEqual(false, managerHasRefcountV1(.arena));
    try std.testing.expectEqual(false, managerHasRefcountV1(.no_op));
    try std.testing.expectEqual(false, managerHasRefcountV1(.leak));
    try std.testing.expectEqual(false, managerHasRefcountV1(.tracking));
    try std.testing.expectEqual(false, managerHasRefcountV1(.third_party));
}

test "Phase 4 dispatch: ACTIVE_MANAGER_TAG defaults to .third_party in host test builds" {
    // The host test suite loads `runtime.zig` as a Zig module without
    // going through `compiler.getRuntimeSource`'s tag rewrite, so the
    // source-level default of `.third_party` must survive verbatim.
    // Phase 4's vtable-dispatch arm is exercised by the host tests for
    // exactly this reason: a regression that flipped the default to
    // (say) `.arc` would silently exercise the first-party direct-call
    // arm in tests while the runtime ABI assumes the vtable path.
    try std.testing.expectEqual(ActiveManagerTag.third_party, ACTIVE_MANAGER_TAG);
}

test "Phase 4: active_manager uniform interface signatures match the manager-ABI vtable slot types" {
    // Force semantic analysis of every uniform-interface symbol against
    // its expected vtable signature. In host test builds
    // `ACTIVE_MANAGER_TAG == .third_party`, which means every
    // `active_manager.<fn>(...)` call site in the runtime's dispatchers
    // is dead-code-eliminated at the comptime branch — a typo like
    // `active_manager.retainSizedd(...)` would compile clean and only
    // surface at Phase 5/6 user-binary compile time.
    //
    // Pinning each alias to its expected canonical slot signature here
    // forces the compiler to type-check the first-party arm in the
    // host build. If a first-party manager's alias (or the third-party
    // stub's matching panic body) drifts from the ABI slot signature,
    // this test fails at host-build time rather than at user-binary
    // link time.
    //
    // Note: in host test builds `active_manager` resolves to
    // `src/zap_active_manager_stub.zig`, which exports panic-typed
    // bodies with the exact signatures below. Real first-party
    // managers are pinned in their own per-manager `comptime` blocks.
    //
    // The signatures below are scoped to the slots actually invoked
    // through the comptime first-party arm: `allocate`, `deallocate`,
    // `allocateRefcounted`, `retain`, `release`, `retainSized`,
    // `releaseSized`, `refcountSized`. The `init`, `deinit`, and
    // `getCapabilityDesc` slots are consumed via the runtime's core
    // vtable (a `*const ZapMemoryManagerCoreV1` populated at manager
    // bind time), never through a direct `active_manager.<fn>` call,
    // so their nominal extern-struct parameter types (which differ
    // between `AbiV1` and the stub's self-contained redeclaration —
    // extern structs are nominal in Zig even when layouts are
    // identical) are not in scope for this test. Each first-party
    // manager's own per-module `comptime` block pins those slots
    // against its locally-declared ABI types.

    // Slot signatures invoked from the runtime's comptime first-party
    // arm. These use only primitive types and function pointers (which
    // ARE structural in Zig), so they pin cleanly against the
    // third-party stub's panic bodies as well.
    const DeepWalkFn = *const fn (object: *anyopaque) callconv(.c) void;
    const AllocateFn = *const fn (ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8;
    const DeallocateFn = *const fn (ctx: *anyopaque, ptr: [*]u8, size: usize, alignment: u32) callconv(.c) void;
    const RetainFn = *const fn (ctx: *anyopaque, object: *anyopaque) callconv(.c) void;
    const ReleaseFn = *const fn (ctx: *anyopaque, object: *anyopaque, deep_walk: ?DeepWalkFn) callconv(.c) void;
    const RetainSizedFn = *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void;
    const ReleaseSizedFn = *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32, deep_walk: ?DeepWalkFn) callconv(.c) void;
    const AllocateRefcountedFn = *const fn (ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8;
    const RefcountSizedFn = *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32;

    // Pin each uniform-interface alias to its expected signature. The
    // `comptime _ = @as(T, value)` form forces semantic analysis at
    // the test site without emitting runtime code; if any signature
    // drifts, this file fails to compile under `zig build test`. The
    // existence checks for `init`/`deinit`/`getCapabilityDesc` use
    // `@TypeOf(...)` (which only requires the symbol be defined,
    // without coercing the nominal extern-struct parameter types) so
    // the test still catches a missing symbol while delegating
    // shape-of-the-extern-struct validation to each manager's own
    // module-scope comptime block.
    comptime {
        _ = @TypeOf(active_manager.init);
        _ = @TypeOf(active_manager.deinit);
        _ = @TypeOf(active_manager.getCapabilityDesc);

        _ = @as(AllocateFn, active_manager.allocate);
        _ = @as(DeallocateFn, active_manager.deallocate);
        _ = @as(RetainFn, active_manager.retain);
        _ = @as(ReleaseFn, active_manager.release);
        _ = @as(RetainSizedFn, active_manager.retainSized);
        _ = @as(ReleaseSizedFn, active_manager.releaseSized);
        _ = @as(AllocateRefcountedFn, active_manager.allocateRefcounted);
        _ = @as(RefcountSizedFn, active_manager.refcountSized);
    }
}

test "releaseChildrenAny releases ?*const Map(K, V) field" {
    // Phase F regression test: when a struct holds a `?*const Map(K, V)`
    // child field, `releaseChildrenAny` must walk the field via
    // `releaseFieldChildAny` -> `releaseArcAny` and dispatch into the
    // Map's inline-header `release` method. Prior to Phase F the `.map`
    // type was not flagged as ARC-managed at the IR level, so this code
    // path was never exercised through the codegen. Now that `.map` is
    // ARC-managed, the runtime helper that releases struct children
    // must correctly recognize the inline-header path and avoid the
    // `Arc(T)`-wrapper double-counting that would arise if it routed
    // through `prepareReleaseAny`.
    const MapI64 = Map(i64, i64);

    const before_releases = arc_releases_total;

    const keys = [_]i64{ 1, 2, 3 };
    const vals = [_]i64{ 10, 20, 30 };
    const map_ptr = MapI64.fromPairs(&keys, &vals, 3) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(i64, 20), MapI64.get(map_ptr, 2, -1));

    // Wrap the Map pointer inside a struct, mimicking the codegen-emitted
    // shape for an aggregate that owns a Map child via an indirect-storage
    // optional pointer field.
    const Holder = struct {
        map_field: ?*const MapI64,
        scalar: i64,
    };
    const holder = Holder{ .map_field = map_ptr, .scalar = 7 };

    // releaseChildrenAny must traverse `map_field` and invoke the Map's
    // inline-header `release` (not the generic Arc(T) path). The non-arc
    // `scalar` field must be skipped without compile error.
    ArcRuntime.releaseChildrenAny(Holder, std.testing.allocator, holder);

    // The Map's `release` bumps `arc_releases_total` exactly once when it
    // hits the zero-transition. The generic wrapper short-circuits the
    // bump for inline-header types, so we expect exactly one release tick.
    try std.testing.expectEqual(before_releases + 1, arc_releases_total);
}

test "Atom well-known values" {
    try std.testing.expectEqual(@as(u32, 0), Atom.nil.id);
    try std.testing.expectEqual(@as(u32, 1), Atom.true.id);
    try std.testing.expect(Atom.nil.eql(Atom.nil));
    try std.testing.expect(!Atom.nil.eql(Atom.true));
}

test "AtomTable intern and retrieve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var table = AtomTable.init(alloc);
    defer table.deinit();

    const hello = try table.intern("hello");
    const world = try table.intern("world");
    const hello2 = try table.intern("hello");

    try std.testing.expect(hello.eql(hello2));
    try std.testing.expect(!hello.eql(world));
    try std.testing.expectEqualStrings("hello", table.getName(hello));
    try std.testing.expectEqualStrings("world", table.getName(world));

    // Well-known atoms should exist
    try std.testing.expectEqualStrings("nil", table.getName(Atom.nil));
    try std.testing.expectEqualStrings("true", table.getName(Atom.true));
}

test "String operations" {
    try std.testing.expect(String.contains("hello world", "world"));
    try std.testing.expect(!String.contains("hello world", "xyz"));
    try std.testing.expect(String.startsWith("hello", "hel"));
    try std.testing.expect(String.endsWith("hello", "llo"));
    try std.testing.expectEqualStrings("llo", String.slice("hello", 2, 5));
    try std.testing.expectEqualStrings("hello", String.trim("  hello  "));
}

test "String concat" {
    try std.testing.expectEqualStrings("hello world", String.concat("hello", " world"));
}

test "String concat: in-place extend preserves prefix observers" {
    // Tail-recursive accumulator pattern (`clean_line` in k-nucleotide):
    // `acc = concat(acc, ch)` on the most-recent arena allocation should
    // hit the `tryArenaExtend` fast path and keep `acc.ptr` stable. The
    // first concat seeds the arena (literal `a.len == 0` -> falls back
    // to `bumpAllocAt`); every subsequent concat extends in place. This
    // test asserts the load-bearing property that the buffer pointer
    // does not move across in-place extensions — if the fast path
    // regresses to allocate-and-copy, `acc.ptr` would change on each
    // call and the cumulative arena allocation pattern returns to the
    // pre-fix O(n²) shape.
    var acc: []const u8 = "";
    acc = String.concat(acc, "A");
    const seed_ptr = acc.ptr;
    acc = String.concat(acc, "C");
    try std.testing.expectEqualStrings("AC", acc);
    try std.testing.expectEqual(seed_ptr, acc.ptr);
    acc = String.concat(acc, "G");
    try std.testing.expectEqualStrings("ACG", acc);
    try std.testing.expectEqual(seed_ptr, acc.ptr);
    acc = String.concat(acc, "T");
    try std.testing.expectEqualStrings("ACGT", acc);
    try std.testing.expectEqual(seed_ptr, acc.ptr);
}

test "String concat: empty right-hand returns identity" {
    // Skipping the resize round-trip when `b` is empty saves a branch
    // and an arena lookup. The pre-existing path also returned the
    // requested result via the `a.len + b.len == a.len` no-op @memcpy,
    // but the explicit guard avoids touching the arena entirely when
    // there's nothing to append.
    const literal: []const u8 = "abc";
    try std.testing.expectEqualStrings("abc", String.concat(literal, ""));
}

test "String concat: literal left-hand allocates fresh buffer" {
    // When `a` is a `.rodata` literal (not in the arena), the
    // `tryArenaExtend` path returns false via
    // `runtime_arena.allocator().resize`'s internal address comparison,
    // and we fall back to the bump-alloc copy path. The returned slice
    // must NOT alias the literal — its bytes must equal `a ++ b`, and
    // the literal `a` must remain unchanged.
    const a: []const u8 = "hello";
    const result = String.concat(a, " world");
    try std.testing.expectEqualStrings("hello world", result);
    try std.testing.expectEqualStrings("hello", a);
}

test "String concat: in-place extend is O(n) in arena bytes" {
    // Without the fast path, a tail-recursive accumulator of N
    // single-byte appends allocates 1 + 2 + 3 + ... + N = N*(N+1)/2
    // bytes through the arena (O(N^2)). With the fast path, the seed
    // allocates 1 byte and every subsequent extension grows the active
    // arena allocation by exactly 1 byte (O(N) cumulative bytes
    // observed by recordBump). This test pins the asymptotic behaviour
    // for a representative `N = 64` (close to k-nucleotide's typical
    // FASTA line length of 60).
    const baseline_string_concat_bytes = bump_site_bytes[@intFromEnum(BumpSite.string_concat)];
    var acc: []const u8 = "";
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        acc = String.concat(acc, "A");
    }
    try std.testing.expectEqual(@as(usize, 64), acc.len);
    const delta = bump_site_bytes[@intFromEnum(BumpSite.string_concat)] - baseline_string_concat_bytes;
    // Fast-path correctness bound: seed of 1 byte + 63 single-byte
    // extensions = 64 bytes recorded. The pre-fix path would record
    // 64 * 65 / 2 = 2080 bytes. Allow a 4x ceiling to absorb the
    // small (one-time) bumpAllocAt 8-byte alignment of the seed plus
    // anything unrelated this test might trigger; the gap between
    // worst-case fast-path and worst-case slow-path is >25x.
    try std.testing.expect(delta < 256);
}

test "List(i64) sliceFrom returns indexed suffix" {
    const ListI64 = List(i64);
    var list = ListI64.new_empty(0) orelse @panic("test list allocation failed");
    list = ListI64.push(list, 10) orelse @panic("push failed");
    list = ListI64.push(list, 20) orelse @panic("push failed");
    list = ListI64.push(list, 30) orelse @panic("push failed");
    list = ListI64.push(list, 40) orelse @panic("push failed");
    defer ListI64.release(list);

    const suffix = ListI64.sliceFrom(list, 2) orelse @panic("sliceFrom returned null");
    defer ListI64.release(suffix);
    try std.testing.expectEqual(@as(i64, 2), ListI64.length(suffix));
    try std.testing.expectEqual(@as(i64, 30), ListI64.get(suffix, 0));

    try std.testing.expect(ListI64.sliceFrom(list, 4) == null);
}

// ============================================================
// Map workload instrumentation differential tests (Phase A)
//
// These three tests validate the S/W/V classifier against three
// canonical lifetime patterns. They are gated by `comptime if
// (instrument_map)`: when the compiler is built with the default
// `-Dinstrument-map=false` they pass trivially, and when built with
// `-Dinstrument-map=true` they exercise the full classifier path.
// ============================================================

test "instrumentation: S — never shared" {
    if (!comptime instrument_map) return;
    const MapI64 = Map(i64, i64);
    const before_id = mapInstrumentationLastInstanceId();
    const m_initial = MapI64.put(null, 1, 100) orelse {
        try std.testing.expect(false);
        return;
    };
    var m: ?*const MapI64 = m_initial;
    var k: i64 = 2;
    while (k <= 5) : (k += 1) {
        const next_m = MapI64.put(m, k, k * 100) orelse {
            try std.testing.expect(false);
            return;
        };
        MapI64.release(m);
        m = next_m;
    }
    // First derived id is `before_id + 1`. We re-resolve via a probe:
    // the initial allocation registered exactly one instance with the
    // first-allocated cell pointer, which became the parent for the
    // four follow-up `put` calls. Releasing m releases the chain head.
    MapI64.release(m);

    // Walk the finalised list looking for the chain we just produced
    // (lineage_id was assigned to the first allocation; every put
    // inherited it via the parent context). We expect 5 records (one
    // per allocation), all class S with peak_strong_count = 1.
    var saw_first: bool = false;
    var seen_class_S: u32 = 0;
    var puts_on_first: u32 = 0;
    var gets_on_first: u32 = 0;
    for (instrumentation_state.finalised.items) |rec| {
        if (rec.instance_id <= before_id) continue;
        try std.testing.expectEqual(@as(u32, 1), rec.peak_strong_count);
        if (rec.class == 'S') seen_class_S += 1;
        if (!saw_first and rec.parent_instance_id == 0) {
            saw_first = true;
            puts_on_first = rec.puts;
            gets_on_first = rec.gets;
        }
    }
    try std.testing.expect(seen_class_S >= 5);
    try std.testing.expect(saw_first);
    // The first map had four `put` calls applied to it (the chain
    // wraps it four times before the final release).
    try std.testing.expectEqual(@as(u32, 1), puts_on_first);
    try std.testing.expectEqual(@as(u32, 0), gets_on_first);
}

test "instrumentation: W — shared but never post-share-mutated" {
    if (!comptime instrument_map) return;
    const MapI64 = Map(i64, i64);
    const m = MapI64.put(null, 1, 100) orelse {
        try std.testing.expect(false);
        return;
    };
    const cell_ptr = @intFromPtr(m);
    const initial_record = instrumentation_state.active.getPtr(cell_ptr).?;
    const instance_id = initial_record.instance_id;

    // Share by retaining — refcount goes 1 → 2.
    _ = MapI64.retain(m);
    // Drop the share without mutating — refcount returns to 1.
    MapI64.release(m);
    // Final release — class W expected (had_share_event=true,
    // had_post_share_mutation=false).
    MapI64.release(m);

    const rec = mapInstrumentationFindFinalised(0, instance_id) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(rec.had_share_event);
    try std.testing.expect(!rec.had_post_share_mutation);
    try std.testing.expectEqual(@as(u8, 'W'), rec.class);
    try std.testing.expectEqual(@as(u32, 2), rec.peak_strong_count);
}

test "instrumentation: V — shared and post-share-mutated" {
    if (!comptime instrument_map) return;
    const MapI64 = Map(i64, i64);
    const original = MapI64.put(null, 1, 100) orelse {
        try std.testing.expect(false);
        return;
    };
    const original_ptr = @intFromPtr(original);
    const original_id = instrumentation_state.active.getPtr(original_ptr).?.instance_id;

    // Share — refcount goes 1 → 2 — `had_share_event` flips on.
    _ = MapI64.retain(original);

    // Mutate while still shared. `put` allocates a fresh derived map.
    const derived = MapI64.put(original, 2, 200) orelse {
        try std.testing.expect(false);
        return;
    };
    // The mutation hook should have flagged `had_post_share_mutation`
    // on the original cell.

    // Release the second share, then the original cell, then the
    // derived. We expect the original cell to land in finalised with
    // class V.
    MapI64.release(original);
    MapI64.release(original);
    MapI64.release(derived);

    const rec = mapInstrumentationFindFinalised(0, original_id) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(rec.had_share_event);
    try std.testing.expect(rec.had_post_share_mutation);
    try std.testing.expectEqual(@as(u8, 'V'), rec.class);
}

// ============================================================
// List(T) — renamed flat-buffer mutable array
// ============================================================

test "List(i64) new_filled allocates and initialises every slot" {
    const ListI64 = List(i64);
    const v = ListI64.new_filled(5, 7) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(v);

    try std.testing.expectEqual(@as(i64, 5), ListI64.length(v));
    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expectEqual(@as(i64, 7), ListI64.get(v, i));
    }
}

test "List(i64) new_empty allocates with reserved capacity and zero len" {
    const ListI64 = List(i64);
    const v = ListI64.new_empty(8) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(v);

    try std.testing.expectEqual(@as(i64, 0), ListI64.length(v));
    try std.testing.expect(ListI64.capacity(v) >= 8);
}

test "List(i64) get/set roundtrips on rc==1 buffer returns same handle" {
    const ListI64 = List(i64);
    const v = ListI64.new_filled(3, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(v);

    const after_set = ListI64.set(v, 1, 42) orelse {
        try std.testing.expect(false);
        return;
    };
    // rc==1 fast path: same handle returned, in-place mutation.
    try std.testing.expectEqual(@intFromPtr(v), @intFromPtr(after_set));
    try std.testing.expectEqual(@as(i64, 42), ListI64.get(after_set, 1));
}

test "List(i64) set on rc>1 buffer clones; original stays unchanged" {
    const ListI64 = List(i64);
    const original = ListI64.new_filled(3, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(original);

    // Bump refcount; now `set` must COW.
    const shared = ListI64.retain(original);
    defer ListI64.release(shared);

    const updated = ListI64.set(original, 1, 99) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(updated);

    try std.testing.expect(@intFromPtr(updated) != @intFromPtr(original));
    // Original unchanged.
    try std.testing.expectEqual(@as(i64, 0), ListI64.get(original, 1));
    // Updated has the new value.
    try std.testing.expectEqual(@as(i64, 99), ListI64.get(updated, 1));
}

test "List(i64) push grows length and persists value (rc==1)" {
    const ListI64 = List(i64);
    const v0 = ListI64.new_empty(2) orelse {
        try std.testing.expect(false);
        return;
    };
    const v1 = ListI64.push(v0, 10) orelse {
        try std.testing.expect(false);
        return;
    };
    const v2 = ListI64.push(v1, 20) orelse {
        try std.testing.expect(false);
        return;
    };
    // rc==1: each push reuses buffer (until capacity is exceeded).
    const v3 = ListI64.push(v2, 30) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(v3);

    try std.testing.expectEqual(@as(i64, 3), ListI64.length(v3));
    try std.testing.expectEqual(@as(i64, 10), ListI64.get(v3, 0));
    try std.testing.expectEqual(@as(i64, 20), ListI64.get(v3, 1));
    try std.testing.expectEqual(@as(i64, 30), ListI64.get(v3, 2));
}

test "List(i64) push past capacity triggers in-place grow on rc==1" {
    const ListI64 = List(i64);
    var current: ?*const ListI64 = ListI64.new_empty(2) orelse {
        try std.testing.expect(false);
        return;
    };
    var i: i64 = 0;
    while (i < 16) : (i += 1) {
        current = ListI64.push(current, i) orelse {
            try std.testing.expect(false);
            return;
        };
    }
    defer ListI64.release(current);

    try std.testing.expectEqual(@as(i64, 16), ListI64.length(current));
    var k: i64 = 0;
    while (k < 16) : (k += 1) {
        try std.testing.expectEqual(k, ListI64.get(current, k));
    }
    try std.testing.expect(ListI64.capacity(current) >= 16);
}

test "List(i64) pop decrements length on rc==1" {
    const ListI64 = List(i64);
    const v = ListI64.new_filled(3, 7) orelse {
        try std.testing.expect(false);
        return;
    };
    const popped = ListI64.pop(v) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(popped);

    try std.testing.expectEqual(@intFromPtr(v), @intFromPtr(popped));
    try std.testing.expectEqual(@as(i64, 2), ListI64.length(popped));
}

test "List(i64) append concatenates two buffers in correct order" {
    const ListI64 = List(i64);
    var a: ?*const ListI64 = ListI64.new_empty(0) orelse {
        try std.testing.expect(false);
        return;
    };
    a = ListI64.push(a, 1) orelse {
        try std.testing.expect(false);
        return;
    };
    a = ListI64.push(a, 2) orelse {
        try std.testing.expect(false);
        return;
    };

    var b: ?*const ListI64 = ListI64.new_empty(0) orelse {
        try std.testing.expect(false);
        return;
    };
    b = ListI64.push(b, 3) orelse {
        try std.testing.expect(false);
        return;
    };
    b = ListI64.push(b, 4) orelse {
        try std.testing.expect(false);
        return;
    };

    const result = ListI64.append(a, b) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(result);
    defer ListI64.release(b);

    try std.testing.expectEqual(@as(i64, 4), ListI64.length(result));
    try std.testing.expectEqual(@as(i64, 1), ListI64.get(result, 0));
    try std.testing.expectEqual(@as(i64, 2), ListI64.get(result, 1));
    try std.testing.expectEqual(@as(i64, 3), ListI64.get(result, 2));
    try std.testing.expectEqual(@as(i64, 4), ListI64.get(result, 3));
}

test "List(i64) append self grows without reading freed storage" {
    const ListI64 = List(i64);
    var values: ?*const ListI64 = ListI64.new_empty(2) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push(values, 1) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push(values, 2) orelse {
        try std.testing.expect(false);
        return;
    };

    const result = ListI64.append(values, values) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(result);

    try std.testing.expectEqual(@as(i64, 4), ListI64.length(result));
    try std.testing.expectEqual(@as(i64, 1), ListI64.get(result, 0));
    try std.testing.expectEqual(@as(i64, 2), ListI64.get(result, 1));
    try std.testing.expectEqual(@as(i64, 1), ListI64.get(result, 2));
    try std.testing.expectEqual(@as(i64, 2), ListI64.get(result, 3));
}

test "List(i64) cons on null tail allocates fresh single-element buffer" {
    const before_calls = list_cons_calls_total;
    const ListI64 = List(i64);
    const result = ListI64.cons(42, null) orelse return error.OutOfMemory;
    defer ListI64.release(result);

    try std.testing.expectEqual(@as(i64, 1), ListI64.length(result));
    try std.testing.expectEqual(@as(i64, 42), ListI64.get(result, 0));
    try std.testing.expectEqual(@as(u32, 1), result.header.count());
    try std.testing.expectEqual(before_calls + 1, list_cons_calls_total);
}

test "List(i64) cons on rc==1 tail with spare capacity mutates in place" {
    const ListI64 = List(i64);
    var tail: ?*const ListI64 = ListI64.new_empty(8) orelse return error.OutOfMemory;
    tail = ListI64.push(tail, 20) orelse return error.OutOfMemory;
    tail = ListI64.push(tail, 30) orelse return error.OutOfMemory;
    const before_ptr = @intFromPtr(tail.?);

    const before_inplace = list_cons_rc1_inplace_total;
    const result = ListI64.cons(10, tail) orelse return error.OutOfMemory;
    defer ListI64.release(result);

    // Same pointer — the fast path mutated in place.
    try std.testing.expectEqual(before_ptr, @intFromPtr(result));
    try std.testing.expectEqual(before_inplace + 1, list_cons_rc1_inplace_total);

    try std.testing.expectEqual(@as(i64, 3), ListI64.length(result));
    try std.testing.expectEqual(@as(i64, 10), ListI64.get(result, 0));
    try std.testing.expectEqual(@as(i64, 20), ListI64.get(result, 1));
    try std.testing.expectEqual(@as(i64, 30), ListI64.get(result, 2));
}

test "List(i64) cons on rc==1 tail at capacity grows and frees old buffer" {
    const ListI64 = List(i64);
    var tail: ?*const ListI64 = ListI64.new_empty(2) orelse return error.OutOfMemory;
    tail = ListI64.push(tail, 5) orelse return error.OutOfMemory;
    tail = ListI64.push(tail, 6) orelse return error.OutOfMemory;
    // Tail has cap=4 now (push grew once); fill it.
    tail = ListI64.push(tail, 7) orelse return error.OutOfMemory;
    tail = ListI64.push(tail, 8) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(i64, 4), ListI64.length(tail));
    try std.testing.expectEqual(@as(i64, 4), ListI64.capacity(tail));

    const before_grow = list_cons_rc1_grow_total;
    const result = ListI64.cons(1, tail) orelse return error.OutOfMemory;
    defer ListI64.release(result);

    try std.testing.expectEqual(before_grow + 1, list_cons_rc1_grow_total);
    try std.testing.expectEqual(@as(i64, 5), ListI64.length(result));
    try std.testing.expect(ListI64.capacity(result) >= 5);
    try std.testing.expectEqual(@as(i64, 1), ListI64.get(result, 0));
    try std.testing.expectEqual(@as(i64, 5), ListI64.get(result, 1));
    try std.testing.expectEqual(@as(i64, 6), ListI64.get(result, 2));
    try std.testing.expectEqual(@as(i64, 7), ListI64.get(result, 3));
    try std.testing.expectEqual(@as(i64, 8), ListI64.get(result, 4));
    try std.testing.expectEqual(@as(u32, 1), result.header.count());
}

test "List(i64) cons on rc>1 tail clones with deep-retain and leaves original intact" {
    const ListI64 = List(i64);
    var tail: ?*const ListI64 = ListI64.new_empty(4) orelse return error.OutOfMemory;
    tail = ListI64.push(tail, 100) orelse return error.OutOfMemory;
    tail = ListI64.push(tail, 200) orelse return error.OutOfMemory;
    defer ListI64.release(tail);

    // Retain to bump rc to 2 — simulates a shared owner.
    const shared = ListI64.retain(tail);
    try std.testing.expectEqual(@as(u32, 2), tail.?.header.count());

    const before_shared = list_cons_shared_total;
    const result = ListI64.cons(99, shared) orelse return error.OutOfMemory;
    defer ListI64.release(result);

    try std.testing.expectEqual(before_shared + 1, list_cons_shared_total);
    // Fresh pointer — clone path was taken.
    try std.testing.expect(@intFromPtr(result) != @intFromPtr(tail.?));
    // Tail's refcount dropped by one — the cons consumed the borrowed owner.
    try std.testing.expectEqual(@as(u32, 1), tail.?.header.count());

    try std.testing.expectEqual(@as(i64, 3), ListI64.length(result));
    try std.testing.expectEqual(@as(i64, 99), ListI64.get(result, 0));
    try std.testing.expectEqual(@as(i64, 100), ListI64.get(result, 1));
    try std.testing.expectEqual(@as(i64, 200), ListI64.get(result, 2));

    // Original tail is unchanged.
    try std.testing.expectEqual(@as(i64, 2), ListI64.length(tail));
    try std.testing.expectEqual(@as(i64, 100), ListI64.get(tail, 0));
    try std.testing.expectEqual(@as(i64, 200), ListI64.get(tail, 1));
}

test "List(i64) repeated cons on rc==1 keeps allocations O(log n)" {
    // Validates that the rc-1 fast path produces amortized O(log n)
    // capacity doublings even for n=128 prepends. Before the fast
    // path, each cons re-allocated a buffer sized exactly to the
    // new length — O(n) allocations totalling O(n²) bytes.
    const ListI64 = List(i64);
    var current: ?*const ListI64 = null;
    const before_alloc_bytes = list_cons_alloc_bytes;

    var i: i64 = 0;
    while (i < 128) : (i += 1) {
        current = ListI64.cons(i, current) orelse return error.OutOfMemory;
    }
    defer ListI64.release(current);

    try std.testing.expectEqual(@as(i64, 128), ListI64.length(current));
    try std.testing.expectEqual(@as(i64, 127), ListI64.get(current, 0));
    try std.testing.expectEqual(@as(i64, 0), ListI64.get(current, 127));

    // The doubling pattern yields capacities 4, 8, 16, ..., 128
    // (5 capacity transitions for 128 entries). Each grow allocates
    // bufferSize(cap) bytes. Total bytes should be < 16 KB —
    // dramatically less than the O(n²) shape's 128 KB+.
    const allocated = list_cons_alloc_bytes - before_alloc_bytes;
    try std.testing.expect(allocated < 16 * 1024);
}

test "listSum bridge dispatches to concrete List(i64) sum" {
    const ListI64 = List(i64);
    var values: ?*const ListI64 = ListI64.new_empty(4) orelse return error.OutOfMemory;
    values = ListI64.push(values, 10) orelse return error.OutOfMemory;
    values = ListI64.push(values, -3) orelse return error.OutOfMemory;
    values = ListI64.push(values, 25) orelse return error.OutOfMemory;
    defer ListI64.release(values);

    try std.testing.expectEqual(@as(i64, 32), listSum(values));
    try std.testing.expectEqual(@as(i64, 0), listSum(@as(?*const ListI64, null)));
}

test "listSum bridge supports concrete List(f64) sum" {
    const ListF64 = List(f64);
    var values: ?*const ListF64 = ListF64.new_empty(3) orelse return error.OutOfMemory;
    values = ListF64.push(values, 1.5) orelse return error.OutOfMemory;
    values = ListF64.push(values, -2.25) orelse return error.OutOfMemory;
    values = ListF64.push(values, 5.75) orelse return error.OutOfMemory;
    defer ListF64.release(values);

    try std.testing.expectEqual(@as(f64, 5.0), listSum(values));
    try std.testing.expectEqual(@as(f64, 0.0), listSum(@as(?*const ListF64, null)));
}

test "listSum bridge uses SIMD lane width for integer lists when target exposes one" {
    const lane_count = listSumSimdLaneCount(i64);
    if (std.simd.suggestVectorLength(i64)) |suggested_lane_count| {
        try std.testing.expectEqual(@as(comptime_int, suggested_lane_count), lane_count);
        try std.testing.expect(lane_count > 1);
    } else {
        try std.testing.expectEqual(@as(comptime_int, 1), lane_count);
    }
}

test "listSum bridge handles SIMD chunks and scalar tail for List(i64)" {
    const ListI64 = List(i64);
    const lane_count = listSumSimdLaneCount(i64);
    const item_count = lane_count * 3 + 5;
    var values: ?*const ListI64 = ListI64.new_empty(item_count) orelse return error.OutOfMemory;
    var expected: i64 = 0;
    var index: i64 = 0;
    while (index < item_count) : (index += 1) {
        const value = if (@mod(index, 2) == 0) index else -index;
        expected += value;
        values = ListI64.push(values, value) orelse return error.OutOfMemory;
    }
    defer ListI64.release(values);

    try std.testing.expectEqual(expected, listSum(values));
}

test "List(i64) retain/release roundtrips refcount" {
    const ListI64 = List(i64);
    const v = ListI64.new_filled(2, 99) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(u32, 1), v.header.count());

    const second = ListI64.retain(v);
    try std.testing.expectEqual(@as(u32, 2), v.header.count());

    // First release: count drops to 1, buffer alive.
    ListI64.release(second);
    try std.testing.expectEqual(@as(u32, 1), v.header.count());

    // Final release: buffer freed.
    ListI64.release(v);
}

test "List(f64) initialises slots and round-trips writes (rc==1 in place)" {
    const ListF64 = List(f64);
    const v = ListF64.new_filled(4, 1.5) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(i64, 4), ListF64.length(v));
    try std.testing.expectEqual(@as(f64, 1.5), ListF64.get(v, 2));

    const after_set = ListF64.set(v, 2, 2.75) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@intFromPtr(v), @intFromPtr(after_set));
    try std.testing.expectEqual(@as(f64, 2.75), ListF64.get(after_set, 2));
    ListF64.release(after_set);
}

test "List([]const u8) runtime string slices round-trip" {
    const StringList = List([]const u8);
    var strings: ?*const StringList = StringList.new_empty(2) orelse {
        try std.testing.expect(false);
        return;
    };
    strings = StringList.push(strings, "hello") orelse {
        try std.testing.expect(false);
        return;
    };
    strings = StringList.push(strings, "world") orelse {
        try std.testing.expect(false);
        return;
    };
    defer StringList.release(strings);

    try std.testing.expectEqual(@as(i64, 2), StringList.length(strings));
    try std.testing.expectEqualStrings("hello", StringList.get(strings, 0));
    try std.testing.expectEqualStrings("world", StringList.get(strings, 1));
}

test "List deep-releases ARC-managed children on zero-transition" {
    // Phase 2: when T is an ARC-managed pointer (e.g. ?*const Map(K, V)),
    // List(T)'s release on the zero-transition must walk every live
    // element and deep-release it. We mirror the Map and List
    // regression-test pattern.
    const MapI64 = Map(i64, i64);
    const ListMap = List(?*const MapI64);

    const before_releases = arc_releases_total;

    const keys_one = [_]i64{ 1, 2 };
    const vals_one = [_]i64{ 10, 20 };
    const map_one = MapI64.fromPairs(&keys_one, &vals_one, 2) orelse {
        try std.testing.expect(false);
        return;
    };
    const keys_two = [_]i64{ 3, 4 };
    const vals_two = [_]i64{ 30, 40 };
    const map_two = MapI64.fromPairs(&keys_two, &vals_two, 2) orelse {
        try std.testing.expect(false);
        return;
    };

    var vec: ?*const ListMap = ListMap.new_empty(2) orelse {
        try std.testing.expect(false);
        return;
    };
    // `push` consumes the value (as the cell's durable owner), so each
    // pushed Map's +1 transfers into the List.
    vec = ListMap.push(vec, map_one) orelse {
        try std.testing.expect(false);
        return;
    };
    vec = ListMap.push(vec, map_two) orelse {
        try std.testing.expect(false);
        return;
    };

    // Release the buffer. The List's own `release` bumps
    // `arc_releases_total` once (unconditionally, mirroring Map's
    // pattern). On the zero-transition the deep-release walk fires
    // `release` on each child Map, bumping the counter twice more
    // (one per Map cell freed). Net: +3.
    ListMap.release(vec);
    try std.testing.expectEqual(before_releases + 3, arc_releases_total);
}

test "List(T) deep-releases struct elements with ARC-managed fields" {
    const MapI64 = Map(i64, i64);
    const Holder = struct {
        child: ?*const MapI64,
        label: i64,
    };
    const HolderList = List(Holder);

    const before_releases = arc_releases_total;

    const keys_one = [_]i64{ 1, 2 };
    const vals_one = [_]i64{ 10, 20 };
    const map_one = MapI64.fromPairs(&keys_one, &vals_one, 2) orelse {
        try std.testing.expect(false);
        return;
    };
    const keys_two = [_]i64{ 3, 4 };
    const vals_two = [_]i64{ 30, 40 };
    const map_two = MapI64.fromPairs(&keys_two, &vals_two, 2) orelse {
        try std.testing.expect(false);
        return;
    };

    var holders: ?*const HolderList = HolderList.new_empty(2) orelse {
        try std.testing.expect(false);
        return;
    };
    holders = HolderList.push(holders, .{ .child = map_one, .label = 1 }) orelse {
        try std.testing.expect(false);
        return;
    };
    holders = HolderList.push(holders, .{ .child = map_two, .label = 2 }) orelse {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expectEqual(@as(i64, 2), HolderList.length(holders));
    const first_holder = HolderList.get(holders, 0);
    defer MapI64.release(first_holder.child);
    const second_holder = HolderList.get(holders, 1);
    defer MapI64.release(second_holder.child);
    try std.testing.expectEqual(@as(i64, 1), first_holder.label);
    try std.testing.expectEqual(@as(i64, 2), second_holder.label);

    HolderList.release(holders);
    try std.testing.expectEqual(before_releases + 3, arc_releases_total);
}

test "List(?*const Map) set on shared buffer preserves original ARC elements" {
    const Helpers = struct {
        const MapI64 = Map(i64, i64);
        const ListMap = List(?*const MapI64);

        fn newMap(seed: i64) ?*const MapI64 {
            const keys = [_]i64{seed};
            const values = [_]i64{seed * 10};
            return MapI64.fromPairs(&keys, &values, 1);
        }

        fn expectSlot(list: ?*const ListMap, index: i64, expected: *const MapI64) !void {
            const actual = ListMap.get(list, index) orelse @panic("expected map element");
            defer MapI64.release(actual);
            try std.testing.expectEqual(@intFromPtr(expected), @intFromPtr(actual));
        }
    };

    const before_releases = arc_releases_total;

    const map_one = Helpers.newMap(1) orelse @panic("test map allocation failed");
    const map_two = Helpers.newMap(2) orelse @panic("test map allocation failed");
    const replacement = Helpers.newMap(9) orelse @panic("test map allocation failed");

    var original: ?*const Helpers.ListMap = Helpers.ListMap.new_empty(2) orelse @panic("test list allocation failed");
    defer if (original) |list| Helpers.ListMap.release(list);

    original = Helpers.ListMap.push(original, map_one) orelse @panic("test list push failed");
    original = Helpers.ListMap.push(original, map_two) orelse @panic("test list push failed");

    var shared: ?*const Helpers.ListMap = Helpers.ListMap.retain(original);
    defer if (shared) |list| Helpers.ListMap.release(list);

    var updated: ?*const Helpers.ListMap = Helpers.ListMap.set(original, 0, replacement) orelse @panic("test list set failed");
    defer if (updated) |list| Helpers.ListMap.release(list);

    try std.testing.expect(@intFromPtr(updated.?) != @intFromPtr(original.?));
    try Helpers.expectSlot(original, 0, map_one);
    try Helpers.expectSlot(original, 1, map_two);
    try Helpers.expectSlot(updated, 0, replacement);
    try Helpers.expectSlot(updated, 1, map_two);

    Helpers.ListMap.release(original);
    original = null;
    Helpers.ListMap.release(shared);
    shared = null;
    Helpers.ListMap.release(updated);
    updated = null;

    try std.testing.expectEqual(before_releases + 12, arc_releases_total);
}

test "List higher-order helpers pass owned ARC elements to callbacks" {
    const Helpers = struct {
        const MapI64 = Map(i64, i64);
        const ListMap = List(?*const MapI64);

        fn newMap(seed: i64) ?*const MapI64 {
            const keys = [_]i64{seed};
            const values = [_]i64{seed * 10};
            return MapI64.fromPairs(&keys, &values, 1);
        }

        fn newSizedMap(seed: i64, size: usize) ?*const MapI64 {
            var keys: [3]i64 = undefined;
            var values: [3]i64 = undefined;
            var index: usize = 0;
            while (index < size) : (index += 1) {
                keys[index] = seed + @as(i64, @intCast(index));
                values[index] = (seed + @as(i64, @intCast(index))) * 10;
            }
            return MapI64.fromPairs(&keys, &values, @intCast(size));
        }

        fn newList() ?*const ListMap {
            var list: ?*const ListMap = ListMap.new_empty(2) orelse @panic("test list allocation failed");
            list = ListMap.push(list, newMap(1) orelse @panic("test map allocation failed")) orelse @panic("test list push failed");
            list = ListMap.push(list, newMap(2) orelse @panic("test map allocation failed")) orelse @panic("test list push failed");
            return list;
        }

        fn newSortableList() ?*const ListMap {
            var list: ?*const ListMap = ListMap.new_empty(2) orelse @panic("test list allocation failed");
            list = ListMap.push(list, newSizedMap(10, 2) orelse @panic("test map allocation failed")) orelse @panic("test list push failed");
            list = ListMap.push(list, newSizedMap(20, 1) orelse @panic("test map allocation failed")) orelse @panic("test list push failed");
            return list;
        }

        fn expectOwned(map: ?*const MapI64) void {
            const ptr = map orelse @panic("expected map");
            std.debug.assert(ptr.header.count() >= 2);
        }

        fn releaseMapReturnReplacement(map: ?*const MapI64) ?*const MapI64 {
            expectOwned(map);
            MapI64.release(map);
            return newMap(100) orelse @panic("test map allocation failed");
        }

        fn releaseMapTrue(map: ?*const MapI64) bool {
            expectOwned(map);
            MapI64.release(map);
            return true;
        }

        fn releaseMapFalse(map: ?*const MapI64) bool {
            expectOwned(map);
            MapI64.release(map);
            return false;
        }

        fn reduceKeepAccumulator(accumulator: ?*const MapI64, map: ?*const MapI64) ?*const MapI64 {
            expectOwned(map);
            MapI64.release(map);
            return accumulator;
        }

        fn compareBySize(left: ?*const MapI64, right: ?*const MapI64) bool {
            expectOwned(left);
            expectOwned(right);
            const ordered = MapI64.size(left) < MapI64.size(right);
            MapI64.release(left);
            MapI64.release(right);
            return ordered;
        }

        fn releaseMapReturnSingletonList(map: ?*const MapI64) ?*const ListMap {
            expectOwned(map);
            MapI64.release(map);
            var list: ?*const ListMap = ListMap.new_empty(1) orelse @panic("test list allocation failed");
            list = ListMap.push(list, newMap(200) orelse @panic("test map allocation failed")) orelse @panic("test list push failed");
            return list;
        }
    };

    {
        const list = Helpers.newList() orelse @panic("test list allocation failed");
        const mapped = Helpers.ListMap.mapFn(list, Helpers.releaseMapReturnReplacement) orelse @panic("mapFn returned null");
        try std.testing.expectEqual(@as(i64, 2), Helpers.ListMap.length(mapped));
        Helpers.ListMap.release(list);
        Helpers.ListMap.release(mapped);
    }

    {
        const list = Helpers.newList() orelse @panic("test list allocation failed");
        const filtered = Helpers.ListMap.filterFn(list, Helpers.releaseMapTrue) orelse @panic("filterFn returned null");
        try std.testing.expectEqual(@as(i64, 2), Helpers.ListMap.length(filtered));
        Helpers.ListMap.release(list);
        Helpers.ListMap.release(filtered);
    }

    {
        const list = Helpers.newList() orelse @panic("test list allocation failed");
        const rejected = Helpers.ListMap.rejectFn(list, Helpers.releaseMapFalse) orelse @panic("rejectFn returned null");
        try std.testing.expectEqual(@as(i64, 2), Helpers.ListMap.length(rejected));
        Helpers.ListMap.release(list);
        Helpers.ListMap.release(rejected);
    }

    {
        const list = Helpers.newList() orelse @panic("test list allocation failed");
        const accumulator = Helpers.newMap(90) orelse @panic("test map allocation failed");
        const result = Helpers.ListMap.enumReduceSimple(list, accumulator, Helpers.reduceKeepAccumulator);
        try std.testing.expectEqual(@intFromPtr(accumulator), @intFromPtr(result));
        Helpers.ListMap.release(list);
        Helpers.MapI64.release(result);
    }

    {
        const list = Helpers.newList() orelse @panic("test list allocation failed");
        const before_releases = arc_releases_total;
        const returned = Helpers.ListMap.eachFn(list, Helpers.releaseMapReturnReplacement);
        try std.testing.expectEqual(@intFromPtr(list), @intFromPtr(returned));
        Helpers.ListMap.release(list);
        try std.testing.expectEqual(before_releases + 7, arc_releases_total);
    }

    {
        const list = Helpers.newList() orelse @panic("test list allocation failed");
        const found = Helpers.ListMap.findFn(list, null, Helpers.releaseMapTrue);
        try std.testing.expect(found != null);
        Helpers.ListMap.release(list);
        Helpers.MapI64.release(found);
    }

    {
        const list = Helpers.newList() orelse @panic("test list allocation failed");
        try std.testing.expect(Helpers.ListMap.anyFn(list, Helpers.releaseMapTrue));
        Helpers.ListMap.release(list);
    }

    {
        const list = Helpers.newList() orelse @panic("test list allocation failed");
        try std.testing.expect(Helpers.ListMap.allFn(list, Helpers.releaseMapTrue));
        Helpers.ListMap.release(list);
    }

    {
        const list = Helpers.newList() orelse @panic("test list allocation failed");
        try std.testing.expectEqual(@as(i64, 2), Helpers.ListMap.countFn(list, Helpers.releaseMapTrue));
        Helpers.ListMap.release(list);
    }

    {
        const list = Helpers.newSortableList() orelse @panic("test list allocation failed");
        const sorted = Helpers.ListMap.sortFn(list, Helpers.compareBySize) orelse @panic("sortFn returned null");
        try std.testing.expectEqual(@as(i64, 2), Helpers.ListMap.length(sorted));
        Helpers.ListMap.release(list);
        Helpers.ListMap.release(sorted);
    }

    {
        const list = Helpers.newList() orelse @panic("test list allocation failed");
        const flattened = Helpers.ListMap.flatMapFn(list, Helpers.releaseMapReturnSingletonList) orelse @panic("flatMapFn returned null");
        try std.testing.expectEqual(@as(i64, 2), Helpers.ListMap.length(flattened));
        Helpers.ListMap.release(list);
        Helpers.ListMap.release(flattened);
    }
}

// ============================================================
// uniqueness unchecked-mutation variants — Map and List
// ============================================================
//
// These tests exercise the `*_owned_unchecked` runtime functions
// directly via Zig (host tests). The codegen is not yet wired to
// emit these — that is the next session's deliverable. The tests
// confirm:
//   * The unchecked variant mutates in place (same pointer
//     returned for in-buffer mutations).
//   * The result is semantically identical to the checked variant
//     when invoked on a uniquely-owned (rc==1) input.
//   * The unchecked variant skips the rc==1 check (calls the
//     in-place core directly).
//
// We do NOT test the rc>1 case for unchecked variants — the uniqueness
// contract makes that undefined behavior, and the uniqueness verifier
// rejects unchecked calls at any site where rc could be > 1.
// Production callers must always route through uniqueness.

test "List(i64) set_owned_unchecked mutates in place and returns same pointer" {
    const ListI64 = List(i64);
    const v = ListI64.new_filled(3, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(v);

    const before_unchecked = list_unchecked_total;
    const after = ListI64.set_owned_unchecked(v, 1, 42) orelse {
        try std.testing.expect(false);
        return;
    };
    // Same pointer — proof of in-place mutation.
    try std.testing.expectEqual(@intFromPtr(v), @intFromPtr(after));
    try std.testing.expectEqual(@as(i64, 42), ListI64.get(after, 1));
    // Counter went up — proof we routed through the unchecked variant.
    try std.testing.expectEqual(before_unchecked + 1, list_unchecked_total);
}

test "List(i64) push_owned_unchecked grows in place when capacity allows" {
    const ListI64 = List(i64);
    const v0 = ListI64.new_empty(4) orelse {
        try std.testing.expect(false);
        return;
    };
    const before_unchecked = list_unchecked_total;

    var current: ?*const ListI64 = v0;
    current = ListI64.push_owned_unchecked(current, 10) orelse {
        try std.testing.expect(false);
        return;
    };
    // First push: capacity 4, len was 0, so no resize — same pointer.
    try std.testing.expectEqual(@intFromPtr(v0), @intFromPtr(current));

    current = ListI64.push_owned_unchecked(current, 20) orelse {
        try std.testing.expect(false);
        return;
    };
    current = ListI64.push_owned_unchecked(current, 30) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(current);

    try std.testing.expectEqual(@as(i64, 3), ListI64.length(current));
    try std.testing.expectEqual(@as(i64, 10), ListI64.get(current, 0));
    try std.testing.expectEqual(@as(i64, 30), ListI64.get(current, 2));
    try std.testing.expectEqual(before_unchecked + 3, list_unchecked_total);
}

test "List(i64) push_owned_unchecked grows the buffer when capacity is exceeded" {
    const ListI64 = List(i64);
    var current: ?*const ListI64 = ListI64.new_empty(2) orelse {
        try std.testing.expect(false);
        return;
    };
    var i: i64 = 0;
    while (i < 16) : (i += 1) {
        current = ListI64.push_owned_unchecked(current, i) orelse {
            try std.testing.expect(false);
            return;
        };
    }
    defer ListI64.release(current);

    try std.testing.expectEqual(@as(i64, 16), ListI64.length(current));
    var k: i64 = 0;
    while (k < 16) : (k += 1) {
        try std.testing.expectEqual(k, ListI64.get(current, k));
    }
    // After grow, refcount is still 1.
    try std.testing.expectEqual(@as(u32, 1), current.?.header.count());
}

test "List(i64) pop_owned_unchecked decrements length in place" {
    const ListI64 = List(i64);
    const v = ListI64.new_filled(3, 7) orelse {
        try std.testing.expect(false);
        return;
    };
    const popped = ListI64.pop_owned_unchecked(v) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(popped);

    try std.testing.expectEqual(@intFromPtr(v), @intFromPtr(popped));
    try std.testing.expectEqual(@as(i64, 2), ListI64.length(popped));
}

test "List(i64) append_owned_unchecked concatenates in place when capacity fits" {
    const ListI64 = List(i64);
    const a = ListI64.new_empty(8) orelse {
        try std.testing.expect(false);
        return;
    };
    var av: ?*const ListI64 = a;
    av = ListI64.push_owned_unchecked(av, 1).?;
    av = ListI64.push_owned_unchecked(av, 2).?;

    var bv: ?*const ListI64 = ListI64.new_empty(0) orelse {
        try std.testing.expect(false);
        return;
    };
    bv = ListI64.push(bv, 3).?;
    bv = ListI64.push(bv, 4).?;
    defer ListI64.release(bv);

    const result = ListI64.append_owned_unchecked(av, bv) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(result);

    // av's capacity was 8 with len 2; appending bv's len 2 fits.
    // Same pointer as av (in-place).
    try std.testing.expectEqual(@intFromPtr(a), @intFromPtr(result));
    try std.testing.expectEqual(@as(i64, 4), ListI64.length(result));
    try std.testing.expectEqual(@as(i64, 1), ListI64.get(result, 0));
    try std.testing.expectEqual(@as(i64, 2), ListI64.get(result, 1));
    try std.testing.expectEqual(@as(i64, 3), ListI64.get(result, 2));
    try std.testing.expectEqual(@as(i64, 4), ListI64.get(result, 3));
}

test "List(i64) append_owned_unchecked grows when capacity is insufficient" {
    const ListI64 = List(i64);
    const a = ListI64.new_empty(2) orelse {
        try std.testing.expect(false);
        return;
    };
    var av: ?*const ListI64 = a;
    av = ListI64.push_owned_unchecked(av, 1).?;
    av = ListI64.push_owned_unchecked(av, 2).?;

    var bv: ?*const ListI64 = ListI64.new_empty(0) orelse {
        try std.testing.expect(false);
        return;
    };
    bv = ListI64.push(bv, 3).?;
    bv = ListI64.push(bv, 4).?;
    bv = ListI64.push(bv, 5).?;
    defer ListI64.release(bv);

    const result = ListI64.append_owned_unchecked(av, bv) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(result);

    try std.testing.expectEqual(@as(i64, 5), ListI64.length(result));
    try std.testing.expectEqual(@as(i64, 1), ListI64.get(result, 0));
    try std.testing.expectEqual(@as(i64, 5), ListI64.get(result, 4));
    // After grow, refcount still 1.
    try std.testing.expectEqual(@as(u32, 1), result.header.count());
}

test "List(i64) append_owned_unchecked self grows without reading freed storage" {
    const ListI64 = List(i64);
    var values: ?*const ListI64 = ListI64.new_empty(2) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push_owned_unchecked(values, 1) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push_owned_unchecked(values, 2) orelse {
        try std.testing.expect(false);
        return;
    };

    const result = ListI64.append_owned_unchecked(values, values) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(result);

    try std.testing.expectEqual(@as(i64, 4), ListI64.length(result));
    try std.testing.expectEqual(@as(i64, 1), ListI64.get(result, 0));
    try std.testing.expectEqual(@as(i64, 2), ListI64.get(result, 1));
    try std.testing.expectEqual(@as(i64, 1), ListI64.get(result, 2));
    try std.testing.expectEqual(@as(i64, 2), ListI64.get(result, 3));
    try std.testing.expectEqual(@as(u32, 1), result.header.count());
}

test "List(i64) head_owned_unchecked returns the first element" {
    const ListI64 = List(i64);
    var values: ?*const ListI64 = ListI64.new_empty(3) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push_owned_unchecked(values, 10) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push_owned_unchecked(values, 20) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(values);

    try std.testing.expectEqual(@as(i64, 10), ListI64.head_owned_unchecked(values));
    try std.testing.expectEqual(@as(i64, 2), ListI64.length(values));
}

test "List(i64) tail_owned_unchecked shifts the suffix in place" {
    const ListI64 = List(i64);
    var values: ?*const ListI64 = ListI64.new_empty(4) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push_owned_unchecked(values, 10) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push_owned_unchecked(values, 20) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push_owned_unchecked(values, 30) orelse {
        try std.testing.expect(false);
        return;
    };
    const original = values.?;
    const before_unchecked = list_unchecked_total;

    values = ListI64.tail_owned_unchecked(values) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(values);

    try std.testing.expectEqual(@intFromPtr(original), @intFromPtr(values.?));
    try std.testing.expectEqual(@as(i64, 2), ListI64.length(values));
    try std.testing.expectEqual(@as(i64, 20), ListI64.get(values, 0));
    try std.testing.expectEqual(@as(i64, 30), ListI64.get(values, 1));
    try std.testing.expectEqual(@as(u32, 1), values.?.header.count());
    try std.testing.expectEqual(before_unchecked + 1, list_unchecked_total);
}

test "List(i64) slice_owned_unchecked shifts an indexed suffix in place" {
    const ListI64 = List(i64);
    var values: ?*const ListI64 = ListI64.new_empty(5) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push_owned_unchecked(values, 10) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push_owned_unchecked(values, 20) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push_owned_unchecked(values, 30) orelse {
        try std.testing.expect(false);
        return;
    };
    values = ListI64.push_owned_unchecked(values, 40) orelse {
        try std.testing.expect(false);
        return;
    };
    const original = values.?;
    const before_unchecked = list_unchecked_total;

    values = ListI64.slice_owned_unchecked(values, 2) orelse {
        try std.testing.expect(false);
        return;
    };
    defer ListI64.release(values);

    try std.testing.expectEqual(@intFromPtr(original), @intFromPtr(values.?));
    try std.testing.expectEqual(@as(i64, 2), ListI64.length(values));
    try std.testing.expectEqual(@as(i64, 30), ListI64.get(values, 0));
    try std.testing.expectEqual(@as(i64, 40), ListI64.get(values, 1));
    try std.testing.expectEqual(@as(u32, 1), values.?.header.count());
    try std.testing.expectEqual(before_unchecked + 1, list_unchecked_total);
}

test "List(?*const Map) owned-unchecked head and slice balance element lifetimes" {
    const MapI64 = Map(i64, i64);
    const ListMap = List(?*const MapI64);

    const map_one = MapI64.put_owned_unchecked(null, 1, 10) orelse @panic("test map allocation failed");
    const map_two = MapI64.put_owned_unchecked(null, 2, 20) orelse @panic("test map allocation failed");
    const map_three = MapI64.put_owned_unchecked(null, 3, 30) orelse @panic("test map allocation failed");

    var values: ?*const ListMap = ListMap.new_empty(3) orelse @panic("test list allocation failed");
    values = ListMap.push_owned_unchecked(values, map_one) orelse @panic("test push failed");
    values = ListMap.push_owned_unchecked(values, map_two) orelse @panic("test push failed");
    values = ListMap.push_owned_unchecked(values, map_three) orelse @panic("test push failed");

    const head = ListMap.head_owned_unchecked(values) orelse @panic("test head missing");
    try std.testing.expectEqual(@intFromPtr(map_one), @intFromPtr(head));
    try std.testing.expectEqual(@as(u32, 2), map_one.header.count());

    values = ListMap.slice_owned_unchecked(values, 1) orelse @panic("test slice failed");
    defer ListMap.release(values);
    defer MapI64.release(head);

    try std.testing.expectEqual(@as(u32, 1), map_one.header.count());
    try std.testing.expectEqual(@as(i64, 2), ListMap.length(values));

    const first_tail = ListMap.get(values, 0) orelse @panic("test tail slot missing");
    defer MapI64.release(first_tail);
    const second_tail = ListMap.get(values, 1) orelse @panic("test tail slot missing");
    defer MapI64.release(second_tail);

    try std.testing.expectEqual(@intFromPtr(map_two), @intFromPtr(first_tail));
    try std.testing.expectEqual(@intFromPtr(map_three), @intFromPtr(second_tail));
}

test "List(?*const Map) owned-unchecked mutators balance ARC element lifetimes" {
    const Helpers = struct {
        const MapI64 = Map(i64, i64);
        const ListMap = List(?*const MapI64);

        fn newMap(seed: i64) ?*const MapI64 {
            const keys = [_]i64{seed};
            const values = [_]i64{seed * 10};
            return MapI64.fromPairs(&keys, &values, 1);
        }

        fn expectSlot(list: ?*const ListMap, index: i64, expected: *const MapI64) !void {
            const actual = ListMap.get(list, index) orelse @panic("expected map element");
            defer MapI64.release(actual);
            try std.testing.expectEqual(@intFromPtr(expected), @intFromPtr(actual));
        }
    };

    const before_releases = arc_releases_total;

    const map_one = Helpers.newMap(1) orelse @panic("test map allocation failed");
    const map_two = Helpers.newMap(2) orelse @panic("test map allocation failed");
    const map_three = Helpers.newMap(3) orelse @panic("test map allocation failed");
    const replacement = Helpers.newMap(20) orelse @panic("test map allocation failed");
    const map_four = Helpers.newMap(4) orelse @panic("test map allocation failed");
    const map_five = Helpers.newMap(5) orelse @panic("test map allocation failed");

    var left: ?*const Helpers.ListMap = Helpers.ListMap.new_empty(2) orelse @panic("test left list allocation failed");
    defer if (left) |list| Helpers.ListMap.release(list);
    left = Helpers.ListMap.push_owned_unchecked(left, map_one) orelse @panic("test left push failed");
    left = Helpers.ListMap.push_owned_unchecked(left, map_two) orelse @panic("test left push failed");
    left = Helpers.ListMap.push_owned_unchecked(left, map_three) orelse @panic("test left grow failed");

    const after_set = Helpers.ListMap.set_owned_unchecked(left, 1, replacement) orelse @panic("test set failed");
    try std.testing.expectEqual(@intFromPtr(left.?), @intFromPtr(after_set));
    left = after_set;

    var right: ?*const Helpers.ListMap = Helpers.ListMap.new_empty(2) orelse @panic("test right list allocation failed");
    defer if (right) |list| Helpers.ListMap.release(list);
    right = Helpers.ListMap.push_owned_unchecked(right, map_four) orelse @panic("test right push failed");
    right = Helpers.ListMap.push_owned_unchecked(right, map_five) orelse @panic("test right push failed");

    var appended: ?*const Helpers.ListMap = Helpers.ListMap.append_owned_unchecked(left, right) orelse @panic("test append failed");
    defer if (appended) |list| Helpers.ListMap.release(list);
    left = null;

    try std.testing.expectEqual(@as(i64, 5), Helpers.ListMap.length(appended));
    try Helpers.expectSlot(appended, 0, map_one);
    try Helpers.expectSlot(appended, 1, replacement);
    try Helpers.expectSlot(appended, 2, map_three);
    try Helpers.expectSlot(appended, 3, map_four);
    try Helpers.expectSlot(appended, 4, map_five);
    try std.testing.expectEqual(@as(u32, 1), appended.?.header.count());

    Helpers.ListMap.release(right);
    right = null;
    Helpers.ListMap.release(appended);
    appended = null;

    try std.testing.expectEqual(before_releases + 15, arc_releases_total);
}

test "List(?*const Map(u32, Term)) releases generated manifest-shaped maps once" {
    const SummaryMap = Map(u32, Term);
    const SummaryList = List(?*const SummaryMap);

    var summaries: ?*const SummaryList = SummaryList.empty();
    defer SummaryList.release(summaries);

    var index: u32 = 0;
    while (index < 512) : (index += 1) {
        var summary: ?*const SummaryMap = SummaryMap.empty();
        summary = SummaryMap.put(summary, 1, Term.from("Atom")) orelse @panic("summary module insert failed");
        summary = SummaryMap.put(summary, 2, Term.from("to_string")) orelse @panic("summary name insert failed");
        summary = SummaryMap.put(summary, 3, Term.from(@as(i64, 1))) orelse @panic("summary arity insert failed");
        summary = SummaryMap.put(summary, 4, Term.from("Converts an atom.")) orelse @panic("summary doc insert failed");
        summary = SummaryMap.put(summary, 5, Term.from("lib/atom.zap")) orelse @panic("summary source file insert failed");
        summary = SummaryMap.put(summary, 6, Term.from(@as(i64, 29))) orelse @panic("summary source line insert failed");
        summary = SummaryMap.put(summary, 7, Term.from("to_string(atom :: Atom) -> String")) orelse @panic("summary signature insert failed");

        summaries = SummaryList.push(summaries, summary) orelse @panic("summary list push failed");
    }

    try std.testing.expectEqual(@as(i64, 512), SummaryList.length(summaries));
}

test "Map retains nested map values inserted through checked put" {
    const InnerMap = Map(u32, i64);
    const OuterMap = Map(u32, ?*const InnerMap);

    const inner_keys = [_]u32{2};
    const inner_values = [_]i64{42};
    const inner = InnerMap.fromPairs(&inner_keys, &inner_values, 1) orelse @panic("inner map allocation failed");

    var outer: ?*const OuterMap = OuterMap.put(null, 1, inner) orelse @panic("outer map allocation failed");
    try std.testing.expectEqual(@as(u32, 2), inner.header.count());

    InnerMap.release(inner);

    const fetched = OuterMap.get(outer, 1, null) orelse @panic("nested map missing");
    defer InnerMap.release(fetched);

    try std.testing.expectEqual(@as(i64, 42), InnerMap.get(fetched, 2, 0));
    try std.testing.expectEqual(@as(u32, 2), fetched.header.count());

    OuterMap.release(outer);
    outer = null;
}

test "Map.fromPairs retains nested map values" {
    const InnerMap = Map(u32, i64);
    const OuterMap = Map(u32, ?*const InnerMap);

    const inner_keys = [_]u32{7};
    const inner_values = [_]i64{70};
    const inner = InnerMap.fromPairs(&inner_keys, &inner_values, 1) orelse @panic("inner map allocation failed");

    const outer_keys = [_]u32{1};
    const outer_values = [_]?*const InnerMap{inner};
    const outer = OuterMap.fromPairs(&outer_keys, &outer_values, 1) orelse @panic("outer map allocation failed");
    try std.testing.expectEqual(@as(u32, 2), inner.header.count());

    InnerMap.release(inner);

    const fetched = OuterMap.get(outer, 1, null) orelse @panic("nested map missing");
    defer InnerMap.release(fetched);

    try std.testing.expectEqual(@as(i64, 70), InnerMap.get(fetched, 7, 0));
    try std.testing.expectEqual(@as(u32, 2), fetched.header.count());

    OuterMap.release(outer);
}

test "Map(i64,i64) put_owned_unchecked mutates in place and returns same pointer" {
    const MapI64 = Map(i64, i64);
    const keys = [_]i64{ 1, 2 };
    const vals = [_]i64{ 10, 20 };
    const m = MapI64.fromPairs(&keys, &vals, 2) orelse {
        try std.testing.expect(false);
        return;
    };
    const before_unchecked = dense_map_unchecked_total;

    const after = MapI64.put_owned_unchecked(m, 3, 30) orelse {
        try std.testing.expect(false);
        return;
    };
    defer MapI64.release(after);

    // Same pointer — in-place insertion (capacity 8, len was 2,
    // load factor not breached).
    try std.testing.expectEqual(@intFromPtr(m), @intFromPtr(after));
    try std.testing.expectEqual(@as(i64, 30), MapI64.get(after, 3, 0));
    try std.testing.expectEqual(@as(i64, 10), MapI64.get(after, 1, 0));
    try std.testing.expectEqual(before_unchecked + 1, dense_map_unchecked_total);
}

test "Map(i64,i64) put_owned_unchecked semantics match checked put on rc=1 input" {
    const MapI64 = Map(i64, i64);
    // Build two identical maps; mutate one with put, the other with
    // put_owned_unchecked. Final state must be identical.
    const keys = [_]i64{ 1, 2, 3 };
    const vals = [_]i64{ 10, 20, 30 };

    const m_checked = MapI64.fromPairs(&keys, &vals, 3) orelse {
        try std.testing.expect(false);
        return;
    };
    const m_unchecked = MapI64.fromPairs(&keys, &vals, 3) orelse {
        try std.testing.expect(false);
        return;
    };

    const after_checked = MapI64.put(m_checked, 4, 40).?;
    const after_unchecked = MapI64.put_owned_unchecked(m_unchecked, 4, 40).?;
    defer MapI64.release(after_checked);
    defer MapI64.release(after_unchecked);

    try std.testing.expectEqual(MapI64.size(after_checked), MapI64.size(after_unchecked));
    try std.testing.expectEqual(MapI64.get(after_checked, 4, 0), MapI64.get(after_unchecked, 4, 0));
    try std.testing.expectEqual(MapI64.get(after_checked, 1, 0), MapI64.get(after_unchecked, 1, 0));
}

test "Map(i64,i64) delete_owned_unchecked removes key in place" {
    const MapI64 = Map(i64, i64);
    const keys = [_]i64{ 1, 2, 3 };
    const vals = [_]i64{ 10, 20, 30 };
    const m = MapI64.fromPairs(&keys, &vals, 3) orelse {
        try std.testing.expect(false);
        return;
    };

    const after = MapI64.delete_owned_unchecked(m, 2).?;
    defer MapI64.release(after);

    // Same pointer — in-place delete.
    try std.testing.expectEqual(@intFromPtr(m), @intFromPtr(after));
    try std.testing.expectEqual(@as(i64, 2), MapI64.size(after));
    // Key 2 is gone (default returned).
    try std.testing.expectEqual(@as(i64, -1), MapI64.get(after, 2, -1));
    // Other keys still present.
    try std.testing.expectEqual(@as(i64, 10), MapI64.get(after, 1, 0));
    try std.testing.expectEqual(@as(i64, 30), MapI64.get(after, 3, 0));
}

test "Map(i64,i64) delete_owned_unchecked is a no-op for absent keys" {
    const MapI64 = Map(i64, i64);
    const keys = [_]i64{ 1, 2 };
    const vals = [_]i64{ 10, 20 };
    const m = MapI64.fromPairs(&keys, &vals, 2) orelse {
        try std.testing.expect(false);
        return;
    };

    const after = MapI64.delete_owned_unchecked(m, 99).?;
    defer MapI64.release(after);

    try std.testing.expectEqual(@intFromPtr(m), @intFromPtr(after));
    try std.testing.expectEqual(@as(i64, 2), MapI64.size(after));
}

test "Map(i64,i64) merge_owned_unchecked folds B into A in place" {
    const MapI64 = Map(i64, i64);
    const keys_a = [_]i64{ 1, 2 };
    const vals_a = [_]i64{ 10, 20 };
    const a = MapI64.fromPairs(&keys_a, &vals_a, 2) orelse {
        try std.testing.expect(false);
        return;
    };
    const keys_b = [_]i64{ 3, 4 };
    const vals_b = [_]i64{ 30, 40 };
    const b = MapI64.fromPairs(&keys_b, &vals_b, 2) orelse {
        try std.testing.expect(false);
        return;
    };
    defer MapI64.release(b);

    const a_ptr = @intFromPtr(a);
    const after = MapI64.merge_owned_unchecked(a, b).?;
    defer MapI64.release(after);

    // A had capacity 8, len 2; merging 2 entries doesn't trigger
    // a resize (load factor 7/8 == 7 entries before resize). So the
    // result is A's pointer.
    try std.testing.expectEqual(a_ptr, @intFromPtr(after));
    try std.testing.expectEqual(@as(i64, 4), MapI64.size(after));
    try std.testing.expectEqual(@as(i64, 10), MapI64.get(after, 1, 0));
    try std.testing.expectEqual(@as(i64, 30), MapI64.get(after, 3, 0));
}

test "Map(i64,i64) merge_owned_unchecked semantics match checked merge on rc=1 inputs" {
    const MapI64 = Map(i64, i64);
    const keys_a = [_]i64{ 1, 2 };
    const vals_a = [_]i64{ 10, 20 };
    const keys_b = [_]i64{ 2, 3 };
    const vals_b = [_]i64{ 99, 30 };

    const a_checked = MapI64.fromPairs(&keys_a, &vals_a, 2).?;
    const b_checked = MapI64.fromPairs(&keys_b, &vals_b, 2).?;
    defer MapI64.release(b_checked);
    const merged_checked = MapI64.merge(a_checked, b_checked).?;
    defer MapI64.release(merged_checked);
    MapI64.release(a_checked);

    const a_unchecked = MapI64.fromPairs(&keys_a, &vals_a, 2).?;
    const b_unchecked = MapI64.fromPairs(&keys_b, &vals_b, 2).?;
    defer MapI64.release(b_unchecked);
    const merged_unchecked = MapI64.merge_owned_unchecked(a_unchecked, b_unchecked).?;
    defer MapI64.release(merged_unchecked);

    try std.testing.expectEqual(MapI64.size(merged_checked), MapI64.size(merged_unchecked));
    // Key 2's value should be the B-side value (B overrides A on collision).
    try std.testing.expectEqual(@as(i64, 99), MapI64.get(merged_checked, 2, 0));
    try std.testing.expectEqual(@as(i64, 99), MapI64.get(merged_unchecked, 2, 0));
    try std.testing.expectEqual(@as(i64, 10), MapI64.get(merged_unchecked, 1, 0));
    try std.testing.expectEqual(@as(i64, 30), MapI64.get(merged_unchecked, 3, 0));
}

test "Map(i64,i64) put_owned_unchecked on null receiver allocates a fresh map" {
    const MapI64 = Map(i64, i64);
    const m = MapI64.put_owned_unchecked(null, 42, 100).?;
    defer MapI64.release(m);

    try std.testing.expectEqual(@as(i64, 1), MapI64.size(m));
    try std.testing.expectEqual(@as(i64, 100), MapI64.get(m, 42, 0));
    try std.testing.expectEqual(@as(u32, 1), m.header.count());
}

// ============================================================
// byte_intern_table — process-lifetime single-byte interning
// ============================================================

test "runtime: String.byte_at returns slice into byte_intern_table" {
    // Regression for commit 287e9cd. Walking a string byte-by-byte
    // (e.g., k-nucleotide's per-base FASTA scan, ~11.5M iterations on
    // a 250 KB sequence) must not pin one bump-arena page per byte.
    // The fix routes every single-byte return through the
    // process-lifetime `byte_intern_table` so all callers share the
    // same 256-byte storage. If the regression returns (i.e., a fresh
    // `bumpAlloc(1)` per call), the returned slice's pointer would
    // land in the arena and NOT equal `&byte_intern_table[s[0]]`.
    const source = "Z";
    const first = String.byte_at(source, 0);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(@as(u8, 'Z'), first[0]);
    // The slice's pointer must equal the table address for byte 'Z'.
    // Any non-interned path would land elsewhere in memory.
    try std.testing.expectEqual(
        @intFromPtr(&byte_intern_table[@as(usize, 'Z')]),
        @intFromPtr(first.ptr),
    );
}

test "runtime: byte_intern_table slice survives runtime_arena reset" {
    // The interned table lives in `.rodata`. Slices into it must
    // remain valid after `runtime_arena.reset(.free_all)` — a property
    // the runtime relies on when callers hold the byte slice across
    // an arena-clearing boundary (e.g., a streaming loop that resets
    // the arena between iterations). If the byte_at path regressed to
    // `bumpAlloc`, the slice would point into the arena and reading
    // it after `reset(.free_all)` would observe freed memory.
    const source = "Q";
    const saved = String.byte_at(source, 0);
    const saved_ptr = saved.ptr;
    try std.testing.expectEqual(@as(u8, 'Q'), saved[0]);

    // Reset the arena, freeing every node. Any slice that lived in
    // the arena would be dangling now. The interned slice is unaffected.
    // `reset` returns a bool indicating success; we discard it because
    // the test does not depend on whether the arena released its
    // pages — only on the table-backed slice's continued validity.
    _ = runtime_arena.reset(.free_all);

    try std.testing.expectEqual(saved_ptr, saved.ptr);
    try std.testing.expectEqual(@as(usize, 1), saved.len);
    try std.testing.expectEqual(@as(u8, 'Q'), saved[0]);
    // The slice must still point into the table at the right offset.
    try std.testing.expectEqual(
        @intFromPtr(&byte_intern_table[@as(usize, 'Q')]),
        @intFromPtr(saved.ptr),
    );
}

test "runtime: String.from_byte returns identity slice" {
    // `String.from_byte` is the inverse of `byte_at`. Both must route
    // through the same interned table so a value produced by
    // `from_byte(b)` is pointer-equal to a value extracted by
    // `byte_at(s, i)` when `s[i] == b`. This pinning property keeps
    // PBM-image-style streaming output (a long sequence of single-byte
    // emissions) from allocating one arena page per call.
    const result = String.from_byte(65);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u8, 'A'), result[0]);
    try std.testing.expectEqual(
        @intFromPtr(&byte_intern_table[65]),
        @intFromPtr(result.ptr),
    );

    // Round-trip: byte_at of an 'A' must return the exact same slice
    // address that from_byte(65) returned — they share the table.
    const round_trip = String.byte_at("A", 0);
    try std.testing.expectEqual(@intFromPtr(result.ptr), @intFromPtr(round_trip.ptr));
}

test "runtime: String.next yields stable single-byte slices" {
    // The string iterator returns a head slice and a tail slice on
    // every step. The head must alias the interned table (so iterating
    // an N-byte string never produces N transient arena allocations).
    // Each step's head pointer must equal `&byte_intern_table[byte]`.
    const source = "hello";
    var remaining: []const u8 = source;
    const expected = "hello";
    var index: usize = 0;
    while (remaining.len > 0) : (index += 1) {
        const step = String.next(remaining);
        const head = step[1];
        const tail = step[2];
        try std.testing.expectEqual(@as(usize, 1), head.len);
        try std.testing.expectEqual(expected[index], head[0]);
        try std.testing.expectEqual(
            @intFromPtr(&byte_intern_table[@as(usize, expected[index])]),
            @intFromPtr(head.ptr),
        );
        remaining = tail;
    }
    try std.testing.expectEqual(@as(usize, 5), index);
}

// ============================================================
// Wyhash.hashInt — SplitMix64 integer mixer used by DenseMap
// ============================================================

test "runtime: hashInt single-bit avalanche" {
    // Regression for commit e94d59f. A weak integer mixer (e.g., the
    // identity function or a simple xor) flips fewer than half of its
    // output bits for a single-bit input flip — the dense Map's
    // probing distribution would then collapse on integer-key
    // workloads. SplitMix64's finalizer is known to achieve 28-32 bit
    // avalanche on average; we require ≥ 24 bits for every input bit
    // position. Mentally inverting the function (e.g., reverting to
    // `value ^ seed`) would observe Hamming distances of just 1 or 2
    // for many positions — this test catches that regression.
    const seed: u64 = 0xDEADBEEFCAFEBABE;
    const baseline_input: u64 = 0x0123_4567_89AB_CDEF;
    const baseline_hash = Wyhash.hashInt(seed, baseline_input);
    var bit: u6 = 0;
    while (true) {
        const flipped_input = baseline_input ^ (@as(u64, 1) << bit);
        const flipped_hash = Wyhash.hashInt(seed, flipped_input);
        const diff = baseline_hash ^ flipped_hash;
        const distance: u32 = @popCount(diff);
        try std.testing.expect(distance >= 24);
        if (bit == 63) break;
        bit += 1;
    }
}

test "runtime: hashInt distribution over sequential inputs" {
    // The dense Map uses the low bits of `hashInt(seed, key)` mod cap
    // to pick the home slot. A poor mixer (e.g., identity) clusters
    // sequential keys into the same bucket — for inputs 0..N-1 with
    // 16 buckets, the identity mixer puts ⌈N/16⌉ keys in every bucket
    // for a max-equals-mean distribution that looks healthy but for
    // any non-sequential key set degenerates immediately. SplitMix64's
    // finalizer scatters sequential inputs across buckets with a max
    // count not far from the binomial mean. We bound max ≤ 1.5×mean.
    const seed: u64 = 0xA5A5_5A5A_A5A5_5A5A;
    const total_count: usize = 1000;
    const bucket_count: usize = 16;
    var buckets: [16]u32 = .{0} ** 16;
    var index: u64 = 0;
    while (index < total_count) : (index += 1) {
        const hash_value = Wyhash.hashInt(seed, index);
        buckets[@as(usize, @intCast(hash_value & 0xF))] += 1;
    }
    const mean: u32 = @intCast(total_count / bucket_count);
    var max_count: u32 = 0;
    for (buckets) |b| {
        if (b > max_count) max_count = b;
    }
    // Mean is 62.5 for N=1000, ceiling = 63. 1.5× is ~94 — a SplitMix64
    // finalizer comfortably stays below that. Identity would fail
    // (the high bits all collide into bucket 0, and a uniform run of
    // ascending values would skew heavily under any clustering pattern
    // not aligned with 16). The conservative 1.5× ceiling pins the
    // mixing quality without flaking on legitimate variance.
    const ceiling: u32 = mean + (mean / 2);
    try std.testing.expect(max_count <= ceiling);
}

test "runtime: hashInt deterministic" {
    // Regression-protects against accidental statefulness in the
    // mixer (e.g., reading a global RNG instead of just the inputs).
    // The function must be a pure function of (seed, value); two
    // independent calls with the same arguments must return the same
    // hash. If a reviewer mistakenly added a thread-local state to
    // the mixer, this test would observe drift on the second call.
    const seed: u64 = 0x1234_5678_9ABC_DEF0;
    const value: u64 = 0x0FED_CBA9_8765_4321;
    const first = Wyhash.hashInt(seed, value);
    const second = Wyhash.hashInt(seed, value);
    const third = Wyhash.hashInt(seed, value);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(first, third);

    // Different seeds yield different hashes for the same value.
    const other_seed: u64 = seed ^ 0xFFFF_FFFF_FFFF_FFFF;
    try std.testing.expect(Wyhash.hashInt(other_seed, value) != first);
    // Different values yield different hashes under the same seed.
    try std.testing.expect(Wyhash.hashInt(seed, value ^ 1) != first);
}

// ============================================================
// Buffered stdin — drain ordering, EOF stickiness
// ============================================================

test "runtime: stdinReadByte EOF stickiness" {
    // Regression for commit e94d59f. Once stdin hits EOF, the runtime
    // sets `stdin_eof = true` so subsequent reads short-circuit
    // without re-entering `read(2)`. Without the sticky guard,
    // line-by-line readers that consume past EOF (e.g., `IO.gets()`
    // followed by another `IO.gets()`) would spin in a tight syscall
    // loop, each `read` returning 0 and incurring kernel-boundary
    // overhead. We pin BOTH halves of the contract:
    //
    //   1. `stdinRefill` with `stdin_eof = true` returns 0 without
    //      issuing a syscall.
    //   2. `stdinReadByte` with `stdin_eof = true` and an empty
    //      buffer returns null and leaves `stdin_eof` set.
    //
    // The first half is the load-bearing invariant — it's what
    // protects against the post-EOF syscall storm. Without the
    // `if (stdin_eof) return 0;` guard at the top of `stdinRefill`,
    // the function would issue an unpredictable `read(STDIN_FD,...)`
    // here. We use a sentinel value in the buffer to detect any such
    // unexpected syscall write: if `stdinRefill` somehow succeeded,
    // it would overwrite `stdin_buf[0]` and bump `stdin_buf_len`. We
    // verify both fields are unchanged.
    const saved_pos = stdin_buf_pos;
    const saved_len = stdin_buf_len;
    const saved_eof = stdin_eof;
    const saved_byte = stdin_buf[0];
    defer {
        stdin_buf_pos = saved_pos;
        stdin_buf_len = saved_len;
        stdin_eof = saved_eof;
        stdin_buf[0] = saved_byte;
    }

    // Mark a sentinel byte. Any `read(2)` that actually fires would
    // overwrite this — proving the guard is missing.
    const sentinel: u8 = 0xA5;
    stdin_buf[0] = sentinel;
    stdin_buf_pos = 0;
    stdin_buf_len = 0;
    stdin_eof = true;

    // Direct invocation: stdinRefill must short-circuit on stdin_eof.
    try std.testing.expectEqual(@as(usize, 0), stdinRefill());
    // Sentinel preserved → no syscall fired.
    try std.testing.expectEqual(sentinel, stdin_buf[0]);
    try std.testing.expectEqual(@as(usize, 0), stdin_buf_pos);
    try std.testing.expectEqual(@as(usize, 0), stdin_buf_len);
    try std.testing.expect(stdin_eof);

    // Three calls in a row to stdinReadByte — each must return null
    // and leave the EOF flag set. The buffer remains empty.
    try std.testing.expectEqual(@as(?u8, null), stdinReadByte());
    try std.testing.expectEqual(@as(?u8, null), stdinReadByte());
    try std.testing.expectEqual(@as(?u8, null), stdinReadByte());

    // Buffer fields must be unchanged by the EOF reads.
    try std.testing.expectEqual(@as(usize, 0), stdin_buf_pos);
    try std.testing.expectEqual(@as(usize, 0), stdin_buf_len);
    try std.testing.expect(stdin_eof);
    try std.testing.expectEqual(sentinel, stdin_buf[0]);
}

test "runtime: stdinReadByte drains buffer before refill" {
    // Pre-fill the buffer with known bytes and confirm
    // `stdinReadByte` returns them in order without issuing a refill.
    // A regression that broke the drain ordering (e.g., always
    // refilling first) would either consume the test bytes silently
    // or block on `read(STDIN_FD)`. With `stdin_eof = false` and a
    // non-zero `stdin_buf_len`, the function MUST consume the buffer
    // before consulting the syscall.
    const saved_pos = stdin_buf_pos;
    const saved_len = stdin_buf_len;
    const saved_eof = stdin_eof;
    const saved_buf: [4]u8 = .{ stdin_buf[0], stdin_buf[1], stdin_buf[2], stdin_buf[3] };
    defer {
        stdin_buf_pos = saved_pos;
        stdin_buf_len = saved_len;
        stdin_eof = saved_eof;
        stdin_buf[0] = saved_buf[0];
        stdin_buf[1] = saved_buf[1];
        stdin_buf[2] = saved_buf[2];
        stdin_buf[3] = saved_buf[3];
    }

    // Inject a four-byte sequence. With stdin_eof=false and a partial
    // buffer present, calls must consume from the buffer alone. If
    // the function regressed to refill-first, the test would either
    // block (real stdin is a terminal in `zig build test`) or return
    // unrelated bytes.
    stdin_buf[0] = 'a';
    stdin_buf[1] = 'b';
    stdin_buf[2] = 'c';
    stdin_buf[3] = 'd';
    stdin_buf_pos = 0;
    stdin_buf_len = 4;
    stdin_eof = false;

    try std.testing.expectEqual(@as(?u8, 'a'), stdinReadByte());
    try std.testing.expectEqual(@as(?u8, 'b'), stdinReadByte());
    try std.testing.expectEqual(@as(?u8, 'c'), stdinReadByte());
    try std.testing.expectEqual(@as(?u8, 'd'), stdinReadByte());

    // After consuming all four bytes, pos == len. The NEXT call would
    // attempt a refill — we do NOT call it here because we cannot
    // mock fd 0. The buffer-drain contract is the load-bearing
    // invariant we wanted to pin.
    try std.testing.expectEqual(@as(usize, 4), stdin_buf_pos);
    try std.testing.expectEqual(@as(usize, 4), stdin_buf_len);
}

test "runtime: IO.gets handles partial-line buffer boundaries" {
    // The fast path inside `IO.gets` requires the entire line plus
    // its terminating newline to live in the current refill window.
    // When a line spans a refill boundary, `gets` falls back to a
    // scratch buffer and stitches the chunks together. Validate the
    // boundary behaviour by simulating two refills back-to-back:
    // pre-fill the buffer with a partial-line (no newline), let
    // `gets` consume it into scratch, then re-fill the buffer with
    // the line's tail (including the newline) BEFORE returning to
    // `gets`. The result must be the concatenated line.
    //
    // To control the refill, we open a pipe via libc and rebind
    // STDIN_FD via `dup2` for the duration of the test. The bytes
    // we pre-pack into `stdin_buf` (no newline) are consumed first,
    // then the in-flight `stdinRefill` call inside `gets` reads
    // from the pipe to obtain the line's tail (which contains the
    // newline). The line we assert is "first-chunk:second-chunk\n"
    // minus the trailing newline.
    //
    // `std.posix.pipe`/`close`/`dup` aren't exposed in this Zig
    // version's posix layer, so we drop to libc directly. The
    // runtime always links libc (`main.zig` builds with
    // `link_libc = true`), and the existing buffered-stdin code
    // already uses `std.c.*` syscalls, so this is the cleanest
    // route.
    const libc = struct {
        extern "c" fn pipe(fds: *[2]std.c.fd_t) c_int;
        extern "c" fn dup(fd: std.c.fd_t) c_int;
        extern "c" fn dup2(old_fd: std.c.fd_t, new_fd: std.c.fd_t) c_int;
        extern "c" fn close(fd: std.c.fd_t) c_int;
    };

    const saved_pos = stdin_buf_pos;
    const saved_len = stdin_buf_len;
    const saved_eof = stdin_eof;
    defer {
        stdin_buf_pos = saved_pos;
        stdin_buf_len = saved_len;
        stdin_eof = saved_eof;
    }

    // Open a pipe; write the line's tail and EOF the write end so
    // the read side observes the bytes followed by EOF.
    var pipe_fds: [2]std.c.fd_t = undefined;
    try std.testing.expect(libc.pipe(&pipe_fds) == 0);
    const read_end = pipe_fds[0];
    const write_end = pipe_fds[1];
    defer _ = libc.close(read_end);

    const tail_bytes = "second-chunk\nleftover";
    const written = std.c.write(write_end, tail_bytes.ptr, tail_bytes.len);
    try std.testing.expectEqual(@as(isize, @intCast(tail_bytes.len)), written);
    _ = libc.close(write_end);

    // Redirect STDIN_FD to point at the pipe's read end. Save the
    // original fd so we can restore it.
    const saved_stdin_fd = libc.dup(STDIN_FD);
    try std.testing.expect(saved_stdin_fd >= 0);
    defer {
        _ = libc.dup2(saved_stdin_fd, STDIN_FD);
        _ = libc.close(saved_stdin_fd);
    }
    try std.testing.expect(libc.dup2(read_end, STDIN_FD) >= 0);

    // Pre-pack the first chunk into the buffer. It does NOT contain
    // a newline — `gets` will consume it into scratch and then call
    // `stdinRefill` which reads the pipe's tail. The combined line
    // is "first-chunk:second-chunk".
    const head_bytes = "first-chunk:";
    @memcpy(stdin_buf[0..head_bytes.len], head_bytes);
    stdin_buf_pos = 0;
    stdin_buf_len = head_bytes.len;
    stdin_eof = false;

    const line = IO.gets();
    try std.testing.expectEqualStrings("first-chunk:second-chunk", line);
}

// ============================================================
// MapIter — cursor-based map iteration
//
// `Map.next` returns a cursor cell (`MapIter`) rather than a
// per-step clone. Functional iteration semantics are preserved —
// the source Map is never mutated, the iter retains its own
// reference to the source, and each step yields the next entry's
// (k, v) with proper retain on the elements.
//
// Layout invariant: the iter cell's first 24 bytes are
// binary-compatible with `Map(K, V).Self`'s header prefix — same
// `header`, `len`, `capacity`, `entry_cap`, `hash_seed` fields in
// the same order at the same offsets. The discriminator is
// `capacity == 0`: a real Map always has `capacity >=
// DENSE_MAP_INITIAL_CAPACITY` (8), so reading `.capacity` from a
// pointer addressed as `?*const Map(K, V).Self` cleanly
// distinguishes real maps from iter cells without a tag byte.
//
// `Map.next` / `Map.retain` / `Map.release` inspect that field
// before dispatching: real maps follow the existing paths, iter
// cells advance their cursor / release their retained source.
// ============================================================

test "MapIter: empty map returns ATOM_DONE immediately" {
    const M = Map(i64, i64);
    const result = M.next(null);
    try std.testing.expectEqual(ATOM_DONE, result.@"0");
    try std.testing.expectEqual(@as(?*const M, null), result.@"2");
}

// MapIter unit tests drive iteration through `Map.next` directly.
// `Map.next` borrows its argument and self-releases the iter cell
// on the DONE step (see `MapIter.advanceFromMapPtr`), so a
// well-formed iteration that runs to completion does NOT need to
// manually release the iter — Map.next does it for the caller.
// Tests that abandon iteration partway through must explicitly
// release the iter to free the cell + drop the retained source-map
// reference.

test "MapIter: walks all entries in stable order with O(1) per-step cost" {
    const M = Map(i64, i64);
    var keys: [100]i64 = undefined;
    var values: [100]i64 = undefined;
    for (0..100) |i| {
        keys[i] = @intCast(i);
        values[i] = @as(i64, @intCast(i)) * 10;
    }
    const src = M.fromPairs(&keys, &values, 100) orelse @panic("alloc failed");
    defer M.release(src);

    const before_clone_total = dense_map_retaining_clone_total;

    var seen: [100]bool = .{false} ** 100;
    var count: u32 = 0;

    var state: ?*const M = src;
    while (true) {
        const step = M.next(state);
        if (step.@"0" == ATOM_DONE) break;
        try std.testing.expectEqual(ATOM_CONT, step.@"0");
        const k = step.@"1".@"0";
        const v = step.@"1".@"1";
        try std.testing.expect(k >= 0 and k < 100);
        try std.testing.expectEqual(@as(i64, @intCast(k)) * 10, v);
        try std.testing.expect(!seen[@intCast(k)]);
        seen[@intCast(k)] = true;
        count += 1;
        state = step.@"2";
    }
    try std.testing.expectEqual(@as(u32, 100), count);
    for (seen) |s| try std.testing.expect(s);

    // O(1) iteration cost — no retaining clones generated for the walk.
    try std.testing.expectEqual(before_clone_total, dense_map_retaining_clone_total);

    // Source map is unchanged.
    try std.testing.expectEqual(@as(u32, 100), src.len);
}

test "MapIter: source map refcount preserved across full iteration" {
    const M = Map(i64, i64);
    var keys: [10]i64 = undefined;
    var values: [10]i64 = undefined;
    for (0..10) |i| {
        keys[i] = @intCast(i);
        values[i] = @as(i64, @intCast(i));
    }
    const src = M.fromPairs(&keys, &values, 10) orelse @panic("alloc failed");
    defer M.release(src);

    const refcount_before = src.header.count();
    const iter_allocs_before = dense_map_iter_alloc_total;
    const iter_frees_before = dense_map_iter_free_total;

    var state: ?*const M = src;
    while (true) {
        const step = M.next(state);
        if (step.@"0" == ATOM_DONE) break;
        state = step.@"2";
    }

    // After full iteration: source's refcount returns to its
    // pre-iteration value (Map.next on DONE self-released the iter,
    // which dropped its retained source-map reference).
    try std.testing.expectEqual(refcount_before, src.header.count());

    // Allocations and frees balance — no iter cell leaks.
    try std.testing.expectEqual(
        dense_map_iter_alloc_total - iter_allocs_before,
        dense_map_iter_free_total - iter_frees_before,
    );
}

test "MapIter: source map unchanged when iteration is abandoned" {
    const M = Map(i64, i64);
    var keys: [5]i64 = undefined;
    var values: [5]i64 = undefined;
    for (0..5) |i| {
        keys[i] = @intCast(i);
        values[i] = @as(i64, @intCast(i));
    }
    const src = M.fromPairs(&keys, &values, 5) orelse @panic("alloc failed");
    defer M.release(src);

    const refcount_before = src.header.count();

    // Take one step. The iter retains src (+1).
    const step = M.next(src);
    try std.testing.expectEqual(ATOM_CONT, step.@"0");
    const iter = step.@"2";
    try std.testing.expect(iter != null);
    try std.testing.expect(iter != src);

    // The iter has retained the source: rc went up by 1.
    try std.testing.expectEqual(refcount_before + 1, src.header.count());

    // Releasing the iter triggers `MapIter.releaseFromMapPtr` via
    // the `Map.release` dispatcher's `capacity == 0` discriminator.
    // The iter cell is freed and the source map's rc is dropped by 1.
    M.release(iter);
    try std.testing.expectEqual(refcount_before, src.header.count());
    try std.testing.expectEqual(@as(u32, 5), src.len);
}

test "MapIter: yielded keys/values retain correctly for ARC types" {
    // Use Map(u32, ?*const List(i64)) so values are ARC-managed lists.
    const InnerList = List(i64);
    const M = Map(u32, ?*const InnerList);

    const inner1 = InnerList.new_filled(3, 100) orelse @panic("list alloc");
    defer InnerList.release(inner1);
    const inner2 = InnerList.new_filled(3, 200) orelse @panic("list alloc");
    defer InnerList.release(inner2);

    const keys = [_]u32{ 1, 2 };
    const vals = [_]?*const InnerList{ inner1, inner2 };
    const src = M.fromPairs(&keys, &vals, 2) orelse @panic("map alloc");
    defer M.release(src);

    const inner1_rc_before = inner1.header.count();
    const inner2_rc_before = inner2.header.count();

    var saw_inner1 = false;
    var saw_inner2 = false;
    var state: ?*const M = src;
    while (true) {
        const step = M.next(state);
        if (step.@"0" == ATOM_DONE) break;
        const yielded_value = step.@"1".@"1" orelse @panic("null value");
        if (yielded_value == inner1) saw_inner1 = true;
        if (yielded_value == inner2) saw_inner2 = true;
        InnerList.release(yielded_value);
        state = step.@"2";
    }
    try std.testing.expect(saw_inner1);
    try std.testing.expect(saw_inner2);

    // After releasing the yielded values, the inner list refcounts
    // return to their pre-iteration values.
    try std.testing.expectEqual(inner1_rc_before, inner1.header.count());
    try std.testing.expectEqual(inner2_rc_before, inner2.header.count());
}

test "MapIter: large-map iteration produces zero retaining clones" {
    const M = Map(i64, i64);
    const N = 10_000;
    var keys: [N]i64 = undefined;
    var values: [N]i64 = undefined;
    for (0..N) |i| {
        keys[i] = @intCast(i);
        values[i] = @as(i64, @intCast(i));
    }
    const src = M.fromPairs(&keys, &values, N) orelse @panic("alloc failed");
    defer M.release(src);

    const clones_before = dense_map_retaining_clone_total;
    const iter_allocs_before = dense_map_iter_alloc_total;
    const iter_frees_before = dense_map_iter_free_total;
    const iter_advances_before = dense_map_iter_advance_total;

    var count: u32 = 0;
    var state: ?*const M = src;
    while (true) {
        const step = M.next(state);
        if (step.@"0" == ATOM_DONE) break;
        count += 1;
        state = step.@"2";
    }
    try std.testing.expectEqual(@as(u32, N), count);

    // Iteration must NOT trigger any retaining clones.
    try std.testing.expectEqual(clones_before, dense_map_retaining_clone_total);

    // Exactly one iter cell allocated for the whole walk, and
    // it was freed on the DONE step (no manual release needed).
    try std.testing.expectEqual(@as(u64, 1), dense_map_iter_alloc_total - iter_allocs_before);
    try std.testing.expectEqual(@as(u64, 1), dense_map_iter_free_total - iter_frees_before);

    // Advance count matches the number of cont steps after the
    // real-map's first step (N-1 advances + the final DONE which
    // doesn't bump the advance counter).
    try std.testing.expectEqual(@as(u64, N - 1), dense_map_iter_advance_total - iter_advances_before);
}

test "MapIter: single-entry map yields exactly one CONT then DONE" {
    // Boundary case for `Map.next`: when the source map has exactly
    // one entry, the first `Map.next(real_map)` call returns CONT
    // with that entry and an iter as next state, and the immediately
    // following `Map.next(iter)` call must return DONE. The iter
    // self-releases on DONE, so the source map's refcount is
    // unchanged across the round-trip and the iter cell count
    // returns to its pre-iteration value.
    const M = Map(i64, i64);
    const keys = [_]i64{42};
    const values = [_]i64{420};
    const src = M.fromPairs(&keys, &values, 1) orelse @panic("alloc failed");
    defer M.release(src);

    const refcount_before = src.header.count();
    const iter_allocs_before = dense_map_iter_alloc_total;
    const iter_frees_before = dense_map_iter_free_total;

    const first = M.next(src);
    try std.testing.expectEqual(ATOM_CONT, first.@"0");
    try std.testing.expectEqual(@as(i64, 42), first.@"1".@"0");
    try std.testing.expectEqual(@as(i64, 420), first.@"1".@"1");
    const iter = first.@"2";
    try std.testing.expect(iter != null);
    try std.testing.expect(iter != src);

    const second = M.next(iter);
    try std.testing.expectEqual(ATOM_DONE, second.@"0");
    try std.testing.expectEqual(@as(?*const M, null), second.@"2");

    // Source unchanged; iter cell freed; refcount restored.
    try std.testing.expectEqual(refcount_before, src.header.count());
    try std.testing.expectEqual(@as(u32, 1), src.len);
    try std.testing.expectEqual(@as(u64, 1), dense_map_iter_alloc_total - iter_allocs_before);
    try std.testing.expectEqual(@as(u64, 1), dense_map_iter_free_total - iter_frees_before);
}

test "MapIter: abandoning iteration after 2+ advances releases iter cell cleanly" {
    // Companion to "source map unchanged when iteration is abandoned"
    // which abandons at the first step. This variant exercises the
    // mid-cursor-advance abandonment path: advance the iter twice
    // (so `next_idx` reaches 2 — past the first step), then drop
    // it. The iter cell must still be freed via `Map.release`'s
    // iter-cell dispatch, the source map's refcount must return to
    // its pre-iteration value, and the iter cell free counter must
    // tick exactly once.
    const M = Map(i64, i64);
    var keys: [10]i64 = undefined;
    var values: [10]i64 = undefined;
    for (0..10) |i| {
        keys[i] = @intCast(i);
        values[i] = @as(i64, @intCast(i)) * 100;
    }
    const src = M.fromPairs(&keys, &values, 10) orelse @panic("alloc failed");
    defer M.release(src);

    const refcount_before = src.header.count();
    const iter_allocs_before = dense_map_iter_alloc_total;
    const iter_frees_before = dense_map_iter_free_total;
    const iter_advances_before = dense_map_iter_advance_total;

    // Step 1: first call returns CONT + the first entry + an iter.
    const step_one = M.next(src);
    try std.testing.expectEqual(ATOM_CONT, step_one.@"0");
    var iter = step_one.@"2";
    try std.testing.expect(iter != null);

    // Step 2: cursor advances in place — same iter pointer returned
    // (the iter is reused as state across calls).
    const step_two = M.next(iter);
    try std.testing.expectEqual(ATOM_CONT, step_two.@"0");
    try std.testing.expectEqual(iter, step_two.@"2");
    iter = step_two.@"2";

    // Step 3: advance once more so the cursor lands past the second
    // entry (next_idx == 3 inside the iter — fully mid-iteration).
    const step_three = M.next(iter);
    try std.testing.expectEqual(ATOM_CONT, step_three.@"0");
    try std.testing.expectEqual(iter, step_three.@"2");
    iter = step_three.@"2";

    // Source's refcount has gone up by 1 (the iter retains it).
    try std.testing.expectEqual(refcount_before + 1, src.header.count());

    // Two advances were recorded (steps 2 and 3 — step 1 is the
    // first-step allocation path which does NOT bump the advance
    // counter; see `Map.next`'s real-map branch).
    try std.testing.expectEqual(@as(u64, 2), dense_map_iter_advance_total - iter_advances_before);

    // Abandon the iteration mid-cursor-advance. `Map.release` routes
    // through the `capacity == 0` discriminator and frees the iter
    // cell + drops its retained source reference.
    M.release(iter);

    try std.testing.expectEqual(refcount_before, src.header.count());
    try std.testing.expectEqual(@as(u64, 1), dense_map_iter_alloc_total - iter_allocs_before);
    try std.testing.expectEqual(@as(u64, 1), dense_map_iter_free_total - iter_frees_before);
    try std.testing.expectEqual(@as(u32, 10), src.len);
}

test "MapIter: defensive path for null source_map returns DONE" {
    // Defensive coverage for `advanceFromMapPtr`'s null-source guard.
    // The path is unreachable from `Map.next` today (iter cells are
    // only created with a non-null source), but the guard exists so
    // future refactors can't silently UB on a freshly-zeroed iter
    // cell. Construct the failure shape directly: allocate an iter,
    // null its source_map, and confirm advanceFromMapPtr returns DONE
    // with no further side effects before freeing the cell.
    const M = Map(i64, i64);
    const keys = [_]i64{1};
    const values = [_]i64{10};
    const src = M.fromPairs(&keys, &values, 1) orelse @panic("alloc failed");
    defer M.release(src);

    const IterT = MapIter(i64, i64);
    const iter = IterT.create(src) orelse @panic("iter create");

    // Drop the retained source-map reference manually so we don't
    // leak the +1 the iter took on `create`. We hand-construct the
    // failure shape after this point so the iter no longer owns
    // anything on `src`.
    M.release(src);
    iter.source_map = null;

    // advanceFromMapPtr must return DONE on the null-source path.
    const step = IterT.advanceFromMapPtr(iter.asMapPtr().?);
    try std.testing.expectEqual(ATOM_DONE, step.@"0");
    try std.testing.expectEqual(@as(?*const M, null), step.@"2");

    // The iter cell still has rc=1 (advanceFromMapPtr only self-
    // releases on the cursor-end DONE path, not the null-source
    // DONE path). Free it through Map.release so its slab cell
    // returns to the pool.
    M.release(iter.asMapPtr());
}

// ============================================================
// Byte-keyed slab pool tests (Fix 6 — Phase 4.x verification).
//
// These tests target `TestOnlyArcSlabPool` directly, which mirrors
// the production manager's pool in `src/memory/arc/manager.zig`
// byte-for-byte (see Fix 7's comptime cross-check). The production
// manager's pool is exercised end-to-end via `Arc(T)` benchmarks
// and the existing integration tests; this block validates the
// pool's internal contracts (lookup classification, slab layout,
// refcount bookkeeping, cached-empty preservation, slab live-count
// policy) at a unit grain that those higher-level tests can't reach.
//
// Every test runs its own fresh `SlabPool` so test order is
// irrelevant and there's no cross-test contamination.
// ============================================================

test "byte-keyed slab pool: lookupClass classifies every defined class" {
    const Pool = TestOnlyArcSlabPool;
    // For each defined class, the smallest size that maps to it is
    // `(prev_class_size + 1)` (or 1 for class 0), and the largest is
    // exactly `SLAB_CLASS_SIZES[class_index]`. Probe both endpoints
    // with the class's natural alignment and verify classification.
    var class_index: u32 = 0;
    while (class_index < Pool.SLAB_CLASS_COUNT) : (class_index += 1) {
        const class_size = Pool.SLAB_CLASS_SIZES[class_index];
        const class_align = Pool.SLAB_CLASS_ALIGNS[class_index];
        const lower = if (class_index == 0) @as(usize, 1) else @as(usize, Pool.SLAB_CLASS_SIZES[class_index - 1]) + 1;
        const upper: usize = @intCast(class_size);
        const got_lower = Pool.lookupClass(lower, class_align).?;
        const got_upper = Pool.lookupClass(upper, class_align).?;
        try std.testing.expect(got_lower <= class_index);
        try std.testing.expectEqual(class_index, got_upper);
    }
}

test "byte-keyed slab pool: lookupClass returns null for size > MAX_SLAB_CLASS_SIZE" {
    const Pool = TestOnlyArcSlabPool;
    try std.testing.expectEqual(@as(?u32, null), Pool.lookupClass(Pool.MAX_SLAB_CLASS_SIZE + 1, 8));
    try std.testing.expectEqual(@as(?u32, null), Pool.lookupClass(8192, 8));
    try std.testing.expectEqual(@as(?u32, null), Pool.lookupClass(64 * 1024, 8));
}

test "byte-keyed slab pool: lookupClass returns null for size 0" {
    const Pool = TestOnlyArcSlabPool;
    try std.testing.expectEqual(@as(?u32, null), Pool.lookupClass(0, 1));
    try std.testing.expectEqual(@as(?u32, null), Pool.lookupClass(0, 64));
}

test "byte-keyed slab pool: lookupClass boundary 4096 fits, 4097 falls through" {
    const Pool = TestOnlyArcSlabPool;
    // 4096 is the largest slab class — must fit exactly.
    try std.testing.expect(Pool.lookupClass(4096, 8) != null);
    try std.testing.expectEqual(@as(u32, Pool.SLAB_CLASS_COUNT - 1), Pool.lookupClass(4096, 8).?);
    // 4097 exceeds every class — caller routes to the large path.
    try std.testing.expectEqual(@as(?u32, null), Pool.lookupClass(4097, 8));
}

test "byte-keyed slab pool: lookupClass alignment > 4096 forces large path" {
    const Pool = TestOnlyArcSlabPool;
    // Even a 16-byte request with 8192-byte alignment cannot fit in
    // any size class (all class natural alignments are <= class_size,
    // which caps at 4096). The hot-path lookup returns null and the
    // caller routes through `largeAlloc`.
    try std.testing.expectEqual(@as(?u32, null), Pool.lookupClass(16, 8192));
    try std.testing.expectEqual(@as(?u32, null), Pool.lookupClass(64, 16384));
}

test "byte-keyed slab pool: lookupClass alignment-induced class escalation" {
    const Pool = TestOnlyArcSlabPool;
    // A 16-byte request with 256-byte alignment cannot fit class 0
    // (alignment 16) — the loop escalates until it finds a class with
    // alignment >= 256, which is class 8 (size 256, align 256).
    const escalated = Pool.lookupClass(16, 256).?;
    try std.testing.expect(Pool.SLAB_CLASS_ALIGNS[escalated] >= 256);
    try std.testing.expect(Pool.SLAB_CLASS_SIZES[escalated] >= 16);
}

test "byte-keyed slab pool: LargeHeader round-trip" {
    const Pool = TestOnlyArcSlabPool;
    // Allocate a large request, verify the header is well-formed,
    // free it.
    const size: usize = Pool.MAX_SLAB_CLASS_SIZE + 100;
    const alignment: u32 = 16;
    const ptr = Pool.largeAlloc(size, alignment, 1).?;
    const header = Pool.largeHeader(@ptrCast(ptr));
    try std.testing.expectEqual(Pool.LARGE_MAGIC, header.magic);
    try std.testing.expectEqual(size, header.size);
    try std.testing.expectEqual(alignment, header.alignment);
    try std.testing.expectEqual(@as(u32, 1), header.refcount);
    Pool.largeFree(ptr);
}

test "byte-keyed slab pool: side-table refcount is per-slot" {
    const Pool = TestOnlyArcSlabPool;
    var pool = Pool.slabPoolInit();
    defer cleanupSlabPool(&pool);
    // Allocate three slots in the smallest class; verify their
    // side-table refcount slots are independent.
    const class_index: u32 = 0;
    const slot_a = Pool.slabAllocSlot(&pool, class_index, 3).?;
    const slot_b = Pool.slabAllocSlot(&pool, class_index, 5).?;
    const slot_c = Pool.slabAllocSlot(&pool, class_index, 7).?;
    const slab_a = Pool.slabFromSlotPtr(@ptrCast(slot_a));
    const slab_b = Pool.slabFromSlotPtr(@ptrCast(slot_b));
    const slab_c = Pool.slabFromSlotPtr(@ptrCast(slot_c));
    // All three slots are in the same slab (capacity is large for class 0).
    try std.testing.expectEqual(slab_a, slab_b);
    try std.testing.expectEqual(slab_a, slab_c);
    const idx_a = Pool.slotIndexInSlab(slab_a, @ptrCast(slot_a));
    const idx_b = Pool.slotIndexInSlab(slab_b, @ptrCast(slot_b));
    const idx_c = Pool.slotIndexInSlab(slab_c, @ptrCast(slot_c));
    try std.testing.expectEqual(@as(u32, 3), Pool.slabRefcountPtr(slab_a, idx_a).*);
    try std.testing.expectEqual(@as(u32, 5), Pool.slabRefcountPtr(slab_b, idx_b).*);
    try std.testing.expectEqual(@as(u32, 7), Pool.slabRefcountPtr(slab_c, idx_c).*);
    // Mutating one entry does not affect its neighbours.
    Pool.slabRefcountPtr(slab_a, idx_a).* = 99;
    try std.testing.expectEqual(@as(u32, 99), Pool.slabRefcountPtr(slab_a, idx_a).*);
    try std.testing.expectEqual(@as(u32, 5), Pool.slabRefcountPtr(slab_b, idx_b).*);
    try std.testing.expectEqual(@as(u32, 7), Pool.slabRefcountPtr(slab_c, idx_c).*);
    Pool.slabFreeSlot(&pool, slab_a, idx_a);
    Pool.slabFreeSlot(&pool, slab_b, idx_b);
    Pool.slabFreeSlot(&pool, slab_c, idx_c);
}

test "byte-keyed slab pool: cached-empty preservation across slab reuse" {
    const Pool = TestOnlyArcSlabPool;
    var pool = Pool.slabPoolInit();
    defer cleanupSlabPool(&pool);
    // Fill class 0 to spill into a second slab, then free everything
    // in the first slab. The first slab should land in cached_empty
    // (it's not the current). Verify cached_empty holds it, then
    // unmap the current slab manually and confirm the next allocate
    // pulls cached_empty.
    const class_index: u32 = 0;
    const capacity = Pool.capacityForClass(class_index);
    const initial_allocs = try std.testing.allocator.alloc([*]u8, capacity * 2);
    defer std.testing.allocator.free(initial_allocs);
    var alloc_idx: u32 = 0;
    while (alloc_idx < capacity * 2) : (alloc_idx += 1) {
        initial_allocs[alloc_idx] = Pool.slabAllocSlot(&pool, class_index, 1).?;
    }
    // The slab containing initial_allocs[0..capacity] is no longer
    // current. Free everything in that slab.
    const first_slab = Pool.slabFromSlotPtr(@ptrCast(initial_allocs[0]));
    var free_idx: u32 = 0;
    while (free_idx < capacity) : (free_idx += 1) {
        const slot = initial_allocs[free_idx];
        const slab = Pool.slabFromSlotPtr(@ptrCast(slot));
        try std.testing.expectEqual(first_slab, slab);
        const idx = Pool.slotIndexInSlab(slab, @ptrCast(slot));
        Pool.slabFreeSlot(&pool, slab, idx);
    }
    // The first slab's live_count is now 0. It should sit in
    // cached_empty (and out of partials).
    const class = &pool.classes[class_index];
    try std.testing.expectEqual(@as(?*Pool.SlabHeader, first_slab), class.cached_empty);
    try std.testing.expectEqual(@as(?*Pool.SlabHeader, null), class.partials);
    // Free the remaining (currently-active) slab's allocations so it
    // has free slots, then verify cached_empty is still the first
    // slab. The active-slab free-list pops first, so cached_empty
    // remains untouched while the current slab can service requests.
    free_idx = capacity;
    while (free_idx < capacity * 2) : (free_idx += 1) {
        const slot = initial_allocs[free_idx];
        const slab = Pool.slabFromSlotPtr(@ptrCast(slot));
        const idx = Pool.slotIndexInSlab(slab, @ptrCast(slot));
        Pool.slabFreeSlot(&pool, slab, idx);
    }
    // cached_empty is preserved; first_slab is still cached. The
    // active slab's free list now has entries, but cached_empty is
    // not touched until the active slab is rotated out.
    try std.testing.expectEqual(@as(?*Pool.SlabHeader, first_slab), class.cached_empty);
}

test "byte-keyed slab pool: empty slab unmap policy" {
    const Pool = TestOnlyArcSlabPool;
    var pool = Pool.slabPoolInit();
    defer cleanupSlabPool(&pool);
    // When a slab goes empty AND is not current AND cached_empty is
    // already occupied, the slab is unmapped immediately. We test
    // that policy by manufacturing two empty slabs and verifying the
    // second one is unmapped rather than cached.
    const class_index: u32 = 0;
    const capacity = Pool.capacityForClass(class_index);
    // Fill three slabs' worth of allocations.
    const triple = capacity * 3;
    const allocs = try std.testing.allocator.alloc([*]u8, triple);
    defer std.testing.allocator.free(allocs);
    for (allocs) |*slot_ptr_ref| {
        slot_ptr_ref.* = Pool.slabAllocSlot(&pool, class_index, 1).?;
    }
    // The pool now holds 3 slabs (the current and two on the partial
    // list). Free everything. The first two empty slabs that aren't
    // `current` will be cached_empty or unmapped.
    for (allocs) |slot_ptr| {
        const slab = Pool.slabFromSlotPtr(@ptrCast(slot_ptr));
        const idx = Pool.slotIndexInSlab(slab, @ptrCast(slot_ptr));
        Pool.slabFreeSlot(&pool, slab, idx);
    }
    // After all frees: at most one cached_empty, the current slab,
    // and zero partials. Anything else was unmapped.
    const class = &pool.classes[class_index];
    try std.testing.expectEqual(@as(?*Pool.SlabHeader, null), class.partials);
    try std.testing.expect(class.cached_empty != null);
    if (class.cached_empty) |slab| {
        try std.testing.expectEqual(@as(u32, 0), slab.live_count);
    }
}

test "byte-keyed slab pool: live_count tracks allocations and frees" {
    const Pool = TestOnlyArcSlabPool;
    var pool = Pool.slabPoolInit();
    defer cleanupSlabPool(&pool);
    const class_index: u32 = 5; // arbitrary mid-range class
    const total = 50;
    var allocs: [total][*]u8 = undefined;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        allocs[i] = Pool.slabAllocSlot(&pool, class_index, 1).?;
    }
    const slab = Pool.slabFromSlotPtr(@ptrCast(allocs[0]));
    try std.testing.expectEqual(@as(u32, total), slab.live_count);
    // Free half.
    i = 0;
    while (i < total / 2) : (i += 1) {
        const idx = Pool.slotIndexInSlab(slab, @ptrCast(allocs[i]));
        Pool.slabFreeSlot(&pool, slab, idx);
    }
    try std.testing.expectEqual(@as(u32, total - total / 2), slab.live_count);
    // Free the rest.
    while (i < total) : (i += 1) {
        const s = Pool.slabFromSlotPtr(@ptrCast(allocs[i]));
        const idx = Pool.slotIndexInSlab(s, @ptrCast(allocs[i]));
        Pool.slabFreeSlot(&pool, s, idx);
    }
    try std.testing.expectEqual(@as(u32, 0), slab.live_count);
}

test "byte-keyed slab pool: alloc/free returns same slot via free-list" {
    const Pool = TestOnlyArcSlabPool;
    var pool = Pool.slabPoolInit();
    defer cleanupSlabPool(&pool);
    const class_index: u32 = 0;
    // Allocate two slots, free the first, allocate a third — the
    // third should occupy the freed slot (LIFO free-list semantics).
    const slot_a = Pool.slabAllocSlot(&pool, class_index, 1).?;
    const slot_b = Pool.slabAllocSlot(&pool, class_index, 1).?;
    const slab_a = Pool.slabFromSlotPtr(@ptrCast(slot_a));
    const idx_a = Pool.slotIndexInSlab(slab_a, @ptrCast(slot_a));
    Pool.slabFreeSlot(&pool, slab_a, idx_a);
    const slot_c = Pool.slabAllocSlot(&pool, class_index, 1).?;
    try std.testing.expectEqual(@intFromPtr(slot_a), @intFromPtr(slot_c));
    const slab_c = Pool.slabFromSlotPtr(@ptrCast(slot_c));
    const idx_c = Pool.slotIndexInSlab(slab_c, @ptrCast(slot_c));
    Pool.slabFreeSlot(&pool, slab_c, idx_c);
    const slab_b = Pool.slabFromSlotPtr(@ptrCast(slot_b));
    const idx_b = Pool.slotIndexInSlab(slab_b, @ptrCast(slot_b));
    Pool.slabFreeSlot(&pool, slab_b, idx_b);
}

test "byte-keyed slab pool: 64-KiB-aligned slab base mask round-trip" {
    const Pool = TestOnlyArcSlabPool;
    var pool = Pool.slabPoolInit();
    defer cleanupSlabPool(&pool);
    const class_index: u32 = 0;
    const slot = Pool.slabAllocSlot(&pool, class_index, 1).?;
    const slab = Pool.slabFromSlotPtr(@ptrCast(slot));
    try std.testing.expect((@intFromPtr(slab) & Pool.SLAB_MASK) == 0);
    try std.testing.expect((@intFromPtr(slab) % Pool.SLAB_ALIGN) == 0);
    try std.testing.expectEqual(Pool.SLAB_MAGIC, slab.magic);
    const idx = Pool.slotIndexInSlab(slab, @ptrCast(slot));
    Pool.slabFreeSlot(&pool, slab, idx);
}

test "byte-keyed slab pool: largeAlloc handles size > MAX_SLAB_CLASS_SIZE" {
    const Pool = TestOnlyArcSlabPool;
    // 5000 bytes — above the 4096 ceiling — should round-trip through
    // the large-allocation path with a tagged LargeHeader prefix.
    const size: usize = 5000;
    const alignment: u32 = 8;
    const ptr = Pool.largeAlloc(size, alignment, 2).?;
    const header = Pool.largeHeader(@ptrCast(ptr));
    try std.testing.expectEqual(Pool.LARGE_MAGIC, header.magic);
    try std.testing.expectEqual(size, header.size);
    try std.testing.expectEqual(alignment, header.alignment);
    try std.testing.expectEqual(@as(u32, 2), header.refcount);
    Pool.largeFree(ptr);
}

test "byte-keyed slab pool: capacityForClass returns positive for every class" {
    const Pool = TestOnlyArcSlabPool;
    // Every defined size class must hold at least one slot in a
    // 64-KiB slab — otherwise the slab pool can't service a request
    // for that class. The capacity computation is closed-form, so a
    // failure here means the slab math drifted out of the safe range.
    var class_index: u32 = 0;
    while (class_index < Pool.SLAB_CLASS_COUNT) : (class_index += 1) {
        const cap = Pool.capacityForClass(class_index);
        try std.testing.expect(cap > 0);
    }
}

/// Test helper: walk every class and free every still-mapped slab,
/// so the test's `defer` block can return all VM regions back to the
/// kernel without leaking. Mirrors the production manager's
/// `arcDeinit` walk, simplified for the per-test pool lifetime.
fn cleanupSlabPool(pool: *TestOnlyArcSlabPool.SlabPool) void {
    const Pool = TestOnlyArcSlabPool;
    var class_index: u32 = 0;
    while (class_index < Pool.SLAB_CLASS_COUNT) : (class_index += 1) {
        const class = &pool.classes[class_index];
        if (class.current) |slab| {
            Pool.unmapSlab(slab.allocation_base);
            class.current = null;
        }
        while (class.partials) |slab| {
            class.partials = slab.next;
            Pool.unmapSlab(slab.allocation_base);
        }
        if (class.cached_empty) |slab| {
            Pool.unmapSlab(slab.allocation_base);
            class.cached_empty = null;
        }
    }
}

// ============================================================
// v1.0 REFCOUNT_V1 legacy-fallback tests (Gap A — round-2 verification).
//
// The runtime exposes a complete v1.0 backward-compat path:
//   * `dispatcherAllocLegacyV1_0`
//   * `LegacyArcInnerLayout(T)` / `legacyArcInnerHeaderFromValuePtr` /
//     `legacyArcInnerBaseFromValuePtr`
//   * `LegacyV1_0ShallowFreeClosure(T)`
//   * `LegacyV1_0ReleaseClosure(T)`
//   * v1.0 branches in `dispatcherFreeImpl`, `dispatcherReleaseImpl`,
//     `dispatcherRetainImpl`, `dispatcherRetainAnyPersistentImpl`,
//     and `refCountAny`
//
// In a default `zig build test` run the test-only manager always
// advertises `desc.size = 48`, so `active_manager_state.refcount_has_sized_extension`
// is true and the v1.0 branches never fire. These tests install a
// parallel v1.0 descriptor (`test_only_arc_v1_0_refcount_descriptor`,
// size = 16) via `installRefcountCapabilityForTest`, exercise the
// legacy path end-to-end, then restore the pre-test capability state
// so subsequent tests see the v1.1 default. Without this coverage a
// regression in any v1.0 branch — alloc, retain, release, refcount
// query, deep-release closure, shallow-free closure, alignment math —
// would slip through CI.
//
// Test ordering: each test saves capability state on entry and
// restores it on exit via `defer`. The `defer` must run even on a
// test failure so the next test sees a clean v1.1 binding.
//
// Concurrency: single-threaded test runner. If parallel tests are
// ever enabled, these tests must move to a dedicated serial test
// file because they mutate process-global state.
// ============================================================

/// Helper used by the v1.0 fallback tests to allocate an Arc(T)
/// through `dispatcherAllocImpl` (which routes through
/// `dispatcherAllocLegacyV1_0` when the active descriptor is v1.0).
/// Returns the user-visible value pointer; the caller must release
/// (or `freeAny`) through the same dispatcher to balance the alloc.
fn legacyArcAllocForTest(comptime T: type, value: T) *T {
    return ArcRuntime.allocAny(T, std.testing.allocator, value);
}

test "v1.0 fallback: allocate routes through dispatcherAllocLegacyV1_0" {
    ensureMemoryStartup();
    saveActiveRefcountCapabilityForTest();
    defer restoreActiveRefcountCapabilityForTest();
    installRefcountCapabilityForTest(&test_only_arc_v1_0_refcount_descriptor);
    try std.testing.expect(!active_manager_state.refcount_has_sized_extension);

    // Allocate an Arc(i64) under the v1.0 manager. The allocator
    // must request `@sizeOf(LegacyArcInner(i64))` from
    // `core.allocate` and return the pointer past the inline header.
    const val_ptr = legacyArcAllocForTest(i64, 7);
    defer ArcRuntime.releaseAny(std.testing.allocator, val_ptr);

    // The user pointer is `&inner.value`. Walk back to the
    // `LegacyArcInner(i64).header` and verify it sits at offset 0
    // (refcount initialised to 1).
    const Inner = extern struct { header: ArcHeader, value: i64 };
    const value_addr = @intFromPtr(val_ptr);
    const inner_addr = value_addr - @offsetOf(Inner, "value");
    const inner: *Inner = @ptrFromInt(inner_addr);
    try std.testing.expectEqual(@as(u32, 1), inner.header.count());
    try std.testing.expectEqual(@as(i64, 7), val_ptr.*);
}

test "v1.0 fallback: retainAny increments inline-header refcount" {
    ensureMemoryStartup();
    saveActiveRefcountCapabilityForTest();
    defer restoreActiveRefcountCapabilityForTest();
    installRefcountCapabilityForTest(&test_only_arc_v1_0_refcount_descriptor);
    try std.testing.expect(!active_manager_state.refcount_has_sized_extension);

    const val_ptr = legacyArcAllocForTest(i64, 99);
    try std.testing.expectEqual(@as(u32, 1), ArcRuntime.refCountAny(val_ptr));

    ArcRuntime.retainAny(val_ptr);
    try std.testing.expectEqual(@as(u32, 2), ArcRuntime.refCountAny(val_ptr));

    ArcRuntime.retainAny(val_ptr);
    try std.testing.expectEqual(@as(u32, 3), ArcRuntime.refCountAny(val_ptr));

    // Three releases bring the refcount to zero and invoke the
    // deep-release closure, which frees the `LegacyArcInner` via
    // `core.deallocate`.
    ArcRuntime.releaseAny(std.testing.allocator, val_ptr);
    ArcRuntime.releaseAny(std.testing.allocator, val_ptr);
    ArcRuntime.releaseAny(std.testing.allocator, val_ptr);
}

test "v1.0 fallback: deep release fires LegacyV1_0ReleaseClosure on zero transition" {
    ensureMemoryStartup();
    saveActiveRefcountCapabilityForTest();
    defer restoreActiveRefcountCapabilityForTest();
    installRefcountCapabilityForTest(&test_only_arc_v1_0_refcount_descriptor);

    // Allocate, retain so refcount = 2, then call `releaseAny` twice.
    // The first release decrements to 1 (no free). The second
    // transitions to 0 and the manager's `release` slot invokes
    // `LegacyV1_0ReleaseClosure(i64).run`, which calls
    // `core.deallocate`. We can't directly observe the deallocate
    // call (the test-only manager's `core.deallocate` is a side-
    // effecting slab return), but we can re-allocate immediately
    // afterward and verify the same slot is recycled — proving the
    // deep-release path returned the slot to the pool.
    const first = legacyArcAllocForTest(i64, 42);
    ArcRuntime.retainAny(first);
    try std.testing.expectEqual(@as(u32, 2), ArcRuntime.refCountAny(first));

    const first_inner_addr = @intFromPtr(first) - @offsetOf(extern struct { header: ArcHeader, value: i64 }, "value");

    ArcRuntime.releaseAny(std.testing.allocator, first);
    try std.testing.expectEqual(@as(u32, 1), ArcRuntime.refCountAny(first));
    ArcRuntime.releaseAny(std.testing.allocator, first);
    // After zero-transition the slot is freed. Allocate again to
    // confirm pool reuse — the test-only slab pool uses LIFO
    // free-list semantics, so a same-size alloc following a free in
    // the same slab returns the just-freed slot.
    const second = legacyArcAllocForTest(i64, 1234);
    defer ArcRuntime.releaseAny(std.testing.allocator, second);
    const second_inner_addr = @intFromPtr(second) - @offsetOf(extern struct { header: ArcHeader, value: i64 }, "value");
    try std.testing.expectEqual(first_inner_addr, second_inner_addr);
    try std.testing.expectEqual(@as(i64, 1234), second.*);
}

test "v1.0 fallback: freeAny invokes LegacyV1_0ShallowFreeClosure (no deep walk)" {
    ensureMemoryStartup();
    saveActiveRefcountCapabilityForTest();
    defer restoreActiveRefcountCapabilityForTest();
    installRefcountCapabilityForTest(&test_only_arc_v1_0_refcount_descriptor);

    // `freeAny` is the shallow-free path: the caller has already
    // released children (or the type has none), so the manager
    // skips the deep walk and just deallocates the inner. Verify
    // observable slot reuse with the same LIFO trick as the deep-
    // release test.
    const first = legacyArcAllocForTest(i64, 555);
    const first_inner_addr = @intFromPtr(first) - @offsetOf(extern struct { header: ArcHeader, value: i64 }, "value");

    // Single owner — refcount transitions 1 -> 0 directly. The
    // dispatcher routes through `cap.release(ctx, &inner.header,
    // LegacyV1_0ShallowFreeClosure(i64).run)` which calls
    // `core.deallocate` without walking children.
    ArcRuntime.freeAny(std.testing.allocator, first);

    const second = legacyArcAllocForTest(i64, 999);
    defer ArcRuntime.releaseAny(std.testing.allocator, second);
    const second_inner_addr = @intFromPtr(second) - @offsetOf(extern struct { header: ArcHeader, value: i64 }, "value");
    try std.testing.expectEqual(first_inner_addr, second_inner_addr);
    try std.testing.expectEqual(@as(i64, 999), second.*);
}

test "v1.0 fallback: legacy alloc honors LegacyArcInner alignment for varied T sizes" {
    ensureMemoryStartup();
    saveActiveRefcountCapabilityForTest();
    defer restoreActiveRefcountCapabilityForTest();
    installRefcountCapabilityForTest(&test_only_arc_v1_0_refcount_descriptor);

    // The inline-header layout's natural alignment is
    // `@alignOf(LegacyArcInner(T)) = max(@alignOf(ArcHeader=u32),
    // @alignOf(T))`. The manager's `core.allocate` must hand back a
    // pointer aligned to that bound. Probe a range of T sizes /
    // alignments to make sure the layout math survives in every
    // class.
    const Cases = struct { name: []const u8, run: *const fn () anyerror!void };

    const probes = [_]Cases{
        .{
            .name = "u8",
            .run = struct {
                fn run() !void {
                    const val_ptr = ArcRuntime.allocAny(u8, std.testing.allocator, 0xAB);
                    defer ArcRuntime.releaseAny(std.testing.allocator, val_ptr);
                    const Inner = extern struct { header: ArcHeader, value: u8 };
                    try std.testing.expect(@intFromPtr(val_ptr) % @alignOf(u8) == 0);
                    const inner_addr = @intFromPtr(val_ptr) - @offsetOf(Inner, "value");
                    try std.testing.expect(inner_addr % @alignOf(Inner) == 0);
                    try std.testing.expectEqual(@as(u8, 0xAB), val_ptr.*);
                }
            }.run,
        },
        .{
            .name = "[7]u8",
            .run = struct {
                fn run() !void {
                    const T = [7]u8;
                    const val_ptr = ArcRuntime.allocAny(T, std.testing.allocator, [_]u8{ 1, 2, 3, 4, 5, 6, 7 });
                    defer ArcRuntime.releaseAny(std.testing.allocator, val_ptr);
                    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7 }, val_ptr[0..]);
                }
            }.run,
        },
        .{
            .name = "u128",
            .run = struct {
                fn run() !void {
                    const val_ptr = ArcRuntime.allocAny(u128, std.testing.allocator, 0xDEADBEEF_CAFEBABE_12345678_90ABCDEF);
                    defer ArcRuntime.releaseAny(std.testing.allocator, val_ptr);
                    try std.testing.expect(@intFromPtr(val_ptr) % @alignOf(u128) == 0);
                    try std.testing.expectEqual(@as(u128, 0xDEADBEEF_CAFEBABE_12345678_90ABCDEF), val_ptr.*);
                }
            }.run,
        },
        .{
            .name = "[64]u8",
            .run = struct {
                fn run() !void {
                    const T = [64]u8;
                    var seed: T = undefined;
                    for (0..64) |i| seed[i] = @intCast(i);
                    const val_ptr = ArcRuntime.allocAny(T, std.testing.allocator, seed);
                    defer ArcRuntime.releaseAny(std.testing.allocator, val_ptr);
                    try std.testing.expectEqualSlices(u8, &seed, val_ptr[0..]);
                }
            }.run,
        },
    };
    for (probes) |probe| {
        probe.run() catch |err| {
            std.debug.print("v1.0 fallback alignment probe failed for {s}: {s}\n", .{ probe.name, @errorName(err) });
            return err;
        };
    }
}

test "v1.0 fallback: retainAnyPersistent routes through legacy retain slot" {
    ensureMemoryStartup();
    saveActiveRefcountCapabilityForTest();
    defer restoreActiveRefcountCapabilityForTest();
    installRefcountCapabilityForTest(&test_only_arc_v1_0_refcount_descriptor);
    try std.testing.expect(!active_manager_state.refcount_has_sized_extension);

    // `retainAnyPersistent` mirrors `retainAny` on the v1.0 path —
    // both dispatch through `cap.retain(ctx, &inner.header)` because
    // the v1.0 vtable has no separate persistent-share slot. This
    // test exercises the dispatcher branch in
    // `dispatcherRetainAnyPersistentImpl` so a regression that drops
    // the v1.0 fallback there surfaces immediately.
    const val_ptr = legacyArcAllocForTest(i64, 5150);
    defer ArcRuntime.releaseAny(std.testing.allocator, val_ptr);
    defer ArcRuntime.releaseAny(std.testing.allocator, val_ptr);

    ArcRuntime.retainAnyPersistent(val_ptr);
    try std.testing.expectEqual(@as(u32, 2), ArcRuntime.refCountAny(val_ptr));
    try std.testing.expectEqual(@as(i64, 5150), val_ptr.*);
}

test "v1.0 fallback: trap stubs panic when sized slots are dispatched (compile-time wiring check)" {
    ensureMemoryStartup();
    saveActiveRefcountCapabilityForTest();
    defer restoreActiveRefcountCapabilityForTest();
    installRefcountCapabilityForTest(&test_only_arc_v1_0_refcount_descriptor);

    // After v1.0 binding, the composed capability vtable's slots 2-5
    // must be the trap stubs (Gap D's defense-in-depth). We don't
    // actually invoke them — that would abort the test process —
    // but we verify their function-pointer identity to guard against
    // a regression that leaves slots 2-5 pointing at out-of-bounds
    // memory or at the v1.1 implementations.
    const cap = active_manager_state.refcount_capability orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(
        @as(@TypeOf(cap.retain_sized), v1_0_trap_retain_sized),
        cap.retain_sized,
    );
    try std.testing.expectEqual(
        @as(@TypeOf(cap.release_sized), v1_0_trap_release_sized),
        cap.release_sized,
    );
    try std.testing.expectEqual(
        @as(@TypeOf(cap.allocate_refcounted), v1_0_trap_allocate_refcounted),
        cap.allocate_refcounted,
    );
    try std.testing.expectEqual(
        @as(@TypeOf(cap.refcount_sized), v1_0_trap_refcount_sized),
        cap.refcount_sized,
    );

    // Slots 0 and 1 must mirror the v1.0 descriptor's user-supplied
    // function pointers (the test-only retain/release).
    try std.testing.expectEqual(
        @as(@TypeOf(cap.retain), testOnlyArcRetain),
        cap.retain,
    );
    try std.testing.expectEqual(
        @as(@TypeOf(cap.release), testOnlyArcRelease),
        cap.release,
    );
}
