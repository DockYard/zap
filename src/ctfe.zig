//! Compile-Time Function Execution (CTFE)
//!
//! A typed IR interpreter that executes Zap IR at compile time.
//! Uses a recursive tree-walker over structured IR (not flat CFG).
//!
//! Two value layers:
//!   - CtValue: interpreter-internal values during execution
//!   - ConstValue: stable compiler-facing results exported from CTFE

const std = @import("std");
const ir = @import("ir.zig");
const ast = @import("ast.zig");

// ============================================================
// Symbolic Memory Model
//
// Aggregates created during CTFE are tracked via AllocId to preserve
// a clear separation between interpreter memory and host memory.
// Values are stored by-value (no pointer indirection) but each
// allocation is registered for provenance tracking.
// ============================================================

pub const AllocId = u32;

pub const AllocationRecord = struct {
    id: AllocId,
    kind: AllocKind,
    /// Source location (function + instruction) that created this allocation
    source_function: ?ir.FunctionId = null,
};

pub const AllocKind = enum {
    tuple,
    list,
    map,
    struct_val,
    union_val,
    closure,
    string_concat,
};

pub const AllocationStore = struct {
    next_id: AllocId = 1,
    records: std.ArrayListUnmanaged(AllocationRecord) = .empty,

    pub fn alloc(self: *AllocationStore, allocator: std.mem.Allocator, kind: AllocKind, source_fn: ?ir.FunctionId) AllocId {
        const id = self.next_id;
        self.next_id += 1;
        self.records.append(allocator, .{
            .id = id,
            .kind = kind,
            .source_function = source_fn,
        }) catch {};
        return id;
    }

    pub fn deinit(self: *AllocationStore, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
    }

    pub fn count(self: *const AllocationStore) u32 {
        return self.next_id - 1;
    }
};

// ============================================================
// CtValue — interpreter-internal value type
// ============================================================

pub const CtValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
    atom: []const u8,
    nil,
    void,
    consumed,
    reuse_token: CtReuseToken,
    tuple: CtTupleValue,
    list: CtListValue,
    map: CtMapValue,
    struct_val: CtStructValue,
    union_val: CtUnionValue,
    enum_val: CtEnumValue,
    optional: CtOptional,
    closure: CtClosureValue,

    pub const CtMapEntry = struct {
        key: CtValue,
        value: CtValue,
    };

    pub const CtTupleValue = struct {
        alloc_id: AllocId,
        elems: []const CtValue,
    };

    pub const CtListValue = struct {
        alloc_id: AllocId,
        elems: []const CtValue,
    };

    pub const CtMapValue = struct {
        alloc_id: AllocId,
        entries: []const CtMapEntry,
    };

    pub const CtReuseToken = struct {
        alloc_id: AllocId,
        kind: AllocKind,
    };

    pub const CtStructValue = struct {
        alloc_id: AllocId,
        type_name: []const u8,
        fields: []const CtFieldValue,
    };

    pub const CtFieldValue = struct {
        name: []const u8,
        value: CtValue,
    };

    pub const CtUnionValue = struct {
        alloc_id: AllocId,
        type_name: []const u8,
        variant: []const u8,
        payload: *const CtValue,
    };

    pub const CtEnumValue = struct {
        type_name: []const u8,
        variant: []const u8,
    };

    pub const CtOptional = struct {
        value: ?*const CtValue,
    };

    pub const CtClosureValue = struct {
        alloc_id: AllocId,
        function_id: ir.FunctionId,
        captures: []const CtValue,
    };

    /// Evaluate truthiness for condition checks.
    pub fn isTruthy(self: CtValue) bool {
        return switch (self) {
            .bool_val => |b| b,
            .nil => false,
            .void => false,
            .consumed => false,
            .reuse_token => false,
            .int => |i| i != 0,
            .optional => |o| o.value != null,
            else => true,
        };
    }

    /// Value equality for matching and comparisons.
    pub fn eql(self: CtValue, other: CtValue) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return false;

        return switch (self) {
            .int => |a| a == other.int,
            .float => |a| a == other.float,
            .string => |a| std.mem.eql(u8, a, other.string),
            .bool_val => |a| a == other.bool_val,
            .atom => |a| std.mem.eql(u8, a, other.atom),
            .nil => true,
            .void => true,
            .consumed => true,
            .reuse_token => |a| {
                const b = other.reuse_token;
                return a.alloc_id == b.alloc_id and a.kind == b.kind;
            },
            .tuple => |a| {
                const b = other.tuple;
                if (a.elems.len != b.elems.len) return false;
                for (a.elems, b.elems) |av, bv| {
                    if (!av.eql(bv)) return false;
                }
                return true;
            },
            .list => |a| {
                const b = other.list;
                if (a.elems.len != b.elems.len) return false;
                for (a.elems, b.elems) |av, bv| {
                    if (!av.eql(bv)) return false;
                }
                return true;
            },
            .map => |a| {
                const b = other.map;
                if (a.entries.len != b.entries.len) return false;
                for (a.entries) |entry_a| {
                    var found = false;
                    for (b.entries) |entry_b| {
                        if (entry_a.key.eql(entry_b.key) and entry_a.value.eql(entry_b.value)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                }
                return true;
            },
            .struct_val => |a| {
                const b = other.struct_val;
                if (!std.mem.eql(u8, a.type_name, b.type_name)) return false;
                if (a.fields.len != b.fields.len) return false;
                for (a.fields) |fa| {
                    var found = false;
                    for (b.fields) |fb| {
                        if (std.mem.eql(u8, fa.name, fb.name) and fa.value.eql(fb.value)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                }
                return true;
            },
            .enum_val => |a| {
                const b = other.enum_val;
                return std.mem.eql(u8, a.type_name, b.type_name) and
                    std.mem.eql(u8, a.variant, b.variant);
            },
            .union_val => |a| {
                const b = other.union_val;
                return std.mem.eql(u8, a.type_name, b.type_name) and
                    std.mem.eql(u8, a.variant, b.variant) and
                    a.payload.eql(b.payload.*);
            },
            .optional => |a| {
                const b = other.optional;
                if (a.value == null and b.value == null) return true;
                if (a.value != null and b.value != null) return a.value.?.eql(b.value.?.*);
                return false;
            },
            .closure => false, // closures are never equal
        };
    }

    /// Compare for ordering (lt/gt/lte/gte). Returns null if incomparable.
    pub fn compare(self: CtValue, other: CtValue) ?std.math.Order {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return null;

        return switch (self) {
            .int => |a| std.math.order(a, other.int),
            .float => |a| std.math.order(a, other.float),
            .string => |a| std.mem.order(u8, a, other.string),
            .atom => |a| std.mem.order(u8, a, other.atom),
            else => null,
        };
    }

    /// Hash a CtValue for memoization cache keys.
    pub fn hash(self: CtValue) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hashInto(&hasher);
        return hasher.final();
    }

    fn hashInto(self: CtValue, hasher: *std.hash.Wyhash) void {
        // Hash the tag discriminant
        const tag_byte = [_]u8{@intFromEnum(std.meta.activeTag(self))};
        hasher.update(&tag_byte);
        switch (self) {
            .int => |v| hasher.update(std.mem.asBytes(&v)),
            .float => |v| hasher.update(std.mem.asBytes(&v)),
            .string => |v| hasher.update(v),
            .bool_val => |v| hasher.update(&[_]u8{@intFromBool(v)}),
            .atom => |v| hasher.update(v),
            .nil, .void, .consumed => {},
            .reuse_token => |rt| {
                hasher.update(std.mem.asBytes(&rt.alloc_id));
                hasher.update(&[_]u8{@intFromEnum(rt.kind)});
            },
            .tuple => |tv| for (tv.elems) |e| e.hashInto(hasher),
            .list => |lv| for (lv.elems) |e| e.hashInto(hasher),
            .map => |mv| for (mv.entries) |entry| {
                entry.key.hashInto(hasher);
                entry.value.hashInto(hasher);
            },
            .struct_val => |sv| {
                hasher.update(sv.type_name);
                for (sv.fields) |f| {
                    hasher.update(f.name);
                    f.value.hashInto(hasher);
                }
            },
            .union_val => |uv| {
                hasher.update(uv.type_name);
                hasher.update(uv.variant);
                uv.payload.hashInto(hasher);
            },
            .enum_val => |ev| {
                hasher.update(ev.type_name);
                hasher.update(ev.variant);
            },
            .optional => |o| {
                if (o.value) |v| v.hashInto(hasher);
            },
            .closure => |cl| {
                hasher.update(std.mem.asBytes(&cl.function_id));
                for (cl.captures) |c| c.hashInto(hasher);
            },
        }
    }
};

// ============================================================
// ConstValue — compiler-facing stable export
// ============================================================

pub const ConstValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
    atom: []const u8,
    nil,
    void,
    tuple: []const ConstValue,
    list: []const ConstValue,
    map: []const ConstMapEntry,
    struct_val: ConstStructValue,

    pub const ConstMapEntry = struct {
        key: ConstValue,
        value: ConstValue,
    };

    pub const ConstStructValue = struct {
        type_name: []const u8,
        fields: []const ConstFieldValue,
    };

    pub const ConstFieldValue = struct {
        name: []const u8,
        value: ConstValue,
    };
};

/// Convert a CtValue (interpreter-internal) to a ConstValue (compiler-facing).
/// Deep-copies all data. Closures and union values cannot be exported.
pub fn exportValue(alloc: std.mem.Allocator, val: CtValue) ExportError!ConstValue {
    return switch (val) {
        .int => |v| .{ .int = v },
        .float => |v| .{ .float = v },
        .string => |v| .{ .string = try alloc.dupe(u8, v) },
        .bool_val => |v| .{ .bool_val = v },
        .atom => |v| .{ .atom = try alloc.dupe(u8, v) },
        .nil => .nil,
        .void => .void,
        .consumed => error.CannotExport,
        .reuse_token => error.CannotExport,
        .tuple => |tv| {
            const exported = try alloc.alloc(ConstValue, tv.elems.len);
            for (tv.elems, 0..) |elem, i| {
                exported[i] = try exportValue(alloc, elem);
            }
            return .{ .tuple = exported };
        },
        .list => |lv| {
            const exported = try alloc.alloc(ConstValue, lv.elems.len);
            for (lv.elems, 0..) |elem, i| {
                exported[i] = try exportValue(alloc, elem);
            }
            return .{ .list = exported };
        },
        .map => |mv| {
            const exported = try alloc.alloc(ConstValue.ConstMapEntry, mv.entries.len);
            for (mv.entries, 0..) |entry, i| {
                exported[i] = .{
                    .key = try exportValue(alloc, entry.key),
                    .value = try exportValue(alloc, entry.value),
                };
            }
            return .{ .map = exported };
        },
        .struct_val => |sv| {
            const exported_fields = try alloc.alloc(ConstValue.ConstFieldValue, sv.fields.len);
            for (sv.fields, 0..) |field, i| {
                exported_fields[i] = .{
                    .name = try alloc.dupe(u8, field.name),
                    .value = try exportValue(alloc, field.value),
                };
            }
            return .{ .struct_val = .{
                .type_name = try alloc.dupe(u8, sv.type_name),
                .fields = exported_fields,
            } };
        },
        .enum_val => |ev| .{ .atom = try alloc.dupe(u8, ev.variant) },
        .optional => |o| {
            if (o.value) |v| return exportValue(alloc, v.*);
            return .nil;
        },
        .union_val => error.CannotExport,
        .closure => error.CannotExport,
    };
}

pub const ExportError = error{
    CannotExport,
    OutOfMemory,
};

// ============================================================
// Capabilities
// ============================================================

pub const Capability = enum(u3) {
    pure = 0,
    read_file = 1,
    read_env = 2,
    reflect_module = 3,
};

pub const CapabilitySet = struct {
    flags: u8 = 0,

    pub fn has(self: CapabilitySet, cap: Capability) bool {
        return (self.flags & (@as(u8, 1) << @intFromEnum(cap))) != 0;
    }

    pub fn with(self: CapabilitySet, cap: Capability) CapabilitySet {
        return .{ .flags = self.flags | (@as(u8, 1) << @intFromEnum(cap)) };
    }

    pub const pure_only = CapabilitySet{};
    pub const build = CapabilitySet{ .flags = 0b1111 }; // pure + read_file + read_env + reflect_module
};

// ============================================================
// Dependencies
// ============================================================

pub const CtDependency = union(enum) {
    file: struct {
        path: []const u8,
        content_hash: u64,
    },
    env_var: struct {
        name: []const u8,
        value_hash: u64,
        present: bool,
    },
    reflected_module: struct {
        module_name: []const u8,
        interface_hash: u64,
    },
};

pub const CtEvalResult = struct {
    value: ConstValue,
    dependencies: []const CtDependency,
    result_hash: u64,
};

fn cloneDependency(alloc: std.mem.Allocator, dep: CtDependency) !CtDependency {
    return switch (dep) {
        .file => |f| .{ .file = .{
            .path = try alloc.dupe(u8, f.path),
            .content_hash = f.content_hash,
        } },
        .env_var => |ev| .{ .env_var = .{
            .name = try alloc.dupe(u8, ev.name),
            .value_hash = ev.value_hash,
            .present = ev.present,
        } },
        .reflected_module => |rm| .{ .reflected_module = .{
            .module_name = try alloc.dupe(u8, rm.module_name),
            .interface_hash = rm.interface_hash,
        } },
    };
}

fn cloneDependencies(alloc: std.mem.Allocator, deps: []const CtDependency) ![]const CtDependency {
    const cloned = try alloc.alloc(CtDependency, deps.len);
    for (deps, 0..) |dep, i| {
        cloned[i] = try cloneDependency(alloc, dep);
    }
    return cloned;
}

// ============================================================
// Diagnostics
// ============================================================

pub const CtfeErrorKind = enum {
    step_limit_exceeded,
    recursion_limit_exceeded,
    unsupported_instruction,
    type_error,
    use_after_consume,
    division_by_zero,
    capability_violation,
    match_failure,
    undefined_function,
    index_out_of_bounds,
};

pub const CtfeFrame = struct {
    function_name: []const u8,
    function_id: ir.FunctionId,
    instruction_index: usize,
    source_span: ?ast.SourceSpan = null,
};

pub const CtfeError = struct {
    message: []const u8,
    kind: CtfeErrorKind,
    call_stack: []const CtfeFrame,
    /// Optional context: which attribute triggered this evaluation
    attribute_context: ?AttributeContext = null,

    pub const AttributeContext = struct {
        attr_name: []const u8,
        module_name: []const u8,
    };
};

fn cloneCtfeError(alloc: std.mem.Allocator, err: CtfeError) !CtfeError {
    const cloned_stack = try alloc.dupe(CtfeFrame, err.call_stack);
    return .{
        .message = try alloc.dupe(u8, err.message),
        .kind = err.kind,
        .call_stack = cloned_stack,
        .attribute_context = if (err.attribute_context) |ctx| .{
            .attr_name = try alloc.dupe(u8, ctx.attr_name),
            .module_name = try alloc.dupe(u8, ctx.module_name),
        } else null,
    };
}

fn cloneCtfeErrors(alloc: std.mem.Allocator, errors: []const CtfeError) ![]const CtfeError {
    const cloned = try alloc.alloc(CtfeError, errors.len);
    for (errors, 0..) |err, i| {
        cloned[i] = try cloneCtfeError(alloc, err);
    }
    return cloned;
}

/// Format a CTFE error as a rich multi-line diagnostic string.
/// Produces output like:
///   error: compile-time evaluation exceeded step limit
///     while evaluating `Config.generate/0`
///     called from attribute `@config` in `App`
///     help: possible infinite recursion or unexpectedly large compile-time loop
pub fn formatCtfeError(alloc: std.mem.Allocator, err: CtfeError) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(alloc);

    // Main error line
    try w.print("error: {s}\n", .{err.message});

    // Call stack (innermost first)
    if (err.call_stack.len > 0) {
        var i: usize = err.call_stack.len;
        while (i > 0) {
            i -= 1;
            const frame = err.call_stack[i];
            if (i == err.call_stack.len - 1) {
                try w.print("  while evaluating `{s}`", .{frame.function_name});
            } else {
                try w.print("  called from `{s}`", .{frame.function_name});
            }
            if (frame.source_span) |span| {
                if (span.line > 0) {
                    try w.print(" at {d}:{d}", .{ span.line, span.col });
                } else {
                    try w.print(" at span {d}..{d}", .{ span.start, span.end });
                }
            }
            try w.writeByte('\n');
        }
    }

    // Attribute context
    if (err.attribute_context) |ctx| {
        try w.print("  for attribute `@{s}` in `{s}`\n", .{ ctx.attr_name, ctx.module_name });
    }

    // Help text based on error kind
    switch (err.kind) {
        .step_limit_exceeded => try w.writeAll("  help: possible infinite recursion or unexpectedly large compile-time loop\n"),
        .recursion_limit_exceeded => try w.writeAll("  help: recursion depth exceeded — simplify the compile-time computation or increase the limit\n"),
        .capability_violation => try w.print("  help: declare the required capability or remove the compile-time {s}\n", .{
            if (std.mem.indexOf(u8, err.message, "read_file")) |_| "file access" else if (std.mem.indexOf(u8, err.message, "read_env")) |_| "env access" else if (std.mem.indexOf(u8, err.message, "reflect_module")) |_| "reflection" else "effect",
        }),
        .use_after_consume => try w.writeAll("  help: a moved or released value was read again during compile-time evaluation\n"),
        .division_by_zero => try w.writeAll("  help: ensure the divisor is non-zero at compile time\n"),
        .undefined_function => try w.writeAll("  help: the function may not exist or may not be visible at compile time\n"),
        .match_failure => try w.writeAll("  help: no clause matched the compile-time value — add a catch-all clause\n"),
        .type_error => try w.writeAll("  help: compile-time values must have compatible types\n"),
        else => {},
    }

    return buf.toOwnedSlice(alloc);
}

/// Emit all CTFE errors to stderr using the diagnostic format.
pub fn emitCtfeErrors(alloc: std.mem.Allocator, errors: []const CtfeError) void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    for (errors) |err| {
        const formatted = formatCtfeError(alloc, err) catch {
            stderr.print("ctfe error: {s}\n", .{err.message}) catch {};
            continue;
        };
        stderr.writeAll(formatted) catch {};
        alloc.free(formatted);
    }
}

// ============================================================
// Interpreter
// ============================================================

pub const CacheKey = struct {
    function_id: ir.FunctionId,
    function_hash: u64,
    args_hash: u64,
    capability_flags: u8,
    /// Combined hash of target triple + optimize mode + compile options
    options_hash: u64 = 0,
};

/// Schema version for cache invalidation when interpreter semantics change.
pub const CTFE_SCHEMA_VERSION: u32 = 1;

/// Build a complete options hash from compile-relevant settings.
pub fn hashCompileOptions(target: []const u8, optimize: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(target);
    hasher.update(optimize);
    hasher.update(std.mem.asBytes(&CTFE_SCHEMA_VERSION));
    return hasher.final();
}

fn hashBuildOptions(build_opts: std.StringHashMapUnmanaged([]const u8)) u64 {
    var combined: u64 = 0;
    var count: u32 = 0;
    var iter = build_opts.iterator();
    while (iter.next()) |entry| {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(entry.key_ptr.*);
        hasher.update(entry.value_ptr.*);
        combined ^= hasher.final();
        count += 1;
    }

    var final_hasher = std.hash.Wyhash.init(0);
    final_hasher.update(std.mem.asBytes(&combined));
    final_hasher.update(std.mem.asBytes(&count));
    final_hasher.update(std.mem.asBytes(&CTFE_SCHEMA_VERSION));
    return final_hasher.final();
}

fn hashEvaluationOptions(explicit_compile_options_hash: u64, build_opts: std.StringHashMapUnmanaged([]const u8)) u64 {
    const build_opts_hash = hashBuildOptions(build_opts);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&explicit_compile_options_hash));
    hasher.update(std.mem.asBytes(&build_opts_hash));
    hasher.update(std.mem.asBytes(&CTFE_SCHEMA_VERSION));
    return hasher.final();
}

fn hashLocalIds(hasher: *std.hash.Wyhash, locals: []const ir.LocalId) void {
    for (locals) |local_id| hasher.update(std.mem.asBytes(&local_id));
}

fn hashZigType(hasher: *std.hash.Wyhash, ty: ir.ZigType) void {
    const tag = std.meta.activeTag(ty);
    hasher.update(&[_]u8{@intFromEnum(tag)});
    switch (ty) {
        .tuple => |items| for (items) |item| hashZigType(hasher, item),
        .list => |item| hashZigType(hasher, item.*),
        .map => |m| {
            hashZigType(hasher, m.key.*);
            hashZigType(hasher, m.value.*);
        },
        .struct_ref => |name| hasher.update(name),
        .function => |fn_ty| {
            for (fn_ty.params) |param| hashZigType(hasher, param);
            hashZigType(hasher, fn_ty.return_type.*);
        },
        .tagged_union => |name| hasher.update(name),
        .optional => |item| hashZigType(hasher, item.*),
        .ptr => |item| hashZigType(hasher, item.*),
        else => {},
    }
}

fn hashLiteralValueForIr(hasher: *std.hash.Wyhash, value: ir.LiteralValue) void {
    const tag = std.meta.activeTag(value);
    hasher.update(&[_]u8{@intFromEnum(tag)});
    switch (value) {
        .int => |v| hasher.update(std.mem.asBytes(&v)),
        .float => |v| hasher.update(std.mem.asBytes(&v)),
        .bool_val => |v| hasher.update(&[_]u8{@intFromBool(v)}),
        .string => |v| hasher.update(v),
    }
}

fn hashInstruction(hasher: *std.hash.Wyhash, instr: ir.Instruction) void {
    const tag = std.meta.activeTag(instr);
    hasher.update(&[_]u8{@intFromEnum(tag)});
    switch (instr) {
        .const_int => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.value));
            if (v.type_hint) |hint| hashZigType(hasher, hint);
        },
        .const_float => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.value));
            if (v.type_hint) |hint| hashZigType(hasher, hint);
        },
        .const_string => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.value);
        },
        .const_bool => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(&[_]u8{@intFromBool(v.value)});
        },
        .const_atom => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.value);
        },
        .const_nil => |dest| hasher.update(std.mem.asBytes(&dest)),
        .local_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .local_set => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.value));
        },
        .move_value => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .share_value => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .param_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.index));
        },
        .tuple_init, .list_init => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hashLocalIds(hasher, v.elements);
        },
        .list_cons => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.head));
            hasher.update(std.mem.asBytes(&v.tail));
        },
        .map_init => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            for (v.entries) |entry| {
                hasher.update(std.mem.asBytes(&entry.key));
                hasher.update(std.mem.asBytes(&entry.value));
            }
        },
        .struct_init => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.type_name);
            for (v.fields) |field| {
                hasher.update(field.name);
                hasher.update(std.mem.asBytes(&field.value));
            }
        },
        .union_init => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.union_type);
            hasher.update(v.variant_name);
            hasher.update(std.mem.asBytes(&v.value));
        },
        .enum_literal => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.type_name);
            hasher.update(v.variant);
        },
        .field_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.object));
            hasher.update(v.field);
        },
        .field_set => |v| {
            hasher.update(std.mem.asBytes(&v.object));
            hasher.update(v.field);
            hasher.update(std.mem.asBytes(&v.value));
        },
        .index_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.object));
            hasher.update(std.mem.asBytes(&v.index));
        },
        .list_len_check => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(std.mem.asBytes(&v.expected_len));
        },
        .list_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.list));
            hasher.update(std.mem.asBytes(&v.index));
        },
        .list_is_not_empty => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.list));
        },
        .list_head, .list_tail => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.list));
        },
        .map_has_key => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.map));
            hasher.update(std.mem.asBytes(&v.key));
        },
        .map_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.map));
            hasher.update(std.mem.asBytes(&v.key));
            hasher.update(std.mem.asBytes(&v.default));
        },
        .binary_op => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(&[_]u8{@intFromEnum(v.op)});
            hasher.update(std.mem.asBytes(&v.lhs));
            hasher.update(std.mem.asBytes(&v.rhs));
        },
        .unary_op => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(&[_]u8{@intFromEnum(v.op)});
            hasher.update(std.mem.asBytes(&v.operand));
        },
        .call_direct => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.function));
            hashLocalIds(hasher, v.args);
        },
        .call_named => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.name);
            hashLocalIds(hasher, v.args);
            for (v.arg_modes) |mode| hasher.update(&[_]u8{@intFromEnum(mode)});
        },
        .try_call_named => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.name);
            hashLocalIds(hasher, v.args);
            for (v.arg_modes) |mode| hasher.update(&[_]u8{@intFromEnum(mode)});
        },
        .call_closure => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.callee));
            hashLocalIds(hasher, v.args);
            for (v.arg_modes) |mode| hasher.update(&[_]u8{@intFromEnum(mode)});
        },
        .call_dispatch => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.group_id));
            hashLocalIds(hasher, v.args);
        },
        .call_builtin => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.name);
            hashLocalIds(hasher, v.args);
            for (v.arg_modes) |mode| hasher.update(&[_]u8{@intFromEnum(mode)});
        },
        .tail_call => |v| {
            hasher.update(v.name);
            hashLocalIds(hasher, v.args);
        },
        .error_catch => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            hasher.update(std.mem.asBytes(&v.catch_value));
        },
        .if_expr => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.condition));
            for (v.then_instrs) |nested| hashInstruction(hasher, nested);
            if (v.then_result) |res| hasher.update(std.mem.asBytes(&res));
            for (v.else_instrs) |nested| hashInstruction(hasher, nested);
            if (v.else_result) |res| hasher.update(std.mem.asBytes(&res));
        },
        .guard_block => |v| {
            hasher.update(std.mem.asBytes(&v.condition));
            for (v.body) |nested| hashInstruction(hasher, nested);
        },
        .case_block => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            for (v.pre_instrs) |nested| hashInstruction(hasher, nested);
            for (v.arms) |arm| {
                hasher.update(std.mem.asBytes(&arm.condition));
                for (arm.cond_instrs) |nested| hashInstruction(hasher, nested);
                for (arm.body_instrs) |nested| hashInstruction(hasher, nested);
                if (arm.result) |res| hasher.update(std.mem.asBytes(&res));
            }
            for (v.default_instrs) |nested| hashInstruction(hasher, nested);
            if (v.default_result) |res| hasher.update(std.mem.asBytes(&res));
        },
        .branch => |v| hasher.update(std.mem.asBytes(&v.target)),
        .cond_branch => |v| {
            hasher.update(std.mem.asBytes(&v.condition));
            hasher.update(std.mem.asBytes(&v.then_target));
            hasher.update(std.mem.asBytes(&v.else_target));
        },
        .switch_tag => |v| {
            hasher.update(std.mem.asBytes(&v.scrutinee));
            for (v.cases) |case| {
                hasher.update(case.tag);
                hasher.update(std.mem.asBytes(&case.target));
            }
            hasher.update(std.mem.asBytes(&v.default));
        },
        .switch_literal => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            for (v.cases) |case| {
                hashLiteralValueForIr(hasher, case.value);
                for (case.body_instrs) |nested| hashInstruction(hasher, nested);
                if (case.result) |res| hasher.update(std.mem.asBytes(&res));
            }
            for (v.default_instrs) |nested| hashInstruction(hasher, nested);
            if (v.default_result) |res| hasher.update(std.mem.asBytes(&res));
        },
        .switch_return => |v| {
            hasher.update(std.mem.asBytes(&v.scrutinee_param));
            for (v.cases) |case| {
                hashLiteralValueForIr(hasher, case.value);
                for (case.body_instrs) |nested| hashInstruction(hasher, nested);
                if (case.return_value) |rv| hasher.update(std.mem.asBytes(&rv));
            }
            for (v.default_instrs) |nested| hashInstruction(hasher, nested);
            if (v.default_result) |dr| hasher.update(std.mem.asBytes(&dr));
        },
        .union_switch_return => |v| {
            hasher.update(std.mem.asBytes(&v.scrutinee_param));
            for (v.cases) |case| {
                hasher.update(case.variant_name);
                for (case.field_bindings) |binding| {
                    hasher.update(binding.field_name);
                    hasher.update(std.mem.asBytes(&binding.local_index));
                }
                for (case.body_instrs) |nested| hashInstruction(hasher, nested);
                if (case.return_value) |rv| hasher.update(std.mem.asBytes(&rv));
            }
        },
        .union_switch => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            for (v.cases) |case| {
                hasher.update(case.variant_name);
                for (case.field_bindings) |binding| {
                    hasher.update(binding.field_name);
                    hasher.update(std.mem.asBytes(&binding.local_index));
                }
                for (case.body_instrs) |nested| hashInstruction(hasher, nested);
                if (case.return_value) |rv| hasher.update(std.mem.asBytes(&rv));
            }
        },
        .match_atom => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(v.atom_name);
        },
        .match_int => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(std.mem.asBytes(&v.value));
        },
        .match_float => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(std.mem.asBytes(&v.value));
        },
        .match_string => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(v.expected);
        },
        .match_type => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hashZigType(hasher, v.expected_type);
        },
        .match_fail, .match_error_return => {},
        .ret => |v| if (v.value) |value| hasher.update(std.mem.asBytes(&value)),
        .cond_return => |v| {
            hasher.update(std.mem.asBytes(&v.condition));
            if (v.value) |value| hasher.update(std.mem.asBytes(&value));
        },
        .case_break => |v| if (v.value) |value| hasher.update(std.mem.asBytes(&value)),
        .jump => |v| {
            hasher.update(std.mem.asBytes(&v.target));
            if (v.bind_dest) |dest| hasher.update(std.mem.asBytes(&dest));
            if (v.value) |value| hasher.update(std.mem.asBytes(&value));
        },
        .make_closure => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.function));
            hashLocalIds(hasher, v.captures);
        },
        .capture_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.index));
        },
        .optional_unwrap => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .bin_len_check => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(std.mem.asBytes(&v.min_len));
        },
        .bin_read_int => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            hasher.update(std.mem.asBytes(&v.bits));
            hasher.update(&[_]u8{@intFromEnum(v.endianness)});
            hasher.update(&[_]u8{@intFromBool(v.signed)});
        },
        .bin_read_float => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            hasher.update(std.mem.asBytes(&v.bits));
            hasher.update(&[_]u8{@intFromEnum(v.endianness)});
        },
        .bin_slice => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            if (v.length) |len| switch (len) {
                .static => |s| hasher.update(std.mem.asBytes(&s)),
                .dynamic => |d| hasher.update(std.mem.asBytes(&d)),
            };
        },
        .bin_read_utf8 => |v| {
            hasher.update(std.mem.asBytes(&v.dest_codepoint));
            hasher.update(std.mem.asBytes(&v.dest_len));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .bin_match_prefix => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            hasher.update(v.expected);
        },
        .retain => |v| hasher.update(std.mem.asBytes(&v.value)),
        .release => |v| hasher.update(std.mem.asBytes(&v.value)),
        .reset => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .reuse_alloc => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            if (v.token) |t| hasher.update(std.mem.asBytes(&t));
            hasher.update(std.mem.asBytes(&v.constructor_tag));
            hashZigType(hasher, v.dest_type);
        },
        .int_widen, .float_widen => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            hashZigType(hasher, v.dest_type);
        },
        .phi => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            for (v.sources) |src| {
                hasher.update(std.mem.asBytes(&src.from_block));
                hasher.update(std.mem.asBytes(&src.value));
            }
        },
    }
}

fn hashFunctionIdentity(func: *const ir.Function) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(func.name);
    hasher.update(std.mem.asBytes(&func.arity));
    hashZigType(&hasher, func.return_type);
    hasher.update(std.mem.asBytes(&func.local_count));
    hasher.update(&[_]u8{@intFromBool(func.is_closure)});
    for (func.params) |param| {
        hasher.update(param.name);
        hashZigType(&hasher, param.type_expr);
    }
    for (func.captures) |capture| {
        hasher.update(capture.name);
        hashZigType(&hasher, capture.type_expr);
        hasher.update(&[_]u8{@intFromEnum(capture.ownership)});
    }
    for (func.body) |block| {
        hasher.update(std.mem.asBytes(&block.label));
        for (block.instructions) |instr| hashInstruction(&hasher, instr);
    }
    return hasher.final();
}

pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    function_by_name: std.StringHashMapUnmanaged(ir.FunctionId),
    step_budget: u64,
    steps_remaining: u64,
    recursion_limit: u32,
    allocation_store: AllocationStore,
    persistent_cache: ?PersistentCache = null,
    capabilities: CapabilitySet,
    dependencies: std.ArrayListUnmanaged(CtDependency),
    call_stack: std.ArrayListUnmanaged(CtfeFrame),
    errors: std.ArrayListUnmanaged(CtfeError),
    memo_cache: std.AutoHashMapUnmanaged(CacheKey, CtValue),
    scope_graph: ?*const scope.ScopeGraph,
    interner: ?*const ast.StringInterner,
    build_opts: std.StringHashMapUnmanaged([]const u8) = .empty,
    compile_options_hash: u64 = 0,
    current_attribute_context: ?CtfeError.AttributeContext = null,

    pub fn init(
        allocator: std.mem.Allocator,
        program: *const ir.Program,
    ) Interpreter {
        var interp = Interpreter{
            .allocator = allocator,
            .program = program,
            .function_by_name = .empty,
            .step_budget = 1_000_000,
            .steps_remaining = 1_000_000,
            .recursion_limit = 256,
            .capabilities = CapabilitySet.pure_only,
            .dependencies = .empty,
            .call_stack = .empty,
            .errors = .empty,
            .memo_cache = .empty,
            .allocation_store = .{},
            .scope_graph = null,
            .interner = null,
            .current_attribute_context = null,
        };
        // Build name -> id index
        for (program.functions, 0..) |func, i| {
            interp.function_by_name.put(allocator, func.name, @intCast(i)) catch {};
        }
        return interp;
    }

    pub fn deinit(self: *Interpreter) void {
        self.function_by_name.deinit(self.allocator);
        self.dependencies.deinit(self.allocator);
        self.call_stack.deinit(self.allocator);
        for (self.errors.items) |err| {
            if (err.attribute_context) |ctx| {
                self.allocator.free(ctx.attr_name);
                self.allocator.free(ctx.module_name);
            }
        }
        self.errors.deinit(self.allocator);
        self.memo_cache.deinit(self.allocator);
        self.allocation_store.deinit(self.allocator);
    }

    /// Evaluate a function by ID with given arguments.
    pub fn evalFunction(
        self: *Interpreter,
        function_id: ir.FunctionId,
        args: []const CtValue,
    ) CtfeInterpretError!CtValue {
        if (self.call_stack.items.len >= self.recursion_limit) {
            try self.emitError(.recursion_limit_exceeded, "recursion limit exceeded");
            return error.CtfeFailure;
        }

        if (function_id >= self.program.functions.len) {
            try self.emitError(.undefined_function, "invalid function id");
            return error.CtfeFailure;
        }

        const func = &self.program.functions[function_id];

        // Memoization: check in-process cache
        const cache_key = CacheKey{
            .function_id = function_id,
            .function_hash = hashFunctionIdentity(func),
            .args_hash = hashArgs(args),
            .capability_flags = self.capabilities.flags,
            .options_hash = hashEvaluationOptions(self.compile_options_hash, self.build_opts),
        };
        if (self.memo_cache.get(cache_key)) |cached| {
            return cached;
        }

        // Persistent cache: check disk cache (top-level calls only)
        if (self.persistent_cache) |*pc| {
            if (self.call_stack.items.len == 0) {
                const pk = PersistentCache.cacheKeyFor(
                    self.program.functions[function_id].name,
                    cache_key.function_hash,
                    cache_key.args_hash,
                    cache_key.capability_flags,
                    cache_key.options_hash,
                );
                if (pc.load(self.allocator, pk)) |cached_result| {
                    if (PersistentCache.validateDependencies(self.allocator, cached_result.dependencies, self.scope_graph, self.interner)) {
                        const imported = importConstValue(cached_result.value);
                        self.memo_cache.put(self.allocator, cache_key, imported) catch {};
                        return imported;
                    }
                }
            }
        }

        var frame = Frame.init(self.allocator, func, args) catch return error.OutOfMemory;
        defer frame.deinit(self.allocator);

        try self.call_stack.append(self.allocator, .{
            .function_name = func.name,
            .function_id = function_id,
            .instruction_index = 0,
            .source_span = self.resolveFunctionSourceSpan(func),
        });
        defer _ = self.call_stack.pop();

        if (func.body.len == 0) return .void;
        const result = try self.execFunctionBlocks(func, &frame);

        // Store in memo cache
        self.memo_cache.put(self.allocator, cache_key, result) catch {};

        // Store in persistent cache (top-level calls only)
        if (self.persistent_cache) |*pc| {
            if (self.call_stack.items.len == 0) {
                const exported = exportValue(self.allocator, result) catch null;
                if (exported) |ev| {
                    const pk = PersistentCache.cacheKeyFor(
                        func.name,
                        cache_key.function_hash,
                        cache_key.args_hash,
                        cache_key.capability_flags,
                        cache_key.options_hash,
                    );
                    pc.store(self.allocator, pk, .{
                        .value = ev,
                        .dependencies = self.dependencies.items,
                        .result_hash = hashConstValue(ev),
                    });
                }
            }
        }

        return result;
    }

    /// Evaluate a function by name.
    pub fn evalByName(
        self: *Interpreter,
        name: []const u8,
        args: []const CtValue,
    ) CtfeInterpretError!CtValue {
        const func_id = self.function_by_name.get(name) orelse {
            try self.emitError(.undefined_function, name);
            return error.CtfeFailure;
        };
        return self.evalFunction(func_id, args);
    }

    /// Evaluate and export: accepts ConstValue args, returns CtEvalResult.
    /// This is the production API for CTFE evaluation.
    pub fn evalAndExport(
        self: *Interpreter,
        function_id: ir.FunctionId,
        args: []const ConstValue,
        caps: CapabilitySet,
    ) CtfeInterpretError!CtEvalResult {
        self.capabilities = caps;
        self.dependencies = .empty;
        self.steps_remaining = self.step_budget;

        // Import ConstValue args to CtValue
        const ct_args = self.allocator.alloc(CtValue, args.len) catch return error.OutOfMemory;
        for (args, 0..) |arg, i| {
            ct_args[i] = importConstValue(arg);
        }

        const result = try self.evalFunction(function_id, ct_args);
        const exported = exportValue(self.allocator, result) catch return error.CtfeFailure;
        const dependencies = cloneDependencies(self.allocator, self.dependencies.items) catch return error.OutOfMemory;

        return .{
            .value = exported,
            .dependencies = dependencies,
            .result_hash = hashConstValue(exported),
        };
    }

    fn hashConstValue(val: ConstValue) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hashConstValueInto(&hasher, val);
        return hasher.final();
    }

    fn hashConstValueInto(hasher: *std.hash.Wyhash, val: ConstValue) void {
        switch (val) {
            .int => |v| hasher.update(std.mem.asBytes(&v)),
            .float => |v| hasher.update(std.mem.asBytes(&v)),
            .string => |v| hasher.update(v),
            .bool_val => |v| hasher.update(&[_]u8{@intFromBool(v)}),
            .atom => |v| hasher.update(v),
            .nil, .void => {},
            .tuple => |elems| for (elems) |e| hashConstValueInto(hasher, e),
            .list => |elems| for (elems) |e| hashConstValueInto(hasher, e),
            .map => |entries| for (entries) |entry| {
                hashConstValueInto(hasher, entry.key);
                hashConstValueInto(hasher, entry.value);
            },
            .struct_val => |sv| {
                hasher.update(sv.type_name);
                for (sv.fields) |f| {
                    hasher.update(f.name);
                    hashConstValueInto(hasher, f.value);
                }
            },
        }
    }

    /// Execute a sequence of instructions. Returns the result value.
    fn execInstructions(
        self: *Interpreter,
        instrs: []const ir.Instruction,
        frame: *Frame,
    ) CtfeInterpretError!CtValue {
        return self.execInstructionsFrom(instrs, frame, 0);
    }

    fn execInstructionsFrom(
        self: *Interpreter,
        instrs: []const ir.Instruction,
        frame: *Frame,
        start_index: usize,
    ) CtfeInterpretError!CtValue {
        for (instrs[start_index..], start_index..) |instr, idx| {
            if (self.steps_remaining == 0) {
                try self.emitError(.step_limit_exceeded, "step limit exceeded");
                return error.CtfeFailure;
            }
            self.steps_remaining -= 1;
            self.setCurrentInstructionIndex(idx);

            const result = try self.execOneInstruction(instr, frame);
            switch (result) {
                .continued => continue,
                .returned => |val| return val,
                .broke => |val| return val orelse .void,
                .jumped => |target| {
                    frame.predecessor_block_label = frame.current_block_label;
                    frame.current_block_label = target;
                    return try self.execFunctionBlocksFromCurrent(frame);
                },
            }
        }
        return .void;
    }

    /// Execute a single instruction.
    fn execOneInstruction(
        self: *Interpreter,
        instr: ir.Instruction,
        frame: *Frame,
    ) CtfeInterpretError!ExecResult {
        switch (instr) {
            // === Constants ===
            .const_int => |ci| {
                frame.setLocal(ci.dest, .{ .int = ci.value });
                return .continued;
            },
            .const_float => |cf| {
                frame.setLocal(cf.dest, .{ .float = cf.value });
                return .continued;
            },
            .const_string => |cs| {
                frame.setLocal(cs.dest, .{ .string = cs.value });
                return .continued;
            },
            .const_bool => |cb| {
                frame.setLocal(cb.dest, .{ .bool_val = cb.value });
                return .continued;
            },
            .const_atom => |ca| {
                frame.setLocal(ca.dest, .{ .atom = ca.value });
                return .continued;
            },
            .const_nil => |dest| {
                frame.setLocal(dest, .nil);
                return .continued;
            },

            // === Locals ===
            .local_get => |lg| {
                frame.setLocal(lg.dest, try self.readLocal(frame, lg.source));
                return .continued;
            },
            .local_set => |ls| {
                frame.setLocal(ls.dest, try self.readLocal(frame, ls.value));
                return .continued;
            },
            .param_get => |pg| {
                frame.setLocal(pg.dest, try self.readParam(frame, pg.index));
                return .continued;
            },
            .move_value => |mv| {
                // Move semantics: copy value and invalidate source
                const val = try self.readLocal(frame, mv.source);
                frame.setLocal(mv.dest, val);
                frame.setLocal(mv.source, .consumed); // source is consumed
                return .continued;
            },
            .share_value => |sv| {
                // Share semantics: copy value, source remains valid
                frame.setLocal(sv.dest, try self.readLocal(frame, sv.source));
                return .continued;
            },

            // === Arithmetic ===
            .binary_op => |op| {
                const result = try self.evalBinaryOp(op, frame);
                frame.setLocal(op.dest, result);
                return .continued;
            },
            .unary_op => |op| {
                const result = try self.evalUnaryOp(op, frame);
                frame.setLocal(op.dest, result);
                return .continued;
            },

            // === Aggregates ===
            .tuple_init => |ti| {
                const elems = try self.collectLocals(ti.elements, frame);
                const alloc_id = self.allocIdForDest(frame, ti.dest, .tuple);
                frame.setLocal(ti.dest, .{ .tuple = .{ .alloc_id = alloc_id, .elems = elems } });
                return .continued;
            },
            .list_init => |li| {
                const elems = try self.collectLocals(li.elements, frame);
                const alloc_id = self.allocIdForDest(frame, li.dest, .list);
                frame.setLocal(li.dest, .{ .list = .{ .alloc_id = alloc_id, .elems = elems } });
                return .continued;
            },
            .list_cons => |lc| {
                const head_val = try self.readLocal(frame, lc.head);
                const tail_val = try self.readLocal(frame, lc.tail);
                const elems = try self.allocator.alloc(CtValue, 2);
                elems[0] = head_val;
                elems[1] = tail_val;
                const alloc_id = self.allocIdForDest(frame, lc.dest, .tuple);
                frame.setLocal(lc.dest, .{ .tuple = .{ .alloc_id = alloc_id, .elems = elems } });
                return .continued;
            },
            .map_init => |mi| {
                const entries = try self.allocator.alloc(CtValue.CtMapEntry, mi.entries.len);
                for (mi.entries, 0..) |entry, i| {
                    entries[i] = .{
                        .key = try self.readLocal(frame, entry.key),
                        .value = try self.readLocal(frame, entry.value),
                    };
                }
                const alloc_id = self.allocIdForDest(frame, mi.dest, .map);
                frame.setLocal(mi.dest, .{ .map = .{ .alloc_id = alloc_id, .entries = entries } });
                return .continued;
            },
            .struct_init => |si| {
                const fields = try self.allocator.alloc(CtValue.CtFieldValue, si.fields.len);
                for (si.fields, 0..) |field, i| {
                    fields[i] = .{
                        .name = field.name,
                        .value = try self.readLocal(frame, field.value),
                    };
                }
                const alloc_id = self.allocIdForDest(frame, si.dest, .struct_val);
                frame.setLocal(si.dest, .{ .struct_val = .{
                    .alloc_id = alloc_id,
                    .type_name = si.type_name,
                    .fields = fields,
                } });
                return .continued;
            },
            .union_init => |ui| {
                const payload = try self.allocator.create(CtValue);
                payload.* = try self.readLocal(frame, ui.value);
                const alloc_id = self.allocIdForDest(frame, ui.dest, .union_val);
                frame.setLocal(ui.dest, .{ .union_val = .{
                    .alloc_id = alloc_id,
                    .type_name = ui.union_type,
                    .variant = ui.variant_name,
                    .payload = payload,
                } });
                return .continued;
            },
            .enum_literal => |el| {
                frame.setLocal(el.dest, .{ .enum_val = .{
                    .type_name = el.type_name,
                    .variant = el.variant,
                } });
                return .continued;
            },

            // === Access ===
            .field_get => |fg| {
                const result = try self.evalFieldGet(fg, frame);
                frame.setLocal(fg.dest, result);
                return .continued;
            },
            .index_get => |ig| {
                const result = try self.evalIndexGet(ig, frame);
                frame.setLocal(ig.dest, result);
                return .continued;
            },
            .list_get => |lg| {
                const result = try self.evalListGet(lg, frame);
                frame.setLocal(lg.dest, result);
                return .continued;
            },
            .list_is_not_empty => |lne| {
                const list_val = try self.readLocal(frame, lne.list);
                const is_not_empty: bool = switch (list_val) {
                    .list => |l| l.elems.len > 0,
                    .nil => false,
                    else => true,
                };
                frame.setLocal(lne.dest, .{ .bool_val = is_not_empty });
                return .continued;
            },
            .list_head => |lh| {
                const list_val = try self.readLocal(frame, lh.list);
                switch (list_val) {
                    .list => |l| {
                        if (l.elems.len == 0) {
                            try self.emitError(.index_out_of_bounds, "list_head on empty list");
                            return error.CtfeFailure;
                        }
                        frame.setLocal(lh.dest, l.elems[0]);
                    },
                    .tuple => |t| {
                        if (t.elems.len == 0) {
                            try self.emitError(.index_out_of_bounds, "list_head on empty cons cell");
                            return error.CtfeFailure;
                        }
                        frame.setLocal(lh.dest, t.elems[0]);
                    },
                    else => {
                        try self.emitError(.type_error, "list_head on non-list value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },
            .list_tail => |lt| {
                const list_val = try self.readLocal(frame, lt.list);
                switch (list_val) {
                    .list => |l| {
                        if (l.elems.len == 0) {
                            try self.emitError(.index_out_of_bounds, "list_tail on empty list");
                            return error.CtfeFailure;
                        }
                        if (l.elems.len == 1) {
                            frame.setLocal(lt.dest, .nil);
                        } else {
                            const tail_elems = try self.allocator.alloc(CtValue, l.elems.len - 1);
                            @memcpy(tail_elems, l.elems[1..]);
                            frame.setLocal(lt.dest, .{ .list = .{ .alloc_id = l.alloc_id, .elems = tail_elems } });
                        }
                    },
                    .tuple => |t| {
                        if (t.elems.len < 2) {
                            try self.emitError(.index_out_of_bounds, "list_tail on cons cell with no tail");
                            return error.CtfeFailure;
                        }
                        frame.setLocal(lt.dest, t.elems[1]);
                    },
                    else => {
                        try self.emitError(.type_error, "list_tail on non-list value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },
            .map_has_key => |mhk| {
                const map_val = try self.readLocal(frame, mhk.map);
                const key_val = try self.readLocal(frame, mhk.key);
                switch (map_val) {
                    .map => |mv| {
                        var found = false;
                        for (mv.entries) |entry| {
                            if (entry.key.eql(key_val)) {
                                found = true;
                                break;
                            }
                        }
                        frame.setLocal(mhk.dest, .{ .bool_val = found });
                    },
                    else => {
                        try self.emitError(.type_error, "map_has_key on non-map value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },
            .map_get => |mg| {
                const map_val = try self.readLocal(frame, mg.map);
                const key_val = try self.readLocal(frame, mg.key);
                switch (map_val) {
                    .map => |mv| {
                        var result: ?CtValue = null;
                        for (mv.entries) |entry| {
                            if (entry.key.eql(key_val)) {
                                result = entry.value;
                                break;
                            }
                        }
                        if (result) |val| {
                            frame.setLocal(mg.dest, val);
                        } else {
                            frame.setLocal(mg.dest, try self.readLocal(frame, mg.default));
                        }
                    },
                    else => {
                        try self.emitError(.type_error, "map_get on non-map value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },
            .list_len_check => |lc| {
                const obj = try self.readLocal(frame, lc.scrutinee);
                const result: bool = switch (obj) {
                    .list => |l| l.elems.len == lc.expected_len,
                    .tuple => |t| t.elems.len == lc.expected_len,
                    else => false,
                };
                frame.setLocal(lc.dest, .{ .bool_val = result });
                return .continued;
            },
            .optional_unwrap => |ou| {
                const val = try self.readLocal(frame, ou.source);
                switch (val) {
                    .optional => |o| {
                        if (o.value) |v| {
                            frame.setLocal(ou.dest, v.*);
                        } else {
                            try self.emitError(.type_error, "unwrap of nil optional");
                            return error.CtfeFailure;
                        }
                    },
                    .nil => {
                        try self.emitError(.type_error, "unwrap of nil");
                        return error.CtfeFailure;
                    },
                    else => frame.setLocal(ou.dest, val),
                }
                return .continued;
            },

            // === Structured control flow ===
            .if_expr => |ie| return self.execIfExpr(ie, frame),
            .case_block => |cb| return self.execCaseBlock(cb, frame),
            .switch_literal => |sl| return self.execSwitchLiteral(sl, frame),
            .switch_return => |sr| return self.execSwitchReturn(sr, frame),
            .union_switch_return => |usr| return self.execUnionSwitchReturn(usr, frame),
            .union_switch => |us| return self.execUnionSwitch(us, frame),
            .branch => |b| return .{ .jumped = b.target },
            .cond_branch => |cb| {
                const cond = try self.readLocal(frame, cb.condition);
                return .{ .jumped = if (cond.isTruthy()) cb.then_target else cb.else_target };
            },
            .switch_tag => |st| {
                const scrutinee = try self.readLocal(frame, st.scrutinee);
                const tag = switch (scrutinee) {
                    .union_val => |uv| uv.variant,
                    .enum_val => |ev| ev.variant,
                    .atom => |a| a,
                    else => {
                        try self.emitError(.type_error, "switch_tag on non-tagged value");
                        return error.CtfeFailure;
                    },
                };
                for (st.cases) |case| {
                    if (std.mem.eql(u8, tag, case.tag)) return .{ .jumped = case.target };
                }
                return .{ .jumped = st.default };
            },
            .guard_block => |gb| {
                if ((try self.readLocal(frame, gb.condition)).isTruthy()) {
                    for (gb.body, 0..) |body_instr, body_idx| {
                        self.setCurrentInstructionIndex(body_idx);
                        const r = try self.execOneInstruction(body_instr, frame);
                        switch (r) {
                            .continued => {},
                            .returned => |v| return .{ .returned = v },
                            .broke => |v| return .{ .broke = v },
                            .jumped => |target| return .{ .jumped = target },
                        }
                    }
                }
                return .continued;
            },

            // === Calls ===
            .call_direct => |cd| {
                const result = try self.execCallDirect(cd, frame);
                frame.setLocal(cd.dest, result);
                return .continued;
            },
            .call_named => |cn| {
                const result = try self.execCallNamed(cn, frame);
                frame.setLocal(cn.dest, result);
                return .continued;
            },
            .try_call_named => |tcn| {
                // try_call_named behaves like call_named at CTFE level;
                // the error union semantics are handled by error_catch.
                const result = try self.execCallNamed(.{
                    .dest = tcn.dest,
                    .name = tcn.name,
                    .args = tcn.args,
                    .arg_modes = tcn.arg_modes,
                }, frame);
                frame.setLocal(tcn.dest, result);
                return .continued;
            },
            .error_catch => |ec| {
                // At CTFE, if source holds a value, pass it through;
                // error handling is structural — catch_value is the fallback.
                const source_val = try self.readLocal(frame, ec.source);
                frame.setLocal(ec.dest, source_val);
                return .continued;
            },
            .call_builtin => |cb| {
                const result = try self.execCallBuiltin(cb, frame);
                frame.setLocal(cb.dest, result);
                return .continued;
            },
            .tail_call => |tc| {
                const result = try self.execTailCall(tc, frame);
                return .{ .returned = result };
            },

            // === Return / break ===
            .ret => |r| {
                return .{ .returned = if (r.value) |v| try self.readLocal(frame, v) else .void };
            },
            .cond_return => |cr| {
                if ((try self.readLocal(frame, cr.condition)).isTruthy()) {
                    return .{ .returned = if (cr.value) |v| try self.readLocal(frame, v) else .void };
                }
                return .continued;
            },
            .case_break => |cb| {
                return .{ .broke = if (cb.value) |v| try self.readLocal(frame, v) else null };
            },

            // === Match ===
            .match_atom => |ma| {
                const scrutinee = try self.readLocal(frame, ma.scrutinee);
                const matches = switch (scrutinee) {
                    .atom => |a| std.mem.eql(u8, a, ma.atom_name),
                    else => false,
                };
                frame.setLocal(ma.dest, .{ .bool_val = matches });
                return .continued;
            },
            .match_int => |mi| {
                const scrutinee = try self.readLocal(frame, mi.scrutinee);
                const matches = switch (scrutinee) {
                    .int => |v| v == mi.value,
                    else => false,
                };
                frame.setLocal(mi.dest, .{ .bool_val = matches });
                return .continued;
            },
            .match_float => |mf| {
                const scrutinee = try self.readLocal(frame, mf.scrutinee);
                const matches = switch (scrutinee) {
                    .float => |v| v == mf.value,
                    else => false,
                };
                frame.setLocal(mf.dest, .{ .bool_val = matches });
                return .continued;
            },
            .match_string => |ms| {
                const scrutinee = try self.readLocal(frame, ms.scrutinee);
                const matches = switch (scrutinee) {
                    .string => |v| std.mem.eql(u8, v, ms.expected),
                    else => false,
                };
                frame.setLocal(ms.dest, .{ .bool_val = matches });
                return .continued;
            },
            .match_type => |mt| {
                const scrutinee = try self.readLocal(frame, mt.scrutinee);
                const matches = matchesZigType(scrutinee, mt.expected_type);
                frame.setLocal(mt.dest, .{ .bool_val = matches });
                return .continued;
            },
            .match_fail => {
                try self.emitError(.match_failure, "no matching clause at compile time");
                return error.CtfeFailure;
            },
            .match_error_return => {
                try self.emitError(.match_failure, "no matching clause at compile time (try variant)");
                return error.CtfeFailure;
            },

            // === ARC (ownership-aware at compile time) ===
            .retain => |ret| {
                // Retain increments reference count. At CTFE, values are by-value
                // so this is a semantic check: the value should not be void/moved.
                // No actual count tracking needed with by-value semantics.
                _ = try self.readLocal(frame, ret.value);
                return .continued;
            },
            .release => |rel| {
                // Release decrements reference count. At CTFE, mark the value
                // as consumed (void) to catch use-after-release errors.
                _ = try self.readLocal(frame, rel.value);
                frame.setLocal(rel.value, .consumed);
                return .continued;
            },
            .reset => |rst| {
                // Perceus reset: if RC=1, make memory available for reuse.
                // At CTFE, the source value is consumed and a reuse token is produced.
                const source = try self.readLocal(frame, rst.source);
                frame.setLocal(rst.dest, if (getReuseInfo(source)) |rt| .{ .reuse_token = rt } else .nil);
                frame.setLocal(rst.source, .consumed);
                return .continued;
            },
            .reuse_alloc => |ra| {
                // Perceus reuse: validate and consume the token if present.
                if (ra.token) |token_local| {
                    const token = try self.readLocal(frame, token_local);
                    switch (token) {
                        .reuse_token => |rt| {
                            frame.setLocal(token_local, .consumed);
                            frame.setLocal(ra.dest, .{ .reuse_token = rt });
                        },
                        .nil => {},
                        else => {
                            try self.emitError(.type_error, "reuse_alloc expects a reuse token or nil");
                            return error.CtfeFailure;
                        },
                    }
                } else {
                    frame.setLocal(ra.dest, .void);
                }
                return .continued;
            },

            // === Closures ===
            .make_closure => |mc| {
                const caps = try self.collectLocals(mc.captures, frame);
                const alloc_id = self.allocIdForDest(frame, mc.dest, .closure);
                frame.setLocal(mc.dest, .{ .closure = .{
                    .alloc_id = alloc_id,
                    .function_id = mc.function,
                    .captures = caps,
                } });
                return .continued;
            },
            .capture_get => |cg| {
                frame.setLocal(cg.dest, try self.readCaptured(frame, cg.index));
                return .continued;
            },
            .call_closure => |cc| {
                const callee = try self.readLocal(frame, cc.callee);
                switch (callee) {
                    .closure => |cl| {
                        const args = try self.collectLocals(cc.args, frame);
                        // Save and set captures on the new frame
                        const result = try self.evalClosureCall(cl.function_id, args, cl.captures);
                        frame.setLocal(cc.dest, result);
                    },
                    else => {
                        try self.emitError(.type_error, "call_closure on non-closure value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },

            // === field_set (copy-on-write) ===
            .field_set => |fs| {
                const obj = try self.readLocal(frame, fs.object);
                switch (obj) {
                    .struct_val => |sv| {
                        const new_fields = self.allocator.alloc(CtValue.CtFieldValue, sv.fields.len) catch return error.OutOfMemory;
                        for (sv.fields, 0..) |field, i| {
                            if (std.mem.eql(u8, field.name, fs.field)) {
                                new_fields[i] = .{ .name = field.name, .value = try self.readLocal(frame, fs.value) };
                            } else {
                                new_fields[i] = field;
                            }
                        }
                        frame.setLocal(fs.object, .{ .struct_val = .{
                            .alloc_id = sv.alloc_id,
                            .type_name = sv.type_name,
                            .fields = new_fields,
                        } });
                    },
                    .map => |mv| {
                        var new_entries = std.ArrayListUnmanaged(CtValue.CtMapEntry).fromOwnedSlice(@constCast(mv.entries));
                        var found = false;
                        for (new_entries.items, 0..) |entry, i| {
                            const key_matches = switch (entry.key) {
                                .string => |k| std.mem.eql(u8, k, fs.field),
                                .atom => |k| std.mem.eql(u8, k, fs.field),
                                else => false,
                            };
                            if (key_matches) {
                                new_entries.items[i].value = try self.readLocal(frame, fs.value);
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            new_entries.append(self.allocator, .{
                                .key = .{ .string = fs.field },
                                .value = try self.readLocal(frame, fs.value),
                            }) catch return error.OutOfMemory;
                        }
                        frame.setLocal(fs.object, .{ .map = .{ .alloc_id = mv.alloc_id, .entries = new_entries.items } });
                    },
                    else => {
                        try self.emitError(.type_error, "field_set on non-struct/map value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },

            // === Binary pattern matching ===
            .bin_len_check => |blc| {
                const val = try self.readLocal(frame, blc.scrutinee);
                const bytes = getBinaryBytes(val);
                frame.setLocal(blc.dest, .{ .bool_val = if (bytes) |b| b.len >= blc.min_len else false });
                return .continued;
            },
            .bin_read_int => |bri| {
                const source = getBinaryBytes(try self.readLocal(frame, bri.source)) orelse {
                    try self.emitError(.type_error, "bin_read_int on non-binary value");
                    return error.CtfeFailure;
                };
                const offset = try self.resolveOffset(bri.offset, frame);
                const byte_count: usize = (@as(usize, bri.bits) + 7) / 8;
                if (offset + byte_count > source.len) {
                    try self.emitError(.index_out_of_bounds, "binary read out of bounds");
                    return error.CtfeFailure;
                }
                const bytes = source[offset..][0..byte_count];
                var result: i64 = 0;
                for (bytes) |b| {
                    if (bri.endianness == .little) {
                        // Will handle below
                    }
                    result = (result << 8) | @as(i64, b);
                }
                if (bri.endianness == .little) {
                    result = 0;
                    for (0..byte_count) |i| {
                        result |= @as(i64, bytes[i]) << @intCast(i * 8);
                    }
                }
                if (bri.signed and byte_count > 0) {
                    const sign_bit = @as(u6, @intCast(bri.bits - 1));
                    const mask = @as(i64, 1) << sign_bit;
                    if (result & mask != 0) {
                        result = result - (@as(i64, 1) << @as(u6, @intCast(bri.bits)));
                    }
                }
                frame.setLocal(bri.dest, .{ .int = result });
                return .continued;
            },
            .bin_read_float => |brf| {
                const source = getBinaryBytes(try self.readLocal(frame, brf.source)) orelse {
                    try self.emitError(.type_error, "bin_read_float on non-binary value");
                    return error.CtfeFailure;
                };
                const offset = try self.resolveOffset(brf.offset, frame);
                if (brf.bits == 64) {
                    if (offset + 8 > source.len) {
                        try self.emitError(.index_out_of_bounds, "binary read out of bounds");
                        return error.CtfeFailure;
                    }
                    var buf: [8]u8 = undefined;
                    @memcpy(&buf, source[offset..][0..8]);
                    const val: f64 = @bitCast(std.mem.readInt(u64, &buf, if (brf.endianness == .little) .little else .big));
                    frame.setLocal(brf.dest, .{ .float = val });
                } else {
                    if (offset + 4 > source.len) {
                        try self.emitError(.index_out_of_bounds, "binary read out of bounds");
                        return error.CtfeFailure;
                    }
                    var buf: [4]u8 = undefined;
                    @memcpy(&buf, source[offset..][0..4]);
                    const val: f32 = @bitCast(std.mem.readInt(u32, &buf, if (brf.endianness == .little) .little else .big));
                    frame.setLocal(brf.dest, .{ .float = @floatCast(val) });
                }
                return .continued;
            },
            .bin_slice => |bs| {
                const source = getBinaryBytes(try self.readLocal(frame, bs.source)) orelse {
                    try self.emitError(.type_error, "bin_slice on non-binary value");
                    return error.CtfeFailure;
                };
                const offset = try self.resolveOffset(bs.offset, frame);
                if (offset > source.len) {
                    try self.emitError(.index_out_of_bounds, "binary slice offset out of bounds");
                    return error.CtfeFailure;
                }
                if (bs.length) |len_offset| {
                    const length = try self.resolveOffset(len_offset, frame);
                    const end = offset + length;
                    if (end > source.len) {
                        try self.emitError(.index_out_of_bounds, "binary slice length out of bounds");
                        return error.CtfeFailure;
                    }
                    frame.setLocal(bs.dest, .{ .string = source[offset..end] });
                } else {
                    frame.setLocal(bs.dest, .{ .string = source[offset..] });
                }
                return .continued;
            },
            .bin_read_utf8 => |bru| {
                const source = getBinaryBytes(try self.readLocal(frame, bru.source)) orelse {
                    try self.emitError(.type_error, "bin_read_utf8 on non-binary value");
                    return error.CtfeFailure;
                };
                const offset = try self.resolveOffset(bru.offset, frame);
                if (offset >= source.len) {
                    try self.emitError(.index_out_of_bounds, "binary read_utf8 out of bounds");
                    return error.CtfeFailure;
                }
                const byte_len = std.unicode.utf8ByteSequenceLength(source[offset]) catch {
                    try self.emitError(.type_error, "invalid UTF-8 sequence");
                    return error.CtfeFailure;
                };
                if (offset + byte_len > source.len) {
                    try self.emitError(.index_out_of_bounds, "incomplete UTF-8 sequence");
                    return error.CtfeFailure;
                }
                const codepoint = std.unicode.utf8Decode(source[offset..][0..byte_len]) catch {
                    try self.emitError(.type_error, "invalid UTF-8 codepoint");
                    return error.CtfeFailure;
                };
                frame.setLocal(bru.dest_codepoint, .{ .int = @intCast(codepoint) });
                frame.setLocal(bru.dest_len, .{ .int = @intCast(byte_len) });
                return .continued;
            },
            .bin_match_prefix => |bmp| {
                const source = getBinaryBytes(try self.readLocal(frame, bmp.source)) orelse {
                    frame.setLocal(bmp.dest, .{ .bool_val = false });
                    return .continued;
                };
                frame.setLocal(bmp.dest, .{ .bool_val = std.mem.startsWith(u8, source, bmp.expected) });
                return .continued;
            },

            // === Numeric widening (identity at CTFE — values are untyped) ===
            .int_widen, .float_widen => |nw| {
                frame.setLocal(nw.dest, try self.readLocal(frame, nw.source));
                return .continued;
            },

            // === dispatch and jump ===
            .call_dispatch => |cd| {
                // Dynamic dispatch by group_id — resolve to function by ID
                const args = try self.collectLocals(cd.args, frame);
                if (cd.group_id < self.program.functions.len) {
                    const result = try self.evalFunction(cd.group_id, args);
                    frame.setLocal(cd.dest, result);
                } else {
                    try self.emitError(.undefined_function, "dispatch group not found");
                    return error.CtfeFailure;
                }
                return .continued;
            },
            .jump => |j| {
                // In structured IR, jump binds a value to a dest local
                if (j.bind_dest) |dest| {
                    if (j.value) |value| {
                        frame.setLocal(dest, try self.readLocal(frame, value));
                    }
                }
                return .continued;
            },

            // === Dead instructions (never emitted by IR builder) ===
            .phi,
            => {
                try self.emitError(.unsupported_instruction, "unsupported instruction in CTFE");
                return error.CtfeFailure;
            },
        }
    }

    // --------------------------------------------------------
    // Binary operations
    // --------------------------------------------------------

    fn evalBinaryOp(self: *Interpreter, op: ir.BinaryOp, frame: *const Frame) CtfeInterpretError!CtValue {
        const lhs = try self.readLocal(frame, op.lhs);
        const rhs = try self.readLocal(frame, op.rhs);

        switch (op.op) {
            .add => return self.numericOp(lhs, rhs, .add),
            .sub => return self.numericOp(lhs, rhs, .sub),
            .mul => return self.numericOp(lhs, rhs, .mul),
            .div => {
                // Check division by zero
                switch (rhs) {
                    .int => |v| if (v == 0) {
                        try self.emitError(.division_by_zero, "division by zero");
                        return error.CtfeFailure;
                    },
                    .float => |v| if (v == 0.0) {
                        try self.emitError(.division_by_zero, "division by zero");
                        return error.CtfeFailure;
                    },
                    else => {},
                }
                return self.numericOp(lhs, rhs, .div);
            },
            .rem_op => {
                switch (rhs) {
                    .int => |v| if (v == 0) {
                        try self.emitError(.division_by_zero, "remainder by zero");
                        return error.CtfeFailure;
                    },
                    else => {},
                }
                return self.numericOp(lhs, rhs, .rem_op);
            },
            .eq, .string_eq => return .{ .bool_val = lhs.eql(rhs) },
            .neq, .string_neq => return .{ .bool_val = !lhs.eql(rhs) },
            .lt => {
                const ord = lhs.compare(rhs) orelse {
                    try self.emitError(.type_error, "incomparable types");
                    return error.CtfeFailure;
                };
                return .{ .bool_val = ord == .lt };
            },
            .gt => {
                const ord = lhs.compare(rhs) orelse {
                    try self.emitError(.type_error, "incomparable types");
                    return error.CtfeFailure;
                };
                return .{ .bool_val = ord == .gt };
            },
            .lte => {
                const ord = lhs.compare(rhs) orelse {
                    try self.emitError(.type_error, "incomparable types");
                    return error.CtfeFailure;
                };
                return .{ .bool_val = ord != .gt };
            },
            .gte => {
                const ord = lhs.compare(rhs) orelse {
                    try self.emitError(.type_error, "incomparable types");
                    return error.CtfeFailure;
                };
                return .{ .bool_val = ord != .lt };
            },
            .bool_and => return .{ .bool_val = lhs.isTruthy() and rhs.isTruthy() },
            .bool_or => return .{ .bool_val = lhs.isTruthy() or rhs.isTruthy() },
            .concat => return self.evalConcat(lhs, rhs),
        }
    }

    fn numericOp(self: *Interpreter, lhs: CtValue, rhs: CtValue, op: ir.BinaryOp.Op) CtfeInterpretError!CtValue {
        switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| return .{ .int = switch (op) {
                    .add => a +% b,
                    .sub => a -% b,
                    .mul => a *% b,
                    .div => @divTrunc(a, b),
                    .rem_op => @rem(a, b),
                    else => unreachable,
                } },
                else => {},
            },
            .float => |a| switch (rhs) {
                .float => |b| return .{ .float = switch (op) {
                    .add => a + b,
                    .sub => a - b,
                    .mul => a * b,
                    .div => a / b,
                    .rem_op => @rem(a, b),
                    else => unreachable,
                } },
                else => {},
            },
            else => {},
        }
        try self.emitError(.type_error, "numeric operation on non-numeric types");
        return error.CtfeFailure;
    }

    fn evalUnaryOp(self: *Interpreter, op: ir.UnaryOp, frame: *const Frame) CtfeInterpretError!CtValue {
        const operand = try self.readLocal(frame, op.operand);
        switch (op.op) {
            .negate => switch (operand) {
                .int => |v| return .{ .int = -%v },
                .float => |v| return .{ .float = -v },
                else => {
                    try self.emitError(.type_error, "negate on non-numeric type");
                    return error.CtfeFailure;
                },
            },
            .bool_not => return .{ .bool_val = !operand.isTruthy() },
        }
    }

    fn evalConcat(self: *Interpreter, lhs: CtValue, rhs: CtValue) CtfeInterpretError!CtValue {
        switch (lhs) {
            .string => |a| switch (rhs) {
                .string => |b| {
                    const result = self.allocator.alloc(u8, a.len + b.len) catch return error.OutOfMemory;
                    @memcpy(result[0..a.len], a);
                    @memcpy(result[a.len..], b);
                    return .{ .string = result };
                },
                else => {},
            },
            .list => |a| switch (rhs) {
                .list => |b| {
                    const result = self.allocator.alloc(CtValue, a.elems.len + b.elems.len) catch return error.OutOfMemory;
                    @memcpy(result[0..a.elems.len], a.elems);
                    @memcpy(result[a.elems.len..], b.elems);
                    const alloc_id = self.allocation_store.alloc(self.allocator, .list, self.currentFunctionId());
                    return .{ .list = .{ .alloc_id = alloc_id, .elems = result } };
                },
                else => {},
            },
            else => {},
        }
        try self.emitError(.type_error, "concat on incompatible types");
        return error.CtfeFailure;
    }

    // --------------------------------------------------------
    // Access operations
    // --------------------------------------------------------

    fn evalFieldGet(self: *Interpreter, fg: ir.FieldGet, frame: *const Frame) CtfeInterpretError!CtValue {
        const obj = try self.readLocal(frame, fg.object);
        switch (obj) {
            .struct_val => |sv| {
                for (sv.fields) |field| {
                    if (std.mem.eql(u8, field.name, fg.field)) {
                        return field.value;
                    }
                }
                try self.emitError(.type_error, "field not found");
                return error.CtfeFailure;
            },
            .map => |mv| {
                for (mv.entries) |entry| {
                    switch (entry.key) {
                        .string => |k| if (std.mem.eql(u8, k, fg.field)) return entry.value,
                        .atom => |k| if (std.mem.eql(u8, k, fg.field)) return entry.value,
                        else => {},
                    }
                }
                try self.emitError(.type_error, "key not found in map");
                return error.CtfeFailure;
            },
            else => {
                try self.emitError(.type_error, "field_get on non-struct/map value");
                return error.CtfeFailure;
            },
        }
    }

    fn evalIndexGet(self: *Interpreter, ig: ir.IndexGet, frame: *const Frame) CtfeInterpretError!CtValue {
        const obj = try self.readLocal(frame, ig.object);
        switch (obj) {
            .tuple => |t| {
                if (ig.index >= t.elems.len) {
                    try self.emitError(.index_out_of_bounds, "tuple index out of bounds");
                    return error.CtfeFailure;
                }
                return t.elems[ig.index];
            },
            else => {
                try self.emitError(.type_error, "index_get on non-tuple value");
                return error.CtfeFailure;
            },
        }
    }

    fn evalListGet(self: *Interpreter, lg: ir.ListGet, frame: *const Frame) CtfeInterpretError!CtValue {
        const obj = try self.readLocal(frame, lg.list);
        switch (obj) {
            .list => |l| {
                if (lg.index >= l.elems.len) {
                    try self.emitError(.index_out_of_bounds, "list index out of bounds");
                    return error.CtfeFailure;
                }
                return l.elems[lg.index];
            },
            else => {
                try self.emitError(.type_error, "list_get on non-list value");
                return error.CtfeFailure;
            },
        }
    }

    // --------------------------------------------------------
    // Structured control flow
    // --------------------------------------------------------

    fn execIfExpr(self: *Interpreter, ie: ir.IfExpr, frame: *Frame) CtfeInterpretError!ExecResult {
        const cond = try self.readLocal(frame, ie.condition);
        if (cond.isTruthy()) {
            const val = try self.execBranch(ie.then_instrs, ie.then_result, frame);
            frame.setLocal(ie.dest, val);
        } else {
            const val = try self.execBranch(ie.else_instrs, ie.else_result, frame);
            frame.setLocal(ie.dest, val);
        }
        return .continued;
    }

    fn execCaseBlock(self: *Interpreter, cb: ir.CaseBlock, frame: *Frame) CtfeInterpretError!ExecResult {
        // Execute pre-instructions (decision tree with match + case_break)
        for (cb.pre_instrs, 0..) |instr, idx| {
            self.setCurrentInstructionIndex(idx);
            const r = try self.execOneInstruction(instr, frame);
            switch (r) {
                .continued => {},
                .returned => |v| return .{ .returned = v },
                .broke => |val| {
                    // case_break from decision tree: set dest and exit
                    frame.setLocal(cb.dest, val orelse .nil);
                    return .continued;
                },
                .jumped => |target| return .{ .jumped = target },
            }
        }
        // Try each arm
        for (cb.arms) |arm| {
            for (arm.cond_instrs, 0..) |instr, idx| {
                self.setCurrentInstructionIndex(idx);
                const r = try self.execOneInstruction(instr, frame);
                switch (r) {
                    .continued => {},
                    .returned => |v| return .{ .returned = v },
                    .broke => {},
                    .jumped => |target| return .{ .jumped = target },
                }
            }
            if ((try self.readLocal(frame, arm.condition)).isTruthy()) {
                const val = try self.execBranch(arm.body_instrs, arm.result, frame);
                frame.setLocal(cb.dest, val);
                return .continued;
            }
        }
        // Default
        const val = try self.execBranch(cb.default_instrs, cb.default_result, frame);
        frame.setLocal(cb.dest, val);
        return .continued;
    }

    fn execSwitchLiteral(self: *Interpreter, sl: ir.SwitchLiteral, frame: *Frame) CtfeInterpretError!ExecResult {
        const scrutinee = try self.readLocal(frame, sl.scrutinee);
        for (sl.cases) |case| {
            if (matchLiteralValue(scrutinee, case.value)) {
                const val = try self.execBranch(case.body_instrs, case.result, frame);
                frame.setLocal(sl.dest, val);
                return .continued;
            }
        }
        // Default
        const val = try self.execBranch(sl.default_instrs, sl.default_result, frame);
        frame.setLocal(sl.dest, val);
        return .continued;
    }

    fn execSwitchReturn(self: *Interpreter, sr: ir.SwitchReturn, frame: *Frame) CtfeInterpretError!ExecResult {
        const scrutinee = try self.readParam(frame, sr.scrutinee_param);
        for (sr.cases) |case| {
            if (matchLiteralValue(scrutinee, case.value)) {
                for (case.body_instrs, 0..) |instr, idx| {
                    self.setCurrentInstructionIndex(idx);
                    const r = try self.execOneInstruction(instr, frame);
                    switch (r) {
                        .returned => |v| return .{ .returned = v },
                        .continued => {},
                        .broke => {},
                        .jumped => |target| return .{ .jumped = target },
                    }
                }
                return .{ .returned = if (case.return_value) |rv| try self.readLocal(frame, rv) else .void };
            }
        }
        // Default
        for (sr.default_instrs, 0..) |instr, idx| {
            self.setCurrentInstructionIndex(idx);
            const r = try self.execOneInstruction(instr, frame);
            switch (r) {
                .returned => |v| return .{ .returned = v },
                .continued => {},
                .broke => {},
                .jumped => |target| return .{ .jumped = target },
            }
        }
        return .{ .returned = if (sr.default_result) |dr| try self.readLocal(frame, dr) else .void };
    }

    fn execUnionSwitchReturn(self: *Interpreter, usr: ir.UnionSwitchReturn, frame: *Frame) CtfeInterpretError!ExecResult {
        const scrutinee = try self.readParam(frame, usr.scrutinee_param);
        switch (scrutinee) {
            .union_val => |uv| {
                for (usr.cases) |case| {
                    if (std.mem.eql(u8, case.variant_name, uv.variant)) {
                        // Bind fields to locals
                        for (case.field_bindings) |binding| {
                            const payload_struct = uv.payload.*;
                            switch (payload_struct) {
                                .struct_val => |sv| {
                                    for (sv.fields) |field| {
                                        if (std.mem.eql(u8, field.name, binding.field_name)) {
                                            frame.setLocal(binding.local_index, field.value);
                                            break;
                                        }
                                    }
                                },
                                else => frame.setLocal(binding.local_index, payload_struct),
                            }
                        }
                        // Execute body
                        for (case.body_instrs, 0..) |instr, idx| {
                            self.setCurrentInstructionIndex(idx);
                            const r = try self.execOneInstruction(instr, frame);
                            switch (r) {
                                .returned => |v| return .{ .returned = v },
                                .continued => {},
                                .broke => {},
                                .jumped => |target| return .{ .jumped = target },
                            }
                        }
                        return .{ .returned = if (case.return_value) |rv| try self.readLocal(frame, rv) else .void };
                    }
                }
                try self.emitError(.match_failure, "no matching union variant");
                return error.CtfeFailure;
            },
            .struct_val => |sv| {
                // Direct struct dispatch (not a union wrapper)
                for (usr.cases) |case| {
                    if (std.mem.eql(u8, case.variant_name, sv.type_name)) {
                        for (case.field_bindings) |binding| {
                            for (sv.fields) |field| {
                                if (std.mem.eql(u8, field.name, binding.field_name)) {
                                    frame.setLocal(binding.local_index, field.value);
                                    break;
                                }
                            }
                        }
                        for (case.body_instrs, 0..) |instr, idx| {
                            self.setCurrentInstructionIndex(idx);
                            const r = try self.execOneInstruction(instr, frame);
                            switch (r) {
                                .returned => |v| return .{ .returned = v },
                                .continued => {},
                                .broke => {},
                                .jumped => |target| return .{ .jumped = target },
                            }
                        }
                        return .{ .returned = if (case.return_value) |rv| try self.readLocal(frame, rv) else .void };
                    }
                }
                try self.emitError(.match_failure, "no matching struct type");
                return error.CtfeFailure;
            },
            else => {
                try self.emitError(.type_error, "union_switch_return on non-union value");
                return error.CtfeFailure;
            },
        }
    }

    fn execUnionSwitch(self: *Interpreter, us: ir.UnionSwitch, frame: *Frame) CtfeInterpretError!ExecResult {
        const scrutinee = try self.readLocal(frame, us.scrutinee);
        switch (scrutinee) {
            .union_val => |uv| {
                for (us.cases) |case| {
                    if (std.mem.eql(u8, case.variant_name, uv.variant)) {
                        // Bind fields to locals
                        for (case.field_bindings) |binding| {
                            const payload_struct = uv.payload.*;
                            switch (payload_struct) {
                                .struct_val => |sv| {
                                    for (sv.fields) |field| {
                                        if (std.mem.eql(u8, field.name, binding.field_name)) {
                                            frame.setLocal(binding.local_index, field.value);
                                            break;
                                        }
                                    }
                                },
                                else => frame.setLocal(binding.local_index, payload_struct),
                            }
                        }
                        // Execute body
                        for (case.body_instrs, 0..) |instr, idx| {
                            self.setCurrentInstructionIndex(idx);
                            const r = try self.execOneInstruction(instr, frame);
                            switch (r) {
                                .returned => |v| return .{ .returned = v },
                                .continued => {},
                                .broke => {},
                                .jumped => |target| return .{ .jumped = target },
                            }
                        }
                        const result = if (case.return_value) |rv| try self.readLocal(frame, rv) else .void;
                        frame.setLocal(us.dest, result);
                        return .continued;
                    }
                }
                try self.emitError(.match_failure, "no matching union variant");
                return error.CtfeFailure;
            },
            .struct_val => |sv| {
                for (us.cases) |case| {
                    if (std.mem.eql(u8, case.variant_name, sv.type_name)) {
                        for (case.field_bindings) |binding| {
                            for (sv.fields) |field| {
                                if (std.mem.eql(u8, field.name, binding.field_name)) {
                                    frame.setLocal(binding.local_index, field.value);
                                    break;
                                }
                            }
                        }
                        for (case.body_instrs, 0..) |instr, idx| {
                            self.setCurrentInstructionIndex(idx);
                            const r = try self.execOneInstruction(instr, frame);
                            switch (r) {
                                .returned => |v| return .{ .returned = v },
                                .continued => {},
                                .broke => {},
                                .jumped => |target| return .{ .jumped = target },
                            }
                        }
                        const result = if (case.return_value) |rv| try self.readLocal(frame, rv) else .void;
                        frame.setLocal(us.dest, result);
                        return .continued;
                    }
                }
                try self.emitError(.match_failure, "no matching struct type");
                return error.CtfeFailure;
            },
            else => {
                try self.emitError(.type_error, "union_switch on non-union value");
                return error.CtfeFailure;
            },
        }
    }

    /// Helper: execute instructions then read the result local.
    fn execBranch(
        self: *Interpreter,
        instrs: []const ir.Instruction,
        result_local: ?ir.LocalId,
        frame: *Frame,
    ) CtfeInterpretError!CtValue {
        for (instrs, 0..) |instr, idx| {
            if (self.steps_remaining == 0) {
                try self.emitError(.step_limit_exceeded, "step limit exceeded");
                return error.CtfeFailure;
            }
            self.steps_remaining -= 1;
            self.setCurrentInstructionIndex(idx);
            const r = try self.execOneInstruction(instr, frame);
            switch (r) {
                .continued => {},
                .returned => |v| return v,
                .broke => |v| return v orelse .void,
                .jumped => |target| {
                    frame.predecessor_block_label = frame.current_block_label;
                    frame.current_block_label = target;
                    return try self.execFunctionBlocksFromCurrent(frame);
                },
            }
        }
        return if (result_local) |rl| try self.readLocal(frame, rl) else .void;
    }

    fn findBlockByLabel(func: *const ir.Function, label: ir.LabelId) ?*const ir.Block {
        for (func.body) |*block| {
            if (block.label == label) return block;
        }
        return null;
    }

    fn applyPhiInstructions(
        self: *Interpreter,
        instrs: []const ir.Instruction,
        frame: *Frame,
        predecessor: ?ir.LabelId,
    ) CtfeInterpretError!usize {
        var idx: usize = 0;
        while (idx < instrs.len) : (idx += 1) {
            switch (instrs[idx]) {
                .phi => |phi| {
                    const pred = predecessor orelse {
                        try self.emitError(.type_error, "phi reached without predecessor block");
                        return error.CtfeFailure;
                    };
                    var matched = false;
                    for (phi.sources) |src| {
                        if (src.from_block == pred) {
                            frame.setLocal(phi.dest, try self.readLocal(frame, src.value));
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) {
                        try self.emitError(.type_error, "phi missing source for predecessor block");
                        return error.CtfeFailure;
                    }
                },
                else => return idx,
            }
        }
        return idx;
    }

    fn execFunctionBlocksFromCurrent(self: *Interpreter, frame: *Frame) CtfeInterpretError!CtValue {
        const function_id = frame.function_id;
        if (function_id >= self.program.functions.len) {
            try self.emitError(.undefined_function, "invalid function id");
            return error.CtfeFailure;
        }
        const func = &self.program.functions[function_id];
        while (true) {
            const current_label = frame.current_block_label orelse {
                try self.emitError(.type_error, "missing current block label");
                return error.CtfeFailure;
            };
            const block = findBlockByLabel(func, current_label) orelse {
                try self.emitError(.undefined_function, "block label not found");
                return error.CtfeFailure;
            };
            const start_index = try self.applyPhiInstructions(block.instructions, frame, frame.predecessor_block_label);
            return try self.execInstructionsFrom(block.instructions, frame, start_index);
        }
    }

    fn execFunctionBlocks(self: *Interpreter, func: *const ir.Function, frame: *Frame) CtfeInterpretError!CtValue {
        frame.current_block_label = func.body[0].label;
        frame.predecessor_block_label = null;
        return self.execFunctionBlocksFromCurrent(frame);
    }

    // --------------------------------------------------------
    // Calls
    // --------------------------------------------------------

    fn execCallDirect(self: *Interpreter, cd: ir.CallDirect, frame: *const Frame) CtfeInterpretError!CtValue {
        const args = try self.collectLocals(cd.args, frame);
        return self.evalFunction(cd.function, args);
    }

    fn execCallNamed(self: *Interpreter, cn: ir.CallNamed, frame: *const Frame) CtfeInterpretError!CtValue {
        const args = try self.collectLocals(cn.args, frame);
        const func_id = self.function_by_name.get(cn.name) orelse {
            try self.emitError(.undefined_function, cn.name);
            return error.CtfeFailure;
        };
        return self.evalFunction(func_id, args);
    }

    fn execCallBuiltin(self: *Interpreter, cb: ir.CallBuiltin, frame: *const Frame) CtfeInterpretError!CtValue {
        const args = try self.collectLocals(cb.args, frame);

        // Reflection intrinsics
        if (std.mem.eql(u8, cb.name, "Module__functions") or
            std.mem.endsWith(u8, cb.name, "__Module__functions"))
        {
            return self.builtinModuleFunctions(args);
        }
        if (std.mem.eql(u8, cb.name, "Module__attributes") or
            std.mem.endsWith(u8, cb.name, "__Module__attributes"))
        {
            return self.builtinModuleAttributes(args);
        }
        if (std.mem.eql(u8, cb.name, "Module__types") or
            std.mem.endsWith(u8, cb.name, "__Module__types"))
        {
            return self.builtinModuleTypes(args);
        }

        // File read intrinsic
        if (std.mem.eql(u8, cb.name, "File.read") or
            std.mem.endsWith(u8, cb.name, "__File__read") or
            std.mem.eql(u8, cb.name, ":zig.file_read"))
        {
            return self.builtinFileRead(args);
        }

        // Env read intrinsic
        if (std.mem.eql(u8, cb.name, "System.get_env") or
            std.mem.eql(u8, cb.name, ":zig.get_env"))
        {
            return self.builtinGetEnv(args);
        }

        // Build opt read intrinsic
        if (std.mem.eql(u8, cb.name, "System.get_build_opt") or
            std.mem.eql(u8, cb.name, ":zig.get_build_opt"))
        {
            return self.builtinGetBuildOpt(args);
        }

        // Pure type conversion builtins
        if (std.mem.eql(u8, cb.name, ":zig.atom_name")) {
            return self.builtinAtomName(args);
        }
        if (std.mem.eql(u8, cb.name, ":zig.i64_to_string")) {
            return self.builtinI64ToString(args);
        }
        if (std.mem.eql(u8, cb.name, ":zig.f64_to_string")) {
            return self.builtinF64ToString(args);
        }
        if (std.mem.eql(u8, cb.name, ":zig.to_atom") or
            std.mem.eql(u8, cb.name, ":zig.to_existing_atom"))
        {
            return self.builtinToAtom(args);
        }
        if (std.mem.eql(u8, cb.name, ":zig.inspect")) {
            return self.builtinInspect(args);
        }

        // Side-effect builtins: no-op at compile time, return the argument
        if (std.mem.eql(u8, cb.name, ":zig.println") or
            std.mem.eql(u8, cb.name, ":zig.print_str"))
        {
            return if (args.len > 0) args[0] else .nil;
        }

        // Runtime-only builtins
        if (std.mem.eql(u8, cb.name, ":zig.arg_count") or
            std.mem.eql(u8, cb.name, ":zig.arg_at"))
        {
            try self.emitError(.capability_violation, "command-line arguments are not available at compile time");
            return error.CtfeFailure;
        }

        try self.emitError(.unsupported_instruction, cb.name);
        return error.CtfeFailure;
    }

    fn builtinAtomName(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "atom_name expects 1 argument");
            return error.CtfeFailure;
        }
        return switch (args[0]) {
            .atom => |a| .{ .string = a },
            else => {
                try self.emitError(.type_error, "atom_name expects an atom argument");
                return error.CtfeFailure;
            },
        };
    }

    fn builtinI64ToString(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "i64_to_string expects 1 argument");
            return error.CtfeFailure;
        }
        return switch (args[0]) {
            .int => |v| .{ .string = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch return error.OutOfMemory },
            else => {
                try self.emitError(.type_error, "i64_to_string expects an integer argument");
                return error.CtfeFailure;
            },
        };
    }

    fn builtinF64ToString(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "f64_to_string expects 1 argument");
            return error.CtfeFailure;
        }
        return switch (args[0]) {
            .float => |v| .{ .string = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch return error.OutOfMemory },
            else => {
                try self.emitError(.type_error, "f64_to_string expects a float argument");
                return error.CtfeFailure;
            },
        };
    }

    fn builtinToAtom(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "to_atom expects 1 argument");
            return error.CtfeFailure;
        }
        return switch (args[0]) {
            .string => |s| .{ .atom = s },
            else => {
                try self.emitError(.type_error, "to_atom expects a string argument");
                return error.CtfeFailure;
            },
        };
    }

    fn builtinInspect(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "inspect expects 1 argument");
            return error.CtfeFailure;
        }
        const s = formatCtValue(self.allocator, args[0]) catch return error.OutOfMemory;
        return .{ .string = s };
    }

    // --------------------------------------------------------
    // File/env intrinsics
    // --------------------------------------------------------

    fn builtinFileRead(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.capabilities.has(.read_file)) {
            try self.emitError(.capability_violation, "File.read requires read_file capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "File.read expects 1 argument (path)");
            return error.CtfeFailure;
        }

        const path = switch (args[0]) {
            .string => |s| s,
            else => {
                try self.emitError(.type_error, "File.read expects a string path");
                return error.CtfeFailure;
            },
        };

        // Read the file
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch {
            // Record dependency on absent file
            self.dependencies.append(self.allocator, .{
                .file = .{ .path = path, .content_hash = 0 },
            }) catch {};
            return .nil;
        };

        // Record dependency with content hash
        const content_hash = std.hash.Wyhash.hash(0, content);
        self.dependencies.append(self.allocator, .{
            .file = .{ .path = path, .content_hash = content_hash },
        }) catch {};

        return .{ .string = content };
    }

    fn builtinGetEnv(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.capabilities.has(.read_env)) {
            try self.emitError(.capability_violation, "System.get_env requires read_env capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "System.get_env expects 1 argument (name)");
            return error.CtfeFailure;
        }

        const name = switch (args[0]) {
            .string => |s| s,
            .atom => |a| a,
            else => {
                try self.emitError(.type_error, "System.get_env expects a string name");
                return error.CtfeFailure;
            },
        };

        // Read the env var
        // Use a null-terminated copy for getenv
        const name_z = self.allocator.dupeZ(u8, name) catch return error.OutOfMemory;
        const value = std.posix.getenv(name_z);

        if (value) |v| {
            const val_copy = self.allocator.dupe(u8, v) catch return error.OutOfMemory;
            const value_hash = std.hash.Wyhash.hash(0, v);
            self.dependencies.append(self.allocator, .{
                .env_var = .{ .name = name, .value_hash = value_hash, .present = true },
            }) catch {};
            return .{ .string = val_copy };
        } else {
            // Record dependency on absent env var
            self.dependencies.append(self.allocator, .{
                .env_var = .{ .name = name, .value_hash = 0, .present = false },
            }) catch {};
            return .nil;
        }
    }

    fn builtinGetBuildOpt(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "System.get_build_opt expects 1 argument (name)");
            return error.CtfeFailure;
        }

        const name = switch (args[0]) {
            .string => |s| s,
            .atom => |a| a,
            else => {
                try self.emitError(.type_error, "System.get_build_opt expects a string name");
                return error.CtfeFailure;
            },
        };

        if (self.build_opts.get(name)) |v| {
            return .{ .string = v };
        }
        return .nil;
    }

    // --------------------------------------------------------
    // Reflection intrinsics
    // --------------------------------------------------------

    fn builtinModuleFunctions(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.capabilities.has(.reflect_module)) {
            try self.emitError(.capability_violation, "Module.functions requires reflect_module capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "Module.functions expects 1 argument");
            return error.CtfeFailure;
        }

        const mod_name_str = switch (args[0]) {
            .atom => |a| a,
            .string => |s| s,
            else => {
                try self.emitError(.type_error, "Module.functions expects atom or string argument");
                return error.CtfeFailure;
            },
        };

        const graph = self.scope_graph orelse {
            try self.emitError(.unsupported_instruction, "no scope graph available for reflection");
            return error.CtfeFailure;
        };

        // Find module scope
        const mod_scope_id = self.findModuleScopeByName(graph, mod_name_str) orelse {
            try self.emitError(.undefined_function, "module not found for reflection");
            return error.CtfeFailure;
        };

        // Record dependency with interface hash
        const iface_hash = computeModuleInterfaceHash(graph, mod_scope_id, self.interner, mod_name_str);
        try self.dependencies.append(self.allocator, .{
            .reflected_module = .{ .module_name = mod_name_str, .interface_hash = iface_hash },
        });

        // Collect public functions from this module's scope
        const mod_scope = graph.getScope(mod_scope_id);
        var result_list: std.ArrayListUnmanaged(CtValue) = .empty;

        var family_iter = mod_scope.function_families.iterator();
        while (family_iter.next()) |entry| {
            const family = &graph.families.items[entry.value_ptr.*];
            if (family.visibility == .public) {
                const name_str = if (self.interner) |int| int.get(family.name) else "?";
                const tuple_elems = self.allocator.alloc(CtValue, 2) catch return error.OutOfMemory;
                tuple_elems[0] = .{ .atom = name_str };
                tuple_elems[1] = .{ .int = @intCast(family.arity) };
                const alloc_id = self.allocation_store.alloc(self.allocator, .tuple, self.currentFunctionId());
                result_list.append(self.allocator, .{ .tuple = .{ .alloc_id = alloc_id, .elems = tuple_elems } }) catch return error.OutOfMemory;
            }
        }

        const alloc_id = self.allocation_store.alloc(self.allocator, .list, self.currentFunctionId());
        return .{ .list = .{ .alloc_id = alloc_id, .elems = result_list.items } };
    }

    fn builtinModuleAttributes(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.capabilities.has(.reflect_module)) {
            try self.emitError(.capability_violation, "Module.attributes requires reflect_module capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "Module.attributes expects 1 argument");
            return error.CtfeFailure;
        }

        const mod_name_str = switch (args[0]) {
            .atom => |a| a,
            .string => |s| s,
            else => {
                try self.emitError(.type_error, "Module.attributes expects atom or string argument");
                return error.CtfeFailure;
            },
        };

        const graph = self.scope_graph orelse {
            try self.emitError(.unsupported_instruction, "no scope graph available for reflection");
            return error.CtfeFailure;
        };

        // Record dependency with interface hash
        const mod_scope_id = self.findModuleScopeByName(graph, mod_name_str);
        const iface_hash = if (mod_scope_id) |sid| computeModuleInterfaceHash(graph, sid, self.interner, mod_name_str) else 0;
        try self.dependencies.append(self.allocator, .{
            .reflected_module = .{ .module_name = mod_name_str, .interface_hash = iface_hash },
        });

        // Find module entry and collect its attributes
        var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
        for (graph.modules.items) |mod_entry| {
            if (self.moduleNameMatches(mod_entry.name, mod_name_str)) {
                for (mod_entry.attributes.items) |attr| {
                    const name_str = if (self.interner) |int| int.get(attr.name) else "?";
                    const tuple_elems = self.allocator.alloc(CtValue, 2) catch return error.OutOfMemory;
                    tuple_elems[0] = .{ .atom = name_str };
                    // Include computed value if available, otherwise nil
                    if (attr.computed_value) |cv| {
                        tuple_elems[1] = importConstValue(cv);
                    } else {
                        tuple_elems[1] = .nil;
                    }
                    const alloc_id = self.allocation_store.alloc(self.allocator, .tuple, self.currentFunctionId());
                    result_list.append(self.allocator, .{ .tuple = .{ .alloc_id = alloc_id, .elems = tuple_elems } }) catch return error.OutOfMemory;
                }
                break;
            }
        }

        const alloc_id = self.allocation_store.alloc(self.allocator, .list, self.currentFunctionId());
        return .{ .list = .{ .alloc_id = alloc_id, .elems = result_list.items } };
    }

    fn builtinModuleTypes(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.capabilities.has(.reflect_module)) {
            try self.emitError(.capability_violation, "Module.types requires reflect_module capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "Module.types expects 1 argument");
            return error.CtfeFailure;
        }

        const mod_name_str = switch (args[0]) {
            .atom => |a| a,
            .string => |s| s,
            else => {
                try self.emitError(.type_error, "Module.types expects atom or string argument");
                return error.CtfeFailure;
            },
        };

        const graph = self.scope_graph orelse {
            try self.emitError(.unsupported_instruction, "no scope graph available for reflection");
            return error.CtfeFailure;
        };

        // Record dependency with interface hash
        const mod_scope_id = self.findModuleScopeByName(graph, mod_name_str) orelse {
            try self.dependencies.append(self.allocator, .{
                .reflected_module = .{ .module_name = mod_name_str, .interface_hash = 0 },
            });
            return .{ .list = .{ .alloc_id = 0, .elems = &.{} } };
        };
        const iface_hash = computeModuleInterfaceHash(graph, mod_scope_id, self.interner, mod_name_str);
        try self.dependencies.append(self.allocator, .{
            .reflected_module = .{ .module_name = mod_name_str, .interface_hash = iface_hash },
        });

        var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
        for (graph.types.items) |type_entry| {
            // Check if type belongs to this module by matching scope
            if (self.moduleNameMatchesByScope(graph, type_entry.scope_id, mod_name_str)) {
                const name_str = if (self.interner) |int| int.get(type_entry.name) else "?";
                result_list.append(self.allocator, .{ .atom = name_str }) catch return error.OutOfMemory;
            }
        }

        const alloc_id = self.allocation_store.alloc(self.allocator, .list, self.currentFunctionId());
        return .{ .list = .{ .alloc_id = alloc_id, .elems = result_list.items } };
    }

    fn findModuleScopeByName(self: *Interpreter, graph: *const scope.ScopeGraph, name_str: []const u8) ?scope.ScopeId {
        for (graph.modules.items) |mod_entry| {
            if (self.moduleNameMatches(mod_entry.name, name_str)) {
                return mod_entry.scope_id;
            }
        }
        return null;
    }

    fn moduleNameMatches(self: *Interpreter, name: ast.ModuleName, target: []const u8) bool {
        const int = self.interner orelse return false;
        // Build the full name from parts and compare
        if (name.parts.len == 1) {
            return std.mem.eql(u8, int.get(name.parts[0]), target);
        }
        // Multi-part: join with "."
        var buf: [256]u8 = undefined;
        var pos: usize = 0;
        for (name.parts, 0..) |part, i| {
            if (i > 0) {
                if (pos < buf.len) {
                    buf[pos] = '.';
                    pos += 1;
                }
            }
            const s = int.get(part);
            const end = @min(pos + s.len, buf.len);
            @memcpy(buf[pos..end], s[0 .. end - pos]);
            pos = end;
        }
        return std.mem.eql(u8, buf[0..pos], target);
    }

    fn moduleNameMatchesByScope(self: *Interpreter, graph: *const scope.ScopeGraph, type_scope_id: scope.ScopeId, mod_name_str: []const u8) bool {
        // Walk up from type's scope to find the module
        var sid = type_scope_id;
        while (true) {
            for (graph.modules.items) |mod_entry| {
                if (mod_entry.scope_id == sid) {
                    return self.moduleNameMatches(mod_entry.name, mod_name_str);
                }
            }
            const s = graph.getScope(sid);
            if (s.parent) |parent_id| {
                sid = parent_id;
            } else break;
        }
        return false;
    }

    fn importConstValue(cv: ConstValue) CtValue {
        return importConstValueInner(cv);
    }

    fn importConstValueInner(cv: ConstValue) CtValue {
        return switch (cv) {
            .int => |v| .{ .int = v },
            .float => |v| .{ .float = v },
            .string => |v| .{ .string = v },
            .bool_val => |v| .{ .bool_val = v },
            .atom => |v| .{ .atom = v },
            .nil => .nil,
            .void => .void,
            .tuple => |elems| blk: {
                // Reinterpret in-place: ConstValue and CtValue have compatible
                // scalar layouts for the types that exportValue can produce.
                // For aggregates loaded from the persistent cache, the backing
                // memory is arena-owned so in-place mutation is safe.
                var ct_elems = std.heap.page_allocator.alloc(CtValue, elems.len) catch return .nil;
                for (elems, 0..) |elem, i| {
                    ct_elems[i] = importConstValueInner(elem);
                }
                break :blk .{ .tuple = .{ .alloc_id = 0, .elems = ct_elems } };
            },
            .list => |elems| blk: {
                var ct_elems = std.heap.page_allocator.alloc(CtValue, elems.len) catch return .nil;
                for (elems, 0..) |elem, i| {
                    ct_elems[i] = importConstValueInner(elem);
                }
                break :blk .{ .list = .{ .alloc_id = 0, .elems = ct_elems } };
            },
            .map => |entries| blk: {
                var ct_entries = std.heap.page_allocator.alloc(CtValue.CtMapEntry, entries.len) catch return .nil;
                for (entries, 0..) |entry, i| {
                    ct_entries[i] = .{
                        .key = importConstValueInner(entry.key),
                        .value = importConstValueInner(entry.value),
                    };
                }
                break :blk .{ .map = .{ .alloc_id = 0, .entries = ct_entries } };
            },
            .struct_val => |sv| blk: {
                var ct_fields = std.heap.page_allocator.alloc(CtValue.CtFieldValue, sv.fields.len) catch return .nil;
                for (sv.fields, 0..) |field, i| {
                    ct_fields[i] = .{
                        .name = field.name,
                        .value = importConstValueInner(field.value),
                    };
                }
                break :blk .{ .struct_val = .{
                    .alloc_id = 0,
                    .type_name = sv.type_name,
                    .fields = ct_fields,
                } };
            },
        };
    }

    fn evalClosureCall(
        self: *Interpreter,
        function_id: ir.FunctionId,
        args: []const CtValue,
        captures: []const CtValue,
    ) CtfeInterpretError!CtValue {
        if (self.call_stack.items.len >= self.recursion_limit) {
            try self.emitError(.recursion_limit_exceeded, "recursion limit exceeded");
            return error.CtfeFailure;
        }

        if (function_id >= self.program.functions.len) {
            try self.emitError(.undefined_function, "invalid closure function id");
            return error.CtfeFailure;
        }

        const func = &self.program.functions[function_id];
        var frame = Frame.init(self.allocator, func, args) catch return error.OutOfMemory;
        defer frame.deinit(self.allocator);
        frame.captures = captures;

        try self.call_stack.append(self.allocator, .{
            .function_name = func.name,
            .function_id = function_id,
            .instruction_index = 0,
            .source_span = self.resolveFunctionSourceSpan(func),
        });
        defer _ = self.call_stack.pop();

        if (func.body.len == 0) return .void;
        return self.execInstructions(func.body[0].instructions, &frame);
    }

    fn execTailCall(self: *Interpreter, tc: ir.TailCall, frame: *const Frame) CtfeInterpretError!CtValue {
        const args = try self.collectLocals(tc.args, frame);
        const func_id = self.function_by_name.get(tc.name) orelse {
            try self.emitError(.undefined_function, tc.name);
            return error.CtfeFailure;
        };
        return self.evalFunction(func_id, args);
    }

    // --------------------------------------------------------
    // Helpers
    // --------------------------------------------------------

    fn collectLocals(self: *Interpreter, locals: []const ir.LocalId, frame: *const Frame) CtfeInterpretError![]const CtValue {
        const result = self.allocator.alloc(CtValue, locals.len) catch return error.OutOfMemory;
        for (locals, 0..) |local_id, i| {
            result[i] = try self.readLocal(frame, local_id);
        }
        return result;
    }

    fn emitError(self: *Interpreter, kind: CtfeErrorKind, message: []const u8) !void {
        const stack_copy = try self.allocator.alloc(CtfeFrame, self.call_stack.items.len);
        @memcpy(stack_copy, self.call_stack.items);

        const attribute_context = if (self.current_attribute_context) |ctx| CtfeError.AttributeContext{
            .attr_name = try self.allocator.dupe(u8, ctx.attr_name),
            .module_name = try self.allocator.dupe(u8, ctx.module_name),
        } else null;

        try self.errors.append(self.allocator, .{
            .message = message,
            .kind = kind,
            .call_stack = stack_copy,
            .attribute_context = attribute_context,
        });
    }

    fn currentFunctionId(self: *const Interpreter) ?ir.FunctionId {
        if (self.call_stack.items.len > 0) {
            return self.call_stack.items[self.call_stack.items.len - 1].function_id;
        }
        return null;
    }

    fn readLocal(self: *Interpreter, frame: *const Frame, id: ir.LocalId) CtfeInterpretError!CtValue {
        const value = frame.getLocal(id);
        if (value == .consumed) {
            try self.emitError(.use_after_consume, "value was used after move/release");
            return error.CtfeFailure;
        }
        return value;
    }

    fn readParam(self: *Interpreter, frame: *const Frame, index: u32) CtfeInterpretError!CtValue {
        const value = frame.getParam(index);
        if (value == .consumed) {
            try self.emitError(.use_after_consume, "parameter was used after move/release");
            return error.CtfeFailure;
        }
        return value;
    }

    fn readCaptured(self: *Interpreter, frame: *const Frame, index: u32) CtfeInterpretError!CtValue {
        const value = frame.getCaptured(index);
        if (value == .consumed) {
            try self.emitError(.use_after_consume, "captured value was used after move/release");
            return error.CtfeFailure;
        }
        return value;
    }

    fn setCurrentInstructionIndex(self: *Interpreter, index: usize) void {
        if (self.call_stack.items.len == 0) return;
        self.call_stack.items[self.call_stack.items.len - 1].instruction_index = index;
    }

    fn resolveFunctionSourceSpan(self: *const Interpreter, func: *const ir.Function) ?ast.SourceSpan {
        const graph = self.scope_graph orelse return null;
        const interner = self.interner orelse return null;

        const target_name = baseFunctionName(func.name);
        var fallback: ?ast.SourceSpan = null;

        for (graph.families.items) |family| {
            if (family.scope_id != func.scope_id) continue;
            if (!std.mem.eql(u8, interner.get(family.name), target_name)) continue;
            if (family.clauses.items.len == 0) continue;

            const clause_ref = family.clauses.items[0];
            const clause_span = clause_ref.decl.clauses[clause_ref.clause_index].meta.span;
            if (family.arity == func.arity) return clause_span;
            if (fallback == null) fallback = clause_span;
        }

        return fallback;
    }

    fn hashArgs(args: []const CtValue) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (args) |arg| arg.hashInto(&hasher);
        return hasher.final();
    }

    fn getBinaryBytes(val: CtValue) ?[]const u8 {
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    fn getReuseInfo(val: CtValue) ?CtValue.CtReuseToken {
        return switch (val) {
            .tuple => |tv| .{ .alloc_id = tv.alloc_id, .kind = .tuple },
            .list => |lv| .{ .alloc_id = lv.alloc_id, .kind = .list },
            .map => |mv| .{ .alloc_id = mv.alloc_id, .kind = .map },
            .struct_val => |sv| .{ .alloc_id = sv.alloc_id, .kind = .struct_val },
            .union_val => |uv| .{ .alloc_id = uv.alloc_id, .kind = .union_val },
            .closure => |cl| .{ .alloc_id = cl.alloc_id, .kind = .closure },
            else => null,
        };
    }

    fn allocIdForDest(self: *Interpreter, frame: *const Frame, dest: ir.LocalId, kind: AllocKind) AllocId {
        const existing = frame.getLocal(dest);
        return switch (existing) {
            .reuse_token => |rt| if (rt.kind == kind) rt.alloc_id else self.allocation_store.alloc(self.allocator, kind, self.currentFunctionId()),
            else => self.allocation_store.alloc(self.allocator, kind, self.currentFunctionId()),
        };
    }

    fn isReusableValue(val: CtValue) bool {
        return switch (val) {
            .tuple, .list, .map, .struct_val, .union_val, .closure => true,
            else => false,
        };
    }

    fn resolveOffset(self: *Interpreter, offset: ir.BinOffset, frame: *const Frame) CtfeInterpretError!usize {
        return switch (offset) {
            .static => |v| @intCast(v),
            .dynamic => |local_id| {
                const val = try self.readLocal(frame, local_id);
                return switch (val) {
                    .int => |v| if (v >= 0) @intCast(v) else 0,
                    else => 0,
                };
            },
        };
    }

    fn matchLiteralValue(val: CtValue, lit: ir.LiteralValue) bool {
        return switch (lit) {
            .int => |v| switch (val) {
                .int => |cv| cv == v,
                else => false,
            },
            .float => |v| switch (val) {
                .float => |cv| cv == v,
                else => false,
            },
            .string => |v| switch (val) {
                .string => |cv| std.mem.eql(u8, cv, v),
                else => false,
            },
            .bool_val => |v| switch (val) {
                .bool_val => |cv| cv == v,
                else => false,
            },
        };
    }

    fn matchesZigType(val: CtValue, expected: ir.ZigType) bool {
        return switch (expected) {
            .i64 => val == .int,
            .f64 => val == .float,
            .string => val == .string,
            .bool_type => val == .bool_val,
            .atom => val == .atom,
            .nil => val == .nil,
            .void => val == .void,
            .any => true,
            else => false,
        };
    }
};

/// Compute a deterministic hash of a module's public interface.
/// Hashes public function families (sorted by name+arity) and module attribute names/values.
fn computeModuleInterfaceHash(
    graph: *const scope.ScopeGraph,
    mod_scope_id: scope.ScopeId,
    interner: ?*const ast.StringInterner,
    mod_name_str: []const u8,
) u64 {
    var hasher = std.hash.Wyhash.init(0);

    // Hash module name for disambiguation
    hasher.update(mod_name_str);

    // Hash public function families from this module's scope
    const mod_scope = graph.getScope(mod_scope_id);
    var family_iter = mod_scope.function_families.iterator();
    // Collect and hash family entries (order-independent via commutative accumulation)
    var family_hash: u64 = 0;
    while (family_iter.next()) |entry| {
        const family = &graph.families.items[entry.value_ptr.*];
        if (family.visibility == .public) {
            var fh = std.hash.Wyhash.init(0);
            const name_str = if (interner) |int| int.get(family.name) else "";
            fh.update(name_str);
            fh.update(std.mem.asBytes(&family.arity));
            family_hash ^= fh.final(); // XOR for order independence
        }
    }
    hasher.update(std.mem.asBytes(&family_hash));

    // Hash module attributes
    var attr_hash: u64 = 0;
    for (graph.modules.items) |mod_entry| {
        if (mod_entry.scope_id == mod_scope_id) {
            for (mod_entry.attributes.items) |attr| {
                var ah = std.hash.Wyhash.init(0);
                const attr_name = if (interner) |int| int.get(attr.name) else "";
                ah.update(attr_name);
                if (attr.computed_value) |cv| {
                    const cv_hash = Interpreter.hashConstValue(cv);
                    ah.update(std.mem.asBytes(&cv_hash));
                }
                attr_hash ^= ah.final();
            }
            break;
        }
    }
    hasher.update(std.mem.asBytes(&attr_hash));

    return hasher.final();
}

fn baseFunctionName(function_name: []const u8) []const u8 {
    const core_name = if (std.mem.indexOf(u8, function_name, "__default_")) |idx|
        function_name[0..idx]
    else
        function_name;

    return if (std.mem.lastIndexOf(u8, core_name, "__")) |idx|
        core_name[idx + 2 ..]
    else
        core_name;
}

/// Format a CtValue as a human-readable inspect string.
fn formatCtValue(alloc: std.mem.Allocator, val: CtValue) ![]const u8 {
    return switch (val) {
        .int => |v| try std.fmt.allocPrint(alloc, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(alloc, "{d}", .{v}),
        .string => |v| try std.fmt.allocPrint(alloc, "\"{s}\"", .{v}),
        .bool_val => |v| try std.fmt.allocPrint(alloc, "{}", .{v}),
        .atom => |v| try std.fmt.allocPrint(alloc, ":{s}", .{v}),
        .nil => try alloc.dupe(u8, "nil"),
        .void => try alloc.dupe(u8, "void"),
        .consumed => try alloc.dupe(u8, "<consumed>"),
        .reuse_token => try alloc.dupe(u8, "<reuse-token>"),
        .tuple => |tv| {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.append(alloc, '{');
            for (tv.elems, 0..) |elem, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                const s = try formatCtValue(alloc, elem);
                try buf.appendSlice(alloc, s);
            }
            try buf.append(alloc, '}');
            return buf.toOwnedSlice(alloc);
        },
        .list => |lv| {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.append(alloc, '[');
            for (lv.elems, 0..) |elem, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                const s = try formatCtValue(alloc, elem);
                try buf.appendSlice(alloc, s);
            }
            try buf.append(alloc, ']');
            return buf.toOwnedSlice(alloc);
        },
        .map => |mv| {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(alloc, "%{");
            for (mv.entries, 0..) |entry, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                const k = try formatCtValue(alloc, entry.key);
                const v = try formatCtValue(alloc, entry.value);
                try buf.appendSlice(alloc, k);
                try buf.appendSlice(alloc, " => ");
                try buf.appendSlice(alloc, v);
            }
            try buf.append(alloc, '}');
            return buf.toOwnedSlice(alloc);
        },
        .struct_val => |sv| try std.fmt.allocPrint(alloc, "%{s}{{...}}", .{sv.type_name}),
        .union_val => |uv| try std.fmt.allocPrint(alloc, "{s}.{s}(...)", .{ uv.type_name, uv.variant }),
        .enum_val => |ev| try std.fmt.allocPrint(alloc, "{s}.{s}", .{ ev.type_name, ev.variant }),
        .optional => |o| if (o.value) |v| formatCtValue(alloc, v.*) else try alloc.dupe(u8, "nil"),
        .closure => try alloc.dupe(u8, "#Function<closure>"),
    };
}

// ============================================================
// Frame
// ============================================================

pub const Frame = struct {
    function_id: ir.FunctionId,
    function_name: []const u8,
    locals: []CtValue,
    params: []const CtValue,
    captures: []const CtValue,
    current_block_label: ?ir.LabelId = null,
    predecessor_block_label: ?ir.LabelId = null,

    pub fn init(allocator: std.mem.Allocator, func: *const ir.Function, args: []const CtValue) !Frame {
        const local_count = if (func.local_count > 0) func.local_count else blk: {
            // Fallback: scan instructions for max local id
            var max: u32 = 0;
            for (func.body) |block| {
                max = @max(max, scanMaxLocal(block.instructions));
            }
            break :blk max + 1;
        };
        const locals = try allocator.alloc(CtValue, local_count);
        @memset(locals, .void);
        return .{
            .function_id = func.id,
            .function_name = func.name,
            .locals = locals,
            .params = args,
            .captures = &.{},
            .current_block_label = null,
            .predecessor_block_label = null,
        };
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.locals);
    }

    pub fn getLocal(self: *const Frame, id: ir.LocalId) CtValue {
        if (id >= self.locals.len) return .void;
        return self.locals[id];
    }

    pub fn setLocal(self: *Frame, id: ir.LocalId, val: CtValue) void {
        if (id < self.locals.len) {
            self.locals[id] = val;
        }
    }

    pub fn getParam(self: *const Frame, index: u32) CtValue {
        if (index >= self.params.len) return .void;
        return self.params[index];
    }

    pub fn getCaptured(self: *const Frame, index: u32) CtValue {
        if (index >= self.captures.len) return .void;
        return self.captures[index];
    }
};

/// Scan instructions recursively for the maximum LocalId used.
fn scanMaxLocal(instrs: []const ir.Instruction) u32 {
    var max: u32 = 0;
    for (instrs) |instr| {
        switch (instr) {
            .const_int => |ci| max = @max(max, ci.dest),
            .const_float => |cf| max = @max(max, cf.dest),
            .const_string => |cs| max = @max(max, cs.dest),
            .const_bool => |cb| max = @max(max, cb.dest),
            .const_atom => |ca| max = @max(max, ca.dest),
            .const_nil => |dest| max = @max(max, dest),
            .local_get => |lg| max = @max(max, @max(lg.dest, lg.source)),
            .local_set => |ls| max = @max(max, @max(ls.dest, ls.value)),
            .param_get => |pg| max = @max(max, pg.dest),
            .binary_op => |op| max = @max(max, @max(op.dest, @max(op.lhs, op.rhs))),
            .unary_op => |op| max = @max(max, @max(op.dest, op.operand)),
            .if_expr => |ie| {
                max = @max(max, ie.dest);
                max = @max(max, scanMaxLocal(ie.then_instrs));
                max = @max(max, scanMaxLocal(ie.else_instrs));
            },
            .case_block => |cb| {
                max = @max(max, cb.dest);
                max = @max(max, scanMaxLocal(cb.pre_instrs));
                max = @max(max, scanMaxLocal(cb.default_instrs));
                for (cb.arms) |arm| {
                    max = @max(max, scanMaxLocal(arm.cond_instrs));
                    max = @max(max, scanMaxLocal(arm.body_instrs));
                }
            },
            .ret => |r| if (r.value) |v| {
                max = @max(max, v);
            },
            else => {},
        }
    }
    return max;
}

// ============================================================
// ExecResult — internal control flow signal
// ============================================================

const ExecResult = union(enum) {
    continued,
    returned: CtValue,
    broke: ?CtValue,
    jumped: ir.LabelId,
};

pub const CtfeInterpretError = error{
    CtfeFailure,
    OutOfMemory,
};

// ============================================================
// Bridge: ConstValue → AST Expr (for attribute substitution)
// ============================================================

pub fn constValueToExpr(
    alloc: std.mem.Allocator,
    val: ConstValue,
    interner: *ast.StringInterner,
) !*const ast.Expr {
    const expr = try alloc.create(ast.Expr);
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };
    expr.* = switch (val) {
        .int => |v| .{ .int_literal = .{ .meta = meta, .value = v } },
        .float => |v| .{ .float_literal = .{ .meta = meta, .value = v } },
        .string => |v| .{ .string_literal = .{ .meta = meta, .value = try interner.intern(v) } },
        .bool_val => |v| .{ .bool_literal = .{ .meta = meta, .value = v } },
        .atom => |v| .{ .atom_literal = .{ .meta = meta, .value = try interner.intern(v) } },
        .nil => .{ .nil_literal = .{ .meta = meta } },
        .void => .{ .nil_literal = .{ .meta = meta } },
        .tuple => |elems| blk: {
            const converted = try alloc.alloc(*const ast.Expr, elems.len);
            for (elems, 0..) |elem, i| {
                converted[i] = try constValueToExpr(alloc, elem, interner);
            }
            break :blk .{ .tuple = .{ .meta = meta, .elements = converted } };
        },
        .list => |elems| blk: {
            const converted = try alloc.alloc(*const ast.Expr, elems.len);
            for (elems, 0..) |elem, i| {
                converted[i] = try constValueToExpr(alloc, elem, interner);
            }
            break :blk .{ .list = .{ .meta = meta, .elements = converted } };
        },
        .map => |entries| blk: {
            const converted = try alloc.alloc(ast.MapField, entries.len);
            for (entries, 0..) |entry, i| {
                converted[i] = .{
                    .key = try constValueToExpr(alloc, entry.key, interner),
                    .value = try constValueToExpr(alloc, entry.value, interner),
                };
            }
            break :blk .{ .map = .{ .meta = meta, .fields = converted } };
        },
        .struct_val => |sv| blk: {
            const converted = try alloc.alloc(ast.StructField, sv.fields.len);
            for (sv.fields, 0..) |field, i| {
                converted[i] = .{
                    .name = try interner.intern(field.name),
                    .value = try constValueToExpr(alloc, field.value, interner),
                };
            }
            const name_parts = try alloc.alloc(ast.StringId, 1);
            name_parts[0] = try interner.intern(sv.type_name);
            break :blk .{ .struct_expr = .{
                .meta = meta,
                .module_name = .{ .parts = name_parts, .span = .{ .start = 0, .end = 0 } },
                .update_source = null,
                .fields = converted,
            } };
        },
    };
    return expr;
}

// ============================================================
// Computed Attribute Evaluation
// ============================================================

const scope = @import("scope.zig");

/// Evaluate computed attributes across all modules.
///
/// Walks module and function attributes looking for those whose values
/// are function calls (zero-argument). For each, resolves the callee to
/// an IR function, evaluates it via CTFE, and stores the result as
/// `computed_value` on the attribute.
///
/// This runs after IR lowering — the full IR program is available.
pub fn evaluateComputedAttributes(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
    cache_dir: ?[]const u8,
    compile_options_hash: u64,
) EvalAttrError!EvalAttrResult {
    var interp = Interpreter.init(alloc, program);
    defer interp.deinit();
    interp.scope_graph = graph;
    interp.interner = interner;
    interp.compile_options_hash = compile_options_hash;
    if (cache_dir) |dir| {
        std.fs.cwd().makePath(dir) catch {};
        interp.persistent_cache = PersistentCache.init(dir);
    }

    var evaluated: u32 = 0;
    var failed: u32 = 0;

    // Walk module-level attributes
    for (graph.modules.items) |*mod_entry| {
        for (mod_entry.attributes.items) |*attr| {
            if (attr.computed_value != null) continue; // already computed
            if (tryEvalAttribute(alloc, &interp, attr, mod_entry.name, interner)) {
                evaluated += 1;
            } else |_| {
                failed += 1;
            }
        }
    }

    // Walk function-level attributes
    for (graph.families.items) |*family| {
        // Find the enclosing module for name mangling
        const mod_name = findModuleForScope(graph, family.scope_id);
        for (family.attributes.items) |*attr| {
            if (attr.computed_value != null) continue;
            if (tryEvalAttribute(alloc, &interp, attr, mod_name, interner)) {
                evaluated += 1;
            } else |_| {
                failed += 1;
            }
        }
    }

    return .{
        .evaluated = evaluated,
        .failed = failed,
        .errors = try cloneCtfeErrors(alloc, interp.errors.items),
    };
}

pub const EvalAttrResult = struct {
    evaluated: u32,
    failed: u32,
    errors: []const CtfeError,
};

pub const EvalAttrError = error{
    OutOfMemory,
};

/// Evaluate computed attributes in dependency order.
///
/// Like `evaluateComputedAttributes`, but processes modules in the given
/// topological order. Results from earlier modules are stored before
/// later modules are evaluated, ensuring that cross-module attribute
/// references resolve correctly.
pub fn evaluateModuleAttributesInOrder(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
    module_order: []const []const u8,
    cache_dir: ?[]const u8,
    compile_options_hash: u64,
) EvalAttrError!EvalAttrResult {
    var interp = Interpreter.init(alloc, program);
    defer interp.deinit();
    interp.scope_graph = graph;
    interp.interner = interner;
    interp.compile_options_hash = compile_options_hash;
    if (cache_dir) |dir| {
        std.fs.cwd().makePath(dir) catch {};
        interp.persistent_cache = PersistentCache.init(dir);
    }

    var evaluated: u32 = 0;
    var failed: u32 = 0;

    // Process modules in dependency order
    for (module_order) |mod_name| {
        // Find the module entry matching this name
        for (graph.modules.items) |*mod_entry| {
            if (moduleNameMatchesStr(mod_entry.name, mod_name, interner)) {
                // Evaluate module-level attributes
                for (mod_entry.attributes.items) |*attr| {
                    if (attr.computed_value != null) continue;
                    if (tryEvalAttribute(alloc, &interp, attr, mod_entry.name, interner)) {
                        evaluated += 1;
                    } else |_| {
                        failed += 1;
                    }
                }

                // Evaluate function-level attributes in this module
                for (graph.families.items) |*family| {
                    if (family.scope_id == mod_entry.scope_id) {
                        for (family.attributes.items) |*attr| {
                            if (attr.computed_value != null) continue;
                            if (tryEvalAttribute(alloc, &interp, attr, mod_entry.name, interner)) {
                                evaluated += 1;
                            } else |_| {
                                failed += 1;
                            }
                        }
                    }
                }
                break;
            }
        }
    }

    // Also process any modules not in the order list (stdlib, etc.)
    for (graph.modules.items) |*mod_entry| {
        for (mod_entry.attributes.items) |*attr| {
            if (attr.computed_value != null) continue;
            if (tryEvalAttribute(alloc, &interp, attr, mod_entry.name, interner)) {
                evaluated += 1;
            } else |_| {
                failed += 1;
            }
        }
    }

    return .{
        .evaluated = evaluated,
        .failed = failed,
        .errors = try cloneCtfeErrors(alloc, interp.errors.items),
    };
}

/// Evaluate computed attributes for a single module against the module IR that
/// has just been lowered. This is used by the true module-by-module compiler
/// loop so later modules can observe earlier computed values without trying to
/// evaluate modules whose IR does not exist yet.
pub fn evaluateComputedAttributesForModule(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
    module_name: []const u8,
    cache_dir: ?[]const u8,
    compile_options_hash: u64,
) EvalAttrError!EvalAttrResult {
    var interp = Interpreter.init(alloc, program);
    defer interp.deinit();
    interp.scope_graph = graph;
    interp.interner = interner;
    interp.compile_options_hash = compile_options_hash;
    if (cache_dir) |dir| {
        std.fs.cwd().makePath(dir) catch {};
        interp.persistent_cache = PersistentCache.init(dir);
    }

    var evaluated: u32 = 0;
    var failed: u32 = 0;

    for (graph.modules.items) |*mod_entry| {
        if (!moduleNameMatchesStr(mod_entry.name, module_name, interner)) continue;

        for (mod_entry.attributes.items) |*attr| {
            if (attr.computed_value != null) continue;
            if (tryEvalAttribute(alloc, &interp, attr, mod_entry.name, interner)) {
                evaluated += 1;
            } else |_| {
                failed += 1;
            }
        }

        for (graph.families.items) |*family| {
            if (family.scope_id != mod_entry.scope_id) continue;
            for (family.attributes.items) |*attr| {
                if (attr.computed_value != null) continue;
                if (tryEvalAttribute(alloc, &interp, attr, mod_entry.name, interner)) {
                    evaluated += 1;
                } else |_| {
                    failed += 1;
                }
            }
        }

        break;
    }

    return .{
        .evaluated = evaluated,
        .failed = failed,
        .errors = try cloneCtfeErrors(alloc, interp.errors.items),
    };
}

fn moduleNameMatchesStr(name: ast.ModuleName, target: []const u8, interner: *const ast.StringInterner) bool {
    if (name.parts.len == 1) {
        return std.mem.eql(u8, interner.get(name.parts[0]), target);
    }
    // Multi-part: join with "."
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    for (name.parts, 0..) |part, i| {
        if (i > 0 and pos < buf.len) {
            buf[pos] = '.';
            pos += 1;
        }
        const s = interner.get(part);
        const end = @min(pos + s.len, buf.len);
        @memcpy(buf[pos..end], s[0 .. end - pos]);
        pos = end;
    }
    return std.mem.eql(u8, buf[0..pos], target);
}

/// Try to evaluate a single attribute's value via CTFE.
/// Handles recursively evaluable constant expressions and compile-time calls.
fn tryEvalAttribute(
    alloc: std.mem.Allocator,
    interp: *Interpreter,
    attr: *scope.Attribute,
    mod_name: ?ast.ModuleName,
    interner: *const ast.StringInterner,
) !void {
    const value_expr = attr.value orelse return error.NotComputable;

    const prev_context = interp.current_attribute_context;
    defer interp.current_attribute_context = prev_context;
    const module_name_str = if (mod_name) |mn| try moduleNameToString(alloc, mn, interner) else null;
    defer if (module_name_str) |name| alloc.free(name);
    if (mod_name) |mn| {
        _ = mn;
        interp.current_attribute_context = .{
            .attr_name = interner.get(attr.name),
            .module_name = module_name_str.?,
        };
    } else {
        interp.current_attribute_context = .{
            .attr_name = interner.get(attr.name),
            .module_name = "<unknown>",
        };
    }

    const ct_value = try evaluateConstExpr(alloc, interp, value_expr, mod_name, interner);
    attr.computed_value = exportValue(alloc, ct_value) catch return error.CtfeFailed;
}

/// Convert a literal AST expression to a CtValue for use as a CTFE argument.
/// Returns null for non-literal expressions.
fn astLiteralToCtValue(expr: *const ast.Expr, interner: *const ast.StringInterner) ?CtValue {
    return switch (expr.*) {
        .int_literal => |v| .{ .int = v.value },
        .float_literal => |v| .{ .float = v.value },
        .string_literal => |v| .{ .string = interner.get(v.value) },
        .atom_literal => |v| .{ .atom = interner.get(v.value) },
        .bool_literal => |v| .{ .bool_val = v.value },
        .nil_literal => .nil,
        else => null,
    };
}

fn importComputedConstValue(cv: ConstValue) CtValue {
    return switch (cv) {
        .int => |v| .{ .int = v },
        .float => |v| .{ .float = v },
        .string => |v| .{ .string = v },
        .bool_val => |v| .{ .bool_val = v },
        .atom => |v| .{ .atom = v },
        .nil => .nil,
        .void => .void,
        .tuple => |elems| blk: {
            var ct_elems = std.heap.page_allocator.alloc(CtValue, elems.len) catch return .nil;
            for (elems, 0..) |elem, i| {
                ct_elems[i] = importComputedConstValue(elem);
            }
            break :blk .{ .tuple = .{ .alloc_id = 0, .elems = ct_elems } };
        },
        .list => |elems| blk: {
            var ct_elems = std.heap.page_allocator.alloc(CtValue, elems.len) catch return .nil;
            for (elems, 0..) |elem, i| {
                ct_elems[i] = importComputedConstValue(elem);
            }
            break :blk .{ .list = .{ .alloc_id = 0, .elems = ct_elems } };
        },
        .map => |entries| blk: {
            var ct_entries = std.heap.page_allocator.alloc(CtValue.CtMapEntry, entries.len) catch return .nil;
            for (entries, 0..) |entry, i| {
                ct_entries[i] = .{
                    .key = importComputedConstValue(entry.key),
                    .value = importComputedConstValue(entry.value),
                };
            }
            break :blk .{ .map = .{ .alloc_id = 0, .entries = ct_entries } };
        },
        .struct_val => |sv| blk: {
            var ct_fields = std.heap.page_allocator.alloc(CtValue.CtFieldValue, sv.fields.len) catch return .nil;
            for (sv.fields, 0..) |field, i| {
                ct_fields[i] = .{
                    .name = field.name,
                    .value = importComputedConstValue(field.value),
                };
            }
            break :blk .{ .struct_val = .{ .alloc_id = 0, .type_name = sv.type_name, .fields = ct_fields } };
        },
    };
}

fn evaluateConstExpr(
    alloc: std.mem.Allocator,
    interp: *Interpreter,
    expr: *const ast.Expr,
    mod_name: ?ast.ModuleName,
    interner: *const ast.StringInterner,
) AttrEvalInternalError!CtValue {
    if (astLiteralToCtValue(expr, interner)) |lit| return lit;

    return switch (expr.*) {
        .tuple => |t| blk: {
            const elems = alloc.alloc(CtValue, t.elements.len) catch return error.OutOfMemory;
            for (t.elements, 0..) |elem, i| {
                elems[i] = try evaluateConstExpr(alloc, interp, elem, mod_name, interner);
            }
            const alloc_id = interp.allocation_store.alloc(alloc, .tuple, interp.currentFunctionId());
            break :blk .{ .tuple = .{ .alloc_id = alloc_id, .elems = elems } };
        },
        .list => |l| blk: {
            const elems = alloc.alloc(CtValue, l.elements.len) catch return error.OutOfMemory;
            for (l.elements, 0..) |elem, i| {
                elems[i] = try evaluateConstExpr(alloc, interp, elem, mod_name, interner);
            }
            const alloc_id = interp.allocation_store.alloc(alloc, .list, interp.currentFunctionId());
            break :blk .{ .list = .{ .alloc_id = alloc_id, .elems = elems } };
        },
        .map => |m| blk: {
            const entries = alloc.alloc(CtValue.CtMapEntry, m.fields.len) catch return error.OutOfMemory;
            for (m.fields, 0..) |field, i| {
                entries[i] = .{
                    .key = try evaluateConstExpr(alloc, interp, field.key, mod_name, interner),
                    .value = try evaluateConstExpr(alloc, interp, field.value, mod_name, interner),
                };
            }
            const alloc_id = interp.allocation_store.alloc(alloc, .map, interp.currentFunctionId());
            break :blk .{ .map = .{ .alloc_id = alloc_id, .entries = entries } };
        },
        .struct_expr => |s| blk: {
            if (s.update_source != null) return error.NotComputable;
            const fields = alloc.alloc(CtValue.CtFieldValue, s.fields.len) catch return error.OutOfMemory;
            const type_name = try moduleNameToString(alloc, s.module_name, interner);
            for (s.fields, 0..) |field, i| {
                fields[i] = .{
                    .name = interner.get(field.name),
                    .value = try evaluateConstExpr(alloc, interp, field.value, mod_name, interner),
                };
            }
            const alloc_id = interp.allocation_store.alloc(alloc, .struct_val, interp.currentFunctionId());
            break :blk .{ .struct_val = .{ .alloc_id = alloc_id, .type_name = type_name, .fields = fields } };
        },
        .attr_ref => |ar| blk: {
            const graph = interp.scope_graph orelse return error.NotComputable;
            const current_module = mod_name orelse return error.NotComputable;
            for (graph.modules.items) |mod_entry| {
                if (!std.meta.eql(mod_entry.name, current_module)) continue;
                for (mod_entry.attributes.items) |attr| {
                    if (attr.name != ar.name) continue;
                    if (attr.computed_value) |cv| {
                        break :blk importComputedConstValue(cv);
                    }
                    return error.NotComputable;
                }
            }
            return error.NotComputable;
        },
        .binary_op => |b| try evaluateConstBinaryOp(alloc, interp, b, mod_name, interner),
        .unary_op => |u| try evaluateConstUnaryOp(alloc, interp, u, mod_name, interner),
        .type_annotated => |ta| try evaluateConstExpr(alloc, interp, ta.expr, mod_name, interner),
        .call => |call| blk: {
            const callee_name = resolveCalleeName(alloc, call.callee, mod_name, interner) orelse
                return error.NotComputable;

            const func_id = interp.function_by_name.get(callee_name) orelse
                return error.NotComputable;

            var ct_args = std.ArrayListUnmanaged(CtValue).empty;
            for (call.args) |arg| {
                ct_args.append(alloc, try evaluateConstExpr(alloc, interp, arg, mod_name, interner)) catch return error.OutOfMemory;
            }

            interp.steps_remaining = interp.step_budget;
            break :blk interp.evalFunction(func_id, ct_args.items) catch return error.CtfeFailed;
        },
        else => error.NotComputable,
    };
}

fn evaluateConstBinaryOp(
    alloc: std.mem.Allocator,
    interp: *Interpreter,
    op: ast.BinaryOp,
    mod_name: ?ast.ModuleName,
    interner: *const ast.StringInterner,
) AttrEvalInternalError!CtValue {
    const lhs = try evaluateConstExpr(alloc, interp, op.lhs, mod_name, interner);
    const rhs = try evaluateConstExpr(alloc, interp, op.rhs, mod_name, interner);

    return switch (op.op) {
        .add => switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| .{ .int = a +% b },
                else => error.NotComputable,
            },
            .float => |a| switch (rhs) {
                .float => |b| .{ .float = a + b },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
        .sub => switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| .{ .int = a -% b },
                else => error.NotComputable,
            },
            .float => |a| switch (rhs) {
                .float => |b| .{ .float = a - b },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
        .mul => switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| .{ .int = a *% b },
                else => error.NotComputable,
            },
            .float => |a| switch (rhs) {
                .float => |b| .{ .float = a * b },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
        .div => switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| blk: {
                    if (b == 0) return error.CtfeFailed;
                    break :blk .{ .int = @divTrunc(a, b) };
                },
                else => error.NotComputable,
            },
            .float => |a| switch (rhs) {
                .float => |b| blk: {
                    if (b == 0.0) return error.CtfeFailed;
                    break :blk .{ .float = a / b };
                },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
        .rem_op => switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| blk: {
                    if (b == 0) return error.CtfeFailed;
                    break :blk .{ .int = @rem(a, b) };
                },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
        .equal => .{ .bool_val = lhs.eql(rhs) },
        .not_equal => .{ .bool_val = !lhs.eql(rhs) },
        .less => blk: {
            const ord = lhs.compare(rhs) orelse return error.NotComputable;
            break :blk .{ .bool_val = ord == .lt };
        },
        .greater => blk: {
            const ord = lhs.compare(rhs) orelse return error.NotComputable;
            break :blk .{ .bool_val = ord == .gt };
        },
        .less_equal => blk: {
            const ord = lhs.compare(rhs) orelse return error.NotComputable;
            break :blk .{ .bool_val = ord != .gt };
        },
        .greater_equal => blk: {
            const ord = lhs.compare(rhs) orelse return error.NotComputable;
            break :blk .{ .bool_val = ord != .lt };
        },
        .and_op => .{ .bool_val = lhs.isTruthy() and rhs.isTruthy() },
        .or_op => .{ .bool_val = lhs.isTruthy() or rhs.isTruthy() },
        .concat => switch (lhs) {
            .string => |a| switch (rhs) {
                .string => |b| blk: {
                    const result = alloc.alloc(u8, a.len + b.len) catch return error.OutOfMemory;
                    @memcpy(result[0..a.len], a);
                    @memcpy(result[a.len..], b);
                    break :blk .{ .string = result };
                },
                else => error.NotComputable,
            },
            .list => |a| switch (rhs) {
                .list => |b| blk: {
                    const result = alloc.alloc(CtValue, a.elems.len + b.elems.len) catch return error.OutOfMemory;
                    @memcpy(result[0..a.elems.len], a.elems);
                    @memcpy(result[a.elems.len..], b.elems);
                    const alloc_id = interp.allocation_store.alloc(alloc, .list, interp.currentFunctionId());
                    break :blk .{ .list = .{ .alloc_id = alloc_id, .elems = result } };
                },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
    };
}

fn evaluateConstUnaryOp(
    alloc: std.mem.Allocator,
    interp: *Interpreter,
    op: ast.UnaryOp,
    mod_name: ?ast.ModuleName,
    interner: *const ast.StringInterner,
) AttrEvalInternalError!CtValue {
    const operand = try evaluateConstExpr(alloc, interp, op.operand, mod_name, interner);
    return switch (op.op) {
        .negate => switch (operand) {
            .int => |v| .{ .int = -%v },
            .float => |v| .{ .float = -v },
            else => error.NotComputable,
        },
        .not_op => .{ .bool_val = !operand.isTruthy() },
    };
}

const AttrEvalInternalError = error{
    NotComputable,
    CtfeFailed,
    OutOfMemory,
};

/// Resolve a callee AST expression to a mangled IR function name.
/// Handles: bare `func()` and `Module.func()` forms.
fn resolveCalleeName(
    alloc: std.mem.Allocator,
    callee: *const ast.Expr,
    mod_name: ?ast.ModuleName,
    interner: *const ast.StringInterner,
) ?[]const u8 {
    switch (callee.*) {
        // Bare call: func() → Module__func
        .var_ref => |vr| {
            const func_name = interner.get(vr.name);
            if (mod_name) |mn| {
                const prefix = moduleNameToPrefix(alloc, mn, interner) catch return null;
                return std.fmt.allocPrint(alloc, "{s}__{s}", .{ prefix, func_name }) catch null;
            }
            return func_name;
        },
        // Qualified call: Module.func() → Module__func
        .field_access => |fa| {
            // object should be a module_ref or var_ref
            const field_name = interner.get(fa.field);
            switch (fa.object.*) {
                .module_ref => |mr| {
                    const prefix = moduleNameToPrefix(alloc, mr.name, interner) catch return null;
                    return std.fmt.allocPrint(alloc, "{s}__{s}", .{ prefix, field_name }) catch null;
                },
                .var_ref => |vr| {
                    const obj_name = interner.get(vr.name);
                    return std.fmt.allocPrint(alloc, "{s}__{s}", .{ obj_name, field_name }) catch null;
                },
                else => return null,
            }
        },
        else => return null,
    }
}

/// Convert an ast.ModuleName to a prefix string, matching IR builder convention.
/// Single-part: "IO". Multi-part: "IO_File".
fn moduleNameToPrefix(
    alloc: std.mem.Allocator,
    name: ast.ModuleName,
    interner: *const ast.StringInterner,
) ![]const u8 {
    if (name.parts.len == 1) {
        return interner.get(name.parts[0]);
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (name.parts, 0..) |part, i| {
        if (i > 0) try buf.append(alloc, '_');
        try buf.appendSlice(alloc, interner.get(part));
    }
    return buf.toOwnedSlice(alloc);
}

fn moduleNameToString(
    alloc: std.mem.Allocator,
    name: ast.ModuleName,
    interner: *const ast.StringInterner,
) ![]const u8 {
    if (name.parts.len == 1) {
        return alloc.dupe(u8, interner.get(name.parts[0]));
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (name.parts, 0..) |part, i| {
        if (i > 0) try buf.append(alloc, '.');
        try buf.appendSlice(alloc, interner.get(part));
    }
    return buf.toOwnedSlice(alloc);
}

/// Find the enclosing module name for a scope, walking up the scope tree.
fn findModuleForScope(graph: *const scope.ScopeGraph, scope_id: scope.ScopeId) ?ast.ModuleName {
    // Check if this scope directly belongs to a module
    for (graph.modules.items) |mod_entry| {
        if (mod_entry.scope_id == scope_id) return mod_entry.name;
    }
    // Walk up parent scopes
    const s = graph.getScope(scope_id);
    if (s.parent) |parent_id| {
        return findModuleForScope(graph, parent_id);
    }
    return null;
}

fn findModuleScopeByNameForCache(
    graph: *const scope.ScopeGraph,
    interner: *const ast.StringInterner,
    module_name: []const u8,
) ?scope.ScopeId {
    for (graph.modules.items) |mod_entry| {
        if (moduleNameMatchesStr(mod_entry.name, module_name, interner)) {
            return mod_entry.scope_id;
        }
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn makeTestProgram(functions: []const ir.Function) ir.Program {
    return .{
        .functions = functions,
        .type_defs = &.{},
        .entry = null,
    };
}

// ============================================================
// Persistent CTFE Cache
// ============================================================

pub const PersistentCache = struct {
    cache_dir: []const u8,

    pub fn init(cache_dir: []const u8) PersistentCache {
        return .{ .cache_dir = cache_dir };
    }

    /// Generate a cache key for a function evaluation.
    pub fn cacheKeyFor(function_name: []const u8, function_hash: u64, args_hash: u64, capability_flags: u8, options_hash: u64) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(function_name);
        hasher.update(std.mem.asBytes(&function_hash));
        hasher.update(std.mem.asBytes(&args_hash));
        hasher.update(&[_]u8{capability_flags});
        hasher.update(std.mem.asBytes(&options_hash));
        hasher.update("ctfe_v2"); // schema version
        return hasher.final();
    }

    /// Try to load a cached result. Returns null if not found or stale.
    pub fn load(self: *const PersistentCache, alloc: std.mem.Allocator, key: u64) ?CtEvalResult {
        const hex_key = std.fmt.allocPrint(alloc, "{x:0>16}", .{key}) catch return null;
        defer alloc.free(hex_key);
        const path = std.fmt.allocPrint(alloc, "{s}/{s}.ctfe", .{ self.cache_dir, hex_key }) catch return null;
        defer alloc.free(path);

        const data = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch return null;
        defer alloc.free(data);

        return deserializeResult(alloc, data) catch null;
    }

    /// Store a result in the persistent cache.
    pub fn store(self: *const PersistentCache, alloc: std.mem.Allocator, key: u64, result: CtEvalResult) void {
        const hex_key = std.fmt.allocPrint(alloc, "{x:0>16}", .{key}) catch return;
        defer alloc.free(hex_key);

        std.fs.cwd().makePath(self.cache_dir) catch return;

        const path = std.fmt.allocPrint(alloc, "{s}/{s}.ctfe", .{ self.cache_dir, hex_key }) catch return;
        defer alloc.free(path);

        const data = serializeResult(alloc, result) catch return;
        defer alloc.free(data);

        const file = std.fs.cwd().createFile(path, .{}) catch return;
        defer file.close();
        file.writeAll(data) catch return;
    }

    /// Validate that all dependencies in a cached result are still current.
    pub fn validateDependencies(
        alloc: std.mem.Allocator,
        deps: []const CtDependency,
        graph: ?*const scope.ScopeGraph,
        interner: ?*const ast.StringInterner,
    ) bool {
        for (deps) |dep| {
            switch (dep) {
                .file => |f| {
                    const content = std.fs.cwd().readFileAlloc(alloc, f.path, 10 * 1024 * 1024) catch return false;
                    defer alloc.free(content);
                    const current_hash = std.hash.Wyhash.hash(0, content);
                    if (current_hash != f.content_hash) return false;
                },
                .env_var => |ev| {
                    const current = std.posix.getenv(ev.name);
                    if (ev.present and current == null) return false;
                    if (!ev.present and current != null) return false;
                    if (current) |v| {
                        const current_hash = std.hash.Wyhash.hash(0, v);
                        if (current_hash != ev.value_hash) return false;
                    }
                },
                .reflected_module => |rm| {
                    const current_graph = graph orelse return false;
                    const current_interner = interner orelse return false;
                    const mod_scope_id = findModuleScopeByNameForCache(current_graph, current_interner, rm.module_name) orelse return false;
                    const current_hash = computeModuleInterfaceHash(current_graph, mod_scope_id, current_interner, rm.module_name);
                    if (current_hash != rm.interface_hash) return false;
                },
            }
        }
        return true;
    }
};

// Tag bytes for ConstValue serialization
const CONST_TAG_INT: u8 = 1;
const CONST_TAG_FLOAT: u8 = 2;
const CONST_TAG_STRING: u8 = 3;
const CONST_TAG_BOOL: u8 = 4;
const CONST_TAG_ATOM: u8 = 5;
const CONST_TAG_NIL: u8 = 6;
const CONST_TAG_VOID: u8 = 7;
const CONST_TAG_TUPLE: u8 = 8;
const CONST_TAG_LIST: u8 = 9;
const CONST_TAG_MAP: u8 = 10;
const CONST_TAG_STRUCT: u8 = 11;

// Dependency serialization tags
const DEP_TAG_FILE: u8 = 1;
const DEP_TAG_ENV_VAR: u8 = 2;
const DEP_TAG_REFLECTED_MODULE: u8 = 3;

fn serializeDependencyInto(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), dep: CtDependency) !void {
    switch (dep) {
        .file => |f| {
            try buf.append(alloc, DEP_TAG_FILE);
            const path_len: u32 = @intCast(f.path.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&path_len));
            try buf.appendSlice(alloc, f.path);
            try buf.appendSlice(alloc, std.mem.asBytes(&f.content_hash));
        },
        .env_var => |ev| {
            try buf.append(alloc, DEP_TAG_ENV_VAR);
            const name_len: u32 = @intCast(ev.name.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&name_len));
            try buf.appendSlice(alloc, ev.name);
            try buf.appendSlice(alloc, std.mem.asBytes(&ev.value_hash));
            try buf.append(alloc, @intFromBool(ev.present));
        },
        .reflected_module => |rm| {
            try buf.append(alloc, DEP_TAG_REFLECTED_MODULE);
            const name_len: u32 = @intCast(rm.module_name.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&name_len));
            try buf.appendSlice(alloc, rm.module_name);
            try buf.appendSlice(alloc, std.mem.asBytes(&rm.interface_hash));
        },
    }
}

fn deserializeDependency(alloc: std.mem.Allocator, data: []const u8, pos: *usize) SerializeError!CtDependency {
    if (pos.* >= data.len) return error.UnexpectedEndOfData;
    const tag = data[pos.*];
    pos.* += 1;

    return switch (tag) {
        DEP_TAG_FILE => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const path_len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            if (pos.* + path_len > data.len) return error.UnexpectedEndOfData;
            const path = try alloc.dupe(u8, data[pos.*..][0..path_len]);
            pos.* += path_len;
            if (pos.* + 8 > data.len) return error.UnexpectedEndOfData;
            const content_hash = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .file = .{ .path = path, .content_hash = content_hash } };
        },
        DEP_TAG_ENV_VAR => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const name_len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            if (pos.* + name_len > data.len) return error.UnexpectedEndOfData;
            const name = try alloc.dupe(u8, data[pos.*..][0..name_len]);
            pos.* += name_len;
            if (pos.* + 9 > data.len) return error.UnexpectedEndOfData;
            const value_hash = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            const present = data[pos.*] != 0;
            pos.* += 1;
            return .{ .env_var = .{ .name = name, .value_hash = value_hash, .present = present } };
        },
        DEP_TAG_REFLECTED_MODULE => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const name_len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            if (pos.* + name_len > data.len) return error.UnexpectedEndOfData;
            const module_name = try alloc.dupe(u8, data[pos.*..][0..name_len]);
            pos.* += name_len;
            if (pos.* + 8 > data.len) return error.UnexpectedEndOfData;
            const interface_hash = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .reflected_module = .{ .module_name = module_name, .interface_hash = interface_hash } };
        },
        else => return error.UnexpectedEndOfData,
    };
}

fn serializeConstValue(alloc: std.mem.Allocator, val: ConstValue) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try serializeConstValueInto(alloc, &buf, val);
    return buf.toOwnedSlice(alloc);
}

fn serializeConstValueInto(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), val: ConstValue) !void {
    switch (val) {
        .int => |v| {
            try buf.append(alloc, CONST_TAG_INT);
            try buf.appendSlice(alloc, std.mem.asBytes(&v));
        },
        .float => |v| {
            try buf.append(alloc, CONST_TAG_FLOAT);
            try buf.appendSlice(alloc, std.mem.asBytes(&v));
        },
        .string => |v| {
            try buf.append(alloc, CONST_TAG_STRING);
            const len: u32 = @intCast(v.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&len));
            try buf.appendSlice(alloc, v);
        },
        .bool_val => |v| {
            try buf.append(alloc, CONST_TAG_BOOL);
            try buf.append(alloc, @intFromBool(v));
        },
        .atom => |v| {
            try buf.append(alloc, CONST_TAG_ATOM);
            const len: u32 = @intCast(v.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&len));
            try buf.appendSlice(alloc, v);
        },
        .nil => try buf.append(alloc, CONST_TAG_NIL),
        .void => try buf.append(alloc, CONST_TAG_VOID),
        .tuple => |elems| {
            try buf.append(alloc, CONST_TAG_TUPLE);
            const len: u32 = @intCast(elems.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&len));
            for (elems) |e| try serializeConstValueInto(alloc, buf, e);
        },
        .list => |elems| {
            try buf.append(alloc, CONST_TAG_LIST);
            const len: u32 = @intCast(elems.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&len));
            for (elems) |e| try serializeConstValueInto(alloc, buf, e);
        },
        .map => |entries| {
            try buf.append(alloc, CONST_TAG_MAP);
            const len: u32 = @intCast(entries.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&len));
            for (entries) |entry| {
                try serializeConstValueInto(alloc, buf, entry.key);
                try serializeConstValueInto(alloc, buf, entry.value);
            }
        },
        .struct_val => |sv| {
            try buf.append(alloc, CONST_TAG_STRUCT);
            const name_len: u32 = @intCast(sv.type_name.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&name_len));
            try buf.appendSlice(alloc, sv.type_name);
            const field_count: u32 = @intCast(sv.fields.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&field_count));
            for (sv.fields) |field| {
                const fname_len: u32 = @intCast(field.name.len);
                try buf.appendSlice(alloc, std.mem.asBytes(&fname_len));
                try buf.appendSlice(alloc, field.name);
                try serializeConstValueInto(alloc, buf, field.value);
            }
        },
    }
}

fn deserializeConstValue(alloc: std.mem.Allocator, data: []const u8, pos: *usize) !ConstValue {
    if (pos.* >= data.len) return error.UnexpectedEndOfData;
    const tag = data[pos.*];
    pos.* += 1;

    return switch (tag) {
        CONST_TAG_INT => {
            if (pos.* + 8 > data.len) return error.UnexpectedEndOfData;
            const v = std.mem.readInt(i64, data[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .int = v };
        },
        CONST_TAG_FLOAT => {
            if (pos.* + 8 > data.len) return error.UnexpectedEndOfData;
            const v: f64 = @bitCast(std.mem.readInt(u64, data[pos.*..][0..8], .little));
            pos.* += 8;
            return .{ .float = v };
        },
        CONST_TAG_STRING => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            if (pos.* + len > data.len) return error.UnexpectedEndOfData;
            const s = try alloc.dupe(u8, data[pos.*..][0..len]);
            pos.* += len;
            return .{ .string = s };
        },
        CONST_TAG_BOOL => {
            if (pos.* >= data.len) return error.UnexpectedEndOfData;
            const v = data[pos.*] != 0;
            pos.* += 1;
            return .{ .bool_val = v };
        },
        CONST_TAG_ATOM => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            if (pos.* + len > data.len) return error.UnexpectedEndOfData;
            const s = try alloc.dupe(u8, data[pos.*..][0..len]);
            pos.* += len;
            return .{ .atom = s };
        },
        CONST_TAG_NIL => .nil,
        CONST_TAG_VOID => .void,
        CONST_TAG_TUPLE => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const elems = try alloc.alloc(ConstValue, len);
            for (0..len) |i| {
                elems[i] = try deserializeConstValue(alloc, data, pos);
            }
            return .{ .tuple = elems };
        },
        CONST_TAG_LIST => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const elems = try alloc.alloc(ConstValue, len);
            for (0..len) |i| {
                elems[i] = try deserializeConstValue(alloc, data, pos);
            }
            return .{ .list = elems };
        },
        CONST_TAG_MAP => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const entry_count = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const entries = try alloc.alloc(ConstValue.ConstMapEntry, entry_count);
            for (0..entry_count) |i| {
                entries[i] = .{
                    .key = try deserializeConstValue(alloc, data, pos),
                    .value = try deserializeConstValue(alloc, data, pos),
                };
            }
            return .{ .map = entries };
        },
        CONST_TAG_STRUCT => {
            // type_name
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const name_len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            if (pos.* + name_len > data.len) return error.UnexpectedEndOfData;
            const type_name = try alloc.dupe(u8, data[pos.*..][0..name_len]);
            pos.* += name_len;
            // fields
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const field_count = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const fields = try alloc.alloc(ConstValue.ConstFieldValue, field_count);
            for (0..field_count) |i| {
                if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
                const fname_len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
                pos.* += 4;
                if (pos.* + fname_len > data.len) return error.UnexpectedEndOfData;
                const fname = try alloc.dupe(u8, data[pos.*..][0..fname_len]);
                pos.* += fname_len;
                fields[i] = .{
                    .name = fname,
                    .value = try deserializeConstValue(alloc, data, pos),
                };
            }
            return .{ .struct_val = .{ .type_name = type_name, .fields = fields } };
        },
        else => return error.UnexpectedEndOfData,
    };
}

const SerializeError = error{
    UnexpectedEndOfData,
    OutOfMemory,
};

fn serializeResult(alloc: std.mem.Allocator, result: CtEvalResult) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    // Magic + version
    try buf.appendSlice(alloc, "CTFE");
    try buf.append(alloc, 2); // version 2: full dependency serialization
    // Value
    try serializeConstValueInto(alloc, &buf, result.value);
    // Result hash
    try buf.appendSlice(alloc, std.mem.asBytes(&result.result_hash));
    // Dependencies
    const dep_count: u32 = @intCast(result.dependencies.len);
    try buf.appendSlice(alloc, std.mem.asBytes(&dep_count));
    for (result.dependencies) |dep| {
        try serializeDependencyInto(alloc, &buf, dep);
    }
    return buf.toOwnedSlice(alloc);
}

fn deserializeResult(alloc: std.mem.Allocator, data: []const u8) SerializeError!CtEvalResult {
    if (data.len < 5) return error.UnexpectedEndOfData;
    if (!std.mem.eql(u8, data[0..4], "CTFE")) return error.UnexpectedEndOfData;
    if (data[4] != 2) return error.UnexpectedEndOfData; // version 2
    var pos: usize = 5;
    const value = try deserializeConstValue(alloc, data, &pos);
    if (pos + 8 > data.len) return error.UnexpectedEndOfData;
    const result_hash = std.mem.readInt(u64, data[pos..][0..8], .little);
    pos += 8;
    // Dependencies
    if (pos + 4 > data.len) return error.UnexpectedEndOfData;
    const dep_count = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;
    const deps = try alloc.alloc(CtDependency, dep_count);
    for (0..dep_count) |i| {
        deps[i] = try deserializeDependency(alloc, data, &pos);
    }
    return .{
        .value = value,
        .dependencies = deps,
        .result_hash = result_hash,
    };
}

/// Create an arena-backed allocator for interpreter tests.
/// The interpreter makes many small allocations (collectLocals, struct fields,
/// error stacks) that are logically tied to the evaluation lifetime. Using an
/// arena mirrors production behavior (GPA+ArenaAllocator freed at process exit).
fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.page_allocator);
}

test "CtValue.isTruthy" {
    try testing.expect((CtValue{ .bool_val = true }).isTruthy());
    try testing.expect(!(CtValue{ .bool_val = false }).isTruthy());
    try testing.expect(!(@as(CtValue, .nil)).isTruthy());
    try testing.expect(!(@as(CtValue, .void)).isTruthy());
    try testing.expect((CtValue{ .int = 1 }).isTruthy());
    try testing.expect(!(CtValue{ .int = 0 }).isTruthy());
    try testing.expect((CtValue{ .int = -1 }).isTruthy());
    try testing.expect((CtValue{ .string = "hello" }).isTruthy());
    try testing.expect((CtValue{ .atom = "ok" }).isTruthy());
}

test "CtValue.eql" {
    try testing.expect((CtValue{ .int = 42 }).eql(.{ .int = 42 }));
    try testing.expect(!(CtValue{ .int = 42 }).eql(.{ .int = 43 }));
    try testing.expect((CtValue{ .string = "abc" }).eql(.{ .string = "abc" }));
    try testing.expect(!(CtValue{ .string = "abc" }).eql(.{ .string = "def" }));
    try testing.expect((CtValue{ .bool_val = true }).eql(.{ .bool_val = true }));
    try testing.expect(!(CtValue{ .bool_val = true }).eql(.{ .bool_val = false }));
    try testing.expect((CtValue{ .atom = "ok" }).eql(.{ .atom = "ok" }));
    try testing.expect(!(CtValue{ .atom = "ok" }).eql(.{ .atom = "error" }));
    try testing.expect((@as(CtValue, .nil)).eql(.nil));
    try testing.expect((@as(CtValue, .void)).eql(.void));
    // Cross-type inequality
    try testing.expect(!(CtValue{ .int = 0 }).eql(.nil));
    try testing.expect(!(CtValue{ .int = 1 }).eql(.{ .bool_val = true }));
}

test "CtValue.compare" {
    try testing.expectEqual(std.math.Order.lt, (CtValue{ .int = 1 }).compare(.{ .int = 2 }).?);
    try testing.expectEqual(std.math.Order.gt, (CtValue{ .int = 2 }).compare(.{ .int = 1 }).?);
    try testing.expectEqual(std.math.Order.eq, (CtValue{ .int = 5 }).compare(.{ .int = 5 }).?);
    try testing.expectEqual(std.math.Order.lt, (CtValue{ .float = 1.0 }).compare(.{ .float = 2.0 }).?);
    // Incomparable types
    try testing.expect((CtValue{ .int = 1 }).compare(.{ .string = "a" }) == null);
}

test "exportValue scalars" {
    const alloc = testing.allocator;
    {
        const result = try exportValue(alloc, .{ .int = 42 });
        try testing.expectEqual(@as(i64, 42), result.int);
    }
    {
        const result = try exportValue(alloc, .{ .bool_val = true });
        try testing.expect(result.bool_val);
    }
    {
        const result = try exportValue(alloc, .nil);
        try testing.expect(result == .nil);
    }
    {
        const result = try exportValue(alloc, .{ .string = "hello" });
        try testing.expectEqualStrings("hello", result.string);
        alloc.free(result.string);
    }
    {
        const result = try exportValue(alloc, .{ .atom = "ok" });
        try testing.expectEqualStrings("ok", result.atom);
        alloc.free(result.atom);
    }
}

test "exportValue tuple" {
    const alloc = testing.allocator;
    const elems = [_]CtValue{ .{ .int = 1 }, .{ .int = 2 } };
    const result = try exportValue(alloc, .{ .tuple = .{ .alloc_id = 1, .elems = &elems } });
    defer alloc.free(result.tuple);
    try testing.expectEqual(@as(usize, 2), result.tuple.len);
    try testing.expectEqual(@as(i64, 1), result.tuple[0].int);
    try testing.expectEqual(@as(i64, 2), result.tuple[1].int);
}

test "exportValue closure fails" {
    const alloc = testing.allocator;
    const result = exportValue(alloc, .{ .closure = .{
        .alloc_id = 1,
        .function_id = 0,
        .captures = &.{},
    } });
    try testing.expectError(error.CannotExport, result);
}

test "constValueToExpr: tuple" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    const cv = ConstValue{ .tuple = &.{
        .{ .int = 1 },
        .{ .int = 2 },
        .{ .int = 3 },
    } };
    const expr = try constValueToExpr(alloc, cv, &interner);
    try testing.expect(expr.* == .tuple);
    try testing.expectEqual(@as(usize, 3), expr.tuple.elements.len);
    try testing.expectEqual(@as(i64, 1), expr.tuple.elements[0].int_literal.value);
}

test "constValueToExpr: list" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    const cv = ConstValue{ .list = &.{
        .{ .int = 10 },
        .{ .int = 20 },
    } };
    const expr = try constValueToExpr(alloc, cv, &interner);
    try testing.expect(expr.* == .list);
    try testing.expectEqual(@as(usize, 2), expr.list.elements.len);
    try testing.expectEqual(@as(i64, 10), expr.list.elements[0].int_literal.value);
}

test "constValueToExpr: map" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    const cv = ConstValue{ .map = &.{
        .{ .key = .{ .atom = "name" }, .value = .{ .string = "zap" } },
    } };
    const expr = try constValueToExpr(alloc, cv, &interner);
    try testing.expect(expr.* == .map);
    try testing.expectEqual(@as(usize, 1), expr.map.fields.len);
    try testing.expect(expr.map.fields[0].key.* == .atom_literal);
    try testing.expect(expr.map.fields[0].value.* == .string_literal);
}

test "constValueToExpr: struct_val" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    const cv = ConstValue{ .struct_val = .{
        .type_name = "Config",
        .fields = &.{
            .{ .name = "port", .value = .{ .int = 8080 } },
        },
    } };
    const expr = try constValueToExpr(alloc, cv, &interner);
    try testing.expect(expr.* == .struct_expr);
    try testing.expectEqual(@as(usize, 1), expr.struct_expr.fields.len);
    try testing.expectEqual(@as(i64, 8080), expr.struct_expr.fields[0].value.int_literal.value);
}

test "constValueToExpr: nested list of tuples" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    const cv = ConstValue{ .list = &.{
        .{ .tuple = &.{ .{ .int = 1 }, .{ .int = 2 } } },
    } };
    const expr = try constValueToExpr(alloc, cv, &interner);
    try testing.expect(expr.* == .list);
    try testing.expect(expr.list.elements[0].* == .tuple);
    try testing.expectEqual(@as(usize, 2), expr.list.elements[0].tuple.elements.len);
}

test "importConstValue: aggregates round-trip" {
    const alloc = testing.allocator;
    // Test tuple round-trip through export→import
    const ct_tuple = CtValue{ .tuple = .{ .alloc_id = 1, .elems = &.{ .{ .int = 1 }, .{ .int = 2 } } } };
    const exported = try exportValue(alloc, ct_tuple);
    defer alloc.free(exported.tuple);
    const imported = Interpreter.importConstValue(exported);
    try testing.expect(imported == .tuple);
    try testing.expectEqual(@as(usize, 2), imported.tuple.elems.len);
    try testing.expectEqual(@as(i64, 1), imported.tuple.elems[0].int);
}

test "interpreter: constants" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: binary_op add" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "add_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } },
                .{ .const_int = .{ .dest = 1, .value = 32 } },
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: if_expr true branch" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "if_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_bool = .{ .dest = 0, .value = true } },
                .{ .if_expr = .{
                    .dest = 1,
                    .condition = 0,
                    .then_instrs = &.{
                        .{ .const_int = .{ .dest = 2, .value = 100 } },
                    },
                    .then_result = 2,
                    .else_instrs = &.{
                        .{ .const_int = .{ .dest = 3, .value = 200 } },
                    },
                    .else_result = 3,
                } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 100), result.int);
}

test "interpreter: if_expr false branch" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "if_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_bool = .{ .dest = 0, .value = false } },
                .{ .if_expr = .{
                    .dest = 1,
                    .condition = 0,
                    .then_instrs = &.{
                        .{ .const_int = .{ .dest = 2, .value = 100 } },
                    },
                    .then_result = 2,
                    .else_instrs = &.{
                        .{ .const_int = .{ .dest = 3, .value = 200 } },
                    },
                    .else_result = 3,
                } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 200), result.int);
}

test "interpreter: param_get" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "identity",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalByName("identity", &.{.{ .int = 99 }});
    try testing.expectEqual(@as(i64, 99), result.int);
}

test "interpreter: call_direct between functions" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    // Function 0: returns 7
    const inner = ir.Function{
        .id = 0,
        .name = "inner",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 7 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    // Function 1: calls inner and adds 3
    const outer = ir.Function{
        .id = 1,
        .name = "outer",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .call_direct = .{ .dest = 0, .function = 0, .args = &.{}, .arg_modes = &.{} } },
                .{ .const_int = .{ .dest = 1, .value = 3 } },
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{ inner, outer };
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(1, &.{});
    try testing.expectEqual(@as(i64, 10), result.int);
}

test "interpreter: call_named" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const callee = ir.Function{
        .id = 0,
        .name = "helper",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .const_int = .{ .dest = 1, .value = 1 } },
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const caller = ir.Function{
        .id = 1,
        .name = "main",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 5 } },
                .{ .call_named = .{ .dest = 1, .name = "helper", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{ callee, caller };
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalByName("main", &.{});
    try testing.expectEqual(@as(i64, 6), result.int);
}

test "interpreter: struct_init and field_get" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "struct_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .const_string = .{ .dest = 1, .value = "hello" } },
                .{ .struct_init = .{
                    .dest = 2,
                    .type_name = "MyStruct",
                    .fields = &.{
                        .{ .name = "x", .value = 0 },
                        .{ .name = "y", .value = 1 },
                    },
                } },
                .{ .field_get = .{ .dest = 3, .object = 2, .field = "x" } },
                .{ .ret = .{ .value = 3 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: step budget exceeded" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    // Recursive function that will exceed step budget
    const func = ir.Function{
        .id = 0,
        .name = "infinite",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .call_named = .{ .dest = 0, .name = "infinite", .args = &.{}, .arg_modes = &.{} } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.step_budget = 100;
    interp.steps_remaining = 100;
    interp.recursion_limit = 1000; // high limit so step budget hits first

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expect(interp.errors.items.len > 0);
}

test "interpreter: recursion limit exceeded" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "infinite",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .call_named = .{ .dest = 0, .name = "infinite", .args = &.{}, .arg_modes = &.{} } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.recursion_limit = 5;
    interp.step_budget = 1_000_000;
    interp.steps_remaining = 1_000_000;

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expect(interp.errors.items.len > 0);
    try testing.expectEqual(CtfeErrorKind.recursion_limit_exceeded, interp.errors.items[0].kind);
}

test "interpreter: switch_return dispatch" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    // Function that switches on param 0 (integer)
    const func = ir.Function{
        .id = 0,
        .name = "dispatch",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .switch_return = .{
                    .scrutinee_param = 0,
                    .cases = &.{
                        .{
                            .value = .{ .int = 1 },
                            .body_instrs = &.{
                                .{ .const_int = .{ .dest = 0, .value = 100 } },
                            },
                            .return_value = 0,
                        },
                        .{
                            .value = .{ .int = 2 },
                            .body_instrs = &.{
                                .{ .const_int = .{ .dest = 0, .value = 200 } },
                            },
                            .return_value = 0,
                        },
                    },
                    .default_instrs = &.{
                        .{ .const_int = .{ .dest = 0, .value = 999 } },
                    },
                    .default_result = 0,
                } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const r1 = try interp.evalFunction(0, &.{.{ .int = 1 }});
    try testing.expectEqual(@as(i64, 100), r1.int);

    interp.steps_remaining = interp.step_budget;
    const r2 = try interp.evalFunction(0, &.{.{ .int = 2 }});
    try testing.expectEqual(@as(i64, 200), r2.int);

    interp.steps_remaining = interp.step_budget;
    const r3 = try interp.evalFunction(0, &.{.{ .int = 99 }});
    try testing.expectEqual(@as(i64, 999), r3.int);
}

test "interpreter: branch between blocks" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "branch_blocks",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{
            .{ .label = 0, .instructions = &.{.{ .branch = .{ .target = 1 } }} },
            .{ .label = 1, .instructions = &.{ .{ .const_int = .{ .dest = 0, .value = 42 } }, .{ .ret = .{ .value = 0 } } } },
        },
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: cond_branch between blocks" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "cond_branch_blocks",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{
            .{ .label = 0, .instructions = &.{
                .{ .const_bool = .{ .dest = 0, .value = true } },
                .{ .cond_branch = .{ .condition = 0, .then_target = 1, .else_target = 2 } },
            } },
            .{ .label = 1, .instructions = &.{ .{ .const_int = .{ .dest = 1, .value = 42 } }, .{ .ret = .{ .value = 1 } } } },
            .{ .label = 2, .instructions = &.{ .{ .const_int = .{ .dest = 1, .value = 0 } }, .{ .ret = .{ .value = 1 } } } },
        },
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: switch_tag dispatch" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const payload = try alloc.create(CtValue);
    payload.* = .{ .int = 42 };
    const union_value = CtValue{ .union_val = .{ .alloc_id = 1, .type_name = "Option", .variant = "some", .payload = payload } };
    const func = ir.Function{
        .id = 0,
        .name = "switch_tag_blocks",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .any }},
        .return_type = .i64,
        .body = &.{
            .{ .label = 0, .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .switch_tag = .{ .scrutinee = 0, .cases = &.{.{ .tag = "some", .target = 1 }}, .default = 2 } },
            } },
            .{ .label = 1, .instructions = &.{ .{ .const_int = .{ .dest = 1, .value = 42 } }, .{ .ret = .{ .value = 1 } } } },
            .{ .label = 2, .instructions = &.{ .{ .const_int = .{ .dest = 1, .value = 0 } }, .{ .ret = .{ .value = 1 } } } },
        },
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{union_value});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: phi selects predecessor value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "phi_blocks",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{
            .{ .label = 0, .instructions = &.{
                .{ .const_bool = .{ .dest = 0, .value = true } },
                .{ .cond_branch = .{ .condition = 0, .then_target = 1, .else_target = 2 } },
            } },
            .{ .label = 1, .instructions = &.{ .{ .const_int = .{ .dest = 1, .value = 42 } }, .{ .branch = .{ .target = 3 } } } },
            .{ .label = 2, .instructions = &.{ .{ .const_int = .{ .dest = 2, .value = 0 } }, .{ .branch = .{ .target = 3 } } } },
            .{ .label = 3, .instructions = &.{
                .{ .phi = .{ .dest = 3, .sources = &.{ .{ .from_block = 1, .value = 1 }, .{ .from_block = 2, .value = 2 } } } },
                .{ .ret = .{ .value = 3 } },
            } },
        },
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: division by zero" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "div_zero",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } },
                .{ .const_int = .{ .dest = 1, .value = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .div, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.division_by_zero, interp.errors.items[0].kind);
}

test "interpreter: error records failing instruction index" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "div_idx",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } },
                .{ .const_int = .{ .dest = 1, .value = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .div, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(@as(usize, 1), interp.errors.items.len);
    try testing.expectEqual(@as(usize, 1), interp.errors.items[0].call_stack.len);
    try testing.expectEqual(@as(usize, 2), interp.errors.items[0].call_stack[0].instruction_index);
}

test "interpreter: error captures function source span provenance" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const fn_name = try interner.intern("div_idx");

    var graph = scope.ScopeGraph.init(alloc);
    defer graph.deinit();

    const mod_scope = try graph.createScope(0, .module);
    const family_id = try graph.createFamily(mod_scope, fn_name, 0, .public);

    const clause_span = ast.SourceSpan{ .start = 10, .end = 20, .line = 7, .col = 3 };
    const clauses = try alloc.alloc(ast.FunctionClause, 1);
    clauses[0] = .{
        .meta = .{ .span = clause_span },
        .params = &.{},
        .return_type = null,
        .refinement = null,
        .body = &.{},
    };
    const decl = try alloc.create(ast.FunctionDecl);
    decl.* = .{
        .meta = .{ .span = clause_span },
        .name = fn_name,
        .clauses = clauses,
        .visibility = .public,
    };
    try graph.getFamilyMut(family_id).clauses.append(alloc, .{ .decl = decl, .clause_index = 0 });

    const func = ir.Function{
        .id = 0,
        .name = "div_idx",
        .scope_id = mod_scope,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } },
                .{ .const_int = .{ .dest = 1, .value = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .div, .lhs = 0, .rhs = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const program = makeTestProgram(&.{func});

    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.scope_graph = &graph;
    interp.interner = &interner;

    try testing.expectError(error.CtfeFailure, interp.evalFunction(0, &.{}));
    try testing.expect(interp.errors.items[0].call_stack[0].source_span != null);
    try testing.expectEqual(@as(u32, 7), interp.errors.items[0].call_stack[0].source_span.?.line);
    try testing.expectEqual(@as(u32, 3), interp.errors.items[0].call_stack[0].source_span.?.col);
}

test "interpreter: match_atom" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "match_fn",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .atom }},
        .return_type = .bool_type,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .match_atom = .{ .dest = 1, .scrutinee = 0, .atom_name = "ok" } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const r1 = try interp.evalFunction(0, &.{.{ .atom = "ok" }});
    try testing.expect(r1.bool_val);

    interp.steps_remaining = interp.step_budget;
    const r2 = try interp.evalFunction(0, &.{.{ .atom = "error" }});
    try testing.expect(!r2.bool_val);
}

test "interpreter: tuple_init and index_get" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "tuple_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } },
                .{ .const_int = .{ .dest = 1, .value = 20 } },
                .{ .tuple_init = .{ .dest = 2, .elements = &.{ 0, 1 } } },
                .{ .index_get = .{ .dest = 3, .object = 2, .index = 1 } },
                .{ .ret = .{ .value = 3 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 20), result.int);
}

test "CapabilitySet" {
    const pure = CapabilitySet.pure_only;
    try testing.expect(!pure.has(.read_file));
    try testing.expect(!pure.has(.read_env));

    const build = CapabilitySet.build;
    try testing.expect(build.has(.pure));
    try testing.expect(build.has(.read_file));
    try testing.expect(build.has(.read_env));
    try testing.expect(build.has(.reflect_module));

    const with_reflect = pure.with(.reflect_module);
    try testing.expect(with_reflect.has(.reflect_module));
    try testing.expect(!with_reflect.has(.read_file));
}

test "interpreter: make_closure and call_closure" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    // Function 0: closure body — returns captured value + arg
    const closure_body = ir.Function{
        .id = 0,
        .name = "closure_body",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "y", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .capture_get = .{ .dest = 0, .index = 0 } }, // captured x
                .{ .param_get = .{ .dest = 1, .index = 0 } }, // arg y
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = true,
        .captures = &.{.{ .name = "x", .type_expr = .i64, .ownership = .shared }},
        .local_count = 3,
    };
    // Function 1: creates closure capturing x=10, calls it with y=5
    const outer = ir.Function{
        .id = 1,
        .name = "outer",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } }, // x = 10
                .{ .make_closure = .{ .dest = 1, .function = 0, .captures = &.{0} } },
                .{ .const_int = .{ .dest = 2, .value = 5 } }, // y = 5
                .{ .call_closure = .{
                    .dest = 3,
                    .callee = 1,
                    .args = &.{2},
                    .arg_modes = &.{.share},
                    .return_type = .i64,
                } },
                .{ .ret = .{ .value = 3 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{ closure_body, outer };
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(1, &.{});
    try testing.expectEqual(@as(i64, 15), result.int); // 10 + 5
}

test "evaluateComputedAttributes: call expression" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build an IR function: Foo__compute returns 42
    const compute_fn = ir.Function{
        .id = 0,
        .name = "Foo__compute",
        .scope_id = 1,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{compute_fn};
    const program = makeTestProgram(&functions);

    // Build a scope graph with a module "Foo" and an attribute @config = compute()
    var graph = scope.ScopeGraph.init(alloc);

    // Create module scope (child of prelude)
    const mod_scope = try graph.createScope(0, .module);

    // Intern strings
    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const config_id = try interner.intern("config");
    const compute_id = try interner.intern("compute");

    // Build the AST call expression: compute()
    const callee_expr = try alloc.create(ast.Expr);
    callee_expr.* = .{ .var_ref = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = compute_id,
    } };
    const call_expr = try alloc.create(ast.Expr);
    call_expr.* = .{ .call = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .callee = callee_expr,
        .args = &.{},
    } };

    // Create a stub module decl (needed for ModuleEntry)
    const mod_decl = try alloc.create(ast.ModuleDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    // Register the module with the attribute
    try graph.modules.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });

    // Add the @config attribute with call expression value
    graph.modules.items[0].attributes.append(alloc, .{
        .name = config_id,
        .value = call_expr,
    }) catch {};

    // Run CTFE evaluation
    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 1), result.evaluated);
    try testing.expectEqual(@as(u32, 0), result.failed);

    // Verify the computed value was stored
    const attr = &graph.modules.items[0].attributes.items[0];
    try testing.expect(attr.computed_value != null);
    try testing.expectEqual(@as(i64, 42), attr.computed_value.?.int);
}

test "evaluateComputedAttributes: failing attribute records attribute context" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const compute_fn = ir.Function{
        .id = 0,
        .name = "Foo__compute",
        .scope_id = 1,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .const_int = .{ .dest = 1, .value = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .div, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{compute_fn};
    const program = makeTestProgram(&functions);

    var graph = scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .module);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const config_id = try interner.intern("config");
    const compute_id = try interner.intern("compute");

    const callee_expr = try alloc.create(ast.Expr);
    callee_expr.* = .{ .var_ref = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = compute_id,
    } };
    const call_expr = try alloc.create(ast.Expr);
    call_expr.* = .{ .call = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .callee = callee_expr,
        .args = &.{},
    } };

    const mod_decl = try alloc.create(ast.ModuleDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.modules.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.modules.items[0].attributes.append(alloc, .{
        .name = config_id,
        .value = call_expr,
    }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 0), result.evaluated);
    try testing.expectEqual(@as(u32, 1), result.failed);
    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expect(result.errors[0].attribute_context != null);
    try testing.expectEqualStrings("config", result.errors[0].attribute_context.?.attr_name);
    try testing.expectEqualStrings("Foo", result.errors[0].attribute_context.?.module_name);
}

test "evaluateComputedAttributes: binary expression value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);

    var graph = scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .module);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const config_id = try interner.intern("config");

    const lhs = try alloc.create(ast.Expr);
    lhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 40 } };
    const rhs = try alloc.create(ast.Expr);
    rhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 2 } };
    const expr = try alloc.create(ast.Expr);
    expr.* = .{ .binary_op = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .op = .add,
        .lhs = lhs,
        .rhs = rhs,
    } };

    const mod_decl = try alloc.create(ast.ModuleDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.modules.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.modules.items[0].attributes.append(alloc, .{
        .name = config_id,
        .value = expr,
    }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 1), result.evaluated);
    try testing.expectEqual(@as(u32, 0), result.failed);
    try testing.expectEqual(@as(i64, 42), graph.modules.items[0].attributes.items[0].computed_value.?.int);
}

test "evaluateComputedAttributes: call expression with computed args" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const compute_fn = ir.Function{
        .id = 0,
        .name = "Foo__compute",
        .scope_id = 1,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{compute_fn};
    const program = makeTestProgram(&functions);

    var graph = scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .module);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const config_id = try interner.intern("config");
    const compute_id = try interner.intern("compute");

    const lhs = try alloc.create(ast.Expr);
    lhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 40 } };
    const rhs = try alloc.create(ast.Expr);
    rhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 2 } };
    const arg_expr = try alloc.create(ast.Expr);
    arg_expr.* = .{ .binary_op = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .op = .add,
        .lhs = lhs,
        .rhs = rhs,
    } };

    const callee_expr = try alloc.create(ast.Expr);
    callee_expr.* = .{ .var_ref = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = compute_id,
    } };
    const call_expr = try alloc.create(ast.Expr);
    call_expr.* = .{ .call = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .callee = callee_expr,
        .args = &.{arg_expr},
    } };

    const mod_decl = try alloc.create(ast.ModuleDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.modules.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.modules.items[0].attributes.append(alloc, .{
        .name = config_id,
        .value = call_expr,
    }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 1), result.evaluated);
    try testing.expectEqual(@as(u32, 0), result.failed);
    try testing.expectEqual(@as(i64, 42), graph.modules.items[0].attributes.items[0].computed_value.?.int);
}

test "evaluateComputedAttributes: attr_ref can use earlier computed attribute" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);

    var graph = scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .module);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const base_id = try interner.intern("base");
    const config_id = try interner.intern("config");

    const base_expr = try alloc.create(ast.Expr);
    base_expr.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 40 } };

    const attr_ref_expr = try alloc.create(ast.Expr);
    attr_ref_expr.* = .{ .attr_ref = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = base_id,
    } };
    const rhs = try alloc.create(ast.Expr);
    rhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 2 } };
    const config_expr = try alloc.create(ast.Expr);
    config_expr.* = .{ .binary_op = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .op = .add,
        .lhs = attr_ref_expr,
        .rhs = rhs,
    } };

    const mod_decl = try alloc.create(ast.ModuleDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.modules.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.modules.items[0].attributes.append(alloc, .{ .name = base_id, .value = base_expr }) catch {};
    graph.modules.items[0].attributes.append(alloc, .{ .name = config_id, .value = config_expr }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 2), result.evaluated);
    try testing.expectEqual(@as(u32, 0), result.failed);
    try testing.expectEqual(@as(i64, 42), graph.modules.items[0].attributes.items[1].computed_value.?.int);
}

test "tryEvalAttribute: literal int value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);

    var graph = scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .module);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const port_id = try interner.intern("port");

    // Build literal expression: 8080
    const lit_expr = try alloc.create(ast.Expr);
    lit_expr.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 8080 } };

    const mod_decl = try alloc.create(ast.ModuleDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.modules.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.modules.items[0].attributes.append(alloc, .{
        .name = port_id,
        .value = lit_expr,
    }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 1), result.evaluated);

    const attr = &graph.modules.items[0].attributes.items[0];
    try testing.expect(attr.computed_value != null);
    try testing.expectEqual(@as(i64, 8080), attr.computed_value.?.int);
}

test "tryEvalAttribute: literal string value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);

    var graph = scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .module);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const name_id = try interner.intern("app_name");
    const val_id = try interner.intern("myapp");

    const lit_expr = try alloc.create(ast.Expr);
    lit_expr.* = .{ .string_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = val_id } };

    const mod_decl = try alloc.create(ast.ModuleDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.modules.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.modules.items[0].attributes.append(alloc, .{
        .name = name_id,
        .value = lit_expr,
    }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 1), result.evaluated);

    const attr = &graph.modules.items[0].attributes.items[0];
    try testing.expect(attr.computed_value != null);
    try testing.expectEqualStrings("myapp", attr.computed_value.?.string);
}

test "interpreter: field_set on struct" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "field_set_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .const_int = .{ .dest = 1, .value = 2 } },
                .{ .struct_init = .{
                    .dest = 2,
                    .type_name = "S",
                    .fields = &.{
                        .{ .name = "a", .value = 0 },
                        .{ .name = "b", .value = 1 },
                    },
                } },
                .{ .const_int = .{ .dest = 3, .value = 99 } },
                .{ .field_set = .{ .object = 2, .field = "b", .value = 3 } },
                .{ .field_get = .{ .dest = 4, .object = 2, .field = "b" } },
                .{ .ret = .{ .value = 4 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 99), result.int);
}

test "interpreter: bin_len_check" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "bin_fn",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "data", .type_expr = .string }},
        .return_type = .bool_type,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .bin_len_check = .{ .dest = 1, .scrutinee = 0, .min_len = 3 } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const r1 = try interp.evalFunction(0, &.{.{ .string = "hello" }});
    try testing.expect(r1.bool_val); // 5 >= 3

    interp.steps_remaining = interp.step_budget;
    const r2 = try interp.evalFunction(0, &.{.{ .string = "ab" }});
    try testing.expect(!r2.bool_val); // 2 < 3
}

test "interpreter: bin_match_prefix" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "prefix_fn",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "data", .type_expr = .string }},
        .return_type = .bool_type,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .bin_match_prefix = .{ .dest = 1, .source = 0, .expected = "hel" } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const r1 = try interp.evalFunction(0, &.{.{ .string = "hello" }});
    try testing.expect(r1.bool_val);

    interp.steps_remaining = interp.step_budget;
    const r2 = try interp.evalFunction(0, &.{.{ .string = "world" }});
    try testing.expect(!r2.bool_val);
}

test "interpreter: bin_slice" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "slice_fn",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "data", .type_expr = .string }},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .bin_slice = .{ .dest = 1, .source = 0, .offset = .{ .static = 6 }, .length = null } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{.{ .string = "hello world" }});
    try testing.expectEqualStrings("world", result.string);
}

test "memoization: cache hit on second call" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "expensive",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .const_int = .{ .dest = 1, .value = 1 } },
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    // First call — executes function body, consumes steps
    const r1 = try interp.evalFunction(0, &.{.{ .int = 10 }});
    try testing.expectEqual(@as(i64, 11), r1.int);
    const steps_after_first = interp.steps_remaining;

    // Second call with same args — should hit cache, no steps consumed
    const r2 = try interp.evalFunction(0, &.{.{ .int = 10 }});
    try testing.expectEqual(@as(i64, 11), r2.int);
    try testing.expectEqual(steps_after_first, interp.steps_remaining);

    // Third call with different args — cache miss, steps consumed
    const r3 = try interp.evalFunction(0, &.{.{ .int = 20 }});
    try testing.expectEqual(@as(i64, 21), r3.int);
    try testing.expect(interp.steps_remaining < steps_after_first);
}

test "CtValue.hash consistency" {
    const a = CtValue{ .int = 42 };
    const b = CtValue{ .int = 42 };
    const c = CtValue{ .int = 43 };
    try testing.expectEqual(a.hash(), b.hash());
    try testing.expect(a.hash() != c.hash());

    const s1 = CtValue{ .string = "hello" };
    const s2 = CtValue{ .string = "hello" };
    const s3 = CtValue{ .string = "world" };
    try testing.expectEqual(s1.hash(), s2.hash());
    try testing.expect(s1.hash() != s3.hash());
}

test "persistent cache: serialize/deserialize round-trip" {
    const alloc = testing.allocator;

    // Test integer
    {
        const result = CtEvalResult{
            .value = .{ .int = 42 },
            .dependencies = &.{},
            .result_hash = 12345,
        };
        const data = try serializeResult(alloc, result);
        defer alloc.free(data);
        const restored = try deserializeResult(alloc, data);
        try testing.expectEqual(@as(i64, 42), restored.value.int);
        try testing.expectEqual(@as(u64, 12345), restored.result_hash);
    }

    // Test string
    {
        const result = CtEvalResult{
            .value = .{ .string = "hello" },
            .dependencies = &.{},
            .result_hash = 67890,
        };
        const data = try serializeResult(alloc, result);
        defer alloc.free(data);
        const restored = try deserializeResult(alloc, data);
        try testing.expectEqualStrings("hello", restored.value.string);
        alloc.free(restored.value.string);
    }

    // Test bool
    {
        const result = CtEvalResult{
            .value = .{ .bool_val = true },
            .dependencies = &.{},
            .result_hash = 0,
        };
        const data = try serializeResult(alloc, result);
        defer alloc.free(data);
        const restored = try deserializeResult(alloc, data);
        try testing.expect(restored.value.bool_val);
    }

    // Test nil
    {
        const result = CtEvalResult{
            .value = .nil,
            .dependencies = &.{},
            .result_hash = 0,
        };
        const data = try serializeResult(alloc, result);
        defer alloc.free(data);
        const restored = try deserializeResult(alloc, data);
        try testing.expect(restored.value == .nil);
    }
}

test "persistent cache key includes option hash" {
    const key_a = PersistentCache.cacheKeyFor("manifest", 999, 123, CapabilitySet.build.flags, 111);
    const key_b = PersistentCache.cacheKeyFor("manifest", 999, 123, CapabilitySet.build.flags, 222);

    try testing.expect(key_a != key_b);
}

test "function identity hash changes when function body changes" {
    const func_a = ir.Function{
        .id = 0,
        .name = "f",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{ .{ .const_int = .{ .dest = 0, .value = 1 } }, .{ .ret = .{ .value = 0 } } },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const func_b = ir.Function{
        .id = 0,
        .name = "f",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{ .{ .const_int = .{ .dest = 0, .value = 2 } }, .{ .ret = .{ .value = 0 } } },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };

    try testing.expect(hashFunctionIdentity(&func_a) != hashFunctionIdentity(&func_b));
}

test "persistent cache key includes function identity hash" {
    const key_a = PersistentCache.cacheKeyFor("manifest", 111, 123, CapabilitySet.build.flags, 999);
    const key_b = PersistentCache.cacheKeyFor("manifest", 222, 123, CapabilitySet.build.flags, 999);

    try testing.expect(key_a != key_b);
}

test "capability enforcement: File.read without read_file" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    // Function that calls File.read builtin
    const func = ir.Function{
        .id = 0,
        .name = "read_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "test.txt" } },
                .{ .call_builtin = .{ .dest = 1, .name = "File.read", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only; // NO read_file

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expect(interp.errors.items.len > 0);
    try testing.expectEqual(CtfeErrorKind.capability_violation, interp.errors.items[0].kind);
}

test "capability enforcement: System.get_env without read_env" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "env_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "HOME" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_env", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only;

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.capability_violation, interp.errors.items[0].kind);
}

test "dependency tracking: env read records dependency" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "env_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "CTFE_TEST_VAR" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_env", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.build; // has read_env

    _ = try interp.evalFunction(0, &.{});
    // Should have recorded an env_var dependency
    try testing.expect(interp.dependencies.items.len > 0);
    try testing.expect(interp.dependencies.items[0] == .env_var);
}

test "ownership: use after move fails" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "move_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .move_value = .{ .dest = 1, .source = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.use_after_consume, interp.errors.items[0].kind);
}

test "ownership: use after release fails" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "release_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .release = .{ .value = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.use_after_consume, interp.errors.items[0].kind);
}

test "ownership: binary_op on moved value fails" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "move_binary_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 40 } },
                .{ .move_value = .{ .dest = 1, .source = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.use_after_consume, interp.errors.items[0].kind);
}

test "ownership: retain on moved value fails" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "retain_move_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .move_value = .{ .dest = 1, .source = 0 } },
                .{ .retain = .{ .value = 0 } },
                .{ .ret = .{ .value = null } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.use_after_consume, interp.errors.items[0].kind);
}

test "ownership: reset returns reuse token for aggregate and reuse_alloc consumes it" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "reuse_token_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .bool_type,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .list_init = .{ .dest = 1, .elements = &.{0} } },
                .{ .reset = .{ .dest = 2, .source = 1 } },
                .{ .reuse_alloc = .{ .dest = 3, .token = 2, .constructor_tag = 0, .dest_type = .any } },
                .{ .local_get = .{ .dest = 4, .source = 2 } },
                .{ .ret = .{ .value = 4 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.use_after_consume, interp.errors.items[0].kind);
}

test "ownership: reuse_alloc rejects non-token value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "bad_reuse_token_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .reuse_alloc = .{ .dest = 1, .token = 0, .constructor_tag = 0, .dest_type = .any } },
                .{ .ret = .{ .value = null } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.type_error, interp.errors.items[0].kind);
}

test "symbolic memory: reuse preserves alloc id for matching aggregate kind" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "reuse_preserve_alloc_id_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .list_init = .{ .dest = 1, .elements = &.{0} } },
                .{ .reset = .{ .dest = 2, .source = 1 } },
                .{ .reuse_alloc = .{ .dest = 3, .token = 2, .constructor_tag = 0, .dest_type = .any } },
                .{ .list_init = .{ .dest = 3, .elements = &.{0} } },
                .{ .ret = .{ .value = 3 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(u32, 1), interp.allocation_store.count());
    try testing.expectEqual(@as(AllocId, 1), result.list.alloc_id);
}

test "symbolic memory: reuse falls back to fresh alloc for mismatched kind" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "reuse_kind_mismatch_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .list_init = .{ .dest = 1, .elements = &.{0} } },
                .{ .reset = .{ .dest = 2, .source = 1 } },
                .{ .reuse_alloc = .{ .dest = 3, .token = 2, .constructor_tag = 0, .dest_type = .any } },
                .{ .tuple_init = .{ .dest = 3, .elements = &.{0} } },
                .{ .ret = .{ .value = 3 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expect(result == .tuple);
    try testing.expectEqual(@as(u32, 2), interp.allocation_store.count());
    try testing.expectEqual(@as(AllocId, 2), result.tuple.alloc_id);
}

test "symbolic memory: fresh aggregate allocations get distinct alloc ids" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "alloc_ids_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .list_init = .{ .dest = 1, .elements = &.{0} } },
                .{ .list_init = .{ .dest = 2, .elements = &.{0} } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    _ = try interp.evalFunction(0, &.{});
    try testing.expect(interp.allocation_store.count() >= 2);
}

test "evalAndExport returns CtEvalResult" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "export_fn",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalAndExport(0, &.{.{ .int = 99 }}, CapabilitySet.pure_only);
    try testing.expectEqual(@as(i64, 99), result.value.int);
    try testing.expect(result.result_hash != 0);
}

test "evalAndExport copies dependency slice out of interpreter storage" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const func = ir.Function{
        .id = 0,
        .name = "export_dep_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "CTFE_TEST_VAR" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_env", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalAndExport(0, &.{}, CapabilitySet.build);
    try testing.expect(result.dependencies.len > 0);
    try testing.expect(result.dependencies[0] == .env_var);
    try testing.expect(result.dependencies.ptr != interp.dependencies.items.ptr);
}

test "rich diagnostics: formatCtfeError" {
    const alloc = testing.allocator;
    const err = CtfeError{
        .message = "step limit exceeded",
        .kind = .step_limit_exceeded,
        .call_stack = &.{
            .{ .function_name = "Config__generate", .function_id = 0, .instruction_index = 0, .source_span = .{ .start = 10, .end = 20, .line = 12, .col = 4 } },
        },
        .attribute_context = .{ .attr_name = "config", .module_name = "App" },
    };
    const formatted = try formatCtfeError(alloc, err);
    defer alloc.free(formatted);
    // Verify it contains the key pieces
    try testing.expect(std.mem.indexOf(u8, formatted, "step limit exceeded") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Config__generate") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "12:4") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "@config") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "App") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "help:") != null);
}

test "cache key includes explicit compile options hash" {
    var build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer build_opts.deinit(testing.allocator);

    const native_debug = hashEvaluationOptions(hashCompileOptions("native", "debug"), build_opts);
    const wasm_debug = hashEvaluationOptions(hashCompileOptions("wasm32", "debug"), build_opts);

    try testing.expect(native_debug != wasm_debug);
}

test "validateDependencies: no deps returns true" {
    const alloc = testing.allocator;
    try testing.expect(PersistentCache.validateDependencies(alloc, &.{}, null, null));
}

test "validateDependencies: env_var absent stays absent" {
    const alloc = testing.allocator;
    // A dependency on an env var that was absent — should validate if still absent
    const deps = [_]CtDependency{
        .{ .env_var = .{ .name = "CTFE_TEST_NONEXISTENT_VAR_12345", .value_hash = 0, .present = false } },
    };
    try testing.expect(PersistentCache.validateDependencies(alloc, &deps, null, null));
}

test "validateDependencies: reflected_module invalidates without graph" {
    const alloc = testing.allocator;
    const deps = [_]CtDependency{
        .{ .reflected_module = .{ .module_name = "Test", .interface_hash = 0 } },
    };
    try testing.expect(!PersistentCache.validateDependencies(alloc, &deps, null, null));
}

test "validateDependencies: reflected_module validates against matching graph" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .module);
    var interner = ast.StringInterner.init(alloc);
    const test_id = try interner.intern("Test");

    const mod_decl = try alloc.create(ast.ModuleDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{test_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };
    try graph.modules.append(alloc, .{
        .name = .{ .parts = &.{test_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });

    const iface_hash = computeModuleInterfaceHash(&graph, mod_scope, &interner, "Test");
    const deps = [_]CtDependency{
        .{ .reflected_module = .{ .module_name = "Test", .interface_hash = iface_hash } },
    };
    try testing.expect(PersistentCache.validateDependencies(alloc, &deps, &graph, &interner));
}

test "validateDependencies: reflected_module invalidates on interface change" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .module);
    var interner = ast.StringInterner.init(alloc);
    const test_id = try interner.intern("Test");
    const config_id = try interner.intern("config");

    const mod_decl = try alloc.create(ast.ModuleDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{test_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };
    try graph.modules.append(alloc, .{
        .name = .{ .parts = &.{test_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.modules.items[0].attributes.append(alloc, .{
        .name = config_id,
        .computed_value = .{ .int = 1 },
    }) catch {};

    const iface_hash = computeModuleInterfaceHash(&graph, mod_scope, &interner, "Test");
    const deps = [_]CtDependency{
        .{ .reflected_module = .{ .module_name = "Test", .interface_hash = iface_hash } },
    };

    graph.modules.items[0].attributes.items[0].computed_value = .{ .int = 2 };
    try testing.expect(!PersistentCache.validateDependencies(alloc, &deps, &graph, &interner));
}

test "builtin: string concat" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "hello" } },
                .{ .const_string = .{ .dest = 1, .value = " world" } },
                .{ .binary_op = .{ .dest = 2, .lhs = 0, .rhs = 1, .op = .concat } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("hello world", result.string);
}

test "builtin: list concat" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .list_init = .{ .dest = 1, .elements = &.{0} } },
                .{ .const_int = .{ .dest = 2, .value = 2 } },
                .{ .list_init = .{ .dest = 3, .elements = &.{2} } },
                .{ .binary_op = .{ .dest = 4, .lhs = 1, .rhs = 3, .op = .concat } },
                .{ .ret = .{ .value = 4 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.elems.len);
    try testing.expectEqual(@as(i64, 1), result.list.elems[0].int);
    try testing.expectEqual(@as(i64, 2), result.list.elems[1].int);
}

test "builtin: atom_name" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_atom = .{ .dest = 0, .value = "hello" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.atom_name", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("hello", result.string);
}

test "builtin: i64_to_string" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.i64_to_string", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("42", result.string);
}

test "builtin: to_atom" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .atom,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "world" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.to_atom", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("world", result.atom);
}

test "builtin: println is no-op" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "hello" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.println", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("hello", result.string);
}

test "serialize/deserialize map round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]ConstValue.ConstMapEntry{
        .{ .key = .{ .atom = "name" }, .value = .{ .string = "zap" } },
        .{ .key = .{ .atom = "version" }, .value = .{ .int = 1 } },
    };
    const original = ConstValue{ .map = &entries };
    const data = try serializeConstValue(alloc, original);
    var pos: usize = 0;
    const restored = try deserializeConstValue(alloc, data, &pos);
    try testing.expect(restored == .map);
    try testing.expectEqual(@as(usize, 2), restored.map.len);
    try testing.expectEqualStrings("name", restored.map[0].key.atom);
    try testing.expectEqualStrings("zap", restored.map[0].value.string);
    try testing.expectEqualStrings("version", restored.map[1].key.atom);
    try testing.expectEqual(@as(i64, 1), restored.map[1].value.int);
}

test "serialize/deserialize struct round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const fields = [_]ConstValue.ConstFieldValue{
        .{ .name = "host", .value = .{ .string = "localhost" } },
        .{ .name = "port", .value = .{ .int = 8080 } },
        .{ .name = "debug", .value = .{ .bool_val = true } },
    };
    const original = ConstValue{ .struct_val = .{
        .type_name = "Config",
        .fields = &fields,
    } };
    const data = try serializeConstValue(alloc, original);
    var pos: usize = 0;
    const restored = try deserializeConstValue(alloc, data, &pos);
    try testing.expect(restored == .struct_val);
    try testing.expectEqualStrings("Config", restored.struct_val.type_name);
    try testing.expectEqual(@as(usize, 3), restored.struct_val.fields.len);
    try testing.expectEqualStrings("host", restored.struct_val.fields[0].name);
    try testing.expectEqualStrings("localhost", restored.struct_val.fields[0].value.string);
    try testing.expectEqualStrings("port", restored.struct_val.fields[1].name);
    try testing.expectEqual(@as(i64, 8080), restored.struct_val.fields[1].value.int);
    try testing.expectEqualStrings("debug", restored.struct_val.fields[2].name);
    try testing.expect(restored.struct_val.fields[2].value.bool_val);
}

test "serialize/deserialize nested struct with list" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const paths = [_]ConstValue{ .{ .string = "lib/**/*.zap" }, .{ .string = "test/**/*.zap" } };
    const fields = [_]ConstValue.ConstFieldValue{
        .{ .name = "name", .value = .{ .string = "my_app" } },
        .{ .name = "version", .value = .{ .string = "0.1.0" } },
        .{ .name = "kind", .value = .{ .atom = "bin" } },
        .{ .name = "paths", .value = .{ .list = &paths } },
    };
    const original = ConstValue{ .struct_val = .{
        .type_name = "Zap_Manifest",
        .fields = &fields,
    } };
    const data = try serializeConstValue(alloc, original);
    var pos: usize = 0;
    const restored = try deserializeConstValue(alloc, data, &pos);
    try testing.expect(restored == .struct_val);
    try testing.expectEqualStrings("Zap_Manifest", restored.struct_val.type_name);
    try testing.expectEqual(@as(usize, 4), restored.struct_val.fields.len);
    const restored_paths = restored.struct_val.fields[3].value;
    try testing.expect(restored_paths == .list);
    try testing.expectEqual(@as(usize, 2), restored_paths.list.len);
    try testing.expectEqualStrings("lib/**/*.zap", restored_paths.list[0].string);
    try testing.expectEqualStrings("test/**/*.zap", restored_paths.list[1].string);
}

test "serializeResult/deserializeResult struct round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const fields = [_]ConstValue.ConstFieldValue{
        .{ .name = "name", .value = .{ .string = "my_app" } },
        .{ .name = "port", .value = .{ .int = 3000 } },
    };
    const eval_result = CtEvalResult{
        .value = .{ .struct_val = .{
            .type_name = "AppConfig",
            .fields = &fields,
        } },
        .dependencies = &.{},
        .result_hash = 99999,
    };
    const data = try serializeResult(alloc, eval_result);
    const restored = try deserializeResult(alloc, data);
    try testing.expect(restored.value == .struct_val);
    try testing.expectEqualStrings("AppConfig", restored.value.struct_val.type_name);
    try testing.expectEqual(@as(usize, 2), restored.value.struct_val.fields.len);
    try testing.expectEqualStrings("my_app", restored.value.struct_val.fields[0].value.string);
    try testing.expectEqual(@as(i64, 3000), restored.value.struct_val.fields[1].value.int);
    try testing.expectEqual(@as(u64, 99999), restored.result_hash);
}

test "dependency serialization: file dep round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const deps = [_]CtDependency{
        .{ .file = .{ .path = "lib/config.zap", .content_hash = 0xDEADBEEF } },
    };
    const eval_result = CtEvalResult{
        .value = .{ .int = 42 },
        .dependencies = &deps,
        .result_hash = 100,
    };
    const data = try serializeResult(alloc, eval_result);
    const restored = try deserializeResult(alloc, data);
    try testing.expectEqual(@as(usize, 1), restored.dependencies.len);
    try testing.expect(restored.dependencies[0] == .file);
    try testing.expectEqualStrings("lib/config.zap", restored.dependencies[0].file.path);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), restored.dependencies[0].file.content_hash);
}

test "dependency serialization: env_var dep round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const deps = [_]CtDependency{
        .{ .env_var = .{ .name = "DATABASE_URL", .value_hash = 0x12345678, .present = true } },
    };
    const eval_result = CtEvalResult{
        .value = .nil,
        .dependencies = &deps,
        .result_hash = 0,
    };
    const data = try serializeResult(alloc, eval_result);
    const restored = try deserializeResult(alloc, data);
    try testing.expectEqual(@as(usize, 1), restored.dependencies.len);
    try testing.expect(restored.dependencies[0] == .env_var);
    try testing.expectEqualStrings("DATABASE_URL", restored.dependencies[0].env_var.name);
    try testing.expectEqual(@as(u64, 0x12345678), restored.dependencies[0].env_var.value_hash);
    try testing.expect(restored.dependencies[0].env_var.present);
}

test "dependency serialization: reflected_module dep round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const deps = [_]CtDependency{
        .{ .reflected_module = .{ .module_name = "Config", .interface_hash = 0xABCD } },
    };
    const eval_result = CtEvalResult{
        .value = .{ .bool_val = true },
        .dependencies = &deps,
        .result_hash = 1,
    };
    const data = try serializeResult(alloc, eval_result);
    const restored = try deserializeResult(alloc, data);
    try testing.expectEqual(@as(usize, 1), restored.dependencies.len);
    try testing.expect(restored.dependencies[0] == .reflected_module);
    try testing.expectEqualStrings("Config", restored.dependencies[0].reflected_module.module_name);
    try testing.expectEqual(@as(u64, 0xABCD), restored.dependencies[0].reflected_module.interface_hash);
}

test "dependency serialization: multiple mixed deps" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const deps = [_]CtDependency{
        .{ .file = .{ .path = "build.zap", .content_hash = 111 } },
        .{ .env_var = .{ .name = "MIX_ENV", .value_hash = 222, .present = false } },
        .{ .reflected_module = .{ .module_name = "App.Config", .interface_hash = 333 } },
    };
    const eval_result = CtEvalResult{
        .value = .{ .string = "ok" },
        .dependencies = &deps,
        .result_hash = 999,
    };
    const data = try serializeResult(alloc, eval_result);
    const restored = try deserializeResult(alloc, data);
    try testing.expectEqual(@as(usize, 3), restored.dependencies.len);
    // file
    try testing.expect(restored.dependencies[0] == .file);
    try testing.expectEqualStrings("build.zap", restored.dependencies[0].file.path);
    try testing.expectEqual(@as(u64, 111), restored.dependencies[0].file.content_hash);
    // env_var
    try testing.expect(restored.dependencies[1] == .env_var);
    try testing.expectEqualStrings("MIX_ENV", restored.dependencies[1].env_var.name);
    try testing.expect(!restored.dependencies[1].env_var.present);
    // reflected_module
    try testing.expect(restored.dependencies[2] == .reflected_module);
    try testing.expectEqualStrings("App.Config", restored.dependencies[2].reflected_module.module_name);
    try testing.expectEqual(@as(u64, 333), restored.dependencies[2].reflected_module.interface_hash);
}

test "builtin: get_build_opt returns value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "optimize" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_build_opt", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.build_opts.put(alloc, "optimize", "release_fast") catch {};

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("release_fast", result.string);
}

test "builtin: get_build_opt returns nil for missing key" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "nonexistent" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_build_opt", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expect(result == .nil);
}

test "capability: build caps allow env read" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "env_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "CTFE_TEST_NONEXISTENT_VAR_999" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_env", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.build; // has all caps

    // Should succeed (returns nil for nonexistent var, but no error)
    const env_result = try interp.evalFunction(0, &.{});
    try testing.expect(env_result == .nil);
    try testing.expectEqual(@as(usize, 0), interp.errors.items.len);
}

test "capability: runtime-only builtins fail at compile time" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "arg_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .call_builtin = .{ .dest = 0, .name = ":zig.arg_count", .args = &.{}, .arg_modes = &.{} } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.build;

    const arg_result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, arg_result);
    try testing.expectEqual(CtfeErrorKind.capability_violation, interp.errors.items[0].kind);
}
