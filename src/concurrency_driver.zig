//! Concurrency kernel build driver (P2-J1 —
//! `docs/concurrency-implementation-plan.md` §4 / Phase 2 packaging).
//!
//! When a build's `runtime_concurrency` gate is ON, this driver turns
//! the self-contained kernel source unit (`src/runtime/concurrency/`,
//! rooted at `abi.zig`) into a per-target object file through the SAME
//! Zig-fork primitive the memory-manager driver uses
//! (`zap_fork_compile_zig_to_object` — plan §4: "compiled per target …
//! exactly like manager sources — never text codegen"). The resulting
//! object is spliced into the user binary's link line by
//! `src/zir_backend.zig` via `zir_compilation_add_link_object_file`,
//! alongside the ZIR-generated code and the `zap_active_manager`
//! source module.
//!
//! Multi-file-root note (the P2-J1 packaging finding): the fork
//! primitive already supports multi-file roots — `compileToObjectImpl`
//! creates the root `Package.Module` with `root = dirname(source_path)`
//! and `root_src_path = basename(source_path)`, so the root file's
//! relative `@import`s of its siblings resolve through Zig's ordinary
//! module machinery. No fork extension was required; `abi.zig`
//! `@import`s the whole kernel tree and the primitive compiles it as
//! one unit.
//!
//! When the gate is OFF this driver is never invoked: no kernel source
//! is read, no object is produced or linked, and no `zap_proc_*` symbol
//! exists in the binary (plan §3 zero-cost guarantee, job constraint 4).
//!
//! ## Caching
//!
//! The object is content-addressed, mirroring the manager validation
//! cache (`src/memory/driver.zig` §10.3 semantics): the cache key
//! digests every `.zig` file of the kernel unit (sorted path + content,
//! length-prefixed), the root basename, the toolchain identity digests,
//! the optimize mode, the target identity (triple, or host arch/os/abi
//! for native), and the CPU string. A keyed object already on disk is
//! reused without invoking the fork; a fresh compile lands via
//! write-to-temporary + atomic rename so a crashed build can never
//! leave a truncated object that later cache-hits. The key's hex form
//! is also folded into the build's artifact cache key by `src/main.zig`
//! so editing a kernel source invalidates cached user binaries.

const std = @import("std");
const builtin = @import("builtin");
const memory_driver = @import("memory/driver.zig");
const progress_mod = @import("progress.zig");

/// Schema tag folded into the cache key so a future change to what the
/// key covers self-invalidates every older entry. v2: the P6-J6
/// `runtime_tracing` gate joined the key. v3: the kernel object's libc
/// posture (`KERNEL_OBJECT_LINK_LIBC`) joined the key (7.1a) — objects
/// cached by older schemas were compiled under the fork's internal libc
/// decision (no libc on Linux) and must never cache-hit a build whose
/// kernel object now links libc.
const KERNEL_CACHE_SCHEMA = "zap.concurrency.kernel.object.cache.v3";

/// The kernel object's libc posture (7.1a): ALWAYS compiled with
/// `link_libc = true`, matching the final binary's link
/// (`src/zir_backend.zig` `link_libc: bool = true`). The kernel
/// deliberately reads `std.c.getenv` / `std.c.clock_gettime` — the
/// documented production seams — so on targets where the fork's
/// internal default would skip libc (Linux) the object would otherwise
/// fail to compile with `std.c` resolution errors. A single constant
/// feeds BOTH the cache key (`kernelCacheKeyHex`) and the fork compile
/// (`compileKernelUnit`) so the key can never drift from the object it
/// addresses.
const KERNEL_OBJECT_LINK_LIBC: memory_driver.ZapForkLinkLibc = .on;

/// The trace-gate marker line the staging rewrite flips (P6-J6 — the
/// P2-J1 `RUNTIME_CONCURRENCY_DEFAULT` marker-rewrite pattern applied to
/// the kernel unit). Lives in `src/runtime/concurrency/trace.zig`.
const TRACE_MARKER_FILE_BASENAME = "trace.zig";
const TRACE_MARKER_OFF = "pub const RUNTIME_TRACE_DEFAULT: bool = false;";
const TRACE_MARKER_ON = "pub const RUNTIME_TRACE_DEFAULT: bool = true;";

/// Path of the kernel source unit relative to the Zap source tree root
/// (the parent of the resolved stdlib `lib/` directory — the same root
/// the memory driver resolves stdlib manager backends under).
pub const KERNEL_UNIT_RELATIVE_DIR = "src/runtime/concurrency";

/// Root file of the kernel compilation unit: the C-ABI intrinsic
/// bridge, which `@import`s the rest of the kernel tree.
pub const KERNEL_ROOT_BASENAME = "abi.zig";

/// The cpu architectures the concurrency kernel can exist on at all —
/// the driver-level mirror of the fork's stackful-fiber support set
/// (`~/projects/zig/lib/std/Io/fiber.zig`, `pub const supported`) and of
/// the kernel's own comptime guard (`src/runtime/concurrency/
/// fiber_context.zig`: "the Zap concurrency kernel requires stackful
/// fiber support"). `validateKernelTargetSupport` checks this set BEFORE
/// any kernel work so a gate-ON build for an unsupported target fails
/// with ONE actionable diagnostic at the earliest point that knows both
/// the gate and the target (plan 7.1's capability-matrix posture),
/// instead of a screen of fiber/thread/atomic errors from deep inside
/// the kernel-object compile. The OS axis of the same capability matrix
/// lives in `kernelSupportsOperatingSystem` (plan 7.2).
pub const FIBER_SUPPORTED_ARCHITECTURES = [_]std.Target.Cpu.Arch{ .aarch64, .riscv64, .x86_64 };

/// The intrinsic export the compiled object is asserted to carry. One
/// symbol suffices as the build-time link-surface tripwire: all
/// `zap_proc_*` exports live in the same root file, so a root-file
/// mismatch (wrong file compiled, exports renamed) fails here with a
/// precise diagnostic instead of at the user binary's final link.
pub const KERNEL_SENTINEL_SYMBOL = "zap_proc_runtime_init";

/// Driver-level errors, mirroring the memory driver's error/diagnostic
/// discipline (each variant is paired with a populated diagnostic).
pub const KernelResolveError = error{
    /// The build target cannot host the kernel at all — its cpu
    /// architecture has no stackful-fiber support (see
    /// `FIBER_SUPPORTED_ARCHITECTURES`) or its operating system has no
    /// kernel OS-primitive layer (see `kernelSupportsOperatingSystem`).
    /// Raised BEFORE any kernel work with an actionable diagnostic.
    KernelTargetUnsupported,
    /// The kernel source directory or its root file could not be read.
    KernelSourceNotFound,
    /// The fork primitive rejected the compile; the diagnostic carries
    /// the forwarded compiler errors.
    KernelCompileFailed,
    /// The compiled object could not be read back for validation.
    ObjectReadFailed,
    /// The compiled object does not export the sentinel intrinsic.
    ValidationFailed,
    /// Internal driver error (filesystem, allocator misuse) not
    /// described above.
    InternalError,
    OutOfMemory,
};

/// Inputs for kernel-object resolution. Mirrors the shape of
/// `memory_driver.ResolveOptions` for the fields both drivers share.
pub const KernelResolveOptions = struct {
    /// Absolute or cwd-relative path to the kernel source unit
    /// directory (production: `<zap_source_root>/src/runtime/concurrency`).
    kernel_source_dir: []const u8,
    /// Root file basename within `kernel_source_dir`.
    kernel_root_basename: []const u8 = KERNEL_ROOT_BASENAME,
    /// Directory the compiled kernel object is cached in. Created if
    /// absent.
    cache_dir: []const u8,
    /// Optional Zig stdlib directory forwarded to the fork primitive.
    zig_lib_dir: ?[]const u8 = null,
    /// Identity digest of the running Zap compiler / Zig fork toolchain
    /// (required in production; test-only default mirrors the memory
    /// driver's discipline).
    compiler_identity_digest: ?[32]u8 = null,
    /// Identity digest of the Zig stdlib directory (same discipline).
    zig_lib_identity_digest: ?[32]u8 = null,
    /// Optimize mode forwarded to the fork primitive — the same value
    /// the build passes for the manager object so every object in the
    /// final link agrees.
    optimize: memory_driver.ZapForkOptimize = .ReleaseSafe,
    /// Cross-compile target triple (null = native), identical semantics
    /// to the memory driver.
    target: ?[]const u8 = null,
    /// CPU model/feature set (null/"" = the triple's default CPU).
    cpu: ?[]const u8 = null,
    /// Test seam: overrides the linked-in fork primitive.
    fork_compile_fn: ?memory_driver.ForkCompileFn = null,
    /// Optional CLI progress reporter owned by the build command.
    progress: ?*progress_mod.Reporter = null,
    /// P6-J6: the resolved `runtime_tracing` gate. OFF (default) compiles
    /// the kernel unit from the source tree unchanged — byte-identical to
    /// a pre-tracing build. ON compiles from a STAGED COPY of the unit
    /// with `trace.zig`'s `RUNTIME_TRACE_DEFAULT` marker rewritten to
    /// `true` (the source tree is never modified), enabling the
    /// comptime-gated trace instrumentation. Folded into the cache key.
    runtime_tracing: bool = false,
};

/// A resolved (content-addressed, validated) kernel object.
pub const ResolvedKernel = struct {
    /// Absolute-or-cwd-relative path of the compiled kernel object,
    /// owned by the caller's allocator.
    object_path: []const u8,
    /// Hex form of the content-address key. Value type — callers fold
    /// it into the build artifact cache key.
    cache_key_hex: [64]u8,
};

/// Free the owned memory inside a `ResolvedKernel`. Safe to call once.
pub fn freeResolvedKernel(allocator: std.mem.Allocator, resolved: *ResolvedKernel) void {
    allocator.free(resolved.object_path);
    resolved.object_path = "";
}

/// Compute the kernel unit's content-address key WITHOUT compiling
/// (cheap; safe to run before an artifact-cache check, mirroring
/// `memory_driver.resolveManagerSource`'s role). Digests every `.zig`
/// file under `kernel_source_dir` (recursively, sorted) plus the build
/// controls listed in the module doc.
pub fn kernelCacheKeyHex(
    allocator: std.mem.Allocator,
    options: KernelResolveOptions,
    diag: *memory_driver.DriverDiagnostic,
) KernelResolveError![64]u8 {
    // Capability gate first: no cache key exists for a target the kernel
    // cannot exist on. Every build path reaches the driver through this
    // function (the manifest compile tail and script-mode key computation
    // call it directly; `resolveKernelObject` calls it before compiling),
    // so this is the single earliest enforcement point.
    try validateKernelTargetSupport(options.target, diag);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashLenPrefixed(&hasher, KERNEL_CACHE_SCHEMA);
    hashLenPrefixed(&hasher, options.kernel_root_basename);

    try hashKernelSources(allocator, &hasher, options, diag);

    const compiler_identity = try requiredIdentity(options.compiler_identity_digest, "compiler", diag);
    const zig_lib_identity = try requiredIdentity(options.zig_lib_identity_digest, "Zig lib", diag);
    hasher.update(&compiler_identity);
    hasher.update(&zig_lib_identity);

    const optimize_tag: u8 = @intCast(@intFromEnum(options.optimize));
    hasher.update(std.mem.asBytes(&optimize_tag));

    if (options.target) |triple| {
        hashLenPrefixed(&hasher, triple);
    } else {
        // Native identity: the host triple, so a cache directory shared
        // across hosts (e.g. a copied workspace) can never false-hit.
        hashLenPrefixed(&hasher, "native");
        hashLenPrefixed(&hasher, @tagName(builtin.cpu.arch));
        hashLenPrefixed(&hasher, @tagName(builtin.os.tag));
        hashLenPrefixed(&hasher, @tagName(builtin.abi));
    }
    hashLenPrefixed(&hasher, options.cpu orelse "");
    hashLenPrefixed(&hasher, options.zig_lib_dir orelse "");

    // P6-J6: the trace gate changes the compiled object (the staged
    // marker rewrite), so it is part of the object's identity.
    const tracing_byte: u8 = if (options.runtime_tracing) 1 else 0;
    hasher.update(std.mem.asBytes(&tracing_byte));

    // 7.1a: the libc posture changes the compiled object (which `std.c`
    // externs resolve, and the object/final-link agreement), so it is
    // part of the object's identity — a change to
    // `KERNEL_OBJECT_LINK_LIBC` must miss the cache.
    const link_libc_byte: u8 = @intCast(@intFromEnum(KERNEL_OBJECT_LINK_LIBC));
    hasher.update(std.mem.asBytes(&link_libc_byte));

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digestHex(digest);
}

/// Resolve the compiled kernel object for this build: compute the
/// content-address key, reuse the keyed object when present, otherwise
/// compile the kernel unit through the fork primitive (temporary path +
/// atomic rename) and assert the sentinel intrinsic export. The
/// returned `object_path` is owned by `allocator`.
pub fn resolveKernelObject(
    allocator: std.mem.Allocator,
    options: KernelResolveOptions,
    diag: *memory_driver.DriverDiagnostic,
) KernelResolveError!ResolvedKernel {
    const cache_key_hex = try kernelCacheKeyHex(allocator, options, diag);

    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, options.cache_dir) catch {};

    const object_basename = std.fmt.allocPrint(
        allocator,
        "zap_concurrency_kernel-{s}.o",
        .{cache_key_hex},
    ) catch return KernelResolveError.OutOfMemory;
    defer allocator.free(object_basename);
    const object_path = std.fs.path.join(allocator, &.{ options.cache_dir, object_basename }) catch
        return KernelResolveError.OutOfMemory;
    errdefer allocator.free(object_path);

    // Content-addressed reuse: the key covers every input that affects
    // the object, and completed objects are published atomically below,
    // so existence at the keyed path IS validity.
    if (pathIsReadable(object_path)) {
        return .{ .object_path = object_path, .cache_key_hex = cache_key_hex };
    }

    if (options.progress) |progress| {
        progress.stage("Concurrency: compiling kernel object", .{});
        progress.commitLine();
    }

    const root_source_path = std.fs.path.join(
        allocator,
        &.{ options.kernel_source_dir, options.kernel_root_basename },
    ) catch return KernelResolveError.OutOfMemory;
    defer allocator.free(root_source_path);

    // P6-J6: with `runtime_tracing` ON, compile from a STAGED COPY of the
    // kernel unit whose `trace.zig` marker is rewritten to `true` — the
    // P2-J1 marker-rewrite pattern applied to the kernel; the source tree
    // is never modified. OFF compiles from the tree unchanged (the
    // zero-cost posture: the OFF object is byte-for-byte the object a
    // build with no tracing support would produce). The staging directory
    // is process-unique and removed after the compile (the OBJECT is what
    // the cache keeps).
    var staging_dir_path: ?[]const u8 = null;
    defer if (staging_dir_path) |staged_dir| {
        std.Io.Dir.cwd().deleteTree(std.Options.debug_io, staged_dir) catch {};
        allocator.free(staged_dir);
    };
    var staged_root_path: ?[]const u8 = null;
    defer if (staged_root_path) |staged_root| allocator.free(staged_root);
    if (options.runtime_tracing) {
        const staged_dir = std.fmt.allocPrint(
            allocator,
            "{s}/traced-src.tmp-{d}",
            .{ options.cache_dir, interimPathDiscriminator() },
        ) catch return KernelResolveError.OutOfMemory;
        staging_dir_path = staged_dir;
        try stageTracedKernelUnit(allocator, options, staged_dir, diag);
        staged_root_path = std.fs.path.join(
            allocator,
            &.{ staged_dir, options.kernel_root_basename },
        ) catch return KernelResolveError.OutOfMemory;
    }

    // Compile to a process-unique temporary sibling, then rename into
    // the keyed path. A crash mid-compile leaves only a stale `.tmp-*`
    // file that can never satisfy the reuse check above.
    const temporary_object_path = std.fmt.allocPrint(
        allocator,
        "{s}.tmp-{d}",
        .{ object_path, interimPathDiscriminator() },
    ) catch return KernelResolveError.OutOfMemory;
    defer allocator.free(temporary_object_path);

    try compileKernelUnit(
        allocator,
        staged_root_path orelse root_source_path,
        temporary_object_path,
        options,
        diag,
    );
    errdefer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, temporary_object_path) catch {};

    try assertKernelObjectExports(allocator, temporary_object_path, diag);

    std.Io.Dir.cwd().rename(
        temporary_object_path,
        std.Io.Dir.cwd(),
        object_path,
        std.Options.debug_io,
    ) catch {
        diag.write(
            "concurrency kernel: could not publish compiled object to '{s}'",
            .{object_path},
        );
        return KernelResolveError.InternalError;
    };

    return .{ .object_path = object_path, .cache_key_hex = cache_key_hex };
}

/// Reject a build target that cannot host the concurrency kernel (plan
/// 7.1/7.2 — the capability-matrix compile-time check), on either axis:
///
/// * **Architecture** (plan 7.1, P7-J2): the kernel is fiber-based —
///   `FIBER_SUPPORTED_ARCHITECTURES` mirrors the fork's
///   `std.Io.fiber.supported` set, and wasm is excluded architecturally
///   (the wasm call stack is inaccessible, so no fiber substrate exists;
///   Asyncify is ruled out by decision 9 of `zap-concurrency-research.md`
///   §6; revisit when the wasm stack-switching proposal ships in major
///   runtimes).
/// * **Operating system** (plan 7.2, P7-J3): the kernel's OS-primitive
///   layer — futex parking (`futex.zig`), guard-paged lazy-commit fiber
///   stacks (`stack_pool.zig`), and the receive/after monotonic clock
///   (`scheduler.zig`) — is implemented for the Darwin family and Linux
///   only (`kernelSupportsOperatingSystem`). Windows on a fiber-capable
///   arch would otherwise pass the arch check and die inside the
///   kernel-object compile on those primitives' `@compileError`s; it is
///   rejected here with the plan 7.2a port list instead.
///
/// A `null` target validates the native host. A triple that does not
/// parse is NOT rejected here: the compile path owns the malformed-triple
/// diagnostic (`compileKernelUnit`), and this check must never mask it.
pub fn validateKernelTargetSupport(
    target_triple: ?[]const u8,
    diag: *memory_driver.DriverDiagnostic,
) KernelResolveError!void {
    var target_architecture: std.Target.Cpu.Arch = builtin.cpu.arch;
    var target_operating_system: std.Target.Os.Tag = builtin.os.tag;
    if (target_triple) |triple| {
        const parsed = memory_driver.parseTargetTriple(triple) orelse return;
        target_architecture = architectureFromForkTag(parsed.arch_tag) orelse return;
        target_operating_system = operatingSystemFromForkTag(parsed.os_tag) orelse return;
    }
    const triple_text = target_triple orelse "native";

    const architecture_is_fiber_capable = for (FIBER_SUPPORTED_ARCHITECTURES) |supported_architecture| {
        if (target_architecture == supported_architecture) break true;
    } else false;
    if (!architecture_is_fiber_capable) {
        switch (target_architecture) {
            .wasm32, .wasm64 => diag.write(
                "runtime_concurrency is not supported on {s} (target '{s}'): the concurrency " ++
                    "kernel requires stackful fibers, and the wasm call stack is architecturally " ++
                    "inaccessible — no wasm fiber substrate exists (Asyncify is ruled out; revisit " ++
                    "when the wasm stack-switching proposal ships). Build without " ++
                    "-Druntime-concurrency=on (or set `runtime_concurrency: false` in the " ++
                    "Zap.Manifest), or target a fiber-capable platform (aarch64/x86_64/riscv64).",
                .{ @tagName(target_architecture), triple_text },
            ),
            else => diag.write(
                "runtime_concurrency is not supported on {s} (target '{s}'): the concurrency " ++
                    "kernel requires stackful fiber support, which exists for " ++
                    "aarch64/x86_64/riscv64 only. Build without -Druntime-concurrency=on (or set " ++
                    "`runtime_concurrency: false` in the Zap.Manifest), or target a fiber-capable " ++
                    "architecture.",
                .{ @tagName(target_architecture), triple_text },
            ),
        }
        return KernelResolveError.KernelTargetUnsupported;
    }

    if (!kernelSupportsOperatingSystem(target_operating_system)) {
        switch (target_operating_system) {
            .windows => diag.write(
                "runtime_concurrency is not supported on windows (target '{s}'): the concurrency " ++
                    "kernel's OS-primitive layer exists for macOS/Darwin and Linux only — the " ++
                    "Windows port (plan item 7.2a) still needs futex parking " ++
                    "(WaitOnAddress/WakeByAddressSingle), a VirtualAlloc guard-paged fiber-stack " ++
                    "pool, a monotonic scheduler clock (QueryPerformanceCounter), and Win64 " ++
                    "fiber-entry ABI + TIB stack-bound maintenance. Build without " ++
                    "-Druntime-concurrency=on (or set `runtime_concurrency: false` in the " ++
                    "Zap.Manifest), or target macOS or Linux on a fiber-capable architecture.",
                .{triple_text},
            ),
            else => diag.write(
                "runtime_concurrency is not supported on {s} (target '{s}'): the concurrency " ++
                    "kernel's OS-primitive layer (futex parking, guard-paged fiber stacks, the " ++
                    "monotonic scheduler clock) is implemented for macOS/Darwin and Linux only. " ++
                    "Build without -Druntime-concurrency=on (or set `runtime_concurrency: false` " ++
                    "in the Zap.Manifest), or target macOS or Linux on a fiber-capable " ++
                    "architecture.",
                .{ @tagName(target_operating_system), triple_text },
            ),
        }
        return KernelResolveError.KernelTargetUnsupported;
    }
}

/// Whether the concurrency kernel's OS-primitive layer is implemented for
/// `operating_system` — the OS axis of the capability matrix (plan 7.2,
/// P7-J3), mirroring the kernel's own comptime OS gates: futex parking
/// (`futex.zig` — Darwin `os_sync_*`/`__ulock_*`, Linux `futex(2)`,
/// `@compileError` otherwise), the guard-paged lazy-commit stack pool
/// (`stack_pool.zig` — `posix.mmap`/`mprotect`/`madvise`), and the
/// receive/after monotonic clock (`scheduler.zig` —
/// `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` / `clock_gettime(MONOTONIC)`,
/// `@compileError` otherwise). Extending this set means porting those
/// primitives FIRST (Windows: plan item 7.2a) — the driver gate must never
/// admit an OS the kernel unit cannot compile for.
fn kernelSupportsOperatingSystem(operating_system: std.Target.Os.Tag) bool {
    return operating_system.isDarwin() or operating_system == .linux;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// Resolve a `ZapForkTarget.arch_tag` back to the `std.Target.Cpu.Arch`
/// it encodes (the inverse of `memory_driver.parseTargetTriple`'s
/// `@intFromEnum`). Null for a tag no architecture carries — the caller
/// defers such targets to the compile path's own diagnostics.
fn architectureFromForkTag(arch_tag: u16) ?std.Target.Cpu.Arch {
    return inline for (@typeInfo(std.Target.Cpu.Arch).@"enum".fields) |field| {
        if (field.value == arch_tag) break @field(std.Target.Cpu.Arch, field.name);
    } else null;
}

/// Resolve a `ZapForkTarget.os_tag` back to the `std.Target.Os.Tag` it
/// encodes — `architectureFromForkTag`'s OS counterpart, with the same
/// null-means-defer contract.
fn operatingSystemFromForkTag(os_tag: u16) ?std.Target.Os.Tag {
    return inline for (@typeInfo(std.Target.Os.Tag).@"enum".fields) |field| {
        if (field.value == os_tag) break @field(std.Target.Os.Tag, field.name);
    } else null;
}

fn requiredIdentity(
    digest: ?[32]u8,
    comptime which: []const u8,
    diag: *memory_driver.DriverDiagnostic,
) KernelResolveError![32]u8 {
    return digest orelse {
        if (builtin.is_test) return [_]u8{0} ** 32;
        diag.write(
            "concurrency kernel driver: production resolve omitted the " ++ which ++ " identity digest",
            .{},
        );
        return KernelResolveError.InternalError;
    };
}

/// Digest every `.zig` file under the kernel unit directory
/// (recursively), in sorted relative-path order, folding path and
/// content length-prefixed. An empty unit (no `.zig` files) is a
/// configuration error, not an empty digest.
fn hashKernelSources(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    options: KernelResolveOptions,
    diag: *memory_driver.DriverDiagnostic,
) KernelResolveError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var relative_paths: std.ArrayListUnmanaged([]const u8) = .empty;

    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, options.kernel_source_dir, .{ .iterate = true }) catch {
        diag.write(
            "concurrency kernel source unit not found at '{s}'",
            .{options.kernel_source_dir},
        );
        return KernelResolveError.KernelSourceNotFound;
    };
    defer dir.close(std.Options.debug_io);

    var walker = dir.walk(arena) catch return KernelResolveError.OutOfMemory;
    defer walker.deinit();
    while (walker.next(std.Options.debug_io) catch {
        diag.write(
            "concurrency kernel source unit at '{s}' could not be walked",
            .{options.kernel_source_dir},
        );
        return KernelResolveError.KernelSourceNotFound;
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const owned = arena.dupe(u8, entry.path) catch return KernelResolveError.OutOfMemory;
        relative_paths.append(arena, owned) catch return KernelResolveError.OutOfMemory;
    }

    if (relative_paths.items.len == 0) {
        diag.write(
            "concurrency kernel source unit at '{s}' contains no .zig sources",
            .{options.kernel_source_dir},
        );
        return KernelResolveError.KernelSourceNotFound;
    }

    std.mem.sort([]const u8, relative_paths.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);

    var found_root = false;
    for (relative_paths.items) |relative_path| {
        if (std.mem.eql(u8, relative_path, options.kernel_root_basename)) found_root = true;
        const contents = dir.readFileAlloc(
            std.Options.debug_io,
            relative_path,
            arena,
            .limited(64 * 1024 * 1024),
        ) catch {
            diag.write(
                "concurrency kernel source '{s}/{s}' could not be read",
                .{ options.kernel_source_dir, relative_path },
            );
            return KernelResolveError.KernelSourceNotFound;
        };
        hashLenPrefixed(hasher, relative_path);
        hashLenPrefixed(hasher, contents);
    }

    if (!found_root) {
        diag.write(
            "concurrency kernel root '{s}' not found under '{s}'",
            .{ options.kernel_root_basename, options.kernel_source_dir },
        );
        return KernelResolveError.KernelSourceNotFound;
    }
}

/// P6-J6: copy every `.zig` file of the kernel unit into `staging_dir`
/// (flat — the unit has no subdirectories; asserted), rewriting
/// `trace.zig`'s `RUNTIME_TRACE_DEFAULT` marker from `false` to `true`.
/// A missing or already-rewritten marker is a hard error: the marker is
/// the trace gate's single source of truth, and drifting silently would
/// ship a "traced" binary with no instrumentation.
fn stageTracedKernelUnit(
    allocator: std.mem.Allocator,
    options: KernelResolveOptions,
    staging_dir: []const u8,
    diag: *memory_driver.DriverDiagnostic,
) KernelResolveError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, staging_dir) catch {
        diag.write(
            "concurrency kernel tracing: could not create the staging directory '{s}'",
            .{staging_dir},
        );
        return KernelResolveError.InternalError;
    };

    var source_dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, options.kernel_source_dir, .{ .iterate = true }) catch {
        diag.write(
            "concurrency kernel source unit not found at '{s}'",
            .{options.kernel_source_dir},
        );
        return KernelResolveError.KernelSourceNotFound;
    };
    defer source_dir.close(std.Options.debug_io);

    var marker_rewritten = false;
    var walker = source_dir.walk(arena) catch return KernelResolveError.OutOfMemory;
    defer walker.deinit();
    while (walker.next(std.Options.debug_io) catch {
        diag.write(
            "concurrency kernel source unit at '{s}' could not be walked",
            .{options.kernel_source_dir},
        );
        return KernelResolveError.KernelSourceNotFound;
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // The unit is flat by construction (`abi.zig` imports siblings);
        // a nested source would silently escape the copy below.
        if (std.mem.findScalar(u8, entry.path, std.fs.path.sep) != null) {
            diag.write(
                "concurrency kernel tracing: unexpected nested source '{s}' (the staging copy assumes a flat unit)",
                .{entry.path},
            );
            return KernelResolveError.InternalError;
        }
        const contents = source_dir.readFileAlloc(
            std.Options.debug_io,
            entry.path,
            arena,
            .limited(64 * 1024 * 1024),
        ) catch {
            diag.write(
                "concurrency kernel source '{s}/{s}' could not be read",
                .{ options.kernel_source_dir, entry.path },
            );
            return KernelResolveError.KernelSourceNotFound;
        };
        var staged_contents: []const u8 = contents;
        if (std.mem.eql(u8, entry.path, TRACE_MARKER_FILE_BASENAME)) {
            const marker_index = std.mem.find(u8, contents, TRACE_MARKER_OFF) orelse {
                diag.write(
                    "concurrency kernel tracing: '{s}' is missing the marker line `{s}` — the trace-gate rewrite cannot proceed",
                    .{ TRACE_MARKER_FILE_BASENAME, TRACE_MARKER_OFF },
                );
                return KernelResolveError.KernelCompileFailed;
            };
            const rewritten = arena.alloc(u8, contents.len - TRACE_MARKER_OFF.len + TRACE_MARKER_ON.len) catch
                return KernelResolveError.OutOfMemory;
            @memcpy(rewritten[0..marker_index], contents[0..marker_index]);
            @memcpy(rewritten[marker_index..][0..TRACE_MARKER_ON.len], TRACE_MARKER_ON);
            @memcpy(
                rewritten[marker_index + TRACE_MARKER_ON.len ..],
                contents[marker_index + TRACE_MARKER_OFF.len ..],
            );
            staged_contents = rewritten;
            marker_rewritten = true;
        }
        const staged_path = std.fs.path.join(arena, &.{ staging_dir, entry.path }) catch
            return KernelResolveError.OutOfMemory;
        std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
            .sub_path = staged_path,
            .data = staged_contents,
        }) catch {
            diag.write(
                "concurrency kernel tracing: could not write staged source '{s}'",
                .{staged_path},
            );
            return KernelResolveError.InternalError;
        };
    }

    if (!marker_rewritten) {
        diag.write(
            "concurrency kernel tracing: '{s}' not found in the kernel unit — the trace-gate rewrite cannot proceed",
            .{TRACE_MARKER_FILE_BASENAME},
        );
        return KernelResolveError.KernelCompileFailed;
    }
}

fn compileKernelUnit(
    allocator: std.mem.Allocator,
    root_source_path: []const u8,
    object_path: []const u8,
    options: KernelResolveOptions,
    diag: *memory_driver.DriverDiagnostic,
) KernelResolveError!void {
    const source_z = allocator.dupeZ(u8, root_source_path) catch return KernelResolveError.OutOfMemory;
    defer allocator.free(source_z);
    const object_z = allocator.dupeZ(u8, object_path) catch return KernelResolveError.OutOfMemory;
    defer allocator.free(object_z);
    const cache_dir_z = allocator.dupeZ(u8, options.cache_dir) catch return KernelResolveError.OutOfMemory;
    defer allocator.free(cache_dir_z);
    const zig_lib_z: ?[:0]const u8 = if (options.zig_lib_dir) |p|
        (allocator.dupeZ(u8, p) catch return KernelResolveError.OutOfMemory)
    else
        null;
    defer if (zig_lib_z) |p| allocator.free(p);
    const cpu_z: ?[:0]const u8 = if (options.cpu) |c|
        (if (c.len == 0) null else (allocator.dupeZ(u8, c) catch return KernelResolveError.OutOfMemory))
    else
        null;
    defer if (cpu_z) |p| allocator.free(p);

    const target: memory_driver.ZapForkTarget = if (options.target) |triple|
        memory_driver.parseTargetTriple(triple) orelse {
            diag.write(
                "concurrency kernel could not build for cross-compile target '{s}': unrecognised triple (expected arch-os-abi)",
                .{triple},
            );
            return KernelResolveError.KernelCompileFailed;
        }
    else
        .{
            .arch_tag = memory_driver.ZAP_FORK_ARCH_NATIVE,
            .os_tag = 0,
            .abi_tag = 0,
            ._reserved = 0,
        };

    const fork_fn: memory_driver.ForkCompileFn = options.fork_compile_fn orelse
        (memory_driver.defaultForkCompileFn() orelse {
            diag.write(
                "concurrency kernel driver: no fork compile function available (test build without explicit override?)",
                .{},
            );
            return KernelResolveError.InternalError;
        });

    var fork_diag_buf: [4096]u8 = undefined;
    fork_diag_buf[0] = 0;

    const result = fork_fn(
        source_z.ptr,
        &target,
        options.optimize,
        object_z.ptr,
        &fork_diag_buf,
        fork_diag_buf.len,
        if (zig_lib_z) |p| p.ptr else null,
        cache_dir_z.ptr,
        cache_dir_z.ptr,
        if (cpu_z) |p| p.ptr else null,
        // The kernel object always links libc, matching the final
        // binary's posture — see `KERNEL_OBJECT_LINK_LIBC` (7.1a).
        KERNEL_OBJECT_LINK_LIBC,
    );

    switch (result) {
        .Ok => return,
        .SourceNotFound => {
            diag.write(
                "concurrency kernel root source not found at '{s}'",
                .{root_source_path},
            );
            return KernelResolveError.KernelSourceNotFound;
        },
        .CompilationFailed => {
            const fork_text = std.mem.sliceTo(&fork_diag_buf, 0);
            diag.write(
                "compilation of the concurrency kernel failed:\n{s}",
                .{fork_text},
            );
            return KernelResolveError.KernelCompileFailed;
        },
        .TargetUnsupported => {
            const fork_text = std.mem.sliceTo(&fork_diag_buf, 0);
            diag.write(
                "concurrency kernel target unsupported: {s}",
                .{fork_text},
            );
            return KernelResolveError.KernelCompileFailed;
        },
        .InternalError => {
            const fork_text = std.mem.sliceTo(&fork_diag_buf, 0);
            diag.write(
                "internal error compiling the concurrency kernel: {s}",
                .{fork_text},
            );
            return KernelResolveError.InternalError;
        },
    }
}

/// Assert the freshly-compiled object exports the sentinel intrinsic
/// (`KERNEL_SENTINEL_SYMBOL`), reusing the memory driver's per-format
/// symbol-table walkers. Catching a link-surface mismatch here gives a
/// build-time diagnostic naming the kernel instead of an undefined
/// `zap_proc_*` reference at the user binary's final link.
fn assertKernelObjectExports(
    allocator: std.mem.Allocator,
    object_path: []const u8,
    diag: *memory_driver.DriverDiagnostic,
) KernelResolveError!void {
    const object_bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        object_path,
        allocator,
        .limited(256 * 1024 * 1024),
    ) catch {
        diag.write("could not read compiled concurrency kernel object at '{s}'", .{object_path});
        return KernelResolveError.ObjectReadFailed;
    };
    defer allocator.free(object_bytes);

    const found = memory_driver.objectExportsSymbol(object_bytes, KERNEL_SENTINEL_SYMBOL) catch |err| {
        switch (err) {
            error.UnsupportedFormat => diag.write(
                "concurrency kernel object at '{s}' uses an unsupported format for symbol-table inspection",
                .{object_path},
            ),
            error.InvalidObject => diag.write(
                "concurrency kernel object at '{s}' has a malformed object header",
                .{object_path},
            ),
        }
        return KernelResolveError.ValidationFailed;
    };
    if (!found) {
        diag.write(
            "concurrency kernel object does not export the required intrinsic '{s}'; the compiled root must be the C-ABI bridge (src/runtime/concurrency/abi.zig)",
            .{KERNEL_SENTINEL_SYMBOL},
        );
        return KernelResolveError.ValidationFailed;
    }
}

fn pathIsReadable(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

/// Discriminator for the temporary object path: pid + a monotonic
/// counter, unique enough that two concurrent builds in one cache
/// directory never collide on the temporary name (each publishes via
/// rename, so the final path is race-free either way).
var interim_counter = std.atomic.Value(u64).init(0);

fn interimPathDiscriminator() u64 {
    const counter = interim_counter.fetchAdd(1, .monotonic);
    const pid: u64 = switch (builtin.os.tag) {
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        .wasi => 0,
        else => @intCast(std.c.getpid()),
    };
    return pid *% 0x1_0000 +% counter;
}

fn hashLenPrefixed(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    const len: u64 = bytes.len;
    hasher.update(std.mem.asBytes(&len));
    hasher.update(bytes);
}

fn digestHex(digest: [32]u8) [64]u8 {
    const alphabet = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Test fixture: a fake kernel unit in a tmp dir plus a mock fork
/// primitive that writes a minimal ELF64 object exporting the sentinel
/// intrinsic (modeled on `memory/driver.zig`'s `synthesizeElfWithCaps`,
/// minus the `.zapmem` machinery the kernel does not carry).
const TestUnit = struct {
    tmp: testing.TmpDir,
    // Sentinel-terminated on purpose: `realPathFileAlloc` returns a
    // `dupeZ` allocation, and `allocator.free` must see the sentinel in
    // the slice type to release the full buffer.
    dir_path: [:0]const u8,
    cache_path: [:0]const u8,

    fn init(allocator: std.mem.Allocator) !TestUnit {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.Options.debug_io, "kernel");
        try tmp.dir.createDirPath(std.Options.debug_io, "cache");
        try tmp.dir.writeFile(std.Options.debug_io, .{
            .sub_path = "kernel/abi.zig",
            .data = "// fake kernel root\n",
        });
        try tmp.dir.writeFile(std.Options.debug_io, .{
            .sub_path = "kernel/scheduler.zig",
            .data = "// fake sibling\n",
        });
        const dir_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "kernel", allocator);
        errdefer allocator.free(dir_path);
        const cache_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "cache", allocator);
        return .{ .tmp = tmp, .dir_path = dir_path, .cache_path = cache_path };
    }

    fn deinit(unit: *TestUnit, allocator: std.mem.Allocator) void {
        allocator.free(unit.dir_path);
        allocator.free(unit.cache_path);
        unit.tmp.cleanup();
    }

    fn options(unit: *const TestUnit, fork_fn: memory_driver.ForkCompileFn) KernelResolveOptions {
        return .{
            .kernel_source_dir = unit.dir_path,
            .cache_dir = unit.cache_path,
            .fork_compile_fn = fork_fn,
        };
    }
};

var mock_kernel_compile_count: usize = 0;
/// The libc decision the driver threaded into the most recent mock
/// kernel compile — kernel objects must always receive
/// `KERNEL_OBJECT_LINK_LIBC` (`.on`, the final binary's posture).
var mock_kernel_last_link_libc: ?memory_driver.ZapForkLinkLibc = null;

fn mockForkCompileKernel(
    source_path: [*:0]const u8,
    target: *const memory_driver.ZapForkTarget,
    optimize: memory_driver.ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
    zig_lib_dir_opt: ?[*:0]const u8,
    local_cache_dir_opt: ?[*:0]const u8,
    global_cache_dir_opt: ?[*:0]const u8,
    cpu_features_opt: ?[*:0]const u8,
    link_libc: memory_driver.ZapForkLinkLibc,
) callconv(.c) memory_driver.ZapForkResult {
    _ = source_path;
    _ = target;
    _ = optimize;
    _ = out_diagnostic_buffer;
    _ = out_diagnostic_capacity;
    _ = zig_lib_dir_opt;
    _ = local_cache_dir_opt;
    _ = global_cache_dir_opt;
    _ = cpu_features_opt;
    mock_kernel_compile_count += 1;
    mock_kernel_last_link_libc = link_libc;
    var buffer: [4096]u8 = undefined;
    const written = synthesizeKernelElf(&buffer);
    const object_path = std.mem.sliceTo(out_object_path, 0);
    std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = object_path,
        .data = buffer[0..written],
    }) catch return .InternalError;
    return .Ok;
}

fn mockForkCompileGarbage(
    source_path: [*:0]const u8,
    target: *const memory_driver.ZapForkTarget,
    optimize: memory_driver.ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
    zig_lib_dir_opt: ?[*:0]const u8,
    local_cache_dir_opt: ?[*:0]const u8,
    global_cache_dir_opt: ?[*:0]const u8,
    cpu_features_opt: ?[*:0]const u8,
    link_libc: memory_driver.ZapForkLinkLibc,
) callconv(.c) memory_driver.ZapForkResult {
    _ = source_path;
    _ = target;
    _ = optimize;
    _ = out_diagnostic_buffer;
    _ = out_diagnostic_capacity;
    _ = zig_lib_dir_opt;
    _ = local_cache_dir_opt;
    _ = global_cache_dir_opt;
    _ = cpu_features_opt;
    _ = link_libc;
    const object_path = std.mem.sliceTo(out_object_path, 0);
    std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = object_path,
        .data = "not an object file",
    }) catch return .InternalError;
    return .Ok;
}

/// Minimal ELF64 relocatable whose symtab carries exactly the sentinel
/// intrinsic. Layout mirrors the memory driver's ELF synthesizer.
fn synthesizeKernelElf(buffer: []u8) usize {
    const shstrtab = "\x00.shstrtab\x00.symtab\x00.strtab\x00";
    const symstrtab = "\x00" ++ KERNEL_SENTINEL_SYMBOL ++ "\x00";

    const ehdr_size: u64 = @sizeOf(std.elf.Elf64_Ehdr);
    const shdr_size: u64 = @sizeOf(std.elf.Elf64_Shdr);
    const sym_size: u64 = @sizeOf(std.elf.Elf64_Sym);
    const shdr_count: u16 = 4; // null, shstrtab, symtab, strtab

    const shdr_table_offset = ehdr_size;
    const shstrtab_offset = shdr_table_offset + shdr_size * @as(u64, shdr_count);
    const symtab_offset = shstrtab_offset + shstrtab.len;
    const sym_count: u64 = 2; // STN_UNDEF + the sentinel
    const symstrtab_offset = symtab_offset + sym_size * sym_count;
    const total = symstrtab_offset + symstrtab.len;

    var ehdr: std.elf.Elf64_Ehdr = .{
        .e_ident = [_]u8{0} ** 16,
        .e_type = .REL,
        .e_machine = .X86_64,
        .e_version = 1,
        .e_entry = 0,
        .e_phoff = 0,
        .e_shoff = shdr_table_offset,
        .e_flags = 0,
        .e_ehsize = @intCast(ehdr_size),
        .e_phentsize = 0,
        .e_phnum = 0,
        .e_shentsize = @intCast(shdr_size),
        .e_shnum = shdr_count,
        .e_shstrndx = 1,
    };
    ehdr.e_ident[0] = 0x7F;
    ehdr.e_ident[1] = 'E';
    ehdr.e_ident[2] = 'L';
    ehdr.e_ident[3] = 'F';
    ehdr.e_ident[std.elf.EI.CLASS] = std.elf.ELFCLASS64;
    ehdr.e_ident[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    ehdr.e_ident[std.elf.EI.VERSION] = 1;
    @memcpy(buffer[0..@sizeOf(std.elf.Elf64_Ehdr)], std.mem.asBytes(&ehdr));

    var sh_null: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    @memcpy(buffer[shdr_table_offset..][0..@sizeOf(std.elf.Elf64_Shdr)], std.mem.asBytes(&sh_null));

    var sh_shstrtab: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    sh_shstrtab.sh_name = 1; // ".shstrtab"
    sh_shstrtab.sh_type = @intFromEnum(std.elf.SHT.STRTAB);
    sh_shstrtab.sh_offset = shstrtab_offset;
    sh_shstrtab.sh_size = shstrtab.len;
    @memcpy(
        buffer[shdr_table_offset + shdr_size ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_shstrtab),
    );

    var sh_symtab: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    sh_symtab.sh_name = 11; // ".symtab"
    sh_symtab.sh_type = @intFromEnum(std.elf.SHT.SYMTAB);
    sh_symtab.sh_offset = symtab_offset;
    sh_symtab.sh_size = sym_size * sym_count;
    sh_symtab.sh_link = 3; // ".strtab" index
    sh_symtab.sh_info = 1;
    sh_symtab.sh_addralign = 8;
    sh_symtab.sh_entsize = sym_size;
    @memcpy(
        buffer[shdr_table_offset + shdr_size * 2 ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_symtab),
    );

    var sh_strtab: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    sh_strtab.sh_name = 19; // ".strtab"
    sh_strtab.sh_type = @intFromEnum(std.elf.SHT.STRTAB);
    sh_strtab.sh_offset = symstrtab_offset;
    sh_strtab.sh_size = symstrtab.len;
    @memcpy(
        buffer[shdr_table_offset + shdr_size * 3 ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_strtab),
    );

    @memcpy(buffer[shstrtab_offset..][0..shstrtab.len], shstrtab);

    var sym_null: std.elf.Elf64_Sym = std.mem.zeroes(std.elf.Elf64_Sym);
    @memcpy(buffer[symtab_offset..][0..@sizeOf(std.elf.Elf64_Sym)], std.mem.asBytes(&sym_null));

    var sym_sentinel: std.elf.Elf64_Sym = std.mem.zeroes(std.elf.Elf64_Sym);
    sym_sentinel.st_name = 1; // offset of the sentinel in strtab
    // STT_FUNC(2) | STB_GLOBAL(1) << 4 = 0x12
    sym_sentinel.st_info = (1 << 4) | 2;
    sym_sentinel.st_shndx = 1;
    @memcpy(
        buffer[symtab_offset + sym_size ..][0..@sizeOf(std.elf.Elf64_Sym)],
        std.mem.asBytes(&sym_sentinel),
    );

    @memcpy(buffer[symstrtab_offset..][0..symstrtab.len], symstrtab);

    return @intCast(total);
}

test "concurrency driver: resolve compiles once and content-addressed reuse skips the fork" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    mock_kernel_compile_count = 0;
    var first = try resolveKernelObject(allocator, unit.options(mockForkCompileKernel), &diag);
    defer freeResolvedKernel(allocator, &first);
    try testing.expectEqual(@as(usize, 1), mock_kernel_compile_count);

    var second = try resolveKernelObject(allocator, unit.options(mockForkCompileKernel), &diag);
    defer freeResolvedKernel(allocator, &second);
    // Cache hit: the fork primitive is NOT re-invoked and the paths agree.
    try testing.expectEqual(@as(usize, 1), mock_kernel_compile_count);
    try testing.expectEqualStrings(first.object_path, second.object_path);
    try testing.expectEqualSlices(u8, &first.cache_key_hex, &second.cache_key_hex);
}

test "concurrency driver: kernel objects compile with link_libc=on, matching the final binary's posture" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    mock_kernel_compile_count = 0;
    mock_kernel_last_link_libc = null;
    var resolved = try resolveKernelObject(allocator, unit.options(mockForkCompileKernel), &diag);
    defer freeResolvedKernel(allocator, &resolved);

    // 7.1a: the kernel deliberately reads `std.c.getenv` /
    // `std.c.clock_gettime` and the final binary always links libc, so
    // the kernel-object compile must pin `link_libc = true` instead of
    // inheriting the fork's internal per-target default (which would be
    // `false` on Linux and fail the gate-ON x86_64-linux-gnu compile).
    try testing.expectEqual(@as(usize, 1), mock_kernel_compile_count);
    try testing.expectEqual(
        @as(?memory_driver.ZapForkLinkLibc, KERNEL_OBJECT_LINK_LIBC),
        mock_kernel_last_link_libc,
    );
    try testing.expectEqual(memory_driver.ZapForkLinkLibc.on, KERNEL_OBJECT_LINK_LIBC);
}

test "concurrency driver: editing any kernel source changes the cache key and recompiles" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    mock_kernel_compile_count = 0;
    var first = try resolveKernelObject(allocator, unit.options(mockForkCompileKernel), &diag);
    defer freeResolvedKernel(allocator, &first);

    // Edit a NON-ROOT sibling: the whole unit participates in the key.
    try unit.tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "kernel/scheduler.zig",
        .data = "// fake sibling, edited\n",
    });

    var second = try resolveKernelObject(allocator, unit.options(mockForkCompileKernel), &diag);
    defer freeResolvedKernel(allocator, &second);
    try testing.expectEqual(@as(usize, 2), mock_kernel_compile_count);
    try testing.expect(!std.mem.eql(u8, &first.cache_key_hex, &second.cache_key_hex));
    try testing.expect(!std.mem.eql(u8, first.object_path, second.object_path));
}

test "concurrency driver: cache key separates optimize, target, and cpu" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    var base_options = unit.options(mockForkCompileKernel);
    const base_key = try kernelCacheKeyHex(allocator, base_options, &diag);

    base_options.optimize = .ReleaseFast;
    const optimize_key = try kernelCacheKeyHex(allocator, base_options, &diag);
    try testing.expect(!std.mem.eql(u8, &base_key, &optimize_key));

    base_options.optimize = .ReleaseSafe;
    base_options.target = "aarch64-linux-gnu";
    const target_key = try kernelCacheKeyHex(allocator, base_options, &diag);
    try testing.expect(!std.mem.eql(u8, &base_key, &target_key));

    base_options.target = null;
    base_options.cpu = "baseline";
    const cpu_key = try kernelCacheKeyHex(allocator, base_options, &diag);
    try testing.expect(!std.mem.eql(u8, &base_key, &cpu_key));
}

test "concurrency driver: gate-ON wasm32 target fails early with one actionable diagnostic" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    mock_kernel_compile_count = 0;
    var options = unit.options(mockForkCompileKernel);
    options.target = "wasm32-wasi";

    try testing.expectError(
        KernelResolveError.KernelTargetUnsupported,
        resolveKernelObject(allocator, options, &diag),
    );
    // The rejection happens BEFORE any kernel work: the fork primitive is
    // never invoked, so no screen of fiber/atomic stdlib compile errors.
    try testing.expectEqual(@as(usize, 0), mock_kernel_compile_count);
    // The diagnostic is the actionable capability message.
    try testing.expect(std.mem.indexOf(u8, diag.text(), "runtime_concurrency is not supported on wasm32") != null);
    try testing.expect(std.mem.indexOf(u8, diag.text(), "wasm call stack") != null);
    try testing.expect(std.mem.indexOf(u8, diag.text(), "-Druntime-concurrency") != null);
}

test "concurrency driver: the wasm rejection covers the cache-key path and explicit-abi triples" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    var options = unit.options(mockForkCompileKernel);
    options.target = "wasm32-wasi-musl";

    // `kernelCacheKeyHex` is the FIRST driver entry point every build path
    // hits (the manifest compile tail, script-mode key computation, and
    // `resolveKernelObject` itself), so the capability check must fire there.
    try testing.expectError(
        KernelResolveError.KernelTargetUnsupported,
        kernelCacheKeyHex(allocator, options, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.text(), "runtime_concurrency is not supported on wasm32") != null);
}

test "concurrency driver: a fiber-incapable non-wasm architecture is rejected with the fiber diagnostic" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    mock_kernel_compile_count = 0;
    var options = unit.options(mockForkCompileKernel);
    options.target = "arm-linux-gnueabihf";

    try testing.expectError(
        KernelResolveError.KernelTargetUnsupported,
        resolveKernelObject(allocator, options, &diag),
    );
    try testing.expectEqual(@as(usize, 0), mock_kernel_compile_count);
    try testing.expect(std.mem.indexOf(u8, diag.text(), "runtime_concurrency is not supported on arm") != null);
    try testing.expect(std.mem.indexOf(u8, diag.text(), "aarch64/x86_64/riscv64") != null);
}

test "concurrency driver: fiber-capable cross targets pass the capability check" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    var options = unit.options(mockForkCompileKernel);
    const fiber_capable_triples = [_][]const u8{
        "x86_64-linux-gnu",
        "aarch64-macos",
        "riscv64-linux-gnu",
    };
    for (fiber_capable_triples) |triple| {
        options.target = triple;
        // Key computation succeeds: the capability check lets the build
        // proceed to the kernel compile for every fiber-capable target.
        _ = try kernelCacheKeyHex(allocator, options, &diag);
    }
}

test "concurrency driver: gate-ON windows target fails early with the OS port-list diagnostic" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    mock_kernel_compile_count = 0;
    var options = unit.options(mockForkCompileKernel);
    options.target = "x86_64-windows-gnu";

    try testing.expectError(
        KernelResolveError.KernelTargetUnsupported,
        resolveKernelObject(allocator, options, &diag),
    );
    // The rejection happens BEFORE any kernel work: the fork primitive is
    // never invoked, so none of the futex/clock/mmap compile errors from
    // inside the kernel-object compile ever surface (x86_64 passes the
    // ARCH check — the OS gate is what must fire here).
    try testing.expectEqual(@as(usize, 0), mock_kernel_compile_count);
    // The diagnostic is actionable AND names the missing Windows
    // primitives — the plan 7.2a port list.
    try testing.expect(std.mem.indexOf(u8, diag.text(), "runtime_concurrency is not supported on windows") != null);
    try testing.expect(std.mem.indexOf(u8, diag.text(), "WaitOnAddress") != null);
    try testing.expect(std.mem.indexOf(u8, diag.text(), "VirtualAlloc") != null);
    try testing.expect(std.mem.indexOf(u8, diag.text(), "-Druntime-concurrency") != null);
}

test "concurrency driver: the windows rejection covers the cache-key path and the bare arch-os triple" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    var options = unit.options(mockForkCompileKernel);
    // A bare `arch-os` triple resolves its default ABI (`gnu` for windows,
    // mirroring the build's own triple resolution) and must be rejected on
    // `kernelCacheKeyHex` — the FIRST driver entry point every build path
    // hits — exactly like the wasm rejection.
    options.target = "x86_64-windows";

    try testing.expectError(
        KernelResolveError.KernelTargetUnsupported,
        kernelCacheKeyHex(allocator, options, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.text(), "runtime_concurrency is not supported on windows") != null);
}

test "concurrency driver: a fiber-capable architecture on an unsupported OS is rejected with the OS diagnostic" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    mock_kernel_compile_count = 0;
    var options = unit.options(mockForkCompileKernel);
    // x86_64 passes the arch check; freebsd has no kernel OS-primitive
    // layer (futex parking, guard-paged stacks, the scheduler clock), so
    // the generic OS rejection must fire with the supported-OS listing.
    options.target = "x86_64-freebsd-none";

    try testing.expectError(
        KernelResolveError.KernelTargetUnsupported,
        resolveKernelObject(allocator, options, &diag),
    );
    try testing.expectEqual(@as(usize, 0), mock_kernel_compile_count);
    try testing.expect(std.mem.indexOf(u8, diag.text(), "runtime_concurrency is not supported on freebsd") != null);
    try testing.expect(std.mem.indexOf(u8, diag.text(), "macOS/Darwin and Linux") != null);
}

test "concurrency driver: a malformed triple defers to the compile-path diagnostic" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    var options = unit.options(mockForkCompileKernel);
    options.target = "bogus-not-a-target";

    // The capability check must never mask the existing malformed-triple
    // diagnostic owned by the compile path.
    try testing.expectError(
        KernelResolveError.KernelCompileFailed,
        resolveKernelObject(allocator, options, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.text(), "unrecognised triple") != null);
}

test "concurrency driver: object missing the sentinel intrinsic fails validation" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    try testing.expectError(
        KernelResolveError.ValidationFailed,
        resolveKernelObject(allocator, unit.options(mockForkCompileGarbage), &diag),
    );
    try testing.expect(diag.text().len > 0);
}

test "concurrency driver: missing kernel unit fails with a named diagnostic" {
    const allocator = testing.allocator;
    var unit = try TestUnit.init(allocator);
    defer unit.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: memory_driver.DriverDiagnostic = .{ .buffer = &diag_buf };

    var options = unit.options(mockForkCompileKernel);
    options.kernel_source_dir = "/nonexistent/zap/kernel/unit";
    try testing.expectError(
        KernelResolveError.KernelSourceNotFound,
        resolveKernelObject(allocator, options, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.text(), "/nonexistent/zap/kernel/unit") != null);
}
