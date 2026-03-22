//! Builder Phase
//!
//! Handles compiling build.zap as a separate binary, executing it to obtain
//! the manifest, and parsing the manifest output.
//!
//! The builder binary receives env data as command-line arguments and outputs
//! the manifest as a simple key=value format on stdout.

const std = @import("std");
const zap = @import("root.zig");
const compiler = zap.compiler;
const zir_backend = zap.zir_backend;

/// Parsed manifest from the builder output.
pub const BuildConfig = struct {
    name: []const u8,
    version: []const u8,
    kind: Kind,
    root: ?[]const u8 = null,
    asset_name: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    build_opts: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub const Kind = enum { bin, lib, obj };
};

/// Scan build.zap AST to find the module defining manifest/1.
/// Returns the module name (e.g., "FooBar.Builder").
pub fn findBuilderModule(
    alloc: std.mem.Allocator,
    build_source: []const u8,
) ![]const u8 {
    // Parse build.zap
    const prepend_result = zap.stdlib.prependStdlib(alloc, build_source) catch
        return error.StdlibError;
    const full_source = prepend_result.source;

    var parser = zap.Parser.init(alloc, full_source);
    defer parser.deinit();

    const program = parser.parseProgram() catch return error.ParseFailed;

    // Walk module declarations looking for manifest/1
    for (program.modules) |mod| {
        for (mod.items) |item| {
            switch (item) {
                .function => |func| {
                    const name = parser.interner.get(func.name);
                    if (std.mem.eql(u8, name, "manifest") and func.clauses.len > 0 and func.clauses[0].params.len == 1) {
                        // Found it — reconstruct the module name
                        var mod_name_buf: std.ArrayListUnmanaged(u8) = .empty;
                        for (mod.name.parts, 0..) |part, i| {
                            if (i > 0) try mod_name_buf.append(alloc, '.');
                            const part_str = parser.interner.get(part);
                            try mod_name_buf.appendSlice(alloc, part_str);
                        }
                        return try mod_name_buf.toOwnedSlice(alloc);
                    }
                },
                else => {},
            }
        }
    }

    return error.ManifestNotFound;
}

/// Generate the wrapper main source that calls the builder's manifest/1.
/// The wrapper reads env from CLI args, calls manifest(env), and writes
/// the result as key=value lines to stdout.
pub fn generateWrapperMain(
    alloc: std.mem.Allocator,
    builder_module: []const u8,
) ![]const u8 {
    // Generate a wrapper that calls the builder module's manifest function.
    // For now, generate a simple main that calls manifest with a hardcoded env
    // and prints the result fields.
    //
    // The wrapper is Zap source text prepended to build.zap.
    // Since we can't yet compile struct construction or case expressions through
    // ZIR reliably, we use a bridge approach: the zap CLI directly parses
    // build.zap's AST to extract manifest data statically.
    _ = builder_module;
    _ = alloc;

    // TODO: When Zap can compile struct construction, case expressions, and
    // field access through ZIR, generate a real wrapper main here.
    // For now, return empty — the bridge in main.zig handles it.
    return "";
}

/// Parse the builder's stdout output into a BuildConfig.
/// Format: key=value lines, one per field.
/// paths are repeated: paths=lib\npaths=test
/// build_opts are prefixed: build_opts.key=value
pub fn parseManifestOutput(
    alloc: std.mem.Allocator,
    output: []const u8,
) !BuildConfig {
    var config = BuildConfig{
        .name = "",
        .version = "",
        .kind = .bin,
    };

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq_idx];
        const value = line[eq_idx + 1 ..];

        if (std.mem.eql(u8, key, "name")) {
            config.name = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "version")) {
            config.version = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "kind")) {
            if (std.mem.eql(u8, value, "bin")) {
                config.kind = .bin;
            } else if (std.mem.eql(u8, value, "lib")) {
                config.kind = .lib;
            } else if (std.mem.eql(u8, value, "obj")) {
                config.kind = .obj;
            }
        } else if (std.mem.eql(u8, key, "root")) {
            config.root = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "asset_name")) {
            config.asset_name = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "paths")) {
            try paths.append(alloc, try alloc.dupe(u8, value));
        } else if (std.mem.startsWith(u8, key, "build_opts.")) {
            const opt_key = key["build_opts.".len..];
            try config.build_opts.put(alloc, try alloc.dupe(u8, opt_key), try alloc.dupe(u8, value));
        }
    }

    config.paths = try paths.toOwnedSlice(alloc);
    return config;
}

/// Extract a BuildConfig directly from the build.zap AST.
/// This is the bridge for v1 — it statically extracts the manifest for the
/// requested target by pattern-matching the AST, without compiling and
/// executing the builder.
pub fn extractManifestFromAST(
    alloc: std.mem.Allocator,
    build_source: []const u8,
    target_name: []const u8,
) !BuildConfig {
    // Parse build.zap WITHOUT stdlib prepend — we're extracting data from
    // the AST, not compiling. Stdlib types like Zap.Env and Zap.Manifest
    // are recognized structurally, not by import.
    var parser = zap.Parser.init(alloc, build_source);
    defer parser.deinit();

    const program = parser.parseProgram() catch {
        // Show parse errors
        const stderr = std.fs.File.stderr().deprecatedWriter();
        for (parser.errors.items) |parse_err| {
            stderr.print("  parse error: {s}\n", .{parse_err.message}) catch {};
        }
        return error.ParseFailed;
    };

    // Find the manifest/1 function
    for (program.modules) |mod| {
        for (mod.items) |item| {
            switch (item) {
                .function => |func| {
                    const name = parser.interner.get(func.name);
                    if (std.mem.eql(u8, name, "manifest") and func.clauses.len > 0 and func.clauses[0].params.len == 1) {
                        return extractFromManifestBody(alloc, &parser.interner, func, target_name);
                    }
                },
                else => {},
            }
        }
    }

    return error.ManifestNotFound;
}

const StdlibError = error{StdlibError};
const ParseError = error{ParseFailed};
const ManifestError = error{ManifestNotFound};

fn extractFromManifestBody(
    alloc: std.mem.Allocator,
    interner: *const zap.ast.StringInterner,
    func: *const zap.ast.FunctionDecl,
    target_name: []const u8,
) !BuildConfig {
    // Walk all function clauses looking for:
    // 1. Case expressions on env.target with matching clause
    // 2. Direct struct returns (no case — always returns the same manifest)
    for (func.clauses) |clause| {
        for (clause.body) |stmt| {
            switch (stmt) {
                .expr => |expr| {
                    if (extractFromExpr(alloc, interner, expr, target_name)) |config| {
                        return config;
                    }
                    if (extractManifestFromStructExpr(alloc, interner, expr)) |config| {
                        return config;
                    }
                },
                else => {},
            }
        }
    }

    // Target not found in any case clause
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.print("Error: target '{s}' not found in build.zap manifest/1\n", .{target_name}) catch {};
    return error.ManifestNotFound;
}

fn extractFromExpr(
    alloc: std.mem.Allocator,
    interner: *const zap.ast.StringInterner,
    expr: *const zap.ast.Expr,
    target_name: []const u8,
) ?BuildConfig {
    switch (expr.*) {
        .case_expr => |ce| {
            // Walk case clauses looking for one whose pattern matches target_name
            for (ce.clauses) |clause| {
                if (clauseMatchesTarget(interner, clause, target_name)) {
                    // Extract the manifest struct from this clause's body
                    for (clause.body) |stmt| {
                        switch (stmt) {
                            .expr => |body_expr| {
                                if (extractManifestFromStructExpr(alloc, interner, body_expr)) |config| {
                                    return config;
                                }
                            },
                            else => {},
                        }
                    }
                }
            }
        },
        .block => |blk| {
            for (blk.stmts) |stmt| {
                switch (stmt) {
                    .expr => |e| {
                        if (extractFromExpr(alloc, interner, e, target_name)) |config| {
                            return config;
                        }
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
    return null;
}

fn clauseMatchesTarget(
    interner: *const zap.ast.StringInterner,
    clause: zap.ast.CaseClause,
    target_name: []const u8,
) bool {
    // Check if the clause's pattern is an atom literal matching target_name
    switch (clause.pattern.*) {
        .literal => |lit| {
            switch (lit) {
                .atom => |al| {
                    const atom_name = interner.get(al.value);
                    return std.mem.eql(u8, atom_name, target_name);
                },
                else => return false,
            }
        },
        .wildcard => return false,
        else => return false,
    }
}

fn extractManifestFromStructExpr(
    alloc: std.mem.Allocator,
    interner: *const zap.ast.StringInterner,
    expr: *const zap.ast.Expr,
) ?BuildConfig {
    switch (expr.*) {
        .struct_expr => |se| {
            // Check if this is a %Zap.Manifest{...} or %Manifest{...}
            if (se.module_name.parts.len >= 1) {
                const last = interner.get(se.module_name.parts[se.module_name.parts.len - 1]);
                if (std.mem.eql(u8, last, "Manifest")) {
                    return extractFieldsFromStruct(alloc, interner, se.fields);
                }
            }
        },
        else => {},
    }
    return null;
}

fn extractFieldsFromStruct(
    alloc: std.mem.Allocator,
    interner: *const zap.ast.StringInterner,
    fields: []const zap.ast.StructField,
) ?BuildConfig {
    var config = BuildConfig{
        .name = "",
        .version = "",
        .kind = .bin,
    };
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;

    for (fields) |field| {
        const field_name = interner.get(field.name);

        if (std.mem.eql(u8, field_name, "name")) {
            if (field.value.* == .string_literal) {
                config.name = interner.get(field.value.string_literal.value);
            }
        } else if (std.mem.eql(u8, field_name, "version")) {
            if (field.value.* == .string_literal) {
                config.version = interner.get(field.value.string_literal.value);
            }
        } else if (std.mem.eql(u8, field_name, "kind")) {
            if (field.value.* == .atom_literal) {
                const kind_str = interner.get(field.value.atom_literal.value);
                if (std.mem.eql(u8, kind_str, "bin")) config.kind = .bin
                else if (std.mem.eql(u8, kind_str, "lib")) config.kind = .lib
                else if (std.mem.eql(u8, kind_str, "obj")) config.kind = .obj;
            }
        } else if (std.mem.eql(u8, field_name, "root")) {
            if (field.value.* == .string_literal) {
                config.root = interner.get(field.value.string_literal.value);
            }
        } else if (std.mem.eql(u8, field_name, "asset_name")) {
            if (field.value.* == .string_literal) {
                config.asset_name = interner.get(field.value.string_literal.value);
            }
        } else if (std.mem.eql(u8, field_name, "paths")) {
            if (field.value.* == .list) {
                for (field.value.list.elements) |elem| {
                    if (elem.* == .string_literal) {
                        paths.append(alloc, interner.get(elem.string_literal.value)) catch continue;
                    }
                }
            }
        }
    }

    config.paths = paths.toOwnedSlice(alloc) catch return null;
    return config;
}
