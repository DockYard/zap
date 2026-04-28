// ============================================================
// AST-as-Data: Bidirectional converter between ast.Expr and CtValue
//
// Every AST node maps to a 3-tuple: {form, metadata, arguments}
// - form: atom or value identifying the node type
// - metadata: keyword list with line/col/type info
// - arguments: list of child nodes, or nil for leaves
//
// Literals are always wrapped: 42 → {42, [], nil}
// Variables: x → {:x, [], nil}
// Calls: foo(1, 2) → {:foo, [], [1_ast, 2_ast]}
// Operators: 1 + 2 → {:+, [], [1_ast, 2_ast]}
// ============================================================

const std = @import("std");
const ast = @import("ast.zig");
const ctfe = @import("ctfe.zig");
const CtValue = ctfe.CtValue;
const AllocId = ctfe.AllocId;
const AllocationStore = ctfe.AllocationStore;
const Allocator = std.mem.Allocator;

/// Convert an ast.Expr to its CtValue 3-tuple representation.
pub fn exprToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    expr: *const ast.Expr,
) error{OutOfMemory}!CtValue {
    return switch (expr.*) {
        // Literals — wrapped in 3-tuples: {value, metadata, nil}
        .int_literal => |v| makeTuple3(alloc, store, .{ .int = v.value }, try metaToList(alloc, store, v.meta, null), .nil),
        .float_literal => |v| makeTuple3(alloc, store, .{ .float = v.value }, try metaToList(alloc, store, v.meta, null), .nil),
        .string_literal => |v| makeTuple3(alloc, store, .{ .string = interner.get(v.value) }, try metaToList(alloc, store, v.meta, null), .nil),
        .atom_literal => |v| blk: {
            // Prefix atom names with ":" to distinguish from variables in round-trip
            const name = interner.get(v.value);
            const prefixed = try std.fmt.allocPrint(alloc, ":{s}", .{name});
            break :blk makeTuple3(alloc, store, .{ .atom = prefixed }, try metaToList(alloc, store, v.meta, null), .nil);
        },
        .bool_literal => |v| makeTuple3(alloc, store, .{ .bool_val = v.value }, try metaToList(alloc, store, v.meta, null), .nil),
        .nil_literal => |v| makeTuple3(alloc, store, .nil, try metaToList(alloc, store, v.meta, null), .nil),

        // Variables: {:name, meta, nil}
        .var_ref => |v| makeTuple3(alloc, store, .{ .atom = interner.get(v.name) }, try metaToList(alloc, store, v.meta, null), .nil),

        // Binary operators: {:op, meta, [left, right]}
        .binary_op => |v| {
            const op_atom: CtValue = .{ .atom = binopToString(v.op) };
            const left = try exprToCtValue(alloc, interner, store, v.lhs);
            const right = try exprToCtValue(alloc, interner, store, v.rhs);
            const args = try makeList(alloc, store, &.{ left, right });
            return makeTuple3(alloc, store, op_atom, try metaToList(alloc, store, v.meta, null), args);
        },

        // Unary operators: {:op, meta, [operand]}
        .unary_op => |v| {
            const op_atom: CtValue = .{ .atom = unopToString(v.op) };
            const operand = try exprToCtValue(alloc, interner, store, v.operand);
            const args = try makeList(alloc, store, &.{operand});
            return makeTuple3(alloc, store, op_atom, try metaToList(alloc, store, v.meta, null), args);
        },

        // Calls: {:name, meta, [args...]}
        .call => |v| {
            const form = try calleeToCtValue(alloc, interner, store, v.callee);
            var arg_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.args) |arg| {
                try arg_vals.append(alloc, try exprToCtValue(alloc, interner, store, arg));
            }
            const args = try makeListFromSlice(alloc, store, arg_vals.items);
            return makeTuple3(alloc, store, form, try metaToList(alloc, store, v.meta, null), args);
        },

        .anonymous_function => |v| blk: {
            const name = interner.get(v.decl.name);
            const params = try paramsToCtList(alloc, interner, store, v.decl.clauses[0].params);
            const body = if (v.decl.clauses[0].body) |body_stmts|
                try blockToCtValue(alloc, interner, store, body_stmts)
            else
                .nil;
            const ret_type = if (v.decl.clauses[0].return_type) |rt|
                try typeExprToCtValue(alloc, interner, store, rt)
            else
                CtValue.nil;
            const args = try makeList(alloc, store, &.{ .{ .atom = name }, params, body, ret_type });
            break :blk makeTuple3(alloc, store, .{ .atom = "fn" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Pipe: {:|>, meta, [left, right]}
        .pipe => |v| {
            const left = try exprToCtValue(alloc, interner, store, v.lhs);
            const right = try exprToCtValue(alloc, interner, store, v.rhs);
            const args = try makeList(alloc, store, &.{ left, right });
            return makeTuple3(alloc, store, .{ .atom = "|>" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Field access: {:., meta, [object, :field]}
        .field_access => |v| {
            const obj = try exprToCtValue(alloc, interner, store, v.object);
            const field: CtValue = .{ .atom = interner.get(v.field) };
            const args = try makeList(alloc, store, &.{ obj, field });
            return makeTuple3(alloc, store, .{ .atom = "." }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Tuple: {:{}, meta, [elements...]}
        .tuple => |v| {
            var elem_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.elements) |elem| {
                try elem_vals.append(alloc, try exprToCtValue(alloc, interner, store, elem));
            }
            const args = try makeListFromSlice(alloc, store, elem_vals.items);
            return makeTuple3(alloc, store, .{ .atom = "{}" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // List: bare list [elements...]
        .list => |v| {
            var elem_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.elements) |elem| {
                try elem_vals.append(alloc, try exprToCtValue(alloc, interner, store, elem));
            }
            return makeListFromSlice(alloc, store, elem_vals.items);
        },

        // Block: {:__block__, meta, [stmts...]}
        .block => |v| {
            var stmt_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.stmts) |stmt| {
                try stmt_vals.append(alloc, try stmtToCtValue(alloc, interner, store, stmt));
            }
            const args = try makeListFromSlice(alloc, store, stmt_vals.items);
            return makeTuple3(alloc, store, .{ .atom = "__block__" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // If: {:if, meta, [condition, [do: then, else: else]]}
        .if_expr => |v| {
            const cond = try exprToCtValue(alloc, interner, store, v.condition);
            const then_val = try blockToCtValue(alloc, interner, store, v.then_block);
            var kw_elems : std.ArrayListUnmanaged(CtValue) = .empty;
            try kw_elems.append(alloc, try makeKeywordPair(alloc, store, "do", then_val));
            if (v.else_block) |else_block| {
                const else_val = try blockToCtValue(alloc, interner, store, else_block);
                try kw_elems.append(alloc, try makeKeywordPair(alloc, store, "else", else_val));
            }
            const kw_list = try makeListFromSlice(alloc, store, kw_elems.items);
            const args = try makeList(alloc, store, &.{ cond, kw_list });
            return makeTuple3(alloc, store, .{ .atom = "if" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Case: {:case, meta, [subject, [do: [clauses...]]]}
        .case_expr => |v| {
            const subject = try exprToCtValue(alloc, interner, store, v.scrutinee);
            var clause_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.clauses) |clause| {
                try clause_vals.append(alloc, try caseClauseToCtValue(alloc, interner, store, clause));
            }
            const clauses_list = try makeListFromSlice(alloc, store, clause_vals.items);
            const do_pair = try makeKeywordPair(alloc, store, "do", clauses_list);
            const kw_list = try makeList(alloc, store, &.{do_pair});
            const args = try makeList(alloc, store, &.{ subject, kw_list });
            return makeTuple3(alloc, store, .{ .atom = "case" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Module ref: {:__aliases__, meta, [:Part1, :Part2, ...]}
        .module_ref => |v| {
            var parts : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.name.parts) |part| {
                try parts.append(alloc, CtValue{ .atom = interner.get(part) });
            }
            const args = try makeListFromSlice(alloc, store, parts.items);
            return makeTuple3(alloc, store, .{ .atom = "__aliases__" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Quote: {:quote, meta, [body]}
        .quote_expr => |v| {
            var body_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.body) |stmt| {
                try body_vals.append(alloc, try stmtToCtValue(alloc, interner, store, stmt));
            }
            const body_list = try makeListFromSlice(alloc, store, body_vals.items);
            const args = try makeList(alloc, store, &.{body_list});
            return makeTuple3(alloc, store, .{ .atom = "quote" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Unquote: {:unquote, meta, [expr]}
        .unquote_expr => |v| {
            const inner = try exprToCtValue(alloc, interner, store, v.expr);
            const args = try makeList(alloc, store, &.{inner});
            return makeTuple3(alloc, store, .{ .atom = "unquote" }, try metaToList(alloc, store, v.meta, null), args);
        },

        .unquote_splicing_expr => |v| {
            const inner = try exprToCtValue(alloc, interner, store, v.expr);
            const args = try makeList(alloc, store, &.{inner});
            return makeTuple3(alloc, store, .{ .atom = "unquote_splicing" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Type annotated: {:::, [], [expr, type]}
        .type_annotated => |v| {
            const inner = try exprToCtValue(alloc, interner, store, v.expr);
            const type_val = try typeExprToCtValue(alloc, interner, store, v.type_expr);
            const args_list = try makeList(alloc, store, &.{ inner, type_val });
            return makeTuple3(alloc, store, .{ .atom = "::" }, try metaToList(alloc, store, v.meta, null), args_list);
        },

        // Error pipe: {:~>, meta, [chain, handler]}
        .error_pipe => |v| {
            const chain = try exprToCtValue(alloc, interner, store, v.chain);
            const handler = switch (v.handler) {
                .block => |clauses| blk: {
                    var clause_vals : std.ArrayListUnmanaged(CtValue) = .empty;
                    for (clauses) |clause| {
                        try clause_vals.append(alloc, try caseClauseToCtValue(alloc, interner, store, clause));
                    }
                    break :blk try makeListFromSlice(alloc, store, clause_vals.items);
                },
                .function => |func| try exprToCtValue(alloc, interner, store, func),
            };
            const args = try makeList(alloc, store, &.{ chain, handler });
            return makeTuple3(alloc, store, .{ .atom = "~>" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Map: {:%{}, meta, [pairs...]}
        .map => |v| {
            var pair_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.fields) |field| {
                const key = try exprToCtValue(alloc, interner, store, field.key);
                const val = try exprToCtValue(alloc, interner, store, field.value);
                try pair_vals.append(alloc, try makeTuple2(alloc, store, key, val));
            }
            const args = try makeListFromSlice(alloc, store, pair_vals.items);
            return makeTuple3(alloc, store, .{ .atom = "%{}" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Struct: {:%, meta, [name, {:%{}, [], [fields...]}, update_source_or_nil]}
        .struct_expr => |v| {
            var field_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.fields) |field| {
                const key: CtValue = .{ .atom = interner.get(field.name) };
                const val = try exprToCtValue(alloc, interner, store, field.value);
                try field_vals.append(alloc, try makeTuple2(alloc, store, key, val));
            }
            const fields_list = try makeListFromSlice(alloc, store, field_vals.items);
            const map_node = try makeTuple3(alloc, store, .{ .atom = "%{}" }, try emptyList(alloc, store), fields_list);
            var name_parts : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.module_name.parts) |part| {
                try name_parts.append(alloc, CtValue{ .atom = interner.get(part) });
            }
            const name_val = try makeListFromSlice(alloc, store, name_parts.items);
            const update_val: CtValue = if (v.update_source) |source|
                try exprToCtValue(alloc, interner, store, source)
            else
                .nil;
            const args = try makeList(alloc, store, &.{ name_val, map_node, update_val });
            return makeTuple3(alloc, store, .{ .atom = "%" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Intrinsic: {:__intrinsic__, meta, [:name, args...]}
        .intrinsic => |v| {
            var arg_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            try arg_vals.append(alloc, CtValue{ .atom = interner.get(v.name) });
            for (v.args) |arg| {
                try arg_vals.append(alloc, try exprToCtValue(alloc, interner, store, arg));
            }
            const args = try makeListFromSlice(alloc, store, arg_vals.items);
            return makeTuple3(alloc, store, .{ .atom = "__intrinsic__" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // String interpolation: {:<<>>, meta, [parts...]} where each part is a string or expr
        .string_interpolation => |v| {
            var part_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.parts) |part| {
                switch (part) {
                    .literal => |sid| try part_vals.append(alloc, try makeTuple3(alloc, store, .{ .string = interner.get(sid) }, try emptyList(alloc, store), .nil)),
                    .expr => |e| try part_vals.append(alloc, try exprToCtValue(alloc, interner, store, e)),
                }
            }
            const args = try makeListFromSlice(alloc, store, part_vals.items);
            return makeTuple3(alloc, store, .{ .atom = "<<>>" }, try metaToList(alloc, store, v.meta, null), args);
        },
        .unwrap => |v| {
            const inner = try exprToCtValue(alloc, interner, store, v.expr);
            const args = try makeList(alloc, store, &.{inner});
            return makeTuple3(alloc, store, .{ .atom = "!" }, try metaToList(alloc, store, v.meta, null), args);
        },
        .panic_expr => |v| {
            const msg = try exprToCtValue(alloc, interner, store, v.message);
            const args = try makeList(alloc, store, &.{msg});
            return makeTuple3(alloc, store, .{ .atom = "panic" }, try metaToList(alloc, store, v.meta, null), args);
        },
        .cond_expr => |v| {
            // {:cond, meta, [do: [clauses...]]} where each clause is {:->, [], [[condition], body]}
            var clause_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.clauses) |clause| {
                const cond = try exprToCtValue(alloc, interner, store, clause.condition);
                const body = try blockToCtValue(alloc, interner, store, clause.body);
                const cond_list = try makeList(alloc, store, &.{cond});
                const clause_args = try makeList(alloc, store, &.{ cond_list, body });
                try clause_vals.append(alloc, try makeTuple3(alloc, store, .{ .atom = "->" }, try emptyList(alloc, store), clause_args));
            }
            const clauses_list = try makeListFromSlice(alloc, store, clause_vals.items);
            const do_pair = try makeKeywordPair(alloc, store, "do", clauses_list);
            const kw_list = try makeList(alloc, store, &.{do_pair});
            return makeTuple3(alloc, store, .{ .atom = "cond" }, try metaToList(alloc, store, v.meta, null), kw_list);
        },
        .attr_ref => |v| {
            const name: CtValue = .{ .atom = interner.get(v.name) };
            const args = try makeList(alloc, store, &.{name});
            return makeTuple3(alloc, store, .{ .atom = "@" }, try metaToList(alloc, store, v.meta, null), args);
        },
        .binary_literal => |v| {
            var seg_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.segments) |seg| {
                const val = switch (seg.value) {
                    .expr => |e| try exprToCtValue(alloc, interner, store, e),
                    .pattern => |p| try patternToCtValue(alloc, interner, store, p),
                    .string_literal => |s| try makeTuple3(alloc, store, .{ .string = interner.get(s) }, try emptyList(alloc, store), .nil),
                };
                try seg_vals.append(alloc, val);
            }
            return makeTuple3(alloc, store, .{ .atom = "<<>>" }, try metaToList(alloc, store, v.meta, null), try makeListFromSlice(alloc, store, seg_vals.items));
        },
        .function_ref => |v| {
            const name: CtValue = .{ .atom = interner.get(v.function) };
            const arity: CtValue = .{ .int = @intCast(v.arity) };
            const args = try makeList(alloc, store, &.{ name, arity });
            return makeTuple3(alloc, store, .{ .atom = "&" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // For comprehension: {:for, meta, [var_pattern, iterable, filter_or_nil, body]}
        // var_pattern is the full Pattern serialization — supports tuple
        // destructure (`{k, v}`), tagged tuples (`{:ok, n}`), cons heads,
        // wildcards, etc. — going through the same patternToCtValue helper
        // that case-arms and function params use.
        .for_expr => |v| {
            const var_pattern_val = try patternToCtValue(alloc, interner, store, v.var_pattern);
            const iterable = try exprToCtValue(alloc, interner, store, v.iterable);
            const filter_val = if (v.filter) |f| try exprToCtValue(alloc, interner, store, f) else CtValue.nil;
            const body = try exprToCtValue(alloc, interner, store, v.body);
            const args = try makeList(alloc, store, &.{ var_pattern_val, iterable, filter_val, body });
            return makeTuple3(alloc, store, .{ .atom = "for" }, try metaToList(alloc, store, v.meta, null), args);
        },

        // Range: {:.., meta, [start, end, step_or_nil]}
        .range => |v| {
            const start = try exprToCtValue(alloc, interner, store, v.start);
            const end_val = try exprToCtValue(alloc, interner, store, v.end);
            const step_val = if (v.step) |s| try exprToCtValue(alloc, interner, store, s) else CtValue.nil;
            const args = try makeList(alloc, store, &.{ start, end_val, step_val });
            return makeTuple3(alloc, store, .{ .atom = ".." }, try metaToList(alloc, store, v.meta, null), args);
        },

        // List cons expression: {:cons, meta, [head, tail]}
        .list_cons_expr => |v| {
            const head = try exprToCtValue(alloc, interner, store, v.head);
            const tail = try exprToCtValue(alloc, interner, store, v.tail);
            const args = try makeList(alloc, store, &.{ head, tail });
            return makeTuple3(alloc, store, .{ .atom = "cons" }, try metaToList(alloc, store, v.meta, null), args);
        },
    };
}

/// Convert a statement to CtValue.
pub fn stmtToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    stmt: ast.Stmt,
) error{OutOfMemory}!CtValue {
    return switch (stmt) {
        .expr => |e| exprToCtValue(alloc, interner, store, e),
        .assignment => |a| {
            const target = try patternToCtValue(alloc, interner, store, a.pattern);
            const value = try exprToCtValue(alloc, interner, store, a.value);
            const args = try makeList(alloc, store, &.{ target, value });
            return makeTuple3(alloc, store, .{ .atom = "=" }, try emptyList(alloc, store), args);
        },
        .function_decl => |f| return functionDeclToCtValue(alloc, interner, store, f),
        .macro_decl => |m| {
            const fn_ct = try functionDeclToCtValue(alloc, interner, store, m);
            if (fn_ct == .tuple and fn_ct.tuple.elems.len == 3) {
                const new_elems = try alloc.alloc(CtValue, 3);
                new_elems[0] = .{ .atom = "macro" };
                new_elems[1] = fn_ct.tuple.elems[1];
                new_elems[2] = fn_ct.tuple.elems[2];
                const id = store.alloc(alloc, .tuple, null);
                return CtValue{ .tuple = .{ .alloc_id = id, .elems = new_elems } };
            }
            return fn_ct;
        },
        .import_decl => |id| {
            var parts : std.ArrayListUnmanaged(CtValue) = .empty;
            for (id.module_path.parts) |part| {
                try parts.append(alloc, CtValue{ .atom = interner.get(part) });
            }
            const aliases = try makeTuple3(alloc, store, .{ .atom = "__aliases__" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, parts.items));
            const args = try makeList(alloc, store, &.{aliases});
            return makeTuple3(alloc, store, .{ .atom = "import" }, try emptyList(alloc, store), args);
        },
    };
}

/// Convert a case clause to CtValue: {:->, meta, [[pattern], body]}
fn caseClauseToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    clause: ast.CaseClause,
) error{OutOfMemory}!CtValue {
    // Pattern as a list (like Elixir: left side of -> is always a list)
    const pat_val = try patternToCtValue(alloc, interner, store, clause.pattern);
    const pattern_list = try makeList(alloc, store, &.{pat_val});

    // Body
    const body = try blockToCtValue(alloc, interner, store, clause.body);

    const args = try makeList(alloc, store, &.{ pattern_list, body });
    return makeTuple3(alloc, store, .{ .atom = "->" }, try emptyList(alloc, store), args);
}

/// Convert a pattern to CtValue.
pub fn patternToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    pattern: *const ast.Pattern,
) error{OutOfMemory}!CtValue {
    return switch (pattern.*) {
        .wildcard => |v| makeTuple3(alloc, store, .{ .atom = "_" }, try metaToList(alloc, store, v.meta, null), .nil),
        .bind => |v| makeTuple3(alloc, store, .{ .atom = interner.get(v.name) }, try metaToList(alloc, store, v.meta, null), .nil),
        .literal => |v| switch (v) {
            .int => |lit| makeTuple3(alloc, store, .{ .int = lit.value }, try metaToList(alloc, store, lit.meta, null), .nil),
            .float => |lit| makeTuple3(alloc, store, .{ .float = lit.value }, try metaToList(alloc, store, lit.meta, null), .nil),
            .string => |lit| makeTuple3(alloc, store, .{ .string = interner.get(lit.value) }, try metaToList(alloc, store, lit.meta, null), .nil),
            .atom => |lit| makeTuple3(alloc, store, .{ .atom = interner.get(lit.value) }, try metaToList(alloc, store, lit.meta, null), .nil),
            .bool_lit => |lit| makeTuple3(alloc, store, .{ .bool_val = lit.value }, try metaToList(alloc, store, lit.meta, null), .nil),
            .nil => |lit| makeTuple3(alloc, store, .nil, try metaToList(alloc, store, lit.meta, null), .nil),
        },
        .pin => |v| {
            const name_val: CtValue = .{ .atom = interner.get(v.name) };
            const args = try makeList(alloc, store, &.{name_val});
            return makeTuple3(alloc, store, .{ .atom = "^" }, try metaToList(alloc, store, v.meta, null), args);
        },
        .tuple => |v| {
            var elems : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.elements) |elem| {
                try elems.append(alloc, try patternToCtValue(alloc, interner, store, elem));
            }
            const args = try makeListFromSlice(alloc, store, elems.items);
            return makeTuple3(alloc, store, .{ .atom = "{}" }, try metaToList(alloc, store, v.meta, null), args);
        },
        .list => |v| {
            var elems : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.elements) |elem| {
                try elems.append(alloc, try patternToCtValue(alloc, interner, store, elem));
            }
            return makeListFromSlice(alloc, store, elems.items);
        },
        .list_cons => |v| {
            var head_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.heads) |h| {
                try head_vals.append(alloc, try patternToCtValue(alloc, interner, store, h));
            }
            const heads_list = try makeListFromSlice(alloc, store, head_vals.items);
            const tail = try patternToCtValue(alloc, interner, store, v.tail);
            const args = try makeList(alloc, store, &.{ heads_list, tail });
            return makeTuple3(alloc, store, .{ .atom = "|" }, try metaToList(alloc, store, v.meta, null), args);
        },
        .struct_pattern => |v| {
            // {:%, meta, [module_name, {:%{}, [], [field_pairs...]}]}
            var parts : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.module_name.parts) |part| {
                try parts.append(alloc, CtValue{ .atom = interner.get(part) });
            }
            const name_val = try makeTuple3(alloc, store, .{ .atom = "__aliases__" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, parts.items));
            var field_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.fields) |field| {
                const fname: CtValue = .{ .atom = interner.get(field.name) };
                const fpat = try patternToCtValue(alloc, interner, store, field.pattern);
                try field_vals.append(alloc, try makeTuple2(alloc, store, fname, fpat));
            }
            const map_node = try makeTuple3(alloc, store, .{ .atom = "%{}" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, field_vals.items));
            const args = try makeList(alloc, store, &.{ name_val, map_node });
            return makeTuple3(alloc, store, .{ .atom = "%" }, try metaToList(alloc, store, v.meta, null), args);
        },
        .map => |v| {
            // {:%{}, meta, [field_pairs...]}
            var field_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.fields) |field| {
                const key = try exprToCtValue(alloc, interner, store, field.key);
                const val = try patternToCtValue(alloc, interner, store, field.value);
                try field_vals.append(alloc, try makeTuple2(alloc, store, key, val));
            }
            return makeTuple3(alloc, store, .{ .atom = "%{}" }, try metaToList(alloc, store, v.meta, null), try makeListFromSlice(alloc, store, field_vals.items));
        },
        .paren => |v| patternToCtValue(alloc, interner, store, v.inner),
        .binary => |v| {
            // {:<<>>, meta, [segments...]} — simplified representation
            var seg_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.segments) |seg| {
                const val = switch (seg.value) {
                    .pattern => |p| try patternToCtValue(alloc, interner, store, p),
                    .expr => |e| try exprToCtValue(alloc, interner, store, e),
                    .string_literal => |s| try makeTuple3(alloc, store, .{ .string = interner.get(s) }, try emptyList(alloc, store), .nil),
                };
                try seg_vals.append(alloc, val);
            }
            return makeTuple3(alloc, store, .{ .atom = "<<>>" }, try metaToList(alloc, store, v.meta, null), try makeListFromSlice(alloc, store, seg_vals.items));
        },
    };
}

// ============================================================
// Helper functions
// ============================================================

/// Build a 3-tuple CtValue.
pub fn makeTuple3(alloc: Allocator, store: *AllocationStore, form: CtValue, meta: CtValue, args: CtValue) !CtValue {
    const elems = try alloc.alloc(CtValue, 3);
    elems[0] = form;
    elems[1] = meta;
    elems[2] = args;
    const id = store.alloc(alloc, .tuple, null);
    return .{ .tuple = .{ .alloc_id = id, .elems = elems } };
}

/// Build a 2-tuple CtValue (for keyword pairs, map entries).
pub fn makeTuple2(alloc: Allocator, store: *AllocationStore, first: CtValue, second: CtValue) !CtValue {
    const elems = try alloc.alloc(CtValue, 2);
    elems[0] = first;
    elems[1] = second;
    const id = store.alloc(alloc, .tuple, null);
    return .{ .tuple = .{ .alloc_id = id, .elems = elems } };
}

/// Build a CtValue list from inline items.
pub fn makeList(alloc: Allocator, store: *AllocationStore, items: []const CtValue) !CtValue {
    const elems = try alloc.alloc(CtValue, items.len);
    @memcpy(elems, items);
    const id = store.alloc(alloc, .list, null);
    return .{ .list = .{ .alloc_id = id, .elems = elems } };
}

/// Build a CtValue list from a slice.
pub fn makeListFromSlice(alloc: Allocator, store: *AllocationStore, items: []const CtValue) !CtValue {
    const elems = try alloc.alloc(CtValue, items.len);
    @memcpy(elems, items);
    const id = store.alloc(alloc, .list, null);
    return .{ .list = .{ .alloc_id = id, .elems = elems } };
}

/// Build an empty list.
pub fn emptyList(alloc: Allocator, store: *AllocationStore) !CtValue {
    return makeList(alloc, store, &.{});
}

/// Build a keyword pair: {atom, value} as a 2-tuple.
fn makeKeywordPair(alloc: Allocator, store: *AllocationStore, key: []const u8, value: CtValue) !CtValue {
    return makeTuple2(alloc, store, .{ .atom = key }, value);
}

/// Convert NodeMeta to a keyword list CtValue.
fn metaToList(alloc: Allocator, store: *AllocationStore, meta: ast.NodeMeta, type_name: ?[]const u8) !CtValue {
    var pairs : std.ArrayListUnmanaged(CtValue) = .empty;
    if (meta.span.line > 0) {
        try pairs.append(alloc, try makeKeywordPair(alloc, store, "line", .{ .int = @intCast(meta.span.line) }));
    }
    if (meta.span.col > 0) {
        try pairs.append(alloc, try makeKeywordPair(alloc, store, "col", .{ .int = @intCast(meta.span.col) }));
    }
    if (type_name) |tn| {
        try pairs.append(alloc, try makeKeywordPair(alloc, store, "type", .{ .atom = tn }));
    }
    return makeListFromSlice(alloc, store, pairs.items);
}

/// Convert a block ([]const Stmt) to CtValue.
/// Single statement → unwrapped. Multiple → {:__block__, [], [stmts...]}.
fn blockToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    stmts: []const ast.Stmt,
) error{OutOfMemory}!CtValue {
    if (stmts.len == 1) {
        return stmtToCtValue(alloc, interner, store, stmts[0]);
    }
    var vals : std.ArrayListUnmanaged(CtValue) = .empty;
    for (stmts) |stmt| {
        try vals.append(alloc, try stmtToCtValue(alloc, interner, store, stmt));
    }
    const args = try makeListFromSlice(alloc, store, vals.items);
    return makeTuple3(alloc, store, .{ .atom = "__block__" }, try emptyList(alloc, store), args);
}

fn paramsToCtList(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    params: []const ast.Param,
) error{OutOfMemory}!CtValue {
    var vals : std.ArrayListUnmanaged(CtValue) = .empty;
    for (params) |param| {
        const pat = try patternToCtValue(alloc, interner, store, param.pattern);
        if (param.type_annotation) |type_expr| {
            const type_val = try typeExprToCtValue(alloc, interner, store, type_expr);
            try vals.append(alloc, try makeTuple3(alloc, store, .{ .atom = "::" }, try emptyList(alloc, store), try makeList(alloc, store, &.{ pat, type_val })));
        } else {
            try vals.append(alloc, pat);
        }
    }
    return makeListFromSlice(alloc, store, vals.items);
}

/// Convert a call's callee to the form atom/node.
fn calleeToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    callee: *const ast.Expr,
) error{OutOfMemory}!CtValue {
    return switch (callee.*) {
        .var_ref => |v| CtValue{ .atom = interner.get(v.name) },
        .field_access => |v| {
            const obj = try exprToCtValue(alloc, interner, store, v.object);
            const field: CtValue = .{ .atom = interner.get(v.field) };
            const args = try makeList(alloc, store, &.{ obj, field });
            return makeTuple3(alloc, store, .{ .atom = "." }, try metaToList(alloc, store, v.meta, null), args);
        },
        .module_ref => |v| {
            var parts : std.ArrayListUnmanaged(CtValue) = .empty;
            for (v.name.parts) |part| {
                try parts.append(alloc, CtValue{ .atom = interner.get(part) });
            }
            const part_list = try makeListFromSlice(alloc, store, parts.items);
            return makeTuple3(alloc, store, .{ .atom = "__aliases__" }, try emptyList(alloc, store), part_list);
        },
        else => exprToCtValue(alloc, interner, store, callee),
    };
}

/// Map binary operator to string.
fn binopToString(op: ast.BinaryOp.Op) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .rem_op => "rem",
        .equal => "==",
        .not_equal => "!=",
        .less => "<",
        .greater => ">",
        .less_equal => "<=",
        .greater_equal => ">=",
        .and_op => "&&",
        .or_op => "||",
        .concat => "<>",
        .in_op => "in",
    };
}

/// Map unary operator to string.
fn unopToString(op: ast.UnaryOp.Op) []const u8 {
    return switch (op) {
        .negate => "-",
        .not_op => "not",
    };
}

// ============================================================
// Reverse conversion: CtValue 3-tuple → ast.Expr
// ============================================================

/// Convert a CtValue 3-tuple back to an ast.Expr.
pub fn ctValueToExpr(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) error{OutOfMemory}!*const ast.Expr {
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    // A bare list represents a Zap list literal
    if (value == .list) {
        var elems : std.ArrayListUnmanaged(*const ast.Expr) = .empty;
        for (value.list.elems) |elem| {
            try elems.append(alloc, try ctValueToExpr(alloc, interner, elem));
        }
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .list = .{ .meta = meta, .elements = try elems.toOwnedSlice(alloc) } };
        return expr;
    }

    // Bare primitive CtValues — convert directly to AST expressions.
    // This handles cases where macro-generated function bodies contain
    // bare strings, atoms, ints, etc. that are not wrapped in 3-tuples.
    if (value == .string) {
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .string_literal = .{ .meta = meta, .value = try interner.intern(value.string) } };
        return expr;
    }
    if (value == .int) {
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .int_literal = .{ .meta = meta, .value = value.int } };
        return expr;
    }
    if (value == .float) {
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .float_literal = .{ .meta = meta, .value = value.float } };
        return expr;
    }
    if (value == .bool_val) {
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .bool_literal = .{ .meta = meta, .value = value.bool_val } };
        return expr;
    }
    if (value == .atom) {
        // Atoms prefixed with ":" are atom literals; otherwise treat as variable references
        if (value.atom.len > 0 and value.atom[0] == ':') {
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .atom_literal = .{ .meta = meta, .value = try interner.intern(value.atom[1..]) } };
            return expr;
        } else if (value.atom.len > 0 and (value.atom[0] == '_' or std.ascii.isLower(value.atom[0]))) {
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .var_ref = .{ .meta = meta, .name = try interner.intern(value.atom) } };
            return expr;
        }
    }
    if (value == .nil) {
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .nil_literal = .{ .meta = meta } };
        return expr;
    }

    // Must be a 3-tuple: {form, metadata, args}
    if (value != .tuple or value.tuple.elems.len != 3) {
        // Fallback: nil literal
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .nil_literal = .{ .meta = meta } };
        return expr;
    }

    const form = value.tuple.elems[0];
    // metadata is value.tuple.elems[1] — we extract line/col from it
    const node_meta = try keywordListToMeta(value.tuple.elems[1]);
    const args = value.tuple.elems[2];

    // Wrapped literals: {value, meta, nil} where args is nil
    if (args == .nil) {
        return switch (form) {
            .int => |v| blk: {
                const expr = try alloc.create(ast.Expr);
                expr.* = .{ .int_literal = .{ .meta = node_meta, .value = v } };
                break :blk expr;
            },
            .float => |v| blk: {
                const expr = try alloc.create(ast.Expr);
                expr.* = .{ .float_literal = .{ .meta = node_meta, .value = v } };
                break :blk expr;
            },
            .string => |v| blk: {
                const expr = try alloc.create(ast.Expr);
                expr.* = .{ .string_literal = .{ .meta = node_meta, .value = try interner.intern(v) } };
                break :blk expr;
            },
            .bool_val => |v| blk: {
                const expr = try alloc.create(ast.Expr);
                expr.* = .{ .bool_literal = .{ .meta = node_meta, .value = v } };
                break :blk expr;
            },
            .nil => blk: {
                const expr = try alloc.create(ast.Expr);
                expr.* = .{ .nil_literal = .{ .meta = node_meta } };
                break :blk expr;
            },
            .atom => |name| blk: {
                // Atom with nil args = variable or atom literal
                // Atoms are prefixed with ":" to distinguish from variables
                if (name.len > 0 and name[0] == ':') {
                    const expr = try alloc.create(ast.Expr);
                    expr.* = .{ .atom_literal = .{ .meta = node_meta, .value = try interner.intern(name[1..]) } };
                    break :blk expr;
                } else if (name.len > 0 and (name[0] == '_' or std.ascii.isLower(name[0]))) {
                    const expr = try alloc.create(ast.Expr);
                    expr.* = .{ .var_ref = .{ .meta = node_meta, .name = try interner.intern(name) } };
                    break :blk expr;
                } else {
                    const expr = try alloc.create(ast.Expr);
                    expr.* = .{ .atom_literal = .{ .meta = node_meta, .value = try interner.intern(name) } };
                    break :blk expr;
                }
            },
            else => blk: {
                const expr = try alloc.create(ast.Expr);
                expr.* = .{ .nil_literal = .{ .meta = node_meta } };
                break :blk expr;
            },
        };
    }

    // Node with args: {form_atom, meta, args_list}
    if (form != .atom) {
        // Non-atom form — check for dot-call: {:., meta, [object, :field]}
        // This represents a qualified function call like Module.func(args)
        if (form == .tuple and form.tuple.elems.len == 3) {
            const dot_form = form.tuple.elems[0];
            const dot_args = form.tuple.elems[2];
            if (dot_form == .atom and std.mem.eql(u8, dot_form.atom, ".") and dot_args == .list and dot_args.list.elems.len == 2) {
                // Reconstruct: object.field(args)
                const object = try ctValueToExpr(alloc, interner, dot_args.list.elems[0]);
                const field_atom = dot_args.list.elems[1];
                const field_name = if (field_atom == .atom)
                    try interner.intern(field_atom.atom)
                else
                    try interner.intern("unknown");

                const callee = try alloc.create(ast.Expr);
                callee.* = .{ .field_access = .{ .meta = node_meta, .object = object, .field = field_name } };

                // Build the call with the dot-access callee
                const arg_elems = if (args == .list) args.list.elems else &[_]CtValue{};
                var call_args: std.ArrayListUnmanaged(*const ast.Expr) = .empty;
                for (arg_elems) |arg| {
                    try call_args.append(alloc, try ctValueToExpr(alloc, interner, arg));
                }

                const expr = try alloc.create(ast.Expr);
                expr.* = .{ .call = .{
                    .meta = node_meta,
                    .callee = callee,
                    .args = try call_args.toOwnedSlice(alloc),
                } };
                return expr;
            }
        }

        // Truly unrecognized non-atom form — fallback
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .nil_literal = .{ .meta = node_meta } };
        return expr;
    }

    const form_name = form.atom;
    const args_is_nil = args == .nil;
    const arg_elems = if (args == .list) args.list.elems else &[_]CtValue{};

    // Variable reference: {:name, meta, nil}. Nil args means var_ref.
    // Distinct from zero-arg call {:name, meta, []} which has empty list.
    if (args_is_nil) {
        const interner_mut: *ast.StringInterner = @constCast(interner);
        const expr = try alloc.create(ast.Expr);
        if (form_name.len > 0 and form_name[0] == ':') {
            expr.* = .{ .atom_literal = .{ .meta = node_meta, .value = try interner_mut.intern(form_name[1..]) } };
        } else {
            expr.* = .{ .var_ref = .{ .meta = node_meta, .name = try interner_mut.intern(form_name) } };
        }
        return expr;
    }

    // Binary operators
    if (stringToBinop(form_name)) |op| {
        if (arg_elems.len == 2) {
            const lhs = try ctValueToExpr(alloc, interner, arg_elems[0]);
            const rhs = try ctValueToExpr(alloc, interner, arg_elems[1]);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .binary_op = .{ .meta = node_meta, .op = op, .lhs = lhs, .rhs = rhs } };
            return expr;
        }
    }

    // Unary operators
    if (stringToUnop(form_name)) |op| {
        if (arg_elems.len == 1) {
            const operand = try ctValueToExpr(alloc, interner, arg_elems[0]);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .unary_op = .{ .meta = node_meta, .op = op, .operand = operand } };
            return expr;
        }
    }

    // Special forms
    // Range expression: {:.., meta, [start, end, step_or_nil]}
    if (std.mem.eql(u8, form_name, "..")) {
        if (arg_elems.len >= 2) {
            const start = try ctValueToExpr(alloc, interner, arg_elems[0]);
            const end_val = try ctValueToExpr(alloc, interner, arg_elems[1]);
            const step = if (arg_elems.len >= 3 and arg_elems[2] != .nil)
                try ctValueToExpr(alloc, interner, arg_elems[2])
            else
                null;
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .range = .{ .meta = node_meta, .start = start, .end = end_val, .step = step } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "__block__")) {
        var stmts : std.ArrayListUnmanaged(ast.Stmt) = .empty;
        for (arg_elems) |elem| {
            try stmts.append(alloc, try ctValueToStmt(alloc, interner, elem));
        }
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .block = .{ .meta = node_meta, .stmts = try stmts.toOwnedSlice(alloc) } };
        return expr;
    }

    if (std.mem.eql(u8, form_name, "{}")) {
        var elems : std.ArrayListUnmanaged(*const ast.Expr) = .empty;
        for (arg_elems) |elem| {
            try elems.append(alloc, try ctValueToExpr(alloc, interner, elem));
        }
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .tuple = .{ .meta = node_meta, .elements = try elems.toOwnedSlice(alloc) } };
        return expr;
    }

    if (std.mem.eql(u8, form_name, "%{}")) {
        var fields : std.ArrayListUnmanaged(ast.MapField) = .empty;
        for (arg_elems) |pair| {
            if (pair == .tuple and pair.tuple.elems.len == 2) {
                const key = try ctValueToExpr(alloc, interner, pair.tuple.elems[0]);
                const val = try ctValueToExpr(alloc, interner, pair.tuple.elems[1]);
                try fields.append(alloc, .{ .key = key, .value = val });
            }
        }
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .map = .{ .meta = node_meta, .fields = try fields.toOwnedSlice(alloc) } };
        return expr;
    }

    // Struct expression: {:%, meta, [name_list, {:%{}, [], [field_pairs...]}, update_or_nil]}
    if (std.mem.eql(u8, form_name, "%")) {
        if (arg_elems.len >= 2) {
            // arg_elems[0] = module name parts (list of atoms)
            // arg_elems[1] = {:%{}, [], [field_pairs...]} (map node with fields)
            var name_parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
            if (arg_elems[0] == .list) {
                for (arg_elems[0].list.elems) |elem| {
                    if (elem == .atom) {
                        try name_parts.append(alloc, try interner.intern(elem.atom));
                    }
                }
            }

            // Extract fields from the map node {:%{}, [], [field_pairs...]}
            var fields: std.ArrayListUnmanaged(ast.StructField) = .empty;
            const map_node = arg_elems[1];
            if (map_node == .tuple and map_node.tuple.elems.len >= 3) {
                const map_args = map_node.tuple.elems[2];
                if (map_args == .list) {
                    for (map_args.list.elems) |pair| {
                        if (pair == .tuple and pair.tuple.elems.len == 2) {
                            const key = pair.tuple.elems[0];
                            const val = pair.tuple.elems[1];
                            if (key == .atom) {
                                try fields.append(alloc, .{
                                    .name = try interner.intern(key.atom),
                                    .value = try ctValueToExpr(alloc, interner, val),
                                });
                            }
                        }
                    }
                }
            }

            // Restore update_source if present (3rd arg, non-nil)
            const update_source: ?*const ast.Expr = if (arg_elems.len >= 3 and arg_elems[2] != .nil)
                try ctValueToExpr(alloc, interner, arg_elems[2])
            else
                null;

            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .struct_expr = .{
                .meta = node_meta,
                .module_name = .{ .parts = try name_parts.toOwnedSlice(alloc), .span = node_meta.span },
                .update_source = update_source,
                .fields = try fields.toOwnedSlice(alloc),
            } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "|>")) {
        if (arg_elems.len == 2) {
            const lhs = try ctValueToExpr(alloc, interner, arg_elems[0]);
            const rhs = try ctValueToExpr(alloc, interner, arg_elems[1]);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .pipe = .{ .meta = node_meta, .lhs = lhs, .rhs = rhs } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, ".")) {
        if (arg_elems.len == 2 and arg_elems[1] == .atom) {
            const obj = try ctValueToExpr(alloc, interner, arg_elems[0]);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .field_access = .{
                .meta = node_meta,
                .object = obj,
                .field = try interner.intern(arg_elems[1].atom),
            } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "__aliases__")) {
        var parts : std.ArrayListUnmanaged(ast.StringId) = .empty;
        for (arg_elems) |elem| {
            if (elem == .atom) {
                try parts.append(alloc, try interner.intern(elem.atom));
            }
        }
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .module_ref = .{
            .meta = node_meta,
            .name = .{ .parts = try parts.toOwnedSlice(alloc), .span = node_meta.span },
        } };
        return expr;
    }

    if (std.mem.eql(u8, form_name, "if")) {
        if (arg_elems.len == 2) {
            const cond = try ctValueToExpr(alloc, interner, arg_elems[0]);
            const kw = arg_elems[1];
            var then_stmts: []const ast.Stmt = &.{};
            var else_stmts: ?[]const ast.Stmt = null;

            if (kw == .list) {
                for (kw.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                        const key = pair.tuple.elems[0].atom;
                        if (std.mem.eql(u8, key, "do")) {
                            then_stmts = try ctValueToStmts(alloc, interner, pair.tuple.elems[1]);
                        } else if (std.mem.eql(u8, key, "else")) {
                            else_stmts = try ctValueToStmts(alloc, interner, pair.tuple.elems[1]);
                        }
                    }
                }
            }
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .if_expr = .{
                .meta = node_meta,
                .condition = cond,
                .then_block = then_stmts,
                .else_block = else_stmts,
            } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "case")) {
        if (arg_elems.len == 2) {
            const subject = try ctValueToExpr(alloc, interner, arg_elems[0]);
            var clauses : std.ArrayListUnmanaged(ast.CaseClause) = .empty;

            const kw = arg_elems[1];
            if (kw == .list) {
                for (kw.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                        if (std.mem.eql(u8, pair.tuple.elems[0].atom, "do") and pair.tuple.elems[1] == .list) {
                            for (pair.tuple.elems[1].list.elems) |clause_val| {
                                try clauses.append(alloc, try ctValueToCaseClause(alloc, interner, clause_val));
                            }
                        }
                    }
                }
            }
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .case_expr = .{
                .meta = node_meta,
                .scrutinee = subject,
                .clauses = try clauses.toOwnedSlice(alloc),
            } };
            return expr;
        }
    }

    // Cond: {:cond, meta, [do: [clauses...]]}
    if (std.mem.eql(u8, form_name, "cond")) {
        var clauses : std.ArrayListUnmanaged(ast.CondClause) = .empty;
        if (arg_elems.len == 1 and arg_elems[0] == .list) {
            for (arg_elems[0].list.elems) |pair| {
                if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                    if (std.mem.eql(u8, pair.tuple.elems[0].atom, "do") and pair.tuple.elems[1] == .list) {
                        for (pair.tuple.elems[1].list.elems) |clause_val| {
                            if (clause_val == .tuple and clause_val.tuple.elems.len == 3) {
                                if (clause_val.tuple.elems[2] == .list and clause_val.tuple.elems[2].list.elems.len == 2) {
                                    const cond_list = clause_val.tuple.elems[2].list.elems[0];
                                    const body_val = clause_val.tuple.elems[2].list.elems[1];
                                    if (cond_list == .list and cond_list.list.elems.len == 1) {
                                        try clauses.append(alloc, .{
                                            .meta = node_meta,
                                            .condition = try ctValueToExpr(alloc, interner, cond_list.list.elems[0]),
                                            .body = try ctValueToStmts(alloc, interner, body_val),
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .cond_expr = .{ .meta = node_meta, .clauses = try clauses.toOwnedSlice(alloc) } };
        return expr;
    }

    // String interpolation: {:<<>>, meta, [parts...]}
    if (std.mem.eql(u8, form_name, "<<>>")) {
        var parts : std.ArrayListUnmanaged(ast.StringPart) = .empty;
        for (arg_elems) |part| {
            if (part == .tuple and part.tuple.elems.len == 3 and part.tuple.elems[0] == .string) {
                try parts.append(alloc, .{ .literal = try interner.intern(part.tuple.elems[0].string) });
            } else {
                try parts.append(alloc, .{ .expr = try ctValueToExpr(alloc, interner, part) });
            }
        }
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .string_interpolation = .{ .meta = node_meta, .parts = try parts.toOwnedSlice(alloc) } };
        return expr;
    }

    // Type annotation: {:::, meta, [expr, type]}
    if (std.mem.eql(u8, form_name, "::")) {
        if (arg_elems.len == 2) {
            const inner = try ctValueToExpr(alloc, interner, arg_elems[0]);
            const te = try ctValueToTypeExpr(alloc, interner, arg_elems[1]);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .type_annotated = .{ .meta = node_meta, .expr = inner, .type_expr = te } };
            return expr;
        }
    }

    // For comprehension: {:for, meta, [var_pattern, iterable, filter, body]}
    // The first argument is the loop variable's pattern serialization.
    // Legacy CTFE inputs that used a bare atom for a single-name binding
    // are still accepted via the atom → bind-pattern fallback.
    if (std.mem.eql(u8, form_name, "for")) {
        if (arg_elems.len == 4) {
            const var_pattern: *const ast.Pattern = if (arg_elems[0] == .atom) blk: {
                const bind_name = try interner.intern(arg_elems[0].atom);
                const pat = try alloc.create(ast.Pattern);
                pat.* = .{ .bind = .{ .meta = node_meta, .name = bind_name } };
                break :blk pat;
            } else try ctValueToPattern(alloc, interner, arg_elems[0]);
            const iterable = try ctValueToExpr(alloc, interner, arg_elems[1]);
            const filter_expr = if (arg_elems[2] != .nil)
                try ctValueToExpr(alloc, interner, arg_elems[2])
            else
                null;
            const body = try ctValueToExpr(alloc, interner, arg_elems[3]);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .for_expr = .{
                .meta = node_meta,
                .var_pattern = var_pattern,
                .var_type_annotation = null,
                .iterable = iterable,
                .filter = filter_expr,
                .body = body,
            } };
            return expr;
        }
    }

    // Error pipe: {:~>, meta, [chain, handler]}
    if (std.mem.eql(u8, form_name, "~>")) {
        if (arg_elems.len == 2) {
            const chain = try ctValueToExpr(alloc, interner, arg_elems[0]);
            // Handler can be a list of clauses or an expression
            const handler_val = arg_elems[1];
            if (handler_val == .list) {
                var clauses : std.ArrayListUnmanaged(ast.CaseClause) = .empty;
                for (handler_val.list.elems) |clause_val| {
                    try clauses.append(alloc, try ctValueToCaseClause(alloc, interner, clause_val));
                }
                const expr = try alloc.create(ast.Expr);
                expr.* = .{ .error_pipe = .{
                    .meta = node_meta,
                    .chain = chain,
                    .handler = .{ .block = try clauses.toOwnedSlice(alloc) },
                } };
                return expr;
            } else {
                const handler_expr = try ctValueToExpr(alloc, interner, handler_val);
                const expr = try alloc.create(ast.Expr);
                expr.* = .{ .error_pipe = .{
                    .meta = node_meta,
                    .chain = chain,
                    .handler = .{ .function = handler_expr },
                } };
                return expr;
            }
        }
    }

    if (std.mem.eql(u8, form_name, "quote")) {
        if (arg_elems.len == 1 and arg_elems[0] == .list) {
            var stmts : std.ArrayListUnmanaged(ast.Stmt) = .empty;
            for (arg_elems[0].list.elems) |elem| {
                try stmts.append(alloc, .{ .expr = try ctValueToExpr(alloc, interner, elem) });
            }
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .quote_expr = .{ .meta = node_meta, .body = try stmts.toOwnedSlice(alloc) } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "unquote")) {
        if (arg_elems.len == 1) {
            const inner = try ctValueToExpr(alloc, interner, arg_elems[0]);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .unquote_expr = .{ .meta = node_meta, .expr = inner } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "unquote_splicing")) {
        if (arg_elems.len == 1) {
            const inner = try ctValueToExpr(alloc, interner, arg_elems[0]);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .unquote_splicing_expr = .{ .meta = node_meta, .expr = inner } };
            return expr;
        }
    }

    // Function reference: {:&, meta, [name, arity]}
    if (std.mem.eql(u8, form_name, "&")) {
        if (arg_elems.len == 2 and arg_elems[0] == .atom and arg_elems[1] == .int) {
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .function_ref = .{
                .meta = node_meta,
                .module = null,
                .function = try interner.intern(arg_elems[0].atom),
                .arity = @intCast(arg_elems[1].int),
            } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "import")) {
        // Handled as statement, not expression — return nil placeholder
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .nil_literal = .{ .meta = node_meta } };
        return expr;
    }

    if (std.mem.eql(u8, form_name, "=")) {
        if (arg_elems.len == 2) {
            // Assignment — but this returns an Expr, and assignments are Stmts
            // For now, return the value side
            return ctValueToExpr(alloc, interner, arg_elems[1]);
        }
    }

    if (std.mem.eql(u8, form_name, "panic")) {
        if (arg_elems.len == 1) {
            const msg = try ctValueToExpr(alloc, interner, arg_elems[0]);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .panic_expr = .{ .meta = node_meta, .message = msg } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "!")) {
        if (arg_elems.len == 1) {
            const inner = try ctValueToExpr(alloc, interner, arg_elems[0]);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .unwrap = .{ .meta = node_meta, .expr = inner } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "@")) {
        if (arg_elems.len == 1 and arg_elems[0] == .atom) {
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .attr_ref = .{ .meta = node_meta, .name = try interner.intern(arg_elems[0].atom) } };
            return expr;
        }
    }

    // Function declaration form {:fn, meta, clauses} at expression level:
    // Convert to a block containing the function declaration + a call to it.
    // This allows macros that produce function declarations to work in
    // expression contexts (e.g., test() inside run/0).
    if (std.mem.eql(u8, form_name, "fn") and arg_elems.len > 0) {
        if (arg_elems[0] == .tuple and arg_elems[0].tuple.elems.len == 3) {
            // This looks like a clause: {:->, meta, [head, opts]}
            const clause_ct = arg_elems[0];
            if (clause_ct.tuple.elems[0] == .atom and std.mem.eql(u8, clause_ct.tuple.elems[0].atom, "->")) {
                // Use the original value tuple directly for conversion
                const interner_mut: *ast.StringInterner = @constCast(interner);
                if (ctValueToStructItem(alloc, interner_mut, value) catch null) |mi| {
                    switch (mi) {
                        .function, .priv_function => |decl| {
                            // Wrap in a block: { function_decl; call_to_function }
                            const fn_name = interner.get(decl.name);
                            const call_callee = try alloc.create(ast.Expr);
                            call_callee.* = .{ .var_ref = .{ .meta = node_meta, .name = decl.name } };
                            const call_expr = try alloc.create(ast.Expr);
                            call_expr.* = .{ .call = .{ .meta = node_meta, .callee = call_callee, .args = &.{} } };
                            _ = fn_name;

                            // Create block with function_decl statement + call expression
                            const stmts = try alloc.alloc(ast.Stmt, 2);
                            stmts[0] = .{ .function_decl = decl };
                            stmts[1] = .{ .expr = call_expr };
                            const block_expr = try alloc.create(ast.Expr);
                            block_expr.* = .{ .block = .{ .meta = node_meta, .stmts = stmts } };
                            return block_expr;
                        },
                        else => {},
                    }
                }
            }
        }
    }

    // Anonymous function: {:fn, meta, [name, params, body]}
    // Reconstructed from exprToCtValue's anonymous_function handler.
    if (std.mem.eql(u8, form_name, "fn") and (arg_elems.len == 3 or arg_elems.len == 4) and arg_elems[0] == .atom) {
        {
            const interner_mut: *ast.StringInterner = @constCast(interner);
            const fn_name = try interner_mut.intern(arg_elems[0].atom);

            // Reconstruct params from the CtValue list
            var params: std.ArrayListUnmanaged(ast.Param) = .empty;
            if (arg_elems[1] == .list) {
                for (arg_elems[1].list.elems) |param_ct| {
                    // Handle typed params {:::, meta, [pattern, type]}
                    if (param_ct == .tuple and param_ct.tuple.elems.len == 3 and
                        param_ct.tuple.elems[0] == .atom and
                        std.mem.eql(u8, param_ct.tuple.elems[0].atom, "::"))
                    {
                        const param_args = param_ct.tuple.elems[2];
                        if (param_args == .list and param_args.list.elems.len == 2) {
                            const pat_ct = param_args.list.elems[0];
                            const type_ct = param_args.list.elems[1];
                            const name_str = if (pat_ct == .atom)
                                pat_ct.atom
                            else if (pat_ct == .tuple and pat_ct.tuple.elems.len >= 1 and pat_ct.tuple.elems[0] == .atom)
                                pat_ct.tuple.elems[0].atom
                            else
                                continue;
                            const pat = try alloc.create(ast.Pattern);
                            pat.* = .{ .bind = .{ .meta = node_meta, .name = try interner_mut.intern(name_str) } };
                            // Reconstruct type annotation from CtValue
                            const type_ann = try ctValueToTypeExpr(alloc, interner_mut, type_ct);
                            try params.append(alloc, .{
                                .meta = node_meta,
                                .pattern = pat,
                                .type_annotation = type_ann,
                            });
                            continue;
                        }
                    }
                    // Handle untyped params: atoms or tuples
                    const param_name = if (param_ct == .atom)
                        param_ct.atom
                    else if (param_ct == .tuple and param_ct.tuple.elems.len >= 1 and param_ct.tuple.elems[0] == .atom)
                        param_ct.tuple.elems[0].atom
                    else
                        continue;
                    const pat = try alloc.create(ast.Pattern);
                    pat.* = .{ .bind = .{ .meta = node_meta, .name = try interner_mut.intern(param_name) } };
                    try params.append(alloc, .{
                        .meta = node_meta,
                        .pattern = pat,
                        .type_annotation = null,
                    });
                }
            }

            // Reconstruct body
            var body_stmts: std.ArrayListUnmanaged(ast.Stmt) = .empty;
            if (arg_elems[2] != .nil) {
                const body_expr = try ctValueToExpr(alloc, interner, arg_elems[2]);
                try body_stmts.append(alloc, .{ .expr = body_expr });
            }

            // Reconstruct return type if present (4th arg)
            const return_type: ?*const ast.TypeExpr = if (arg_elems.len >= 4 and arg_elems[3] != .nil)
                try ctValueToTypeExpr(alloc, interner_mut, arg_elems[3])
            else
                null;

            const clause = try alloc.create(ast.FunctionClause);
            clause.* = .{
                .meta = node_meta,
                .params = try params.toOwnedSlice(alloc),
                .return_type = return_type,
                .refinement = null,
                .body = try body_stmts.toOwnedSlice(alloc),
            };
            const clauses = try alloc.alloc(ast.FunctionClause, 1);
            clauses[0] = clause.*;

            const decl = try alloc.create(ast.FunctionDecl);
            decl.* = .{
                .meta = node_meta,
                .name = fn_name,
                .clauses = clauses,
                .visibility = .private,
            };

            const anon_expr = try alloc.create(ast.Expr);
            anon_expr.* = .{ .anonymous_function = .{ .meta = node_meta, .decl = decl } };
            return anon_expr;
        }
    }

    // Default: treat as a function call — {:name, meta, [args...]}
    {
        const callee = try alloc.create(ast.Expr);
        callee.* = .{ .var_ref = .{ .meta = node_meta, .name = try interner.intern(form_name) } };

        var call_args : std.ArrayListUnmanaged(*const ast.Expr) = .empty;
        for (arg_elems) |elem| {
            try call_args.append(alloc, try ctValueToExpr(alloc, interner, elem));
        }

        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .call = .{
            .meta = node_meta,
            .callee = callee,
            .args = try call_args.toOwnedSlice(alloc),
        } };
        return expr;
    }
}

/// Convert a single CtValue element to an ast.Stmt, recognizing assignment
/// forms {:=, meta, [target, value]} and reconstructing them as proper
/// `.assignment` statements. All other forms become `.expr` statements.
fn ctValueToStmt(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) error{OutOfMemory}!ast.Stmt {
    if (value == .tuple and value.tuple.elems.len == 3) {
        const form = value.tuple.elems[0];
        const args_val = value.tuple.elems[2];
        if (form == .atom and std.mem.eql(u8, form.atom, "=")) {
            if (args_val == .list and args_val.list.elems.len == 2) {
                const pattern = try ctValueToPattern(alloc, interner, args_val.list.elems[0]);
                const value_expr = try ctValueToExpr(alloc, interner, args_val.list.elems[1]);
                const assignment = try alloc.create(ast.Assignment);
                const node_meta = try keywordListToMeta(value.tuple.elems[1]);
                assignment.* = .{
                    .meta = node_meta,
                    .pattern = pattern,
                    .value = value_expr,
                };
                return .{ .assignment = assignment };
            }
        }
    }
    // Default: treat as expression statement
    return .{ .expr = try ctValueToExpr(alloc, interner, value) };
}

/// Convert a CtValue to a statement list (for do/else blocks).
fn ctValueToStmts(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) error{OutOfMemory}![]const ast.Stmt {
    // If it's a __block__, unwrap the children
    if (value == .tuple and value.tuple.elems.len == 3) {
        if (value.tuple.elems[0] == .atom and std.mem.eql(u8, value.tuple.elems[0].atom, "__block__")) {
            if (value.tuple.elems[2] == .list) {
                var stmts : std.ArrayListUnmanaged(ast.Stmt) = .empty;
                for (value.tuple.elems[2].list.elems) |elem| {
                    try stmts.append(alloc, try ctValueToStmt(alloc, interner, elem));
                }
                return stmts.toOwnedSlice(alloc);
            }
        }
    }
    // Single expression — may still be an assignment form
    const stmts = try alloc.alloc(ast.Stmt, 1);
    stmts[0] = try ctValueToStmt(alloc, interner, value);
    return stmts;
}

/// Convert a CtValue arrow clause back to a CaseClause.
fn ctValueToCaseClause(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) error{OutOfMemory}!ast.CaseClause {
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    // Expect {:->, [], [[pattern], body]}
    if (value == .tuple and value.tuple.elems.len == 3) {
        if (value.tuple.elems[0] == .atom and std.mem.eql(u8, value.tuple.elems[0].atom, "->")) {
            const arrow_args = value.tuple.elems[2];
            if (arrow_args == .list and arrow_args.list.elems.len == 2) {
                const pat_list = arrow_args.list.elems[0];
                const body_val = arrow_args.list.elems[1];

                // First pattern from the list
                const pattern = if (pat_list == .list and pat_list.list.elems.len > 0)
                    try ctValueToPattern(alloc, interner, pat_list.list.elems[0])
                else blk: {
                    const p = try alloc.create(ast.Pattern);
                    p.* = .{ .wildcard = .{ .meta = meta } };
                    break :blk @as(*const ast.Pattern, p);
                };

                const stmts = try ctValueToStmts(alloc, interner, body_val);

                return .{
                    .meta = meta,
                    .pattern = pattern,
                    .type_annotation = null,
                    .guard = null,
                    .body = stmts,
                };
            }
        }
    }

    // Fallback: wildcard pattern with nil body
    const pattern = try alloc.create(ast.Pattern);
    pattern.* = .{ .wildcard = .{ .meta = meta } };
    return .{
        .meta = meta,
        .pattern = pattern,
        .type_annotation = null,
        .guard = null,
        .body = &.{},
    };
}

/// Convert a CtValue to an ast.Pattern.
fn ctValueToPattern(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) error{OutOfMemory}!*const ast.Pattern {
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    if (value == .tuple and value.tuple.elems.len == 3) {
        const form = value.tuple.elems[0];
        const pat_args = value.tuple.elems[2];

        // Wildcard: {:_, meta, nil}
        if (form == .atom and std.mem.eql(u8, form.atom, "_") and pat_args == .nil) {
            const pat = try alloc.create(ast.Pattern);
            pat.* = .{ .wildcard = .{ .meta = meta } };
            return pat;
        }

        // Literal patterns
        if (pat_args == .nil) {
            switch (form) {
                .int => |v| {
                    const pat = try alloc.create(ast.Pattern);
                    pat.* = .{ .literal = .{ .int = .{ .meta = meta, .value = v } } };
                    return pat;
                },
                .float => |v| {
                    const pat = try alloc.create(ast.Pattern);
                    pat.* = .{ .literal = .{ .float = .{ .meta = meta, .value = v } } };
                    return pat;
                },
                .string => |v| {
                    const pat = try alloc.create(ast.Pattern);
                    pat.* = .{ .literal = .{ .string = .{ .meta = meta, .value = try interner.intern(v) } } };
                    return pat;
                },
                .bool_val => |v| {
                    const pat = try alloc.create(ast.Pattern);
                    pat.* = .{ .literal = .{ .bool_lit = .{ .meta = meta, .value = v } } };
                    return pat;
                },
                .nil => {
                    const pat = try alloc.create(ast.Pattern);
                    pat.* = .{ .literal = .{ .nil = .{ .meta = meta } } };
                    return pat;
                },
                .atom => |name| {
                    // Variable binding or atom pattern
                    if (name.len > 0 and (name[0] == '_' or std.ascii.isLower(name[0]))) {
                        const pat = try alloc.create(ast.Pattern);
                        pat.* = .{ .bind = .{ .meta = meta, .name = try interner.intern(name) } };
                        return pat;
                    } else {
                        const pat = try alloc.create(ast.Pattern);
                        pat.* = .{ .literal = .{ .atom = .{ .meta = meta, .value = try interner.intern(name) } } };
                        return pat;
                    }
                },
                else => {},
            }
        }

        // Pin: {:^, meta, [name]}
        if (form == .atom and std.mem.eql(u8, form.atom, "^")) {
            if (pat_args == .list and pat_args.list.elems.len == 1 and pat_args.list.elems[0] == .atom) {
                const pat = try alloc.create(ast.Pattern);
                pat.* = .{ .pin = .{ .meta = meta, .name = try interner.intern(pat_args.list.elems[0].atom) } };
                return pat;
            }
        }

        // List cons: {:|, meta, [heads_list, tail]}
        if (form == .atom and std.mem.eql(u8, form.atom, "|")) {
            if (pat_args == .list and pat_args.list.elems.len == 2) {
                var heads : std.ArrayListUnmanaged(*const ast.Pattern) = .empty;
                if (pat_args.list.elems[0] == .list) {
                    for (pat_args.list.elems[0].list.elems) |h| {
                        try heads.append(alloc, try ctValueToPattern(alloc, interner, h));
                    }
                }
                const tail = try ctValueToPattern(alloc, interner, pat_args.list.elems[1]);
                const pat = try alloc.create(ast.Pattern);
                pat.* = .{ .list_cons = .{ .meta = meta, .heads = try heads.toOwnedSlice(alloc), .tail = tail } };
                return pat;
            }
        }

        // Struct pattern: {:%, meta, [aliases, {:%{}, [], [fields...]}]}
        if (form == .atom and std.mem.eql(u8, form.atom, "%")) {
            if (pat_args == .list and pat_args.list.elems.len == 2) {
                const aliases_ct = pat_args.list.elems[0];
                const map_ct = pat_args.list.elems[1];
                // Extract module name
                var parts : std.ArrayListUnmanaged(ast.StringId) = .empty;
                if (aliases_ct == .tuple and aliases_ct.tuple.elems.len == 3 and aliases_ct.tuple.elems[2] == .list) {
                    for (aliases_ct.tuple.elems[2].list.elems) |part| {
                        if (part == .atom) try parts.append(alloc, try interner.intern(part.atom));
                    }
                }
                // Extract fields
                var fields : std.ArrayListUnmanaged(ast.StructPatternField) = .empty;
                if (map_ct == .tuple and map_ct.tuple.elems.len == 3 and map_ct.tuple.elems[2] == .list) {
                    for (map_ct.tuple.elems[2].list.elems) |pair| {
                        if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                            try fields.append(alloc, .{
                                .name = try interner.intern(pair.tuple.elems[0].atom),
                                .pattern = try ctValueToPattern(alloc, interner, pair.tuple.elems[1]),
                            });
                        }
                    }
                }
                const pat = try alloc.create(ast.Pattern);
                pat.* = .{ .struct_pattern = .{
                    .meta = meta,
                    .module_name = .{ .parts = try parts.toOwnedSlice(alloc), .span = meta.span },
                    .fields = try fields.toOwnedSlice(alloc),
                } };
                return pat;
            }
        }

        // Map pattern: {:%{}, meta, [field_pairs...]}
        if (form == .atom and std.mem.eql(u8, form.atom, "%{}")) {
            if (pat_args == .list) {
                var fields : std.ArrayListUnmanaged(ast.MapPatternField) = .empty;
                for (pat_args.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2) {
                        try fields.append(alloc, .{
                            .key = try ctValueToExpr(alloc, interner, pair.tuple.elems[0]),
                            .value = try ctValueToPattern(alloc, interner, pair.tuple.elems[1]),
                        });
                    }
                }
                const pat = try alloc.create(ast.Pattern);
                pat.* = .{ .map = .{ .meta = meta, .fields = try fields.toOwnedSlice(alloc) } };
                return pat;
            }
        }

        // Tuple pattern: {:{}, meta, [elems...]}
        if (form == .atom and std.mem.eql(u8, form.atom, "{}")) {
            if (pat_args == .list) {
                var elems : std.ArrayListUnmanaged(*const ast.Pattern) = .empty;
                for (pat_args.list.elems) |elem| {
                    try elems.append(alloc, try ctValueToPattern(alloc, interner, elem));
                }
                const pat = try alloc.create(ast.Pattern);
                pat.* = .{ .tuple = .{ .meta = meta, .elements = try elems.toOwnedSlice(alloc) } };
                return pat;
            }
        }
    }

    // Bare list → list pattern
    if (value == .list) {
        var elems : std.ArrayListUnmanaged(*const ast.Pattern) = .empty;
        for (value.list.elems) |elem| {
            try elems.append(alloc, try ctValueToPattern(alloc, interner, elem));
        }
        const pat = try alloc.create(ast.Pattern);
        pat.* = .{ .list = .{ .meta = meta, .elements = try elems.toOwnedSlice(alloc) } };
        return pat;
    }

    // Fallback: wildcard
    const pat = try alloc.create(ast.Pattern);
    pat.* = .{ .wildcard = .{ .meta = meta } };
    return pat;
}

/// Extract metadata from a keyword list CtValue.
fn keywordListToMeta(value: CtValue) !ast.NodeMeta {
    var line: u32 = 0;
    var col: u32 = 0;
    if (value == .list) {
        for (value.list.elems) |pair| {
            if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                const key = pair.tuple.elems[0].atom;
                if (std.mem.eql(u8, key, "line") and pair.tuple.elems[1] == .int) {
                    line = @intCast(pair.tuple.elems[1].int);
                } else if (std.mem.eql(u8, key, "col") and pair.tuple.elems[1] == .int) {
                    col = @intCast(pair.tuple.elems[1].int);
                }
            }
        }
    }
    return .{ .span = .{ .start = 0, .end = 0, .line = line, .col = col } };
}

/// Map string to binary operator.
fn stringToBinop(name: []const u8) ?ast.BinaryOp.Op {
    if (std.mem.eql(u8, name, "+")) return .add;
    if (std.mem.eql(u8, name, "-")) return .sub;
    if (std.mem.eql(u8, name, "*")) return .mul;
    if (std.mem.eql(u8, name, "/")) return .div;
    if (std.mem.eql(u8, name, "rem")) return .rem_op;
    if (std.mem.eql(u8, name, "==")) return .equal;
    if (std.mem.eql(u8, name, "!=")) return .not_equal;
    if (std.mem.eql(u8, name, "<")) return .less;
    if (std.mem.eql(u8, name, ">")) return .greater;
    if (std.mem.eql(u8, name, "<=")) return .less_equal;
    if (std.mem.eql(u8, name, ">=")) return .greater_equal;
    if (std.mem.eql(u8, name, "&&")) return .and_op;
    if (std.mem.eql(u8, name, "||")) return .or_op;
    if (std.mem.eql(u8, name, "<>")) return .concat;
    return null;
}

/// Map string to unary operator.
fn stringToUnop(name: []const u8) ?ast.UnaryOp.Op {
    // "-" is ambiguous (binary sub or unary negate) — only match with 1 arg
    if (std.mem.eql(u8, name, "-")) return .negate;
    if (std.mem.eql(u8, name, "not")) return .not_op;
    return null;
}

// ============================================================
// Declaration conversion: FunctionDecl, StructDecl → CtValue
// ============================================================

/// Convert a TypeExpr to CtValue.
/// Simple types become atoms: :i64, :String, :Bool
/// Compound types become tuples: {:list, [], [:String]}, {:tuple, [], [:i64, :String]}
pub fn typeExprToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    te: *const ast.TypeExpr,
) error{OutOfMemory}!CtValue {
    return switch (te.*) {
        .name => |n| {
            if (n.args.len == 0) {
                // Simple type: :i64, :String, :Bool
                return CtValue{ .atom = interner.get(n.name) };
            }
            // Generic type: {:TypeName, [], [args...]}
            var arg_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (n.args) |arg| {
                try arg_vals.append(alloc, try typeExprToCtValue(alloc, interner, store, arg));
            }
            return makeTuple3(alloc, store, .{ .atom = interner.get(n.name) }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, arg_vals.items));
        },
        .variable => |v| CtValue{ .atom = interner.get(v.name) },
        .tuple => |t| {
            var elem_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (t.elements) |elem| {
                try elem_vals.append(alloc, try typeExprToCtValue(alloc, interner, store, elem));
            }
            return makeTuple3(alloc, store, .{ .atom = "tuple" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, elem_vals.items));
        },
        .list => |l| {
            const elem = try typeExprToCtValue(alloc, interner, store, l.element);
            return makeTuple3(alloc, store, .{ .atom = "list" }, try emptyList(alloc, store), try makeList(alloc, store, &.{elem}));
        },
        .map => |m| {
            var field_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (m.fields) |field| {
                const key = try typeExprToCtValue(alloc, interner, store, field.key);
                const val = try typeExprToCtValue(alloc, interner, store, field.value);
                try field_vals.append(alloc, try makeTuple2(alloc, store, key, val));
            }
            return makeTuple3(alloc, store, .{ .atom = "map" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, field_vals.items));
        },
        .function => |f| {
            var param_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (f.params) |p| {
                try param_vals.append(alloc, try typeExprToCtValue(alloc, interner, store, p));
            }
            const ret = try typeExprToCtValue(alloc, interner, store, f.return_type);
            const args = try makeList(alloc, store, &.{ try makeListFromSlice(alloc, store, param_vals.items), ret });
            return makeTuple3(alloc, store, .{ .atom = "fn_type" }, try emptyList(alloc, store), args);
        },
        .never => makeTuple3(alloc, store, .{ .atom = "Never" }, try emptyList(alloc, store), .nil),
        .paren => |p| typeExprToCtValue(alloc, interner, store, p.inner),
        .struct_type => |s| {
            var parts : std.ArrayListUnmanaged(CtValue) = .empty;
            for (s.module_name.parts) |part| {
                try parts.append(alloc, CtValue{ .atom = interner.get(part) });
            }
            return makeTuple3(alloc, store, .{ .atom = "__aliases__" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, parts.items));
        },
        .union_type => |u| {
            var member_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (u.members) |m| {
                try member_vals.append(alloc, try typeExprToCtValue(alloc, interner, store, m));
            }
            return makeTuple3(alloc, store, .{ .atom = "union_type" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, member_vals.items));
        },
        .literal => |l| switch (l.value) {
            .int => |v| makeTuple3(alloc, store, .{ .int = v }, try emptyList(alloc, store), .nil),
            .string => |v| makeTuple3(alloc, store, .{ .string = interner.get(v) }, try emptyList(alloc, store), .nil),
            .bool_val => |v| makeTuple3(alloc, store, .{ .bool_val = v }, try emptyList(alloc, store), .nil),
            .nil => makeTuple3(alloc, store, .nil, try emptyList(alloc, store), .nil),
        },
    };
}

/// Convert a CtValue back to a TypeExpr.
/// Atoms become simple named types: :i64 → TypeNameExpr("i64")
pub fn ctValueToTypeExpr(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) error{OutOfMemory}!*const ast.TypeExpr {
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    if (value == .atom) {
        const te = try alloc.create(ast.TypeExpr);
        te.* = .{ .name = .{ .meta = meta, .name = try interner.intern(value.atom), .args = &.{} } };
        return te;
    }

    if (value == .tuple and value.tuple.elems.len == 3) {
        const form = value.tuple.elems[0];
        const args = value.tuple.elems[2];

        if (form == .atom) {
            if (std.mem.eql(u8, form.atom, "list") and args == .list and args.list.elems.len == 1) {
                const elem = try ctValueToTypeExpr(alloc, interner, args.list.elems[0]);
                const te = try alloc.create(ast.TypeExpr);
                te.* = .{ .list = .{ .meta = meta, .element = elem } };
                return te;
            }

            if (std.mem.eql(u8, form.atom, "tuple") and args == .list) {
                var elems : std.ArrayListUnmanaged(*const ast.TypeExpr) = .empty;
                for (args.list.elems) |elem| {
                    try elems.append(alloc, try ctValueToTypeExpr(alloc, interner, elem));
                }
                const te = try alloc.create(ast.TypeExpr);
                te.* = .{ .tuple = .{ .meta = meta, .elements = try elems.toOwnedSlice(alloc) } };
                return te;
            }

            if (std.mem.eql(u8, form.atom, "Never") and args == .nil) {
                const te = try alloc.create(ast.TypeExpr);
                te.* = .{ .never = .{ .meta = meta } };
                return te;
            }

            // Map type: {:map, [], [field_pairs...]}
            if (std.mem.eql(u8, form.atom, "map") and args == .list) {
                var fields : std.ArrayListUnmanaged(ast.TypeMapField) = .empty;
                for (args.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2) {
                        try fields.append(alloc, .{
                            .key = try ctValueToTypeExpr(alloc, interner, pair.tuple.elems[0]),
                            .value = try ctValueToTypeExpr(alloc, interner, pair.tuple.elems[1]),
                        });
                    }
                }
                const te = try alloc.create(ast.TypeExpr);
                te.* = .{ .map = .{ .meta = meta, .fields = try fields.toOwnedSlice(alloc) } };
                return te;
            }

            // Function type: {:fn_type, [], [[param_types...], return_type]}
            if (std.mem.eql(u8, form.atom, "fn_type") and args == .list and args.list.elems.len == 2) {
                const param_list = args.list.elems[0];
                const ret = try ctValueToTypeExpr(alloc, interner, args.list.elems[1]);
                var params : std.ArrayListUnmanaged(*const ast.TypeExpr) = .empty;
                if (param_list == .list) {
                    for (param_list.list.elems) |p| {
                        try params.append(alloc, try ctValueToTypeExpr(alloc, interner, p));
                    }
                }
                const ownerships = try alloc.alloc(ast.Ownership, params.items.len);
                @memset(ownerships, .shared);
                const explicit = try alloc.alloc(bool, params.items.len);
                @memset(explicit, false);
                const te = try alloc.create(ast.TypeExpr);
                te.* = .{ .function = .{
                    .meta = meta,
                    .params = try params.toOwnedSlice(alloc),
                    .param_ownerships = ownerships,
                    .param_ownerships_explicit = explicit,
                    .return_type = ret,
                } };
                return te;
            }

            // Union type: {:union_type, [], [member_types...]}
            if (std.mem.eql(u8, form.atom, "union_type") and args == .list) {
                var members : std.ArrayListUnmanaged(*const ast.TypeExpr) = .empty;
                for (args.list.elems) |m| {
                    try members.append(alloc, try ctValueToTypeExpr(alloc, interner, m));
                }
                const te = try alloc.create(ast.TypeExpr);
                te.* = .{ .union_type = .{ .meta = meta, .members = try members.toOwnedSlice(alloc) } };
                return te;
            }

            // Struct type: {:__aliases__, [], [:Part1, :Part2, ...]}
            if (std.mem.eql(u8, form.atom, "__aliases__") and args == .list) {
                var parts : std.ArrayListUnmanaged(ast.StringId) = .empty;
                for (args.list.elems) |part| {
                    if (part == .atom) try parts.append(alloc, try interner.intern(part.atom));
                }
                const te = try alloc.create(ast.TypeExpr);
                te.* = .{ .struct_type = .{
                    .meta = meta,
                    .module_name = .{ .parts = try parts.toOwnedSlice(alloc), .span = meta.span },
                    .fields = &.{},
                } };
                return te;
            }

            // Named type with args or simple name
            if (args == .nil or args == .list) {
                var type_args : std.ArrayListUnmanaged(*const ast.TypeExpr) = .empty;
                if (args == .list) {
                    for (args.list.elems) |a| {
                        try type_args.append(alloc, try ctValueToTypeExpr(alloc, interner, a));
                    }
                }
                const te = try alloc.create(ast.TypeExpr);
                te.* = .{ .name = .{ .meta = meta, .name = try interner.intern(form.atom), .args = try type_args.toOwnedSlice(alloc) } };
                return te;
            }
        }
    }

    // Fallback: any
    const te = try alloc.create(ast.TypeExpr);
    te.* = .{ .name = .{ .meta = meta, .name = try interner.intern("any"), .args = &.{} } };
    return te;
}

/// Convert a FunctionDecl to CtValue:
/// {:fn, [visibility: :pub], [{:name, [], [params...]}, [return: type, do: body]]}
pub fn functionDeclToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    decl: *const ast.FunctionDecl,
) error{OutOfMemory}!CtValue {
    var clause_vals : std.ArrayListUnmanaged(CtValue) = .empty;

    for (decl.clauses) |clause| {
        // Params
        var param_vals : std.ArrayListUnmanaged(CtValue) = .empty;
        for (clause.params) |param| {
            try param_vals.append(alloc, try paramToCtValue(alloc, interner, store, param));
        }

        // Function head: {:name, [], [params...]}
        const params_list = try makeListFromSlice(alloc, store, param_vals.items);
        const head = try makeTuple3(alloc, store, .{ .atom = interner.get(decl.name) }, try emptyList(alloc, store), params_list);

        // Keyword opts: [return: type, do: body]
        var kw_elems : std.ArrayListUnmanaged(CtValue) = .empty;
        if (clause.return_type) |rt| {
            try kw_elems.append(alloc, try makeKeywordPair(alloc, store, "return", try typeExprToCtValue(alloc, interner, store, rt)));
        }

        // Body (optional — protocol signatures and forward declarations have no body)
        if (clause.body) |body_stmts| {
            var body_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (body_stmts) |stmt| {
                try body_vals.append(alloc, try stmtToCtValue(alloc, interner, store, stmt));
            }
            const body_ct = if (body_vals.items.len == 1)
                body_vals.items[0]
            else
                try makeTuple3(alloc, store, .{ .atom = "__block__" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, body_vals.items));
            try kw_elems.append(alloc, try makeKeywordPair(alloc, store, "do", body_ct));
        }

        // Guard
        if (clause.refinement) |guard| {
            try kw_elems.append(alloc, try makeKeywordPair(alloc, store, "when", try exprToCtValue(alloc, interner, store, guard)));
        }

        const opts = try makeListFromSlice(alloc, store, kw_elems.items);

        // Clause: {:->, [], [head, opts]}
        const clause_args = try makeList(alloc, store, &.{ head, opts });
        try clause_vals.append(alloc, try makeTuple3(alloc, store, .{ .atom = "->" }, try emptyList(alloc, store), clause_args));
    }

    // Metadata with visibility
    var meta_elems : std.ArrayListUnmanaged(CtValue) = .empty;
    try meta_elems.append(alloc, try makeKeywordPair(alloc, store, "visibility", .{
        .atom = if (decl.visibility == .public) "pub" else "private",
    }));
    if (decl.meta.span.line > 0) {
        try meta_elems.append(alloc, try makeKeywordPair(alloc, store, "line", .{ .int = @intCast(decl.meta.span.line) }));
    }
    const meta = try makeListFromSlice(alloc, store, meta_elems.items);

    const clauses_list = try makeListFromSlice(alloc, store, clause_vals.items);
    return makeTuple3(alloc, store, .{ .atom = "fn" }, meta, clauses_list);
}

/// Convert a Param to CtValue:
/// {:::, [], [{:name, [], nil}, :type]} or {:name, [], nil} (no type)
fn paramToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    param: ast.Param,
) error{OutOfMemory}!CtValue {
    const pat_val = try patternToCtValue(alloc, interner, store, param.pattern);

    if (param.type_annotation) |ta| {
        // {:::, [], [pattern, type]}
        const type_val = try typeExprToCtValue(alloc, interner, store, ta);
        const args = try makeList(alloc, store, &.{ pat_val, type_val });
        return makeTuple3(alloc, store, .{ .atom = "::" }, try emptyList(alloc, store), args);
    }

    return pat_val;
}

/// Convert a StructDecl to CtValue:
/// {:module, [visibility: :pub], [:Name, [do: [items...]]]}
pub fn moduleDeclToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    decl: *const ast.StructDecl,
) error{OutOfMemory}!CtValue {
    // Module name as atom
    var name_parts : std.ArrayListUnmanaged(CtValue) = .empty;
    for (decl.name.parts) |part| {
        try name_parts.append(alloc, CtValue{ .atom = interner.get(part) });
    }
    const name_val = try makeTuple3(alloc, store, .{ .atom = "__aliases__" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, name_parts.items));

    // Items
    var item_vals : std.ArrayListUnmanaged(CtValue) = .empty;
    for (decl.items) |item| {
        try item_vals.append(alloc, try structItemToCtValue(alloc, interner, store, item));
    }
    const items_list = try makeListFromSlice(alloc, store, item_vals.items);
    const do_pair = try makeKeywordPair(alloc, store, "do", items_list);
    const opts = try makeList(alloc, store, &.{do_pair});

    // Metadata
    var meta_elems : std.ArrayListUnmanaged(CtValue) = .empty;
    try meta_elems.append(alloc, try makeKeywordPair(alloc, store, "visibility", .{
        .atom = if (decl.is_private) "private" else "pub",
    }));
    const meta = try makeListFromSlice(alloc, store, meta_elems.items);

    const args = try makeList(alloc, store, &.{ name_val, opts });
    return makeTuple3(alloc, store, .{ .atom = "module" }, meta, args);
}

/// Convert a StructDecl to CtValue:
/// {:struct, [visibility: :pub], [:Name, [fields...]]}
pub fn structDeclToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    decl: *const ast.StructDecl,
) error{OutOfMemory}!CtValue {
    const name_val: CtValue = if (decl.name.parts.len > 0) .{ .atom = interner.get(decl.name.parts[0]) } else .nil;

    var field_vals : std.ArrayListUnmanaged(CtValue) = .empty;
    for (decl.fields) |field| {
        const field_name: CtValue = .{ .atom = interner.get(field.name) };
        const field_type = try typeExprToCtValue(alloc, interner, store, field.type_expr);
        try field_vals.append(alloc, try makeTuple2(alloc, store, field_name, field_type));
    }
    const fields_list = try makeListFromSlice(alloc, store, field_vals.items);

    const args = try makeList(alloc, store, &.{ name_val, fields_list });
    return makeTuple3(alloc, store, .{ .atom = "struct" }, try emptyList(alloc, store), args);
}

/// Convert a StructItem to CtValue.
pub fn structItemToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    item: ast.StructItem,
) error{OutOfMemory}!CtValue {
    return switch (item) {
        .function, .priv_function => |f| functionDeclToCtValue(alloc, interner, store, f),
        .macro, .priv_macro => |m| {
            // Same as function but with :macro form
            const fn_ct = try functionDeclToCtValue(alloc, interner, store, m);
            // Replace :fn with :macro in the form position
            if (fn_ct == .tuple and fn_ct.tuple.elems.len == 3) {
                const new_elems = try alloc.alloc(CtValue, 3);
                new_elems[0] = .{ .atom = "macro" };
                new_elems[1] = fn_ct.tuple.elems[1];
                new_elems[2] = fn_ct.tuple.elems[2];
                const id = store.alloc(alloc, .tuple, null);
                return CtValue{ .tuple = .{ .alloc_id = id, .elems = new_elems } };
            }
            return fn_ct;
        },
        .struct_decl => |s| structDeclToCtValue(alloc, interner, store, s),
        .union_decl => |u| {
            // {:union, [], [:Name, [variants...]]}
            const name_val: CtValue = .{ .atom = interner.get(u.name) };
            var variant_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            for (u.variants) |v| {
                if (v.type_expr) |te| {
                    // Data variant: {:VariantName, type}
                    const vname: CtValue = .{ .atom = interner.get(v.name) };
                    const vtype = try typeExprToCtValue(alloc, interner, store, te);
                    try variant_vals.append(alloc, try makeTuple2(alloc, store, vname, vtype));
                } else {
                    // Unit variant: :VariantName
                    try variant_vals.append(alloc, CtValue{ .atom = interner.get(v.name) });
                }
            }
            const args = try makeList(alloc, store, &.{ name_val, try makeListFromSlice(alloc, store, variant_vals.items) });
            return makeTuple3(alloc, store, .{ .atom = "union" }, try emptyList(alloc, store), args);
        },
        .import_decl => |id| {
            var parts : std.ArrayListUnmanaged(CtValue) = .empty;
            for (id.module_path.parts) |part| {
                try parts.append(alloc, CtValue{ .atom = interner.get(part) });
            }
            const aliases = try makeTuple3(alloc, store, .{ .atom = "__aliases__" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, parts.items));
            const args = try makeList(alloc, store, &.{aliases});
            return makeTuple3(alloc, store, .{ .atom = "import" }, try emptyList(alloc, store), args);
        },
        .use_decl => |ud| {
            var parts : std.ArrayListUnmanaged(CtValue) = .empty;
            for (ud.module_path.parts) |part| {
                try parts.append(alloc, CtValue{ .atom = interner.get(part) });
            }
            const aliases = try makeTuple3(alloc, store, .{ .atom = "__aliases__" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, parts.items));
            const args = try makeList(alloc, store, &.{aliases});
            return makeTuple3(alloc, store, .{ .atom = "use" }, try emptyList(alloc, store), args);
        },
        .alias_decl => |ad| {
            // {:alias, [], [module_path, as_name]}
            var parts : std.ArrayListUnmanaged(CtValue) = .empty;
            for (ad.module_path.parts) |part| {
                try parts.append(alloc, CtValue{ .atom = interner.get(part) });
            }
            const mod_val = try makeTuple3(alloc, store, .{ .atom = "__aliases__" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, parts.items));
            var arg_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            try arg_vals.append(alloc, mod_val);
            if (ad.as_name) |as_name| {
                var as_parts : std.ArrayListUnmanaged(CtValue) = .empty;
                for (as_name.parts) |part| {
                    try as_parts.append(alloc, CtValue{ .atom = interner.get(part) });
                }
                try arg_vals.append(alloc, try makeTuple3(alloc, store, .{ .atom = "__aliases__" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, as_parts.items)));
            }
            return makeTuple3(alloc, store, .{ .atom = "alias" }, try emptyList(alloc, store), try makeListFromSlice(alloc, store, arg_vals.items));
        },
        .type_decl => |td| {
            // {:type, [], [:Name, body_type]}
            const name_val: CtValue = .{ .atom = interner.get(td.name) };
            const body_val = try typeExprToCtValue(alloc, interner, store, td.body);
            const args = try makeList(alloc, store, &.{ name_val, body_val });
            return makeTuple3(alloc, store, .{ .atom = "type" }, try emptyList(alloc, store), args);
        },
        .opaque_decl => |od| {
            // {:opaque, [], [:Name, body_type]}
            const name_val: CtValue = .{ .atom = interner.get(od.name) };
            const body_val = try typeExprToCtValue(alloc, interner, store, od.body);
            const args = try makeList(alloc, store, &.{ name_val, body_val });
            return makeTuple3(alloc, store, .{ .atom = "opaque" }, try emptyList(alloc, store), args);
        },
        .attribute => |attr| {
            // {:@, [], [:name, value]} or {:@, [], [:name]}
            const name: CtValue = .{ .atom = interner.get(attr.name) };
            var arg_vals : std.ArrayListUnmanaged(CtValue) = .empty;
            try arg_vals.append(alloc, name);
            if (attr.value) |val| {
                try arg_vals.append(alloc, try exprToCtValue(alloc, interner, store, val));
            }
            const args = try makeListFromSlice(alloc, store, arg_vals.items);
            return makeTuple3(alloc, store, .{ .atom = "@" }, try emptyList(alloc, store), args);
        },
        .struct_level_expr => |expr| {
            return exprToCtValue(alloc, interner, store, expr);
        },
    };
}

// ============================================================
// Reverse declaration conversion: CtValue → StructItem
// ============================================================

/// Convert a CtValue back to a StructItem.
/// Expects {:fn, meta, clauses} or {:macro, meta, clauses} etc.
pub fn ctValueToStructItem(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) error{OutOfMemory}!?ast.StructItem {
    if (value != .tuple or value.tuple.elems.len != 3) return null;

    const form = value.tuple.elems[0];
    if (form != .atom) return null;
    const form_name = form.atom;
    const meta_val = value.tuple.elems[1];
    const args = value.tuple.elems[2];

    // Extract visibility from metadata
    const is_public = blk: {
        if (meta_val == .list) {
            for (meta_val.list.elems) |pair| {
                if (pair == .tuple and pair.tuple.elems.len == 2) {
                    if (pair.tuple.elems[0] == .atom and std.mem.eql(u8, pair.tuple.elems[0].atom, "visibility")) {
                        if (pair.tuple.elems[1] == .atom) {
                            break :blk std.mem.eql(u8, pair.tuple.elems[1].atom, "pub");
                        }
                    }
                }
            }
        }
        break :blk false;
    };

    if (std.mem.eql(u8, form_name, "fn") or std.mem.eql(u8, form_name, "macro")) {
        const is_macro = std.mem.eql(u8, form_name, "macro");
        if (args != .list) return null;

        // Each clause: {:->, [], [{:name, [], [params...]}, [return: type, do: body]]}
        var clauses : std.ArrayListUnmanaged(ast.FunctionClause) = .empty;
        var func_name: ast.StringId = 0;

        for (args.list.elems) |clause_ct| {
            if (clause_ct != .tuple or clause_ct.tuple.elems.len != 3) continue;
            if (clause_ct.tuple.elems[0] != .atom or !std.mem.eql(u8, clause_ct.tuple.elems[0].atom, "->")) continue;
            const clause_args = clause_ct.tuple.elems[2];
            if (clause_args != .list or clause_args.list.elems.len != 2) continue;

            const head = clause_args.list.elems[0];
            const opts = clause_args.list.elems[1];

            // Head: {:name, [], [params...]}
            if (head != .tuple or head.tuple.elems.len != 3) continue;
            if (head.tuple.elems[0] == .atom) {
                func_name = try interner.intern(head.tuple.elems[0].atom);
            }

            // Params
            var params : std.ArrayListUnmanaged(ast.Param) = .empty;
            if (head.tuple.elems[2] == .list) {
                for (head.tuple.elems[2].list.elems) |param_ct| {
                    try params.append(alloc, try ctValueToParam(alloc, interner, param_ct));
                }
            }

            // Extract opts: [return: type, do: body, when: guard]
            var return_type: ?*const ast.TypeExpr = null;
            var body_stmts: []const ast.Stmt = &.{};
            var guard: ?*const ast.Expr = null;

            if (opts == .list) {
                for (opts.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                        const key = pair.tuple.elems[0].atom;
                        if (std.mem.eql(u8, key, "return")) {
                            return_type = try ctValueToTypeExpr(alloc, interner, pair.tuple.elems[1]);
                        } else if (std.mem.eql(u8, key, "do")) {
                            body_stmts = try ctValueToStmts(alloc, interner, pair.tuple.elems[1]);
                        } else if (std.mem.eql(u8, key, "when")) {
                            guard = try ctValueToExpr(alloc, interner, pair.tuple.elems[1]);
                        }
                    }
                }
            }

            try clauses.append(alloc, .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .params = try params.toOwnedSlice(alloc),
                .return_type = return_type,
                .refinement = guard,
                .body = body_stmts,
            });
        }

        const decl = try alloc.create(ast.FunctionDecl);
        decl.* = .{
            .meta = .{ .span = .{ .start = 0, .end = 0 } },
            .name = func_name,
            .clauses = try clauses.toOwnedSlice(alloc),
            .visibility = if (is_public) .public else .private,
        };

        if (is_macro) {
            return if (is_public) .{ .macro = decl } else .{ .priv_macro = decl };
        }
        return if (is_public) .{ .function = decl } else .{ .priv_function = decl };
    }

    if (std.mem.eql(u8, form_name, "import")) {
        if (args == .list and args.list.elems.len > 0) {
            const aliases = args.list.elems[0];
            if (aliases == .tuple and aliases.tuple.elems.len == 3) {
                if (aliases.tuple.elems[0] == .atom and std.mem.eql(u8, aliases.tuple.elems[0].atom, "__aliases__")) {
                    if (aliases.tuple.elems[2] == .list) {
                        var parts : std.ArrayListUnmanaged(ast.StringId) = .empty;
                        for (aliases.tuple.elems[2].list.elems) |part| {
                            if (part == .atom) try parts.append(alloc, try interner.intern(part.atom));
                        }
                        const decl = try alloc.create(ast.ImportDecl);
                        decl.* = .{
                            .meta = .{ .span = .{ .start = 0, .end = 0 } },
                            .module_path = .{ .parts = try parts.toOwnedSlice(alloc), .span = .{ .start = 0, .end = 0 } },
                            .filter = null,
                        };
                        return .{ .import_decl = decl };
                    }
                }
            }
        }
    }

    // Struct: {:struct, meta, [name, [fields...]]}
    if (std.mem.eql(u8, form_name, "struct")) {
        if (args == .list and args.list.elems.len == 2) {
            const name_val = args.list.elems[0];
            const fields_val = args.list.elems[1];
            const name_parts: []const ast.StringId = if (name_val == .atom) blk: {
                const parts = try alloc.alloc(ast.StringId, 1);
                parts[0] = try interner.intern(name_val.atom);
                break :blk parts;
            } else &.{};
            var fields : std.ArrayListUnmanaged(ast.StructFieldDecl) = .empty;
            if (fields_val == .list) {
                for (fields_val.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                        try fields.append(alloc, .{
                            .meta = .{ .span = .{ .start = 0, .end = 0 } },
                            .name = try interner.intern(pair.tuple.elems[0].atom),
                            .type_expr = try ctValueToTypeExpr(alloc, interner, pair.tuple.elems[1]),
                            .default = null,
                        });
                    }
                }
            }
            const decl = try alloc.create(ast.StructDecl);
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .name = .{ .parts = name_parts, .span = .{ .start = 0, .end = 0 } },
                .fields = try fields.toOwnedSlice(alloc),
            };
            return .{ .struct_decl = decl };
        }
    }

    // Use: {:use, meta, [aliases]}
    if (std.mem.eql(u8, form_name, "use")) {
        if (args == .list and args.list.elems.len > 0) {
            const aliases = args.list.elems[0];
            if (aliases == .tuple and aliases.tuple.elems.len == 3) {
                if (aliases.tuple.elems[0] == .atom and std.mem.eql(u8, aliases.tuple.elems[0].atom, "__aliases__")) {
                    if (aliases.tuple.elems[2] == .list) {
                        var parts : std.ArrayListUnmanaged(ast.StringId) = .empty;
                        for (aliases.tuple.elems[2].list.elems) |part| {
                            if (part == .atom) try parts.append(alloc, try interner.intern(part.atom));
                        }
                        const decl = try alloc.create(ast.UseDecl);
                        decl.* = .{
                            .meta = .{ .span = .{ .start = 0, .end = 0 } },
                            .module_path = .{ .parts = try parts.toOwnedSlice(alloc), .span = .{ .start = 0, .end = 0 } },
                            .opts = null,
                        };
                        return .{ .use_decl = decl };
                    }
                }
            }
        }
    }

    // Union: {:union, meta, [name, [variants...]]}
    if (std.mem.eql(u8, form_name, "union")) {
        if (args == .list and args.list.elems.len >= 1) {
            const name_val = args.list.elems[0];
            const name_id: ast.StringId = if (name_val == .atom) try interner.intern(name_val.atom) else 0;
            var variants : std.ArrayListUnmanaged(ast.UnionVariant) = .empty;
            if (args.list.elems.len >= 2 and args.list.elems[1] == .list) {
                for (args.list.elems[1].list.elems) |v| {
                    if (v == .atom) {
                        try variants.append(alloc, .{
                            .meta = .{ .span = .{ .start = 0, .end = 0 } },
                            .name = try interner.intern(v.atom),
                        });
                    } else if (v == .tuple and v.tuple.elems.len == 2 and v.tuple.elems[0] == .atom) {
                        try variants.append(alloc, .{
                            .meta = .{ .span = .{ .start = 0, .end = 0 } },
                            .name = try interner.intern(v.tuple.elems[0].atom),
                            .type_expr = try ctValueToTypeExpr(alloc, interner, v.tuple.elems[1]),
                        });
                    }
                }
            }
            const decl = try alloc.create(ast.UnionDecl);
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .name = name_id,
                .variants = try variants.toOwnedSlice(alloc),
            };
            return .{ .union_decl = decl };
        }
    }

    // Attribute: {:@, meta, [:name]} or {:@, meta, [:name, value]}
    if (std.mem.eql(u8, form_name, "@")) {
        if (args == .list and args.list.elems.len >= 1 and args.list.elems[0] == .atom) {
            const attr_value: ?*const ast.Expr = if (args.list.elems.len >= 2)
                try ctValueToExpr(alloc, interner, args.list.elems[1])
            else
                null;
            const decl = try alloc.create(ast.AttributeDecl);
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .name = try interner.intern(args.list.elems[0].atom),
                .value = attr_value,
            };
            return .{ .attribute = decl };
        }
    }

    // Alias: {:alias, meta, [module_path, ?as_name]}
    if (std.mem.eql(u8, form_name, "alias")) {
        if (args == .list and args.list.elems.len >= 1) {
            const mod_aliases = args.list.elems[0];
            var mod_parts : std.ArrayListUnmanaged(ast.StringId) = .empty;
            if (mod_aliases == .tuple and mod_aliases.tuple.elems.len == 3 and mod_aliases.tuple.elems[2] == .list) {
                for (mod_aliases.tuple.elems[2].list.elems) |part| {
                    if (part == .atom) try mod_parts.append(alloc, try interner.intern(part.atom));
                }
            }
            var as_name: ?ast.StructName = null;
            if (args.list.elems.len >= 2) {
                const as_aliases = args.list.elems[1];
                if (as_aliases == .tuple and as_aliases.tuple.elems.len == 3 and as_aliases.tuple.elems[2] == .list) {
                    var as_parts : std.ArrayListUnmanaged(ast.StringId) = .empty;
                    for (as_aliases.tuple.elems[2].list.elems) |part| {
                        if (part == .atom) try as_parts.append(alloc, try interner.intern(part.atom));
                    }
                    as_name = .{ .parts = try as_parts.toOwnedSlice(alloc), .span = .{ .start = 0, .end = 0 } };
                }
            }
            const decl = try alloc.create(ast.AliasDecl);
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .module_path = .{ .parts = try mod_parts.toOwnedSlice(alloc), .span = .{ .start = 0, .end = 0 } },
                .as_name = as_name,
            };
            return .{ .alias_decl = decl };
        }
    }

    // Type: {:type, meta, [:Name, body_type]}
    if (std.mem.eql(u8, form_name, "type")) {
        if (args == .list and args.list.elems.len >= 2 and args.list.elems[0] == .atom) {
            const decl = try alloc.create(ast.TypeDecl);
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .name = try interner.intern(args.list.elems[0].atom),
                .params = &.{},
                .body = try ctValueToTypeExpr(alloc, interner, args.list.elems[1]),
            };
            return .{ .type_decl = decl };
        }
    }

    // Opaque: {:opaque, meta, [:Name, body_type]}
    if (std.mem.eql(u8, form_name, "opaque")) {
        if (args == .list and args.list.elems.len >= 2 and args.list.elems[0] == .atom) {
            const decl = try alloc.create(ast.OpaqueDecl);
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .name = try interner.intern(args.list.elems[0].atom),
                .params = &.{},
                .body = try ctValueToTypeExpr(alloc, interner, args.list.elems[1]),
            };
            return .{ .opaque_decl = decl };
        }
    }

    // Module: {:module, meta, [name, [do: [items...]]]}
    if (std.mem.eql(u8, form_name, "module")) {
        if (args == .list and args.list.elems.len >= 2) {
            const name_ct = args.list.elems[0];
            var name_parts : std.ArrayListUnmanaged(ast.StringId) = .empty;
            if (name_ct == .tuple and name_ct.tuple.elems.len == 3 and name_ct.tuple.elems[2] == .list) {
                for (name_ct.tuple.elems[2].list.elems) |part| {
                    if (part == .atom) try name_parts.append(alloc, try interner.intern(part.atom));
                }
            }
            // Extract items from [do: [items...]]
            // For now, return an empty module — full item reconstruction is complex
            const decl = try alloc.create(ast.StructDecl);
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .name = .{ .parts = try name_parts.toOwnedSlice(alloc), .span = .{ .start = 0, .end = 0 } },
            };
            // Struct goes in TopItem, not StructItem — return null for now
            // (structs inside structs are rare)
        }
    }

    return null;
}

/// Convert a CtValue back to a Param.
fn ctValueToParam(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) error{OutOfMemory}!ast.Param {
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    // {:::, [], [pattern, type]}
    if (value == .tuple and value.tuple.elems.len == 3) {
        if (value.tuple.elems[0] == .atom and std.mem.eql(u8, value.tuple.elems[0].atom, "::")) {
            if (value.tuple.elems[2] == .list and value.tuple.elems[2].list.elems.len == 2) {
                const pat = try ctValueToPattern(alloc, interner, value.tuple.elems[2].list.elems[0]);
                const te = try ctValueToTypeExpr(alloc, interner, value.tuple.elems[2].list.elems[1]);
                return .{ .meta = meta, .pattern = pat, .type_annotation = te };
            }
        }
    }

    // Just a pattern, no type annotation
    const pat = try ctValueToPattern(alloc, interner, value);
    return .{ .meta = meta, .pattern = pat, .type_annotation = null };
}

// ============================================================
// Tests
// ============================================================

test "integer literal to CtValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const expr = try alloc.create(ast.Expr);
    expr.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 42 } };

    const result = try exprToCtValue(alloc, &interner, &store, expr);

    // Should be a 3-tuple: {42, [], nil}
    try std.testing.expect(result == .tuple);
    try std.testing.expectEqual(@as(usize, 3), result.tuple.elems.len);
    try std.testing.expect(result.tuple.elems[0] == .int);
    try std.testing.expectEqual(@as(i64, 42), result.tuple.elems[0].int);
    try std.testing.expect(result.tuple.elems[1] == .list); // metadata
    try std.testing.expect(result.tuple.elems[2] == .nil);
}

test "variable to CtValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const name = try interner.intern("x");
    const expr = try alloc.create(ast.Expr);
    expr.* = .{ .var_ref = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .name = name } };

    const result = try exprToCtValue(alloc, &interner, &store, expr);

    // Should be {:x, [], nil}
    try std.testing.expect(result == .tuple);
    try std.testing.expectEqual(@as(usize, 3), result.tuple.elems.len);
    try std.testing.expect(result.tuple.elems[0] == .atom);
    try std.testing.expect(std.mem.eql(u8, result.tuple.elems[0].atom, "x"));
    try std.testing.expect(result.tuple.elems[2] == .nil);
}

test "binary op to CtValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const lhs = try alloc.create(ast.Expr);
    lhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 1 } };
    const rhs = try alloc.create(ast.Expr);
    rhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 2 } };

    const expr = try alloc.create(ast.Expr);
    expr.* = .{ .binary_op = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .op = .add,
        .lhs = lhs,
        .rhs = rhs,
    } };

    const result = try exprToCtValue(alloc, &interner, &store, expr);

    // Should be {:+, [], [{1, [], nil}, {2, [], nil}]}
    try std.testing.expect(result == .tuple);
    try std.testing.expectEqual(@as(usize, 3), result.tuple.elems.len);
    try std.testing.expect(result.tuple.elems[0] == .atom);
    try std.testing.expect(std.mem.eql(u8, result.tuple.elems[0].atom, "+"));
    try std.testing.expect(result.tuple.elems[2] == .list);
    try std.testing.expectEqual(@as(usize, 2), result.tuple.elems[2].list.elems.len);

    // Left operand: {1, [], nil}
    const left = result.tuple.elems[2].list.elems[0];
    try std.testing.expect(left == .tuple);
    try std.testing.expect(left.tuple.elems[0] == .int);
    try std.testing.expectEqual(@as(i64, 1), left.tuple.elems[0].int);
}

test "atom literal to CtValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const name = try interner.intern("ok");
    const expr = try alloc.create(ast.Expr);
    expr.* = .{ .atom_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = name } };

    const result = try exprToCtValue(alloc, &interner, &store, expr);

    // Should be {":ok", [], nil} — atoms are prefixed with ":" in CtValue
    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.elems[0] == .atom);
    try std.testing.expect(std.mem.eql(u8, result.tuple.elems[0].atom, ":ok"));
    try std.testing.expect(result.tuple.elems[2] == .nil);
}

test "bool literal to CtValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const expr = try alloc.create(ast.Expr);
    expr.* = .{ .bool_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = true } };

    const result = try exprToCtValue(alloc, &interner, &store, expr);

    // Should be {true, [], nil}
    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.elems[0] == .bool_val);
    try std.testing.expect(result.tuple.elems[0].bool_val == true);
    try std.testing.expect(result.tuple.elems[2] == .nil);
}

test "pipe to CtValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const lhs = try alloc.create(ast.Expr);
    lhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 5 } };
    const callee = try alloc.create(ast.Expr);
    const foo_name = try interner.intern("foo");
    callee.* = .{ .var_ref = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .name = foo_name } };
    const rhs = try alloc.create(ast.Expr);
    rhs.* = .{ .call = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .callee = callee, .args = &.{} } };

    const expr = try alloc.create(ast.Expr);
    expr.* = .{ .pipe = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .lhs = lhs, .rhs = rhs } };

    const result = try exprToCtValue(alloc, &interner, &store, expr);

    // Should be {:|>, [], [{5, [], nil}, {:foo, [], []}]}
    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.elems[0] == .atom);
    try std.testing.expect(std.mem.eql(u8, result.tuple.elems[0].atom, "|>"));
    try std.testing.expect(result.tuple.elems[2] == .list);
    try std.testing.expectEqual(@as(usize, 2), result.tuple.elems[2].list.elems.len);
}

// ============================================================
// Round-trip tests: exprToCtValue → ctValueToExpr
// ============================================================

test "round-trip: integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 99 } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .int_literal);
    try std.testing.expectEqual(@as(i64, 99), back.int_literal.value);
}

test "round-trip: string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const sid = try interner.intern("hello");
    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .string_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = sid } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .string_literal);
    try std.testing.expect(std.mem.eql(u8, interner.get(back.string_literal.value), "hello"));
}

test "round-trip: variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const name = try interner.intern("my_var");
    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .var_ref = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .name = name } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .var_ref);
    try std.testing.expect(std.mem.eql(u8, interner.get(back.var_ref.name), "my_var"));
}

test "round-trip: binary op (add)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const lhs = try alloc.create(ast.Expr);
    lhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 3 } };
    const rhs = try alloc.create(ast.Expr);
    rhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 4 } };
    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .binary_op = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .op = .add, .lhs = lhs, .rhs = rhs } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .binary_op);
    try std.testing.expect(back.binary_op.op == .add);
    try std.testing.expect(back.binary_op.lhs.* == .int_literal);
    try std.testing.expectEqual(@as(i64, 3), back.binary_op.lhs.int_literal.value);
    try std.testing.expect(back.binary_op.rhs.* == .int_literal);
    try std.testing.expectEqual(@as(i64, 4), back.binary_op.rhs.int_literal.value);
}

test "round-trip: function call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const callee = try alloc.create(ast.Expr);
    const foo = try interner.intern("foo");
    callee.* = .{ .var_ref = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .name = foo } };
    const arg1 = try alloc.create(ast.Expr);
    arg1.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 42 } };

    const args = try alloc.alloc(*const ast.Expr, 1);
    args[0] = arg1;

    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .call = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .callee = callee, .args = args } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .call);
    try std.testing.expect(back.call.callee.* == .var_ref);
    try std.testing.expect(std.mem.eql(u8, interner.get(back.call.callee.var_ref.name), "foo"));
    try std.testing.expectEqual(@as(usize, 1), back.call.args.len);
    try std.testing.expect(back.call.args[0].* == .int_literal);
    try std.testing.expectEqual(@as(i64, 42), back.call.args[0].int_literal.value);
}

test "round-trip: bool literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .bool_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = true } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .bool_literal);
    try std.testing.expect(back.bool_literal.value == true);
}

test "round-trip: atom literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const name = try interner.intern("Ok");
    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .atom_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = name } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    // Atom starting with uppercase → atom_literal
    try std.testing.expect(back.* == .atom_literal);
    try std.testing.expect(std.mem.eql(u8, interner.get(back.atom_literal.value), "Ok"));
}

test "round-trip: nil literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .nil_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } } } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .nil_literal);
}

test "round-trip: pipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const lhs = try alloc.create(ast.Expr);
    lhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 5 } };
    const callee = try alloc.create(ast.Expr);
    callee.* = .{ .var_ref = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .name = try interner.intern("foo") } };
    const rhs = try alloc.create(ast.Expr);
    rhs.* = .{ .call = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .callee = callee, .args = &.{} } };

    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .pipe = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .lhs = lhs, .rhs = rhs } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .pipe);
    try std.testing.expect(back.pipe.lhs.* == .int_literal);
    try std.testing.expectEqual(@as(i64, 5), back.pipe.lhs.int_literal.value);
}

// ============================================================
// Declaration round-trip tests (Phase 5)
// ============================================================

test "round-trip: function declaration to CtValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    // Build: pub fn add(a :: i64, b :: i64) -> i64 { a + b }
    const a_name = try interner.intern("a");
    const b_name = try interner.intern("b");
    const add_name = try interner.intern("add");

    const a_pat = try alloc.create(ast.Pattern);
    a_pat.* = .{ .bind = .{ .meta = meta, .name = a_name } };
    const b_pat = try alloc.create(ast.Pattern);
    b_pat.* = .{ .bind = .{ .meta = meta, .name = b_name } };

    const i64_type = try alloc.create(ast.TypeExpr);
    i64_type.* = .{ .name = .{ .meta = meta, .name = try interner.intern("i64"), .args = &.{} } };

    const a_ref = try alloc.create(ast.Expr);
    a_ref.* = .{ .var_ref = .{ .meta = meta, .name = a_name } };
    const b_ref = try alloc.create(ast.Expr);
    b_ref.* = .{ .var_ref = .{ .meta = meta, .name = b_name } };
    const body_expr = try alloc.create(ast.Expr);
    body_expr.* = .{ .binary_op = .{ .meta = meta, .op = .add, .lhs = a_ref, .rhs = b_ref } };

    const params = try alloc.alloc(ast.Param, 2);
    params[0] = .{ .meta = meta, .pattern = a_pat, .type_annotation = i64_type };
    params[1] = .{ .meta = meta, .pattern = b_pat, .type_annotation = i64_type };

    const body = try alloc.alloc(ast.Stmt, 1);
    body[0] = .{ .expr = body_expr };

    const clauses = try alloc.alloc(ast.FunctionClause, 1);
    clauses[0] = .{
        .meta = meta,
        .params = params,
        .return_type = i64_type,
        .refinement = null,
        .body = body,
    };

    const func_decl = try alloc.create(ast.FunctionDecl);
    func_decl.* = .{
        .meta = meta,
        .name = add_name,
        .visibility = .public,
        .clauses = clauses,
    };

    // Convert to CtValue
    const item: ast.StructItem = .{ .function = func_decl };
    const ct = try structItemToCtValue(alloc, &interner, &store, item);

    // Should be a 3-tuple with form :fn
    try std.testing.expect(ct == .tuple);
    try std.testing.expectEqual(@as(usize, 3), ct.tuple.elems.len);
    try std.testing.expect(ct.tuple.elems[0] == .atom);
    try std.testing.expect(std.mem.eql(u8, ct.tuple.elems[0].atom, "fn"));

    // Round-trip back
    const back = ctValueToStructItem(alloc, &interner, ct) catch null;
    try std.testing.expect(back != null);
    try std.testing.expect(back.? == .function);
}

test "round-trip: struct declaration to CtValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    // Build: pub struct Point { x :: i64, y :: i64 }
    const i64_type = try alloc.create(ast.TypeExpr);
    i64_type.* = .{ .name = .{ .meta = meta, .name = try interner.intern("i64"), .args = &.{} } };

    const fields = try alloc.alloc(ast.StructFieldDecl, 2);
    fields[0] = .{ .meta = meta, .name = try interner.intern("x"), .type_expr = i64_type, .default = null };
    fields[1] = .{ .meta = meta, .name = try interner.intern("y"), .type_expr = i64_type, .default = null };

    const name_parts = try alloc.alloc(ast.StringId, 1);
    name_parts[0] = try interner.intern("Point");
    const struct_decl = try alloc.create(ast.StructDecl);
    struct_decl.* = .{
        .meta = meta,
        .name = .{ .parts = name_parts, .span = .{ .start = 0, .end = 0 } },
        .fields = fields,
    };

    // Convert to CtValue
    const item: ast.StructItem = .{ .struct_decl = struct_decl };
    const ct = try structItemToCtValue(alloc, &interner, &store, item);

    // Should be a 3-tuple with form :struct
    try std.testing.expect(ct == .tuple);
    try std.testing.expectEqual(@as(usize, 3), ct.tuple.elems.len);
    try std.testing.expect(ct.tuple.elems[0] == .atom);
    try std.testing.expect(std.mem.eql(u8, ct.tuple.elems[0].atom, "struct"));

    // Round-trip back
    const back = ctValueToStructItem(alloc, &interner, ct) catch null;
    try std.testing.expect(back != null);
    try std.testing.expect(back.? == .struct_decl);
}
