//! Import-Driven File Discovery
//!
//! Discovers which source files to compile by starting from the entry point
//! struct and following struct references transitively. Builds a dependency
//! DAG and enforces no circular dependencies.
//!
//! Struct names map to file paths by convention:
//!   Config.Parser → lib/config/parser.zap
//!   App → lib/app.zap (or app.zap in project root)

const std = @import("std");
const zap = @import("root.zig");
const ast = zap.ast;

/// A root directory where structs can be found (project lib or dep lib).
pub const SourceRoot = struct {
    /// Display name for error messages (e.g., "project", "dep:json_parser")
    name: []const u8,
    /// Absolute path to the lib directory
    path: []const u8,
};

/// The result of file discovery: a struct dependency DAG.
pub const FileGraph = struct {
    allocator: std.mem.Allocator,

    /// Source path ownership invariant:
    /// `known_files` owns exactly one source path string per recorded source
    /// file. Every other FileGraph field that stores source paths borrows those
    /// buffers unless the field documents a narrower ownership rule.
    ///
    /// `canonical_files` is separate: it owns realpath strings used only for
    /// duplicate detection.
    ///
    /// Struct-name strings are owned by `file_to_structs`; maps keyed by struct
    /// name borrow those same buffers.
    ///
    /// Import-name strings are owned by `file_imports`.
    ///
    /// Compile-after glob pattern strings are owned by
    /// `file_compile_after_globs`.
    /// Struct name → file path (absolute)
    struct_to_file: std.StringHashMap([]const u8),

    /// File path → primary struct name declared by that file.
    file_to_struct: std.StringHashMap([]const u8),

    /// File path → all struct names declared by that file.
    /// The graph owns each struct-name element through this list; other maps
    /// borrow those same name buffers.
    file_to_structs: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// Every source file known to the graph, including files without a
    /// top-level struct such as protocol/impl-only files.
    known_files: std.StringHashMap(void),

    /// Realpath (absolute, fully resolved) form of every file recorded
    /// in the graph. Independent from `known_files` — `known_files`
    /// keys preserve the surface path the caller provided (used for
    /// downstream tooling that operates on user-facing paths), while
    /// `canonical_files` keys are the deduplicated identity for the
    /// underlying inode. Discovery uses this map to skip a file
    /// already recorded under a different surface path.
    canonical_files: std.StringHashMap(void),

    /// File path → list of struct names it references.
    /// The graph owns each import-name element through this list.
    file_imports: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// File path → list of files that import it
    file_imported_by: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// Files in topological order (dependencies before dependents)
    topo_order: std.ArrayListUnmanaged([]const u8),

    /// Indices into topo_order marking where each dependency level ends.
    /// Structs within the same level have no dependencies on each other
    /// and can be compiled in parallel.
    level_boundaries: std.ArrayListUnmanaged(u32) = .empty,

    /// Stdlib struct names (not discovered from files)
    stdlib_structs: std.StringHashMap(void),

    /// File path → source root name (e.g., "project", "dep:math_lib")
    /// Used to determine dep boundaries for private struct enforcement.
    file_source_root: std.StringHashMap([]const u8),

    /// Struct name → true if declared with private struct (private to dep)
    struct_is_private: std.StringHashMap(bool),

    /// File path → list of glob patterns the file declares with
    /// `@compile_after_glob`. Each pattern names files this one must be
    /// compiled AFTER. Used by structs that reflect on a file glob at
    /// macro-expansion time (e.g. a test runner enumerating test files):
    /// without an explicit ordering hint the topological sort can place
    /// the reflecting file ahead of its globbed peers, so reflection
    /// runs before those peers' macros have generated the functions
    /// the runner is querying.
    file_compile_after_globs: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// File path → matched source files from `@compile_after_glob`.
    /// Keys and matched-file items borrow source paths owned by `known_files`.
    /// These are order-only dependencies for topological sorting. They
    /// are deliberately separate from `file_imports`/`file_imported_by`
    /// so incremental invalidation does not treat every globbed file as
    /// an ordinary import dependency of the reflecting file.
    file_compile_after_files: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// Reverse index of `file_compile_after_files`, used only by
    /// topological sorting to release dependents when an order-only
    /// provider file has been emitted.
    /// Keys and dependent-file items borrow source paths owned by `known_files`.
    file_compile_after_by: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    pub fn init(allocator: std.mem.Allocator) FileGraph {
        return .{
            .allocator = allocator,
            .struct_to_file = std.StringHashMap([]const u8).init(allocator),
            .file_to_struct = std.StringHashMap([]const u8).init(allocator),
            .file_to_structs = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .known_files = std.StringHashMap(void).init(allocator),
            .canonical_files = std.StringHashMap(void).init(allocator),
            .file_imports = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .file_imported_by = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .topo_order = .empty,
            .level_boundaries = .empty,
            .stdlib_structs = std.StringHashMap(void).init(allocator),
            .file_source_root = std.StringHashMap([]const u8).init(allocator),
            .struct_is_private = std.StringHashMap(bool).init(allocator),
            .file_compile_after_globs = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .file_compile_after_files = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .file_compile_after_by = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *FileGraph) void {
        self.struct_to_file.deinit();
        self.file_to_struct.deinit();
        self.struct_is_private.deinit();
        {
            var it = self.file_to_structs.iterator();
            while (it.next()) |entry| freeOwnedStructNameList(self.allocator, entry.value_ptr);
        }
        self.file_to_structs.deinit();
        {
            var it = self.canonical_files.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        }
        self.canonical_files.deinit();
        {
            var it = self.file_imports.iterator();
            while (it.next()) |entry| freeOwnedImportList(self.allocator, entry.value_ptr);
        }
        self.file_imports.deinit();
        {
            var it = self.file_imported_by.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        }
        self.file_imported_by.deinit();
        self.topo_order.deinit(self.allocator);
        self.level_boundaries.deinit(self.allocator);
        self.stdlib_structs.deinit();
        self.file_source_root.deinit();
        {
            var it = self.file_compile_after_globs.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.items) |pattern| self.allocator.free(pattern);
                entry.value_ptr.deinit(self.allocator);
            }
        }
        self.file_compile_after_globs.deinit();
        {
            var it = self.file_compile_after_files.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        }
        self.file_compile_after_files.deinit();
        {
            var it = self.file_compile_after_by.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        }
        self.file_compile_after_by.deinit();
        {
            var it = self.known_files.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        }
        self.known_files.deinit();
    }

    pub fn structForFile(self: *const FileGraph, file_path: []const u8) ?[]const u8 {
        return self.file_to_struct.get(file_path);
    }

    pub fn structsForFile(self: *const FileGraph, file_path: []const u8) []const []const u8 {
        if (self.file_to_structs.get(file_path)) |structs| {
            return structs.items;
        }
        return &.{};
    }
};

pub const DiscoveryError = error{
    StructNotFound,
    CircularDependency,
    OutOfMemory,
    ReadError,
    ParseFailed,
};

fn discoveryIoError(err: anyerror) DiscoveryError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadError,
    };
}

fn isMissingPathError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.NotDir => true,
        else => false,
    };
}

fn freeOwnedStructNameList(alloc: std.mem.Allocator, names: *std.ArrayListUnmanaged([]const u8)) void {
    for (names.items) |name| alloc.free(name);
    names.deinit(alloc);
}

fn freeOwnedStructNameSliceElements(alloc: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| alloc.free(name);
}

fn freeOwnedImportList(alloc: std.mem.Allocator, imports: *std.ArrayListUnmanaged([]const u8)) void {
    for (imports.items) |import_name| alloc.free(import_name);
    imports.deinit(alloc);
}

fn freeOwnedImportSliceElements(alloc: std.mem.Allocator, imports: []const []const u8) void {
    for (imports) |import_name| alloc.free(import_name);
}

fn freeStringHashMapKeys(alloc: std.mem.Allocator, map: *std.StringHashMap(void)) void {
    var it = map.iterator();
    while (it.next()) |entry| alloc.free(entry.key_ptr.*);
}

const SourcePathOwnership = union(enum) {
    borrowed: []const u8,
    owned: []const u8,

    fn slice(self: SourcePathOwnership) []const u8 {
        return switch (self) {
            .borrowed => |path| path,
            .owned => |path| path,
        };
    }

    fn freeIfOwned(self: SourcePathOwnership, alloc: std.mem.Allocator) void {
        switch (self) {
            .borrowed => {},
            .owned => |path| alloc.free(path),
        }
    }
};

const RecordedSourcePath = struct {
    path: []const u8,
    inserted: bool,
};

fn recordKnownSourcePath(
    alloc: std.mem.Allocator,
    graph: *FileGraph,
    source_path: SourcePathOwnership,
) DiscoveryError!RecordedSourcePath {
    const candidate_path = switch (source_path) {
        .borrowed => |path| alloc.dupe(u8, path) catch return error.OutOfMemory,
        .owned => |path| path,
    };
    var candidate_path_needs_free = true;
    errdefer if (candidate_path_needs_free) alloc.free(candidate_path);

    const entry = graph.known_files.getOrPut(candidate_path) catch return error.OutOfMemory;
    if (entry.found_existing) {
        alloc.free(candidate_path);
        candidate_path_needs_free = false;
        return .{ .path = entry.key_ptr.*, .inserted = false };
    }

    entry.value_ptr.* = {};
    candidate_path_needs_free = false;
    return .{ .path = entry.key_ptr.*, .inserted = true };
}

fn removeKnownSourcePath(alloc: std.mem.Allocator, graph: *FileGraph, file_path: []const u8) void {
    if (graph.known_files.fetchRemove(file_path)) |removed_entry| {
        alloc.free(removed_entry.key);
    }
}

fn graphOwnedSourcePath(graph: *const FileGraph, file_path: []const u8) ?[]const u8 {
    return graph.known_files.getKey(file_path);
}

fn putOwnedStructReference(
    alloc: std.mem.Allocator,
    refs: *std.StringHashMap(void),
    struct_name: []const u8,
) error{OutOfMemory}!void {
    if (refs.contains(struct_name)) return;

    const owned_struct_name = try alloc.dupe(u8, struct_name);
    errdefer alloc.free(owned_struct_name);
    try refs.put(owned_struct_name, {});
}

fn putOwnedFileImports(
    alloc: std.mem.Allocator,
    graph: *FileGraph,
    file_path: []const u8,
    imports: std.ArrayListUnmanaged([]const u8),
) DiscoveryError!void {
    if (graph.file_imports.fetchPut(file_path, imports) catch return error.OutOfMemory) |displaced_entry| {
        var displaced_imports = displaced_entry.value;
        freeOwnedImportList(alloc, &displaced_imports);
    }
}

fn removeDeclaredStructMappings(graph: *FileGraph, declared_structs: []const []const u8) void {
    for (declared_structs) |struct_name| {
        _ = graph.struct_to_file.remove(struct_name);
        _ = graph.struct_is_private.remove(struct_name);
    }
}

fn removeOwnedFileStructsEntry(alloc: std.mem.Allocator, graph: *FileGraph, file_path: []const u8) void {
    if (graph.file_to_structs.fetchRemove(file_path)) |removed_entry| {
        var names = removed_entry.value;
        freeOwnedStructNameList(alloc, &names);
    }
}

fn declaredStructName(declared_structs: []const []const u8, struct_name: []const u8) ?[]const u8 {
    for (declared_structs) |declared_struct| {
        if (std.mem.eql(u8, declared_struct, struct_name)) return declared_struct;
    }
    return null;
}

fn graphPrimaryStructName(declared_structs: []const []const u8, primary_struct: ?[]const u8) ?[]const u8 {
    if (primary_struct) |struct_name| {
        return declaredStructName(declared_structs, struct_name);
    }
    if (declared_structs.len == 0) return null;
    return declared_structs[0];
}

/// Error details populated on failure. Caller provides this to discover()
/// to get human-readable error information without stderr writes.
pub const ErrorInfo = struct {
    unresolved_struct: ?[]const u8 = null,
    boundary_struct: ?[]const u8 = null,
    boundary_dep: ?[]const u8 = null,
    boundary_from: ?[]const u8 = null,
};

/// Discover all files reachable from the entry struct.
///
/// `entry_struct` is e.g. "App" (extracted from a build.zap root such as &App.main/0).
/// `source_roots` are directories to search for struct files, in priority order.
/// The first root is typically the project's own lib dir.
/// Name of the stdlib struct that's auto-imported into every Zap
/// struct (Elixir-style). The collector injects an
/// `import <kernel_struct_name>` into every struct's scope so the
/// macros and helpers defined in `lib/kernel.zap` (`if`, `unless`,
/// `|>`, `<>`, sigils, …) are reachable as bare calls without an
/// explicit import.
///
/// This is the single source of truth for the name. Every site that
/// needed to ask "is this the Kernel struct?" or "what name should I
/// inject as the auto-import?" reads it from here.
pub const kernel_struct_name = "Kernel";

/// Structs that discovery must always load even when no source file
/// references them. `kernel_struct_name` is here because the collector
/// injects auto-imports against it.
pub const AUTO_IMPORTS = [_][]const u8{
    kernel_struct_name,
};

pub fn discover(
    alloc: std.mem.Allocator,
    entry_struct: []const u8,
    source_roots: []const SourceRoot,
    stdlib_struct_names: []const []const u8,
    err_info: ?*ErrorInfo,
) DiscoveryError!FileGraph {
    return discoverWithSourceFiles(alloc, entry_struct, source_roots, stdlib_struct_names, &.{}, err_info);
}

pub fn discoverWithSourceFiles(
    alloc: std.mem.Allocator,
    entry_struct: []const u8,
    source_roots: []const SourceRoot,
    stdlib_struct_names: []const []const u8,
    explicit_source_files: []const []const u8,
    err_info: ?*ErrorInfo,
) DiscoveryError!FileGraph {
    var graph = FileGraph.init(alloc);
    errdefer graph.deinit();

    // Register stdlib structs so we don't try to discover them as files
    for (stdlib_struct_names) |name| {
        graph.stdlib_structs.put(name, {}) catch return error.OutOfMemory;
    }

    var native_type_structs = try discoverNativeTypeStructs(alloc, source_roots);
    defer freeNativeTypeStructs(alloc, &native_type_structs);

    // Discovery work queue
    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);

    // Seed with entry struct
    queue.append(alloc, entry_struct) catch return error.OutOfMemory;

    // Seed auto-imported structs. These are always compiled because their
    // exports are implicitly available in every struct (like Elixir's Kernel).
    for (&AUTO_IMPORTS) |auto_mod| {
        queue.append(alloc, auto_mod) catch return error.OutOfMemory;
    }

    try drainDiscoveryQueue(alloc, &graph, &queue, source_roots, &native_type_structs);

    for (explicit_source_files) |file_path| {
        // Pre-check against the canonical (realpath) form so we don't
        // re-read a file that's already recorded under a different
        // surface path. This avoids the duplicate-record hazard that
        // arises when the entry-point struct→file resolution
        // produces, e.g., `./fannkuch_redux.zap` while the explicit
        // glob expansion produces `././fannkuch_redux.zap` — both
        // resolve to the same realpath. `recordSourceFile` enforces
        // the same invariant so this pre-check is purely an
        // I/O optimization; correctness still holds without it.
        const canonical_check = try canonicalizeFilePath(alloc, file_path);
        if (graph.canonical_files.contains(canonical_check)) {
            alloc.free(canonical_check);
            continue;
        }
        alloc.free(canonical_check);

        const source_root_name = (try sourceRootNameForFile(alloc, file_path, source_roots)) orelse "project";
        const source = try readDiscoveredSourceFile(alloc, file_path);
        const primary_struct = primaryStructName(alloc, source) catch |err| {
            alloc.free(source);
            return err;
        };
        recordSourceFile(alloc, &graph, .{ .borrowed = file_path }, source_root_name, source, primary_struct, &queue, &native_type_structs) catch |err| {
            if (primary_struct) |struct_name| alloc.free(struct_name);
            alloc.free(source);
            return err;
        };
        if (primary_struct) |struct_name| alloc.free(struct_name);
        alloc.free(source);
        try drainDiscoveryQueue(alloc, &graph, &queue, source_roots, &native_type_structs);
    }

    // Resolve `@compile_after_glob` declarations into order-only file
    // dependencies. They affect topological/evaluation order, but are not
    // ordinary imports and must not feed broad incremental invalidation.
    try resolveCompileAfterGlobs(alloc, &graph);

    // Build imported_by (reverse index)
    {
        var it = graph.file_imports.iterator();
        while (it.next()) |entry| {
            const importer_file = entry.key_ptr.*;
            for (entry.value_ptr.items) |imported_struct| {
                if (graph.struct_to_file.get(imported_struct)) |imported_file| {
                    if (std.mem.eql(u8, imported_file, importer_file)) continue;
                    const by_entry = graph.file_imported_by.getOrPut(imported_file) catch
                        return error.OutOfMemory;
                    if (!by_entry.found_existing) {
                        by_entry.value_ptr.* = .empty;
                    }
                    by_entry.value_ptr.append(alloc, importer_file) catch return error.OutOfMemory;
                }
            }
        }
    }

    // Topological sort (Kahn's algorithm) — detect cycles
    try topologicalSort(alloc, &graph);

    // Enforce private struct dep boundaries: a private struct from dep A
    // cannot be referenced by code in dep B or the project.
    try enforceDepBoundaries(alloc, &graph, err_info);

    return graph;
}

fn drainDiscoveryQueue(
    alloc: std.mem.Allocator,
    graph: *FileGraph,
    queue: *std.ArrayListUnmanaged([]const u8),
    source_roots: []const SourceRoot,
    native_type_structs: *const NativeTypeStructs,
) DiscoveryError!void {
    while (queue.items.len > 0) {
        const struct_name = queue.orderedRemove(0);

        if (graph.struct_to_file.contains(struct_name)) continue;
        if (graph.stdlib_structs.contains(struct_name)) continue;

        const resolved = (try resolveStructToFile(alloc, struct_name, source_roots)) orelse continue;
        const source = readDiscoveredSourceFile(alloc, resolved.path) catch |err| {
            alloc.free(resolved.path);
            return err;
        };

        recordSourceFile(alloc, graph, .{ .owned = resolved.path }, resolved.source_root_name, source, struct_name, queue, native_type_structs) catch |err| {
            alloc.free(source);
            return err;
        };
        alloc.free(source);
    }
}

const NativeTypeStructs = std.EnumArray(zap.scope.NativeTypeKind, ?[]const u8);

fn freeNativeTypeStructs(alloc: std.mem.Allocator, native_type_structs: *NativeTypeStructs) void {
    inline for (std.meta.tags(zap.scope.NativeTypeKind)) |kind| {
        const slot = native_type_structs.getPtr(kind);
        if (slot.*) |struct_name| {
            alloc.free(struct_name);
            slot.* = null;
        }
    }
}

/// Canonicalize a file path to its absolute, fully-resolved form so
/// duplicate-file detection in the FileGraph can match paths that
/// point at the same on-disk file even when callers pass different
/// surface representations (e.g. `./foo.zap` vs `././foo.zap` vs an
/// absolute path).
///
/// The returned slice is owned by `alloc`.
fn canonicalizeFilePath(alloc: std.mem.Allocator, file_path: []const u8) DiscoveryError![]const u8 {
    var real_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path_len = std.Io.Dir.cwd().realPathFile(std.Options.debug_io, file_path, &real_path_buffer) catch |err|
        return discoveryIoError(err);
    return alloc.dupe(u8, real_path_buffer[0..real_path_len]) catch return error.OutOfMemory;
}

fn readDiscoveredSourceFile(alloc: std.mem.Allocator, file_path: []const u8) DiscoveryError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, alloc, .limited(10 * 1024 * 1024)) catch |err|
        return discoveryIoError(err);
}

fn recordSourceFile(
    alloc: std.mem.Allocator,
    graph: *FileGraph,
    source_path: SourcePathOwnership,
    source_root_name: []const u8,
    source: []const u8,
    primary_struct: ?[]const u8,
    queue: *std.ArrayListUnmanaged([]const u8),
    native_type_structs: *const NativeTypeStructs,
) DiscoveryError!void {
    // Track the canonical (realpath) form of every recorded file so
    // callers that pass different surface representations of the same
    // on-disk file (e.g. the entry-point struct→file resolution
    // produces `./foo.zap` while glob expansion produces
    // `././foo.zap`) don't double-record the file. Without this, the
    // same struct can land in `file_to_structs` twice and the
    // downstream `compileStructByStruct` pipeline lowers it to two
    // distinct `ir.Function` records with the same name — silently
    // breaking the chain-consistency invariants that arc/uniqueness audits
    // rely on.
    var source_path_consumed = false;
    errdefer if (!source_path_consumed) source_path.freeIfOwned(alloc);

    const canonical = try canonicalizeFilePath(alloc, source_path.slice());
    var canonical_transferred = false;
    errdefer {
        if (canonical_transferred) {
            if (graph.canonical_files.fetchRemove(canonical)) |removed_entry| {
                alloc.free(removed_entry.key);
            }
        } else {
            alloc.free(canonical);
        }
    }
    if (graph.canonical_files.contains(canonical)) {
        alloc.free(canonical);
        source_path.freeIfOwned(alloc);
        source_path_consumed = true;
        return;
    }
    graph.canonical_files.put(canonical, {}) catch return error.OutOfMemory;
    canonical_transferred = true;

    source_path_consumed = true;
    const recorded_source_path = try recordKnownSourcePath(alloc, graph, source_path);
    const file_path = recorded_source_path.path;
    var known_file_recorded = recorded_source_path.inserted;
    errdefer if (known_file_recorded) removeKnownSourcePath(alloc, graph, file_path);

    graph.file_source_root.put(file_path, source_root_name) catch return error.OutOfMemory;
    var source_root_recorded = true;
    errdefer if (source_root_recorded) {
        _ = graph.file_source_root.remove(file_path);
    };

    const declared_structs = structNamesInSource(alloc, source) catch return error.OutOfMemory;
    defer alloc.free(declared_structs);
    var graph_owns_declared_structs = false;
    var file_to_struct_recorded = false;
    errdefer {
        if (file_to_struct_recorded) _ = graph.file_to_struct.remove(file_path);
        removeDeclaredStructMappings(graph, declared_structs);
        if (graph_owns_declared_structs) {
            removeOwnedFileStructsEntry(alloc, graph, file_path);
        } else {
            freeOwnedStructNameSliceElements(alloc, declared_structs);
        }
    }
    if (declared_structs.len > 0) {
        var structs_for_file: std.ArrayListUnmanaged([]const u8) = .empty;
        var structs_for_file_transferred = false;
        errdefer if (!structs_for_file_transferred) structs_for_file.deinit(alloc);

        for (declared_structs) |struct_name| {
            structs_for_file.append(alloc, struct_name) catch return error.OutOfMemory;
        }

        for (declared_structs) |struct_name| {
            graph.struct_to_file.put(struct_name, file_path) catch return error.OutOfMemory;
            graph.struct_is_private.put(struct_name, false) catch return error.OutOfMemory;
        }
        graph.file_to_structs.put(file_path, structs_for_file) catch return error.OutOfMemory;
        structs_for_file_transferred = true;
        graph_owns_declared_structs = true;
    }

    if (graphPrimaryStructName(declared_structs, primary_struct)) |struct_name| {
        graph.struct_to_file.put(struct_name, file_path) catch return error.OutOfMemory;
        graph.file_to_struct.put(file_path, struct_name) catch return error.OutOfMemory;
        file_to_struct_recorded = true;
        graph.struct_is_private.put(struct_name, isPrivateStruct(source)) catch return error.OutOfMemory;
    }

    const refs = extractStructReferences(alloc, source, primary_struct orelse "") catch
        return error.OutOfMemory;
    defer alloc.free(refs);

    var imports_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var imports_list_transferred = false;
    errdefer if (!imports_list_transferred) freeOwnedImportList(alloc, &imports_list);
    var import_seen = std.StringHashMap(void).init(alloc);
    defer import_seen.deinit();

    var next_ref_index: usize = 0;
    errdefer {
        for (refs[next_ref_index..]) |unprocessed_ref| alloc.free(unprocessed_ref);
    }
    while (next_ref_index < refs.len) {
        const ref = refs[next_ref_index];
        next_ref_index += 1;
        var ref_transferred = false;
        errdefer if (!ref_transferred) alloc.free(ref);
        ref_transferred = try appendOwnedDiscoveredImport(alloc, graph, queue, &imports_list, &import_seen, declared_structs, primary_struct, ref);
        if (!ref_transferred) alloc.free(ref);
    }

    const native_refs = nativeTypeReferencesInSource(alloc, source, native_type_structs) catch return error.OutOfMemory;
    defer alloc.free(native_refs);
    for (native_refs) |ref| {
        try appendNativeTypeImport(alloc, graph, queue, &imports_list, &import_seen, declared_structs, primary_struct, ref);
    }

    const compile_after_globs = extractCompileAfterGlobs(alloc, source) catch return error.OutOfMemory;
    defer alloc.free(compile_after_globs);
    var compile_after_globs_recorded = false;
    errdefer if (compile_after_globs_recorded) {
        if (graph.file_compile_after_globs.fetchRemove(file_path)) |removed_entry| {
            var recorded_globs = removed_entry.value;
            for (recorded_globs.items) |pattern| alloc.free(pattern);
            recorded_globs.deinit(alloc);
        }
    };
    if (compile_after_globs.len > 0) {
        var globs_list: std.ArrayListUnmanaged([]const u8) = .empty;
        var transferred_glob_count: usize = 0;
        errdefer {
            for (globs_list.items) |pattern| alloc.free(pattern);
            for (compile_after_globs[transferred_glob_count..]) |pattern| alloc.free(pattern);
            globs_list.deinit(alloc);
        }
        for (compile_after_globs) |pattern| {
            globs_list.append(alloc, pattern) catch return error.OutOfMemory;
            transferred_glob_count += 1;
        }
        graph.file_compile_after_globs.put(file_path, globs_list) catch return error.OutOfMemory;
        compile_after_globs_recorded = true;
    }

    try putOwnedFileImports(alloc, graph, file_path, imports_list);
    imports_list_transferred = true;
    compile_after_globs_recorded = false;
    source_root_recorded = false;
    known_file_recorded = false;
    canonical_transferred = false;
}

fn appendOwnedDiscoveredImport(
    alloc: std.mem.Allocator,
    graph: *FileGraph,
    queue: *std.ArrayListUnmanaged([]const u8),
    imports_list: *std.ArrayListUnmanaged([]const u8),
    import_seen: *std.StringHashMap(void),
    declared_structs: []const []const u8,
    primary_struct: ?[]const u8,
    ref: []const u8,
) DiscoveryError!bool {
    if (!shouldAppendDiscoveredImport(graph, import_seen, declared_structs, primary_struct, ref)) return false;
    try recordDiscoveredImport(alloc, graph, queue, imports_list, import_seen, ref);
    return true;
}

fn appendNativeTypeImport(
    alloc: std.mem.Allocator,
    graph: *FileGraph,
    queue: *std.ArrayListUnmanaged([]const u8),
    imports_list: *std.ArrayListUnmanaged([]const u8),
    import_seen: *std.StringHashMap(void),
    declared_structs: []const []const u8,
    primary_struct: ?[]const u8,
    ref: []const u8,
) DiscoveryError!void {
    if (!shouldAppendDiscoveredImport(graph, import_seen, declared_structs, primary_struct, ref)) return;

    const owned_ref = alloc.dupe(u8, ref) catch return error.OutOfMemory;
    var owned_ref_transferred = false;
    errdefer if (!owned_ref_transferred) alloc.free(owned_ref);

    try recordDiscoveredImport(alloc, graph, queue, imports_list, import_seen, owned_ref);
    owned_ref_transferred = true;
}

fn shouldAppendDiscoveredImport(
    graph: *const FileGraph,
    import_seen: *const std.StringHashMap(void),
    declared_structs: []const []const u8,
    primary_struct: ?[]const u8,
    ref: []const u8,
) bool {
    if (primary_struct) |struct_name| {
        if (std.mem.eql(u8, ref, struct_name)) return false;
    }
    if (structNameDeclaredInFile(declared_structs, ref)) return false;
    if (graph.stdlib_structs.contains(ref)) return false;
    if (import_seen.contains(ref)) return false;
    return true;
}

fn recordDiscoveredImport(
    alloc: std.mem.Allocator,
    graph: *FileGraph,
    queue: *std.ArrayListUnmanaged([]const u8),
    imports_list: *std.ArrayListUnmanaged([]const u8),
    import_seen: *std.StringHashMap(void),
    ref: []const u8,
) DiscoveryError!void {
    const should_queue = !graph.struct_to_file.contains(ref);

    import_seen.ensureUnusedCapacity(1) catch return error.OutOfMemory;
    imports_list.ensureUnusedCapacity(alloc, 1) catch return error.OutOfMemory;
    if (should_queue) {
        queue.ensureUnusedCapacity(alloc, 1) catch return error.OutOfMemory;
    }

    import_seen.putAssumeCapacity(ref, {});
    imports_list.appendAssumeCapacity(ref);
    if (should_queue) queue.appendAssumeCapacity(ref);
}

fn discoverNativeTypeStructs(
    alloc: std.mem.Allocator,
    source_roots: []const SourceRoot,
) DiscoveryError!NativeTypeStructs {
    var native_type_structs = NativeTypeStructs.initFill(null);
    errdefer freeNativeTypeStructs(alloc, &native_type_structs);
    for (source_roots) |root| {
        try scanNativeTypesInDir(alloc, root.path, &native_type_structs);
    }
    return native_type_structs;
}

fn scanNativeTypesInDir(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    native_type_structs: *NativeTypeStructs,
) DiscoveryError!void {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch |err|
        return discoveryIoError(err);
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();
    while (iter.next(std.Options.debug_io) catch |err| return discoveryIoError(err)) |entry| {
        if (entry.kind == .directory) {
            const child_path = std.fs.path.join(alloc, &.{ dir_path, entry.name }) catch return error.OutOfMemory;
            defer alloc.free(child_path);
            try scanNativeTypesInDir(alloc, child_path, native_type_structs);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;

        const file_path = std.fs.path.join(alloc, &.{ dir_path, entry.name }) catch return error.OutOfMemory;
        defer alloc.free(file_path);
        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, alloc, .limited(10 * 1024 * 1024)) catch |err|
            return discoveryIoError(err);
        defer alloc.free(source);
        if (try nativeTypeDeclarationInSource(alloc, source)) |declaration| {
            const slot = native_type_structs.getPtr(declaration.kind);
            if (slot.* == null) {
                slot.* = declaration.struct_name;
            } else {
                alloc.free(declaration.struct_name);
            }
        }
    }
}

const NativeTypeDeclaration = struct {
    kind: zap.scope.NativeTypeKind,
    struct_name: []const u8,
};

fn nativeTypeDeclarationInSource(
    alloc: std.mem.Allocator,
    source: []const u8,
) error{OutOfMemory}!?NativeTypeDeclaration {
    var lexer = zap.Lexer.init(source);
    var pending_kind: ?zap.scope.NativeTypeKind = null;

    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;

        if (tok.tag == .at_sign) {
            const name_tok = lexer.next();
            if (name_tok.tag != .identifier) continue;
            if (!std.mem.eql(u8, name_tok.slice(source), "native_type")) continue;

            const equal_tok = lexer.next();
            if (equal_tok.tag != .equal) continue;

            const value_tok = lexer.next();
            if (value_tok.tag != .string_literal) continue;
            pending_kind = zap.scope.NativeTypeKind.fromName(stringLiteralContents(value_tok.slice(source)));
            continue;
        }

        if (tok.tag == .keyword_struct or tok.tag == .keyword_pub) {
            var struct_lexer = lexer;
            const struct_tok = if (tok.tag == .keyword_pub) struct_lexer.next() else tok;
            if (struct_tok.tag != .keyword_struct) continue;

            const name_tok = struct_lexer.next();
            if (name_tok.tag != .type_identifier) continue;
            const kind = pending_kind orelse continue;

            var name_buf: std.ArrayListUnmanaged(u8) = .empty;
            errdefer name_buf.deinit(alloc);
            try name_buf.appendSlice(alloc, name_tok.slice(source));
            var peek = struct_lexer;
            while (true) {
                const dot_tok = peek.next();
                if (dot_tok.tag != .dot) break;
                const next_tok = peek.next();
                if (next_tok.tag != .type_identifier) break;
                try name_buf.append(alloc, '.');
                try name_buf.appendSlice(alloc, next_tok.slice(source));
                struct_lexer = peek;
            }

            return .{
                .kind = kind,
                .struct_name = try name_buf.toOwnedSlice(alloc),
            };
        }
    }

    return null;
}

fn stringLiteralContents(literal: []const u8) []const u8 {
    if (literal.len >= 2 and literal[0] == '"' and literal[literal.len - 1] == '"') {
        return literal[1 .. literal.len - 1];
    }
    return literal;
}

fn nativeTypeReferencesInSource(
    alloc: std.mem.Allocator,
    source: []const u8,
    native_type_structs: *const NativeTypeStructs,
) error{OutOfMemory}![]const []const u8 {
    var refs = std.StringHashMap(void).init(alloc);
    defer refs.deinit();

    var lexer = zap.Lexer.init(source);
    var in_attribute = false;
    var in_type_annotation = false;
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;

        if (tok.tag == .at_sign) {
            in_attribute = true;
            continue;
        }
        if (in_attribute) {
            if (tok.tag == .newline) in_attribute = false;
            continue;
        }
        if (tok.tag == .double_colon or tok.tag == .arrow) {
            in_type_annotation = true;
            continue;
        }
        if (in_type_annotation) {
            switch (tok.tag) {
                .comma, .right_paren, .left_brace, .equal, .newline => in_type_annotation = false,
                else => {},
            }
            continue;
        }

        const kind: ?zap.scope.NativeTypeKind = switch (tok.tag) {
            .left_bracket => .list,
            .percent_brace => .map,
            .dot_dot => .range,
            .string_literal, .string_literal_start, .string_literal_part, .string_literal_end => .string,
            else => null,
        };
        const native_kind = kind orelse continue;
        const struct_name = native_type_structs.get(native_kind) orelse continue;
        try refs.put(struct_name, {});
    }

    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer result.deinit(alloc);
    var it = refs.iterator();
    while (it.next()) |entry| {
        try result.append(alloc, entry.key_ptr.*);
    }
    return try result.toOwnedSlice(alloc);
}

/// Enforce that private struct structs are not referenced across dep boundaries.
/// A struct declared with private struct in dep "dep:foo" is only visible to
/// other structs in "dep:foo". Project code and other deps cannot access it.
fn enforceDepBoundaries(alloc: std.mem.Allocator, graph: *FileGraph, err_info: ?*ErrorInfo) DiscoveryError!void {
    _ = alloc;
    var had_error = false;

    var import_it = graph.file_imports.iterator();
    while (import_it.next()) |entry| {
        const importer_file = entry.key_ptr.*;
        const importer_root = graph.file_source_root.get(importer_file) orelse continue;

        for (entry.value_ptr.items) |imported_struct| {
            // Check if the imported struct is private
            const is_private = graph.struct_is_private.get(imported_struct) orelse false;
            if (!is_private) continue;

            // Get the source root of the imported struct's file
            const imported_file = graph.struct_to_file.get(imported_struct) orelse continue;
            const imported_root = graph.file_source_root.get(imported_file) orelse continue;

            // If they're in different source roots, it's a boundary violation
            if (!std.mem.eql(u8, importer_root, imported_root)) {
                if (err_info) |info| {
                    info.boundary_struct = imported_struct;
                    info.boundary_dep = imported_root;
                    info.boundary_from = importer_root;
                }
                had_error = true;
            }
        }
    }

    if (had_error) return error.StructNotFound;
}

/// Convert a struct name to a relative file path.
/// "Config.Parser" → "config/parser.zap"
/// Caller owns the returned slice and must free it with the same allocator.
pub fn structNameToRelPath(alloc: std.mem.Allocator, struct_name: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(alloc);

    var it = std.mem.splitScalar(u8, struct_name, '.');
    var first = true;
    while (it.next()) |segment| {
        if (!first) try result.append(alloc, '/');
        first = false;

        // PascalCase → snake_case
        // Only insert '_' when transitioning from lowercase to uppercase,
        // not between consecutive uppercase letters (IO → io, not i_o).
        for (segment, 0..) |c, i| {
            if (std.ascii.isUpper(c)) {
                if (i > 0 and !std.ascii.isUpper(segment[i - 1])) {
                    try result.append(alloc, '_');
                }
                try result.append(alloc, std.ascii.toLower(c));
            } else {
                try result.append(alloc, c);
            }
        }
    }
    try result.appendSlice(alloc, ".zap");
    return try result.toOwnedSlice(alloc);
}

const ResolvedFile = struct {
    path: []const u8,
    source_root_name: []const u8,
};

/// Try to resolve a struct name to an absolute file path by checking source roots.
/// Returns the file path and the name of the source root it was found in.
fn resolveStructToFile(
    alloc: std.mem.Allocator,
    struct_name: []const u8,
    source_roots: []const SourceRoot,
) DiscoveryError!?ResolvedFile {
    const rel_path = try structNameToRelPath(alloc, struct_name);
    defer alloc.free(rel_path);

    // Try the full relative path first
    for (source_roots) |root| {
        const full_path = try std.fs.path.join(alloc, &.{ root.path, rel_path });
        std.Io.Dir.cwd().access(std.Options.debug_io, full_path, .{}) catch |err| {
            alloc.free(full_path);
            if (isMissingPathError(err)) continue;
            return discoveryIoError(err);
        };
        return .{ .path = full_path, .source_root_name = root.name };
    }

    // If the struct name has a prefix (e.g., "Test.StringTest"), try stripping
    // the first segment and resolving within each source root. This handles the
    // convention where `test/` is a source root and structs are named
    // `Test.StructName` — the `Test.` prefix maps to the source root, not to
    // a subdirectory within it.
    if (std.mem.indexOfScalar(u8, struct_name, '.')) |dot_pos| {
        const suffix = struct_name[dot_pos + 1 ..];
        const suffix_path = try structNameToRelPath(alloc, suffix);
        defer alloc.free(suffix_path);
        for (source_roots) |root| {
            const full_path = try std.fs.path.join(alloc, &.{ root.path, suffix_path });
            std.Io.Dir.cwd().access(std.Options.debug_io, full_path, .{}) catch |err| {
                alloc.free(full_path);
                if (isMissingPathError(err)) continue;
                return discoveryIoError(err);
            };
            return .{ .path = full_path, .source_root_name = root.name };
        }
    }

    return null;
}

fn sourceRootNameForFile(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    source_roots: []const SourceRoot,
) error{OutOfMemory}!?[]const u8 {
    const normalized_file = if (std.mem.startsWith(u8, file_path, "./")) file_path[2..] else file_path;
    for (source_roots) |root| {
        const normalized_root = if (std.mem.startsWith(u8, root.path, "./")) root.path[2..] else root.path;
        if (std.mem.eql(u8, normalized_file, normalized_root)) return root.name;
        const root_slash = try std.fmt.allocPrint(alloc, "{s}/", .{normalized_root});
        defer alloc.free(root_slash);
        if (std.mem.startsWith(u8, normalized_file, root_slash)) return root.name;
    }
    return null;
}

pub fn primaryStructName(alloc: std.mem.Allocator, source: []const u8) error{OutOfMemory}!?[]const u8 {
    const declared_structs = try structNamesInSource(alloc, source);
    defer alloc.free(declared_structs);
    if (declared_structs.len == 0) return null;

    const primary_struct = declared_structs[0];
    freeOwnedStructNameSliceElements(alloc, declared_structs[1..]);
    return primary_struct;
}

fn structNamesInSource(alloc: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    var lexer = zap.Lexer.init(source);
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;
        if (tok.tag != .keyword_struct) continue;

        const name_tok = lexer.next();
        if (name_tok.tag != .type_identifier) continue;

        var name_buf: std.ArrayListUnmanaged(u8) = .empty;
        var name_buf_transferred = false;
        errdefer if (!name_buf_transferred) name_buf.deinit(alloc);
        try name_buf.appendSlice(alloc, name_tok.slice(source));

        var peek = lexer;
        while (true) {
            const dot_tok = peek.next();
            if (dot_tok.tag != .dot) break;
            const next_tok = peek.next();
            if (next_tok.tag != .type_identifier) break;
            try name_buf.append(alloc, '.');
            try name_buf.appendSlice(alloc, next_tok.slice(source));
            lexer = peek;
        }

        const name = try name_buf.toOwnedSlice(alloc);
        name_buf_transferred = true;
        var name_transferred = false;
        errdefer if (!name_transferred) alloc.free(name);
        try names.append(alloc, name);
        name_transferred = true;
    }

    return try names.toOwnedSlice(alloc);
}

fn structNameDeclaredInFile(declared_structs: []const []const u8, ref: []const u8) bool {
    for (declared_structs) |struct_name| {
        if (std.mem.eql(u8, struct_name, ref)) return true;
    }
    return false;
}

/// Check if a source file declares its struct without `pub` (private).
/// Uses the lexer for a fast scan — no full parsing needed.
/// A `struct Name {` declaration is private; `pub struct Name {` is public.
fn isPrivateStruct(source: []const u8) bool {
    var lexer = zap.Lexer.init(source);
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;
        if (tok.tag == .keyword_struct) return true; // bare `struct` = private
        if (tok.tag == .keyword_pub) return false; // `pub struct` = public
    }
    return false;
}

/// Extract struct references from a source file using the lexer.
///
/// Scans for `type_identifier` tokens (capitalized identifiers) that appear
/// in positions indicating a struct reference:
/// - Before a `.` followed by an identifier or another type_identifier
///   (qualified call or field access)
/// - After `%` (struct literal)
/// - After `::` in certain positions (type annotations)
///
/// Returns a deduplicated list of struct names (e.g., ["Config", "IO", "Config.Parser"]).
fn extractStructReferences(
    alloc: std.mem.Allocator,
    source: []const u8,
    _: []const u8, // self_struct (unused for now)
) ![]const []const u8 {
    var refs = std.StringHashMap(void).init(alloc);
    defer refs.deinit();
    var refs_transferred = false;
    errdefer if (!refs_transferred) freeStringHashMapKeys(alloc, &refs);

    var lexer = zap.Lexer.init(source);

    // Track context to distinguish struct references from union variants,
    // struct names, and other non-struct uppercase identifiers.
    // We skip uppercase identifiers that appear inside union/struct/enum bodies
    // as bare names (without a dot-call or being after `use`/`import`).
    var inside_union_body = false;
    var inside_struct_body = false;
    var brace_depth: u32 = 0;
    var union_brace_depth: u32 = 0;
    var struct_brace_depth: u32 = 0;
    var prev_tag: zap.Token.Tag = .eof;

    // Phase 1.2 `pub error` desugar introduces references to `Option`
    // and `Error` (via the auto-injected `cause :: Option(Error)` field
    // and the auto-generated `pub impl Error for X` block). Those
    // identifiers never appear in the user's source, so discovery —
    // which is lexer-driven and runs BEFORE desugar — would otherwise
    // never load `lib/option.zap` or `lib/error.zap`. We make the
    // requirement explicit: as soon as the file declares a `pub error`
    // (or bare `error`), seed the reference set with both stdlib
    // structs so the standard import-driven loader picks them up.
    {
        var scout = zap.Lexer.init(source);
        while (true) {
            const tok = scout.next();
            if (tok.tag == .eof) break;
            // `error` is a contextual keyword (Token.isErrorIdent): the
            // lexer emits a bare `identifier` whose text is exactly
            // "error". Match on the slice so this discovery scout stays
            // in sync with the parser's contextual reading.
            if (tok.isErrorIdent(source)) {
                try putOwnedStructReference(alloc, &refs, "Option");
                try putOwnedStructReference(alloc, &refs, "Error");
                break;
            }
        }
    }

    // Phase 1.4 `raise` desugar introduces references to `RuntimeError`
    // (for the `raise "string"` shorthand, normalised to
    // `%RuntimeError{...}`) plus `Error`/`Option` (RuntimeError is a
    // `pub error`, so its auto-injected `cause :: Option(Error)` field and
    // `pub impl Error` block pull those in). Those identifiers never
    // appear in the user's source, so the lexer-driven discovery — which
    // runs BEFORE desugar — would otherwise never load `lib/error.zap`.
    // As soon as the file uses the contextual `raise` keyword, seed the
    // reference set so the standard import-driven loader picks them up.
    {
        var scout = zap.Lexer.init(source);
        while (true) {
            const tok = scout.next();
            if (tok.tag == .eof) break;
            if (tok.isRaiseIdent(source)) {
                try putOwnedStructReference(alloc, &refs, "RuntimeError");
                try putOwnedStructReference(alloc, &refs, "Option");
                try putOwnedStructReference(alloc, &refs, "Error");
                break;
            }
        }
    }

    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;

        // Track brace nesting for union/struct body detection
        if (tok.tag == .left_brace) {
            brace_depth += 1;
        } else if (tok.tag == .right_brace) {
            if (brace_depth > 0) brace_depth -= 1;
            if (inside_union_body and brace_depth < union_brace_depth) {
                inside_union_body = false;
            }
            if (inside_struct_body and brace_depth < struct_brace_depth) {
                inside_struct_body = false;
            }
        }

        // Detect entering union body: `union Name {` or `pub union Name {`
        if (tok.tag == .keyword_union) {
            var peek = lexer;
            const name_tok = peek.next();
            if (name_tok.tag == .type_identifier) {
                const brace_tok = peek.next();
                if (brace_tok.tag == .left_brace) {
                    inside_union_body = true;
                    union_brace_depth = brace_depth + 1;
                }
            }
        }

        // Detect entering struct body: `struct Name {` or `pub struct Name {`
        if (tok.tag == .keyword_struct) {
            var peek = lexer;
            const name_tok = peek.next();
            if (name_tok.tag == .type_identifier) {
                const brace_tok = peek.next();
                if (brace_tok.tag == .left_brace) {
                    inside_struct_body = true;
                    struct_brace_depth = brace_depth + 1;
                }
            }
        }

        if (tok.tag == .type_identifier) {
            if (prev_tag == .keyword_struct or prev_tag == .keyword_union) {
                var declaration_name_peek = lexer;
                while (true) {
                    const dot_tok = declaration_name_peek.next();
                    if (dot_tok.tag != .dot) break;
                    const next_tok = declaration_name_peek.next();
                    if (next_tok.tag != .type_identifier) break;
                    lexer = declaration_name_peek;
                }
                prev_tag = tok.tag;
                continue;
            }

            const name_text = tok.slice(source);

            // Skip: bare uppercase identifiers inside union bodies are variants, not structs.
            // e.g., `pub union Color { Red, Green, Blue }` — Red/Green/Blue are variants.
            if (inside_union_body) {
                // Check if this is a bare variant name (not followed by `.function()`)
                var peek = lexer;
                const next = peek.next();
                if (next.tag != .dot) {
                    // Bare name inside union body — skip as variant declaration
                    continue;
                }
                // If followed by dot, it's a qualified reference like Struct.function — proceed
            }

            // Skip: identifiers after `::` or `->` are type annotations, not struct calls.
            // `:: String` is a parameter type, `-> Bool` is a return type.
            // Exception: if followed by `.` it's a struct-qualified type like `Zap.Env`.
            if (prev_tag == .double_colon or prev_tag == .arrow) {
                var peek = lexer;
                const next = peek.next();
                if (next.tag != .dot) {
                    continue;
                }
            }

            // Collect the full dotted struct name: Foo.Bar.Baz
            var name_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer name_buf.deinit(alloc);
            try name_buf.appendSlice(alloc, name_text);

            // Look ahead for .TypeIdentifier chains
            var peek_lexer = lexer;
            while (true) {
                const dot_tok = peek_lexer.next();
                if (dot_tok.tag != .dot) break;

                const next_tok = peek_lexer.next();
                if (next_tok.tag == .type_identifier) {
                    try name_buf.append(alloc, '.');
                    try name_buf.appendSlice(alloc, next_tok.slice(source));
                    lexer = peek_lexer;
                } else {
                    // Dot followed by a lowercase identifier = function call on the struct
                    // The struct part is what we've collected so far
                    break;
                }
            }

            try putOwnedStructReference(alloc, &refs, name_buf.items);
        }

        prev_tag = tok.tag;
    }

    // Convert to array
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer result.deinit(alloc);
    var it = refs.iterator();
    while (it.next()) |entry| {
        try result.append(alloc, entry.key_ptr.*);
    }
    const owned_refs = try result.toOwnedSlice(alloc);
    refs_transferred = true;
    return owned_refs;
}

/// Topological sort of the file graph using Kahn's algorithm.
/// Produces dependencies-first ordering. Detects circular dependencies.
/// Extract `@compile_after_glob` attribute values from a file's source.
/// Accepts the same syntactic forms the parser does:
///   `@compile_after_glob = "test/**/*_test.zap"`
///   `@compile_after_glob = ["a/*.zap", "b/*.zap"]`
/// Returns a deduplicated, allocator-owned list of pattern strings;
/// the caller frees each entry plus the outer slice.
fn extractCompileAfterGlobs(alloc: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]const []const u8 {
    var patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (patterns.items) |p| alloc.free(p);
        patterns.deinit(alloc);
    }

    const needle = "@compile_after_glob";
    var search_index: usize = 0;
    while (search_index < source.len) {
        const found_offset = std.mem.indexOfPos(u8, source, search_index, needle) orelse break;
        const after_needle = found_offset + needle.len;
        search_index = after_needle;

        // Skip whitespace and an optional `=`. Anything else means this
        // hit isn't an attribute assignment (could be inside a string,
        // doc comment, etc.) — bail to the next match without recording.
        var cursor = after_needle;
        while (cursor < source.len and (source[cursor] == ' ' or source[cursor] == '\t')) cursor += 1;
        if (cursor >= source.len or source[cursor] != '=') continue;
        cursor += 1;
        while (cursor < source.len and (source[cursor] == ' ' or source[cursor] == '\t' or source[cursor] == '\n')) cursor += 1;
        if (cursor >= source.len) continue;

        const ch = source[cursor];
        if (ch == '"') {
            const end_quote = std.mem.indexOfScalarPos(u8, source, cursor + 1, '"') orelse continue;
            const pattern = source[cursor + 1 .. end_quote];
            const dup = try alloc.dupe(u8, pattern);
            patterns.append(alloc, dup) catch |err| {
                alloc.free(dup);
                return err;
            };
        } else if (ch == '[') {
            // Walk the list, picking out each "..." element. Stops at
            // the first unmatched `]` or end of input.
            var inner = cursor + 1;
            while (inner < source.len and source[inner] != ']') {
                while (inner < source.len and source[inner] != '"' and source[inner] != ']') inner += 1;
                if (inner >= source.len or source[inner] == ']') break;
                const end_quote = std.mem.indexOfScalarPos(u8, source, inner + 1, '"') orelse break;
                const pattern = source[inner + 1 .. end_quote];
                const dup = try alloc.dupe(u8, pattern);
                patterns.append(alloc, dup) catch |err| {
                    alloc.free(dup);
                    return err;
                };
                inner = end_quote + 1;
            }
        }
    }

    return patterns.toOwnedSlice(alloc);
}

/// For each file with `@compile_after_glob` patterns, glob-expand each
/// pattern and record matched files as order-only dependencies. The
/// topological sort then orders the declaring file after each matched
/// peer without exposing those edges as ordinary imports to later
/// incremental invalidation.
fn resolveCompileAfterGlobs(alloc: std.mem.Allocator, graph: *FileGraph) DiscoveryError!void {
    const glob_mod = @import("glob.zig");
    var glob_it = graph.file_compile_after_globs.iterator();
    while (glob_it.next()) |entry| {
        const declaring_file = entry.key_ptr.*;
        for (entry.value_ptr.items) |pattern| {
            const matches = glob_mod.collect(alloc, std.Options.debug_io, pattern, .{}) catch |err|
                return discoveryIoError(err);
            defer glob_mod.freeMatches(alloc, matches);
            for (matches) |matched_path| {
                // Normalize so leading `./` (often present on graph keys
                // because the compiler walks relative paths from the
                // project root) matches whether the glob produced the
                // bare or prefixed form.
                var prefixed_lookup_key: ?[]u8 = null;
                defer if (prefixed_lookup_key) |key| alloc.free(key);
                const lookup_key = if (graph.file_to_struct.contains(matched_path))
                    matched_path
                else blk: {
                    const prefixed = try std.fmt.allocPrint(alloc, "./{s}", .{matched_path});
                    prefixed_lookup_key = prefixed;
                    if (graph.file_to_struct.contains(prefixed)) break :blk prefixed;
                    break :blk matched_path;
                };
                if (std.mem.eql(u8, lookup_key, declaring_file)) continue;
                if (!graph.known_files.contains(lookup_key)) continue;
                try appendCompileAfterFileEdge(alloc, graph, declaring_file, lookup_key);
            }
        }
    }
}

fn appendCompileAfterFileEdge(
    alloc: std.mem.Allocator,
    graph: *FileGraph,
    declaring_file: []const u8,
    matched_file: []const u8,
) DiscoveryError!void {
    const graph_declaring_file = graphOwnedSourcePath(graph, declaring_file) orelse unreachable;
    const graph_matched_file = graphOwnedSourcePath(graph, matched_file) orelse unreachable;

    if (graph.file_compile_after_files.get(graph_declaring_file)) |existing_matches| {
        for (existing_matches.items) |existing| {
            if (std.mem.eql(u8, existing, graph_matched_file)) return;
        }
    }

    {
        const entry = try graph.file_compile_after_files.getOrPut(graph_declaring_file);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(alloc, graph_matched_file);
    }

    {
        const entry = try graph.file_compile_after_by.getOrPut(graph_matched_file);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        for (entry.value_ptr.items) |existing| {
            if (std.mem.eql(u8, existing, graph_declaring_file)) return;
        }
        try entry.value_ptr.append(alloc, graph_declaring_file);
    }
}

fn indexOfPath(paths: []const []const u8, needle: []const u8) ?usize {
    for (paths, 0..) |path, index| {
        if (std.mem.eql(u8, path, needle)) return index;
    }
    return null;
}

fn topologicalSort(alloc: std.mem.Allocator, graph: *FileGraph) DiscoveryError!void {
    // in_degree[file] = number of dependencies this file has (how many structs it imports
    // that are in the graph). Files with in_degree 0 have no dependencies = leaf libraries.
    var in_degree = std.StringHashMap(u32).init(alloc);
    defer in_degree.deinit();

    // Initialize all known files with in-degree 0. Some source files
    // intentionally have no primary struct, such as protocol/impl-only
    // files collected from manifest globs.
    var file_it = graph.known_files.iterator();
    while (file_it.next()) |entry| {
        in_degree.put(entry.key_ptr.*, 0) catch return error.OutOfMemory;
    }

    // Count dependencies: for each file, count how many of its imports resolve to files in the graph
    var import_it = graph.file_imports.iterator();
    while (import_it.next()) |entry| {
        const importing_file = entry.key_ptr.*;
        var dep_count: u32 = 0;
        for (entry.value_ptr.items) |imported_struct| {
            if (graph.struct_to_file.get(imported_struct)) |imported_file| {
                if (std.mem.eql(u8, imported_file, importing_file)) continue;
                dep_count += 1;
            }
        }
        if (in_degree.getPtr(importing_file)) |deg| {
            deg.* = dep_count;
        }
    }

    var compile_after_it = graph.file_compile_after_files.iterator();
    while (compile_after_it.next()) |entry| {
        const declaring_file = entry.key_ptr.*;
        const deg = in_degree.getPtr(declaring_file) orelse continue;
        for (entry.value_ptr.items) |matched_file| {
            if (std.mem.eql(u8, matched_file, declaring_file)) continue;
            if (!graph.known_files.contains(matched_file)) continue;
            deg.* += 1;
        }
    }

    // Seed the current wave with all files that have in-degree 0 (no dependencies — leaf libraries).
    // Process in waves: each wave contains files whose dependencies are all in previous waves.
    // Files within the same wave are independent and can be compiled in parallel.
    var current_wave: std.ArrayListUnmanaged([]const u8) = .empty;
    defer current_wave.deinit(alloc);
    var next_wave: std.ArrayListUnmanaged([]const u8) = .empty;
    defer next_wave.deinit(alloc);

    var deg_it = in_degree.iterator();
    while (deg_it.next()) |entry| {
        if (entry.value_ptr.* == 0) {
            current_wave.append(alloc, entry.key_ptr.*) catch return error.OutOfMemory;
        }
    }

    var sorted_count: u32 = 0;
    while (current_wave.items.len > 0) {
        // Process all files in the current wave
        for (current_wave.items) |file| {
            graph.topo_order.append(alloc, file) catch return error.OutOfMemory;
            sorted_count += 1;

            // Decrement in-degree of all files that depend on this file.
            // If a dependent's in-degree reaches 0, it belongs in the next wave.
            if (graph.file_imported_by.get(file)) |dependents| {
                for (dependents.items) |dependent_file| {
                    if (in_degree.getPtr(dependent_file)) |deg| {
                        if (deg.* > 0) {
                            deg.* -= 1;
                            if (deg.* == 0) {
                                next_wave.append(alloc, dependent_file) catch return error.OutOfMemory;
                            }
                        }
                    }
                }
            }
            if (graph.file_compile_after_by.get(file)) |dependents| {
                for (dependents.items) |dependent_file| {
                    if (in_degree.getPtr(dependent_file)) |deg| {
                        if (deg.* > 0) {
                            deg.* -= 1;
                            if (deg.* == 0) {
                                next_wave.append(alloc, dependent_file) catch return error.OutOfMemory;
                            }
                        }
                    }
                }
            }
        }

        // Record the boundary: all files up to sorted_count belong to this level
        graph.level_boundaries.append(alloc, sorted_count) catch return error.OutOfMemory;

        // Swap waves: next_wave becomes current, and we clear next_wave for reuse
        const tmp = current_wave;
        current_wave = next_wave;
        next_wave = tmp;
        next_wave.clearRetainingCapacity();
    }

    const total_files = in_degree.count();
    if (sorted_count != total_files) {
        return error.CircularDependency;
    }
}

/// Primitive type names that should not trigger struct file discovery.
/// These names are valid as type annotations (:: Bool, :: Nil) but do NOT
/// correspond to importable struct files. Real structs like Atom, String,
/// Bool etc. are discovered normally — the type annotation context check
/// in extractStructReferences prevents them from being treated as struct
/// references when used after `::`.
pub const BUILTIN_TYPE_NAMES = [_][]const u8{
    "Nil",
    "Expr",
    "Never",
};

// ============================================================
// Tests
// ============================================================

test "structNameToRelPath: simple struct" {
    const alloc = std.testing.allocator;
    const result = try structNameToRelPath(alloc, "Config");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("config.zap", result);
}

test "structNameToRelPath: nested struct" {
    const alloc = std.testing.allocator;
    const result = try structNameToRelPath(alloc, "Config.Parser");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("config/parser.zap", result);
}

test "structNameToRelPath: PascalCase to snake_case" {
    const alloc = std.testing.allocator;
    const result = try structNameToRelPath(alloc, "JsonParser");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("json_parser.zap", result);
}

test "structNameToRelPath: deeply nested" {
    const alloc = std.testing.allocator;
    const result = try structNameToRelPath(alloc, "App.Http.Middleware");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("app/http/middleware.zap", result);
}

fn exerciseStructNamesInSourceAllocationFailures(alloc: std.mem.Allocator) !void {
    const names = try structNamesInSource(
        alloc,
        "pub struct App {}\npub struct App.Router {}\n",
    );
    defer {
        for (names) |name| alloc.free(name);
        alloc.free(names);
    }

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("App", names[0]);
    try std.testing.expectEqualStrings("App.Router", names[1]);
}

test "P4J2: structNamesInSource frees owned name when names append fails" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseStructNamesInSourceAllocationFailures,
        .{},
    );
}

test "P4J2: primaryStructName frees outer slice and unused declared names" {
    const alloc = std.testing.allocator;
    const primary_struct = (try primaryStructName(
        alloc,
        "pub struct App {}\npub struct Helper {}\n",
    )) orelse return error.TestExpectedEqual;
    defer alloc.free(primary_struct);

    try std.testing.expectEqualStrings("App", primary_struct);
}

fn exerciseRecordSourceFileDeclaredStructOwnership(alloc: std.mem.Allocator, file_path: []const u8) !void {
    var graph = FileGraph.init(alloc);
    defer graph.deinit();

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);

    const native_type_structs = NativeTypeStructs.initFill(null);
    try recordSourceFile(
        alloc,
        &graph,
        .{ .borrowed = file_path },
        "project",
        "pub struct App {}\npub struct Helper {}\n",
        "App",
        &queue,
        &native_type_structs,
    );

    try std.testing.expectEqual(@as(usize, 2), graph.structsForFile(file_path).len);
    try std.testing.expectEqualStrings("App", graph.structForFile(file_path).?);
    try std.testing.expect(graph.struct_to_file.contains("Helper"));
}

test "P4J2: recordSourceFile transfers declared struct names to FileGraph" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    try temporary_directory.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "",
    });

    const alloc = std.testing.allocator;
    const file_path = try temporary_directory.dir.realPathFileAlloc(std.Options.debug_io, "app.zap", alloc);
    defer alloc.free(file_path);

    try std.testing.checkAllAllocationFailures(
        alloc,
        exerciseRecordSourceFileDeclaredStructOwnership,
        .{file_path},
    );
}

test "P4J2: FileGraph.deinit frees declared struct names exactly once" {
    const alloc = std.testing.allocator;
    var graph = FileGraph.init(alloc);
    errdefer graph.deinit();

    var declared_structs: std.ArrayListUnmanaged([]const u8) = .empty;
    var graph_owns_declared_structs = false;
    errdefer if (!graph_owns_declared_structs) freeOwnedStructNameList(alloc, &declared_structs);

    const app_struct = try alloc.dupe(u8, "App");
    var app_struct_transferred = false;
    errdefer if (!app_struct_transferred) alloc.free(app_struct);
    try declared_structs.append(alloc, app_struct);
    app_struct_transferred = true;

    const helper_struct = try alloc.dupe(u8, "Helper");
    var helper_struct_transferred = false;
    errdefer if (!helper_struct_transferred) alloc.free(helper_struct);
    try declared_structs.append(alloc, helper_struct);
    helper_struct_transferred = true;

    const graph_file_path = (try recordKnownSourcePath(alloc, &graph, .{ .borrowed = "app.zap" })).path;

    try graph.struct_to_file.put(app_struct, graph_file_path);
    try graph.struct_to_file.put(helper_struct, graph_file_path);
    try graph.struct_is_private.put(app_struct, false);
    try graph.struct_is_private.put(helper_struct, false);
    try graph.file_to_struct.put(graph_file_path, app_struct);
    try graph.file_to_structs.put(graph_file_path, declared_structs);
    graph_owns_declared_structs = true;

    graph.deinit();
}

fn exerciseExtractStructReferencesOwnedImportCleanup(alloc: std.mem.Allocator) !void {
    const source =
        \\pub struct App {
        \\  pub fn main() {
        \\    Helper.run()
        \\    Helper.stop()
        \\    Config.Parser.parse("data")
        \\    Config.Parser.render("data")
        \\  }
        \\}
    ;
    const refs = try extractStructReferences(alloc, source, "App");
    defer {
        freeOwnedImportSliceElements(alloc, refs);
        alloc.free(refs);
    }

    var helper_count: usize = 0;
    var found_config_parser = false;
    for (refs) |ref| {
        if (std.mem.eql(u8, ref, "Helper")) helper_count += 1;
        if (std.mem.eql(u8, ref, "Config.Parser")) found_config_parser = true;
    }
    try std.testing.expectEqual(@as(usize, 1), helper_count);
    try std.testing.expect(found_config_parser);
}

test "P4J2: extractStructReferences returns owned refs without leaking duplicates" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExtractStructReferencesOwnedImportCleanup,
        .{},
    );
}

fn exerciseRecordSourceFileImportOwnership(alloc: std.mem.Allocator, file_path: []const u8) !void {
    var graph = FileGraph.init(alloc);
    defer graph.deinit();

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);

    const native_type_structs = NativeTypeStructs.initFill(null);
    try recordSourceFile(
        alloc,
        &graph,
        .{ .borrowed = file_path },
        "project",
        "pub struct App {\n  pub fn main() {\n    Helper.run()\n    Helper.stop()\n    Util.value()\n  }\n}\n",
        "App",
        &queue,
        &native_type_structs,
    );

    const imports = graph.file_imports.get(file_path) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), imports.items.len);

    var found_helper = false;
    var found_util = false;
    for (imports.items) |import_name| {
        if (std.mem.eql(u8, import_name, "Helper")) found_helper = true;
        if (std.mem.eql(u8, import_name, "Util")) found_util = true;
    }
    try std.testing.expect(found_helper);
    try std.testing.expect(found_util);
}

test "P4J2: recordSourceFile transfers discovered import strings to FileGraph" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    try temporary_directory.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "",
    });

    const alloc = std.testing.allocator;
    const file_path = try temporary_directory.dir.realPathFileAlloc(std.Options.debug_io, "app.zap", alloc);
    defer alloc.free(file_path);

    try std.testing.checkAllAllocationFailures(
        alloc,
        exerciseRecordSourceFileImportOwnership,
        .{file_path},
    );
}

fn exerciseRecordSourceFileNativeImportOwnership(alloc: std.mem.Allocator, file_path: []const u8) !void {
    var graph = FileGraph.init(alloc);
    defer graph.deinit();

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);

    var native_type_structs = NativeTypeStructs.initFill(null);
    native_type_structs.getPtr(.list).* = "List";
    try recordSourceFile(
        alloc,
        &graph,
        .{ .borrowed = file_path },
        "project",
        "pub struct App {\n  pub fn main() {\n    []\n  }\n}\n",
        "App",
        &queue,
        &native_type_structs,
    );

    const imports = graph.file_imports.get(file_path) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), imports.items.len);
    try std.testing.expectEqualStrings("List", imports.items[0]);
}

test "P4J2: recordSourceFile transfers native literal import strings to FileGraph" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    try temporary_directory.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "",
    });

    const alloc = std.testing.allocator;
    const file_path = try temporary_directory.dir.realPathFileAlloc(std.Options.debug_io, "app.zap", alloc);
    defer alloc.free(file_path);

    try std.testing.checkAllAllocationFailures(
        alloc,
        exerciseRecordSourceFileNativeImportOwnership,
        .{file_path},
    );
}

fn exerciseRecordSourceFileImportReplacement(alloc: std.mem.Allocator, file_path: []const u8) !void {
    var graph = FileGraph.init(alloc);
    defer graph.deinit();

    var stale_imports: std.ArrayListUnmanaged([]const u8) = .empty;
    var graph_owns_stale_imports = false;
    errdefer if (!graph_owns_stale_imports) freeOwnedImportList(alloc, &stale_imports);

    const stale_import = try alloc.dupe(u8, "Stale");
    var stale_import_transferred = false;
    errdefer if (!stale_import_transferred) alloc.free(stale_import);
    try stale_imports.append(alloc, stale_import);
    stale_import_transferred = true;

    const graph_file_path = (try recordKnownSourcePath(alloc, &graph, .{ .borrowed = file_path })).path;
    try graph.file_imports.put(graph_file_path, stale_imports);
    graph_owns_stale_imports = true;

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);

    const native_type_structs = NativeTypeStructs.initFill(null);
    try recordSourceFile(
        alloc,
        &graph,
        .{ .borrowed = file_path },
        "project",
        "pub struct App {\n  pub fn main() {\n    Fresh.run()\n  }\n}\n",
        "App",
        &queue,
        &native_type_structs,
    );

    const imports = graph.file_imports.get(file_path) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), imports.items.len);
    try std.testing.expectEqualStrings("Fresh", imports.items[0]);
}

test "P4J2: recordSourceFile frees replaced import strings exactly once" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    try temporary_directory.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "",
    });

    const alloc = std.testing.allocator;
    const file_path = try temporary_directory.dir.realPathFileAlloc(std.Options.debug_io, "app.zap", alloc);
    defer alloc.free(file_path);

    try std.testing.checkAllAllocationFailures(
        alloc,
        exerciseRecordSourceFileImportReplacement,
        .{file_path},
    );
}

test "P4J2: resolveStructToFile propagates OutOfMemory while building relative path" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const roots = &[_]SourceRoot{.{ .name = "project", .path = "." }};

    try std.testing.expectError(
        error.OutOfMemory,
        resolveStructToFile(failing_allocator.allocator(), "App", roots),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: resolveStructToFile propagates OutOfMemory while joining source root path" {
    var fixed_buffer: [128]u8 = undefined;
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    const roots = &[_]SourceRoot{.{
        .name = "project",
        .path = "this/source/root/path/is/long/enough/to/exhaust/the/fixed/buffer/when/resolveStructToFile/joins/it/with/app.zap",
    }};

    try std.testing.expectError(
        error.OutOfMemory,
        resolveStructToFile(fixed_allocator.allocator(), "App", roots),
    );
}

test "P4J2: resolveStructToFile treats missing probes as semantic absence" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const alloc = std.testing.allocator;
    const root_path = try temporary_directory.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(root_path);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = root_path }};

    const resolved = try resolveStructToFile(alloc, "App", roots);
    try std.testing.expect(resolved == null);
}

test "P4J2: resolveStructToFile propagates access failures instead of absence" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    try temporary_directory.dir.symLink(std.Options.debug_io, "app.zap", "app.zap", .{});

    const alloc = std.testing.allocator;
    const root_path = try temporary_directory.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(root_path);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = root_path }};

    try std.testing.expectError(
        error.ReadError,
        resolveStructToFile(alloc, "App", roots),
    );
}

test "P4J2: discovery queue propagates resolver OutOfMemory instead of skipping import" {
    var fixed_buffer: [128]u8 = undefined;
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    const fixed_alloc = fixed_allocator.allocator();

    var graph = FileGraph.init(fixed_alloc);
    defer graph.deinit();

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(std.testing.allocator);
    try queue.append(std.testing.allocator, "App");

    const roots = &[_]SourceRoot{.{
        .name = "project",
        .path = "this/source/root/path/is/long/enough/to/exhaust/the/fixed/buffer/when/drainDiscoveryQueue/joins/it/with/app.zap",
    }};
    const native_type_structs = NativeTypeStructs.initFill(null);

    try std.testing.expectError(
        error.OutOfMemory,
        drainDiscoveryQueue(fixed_alloc, &graph, &queue, roots, &native_type_structs),
    );
}

fn exerciseDrainDiscoveryQueueSourcePathOwnership(alloc: std.mem.Allocator, root_path: []const u8) !void {
    var graph = FileGraph.init(alloc);
    defer graph.deinit();

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);
    try queue.append(alloc, "App");

    const roots = &[_]SourceRoot{.{ .name = "project", .path = root_path }};
    const native_type_structs = NativeTypeStructs.initFill(null);

    try drainDiscoveryQueue(alloc, &graph, &queue, roots, &native_type_structs);

    const graph_file_path = graph.struct_to_file.get("App") orelse return error.TestExpectedEqual;
    const known_file_path = graphOwnedSourcePath(&graph, graph_file_path) orelse return error.TestExpectedEqual;
    try std.testing.expect(known_file_path.ptr == graph_file_path.ptr);
    try std.testing.expect(graph.file_source_root.get(graph_file_path) != null);
}

test "P4J2: discovery queue transfers resolved source paths to FileGraph" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n}\n",
    });

    const alloc = std.testing.allocator;
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(root_path);

    try std.testing.checkAllAllocationFailures(
        alloc,
        exerciseDrainDiscoveryQueueSourcePathOwnership,
        .{root_path},
    );
}

fn exerciseRecordSourceFileBorrowedSourcePathOwnership(alloc: std.mem.Allocator, file_path: []const u8) !void {
    var graph = FileGraph.init(alloc);
    defer graph.deinit();

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);

    const native_type_structs = NativeTypeStructs.initFill(null);
    try recordSourceFile(
        alloc,
        &graph,
        .{ .borrowed = file_path },
        "project",
        "pub struct App {\n}\n",
        "App",
        &queue,
        &native_type_structs,
    );

    const known_file_path = graphOwnedSourcePath(&graph, file_path) orelse return error.TestExpectedEqual;
    const graph_file_path = graph.struct_to_file.get("App") orelse return error.TestExpectedEqual;
    try std.testing.expect(known_file_path.ptr == graph_file_path.ptr);
    try std.testing.expect(known_file_path.ptr != file_path.ptr);
}

test "P4J2: recordSourceFile stores borrowed source paths as graph-owned keys" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n}\n",
    });

    const alloc = std.testing.allocator;
    const file_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, "app.zap", alloc);
    defer alloc.free(file_path);

    try std.testing.checkAllAllocationFailures(
        alloc,
        exerciseRecordSourceFileBorrowedSourcePathOwnership,
        .{file_path},
    );
}

test "P4J2: recordSourceFile frees owned duplicate source path on canonical dedupe" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n}\n",
    });

    const alloc = std.testing.allocator;
    const file_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, "app.zap", alloc);
    defer alloc.free(file_path);

    var graph = FileGraph.init(alloc);
    defer graph.deinit();

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);

    const native_type_structs = NativeTypeStructs.initFill(null);
    try recordSourceFile(
        alloc,
        &graph,
        .{ .borrowed = file_path },
        "project",
        "pub struct App {\n}\n",
        "App",
        &queue,
        &native_type_structs,
    );

    const duplicate_file_path = try alloc.dupe(u8, file_path);
    try recordSourceFile(
        alloc,
        &graph,
        .{ .owned = duplicate_file_path },
        "project",
        "pub struct App {\n}\n",
        "App",
        &queue,
        &native_type_structs,
    );

    try std.testing.expectEqual(@as(u32, 1), graph.known_files.count());
}

fn exerciseCanonicalDedupeKey(alloc: std.mem.Allocator, file_path: []const u8) !void {
    var canonical_files = std.StringHashMap(void).init(alloc);
    defer {
        var it = canonical_files.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        canonical_files.deinit();
    }

    const recorded_key = try canonicalizeFilePath(alloc, file_path);
    var recorded_key_inserted = false;
    errdefer if (!recorded_key_inserted) alloc.free(recorded_key);
    try canonical_files.put(recorded_key, {});
    recorded_key_inserted = true;

    const check_key = try canonicalizeFilePath(alloc, file_path);
    defer alloc.free(check_key);

    try std.testing.expect(canonical_files.contains(check_key));
}

test "P4J2: canonical dedupe preserves OutOfMemory from canonical path allocation" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    1\n  }\n}\n",
    });

    const alloc = std.testing.allocator;
    const file_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, "app.zap", alloc);
    defer alloc.free(file_path);

    try std.testing.checkAllAllocationFailures(alloc, exerciseCanonicalDedupeKey, .{file_path});
}

test "P4J2: canonical dedupe propagates canonicalization failures" {
    try std.testing.expectError(
        error.ReadError,
        canonicalizeFilePath(std.testing.allocator, "missing/p4j2/canonical/input.zap"),
    );
}

test "P4J2: source-file reads preserve OutOfMemory" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n}\n",
    });

    const alloc = std.testing.allocator;
    const file_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, "app.zap", alloc);
    defer alloc.free(file_path);

    var failing_allocator = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        readDiscoveredSourceFile(failing_allocator.allocator(), file_path),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: source-file reads map non-OOM read failures to ReadError" {
    try std.testing.expectError(
        error.ReadError,
        readDiscoveredSourceFile(std.testing.allocator, "missing/p4j2/source/read.zap"),
    );
}

fn exerciseNativeTypeScan(alloc: std.mem.Allocator, root_path: []const u8) !void {
    var native_type_structs = NativeTypeStructs.initFill(null);
    errdefer freeNativeTypeStructs(alloc, &native_type_structs);

    try scanNativeTypesInDir(alloc, root_path, &native_type_structs);
    defer freeNativeTypeStructs(alloc, &native_type_structs);

    const list_struct = native_type_structs.get(.list) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("List", list_struct);
}

test "P4J2: native-type scan propagates OutOfMemory" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "list.zap",
        .data =
        \\@native_type = "list"
        \\pub struct List {
        \\}
        ,
    });

    const alloc = std.testing.allocator;
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(root_path);

    try std.testing.checkAllAllocationFailures(alloc, exerciseNativeTypeScan, .{root_path});
}

test "P4J2: native-type scan propagates directory read errors" {
    var native_type_structs = NativeTypeStructs.initFill(null);

    try std.testing.expectError(
        error.ReadError,
        scanNativeTypesInDir(
            std.testing.allocator,
            "does/not/exist/for/p4j2/native/type/scan",
            &native_type_structs,
        ),
    );
}

test "P4J2: discoverWithSourceFiles frees native-type scan results on success" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "list.zap",
        .data =
        \\@native_type = "list"
        \\pub struct List {
        \\}
        ,
    });

    const alloc = std.testing.allocator;
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(root_path);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = root_path }};

    var graph = try discoverWithSourceFiles(alloc, "MissingEntry", roots, &BUILTIN_TYPE_NAMES, &.{}, null);
    defer graph.deinit();
}

test "P4J2: discoverWithSourceFiles frees native-type scan results on later failure" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "list.zap",
        .data =
        \\@native_type = "list"
        \\pub struct List {
        \\}
        ,
    });

    const alloc = std.testing.allocator;
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(root_path);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = root_path }};

    try std.testing.expectError(
        error.ReadError,
        discoverWithSourceFiles(
            alloc,
            "MissingEntry",
            roots,
            &BUILTIN_TYPE_NAMES,
            &.{"missing/p4j2/native/type/later_failure.zap"},
            null,
        ),
    );
}

test "P4J2: source-root classification propagates OutOfMemory" {
    var fixed_buffer: [8]u8 = undefined;
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    const roots = &[_]SourceRoot{.{
        .name = "project",
        .path = "this/source/root/path/is/too/long/for/the/classification/slash/allocation",
    }};

    try std.testing.expectError(
        error.OutOfMemory,
        sourceRootNameForFile(
            fixed_allocator.allocator(),
            "this/source/root/path/is/too/long/for/the/classification/slash/allocation/app.zap",
            roots,
        ),
    );
}

fn exerciseCompileAfterGlobResolution(alloc: std.mem.Allocator) !void {
    var graph = FileGraph.init(alloc);
    defer graph.deinit();

    const declaring_file = "./test_runner.zap";
    const matched_file = "./src/discovery.zig";
    const graph_declaring_file = (try recordKnownSourcePath(alloc, &graph, .{ .borrowed = declaring_file })).path;
    const graph_matched_file = (try recordKnownSourcePath(alloc, &graph, .{ .borrowed = matched_file })).path;
    try graph.file_to_struct.put(graph_matched_file, "Discovery");

    var patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    var graph_owns_patterns = false;
    errdefer if (!graph_owns_patterns) patterns.deinit(alloc);

    const pattern = try alloc.dupe(u8, "src/discovery.zig");
    var graph_owns_pattern = false;
    errdefer if (!graph_owns_pattern) alloc.free(pattern);

    try patterns.append(alloc, pattern);
    try graph.file_compile_after_globs.put(graph_declaring_file, patterns);
    graph_owns_patterns = true;
    graph_owns_pattern = true;

    try resolveCompileAfterGlobs(alloc, &graph);
    try std.testing.expect(graph.file_compile_after_by.get(graph_matched_file) != null);
}

test "P4J2: compile-after glob resolution propagates OutOfMemory" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompileAfterGlobResolution,
        .{},
    );
}

test "P4J2: compile-after glob resolution propagates glob filesystem errors" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    try temporary_directory.dir.symLink(std.Options.debug_io, "loop.zap", "loop.zap", .{});

    const alloc = std.testing.allocator;
    const root_path = try temporary_directory.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(root_path);
    const loop_path = try std.fs.path.join(alloc, &.{ root_path, "loop.zap" });
    defer alloc.free(loop_path);

    var graph = FileGraph.init(alloc);
    defer graph.deinit();

    const declaring_file = "./test_runner.zap";
    const graph_declaring_file = (try recordKnownSourcePath(alloc, &graph, .{ .borrowed = declaring_file })).path;

    var patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    var graph_owns_patterns = false;
    errdefer if (!graph_owns_patterns) patterns.deinit(alloc);

    const pattern = try alloc.dupe(u8, loop_path);
    var graph_owns_pattern = false;
    errdefer if (!graph_owns_pattern) alloc.free(pattern);

    try patterns.append(alloc, pattern);
    try graph.file_compile_after_globs.put(graph_declaring_file, patterns);
    graph_owns_patterns = true;
    graph_owns_pattern = true;

    try std.testing.expectError(error.ReadError, resolveCompileAfterGlobs(alloc, &graph));
}

test "extractStructReferences: finds qualified calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\pub struct App {
        \\  pub fn main() -> String {
        \\    Config.load("/etc/app")
        \\    IO.puts("hello")
        \\  }
        \\}
    ;
    const refs = try extractStructReferences(alloc, source, "App");

    // Should find Config, IO, App (self), String
    var found_config = false;
    var found_io = false;
    for (refs) |ref| {
        if (std.mem.eql(u8, ref, "Config")) found_config = true;
        if (std.mem.eql(u8, ref, "IO")) found_io = true;
    }
    try std.testing.expect(found_config);
    try std.testing.expect(found_io);
}

test "extractStructReferences: finds nested struct references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\pub struct App {
        \\  pub fn main() -> String {
        \\    Config.Parser.parse("data")
        \\  }
        \\}
    ;
    const refs = try extractStructReferences(alloc, source, "App");

    var found = false;
    for (refs) |ref| {
        if (std.mem.eql(u8, ref, "Config.Parser")) found = true;
    }
    try std.testing.expect(found);
}

test "isPrivateStruct: detects bare struct" {
    try std.testing.expect(isPrivateStruct("struct Foo {\n}\n"));
    try std.testing.expect(!isPrivateStruct("pub struct Foo {\n}\n"));
}

test "discover: single file with no references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create temp directory with a single .zap file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    42\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discover(alloc, "App", roots, &BUILTIN_TYPE_NAMES, null);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 1), graph.topo_order.items.len);
    try std.testing.expect(graph.struct_to_file.contains("App"));
}

test "discover: transitive references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // App → Helper → Util (3 files, transitive chain)
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    Helper.run()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "helper.zap",
        .data = "pub struct Helper {\n  pub fn run() -> i64 {\n    Util.value()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "util.zap",
        .data = "pub struct Util {\n  pub fn value() -> i64 {\n    1\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discover(alloc, "App", roots, &BUILTIN_TYPE_NAMES, null);
    defer graph.deinit();

    // Should discover all 3 files
    try std.testing.expectEqual(@as(usize, 3), graph.topo_order.items.len);
    try std.testing.expect(graph.struct_to_file.contains("App"));
    try std.testing.expect(graph.struct_to_file.contains("Helper"));
    try std.testing.expect(graph.struct_to_file.contains("Util"));

    // Topo order: Util first (no deps), then Helper, then App
    const topo = graph.topo_order.items;
    const util_path = graph.struct_to_file.get("Util").?;
    try std.testing.expectEqualStrings(util_path, topo[0]);
}

test "discoverWithSourceFiles indexes globbed source file struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    1\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "extra_test.zap",
        .data = "pub struct Test.ExtraTest {\n  pub fn run() -> i64 {\n    Helper.value()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "helper.zap",
        .data = "pub struct Helper {\n  pub fn value() -> i64 {\n    2\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const extra_path = try std.fs.path.join(alloc, &.{ tmp_path, "extra_test.zap" });
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discoverWithSourceFiles(alloc, "App", roots, &BUILTIN_TYPE_NAMES, &.{extra_path}, null);
    defer graph.deinit();

    try std.testing.expect(graph.struct_to_file.contains("App"));
    try std.testing.expect(graph.struct_to_file.contains("Test.ExtraTest"));
    try std.testing.expect(graph.struct_to_file.contains("Helper"));
    try std.testing.expectEqualStrings("Test.ExtraTest", graph.structForFile(extra_path).?);
}

test "discoverWithSourceFiles tracks multiple structs in one source file without self-cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    1\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "multi_test.zap",
        .data = "pub struct Point {\n  x :: i64\n}\n\n" ++
            "pub struct Test.MultiTest {\n" ++
            "  pub fn run() -> Point {\n" ++
            "    %Point{x: 1}\n" ++
            "  }\n" ++
            "}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const multi_path = try std.fs.path.join(alloc, &.{ tmp_path, "multi_test.zap" });
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discoverWithSourceFiles(alloc, "App", roots, &BUILTIN_TYPE_NAMES, &.{multi_path}, null);
    defer graph.deinit();

    try std.testing.expect(graph.struct_to_file.contains("Point"));
    try std.testing.expect(graph.struct_to_file.contains("Test.MultiTest"));
    try std.testing.expectEqual(@as(usize, 2), graph.structsForFile(multi_path).len);
    try std.testing.expectEqual(@as(usize, 2), graph.topo_order.items.len);
}

test "discoverWithSourceFiles dedupes a file passed both via entry-point resolution and explicit_source_files with different surface paths" {
    // Regression for the duplicate-name IR-function bug surfaced by
    // fannkuch-redux's chain-consistency audit. The compiler was
    // recording the same source file twice in the FileGraph when the
    // entry-point struct→file resolver produced a path with one
    // representation (e.g. `<root>/app.zap`) and the explicit source
    // file glob produced another representation of the same file
    // (e.g. with a `././` prefix). Both keys hashed independently, so
    // `file_to_structs` ended up with two entries for the same file
    // and `topo_order` listed the same struct twice — which then
    // caused `compileStructByStruct` to run HIR/IR for the struct
    // twice, producing two `ir.Function` records with the same name
    // but different `FunctionId`s.
    //
    // The fix canonicalizes file paths to their realpath form for
    // duplicate detection, so any two surface paths that resolve to
    // the same on-disk file collapse to one record.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    1\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const canonical_app_path = try std.fs.path.join(alloc, &.{ tmp_path, "app.zap" });
    // Same file, two different surface representations: one direct,
    // one with an extra `./` segment that `std.fs.path.join` does not
    // collapse on its own. Without the realpath-keyed dedup, the
    // FileGraph would record both as distinct keys.
    const aliased_app_path = try std.fs.path.join(alloc, &.{ tmp_path, ".", "app.zap" });
    try std.testing.expect(!std.mem.eql(u8, canonical_app_path, aliased_app_path));

    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discoverWithSourceFiles(
        alloc,
        "App",
        roots,
        &BUILTIN_TYPE_NAMES,
        &.{aliased_app_path},
        null,
    );
    defer graph.deinit();

    // App should appear in struct_to_file under exactly one path key,
    // and that key should resolve to the same realpath as both
    // surface paths.
    try std.testing.expect(graph.struct_to_file.contains("App"));

    // topo_order has exactly one entry — without the fix, the
    // duplicate would surface here as an extra entry pointing at the
    // aliased path key.
    try std.testing.expectEqual(@as(usize, 1), graph.topo_order.items.len);

    // Either of the two surface paths used during discovery should
    // map back to the App struct via structsForFile/structForFile,
    // because at most one canonicalized record exists for the file.
    var matched_records: usize = 0;
    if (graph.structsForFile(canonical_app_path).len > 0) matched_records += 1;
    if (graph.structsForFile(aliased_app_path).len > 0) matched_records += 1;
    try std.testing.expect(matched_records >= 1);
    try std.testing.expectEqual(@as(usize, 1), matched_records);
}

test "discoverWithSourceFiles keeps structless source files in graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    1\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "integer_display.zap",
        .data = "impl Display for Integer {\n  pub fn show(_value :: Integer) -> String {\n    \"1\"\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const impl_path = try std.fs.path.join(alloc, &.{ tmp_path, "integer_display.zap" });
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discoverWithSourceFiles(alloc, "App", roots, &BUILTIN_TYPE_NAMES, &.{impl_path}, null);
    defer graph.deinit();

    try std.testing.expect(graph.known_files.contains(impl_path));
    try std.testing.expect(graph.structForFile(impl_path) == null);
    try std.testing.expectEqual(@as(usize, 2), graph.topo_order.items.len);
}

test "compile_after_glob is order-only and not an import dependent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const runner_path = try std.fs.path.join(alloc, &.{ tmp_path, "test_runner.zap" });
    const provider_path = try std.fs.path.join(alloc, &.{ tmp_path, "provider_test.zap" });

    const runner_source = try std.fmt.allocPrint(
        alloc,
        "@compile_after_glob = \"{s}\"\n\n" ++
            "pub struct TestRunner {{\n" ++
            "  pub fn main() -> i64 {{\n" ++
            "    0\n" ++
            "  }}\n" ++
            "}}\n",
        .{provider_path},
    );
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "test_runner.zap",
        .data = runner_source,
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "provider_test.zap",
        .data = "pub struct ProviderTest {\n  pub fn value() -> i64 {\n    1\n  }\n}\n",
    });

    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discoverWithSourceFiles(alloc, "TestRunner", roots, &BUILTIN_TYPE_NAMES, &.{provider_path}, null);
    defer graph.deinit();

    try std.testing.expect(graph.file_imported_by.get(provider_path) == null);
    try std.testing.expect(graph.file_compile_after_by.get(provider_path) != null);
    const provider_index = indexOfPath(graph.topo_order.items, provider_path).?;
    const runner_index = indexOfPath(graph.topo_order.items, runner_path).?;
    try std.testing.expect(provider_index < runner_index);
}

test "discover: circular dependency detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // A → B → A (cycle)
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "cycle_a.zap",
        .data = "pub struct CycleA {\n  pub fn go() -> i64 {\n    CycleB.go()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "cycle_b.zap",
        .data = "pub struct CycleB {\n  pub fn go() -> i64 {\n    CycleA.go()\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    const result = discover(alloc, "CycleA", roots, &BUILTIN_TYPE_NAMES, null);
    try std.testing.expectError(error.CircularDependency, result);
}

test "discover: unresolvable references are silently skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // App references NonExistent which doesn't exist — should be skipped
    // (might be a union variant, struct name, or other non-struct identifier)
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    NonExistent.foo()\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    // Discovery succeeds — unresolvable references don't cause errors.
    // The compiler will catch genuinely missing structs during compilation.
    var graph = try discover(alloc, "App", roots, &BUILTIN_TYPE_NAMES, null);
    defer graph.deinit();

    // App was discovered
    try std.testing.expect(graph.struct_to_file.contains("App"));
    // NonExistent was NOT discovered (silently skipped)
    try std.testing.expect(!graph.struct_to_file.contains("NonExistent"));
}

test "discover: struct found in dep root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Project references DepMod which is in a separate dep root
    tmp_dir.dir.createDirPath(std.Options.debug_io, "project") catch {};
    tmp_dir.dir.createDirPath(std.Options.debug_io, "dep_lib") catch {};

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "project/app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    DepMod.value()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "dep_lib/dep_mod.zap",
        .data = "pub struct DepMod {\n  pub fn value() -> i64 {\n    99\n  }\n}\n",
    });

    const project_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, "project", alloc);
    const dep_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, "dep_lib", alloc);
    const roots = &[_]SourceRoot{
        .{ .name = "project", .path = project_path },
        .{ .name = "dep:mylib", .path = dep_path },
    };

    var graph = try discover(alloc, "App", roots, &BUILTIN_TYPE_NAMES, null);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 2), graph.topo_order.items.len);
    try std.testing.expect(graph.struct_to_file.contains("App"));
    try std.testing.expect(graph.struct_to_file.contains("DepMod"));

    // DepMod should be in the dep source root
    const dep_mod_file = graph.struct_to_file.get("DepMod").?;
    const dep_root = graph.file_source_root.get(dep_mod_file).?;
    try std.testing.expectEqualStrings("dep:mylib", dep_root);
}

test "discover: level_boundaries for single file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    42\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discover(alloc, "App", roots, &BUILTIN_TYPE_NAMES, null);
    defer graph.deinit();

    // Single file → one level with boundary at 1
    try std.testing.expectEqual(@as(usize, 1), graph.level_boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 1), graph.level_boundaries.items[0]);
}

test "discover: level_boundaries for linear chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // App → Helper → Util (linear chain = 3 levels)
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    Helper.run()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "helper.zap",
        .data = "pub struct Helper {\n  pub fn run() -> i64 {\n    Util.value()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "util.zap",
        .data = "pub struct Util {\n  pub fn value() -> i64 {\n    1\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discover(alloc, "App", roots, &BUILTIN_TYPE_NAMES, null);
    defer graph.deinit();

    // Linear chain: 3 levels (Util), (Helper), (App) → boundaries [1, 2, 3]
    try std.testing.expectEqual(@as(usize, 3), graph.level_boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 1), graph.level_boundaries.items[0]);
    try std.testing.expectEqual(@as(u32, 2), graph.level_boundaries.items[1]);
    try std.testing.expectEqual(@as(u32, 3), graph.level_boundaries.items[2]);
}

test "discover: level_boundaries for diamond dependency" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Diamond: App → {Left, Right} → Base
    // Level 0: Base (no deps)
    // Level 1: Left, Right (both depend only on Base)
    // Level 2: App (depends on Left and Right)
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    Left.go() + Right.go()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "left.zap",
        .data = "pub struct Left {\n  pub fn go() -> i64 {\n    Base.value()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "right.zap",
        .data = "pub struct Right {\n  pub fn go() -> i64 {\n    Base.value()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "base.zap",
        .data = "pub struct Base {\n  pub fn value() -> i64 {\n    1\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discover(alloc, "App", roots, &BUILTIN_TYPE_NAMES, null);
    defer graph.deinit();

    // Diamond: 3 levels → boundaries [1, 3, 4]
    // Level 0: [Base] → boundary at 1
    // Level 1: [Left, Right] → boundary at 3
    // Level 2: [App] → boundary at 4
    try std.testing.expectEqual(@as(usize, 3), graph.level_boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 1), graph.level_boundaries.items[0]);
    try std.testing.expectEqual(@as(u32, 3), graph.level_boundaries.items[1]);
    try std.testing.expectEqual(@as(u32, 4), graph.level_boundaries.items[2]);

    // Level 1 should contain both Left and Right (in some order)
    const level1_start: usize = graph.level_boundaries.items[0];
    const level1_end: usize = graph.level_boundaries.items[1];
    try std.testing.expectEqual(@as(usize, 2), level1_end - level1_start);
}
