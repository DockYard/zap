const std = @import("std");
const ast = @import("ast.zig");

// ============================================================
// Multi-file project support
//
// Discovers .zap files, builds dependency graphs, detects
// cycles, and determines compilation order.
// ============================================================

pub const FileUnit = struct {
    path: []const u8,
    stem: []const u8,
    source: []const u8,
    defines_types: []const []const u8,
    defines_structs: []const []const u8,
    defines_functions: []const []const u8 = &.{},
    references_types: []const []const u8,
    references_structs: []const []const u8,
    has_main: bool,
};

pub const DependencyGraph = struct {
    allocator: std.mem.Allocator,
    files: []const FileUnit,
    /// edges[i] = list of file indices that file i depends on
    edges: []const []const usize,

    pub fn init(allocator: std.mem.Allocator, files: []const FileUnit) !DependencyGraph {
        var edges = try allocator.alloc([]const usize, files.len);
        var initialized_edges: usize = 0;
        errdefer {
            for (edges[0..initialized_edges]) |deps| {
                allocator.free(deps);
            }
            allocator.free(edges);
        }

        for (files, 0..) |file, i| {
            var deps: std.ArrayList(usize) = .empty;
            errdefer deps.deinit(allocator);

            for (file.references_types) |ref_type| {
                // Find which file defines this type
                for (files, 0..) |other, j| {
                    if (i == j) continue;
                    for (other.defines_types) |def_type| {
                        if (std.mem.eql(u8, ref_type, def_type)) {
                            // Check not already in deps
                            var found = false;
                            for (deps.items) |d| {
                                if (d == j) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                try deps.append(allocator, j);
                            }
                        }
                    }
                }
            }
            for (file.references_structs) |ref_mod| {
                for (files, 0..) |other, j| {
                    if (i == j) continue;
                    for (other.defines_structs) |def_mod| {
                        if (std.mem.eql(u8, ref_mod, def_mod)) {
                            var found = false;
                            for (deps.items) |d| {
                                if (d == j) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                try deps.append(allocator, j);
                            }
                        }
                    }
                }
            }
            edges[i] = try deps.toOwnedSlice(allocator);
            initialized_edges += 1;
        }
        return .{
            .allocator = allocator,
            .files = files,
            .edges = edges,
        };
    }

    /// Free dependency edge storage allocated by init.
    pub fn deinit(self: *DependencyGraph) void {
        const allocator = self.allocator;
        for (self.edges) |deps| {
            allocator.free(deps);
        }
        allocator.free(self.edges);
        self.* = .{
            .allocator = allocator,
            .files = &.{},
            .edges = &.{},
        };
    }

    /// Topological sort. Returns file indices in dependency order.
    /// Returns error if a cycle is detected.
    pub fn topologicalSort(self: *const DependencyGraph, allocator: std.mem.Allocator) ![]const usize {
        const file_count = self.files.len;
        var in_degree = try allocator.alloc(usize, file_count);
        defer allocator.free(in_degree);

        for (0..file_count) |file_index| {
            in_degree[file_index] = self.edges[file_index].len;
        }

        var queue: std.ArrayList(usize) = .empty;
        defer queue.deinit(allocator);

        for (0..file_count) |file_index| {
            if (in_degree[file_index] == 0) {
                try queue.append(allocator, file_index);
            }
        }

        // Build reverse edges: reverse_edges[j] = files that depend on j
        var reverse_edges = try allocator.alloc(std.ArrayList(usize), file_count);
        for (0..file_count) |file_index| {
            reverse_edges[file_index] = .empty;
        }
        defer {
            for (reverse_edges) |*dependents| {
                dependents.deinit(allocator);
            }
            allocator.free(reverse_edges);
        }

        for (0..file_count) |file_index| {
            for (self.edges[file_index]) |dependency_index| {
                try reverse_edges[dependency_index].append(allocator, file_index);
            }
        }

        var result: std.ArrayList(usize) = .empty;
        errdefer result.deinit(allocator);

        var head: usize = 0;
        while (head < queue.items.len) {
            const current = queue.items[head];
            head += 1;
            try result.append(allocator, current);

            for (reverse_edges[current].items) |dependent| {
                in_degree[dependent] -= 1;
                if (in_degree[dependent] == 0) {
                    try queue.append(allocator, dependent);
                }
            }
        }

        if (result.items.len != file_count) {
            return error.CircularDependency;
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Format a human-readable circular dependency error message.
    /// Call this after topologicalSort returns CircularDependency.
    pub fn formatCycleError(self: *const DependencyGraph, allocator: std.mem.Allocator) ![]const u8 {
        var msg: std.ArrayList(u8) = .empty;
        errdefer msg.deinit(allocator);

        try msg.appendSlice(allocator, "error: circular dependency between files\n");

        // Find files involved in cycles (those not processed by topo sort)
        const file_count = self.files.len;
        var in_degree = try allocator.alloc(usize, file_count);
        defer allocator.free(in_degree);

        for (0..file_count) |file_index| {
            in_degree[file_index] = self.edges[file_index].len;
        }

        // Run partial topo sort to find remaining cycle members
        var processed = try allocator.alloc(bool, file_count);
        defer allocator.free(processed);

        @memset(processed, false);
        var changed = true;
        while (changed) {
            changed = false;
            for (0..file_count) |file_index| {
                if (!processed[file_index] and in_degree[file_index] == 0) {
                    processed[file_index] = true;
                    changed = true;
                    for (0..file_count) |dependent_index| {
                        for (self.edges[dependent_index]) |dependency_index| {
                            if (dependency_index == file_index) {
                                in_degree[dependent_index] -= 1;
                            }
                        }
                    }
                }
            }
        }

        // Report cycle edges
        for (0..file_count) |file_index| {
            if (processed[file_index]) continue;
            for (self.edges[file_index]) |dependency_index| {
                if (processed[dependency_index]) continue;
                {
                    const line = try std.fmt.allocPrint(allocator, "  {s} depends on {s}\n", .{
                        self.files[file_index].path,
                        self.files[dependency_index].path,
                    });
                    defer allocator.free(line);

                    try msg.appendSlice(allocator, line);
                }
            }
        }

        try msg.appendSlice(allocator, "  = help: move related types into the same file, or break the cycle\n");
        return try msg.toOwnedSlice(allocator);
    }

    /// Find the main file (the one with def main()).
    pub fn findMainFile(self: *const DependencyGraph) !usize {
        var main_idx: ?usize = null;
        for (self.files, 0..) |file, i| {
            if (file.has_main) {
                if (main_idx != null) {
                    return error.MultipleMainFiles;
                }
                main_idx = i;
            }
        }
        return main_idx orelse error.NoMainFile;
    }
};

fn deinitOwnedStringList(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8)) void {
    for (values.items) |value| {
        allocator.free(value);
    }
    values.deinit(allocator);
}

fn appendOwnedStringCopies(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]const u8),
    borrowed_values: []const []const u8,
) !void {
    for (borrowed_values) |borrowed_value| {
        const owned_value = try allocator.dupe(u8, borrowed_value);
        errdefer allocator.free(owned_value);
        try values.append(allocator, owned_value);
    }
}

/// Discover all .zap files in the same directory as the given file.
/// Only returns multiple files if they form a project (at least one file
/// references a type or struct defined in another file). Standalone files
/// in a directory of unrelated .zap files stay in single-file mode.
pub fn discoverZapFiles(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const dir_path = std.fs.path.dirname(path) orelse ".";

    const pio = std.Options.debug_io;
    var dir = try std.Io.Dir.cwd().openDir(pio, dir_path, .{ .iterate = true });
    defer dir.close(pio);

    var candidate_paths: std.ArrayList([]const u8) = .empty;
    var candidate_paths_owned = true;
    defer if (candidate_paths_owned) deinitOwnedStringList(allocator, &candidate_paths);

    var iter = dir.iterate();
    while (try iter.next(pio)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
        const full_path = if (std.mem.eql(u8, dir_path, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        errdefer allocator.free(full_path);
        try candidate_paths.append(allocator, full_path);
    }

    if (candidate_paths.items.len <= 1) {
        var result = try allocator.alloc([]const u8, 1);
        result[0] = path;
        return result;
    }

    // Check if files actually reference each other (form a project).
    // Parse each file and collect what it defines vs references.
    var all_defined: std.ArrayList([]const u8) = .empty;
    var all_referenced: std.ArrayList([]const u8) = .empty;
    defer deinitOwnedStringList(allocator, &all_defined);
    defer deinitOwnedStringList(allocator, &all_referenced);

    for (candidate_paths.items) |cp| {
        var parse_arena = std.heap.ArenaAllocator.init(allocator);
        defer parse_arena.deinit();
        const parse_allocator = parse_arena.allocator();

        const source = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, cp, parse_allocator, .limited(10 * 1024 * 1024));
        var parser = try @import("parser.zig").Parser.init(parse_allocator, source);
        defer parser.deinit();
        const program = try parser.parseProgram();
        const analysis = try analyzeProgram(parse_allocator, &program, parser.interner);
        try appendOwnedStringCopies(allocator, &all_defined, analysis.defines_types);
        try appendOwnedStringCopies(allocator, &all_defined, analysis.defines_structs);
        try appendOwnedStringCopies(allocator, &all_referenced, analysis.references_types);
        try appendOwnedStringCopies(allocator, &all_referenced, analysis.references_structs);
    }

    // If any referenced name matches a name defined in another file, it's a project
    var is_project = false;
    for (all_referenced.items) |ref| {
        for (all_defined.items) |def| {
            if (std.mem.eql(u8, ref, def)) {
                is_project = true;
                break;
            }
        }
        if (is_project) break;
    }

    if (!is_project) {
        // Standalone files — single-file mode
        var result = try allocator.alloc([]const u8, 1);
        result[0] = path;
        return result;
    }

    const result = try candidate_paths.toOwnedSlice(allocator);
    candidate_paths_owned = false;
    return result;
}

test "discoverZapFiles propagates missing required directory" {
    try std.testing.expectError(
        error.FileNotFound,
        discoverZapFiles(std.testing.allocator, "missing-required-source-dir/app.zap"),
    );
}

test "discoverZapFiles propagates allocator failure while reading candidates" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {}",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "dep.zap",
        .data = "pub struct Dep {}",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", arena.allocator());
    const app_path = try std.fs.path.join(arena.allocator(), &.{ root_path, "app.zap" });

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        discoverZapFiles(failing_allocator.allocator(), app_path),
    );
}

test "discoverZapFiles frees candidate paths for single-file mode" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {}",
    });

    const allocator = std.testing.allocator;
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root_path);
    const app_path = try std.fs.path.join(allocator, &.{ root_path, "app.zap" });
    defer allocator.free(app_path);

    const discovered = try discoverZapFiles(allocator, app_path);
    defer allocator.free(discovered);
    try std.testing.expectEqual(@as(usize, 1), discovered.len);
    try std.testing.expectEqualStrings(app_path, discovered[0]);
}

test "discoverZapFiles frees analysis temporaries for non-project mode" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {}",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "dep.zap",
        .data = "pub struct Dep {}",
    });

    const allocator = std.testing.allocator;
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root_path);
    const app_path = try std.fs.path.join(allocator, &.{ root_path, "app.zap" });
    defer allocator.free(app_path);

    const discovered = try discoverZapFiles(allocator, app_path);
    defer allocator.free(discovered);
    try std.testing.expectEqual(@as(usize, 1), discovered.len);
    try std.testing.expectEqualStrings(app_path, discovered[0]);
}

test "discoverZapFiles cleans candidates and parse temporaries on parse failure" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "dep.zap",
        .data = "pub struct Dep {}",
    });

    const allocator = std.testing.allocator;
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root_path);
    const app_path = try std.fs.path.join(allocator, &.{ root_path, "app.zap" });
    defer allocator.free(app_path);

    try std.testing.expectError(
        error.ParseError,
        discoverZapFiles(allocator, app_path),
    );
}

test "discoverZapFiles transfers candidate path ownership for project mode" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "app.zap",
        .data =
        \\pub struct App {
        \\  pub fn main(dep :: Dep) {
        \\    dep
        \\  }
        \\}
        ,
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "dep.zap",
        .data = "pub struct Dep {}",
    });

    const allocator = std.testing.allocator;
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root_path);
    const app_path = try std.fs.path.join(allocator, &.{ root_path, "app.zap" });
    defer allocator.free(app_path);

    const discovered = try discoverZapFiles(allocator, app_path);
    defer {
        for (discovered) |candidate_path| allocator.free(candidate_path);
        allocator.free(discovered);
    }
    try std.testing.expectEqual(@as(usize, 2), discovered.len);
}

/// Analyze a parsed program to determine what types and structs it defines and references.
pub fn analyzeProgram(
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    interner: *const ast.StringInterner,
) !struct {
    defines_types: []const []const u8,
    defines_structs: []const []const u8,
    defines_functions: []const []const u8,
    references_types: []const []const u8,
    references_structs: []const []const u8,
    has_main: bool,
} {
    var def_types: std.ArrayList([]const u8) = .empty;
    errdefer def_types.deinit(allocator);
    var def_structs: std.ArrayList([]const u8) = .empty;
    errdefer def_structs.deinit(allocator);
    var def_functions: std.ArrayList([]const u8) = .empty;
    errdefer def_functions.deinit(allocator);
    var ref_types: std.ArrayList([]const u8) = .empty;
    defer ref_types.deinit(allocator);
    var ref_structs: std.ArrayList([]const u8) = .empty;
    defer ref_structs.deinit(allocator);
    var has_main = false;

    for (program.top_items) |item| {
        switch (item) {
            .struct_decl, .priv_struct_decl => |sd| {
                if (sd.name.parts.len > 0) {
                    const struct_name = interner.get(sd.name.parts[0]);
                    try def_structs.append(allocator, struct_name);
                }
                // Check for extends (references parent struct)
                if (sd.parent) |parent| {
                    try ref_structs.append(allocator, interner.get(parent));
                }
                // Scan struct functions for type references and main
                for (sd.items) |struct_item| {
                    switch (struct_item) {
                        .function => |func_decl| {
                            for (func_decl.clauses) |*clause| {
                                try collectTypeRefsFromFunction(allocator, clause, interner, &ref_types);
                            }
                            if (std.mem.eql(u8, interner.get(func_decl.name), "main")) {
                                has_main = true;
                            }
                        },
                        .priv_function => |func_decl| {
                            for (func_decl.clauses) |*clause| {
                                try collectTypeRefsFromFunction(allocator, clause, interner, &ref_types);
                            }
                        },
                        else => {},
                    }
                }
                // Also register struct field types
                for (sd.fields) |field| {
                    _ = field;
                }
            },
            .union_decl => |ed| {
                try def_types.append(allocator, interner.get(ed.name));
            },
            .function => |func_decl| {
                const fname = interner.get(func_decl.name);
                try def_functions.append(allocator, fname);
                for (func_decl.clauses) |*clause| {
                    try collectTypeRefsFromFunction(allocator, clause, interner, &ref_types);
                }
                if (std.mem.eql(u8, fname, "main")) {
                    has_main = true;
                }
            },
            else => {},
        }
    }

    // Remove self-references (types defined in this file)
    var filtered_ref_types: std.ArrayList([]const u8) = .empty;
    errdefer filtered_ref_types.deinit(allocator);
    for (ref_types.items) |rt| {
        var is_self = false;
        for (def_types.items) |dt| {
            if (std.mem.eql(u8, rt, dt)) {
                is_self = true;
                break;
            }
        }
        if (!is_self) {
            try filtered_ref_types.append(allocator, rt);
        }
    }

    var filtered_ref_structs: std.ArrayList([]const u8) = .empty;
    errdefer filtered_ref_structs.deinit(allocator);
    for (ref_structs.items) |rm| {
        var is_self = false;
        for (def_structs.items) |dm| {
            if (std.mem.eql(u8, rm, dm)) {
                is_self = true;
                break;
            }
        }
        if (!is_self) {
            try filtered_ref_structs.append(allocator, rm);
        }
    }

    const defines_types = try def_types.toOwnedSlice(allocator);
    errdefer allocator.free(defines_types);
    const defines_structs = try def_structs.toOwnedSlice(allocator);
    errdefer allocator.free(defines_structs);
    const defines_functions = try def_functions.toOwnedSlice(allocator);
    errdefer allocator.free(defines_functions);
    const references_types = try filtered_ref_types.toOwnedSlice(allocator);
    errdefer allocator.free(references_types);
    const references_structs = try filtered_ref_structs.toOwnedSlice(allocator);
    errdefer allocator.free(references_structs);

    return .{
        .defines_types = defines_types,
        .defines_structs = defines_structs,
        .defines_functions = defines_functions,
        .references_types = references_types,
        .references_structs = references_structs,
        .has_main = has_main,
    };
}

fn collectTypeRefsFromFunction(
    allocator: std.mem.Allocator,
    func: *const ast.FunctionClause,
    interner: *const ast.StringInterner,
    ref_types: *std.ArrayList([]const u8),
) !void {
    for (func.params) |param| {
        if (param.type_annotation) |ann| {
            try collectTypeRefsFromTypeExpr(allocator, ann, interner, ref_types);
        }
    }
    if (func.return_type) |rt| {
        try collectTypeRefsFromTypeExpr(allocator, rt, interner, ref_types);
    }
    // Scan function body for struct_expr type references
    if (func.body) |body| {
        for (body) |stmt| {
            try collectTypeRefsFromStmt(allocator, stmt, interner, ref_types);
        }
    }
}

fn collectTypeRefsFromStmt(
    allocator: std.mem.Allocator,
    stmt: ast.Stmt,
    interner: *const ast.StringInterner,
    ref_types: *std.ArrayList([]const u8),
) anyerror!void {
    switch (stmt) {
        .expr => |expr| try collectTypeRefsFromExpr(allocator, expr, interner, ref_types),
        .assignment => |assign| try collectTypeRefsFromExpr(allocator, assign.value, interner, ref_types),
        else => {},
    }
}

fn collectTypeRefsFromExpr(
    allocator: std.mem.Allocator,
    expr: *const ast.Expr,
    interner: *const ast.StringInterner,
    ref_types: *std.ArrayList([]const u8),
) anyerror!void {
    switch (expr.*) {
        .struct_expr => |se| {
            if (se.struct_name.parts.len > 0) {
                const name = interner.get(se.struct_name.parts[0]);
                if (!isBuiltinTypeName(name)) {
                    try ref_types.append(allocator, name);
                }
            }
            for (se.fields) |field| {
                try collectTypeRefsFromExpr(allocator, field.value, interner, ref_types);
            }
        },
        .call => |call| {
            try collectTypeRefsFromExpr(allocator, call.callee, interner, ref_types);
            for (call.args) |arg| {
                try collectTypeRefsFromExpr(allocator, arg, interner, ref_types);
            }
        },
        .binary_op => |bo| {
            try collectTypeRefsFromExpr(allocator, bo.lhs, interner, ref_types);
            try collectTypeRefsFromExpr(allocator, bo.rhs, interner, ref_types);
        },
        .if_expr => |ie| {
            try collectTypeRefsFromExpr(allocator, ie.condition, interner, ref_types);
            for (ie.then_block) |s| try collectTypeRefsFromStmt(allocator, s, interner, ref_types);
            if (ie.else_block) |eb| {
                for (eb) |s| try collectTypeRefsFromStmt(allocator, s, interner, ref_types);
            }
        },
        .case_expr => |ce| {
            try collectTypeRefsFromExpr(allocator, ce.scrutinee, interner, ref_types);
            for (ce.clauses) |clause| {
                for (clause.body) |s| try collectTypeRefsFromStmt(allocator, s, interner, ref_types);
            }
        },
        else => {},
    }
}

fn collectTypeRefsFromTypeExpr(
    allocator: std.mem.Allocator,
    type_expr: *const ast.TypeExpr,
    interner: *const ast.StringInterner,
    ref_types: *std.ArrayList([]const u8),
) !void {
    switch (type_expr.*) {
        .name => |tn| {
            const name = interner.get(tn.name);
            // Skip builtin type names
            if (!isBuiltinTypeName(name)) {
                try ref_types.append(allocator, name);
            }
        },
        .paren => |p| {
            try collectTypeRefsFromTypeExpr(allocator, p.inner, interner, ref_types);
        },
        .never => {},
        else => {},
    }
}

fn isBuiltinTypeName(name: []const u8) bool {
    const builtins = [_][]const u8{
        "Bool",  "String", "Atom", "Nil", "Never",
        "i128",  "i64",    "i32",  "i16", "i8",
        "u128",  "u64",    "u32",  "u16", "u8",
        "f128",  "f80",    "f64",  "f32", "f16",
        "usize", "isize",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

test "DependencyGraph cycle diagnostic lists cycle edges and help" {
    const allocator = std.testing.allocator;
    const files = [_]FileUnit{
        .{
            .path = "lib/cycle_a.zap",
            .stem = "cycle_a",
            .source = "",
            .defines_types = &.{},
            .defines_structs = &.{"CycleA"},
            .references_types = &.{},
            .references_structs = &.{"CycleB"},
            .has_main = false,
        },
        .{
            .path = "lib/cycle_b.zap",
            .stem = "cycle_b",
            .source = "",
            .defines_types = &.{},
            .defines_structs = &.{"CycleB"},
            .references_types = &.{},
            .references_structs = &.{"CycleA"},
            .has_main = false,
        },
    };

    var graph = try DependencyGraph.init(allocator, &files);
    defer graph.deinit();

    const topo_result = graph.topologicalSort(allocator);
    try std.testing.expectError(error.CircularDependency, topo_result);

    const message = try graph.formatCycleError(allocator);
    defer allocator.free(message);

    try std.testing.expect(std.mem.indexOf(u8, message, "error: circular dependency between files") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "lib/cycle_a.zap depends on lib/cycle_b.zap") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "lib/cycle_b.zap depends on lib/cycle_a.zap") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "break the cycle") != null);
}

test "DependencyGraph topologicalSort returns dependency order without leaks" {
    const allocator = std.testing.allocator;
    const files = [_]FileUnit{
        .{
            .path = "lib/app.zap",
            .stem = "app",
            .source = "",
            .defines_types = &.{},
            .defines_structs = &.{"App"},
            .references_types = &.{},
            .references_structs = &.{"Service"},
            .has_main = true,
        },
        .{
            .path = "lib/service.zap",
            .stem = "service",
            .source = "",
            .defines_types = &.{},
            .defines_structs = &.{"Service"},
            .references_types = &.{},
            .references_structs = &.{"Data"},
            .has_main = false,
        },
        .{
            .path = "lib/data.zap",
            .stem = "data",
            .source = "",
            .defines_types = &.{},
            .defines_structs = &.{"Data"},
            .references_types = &.{},
            .references_structs = &.{},
            .has_main = false,
        },
    };

    var graph = try DependencyGraph.init(allocator, &files);
    defer graph.deinit();

    const sorted = try graph.topologicalSort(allocator);
    defer allocator.free(sorted);

    try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 1, 0 }, sorted);
}

test "DependencyGraph topologicalSort releases temporaries on allocator failure" {
    const files = [_]FileUnit{
        .{
            .path = "lib/app.zap",
            .stem = "app",
            .source = "",
            .defines_types = &.{},
            .defines_structs = &.{"App"},
            .references_types = &.{},
            .references_structs = &.{"Service"},
            .has_main = true,
        },
        .{
            .path = "lib/service.zap",
            .stem = "service",
            .source = "",
            .defines_types = &.{},
            .defines_structs = &.{"Service"},
            .references_types = &.{},
            .references_structs = &.{"Data"},
            .has_main = false,
        },
        .{
            .path = "lib/data.zap",
            .stem = "data",
            .source = "",
            .defines_types = &.{},
            .defines_structs = &.{"Data"},
            .references_types = &.{},
            .references_structs = &.{},
            .has_main = false,
        },
    };
    const app_edges = [_]usize{1};
    const service_edges = [_]usize{2};
    const data_edges = [_]usize{};
    const edge_lists = [_][]const usize{ &app_edges, &service_edges, &data_edges };
    const graph = DependencyGraph{
        .allocator = std.testing.allocator,
        .files = &files,
        .edges = &edge_lists,
    };

    for (0..16) |fail_index| {
        var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing_allocator.allocator();

        const result = graph.topologicalSort(allocator);
        if (result) |sorted| {
            defer allocator.free(sorted);
            try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 1, 0 }, sorted);
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
    }
}

test "DependencyGraph formatCycleError releases temporaries on allocator failure" {
    const files = [_]FileUnit{
        .{
            .path = "lib/cycle_a.zap",
            .stem = "cycle_a",
            .source = "",
            .defines_types = &.{},
            .defines_structs = &.{"CycleA"},
            .references_types = &.{},
            .references_structs = &.{"CycleB"},
            .has_main = false,
        },
        .{
            .path = "lib/cycle_b.zap",
            .stem = "cycle_b",
            .source = "",
            .defines_types = &.{},
            .defines_structs = &.{"CycleB"},
            .references_types = &.{},
            .references_structs = &.{"CycleA"},
            .has_main = false,
        },
    };
    const cycle_a_edges = [_]usize{1};
    const cycle_b_edges = [_]usize{0};
    const edge_lists = [_][]const usize{ &cycle_a_edges, &cycle_b_edges };
    const graph = DependencyGraph{
        .allocator = std.testing.allocator,
        .files = &files,
        .edges = &edge_lists,
    };

    for (0..24) |fail_index| {
        var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing_allocator.allocator();

        const message = graph.formatCycleError(allocator) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer allocator.free(message);

        try std.testing.expect(std.mem.indexOf(u8, message, "lib/cycle_a.zap depends on lib/cycle_b.zap") != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "lib/cycle_b.zap depends on lib/cycle_a.zap") != null);
    }
}
