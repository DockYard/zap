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
    /// Recursion depth for comptime function dispatch. Bumped each
    /// time `dispatchComptimeCall` recurses into another function.
    /// Limits runaway evaluation of recursive functions.
    dispatch_depth: u32 = 0,

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

            // __zap_list_at__(list, index) — element at zero-based index,
            // or nil when out of range. Negative indices count from the
            // end (`-1` = last). Lifts the bare-int conventions from Zig
            // into macro space so library code can write `list_at(args, 0)`
            // to take the first matching call.
            if (std.mem.eql(u8, form_name, "__zap_list_at__")) {
                if (arg_elems.len == 2) {
                    const list = try eval(env, arg_elems[0]);
                    const idx_raw = try eval(env, arg_elems[1]);
                    const idx_val = unwrapAstLiteral(idx_raw);
                    if (list == .list and idx_val == .int) {
                        const len: i64 = @intCast(list.list.elems.len);
                        const normalized: i64 = if (idx_val.int < 0) len + idx_val.int else idx_val.int;
                        if (normalized >= 0 and normalized < len) {
                            return list.list.elems[@intCast(normalized)];
                        }
                    }
                    return .nil;
                }
            }

            // __zap_list_len__(list) — element count as a bare int.
            // Returns 0 for non-lists so callers can chain it through
            // `==` / `>` without first checking shape.
            if (std.mem.eql(u8, form_name, "__zap_list_len__")) {
                if (arg_elems.len == 1) {
                    const list = try eval(env, arg_elems[0]);
                    if (list == .list) return CtValue{ .int = @intCast(list.list.elems.len) };
                    return CtValue{ .int = 0 };
                }
            }

            // __zap_list_empty__(list) — true iff the list has no elements.
            // Non-list values are treated as empty so callers don't have
            // to distinguish "empty list" from "wrong shape".
            if (std.mem.eql(u8, form_name, "__zap_list_empty__")) {
                if (arg_elems.len == 1) {
                    const list = try eval(env, arg_elems[0]);
                    if (list == .list) return CtValue{ .bool_val = list.list.elems.len == 0 };
                    return CtValue{ .bool_val = true };
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

            // For-comprehension at comptime: iterate a list/string,
            // bind the loop pattern, optionally filter, accumulate
            // body results into a fresh list. Encoded by `exprToCtValue`
            // as `{:for, meta, [var_pattern, iterable, filter|nil, body]}`.
            if (std.mem.eql(u8, form_name, "for")) {
                return forComprehensionIntrinsic(env, arg_elems);
            }

            // Comptime string/atom helpers — language primitives
            // exposed to macro bodies so library-level macros can
            // build dynamic identifiers without depending on
            // test-framework-specific Zig builtins. These are the
            // minimum needed to migrate the Zest test framework
            // entirely into Zap source.
            if (std.mem.eql(u8, form_name, "__zap_atom_name__")) {
                return atomNameIntrinsic(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "__zap_slugify__")) {
                return slugifyIntrinsic(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "__zap_intern_atom__")) {
                return internAtomIntrinsic(env, arg_elems);
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

        // Comptime function dispatch: unknown form is a function name
        // visible in the current module's scope. Look up the function
        // family, instantiate the first matching clause's body with
        // the call's arg CtValues bound to the params, and recursively
        // interpret. Pure Zap functions (no `:zig.` calls beyond
        // comptime intrinsics) "just work"; impure functions return
        // nil through the natural fall-through and the call survives
        // as AST data.
        if (args == .list) {
            if (try dispatchComptimeCall(env, form_name, args.list.elems)) |result| {
                return result;
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

fn evalBinop(env: *Env, op: []const u8, lhs_raw: CtValue, rhs_raw: CtValue) MacroEvalError!CtValue {
    // Operands arrive in their "as-evaluated" shape — eval of a
    // literal AST node returns the wrapped 3-tuple `{value, meta, nil}`
    // rather than the bare scalar (so AST identity is preserved for
    // round-trips). Unwrap to bare scalars here so the per-type
    // checks below work uniformly whether an operand came from a
    // literal in source, a comptime computed value, or a substituted
    // unquote.
    const lhs = unwrapAstLiteral(lhs_raw);
    const rhs = unwrapAstLiteral(rhs_raw);

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

/// Walk a function's AST body and return true when none of its
/// constructs would produce a runtime side effect when evaluated at
/// compile time. Conservative — refuses on any construct the
/// comptime evaluator can't safely interpret (`:zig.X` calls,
/// `panic`, calls to functions whose bodies in turn aren't safe).
///
/// "Safe" here is structural: the AST shape is recognized and
/// reducible to a value. The evaluator may still fail dynamically
/// (e.g., division by zero) — those are handled by the caller's
/// `catch return null` paths.
fn isFunctionBodyComptimeSafe(body: []const ast.Stmt) bool {
    for (body) |stmt| {
        switch (stmt) {
            .expr => |e| if (!isExprComptimeSafe(e)) return false,
            .assignment => |a| {
                if (!isExprComptimeSafe(a.value)) return false;
            },
            // Function/macro/import declarations inside another fn
            // body aren't comptime-callable through dispatch (the
            // caller would have to evaluate the whole construct).
            .function_decl, .macro_decl, .import_decl => return false,
        }
    }
    return true;
}

fn isExprComptimeSafe(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        // Literals — always safe
        .int_literal, .float_literal, .string_literal, .bool_literal,
        .atom_literal, .nil_literal => true,
        // Variable references resolve through env.bindings
        .var_ref => true,
        // Compound shapes — all children must be safe
        .binary_op => |b| isExprComptimeSafe(b.lhs) and isExprComptimeSafe(b.rhs),
        .unary_op => |u| isExprComptimeSafe(u.operand),
        .pipe => |p| isExprComptimeSafe(p.lhs) and isExprComptimeSafe(p.rhs),
        .list => |l| for (l.elements) |elem| {
            if (!isExprComptimeSafe(elem)) break false;
        } else true,
        .tuple => |t| for (t.elements) |elem| {
            if (!isExprComptimeSafe(elem)) break false;
        } else true,
        .map => |m| blk: {
            if (m.update_source) |src| {
                if (!isExprComptimeSafe(src)) break :blk false;
            }
            for (m.fields) |entry| {
                if (!isExprComptimeSafe(entry.key)) break :blk false;
                if (!isExprComptimeSafe(entry.value)) break :blk false;
            }
            break :blk true;
        },
        .block => |b| for (b.stmts) |stmt| {
            switch (stmt) {
                .expr => |e| if (!isExprComptimeSafe(e)) break false,
                .assignment => |a| if (!isExprComptimeSafe(a.value)) break false,
                else => break false,
            }
        } else true,
        .if_expr => |ife| ifBlk: {
            if (!isExprComptimeSafe(ife.condition)) break :ifBlk false;
            for (ife.then_block) |s| {
                switch (s) {
                    .expr => |e| if (!isExprComptimeSafe(e)) break :ifBlk false,
                    .assignment => |a| if (!isExprComptimeSafe(a.value)) break :ifBlk false,
                    else => break :ifBlk false,
                }
            }
            if (ife.else_block) |else_b| {
                for (else_b) |s| {
                    switch (s) {
                        .expr => |e| if (!isExprComptimeSafe(e)) break :ifBlk false,
                        .assignment => |a| if (!isExprComptimeSafe(a.value)) break :ifBlk false,
                        else => break :ifBlk false,
                    }
                }
            }
            break :ifBlk true;
        },
        // Calls — check the callee shape. Bare-name calls go through
        // comptime dispatch (recursive safety check at dispatch
        // time). Field-access callees that target the `:zig.` interop
        // namespace are NEVER comptime-safe; module-qualified Zap
        // calls (`Foo.bar(args)`) are conservatively rejected for
        // now since dispatch doesn't yet route through module refs.
        .call => |c| isCallComptimeSafe(c),
        // Range, list-cons, struct construction — pure shape
        .range => |r| {
            if (!isExprComptimeSafe(r.start)) return false;
            if (!isExprComptimeSafe(r.end)) return false;
            if (r.step) |s| if (!isExprComptimeSafe(s)) return false;
            return true;
        },
        .list_cons_expr => |c| isExprComptimeSafe(c.head) and isExprComptimeSafe(c.tail),
        // Quote/unquote — handled by macro engine, not function
        // dispatch. Treat as not-safe so dispatch refuses.
        .quote_expr, .unquote_expr, .unquote_splicing_expr => false,
        // For-comp inside a function body — defer to its own safety.
        .for_expr => |f| isExprComptimeSafe(f.iterable) and isExprComptimeSafe(f.body) and
            (f.filter == null or isExprComptimeSafe(f.filter.?)),
        // Anything else is unrecognized — refuse conservatively.
        else => false,
    };
}

fn isCallComptimeSafe(call: anytype) bool {
    // Inspect callee shape:
    //   - var_ref: bare-name call. Safe — dispatch will recurse.
    //   - field_access on :zig: NEVER safe.
    //   - field_access on a Zap module: may eventually be safe
    //     (cross-module pure dispatch), but dispatch doesn't
    //     currently route through module refs. Reject.
    //   - module_ref or anything else: reject.
    if (call.callee.* == .var_ref) {
        // Each arg must also be safe.
        for (call.args) |arg| {
            if (!isExprComptimeSafe(arg)) return false;
        }
        return true;
    }
    if (call.callee.* == .field_access) {
        // Module-qualified calls (`Foo.bar(args)`) and `:zig.X.Y(...)`
        // interop are conservatively rejected — comptime dispatch
        // doesn't route through field-access callees yet. When
        // cross-module dispatch lands the safe-set widens here.
        return false;
    }
    return false;
}

/// Maximum recursion depth for comptime function dispatch. Prevents
/// runaway evaluation of recursive functions; mirrors the
/// `max_expansions` limit on the macro engine itself. Counted across
/// the call stack via env.dispatch_depth.
const COMPTIME_DISPATCH_MAX_DEPTH: u32 = 64;

/// Try to resolve and interpret a Zap-side function call at comptime.
/// Returns the function body's evaluated result, or null when:
///   - no module context is available (eval is not running for a
///     macro expansion)
///   - the function family isn't found in the current scope chain
///   - the function body contains constructs the comptime evaluator
///     can't handle (e.g., `:zig.` calls)
///   - the depth limit is reached
fn dispatchComptimeCall(
    env: *Env,
    form_name: []const u8,
    arg_forms: []const CtValue,
) MacroEvalError!?CtValue {
    const ctx = env.module_ctx orelse return null;
    if (env.dispatch_depth >= COMPTIME_DISPATCH_MAX_DEPTH) return null;

    const scope_id = ctx.current_module_scope orelse ctx.graph.prelude_scope;
    const name_id = ctx.interner.intern(form_name) catch return null;
    const arity: u32 = @intCast(arg_forms.len);
    const family_id = ctx.graph.resolveFamily(scope_id, name_id, arity) orelse return null;
    const family = &ctx.graph.families.items[family_id];
    if (family.clauses.items.len == 0) return null;

    // Pick the first clause for now. Multi-clause dispatch with
    // pattern matching at comptime is a future extension; the
    // common case (string helpers, list helpers, formatters) uses
    // a single clause anyway.
    const clause_ref = family.clauses.items[0];
    const clause = &clause_ref.decl.clauses[clause_ref.clause_index];
    const body = clause.body orelse return null;

    // Purity check: refuse to dispatch a function whose body
    // contains `:zig.` interop calls, raw `panic`, or other
    // side-effecting primitives. Without this guard, eval would
    // happily process pure subtrees and leave impure subtrees as
    // unresolved AST tuples — the macro author would silently get
    // mangled output. The conservative refusal returns null, the
    // caller falls through to "leave the call as AST data" which
    // surfaces at runtime where the impure call belongs.
    if (!isFunctionBodyComptimeSafe(body)) return null;

    // Pre-evaluate each argument so the callee sees fully-evaluated
    // values, not AST forms still containing nested calls.
    var arg_cts = env.alloc.alloc(CtValue, arg_forms.len) catch return null;
    defer env.alloc.free(arg_cts);
    for (arg_forms, 0..) |form, i| {
        arg_cts[i] = eval(env, form) catch return null;
    }

    // Spin up a child env that inherits the same store, dispatch
    // depth (incremented), and module_ctx, but starts with a fresh
    // bindings map populated only with the callee's parameters. The
    // child's bindings can't leak into the caller's scope.
    var child_env = Env.init(env.alloc, env.store);
    defer child_env.deinit();
    child_env.module_ctx = env.module_ctx;
    child_env.dispatch_depth = env.dispatch_depth + 1;

    for (clause.params, 0..) |param, i| {
        if (i >= arg_cts.len) break;
        if (param.pattern.* == .bind) {
            const param_name = ctx.interner.get(param.pattern.bind.name);
            child_env.bind(param_name, arg_cts[i]) catch return null;
        }
    }

    // Convert the body statements to CtValue and evaluate them.
    // Last statement's result is the return value, matching
    // expression-language semantics.
    var result: CtValue = .nil;
    for (body) |stmt| {
        const stmt_ct = ast_data.stmtToCtValue(env.alloc, ctx.interner, env.store, stmt) catch return null;
        result = eval(&child_env, stmt_ct) catch return null;
    }

    // The function may legitimately return nil. Return the actual
    // result so callers can distinguish nil-return from no-dispatch.
    return result;
}

/// `for x <- iterable, filter, body` at comptime. Encoded as
/// `{:for, meta, [var_pattern, iterable, filter|nil, body]}` per
/// `exprToCtValue.for_expr`. Iterates the list-shaped iterable,
/// binds the pattern, optionally evaluates a boolean filter, and
/// accumulates body results into a fresh CtValue.list.
fn forComprehensionIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 4) return .nil;
    const var_pattern = args[0];
    const iterable_ct = try eval(env, args[1]);
    const filter_form = args[2]; // unevaluated — re-evaluated per iteration
    const body_form = args[3];

    // Iterables: bare lists, AST-wrapped list literals, or strings
    // (which iterate codepoints). Anything else returns nil — the
    // caller can chose whether to treat that as an error.
    const list_elems: []const CtValue = switch (iterable_ct) {
        .list => |l| l.elems,
        // AST-wrapped list literal would surface as a `.tuple`, but
        // `exprToCtValue` produces bare lists for `[a, b, c]` so the
        // tuple-shaped path doesn't arise in practice. Treat any
        // other shape as "not iterable at comptime" — caller code
        // can catch the nil result and surface a useful error.
        else => return .nil,
    };

    var accumulated: std.ArrayListUnmanaged(CtValue) = .empty;
    for (list_elems) |elem| {
        // Bind the loop pattern. Save and restore env.bindings around
        // each iteration so loop-bound names don't leak.
        const had_pattern_bind = bindForPattern(env, var_pattern, elem) catch continue;
        defer if (had_pattern_bind) |bound_name| {
            _ = env.bindings.remove(bound_name);
        };

        // Filter check, if present.
        if (filter_form != .nil) {
            const filter_result = eval(env, filter_form) catch CtValue.nil;
            const bare = unwrapAstLiteral(filter_result);
            const passes = switch (bare) {
                .bool_val => |b| b,
                else => false, // truthy semantics not supported at comptime
            };
            if (!passes) continue;
        }

        const body_result = eval(env, body_form) catch CtValue.nil;
        try accumulated.append(env.alloc, body_result);
    }

    const slice = try accumulated.toOwnedSlice(env.alloc);
    const id = env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = slice } };
}

/// Bind a for-comprehension's loop pattern to a list element. Only
/// simple bind patterns (a bare name) are supported at comptime —
/// destructuring patterns (`{k, v}` etc.) require running the
/// pattern matcher, which is HIR-level work. Returns the bound name
/// (if any) for cleanup.
fn bindForPattern(env: *Env, pattern: CtValue, elem: CtValue) !?[]const u8 {
    // The pattern as a CtValue is itself an AST tuple shape:
    //   - `{:name, [], nil}`     — bare bind pattern (variable)
    //   - `{:_, [], nil}`        — wildcard (no binding)
    //   - other 3-tuples         — compound patterns (unsupported)
    if (pattern == .atom) {
        // Bare atom — happens when patternToCtValue collapses a
        // bind pattern to the underlying name.
        const name = pattern.atom;
        if (std.mem.eql(u8, name, "_")) return null;
        try env.bind(name, elem);
        return name;
    }
    if (pattern == .tuple and pattern.tuple.elems.len == 3) {
        const form = pattern.tuple.elems[0];
        const args_v = pattern.tuple.elems[2];
        if (form == .atom and args_v == .nil) {
            const name = form.atom;
            if (std.mem.eql(u8, name, "_")) return null;
            // Skip atom literal patterns (`:foo`) — they match by
            // equality, not by binding. The current comptime for
            // doesn't support match semantics; that's HIR territory.
            if (name.len > 0 and name[0] == ':') return null;
            try env.bind(name, elem);
            return name;
        }
    }
    return null;
}

/// `__zap_atom_name__(atom_value)`: extract the bare name string
/// from an atom CtValue (or AST-wrapped atom literal). The leading
/// `:` that distinguishes literal atoms from variable references in
/// the AST encoding is stripped. Returns the string CtValue;
/// returns nil if the argument isn't atom-shaped.
fn atomNameIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    const val = try eval(env, args[0]);
    const name = extractAtomName(val) orelse return .nil;
    // Duplicate so the lifetime survives any temporary stores.
    const buf = env.alloc.alloc(u8, name.len) catch return .nil;
    @memcpy(buf, name);
    return CtValue{ .string = buf };
}

/// `__zap_slugify__(string_value)`: convert a string to a snake-
/// case identifier suitable for use as a function name. Spaces,
/// dashes, and other non-alphanumerics become underscores; uppercase
/// letters become lowercase. Returns the string CtValue.
fn slugifyIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    const val = try eval(env, args[0]);
    const input = extractString(val) orelse return .nil;
    const out = slugifyString(env.alloc, input) catch return .nil;
    return CtValue{ .string = out };
}

/// `__zap_intern_atom__(string_value)`: convert a string to an atom
/// CtValue (with the `:` prefix that distinguishes literal atoms
/// from variable refs in the AST encoding). Used by macros that
/// build a function name as a string and need to splice it into
/// `unquote(name)(...)` position.
fn internAtomIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    const val = try eval(env, args[0]);
    const input = extractString(val) orelse return .nil;
    const prefixed = std.fmt.allocPrint(env.alloc, ":{s}", .{input}) catch return .nil;
    return CtValue{ .atom = prefixed };
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

test "eval: __zap_list_at__ extracts elements with normal and negative indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const list = try ast_data.makeList(alloc, &store, &.{
        .{ .int = 10 },
        .{ .int = 20 },
        .{ .int = 30 },
    });

    // list_at(list, 0) → 10
    const at0 = try ast_data.makeTuple3(alloc, &store, .{ .atom = "__zap_list_at__" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ list, .{ .int = 0 } }));
    const r0 = try eval(&env, at0);
    try std.testing.expect(r0 == .int);
    try std.testing.expectEqual(@as(i64, 10), r0.int);

    // list_at(list, 2) → 30
    const at2 = try ast_data.makeTuple3(alloc, &store, .{ .atom = "__zap_list_at__" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ list, .{ .int = 2 } }));
    const r2 = try eval(&env, at2);
    try std.testing.expect(r2 == .int);
    try std.testing.expectEqual(@as(i64, 30), r2.int);

    // list_at(list, -1) → 30 (last)
    const at_neg = try ast_data.makeTuple3(alloc, &store, .{ .atom = "__zap_list_at__" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ list, .{ .int = -1 } }));
    const r_neg = try eval(&env, at_neg);
    try std.testing.expect(r_neg == .int);
    try std.testing.expectEqual(@as(i64, 30), r_neg.int);

    // list_at(list, 5) → nil (out of range)
    const at_oor = try ast_data.makeTuple3(alloc, &store, .{ .atom = "__zap_list_at__" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ list, .{ .int = 5 } }));
    const r_oor = try eval(&env, at_oor);
    try std.testing.expect(r_oor == .nil);
}

test "eval: __zap_list_len__ counts list elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const list3 = try ast_data.makeList(alloc, &store, &.{
        .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 },
    });
    const call3 = try ast_data.makeTuple3(alloc, &store, .{ .atom = "__zap_list_len__" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{list3}));
    const r3 = try eval(&env, call3);
    try std.testing.expect(r3 == .int);
    try std.testing.expectEqual(@as(i64, 3), r3.int);

    // Empty list → 0
    const empty = try ast_data.emptyList(alloc, &store);
    const call_empty = try ast_data.makeTuple3(alloc, &store, .{ .atom = "__zap_list_len__" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{empty}));
    const r_empty = try eval(&env, call_empty);
    try std.testing.expect(r_empty == .int);
    try std.testing.expectEqual(@as(i64, 0), r_empty.int);
}

test "eval: __zap_list_empty__ distinguishes empty from non-empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const empty = try ast_data.emptyList(alloc, &store);
    const call_e = try ast_data.makeTuple3(alloc, &store, .{ .atom = "__zap_list_empty__" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{empty}));
    const r_e = try eval(&env, call_e);
    try std.testing.expect(r_e == .bool_val);
    try std.testing.expectEqual(true, r_e.bool_val);

    const nonempty = try ast_data.makeList(alloc, &store, &.{.{ .int = 1 }});
    const call_n = try ast_data.makeTuple3(alloc, &store, .{ .atom = "__zap_list_empty__" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{nonempty}));
    const r_n = try eval(&env, call_n);
    try std.testing.expect(r_n == .bool_val);
    try std.testing.expectEqual(false, r_n.bool_val);
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

