//! ZIR Backend — calls the Zig compiler library to produce binaries from ZIR.
//!
//! This module provides extern declarations for the C-ABI functions exported
//! by libzig_compiler.a (built from the forked Zig at ~/projects/zig), and a
//! high-level `compile` function that wires up the full pipeline:
//!   ir.Program → ZirDriver (C-ABI calls) → inject → Zig compiler → binary
//!
//! The library must be linked at build time with `-Denable-zir-backend=true`.

const std = @import("std");
const zir_builder = @import("zir_builder.zig");
const ZirContext = zir_builder.ZirContext;
const ir = @import("ir.zig");

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

extern "c" fn zir_compilation_update(ctx: *ZirContext) i32;

extern "c" fn zir_compilation_destroy(ctx: *ZirContext) void;

extern "c" fn zir_compilation_add_module_source(
    ctx: *ZirContext,
    name: [*:0]const u8,
    source_ptr: [*]const u8,
    source_len: u32,
) i32;

extern "c" fn zir_compilation_print_errors(ctx: *ZirContext) void;

extern "c" fn zir_compilation_set_builder_entry(
    ctx: *ZirContext,
    entry_name: [*:0]const u8,
) i32;

// ---------------------------------------------------------------------------
// High-level API
// ---------------------------------------------------------------------------

pub const CompileError = error{
    ZirCreateFailed,
    BeginFuncFailed,
    EndFuncFailed,
    EmitFailed,
    UnknownLocal,
    CompilationCreateFailed,
    ZirInjectionFailed,
    CompilationFailed,
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
    /// zir_compilation_add_module_source instead of file path.
    runtime_source: ?[]const u8 = null,
    /// Output mode: 0=Exe, 1=Lib, 2=Obj.
    output_mode: u8 = 0,
    /// Optimize mode: 0=Debug, 1=ReleaseSafe, 2=ReleaseFast, 3=ReleaseSmall.
    optimize_mode: u8 = 1,
    /// For Lib output: true=dynamic (.so/.dylib), false=static (.a).
    is_dynamic: bool = false,
    /// Whether to link libc.
    link_libc: bool = true,
    /// Builder mode: compile as a builder binary with a custom entry point.
    /// The entry point function name (mangled, e.g., "FooBar__Builder__manifest").
    builder_entry: ?[]const u8 = null,
};

/// Compile a Zap IR program to a native binary via ZIR.
///
/// This is the replacement for the `codegen.zig -> write .zig file -> zig build`
/// flow. Instead: `ir.Program -> ZirDriver (C-ABI) -> inject -> Zig compiler -> binary`.
pub fn compile(allocator: std.mem.Allocator, program: ir.Program, options: CompileOptions) CompileError!void {
    // Phase 1: Create compilation context.
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

    const ctx = zir_compilation_create(zig_lib_z, cache_z, global_cache_z, output_z, name_z, options.output_mode, options.optimize_mode, options.is_dynamic, options.link_libc) orelse
        return error.CompilationCreateFailed;
    defer zir_compilation_destroy(ctx);

    // Configure builder mode if entry point is specified.
    if (options.builder_entry) |entry| {
        const entry_z = allocator.dupeZ(u8, entry) catch return error.OutOfMemory;
        defer allocator.free(entry_z);
        if (zir_compilation_set_builder_entry(ctx, entry_z) != 0) {
            return error.CompilationFailed;
        }
    }

    // Phase 2a: Register embedded runtime source if provided.
    if (options.runtime_source) |source| {
        if (zir_compilation_add_module_source(ctx, "zap_runtime", source.ptr, @intCast(source.len)) != 0) {
            return error.CompilationFailed;
        }
    }

    // Phase 2b: Build ZIR via C-ABI calls and inject into compilation.
    const lib_mode = options.output_mode == 1;
    try zir_builder.buildAndInject(allocator, program, ctx, null, lib_mode, options.builder_entry);

    // Phase 3: Run Sema + codegen + link.
    if (zir_compilation_update(ctx) != 0) {
        zir_compilation_print_errors(ctx);
        return error.CompilationFailed;
    }
}

/// Detect the Zig lib directory.
/// Checks ZAP_ZIG_LIB_DIR, ZIG_LIB_DIR env vars, exe-relative paths, then
/// well-known installation paths. Returns null if detection fails.
/// Caller owns the returned memory.
pub fn detectZigLibDir(allocator: std.mem.Allocator) ?[]const u8 {
    // 1. Try the ZAP_ZIG_LIB_DIR environment variable (project-specific override).
    if (std.process.getEnvVarOwned(allocator, "ZAP_ZIG_LIB_DIR")) |dir| {
        return dir;
    } else |_| {}

    // 2. Try the ZIG_LIB_DIR environment variable.
    if (std.process.getEnvVarOwned(allocator, "ZIG_LIB_DIR")) |dir| {
        return dir;
    } else |_| {}

    // 3. Try paths relative to the self executable.
    //    e.g., if exe is /usr/local/bin/zap, check:
    //      /usr/local/lib/zig/std/std.zig  (../lib/zig/)
    //      /usr/local/lib/std/std.zig      (../lib/)
    if (std.fs.selfExePathAlloc(allocator)) |exe_path| {
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

            std.fs.cwd().access(check, .{}) catch {
                allocator.free(candidate);
                continue;
            };

            return candidate;
        }
    } else |_| {}

    // 4. Try well-known paths based on the system zig installation.
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (home_dir) |h| allocator.free(h);

    // Build asdf candidate only if HOME is available.
    const asdf_candidate: ?[]const u8 = if (home_dir) |h|
        std.fs.path.join(allocator, &.{ h, ".asdf/installs/zig/0.15.2/lib" }) catch null
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
                std.fs.cwd().access(c, .{}) catch break :blk false;
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

        std.fs.cwd().access(check, .{}) catch continue;

        return allocator.dupe(u8, candidate) catch return null;
    }

    return null;
}
