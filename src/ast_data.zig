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
const scope_mod = @import("scope.zig");
const CtValue = ctfe.CtValue;
const AllocId = ctfe.AllocId;
const AllocationStore = ctfe.AllocationStore;
const Allocator = std.mem.Allocator;

pub const CtValueDecodeError = Allocator.Error || error{
    InvalidCtValueInteger,
    InvalidCtValueShape,
    StructuralBudgetExceeded,
};

fn checkedCtInt(comptime T: type, value: i64) CtValueDecodeError!T {
    return std.math.cast(T, value) orelse error.InvalidCtValueInteger;
}

const CTVALUE_DECODE_MAX_DEPTH: usize = 4096;
const CTVALUE_DECODE_NODE_BUDGET: usize = 1_000_000;

const CtValueDecodeBudget = struct {
    depth_remaining: usize,
    nodes_remaining: usize,

    fn default() CtValueDecodeBudget {
        return .{
            .depth_remaining = CTVALUE_DECODE_MAX_DEPTH,
            .nodes_remaining = CTVALUE_DECODE_NODE_BUDGET,
        };
    }

    fn init(depth: usize, nodes: usize) CtValueDecodeBudget {
        return .{ .depth_remaining = depth, .nodes_remaining = nodes };
    }

    fn enter(self: *CtValueDecodeBudget) CtValueDecodeError!void {
        if (self.depth_remaining == 0 or self.nodes_remaining == 0) {
            return error.StructuralBudgetExceeded;
        }
        self.depth_remaining -= 1;
        self.nodes_remaining -= 1;
    }

    fn leave(self: *CtValueDecodeBudget) void {
        self.depth_remaining += 1;
    }

    fn consumeNode(self: *CtValueDecodeBudget) CtValueDecodeError!void {
        if (self.nodes_remaining == 0) return error.StructuralBudgetExceeded;
        self.nodes_remaining -= 1;
    }
};

const IDENTIFIER_SCOPE_TRANSFORM_INLINE_STACK_CAPACITY: usize = 64;
const IDENTIFIER_SCOPE_TRANSFORM_STEP_BUDGET: usize = 1_000_000;

fn SmallInlineStack(comptime T: type, comptime inline_capacity: usize) type {
    return struct {
        inline_items: [inline_capacity]T = undefined,
        inline_len: usize = 0,
        spill: std.ArrayListUnmanaged(T) = .empty,

        const Self = @This();

        fn deinit(self: *Self, allocator: Allocator) void {
            self.spill.deinit(allocator);
        }

        fn len(self: *const Self) usize {
            return self.inline_len + self.spill.items.len;
        }

        fn append(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            if (self.spill.items.len == 0 and self.inline_len < inline_capacity) {
                self.inline_items[self.inline_len] = item;
                self.inline_len += 1;
                return;
            }
            try self.spill.append(allocator, item);
        }

        fn pop(self: *Self) T {
            std.debug.assert(self.len() != 0);
            if (self.spill.items.len != 0) return self.spill.pop().?;
            self.inline_len -= 1;
            return self.inline_items[self.inline_len];
        }
    };
}

const IdentifierScopeTransformFrame = union(enum) {
    visit: CtValue,
    finish_tuple3: CtValue.CtTupleValue,
    finish_tuple2: CtValue.CtTupleValue,
    finish_list: CtValue.CtListValue,
};

/// Convert an ast.Expr to its CtValue 3-tuple representation.
pub fn exprToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    expr: *const ast.Expr,
) error{OutOfMemory}!CtValue {
    return switch (expr.*) {
        // Literals — wrapped in 3-tuples: {value, metadata, nil}
        .int_literal => |v| makeTuple3WithTemporaryChildren(alloc, store, .{ .int = v.value }, try metaToList(alloc, store, v.meta, null), .nil),
        .float_literal => |v| makeTuple3WithTemporaryChildren(alloc, store, .{ .float = v.value }, try metaToList(alloc, store, v.meta, null), .nil),
        .string_literal => |v| makeTuple3WithTemporaryChildren(alloc, store, .{ .string = interner.get(v.value) }, try metaToList(alloc, store, v.meta, null), .nil),
        .atom_literal => |v| {
            // Prefix atom names with ":" to distinguish from variables in round-trip
            const name = interner.get(v.value);
            const prefixed = try prefixedAtomLiteralName(alloc, interner, name);
            return makeTuple3WithTemporaryChildren(alloc, store, .{ .atom = prefixed }, try metaToList(alloc, store, v.meta, null), .nil);
        },
        .bool_literal => |v| makeTuple3WithTemporaryChildren(alloc, store, .{ .bool_val = v.value }, try metaToList(alloc, store, v.meta, null), .nil),
        .nil_literal => |v| makeTuple3WithTemporaryChildren(alloc, store, .nil, try metaToList(alloc, store, v.meta, null), .nil),

        // Variables: {:name, meta, nil}
        .var_ref => |v| {
            const meta = try metaToList(alloc, store, v.meta, null);
            return makeTuple3WithTemporaryChildren(alloc, store, .{ .atom = interner.get(v.name) }, meta, .nil);
        },

        // Binary operators: {:op, meta, [left, right]}
        .binary_op => |v| {
            const op_atom: CtValue = .{ .atom = binopToString(v.op) };
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.lhs));
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.rhs));
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, op_atom, meta, args, &owner);
        },

        // Unary operators: {:op, meta, [operand]}
        .unary_op => |v| {
            const op_atom: CtValue = .{ .atom = unopToString(v.op) };
            const operand = try exprToCtValue(alloc, interner, store, v.operand);
            const args = try makeListWithTemporaryChildren(alloc, store, &.{operand});
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, op_atom, meta, args, &owner);
        },

        // Calls: {:name, meta, [args...]}
        .call => |v| {
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            const form = try calleeToCtValue(alloc, interner, store, v.callee);
            try owner.adopt(form);
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            for (v.args) |arg| {
                try arg_vals.append(try exprToCtValue(alloc, interner, store, arg));
            }
            const args = try arg_vals.toCtList();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, form, meta, args, &owner);
        },

        .anonymous_function => |v| blk: {
            const name = interner.get(v.decl.name);
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(.{ .atom = name });
            const params = try paramsToCtList(alloc, interner, store, v.decl.clauses[0].params);
            try arg_vals.append(params);
            const body = if (v.decl.clauses[0].body) |body_stmts|
                try blockToCtValue(alloc, interner, store, body_stmts)
            else
                .nil;
            try arg_vals.append(body);
            const ret_type = if (v.decl.clauses[0].return_type) |rt|
                try typeExprToCtValue(alloc, interner, store, rt)
            else
                CtValue.nil;
            try arg_vals.append(ret_type);
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            break :blk try makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "fn" }, meta, args, &owner);
        },

        // Pipe: {:|>, meta, [left, right]}
        .pipe => |v| {
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.lhs));
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.rhs));
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "|>" }, meta, args, &owner);
        },

        // Field access: {:., meta, [object, :field]}
        .field_access => |v| {
            const obj = try exprToCtValue(alloc, interner, store, v.object);
            const field: CtValue = .{ .atom = interner.get(v.field) };
            const args = try makeListWithTemporaryChildren(alloc, store, &.{ obj, field });
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "." }, meta, args, &owner);
        },

        // Tuple: {:{}, meta, [elements...]}
        .tuple => |v| {
            var elem_vals = TemporaryCtValueList.init(alloc, store);
            defer elem_vals.deinit();
            for (v.elements) |elem| {
                try elem_vals.append(try exprToCtValue(alloc, interner, store, elem));
            }
            const args = try elem_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "{}" }, meta, args, &owner);
        },

        // List: bare list [elements...]
        .list => |v| {
            var elem_vals = TemporaryCtValueList.init(alloc, store);
            defer elem_vals.deinit();
            for (v.elements) |elem| {
                try elem_vals.append(try exprToCtValue(alloc, interner, store, elem));
            }
            return elem_vals.toCtList();
        },

        // Block: {:__block__, meta, [stmts...]}
        .block => |v| {
            var stmt_vals = TemporaryCtValueList.init(alloc, store);
            defer stmt_vals.deinit();
            for (v.stmts) |stmt| {
                try stmt_vals.append(try stmtToCtValue(alloc, interner, store, stmt));
            }
            const args = try stmt_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "__block__" }, meta, args, &owner);
        },

        // If: {:if, meta, [condition, [do: then, else: else]]}
        .if_expr => |v| {
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.condition));
            const then_val = try blockToCtValue(alloc, interner, store, v.then_block);
            var kw_elems = TemporaryCtValueList.init(alloc, store);
            defer kw_elems.deinit();
            try kw_elems.append(try makeKeywordPair(alloc, store, "do", then_val));
            if (v.else_block) |else_block| {
                const else_val = try blockToCtValue(alloc, interner, store, else_block);
                try kw_elems.append(try makeKeywordPair(alloc, store, "else", else_val));
            }
            const kw_list = try kw_elems.toCtList();
            try arg_vals.append(kw_list);
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "if" }, meta, args, &owner);
        },

        // Case: {:case, meta, [subject, [do: [clauses...]]]}
        .case_expr => |v| {
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.scrutinee));
            var clause_vals = TemporaryCtValueList.init(alloc, store);
            defer clause_vals.deinit();
            for (v.clauses) |clause| {
                try clause_vals.append(try caseClauseToCtValue(alloc, interner, store, clause));
            }
            const clauses_list = try clause_vals.toCtList();
            const do_pair = try makeKeywordPair(alloc, store, "do", clauses_list);
            const kw_list = try makeListWithTemporaryChildren(alloc, store, &.{do_pair});
            try arg_vals.append(kw_list);
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "case" }, meta, args, &owner);
        },

        // Struct ref: {:__aliases__, meta, [:Part1, :Part2, ...]}
        // Parametric variant constructors (`Option(i64).Some`,
        // `Result(i64, String).Err`) attach a `type_args` field on
        // `StructRef` that must round-trip through quote/unquote.
        // Encode it as a `type_args: [...]` keyword in the meta list
        // so the args list still mirrors Elixir's `__aliases__`
        // convention (just atom segments). The decoder
        // (`ctValueToExpr` in this file) reads the meta keyword back
        // out into `mr.type_args` when reconstructing the AST node.
        .struct_ref => |v| {
            var parts = TemporaryCtValueList.init(alloc, store);
            defer parts.deinit();
            for (v.name.parts) |part| {
                try parts.append(CtValue{ .atom = interner.get(part) });
            }
            const args = try parts.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try structRefMetaWithTypeArgs(alloc, interner, store, v.meta, v.type_args);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "__aliases__" }, meta, args, &owner);
        },

        // Quote: {:quote, meta, [body]}
        .quote_expr => |v| {
            var body_vals = TemporaryCtValueList.init(alloc, store);
            defer body_vals.deinit();
            for (v.body) |stmt| {
                try body_vals.append(try stmtToCtValue(alloc, interner, store, stmt));
            }
            const body_list = try body_vals.toCtList();
            const args = try makeListWithTemporaryChildren(alloc, store, &.{body_list});
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "quote" }, meta, args, &owner);
        },

        // Unquote: {:unquote, meta, [expr]}
        .unquote_expr => |v| {
            const inner = try exprToCtValue(alloc, interner, store, v.expr);
            const args = try makeListWithTemporaryChildren(alloc, store, &.{inner});
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "unquote" }, meta, args, &owner);
        },

        .unquote_splicing_expr => |v| {
            const inner = try exprToCtValue(alloc, interner, store, v.expr);
            const args = try makeListWithTemporaryChildren(alloc, store, &.{inner});
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "unquote_splicing" }, meta, args, &owner);
        },

        // Type annotated: {:::, [], [expr, type]}
        .type_annotated => |v| {
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.expr));
            try arg_vals.append(try typeExprToCtValue(alloc, interner, store, v.type_expr));
            const args_list = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args_list);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "::" }, meta, args_list, &owner);
        },

        // Error pipe: {:~>, meta, [chain, handler]}
        .error_pipe => |v| {
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.chain));
            const handler = switch (v.handler) {
                .block => |clauses| blk: {
                    var clause_vals = TemporaryCtValueList.init(alloc, store);
                    defer clause_vals.deinit();
                    for (clauses) |clause| {
                        try clause_vals.append(try caseClauseToCtValue(alloc, interner, store, clause));
                    }
                    break :blk try clause_vals.toCtList();
                },
                .function => |func| try exprToCtValue(alloc, interner, store, func),
            };
            try arg_vals.append(handler);
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "~>" }, meta, args, &owner);
        },

        // Map: {:%{}, meta, [pairs...]}
        .map => |v| {
            var pair_vals = TemporaryCtValueList.init(alloc, store);
            defer pair_vals.deinit();
            for (v.fields) |field| {
                var pair_owner = TemporaryCtValueOwner.init(alloc, store);
                defer pair_owner.deinit();
                const key = try exprToCtValue(alloc, interner, store, field.key);
                try pair_owner.adopt(key);
                const val = try exprToCtValue(alloc, interner, store, field.value);
                try pair_owner.adopt(val);
                const pair = try makeTuple2(alloc, store, key, val);
                pair_owner.release();
                try pair_vals.append(pair);
            }
            const args = try pair_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "%{}" }, meta, args, &owner);
        },

        // Struct: {:%, meta, [name, {:%{}, [], [fields...]}, update_source_or_nil]}
        .struct_expr => |v| {
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();

            var name_parts = TemporaryCtValueList.init(alloc, store);
            defer name_parts.deinit();
            for (v.struct_name.parts) |part| {
                try name_parts.append(CtValue{ .atom = interner.get(part) });
            }
            try arg_vals.append(try name_parts.toCtList());

            var field_vals = TemporaryCtValueList.init(alloc, store);
            defer field_vals.deinit();
            for (v.fields) |field| {
                const key: CtValue = .{ .atom = interner.get(field.name) };
                const val = try exprToCtValue(alloc, interner, store, field.value);
                try field_vals.append(try makeTuple2WithTemporaryChildren(alloc, store, key, val));
            }
            const fields_list = try field_vals.toCtList();
            var map_owner = TemporaryCtValueOwner.init(alloc, store);
            defer map_owner.deinit();
            try map_owner.adopt(fields_list);
            const map_meta = try emptyList(alloc, store);
            try map_owner.adopt(map_meta);
            const map_node = try makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "%{}" }, map_meta, fields_list, &map_owner);
            try arg_vals.append(map_node);
            const update_val: CtValue = if (v.update_source) |source|
                try exprToCtValue(alloc, interner, store, source)
            else
                .nil;
            try arg_vals.append(update_val);
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try structExprMetaWithTypeArgs(alloc, interner, store, v.meta, v.type_args, v.type_args_parens_present);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "%" }, meta, args, &owner);
        },

        // Intrinsic: {:__intrinsic__, meta, [:name, args...]}
        .intrinsic => |v| {
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(CtValue{ .atom = interner.get(v.name) });
            for (v.args) |arg| {
                try arg_vals.append(try exprToCtValue(alloc, interner, store, arg));
            }
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "__intrinsic__" }, meta, args, &owner);
        },

        // String interpolation: {:<<>>, meta, [parts...]} where each part is a string or expr
        .string_interpolation => |v| {
            var part_vals = TemporaryCtValueList.init(alloc, store);
            defer part_vals.deinit();
            for (v.parts) |part| {
                switch (part) {
                    .literal => |sid| try part_vals.append(try makeTuple3WithTemporaryChildren(alloc, store, .{ .string = interner.get(sid) }, try emptyList(alloc, store), .nil)),
                    .expr => |e| try part_vals.append(try exprToCtValue(alloc, interner, store, e)),
                }
            }
            const args = try part_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "<<>>" }, meta, args, &owner);
        },
        .unwrap => |v| {
            const inner = try exprToCtValue(alloc, interner, store, v.expr);
            const args = try makeListWithTemporaryChildren(alloc, store, &.{inner});
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "!" }, meta, args, &owner);
        },
        .panic_expr => |v| {
            const msg = try exprToCtValue(alloc, interner, store, v.message);
            const args = try makeListWithTemporaryChildren(alloc, store, &.{msg});
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "panic" }, meta, args, &owner);
        },
        .raise_expr => |v| {
            const value = try exprToCtValue(alloc, interner, store, v.value);
            const args = try makeListWithTemporaryChildren(alloc, store, &.{value});
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "raise" }, meta, args, &owner);
        },
        // {:try_rescue, meta, [do: body, rescue: [clauses...], after: cleanup_or_nil]}
        // where each rescue clause is {:->, [], [[pattern], body]}, mirroring
        // the `cond`/`case` arm serialization.
        .try_rescue => |v| {
            var kw_vals = TemporaryCtValueList.init(alloc, store);
            defer kw_vals.deinit();
            const body_val = try blockToCtValue(alloc, interner, store, v.body);
            try kw_vals.append(try makeKeywordPair(alloc, store, "do", body_val));
            var clause_vals = TemporaryCtValueList.init(alloc, store);
            defer clause_vals.deinit();
            for (v.rescue_clauses) |clause| {
                var clause_arg_vals = TemporaryCtValueList.init(alloc, store);
                defer clause_arg_vals.deinit();
                const pat = try patternToCtValue(alloc, interner, store, clause.pattern);
                const pat_list = try makeListWithTemporaryChildren(alloc, store, &.{pat});
                try clause_arg_vals.append(pat_list);
                const clause_body = try blockToCtValue(alloc, interner, store, clause.body);
                try clause_arg_vals.append(clause_body);
                const clause_args = try clause_arg_vals.toCtList();
                var clause_owner = TemporaryCtValueOwner.init(alloc, store);
                defer clause_owner.deinit();
                try clause_owner.adopt(clause_args);
                const clause_meta = try emptyList(alloc, store);
                try clause_owner.adopt(clause_meta);
                try clause_vals.append(try makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "->" }, clause_meta, clause_args, &clause_owner));
            }
            const clauses_list = try clause_vals.toCtList();
            try kw_vals.append(try makeKeywordPair(alloc, store, "rescue", clauses_list));
            const after_val: CtValue = if (v.after_block) |cleanup|
                try blockToCtValue(alloc, interner, store, cleanup)
            else
                CtValue.nil;
            try kw_vals.append(try makeKeywordPair(alloc, store, "after", after_val));
            const kw_list = try kw_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(kw_list);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "try_rescue" }, meta, kw_list, &owner);
        },
        .with_expr => |v| {
            // {:with, meta, [steps: [steps...], do: do_body, else: clauses_or_nil]}
            // where each step is {:<-, meta, [[pattern], expr]} (mirroring
            // the `->` clause encoding but tagged `<-` to denote a bind
            // step) and each else clause is {:->, [], [[pattern], body]}.
            // `with` is desugared to nested `case` during macro expansion,
            // so this round-trip only matters for `with` appearing inside a
            // quoted macro body.
            var step_vals = TemporaryCtValueList.init(alloc, store);
            defer step_vals.deinit();
            for (v.steps) |step| {
                var step_arg_vals = TemporaryCtValueList.init(alloc, store);
                defer step_arg_vals.deinit();
                const pat = try patternToCtValue(alloc, interner, store, step.pattern);
                const pat_list = try makeListWithTemporaryChildren(alloc, store, &.{pat});
                try step_arg_vals.append(pat_list);
                try step_arg_vals.append(try exprToCtValue(alloc, interner, store, step.expr));
                const step_args = try step_arg_vals.toCtList();
                var step_owner = TemporaryCtValueOwner.init(alloc, store);
                defer step_owner.deinit();
                try step_owner.adopt(step_args);
                const step_meta = try metaToList(alloc, store, step.meta, null);
                try step_owner.adopt(step_meta);
                try step_vals.append(try makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "<-" }, step_meta, step_args, &step_owner));
            }
            const steps_list = try step_vals.toCtList();
            var kw_vals = TemporaryCtValueList.init(alloc, store);
            defer kw_vals.deinit();
            try kw_vals.append(try makeKeywordPair(alloc, store, "steps", steps_list));
            const do_val = try blockToCtValue(alloc, interner, store, v.do_body);
            try kw_vals.append(try makeKeywordPair(alloc, store, "do", do_val));
            const else_val: CtValue = if (v.else_clauses) |clauses| blk: {
                var clause_vals = TemporaryCtValueList.init(alloc, store);
                defer clause_vals.deinit();
                for (clauses) |clause| {
                    var clause_arg_vals = TemporaryCtValueList.init(alloc, store);
                    defer clause_arg_vals.deinit();
                    const pat = try patternToCtValue(alloc, interner, store, clause.pattern);
                    const pat_list = try makeListWithTemporaryChildren(alloc, store, &.{pat});
                    try clause_arg_vals.append(pat_list);
                    const clause_body = try blockToCtValue(alloc, interner, store, clause.body);
                    try clause_arg_vals.append(clause_body);
                    const clause_args = try clause_arg_vals.toCtList();
                    var clause_owner = TemporaryCtValueOwner.init(alloc, store);
                    defer clause_owner.deinit();
                    try clause_owner.adopt(clause_args);
                    const clause_meta = try emptyList(alloc, store);
                    try clause_owner.adopt(clause_meta);
                    try clause_vals.append(try makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "->" }, clause_meta, clause_args, &clause_owner));
                }
                break :blk try clause_vals.toCtList();
            } else CtValue.nil;
            try kw_vals.append(try makeKeywordPair(alloc, store, "else", else_val));
            const kw_list = try kw_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(kw_list);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "with" }, meta, kw_list, &owner);
        },
        .cond_expr => |v| {
            // {:cond, meta, [do: [clauses...]]} where each clause is {:->, [], [[condition], body]}
            var clause_vals = TemporaryCtValueList.init(alloc, store);
            defer clause_vals.deinit();
            for (v.clauses) |clause| {
                var clause_arg_vals = TemporaryCtValueList.init(alloc, store);
                defer clause_arg_vals.deinit();
                const cond = try exprToCtValue(alloc, interner, store, clause.condition);
                const cond_list = try makeListWithTemporaryChildren(alloc, store, &.{cond});
                try clause_arg_vals.append(cond_list);
                try clause_arg_vals.append(try blockToCtValue(alloc, interner, store, clause.body));
                const clause_args = try clause_arg_vals.toCtList();
                var clause_owner = TemporaryCtValueOwner.init(alloc, store);
                defer clause_owner.deinit();
                try clause_owner.adopt(clause_args);
                const clause_meta = try emptyList(alloc, store);
                try clause_owner.adopt(clause_meta);
                try clause_vals.append(try makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "->" }, clause_meta, clause_args, &clause_owner));
            }
            const clauses_list = try clause_vals.toCtList();
            const do_pair = try makeKeywordPair(alloc, store, "do", clauses_list);
            const kw_list = try makeListWithTemporaryChildren(alloc, store, &.{do_pair});
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(kw_list);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "cond" }, meta, kw_list, &owner);
        },
        .receive_expr => |v| {
            // {:receive, meta, [message_type, [clauses...], after]} where each
            // clause is {:->, [], [[pattern], body]} and `after` is nil or the
            // list [duration, body].
            var clause_vals = TemporaryCtValueList.init(alloc, store);
            defer clause_vals.deinit();
            for (v.clauses) |clause| {
                try clause_vals.append(try caseClauseToCtValue(alloc, interner, store, clause));
            }
            const clauses_list = try clause_vals.toCtList();

            const after_val: CtValue = if (v.after) |after| after_blk: {
                var after_vals = TemporaryCtValueList.init(alloc, store);
                defer after_vals.deinit();
                try after_vals.append(try exprToCtValue(alloc, interner, store, after.duration));
                try after_vals.append(try blockToCtValue(alloc, interner, store, after.body));
                break :after_blk try after_vals.toCtList();
            } else CtValue.nil;

            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try typeExprToCtValue(alloc, interner, store, v.message_type));
            try arg_vals.append(clauses_list);
            try arg_vals.append(after_val);
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "receive" }, meta, args, &owner);
        },
        .attr_ref => |v| {
            const name: CtValue = .{ .atom = interner.get(v.name) };
            const args = try makeListWithTemporaryChildren(alloc, store, &.{name});
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "@" }, meta, args, &owner);
        },
        .binary_literal => |v| {
            var seg_vals = TemporaryCtValueList.init(alloc, store);
            defer seg_vals.deinit();
            for (v.segments) |seg| {
                const val = switch (seg.value) {
                    .expr => |e| try exprToCtValue(alloc, interner, store, e),
                    .pattern => |p| try patternToCtValue(alloc, interner, store, p),
                    .string_literal => |s| try makeTuple3WithTemporaryChildren(alloc, store, .{ .string = interner.get(s) }, try emptyList(alloc, store), .nil),
                };
                try seg_vals.append(val);
            }
            const args = try seg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "<<>>" }, meta, args, &owner);
        },
        .function_ref => |v| {
            const name: CtValue = .{ .atom = interner.get(v.function) };
            const arity: CtValue = .{ .int = @intCast(v.arity) };
            const args = try makeListWithTemporaryChildren(alloc, store, &.{ name, arity });
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "&" }, meta, args, &owner);
        },

        // For comprehension: {:for, meta, [var_pattern, iterable, filter_or_nil, body]}
        // var_pattern is the full Pattern serialization — supports tuple
        // destructure (`{k, v}`), tagged tuples (`{:ok, n}`), cons heads,
        // wildcards, etc. — going through the same patternToCtValue helper
        // that case-arms and function params use.
        .for_expr => |v| {
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try patternToCtValue(alloc, interner, store, v.var_pattern));
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.iterable));
            try arg_vals.append(if (v.filter) |f| try exprToCtValue(alloc, interner, store, f) else CtValue.nil);
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.body));
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "for" }, meta, args, &owner);
        },

        // Range: {:.., meta, [start, end, step_or_nil]}
        .range => |v| {
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.start));
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.end));
            try arg_vals.append(if (v.step) |s| try exprToCtValue(alloc, interner, store, s) else CtValue.nil);
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = ".." }, meta, args, &owner);
        },

        // List cons expression: {:cons, meta, [head, tail]}
        .list_cons_expr => |v| {
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.head));
            try arg_vals.append(try exprToCtValue(alloc, interner, store, v.tail));
            const args = try arg_vals.toCtList();
            var owner = TemporaryCtValueOwner.init(alloc, store);
            defer owner.deinit();
            try owner.adopt(args);
            const meta = try metaToList(alloc, store, v.meta, null);
            try owner.adopt(meta);
            return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "cons" }, meta, args, &owner);
        },

        // Poison sentinel (Phase 4.b): a parse-error placeholder. Reflected as
        // `{:__poison__, meta, nil}` so a `quote`/macro round-trip stays
        // well-formed; it never reaches a real compile (the program already
        // failed parsing).
        .poison => |v| return makeTuple3WithTemporaryChildren(alloc, store, .{ .atom = "__poison__" }, try metaToList(alloc, store, v.meta, null), .nil),
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
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try patternToCtValue(alloc, interner, store, a.pattern));
            try arg_vals.append(try exprToCtValue(alloc, interner, store, a.value));
            const args = try arg_vals.toCtList();
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "=" }, args);
        },
        .function_decl => |f| return functionDeclToCtValue(alloc, interner, store, f),
        .macro_decl => |m| {
            const fn_ct = try functionDeclToCtValue(alloc, interner, store, m);
            if (fn_ct == .tuple and fn_ct.tuple.elems.len == 3) {
                @constCast(fn_ct.tuple.elems)[0] = .{ .atom = "macro" };
            }
            return fn_ct;
        },
        .import_decl => |id| {
            var parts = TemporaryCtValueList.init(alloc, store);
            defer parts.deinit();
            for (id.struct_path.parts) |part| {
                try parts.append(CtValue{ .atom = interner.get(part) });
            }
            const aliases_args = try parts.toCtList();
            const aliases = try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "__aliases__" }, aliases_args);
            const args = try makeListWithTemporaryChildren(alloc, store, &.{aliases});
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "import" }, args);
        },
        .attribute => |attr| return attributeDeclToCtValue(alloc, interner, store, attr),
    };
}

fn attributeDeclToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    attr: *const ast.AttributeDecl,
) error{OutOfMemory}!CtValue {
    const name: CtValue = .{ .atom = interner.get(attr.name) };
    var arg_vals = TemporaryCtValueList.init(alloc, store);
    defer arg_vals.deinit();
    try arg_vals.append(name);
    if (attr.value) |val| {
        try arg_vals.append(try exprToCtValue(alloc, interner, store, val));
    }
    const args = try arg_vals.toCtList();
    return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "@" }, args);
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
    const pattern_list = try makeListWithTemporaryChildren(alloc, store, &.{pat_val});

    // Body
    var arg_vals = TemporaryCtValueList.init(alloc, store);
    defer arg_vals.deinit();
    try arg_vals.append(pattern_list);
    const body = try blockToCtValue(alloc, interner, store, clause.body);
    try arg_vals.append(body);

    const args = try arg_vals.toCtList();
    return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "->" }, args);
}

/// Convert a pattern to CtValue.
pub fn patternToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    pattern: *const ast.Pattern,
) error{OutOfMemory}!CtValue {
    return switch (pattern.*) {
        .wildcard => |v| makeTuple3WithTemporaryChildren(alloc, store, .{ .atom = "_" }, try metaToList(alloc, store, v.meta, null), .nil),
        .bind => |v| makeTuple3WithTemporaryChildren(alloc, store, .{ .atom = interner.get(v.name) }, try metaToList(alloc, store, v.meta, null), .nil),
        .literal => |v| switch (v) {
            .int => |lit| makeTuple3WithTemporaryChildren(alloc, store, .{ .int = lit.value }, try metaToList(alloc, store, lit.meta, null), .nil),
            .float => |lit| makeTuple3WithTemporaryChildren(alloc, store, .{ .float = lit.value }, try metaToList(alloc, store, lit.meta, null), .nil),
            .string => |lit| makeTuple3WithTemporaryChildren(alloc, store, .{ .string = interner.get(lit.value) }, try metaToList(alloc, store, lit.meta, null), .nil),
            .atom => |lit| makeTuple3WithTemporaryChildren(alloc, store, .{ .atom = interner.get(lit.value) }, try metaToList(alloc, store, lit.meta, null), .nil),
            .bool_lit => |lit| makeTuple3WithTemporaryChildren(alloc, store, .{ .bool_val = lit.value }, try metaToList(alloc, store, lit.meta, null), .nil),
            .nil => |lit| makeTuple3WithTemporaryChildren(alloc, store, .nil, try metaToList(alloc, store, lit.meta, null), .nil),
        },
        .pin => |v| {
            const name_val: CtValue = .{ .atom = interner.get(v.name) };
            const args = try makeListWithTemporaryChildren(alloc, store, &.{name_val});
            return makeTuple3WithNodeMetaAndArgs(alloc, store, .{ .atom = "^" }, v.meta, args);
        },
        .tuple => |v| {
            var elems = TemporaryCtValueList.init(alloc, store);
            defer elems.deinit();
            for (v.elements) |elem| {
                try elems.append(try patternToCtValue(alloc, interner, store, elem));
            }
            const args = try elems.toCtList();
            return makeTuple3WithNodeMetaAndArgs(alloc, store, .{ .atom = "{}" }, v.meta, args);
        },
        .list => |v| {
            var elems = TemporaryCtValueList.init(alloc, store);
            defer elems.deinit();
            for (v.elements) |elem| {
                try elems.append(try patternToCtValue(alloc, interner, store, elem));
            }
            return elems.toCtList();
        },
        .list_cons => |v| {
            var head_vals = TemporaryCtValueList.init(alloc, store);
            defer head_vals.deinit();
            for (v.heads) |h| {
                try head_vals.append(try patternToCtValue(alloc, interner, store, h));
            }
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try head_vals.toCtList());
            try arg_vals.append(try patternToCtValue(alloc, interner, store, v.tail));
            const args = try arg_vals.toCtList();
            return makeTuple3WithNodeMetaAndArgs(alloc, store, .{ .atom = "|" }, v.meta, args);
        },
        .struct_pattern => |v| {
            // {:%, meta, [struct_name, {:%{}, [], [field_pairs...]}]}
            var parts = TemporaryCtValueList.init(alloc, store);
            defer parts.deinit();
            for (v.struct_name.parts) |part| {
                try parts.append(CtValue{ .atom = interner.get(part) });
            }
            const name_args = try parts.toCtList();
            const name_val = try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "__aliases__" }, name_args);
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(name_val);

            var field_vals = TemporaryCtValueList.init(alloc, store);
            defer field_vals.deinit();
            for (v.fields) |field| {
                const fname: CtValue = .{ .atom = interner.get(field.name) };
                const fpat = try patternToCtValue(alloc, interner, store, field.pattern);
                try field_vals.append(try makeTuple2WithTemporaryChildren(alloc, store, fname, fpat));
            }
            const field_args = try field_vals.toCtList();
            const map_node = try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "%{}" }, field_args);
            try arg_vals.append(map_node);
            const args = try arg_vals.toCtList();
            return makeTuple3WithNodeMetaAndArgs(alloc, store, .{ .atom = "%" }, v.meta, args);
        },
        .map => |v| {
            // {:%{}, meta, [field_pairs...]}
            var field_vals = TemporaryCtValueList.init(alloc, store);
            defer field_vals.deinit();
            for (v.fields) |field| {
                var field_owner = TemporaryCtValueOwner.init(alloc, store);
                defer field_owner.deinit();
                const key = try exprToCtValue(alloc, interner, store, field.key);
                try field_owner.adopt(key);
                const val = try patternToCtValue(alloc, interner, store, field.value);
                try field_owner.adopt(val);
                const pair = try makeTuple2(alloc, store, key, val);
                field_owner.release();
                try field_vals.append(pair);
            }
            const args = try field_vals.toCtList();
            return makeTuple3WithNodeMetaAndArgs(alloc, store, .{ .atom = "%{}" }, v.meta, args);
        },
        .paren => |v| patternToCtValue(alloc, interner, store, v.inner),
        .tagged_union_variant => |v| {
            // Encode as {:variant, meta, [qualifier_aliases, payload_pattern_or_nil]}.
            // The CtValue surface is consumed by quote/unquote and intentionally
            // mirrors Elixir's Macro.escape shape — qualifier becomes an
            // `__aliases__` list, payload becomes the destructuring pattern or
            // nil for nullary variants. Type-args are omitted from the CtValue
            // surface (they're irrelevant to AST-walking macros).
            var parts = TemporaryCtValueList.init(alloc, store);
            defer parts.deinit();
            for (v.qualifier.parts) |part| {
                try parts.append(CtValue{ .atom = interner.get(part) });
            }
            const alias_args = try parts.toCtList();
            const aliases = try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "__aliases__" }, alias_args);
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(aliases);
            const payload_val: CtValue = if (v.payload) |p|
                try patternToCtValue(alloc, interner, store, p)
            else
                .nil;
            try arg_vals.append(payload_val);
            const args = try arg_vals.toCtList();
            return makeTuple3WithNodeMetaAndArgs(alloc, store, .{ .atom = "variant" }, v.meta, args);
        },
        .binary => |v| {
            // {:<<>>, meta, [segments...]} — simplified representation
            var seg_vals = TemporaryCtValueList.init(alloc, store);
            defer seg_vals.deinit();
            for (v.segments) |seg| {
                const val = switch (seg.value) {
                    .pattern => |p| try patternToCtValue(alloc, interner, store, p),
                    .expr => |e| try exprToCtValue(alloc, interner, store, e),
                    .string_literal => |s| try makeTuple3WithTemporaryChildren(alloc, store, .{ .string = interner.get(s) }, try emptyList(alloc, store), .nil),
                };
                try seg_vals.append(val);
            }
            const args = try seg_vals.toCtList();
            return makeTuple3WithNodeMetaAndArgs(alloc, store, .{ .atom = "<<>>" }, v.meta, args);
        },
    };
}

// ============================================================
// Helper functions
// ============================================================

/// Build a 3-tuple CtValue.
pub fn makeTuple3(alloc: Allocator, store: *AllocationStore, form: CtValue, meta: CtValue, args: CtValue) !CtValue {
    const elems = try alloc.alloc(CtValue, 3);
    errdefer if (elems.len > 0) alloc.free(elems);
    elems[0] = form;
    elems[1] = meta;
    elems[2] = args;
    const id = try store.alloc(alloc, .tuple, null);
    return .{ .tuple = .{ .alloc_id = id, .elems = elems } };
}

/// Build a 2-tuple CtValue (for keyword pairs, map entries).
pub fn makeTuple2(alloc: Allocator, store: *AllocationStore, first: CtValue, second: CtValue) !CtValue {
    const elems = try alloc.alloc(CtValue, 2);
    errdefer if (elems.len > 0) alloc.free(elems);
    elems[0] = first;
    elems[1] = second;
    const id = try store.alloc(alloc, .tuple, null);
    return .{ .tuple = .{ .alloc_id = id, .elems = elems } };
}

/// Build a CtValue list from inline items.
pub fn makeList(alloc: Allocator, store: *AllocationStore, items: []const CtValue) !CtValue {
    const elems = try alloc.alloc(CtValue, items.len);
    errdefer if (elems.len > 0) alloc.free(elems);
    @memcpy(elems, items);
    const id = try store.alloc(alloc, .list, null);
    return .{ .list = .{ .alloc_id = id, .elems = elems } };
}

/// Build a CtValue list from a slice.
pub fn makeListFromSlice(alloc: Allocator, store: *AllocationStore, items: []const CtValue) !CtValue {
    const elems = try alloc.alloc(CtValue, items.len);
    errdefer if (elems.len > 0) alloc.free(elems);
    @memcpy(elems, items);
    const id = try store.alloc(alloc, .list, null);
    return .{ .list = .{ .alloc_id = id, .elems = elems } };
}

/// Build an empty list.
pub fn emptyList(alloc: Allocator, store: *AllocationStore) !CtValue {
    return makeList(alloc, store, &.{});
}

/// Build a keyword pair: {atom, value} as a 2-tuple.
fn makeKeywordPair(alloc: Allocator, store: *AllocationStore, key: []const u8, value: CtValue) !CtValue {
    return makeTuple2WithTemporaryChildren(alloc, store, .{ .atom = key }, value);
}

fn prefixedAtomLiteralName(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    name: []const u8,
) Allocator.Error![]const u8 {
    const prefixed = try std.fmt.allocPrint(alloc, ":{s}", .{name});
    defer alloc.free(prefixed);
    const interned_id = try @constCast(interner).intern(prefixed);
    return interner.get(interned_id);
}

fn takeTemporaryCtAllocation(store: *AllocationStore, alloc_id: AllocId) bool {
    if (alloc_id == 0) return false;
    for (store.records.items) |*record| {
        if (record.id == alloc_id) {
            record.id = 0;
            return true;
        }
    }
    return false;
}

fn deinitTemporaryCtValueSlice(alloc: Allocator, store: *AllocationStore, values: []const CtValue) void {
    for (values) |value| {
        deinitTemporaryCtValue(alloc, store, value);
    }
}

fn deinitTemporaryCtMapEntries(alloc: Allocator, store: *AllocationStore, entries: []const CtValue.CtMapEntry) void {
    for (entries) |entry| {
        deinitTemporaryCtValue(alloc, store, entry.key);
        deinitTemporaryCtValue(alloc, store, entry.value);
    }
}

fn deinitTemporaryCtFieldValues(alloc: Allocator, store: *AllocationStore, fields: []const CtValue.CtFieldValue) void {
    for (fields) |field| {
        deinitTemporaryCtValue(alloc, store, field.value);
    }
}

fn deinitTemporaryCtValue(alloc: Allocator, store: *AllocationStore, value: CtValue) void {
    switch (value) {
        .tuple => |tuple_value| {
            if (!takeTemporaryCtAllocation(store, tuple_value.alloc_id)) return;
            deinitTemporaryCtValueSlice(alloc, store, tuple_value.elems);
            if (tuple_value.elems.len > 0) alloc.free(tuple_value.elems);
        },
        .list => |list_value| {
            if (!takeTemporaryCtAllocation(store, list_value.alloc_id)) return;
            deinitTemporaryCtValueSlice(alloc, store, list_value.elems);
            if (list_value.elems.len > 0) alloc.free(list_value.elems);
        },
        .map => |map_value| {
            if (!takeTemporaryCtAllocation(store, map_value.alloc_id)) return;
            deinitTemporaryCtMapEntries(alloc, store, map_value.entries);
            if (map_value.entries.len > 0) alloc.free(map_value.entries);
        },
        .struct_val => |struct_value| {
            if (!takeTemporaryCtAllocation(store, struct_value.alloc_id)) return;
            deinitTemporaryCtFieldValues(alloc, store, struct_value.fields);
            if (struct_value.fields.len > 0) alloc.free(struct_value.fields);
        },
        .union_val => |union_value| {
            if (!takeTemporaryCtAllocation(store, union_value.alloc_id)) return;
            deinitTemporaryCtValue(alloc, store, union_value.payload.*);
            alloc.destroy(@constCast(union_value.payload));
        },
        .closure => |closure_value| {
            if (!takeTemporaryCtAllocation(store, closure_value.alloc_id)) return;
            deinitTemporaryCtValueSlice(alloc, store, closure_value.captures);
            if (closure_value.captures.len > 0) alloc.free(closure_value.captures);
        },
        .int,
        .float,
        .string,
        .bool_val,
        .atom,
        .nil,
        .void,
        .consumed,
        .reuse_token,
        .enum_val,
        .optional,
        => {},
    }
}

fn appendTemporaryCtValue(
    alloc: Allocator,
    store: *AllocationStore,
    values: *std.ArrayListUnmanaged(CtValue),
    value: CtValue,
) !void {
    errdefer deinitTemporaryCtValue(alloc, store, value);
    try values.append(alloc, value);
}

fn makeTuple3WithTemporaryChildren(
    alloc: Allocator,
    store: *AllocationStore,
    form: CtValue,
    meta: CtValue,
    args: CtValue,
) !CtValue {
    const children = [_]CtValue{ form, meta, args };
    var children_transferred = false;
    errdefer if (!children_transferred) deinitTemporaryCtValueSlice(alloc, store, &children);
    const tuple = try makeTuple3(alloc, store, form, meta, args);
    children_transferred = true;
    return tuple;
}

fn makeTuple2WithTemporaryChildren(
    alloc: Allocator,
    store: *AllocationStore,
    first: CtValue,
    second: CtValue,
) !CtValue {
    const children = [_]CtValue{ first, second };
    var children_transferred = false;
    errdefer if (!children_transferred) deinitTemporaryCtValueSlice(alloc, store, &children);
    const tuple = try makeTuple2(alloc, store, first, second);
    children_transferred = true;
    return tuple;
}

fn makeListWithTemporaryChildren(
    alloc: Allocator,
    store: *AllocationStore,
    items: []const CtValue,
) !CtValue {
    var children_transferred = false;
    errdefer if (!children_transferred) deinitTemporaryCtValueSlice(alloc, store, items);
    const list = try makeList(alloc, store, items);
    children_transferred = true;
    return list;
}

const TemporaryCtValueList = struct {
    allocator: Allocator,
    store: *AllocationStore,
    values: std.ArrayListUnmanaged(CtValue) = .empty,
    owns_values: bool = true,

    fn init(allocator: Allocator, store: *AllocationStore) TemporaryCtValueList {
        return .{ .allocator = allocator, .store = store };
    }

    fn append(self: *TemporaryCtValueList, value: CtValue) Allocator.Error!void {
        errdefer deinitTemporaryCtValue(self.allocator, self.store, value);
        try self.values.append(self.allocator, value);
    }

    fn toCtList(self: *TemporaryCtValueList) Allocator.Error!CtValue {
        const list = try makeListFromSlice(self.allocator, self.store, self.values.items);
        self.owns_values = false;
        return list;
    }

    fn takeOnly(self: *TemporaryCtValueList) CtValue {
        std.debug.assert(self.values.items.len == 1);
        self.owns_values = false;
        return self.values.items[0];
    }

    fn releaseValues(self: *TemporaryCtValueList) void {
        self.owns_values = false;
    }

    fn deinit(self: *TemporaryCtValueList) void {
        if (self.owns_values) {
            deinitTemporaryCtValueSlice(self.allocator, self.store, self.values.items);
        }
        self.values.deinit(self.allocator);
    }
};

const TemporaryCtValueOwner = struct {
    allocator: Allocator,
    store: *AllocationStore,
    roots: std.ArrayListUnmanaged(CtValue) = .empty,
    owns_values: bool = true,

    fn init(allocator: Allocator, store: *AllocationStore) TemporaryCtValueOwner {
        return .{ .allocator = allocator, .store = store };
    }

    fn adopt(self: *TemporaryCtValueOwner, value: CtValue) Allocator.Error!void {
        errdefer deinitTemporaryCtValue(self.allocator, self.store, value);
        try self.roots.append(self.allocator, value);
    }

    fn release(self: *TemporaryCtValueOwner) void {
        self.owns_values = false;
    }

    fn deinit(self: *TemporaryCtValueOwner) void {
        if (self.owns_values) {
            deinitTemporaryCtValueSlice(self.allocator, self.store, self.roots.items);
        }
        self.roots.deinit(self.allocator);
    }
};

fn makeTuple3WithOwnedChildren(
    alloc: Allocator,
    store: *AllocationStore,
    form: CtValue,
    meta: CtValue,
    args: CtValue,
    owner: *TemporaryCtValueOwner,
) !CtValue {
    const tuple = try makeTuple3(alloc, store, form, meta, args);
    owner.release();
    return tuple;
}

fn makeTuple3WithNodeMetaAndArgs(
    alloc: Allocator,
    store: *AllocationStore,
    form: CtValue,
    node_meta: ast.NodeMeta,
    args: CtValue,
) !CtValue {
    var owner = TemporaryCtValueOwner.init(alloc, store);
    defer owner.deinit();
    try owner.adopt(args);
    const meta = try metaToList(alloc, store, node_meta, null);
    try owner.adopt(meta);
    return makeTuple3WithOwnedChildren(alloc, store, form, meta, args, &owner);
}

fn makeTuple3WithEmptyMetaAndArgs(
    alloc: Allocator,
    store: *AllocationStore,
    form: CtValue,
    args: CtValue,
) !CtValue {
    var owner = TemporaryCtValueOwner.init(alloc, store);
    defer owner.deinit();
    try owner.adopt(args);
    const meta = try emptyList(alloc, store);
    try owner.adopt(meta);
    return makeTuple3WithOwnedChildren(alloc, store, form, meta, args, &owner);
}

/// Convert NodeMeta to a keyword list CtValue.
fn metaToList(alloc: Allocator, store: *AllocationStore, meta: ast.NodeMeta, type_name: ?[]const u8) !CtValue {
    var pairs = TemporaryCtValueList.init(alloc, store);
    defer pairs.deinit();
    try appendMetaKeywordPairs(alloc, store, &pairs, meta, type_name);
    return pairs.toCtList();
}

fn appendMetaKeywordPairs(
    alloc: Allocator,
    store: *AllocationStore,
    pairs: *TemporaryCtValueList,
    meta: ast.NodeMeta,
    type_name: ?[]const u8,
) !void {
    // Encode start/end so the original byte-offset span survives round
    // trips through CtValue. Without this, the reverse conversion in
    // `keywordListToMeta` zeroes the offsets and any error reported on
    // the rehydrated AST points at line 1 col 0 instead of the source.
    if (meta.span.start > 0) {
        try pairs.append(try makeKeywordPair(alloc, store, "start", .{ .int = @intCast(meta.span.start) }));
    }
    if (meta.span.end > 0) {
        try pairs.append(try makeKeywordPair(alloc, store, "end", .{ .int = @intCast(meta.span.end) }));
    }
    if (meta.span.line > 0) {
        try pairs.append(try makeKeywordPair(alloc, store, "line", .{ .int = @intCast(meta.span.line) }));
    }
    if (meta.span.col > 0) {
        try pairs.append(try makeKeywordPair(alloc, store, "col", .{ .int = @intCast(meta.span.col) }));
    }
    if (meta.span.source_id) |sid| {
        try pairs.append(try makeKeywordPair(alloc, store, "source_id", .{ .int = @intCast(sid) }));
    }
    // Encode the hygiene scope set so identifiers carry their Flatt-2016
    // scope marks across `quote { ... unquote(...) ... }` round trips.
    // The set is encoded as a list of int ScopeIds — the sorted-array
    // invariant is preserved on the wire because `meta.scopes.slice()`
    // returns the underlying sorted storage. An empty set is omitted so
    // pre-hygiene CtValues stay byte-identical with the previous encoding.
    if (!meta.scopes.isEmpty()) {
        const ids = meta.scopes.slice();
        var scope_vals = TemporaryCtValueList.init(alloc, store);
        defer scope_vals.deinit();
        for (ids) |scope_id| {
            try scope_vals.append(.{ .int = @intCast(scope_id) });
        }
        const scopes_list = try scope_vals.toCtList();
        const scopes_pair = try makeKeywordPair(alloc, store, "scopes", scopes_list);
        try pairs.append(scopes_pair);
    }
    if (type_name) |tn| {
        try pairs.append(try makeKeywordPair(alloc, store, "type", .{ .atom = tn }));
    }
}

/// Build the meta-list for an `__aliases__` (struct_ref) CtValue
/// node, appending a `type_args` keyword when the source struct_ref
/// carries parametric type arguments (`Option(i64).Some` etc.). The
/// base meta encoding (`metaToList`) covers span/line/scopes; this
/// helper layers the type-args list on top so a single helper still
/// owns the meta shape and the encoder's struct_ref arm stays a
/// one-call site. Decoded back by `ctValueToExpr` for `__aliases__`.
fn structRefMetaWithTypeArgs(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    meta: ast.NodeMeta,
    type_args: []const *const ast.TypeExpr,
) error{OutOfMemory}!CtValue {
    if (type_args.len == 0) return metaToList(alloc, store, meta, null);

    var pairs = TemporaryCtValueList.init(alloc, store);
    defer pairs.deinit();
    try appendMetaKeywordPairs(alloc, store, &pairs, meta, null);

    // Build the type-args list — each element is a CtValue
    // representation of a TypeExpr (round-trippable via
    // `typeExprToCtValue` / `ctValueToTypeExpr`).
    var arg_vals = TemporaryCtValueList.init(alloc, store);
    defer arg_vals.deinit();
    for (type_args) |arg| {
        try arg_vals.append(try typeExprToCtValue(alloc, interner, store, arg));
    }
    const args_list = try arg_vals.toCtList();
    try pairs.append(try makeKeywordPair(alloc, store, "type_args", args_list));
    return pairs.toCtList();
}

/// Build the meta-list for a `%` (struct_expr) CtValue node, layering
/// the instantiation-site `type_args` (e.g. `i64` in `%Box(i64){...}`)
/// and the `type_args_parens_present` flag on top of the base meta so
/// both round-trip through quote/unquote. Without this, quoting a body
/// that contains a parametric struct literal dropped the type
/// arguments, and the rehydrated `%Adapter{...}` typed as the bare
/// generic head instead of `Adapter(i64)` — starving monomorphization
/// of the concrete instantiation (the Zest macro engine hit this when
/// quoting test bodies driving parametric `Enumerable` adapters through
/// `Enum`). The parens flag is emitted only for the explicit
/// empty-parens `%Box(){...}` arity-error shape; a non-empty
/// `type_args` implies parens on decode. Decoded back by
/// `ctValueToExpr` for the `%` form.
fn structExprMetaWithTypeArgs(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    meta: ast.NodeMeta,
    type_args: []const *const ast.TypeExpr,
    type_args_parens_present: bool,
) error{OutOfMemory}!CtValue {
    if (type_args.len == 0 and !type_args_parens_present) {
        return metaToList(alloc, store, meta, null);
    }

    var pairs = TemporaryCtValueList.init(alloc, store);
    defer pairs.deinit();
    try appendMetaKeywordPairs(alloc, store, &pairs, meta, null);

    if (type_args.len > 0) {
        var arg_vals = TemporaryCtValueList.init(alloc, store);
        defer arg_vals.deinit();
        for (type_args) |arg| {
            try arg_vals.append(try typeExprToCtValue(alloc, interner, store, arg));
        }
        const args_list = try arg_vals.toCtList();
        try pairs.append(try makeKeywordPair(alloc, store, "type_args", args_list));
    }
    // Only the explicit-empty-parens form (`%Box(){...}`, an arity
    // error against a parametric declaration) needs the marker; the
    // `type_args`-bearing form implies parens on decode, so we omit it
    // there to keep the common `%Box(i64){...}` encoding minimal.
    if (type_args_parens_present and type_args.len == 0) {
        try pairs.append(try makeKeywordPair(alloc, store, "type_args_parens", .{ .bool_val = true }));
    }
    return pairs.toCtList();
}

/// Read the `type_args_parens` boolean keyword the struct_expr encoder
/// stashes on the meta list (see `structExprMetaWithTypeArgs`). Returns
/// true only for the explicit-empty-parens `%Box(){...}` shape; the
/// common `%Box{...}` form omits the marker, and the
/// `type_args`-bearing `%Box(i64){...}` form recovers the flag from a
/// non-empty decoded `type_args` at the call site.
fn structExprParensFlagFromMeta(meta_value: CtValue) bool {
    if (meta_value != .list) return false;
    for (meta_value.list.elems) |pair| {
        if (pair != .tuple or pair.tuple.elems.len != 2) continue;
        const key = pair.tuple.elems[0];
        if (key != .atom) continue;
        if (!std.mem.eql(u8, key.atom, "type_args_parens")) continue;
        const flag = pair.tuple.elems[1];
        if (flag == .bool_val) return flag.bool_val;
    }
    return false;
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
    var vals = TemporaryCtValueList.init(alloc, store);
    defer vals.deinit();
    for (stmts) |stmt| {
        try vals.append(try stmtToCtValue(alloc, interner, store, stmt));
    }
    const args = try vals.toCtList();
    return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "__block__" }, args);
}

fn paramsToCtList(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    params: []const ast.Param,
) error{OutOfMemory}!CtValue {
    var vals = TemporaryCtValueList.init(alloc, store);
    defer vals.deinit();
    for (params) |param| {
        const pat = try patternToCtValue(alloc, interner, store, param.pattern);
        if (param.type_annotation) |type_expr| {
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(pat);
            try arg_vals.append(try typeExprToCtValue(alloc, interner, store, type_expr));
            const args = try arg_vals.toCtList();
            try vals.append(try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "::" }, args));
        } else {
            try vals.append(pat);
        }
    }
    return vals.toCtList();
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
            const args = try makeListWithTemporaryChildren(alloc, store, &.{ obj, field });
            return makeTuple3WithNodeMetaAndArgs(alloc, store, .{ .atom = "." }, v.meta, args);
        },
        .struct_ref => {
            // Encode the callee struct_ref through `exprToCtValue`
            // (which uses `structRefMetaWithTypeArgs` to round-trip
            // parametric variant constructors like
            // `Option(i64).Some(42)`). The previous direct
            // construction here dropped the struct_ref's type_args,
            // forcing the macro engine to re-encode parametric
            // variants as a 1-part `__aliases__` without the type-
            // arg payload — the test-mode Option(i64).Some(...) ->
            // Nil regression.
            return exprToCtValue(alloc, interner, store, callee);
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
        .not_in_op => "not in",
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

/// Decode an `{:__aliases__, meta, [:Part1, :Part2, ...]}` CtValue
/// 3-tuple back into a `.struct_ref` AST node, reconstructing any
/// parametric `type_args` the encoder stashed on the meta keyword
/// list (see `structRefMetaWithTypeArgs`). Shared by the two decode
/// sites that can encounter an `__aliases__` form: a bare struct
/// reference (`Option(i64).None`) and a parametric variant
/// constructor used as a *call callee* (`Option(i64).Some(42)`,
/// whose call form slot holds this very 3-tuple). `aliases_tuple`
/// MUST be a 3-tuple whose first element is the `__aliases__` atom.
fn structRefTypeArgsFromMetaBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    meta_value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError![]const *const ast.TypeExpr {
    if (meta_value != .list) return &.{};

    for (meta_value.list.elems) |pair| {
        if (pair != .tuple or pair.tuple.elems.len != 2) continue;
        const key = pair.tuple.elems[0];
        if (key != .atom) continue;
        if (!std.mem.eql(u8, key.atom, "type_args")) continue;
        const args_val = pair.tuple.elems[1];
        if (args_val != .list) continue;

        var decoded = DecodedTypeExprList.init(alloc);
        defer decoded.deinit();
        for (args_val.list.elems) |arg_ct| {
            try decoded.append(try ctValueToTypeExprBudgeted(alloc, interner, arg_ct, budget));
        }
        return decoded.takeOwnedSlice();
    }

    return &.{};
}

fn aliasesTupleToStructRef(
    alloc: Allocator,
    interner: *ast.StringInterner,
    aliases_tuple: CtValue,
    node_meta: ast.NodeMeta,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!*const ast.Expr {
    try budget.enter();
    defer budget.leave();

    const elems = aliases_tuple.tuple.elems;
    const meta_value = elems[1];
    const args_value = elems[2];

    var parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
    defer parts.deinit(alloc);
    if (args_value == .list) {
        for (args_value.list.elems) |elem| {
            if (elem == .atom) {
                try parts.append(alloc, try interner.intern(elem.atom));
            }
        }
    }

    // Decode parametric type-args from the meta keyword list, mirroring
    // the bare-`__aliases__` decode arm in `ctValueToExpr`.
    const owned_meta = node_meta;
    errdefer deinitDecodedMeta(alloc, owned_meta);

    const type_args = try structRefTypeArgsFromMetaBudgeted(alloc, interner, meta_value, budget);
    errdefer deinitDecodedTypeExprSlice(alloc, type_args);

    const expr = try alloc.create(ast.Expr);
    errdefer alloc.destroy(expr);
    const name_parts = try parts.toOwnedSlice(alloc);
    errdefer freeDecodedSlice(alloc, name_parts);

    expr.* = .{ .struct_ref = .{
        .meta = owned_meta,
        .name = .{ .parts = name_parts, .span = owned_meta.span },
        .type_args = type_args,
    } };
    return expr;
}

/// Convert a CtValue 3-tuple back to an ast.Expr.
pub fn ctValueToExpr(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) CtValueDecodeError!*const ast.Expr {
    var budget = CtValueDecodeBudget.default();
    return ctValueToExprBudgeted(alloc, interner, value, &budget);
}

fn deinitDecodedExpr(alloc: Allocator, expr: *const ast.Expr) void {
    const mutable = @constCast(expr);
    switch (mutable.*) {
        .int_literal => |literal| deinitDecodedMeta(alloc, literal.meta),
        .float_literal => |literal| deinitDecodedMeta(alloc, literal.meta),
        .string_literal => |literal| deinitDecodedMeta(alloc, literal.meta),
        .string_interpolation => |interpolation| {
            deinitDecodedStringPartSlice(alloc, interpolation.parts);
            deinitDecodedMeta(alloc, interpolation.meta);
        },
        .atom_literal => |literal| deinitDecodedMeta(alloc, literal.meta),
        .bool_literal => |literal| deinitDecodedMeta(alloc, literal.meta),
        .nil_literal => |literal| deinitDecodedMeta(alloc, literal.meta),
        .var_ref => |var_ref| deinitDecodedMeta(alloc, var_ref.meta),
        .struct_ref => |struct_ref| {
            deinitDecodedStructName(alloc, struct_ref.name);
            deinitDecodedTypeExprSlice(alloc, struct_ref.type_args);
            deinitDecodedMeta(alloc, struct_ref.meta);
        },
        .tuple => |tuple| {
            deinitDecodedExprSlice(alloc, tuple.elements);
            deinitDecodedMeta(alloc, tuple.meta);
        },
        .list => |list| {
            deinitDecodedExprSlice(alloc, list.elements);
            deinitDecodedMeta(alloc, list.meta);
        },
        .map => |map| {
            if (map.update_source) |update_source| deinitDecodedExpr(alloc, update_source);
            deinitDecodedMapFieldSlice(alloc, map.fields);
            deinitDecodedMeta(alloc, map.meta);
        },
        .struct_expr => |struct_expr| {
            deinitDecodedStructName(alloc, struct_expr.struct_name);
            deinitDecodedTypeExprSlice(alloc, struct_expr.type_args);
            if (struct_expr.update_source) |update_source| deinitDecodedExpr(alloc, update_source);
            deinitDecodedStructFieldSlice(alloc, struct_expr.fields);
            deinitDecodedMeta(alloc, struct_expr.meta);
        },
        .range => |range| {
            deinitDecodedExpr(alloc, range.start);
            deinitDecodedExpr(alloc, range.end);
            if (range.step) |step| deinitDecodedExpr(alloc, step);
            deinitDecodedMeta(alloc, range.meta);
        },
        .binary_op => |binary| {
            deinitDecodedExpr(alloc, binary.lhs);
            deinitDecodedExpr(alloc, binary.rhs);
            deinitDecodedMeta(alloc, binary.meta);
        },
        .unary_op => |unary| {
            deinitDecodedExpr(alloc, unary.operand);
            deinitDecodedMeta(alloc, unary.meta);
        },
        .call => |call| {
            deinitDecodedExpr(alloc, call.callee);
            deinitDecodedExprSlice(alloc, call.args);
            deinitDecodedMeta(alloc, call.meta);
        },
        .field_access => |field_access| {
            deinitDecodedExpr(alloc, field_access.object);
            deinitDecodedMeta(alloc, field_access.meta);
        },
        .pipe => |pipe| {
            deinitDecodedExpr(alloc, pipe.lhs);
            deinitDecodedExpr(alloc, pipe.rhs);
            deinitDecodedMeta(alloc, pipe.meta);
        },
        .unwrap => |unwrap| {
            deinitDecodedExpr(alloc, unwrap.expr);
            deinitDecodedMeta(alloc, unwrap.meta);
        },
        .if_expr => |if_expr| {
            deinitDecodedExpr(alloc, if_expr.condition);
            deinitDecodedStmtSlice(alloc, if_expr.then_block);
            if (if_expr.else_block) |else_block| deinitDecodedStmtSlice(alloc, else_block);
            deinitDecodedMeta(alloc, if_expr.meta);
        },
        .case_expr => |case_expr| {
            deinitDecodedExpr(alloc, case_expr.scrutinee);
            deinitDecodedCaseClauseSlice(alloc, case_expr.clauses);
            deinitDecodedMeta(alloc, case_expr.meta);
        },
        .cond_expr => |cond_expr| {
            deinitDecodedCondClauseSlice(alloc, cond_expr.clauses);
            deinitDecodedMeta(alloc, cond_expr.meta);
        },
        .receive_expr => |receive_expr| {
            deinitDecodedTypeExpr(alloc, receive_expr.message_type);
            deinitDecodedCaseClauseSlice(alloc, receive_expr.clauses);
            if (receive_expr.after) |after| {
                deinitDecodedExpr(alloc, after.duration);
                deinitDecodedStmtSlice(alloc, after.body);
            }
            deinitDecodedMeta(alloc, receive_expr.meta);
        },
        .for_expr => |for_expr| {
            deinitDecodedPattern(alloc, for_expr.var_pattern);
            if (for_expr.var_type_annotation) |type_annotation| deinitDecodedTypeExpr(alloc, type_annotation);
            deinitDecodedExpr(alloc, for_expr.iterable);
            if (for_expr.filter) |filter| deinitDecodedExpr(alloc, filter);
            deinitDecodedExpr(alloc, for_expr.body);
            deinitDecodedMeta(alloc, for_expr.meta);
        },
        .with_expr => |with_expr| {
            deinitDecodedWithStepSlice(alloc, with_expr.steps);
            deinitDecodedStmtSlice(alloc, with_expr.do_body);
            if (with_expr.else_clauses) |else_clauses| deinitDecodedCaseClauseSlice(alloc, else_clauses);
            deinitDecodedMeta(alloc, with_expr.meta);
        },
        .list_cons_expr => |list_cons| {
            deinitDecodedExpr(alloc, list_cons.head);
            deinitDecodedExpr(alloc, list_cons.tail);
            deinitDecodedMeta(alloc, list_cons.meta);
        },
        .quote_expr => |quote| {
            deinitDecodedStmtSlice(alloc, quote.body);
            deinitDecodedMeta(alloc, quote.meta);
        },
        .unquote_expr => |unquote| {
            deinitDecodedExpr(alloc, unquote.expr);
            deinitDecodedMeta(alloc, unquote.meta);
        },
        .unquote_splicing_expr => |unquote_splicing| {
            deinitDecodedExpr(alloc, unquote_splicing.expr);
            deinitDecodedMeta(alloc, unquote_splicing.meta);
        },
        .panic_expr => |panic| {
            deinitDecodedExpr(alloc, panic.message);
            deinitDecodedMeta(alloc, panic.meta);
        },
        .raise_expr => |raise| {
            deinitDecodedExpr(alloc, raise.value);
            deinitDecodedMeta(alloc, raise.meta);
        },
        .error_pipe => |error_pipe| {
            deinitDecodedExpr(alloc, error_pipe.chain);
            switch (error_pipe.handler) {
                .block => |clauses| deinitDecodedCaseClauseSlice(alloc, clauses),
                .function => |handler| deinitDecodedExpr(alloc, handler),
            }
            deinitDecodedMeta(alloc, error_pipe.meta);
        },
        .try_rescue => |try_rescue| {
            deinitDecodedStmtSlice(alloc, try_rescue.body);
            deinitDecodedCaseClauseSlice(alloc, try_rescue.rescue_clauses);
            if (try_rescue.after_block) |after_block| deinitDecodedStmtSlice(alloc, after_block);
            deinitDecodedMeta(alloc, try_rescue.meta);
        },
        .block => |block| {
            deinitDecodedStmtSlice(alloc, block.stmts);
            deinitDecodedMeta(alloc, block.meta);
        },
        .intrinsic => |intrinsic| {
            deinitDecodedExprSlice(alloc, intrinsic.args);
            deinitDecodedMeta(alloc, intrinsic.meta);
        },
        .attr_ref => |attr_ref| deinitDecodedMeta(alloc, attr_ref.meta),
        .binary_literal => |binary_literal| {
            deinitDecodedBinarySegmentSlice(alloc, binary_literal.segments);
            deinitDecodedMeta(alloc, binary_literal.meta);
        },
        .function_ref => |function_ref| {
            if (function_ref.struct_name) |struct_name| deinitDecodedStructName(alloc, struct_name);
            deinitDecodedMeta(alloc, function_ref.meta);
        },
        .anonymous_function => |anonymous_function| {
            deinitDecodedFunctionDecl(alloc, anonymous_function.decl);
            deinitDecodedMeta(alloc, anonymous_function.meta);
        },
        .type_annotated => |type_annotated| {
            deinitDecodedExpr(alloc, type_annotated.expr);
            deinitDecodedTypeExpr(alloc, type_annotated.type_expr);
            deinitDecodedMeta(alloc, type_annotated.meta);
        },
        .poison => |poison| deinitDecodedMeta(alloc, poison.meta),
    }
    alloc.destroy(mutable);
}

fn deinitDecodedStmt(alloc: Allocator, stmt: ast.Stmt) void {
    switch (stmt) {
        .expr => |expr| deinitDecodedExpr(alloc, expr),
        .assignment => |assignment| deinitDecodedAssignment(alloc, assignment),
        .function_decl, .macro_decl => |decl| deinitDecodedFunctionDecl(alloc, decl),
        .import_decl => |decl| deinitDecodedImportDecl(alloc, decl),
        .attribute => |decl| deinitDecodedAttributeDecl(alloc, decl),
    }
}

fn deinitDecodedAssignment(alloc: Allocator, assignment: *const ast.Assignment) void {
    const mutable = @constCast(assignment);
    deinitDecodedPattern(alloc, mutable.pattern);
    deinitDecodedExpr(alloc, mutable.value);
    deinitDecodedMeta(alloc, mutable.meta);
    alloc.destroy(mutable);
}

fn deinitDecodedPattern(alloc: Allocator, pattern: *const ast.Pattern) void {
    const mutable = @constCast(pattern);
    switch (mutable.*) {
        .wildcard => |wildcard| deinitDecodedMeta(alloc, wildcard.meta),
        .bind => |bind| deinitDecodedMeta(alloc, bind.meta),
        .literal => |literal| deinitDecodedLiteralPattern(alloc, literal),
        .tuple => |tuple| {
            deinitDecodedPatternSlice(alloc, tuple.elements);
            deinitDecodedMeta(alloc, tuple.meta);
        },
        .list => |list| {
            deinitDecodedPatternSlice(alloc, list.elements);
            deinitDecodedMeta(alloc, list.meta);
        },
        .list_cons => |list_cons| {
            deinitDecodedPatternSlice(alloc, list_cons.heads);
            deinitDecodedPattern(alloc, list_cons.tail);
            deinitDecodedMeta(alloc, list_cons.meta);
        },
        .map => |map| {
            deinitDecodedMapPatternFieldSlice(alloc, map.fields);
            deinitDecodedMeta(alloc, map.meta);
        },
        .struct_pattern => |struct_pattern| {
            deinitDecodedStructName(alloc, struct_pattern.struct_name);
            deinitDecodedStructPatternFieldSlice(alloc, struct_pattern.fields);
            deinitDecodedMeta(alloc, struct_pattern.meta);
        },
        .pin => |pin| deinitDecodedMeta(alloc, pin.meta),
        .paren => |paren| {
            deinitDecodedPattern(alloc, paren.inner);
            deinitDecodedMeta(alloc, paren.meta);
        },
        .binary => |binary| {
            deinitDecodedBinarySegmentSlice(alloc, binary.segments);
            deinitDecodedMeta(alloc, binary.meta);
        },
        .tagged_union_variant => |variant| {
            deinitDecodedStructName(alloc, variant.qualifier);
            deinitDecodedTypeExprSlice(alloc, variant.type_args);
            if (variant.payload) |payload| deinitDecodedPattern(alloc, payload);
            deinitDecodedMeta(alloc, variant.meta);
        },
    }
    alloc.destroy(mutable);
}

fn deinitDecodedLiteralPattern(alloc: Allocator, literal: ast.LiteralPattern) void {
    switch (literal) {
        .int => |value| deinitDecodedMeta(alloc, value.meta),
        .float => |value| deinitDecodedMeta(alloc, value.meta),
        .string => |value| deinitDecodedMeta(alloc, value.meta),
        .atom => |value| deinitDecodedMeta(alloc, value.meta),
        .bool_lit => |value| deinitDecodedMeta(alloc, value.meta),
        .nil => |value| deinitDecodedMeta(alloc, value.meta),
    }
}

fn deinitDecodedTypeExpr(alloc: Allocator, type_expr: *const ast.TypeExpr) void {
    const mutable = @constCast(type_expr);
    switch (mutable.*) {
        .name => |name| {
            deinitDecodedTypeExprSlice(alloc, name.args);
            deinitDecodedMeta(alloc, name.meta);
        },
        .variable => |variable| deinitDecodedMeta(alloc, variable.meta),
        .tuple => |tuple| {
            deinitDecodedTypeExprSlice(alloc, tuple.elements);
            deinitDecodedMeta(alloc, tuple.meta);
        },
        .list => |list| {
            deinitDecodedTypeExpr(alloc, list.element);
            deinitDecodedMeta(alloc, list.meta);
        },
        .map => |map| {
            deinitDecodedTypeMapFieldSlice(alloc, map.fields);
            deinitDecodedMeta(alloc, map.meta);
        },
        .struct_type => |struct_type| {
            deinitDecodedStructName(alloc, struct_type.struct_name);
            deinitDecodedTypeStructFieldSlice(alloc, struct_type.fields);
            deinitDecodedMeta(alloc, struct_type.meta);
        },
        .union_type => |union_type| {
            deinitDecodedTypeExprSlice(alloc, union_type.members);
            deinitDecodedMeta(alloc, union_type.meta);
        },
        .function => |function| {
            deinitDecodedTypeExprSlice(alloc, function.params);
            freeDecodedSlice(alloc, function.param_ownerships);
            freeDecodedSlice(alloc, function.param_ownerships_explicit);
            deinitDecodedTypeExpr(alloc, function.return_type);
            deinitDecodedMeta(alloc, function.meta);
        },
        .literal => |literal| deinitDecodedMeta(alloc, literal.meta),
        .never => |never| deinitDecodedMeta(alloc, never.meta),
        .paren => |paren| {
            deinitDecodedTypeExpr(alloc, paren.inner);
            deinitDecodedMeta(alloc, paren.meta);
        },
    }
    alloc.destroy(mutable);
}

fn deinitDecodedCaseClause(alloc: Allocator, clause: ast.CaseClause) void {
    deinitDecodedPattern(alloc, clause.pattern);
    if (clause.type_annotation) |type_annotation| deinitDecodedTypeExpr(alloc, type_annotation);
    if (clause.guard) |guard| deinitDecodedExpr(alloc, guard);
    deinitDecodedStmtSlice(alloc, clause.body);
    deinitDecodedMeta(alloc, clause.meta);
}

fn deinitDecodedCondClause(alloc: Allocator, clause: ast.CondClause) void {
    deinitDecodedExpr(alloc, clause.condition);
    deinitDecodedStmtSlice(alloc, clause.body);
    deinitDecodedMeta(alloc, clause.meta);
}

fn deinitDecodedWithStep(alloc: Allocator, step: ast.WithStep) void {
    deinitDecodedPattern(alloc, step.pattern);
    if (step.type_annotation) |type_annotation| deinitDecodedTypeExpr(alloc, type_annotation);
    deinitDecodedExpr(alloc, step.expr);
    deinitDecodedMeta(alloc, step.meta);
}

fn deinitDecodedParam(alloc: Allocator, param: ast.Param) void {
    deinitDecodedPattern(alloc, param.pattern);
    if (param.type_annotation) |type_annotation| deinitDecodedTypeExpr(alloc, type_annotation);
    if (param.default) |default| deinitDecodedExpr(alloc, default);
    deinitDecodedMeta(alloc, param.meta);
}

fn deinitDecodedFunctionDecl(alloc: Allocator, decl: *const ast.FunctionDecl) void {
    const mutable = @constCast(decl);
    if (mutable.name_expr) |name_expr| deinitDecodedExpr(alloc, name_expr);
    deinitDecodedFunctionClauseSlice(alloc, mutable.clauses);
    deinitDecodedMeta(alloc, mutable.meta);
    alloc.destroy(mutable);
}

fn deinitDecodedFunctionClause(alloc: Allocator, clause: ast.FunctionClause) void {
    deinitDecodedParamSlice(alloc, clause.params);
    if (clause.return_type) |return_type| deinitDecodedTypeExpr(alloc, return_type);
    if (clause.refinement) |refinement| deinitDecodedExpr(alloc, refinement);
    if (clause.body) |body| deinitDecodedStmtSlice(alloc, body);
    if (clause.raises) |raises| deinitDecodedTypeExprSlice(alloc, raises);
    deinitDecodedMeta(alloc, clause.meta);
}

fn deinitDecodedStructItem(alloc: Allocator, item: ast.StructItem) void {
    switch (item) {
        .type_decl => |decl| deinitDecodedTypeDecl(alloc, decl),
        .opaque_decl => |decl| deinitDecodedOpaqueDecl(alloc, decl),
        .struct_decl => |decl| deinitDecodedStructDecl(alloc, decl),
        .union_decl => |decl| deinitDecodedUnionDecl(alloc, decl),
        .function, .priv_function, .macro, .priv_macro => |decl| deinitDecodedFunctionDecl(alloc, decl),
        .alias_decl => |decl| deinitDecodedAliasDecl(alloc, decl),
        .import_decl => |decl| deinitDecodedImportDecl(alloc, decl),
        .use_decl => |decl| deinitDecodedUseDecl(alloc, decl),
        .attribute => |decl| deinitDecodedAttributeDecl(alloc, decl),
        .struct_level_expr => |expr| deinitDecodedExpr(alloc, expr),
    }
}

fn deinitDecodedTypeDecl(alloc: Allocator, decl: *const ast.TypeDecl) void {
    const mutable = @constCast(decl);
    deinitDecodedTypeParamSlice(alloc, mutable.params);
    deinitDecodedTypeExpr(alloc, mutable.body);
    deinitDecodedMeta(alloc, mutable.meta);
    alloc.destroy(mutable);
}

fn deinitDecodedOpaqueDecl(alloc: Allocator, decl: *const ast.OpaqueDecl) void {
    const mutable = @constCast(decl);
    deinitDecodedTypeParamSlice(alloc, mutable.params);
    deinitDecodedTypeExpr(alloc, mutable.body);
    deinitDecodedMeta(alloc, mutable.meta);
    alloc.destroy(mutable);
}

fn deinitDecodedStructDecl(alloc: Allocator, decl: *const ast.StructDecl) void {
    const mutable = @constCast(decl);
    deinitDecodedStructName(alloc, mutable.name);
    freeDecodedSlice(alloc, mutable.type_params);
    deinitDecodedStructItemSlice(alloc, mutable.items);
    deinitDecodedStructFieldDeclSlice(alloc, mutable.fields);
    deinitDecodedMeta(alloc, mutable.meta);
    alloc.destroy(mutable);
}

fn deinitDecodedUnionDecl(alloc: Allocator, decl: *const ast.UnionDecl) void {
    const mutable = @constCast(decl);
    freeDecodedSlice(alloc, mutable.type_params);
    deinitDecodedUnionVariantSlice(alloc, mutable.variants);
    deinitDecodedMeta(alloc, mutable.meta);
    alloc.destroy(mutable);
}

fn deinitDecodedAliasDecl(alloc: Allocator, decl: *const ast.AliasDecl) void {
    const mutable = @constCast(decl);
    deinitDecodedStructName(alloc, mutable.struct_path);
    if (mutable.as_name) |as_name| deinitDecodedStructName(alloc, as_name);
    deinitDecodedMeta(alloc, mutable.meta);
    alloc.destroy(mutable);
}

fn deinitDecodedImportDecl(alloc: Allocator, decl: *const ast.ImportDecl) void {
    const mutable = @constCast(decl);
    deinitDecodedStructName(alloc, mutable.struct_path);
    if (mutable.filter) |filter| deinitDecodedImportFilter(alloc, filter);
    deinitDecodedMeta(alloc, mutable.meta);
    alloc.destroy(mutable);
}

fn deinitDecodedUseDecl(alloc: Allocator, decl: *const ast.UseDecl) void {
    const mutable = @constCast(decl);
    deinitDecodedStructName(alloc, mutable.struct_path);
    if (mutable.opts) |opts| deinitDecodedExpr(alloc, opts);
    deinitDecodedMeta(alloc, mutable.meta);
    alloc.destroy(mutable);
}

fn deinitDecodedAttributeDecl(alloc: Allocator, decl: *const ast.AttributeDecl) void {
    const mutable = @constCast(decl);
    if (mutable.type_expr) |type_expr| deinitDecodedTypeExpr(alloc, type_expr);
    if (mutable.value) |value| deinitDecodedExpr(alloc, value);
    deinitDecodedMeta(alloc, mutable.meta);
    alloc.destroy(mutable);
}

fn deinitDecodedImportFilter(alloc: Allocator, filter: ast.ImportFilter) void {
    switch (filter) {
        .only => |entries| freeDecodedSlice(alloc, entries),
        .except => |entries| freeDecodedSlice(alloc, entries),
    }
}

fn deinitDecodedMapField(alloc: Allocator, field: ast.MapField) void {
    deinitDecodedExpr(alloc, field.key);
    deinitDecodedExpr(alloc, field.value);
}

fn deinitDecodedStringPart(alloc: Allocator, part: ast.StringPart) void {
    switch (part) {
        .literal => {},
        .expr => |expr| deinitDecodedExpr(alloc, expr),
    }
}

fn deinitDecodedStructField(alloc: Allocator, field: ast.StructField) void {
    deinitDecodedExpr(alloc, field.value);
}

fn deinitDecodedMapPatternField(alloc: Allocator, field: ast.MapPatternField) void {
    deinitDecodedExpr(alloc, field.key);
    deinitDecodedPattern(alloc, field.value);
}

fn deinitDecodedStructPatternField(alloc: Allocator, field: ast.StructPatternField) void {
    deinitDecodedPattern(alloc, field.pattern);
}

fn deinitDecodedTypeMapField(alloc: Allocator, field: ast.TypeMapField) void {
    deinitDecodedTypeExpr(alloc, field.key);
    deinitDecodedTypeExpr(alloc, field.value);
}

fn deinitDecodedTypeStructField(alloc: Allocator, field: ast.TypeStructField) void {
    deinitDecodedTypeExpr(alloc, field.type_expr);
}

fn deinitDecodedStructFieldDecl(alloc: Allocator, field: ast.StructFieldDecl) void {
    deinitDecodedTypeExpr(alloc, field.type_expr);
    if (field.default) |default| deinitDecodedExpr(alloc, default);
    deinitDecodedMeta(alloc, field.meta);
}

fn deinitDecodedUnionVariant(alloc: Allocator, variant: ast.UnionVariant) void {
    if (variant.type_expr) |type_expr| deinitDecodedTypeExpr(alloc, type_expr);
    deinitDecodedMeta(alloc, variant.meta);
}

fn deinitDecodedTypeParam(alloc: Allocator, type_param: ast.TypeParam) void {
    deinitDecodedMeta(alloc, type_param.meta);
}

fn deinitDecodedBinarySegment(alloc: Allocator, segment: ast.BinarySegment) void {
    switch (segment.value) {
        .expr => |expr| deinitDecodedExpr(alloc, expr),
        .pattern => |pattern| deinitDecodedPattern(alloc, pattern),
        .string_literal => {},
    }
    deinitDecodedMeta(alloc, segment.meta);
}

fn deinitDecodedMeta(alloc: Allocator, meta: ast.NodeMeta) void {
    var mutable = meta;
    mutable.scopes.deinit(alloc);
}

fn cloneDecodedMeta(alloc: Allocator, meta: ast.NodeMeta) Allocator.Error!ast.NodeMeta {
    var cloned = meta;
    cloned.scopes = try meta.scopes.clone(alloc);
    return cloned;
}

fn deinitDecodedStructName(alloc: Allocator, name: ast.StructName) void {
    freeDecodedSlice(alloc, name.parts);
}

fn freeDecodedSlice(alloc: Allocator, slice: anytype) void {
    if (slice.len != 0) alloc.free(slice);
}

fn deinitDecodedExprSlice(alloc: Allocator, slice: []const *const ast.Expr) void {
    for (slice) |item| deinitDecodedExpr(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedStmtSlice(alloc: Allocator, slice: []const ast.Stmt) void {
    for (slice) |item| deinitDecodedStmt(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedPatternSlice(alloc: Allocator, slice: []const *const ast.Pattern) void {
    for (slice) |item| deinitDecodedPattern(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedTypeExprSlice(alloc: Allocator, slice: []const *const ast.TypeExpr) void {
    for (slice) |item| deinitDecodedTypeExpr(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedMapFieldSlice(alloc: Allocator, slice: []const ast.MapField) void {
    for (slice) |item| deinitDecodedMapField(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedStringPartSlice(alloc: Allocator, slice: []const ast.StringPart) void {
    for (slice) |item| deinitDecodedStringPart(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedStructFieldSlice(alloc: Allocator, slice: []const ast.StructField) void {
    for (slice) |item| deinitDecodedStructField(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedCaseClauseSlice(alloc: Allocator, slice: []const ast.CaseClause) void {
    for (slice) |item| deinitDecodedCaseClause(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedCondClauseSlice(alloc: Allocator, slice: []const ast.CondClause) void {
    for (slice) |item| deinitDecodedCondClause(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedWithStepSlice(alloc: Allocator, slice: []const ast.WithStep) void {
    for (slice) |item| deinitDecodedWithStep(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedMapPatternFieldSlice(alloc: Allocator, slice: []const ast.MapPatternField) void {
    for (slice) |item| deinitDecodedMapPatternField(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedStructPatternFieldSlice(alloc: Allocator, slice: []const ast.StructPatternField) void {
    for (slice) |item| deinitDecodedStructPatternField(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedBinarySegmentSlice(alloc: Allocator, slice: []const ast.BinarySegment) void {
    for (slice) |item| deinitDecodedBinarySegment(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedTypeMapFieldSlice(alloc: Allocator, slice: []const ast.TypeMapField) void {
    for (slice) |item| deinitDecodedTypeMapField(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedTypeStructFieldSlice(alloc: Allocator, slice: []const ast.TypeStructField) void {
    for (slice) |item| deinitDecodedTypeStructField(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedParamSlice(alloc: Allocator, slice: []const ast.Param) void {
    for (slice) |item| deinitDecodedParam(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedFunctionClauseSlice(alloc: Allocator, slice: []const ast.FunctionClause) void {
    for (slice) |item| deinitDecodedFunctionClause(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedStructItemSlice(alloc: Allocator, slice: []const ast.StructItem) void {
    for (slice) |item| deinitDecodedStructItem(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedStructFieldDeclSlice(alloc: Allocator, slice: []const ast.StructFieldDecl) void {
    for (slice) |item| deinitDecodedStructFieldDecl(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedUnionVariantSlice(alloc: Allocator, slice: []const ast.UnionVariant) void {
    for (slice) |item| deinitDecodedUnionVariant(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn deinitDecodedTypeParamSlice(alloc: Allocator, slice: []const ast.TypeParam) void {
    for (slice) |item| deinitDecodedTypeParam(alloc, item);
    freeDecodedSlice(alloc, slice);
}

fn DecodedListGuard(comptime T: type, comptime deinitItem: fn (Allocator, T) void) type {
    return struct {
        allocator: Allocator,
        items: std.ArrayListUnmanaged(T) = .empty,
        active: bool = true,

        const Self = @This();

        fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *Self) void {
            if (self.active) {
                for (self.items.items) |item| deinitItem(self.allocator, item);
            }
            self.items.deinit(self.allocator);
        }

        fn append(self: *Self, item: T) Allocator.Error!void {
            var transferred = false;
            errdefer if (!transferred) deinitItem(self.allocator, item);
            try self.items.append(self.allocator, item);
            transferred = true;
        }

        fn takeOwnedSlice(self: *Self) Allocator.Error![]const T {
            const slice = try self.items.toOwnedSlice(self.allocator);
            self.active = false;
            return slice;
        }
    };
}

const DecodedExprList = DecodedListGuard(*const ast.Expr, deinitDecodedExpr);
const DecodedStmtList = DecodedListGuard(ast.Stmt, deinitDecodedStmt);
const DecodedPatternList = DecodedListGuard(*const ast.Pattern, deinitDecodedPattern);
const DecodedTypeExprList = DecodedListGuard(*const ast.TypeExpr, deinitDecodedTypeExpr);
const DecodedMapFieldList = DecodedListGuard(ast.MapField, deinitDecodedMapField);
const DecodedStringPartList = DecodedListGuard(ast.StringPart, deinitDecodedStringPart);
const DecodedStructFieldList = DecodedListGuard(ast.StructField, deinitDecodedStructField);
const DecodedCaseClauseList = DecodedListGuard(ast.CaseClause, deinitDecodedCaseClause);
const DecodedCondClauseList = DecodedListGuard(ast.CondClause, deinitDecodedCondClause);
const DecodedMapPatternFieldList = DecodedListGuard(ast.MapPatternField, deinitDecodedMapPatternField);
const DecodedStructPatternFieldList = DecodedListGuard(ast.StructPatternField, deinitDecodedStructPatternField);
const DecodedTypeMapFieldList = DecodedListGuard(ast.TypeMapField, deinitDecodedTypeMapField);
const DecodedParamList = DecodedListGuard(ast.Param, deinitDecodedParam);
const DecodedFunctionClauseList = DecodedListGuard(ast.FunctionClause, deinitDecodedFunctionClause);
const DecodedStructFieldDeclList = DecodedListGuard(ast.StructFieldDecl, deinitDecodedStructFieldDecl);
const DecodedUnionVariantList = DecodedListGuard(ast.UnionVariant, deinitDecodedUnionVariant);

fn decodedMapFieldBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    key_value: CtValue,
    value_value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.MapField {
    const key = try ctValueToExprBudgeted(alloc, interner, key_value, budget);
    errdefer deinitDecodedExpr(alloc, key);
    const value = try ctValueToExprBudgeted(alloc, interner, value_value, budget);
    errdefer deinitDecodedExpr(alloc, value);
    return .{ .key = key, .value = value };
}

fn decodedStructFieldBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    name_value: CtValue,
    value_value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.StructField {
    if (name_value != .atom) return error.InvalidCtValueShape;
    const name = try interner.intern(name_value.atom);
    const value = try ctValueToExprBudgeted(alloc, interner, value_value, budget);
    errdefer deinitDecodedExpr(alloc, value);
    return .{ .name = name, .value = value };
}

fn decodedCondClauseBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    node_meta: ast.NodeMeta,
    condition_value: CtValue,
    body_value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.CondClause {
    const clause_meta = try cloneDecodedMeta(alloc, node_meta);
    errdefer deinitDecodedMeta(alloc, clause_meta);
    const condition = try ctValueToExprBudgeted(alloc, interner, condition_value, budget);
    errdefer deinitDecodedExpr(alloc, condition);
    const body = try ctValueToStmtsBudgeted(alloc, interner, body_value, budget);
    errdefer deinitDecodedStmtSlice(alloc, body);
    return .{ .meta = clause_meta, .condition = condition, .body = body };
}

fn decodedBindParamBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    node_meta: ast.NodeMeta,
    name: []const u8,
    type_value: ?CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.Param {
    const name_id = try interner.intern(name);
    const pattern_meta = try cloneDecodedMeta(alloc, node_meta);
    var pattern_meta_owned = true;
    errdefer if (pattern_meta_owned) deinitDecodedMeta(alloc, pattern_meta);
    const pattern = try alloc.create(ast.Pattern);
    pattern.* = .{ .bind = .{ .meta = pattern_meta, .name = name_id } };
    pattern_meta_owned = false;
    errdefer deinitDecodedPattern(alloc, pattern);

    const type_annotation = if (type_value) |ct_type|
        try ctValueToTypeExprBudgeted(alloc, interner, ct_type, budget)
    else
        null;
    errdefer if (type_annotation) |type_expr| deinitDecodedTypeExpr(alloc, type_expr);

    const param_meta = try cloneDecodedMeta(alloc, node_meta);
    errdefer deinitDecodedMeta(alloc, param_meta);

    return .{
        .meta = param_meta,
        .pattern = pattern,
        .type_annotation = type_annotation,
    };
}

fn decodedStructPatternFieldBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    name_value: CtValue,
    pattern_value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.StructPatternField {
    if (name_value != .atom) return error.InvalidCtValueShape;
    const name = try interner.intern(name_value.atom);
    const pattern = try ctValueToPatternBudgeted(alloc, interner, pattern_value, budget);
    errdefer deinitDecodedPattern(alloc, pattern);
    return .{ .name = name, .pattern = pattern };
}

fn decodedMapPatternFieldBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    key_value: CtValue,
    pattern_value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.MapPatternField {
    const key = try ctValueToExprBudgeted(alloc, interner, key_value, budget);
    errdefer deinitDecodedExpr(alloc, key);
    const value_pattern = try ctValueToPatternBudgeted(alloc, interner, pattern_value, budget);
    errdefer deinitDecodedPattern(alloc, value_pattern);
    return .{ .key = key, .value = value_pattern };
}

fn decodedTypeMapFieldBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    key_value: CtValue,
    value_value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.TypeMapField {
    const key = try ctValueToTypeExprBudgeted(alloc, interner, key_value, budget);
    errdefer deinitDecodedTypeExpr(alloc, key);
    const value = try ctValueToTypeExprBudgeted(alloc, interner, value_value, budget);
    errdefer deinitDecodedTypeExpr(alloc, value);
    return .{ .key = key, .value = value };
}

fn decodedStructFieldDeclBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    name_value: CtValue,
    type_value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.StructFieldDecl {
    if (name_value != .atom) return error.InvalidCtValueShape;
    const name = try interner.intern(name_value.atom);
    const type_expr = try ctValueToTypeExprBudgeted(alloc, interner, type_value, budget);
    errdefer deinitDecodedTypeExpr(alloc, type_expr);
    return .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = name,
        .type_expr = type_expr,
        .default = null,
    };
}

fn decodedUnionVariantBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    name_value: CtValue,
    type_value: ?CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.UnionVariant {
    if (name_value != .atom) return error.InvalidCtValueShape;
    const name = try interner.intern(name_value.atom);
    const type_expr = if (type_value) |value|
        try ctValueToTypeExprBudgeted(alloc, interner, value, budget)
    else
        null;
    errdefer if (type_expr) |expr| deinitDecodedTypeExpr(alloc, expr);
    return .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = name,
        .type_expr = type_expr,
    };
}

fn ctValueToExprBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!*const ast.Expr {
    try budget.enter();
    defer budget.leave();

    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    // A bare list represents a Zap list literal
    if (value == .list) {
        var elems = DecodedExprList.init(alloc);
        defer elems.deinit();
        for (value.list.elems) |elem| {
            try elems.append(try ctValueToExprBudgeted(alloc, interner, elem, budget));
        }
        const expr = try alloc.create(ast.Expr);
        errdefer alloc.destroy(expr);
        const elements = try elems.takeOwnedSlice();
        expr.* = .{ .list = .{ .meta = meta, .elements = elements } };
        return expr;
    }

    // Bare primitive CtValues — convert directly to AST expressions.
    // This handles cases where macro-generated function bodies contain
    // bare strings, atoms, ints, etc. that are not wrapped in 3-tuples.
    if (value == .string) {
        const string_id = try interner.intern(value.string);
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .string_literal = .{ .meta = meta, .value = string_id } };
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
            const atom_id = try interner.intern(value.atom[1..]);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .atom_literal = .{ .meta = meta, .value = atom_id } };
            return expr;
        } else if (value.atom.len > 0 and (value.atom[0] == '_' or std.ascii.isLower(value.atom[0]))) {
            const name_id = try interner.intern(value.atom);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .var_ref = .{ .meta = meta, .name = name_id } };
            return expr;
        }
    }
    if (value == .nil) {
        const expr = try alloc.create(ast.Expr);
        expr.* = .{ .nil_literal = .{ .meta = meta } };
        return expr;
    }

    // Bare map CtValue (typically the result of evaluating a `%{}` map
    // literal at macro expansion time, then unquoted into a runtime
    // function body). Reconstruct as an `ast.MapExpr` so the type checker
    // sees a normal map literal rather than falling back to `nil`.
    if (value == .map) {
        var fields = DecodedMapFieldList.init(alloc);
        defer fields.deinit();
        for (value.map.entries) |entry| {
            try fields.append(try decodedMapFieldBudgeted(alloc, interner, entry.key, entry.value, budget));
        }
        const expr = try alloc.create(ast.Expr);
        errdefer alloc.destroy(expr);
        const field_slice = try fields.takeOwnedSlice();
        expr.* = .{ .map = .{
            .meta = meta,
            .update_source = null,
            .fields = field_slice,
        } };
        return expr;
    }

    // Must be a 3-tuple: {form, metadata, args}
    if (value != .tuple or value.tuple.elems.len != 3) {
        return error.InvalidCtValueShape;
    }

    const form = value.tuple.elems[0];
    // metadata is value.tuple.elems[1] — we extract span/scopes from it
    const node_meta = try keywordListToMetaBudgeted(alloc, value.tuple.elems[1], budget);
    errdefer {
        var decoded_meta = node_meta;
        decoded_meta.scopes.deinit(alloc);
    }
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
                const string_id = try interner.intern(v);
                const expr = try alloc.create(ast.Expr);
                expr.* = .{ .string_literal = .{ .meta = node_meta, .value = string_id } };
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
                    const atom_id = try interner.intern(name[1..]);
                    const expr = try alloc.create(ast.Expr);
                    expr.* = .{ .atom_literal = .{ .meta = node_meta, .value = atom_id } };
                    break :blk expr;
                } else if (name.len > 0 and (name[0] == '_' or std.ascii.isLower(name[0]))) {
                    const name_id = try interner.intern(name);
                    const expr = try alloc.create(ast.Expr);
                    expr.* = .{ .var_ref = .{ .meta = node_meta, .name = name_id } };
                    break :blk expr;
                } else {
                    const atom_id = try interner.intern(name);
                    const expr = try alloc.create(ast.Expr);
                    expr.* = .{ .atom_literal = .{ .meta = node_meta, .value = atom_id } };
                    break :blk expr;
                }
            },
            else => error.InvalidCtValueShape,
        };
    }

    // Node with args: {form_atom, meta, args_list}
    if (form != .atom) {
        // Non-atom form — check for dot-call: {:., meta, [object, :field]}
        // This represents a qualified function call like Struct.func(args)
        if (form == .tuple and form.tuple.elems.len == 3) {
            const dot_form = form.tuple.elems[0];
            const dot_args = form.tuple.elems[2];
            if (dot_form == .atom and std.mem.eql(u8, dot_form.atom, ".") and dot_args == .list and dot_args.list.elems.len == 2) {
                // Reconstruct: object.field(args)
                const object = try ctValueToExprBudgeted(alloc, interner, dot_args.list.elems[0], budget);
                var object_owned = true;
                errdefer if (object_owned) deinitDecodedExpr(alloc, object);
                const field_name = try interner.intern(ctFieldName(dot_args.list.elems[1]) orelse "unknown");
                const callee_meta = try cloneDecodedMeta(alloc, node_meta);
                var callee_meta_owned = true;
                errdefer if (callee_meta_owned) deinitDecodedMeta(alloc, callee_meta);

                const callee = try alloc.create(ast.Expr);
                callee.* = .{ .field_access = .{ .meta = callee_meta, .object = object, .field = field_name } };
                object_owned = false;
                callee_meta_owned = false;
                errdefer deinitDecodedExpr(alloc, callee);

                // Build the call with the dot-access callee
                const arg_elems = if (args == .list) args.list.elems else &[_]CtValue{};
                var call_args = DecodedExprList.init(alloc);
                defer call_args.deinit();
                for (arg_elems) |arg| {
                    try call_args.append(try ctValueToExprBudgeted(alloc, interner, arg, budget));
                }

                const expr = try alloc.create(ast.Expr);
                errdefer alloc.destroy(expr);
                const call_args_slice = try call_args.takeOwnedSlice();
                expr.* = .{ .call = .{
                    .meta = node_meta,
                    .callee = callee,
                    .args = call_args_slice,
                } };
                return expr;
            }

            // Parametric variant constructor used as a call callee:
            // `Option(i64).Some(42)` parses to a `.call` whose callee
            // is a `struct_ref` (`name.parts = [Option, Some]`,
            // `type_args = [i64]`). The encoder turns that callee into
            // an `{:__aliases__, meta, [:Option, :Some]}` form tuple
            // sitting in the call's form slot. Reconstruct the
            // struct_ref callee (preserving `type_args`) and rebuild
            // the call. Without this the form fell through to the
            // `nil_literal` fallback below, collapsing the whole
            // construction to `nil` — the `zap test`
            // "argument 1 expects `Option({type_var})`, got `Nil`"
            // regression for quoted (Zest `test`/`describe`) bodies.
            if (dot_form == .atom and std.mem.eql(u8, dot_form.atom, "__aliases__")) {
                const callee_meta = try cloneDecodedMeta(alloc, node_meta);
                const callee = try aliasesTupleToStructRef(alloc, interner, form, callee_meta, budget);
                errdefer deinitDecodedExpr(alloc, callee);

                const arg_elems = if (args == .list) args.list.elems else &[_]CtValue{};
                var call_args = DecodedExprList.init(alloc);
                defer call_args.deinit();
                for (arg_elems) |arg| {
                    try call_args.append(try ctValueToExprBudgeted(alloc, interner, arg, budget));
                }

                const expr = try alloc.create(ast.Expr);
                errdefer alloc.destroy(expr);
                const call_args_slice = try call_args.takeOwnedSlice();
                expr.* = .{ .call = .{
                    .meta = node_meta,
                    .callee = callee,
                    .args = call_args_slice,
                } };
                return expr;
            }

            // Nested value-call callee — the form is itself a CALL node, e.g.
            // `f()(10)`: the encoder put the inner call `f()`
            // (`{:f, meta, []}`) in the OUTER call's form slot. Decode the
            // form 3-tuple recursively as a full expression (yielding the
            // inner `.call`/`.field_access`-callee call) and use it as the
            // outer call's callee. Without this, a nested value-call inside a
            // quoted (Zest `test`/`describe`/`case`) body fell through to the
            // `nil_literal` fallback below and the WHOLE value-call collapsed
            // to `nil` — the project-mode `r = f()(10)` → `r == N` "comparison
            // of comptime_int with null" / "expects i8, got Nil" gap. (The
            // `.` and `__aliases__` arms above are the special-cased callee
            // shapes; this is the general nested-call/expression callee.)
            const decoded_callee = try ctValueToExprBudgeted(alloc, interner, form, budget);
            errdefer deinitDecodedExpr(alloc, decoded_callee);
            const arg_elems = if (args == .list) args.list.elems else &[_]CtValue{};
            var call_args = DecodedExprList.init(alloc);
            defer call_args.deinit();
            for (arg_elems) |arg| {
                try call_args.append(try ctValueToExprBudgeted(alloc, interner, arg, budget));
            }
            const expr = try alloc.create(ast.Expr);
            errdefer alloc.destroy(expr);
            const call_args_slice = try call_args.takeOwnedSlice();
            expr.* = .{ .call = .{
                .meta = node_meta,
                .callee = decoded_callee,
                .args = call_args_slice,
            } };
            return expr;
        }

        return error.InvalidCtValueShape;
    }

    if (args != .list) return error.InvalidCtValueShape;

    const form_name = form.atom;
    const arg_elems = args.list.elems;

    // Binary operators
    if (stringToBinop(form_name)) |op| {
        if (arg_elems.len == 2) {
            const lhs = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            var lhs_transferred = false;
            errdefer if (!lhs_transferred) deinitDecodedExpr(alloc, lhs);
            const rhs = try ctValueToExprBudgeted(alloc, interner, arg_elems[1], budget);
            var rhs_transferred = false;
            errdefer if (!rhs_transferred) deinitDecodedExpr(alloc, rhs);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .binary_op = .{ .meta = node_meta, .op = op, .lhs = lhs, .rhs = rhs } };
            lhs_transferred = true;
            rhs_transferred = true;
            return expr;
        }
    }

    // Unary operators
    if (stringToUnop(form_name)) |op| {
        if (arg_elems.len == 1) {
            const operand = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, operand);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .unary_op = .{ .meta = node_meta, .op = op, .operand = operand } };
            return expr;
        }
    }

    // Special forms
    // Range expression: {:.., meta, [start, end, step_or_nil]}
    if (std.mem.eql(u8, form_name, "..")) {
        if (arg_elems.len >= 2) {
            const start = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, start);
            const end_val = try ctValueToExprBudgeted(alloc, interner, arg_elems[1], budget);
            errdefer deinitDecodedExpr(alloc, end_val);
            const step = if (arg_elems.len >= 3 and arg_elems[2] != .nil)
                try ctValueToExprBudgeted(alloc, interner, arg_elems[2], budget)
            else
                null;
            errdefer if (step) |step_expr| deinitDecodedExpr(alloc, step_expr);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .range = .{ .meta = node_meta, .start = start, .end = end_val, .step = step } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "__block__")) {
        var stmts = DecodedStmtList.init(alloc);
        defer stmts.deinit();
        for (arg_elems) |elem| {
            try stmts.append(try ctValueToStmtBudgeted(alloc, interner, elem, budget));
        }
        const expr = try alloc.create(ast.Expr);
        errdefer alloc.destroy(expr);
        const stmt_slice = try stmts.takeOwnedSlice();
        expr.* = .{ .block = .{ .meta = node_meta, .stmts = stmt_slice } };
        return expr;
    }

    if (std.mem.eql(u8, form_name, "{}")) {
        var elems = DecodedExprList.init(alloc);
        defer elems.deinit();
        for (arg_elems) |elem| {
            try elems.append(try ctValueToExprBudgeted(alloc, interner, elem, budget));
        }
        const expr = try alloc.create(ast.Expr);
        errdefer alloc.destroy(expr);
        const elements = try elems.takeOwnedSlice();
        expr.* = .{ .tuple = .{ .meta = node_meta, .elements = elements } };
        return expr;
    }

    if (std.mem.eql(u8, form_name, "%{}")) {
        var fields = DecodedMapFieldList.init(alloc);
        defer fields.deinit();
        for (arg_elems) |pair| {
            if (pair == .tuple and pair.tuple.elems.len == 2) {
                try fields.append(try decodedMapFieldBudgeted(alloc, interner, pair.tuple.elems[0], pair.tuple.elems[1], budget));
            }
        }
        const expr = try alloc.create(ast.Expr);
        errdefer alloc.destroy(expr);
        const field_slice = try fields.takeOwnedSlice();
        expr.* = .{ .map = .{ .meta = node_meta, .fields = field_slice } };
        return expr;
    }

    // Struct expression: {:%, meta, [name_list, {:%{}, [], [field_pairs...]}, update_or_nil]}
    if (std.mem.eql(u8, form_name, "%")) {
        if (arg_elems.len >= 2) {
            // arg_elems[0] = struct name parts (list of atoms)
            // arg_elems[1] = {:%{}, [], [field_pairs...]} (map node with fields)
            var name_parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
            defer name_parts.deinit(alloc);
            if (arg_elems[0] == .list) {
                for (arg_elems[0].list.elems) |elem| {
                    if (elem == .atom) {
                        try name_parts.append(alloc, try interner.intern(elem.atom));
                    }
                }
            }

            // Extract fields from the map node {:%{}, [], [field_pairs...]}
            var fields = DecodedStructFieldList.init(alloc);
            defer fields.deinit();
            const map_node = arg_elems[1];
            if (map_node == .tuple and map_node.tuple.elems.len >= 3) {
                const map_args = map_node.tuple.elems[2];
                if (map_args == .list) {
                    for (map_args.list.elems) |pair| {
                        if (pair == .tuple and pair.tuple.elems.len == 2) {
                            const key = pair.tuple.elems[0];
                            const val = pair.tuple.elems[1];
                            if (key == .atom) {
                                try fields.append(try decodedStructFieldBudgeted(alloc, interner, key, val, budget));
                            }
                        }
                    }
                }
            }

            // Restore update_source if present (3rd arg, non-nil)
            const update_source: ?*const ast.Expr = if (arg_elems.len >= 3 and arg_elems[2] != .nil)
                try ctValueToExprBudgeted(alloc, interner, arg_elems[2], budget)
            else
                null;
            errdefer if (update_source) |source| deinitDecodedExpr(alloc, source);

            // Restore the instantiation-site `type_args` and the
            // explicit-parens flag the encoder stashed on the meta
            // (see `structExprMetaWithTypeArgs`). Round-tripping without
            // this dropped `(i64)` from `%Adapter(i64){...}`, so the
            // rehydrated literal typed as the bare generic head and
            // starved monomorphization of the concrete instantiation.
            const type_args = try structRefTypeArgsFromMetaBudgeted(alloc, interner, value.tuple.elems[1], budget);
            errdefer deinitDecodedTypeExprSlice(alloc, type_args);
            const type_args_parens_present = type_args.len > 0 or structExprParensFlagFromMeta(value.tuple.elems[1]);

            const expr = try alloc.create(ast.Expr);
            errdefer alloc.destroy(expr);
            const name_part_slice = try name_parts.toOwnedSlice(alloc);
            errdefer freeDecodedSlice(alloc, name_part_slice);
            const field_slice = try fields.takeOwnedSlice();
            expr.* = .{ .struct_expr = .{
                .meta = node_meta,
                .struct_name = .{ .parts = name_part_slice, .span = node_meta.span },
                .update_source = update_source,
                .fields = field_slice,
                .type_args = type_args,
                .type_args_parens_present = type_args_parens_present,
            } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "|>")) {
        if (arg_elems.len == 2) {
            const lhs = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, lhs);
            const rhs = try ctValueToExprBudgeted(alloc, interner, arg_elems[1], budget);
            errdefer deinitDecodedExpr(alloc, rhs);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .pipe = .{ .meta = node_meta, .lhs = lhs, .rhs = rhs } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, ".")) {
        if (arg_elems.len == 2) {
            if (ctFieldName(arg_elems[1])) |field_name| {
                const obj = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
                errdefer deinitDecodedExpr(alloc, obj);
                const field = try interner.intern(field_name);
                const expr = try alloc.create(ast.Expr);
                expr.* = .{ .field_access = .{
                    .meta = node_meta,
                    .object = obj,
                    .field = field,
                } };
                return expr;
            }
        }
    }

    if (std.mem.eql(u8, form_name, "__aliases__")) {
        var parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
        defer parts.deinit(alloc);
        for (arg_elems) |elem| {
            if (elem == .atom) {
                try parts.append(alloc, try interner.intern(elem.atom));
            }
        }
        // Decode parametric type-args from the meta keyword list.
        // `exprToCtValue` for `.struct_ref` (in this file) encodes
        // non-empty `mr.type_args` as a `type_args: [...]` keyword
        // on the meta. Round-tripping through CtValue without this
        // dropped type-args for parametric variant constructors
        // (`Option(i64).Some(42)`) — the case the Zest macro engine
        // hit when quoting test bodies. Empty list when the meta
        // carries no `type_args` entry (the common case).
        const type_args = try structRefTypeArgsFromMetaBudgeted(alloc, interner, value.tuple.elems[1], budget);
        errdefer deinitDecodedTypeExprSlice(alloc, type_args);
        const expr = try alloc.create(ast.Expr);
        errdefer alloc.destroy(expr);
        const name_parts = try parts.toOwnedSlice(alloc);
        errdefer freeDecodedSlice(alloc, name_parts);
        expr.* = .{ .struct_ref = .{
            .meta = node_meta,
            .name = .{ .parts = name_parts, .span = node_meta.span },
            .type_args = type_args,
        } };
        return expr;
    }

    if (std.mem.eql(u8, form_name, "if")) {
        if (arg_elems.len == 2) {
            const cond = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, cond);
            const kw = arg_elems[1];
            var then_stmts: []const ast.Stmt = &.{};
            var then_stmts_owned = false;
            errdefer if (then_stmts_owned) deinitDecodedStmtSlice(alloc, then_stmts);
            var else_stmts: ?[]const ast.Stmt = null;
            var else_stmts_owned = false;
            errdefer if (else_stmts_owned) deinitDecodedStmtSlice(alloc, else_stmts.?);

            if (kw == .list) {
                for (kw.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                        const key = pair.tuple.elems[0].atom;
                        if (std.mem.eql(u8, key, "do")) {
                            then_stmts = try ctValueToStmtsBudgeted(alloc, interner, pair.tuple.elems[1], budget);
                            then_stmts_owned = true;
                        } else if (std.mem.eql(u8, key, "else")) {
                            else_stmts = try ctValueToStmtsBudgeted(alloc, interner, pair.tuple.elems[1], budget);
                            else_stmts_owned = true;
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
            then_stmts_owned = false;
            else_stmts_owned = false;
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "case")) {
        if (arg_elems.len == 2) {
            const subject = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, subject);
            var clauses = DecodedCaseClauseList.init(alloc);
            defer clauses.deinit();

            const kw = arg_elems[1];
            if (kw == .list) {
                for (kw.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                        if (std.mem.eql(u8, pair.tuple.elems[0].atom, "do") and pair.tuple.elems[1] == .list) {
                            for (pair.tuple.elems[1].list.elems) |clause_val| {
                                try clauses.append(try ctValueToCaseClauseBudgeted(alloc, interner, clause_val, budget));
                            }
                        }
                    }
                }
            }
            const expr = try alloc.create(ast.Expr);
            errdefer alloc.destroy(expr);
            const clause_slice = try clauses.takeOwnedSlice();
            expr.* = .{ .case_expr = .{
                .meta = node_meta,
                .scrutinee = subject,
                .clauses = clause_slice,
            } };
            return expr;
        }
    }

    // Cond: {:cond, meta, [do: [clauses...]]}
    if (std.mem.eql(u8, form_name, "cond")) {
        var clauses = DecodedCondClauseList.init(alloc);
        defer clauses.deinit();
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
                                        try clauses.append(try decodedCondClauseBudgeted(
                                            alloc,
                                            interner,
                                            node_meta,
                                            cond_list.list.elems[0],
                                            body_val,
                                            budget,
                                        ));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        const expr = try alloc.create(ast.Expr);
        errdefer alloc.destroy(expr);
        const clause_slice = try clauses.takeOwnedSlice();
        expr.* = .{ .cond_expr = .{ .meta = node_meta, .clauses = clause_slice } };
        return expr;
    }

    // Receive: {:receive, meta, [message_type, [clauses...], after]} where
    // each clause is {:->, [], [[pattern], body]} and `after` is nil or the
    // list [duration, body].
    if (std.mem.eql(u8, form_name, "receive")) {
        if (arg_elems.len == 3) {
            const message_type = try ctValueToTypeExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedTypeExpr(alloc, message_type);

            var clauses = DecodedCaseClauseList.init(alloc);
            defer clauses.deinit();
            if (arg_elems[1] == .list) {
                for (arg_elems[1].list.elems) |clause_val| {
                    try clauses.append(try ctValueToCaseClauseBudgeted(alloc, interner, clause_val, budget));
                }
            }

            var after_arm: ?ast.ReceiveAfter = null;
            if (arg_elems[2] == .list and arg_elems[2].list.elems.len == 2) {
                const duration = try ctValueToExprBudgeted(alloc, interner, arg_elems[2].list.elems[0], budget);
                errdefer deinitDecodedExpr(alloc, duration);
                const after_body = try ctValueToStmtsBudgeted(alloc, interner, arg_elems[2].list.elems[1], budget);
                after_arm = .{
                    .meta = ast.NodeMeta{ .span = node_meta.span },
                    .duration = duration,
                    .body = after_body,
                };
            }

            const expr = try alloc.create(ast.Expr);
            errdefer alloc.destroy(expr);
            const clause_slice = try clauses.takeOwnedSlice();
            expr.* = .{ .receive_expr = .{
                .meta = node_meta,
                .message_type = message_type,
                .clauses = clause_slice,
                .after = after_arm,
            } };
            return expr;
        }
    }

    // String interpolation: {:<<>>, meta, [parts...]}
    if (std.mem.eql(u8, form_name, "<<>>")) {
        var parts = DecodedStringPartList.init(alloc);
        defer parts.deinit();
        for (arg_elems) |part| {
            if (part == .tuple and part.tuple.elems.len == 3 and part.tuple.elems[0] == .string) {
                try parts.append(.{ .literal = try interner.intern(part.tuple.elems[0].string) });
            } else {
                try parts.append(.{ .expr = try ctValueToExprBudgeted(alloc, interner, part, budget) });
            }
        }
        const expr = try alloc.create(ast.Expr);
        errdefer alloc.destroy(expr);
        const part_slice = try parts.takeOwnedSlice();
        expr.* = .{ .string_interpolation = .{ .meta = node_meta, .parts = part_slice } };
        return expr;
    }

    // Type annotation: {:::, meta, [expr, type]}
    if (std.mem.eql(u8, form_name, "::")) {
        if (arg_elems.len == 2) {
            const inner = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, inner);
            const te = try ctValueToTypeExprBudgeted(alloc, interner, arg_elems[1], budget);
            errdefer deinitDecodedTypeExpr(alloc, te);
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
                const pattern_meta = try cloneDecodedMeta(alloc, node_meta);
                errdefer deinitDecodedMeta(alloc, pattern_meta);
                const pat = try alloc.create(ast.Pattern);
                pat.* = .{ .bind = .{ .meta = pattern_meta, .name = bind_name } };
                break :blk pat;
            } else try ctValueToPatternBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedPattern(alloc, var_pattern);
            const iterable = try ctValueToExprBudgeted(alloc, interner, arg_elems[1], budget);
            errdefer deinitDecodedExpr(alloc, iterable);
            const filter_expr = if (arg_elems[2] != .nil)
                try ctValueToExprBudgeted(alloc, interner, arg_elems[2], budget)
            else
                null;
            errdefer if (filter_expr) |filter| deinitDecodedExpr(alloc, filter);
            const body = try ctValueToExprBudgeted(alloc, interner, arg_elems[3], budget);
            errdefer deinitDecodedExpr(alloc, body);
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
            const chain = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, chain);
            // Handler can be a list of clauses or an expression
            const handler_val = arg_elems[1];
            if (handler_val == .list) {
                var clauses = DecodedCaseClauseList.init(alloc);
                defer clauses.deinit();
                for (handler_val.list.elems) |clause_val| {
                    try clauses.append(try ctValueToCaseClauseBudgeted(alloc, interner, clause_val, budget));
                }
                const expr = try alloc.create(ast.Expr);
                errdefer alloc.destroy(expr);
                const clause_slice = try clauses.takeOwnedSlice();
                expr.* = .{ .error_pipe = .{
                    .meta = node_meta,
                    .chain = chain,
                    .handler = .{ .block = clause_slice },
                } };
                return expr;
            } else {
                const handler_expr = try ctValueToExprBudgeted(alloc, interner, handler_val, budget);
                errdefer deinitDecodedExpr(alloc, handler_expr);
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
            var stmts = DecodedStmtList.init(alloc);
            defer stmts.deinit();
            for (arg_elems[0].list.elems) |elem| {
                try stmts.append(.{ .expr = try ctValueToExprBudgeted(alloc, interner, elem, budget) });
            }
            const expr = try alloc.create(ast.Expr);
            errdefer alloc.destroy(expr);
            const stmt_slice = try stmts.takeOwnedSlice();
            expr.* = .{ .quote_expr = .{ .meta = node_meta, .body = stmt_slice } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "unquote")) {
        if (arg_elems.len == 1) {
            const inner = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, inner);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .unquote_expr = .{ .meta = node_meta, .expr = inner } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "unquote_splicing")) {
        if (arg_elems.len == 1) {
            const inner = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, inner);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .unquote_splicing_expr = .{ .meta = node_meta, .expr = inner } };
            return expr;
        }
    }

    // Function reference: {:&, meta, [name, arity]}
    if (std.mem.eql(u8, form_name, "&")) {
        if (arg_elems.len == 2 and arg_elems[0] == .atom and arg_elems[1] == .int) {
            const function_name = try interner.intern(arg_elems[0].atom);
            const arity = try checkedCtInt(u32, arg_elems[1].int);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .function_ref = .{
                .meta = node_meta,
                .struct_name = null,
                .function = function_name,
                .arity = arity,
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
            const value_expr = try ctValueToExprBudgeted(alloc, interner, arg_elems[1], budget);
            deinitDecodedMeta(alloc, node_meta);
            return value_expr;
        }
    }

    if (std.mem.eql(u8, form_name, "panic")) {
        if (arg_elems.len == 1) {
            const msg = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, msg);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .panic_expr = .{ .meta = node_meta, .message = msg } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "raise")) {
        if (arg_elems.len == 1) {
            const raised_value = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, raised_value);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .raise_expr = .{ .meta = node_meta, .value = raised_value } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "!")) {
        if (arg_elems.len == 1) {
            const inner = try ctValueToExprBudgeted(alloc, interner, arg_elems[0], budget);
            errdefer deinitDecodedExpr(alloc, inner);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .unwrap = .{ .meta = node_meta, .expr = inner } };
            return expr;
        }
    }

    if (std.mem.eql(u8, form_name, "@")) {
        if (arg_elems.len == 1 and arg_elems[0] == .atom) {
            const attr_name = try interner.intern(arg_elems[0].atom);
            const expr = try alloc.create(ast.Expr);
            expr.* = .{ .attr_ref = .{ .meta = node_meta, .name = attr_name } };
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
                const maybe_struct_item = try ctValueToStructItemBudgeted(alloc, interner_mut, value, budget);
                if (maybe_struct_item) |mi| {
                    switch (mi) {
                        .function, .priv_function => |decl| {
                            // Wrap in a block: { function_decl; call_to_function }
                            var decl_owned = true;
                            errdefer if (decl_owned) deinitDecodedFunctionDecl(alloc, decl);
                            const call_callee_meta = try cloneDecodedMeta(alloc, node_meta);
                            var call_callee_meta_owned = true;
                            errdefer if (call_callee_meta_owned) deinitDecodedMeta(alloc, call_callee_meta);
                            const call_callee = try alloc.create(ast.Expr);
                            call_callee.* = .{ .var_ref = .{ .meta = call_callee_meta, .name = decl.name } };
                            call_callee_meta_owned = false;
                            var call_callee_owned = true;
                            errdefer if (call_callee_owned) deinitDecodedExpr(alloc, call_callee);

                            const call_meta = try cloneDecodedMeta(alloc, node_meta);
                            var call_meta_owned = true;
                            errdefer if (call_meta_owned) deinitDecodedMeta(alloc, call_meta);
                            const call_expr = try alloc.create(ast.Expr);
                            call_expr.* = .{ .call = .{ .meta = call_meta, .callee = call_callee, .args = &.{} } };
                            call_callee_owned = false;
                            call_meta_owned = false;
                            var call_expr_owned = true;
                            errdefer if (call_expr_owned) deinitDecodedExpr(alloc, call_expr);

                            // Create block with function_decl statement + call expression
                            const stmts = try alloc.alloc(ast.Stmt, 2);
                            var stmts_initialized: usize = 0;
                            errdefer {
                                for (stmts[0..stmts_initialized]) |stmt| deinitDecodedStmt(alloc, stmt);
                                freeDecodedSlice(alloc, stmts);
                            }
                            stmts[0] = .{ .function_decl = decl };
                            decl_owned = false;
                            stmts_initialized = 1;
                            stmts[1] = .{ .expr = call_expr };
                            call_expr_owned = false;
                            stmts_initialized = 2;
                            const block_expr = try alloc.create(ast.Expr);
                            block_expr.* = .{ .block = .{ .meta = node_meta, .stmts = stmts } };
                            return block_expr;
                        },
                        else => deinitDecodedStructItem(alloc, mi),
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
            var params = DecodedParamList.init(alloc);
            defer params.deinit();
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
                            try params.append(try decodedBindParamBudgeted(alloc, interner_mut, node_meta, name_str, type_ct, budget));
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
                    try params.append(try decodedBindParamBudgeted(alloc, interner_mut, node_meta, param_name, null, budget));
                }
            }

            // Reconstruct body
            var body_stmts = DecodedStmtList.init(alloc);
            defer body_stmts.deinit();
            if (arg_elems[2] != .nil) {
                const body_expr = try ctValueToExprBudgeted(alloc, interner, arg_elems[2], budget);
                try body_stmts.append(.{ .expr = body_expr });
            }

            // Reconstruct return type if present (4th arg)
            const return_type: ?*const ast.TypeExpr = if (arg_elems.len >= 4 and arg_elems[3] != .nil)
                try ctValueToTypeExprBudgeted(alloc, interner_mut, arg_elems[3], budget)
            else
                null;
            var return_type_owned = return_type != null;
            errdefer if (return_type_owned) deinitDecodedTypeExpr(alloc, return_type.?);

            const clause_meta = try cloneDecodedMeta(alloc, node_meta);
            var clause_meta_owned = true;
            errdefer if (clause_meta_owned) deinitDecodedMeta(alloc, clause_meta);

            const params_slice = try params.takeOwnedSlice();
            var params_slice_owned = true;
            errdefer if (params_slice_owned) deinitDecodedParamSlice(alloc, params_slice);
            const body_slice = try body_stmts.takeOwnedSlice();
            var body_slice_owned = true;
            errdefer if (body_slice_owned) deinitDecodedStmtSlice(alloc, body_slice);

            const clauses = try alloc.alloc(ast.FunctionClause, 1);
            clauses[0] = .{
                .meta = clause_meta,
                .params = params_slice,
                .return_type = return_type,
                .refinement = null,
                .body = body_slice,
            };
            clause_meta_owned = false;
            params_slice_owned = false;
            body_slice_owned = false;
            return_type_owned = false;
            var clauses_owned = true;
            errdefer {
                if (clauses_owned) {
                    deinitDecodedFunctionClause(alloc, clauses[0]);
                    freeDecodedSlice(alloc, clauses);
                }
            }

            const decl_meta = try cloneDecodedMeta(alloc, node_meta);
            var decl_meta_owned = true;
            errdefer if (decl_meta_owned) deinitDecodedMeta(alloc, decl_meta);
            const decl = try alloc.create(ast.FunctionDecl);
            decl.* = .{
                .meta = decl_meta,
                .name = fn_name,
                .clauses = clauses,
                .visibility = .private,
            };
            clauses_owned = false;
            decl_meta_owned = false;
            errdefer deinitDecodedFunctionDecl(alloc, decl);

            const anon_expr = try alloc.create(ast.Expr);
            anon_expr.* = .{ .anonymous_function = .{ .meta = node_meta, .decl = decl } };
            return anon_expr;
        }
    }

    // Default: treat as a function call — {:name, meta, [args...]}.
    //
    // The form atom may carry a leading `":"` when it was produced
    // by `intern_atom` and substituted into callee position
    // by an `unquote(name)` in `pub fn unquote(name)()` /
    // `unquote(name)()` patterns. The colon prefix distinguishes
    // atom literals from variable references in the AST encoding;
    // function names use the unprefixed form, so strip it here so
    // the generated `var_ref` resolves correctly.
    {
        const raw_name = form_name;
        const callee_name = if (raw_name.len > 0 and raw_name[0] == ':')
            raw_name[1..]
        else
            raw_name;
        const callee_name_id = try interner.intern(callee_name);
        const callee_meta = try cloneDecodedMeta(alloc, node_meta);
        var callee_meta_owned = true;
        errdefer if (callee_meta_owned) deinitDecodedMeta(alloc, callee_meta);
        const callee = try alloc.create(ast.Expr);
        callee.* = .{ .var_ref = .{ .meta = callee_meta, .name = callee_name_id } };
        callee_meta_owned = false;
        errdefer deinitDecodedExpr(alloc, callee);

        var call_args = DecodedExprList.init(alloc);
        defer call_args.deinit();
        for (arg_elems) |elem| {
            try call_args.append(try ctValueToExprBudgeted(alloc, interner, elem, budget));
        }

        const expr = try alloc.create(ast.Expr);
        errdefer alloc.destroy(expr);
        const call_args_slice = try call_args.takeOwnedSlice();
        expr.* = .{ .call = .{
            .meta = node_meta,
            .callee = callee,
            .args = call_args_slice,
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
) CtValueDecodeError!ast.Stmt {
    var budget = CtValueDecodeBudget.default();
    return ctValueToStmtBudgeted(alloc, interner, value, &budget);
}

fn ctValueToStmtBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.Stmt {
    try budget.enter();
    defer budget.leave();

    if (value == .tuple and value.tuple.elems.len == 3) {
        const form = value.tuple.elems[0];
        const args_val = value.tuple.elems[2];
        if (form == .atom and std.mem.eql(u8, form.atom, "=")) {
            if (args_val == .list and args_val.list.elems.len == 2) {
                const pattern = try ctValueToPatternBudgeted(alloc, interner, args_val.list.elems[0], budget);
                errdefer deinitDecodedPattern(alloc, pattern);
                const value_expr = try ctValueToExprBudgeted(alloc, interner, args_val.list.elems[1], budget);
                errdefer deinitDecodedExpr(alloc, value_expr);
                const node_meta = try keywordListToMetaBudgeted(alloc, value.tuple.elems[1], budget);
                errdefer deinitDecodedMeta(alloc, node_meta);
                const assignment = try alloc.create(ast.Assignment);
                assignment.* = .{
                    .meta = node_meta,
                    .pattern = pattern,
                    .value = value_expr,
                };
                return .{ .assignment = assignment };
            }
        }
        if (form == .atom and std.mem.eql(u8, form.atom, "@")) {
            if (args_val == .list and args_val.list.elems.len >= 1 and args_val.list.elems[0] == .atom) {
                const attr_value: ?*const ast.Expr = if (args_val.list.elems.len >= 2)
                    try ctValueToExprBudgeted(alloc, interner, args_val.list.elems[1], budget)
                else
                    null;
                errdefer if (attr_value) |value_expr| deinitDecodedExpr(alloc, value_expr);
                const node_meta = try keywordListToMetaBudgeted(alloc, value.tuple.elems[1], budget);
                errdefer deinitDecodedMeta(alloc, node_meta);
                const attr_name = try interner.intern(args_val.list.elems[0].atom);
                const decl = try alloc.create(ast.AttributeDecl);
                decl.* = .{
                    .meta = node_meta,
                    .name = attr_name,
                    .type_expr = null,
                    .value = attr_value,
                };
                return .{ .attribute = decl };
            }
        }
    }
    // Default: treat as expression statement
    return .{ .expr = try ctValueToExprBudgeted(alloc, interner, value, budget) };
}

fn ctFieldName(value: CtValue) ?[]const u8 {
    return switch (value) {
        .atom => |raw| if (raw.len > 0 and raw[0] == ':') raw[1..] else raw,
        .string => |name| name,
        else => null,
    };
}

/// Convert a CtValue to a statement list (for do/else blocks).
fn ctValueToStmts(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) CtValueDecodeError![]const ast.Stmt {
    var budget = CtValueDecodeBudget.default();
    return ctValueToStmtsBudgeted(alloc, interner, value, &budget);
}

fn ctValueToStmtsBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError![]const ast.Stmt {
    try budget.enter();
    defer budget.leave();

    // If it's a __block__, unwrap the children
    if (value == .tuple and value.tuple.elems.len == 3) {
        if (value.tuple.elems[0] == .atom and std.mem.eql(u8, value.tuple.elems[0].atom, "__block__")) {
            if (value.tuple.elems[2] == .list) {
                var stmts = DecodedStmtList.init(alloc);
                defer stmts.deinit();
                for (value.tuple.elems[2].list.elems) |elem| {
                    try stmts.append(try ctValueToStmtBudgeted(alloc, interner, elem, budget));
                }
                return stmts.takeOwnedSlice();
            }
        }
    }
    // Single expression — may still be an assignment form
    const stmts = try alloc.alloc(ast.Stmt, 1);
    errdefer freeDecodedSlice(alloc, stmts);
    stmts[0] = try ctValueToStmtBudgeted(alloc, interner, value, budget);
    return stmts;
}

/// Convert a CtValue arrow clause back to a CaseClause.
fn ctValueToCaseClause(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) CtValueDecodeError!ast.CaseClause {
    var budget = CtValueDecodeBudget.default();
    return ctValueToCaseClauseBudgeted(alloc, interner, value, &budget);
}

fn ctValueToCaseClauseBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.CaseClause {
    try budget.enter();
    defer budget.leave();

    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    // Expect {:->, [], [[pattern], body]}
    if (value != .tuple or value.tuple.elems.len != 3) return error.InvalidCtValueShape;
    if (value.tuple.elems[0] != .atom or !std.mem.eql(u8, value.tuple.elems[0].atom, "->")) return error.InvalidCtValueShape;

    const arrow_args = value.tuple.elems[2];
    if (arrow_args != .list or arrow_args.list.elems.len != 2) return error.InvalidCtValueShape;

    const pat_list = arrow_args.list.elems[0];
    if (pat_list != .list or pat_list.list.elems.len == 0) return error.InvalidCtValueShape;

    const body_val = arrow_args.list.elems[1];
    const pattern = try ctValueToPatternBudgeted(alloc, interner, pat_list.list.elems[0], budget);
    errdefer deinitDecodedPattern(alloc, pattern);
    const stmts = try ctValueToStmtsBudgeted(alloc, interner, body_val, budget);
    errdefer deinitDecodedStmtSlice(alloc, stmts);

    return .{
        .meta = meta,
        .pattern = pattern,
        .type_annotation = null,
        .guard = null,
        .body = stmts,
    };
}

/// Convert a CtValue to an ast.Pattern.
fn ctValueToPattern(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) CtValueDecodeError!*const ast.Pattern {
    var budget = CtValueDecodeBudget.default();
    return ctValueToPatternBudgeted(alloc, interner, value, &budget);
}

fn ctValueToPatternBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!*const ast.Pattern {
    try budget.enter();
    defer budget.leave();

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
                    const string_id = try interner.intern(v);
                    const pat = try alloc.create(ast.Pattern);
                    pat.* = .{ .literal = .{ .string = .{ .meta = meta, .value = string_id } } };
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
                        const name_id = try interner.intern(name);
                        const pat = try alloc.create(ast.Pattern);
                        pat.* = .{ .bind = .{ .meta = meta, .name = name_id } };
                        return pat;
                    } else {
                        const atom_id = try interner.intern(name);
                        const pat = try alloc.create(ast.Pattern);
                        pat.* = .{ .literal = .{ .atom = .{ .meta = meta, .value = atom_id } } };
                        return pat;
                    }
                },
                else => {},
            }
        }

        // Pin: {:^, meta, [name]}
        if (form == .atom and std.mem.eql(u8, form.atom, "^")) {
            if (pat_args == .list and pat_args.list.elems.len == 1 and pat_args.list.elems[0] == .atom) {
                const pin_name = try interner.intern(pat_args.list.elems[0].atom);
                const pat = try alloc.create(ast.Pattern);
                pat.* = .{ .pin = .{ .meta = meta, .name = pin_name } };
                return pat;
            }
        }

        // List cons: {:|, meta, [heads_list, tail]}
        if (form == .atom and std.mem.eql(u8, form.atom, "|")) {
            if (pat_args == .list and pat_args.list.elems.len == 2) {
                var heads = DecodedPatternList.init(alloc);
                defer heads.deinit();
                if (pat_args.list.elems[0] == .list) {
                    for (pat_args.list.elems[0].list.elems) |h| {
                        try heads.append(try ctValueToPatternBudgeted(alloc, interner, h, budget));
                    }
                }
                const tail = try ctValueToPatternBudgeted(alloc, interner, pat_args.list.elems[1], budget);
                errdefer deinitDecodedPattern(alloc, tail);
                const pat = try alloc.create(ast.Pattern);
                errdefer alloc.destroy(pat);
                const head_slice = try heads.takeOwnedSlice();
                pat.* = .{ .list_cons = .{ .meta = meta, .heads = head_slice, .tail = tail } };
                return pat;
            }
        }

        // Tagged-union variant pattern: {:variant, meta, [aliases, payload_or_nil]}.
        // Mirrors the `.tagged_union_variant` encoder in `patternToCtValue`:
        // the qualifier is an `__aliases__` segment list (`[Option, Some]`)
        // and the payload is either a nested destructuring pattern or `nil`
        // for a nullary variant (`Option.None`). Reconstructing this is what
        // keeps a `case` arm like `Option.Some(v) -> v` binding `v` after a
        // quote/unquote round-trip (Zest `test`/`describe` bodies); without
        // it the pattern collapsed to a bare wildcard and dropped the binding.
        if (form == .atom and std.mem.eql(u8, form.atom, "variant")) {
            if (pat_args == .list and pat_args.list.elems.len == 2) {
                const aliases_ct = pat_args.list.elems[0];
                const payload_ct = pat_args.list.elems[1];

                var parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
                defer parts.deinit(alloc);
                if (aliases_ct == .tuple and aliases_ct.tuple.elems.len == 3 and aliases_ct.tuple.elems[2] == .list) {
                    for (aliases_ct.tuple.elems[2].list.elems) |part| {
                        if (part == .atom) try parts.append(alloc, try interner.intern(part.atom));
                    }
                }

                const payload: ?*const ast.Pattern = if (payload_ct == .nil)
                    null
                else
                    try ctValueToPatternBudgeted(alloc, interner, payload_ct, budget);
                errdefer if (payload) |payload_pattern| deinitDecodedPattern(alloc, payload_pattern);

                const pat = try alloc.create(ast.Pattern);
                errdefer alloc.destroy(pat);
                const part_slice = try parts.toOwnedSlice(alloc);
                errdefer freeDecodedSlice(alloc, part_slice);
                pat.* = .{ .tagged_union_variant = .{
                    .meta = meta,
                    .qualifier = .{ .parts = part_slice, .span = meta.span },
                    .payload = payload,
                } };
                return pat;
            }
        }

        // Struct pattern: {:%, meta, [aliases, {:%{}, [], [fields...]}]}
        if (form == .atom and std.mem.eql(u8, form.atom, "%")) {
            if (pat_args == .list and pat_args.list.elems.len == 2) {
                const aliases_ct = pat_args.list.elems[0];
                const map_ct = pat_args.list.elems[1];
                // Extract struct name
                var parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
                defer parts.deinit(alloc);
                if (aliases_ct == .tuple and aliases_ct.tuple.elems.len == 3 and aliases_ct.tuple.elems[2] == .list) {
                    for (aliases_ct.tuple.elems[2].list.elems) |part| {
                        if (part == .atom) try parts.append(alloc, try interner.intern(part.atom));
                    }
                }
                // Extract fields
                var fields = DecodedStructPatternFieldList.init(alloc);
                defer fields.deinit();
                if (map_ct == .tuple and map_ct.tuple.elems.len == 3 and map_ct.tuple.elems[2] == .list) {
                    for (map_ct.tuple.elems[2].list.elems) |pair| {
                        if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                            try fields.append(try decodedStructPatternFieldBudgeted(alloc, interner, pair.tuple.elems[0], pair.tuple.elems[1], budget));
                        }
                    }
                }
                const pat = try alloc.create(ast.Pattern);
                errdefer alloc.destroy(pat);
                const part_slice = try parts.toOwnedSlice(alloc);
                errdefer freeDecodedSlice(alloc, part_slice);
                const field_slice = try fields.takeOwnedSlice();
                pat.* = .{ .struct_pattern = .{
                    .meta = meta,
                    .struct_name = .{ .parts = part_slice, .span = meta.span },
                    .fields = field_slice,
                } };
                return pat;
            }
        }

        // Map pattern: {:%{}, meta, [field_pairs...]}
        if (form == .atom and std.mem.eql(u8, form.atom, "%{}")) {
            if (pat_args == .list) {
                var fields = DecodedMapPatternFieldList.init(alloc);
                defer fields.deinit();
                for (pat_args.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2) {
                        try fields.append(try decodedMapPatternFieldBudgeted(alloc, interner, pair.tuple.elems[0], pair.tuple.elems[1], budget));
                    }
                }
                const pat = try alloc.create(ast.Pattern);
                errdefer alloc.destroy(pat);
                const field_slice = try fields.takeOwnedSlice();
                pat.* = .{ .map = .{ .meta = meta, .fields = field_slice } };
                return pat;
            }
        }

        // Tuple pattern: {:{}, meta, [elems...]}
        if (form == .atom and std.mem.eql(u8, form.atom, "{}")) {
            if (pat_args == .list) {
                var elems = DecodedPatternList.init(alloc);
                defer elems.deinit();
                for (pat_args.list.elems) |elem| {
                    try elems.append(try ctValueToPatternBudgeted(alloc, interner, elem, budget));
                }
                const pat = try alloc.create(ast.Pattern);
                errdefer alloc.destroy(pat);
                const element_slice = try elems.takeOwnedSlice();
                pat.* = .{ .tuple = .{ .meta = meta, .elements = element_slice } };
                return pat;
            }
        }
    }

    // Bare list → list pattern
    if (value == .list) {
        var elems = DecodedPatternList.init(alloc);
        defer elems.deinit();
        for (value.list.elems) |elem| {
            try elems.append(try ctValueToPatternBudgeted(alloc, interner, elem, budget));
        }
        const pat = try alloc.create(ast.Pattern);
        errdefer alloc.destroy(pat);
        const element_slice = try elems.takeOwnedSlice();
        pat.* = .{ .list = .{ .meta = meta, .elements = element_slice } };
        return pat;
    }

    return error.InvalidCtValueShape;
}

/// Extract metadata from a keyword list CtValue.
fn keywordListToMeta(alloc: Allocator, value: CtValue) CtValueDecodeError!ast.NodeMeta {
    var budget = CtValueDecodeBudget.default();
    return keywordListToMetaBudgeted(alloc, value, &budget);
}

fn keywordListToMetaBudgeted(
    alloc: Allocator,
    value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.NodeMeta {
    try budget.enter();
    defer budget.leave();

    var start: u32 = 0;
    var end: u32 = 0;
    var line: u32 = 0;
    var col: u32 = 0;
    var source_id: ?u32 = null;
    var scopes: scope_mod.ScopeSet = .empty;
    errdefer scopes.deinit(alloc);
    if (value != .list) return error.InvalidCtValueShape;

    for (value.list.elems) |pair| {
        try budget.consumeNode();
        if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
            const key = pair.tuple.elems[0].atom;
            if (std.mem.eql(u8, key, "start") and pair.tuple.elems[1] == .int) {
                start = try checkedCtInt(u32, pair.tuple.elems[1].int);
            } else if (std.mem.eql(u8, key, "end") and pair.tuple.elems[1] == .int) {
                end = try checkedCtInt(u32, pair.tuple.elems[1].int);
            } else if (std.mem.eql(u8, key, "line") and pair.tuple.elems[1] == .int) {
                line = try checkedCtInt(u32, pair.tuple.elems[1].int);
            } else if (std.mem.eql(u8, key, "col") and pair.tuple.elems[1] == .int) {
                col = try checkedCtInt(u32, pair.tuple.elems[1].int);
            } else if (std.mem.eql(u8, key, "source_id") and pair.tuple.elems[1] == .int) {
                source_id = try checkedCtInt(u32, pair.tuple.elems[1].int);
            } else if (std.mem.eql(u8, key, "scopes") and pair.tuple.elems[1] == .list) {
                // Rehydrate the hygiene scope set. The encoded list is
                // sorted (the encoder calls `meta.scopes.slice()` which
                // preserves the sorted invariant), but we use `add`
                // here rather than appending raw so the invariant is
                // re-established defensively from any source.
                try budget.consumeNode();
                for (pair.tuple.elems[1].list.elems) |scope_val| {
                    try budget.consumeNode();
                    if (scope_val == .int) {
                        try scopes.add(alloc, try checkedCtInt(scope_mod.ScopeId, scope_val.int));
                    }
                }
            }
        }
    }
    return .{
        .span = .{ .start = start, .end = end, .line = line, .col = col, .source_id = source_id },
        .scopes = scopes,
    };
}

// ============================================================
// Hygiene scope walker
//
// Identifiers in a CtValue tree are 3-tuples `{atom_name, meta_kw_list, nil}`
// where `atom_name.atom` is a bare identifier — *not* prefixed with `:`
// (atoms with `:` prefix are atom literals, not identifiers; see
// `exprToCtValue` for atom_literal which wraps the name with a `:` prefix).
//
// The walkers in this section traverse a CtValue tree and rewrite the
// `meta.scopes` field on every identifier 3-tuple they encounter,
// returning a structurally fresh tree. Used by the macro engine at
// expansion boundaries to implement Flatt-2016 hygiene:
//   - addScopeToIdentifiers: extends the scope set on all identifiers
//     so user-supplied AST entering the macro carries a use_scope, and
//     template AST gets an intro_scope.
//   - flipScopeOnIdentifiers: XORs a scope on every identifier; used
//     after substitution to remove the use_scope from user-supplied
//     identifiers (which had it added on entry) while introducing it
//     on template identifiers (which didn't).
//
// The implementation decodes the meta keyword list into NodeMeta,
// mutates `scopes`, and re-encodes via `metaToList`. This is the
// most-obviously-correct path: it goes through the same encoding the
// macro engine uses elsewhere, so any future field added to NodeMeta
// is automatically preserved.
// ============================================================

/// Operation applied to an identifier's scope set during a walk.
const ScopeOp = enum { add, flip };

/// Apply `op(scope_id)` to the `meta.scopes` of every identifier-shaped
/// 3-tuple in `value`, returning a fresh CtValue tree. Non-identifier
/// 3-tuples (calls, operator forms, declarations, blocks, etc.) keep
/// their meta unchanged but are recursively descended into.
pub fn addScopeToIdentifiers(
    alloc: Allocator,
    store: *AllocationStore,
    value: CtValue,
    scope_id: scope_mod.ScopeId,
) CtValueDecodeError!CtValue {
    return transformIdentifierScopes(alloc, store, value, scope_id, .add);
}

/// Same as `addScopeToIdentifiers` but XORs the scope (Flatt's "flip"
/// operation). On identifiers that already carry the scope, this
/// removes it; on identifiers that don't, it adds it.
pub fn flipScopeOnIdentifiers(
    alloc: Allocator,
    store: *AllocationStore,
    value: CtValue,
    scope_id: scope_mod.ScopeId,
) CtValueDecodeError!CtValue {
    return transformIdentifierScopes(alloc, store, value, scope_id, .flip);
}

fn transformIdentifierScopes(
    alloc: Allocator,
    store: *AllocationStore,
    value: CtValue,
    scope_id: scope_mod.ScopeId,
    op: ScopeOp,
) CtValueDecodeError!CtValue {
    return transformIdentifierScopesWithBudget(
        alloc,
        store,
        value,
        scope_id,
        op,
        IDENTIFIER_SCOPE_TRANSFORM_STEP_BUDGET,
    );
}

fn transformIdentifierScopesWithBudget(
    alloc: Allocator,
    store: *AllocationStore,
    value: CtValue,
    scope_id: scope_mod.ScopeId,
    op: ScopeOp,
    max_steps: usize,
) CtValueDecodeError!CtValue {
    var steps_remaining = max_steps;
    var frames: SmallInlineStack(IdentifierScopeTransformFrame, IDENTIFIER_SCOPE_TRANSFORM_INLINE_STACK_CAPACITY) = .{};
    defer frames.deinit(alloc);
    var results: SmallInlineStack(CtValue, IDENTIFIER_SCOPE_TRANSFORM_INLINE_STACK_CAPACITY) = .{};
    defer results.deinit(alloc);
    var created_values: std.ArrayListUnmanaged(CtValue) = .empty;
    defer created_values.deinit(alloc);
    errdefer deinitTemporaryCtValueSlice(alloc, store, created_values.items);

    try frames.append(alloc, .{ .visit = value });
    while (frames.len() != 0) {
        switch (frames.pop()) {
            .visit => |current| {
                try consumeIdentifierScopeTransformStep(&steps_remaining);

                if (current == .tuple and current.tuple.elems.len == 3) {
                    if (try transformIdentifierTupleOnly(alloc, store, current.tuple, scope_id, op)) |transformed| {
                        try appendTemporaryCtValue(alloc, store, &created_values, transformed);
                        try results.append(alloc, transformed);
                        continue;
                    }

                    // Non-identifier 3-tuple: keep meta as-is and transform form/args.
                    // Meta keyword lists contain scalar source/hygiene data, not AST identifiers.
                    try frames.append(alloc, .{ .finish_tuple3 = current.tuple });
                    try frames.append(alloc, .{ .visit = current.tuple.elems[2] });
                    try frames.append(alloc, .{ .visit = current.tuple.elems[0] });
                    continue;
                }

                if (current == .tuple and current.tuple.elems.len == 2) {
                    try frames.append(alloc, .{ .finish_tuple2 = current.tuple });
                    try frames.append(alloc, .{ .visit = current.tuple.elems[1] });
                    continue;
                }

                if (current == .list) {
                    try frames.append(alloc, .{ .finish_list = current.list });
                    var index = current.list.elems.len;
                    while (index > 0) {
                        index -= 1;
                        try frames.append(alloc, .{ .visit = current.list.elems[index] });
                    }
                    continue;
                }

                try results.append(alloc, current);
            },
            .finish_tuple3 => |tuple| {
                const new_args = results.pop();
                const new_form = results.pop();
                const new_elems = try alloc.alloc(CtValue, 3);
                var new_elems_transferred = false;
                errdefer if (!new_elems_transferred and new_elems.len > 0) alloc.free(new_elems);
                new_elems[0] = new_form;
                new_elems[1] = tuple.elems[1];
                new_elems[2] = new_args;
                const id = try store.alloc(alloc, .tuple, null);
                const transformed = CtValue{ .tuple = .{ .alloc_id = id, .elems = new_elems } };
                new_elems_transferred = true;
                try appendTemporaryCtValue(alloc, store, &created_values, transformed);
                try results.append(alloc, transformed);
            },
            .finish_tuple2 => |tuple| {
                const new_value = results.pop();
                const new_elems = try alloc.alloc(CtValue, 2);
                var new_elems_transferred = false;
                errdefer if (!new_elems_transferred and new_elems.len > 0) alloc.free(new_elems);
                new_elems[0] = tuple.elems[0];
                new_elems[1] = new_value;
                const id = try store.alloc(alloc, .tuple, null);
                const transformed = CtValue{ .tuple = .{ .alloc_id = id, .elems = new_elems } };
                new_elems_transferred = true;
                try appendTemporaryCtValue(alloc, store, &created_values, transformed);
                try results.append(alloc, transformed);
            },
            .finish_list => |list| {
                const new_elems = try alloc.alloc(CtValue, list.elems.len);
                var new_elems_transferred = false;
                errdefer if (!new_elems_transferred and new_elems.len > 0) alloc.free(new_elems);
                var index = list.elems.len;
                while (index > 0) {
                    index -= 1;
                    new_elems[index] = results.pop();
                }
                const id = try store.alloc(alloc, .list, null);
                const transformed = CtValue{ .list = .{ .alloc_id = id, .elems = new_elems } };
                new_elems_transferred = true;
                try appendTemporaryCtValue(alloc, store, &created_values, transformed);
                try results.append(alloc, transformed);
            },
        }
    }

    std.debug.assert(results.len() == 1);
    return results.pop();
}

fn consumeIdentifierScopeTransformStep(steps_remaining: *usize) CtValueDecodeError!void {
    if (steps_remaining.* > 0) {
        steps_remaining.* -= 1;
        return;
    }
    return error.StructuralBudgetExceeded;
}

fn transformIdentifierTupleOnly(
    alloc: Allocator,
    store: *AllocationStore,
    tuple: CtValue.CtTupleValue,
    scope_id: scope_mod.ScopeId,
    op: ScopeOp,
) CtValueDecodeError!?CtValue {
    // Identifier shape: 3-tuple `{atom_name, meta_kw_list, nil}` whose
    // form atom is a bare identifier (not a `:`-prefixed atom literal).
    // The args slot must be `.nil` — variable references have no args;
    // calls (which also use a 3-tuple shape) carry their args in the
    // third slot.
    const form = tuple.elems[0];
    const args = tuple.elems[2];
    const is_identifier = form == .atom and
        args == .nil and
        form.atom.len > 0 and
        form.atom[0] != ':';
    if (!is_identifier) return null;

    // Decode meta, mutate scope set, re-encode. Going through
    // NodeMeta+metaToList rather than mutating the keyword list
    // directly means any future fields on NodeMeta are preserved.
    var meta = try keywordListToMeta(alloc, tuple.elems[1]);
    defer meta.scopes.deinit(alloc);
    switch (op) {
        .add => try meta.scopes.add(alloc, scope_id),
        .flip => try meta.scopes.flip(alloc, scope_id),
    }
    const new_meta = try metaToList(alloc, store, meta, null);
    var new_meta_transferred = false;
    errdefer if (!new_meta_transferred) deinitTemporaryCtValue(alloc, store, new_meta);
    const new_elems = try alloc.alloc(CtValue, 3);
    var new_elems_transferred = false;
    errdefer if (!new_elems_transferred and new_elems.len > 0) alloc.free(new_elems);
    new_elems[0] = form;
    new_elems[1] = new_meta;
    new_elems[2] = args;
    const id = try store.alloc(alloc, .tuple, null);
    new_meta_transferred = true;
    new_elems_transferred = true;
    return CtValue{ .tuple = .{ .alloc_id = id, .elems = new_elems } };
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
    if (std.mem.eql(u8, name, "in")) return .in_op;
    if (std.mem.eql(u8, name, "not in")) return .not_in_op;
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
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            for (n.args) |arg| {
                try arg_vals.append(try typeExprToCtValue(alloc, interner, store, arg));
            }
            const args = try arg_vals.toCtList();
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = interner.get(n.name) }, args);
        },
        .variable => |v| CtValue{ .atom = interner.get(v.name) },
        .tuple => |t| {
            var elem_vals = TemporaryCtValueList.init(alloc, store);
            defer elem_vals.deinit();
            for (t.elements) |elem| {
                try elem_vals.append(try typeExprToCtValue(alloc, interner, store, elem));
            }
            const args = try elem_vals.toCtList();
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "tuple" }, args);
        },
        .list => |l| {
            const elem = try typeExprToCtValue(alloc, interner, store, l.element);
            const args = try makeListWithTemporaryChildren(alloc, store, &.{elem});
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "list" }, args);
        },
        .map => |m| {
            var field_vals = TemporaryCtValueList.init(alloc, store);
            defer field_vals.deinit();
            for (m.fields) |field| {
                var field_owner = TemporaryCtValueOwner.init(alloc, store);
                defer field_owner.deinit();
                const key = try typeExprToCtValue(alloc, interner, store, field.key);
                try field_owner.adopt(key);
                const val = try typeExprToCtValue(alloc, interner, store, field.value);
                try field_owner.adopt(val);
                const pair = try makeTuple2(alloc, store, key, val);
                field_owner.release();
                try field_vals.append(pair);
            }
            const args = try field_vals.toCtList();
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "map" }, args);
        },
        .function => |f| {
            var param_vals = TemporaryCtValueList.init(alloc, store);
            defer param_vals.deinit();
            for (f.params) |p| {
                try param_vals.append(try typeExprToCtValue(alloc, interner, store, p));
            }
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(try param_vals.toCtList());
            try arg_vals.append(try typeExprToCtValue(alloc, interner, store, f.return_type));
            const args = try arg_vals.toCtList();
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "fn_type" }, args);
        },
        .never => makeTuple3WithTemporaryChildren(alloc, store, .{ .atom = "Never" }, try emptyList(alloc, store), .nil),
        .paren => |p| typeExprToCtValue(alloc, interner, store, p.inner),
        .struct_type => |s| {
            var parts = TemporaryCtValueList.init(alloc, store);
            defer parts.deinit();
            for (s.struct_name.parts) |part| {
                try parts.append(CtValue{ .atom = interner.get(part) });
            }
            const args = try parts.toCtList();
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "__aliases__" }, args);
        },
        .union_type => |u| {
            var member_vals = TemporaryCtValueList.init(alloc, store);
            defer member_vals.deinit();
            for (u.members) |m| {
                try member_vals.append(try typeExprToCtValue(alloc, interner, store, m));
            }
            const args = try member_vals.toCtList();
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "union_type" }, args);
        },
        .literal => |l| switch (l.value) {
            .int => |v| makeTuple3WithTemporaryChildren(alloc, store, .{ .int = v }, try emptyList(alloc, store), .nil),
            .string => |v| makeTuple3WithTemporaryChildren(alloc, store, .{ .string = interner.get(v) }, try emptyList(alloc, store), .nil),
            .bool_val => |v| makeTuple3WithTemporaryChildren(alloc, store, .{ .bool_val = v }, try emptyList(alloc, store), .nil),
            .nil => makeTuple3WithTemporaryChildren(alloc, store, .nil, try emptyList(alloc, store), .nil),
        },
    };
}

/// Convert a CtValue back to a TypeExpr.
/// Atoms become simple named types: :i64 → TypeNameExpr("i64")
pub fn ctValueToTypeExpr(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) CtValueDecodeError!*const ast.TypeExpr {
    var budget = CtValueDecodeBudget.default();
    return ctValueToTypeExprBudgeted(alloc, interner, value, &budget);
}

fn ctValueToTypeExprBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!*const ast.TypeExpr {
    try budget.enter();
    defer budget.leave();

    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    if (value == .atom) {
        const type_name = try interner.intern(value.atom);
        const te = try alloc.create(ast.TypeExpr);
        te.* = .{ .name = .{ .meta = meta, .name = type_name, .args = &.{} } };
        return te;
    }

    if (value == .tuple and value.tuple.elems.len == 3) {
        const form = value.tuple.elems[0];
        const args = value.tuple.elems[2];

        if (form == .atom) {
            if (std.mem.eql(u8, form.atom, "list") and args == .list and args.list.elems.len == 1) {
                const elem = try ctValueToTypeExprBudgeted(alloc, interner, args.list.elems[0], budget);
                errdefer deinitDecodedTypeExpr(alloc, elem);
                const te = try alloc.create(ast.TypeExpr);
                te.* = .{ .list = .{ .meta = meta, .element = elem } };
                return te;
            }

            if (std.mem.eql(u8, form.atom, "tuple") and args == .list) {
                var elems = DecodedTypeExprList.init(alloc);
                defer elems.deinit();
                for (args.list.elems) |elem| {
                    try elems.append(try ctValueToTypeExprBudgeted(alloc, interner, elem, budget));
                }
                const te = try alloc.create(ast.TypeExpr);
                errdefer alloc.destroy(te);
                const element_slice = try elems.takeOwnedSlice();
                te.* = .{ .tuple = .{ .meta = meta, .elements = element_slice } };
                return te;
            }

            if (std.mem.eql(u8, form.atom, "Never") and args == .nil) {
                const te = try alloc.create(ast.TypeExpr);
                te.* = .{ .never = .{ .meta = meta } };
                return te;
            }

            // Map type: {:map, [], [field_pairs...]}
            if (std.mem.eql(u8, form.atom, "map") and args == .list) {
                var fields = DecodedTypeMapFieldList.init(alloc);
                defer fields.deinit();
                for (args.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2) {
                        try fields.append(try decodedTypeMapFieldBudgeted(alloc, interner, pair.tuple.elems[0], pair.tuple.elems[1], budget));
                    }
                }
                const te = try alloc.create(ast.TypeExpr);
                errdefer alloc.destroy(te);
                const field_slice = try fields.takeOwnedSlice();
                te.* = .{ .map = .{ .meta = meta, .fields = field_slice } };
                return te;
            }

            // Function type: {:fn_type, [], [[param_types...], return_type]}
            if (std.mem.eql(u8, form.atom, "fn_type") and args == .list and args.list.elems.len == 2) {
                const param_list = args.list.elems[0];
                const ret = try ctValueToTypeExprBudgeted(alloc, interner, args.list.elems[1], budget);
                errdefer deinitDecodedTypeExpr(alloc, ret);
                var params = DecodedTypeExprList.init(alloc);
                defer params.deinit();
                if (param_list == .list) {
                    for (param_list.list.elems) |p| {
                        try params.append(try ctValueToTypeExprBudgeted(alloc, interner, p, budget));
                    }
                }
                const ownerships = try alloc.alloc(ast.Ownership, params.items.items.len);
                errdefer freeDecodedSlice(alloc, ownerships);
                @memset(ownerships, .shared);
                const explicit = try alloc.alloc(bool, params.items.items.len);
                errdefer freeDecodedSlice(alloc, explicit);
                @memset(explicit, false);
                const te = try alloc.create(ast.TypeExpr);
                errdefer alloc.destroy(te);
                const param_slice = try params.takeOwnedSlice();
                te.* = .{ .function = .{
                    .meta = meta,
                    .params = param_slice,
                    .param_ownerships = ownerships,
                    .param_ownerships_explicit = explicit,
                    .return_type = ret,
                } };
                return te;
            }

            // Union type: {:union_type, [], [member_types...]}
            if (std.mem.eql(u8, form.atom, "union_type") and args == .list) {
                var members = DecodedTypeExprList.init(alloc);
                defer members.deinit();
                for (args.list.elems) |m| {
                    try members.append(try ctValueToTypeExprBudgeted(alloc, interner, m, budget));
                }
                const te = try alloc.create(ast.TypeExpr);
                errdefer alloc.destroy(te);
                const member_slice = try members.takeOwnedSlice();
                te.* = .{ .union_type = .{ .meta = meta, .members = member_slice } };
                return te;
            }

            // Struct type: {:__aliases__, [], [:Part1, :Part2, ...]}
            if (std.mem.eql(u8, form.atom, "__aliases__") and args == .list) {
                var parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
                defer parts.deinit(alloc);
                for (args.list.elems) |part| {
                    if (part == .atom) try parts.append(alloc, try interner.intern(part.atom));
                }
                const te = try alloc.create(ast.TypeExpr);
                errdefer alloc.destroy(te);
                const part_slice = try parts.toOwnedSlice(alloc);
                errdefer freeDecodedSlice(alloc, part_slice);
                te.* = .{ .struct_type = .{
                    .meta = meta,
                    .struct_name = .{ .parts = part_slice, .span = meta.span },
                    .fields = &.{},
                } };
                return te;
            }

            // Named type with args or simple name
            if (args == .nil or args == .list) {
                var type_args = DecodedTypeExprList.init(alloc);
                defer type_args.deinit();
                if (args == .list) {
                    for (args.list.elems) |a| {
                        try type_args.append(try ctValueToTypeExprBudgeted(alloc, interner, a, budget));
                    }
                }
                const type_name = try interner.intern(form.atom);
                const te = try alloc.create(ast.TypeExpr);
                errdefer alloc.destroy(te);
                const arg_slice = try type_args.takeOwnedSlice();
                te.* = .{ .name = .{ .meta = meta, .name = type_name, .args = arg_slice } };
                return te;
            }
        }
    }

    return error.InvalidCtValueShape;
}

/// Convert a FunctionDecl to CtValue:
/// {:fn, [visibility: :pub], [{:name, [], [params...]}, [return: type, do: body]]}
pub fn functionDeclToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    decl: *const ast.FunctionDecl,
) error{OutOfMemory}!CtValue {
    var clause_vals = TemporaryCtValueList.init(alloc, store);
    defer clause_vals.deinit();

    for (decl.clauses) |clause| {
        // Params
        var param_vals = TemporaryCtValueList.init(alloc, store);
        defer param_vals.deinit();
        for (clause.params) |param| {
            try param_vals.append(try paramToCtValue(alloc, interner, store, param));
        }

        // Function head: {:name, [], [params...]}.
        //
        // When `decl.name_expr` is set, the macro author wrote
        // `pub fn unquote(name)(...) { ... }` — the head's form is
        // the unquote AST itself (not a literal atom). The macro
        // engine's substituteCtValue will rewrite the form when the
        // surrounding `quote { ... }` is expanded with bindings.
        const params_list = try param_vals.toCtList();
        var head_owner = TemporaryCtValueOwner.init(alloc, store);
        defer head_owner.deinit();
        try head_owner.adopt(params_list);
        const head_form: CtValue = if (decl.name_expr) |ne|
            try exprToCtValue(alloc, interner, store, ne)
        else
            .{ .atom = interner.get(decl.name) };
        try head_owner.adopt(head_form);
        const head_meta = try emptyList(alloc, store);
        try head_owner.adopt(head_meta);
        const head = try makeTuple3WithOwnedChildren(alloc, store, head_form, head_meta, params_list, &head_owner);

        // Clause args own the head while fallible keyword option conversion runs.
        var clause_arg_vals = TemporaryCtValueList.init(alloc, store);
        defer clause_arg_vals.deinit();
        try clause_arg_vals.append(head);

        // Keyword opts: [return: type, do: body]
        var kw_elems = TemporaryCtValueList.init(alloc, store);
        defer kw_elems.deinit();
        if (clause.return_type) |rt| {
            try kw_elems.append(try makeKeywordPair(alloc, store, "return", try typeExprToCtValue(alloc, interner, store, rt)));
        }

        // Body (optional — protocol signatures and forward declarations have no body)
        if (clause.body) |body_stmts| {
            var body_vals = TemporaryCtValueList.init(alloc, store);
            defer body_vals.deinit();
            for (body_stmts) |stmt| {
                try body_vals.append(try stmtToCtValue(alloc, interner, store, stmt));
            }
            const body_ct = if (body_vals.values.items.len == 1)
                body_vals.takeOnly()
            else
                try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "__block__" }, try body_vals.toCtList());
            try kw_elems.append(try makeKeywordPair(alloc, store, "do", body_ct));
        }

        // Guard
        if (clause.refinement) |guard| {
            try kw_elems.append(try makeKeywordPair(alloc, store, "when", try exprToCtValue(alloc, interner, store, guard)));
        }

        const opts = try kw_elems.toCtList();

        // Clause: {:->, [], [head, opts]}
        try clause_arg_vals.append(opts);
        const clause_args = try clause_arg_vals.toCtList();
        try clause_vals.append(try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "->" }, clause_args));
    }

    const clauses_list = try clause_vals.toCtList();
    var owner = TemporaryCtValueOwner.init(alloc, store);
    defer owner.deinit();
    try owner.adopt(clauses_list);

    // Metadata with visibility
    var meta_elems = TemporaryCtValueList.init(alloc, store);
    defer meta_elems.deinit();
    try meta_elems.append(try makeKeywordPair(alloc, store, "visibility", .{
        .atom = if (decl.visibility == .public) "pub" else "private",
    }));
    if (decl.meta.span.line > 0) {
        try meta_elems.append(try makeKeywordPair(alloc, store, "line", .{ .int = @intCast(decl.meta.span.line) }));
    }
    const meta = try meta_elems.toCtList();
    try owner.adopt(meta);

    return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "fn" }, meta, clauses_list, &owner);
}

/// Convert a Param to CtValue:
/// {:::, [], [{:name, [], nil}, :type]} or {:name, [], nil} (no type)
fn paramToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    param: ast.Param,
) error{OutOfMemory}!CtValue {
    var arg_vals = TemporaryCtValueList.init(alloc, store);
    defer arg_vals.deinit();
    const pat_val = try patternToCtValue(alloc, interner, store, param.pattern);

    if (param.type_annotation) |ta| {
        // {:::, [], [pattern, type]}
        try arg_vals.append(pat_val);
        try arg_vals.append(try typeExprToCtValue(alloc, interner, store, ta));
        const args = try arg_vals.toCtList();
        return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "::" }, args);
    }

    return pat_val;
}

/// Convert a StructDecl to CtValue:
/// {:struct, [visibility: :pub], [:Name, [do: [items...]]]}
pub fn functionBearingStructDeclToCtValue(
    alloc: Allocator,
    interner: *const ast.StringInterner,
    store: *AllocationStore,
    decl: *const ast.StructDecl,
) error{OutOfMemory}!CtValue {
    // Struct name as atom
    var name_parts = TemporaryCtValueList.init(alloc, store);
    defer name_parts.deinit();
    for (decl.name.parts) |part| {
        try name_parts.append(CtValue{ .atom = interner.get(part) });
    }
    const name_args = try name_parts.toCtList();
    const name_val = try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "__aliases__" }, name_args);

    var arg_vals = TemporaryCtValueList.init(alloc, store);
    defer arg_vals.deinit();
    try arg_vals.append(name_val);

    // Items
    var item_vals = TemporaryCtValueList.init(alloc, store);
    defer item_vals.deinit();
    for (decl.items) |item| {
        try item_vals.append(try structItemToCtValue(alloc, interner, store, item));
    }
    const items_list = try item_vals.toCtList();
    const do_pair = try makeKeywordPair(alloc, store, "do", items_list);
    const opts = try makeListWithTemporaryChildren(alloc, store, &.{do_pair});

    try arg_vals.append(opts);
    const args = try arg_vals.toCtList();
    var owner = TemporaryCtValueOwner.init(alloc, store);
    defer owner.deinit();
    try owner.adopt(args);

    // Metadata
    var meta_elems = TemporaryCtValueList.init(alloc, store);
    defer meta_elems.deinit();
    try meta_elems.append(try makeKeywordPair(alloc, store, "visibility", .{
        .atom = if (decl.is_private) "private" else "pub",
    }));
    const meta = try meta_elems.toCtList();
    try owner.adopt(meta);
    return makeTuple3WithOwnedChildren(alloc, store, .{ .atom = "struct" }, meta, args, &owner);
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

    var field_vals = TemporaryCtValueList.init(alloc, store);
    defer field_vals.deinit();
    for (decl.fields) |field| {
        const field_name: CtValue = .{ .atom = interner.get(field.name) };
        const field_type = try typeExprToCtValue(alloc, interner, store, field.type_expr);
        try field_vals.append(try makeTuple2WithTemporaryChildren(alloc, store, field_name, field_type));
    }
    const fields_list = try field_vals.toCtList();

    var arg_vals = TemporaryCtValueList.init(alloc, store);
    defer arg_vals.deinit();
    try arg_vals.append(name_val);
    try arg_vals.append(fields_list);
    const args = try arg_vals.toCtList();
    return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "struct" }, args);
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
                @constCast(fn_ct.tuple.elems)[0] = .{ .atom = "macro" };
            }
            return fn_ct;
        },
        .struct_decl => |s| structDeclToCtValue(alloc, interner, store, s),
        .union_decl => |u| {
            // {:union, [], [:Name, [variants...]]}
            const name_val: CtValue = .{ .atom = interner.get(u.name) };
            var variant_vals = TemporaryCtValueList.init(alloc, store);
            defer variant_vals.deinit();
            for (u.variants) |v| {
                if (v.type_expr) |te| {
                    // Data variant: {:VariantName, type}
                    const vname: CtValue = .{ .atom = interner.get(v.name) };
                    const vtype = try typeExprToCtValue(alloc, interner, store, te);
                    try variant_vals.append(try makeTuple2WithTemporaryChildren(alloc, store, vname, vtype));
                } else {
                    // Unit variant: :VariantName
                    try variant_vals.append(CtValue{ .atom = interner.get(v.name) });
                }
            }
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(name_val);
            try arg_vals.append(try variant_vals.toCtList());
            const args = try arg_vals.toCtList();
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "union" }, args);
        },
        .import_decl => |id| {
            var parts = TemporaryCtValueList.init(alloc, store);
            defer parts.deinit();
            for (id.struct_path.parts) |part| {
                try parts.append(CtValue{ .atom = interner.get(part) });
            }
            const aliases = try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "__aliases__" }, try parts.toCtList());
            const args = try makeListWithTemporaryChildren(alloc, store, &.{aliases});
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "import" }, args);
        },
        .use_decl => |ud| {
            var parts = TemporaryCtValueList.init(alloc, store);
            defer parts.deinit();
            for (ud.struct_path.parts) |part| {
                try parts.append(CtValue{ .atom = interner.get(part) });
            }
            const aliases = try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "__aliases__" }, try parts.toCtList());
            const args = try makeListWithTemporaryChildren(alloc, store, &.{aliases});
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "use" }, args);
        },
        .alias_decl => |ad| {
            // {:alias, [], [struct_path, as_name]}
            var parts = TemporaryCtValueList.init(alloc, store);
            defer parts.deinit();
            for (ad.struct_path.parts) |part| {
                try parts.append(CtValue{ .atom = interner.get(part) });
            }
            const mod_val = try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "__aliases__" }, try parts.toCtList());
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(mod_val);
            if (ad.as_name) |as_name| {
                var as_parts = TemporaryCtValueList.init(alloc, store);
                defer as_parts.deinit();
                for (as_name.parts) |part| {
                    try as_parts.append(CtValue{ .atom = interner.get(part) });
                }
                try arg_vals.append(try makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "__aliases__" }, try as_parts.toCtList()));
            }
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "alias" }, try arg_vals.toCtList());
        },
        .type_decl => |td| {
            // {:type, [], [:Name, body_type]}
            const name_val: CtValue = .{ .atom = interner.get(td.name) };
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(name_val);
            try arg_vals.append(try typeExprToCtValue(alloc, interner, store, td.body));
            const args = try arg_vals.toCtList();
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "type" }, args);
        },
        .opaque_decl => |od| {
            // {:opaque, [], [:Name, body_type]}
            const name_val: CtValue = .{ .atom = interner.get(od.name) };
            var arg_vals = TemporaryCtValueList.init(alloc, store);
            defer arg_vals.deinit();
            try arg_vals.append(name_val);
            try arg_vals.append(try typeExprToCtValue(alloc, interner, store, od.body));
            const args = try arg_vals.toCtList();
            return makeTuple3WithEmptyMetaAndArgs(alloc, store, .{ .atom = "opaque" }, args);
        },
        .attribute => |attr| {
            return attributeDeclToCtValue(alloc, interner, store, attr);
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
/// Extract a function/macro name string from a CtValue used as the
/// "form atom" position of a function-head 3-tuple. Used by
/// `ctValueToStructItem` to support `pub fn unquote(name)(...)` —
/// after macro substitution the form may be a bare atom, a string,
/// or a wrapped literal.
fn extractIdentifierNameBudgeted(value: CtValue, budget: *CtValueDecodeBudget) CtValueDecodeError!?[]const u8 {
    try budget.enter();
    defer budget.leave();

    switch (value) {
        .atom => |a| {
            // Strip the colon prefix that distinguishes literal
            // atoms (`":foo"`) from variable references in the AST
            // encoding. Function names use the unprefixed form.
            if (a.len > 0 and a[0] == ':') return a[1..];
            return a;
        },
        .string => |s| return s,
        .tuple => |t| {
            if (t.elems.len == 3 and t.elems[2] == .nil) {
                return extractIdentifierNameBudgeted(t.elems[0], budget);
            }
            return null;
        },
        else => return null,
    }
}

pub fn ctValueToStructItem(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
) CtValueDecodeError!?ast.StructItem {
    var budget = CtValueDecodeBudget.default();
    return ctValueToStructItemBudgeted(alloc, interner, value, &budget);
}

fn ctValueToStructItemBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!?ast.StructItem {
    try budget.enter();
    defer budget.leave();

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
                try budget.consumeNode();
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
        var clauses = DecodedFunctionClauseList.init(alloc);
        defer clauses.deinit();
        var func_name: ast.StringId = 0;

        for (args.list.elems) |clause_ct| {
            if (clause_ct != .tuple or clause_ct.tuple.elems.len != 3) continue;
            if (clause_ct.tuple.elems[0] != .atom or !std.mem.eql(u8, clause_ct.tuple.elems[0].atom, "->")) continue;
            const clause_args = clause_ct.tuple.elems[2];
            if (clause_args != .list or clause_args.list.elems.len != 2) continue;

            const head = clause_args.list.elems[0];
            const opts = clause_args.list.elems[1];

            // Head: {:name, [], [params...]}.
            //
            // The head's form atom is the function name. When the
            // function was written as `pub fn unquote(name)(...) {}`,
            // the form may now be (post-macro-substitution):
            //   - a bare atom — the resolved name
            //   - a wrapped string literal `{"foo", _, nil}` — same
            //     situation when the unquoted value was a string
            //   - an unresolved unquote tuple — the substitute pass
            //     didn't bind the param; treat as an error and skip
            //     (the macro engine will already have logged a real
            //     diagnostic for the surrounding macro)
            if (head != .tuple or head.tuple.elems.len != 3) continue;
            if (try extractIdentifierNameBudgeted(head.tuple.elems[0], budget)) |name_str| {
                func_name = try interner.intern(name_str);
            } else continue;

            // Params
            var params = DecodedParamList.init(alloc);
            defer params.deinit();
            if (head.tuple.elems[2] == .list) {
                for (head.tuple.elems[2].list.elems) |param_ct| {
                    try params.append(try ctValueToParamBudgeted(alloc, interner, param_ct, budget));
                }
            }

            // Extract opts: [return: type, do: body, when: guard]
            var return_type: ?*const ast.TypeExpr = null;
            var return_type_owned = false;
            errdefer if (return_type_owned) deinitDecodedTypeExpr(alloc, return_type.?);
            var body_stmts: []const ast.Stmt = &.{};
            var body_stmts_owned = false;
            errdefer if (body_stmts_owned) deinitDecodedStmtSlice(alloc, body_stmts);
            var guard: ?*const ast.Expr = null;
            var guard_owned = false;
            errdefer if (guard_owned) deinitDecodedExpr(alloc, guard.?);

            if (opts == .list) {
                for (opts.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                        const key = pair.tuple.elems[0].atom;
                        if (std.mem.eql(u8, key, "return")) {
                            if (return_type_owned) deinitDecodedTypeExpr(alloc, return_type.?);
                            return_type = try ctValueToTypeExprBudgeted(alloc, interner, pair.tuple.elems[1], budget);
                            return_type_owned = true;
                        } else if (std.mem.eql(u8, key, "do")) {
                            if (body_stmts_owned) deinitDecodedStmtSlice(alloc, body_stmts);
                            body_stmts = try ctValueToStmtsBudgeted(alloc, interner, pair.tuple.elems[1], budget);
                            body_stmts_owned = true;
                        } else if (std.mem.eql(u8, key, "when")) {
                            if (guard_owned) deinitDecodedExpr(alloc, guard.?);
                            guard = try ctValueToExprBudgeted(alloc, interner, pair.tuple.elems[1], budget);
                            guard_owned = true;
                        }
                    }
                }
            }

            const params_slice = try params.takeOwnedSlice();
            var params_slice_owned = true;
            errdefer if (params_slice_owned) deinitDecodedParamSlice(alloc, params_slice);

            try clauses.append(.{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .params = params_slice,
                .return_type = return_type,
                .refinement = guard,
                .body = body_stmts,
            });
            params_slice_owned = false;
            return_type_owned = false;
            body_stmts_owned = false;
            guard_owned = false;
        }

        const decl = try alloc.create(ast.FunctionDecl);
        errdefer alloc.destroy(decl);
        const clause_slice = try clauses.takeOwnedSlice();
        decl.* = .{
            .meta = .{ .span = .{ .start = 0, .end = 0 } },
            .name = func_name,
            .clauses = clause_slice,
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
                        var parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
                        defer parts.deinit(alloc);
                        for (aliases.tuple.elems[2].list.elems) |part| {
                            if (part == .atom) try parts.append(alloc, try interner.intern(part.atom));
                        }
                        const decl = try alloc.create(ast.ImportDecl);
                        errdefer alloc.destroy(decl);
                        const part_slice = try parts.toOwnedSlice(alloc);
                        errdefer freeDecodedSlice(alloc, part_slice);
                        decl.* = .{
                            .meta = .{ .span = .{ .start = 0, .end = 0 } },
                            .struct_path = .{ .parts = part_slice, .span = .{ .start = 0, .end = 0 } },
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
            var name_parts_list: std.ArrayListUnmanaged(ast.StringId) = .empty;
            defer name_parts_list.deinit(alloc);
            if (name_val == .atom) try name_parts_list.append(alloc, try interner.intern(name_val.atom));
            var fields = DecodedStructFieldDeclList.init(alloc);
            defer fields.deinit();
            if (fields_val == .list) {
                for (fields_val.list.elems) |pair| {
                    if (pair == .tuple and pair.tuple.elems.len == 2 and pair.tuple.elems[0] == .atom) {
                        try fields.append(try decodedStructFieldDeclBudgeted(alloc, interner, pair.tuple.elems[0], pair.tuple.elems[1], budget));
                    }
                }
            }
            const decl = try alloc.create(ast.StructDecl);
            errdefer alloc.destroy(decl);
            const name_parts = try name_parts_list.toOwnedSlice(alloc);
            errdefer freeDecodedSlice(alloc, name_parts);
            const field_slice = try fields.takeOwnedSlice();
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .name = .{ .parts = name_parts, .span = .{ .start = 0, .end = 0 } },
                .fields = field_slice,
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
                        var parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
                        defer parts.deinit(alloc);
                        for (aliases.tuple.elems[2].list.elems) |part| {
                            if (part == .atom) try parts.append(alloc, try interner.intern(part.atom));
                        }
                        const decl = try alloc.create(ast.UseDecl);
                        errdefer alloc.destroy(decl);
                        const part_slice = try parts.toOwnedSlice(alloc);
                        errdefer freeDecodedSlice(alloc, part_slice);
                        decl.* = .{
                            .meta = .{ .span = .{ .start = 0, .end = 0 } },
                            .struct_path = .{ .parts = part_slice, .span = .{ .start = 0, .end = 0 } },
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
            var variants = DecodedUnionVariantList.init(alloc);
            defer variants.deinit();
            if (args.list.elems.len >= 2 and args.list.elems[1] == .list) {
                for (args.list.elems[1].list.elems) |v| {
                    if (v == .atom) {
                        try variants.append(try decodedUnionVariantBudgeted(alloc, interner, v, null, budget));
                    } else if (v == .tuple and v.tuple.elems.len == 2 and v.tuple.elems[0] == .atom) {
                        try variants.append(try decodedUnionVariantBudgeted(alloc, interner, v.tuple.elems[0], v.tuple.elems[1], budget));
                    }
                }
            }
            const decl = try alloc.create(ast.UnionDecl);
            errdefer alloc.destroy(decl);
            const variant_slice = try variants.takeOwnedSlice();
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .name = name_id,
                .variants = variant_slice,
            };
            return .{ .union_decl = decl };
        }
    }

    // Attribute: {:@, meta, [:name]} or {:@, meta, [:name, value]}
    if (std.mem.eql(u8, form_name, "@")) {
        if (args == .list and args.list.elems.len >= 1 and args.list.elems[0] == .atom) {
            const attr_value: ?*const ast.Expr = if (args.list.elems.len >= 2)
                try ctValueToExprBudgeted(alloc, interner, args.list.elems[1], budget)
            else
                null;
            errdefer if (attr_value) |value_expr| deinitDecodedExpr(alloc, value_expr);
            const attr_name = try interner.intern(args.list.elems[0].atom);
            const decl = try alloc.create(ast.AttributeDecl);
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .name = attr_name,
                .value = attr_value,
            };
            return .{ .attribute = decl };
        }
    }

    // Alias: {:alias, meta, [struct_path, ?as_name]}
    if (std.mem.eql(u8, form_name, "alias")) {
        if (args == .list and args.list.elems.len >= 1) {
            const mod_aliases = args.list.elems[0];
            var mod_parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
            defer mod_parts.deinit(alloc);
            if (mod_aliases == .tuple and mod_aliases.tuple.elems.len == 3 and mod_aliases.tuple.elems[2] == .list) {
                for (mod_aliases.tuple.elems[2].list.elems) |part| {
                    if (part == .atom) try mod_parts.append(alloc, try interner.intern(part.atom));
                }
            }
            var as_name: ?ast.StructName = null;
            var as_name_owned = false;
            errdefer if (as_name_owned) deinitDecodedStructName(alloc, as_name.?);
            if (args.list.elems.len >= 2) {
                const as_aliases = args.list.elems[1];
                if (as_aliases == .tuple and as_aliases.tuple.elems.len == 3 and as_aliases.tuple.elems[2] == .list) {
                    var as_parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
                    defer as_parts.deinit(alloc);
                    for (as_aliases.tuple.elems[2].list.elems) |part| {
                        if (part == .atom) try as_parts.append(alloc, try interner.intern(part.atom));
                    }
                    as_name = .{ .parts = try as_parts.toOwnedSlice(alloc), .span = .{ .start = 0, .end = 0 } };
                    as_name_owned = true;
                }
            }
            const decl = try alloc.create(ast.AliasDecl);
            errdefer alloc.destroy(decl);
            const mod_part_slice = try mod_parts.toOwnedSlice(alloc);
            errdefer freeDecodedSlice(alloc, mod_part_slice);
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .struct_path = .{ .parts = mod_part_slice, .span = .{ .start = 0, .end = 0 } },
                .as_name = as_name,
            };
            as_name_owned = false;
            return .{ .alias_decl = decl };
        }
    }

    // Type: {:type, meta, [:Name, body_type]}
    if (std.mem.eql(u8, form_name, "type")) {
        if (args == .list and args.list.elems.len >= 2 and args.list.elems[0] == .atom) {
            const name = try interner.intern(args.list.elems[0].atom);
            const body = try ctValueToTypeExprBudgeted(alloc, interner, args.list.elems[1], budget);
            errdefer deinitDecodedTypeExpr(alloc, body);
            const decl = try alloc.create(ast.TypeDecl);
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .name = name,
                .params = &.{},
                .body = body,
            };
            return .{ .type_decl = decl };
        }
    }

    // Opaque: {:opaque, meta, [:Name, body_type]}
    if (std.mem.eql(u8, form_name, "opaque")) {
        if (args == .list and args.list.elems.len >= 2 and args.list.elems[0] == .atom) {
            const name = try interner.intern(args.list.elems[0].atom);
            const body = try ctValueToTypeExprBudgeted(alloc, interner, args.list.elems[1], budget);
            errdefer deinitDecodedTypeExpr(alloc, body);
            const decl = try alloc.create(ast.OpaqueDecl);
            decl.* = .{
                .meta = .{ .span = .{ .start = 0, .end = 0 } },
                .name = name,
                .params = &.{},
                .body = body,
            };
            return .{ .opaque_decl = decl };
        }
    }

    // Struct: {:struct, meta, [name, [do: [items...]]]}
    if (std.mem.eql(u8, form_name, "struct")) {
        if (args == .list and args.list.elems.len >= 2) {
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
) CtValueDecodeError!ast.Param {
    var budget = CtValueDecodeBudget.default();
    return ctValueToParamBudgeted(alloc, interner, value, &budget);
}

fn ctValueToParamBudgeted(
    alloc: Allocator,
    interner: *ast.StringInterner,
    value: CtValue,
    budget: *CtValueDecodeBudget,
) CtValueDecodeError!ast.Param {
    try budget.enter();
    defer budget.leave();

    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    // {:::, [], [pattern, type]}
    if (value == .tuple and value.tuple.elems.len == 3) {
        if (value.tuple.elems[0] == .atom and std.mem.eql(u8, value.tuple.elems[0].atom, "::")) {
            if (value.tuple.elems[2] == .list and value.tuple.elems[2].list.elems.len == 2) {
                const pat = try ctValueToPatternBudgeted(alloc, interner, value.tuple.elems[2].list.elems[0], budget);
                errdefer deinitDecodedPattern(alloc, pat);
                const te = try ctValueToTypeExprBudgeted(alloc, interner, value.tuple.elems[2].list.elems[1], budget);
                errdefer deinitDecodedTypeExpr(alloc, te);
                return .{ .meta = meta, .pattern = pat, .type_annotation = te };
            }
        }
    }

    // Just a pattern, no type annotation
    const pat = try ctValueToPatternBudgeted(alloc, interner, value, budget);
    errdefer deinitDecodedPattern(alloc, pat);
    return .{ .meta = meta, .pattern = pat, .type_annotation = null };
}

// ============================================================
// Tests
// ============================================================

fn astDataAllocationTestMeta() ast.NodeMeta {
    return .{ .span = .{ .start = 1, .end = 2, .line = 1, .col = 1 } };
}

fn createTestExpr(alloc: Allocator, expr: ast.Expr) !*const ast.Expr {
    const node = try alloc.create(ast.Expr);
    node.* = expr;
    return node;
}

fn createTestPattern(alloc: Allocator, pattern: ast.Pattern) !*const ast.Pattern {
    const node = try alloc.create(ast.Pattern);
    node.* = pattern;
    return node;
}

fn createTestTypeExpr(alloc: Allocator, type_expr: ast.TypeExpr) !*const ast.TypeExpr {
    const node = try alloc.create(ast.TypeExpr);
    node.* = type_expr;
    return node;
}

fn exerciseExprToCtValueAllocationFailures(
    allocator: Allocator,
    interner: *ast.StringInterner,
    expr: *const ast.Expr,
) !void {
    var store = AllocationStore{};
    defer store.deinit(allocator);

    const value = try exprToCtValue(allocator, interner, &store, expr);
    defer deinitTemporaryCtValue(allocator, &store, value);

    try std.testing.expect(value == .tuple);
}

test "exprToCtValue cleans temporary CtValues on allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("foo");
    const atom_id = try interner.intern("ok");
    const point_id = try interner.intern("Point");
    const x_id = try interner.intern("x");
    const y_id = try interner.intern("y");

    const one = try createTestExpr(alloc, .{ .int_literal = .{ .meta = astDataAllocationTestMeta(), .value = 1 } });
    const two = try createTestExpr(alloc, .{ .int_literal = .{ .meta = astDataAllocationTestMeta(), .value = 2 } });
    const atom_expr = try createTestExpr(alloc, .{ .atom_literal = .{ .meta = astDataAllocationTestMeta(), .value = atom_id } });
    const sum = try createTestExpr(alloc, .{ .binary_op = .{ .meta = astDataAllocationTestMeta(), .op = .add, .lhs = one, .rhs = two } });

    const tuple_elements = [_]*const ast.Expr{ sum, atom_expr };
    const tuple_expr = try createTestExpr(alloc, .{ .tuple = .{ .meta = astDataAllocationTestMeta(), .elements = &tuple_elements } });
    const list_elements = [_]*const ast.Expr{ one, sum, atom_expr };
    const list_expr = try createTestExpr(alloc, .{ .list = .{ .meta = astDataAllocationTestMeta(), .elements = &list_elements } });
    const map_fields = [_]ast.MapField{.{ .key = atom_expr, .value = sum }};
    const map_expr = try createTestExpr(alloc, .{ .map = .{ .meta = astDataAllocationTestMeta(), .fields = &map_fields } });
    const struct_parts = [_]ast.StringId{point_id};
    const struct_fields = [_]ast.StructField{
        .{ .name = x_id, .value = one },
        .{ .name = y_id, .value = sum },
    };
    const struct_expr = try createTestExpr(alloc, .{ .struct_expr = .{
        .meta = astDataAllocationTestMeta(),
        .struct_name = .{ .parts = &struct_parts, .span = astDataAllocationTestMeta().span },
        .update_source = null,
        .fields = &struct_fields,
    } });

    const callee = try createTestExpr(alloc, .{ .var_ref = .{ .meta = astDataAllocationTestMeta(), .name = foo_id } });
    const call_args = [_]*const ast.Expr{ tuple_expr, list_expr, map_expr, struct_expr };
    const root = try createTestExpr(alloc, .{ .call = .{ .meta = astDataAllocationTestMeta(), .callee = callee, .args = &call_args } });

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExprToCtValueAllocationFailures,
        .{ &interner, root },
    );
}

fn exercisePatternToCtValueAllocationFailures(
    allocator: Allocator,
    interner: *ast.StringInterner,
    pattern: *const ast.Pattern,
) !void {
    var store = AllocationStore{};
    defer store.deinit(allocator);

    const value = try patternToCtValue(allocator, interner, &store, pattern);
    defer deinitTemporaryCtValue(allocator, &store, value);

    try std.testing.expect(value == .tuple);
}

test "patternToCtValue cleans temporary CtValues on allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const value_id = try interner.intern("value");
    const key_id = try interner.intern("key");
    const point_id = try interner.intern("Point");
    const x_id = try interner.intern("x");

    const key_expr = try createTestExpr(alloc, .{ .atom_literal = .{ .meta = astDataAllocationTestMeta(), .value = key_id } });
    const bind_pattern = try createTestPattern(alloc, .{ .bind = .{ .meta = astDataAllocationTestMeta(), .name = value_id } });
    const wildcard_pattern = try createTestPattern(alloc, .{ .wildcard = .{ .meta = astDataAllocationTestMeta() } });
    const literal_pattern = try createTestPattern(alloc, .{ .literal = .{ .int = .{ .meta = astDataAllocationTestMeta(), .value = 7 } } });
    const cons_heads = [_]*const ast.Pattern{bind_pattern};
    const cons_pattern = try createTestPattern(alloc, .{ .list_cons = .{ .meta = astDataAllocationTestMeta(), .heads = &cons_heads, .tail = wildcard_pattern } });
    const map_fields = [_]ast.MapPatternField{.{ .key = key_expr, .value = literal_pattern }};
    const map_pattern = try createTestPattern(alloc, .{ .map = .{ .meta = astDataAllocationTestMeta(), .fields = &map_fields } });
    const struct_parts = [_]ast.StringId{point_id};
    const struct_fields = [_]ast.StructPatternField{.{ .name = x_id, .pattern = cons_pattern }};
    const struct_pattern = try createTestPattern(alloc, .{ .struct_pattern = .{
        .meta = astDataAllocationTestMeta(),
        .struct_name = .{ .parts = &struct_parts, .span = astDataAllocationTestMeta().span },
        .fields = &struct_fields,
    } });
    const tuple_elements = [_]*const ast.Pattern{ struct_pattern, map_pattern };
    const root = try createTestPattern(alloc, .{ .tuple = .{ .meta = astDataAllocationTestMeta(), .elements = &tuple_elements } });

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePatternToCtValueAllocationFailures,
        .{ &interner, root },
    );
}

fn exerciseDeclarationCtValueAllocationFailures(
    allocator: Allocator,
    interner: *ast.StringInterner,
    function_decl: *const ast.FunctionDecl,
    struct_decl: *const ast.StructDecl,
    union_decl: *const ast.UnionDecl,
    alias_decl: *const ast.AliasDecl,
) !void {
    var store = AllocationStore{};
    defer store.deinit(allocator);

    const function_value = try functionDeclToCtValue(allocator, interner, &store, function_decl);
    defer deinitTemporaryCtValue(allocator, &store, function_value);

    const struct_value = try functionBearingStructDeclToCtValue(allocator, interner, &store, struct_decl);
    defer deinitTemporaryCtValue(allocator, &store, struct_value);

    const union_value = try structItemToCtValue(allocator, interner, &store, .{ .union_decl = union_decl });
    defer deinitTemporaryCtValue(allocator, &store, union_value);

    const alias_value = try structItemToCtValue(allocator, interner, &store, .{ .alias_decl = alias_decl });
    defer deinitTemporaryCtValue(allocator, &store, alias_value);

    try std.testing.expect(function_value == .tuple);
    try std.testing.expect(struct_value == .tuple);
    try std.testing.expect(union_value == .tuple);
    try std.testing.expect(alias_value == .tuple);
}

test "declaration CtValue encoders clean temporaries on allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const generated_id = try interner.intern("generated");
    const value_id = try interner.intern("value");
    const output_id = try interner.intern("output");
    const i64_id = try interner.intern("i64");
    const string_id = try interner.intern("String");
    const box_id = try interner.intern("Box");
    const result_id = try interner.intern("Result");
    const ok_id = try interner.intern("Ok");
    const none_id = try interner.intern("None");
    const alias_target_id = try interner.intern("AliasTarget");
    const alias_name_id = try interner.intern("AliasName");

    const i64_type = try createTestTypeExpr(alloc, .{ .name = .{ .meta = astDataAllocationTestMeta(), .name = i64_id, .args = &.{} } });
    const string_type = try createTestTypeExpr(alloc, .{ .name = .{ .meta = astDataAllocationTestMeta(), .name = string_id, .args = &.{} } });
    const list_type = try createTestTypeExpr(alloc, .{ .list = .{ .meta = astDataAllocationTestMeta(), .element = i64_type } });
    const map_type_fields = [_]ast.TypeMapField{.{ .key = string_type, .value = i64_type }};
    const map_type = try createTestTypeExpr(alloc, .{ .map = .{ .meta = astDataAllocationTestMeta(), .fields = &map_type_fields } });
    const function_type_params = [_]*const ast.TypeExpr{list_type};
    const function_type_ownerships = [_]ast.Ownership{.shared};
    const function_type_ownerships_explicit = [_]bool{false};
    const function_type = try createTestTypeExpr(alloc, .{ .function = .{
        .meta = astDataAllocationTestMeta(),
        .params = &function_type_params,
        .param_ownerships = &function_type_ownerships,
        .param_ownerships_explicit = &function_type_ownerships_explicit,
        .return_type = map_type,
    } });

    const param_pattern = try createTestPattern(alloc, .{ .bind = .{ .meta = astDataAllocationTestMeta(), .name = value_id } });
    const params = [_]ast.Param{.{ .meta = astDataAllocationTestMeta(), .pattern = param_pattern, .type_annotation = function_type }};
    const output_pattern = try createTestPattern(alloc, .{ .bind = .{ .meta = astDataAllocationTestMeta(), .name = output_id } });
    const body_value = try createTestExpr(alloc, .{ .int_literal = .{ .meta = astDataAllocationTestMeta(), .value = 42 } });
    const assignment = try alloc.create(ast.Assignment);
    assignment.* = .{ .meta = astDataAllocationTestMeta(), .pattern = output_pattern, .value = body_value };
    const body_stmts = [_]ast.Stmt{ .{ .assignment = assignment }, .{ .expr = body_value } };
    const clauses = [_]ast.FunctionClause{.{
        .meta = astDataAllocationTestMeta(),
        .params = &params,
        .return_type = map_type,
        .refinement = body_value,
        .body = &body_stmts,
    }};
    const function_decl = try alloc.create(ast.FunctionDecl);
    function_decl.* = .{
        .meta = astDataAllocationTestMeta(),
        .name = generated_id,
        .clauses = &clauses,
        .visibility = .public,
    };

    const struct_parts = [_]ast.StringId{box_id};
    const struct_fields = [_]ast.StructFieldDecl{.{
        .meta = astDataAllocationTestMeta(),
        .name = value_id,
        .type_expr = function_type,
        .default = body_value,
    }};
    const union_variants = [_]ast.UnionVariant{
        .{ .meta = astDataAllocationTestMeta(), .name = ok_id, .type_expr = i64_type },
        .{ .meta = astDataAllocationTestMeta(), .name = none_id },
    };
    const union_decl = try alloc.create(ast.UnionDecl);
    union_decl.* = .{
        .meta = astDataAllocationTestMeta(),
        .name = result_id,
        .variants = &union_variants,
    };
    const struct_items = [_]ast.StructItem{ .{ .function = function_decl }, .{ .union_decl = union_decl } };
    const struct_decl = try alloc.create(ast.StructDecl);
    struct_decl.* = .{
        .meta = astDataAllocationTestMeta(),
        .name = .{ .parts = &struct_parts, .span = astDataAllocationTestMeta().span },
        .items = &struct_items,
        .fields = &struct_fields,
    };

    const alias_target_parts = [_]ast.StringId{alias_target_id};
    const alias_name_parts = [_]ast.StringId{alias_name_id};
    const alias_decl = try alloc.create(ast.AliasDecl);
    alias_decl.* = .{
        .meta = astDataAllocationTestMeta(),
        .struct_path = .{ .parts = &alias_target_parts, .span = astDataAllocationTestMeta().span },
        .as_name = .{ .parts = &alias_name_parts, .span = astDataAllocationTestMeta().span },
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDeclarationCtValueAllocationFailures,
        .{ &interner, function_decl, struct_decl, union_decl, alias_decl },
    );
}

fn wrappedIntCtForDecodedAstFailureTest(
    alloc: Allocator,
    store: *AllocationStore,
    value: i64,
) !CtValue {
    return makeTuple3(alloc, store, .{ .int = value }, try emptyList(alloc, store), .nil);
}

fn wrappedAtomCtForDecodedAstFailureTest(
    alloc: Allocator,
    store: *AllocationStore,
    value: []const u8,
) !CtValue {
    return makeTuple3(alloc, store, .{ .atom = value }, try emptyList(alloc, store), .nil);
}

fn makeDecodedExprFailureCtValue(
    alloc: Allocator,
    store: *AllocationStore,
) !CtValue {
    const one = try wrappedIntCtForDecodedAstFailureTest(alloc, store, 1);
    const two = try wrappedIntCtForDecodedAstFailureTest(alloc, store, 2);
    const tuple_args = try makeList(alloc, store, &.{ one, two });
    const tuple_expr = try makeTuple3(alloc, store, .{ .atom = "{}" }, try emptyList(alloc, store), tuple_args);
    const field_pair = try makeTuple2(alloc, store, .{ .atom = "x" }, tuple_expr);
    const field_pairs = try makeList(alloc, store, &.{field_pair});
    const map_node = try makeTuple3(alloc, store, .{ .atom = "%{}" }, try emptyList(alloc, store), field_pairs);
    const name_parts = try makeList(alloc, store, &.{.{ .atom = "Point" }});
    const struct_args = try makeList(alloc, store, &.{ name_parts, map_node, .nil });
    const struct_expr = try makeTuple3(alloc, store, .{ .atom = "%" }, try emptyList(alloc, store), struct_args);
    const block = try makeTuple3(alloc, store, .{ .atom = "__block__" }, try emptyList(alloc, store), try makeList(alloc, store, &.{struct_expr}));
    const do_pair = try makeKeywordPair(alloc, store, "do", block);
    const kw = try makeList(alloc, store, &.{do_pair});
    return makeTuple3(alloc, store, .{ .atom = "if" }, try emptyList(alloc, store), try makeList(alloc, store, &.{ .{ .bool_val = true }, kw }));
}

fn makeDecodedStmtFailureCtValue(
    alloc: Allocator,
    store: *AllocationStore,
) !CtValue {
    const bind_x = try wrappedAtomCtForDecodedAstFailureTest(alloc, store, "x");
    const bind_y = try wrappedAtomCtForDecodedAstFailureTest(alloc, store, "y");
    const pattern_tuple = try makeTuple3(alloc, store, .{ .atom = "{}" }, try emptyList(alloc, store), try makeList(alloc, store, &.{ bind_x, bind_y }));
    const value_list = try makeList(alloc, store, &.{
        try wrappedIntCtForDecodedAstFailureTest(alloc, store, 10),
        try wrappedIntCtForDecodedAstFailureTest(alloc, store, 20),
    });
    return makeTuple3(alloc, store, .{ .atom = "=" }, try emptyList(alloc, store), try makeList(alloc, store, &.{ pattern_tuple, value_list }));
}

fn makeDecodedPatternFailureCtValue(
    alloc: Allocator,
    store: *AllocationStore,
) !CtValue {
    const head_one = try wrappedAtomCtForDecodedAstFailureTest(alloc, store, "head");
    const head_two = try wrappedIntCtForDecodedAstFailureTest(alloc, store, 7);
    const tail = try wrappedAtomCtForDecodedAstFailureTest(alloc, store, "tail");
    const list_cons = try makeTuple3(
        alloc,
        store,
        .{ .atom = "|" },
        try emptyList(alloc, store),
        try makeList(alloc, store, &.{ try makeList(alloc, store, &.{ head_one, head_two }), tail }),
    );
    const aliases = try makeTuple3(
        alloc,
        store,
        .{ .atom = "__aliases__" },
        try emptyList(alloc, store),
        try makeList(alloc, store, &.{.{ .atom = "Option" }}),
    );
    const field_pair = try makeTuple2(alloc, store, .{ .atom = "value" }, list_cons);
    const map_node = try makeTuple3(alloc, store, .{ .atom = "%{}" }, try emptyList(alloc, store), try makeList(alloc, store, &.{field_pair}));
    return makeTuple3(alloc, store, .{ .atom = "%" }, try emptyList(alloc, store), try makeList(alloc, store, &.{ aliases, map_node }));
}

fn makeDecodedTypeFailureCtValue(
    alloc: Allocator,
    store: *AllocationStore,
) !CtValue {
    const tuple_type = try makeTuple3(
        alloc,
        store,
        .{ .atom = "tuple" },
        try emptyList(alloc, store),
        try makeList(alloc, store, &.{ .{ .atom = "i64" }, .{ .atom = "String" } }),
    );
    const map_field = try makeTuple2(alloc, store, .{ .atom = "String" }, .{ .atom = "i64" });
    const map_type = try makeTuple3(alloc, store, .{ .atom = "map" }, try emptyList(alloc, store), try makeList(alloc, store, &.{map_field}));
    const list_type = try makeTuple3(alloc, store, .{ .atom = "list" }, try emptyList(alloc, store), try makeList(alloc, store, &.{.{ .atom = "Bool" }}));
    const union_type = try makeTuple3(alloc, store, .{ .atom = "union_type" }, try emptyList(alloc, store), try makeList(alloc, store, &.{ list_type, .{ .atom = "Never" } }));
    return makeTuple3(alloc, store, .{ .atom = "fn_type" }, try emptyList(alloc, store), try makeList(alloc, store, &.{ try makeList(alloc, store, &.{ tuple_type, map_type }), union_type }));
}

fn exerciseDecodedExprAllocationFailures(allocator: Allocator, value: CtValue) !void {
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();

    const decoded = try ctValueToExpr(allocator, &interner, value);
    defer deinitDecodedExpr(allocator, decoded);

    try std.testing.expect(decoded.* == .if_expr);
}

fn exerciseDecodedStmtAllocationFailures(allocator: Allocator, value: CtValue) !void {
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();

    const decoded = try ctValueToStmt(allocator, &interner, value);
    defer deinitDecodedStmt(allocator, decoded);

    try std.testing.expect(decoded == .assignment);
}

fn exerciseDecodedPatternAllocationFailures(allocator: Allocator, value: CtValue) !void {
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();

    const decoded = try ctValueToPattern(allocator, &interner, value);
    defer deinitDecodedPattern(allocator, decoded);

    try std.testing.expect(decoded.* == .struct_pattern);
}

fn exerciseDecodedTypeAllocationFailures(allocator: Allocator, value: CtValue) !void {
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();

    const decoded = try ctValueToTypeExpr(allocator, &interner, value);
    defer deinitDecodedTypeExpr(allocator, decoded);

    try std.testing.expect(decoded.* == .function);
}

test "decoded AST expression rollback is transactional under allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const value = try makeDecodedExprFailureCtValue(alloc, &store);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDecodedExprAllocationFailures,
        .{value},
    );
}

test "decoded AST statement rollback cleans pattern and expression children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const value = try makeDecodedStmtFailureCtValue(alloc, &store);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDecodedStmtAllocationFailures,
        .{value},
    );
}

test "decoded AST pattern rollback cleans nested child fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const value = try makeDecodedPatternFailureCtValue(alloc, &store);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDecodedPatternAllocationFailures,
        .{value},
    );
}

test "decoded AST type rollback cleans params, fields, members, and return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const value = try makeDecodedTypeFailureCtValue(alloc, &store);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDecodedTypeAllocationFailures,
        .{value},
    );
}

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

fn makeIdentifierCtForScopeTransformTest(
    alloc: Allocator,
    store: *AllocationStore,
    name: []const u8,
) !CtValue {
    const empty_meta = try emptyList(alloc, store);
    return makeTuple3(alloc, store, .{ .atom = name }, empty_meta, .nil);
}

fn wrapCtInNestedListsForScopeTransformTest(
    alloc: Allocator,
    store: *AllocationStore,
    leaf: CtValue,
    depth: usize,
) !CtValue {
    var current = leaf;
    for (0..depth) |_| {
        current = try makeList(alloc, store, &.{current});
    }
    return current;
}

test "identifier scope transform handles deeply nested macro-produced lists iteratively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const depth: usize = 20_000;
    const identifier = try makeIdentifierCtForScopeTransformTest(alloc, &store, "value");
    const nested = try wrapCtInNestedListsForScopeTransformTest(alloc, &store, identifier, depth);
    const transformed = try addScopeToIdentifiers(alloc, &store, nested, 77);

    var current = transformed;
    for (0..depth) |_| {
        try std.testing.expect(current == .list);
        try std.testing.expectEqual(@as(usize, 1), current.list.elems.len);
        current = current.list.elems[0];
    }

    try std.testing.expect(current == .tuple);
    const meta = try keywordListToMeta(alloc, current.tuple.elems[1]);
    try std.testing.expect(meta.scopes.contains(77));
}

test "identifier scope transform returns structured budget exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const identifier = try makeIdentifierCtForScopeTransformTest(alloc, &store, "value");
    const nested = try wrapCtInNestedListsForScopeTransformTest(alloc, &store, identifier, 4);

    try std.testing.expectError(
        error.StructuralBudgetExceeded,
        transformIdentifierScopesWithBudget(alloc, &store, nested, 77, .add, 2),
    );
}

fn makeNestedTypeListCtForDecodeTest(
    alloc: Allocator,
    store: *AllocationStore,
    leaf: CtValue,
    depth: usize,
) !CtValue {
    var current = leaf;
    for (0..depth) |_| {
        current = try makeTuple3(
            alloc,
            store,
            .{ .atom = "list" },
            try emptyList(alloc, store),
            try makeList(alloc, store, &.{current}),
        );
    }
    return current;
}

fn makeFunctionStructItemCtForDecodeTest(
    alloc: Allocator,
    store: *AllocationStore,
    return_type: CtValue,
) !CtValue {
    const params = try emptyList(alloc, store);
    const head = try makeTuple3(alloc, store, .{ .atom = "generated" }, try emptyList(alloc, store), params);
    const return_pair = try makeKeywordPair(alloc, store, "return", return_type);
    const opts = try makeList(alloc, store, &.{return_pair});
    const clause_args = try makeList(alloc, store, &.{ head, opts });
    const clause = try makeTuple3(alloc, store, .{ .atom = "->" }, try emptyList(alloc, store), clause_args);
    return makeTuple3(alloc, store, .{ .atom = "fn" }, try emptyList(alloc, store), try makeList(alloc, store, &.{clause}));
}

test "ctValueToExpr returns structured budget exhaustion for deeply nested CtValues" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const nested = try wrapCtInNestedListsForScopeTransformTest(alloc, &store, .{ .int = 1 }, 5);
    var budget = CtValueDecodeBudget.init(3, 100);
    try std.testing.expectError(
        error.StructuralBudgetExceeded,
        ctValueToExprBudgeted(alloc, &interner, nested, &budget),
    );
}

test "ctValueToStmt returns structured budget exhaustion for deeply nested CtValues" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const target = try makeIdentifierCtForScopeTransformTest(alloc, &store, "value");
    const nested_value = try wrapCtInNestedListsForScopeTransformTest(alloc, &store, .{ .int = 1 }, 5);
    const assignment_args = try makeList(alloc, &store, &.{ target, nested_value });
    const assignment = try makeTuple3(alloc, &store, .{ .atom = "=" }, try emptyList(alloc, &store), assignment_args);

    var budget = CtValueDecodeBudget.init(4, 100);
    try std.testing.expectError(
        error.StructuralBudgetExceeded,
        ctValueToStmtBudgeted(alloc, &interner, assignment, &budget),
    );
}

test "ctValueToPattern returns structured budget exhaustion for deeply nested CtValues" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const leaf = try makeTuple3(alloc, &store, .{ .int = 1 }, try emptyList(alloc, &store), .nil);
    const nested = try wrapCtInNestedListsForScopeTransformTest(alloc, &store, leaf, 5);
    var budget = CtValueDecodeBudget.init(3, 100);
    try std.testing.expectError(
        error.StructuralBudgetExceeded,
        ctValueToPatternBudgeted(alloc, &interner, nested, &budget),
    );
}

test "ctValueToTypeExpr returns structured budget exhaustion for deeply nested CtValues" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const nested = try makeNestedTypeListCtForDecodeTest(alloc, &store, .{ .atom = "i64" }, 5);
    var budget = CtValueDecodeBudget.init(3, 100);
    try std.testing.expectError(
        error.StructuralBudgetExceeded,
        ctValueToTypeExprBudgeted(alloc, &interner, nested, &budget),
    );
}

test "ctValueToStructItem returns structured budget exhaustion for deeply nested CtValues" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const return_type = try makeNestedTypeListCtForDecodeTest(alloc, &store, .{ .atom = "i64" }, 5);
    const function_item = try makeFunctionStructItemCtForDecodeTest(alloc, &store, return_type);
    var budget = CtValueDecodeBudget.init(4, 100);
    try std.testing.expectError(
        error.StructuralBudgetExceeded,
        ctValueToStructItemBudgeted(alloc, &interner, function_item, &budget),
    );
}

test "CtValue decode returns structured budget exhaustion when node budget is exhausted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const wide = try makeList(alloc, &store, &.{
        .{ .int = 1 },
        .{ .int = 2 },
        .{ .int = 3 },
        .{ .int = 4 },
    });
    var budget = CtValueDecodeBudget.init(100, 3);
    try std.testing.expectError(
        error.StructuralBudgetExceeded,
        ctValueToExprBudgeted(alloc, &interner, wide, &budget),
    );
}

test "CtValue decode budget preserves normal expression decoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};
    defer store.deinit(alloc);

    const nested = try makeList(alloc, &store, &.{.{ .int = 2 }});
    const value = try makeList(alloc, &store, &.{ .{ .int = 1 }, nested });
    var budget = CtValueDecodeBudget.init(16, 64);
    const decoded = try ctValueToExprBudgeted(alloc, &interner, value, &budget);

    try std.testing.expect(decoded.* == .list);
    try std.testing.expectEqual(@as(usize, 2), decoded.list.elements.len);
    try std.testing.expect(decoded.list.elements[0].* == .int_literal);
    try std.testing.expectEqual(@as(i64, 1), decoded.list.elements[0].int_literal.value);
    try std.testing.expect(decoded.list.elements[1].* == .list);
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

test "round-trip: NodeMeta.scopes survives CtValue conversion" {
    // Hygiene scope sets must round-trip through quote substitution so
    // identifiers preserve their Flatt-2016 marks across macro expansion.
    // Empty sets stay empty; populated sets retain identity (member set
    // equality, sorted invariant intact).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    var scopes: scope_mod.ScopeSet = .empty;
    try scopes.add(alloc, 5);
    try scopes.add(alloc, 1);
    try scopes.add(alloc, 3);
    // After adds the set is {1, 3, 5} in sorted order.

    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .int_literal = .{
        .meta = .{
            .span = .{ .start = 100, .end = 102, .line = 4, .col = 9, .source_id = null },
            .scopes = scopes,
        },
        .value = 7,
    } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .int_literal);
    const got = back.int_literal.meta.scopes;
    try std.testing.expectEqual(@as(usize, 3), got.len());
    try std.testing.expect(got.contains(1));
    try std.testing.expect(got.contains(3));
    try std.testing.expect(got.contains(5));
    try std.testing.expect(!got.contains(2));
    // Sorted invariant: slice is monotonically increasing.
    const slice = got.slice();
    try std.testing.expectEqual(@as(scope_mod.ScopeId, 1), slice[0]);
    try std.testing.expectEqual(@as(scope_mod.ScopeId, 3), slice[1]);
    try std.testing.expectEqual(@as(scope_mod.ScopeId, 5), slice[2]);
}

test "round-trip: empty NodeMeta.scopes stays empty" {
    // The encoding must omit the `scopes` keyword pair when the set is
    // empty so pre-hygiene CtValues stay byte-compatible (existing
    // equality checks elsewhere in the macro engine compare meta lists
    // structurally).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .int_literal = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .value = 1,
    } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .int_literal);
    try std.testing.expect(back.int_literal.meta.scopes.isEmpty());
}

test "round-trip: span byte offsets and source_id survive CtValue conversion" {
    // Source spans round-trip through CtValue so error reports on
    // macro-rehydrated AST point at the original source location, not
    // line 1 col 0. Before this contract, `keywordListToMeta` zeroed
    // start/end and dropped source_id — every diagnostic emitted on
    // post-fixpoint AST collapsed to the file origin.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .int_literal = .{
        .meta = .{ .span = .{ .start = 142, .end = 145, .line = 7, .col = 12, .source_id = 3 } },
        .value = 42,
    } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .int_literal);
    const span = back.int_literal.meta.span;
    try std.testing.expectEqual(@as(u32, 142), span.start);
    try std.testing.expectEqual(@as(u32, 145), span.end);
    try std.testing.expectEqual(@as(u32, 7), span.line);
    try std.testing.expectEqual(@as(u32, 12), span.col);
    try std.testing.expect(span.source_id != null);
    try std.testing.expectEqual(@as(u32, 3), span.source_id.?);
}

test "ctValueToExpr rejects negative function-ref arity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);

    const empty_meta_elems = [_]CtValue{};
    const empty_meta = CtValue{ .list = .{ .alloc_id = 0, .elems = &empty_meta_elems } };
    const arg_elems = [_]CtValue{ .{ .atom = "target" }, .{ .int = -1 } };
    const args = CtValue{ .list = .{ .alloc_id = 0, .elems = &arg_elems } };
    const tuple_elems = [_]CtValue{ .{ .atom = "&" }, empty_meta, args };
    const value = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &tuple_elems } };

    try std.testing.expectError(error.InvalidCtValueInteger, ctValueToExpr(alloc, &interner, value));
}

test "ctValueToExpr rejects negative span metadata integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);

    const pair_elems = [_]CtValue{ .{ .atom = "start" }, .{ .int = -1 } };
    const pair = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &pair_elems } };
    const meta_elems = [_]CtValue{pair};
    const meta = CtValue{ .list = .{ .alloc_id = 0, .elems = &meta_elems } };
    const tuple_elems = [_]CtValue{ .{ .atom = "x" }, meta, CtValue.nil };
    const value = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &tuple_elems } };

    try std.testing.expectError(error.InvalidCtValueInteger, ctValueToExpr(alloc, &interner, value));
}

test "ctValueToExpr rejects negative hygiene scope ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);

    const scope_elems = [_]CtValue{.{ .int = -1 }};
    const scopes = CtValue{ .list = .{ .alloc_id = 0, .elems = &scope_elems } };
    const pair_elems = [_]CtValue{ .{ .atom = "scopes" }, scopes };
    const pair = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &pair_elems } };
    const meta_elems = [_]CtValue{pair};
    const meta = CtValue{ .list = .{ .alloc_id = 0, .elems = &meta_elems } };
    const tuple_elems = [_]CtValue{ .{ .atom = "x" }, meta, CtValue.nil };
    const value = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &tuple_elems } };

    try std.testing.expectError(error.InvalidCtValueInteger, ctValueToExpr(alloc, &interner, value));
}

test "ctValueToExpr rejects unsupported and malformed CtValue shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);

    try std.testing.expectError(error.InvalidCtValueShape, ctValueToExpr(alloc, &interner, .void));

    const tuple_elems = [_]CtValue{.{ .atom = "x" }};
    const malformed_tuple = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &tuple_elems } };
    try std.testing.expectError(error.InvalidCtValueShape, ctValueToExpr(alloc, &interner, malformed_tuple));

    const malformed_meta_elems = [_]CtValue{ .{ .atom = "x" }, .{ .int = 0 }, CtValue.nil };
    const malformed_meta = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &malformed_meta_elems } };
    try std.testing.expectError(error.InvalidCtValueShape, ctValueToExpr(alloc, &interner, malformed_meta));

    const empty_meta_elems = [_]CtValue{};
    const empty_meta = CtValue{ .list = .{ .alloc_id = 0, .elems = &empty_meta_elems } };
    const malformed_args_elems = [_]CtValue{ .{ .atom = "call" }, empty_meta, .{ .int = 1 } };
    const malformed_args = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &malformed_args_elems } };
    try std.testing.expectError(error.InvalidCtValueShape, ctValueToExpr(alloc, &interner, malformed_args));
}

test "ctValueToPattern rejects malformed CtValue shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    try std.testing.expectError(error.InvalidCtValueShape, ctValueToPattern(alloc, &interner, .void));

    const malformed_tuple = try makeTuple3(alloc, &store, .void, try emptyList(alloc, &store), .nil);
    try std.testing.expectError(error.InvalidCtValueShape, ctValueToPattern(alloc, &interner, malformed_tuple));
}

test "ctValueToCaseClause rejects malformed CtValue shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    try std.testing.expectError(error.InvalidCtValueShape, ctValueToCaseClause(alloc, &interner, .void));

    const empty_patterns = try emptyList(alloc, &store);
    const body_value = CtValue{ .int = 1 };
    const arrow_args = try makeList(alloc, &store, &.{ empty_patterns, body_value });
    const malformed_clause = try makeTuple3(alloc, &store, .{ .atom = "->" }, try emptyList(alloc, &store), arrow_args);
    try std.testing.expectError(error.InvalidCtValueShape, ctValueToCaseClause(alloc, &interner, malformed_clause));
}

test "ctValueToTypeExpr rejects malformed CtValue shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);

    try std.testing.expectError(error.InvalidCtValueShape, ctValueToTypeExpr(alloc, &interner, .void));
}

test "ctValueToExpr rejects malformed direct struct-ref type args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const malformed_type_args = try makeList(alloc, &store, &.{.void});
    const type_args_pair = try makeKeywordPair(alloc, &store, "type_args", malformed_type_args);
    const meta = try makeList(alloc, &store, &.{type_args_pair});
    const alias_parts = try makeList(alloc, &store, &.{.{ .atom = "Option" }});
    const value = try makeTuple3(alloc, &store, .{ .atom = "__aliases__" }, meta, alias_parts);

    try std.testing.expectError(error.InvalidCtValueShape, ctValueToExpr(alloc, &interner, value));
}

test "ctValueToExpr rejects malformed callee struct-ref type args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const malformed_type_args = try makeList(alloc, &store, &.{.void});
    const type_args_pair = try makeKeywordPair(alloc, &store, "type_args", malformed_type_args);
    const aliases_meta = try makeList(alloc, &store, &.{type_args_pair});
    const alias_parts = try makeList(alloc, &store, &.{ .{ .atom = "Option" }, .{ .atom = "Some" } });
    const aliases = try makeTuple3(alloc, &store, .{ .atom = "__aliases__" }, aliases_meta, alias_parts);
    const value = try makeTuple3(alloc, &store, aliases, try emptyList(alloc, &store), try emptyList(alloc, &store));

    try std.testing.expectError(error.InvalidCtValueShape, ctValueToExpr(alloc, &interner, value));
}

test "ctValueToExpr propagates struct item decode shape errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const pattern = try makeTuple3(alloc, &store, .{ .atom = "value" }, try emptyList(alloc, &store), .nil);
    const typed_param_args = try makeList(alloc, &store, &.{ pattern, .{ .int = 1 } });
    const typed_param = try makeTuple3(alloc, &store, .{ .atom = "::" }, try emptyList(alloc, &store), typed_param_args);
    const params = try makeList(alloc, &store, &.{typed_param});
    const head = try makeTuple3(alloc, &store, .{ .atom = "generated" }, try emptyList(alloc, &store), params);
    const clause_args = try makeList(alloc, &store, &.{ head, try emptyList(alloc, &store) });
    const clause = try makeTuple3(alloc, &store, .{ .atom = "->" }, try emptyList(alloc, &store), clause_args);
    const value = try makeTuple3(alloc, &store, .{ .atom = "fn" }, try emptyList(alloc, &store), try makeList(alloc, &store, &.{clause}));

    try std.testing.expectError(error.InvalidCtValueShape, ctValueToExpr(alloc, &interner, value));
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

test "round-trip: parametric variant constructor call (Option(i64).Some(42))" {
    // G4: `Option(i64).Some(42)` parses to a `.call` whose callee is a
    // `struct_ref { name.parts = [Option, Some], type_args = [i64] }`.
    // The encoder turns the callee into a `{:__aliases__, meta, [...]}`
    // CtValue; the decoder must recognise an `__aliases__` form sitting
    // in the call's *form* slot and rebuild the variant-constructor
    // call (callee struct_ref + args). Before the fix the decoder hit
    // the "unrecognised non-atom form" fallback and emitted `nil`,
    // collapsing the whole construction to a `nil_literal` — the
    // `zap test` "argument 1 expects Option({type_var}), got Nil" bug.
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const meta = ast.NodeMeta{ .span = span };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const option_id = try interner.intern("Option");
    const some_id = try interner.intern("Some");
    const i64_id = try interner.intern("i64");

    const i64_type = try alloc.create(ast.TypeExpr);
    i64_type.* = .{ .name = .{ .meta = meta, .name = i64_id, .args = &.{} } };
    const type_args = try alloc.alloc(*const ast.TypeExpr, 1);
    type_args[0] = i64_type;

    const parts = try alloc.alloc(ast.StringId, 2);
    parts[0] = option_id;
    parts[1] = some_id;

    const callee = try alloc.create(ast.Expr);
    callee.* = .{ .struct_ref = .{
        .meta = meta,
        .name = .{ .parts = parts, .span = span },
        .type_args = type_args,
    } };

    const arg = try alloc.create(ast.Expr);
    arg.* = .{ .int_literal = .{ .meta = meta, .value = 42 } };
    const args = try alloc.alloc(*const ast.Expr, 1);
    args[0] = arg;

    const orig = try alloc.create(ast.Expr);
    orig.* = .{ .call = .{ .meta = meta, .callee = callee, .args = args } };

    const ct = try exprToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToExpr(alloc, &interner, ct);

    try std.testing.expect(back.* == .call);
    try std.testing.expect(back.call.callee.* == .struct_ref);
    try std.testing.expectEqual(@as(usize, 2), back.call.callee.struct_ref.name.parts.len);
    try std.testing.expect(std.mem.eql(u8, interner.get(back.call.callee.struct_ref.name.parts[0]), "Option"));
    try std.testing.expect(std.mem.eql(u8, interner.get(back.call.callee.struct_ref.name.parts[1]), "Some"));
    try std.testing.expectEqual(@as(usize, 1), back.call.callee.struct_ref.type_args.len);
    try std.testing.expectEqual(@as(usize, 1), back.call.args.len);
    try std.testing.expect(back.call.args[0].* == .int_literal);
    try std.testing.expectEqual(@as(i64, 42), back.call.args[0].int_literal.value);
}

test "round-trip: tagged-union variant pattern (Option.Some(v))" {
    // G4 (pattern half): a `case` arm pattern `Option.Some(v)` is a
    // `tagged_union_variant` pattern (qualifier `[Option, Some]`,
    // payload bind `v`). The encoder emits `{:variant, meta, [aliases,
    // payload]}`; the decoder must rebuild the variant pattern with its
    // payload binding intact. Before the fix the decoder had no
    // `variant` arm and fell through to a bare `wildcard`, dropping the
    // `v` binding — so the arm body `-> v` referenced an undefined
    // value and lowering produced "expected type 'i64', found 'void'"
    // for the destructuring tests in option_test.zap / result_test.zap.
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const meta = ast.NodeMeta{ .span = span };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    var store = AllocationStore{};

    const option_id = try interner.intern("Option");
    const some_id = try interner.intern("Some");
    const v_id = try interner.intern("v");

    const parts = try alloc.alloc(ast.StringId, 2);
    parts[0] = option_id;
    parts[1] = some_id;

    const payload = try alloc.create(ast.Pattern);
    payload.* = .{ .bind = .{ .meta = meta, .name = v_id } };

    const orig = try alloc.create(ast.Pattern);
    orig.* = .{ .tagged_union_variant = .{
        .meta = meta,
        .qualifier = .{ .parts = parts, .span = span },
        .payload = payload,
    } };

    const ct = try patternToCtValue(alloc, &interner, &store, orig);
    const back = try ctValueToPattern(alloc, &interner, ct);

    try std.testing.expect(back.* == .tagged_union_variant);
    try std.testing.expectEqual(@as(usize, 2), back.tagged_union_variant.qualifier.parts.len);
    try std.testing.expect(std.mem.eql(u8, interner.get(back.tagged_union_variant.qualifier.parts[0]), "Option"));
    try std.testing.expect(std.mem.eql(u8, interner.get(back.tagged_union_variant.qualifier.parts[1]), "Some"));
    try std.testing.expect(back.tagged_union_variant.payload != null);
    try std.testing.expect(back.tagged_union_variant.payload.?.* == .bind);
    try std.testing.expect(std.mem.eql(u8, interner.get(back.tagged_union_variant.payload.?.bind.name), "v"));
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
    const back = try ctValueToStructItem(alloc, &interner, ct);
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
    const back = try ctValueToStructItem(alloc, &interner, ct);
    try std.testing.expect(back != null);
    try std.testing.expect(back.? == .struct_decl);
}
