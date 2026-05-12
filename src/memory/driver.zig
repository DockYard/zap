//! Memory manager build-time driver.
//!
//! Phase 3 of the pluggable memory manager rollout — see
//! `docs/memory-manager-abi.md` section 10 for the normative build pipeline.
//!
//! The driver:
//!   1. Receives the manifest's `memory:` selection (a struct reference
//!      resolved to a dotted name like `"Zap.Memory.NoOp"`).
//!   2. Locates the matching `.zap` stdlib struct and reads its
//!      `@memory_manager_source` attribute to find the manager's Zig source.
//!   3. For the built-in default `Zap.Memory.ARC`, short-circuits: no
//!      external compile is invoked and the runtime's built-in ARC stub
//!      continues to provide the active vtable.
//!   4. For non-default managers, invokes the Zig-fork primitive
//!      `zap_fork_compile_zig_to_object` to compile the manager's source
//!      into an object file in `.zap-cache/memory/`.
//!   5. Reads the object file, extracts the `.zapmem` section via the
//!      Phase 1 section parser, and validates the meta header + core vtable
//!      + embedded descriptors per spec section 3.5.
//!   6. Exposes the resulting `ResolvedManager` to the compiler driver:
//!      the object path goes onto the link line; `declared_caps` flows
//!      through to HIR / codegen (Phase 6 will branch on it); the manager
//!      name appears in diagnostics.
//!
//! The driver is build-time-only — it produces a `ResolvedManager` value
//! that the rest of the build pipeline (`src/main.zig`'s `buildTarget`)
//! reads. It does not touch the runtime; the runtime bootstrap (spec
//! section 10.2) is wired separately.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const section_parser = @import("section_parser.zig");

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

/// Resolved state of the active manager, threaded from the build driver
/// through to the link step and runtime bootstrap.
pub const ResolvedManager = struct {
    /// Dotted manager name as it appears in the manifest (e.g.
    /// `"Zap.Memory.ARC"`, `"Zap.Memory.NoOp"`). Always non-empty.
    name: []const u8,

    /// `true` when the manager is `Zap.Memory.ARC` and the driver elected
    /// to use the runtime's built-in stub instead of compiling and
    /// linking an external manager `.o`. In this mode `object_path` is
    /// `null` and the link step ignores the manager.
    is_builtin_default: bool,

    /// Absolute or relative path to the compiled manager object file. Only
    /// populated when `is_builtin_default == false`. The compiler driver
    /// appends this to the final binary's link line.
    object_path: ?[]const u8,

    /// Capability bitmask read from the validated `.zapmem` core vtable.
    /// Phase 6 (codegen elision) reads this to decide whether to emit
    /// retain/release calls; Phase 4 (Map/List/String layout branch)
    /// reads it to decide whether the inline ArcHeader is present.
    declared_caps: u64,

    /// ABI minor version declared by the manager. Phase 3 records this
    /// for diagnostic context; runtime validation rejects majors that
    /// don't match the compiler's (currently 1).
    abi_minor: u16,
};

/// Driver-level errors. Each variant maps to a build-time diagnostic in
/// the normative table from spec section 10.4.
pub const ResolveError = error{
    /// The `memory:` field was set to a struct that does not declare a
    /// `@memory_manager_source` attribute.
    MissingMemoryManagerSource,
    /// The struct named by `memory:` could not be found in any of the
    /// source roots.
    ManagerStructNotFound,
    /// The Zig source file referenced by `@memory_manager_source` could
    /// not be opened.
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
/// be a leaf import without cyclic dependencies on `discovery.zig`.
pub const SourceRoot = struct {
    /// Logical name (e.g. `"project"`, `"zap_stdlib"`, `"dep:foo"`).
    name: []const u8,
    /// Absolute or workspace-relative path to a directory the driver may
    /// recursively scan for `.zap` files.
    path: []const u8,
};

/// Inputs passed to `resolve`.
pub const ResolveOptions = struct {
    /// Dotted manager name from the manifest (e.g. `"Zap.Memory.NoOp"`).
    /// Empty string -> driver applies the default `Zap.Memory.ARC`.
    manager_name: []const u8,
    /// Source roots to search for the manager's `.zap` stdlib struct.
    source_roots: []const SourceRoot,
    /// Project root — used to resolve the manager's `@memory_manager_source`
    /// attribute (which may be relative).
    project_root: []const u8,
    /// Path to the Zap source tree's root (e.g.
    /// `/Users/.../zap`) — used to resolve first-party stdlib paths.
    /// May be the same as `project_root` when building Zap itself.
    zap_source_root: []const u8,
    /// Directory the driver writes the compiled manager `.o` into.
    /// Created if it does not exist.
    cache_dir: []const u8,
    /// Optional Zig stdlib directory passed through to the fork primitive.
    /// When null the primitive auto-detects.
    zig_lib_dir: ?[]const u8 = null,
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
    /// Optional override for the fork compile function. When null the
    /// driver invokes the real `libzap_compiler.a` extern. Tests pass a
    /// mock that synthesises an object file without needing the LLVM
    /// stack. Production builds (the `zap` binary) always leave this
    /// null so the real fork primitive runs.
    fork_compile_fn: ?ForkCompileFn = null,
};

/// Default manager when the manifest does not set `memory:`.
pub const DEFAULT_MANAGER: []const u8 = "Zap.Memory.ARC";

/// Resolve the active memory manager for the build. Returns a
/// `ResolvedManager` whose lifetime is bound to the caller's allocator.
///
/// The driver short-circuits the built-in ARC default to keep existing
/// projects building unchanged. For any other manager it walks the full
/// pipeline: source discovery → external compile → section parse →
/// validation.
pub fn resolve(
    allocator: std.mem.Allocator,
    options: ResolveOptions,
    diag: *DriverDiagnostic,
) ResolveError!ResolvedManager {
    const manager_name = if (options.manager_name.len == 0)
        DEFAULT_MANAGER
    else
        options.manager_name;

    // Short-circuit the built-in ARC default — the runtime's static
    // `builtin_arc_core` provides the active vtable; no external compile
    // is needed and no `.o` is appended to the link line.
    if (std.mem.eql(u8, manager_name, "Zap.Memory.ARC")) {
        return .{
            .name = try allocator.dupe(u8, manager_name),
            .is_builtin_default = true,
            .object_path = null,
            // The built-in stub declares REFCOUNT_V1. Phase 6 reads this
            // bit to know that retain/release calls should be emitted.
            .declared_caps = abi.REFCOUNT_V1_BIT,
            .abi_minor = 0,
        };
    }

    // Find the .zap source that declares the manager struct so we can
    // read its `@memory_manager_source` attribute.
    const manager_source_rel = (try discoverManagerSource(allocator, manager_name, options.source_roots)) orelse {
        diag.write(
            "memory manager struct '{s}' was not found in any source root; check the manifest's `memory:` value",
            .{manager_name},
        );
        return ResolveError.ManagerStructNotFound;
    };
    defer allocator.free(manager_source_rel);

    // Resolve `@memory_manager_source` to an absolute filesystem path.
    // First-party managers express the path relative to the Zap source
    // tree; third-party managers express it relative to the dep's root
    // (Phase 3 always treats the path as relative to either the project
    // root or the Zap source root; richer dep-aware resolution lands in
    // Phase 7).
    const candidates = [_][]const u8{ options.zap_source_root, options.project_root };
    var manager_zig_path: ?[]const u8 = null;
    for (candidates) |root| {
        const joined = std.fs.path.join(allocator, &.{ root, manager_source_rel }) catch return ResolveError.OutOfMemory;
        std.Io.Dir.cwd().access(std.Options.debug_io, joined, .{}) catch {
            allocator.free(joined);
            continue;
        };
        manager_zig_path = joined;
        break;
    }
    const manager_zig_path_owned = manager_zig_path orelse {
        diag.write(
            "memory manager source not found at '{s}' (from `@memory_manager_source` on `{s}`)",
            .{ manager_source_rel, manager_name },
        );
        return ResolveError.ManagerSourceNotFound;
    };
    defer allocator.free(manager_zig_path_owned);

    // Compile the manager's Zig source into an object file in
    // `<cache_dir>/<safe_name>.o`. Spec section 10.3: the .o is content-
    // addressed; Phase 3 always recompiles (cheap) and Phase 7 may add
    // a content hash.
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, options.cache_dir) catch {};
    const safe_name = try makeSafeFileName(allocator, manager_name);
    defer allocator.free(safe_name);
    const object_basename = try std.fmt.allocPrint(allocator, "{s}.o", .{safe_name});
    defer allocator.free(object_basename);
    const object_path = std.fs.path.join(allocator, &.{ options.cache_dir, object_basename }) catch return ResolveError.OutOfMemory;
    // Caller owns `object_path` via the returned struct; we must NOT free it here.
    errdefer allocator.free(object_path);

    try compileManagerSource(allocator, manager_name, manager_zig_path_owned, object_path, options, diag);

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

    // Build-time check: the runtime bootstrap discovers the manager
    // via `@extern(..., .{ .name = "zap_memory_section", .linkage =
    // .weak })`. The contract in `docs/memory-manager-abi.md` section
    // 3.2 / 10.5 requires every manager to export the section payload
    // under that symbol name. A manager that emitted the section bytes
    // under a different symbol (or as an unnamed payload) would pass
    // the section-content validation above but silently resolve the
    // weak extern to null at runtime, falling back to the built-in ARC
    // vtable. The check below catches that mis-emission at build time.
    try assertExportsManagerSymbol(manager_name, object_bytes, diag);

    return .{
        .name = try allocator.dupe(u8, manager_name),
        .is_builtin_default = false,
        .object_path = object_path,
        .declared_caps = validated.declared_caps,
        .abi_minor = validated.abi_minor,
    };
}

/// Free the owned memory inside a `ResolvedManager`. Safe to call once.
pub fn freeResolved(allocator: std.mem.Allocator, resolved: *ResolvedManager) void {
    allocator.free(resolved.name);
    if (resolved.object_path) |p| allocator.free(p);
    resolved.name = "";
    resolved.object_path = null;
}

// ---------------------------------------------------------------------------
// Source discovery
// ---------------------------------------------------------------------------

/// Walk every `.zap` file under `source_roots` looking for the one that
/// declares `manager_name`. When the declaration is found, return the
/// owned string value of the file's `@memory_manager_source` attribute.
/// Returns null when no file declares the struct. Returns
/// `MissingMemoryManagerSource` when the struct is declared without the
/// attribute.
fn discoverManagerSource(
    allocator: std.mem.Allocator,
    manager_name: []const u8,
    source_roots: []const SourceRoot,
) ResolveError!?[]const u8 {
    for (source_roots) |root| {
        if (try scanDirForManagerSource(allocator, manager_name, root.path)) |found| {
            return found;
        }
    }
    return null;
}

fn scanDirForManagerSource(
    allocator: std.mem.Allocator,
    manager_name: []const u8,
    dir_path: []const u8,
) ResolveError!?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();
    while (iter.next(std.Options.debug_io) catch null) |entry| {
        if (entry.kind == .directory) {
            const sub_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch return ResolveError.OutOfMemory;
            defer allocator.free(sub_path);
            if (try scanDirForManagerSource(allocator, manager_name, sub_path)) |found| return found;
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
        const file_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch return ResolveError.OutOfMemory;
        defer allocator.free(file_path);

        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, allocator, .limited(10 * 1024 * 1024)) catch continue;
        defer allocator.free(source);

        if (try matchManagerSourceInZap(allocator, manager_name, source)) |attr_value| return attr_value;
    }
    return null;
}

/// Best-effort scan of a Zap source's text looking for a top-level
/// `@memory_manager_source = "..."` attribute paired with a `pub struct
/// <manager_name>` declaration. The driver runs before the full collector
/// pipeline, so we tokenize the file directly (mirroring how the
/// `@native_type` discovery pass works in `discovery.zig`).
fn matchManagerSourceInZap(
    allocator: std.mem.Allocator,
    manager_name: []const u8,
    source: []const u8,
) ResolveError!?[]const u8 {
    var pending_attr: ?[]const u8 = null;

    var cursor: usize = 0;
    while (cursor < source.len) {
        // Skip whitespace.
        while (cursor < source.len and isWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor >= source.len) break;

        // Line comments — `#`. The Zap lexer treats `#` as a comment marker
        // outside of string interpolation; we approximate by skipping to
        // newline whenever we see a `#` that isn't preceded by `\` or
        // inside a heredoc. The driver only needs to ignore comment lines
        // that contain literal `@memory_manager_source`, which is rare.
        if (source[cursor] == '#') {
            while (cursor < source.len and source[cursor] != '\n') : (cursor += 1) {}
            continue;
        }

        // Heredoc `"""` — skip everything up to the closing `"""`.
        if (cursor + 2 < source.len and source[cursor] == '"' and source[cursor + 1] == '"' and source[cursor + 2] == '"') {
            cursor += 3;
            while (cursor + 2 < source.len) : (cursor += 1) {
                if (source[cursor] == '"' and source[cursor + 1] == '"' and source[cursor + 2] == '"') {
                    cursor += 3;
                    break;
                }
            }
            continue;
        }

        // Top-level attribute: `@memory_manager_source = "..."`.
        if (source[cursor] == '@') {
            cursor += 1;
            const name_start = cursor;
            while (cursor < source.len and isIdentChar(source[cursor])) : (cursor += 1) {}
            const attr_name = source[name_start..cursor];
            if (std.mem.eql(u8, attr_name, "memory_manager_source")) {
                // Skip whitespace, `=`, whitespace.
                while (cursor < source.len and isWhitespace(source[cursor])) : (cursor += 1) {}
                if (cursor >= source.len or source[cursor] != '=') continue;
                cursor += 1;
                while (cursor < source.len and isWhitespace(source[cursor])) : (cursor += 1) {}
                if (cursor >= source.len or source[cursor] != '"') continue;
                cursor += 1;
                const value_start = cursor;
                while (cursor < source.len and source[cursor] != '"') : (cursor += 1) {}
                if (cursor >= source.len) break;
                const value_end = cursor;
                cursor += 1;
                if (pending_attr) |old| allocator.free(old);
                pending_attr = try allocator.dupe(u8, source[value_start..value_end]);
            }
            continue;
        }

        // `pub struct <manager_name>` — match the manager name literally.
        if (matchAtCursor(source, cursor, "pub struct")) {
            cursor += "pub struct".len;
            while (cursor < source.len and isWhitespace(source[cursor])) : (cursor += 1) {}
            const name_start = cursor;
            while (cursor < source.len and (isIdentChar(source[cursor]) or source[cursor] == '.')) : (cursor += 1) {}
            const decl_name = source[name_start..cursor];
            if (std.mem.eql(u8, decl_name, manager_name)) {
                if (pending_attr) |attr| return attr;
                return ResolveError.MissingMemoryManagerSource;
            }
            // Different struct in the same file — reset attribute and
            // continue scanning.
            if (pending_attr) |old| {
                allocator.free(old);
                pending_attr = null;
            }
            continue;
        }

        cursor += 1;
    }

    if (pending_attr) |old| allocator.free(old);
    return null;
}

fn matchAtCursor(source: []const u8, cursor: usize, prefix: []const u8) bool {
    if (cursor + prefix.len > source.len) return false;
    return std.mem.eql(u8, source[cursor .. cursor + prefix.len], prefix);
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
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

    // When the build is cross-compiling (`compile_target` is set on
    // the manifest), pass the matching `ZapForkTarget` to the fork
    // primitive so the manager `.o` matches the binary's target.
    // Otherwise pass the NATIVE sentinel — the fork's
    // `isSupportedTriple` whitelist gates which native hosts are
    // accepted.
    const target: ZapForkTarget = if (options.target) |triple|
        parseTargetTriple(triple) orelse {
            diag.write(
                "memory manager '{s}' could not build for cross-compile target '{s}': unrecognised triple (expected arch-os-abi)",
                .{ manager_name, triple },
            );
            return ResolveError.ManagerCompileFailed;
        }
    else
        .{
            .arch_tag = ZAP_FORK_ARCH_NATIVE,
            .os_tag = 0,
            .abi_tag = 0,
            ._reserved = 0,
        };

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
    const result = fork_fn(
        source_z.ptr,
        &target,
        options.optimize,
        object_z.ptr,
        &fork_diag_buf,
        fork_diag_buf.len,
        zig_lib_z,
        null,
        null,
    );

    switch (result) {
        .Ok => return,
        .SourceNotFound => {
            diag.write(
                "memory manager source not found at '{s}' (from `@memory_manager_source` on `{s}`)",
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
/// but resolve the runtime weak-extern to null at startup, silently
/// falling back to the built-in ARC vtable.
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

const SymbolCheckError = error{
    UnsupportedFormat,
    InvalidObject,
};

/// Walk the object's symbol table and return `true` iff
/// `zap_memory_section` is present. Supports ELF64 and Mach-O 64-bit
/// — the same formats `section_parser.extractSection` handles.
fn managerSymbolPresent(bytes: []const u8) SymbolCheckError!bool {
    return switch (section_parser.detectFormat(bytes)) {
        .elf => elfSymbolPresent(bytes, MANAGER_SYMBOL_NAME),
        .macho => machoSymbolPresent(bytes, MANAGER_SYMBOL_NAME),
        .coff => SymbolCheckError.UnsupportedFormat,
        .unknown => SymbolCheckError.InvalidObject,
    };
}

fn elfSymbolPresent(bytes: []const u8, want: []const u8) SymbolCheckError!bool {
    var hdr_reader = std.Io.Reader.fixed(bytes);
    const header = std.elf.Header.read(&hdr_reader) catch return SymbolCheckError.InvalidObject;
    if (header.shnum == 0) return false;

    // First pass: collect headers so we can look up the string table
    // a symbol-table section references via `sh_link`.
    var section_headers: [256]std.elf.Elf64_Shdr = undefined;
    if (header.shnum > section_headers.len) return false;
    var idx: u32 = 0;
    var it = header.iterateSectionHeadersBuffer(bytes);
    while (true) {
        const maybe = it.next() catch return SymbolCheckError.InvalidObject;
        const sh = maybe orelse break;
        if (idx >= section_headers.len) break;
        section_headers[idx] = sh;
        idx += 1;
    }
    const count = idx;

    var s: u32 = 0;
    while (s < count) : (s += 1) {
        const sh = section_headers[s];
        if (sh.sh_type != @intFromEnum(std.elf.SHT.SYMTAB) and
            sh.sh_type != @intFromEnum(std.elf.SHT.DYNSYM))
        {
            continue;
        }
        if (sh.sh_link >= count) return SymbolCheckError.InvalidObject;
        const strtab_sh = section_headers[sh.sh_link];
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

// ---------------------------------------------------------------------------
// Section validation (spec section 3.5)
// ---------------------------------------------------------------------------

const ValidatedSection = struct {
    declared_caps: u64,
    abi_minor: u16,
};

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

    // Reject reserved capability bits. Phase 3 only knows REFCOUNT_V1
    // (bit 0); spec section 7 reserves bits 1..9. A v1.0 manager must
    // not declare any reserved bit.
    const reserved_mask: u64 = 0x3FE; // bits 1..9 inclusive
    if ((meta.declared_caps & reserved_mask) != 0) {
        diag.write(
            "manager '{s}' declares a reserved-but-unimplemented capability (declared_caps=0x{x})",
            .{ manager_name, meta.declared_caps },
        );
        return ResolveError.ReservedCapabilityDeclared;
    }

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
        }
    }

    return .{
        .declared_caps = meta.declared_caps,
        .abi_minor = meta.abi_minor,
    };
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

test "default short-circuit returns built-in ARC marker" {
    var diag_buf: [256]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var resolved = try resolve(
        std.testing.allocator,
        .{
            .manager_name = "",
            .source_roots = &.{},
            .project_root = ".",
            .zap_source_root = ".",
            .cache_dir = "/tmp/zap-driver-test-default",
        },
        &diag,
    );
    defer freeResolved(std.testing.allocator, &resolved);

    try std.testing.expect(resolved.is_builtin_default);
    try std.testing.expectEqualStrings("Zap.Memory.ARC", resolved.name);
    try std.testing.expectEqual(@as(?[]const u8, null), resolved.object_path);
    try std.testing.expectEqual(abi.REFCOUNT_V1_BIT, resolved.declared_caps);
}

test "explicit ARC selection also short-circuits" {
    var diag_buf: [256]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var resolved = try resolve(
        std.testing.allocator,
        .{
            .manager_name = "Zap.Memory.ARC",
            .source_roots = &.{},
            .project_root = ".",
            .zap_source_root = ".",
            .cache_dir = "/tmp/zap-driver-test-arc",
        },
        &diag,
    );
    defer freeResolved(std.testing.allocator, &resolved);

    try std.testing.expect(resolved.is_builtin_default);
    try std.testing.expectEqualStrings("Zap.Memory.ARC", resolved.name);
}

test "unknown manager name returns ManagerStructNotFound" {
    var diag_buf: [512]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    const result = resolve(
        std.testing.allocator,
        .{
            .manager_name = "Third.Party.Bogus",
            .source_roots = &.{},
            .project_root = ".",
            .zap_source_root = ".",
            .cache_dir = "/tmp/zap-driver-test-bogus",
        },
        &diag,
    );
    try std.testing.expectError(ResolveError.ManagerStructNotFound, result);
    try std.testing.expect(diag.text().len > 0);
}

test "matchManagerSourceInZap extracts @memory_manager_source attribute" {
    const source =
        \\@memory_manager_source = "src/memory/no_op/manager.zig"
        \\
        \\pub struct Zap.Memory.NoOp {
        \\}
        \\
    ;
    const allocator = std.testing.allocator;
    const found = try matchManagerSourceInZap(allocator, "Zap.Memory.NoOp", source);
    defer if (found) |f| allocator.free(f);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("src/memory/no_op/manager.zig", found.?);
}

test "matchManagerSourceInZap returns MissingMemoryManagerSource when attribute absent" {
    const source =
        \\pub struct Some.Manager {
        \\}
        \\
    ;
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        ResolveError.MissingMemoryManagerSource,
        matchManagerSourceInZap(allocator, "Some.Manager", source),
    );
}

test "matchManagerSourceInZap returns null when struct not present" {
    const source =
        \\@memory_manager_source = "x.zig"
        \\
        \\pub struct Different.Name {
        \\}
        \\
    ;
    const allocator = std.testing.allocator;
    const found = try matchManagerSourceInZap(allocator, "Missing.Name", source);
    try std.testing.expect(found == null);
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
    var payload: [88]u8 = undefined;
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
        .declared_caps = 0,
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
/// carries a NoOp-style metadata payload AND whose symbol table exports
/// `zap_memory_section` for the section's offset. Returns the number
/// of bytes written. The symbol-table emission is what lets the
/// driver's `assertExportsManagerSymbol` pass in the integration test.
fn synthesizeNoOpElf(buffer: []u8) usize {
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
    const payload = synthesizeNoOpPayload();
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

/// Build a complete Mach-O 64-bit object file whose `__DATA,__zapmem`
/// section carries a NoOp-style metadata payload AND whose symbol table
/// exports `_zap_memory_section` (Mach-O prefixes external C symbols
/// with a leading underscore). Returns the number of bytes written.
/// Used by the Mach-O sibling integration test.
fn synthesizeNoOpMacho(buffer: []u8) usize {
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

    const payload = synthesizeNoOpPayload();

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

/// Mock `ForkCompileFn` used by the ELF integration test. Writes a
/// NoOp-style ELF object to the requested output path and returns `.Ok`.
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
) callconv(.c) ZapForkResult {
    _ = source_path;
    _ = target;
    _ = optimize;
    _ = out_diagnostic_buffer;
    _ = out_diagnostic_capacity;
    _ = zig_lib_dir_opt;
    _ = local_cache_dir_opt;
    _ = global_cache_dir_opt;

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
) callconv(.c) ZapForkResult {
    _ = source_path;
    _ = target;
    _ = optimize;
    _ = out_diagnostic_buffer;
    _ = out_diagnostic_capacity;
    _ = zig_lib_dir_opt;
    _ = local_cache_dir_opt;
    _ = global_cache_dir_opt;

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

test "Phase 3 integration: NoOp manager resolves end-to-end through driver" {
    const allocator = std.testing.allocator;

    // Build a temp directory tree that mimics a real project's stdlib
    // layout — `lib/zap/memory/no_op.zap` declares the struct and points
    // at the manager source via `@memory_manager_source`.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib/zap/memory") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "src/memory/no_op") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;

    const stdlib_decl =
        \\@memory_manager_source = "src/memory/no_op/manager.zig"
        \\
        \\pub struct Zap.Memory.NoOp {
        \\}
        \\
    ;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/zap/memory/no_op.zap", .data = stdlib_decl }) catch return error.Unexpected;

    // Placeholder manager source — the mock fork ignores it and
    // synthesises the object file, but the path must exist on disk so
    // the driver's filesystem check passes.
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/memory/no_op/manager.zig", .data = "// placeholder" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);

    const stdlib_root = std.fs.path.join(allocator, &.{ tmp_path, "lib" }) catch return error.Unexpected;
    defer allocator.free(stdlib_root);
    const cache_root = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch return error.Unexpected;
    defer allocator.free(cache_root);

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var resolved = try resolve(
        allocator,
        .{
            .manager_name = "Zap.Memory.NoOp",
            .source_roots = &.{
                .{ .name = "zap_stdlib", .path = stdlib_root },
            },
            .project_root = tmp_path,
            .zap_source_root = tmp_path,
            .cache_dir = cache_root,
            .fork_compile_fn = mockForkCompileNoOp,
        },
        &diag,
    );
    defer freeResolved(allocator, &resolved);

    try std.testing.expect(!resolved.is_builtin_default);
    try std.testing.expectEqualStrings("Zap.Memory.NoOp", resolved.name);
    try std.testing.expectEqual(@as(u64, 0), resolved.declared_caps);
    try std.testing.expect(resolved.object_path != null);

    // The object the mock wrote must still be on disk under the cache.
    std.Io.Dir.cwd().access(std.Options.debug_io, resolved.object_path.?, .{}) catch return error.Unexpected;
}

test "Phase 3 integration: NoOp manager resolves end-to-end through driver (Mach-O)" {
    // Sibling of the ELF integration test above. Exercises the
    // Mach-O code path inside `section_parser.extractSection` and
    // `assertExportsManagerSymbol` — both of which the macOS dev
    // host's production builds rely on but had no test coverage
    // before this phase.
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib/zap/memory") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "src/memory/no_op") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "cache") catch return error.Unexpected;

    const stdlib_decl =
        \\@memory_manager_source = "src/memory/no_op/manager.zig"
        \\
        \\pub struct Zap.Memory.NoOp {
        \\}
        \\
    ;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/zap/memory/no_op.zap", .data = stdlib_decl }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/memory/no_op/manager.zig", .data = "// placeholder" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);

    const stdlib_root = std.fs.path.join(allocator, &.{ tmp_path, "lib" }) catch return error.Unexpected;
    defer allocator.free(stdlib_root);
    const cache_root = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch return error.Unexpected;
    defer allocator.free(cache_root);

    var diag_buf: [1024]u8 = undefined;
    var diag: DriverDiagnostic = .{ .buffer = &diag_buf };

    var resolved = try resolve(
        allocator,
        .{
            .manager_name = "Zap.Memory.NoOp",
            .source_roots = &.{
                .{ .name = "zap_stdlib", .path = stdlib_root },
            },
            .project_root = tmp_path,
            .zap_source_root = tmp_path,
            .cache_dir = cache_root,
            .fork_compile_fn = mockForkCompileNoOpMacho,
        },
        &diag,
    );
    defer freeResolved(allocator, &resolved);

    try std.testing.expect(!resolved.is_builtin_default);
    try std.testing.expectEqualStrings("Zap.Memory.NoOp", resolved.name);
    try std.testing.expectEqual(@as(u64, 0), resolved.declared_caps);
    try std.testing.expect(resolved.object_path != null);
    std.Io.Dir.cwd().access(std.Options.debug_io, resolved.object_path.?, .{}) catch return error.Unexpected;
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
        .declared_caps = 0x2, // GCOL bit, reserved
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
