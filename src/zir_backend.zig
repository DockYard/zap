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
) ?*ZirContext;

extern "c" fn zir_compilation_update(ctx: *ZirContext) i32;

extern "c" fn zir_compilation_destroy(ctx: *ZirContext) void;

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

    const ctx = zir_compilation_create(zig_lib_z, cache_z, global_cache_z, output_z, name_z) orelse
        return error.CompilationCreateFailed;
    defer zir_compilation_destroy(ctx);

    // Phase 2: Build ZIR via C-ABI calls and inject into compilation.
    try zir_builder.buildAndInject(allocator, program, ctx);

    // Phase 3: Run Sema + codegen + link.
    if (zir_compilation_update(ctx) != 0) {
        return error.CompilationFailed;
    }
}

/// Detect the Zig lib directory.
/// Checks ZIG_LIB_DIR env var, then tries to derive from the zig installation.
/// Returns null if detection fails. Caller owns the returned memory.
pub fn detectZigLibDir(allocator: std.mem.Allocator) ?[]const u8 {
    // Try the ZIG_LIB_DIR environment variable first.
    if (std.process.getEnvVarOwned(allocator, "ZIG_LIB_DIR")) |dir| {
        return dir;
    } else |_| {}

    // Try well-known paths based on the system zig installation.
    const candidates = [_][]const u8{
        // asdf-managed zig
        std.fs.path.join(allocator, &.{
            std.process.getEnvVarOwned(allocator, "HOME") catch return null,
            ".asdf/installs/zig/0.15.2/lib",
        }) catch return null,
        // System zig
        "/usr/local/lib/zig",
        "/usr/lib/zig",
    };

    for (candidates) |candidate| {
        // Check if std/std.zig exists under this path.
        const check = std.fs.path.join(allocator, &.{ candidate, "std", "std.zig" }) catch continue;
        defer allocator.free(check);

        std.fs.cwd().access(check, .{}) catch continue;

        return allocator.dupe(u8, candidate) catch return null;
    }

    return null;
}
