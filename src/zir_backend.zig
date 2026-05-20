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
        break :blk (if (options.incremental)
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
    } else (if (options.incremental)
        zir_compilation_create_incremental(zig_lib_z, cache_z, global_cache_z, output_z, name_z, options.output_mode, options.optimize_mode, options.is_dynamic, options.link_libc)
    else
        zir_compilation_create(zig_lib_z, cache_z, global_cache_z, output_z, name_z, options.output_mode, options.optimize_mode, options.is_dynamic, options.link_libc)) orelse
        return error.CompilationCreateFailed;

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
    try zir_builder.buildAndInject(allocator, program, ctx, null, lib_mode, options.builder_entry, options.analysis_context, options.arc_ownership, options.declared_caps, options.progress);

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
    zir_builder.buildAndInject(allocator, program, ctx, null, lib_mode, options.builder_entry, options.analysis_context, options.arc_ownership, options.declared_caps, options.progress) catch |inject_err| {
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
}

/// Inject only the prepared modules and run the incremental update.
pub fn injectPreparedSelectedAndUpdate(
    allocator: std.mem.Allocator,
    program: ir.Program,
    ctx: *ZirContext,
    options: CompileOptions,
    struct_names: []const []const u8,
    include_root: bool,
) CompileError!void {
    const lib_mode = options.output_mode == 1;
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
