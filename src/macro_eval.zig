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

            // split_words(string) — split a string on whitespace, return list of strings
            if (std.mem.eql(u8, form_name, "split_words")) {
                if (arg_elems.len == 1) {
                    const val = try eval(env, arg_elems[0]);
                    // Extract the string content from a wrapped literal {string, meta, nil}
                    const content = if (val == .string)
                        val.string
                    else if (val == .tuple and val.tuple.elems.len == 3 and val.tuple.elems[0] == .string)
                        val.tuple.elems[0].string
                    else
                        return .nil;

                    var words : std.ArrayListUnmanaged(CtValue) = .empty;
                    var i: usize = 0;
                    while (i < content.len) {
                        while (i < content.len and (content[i] == ' ' or content[i] == '\t' or content[i] == '\n' or content[i] == '\r')) : (i += 1) {}
                        if (i >= content.len) break;
                        const word_start = i;
                        while (i < content.len and content[i] != ' ' and content[i] != '\t' and content[i] != '\n' and content[i] != '\r') : (i += 1) {}
                        const word = content[word_start..i];
                        // Wrap each word as a 3-tuple string literal: {word, [], nil}
                        const word_elems = try env.alloc.alloc(CtValue, 3);
                        word_elems[0] = .{ .string = word };
                        word_elems[1] = .{ .list = .{ .alloc_id = 0, .elems = &.{} } };
                        word_elems[2] = .nil;
                        const word_id = env.store.alloc(env.alloc, .tuple, null);
                        try words.append(env.alloc, CtValue{ .tuple = .{ .alloc_id = word_id, .elems = word_elems } });
                    }
                    const list_id = env.store.alloc(env.alloc, .list, null);
                    return CtValue{ .list = .{ .alloc_id = list_id, .elems = try words.toOwnedSlice(env.alloc) } };
                }
            }

            // slugify(string) — convert "hello world" to "hello_world"
            if (std.mem.eql(u8, form_name, "slugify")) {
                if (arg_elems.len == 1) {
                    const val = try eval(env, arg_elems[0]);
                    const content = extractString(val) orelse return .nil;
                    const result = try env.alloc.alloc(u8, content.len);
                    for (content, 0..) |c, i| {
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
                    return CtValue{ .string = result };
                }
            }

            // string_concat(a, b) — concatenate two strings at compile time
            if (std.mem.eql(u8, form_name, "string_concat")) {
                if (arg_elems.len == 2) {
                    const a = try eval(env, arg_elems[0]);
                    const b = try eval(env, arg_elems[1]);
                    const sa = extractString(a) orelse return .nil;
                    const sb = extractString(b) orelse return .nil;
                    const result = std.fmt.allocPrint(env.alloc, "{s}{s}", .{ sa, sb }) catch return .nil;
                    return CtValue{ .string = result };
                }
            }

            // make_fn_decl(name, body) — construct a {:fn, meta, clauses} CtValue
            // for a zero-param pub function returning String.
            // name: string (function name)
            // body: CtValue (the function body expression/block)
            if (std.mem.eql(u8, form_name, "make_fn_decl")) {
                if (arg_elems.len == 2) {
                    const name_val = try eval(env, arg_elems[0]);
                    const body_val = try eval(env, arg_elems[1]);
                    const name_str = extractString(name_val) orelse return .nil;
                    return buildFnDeclCtValue(env.alloc, env.store, name_str, body_val) catch return .nil;
                }
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

            // inject_setup(body, setup_body, teardown_body) — walk a describe block body,
            // find test/3 calls (test with context param), and inject setup_body before
            // and teardown_body after the test body. test/2 calls get no injection.
            // Returns the modified body.
            if (std.mem.eql(u8, form_name, "inject_setup")) {
                if (arg_elems.len == 3) {
                    const body = try eval(env, arg_elems[0]);
                    const setup_body = try eval(env, arg_elems[1]);
                    const teardown_body = try eval(env, arg_elems[2]);
                    return injectSetupIntoTests(env.alloc, env.store, body, setup_body, teardown_body) catch return .nil;
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
/// find test/3 calls (tests with a context parameter), and for each one:
/// - Replace the test body with: { ctx = <setup_body>; <original_body>; <teardown_body> }
/// test/2 calls (no context) are left unchanged but get teardown injected.
/// setup() and teardown() calls in the body are removed (consumed).
fn injectSetupIntoTests(
    alloc: Allocator,
    store: *AllocationStore,
    body: CtValue,
    setup_body: CtValue,
    teardown_body: CtValue,
) !CtValue {
    // Body should be a __block__: {:__block__, meta, [stmts...]}
    // Or a single expression (just one statement)
    if (body != .tuple or body.tuple.elems.len != 3) return body;

    const form = body.tuple.elems[0];
    const meta = body.tuple.elems[1];
    const args = body.tuple.elems[2];

    // Check if it's a __block__
    if (form == .atom and std.mem.eql(u8, form.atom, "__block__") and args == .list) {
        var new_stmts : std.ArrayListUnmanaged(CtValue) = .empty;

        for (args.list.elems) |stmt| {
            // Skip setup() and teardown() calls — they've been consumed
            if (isCallNamed(stmt, "setup") or isCallNamed(stmt, "teardown")) continue;

            // Check if this is a test/3 call: {:test, meta, [name, ctx_var, body]}
            if (isCallNamed(stmt, "test")) {
                const test_args = stmt.tuple.elems[2];
                if (test_args == .list and test_args.list.elems.len == 3 and setup_body != .nil) {
                    // test/3: inject setup body as ctx assignment + teardown after
                    const test_name = test_args.list.elems[0];
                    // ctx_var (index 1) is ignored — we always use "ctx"
                    const test_body = test_args.list.elems[2];

                    // Build new body: {:__block__, [], [ctx = setup_body, original_body, teardown_body]}
                    const empty = try ast_data.emptyList(alloc, store);
                    // Build ctx as a var_ref form {:ctx, [], nil} not a bare atom
                    const ctx_var = try ast_data.makeTuple3(alloc, store, .{ .atom = "ctx" }, empty, .nil);
                    const ctx_assign = try ast_data.makeTuple3(alloc, store, .{ .atom = "=" }, empty, try ast_data.makeList(alloc, store, &.{ ctx_var, setup_body }));

                    var body_stmts : std.ArrayListUnmanaged(CtValue) = .empty;
                    try body_stmts.append(alloc, ctx_assign);
                    try body_stmts.append(alloc, test_body);
                    if (teardown_body != .nil) try body_stmts.append(alloc, teardown_body);
                    const new_test_body = try ast_data.makeTuple3(alloc, store, .{ .atom = "__block__" }, empty, try ast_data.makeListFromSlice(alloc, store, body_stmts.items));

                    // Build new test/2 call with modified body (context handled internally)
                    const new_test = try ast_data.makeTuple3(alloc, store, .{ .atom = "test" }, meta, try ast_data.makeList(alloc, store, &.{ test_name, new_test_body }));
                    try new_stmts.append(alloc, new_test);
                    continue;
                } else if (test_args == .list and test_args.list.elems.len == 2 and teardown_body != .nil) {
                    // test/2: inject teardown after body
                    const test_name = test_args.list.elems[0];
                    const test_body = test_args.list.elems[1];

                    const empty = try ast_data.emptyList(alloc, store);
                    var body_stmts : std.ArrayListUnmanaged(CtValue) = .empty;
                    try body_stmts.append(alloc, test_body);
                    try body_stmts.append(alloc, teardown_body);
                    const new_test_body = try ast_data.makeTuple3(alloc, store, .{ .atom = "__block__" }, empty, try ast_data.makeListFromSlice(alloc, store, body_stmts.items));

                    const new_test = try ast_data.makeTuple3(alloc, store, .{ .atom = "test" }, meta, try ast_data.makeList(alloc, store, &.{ test_name, new_test_body }));
                    try new_stmts.append(alloc, new_test);
                    continue;
                }
            }

            // Other statements pass through unchanged
            try new_stmts.append(alloc, stmt);
        }

        return ast_data.makeTuple3(alloc, store, form, meta, try ast_data.makeListFromSlice(alloc, store, new_stmts.items));
    }

    return body;
}

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

/// Build a CtValue representing a zero-param pub function declaration
/// with String return type:
///   {:fn, [{:visibility, "pub"}], [{:->, [], [{:name, [], []}, [{:return, :String}, {:do, body}]]}]}
fn buildFnDeclCtValue(alloc: Allocator, store: *AllocationStore, name: []const u8, body: CtValue) !CtValue {
    const empty = try ast_data.emptyList(alloc, store);

    // Head: {:name, [], []} — function name with no params
    const head = try ast_data.makeTuple3(alloc, store, .{ .atom = name }, empty, empty);

    // Return type: :String
    const return_pair = try ast_data.makeTuple2(alloc, store, .{ .atom = "return" }, .{ .atom = "String" });

    // Body: {:do, body_expr}
    const do_pair = try ast_data.makeTuple2(alloc, store, .{ .atom = "do" }, body);

    // Opts: [{:return, :String}, {:do, body}]
    const opts = try ast_data.makeList(alloc, store, &.{ return_pair, do_pair });

    // Clause args: [head, opts]
    const clause_args = try ast_data.makeList(alloc, store, &.{ head, opts });

    // Clause: {:->, [], [head, opts]}
    const clause = try ast_data.makeTuple3(alloc, store, .{ .atom = "->" }, empty, clause_args);

    // Clauses list
    const clauses = try ast_data.makeList(alloc, store, &.{clause});

    // Meta: [{:visibility, "pub"}]
    const vis_pair = try ast_data.makeTuple2(alloc, store, .{ .atom = "visibility" }, .{ .string = "pub" });
    const meta = try ast_data.makeList(alloc, store, &.{vis_pair});

    // Function: {:fn, meta, clauses}
    return ast_data.makeTuple3(alloc, store, .{ .atom = "fn" }, meta, clauses);
}
