// ============================================================
// Macro Evaluator
//
// Evaluates CtValue AST tuples at compile time.
// Used by the macro engine to execute macro bodies that
// contain logic beyond simple quote/unquote templates.
//
// This is a tree-walking interpreter over the AST data
// representation ({form, metadata, args} tuples).
// ============================================================

const std = @import("std");
const ast = @import("ast.zig");
const ctfe = @import("ctfe.zig");
const ast_data = @import("ast_data.zig");
const CtValue = ctfe.CtValue;
const AllocationStore = ctfe.AllocationStore;
const Allocator = std.mem.Allocator;

pub const MacroEvalError = error{
    EvalFailed,
    OutOfMemory,
};

/// Side channel for `Module.*` intrinsics: lets the evaluator reach the
/// scope graph and the current module's `StructEntry`. The macro
/// engine populates this before invoking `eval`; non-macro callers
/// (legacy CTFE attribute evaluation) leave it null and the
/// intrinsics fall back to evaluator-local behavior or no-ops.
pub const ModuleContext = struct {
    graph: *@import("scope.zig").ScopeGraph,
    interner: *@import("ast.zig").StringInterner,
    current_module_scope: ?u32 = null,
};

pub const Env = struct {
    alloc: Allocator,
    store: *AllocationStore,
    bindings: std.StringHashMap(CtValue),
    module_ctx: ?ModuleContext = null,

    pub fn init(alloc: Allocator, store: *AllocationStore) Env {
        return .{
            .alloc = alloc,
            .store = store,
            .bindings = std.StringHashMap(CtValue).init(alloc),
        };
    }

    pub fn deinit(self: *Env) void {
        self.bindings.deinit();
    }

    pub fn bind(self: *Env, name: []const u8, value: CtValue) !void {
        try self.bindings.put(name, value);
    }

    pub fn lookup(self: *const Env, name: []const u8) ?CtValue {
        return self.bindings.get(name);
    }
};

/// Evaluate a CtValue AST node in the given environment.
/// Returns the result of evaluation.
pub fn eval(env: *Env, value: CtValue) MacroEvalError!CtValue {
    // 3-tuple: {form, meta, args}
    if (value == .tuple and value.tuple.elems.len == 3) {
        const form = value.tuple.elems[0];
        const args = value.tuple.elems[2];

        // Literals with nil args: {value, meta, nil} → return the value
        if (args == .nil) {
            return switch (form) {
                .int, .float, .string, .bool_val, .nil => value,
                .atom => |name| {
                    // Check if it's a variable reference
                    if (name.len > 0 and (name[0] == '_' or std.ascii.isLower(name[0]))) {
                        if (env.lookup(name)) |bound| return bound;
                    }
                    return value;
                },
                else => value,
            };
        }

        if (form != .atom) return value;
        const form_name = form.atom;

        // quote: return the body as data (don't evaluate it)
        if (std.mem.eql(u8, form_name, "quote")) {
            if (args == .list and args.list.elems.len == 1) {
                return args.list.elems[0];
            }
            return value;
        }

        // unquote: evaluate the inner expression
        if (std.mem.eql(u8, form_name, "unquote")) {
            if (args == .list and args.list.elems.len == 1) {
                return eval(env, args.list.elems[0]);
            }
            return value;
        }

        // unquote_splicing: evaluate the inner expression (splicing happens at list level)
        if (std.mem.eql(u8, form_name, "unquote_splicing")) {
            if (args == .list and args.list.elems.len == 1) {
                return eval(env, args.list.elems[0]);
            }
            return value;
        }

        // Assignment: {:=, meta, [target, value]}
        if (std.mem.eql(u8, form_name, "=")) {
            if (args == .list and args.list.elems.len == 2) {
                const target = args.list.elems[0];
                const val = try eval(env, args.list.elems[1]);
                // Simple binding: target is a variable {:name, _, nil}
                if (target == .tuple and target.tuple.elems.len == 3) {
                    if (target.tuple.elems[0] == .atom and target.tuple.elems[2] == .nil) {
                        try env.bind(target.tuple.elems[0].atom, val);
                    }
                }
                return val;
            }
        }

        // Block: {:__block__, meta, [stmts...]}
        if (std.mem.eql(u8, form_name, "__block__")) {
            if (args == .list) {
                var result: CtValue = .nil;
                for (args.list.elems) |stmt| {
                    result = try eval(env, stmt);
                }
                return result;
            }
        }

        // Case: {:case, meta, [subject, [do: [clauses...]]]}
        if (std.mem.eql(u8, form_name, "case")) {
            if (args == .list and args.list.elems.len == 2) {
                const subject = try eval(env, args.list.elems[0]);
                const kw = args.list.elems[1];
                if (kw == .list) {
                    for (kw.list.elems) |pair| {
                        if (pair == .tuple and pair.tuple.elems.len == 2) {
                            if (pair.tuple.elems[0] == .atom and std.mem.eql(u8, pair.tuple.elems[0].atom, "do")) {
                                if (pair.tuple.elems[1] == .list) {
                                    return evalCaseClauses(env, subject, pair.tuple.elems[1].list.elems);
                                }
                            }
                        }
                    }
                }
            }
        }

        // If expression: {:if, meta, [condition, [do: then, else: else]]}
        if (std.mem.eql(u8, form_name, "if")) {
            if (args == .list and args.list.elems.len == 2) {
                const cond = try eval(env, args.list.elems[0]);
                const kw = args.list.elems[1];
                if (kw == .list) {
                    var then_branch: ?CtValue = null;
                    var else_branch: ?CtValue = null;
                    for (kw.list.elems) |pair| {
                        if (pair == .tuple and pair.tuple.elems.len == 2) {
                            if (pair.tuple.elems[0] == .atom) {
                                if (std.mem.eql(u8, pair.tuple.elems[0].atom, "do"))
                                    then_branch = pair.tuple.elems[1];
                                if (std.mem.eql(u8, pair.tuple.elems[0].atom, "else"))
                                    else_branch = pair.tuple.elems[1];
                            }
                        }
                    }
                    if (cond == .bool_val) {
                        if (cond.bool_val) {
                            if (then_branch) |tb| return eval(env, tb);
                        } else {
                            if (else_branch) |eb| return eval(env, eb);
                        }
                    }
                }
            }
        }

        // Cond: {:cond, meta, [clauses...]}
        if (std.mem.eql(u8, form_name, "cond")) {
            if (args == .list) {
                for (args.list.elems) |clause| {
                    if (clause == .tuple and clause.tuple.elems.len == 3) {
                        if (clause.tuple.elems[0] == .atom and std.mem.eql(u8, clause.tuple.elems[0].atom, "->")) {
                            const clause_args = clause.tuple.elems[2];
                            if (clause_args == .list and clause_args.list.elems.len == 2) {
                                const cond_expr = clause_args.list.elems[0];
                                const body = clause_args.list.elems[1];
                                const cond_val = try eval(env, cond_expr);
                                if (cond_val == .bool_val and cond_val.bool_val) {
                                    return eval(env, body);
                                }
                            }
                        }
                    }
                }
            }
        }

        // Built-in compile-time functions for AST manipulation
        // Must be checked BEFORE binary/unary operator fallbacks since
        // built-in functions like elem(x, 0) also have 2 args.
        if (args == .list) {
            const arg_elems = args.list.elems;

            // elem(tuple, index) — extract element from tuple
            if (std.mem.eql(u8, form_name, "elem")) {
                if (arg_elems.len == 2) {
                    const tup = try eval(env, arg_elems[0]);
                    const idx = try eval(env, arg_elems[1]);
                    if (tup == .tuple and idx == .int) {
                        const i: usize = @intCast(idx.int);
                        if (i < tup.tuple.elems.len) return tup.tuple.elems[i];
                    }
                    // Also support wrapped integers {42, [], nil} — extract the int
                    if (tup == .tuple and tup.tuple.elems.len == 3 and idx == .tuple and idx.tuple.elems.len == 3) {
                        if (idx.tuple.elems[0] == .int) {
                            const i: usize = @intCast(idx.tuple.elems[0].int);
                            if (i < tup.tuple.elems.len) return tup.tuple.elems[i];
                        }
                    }
                }
            }

            // prepend(list, value) — [value | list]
            if (std.mem.eql(u8, form_name, "prepend")) {
                if (arg_elems.len == 2) {
                    const list = try eval(env, arg_elems[0]);
                    const val = try eval(env, arg_elems[1]);
                    if (list == .list) {
                        var new_elems = try env.alloc.alloc(CtValue, list.list.elems.len + 1);
                        new_elems[0] = val;
                        @memcpy(new_elems[1..], list.list.elems);
                        const id = env.store.alloc(env.alloc, .list, null);
                        return CtValue{ .list = .{ .alloc_id = id, .elems = new_elems } };
                    }
                }
            }

            // tuple(a, b, c) — construct a tuple
            if (std.mem.eql(u8, form_name, "tuple")) {
                var elems = try env.alloc.alloc(CtValue, arg_elems.len);
                for (arg_elems, 0..) |a, i| {
                    elems[i] = try eval(env, a);
                }
                const id = env.store.alloc(env.alloc, .tuple, null);
                return CtValue{ .tuple = .{ .alloc_id = id, .elems = elems } };
            }

            // find_setup(body) — find the setup() call in a block and return its body
            if (std.mem.eql(u8, form_name, "find_setup")) {
                if (arg_elems.len == 1) {
                    const body = try eval(env, arg_elems[0]);
                    return findNamedCallBody(body, "setup");
                }
            }

            // find_teardown(body) — find the teardown() call in a block and return its body
            if (std.mem.eql(u8, form_name, "find_teardown")) {
                if (arg_elems.len == 1) {
                    const body = try eval(env, arg_elems[0]);
                    return findNamedCallBody(body, "teardown");
                }
            }

            // build_test_fns(describe_name, body, setup_body, teardown_body)
            if (std.mem.eql(u8, form_name, "build_test_fns")) {
                if (arg_elems.len == 4) {
                    const desc = try eval(env, arg_elems[0]);
                    const body = try eval(env, arg_elems[1]);
                    const setup = try eval(env, arg_elems[2]);
                    const teardown = try eval(env, arg_elems[3]);
                    const desc_str = extractString(desc) orelse return .nil;
                    return buildTestFunctions(env.alloc, env.store, desc_str, body, setup, teardown) catch return .nil;
                }
            }

            // build_test_fn(name, body)
            if (std.mem.eql(u8, form_name, "build_test_fn")) {
                if (arg_elems.len == 2) {
                    const name_val = try eval(env, arg_elems[0]);
                    const body_val = try eval(env, arg_elems[1]);
                    const name_str = extractString(name_val) orelse return .nil;
                    return buildSingleTestFunction(env.alloc, env.store, name_str, body_val) catch return .nil;
                }
            }

            // Module attribute intrinsics — callable from within macro
            // bodies to read/write the current module's compile-time
            // attribute table. Inert when no module context is wired
            // through `env.module_ctx` (legacy CTFE callers).
            //
            // The user-facing API lives in Zap (`Module.put_attribute`,
            // etc.) and lowers to these underscore-prefixed names via
            // ordinary macros in lib/. The compiler stays
            // language-agnostic about the wrappers' shape; it only
            // implements the storage primitive.
            if (std.mem.eql(u8, form_name, "__zap_module_put_attr__")) {
                return moduleIntrinsicPut(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "__zap_module_get_attr__")) {
                return moduleIntrinsicGet(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "__zap_module_register_attr__")) {
                return moduleIntrinsicRegister(env, arg_elems);
            }

        }

        // Binary operators (checked AFTER built-in functions)
        if (args == .list and args.list.elems.len == 2) {
            const lhs = try eval(env, args.list.elems[0]);
            const rhs = try eval(env, args.list.elems[1]);
            const binop_result = try evalBinop(env, form_name, lhs, rhs);
            if (binop_result != .nil) return binop_result;
        }

        // Unary operators
        if (args == .list and args.list.elems.len == 1) {
            const operand = try eval(env, args.list.elems[0]);
            if (std.mem.eql(u8, form_name, "-") and operand == .int) {
                return CtValue{ .int = -operand.int };
            }
            if (std.mem.eql(u8, form_name, "not") and operand == .bool_val) {
                return CtValue{ .bool_val = !operand.bool_val };
            }
        }

        // Unknown function call — return as-is (it's probably AST data)
        return value;
    }

    // Bare list — evaluate each element
    if (value == .list) {
        var elems = try env.alloc.alloc(CtValue, value.list.elems.len);
        for (value.list.elems, 0..) |elem, i| {
            elems[i] = try eval(env, elem);
        }
        const id = env.store.alloc(env.alloc, .list, null);
        return CtValue{ .list = .{ .alloc_id = id, .elems = elems } };
    }

    // Leaf values — check for variable binding
    if (value == .atom) {
        if (env.lookup(value.atom)) |bound_val| {
            return bound_val;
        }
    }
    return value;
}

fn evalBinop(env: *Env, op: []const u8, lhs: CtValue, rhs: CtValue) MacroEvalError!CtValue {
    // Arithmetic
    if (lhs == .int and rhs == .int) {
        if (std.mem.eql(u8, op, "+")) return CtValue{ .int = lhs.int + rhs.int };
        if (std.mem.eql(u8, op, "-")) return CtValue{ .int = lhs.int - rhs.int };
        if (std.mem.eql(u8, op, "*")) return CtValue{ .int = lhs.int * rhs.int };
        if (std.mem.eql(u8, op, "/") and rhs.int != 0) return CtValue{ .int = @divTrunc(lhs.int, rhs.int) };
    }

    // Comparison (works for all types)
    if (std.mem.eql(u8, op, "==")) return CtValue{ .bool_val = lhs.eql(rhs) };
    if (std.mem.eql(u8, op, "!=")) return CtValue{ .bool_val = !lhs.eql(rhs) };

    // Integer comparison
    if (lhs == .int and rhs == .int) {
        if (std.mem.eql(u8, op, "<")) return CtValue{ .bool_val = lhs.int < rhs.int };
        if (std.mem.eql(u8, op, ">")) return CtValue{ .bool_val = lhs.int > rhs.int };
        if (std.mem.eql(u8, op, "<=")) return CtValue{ .bool_val = lhs.int <= rhs.int };
        if (std.mem.eql(u8, op, ">=")) return CtValue{ .bool_val = lhs.int >= rhs.int };
    }

    // Boolean
    if (lhs == .bool_val and rhs == .bool_val) {
        if (std.mem.eql(u8, op, "&&")) return CtValue{ .bool_val = lhs.bool_val and rhs.bool_val };
        if (std.mem.eql(u8, op, "||")) return CtValue{ .bool_val = lhs.bool_val or rhs.bool_val };
    }

    // String concat
    if (lhs == .string and rhs == .string) {
        if (std.mem.eql(u8, op, "<>")) {
            const result = std.fmt.allocPrint(env.alloc, "{s}{s}", .{ lhs.string, rhs.string }) catch return .nil;
            return CtValue{ .string = result };
        }
    }

    return .nil;
}

fn evalCaseClauses(env: *Env, subject: CtValue, clauses: []const CtValue) MacroEvalError!CtValue {
    for (clauses) |clause| {
        // Each clause: {:->, meta, [[pattern], body]}
        if (clause == .tuple and clause.tuple.elems.len == 3) {
            if (clause.tuple.elems[0] == .atom and std.mem.eql(u8, clause.tuple.elems[0].atom, "->")) {
                const clause_args = clause.tuple.elems[2];
                if (clause_args == .list and clause_args.list.elems.len == 2) {
                    const pattern_list = clause_args.list.elems[0];
                    const body = clause_args.list.elems[1];

                    if (pattern_list == .list and pattern_list.list.elems.len > 0) {
                        const pattern = pattern_list.list.elems[0];
                        if (matchPattern(env, pattern, subject)) {
                            return eval(env, body);
                        }
                    }
                }
            }
        }
    }
    return .nil;
}

fn matchPattern(env: *Env, pattern: CtValue, subject: CtValue) bool {
    // 3-tuple pattern: {form, meta, args}
    if (pattern == .tuple and pattern.tuple.elems.len == 3) {
        const form = pattern.tuple.elems[0];
        const args = pattern.tuple.elems[2];

        // Wildcard: {:_, _, nil}
        if (form == .atom and args == .nil) {
            const name = form.atom;
            if (std.mem.eql(u8, name, "_")) return true;

            // Variable binding — bind and match
            if (name.len > 0 and (name[0] == '_' or std.ascii.isLower(name[0]))) {
                env.bind(name, subject) catch return false;
                return true;
            }

            // Literal match: form matches subject's form
            return form.eql(extractForm(subject));
        }

        // Tuple destructuring: {:{}, [], [sub_patterns...]}
        // Matches a tuple subject and binds sub-patterns to elements
        if (form == .atom and std.mem.eql(u8, form.atom, "{}")) {
            if (args == .list and subject == .tuple) {
                if (args.list.elems.len != subject.tuple.elems.len) return false;
                for (args.list.elems, subject.tuple.elems) |sub_pat, sub_val| {
                    if (!matchPattern(env, sub_pat, sub_val)) return false;
                }
                return true;
            }
            return false;
        }

        // Structured AST pattern: {:form_name, _, [sub_patterns...]}
        // Matches a 3-tuple subject with matching form and recurses on args
        if (form == .atom and args == .list) {
            if (subject == .tuple and subject.tuple.elems.len == 3) {
                // Match the form
                if (!form.eql(subject.tuple.elems[0])) return false;
                // Match sub-patterns against subject args
                const subj_args = subject.tuple.elems[2];
                if (subj_args == .list and args.list.elems.len == subj_args.list.elems.len) {
                    for (args.list.elems, subj_args.list.elems) |sub_pat, sub_val| {
                        if (!matchPattern(env, sub_pat, sub_val)) return false;
                    }
                    return true;
                }
            }
            return false;
        }
    }

    // List pattern: match element by element
    if (pattern == .list and subject == .list) {
        if (pattern.list.elems.len != subject.list.elems.len) return false;
        for (pattern.list.elems, subject.list.elems) |p, s| {
            if (!matchPattern(env, p, s)) return false;
        }
        return true;
    }

    // Direct value match
    return pattern.eql(subject);
}

fn extractForm(value: CtValue) CtValue {
    if (value == .tuple and value.tuple.elems.len == 3) {
        return value.tuple.elems[0];
    }
    return value;
}

// ============================================================
// Tests
// ============================================================

test "eval: integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    // {42, [], nil}
    const val = try ast_data.makeTuple3(alloc, &store, .{ .int = 42 }, try ast_data.emptyList(alloc, &store), .nil);
    const result = try eval(&env, val);
    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.elems[0] == .int);
    try std.testing.expectEqual(@as(i64, 42), result.tuple.elems[0].int);
}

test "eval: variable binding and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    // x = {42, [], nil}
    const var_node = try ast_data.makeTuple3(alloc, &store, .{ .atom = "x" }, try ast_data.emptyList(alloc, &store), .nil);
    const val_node = try ast_data.makeTuple3(alloc, &store, .{ .int = 42 }, try ast_data.emptyList(alloc, &store), .nil);
    const assign_args = try ast_data.makeList(alloc, &store, &.{ var_node, val_node });
    const assign = try ast_data.makeTuple3(alloc, &store, .{ .atom = "=" }, try ast_data.emptyList(alloc, &store), assign_args);

    _ = try eval(&env, assign);

    // Lookup x
    const x_ref = try ast_data.makeTuple3(alloc, &store, .{ .atom = "x" }, try ast_data.emptyList(alloc, &store), .nil);
    const result = try eval(&env, x_ref);
    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.elems[0] == .int);
    try std.testing.expectEqual(@as(i64, 42), result.tuple.elems[0].int);
}

test "eval: quote returns data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    // quote { 1 + 2 } → {:+, [], [{1, [], nil}, {2, [], nil}]}
    const one = try ast_data.makeTuple3(alloc, &store, .{ .int = 1 }, try ast_data.emptyList(alloc, &store), .nil);
    const two = try ast_data.makeTuple3(alloc, &store, .{ .int = 2 }, try ast_data.emptyList(alloc, &store), .nil);
    const add_args = try ast_data.makeList(alloc, &store, &.{ one, two });
    const add_node = try ast_data.makeTuple3(alloc, &store, .{ .atom = "+" }, try ast_data.emptyList(alloc, &store), add_args);

    const body_list = try ast_data.makeList(alloc, &store, &.{add_node});
    const quote_args = try ast_data.makeList(alloc, &store, &.{body_list});
    const quote_node = try ast_data.makeTuple3(alloc, &store, .{ .atom = "quote" }, try ast_data.emptyList(alloc, &store), quote_args);

    const result = try eval(&env, quote_node);

    // Should be a list containing the add node (not evaluated)
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(@as(usize, 1), result.list.elems.len);
    // The add node should be un-evaluated
    try std.testing.expect(result.list.elems[0] == .tuple);
    try std.testing.expect(result.list.elems[0].tuple.elems[0] == .atom);
    try std.testing.expect(std.mem.eql(u8, result.list.elems[0].tuple.elems[0].atom, "+"));
}

// ============================================================
// Helper functions
// ============================================================

/// Walk a describe block body (a __block__ or list of statements),
/// Find a named call (like setup or teardown) in a __block__ body
/// and return its first argument (the body expression).
fn findNamedCallBody(body: CtValue, name: []const u8) CtValue {
    if (body != .tuple or body.tuple.elems.len != 3) return .nil;
    const form = body.tuple.elems[0];
    const args = body.tuple.elems[2];

    if (form == .atom and std.mem.eql(u8, form.atom, "__block__") and args == .list) {
        for (args.list.elems) |stmt| {
            if (isCallNamed(stmt, name)) {
                const call_args = stmt.tuple.elems[2];
                if (call_args == .list and call_args.list.elems.len >= 1) {
                    return call_args.list.elems[call_args.list.elems.len - 1]; // Last arg is the trailing block body
                }
            }
        }
    }
    return .nil;
}

/// Check if a CtValue is a call to a specific named function/macro.
fn isCallNamed(val: CtValue, name: []const u8) bool {
    if (val != .tuple or val.tuple.elems.len != 3) return false;
    if (val.tuple.elems[0] != .atom) return false;
    return std.mem.eql(u8, val.tuple.elems[0].atom, name);
}

/// Extract string content from a CtValue, handling both bare strings
/// and wrapped string literals ({string_content, meta, nil}).
fn extractString(val: CtValue) ?[]const u8 {
    if (val == .string) return val.string;
    if (val == .tuple and val.tuple.elems.len == 3 and val.tuple.elems[0] == .string)
        return val.tuple.elems[0].string;
    if (val == .atom) return val.atom;
    return null;
}

// ============================================================
// Module attribute intrinsics
//
// Implementation of `__zap_module_put_attr__`,
// `__zap_module_get_attr__`, and `__zap_module_register_attr__`.
// These thread through `env.module_ctx` to reach the scope graph;
// when the context is null (legacy CTFE attribute eval) they return
// nil so user macros wrapping them gracefully no-op.
// ============================================================

fn moduleIntrinsicPut(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 2) return .nil;
    const name_val = try eval(env, args[0]);
    const value_ct = try eval(env, args[1]);
    const ctx = env.module_ctx orelse return .nil;
    const scope_id = ctx.current_module_scope orelse return .nil;
    const mod_entry = ctx.graph.findStructByScope(scope_id) orelse return .nil;

    const name_str = extractAtomName(name_val) orelse return .nil;
    const name_id = ctx.interner.intern(name_str) catch return .nil;

    // The macro evaluator's CtValue carries AST-shape wrappers
    // (3-tuple `{form, meta, nil}` for literals); the attribute store
    // holds bare ConstValues that match `@attr = literal`'s storage
    // format. Unwrap AST literal shells so consumers see the same
    // values regardless of whether the attribute was written from
    // source or via a macro intrinsic.
    const unwrapped = unwrapAstLiteral(value_ct);
    const cv = ctfe.exportValue(env.alloc, unwrapped) catch return .nil;
    ctx.graph.putModuleAttribute(mod_entry, name_id, cv) catch return .nil;
    return .nil;
}

/// Unwrap an AST-wrapped literal CtValue to its bare scalar form.
/// `{ .atom ":foo", meta, nil }` → `.atom "foo"` (colon stripped to
/// match `ConstValue.atom` semantics). `{ .int 42, meta, nil }` →
/// `.int 42`. Tuples and lists pass through unchanged because their
/// elements may contain mixed shapes.
fn unwrapAstLiteral(val: CtValue) CtValue {
    if (val != .tuple or val.tuple.elems.len != 3) return val;
    if (val.tuple.elems[2] != .nil) return val;
    const form = val.tuple.elems[0];
    return switch (form) {
        .int, .float, .string, .bool_val, .nil => form,
        .atom => |name| blk: {
            // Strip `:` prefix used to disambiguate atom literal vs
            // variable reference in the AST encoding. ConstValue
            // atoms are stored without the prefix.
            if (name.len > 0 and name[0] == ':') {
                break :blk CtValue{ .atom = name[1..] };
            }
            break :blk val; // variable refs are not literals — keep wrapper
        },
        else => val,
    };
}

fn moduleIntrinsicGet(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    const name_val = try eval(env, args[0]);
    const ctx = env.module_ctx orelse return .nil;
    const scope_id = ctx.current_module_scope orelse return .nil;
    const mod_entry = ctx.graph.findStructByScope(scope_id) orelse return .nil;

    const name_str = extractAtomName(name_val) orelse return .nil;
    const name_id = ctx.interner.intern(name_str) catch return .nil;
    const cv_opt = ctx.graph.getModuleAttribute(mod_entry, name_id) catch return .nil;
    const cv = cv_opt orelse return .nil;
    return constValueToCtValue(env, cv) catch .nil;
}

fn moduleIntrinsicRegister(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len < 1) return .nil;
    const name_val = try eval(env, args[0]);
    const ctx = env.module_ctx orelse return .nil;
    const scope_id = ctx.current_module_scope orelse return .nil;
    const mod_entry = ctx.graph.findStructByScope(scope_id) orelse return .nil;

    const name_str = extractAtomName(name_val) orelse return .nil;
    const name_id = ctx.interner.intern(name_str) catch return .nil;
    ctx.graph.registerAccumulatingAttribute(mod_entry, name_id) catch return .nil;
    return .nil;
}

/// Extract an atom name from a CtValue, dropping the leading `:`
/// that distinguishes literal atoms from identifiers in the encoded
/// AST. Accepts:
///   - Bare `.atom` values (with or without `:` prefix).
///   - 3-tuple-wrapped atom literals: `{:":name", meta, nil}`.
///   - 3-tuple-wrapped strings: `{"name", meta, nil}` (legacy).
fn extractAtomName(val: CtValue) ?[]const u8 {
    if (val == .atom) {
        const raw = val.atom;
        if (raw.len > 0 and raw[0] == ':') return raw[1..];
        return raw;
    }
    if (val == .tuple and val.tuple.elems.len == 3 and val.tuple.elems[2] == .nil) {
        const form = val.tuple.elems[0];
        if (form == .atom) {
            const raw = form.atom;
            if (raw.len > 0 and raw[0] == ':') return raw[1..];
            return raw;
        }
        if (form == .string) return form.string;
    }
    if (val == .string) return val.string;
    return null;
}

/// Re-import a stored ConstValue back into the macro evaluator's
/// CtValue representation. Inverse of `ctfe.exportValue` for the
/// shapes the attribute store actually holds (no closures or
/// runtime-only structures appear in attribute payloads).
fn constValueToCtValue(env: *Env, cv: anytype) !CtValue {
    const ConstValue = ctfe.ConstValue;
    return switch (cv) {
        ConstValue.int => |v| CtValue{ .int = v },
        ConstValue.float => |v| CtValue{ .float = v },
        ConstValue.string => |v| CtValue{ .string = v },
        ConstValue.bool_val => |v| CtValue{ .bool_val = v },
        ConstValue.atom => |v| CtValue{ .atom = v },
        ConstValue.nil => .nil,
        ConstValue.void => .void,
        ConstValue.tuple => |elems| blk: {
            var result = try env.alloc.alloc(CtValue, elems.len);
            for (elems, 0..) |e, i| result[i] = try constValueToCtValue(env, e);
            const id = env.store.alloc(env.alloc, .tuple, null);
            break :blk CtValue{ .tuple = .{ .alloc_id = id, .elems = result } };
        },
        ConstValue.list => |elems| blk: {
            var result = try env.alloc.alloc(CtValue, elems.len);
            for (elems, 0..) |e, i| result[i] = try constValueToCtValue(env, e);
            const id = env.store.alloc(env.alloc, .list, null);
            break :blk CtValue{ .list = .{ .alloc_id = id, .elems = result } };
        },
        else => .nil, // map and struct_val are not used in attribute storage today
    };
}

fn slugifyString(alloc: Allocator, input: []const u8) ![]const u8 {
    const result = try alloc.alloc(u8, input.len);
    for (input, 0..) |c, i| {
        if (c == ' ' or c == '-' or c == '\t' or c == '\n') {
            result[i] = '_';
        } else if (std.ascii.isUpper(c)) {
            result[i] = std.ascii.toLower(c);
        } else if (std.ascii.isAlphanumeric(c) or c == '_') {
            result[i] = c;
        } else {
            result[i] = '_';
        }
    }
    return result;
}

/// Build a plain function call: {:fn_name, [], []}
fn buildCall0(alloc: Allocator, store: *AllocationStore, name: []const u8) !CtValue {
    const empty = try ast_data.emptyList(alloc, store);
    return ast_data.makeTuple3(alloc, store, .{ .atom = name }, empty, empty);
}

/// Build a test function declaration (pub, String return, given body).
fn buildTestFnDecl(alloc: Allocator, store: *AllocationStore, name: []const u8, body: CtValue) !CtValue {
    const empty = try ast_data.emptyList(alloc, store);
    const head = try ast_data.makeTuple3(alloc, store, .{ .atom = name }, empty, empty);
    const return_pair = try ast_data.makeTuple2(alloc, store, .{ .atom = "return" }, .{ .atom = "String" });
    const do_pair = try ast_data.makeTuple2(alloc, store, .{ .atom = "do" }, body);
    const opts = try ast_data.makeList(alloc, store, &.{ return_pair, do_pair });
    const clause_args = try ast_data.makeList(alloc, store, &.{ head, opts });
    const clause = try ast_data.makeTuple3(alloc, store, .{ .atom = "->" }, empty, clause_args);
    const clauses = try ast_data.makeList(alloc, store, &.{clause});
    // Visibility lives in metadata as an atom — must match the encoding
    // produced by `functionDeclToCtValue` and consumed by
    // `ctValueToStructItem` (`src/ast_data.zig:2243`). Writing it as a
    // string would silently make the test function private.
    const vis_pair = try ast_data.makeTuple2(alloc, store, .{ .atom = "visibility" }, .{ .atom = "pub" });
    const fn_meta = try ast_data.makeList(alloc, store, &.{vis_pair});
    return ast_data.makeTuple3(alloc, store, .{ .atom = "fn" }, fn_meta, clauses);
}

/// Build test functions from a describe block.
/// Returns a __block__ containing:
///   - function declarations (test_*)
///   - tracking call expressions (begin_test; call; end_test; print_result; ".")
fn buildTestFunctions(
    alloc: Allocator,
    store: *AllocationStore,
    describe_name: []const u8,
    body: CtValue,
    setup_body: CtValue,
    teardown_body: CtValue,
) !CtValue {
    if (body != .tuple or body.tuple.elems.len != 3) return .nil;
    const form = body.tuple.elems[0];
    const args = body.tuple.elems[2];
    if (form != .atom or !std.mem.eql(u8, form.atom, "__block__") or args != .list) return .nil;

    const desc_slug = try slugifyString(alloc, describe_name);
    const empty = try ast_data.emptyList(alloc, store);
    var result_items: std.ArrayListUnmanaged(CtValue) = .empty;

    for (args.list.elems) |stmt| {
        if (isCallNamed(stmt, "setup") or isCallNamed(stmt, "teardown")) continue;

        if (isCallNamed(stmt, "test")) {
            const test_args = stmt.tuple.elems[2];
            if (test_args != .list or test_args.list.elems.len < 2) continue;

            const test_name_str = extractString(test_args.list.elems[0]) orelse continue;
            const test_slug = try slugifyString(alloc, test_name_str);
            const fn_name = try std.fmt.allocPrint(alloc, "test_{s}_{s}", .{ desc_slug, test_slug });

            // Determine test body
            const has_context = test_args.list.elems.len == 3 and setup_body != .nil;
            const raw_body = if (has_context) test_args.list.elems[2] else test_args.list.elems[test_args.list.elems.len - 1];

            // Build function body: [setup?; body_stmts...; teardown?; "ok"]
            var fn_body_stmts: std.ArrayListUnmanaged(CtValue) = .empty;
            if (has_context) {
                const ctx_var = try ast_data.makeTuple3(alloc, store, .{ .atom = "ctx" }, empty, .nil);
                const ctx_assign = try ast_data.makeTuple3(alloc, store, .{ .atom = "=" }, empty, try ast_data.makeList(alloc, store, &.{ ctx_var, setup_body }));
                try fn_body_stmts.append(alloc, ctx_assign);
            }
            // Flatten __block__ bodies
            if (raw_body == .tuple and raw_body.tuple.elems.len == 3 and
                raw_body.tuple.elems[0] == .atom and std.mem.eql(u8, raw_body.tuple.elems[0].atom, "__block__") and
                raw_body.tuple.elems[2] == .list)
            {
                for (raw_body.tuple.elems[2].list.elems) |inner| try fn_body_stmts.append(alloc, inner);
            } else {
                try fn_body_stmts.append(alloc, raw_body);
            }
            if (teardown_body != .nil) try fn_body_stmts.append(alloc, teardown_body);
            try fn_body_stmts.append(alloc, .{ .string = "ok" });

            const fn_body = try ast_data.makeTuple3(alloc, store, .{ .atom = "__block__" }, empty, try ast_data.makeListFromSlice(alloc, store, fn_body_stmts.items));
            const fn_decl = try buildTestFnDecl(alloc, store, fn_name, fn_body);
            try result_items.append(alloc, fn_decl);

            // Tracking call: begin_test(); test_fn(); end_test(); print_result(); "."
            const tracking = try ast_data.makeTuple3(alloc, store, .{ .atom = "__block__" }, empty, try ast_data.makeList(alloc, store, &.{
                try buildCall0(alloc, store, "begin_test"),
                try buildCall0(alloc, store, fn_name),
                try buildCall0(alloc, store, "end_test"),
                try buildCall0(alloc, store, "print_result"),
                .{ .string = "." },
            }));
            try result_items.append(alloc, tracking);
        } else {
            try result_items.append(alloc, stmt);
        }
    }

    // Return as __block__ (mixed content: fn decls + tracking exprs)
    return ast_data.makeTuple3(alloc, store, .{ .atom = "__block__" }, empty, try ast_data.makeListFromSlice(alloc, store, result_items.items));
}

/// Build a standalone test function + tracking call.
fn buildSingleTestFunction(alloc: Allocator, store: *AllocationStore, name: []const u8, body: CtValue) !CtValue {
    const slug = try slugifyString(alloc, name);
    const fn_name = try std.fmt.allocPrint(alloc, "test_{s}", .{slug});
    const empty = try ast_data.emptyList(alloc, store);

    var fn_body_stmts: std.ArrayListUnmanaged(CtValue) = .empty;
    if (body == .tuple and body.tuple.elems.len == 3 and
        body.tuple.elems[0] == .atom and std.mem.eql(u8, body.tuple.elems[0].atom, "__block__") and
        body.tuple.elems[2] == .list)
    {
        for (body.tuple.elems[2].list.elems) |inner| try fn_body_stmts.append(alloc, inner);
    } else {
        try fn_body_stmts.append(alloc, body);
    }
    try fn_body_stmts.append(alloc, .{ .string = "ok" });

    const fn_body = try ast_data.makeTuple3(alloc, store, .{ .atom = "__block__" }, empty, try ast_data.makeListFromSlice(alloc, store, fn_body_stmts.items));
    const fn_decl = try buildTestFnDecl(alloc, store, fn_name, fn_body);

    const tracking = try ast_data.makeTuple3(alloc, store, .{ .atom = "__block__" }, empty, try ast_data.makeList(alloc, store, &.{
        try buildCall0(alloc, store, "begin_test"),
        try buildCall0(alloc, store, fn_name),
        try buildCall0(alloc, store, "end_test"),
        try buildCall0(alloc, store, "print_result"),
        .{ .string = "." },
    }));

    // Return as __block__ (mixed: fn decl + tracking expr)
    return ast_data.makeTuple3(alloc, store, .{ .atom = "__block__" }, empty, try ast_data.makeList(alloc, store, &.{ fn_decl, tracking }));
}

