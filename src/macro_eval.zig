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

pub const Env = struct {
    alloc: Allocator,
    store: *AllocationStore,
    bindings: std.StringHashMap(CtValue),

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

        // Binary operators
        if (args == .list and args.list.elems.len == 2) {
            const lhs = try eval(env, args.list.elems[0]);
            const rhs = try eval(env, args.list.elems[1]);
            return evalBinop(env, form_name, lhs, rhs);
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

        // Built-in compile-time functions for AST manipulation
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

            // is_tuple(value) — check if value is a tuple
            if (std.mem.eql(u8, form_name, "is_tuple")) {
                if (arg_elems.len == 1) {
                    const val = try eval(env, arg_elems[0]);
                    return CtValue{ .bool_val = val == .tuple };
                }
            }

            // is_list(value) — check if value is a list
            if (std.mem.eql(u8, form_name, "is_list")) {
                if (arg_elems.len == 1) {
                    const val = try eval(env, arg_elems[0]);
                    return CtValue{ .bool_val = val == .list };
                }
            }

            // is_atom(value) — check if value is an atom
            if (std.mem.eql(u8, form_name, "is_atom")) {
                if (arg_elems.len == 1) {
                    const val = try eval(env, arg_elems[0]);
                    return CtValue{ .bool_val = val == .atom };
                }
            }

            // length(list_or_tuple) — get length
            if (std.mem.eql(u8, form_name, "length")) {
                if (arg_elems.len == 1) {
                    const val = try eval(env, arg_elems[0]);
                    if (val == .list) return CtValue{ .int = @intCast(val.list.elems.len) };
                    if (val == .tuple) return CtValue{ .int = @intCast(val.tuple.elems.len) };
                }
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

    // Leaf values
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
