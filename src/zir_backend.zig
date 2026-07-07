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
const diagnostics = @import("diagnostics.zig");

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

// Phase 0 — DWARF foundation, Gap C: V3 of every `create_*` ABI.
// Identical shape to V2 plus a trailing `frame_pointer_policy: u8`
// (see `FramePointerPolicy`). The two policies are independent; the
// V3 family is added alongside V2 (never on top of V2's parameter
// list) so V2 stays byte-identical for callers that don't need the
// frame-pointer override.
extern "c" fn zir_compilation_create_v3(
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
    frame_pointer_policy: u8,
) ?*ZirContext;

extern "c" fn zir_compilation_create_incremental_v3(
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
    frame_pointer_policy: u8,
) ?*ZirContext;

extern "c" fn zir_compilation_create_cross_v3(
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
    frame_pointer_policy: u8,
) ?*ZirContext;

extern "c" fn zir_compilation_create_cross_incremental_v3(
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
    frame_pointer_policy: u8,
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
    /// A prepared incremental update failed and the rollback to the previous
    /// injected ZIR baseline also failed. The owning watch/daemon state must
    /// discard the ZirContext before any later backend update.
    PreparedUpdateAbortFailed,
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
    /// The backend could not read an existing symbol-table sidecar while
    /// preparing a selected incremental merge. A missing sidecar is handled
    /// separately as a valid first-build/no-symbols state; this error means
    /// the filesystem read itself failed.
    SymbolTableSidecarReadFailed,
    /// A selected incremental update needed prior sidecar state to preserve
    /// unchanged symbols, but the prior sidecar was missing while the rebuild
    /// emitted Zap symbol mappings.
    SymbolTableSidecarMissing,
    /// An existing or freshly produced symbol-table sidecar blob did not
    /// decode as the expected Zap symbol-table format.
    SymbolTableSidecarParseFailed,
    /// The backend could not encode the merged sidecar blob after a selected
    /// incremental update.
    SymbolTableSidecarEncodeFailed,
    /// The backend could not write the sidecar atomically next to the output
    /// artifact.
    SymbolTableSidecarWriteFailed,
    /// The backend could not remove a stale sidecar after a validated
    /// no-symbols build.
    SymbolTableSidecarDeleteFailed,
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
    /// P2-J1 concurrency gate: path to the per-target concurrency
    /// kernel object resolved by `src/concurrency_driver.zig`, linked
    /// into the binary via `zir_compilation_add_link_object_file`.
    /// MUST be non-null exactly when the build's `runtime_concurrency`
    /// gate is ON **and this options value creates the compilation
    /// context** (the caller also passes `runtime_concurrency = true`
    /// through `compiler.RuntimeSourceControls` so the embedded
    /// runtime's `zap_proc_*` extern references have this object to
    /// resolve against). Incremental-rebuild options reuse a persistent
    /// context whose link inputs already carry the object and leave
    /// this null — which is why the gate itself travels separately as
    /// `runtime_concurrency` below. Null — the default — is the
    /// zero-cost OFF posture: nothing is linked and no intrinsic
    /// symbol exists.
    concurrency_kernel_object_path: ?[]const u8 = null,
    /// P2-J2: the resolved `runtime_concurrency` gate, threaded into
    /// ZIR emission (`zir_builder.ZirDriver.runtime_concurrency`).
    /// ON reroutes executable entry emission through the root-process
    /// bootstrap (user main runs as the root process). Must be set on
    /// EVERY options value that reaches an inject entry point —
    /// including incremental rebuilds that leave
    /// `concurrency_kernel_object_path` null.
    runtime_concurrency: bool = false,
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
    /// Phase 0 — DWARF foundation, Gap C: the per-mode frame-pointer
    /// policy resolved from the optimize mode plus any
    /// `-Dframe-pointers=on|off` CLI override. See
    /// `FramePointerPolicy` for the value semantics. `null` keeps
    /// Zig's per-module default — `omit_frame_pointer = false` in
    /// every mode except ReleaseSmall on non-x86 — and routes
    /// through the V1/V2 ABI. A non-null value forces the V3 ABI so
    /// the policy actually reaches `Package.Module.create`'s
    /// `inherited.omit_frame_pointer`.
    frame_pointer_policy: ?FramePointerPolicy = null,
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

/// Phase 0 — DWARF foundation, Gap C: per-mode frame-pointer policy.
/// Mirrors the fork's `FramePointerPolicy` in
/// `~/projects/zig/src/zir_api.zig` byte-for-byte — the raw `u8`
/// encoding is the C-ABI contract.
///
/// * `default` keeps Zig's per-module default
///   (`omit_frame_pointer = false` in every mode except ReleaseSmall
///   on non-x86). Existing V1/V2 callers stay on this path with
///   byte-identical behavior.
/// * `keep` forces frame pointers on regardless of the optimize
///   mode. The policy Zap's Debug / ReleaseSafe modes want so
///   `perf`, `samply`, and the Phase-2 async-signal-safe crash
///   printer can walk the stack without unwinder tables. Also the
///   resolved policy when the user passes `-Dframe-pointers=on`.
/// * `omit` forces frame pointers off regardless of the optimize
///   mode. The policy ReleaseFast / ReleaseSmall use to recover the
///   ~1-3% lost to the FP prologue. Also the resolved policy when
///   the user passes `-Dframe-pointers=off`.
pub const FramePointerPolicy = enum(u8) {
    default = 0,
    keep = 1,
    omit = 2,

    /// Project the Zap-side `?bool` flag (true = keep, false = omit,
    /// null = mode default) to the fork ABI's tri-state byte. The
    /// resolver in `src/main.zig` produces `?bool` after applying
    /// the per-optimize-mode default; this helper is the boundary
    /// between Zap's representation and the C-ABI contract.
    pub fn fromOptional(flag: ?bool) FramePointerPolicy {
        return switch (flag orelse return .default) {
            true => .keep,
            false => .omit,
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
    // Phase 0 — DWARF foundation: select the lowest ABI version that
    // can express the caller's requested policy stack. V3 carries both
    // the debug-info and frame-pointer policy bytes (Gap C); V2 carries
    // only the debug-info byte; V1 carries neither and preserves the
    // legacy behavior (Debug keeps DWARF, every other mode strips; FP
    // follows Zig's per-module default).
    //   * Any non-null `frame_pointer_policy` forces V3 — V2 has no way
    //     to express it.
    //   * Any non-null `debug_info_policy` with no FP override picks
    //     V2 for byte-identical V2 caller behavior.
    //   * Otherwise V1 stays the path, byte-identical to pre-Phase-0
    //     callers.
    const dbg_policy_byte: u8 = @intFromEnum(options.debug_info_policy orelse DebugInfoPolicy.default);
    const fp_policy_byte: u8 = @intFromEnum(options.frame_pointer_policy orelse FramePointerPolicy.default);
    const has_dbg_policy = options.debug_info_policy != null;
    const has_fp_policy = options.frame_pointer_policy != null;
    const use_v3 = has_fp_policy;
    const use_v2 = !has_fp_policy and has_dbg_policy;
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
        const target_ptr = if (target_z) |t| t.ptr else null;
        const cpu_ptr = if (cpu_z) |c| c.ptr else null;
        break :blk (if (options.incremental and use_v3)
            zir_compilation_create_cross_incremental_v3(
                zig_lib_z,
                cache_z,
                global_cache_z,
                output_z,
                name_z,
                options.output_mode,
                options.optimize_mode,
                options.is_dynamic,
                options.link_libc,
                target_ptr,
                cpu_ptr,
                dbg_policy_byte,
                fp_policy_byte,
            )
        else if (options.incremental and use_v2)
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
                target_ptr,
                cpu_ptr,
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
                target_ptr,
                cpu_ptr,
            )
        else if (use_v3)
            zir_compilation_create_cross_v3(
                zig_lib_z,
                cache_z,
                global_cache_z,
                output_z,
                name_z,
                options.output_mode,
                options.optimize_mode,
                options.is_dynamic,
                options.link_libc,
                target_ptr,
                cpu_ptr,
                dbg_policy_byte,
                fp_policy_byte,
            )
        else if (use_v2)
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
                target_ptr,
                cpu_ptr,
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
                target_ptr,
                cpu_ptr,
            )) orelse
            return error.CompilationCreateFailed;
    } else native_path: {
        break :native_path (if (options.incremental and use_v3)
            zir_compilation_create_incremental_v3(zig_lib_z, cache_z, global_cache_z, output_z, name_z, options.output_mode, options.optimize_mode, options.is_dynamic, options.link_libc, dbg_policy_byte, fp_policy_byte)
        else if (options.incremental and use_v2)
            zir_compilation_create_incremental_v2(zig_lib_z, cache_z, global_cache_z, output_z, name_z, options.output_mode, options.optimize_mode, options.is_dynamic, options.link_libc, dbg_policy_byte)
        else if (options.incremental)
            zir_compilation_create_incremental(zig_lib_z, cache_z, global_cache_z, output_z, name_z, options.output_mode, options.optimize_mode, options.is_dynamic, options.link_libc)
        else if (use_v3)
            zir_compilation_create_v3(zig_lib_z, cache_z, global_cache_z, output_z, name_z, options.output_mode, options.optimize_mode, options.is_dynamic, options.link_libc, dbg_policy_byte, fp_policy_byte)
        else if (use_v2)
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

    // P2-J1 concurrency gate: splice the per-target kernel object into
    // the link line. Present exactly when the build resolved
    // `runtime_concurrency` ON — the rewritten runtime source then
    // references the object's `zap_proc_*` intrinsics. The object was
    // compiled and content-address-validated by
    // `src/concurrency_driver.zig` before it reaches here.
    if (options.concurrency_kernel_object_path) |kernel_object_path| {
        addLinkObjectFile(ctx, kernel_object_path, allocator) catch |err| {
            zir_compilation_destroy(ctx);
            return err;
        };
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

fn incrementalOutputPathResolveError(err: anyerror) CompileError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.EmitFailed,
    };
}

fn resolveIncrementalOutputPath(allocator: std.mem.Allocator, path: []const u8) CompileError![]u8 {
    return std.fs.path.resolve(allocator, &.{path}) catch |err| return incrementalOutputPathResolveError(err);
}

const IncrementalOutputCopyPaths = struct {
    source_path: []const u8,
    output_path: []const u8,
    source_owned: bool,
    output_owned: bool,

    fn deinit(self: IncrementalOutputCopyPaths, allocator: std.mem.Allocator) void {
        if (self.source_owned) allocator.free(self.source_path);
        if (self.output_owned) allocator.free(self.output_path);
    }
};

fn resolveAbsoluteIncrementalOutputCopyPaths(
    allocator: std.mem.Allocator,
    artifact_path: []const u8,
    output_path: []const u8,
    artifact_path_absolute: bool,
    output_path_absolute: bool,
) CompileError!IncrementalOutputCopyPaths {
    std.debug.assert(artifact_path_absolute or output_path_absolute);

    const copy_source_path = if (artifact_path_absolute)
        artifact_path
    else
        try resolveIncrementalOutputPath(allocator, artifact_path);
    errdefer if (!artifact_path_absolute) allocator.free(copy_source_path);

    const copy_output_path = if (output_path_absolute)
        output_path
    else
        try resolveIncrementalOutputPath(allocator, output_path);
    errdefer if (!output_path_absolute) allocator.free(copy_output_path);

    return .{
        .source_path = copy_source_path,
        .output_path = copy_output_path,
        .source_owned = !artifact_path_absolute,
        .output_owned = !output_path_absolute,
    };
}

fn publishIncrementalOutput(allocator: std.mem.Allocator, ctx: *ZirContext, output_path: []const u8) CompileError!void {
    const artifact_path = try outputArtifactPath(allocator, ctx);
    defer allocator.free(artifact_path);

    if (std.mem.eql(u8, artifact_path, output_path)) return;

    const artifact_path_absolute = std.fs.path.isAbsolute(artifact_path);
    const output_path_absolute = std.fs.path.isAbsolute(output_path);
    if (artifact_path_absolute or output_path_absolute) {
        const copy_paths = try resolveAbsoluteIncrementalOutputCopyPaths(
            allocator,
            artifact_path,
            output_path,
            artifact_path_absolute,
            output_path_absolute,
        );
        defer copy_paths.deinit(allocator);

        std.Io.Dir.copyFileAbsolute(
            copy_paths.source_path,
            copy_paths.output_path,
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

/// Phase 1.5 — map the numeric optimize mode (0=Debug, 1=ReleaseSafe,
/// 2=ReleaseFast, 3=ReleaseSmall) to the per-mode arithmetic-overflow
/// policy: Debug and ReleaseSafe trap on overflow (route to
/// `arithmetic_error`), ReleaseFast and ReleaseSmall wrap. This is the
/// single boundary where the build config's optimize byte becomes the
/// ZIR builder's checked-vs-wrapping arithmetic decision, kept in lockstep
/// with `frontend_policy.FrontendOptimizeMode.arithmeticOverflowTraps`.
fn arithmeticOverflowTrapsForMode(optimize_mode: u8) bool {
    return optimize_mode == 0 or optimize_mode == 1;
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
        options.runtime_concurrency,
        options.analysis_context,
        options.arc_ownership,
        options.declared_caps,
        options.progress,
        arithmeticOverflowTrapsForMode(options.optimize_mode),
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
        try publishSymbolTableSidecar(allocator, options.output_path, symbol_table_bytes);
    }
}

fn sidecarWriteError(err: anyerror) CompileError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SymbolTableSidecarWriteFailed,
    };
}

fn sidecarReadError(err: anyerror) CompileError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SymbolTableSidecarReadFailed,
    };
}

fn sidecarParseError(err: anyerror) CompileError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SymbolTableSidecarParseFailed,
    };
}

fn sidecarEncodeError(err: anyerror) CompileError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateMangledName => error.DuplicateMangledName,
        else => error.SymbolTableSidecarEncodeFailed,
    };
}

fn sidecarDeleteError(err: anyerror) CompileError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SymbolTableSidecarDeleteFailed,
    };
}

fn sidecarPath(allocator: std.mem.Allocator, output_path: []const u8) CompileError![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.zap-symbols", .{output_path}) catch return error.OutOfMemory;
}

/// Write the encoded symbol-table blob to `path`, creating parent
/// directories as needed. Atomic via `createFileAtomic` + `replace` so a
/// partial write (out of disk space, signal during write) never leaves a
/// half-decoded sidecar in place. Phase 2's crash printer reads this file
/// directly; a corrupt blob would point the printer at a bogus Zap symbol.
fn writeSymbolTableSidecar(path: []const u8, bytes: []const u8) CompileError!void {
    const io = std.Options.debug_io;
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return sidecarWriteError(err),
        };
    }
    var atomic_file = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true }) catch |err| return sidecarWriteError(err);
    defer atomic_file.deinit(io);

    atomic_file.file.writeStreamingAll(io, bytes) catch |err| return sidecarWriteError(err);
    atomic_file.file.sync(io) catch |err| return sidecarWriteError(err);
    atomic_file.replace(io) catch |err| return sidecarWriteError(err);
}

fn deleteSymbolTableSidecarIfPresent(sidecar_path_value: []const u8) CompileError!void {
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, sidecar_path_value) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return sidecarDeleteError(err),
    };
}

fn publishSymbolTableSidecar(
    allocator: std.mem.Allocator,
    output_path: []const u8,
    symbol_table_bytes: ?[]const u8,
) CompileError!void {
    const sidecar_path_value = try sidecarPath(allocator, output_path);
    defer allocator.free(sidecar_path_value);

    if (symbol_table_bytes) |bytes| {
        try writeSymbolTableSidecar(sidecar_path_value, bytes);
    } else {
        // The ZIR builder only returns null after a successful build that
        // recorded no Zap symbol mappings. Keep the artifact/sidecar pair
        // honest by removing any older table for the same output.
        try deleteSymbolTableSidecarIfPresent(sidecar_path_value);
    }
}

fn readExistingSymbolTableSidecar(
    allocator: std.mem.Allocator,
    sidecar_path_value: []const u8,
) CompileError!?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        sidecar_path_value,
        allocator,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return sidecarReadError(err),
    };
}

fn adoptSymbolTableSidecar(
    builder: *zap_symbol_table.Builder,
    bytes: []const u8,
    selected_structs: []const []const u8,
    include_root: bool,
) CompileError!void {
    builder.adoptFromSidecar(bytes, selected_structs, include_root) catch |err| return sidecarParseError(err);
}

fn encodeMergedSymbolTableSidecar(builder: *zap_symbol_table.Builder) CompileError![]u8 {
    return builder.encode() catch |err| return sidecarEncodeError(err);
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

const PreparedUpdateFailureContext = enum {
    zir_injection,
    selected_zir_injection,
    zig_update,

    fn description(self: PreparedUpdateFailureContext) []const u8 {
        return switch (self) {
            .zir_injection => "ZIR injection failure",
            .selected_zir_injection => "selective ZIR injection failure",
            .zig_update => "Zig update failure",
        };
    }
};

fn preparedUpdateFailureStatus(original_err: CompileError, abort_err: ?CompileError) CompileError {
    if (abort_err != null) return error.PreparedUpdateAbortFailed;
    return original_err;
}

fn abortPreparedUpdateAfterFailure(
    ctx: *ZirContext,
    failure_context: PreparedUpdateFailureContext,
    original_err: CompileError,
) CompileError {
    abortUpdate(ctx) catch |abort_err| {
        diagnostics.emitStderrFmt(
            "Error: failed to abort prepared incremental update after {s} ({s}); context must be discarded: {s}\n",
            .{ failure_context.description(), @errorName(original_err), @errorName(abort_err) },
        );
        return preparedUpdateFailureStatus(original_err, abort_err);
    };
    return preparedUpdateFailureStatus(original_err, null);
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
        return abortPreparedUpdateAfterFailure(ctx, .zig_update, error.CompilationFailed);
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
        options.runtime_concurrency,
        options.analysis_context,
        options.arc_ownership,
        options.declared_caps,
        options.progress,
        arithmeticOverflowTrapsForMode(options.optimize_mode),
        out_sym_ptr,
    ) catch |inject_err| {
        return abortPreparedUpdateAfterFailure(ctx, .zir_injection, inject_err);
    };
    try runPreparedUpdate(allocator, ctx, options);

    if (want_sidecar) {
        try publishSymbolTableSidecar(allocator, options.output_path, symbol_table_bytes);
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
/// A missing prior sidecar is allowed only when the selected rebuild
/// plus prior state validates that the output has no Zap-identified
/// symbols. A corrupt or unreadable prior sidecar is a backend
/// infrastructure failure because continuing would publish an artifact
/// whose debug side table cannot be trusted.
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
        options.runtime_concurrency,
        options.analysis_context,
        options.arc_ownership,
        options.declared_caps,
        options.progress,
        arithmeticOverflowTrapsForMode(options.optimize_mode),
        struct_names,
        include_root,
        out_sym_ptr,
    ) catch |inject_err| {
        return abortPreparedUpdateAfterFailure(ctx, .selected_zir_injection, inject_err);
    };
    try runPreparedUpdate(allocator, ctx, options);

    if (want_sidecar) {
        const sidecar_path_value = try sidecarPath(allocator, options.output_path);
        defer allocator.free(sidecar_path_value);
        try mergeAndWriteSelectedSidecar(
            allocator,
            sidecar_path_value,
            rebuilt_symbol_table_bytes,
            struct_names,
            include_root,
        );
    }
}

/// Read the prior sidecar (if any), merge the just-rebuilt selected
/// subset into the unchanged-struct entries adopted from it, and
/// atomically rewrite the sidecar. Missing prior state is accepted only after
/// the merge validates that there are no Zap-identified symbols to publish;
/// corrupt prior state, missing prior state with rebuilt symbols, read
/// failures, encode failures, and write failures are compile-fatal because the
/// sidecar is part of artifact/debug correctness.
fn mergeAndWriteSelectedSidecar(
    allocator: std.mem.Allocator,
    sidecar_path_value: []const u8,
    rebuilt_bytes: ?[]const u8,
    selected_structs: []const []const u8,
    include_root: bool,
) CompileError!void {
    var prior_bytes_owned: ?[]u8 = null;
    defer if (prior_bytes_owned) |bytes| allocator.free(bytes);
    prior_bytes_owned = try readExistingSymbolTableSidecar(allocator, sidecar_path_value);

    var merged_builder = zap_symbol_table.Builder.init(allocator);
    defer merged_builder.deinit();

    // Adopt entries from the rebuilt subset (everything the selected
    // build re-emitted) with no further filtering — the rebuild is
    // authoritative for its own structs.
    if (rebuilt_bytes) |bytes| {
        try adoptSymbolTableSidecar(&merged_builder, bytes, &.{}, false);
    }

    // Adopt unchanged-struct entries from the prior sidecar. The merge
    // helper drops any entry whose `zap_struct` is in `selected_structs`
    // (and root entries when `include_root`) — those are owned by the
    // rebuild.
    if (prior_bytes_owned) |bytes| {
        try adoptSymbolTableSidecar(&merged_builder, bytes, selected_structs, include_root);
    }

    if (prior_bytes_owned == null and merged_builder.entries.items.len > 0) {
        return error.SymbolTableSidecarMissing;
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
        try deleteSymbolTableSidecarIfPresent(sidecar_path_value);
        return;
    }

    const merged_blob = try encodeMergedSymbolTableSidecar(&merged_builder);
    defer allocator.free(merged_blob);

    try writeSymbolTableSidecar(sidecar_path_value, merged_blob);
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

/// Errors that mean Zig-lib probing was blocked by infrastructure or by an
/// explicitly configured invalid directory. A missing lower-precedence
/// candidate is represented by `null`; it is not collapsed into one of these
/// errors.
pub const ZigLibDirProbeError = error{
    InvalidZigLibDir,
    ZigLibDirExecutablePathFailed,
    ZigLibDirAccessFailed,
    ZigLibDirCanonicalizeFailed,
    OutOfMemory,
};

const MissingZigLibCandidateBehavior = enum {
    absence,
    invalid,
};

fn isMissingZigLibPathError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.NotDir => true,
        else => false,
    };
}

fn zigLibExecutablePathError(err: anyerror) ZigLibDirProbeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ZigLibDirExecutablePathFailed,
    };
}

fn zigLibDirAccessError(err: anyerror) ZigLibDirProbeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ZigLibDirAccessFailed,
    };
}

fn zigLibDirCanonicalizeError(err: anyerror) ZigLibDirProbeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ZigLibDirCanonicalizeFailed,
    };
}

fn accessZigLibMarker(path: []const u8) anyerror!void {
    return std.Io.Dir.cwd().access(std.Options.debug_io, path, .{});
}

fn canonicalizeZigLibPath(allocator: std.mem.Allocator, path: []const u8) ZigLibDirProbeError![]const u8 {
    const real_path_z = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, allocator) catch |err| {
        return zigLibDirCanonicalizeError(err);
    };
    defer allocator.free(real_path_z);
    return allocator.dupe(u8, real_path_z) catch return error.OutOfMemory;
}

fn canonicalizeZigLibPathForProbe(allocator: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
    return canonicalizeZigLibPath(allocator, path);
}

fn probeZigLibCandidateWithHooks(
    allocator: std.mem.Allocator,
    candidate: []const u8,
    missing_behavior: MissingZigLibCandidateBehavior,
    comptime accessFn: fn ([]const u8) anyerror!void,
    comptime canonicalizeFn: fn (std.mem.Allocator, []const u8) anyerror![]const u8,
) ZigLibDirProbeError!?[]const u8 {
    const std_marker = std.fs.path.join(allocator, &.{ candidate, "std", "std.zig" }) catch return error.OutOfMemory;
    defer allocator.free(std_marker);

    accessFn(std_marker) catch |err| {
        if (isMissingZigLibPathError(err)) {
            return switch (missing_behavior) {
                .absence => null,
                .invalid => error.InvalidZigLibDir,
            };
        }
        return zigLibDirAccessError(err);
    };

    return canonicalizeFn(allocator, candidate) catch |err| {
        return zigLibDirCanonicalizeError(err);
    };
}

fn probeZigLibCandidate(
    allocator: std.mem.Allocator,
    candidate: []const u8,
    missing_behavior: MissingZigLibCandidateBehavior,
) ZigLibDirProbeError!?[]const u8 {
    return probeZigLibCandidateWithHooks(
        allocator,
        candidate,
        missing_behavior,
        accessZigLibMarker,
        canonicalizeZigLibPathForProbe,
    );
}

fn probeConfiguredZigLibDir(allocator: std.mem.Allocator, candidate: []const u8) ZigLibDirProbeError![]const u8 {
    return (try probeZigLibCandidate(allocator, candidate, .invalid)) orelse unreachable;
}

/// Resolve the trusted Zig stdlib directory for compiling user binaries.
///
/// Precedence is ZAP_ZIG_LIB_DIR, ZIG_LIB_DIR, then a copy shipped next to the
/// `zap` executable. These are trusted fork-stdlib sources, so callers must
/// prefer them over the embedded fork bundle and any system Zig fallback.
///
/// Returns null only when no trusted source exists. Infrastructure failures and
/// explicitly configured invalid directories are hard errors. Caller owns the
/// returned memory.
///
/// This deliberately does NOT consult a system Zig install (asdf,
/// `/usr/local`, …): those are upstream Zig, not the fork, and lack the
/// fork-only stdlib changes (e.g. the `MachOFile` dSYM fallback). Callers
/// must prefer the embedded fork stdlib over the system fallback — see
/// `detectZigLibDirSystemFallback`.
pub fn detectZigLibDir(allocator: std.mem.Allocator) ZigLibDirProbeError!?[]const u8 {
    // 1. Try the ZAP_ZIG_LIB_DIR environment variable (project-specific override).
    if (env.getenv("ZAP_ZIG_LIB_DIR")) |val| {
        return try probeConfiguredZigLibDir(allocator, val);
    }

    // 2. Try the ZIG_LIB_DIR environment variable.
    if (env.getenv("ZIG_LIB_DIR")) |val| {
        return try probeConfiguredZigLibDir(allocator, val);
    }

    // 3. Try paths relative to the self executable.
    //    e.g., if exe is /usr/local/bin/zap, check:
    //      /usr/local/lib/zig/std/std.zig  (../lib/zig/)
    //      /usr/local/lib/std/std.zig      (../lib/)
    const exe_path_z = std.process.executablePathAlloc(std.Options.debug_io, allocator) catch |err| {
        return zigLibExecutablePathError(err);
    };
    defer allocator.free(exe_path_z);
    const exe_path = try canonicalizeZigLibPath(allocator, exe_path_z);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse "";
    const parent_dir = std.fs.path.dirname(exe_dir) orelse "";

    const exe_relative_candidates = [_][]const u8{
        "lib/zig",
        "lib",
    };

    for (exe_relative_candidates) |suffix| {
        const candidate = std.fs.path.join(allocator, &.{ parent_dir, suffix }) catch return error.OutOfMemory;
        defer allocator.free(candidate);
        if (try probeZigLibCandidate(allocator, candidate, .absence)) |zig_lib_dir| {
            return zig_lib_dir;
        }
    }

    return null;
}

/// Last-resort Zig stdlib resolution against a **system** Zig install (asdf,
/// `/usr/local/lib/zig`, `/usr/lib/zig`). This is intentionally the lowest
/// priority: a system Zig is upstream, not the Zap fork, so its stdlib lacks
/// the fork-only changes the crash reporter relies on (notably the
/// `std.debug.MachOFile` dSYM fallback that resolves `zap run` backtraces to
/// Zap source). Callers MUST try `detectZigLibDir` and the embedded fork
/// stdlib first, and only fall back here when neither is available — at which
/// point a degraded backtrace beats no compilation at all.
pub fn detectZigLibDirSystemFallback(allocator: std.mem.Allocator) ZigLibDirProbeError!?[]const u8 {
    const home_dir: ?[]const u8 = env.getenv("HOME");

    const static_candidates = [_][]const u8{
        "/usr/local/lib/zig",
        "/usr/lib/zig",
    };

    // Check asdf candidate first if available.
    if (home_dir) |home| {
        const asdf_candidate = std.fs.path.join(allocator, &.{ home, ".asdf/installs/zig/0.16.0/lib" }) catch return error.OutOfMemory;
        defer allocator.free(asdf_candidate);
        if (try probeZigLibCandidate(allocator, asdf_candidate, .absence)) |zig_lib_dir| {
            return zig_lib_dir;
        }
    }

    for (static_candidates) |candidate| {
        if (try probeZigLibCandidate(allocator, candidate, .absence)) |zig_lib_dir| {
            return zig_lib_dir;
        }
    }

    return null;
}

fn missingZigLibMarkerForTest(_: []const u8) anyerror!void {
    return error.FileNotFound;
}

fn deniedZigLibMarkerForTest(_: []const u8) anyerror!void {
    return error.AccessDenied;
}

fn presentZigLibMarkerForTest(_: []const u8) anyerror!void {}

fn canonicalizeUnexpectedForTest(_: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    return error.AccessDenied;
}

fn canonicalizeDupeForTest(allocator: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
    return allocator.dupe(u8, path);
}

const testing = std.testing;

test "P4J2: incremental publish source path resolution preserves OutOfMemory" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const absolute_output_path = if (@import("builtin").os.tag == .windows)
        "C:\\tmp\\zap-example"
    else
        "/tmp/zap-example";
    try testing.expectError(
        error.OutOfMemory,
        resolveAbsoluteIncrementalOutputCopyPaths(
            failing_allocator.allocator(),
            "zig-cache/o/example",
            absolute_output_path,
            false,
            true,
        ),
    );
}

test "P4J2: incremental publish output path resolution preserves OutOfMemory" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const absolute_artifact_path = if (@import("builtin").os.tag == .windows)
        "C:\\tmp\\zig-cache\\o\\example"
    else
        "/tmp/zig-cache/o/example";
    try testing.expectError(
        error.OutOfMemory,
        resolveAbsoluteIncrementalOutputCopyPaths(
            failing_allocator.allocator(),
            absolute_artifact_path,
            "zig-out/bin/example",
            true,
            false,
        ),
    );
}

test "P4J2: incremental publish path resolution keeps non-OOM output failures in emit bucket" {
    try testing.expectEqual(
        @as(CompileError, error.EmitFailed),
        incrementalOutputPathResolveError(error.AccessDenied),
    );
}

test "P4J2: prepared update abort failure reports context-invalidating backend error" {
    try testing.expectEqual(
        @as(CompileError, error.ZirInjectionFailed),
        preparedUpdateFailureStatus(error.ZirInjectionFailed, null),
    );
    try testing.expectEqual(
        @as(CompileError, error.CompilationFailed),
        preparedUpdateFailureStatus(error.CompilationFailed, null),
    );
    try testing.expectEqual(
        @as(CompileError, error.PreparedUpdateAbortFailed),
        preparedUpdateFailureStatus(error.ZirInjectionFailed, error.CompilationFailed),
    );
    try testing.expectEqual(
        @as(CompileError, error.PreparedUpdateAbortFailed),
        preparedUpdateFailureStatus(error.CompilationFailed, error.OutOfMemory),
    );
}

test "P4J2: Zig lib candidate absence remains optional" {
    const resolved = try probeZigLibCandidateWithHooks(
        testing.allocator,
        "/missing/zig/lib",
        .absence,
        missingZigLibMarkerForTest,
        canonicalizeUnexpectedForTest,
    );
    try testing.expectEqual(@as(?[]const u8, null), resolved);
}

test "P4J2: configured Zig lib missing std marker is invalid" {
    try testing.expectError(
        error.InvalidZigLibDir,
        probeZigLibCandidateWithHooks(
            testing.allocator,
            "/configured/zig/lib",
            .invalid,
            missingZigLibMarkerForTest,
            canonicalizeUnexpectedForTest,
        ),
    );
}

test "P4J2: Zig lib candidate access failures propagate" {
    try testing.expectError(
        error.ZigLibDirAccessFailed,
        probeZigLibCandidateWithHooks(
            testing.allocator,
            "/protected/zig/lib",
            .absence,
            deniedZigLibMarkerForTest,
            canonicalizeUnexpectedForTest,
        ),
    );
}

test "P4J2: Zig lib candidate canonicalization failures propagate" {
    try testing.expectError(
        error.ZigLibDirCanonicalizeFailed,
        probeZigLibCandidateWithHooks(
            testing.allocator,
            "/present/zig/lib",
            .absence,
            presentZigLibMarkerForTest,
            canonicalizeUnexpectedForTest,
        ),
    );
}

test "P4J2: Zig lib candidate OutOfMemory propagates" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        probeZigLibCandidateWithHooks(
            failing_allocator.allocator(),
            "/present/zig/lib",
            .absence,
            presentZigLibMarkerForTest,
            canonicalizeDupeForTest,
        ),
    );
}

test "P4J2: trusted Zig lib detection preserves OutOfMemory" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, detectZigLibDir(failing_allocator.allocator()));
}

test "P4J2: system Zig lib fallback preserves OutOfMemory" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, detectZigLibDirSystemFallback(failing_allocator.allocator()));
}

test "P4J2: Zig lib executable path failures are infrastructure errors" {
    try testing.expectEqual(
        @as(ZigLibDirProbeError, error.ZigLibDirExecutablePathFailed),
        zigLibExecutablePathError(error.AccessDenied),
    );
    try testing.expectEqual(
        @as(ZigLibDirProbeError, error.OutOfMemory),
        zigLibExecutablePathError(error.OutOfMemory),
    );
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

fn sidecarExistsForTest(sidecar_path_value: []const u8) bool {
    std.Io.Dir.cwd().access(std.Options.debug_io, sidecar_path_value, .{}) catch return false;
    return true;
}

test "publishSymbolTableSidecar fails when the sidecar target cannot be replaced" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const artifact_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe" });
    defer testing.allocator.free(artifact_path);
    const sidecar_path_value = try sidecarPath(testing.allocator, artifact_path);
    defer testing.allocator.free(sidecar_path_value);

    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, sidecar_path_value);

    const blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Beta.run__0", "Beta", "run", 0 },
    });
    defer testing.allocator.free(blob);

    try testing.expectError(
        error.SymbolTableSidecarWriteFailed,
        publishSymbolTableSidecar(testing.allocator, artifact_path, blob),
    );

    var iterator = tmp_dir.dir.iterate();
    var entry_count: usize = 0;
    while (try iterator.next(std.Options.debug_io)) |entry| {
        entry_count += 1;
        try testing.expectEqualStrings("probe.zap-symbols", entry.name);
    }
    try testing.expectEqual(@as(usize, 1), entry_count);
}

test "publishSymbolTableSidecar ignores pre-existing fixed temp path" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const artifact_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe" });
    defer testing.allocator.free(artifact_path);
    const sidecar_path_value = try sidecarPath(testing.allocator, artifact_path);
    defer testing.allocator.free(sidecar_path_value);
    const fixed_temp_path = try std.fmt.allocPrint(testing.allocator, "{s}.tmp", .{sidecar_path_value});
    defer testing.allocator.free(fixed_temp_path);

    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, fixed_temp_path);

    const blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Beta.run__0", "Beta", "run", 0 },
    });
    defer testing.allocator.free(blob);

    try publishSymbolTableSidecar(testing.allocator, artifact_path, blob);

    const published = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        sidecar_path_value,
        testing.allocator,
        .limited(1 * 1024 * 1024),
    );
    defer testing.allocator.free(published);
    try testing.expectEqualSlices(u8, blob, published);

    var fixed_temp_dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, fixed_temp_path, .{});
    fixed_temp_dir.close(std.Options.debug_io);
}

test "publishSymbolTableSidecar removes stale sidecar for validated no-symbols output" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const artifact_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe" });
    defer testing.allocator.free(artifact_path);
    const sidecar_path_value = try sidecarPath(testing.allocator, artifact_path);
    defer testing.allocator.free(sidecar_path_value);

    const stale_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Old.run__0", "Old", "run", 0 },
    });
    defer testing.allocator.free(stale_blob);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = sidecar_path_value, .data = stale_blob });

    try publishSymbolTableSidecar(testing.allocator, artifact_path, null);
    try testing.expect(!sidecarExistsForTest(sidecar_path_value));
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

test "mergeAndWriteSelectedSidecar fails when the prior blob is corrupt" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const sidecar_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe.zap-symbols" });
    defer testing.allocator.free(sidecar_path);

    // A bad-magic prior sidecar is artifact/debug state corruption. The
    // selected update must fail instead of deleting the sidecar and continuing.
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = sidecar_path, .data = &garbage });

    const rebuilt_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Beta.run__0", "Beta", "run", 0 },
    });
    defer testing.allocator.free(rebuilt_blob);

    const selected_structs = [_][]const u8{"Beta"};
    try testing.expectError(
        error.SymbolTableSidecarParseFailed,
        mergeAndWriteSelectedSidecar(
            testing.allocator,
            sidecar_path,
            rebuilt_blob,
            &selected_structs,
            false,
        ),
    );

    try testing.expect(sidecarExistsForTest(sidecar_path));
}

test "mergeAndWriteSelectedSidecar fails when the prior sidecar cannot be read" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const sidecar_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe.zap-symbols" });
    defer testing.allocator.free(sidecar_path);

    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, sidecar_path);

    const rebuilt_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Beta.run__0", "Beta", "run", 0 },
    });
    defer testing.allocator.free(rebuilt_blob);

    const selected_structs = [_][]const u8{"Beta"};
    try testing.expectError(
        error.SymbolTableSidecarReadFailed,
        mergeAndWriteSelectedSidecar(
            testing.allocator,
            sidecar_path,
            rebuilt_blob,
            &selected_structs,
            false,
        ),
    );
}

test "mergeAndWriteSelectedSidecar propagates merge encode failures" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const sidecar_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe.zap-symbols" });
    defer testing.allocator.free(sidecar_path);

    const baseline_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Alpha.keep__0", "Alpha", "keep", 0 },
    });
    defer testing.allocator.free(baseline_blob);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = sidecar_path, .data = baseline_blob });

    // Rebuilt bytes are adopted first and prior entries outside the selected
    // struct set are adopted next. A duplicate mangled name must surface as an
    // encode failure, not invalidate or overwrite the existing sidecar.
    const rebuilt_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Alpha.keep__0", "Alpha", "keep", 0 },
    });
    defer testing.allocator.free(rebuilt_blob);

    const selected_structs = [_][]const u8{"Beta"};
    try testing.expectError(
        error.DuplicateMangledName,
        mergeAndWriteSelectedSidecar(
            testing.allocator,
            sidecar_path,
            rebuilt_blob,
            &selected_structs,
            false,
        ),
    );

    const preserved = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        sidecar_path,
        testing.allocator,
        .limited(1 * 1024 * 1024),
    );
    defer testing.allocator.free(preserved);
    const reader = try zap_symbol_table.Reader.init(preserved);
    try testing.expectEqual(@as(u32, 1), reader.entry_count);
    try testing.expect(reader.findByMangled("Alpha.keep__0") != null);
}

test "mergeAndWriteSelectedSidecar leaves no sidecar for first-build no-symbols output" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const sidecar_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe.zap-symbols" });
    defer testing.allocator.free(sidecar_path);

    try mergeAndWriteSelectedSidecar(
        testing.allocator,
        sidecar_path,
        null,
        &.{},
        false,
    );
    try testing.expect(!sidecarExistsForTest(sidecar_path));
}

test "mergeAndWriteSelectedSidecar removes stale sidecar for selected no-symbols output" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const sidecar_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "probe.zap-symbols" });
    defer testing.allocator.free(sidecar_path);

    const baseline_blob = try encodeSymbolTableForTest(testing.allocator, &.{
        .{ "Beta.run__0", "Beta", "run", 0 },
    });
    defer testing.allocator.free(baseline_blob);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = sidecar_path, .data = baseline_blob });

    const selected_structs = [_][]const u8{"Beta"};
    try mergeAndWriteSelectedSidecar(
        testing.allocator,
        sidecar_path,
        null,
        &selected_structs,
        false,
    );
    try testing.expect(!sidecarExistsForTest(sidecar_path));
}

test "mergeAndWriteSelectedSidecar rejects missing prior sidecar when rebuild has symbols" {
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
    try testing.expectError(
        error.SymbolTableSidecarMissing,
        mergeAndWriteSelectedSidecar(
            testing.allocator,
            sidecar_path,
            rebuilt_blob,
            &selected_structs,
            false,
        ),
    );
    try testing.expect(!sidecarExistsForTest(sidecar_path));
}
