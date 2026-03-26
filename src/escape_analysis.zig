const std = @import("std");
const ir = @import("ir.zig");
const scope = @import("scope.zig");
const types = @import("types.zig");

pub const ClosureEscape = enum {
    no_escape,
    call_local,
    block_local,
    stored_local,
    passed_known_safe,
    passed_unknown,
    returned,
    stored_heap,
    merged_escape,
    unknown_escape,
};

pub const ValueLifetime = enum {
    dead,
    local_only,
    block_live,
    function_live,
    escaping,
    merged,
    unknown,
};

pub const CaptureTransfer = enum {
    borrow_local,
    move_into_env,
    share_into_env,
    forward_direct,
    illegal,
};

pub const AllocationStrategy = enum {
    none_direct_call,
    stack_env,
    local_env,
    heap_env,
};

pub const CallableStrategy = enum {
    direct_named,
    direct_wrapper,
    dyn_closure,
};

pub const ClosureSiteId = u32;
pub const CallSiteId = u32;

pub const CaptureSummary = struct {
    binding_id: ?scope.BindingId = null,
    ownership: types.Ownership,
    lifetime: ValueLifetime,
    transfer: CaptureTransfer,
};

pub const ClosureSummary = struct {
    escape: ClosureEscape,
    allocation: AllocationStrategy,
    callable_strategy: CallableStrategy,
    has_borrowed_capture: bool,
    captures: []const CaptureSummary,
};

fn joinAllocationStrategy(a: AllocationStrategy, b: AllocationStrategy) AllocationStrategy {
    if (a == b) return a;
    if (a == .heap_env or b == .heap_env) return .heap_env;
    if (a == .local_env or b == .local_env) return .local_env;
    if (a == .stack_env or b == .stack_env) return .stack_env;
    return .none_direct_call;
}

fn joinCallableStrategy(a: CallableStrategy, b: CallableStrategy) CallableStrategy {
    if (a == b) return a;
    if (a == .dyn_closure or b == .dyn_closure) return .dyn_closure;
    if (a == .direct_wrapper or b == .direct_wrapper) return .direct_wrapper;
    return .direct_named;
}

pub const ValueSummary = struct {
    lifetime: ValueLifetime,
};

pub const CallSummary = struct {
    closure_escape: ClosureEscape = .unknown_escape,
};

pub const FunctionParamSummary = struct {
    closure_params_safe: []const bool,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    closure_sites: std.AutoHashMap(ClosureSiteId, ClosureSummary),
    local_lifetimes: std.AutoHashMap(ir.LocalId, ValueSummary),
    call_sites: std.AutoHashMap(CallSiteId, CallSummary),
    closure_functions: std.AutoHashMap(ir.FunctionId, ClosureSummary),
    closure_function_names: std.StringHashMap(ClosureSummary),
    function_param_summaries: std.AutoHashMap(ir.FunctionId, FunctionParamSummary),
    function_name_to_id: std.StringHashMap(ir.FunctionId),

    pub fn init(allocator: std.mem.Allocator) Result {
        return .{
            .allocator = allocator,
            .closure_sites = std.AutoHashMap(ClosureSiteId, ClosureSummary).init(allocator),
            .local_lifetimes = std.AutoHashMap(ir.LocalId, ValueSummary).init(allocator),
            .call_sites = std.AutoHashMap(CallSiteId, CallSummary).init(allocator),
            .closure_functions = std.AutoHashMap(ir.FunctionId, ClosureSummary).init(allocator),
            .closure_function_names = std.StringHashMap(ClosureSummary).init(allocator),
            .function_param_summaries = std.AutoHashMap(ir.FunctionId, FunctionParamSummary).init(allocator),
            .function_name_to_id = std.StringHashMap(ir.FunctionId).init(allocator),
        };
    }

    pub fn deinit(self: *Result) void {
        var it = self.closure_sites.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.captures);
        }
        self.closure_sites.deinit();
        self.local_lifetimes.deinit();
        self.call_sites.deinit();
        self.closure_functions.deinit();
        self.closure_function_names.deinit();
        self.function_name_to_id.deinit();
        var fit = self.function_param_summaries.iterator();
        while (fit.next()) |entry| {
            self.allocator.free(entry.value_ptr.closure_params_safe);
        }
        self.function_param_summaries.deinit();
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn analyzeProgram(self: *Analyzer, program: *const ir.Program) !Result {
        var result = Result.init(self.allocator);

        for (program.functions) |func| {
            try result.function_name_to_id.put(func.name, func.id);
            try result.function_param_summaries.put(func.id, try self.summarizeFunctionParams(func, &result, program));
        }

        var changed = true;
        while (changed) {
            changed = false;
            for (program.functions) |func| {
                const new_summary = try self.summarizeFunctionParams(func, &result, program);
                const existing = result.function_param_summaries.getPtr(func.id).?;
                if (!std.mem.eql(bool, existing.closure_params_safe, new_summary.closure_params_safe)) {
                    self.allocator.free(existing.closure_params_safe);
                    try result.function_param_summaries.put(func.id, new_summary);
                    changed = true;
                } else {
                    self.allocator.free(new_summary.closure_params_safe);
                }
            }
        }

        var next_closure_site: ClosureSiteId = 0;
        var next_call_site: CallSiteId = 0;

        for (program.functions) |func| {
            for (func.body) |block| {
                for (block.instructions) |instr| {
                    switch (instr) {
                        .make_closure => |mc| {
                            const summary = try self.summarizeClosure(mc, func, instr, &result, program);
                            try result.closure_sites.put(next_closure_site, summary);
                            try self.mergeClosureFunctionSummary(&result, mc.function, func.name, summary);
                            try result.local_lifetimes.put(mc.dest, .{ .lifetime = switch (summary.escape) {
                                .no_escape, .call_local => .local_only,
                                .block_local, .stored_local, .passed_known_safe => .block_live,
                                .passed_unknown, .returned, .stored_heap => .escaping,
                                .merged_escape => .merged,
                                .unknown_escape => .unknown,
                            } });
                            next_closure_site += 1;
                        },
                        .local_get => |lg| {
                            if (result.local_lifetimes.get(lg.source)) |summary| {
                                try result.local_lifetimes.put(lg.dest, summary);
                            }
                        },
                        .local_set => |ls| {
                            if (result.local_lifetimes.get(ls.value)) |summary| {
                                try result.local_lifetimes.put(ls.dest, summary);
                            }
                        },
                        .move_value => |mv| {
                            if (result.local_lifetimes.get(mv.source)) |summary| {
                                try result.local_lifetimes.put(mv.dest, summary);
                            }
                        },
                        .share_value => |sv| {
                            if (result.local_lifetimes.get(sv.source)) |summary| {
                                try result.local_lifetimes.put(sv.dest, .{ .lifetime = joinLifetime(summary.lifetime, .block_live) });
                            }
                        },
                        .call_closure => {
                            try result.call_sites.put(next_call_site, .{ .closure_escape = .passed_unknown });
                            next_call_site += 1;
                        },
                        .phi => |phi| {
                            var joined: ValueLifetime = .dead;
                            var saw_source = false;
                            for (phi.sources) |source| {
                                if (result.local_lifetimes.get(source.value)) |summary| {
                                    joined = if (saw_source) joinLifetime(joined, summary.lifetime) else summary.lifetime;
                                    saw_source = true;
                                }
                            }
                            try result.local_lifetimes.put(phi.dest, .{ .lifetime = if (saw_source) joinLifetime(joined, .merged) else .merged });
                        },
                        else => {},
                    }
                }
            }
        }

        return result;
    }

    fn mergeClosureFunctionSummary(_: *Analyzer, result: *Result, function_id: ir.FunctionId, function_name: []const u8, summary: ClosureSummary) !void {
        if (result.closure_functions.get(function_id)) |existing| {
            const merged = ClosureSummary{
                .escape = joinClosureEscape(existing.escape, summary.escape),
                .allocation = joinAllocationStrategy(existing.allocation, summary.allocation),
                .callable_strategy = joinCallableStrategy(existing.callable_strategy, summary.callable_strategy),
                .has_borrowed_capture = existing.has_borrowed_capture or summary.has_borrowed_capture,
                .captures = existing.captures,
            };
            try result.closure_functions.put(function_id, merged);
            try result.closure_function_names.put(function_name, merged);
            return;
        }
        try result.closure_functions.put(function_id, summary);
        try result.closure_function_names.put(function_name, summary);
    }

    fn summarizeClosure(self: *Analyzer, mc: ir.MakeClosure, func: ir.Function, closure_instr: ir.Instruction, result: *const Result, program: *const ir.Program) !ClosureSummary {
        const capture_summaries = try self.allocator.alloc(CaptureSummary, mc.captures.len);
        for (capture_summaries, mc.captures, 0..) |*summary, local_id, idx| {
            const ownership = if (idx < func.captures.len) func.captures[idx].ownership else .shared;
            summary.* = .{
                .binding_id = null,
                .ownership = ownership,
                .lifetime = switch (ownership) {
                    .borrowed => .block_live,
                    .unique => .function_live,
                    .shared => .escaping,
                },
                .transfer = switch (ownership) {
                    .borrowed => .borrow_local,
                    .unique => .move_into_env,
                    .shared => .share_into_env,
                },
            };
            _ = local_id;
        }

        const has_borrowed = blk: {
            for (capture_summaries) |summary| {
                if (summary.ownership == .borrowed) break :blk true;
            }
            break :blk false;
        };

        const escape = self.classifyClosureUse(mc.dest, func, closure_instr, result, program);
        return .{
            .escape = escape,
            .allocation = switch (escape) {
                .no_escape, .call_local => .none_direct_call,
                .block_local, .stored_local, .passed_known_safe => if (has_borrowed) .stack_env else .local_env,
                else => .heap_env,
            },
            .callable_strategy = switch (escape) {
                .no_escape, .call_local => .direct_wrapper,
                .passed_known_safe => .direct_wrapper,
                else => if (mc.captures.len == 0) .direct_named else .dyn_closure,
            },
            .has_borrowed_capture = has_borrowed,
            .captures = capture_summaries,
        };
    }

    fn classifyClosureUse(self: *Analyzer, closure_local: ir.LocalId, func: ir.Function, closure_instr: ir.Instruction, result: *const Result, program: *const ir.Program) ClosureEscape {
        var aliases = std.AutoHashMap(ir.LocalId, void).init(self.allocator);
        defer aliases.deinit();
        aliases.put(closure_local, {}) catch return .unknown_escape;

        var start_block_index: usize = 0;
        var start_instr_index: usize = 0;
        outer: for (func.body, 0..) |block, block_idx| {
            for (block.instructions, 0..) |instr, instr_idx| {
                if (std.meta.eql(instr, closure_instr)) {
                    start_block_index = block_idx;
                    start_instr_index = instr_idx + 1;
                    break :outer;
                }
            }
        }

        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();
        return self.classifyFromBlock(func, start_block_index, start_instr_index, &aliases, &visited, result, program);
    }

    fn classifyFromBlock(
        self: *Analyzer,
        func: ir.Function,
        block_index: usize,
        start_instr_index: usize,
        aliases: *std.AutoHashMap(ir.LocalId, void),
        visited: *std.AutoHashMap(u64, void),
        result: *const Result,
        program: *const ir.Program,
    ) ClosureEscape {
        const visit_key: u64 = (@as(u64, @intCast(block_index)) << 32) | @as(u64, @intCast(start_instr_index));
        if (visited.contains(visit_key)) return .merged_escape;
        visited.put(visit_key, {}) catch return .unknown_escape;

        const block = func.body[block_index];
        for (block.instructions[start_instr_index..], start_instr_index..) |instr, idx| {
            switch (instr) {
                .local_get => |lg| {
                    if (aliases.contains(lg.source)) aliases.put(lg.dest, {}) catch return .unknown_escape;
                },
                .local_set => |ls| {
                    if (aliases.contains(ls.value)) aliases.put(ls.dest, {}) catch return .unknown_escape;
                },
                .move_value => |mv| {
                    if (aliases.contains(mv.source)) aliases.put(mv.dest, {}) catch return .unknown_escape;
                },
                .share_value => |sv| {
                    if (aliases.contains(sv.source)) aliases.put(sv.dest, {}) catch return .unknown_escape;
                },
                .call_closure => |call| {
                    if (aliases.contains(call.callee)) return if (idx == 1) .call_local else .block_local;
                    for (call.args) |arg| if (aliases.contains(arg)) return .passed_unknown;
                },
                .call_direct => |call| {
                    for (call.args, 0..) |arg, arg_idx| {
                        if (!aliases.contains(arg)) continue;
                        if (self.isClosureParamMarkedSafe(call.function, @intCast(arg_idx), result)) return .passed_known_safe;
                        return .passed_unknown;
                    }
                },
                .call_named => |call| {
                    for (call.args, 0..) |arg, arg_idx| {
                        if (!aliases.contains(arg)) continue;
                        if (self.resolveFunctionIdByName(program, call.name)) |function_id| {
                            if (self.isClosureParamMarkedSafe(function_id, @intCast(arg_idx), result)) return .passed_known_safe;
                        }
                        return .passed_unknown;
                    }
                },
                .ret => |ret| {
                    if (ret.value) |value| if (aliases.contains(value)) return .returned;
                },
                .tuple_init => |agg| for (agg.elements) |elem| if (aliases.contains(elem)) return .stored_local,
                .list_init => |agg| for (agg.elements) |elem| if (aliases.contains(elem)) return .stored_local,
                .map_init => |map| for (map.entries) |entry| if (aliases.contains(entry.key) or aliases.contains(entry.value)) return .stored_heap,
                .struct_init => |si| for (si.fields) |field| if (aliases.contains(field.value)) return .stored_heap,
                .union_init => |ui| if (aliases.contains(ui.value)) return .stored_heap,
                .phi => |phi| for (phi.sources) |source| if (aliases.contains(source.value)) return .merged_escape,
                .branch => |br| {
                    if (self.findBlockIndexByLabel(func, br.target)) |target_idx| {
                        var next_aliases = self.cloneAliasSet(aliases) catch return .unknown_escape;
                        defer next_aliases.deinit();
                        var next_visited = self.cloneVisitedSet(visited) catch return .unknown_escape;
                        defer next_visited.deinit();
                        return self.classifyFromBlock(func, target_idx, 0, &next_aliases, &next_visited, result, program);
                    }
                    return .unknown_escape;
                },
                .jump => |jmp| {
                    if (self.findBlockIndexByLabel(func, jmp.target)) |target_idx| {
                        var next_aliases = self.cloneAliasSet(aliases) catch return .unknown_escape;
                        defer next_aliases.deinit();
                        var next_visited = self.cloneVisitedSet(visited) catch return .unknown_escape;
                        defer next_visited.deinit();
                        return self.classifyFromBlock(func, target_idx, 0, &next_aliases, &next_visited, result, program);
                    }
                    return .unknown_escape;
                },
                .cond_branch => |cb| {
                    const then_escape = if (self.findBlockIndexByLabel(func, cb.then_target)) |target_idx| blk: {
                        var then_aliases = self.cloneAliasSet(aliases) catch break :blk .unknown_escape;
                        defer then_aliases.deinit();
                        var then_visited = self.cloneVisitedSet(visited) catch break :blk .unknown_escape;
                        defer then_visited.deinit();
                        break :blk self.classifyFromBlock(func, target_idx, 0, &then_aliases, &then_visited, result, program);
                    } else .unknown_escape;
                    const else_escape = if (self.findBlockIndexByLabel(func, cb.else_target)) |target_idx| blk: {
                        var else_aliases = self.cloneAliasSet(aliases) catch break :blk .unknown_escape;
                        defer else_aliases.deinit();
                        var else_visited = self.cloneVisitedSet(visited) catch break :blk .unknown_escape;
                        defer else_visited.deinit();
                        break :blk self.classifyFromBlock(func, target_idx, 0, &else_aliases, &else_visited, result, program);
                    } else .unknown_escape;
                    return joinClosureEscape(then_escape, else_escape);
                },
                else => {},
            }
        }
        return .no_escape;
    }

    fn cloneAliasSet(self: *Analyzer, aliases: *const std.AutoHashMap(ir.LocalId, void)) !std.AutoHashMap(ir.LocalId, void) {
        var cloned = std.AutoHashMap(ir.LocalId, void).init(self.allocator);
        var it = aliases.iterator();
        while (it.next()) |entry| {
            try cloned.put(entry.key_ptr.*, {});
        }
        return cloned;
    }

    fn cloneVisitedSet(self: *Analyzer, visited: *const std.AutoHashMap(u64, void)) !std.AutoHashMap(u64, void) {
        var cloned = std.AutoHashMap(u64, void).init(self.allocator);
        var it = visited.iterator();
        while (it.next()) |entry| {
            try cloned.put(entry.key_ptr.*, {});
        }
        return cloned;
    }

    fn findBlockIndexByLabel(self: *Analyzer, func: ir.Function, label: ir.LabelId) ?usize {
        _ = self;
        for (func.body, 0..) |block, idx| {
            if (block.label == label) return idx;
        }
        return null;
    }

    fn resolveFunctionIdByName(self: *Analyzer, program: *const ir.Program, name: []const u8) ?ir.FunctionId {
        _ = self;
        for (program.functions) |func| {
            if (std.mem.eql(u8, func.name, name)) return func.id;
        }
        return null;
    }

    fn isClosureParamMarkedSafe(self: *Analyzer, function_id: ir.FunctionId, param_idx: u32, result: *const Result) bool {
        _ = self;
        const summary = result.function_param_summaries.get(function_id) orelse return false;
        if (param_idx >= summary.closure_params_safe.len) return false;
        return summary.closure_params_safe[param_idx];
    }

    fn summarizeFunctionParams(self: *Analyzer, func: ir.Function, result: *const Result, program: *const ir.Program) !FunctionParamSummary {
        const safe = try self.allocator.alloc(bool, func.params.len);
        for (safe, func.params, 0..) |*slot, param, idx| {
            slot.* = switch (param.type_expr) {
                .function => self.isClosureParamKnownSafe(func, @intCast(idx), result, program),
                else => false,
            };
        }
        return .{ .closure_params_safe = safe };
    }

    fn isClosureParamKnownSafe(self: *Analyzer, func: ir.Function, param_idx: u32, result: *const Result, program: *const ir.Program) bool {
        var aliases = std.AutoHashMap(ir.LocalId, void).init(self.allocator);
        defer aliases.deinit();
        for (func.body) |block| {
            for (block.instructions) |instr| {
                switch (instr) {
                    .param_get => |pg| {
                        if (pg.index == param_idx) aliases.put(pg.dest, {}) catch return false;
                    },
                    else => {},
                }
            }
        }
        if (aliases.count() == 0) return false;

        var changed = true;
        while (changed) {
            changed = false;
            for (func.body) |block| {
                for (block.instructions) |instr| {
                    switch (instr) {
                        .local_get => |lg| {
                            if (aliases.contains(lg.source) and !aliases.contains(lg.dest)) {
                                aliases.put(lg.dest, {}) catch return false;
                                changed = true;
                            }
                        },
                        .local_set => |ls| {
                            if (aliases.contains(ls.value) and !aliases.contains(ls.dest)) {
                                aliases.put(ls.dest, {}) catch return false;
                                changed = true;
                            }
                        },
                        .move_value => |mv| {
                            if (aliases.contains(mv.source) and !aliases.contains(mv.dest)) {
                                aliases.put(mv.dest, {}) catch return false;
                                changed = true;
                            }
                        },
                        .share_value => |sv| {
                            if (aliases.contains(sv.source) and !aliases.contains(sv.dest)) {
                                aliases.put(sv.dest, {}) catch return false;
                                changed = true;
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        for (func.body) |block| {
            for (block.instructions) |instr| {
                switch (instr) {
                    .call_closure => |call| {
                        if (aliases.contains(call.callee)) continue;
                        for (call.args) |arg| if (aliases.contains(arg)) return false;
                    },
                    .call_direct => |call| {
                        for (call.args, 0..) |arg, arg_idx| {
                            if (!aliases.contains(arg)) continue;
                            if (!self.isClosureParamMarkedSafe(call.function, @intCast(arg_idx), result)) return false;
                        }
                    },
                    .call_named => |call| {
                        for (call.args, 0..) |arg, arg_idx| {
                            if (!aliases.contains(arg)) continue;
                            const callee_id = self.resolveFunctionIdByName(program, call.name) orelse return false;
                            if (!self.isClosureParamMarkedSafe(callee_id, @intCast(arg_idx), result)) return false;
                        }
                    },
                    .ret => |ret| if (ret.value) |value| if (aliases.contains(value)) return false,
                    .tuple_init => |agg| for (agg.elements) |elem| if (aliases.contains(elem)) return false,
                    .list_init => |agg| for (agg.elements) |elem| if (aliases.contains(elem)) return false,
                    .map_init => |map| for (map.entries) |entry| if (aliases.contains(entry.key) or aliases.contains(entry.value)) return false,
                    .struct_init => |si| for (si.fields) |field| if (aliases.contains(field.value)) return false,
                    .union_init => |ui| if (aliases.contains(ui.value)) return false,
                    .make_closure => |mc| for (mc.captures) |capture| if (aliases.contains(capture)) return false,
                    .phi => |phi| for (phi.sources) |source| if (aliases.contains(source.value)) return false,
                    else => {},
                }
            }
        }
        return true;
    }
};

pub fn joinClosureEscape(a: ClosureEscape, b: ClosureEscape) ClosureEscape {
    if (a == b) return a;
    if (a == .unknown_escape or b == .unknown_escape) return .unknown_escape;
    if (a == .merged_escape or b == .merged_escape) return .merged_escape;
    if (a == .returned or b == .returned) return .returned;
    if (a == .stored_heap or b == .stored_heap) return .stored_heap;
    if (a == .passed_unknown or b == .passed_unknown) return .passed_unknown;
    if (a == .passed_known_safe or b == .passed_known_safe) return .passed_known_safe;
    if (a == .stored_local or b == .stored_local) return .stored_local;
    if (a == .block_local or b == .block_local) return .block_local;
    if (a == .call_local or b == .call_local) return .call_local;
    return .no_escape;
}

pub fn joinLifetime(a: ValueLifetime, b: ValueLifetime) ValueLifetime {
    if (a == b) return a;
    if (a == .unknown or b == .unknown) return .unknown;
    if (a == .escaping or b == .escaping) return .escaping;
    if (a == .merged or b == .merged) return .merged;
    if (a == .function_live or b == .function_live) return .function_live;
    if (a == .block_live or b == .block_live) return .block_live;
    if (a == .local_only or b == .local_only) return .local_only;
    return .dead;
}

test "joinClosureEscape prefers stronger escape state" {
    try std.testing.expectEqual(ClosureEscape.returned, joinClosureEscape(.call_local, .returned));
    try std.testing.expectEqual(ClosureEscape.block_local, joinClosureEscape(.no_escape, .block_local));
    try std.testing.expectEqual(ClosureEscape.unknown_escape, joinClosureEscape(.passed_unknown, .unknown_escape));
}

test "joinLifetime prefers stronger liveness" {
    try std.testing.expectEqual(ValueLifetime.escaping, joinLifetime(.block_live, .escaping));
    try std.testing.expectEqual(ValueLifetime.function_live, joinLifetime(.local_only, .function_live));
    try std.testing.expectEqual(ValueLifetime.unknown, joinLifetime(.merged, .unknown));
}

test "analyzer classifies immediate closure call as call_local" {
    var analyzer = Analyzer.init(std.testing.allocator);
    const instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{1} } },
        .{ .call_closure = .{ .dest = 2, .callee = 0, .args = &.{3}, .arg_modes = &.{.share}, .return_type = .i64 } },
    };
    const func = ir.Function{
        .id = 1,
        .name = "foo",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{.{ .label = 0, .instructions = &instrs }},
        .is_closure = true,
        .captures = &.{.{ .name = "x", .type_expr = .i64, .ownership = .shared }},
    };

    var result = try analyzer.analyzeProgram(&.{ .functions = &.{func}, .type_defs = &.{}, .entry = null });
    defer result.deinit();

    const summary = result.closure_sites.get(0).?;
    try std.testing.expectEqual(ClosureEscape.call_local, summary.escape);
    try std.testing.expectEqual(AllocationStrategy.none_direct_call, summary.allocation);
}

test "analyzer classifies returned closure as returned" {
    var analyzer = Analyzer.init(std.testing.allocator);
    const ret_type: ir.ZigType = .i64;
    const instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{1} } },
        .{ .ret = .{ .value = 0 } },
    };
    const func = ir.Function{
        .id = 1,
        .name = "foo",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .{ .function = .{ .params = &.{}, .return_type = &ret_type } },
        .body = &.{.{ .label = 0, .instructions = &instrs }},
        .is_closure = true,
        .captures = &.{.{ .name = "x", .type_expr = .i64, .ownership = .borrowed }},
    };

    var result = try analyzer.analyzeProgram(&.{ .functions = &.{func}, .type_defs = &.{}, .entry = null });
    defer result.deinit();

    const summary = result.closure_sites.get(0).?;
    try std.testing.expectEqual(ClosureEscape.returned, summary.escape);
    try std.testing.expectEqual(AllocationStrategy.heap_env, summary.allocation);
}

test "analyzer propagates local lifetime through aliases and phi" {
    var analyzer = Analyzer.init(std.testing.allocator);
    const instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{1} } },
        .{ .local_get = .{ .dest = 2, .source = 0 } },
        .{ .share_value = .{ .dest = 3, .source = 2 } },
        .{ .phi = .{ .dest = 4, .sources = &.{ .{ .from_block = 0, .value = 0 }, .{ .from_block = 0, .value = 3 } } } },
    };
    const func = ir.Function{
        .id = 1,
        .name = "foo",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{.{ .label = 0, .instructions = &instrs }},
        .is_closure = true,
        .captures = &.{.{ .name = "x", .type_expr = .i64, .ownership = .shared }},
    };

    var result = try analyzer.analyzeProgram(&.{ .functions = &.{func}, .type_defs = &.{}, .entry = null });
    defer result.deinit();

    try std.testing.expectEqual(ValueLifetime.merged, result.local_lifetimes.get(0).?.lifetime);
    try std.testing.expectEqual(ValueLifetime.merged, result.local_lifetimes.get(2).?.lifetime);
    try std.testing.expectEqual(ValueLifetime.merged, result.local_lifetimes.get(3).?.lifetime);
    try std.testing.expectEqual(ValueLifetime.merged, result.local_lifetimes.get(4).?.lifetime);
}

test "analyzer classifies passed known-safe closure" {
    var analyzer = Analyzer.init(std.testing.allocator);
    const callee_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .call_closure = .{ .dest = 2, .callee = 0, .args = &.{1}, .arg_modes = &.{.share}, .return_type = .i64 } },
        .{ .ret = .{ .value = 2 } },
    };
    const caller_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 3, .captures = &.{1} } },
        .{ .call_direct = .{ .dest = 2, .function = 1, .args = &.{ 0, 4 }, .arg_modes = &.{ .share, .share } } },
    };
    const ret_type: ir.ZigType = .i64;
    const fn_ty = ir.ZigType{ .function = .{ .params = &.{.i64}, .return_type = &ret_type } };
    const callee = ir.Function{
        .id = 1,
        .name = "apply",
        .scope_id = 0,
        .arity = 2,
        .params = &.{ .{ .name = "f", .type_expr = fn_ty }, .{ .name = "x", .type_expr = .i64 } },
        .return_type = .i64,
        .body = &.{.{ .label = 0, .instructions = &callee_instrs }},
        .is_closure = false,
        .captures = &.{},
    };
    const closure_func = ir.Function{
        .id = 3,
        .name = "add_x",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "y", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{.{ .label = 0, .instructions = &.{} }},
        .is_closure = true,
        .captures = &.{.{ .name = "x", .type_expr = .i64, .ownership = .shared }},
    };
    const caller = ir.Function{
        .id = 2,
        .name = "caller",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{.{ .label = 0, .instructions = &caller_instrs }},
        .is_closure = false,
        .captures = &.{},
    };

    var result = try analyzer.analyzeProgram(&.{ .functions = &.{ callee, caller, closure_func }, .type_defs = &.{}, .entry = null });
    defer result.deinit();

    try std.testing.expect(result.function_param_summaries.get(1).?.closure_params_safe[0]);
    const summary = result.closure_sites.get(0).?;
    try std.testing.expectEqual(ClosureEscape.passed_known_safe, summary.escape);
    try std.testing.expectEqual(AllocationStrategy.local_env, summary.allocation);
}

test "analyzer computes transitive known-safe closure passing" {
    var analyzer = Analyzer.init(std.testing.allocator);
    const apply_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .call_closure = .{ .dest = 2, .callee = 0, .args = &.{1}, .arg_modes = &.{.share}, .return_type = .i64 } },
        .{ .ret = .{ .value = 2 } },
    };
    const wrap_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .call_direct = .{ .dest = 2, .function = 1, .args = &.{ 0, 1 }, .arg_modes = &.{ .share, .share } } },
        .{ .ret = .{ .value = 2 } },
    };
    const caller_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 5, .captures = &.{1} } },
        .{ .call_direct = .{ .dest = 2, .function = 3, .args = &.{ 0, 4 }, .arg_modes = &.{ .share, .share } } },
    };
    const ret_type: ir.ZigType = .i64;
    const fn_ty = ir.ZigType{ .function = .{ .params = &.{.i64}, .return_type = &ret_type } };
    const apply = ir.Function{
        .id = 1,
        .name = "apply",
        .scope_id = 0,
        .arity = 2,
        .params = &.{ .{ .name = "f", .type_expr = fn_ty }, .{ .name = "x", .type_expr = .i64 } },
        .return_type = .i64,
        .body = &.{.{ .label = 0, .instructions = &apply_instrs }},
        .is_closure = false,
        .captures = &.{},
    };
    const wrap = ir.Function{
        .id = 3,
        .name = "wrap",
        .scope_id = 0,
        .arity = 2,
        .params = &.{ .{ .name = "f", .type_expr = fn_ty }, .{ .name = "x", .type_expr = .i64 } },
        .return_type = .i64,
        .body = &.{.{ .label = 0, .instructions = &wrap_instrs }},
        .is_closure = false,
        .captures = &.{},
    };
    const closure_func = ir.Function{
        .id = 5,
        .name = "add_x",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "y", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{.{ .label = 0, .instructions = &.{} }},
        .is_closure = true,
        .captures = &.{.{ .name = "x", .type_expr = .i64, .ownership = .shared }},
    };
    const caller = ir.Function{
        .id = 7,
        .name = "caller",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{.{ .label = 0, .instructions = &caller_instrs }},
        .is_closure = false,
        .captures = &.{},
    };

    var result = try analyzer.analyzeProgram(&.{ .functions = &.{ apply, wrap, closure_func, caller }, .type_defs = &.{}, .entry = null });
    defer result.deinit();

    try std.testing.expect(result.function_param_summaries.get(1).?.closure_params_safe[0]);
    try std.testing.expect(result.function_param_summaries.get(3).?.closure_params_safe[0]);
    const summary = result.closure_sites.get(0).?;
    try std.testing.expectEqual(ClosureEscape.passed_known_safe, summary.escape);
}

test "closure summaries join across multiple sites for same function" {
    var analyzer = Analyzer.init(std.testing.allocator);
    const instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 9, .captures = &.{1} } },
        .{ .call_closure = .{ .dest = 2, .callee = 0, .args = &.{3}, .arg_modes = &.{.share}, .return_type = .i64 } },
        .{ .make_closure = .{ .dest = 4, .function = 9, .captures = &.{5} } },
        .{ .ret = .{ .value = 4 } },
    };
    const closure_func = ir.Function{
        .id = 9,
        .name = "same_closure",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "y", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{.{ .label = 0, .instructions = &instrs }},
        .is_closure = true,
        .captures = &.{.{ .name = "x", .type_expr = .i64, .ownership = .shared }},
    };

    var result = try analyzer.analyzeProgram(&.{ .functions = &.{closure_func}, .type_defs = &.{}, .entry = null });
    defer result.deinit();

    const summary = result.closure_functions.get(9).?;
    try std.testing.expectEqual(ClosureEscape.returned, summary.escape);
    try std.testing.expectEqual(AllocationStrategy.heap_env, summary.allocation);
}

test "analyzer joins branch escapes across CFG" {
    var analyzer = Analyzer.init(std.testing.allocator);
    const block0_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 7, .captures = &.{1} } },
        .{ .cond_branch = .{ .condition = 2, .then_target = 1, .else_target = 2 } },
    };
    const block1_instrs = [_]ir.Instruction{
        .{ .ret = .{ .value = 0 } },
    };
    const block2_instrs = [_]ir.Instruction{
        .{ .call_closure = .{ .dest = 3, .callee = 0, .args = &.{4}, .arg_modes = &.{.share}, .return_type = .i64 } },
    };
    const func = ir.Function{
        .id = 7,
        .name = "branchy",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{
            .{ .label = 0, .instructions = &block0_instrs },
            .{ .label = 1, .instructions = &block1_instrs },
            .{ .label = 2, .instructions = &block2_instrs },
        },
        .is_closure = true,
        .captures = &.{.{ .name = "x", .type_expr = .i64, .ownership = .shared }},
    };

    var result = try analyzer.analyzeProgram(&.{ .functions = &.{func}, .type_defs = &.{}, .entry = null });
    defer result.deinit();

    const summary = result.closure_sites.get(0).?;
    try std.testing.expectEqual(ClosureEscape.returned, summary.escape);
    try std.testing.expectEqual(ValueLifetime.escaping, result.local_lifetimes.get(0).?.lifetime);
}
