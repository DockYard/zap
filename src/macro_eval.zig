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
const signature = @import("signature.zig");
const CtValue = ctfe.CtValue;
const AllocationStore = ctfe.AllocationStore;
const Allocator = std.mem.Allocator;

// `borrowed` names point into the source CtValue; `owned` names are
// allocator-owned dotted aliases and must be deinitialized or transferred.
const ExtractedStructRefName = union(enum) {
    borrowed: []const u8,
    owned: []const u8,

    fn bytes(self: ExtractedStructRefName) []const u8 {
        return switch (self) {
            .borrowed => |name| name,
            .owned => |name| name,
        };
    }

    fn deinit(self: ExtractedStructRefName, alloc: Allocator) void {
        switch (self) {
            .borrowed => {},
            .owned => |name| alloc.free(name),
        }
    }
};

const MACRO_EVAL_DEFAULT_MAX_DEPTH: u32 = 512;
const MACRO_EVAL_DEFAULT_STEP_BUDGET: usize = 1_000_000;

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
    /// Filesystem path of the source file containing the macro family
    /// currently being expanded. `read_file` uses this to anchor
    /// relative paths against the macro's source-file directory rather
    /// than the compilation cwd, so a macro that bundles assets via
    /// `read_file("assets/foo.css")` keeps working when the consuming
    /// program is compiled from any working directory.
    current_macro_source_path: ?[]const u8 = null,
    /// Last hard evaluator diagnostic produced during eval. The
    /// surface-level macro engine queries this to forward a precise
    /// diagnostic when expansion fails. Owned by `alloc`.
    last_capability_error: ?[]const u8 = null,
    /// Native-stack guard for recursive evaluator entry. This is
    /// separate from comptime dispatch depth: it protects structural
    /// recursion within one macro-produced CtValue tree.
    eval_depth: u32 = 0,
    eval_depth_limit: u32 = MACRO_EVAL_DEFAULT_MAX_DEPTH,
    /// Per-root structural work budget for `eval`. Reset when entering
    /// a root eval call (`eval_depth == 0`) and consumed by every
    /// recursive entry under that root.
    eval_step_budget: usize = MACRO_EVAL_DEFAULT_STEP_BUDGET,
    eval_steps_remaining: usize = 0,

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

    pub fn bind(self: *Env, name: []const u8, value: CtValue) Allocator.Error!void {
        try self.bindings.put(name, value);
    }

    pub fn lookup(self: *const Env, name: []const u8) ?CtValue {
        return self.bindings.get(name);
    }
};

/// Evaluate a CtValue AST node in the given environment.
/// Returns the result of evaluation.
pub fn eval(env: *Env, value: CtValue) MacroEvalError!CtValue {
    try enterEval(env);
    defer leaveEval(env);
    return evalInner(env, value);
}

fn evalInner(env: *Env, value: CtValue) MacroEvalError!CtValue {
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
                        if (env.lookup(name)) |bound| {
                            // Reading a single-`_`-prefixed binding is a
                            // contradiction: the prefix declares the
                            // binding intentionally unused. The
                            // type-checker enforces this rule for runtime
                            // function bodies; macro bodies aren't
                            // type-checked, so the macro evaluator
                            // enforces it here. Double-underscore names
                            // (`__foo`) stay in the language-hook
                            // namespace and are readable.
                            if (isReservedUnderscoreReadName(name)) {
                                return failWithHardDiagnostic(
                                    env,
                                    "cannot read `{s}` — single-underscore-prefixed bindings are intentionally unused; drop the leading `_` to use the value (rename to `{s}`)",
                                    .{ name, name[1..] },
                                );
                            }
                            return bound;
                        }
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
                var temporary_values = TemporaryCtValueOwner.init(env.alloc, env.store);
                defer temporary_values.deinitRootList();
                errdefer temporary_values.deinitValues();

                const substituted = try substituteUnquotesEval(env, args.list.elems[0]);
                try temporary_values.adopt(substituted);
                if (substituted == .list) {
                    if (substituted.list.elems.len == 1) {
                        const unwrapped = substituted.list.elems[0];
                        deinitTemporaryCtAggregateShell(
                            env.alloc,
                            env.store,
                            substituted,
                            temporary_values.first_owned_alloc_id,
                        );
                        return unwrapped;
                    }
                    if (substituted.list.elems.len > 1) {
                        const empty = ast_data.emptyList(env.alloc, env.store) catch return MacroEvalError.OutOfMemory;
                        try temporary_values.adopt(empty);
                        const block = ast_data.makeTuple3(
                            env.alloc,
                            env.store,
                            .{ .atom = "__block__" },
                            empty,
                            substituted,
                        ) catch return MacroEvalError.OutOfMemory;
                        return block;
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
            return failWithHardDiagnostic(
                env,
                "cannot call underscore-prefixed function `{s}` from macro code",
                .{form_name},
            );
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
                    var temporary_values = TemporaryCtValueOwner.init(env.alloc, env.store);
                    defer temporary_values.deinitRootList();
                    errdefer temporary_values.deinitValues();

                    const list = try eval(env, arg_elems[0]);
                    try temporary_values.adopt(list);
                    const val = try eval(env, arg_elems[1]);
                    try temporary_values.adopt(val);
                    if (list == .list) {
                        const new_elems = try env.alloc.alloc(CtValue, list.list.elems.len + 1);
                        var initialized_count: usize = 0;
                        var new_elems_transferred = false;
                        errdefer if (!new_elems_transferred) {
                            deinitInitializedTemporaryCtValues(
                                env.alloc,
                                env.store,
                                new_elems,
                                initialized_count,
                                temporary_values.first_owned_alloc_id,
                            );
                            if (new_elems.len > 0) env.alloc.free(new_elems);
                        };
                        new_elems[0] = val;
                        initialized_count += 1;
                        @memcpy(new_elems[1..], list.list.elems);
                        initialized_count += list.list.elems.len;
                        const id = try env.store.alloc(env.alloc, .list, null);
                        new_elems_transferred = true;
                        deinitTemporaryCtAggregateShell(env.alloc, env.store, list, temporary_values.first_owned_alloc_id);
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
                    var temporary_values = TemporaryCtValueOwner.init(env.alloc, env.store);
                    defer temporary_values.deinitRootList();
                    errdefer temporary_values.deinitValues();

                    const left = try eval(env, arg_elems[0]);
                    try temporary_values.adopt(left);
                    const right = try eval(env, arg_elems[1]);
                    try temporary_values.adopt(right);
                    const left_elems: []const CtValue = if (left == .list) left.list.elems else &.{};
                    const right_elems: []const CtValue = if (right == .list) right.list.elems else &.{};
                    const total = left_elems.len + right_elems.len;
                    const combined = try env.alloc.alloc(CtValue, total);
                    var initialized_count: usize = 0;
                    var combined_transferred = false;
                    errdefer if (!combined_transferred) {
                        deinitInitializedTemporaryCtValues(
                            env.alloc,
                            env.store,
                            combined,
                            initialized_count,
                            temporary_values.first_owned_alloc_id,
                        );
                        if (combined.len > 0) env.alloc.free(combined);
                    };
                    @memcpy(combined[0..left_elems.len], left_elems);
                    initialized_count += left_elems.len;
                    @memcpy(combined[left_elems.len..], right_elems);
                    initialized_count += right_elems.len;
                    const id = try env.store.alloc(env.alloc, .list, null);
                    combined_transferred = true;
                    if (left == .list) {
                        deinitTemporaryCtAggregateShell(env.alloc, env.store, left, temporary_values.first_owned_alloc_id);
                    } else {
                        deinitTemporaryCtValue(env.alloc, env.store, left, temporary_values.first_owned_alloc_id);
                    }
                    if (right == .list) {
                        deinitTemporaryCtAggregateShell(env.alloc, env.store, right, temporary_values.first_owned_alloc_id);
                    } else {
                        deinitTemporaryCtValue(env.alloc, env.store, right, temporary_values.first_owned_alloc_id);
                    }
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
                    var temporary_values = TemporaryCtValueOwner.init(env.alloc, env.store);
                    defer temporary_values.deinitRootList();
                    errdefer temporary_values.deinitValues();

                    const outer = try eval(env, arg_elems[0]);
                    try temporary_values.adopt(outer);
                    if (outer != .list) {
                        const id = try env.store.alloc(env.alloc, .list, null);
                        deinitTemporaryCtValue(env.alloc, env.store, outer, temporary_values.first_owned_alloc_id);
                        return CtValue{ .list = .{ .alloc_id = id, .elems = &.{} } };
                    }
                    var total: usize = 0;
                    for (outer.list.elems) |e| {
                        total += if (e == .list) e.list.elems.len else 1;
                    }
                    const combined = try env.alloc.alloc(CtValue, total);
                    var initialized_count: usize = 0;
                    var combined_transferred = false;
                    errdefer if (!combined_transferred) {
                        deinitInitializedTemporaryCtValues(
                            env.alloc,
                            env.store,
                            combined,
                            initialized_count,
                            temporary_values.first_owned_alloc_id,
                        );
                        if (combined.len > 0) env.alloc.free(combined);
                    };
                    var idx: usize = 0;
                    for (outer.list.elems) |e| {
                        if (e == .list) {
                            @memcpy(combined[idx .. idx + e.list.elems.len], e.list.elems);
                            idx += e.list.elems.len;
                            initialized_count += e.list.elems.len;
                        } else {
                            combined[idx] = e;
                            idx += 1;
                            initialized_count += 1;
                        }
                    }
                    const id = try env.store.alloc(env.alloc, .list, null);
                    combined_transferred = true;
                    for (outer.list.elems) |e| {
                        deinitTemporaryCtAggregateShell(env.alloc, env.store, e, temporary_values.first_owned_alloc_id);
                    }
                    deinitTemporaryCtAggregateShell(env.alloc, env.store, outer, temporary_values.first_owned_alloc_id);
                    return CtValue{ .list = .{ .alloc_id = id, .elems = combined } };
                }
            }

            // html_escape(text) — escape `&`, `<`, `>`, `"` for safe
            // emission as HTML body text or attribute content. Mirrors
            // the runtime `Zap.Doc.escape_html` helper so doc-builder
            // macros that bake pre-rendered HTML (signatures, table
            // cells) can escape inputs at expansion time.
            if (std.mem.eql(u8, form_name, "html_escape")) {
                if (arg_elems.len == 1) {
                    const text_value = try eval(env, arg_elems[0]);
                    if (text_value != .string) return CtValue{ .string = "" };
                    const text = text_value.string;
                    var needed: usize = text.len;
                    for (text) |c| switch (c) {
                        '&' => needed += 4,
                        '<' => needed += 3,
                        '>' => needed += 3,
                        '"' => needed += 5,
                        else => {},
                    };
                    var buf = try env.alloc.alloc(u8, needed);
                    var idx: usize = 0;
                    for (text) |c| switch (c) {
                        '&' => {
                            @memcpy(buf[idx .. idx + 5], "&amp;");
                            idx += 5;
                        },
                        '<' => {
                            @memcpy(buf[idx .. idx + 4], "&lt;");
                            idx += 4;
                        },
                        '>' => {
                            @memcpy(buf[idx .. idx + 4], "&gt;");
                            idx += 4;
                        },
                        '"' => {
                            @memcpy(buf[idx .. idx + 6], "&quot;");
                            idx += 6;
                        },
                        else => {
                            buf[idx] = c;
                            idx += 1;
                        },
                    };
                    return CtValue{ .string = buf };
                }
            }

            // string_concat_list(list_of_strings) — concatenate every
            // string element in the list into a single string. Useful
            // for collapsing the output of a `for` comprehension into a
            // single rendered chunk when the doc-builder bakes
            // pre-rendered HTML at compile time. Non-string elements
            // are skipped; the empty list yields the empty string.
            if (std.mem.eql(u8, form_name, "string_concat_list")) {
                if (arg_elems.len == 1) {
                    const list = try eval(env, arg_elems[0]);
                    if (list != .list) return CtValue{ .string = "" };
                    var total: usize = 0;
                    for (list.list.elems) |e| {
                        if (e == .string) total += e.string.len;
                    }
                    var buf = try env.alloc.alloc(u8, total);
                    var idx: usize = 0;
                    for (list.list.elems) |e| {
                        if (e == .string) {
                            @memcpy(buf[idx .. idx + e.string.len], e.string);
                            idx += e.string.len;
                        }
                    }
                    return CtValue{ .string = buf };
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
                            if (try ctMapKeyEql(env, entry.key, lookup_key)) {
                                return entry.value;
                            }
                        }
                    }
                    return default_value;
                }
            }

            // tuple(a, b, c) — construct a tuple
            if (std.mem.eql(u8, form_name, "tuple")) {
                var temporary_values = TemporaryCtValueOwner.init(env.alloc, env.store);
                defer temporary_values.deinitRootList();
                errdefer temporary_values.deinitValues();

                const elems = try env.alloc.alloc(CtValue, arg_elems.len);
                var initialized_count: usize = 0;
                var elems_transferred = false;
                errdefer if (!elems_transferred) {
                    deinitInitializedTemporaryCtValues(
                        env.alloc,
                        env.store,
                        elems,
                        initialized_count,
                        temporary_values.first_owned_alloc_id,
                    );
                    if (elems.len > 0) env.alloc.free(elems);
                };
                for (arg_elems, 0..) |a, i| {
                    elems[i] = try eval(env, a);
                    initialized_count += 1;
                    try temporary_values.adopt(elems[i]);
                }
                const id = try env.store.alloc(env.alloc, .tuple, null);
                elems_transferred = true;
                return CtValue{ .tuple = .{ .alloc_id = id, .elems = elems } };
            }

            // type_tuple(type_expr, arity) — construct a tuple TypeExpr CtValue
            // containing `arity` copies of `type_expr`.
            if (std.mem.eql(u8, form_name, "type_tuple")) {
                if (arg_elems.len != 2) return .nil;
                var temporary_values = TemporaryCtValueOwner.init(env.alloc, env.store);
                defer temporary_values.deinitRootList();
                errdefer temporary_values.deinitValues();

                const lane_type = try eval(env, arg_elems[0]);
                try temporary_values.adopt(lane_type);
                const lane_count_result = try eval(env, arg_elems[1]);
                try temporary_values.adopt(lane_count_result);
                const lane_count_raw = unwrapAstLiteral(lane_count_result);
                if (lane_count_raw != .int or lane_count_raw.int < 0) {
                    temporary_values.deinitValues();
                    return .nil;
                }
                deinitTemporaryCtValue(
                    env.alloc,
                    env.store,
                    lane_count_result,
                    temporary_values.first_owned_alloc_id,
                );
                const lane_count: usize = @intCast(lane_count_raw.int);
                if (lane_count == 0) {
                    deinitTemporaryCtValue(
                        env.alloc,
                        env.store,
                        lane_type,
                        temporary_values.first_owned_alloc_id,
                    );
                }

                const elems = try env.alloc.alloc(CtValue, lane_count);
                defer env.alloc.free(elems);
                for (elems) |*elem| {
                    elem.* = lane_type;
                }

                const args_list = try ast_data.makeListFromSlice(env.alloc, env.store, elems);
                try temporary_values.adopt(args_list);
                const empty = try ast_data.emptyList(env.alloc, env.store);
                try temporary_values.adopt(empty);
                return try ast_data.makeTuple3(env.alloc, env.store, .{ .atom = "tuple" }, empty, args_list);
            }

            // type_name(type_expr) — return the dotted textual name for a
            // simple type expression. Used by macros that need to dispatch to
            // a typed runtime bridge while still accepting Type-shaped input.
            if (std.mem.eql(u8, form_name, "type_name")) {
                if (arg_elems.len != 1) return CtValue{ .string = "" };
                const type_expr = try eval(env, arg_elems[0]);
                if (try extractStructRefName(env.alloc, type_expr)) |name_ref| {
                    // Owned alias names become the returned string value.
                    return CtValue{ .string = name_ref.bytes() };
                }
                if (env.struct_ctx) |ctx| {
                    const ast_type_expr = ast_data.ctValueToTypeExpr(env.alloc, ctx.interner, type_expr) catch |err|
                        return failIntrinsicInfrastructure(env, "type_name", "decoding type expression", err);
                    var buffer = signature.Buffer.init(env.alloc);
                    errdefer buffer.deinit();
                    try appendReflectionTypeExpr(&buffer, ast_type_expr, ctx.interner, ctx.graph);
                    return CtValue{ .string = buffer.toSlice() };
                }
                return CtValue{ .string = "" };
            }

            // type_annotate(expr, type_expr) — construct `expr :: type_expr`
            // as AST data for macros that need to carry a computed TypeExpr
            // through quote/unquote.
            if (std.mem.eql(u8, form_name, "type_annotate")) {
                if (arg_elems.len != 2) return .nil;
                var temporary_values = TemporaryCtValueOwner.init(env.alloc, env.store);
                defer temporary_values.deinitRootList();
                errdefer temporary_values.deinitValues();

                const value_expr = try eval(env, arg_elems[0]);
                try temporary_values.adopt(value_expr);
                const type_expr = try eval(env, arg_elems[1]);
                try temporary_values.adopt(type_expr);
                const args_list = try ast_data.makeList(env.alloc, env.store, &.{ value_expr, type_expr });
                try temporary_values.adopt(args_list);
                const empty = try ast_data.emptyList(env.alloc, env.store);
                try temporary_values.adopt(empty);
                return try ast_data.makeTuple3(env.alloc, env.store, .{ .atom = "::" }, empty, args_list);
            }

            // %{key => value, ...} — construct a map at compile time.
            // The parser encodes a map literal as `{:%{}, meta, [pair, ...]}`
            // where each pair is `{key_form, value_form}`. Evaluating each
            // entry's key and value yields a CtValue map that downstream
            // operators (`map_get`, equality) can consume, and `unquote`
            // can splice into a runtime function body as a literal map.
            //
            // We deliberately keep entries in their wrapped AST form
            // (`{form, meta, nil}` for literals) rather than unwrapping
            // them. The map round-trips through `ctValueToExpr` when
            // unquoted into a runtime body, and atom keys must reach
            // that conversion as wrapped atom literals so they don't get
            // misclassified as variable references — `unwrapAstLiteral`
            // strips the leading `:` from atom names, which destroys the
            // signal that distinguishes `:name` from a `name` var.
            if (std.mem.eql(u8, form_name, "%{}")) {
                var temporary_values = TemporaryCtValueOwner.init(env.alloc, env.store);
                defer temporary_values.deinitRootList();
                errdefer temporary_values.deinitValues();

                const entries = try env.alloc.alloc(CtValue.CtMapEntry, arg_elems.len);
                var initialized_count: usize = 0;
                var entries_transferred = false;
                errdefer if (!entries_transferred) {
                    deinitInitializedTemporaryCtMapEntries(
                        env.alloc,
                        env.store,
                        entries,
                        initialized_count,
                        temporary_values.first_owned_alloc_id,
                    );
                    if (entries.len > 0) env.alloc.free(entries);
                };
                for (arg_elems, 0..) |pair, i| {
                    if (pair == .tuple and pair.tuple.elems.len == 2) {
                        const key = try eval(env, pair.tuple.elems[0]);
                        try temporary_values.adopt(key);
                        const val = try eval(env, pair.tuple.elems[1]);
                        try temporary_values.adopt(val);
                        entries[i] = .{ .key = key, .value = val };
                    } else {
                        // Malformed pair — fall back to nil entry so the
                        // resulting map shape is still well-formed and the
                        // surrounding eval path can surface a precise error.
                        entries[i] = .{ .key = .nil, .value = .nil };
                    }
                    initialized_count += 1;
                }
                const id = try env.store.alloc(env.alloc, .map, null);
                entries_transferred = true;
                return CtValue{ .map = .{ .alloc_id = id, .entries = entries } };
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
            if (std.mem.eql(u8, form_name, "source_graph_impls")) {
                return sourceGraphImplsIntrinsic(env, arg_elems);
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
            if (std.mem.eql(u8, form_name, "union_variants")) {
                return unionVariantsIntrinsic(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "protocol_required_functions")) {
                return protocolRequiredFunctionsIntrinsic(env, arg_elems);
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
            if (std.mem.eql(u8, form_name, "source_text")) {
                return sourceTextIntrinsic(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "source_location")) {
                return sourceLocationIntrinsic(env, arg_elems);
            }

            // make_call(form_name_string, args_list) — build a
            // 3-tuple AST node `{atom(form_name), [], args}`. The form
            // atom is stored WITHOUT the leading `:` that disambiguates
            // atom literals from variable refs in AST encoding, so the
            // result round-trips as a call/operator/assignment node
            // (e.g., `make_call("=", [target, value])` produces
            // the same shape as the parser emits for `target = value`).
            // The form name is interned through the macro context so
            // the atom slice is borrowed, matching CtValue scalar
            // ownership rules.
            //
            // Distinct from `tuple(...)` which evaluates each argument
            // and may wrap atom literals in 3-tuple wrappers — that
            // shape is wrong for AST node construction. A separate
            // primitive keeps both useful: `tuple` for data tuples,
            // `make_call` for AST nodes.
            if (std.mem.eql(u8, form_name, "make_call")) {
                if (arg_elems.len == 2) {
                    var temporary_values = TemporaryCtValueOwner.init(env.alloc, env.store);
                    defer temporary_values.deinitRootList();
                    errdefer temporary_values.deinitValues();

                    const name_raw = try eval(env, arg_elems[0]);
                    try temporary_values.adopt(name_raw);
                    const args_raw = try eval(env, arg_elems[1]);
                    try temporary_values.adopt(args_raw);
                    const name_str = extractString(name_raw) orelse {
                        temporary_values.deinitValues();
                        return .nil;
                    };
                    const call_atom = try internBorrowedMacroAtom(env, "make_call", name_str);
                    deinitTemporaryCtValue(
                        env.alloc,
                        env.store,
                        name_raw,
                        temporary_values.first_owned_alloc_id,
                    );
                    const empty = try ast_data.emptyList(env.alloc, env.store);
                    try temporary_values.adopt(empty);
                    const args_list: CtValue = if (args_raw == .list) args_raw else empty;
                    if (args_raw != .list) {
                        deinitTemporaryCtValue(
                            env.alloc,
                            env.store,
                            args_raw,
                            temporary_values.first_owned_alloc_id,
                        );
                    }
                    return try ast_data.makeTuple3(env.alloc, env.store, .{ .atom = call_atom }, empty, args_list);
                }
            }
            if (std.mem.eql(u8, form_name, "slugify")) {
                return slugifyIntrinsic(env, arg_elems);
            }
            if (std.mem.eql(u8, form_name, "intern_atom")) {
                return internAtomIntrinsic(env, arg_elems);
            }

            // read_file(path) — read a file at compile time.
            // Gated by the `read_file` capability, inferred by
            // `capability_inference.zig` from the macro's call graph.
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
                    return failWithHardDiagnostic(
                        env,
                        "internal: macro `{s}` reached `read_file` without the inferred read_file capability — capability inference is out of sync with the call graph",
                        .{caller},
                    );
                }
                const path_raw = try eval(env, arg_elems[0]);
                const path_ct = unwrapAstLiteral(path_raw);
                if (path_ct != .string) return MacroEvalError.EvalFailed;
                // Try the cwd-relative path first, falling back to the
                // macro source-file directory when the cwd lookup misses.
                // Macro authors bundling assets next to the macro source
                // (e.g. `read_file("assets/style.css")` from a stdlib
                // macro) get correct resolution regardless of the
                // consumer's compilation cwd; consumer-cwd lookups still
                // win for paths the consumer itself owns.
                const cwd_attempt = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path_ct.string, env.alloc, .limited(1 << 20));
                if (cwd_attempt) |bytes| {
                    return CtValue{ .string = bytes };
                } else |cwd_err| {
                    if (env.current_macro_source_path) |macro_path| {
                        if (std.fs.path.dirname(macro_path)) |macro_dir| {
                            const joined = try std.fs.path.join(env.alloc, &.{ macro_dir, path_ct.string });
                            if (std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, joined, env.alloc, .limited(1 << 20))) |bytes| {
                                env.alloc.free(joined);
                                return CtValue{ .string = bytes };
                            } else |_| {
                                env.alloc.free(joined);
                            }
                        }
                    }
                    const caller = env.current_macro_name orelse "<top-level>";
                    return failWithHardDiagnostic(
                        env,
                        "`read_file` in macro `{s}` failed to read `{s}`: {s}",
                        .{ caller, path_ct.string, @errorName(cwd_err) },
                    );
                }
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
        var temporary_values = TemporaryCtValueOwner.init(env.alloc, env.store);
        defer temporary_values.deinitRootList();
        errdefer temporary_values.deinitValues();

        const elems = try env.alloc.alloc(CtValue, value.list.elems.len);
        var initialized_count: usize = 0;
        var elems_transferred = false;
        errdefer if (!elems_transferred) {
            deinitInitializedTemporaryCtValues(
                env.alloc,
                env.store,
                elems,
                initialized_count,
                temporary_values.first_owned_alloc_id,
            );
            if (elems.len > 0) env.alloc.free(elems);
        };
        for (value.list.elems, 0..) |elem, i| {
            elems[i] = try eval(env, elem);
            initialized_count += 1;
            try temporary_values.adopt(elems[i]);
        }
        const id = try env.store.alloc(env.alloc, .list, null);
        elems_transferred = true;
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

fn enterEval(env: *Env) MacroEvalError!void {
    if (env.eval_depth == 0) {
        env.eval_steps_remaining = env.eval_step_budget;
    }

    if (env.eval_depth >= env.eval_depth_limit) {
        return failWithHardDiagnostic(
            env,
            "macro evaluator exceeded maximum structural recursion depth ({d}); possible pathological macro-produced AST",
            .{env.eval_depth_limit},
        );
    }

    if (env.eval_steps_remaining == 0) {
        return failWithHardDiagnostic(
            env,
            "macro evaluator exceeded structural step budget ({d}); possible pathological macro-produced AST",
            .{env.eval_step_budget},
        );
    }

    env.eval_steps_remaining -= 1;
    env.eval_depth += 1;
}

fn leaveEval(env: *Env) void {
    std.debug.assert(env.eval_depth > 0);
    env.eval_depth -= 1;
}

fn failWithHardDiagnostic(
    env: *Env,
    comptime format: []const u8,
    args: anytype,
) MacroEvalError {
    env.last_capability_error = std.fmt.allocPrint(env.alloc, format, args) catch return MacroEvalError.OutOfMemory;
    return MacroEvalError.EvalFailed;
}

fn failMissingReflectionCapability(env: *Env, intrinsic_name: []const u8) MacroEvalError {
    return failWithHardDiagnostic(
        env,
        "macro `{s}` reached `{s}` without the inferred reflect_source capability — capability inference is out of sync with the call graph",
        .{ env.current_macro_name orelse "<top-level>", intrinsic_name },
    );
}

fn failIntrinsicInfrastructure(
    env: *Env,
    intrinsic_name: []const u8,
    operation: []const u8,
    err: anyerror,
) MacroEvalError {
    if (err == error.OutOfMemory) return MacroEvalError.OutOfMemory;
    return failWithHardDiagnostic(
        env,
        "macro intrinsic `{s}` failed while {s}: {s}",
        .{ intrinsic_name, operation, @errorName(err) },
    );
}

fn macroValueTraversalFailure(env: *Env, err: ctfe.ValueTraversalError) MacroEvalError {
    return switch (err) {
        error.OutOfMemory => MacroEvalError.OutOfMemory,
        error.ValueTraversalDepthExceeded => failWithHardDiagnostic(
            env,
            "macro evaluator exceeded maximum CTFE value traversal depth while comparing values",
            .{},
        ),
        error.ValueTraversalBudgetExceeded => failWithHardDiagnostic(
            env,
            "macro evaluator exceeded CTFE value traversal budget while comparing values",
            .{},
        ),
    };
}

fn isDisallowedUnderscoreComptimeCallName(name: []const u8) bool {
    if (name.len == 0 or name[0] != '_') return false;
    if (std.mem.eql(u8, name, "__block__")) return false;
    if (std.mem.eql(u8, name, "__aliases__")) return false;
    return true;
}

/// True for names that begin with a single `_` and therefore declare
/// "intentionally unused" — a read of one is the macro-body counterpart
/// of the type-checker's `rejectUnderscoreVarRead`. Double-underscore
/// names (`__foo`, `__foo__`) belong to the language-hook namespace
/// and stay readable.
fn isReservedUnderscoreReadName(name: []const u8) bool {
    if (name.len == 0 or name[0] != '_') return false;
    if (name.len >= 2 and name[1] == '_') return false;
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
    if (std.mem.eql(u8, op, "==")) return CtValue{ .bool_val = lhs.eql(rhs) catch |err| return macroValueTraversalFailure(env, err) };
    if (std.mem.eql(u8, op, "!=")) return CtValue{ .bool_val = !(lhs.eql(rhs) catch |err| return macroValueTraversalFailure(env, err)) };

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

    // Membership over compile-time list literals. Runtime `in`
    // desugars through the Membership protocol; macro bodies need the
    // same operator to fold when both operands are already compile-time
    // values, e.g. `if lanes in [2, 3, 4, 8, 16] { ... }`.
    if (std.mem.eql(u8, op, "in") and rhs_raw == .list) {
        for (rhs_raw.list.elems) |candidate_raw| {
            if (lhs.eql(unwrapAstLiteral(candidate_raw)) catch |err| return macroValueTraversalFailure(env, err)) {
                return CtValue{ .bool_val = true };
            }
        }
        return CtValue{ .bool_val = false };
    }

    if (std.mem.eql(u8, op, "not in") and rhs_raw == .list) {
        for (rhs_raw.list.elems) |candidate_raw| {
            if (lhs.eql(unwrapAstLiteral(candidate_raw)) catch |err| return macroValueTraversalFailure(env, err)) {
                return CtValue{ .bool_val = false };
            }
        }
        return CtValue{ .bool_val = true };
    }

    // String concat
    if (lhs == .string and rhs == .string) {
        if (std.mem.eql(u8, op, "<>")) {
            const result = try std.fmt.allocPrint(env.alloc, "{s}{s}", .{ lhs.string, rhs.string });
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
                        if (try matchPattern(env, pattern, subject)) {
                            return eval(env, body);
                        }
                    }
                }
            }
        }
    }
    return .nil;
}

const MACRO_EVAL_PATTERN_MATCH_INLINE_STACK_CAPACITY: usize = 64;
const MACRO_EVAL_PATTERN_MATCH_STEP_BUDGET: usize = 1_000_000;
const MACRO_EVAL_UNQUOTE_SUBSTITUTE_INLINE_STACK_CAPACITY: usize = 64;
const MACRO_EVAL_UNQUOTE_SUBSTITUTE_STEP_BUDGET: usize = 1_000_000;
const MACRO_EVAL_COMPTIME_SAFETY_INLINE_STACK_CAPACITY: usize = 64;
const MACRO_EVAL_COMPTIME_SAFETY_STEP_BUDGET: usize = 1_000_000;
const MACRO_EVAL_QUALIFIED_SEGMENTS_INLINE_STACK_CAPACITY: usize = 16;
const MACRO_EVAL_QUALIFIED_SEGMENTS_STEP_BUDGET: usize = 1_000_000;

const MatchPatternFrame = struct {
    pattern: CtValue,
    subject: CtValue,
};

const ComptimeSafetyFrame = union(enum) {
    stmt: ast.Stmt,
    expr: *const ast.Expr,
};

const QualifiedSegmentFrame = union(enum) {
    visit: CtValue,
    append: []const u8,
};

const SubstituteUnquoteFrame = union(enum) {
    visit: CtValue,
    emit: SubstituteUnquoteResult,
    finish_tuple3: struct {
        tuple: CtValue.CtTupleValue,
        args_was_list: bool,
    },
    finish_tuple2: CtValue.CtTupleValue,
    finish_list: struct {
        list: CtValue.CtListValue,
        output_count: usize,
        forced_changed: bool,
    },
};

const SubstituteUnquoteResult = struct {
    value: CtValue,
    changed: bool,
    splice_list: bool = false,
};

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

const TemporaryCtValueOwner = struct {
    allocator: Allocator,
    store: *AllocationStore,
    first_owned_alloc_id: ctfe.AllocId,
    roots: std.ArrayListUnmanaged(CtValue) = .empty,

    fn init(allocator: Allocator, store: *AllocationStore) TemporaryCtValueOwner {
        return .{
            .allocator = allocator,
            .store = store,
            .first_owned_alloc_id = store.next_id,
        };
    }

    fn adopt(self: *TemporaryCtValueOwner, value: CtValue) Allocator.Error!void {
        errdefer deinitTemporaryCtValue(self.allocator, self.store, value, self.first_owned_alloc_id);
        try self.roots.append(self.allocator, value);
    }

    fn deinitValues(self: *TemporaryCtValueOwner) void {
        for (self.roots.items) |value| {
            deinitTemporaryCtValue(self.allocator, self.store, value, self.first_owned_alloc_id);
        }
    }

    fn deinitRootList(self: *TemporaryCtValueOwner) void {
        self.roots.deinit(self.allocator);
    }
};

fn takeTemporaryCtAllocation(
    store: *AllocationStore,
    alloc_id: ctfe.AllocId,
    first_owned_alloc_id: ctfe.AllocId,
) bool {
    if (alloc_id == 0 or alloc_id < first_owned_alloc_id) return false;
    for (store.records.items) |*record| {
        if (record.id == alloc_id) {
            record.id = 0;
            return true;
        }
    }
    return false;
}

fn deinitTemporaryCtValueSlice(
    allocator: Allocator,
    store: *AllocationStore,
    values: []const CtValue,
    first_owned_alloc_id: ctfe.AllocId,
) void {
    for (values) |value| {
        deinitTemporaryCtValue(allocator, store, value, first_owned_alloc_id);
    }
}

fn deinitTemporaryCtMapEntries(
    allocator: Allocator,
    store: *AllocationStore,
    entries: []const CtValue.CtMapEntry,
    first_owned_alloc_id: ctfe.AllocId,
) void {
    for (entries) |entry| {
        deinitTemporaryCtValue(allocator, store, entry.key, first_owned_alloc_id);
        deinitTemporaryCtValue(allocator, store, entry.value, first_owned_alloc_id);
    }
}

fn deinitTemporaryCtFieldValues(
    allocator: Allocator,
    store: *AllocationStore,
    fields: []const CtValue.CtFieldValue,
    first_owned_alloc_id: ctfe.AllocId,
) void {
    for (fields) |field| {
        deinitTemporaryCtValue(allocator, store, field.value, first_owned_alloc_id);
    }
}

fn deinitTemporaryCtValue(
    allocator: Allocator,
    store: *AllocationStore,
    value: CtValue,
    first_owned_alloc_id: ctfe.AllocId,
) void {
    switch (value) {
        .tuple => |tuple_value| {
            if (!takeTemporaryCtAllocation(store, tuple_value.alloc_id, first_owned_alloc_id)) return;
            deinitTemporaryCtValueSlice(allocator, store, tuple_value.elems, first_owned_alloc_id);
            if (tuple_value.elems.len > 0) allocator.free(tuple_value.elems);
        },
        .list => |list_value| {
            if (!takeTemporaryCtAllocation(store, list_value.alloc_id, first_owned_alloc_id)) return;
            deinitTemporaryCtValueSlice(allocator, store, list_value.elems, first_owned_alloc_id);
            if (list_value.elems.len > 0) allocator.free(list_value.elems);
        },
        .map => |map_value| {
            if (!takeTemporaryCtAllocation(store, map_value.alloc_id, first_owned_alloc_id)) return;
            deinitTemporaryCtMapEntries(allocator, store, map_value.entries, first_owned_alloc_id);
            if (map_value.entries.len > 0) allocator.free(map_value.entries);
        },
        .struct_val => |struct_value| {
            if (!takeTemporaryCtAllocation(store, struct_value.alloc_id, first_owned_alloc_id)) return;
            deinitTemporaryCtFieldValues(allocator, store, struct_value.fields, first_owned_alloc_id);
            if (struct_value.fields.len > 0) allocator.free(struct_value.fields);
        },
        .union_val => |union_value| {
            if (!takeTemporaryCtAllocation(store, union_value.alloc_id, first_owned_alloc_id)) return;
            deinitTemporaryCtValue(allocator, store, union_value.payload.*, first_owned_alloc_id);
            allocator.destroy(@constCast(union_value.payload));
        },
        .closure => |closure_value| {
            if (!takeTemporaryCtAllocation(store, closure_value.alloc_id, first_owned_alloc_id)) return;
            deinitTemporaryCtValueSlice(allocator, store, closure_value.captures, first_owned_alloc_id);
            if (closure_value.captures.len > 0) allocator.free(closure_value.captures);
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

fn deinitTemporaryCtAggregateShell(
    allocator: Allocator,
    store: *AllocationStore,
    value: CtValue,
    first_owned_alloc_id: ctfe.AllocId,
) void {
    switch (value) {
        .tuple => |tuple_value| {
            if (!takeTemporaryCtAllocation(store, tuple_value.alloc_id, first_owned_alloc_id)) return;
            if (tuple_value.elems.len > 0) allocator.free(tuple_value.elems);
        },
        .list => |list_value| {
            if (!takeTemporaryCtAllocation(store, list_value.alloc_id, first_owned_alloc_id)) return;
            if (list_value.elems.len > 0) allocator.free(list_value.elems);
        },
        .map => |map_value| {
            if (!takeTemporaryCtAllocation(store, map_value.alloc_id, first_owned_alloc_id)) return;
            if (map_value.entries.len > 0) allocator.free(map_value.entries);
        },
        .struct_val => |struct_value| {
            if (!takeTemporaryCtAllocation(store, struct_value.alloc_id, first_owned_alloc_id)) return;
            if (struct_value.fields.len > 0) allocator.free(struct_value.fields);
        },
        .union_val => |union_value| {
            if (!takeTemporaryCtAllocation(store, union_value.alloc_id, first_owned_alloc_id)) return;
            allocator.destroy(@constCast(union_value.payload));
        },
        .closure => |closure_value| {
            if (!takeTemporaryCtAllocation(store, closure_value.alloc_id, first_owned_alloc_id)) return;
            if (closure_value.captures.len > 0) allocator.free(closure_value.captures);
        },
        else => {},
    }
}

fn deinitInitializedTemporaryCtValues(
    allocator: Allocator,
    store: *AllocationStore,
    values: []const CtValue,
    initialized_count: usize,
    first_owned_alloc_id: ctfe.AllocId,
) void {
    deinitTemporaryCtValueSlice(allocator, store, values[0..initialized_count], first_owned_alloc_id);
}

fn deinitInitializedTemporaryCtMapEntries(
    allocator: Allocator,
    store: *AllocationStore,
    entries: []const CtValue.CtMapEntry,
    initialized_count: usize,
    first_owned_alloc_id: ctfe.AllocId,
) void {
    deinitTemporaryCtMapEntries(allocator, store, entries[0..initialized_count], first_owned_alloc_id);
}

fn resultAliasesCtValue(result: CtValue, candidate: CtValue) bool {
    if (std.meta.activeTag(result) != std.meta.activeTag(candidate)) return false;
    return switch (result) {
        .tuple => |result_tuple| result_tuple.alloc_id == candidate.tuple.alloc_id and result_tuple.elems.ptr == candidate.tuple.elems.ptr,
        .list => |result_list| result_list.alloc_id == candidate.list.alloc_id and result_list.elems.ptr == candidate.list.elems.ptr,
        .map => |result_map| result_map.alloc_id == candidate.map.alloc_id and result_map.entries.ptr == candidate.map.entries.ptr,
        .struct_val => |result_struct| result_struct.alloc_id == candidate.struct_val.alloc_id and result_struct.fields.ptr == candidate.struct_val.fields.ptr,
        .union_val => |result_union| result_union.alloc_id == candidate.union_val.alloc_id and result_union.payload == candidate.union_val.payload,
        .closure => |result_closure| result_closure.alloc_id == candidate.closure.alloc_id and result_closure.captures.ptr == candidate.closure.captures.ptr,
        else => false,
    };
}

fn matchPattern(env: *Env, pattern: CtValue, subject: CtValue) MacroEvalError!bool {
    return matchPatternWithBudget(env, pattern, subject, MACRO_EVAL_PATTERN_MATCH_STEP_BUDGET);
}

fn matchPatternWithBudget(
    env: *Env,
    pattern: CtValue,
    subject: CtValue,
    max_steps: usize,
) MacroEvalError!bool {
    var steps_remaining = max_steps;
    var stack: SmallInlineStack(MatchPatternFrame, MACRO_EVAL_PATTERN_MATCH_INLINE_STACK_CAPACITY) = .{};
    defer stack.deinit(env.alloc);
    try stack.append(env.alloc, .{ .pattern = pattern, .subject = subject });

    while (stack.len() != 0) {
        const frame = stack.pop();
        try consumeMatchPatternStep(env, &steps_remaining, max_steps);

        // 3-tuple pattern: {form, meta, args}
        if (frame.pattern == .tuple and frame.pattern.tuple.elems.len == 3) {
            const form = frame.pattern.tuple.elems[0];
            const args = frame.pattern.tuple.elems[2];

            // Wildcard: {:_, _, nil}
            if (form == .atom and args == .nil) {
                const name = form.atom;
                if (std.mem.eql(u8, name, "_")) continue;

                // Variable binding — bind and match.
                if (name.len > 0 and (name[0] == '_' or std.ascii.isLower(name[0]))) {
                    try env.bind(name, frame.subject);
                    continue;
                }

                // Literal match: form matches subject's form.
                if (!(form.eql(extractForm(frame.subject)) catch |err| return macroValueTraversalFailure(env, err))) return false;
                continue;
            }

            // Tuple destructuring: {:{}, [], [sub_patterns...]}
            // Matches a tuple subject and binds sub-patterns to elements.
            if (form == .atom and std.mem.eql(u8, form.atom, "{}")) {
                if (args != .list or frame.subject != .tuple) return false;
                if (args.list.elems.len != frame.subject.tuple.elems.len) return false;
                try pushMatchPatternFrames(&stack, env.alloc, args.list.elems, frame.subject.tuple.elems);
                continue;
            }

            // Structured AST pattern: {:form_name, _, [sub_patterns...]}
            // Matches a 3-tuple subject with matching form and recurses on args.
            if (form == .atom and args == .list) {
                if (frame.subject != .tuple or frame.subject.tuple.elems.len != 3) return false;
                if (!(form.eql(frame.subject.tuple.elems[0]) catch |err| return macroValueTraversalFailure(env, err))) return false;
                const subject_args = frame.subject.tuple.elems[2];
                if (subject_args != .list or args.list.elems.len != subject_args.list.elems.len) return false;
                try pushMatchPatternFrames(&stack, env.alloc, args.list.elems, subject_args.list.elems);
                continue;
            }
        }

        // List pattern: match element by element.
        if (frame.pattern == .list and frame.subject == .list) {
            if (frame.pattern.list.elems.len != frame.subject.list.elems.len) return false;
            try pushMatchPatternFrames(&stack, env.alloc, frame.pattern.list.elems, frame.subject.list.elems);
            continue;
        }

        if (frame.pattern == .tuple and frame.subject == .tuple) {
            if (frame.pattern.tuple.elems.len != frame.subject.tuple.elems.len) return false;
            try pushMatchPatternFrames(&stack, env.alloc, frame.pattern.tuple.elems, frame.subject.tuple.elems);
            continue;
        }

        // Direct value match.
        if (!(frame.pattern.eql(frame.subject) catch |err| return macroValueTraversalFailure(env, err))) return false;
    }

    return true;
}

fn pushMatchPatternFrames(
    stack: *SmallInlineStack(MatchPatternFrame, MACRO_EVAL_PATTERN_MATCH_INLINE_STACK_CAPACITY),
    allocator: Allocator,
    patterns: []const CtValue,
    subjects: []const CtValue,
) Allocator.Error!void {
    std.debug.assert(patterns.len == subjects.len);
    var index = patterns.len;
    while (index > 0) {
        index -= 1;
        try stack.append(allocator, .{
            .pattern = patterns[index],
            .subject = subjects[index],
        });
    }
}

fn consumeMatchPatternStep(env: *Env, steps_remaining: *usize, budget_limit: usize) MacroEvalError!void {
    if (steps_remaining.* > 0) {
        steps_remaining.* -= 1;
        return;
    }

    return failWithHardDiagnostic(
        env,
        "macro-time case pattern matching exceeded structural budget ({d}); possible pathological macro-produced pattern or subject",
        .{budget_limit},
    );
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

fn installRecursiveComptimeFunctionFixture(
    alloc: Allocator,
    interner: *ast.StringInterner,
    graph: *scope.ScopeGraph,
    struct_name: []const u8,
    function_name: []const u8,
) !scope.ScopeId {
    const struct_name_id = try interner.intern(struct_name);
    const function_name_id = try interner.intern(function_name);
    const struct_scope = try graph.createScope(graph.prelude_scope, .struct_scope);
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 }, .scope_id = struct_scope };

    const struct_parts = try alloc.alloc(ast.StringId, 1);
    struct_parts[0] = struct_name_id;
    const struct_decl = try alloc.create(ast.StructDecl);
    struct_decl.* = .{
        .meta = meta,
        .name = .{ .parts = struct_parts, .span = meta.span },
    };
    try graph.registerStruct(struct_decl.name, struct_scope, struct_decl);

    const callee_expr = try alloc.create(ast.Expr);
    callee_expr.* = .{ .var_ref = .{ .meta = meta, .name = function_name_id } };
    const recursive_call_expr = try alloc.create(ast.Expr);
    recursive_call_expr.* = .{ .call = .{ .meta = meta, .callee = callee_expr, .args = &.{} } };

    const body = try alloc.alloc(ast.Stmt, 1);
    body[0] = .{ .expr = recursive_call_expr };
    const clauses = try alloc.alloc(ast.FunctionClause, 1);
    clauses[0] = .{
        .meta = meta,
        .params = &.{},
        .return_type = null,
        .refinement = null,
        .body = body,
    };
    const decl = try alloc.create(ast.FunctionDecl);
    decl.* = .{
        .meta = meta,
        .name = function_name_id,
        .clauses = clauses,
        .visibility = .public,
    };

    const family_id = try graph.createFamily(struct_scope, function_name_id, 0, .public);
    try graph.getFamilyMut(family_id).clauses.append(alloc, .{ .decl = decl, .clause_index = 0 });
    return struct_scope;
}

fn installNestedArgumentComptimeFunctionFixture(
    alloc: Allocator,
    interner: *ast.StringInterner,
    graph: *scope.ScopeGraph,
    struct_name: []const u8,
    recursive_function_name: []const u8,
    outer_function_name: []const u8,
    outer_arity: usize,
) !scope.ScopeId {
    std.debug.assert(outer_arity > 0);
    const struct_scope = try installRecursiveComptimeFunctionFixture(alloc, interner, graph, struct_name, recursive_function_name);
    const outer_name_id = try interner.intern(outer_function_name);
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 }, .scope_id = struct_scope };

    const params = try alloc.alloc(ast.Param, outer_arity);
    var first_param_name_id: ast.StringId = undefined;
    for (params, 0..) |*param, index| {
        const param_name = try std.fmt.allocPrint(alloc, "value_{d}", .{index});
        const param_name_id = try interner.intern(param_name);
        if (index == 0) first_param_name_id = param_name_id;

        const param_pattern = try alloc.create(ast.Pattern);
        param_pattern.* = .{ .bind = .{ .meta = meta, .name = param_name_id } };
        param.* = .{
            .meta = meta,
            .pattern = param_pattern,
            .type_annotation = null,
        };
    }

    const return_expr = try alloc.create(ast.Expr);
    return_expr.* = .{ .var_ref = .{ .meta = meta, .name = first_param_name_id } };
    const body = try alloc.alloc(ast.Stmt, 1);
    body[0] = .{ .expr = return_expr };

    const clauses = try alloc.alloc(ast.FunctionClause, 1);
    clauses[0] = .{
        .meta = meta,
        .params = params,
        .return_type = null,
        .refinement = null,
        .body = body,
    };

    const decl = try alloc.create(ast.FunctionDecl);
    decl.* = .{
        .meta = meta,
        .name = outer_name_id,
        .clauses = clauses,
        .visibility = .public,
    };

    const family_id = try graph.createFamily(struct_scope, outer_name_id, @intCast(outer_arity), .public);
    try graph.getFamilyMut(family_id).clauses.append(alloc, .{ .decl = decl, .clause_index = 0 });
    return struct_scope;
}

fn installQuotedIntrinsicMacroFixture(
    alloc: Allocator,
    interner: *ast.StringInterner,
    graph: *scope.ScopeGraph,
    struct_name: []const u8,
    macro_name: []const u8,
    intrinsic_name: []const u8,
) !scope.ScopeId {
    const struct_name_id = try interner.intern(struct_name);
    const macro_name_id = try interner.intern(macro_name);
    const intrinsic_name_id = try interner.intern(intrinsic_name);
    const path_filter_id = try interner.intern("src/macro_eval.zig");
    const struct_scope = try graph.createScope(graph.prelude_scope, .struct_scope);
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 }, .scope_id = struct_scope };

    const struct_parts = try alloc.alloc(ast.StringId, 1);
    struct_parts[0] = struct_name_id;
    const struct_decl = try alloc.create(ast.StructDecl);
    struct_decl.* = .{
        .meta = meta,
        .name = .{ .parts = struct_parts, .span = meta.span },
    };
    try graph.registerStruct(struct_decl.name, struct_scope, struct_decl);

    const intrinsic_callee_expr = try alloc.create(ast.Expr);
    intrinsic_callee_expr.* = .{ .var_ref = .{ .meta = meta, .name = intrinsic_name_id } };
    const path_filter_expr = try alloc.create(ast.Expr);
    path_filter_expr.* = .{ .string_literal = .{ .meta = meta, .value = path_filter_id } };
    const intrinsic_args = try alloc.alloc(*const ast.Expr, 1);
    intrinsic_args[0] = path_filter_expr;
    const intrinsic_call_expr = try alloc.create(ast.Expr);
    intrinsic_call_expr.* = .{ .call = .{ .meta = meta, .callee = intrinsic_callee_expr, .args = intrinsic_args } };

    const quoted_body = try alloc.alloc(ast.Stmt, 1);
    quoted_body[0] = .{ .expr = intrinsic_call_expr };
    const quote_expr = try alloc.create(ast.Expr);
    quote_expr.* = .{ .quote_expr = .{ .meta = meta, .body = quoted_body } };

    const body = try alloc.alloc(ast.Stmt, 1);
    body[0] = .{ .expr = quote_expr };
    const clauses = try alloc.alloc(ast.FunctionClause, 1);
    clauses[0] = .{
        .meta = meta,
        .params = &.{},
        .return_type = null,
        .refinement = null,
        .body = body,
    };

    const decl = try alloc.create(ast.FunctionDecl);
    decl.* = .{
        .meta = meta,
        .name = macro_name_id,
        .clauses = clauses,
        .visibility = .public,
    };

    const family_id = try graph.createMacroFamily(struct_scope, macro_name_id, 0);
    graph.macro_families.items[family_id].required_caps = ctfe.CapabilitySet.pure_only;
    try graph.macro_families.items[family_id].clauses.append(alloc, .{ .decl = decl, .clause_index = 0 });
    return struct_scope;
}

fn installStructAttributeFixture(
    alloc: Allocator,
    interner: *ast.StringInterner,
    graph: *scope.ScopeGraph,
    struct_name: []const u8,
) !scope.ScopeId {
    const struct_name_id = try interner.intern(struct_name);
    const struct_scope = try graph.createScope(graph.prelude_scope, .struct_scope);
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 }, .scope_id = struct_scope };

    const struct_parts = try alloc.alloc(ast.StringId, 1);
    struct_parts[0] = struct_name_id;
    const struct_decl = try alloc.create(ast.StructDecl);
    struct_decl.* = .{
        .meta = meta,
        .name = .{ .parts = struct_parts, .span = meta.span },
    };
    try graph.registerStruct(struct_decl.name, struct_scope, struct_decl);
    return struct_scope;
}

fn putOwnedStructAttributeForTest(
    graph: *scope.ScopeGraph,
    struct_scope: scope.ScopeId,
    attr_name: ast.StringId,
    value: ctfe.ConstValue,
) !void {
    var transferred = false;
    errdefer if (!transferred) ctfe.deinitConstValue(graph.allocator, value);

    try graph.putStructAttribute(graph.findStructByScope(struct_scope).?, attr_name, value);
    transferred = true;
}

fn makeUnqualifiedCallCtValue(
    alloc: Allocator,
    store: *AllocationStore,
    function_name: []const u8,
) !CtValue {
    return makeUnqualifiedCallCtValueWithArgs(alloc, store, function_name, &.{});
}

fn makeUnqualifiedCallCtValueWithArgs(
    alloc: Allocator,
    store: *AllocationStore,
    function_name: []const u8,
    arg_values: []const CtValue,
) !CtValue {
    const empty = try ast_data.emptyList(alloc, store);
    const args = try ast_data.makeList(alloc, store, arg_values);
    return ast_data.makeTuple3(alloc, store, .{ .atom = function_name }, empty, args);
}

fn makeQualifiedCallCtValue(
    alloc: Allocator,
    store: *AllocationStore,
    struct_name: []const u8,
    function_name: []const u8,
) !CtValue {
    return makeQualifiedCallCtValueWithArgs(alloc, store, struct_name, function_name, &.{});
}

fn makeQualifiedCallCtValueWithArgs(
    alloc: Allocator,
    store: *AllocationStore,
    struct_name: []const u8,
    function_name: []const u8,
    arg_values: []const CtValue,
) !CtValue {
    const empty = try ast_data.emptyList(alloc, store);
    const aliases_args = try ast_data.makeList(alloc, store, &.{.{ .atom = struct_name }});
    const aliases = try ast_data.makeTuple3(alloc, store, .{ .atom = "__aliases__" }, empty, aliases_args);
    const dot_args = try ast_data.makeList(alloc, store, &.{ aliases, .{ .atom = function_name } });
    const dot_form = try ast_data.makeTuple3(alloc, store, .{ .atom = "." }, empty, dot_args);
    const call_args = try ast_data.makeList(alloc, store, arg_values);
    return ast_data.makeTuple3(alloc, store, dot_form, empty, call_args);
}

fn makeReadFileCallCtValue(
    alloc: Allocator,
    store: *AllocationStore,
) !CtValue {
    return makeUnqualifiedCallCtValueWithArgs(alloc, store, "read_file", &.{.{ .string = "missing.txt" }});
}

fn makeForComprehensionCtValue(
    alloc: Allocator,
    store: *AllocationStore,
    filter_form: CtValue,
    body_form: CtValue,
) !CtValue {
    const iterable = try ast_data.makeList(alloc, store, &.{.{ .int = 1 }});
    return makeUnqualifiedCallCtValueWithArgs(
        alloc,
        store,
        "for",
        &.{ .{ .atom = "item" }, iterable, filter_form, body_form },
    );
}

fn expectHardDiagnosticContains(env: *const Env, expected_fragment: []const u8) !void {
    try std.testing.expect(env.last_capability_error != null);
    const message = env.last_capability_error.?;
    try std.testing.expect(std.mem.indexOf(u8, message, expected_fragment) != null);
}

fn expectComptimeDepthDiagnostic(env: *const Env, expected_callee: []const u8) !void {
    try expectHardDiagnosticContains(env, "maximum recursion depth");
    try expectHardDiagnosticContains(env, expected_callee);
}

fn makeNestedListCtForMatcherTest(
    alloc: Allocator,
    store: *AllocationStore,
    depth: usize,
) !CtValue {
    var current: CtValue = .{ .int = 1 };
    for (0..depth) |_| {
        current = try ast_data.makeList(alloc, store, &.{current});
    }
    return current;
}

fn wrapCtInNestedListsForUnquoteEvalTest(
    alloc: Allocator,
    store: *AllocationStore,
    leaf: CtValue,
    depth: usize,
) !CtValue {
    var current = leaf;
    for (0..depth) |_| {
        current = try ast_data.makeList(alloc, store, &.{current});
    }
    return current;
}

fn makeVarRefCtForUnquoteEvalTest(
    alloc: Allocator,
    store: *AllocationStore,
    name: []const u8,
) !CtValue {
    const empty_meta = try ast_data.emptyList(alloc, store);
    return ast_data.makeTuple3(alloc, store, .{ .atom = name }, empty_meta, .nil);
}

fn makeUnquoteCtForUnquoteEvalTest(
    alloc: Allocator,
    store: *AllocationStore,
    name: []const u8,
) !CtValue {
    const empty_meta = try ast_data.emptyList(alloc, store);
    const var_ref = try makeVarRefCtForUnquoteEvalTest(alloc, store, name);
    const args = try ast_data.makeList(alloc, store, &.{var_ref});
    return ast_data.makeTuple3(alloc, store, .{ .atom = "unquote" }, empty_meta, args);
}

fn makeNestedListExprForSafetyTest(
    alloc: Allocator,
    depth: usize,
) !*const ast.Expr {
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };
    const leaf = try alloc.create(ast.Expr);
    leaf.* = .{ .int_literal = .{ .meta = meta, .value = 1 } };

    var current: *const ast.Expr = leaf;
    for (0..depth) |_| {
        const elements = try alloc.alloc(*const ast.Expr, 1);
        elements[0] = current;
        const next = try alloc.create(ast.Expr);
        next.* = .{ .list = .{ .meta = meta, .elements = elements } };
        current = next;
    }
    return current;
}

fn makeFunctionBodyForSafetyTest(
    alloc: Allocator,
    expr: *const ast.Expr,
) ![]const ast.Stmt {
    const body = try alloc.alloc(ast.Stmt, 1);
    body[0] = .{ .expr = expr };
    return body;
}

fn makeDeepQualifiedFormCtForTest(
    alloc: Allocator,
    store: *AllocationStore,
    depth: usize,
) !CtValue {
    const empty = try ast_data.emptyList(alloc, store);
    const aliases_args = try ast_data.makeList(alloc, store, &.{.{ .atom = "DeepRoot" }});
    var current = try ast_data.makeTuple3(alloc, store, .{ .atom = "__aliases__" }, empty, aliases_args);

    for (0..depth) |index| {
        const field = try std.fmt.allocPrint(alloc, "field_{d}", .{index});
        const dot_args = try ast_data.makeList(alloc, store, &.{ current, .{ .atom = field } });
        current = try ast_data.makeTuple3(alloc, store, .{ .atom = "." }, empty, dot_args);
    }

    return current;
}

test "macro-time case matcher handles deeply nested list patterns iteratively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const depth: usize = 20_000;
    const pattern = try makeNestedListCtForMatcherTest(alloc, &store, depth);
    const subject = try makeNestedListCtForMatcherTest(alloc, &store, depth);

    try std.testing.expect(try matchPattern(&env, pattern, subject));
    try std.testing.expect(env.last_capability_error == null);
}

test "macro-time case matcher keeps ordinary no-match soft" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const pattern = try ast_data.makeList(alloc, &store, &.{.{ .int = 1 }});
    const subject = try ast_data.makeList(alloc, &store, &.{.{ .int = 2 }});

    try std.testing.expect(!try matchPattern(&env, pattern, subject));
    try std.testing.expect(env.last_capability_error == null);
}

test "macro-time case matcher reports structural budget exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const pattern = try makeNestedListCtForMatcherTest(alloc, &store, 4);
    const subject = try makeNestedListCtForMatcherTest(alloc, &store, 4);

    try std.testing.expectError(MacroEvalError.EvalFailed, matchPatternWithBudget(&env, pattern, subject, 2));
    try expectHardDiagnosticContains(&env, "structural budget (2)");
}

test "quote unquote evaluator handles deeply nested macro-produced lists iteratively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    try env.bind("value", .{ .int = 42 });

    const depth: usize = 20_000;
    const unquote_value = try makeUnquoteCtForUnquoteEvalTest(alloc, &store, "value");
    const nested = try wrapCtInNestedListsForUnquoteEvalTest(alloc, &store, unquote_value, depth);
    const substituted = try substituteUnquotesEval(&env, nested);

    var current = substituted;
    for (0..depth) |_| {
        try std.testing.expect(current == .list);
        try std.testing.expectEqual(@as(usize, 1), current.list.elems.len);
        current = current.list.elems[0];
    }
    try std.testing.expect(current == .int);
    try std.testing.expectEqual(@as(i64, 42), current.int);
    try std.testing.expect(env.last_capability_error == null);
}

test "quote unquote evaluator reports structural budget exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    try env.bind("value", .{ .int = 42 });

    const unquote_value = try makeUnquoteCtForUnquoteEvalTest(alloc, &store, "value");
    const nested = try wrapCtInNestedListsForUnquoteEvalTest(alloc, &store, unquote_value, 4);

    try std.testing.expectError(
        MacroEvalError.EvalFailed,
        substituteUnquotesEvalWithBudget(&env, nested, 2),
    );
    try expectHardDiagnosticContains(&env, "quote unquote substitution exceeded structural budget (2)");
}

test "eval reports structural depth exhaustion for deeply nested macro-produced lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.eval_depth_limit = 8;

    const nested = try makeNestedListCtForMatcherTest(alloc, &store, 16);

    try std.testing.expectError(MacroEvalError.EvalFailed, eval(&env, nested));
    try expectHardDiagnosticContains(&env, "maximum structural recursion depth (8)");
    try std.testing.expectEqual(@as(u32, 0), env.eval_depth);
}

test "eval reports structural step budget exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.eval_step_budget = 2;

    const values = try ast_data.makeList(alloc, &store, &.{ .{ .int = 1 }, .{ .int = 2 } });

    try std.testing.expectError(MacroEvalError.EvalFailed, eval(&env, values));
    try expectHardDiagnosticContains(&env, "structural step budget (2)");
    try std.testing.expectEqual(@as(u32, 0), env.eval_depth);
}

test "comptime safety walker handles deeply nested list expressions iteratively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const expr = try makeNestedListExprForSafetyTest(alloc, 20_000);
    const body = try makeFunctionBodyForSafetyTest(alloc, expr);

    try std.testing.expect(try isFunctionBodyComptimeSafe(&env, body));
    try std.testing.expect(env.last_capability_error == null);
}

test "comptime safety walker reports structural budget exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const expr = try makeNestedListExprForSafetyTest(alloc, 4);
    const body = try makeFunctionBodyForSafetyTest(alloc, expr);

    try std.testing.expectError(
        MacroEvalError.EvalFailed,
        isFunctionBodyComptimeSafeWithBudget(&env, body, 2),
    );
    try expectHardDiagnosticContains(&env, "comptime-safety analysis exceeded structural budget (2)");
}

test "qualified callee walker handles deeply nested dotted forms iteratively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const depth: usize = 20_000;
    const form = try makeDeepQualifiedFormCtForTest(alloc, &store, depth);
    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer segments.deinit(alloc);

    try std.testing.expect(try collectQualifiedSegments(&env, form, &segments));
    try std.testing.expectEqual(depth + 1, segments.items.len);
    try std.testing.expectEqualStrings("DeepRoot", segments.items[0]);
    try std.testing.expectEqualStrings("field_19999", segments.items[depth]);
    try std.testing.expect(env.last_capability_error == null);
}

test "qualified callee walker reports structural budget exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const form = try makeDeepQualifiedFormCtForTest(alloc, &store, 4);
    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer segments.deinit(alloc);

    try std.testing.expectError(
        MacroEvalError.EvalFailed,
        collectQualifiedSegmentsWithBudget(&env, form, &segments, 2),
    );
    try expectHardDiagnosticContains(&env, "qualified comptime callee analysis exceeded structural budget (2)");
}

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

test "eval: in operator checks compile-time list membership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const empty = try ast_data.emptyList(alloc, &store);
    const two = try ast_data.makeTuple3(alloc, &store, .{ .int = 2 }, empty, .nil);
    const three = try ast_data.makeTuple3(alloc, &store, .{ .int = 3 }, empty, .nil);
    const four = try ast_data.makeTuple3(alloc, &store, .{ .int = 4 }, empty, .nil);
    const five = try ast_data.makeTuple3(alloc, &store, .{ .int = 5 }, empty, .nil);
    const members = try ast_data.makeList(alloc, &store, &.{ two, three, four });

    const hit = try evalBinop(&env, "in", four, members);
    const miss = try evalBinop(&env, "in", five, members);

    try std.testing.expect(hit == .bool_val);
    try std.testing.expect(hit.bool_val);
    try std.testing.expect(miss == .bool_val);
    try std.testing.expect(!miss.bool_val);
}

test "comptime dispatch: recursive local helper reports depth exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};

    const struct_scope = try installRecursiveComptimeFunctionFixture(alloc, &interner, &graph, "DepthFixture", "loop");
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
    };
    env.dispatch_depth = COMPTIME_DISPATCH_MAX_DEPTH - 1;

    const call = try makeUnqualifiedCallCtValue(alloc, &store, "loop");

    try std.testing.expectError(error.EvalFailed, eval(&env, call));
    try expectComptimeDepthDiagnostic(&env, "loop/0");
}

test "comptime dispatch: qualified helper reports depth exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};

    const struct_scope = try installRecursiveComptimeFunctionFixture(alloc, &interner, &graph, "DepthFixture", "loop");
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
    };
    env.dispatch_depth = COMPTIME_DISPATCH_MAX_DEPTH;

    const call = try makeQualifiedCallCtValue(alloc, &store, "DepthFixture", "loop");

    try std.testing.expectError(error.EvalFailed, eval(&env, call));
    try expectComptimeDepthDiagnostic(&env, "loop/0");
}

test "comptime dispatch: depth cap preserves fallback for unknown local calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};

    const struct_scope = try installRecursiveComptimeFunctionFixture(alloc, &interner, &graph, "DepthFixture", "loop");
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
    };
    env.dispatch_depth = COMPTIME_DISPATCH_MAX_DEPTH;

    const call = try makeUnqualifiedCallCtValue(alloc, &store, "not_defined");
    const result = try eval(&env, call);

    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.elems[0] == .atom);
    try std.testing.expectEqualStrings("not_defined", result.tuple.elems[0].atom);
    try std.testing.expect(env.last_capability_error == null);
}

test "comptime dispatch: unknown local call remains a semantic fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = graph.prelude_scope,
    };

    const call = try makeUnqualifiedCallCtValue(alloc, &store, "not_defined");
    const result = try eval(&env, call);

    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.elems[0] == .atom);
    try std.testing.expectEqualStrings("not_defined", result.tuple.elems[0].atom);
    try std.testing.expect(env.last_capability_error == null);
}

test "comptime dispatch: argument buffer allocation failure remains hard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};

    const struct_scope = try installNestedArgumentComptimeFunctionFixture(alloc, &interner, &graph, "AllocationFixture", "loop", "outer", 1);
    var backing_buffer: [0]u8 = .{};
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&backing_buffer);
    var env = Env.init(fixed_buffer.allocator(), &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
    };

    const call = try makeUnqualifiedCallCtValueWithArgs(alloc, &store, "outer", &.{.{ .int = 1 }});

    try std.testing.expectError(error.OutOfMemory, eval(&env, call));
    try std.testing.expect(env.last_capability_error == null);
}

test "comptime dispatch: parameter bind allocation failure remains hard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};

    const struct_scope = try installNestedArgumentComptimeFunctionFixture(alloc, &interner, &graph, "BindFixture", "loop", "outer", 1);
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var env = Env.init(failing_allocator.allocator(), &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
    };

    const call = try makeUnqualifiedCallCtValueWithArgs(alloc, &store, "outer", &.{.{ .int = 1 }});

    try std.testing.expectError(error.OutOfMemory, eval(&env, call));
    try std.testing.expect(env.last_capability_error == null);
}

test "comptime dispatch: body CtValue encoding allocation failure remains hard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};

    const struct_scope = try installRecursiveComptimeFunctionFixture(alloc, &interner, &graph, "EncodingFixture", "loop");
    var backing_buffer: [0]u8 = .{};
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&backing_buffer);
    var env = Env.init(fixed_buffer.allocator(), &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
    };

    const call = try makeUnqualifiedCallCtValue(alloc, &store, "loop");

    try std.testing.expectError(error.OutOfMemory, eval(&env, call));
    try std.testing.expect(env.last_capability_error == null);
}

test "comptime dispatch: interner allocation failure remains hard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};

    var backing_buffer: [0]u8 = .{};
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&backing_buffer);
    var interner = ast.StringInterner.init(fixed_buffer.allocator());
    defer interner.deinit();
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = graph.prelude_scope,
    };

    const call = try makeUnqualifiedCallCtValue(alloc, &store, "not_interned");

    try std.testing.expectError(error.OutOfMemory, eval(&env, call));
    try std.testing.expect(env.last_capability_error == null);
}

test "comptime dispatch: nested local argument depth exhaustion remains hard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};

    const struct_scope = try installNestedArgumentComptimeFunctionFixture(alloc, &interner, &graph, "DepthFixture", "loop", "outer", 3);
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
    };
    env.dispatch_depth = COMPTIME_DISPATCH_MAX_DEPTH - 1;

    const recursive_arg = try makeUnqualifiedCallCtValue(alloc, &store, "loop");
    const call = try makeUnqualifiedCallCtValueWithArgs(alloc, &store, "outer", &.{ recursive_arg, .{ .int = 1 }, .{ .int = 2 } });

    try std.testing.expectError(error.EvalFailed, eval(&env, call));
    try expectComptimeDepthDiagnostic(&env, "loop/0");
}

test "comptime dispatch: nested qualified argument depth exhaustion remains hard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};

    const struct_scope = try installNestedArgumentComptimeFunctionFixture(alloc, &interner, &graph, "DepthFixture", "loop", "outer", 3);
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
    };
    env.dispatch_depth = COMPTIME_DISPATCH_MAX_DEPTH - 1;

    const recursive_arg = try makeUnqualifiedCallCtValue(alloc, &store, "loop");
    const call = try makeQualifiedCallCtValueWithArgs(alloc, &store, "DepthFixture", "outer", &.{ recursive_arg, .{ .int = 1 }, .{ .int = 2 } });

    try std.testing.expectError(error.EvalFailed, eval(&env, call));
    try expectComptimeDepthDiagnostic(&env, "loop/0");
}

test "comptime for: filter hard diagnostic remains hard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.current_macro_caps = ctfe.CapabilitySet.pure_only;
    env.current_macro_name = "ForFixture";

    const filter_form = try makeReadFileCallCtValue(alloc, &store);
    const call = try makeForComprehensionCtValue(alloc, &store, filter_form, .{ .int = 1 });

    try std.testing.expectError(error.EvalFailed, eval(&env, call));
    try expectHardDiagnosticContains(&env, "read_file");
}

test "comptime for: body hard diagnostic remains hard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.current_macro_caps = ctfe.CapabilitySet.pure_only;
    env.current_macro_name = "ForFixture";

    const body_form = try makeReadFileCallCtValue(alloc, &store);
    const call = try makeForComprehensionCtValue(alloc, &store, .nil, body_form);

    try std.testing.expectError(error.EvalFailed, eval(&env, call));
    try expectHardDiagnosticContains(&env, "read_file");
}

test "comptime for: pattern bind allocation failure remains hard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var setup_store = AllocationStore{};

    const iterable = try ast_data.makeList(alloc, &setup_store, &.{.{ .int = 1 }});
    const call = try makeUnqualifiedCallCtValueWithArgs(
        alloc,
        &setup_store,
        "for",
        &.{ .{ .atom = "item" }, iterable, .nil, .{ .int = 1 } },
    );

    var backing_buffer: [4096]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&backing_buffer);
    var failing_allocator = std.testing.FailingAllocator.init(fixed_buffer.allocator(), .{ .fail_index = 2 });
    var eval_store = AllocationStore{};
    defer eval_store.deinit(failing_allocator.allocator());
    var env = Env.init(failing_allocator.allocator(), &eval_store);
    defer env.deinit();

    try std.testing.expectError(error.OutOfMemory, eval(&env, call));
    try std.testing.expect(env.last_capability_error == null);
}

test "comptime for: unsupported bind pattern remains no binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();

    const unsupported_pattern = try ast_data.makeList(alloc, &store, &.{.{ .atom = "item" }});
    const bound_name = try bindForPattern(&env, unsupported_pattern, .{ .int = 1 });

    try std.testing.expect(bound_name == null);
    try std.testing.expect(env.lookup("item") == null);
}

test "underscore binding diagnostic allocation failure remains OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    try env.bind("_unused", .{ .int = 1 });

    const variable_ref = try makeVarRefCtForUnquoteEvalTest(alloc, &store, "_unused");
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    env.alloc = failing_allocator.allocator();

    try std.testing.expectError(error.OutOfMemory, eval(&env, variable_ref));
    try std.testing.expect(env.last_capability_error == null);
}

test "read_file diagnostic allocation failure remains OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.current_macro_caps = ctfe.CapabilitySet.pure_only;
    env.current_macro_name = "ReadFileFixture";

    const call = try makeReadFileCallCtValue(alloc, &store);
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    env.alloc = failing_allocator.allocator();

    try std.testing.expectError(error.OutOfMemory, eval(&env, call));
    try std.testing.expect(env.last_capability_error == null);
}

test "read_file macro-relative path allocation failure remains OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.current_macro_caps = ctfe.CapabilitySet.build;
    env.current_macro_name = "ReadFileFixture";
    env.current_macro_source_path = "definitely_missing_macro_eval_fixture_dir/macro.zap";

    const call = try makeUnqualifiedCallCtValueWithArgs(
        alloc,
        &store,
        "read_file",
        &.{.{ .string = "definitely_missing_macro_eval_fixture_asset.txt" }},
    );
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    env.alloc = failing_allocator.allocator();

    try std.testing.expectError(error.OutOfMemory, eval(&env, call));
    try std.testing.expect(env.last_capability_error == null);
}

test "reflection capability diagnostic allocation failure remains OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.current_macro_caps = ctfe.CapabilitySet.pure_only;
    env.current_macro_name = "ReflectionFixture";

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    env.alloc = failing_allocator.allocator();

    try std.testing.expectError(error.OutOfMemory, sourceTextIntrinsic(&env, &.{.nil}));
    try std.testing.expect(env.last_capability_error == null);
}

test "comptime dispatch: nested intrinsic result preserves child diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};

    const struct_scope = try installQuotedIntrinsicMacroFixture(
        alloc,
        &interner,
        &graph,
        "ReflectionFixture",
        "reflecting_macro",
        "source_graph_structs",
    );
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
    };
    env.current_macro_caps = ctfe.CapabilitySet.pure_only;
    env.current_macro_name = "Caller";

    const call = try makeUnqualifiedCallCtValue(alloc, &store, "reflecting_macro");

    try std.testing.expectError(error.EvalFailed, eval(&env, call));
    try expectHardDiagnosticContains(&env, "source_graph_structs");
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
    return substituteUnquotesEvalWithBudget(
        env,
        value,
        MACRO_EVAL_UNQUOTE_SUBSTITUTE_STEP_BUDGET,
    );
}

fn substituteUnquotesEvalWithBudget(
    env: *Env,
    value: CtValue,
    max_steps: usize,
) MacroEvalError!CtValue {
    var steps_remaining = max_steps;
    var frames: SmallInlineStack(SubstituteUnquoteFrame, MACRO_EVAL_UNQUOTE_SUBSTITUTE_INLINE_STACK_CAPACITY) = .{};
    defer frames.deinit(env.alloc);
    var results: SmallInlineStack(SubstituteUnquoteResult, MACRO_EVAL_UNQUOTE_SUBSTITUTE_INLINE_STACK_CAPACITY) = .{};
    defer results.deinit(env.alloc);
    var created_values = TemporaryCtValueOwner.init(env.alloc, env.store);
    defer created_values.deinitRootList();
    errdefer created_values.deinitValues();

    try frames.append(env.alloc, .{ .visit = value });
    while (frames.len() != 0) {
        switch (frames.pop()) {
            .emit => |result| try results.append(env.alloc, result),
            .visit => |current| {
                try consumeUnquoteSubstitutionStep(env, &steps_remaining, max_steps);

                if (current == .tuple and current.tuple.elems.len == 3) {
                    const form = current.tuple.elems[0];
                    const args = current.tuple.elems[2];

                    if (form == .atom) {
                        // Eager unquote: fully evaluate the inner expression in the current env.
                        if (std.mem.eql(u8, form.atom, "unquote")) {
                            if (args == .list and args.list.elems.len == 1) {
                                const replacement = try eval(env, args.list.elems[0]);
                                try created_values.adopt(replacement);
                                try results.append(env.alloc, .{
                                    .value = replacement,
                                    .changed = true,
                                });
                                continue;
                            }
                        }

                        // Top-level unquote_splicing in a single quote body returns the
                        // evaluated value; list contexts handle sibling splicing below.
                        if (std.mem.eql(u8, form.atom, "unquote_splicing")) {
                            if (args == .list and args.list.elems.len == 1) {
                                const replacement = try eval(env, args.list.elems[0]);
                                try created_values.adopt(replacement);
                                try results.append(env.alloc, .{
                                    .value = replacement,
                                    .changed = true,
                                });
                                continue;
                            }
                        }

                        // Don't descend into nested quote; its unquotes belong to that quote.
                        if (std.mem.eql(u8, form.atom, "quote")) {
                            try results.append(env.alloc, .{ .value = current, .changed = false });
                            continue;
                        }
                    }

                    try frames.append(env.alloc, .{ .finish_tuple3 = .{
                        .tuple = current.tuple,
                        .args_was_list = args == .list,
                    } });
                    if (args == .list) {
                        try frames.append(env.alloc, .{ .visit = args });
                    }
                    try frames.append(env.alloc, .{ .visit = form });
                    continue;
                }

                if (current == .tuple and current.tuple.elems.len == 2) {
                    try frames.append(env.alloc, .{ .finish_tuple2 = current.tuple });
                    try frames.append(env.alloc, .{ .visit = current.tuple.elems[1] });
                    continue;
                }

                if (current == .list) {
                    var result_count: usize = 0;
                    var forced_changed = false;
                    for (current.list.elems) |elem| {
                        if (isUnquoteSplicingForm(elem)) {
                            forced_changed = true;
                        }
                        result_count += 1;
                    }

                    try frames.append(env.alloc, .{ .finish_list = .{
                        .list = current.list,
                        .output_count = result_count,
                        .forced_changed = forced_changed,
                    } });

                    var index = current.list.elems.len;
                    while (index > 0) {
                        index -= 1;
                        const elem = current.list.elems[index];
                        if (isUnquoteSplicingForm(elem)) {
                            const replacement = try eval(env, elem.tuple.elems[2].list.elems[0]);
                            try created_values.adopt(replacement);
                            try frames.append(env.alloc, .{ .emit = .{
                                .value = replacement,
                                .changed = true,
                                .splice_list = replacement == .list,
                            } });
                            continue;
                        }

                        try frames.append(env.alloc, .{ .visit = elem });
                    }
                    continue;
                }

                try results.append(env.alloc, .{ .value = current, .changed = false });
            },
            .finish_tuple3 => |finish| {
                const transformed_args = if (finish.args_was_list) results.pop() else null;
                const transformed_form = results.pop();
                const args = if (transformed_args) |result| result.value else finish.tuple.elems[2];
                const changed = transformed_form.changed or if (transformed_args) |result| result.changed else false;

                const new_tuple = try env.alloc.alloc(CtValue, 3);
                var initialized_count: usize = 0;
                var new_tuple_transferred = false;
                errdefer if (!new_tuple_transferred) {
                    deinitInitializedTemporaryCtValues(
                        env.alloc,
                        env.store,
                        new_tuple,
                        initialized_count,
                        created_values.first_owned_alloc_id,
                    );
                    if (new_tuple.len > 0) env.alloc.free(new_tuple);
                };
                new_tuple[0] = transformed_form.value;
                initialized_count += 1;
                new_tuple[1] = finish.tuple.elems[1];
                initialized_count += 1;
                new_tuple[2] = args;
                initialized_count += 1;
                const id = try env.store.alloc(env.alloc, .tuple, null);
                const transformed = CtValue{ .tuple = .{ .alloc_id = id, .elems = new_tuple } };
                new_tuple_transferred = true;
                try created_values.adopt(transformed);
                try results.append(env.alloc, .{
                    .value = transformed,
                    .changed = changed,
                });
            },
            .finish_tuple2 => |tuple| {
                const transformed_value = results.pop();
                const new_elems = try env.alloc.alloc(CtValue, 2);
                var initialized_count: usize = 0;
                var new_elems_transferred = false;
                errdefer if (!new_elems_transferred) {
                    deinitInitializedTemporaryCtValues(
                        env.alloc,
                        env.store,
                        new_elems,
                        initialized_count,
                        created_values.first_owned_alloc_id,
                    );
                    if (new_elems.len > 0) env.alloc.free(new_elems);
                };
                new_elems[0] = tuple.elems[0];
                initialized_count += 1;
                new_elems[1] = transformed_value.value;
                initialized_count += 1;
                const id = try env.store.alloc(env.alloc, .tuple, null);
                const transformed = CtValue{ .tuple = .{ .alloc_id = id, .elems = new_elems } };
                new_elems_transferred = true;
                try created_values.adopt(transformed);
                try results.append(env.alloc, .{
                    .value = transformed,
                    .changed = transformed_value.changed,
                });
            },
            .finish_list => |finish| {
                var reversed_results: SmallInlineStack(SubstituteUnquoteResult, MACRO_EVAL_UNQUOTE_SUBSTITUTE_INLINE_STACK_CAPACITY) = .{};
                defer reversed_results.deinit(env.alloc);

                var changed = finish.forced_changed or finish.output_count != finish.list.elems.len;
                var final_count: usize = 0;
                var remaining = finish.output_count;
                while (remaining > 0) {
                    remaining -= 1;
                    const result = results.pop();
                    if (result.changed) changed = true;
                    final_count += if (result.splice_list) result.value.list.elems.len else 1;
                    try reversed_results.append(env.alloc, result);
                }

                if (!changed) {
                    try results.append(env.alloc, .{
                        .value = .{ .list = finish.list },
                        .changed = false,
                    });
                    continue;
                }

                const new_elems = try env.alloc.alloc(CtValue, final_count);
                var output_index: usize = 0;
                var new_elems_transferred = false;
                errdefer if (!new_elems_transferred) {
                    deinitInitializedTemporaryCtValues(
                        env.alloc,
                        env.store,
                        new_elems,
                        output_index,
                        created_values.first_owned_alloc_id,
                    );
                    if (new_elems.len > 0) env.alloc.free(new_elems);
                };
                while (reversed_results.len() != 0) {
                    const result = reversed_results.pop();
                    if (result.splice_list) {
                        for (result.value.list.elems) |splice_elem| {
                            new_elems[output_index] = splice_elem;
                            output_index += 1;
                        }
                    } else {
                        new_elems[output_index] = result.value;
                        output_index += 1;
                    }
                }
                const id = try env.store.alloc(env.alloc, .list, null);
                const transformed = CtValue{ .list = .{ .alloc_id = id, .elems = new_elems } };
                new_elems_transferred = true;
                try created_values.adopt(transformed);
                try results.append(env.alloc, .{
                    .value = transformed,
                    .changed = changed,
                });
            },
        }
    }

    std.debug.assert(results.len() == 1);
    return results.pop().value;
}

fn consumeUnquoteSubstitutionStep(
    env: *Env,
    steps_remaining: *usize,
    budget_limit: usize,
) MacroEvalError!void {
    if (steps_remaining.* > 0) {
        steps_remaining.* -= 1;
        return;
    }

    return failWithHardDiagnostic(
        env,
        "macro-time quote unquote substitution exceeded structural budget ({d}); possible pathological macro-produced quote body",
        .{budget_limit},
    );
}

fn isUnquoteSplicingForm(value: CtValue) bool {
    if (value != .tuple or value.tuple.elems.len != 3) return false;
    const form = value.tuple.elems[0];
    const args = value.tuple.elems[2];
    return form == .atom and
        std.mem.eql(u8, form.atom, "unquote_splicing") and
        args == .list and
        args.list.elems.len == 1;
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

fn internBorrowedMacroAtom(env: *Env, intrinsic_name: []const u8, name: []const u8) MacroEvalError![]const u8 {
    const ctx = env.struct_ctx orelse return failWithHardDiagnostic(
        env,
        "macro intrinsic `{s}` requires macro expansion context to intern atom `{s}`",
        .{ intrinsic_name, name },
    );
    const atom_id = ctx.interner.intern(name) catch |err|
        return failIntrinsicInfrastructure(env, intrinsic_name, "interning atom name", err);
    return ctx.interner.get(atom_id);
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
    const name_id = ctx.interner.intern(name_str) catch |err|
        return failIntrinsicInfrastructure(env, "struct_put_attribute", "interning attribute name", err);

    // The macro evaluator's CtValue carries AST-shape wrappers
    // (3-tuple `{form, meta, nil}` for literals); the attribute store
    // holds bare ConstValues that match `@attr = literal`'s storage
    // format. Unwrap AST literal shells so consumers see the same
    // values regardless of whether the attribute was written from
    // source or via a macro intrinsic.
    const unwrapped = unwrapAstLiteral(value_ct);
    const cv = ctfe.exportValue(ctx.graph.allocator, unwrapped) catch |err|
        return failIntrinsicInfrastructure(env, "struct_put_attribute", "exporting attribute value", err);
    var cv_transferred = false;
    errdefer if (!cv_transferred) ctfe.deinitConstValue(ctx.graph.allocator, cv);
    ctx.graph.putStructAttribute(mod_entry, name_id, cv) catch |err|
        return failIntrinsicInfrastructure(env, "struct_put_attribute", "storing attribute value", err);
    cv_transferred = true;
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
/// (e.g., division by zero); those failures remain hard once a
/// dispatchable callee has been selected.
fn isFunctionBodyComptimeSafe(env: *Env, body: []const ast.Stmt) MacroEvalError!bool {
    return isFunctionBodyComptimeSafeWithBudget(
        env,
        body,
        MACRO_EVAL_COMPTIME_SAFETY_STEP_BUDGET,
    );
}

fn isFunctionBodyComptimeSafeWithBudget(
    env: *Env,
    body: []const ast.Stmt,
    max_steps: usize,
) MacroEvalError!bool {
    var steps_remaining = max_steps;
    var stack: SmallInlineStack(ComptimeSafetyFrame, MACRO_EVAL_COMPTIME_SAFETY_INLINE_STACK_CAPACITY) = .{};
    defer stack.deinit(env.alloc);

    try pushComptimeSafetyStmts(&stack, env.alloc, body);
    while (stack.len() != 0) {
        try consumeComptimeSafetyStep(env, &steps_remaining, max_steps);
        switch (stack.pop()) {
            .stmt => |stmt| switch (stmt) {
                .expr => |expr| try stack.append(env.alloc, .{ .expr = expr }),
                .assignment => |assignment| try stack.append(env.alloc, .{ .expr = assignment.value }),
                // Function/macro/import declarations inside another fn
                // body aren't comptime-callable through dispatch (the
                // caller would have to evaluate the whole construct).
                .function_decl, .macro_decl, .import_decl, .attribute => return false,
            },
            .expr => |expr| switch (expr.*) {
                // Literals — always safe.
                .int_literal, .float_literal, .string_literal, .bool_literal, .atom_literal, .nil_literal => {},
                // Variable references resolve through env.bindings.
                .var_ref => {},
                // Compound shapes — all children must be safe.
                .binary_op => |binary| {
                    try stack.append(env.alloc, .{ .expr = binary.rhs });
                    try stack.append(env.alloc, .{ .expr = binary.lhs });
                },
                .unary_op => |unary| try stack.append(env.alloc, .{ .expr = unary.operand }),
                .pipe => |pipe| {
                    try stack.append(env.alloc, .{ .expr = pipe.rhs });
                    try stack.append(env.alloc, .{ .expr = pipe.lhs });
                },
                .list => |list| try pushComptimeSafetyExprs(&stack, env.alloc, list.elements),
                .tuple => |tuple| try pushComptimeSafetyExprs(&stack, env.alloc, tuple.elements),
                .map => |map| {
                    var index = map.fields.len;
                    while (index > 0) {
                        index -= 1;
                        try stack.append(env.alloc, .{ .expr = map.fields[index].value });
                        try stack.append(env.alloc, .{ .expr = map.fields[index].key });
                    }
                    if (map.update_source) |source| {
                        try stack.append(env.alloc, .{ .expr = source });
                    }
                },
                .block => |block| try pushComptimeSafetyStmts(&stack, env.alloc, block.stmts),
                .if_expr => |if_expr| {
                    if (if_expr.else_block) |else_block| {
                        try pushComptimeSafetyStmts(&stack, env.alloc, else_block);
                    }
                    try pushComptimeSafetyStmts(&stack, env.alloc, if_expr.then_block);
                    try stack.append(env.alloc, .{ .expr = if_expr.condition });
                },
                // Calls — check the callee shape. Bare-name calls go through
                // comptime dispatch (recursive safety check at dispatch
                // time). Field-access callees that target the `:zig.` interop
                // namespace are NEVER comptime-safe; struct-qualified Zap
                // calls (`Foo.bar(args)`) are conservatively rejected for
                // now since dispatch doesn't yet route through struct refs.
                .call => |call| {
                    if (call.callee.* != .var_ref) return false;
                    try pushComptimeSafetyExprs(&stack, env.alloc, call.args);
                },
                .range => |range| {
                    if (range.step) |step| {
                        try stack.append(env.alloc, .{ .expr = step });
                    }
                    try stack.append(env.alloc, .{ .expr = range.end });
                    try stack.append(env.alloc, .{ .expr = range.start });
                },
                .list_cons_expr => |list_cons| {
                    try stack.append(env.alloc, .{ .expr = list_cons.tail });
                    try stack.append(env.alloc, .{ .expr = list_cons.head });
                },
                // Quote/unquote/splicing — the macro evaluator handles all
                // three forms directly: quote returns its body as data, and
                // unquote/unquote_splicing only fire inside quote. Treating
                // them as comptime-safe lets user-defined macros that
                // construct AST (`quote { ... }`) be invoked from another
                // macro body via comptime dispatch.
                .quote_expr, .unquote_expr, .unquote_splicing_expr => {},
                .for_expr => |for_expr| {
                    if (for_expr.filter) |filter| {
                        try stack.append(env.alloc, .{ .expr = filter });
                    }
                    try stack.append(env.alloc, .{ .expr = for_expr.body });
                    try stack.append(env.alloc, .{ .expr = for_expr.iterable });
                },
                .case_expr => |case_expr| {
                    var clause_index = case_expr.clauses.len;
                    while (clause_index > 0) {
                        clause_index -= 1;
                        try pushComptimeSafetyStmts(&stack, env.alloc, case_expr.clauses[clause_index].body);
                    }
                    try stack.append(env.alloc, .{ .expr = case_expr.scrutinee });
                },
                // Anything else is unrecognized — refuse conservatively.
                else => return false,
            },
        }
    }

    return true;
}

fn pushComptimeSafetyStmts(
    stack: *SmallInlineStack(ComptimeSafetyFrame, MACRO_EVAL_COMPTIME_SAFETY_INLINE_STACK_CAPACITY),
    allocator: Allocator,
    stmts: []const ast.Stmt,
) Allocator.Error!void {
    var index = stmts.len;
    while (index > 0) {
        index -= 1;
        try stack.append(allocator, .{ .stmt = stmts[index] });
    }
}

fn pushComptimeSafetyExprs(
    stack: *SmallInlineStack(ComptimeSafetyFrame, MACRO_EVAL_COMPTIME_SAFETY_INLINE_STACK_CAPACITY),
    allocator: Allocator,
    exprs: []const *const ast.Expr,
) Allocator.Error!void {
    var index = exprs.len;
    while (index > 0) {
        index -= 1;
        try stack.append(allocator, .{ .expr = exprs[index] });
    }
}

fn consumeComptimeSafetyStep(
    env: *Env,
    steps_remaining: *usize,
    budget_limit: usize,
) MacroEvalError!void {
    if (steps_remaining.* > 0) {
        steps_remaining.* -= 1;
        return;
    }

    return failWithHardDiagnostic(
        env,
        "comptime-safety analysis exceeded structural budget ({d}); possible pathological macro-produced function body",
        .{budget_limit},
    );
}

fn dispatchQualifiedComptimeCall(
    env: *Env,
    form: CtValue,
    arg_forms: []const CtValue,
) MacroEvalError!?CtValue {
    const ctx = env.struct_ctx orelse return null;

    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer segments.deinit(env.alloc);
    if (!try collectQualifiedSegments(env, form, &segments)) return null;
    if (segments.items.len < 2) return null;

    if (std.mem.eql(u8, segments.items[0], "zig")) return null;

    const function_name = segments.items[segments.items.len - 1];
    if (isDisallowedUnderscoreComptimeCallName(function_name)) {
        return failWithHardDiagnostic(
            env,
            "cannot call underscore-prefixed function `{s}` from macro code",
            .{function_name},
        );
    }
    const struct_scope = findStructScopeBySegments(ctx.graph, ctx.interner, segments.items[0 .. segments.items.len - 1]) orelse return null;
    const name_id = try ctx.interner.intern(function_name);
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
        if (try evalDispatchedClause(env, &clause_ref.decl.clauses[clause_ref.clause_index], arg_forms, struct_scope, false, ctfe.CapabilitySet.build, function_name)) |result| {
            return result;
        }
        // The function exists but neither evaluation path could produce
        // a value:
        //   - `evalCompiledQualifiedFunction` returned null because the
        //     function isn't yet in the compiled-IR table (staged
        //     compilation order placed the consumer before the
        //     provider's IR was built).
        //   - `evalDispatchedClause` returned null because the body
        //     isn't comptime-safe for AST evaluation (it calls a
        //     `:zig.*` builtin or other unevaluable form).
        //
        // Returning null here lets eval fall through to `return value`,
        // leaving the unevaluated AST tuple in the caller's slot. That
        // silently propagates as nil/[Nil] through downstream operations
        // and produces wrong-type errors many phases away from the
        // actual cause. Raise a precise diagnostic instead so the
        // staging issue is visible at the point of failure.
        const dotted = try std.mem.join(env.alloc, ".", segments.items);
        defer env.alloc.free(dotted);
        return failWithHardDiagnostic(
            env,
            "comptime call to `{s}/{d}` couldn't be evaluated — the function's IR isn't available at this expansion stage and its body uses `:zig.*` builtins the AST evaluator can't run. The consumer's compilation likely landed in a topo-order wave before the provider's dependencies were compiled.",
            .{ dotted, arity },
        );
    }

    if (struct_scope_value.macros.get(key)) |macro_id| {
        const family = &ctx.graph.macro_families.items[macro_id];
        if (!family.required_caps.isSubsetOf(env.current_macro_caps)) {
            const caller_name = env.current_macro_name orelse "<top-level>";
            return failWithHardDiagnostic(
                env,
                "macro `{s}` requires capabilities not held by caller `{s}` — calling macro `{s}` would escalate the caller's capability set",
                .{ function_name, caller_name, function_name },
            );
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
    defer env.alloc.free(compiled_name);

    var interpreter = try ctfe.Interpreter.init(env.alloc, program);
    defer interpreter.deinit();
    if (env.struct_ctx) |ctx| {
        interpreter.scope_graph = ctx.graph;
        interpreter.interner = ctx.interner;
        interpreter.current_struct_scope = attributeStructScope(ctx);
    }
    interpreter.capabilities = env.current_macro_caps;
    interpreter.steps_remaining = interpreter.step_budget;
    if (!interpreter.function_by_name.contains(compiled_name)) return null;

    const first_owned_alloc_id = env.store.next_id;
    const arg_values = env.alloc.alloc(CtValue, arg_forms.len) catch return MacroEvalError.OutOfMemory;
    var initialized_count: usize = 0;
    var transferred_arg_index: ?usize = null;
    defer {
        for (arg_values[0..initialized_count], 0..) |arg_value, index| {
            if (transferred_arg_index == null or transferred_arg_index.? != index) {
                deinitTemporaryCtValue(env.alloc, env.store, arg_value, first_owned_alloc_id);
            }
        }
        if (arg_values.len > 0) env.alloc.free(arg_values);
    }
    for (arg_forms, 0..) |form, index| {
        arg_values[index] = try eval(env, form);
        initialized_count += 1;
    }

    const result = interpreter.evalByName(compiled_name, arg_values) catch |err| {
        if (err == error.OutOfMemory) return MacroEvalError.OutOfMemory;
        if (interpreter.errors.items.len > 0) {
            env.last_capability_error = ctfe.formatCtfeError(env.alloc, interpreter.errors.items[0]) catch |format_err|
                return failIntrinsicInfrastructure(env, "compiled Zap function CTFE", "formatting CTFE diagnostic", format_err);
            return MacroEvalError.EvalFailed;
        }
        return failWithHardDiagnostic(
            env,
            "compiled Zap function CTFE failed without a diagnostic: {s}",
            .{@errorName(err)},
        );
    };
    for (arg_values[0..initialized_count], 0..) |arg_value, index| {
        if (resultAliasesCtValue(result, arg_value)) {
            transferred_arg_index = index;
            break;
        }
    }
    return result;
}

fn compiledFunctionName(
    allocator: Allocator,
    segments: []const []const u8,
    arity: usize,
) MacroEvalError![]const u8 {
    var struct_prefix: std.ArrayListUnmanaged(u8) = .empty;
    defer struct_prefix.deinit(allocator);

    for (segments[0 .. segments.len - 1], 0..) |segment, index| {
        if (index > 0) try struct_prefix.append(allocator, '_');
        try struct_prefix.appendSlice(allocator, segment);
    }

    const raw_function_name = segments[segments.len - 1];
    const mangled_function_name = ir.mangleSymbolForZig(allocator, raw_function_name) catch
        return MacroEvalError.OutOfMemory;
    defer if (!std.mem.eql(u8, mangled_function_name, raw_function_name)) {
        allocator.free(mangled_function_name);
    };

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
        std.mem.eql(u8, form.atom, "source_graph_impls") or
        std.mem.eql(u8, form.atom, "struct_functions") or
        std.mem.eql(u8, form.atom, "struct_macros") or
        std.mem.eql(u8, form.atom, "struct_info") or
        std.mem.eql(u8, form.atom, "union_variants") or
        std.mem.eql(u8, form.atom, "protocol_required_functions");
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
    if (!try isFunctionBodyComptimeSafe(env, body)) return null;
    try requireComptimeDispatchDepth(env, callee_name, arg_forms.len);

    var arg_cts = try env.alloc.alloc(CtValue, arg_forms.len);
    defer env.alloc.free(arg_cts);
    for (arg_forms, 0..) |form, index| {
        arg_cts[index] = (try evalDispatchArgument(env, form)) orelse return null;
    }

    var child_env = Env.init(env.alloc, env.store);
    defer child_env.deinit();
    child_env.eval_depth_limit = env.eval_depth_limit;
    child_env.eval_step_budget = env.eval_step_budget;
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
        // When dispatching into another macro, anchor `read_file` etc.
        // against the callee's source file so the callee's own
        // bundled assets resolve regardless of caller cwd.
        child_env.current_macro_source_path = if (clause.meta.span.source_id) |sid|
            ctx.graph.sourcePathById(sid)
        else
            env.current_macro_source_path;
    } else {
        child_env.current_macro_caps = env.current_macro_caps;
        child_env.current_macro_name = env.current_macro_name;
        child_env.current_macro_source_path = env.current_macro_source_path;
    }

    for (clause.params, 0..) |param, index| {
        if (index >= arg_cts.len) break;
        if (param.pattern.* == .bind) {
            const param_name = ctx.interner.get(param.pattern.bind.name);
            try child_env.bind(param_name, arg_cts[index]);
        }
    }

    var result: CtValue = .nil;
    for (body) |stmt| {
        const stmt_ct = try ast_data.stmtToCtValue(env.alloc, ctx.interner, env.store, stmt);
        result = eval(&child_env, stmt_ct) catch |err| {
            copyChildHardEvalDiagnostic(env, &child_env);
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
    return collectQualifiedSegmentsWithBudget(
        env,
        value,
        segments,
        MACRO_EVAL_QUALIFIED_SEGMENTS_STEP_BUDGET,
    );
}

fn collectQualifiedSegmentsWithBudget(
    env: *Env,
    value: CtValue,
    segments: *std.ArrayListUnmanaged([]const u8),
    max_steps: usize,
) MacroEvalError!bool {
    var steps_remaining = max_steps;
    var stack: SmallInlineStack(QualifiedSegmentFrame, MACRO_EVAL_QUALIFIED_SEGMENTS_INLINE_STACK_CAPACITY) = .{};
    defer stack.deinit(env.alloc);

    try stack.append(env.alloc, .{ .visit = value });
    while (stack.len() != 0) {
        try consumeQualifiedSegmentStep(env, &steps_remaining, max_steps);
        switch (stack.pop()) {
            .append => |segment| try segments.append(env.alloc, segment),
            .visit => |current| {
                if (current == .tuple and current.tuple.elems.len == 3) {
                    const form = current.tuple.elems[0];
                    const args = current.tuple.elems[2];

                    if (form == .atom and std.mem.eql(u8, form.atom, ".")) {
                        if (args != .list or args.list.elems.len != 2) return false;
                        const field = args.list.elems[1];
                        if (field != .atom) return false;
                        try stack.append(env.alloc, .{ .append = stripAtomLiteralPrefix(field.atom) });
                        try stack.append(env.alloc, .{ .visit = args.list.elems[0] });
                        continue;
                    }

                    if (form == .atom and std.mem.eql(u8, form.atom, "__aliases__")) {
                        if (args != .list) return false;
                        var index = args.list.elems.len;
                        while (index > 0) {
                            index -= 1;
                            const part = args.list.elems[index];
                            if (part != .atom) return false;
                            try stack.append(env.alloc, .{ .append = stripAtomLiteralPrefix(part.atom) });
                        }
                        continue;
                    }

                    if (args == .nil and form == .atom and form.atom.len > 0 and form.atom[0] == ':') {
                        try stack.append(env.alloc, .{ .append = form.atom[1..] });
                        continue;
                    }
                }

                if (current == .atom) {
                    try stack.append(env.alloc, .{ .append = stripAtomLiteralPrefix(current.atom) });
                    continue;
                }

                return false;
            },
        }
    }

    return true;
}

fn consumeQualifiedSegmentStep(
    env: *Env,
    steps_remaining: *usize,
    budget_limit: usize,
) MacroEvalError!void {
    if (steps_remaining.* > 0) {
        steps_remaining.* -= 1;
        return;
    }

    return failWithHardDiagnostic(
        env,
        "qualified comptime callee analysis exceeded structural budget ({d}); possible pathological macro-produced callee",
        .{budget_limit},
    );
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

fn requireComptimeDispatchDepth(
    env: *Env,
    callee_name: []const u8,
    arity: usize,
) MacroEvalError!void {
    if (env.dispatch_depth < COMPTIME_DISPATCH_MAX_DEPTH) return;

    return failWithHardDiagnostic(
        env,
        "comptime dispatch exceeded maximum recursion depth ({d}) while evaluating `{s}/{d}`; check recursive macro helper/function calls and add or fix the base case",
        .{ COMPTIME_DISPATCH_MAX_DEPTH, callee_name, arity },
    );
}

fn evalDispatchArgument(env: *Env, form: CtValue) MacroEvalError!?CtValue {
    return evalOrNullOnSoftFailure(env, form);
}

fn evalOrNullOnSoftFailure(env: *Env, form: CtValue) MacroEvalError!?CtValue {
    const diagnostic_before = env.last_capability_error;
    return eval(env, form) catch |err| {
        switch (err) {
            error.OutOfMemory => return err,
            error.EvalFailed => {
                if (hardEvalDiagnosticChanged(diagnostic_before, env.last_capability_error)) {
                    return err;
                }
                return null;
            },
        }
    };
}

fn evalOrNilOnSoftFailure(env: *Env, form: CtValue) MacroEvalError!CtValue {
    return (try evalOrNullOnSoftFailure(env, form)) orelse .nil;
}

fn hardEvalDiagnosticChanged(before: ?[]const u8, after: ?[]const u8) bool {
    const current = after orelse return false;
    const previous = before orelse return true;
    return current.ptr != previous.ptr or current.len != previous.len;
}

fn copyChildHardEvalDiagnostic(parent: *Env, child: *const Env) void {
    if (child.last_capability_error) |message| {
        parent.last_capability_error = message;
    }
}

/// Try to resolve and interpret a Zap-side function call at comptime.
/// Returns the function body's evaluated result, or null when:
///   - no struct context is available (eval is not running for a
///     macro expansion)
///   - the function family isn't found in the current scope chain
///   - the function body contains constructs the comptime evaluator
///     can't handle (e.g., `:zig.` calls)
///
/// Dispatch recursion depth exhaustion is a hard diagnostic once a
/// dispatchable, comptime-safe callee is found; it is not represented as
/// null because null means "leave this call as ordinary AST data".
fn dispatchComptimeCall(
    env: *Env,
    form_name: []const u8,
    arg_forms: []const CtValue,
) MacroEvalError!?CtValue {
    const ctx = env.struct_ctx orelse return null;

    const scope_id = ctx.current_struct_scope orelse ctx.graph.prelude_scope;
    const name_id = try ctx.interner.intern(form_name);
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
        return failWithHardDiagnostic(
            env,
            "macro `{s}` requires capabilities not held by caller `{s}` — calling macro `{s}` would escalate the caller's capability set",
            .{ form_name, caller_name, form_name },
        );
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
    if (!try isFunctionBodyComptimeSafe(env, body)) {
        return null;
    }
    try requireComptimeDispatchDepth(env, form_name, arg_forms.len);

    // Pre-evaluate each argument so the callee sees fully-evaluated
    // values, not AST forms still containing nested calls.
    var arg_cts = try env.alloc.alloc(CtValue, arg_forms.len);
    defer env.alloc.free(arg_cts);
    for (arg_forms, 0..) |form, i| {
        arg_cts[i] = (try evalDispatchArgument(env, form)) orelse return null;
    }

    // Spin up a child env that inherits the same store, dispatch
    // depth (incremented), and struct_ctx, but starts with a fresh
    // bindings map populated only with the callee's parameters. The
    // child's bindings can't leak into the caller's scope.
    var child_env = Env.init(env.alloc, env.store);
    defer child_env.deinit();
    child_env.eval_depth_limit = env.eval_depth_limit;
    child_env.eval_step_budget = env.eval_step_budget;
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
        child_env.current_macro_source_path = if (clause.meta.span.source_id) |sid|
            ctx.graph.sourcePathById(sid)
        else
            env.current_macro_source_path;
    } else {
        child_env.current_macro_caps = env.current_macro_caps;
        child_env.current_macro_name = env.current_macro_name;
        child_env.current_macro_source_path = env.current_macro_source_path;
    }

    for (clause.params, 0..) |param, i| {
        if (i >= arg_cts.len) break;
        if (param.pattern.* == .bind) {
            const param_name = ctx.interner.get(param.pattern.bind.name);
            try child_env.bind(param_name, arg_cts[i]);
        }
    }

    // Convert the body statements to CtValue and evaluate them.
    // Last statement's result is the return value, matching
    // expression-language semantics.
    var result: CtValue = .nil;
    for (body) |stmt| {
        const stmt_ct = try ast_data.stmtToCtValue(env.alloc, ctx.interner, env.store, stmt);
        result = eval(&child_env, stmt_ct) catch |err| {
            // Propagate a capability-violation diagnostic surfaced by
            // an inner intrinsic or macro out to the caller's env so
            // the outer expansion site can present it. Without this,
            // a violation in a nested macro would surface as an
            // opaque `EvalFailed` and the user would see no actionable
            // hint about which capability was missing.
            copyChildHardEvalDiagnostic(env, &child_env);
            return err;
        };
    }

    if (callee_is_macro and isCompileTimeIntrinsicExpansion(result)) {
        return eval(&child_env, result) catch |err| {
            copyChildHardEvalDiagnostic(env, &child_env);
            return err;
        };
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
    var temporary_values = TemporaryCtValueOwner.init(env.alloc, env.store);
    defer temporary_values.deinitRootList();
    errdefer temporary_values.deinitValues();

    const var_pattern = args[0];
    const iterable_ct = try eval(env, args[1]);
    try temporary_values.adopt(iterable_ct);
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
        else => {
            deinitTemporaryCtValue(env.alloc, env.store, iterable_ct, temporary_values.first_owned_alloc_id);
            return .nil;
        },
    };

    var accumulated: std.ArrayListUnmanaged(CtValue) = .empty;
    errdefer accumulated.deinit(env.alloc);
    for (list_elems) |elem| {
        // Bind the loop pattern. Save and restore env.bindings around
        // each iteration so loop-bound names don't leak.
        const had_pattern_bind = try bindForPattern(env, var_pattern, elem);
        defer if (had_pattern_bind) |bound_name| {
            _ = env.bindings.remove(bound_name);
        };

        // Filter check, if present.
        if (filter_form != .nil) {
            const filter_result = try evalOrNilOnSoftFailure(env, filter_form);
            const bare = unwrapAstLiteral(filter_result);
            const passes = switch (bare) {
                .bool_val => |b| b,
                else => false, // truthy semantics not supported at comptime
            };
            if (!passes) continue;
        }

        const body_result = try evalOrNilOnSoftFailure(env, body_form);
        try temporary_values.adopt(body_result);
        try accumulated.append(env.alloc, body_result);
    }

    const slice = try accumulated.toOwnedSlice(env.alloc);
    var slice_transferred = false;
    errdefer if (!slice_transferred) {
        deinitTemporaryCtValueSlice(
            env.alloc,
            env.store,
            slice,
            temporary_values.first_owned_alloc_id,
        );
        if (slice.len > 0) env.alloc.free(slice);
    };
    const id = try env.store.alloc(env.alloc, .list, null);
    slice_transferred = true;
    deinitTemporaryCtAggregateShell(env.alloc, env.store, iterable_ct, temporary_values.first_owned_alloc_id);
    return CtValue{ .list = .{ .alloc_id = id, .elems = slice } };
}

/// Bind a for-comprehension's loop pattern to a list element. Only
/// simple bind patterns (a bare name) are supported at comptime —
/// destructuring patterns (`{k, v}` etc.) require running the
/// pattern matcher, which is HIR-level work. Returns the bound name
/// (if any) for cleanup.
fn bindForPattern(env: *Env, pattern: CtValue, elem: CtValue) Allocator.Error!?[]const u8 {
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
    const buf = try env.alloc.dupe(u8, name);
    return CtValue{ .string = buf };
}

/// `source_text(expr)`: return the exact source slice for an AST node.
/// Missing spans, generated nodes, or unavailable source content return
/// the empty string so macros can fall back without failing expansion.
fn sourceTextIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return CtValue{ .string = "" };
    if (!hasReflectionCapability(env)) {
        return failMissingReflectionCapability(env, "source_text");
    }

    const value = try eval(env, args[0]);
    const ctx = env.struct_ctx orelse return CtValue{ .string = "" };
    const meta = ctValueNodeMeta(value) orelse return CtValue{ .string = "" };
    const text = sourceSlice(meta, ctx.graph) orelse "";
    const buf = env.alloc.alloc(u8, text.len) catch return MacroEvalError.OutOfMemory;
    @memcpy(buf, text);
    return CtValue{ .string = buf };
}

/// `source_location(expr)`: return `path:line` for an AST node.
/// Missing spans, generated nodes, or unavailable source metadata return the
/// empty string so macros can omit location output without failing expansion.
fn sourceLocationIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return CtValue{ .string = "" };
    if (!hasReflectionCapability(env)) {
        return failMissingReflectionCapability(env, "source_location");
    }

    const value = try eval(env, args[0]);
    const ctx = env.struct_ctx orelse return CtValue{ .string = "" };
    const meta = ctValueNodeMeta(value) orelse return CtValue{ .string = "" };
    const source_id = meta.span.source_id orelse return CtValue{ .string = "" };
    const path = ctx.graph.sourcePathById(source_id) orelse return CtValue{ .string = "" };
    if (path.len == 0) return CtValue{ .string = "" };

    const source = ctx.graph.sourceContentById(source_id);
    const line = if (source.len > 0)
        lineNumberFromOffset(source, meta.span.start)
    else
        meta.span.line;
    if (line == 0) return CtValue{ .string = "" };

    return CtValue{ .string = std.fmt.allocPrint(env.alloc, "{s}:{d}", .{ path, line }) catch return MacroEvalError.OutOfMemory };
}

fn ctValueNodeMeta(value: CtValue) ?ast.NodeMeta {
    if (value != .tuple or value.tuple.elems.len != 3) return null;
    const meta_value = value.tuple.elems[1];
    if (meta_value != .list) return null;

    var span = ast.SourceSpan{ .start = 0, .end = 0 };
    for (meta_value.list.elems) |pair| {
        if (pair != .tuple or pair.tuple.elems.len != 2) continue;
        if (pair.tuple.elems[0] != .atom or pair.tuple.elems[1] != .int) continue;
        const key = pair.tuple.elems[0].atom;
        const value_int = pair.tuple.elems[1].int;
        if (std.mem.eql(u8, key, "start")) {
            span.start = @intCast(value_int);
        } else if (std.mem.eql(u8, key, "end")) {
            span.end = @intCast(value_int);
        } else if (std.mem.eql(u8, key, "line")) {
            span.line = @intCast(value_int);
        } else if (std.mem.eql(u8, key, "col")) {
            span.col = @intCast(value_int);
        } else if (std.mem.eql(u8, key, "source_id")) {
            span.source_id = @intCast(value_int);
        }
    }

    return ast.NodeMeta{ .span = span };
}

/// `slugify(string_value)`: convert a string to a snake-
/// case identifier suitable for use as a function name. Spaces,
/// dashes, and other non-alphanumerics become underscores; uppercase
/// letters become lowercase. Returns the string CtValue.
fn slugifyIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    const val = try eval(env, args[0]);
    const input = extractString(val) orelse return .nil;
    const out = try slugifyString(env.alloc, input);
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
    const prefixed = try std.fmt.allocPrint(env.alloc, ":{s}", .{input});
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
        .map => |m| {
            std.debug.print("%{{", .{});
            for (m.entries, 0..) |entry, i| {
                if (i > 0) std.debug.print(", ", .{});
                debugPrintCtValue(entry.key, max_depth - 1);
                std.debug.print(" => ", .{});
                debugPrintCtValue(entry.value, max_depth - 1);
            }
            std.debug.print("}}", .{});
        },
        .struct_val => std.debug.print("<struct>", .{}),
        .union_val => std.debug.print("<union>", .{}),
        .enum_val => std.debug.print("<enum>", .{}),
        .optional => std.debug.print("<optional>", .{}),
        .closure => std.debug.print("<closure>", .{}),
    }
}

fn unwrapAstLiteral(val: CtValue) CtValue {
    // A bare atom carrying a leading `:` is unambiguously an atom
    // literal at the CtValue layer — variables never start with `:`,
    // so the prefix is the only thing that distinguishes a stored
    // atom literal from a variable reference. Strip it so equality
    // and map-key comparisons match the unwrapped lookup keys.
    if (val == .atom and val.atom.len > 0 and val.atom[0] == ':') {
        return CtValue{ .atom = val.atom[1..] };
    }
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

fn ctMapKeyEql(env: *Env, left_raw: CtValue, right_raw: CtValue) MacroEvalError!bool {
    const left = unwrapAstLiteral(left_raw);
    const right = unwrapAstLiteral(right_raw);
    return left.eql(right) catch |err| return macroValueTraversalFailure(env, err);
}

fn structIntrinsicGet(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    const name_val = try eval(env, args[0]);
    const ctx = env.struct_ctx orelse return .nil;
    const scope_id = attributeStructScope(ctx) orelse return .nil;
    const mod_entry = ctx.graph.findStructByScope(scope_id) orelse return .nil;

    const name_str = extractAtomName(name_val) orelse return .nil;
    const name_id = ctx.interner.intern(name_str) catch return error.OutOfMemory;
    var cv_opt = ctx.graph.getStructAttribute(mod_entry, name_id) catch return error.OutOfMemory;
    if (cv_opt) |*cv| {
        defer cv.deinit(ctx.graph.allocator);
        return reimportStoredAttributeValue(env, name_str, cv.value);
    }
    return .nil;
}

fn structIntrinsicRegister(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len < 1) return .nil;
    const name_val = try eval(env, args[0]);
    const ctx = env.struct_ctx orelse return .nil;
    const scope_id = attributeStructScope(ctx) orelse return .nil;
    const mod_entry = ctx.graph.findStructByScope(scope_id) orelse return .nil;

    const name_str = extractAtomName(name_val) orelse return .nil;
    const name_id = ctx.interner.intern(name_str) catch |err|
        return failIntrinsicInfrastructure(env, "struct_register_attribute", "interning attribute name", err);
    ctx.graph.registerAccumulatingAttribute(mod_entry, name_id) catch |err|
        return failIntrinsicInfrastructure(env, "struct_register_attribute", "registering accumulating attribute", err);
    return .nil;
}

fn attributeStructScope(ctx: StructContext) ?scope.ScopeId {
    return ctx.attribute_struct_scope orelse ctx.current_struct_scope;
}

fn sourceGraphStructsIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        return failMissingReflectionCapability(env, "source_graph_structs");
    }

    const paths_raw = try eval(env, args[0]);
    const paths = try extractPathFilterOrDiagnostic(env, "source_graph_structs", paths_raw);
    defer if (paths.len > 0) env.alloc.free(paths);
    const ctx = env.struct_ctx orelse return .nil;

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    errdefer deinitReflectionResultList(env.alloc, &result_list);
    for (ctx.graph.structs.items) |struct_entry| {
        const source_id = struct_entry.decl.meta.span.source_id orelse continue;
        const path = ctx.graph.sourcePathById(source_id) orelse continue;
        if (!try pathFilterContains(env.alloc, paths, path)) continue;
        const struct_ref = try makeStructRef(env, ctx.interner, struct_entry, path, source_id);
        try appendOwnedReflectionResultValue(env.alloc, &result_list, struct_ref);
    }

    const id = try env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = result_list.items } };
}

fn structFunctionsIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        return failMissingReflectionCapability(env, "struct_functions");
    }

    const ctx = env.struct_ctx orelse return .nil;
    const ref_value = try eval(env, args[0]);
    const struct_name_ref = (try extractStructRefName(env.alloc, ref_value)) orelse return .nil;
    defer struct_name_ref.deinit(env.alloc);
    const struct_name = struct_name_ref.bytes();
    const struct_scope_id = findStructScopeByName(ctx.graph, ctx.interner, struct_name) orelse return .nil;
    const struct_scope = ctx.graph.getScope(struct_scope_id);

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    errdefer deinitReflectionResultList(env.alloc, &result_list);
    var family_iter = struct_scope.function_families.iterator();
    while (family_iter.next()) |entry| {
        const family = &ctx.graph.families.items[entry.value_ptr.*];
        if (family.visibility != .public) continue;
        if (family.clauses.items.len == 0) continue;
        // Skip impl-block functions that were reparented into the target
        // struct's scope by `registerImplFunctionsInTargetScopes`. The
        // family's primary `scope_id` still points at its declaring impl
        // block, so a mismatch with the struct scope is the signal that
        // this family belongs to a protocol-impl namespace, not to the
        // struct itself. The legacy doc generator applied the same
        // filter; without it `Integer` and similar structs end up
        // listing every protocol operator alongside their own functions.
        if (family.scope_id != struct_scope_id) continue;
        const name = ctx.interner.get(family.name);
        const owned_doc_text = try extractDocAttributeText(env.alloc, ctx.interner, family.attributes);
        var doc_text_transferred = false;
        errdefer if (!doc_text_transferred) deinitOptionalOwnedReflectionText(env.alloc, owned_doc_text);
        const loc = declSourceLocation(ctx.graph, family.clauses.items[0].decl.meta);
        const owned_signatures = try buildReflectionClauseSignatures(env.alloc, name, family.clauses.items, ctx.interner, ctx.graph);
        doc_text_transferred = true;
        const function_ref = try makeFunctionRef(env, name, family.arity, family.visibility, owned_doc_text, loc.path, loc.line, owned_signatures);
        try appendOwnedReflectionResultValue(env.alloc, &result_list, function_ref);
    }

    const id = try env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = result_list.items } };
}

/// Enumerate every public protocol declared in any of the source paths
/// supplied. Each result is an `__aliases__` AST ref pointing at the
/// protocol — the same shape as `source_graph_structs`, so callers can
/// hand the result to `struct_info` for protocol-level metadata.
fn sourceGraphProtocolsIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        return failMissingReflectionCapability(env, "source_graph_protocols");
    }

    const paths_raw = try eval(env, args[0]);
    const paths = try extractPathFilterOrDiagnostic(env, "source_graph_protocols", paths_raw);
    defer if (paths.len > 0) env.alloc.free(paths);
    const ctx = env.struct_ctx orelse return .nil;

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    errdefer deinitReflectionResultList(env.alloc, &result_list);
    for (ctx.graph.protocols.items) |protocol_entry| {
        if (protocol_entry.decl.is_private) continue;
        const source_id = protocol_entry.decl.meta.span.source_id orelse continue;
        const path = ctx.graph.sourcePathById(source_id) orelse continue;
        if (!try pathFilterContains(env.alloc, paths, path)) continue;
        const protocol_ref = try makeAliasRef(env, ctx.interner, protocol_entry.name);
        try appendOwnedReflectionResultValue(env.alloc, &result_list, protocol_ref);
    }

    const id = try env.store.alloc(env.alloc, .list, null);
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
        return failMissingReflectionCapability(env, "source_graph_unions");
    }

    const paths_raw = try eval(env, args[0]);
    const paths = try extractPathFilterOrDiagnostic(env, "source_graph_unions", paths_raw);
    defer if (paths.len > 0) env.alloc.free(paths);
    const ctx = env.struct_ctx orelse return .nil;

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    errdefer deinitReflectionResultList(env.alloc, &result_list);
    for (ctx.graph.types.items) |type_entry| {
        const union_decl = switch (type_entry.kind) {
            .union_type => |u| u,
            else => continue,
        };
        if (union_decl.is_private) continue;
        const source_id = union_decl.meta.span.source_id orelse continue;
        const path = ctx.graph.sourcePathById(source_id) orelse continue;
        if (!try pathFilterContains(env.alloc, paths, path)) continue;
        // Fabricate a single-segment StructName from the registered
        // union name so the alias-ref shape matches the other source
        // graph results. Dotted names declared at top-level (e.g.
        // `IO.Mode`) are interned as a single string by the parser, so
        // a single-segment ref still round-trips through the resolver.
        const name = ast.StructName{
            .parts = &[_]ast.StringId{type_entry.name},
            .span = union_decl.meta.span,
        };
        const union_ref = try makeAliasRef(env, ctx.interner, name);
        try appendOwnedReflectionResultValue(env.alloc, &result_list, union_ref);
    }

    const id = try env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = result_list.items } };
}

/// Enumerate every public protocol implementation declared in any of
/// the source paths supplied. Each result is a compile-time map with
/// `:protocol` (the qualified protocol name as a string), `:target`
/// (the qualified target type name), `:source_file`, and `:is_private`.
/// Doc generation uses this to render the per-type "Implements" row.
fn sourceGraphImplsIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        return failMissingReflectionCapability(env, "source_graph_impls");
    }

    const paths_raw = try eval(env, args[0]);
    const paths = try extractPathFilterOrDiagnostic(env, "source_graph_impls", paths_raw);
    defer if (paths.len > 0) env.alloc.free(paths);
    const ctx = env.struct_ctx orelse return .nil;

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    errdefer deinitReflectionResultList(env.alloc, &result_list);
    for (ctx.graph.impls.items) |impl_entry| {
        if (impl_entry.is_private) continue;
        const source_id = impl_entry.decl.meta.span.source_id orelse continue;
        const path = ctx.graph.sourcePathById(source_id) orelse continue;
        if (!try pathFilterContains(env.alloc, paths, path)) continue;

        const impl_ref = try makeImplRef(env, ctx.interner, impl_entry, path);
        try appendOwnedReflectionResultValue(env.alloc, &result_list, impl_ref);
    }

    const id = try env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = result_list.items } };
}

/// Render a `StructName`'s segments joined with `.` so reflection
/// callers can identify a protocol or target type with a plain string
/// (matching the format the doc generator uses for cross-links).
fn structNameToString(alloc: Allocator, interner: *ast.StringInterner, name: ast.StructName) ![]const u8 {
    if (name.parts.len == 0) return "";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (name.parts, 0..) |part, i| {
        if (i > 0) try buf.append(alloc, '.');
        try buf.appendSlice(alloc, interner.get(part));
    }
    return buf.toOwnedSlice(alloc);
}

/// Reflect on the variants of a union type. Each result is a
/// compile-time map with `:name` and `:signature`. The signature is
/// `Variant` for bare variants and `Variant :: TypeExpr` for typed
/// payload variants — the same shape `signature.buildUnionVariantSignature`
/// produces for the in-tree doc generator.
fn unionVariantsIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        return failMissingReflectionCapability(env, "union_variants");
    }

    const ctx = env.struct_ctx orelse return .nil;
    const ref_value = try eval(env, args[0]);
    const union_name_ref = (try extractStructRefName(env.alloc, ref_value)) orelse return .nil;
    defer union_name_ref.deinit(env.alloc);
    const union_name = union_name_ref.bytes();

    var union_decl: ?*const ast.UnionDecl = null;
    for (ctx.graph.types.items) |type_entry| {
        const decl = switch (type_entry.kind) {
            .union_type => |u| u,
            else => continue,
        };
        const local_name = ctx.interner.get(type_entry.name);
        if (!std.mem.eql(u8, local_name, union_name)) continue;
        union_decl = decl;
        break;
    }
    const decl = union_decl orelse return .nil;

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    errdefer deinitReflectionResultList(env.alloc, &result_list);
    for (decl.variants) |variant| {
        const sig = try signature.buildUnionVariantSignature(env.alloc, variant, ctx.interner);
        const variant_ref = try makeNamedSignatureRef(env, ctx.interner.get(variant.name), sig);
        try appendOwnedReflectionResultValue(env.alloc, &result_list, variant_ref);
    }

    const id = try env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = result_list.items } };
}

/// Reflect on the required functions a protocol declares. Each result
/// is a compile-time map with `:name` and `:signature` (the bare
/// `next(state) -> {Atom, element, Enumerable(element)}` form), letting
/// the doc generator render the protocol's contract surface alongside
/// the protocol's own `@doc`.
fn protocolRequiredFunctionsIntrinsic(env: *Env, args: []const CtValue) MacroEvalError!CtValue {
    if (args.len != 1) return .nil;
    if (!hasReflectionCapability(env)) {
        return failMissingReflectionCapability(env, "protocol_required_functions");
    }

    const ctx = env.struct_ctx orelse return .nil;
    const ref_value = try eval(env, args[0]);
    const protocol_name_ref = (try extractStructRefName(env.alloc, ref_value)) orelse return .nil;
    defer protocol_name_ref.deinit(env.alloc);
    const protocol_name = protocol_name_ref.bytes();

    var protocol_decl: ?*const ast.ProtocolDecl = null;
    for (ctx.graph.protocols.items) |entry| {
        if (!structNameMatches(ctx.interner, entry.name, protocol_name)) continue;
        protocol_decl = entry.decl;
        break;
    }
    const decl = protocol_decl orelse return .nil;

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    errdefer deinitReflectionResultList(env.alloc, &result_list);
    for (decl.functions) |fn_sig| {
        const sig = try signature.buildProtocolFunctionSignature(env.alloc, fn_sig, ctx.interner);
        const required_function_ref = try makeNamedSignatureRef(env, ctx.interner.get(fn_sig.name), sig);
        try appendOwnedReflectionResultValue(env.alloc, &result_list, required_function_ref);
    }

    const id = try env.store.alloc(env.alloc, .list, null);
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
        return failMissingReflectionCapability(env, "struct_macros");
    }

    const ctx = env.struct_ctx orelse return .nil;
    const ref_value = try eval(env, args[0]);
    const struct_name_ref = (try extractStructRefName(env.alloc, ref_value)) orelse return .nil;
    defer struct_name_ref.deinit(env.alloc);
    const struct_name = struct_name_ref.bytes();
    const struct_scope_id = findStructScopeByName(ctx.graph, ctx.interner, struct_name) orelse return .nil;
    const struct_scope = ctx.graph.getScope(struct_scope_id);

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    errdefer deinitReflectionResultList(env.alloc, &result_list);
    var iter = struct_scope.macros.iterator();
    while (iter.next()) |entry| {
        const family = &ctx.graph.macro_families.items[entry.value_ptr.*];
        if (family.clauses.items.len == 0) continue;
        const visibility = family.clauses.items[0].decl.visibility;
        if (visibility != .public) continue;
        const name = ctx.interner.get(family.name);
        if (std.mem.startsWith(u8, name, "__")) continue;
        const owned_doc_text = try extractDocAttributeText(env.alloc, ctx.interner, family.attributes);
        var doc_text_transferred = false;
        errdefer if (!doc_text_transferred) deinitOptionalOwnedReflectionText(env.alloc, owned_doc_text);
        const loc = declSourceLocation(ctx.graph, family.clauses.items[0].decl.meta);
        const owned_signatures = try buildReflectionClauseSignatures(env.alloc, name, family.clauses.items, ctx.interner, ctx.graph);
        doc_text_transferred = true;
        const macro_ref = try makeFunctionRef(env, name, family.arity, visibility, owned_doc_text, loc.path, loc.line, owned_signatures);
        try appendOwnedReflectionResultValue(env.alloc, &result_list, macro_ref);
    }

    const id = try env.store.alloc(env.alloc, .list, null);
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
        return failMissingReflectionCapability(env, "struct_info");
    }

    const ctx = env.struct_ctx orelse return .nil;
    const ref_value = try eval(env, args[0]);
    const struct_name_ref = (try extractStructRefName(env.alloc, ref_value)) orelse return .nil;
    defer struct_name_ref.deinit(env.alloc);
    const struct_name = struct_name_ref.bytes();

    // Look up struct, protocol, and union entries by name. The same
    // `struct_info` intrinsic answers for any of them — refs returned
    // from the source-graph reflection intrinsics are interchangeable.
    for (ctx.graph.structs.items) |entry| {
        if (!structNameMatches(ctx.interner, entry.name, struct_name)) continue;
        const doc_text = (try extractDocAttributeText(env.alloc, ctx.interner, entry.attributes)) orelse "";
        return makeDeclInfoMapWithDoc(env, ctx, struct_name, entry.decl.meta, entry.decl.is_private, doc_text);
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
    const doc_text = (try extractDocAttributeText(env.alloc, ctx.interner, attributes)) orelse "";

    return makeDeclInfoMapWithDoc(env, ctx, name, meta, is_private, doc_text);
}

fn makeDeclInfoMapWithDoc(
    env: *Env,
    ctx: StructContext,
    name: []const u8,
    meta: ast.NodeMeta,
    is_private: bool,
    doc_text: []const u8,
) !CtValue {
    const source_id = meta.span.source_id orelse 0;
    const source_path = ctx.graph.sourcePathById(source_id) orelse "";

    const entries = try env.alloc.alloc(CtValue.CtMapEntry, 4);
    entries[0] = .{ .key = .{ .atom = ":name" }, .value = .{ .string = try env.alloc.dupe(u8, name) } };
    entries[1] = .{ .key = .{ .atom = ":source_file" }, .value = .{ .string = source_path } };
    entries[2] = .{ .key = .{ .atom = ":is_private" }, .value = .{ .bool_val = is_private } };
    entries[3] = .{ .key = .{ .atom = ":doc" }, .value = .{ .string = doc_text } };
    const id = try env.store.alloc(env.alloc, .map, null);
    return CtValue{ .map = .{ .alloc_id = id, .entries = entries } };
}

fn hasReflectionCapability(env: *const Env) bool {
    return env.current_macro_caps.has(.reflect_source) or env.current_macro_caps.has(.reflect_struct);
}

fn deinitReflectionResultList(alloc: Allocator, values: *std.ArrayListUnmanaged(CtValue)) void {
    deinitReflectionResultValueSlice(alloc, values.items);
    values.deinit(alloc);
}

fn appendOwnedReflectionResultValue(
    alloc: Allocator,
    values: *std.ArrayListUnmanaged(CtValue),
    value: CtValue,
) Allocator.Error!void {
    errdefer deinitReflectionResultValue(alloc, value);
    try values.append(alloc, value);
}

fn deinitReflectionResultValueSlice(alloc: Allocator, values: []const CtValue) void {
    for (values) |value| {
        deinitReflectionResultValue(alloc, value);
    }
}

fn deinitReflectionResultValue(alloc: Allocator, value: CtValue) void {
    switch (value) {
        .tuple => |tuple_value| {
            deinitReflectionResultValueSlice(alloc, tuple_value.elems);
            if (tuple_value.elems.len > 0) alloc.free(tuple_value.elems);
        },
        .list => |list_value| {
            deinitReflectionResultValueSlice(alloc, list_value.elems);
            if (list_value.elems.len > 0) alloc.free(list_value.elems);
        },
        .map => |map_value| {
            deinitReflectionMapEntries(alloc, map_value.entries);
            if (map_value.entries.len > 0) alloc.free(map_value.entries);
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
        .struct_val,
        .union_val,
        .enum_val,
        .optional,
        .closure,
        => {},
    }
}

fn deinitReflectionMapEntries(alloc: Allocator, entries: []const CtValue.CtMapEntry) void {
    for (entries) |entry| {
        const key = reflectionMapKey(entry.key) orelse continue;
        if (std.mem.eql(u8, key, "protocol") or
            std.mem.eql(u8, key, "target") or
            std.mem.eql(u8, key, "signature") or
            std.mem.eql(u8, key, "doc"))
        {
            deinitOwnedReflectionString(alloc, entry.value);
        } else if (std.mem.eql(u8, key, "visibility")) {
            deinitOwnedReflectionAtom(alloc, entry.value);
        } else if (std.mem.eql(u8, key, "signatures")) {
            deinitReflectionSignatureListValue(alloc, entry.value);
        }
    }
}

fn reflectionMapKey(value: CtValue) ?[]const u8 {
    const unwrapped = unwrapAstLiteral(value);
    return switch (unwrapped) {
        .atom => |name| stripAtomLiteralPrefix(name),
        .string => |name| name,
        else => null,
    };
}

fn deinitReflectionSignatureListValue(alloc: Allocator, value: CtValue) void {
    if (value != .list) {
        deinitReflectionResultValue(alloc, value);
        return;
    }

    deinitReflectionSignatureElems(alloc, value.list.elems);
}

fn deinitReflectionSignatureElems(alloc: Allocator, elems: []const CtValue) void {
    for (elems) |elem| {
        if (elem == .string) {
            if (elem.string.len > 0) alloc.free(elem.string);
        } else {
            deinitReflectionResultValue(alloc, elem);
        }
    }
    if (elems.len > 0) alloc.free(elems);
}

fn deinitOptionalOwnedReflectionText(alloc: Allocator, maybe_text: ?[]const u8) void {
    if (maybe_text) |text| {
        if (text.len > 0) alloc.free(text);
    }
}

fn deinitOwnedReflectionString(alloc: Allocator, value: CtValue) void {
    if (value == .string and value.string.len > 0) {
        alloc.free(value.string);
    }
}

fn deinitOwnedReflectionAtom(alloc: Allocator, value: CtValue) void {
    if (value == .atom and value.atom.len > 0) {
        alloc.free(value.atom);
    }
}

fn deinitOwnedReflectionSignatureSlice(alloc: Allocator, signatures: []const []const u8) void {
    for (signatures) |signature_text| {
        if (signature_text.len > 0) alloc.free(signature_text);
    }
    if (signatures.len > 0) alloc.free(signatures);
}

const PathFilterError = Allocator.Error || error{InvalidPathFilter};

fn extractPathFilterOrDiagnostic(
    env: *Env,
    intrinsic_name: []const u8,
    value: CtValue,
) MacroEvalError![]const []const u8 {
    return extractPathFilter(env, value) catch |err|
        return failIntrinsicInfrastructure(env, intrinsic_name, "decoding source path filter", err);
}

fn extractPathFilter(env: *Env, value: CtValue) PathFilterError![]const []const u8 {
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

fn extractStructRefName(alloc: Allocator, value: CtValue) !?ExtractedStructRefName {
    const unwrapped = unwrapAstLiteral(value);
    return switch (unwrapped) {
        .string => |name| .{ .borrowed = name },
        .atom => |name| .{ .borrowed = name },
        .tuple => |tuple| blk: {
            if (tuple.elems.len != 3) break :blk null;
            if (tuple.elems[0] != .atom or !std.mem.eql(u8, tuple.elems[0].atom, "__aliases__")) break :blk null;
            if (tuple.elems[2] != .list) break :blk null;
            var buffer: std.ArrayListUnmanaged(u8) = .empty;
            errdefer buffer.deinit(alloc);
            for (tuple.elems[2].list.elems, 0..) |part, index| {
                if (part != .atom) {
                    buffer.deinit(alloc);
                    break :blk null;
                }
                if (index > 0) try buffer.append(alloc, '.');
                try buffer.appendSlice(alloc, stripAtomLiteralPrefix(part.atom));
            }
            break :blk .{ .owned = try buffer.toOwnedSlice(alloc) };
        },
        .map => |map| blk: {
            for (map.entries) |entry| {
                const key = unwrapAstLiteral(entry.key);
                if (key == .atom and std.mem.eql(u8, key.atom, "name")) {
                    const val = unwrapAstLiteral(entry.value);
                    if (val == .string) break :blk .{ .borrowed = val.string };
                    if (val == .atom) break :blk .{ .borrowed = val.atom };
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
    defer parts.deinit(env.alloc);
    for (name.parts) |part| {
        try parts.append(env.alloc, .{ .atom = interner.get(part) });
    }

    const meta = try makeReflectionEmptyList(env);
    var meta_transferred = false;
    errdefer if (!meta_transferred) deinitReflectionResultValue(env.alloc, meta);

    const args = try makeReflectionListFromSlice(env, parts.items);
    var args_transferred = false;
    errdefer if (!args_transferred) deinitReflectionResultValue(env.alloc, args);

    meta_transferred = true;
    args_transferred = true;
    return makeReflectionTuple3(env, .{ .atom = "__aliases__" }, meta, args);
}

fn makeReflectionEmptyList(env: *Env) Allocator.Error!CtValue {
    const id = try env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = &.{} } };
}

fn makeReflectionListFromSlice(env: *Env, items: []const CtValue) Allocator.Error!CtValue {
    const elems = try env.alloc.alloc(CtValue, items.len);
    errdefer if (elems.len > 0) env.alloc.free(elems);
    @memcpy(elems, items);
    const id = try env.store.alloc(env.alloc, .list, null);
    return CtValue{ .list = .{ .alloc_id = id, .elems = elems } };
}

fn makeReflectionTuple3(env: *Env, form: CtValue, meta: CtValue, args: CtValue) Allocator.Error!CtValue {
    var meta_transferred = false;
    errdefer if (!meta_transferred) deinitReflectionResultValue(env.alloc, meta);
    var args_transferred = false;
    errdefer if (!args_transferred) deinitReflectionResultValue(env.alloc, args);

    const elems = try env.alloc.alloc(CtValue, 3);
    elems[0] = form;
    elems[1] = meta;
    elems[2] = args;
    meta_transferred = true;
    args_transferred = true;

    var elems_transferred = false;
    errdefer if (!elems_transferred) {
        deinitReflectionResultValueSlice(env.alloc, elems);
        if (elems.len > 0) env.alloc.free(elems);
    };

    const id = try env.store.alloc(env.alloc, .tuple, null);
    elems_transferred = true;
    return CtValue{ .tuple = .{ .alloc_id = id, .elems = elems } };
}

fn makeImplRef(
    env: *Env,
    interner: *ast.StringInterner,
    impl_entry: scope.ImplEntry,
    path: []const u8,
) !CtValue {
    const protocol_name = try structNameToString(env.alloc, interner, impl_entry.protocol_name);
    var protocol_name_transferred = false;
    errdefer if (!protocol_name_transferred and protocol_name.len > 0) env.alloc.free(protocol_name);

    const target_name = try structNameToString(env.alloc, interner, impl_entry.target_type);
    var target_name_transferred = false;
    errdefer if (!target_name_transferred and target_name.len > 0) env.alloc.free(target_name);

    const entries = try env.alloc.alloc(CtValue.CtMapEntry, 4);
    entries[0] = .{ .key = .{ .atom = ":protocol" }, .value = .{ .string = protocol_name } };
    entries[1] = .{ .key = .{ .atom = ":target" }, .value = .{ .string = target_name } };
    entries[2] = .{ .key = .{ .atom = ":source_file" }, .value = .{ .string = path } };
    entries[3] = .{ .key = .{ .atom = ":is_private" }, .value = .{ .bool_val = impl_entry.is_private } };
    protocol_name_transferred = true;
    target_name_transferred = true;

    var entries_transferred = false;
    errdefer if (!entries_transferred) {
        deinitReflectionMapEntries(env.alloc, entries);
        if (entries.len > 0) env.alloc.free(entries);
    };

    const map_id = try env.store.alloc(env.alloc, .map, null);
    entries_transferred = true;
    return CtValue{ .map = .{ .alloc_id = map_id, .entries = entries } };
}

fn makeNamedSignatureRef(env: *Env, name: []const u8, owned_signature: []const u8) !CtValue {
    var signature_transferred = false;
    errdefer if (!signature_transferred and owned_signature.len > 0) env.alloc.free(owned_signature);

    const entries = try env.alloc.alloc(CtValue.CtMapEntry, 2);
    entries[0] = .{ .key = .{ .atom = ":name" }, .value = .{ .string = name } };
    entries[1] = .{ .key = .{ .atom = ":signature" }, .value = .{ .string = owned_signature } };
    signature_transferred = true;

    var entries_transferred = false;
    errdefer if (!entries_transferred) {
        deinitReflectionMapEntries(env.alloc, entries);
        if (entries.len > 0) env.alloc.free(entries);
    };

    const map_id = try env.store.alloc(env.alloc, .map, null);
    entries_transferred = true;
    return CtValue{ .map = .{ .alloc_id = map_id, .entries = entries } };
}

fn makeFunctionRef(
    env: *Env,
    name: []const u8,
    arity: u32,
    visibility: ast.FunctionDecl.Visibility,
    owned_doc_text: ?[]const u8,
    source_file: []const u8,
    source_line: u32,
    owned_signatures: []const []const u8,
) !CtValue {
    var doc_text_transferred = false;
    errdefer if (!doc_text_transferred) deinitOptionalOwnedReflectionText(env.alloc, owned_doc_text);

    var signature_texts_transferred = false;
    errdefer if (!signature_texts_transferred) deinitOwnedReflectionSignatureSlice(env.alloc, owned_signatures);

    const sig_elems = try env.alloc.alloc(CtValue, owned_signatures.len);
    for (owned_signatures, 0..) |signature_text, index| {
        sig_elems[index] = .{ .string = signature_text };
    }
    if (owned_signatures.len > 0) env.alloc.free(owned_signatures);
    signature_texts_transferred = true;

    var sig_elems_transferred = false;
    errdefer if (!sig_elems_transferred) deinitReflectionSignatureElems(env.alloc, sig_elems);

    const sig_list_id = try env.store.alloc(env.alloc, .list, null);
    const signatures_value = CtValue{ .list = .{ .alloc_id = sig_list_id, .elems = sig_elems } };
    sig_elems_transferred = true;
    var signatures_value_transferred = false;
    errdefer if (!signatures_value_transferred) deinitReflectionSignatureListValue(env.alloc, signatures_value);

    const visibility_atom = try std.fmt.allocPrint(env.alloc, ":{s}", .{@tagName(visibility)});
    var visibility_atom_transferred = false;
    errdefer if (!visibility_atom_transferred) env.alloc.free(visibility_atom);

    const doc_text = owned_doc_text orelse "";
    const entries = try env.alloc.alloc(CtValue.CtMapEntry, 7);
    entries[0] = .{ .key = .{ .atom = ":name" }, .value = .{ .string = name } };
    entries[1] = .{ .key = .{ .atom = ":arity" }, .value = .{ .int = @intCast(arity) } };
    entries[2] = .{ .key = .{ .atom = ":visibility" }, .value = .{ .atom = visibility_atom } };
    entries[3] = .{ .key = .{ .atom = ":doc" }, .value = .{ .string = doc_text } };
    entries[4] = .{ .key = .{ .atom = ":source_file" }, .value = .{ .string = source_file } };
    entries[5] = .{ .key = .{ .atom = ":source_line" }, .value = .{ .int = @intCast(source_line) } };
    entries[6] = .{ .key = .{ .atom = ":signatures" }, .value = signatures_value };
    doc_text_transferred = true;
    visibility_atom_transferred = true;
    signatures_value_transferred = true;

    var entries_transferred = false;
    errdefer if (!entries_transferred) {
        deinitReflectionMapEntries(env.alloc, entries);
        if (entries.len > 0) env.alloc.free(entries);
    };

    const id = try env.store.alloc(env.alloc, .map, null);
    entries_transferred = true;
    return CtValue{ .map = .{ .alloc_id = id, .entries = entries } };
}

/// Convert a 0-based byte offset into a 1-based line number using the
/// source bytes. Returns 0 when `offset` exceeds `source.len`.
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

fn buildReflectionClauseSignatures(
    alloc: Allocator,
    function_name: []const u8,
    clauses: []const scope.FunctionClauseRef,
    interner: *const ast.StringInterner,
    graph: *const scope.ScopeGraph,
) Allocator.Error![]const []const u8 {
    var signatures: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (signatures.items) |signature_text| alloc.free(signature_text);
        signatures.deinit(alloc);
    }

    for (clauses) |clause_ref| {
        if (clause_ref.clause_index >= clause_ref.decl.clauses.len) continue;
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];
        const rendered = try buildReflectionClauseSignature(alloc, function_name, clause, interner, graph);
        errdefer alloc.free(rendered);
        try signatures.append(alloc, rendered);
    }
    if (signatures.items.len == 0) {
        const rendered = try std.fmt.allocPrint(alloc, "{s}()", .{function_name});
        errdefer alloc.free(rendered);
        try signatures.append(alloc, rendered);
    }
    return signatures.toOwnedSlice(alloc);
}

fn buildReflectionClauseSignature(
    alloc: Allocator,
    function_name: []const u8,
    clause: ast.FunctionClause,
    interner: *const ast.StringInterner,
    graph: *const scope.ScopeGraph,
) Allocator.Error![]const u8 {
    var buf = signature.Buffer.init(alloc);
    errdefer buf.deinit();

    try buf.str(function_name);
    try buf.char('(');
    for (clause.params, 0..) |param, index| {
        if (index > 0) try buf.str(", ");
        try signature.appendPattern(&buf, param.pattern, interner, graph);
        if (param.type_annotation) |type_annotation| {
            try buf.str(" :: ");
            try appendReflectionTypeExpr(&buf, type_annotation, interner, graph);
        }
        if (param.default) |default_expr| {
            try buf.str(" = ");
            try signature.appendExpr(&buf, default_expr, interner, graph);
        }
    }
    try buf.char(')');
    if (clause.return_type) |return_type| {
        try buf.str(" -> ");
        try appendReflectionTypeExpr(&buf, return_type, interner, graph);
    }
    if (clause.refinement) |refinement| {
        try buf.str(" if ");
        try signature.appendExpr(&buf, refinement, interner, graph);
    }
    return buf.toOwnedSlice();
}

fn appendReflectionTypeExpr(
    buf: *signature.Buffer,
    type_expr: *const ast.TypeExpr,
    interner: *const ast.StringInterner,
    graph: *const scope.ScopeGraph,
) Allocator.Error!void {
    if (sourceSlice(type_expr.getMeta(), graph)) |text| {
        try buf.str(text);
        return;
    }

    switch (type_expr.*) {
        .name => |name_expr| {
            try buf.str(interner.get(name_expr.name));
            try appendReflectionTypeArgs(buf, name_expr.args, interner, graph);
        },
        .variable => |variable| try buf.str(interner.get(variable.name)),
        .list => |list| {
            try buf.char('[');
            try appendReflectionTypeExpr(buf, list.element, interner, graph);
            try buf.char(']');
        },
        .tuple => |tuple| {
            try buf.char('{');
            for (tuple.elements, 0..) |element, index| {
                if (index > 0) try buf.str(", ");
                try appendReflectionTypeExpr(buf, element, interner, graph);
            }
            try buf.char('}');
        },
        .map => |map| {
            try buf.str("%{");
            for (map.fields, 0..) |field, index| {
                if (index > 0) try buf.str(", ");
                try appendReflectionTypeExpr(buf, field.key, interner, graph);
                try buf.str(" => ");
                try appendReflectionTypeExpr(buf, field.value, interner, graph);
            }
            try buf.char('}');
        },
        .struct_type => |struct_type| {
            try buf.char('%');
            try signature.appendStructName(buf, struct_type.struct_name, interner);
            try buf.char('{');
            for (struct_type.fields, 0..) |field, index| {
                if (index > 0) try buf.str(", ");
                try buf.str(interner.get(field.name));
                try buf.str(" :: ");
                try appendReflectionTypeExpr(buf, field.type_expr, interner, graph);
            }
            try buf.char('}');
        },
        .union_type => |union_type| {
            for (union_type.members, 0..) |member, index| {
                if (index > 0) try buf.str(" | ");
                try appendReflectionTypeExpr(buf, member, interner, graph);
            }
        },
        .function => |function_type| {
            // A function-TYPE annotation reflects in the current surface
            // syntax `fn(P...) -> R`, matching the form the parser accepts
            // and `signature.appendTypeExpr`. (A function DECLARATION return
            // type `name(P...) -> R` is rendered by the clause-signature path
            // above and stays unparenthesized.)
            try buf.str("fn(");
            for (function_type.params, 0..) |param, index| {
                if (index > 0) try buf.str(", ");
                try appendReflectionTypeExpr(buf, param, interner, graph);
            }
            try buf.str(") -> ");
            try appendReflectionTypeExpr(buf, function_type.return_type, interner, graph);
        },
        .literal => |literal| try appendReflectionTypeLiteral(buf, literal.value, interner),
        .never => try buf.str("Never"),
        .paren => |paren| {
            try buf.char('(');
            try appendReflectionTypeExpr(buf, paren.inner, interner, graph);
            try buf.char(')');
        },
    }
}

fn appendReflectionTypeArgs(
    buf: *signature.Buffer,
    args: []const *const ast.TypeExpr,
    interner: *const ast.StringInterner,
    graph: *const scope.ScopeGraph,
) Allocator.Error!void {
    if (args.len == 0) return;
    try buf.char('(');
    for (args, 0..) |arg, index| {
        if (index > 0) try buf.str(", ");
        try appendReflectionTypeExpr(buf, arg, interner, graph);
    }
    try buf.char(')');
}

fn appendReflectionTypeLiteral(
    buf: *signature.Buffer,
    value: ast.TypeLiteralExpr.LiteralValue,
    interner: *const ast.StringInterner,
) Allocator.Error!void {
    switch (value) {
        .int => |int_value| try buf.fmt("{d}", .{int_value}),
        .string => |string_id| try appendReflectionStringLiteral(buf, interner.get(string_id)),
        .bool_val => |bool_value| try buf.str(if (bool_value) "true" else "false"),
        .nil => try buf.str("nil"),
    }
}

fn appendReflectionStringLiteral(buf: *signature.Buffer, value: []const u8) Allocator.Error!void {
    try buf.char('"');
    for (value) |c| {
        switch (c) {
            '\\' => try buf.str("\\\\"),
            '"' => try buf.str("\\\""),
            '\n' => try buf.str("\\n"),
            '\r' => try buf.str("\\r"),
            '\t' => try buf.str("\\t"),
            else => try buf.char(c),
        }
    }
    try buf.char('"');
}

fn sourceSlice(meta: ast.NodeMeta, graph: *const scope.ScopeGraph) ?[]const u8 {
    const source_id = meta.span.source_id orelse return null;
    const source = graph.sourceContentById(source_id);
    if (source.len == 0) return null;
    if (meta.span.start >= meta.span.end) return null;
    if (meta.span.end > source.len) return null;
    return std.mem.trim(u8, source[meta.span.start..meta.span.end], " \t\r\n");
}

/// Extract the canonical documentation attribute from a declaration.
/// The string is heredoc-stripped (common leading whitespace removed) so
/// multi-line docs round-trip cleanly into runtime literal strings.
fn extractDocAttributeText(
    alloc: Allocator,
    interner: *ast.StringInterner,
    attributes: std.ArrayListUnmanaged(scope.Attribute),
) Allocator.Error!?[]const u8 {
    for (attributes.items) |attr| {
        const name = interner.get(attr.name);
        if (!std.mem.eql(u8, name, "doc")) continue;
        const expr = attr.value orelse return null;
        if (expr.* != .string_literal) return null;
        const raw = interner.get(expr.string_literal.value);
        return try stripHeredocCommonIndent(alloc, raw);
    }
    return null;
}

/// Strip the common leading-whitespace prefix from every non-blank line in
/// `text` so that `@doc = """\n    Body\n    """` round-trips as `"Body"`
/// without the heredoc indentation. Lines that are empty (or whitespace-only)
/// stay empty in the output.
fn stripHeredocCommonIndent(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
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
        return try alloc.dupe(u8, text);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitSequence(u8, text, "\n");
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(alloc, '\n');
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
        try out.appendSlice(alloc, line[start..]);
    }
    return try out.toOwnedSlice(alloc);
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

fn pathFilterContains(alloc: Allocator, paths: []const []const u8, path: []const u8) Allocator.Error!bool {
    for (paths) |candidate| {
        if (try sourcePathsEqual(alloc, candidate, path)) return true;
    }
    return false;
}

fn sourcePathsEqual(alloc: Allocator, left: []const u8, right: []const u8) Allocator.Error!bool {
    const normalized_left = normalizeSourcePath(left);
    const normalized_right = normalizeSourcePath(right);
    if (std.mem.eql(u8, normalized_left, normalized_right)) return true;

    const canonical_left = try canonicalSourcePath(alloc, normalized_left);
    defer alloc.free(canonical_left);
    const canonical_right = try canonicalSourcePath(alloc, normalized_right);
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
fn reimportStoredAttributeValue(env: *Env, attribute_name: []const u8, cv: ctfe.ConstValue) MacroEvalError!CtValue {
    return constValueToCtValue(env, cv) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CannotImport => failWithHardDiagnostic(
            env,
            "cannot reimport stored attribute `{s}`: unsupported ConstValue shape `{s}`",
            .{ attribute_name, @tagName(std.meta.activeTag(cv)) },
        ),
    };
}

const ConstValueImportError = error{
    CannotImport,
    OutOfMemory,
};

fn constValueToCtValue(env: *Env, cv: ctfe.ConstValue) ConstValueImportError!CtValue {
    return switch (cv) {
        .int => |v| CtValue{ .int = v },
        .float => |v| CtValue{ .float = v },
        .string => |v| CtValue{ .string = v },
        .bool_val => |v| CtValue{ .bool_val = v },
        .atom => |v| CtValue{ .atom = v },
        .nil => .nil,
        .void => .void,
        .tuple => |elems| blk: {
            const first_owned_alloc_id = env.store.next_id;
            const result = try env.alloc.alloc(CtValue, elems.len);
            var initialized_count: usize = 0;
            errdefer {
                deinitInitializedTemporaryCtValues(
                    env.alloc,
                    env.store,
                    result,
                    initialized_count,
                    first_owned_alloc_id,
                );
                if (result.len > 0) env.alloc.free(result);
            }
            for (elems, 0..) |e, i| {
                result[i] = try constValueToCtValue(env, e);
                initialized_count += 1;
            }
            const id = try env.store.alloc(env.alloc, .tuple, null);
            break :blk CtValue{ .tuple = .{ .alloc_id = id, .elems = result } };
        },
        .list => |elems| blk: {
            const first_owned_alloc_id = env.store.next_id;
            const result = try env.alloc.alloc(CtValue, elems.len);
            var initialized_count: usize = 0;
            errdefer {
                deinitInitializedTemporaryCtValues(
                    env.alloc,
                    env.store,
                    result,
                    initialized_count,
                    first_owned_alloc_id,
                );
                if (result.len > 0) env.alloc.free(result);
            }
            for (elems, 0..) |e, i| {
                result[i] = try constValueToCtValue(env, e);
                initialized_count += 1;
            }
            const id = try env.store.alloc(env.alloc, .list, null);
            break :blk CtValue{ .list = .{ .alloc_id = id, .elems = result } };
        },
        .map => |entries| blk: {
            const first_owned_alloc_id = env.store.next_id;
            const result = try env.alloc.alloc(CtValue.CtMapEntry, entries.len);
            var initialized_count: usize = 0;
            var partial_key: ?CtValue = null;
            errdefer {
                if (partial_key) |key| {
                    deinitTemporaryCtValue(env.alloc, env.store, key, first_owned_alloc_id);
                }
                deinitInitializedTemporaryCtMapEntries(
                    env.alloc,
                    env.store,
                    result,
                    initialized_count,
                    first_owned_alloc_id,
                );
                if (result.len > 0) env.alloc.free(result);
            }
            for (entries, 0..) |entry, i| {
                const key = try constValueToCtValue(env, entry.key);
                partial_key = key;
                const value = try constValueToCtValue(env, entry.value);
                partial_key = null;
                result[i] = .{
                    .key = key,
                    .value = value,
                };
                initialized_count += 1;
            }
            const id = try env.store.alloc(env.alloc, .map, null);
            break :blk CtValue{ .map = .{ .alloc_id = id, .entries = result } };
        },
        .struct_val => |struct_value| blk: {
            const first_owned_alloc_id = env.store.next_id;
            const result = try env.alloc.alloc(CtValue.CtFieldValue, struct_value.fields.len);
            var initialized_count: usize = 0;
            errdefer {
                deinitTemporaryCtFieldValues(
                    env.alloc,
                    env.store,
                    result[0..initialized_count],
                    first_owned_alloc_id,
                );
                if (result.len > 0) env.alloc.free(result);
            }
            for (struct_value.fields, 0..) |field, i| {
                result[i] = .{
                    .name = field.name,
                    .value = try constValueToCtValue(env, field.value),
                };
                initialized_count += 1;
            }
            const id = try env.store.alloc(env.alloc, .struct_val, null);
            break :blk CtValue{ .struct_val = .{
                .alloc_id = id,
                .type_name = struct_value.type_name,
                .fields = result,
            } };
        },
    };
}

fn expectNoActiveTemporaryCtAllocations(store: *const AllocationStore, first_owned_alloc_id: ctfe.AllocId) !void {
    for (store.records.items) |record| {
        try std.testing.expect(record.id == 0 or record.id < first_owned_alloc_id);
    }
}

fn constValueImportCoverageValue() ctfe.ConstValue {
    const Fixtures = struct {
        const tuple_elems = [_]ctfe.ConstValue{
            .{ .int = 1 },
            .{ .string = "tuple" },
        };
        const list_elems = [_]ctfe.ConstValue{
            .{ .atom = "list" },
            .{ .bool_val = true },
        };
        const map_entries = [_]ctfe.ConstValue.ConstMapEntry{
            .{ .key = .{ .atom = "key" }, .value = .{ .list = &list_elems } },
        };
        const nested_struct_fields = [_]ctfe.ConstValue.ConstFieldValue{
            .{ .name = "enabled", .value = .{ .bool_val = true } },
        };
        const root_fields = [_]ctfe.ConstValue.ConstFieldValue{
            .{ .name = "tuple", .value = .{ .tuple = &tuple_elems } },
            .{ .name = "map", .value = .{ .map = &map_entries } },
            .{ .name = "struct", .value = .{ .struct_val = .{ .type_name = "Nested", .fields = &nested_struct_fields } } },
        };
    };
    return .{ .struct_val = .{ .type_name = "Root", .fields = &Fixtures.root_fields } };
}

fn exerciseConstValueImportAllocationFailures(allocator: Allocator) !void {
    var store = AllocationStore{};
    defer store.deinit(allocator);
    var env = Env.init(allocator, &store);
    defer env.deinit();

    const first_owned_alloc_id = store.next_id;
    const result = try constValueToCtValue(&env, constValueImportCoverageValue());
    defer deinitTemporaryCtValue(allocator, &store, result, first_owned_alloc_id);

    try std.testing.expect(result == .struct_val);
    try std.testing.expectEqual(@as(usize, 3), result.struct_val.fields.len);
}

test "P4J2: constValueToCtValue cleans tuple list map struct imports on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseConstValueImportAllocationFailures,
        .{},
    );
}

test "P4J2: constValueToCtValue unwinds initialized nested aggregate before later child failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    const allocator = failing_allocator.allocator();

    var store = AllocationStore{};
    defer store.deinit(allocator);
    var env = Env.init(allocator, &store);
    defer env.deinit();

    const first_child_elems = [_]ctfe.ConstValue{.{ .int = 1 }};
    const second_child_elems = [_]ctfe.ConstValue{.{ .int = 2 }};
    const outer_elems = [_]ctfe.ConstValue{
        .{ .list = &first_child_elems },
        .{ .list = &second_child_elems },
    };

    const first_owned_alloc_id = store.next_id;
    try std.testing.expectError(error.OutOfMemory, constValueToCtValue(&env, .{ .list = &outer_elems }));
    try std.testing.expect(failing_allocator.has_induced_failure);
    try expectNoActiveTemporaryCtAllocations(&store, first_owned_alloc_id);
}

test "P4J2: constValueToCtValue unwinds initialized nested aggregate on final store failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing_allocator.allocator();

    var store = AllocationStore{};
    defer store.deinit(allocator);
    const reserved_records = try allocator.alloc(ctfe.AllocationRecord, 1);
    store.records.items = reserved_records[0..0];
    store.records.capacity = reserved_records.len;

    var env = Env.init(allocator, &store);
    defer env.deinit();

    const child_elems = [_]ctfe.ConstValue{.{ .int = 1 }};
    const outer_elems = [_]ctfe.ConstValue{.{ .list = &child_elems }};

    const first_owned_alloc_id = store.next_id;
    failing_allocator.fail_index = failing_allocator.alloc_index + 2;
    try std.testing.expectError(error.OutOfMemory, constValueToCtValue(&env, .{ .list = &outer_elems }));
    try std.testing.expect(failing_allocator.has_induced_failure);
    try expectNoActiveTemporaryCtAllocations(&store, first_owned_alloc_id);
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
    entries[0] = .{ .key = .{ .atom = ":name" }, .value = .{ .string = "run" } };
    entries[1] = .{ .key = .{ .atom = ":arity" }, .value = .{ .int = 0 } };
    const map_value = CtValue{ .map = .{ .alloc_id = try store.alloc(alloc, .map, null), .entries = entries } };

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

fn exerciseCompiledFunctionNameAllocationFailures(allocator: Allocator) !void {
    const segments = [_][]const u8{ "Math", "Ops", "<>" };
    const compiled_name = try compiledFunctionName(allocator, segments[0..], 2);
    defer allocator.free(compiled_name);

    try std.testing.expectEqualStrings("Math_Ops___lt_gt__2", compiled_name);
}

test "P4J2: compiledFunctionName frees intermediate allocations on failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompiledFunctionNameAllocationFailures,
        .{},
    );
}

test "P4J2: evalCompiledQualifiedFunction frees compiled name on lookup miss" {
    const allocator = std.testing.allocator;
    const program = ir.Program{
        .functions = &.{},
        .type_defs = &.{},
        .entry = null,
    };
    var store = AllocationStore{};
    var env = Env.init(allocator, &store);
    defer env.deinit();
    env.compiled_program = &program;

    const segments = [_][]const u8{ "Math", "Ops", "<>" };
    const arg_forms: []const CtValue = &.{};

    const result = try evalCompiledQualifiedFunction(&env, segments[0..], arg_forms);
    try std.testing.expect(result == null);
}

fn exerciseQuoteUnquoteSubstitutionAllocationFailures(allocator: Allocator) !void {
    var store = AllocationStore{};
    defer store.deinit(allocator);
    var env = Env.init(allocator, &store);
    defer env.deinit();

    const unquote_arg_elems = [_]CtValue{.{ .int = 1 }};
    const unquote_args = CtValue{ .list = .{ .alloc_id = 0, .elems = &unquote_arg_elems } };
    const unquote_elems = [_]CtValue{ .{ .atom = "unquote" }, .nil, unquote_args };
    const unquote_node = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &unquote_elems } };
    const root_arg_elems = [_]CtValue{unquote_node};
    const root_args = CtValue{ .list = .{ .alloc_id = 0, .elems = &root_arg_elems } };
    const root_elems = [_]CtValue{ .{ .atom = "tuple" }, .nil, root_args };
    const root = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &root_elems } };

    const first_owned_alloc_id = store.next_id;
    const result = try substituteUnquotesEval(&env, root);
    defer deinitTemporaryCtValue(allocator, &store, result, first_owned_alloc_id);

    try std.testing.expect(result == .tuple);
    try std.testing.expectEqual(@as(usize, 3), result.tuple.elems.len);
    try std.testing.expect(result.tuple.elems[2] == .list);
    try std.testing.expectEqual(@as(i64, 1), result.tuple.elems[2].list.elems[0].int);
}

test "P4J2: quote unquote substitution cleans aggregate payloads on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseQuoteUnquoteSubstitutionAllocationFailures,
        .{},
    );
}

fn evalAndDeinitTemporaryResultForAllocationFailureTest(
    allocator: Allocator,
    store: *AllocationStore,
    env: *Env,
    call: CtValue,
) !CtValue {
    const first_owned_alloc_id = store.next_id;
    const result = try eval(env, call);
    errdefer deinitTemporaryCtValue(allocator, store, result, first_owned_alloc_id);
    return result;
}

fn exerciseAggregateIntrinsicAllocationFailures(allocator: Allocator) !void {
    var store = AllocationStore{};
    defer store.deinit(allocator);
    var env = Env.init(allocator, &store);
    defer env.deinit();

    {
        const source_elems = [_]CtValue{.{ .int = 2 }};
        const source_list = CtValue{ .list = .{ .alloc_id = 0, .elems = &source_elems } };
        const args_elems = [_]CtValue{ source_list, .{ .int = 1 } };
        const args = CtValue{ .list = .{ .alloc_id = 0, .elems = &args_elems } };
        const call_elems = [_]CtValue{ .{ .atom = "prepend" }, .nil, args };
        const call = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &call_elems } };
        const first_owned_alloc_id = store.next_id;
        const result = try evalAndDeinitTemporaryResultForAllocationFailureTest(allocator, &store, &env, call);
        defer deinitTemporaryCtValue(allocator, &store, result, first_owned_alloc_id);
        try std.testing.expect(result == .list);
        try std.testing.expectEqual(@as(usize, 2), result.list.elems.len);
    }

    {
        const left_elems = [_]CtValue{.{ .int = 1 }};
        const right_elems = [_]CtValue{.{ .int = 2 }};
        const left = CtValue{ .list = .{ .alloc_id = 0, .elems = &left_elems } };
        const right = CtValue{ .list = .{ .alloc_id = 0, .elems = &right_elems } };
        const args_elems = [_]CtValue{ left, right };
        const args = CtValue{ .list = .{ .alloc_id = 0, .elems = &args_elems } };
        const call_elems = [_]CtValue{ .{ .atom = "list_concat" }, .nil, args };
        const call = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &call_elems } };
        const first_owned_alloc_id = store.next_id;
        const result = try evalAndDeinitTemporaryResultForAllocationFailureTest(allocator, &store, &env, call);
        defer deinitTemporaryCtValue(allocator, &store, result, first_owned_alloc_id);
        try std.testing.expect(result == .list);
        try std.testing.expectEqual(@as(usize, 2), result.list.elems.len);
    }

    {
        const inner_elems = [_]CtValue{ .{ .int = 1 }, .{ .int = 2 } };
        const inner = CtValue{ .list = .{ .alloc_id = 0, .elems = &inner_elems } };
        const outer_elems = [_]CtValue{inner};
        const outer = CtValue{ .list = .{ .alloc_id = 0, .elems = &outer_elems } };
        const args_elems = [_]CtValue{outer};
        const args = CtValue{ .list = .{ .alloc_id = 0, .elems = &args_elems } };
        const call_elems = [_]CtValue{ .{ .atom = "list_flatten" }, .nil, args };
        const call = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &call_elems } };
        const first_owned_alloc_id = store.next_id;
        const result = try evalAndDeinitTemporaryResultForAllocationFailureTest(allocator, &store, &env, call);
        defer deinitTemporaryCtValue(allocator, &store, result, first_owned_alloc_id);
        try std.testing.expect(result == .list);
        try std.testing.expectEqual(@as(usize, 2), result.list.elems.len);
    }

    {
        const args_elems = [_]CtValue{ .{ .int = 1 }, .{ .int = 2 } };
        const args = CtValue{ .list = .{ .alloc_id = 0, .elems = &args_elems } };
        const call_elems = [_]CtValue{ .{ .atom = "tuple" }, .nil, args };
        const call = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &call_elems } };
        const first_owned_alloc_id = store.next_id;
        const result = try evalAndDeinitTemporaryResultForAllocationFailureTest(allocator, &store, &env, call);
        defer deinitTemporaryCtValue(allocator, &store, result, first_owned_alloc_id);
        try std.testing.expect(result == .tuple);
        try std.testing.expectEqual(@as(usize, 2), result.tuple.elems.len);
    }

    {
        const pair_elems = [_]CtValue{ .{ .atom = ":answer" }, .{ .int = 42 } };
        const pair = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &pair_elems } };
        const args_elems = [_]CtValue{pair};
        const args = CtValue{ .list = .{ .alloc_id = 0, .elems = &args_elems } };
        const call_elems = [_]CtValue{ .{ .atom = "%{}" }, .nil, args };
        const call = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &call_elems } };
        const first_owned_alloc_id = store.next_id;
        const result = try evalAndDeinitTemporaryResultForAllocationFailureTest(allocator, &store, &env, call);
        defer deinitTemporaryCtValue(allocator, &store, result, first_owned_alloc_id);
        try std.testing.expect(result == .map);
        try std.testing.expectEqual(@as(usize, 1), result.map.entries.len);
    }

    {
        const iterable_elems = [_]CtValue{.{ .int = 1 }};
        const iterable = CtValue{ .list = .{ .alloc_id = 0, .elems = &iterable_elems } };
        const args_elems = [_]CtValue{ .{ .atom = "_" }, iterable, .nil, .{ .int = 7 } };
        const args = CtValue{ .list = .{ .alloc_id = 0, .elems = &args_elems } };
        const call_elems = [_]CtValue{ .{ .atom = "for" }, .nil, args };
        const call = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &call_elems } };
        const first_owned_alloc_id = store.next_id;
        const result = try evalAndDeinitTemporaryResultForAllocationFailureTest(allocator, &store, &env, call);
        defer deinitTemporaryCtValue(allocator, &store, result, first_owned_alloc_id);
        try std.testing.expect(result == .list);
        try std.testing.expectEqual(@as(usize, 1), result.list.elems.len);
    }
}

test "P4J2: aggregate intrinsics clean temporary buffers on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAggregateIntrinsicAllocationFailures,
        .{},
    );
}

fn exerciseCompiledQualifiedFunctionArgAllocationFailures(allocator: Allocator) !void {
    const params = [_]ir.Param{
        .{ .name = "left", .type_expr = .i64 },
        .{ .name = "right", .type_expr = .i64 },
    };
    const instructions = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 7 } },
        .{ .ret = .{ .value = 0 } },
    };
    const blocks = [_]ir.Block{.{
        .label = 0,
        .instructions = &instructions,
    }};
    const function = ir.Function{
        .id = 0,
        .name = "Math__constant__2",
        .scope_id = 0,
        .arity = 2,
        .params = &params,
        .return_type = .i64,
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{function};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var store = AllocationStore{};
    defer store.deinit(allocator);
    var env = Env.init(allocator, &store);
    defer env.deinit();
    env.compiled_program = &program;

    const left_list_elems = [_]CtValue{.{ .int = 1 }};
    const right_list_elems = [_]CtValue{.{ .int = 2 }};
    const left_list = CtValue{ .list = .{ .alloc_id = 0, .elems = &left_list_elems } };
    const right_list = CtValue{ .list = .{ .alloc_id = 0, .elems = &right_list_elems } };
    const concat_args_elems = [_]CtValue{ left_list, right_list };
    const concat_args = CtValue{ .list = .{ .alloc_id = 0, .elems = &concat_args_elems } };
    const concat_call_elems = [_]CtValue{ .{ .atom = "list_concat" }, .nil, concat_args };
    const concat_call = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &concat_call_elems } };
    const tuple_args_elems = [_]CtValue{ .{ .int = 3 }, .{ .int = 4 } };
    const tuple_args = CtValue{ .list = .{ .alloc_id = 0, .elems = &tuple_args_elems } };
    const tuple_call_elems = [_]CtValue{ .{ .atom = "tuple" }, .nil, tuple_args };
    const tuple_call = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &tuple_call_elems } };
    const arg_forms = [_]CtValue{ concat_call, tuple_call };
    const segments = [_][]const u8{ "Math", "constant" };

    const result = (try evalCompiledQualifiedFunction(&env, segments[0..], arg_forms[0..])) orelse return error.TestUnexpectedResult;
    try std.testing.expect(result == .int);
    try std.testing.expectEqual(@as(i64, 7), result.int);
}

test "P4J2: evalCompiledQualifiedFunction cleans evaluated args on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompiledQualifiedFunctionArgAllocationFailures,
        .{},
    );
}

fn makeOwnedSignaturesForReflectionTest(allocator: Allocator) ![]const []const u8 {
    const signatures = try allocator.alloc([]const u8, 2);
    var initialized_count: usize = 0;
    errdefer {
        for (signatures[0..initialized_count]) |signature_text| {
            allocator.free(signature_text);
        }
        allocator.free(signatures);
    }

    signatures[0] = try allocator.dupe(u8, "run(i64) -> i64");
    initialized_count += 1;
    signatures[1] = try allocator.dupe(u8, "run(string) -> string");
    initialized_count += 1;
    return signatures;
}

fn exerciseMakeFunctionRefAllocationFailures(allocator: Allocator) !void {
    var store = AllocationStore{};
    defer store.deinit(allocator);
    var env = Env.init(allocator, &store);
    defer env.deinit();

    const owned_doc_text = try allocator.dupe(u8, "Function docs.");
    var doc_text_transferred = false;
    errdefer if (!doc_text_transferred) allocator.free(owned_doc_text);

    const owned_signatures = try makeOwnedSignaturesForReflectionTest(allocator);
    var signatures_transferred = false;
    errdefer if (!signatures_transferred) deinitOwnedReflectionSignatureSlice(allocator, owned_signatures);

    doc_text_transferred = true;
    signatures_transferred = true;
    const function_ref = try makeFunctionRef(
        &env,
        "run",
        1,
        .public,
        owned_doc_text,
        "src/reflection.zap",
        12,
        owned_signatures,
    );
    defer deinitReflectionResultValue(allocator, function_ref);
}

test "P4J2: macro_eval makeFunctionRef frees partial payloads on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMakeFunctionRefAllocationFailures,
        .{},
    );
}

test "P4J2: macro_eval reflection append guard frees function ref on allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing_allocator.allocator();

    var store = AllocationStore{};
    defer store.deinit(allocator);
    var env = Env.init(allocator, &store);
    defer env.deinit();

    const owned_doc_text = try allocator.dupe(u8, "Function docs.");
    const owned_signatures = try makeOwnedSignaturesForReflectionTest(allocator);
    const function_ref = try makeFunctionRef(
        &env,
        "run",
        1,
        .public,
        owned_doc_text,
        "src/reflection.zap",
        12,
        owned_signatures,
    );

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    defer result_list.deinit(allocator);
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try std.testing.expectError(error.OutOfMemory, appendOwnedReflectionResultValue(allocator, &result_list, function_ref));
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), result_list.items.len);
}

test "P4J2: macro_eval reflection append guard frees alias ref on allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing_allocator.allocator();

    var store = AllocationStore{};
    defer store.deinit(allocator);
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();
    var env = Env.init(allocator, &store);
    defer env.deinit();

    const outer = try interner.intern("Outer");
    const inner = try interner.intern("Inner");
    const parts = [_]ast.StringId{ outer, inner };
    const name = ast.StructName{
        .parts = &parts,
        .span = .{ .start = 0, .end = 0 },
    };
    const alias_ref = try makeAliasRef(&env, &interner, name);

    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    defer result_list.deinit(allocator);
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try std.testing.expectError(error.OutOfMemory, appendOwnedReflectionResultValue(allocator, &result_list, alias_ref));
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), result_list.items.len);
}

fn expectEvalOutOfMemoryWithZeroAllocator(store: *AllocationStore, call: CtValue) !void {
    var backing_buffer: [0]u8 = .{};
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&backing_buffer);
    var env = Env.init(fixed_buffer.allocator(), store);
    defer env.deinit();

    try std.testing.expectError(error.OutOfMemory, eval(&env, call));
    try std.testing.expect(env.last_capability_error == null);
}

test "macro intrinsics propagate allocation failures instead of nil" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = AllocationStore{};

    const type_tuple_call = try makeUnqualifiedCallCtValueWithArgs(
        alloc,
        &store,
        "type_tuple",
        &.{ .{ .atom = "i64" }, .{ .int = 0 } },
    );
    try expectEvalOutOfMemoryWithZeroAllocator(&store, type_tuple_call);

    const type_annotate_call = try makeUnqualifiedCallCtValueWithArgs(
        alloc,
        &store,
        "type_annotate",
        &.{ .{ .atom = "value" }, .{ .atom = "i64" } },
    );
    try expectEvalOutOfMemoryWithZeroAllocator(&store, type_annotate_call);

    const make_call_args = try ast_data.emptyList(alloc, &store);
    const make_call = try makeUnqualifiedCallCtValueWithArgs(
        alloc,
        &store,
        "make_call",
        &.{ .{ .string = "=" }, make_call_args },
    );
    try expectEvalOutOfMemoryWithZeroAllocator(&store, make_call);

    const string_concat_call = try makeUnqualifiedCallCtValueWithArgs(
        alloc,
        &store,
        "<>",
        &.{ .{ .string = "a" }, .{ .string = "b" } },
    );
    try expectEvalOutOfMemoryWithZeroAllocator(&store, string_concat_call);

    const slugify_call = try makeUnqualifiedCallCtValueWithArgs(
        alloc,
        &store,
        "slugify",
        &.{.{ .string = "A B" }},
    );
    try expectEvalOutOfMemoryWithZeroAllocator(&store, slugify_call);

    const intern_atom_call = try makeUnqualifiedCallCtValueWithArgs(
        alloc,
        &store,
        "intern_atom",
        &.{.{ .string = "name" }},
    );
    try expectEvalOutOfMemoryWithZeroAllocator(&store, intern_atom_call);
}

fn exerciseTypeTupleConstructionOwnership(allocator: Allocator) !void {
    var store = AllocationStore{};
    defer store.deinit(allocator);
    var env = Env.init(allocator, &store);
    defer env.deinit();

    const tuple_lane_arg_elems = [_]CtValue{.{ .atom = "i64" }};
    const tuple_lane_args = CtValue{ .list = .{ .alloc_id = 0, .elems = &tuple_lane_arg_elems } };
    const tuple_lane_elems = [_]CtValue{ .{ .atom = "tuple" }, .nil, tuple_lane_args };
    const tuple_lane = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &tuple_lane_elems } };
    const call_arg_elems = [_]CtValue{ tuple_lane, .{ .int = 0 } };
    const call_args = CtValue{ .list = .{ .alloc_id = 0, .elems = &call_arg_elems } };
    const call_elems = [_]CtValue{ .{ .atom = "type_tuple" }, .nil, call_args };
    const call = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &call_elems } };

    const first_owned_alloc_id = store.next_id;
    const result = try eval(&env, call);
    defer deinitTemporaryCtValue(allocator, &store, result, first_owned_alloc_id);

    try std.testing.expect(result == .tuple);
    try std.testing.expectEqual(@as(usize, 3), result.tuple.elems.len);
    try std.testing.expect(result.tuple.elems[0] == .atom);
    try std.testing.expectEqualStrings("tuple", result.tuple.elems[0].atom);
    try std.testing.expect(result.tuple.elems[2] == .list);
    try std.testing.expectEqual(@as(usize, 0), result.tuple.elems[2].list.elems.len);
}

test "P4J2: type_tuple construction cleans temporary children on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTypeTupleConstructionOwnership,
        .{},
    );
}

fn exerciseTypeAnnotateConstructionOwnership(allocator: Allocator) !void {
    var store = AllocationStore{};
    defer store.deinit(allocator);
    var env = Env.init(allocator, &store);
    defer env.deinit();

    const call_arg_elems = [_]CtValue{ .{ .atom = "value" }, .{ .atom = "i64" } };
    const call_args = CtValue{ .list = .{ .alloc_id = 0, .elems = &call_arg_elems } };
    const call_elems = [_]CtValue{ .{ .atom = "type_annotate" }, .nil, call_args };
    const call = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &call_elems } };

    const first_owned_alloc_id = store.next_id;
    const result = try eval(&env, call);
    defer deinitTemporaryCtValue(allocator, &store, result, first_owned_alloc_id);

    try std.testing.expect(result == .tuple);
    try std.testing.expectEqual(@as(usize, 3), result.tuple.elems.len);
    try std.testing.expect(result.tuple.elems[0] == .atom);
    try std.testing.expectEqualStrings("::", result.tuple.elems[0].atom);
    try std.testing.expect(result.tuple.elems[2] == .list);
    try std.testing.expectEqual(@as(usize, 2), result.tuple.elems[2].list.elems.len);
}

test "P4J2: type_annotate construction cleans temporary children on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTypeAnnotateConstructionOwnership,
        .{},
    );
}

fn exerciseMakeCallConstructionOwnership(allocator: Allocator) !void {
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(allocator);
    defer graph.deinit();
    var store = AllocationStore{};
    defer store.deinit(allocator);
    var env = Env.init(allocator, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
    };

    const empty_list = CtValue{ .list = .{ .alloc_id = 0, .elems = &.{} } };
    const concat_arg_elems = [_]CtValue{ empty_list, empty_list };
    const concat_args = CtValue{ .list = .{ .alloc_id = 0, .elems = &concat_arg_elems } };
    const concat_elems = [_]CtValue{ .{ .atom = "list_concat" }, .nil, concat_args };
    const owned_args_expr = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &concat_elems } };
    const call_arg_elems = [_]CtValue{ .{ .string = "=" }, owned_args_expr };
    const call_args = CtValue{ .list = .{ .alloc_id = 0, .elems = &call_arg_elems } };
    const call_elems = [_]CtValue{ .{ .atom = "make_call" }, .nil, call_args };
    const call = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &call_elems } };

    const first_owned_alloc_id = store.next_id;
    const result = try eval(&env, call);
    defer deinitTemporaryCtValue(allocator, &store, result, first_owned_alloc_id);

    try std.testing.expect(result == .tuple);
    try std.testing.expectEqual(@as(usize, 3), result.tuple.elems.len);
    try std.testing.expect(result.tuple.elems[0] == .atom);
    try std.testing.expectEqualStrings("=", result.tuple.elems[0].atom);
    try std.testing.expect(result.tuple.elems[1] == .list);
    try std.testing.expect(result.tuple.elems[2] == .list);
}

test "P4J2: make_call construction interns atom and cleans temporary children on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMakeCallConstructionOwnership,
        .{},
    );
}

test "type_name reports malformed CtValue decode as a hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
    };

    const call = try makeUnqualifiedCallCtValueWithArgs(alloc, &store, "type_name", &.{.void});

    try std.testing.expectError(error.EvalFailed, eval(&env, call));
    try expectHardDiagnosticContains(&env, "type_name");
    try expectHardDiagnosticContains(&env, "InvalidCtValueShape");
}

test "struct_put_attribute reports non-exportable values as hard diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    const struct_scope = try installStructAttributeFixture(alloc, &interner, &graph, "AttributeFixture");

    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
        .attribute_struct_scope = struct_scope,
    };

    try std.testing.expectError(error.EvalFailed, structIntrinsicPut(&env, &.{ .{ .atom = ":bad" }, .consumed }));
    try expectHardDiagnosticContains(&env, "struct_put_attribute");
    try expectHardDiagnosticContains(&env, "CannotExport");
}

test "struct_put_attribute propagates attribute store OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    const struct_scope = try installStructAttributeFixture(alloc, &interner, &graph, "AttributeFixture");

    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
        .attribute_struct_scope = struct_scope,
    };

    var backing_buffer: [0]u8 = .{};
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&backing_buffer);
    const original_graph_allocator = graph.allocator;
    graph.allocator = fixed_buffer.allocator();
    defer graph.allocator = original_graph_allocator;

    try std.testing.expectError(error.OutOfMemory, structIntrinsicPut(&env, &.{ .{ .atom = ":stored" }, .{ .int = 1 } }));
    try std.testing.expect(env.last_capability_error == null);
}

test "source_graph_structs reports malformed path filter as hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
    };

    try std.testing.expectError(error.EvalFailed, sourceGraphStructsIntrinsic(&env, &.{.{ .int = 1 }}));
    try expectHardDiagnosticContains(&env, "source_graph_structs");
    try expectHardDiagnosticContains(&env, "InvalidPathFilter");
}

test "P4J2: macro_eval extractStructRefName returns owned alias names" {
    const alloc = std.testing.allocator;

    const parts = [_]CtValue{
        .{ .atom = ":Outer" },
        .{ .atom = ":Inner" },
    };
    const tuple_elems = [_]CtValue{
        .{ .atom = "__aliases__" },
        .nil,
        .{ .list = .{ .alloc_id = 0, .elems = &parts } },
    };
    const alias_ref = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &tuple_elems } };

    const extracted_optional = try extractStructRefName(alloc, alias_ref);
    try std.testing.expect(extracted_optional != null);
    const extracted = extracted_optional.?;
    defer extracted.deinit(alloc);

    try std.testing.expect(extracted == .owned);
    try std.testing.expectEqualStrings("Outer.Inner", extracted.bytes());
}

test "P4J2: macro_eval extractStructRefName frees partial alias buffer on malformed tuple" {
    const alloc = std.testing.allocator;

    const parts = [_]CtValue{
        .{ .atom = ":Outer" },
        .{ .string = "not-an-alias-segment" },
    };
    const tuple_elems = [_]CtValue{
        .{ .atom = "__aliases__" },
        .nil,
        .{ .list = .{ .alloc_id = 0, .elems = &parts } },
    };
    const malformed_alias_ref = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &tuple_elems } };

    const extracted = try extractStructRefName(alloc, malformed_alias_ref);
    try std.testing.expect(extracted == null);
}

test "P4J2: macro_eval type_name consumes owned alias name" {
    const alloc = std.testing.allocator;

    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    defer store.deinit(alloc);

    const parts = [_]CtValue{
        .{ .atom = ":Outer" },
        .{ .atom = ":Inner" },
    };
    const tuple_elems = [_]CtValue{
        .{ .atom = "__aliases__" },
        .nil,
        .{ .list = .{ .alloc_id = 0, .elems = &parts } },
    };
    const alias_ref = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &tuple_elems } };
    const args = try ast_data.makeList(alloc, &store, &.{alias_ref});
    defer if (args.list.elems.len > 0) alloc.free(args.list.elems);
    const empty = try ast_data.emptyList(alloc, &store);
    defer if (empty.list.elems.len > 0) alloc.free(empty.list.elems);
    const call = try ast_data.makeTuple3(alloc, &store, .{ .atom = "type_name" }, empty, args);
    defer alloc.free(call.tuple.elems);

    const result = try eval(&env, call);
    try std.testing.expect(result == .string);
    defer alloc.free(result.string);
    try std.testing.expectEqualStrings("Outer.Inner", result.string);
}

test "struct_get_attribute reimports stored map ConstValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    const struct_scope = try installStructAttributeFixture(alloc, &interner, &graph, "AttributeFixture");

    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
        .attribute_struct_scope = struct_scope,
    };

    const attr_name = try interner.intern("metadata");
    const entries = [_]CtValue.CtMapEntry{
        .{ .key = .{ .atom = "name" }, .value = .{ .string = "zap" } },
        .{ .key = .{ .atom = "version" }, .value = .{ .int = 1 } },
    };
    try putOwnedStructAttributeForTest(
        &graph,
        struct_scope,
        attr_name,
        try ctfe.exportValue(alloc, .{ .map = .{ .alloc_id = 0, .entries = &entries } }),
    );

    const result = try structIntrinsicGet(&env, &.{.{ .atom = ":metadata" }});
    try std.testing.expect(result == .map);
    try std.testing.expectEqual(@as(usize, 2), result.map.entries.len);
    try std.testing.expectEqualStrings("name", result.map.entries[0].key.atom);
    try std.testing.expectEqualStrings("zap", result.map.entries[0].value.string);
    try std.testing.expectEqualStrings("version", result.map.entries[1].key.atom);
    try std.testing.expectEqual(@as(i64, 1), result.map.entries[1].value.int);
}

test "struct_get_attribute reimports stored struct ConstValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    const struct_scope = try installStructAttributeFixture(alloc, &interner, &graph, "AttributeFixture");

    var store = AllocationStore{};
    var env = Env.init(alloc, &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
        .attribute_struct_scope = struct_scope,
    };

    const attr_name = try interner.intern("config");
    const fields = [_]CtValue.CtFieldValue{
        .{ .name = "host", .value = .{ .string = "localhost" } },
        .{ .name = "port", .value = .{ .int = 4000 } },
    };
    try putOwnedStructAttributeForTest(
        &graph,
        struct_scope,
        attr_name,
        try ctfe.exportValue(alloc, .{ .struct_val = .{
            .alloc_id = 0,
            .type_name = "ServerConfig",
            .fields = &fields,
        } }),
    );

    const result = try structIntrinsicGet(&env, &.{.{ .atom = ":config" }});
    try std.testing.expect(result == .struct_val);
    try std.testing.expectEqualStrings("ServerConfig", result.struct_val.type_name);
    try std.testing.expectEqual(@as(usize, 2), result.struct_val.fields.len);
    try std.testing.expectEqualStrings("host", result.struct_val.fields[0].name);
    try std.testing.expectEqualStrings("localhost", result.struct_val.fields[0].value.string);
    try std.testing.expectEqualStrings("port", result.struct_val.fields[1].name);
    try std.testing.expectEqual(@as(i64, 4000), result.struct_val.fields[1].value.int);
}

test "struct_get_attribute propagates stored aggregate reimport OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const setup_alloc = arena.allocator();

    var interner = ast.StringInterner.init(setup_alloc);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(setup_alloc);
    defer graph.deinit();
    const struct_scope = try installStructAttributeFixture(setup_alloc, &interner, &graph, "AttributeFixture");

    const attr_name = try interner.intern("items");
    const elems = [_]CtValue{.{ .int = 1 }};
    try putOwnedStructAttributeForTest(
        &graph,
        struct_scope,
        attr_name,
        try ctfe.exportValue(setup_alloc, .{ .list = .{ .alloc_id = 0, .elems = &elems } }),
    );

    var backing_buffer: [0]u8 = .{};
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&backing_buffer);
    var store = AllocationStore{};
    var env = Env.init(fixed_buffer.allocator(), &store);
    defer env.deinit();
    env.struct_ctx = .{
        .graph = &graph,
        .interner = &interner,
        .current_struct_scope = struct_scope,
        .attribute_struct_scope = struct_scope,
    };

    try std.testing.expectError(error.OutOfMemory, structIntrinsicGet(&env, &.{.{ .atom = ":items" }}));
    try std.testing.expect(env.last_capability_error == null);
}

test "docs-reflection: canonical doc attribute is reflected" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    const doc_text = ast.Expr{ .string_literal = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .value = try interner.intern("Function docs."),
    } };

    var attributes: std.ArrayListUnmanaged(scope.Attribute) = .empty;
    defer attributes.deinit(std.testing.allocator);
    try attributes.append(std.testing.allocator, .{
        .name = try interner.intern("doc"),
        .value = &doc_text,
    });

    const text = (try extractDocAttributeText(std.testing.allocator, &interner, attributes)) orelse "";
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Function docs.", text);
}

test "docs-reflection: struct doc is read from declaration attributes" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    const doc_expr = ast.Expr{ .string_literal = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .value = try interner.intern("Struct docs."),
    } };
    var attributes: std.ArrayListUnmanaged(scope.Attribute) = .empty;
    defer attributes.deinit(std.testing.allocator);
    try attributes.append(std.testing.allocator, .{
        .name = try interner.intern("doc"),
        .value = &doc_expr,
    });

    const text = (try extractDocAttributeText(std.testing.allocator, &interner, attributes)) orelse "";
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Struct docs.", text);
}

test "docs-reflection: generic type arguments are retained in signatures" {
    const allocator = std.testing.allocator;
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();
    var graph = try scope.ScopeGraph.init(allocator);
    defer graph.deinit();

    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };
    const type_parameter = ast.TypeExpr{ .variable = .{
        .meta = meta,
        .name = try interner.intern("t"),
    } };
    const list_type_args = [_]*const ast.TypeExpr{&type_parameter};
    const list_type = ast.TypeExpr{ .name = .{
        .meta = meta,
        .name = try interner.intern("List"),
        .args = &list_type_args,
    } };
    const pattern = ast.Pattern{ .bind = .{
        .meta = meta,
        .name = try interner.intern("list"),
    } };
    const params = [_]ast.Param{.{
        .meta = meta,
        .pattern = &pattern,
        .type_annotation = &list_type,
    }};
    const clause = ast.FunctionClause{
        .meta = meta,
        .params = &params,
        .return_type = &list_type,
        .refinement = null,
    };

    const rendered = try buildReflectionClauseSignature(allocator, "identity", clause, &interner, &graph);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("identity(list :: List(t)) -> List(t)", rendered);
}

test "source path filters treat leading dot slash as equivalent" {
    const alloc = std.testing.allocator;
    const exact_paths = [_][]const u8{"test/zap/zest_runner_test.zap"};
    try std.testing.expect(try pathFilterContains(alloc, &exact_paths, "test/zap/zest_runner_test.zap"));
    try std.testing.expect(try pathFilterContains(alloc, &exact_paths, "./test/zap/zest_runner_test.zap"));

    const dot_slash_paths = [_][]const u8{"./test/zap/zest_runner_test.zap"};
    try std.testing.expect(try pathFilterContains(alloc, &dot_slash_paths, "test/zap/zest_runner_test.zap"));
    try std.testing.expect(!try pathFilterContains(alloc, &exact_paths, "test/other_test.zap"));
}

test "source path filters treat project-relative and absolute paths as equivalent" {
    const alloc = std.testing.allocator;
    const absolute_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, "src/macro_eval.zig", alloc);
    defer alloc.free(absolute_path);

    const relative_paths = [_][]const u8{"src/macro_eval.zig"};
    try std.testing.expect(try pathFilterContains(alloc, &relative_paths, absolute_path));
}
