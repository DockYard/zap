//! Import-Driven File Discovery
//!
//! Discovers which source files to compile by starting from the entry point
//! module and following module references transitively. Builds a dependency
//! DAG and enforces no circular dependencies.
//!
//! Module names map to file paths by convention:
//!   Config.Parser → lib/config/parser.zap
//!   App → lib/app.zap (or app.zap in project root)

const std = @import("std");
const zap = @import("root.zig");
const ast = zap.ast;

/// A root directory where modules can be found (project lib or dep lib).
pub const SourceRoot = struct {
    /// Display name for error messages (e.g., "project", "dep:json_parser")
    name: []const u8,
    /// Absolute path to the lib directory
    path: []const u8,
};

/// The result of file discovery: a module dependency DAG.
pub const FileGraph = struct {
    allocator: std.mem.Allocator,

    /// Module name → file path (absolute)
    module_to_file: std.StringHashMap([]const u8),

    /// File path → primary struct name declared by that file.
    file_to_struct: std.StringHashMap([]const u8),

    /// File path → all struct names declared by that file.
    file_to_structs: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// Every source file known to the graph, including files without a
    /// top-level struct such as protocol/impl-only files.
    known_files: std.StringHashMap(void),

    /// File path → list of module names it references
    file_imports: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// File path → list of files that import it
    file_imported_by: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// Files in topological order (dependencies before dependents)
    topo_order: std.ArrayListUnmanaged([]const u8),

    /// Indices into topo_order marking where each dependency level ends.
    /// Modules within the same level have no dependencies on each other
    /// and can be compiled in parallel.
    level_boundaries: std.ArrayListUnmanaged(u32) = .empty,

    /// Stdlib module names (not discovered from files)
    stdlib_modules: std.StringHashMap(void),

    /// File path → source root name (e.g., "project", "dep:math_lib")
    /// Used to determine dep boundaries for defmodulep enforcement.
    file_source_root: std.StringHashMap([]const u8),

    /// Module name → true if declared with defmodulep (private to dep)
    module_is_private: std.StringHashMap(bool),

    pub fn init(allocator: std.mem.Allocator) FileGraph {
        return .{
            .allocator = allocator,
            .module_to_file = std.StringHashMap([]const u8).init(allocator),
            .file_to_struct = std.StringHashMap([]const u8).init(allocator),
            .file_to_structs = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .known_files = std.StringHashMap(void).init(allocator),
            .file_imports = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .file_imported_by = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .topo_order = .empty,
            .level_boundaries = .empty,
            .stdlib_modules = std.StringHashMap(void).init(allocator),
            .file_source_root = std.StringHashMap([]const u8).init(allocator),
            .module_is_private = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn deinit(self: *FileGraph) void {
        self.module_to_file.deinit();
        self.file_to_struct.deinit();
        {
            var it = self.file_to_structs.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        }
        self.file_to_structs.deinit();
        self.known_files.deinit();
        {
            var it = self.file_imports.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        }
        self.file_imports.deinit();
        {
            var it = self.file_imported_by.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        }
        self.file_imported_by.deinit();
        self.topo_order.deinit(self.allocator);
        self.level_boundaries.deinit(self.allocator);
        self.stdlib_modules.deinit();
        self.file_source_root.deinit();
        self.module_is_private.deinit();
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
    ModuleNotFound,
    CircularDependency,
    OutOfMemory,
    ReadError,
    ParseFailed,
};

/// Error details populated on failure. Caller provides this to discover()
/// to get human-readable error information without stderr writes.
pub const ErrorInfo = struct {
    unresolved_module: ?[]const u8 = null,
    boundary_module: ?[]const u8 = null,
    boundary_dep: ?[]const u8 = null,
    boundary_from: ?[]const u8 = null,
};

/// Discover all files reachable from the entry module.
///
/// `entry_module` is e.g. "App" (extracted from build.zap root "App.main/0").
/// `source_roots` are directories to search for module files, in priority order.
/// The first root is typically the project's own lib dir.
/// Name of the stdlib module that's auto-imported into every Zap
/// module (Elixir-style). The collector injects an
/// `import <kernel_module_name>` into every module's scope so the
/// macros and helpers defined in `lib/kernel.zap` (`if`, `unless`,
/// `|>`, `<>`, sigils, …) are reachable as bare calls without an
/// explicit import.
///
/// This is the single source of truth for the name. Every site that
/// needed to ask "is this the Kernel module?" or "what name should I
/// inject as the auto-import?" reads it from here.
pub const kernel_module_name = "Kernel";

/// Modules that discovery must always load even when no source file
/// references them. `kernel_module_name` is here because the collector
/// injects auto-imports against it; `Range` is here because the `..`
/// range-literal syntax desugars to `%Range{...}` — the user's source
/// doesn't mention `Range` literally, so the file-discovery pass would
/// otherwise skip it.
pub const AUTO_IMPORTS = [_][]const u8{
    kernel_module_name,
    "Range",
};

pub fn discover(
    alloc: std.mem.Allocator,
    entry_module: []const u8,
    source_roots: []const SourceRoot,
    stdlib_module_names: []const []const u8,
    err_info: ?*ErrorInfo,
) DiscoveryError!FileGraph {
    return discoverWithSourceFiles(alloc, entry_module, source_roots, stdlib_module_names, &.{}, err_info);
}

pub fn discoverWithSourceFiles(
    alloc: std.mem.Allocator,
    entry_module: []const u8,
    source_roots: []const SourceRoot,
    stdlib_module_names: []const []const u8,
    explicit_source_files: []const []const u8,
    err_info: ?*ErrorInfo,
) DiscoveryError!FileGraph {
    var graph = FileGraph.init(alloc);
    errdefer graph.deinit();

    // Register stdlib modules so we don't try to discover them as files
    for (stdlib_module_names) |name| {
        graph.stdlib_modules.put(name, {}) catch return error.OutOfMemory;
    }

    // Discovery work queue
    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);

    // Seed with entry module
    queue.append(alloc, entry_module) catch return error.OutOfMemory;

    // Seed auto-imported modules. These are always compiled because their
    // exports are implicitly available in every module (like Elixir's Kernel).
    for (&AUTO_IMPORTS) |auto_mod| {
        queue.append(alloc, auto_mod) catch return error.OutOfMemory;
    }

    try drainDiscoveryQueue(alloc, &graph, &queue, source_roots);

    for (explicit_source_files) |file_path| {
        if (graph.known_files.contains(file_path)) continue;

        const source_root_name = sourceRootNameForFile(alloc, file_path, source_roots) orelse "project";
        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, alloc, .limited(10 * 1024 * 1024)) catch
            return error.ReadError;
        const primary_struct = primaryStructName(alloc, source) catch return error.OutOfMemory;
        try recordSourceFile(alloc, &graph, file_path, source_root_name, source, primary_struct, &queue);
        try drainDiscoveryQueue(alloc, &graph, &queue, source_roots);
    }

    // Build imported_by (reverse index)
    {
        var it = graph.file_imports.iterator();
        while (it.next()) |entry| {
            const importer_file = entry.key_ptr.*;
            for (entry.value_ptr.items) |imported_module| {
                if (graph.module_to_file.get(imported_module)) |imported_file| {
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

    // Enforce defmodulep dep boundaries: a private module from dep A
    // cannot be referenced by code in dep B or the project.
    try enforceDepBoundaries(alloc, &graph, err_info);

    return graph;
}

fn drainDiscoveryQueue(
    alloc: std.mem.Allocator,
    graph: *FileGraph,
    queue: *std.ArrayListUnmanaged([]const u8),
    source_roots: []const SourceRoot,
) DiscoveryError!void {
    while (queue.items.len > 0) {
        const struct_name = queue.orderedRemove(0);

        if (graph.module_to_file.contains(struct_name)) continue;
        if (graph.stdlib_modules.contains(struct_name)) continue;

        const resolved = resolveModuleToFile(alloc, struct_name, source_roots) orelse continue;
        const file_path = resolved.path;
        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, alloc, .limited(10 * 1024 * 1024)) catch
            return error.ReadError;

        try recordSourceFile(alloc, graph, file_path, resolved.source_root_name, source, struct_name, queue);
    }
}

fn recordSourceFile(
    alloc: std.mem.Allocator,
    graph: *FileGraph,
    file_path: []const u8,
    source_root_name: []const u8,
    source: []const u8,
    primary_struct: ?[]const u8,
    queue: *std.ArrayListUnmanaged([]const u8),
) DiscoveryError!void {
    graph.known_files.put(file_path, {}) catch return error.OutOfMemory;
    graph.file_source_root.put(file_path, source_root_name) catch return error.OutOfMemory;

    const declared_structs = structNamesInSource(alloc, source) catch return error.OutOfMemory;
    if (declared_structs.len > 0) {
        var structs_for_file: std.ArrayListUnmanaged([]const u8) = .empty;
        for (declared_structs) |struct_name| {
            graph.module_to_file.put(struct_name, file_path) catch return error.OutOfMemory;
            graph.module_is_private.put(struct_name, false) catch return error.OutOfMemory;
            structs_for_file.append(alloc, struct_name) catch return error.OutOfMemory;
        }
        graph.file_to_structs.put(file_path, structs_for_file) catch return error.OutOfMemory;
    }

    if (primary_struct) |struct_name| {
        graph.module_to_file.put(struct_name, file_path) catch return error.OutOfMemory;
        graph.file_to_struct.put(file_path, struct_name) catch return error.OutOfMemory;
        graph.module_is_private.put(struct_name, isPrivateStruct(source)) catch return error.OutOfMemory;
    } else if (declared_structs.len > 0) {
        graph.file_to_struct.put(file_path, declared_structs[0]) catch return error.OutOfMemory;
    }

    const refs = extractModuleReferences(alloc, source, primary_struct orelse "") catch
        return error.OutOfMemory;

    var imports_list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (refs) |ref| {
        if (primary_struct) |struct_name| {
            if (std.mem.eql(u8, ref, struct_name)) continue;
        }
        if (structNameDeclaredInFile(declared_structs, ref)) continue;
        if (graph.stdlib_modules.contains(ref)) continue;

        imports_list.append(alloc, ref) catch return error.OutOfMemory;

        if (!graph.module_to_file.contains(ref)) {
            queue.append(alloc, ref) catch return error.OutOfMemory;
        }
    }
    graph.file_imports.put(file_path, imports_list) catch return error.OutOfMemory;
}

/// Enforce that defmodulep modules are not referenced across dep boundaries.
/// A module declared with defmodulep in dep "dep:foo" is only visible to
/// other modules in "dep:foo". Project code and other deps cannot access it.
fn enforceDepBoundaries(alloc: std.mem.Allocator, graph: *FileGraph, err_info: ?*ErrorInfo) DiscoveryError!void {
    _ = alloc;
    var had_error = false;

    var import_it = graph.file_imports.iterator();
    while (import_it.next()) |entry| {
        const importer_file = entry.key_ptr.*;
        const importer_root = graph.file_source_root.get(importer_file) orelse continue;

        for (entry.value_ptr.items) |imported_module| {
            // Check if the imported module is private
            const is_private = graph.module_is_private.get(imported_module) orelse false;
            if (!is_private) continue;

            // Get the source root of the imported module's file
            const imported_file = graph.module_to_file.get(imported_module) orelse continue;
            const imported_root = graph.file_source_root.get(imported_file) orelse continue;

            // If they're in different source roots, it's a boundary violation
            if (!std.mem.eql(u8, importer_root, imported_root)) {
                if (err_info) |info| {
                    info.boundary_module = imported_module;
                    info.boundary_dep = imported_root;
                    info.boundary_from = importer_root;
                }
                had_error = true;
            }
        }
    }

    if (had_error) return error.ModuleNotFound;
}

/// Convert a module name to a relative file path.
/// "Config.Parser" → "config/parser.zap"
/// Caller owns the returned slice and must free it with the same allocator.
pub fn structNameToRelPath(alloc: std.mem.Allocator, module_name: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;

    var it = std.mem.splitScalar(u8, module_name, '.');
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

/// Try to resolve a module name to an absolute file path by checking source roots.
/// Returns the file path and the name of the source root it was found in.
fn resolveModuleToFile(
    alloc: std.mem.Allocator,
    module_name: []const u8,
    source_roots: []const SourceRoot,
) ?ResolvedFile {
    const rel_path = structNameToRelPath(alloc, module_name) catch return null;

    // Try the full relative path first
    for (source_roots) |root| {
        const full_path = std.fs.path.join(alloc, &.{ root.path, rel_path }) catch continue;
        std.Io.Dir.cwd().access(std.Options.debug_io, full_path, .{}) catch continue;
        return .{ .path = full_path, .source_root_name = root.name };
    }

    // If the module name has a prefix (e.g., "Test.StringTest"), try stripping
    // the first segment and resolving within each source root. This handles the
    // convention where `test/` is a source root and modules are named
    // `Test.StructName` — the `Test.` prefix maps to the source root, not to
    // a subdirectory within it.
    if (std.mem.indexOfScalar(u8, module_name, '.')) |dot_pos| {
        const suffix = module_name[dot_pos + 1 ..];
        const suffix_path = structNameToRelPath(alloc, suffix) catch return null;
        for (source_roots) |root| {
            const full_path = std.fs.path.join(alloc, &.{ root.path, suffix_path }) catch continue;
            std.Io.Dir.cwd().access(std.Options.debug_io, full_path, .{}) catch continue;
            return .{ .path = full_path, .source_root_name = root.name };
        }
    }

    return null;
}

fn sourceRootNameForFile(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    source_roots: []const SourceRoot,
) ?[]const u8 {
    const normalized_file = if (std.mem.startsWith(u8, file_path, "./")) file_path[2..] else file_path;
    for (source_roots) |root| {
        const normalized_root = if (std.mem.startsWith(u8, root.path, "./")) root.path[2..] else root.path;
        if (std.mem.eql(u8, normalized_file, normalized_root)) return root.name;
        const root_slash = std.fmt.allocPrint(alloc, "{s}/", .{normalized_root}) catch continue;
        if (std.mem.startsWith(u8, normalized_file, root_slash)) return root.name;
    }
    return null;
}

fn primaryStructName(alloc: std.mem.Allocator, source: []const u8) error{OutOfMemory}!?[]const u8 {
    const declared_structs = try structNamesInSource(alloc, source);
    if (declared_structs.len == 0) return null;
    return declared_structs[0];
}

fn structNamesInSource(alloc: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var lexer = zap.Lexer.init(source);
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;
        if (tok.tag != .keyword_struct) continue;

        const name_tok = lexer.next();
        if (name_tok.tag != .module_identifier) continue;

        var name_buf: std.ArrayListUnmanaged(u8) = .empty;
        try name_buf.appendSlice(alloc, name_tok.slice(source));

        var peek = lexer;
        while (true) {
            const dot_tok = peek.next();
            if (dot_tok.tag != .dot) break;
            const next_tok = peek.next();
            if (next_tok.tag != .module_identifier) break;
            try name_buf.append(alloc, '.');
            try name_buf.appendSlice(alloc, next_tok.slice(source));
            lexer = peek;
        }

        try names.append(alloc, try name_buf.toOwnedSlice(alloc));
    }

    return try names.toOwnedSlice(alloc);
}

fn structNameDeclaredInFile(declared_structs: []const []const u8, ref: []const u8) bool {
    for (declared_structs) |struct_name| {
        if (std.mem.eql(u8, struct_name, ref)) return true;
    }
    return false;
}

/// Check if a source file declares its module without `pub` (private).
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

/// Extract module references from a source file using the lexer.
///
/// Scans for `module_identifier` tokens (capitalized identifiers) that appear
/// in positions indicating a module reference:
/// - Before a `.` followed by an identifier or another module_identifier
///   (qualified call or field access)
/// - After `%` (struct literal)
/// - After `::` in certain positions (type annotations)
///
/// Returns a deduplicated list of module names (e.g., ["Config", "IO", "Config.Parser"]).
fn extractModuleReferences(
    alloc: std.mem.Allocator,
    source: []const u8,
    _: []const u8, // self_module (unused for now)
) ![]const []const u8 {
    var refs = std.StringHashMap(void).init(alloc);
    defer refs.deinit();

    var lexer = zap.Lexer.init(source);

    // Track context to distinguish module references from union variants,
    // struct names, and other non-module uppercase identifiers.
    // We skip uppercase identifiers that appear inside union/struct/enum bodies
    // as bare names (without a dot-call or being after `use`/`import`).
    var inside_union_body = false;
    var inside_struct_body = false;
    var brace_depth: u32 = 0;
    var union_brace_depth: u32 = 0;
    var struct_brace_depth: u32 = 0;
    var prev_tag: zap.Token.Tag = .eof;

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
            if (name_tok.tag == .module_identifier) {
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
            if (name_tok.tag == .module_identifier) {
                const brace_tok = peek.next();
                if (brace_tok.tag == .left_brace) {
                    inside_struct_body = true;
                    struct_brace_depth = brace_depth + 1;
                }
            }
        }

        if (tok.tag == .module_identifier) {
            const name_text = tok.slice(source);

            // Skip: bare uppercase identifiers inside union bodies are variants, not modules.
            // e.g., `pub union Color { Red, Green, Blue }` — Red/Green/Blue are variants.
            if (inside_union_body) {
                // Check if this is a bare variant name (not followed by `.function()`)
                var peek = lexer;
                const next = peek.next();
                if (next.tag != .dot) {
                    // Bare name inside union body — skip as variant declaration
                    continue;
                }
                // If followed by dot, it's a qualified reference like Module.function — proceed
            }

            // Skip: identifiers after `::` or `->` are type annotations, not module calls.
            // `:: String` is a parameter type, `-> Bool` is a return type.
            // Exception: if followed by `.` it's a module-qualified type like `Zap.Env`.
            if (prev_tag == .double_colon or prev_tag == .arrow) {
                var peek = lexer;
                const next = peek.next();
                if (next.tag != .dot) {
                    continue;
                }
            }

            // Collect the full dotted module name: Foo.Bar.Baz
            var name_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer name_buf.deinit(alloc);
            try name_buf.appendSlice(alloc, name_text);

            // Look ahead for .ModuleIdentifier chains
            var peek_lexer = lexer;
            while (true) {
                const dot_tok = peek_lexer.next();
                if (dot_tok.tag != .dot) break;

                const next_tok = peek_lexer.next();
                if (next_tok.tag == .module_identifier) {
                    try name_buf.append(alloc, '.');
                    try name_buf.appendSlice(alloc, next_tok.slice(source));
                    lexer = peek_lexer;
                } else {
                    // Dot followed by a lowercase identifier = function call on the module
                    // The module part is what we've collected so far
                    break;
                }
            }

            const module_name = try alloc.dupe(u8, name_buf.items);
            try refs.put(module_name, {});
        }

        prev_tag = tok.tag;
    }

    // Convert to array
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = refs.iterator();
    while (it.next()) |entry| {
        try result.append(alloc, entry.key_ptr.*);
    }
    return try result.toOwnedSlice(alloc);
}

/// Topological sort of the file graph using Kahn's algorithm.
/// Produces dependencies-first ordering. Detects circular dependencies.
fn topologicalSort(alloc: std.mem.Allocator, graph: *FileGraph) DiscoveryError!void {
    // in_degree[file] = number of dependencies this file has (how many modules it imports
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
        for (entry.value_ptr.items) |imported_module| {
            if (graph.module_to_file.get(imported_module)) |imported_file| {
                if (std.mem.eql(u8, imported_file, importing_file)) continue;
                dep_count += 1;
            }
        }
        if (in_degree.getPtr(importing_file)) |deg| {
            deg.* = dep_count;
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

/// Primitive type names that should not trigger module file discovery.
/// These names are valid as type annotations (:: Bool, :: Nil) but do NOT
/// correspond to importable module files. Real modules like Atom, String,
/// Bool etc. are discovered normally — the type annotation context check
/// in extractModuleReferences prevents them from being treated as module
/// references when used after `::`.
pub const BUILTIN_TYPE_NAMES = [_][]const u8{
    "Nil",
    "Expr",
    "Never",
};

// ============================================================
// Tests
// ============================================================

test "structNameToRelPath: simple module" {
    const alloc = std.testing.allocator;
    const result = try structNameToRelPath(alloc, "Config");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("config.zap", result);
}

test "structNameToRelPath: nested module" {
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

test "extractModuleReferences: finds qualified calls" {
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
    const refs = try extractModuleReferences(alloc, source, "App");

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

test "extractModuleReferences: finds nested module references" {
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
    const refs = try extractModuleReferences(alloc, source, "App");

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
    try std.testing.expect(graph.module_to_file.contains("App"));
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
    try std.testing.expect(graph.module_to_file.contains("App"));
    try std.testing.expect(graph.module_to_file.contains("Helper"));
    try std.testing.expect(graph.module_to_file.contains("Util"));

    // Topo order: Util first (no deps), then Helper, then App
    const topo = graph.topo_order.items;
    const util_path = graph.module_to_file.get("Util").?;
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

    try std.testing.expect(graph.module_to_file.contains("App"));
    try std.testing.expect(graph.module_to_file.contains("Test.ExtraTest"));
    try std.testing.expect(graph.module_to_file.contains("Helper"));
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

    try std.testing.expect(graph.module_to_file.contains("Point"));
    try std.testing.expect(graph.module_to_file.contains("Test.MultiTest"));
    try std.testing.expectEqual(@as(usize, 2), graph.structsForFile(multi_path).len);
    try std.testing.expectEqual(@as(usize, 2), graph.topo_order.items.len);
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
    // (might be a union variant, struct name, or other non-module identifier)
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {\n  pub fn main() -> i64 {\n    NonExistent.foo()\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    // Discovery succeeds — unresolvable references don't cause errors.
    // The compiler will catch genuinely missing modules during compilation.
    var graph = try discover(alloc, "App", roots, &BUILTIN_TYPE_NAMES, null);
    defer graph.deinit();

    // App was discovered
    try std.testing.expect(graph.module_to_file.contains("App"));
    // NonExistent was NOT discovered (silently skipped)
    try std.testing.expect(!graph.module_to_file.contains("NonExistent"));
}

test "discover: module found in dep root" {
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
    try std.testing.expect(graph.module_to_file.contains("App"));
    try std.testing.expect(graph.module_to_file.contains("DepMod"));

    // DepMod should be in the dep source root
    const dep_mod_file = graph.module_to_file.get("DepMod").?;
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
