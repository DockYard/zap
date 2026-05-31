//! Memory manager build-time driver.
//!
//! Adapter-driven pluggable memory manager resolver — see
//! `docs/memory-manager-abi.md` section 10 for the normative build pipeline.
//!
//! The driver:
//!   1. Receives the manifest's `Memory.Manager` adapter binding as
//!      evaluated by build.zap CTFE.
//!   2. Resolves the manager backend source from the adapter method's
//!      package-relative source file. An adapter at `lib/foo/bar.zap`
//!      binds to the same package's `src/foo/bar/manager.zig`.
//!   3. Invokes the Zig-fork primitive `zap_fork_compile_zig_to_object`
//!      for every manager source, stdlib and project/dependency alike, then
//!      reads the object file, extracts the `.zapmem` section, and
//!      validates the meta header + core vtable + embedded descriptors
//!      per spec section 3.5.
//!   4. Exposes the resulting `ResolvedManager` to the compiler driver:
//!      `declared_caps` flows through HIR / codegen; the selected Zig
//!      backend source path is registered as `zap_active_manager` for the final
//!      binary; diagnostics refer to the selected manager type.
//!
//! The driver is build-time-only — it produces a `ResolvedManager` value
//! that the rest of the build pipeline (`src/main.zig`'s `buildTarget`)
//! reads. It does not touch the runtime; the runtime bootstrap (spec
//! section 10.2) is wired separately.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const section_parser = @import("section_parser.zig");
const progress_mod = @import("../progress.zig");

// ---------------------------------------------------------------------------
// Zig-fork primitive — extern declarations.
//
// The `libzap_compiler.a` static archive that Zap links against (see
// `build.zig`) exports `zap_fork_compile_zig_to_object` from
// `~/projects/zig/src/zir_api.zig`. Spec section 10.1.1 documents the
// normative signature.
// ---------------------------------------------------------------------------

/// Wire-format target descriptor. Fields mirror `std.Target.Cpu.Arch`,
/// `std.Target.Os.Tag`, and `std.Target.Abi`. v1.0 pins these enums in
/// the Zig fork; reserved field must be 0.
pub const ZapForkTarget = extern struct {
    arch_tag: u16,
    os_tag: u16,
    abi_tag: u16,
    _reserved: u16,
};

/// Sentinel that requests the host's native target. Spec Appendix C and
/// the Zig fork agree on the value `0xFFFF`.
pub const ZAP_FORK_ARCH_NATIVE: u16 = 0xFFFF;

pub const ZapForkOptimize = enum(c_int) {
    Debug = 0,
    ReleaseSafe = 1,
    ReleaseFast = 2,
    ReleaseSmall = 3,
};

pub const ZapForkResult = enum(c_int) {
    Ok = 0,
    SourceNotFound = 1,
    CompilationFailed = 2,
    TargetUnsupported = 3,
    InternalError = 99,
};

/// Function-pointer type matching the Zig fork primitive's C-ABI signature.
/// The driver invokes this indirectly so unit tests that do not link
/// `libzap_compiler.a` can substitute a mock.
pub const ForkCompileFn = *const fn (
    source_path: [*:0]const u8,
    target: *const ZapForkTarget,
    optimize: ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
    zig_lib_dir_opt: ?[*:0]const u8,
    local_cache_dir_opt: ?[*:0]const u8,
    global_cache_dir_opt: ?[*:0]const u8,
    /// Optional CPU model/feature set (mirrors `zig build`'s `-Dcpu=`).
    /// Null/"" ⇒ the resolved triple's default CPU. The manager `.o`
    /// is built for the SAME CPU as the user binary.
    cpu_features_opt: ?[*:0]const u8,
) callconv(.c) ZapForkResult;

/// The real Zig fork primitive, provided by `libzap_compiler.a` in the
/// production link. Declared only in non-test builds so the test binary
/// (`zig build test`), which does not link `libzap_compiler.a`, never
/// emits an undefined-symbol record for the primitive.
///
/// Tests are required to pass an explicit `fork_compile_fn` override via
/// `ResolveOptions`; in non-test builds the override is optional and the
/// driver falls back to this extern.
const default_fork_fn_or_null: ?ForkCompileFn = if (builtin.is_test) null else &zapForkCompileShim;

extern "c" fn zap_fork_compile_zig_to_object(
    source_path: [*:0]const u8,
    target: *const ZapForkTarget,
    optimize: ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
    zig_lib_dir_opt: ?[*:0]const u8,
    local_cache_dir_opt: ?[*:0]const u8,
    global_cache_dir_opt: ?[*:0]const u8,
    cpu_features_opt: ?[*:0]const u8,
) callconv(.c) ZapForkResult;

/// Thin shim that the driver invokes through `default_fork_fn_or_null`.
/// Splitting through a shim ensures the extern symbol reference appears
/// in only one compilation unit and gives a single attribution point in
/// the linker output if the symbol is missing.
fn zapForkCompileShim(
    source_path: [*:0]const u8,
    target: *const ZapForkTarget,
    optimize: ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
    zig_lib_dir_opt: ?[*:0]const u8,
    local_cache_dir_opt: ?[*:0]const u8,
    global_cache_dir_opt: ?[*:0]const u8,
    cpu_features_opt: ?[*:0]const u8,
) callconv(.c) ZapForkResult {
    return zap_fork_compile_zig_to_object(
        source_path,
        target,
        optimize,
        out_object_path,
        out_diagnostic_buffer,
        out_diagnostic_capacity,
        zig_lib_dir_opt,
        local_cache_dir_opt,
        global_cache_dir_opt,
        cpu_features_opt,
    );
}

/// Resolve the default fork-compile function pointer. Returns `null` in
/// test builds (so reaching it without an override is a clear bug).
/// Returns the linked-in primitive in production builds.
fn resolveDefaultForkFn() ?ForkCompileFn {
    return default_fork_fn_or_null;
}

// ---------------------------------------------------------------------------
// Driver types
// ---------------------------------------------------------------------------

/// Binding returned by the selected `Memory.Manager` protocol adapter.
/// The build driver consumes this value instead of inspecting Zap source
/// attributes or accepting manager-provided source paths.
pub const AdapterMetadata = struct {
    /// Concrete manager type selected by `Zap.Manifest.memory`.
    type_name: []const u8,
    /// Source file that declared the adapter type, when source reflection
    /// could recover it during build.zap CTFE.
    adapter_source_path: ?[]const u8 = null,
};

/// Resolved state of the active manager, threaded from the build driver
/// through to the link step and runtime bootstrap.
pub const ResolvedManager = struct {
    /// Concrete manager type selected by the manifest.
    type_name: []const u8,

    /// Absolute path to the selected manager's Zig backend source.
    /// The backend registers this file as `zap_active_manager`.
    active_manager_source_path: []const u8,

    /// Capability bitmask resolved from the validated `.zapmem` core
    /// vtable.
    /// Phase 6 (codegen elision) reads this to decide whether to emit
    /// retain/release calls; Phase 4 (Map/List/String layout branch)
    /// reads it to decide whether the inline ArcHeader is present.
    declared_caps: u64,

    /// ABI minor version declared by the manager. Phase 3 records this
    /// for diagnostic context; runtime validation rejects majors that
    /// don't match the compiler's (currently 1).
    abi_minor: u16,

    /// True when the validated REFCOUNT_V1 descriptor is at least the
    /// v1.1 size that exposes the side-table extension slots.
    refcount_sized_extension: bool,
};

const MANAGER_VALIDATION_CACHE_SCHEMA = "zap.manager.validation.cache.v2";
const MANAGER_VALIDATION_SIDECAR_MAGIC: u32 = 0x4d_56_43_5a; // "ZCVM" little-endian
const MANAGER_VALIDATION_SIDECAR_VERSION: u16 = 2;
const MANAGER_VALIDATION_SIDECAR_LEN: usize = 216;
const TOOLCHAIN_IDENTITY_DIGEST_LEN: usize = std.crypto.hash.sha2.Sha256.digest_length;
const ToolchainIdentityDigest = [TOOLCHAIN_IDENTITY_DIGEST_LEN]u8;

/// Lightweight, owned resolution of the selected manager backend source.
///
/// This is the part of `resolve()` that is safe to run before a build
/// artifact cache check: it validates the manifest-provided adapter
/// binding and resolves the package-convention backend source path, but
/// does not create cache directories, compile a validation object, read
/// `.zapmem`, or inspect object symbols.
pub const ManagerSourceSelection = struct {
    /// Concrete manager type selected by the manifest.
    type_name: []const u8,

    /// Absolute path to the selected manager's Zig backend source.
    active_manager_source_path: []const u8,
};

/// Driver-level errors. Each variant maps to a build-time diagnostic in
/// the normative table from spec section 10.4.
pub const ResolveError = error{
    /// The manifest did not provide an evaluated `Memory.Manager` binding.
    MissingMemoryManagerAdapter,
    /// The adapter source could not be mapped to a package backend.
    InvalidManagerBackendSource,
    /// The Zig backend source file for the adapter could not be opened.
    ManagerSourceNotFound,
    /// Compilation of the manager source failed; the build driver
    /// surfaces the diagnostic text.
    ManagerCompileFailed,
    /// Object file written by the Zig fork could not be opened.
    ObjectReadFailed,
    /// `.zapmem` section is absent, truncated, or malformed.
    SectionInvalid,
    /// Magic mismatch — manager metadata is not `'ZMEM'`.
    BadMagic,
    /// ABI major mismatch against the compiler's supported major (1).
    AbiMajorMismatch,
    /// One of the static validation rules in spec section 3.5 failed
    /// (size too small, declared_caps disagreement, reserved field
    /// non-zero, embedded descriptor for undeclared capability, etc.).
    ValidationFailed,
    /// A reserved-but-unimplemented capability bit was declared.
    ReservedCapabilityDeclared,
    /// The selected manager declares a capability that is sound to
    /// *compile* for the cross-compile target but unsound to *select*
    /// there because a required runtime backend is missing for that
    /// target (e.g. a TRACED/conservative-GC manager on a COFF/PE target
    /// that has no global-segment scanner). This is the forward-compatible
    /// selection gate: a build-time error today (keyed on `-Dmemory` +
    /// `-Dtarget`), and the same compatibility predicate becomes the
    /// runtime spawn-error once per-process spawn-time manager selection
    /// lands. The manager's source still compiles for the target, so it
    /// remains linkable for the managers a future binary CAN use there.
    ManagerTargetUnsupported,
    /// Internal driver error (allocator, filesystem) not described above.
    InternalError,
    OutOfMemory,
};

/// Diagnostic buffer threaded through the driver; populated on every error
/// path so the build orchestrator can surface a clear message.
pub const DriverDiagnostic = struct {
    /// Caller-owned scratch buffer. The driver writes a NUL-terminated
    /// UTF-8 message and truncates if necessary.
    buffer: []u8,
    /// Number of bytes written (excluding the NUL terminator).
    written: usize = 0,

    pub fn write(self: *DriverDiagnostic, comptime fmt: []const u8, args: anytype) void {
        if (self.buffer.len == 0) return;
        const printed = std.fmt.bufPrint(self.buffer[0 .. self.buffer.len - 1], fmt, args) catch {
            self.buffer[self.buffer.len - 1] = 0;
            self.written = self.buffer.len - 1;
            return;
        };
        self.written = printed.len;
        self.buffer[printed.len] = 0;
    }

    pub fn text(self: *const DriverDiagnostic) []const u8 {
        return self.buffer[0..self.written];
    }
};

/// Source root for the driver — the same shape used by
/// `zap.discovery.SourceRoot`. We redeclare it locally so this module can
/// remain a leaf import without depending on discovery.
pub const SourceRoot = struct {
    /// Logical name (e.g. `"project"`, `"zap_stdlib"`, `"dep:foo"`).
    name: []const u8,
    /// Absolute or workspace-relative path to a directory the driver may
    /// use to identify the selected adapter's package.
    path: []const u8,
};

/// Inputs passed to `resolve`.
pub const ResolveOptions = struct {
    /// Binding produced by evaluating the selected `Memory.Manager`
    /// adapter through CTFE.
    adapter: ?AdapterMetadata,
    /// Source roots available to project, stdlib, and dependency
    /// adapter source discovery.
    source_roots: []const SourceRoot = &.{},
    /// Project root.
    project_root: []const u8,
    /// Path to the Zap source tree's root (e.g. `/Users/.../zap`).
    /// May be the same as `project_root` when building Zap itself.
    zap_source_root: []const u8,
    /// Directory the driver writes the compiled manager `.o` into.
    /// Created if it does not exist.
    cache_dir: []const u8,
    /// Optional Zig stdlib directory passed through to the fork primitive.
    /// When null the primitive auto-detects.
    zig_lib_dir: ?[]const u8 = null,
    /// Identity digest for the running Zap compiler / Zig fork toolchain.
    /// Production call sites must pass the already-computed value from
    /// `src/main.zig`; test-only defaults are accepted so focused unit
    /// tests can construct minimal options without a full toolchain
    /// identity scan.
    compiler_identity_digest: ?ToolchainIdentityDigest = null,
    /// Identity digest for the Zig stdlib directory used by the fork.
    /// Production call sites must pass the already-computed value from
    /// `src/main.zig`; test-only defaults are accepted alongside
    /// `compiler_identity_digest`.
    zig_lib_identity_digest: ?ToolchainIdentityDigest = null,
    /// Optimize mode forwarded to the fork primitive.
    optimize: ZapForkOptimize = .ReleaseSafe,
    /// Cross-compile target triple (e.g. `"aarch64-linux-gnu"`). Null
    /// means "native": the manager `.o` is compiled for the host. When
    /// the build's `compile_target` is set, the driver must pass the
    /// matching `ZapForkTarget` to the fork primitive so the manager
    /// `.o` matches the final binary's target. Phase 1's
    /// `isSupportedTriple` whitelist gates which triples are accepted;
    /// unsupported triples surface as `ResolveError.ManagerCompileFailed`
    /// with the primitive's diagnostic text in `diag`.
    target: ?[]const u8 = null,
    /// Optional CPU model/feature set (mirrors `zig build`'s `-Dcpu=`,
    /// e.g. `"baseline"`, `"apple_m1"`). Null/"" ⇒ the resolved
    /// triple's default CPU. Threaded into the fork primitive so the
    /// manager `.o` is built for the SAME CPU as the user binary; an
    /// unparsable CPU surfaces as `ResolveError.ManagerCompileFailed`
    /// with the primitive's diagnostic text in `diag`.
    cpu: ?[]const u8 = null,
    /// Optional override for the fork compile function. When null the
    /// driver invokes the real `libzap_compiler.a` extern. Tests pass a
    /// mock that synthesises an object file without needing the LLVM
    /// stack. Production builds (the `zap` binary) always leave this
    /// null so the real fork primitive runs.
    fork_compile_fn: ?ForkCompileFn = null,
    /// Optional CLI progress reporter owned by the build command.
    progress: ?*progress_mod.Reporter = null,
};

/// Resolve the active memory manager for the build. Returns a
/// `ResolvedManager` whose lifetime is bound to the caller's allocator.
pub fn resolve(
    allocator: std.mem.Allocator,
    options: ResolveOptions,
    diag: *DriverDiagnostic,
) ResolveError!ResolvedManager {
    var source_selection = try resolveManagerSource(allocator, options, diag);
    errdefer freeManagerSourceSelection(allocator, &source_selection);

    const identities = try resolveCacheIdentities(options, diag);

    // Compile selected manager sources into keyed validation objects.
    // The object is build-time evidence only; the final binary registers
    // the backend source path as `zap_active_manager` and does not link
    // this validation object.
    if (options.progress) |progress| progress.stage("Memory: preparing manager validation cache", .{});
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, options.cache_dir) catch {};
    var cache_entry = try managerValidationCacheEntry(allocator, source_selection, options, identities, diag);
    defer cache_entry.deinit(allocator);

    if (try readValidationSidecar(allocator, cache_entry.sidecar_path, cache_entry.record_identity)) |metadata| {
        if (options.progress) |progress| progress.stage("Memory: using cached manager metadata", .{});
        try enforceManagerTargetSupport(source_selection.type_name, metadata.declared_caps, options, diag);
        return resolvedFromValidation(source_selection, metadata);
    }

    const validation_from_object = validateManagerObjectAtPath(
        allocator,
        source_selection.type_name,
        cache_entry.object_path,
        diag,
    ) catch |err| switch (err) {
        ResolveError.ObjectReadFailed,
        ResolveError.SectionInvalid,
        ResolveError.BadMagic,
        ResolveError.AbiMajorMismatch,
        ResolveError.ValidationFailed,
        ResolveError.ReservedCapabilityDeclared,
        => null,
        else => return err,
    };
    if (validation_from_object) |metadata| {
        try writeValidationSidecar(allocator, cache_entry.sidecar_path, cache_entry.record_identity, metadata);
        try enforceManagerTargetSupport(source_selection.type_name, metadata.declared_caps, options, diag);
        return resolvedFromValidation(source_selection, metadata);
    }

    if (options.progress) |progress| {
        progress.stage("Memory: compiling manager object", .{});
        progress.commitLine();
    }
    try compileManagerSource(
        allocator,
        source_selection.type_name,
        source_selection.active_manager_source_path,
        cache_entry.object_path,
        options,
        diag,
    );

    const validated = try validateManagerObjectAtPath(
        allocator,
        source_selection.type_name,
        cache_entry.object_path,
        diag,
    );
    try writeValidationSidecar(allocator, cache_entry.sidecar_path, cache_entry.record_identity, validated);

    try enforceManagerTargetSupport(source_selection.type_name, validated.declared_caps, options, diag);
    return resolvedFromValidation(source_selection, validated);
}

fn resolvedFromValidation(
    source_selection: ManagerSourceSelection,
    validated: ValidatedSection,
) ResolvedManager {
    return .{
        .type_name = source_selection.type_name,
        .active_manager_source_path = source_selection.active_manager_source_path,
        .declared_caps = validated.declared_caps,
        .abi_minor = validated.abi_minor,
        .refcount_sized_extension = validated.refcount_sized_extension,
    };
}

/// Forward-compatible manager × target soundness gate.
///
/// Runs after validation (so the manager's declared capabilities are
/// known) and before `resolve` returns, on BOTH the cache-hit and
/// freshly-compiled paths. The manager's source has already compiled for
/// the target at this point — the gate rejects *selecting* it, not
/// *building* it, so the backend stays linkable for a future binary that
/// monomorphises a different manager at a spawn site.
///
/// The check is **capability-driven**, not keyed on a manager type name:
/// it reasons about the `declared_caps` the driver already reads from the
/// validated `.zapmem` section. Today the only unsound combination is a
/// TRACED (conservative stop-the-world mark-sweep) manager on a Windows
/// (COFF/PE) target: `src/memory/gc/manager.zig`'s `scanGlobals` has no
/// COFF/PE global-segment backend (it no-ops, so a global holding the
/// sole reference to a heap object would be reclaimed — silent
/// corruption), and Windows additionally needs TIB-based stack bounds
/// that are not yet wired. Any future tracing manager that declares
/// TRACED inherits the same correct gate automatically.
///
/// `selected_type_name` is used only to make the diagnostic actionable;
/// the gate *decision* depends solely on the capability and the target.
fn enforceManagerTargetSupport(
    selected_type_name: []const u8,
    declared_caps: u64,
    options: ResolveOptions,
    diag: *DriverDiagnostic,
) ResolveError!void {
    const target_triple = options.target orelse return; // native host: GC is supported (ELF/Mach-O backends exist)
    const target = parseTargetTriple(target_triple) orelse return; // malformed triples are surfaced later by the compile path
    const os_tag = enumFromTag(std.Target.Os.Tag, target.os_tag) orelse return;

    const reclamation_model =
        (declared_caps >> abi.RECLAMATION_MODEL_SHIFT) & abi.RECLAMATION_MODEL_MASK;
    const is_traced = reclamation_model == abi.RECLAMATION_TRACED;

    // The only currently-unsound combination: TRACED × Windows (COFF/PE).
    if (is_traced and os_tag == .windows) {
        diag.write(
            "{s} is unsupported on {s}: conservative global/stack scanning has no COFF/PE backend yet; use Memory.ARC, Memory.Arena, Memory.Leak, Memory.NoOp, or Memory.Tracking",
            .{ selected_type_name, target_triple },
        );
        return ResolveError.ManagerTargetUnsupported;
    }
}

/// Map a wire-format enum tag (`u16`) back to its `std.Target` enum value.
/// Returns null for an unrecognised tag.
fn enumFromTag(comptime E: type, tag: u16) ?E {
    return inline for (@typeInfo(E).@"enum".fields) |f| {
        if (f.value == tag) break @field(E, f.name);
    } else null;
}

fn validateManagerObjectAtPath(
    allocator: std.mem.Allocator,
    manager_name: []const u8,
    object_path: []const u8,
    diag: *DriverDiagnostic,
) ResolveError!ValidatedSection {
    // Read the resulting object file and locate the `.zapmem` section.
    const object_bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        object_path,
        allocator,
        .limited(64 * 1024 * 1024),
    ) catch {
        diag.write("could not read compiled manager object at '{s}'", .{object_path});
        return ResolveError.ObjectReadFailed;
    };
    defer allocator.free(object_bytes);

    const section_bytes = section_parser.extractSection(object_bytes) catch |err| {
        switch (err) {
            error.SectionNotFound => diag.write(
                "manager '{s}' did not emit a `.zapmem` metadata section; see docs/memory-manager-abi.md section 3",
                .{manager_name},
            ),
            error.SectionTooSmall => diag.write(
                "manager '{s}' emitted a `.zapmem` section smaller than the v1.0 metadata header (32 bytes)",
                .{manager_name},
            ),
            error.InvalidObject => diag.write(
                "manager '{s}' produced a malformed object file at '{s}'",
                .{ manager_name, object_path },
            ),
            error.UnsupportedFormat => diag.write(
                "manager '{s}' object file uses an unsupported format (Phase 3 supports ELF and Mach-O 64-bit)",
                .{manager_name},
            ),
        }
        return ResolveError.SectionInvalid;
    };

    // Static validation per spec section 3.5.
    const validated = try validateSection(manager_name, section_bytes, diag);

    // Build-time check: source registration later binds
    // `zap_active_manager.zap_memory_section`; the validation object
    // must export the same section payload symbol.
    try assertExportsManagerSymbol(manager_name, object_bytes, diag);
    return validated;
}

/// Free the owned memory inside a `ResolvedManager`. Safe to call once.
pub fn freeResolved(allocator: std.mem.Allocator, resolved: *ResolvedManager) void {
    allocator.free(resolved.type_name);
    allocator.free(resolved.active_manager_source_path);
    resolved.type_name = "";
    resolved.active_manager_source_path = "";
}

/// Resolve only the selected manager backend source. The returned
/// strings are owned by `allocator` and must be released with
/// `freeManagerSourceSelection`.
pub fn resolveManagerSource(
    allocator: std.mem.Allocator,
    options: ResolveOptions,
    diag: *DriverDiagnostic,
) ResolveError!ManagerSourceSelection {
    const adapter = options.adapter orelse {
        diag.write("build manifest did not evaluate a `Memory.Manager` adapter", .{});
        return ResolveError.MissingMemoryManagerAdapter;
    };
    if (adapter.type_name.len == 0) {
        diag.write("selected `Memory.Manager` adapter returned an empty manager type", .{});
        return ResolveError.InvalidManagerBackendSource;
    }

    const type_name = allocator.dupe(u8, adapter.type_name) catch return ResolveError.OutOfMemory;
    errdefer allocator.free(type_name);
    const manager_source_path = try resolveBackendSourcePath(allocator, adapter, options, diag);
    errdefer allocator.free(manager_source_path);

    return .{
        .type_name = type_name,
        .active_manager_source_path = manager_source_path,
    };
}

/// Free the owned memory inside a `ManagerSourceSelection`. Safe to call once.
pub fn freeManagerSourceSelection(allocator: std.mem.Allocator, selection: *ManagerSourceSelection) void {
    allocator.free(selection.type_name);
    allocator.free(selection.active_manager_source_path);
    selection.type_name = "";
    selection.active_manager_source_path = "";
}

// ---------------------------------------------------------------------------
// Manager backend source resolution
// ---------------------------------------------------------------------------

fn resolveBackendSourcePath(
    allocator: std.mem.Allocator,
    adapter: AdapterMetadata,
    options: ResolveOptions,
    diag: *DriverDiagnostic,
) ResolveError![]const u8 {
    const adapter_source_path = adapter.adapter_source_path orelse {
        diag.write(
            "memory manager adapter '{s}' did not provide a source-backed backend binding",
            .{adapter.type_name},
        );
        return ResolveError.InvalidManagerBackendSource;
    };

    const backend_path = backendPathForAdapterSource(allocator, adapter_source_path, options) catch |err| switch (err) {
        error.OutOfMemory => return ResolveError.OutOfMemory,
        error.InvalidSourcePath => {
            diag.write(
                "memory manager adapter '{s}' must be declared in a `.zap` package source file, got '{s}'",
                .{ adapter.type_name, adapter_source_path },
            );
            return ResolveError.InvalidManagerBackendSource;
        },
    };
    errdefer allocator.free(backend_path);

    std.Io.Dir.cwd().access(std.Options.debug_io, backend_path, .{}) catch {
        diag.write(
            "memory manager backend for '{s}' not found; expected package backend file '{s}'",
            .{ adapter.type_name, backend_path },
        );
        return ResolveError.ManagerSourceNotFound;
    };

    const canonical = canonicalPathOrSelf(allocator, backend_path) catch return ResolveError.OutOfMemory;
    allocator.free(backend_path);
    return canonical;
}

const BackendPathError = error{ OutOfMemory, InvalidSourcePath };

fn backendPathForAdapterSource(
    allocator: std.mem.Allocator,
    adapter_source_path: []const u8,
    options: ResolveOptions,
) BackendPathError![]const u8 {
    if (!std.mem.endsWith(u8, adapter_source_path, ".zap")) return error.InvalidSourcePath;
    const location = try adapterPackageLocation(allocator, adapter_source_path, options);
    defer allocator.free(location.package_root);
    defer allocator.free(location.relative_source_path);

    const source_stem = location.relative_source_path[0 .. location.relative_source_path.len - ".zap".len];
    if (source_stem.len == 0) return error.InvalidSourcePath;
    return std.fs.path.join(allocator, &.{ location.package_root, "src", source_stem, "manager.zig" }) catch
        return error.OutOfMemory;
}

const AdapterPackageLocation = struct {
    package_root: []const u8,
    relative_source_path: []const u8,
};

fn adapterPackageLocation(
    allocator: std.mem.Allocator,
    adapter_source_path: []const u8,
    options: ResolveOptions,
) BackendPathError!AdapterPackageLocation {
    var best_package_source_root: ?[]const u8 = null;
    var best_location: ?AdapterPackageLocation = null;

    for (options.source_roots) |source_root| {
        const package_source_root = packageSourceRootForSearch(allocator, source_root.path) catch return error.OutOfMemory;
        defer allocator.free(package_source_root);
        const relative_source_path = (try relativePathUnderRoot(allocator, adapter_source_path, package_source_root)) orelse continue;
        errdefer allocator.free(relative_source_path);
        if (best_package_source_root) |best_root| {
            if (package_source_root.len <= best_root.len) {
                allocator.free(relative_source_path);
                continue;
            }
            allocator.free(best_root);
            allocator.free(best_location.?.package_root);
            allocator.free(best_location.?.relative_source_path);
        }
        const package_root = packageRootFromSourceRoot(allocator, package_source_root) catch return error.OutOfMemory;
        best_package_source_root = allocator.dupe(u8, package_source_root) catch return error.OutOfMemory;
        best_location = .{
            .package_root = package_root,
            .relative_source_path = relative_source_path,
        };
    }

    if (best_location) |location| {
        allocator.free(best_package_source_root.?);
        return location;
    }

    if (try relativePathUnderRoot(allocator, adapter_source_path, options.project_root)) |relative_source_path| {
        return .{
            .package_root = canonicalPathOrSelf(allocator, options.project_root) catch return error.OutOfMemory,
            .relative_source_path = relative_source_path,
        };
    }
    if (try relativePathUnderRoot(allocator, adapter_source_path, options.zap_source_root)) |relative_source_path| {
        return .{
            .package_root = canonicalPathOrSelf(allocator, options.zap_source_root) catch return error.OutOfMemory,
            .relative_source_path = relative_source_path,
        };
    }

    return error.InvalidSourcePath;
}

fn packageSourceRootForSearch(allocator: std.mem.Allocator, source_root: []const u8) ![]const u8 {
    const canonical_root = try canonicalPathOrSelf(allocator, source_root);
    defer allocator.free(canonical_root);

    var current: ?[]const u8 = canonical_root;
    while (current) |path| {
        const basename = std.fs.path.basename(path);
        if (std.mem.eql(u8, basename, "lib") or
            std.mem.eql(u8, basename, "test") or
            std.mem.eql(u8, basename, "tools"))
        {
            return allocator.dupe(u8, path);
        }
        current = std.fs.path.dirname(path);
    }

    return allocator.dupe(u8, canonical_root);
}

fn relativePathUnderRoot(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    root_path: []const u8,
) BackendPathError!?[]const u8 {
    const canonical_file = canonicalPathOrSelf(allocator, file_path) catch return error.OutOfMemory;
    defer allocator.free(canonical_file);
    const canonical_root = canonicalPathOrSelf(allocator, root_path) catch return error.OutOfMemory;
    defer allocator.free(canonical_root);

    if (std.mem.eql(u8, canonical_file, canonical_root)) return null;

    const root_with_sep = std.fmt.allocPrint(allocator, "{s}{c}", .{ canonical_root, std.fs.path.sep }) catch
        return error.OutOfMemory;
    defer allocator.free(root_with_sep);
    if (!std.mem.startsWith(u8, canonical_file, root_with_sep)) return null;
    return allocator.dupe(u8, canonical_file[root_with_sep.len..]) catch return error.OutOfMemory;
}

fn packageRootFromSourceRoot(allocator: std.mem.Allocator, source_root: []const u8) ![]const u8 {
    const canonical_root = try canonicalPathOrSelf(allocator, source_root);
    errdefer allocator.free(canonical_root);
    const basename = std.fs.path.basename(canonical_root);
    if (std.mem.eql(u8, basename, "lib") or
        std.mem.eql(u8, basename, "test") or
        std.mem.eql(u8, basename, "tools"))
    {
        const parent = std.fs.path.dirname(canonical_root) orelse canonical_root;
        const out = try allocator.dupe(u8, parent);
        allocator.free(canonical_root);
        return out;
    }
    return canonical_root;
}

fn canonicalPathOrSelf(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, allocator) catch
        return std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(real_path);
    return allocator.dupe(u8, real_path);
}

// ---------------------------------------------------------------------------
// Manager validation artifact cache
// ---------------------------------------------------------------------------

const CacheIdentities = struct {
    compiler_identity_digest: ToolchainIdentityDigest,
    zig_lib_identity_digest: ToolchainIdentityDigest,
};

const ManagerValidationRecordIdentity = struct {
    key_digest: [32]u8,
    source_content_digest: [32]u8,
    manager_name_hash: u64,
    source_path_hash: u64,
    zig_lib_path_hash: u64,
    target_hash: u64,
    cpu_hash: u64,
    host_arch_hash: u64,
    host_os_hash: u64,
    host_abi_hash: u64,
    compiler_identity_digest: ToolchainIdentityDigest,
    zig_lib_identity_digest: ToolchainIdentityDigest,
    optimize_tag: u8,
    target_is_native: bool,
};

const ManagerValidationCacheEntry = struct {
    object_path: []const u8,
    sidecar_path: []const u8,
    record_identity: ManagerValidationRecordIdentity,

    fn deinit(self: *ManagerValidationCacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.object_path);
        allocator.free(self.sidecar_path);
    }
};

fn resolveCacheIdentities(options: ResolveOptions, diag: *DriverDiagnostic) ResolveError!CacheIdentities {
    const compiler_identity_digest = options.compiler_identity_digest orelse blk: {
        if (builtin.is_test) {
            break :blk zeroToolchainIdentityDigest();
        } else {
            diag.write(
                "memory manager driver: production resolve omitted compiler identity digest",
                .{},
            );
            return ResolveError.InternalError;
        }
    };
    const zig_lib_identity_digest = options.zig_lib_identity_digest orelse blk: {
        if (builtin.is_test) {
            break :blk zeroToolchainIdentityDigest();
        } else {
            diag.write(
                "memory manager driver: production resolve omitted Zig lib identity digest",
                .{},
            );
            return ResolveError.InternalError;
        }
    };
    return .{
        .compiler_identity_digest = compiler_identity_digest,
        .zig_lib_identity_digest = zig_lib_identity_digest,
    };
}

fn managerValidationCacheEntry(
    allocator: std.mem.Allocator,
    source_selection: ManagerSourceSelection,
    options: ResolveOptions,
    identities: CacheIdentities,
    diag: *DriverDiagnostic,
) ResolveError!ManagerValidationCacheEntry {
    const source_bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        source_selection.active_manager_source_path,
        allocator,
        .limited(64 * 1024 * 1024),
    ) catch {
        diag.write(
            "memory manager backend source for '{s}' could not be read at '{s}'",
            .{ source_selection.type_name, source_selection.active_manager_source_path },
        );
        return ResolveError.ManagerSourceNotFound;
    };
    defer allocator.free(source_bytes);

    const source_content_digest = sha256Digest(source_bytes);
    const target_descriptor = try targetDescriptorForOptions(source_selection.type_name, options, diag);
    const zig_lib_path = options.zig_lib_dir orelse "";
    const cpu = options.cpu orelse "";
    const host_arch = @tagName(builtin.cpu.arch);
    const host_os = @tagName(builtin.os.tag);
    const host_abi = @tagName(builtin.abi);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, MANAGER_VALIDATION_CACHE_SCHEMA);
    hashField(&hasher, source_selection.type_name);
    hashField(&hasher, source_selection.active_manager_source_path);
    hasher.update(&source_content_digest);
    hashInt(&hasher, @as(u8, @intCast(@intFromEnum(options.optimize))));
    hashBool(&hasher, target_descriptor.is_native);
    hashField(&hasher, target_descriptor.identity_text);
    hashInt(&hasher, target_descriptor.target.arch_tag);
    hashInt(&hasher, target_descriptor.target.os_tag);
    hashInt(&hasher, target_descriptor.target.abi_tag);
    hashField(&hasher, cpu);
    hashField(&hasher, zig_lib_path);
    hasher.update(&identities.zig_lib_identity_digest);
    hasher.update(&identities.compiler_identity_digest);
    if (target_descriptor.is_native) {
        hashField(&hasher, host_arch);
        hashField(&hasher, host_os);
        hashField(&hasher, host_abi);
    }
    var key_digest: [32]u8 = undefined;
    hasher.final(&key_digest);

    var key_hex_buf: [64]u8 = undefined;
    const key_hex = digestHex(&key_hex_buf, key_digest);
    const safe_name = try makeSafeFileName(allocator, source_selection.type_name);
    defer allocator.free(safe_name);
    const object_basename = std.fmt.allocPrint(
        allocator,
        "{s}-{s}.o",
        .{ safe_name, key_hex },
    ) catch return ResolveError.OutOfMemory;
    defer allocator.free(object_basename);
    const sidecar_basename = std.fmt.allocPrint(
        allocator,
        "{s}-{s}.zapmem",
        .{ safe_name, key_hex },
    ) catch return ResolveError.OutOfMemory;
    defer allocator.free(sidecar_basename);

    const object_path = std.fs.path.join(allocator, &.{ options.cache_dir, object_basename }) catch return ResolveError.OutOfMemory;
    errdefer allocator.free(object_path);
    const sidecar_path = std.fs.path.join(allocator, &.{ options.cache_dir, sidecar_basename }) catch return ResolveError.OutOfMemory;

    return .{
        .object_path = object_path,
        .sidecar_path = sidecar_path,
        .record_identity = .{
            .key_digest = key_digest,
            .source_content_digest = source_content_digest,
            .manager_name_hash = stableHash(source_selection.type_name),
            .source_path_hash = stableHash(source_selection.active_manager_source_path),
            .zig_lib_path_hash = stableHash(zig_lib_path),
            .target_hash = stableHash(target_descriptor.identity_text),
            .cpu_hash = stableHash(cpu),
            .host_arch_hash = stableHash(host_arch),
            .host_os_hash = stableHash(host_os),
            .host_abi_hash = stableHash(host_abi),
            .compiler_identity_digest = identities.compiler_identity_digest,
            .zig_lib_identity_digest = identities.zig_lib_identity_digest,
            .optimize_tag = @intCast(@intFromEnum(options.optimize)),
            .target_is_native = target_descriptor.is_native,
        },
    };
}

const TargetDescriptor = struct {
    target: ZapForkTarget,
    identity_text: []const u8,
    is_native: bool,
};

fn targetDescriptorForOptions(
    manager_name: []const u8,
    options: ResolveOptions,
    diag: *DriverDiagnostic,
) ResolveError!TargetDescriptor {
    if (options.target) |triple| {
        return .{
            .target = parseTargetTriple(triple) orelse {
                diag.write(
                    "memory manager '{s}' could not build for cross-compile target '{s}': unrecognised triple (expected arch-os-abi)",
                    .{ manager_name, triple },
                );
                return ResolveError.ManagerCompileFailed;
            },
            .identity_text = triple,
            .is_native = false,
        };
    }

    return .{
        .target = .{
            .arch_tag = ZAP_FORK_ARCH_NATIVE,
            .os_tag = 0,
            .abi_tag = 0,
            ._reserved = 0,
        },
        .identity_text = "native",
        .is_native = true,
    };
}

fn readValidationSidecar(
    allocator: std.mem.Allocator,
    sidecar_path: []const u8,
    identity: ManagerValidationRecordIdentity,
) ResolveError!?ValidatedSection {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        sidecar_path,
        allocator,
        .limited(MANAGER_VALIDATION_SIDECAR_LEN + 1),
    ) catch |err| switch (err) {
        error.OutOfMemory => return ResolveError.OutOfMemory,
        else => return null,
    };
    defer allocator.free(bytes);
    if (bytes.len != MANAGER_VALIDATION_SIDECAR_LEN) return null;

    var cursor: usize = 0;
    if (readScalar(u32, bytes, &cursor) != MANAGER_VALIDATION_SIDECAR_MAGIC) return null;
    if (readScalar(u16, bytes, &cursor) != MANAGER_VALIDATION_SIDECAR_VERSION) return null;
    if (readScalar(u8, bytes, &cursor) != 0) return null;
    const refcount_sized_extension = switch (readScalar(u8, bytes, &cursor)) {
        0 => false,
        1 => true,
        else => return null,
    };

    if (!std.mem.eql(u8, bytes[cursor..][0..32], &identity.key_digest)) return null;
    cursor += 32;
    if (!std.mem.eql(u8, bytes[cursor..][0..32], &identity.source_content_digest)) return null;
    cursor += 32;
    if (readScalar(u64, bytes, &cursor) != identity.manager_name_hash) return null;
    if (readScalar(u64, bytes, &cursor) != identity.source_path_hash) return null;
    if (readScalar(u64, bytes, &cursor) != identity.zig_lib_path_hash) return null;
    if (readScalar(u64, bytes, &cursor) != identity.target_hash) return null;
    if (readScalar(u64, bytes, &cursor) != identity.cpu_hash) return null;
    if (readScalar(u64, bytes, &cursor) != identity.host_arch_hash) return null;
    if (readScalar(u64, bytes, &cursor) != identity.host_os_hash) return null;
    if (readScalar(u64, bytes, &cursor) != identity.host_abi_hash) return null;
    if (!std.mem.eql(u8, bytes[cursor..][0..TOOLCHAIN_IDENTITY_DIGEST_LEN], &identity.compiler_identity_digest)) return null;
    cursor += TOOLCHAIN_IDENTITY_DIGEST_LEN;
    if (!std.mem.eql(u8, bytes[cursor..][0..TOOLCHAIN_IDENTITY_DIGEST_LEN], &identity.zig_lib_identity_digest)) return null;
    cursor += TOOLCHAIN_IDENTITY_DIGEST_LEN;
    if (readScalar(u8, bytes, &cursor) != identity.optimize_tag) return null;
    if ((readScalar(u8, bytes, &cursor) != 0) != identity.target_is_native) return null;
    if (readScalar(u16, bytes, &cursor) != 0) return null;

    const declared_caps = readScalar(u64, bytes, &cursor);
    const abi_minor = readScalar(u16, bytes, &cursor);
    if (readScalar(u16, bytes, &cursor) != 0) return null;
    if (cursor != MANAGER_VALIDATION_SIDECAR_LEN) return null;
    return .{
        .declared_caps = declared_caps,
        .abi_minor = abi_minor,
        .refcount_sized_extension = refcount_sized_extension,
    };
}

fn writeValidationSidecar(
    allocator: std.mem.Allocator,
    sidecar_path: []const u8,
    identity: ManagerValidationRecordIdentity,
    metadata: ValidatedSection,
) ResolveError!void {
    var bytes: [MANAGER_VALIDATION_SIDECAR_LEN]u8 = undefined;
    var cursor: usize = 0;
    writeScalar(u32, &bytes, &cursor, MANAGER_VALIDATION_SIDECAR_MAGIC);
    writeScalar(u16, &bytes, &cursor, MANAGER_VALIDATION_SIDECAR_VERSION);
    writeScalar(u8, &bytes, &cursor, 0);
    writeScalar(u8, &bytes, &cursor, if (metadata.refcount_sized_extension) 1 else 0);
    @memcpy(bytes[cursor..][0..32], &identity.key_digest);
    cursor += 32;
    @memcpy(bytes[cursor..][0..32], &identity.source_content_digest);
    cursor += 32;
    writeScalar(u64, &bytes, &cursor, identity.manager_name_hash);
    writeScalar(u64, &bytes, &cursor, identity.source_path_hash);
    writeScalar(u64, &bytes, &cursor, identity.zig_lib_path_hash);
    writeScalar(u64, &bytes, &cursor, identity.target_hash);
    writeScalar(u64, &bytes, &cursor, identity.cpu_hash);
    writeScalar(u64, &bytes, &cursor, identity.host_arch_hash);
    writeScalar(u64, &bytes, &cursor, identity.host_os_hash);
    writeScalar(u64, &bytes, &cursor, identity.host_abi_hash);
    @memcpy(bytes[cursor..][0..TOOLCHAIN_IDENTITY_DIGEST_LEN], &identity.compiler_identity_digest);
    cursor += TOOLCHAIN_IDENTITY_DIGEST_LEN;
    @memcpy(bytes[cursor..][0..TOOLCHAIN_IDENTITY_DIGEST_LEN], &identity.zig_lib_identity_digest);
    cursor += TOOLCHAIN_IDENTITY_DIGEST_LEN;
    writeScalar(u8, &bytes, &cursor, identity.optimize_tag);
    writeScalar(u8, &bytes, &cursor, if (identity.target_is_native) 1 else 0);
    writeScalar(u16, &bytes, &cursor, 0);
    writeScalar(u64, &bytes, &cursor, metadata.declared_caps);
    writeScalar(u16, &bytes, &cursor, metadata.abi_minor);
    writeScalar(u16, &bytes, &cursor, 0);
    std.debug.assert(cursor == MANAGER_VALIDATION_SIDECAR_LEN);
    writeFileAtomic(allocator, sidecar_path, &bytes) catch return ResolveError.InternalError;
}

fn writeFileAtomic(
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
) !void {
    _ = allocator;
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);
    }
    var atomic = try std.Io.Dir.cwd().createFileAtomic(std.Options.debug_io, path, .{
        .replace = true,
        .make_path = true,
    });
    defer atomic.deinit(std.Options.debug_io);
    atomic.file.writeStreamingAll(std.Options.debug_io, contents) catch |err| {
        atomic.file.close(std.Options.debug_io);
        atomic.file_open = false;
        return err;
    };
    try atomic.replace(std.Options.debug_io);
}

fn sha256Digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

fn zeroToolchainIdentityDigest() ToolchainIdentityDigest {
    return [_]u8{0} ** TOOLCHAIN_IDENTITY_DIGEST_LEN;
}

fn testToolchainIdentityDigest(byte: u8) ToolchainIdentityDigest {
    return [_]u8{byte} ** TOOLCHAIN_IDENTITY_DIGEST_LEN;
}

fn digestHex(buffer: *[64]u8, digest: [32]u8) []const u8 {
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        buffer[index * 2] = alphabet[byte >> 4];
        buffer[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return buffer[0..];
}

fn stableHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    hashInt(hasher, bytes.len);
    hasher.update(bytes);
}

fn hashBool(hasher: *std.crypto.hash.sha2.Sha256, value: bool) void {
    hasher.update(&[_]u8{if (value) 1 else 0});
}

fn hashInt(hasher: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    const bytes = std.mem.asBytes(&value);
    hasher.update(bytes);
}

fn writeScalar(comptime T: type, bytes: []u8, cursor: *usize, value: T) void {
    @memcpy(bytes[cursor.*..][0..@sizeOf(T)], std.mem.asBytes(&value));
    cursor.* += @sizeOf(T);
}

fn readScalar(comptime T: type, bytes: []const u8, cursor: *usize) T {
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[cursor.*..][0..@sizeOf(T)]);
    cursor.* += @sizeOf(T);
    return value;
}

// ---------------------------------------------------------------------------
// Compile manager via the Zig fork primitive
// ---------------------------------------------------------------------------

fn compileManagerSource(
    allocator: std.mem.Allocator,
    manager_name: []const u8,
    source_path: []const u8,
    object_path: []const u8,
    options: ResolveOptions,
    diag: *DriverDiagnostic,
) ResolveError!void {
    const source_z = allocator.dupeZ(u8, source_path) catch return ResolveError.OutOfMemory;
    defer allocator.free(source_z);
    const object_z = allocator.dupeZ(u8, object_path) catch return ResolveError.OutOfMemory;
    defer allocator.free(object_z);
    const zig_lib_z: ?[*:0]const u8 = if (options.zig_lib_dir) |p| blk: {
        const dup = allocator.dupeZ(u8, p) catch return ResolveError.OutOfMemory;
        break :blk dup.ptr;
    } else null;
    defer if (zig_lib_z) |p| allocator.free(std.mem.span(p));
    const cache_dir_z = allocator.dupeZ(u8, options.cache_dir) catch return ResolveError.OutOfMemory;
    defer allocator.free(cache_dir_z);

    // When the build is cross-compiling (`compile_target` is set on
    // the manifest), pass the matching `ZapForkTarget` to the fork
    // primitive so the manager `.o` matches the binary's target.
    // Otherwise pass the NATIVE sentinel — the fork's
    // `isSupportedTriple` whitelist gates which native hosts are
    // accepted.
    const target = (try targetDescriptorForOptions(manager_name, options, diag)).target;

    // Diagnostic buffer threaded into the fork primitive. We size it
    // generously so multi-error bundles fit; the primitive truncates and
    // adds a marker if necessary.
    var fork_diag_buf: [4096]u8 = undefined;
    fork_diag_buf[0] = 0;

    const fork_fn: ForkCompileFn = options.fork_compile_fn orelse (resolveDefaultForkFn() orelse {
        diag.write(
            "memory manager driver: no fork compile function available (test build without explicit override?)",
            .{},
        );
        return ResolveError.InternalError;
    });

    // Null-terminated CPU string for the fork primitive. Empty/absent
    // ⇒ pass null so the resolved triple's default CPU is used. A
    // non-empty value builds the manager `.o` for the SAME CPU as the
    // user binary so every object in the final link agrees.
    const cpu_z: ?[:0]const u8 = if (options.cpu) |c|
        (if (c.len == 0) null else (allocator.dupeZ(u8, c) catch return ResolveError.OutOfMemory))
    else
        null;
    defer if (cpu_z) |p| allocator.free(p);

    const result = fork_fn(
        source_z.ptr,
        &target,
        options.optimize,
        object_z.ptr,
        &fork_diag_buf,
        fork_diag_buf.len,
        zig_lib_z,
        cache_dir_z.ptr,
        cache_dir_z.ptr,
        if (cpu_z) |p| p.ptr else null,
    );

    switch (result) {
        .Ok => return,
        .SourceNotFound => {
            diag.write(
                "memory manager source not found at '{s}' for adapter '{s}'",
                .{ source_path, manager_name },
            );
            return ResolveError.ManagerSourceNotFound;
        },
        .CompilationFailed => {
            const fork_text = std.mem.sliceTo(&fork_diag_buf, 0);
            diag.write(
                "compilation of memory manager '{s}' failed:\n{s}",
                .{ manager_name, fork_text },
            );
            return ResolveError.ManagerCompileFailed;
        },
        .TargetUnsupported => {
            const fork_text = std.mem.sliceTo(&fork_diag_buf, 0);
            diag.write(
                "memory manager '{s}' target unsupported: {s}",
                .{ manager_name, fork_text },
            );
            return ResolveError.ManagerCompileFailed;
        },
        .InternalError => {
            const fork_text = std.mem.sliceTo(&fork_diag_buf, 0);
            diag.write(
                "internal error compiling memory manager '{s}': {s}",
                .{ manager_name, fork_text },
            );
            return ResolveError.InternalError;
        },
    }
}

fn makeSafeFileName(allocator: std.mem.Allocator, manager_name: []const u8) ![]const u8 {
    var out = try allocator.alloc(u8, manager_name.len);
    for (manager_name, 0..) |c, i| {
        out[i] = if (c == '.' or c == '/' or c == ':') '_' else c;
    }
    return out;
}

/// Parse a Zap cross-compile target triple of the form
/// `arch-os-abi` (e.g. `"aarch64-linux-gnu"`) into a `ZapForkTarget`.
/// Returns null when the string is not well-formed or any of the three
/// segments fails to resolve to a known `std.Target.*` enum value.
/// Tag-validity is enforced here; whether the resulting triple is in
/// the v1.0 supported whitelist is decided downstream by the fork
/// primitive's `isSupportedTriple`.
fn parseTargetTriple(triple: []const u8) ?ZapForkTarget {
    var iter = std.mem.tokenizeAny(u8, triple, "-");
    const arch_str = iter.next() orelse return null;
    const os_str = iter.next() orelse return null;
    const abi_str = iter.next() orelse return null;
    if (iter.next() != null) return null; // exactly 3 segments

    const arch_tag = enumTag(std.Target.Cpu.Arch, arch_str) orelse return null;
    const os_tag = enumTag(std.Target.Os.Tag, os_str) orelse return null;
    const abi_tag = enumTag(std.Target.Abi, abi_str) orelse return null;

    return .{
        .arch_tag = @intCast(arch_tag),
        .os_tag = @intCast(os_tag),
        .abi_tag = @intCast(abi_tag),
        ._reserved = 0,
    };
}

/// Look up an enum's integer tag value by case-insensitive name match.
/// Returns null when no field's `@tagName` matches the input.
fn enumTag(comptime E: type, name: []const u8) ?usize {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(field.name, name)) {
            return @intCast(field.value);
        }
    }
    return null;
}

test "manager backend binding resolves package src backend from adapter source" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "pkg/lib/memory") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "pkg/src/memory/custom") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "pkg/lib/memory/custom.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "pkg/src/memory/custom/manager.zig", .data = "// backend" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);

    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    const adapter_path = try std.fs.path.join(allocator, &.{ tmp_path, "pkg/lib/memory/custom.zap" });
    defer allocator.free(adapter_path);
    const source_root_path = try std.fs.path.join(allocator, &.{ tmp_path, "pkg/lib" });
    defer allocator.free(source_root_path);
    const source_roots = [_]SourceRoot{.{ .name = "pkg", .path = source_root_path }};
    const backend_path = try resolveBackendSourcePath(allocator, .{
        .type_name = "ThirdParty.Custom",
        .adapter_source_path = adapter_path,
    }, .{
        .adapter = null,
        .source_roots = &source_roots,
        .project_root = tmp_path,
        .zap_source_root = tmp_path,
        .cache_dir = "",
    }, &diag);
    defer allocator.free(backend_path);
    try std.testing.expect(std.mem.endsWith(u8, backend_path, "pkg/src/memory/custom/manager.zig"));
}

test "manager source selection resolves backend without validation artifacts" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "pkg/lib/memory") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "pkg/src/memory/custom") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "pkg/lib/memory/custom.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "pkg/src/memory/custom/manager.zig", .data = "// backend" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const adapter_path = try std.fs.path.join(allocator, &.{ tmp_path, "pkg/lib/memory/custom.zap" });
    defer allocator.free(adapter_path);
    const source_root_path = try std.fs.path.join(allocator, &.{ tmp_path, "pkg/lib" });
    defer allocator.free(source_root_path);
    const cache_root = try std.fs.path.join(allocator, &.{ tmp_path, "cache" });
    defer allocator.free(cache_root);
    const source_roots = [_]SourceRoot{.{ .name = "pkg", .path = source_root_path }};

    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    var selection = try resolveManagerSource(allocator, .{
        .adapter = .{
            .type_name = "ThirdParty.Custom",
            .adapter_source_path = adapter_path,
        },
        .source_roots = &source_roots,
        .project_root = tmp_path,
        .zap_source_root = tmp_path,
        .cache_dir = cache_root,
    }, &diag);
    defer freeManagerSourceSelection(allocator, &selection);

    try std.testing.expectEqualStrings("ThirdParty.Custom", selection.type_name);
    try std.testing.expect(std.mem.endsWith(u8, selection.active_manager_source_path, "pkg/src/memory/custom/manager.zig"));
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.access(std.Options.debug_io, "cache", .{}));
}

test "resolve uses the same selected manager source as lightweight resolution" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "pkg/lib/memory") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "pkg/src/memory/custom") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "pkg/lib/memory/custom.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "pkg/src/memory/custom/manager.zig", .data = "// backend" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const adapter_path = try std.fs.path.join(allocator, &.{ tmp_path, "pkg/lib/memory/custom.zap" });
    defer allocator.free(adapter_path);
    const source_root_path = try std.fs.path.join(allocator, &.{ tmp_path, "pkg/lib" });
    defer allocator.free(source_root_path);
    const cache_root = try std.fs.path.join(allocator, &.{ tmp_path, "cache" });
    defer allocator.free(cache_root);
    const source_roots = [_]SourceRoot{.{ .name = "pkg", .path = source_root_path }};
    const options: ResolveOptions = .{
        .adapter = .{
            .type_name = "ThirdParty.Custom",
            .adapter_source_path = adapter_path,
        },
        .source_roots = &source_roots,
        .project_root = tmp_path,
        .zap_source_root = tmp_path,
        .cache_dir = cache_root,
        .fork_compile_fn = mockForkCompileNoOp,
    };

    var selection_diag_buf: [512]u8 = undefined;
    var selection_diag: DriverDiagnostic = .{ .buffer = &selection_diag_buf };
    var selection = try resolveManagerSource(allocator, options, &selection_diag);
    defer freeManagerSourceSelection(allocator, &selection);

    var resolve_diag_buf: [1024]u8 = undefined;
    var resolve_diag: DriverDiagnostic = .{ .buffer = &resolve_diag_buf };
    var resolved = try resolve(allocator, options, &resolve_diag);
    defer freeResolved(allocator, &resolved);

    try std.testing.expectEqualStrings(selection.type_name, resolved.type_name);
    try std.testing.expectEqualStrings(selection.active_manager_source_path, resolved.active_manager_source_path);
    try std.testing.expectEqual(@as(u64, 0), resolved.declared_caps);
}

test "manager backend binding rejects missing source and non-zap adapters" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    tmp_dir.dir.createDirPath(std.Options.debug_io, "pkg/lib/memory") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "pkg/lib/memory/missing.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "pkg/lib/memory/not_zap.txt", .data = "// adapter" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const source_root_path = try std.fs.path.join(allocator, &.{ tmp_path, "pkg/lib" });
    defer allocator.free(source_root_path);
    const source_roots = [_]SourceRoot{.{ .name = "pkg", .path = source_root_path }};
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    const missing_adapter_path = try std.fs.path.join(allocator, &.{ tmp_path, "pkg/lib/memory/missing.zap" });
    defer allocator.free(missing_adapter_path);
    try std.testing.expectError(
        ResolveError.ManagerSourceNotFound,
        resolveBackendSourcePath(allocator, .{
            .type_name = "Missing.Manager",
            .adapter_source_path = missing_adapter_path,
        }, .{
            .adapter = null,
            .source_roots = &source_roots,
            .project_root = tmp_path,
            .zap_source_root = tmp_path,
            .cache_dir = "",
        }, &diag),
    );

    const invalid_adapter_path = try std.fs.path.join(allocator, &.{ tmp_path, "pkg/lib/memory/not_zap.txt" });
    defer allocator.free(invalid_adapter_path);
    try std.testing.expectError(
        ResolveError.InvalidManagerBackendSource,
        resolveBackendSourcePath(allocator, .{
            .type_name = "ThirdParty.Custom",
            .adapter_source_path = invalid_adapter_path,
        }, .{
            .adapter = null,
            .source_roots = &source_roots,
            .project_root = tmp_path,
            .zap_source_root = tmp_path,
            .cache_dir = "",
        }, &diag),
    );
}

test "parseTargetTriple accepts a well-formed triple" {
    const t = parseTargetTriple("aarch64-linux-gnu") orelse return error.UnexpectedNull;
    try std.testing.expectEqual(@as(u16, @intCast(@intFromEnum(std.Target.Cpu.Arch.aarch64))), t.arch_tag);
    try std.testing.expectEqual(@as(u16, @intCast(@intFromEnum(std.Target.Os.Tag.linux))), t.os_tag);
    try std.testing.expectEqual(@as(u16, @intCast(@intFromEnum(std.Target.Abi.gnu))), t.abi_tag);
    try std.testing.expectEqual(@as(u16, 0), t._reserved);
}

test "parseTargetTriple rejects malformed input" {
    try std.testing.expectEqual(@as(?ZapForkTarget, null), parseTargetTriple("aarch64-linux"));
    try std.testing.expectEqual(@as(?ZapForkTarget, null), parseTargetTriple("aarch64-linux-gnu-extra"));
    try std.testing.expectEqual(@as(?ZapForkTarget, null), parseTargetTriple("not-a-real-arch"));
}

// ---------------------------------------------------------------------------
// Manager-symbol check (spec section 3.2 / 10.5)
// ---------------------------------------------------------------------------

/// Spec-mandated symbol name for the section payload. See the
/// `zap_memory_section` exports in `src/memory/no_op/manager.zig`,
/// `src/memory/arena/manager.zig`, and the runtime's weak-extern
/// resolution in `src/runtime.zig#externalMemorySection`.
const MANAGER_SYMBOL_NAME = "zap_memory_section";

/// Verify the object's symbol table contains a `zap_memory_section`
/// entry. The section validator above only inspects the section
/// contents; without this complementary check, a manager that emitted
/// the section bytes under a different symbol name would link cleanly
/// but resolve the runtime weak-extern to null at startup. Phase 4
/// ripped the in-runtime ARC stub out entirely, so a null weak
/// extern in a production binary now means the first
/// `ArcRuntime.allocAny` / `retainAny` / `releaseAny` / `headerRetain`
/// / `headerRelease` dispatch panics with "dispatched with no active
/// memory manager". Catching the symbol-name mismatch at build time
/// gives a much better diagnostic than that runtime panic.
fn assertExportsManagerSymbol(
    manager_name: []const u8,
    object_bytes: []const u8,
    diag: *DriverDiagnostic,
) ResolveError!void {
    const found = managerSymbolPresent(object_bytes) catch |err| {
        switch (err) {
            error.UnsupportedFormat => {
                // ELF and Mach-O 64-bit are the production targets;
                // any other object format here was already rejected by
                // `section_parser.extractSection`. Reaching this branch
                // means the parser accepted bytes the symbol-check
                // refuses; treat as malformed.
                diag.write(
                    "manager '{s}' object file uses an unsupported format for symbol-table inspection",
                    .{manager_name},
                );
                return ResolveError.SectionInvalid;
            },
            error.InvalidObject => {
                diag.write(
                    "manager '{s}' has a malformed object header (symbol-table check)",
                    .{manager_name},
                );
                return ResolveError.SectionInvalid;
            },
        }
    };
    if (!found) {
        diag.write(
            "manager '{s}' does not export the required symbol '{s}'; every manager MUST export its section payload under this name (see docs/memory-manager-abi.md section 3.2)",
            .{ manager_name, MANAGER_SYMBOL_NAME },
        );
        return ResolveError.ValidationFailed;
    }
}

/// Public alias for `assertExportsManagerSymbol`. Exposes the symbol
/// check to out-of-tree smoke tests (see `scripts/test_manager_compile.sh`)
/// that need to invoke the same code path the build driver runs at link
/// time without going through the full `resolve()` pipeline.
pub fn assertExportsManagerSymbolForTest(
    manager_name: []const u8,
    object_bytes: []const u8,
    diag: *DriverDiagnostic,
) ResolveError!void {
    return assertExportsManagerSymbol(manager_name, object_bytes, diag);
}

const SymbolCheckError = error{
    UnsupportedFormat,
    InvalidObject,
};

/// Walk the object's symbol table and return `true` iff
/// `zap_memory_section` is present. Supports ELF64, Mach-O 64-bit, and
/// COFF — the same formats `section_parser.extractSection` handles.
fn managerSymbolPresent(bytes: []const u8) SymbolCheckError!bool {
    return switch (section_parser.detectFormat(bytes)) {
        .elf => elfSymbolPresent(bytes, MANAGER_SYMBOL_NAME),
        .macho => machoSymbolPresent(bytes, MANAGER_SYMBOL_NAME),
        .coff => coffSymbolPresent(bytes, MANAGER_SYMBOL_NAME),
        .unknown => SymbolCheckError.InvalidObject,
    };
}

fn elfSymbolPresent(bytes: []const u8, want: []const u8) SymbolCheckError!bool {
    var hdr_reader = std.Io.Reader.fixed(bytes);
    const header = std.elf.Header.read(&hdr_reader) catch return SymbolCheckError.InvalidObject;
    if (header.shnum == 0) return false;

    // Walk the section header table once, looking for `SYMTAB`/`DYNSYM`
    // entries. The previous implementation pre-buffered all headers into
    // a fixed-size array which silently failed for objects with > 256
    // sections (real Zig-compiled objects regularly exceed this via
    // per-function `.text.*` and debug sections). The new implementation
    // walks the table via direct byte arithmetic — `shoff + index *
    // shentsize` — so it scales with `shnum`. Each symbol-table section
    // dereferences its string table by index via the same arithmetic, so
    // there is no upper bound beyond what the spec/header itself allows.
    const shdr_size: u64 = if (header.is_64) @sizeOf(std.elf.Elf64_Shdr) else @sizeOf(std.elf.Elf32_Shdr);
    const total_shdr_bytes = shdr_size * @as(u64, header.shnum);
    if (total_shdr_bytes > bytes.len or header.shoff > bytes.len - total_shdr_bytes) {
        return SymbolCheckError.InvalidObject;
    }

    var it = header.iterateSectionHeadersBuffer(bytes);
    var idx: u16 = 0;
    while (true) : (idx += 1) {
        const maybe = it.next() catch return SymbolCheckError.InvalidObject;
        const sh = maybe orelse break;
        if (sh.sh_type != @intFromEnum(std.elf.SHT.SYMTAB) and
            sh.sh_type != @intFromEnum(std.elf.SHT.DYNSYM))
        {
            continue;
        }
        if (sh.sh_link >= header.shnum) return SymbolCheckError.InvalidObject;
        const strtab_sh = readSectionHeader(&header, bytes, @intCast(sh.sh_link)) catch
            return SymbolCheckError.InvalidObject;
        if (strtab_sh.sh_size > bytes.len or
            strtab_sh.sh_offset > bytes.len - strtab_sh.sh_size)
        {
            return SymbolCheckError.InvalidObject;
        }
        const strtab = bytes[@intCast(strtab_sh.sh_offset)..][0..@intCast(strtab_sh.sh_size)];

        if (sh.sh_entsize == 0) return SymbolCheckError.InvalidObject;
        if (sh.sh_size > bytes.len or sh.sh_offset > bytes.len - sh.sh_size) {
            return SymbolCheckError.InvalidObject;
        }
        const sym_bytes = bytes[@intCast(sh.sh_offset)..][0..@intCast(sh.sh_size)];
        const ent_size: usize = @intCast(sh.sh_entsize);
        if (ent_size < @sizeOf(std.elf.Elf64_Sym)) return SymbolCheckError.InvalidObject;
        const n = sym_bytes.len / ent_size;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var sym: std.elf.Elf64_Sym = undefined;
            @memcpy(std.mem.asBytes(&sym), sym_bytes[i * ent_size ..][0..@sizeOf(std.elf.Elf64_Sym)]);
            const name = elfSymbolName(strtab, sym.st_name) orelse continue;
            if (std.mem.eql(u8, name, want)) return true;
        }
    }
    return false;
}

/// Read a single section header by index from the buffered object.
/// Replaces the previous "pre-buffer all headers into a fixed array"
/// pattern, which capped at 256 entries. Uses the same byte arithmetic
/// as `std.elf.SectionHeaderBufferIterator` (offset = `shoff + index *
/// shentsize`).
fn readSectionHeader(
    header: *const std.elf.Header,
    bytes: []const u8,
    index: u16,
) !std.elf.Elf64_Shdr {
    if (index >= header.shnum) return error.InvalidIndex;
    const shdr_size: u64 = if (header.is_64) @sizeOf(std.elf.Elf64_Shdr) else @sizeOf(std.elf.Elf32_Shdr);
    const offset: u64 = header.shoff + shdr_size * @as(u64, index);
    if (offset > bytes.len or shdr_size > bytes.len - offset) return error.OutOfBounds;
    var reader = std.Io.Reader.fixed(bytes[@intCast(offset)..]);
    return std.elf.takeSectionHeader(&reader, header.is_64, header.endian);
}

fn elfSymbolName(strtab: []const u8, offset: u32) ?[]const u8 {
    if (offset >= strtab.len) return null;
    const start: usize = offset;
    var end: usize = start;
    while (end < strtab.len and strtab[end] != 0) : (end += 1) {}
    return strtab[start..end];
}

fn machoSymbolPresent(bytes: []const u8, want: []const u8) SymbolCheckError!bool {
    if (bytes.len < @sizeOf(std.macho.mach_header_64)) return SymbolCheckError.InvalidObject;
    var header: std.macho.mach_header_64 = undefined;
    @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(std.macho.mach_header_64)]);
    if (header.magic != std.macho.MH_MAGIC_64 and header.magic != std.macho.MH_CIGAM_64) {
        return SymbolCheckError.UnsupportedFormat;
    }
    const swap = header.magic == std.macho.MH_CIGAM_64;
    var ncmds: u32 = if (swap) @byteSwap(header.ncmds) else header.ncmds;

    var cursor: usize = @sizeOf(std.macho.mach_header_64);
    while (ncmds > 0) : (ncmds -= 1) {
        if (@sizeOf(std.macho.load_command) > bytes.len or
            cursor > bytes.len - @sizeOf(std.macho.load_command))
        {
            return SymbolCheckError.InvalidObject;
        }
        var lc: std.macho.load_command = undefined;
        @memcpy(std.mem.asBytes(&lc), bytes[cursor..][0..@sizeOf(std.macho.load_command)]);
        const lc_cmd_raw: u32 = if (swap) @byteSwap(@intFromEnum(lc.cmd)) else @intFromEnum(lc.cmd);
        const lc_size: u32 = if (swap) @byteSwap(lc.cmdsize) else lc.cmdsize;
        if (lc_size < @sizeOf(std.macho.load_command)) return SymbolCheckError.InvalidObject;
        if (lc_size > bytes.len or cursor > bytes.len - lc_size) return SymbolCheckError.InvalidObject;

        if (lc_cmd_raw == @intFromEnum(std.macho.LC.SYMTAB)) {
            if (lc_size < @sizeOf(std.macho.symtab_command)) return SymbolCheckError.InvalidObject;
            var symtab: std.macho.symtab_command = undefined;
            @memcpy(std.mem.asBytes(&symtab), bytes[cursor..][0..@sizeOf(std.macho.symtab_command)]);
            const symoff: u32 = if (swap) @byteSwap(symtab.symoff) else symtab.symoff;
            const nsyms: u32 = if (swap) @byteSwap(symtab.nsyms) else symtab.nsyms;
            const stroff: u32 = if (swap) @byteSwap(symtab.stroff) else symtab.stroff;
            const strsize: u32 = if (swap) @byteSwap(symtab.strsize) else symtab.strsize;

            if (@as(usize, stroff) > bytes.len or @as(usize, strsize) > bytes.len - stroff) {
                return SymbolCheckError.InvalidObject;
            }
            const strtab = bytes[stroff..][0..strsize];

            const sym_total: usize = @as(usize, nsyms) * @sizeOf(std.macho.nlist_64);
            if (@as(usize, symoff) > bytes.len or sym_total > bytes.len - symoff) {
                return SymbolCheckError.InvalidObject;
            }
            const sym_bytes = bytes[symoff..][0..sym_total];

            var i: usize = 0;
            while (i < nsyms) : (i += 1) {
                var nl: std.macho.nlist_64 = undefined;
                @memcpy(std.mem.asBytes(&nl), sym_bytes[i * @sizeOf(std.macho.nlist_64) ..][0..@sizeOf(std.macho.nlist_64)]);
                const n_strx_raw = nl.n_strx;
                const n_strx: u32 = if (swap) @byteSwap(n_strx_raw) else n_strx_raw;
                const name = machoSymbolName(strtab, n_strx) orelse continue;
                // Mach-O exported C symbols are prefixed with `_`. Match
                // both the bare name and the underscored form.
                if (std.mem.eql(u8, name, want)) return true;
                if (name.len > 0 and name[0] == '_' and std.mem.eql(u8, name[1..], want)) return true;
            }
            // We found the symtab; whether or not the wanted symbol
            // was inside it, no other LC_SYMTAB will appear.
            return false;
        }

        cursor += lc_size;
    }
    return false;
}

fn machoSymbolName(strtab: []const u8, offset: u32) ?[]const u8 {
    if (offset >= strtab.len) return null;
    const start: usize = offset;
    var end: usize = start;
    while (end < strtab.len and strtab[end] != 0) : (end += 1) {}
    return strtab[start..end];
}

/// COFF symbol-table walk. Zig emits a raw COFF object whose symbol table
/// sits at `pointer_to_symbol_table` with `number_of_symbols` records of
/// 18 bytes each, immediately followed by the string table (4-byte size
/// prefix + NUL-terminated names). The manager symbol `zap_memory_section`
/// is 18 bytes (> 8), so it is always carried via the string-table form
/// (`name[0..4] == 0`, `name[4..8]` = offset). We resolve both the inline
/// and string-table name forms for robustness, and match the bare name as
/// well as a leading-underscore variant (x86_64 Windows uses bare C names;
/// i386 prefixes `_`).
///
/// Each symbol record may be followed by `number_of_aux_symbols` auxiliary
/// records (also 18 bytes); those are skipped so a multi-section symbol's
/// aux data is not misread as a symbol name.
fn coffSymbolPresent(bytes: []const u8, want: []const u8) SymbolCheckError!bool {
    if (bytes.len < @sizeOf(std.coff.Header)) return SymbolCheckError.InvalidObject;
    var header: std.coff.Header = undefined;
    @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(std.coff.Header)]);

    // No symbol table ⇒ the symbol cannot be present.
    if (header.pointer_to_symbol_table == 0) return false;

    const symbol_stride: usize = 18; // std.coff.Symbol.sizeOf()
    const symtab_offset: usize = header.pointer_to_symbol_table;
    const symbol_count: usize = header.number_of_symbols;
    const symtab_bytes = std.math.mul(usize, symbol_count, symbol_stride) catch
        return SymbolCheckError.InvalidObject;
    if (symtab_bytes > bytes.len or symtab_offset > bytes.len - symtab_bytes) {
        return SymbolCheckError.InvalidObject;
    }

    // String table: 4-byte little-endian size prefix (inclusive) directly
    // after the symbol table.
    const strtab_offset = symtab_offset + symtab_bytes;
    const string_table: []const u8 = blk: {
        if (strtab_offset + 4 > bytes.len) break :blk &.{};
        const declared = std.mem.readInt(u32, bytes[strtab_offset..][0..4], .little);
        if (declared < 4 or @as(usize, declared) > bytes.len - strtab_offset) break :blk &.{};
        break :blk bytes[strtab_offset..][0..@as(usize, declared)];
    };

    var index: usize = 0;
    while (index < symbol_count) {
        const record = bytes[symtab_offset + index * symbol_stride ..][0..symbol_stride];
        // Auxiliary-record count is the last byte of the 18-byte record.
        const aux_count: usize = record[17];

        const name: ?[]const u8 = if (std.mem.eql(u8, record[0..4], "\x00\x00\x00\x00")) name_blk: {
            // String-table form: bytes [4..8] are the offset.
            const name_offset = std.mem.readInt(u32, record[4..8], .little);
            break :name_blk coffSymbolName(string_table, name_offset);
        } else inline_blk: {
            const field = record[0..8];
            const len = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
            break :inline_blk field[0..len];
        };

        if (name) |n| {
            if (std.mem.eql(u8, n, want)) return true;
            if (n.len > 0 and n[0] == '_' and std.mem.eql(u8, n[1..], want)) return true;
        }

        // Advance past this symbol and its aux records (overflow-safe).
        index = std.math.add(usize, index, 1 + aux_count) catch return SymbolCheckError.InvalidObject;
    }
    return false;
}

fn coffSymbolName(strtab: []const u8, offset: u32) ?[]const u8 {
    if (offset >= strtab.len) return null;
    const start: usize = offset;
    var end: usize = start;
    while (end < strtab.len and strtab[end] != 0) : (end += 1) {}
    return strtab[start..end];
}

// ---------------------------------------------------------------------------
// Section validation (spec section 3.5)
// ---------------------------------------------------------------------------

const ValidatedSection = struct {
    declared_caps: u64,
    abi_minor: u16,
    refcount_sized_extension: bool,
};

/// Axis-aware validation of a manager's `declared_caps` value.
///
/// `declared_caps` is the structured capability bitmask (`src/memory/abi.zig`):
/// the REFCOUNT_V1 flag (bit 0), the Axis-A reclamation-model field (bits
/// 1..2), and the Axis-B sharing-strategy bit (bit 3). This enforces the
/// model's well-formedness at build time so a malformed or future-ABI manager
/// is rejected with a clear diagnostic rather than mis-driving codegen:
///
///   * **Unknown bits** — any bit outside `KNOWN_CAPS_MASK` (bits 4..63) is
///     reserved and unimplemented (`ReservedCapabilityDeclared`).
///   * **Reserved Axis-A codes** — only the `0b11` code carries no assigned
///     model; it is rejected (`ReservedCapabilityDeclared`). `BULK_OR_NEVER`
///     (`0b00`), `INDIVIDUAL_NO_REFCOUNT` (`0b01`), and `TRACED` (`0b10`) are
///     all defined and accepted. `TRACED` (the conservative tracing-GC model,
///     plan Phase 5) reuses the `BULK_OR_NEVER` codegen contract — no
///     retain/release/free, no `ArcHeader` — and the GC manager reclaims at
///     runtime, so accepting it needs no new compiler emission.
///   * **Inconsistent combos** (`ValidationFailed`):
///       - `REFCOUNT_V1` (bit 0) set but the Axis-A field is not the
///         `REFCOUNTED` encoding (`0b00`) — a manager cannot be both
///         refcounted and a free-model.
///       - The Axis-B `MOVE_ONLY` bit set when Axis A is not
///         `INDIVIDUAL_NO_REFCOUNT` — sharing strategy is meaningless for the
///         other reclamation models.
fn validateDeclaredCaps(
    manager_name: []const u8,
    declared_caps: u64,
    diag: *DriverDiagnostic,
) ResolveError!void {
    // 1. Unknown / still-reserved bits outside the defined axes (bits 4..63).
    if ((declared_caps & ~abi.KNOWN_CAPS_MASK) != 0) {
        diag.write(
            "manager '{s}' declares a reserved-but-unimplemented capability bit (declared_caps=0x{x}, known-bit mask=0x{x})",
            .{ manager_name, declared_caps, abi.KNOWN_CAPS_MASK },
        );
        return ResolveError.ReservedCapabilityDeclared;
    }

    const refcount_v1 = (declared_caps & abi.REFCOUNT_V1_BIT) != 0;
    const axis_a = (declared_caps >> abi.RECLAMATION_MODEL_SHIFT) & abi.RECLAMATION_MODEL_MASK;
    const move_only = (declared_caps & abi.SHARING_MOVE_ONLY_BIT) != 0;

    // 2a. Consistency: REFCOUNT_V1 implies the REFCOUNTED Axis-A encoding.
    if (refcount_v1 and axis_a != abi.RECLAMATION_REFCOUNTED) {
        diag.write(
            "manager '{s}' declares REFCOUNT_V1 (bit 0) but Axis-A reclamation field is 0b{b:0>2}, not REFCOUNTED (declared_caps=0x{x})",
            .{ manager_name, axis_a, declared_caps },
        );
        return ResolveError.ValidationFailed;
    }

    // 2b. Reserved Axis-A codes. When bit 0 is clear the field selects the
    // free model; BULK_OR_NEVER, INDIVIDUAL_NO_REFCOUNT, and TRACED are all
    // defined and accepted, while 0b11 is undefined and rejected. (When bit 0
    // is set, 2a already forced the field to 0b00.) TRACED's codegen contract
    // is byte-identical to BULK_OR_NEVER — the compiler elides every
    // retain/release/free and lays out no `ArcHeader`, and the tracing-GC
    // manager reclaims at runtime (plan Phase 5). Immutability means there are
    // no write barriers to emit and a conservative collector needs no compiler
    // root maps or safepoints, so accepting the model requires no new emission.
    if (!refcount_v1) {
        switch (axis_a) {
            abi.RECLAMATION_BULK_OR_NEVER,
            abi.RECLAMATION_INDIVIDUAL_NO_REFCOUNT,
            abi.RECLAMATION_TRACED,
            => {},
            abi.RECLAMATION_RESERVED => {
                diag.write(
                    "manager '{s}' declares the reserved Axis-A reclamation code 0b11, which has no assigned model (declared_caps=0x{x})",
                    .{ manager_name, declared_caps },
                );
                return ResolveError.ReservedCapabilityDeclared;
            },
            else => unreachable, // 2-bit field; the arms above are exhaustive.
        }
    }

    // 3. Axis B (MOVE_ONLY) is only meaningful for INDIVIDUAL_NO_REFCOUNT.
    if (move_only and (refcount_v1 or axis_a != abi.RECLAMATION_INDIVIDUAL_NO_REFCOUNT)) {
        diag.write(
            "manager '{s}' sets the Axis-B MOVE_ONLY sharing bit (bit 3) but Axis A is not INDIVIDUAL_NO_REFCOUNT (declared_caps=0x{x})",
            .{ manager_name, declared_caps },
        );
        return ResolveError.ValidationFailed;
    }
}

fn validateSection(
    manager_name: []const u8,
    section_bytes: []const u8,
    diag: *DriverDiagnostic,
) ResolveError!ValidatedSection {
    if (section_bytes.len < @sizeOf(abi.ZapMemoryManagerMetaV1)) {
        diag.write(
            "manager '{s}' `.zapmem` section is too small to hold the v1.0 metadata header",
            .{manager_name},
        );
        return ResolveError.SectionInvalid;
    }

    var meta: abi.ZapMemoryManagerMetaV1 = undefined;
    @memcpy(std.mem.asBytes(&meta), section_bytes[0..@sizeOf(abi.ZapMemoryManagerMetaV1)]);

    if (meta.magic != abi.ZMEM_MAGIC_LE) {
        diag.write(
            "manager '{s}' has invalid magic (expected 'ZMEM', got 0x{x:0>8})",
            .{ manager_name, meta.magic },
        );
        return ResolveError.BadMagic;
    }

    if (meta.abi_major != 1) {
        diag.write(
            "manager '{s}' declares ABI major {d}; this compiler supports ABI major 1",
            .{ manager_name, meta.abi_major },
        );
        return ResolveError.AbiMajorMismatch;
    }

    if (meta.size < @sizeOf(abi.ZapMemoryManagerMetaV1)) {
        diag.write(
            "manager '{s}' metadata size {d} is smaller than the v1.0 base size ({d})",
            .{ manager_name, meta.size, @sizeOf(abi.ZapMemoryManagerMetaV1) },
        );
        return ResolveError.ValidationFailed;
    }

    // Upper bound: the meta header may grow in future ABI minors with
    // additional fields, but a v1.0-aware driver bounds the growth so a
    // malformed or maliciously-crafted manager cannot direct the parser
    // to read arbitrary offsets within the object. Future minors that
    // legitimately need more headroom will bump the cap.
    const MAX_META_SIZE: usize = 8 * @sizeOf(abi.ZapMemoryManagerMetaV1);
    if (@as(usize, meta.size) > MAX_META_SIZE) {
        diag.write(
            "manager '{s}' metadata size {d} exceeds the v1.x upper bound ({d}); the manager was built against a future ABI version",
            .{ manager_name, meta.size, MAX_META_SIZE },
        );
        return ResolveError.ValidationFailed;
    }

    if (meta.reserved != 0) {
        diag.write(
            "manager '{s}' metadata reserved field is non-zero ({d}); the manager was built against a future ABI version",
            .{ manager_name, meta.reserved },
        );
        return ResolveError.ValidationFailed;
    }

    if (meta._reserved2 != 0) {
        diag.write(
            "manager '{s}' metadata has non-zero reserved field _reserved2 ({d}); the manager was built against a future ABI version",
            .{ manager_name, meta._reserved2 },
        );
        return ResolveError.ValidationFailed;
    }

    if (meta.core_vtable_offset < meta.size) {
        diag.write(
            "manager '{s}' core_vtable_offset ({d}) overlaps the metadata header (size {d})",
            .{ manager_name, meta.core_vtable_offset, meta.size },
        );
        return ResolveError.ValidationFailed;
    }

    if (meta.core_vtable_offset > section_bytes.len or
        section_bytes.len - meta.core_vtable_offset < @sizeOf(abi.ZapMemoryManagerCoreV1))
    {
        diag.write(
            "manager '{s}' core vtable at offset {d} exceeds section bounds ({d} bytes)",
            .{ manager_name, meta.core_vtable_offset, section_bytes.len },
        );
        return ResolveError.ValidationFailed;
    }

    // Axis-aware capability validation. `declared_caps` encodes the
    // REFCOUNT_V1 flag (bit 0), the Axis-A reclamation-model field (bits
    // 1..2), and the Axis-B sharing-strategy bit (bit 3) — see
    // `src/memory/abi.zig`. Reject still-unknown bits, the not-yet-shipped
    // / undefined Axis-A codes, and inconsistent axis combinations.
    try validateDeclaredCaps(manager_name, meta.declared_caps, diag);

    var core: abi.ZapMemoryManagerCoreV1 = undefined;
    @memcpy(
        std.mem.asBytes(&core),
        section_bytes[meta.core_vtable_offset..][0..@sizeOf(abi.ZapMemoryManagerCoreV1)],
    );

    if (core.abi_major != meta.abi_major or core.abi_minor != meta.abi_minor) {
        diag.write(
            "manager '{s}' meta/core ABI mismatch (meta {d}.{d} vs core {d}.{d})",
            .{ manager_name, meta.abi_major, meta.abi_minor, core.abi_major, core.abi_minor },
        );
        return ResolveError.ValidationFailed;
    }
    if (core.declared_caps != meta.declared_caps) {
        diag.write(
            "manager '{s}' meta.declared_caps (0x{x}) and core.declared_caps (0x{x}) disagree",
            .{ manager_name, meta.declared_caps, core.declared_caps },
        );
        return ResolveError.ValidationFailed;
    }
    if (core.size < @sizeOf(abi.ZapMemoryManagerCoreV1)) {
        diag.write(
            "manager '{s}' core size {d} is smaller than the v1.0 base size ({d})",
            .{ manager_name, core.size, @sizeOf(abi.ZapMemoryManagerCoreV1) },
        );
        return ResolveError.ValidationFailed;
    }

    // Upper bound on `core.size` for the same reason `meta.size` has one
    // (see above). The core vtable may grow with additional function
    // pointers in future ABI minors; the cap simply bounds how far the
    // driver is willing to walk before deciding the input is corrupt.
    const MAX_CORE_SIZE: usize = 8 * @sizeOf(abi.ZapMemoryManagerCoreV1);
    if (@as(usize, core.size) > MAX_CORE_SIZE) {
        diag.write(
            "manager '{s}' core size {d} exceeds the v1.x upper bound ({d}); the manager was built against a future ABI version",
            .{ manager_name, core.size, MAX_CORE_SIZE },
        );
        return ResolveError.ValidationFailed;
    }

    // Validate embedded descriptors: each id must map to a declared bit;
    // id == 0 is reserved; size must fit.
    var refcount_sized_extension = false;
    if (meta.desc_count > 0) {
        const desc_table_offset = @as(usize, meta.core_vtable_offset) + @as(usize, core.size);
        const desc_total = @as(usize, meta.desc_count) * @sizeOf(abi.ZapCapabilityDescV1);
        if (desc_table_offset + desc_total > section_bytes.len) {
            diag.write(
                "manager '{s}' embedded descriptor table ({d} bytes starting at offset {d}) exceeds section ({d} bytes)",
                .{ manager_name, desc_total, desc_table_offset, section_bytes.len },
            );
            return ResolveError.ValidationFailed;
        }
        var i: u32 = 0;
        while (i < meta.desc_count) : (i += 1) {
            const desc_offset = desc_table_offset + @as(usize, i) * @sizeOf(abi.ZapCapabilityDescV1);
            var desc: abi.ZapCapabilityDescV1 = undefined;
            @memcpy(
                std.mem.asBytes(&desc),
                section_bytes[desc_offset..][0..@sizeOf(abi.ZapCapabilityDescV1)],
            );
            if (desc.id == 0) {
                diag.write(
                    "manager '{s}' embeds descriptor with id == 0; descriptor ID 0 is reserved",
                    .{manager_name},
                );
                return ResolveError.ValidationFailed;
            }
            // Translate id -> bit mask and ensure declared_caps covers it.
            const bit = bitForTag(desc.id) orelse {
                diag.write(
                    "manager '{s}' embeds descriptor with unknown id 0x{x:0>8}",
                    .{ manager_name, desc.id },
                );
                return ResolveError.ValidationFailed;
            };
            if ((meta.declared_caps & (@as(u64, 1) << bit)) == 0) {
                diag.write(
                    "manager '{s}' embeds descriptor for capability 0x{x:0>8} but does not declare it in declared_caps",
                    .{ manager_name, desc.id },
                );
                return ResolveError.ValidationFailed;
            }
            // Per-descriptor vtable size bounds. Each capability has
            // its own minimum size (the v1.0 base of that capability's
            // vtable) and the same upper bound applies (8× the v1.x
            // vtable size, mirroring the bound applied to `core.size`
            // and `meta.size`). The runtime tripwire at
            // `zapMemoryStartup` mirrors these checks as defence-in-
            // depth; rejecting at the driver gives a clearer build-
            // time diagnostic instead of a runtime panic.
            const cap_size_min = capabilityVtableMinSize(desc.id);
            const cap_size_max = capabilityVtableMaxSize(desc.id);
            if (desc.size < cap_size_min) {
                diag.write(
                    "manager '{s}' descriptor for capability 0x{x:0>8} has size {d}, less than the minimum {d} bytes",
                    .{ manager_name, desc.id, desc.size, cap_size_min },
                );
                return ResolveError.ValidationFailed;
            }
            if (desc.size > cap_size_max) {
                diag.write(
                    "manager '{s}' descriptor for capability 0x{x:0>8} has size {d}, exceeding the v1.x upper bound {d}; the manager was built against a future ABI version",
                    .{ manager_name, desc.id, desc.size, cap_size_max },
                );
                return ResolveError.ValidationFailed;
            }
            if (desc.id == abi.REFC_TAG and desc.size >= abi.REFCOUNT_V1_SIZE_V1_1) {
                refcount_sized_extension = true;
            }
        }
    }

    return .{
        .declared_caps = meta.declared_caps,
        .abi_minor = meta.abi_minor,
        .refcount_sized_extension = refcount_sized_extension,
    };
}

/// Minimum legal byte length for `desc.size`, per capability. For
/// `REFCOUNT_V1` this is the v1.0 vtable size (16 bytes); a manager
/// that advertises a smaller size cannot satisfy even the v1.0
/// `retain`/`release` contract.
fn capabilityVtableMinSize(id: u32) usize {
    if (id == abi.REFC_TAG) return abi.REFCOUNT_V1_SIZE_V1_0;
    // Unknown / future capabilities have no defined minimum in v1.0;
    // they are rejected earlier in the loop (`bitForTag` returns
    // null), so this branch is unreachable for v1.0 inputs. Provide
    // a conservative floor of 1 byte for forward compatibility.
    return 1;
}

/// Maximum legal byte length for `desc.size`, per capability. Same
/// rationale as the `core.size` upper bound: an absurdly large
/// descriptor is treated as corrupt rather than an enormous future
/// ABI shape. For `REFCOUNT_V1` the bound is 8× the v1.1 vtable size
/// (8 × 48 = 384 bytes).
fn capabilityVtableMaxSize(id: u32) usize {
    if (id == abi.REFC_TAG) return 8 * @as(usize, abi.REFCOUNT_V1_SIZE_V1_1);
    return 8 * @sizeOf(abi.ZapCapabilityDescV1);
}

/// Translate a FourCC tag (in target endianness) to its bit position in
/// `declared_caps`. v1.0 only defines `REFC`; everything else is either
/// reserved or unknown.
fn bitForTag(tag: u32) ?u6 {
    if (tag == abi.REFC_TAG) return 0;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolve requires evaluated adapter binding" {
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    try std.testing.expectError(
        ResolveError.MissingMemoryManagerAdapter,
        resolve(
            std.testing.allocator,
            .{
                .adapter = null,
                .project_root = ".",
                .zap_source_root = ".",
                .cache_dir = "/tmp/zap-driver-test-missing-adapter",
            },
            &diag,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "Memory.Manager") != null);
}

test "resolve rejects empty adapter backend binding before compiling" {
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    try std.testing.expectError(
        ResolveError.InvalidManagerBackendSource,
        resolve(
            std.testing.allocator,
            .{
                .adapter = .{
                    .type_name = "",
                },
                .project_root = ".",
                .zap_source_root = ".",
                .cache_dir = "/tmp/zap-driver-test-bad-adapter",
            },
            &diag,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "empty manager type") != null);
}

test "validateSection accepts a minimal NoOp-style section" {
    const meta: abi.ZapMemoryManagerMetaV1 = .{
        .magic = abi.ZMEM_MAGIC_LE,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(abi.ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = 0,
        .core_vtable_offset = @sizeOf(abi.ZapMemoryManagerMetaV1),
        .reserved = 0,
    };

    // Build a section: meta + core. The function pointers in the core
    // are not invoked here; the validator only inspects layout fields.
    const noop = struct {
        fn cInit(opts: ?*const abi.ZapInitOptions) callconv(.c) ?*anyopaque {
            _ = opts;
            return null;
        }
        fn cDeinit(ctx: *anyopaque) callconv(.c) void {
            _ = ctx;
        }
        fn cAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
            _ = ctx;
            _ = size;
            _ = alignment;
            return null;
        }
        fn cDeallocate(ctx: *anyopaque, ptr: [*]u8, size: usize, alignment: u32) callconv(.c) void {
            _ = ctx;
            _ = ptr;
            _ = size;
            _ = alignment;
        }
        fn cGetCap(ctx: *anyopaque, id: u32) callconv(.c) ?*const abi.ZapCapabilityDescV1 {
            _ = ctx;
            _ = id;
            return null;
        }
    };
    const core: abi.ZapMemoryManagerCoreV1 = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(abi.ZapMemoryManagerCoreV1),
        .declared_caps = 0,
        .init = noop.cInit,
        .deinit = noop.cDeinit,
        .allocate = noop.cAllocate,
        .deallocate = noop.cDeallocate,
        .get_capability_desc = noop.cGetCap,
    };

    var bytes: [@sizeOf(abi.ZapMemoryManagerMetaV1) + @sizeOf(abi.ZapMemoryManagerCoreV1)]u8 = undefined;
    @memcpy(bytes[0..@sizeOf(abi.ZapMemoryManagerMetaV1)], std.mem.asBytes(&meta));
    @memcpy(bytes[@sizeOf(abi.ZapMemoryManagerMetaV1)..][0..@sizeOf(abi.ZapMemoryManagerCoreV1)], std.mem.asBytes(&core));

    var diag_buf: [256]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const v = try validateSection("Test.Manager", &bytes, &diag);
    try std.testing.expectEqual(@as(u64, 0), v.declared_caps);
    try std.testing.expectEqual(@as(u16, 0), v.abi_minor);
}

test "validateSection rejects bad magic" {
    var meta: abi.ZapMemoryManagerMetaV1 = .{
        .magic = 0xDEADBEEF, // bad
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(abi.ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = 0,
        .core_vtable_offset = @sizeOf(abi.ZapMemoryManagerMetaV1),
        .reserved = 0,
    };
    var bytes: [@sizeOf(abi.ZapMemoryManagerMetaV1) + @sizeOf(abi.ZapMemoryManagerCoreV1)]u8 = undefined;
    @memcpy(bytes[0..@sizeOf(abi.ZapMemoryManagerMetaV1)], std.mem.asBytes(&meta));
    // Trailing bytes are uninitialised — we don't get that far because magic fails first.

    var diag_buf: [256]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const result = validateSection("Bad", &bytes, &diag);
    try std.testing.expectError(ResolveError.BadMagic, result);
}

// ---------------------------------------------------------------------------
// End-to-end integration test (Phase 3 acceptance)
//
// Walks the driver from a synthetic project's source roots through to a
// validated `ResolvedManager` populated with the no-op manager's
// declared capabilities. The fork primitive is mocked: it writes a
// minimal ELF object file whose `.zapmem` section matches what the
// real `src/memory/no_op/manager.zig` source would emit when compiled.
// This proves the driver's pipeline end-to-end (struct discovery →
// attribute resolution → compile-then-parse handshake → validation)
// without requiring the Zig fork's full LLVM toolchain in the unit
// test environment.
//
// The real fork primitive is exercised separately through the `zap`
// binary's normal build path (when the manifest selects a non-default
// manager) — see Phase 3's link integration in `src/main.zig` for the
// production wiring.
// ---------------------------------------------------------------------------

/// Build the 88-byte NoOp metadata payload shared by the ELF and
/// Mach-O synthesisers — meta header + core vtable with stub function
/// pointers. The validator only inspects layout/version fields and
/// never invokes the pointers, so storing address-of-stub is safe.
fn synthesizeNoOpPayload() [88]u8 {
    return synthesizePayloadWithCaps(0);
}

/// Helper underlying both `synthesizeNoOpPayload` and the ARC-specific
/// variant used by the Phase 4 ARC integration test. `declared_caps`
/// goes into both the meta and the core's `declared_caps` field; the
/// stub function pointers are no-ops because the section parser only
/// inspects layout fields (the runtime never reaches these stubs).
fn synthesizePayloadWithCaps(declared_caps: u64) [88]u8 {
    var payload: [88]u8 = undefined;
    const meta: abi.ZapMemoryManagerMetaV1 = .{
        .magic = abi.ZMEM_MAGIC_LE,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(abi.ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = declared_caps,
        .core_vtable_offset = @sizeOf(abi.ZapMemoryManagerMetaV1),
        .reserved = 0,
    };
    const stubs = struct {
        fn cInit(opts: ?*const abi.ZapInitOptions) callconv(.c) ?*anyopaque {
            _ = opts;
            return null;
        }
        fn cDeinit(c: *anyopaque) callconv(.c) void {
            _ = c;
        }
        fn cAlloc(c: *anyopaque, sz: usize, al: u32) callconv(.c) ?[*]u8 {
            _ = c;
            _ = sz;
            _ = al;
            return null;
        }
        fn cFree(c: *anyopaque, p: [*]u8, sz: usize, al: u32) callconv(.c) void {
            _ = c;
            _ = p;
            _ = sz;
            _ = al;
        }
        fn cDesc(c: *anyopaque, id: u32) callconv(.c) ?*const abi.ZapCapabilityDescV1 {
            _ = c;
            _ = id;
            return null;
        }
    };
    const core: abi.ZapMemoryManagerCoreV1 = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(abi.ZapMemoryManagerCoreV1),
        .declared_caps = declared_caps,
        .init = stubs.cInit,
        .deinit = stubs.cDeinit,
        .allocate = stubs.cAlloc,
        .deallocate = stubs.cFree,
        .get_capability_desc = stubs.cDesc,
    };
    @memcpy(payload[0..@sizeOf(abi.ZapMemoryManagerMetaV1)], std.mem.asBytes(&meta));
    @memcpy(
        payload[@sizeOf(abi.ZapMemoryManagerMetaV1)..][0..@sizeOf(abi.ZapMemoryManagerCoreV1)],
        std.mem.asBytes(&core),
    );
    return payload;
}

/// Build a complete ELF object file in `buffer` whose `.zapmem` section
/// carries a NoOp-style metadata payload (declared_caps = 0). Wraps
/// `synthesizeElfWithCaps`.
fn synthesizeNoOpElf(buffer: []u8) usize {
    return synthesizeElfWithCaps(buffer, 0);
}

/// Build a complete ELF object file in `buffer` whose `.zapmem` section
/// declares `declared_caps` AND whose symbol table exports
/// `zap_memory_section` for the section's offset. Returns the number
/// of bytes written. The symbol-table emission is what lets the
/// driver's `assertExportsManagerSymbol` pass in the integration test.
/// Used by both the Phase 3 NoOp integration test (`declared_caps = 0`)
/// and the Phase 4 ARC integration test (`declared_caps = REFCOUNT_V1_BIT`).
fn synthesizeElfWithCaps(buffer: []u8, declared_caps: u64) usize {
    // shstrtab layout: index 0 = '\0', then ".shstrtab\0", then
    // ".zapmem\0", then ".symtab\0", then ".strtab\0".
    const shstrtab = "\x00.shstrtab\x00.zapmem\x00.symtab\x00.strtab\x00";
    // Symbol-string table: index 0 = '\0', then the manager-symbol name.
    const symstrtab = "\x00zap_memory_section\x00";

    const ehdr_size: u64 = @sizeOf(std.elf.Elf64_Ehdr);
    const shdr_size: u64 = @sizeOf(std.elf.Elf64_Shdr);
    const sym_size: u64 = @sizeOf(std.elf.Elf64_Sym);
    const shdr_count: u16 = 5; // null, shstrtab, zapmem, symtab, strtab

    const shdr_table_offset = ehdr_size;
    const shstrtab_offset = shdr_table_offset + shdr_size * @as(u64, shdr_count);
    const zapmem_offset = shstrtab_offset + shstrtab.len;
    const payload = synthesizePayloadWithCaps(declared_caps);
    const symtab_offset = zapmem_offset + payload.len;
    // Two symbols: STN_UNDEF (zero) and `zap_memory_section`.
    const sym_count: u64 = 2;
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
    sh_shstrtab.sh_name = 1; // offset of `.shstrtab`
    sh_shstrtab.sh_type = @intFromEnum(std.elf.SHT.STRTAB);
    sh_shstrtab.sh_offset = shstrtab_offset;
    sh_shstrtab.sh_size = shstrtab.len;
    @memcpy(
        buffer[shdr_table_offset + shdr_size ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_shstrtab),
    );

    var sh_zap: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    sh_zap.sh_name = 11; // offset of `.zapmem` in shstrtab
    sh_zap.sh_type = @intFromEnum(std.elf.SHT.PROGBITS);
    sh_zap.sh_flags = std.elf.SHF_ALLOC;
    sh_zap.sh_offset = zapmem_offset;
    sh_zap.sh_size = payload.len;
    @memcpy(
        buffer[shdr_table_offset + shdr_size * 2 ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_zap),
    );

    var sh_symtab: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    sh_symtab.sh_name = 19; // offset of `.symtab`
    sh_symtab.sh_type = @intFromEnum(std.elf.SHT.SYMTAB);
    sh_symtab.sh_offset = symtab_offset;
    sh_symtab.sh_size = sym_size * sym_count;
    sh_symtab.sh_link = 4; // index of `.strtab` in section table
    sh_symtab.sh_info = 1; // first non-local symbol index
    sh_symtab.sh_addralign = 8;
    sh_symtab.sh_entsize = sym_size;
    @memcpy(
        buffer[shdr_table_offset + shdr_size * 3 ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_symtab),
    );

    var sh_strtab: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    sh_strtab.sh_name = 27; // offset of `.strtab`
    sh_strtab.sh_type = @intFromEnum(std.elf.SHT.STRTAB);
    sh_strtab.sh_offset = symstrtab_offset;
    sh_strtab.sh_size = symstrtab.len;
    @memcpy(
        buffer[shdr_table_offset + shdr_size * 4 ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_strtab),
    );

    @memcpy(buffer[shstrtab_offset..][0..shstrtab.len], shstrtab);
    @memcpy(buffer[zapmem_offset..][0..payload.len], &payload);

    // Symbol table: index 0 is STN_UNDEF; index 1 is `zap_memory_section`
    // bound to the .zapmem section.
    var sym_null: std.elf.Elf64_Sym = std.mem.zeroes(std.elf.Elf64_Sym);
    @memcpy(buffer[symtab_offset..][0..@sizeOf(std.elf.Elf64_Sym)], std.mem.asBytes(&sym_null));

    var sym_zap: std.elf.Elf64_Sym = std.mem.zeroes(std.elf.Elf64_Sym);
    sym_zap.st_name = 1; // offset of `zap_memory_section` in strtab
    // STT_OBJECT(1) | STB_GLOBAL(1) << 4 = 0x11
    sym_zap.st_info = (1 << 4) | 1;
    sym_zap.st_other = 0;
    sym_zap.st_shndx = 2; // section index of `.zapmem`
    sym_zap.st_value = 0;
    sym_zap.st_size = payload.len;
    @memcpy(
        buffer[symtab_offset + sym_size ..][0..@sizeOf(std.elf.Elf64_Sym)],
        std.mem.asBytes(&sym_zap),
    );

    @memcpy(buffer[symstrtab_offset..][0..symstrtab.len], symstrtab);

    return @intCast(total);
}

/// Build a complete Mach-O 64-bit object file in `buffer` whose
/// `__DATA,__zapmem` section carries a NoOp-style metadata payload
/// (declared_caps = 0). Wraps `synthesizeMachoWithCaps`.
fn synthesizeNoOpMacho(buffer: []u8) usize {
    return synthesizeMachoWithCaps(buffer, 0);
}

/// Build a complete Mach-O 64-bit object file whose `__DATA,__zapmem`
/// section carries a metadata payload declaring `declared_caps` AND
/// whose symbol table exports `_zap_memory_section` (Mach-O prefixes
/// external C symbols with a leading underscore). Returns the number
/// of bytes written. Used by both the Phase 3 NoOp Mach-O integration
/// test (`declared_caps = 0`) and the Phase 4 ARC Mach-O integration
/// test (`declared_caps = REFCOUNT_V1_BIT`). Sibling of
/// `synthesizeElfWithCaps`.
fn synthesizeMachoWithCaps(buffer: []u8, declared_caps: u64) usize {
    const header_size: usize = @sizeOf(std.macho.mach_header_64);
    const seg_size: usize = @sizeOf(std.macho.segment_command_64);
    const sect_size: usize = @sizeOf(std.macho.section_64);
    const symtab_cmd_size: usize = @sizeOf(std.macho.symtab_command);
    const nlist_size: usize = @sizeOf(std.macho.nlist_64);

    // Mach-O symbol-string table for one external symbol. Mach-O strtab
    // typically begins with `\x20\x00` (a space and a NUL — Apple's
    // historical convention). Use `\x00` for both bytes so the first
    // real entry sits at offset 1 and dereferences cleanly.
    const sym_name = "_zap_memory_section";
    // strtab layout: leading `\x00`, then sym_name + trailing `\x00`.
    var strtab_buf: [1 + sym_name.len + 1]u8 = undefined;
    strtab_buf[0] = 0;
    @memcpy(strtab_buf[1..][0..sym_name.len], sym_name);
    strtab_buf[1 + sym_name.len] = 0;

    const payload = synthesizePayloadWithCaps(declared_caps);

    // Layout: header → LC_SEGMENT_64(__DATA + 1 section) → LC_SYMTAB →
    // payload bytes → symbol table → string table.
    const segment_cmd_offset = header_size;
    const symtab_cmd_offset = segment_cmd_offset + seg_size + sect_size;
    const payload_offset = symtab_cmd_offset + symtab_cmd_size;
    const symtab_offset = payload_offset + payload.len;
    const strtab_offset = symtab_offset + nlist_size;
    const total = strtab_offset + strtab_buf.len;

    // mach_header_64
    var header: std.macho.mach_header_64 = std.mem.zeroes(std.macho.mach_header_64);
    header.magic = std.macho.MH_MAGIC_64;
    header.cputype = std.macho.CPU_TYPE_X86_64;
    header.cpusubtype = std.macho.CPU_SUBTYPE_X86_64_ALL;
    header.filetype = std.macho.MH_OBJECT;
    header.ncmds = 2; // LC_SEGMENT_64 + LC_SYMTAB
    header.sizeofcmds = @intCast(seg_size + sect_size + symtab_cmd_size);
    header.flags = 0;
    header.reserved = 0;
    @memcpy(buffer[0..header_size], std.mem.asBytes(&header));

    // segment_command_64
    var seg: std.macho.segment_command_64 = std.mem.zeroes(std.macho.segment_command_64);
    seg.cmd = .SEGMENT_64;
    seg.cmdsize = @intCast(seg_size + sect_size);
    @memcpy(seg.segname[0.."__DATA".len], "__DATA");
    seg.vmaddr = 0;
    seg.vmsize = payload.len;
    seg.fileoff = payload_offset;
    seg.filesize = payload.len;
    seg.maxprot = .{ .READ = true, .WRITE = true };
    seg.initprot = .{ .READ = true, .WRITE = true };
    seg.nsects = 1;
    seg.flags = 0;
    @memcpy(buffer[segment_cmd_offset..][0..seg_size], std.mem.asBytes(&seg));

    // section_64
    var sect: std.macho.section_64 = std.mem.zeroes(std.macho.section_64);
    @memcpy(sect.sectname[0.."__zapmem".len], "__zapmem");
    @memcpy(sect.segname[0.."__DATA".len], "__DATA");
    sect.addr = 0;
    sect.size = payload.len;
    sect.offset = @intCast(payload_offset);
    sect.@"align" = 3;
    sect.reloff = 0;
    sect.nreloc = 0;
    sect.flags = std.macho.S_REGULAR;
    sect.reserved1 = 0;
    sect.reserved2 = 0;
    sect.reserved3 = 0;
    @memcpy(buffer[segment_cmd_offset + seg_size ..][0..sect_size], std.mem.asBytes(&sect));

    // symtab_command
    var symtab_cmd: std.macho.symtab_command = std.mem.zeroes(std.macho.symtab_command);
    symtab_cmd.cmd = .SYMTAB;
    symtab_cmd.cmdsize = @intCast(symtab_cmd_size);
    symtab_cmd.symoff = @intCast(symtab_offset);
    symtab_cmd.nsyms = 1;
    symtab_cmd.stroff = @intCast(strtab_offset);
    symtab_cmd.strsize = @intCast(strtab_buf.len);
    @memcpy(buffer[symtab_cmd_offset..][0..symtab_cmd_size], std.mem.asBytes(&symtab_cmd));

    // payload
    @memcpy(buffer[payload_offset..][0..payload.len], &payload);

    // nlist_64 (single entry).
    // External N_SECT symbol referencing the only section (index 1).
    // The n_desc bits are all zero for a plain visible data symbol.
    const nl: std.macho.nlist_64 = .{
        .n_strx = 1, // offset of `_zap_memory_section` in strtab
        .n_type = .{ .bits = .{
            .ext = true,
            .type = .sect,
            .pext = false,
            .is_stab = 0,
        } },
        .n_sect = 1,
        .n_desc = .{
            .arm_thumb_def = false,
            .referenced_dynamically = false,
            .discarded_or_no_dead_strip = false,
            .weak_ref = false,
            .weak_def_or_ref_to_weak = false,
            .symbol_resolver = false,
            .alt_entry = false,
        },
        .n_value = 0,
    };
    @memcpy(buffer[symtab_offset..][0..nlist_size], std.mem.asBytes(&nl));

    // strtab
    @memcpy(buffer[strtab_offset..][0..strtab_buf.len], &strtab_buf);

    return total;
}

/// Build a complete raw COFF (no `MZ`) AMD64 object in `buffer` whose
/// `.zapmem` section carries a NoOp-style metadata payload AND whose
/// symbol table exports `zap_memory_section` (via the string-table name
/// form, since the name exceeds 8 bytes). Mirrors the ELF/Mach-O
/// synthesisers so `coffSymbolPresent` and `extractFromCoff` are exercised
/// against a realistic object without invoking the cross compiler.
/// Returns the number of bytes written.
fn synthesizeNoOpCoff(buffer: []u8) usize {
    const header_size: usize = @sizeOf(std.coff.Header); // 20
    const section_header_size: usize = @sizeOf(std.coff.SectionHeader); // 40
    const symbol_stride: usize = 18; // std.coff.Symbol.sizeOf()

    const payload = synthesizePayloadWithCaps(0);

    const section_table_offset = header_size;
    const raw_offset = section_table_offset + section_header_size; // 1 section
    const raw_size = payload.len;
    const symtab_offset = raw_offset + raw_size;
    const symbol_count: usize = 1;
    const strtab_offset = symtab_offset + symbol_count * symbol_stride;

    // String table: 4-byte size prefix, then the manager symbol name.
    const symbol_name = "zap_memory_section\x00";
    const string_table_total = 4 + symbol_name.len;
    const symbol_name_offset: u32 = 4; // first byte after the size prefix
    const total = strtab_offset + string_table_total;

    @memset(buffer[0..total], 0);

    // ---- COFF file header ----
    std.mem.writeInt(u16, buffer[0..2], 0x8664, .little); // AMD64
    std.mem.writeInt(u16, buffer[2..4], 1, .little); // number_of_sections
    std.mem.writeInt(u32, buffer[8..12], @intCast(symtab_offset), .little); // pointer_to_symbol_table
    std.mem.writeInt(u32, buffer[12..16], @intCast(symbol_count), .little); // number_of_symbols
    // size_of_optional_header (offset 16) = 0.

    // ---- section header: `.zapmem` ----
    const sh_off = section_table_offset;
    @memcpy(buffer[sh_off..][0..".zapmem".len], ".zapmem");
    std.mem.writeInt(u32, buffer[sh_off + 16 ..][0..4], @intCast(raw_size), .little); // size_of_raw_data
    std.mem.writeInt(u32, buffer[sh_off + 20 ..][0..4], @intCast(raw_offset), .little); // pointer_to_raw_data

    // ---- raw section bytes ----
    @memcpy(buffer[raw_offset..][0..payload.len], &payload);

    // ---- symbol table: one symbol, string-table name form ----
    const sym = buffer[symtab_offset..][0..symbol_stride];
    // name[0..4] = 0 (string-table form), name[4..8] = offset.
    std.mem.writeInt(u32, sym[0..4], 0, .little);
    std.mem.writeInt(u32, sym[4..8], symbol_name_offset, .little);
    std.mem.writeInt(u32, sym[8..12], 0, .little); // value
    std.mem.writeInt(u16, sym[12..14], 1, .little); // section_number = 1 (.zapmem)
    std.mem.writeInt(u16, sym[14..16], 0, .little); // type
    sym[16] = 2; // storage_class = EXTERNAL
    sym[17] = 0; // number_of_aux_symbols

    // ---- string table ----
    std.mem.writeInt(u32, buffer[strtab_offset..][0..4], @intCast(string_table_total), .little);
    @memcpy(buffer[strtab_offset + 4 ..][0..symbol_name.len], symbol_name);

    return total;
}

/// Mock `ForkCompileFn` used by the ELF integration test. Writes a
/// NoOp-style ELF object to the requested output path and returns `.Ok`.
var mock_noop_compile_count: usize = 0;

fn mockForkCompileNoOp(
    source_path: [*:0]const u8,
    target: *const ZapForkTarget,
    optimize: ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
    zig_lib_dir_opt: ?[*:0]const u8,
    local_cache_dir_opt: ?[*:0]const u8,
    global_cache_dir_opt: ?[*:0]const u8,
    cpu_features_opt: ?[*:0]const u8,
) callconv(.c) ZapForkResult {
    _ = source_path;
    _ = target;
    _ = optimize;
    _ = out_diagnostic_buffer;
    _ = out_diagnostic_capacity;
    _ = zig_lib_dir_opt;
    _ = local_cache_dir_opt;
    _ = global_cache_dir_opt;
    _ = cpu_features_opt;

    mock_noop_compile_count += 1;

    var buffer: [4096]u8 = undefined;
    const written = synthesizeNoOpElf(&buffer);
    const path_slice = std.mem.span(out_object_path);
    if (std.fs.path.dirname(path_slice)) |dir| {
        std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir) catch return .InternalError;
    }
    var file = std.Io.Dir.cwd().createFile(std.Options.debug_io, path_slice, .{}) catch return .InternalError;
    defer file.close(std.Options.debug_io);
    file.writeStreamingAll(std.Options.debug_io, buffer[0..written]) catch return .InternalError;
    return .Ok;
}

const CacheTestProject = struct {
    tmp_path: [:0]u8,
    cache_root: []const u8,
    adapter_source_path: []const u8,
    lib_source_root: []const u8,
    manager_source_path: []const u8,
    source_roots: [1]SourceRoot,

    fn deinit(self: *CacheTestProject, allocator: std.mem.Allocator) void {
        allocator.free(self.tmp_path);
        allocator.free(self.cache_root);
        allocator.free(self.adapter_source_path);
        allocator.free(self.lib_source_root);
        allocator.free(self.manager_source_path);
    }

    fn options(self: *const CacheTestProject, fork_compile_fn: ForkCompileFn) ResolveOptions {
        return .{
            .adapter = .{
                .type_name = "Example.CachedManager",
                .adapter_source_path = self.adapter_source_path,
            },
            .source_roots = self.source_roots[0..],
            .project_root = self.tmp_path,
            .zap_source_root = self.tmp_path,
            .cache_dir = self.cache_root,
            .zig_lib_dir = self.tmp_path,
            .compiler_identity_digest = testToolchainIdentityDigest(0x12),
            .zig_lib_identity_digest = testToolchainIdentityDigest(0x87),
            .fork_compile_fn = fork_compile_fn,
        };
    }
};

fn makeCacheTestProject(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
    manager_source: []const u8,
) !CacheTestProject {
    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "src/cached_manager") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/cached_manager.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/cached_manager/manager.zig", .data = manager_source }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    errdefer allocator.free(tmp_path);
    const cache_root = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch return error.OutOfMemory;
    errdefer allocator.free(cache_root);
    const adapter_source_path = std.fs.path.join(allocator, &.{ tmp_path, "lib/cached_manager.zap" }) catch return error.OutOfMemory;
    errdefer allocator.free(adapter_source_path);
    const lib_source_root = std.fs.path.join(allocator, &.{ tmp_path, "lib" }) catch return error.OutOfMemory;
    errdefer allocator.free(lib_source_root);
    const manager_source_path = std.fs.path.join(allocator, &.{ tmp_path, "src/cached_manager/manager.zig" }) catch return error.OutOfMemory;
    errdefer allocator.free(manager_source_path);

    return .{
        .tmp_path = tmp_path,
        .cache_root = cache_root,
        .adapter_source_path = adapter_source_path,
        .lib_source_root = lib_source_root,
        .manager_source_path = manager_source_path,
        .source_roots = .{.{ .name = "project", .path = lib_source_root }},
    };
}

fn cacheEntryForTest(
    allocator: std.mem.Allocator,
    options: ResolveOptions,
    diag: *DriverDiagnostic,
) !ManagerValidationCacheEntry {
    var selection = try resolveManagerSource(allocator, options, diag);
    defer freeManagerSourceSelection(allocator, &selection);
    return managerValidationCacheEntry(allocator, selection, options, try resolveCacheIdentities(options, diag), diag);
}

test "manager validation cache skips fork compile on identical resolve" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var project = try makeCacheTestProject(allocator, &tmp_dir, "// backend v1");
    defer project.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const options = project.options(mockForkCompileNoOp);

    mock_noop_compile_count = 0;
    var first = try resolve(allocator, options, &diag);
    defer freeResolved(allocator, &first);
    try std.testing.expectEqual(@as(usize, 1), mock_noop_compile_count);

    var cache_entry = try cacheEntryForTest(allocator, options, &diag);
    defer cache_entry.deinit(allocator);
    try writeFileAtomic(allocator, cache_entry.object_path, "corrupt object that must not be read on sidecar hit");

    diag.written = 0;
    if (diag.buffer.len > 0) diag.buffer[0] = 0;
    var second = try resolve(allocator, options, &diag);
    defer freeResolved(allocator, &second);

    try std.testing.expectEqual(@as(usize, 1), mock_noop_compile_count);
    try std.testing.expectEqualStrings(first.type_name, second.type_name);
    try std.testing.expectEqual(first.declared_caps, second.declared_caps);
    try std.testing.expectEqual(first.abi_minor, second.abi_minor);
    try std.testing.expectEqual(first.refcount_sized_extension, second.refcount_sized_extension);
}

test "manager validation cache refreshes corrupt sidecar from keyed object without recompiling" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var project = try makeCacheTestProject(allocator, &tmp_dir, "// backend v1");
    defer project.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const options = project.options(mockForkCompileNoOp);

    mock_noop_compile_count = 0;
    var first = try resolve(allocator, options, &diag);
    defer freeResolved(allocator, &first);
    try std.testing.expectEqual(@as(usize, 1), mock_noop_compile_count);

    var cache_entry = try cacheEntryForTest(allocator, options, &diag);
    defer cache_entry.deinit(allocator);
    try writeFileAtomic(allocator, cache_entry.sidecar_path, "corrupt sidecar");

    diag.written = 0;
    if (diag.buffer.len > 0) diag.buffer[0] = 0;
    var second = try resolve(allocator, options, &diag);
    defer freeResolved(allocator, &second);

    try std.testing.expectEqual(@as(usize, 1), mock_noop_compile_count);
    const refreshed = try readValidationSidecar(allocator, cache_entry.sidecar_path, cache_entry.record_identity);
    try std.testing.expect(refreshed != null);
    try std.testing.expectEqual(first.declared_caps, second.declared_caps);
}

test "manager validation cache key changes with source target cpu and optimize inputs" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var project = try makeCacheTestProject(allocator, &tmp_dir, "// backend v1");
    defer project.deinit(allocator);

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const base_options = project.options(mockForkCompileNoOp);

    mock_noop_compile_count = 0;
    var first = try resolve(allocator, base_options, &diag);
    defer freeResolved(allocator, &first);
    try std.testing.expectEqual(@as(usize, 1), mock_noop_compile_count);

    try writeFileAtomic(allocator, project.manager_source_path, "// backend v2");
    var source_changed = try resolve(allocator, base_options, &diag);
    defer freeResolved(allocator, &source_changed);
    try std.testing.expectEqual(@as(usize, 2), mock_noop_compile_count);

    var target_options = base_options;
    target_options.target = "x86_64-linux-gnu";
    var target_changed = try resolve(allocator, target_options, &diag);
    defer freeResolved(allocator, &target_changed);
    try std.testing.expectEqual(@as(usize, 3), mock_noop_compile_count);

    var cpu_options = target_options;
    cpu_options.cpu = "x86_64_v3";
    var cpu_changed = try resolve(allocator, cpu_options, &diag);
    defer freeResolved(allocator, &cpu_changed);
    try std.testing.expectEqual(@as(usize, 4), mock_noop_compile_count);

    var optimize_options = cpu_options;
    optimize_options.optimize = .ReleaseFast;
    var optimize_changed = try resolve(allocator, optimize_options, &diag);
    defer freeResolved(allocator, &optimize_changed);
    try std.testing.expectEqual(@as(usize, 5), mock_noop_compile_count);
}

/// Mock `ForkCompileFn` used by the Mach-O integration test. Writes a
/// NoOp-style Mach-O 64-bit object whose symbol table exports
/// `_zap_memory_section` and returns `.Ok`. This is the platform
/// sibling to `mockForkCompileNoOp`; both flow through the same driver
/// pipeline so the Mach-O code path that runs on macOS dev hosts is
/// exercised in unit tests just like the ELF path.
fn mockForkCompileNoOpMacho(
    source_path: [*:0]const u8,
    target: *const ZapForkTarget,
    optimize: ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
    zig_lib_dir_opt: ?[*:0]const u8,
    local_cache_dir_opt: ?[*:0]const u8,
    global_cache_dir_opt: ?[*:0]const u8,
    cpu_features_opt: ?[*:0]const u8,
) callconv(.c) ZapForkResult {
    _ = source_path;
    _ = target;
    _ = optimize;
    _ = out_diagnostic_buffer;
    _ = out_diagnostic_capacity;
    _ = zig_lib_dir_opt;
    _ = local_cache_dir_opt;
    _ = global_cache_dir_opt;
    _ = cpu_features_opt;

    var buffer: [4096]u8 = undefined;
    const written = synthesizeNoOpMacho(&buffer);
    const path_slice = std.mem.span(out_object_path);
    if (std.fs.path.dirname(path_slice)) |dir| {
        std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir) catch return .InternalError;
    }
    var file = std.Io.Dir.cwd().createFile(std.Options.debug_io, path_slice, .{}) catch return .InternalError;
    defer file.close(std.Options.debug_io);
    file.writeStreamingAll(std.Options.debug_io, buffer[0..written]) catch return .InternalError;
    return .Ok;
}

test "Phase 2 adapters: stdlib manager resolves through generic compile validation" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib/memory") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "src/memory/no_op") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/memory/no_op.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/memory/no_op/manager.zig", .data = "// backend" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const cache_root = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch return error.Unexpected;
    defer allocator.free(cache_root);
    const adapter_source_path = std.fs.path.join(allocator, &.{ tmp_path, "lib/memory/no_op.zap" }) catch return error.Unexpected;
    defer allocator.free(adapter_source_path);
    const lib_source_root = std.fs.path.join(allocator, &.{ tmp_path, "lib" }) catch return error.Unexpected;
    defer allocator.free(lib_source_root);
    const source_roots = [_]SourceRoot{.{ .name = "zap_stdlib", .path = lib_source_root }};

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var resolved = try resolve(
        allocator,
        .{
            .adapter = .{
                .type_name = "Memory.NoOp",
                .adapter_source_path = adapter_source_path,
            },
            .source_roots = &source_roots,
            .project_root = ".",
            .zap_source_root = ".",
            .cache_dir = cache_root,
            .fork_compile_fn = mockForkCompileNoOp,
        },
        &diag,
    );
    defer freeResolved(allocator, &resolved);

    try std.testing.expectEqualStrings("Memory.NoOp", resolved.type_name);
    try std.testing.expect(std.mem.endsWith(u8, resolved.active_manager_source_path, "src/memory/no_op/manager.zig"));
    try std.testing.expectEqual(@as(u64, 0), resolved.declared_caps);
    try std.testing.expectEqual(@as(u16, 0), resolved.abi_minor);
    try std.testing.expect(!resolved.refcount_sized_extension);

    var selection = try resolveManagerSource(allocator, .{
        .adapter = .{
            .type_name = "Memory.NoOp",
            .adapter_source_path = adapter_source_path,
        },
        .source_roots = &source_roots,
        .project_root = ".",
        .zap_source_root = ".",
        .cache_dir = cache_root,
        .fork_compile_fn = mockForkCompileNoOp,
    }, &diag);
    defer freeManagerSourceSelection(allocator, &selection);
    var cache_entry = try managerValidationCacheEntry(allocator, selection, .{
        .adapter = .{
            .type_name = "Memory.NoOp",
            .adapter_source_path = adapter_source_path,
        },
        .source_roots = &source_roots,
        .project_root = ".",
        .zap_source_root = ".",
        .cache_dir = cache_root,
        .fork_compile_fn = mockForkCompileNoOp,
    }, .{
        .compiler_identity_digest = zeroToolchainIdentityDigest(),
        .zig_lib_identity_digest = zeroToolchainIdentityDigest(),
    }, &diag);
    defer cache_entry.deinit(allocator);
    std.Io.Dir.cwd().access(std.Options.debug_io, cache_entry.object_path, .{}) catch return error.Unexpected;
    std.Io.Dir.cwd().access(std.Options.debug_io, cache_entry.sidecar_path, .{}) catch return error.Unexpected;
}

test "Phase 2 adapters: project manager resolves through same ELF validation path" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "src/project_manager") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/project_manager.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/project_manager/manager.zig", .data = "// placeholder" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const cache_root = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch return error.Unexpected;
    defer allocator.free(cache_root);
    const adapter_source_path = std.fs.path.join(allocator, &.{ tmp_path, "lib/project_manager.zap" }) catch return error.Unexpected;
    defer allocator.free(adapter_source_path);
    const lib_source_root = std.fs.path.join(allocator, &.{ tmp_path, "lib" }) catch return error.Unexpected;
    defer allocator.free(lib_source_root);
    const source_roots = [_]SourceRoot{.{ .name = "project", .path = lib_source_root }};

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var resolved = try resolve(
        allocator,
        .{
            .adapter = .{
                .type_name = "Example.ProjectManager",
                .adapter_source_path = adapter_source_path,
            },
            .source_roots = &source_roots,
            .project_root = tmp_path,
            .zap_source_root = tmp_path,
            .cache_dir = cache_root,
            .fork_compile_fn = mockForkCompileNoOp,
        },
        &diag,
    );
    defer freeResolved(allocator, &resolved);

    try std.testing.expectEqualStrings("Example.ProjectManager", resolved.type_name);
    try std.testing.expect(std.mem.endsWith(u8, resolved.active_manager_source_path, "src/project_manager/manager.zig"));
    try std.testing.expectEqual(@as(u64, 0), resolved.declared_caps);
}

test "Phase 2 adapters: project manager resolves through same Mach-O validation path" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "src/project_manager") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/project_manager.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/project_manager/manager.zig", .data = "// placeholder" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const cache_root = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch return error.Unexpected;
    defer allocator.free(cache_root);
    const adapter_source_path = std.fs.path.join(allocator, &.{ tmp_path, "lib/project_manager.zap" }) catch return error.Unexpected;
    defer allocator.free(adapter_source_path);
    const lib_source_root = std.fs.path.join(allocator, &.{ tmp_path, "lib" }) catch return error.Unexpected;
    defer allocator.free(lib_source_root);
    const source_roots = [_]SourceRoot{.{ .name = "project", .path = lib_source_root }};

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var resolved = try resolve(
        allocator,
        .{
            .adapter = .{
                .type_name = "Example.ProjectManager",
                .adapter_source_path = adapter_source_path,
            },
            .source_roots = &source_roots,
            .project_root = tmp_path,
            .zap_source_root = tmp_path,
            .cache_dir = cache_root,
            .fork_compile_fn = mockForkCompileNoOpMacho,
        },
        &diag,
    );
    defer freeResolved(allocator, &resolved);

    try std.testing.expectEqualStrings("Example.ProjectManager", resolved.type_name);
    try std.testing.expectEqual(@as(u64, 0), resolved.declared_caps);
}

test "assertExportsManagerSymbol passes for synthesized NoOp ELF" {
    // The ELF synthesiser emits a symbol table with `zap_memory_section`;
    // the symbol-presence check must accept it.
    var buffer: [4096]u8 = undefined;
    const written = synthesizeNoOpElf(&buffer);
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    try assertExportsManagerSymbol("NoOp(ELF)", buffer[0..written], &diag);
}

test "assertExportsManagerSymbol passes for synthesized NoOp Mach-O" {
    var buffer: [4096]u8 = undefined;
    const written = synthesizeNoOpMacho(&buffer);
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    try assertExportsManagerSymbol("NoOp(Mach-O)", buffer[0..written], &diag);
}

test "assertExportsManagerSymbol passes for synthesized NoOp COFF" {
    // The COFF synthesiser emits a symbol table exporting
    // `zap_memory_section` via the string-table name form; the
    // symbol-presence check must accept it (the Windows cross-compile
    // path).
    var buffer: [4096]u8 = undefined;
    const written = synthesizeNoOpCoff(&buffer);
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    try assertExportsManagerSymbol("NoOp(COFF)", buffer[0..written], &diag);
}

test "coffSymbolPresent returns false when the manager symbol is absent" {
    // Rewrite the exported symbol name so the lookup must miss, proving
    // the walker does not spuriously match.
    var buffer: [4096]u8 = undefined;
    const written = synthesizeNoOpCoff(&buffer);
    var i: usize = 0;
    while (i + "zap_memory_section".len <= written) : (i += 1) {
        if (std.mem.eql(u8, buffer[i..][0.."zap_memory_section".len], "zap_memory_section")) {
            buffer[i] = 'X';
            break;
        }
    }
    try std.testing.expect(!(try coffSymbolPresent(buffer[0..written], MANAGER_SYMBOL_NAME)));
}

test "coffSymbolPresent extracts the .zapmem section from a synthesized COFF" {
    // Cross-check that the section reader and symbol walker agree on the
    // same synthesised object (both must succeed for validation to pass).
    var buffer: [4096]u8 = undefined;
    const written = synthesizeNoOpCoff(&buffer);
    const section = try section_parser.extractSection(buffer[0..written]);
    try std.testing.expect(section.len >= @sizeOf(abi.ZapMemoryManagerMetaV1));
    try std.testing.expect(try coffSymbolPresent(buffer[0..written], MANAGER_SYMBOL_NAME));
}

// ---------------------------------------------------------------------------
// Manager × target soundness gate (forward-compatible spawn-time check).
// ---------------------------------------------------------------------------

/// `declared_caps` for a fully-declared TRACED manager (`Memory.GC`): the
/// Axis-A reclamation-model field set to TRACED. Equals `0x4`.
const TRACED_CAPS: u64 = abi.RECLAMATION_TRACED << abi.RECLAMATION_MODEL_SHIFT;

fn gateDiagBuf() [512]u8 {
    return [_]u8{0} ** 512;
}

test "enforceManagerTargetSupport gates TRACED manager on windows-gnu" {
    var diag_buf = gateDiagBuf();
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const options: ResolveOptions = .{ .adapter = null, .project_root = "/tmp", .zap_source_root = "/tmp", .cache_dir = "/tmp", .target = "x86_64-windows-gnu" };
    const err = enforceManagerTargetSupport("Memory.GC", TRACED_CAPS, options, &diag);
    try std.testing.expectError(ResolveError.ManagerTargetUnsupported, err);
    // The diagnostic must name the selected type, the target, and the
    // viable alternatives so it is actionable.
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "Memory.GC") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "x86_64-windows-gnu") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "COFF/PE") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "Memory.ARC") != null);
}

test "enforceManagerTargetSupport gates TRACED manager on windows-msvc too" {
    // The gate keys on the OS (windows), not a specific ABI — msvc is
    // equally unsound for conservative global scanning.
    var diag_buf = gateDiagBuf();
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const options: ResolveOptions = .{ .adapter = null, .project_root = "/tmp", .zap_source_root = "/tmp", .cache_dir = "/tmp", .target = "x86_64-windows-msvc" };
    try std.testing.expectError(
        ResolveError.ManagerTargetUnsupported,
        enforceManagerTargetSupport("Memory.GC", TRACED_CAPS, options, &diag),
    );
}

test "enforceManagerTargetSupport allows TRACED manager on linux (ELF backend exists)" {
    var diag_buf = gateDiagBuf();
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const options: ResolveOptions = .{ .adapter = null, .project_root = "/tmp", .zap_source_root = "/tmp", .cache_dir = "/tmp", .target = "x86_64-linux-gnu" };
    try enforceManagerTargetSupport("Memory.GC", TRACED_CAPS, options, &diag);
}

test "enforceManagerTargetSupport allows TRACED manager natively (no target)" {
    // Native host build: the Mach-O / ELF global scanners exist, so GC is
    // supported. A null target must not gate.
    var diag_buf = gateDiagBuf();
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const options: ResolveOptions = .{ .adapter = null, .project_root = "/tmp", .zap_source_root = "/tmp", .cache_dir = "/tmp", .target = null };
    try enforceManagerTargetSupport("Memory.GC", TRACED_CAPS, options, &diag);
}

test "enforceManagerTargetSupport allows non-TRACED managers on windows" {
    // REFCOUNTED (ARC), BULK_OR_NEVER (Arena/NoOp/Leak), and
    // INDIVIDUAL_NO_REFCOUNT (Tracking) all run on windows — only the
    // conservative-scan TRACED model is gated.
    var diag_buf = gateDiagBuf();
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const options: ResolveOptions = .{ .adapter = null, .project_root = "/tmp", .zap_source_root = "/tmp", .cache_dir = "/tmp", .target = "x86_64-windows-gnu" };
    try enforceManagerTargetSupport("Memory.ARC", abi.CAPS_REFCOUNTED, options, &diag);
    try enforceManagerTargetSupport("Memory.Arena", abi.CAPS_BULK_OR_NEVER, options, &diag);
    try enforceManagerTargetSupport("Memory.Tracking", abi.CAPS_INDIVIDUAL_NO_REFCOUNT, options, &diag);
}

test "assertExportsManagerSymbol rejects ELF object lacking the symbol" {
    // Strip the symbol-table sections from the synthesised ELF by
    // rewriting the manager symbol's strtab entry so the lookup fails.
    var buffer: [4096]u8 = undefined;
    const written = synthesizeNoOpElf(&buffer);
    // Find and corrupt the strtab so the manager symbol becomes
    // a different name. The strtab content begins with a NUL followed by
    // `zap_memory_section\0`. Overwrite the first letter so the name no
    // longer matches the spec.
    var i: usize = 0;
    while (i + "zap_memory_section".len <= written) : (i += 1) {
        if (std.mem.eql(u8, buffer[i..][0.."zap_memory_section".len], "zap_memory_section")) {
            buffer[i] = 'X';
            break;
        }
    }
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const result = assertExportsManagerSymbol("BadName", buffer[0..written], &diag);
    try std.testing.expectError(ResolveError.ValidationFailed, result);
    try std.testing.expect(diag.text().len > 0);
}

test "validateSection rejects reserved capability bit" {
    var meta: abi.ZapMemoryManagerMetaV1 = .{
        .magic = abi.ZMEM_MAGIC_LE,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(abi.ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        // Bit 4 is outside the defined capability axes (bits 0..3) — a
        // reserved-but-unimplemented bit a v1.x manager must not declare.
        .declared_caps = 0x10,
        .core_vtable_offset = @sizeOf(abi.ZapMemoryManagerMetaV1),
        .reserved = 0,
    };
    var bytes: [@sizeOf(abi.ZapMemoryManagerMetaV1) + @sizeOf(abi.ZapMemoryManagerCoreV1)]u8 = undefined;
    @memcpy(bytes[0..@sizeOf(abi.ZapMemoryManagerMetaV1)], std.mem.asBytes(&meta));

    var diag_buf: [256]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const result = validateSection("ReservedBit", &bytes, &diag);
    try std.testing.expectError(ResolveError.ReservedCapabilityDeclared, result);
}

test "validateDeclaredCaps accepts the defined axis values" {
    var diag_buf: [256]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    // REFCOUNTED (ARC) — byte-identical to the pre-axes ABI.
    try validateDeclaredCaps("ARC", abi.CAPS_REFCOUNTED, &diag);
    // BULK_OR_NEVER (Arena/NoOp/Leak) — the all-zero value.
    try validateDeclaredCaps("BulkOrNever", abi.CAPS_BULK_OR_NEVER, &diag);
    // INDIVIDUAL_NO_REFCOUNT with the default CLONE_ON_SHARE (Tracking).
    try validateDeclaredCaps("Tracking", abi.CAPS_INDIVIDUAL_NO_REFCOUNT, &diag);
    // INDIVIDUAL_NO_REFCOUNT with MOVE_ONLY (Axis B is legal here).
    try validateDeclaredCaps(
        "TrackingMoveOnly",
        abi.CAPS_INDIVIDUAL_NO_REFCOUNT | abi.SHARING_MOVE_ONLY_BIT,
        &diag,
    );
    // TRACED (the conservative tracing-GC manager, plan Phase 5).
    try validateDeclaredCaps(
        "GC",
        abi.RECLAMATION_TRACED << abi.RECLAMATION_MODEL_SHIFT,
        &diag,
    );
}

test "validateDeclaredCaps rejects unknown high bits" {
    var diag_buf: [256]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    // Bit 4 (and any bit above bit 3) is undefined.
    try std.testing.expectError(
        ResolveError.ReservedCapabilityDeclared,
        validateDeclaredCaps("UnknownBit", 0x10, &diag),
    );
    try std.testing.expectError(
        ResolveError.ReservedCapabilityDeclared,
        validateDeclaredCaps("HighBit", 0x8000_0000_0000_0000, &diag),
    );
}

test "validateDeclaredCaps accepts the TRACED model (conservative tracing GC, Phase 5)" {
    var diag_buf: [256]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const traced: u64 = abi.RECLAMATION_TRACED << abi.RECLAMATION_MODEL_SHIFT; // 0x4
    // Phase 5: the conservative tracing-GC manager (`Memory.GC`) declares
    // TRACED, whose codegen contract reuses BULK_OR_NEVER elision (no
    // retain/release/free, no `ArcHeader`). It is a fully-defined Axis-A model
    // and MUST validate. The MOVE_ONLY (Axis B) bit, however, is only legal for
    // INDIVIDUAL_NO_REFCOUNT — pairing it with TRACED is still an inconsistent
    // combo and is rejected by rule 3 below.
    try validateDeclaredCaps("GC", traced, &diag);
    try std.testing.expectError(
        ResolveError.ValidationFailed,
        validateDeclaredCaps("GCMoveOnly", traced | abi.SHARING_MOVE_ONLY_BIT, &diag),
    );
}

test "validateDeclaredCaps rejects the undefined Axis-A 0b11 code" {
    var diag_buf: [256]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const reserved_code: u64 = abi.RECLAMATION_RESERVED << abi.RECLAMATION_MODEL_SHIFT; // 0x6
    try std.testing.expectError(
        ResolveError.ReservedCapabilityDeclared,
        validateDeclaredCaps("ReservedCode", reserved_code, &diag),
    );
}

test "validateDeclaredCaps rejects REFCOUNT_V1 paired with a non-REFCOUNTED Axis-A field" {
    var diag_buf: [256]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    // bit 0 set + Axis-A = INDIVIDUAL_NO_REFCOUNT (0b01) → 0x3, contradictory.
    const inconsistent: u64 = abi.REFCOUNT_V1_BIT | abi.CAPS_INDIVIDUAL_NO_REFCOUNT;
    try std.testing.expectError(
        ResolveError.ValidationFailed,
        validateDeclaredCaps("RefcountedButIndividual", inconsistent, &diag),
    );
}

test "validateDeclaredCaps rejects MOVE_ONLY without INDIVIDUAL_NO_REFCOUNT" {
    var diag_buf: [256]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    // Axis B set on a BULK_OR_NEVER manager (0x8) — meaningless combo.
    try std.testing.expectError(
        ResolveError.ValidationFailed,
        validateDeclaredCaps("BulkMoveOnly", abi.SHARING_MOVE_ONLY_BIT, &diag),
    );
    // Axis B set on a REFCOUNTED manager (0x9) — also rejected.
    try std.testing.expectError(
        ResolveError.ValidationFailed,
        validateDeclaredCaps("RefcountedMoveOnly", abi.CAPS_REFCOUNTED | abi.SHARING_MOVE_ONLY_BIT, &diag),
    );
}

/// Helper for the descriptor-bounds tests. Builds a section that
/// declares REFCOUNT_V1 with a single embedded descriptor at the given
/// vtable size. Returns the bytes and the offset at which the
/// validator will inspect them.
fn synthesizeRefcountDescriptorSection(buffer: []u8, vtable_size: u16) usize {
    const stubs = struct {
        fn cInit(opts: ?*const abi.ZapInitOptions) callconv(.c) ?*anyopaque {
            _ = opts;
            return null;
        }
        fn cDeinit(c: *anyopaque) callconv(.c) void {
            _ = c;
        }
        fn cAlloc(c: *anyopaque, sz: usize, al: u32) callconv(.c) ?[*]u8 {
            _ = c;
            _ = sz;
            _ = al;
            return null;
        }
        fn cFree(c: *anyopaque, p: [*]u8, sz: usize, al: u32) callconv(.c) void {
            _ = c;
            _ = p;
            _ = sz;
            _ = al;
        }
        fn cDesc(c: *anyopaque, id: u32) callconv(.c) ?*const abi.ZapCapabilityDescV1 {
            _ = c;
            _ = id;
            return null;
        }
    };
    const meta: abi.ZapMemoryManagerMetaV1 = .{
        .magic = abi.ZMEM_MAGIC_LE,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(abi.ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 1,
        .declared_caps = abi.REFCOUNT_V1_BIT,
        .core_vtable_offset = @sizeOf(abi.ZapMemoryManagerMetaV1),
        .reserved = 0,
    };
    const core: abi.ZapMemoryManagerCoreV1 = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(abi.ZapMemoryManagerCoreV1),
        .declared_caps = abi.REFCOUNT_V1_BIT,
        .init = stubs.cInit,
        .deinit = stubs.cDeinit,
        .allocate = stubs.cAlloc,
        .deallocate = stubs.cFree,
        .get_capability_desc = stubs.cDesc,
    };
    // The validator inspects only desc.size / desc.id / desc.flags;
    // the vtable pointer is never dereferenced. Use a dummy non-null
    // pointer so the field is well-defined.
    const dummy_vtable: *const anyopaque = @ptrCast(&core);
    const desc: abi.ZapCapabilityDescV1 = .{
        .id = abi.REFC_TAG,
        .version = 1,
        .size = vtable_size,
        .flags = 0,
        .vtable = dummy_vtable,
    };

    const meta_size = @sizeOf(abi.ZapMemoryManagerMetaV1);
    const core_size = @sizeOf(abi.ZapMemoryManagerCoreV1);
    const desc_size = @sizeOf(abi.ZapCapabilityDescV1);
    @memcpy(buffer[0..meta_size], std.mem.asBytes(&meta));
    @memcpy(buffer[meta_size..][0..core_size], std.mem.asBytes(&core));
    @memcpy(buffer[meta_size + core_size ..][0..desc_size], std.mem.asBytes(&desc));
    return meta_size + core_size + desc_size;
}

test "validateSection accepts REFCOUNT_V1 descriptor at v1.0 size (16 bytes)" {
    var bytes: [256]u8 = undefined;
    const len = synthesizeRefcountDescriptorSection(&bytes, abi.REFCOUNT_V1_SIZE_V1_0);
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const v = try validateSection("V1_0_Refc", bytes[0..len], &diag);
    try std.testing.expectEqual(abi.REFCOUNT_V1_BIT, v.declared_caps);
}

test "validateSection accepts REFCOUNT_V1 descriptor at v1.1 size (48 bytes)" {
    var bytes: [256]u8 = undefined;
    const len = synthesizeRefcountDescriptorSection(&bytes, abi.REFCOUNT_V1_SIZE_V1_1);
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const v = try validateSection("V1_1_Refc", bytes[0..len], &diag);
    try std.testing.expectEqual(abi.REFCOUNT_V1_BIT, v.declared_caps);
}

test "validateSection rejects REFCOUNT_V1 descriptor smaller than 16 bytes" {
    var bytes: [256]u8 = undefined;
    const len = synthesizeRefcountDescriptorSection(&bytes, 8); // half of v1.0
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const result = validateSection("TooSmall", bytes[0..len], &diag);
    try std.testing.expectError(ResolveError.ValidationFailed, result);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "less than the minimum") != null);
}

test "validateSection rejects REFCOUNT_V1 descriptor larger than 384 bytes" {
    var bytes: [256]u8 = undefined;
    const len = synthesizeRefcountDescriptorSection(&bytes, 385);
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const result = validateSection("TooLarge", bytes[0..len], &diag);
    try std.testing.expectError(ResolveError.ValidationFailed, result);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "exceeding the v1.x upper bound") != null);
}

test "validateSection accepts REFCOUNT_V1 descriptor at exact upper bound (384 bytes)" {
    var bytes: [256]u8 = undefined;
    const len = synthesizeRefcountDescriptorSection(&bytes, 384);
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    const v = try validateSection("AtBound", bytes[0..len], &diag);
    try std.testing.expectEqual(abi.REFCOUNT_V1_BIT, v.declared_caps);
}

/// Synthesize an ELF object whose total section count exceeds 256 to
/// exercise the symbol-walker's scalability. Real Zig-compiled objects
/// regularly exceed 256 sections (per-function `.text.*` sections,
/// debug info, etc.); the previous fixed-buffer walker silently failed
/// for such inputs because it capped at 256 entries.
///
/// Layout mirrors `synthesizeNoOpElf`'s 5 real sections (null, shstrtab,
/// zapmem, symtab, strtab) and then appends `padding_count` zero-sized
/// NOBITS sections to push the total over the historical cap. NOBITS
/// sections do not occupy disk space so the buffer requirements stay
/// modest.
fn synthesizeNoOpElfWithExtraSections(buffer: []u8, padding_count: u16) usize {
    const shstrtab = "\x00.shstrtab\x00.zapmem\x00.symtab\x00.strtab\x00.pad\x00";
    const symstrtab = "\x00zap_memory_section\x00";
    const pad_name_offset: u32 = 35; // offset of `.pad` in `shstrtab` above

    const ehdr_size: u64 = @sizeOf(std.elf.Elf64_Ehdr);
    const shdr_size: u64 = @sizeOf(std.elf.Elf64_Shdr);
    const sym_size: u64 = @sizeOf(std.elf.Elf64_Sym);
    const real_shdr_count: u16 = 5; // null, shstrtab, zapmem, symtab, strtab
    const shdr_count: u16 = real_shdr_count + padding_count;

    const shdr_table_offset = ehdr_size;
    const shstrtab_offset = shdr_table_offset + shdr_size * @as(u64, shdr_count);
    const zapmem_offset = shstrtab_offset + shstrtab.len;
    const payload = synthesizeNoOpPayload();
    const symtab_offset = zapmem_offset + payload.len;
    const sym_count: u64 = 2;
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
    sh_shstrtab.sh_name = 1;
    sh_shstrtab.sh_type = @intFromEnum(std.elf.SHT.STRTAB);
    sh_shstrtab.sh_offset = shstrtab_offset;
    sh_shstrtab.sh_size = shstrtab.len;
    @memcpy(
        buffer[shdr_table_offset + shdr_size ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_shstrtab),
    );

    var sh_zap: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    sh_zap.sh_name = 11;
    sh_zap.sh_type = @intFromEnum(std.elf.SHT.PROGBITS);
    sh_zap.sh_flags = std.elf.SHF_ALLOC;
    sh_zap.sh_offset = zapmem_offset;
    sh_zap.sh_size = payload.len;
    @memcpy(
        buffer[shdr_table_offset + shdr_size * 2 ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_zap),
    );

    var sh_symtab: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    sh_symtab.sh_name = 19;
    sh_symtab.sh_type = @intFromEnum(std.elf.SHT.SYMTAB);
    sh_symtab.sh_offset = symtab_offset;
    sh_symtab.sh_size = sym_size * sym_count;
    sh_symtab.sh_link = 4; // index of `.strtab` in section table — still valid even past 256
    sh_symtab.sh_info = 1;
    sh_symtab.sh_addralign = 8;
    sh_symtab.sh_entsize = sym_size;
    @memcpy(
        buffer[shdr_table_offset + shdr_size * 3 ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_symtab),
    );

    var sh_strtab: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    sh_strtab.sh_name = 27;
    sh_strtab.sh_type = @intFromEnum(std.elf.SHT.STRTAB);
    sh_strtab.sh_offset = symstrtab_offset;
    sh_strtab.sh_size = symstrtab.len;
    @memcpy(
        buffer[shdr_table_offset + shdr_size * 4 ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_strtab),
    );

    // Padding sections: zero-sized NOBITS entries pointing at `.pad` in
    // the shstrtab. They contribute nothing on disk but bump `shnum`.
    var pad_idx: u16 = 0;
    while (pad_idx < padding_count) : (pad_idx += 1) {
        var sh_pad: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
        sh_pad.sh_name = pad_name_offset;
        sh_pad.sh_type = @intFromEnum(std.elf.SHT.NOBITS);
        sh_pad.sh_offset = 0;
        sh_pad.sh_size = 0;
        const offset = shdr_table_offset + shdr_size * @as(u64, real_shdr_count + pad_idx);
        @memcpy(
            buffer[@intCast(offset)..][0..@sizeOf(std.elf.Elf64_Shdr)],
            std.mem.asBytes(&sh_pad),
        );
    }

    @memcpy(buffer[shstrtab_offset..][0..shstrtab.len], shstrtab);
    @memcpy(buffer[zapmem_offset..][0..payload.len], &payload);

    var sym_null: std.elf.Elf64_Sym = std.mem.zeroes(std.elf.Elf64_Sym);
    @memcpy(buffer[symtab_offset..][0..@sizeOf(std.elf.Elf64_Sym)], std.mem.asBytes(&sym_null));

    var sym_zap: std.elf.Elf64_Sym = std.mem.zeroes(std.elf.Elf64_Sym);
    sym_zap.st_name = 1;
    sym_zap.st_info = (1 << 4) | 1;
    sym_zap.st_other = 0;
    sym_zap.st_shndx = 2;
    sym_zap.st_value = 0;
    sym_zap.st_size = payload.len;
    @memcpy(
        buffer[symtab_offset + sym_size ..][0..@sizeOf(std.elf.Elf64_Sym)],
        std.mem.asBytes(&sym_zap),
    );

    @memcpy(buffer[symstrtab_offset..][0..symstrtab.len], symstrtab);

    return @intCast(total);
}

test "assertExportsManagerSymbol handles ELF with > 256 sections" {
    // Regression: the previous implementation pre-buffered all section
    // headers into a fixed `[256]Elf64_Shdr` array, silently returning
    // `false` for objects with `shnum > 256`. Real Zig-compiled objects
    // routinely exceed this cap (per-function `.text.*` sections, debug
    // info, etc.), causing valid managers to be rejected with a
    // `ValidationFailed` error. Verify the walker now scales beyond 256.
    const padding_count: u16 = 300; // 300 + 5 real = 305 sections
    // 305 * sizeof(Elf64_Shdr=64) = 19,520 bytes for section headers
    // plus ehdr + payload + symtab + strtab + shstrtab ≈ 19,720 bytes.
    var buffer: [32 * 1024]u8 = undefined;
    const written = synthesizeNoOpElfWithExtraSections(&buffer, padding_count);
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    try assertExportsManagerSymbol("LargeSectionCount", buffer[0..written], &diag);
}

/// Captured arguments from `mockForkCompileCaptureTarget`. Populated on
/// each mock invocation so the test can assert what `resolve()` passed
/// to the fork primitive.
var captured_target_state: struct {
    target: ZapForkTarget = std.mem.zeroes(ZapForkTarget),
    /// Whether a non-null `cpu_features_opt` reached the fork, and its
    /// bytes (bounded copy) so the plumbing test can assert `-Dcpu=`
    /// is threaded all the way through `resolve()`.
    cpu_present: bool = false,
    cpu_buf: [64]u8 = undefined,
    cpu_len: usize = 0,
    local_cache_present: bool = false,
    global_cache_present: bool = false,
    local_cache_buf: [256]u8 = undefined,
    local_cache_len: usize = 0,
    global_cache_buf: [256]u8 = undefined,
    global_cache_len: usize = 0,
    invoked: bool = false,
} = .{};

/// Mock `ForkCompileFn` for the compile_target/cpu plumbing test.
/// Records the `ZapForkTarget` and `cpu_features_opt` it received into
/// `captured_target_state` and writes a NoOp ELF object so the
/// surrounding `resolve()` call completes successfully.
fn mockForkCompileCaptureTarget(
    source_path: [*:0]const u8,
    target: *const ZapForkTarget,
    optimize: ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
    zig_lib_dir_opt: ?[*:0]const u8,
    local_cache_dir_opt: ?[*:0]const u8,
    global_cache_dir_opt: ?[*:0]const u8,
    cpu_features_opt: ?[*:0]const u8,
) callconv(.c) ZapForkResult {
    _ = source_path;
    _ = optimize;
    _ = out_diagnostic_buffer;
    _ = out_diagnostic_capacity;
    _ = zig_lib_dir_opt;

    captured_target_state.target = target.*;
    captured_target_state.invoked = true;
    if (cpu_features_opt) |c| {
        const slice = std.mem.span(c);
        captured_target_state.cpu_present = true;
        const n = @min(slice.len, captured_target_state.cpu_buf.len);
        @memcpy(captured_target_state.cpu_buf[0..n], slice[0..n]);
        captured_target_state.cpu_len = n;
    } else {
        captured_target_state.cpu_present = false;
        captured_target_state.cpu_len = 0;
    }
    if (local_cache_dir_opt) |local_cache_dir| {
        const slice = std.mem.span(local_cache_dir);
        captured_target_state.local_cache_present = true;
        const n = @min(slice.len, captured_target_state.local_cache_buf.len);
        @memcpy(captured_target_state.local_cache_buf[0..n], slice[0..n]);
        captured_target_state.local_cache_len = n;
    } else {
        captured_target_state.local_cache_present = false;
        captured_target_state.local_cache_len = 0;
    }
    if (global_cache_dir_opt) |global_cache_dir| {
        const slice = std.mem.span(global_cache_dir);
        captured_target_state.global_cache_present = true;
        const n = @min(slice.len, captured_target_state.global_cache_buf.len);
        @memcpy(captured_target_state.global_cache_buf[0..n], slice[0..n]);
        captured_target_state.global_cache_len = n;
    } else {
        captured_target_state.global_cache_present = false;
        captured_target_state.global_cache_len = 0;
    }

    var buffer: [4096]u8 = undefined;
    const written = synthesizeNoOpElf(&buffer);
    const path_slice = std.mem.span(out_object_path);
    if (std.fs.path.dirname(path_slice)) |dir| {
        std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir) catch return .InternalError;
    }
    var file = std.Io.Dir.cwd().createFile(std.Options.debug_io, path_slice, .{}) catch return .InternalError;
    defer file.close(std.Options.debug_io);
    file.writeStreamingAll(std.Options.debug_io, buffer[0..written]) catch return .InternalError;
    return .Ok;
}

test "resolve threads compile_target through to fork_compile_fn" {
    // End-to-end check: when the build supplies a cross-compile target,
    // `resolve()` must `parseTargetTriple` it and pass the resulting
    // `ZapForkTarget` to the fork primitive. Without this plumbing the
    // manager `.o` would be compiled for the host instead of the binary's
    // final target, producing a link-time mismatch on cross-builds.
    //
    // The selected adapter's backend source is compiled for validation
    // regardless of whether it came from the stdlib, project, or a
    // dependency, so target plumbing must be uniform across all managers.
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "src/project_manager") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/project_manager.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/project_manager/manager.zig", .data = "// placeholder" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);

    const cache_root = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch return error.Unexpected;
    defer allocator.free(cache_root);
    const adapter_source_path = std.fs.path.join(allocator, &.{ tmp_path, "lib/project_manager.zap" }) catch return error.Unexpected;
    defer allocator.free(adapter_source_path);
    const lib_source_root = std.fs.path.join(allocator, &.{ tmp_path, "lib" }) catch return error.Unexpected;
    defer allocator.free(lib_source_root);
    const source_roots = [_]SourceRoot{.{ .name = "project", .path = lib_source_root }};

    // Reset state in case prior tests touched it.
    captured_target_state = .{};

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var resolved = try resolve(
        allocator,
        .{
            .adapter = .{
                .type_name = "Example.ProjectManager",
                .adapter_source_path = adapter_source_path,
            },
            .source_roots = &source_roots,
            .project_root = tmp_path,
            .zap_source_root = tmp_path,
            .cache_dir = cache_root,
            .target = "x86_64-linux-gnu",
            .fork_compile_fn = mockForkCompileCaptureTarget,
        },
        &diag,
    );
    defer freeResolved(allocator, &resolved);

    try std.testing.expect(captured_target_state.invoked);
    const expected = parseTargetTriple("x86_64-linux-gnu") orelse return error.UnexpectedNull;
    try std.testing.expectEqual(expected.arch_tag, captured_target_state.target.arch_tag);
    try std.testing.expectEqual(expected.os_tag, captured_target_state.target.os_tag);
    try std.testing.expectEqual(expected.abi_tag, captured_target_state.target.abi_tag);
    try std.testing.expectEqual(@as(u16, 0), captured_target_state.target._reserved);
    // Sanity: the parsed values match the expected Zig enum values for
    // x86_64 / linux / gnu.
    try std.testing.expectEqual(
        @as(u16, @intCast(@intFromEnum(std.Target.Cpu.Arch.x86_64))),
        captured_target_state.target.arch_tag,
    );
    try std.testing.expectEqual(
        @as(u16, @intCast(@intFromEnum(std.Target.Os.Tag.linux))),
        captured_target_state.target.os_tag,
    );
    try std.testing.expectEqual(
        @as(u16, @intCast(@intFromEnum(std.Target.Abi.gnu))),
        captured_target_state.target.abi_tag,
    );
}

test "resolve threads cpu through to fork_compile_fn" {
    // The CPU plumbing sibling of the target test: when the build
    // supplies `-Dcpu=`, `resolve()` must pass that exact string to
    // the fork primitive so the manager `.o` is built for the same
    // machine as the user binary. Without this the manager `.o` would
    // use the triple's default CPU and could ABI-mismatch the binary.
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "src/project_manager") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/project_manager.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/project_manager/manager.zig", .data = "// placeholder" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);

    const cache_root = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch return error.Unexpected;
    defer allocator.free(cache_root);
    const adapter_source_path = std.fs.path.join(allocator, &.{ tmp_path, "lib/project_manager.zap" }) catch return error.Unexpected;
    defer allocator.free(adapter_source_path);
    const lib_source_root = std.fs.path.join(allocator, &.{ tmp_path, "lib" }) catch return error.Unexpected;
    defer allocator.free(lib_source_root);
    const source_roots = [_]SourceRoot{.{ .name = "project", .path = lib_source_root }};

    captured_target_state = .{};

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var resolved = try resolve(
        allocator,
        .{
            .adapter = .{
                .type_name = "Example.ProjectManager",
                .adapter_source_path = adapter_source_path,
            },
            .source_roots = &source_roots,
            .project_root = tmp_path,
            .zap_source_root = tmp_path,
            .cache_dir = cache_root,
            .target = "x86_64-linux-gnu",
            .cpu = "x86_64_v3",
            .fork_compile_fn = mockForkCompileCaptureTarget,
        },
        &diag,
    );
    defer freeResolved(allocator, &resolved);

    try std.testing.expect(captured_target_state.invoked);
    try std.testing.expect(captured_target_state.cpu_present);
    try std.testing.expectEqualStrings(
        "x86_64_v3",
        captured_target_state.cpu_buf[0..captured_target_state.cpu_len],
    );
}

test "resolve passes a null cpu when none is requested" {
    // Complementary: with no `cpu` set, the driver must pass null so
    // the fork uses the resolved triple's default CPU.
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "src/project_manager") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/project_manager.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/project_manager/manager.zig", .data = "// placeholder" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);

    const cache_root = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch return error.Unexpected;
    defer allocator.free(cache_root);
    const adapter_source_path = std.fs.path.join(allocator, &.{ tmp_path, "lib/project_manager.zap" }) catch return error.Unexpected;
    defer allocator.free(adapter_source_path);
    const lib_source_root = std.fs.path.join(allocator, &.{ tmp_path, "lib" }) catch return error.Unexpected;
    defer allocator.free(lib_source_root);
    const source_roots = [_]SourceRoot{.{ .name = "project", .path = lib_source_root }};

    captured_target_state = .{};

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var resolved = try resolve(
        allocator,
        .{
            .adapter = .{
                .type_name = "Example.ProjectManager",
                .adapter_source_path = adapter_source_path,
            },
            .source_roots = &source_roots,
            .project_root = tmp_path,
            .zap_source_root = tmp_path,
            .cache_dir = cache_root,
            .fork_compile_fn = mockForkCompileCaptureTarget,
        },
        &diag,
    );
    defer freeResolved(allocator, &resolved);

    try std.testing.expect(captured_target_state.invoked);
    try std.testing.expect(!captured_target_state.cpu_present);
}

test "resolve passes cache dir pointers to fork compile primitive" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var project = try makeCacheTestProject(allocator, &tmp_dir, "// backend v1");
    defer project.deinit(allocator);

    captured_target_state = .{};

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };
    var resolved = try resolve(
        allocator,
        project.options(mockForkCompileCaptureTarget),
        &diag,
    );
    defer freeResolved(allocator, &resolved);

    try std.testing.expect(captured_target_state.invoked);
    try std.testing.expect(captured_target_state.local_cache_present);
    try std.testing.expect(captured_target_state.global_cache_present);
    try std.testing.expectEqualStrings(
        project.cache_root,
        captured_target_state.local_cache_buf[0..captured_target_state.local_cache_len],
    );
    try std.testing.expectEqualStrings(
        project.cache_root,
        captured_target_state.global_cache_buf[0..captured_target_state.global_cache_len],
    );
}

test "resolve passes NATIVE sentinel when compile_target is null" {
    // The complementary case: when no `target` is set, the driver passes
    // `ZAP_FORK_ARCH_NATIVE` so the manager `.o` builds for the host.
    // Uses the same adapter path as the cross-target sibling, but leaves
    // `target` unset so the driver must pass the native sentinel.
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "src/project_manager") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/project_manager.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/project_manager/manager.zig", .data = "// placeholder" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);

    const cache_root = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch return error.Unexpected;
    defer allocator.free(cache_root);
    const adapter_source_path = std.fs.path.join(allocator, &.{ tmp_path, "lib/project_manager.zap" }) catch return error.Unexpected;
    defer allocator.free(adapter_source_path);
    const lib_source_root = std.fs.path.join(allocator, &.{ tmp_path, "lib" }) catch return error.Unexpected;
    defer allocator.free(lib_source_root);
    const source_roots = [_]SourceRoot{.{ .name = "project", .path = lib_source_root }};

    captured_target_state = .{};

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var resolved = try resolve(
        allocator,
        .{
            .adapter = .{
                .type_name = "Example.ProjectManager",
                .adapter_source_path = adapter_source_path,
            },
            .source_roots = &source_roots,
            .project_root = tmp_path,
            .zap_source_root = tmp_path,
            .cache_dir = cache_root,
            // .target intentionally omitted — defaults to null.
            .fork_compile_fn = mockForkCompileCaptureTarget,
        },
        &diag,
    );
    defer freeResolved(allocator, &resolved);

    try std.testing.expect(captured_target_state.invoked);
    try std.testing.expectEqual(ZAP_FORK_ARCH_NATIVE, captured_target_state.target.arch_tag);
    try std.testing.expectEqual(@as(u16, 0), captured_target_state.target.os_tag);
    try std.testing.expectEqual(@as(u16, 0), captured_target_state.target.abi_tag);
    try std.testing.expectEqual(@as(u16, 0), captured_target_state.target._reserved);
}

// ---------------------------------------------------------------------------
// Real-toolchain smoke tests
//
// These tests close the verification gap left by the shell scripts in
// `scripts/test_{arena,arc}_manager_compile.sh`. The shell scripts
// exercise the real manager source through the host's `zig` compiler
// and the driver's symbol/section validator, but they are not wired
// into `zig build test`, so contributors and CI that run only
// `zig build test` would miss drift between the real source and the
// driver's parser.
//
// The tests below invoke the system `zig` compiler via
// `std.process.run`, recompile the manager into a fresh temp-dir
// object file, then re-validate the result with the exact same
// production code paths the driver uses at link time
// (`section_parser.extractSection`, `validateSection`, and
// `assertExportsManagerSymbol`). The result is end-to-end coverage of
// the parser, validator, and the manager source itself, without any
// shell-script choreography.
//
// **Skip semantics.** When the host has no usable system `zig` (no
// binary on PATH, spawn forbidden by a sandbox, or a present binary
// whose own stdlib cannot be read), the harness maps that host/toolchain
// bootstrap failure to `error.SkipZigTest`. Once `zig build-obj` can
// actually load its toolchain, every manager-source compile error,
// malformed `.zapmem` section, or missing symbol remains a real test
// failure.
//
// **Cost.** Each test compiles a single `std`-only Zig source file at
// `-O ReleaseSafe`. Local measurement: ~0.3-0.6 seconds per test,
// well under the budget for `zig build test`.
// ---------------------------------------------------------------------------

/// Skip-marker returned when the host has no usable system `zig`.
/// Reused by every system-zig probe in this file so the catch-and-skip
/// pattern stays in one place.
const SystemZigSkipError = error{
    /// The system `zig` binary could not be spawned or cannot read its
    /// own stdlib. Most commonly `error.FileNotFound` on bare CI runners
    /// or an inaccessible Zig installation inside sandboxed tests.
    SystemZigUnavailable,
};

/// Run `zig build-obj <source_abs> -O ReleaseSafe -femit-bin=<obj_abs>`
/// and return on success. Maps the spawn-side errors that indicate
/// "no working `zig` on this host" to `SystemZigUnavailable` so the
/// caller can `return error.SkipZigTest`. A present `zig` that exits
/// before compiling the manager because its own stdlib cannot be read
/// is treated the same way. Every other failure mode (manager compile
/// error, malformed source, non-zero exit after toolchain bootstrap,
/// etc.) is surfaced as the underlying error and fails the test loudly.
///
/// Uses `std.testing.io` for the spawn — that is the threaded-IO
/// instance the test runner sets up with a real allocator backing
/// `fork`/`execve` argument marshalling. `std.Options.debug_io` is
/// initialised with a `failing` allocator (see `Io.Threaded.init_single_threaded`)
/// and crashes on the first `arena.allocSentinel` for argv-building.
fn invokeSystemZigBuildObj(
    allocator: std.mem.Allocator,
    source_abs: []const u8,
    obj_abs: []const u8,
) !void {
    const femit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{obj_abs});
    defer allocator.free(femit_arg);

    const argv = [_][]const u8{
        "zig",
        "build-obj",
        source_abs,
        "-O",
        "ReleaseSafe",
        femit_arg,
    };

    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        // `FileNotFound` means PATH lookup turned up no `zig` binary —
        // the documented skip trigger. `OperationUnsupported` means
        // the host kernel forbids `fork`/spawn (some seccomp sandboxes);
        // we treat that the same way because it is environmental, not
        // a defect in the manager source.
        error.FileNotFound, error.OperationUnsupported => return SystemZigSkipError.SystemZigUnavailable,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            if (isSystemZigStdlibUnavailable(result.stderr)) {
                return SystemZigSkipError.SystemZigUnavailable;
            }
            std.debug.print(
                "system `zig build-obj` exited with code {d}\nstderr:\n{s}\n",
                .{ code, result.stderr },
            );
            return error.SystemZigCompileFailed;
        },
        else => {
            std.debug.print(
                "system `zig build-obj` terminated abnormally: {any}\nstderr:\n{s}\n",
                .{ result.term, result.stderr },
            );
            return error.SystemZigCompileFailed;
        },
    }
}

fn isSystemZigStdlibUnavailable(stderr: []const u8) bool {
    const mentions_std_root =
        std.mem.indexOf(u8, stderr, "std/std.zig") != null or
        std.mem.indexOf(u8, stderr, "std\\std.zig") != null;
    const unable_to_load_std = std.mem.indexOf(u8, stderr, "unable to load 'std.zig':") != null;
    if (!mentions_std_root or !unable_to_load_std) return false;

    return std.mem.indexOf(u8, stderr, "PermissionDenied") != null or
        std.mem.indexOf(u8, stderr, "FileNotFound") != null or
        std.mem.indexOf(u8, stderr, "NotDir") != null or
        std.mem.indexOf(u8, stderr, "AccessDenied") != null or
        std.mem.indexOf(u8, stderr, "InputOutput") != null;
}

test "system zig stdlib unavailable classifier recognizes inaccessible std root" {
    const stderr =
        "/Users/test/.asdf/installs/zig/0.16.0/lib/std/std.zig:1:1: error: unable to load 'std.zig': PermissionDenied\n";

    try std.testing.expect(isSystemZigStdlibUnavailable(stderr));
}

test "system zig stdlib unavailable classifier rejects manager compile errors" {
    const stderr =
        "/work/src/memory/no_op/manager.zig:12:5: error: expected type 'u64', found '[]const u8'\n";

    try std.testing.expect(!isSystemZigStdlibUnavailable(stderr));
}

/// Shared body for the two real-toolchain probes below. Compiles
/// `manager_source_rel` (resolved relative to the test's cwd, which is
/// the project root when invoked via `zig build test`) into a fresh
/// object file inside `tmp_dir`, then parses the result through the
/// production driver helpers. Asserts:
///
///   * `section_parser.extractSection` finds the `.zapmem` payload.
///   * `validateSection` accepts the meta + core header.
///   * `assertExportsManagerSymbolForTest` accepts the `zap_memory_section`
///     symbol export.
///   * `declared_caps` matches `expected_caps` exactly.
///
/// Returns `error.SkipZigTest` (preserved through the caller) when the
/// host has no working `zig` on PATH.
fn verifyRealManagerObject(
    manager_label: []const u8,
    manager_source_rel: []const u8,
    expected_caps: u64,
) !void {
    const allocator = std.testing.allocator;

    // Resolve `manager_source_rel` against the test cwd (project root
    // when invoked via `zig build test`). Using the absolute path
    // sidesteps any cwd ambiguity if a sub-test changes directories.
    const source_abs = std.Io.Dir.cwd().realPathFileAlloc(
        std.Options.debug_io,
        manager_source_rel,
        allocator,
    ) catch |err| {
        // The manager source not existing on the host is itself a
        // build-tree corruption — fail loudly rather than skip.
        std.debug.print(
            "could not resolve manager source '{s}': {any}\n",
            .{ manager_source_rel, err },
        );
        return err;
    };
    defer allocator.free(source_abs);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_abs = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_abs);

    const obj_abs = std.fs.path.join(allocator, &.{ tmp_abs, "manager.o" }) catch return error.OutOfMemory;
    defer allocator.free(obj_abs);

    invokeSystemZigBuildObj(allocator, source_abs, obj_abs) catch |err| switch (err) {
        SystemZigSkipError.SystemZigUnavailable => return error.SkipZigTest,
        else => return err,
    };

    // Read the freshly-compiled object back into memory and feed it
    // through the production driver helpers, exactly as `resolve()`
    // does at link time.
    const object_bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        obj_abs,
        allocator,
        .limited(64 * 1024 * 1024),
    ) catch return error.Unexpected;
    defer allocator.free(object_bytes);

    const section_bytes = section_parser.extractSection(object_bytes) catch |err| {
        std.debug.print(
            "section_parser.extractSection rejected real {s} manager object: {any}\n",
            .{ manager_label, err },
        );
        return err;
    };

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    const validated = validateSection(manager_label, section_bytes, &diag) catch |err| {
        std.debug.print(
            "validateSection rejected real {s} manager object: {any} - {s}\n",
            .{ manager_label, err, diag.text() },
        );
        return err;
    };

    try std.testing.expectEqual(expected_caps, validated.declared_caps);

    // The smoke scripts call `assertExportsManagerSymbolForTest` after
    // section validation; mirror that here so the in-process test
    // exercises the same code path as the shell test for the symbol
    // table check.
    assertExportsManagerSymbolForTest(manager_label, object_bytes, &diag) catch |err| {
        std.debug.print(
            "assertExportsManagerSymbol rejected real {s} manager object: {any} - {s}\n",
            .{ manager_label, err, diag.text() },
        );
        return err;
    };
}

test "real Arena manager source compiles and exports a valid section (system zig)" {
    // Phase 5 verification gap: `scripts/test_arena_manager_compile.sh`
    // exercises this exact pipeline against the real
    // `src/memory/arena/manager.zig` source, but the script is not
    // wired into `zig build test`. This in-process test closes that
    // gap so any drift between the real Arena source and the driver's
    // section parser / symbol-table inspector is caught the next time
    // a contributor runs `zig build test`.
    //
    // Arena frees in bulk at deinit; individual frees are no-ops. In the
    // capability-axis encoding that is Axis A == BULK_OR_NEVER, the all-zero
    // `declared_caps` value (`abi.CAPS_BULK_OR_NEVER == 0`). The expected
    // value below matches the section's literal `declared_caps` field in
    // `src/memory/arena/manager.zig`.
    try verifyRealManagerObject(
        "real_arena",
        "src/memory/arena/manager.zig",
        abi.CAPS_BULK_OR_NEVER,
    );
}

test "real ARC manager source compiles and exports a valid section (system zig)" {
    // Sibling of the Arena test above for the production ARC manager
    // at `src/memory/arc/manager.zig`. `Zap.Manifest.memory` selects
    // `Memory.ARC` by default, so any drift here would break every Zap
    // binary built without an explicit `memory:` selection.
    //
    // ARC declares the `REFCOUNT_V1` capability bit (0x1) in its
    // `.zapmem` section's `declared_caps` field; the expected value
    // below pins that contract. In the capability-axis encoding this is
    // Axis A == REFCOUNTED, and `abi.CAPS_REFCOUNTED == REFCOUNT_V1_BIT`
    // (byte-identical to the pre-axes ABI).
    try verifyRealManagerObject(
        "real_arc",
        "src/memory/arc/manager.zig",
        abi.REFCOUNT_V1_BIT,
    );
}

test "real Leak manager source compiles and exports a valid section (system zig)" {
    // Phase 7 verification gap: `scripts/test_leak_manager_compile.sh`
    // exercises this exact pipeline against the real
    // `src/memory/leak/manager.zig` source, but the script is not
    // wired into `zig build test`. This in-process test closes that
    // gap so any drift between the real Leak source and the driver's
    // section parser / symbol-table inspector is caught the next time
    // a contributor runs `zig build test`.
    //
    // Leak never frees (the OS reclaims at exit). Like Arena it declares
    // Axis A == BULK_OR_NEVER, the all-zero `declared_caps` value
    // (`abi.CAPS_BULK_OR_NEVER == 0`). The expected value below matches the
    // section's literal `declared_caps` field in
    // `src/memory/leak/manager.zig`.
    try verifyRealManagerObject(
        "real_leak",
        "src/memory/leak/manager.zig",
        abi.CAPS_BULK_OR_NEVER,
    );
}

test "real Tracking manager source compiles and exports a valid section (system zig)" {
    // Sibling of the Leak test above for the production Tracking
    // manager at `src/memory/tracking/manager.zig`. Tracking is the
    // diagnostic leak/UAF/OOB CI tool. It frees each allocation
    // individually but keeps NO reference count, so in the
    // capability-axis encoding it declares Axis A == INDIVIDUAL_NO_REFCOUNT
    // with the default CLONE_ON_SHARE sharing strategy — `declared_caps ==
    // 0x2` (`abi.CAPS_INDIVIDUAL_NO_REFCOUNT`). This both pins the section's
    // literal `declared_caps` value and proves the new axis-aware
    // validation accepts a valid INDIVIDUAL_NO_REFCOUNT manager end-to-end.
    try verifyRealManagerObject(
        "real_tracking",
        "src/memory/tracking/manager.zig",
        abi.CAPS_INDIVIDUAL_NO_REFCOUNT,
    );
}

// ---------------------------------------------------------------------------
// Watch-mode rebuild-path simulation tests.
//
// `src/main.zig`'s `IncrementalWatchState.init` resolves the selected
// adapter once at watch-session startup, caches the resulting
// `declared_caps`, `refcount_sized_extension`, and
// `active_manager_source_path`, then threads those values into every
// subsequent `compileProjectFrontend` + `injectAndUpdate` call without
// re-resolving. These tests pin that cache shape for zero-capability
// managers, which historically exercised the REFCOUNT_V1 refusal path.
// ---------------------------------------------------------------------------

fn simulateWatchInitForManager(
    manager_type_name: []const u8,
) !void {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "src/watch_manager") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/watch_manager.zap", .data = "// adapter" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/watch_manager/manager.zig", .data = "// backend" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const cache_root = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch return error.Unexpected;
    defer allocator.free(cache_root);
    const adapter_source_path = std.fs.path.join(allocator, &.{ tmp_path, "lib/watch_manager.zap" }) catch return error.Unexpected;
    defer allocator.free(adapter_source_path);
    const lib_source_root = std.fs.path.join(allocator, &.{ tmp_path, "lib" }) catch return error.Unexpected;
    defer allocator.free(lib_source_root);
    const source_roots = [_]SourceRoot{.{ .name = "project", .path = lib_source_root }};

    var diag_buf: [1024]u8 = undefined;
    var init_diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var init_resolved = try resolve(
        allocator,
        .{
            .adapter = .{
                .type_name = manager_type_name,
                .adapter_source_path = adapter_source_path,
            },
            .source_roots = &source_roots,
            .project_root = ".",
            .zap_source_root = ".",
            .cache_dir = cache_root,
            .fork_compile_fn = mockForkCompileNoOp,
        },
        &init_diag,
    );
    defer freeResolved(allocator, &init_resolved);

    try std.testing.expectEqualStrings(manager_type_name, init_resolved.type_name);
    try std.testing.expectEqual(@as(u64, 0), init_resolved.declared_caps);
    try std.testing.expectEqual(@as(u64, 0), init_resolved.declared_caps & abi.REFCOUNT_V1_BIT);
    try std.testing.expect(!init_resolved.refcount_sized_extension);
    try std.testing.expect(init_resolved.active_manager_source_path.len > 0);

    const cached_caps: u64 = init_resolved.declared_caps;
    const cached_refcount_sized_extension = init_resolved.refcount_sized_extension;
    const cached_source_path = try allocator.dupe(u8, init_resolved.active_manager_source_path);
    defer allocator.free(cached_source_path);

    try std.testing.expectEqual(@as(u64, 0), cached_caps);
    try std.testing.expectEqual(@as(u64, 0), cached_caps & abi.REFCOUNT_V1_BIT);
    try std.testing.expect(!cached_refcount_sized_extension);
    try std.testing.expectEqualStrings(init_resolved.active_manager_source_path, cached_source_path);
}

test "watch-mode rebuild path: Memory.Arena resolves without REFCOUNT_V1 refusal" {
    try simulateWatchInitForManager("Memory.Arena");
}

test "watch-mode rebuild path: Memory.NoOp resolves without REFCOUNT_V1 refusal" {
    try simulateWatchInitForManager("Memory.NoOp");
}

test "watch-mode rebuild path: Memory.Leak resolves without REFCOUNT_V1 refusal" {
    try simulateWatchInitForManager("Memory.Leak");
}

test "watch-mode rebuild path: Memory.Tracking resolves without REFCOUNT_V1 refusal" {
    try simulateWatchInitForManager("Memory.Tracking");
}
