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
const scope = @import("scope.zig");
const ir = @import("ir.zig");
const CtValue = ctfe.CtValue;
const AllocationStore = ctfe.AllocationStore;
const Allocator = std.mem.Allocator;

pub const MacroEvalError = error{
    EvalFailed,
    OutOfMemory,
};

/// Side channel for `Struct.*` intrinsics: lets the evaluator reach the
/// scope graph and the current struct's `StructEntry`. The macro
/// engine populates this before invoking `eval`; non-macro callers
/// (legacy CTFE attribute evaluation) leave it null and the
/// intrinsics fall back to evaluator-local behavior or no-ops.
pub const StructContext = struct {
    graph: *scope.ScopeGraph,
    interner: *ast.StringInterner,
    /// Lexical struct scope used to resolve unqualified function and
    /// macro helper calls while evaluating macro code.
    current_struct_scope: ?scope.ScopeId = null,
    /// Struct scope that struct attribute intrinsics should read and
    /// write. This can differ from `current_struct_scope` when a macro
    /// helper is evaluated in its provider struct but still needs to
    /// mutate the caller struct being expanded.
    attribute_struct_scope: ?scope.ScopeId = null,
};

pub const Env = struct {
    alloc: Allocator,
    store: *AllocationStore,
    bindings: std.StringHashMap(CtValue),
    struct_ctx: ?StructContext = null,
    /// IR program containing Zap functions compiled before the
    /// current macro expansion. Qualified Zap function calls are
    /// executed through this program when available.
    compiled_program: ?*const ir.Program = null,
    /// Recursion depth for comptime function dispatch. Bumped each
    /// time `dispatchComptimeCall` recurses into another function.
    /// Limits runaway evaluation of recursive functions.
    dispatch_depth: u32 = 0,
    /// Capability set of the macro currently being evaluated. Top-level
    /// (non-macro) callers — manifest evaluation, attribute computation,
    /// hook fixtures — leave this at the build cap (full set) so they
    /// retain the legacy "anything goes" behavior. Evaluation of a
    /// macro body sets this to the family's `required_caps` before
    /// running the body so impure intrinsics can refuse expansion when
    /// the macro has not declared the matching capability.
    current_macro_caps: ctfe.CapabilitySet = ctfe.CapabilitySet.build,
    /// Name of the macro family currently expanding, for diagnostics.
    /// Null when not inside a macro body.
    current_macro_name: ?[]const u8 = null,
    /// Source span of the macro call site, for diagnostics.
    current_macro_span: ?ast.SourceSpan = null,
    /// Last capability-violation message produced during eval. The
    /// surface-level macro engine queries this to forward a precise
    /// diagnostic when expansion fails. Owned by `alloc`.
    last_capability_error: ?[]const u8 = null,

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

        if (form != .atom) {
            if (args == .list) {
                if (try dispatchQualifiedComptimeCall(env, form, args.list.elems)) |result| {
                    return result;
                }
            }
            return value;
        }
        const form_name = form.atom;

        // quote: return the body as AST data, eagerly substituting
        // unquote/unquote_splicing nodes against the current env.
        //
        // Eager substitution makes patterns like:
        //
        //     _expanded = for _t <- _stmts {
        //       quote { ... unquote(_t) ... }
        //     }
        //
        // capture `_t`'s value at the moment of iteration. Without it
        // the loop variable would be cleaned up by the for-comp before
        // the macro-end substitution pass ran, leaving the unquote
        // node dangling.  The macro-end substitute then sees a tree
        // with no remaining unquote nodes and is a no-op for trees
        // produced this way. Pre-existing macros that build a single
        // `quote` template with `unquote(arg)` (where `arg` is bound
        // for the entire macro body) get the same result either way.
        //
        // Result shape mirrors `evaluateMacroBodyToCtValue`'s fast
        // path:
        //   - 1 stmt body → unwrap to the single CtValue
        //   - N stmts body → wrap in `{:__block__, [], [stmts...]}`
        //   so a macro returning `quote { stmt1; stmt2 }` produces a
        //   block (not a list literal) that the engine knows how to
        //   flatten into multiple struct items.
        if (std.mem.eql(u8, form_name, "quote")) {
            if (args == .list and args.list.elems.len == 1) {
                const substituted = try substituteUnquotesEval(env, args.list.elems[0]);
                if (substituted == .list) {
                    if (substituted.list.elems.len == 1) {
                        return substituted.list.elems[0];
                    }
                    if (substituted.list.elems.len > 1) {
                        const empty = ast_data.emptyList(env.alloc, env.store) catch return MacroEvalError.OutOfMemory;
                        return ast_data.makeTuple3(
                            env.alloc,
                            env.store,
                            .{ .atom = "__block__" },
                            empty,
                            substituted,
                        ) catch return MacroEvalError.OutOfMemory;
                    }
                }
                return substituted;
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

        if (isDisallowedUnderscoreComptimeCallName(form_name)) {
            env.last_capability_error = std.fmt.allocPrint(
                env.alloc,
                "cannot call underscore-prefixed function `{s}` from macro code",
                .{form_name},
            ) catch return MacroEvalError.EvalFailed;
            return MacroEvalError.EvalFailed;
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

            // list_at(list, index) — element at zero-based index,
            // or nil when out of range. Negative indices count from the
            // end (`-1` = last). Lifts the bare-int conventions from Zig
            // into macro space so library code can write `list_at(args, 0)`
            // to take the first matching call.
            if (std.mem.eql(u8, form_name, "list_at")) {
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

            // list_length(list) — element count as a bare int.
            // Returns 0 for non-lists so callers can chain it through
            // `==` / `>` without first checking shape.
            if (std.mem.eql(u8, form_name, "list_length")) {
                if (arg_elems.len == 1) {
                    const list = try eval(env, arg_elems[0]);
                    if (list == .list) return CtValue{ .int = @intCast(list.list.elems.len) };
                    return CtValue{ .int = 0 };
                }
            }

            // list_empty?(list) — true iff the list has no elements.
            // Non-list values are treated as empty so callers don't have
            // to distinguish "empty list" from "wrong shape".
            if (std.mem.eql(u8, form_name, "list_empty?")) {
                if (arg_elems.len == 1) {
                    const list = try eval(env, arg_elems[0]);
                    if (list == .list) return CtValue{ .bool_val = list.list.elems.len == 0 };
                    return CtValue{ .bool_val = true };
                }
            }

            // list_concat(left, right) — concatenate two lists.
            // Non-list operands are treated as empty: a nil setup_body
            // can be concatenated freely without an outer guard.
            if (std.mem.eql(u8, form_name, "list_concat")) {
                if (arg_elems.len == 2) {
                    const left = try eval(env, arg_elems[0]);
                    const right = try eval(env, arg_elems[1]);
                    const left_elems: []const CtValue = if (left == .list) left.list.elems else &.{};
                    const right_elems: []const CtValue = if (right == .list) right.list.elems else &.{};
                    const total = left_elems.len + right_elems.len;
                    var combined = try env.alloc.alloc(CtValue, total);
                    @memcpy(combined[0..left_elems.len], left_elems);
                    @memcpy(combined[left_elems.len..], right_elems);
                    const id = env.store.alloc(env.alloc, .list, null);
                    return CtValue{ .list = .{ .alloc_id = id, .elems = combined } };
                }
            }

            // list_flatten(list_of_lists) — flatten one level.
            // Non-list outer is empty; non-list inner elements are
            // appended as singletons so a mixed list `[item, [a, b]]`
            // flattens to `[item, a, b]`. Useful for for-comp bodies
            // that yield variable-arity lists per iteration.
            if (std.mem.eql(u8, form_name, "list_flatten")) {
                if (arg_elems.len == 1) {
                    const outer = try eval(env, arg_elems[0]);
                    if (outer != .list) return CtValue{ .list = .{ .alloc_id = env.store.alloc(env.alloc, .list, null), .elems = &.{} } };
                    var total: usize = 0;
                    for (outer.list.elems) |e| {
                        total += if (e == .list) e.list.elems.len else 1;
                    }
                    var combined = try env.alloc.alloc(CtValue, total);
                    var idx: usize = 0;
                    for (outer.list.elems) |e| {
                        if (e == .list) {
                            @memcpy(combined[idx .. idx + e.list.elems.len], e.list.elems);
                            idx += e.list.elems.len;
                        } else {
                            combined[idx] = e;
                            idx += 1;
                        }
                    }
                    const id = env.store.alloc(env.alloc, .list, null);
                    return CtValue{ .list = .{ .alloc_id = id, .elems = combined } };
                }
            }

            // map_get(map, key, default) — fetch a compile-time
            // map entry by key, returning the caller-provided default
            // when the value is absent or the first argument is not a map.
            if (std.mem.eql(u8, form_name, "map_get")) {
                if (arg_elems.len == 3) {
                    const map_value = try eval(env, arg_elems[0]);
                    const lookup_key = unwrapAstLiteral(try eval(env, arg_elems[1]));
                    const default_value = try eval(env, arg_elems[2]);
                    if (map_value == .map) {
                        for (map_value.map.entries) |entry| {
                            if (ctMapKeyEql(entry.key, lookup_key)) {
                                return entry.value;
                            }
                        }
                    }
                    return default_value;
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

            // Struct attribute intrinsics — callable from within macro
            // bodies to read/write the current struct's compile-time
            // attribute table. Inert when no struct context is wired
            // through `env.struct_ctx` (legacy CTFE callers).
            //
            // The user-facing API lives in Zap (`Struct.put_attribute`,
            // etc.) and lowers to these underscore-prefixed names via
            // ordinary macros in lib/. The compiler stays
            // language-agnostic about the wrappers' shape; it only
            // implements the storage primitive.
            if (std.mem.eql(u8, form_name, "struct_put_attribute")) {
                return structIntrinsicPut(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "struct_get_attribute")) {
                return structIntrinsicGet(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "struct_register_attribute")) {
                return structIntrinsicRegister(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "source_graph_structs")) {
                return sourceGraphStructsIntrinsic(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "source_graph_protocols")) {
                return sourceGraphProtocolsIntrinsic(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "source_graph_unions")) {
                return sourceGraphUnionsIntrinsic(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "struct_functions")) {
                return structFunctionsIntrinsic(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "struct_macros")) {
                return structMacrosIntrinsic(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "struct_info")) {
                return structInfoIntrinsic(env, arg_elems);
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
            if (std.mem.eql(u8, form_name, "atom_name")) {
                return atomNameIntrinsic(env, arg_elems);
            }

            // make_call(form_name_string, args_list) — build a
            // 3-tuple AST node `{atom(form_name), [], args}`. The form
            // atom is stored WITHOUT the leading `:` that disambiguates
            // atom literals from variable refs in AST encoding, so the
            // result round-trips as a call/operator/assignment node
            // (e.g., `make_call("=", [target, value])` produces
            // the same shape as the parser emits for `target = value`).
            //
            // Distinct from `tuple(...)` which evaluates each argument
            // and may wrap atom literals in 3-tuple wrappers — that
            // shape is wrong for AST node construction. A separate
            // primitive keeps both useful: `tuple` for data tuples,
            // `make_call` for AST nodes.
            if (std.mem.eql(u8, form_name, "make_call")) {
                if (arg_elems.len == 2) {
                    const name_raw = try eval(env, arg_elems[0]);
                    const args_raw = try eval(env, arg_elems[1]);
                    const name_str = extractString(name_raw) orelse return .nil;
                    const dup = env.alloc.alloc(u8, name_str.len) catch return .nil;
                    @memcpy(dup, name_str);
                    const empty = ast_data.emptyList(env.alloc, env.store) catch return .nil;
                    const args_list: CtValue = if (args_raw == .list) args_raw else empty;
                    return ast_data.makeTuple3(env.alloc, env.store, .{ .atom = dup }, empty, args_list) catch return .nil;
                }
            }
            if (std.mem.eql(u8, form_name, "slugify")) {
                return slugifyIntrinsic(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "intern_atom")) {
                return internAtomIntrinsic(env, arg_elems);
            }

            // read_file(path) — read a file at compile time.
            // Gated by the `read_file` capability. The first impure
            // intrinsic in the macro language: a macro that calls this
            // must declare `@requires = [:read_file]`, otherwise
            // expansion fails with a capability_violation diagnostic.
            // Returns a `string` CtValue containing the file's bytes.
            //
            // Resource bound: the read is capped at 1 MiB to keep
            // comptime evaluation deterministic — a multi-gig file
            // would silently extend build time and explode allocator
            // pressure. Authors who need larger inputs should chunk.
            if (std.mem.eql(u8, form_name, "read_file")) {
                if (arg_elems.len != 1) return MacroEvalError.EvalFailed;
                if (!env.current_macro_caps.has(.read_file)) {
                    const caller = env.current_macro_name orelse "<top-level>";
                    const msg = std.fmt.allocPrint(
                        env.alloc,
                        "macro `{s}` calls `read_file` but does not declare `@requires = [:read_file]` — add the capability to allow compile-time file reads",
                        .{caller},
                    ) catch return MacroEvalError.EvalFailed;
                    env.last_capability_error = msg;
                    return MacroEvalError.EvalFailed;
                }
                const path_raw = try eval(env, arg_elems[0]);
                const path_ct = unwrapAstLiteral(path_raw);
                if (path_ct != .string) return MacroEvalError.EvalFailed;
                const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path_ct.string, env.alloc, .limited(1 << 20)) catch |err| {
                    const caller = env.current_macro_name orelse "<top-level>";
                    const msg = std.fmt.allocPrint(
                        env.alloc,
                        "`read_file` in macro `{s}` failed to read `{s}`: {s}",
                        .{ caller, path_ct.string, @errorName(err) },
                    ) catch return MacroEvalError.EvalFailed;
                    env.last_capability_error = msg;
                    return MacroEvalError.EvalFailed;
                };
                return CtValue{ .string = bytes };
            }

            // debug_value(label, value) — comptime debug print to stderr.
            // Returns the evaluated value so it can be wrapped around an
            // existing expression: `_x = debug_value("setup", elem(body, 2))`.
            // Useful for inspecting CtValue shapes while authoring macros.
            if (std.mem.eql(u8, form_name, "debug_value")) {
                if (arg_elems.len == 2) {
                    const label_raw = try eval(env, arg_elems[0]);
                    const value_raw = try eval(env, arg_elems[1]);
                    const label_unwrapped = unwrapAstLiteral(label_raw);
                    const label_str = if (label_unwrapped == .string) label_unwrapped.string else "<dbg>";
                    std.debug.print("[ZAP_DBG] {s}: ", .{label_str});
                    debugPrintCtValue(value_raw, 3);
                    std.debug.print("\n", .{});
                    return value_raw;
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

        // Unary operators. Unwrap AST-literal wrappers so a unary
        // minus applied to a literal `-1` (encoded as `{:-, meta,
        // [{1, [], nil}]}`) reduces to a bare `.int = -1` rather
        // than surviving as the unevaluated tuple. Without unwrapping,
        // downstream comparisons (`list_at(list, -1)`) fail
        // their `idx == .int` shape check and return nil — silently
        // breaking step-aware indexing.
        if (args == .list and args.list.elems.len == 1) {
            const operand_raw = try eval(env, args.list.elems[0]);
            const operand = unwrapAstLiteral(operand_raw);
            if (std.mem.eql(u8, form_name, "-") and operand == .int) {
                return CtValue{ .int = -operand.int };
            }
            if (std.mem.eql(u8, form_name, "not") and operand == .bool_val) {
                return CtValue{ .bool_val = !operand.bool_val };
            }
        }

        // Comptime function dispatch: unknown form is a function name
        // visible in the current struct's scope. Look up the function
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

fn isDisallowedUnderscoreComptimeCallName(name: []const u8) bool {
    if (name.len == 0 or name[0] != '_') return false;
    if (std.mem.eql(u8, name, "__block__")) return false;
    if (std.mem.eql(u8, name, "__aliases__")) return false;
    return true;
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

test "eval: quote returns data (single-stmt body unwraps)" {
    // `quote { 1 + 2 }` with a single-statement body returns the
    // statement's CtValue directly — the per-stmt list wrapper is
    // unwrapped so authors get the raw AST node, mirroring the fast
    // path in `evaluateMacroBodyToCtValue`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const one = try ast_data.makeTuple3(alloc, &store, .{ .int = 1 }, try ast_data.emptyList(alloc, &store), .nil);
    const two = try ast_data.makeTuple3(alloc, &store, .{ .int = 2 }, try ast_data.emptyList(alloc, &store), .nil);
    const add_args = try ast_data.makeList(alloc, &store, &.{ one, two });
    const add_node = try ast_data.makeTuple3(alloc, &store, .{ .atom = "+" }, try ast_data.emptyList(alloc, &store), add_args);

    const body_list = try ast_data.makeList(alloc, &store, &.{add_node});
    const quote_args = try ast_data.makeList(alloc, &store, &.{body_list});
    const quote_node = try ast_data.makeTuple3(alloc, &store, .{ .atom = "quote" }, try ast_data.emptyList(alloc, &store), quote_args);

    const result = try eval(&env, quote_node);

    // Single-stmt body is unwrapped — result is the add node tuple.
    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.elems[0] == .atom);
    try std.testing.expect(std.mem.eql(u8, result.tuple.elems[0].atom, "+"));
}

test "eval: quote with multi-stmt body wraps result in __block__" {
    // Multiple statements in a quote body get wrapped in a
    // `{:__block__, [], [stmts...]}` 3-tuple, matching the shape
    // produced by `evaluateMacroBodyToCtValue`'s fast path. This
    // lets the engine flatten nested blocks via
    // `flattenNestedBlocks` and emit each stmt as a sibling
    // struct item.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const one = try ast_data.makeTuple3(alloc, &store, .{ .int = 1 }, try ast_data.emptyList(alloc, &store), .nil);
    const two = try ast_data.makeTuple3(alloc, &store, .{ .int = 2 }, try ast_data.emptyList(alloc, &store), .nil);
    const body_list = try ast_data.makeList(alloc, &store, &.{ one, two });
    const quote_args = try ast_data.makeList(alloc, &store, &.{body_list});
    const quote_node = try ast_data.makeTuple3(alloc, &store, .{ .atom = "quote" }, try ast_data.emptyList(alloc, &store), quote_args);

    const result = try eval(&env, quote_node);

    try std.testing.expect(result == .tuple);
    try std.testing.expectEqual(@as(usize, 3), result.tuple.elems.len);
    try std.testing.expect(result.tuple.elems[0] == .atom);
    try std.testing.expectEqualStrings("__block__", result.tuple.elems[0].atom);
    try std.testing.expect(result.tuple.elems[2] == .list);
    try std.testing.expectEqual(@as(usize, 2), result.tuple.elems[2].list.elems.len);
}

// ============================================================
// Helper functions
// ============================================================

/// Eagerly substitute `unquote(expr)` and `unquote_splicing(expr)`
/// nodes within a quoted body against the macro evaluator's current
/// `env`. Used by the `quote` arm so each quote produces a
/// fully-resolved AST CtValue rather than relying on a deferred
/// substitution pass at macro-body end.
///
/// Behavior:
///   - `{:unquote, _, [inner]}` → `eval(env, inner)`
///   - `{:unquote_splicing, _, [inner]}` (only at list-element
///     positions) → splice `eval(env, inner)`'s list elements as
///     siblings.
///   - Nested `quote` nodes are NOT descended into; their unquotes
///     belong to their own quote scope and remain raw until that
///     quote is itself evaluated.
fn substituteUnquotesEval(env: *Env, value: CtValue) MacroEvalError!CtValue {
    if (value == .tuple and value.tuple.elems.len == 3) {
        const form = value.tuple.elems[0];
        const args = value.tuple.elems[2];

        if (form == .atom) {
            // Eager unquote: fully evaluate the inner expression in
            // the current env. Mirrors the semantics the engine-level
            // substituteCtValue achieves with `param_map`, but uses
            // the evaluator's full eval — so `unquote(elem(_t, 2))`
            // resolves the `elem` call instead of bottoming out on a
            // bare `param_map.get(name)` lookup.
            if (std.mem.eql(u8, form.atom, "unquote")) {
                if (args == .list and args.list.elems.len == 1) {
                    return eval(env, args.list.elems[0]);
                }
            }
            // Top-level unquote_splicing inside a quote with a single
            // stmt body: e.g. `quote { unquote_splicing(_xs) }`. The
            // splicing is into the quote's "implicit outer list" of
            // stmts; with only one stmt there's no surrounding list,
            // so the natural reading is "return the list itself" so
            // the engine sees N siblings instead of an
            // `unquote_splicing` wrapper that survives into the AST.
            if (std.mem.eql(u8, form.atom, "unquote_splicing")) {
                if (args == .list and args.list.elems.len == 1) {
                    return eval(env, args.list.elems[0]);
                }
            }
            // Don't descend into nested quote — its body should stay
            // raw until that quote itself is evaluated, preserving
            // standard quasiquote nesting semantics.
            if (std.mem.eql(u8, form.atom, "quote")) {
                return value;
            }
        }

        const new_form = try substituteUnquotesEval(env, form);
        const new_args: CtValue = if (args == .list)
            try substituteUnquotesInList(env, args.list.elems)
        else
            args;

        const new_tuple = try env.alloc.alloc(CtValue, 3);
        new_tuple[0] = new_form;
        new_tuple[1] = value.tuple.elems[1]; // meta passes through
        new_tuple[2] = new_args;
        const id = env.store.alloc(env.alloc, .tuple, null);
        return CtValue{ .tuple = .{ .alloc_id = id, .elems = new_tuple } };
    }

    if (value == .tuple and value.tuple.elems.len == 2) {
        const new_elems = try env.alloc.alloc(CtValue, 2);
        new_elems[0] = value.tuple.elems[0];
        new_elems[1] = try substituteUnquotesEval(env, value.tuple.elems[1]);
        const id = env.store.alloc(env.alloc, .tuple, null);
        return CtValue{ .tuple = .{ .alloc_id = id, .elems = new_elems } };
    }

    if (value == .list) {
        return substituteUnquotesInList(env, value.list.elems);
    }

    return value;
}

/// Substitute unquote/unquote_splicing inside a list of CtValues,
/// splicing unquote_splicing replacements as siblings. Used both for
/// bare list values and the `args` slot of 3-tuples (where most
/// stmt-shaped CtValues store their children).
fn substituteUnquotesInList(env: *Env, elems: []const CtValue) MacroEvalError!CtValue {
    var out: std.ArrayListUnmanaged(CtValue) = .empty;
    for (elems) |elem| {
        if (elem == .tuple and elem.tuple.elems.len == 3) {
            const e_form = elem.tuple.elems[0];
            const e_args = elem.tuple.elems[2];
            if (e_form == .atom and std.mem.eql(u8, e_form.atom, "unquote_splicing")) {
                if (e_args == .list and e_args.list.elems.len == 1) {
                    const replacement = try eval(env, e_args.list.elems[0]);
                    if (replacement == .list) {
                        for (replacement.list.elems) |splice| {
                            try out.append(env.alloc, splice);
                        }
                        continue;
                    }
                    // Non-list splice replacement: surface the value
                    // as a single sibling so the caller's structural
                    // expectations aren't silently broken.
                    try out.append(env.alloc, replacement);
                    continue;
                }
            }
        }
        try out.append(env.alloc, try substituteUnquotesEval(env, elem));
    }
    const slice = try out.toOwnedSlice(env.alloc);
    const id = env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = slice } };
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
// Struct attribute intrinsics
//
// Implementation of `struct_put_attribute`,
// `struct_get_attribute`, and `struct_register_attribute`.
// These thread through `env.struct_ctx` to reach the scope graph;
// when the context is null (legacy CTFE attribute eval) they return
// nil so user macros wrapping them gracefully no-op.
// ============================================================

fn structIntrinsicPut(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 2) return .nil;
    const name_val = try eval(env, args[0]);
    const value_ct = try eval(env, args[1]);
    const ctx = env.struct_ctx orelse return .nil;
    const scope_id = attributeStructScope(ctx) orelse return .nil;
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
    ctx.graph.putStructAttribute(mod_entry, name_id, cv) catch return .nil;
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
            .function_decl, .macro_decl, .import_decl, .attribute => return false,
        }
    }
    return true;
}

fn isExprComptimeSafe(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        // Literals — always safe
        .int_literal, .float_literal, .string_literal, .bool_literal, .atom_literal, .nil_literal => true,
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
        // namespace are NEVER comptime-safe; struct-qualified Zap
        // calls (`Foo.bar(args)`) are conservatively rejected for
        // now since dispatch doesn't yet route through struct refs.
        .call => |c| isCallComptimeSafe(c),
        // Range, list-cons, struct construction — pure shape
        .range => |r| {
            if (!isExprComptimeSafe(r.start)) return false;
            if (!isExprComptimeSafe(r.end)) return false;
            if (r.step) |s| if (!isExprComptimeSafe(s)) return false;
            return true;
        },
        .list_cons_expr => |c| isExprComptimeSafe(c.head) and isExprComptimeSafe(c.tail),
        // Quote/unquote/splicing — the macro evaluator handles all
        // three forms directly: quote returns its body as data, and
        // unquote/unquote_splicing only fire inside quote. Treating
        // them as comptime-safe lets user-defined macros that
        // construct AST (`quote { ... }`) be invoked from another
        // macro body via comptime dispatch — without this, helper
        // macros like `__describe_wrap_test` survive as bare AST
        // calls instead of being expanded inline.
        .quote_expr, .unquote_expr, .unquote_splicing_expr => true,
        // For-comp inside a function body — defer to its own safety.
        .for_expr => |f| isExprComptimeSafe(f.iterable) and isExprComptimeSafe(f.body) and
            (f.filter == null or isExprComptimeSafe(f.filter.?)),
        // Case expression — scrutinee must be safe; each clause's
        // body must be safe. Patterns are syntactic and don't need
        // a separate safety check (they don't evaluate arbitrary
        // Zap expressions). Without this, helper macros that branch
        // on AST shape via `case elem(stmt, 0) { ... }` are rejected
        // by comptime dispatch and survive as unevaluated calls.
        .case_expr => |ce| caseBlk: {
            if (!isExprComptimeSafe(ce.scrutinee)) break :caseBlk false;
            for (ce.clauses) |clause| {
                for (clause.body) |s| {
                    switch (s) {
                        .expr => |e| if (!isExprComptimeSafe(e)) break :caseBlk false,
                        .assignment => |a| if (!isExprComptimeSafe(a.value)) break :caseBlk false,
                        else => break :caseBlk false,
                    }
                }
            }
            break :caseBlk true;
        },
        // Anything else is unrecognized — refuse conservatively.
        else => false,
    };
}

fn isCallComptimeSafe(call: anytype) bool {
    // Inspect callee shape:
    //   - var_ref: bare-name call. Safe — dispatch will recurse.
    //   - field_access on :zig: NEVER safe.
    //   - field_access on a Zap struct: may eventually be safe
    //     (cross-struct pure dispatch), but dispatch doesn't
    //     currently route through struct refs. Reject.
    //   - struct_ref or anything else: reject.
    if (call.callee.* == .var_ref) {
        // Each arg must also be safe.
        for (call.args) |arg| {
            if (!isExprComptimeSafe(arg)) return false;
        }
        return true;
    }
    if (call.callee.* == .field_access) {
        // Struct-qualified calls (`Foo.bar(args)`) and `:zig.X.Y(...)`
        // interop are conservatively rejected — comptime dispatch
        // doesn't route through field-access callees yet. When
        // cross-struct dispatch lands the safe-set widens here.
        return false;
    }
    return false;
}

fn dispatchQualifiedComptimeCall(
    env: *Env,
    form: CtValue,
    arg_forms: []const CtValue,
) MacroEvalError!?CtValue {
    const ctx = env.struct_ctx orelse return null;
    if (env.dispatch_depth >= COMPTIME_DISPATCH_MAX_DEPTH) return null;

    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    if (!try collectQualifiedSegments(env, form, &segments)) return null;
    if (segments.items.len < 2) return null;

    if (std.mem.eql(u8, segments.items[0], "zig")) return null;

    const function_name = segments.items[segments.items.len - 1];
    if (isDisallowedUnderscoreComptimeCallName(function_name)) {
        env.last_capability_error = std.fmt.allocPrint(
            env.alloc,
            "cannot call underscore-prefixed function `{s}` from macro code",
            .{function_name},
        ) catch return MacroEvalError.EvalFailed;
        return MacroEvalError.EvalFailed;
    }
    const struct_scope = findStructScopeBySegments(ctx.graph, ctx.interner, segments.items[0 .. segments.items.len - 1]) orelse return null;
    const name_id = ctx.interner.intern(function_name) catch return null;
    const arity: u32 = @intCast(arg_forms.len);
    const key = scope.FamilyKey{ .name = name_id, .arity = arity };
    const struct_scope_value = ctx.graph.getScope(struct_scope);

    if (struct_scope_value.function_families.get(key)) |family_id| {
        const family = &ctx.graph.families.items[family_id];
        if (family.visibility != .public and ctx.current_struct_scope != struct_scope) return null;
        if (try evalCompiledQualifiedFunction(env, segments.items, arg_forms)) |compiled_result| {
            return compiled_result;
        }
        if (family.clauses.items.len == 0) return null;
        const clause_ref = family.clauses.items[0];
        return evalDispatchedClause(env, &clause_ref.decl.clauses[clause_ref.clause_index], arg_forms, struct_scope, false, ctfe.CapabilitySet.build, function_name);
    }

    if (struct_scope_value.macros.get(key)) |macro_id| {
        const family = &ctx.graph.macro_families.items[macro_id];
        if (!family.required_caps.isSubsetOf(env.current_macro_caps)) {
            const caller_name = env.current_macro_name orelse "<top-level>";
            env.last_capability_error = std.fmt.allocPrint(
                env.alloc,
                "macro `{s}` requires capabilities not held by caller `{s}` — calling macro `{s}` would escalate the caller's capability set",
                .{ function_name, caller_name, function_name },
            ) catch return MacroEvalError.EvalFailed;
            return MacroEvalError.EvalFailed;
        }
        if (family.clauses.items.len == 0) return null;
        const clause_ref = family.clauses.items[0];
        const result = (try evalDispatchedClause(env, &clause_ref.decl.clauses[clause_ref.clause_index], arg_forms, struct_scope, true, family.required_caps, function_name)) orelse return null;
        if (isCompileTimeIntrinsicExpansion(result)) {
            return try eval(env, result);
        }
        return result;
    }

    return null;
}

fn evalCompiledQualifiedFunction(
    env: *Env,
    segments: []const []const u8,
    arg_forms: []const CtValue,
) MacroEvalError!?CtValue {
    const program = env.compiled_program orelse return null;
    if (segments.len < 2) return null;

    const compiled_name = try compiledFunctionName(env.alloc, segments, arg_forms.len);
    var interpreter = ctfe.Interpreter.init(env.alloc, program);
    defer interpreter.deinit();
    if (env.struct_ctx) |ctx| {
        interpreter.scope_graph = ctx.graph;
        interpreter.interner = ctx.interner;
        interpreter.current_struct_scope = attributeStructScope(ctx);
    }
    interpreter.capabilities = env.current_macro_caps;
    interpreter.steps_remaining = interpreter.step_budget;
    if (!interpreter.function_by_name.contains(compiled_name)) return null;

    var arg_values = env.alloc.alloc(CtValue, arg_forms.len) catch return MacroEvalError.OutOfMemory;
    defer env.alloc.free(arg_values);
    for (arg_forms, 0..) |form, index| {
        arg_values[index] = try eval(env, form);
    }

    return interpreter.evalByName(compiled_name, arg_values) catch |err| {
        if (interpreter.errors.items.len > 0) {
            env.last_capability_error = ctfe.formatCtfeError(env.alloc, interpreter.errors.items[0]) catch
                std.fmt.allocPrint(env.alloc, "compiled Zap function CTFE failed: {s}", .{@errorName(err)}) catch
                return MacroEvalError.EvalFailed;
            return MacroEvalError.EvalFailed;
        }
        return null;
    };
}

fn compiledFunctionName(
    allocator: Allocator,
    segments: []const []const u8,
    arity: usize,
) MacroEvalError![]const u8 {
    var struct_prefix: std.ArrayListUnmanaged(u8) = .empty;
    for (segments[0 .. segments.len - 1], 0..) |segment, index| {
        if (index > 0) try struct_prefix.append(allocator, '_');
        try struct_prefix.appendSlice(allocator, segment);
    }

    const raw_function_name = segments[segments.len - 1];
    const mangled_function_name = ir.mangleSymbolForZig(allocator, raw_function_name) catch
        return MacroEvalError.OutOfMemory;
    return std.fmt.allocPrint(
        allocator,
        "{s}__{s}__{d}",
        .{ struct_prefix.items, mangled_function_name, arity },
    ) catch return MacroEvalError.OutOfMemory;
}

fn isCompileTimeIntrinsicExpansion(value: CtValue) bool {
    if (value != .tuple or value.tuple.elems.len != 3) return false;
    const form = value.tuple.elems[0];
    if (form != .atom) return false;
    return std.mem.eql(u8, form.atom, "source_graph_structs") or
        std.mem.eql(u8, form.atom, "source_graph_protocols") or
        std.mem.eql(u8, form.atom, "source_graph_unions") or
        std.mem.eql(u8, form.atom, "struct_functions") or
        std.mem.eql(u8, form.atom, "struct_macros") or
        std.mem.eql(u8, form.atom, "struct_info");
}

fn evalDispatchedClause(
    env: *Env,
    clause: *const ast.FunctionClause,
    arg_forms: []const CtValue,
    callee_scope: scope.ScopeId,
    callee_is_macro: bool,
    callee_caps: ctfe.CapabilitySet,
    callee_name: []const u8,
) MacroEvalError!?CtValue {
    const ctx = env.struct_ctx orelse return null;
    const body = clause.body orelse return null;
    if (!isFunctionBodyComptimeSafe(body)) return null;

    var arg_cts = env.alloc.alloc(CtValue, arg_forms.len) catch return null;
    defer env.alloc.free(arg_cts);
    for (arg_forms, 0..) |form, index| {
        arg_cts[index] = eval(env, form) catch return null;
    }

    var child_env = Env.init(env.alloc, env.store);
    defer child_env.deinit();
    child_env.struct_ctx = .{
        .graph = ctx.graph,
        .interner = ctx.interner,
        .current_struct_scope = callee_scope,
        .attribute_struct_scope = attributeStructScope(ctx),
    };
    child_env.compiled_program = env.compiled_program;
    child_env.dispatch_depth = env.dispatch_depth + 1;
    if (callee_is_macro) {
        child_env.current_macro_caps = callee_caps;
        child_env.current_macro_name = callee_name;
    } else {
        child_env.current_macro_caps = env.current_macro_caps;
        child_env.current_macro_name = env.current_macro_name;
    }

    for (clause.params, 0..) |param, index| {
        if (index >= arg_cts.len) break;
        if (param.pattern.* == .bind) {
            const param_name = ctx.interner.get(param.pattern.bind.name);
            child_env.bind(param_name, arg_cts[index]) catch return null;
        }
    }

    var result: CtValue = .nil;
    for (body) |stmt| {
        const stmt_ct = ast_data.stmtToCtValue(env.alloc, ctx.interner, env.store, stmt) catch return null;
        result = eval(&child_env, stmt_ct) catch |err| {
            if (child_env.last_capability_error) |message| {
                env.last_capability_error = message;
            }
            return err;
        };
    }
    return result;
}

fn collectQualifiedSegments(
    env: *Env,
    value: CtValue,
    segments: *std.ArrayListUnmanaged([]const u8),
) MacroEvalError!bool {
    if (value == .tuple and value.tuple.elems.len == 3) {
        const form = value.tuple.elems[0];
        const args = value.tuple.elems[2];

        if (form == .atom and std.mem.eql(u8, form.atom, ".")) {
            if (args != .list or args.list.elems.len != 2) return false;
            if (!try collectQualifiedSegments(env, args.list.elems[0], segments)) return false;
            const field = args.list.elems[1];
            if (field != .atom) return false;
            try segments.append(env.alloc, stripAtomLiteralPrefix(field.atom));
            return true;
        }

        if (form == .atom and std.mem.eql(u8, form.atom, "__aliases__")) {
            if (args != .list) return false;
            for (args.list.elems) |part| {
                if (part != .atom) return false;
                try segments.append(env.alloc, stripAtomLiteralPrefix(part.atom));
            }
            return true;
        }

        if (args == .nil and form == .atom and form.atom.len > 0 and form.atom[0] == ':') {
            try segments.append(env.alloc, form.atom[1..]);
            return true;
        }
    }

    if (value == .atom) {
        try segments.append(env.alloc, stripAtomLiteralPrefix(value.atom));
        return true;
    }

    return false;
}

fn stripAtomLiteralPrefix(value: []const u8) []const u8 {
    if (value.len > 0 and value[0] == ':') return value[1..];
    return value;
}

fn findStructScopeBySegments(
    graph: *const scope.ScopeGraph,
    interner: *const ast.StringInterner,
    segments: []const []const u8,
) ?scope.ScopeId {
    for (graph.structs.items) |struct_entry| {
        if (struct_entry.name.parts.len != segments.len) continue;
        for (struct_entry.name.parts, segments) |part_id, segment| {
            if (!std.mem.eql(u8, interner.get(part_id), segment)) break;
        } else {
            return struct_entry.scope_id;
        }
    }
    return null;
}

/// Maximum recursion depth for comptime function dispatch. Prevents
/// runaway evaluation of recursive functions; mirrors the
/// `max_expansions` limit on the macro engine itself. Counted across
/// the call stack via env.dispatch_depth.
const COMPTIME_DISPATCH_MAX_DEPTH: u32 = 64;

/// Try to resolve and interpret a Zap-side function call at comptime.
/// Returns the function body's evaluated result, or null when:
///   - no struct context is available (eval is not running for a
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
    const ctx = env.struct_ctx orelse return null;
    if (env.dispatch_depth >= COMPTIME_DISPATCH_MAX_DEPTH) return null;

    const scope_id = ctx.current_struct_scope orelse ctx.graph.prelude_scope;
    const name_id = ctx.interner.intern(form_name) catch return null;
    const arity: u32 = @intCast(arg_forms.len);

    // Resolve to a function family OR a macro family. Macros and
    // functions live in separate scope tables (`function_families`
    // vs `macros`), but both use `FunctionClauseRef` for their
    // clauses, so once we have the clause body the dispatch logic
    // is identical: pre-evaluate args in the caller's env, bind to
    // the callee's params, and evaluate the body in a child env.
    //
    // Without the macro fallback, a macro-body that calls another
    // macro would land in this function, fail the function lookup,
    // and return null — causing the call to survive as unevaluated
    // AST. The outer macro returns that AST, the fixed-point loop
    // re-discovers the inner call, but by then the outer's eval env
    // is gone, so the inner macro's args bind to raw AST var-refs
    // (`{:_stmt, [], nil}`) instead of the values those locals held.
    // Resolved-callee capability set. Functions are treated as having
    // the build cap (full) — function-level capability gating is out of
    // scope for the MVP and is tracked by the type/effect system, not
    // the macro evaluator. Macros report their `required_caps`.
    var callee_caps: ctfe.CapabilitySet = ctfe.CapabilitySet.build;
    var callee_is_macro = false;

    var callee_scope = scope_id;
    const clause: *const ast.FunctionClause = blk: {
        if (ctx.graph.resolveFamily(scope_id, name_id, arity)) |fid| {
            const family = &ctx.graph.families.items[fid];
            if (family.clauses.items.len == 0) return null;
            callee_scope = family.scope_id;
            const cref = family.clauses.items[0];
            break :blk &cref.decl.clauses[cref.clause_index];
        }
        if (ctx.graph.resolveMacro(scope_id, name_id, arity)) |mid| {
            const mfamily = &ctx.graph.macro_families.items[mid];
            if (mfamily.clauses.items.len == 0) return null;
            callee_caps = mfamily.required_caps;
            callee_is_macro = true;
            callee_scope = mfamily.scope_id;
            const cref = mfamily.clauses.items[0];
            break :blk &cref.decl.clauses[cref.clause_index];
        }
        return null;
    };

    // Caller/callee attenuation: a macro may only invoke another macro
    // whose declared capabilities are a subset of its own. This is the
    // static enforcement of the boolean lattice — without it a `pure`
    // macro could indirectly perform IO by delegating to a `read_file`
    // macro, defeating the whole annotation system.
    if (callee_is_macro and !callee_caps.isSubsetOf(env.current_macro_caps)) {
        const caller_name = env.current_macro_name orelse "<top-level>";
        const msg = std.fmt.allocPrint(
            env.alloc,
            "macro `{s}` requires capabilities not held by caller `{s}` — calling macro `{s}` would escalate the caller's capability set",
            .{ form_name, caller_name, form_name },
        ) catch return null;
        env.last_capability_error = msg;
        return MacroEvalError.EvalFailed;
    }
    const body = clause.body orelse return null;

    // Purity check: refuse to dispatch a function whose body
    // contains `:zig.` interop calls, raw `panic`, or other
    // side-effecting primitives. Without this guard, eval would
    // happily process pure subtrees and leave impure subtrees as
    // unresolved AST tuples — the macro author would silently get
    // mangled output. The conservative refusal returns null, the
    // caller falls through to "leave the call as AST data" which
    // surfaces at runtime where the impure call belongs.
    if (!isFunctionBodyComptimeSafe(body)) {
        return null;
    }

    // Pre-evaluate each argument so the callee sees fully-evaluated
    // values, not AST forms still containing nested calls.
    var arg_cts = env.alloc.alloc(CtValue, arg_forms.len) catch return null;
    defer env.alloc.free(arg_cts);
    for (arg_forms, 0..) |form, i| {
        arg_cts[i] = eval(env, form) catch return null;
    }

    // Spin up a child env that inherits the same store, dispatch
    // depth (incremented), and struct_ctx, but starts with a fresh
    // bindings map populated only with the callee's parameters. The
    // child's bindings can't leak into the caller's scope.
    var child_env = Env.init(env.alloc, env.store);
    defer child_env.deinit();
    child_env.struct_ctx = .{
        .graph = ctx.graph,
        .interner = ctx.interner,
        .current_struct_scope = callee_scope,
        .attribute_struct_scope = attributeStructScope(ctx),
    };
    child_env.compiled_program = env.compiled_program;
    child_env.dispatch_depth = env.dispatch_depth + 1;
    // When dispatching into a macro body, narrow the child env's
    // capability set to the callee's declared caps so its impure-call
    // checks are gated by the *callee's* annotation, not the caller's.
    // For functions we keep the build cap (function-level effect
    // tracking is out of MVP scope).
    if (callee_is_macro) {
        child_env.current_macro_caps = callee_caps;
        child_env.current_macro_name = form_name;
    } else {
        child_env.current_macro_caps = env.current_macro_caps;
        child_env.current_macro_name = env.current_macro_name;
    }

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
        result = eval(&child_env, stmt_ct) catch |err| {
            // Propagate a capability-violation diagnostic surfaced by
            // an inner intrinsic or macro out to the caller's env so
            // the outer expansion site can present it. Without this,
            // a violation in a nested macro would surface as an
            // opaque `EvalFailed` and the user would see no actionable
            // hint about which capability was missing.
            if (child_env.last_capability_error) |msg| {
                env.last_capability_error = msg;
            }
            return err;
        };
    }

    if (callee_is_macro and isCompileTimeIntrinsicExpansion(result)) {
        return try eval(&child_env, result);
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

/// `atom_name(atom_value)`: extract the bare name string
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

/// `slugify(string_value)`: convert a string to a snake-
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

/// `intern_atom(string_value)`: convert a string to an atom
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
fn debugPrintCtValue(val: CtValue, max_depth: u32) void {
    if (max_depth == 0) {
        std.debug.print("…", .{});
        return;
    }
    switch (val) {
        .nil => std.debug.print("nil", .{}),
        .void => std.debug.print("void", .{}),
        .consumed => std.debug.print("<consumed>", .{}),
        .reuse_token => std.debug.print("<reuse>", .{}),
        .int => |v| std.debug.print("{d}", .{v}),
        .float => |v| std.debug.print("{d}", .{v}),
        .string => |v| std.debug.print("\"{s}\"", .{v}),
        .atom => |v| std.debug.print(":{s}", .{v}),
        .bool_val => |v| std.debug.print("{s}", .{if (v) "true" else "false"}),
        .list => |l| {
            std.debug.print("[", .{});
            for (l.elems, 0..) |e, i| {
                if (i > 0) std.debug.print(", ", .{});
                debugPrintCtValue(e, max_depth - 1);
            }
            std.debug.print("]", .{});
        },
        .tuple => |t| {
            std.debug.print("{{", .{});
            for (t.elems, 0..) |e, i| {
                if (i > 0) std.debug.print(", ", .{});
                debugPrintCtValue(e, max_depth - 1);
            }
            std.debug.print("}}", .{});
        },
        .map => std.debug.print("<map>", .{}),
        .struct_val => std.debug.print("<struct>", .{}),
        .union_val => std.debug.print("<union>", .{}),
        .enum_val => std.debug.print("<enum>", .{}),
        .optional => std.debug.print("<optional>", .{}),
        .closure => std.debug.print("<closure>", .{}),
    }
}

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

fn ctMapKeyEql(left_raw: CtValue, right_raw: CtValue) bool {
    const left = unwrapAstLiteral(left_raw);
    const right = unwrapAstLiteral(right_raw);
    return left.eql(right);
}

fn structIntrinsicGet(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    const name_val = try eval(env, args[0]);
    const ctx = env.struct_ctx orelse return .nil;
    const scope_id = attributeStructScope(ctx) orelse return .nil;
    const mod_entry = ctx.graph.findStructByScope(scope_id) orelse return .nil;

    const name_str = extractAtomName(name_val) orelse return .nil;
    const name_id = ctx.interner.intern(name_str) catch return .nil;
    const cv_opt = ctx.graph.getStructAttribute(mod_entry, name_id) catch return .nil;
    const cv = cv_opt orelse return .nil;
    return constValueToCtValue(env, cv) catch .nil;
}

fn structIntrinsicRegister(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len < 1) return .nil;
    const name_val = try eval(env, args[0]);
    const ctx = env.struct_ctx orelse return .nil;
    const scope_id = attributeStructScope(ctx) orelse return .nil;
    const mod_entry = ctx.graph.findStructByScope(scope_id) orelse return .nil;

    const name_str = extractAtomName(name_val) orelse return .nil;
    const name_id = ctx.interner.intern(name_str) catch return .nil;
    ctx.graph.registerAccumulatingAttribute(mod_entry, name_id) catch return .nil;
    return .nil;
}

fn attributeStructScope(ctx: StructContext) ?scope.ScopeId {
    return ctx.attribute_struct_scope orelse ctx.current_struct_scope;
}

fn sourceGraphStructsIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        env.last_capability_error = std.fmt.allocPrint(
            env.alloc,
            "macro `{s}` calls `source_graph_structs` but does not declare `@requires = [:reflect_source]`",
            .{env.current_macro_name orelse "<top-level>"},
        ) catch return MacroEvalError.EvalFailed;
        return MacroEvalError.EvalFailed;
    }

    const paths_raw = try eval(env, args[0]);
    const paths = extractPathFilter(env, paths_raw) catch return .nil;
    const ctx = env.struct_ctx orelse return .nil;

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    for (ctx.graph.structs.items) |struct_entry| {
        const source_id = struct_entry.decl.meta.span.source_id orelse continue;
        const path = ctx.graph.sourcePathById(source_id) orelse continue;
        if (!pathFilterContains(env.alloc, paths, path)) continue;
        try result_list.append(env.alloc, try makeStructRef(env, ctx.interner, struct_entry, path, source_id));
    }

    const id = env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = result_list.items } };
}

fn structFunctionsIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        env.last_capability_error = std.fmt.allocPrint(
            env.alloc,
            "macro `{s}` calls `struct_functions` but does not declare `@requires = [:reflect_source]`",
            .{env.current_macro_name orelse "<top-level>"},
        ) catch return MacroEvalError.EvalFailed;
        return MacroEvalError.EvalFailed;
    }

    const ctx = env.struct_ctx orelse return .nil;
    const ref_value = try eval(env, args[0]);
    const struct_name = (try extractStructRefName(env.alloc, ref_value)) orelse return .nil;
    const struct_scope_id = findStructScopeByName(ctx.graph, ctx.interner, struct_name) orelse return .nil;
    const struct_scope = ctx.graph.getScope(struct_scope_id);

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    var family_iter = struct_scope.function_families.iterator();
    while (family_iter.next()) |entry| {
        const family = &ctx.graph.families.items[entry.value_ptr.*];
        if (family.visibility != .public) continue;
        if (family.clauses.items.len == 0) continue;
        const name = ctx.interner.get(family.name);
        const doc_text = extractDocAttributeText(env.alloc, ctx.interner, family.attributes) orelse "";
        const loc = declSourceLocation(ctx.graph, family.clauses.items[0].decl.meta);
        try result_list.append(env.alloc, try makeFunctionRef(env, name, family.arity, family.visibility, doc_text, loc.path, loc.line));
    }

    const id = env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = result_list.items } };
}

/// Enumerate every public protocol declared in any of the source paths
/// supplied. Each result is an `__aliases__` AST ref pointing at the
/// protocol — the same shape as `source_graph_structs`, so callers can
/// hand the result to `struct_info` for protocol-level metadata.
fn sourceGraphProtocolsIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        env.last_capability_error = std.fmt.allocPrint(
            env.alloc,
            "macro `{s}` calls `source_graph_protocols` but does not declare `@requires = [:reflect_source]`",
            .{env.current_macro_name orelse "<top-level>"},
        ) catch return MacroEvalError.EvalFailed;
        return MacroEvalError.EvalFailed;
    }

    const paths_raw = try eval(env, args[0]);
    const paths = extractPathFilter(env, paths_raw) catch return .nil;
    const ctx = env.struct_ctx orelse return .nil;

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    for (ctx.graph.protocols.items) |protocol_entry| {
        if (protocol_entry.decl.is_private) continue;
        const source_id = protocol_entry.decl.meta.span.source_id orelse continue;
        const path = ctx.graph.sourcePathById(source_id) orelse continue;
        if (!pathFilterContains(env.alloc, paths, path)) continue;
        try result_list.append(env.alloc, try makeAliasRef(env, ctx.interner, protocol_entry.name));
    }

    const id = env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = result_list.items } };
}

/// Enumerate every public union declared in any of the source paths
/// supplied. Returns `__aliases__` AST refs in the same shape as
/// `source_graph_structs` and `source_graph_protocols`.
///
/// Unions whose names are dotted at the top level (e.g. `pub union
/// IO.Mode`) are emitted with their fully qualified name; nested unions
/// declared inside a struct keep their local name here — the doc
/// generator qualifies those by walking the parent struct scope.
fn sourceGraphUnionsIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        env.last_capability_error = std.fmt.allocPrint(
            env.alloc,
            "macro `{s}` calls `source_graph_unions` but does not declare `@requires = [:reflect_source]`",
            .{env.current_macro_name orelse "<top-level>"},
        ) catch return MacroEvalError.EvalFailed;
        return MacroEvalError.EvalFailed;
    }

    const paths_raw = try eval(env, args[0]);
    const paths = extractPathFilter(env, paths_raw) catch return .nil;
    const ctx = env.struct_ctx orelse return .nil;

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    for (ctx.graph.types.items) |type_entry| {
        const union_decl = switch (type_entry.kind) {
            .union_type => |u| u,
            else => continue,
        };
        if (union_decl.is_private) continue;
        const source_id = union_decl.meta.span.source_id orelse continue;
        const path = ctx.graph.sourcePathById(source_id) orelse continue;
        if (!pathFilterContains(env.alloc, paths, path)) continue;
        // Fabricate a single-segment StructName from the registered
        // union name so the alias-ref shape matches the other source
        // graph results. Dotted names declared at top-level (e.g.
        // `IO.Mode`) are interned as a single string by the parser, so
        // a single-segment ref still round-trips through the resolver.
        const name = ast.StructName{
            .parts = &[_]ast.StringId{type_entry.name},
            .span = union_decl.meta.span,
        };
        try result_list.append(env.alloc, try makeAliasRef(env, ctx.interner, name));
    }

    const id = env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = result_list.items } };
}

/// Reflect on the public macros declared in a struct's scope and return
/// them as a list of maps with the same shape as `struct_functions`.
/// Macros prefixed with `__` (e.g. `__using__`, `__before_compile__`) are
/// excluded — they're language hooks, not public API surface that doc
/// generation would render.
fn structMacrosIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        env.last_capability_error = std.fmt.allocPrint(
            env.alloc,
            "macro `{s}` calls `struct_macros` but does not declare `@requires = [:reflect_source]`",
            .{env.current_macro_name orelse "<top-level>"},
        ) catch return MacroEvalError.EvalFailed;
        return MacroEvalError.EvalFailed;
    }

    const ctx = env.struct_ctx orelse return .nil;
    const ref_value = try eval(env, args[0]);
    const struct_name = (try extractStructRefName(env.alloc, ref_value)) orelse return .nil;
    const struct_scope_id = findStructScopeByName(ctx.graph, ctx.interner, struct_name) orelse return .nil;
    const struct_scope = ctx.graph.getScope(struct_scope_id);

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    var iter = struct_scope.macros.iterator();
    while (iter.next()) |entry| {
        const family = &ctx.graph.macro_families.items[entry.value_ptr.*];
        if (family.clauses.items.len == 0) continue;
        const visibility = family.clauses.items[0].decl.visibility;
        if (visibility != .public) continue;
        const name = ctx.interner.get(family.name);
        if (std.mem.startsWith(u8, name, "__")) continue;
        const doc_text = extractDocAttributeText(env.alloc, ctx.interner, family.attributes) orelse "";
        const loc = declSourceLocation(ctx.graph, family.clauses.items[0].decl.meta);
        try result_list.append(env.alloc, try makeFunctionRef(env, name, family.arity, visibility, doc_text, loc.path, loc.line));
    }

    const id = env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = result_list.items } };
}

/// Return struct-level metadata for a single struct: `:name`,
/// `:source_file` (project-relative path of the file the struct was
/// declared in), `:is_private`, and `:doc` (heredoc-stripped `@doc`
/// text, empty when missing). Used by the Zap doc generator to drive
/// breadcrumbs, source-link rendering, and visibility filtering.
fn structInfoIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        env.last_capability_error = std.fmt.allocPrint(
            env.alloc,
            "macro `{s}` calls `struct_info` but does not declare `@requires = [:reflect_source]`",
            .{env.current_macro_name orelse "<top-level>"},
        ) catch return MacroEvalError.EvalFailed;
        return MacroEvalError.EvalFailed;
    }

    const ctx = env.struct_ctx orelse return .nil;
    const ref_value = try eval(env, args[0]);
    const struct_name = (try extractStructRefName(env.alloc, ref_value)) orelse return .nil;

    // Look up struct, protocol, and union entries by name. The same
    // `struct_info` intrinsic answers for any of them — refs returned
    // from the source-graph reflection intrinsics are interchangeable.
    for (ctx.graph.structs.items) |entry| {
        if (!structNameMatches(ctx.interner, entry.name, struct_name)) continue;
        return makeDeclInfoMap(env, ctx, struct_name, entry.decl.meta, entry.decl.is_private, entry.attributes);
    }
    for (ctx.graph.protocols.items) |entry| {
        if (!structNameMatches(ctx.interner, entry.name, struct_name)) continue;
        return makeDeclInfoMap(env, ctx, struct_name, entry.decl.meta, entry.decl.is_private, entry.attributes);
    }
    for (ctx.graph.types.items) |type_entry| {
        const union_decl = switch (type_entry.kind) {
            .union_type => |u| u,
            else => continue,
        };
        const local_name = ctx.interner.get(type_entry.name);
        if (!std.mem.eql(u8, local_name, struct_name)) continue;
        return makeDeclInfoMap(env, ctx, struct_name, union_decl.meta, union_decl.is_private, type_entry.attributes);
    }
    return .nil;
}

fn makeDeclInfoMap(
    env: *Env,
    ctx: StructContext,
    name: []const u8,
    meta: ast.NodeMeta,
    is_private: bool,
    attributes: std.ArrayListUnmanaged(scope.Attribute),
) !CtValue {
    const source_id = meta.span.source_id orelse 0;
    const source_path = ctx.graph.sourcePathById(source_id) orelse "";
    const doc_text = extractDocAttributeText(env.alloc, ctx.interner, attributes) orelse "";

    const entries = try env.alloc.alloc(CtValue.CtMapEntry, 4);
    entries[0] = .{ .key = .{ .atom = "name" }, .value = .{ .string = env.alloc.dupe(u8, name) catch name } };
    entries[1] = .{ .key = .{ .atom = "source_file" }, .value = .{ .string = source_path } };
    entries[2] = .{ .key = .{ .atom = "is_private" }, .value = .{ .bool_val = is_private } };
    entries[3] = .{ .key = .{ .atom = "doc" }, .value = .{ .string = doc_text } };
    const id = env.store.alloc(env.alloc, .map, null);
    return CtValue{ .map = .{ .alloc_id = id, .entries = entries } };
}

fn hasReflectionCapability(env: *const Env) bool {
    return env.current_macro_caps.has(.reflect_source) or env.current_macro_caps.has(.reflect_struct);
}

fn extractPathFilter(env: *Env, value: CtValue) ![]const []const u8 {
    const unwrapped = unwrapAstLiteral(value);
    return switch (unwrapped) {
        .string => |path| blk: {
            const paths = try env.alloc.alloc([]const u8, 1);
            paths[0] = path;
            break :blk paths;
        },
        .atom => |path| blk: {
            const paths = try env.alloc.alloc([]const u8, 1);
            paths[0] = path;
            break :blk paths;
        },
        .list => |list| blk: {
            const paths = try env.alloc.alloc([]const u8, list.elems.len);
            for (list.elems, 0..) |elem, i| {
                const bare = unwrapAstLiteral(elem);
                paths[i] = switch (bare) {
                    .string => |path| path,
                    .atom => |path| path,
                    else => return error.InvalidPathFilter,
                };
            }
            break :blk paths;
        },
        else => return error.InvalidPathFilter,
    };
}

fn extractStructRefName(alloc: Allocator, value: CtValue) !?[]const u8 {
    const unwrapped = unwrapAstLiteral(value);
    return switch (unwrapped) {
        .string => |name| name,
        .atom => |name| name,
        .tuple => |tuple| blk: {
            if (tuple.elems.len != 3) break :blk null;
            if (tuple.elems[0] != .atom or !std.mem.eql(u8, tuple.elems[0].atom, "__aliases__")) break :blk null;
            if (tuple.elems[2] != .list) break :blk null;
            var buffer: std.ArrayListUnmanaged(u8) = .empty;
            for (tuple.elems[2].list.elems, 0..) |part, index| {
                if (part != .atom) break :blk null;
                if (index > 0) try buffer.append(alloc, '.');
                try buffer.appendSlice(alloc, stripAtomLiteralPrefix(part.atom));
            }
            break :blk try buffer.toOwnedSlice(alloc);
        },
        .map => |map| blk: {
            for (map.entries) |entry| {
                const key = unwrapAstLiteral(entry.key);
                if (key == .atom and std.mem.eql(u8, key.atom, "name")) {
                    const val = unwrapAstLiteral(entry.value);
                    if (val == .string) break :blk val.string;
                    if (val == .atom) break :blk val.atom;
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn makeStructRef(
    env: *Env,
    interner: *ast.StringInterner,
    struct_entry: scope.StructEntry,
    path: []const u8,
    source_id: u32,
) !CtValue {
    _ = path;
    _ = source_id;
    return makeAliasRef(env, interner, struct_entry.name);
}

/// Build the `__aliases__` AST tuple form for a dotted struct/protocol
/// name. The macro engine's `extractStructRefName` decodes this back to
/// a dotted string, and the parser produces the same shape for type
/// identifiers in source — so refs round-trip cleanly between
/// reflection results and user code.
fn makeAliasRef(env: *Env, interner: *ast.StringInterner, name: ast.StructName) !CtValue {
    var parts: std.ArrayListUnmanaged(CtValue) = .empty;
    for (name.parts) |part| {
        try parts.append(env.alloc, .{ .atom = interner.get(part) });
    }
    return ast_data.makeTuple3(
        env.alloc,
        env.store,
        .{ .atom = "__aliases__" },
        try ast_data.emptyList(env.alloc, env.store),
        try ast_data.makeListFromSlice(env.alloc, env.store, parts.items),
    );
}

fn makeFunctionRef(
    env: *Env,
    name: []const u8,
    arity: u32,
    visibility: ast.FunctionDecl.Visibility,
    doc_text: []const u8,
    source_file: []const u8,
    source_line: u32,
) !CtValue {
    const entries = try env.alloc.alloc(CtValue.CtMapEntry, 6);
    entries[0] = .{ .key = .{ .atom = "name" }, .value = .{ .string = name } };
    entries[1] = .{ .key = .{ .atom = "arity" }, .value = .{ .int = @intCast(arity) } };
    entries[2] = .{ .key = .{ .atom = "visibility" }, .value = .{ .atom = @tagName(visibility) } };
    entries[3] = .{ .key = .{ .atom = "doc" }, .value = .{ .string = doc_text } };
    entries[4] = .{ .key = .{ .atom = "source_file" }, .value = .{ .string = source_file } };
    entries[5] = .{ .key = .{ .atom = "source_line" }, .value = .{ .int = @intCast(source_line) } };
    const id = env.store.alloc(env.alloc, .map, null);
    return CtValue{ .map = .{ .alloc_id = id, .entries = entries } };
}

/// Convert a 0-based byte offset into a 1-based line number using the
/// source bytes. Returns 0 when `offset` exceeds `source.len`, mirroring
/// the convention used by `doc_generator.computeLineNumber`.
fn lineNumberFromOffset(source: []const u8, offset: u32) u32 {
    if (offset > source.len) return 0;
    var line: u32 = 1;
    var i: usize = 0;
    while (i < offset) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

/// Return the project-relative source path and 1-based line number for
/// a declaration's first byte. The first clause of a function or macro
/// family is treated as the canonical declaration site.
fn declSourceLocation(graph: *const scope.ScopeGraph, meta: ast.NodeMeta) struct { path: []const u8, line: u32 } {
    const source_id = meta.span.source_id orelse return .{ .path = "", .line = 0 };
    const path = graph.sourcePathById(source_id) orelse "";
    const source = graph.sourceContentById(source_id);
    return .{ .path = path, .line = lineNumberFromOffset(source, meta.span.start) };
}

/// Extract the value of an `@doc = "..."` attribute on a declaration, or
/// return null when there is no doc attribute. The string is heredoc-stripped
/// (common leading whitespace removed) so multi-line `@doc = """ ... """`
/// values round-trip cleanly into runtime literal strings.
fn extractDocAttributeText(
    alloc: Allocator,
    interner: *ast.StringInterner,
    attributes: std.ArrayListUnmanaged(scope.Attribute),
) ?[]const u8 {
    for (attributes.items) |attr| {
        const name = interner.get(attr.name);
        if (!std.mem.eql(u8, name, "doc")) continue;
        const expr = attr.value orelse return null;
        if (expr.* != .string_literal) return null;
        const raw = interner.get(expr.string_literal.value);
        return stripHeredocCommonIndent(alloc, raw);
    }
    return null;
}

/// Strip the common leading-whitespace prefix from every non-blank line in
/// `text` so that `@doc = """\n    Body\n    """` round-trips as `"Body"`
/// without the heredoc indentation. Lines that are empty (or whitespace-only)
/// stay empty in the output.
fn stripHeredocCommonIndent(alloc: Allocator, text: []const u8) []const u8 {
    var min_indent: usize = std.math.maxInt(usize);
    var line_iter = std.mem.splitSequence(u8, text, "\n");
    while (line_iter.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        var indent: usize = 0;
        for (line) |c| {
            if (c == ' ') {
                indent += 1;
            } else if (c == '\t') {
                indent += 4;
            } else break;
        }
        if (indent < min_indent) min_indent = indent;
    }
    if (min_indent == 0 or min_indent == std.math.maxInt(usize)) {
        return alloc.dupe(u8, text) catch text;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitSequence(u8, text, "\n");
    var first = true;
    while (lines.next()) |line| {
        if (!first) out.append(alloc, '\n') catch {};
        first = false;
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        var to_strip = min_indent;
        var start: usize = 0;
        while (start < line.len and to_strip > 0) {
            if (line[start] == ' ') {
                to_strip -= 1;
                start += 1;
            } else if (line[start] == '\t') {
                if (to_strip >= 4) {
                    to_strip -= 4;
                } else {
                    to_strip = 0;
                }
                start += 1;
            } else break;
        }
        out.appendSlice(alloc, line[start..]) catch {};
    }
    return out.toOwnedSlice(alloc) catch text;
}

fn findStructScopeByName(graph: *const scope.ScopeGraph, interner: *const ast.StringInterner, name: []const u8) ?scope.ScopeId {
    for (graph.structs.items) |struct_entry| {
        if (structNameMatches(interner, struct_entry.name, name)) return struct_entry.scope_id;
    }
    return null;
}

fn structNameMatches(interner: *const ast.StringInterner, name: ast.StructName, target: []const u8) bool {
    var index: usize = 0;
    for (name.parts, 0..) |part, part_index| {
        const part_name = interner.get(part);
        if (index + part_name.len > target.len) return false;
        if (!std.mem.eql(u8, target[index .. index + part_name.len], part_name)) return false;
        index += part_name.len;
        if (part_index + 1 < name.parts.len) {
            if (index >= target.len or target[index] != '.') return false;
            index += 1;
        }
    }
    return index == target.len;
}

fn pathFilterContains(alloc: Allocator, paths: []const []const u8, path: []const u8) bool {
    for (paths) |candidate| {
        if (sourcePathsEqual(alloc, candidate, path)) return true;
    }
    return false;
}

fn sourcePathsEqual(alloc: Allocator, left: []const u8, right: []const u8) bool {
    const normalized_left = normalizeSourcePath(left);
    const normalized_right = normalizeSourcePath(right);
    if (std.mem.eql(u8, normalized_left, normalized_right)) return true;

    const canonical_left = canonicalSourcePath(alloc, normalized_left) catch return false;
    defer alloc.free(canonical_left);
    const canonical_right = canonicalSourcePath(alloc, normalized_right) catch return false;
    defer alloc.free(canonical_right);

    return std.mem.eql(u8, canonical_left, canonical_right);
}

fn normalizeSourcePath(path: []const u8) []const u8 {
    var normalized = path;
    while (std.mem.startsWith(u8, normalized, "./")) {
        normalized = normalized[2..];
    }
    return normalized;
}

fn canonicalSourcePath(alloc: Allocator, path: []const u8) ![]const u8 {
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, alloc) catch
        return std.fs.path.resolve(alloc, &.{path});
    defer alloc.free(real_path);
    return try alloc.dupe(u8, real_path);
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

test "eval: list_at extracts elements with normal and negative indices" {
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
    const at0 = try ast_data.makeTuple3(alloc, &store, .{ .atom = "list_at" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ list, .{ .int = 0 } }));
    const r0 = try eval(&env, at0);
    try std.testing.expect(r0 == .int);
    try std.testing.expectEqual(@as(i64, 10), r0.int);

    // list_at(list, 2) → 30
    const at2 = try ast_data.makeTuple3(alloc, &store, .{ .atom = "list_at" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ list, .{ .int = 2 } }));
    const r2 = try eval(&env, at2);
    try std.testing.expect(r2 == .int);
    try std.testing.expectEqual(@as(i64, 30), r2.int);

    // list_at(list, -1) → 30 (last)
    const at_neg = try ast_data.makeTuple3(alloc, &store, .{ .atom = "list_at" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ list, .{ .int = -1 } }));
    const r_neg = try eval(&env, at_neg);
    try std.testing.expect(r_neg == .int);
    try std.testing.expectEqual(@as(i64, 30), r_neg.int);

    // list_at(list, 5) → nil (out of range)
    const at_oor = try ast_data.makeTuple3(alloc, &store, .{ .atom = "list_at" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ list, .{ .int = 5 } }));
    const r_oor = try eval(&env, at_oor);
    try std.testing.expect(r_oor == .nil);
}

test "eval: list_length counts list elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const list3 = try ast_data.makeList(alloc, &store, &.{
        .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 },
    });
    const call3 = try ast_data.makeTuple3(alloc, &store, .{ .atom = "list_length" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{list3}));
    const r3 = try eval(&env, call3);
    try std.testing.expect(r3 == .int);
    try std.testing.expectEqual(@as(i64, 3), r3.int);

    // Empty list → 0
    const empty = try ast_data.emptyList(alloc, &store);
    const call_empty = try ast_data.makeTuple3(alloc, &store, .{ .atom = "list_length" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{empty}));
    const r_empty = try eval(&env, call_empty);
    try std.testing.expect(r_empty == .int);
    try std.testing.expectEqual(@as(i64, 0), r_empty.int);
}

test "eval: list_concat joins two lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const a = try ast_data.makeList(alloc, &store, &.{ .{ .int = 1 }, .{ .int = 2 } });
    const b = try ast_data.makeList(alloc, &store, &.{ .{ .int = 3 }, .{ .int = 4 } });
    const call = try ast_data.makeTuple3(alloc, &store, .{ .atom = "list_concat" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ a, b }));
    const r = try eval(&env, call);
    try std.testing.expect(r == .list);
    try std.testing.expectEqual(@as(usize, 4), r.list.elems.len);
    try std.testing.expectEqual(@as(i64, 1), r.list.elems[0].int);
    try std.testing.expectEqual(@as(i64, 4), r.list.elems[3].int);

    // Concat with nil — treats nil as empty so callers can concat
    // an optional list without an outer guard.
    const call_with_nil = try ast_data.makeTuple3(alloc, &store, .{ .atom = "list_concat" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ a, .nil }));
    const r2 = try eval(&env, call_with_nil);
    try std.testing.expect(r2 == .list);
    try std.testing.expectEqual(@as(usize, 2), r2.list.elems.len);
}

test "eval: list_flatten unnests one level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const inner_a = try ast_data.makeList(alloc, &store, &.{ .{ .int = 1 }, .{ .int = 2 } });
    const inner_b = try ast_data.makeList(alloc, &store, &.{.{ .int = 3 }});
    const empty = try ast_data.emptyList(alloc, &store);
    const outer = try ast_data.makeList(alloc, &store, &.{ inner_a, empty, inner_b });

    const call = try ast_data.makeTuple3(alloc, &store, .{ .atom = "list_flatten" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{outer}));
    const r = try eval(&env, call);
    try std.testing.expect(r == .list);
    try std.testing.expectEqual(@as(usize, 3), r.list.elems.len);
    try std.testing.expectEqual(@as(i64, 1), r.list.elems[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.list.elems[1].int);
    try std.testing.expectEqual(@as(i64, 3), r.list.elems[2].int);
}

test "eval: list_empty? distinguishes empty from non-empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const empty = try ast_data.emptyList(alloc, &store);
    const call_e = try ast_data.makeTuple3(alloc, &store, .{ .atom = "list_empty?" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{empty}));
    const r_e = try eval(&env, call_e);
    try std.testing.expect(r_e == .bool_val);
    try std.testing.expectEqual(true, r_e.bool_val);

    const nonempty = try ast_data.makeList(alloc, &store, &.{.{ .int = 1 }});
    const call_n = try ast_data.makeTuple3(alloc, &store, .{ .atom = "list_empty?" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{nonempty}));
    const r_n = try eval(&env, call_n);
    try std.testing.expect(r_n == .bool_val);
    try std.testing.expectEqual(false, r_n.bool_val);
}

test "eval: map_get returns matching value or default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const entries = try alloc.alloc(CtValue.CtMapEntry, 2);
    entries[0] = .{ .key = .{ .atom = "name" }, .value = .{ .string = "run" } };
    entries[1] = .{ .key = .{ .atom = "arity" }, .value = .{ .int = 0 } };
    const map_value = CtValue{ .map = .{ .alloc_id = store.alloc(alloc, .map, null), .entries = entries } };

    const name_key = try ast_data.makeTuple3(alloc, &store, .{ .atom = ":name" }, try ast_data.emptyList(alloc, &store), .nil);
    const name_call = try ast_data.makeTuple3(alloc, &store, .{ .atom = "map_get" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ map_value, name_key, .{ .string = "" } }));
    const name_result = try eval(&env, name_call);
    try std.testing.expect(name_result == .string);
    try std.testing.expectEqualStrings("run", name_result.string);

    const missing_key = try ast_data.makeTuple3(alloc, &store, .{ .atom = ":missing" }, try ast_data.emptyList(alloc, &store), .nil);
    const missing_call = try ast_data.makeTuple3(alloc, &store, .{ .atom = "map_get" }, try ast_data.emptyList(alloc, &store), try ast_data.makeList(alloc, &store, &.{ map_value, missing_key, .{ .int = -1 } }));
    const missing_result = try eval(&env, missing_call);
    try std.testing.expect(missing_result == .int);
    try std.testing.expectEqual(@as(i64, -1), missing_result.int);
}

test "source path filters treat leading dot slash as equivalent" {
    const alloc = std.testing.allocator;
    const exact_paths = [_][]const u8{"test/zap/zest_runner_test.zap"};
    try std.testing.expect(pathFilterContains(alloc, &exact_paths, "test/zap/zest_runner_test.zap"));
    try std.testing.expect(pathFilterContains(alloc, &exact_paths, "./test/zap/zest_runner_test.zap"));

    const dot_slash_paths = [_][]const u8{"./test/zap/zest_runner_test.zap"};
    try std.testing.expect(pathFilterContains(alloc, &dot_slash_paths, "test/zap/zest_runner_test.zap"));
    try std.testing.expect(!pathFilterContains(alloc, &exact_paths, "test/other_test.zap"));
}

test "source path filters treat project-relative and absolute paths as equivalent" {
    const alloc = std.testing.allocator;
    const absolute_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, "src/macro_eval.zig", alloc);
    defer alloc.free(absolute_path);

    const relative_paths = [_][]const u8{"src/macro_eval.zig"};
    try std.testing.expect(pathFilterContains(alloc, &relative_paths, absolute_path));
}
