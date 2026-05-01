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
        for (files, 0..) |file, i| {
            var deps: std.ArrayList(usize) = .empty;
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
        }
        return .{
            .allocator = allocator,
            .files = files,
            .edges = edges,
        };
    }

    /// Topological sort. Returns file indices in dependency order.
    /// Returns error if a cycle is detected.
    pub fn topologicalSort(self: *const DependencyGraph, allocator: std.mem.Allocator) ![]const usize {
        const n = self.files.len;
        var in_degree = try allocator.alloc(usize, n);
        @memset(in_degree, 0);

        for (self.edges) |deps| {
            for (deps) |dep| {
                in_degree[dep] += 1;
            }
        }

        // Note: in_degree counts how many files depend ON this file,
        // but for topo sort we need how many files this file depends on.
        // Let me fix: edges[i] = files that i depends on.
        // For topo sort, we need: process files with no dependencies first.
        @memset(in_degree, 0);
        for (0..n) |i| {
            in_degree[i] = self.edges[i].len;
        }

        var queue: std.ArrayList(usize) = .empty;
        for (0..n) |i| {
            if (in_degree[i] == 0) {
                try queue.append(allocator, i);
            }
        }

        // Build reverse edges: reverse_edges[j] = files that depend on j
        var reverse_edges = try allocator.alloc(std.ArrayList(usize), n);
        for (0..n) |i| {
            reverse_edges[i] = .empty;
        }
        for (0..n) |i| {
            for (self.edges[i]) |dep| {
                try reverse_edges[dep].append(allocator, i);
            }
        }

        var result: std.ArrayList(usize) = .empty;
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

        if (result.items.len != n) {
            return error.CircularDependency;
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Format a human-readable circular dependency error message.
    /// Call this after topologicalSort returns CircularDependency.
    pub fn formatCycleError(self: *const DependencyGraph, allocator: std.mem.Allocator) ![]const u8 {
        var msg: std.ArrayList(u8) = .empty;
        try msg.appendSlice(allocator, "error: circular dependency between files\n");

        // Find files involved in cycles (those not processed by topo sort)
        const n = self.files.len;
        var in_degree = try allocator.alloc(usize, n);
        @memset(in_degree, 0);
        for (0..n) |i| {
            in_degree[i] = self.edges[i].len;
        }
        // Run partial topo sort to find remaining cycle members
        var processed = try allocator.alloc(bool, n);
        @memset(processed, false);
        var changed = true;
        while (changed) {
            changed = false;
            for (0..n) |i| {
                if (!processed[i] and in_degree[i] == 0) {
                    processed[i] = true;
                    changed = true;
                    for (0..n) |j| {
                        for (self.edges[j]) |dep| {
                            if (dep == i) {
                                in_degree[j] -= 1;
                            }
                        }
                    }
                }
            }
        }

        // Report cycle edges
        for (0..n) |i| {
            if (processed[i]) continue;
            for (self.edges[i]) |dep| {
                if (processed[dep]) continue;
                const line = try std.fmt.allocPrint(allocator, "  {s} depends on {s}\n", .{
                    self.files[i].path,
                    self.files[dep].path,
                });
                try msg.appendSlice(allocator, line);
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

/// Discover all .zap files in the same directory as the given file.
/// Only returns multiple files if they form a project (at least one file
/// references a type or struct defined in another file). Standalone files
/// in a directory of unrelated .zap files stay in single-file mode.
pub fn discoverZapFiles(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const dir_path = std.fs.path.dirname(path) orelse ".";

    const pio = std.Options.debug_io;
    var dir = std.Io.Dir.cwd().openDir(pio, dir_path, .{ .iterate = true }) catch {
        var result = try allocator.alloc([]const u8, 1);
        result[0] = path;
        return result;
    };
    defer dir.close(pio);

    var candidate_paths: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next(pio)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
        const full_path = if (std.mem.eql(u8, dir_path, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ dir_path, entry.name });
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

    for (candidate_paths.items) |cp| {
        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, cp, allocator, .limited(10 * 1024 * 1024)) catch continue;
        var parser = @import("parser.zig").Parser.init(allocator, source);
        defer parser.deinit();
        const program = parser.parseProgram() catch continue;
        const analysis = analyzeProgram(allocator, &program, parser.interner) catch continue;
        for (analysis.defines_types) |dt| try all_defined.append(allocator, dt);
        for (analysis.defines_structs) |dm| try all_defined.append(allocator, dm);
        for (analysis.references_types) |rt| try all_referenced.append(allocator, rt);
        for (analysis.references_structs) |rm| try all_referenced.append(allocator, rm);
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

    return try candidate_paths.toOwnedSlice(allocator);
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
    var def_structs: std.ArrayList([]const u8) = .empty;
    var def_functions: std.ArrayList([]const u8) = .empty;
    var ref_types: std.ArrayList([]const u8) = .empty;
    var ref_structs: std.ArrayList([]const u8) = .empty;
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

    return .{
        .defines_types = try def_types.toOwnedSlice(allocator),
        .defines_structs = try def_structs.toOwnedSlice(allocator),
        .defines_functions = try def_functions.toOwnedSlice(allocator),
        .references_types = try filtered_ref_types.toOwnedSlice(allocator),
        .references_structs = try filtered_ref_structs.toOwnedSlice(allocator),
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
    for (func.body) |stmt| {
        try collectTypeRefsFromStmt(allocator, stmt, interner, ref_types);
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

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

    var graph = try DependencyGraph.init(alloc, &files);
    const topo_result = graph.topologicalSort(alloc);
    try std.testing.expectError(error.CircularDependency, topo_result);

    const message = try graph.formatCycleError(alloc);
    try std.testing.expect(std.mem.indexOf(u8, message, "error: circular dependency between files") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "lib/cycle_a.zap depends on lib/cycle_b.zap") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "lib/cycle_b.zap depends on lib/cycle_a.zap") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "break the cycle") != null);
}
