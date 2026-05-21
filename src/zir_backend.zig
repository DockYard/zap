//! ZIR Backend — calls the Zig compiler library to produce binaries from ZIR.
//!
//! This struct provides extern declarations for the C-ABI functions exported
//! by libzig_compiler.a (built from the forked Zig at ~/projects/zig), and a
//! high-level `compile` function that wires up the full pipeline:
//!   ir.Program → ZirDriver (C-ABI calls) → inject → Zig compiler → binary
//!
//! The library must be linked at build time with `-Denable-zir-backend=true`.

const std = @import("std");
const zir_builder = @import("zir_builder.zig");
const ZirContext = zir_builder.ZirContext;
const ir = @import("ir.zig");
const env = @import("env.zig");
const progress_mod = @import("progress.zig");
const zap_symbol_table = @import("zap_symbol_table.zig");

// ---------------------------------------------------------------------------
// Extern declarations for the C-ABI functions in libzig_compiler.a
// ---------------------------------------------------------------------------

extern "c" fn zir_compilation_create(
    zig_lib_dir: [*:0]const u8,
    local_cache_dir: [*:0]const u8,
    global_cache_dir: [*:0]const u8,
    output_path: [*:0]const u8,
    root_name: [*:0]const u8,
    output_mode: u8,
    optimize_mode: u8,
    is_dynamic: bool,
    link_libc: bool,
) ?*ZirContext;

extern "c" fn zir_compilation_create_incremental(
    zig_lib_dir: [*:0]const u8,
    local_cache_dir: [*:0]const u8,
    global_cache_dir: [*:0]const u8,
    output_path: [*:0]const u8,
    root_name: [*:0]const u8,
    output_mode: u8,
    optimize_mode: u8,
    is_dynamic: bool,
    link_libc: bool,
) ?*ZirContext;

extern "c" fn zir_compilation_create_cross(
    zig_lib_dir: [*:0]const u8,
    local_cache_dir: [*:0]const u8,
    global_cache_dir: [*:0]const u8,
    output_path: [*:0]const u8,
    root_name: [*:0]const u8,
    output_mode: u8,
    optimize_mode: u8,
    is_dynamic: bool,
    link_libc: bool,
    target_triple: ?[*:0]const u8,
    cpu_features: ?[*:0]const u8,
) ?*ZirContext;

extern "c" fn zir_compilation_create_cross_incremental(
    zig_lib_dir: [*:0]const u8,
    local_cache_dir: [*:0]const u8,
    global_cache_dir: [*:0]const u8,
    output_path: [*:0]const u8,
    root_name: [*:0]const u8,
    output_mode: u8,
    optimize_mode: u8,
    is_dynamic: bool,
    link_libc: bool,
    target_triple: ?[*:0]const u8,
    cpu_features: ?[*:0]const u8,
) ?*ZirContext;

// Phase 0 — DWARF foundation: V2 of every `create_*` ABI. Identical
// shape to the V1 calls plus a trailing `debug_info_policy: u8` (see
// `DebugInfoPolicy` below). Callers either use V1 (historical
// behavior) or V2 (explicit policy); the two are equivalent when
// `debug_info_policy == 0` (default).
extern "c" fn zir_compilation_create_v2(
    zig_lib_dir: [*:0]const u8,
    local_cache_dir: [*:0]const u8,
    global_cache_dir: [*:0]const u8,
    output_path: [*:0]const u8,
    root_name: [*:0]const u8,
    output_mode: u8,
    optimize_mode: u8,
    is_dynamic: bool,
    link_libc: bool,
    debug_info_policy: u8,
) ?*ZirContext;

extern "c" fn zir_compilation_create_incremental_v2(
    zig_lib_dir: [*:0]const u8,
    local_cache_dir: [*:0]const u8,
    global_cache_dir: [*:0]const u8,
    output_path: [*:0]const u8,
    root_name: [*:0]const u8,
    output_mode: u8,
    optimize_mode: u8,
    is_dynamic: bool,
    link_libc: bool,
    debug_info_policy: u8,
) ?*ZirContext;

extern "c" fn zir_compilation_create_cross_v2(
    zig_lib_dir: [*:0]const u8,
    local_cache_dir: [*:0]const u8,
    global_cache_dir: [*:0]const u8,
    output_path: [*:0]const u8,
    root_name: [*:0]const u8,
    output_mode: u8,
    optimize_mode: u8,
    is_dynamic: bool,
    link_libc: bool,
    target_triple: ?[*:0]const u8,
    cpu_features: ?[*:0]const u8,
    debug_info_policy: u8,
) ?*ZirContext;

extern "c" fn zir_compilation_create_cross_incremental_v2(
    zig_lib_dir: [*:0]const u8,
    local_cache_dir: [*:0]const u8,
    global_cache_dir: [*:0]const u8,
    output_path: [*:0]const u8,
    root_name: [*:0]const u8,
    output_mode: u8,
    optimize_mode: u8,
    is_dynamic: bool,
    link_libc: bool,
    target_triple: ?[*:0]const u8,
    cpu_features: ?[*:0]const u8,
    debug_info_policy: u8,
) ?*ZirContext;

extern "c" fn zir_compilation_update(ctx: *ZirContext) i32;
extern "c" fn zir_compilation_update_with_progress(ctx: *ZirContext) i32;
extern "c" fn zir_compilation_output_path_len(ctx: *ZirContext) usize;
extern "c" fn zir_compilation_copy_output_path(ctx: *ZirContext, out: ?[*]u8, out_len: usize) usize;

extern "c" fn zir_compilation_destroy(ctx: *ZirContext) void;

extern "c" fn zir_compilation_add_struct_source(
    ctx: *ZirContext,
    name: [*:0]const u8,
    source_ptr: [*]const u8,
    source_len: u32,
) i32;

extern "c" fn zir_compilation_add_struct(
    ctx: *ZirContext,
    name: [*:0]const u8,
    source_path: [*:0]const u8,
) i32;

extern "c" fn zir_compilation_print_errors(ctx: *ZirContext) void;

extern "c" fn zir_compilation_set_builder_entry(
    ctx: *ZirContext,
    entry_name: [*:0]const u8,
) i32;

extern "c" fn zir_compilation_prepare_update(ctx: *ZirContext) i32;
extern "c" fn zir_compilation_prepare_update_selected(
    ctx: *ZirContext,
    names: [*]const [*]const u8,
    name_lens: [*]const usize,
    count: usize,
    include_root: bool,
) i32;
extern "c" fn zir_compilation_abort_update(ctx: *ZirContext) i32;

extern "c" fn zir_compilation_invalidate_file(ctx: *ZirContext, name: [*:0]const u8) i32;
extern "c" fn zir_compilation_invalidate_root(ctx: *ZirContext) i32;

extern "c" fn zir_compilation_add_link_lib(ctx: *ZirContext, name: [*:0]const u8) i32;

extern "c" fn zir_compilation_add_link_object_file(ctx: *ZirContext, path: [*:0]const u8) i32;

// ---------------------------------------------------------------------------
// High-level API
// ---------------------------------------------------------------------------

pub const CompileError = error{
    ZirCreateFailed,
    BeginFuncFailed,
    EndFuncFailed,
    EmitFailed,
    InvalidMainReturnType,
    UnknownLocal,
    CompilationCreateFailed,
    ZirInjectionFailed,
    CompilationFailed,
    /// The Zig fork's `zir_compilation_add_link_object_file` could not
    /// open the object file (or its parent directory) the Memory
    /// Manager ABI v1.0 driver produced. Distinguished from
    /// `CompilationFailed` so the caller surfaces a specific
    /// "object not readable" diagnostic instead of a generic compile
    /// failure. See `zir_compilation_add_link_object_file` in
    /// `~/projects/zig/src/zir_api.zig` for the `-2` return code that
    /// maps to this error.
    LinkObjectFileNotReadable,
    OutOfMemory,
    /// Phase 0 — DWARF foundation: the symbol-table builder hit a
    /// duplicate mangled name across two emitted functions. Bubbles
    /// up through `injectAndUpdate` so the caller can surface a
    /// build-fatal diagnostic instead of writing a non-reversible
    /// sidecar.
    DuplicateMangledName,
};

pub const CompileOptions = struct {
    /// Path to Zig's lib directory (contains std/).
    zig_lib_dir: []const u8,
    /// Local cache directory for compilation artifacts.
    cache_dir: []const u8,
    /// Global cache directory.
    global_cache_dir: []const u8,
    /// Path where the output binary should be written.
    output_path: []const u8,
    /// Name of the compilation unit (e.g., the program name).
    name: []const u8,
    /// Optional embedded runtime source. If provided, registered via
    /// zir_compilation_add_struct_source instead of file path.
    runtime_source: ?[]const u8 = null,
    /// Output mode: 0=Exe, 1=Lib, 2=Obj.
    output_mode: u8 = 0,
    /// Optimize mode: 0=Debug, 1=ReleaseSafe, 2=ReleaseFast, 3=ReleaseSmall.
    optimize_mode: u8 = 0,
    /// Zig 0.16 error formatting: "short" or "long" (controls --error-style).
    error_style: ?[]const u8 = null,
    /// Zig 0.16: enable verbose multi-line error output (--multiline-errors).
    multiline_errors: bool = false,
    /// For Lib output: true=dynamic (.so/.dylib), false=static (.a).
    is_dynamic: bool = false,
    /// Whether to link libc.
    link_libc: bool = true,
    /// Builder mode: compile as a builder binary with a custom entry point.
    /// The entry point function name (mangled, e.g., "FooBar__Builder__manifest").
    builder_entry: ?[]const u8 = null,
    /// Create a persistent Zig incremental compilation. Output artifacts are
    /// emitted into Zig's cache artifact directory, then copied to
    /// `output_path` after a successful update.
    incremental: bool = false,
    /// Cross-compilation target triple (e.g., "wasm32-wasi", "aarch64-linux-gnu").
    /// null means native target.
    target: ?[]const u8 = null,
    /// Optional CPU model/feature set (mirrors `zig build`'s `-Dcpu=`,
    /// e.g. "baseline", "apple_m1", "x86_64_v3"). null/"" means the
    /// target's default CPU. Threaded into `zir_compilation_create_cross`
    /// so the user binary is built for the same machine as the manager
    /// `.o`. Native compilation with a non-null cpu still takes the
    /// cross path (the triple is "native" but the CPU is explicit).
    cpu: ?[]const u8 = null,
    /// Analysis results from the escape/region/ARC pipeline.
    analysis_context: ?*const @import("escape_lattice.zig").AnalysisContext = null,
    /// Per-function ARC ownership tables produced by Phase 4 of the
    /// k-nucleotide RSS gap implementation plan. The ZIR backend
    /// reads each function's `return_source_locals` so it can mark
    /// those locals in `arc_returned_locals` when lowering the
    /// matching `share_value`/`ret` pair, suppressing the function's
    /// scope-exit release on the returned local.
    arc_ownership: ?*const @import("arc_liveness.zig").ProgramArcOwnership = null,
    /// Memory Manager ABI v1.0 capability bitmask declared by the
    /// active manager (`docs/memory-manager-abi.md` section 7). Read
    /// by the driver from the manager's `.zapmem` core vtable, threaded
    /// here so downstream codegen passes can branch on capability bits
    /// when deciding what runtime calls to emit (Phase 6 elision) and
    /// what per-cell layout to use (Phase 4 conditional headers).
    /// Phase 3 wires the bit through end-to-end without branching on
    /// it; later phases are purely additive on top. `0` means "no
    /// capabilities" (e.g. `Memory.NoOp`); `1` (`REFCOUNT_V1_BIT`)
    /// means the manager supports the ARC retain/release contract.
    declared_caps: u64 = 0,
    /// Absolute path to the selected manager's Zig backend source.
    /// Registered as the `zap_active_manager` sibling module in every
    /// user-binary build. The memory driver validates the same source
    /// through the `.zapmem` object pipeline before it reaches here.
    active_manager_source_path: []const u8,
    /// Shared CLI progress reporter, owned by the command driver.
    progress: ?*progress_mod.Reporter = null,
    /// Phase 0 — DWARF foundation: when true (the default), the ZIR
    /// backend writes the reversible mangled-symbol ↔ Zap-symbol
    /// side table to `<output_path>.zap-symbols` on a successful
    /// compile. Disabled automatically for lib/obj outputs (those
    /// link as static archives or object files and have no symbol
    /// resolver to drive). Phase-2's crash printer locates the
    /// sidecar by deriving the same `<artifact>.zap-symbols` path
    /// from the executable path at startup, so the convention is
    /// load-bearing — do not change it without updating the
    /// runtime-side loader.
    emit_symbol_table_sidecar: bool = true,
    /// Phase 0 — DWARF foundation: the per-mode debug-info policy
    /// resolved from the optimize mode plus any CLI override. See
    /// `DebugInfoPolicy` for the value semantics. `null` falls
    /// back to the legacy V1 ABI (Debug keeps DWARF, every other
    /// mode strips) which preserves source-mode behavior for
    /// callers that haven't migrated.
    debug_info_policy: ?DebugInfoPolicy = null,
};

/// Per-mode debug-info policy. Mirrors the fork's `DebugInfoPolicy`
/// in `~/projects/zig/src/zir_api.zig` byte-for-byte — the raw `u8`
/// encoding is the C-ABI contract. Resolution rules (driven by
/// Phase 0 of the error-system roadmap, `docs/error-system-research-brief.md`
/// §VIII):
///
/// * **Debug / ReleaseSafe** -> `.full`. Full DWARF; lldb / addr2line
///   / the panic handler can resolve every machine address back to
///   the Zap source line that produced it.
/// * **ReleaseFast / ReleaseSmall** -> `.none`. The main binary
///   ships stripped; the matching DWARF lives in a sibling
///   split-debug artifact (`.dSYM` on Mach-O, `.dwo` /
///   `debuginfod`-keyed elsewhere) produced from a parallel build.
/// * **`-Ddebug-info=<full|split|none>`** explicit CLI override —
///   the user can force any policy regardless of optimize mode.
///   `split` is semantically equivalent to `none` for this enum
///   (the split-debug artifact is produced from a sibling
///   invocation, not by this knob); the distinction matters for
///   the build-time choice "ship debug-info? where?", not the
///   per-`zir_compilation_create_v2` decision "embed DWARF in
///   THIS binary?".
pub const DebugInfoPolicy = enum(u8) {
    default = 0,
    full = 1,
    none = 2,

    /// The default policy for a given optimize mode when the user
    /// has not passed an explicit `-Ddebug-info` override. Encodes
    /// the per-mode policy table from the Phase 0 spec.
    pub fn fromOptimizeMode(optimize_mode: u8) DebugInfoPolicy {
        return switch (optimize_mode) {
            // 0 = Debug, 1 = ReleaseSafe — both keep full DWARF.
            0, 1 => .full,
            // 2 = ReleaseFast, 3 = ReleaseSmall — strip; split-debug
            // is shipped separately, not embedded.
            2, 3 => .none,
            else => .default,
        };
    }
};

/// Create a ZirContext compilation context from the given options.
///
/// This is the first phase of compilation: it creates the Zig compilation
/// context, configures builder mode and runtime source, but does NOT inject
/// ZIR or run the update. The returned context can be reused across multiple
/// incremental updates by calling `injectAndUpdate` repeatedly.
///
/// The caller owns the returned context and must call `destroyContext` when done.
pub fn createContext(allocator: std.mem.Allocator, options: CompileOptions) CompileError!*ZirContext {
    const zig_lib_z = allocator.dupeZ(u8, options.zig_lib_dir) catch return error.OutOfMemory;
    defer allocator.free(zig_lib_z);
    const cache_z = allocator.dupeZ(u8, options.cache_dir) catch return error.OutOfMemory;
    defer allocator.free(cache_z);
    const global_cache_z = allocator.dupeZ(u8, options.global_cache_dir) catch return error.OutOfMemory;
    defer allocator.free(global_cache_z);
    const output_z = allocator.dupeZ(u8, options.output_path) catch return error.OutOfMemory;
    defer allocator.free(output_z);
    const name_z = allocator.dupeZ(u8, options.name) catch return error.OutOfMemory;
    defer allocator.free(name_z);

    // The cross path is taken when EITHER an explicit target triple OR
    // an explicit CPU is requested. A `-Dcpu=` with no `-Dtarget=`
    // still needs the cross primitive (triple = "native", CPU
    // explicit) so the CPU actually reaches `std.Target.Query`. With
    // neither, the plain native path is used unchanged.
    const ctx = if (options.target != null or options.cpu != null) blk: {
        const target_z: ?[:0]const u8 = if (options.target) |t|
            (allocator.dupeZ(u8, t) catch return error.OutOfMemory)
        else
            null;
        defer if (target_z) |t| allocator.free(t);
        const cpu_z: ?[:0]const u8 = if (options.cpu) |c|
            (allocator.dupeZ(u8, c) catch return error.OutOfMemory)
        else
            null;
        defer if (cpu_z) |c| allocator.free(c);
        // Phase 0 — DWARF foundation: when the caller requested an
        // explicit debug-info policy (`Debug`/`ReleaseSafe` -> `full`,
        // `ReleaseFast`/`ReleaseSmall` -> `none`, or a CLI override),
        // route through the V2 ABI which threads the policy into the
        // fork's `Compilation.Config.root_strip`. Callers that left
        // `debug_info_policy = null` keep the V1 ABI (Debug keeps
        // DWARF, every other mode strips) for byte-identical
        // backwards-compatibility.
        const dbg_policy_byte: u8 = @intFromEnum(options.debug_info_policy orelse DebugInfoPolicy.default);
        const has_explicit_policy = options.debug_info_policy != null;
        break :blk (if (options.incremental and has_explicit_policy)
            zir_compilation_create_cross_incremental_v2(
                zig_lib_z,
                cache_z,
                global_cache_z,
                output_z,
                name_z,
                options.output_mode,
                options.optimize_mode,
                options.is_dynamic,
                options.link_libc,
                if (target_z) |t| t.ptr else null,
                if (cpu_z) |c| c.ptr else null,
                dbg_policy_byte,
            )
        else if (options.incremental)
            zir_compilation_create_cross_incremental(
                zig_lib_z,
                cache_z,
                global_cache_z,
                output_z,
                name_z,
                options.output_mode,
                options.optimize_mode,
                options.is_dynamic,
                options.link_libc,
                if (target_z) |t| t.ptr else null,
                if (cpu_z) |c| c.ptr else null,
            )
        else if (has_explicit_policy)
            zir_compilation_create_cross_v2(
                zig_lib_z,
                cache_z,
                global_cache_z,
                output_z,
                name_z,
                options.output_mode,
                options.optimize_mode,
                options.is_dynamic,
                options.link_libc,
                if (target_z) |t| t.ptr else null,
                if (cpu_z) |c| c.ptr else null,
                dbg_policy_byte,
            )
        else
            zir_compilation_create_cross(
                zig_lib_z,
                cache_z,
                global_cache_z,
                output_z,
                name_z,
                options.output_mode,
                options.optimize_mode,
                options.is_dynamic,
                options.link_libc,
                if (target_z) |t| t.ptr else null,
                if (cpu_z) |c| c.ptr else null,
            )) orelse
            return error.CompilationCreateFailed;
    } else native_path: {
        const dbg_policy_byte: u8 = @intFromEnum(options.debug_info_policy orelse DebugInfoPolicy.default);
        const has_explicit_policy = options.debug_info_policy != null;
        break :native_path (if (options.incremental and has_explicit_policy)
            zir_compilation_create_incremental_v2(zig_lib_z, cache_z, global_cache_z, output_z, name_z, options.output_mode, options.optimize_mode, options.is_dynamic, options.link_libc, dbg_policy_byte)
        else if (options.incremental)
            zir_compilation_create_incremental(zig_lib_z, cache_z, global_cache_z, output_z, name_z, options.output_mode, options.optimize_mode, options.is_dynamic, options.link_libc)
        else if (has_explicit_policy)
            zir_compilation_create_v2(zig_lib_z, cache_z, global_cache_z, output_z, name_z, options.output_mode, options.optimize_mode, options.is_dynamic, options.link_libc, dbg_policy_byte)
        else
            zir_compilation_create(zig_lib_z, cache_z, global_cache_z, output_z, name_z, options.output_mode, options.optimize_mode, options.is_dynamic, options.link_libc)) orelse
            return error.CompilationCreateFailed;
    };

    // Configure builder mode if entry point is specified.
    if (options.builder_entry) |entry| {
        const entry_z = allocator.dupeZ(u8, entry) catch return error.OutOfMemory;
        defer allocator.free(entry_z);
        if (zir_compilation_set_builder_entry(ctx, entry_z) != 0) {
            zir_compilation_destroy(ctx);
            return error.CompilationFailed;
        }
    }

    // Register embedded runtime source if provided.
    if (options.runtime_source) |source| {
        if (zir_compilation_add_struct_source(ctx, "zap_runtime", source.ptr, @intCast(source.len)) != 0) {
            zir_compilation_destroy(ctx);
            return error.CompilationFailed;
        }
    }

    // Register the selected adapter's backend source as the
    // `zap_active_manager` sibling module so the runtime's top-level
    // `@import("zap_active_manager")` resolves under every user-binary
    // build. The backend source path has already been resolved and validated by
    // `src/memory/driver.zig` through the same pipeline for stdlib,
    // project, and dependency managers. A silent skip on an empty path
    // would mask a regression as a far-removed "module not found" Sema
    // error at every user-binary build.
    const active_manager_path_z = allocator.dupeZ(u8, options.active_manager_source_path) catch return error.OutOfMemory;
    defer allocator.free(active_manager_path_z);
    if (zir_compilation_add_struct(ctx, "zap_active_manager", active_manager_path_z) != 0) {
        zir_compilation_destroy(ctx);
        return error.CompilationFailed;
    }

    return ctx;
}

/// Inject ZIR from a Zap IR program into the context and run the Zig
/// compilation update (Sema + codegen + link).
///
/// This is the second phase of compilation. For a fresh build, call after
/// `createContext`. For an incremental rebuild, call `prepareUpdate` first
/// to save the old ZIR, then call this to inject new ZIR and update.
fn outputArtifactPath(allocator: std.mem.Allocator, ctx: *ZirContext) CompileError![:0]u8 {
    const path_len = zir_compilation_output_path_len(ctx);
    if (path_len == 0) return error.EmitFailed;

    const path = allocator.allocSentinel(u8, path_len, 0) catch return error.OutOfMemory;
    errdefer allocator.free(path);

    const written_len = zir_compilation_copy_output_path(ctx, path.ptr, path.len + 1);
    if (written_len != path_len) return error.EmitFailed;
    return path;
}

fn publishIncrementalOutput(allocator: std.mem.Allocator, ctx: *ZirContext, output_path: []const u8) CompileError!void {
    const artifact_path = try outputArtifactPath(allocator, ctx);
    defer allocator.free(artifact_path);

    if (std.mem.eql(u8, artifact_path, output_path)) return;

    const artifact_path_absolute = std.fs.path.isAbsolute(artifact_path);
    const output_path_absolute = std.fs.path.isAbsolute(output_path);
    if (artifact_path_absolute or output_path_absolute) {
        const copy_source_path = if (artifact_path_absolute)
            artifact_path
        else
            std.fs.path.resolve(allocator, &.{artifact_path}) catch return error.EmitFailed;
        defer if (!artifact_path_absolute) allocator.free(copy_source_path);

        const copy_output_path = if (output_path_absolute)
            output_path
        else
            std.fs.path.resolve(allocator, &.{output_path}) catch return error.EmitFailed;
        defer if (!output_path_absolute) allocator.free(copy_output_path);

        std.Io.Dir.copyFileAbsolute(
            copy_source_path,
            copy_output_path,
            std.Options.debug_io,
            .{ .make_path = true, .replace = true },
        ) catch return error.EmitFailed;
        return;
    }

    std.Io.Dir.cwd().copyFile(
        artifact_path,
        std.Io.Dir.cwd(),
        output_path,
        std.Options.debug_io,
        .{ .make_path = true, .replace = true },
    ) catch return error.EmitFailed;
}

pub fn injectAndUpdate(allocator: std.mem.Allocator, program: ir.Program, ctx: *ZirContext, options: CompileOptions) CompileError!void {
    // Build ZIR via C-ABI calls and inject into compilation.
    const lib_mode = options.output_mode == 1;
    const want_sidecar = options.emit_symbol_table_sidecar and options.output_mode == 0 and options.output_path.len > 0;
    var symbol_table_bytes: ?[]u8 = null;
    defer if (symbol_table_bytes) |bytes| allocator.free(bytes);
    const out_sym_ptr: ?*?[]u8 = if (want_sidecar) &symbol_table_bytes else null;
    try zir_builder.buildAndInject(
        allocator,
        program,
        ctx,
        null,
        lib_mode,
        options.builder_entry,
        options.analysis_context,
        options.arc_ownership,
        options.declared_caps,
        options.progress,
        out_sym_ptr,
    );

    // Run Sema + codegen + link.
    const update_result = if (options.progress) |progress| blk: {
        progress.event("Zig: semantic analysis, codegen, link\n", .{});
        progress.handoffExternalOutput(.clear);
        break :blk zir_compilation_update_with_progress(ctx);
    } else zir_compilation_update(ctx);
    if (update_result != 0) {
        if (options.progress) |progress| progress.handoffExternalOutput(.clear);
        zir_compilation_print_errors(ctx);
        return error.CompilationFailed;
    }

    if (options.incremental) {
        try publishIncrementalOutput(allocator, ctx, options.output_path);
    }

    if (want_sidecar) {
        if (symbol_table_bytes) |bytes| {
            const sidecar_path = try std.fmt.allocPrint(allocator, "{s}.zap-symbols", .{options.output_path});
            defer allocator.free(sidecar_path);
            writeSymbolTableSidecar(sidecar_path, bytes) catch |err| {
                std.debug.print(
                    "Warning: failed to write zap symbol-table sidecar at {s}: {s}\n",
                    .{ sidecar_path, @errorName(err) },
                );
            };
        }
    }
}

/// Write the encoded symbol-table blob to `path`, creating parent
/// directories as needed. Atomic via a temp-file + rename so a partial
/// write (out of disk space, signal during write) never leaves a
/// half-decoded sidecar in place. Phase 2's crash printer reads this
/// file directly; a corrupt blob would point the printer at a bogus
/// Zap symbol.
fn writeSymbolTableSidecar(path: []const u8, bytes: []const u8) !void {
    const io = std.Options.debug_io;
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    var tmp_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    // Write to a temp file first, then rename, so a partial write
    // never publishes a half-decoded sidecar.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = bytes });
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

/// Prepare the context for an incremental update by saving current ZIR as
/// prev_zir for all injected files. Call this before re-injecting new ZIR.
pub fn prepareUpdate(ctx: *ZirContext) CompileError!void {
    if (zir_compilation_prepare_update(ctx) != 0) {
        return error.CompilationFailed;
    }
}

pub const SelectedUpdateInvalidationPolicy = enum {
    /// Preserve Zig's old-ZIR/new-ZIR instruction mapping and invalidate only
    /// declarations/functions whose associated source hashes changed.
    compare_source_hashes,
    /// Force every tracked source hash in each prepared injected ZIR file stale.
    /// Use this only for structural rebuilds where source-hash comparison is not
    /// a valid semantic boundary.
    force_all_source_hashes,
};

/// Prepare only the selected injected struct modules, plus the synthetic root
/// module when `include_root` is true. Unchanged modules keep their current ZIR
/// and are not placed into Zig's `prev_zir` diff set.
///
/// Normal selected updates must use `.compare_source_hashes`; this preserves
/// Zig's own `updateZirRefs` compare-hash path. `.force_all_source_hashes` is
/// reserved for frontend force-full/structural updates that intentionally give
/// up per-declaration precision.
pub fn prepareSelectedUpdate(
    allocator: std.mem.Allocator,
    ctx: *ZirContext,
    struct_names: []const []const u8,
    include_root: bool,
    invalidation: SelectedUpdateInvalidationPolicy,
) CompileError!void {
    var name_ptrs = allocator.alloc([*]const u8, struct_names.len) catch return error.OutOfMemory;
    defer allocator.free(name_ptrs);
    var name_lens = allocator.alloc(usize, struct_names.len) catch return error.OutOfMemory;
    defer allocator.free(name_lens);

    for (struct_names, 0..) |struct_name, index| {
        name_ptrs[index] = struct_name.ptr;
        name_lens[index] = struct_name.len;
    }

    if (zir_compilation_prepare_update_selected(ctx, name_ptrs.ptr, name_lens.ptr, struct_names.len, include_root) != 0) {
        return error.CompilationFailed;
    }

    switch (invalidation) {
        .compare_source_hashes => {},
        .force_all_source_hashes => {
            if (include_root) {
                try forceInvalidatePreparedRoot(ctx);
            }
            for (struct_names) |struct_name| {
                try forceInvalidatePreparedFile(ctx, struct_name, allocator);
            }
        },
    }
}

/// Abort a prepared incremental update before Zig's update phase starts,
/// restoring the previous injected ZIR for every prepared module.
pub fn abortUpdate(ctx: *ZirContext) CompileError!void {
    if (zir_compilation_abort_update(ctx) != 0) {
        return error.CompilationFailed;
    }
}

fn runPreparedUpdate(
    allocator: std.mem.Allocator,
    ctx: *ZirContext,
    options: CompileOptions,
) CompileError!void {
    const update_result = if (options.progress) |progress| blk: {
        progress.event("Zig: semantic analysis, codegen, link\n", .{});
        progress.handoffExternalOutput(.clear);
        break :blk zir_compilation_update_with_progress(ctx);
    } else zir_compilation_update(ctx);
    if (update_result != 0) {
        if (options.progress) |progress| progress.handoffExternalOutput(.clear);
        zir_compilation_print_errors(ctx);
        abortUpdate(ctx) catch {};
        return error.CompilationFailed;
    }

    if (options.incremental) {
        try publishIncrementalOutput(allocator, ctx, options.output_path);
    }
}

/// Inject ZIR after `prepareUpdate` and run the incremental update. If
/// Zap-side ZIR construction or injection fails before Zig's update phase
/// starts, the prepared context is rolled back to the prior ZIR baseline.
pub fn injectPreparedAndUpdate(allocator: std.mem.Allocator, program: ir.Program, ctx: *ZirContext, options: CompileOptions) CompileError!void {
    const lib_mode = options.output_mode == 1;
    const want_sidecar = options.emit_symbol_table_sidecar and options.output_mode == 0 and options.output_path.len > 0;
    var symbol_table_bytes: ?[]u8 = null;
    defer if (symbol_table_bytes) |bytes| allocator.free(bytes);
    const out_sym_ptr: ?*?[]u8 = if (want_sidecar) &symbol_table_bytes else null;
    zir_builder.buildAndInject(
        allocator,
        program,
        ctx,
        null,
        lib_mode,
        options.builder_entry,
        options.analysis_context,
        options.arc_ownership,
        options.declared_caps,
        options.progress,
        out_sym_ptr,
    ) catch |inject_err| {
        abortUpdate(ctx) catch |abort_err| {
            std.debug.print(
                "Error: failed to abort prepared incremental update after ZIR injection failure ({s}); context must be discarded: {s}\n",
                .{ @errorName(inject_err), @errorName(abort_err) },
            );
            return error.CompilationFailed;
        };
        return inject_err;
    };
    try runPreparedUpdate(allocator, ctx, options);

    if (want_sidecar) {
        if (symbol_table_bytes) |bytes| {
            const sidecar_path = try std.fmt.allocPrint(allocator, "{s}.zap-symbols", .{options.output_path});
            defer allocator.free(sidecar_path);
            writeSymbolTableSidecar(sidecar_path, bytes) catch |err| {
                std.debug.print(
                    "Warning: failed to write zap symbol-table sidecar at {s}: {s}\n",
                    .{ sidecar_path, @errorName(err) },
                );
            };
        }
    }
}

/// Inject only the prepared modules and run the incremental update.
///
/// Phase 0 — DWARF foundation (Gap B): the selected-incremental path
/// emits ZIR (and therefore collects symbol-table entries) only for
/// the structs in `struct_names` plus, when `include_root` is true,
/// the synthetic root. The driver's symbol table is therefore a
/// strict subset of the full set the user binary actually links.
/// Writing it verbatim over the prior `<artifact>.zap-symbols` sidecar
/// would erase every unchanged struct's entries — Phase-2's crash
/// printer would then degrade to mangled symbols across the rest of
/// the program after the very first selected rebuild.
///
/// To stay correct, this routine reads the prior sidecar (if any),
/// adopts every entry whose `zap_struct` is NOT in the just-rebuilt
/// selection (and, for the entry-point case, whose status follows
/// `include_root`), merges those adopted entries with the rebuild's
/// freshly-recorded entries, and writes the resulting deterministic
/// blob back to the sidecar path. The result is byte-identical to
/// what a full rebuild against the same `ir.Program` would have
/// emitted.
///
/// A corrupt or missing prior sidecar is recovered by the production-
/// safe fallback (option (b) in the gap analysis): the sidecar is
/// removed entirely so external tooling treats the binary as
/// unsymbolicated rather than displaying stale Zap names.
pub fn injectPreparedSelectedAndUpdate(
    allocator: std.mem.Allocator,
    program: ir.Program,
    ctx: *ZirContext,
    options: CompileOptions,
    struct_names: []const []const u8,
    include_root: bool,
) CompileError!void {
    const lib_mode = options.output_mode == 1;
    const want_sidecar = options.emit_symbol_table_sidecar and options.output_mode == 0 and options.output_path.len > 0;
    var rebuilt_symbol_table_bytes: ?[]u8 = null;
    defer if (rebuilt_symbol_table_bytes) |bytes| allocator.free(bytes);
    const out_sym_ptr: ?*?[]u8 = if (want_sidecar) &rebuilt_symbol_table_bytes else null;
    zir_builder.buildAndInjectSelected(
        allocator,
        program,
        ctx,
        lib_mode,
        options.builder_entry,
        options.analysis_context,
        options.arc_ownership,
        options.declared_caps,
        options.progress,
        struct_names,
        include_root,
        out_sym_ptr,
    ) catch |inject_err| {
        abortUpdate(ctx) catch |abort_err| {
            std.debug.print(
                "Error: failed to abort prepared incremental update after selective ZIR injection failure ({s}); context must be discarded: {s}\n",
                .{ @errorName(inject_err), @errorName(abort_err) },
            );
            return error.CompilationFailed;
        };
        return inject_err;
    };
    try runPreparedUpdate(allocator, ctx, options);

    if (want_sidecar) {
        const sidecar_path = try std.fmt.allocPrint(allocator, "{s}.zap-symbols", .{options.output_path});
        defer allocator.free(sidecar_path);
        try mergeAndWriteSelectedSidecar(
            allocator,
            sidecar_path,
            rebuilt_symbol_table_bytes,
            struct_names,
            include_root,
        );
    }
}

/// Read the prior sidecar (if any), merge the just-rebuilt selected
/// subset into the unchanged-struct entries adopted from it, and
/// atomically rewrite the sidecar. On any merge failure — corrupt
/// prior blob, allocator failure inside the merge — fall back to the
/// production-safe baseline: remove the sidecar so consumers see a
/// missing-symbol-table state instead of a stale one (Phase 0 Gap B
/// option (b) safety net).
fn mergeAndWriteSelectedSidecar(
    allocator: std.mem.Allocator,
    sidecar_path: []const u8,
    rebuilt_bytes: ?[]const u8,
    selected_structs: []const []const u8,
    include_root: bool,
) CompileError!void {
    const io = std.Options.debug_io;

    // Load the prior sidecar, if any. A missing prior is a first-build
    // state and is fine; any other read error means the file is in an
    // unexpected state — fall through to invalidation.
    var prior_bytes_owned: ?[]u8 = null;
    defer if (prior_bytes_owned) |bytes| allocator.free(bytes);
    prior_bytes_owned = std.Io.Dir.cwd().readFileAlloc(io, sidecar_path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };

    var merged_builder = zap_symbol_table.Builder.init(allocator);
    defer merged_builder.deinit();

    // Adopt entries from the rebuilt subset (everything the selected
    // build re-emitted) with no further filtering — the rebuild is
    // authoritative for its own structs.
    if (rebuilt_bytes) |bytes| {
        merged_builder.adoptFromSidecar(bytes, &.{}, false) catch |err| {
            invalidateSidecarFallback(sidecar_path, "merge: rebuilt blob unreadable", err);
            return;
        };
    }

    // Adopt unchanged-struct entries from the prior sidecar. The merge
    // helper drops any entry whose `zap_struct` is in `selected_structs`
    // (and root entries when `include_root`) — those are owned by the
    // rebuild.
    if (prior_bytes_owned) |bytes| {
        merged_builder.adoptFromSidecar(bytes, selected_structs, include_root) catch |err| {
            invalidateSidecarFallback(sidecar_path, "merge: prior sidecar unreadable", err);
            return;
        };
    }

    // Producing nothing at all means the program has no Zap-identified
    // symbols (e.g. the selected slice was empty and there was no prior
    // sidecar). Skip writing an empty blob — the consumer's existing
    // missing-file handling already covers this case.
    if (merged_builder.entries.items.len == 0) {
        if (prior_bytes_owned == null) return;
        // The prior sidecar exists but everything in it was selected for
        // rebuild and the rebuild emitted nothing — remove the stale
        // file so consumers fall back to mangled symbols.
        std.Io.Dir.cwd().deleteFile(io, sidecar_path) catch {};
        return;
    }

    const merged_blob = merged_builder.encode() catch |err| {
        invalidateSidecarFallback(sidecar_path, "merge: encode failed", err);
        return;
    };
    defer allocator.free(merged_blob);

    writeSymbolTableSidecar(sidecar_path, merged_blob) catch |err| {
        std.debug.print(
            "Warning: failed to write merged zap symbol-table sidecar at {s}: {s}\n",
            .{ sidecar_path, @errorName(err) },
        );
    };
}

/// Phase 0 Gap B fallback: delete the sidecar so consumers see a
/// missing-symbol-table state rather than a stale one. The original
/// merge error is reported through stderr so a hosting daemon log
/// preserves the diagnostic. Best-effort delete — a removal failure is
/// itself worth surfacing.
fn invalidateSidecarFallback(sidecar_path: []const u8, context: []const u8, err: anyerror) void {
    const io = std.Options.debug_io;
    std.debug.print(
        "Warning: invalidating stale zap symbol-table sidecar {s} ({s}: {s})\n",
        .{ sidecar_path, context, @errorName(err) },
    );
    std.Io.Dir.cwd().deleteFile(io, sidecar_path) catch |del_err| switch (del_err) {
        error.FileNotFound => {},
        else => std.debug.print(
            "Warning: failed to remove stale sidecar {s}: {s}\n",
            .{ sidecar_path, @errorName(del_err) },
        ),
    };
}

/// Force every source hash in a prepared named struct's injected ZIR file stale.
/// Ordinary selected updates should not call this path; they rely on Zig's
/// compare-hash update mode after `prepareSelectedUpdate`.
fn forceInvalidatePreparedFile(ctx: *ZirContext, name: []const u8, allocator: std.mem.Allocator) CompileError!void {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    if (zir_compilation_invalidate_file(ctx, name_z) != 0) {
        return error.CompilationFailed;
    }
}

/// Force every source hash in the prepared synthetic root injected ZIR file
/// stale. Ordinary selected root updates should use compare-hash mode.
fn forceInvalidatePreparedRoot(ctx: *ZirContext) CompileError!void {
    if (zir_compilation_invalidate_root(ctx) != 0) {
        return error.CompilationFailed;
    }
}

/// Link a system library by name (e.g., "m" for libm).
/// Must be called after createContext and before injectAndUpdate.
pub fn addLinkLib(ctx: *ZirContext, name: []const u8, allocator: std.mem.Allocator) CompileError!void {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    if (zir_compilation_add_link_lib(ctx, name_z) != 0) {
        return error.CompilationFailed;
    }
}

/// Add a precompiled object file at `path` to the final binary's link
/// inputs. Used by the Memory Manager ABI v1.0 build pipeline
/// (`docs/memory-manager-abi.md` section 10) to splice the manager `.o`
/// compiled by `src/memory/driver.zig` into the binary alongside Zap-
/// generated code. Must be called after createContext and before
/// injectAndUpdate.
///
/// Translates the fork primitive's two negative return codes:
///   * `-1` → `error.CompilationFailed` (general failure, allocation,
///     internal error).
///   * `-2` → `error.LinkObjectFileNotReadable` (filesystem failure
///     opening the object or its parent dir).
pub fn addLinkObjectFile(ctx: *ZirContext, path: []const u8, allocator: std.mem.Allocator) CompileError!void {
    const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(path_z);
    const rc = zir_compilation_add_link_object_file(ctx, path_z);
    switch (rc) {
        0 => return,
        -2 => return error.LinkObjectFileNotReadable,
        else => return error.CompilationFailed,
    }
}

/// Destroy a ZirContext that was created via `createContext`.
pub fn destroyContext(ctx: *ZirContext) void {
    zir_compilation_destroy(ctx);
}

/// Compile a Zap IR program to a native binary via ZIR.
///
/// This is the replacement for the `codegen.zig -> write .zig file -> zig build`
/// flow. Instead: `ir.Program -> ZirDriver (C-ABI) -> inject -> Zig compiler -> binary`.
///
/// For non-incremental use: creates context, injects ZIR, updates, and destroys.
/// For incremental use, call `createContext`, `injectAndUpdate`, `prepareUpdate`,
/// and `destroyContext` separately.
pub fn compile(allocator: std.mem.Allocator, program: ir.Program, options: CompileOptions) CompileError!void {
    if (options.progress) |progress| {
        progress.stage("ZIR: creating Zig compilation", .{});
    }
    const ctx = try createContext(allocator, options);
    defer destroyContext(ctx);
    try injectAndUpdate(allocator, program, ctx, options);
}

/// Detect the Zig lib directory.
/// Checks ZAP_ZIG_LIB_DIR, ZIG_LIB_DIR env vars, exe-relative paths, then
/// well-known installation paths. Returns null if detection fails.
/// Caller owns the returned memory.
pub fn detectZigLibDir(allocator: std.mem.Allocator) ?[]const u8 {
    // 1. Try the ZAP_ZIG_LIB_DIR environment variable (project-specific override).
    if (env.getenv("ZAP_ZIG_LIB_DIR")) |val| {
        return val;
    }

    // 2. Try the ZIG_LIB_DIR environment variable.
    if (env.getenv("ZIG_LIB_DIR")) |val| {
        return val;
    }

    // 3. Try paths relative to the self executable.
    //    e.g., if exe is /usr/local/bin/zap, check:
    //      /usr/local/lib/zig/std/std.zig  (../lib/zig/)
    //      /usr/local/lib/std/std.zig      (../lib/)
    if (std.process.executablePathAlloc(std.Options.debug_io, allocator)) |exe_path| {
        defer allocator.free(exe_path);
        const exe_dir = std.fs.path.dirname(exe_path) orelse "";
        const parent_dir = std.fs.path.dirname(exe_dir) orelse "";

        const exe_relative_candidates = [_][]const u8{
            "lib/zig",
            "lib",
        };

        for (exe_relative_candidates) |suffix| {
            const candidate = std.fs.path.join(allocator, &.{ parent_dir, suffix }) catch continue;
            const check = std.fs.path.join(allocator, &.{ candidate, "std", "std.zig" }) catch {
                allocator.free(candidate);
                continue;
            };
            defer allocator.free(check);

            std.Io.Dir.cwd().access(std.Options.debug_io, check, .{}) catch {
                allocator.free(candidate);
                continue;
            };

            return candidate;
        }
    } else |_| {}

    // 4. Try well-known paths based on the system zig installation.
    const home_dir: ?[]const u8 = env.getenv("HOME");

    // Build asdf candidate only if HOME is available.
    const asdf_candidate: ?[]const u8 = if (home_dir) |h|
        std.fs.path.join(allocator, &.{ h, ".asdf/installs/zig/0.16.0/lib" }) catch null
    else
        null;
    defer if (asdf_candidate) |c| allocator.free(c);

    const static_candidates = [_][]const u8{
        "/usr/local/lib/zig",
        "/usr/lib/zig",
    };

    // Check asdf candidate first if available.
    if (asdf_candidate) |candidate| {
        const check_path = std.fs.path.join(allocator, &.{ candidate, "std", "std.zig" }) catch null;
        if (check_path) |c| {
            defer allocator.free(c);
            const accessible = blk: {
                std.Io.Dir.cwd().access(std.Options.debug_io, c, .{}) catch break :blk false;
                break :blk true;
            };
            if (accessible) {
                return allocator.dupe(u8, candidate) catch null;
            }
        }
    }

    for (static_candidates) |candidate| {
        const check = std.fs.path.join(allocator, &.{ candidate, "std", "std.zig" }) catch continue;
        defer allocator.free(check);

        std.Io.Dir.cwd().access(std.Options.debug_io, check, .{}) catch continue;

        return allocator.dupe(u8, candidate) catch return null;
    }

    return null;
}

// ---------------------------------------------------------------------------
// Selected-incremental sidecar merge — Phase 0 Gap B unit tests
// ---------------------------------------------------------------------------
//
// `mergeAndWriteSelectedSidecar` reaches the real filesystem (the
// sidecar lives next to the artifact on disk and the daemon's
// selected-update path can run concurrently with debugger / crash-
// printer reads), so these tests exercise the merge through a temp
// directory rather than mocking the I/O layer. A fresh temp dir is
// used per test so the canonical CWD-relative path the merge writes
// to never collides with sibling tests or pre-existing repo state.

const testing = std.testing;

/// Build a small symbol-table blob with the supplied entries. Each
/// tuple is `{ mangled, zap_struct, zap_local, zap_arity }` where
/// `zap_struct == null` encodes the entry-point case.
fn encodeSymbolTableForTest(
    allocator: std.mem.Allocator,
    entries: []const struct { []const u8, ?[]const u8, []const u8, u32 },
) ![]u8 {
    var builder = zap_symbol_table.Builder.init(allocator);
    defer builder.deinit();
    for (entries) |entry| {
        try builder.record(entry[0], entry[1], entry[2], entry[3]);
    }
    return try builder.encode();
}

test "mergeAndWriteSelectedSidecar carries forward unchanged-struct entries" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const artifact_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe" });
    defer testing.allocator.free(artifact_path);
    const sidecar_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe.zap-symbols" });
    defer testing.allocator.free(sidecar_path);

    // Seed a baseline sidecar covering three structs + the entry point.
    const baseline_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Alpha.do__1", "Alpha", "do", 1 },
        .{ "Beta.run__0", "Beta", "run", 0 },
        .{ "Gamma.work__2", "Gamma", "work", 2 },
        .{ "main", null, "main", 1 },
    });
    defer testing.allocator.free(baseline_blob);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = sidecar_path, .data = baseline_blob });

    // The selected rebuild only re-emitted Beta — one entry.
    const rebuilt_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Beta.run__0", "Beta", "run", 0 },
    });
    defer testing.allocator.free(rebuilt_blob);

    const selected_structs = [_][]const u8{"Beta"};
    try mergeAndWriteSelectedSidecar(
        testing.allocator,
        sidecar_path,
        rebuilt_blob,
        &selected_structs,
        false,
    );

    const merged = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        sidecar_path,
        testing.allocator,
        .limited(1 * 1024 * 1024),
    );
    defer testing.allocator.free(merged);

    const reader = try zap_symbol_table.Reader.init(merged);
    try testing.expectEqual(@as(u32, 4), reader.entry_count);
    try testing.expect(reader.findByMangled("Alpha.do__1") != null);
    try testing.expect(reader.findByMangled("Beta.run__0") != null);
    try testing.expect(reader.findByMangled("Gamma.work__2") != null);
    try testing.expect(reader.findByMangled("main") != null);
}

test "mergeAndWriteSelectedSidecar drops stale entries from selected structs" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const sidecar_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe.zap-symbols" });
    defer testing.allocator.free(sidecar_path);

    // Baseline holds two functions in Beta; the rebuild renames one
    // and keeps the other — the dropped one must vanish from the
    // merged sidecar.
    const baseline_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Alpha.keep__0", "Alpha", "keep", 0 },
        .{ "Beta.stale__1", "Beta", "stale", 1 },
        .{ "Beta.survivor__2", "Beta", "survivor", 2 },
    });
    defer testing.allocator.free(baseline_blob);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = sidecar_path, .data = baseline_blob });

    const rebuilt_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Beta.survivor__2", "Beta", "survivor", 2 },
        // The rebuild added Beta.renamed/1 in place of Beta.stale/1.
        .{ "Beta.renamed__1", "Beta", "renamed", 1 },
    });
    defer testing.allocator.free(rebuilt_blob);

    const selected_structs = [_][]const u8{"Beta"};
    try mergeAndWriteSelectedSidecar(
        testing.allocator,
        sidecar_path,
        rebuilt_blob,
        &selected_structs,
        false,
    );

    const merged = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        sidecar_path,
        testing.allocator,
        .limited(1 * 1024 * 1024),
    );
    defer testing.allocator.free(merged);

    const reader = try zap_symbol_table.Reader.init(merged);
    try testing.expectEqual(@as(u32, 3), reader.entry_count);
    try testing.expect(reader.findByMangled("Alpha.keep__0") != null);
    try testing.expect(reader.findByMangled("Beta.survivor__2") != null);
    try testing.expect(reader.findByMangled("Beta.renamed__1") != null);
    // The stale function must NOT be carried forward.
    try testing.expect(reader.findByMangled("Beta.stale__1") == null);
}

test "mergeAndWriteSelectedSidecar invalidates the sidecar when the prior blob is corrupt" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const sidecar_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe.zap-symbols" });
    defer testing.allocator.free(sidecar_path);

    // A bad-magic prior sidecar forces the production-safe fallback.
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = sidecar_path, .data = &garbage });

    const rebuilt_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Beta.run__0", "Beta", "run", 0 },
    });
    defer testing.allocator.free(rebuilt_blob);

    const selected_structs = [_][]const u8{"Beta"};
    try mergeAndWriteSelectedSidecar(
        testing.allocator,
        sidecar_path,
        rebuilt_blob,
        &selected_structs,
        false,
    );

    // The corrupt sidecar must have been removed (the fallback path
    // chooses safety over a half-merged result).
    const exists = blk: {
        std.Io.Dir.cwd().access(std.Options.debug_io, sidecar_path, .{}) catch break :blk false;
        break :blk true;
    };
    try testing.expect(!exists);
}

test "mergeAndWriteSelectedSidecar writes a fresh sidecar when none exists yet" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const sidecar_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe.zap-symbols" });
    defer testing.allocator.free(sidecar_path);

    const rebuilt_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Beta.run__0", "Beta", "run", 0 },
    });
    defer testing.allocator.free(rebuilt_blob);

    const selected_structs = [_][]const u8{"Beta"};
    try mergeAndWriteSelectedSidecar(
        testing.allocator,
        sidecar_path,
        rebuilt_blob,
        &selected_structs,
        false,
    );

    const merged = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        sidecar_path,
        testing.allocator,
        .limited(1 * 1024 * 1024),
    );
    defer testing.allocator.free(merged);

    const reader = try zap_symbol_table.Reader.init(merged);
    try testing.expectEqual(@as(u32, 1), reader.entry_count);
    try testing.expect(reader.findByMangled("Beta.run__0") != null);
}
