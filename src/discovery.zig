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

    /// File path → list of module names it references
    file_imports: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// File path → list of files that import it
    file_imported_by: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// Files in topological order (dependencies before dependents)
    topo_order: std.ArrayListUnmanaged([]const u8),

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
            .file_imports = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .file_imported_by = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .topo_order = .empty,
            .stdlib_modules = std.StringHashMap(void).init(allocator),
            .file_source_root = std.StringHashMap([]const u8).init(allocator),
            .module_is_private = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn deinit(self: *FileGraph) void {
        self.module_to_file.deinit();
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
        self.stdlib_modules.deinit();
        self.file_source_root.deinit();
        self.module_is_private.deinit();
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
pub fn discover(
    alloc: std.mem.Allocator,
    entry_module: []const u8,
    source_roots: []const SourceRoot,
    stdlib_module_names: []const []const u8,
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

    while (queue.items.len > 0) {
        const module_name = queue.orderedRemove(0);

        // Skip if already discovered or is a stdlib module
        if (graph.module_to_file.contains(module_name)) continue;
        if (graph.stdlib_modules.contains(module_name)) continue;

        // Resolve module name to file path
        const resolved = resolveModuleToFile(alloc, module_name, source_roots) orelse {
            if (err_info) |info| info.unresolved_module = module_name;
            return error.ModuleNotFound;
        };
        const file_path = resolved.path;

        graph.module_to_file.put(module_name, file_path) catch return error.OutOfMemory;
        graph.file_source_root.put(file_path, resolved.source_root_name) catch return error.OutOfMemory;

        // Read and scan the file for module references
        const source = std.fs.cwd().readFileAlloc(alloc, file_path, 10 * 1024 * 1024) catch
            return error.ReadError;

        // Track whether this module is private (defmodulep)
        graph.module_is_private.put(module_name, isPrivateModule(source)) catch return error.OutOfMemory;

        const refs = extractModuleReferences(alloc, source, module_name) catch
            return error.OutOfMemory;

        // Record imports for this file
        var imports_list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (refs) |ref| {
            // Skip self-references, stdlib modules, and already-queued modules
            if (std.mem.eql(u8, ref, module_name)) continue;
            if (graph.stdlib_modules.contains(ref)) continue;

            imports_list.append(alloc, ref) catch return error.OutOfMemory;

            // Add to queue if not yet discovered
            if (!graph.module_to_file.contains(ref)) {
                queue.append(alloc, ref) catch return error.OutOfMemory;
            }
        }
        graph.file_imports.put(file_path, imports_list) catch return error.OutOfMemory;
    }

    // Build imported_by (reverse index)
    {
        var it = graph.file_imports.iterator();
        while (it.next()) |entry| {
            const importer_file = entry.key_ptr.*;
            for (entry.value_ptr.items) |imported_module| {
                if (graph.module_to_file.get(imported_module)) |imported_file| {
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
pub fn moduleNameToRelPath(alloc: std.mem.Allocator, module_name: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;

    var it = std.mem.splitScalar(u8, module_name, '.');
    var first = true;
    while (it.next()) |segment| {
        if (!first) try result.append(alloc, '/');
        first = false;

        // PascalCase → snake_case
        for (segment, 0..) |c, i| {
            if (std.ascii.isUpper(c)) {
                if (i > 0) try result.append(alloc, '_');
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
    const rel_path = moduleNameToRelPath(alloc, module_name) catch return null;

    for (source_roots) |root| {
        const full_path = std.fs.path.join(alloc, &.{ root.path, rel_path }) catch continue;
        // Check if the file exists
        std.fs.cwd().access(full_path, .{}) catch continue;
        return .{ .path = full_path, .source_root_name = root.name };
    }

    return null;
}

/// Check if a source file declares its module with `defmodulep` (private).
/// Uses the lexer for a fast scan — no full parsing needed.
fn isPrivateModule(source: []const u8) bool {
    var lexer = zap.Lexer.init(source);
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;
        if (tok.tag == .keyword_defmodulep) return true;
        if (tok.tag == .keyword_defmodule) return false;
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

    // Scan tokens looking for module_identifier patterns
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;

        if (tok.tag == .module_identifier) {
            // Collect the full dotted module name: Foo.Bar.Baz
            var name_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer name_buf.deinit(alloc);
            try name_buf.appendSlice(alloc, tok.slice(source));

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

            // Also register parent modules for nested names
            // "Config.Parser" → also register "Config" as a potential reference
            // (but only if Config.Parser is the module — Config alone might not be)
            // For discovery, we try the most specific name first and fall back.
        }
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

    // Initialize all files with in-degree 0
    var mod_it = graph.module_to_file.iterator();
    while (mod_it.next()) |entry| {
        in_degree.put(entry.value_ptr.*, 0) catch return error.OutOfMemory;
    }

    // Count dependencies: for each file, count how many of its imports resolve to files in the graph
    var import_it = graph.file_imports.iterator();
    while (import_it.next()) |entry| {
        const importing_file = entry.key_ptr.*;
        var dep_count: u32 = 0;
        for (entry.value_ptr.items) |imported_module| {
            if (graph.module_to_file.get(imported_module)) |_| {
                dep_count += 1;
            }
        }
        if (in_degree.getPtr(importing_file)) |deg| {
            deg.* = dep_count;
        }
    }

    // Queue files with in-degree 0 (no dependencies — leaf libraries)
    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);

    var deg_it = in_degree.iterator();
    while (deg_it.next()) |entry| {
        if (entry.value_ptr.* == 0) {
            queue.append(alloc, entry.key_ptr.*) catch return error.OutOfMemory;
        }
    }

    var sorted_count: u32 = 0;
    while (queue.items.len > 0) {
        const file = queue.orderedRemove(0);
        graph.topo_order.append(alloc, file) catch return error.OutOfMemory;
        sorted_count += 1;

        // This file is now "resolved." Decrement in-degree of all files that
        // depend on this file (i.e., files that import this file's module).
        if (graph.file_imported_by.get(file)) |dependents| {
            for (dependents.items) |dependent_file| {
                if (in_degree.getPtr(dependent_file)) |deg| {
                    if (deg.* > 0) {
                        deg.* -= 1;
                        if (deg.* == 0) {
                            queue.append(alloc, dependent_file) catch return error.OutOfMemory;
                        }
                    }
                }
            }
        }
    }

    const total_files = in_degree.count();
    if (sorted_count != total_files) {
        return error.CircularDependency;
    }
}

/// Well-known stdlib module names that should not be resolved as file paths.
pub const STDLIB_MODULES = [_][]const u8{
    "Kernel",
    "IO",
    "System",
    "String",
    "Atom",
    "Integer",
    "Float",
    "Zap",
    "Zap.Env",
    "Zap.Manifest",
};

// ============================================================
// Tests
// ============================================================

test "moduleNameToRelPath: simple module" {
    const alloc = std.testing.allocator;
    const result = try moduleNameToRelPath(alloc, "Config");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("config.zap", result);
}

test "moduleNameToRelPath: nested module" {
    const alloc = std.testing.allocator;
    const result = try moduleNameToRelPath(alloc, "Config.Parser");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("config/parser.zap", result);
}

test "moduleNameToRelPath: PascalCase to snake_case" {
    const alloc = std.testing.allocator;
    const result = try moduleNameToRelPath(alloc, "JsonParser");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("json_parser.zap", result);
}

test "moduleNameToRelPath: deeply nested" {
    const alloc = std.testing.allocator;
    const result = try moduleNameToRelPath(alloc, "App.Http.Middleware");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("app/http/middleware.zap", result);
}

test "extractModuleReferences: finds qualified calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\defmodule App do
        \\  def main() :: String do
        \\    Config.load("/etc/app")
        \\    IO.puts("hello")
        \\  end
        \\end
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
        \\defmodule App do
        \\  def main() :: String do
        \\    Config.Parser.parse("data")
        \\  end
        \\end
    ;
    const refs = try extractModuleReferences(alloc, source, "App");

    var found = false;
    for (refs) |ref| {
        if (std.mem.eql(u8, ref, "Config.Parser")) found = true;
    }
    try std.testing.expect(found);
}

test "isPrivateModule: detects defmodulep" {
    try std.testing.expect(isPrivateModule("defmodulep Foo do\nend\n"));
    try std.testing.expect(!isPrivateModule("defmodule Foo do\nend\n"));
    try std.testing.expect(!isPrivateModule("defstruct Foo do\nend\n"));
}

test "discover: single file with no references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create temp directory with a single .zap file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "app.zap",
        .data = "defmodule App do\n  def main() :: i64 do\n    42\n  end\nend\n",
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discover(alloc, "App", roots, &STDLIB_MODULES, null);
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
    try tmp_dir.dir.writeFile(.{
        .sub_path = "app.zap",
        .data = "defmodule App do\n  def main() :: i64 do\n    Helper.run()\n  end\nend\n",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "helper.zap",
        .data = "defmodule Helper do\n  def run() :: i64 do\n    Util.value()\n  end\nend\n",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "util.zap",
        .data = "defmodule Util do\n  def value() :: i64 do\n    1\n  end\nend\n",
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    var graph = try discover(alloc, "App", roots, &STDLIB_MODULES, null);
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

test "discover: circular dependency detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // A → B → A (cycle)
    try tmp_dir.dir.writeFile(.{
        .sub_path = "cycle_a.zap",
        .data = "defmodule CycleA do\n  def go() :: i64 do\n    CycleB.go()\n  end\nend\n",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "cycle_b.zap",
        .data = "defmodule CycleB do\n  def go() :: i64 do\n    CycleA.go()\n  end\nend\n",
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    const result = discover(alloc, "CycleA", roots, &STDLIB_MODULES, null);
    try std.testing.expectError(error.CircularDependency, result);
}

test "discover: module not found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // App references NonExistent which doesn't exist
    try tmp_dir.dir.writeFile(.{
        .sub_path = "app.zap",
        .data = "defmodule App do\n  def main() :: i64 do\n    NonExistent.foo()\n  end\nend\n",
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");
    const roots = &[_]SourceRoot{.{ .name = "project", .path = tmp_path }};

    const result = discover(alloc, "App", roots, &STDLIB_MODULES, null);
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "discover: module found in dep root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Project references DepMod which is in a separate dep root
    tmp_dir.dir.makePath("project") catch {};
    tmp_dir.dir.makePath("dep_lib") catch {};

    try tmp_dir.dir.writeFile(.{
        .sub_path = "project/app.zap",
        .data = "defmodule App do\n  def main() :: i64 do\n    DepMod.value()\n  end\nend\n",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "dep_lib/dep_mod.zap",
        .data = "defmodule DepMod do\n  def value() :: i64 do\n    99\n  end\nend\n",
    });

    const project_path = try tmp_dir.dir.realpathAlloc(alloc, "project");
    const dep_path = try tmp_dir.dir.realpathAlloc(alloc, "dep_lib");
    const roots = &[_]SourceRoot{
        .{ .name = "project", .path = project_path },
        .{ .name = "dep:mylib", .path = dep_path },
    };

    var graph = try discover(alloc, "App", roots, &STDLIB_MODULES, null);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 2), graph.topo_order.items.len);
    try std.testing.expect(graph.module_to_file.contains("App"));
    try std.testing.expect(graph.module_to_file.contains("DepMod"));

    // DepMod should be in the dep source root
    const dep_mod_file = graph.module_to_file.get("DepMod").?;
    const dep_root = graph.file_source_root.get(dep_mod_file).?;
    try std.testing.expectEqualStrings("dep:mylib", dep_root);
}
