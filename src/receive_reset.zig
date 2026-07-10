//! Receive-back-edge arena auto-reset — the iteration-closure proof
//! (P6-J4, plan item 6.4; research.md §6.5 "the auto-reset insight";
//! zap-concurrency-research.md §4).
//!
//! A long-lived server loop under a BULK_OR_NEVER manager (`Memory.Arena`)
//! grows without bound: every message adoption, handler temporary, and reply
//! staging allocation joins the bulk set, which frees only at process death
//! (the §2.4 arena-server growth warning). The fix is O(1) bulk reclamation
//! at the loop's receive back-edge: reset the process's arena to a watermark
//! every time control returns to the receive point — PROVIDED the compiler
//! can prove the ITERATION CLOSURE: no heap allocation made after the
//! process's first proven receive is reachable at the receive program point.
//! A reset without that proof is a use-after-free, so THE GATE IS
//! SOUNDNESS-CRITICAL AND CONSERVATIVE: when any condition below cannot be
//! established, the site is left un-instrumented (no reset — the safe
//! pre-P6-J4 behavior); over-rejection costs only performance.
//!
//! ## What this pass emits
//!
//! For every receive-primitive call site that passes the proof, one
//! `call_builtin "ProcessRuntime.receive_iteration_reset"` is inserted
//! IMMEDIATELY BEFORE the receive call. At runtime the intrinsic dispatches
//! through the calling process's manager binding
//! (`src/runtime/concurrency/abi.zig`, `zap_proc_receive_iteration_reset`):
//! a manager exposing the `ARSR` capability (Arena) captures the iteration
//! watermark on the FIRST call and bulk-frees back to it on every later
//! call; every other model no-ops. The decision is PER RECEIVE SITE (per
//! loop), never per process: one process may run a proven flat loop and an
//! unproven accumulating loop, and only the former resets.
//!
//! Recognition keys on the lowered RUNTIME PRIMITIVE names
//! (`ProcessRuntime.*` — the compiler's own `:zig.` intrinsic bridge
//! vocabulary in `src/runtime.zig`), never on Zap library struct names —
//! the same prime directive `src/concurrency_verifier.zig` documents.
//!
//! ## The conservative iteration-closure proof
//!
//! A receive site S in function F is proven when EVERY condition holds:
//!
//! 1. **F is a reset context** (`computeResetContexts`): every activation
//!    of F sits on a stack whose frames below hold no live heap reference.
//!    Established by a monotone fixpoint over the whole-program reference
//!    graph — F is a reset context iff it has at least one sanctioned
//!    spawn-entry reference or is reached only from reset contexts:
//!      * a `make_closure(F, no captures)` whose dest's every use is the
//!        entry argument of a spawn runtime primitive (or a
//!        retain/release/debug bookkeeping touch) — the process-entry
//!        reference, below which only the kernel bootstrap frame exists;
//!      * a `tail_call` denoting F — the caller's frame is REPLACED, so it
//!        adds nothing to the stack: unconditionally sanctioned from F
//!        itself (the self back-edge; sound by induction on the first
//!        entry) and sanctioned from any other reset context;
//!      * a `call_direct`/`call_named` denoting F from a reset context G
//!        at a call site across which NO heap-possible local of G is live
//!        (the same interval test as condition 3) — the entry→loop chain.
//!    Any other reference — dispatch-table calls, `__try` variants,
//!    closure captures, storage into aggregates, program-entry linkage —
//!    disqualifies F entirely. F must additionally be shape-eligible:
//!    non-closure, capture-free, every parameter scalar (a heap-typed
//!    parameter is live for the whole activation, spanning every receive),
//!    and free of backward intra-function control flow (condition 3's
//!    linear-order argument requires it).
//!
//! 2. **Function names resolve conservatively** (`nameDenotes`): name-based
//!    references (`call_named`/`tail_call`/`try_call_named`) are matched
//!    against F under a SUPERSET predicate (exact, arity-suffix-stripped,
//!    and last-path-component forms), so a reference can be spuriously
//!    ATTRIBUTED to F (over-rejection) but never missed (which would be
//!    unsound). Precision here — e.g. resolving through the real dispatch
//!    tables — is deferral item (ii) in the plan 6.4 ledger.
//!
//! 3. **No heap-possible local of F is live across S** (`checkSite`): with
//!    only forward control flow, every execution trace visits linear
//!    positions monotonically, so a value defined before S and used after
//!    it must satisfy `first_def(L) < pos(S) < last_use(L)` in the
//!    linearized instruction tree — an over-approximation of liveness
//!    (multi-def locals and never-taken paths only WIDEN intervals, which
//!    only rejects more). "Heap-possible" is a def-site classification
//!    (`localClassification`): scalar producers (constants, arithmetic,
//!    comparisons, checks) and static string literals are safe; alias
//!    moves propagate their source's class; calls are safe only when the
//!    return type is provably scalar; every allocation, aggregate access,
//!    merge value, and unknown is heap-possible. A local with a use but no
//!    attributable def is heap-possible and live from function entry —
//!    the catch-all that keeps unknown IR shapes sound.
//!
//! With those, at any execution of S: the frames below F hold no heap
//! references (1), F's own frame holds none across S (3), and — because
//! this is a per-process PRIVATE heap whose only external escape hatches
//! copy out (serialize-on-send; the blob domain is a separate allocation
//! domain; process teardown already bulk-frees the heap wholesale, so any
//! runtime structure retaining a process-heap pointer would already be a
//! teardown use-after-free) — nothing else can reach an allocation made
//! after the process's first proven receive. Resetting the arena to that
//! watermark is therefore sound.
//!
//! ## Numbered deferrals (plan item 6.4 follow-ons)
//!
//! (i) The plain `Process.spawn(&f/0)` FUNCTION path routes the entry
//! closure through the library function's parameter, which this pass
//! conservatively rejects (the closure escapes into a call argument);
//! sanctioning it needs the interprocedural "argument only flows to a
//! spawn primitive" summary. The managed `spawn(f, Memory.Arena)` MACRO
//! path — the one that matters, since only Arena processes reclaim — lowers
//! the spawn primitive inline and is covered. (ii) Name-resolution
//! precision (dispatch groups, `__try` variants, mutual recursion between
//! loop functions). (iii) Accumulating-state precision: a loop that
//! retains state across iterations is rejected wholesale today; a
//! region-solver split of per-iteration vs retained regions
//! (`src/region_solver.zig` storage modes over the back-edge) could reset
//! the per-iteration region only.

const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");

/// The reset intrinsic inserted before proven receive sites — a
/// `ProcessRuntime` runtime primitive (`src/runtime.zig`), lowered by the
/// ZIR backend's generic `Module.function` builtin splitter.
pub const RESET_PRIMITIVE_BUILTIN_NAME = "ProcessRuntime.receive_iteration_reset";

/// The receive-primitive vocabulary (`src/macro.zig`'s `receiveToCase`
/// lowering): the four scalar decodes plus the generic deep-copy decode.
/// `wait_for_message` (the `after` arm's non-consuming probe) is
/// deliberately absent: the reset rides the CONSUMING decode, which the
/// `after` lowering dispatches to right after a successful wait.
const receive_primitive_names = [_][]const u8{
    "ProcessRuntime.receive_message",
    "ProcessRuntime.receive_i64",
    "ProcessRuntime.receive_u64",
    "ProcessRuntime.receive_f64",
    "ProcessRuntime.receive_bool",
};

/// The spawn-primitive vocabulary: a `make_closure` feeding one of these as
/// the ENTRY argument is the sanctioned process-entry reference.
/// `spawn_process_at` is the P3-J3 managed-spawn rewiring target
/// (`src/monomorphize.zig`'s `SPAWN_AT_BUILTIN`) — the shape every
/// `spawn(f, Memory.X)` site carries after the spawn-manager pass;
/// `spawn_process_managed` is its pre-resolution form; the remaining names
/// cover any direct lowering of the unmanaged primitives.
const spawn_builtin_names = [_][]const u8{
    "ProcessRuntime.spawn_process",
    "ProcessRuntime.spawn_process_at",
    "ProcessRuntime.spawn_process_managed",
    "ProcessRuntime.spawn_link_process",
    "ProcessRuntime.spawn_monitor_process",
};

fn isReceivePrimitiveName(name: []const u8) bool {
    for (receive_primitive_names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn isSpawnBuiltinName(name: []const u8) bool {
    for (spawn_builtin_names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Name matching (superset — condition 2 in the module doc)
// ---------------------------------------------------------------------------

/// Strip a trailing `__<digits>` arity suffix (`"loop__1"` → `"loop"`).
fn stripAritySuffix(name: []const u8) []const u8 {
    const separator = std.mem.lastIndexOf(u8, name, "__") orelse return name;
    const suffix = name[separator + 2 ..];
    if (suffix.len == 0) return name;
    for (suffix) |character| {
        if (!std.ascii.isDigit(character)) return name;
    }
    return name[0..separator];
}

/// The last dotted path component (`"A.B.loop"` → `"loop"`).
fn lastPathComponent(name: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[separator + 1 ..];
}

/// Whether a name-based reference COULD denote `function` — the deliberate
/// superset predicate (module doc condition 2): different pipeline stages
/// carry different name shapes (qualified vs local, with vs without the
/// arity suffix), and MISSING a reference would be unsound, so any form
/// collision counts as a reference. Spurious attribution only over-rejects.
fn nameDenotes(reference_name: []const u8, function: *const ir.Function) bool {
    const reference_base = stripAritySuffix(reference_name);
    const function_base = stripAritySuffix(function.name);
    if (std.mem.eql(u8, reference_name, function.name)) return true;
    if (std.mem.eql(u8, reference_base, function_base)) return true;
    if (function.local_name.len != 0) {
        const local_base = stripAritySuffix(function.local_name);
        if (std.mem.eql(u8, reference_base, local_base)) return true;
        if (std.mem.eql(u8, lastPathComponent(reference_base), local_base)) return true;
    }
    return std.mem.eql(u8, lastPathComponent(reference_base), lastPathComponent(function_base));
}

/// Program-wide name/id resolution index — built ONCE so the per-call and
/// per-reference queries the analysis makes (thousands of them on a real
/// post-monomorphization program) are hash lookups, not O(functions) scans
/// with per-pair string work. The bucket scheme answers a SUPERSET of
/// `nameDenotes` (a lookup may return extra candidates), which is the
/// conservative direction everywhere it is consumed: extra candidates only
/// widen heap classification and reference attribution.
const NameResolver = struct {
    const IndexList = std.ArrayListUnmanaged(u32);

    allocator: std.mem.Allocator,
    /// `Function.id` → function index (ids are unique post-monomorphize).
    id_to_index: std.AutoHashMapUnmanaged(ir.FunctionId, u32) = .empty,
    /// Dispatch-group key (`Function.id` and `source_group_id`) → indices.
    group_to_indices: std.AutoHashMapUnmanaged(u32, IndexList) = .empty,
    /// Exact `Function.name` → indices.
    exact_map: std.StringHashMapUnmanaged(IndexList) = .empty,
    /// Arity-stripped `Function.name` / `local_name` bases → indices.
    base_map: std.StringHashMapUnmanaged(IndexList) = .empty,
    /// Last path components of the bases → indices.
    last_map: std.StringHashMapUnmanaged(IndexList) = .empty,
    /// Scratch dedupe bitmap, one slot per function, cleared per query.
    visited: []bool,
    /// Scratch candidate buffer reused across queries.
    scratch: IndexList = .empty,

    fn init(allocator: std.mem.Allocator, program: *const ir.Program) error{OutOfMemory}!NameResolver {
        var resolver = NameResolver{
            .allocator = allocator,
            .visited = try allocator.alloc(bool, program.functions.len),
        };
        errdefer resolver.deinit();
        @memset(resolver.visited, false);
        for (program.functions, 0..) |*function, raw_index| {
            const index: u32 = @intCast(raw_index);
            try resolver.id_to_index.put(allocator, function.id, index);
            try appendTo(&resolver.group_to_indices, allocator, function.id, index);
            if (function.source_group_id) |group| {
                try appendTo(&resolver.group_to_indices, allocator, group, index);
            }
            const name_base = stripAritySuffix(function.name);
            try appendToString(&resolver.exact_map, allocator, function.name, index);
            try appendToString(&resolver.base_map, allocator, name_base, index);
            try appendToString(&resolver.last_map, allocator, lastPathComponent(name_base), index);
            if (function.local_name.len != 0) {
                const local_base = stripAritySuffix(function.local_name);
                try appendToString(&resolver.base_map, allocator, local_base, index);
                try appendToString(&resolver.last_map, allocator, local_base, index);
            }
        }
        return resolver;
    }

    fn deinit(self: *NameResolver) void {
        self.id_to_index.deinit(self.allocator);
        deinitListMap(u32, &self.group_to_indices, self.allocator);
        deinitStringListMap(&self.exact_map, self.allocator);
        deinitStringListMap(&self.base_map, self.allocator);
        deinitStringListMap(&self.last_map, self.allocator);
        self.allocator.free(self.visited);
        self.scratch.deinit(self.allocator);
    }

    fn appendTo(map: *std.AutoHashMapUnmanaged(u32, IndexList), allocator: std.mem.Allocator, key: u32, index: u32) error{OutOfMemory}!void {
        const entry = try map.getOrPut(allocator, key);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(allocator, index);
    }

    fn appendToString(map: *std.StringHashMapUnmanaged(IndexList), allocator: std.mem.Allocator, key: []const u8, index: u32) error{OutOfMemory}!void {
        const entry = try map.getOrPut(allocator, key);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(allocator, index);
    }

    fn deinitListMap(comptime Key: type, map: *std.AutoHashMapUnmanaged(Key, IndexList), allocator: std.mem.Allocator) void {
        var iterator = map.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit(allocator);
        map.deinit(allocator);
    }

    fn deinitStringListMap(map: *std.StringHashMapUnmanaged(IndexList), allocator: std.mem.Allocator) void {
        var iterator = map.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit(allocator);
        map.deinit(allocator);
    }

    /// Deduplicated candidate function indices a name-based reference could
    /// denote (a superset of `nameDenotes` matches). The returned slice is
    /// the internal scratch buffer, valid until the next query.
    fn candidatesForName(self: *NameResolver, reference_name: []const u8) error{OutOfMemory}![]const u32 {
        self.scratch.clearRetainingCapacity();
        const reference_base = stripAritySuffix(reference_name);
        try self.gather(self.exact_map.get(reference_name));
        try self.gather(self.base_map.get(reference_base));
        try self.gather(self.last_map.get(lastPathComponent(reference_base)));
        for (self.scratch.items) |index| self.visited[index] = false;
        return self.scratch.items;
    }

    /// Deduplicated candidate indices for a dispatch-group reference.
    fn candidatesForGroup(self: *NameResolver, group_id: u32) error{OutOfMemory}![]const u32 {
        self.scratch.clearRetainingCapacity();
        try self.gather(self.group_to_indices.get(group_id));
        for (self.scratch.items) |index| self.visited[index] = false;
        return self.scratch.items;
    }

    fn gather(self: *NameResolver, bucket: ?IndexList) error{OutOfMemory}!void {
        const list = bucket orelse return;
        for (list.items) |index| {
            if (self.visited[index]) continue;
            self.visited[index] = true;
            try self.scratch.append(self.allocator, index);
        }
    }
};

// ---------------------------------------------------------------------------
// Scalar / heap-possible type classification
// ---------------------------------------------------------------------------

/// Whether values of `zig_type` can never carry a reference into the
/// process heap: fixed-width numerics, booleans, interned atoms, unit, and
/// `never`. Everything else — including `.any` (unresolved) — is
/// heap-possible.
fn zigTypeIsScalar(zig_type: ir.ZigType) bool {
    return switch (zig_type) {
        .void,
        .bool_type,
        .i8,
        .i16,
        .i32,
        .i64,
        .i128,
        .u8,
        .u16,
        .u32,
        .u64,
        .u128,
        .f16,
        .f32,
        .f64,
        .f80,
        .f128,
        .usize,
        .isize,
        .atom,
        .nil,
        .never,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Linear function analysis (condition 3's substrate)
// ---------------------------------------------------------------------------

const NO_DEF: u32 = std.math.maxInt(u32);

/// Per-function linearization: per-local first-def / last-use positions and
/// the heap-possible flag, plus the receive sites and outgoing references
/// found during the walk. Positions are assigned by one fixed-order
/// traversal (`walkStream`); the rebuild pass replays the identical order,
/// so receive-site ORDINALS agree between analysis and instrumentation.
const LinearFunction = struct {
    first_def: []u32,
    last_use: []u32,
    heap_possible: []bool,
    /// Receive-primitive sites: ordinal (traversal order) + linear position.
    receive_sites: std.ArrayListUnmanaged(ReceiveSite) = .empty,
    /// Outgoing name/id call references (for the reset-context fixpoint).
    call_refs: std.ArrayListUnmanaged(CallRef) = .empty,
    /// `make_closure` sites (sanction analysis resolves their uses).
    closure_refs: std.ArrayListUnmanaged(ClosureRef) = .empty,
    /// Whether any backward intra-function branch target was seen (breaks
    /// the linear-order argument; disqualifies the function).
    has_backward_branch: bool = false,

    fn deinit(self: *LinearFunction, allocator: std.mem.Allocator) void {
        allocator.free(self.first_def);
        allocator.free(self.last_use);
        allocator.free(self.heap_possible);
        self.receive_sites.deinit(allocator);
        self.call_refs.deinit(allocator);
        self.closure_refs.deinit(allocator);
    }
};

const ReceiveSite = struct {
    ordinal: u32,
    position: u32,
};

const CallRefKind = enum {
    /// `call_direct` — precise (by `FunctionId`).
    direct,
    /// `call_named` — name-based (superset attribution).
    named,
    /// `tail_call` — name-based; the caller's frame is replaced.
    tail,
    /// `try_call_named` / `call_dispatch` — always disqualifying.
    disqualifying,
};

const CallRef = struct {
    kind: CallRefKind,
    /// Callee `FunctionId` for `.direct`; the dispatch group id for a
    /// `call_dispatch` `.disqualifying` ref; unused (0) for name-based.
    callee_id: ir.FunctionId = 0,
    /// Callee name for name-based kinds; empty for `.direct`.
    callee_name: []const u8 = "",
    /// Linear position of the call site (for the live-across check).
    position: u32,
    /// True for a `call_dispatch` (`callee_id` is a GROUP id, matched
    /// against both `Function.id` and `Function.source_group_id`).
    is_dispatch_group: bool = false,
};

const ClosureRef = struct {
    callee_id: ir.FunctionId,
    dest: ir.LocalId,
    has_captures: bool,
    /// Resolved by the second (use-scan) pass: every use of `dest` is a
    /// sanctioned spawn-entry / bookkeeping touch.
    sanctioned: bool = true,
};

const Walker = struct {
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: *const ir.Program,
    resolver: *NameResolver,
    info: *LinearFunction,
    next_position: u32 = 0,
    next_receive_ordinal: u32 = 0,

    fn recordDef(self: *Walker, local: ir.LocalId, position: u32, heap: bool) void {
        if (local >= self.info.first_def.len) return; // malformed id — catch-all below keeps it heap-live
        if (position < self.info.first_def[local]) self.info.first_def[local] = position;
        if (heap) self.info.heap_possible[local] = true;
    }

    fn recordUse(self: *Walker, local: ir.LocalId, position: u32) void {
        if (local >= self.info.last_use.len) return;
        if (position > self.info.last_use[local]) self.info.last_use[local] = position;
    }

    fn localIsHeap(self: *const Walker, local: ir.LocalId) bool {
        if (local >= self.info.heap_possible.len) return true;
        return self.info.heap_possible[local];
    }

    /// Whether a call's produced value is provably scalar. Conservative:
    /// unresolved names and mixed candidates are heap-possible. OOM during
    /// resolution degrades to heap-possible (never fails the walk).
    fn namedCallReturnsScalar(self: *Walker, callee_name: []const u8) bool {
        const candidates = self.resolver.candidatesForName(callee_name) catch return false;
        if (candidates.len == 0) return false;
        for (candidates) |candidate_index| {
            if (!zigTypeIsScalar(self.program.functions[candidate_index].return_type)) return false;
        }
        return true;
    }

    fn directCallReturnsScalar(self: *const Walker, callee_id: ir.FunctionId) bool {
        const index = self.resolver.id_to_index.get(callee_id) orelse return false;
        return zigTypeIsScalar(self.program.functions[index].return_type);
    }

    /// Classify one instruction's defined locals and record them at
    /// `position`. `heap` classification is per the module doc: safe only
    /// when the produced value provably carries no process-heap reference.
    fn recordInstructionDefs(self: *Walker, instr: *const ir.Instruction, position: u32) void {
        switch (instr.*) {
            // Scalar producers.
            .const_int => |x| self.recordDef(x.dest, position, false),
            .const_float => |x| self.recordDef(x.dest, position, false),
            .const_bool => |x| self.recordDef(x.dest, position, false),
            .const_atom => |x| self.recordDef(x.dest, position, false),
            .const_nil => |dest| self.recordDef(dest, position, false),
            // A string LITERAL is static rodata, never a process-heap
            // allocation — safe to hold across a receive.
            .const_string => |x| self.recordDef(x.dest, position, false),
            .enum_literal => |x| self.recordDef(x.dest, position, false),
            .binary_op => |x| self.recordDef(x.dest, position, x.op == .concat),
            .unary_op => |x| self.recordDef(x.dest, position, false),
            .list_len_check => |x| self.recordDef(x.dest, position, false),
            .list_is_not_empty => |x| self.recordDef(x.dest, position, false),
            .map_has_key => |x| self.recordDef(x.dest, position, false),
            .bin_len_check => |x| self.recordDef(x.dest, position, false),
            .bin_match_prefix => |x| self.recordDef(x.dest, position, false),
            .bin_read_int => |x| self.recordDef(x.dest, position, false),
            .bin_read_float => |x| self.recordDef(x.dest, position, false),
            .bin_read_utf8 => |x| {
                self.recordDef(x.dest_codepoint, position, false);
                self.recordDef(x.dest_len, position, false);
            },
            .protocol_box_vtable_eq => |x| self.recordDef(x.dest, position, false),
            .match_atom => |x| self.recordDef(x.dest, position, false),
            .match_variant_tag => |x| self.recordDef(x.dest, position, false),
            .match_int => |x| self.recordDef(x.dest, position, false),
            .match_float => |x| self.recordDef(x.dest, position, false),
            .match_string => |x| self.recordDef(x.dest, position, false),
            .match_type => |x| self.recordDef(x.dest, position, false),
            .int_widen => |x| self.recordDef(x.dest, position, false),
            .float_widen => |x| self.recordDef(x.dest, position, false),

            // Alias moves propagate their source's classification.
            .local_get => |x| self.recordDef(x.dest, position, self.localIsHeap(x.source)),
            .move_value => |x| self.recordDef(x.dest, position, self.localIsHeap(x.source)),
            .share_value => |x| self.recordDef(x.dest, position, self.localIsHeap(x.source)),
            .copy_value => |x| self.recordDef(x.dest, position, self.localIsHeap(x.source)),
            .borrow_value => |x| self.recordDef(x.dest, position, self.localIsHeap(x.source)),
            .local_set => |x| self.recordDef(x.dest, position, self.localIsHeap(x.value)),

            // Parameters classify by declared type.
            .param_get => |x| {
                const heap = if (x.index < self.function.params.len)
                    !zigTypeIsScalar(self.function.params[x.index].type_expr)
                else
                    true;
                self.recordDef(x.dest, position, heap);
            },

            // Calls classify by provable return scalar-ness.
            .call_direct => |x| self.recordDef(x.dest, position, !self.directCallReturnsScalar(x.function)),
            .call_named => |x| self.recordDef(x.dest, position, !self.namedCallReturnsScalar(x.name)),
            .call_builtin => |x| self.recordDef(x.dest, position, !zigTypeIsScalar(x.result_type)),
            .call_closure => |x| self.recordDef(x.dest, position, !zigTypeIsScalar(x.return_type)),
            .unwrap_error_union => |x| self.recordDef(x.dest, position, !zigTypeIsScalar(x.payload_type)),
            .typed_undef => |x| self.recordDef(x.dest, position, !zigTypeIsScalar(x.ty)),
            .reuse_alloc => |x| self.recordDef(x.dest, position, !zigTypeIsScalar(x.dest_type)),

            // Union-switch payload bindings define fresh (heap-possible)
            // locals inside their case bodies.
            .union_switch => |x| {
                for (x.cases) |case| {
                    for (case.field_bindings) |binding| {
                        self.recordDef(binding.local_index, position, true);
                    }
                }
            },
            .union_switch_return => |x| {
                for (x.cases) |case| {
                    for (case.field_bindings) |binding| {
                        self.recordDef(binding.local_index, position, true);
                    }
                }
            },
            .optional_dispatch => |x| self.recordDef(x.payload_local, position, true),

            // Everything else defers to the shared primary-dest helper and
            // is heap-possible (allocations, aggregate reads, merges,
            // dispatches, phis, jumps-with-bind, Perceus tokens, …).
            else => {
                if (ir.primaryDefinedLocal(instr)) |dest| {
                    self.recordDef(dest, position, true);
                }
            },
        }
    }

    fn recordInstructionUses(self: *Walker, instr: *const ir.Instruction, position: u32) error{OutOfMemory}!void {
        var uses = arc_liveness.UseList{};
        defer uses.deinit(self.allocator);
        try arc_liveness.collectUses(self.allocator, instr.*, &uses);
        for (uses.slice()) |local| self.recordUse(local, position);
    }

    /// Backward-branch detection: any label target at or before the current
    /// block breaks the monotone linear-order argument.
    fn checkBranchTargets(self: *Walker, instr: *const ir.Instruction, block_index: usize, label_to_index: *const std.AutoHashMapUnmanaged(ir.LabelId, usize)) void {
        const flagBackward = struct {
            fn isBackward(map: *const std.AutoHashMapUnmanaged(ir.LabelId, usize), current: usize, target: ir.LabelId) bool {
                const target_index = map.get(target) orelse return true; // unknown label — conservative
                return target_index <= current;
            }
        };
        switch (instr.*) {
            .branch => |x| {
                if (flagBackward.isBackward(label_to_index, block_index, x.target)) self.info.has_backward_branch = true;
            },
            .cond_branch => |x| {
                if (flagBackward.isBackward(label_to_index, block_index, x.then_target)) self.info.has_backward_branch = true;
                if (flagBackward.isBackward(label_to_index, block_index, x.else_target)) self.info.has_backward_branch = true;
            },
            .switch_tag => |x| {
                for (x.cases) |case| {
                    if (flagBackward.isBackward(label_to_index, block_index, case.target)) self.info.has_backward_branch = true;
                }
                if (flagBackward.isBackward(label_to_index, block_index, x.default)) self.info.has_backward_branch = true;
            },
            .jump => |x| {
                if (flagBackward.isBackward(label_to_index, block_index, x.target)) self.info.has_backward_branch = true;
            },
            else => {},
        }
    }

    fn recordReferences(self: *Walker, instr: *const ir.Instruction, position: u32) error{OutOfMemory}!void {
        switch (instr.*) {
            .call_direct => |x| try self.info.call_refs.append(self.allocator, .{
                .kind = .direct,
                .callee_id = x.function,
                .position = position,
            }),
            .call_named => |x| try self.info.call_refs.append(self.allocator, .{
                .kind = .named,
                .callee_name = x.name,
                .position = position,
            }),
            .tail_call => |x| try self.info.call_refs.append(self.allocator, .{
                .kind = .tail,
                .callee_name = x.name,
                .position = position,
            }),
            .try_call_named => |x| try self.info.call_refs.append(self.allocator, .{
                .kind = .disqualifying,
                .callee_name = x.name,
                .position = position,
            }),
            .call_dispatch => |x| try self.info.call_refs.append(self.allocator, .{
                .kind = .disqualifying,
                .callee_id = x.group_id,
                .position = position,
                .is_dispatch_group = true,
            }),
            .make_closure => |x| try self.info.closure_refs.append(self.allocator, .{
                .callee_id = x.function,
                .dest = x.dest,
                .has_captures = x.captures.len != 0,
            }),
            .call_builtin => |x| {
                if (isReceivePrimitiveName(x.name)) {
                    try self.info.receive_sites.append(self.allocator, .{
                        .ordinal = self.next_receive_ordinal,
                        .position = position,
                    });
                    self.next_receive_ordinal += 1;
                }
            },
            else => {},
        }
    }

    /// Fixed-order tree walk. Plain instructions record defs+uses at their
    /// own (pre) position. Stream-carrying instructions record their
    /// defs+uses at the POST-children position — their dest is written (and
    /// their operands merged) when the construct COMPLETES, so a merge
    /// value produced by a construct that CONTAINS a receive must not be
    /// treated as defined before it (that false interval would reject every
    /// `case`-wrapped server loop); recording uses late only widens
    /// last-use, which is the conservative direction.
    fn walkStream(self: *Walker, stream: []const ir.Instruction, block_index: usize, label_to_index: *const std.AutoHashMapUnmanaged(ir.LabelId, usize)) error{OutOfMemory}!void {
        for (stream) |*instr| {
            const pre_position = self.next_position;
            self.next_position += 1;

            self.checkBranchTargets(instr, block_index, label_to_index);
            try self.recordReferences(instr, pre_position);

            if (instructionHasChildStreams(instr)) {
                const WalkerCtx = struct {
                    walker: *Walker,
                    block_index: usize,
                    labels: *const std.AutoHashMapUnmanaged(ir.LabelId, usize),
                    err: ?error{OutOfMemory} = null,

                    fn visit(ctx: *@This(), child: ir.ChildStream) void {
                        if (ctx.err != null) return;
                        ctx.walker.walkStream(child.stream, ctx.block_index, ctx.labels) catch |err| {
                            ctx.err = err;
                        };
                    }
                };
                var child_ctx = WalkerCtx{ .walker = self, .block_index = block_index, .labels = label_to_index };
                ir.forEachChildStream(instr, &child_ctx, WalkerCtx.visit);
                if (child_ctx.err) |err| return err;

                const post_position = self.next_position;
                self.next_position += 1;
                self.recordInstructionDefs(instr, post_position);
                try self.recordInstructionUses(instr, post_position);
            } else {
                self.recordInstructionDefs(instr, pre_position);
                try self.recordInstructionUses(instr, pre_position);
            }
        }
    }
};

/// Whether an instruction carries child instruction streams (the
/// `forEachChildStream` carrier set).
fn instructionHasChildStreams(instr: *const ir.Instruction) bool {
    var found = false;
    const Probe = struct {
        fn visit(flag: *bool, child: ir.ChildStream) void {
            _ = child;
            flag.* = true;
        }
    };
    ir.forEachChildStream(instr, &found, Probe.visit);
    return found;
}

/// Analyze one function into a `LinearFunction`.
fn analyzeFunction(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    resolver: *NameResolver,
    function: *const ir.Function,
) error{OutOfMemory}!LinearFunction {
    var info = LinearFunction{
        .first_def = try allocator.alloc(u32, function.local_count),
        .last_use = try allocator.alloc(u32, function.local_count),
        .heap_possible = try allocator.alloc(bool, function.local_count),
    };
    errdefer info.deinit(allocator);
    @memset(info.first_def, NO_DEF);
    @memset(info.last_use, 0);
    @memset(info.heap_possible, false);

    var label_to_index: std.AutoHashMapUnmanaged(ir.LabelId, usize) = .empty;
    defer label_to_index.deinit(allocator);
    for (function.body, 0..) |block, index| {
        try label_to_index.put(allocator, block.label, index);
    }

    var walker = Walker{
        .allocator = allocator,
        .function = function,
        .program = program,
        .resolver = resolver,
        .info = &info,
    };
    for (function.body, 0..) |block, block_index| {
        try walker.walkStream(block.instructions, block_index, &label_to_index);
    }

    // Soundness catch-all: any local with a recorded USE but no attributed
    // DEF is treated as heap-possible and live from function entry — an
    // unknown IR shape must reject, never silently pass.
    for (info.first_def, 0..) |first_def, local| {
        if (first_def == NO_DEF and info.last_use[local] != 0) {
            info.first_def[local] = 0;
            info.heap_possible[local] = true;
        }
    }
    return info;
}

/// Condition 3: no heap-possible local's [first-def, last-use] interval
/// strictly contains `position`.
fn noHeapLiveAcross(info: *const LinearFunction, position: u32) bool {
    for (info.heap_possible, 0..) |heap, local| {
        if (!heap) continue;
        if (info.first_def[local] < position and position < info.last_use[local]) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Closure-use sanction analysis
// ---------------------------------------------------------------------------

/// Whether one instruction's use of `closure_local` is a sanctioned
/// spawn-entry / bookkeeping touch (module doc condition 1, first bullet).
fn closureUseSanctioned(instr: *const ir.Instruction, closure_local: ir.LocalId) bool {
    switch (instr.*) {
        .call_builtin => |call| {
            if (!isSpawnBuiltinName(call.name)) return false;
            if (call.args.len == 0 or call.args[0] != closure_local) return false;
            // The closure must be ONLY the entry argument.
            for (call.args[1..]) |argument| {
                if (argument == closure_local) return false;
            }
            return true;
        },
        .retain => |x| return x.value == closure_local,
        .release => |x| return x.value == closure_local,
        .dbg_var, .dbg_stmt => return true,
        else => return false,
    }
}

/// Whether `instr` is a pure alias move from `source_local`, returning the
/// alias dest. The IR builder routes call arguments through per-argument
/// `share_value`s (and pattern plumbing through `local_get`/`move_value`/…),
/// so the spawn-entry closure typically reaches the spawn builtin through a
/// short alias chain rather than as the `make_closure` dest directly.
fn aliasMoveDest(instr: *const ir.Instruction, source_local: ir.LocalId) ?ir.LocalId {
    return switch (instr.*) {
        .local_get => |x| if (x.source == source_local) x.dest else null,
        .move_value => |x| if (x.source == source_local) x.dest else null,
        .share_value => |x| if (x.source == source_local) x.dest else null,
        .copy_value => |x| if (x.source == source_local) x.dest else null,
        .borrow_value => |x| if (x.source == source_local) x.dest else null,
        .local_set => |x| if (x.value == source_local) x.dest else null,
        else => null,
    };
}

/// Scan a function's whole instruction tree and clear the `sanctioned` flag
/// of any tracked closure ref whose dest — or any transitive ALIAS of it —
/// has a non-sanctioned use. Alias dests are added to the tracked set as the
/// (definition-before-use ordered) scan encounters them, so a closure
/// reaching the spawn builtin through `share_value`/`local_get` plumbing is
/// still recognized, while any alias ESCAPING into an ordinary call, a
/// store, or a container is a disqualifying use exactly like the original.
fn resolveClosureSanctions(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    info: *LinearFunction,
) error{OutOfMemory}!void {
    if (info.closure_refs.items.len == 0) return;

    // Per-closure-ref alias set (index-aligned with `closure_refs`).
    const AliasSet = std.AutoHashMapUnmanaged(ir.LocalId, void);
    const alias_sets = try allocator.alloc(AliasSet, info.closure_refs.items.len);
    defer {
        for (alias_sets) |*set| set.deinit(allocator);
        allocator.free(alias_sets);
    }
    for (alias_sets, 0..) |*set, ref_index| {
        set.* = .empty;
        try set.put(allocator, info.closure_refs.items[ref_index].dest, {});
    }

    const Scanner = struct {
        allocator: std.mem.Allocator,
        info: *LinearFunction,
        alias_sets: []AliasSet,
        err: ?error{OutOfMemory} = null,

        fn scanStream(self: *@This(), stream: []const ir.Instruction) error{OutOfMemory}!void {
            for (stream) |*instr| {
                var uses = arc_liveness.UseList{};
                defer uses.deinit(self.allocator);
                try arc_liveness.collectUses(self.allocator, instr.*, &uses);
                for (uses.slice()) |used_local| {
                    for (self.info.closure_refs.items, 0..) |*closure_ref, ref_index| {
                        if (!self.alias_sets[ref_index].contains(used_local)) continue;
                        if (aliasMoveDest(instr, used_local)) |alias_dest| {
                            // A pure alias move: track the new name; the
                            // move itself is bookkeeping, not an escape.
                            try self.alias_sets[ref_index].put(self.allocator, alias_dest, {});
                            continue;
                        }
                        if (!closureUseSanctioned(instr, used_local)) closure_ref.sanctioned = false;
                    }
                }
                const Ctx = struct {
                    scanner: *@TypeOf(self.*),
                    fn visit(ctx: *@This(), child: ir.ChildStream) void {
                        if (ctx.scanner.err != null) return;
                        ctx.scanner.scanStream(child.stream) catch |err| {
                            ctx.scanner.err = err;
                        };
                    }
                };
                var ctx = Ctx{ .scanner = self };
                ir.forEachChildStream(instr, &ctx, Ctx.visit);
                if (self.err) |err| return err;
            }
        }
    };
    var scanner = Scanner{ .allocator = allocator, .info = info, .alias_sets = alias_sets };
    for (function.body) |block| {
        try scanner.scanStream(block.instructions);
    }
    // A capture-carrying closure is never a sanctioned entry reference.
    for (info.closure_refs.items) |*closure_ref| {
        if (closure_ref.has_captures) closure_ref.sanctioned = false;
    }
}

// ---------------------------------------------------------------------------
// The reset-context fixpoint + per-site proof + instrumentation
// ---------------------------------------------------------------------------

/// Shape eligibility (module doc condition 1, trailer).
fn functionShapeEligible(function: *const ir.Function, info: *const LinearFunction) bool {
    if (function.is_closure) return false;
    if (function.captures.len != 0) return false;
    if (info.has_backward_branch) return false;
    for (function.params) |param| {
        if (!zigTypeIsScalar(param.type_expr)) return false;
    }
    return true;
}

/// Run the pass over the whole program: prove receive sites and insert the
/// reset intrinsic before each proven one. Returns the number of
/// instrumented sites (0 leaves the program byte-identical — the fast path
/// for every program without receive primitives, including the entire
/// gate-OFF world).
pub fn instrumentProvenReceiveSites(
    allocator: std.mem.Allocator,
    program: *ir.Program,
) error{OutOfMemory}!u32 {
    // Fast pre-scan (the concurrency_verifier discipline): no receive
    // primitive anywhere → nothing to prove, nothing to touch.
    var any_receive = false;
    for (program.functions) |*function| {
        if (functionContainsReceivePrimitive(function)) {
            any_receive = true;
            break;
        }
    }
    if (!any_receive) return 0;

    const function_count = program.functions.len;

    var resolver = try NameResolver.init(allocator, program);
    defer resolver.deinit();

    const infos = try allocator.alloc(LinearFunction, function_count);
    var analyzed: usize = 0;
    defer {
        for (infos[0..analyzed]) |*info| info.deinit(allocator);
        allocator.free(infos);
    }
    for (program.functions, 0..) |*function, index| {
        infos[index] = try analyzeFunction(allocator, program, &resolver, function);
        analyzed = index + 1;
        try resolveClosureSanctions(allocator, function, &infos[index]);
    }

    const eligible = try allocator.alloc(bool, function_count);
    defer allocator.free(eligible);
    for (program.functions, 0..) |*function, index| {
        eligible[index] = functionShapeEligible(function, &infos[index]);
    }

    // Invert the reference graph ONCE through the resolver's hash buckets
    // (name-based references resolve to a SUPERSET of `nameDenotes` matches
    // — over-attribution only rejects more), so the fixpoint below touches
    // each candidate's own incoming list instead of rescanning the program.
    const IncomingCall = struct {
        referrer_index: u32,
        kind: CallRefKind,
        position: u32,
    };
    const IncomingClosure = struct {
        sanctioned: bool,
    };
    const incoming_calls = try allocator.alloc(std.ArrayListUnmanaged(IncomingCall), function_count);
    const incoming_closures = try allocator.alloc(std.ArrayListUnmanaged(IncomingClosure), function_count);
    defer {
        for (incoming_calls) |*list| list.deinit(allocator);
        allocator.free(incoming_calls);
        for (incoming_closures) |*list| list.deinit(allocator);
        allocator.free(incoming_closures);
    }
    @memset(incoming_calls, .empty);
    @memset(incoming_closures, .empty);

    for (infos, 0..) |*info, raw_referrer_index| {
        const referrer_index: u32 = @intCast(raw_referrer_index);
        for (info.closure_refs.items) |closure_ref| {
            if (resolver.id_to_index.get(closure_ref.callee_id)) |callee_index| {
                try incoming_closures[callee_index].append(allocator, .{ .sanctioned = closure_ref.sanctioned });
            }
        }
        for (info.call_refs.items) |call_ref| {
            switch (call_ref.kind) {
                .direct => {
                    if (resolver.id_to_index.get(call_ref.callee_id)) |callee_index| {
                        try incoming_calls[callee_index].append(allocator, .{
                            .referrer_index = referrer_index,
                            .kind = call_ref.kind,
                            .position = call_ref.position,
                        });
                    }
                },
                .named, .tail => {
                    for (try resolver.candidatesForName(call_ref.callee_name)) |callee_index| {
                        try incoming_calls[callee_index].append(allocator, .{
                            .referrer_index = referrer_index,
                            .kind = call_ref.kind,
                            .position = call_ref.position,
                        });
                    }
                },
                .disqualifying => {
                    const candidates = if (call_ref.is_dispatch_group)
                        try resolver.candidatesForGroup(call_ref.callee_id)
                    else
                        try resolver.candidatesForName(call_ref.callee_name);
                    for (candidates) |callee_index| {
                        try incoming_calls[callee_index].append(allocator, .{
                            .referrer_index = referrer_index,
                            .kind = .disqualifying,
                            .position = call_ref.position,
                        });
                    }
                },
            }
        }
    }

    // Incoming-reference sanction, per candidate F (module doc condition 1):
    //   * every non-closure reference to F must be a sanctioned kind whose
    //     owner is a reset context (or F itself for tail back-edges);
    //   * positive evidence must exist — a sanctioned spawn-closure
    //     reference (a process entry) or a sanctioned call from an
    //     established reset context (the entry→loop chain). A function with
    //     neither — including the program entry, dead code, and anything
    //     reached through non-IR linkage — never becomes a reset context.
    //     Self back-edges deliberately do not count as evidence.
    // Monotone fixpoint: contexts only ever get ADDED, and every sanction
    // check is against the current context set, so iteration to a fixed
    // point is sound and terminates (at most `function_count` rounds).
    const is_reset_context = try allocator.alloc(bool, function_count);
    defer allocator.free(is_reset_context);
    @memset(is_reset_context, false);

    var changed = true;
    while (changed) {
        changed = false;
        candidate: for (0..function_count) |candidate_index| {
            if (is_reset_context[candidate_index]) continue;
            if (!eligible[candidate_index]) continue;

            var has_spawn_reference = false;
            var has_reset_context_call_reference = false;
            for (incoming_closures[candidate_index].items) |closure_ref| {
                if (!closure_ref.sanctioned) continue :candidate;
                has_spawn_reference = true;
            }
            for (incoming_calls[candidate_index].items) |call_ref| {
                switch (call_ref.kind) {
                    .disqualifying => continue :candidate,
                    .tail => {
                        // The referrer's frame is replaced: sanctioned from
                        // the candidate itself (the self back-edge) or any
                        // established reset context.
                        if (call_ref.referrer_index != candidate_index and !is_reset_context[call_ref.referrer_index]) {
                            continue :candidate;
                        }
                        if (call_ref.referrer_index != candidate_index) has_reset_context_call_reference = true;
                    },
                    .direct, .named => {
                        // A live caller frame: must itself be a reset
                        // context AND hold no heap-possible local across
                        // this call site.
                        if (!is_reset_context[call_ref.referrer_index]) continue :candidate;
                        if (!noHeapLiveAcross(&infos[call_ref.referrer_index], call_ref.position)) continue :candidate;
                        has_reset_context_call_reference = true;
                    },
                }
            }
            if (!has_spawn_reference and !has_reset_context_call_reference) continue :candidate;
            is_reset_context[candidate_index] = true;
            changed = true;
        }
    }

    // Diagnostics (`ZAP_DEBUG_RECEIVE_RESET=1`): report, for every function
    // containing a receive primitive, its reset-context verdict and each
    // site's interval verdict — the observability the conservative gate
    // needs when a loop expected to reset does not.
    const debug_requested = std.c.getenv("ZAP_DEBUG_RECEIVE_RESET") != null;
    if (debug_requested) {
        for (program.functions, 0..) |*function, index| {
            const info = &infos[index];
            if (info.receive_sites.items.len == 0) continue;
            std.debug.print("[receive-reset] fn {s} (id={d}): eligible={} reset_context={} backward_branch={} sites={d}\n", .{
                function.name,
                function.id,
                eligible[index],
                is_reset_context[index],
                info.has_backward_branch,
                info.receive_sites.items.len,
            });
            for (info.receive_sites.items) |site| {
                std.debug.print("[receive-reset]   site ord={d} pos={d} heap_clean={}\n", .{ site.ordinal, site.position, noHeapLiveAcross(info, site.position) });
                if (!noHeapLiveAcross(info, site.position)) {
                    for (info.heap_possible, 0..) |heap, local| {
                        if (!heap) continue;
                        if (info.first_def[local] < site.position and site.position < info.last_use[local]) {
                            std.debug.print("[receive-reset]     live heap local {d}: def={d} last_use={d}\n", .{ local, info.first_def[local], info.last_use[local] });
                        }
                    }
                }
            }
            if (!is_reset_context[index]) {
                for (program.functions, 0..) |*referrer, referrer_index| {
                    for (infos[referrer_index].closure_refs.items) |closure_ref| {
                        if (closure_ref.callee_id == function.id) {
                            std.debug.print("[receive-reset]   closure ref from {s}: sanctioned={} captures={}\n", .{ referrer.name, closure_ref.sanctioned, closure_ref.has_captures });
                        }
                    }
                    for (infos[referrer_index].call_refs.items) |call_ref| {
                        if (callRefTargets(&call_ref, function)) {
                            std.debug.print("[receive-reset]   call ref kind={s} from {s} (rc={}) pos={d} clean={}\n", .{ @tagName(call_ref.kind), referrer.name, is_reset_context[referrer_index], call_ref.position, noHeapLiveAcross(&infos[referrer_index], call_ref.position) });
                        }
                    }
                }
            }
        }
    }

    // Per-site proof + instrumentation.
    var instrumented_total: u32 = 0;
    for (program.functions, 0..) |*function_pointer, index| {
        _ = function_pointer;
        if (!is_reset_context[index]) continue;
        const info = &infos[index];
        if (info.receive_sites.items.len == 0) continue;

        var proven_ordinals: std.ArrayListUnmanaged(u32) = .empty;
        defer proven_ordinals.deinit(allocator);
        for (info.receive_sites.items) |site| {
            if (noHeapLiveAcross(info, site.position)) {
                try proven_ordinals.append(allocator, site.ordinal);
            }
        }
        if (proven_ordinals.items.len == 0) continue;

        const mutable_function: *ir.Function = @constCast(&program.functions[index]);
        instrumented_total += try instrumentFunction(allocator, mutable_function, proven_ordinals.items);
    }
    return instrumented_total;
}

fn functionContainsReceivePrimitive(function: *const ir.Function) bool {
    var found = false;
    const Probe = struct {
        fn scanStream(flag: *bool, stream: []const ir.Instruction) void {
            for (stream) |*instr| {
                if (flag.*) return;
                if (instr.* == .call_builtin and isReceivePrimitiveName(instr.call_builtin.name)) {
                    flag.* = true;
                    return;
                }
                const Ctx = struct {
                    fn visit(inner_flag: *bool, child: ir.ChildStream) void {
                        scanStream(inner_flag, child.stream);
                    }
                };
                ir.forEachChildStream(instr, flag, Ctx.visit);
            }
        }
    };
    for (function.body) |block| {
        Probe.scanStream(&found, block.instructions);
        if (found) break;
    }
    return found;
}

fn callRefTargets(call_ref: *const CallRef, candidate: *const ir.Function) bool {
    switch (call_ref.kind) {
        .direct => return call_ref.callee_id == candidate.id,
        .named, .tail => return nameDenotes(call_ref.callee_name, candidate),
        .disqualifying => {
            if (call_ref.is_dispatch_group) {
                if (call_ref.callee_id == candidate.id) return true;
                if (candidate.source_group_id) |group| return call_ref.callee_id == group;
                return false;
            }
            return nameDenotes(call_ref.callee_name, candidate);
        },
    }
}

// ---------------------------------------------------------------------------
// Instrumentation (stream rebuild)
// ---------------------------------------------------------------------------

const Rebuilder = struct {
    allocator: std.mem.Allocator,
    function: *ir.Function,
    proven_ordinals: []const u32,
    next_receive_ordinal: u32 = 0,
    inserted: u32 = 0,

    fn ordinalIsProven(self: *const Rebuilder, ordinal: u32) bool {
        for (self.proven_ordinals) |proven| {
            if (proven == ordinal) return true;
        }
        return false;
    }

    /// Rebuild `stream`, inserting the reset intrinsic before each proven
    /// receive site. Receive ordinals are consumed in the SAME fixed
    /// traversal order as `Walker.walkStream` (instruction order, with a
    /// carrier's child streams visited between it and its successor), so
    /// analysis ordinals and rebuild ordinals agree by construction.
    fn rebuildStream(self: *Rebuilder, stream: []const ir.Instruction) error{OutOfMemory}![]const ir.Instruction {
        var out: std.ArrayListUnmanaged(ir.Instruction) = .empty;
        errdefer out.deinit(self.allocator);
        try out.ensureTotalCapacity(self.allocator, stream.len);

        for (stream) |*instr| {
            if (instr.* == .call_builtin and isReceivePrimitiveName(instr.call_builtin.name)) {
                const ordinal = self.next_receive_ordinal;
                self.next_receive_ordinal += 1;
                if (self.ordinalIsProven(ordinal)) {
                    const reset_dest = self.function.local_count;
                    self.function.local_count += 1;
                    try out.append(self.allocator, .{ .call_builtin = .{
                        .dest = reset_dest,
                        .name = RESET_PRIMITIVE_BUILTIN_NAME,
                        .args = &.{},
                        .arg_modes = &.{},
                        .result_type = .bool_type,
                    } });
                    self.inserted += 1;
                }
                try out.append(self.allocator, instr.*);
                continue;
            }

            try out.append(self.allocator, try self.rebuildInstruction(instr));
        }
        return try out.toOwnedSlice(self.allocator);
    }

    /// Rebuild one instruction, recursing into child streams (the
    /// `forEachChildStream` carrier set, mirrored case by case so the
    /// rebuilt instruction preserves every non-stream field).
    fn rebuildInstruction(self: *Rebuilder, instr: *const ir.Instruction) error{OutOfMemory}!ir.Instruction {
        switch (instr.*) {
            .if_expr => |x| {
                var rebuilt = x;
                rebuilt.then_instrs = try self.rebuildStream(x.then_instrs);
                rebuilt.else_instrs = try self.rebuildStream(x.else_instrs);
                return .{ .if_expr = rebuilt };
            },
            .case_block => |x| {
                var rebuilt = x;
                rebuilt.pre_instrs = try self.rebuildStream(x.pre_instrs);
                const arms = try self.allocator.alloc(ir.IrCaseArm, x.arms.len);
                for (x.arms, 0..) |arm, arm_index| {
                    arms[arm_index] = .{
                        .cond_instrs = try self.rebuildStream(arm.cond_instrs),
                        .condition = arm.condition,
                        .body_instrs = try self.rebuildStream(arm.body_instrs),
                        .result = arm.result,
                    };
                }
                rebuilt.arms = arms;
                rebuilt.default_instrs = try self.rebuildStream(x.default_instrs);
                return .{ .case_block = rebuilt };
            },
            .switch_literal => |x| {
                var rebuilt = x;
                const cases = try self.allocator.alloc(ir.LitCase, x.cases.len);
                for (x.cases, 0..) |case, case_index| {
                    cases[case_index] = .{
                        .value = case.value,
                        .body_instrs = try self.rebuildStream(case.body_instrs),
                        .result = case.result,
                    };
                }
                rebuilt.cases = cases;
                rebuilt.default_instrs = try self.rebuildStream(x.default_instrs);
                return .{ .switch_literal = rebuilt };
            },
            .switch_return => |x| {
                var rebuilt = x;
                const cases = try self.allocator.alloc(ir.ReturnCase, x.cases.len);
                for (x.cases, 0..) |case, case_index| {
                    cases[case_index] = .{
                        .value = case.value,
                        .body_instrs = try self.rebuildStream(case.body_instrs),
                        .return_value = case.return_value,
                    };
                }
                rebuilt.cases = cases;
                rebuilt.default_instrs = try self.rebuildStream(x.default_instrs);
                return .{ .switch_return = rebuilt };
            },
            .union_switch => |x| {
                var rebuilt = x;
                rebuilt.cases = try self.rebuildUnionCases(x.cases);
                rebuilt.else_instrs = try self.rebuildStream(x.else_instrs);
                return .{ .union_switch = rebuilt };
            },
            .union_switch_return => |x| {
                var rebuilt = x;
                rebuilt.cases = try self.rebuildUnionCases(x.cases);
                return .{ .union_switch_return = rebuilt };
            },
            .try_call_named => |x| {
                var rebuilt = x;
                rebuilt.handler_instrs = try self.rebuildStream(x.handler_instrs);
                rebuilt.success_instrs = try self.rebuildStream(x.success_instrs);
                return .{ .try_call_named = rebuilt };
            },
            .guard_block => |x| {
                var rebuilt = x;
                rebuilt.body = try self.rebuildStream(x.body);
                return .{ .guard_block = rebuilt };
            },
            .optional_dispatch => |x| {
                var rebuilt = x;
                rebuilt.nil_instrs = try self.rebuildStream(x.nil_instrs);
                rebuilt.struct_instrs = try self.rebuildStream(x.struct_instrs);
                return .{ .optional_dispatch = rebuilt };
            },
            else => return instr.*,
        }
    }

    fn rebuildUnionCases(self: *Rebuilder, cases: []const ir.UnionCase) error{OutOfMemory}![]const ir.UnionCase {
        const rebuilt = try self.allocator.alloc(ir.UnionCase, cases.len);
        for (cases, 0..) |case, case_index| {
            rebuilt[case_index] = .{
                .variant_name = case.variant_name,
                .field_bindings = case.field_bindings,
                .body_instrs = try self.rebuildStream(case.body_instrs),
                .return_value = case.return_value,
            };
        }
        return rebuilt;
    }
};

/// Insert the reset intrinsic before the proven receive ordinals of
/// `function`. Grows `local_count` (fresh dest locals for the inserted
/// calls) and extends `local_ownership` with matching `.trivial` entries so
/// the length invariant (`local_ownership.len == local_count`) holds for
/// every downstream consumer.
fn instrumentFunction(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    proven_ordinals: []const u32,
) error{OutOfMemory}!u32 {
    var rebuilder = Rebuilder{
        .allocator = allocator,
        .function = function,
        .proven_ordinals = proven_ordinals,
    };

    const new_blocks = try allocator.alloc(ir.Block, function.body.len);
    for (function.body, 0..) |block, block_index| {
        new_blocks[block_index] = .{
            .label = block.label,
            .instructions = try rebuilder.rebuildStream(block.instructions),
        };
    }
    function.body = new_blocks;

    if (rebuilder.inserted != 0 and function.local_ownership.len != 0) {
        const extended = try allocator.alloc(ir.OwnershipClass, function.local_count);
        @memcpy(extended[0..function.local_ownership.len], function.local_ownership);
        @memset(extended[function.local_ownership.len..], .trivial);
        function.local_ownership = extended;
    }
    return rebuilder.inserted;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a minimal `ir.Function` for hand-crafted proof tests (mirrors
/// `concurrency_verifier.buildTestFunction`). Caller provides an arena.
fn buildTestFunction(
    arena: std.mem.Allocator,
    id: ir.FunctionId,
    name: []const u8,
    arity: u32,
    params: []const ir.Param,
    instructions: []const ir.Instruction,
    local_count: u32,
) !ir.Function {
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, instructions),
    };
    const ownership = try arena.alloc(ir.OwnershipClass, local_count);
    @memset(ownership, .trivial);
    return ir.Function{
        .id = id,
        .name = name,
        .scope_id = 0,
        .arity = arity,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = local_count,
        .param_conventions = &.{},
        .local_ownership = ownership,
        .result_convention = .trivial,
    };
}

fn buildReceiveCall(arena: std.mem.Allocator, dest: ir.LocalId) !ir.Instruction {
    _ = arena;
    return .{ .call_builtin = .{
        .dest = dest,
        .name = "ProcessRuntime.receive_i64",
        .args = &.{},
        .arg_modes = &.{},
        .result_type = .i64,
    } };
}

fn buildSpawnerFunction(arena: std.mem.Allocator, id: ir.FunctionId, entry_id: ir.FunctionId) !ir.Function {
    const args = try arena.alloc(ir.LocalId, 2);
    args[0] = 0;
    args[1] = 1;
    const modes = try arena.alloc(ir.ValueMode, 2);
    @memset(modes, .share);
    const instructions = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = entry_id, .captures = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 1 } },
        .{ .call_builtin = .{ .dest = 2, .name = "ProcessRuntime.spawn_process_at", .args = args, .arg_modes = modes, .result_type = .u64 } },
        .{ .ret = .{ .value = null } },
    };
    return buildTestFunction(arena, id, "Spawner.run", 0, &.{}, &instructions, 3);
}

fn countResetCalls(function: *const ir.Function) u32 {
    var count: u32 = 0;
    const Probe = struct {
        fn scanStream(counter: *u32, stream: []const ir.Instruction) void {
            for (stream) |*instr| {
                if (instr.* == .call_builtin and
                    std.mem.eql(u8, instr.call_builtin.name, RESET_PRIMITIVE_BUILTIN_NAME))
                {
                    counter.* += 1;
                }
                const Ctx = struct {
                    fn visit(inner: *u32, child: ir.ChildStream) void {
                        scanStream(inner, child.stream);
                    }
                };
                ir.forEachChildStream(instr, counter, Ctx.visit);
            }
        }
    };
    for (function.body) |block| Probe.scanStream(&count, block.instructions);
    return count;
}

test "a spawn-only flat server loop with scalar state gets the reset, inserted before the receive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // server (id 10): receive an i64, double it (scalar work), tail-recurse.
    const server_instructions = [_]ir.Instruction{
        try buildReceiveCall(arena, 0),
        .{ .binary_op = .{ .dest = 1, .op = .add, .lhs = 0, .rhs = 0, .result_type = .i64 } },
        .{ .tail_call = .{ .name = "Server.loop", .args = &.{} } },
    };
    var functions = try arena.alloc(ir.Function, 2);
    functions[0] = try buildTestFunction(arena, 10, "Server.loop", 0, &.{}, &server_instructions, 2);
    functions[1] = try buildSpawnerFunction(arena, 11, 10);

    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };
    const inserted = try instrumentProvenReceiveSites(arena, &program);
    try testing.expectEqual(@as(u32, 1), inserted);
    try testing.expectEqual(@as(u32, 1), countResetCalls(&program.functions[0]));
    try testing.expectEqual(@as(u32, 0), countResetCalls(&program.functions[1]));

    // The reset is IMMEDIATELY BEFORE the receive.
    const stream = program.functions[0].body[0].instructions;
    try testing.expect(stream.len == 4);
    try testing.expectEqualStrings(RESET_PRIMITIVE_BUILTIN_NAME, stream[0].call_builtin.name);
    try testing.expectEqualStrings("ProcessRuntime.receive_i64", stream[1].call_builtin.name);
    // The fresh dest local extended the ownership table.
    try testing.expectEqual(program.functions[0].local_count, @as(u32, @intCast(program.functions[0].local_ownership.len)));
}

test "a heap-possible local live across the receive rejects the site" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A list is built BEFORE the receive and read AFTER it — the retained-
    // state shape the reset would use-after-free.
    const elements = try arena.alloc(ir.LocalId, 1);
    elements[0] = 0;
    const server_instructions = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 7 } },
        .{ .list_init = .{ .dest = 1, .elements = elements, .element_type = .i64 } },
        try buildReceiveCall(arena, 2),
        .{ .list_len_check = .{ .dest = 3, .scrutinee = 1, .expected_len = 0 } },
        .{ .tail_call = .{ .name = "Server.loop", .args = &.{} } },
    };
    var functions = try arena.alloc(ir.Function, 2);
    functions[0] = try buildTestFunction(arena, 10, "Server.loop", 0, &.{}, &server_instructions, 4);
    functions[1] = try buildSpawnerFunction(arena, 11, 10);

    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };
    const inserted = try instrumentProvenReceiveSites(arena, &program);
    try testing.expectEqual(@as(u32, 0), inserted);
    try testing.expectEqual(@as(u32, 0), countResetCalls(&program.functions[0]));
}

test "a heap-typed parameter (accumulating loop) rejects every site in the function" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const params = try arena.alloc(ir.Param, 1);
    const element_type = try arena.create(ir.ZigType);
    element_type.* = .i64;
    params[0] = .{ .name = "acc", .type_expr = .{ .list = element_type } };
    const server_instructions = [_]ir.Instruction{
        try buildReceiveCall(arena, 0),
        .{ .tail_call = .{ .name = "Server.acc_loop", .args = &.{} } },
    };
    var functions = try arena.alloc(ir.Function, 2);
    functions[0] = try buildTestFunction(arena, 10, "Server.acc_loop", 1, params, &server_instructions, 1);
    functions[1] = try buildSpawnerFunction(arena, 11, 10);

    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };
    const inserted = try instrumentProvenReceiveSites(arena, &program);
    try testing.expectEqual(@as(u32, 0), inserted);
}

test "a function without a sanctioned spawn reference is rejected even when internally clean" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const server_instructions = [_]ir.Instruction{
        try buildReceiveCall(arena, 0),
        .{ .tail_call = .{ .name = "Server.loop", .args = &.{} } },
    };
    var functions = try arena.alloc(ir.Function, 1);
    functions[0] = try buildTestFunction(arena, 10, "Server.loop", 0, &.{}, &server_instructions, 1);

    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };
    const inserted = try instrumentProvenReceiveSites(arena, &program);
    try testing.expectEqual(@as(u32, 0), inserted);
}

test "a normal (non-spawn) call to the loop from an unknown context rejects it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const server_instructions = [_]ir.Instruction{
        try buildReceiveCall(arena, 0),
        .{ .tail_call = .{ .name = "Server.loop", .args = &.{} } },
    };
    // A third function calls the loop directly — a live caller frame the
    // proof cannot vouch for (it is not itself a reset context).
    const caller_instructions = [_]ir.Instruction{
        .{ .call_named = .{ .dest = 0, .name = "Server.loop", .args = &.{}, .arg_modes = &.{} } },
        .{ .ret = .{ .value = null } },
    };
    var functions = try arena.alloc(ir.Function, 3);
    functions[0] = try buildTestFunction(arena, 10, "Server.loop", 0, &.{}, &server_instructions, 1);
    functions[1] = try buildSpawnerFunction(arena, 11, 10);
    functions[2] = try buildTestFunction(arena, 12, "Other.caller", 0, &.{}, &caller_instructions, 1);

    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };
    const inserted = try instrumentProvenReceiveSites(arena, &program);
    try testing.expectEqual(@as(u32, 0), inserted);
}

test "the entry→loop chain proves when the entry is spawn-only and the call site is heap-clean" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // entry (id 12, spawn-only) calls loop (id 10) with nothing heap live
    // across the call; loop self-tail-recurses around a receive.
    const entry_instructions = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 1 } },
        .{ .call_named = .{ .dest = 1, .name = "Server.loop", .args = &.{}, .arg_modes = &.{} } },
        .{ .ret = .{ .value = null } },
    };
    const server_instructions = [_]ir.Instruction{
        try buildReceiveCall(arena, 0),
        .{ .tail_call = .{ .name = "Server.loop", .args = &.{} } },
    };
    var functions = try arena.alloc(ir.Function, 3);
    functions[0] = try buildTestFunction(arena, 10, "Server.loop", 0, &.{}, &server_instructions, 1);
    functions[1] = try buildTestFunction(arena, 12, "Server.entry", 0, &.{}, &entry_instructions, 2);
    functions[2] = try buildSpawnerFunction(arena, 11, 12);

    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };
    const inserted = try instrumentProvenReceiveSites(arena, &program);
    try testing.expectEqual(@as(u32, 1), inserted);
    try testing.expectEqual(@as(u32, 1), countResetCalls(&program.functions[0]));
}

test "the proof is per receive site: one function's clean site resets while its dirty site does not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Site 1 (clean), then a list is created and held across site 2 (dirty),
    // then read, then the back-edge.
    const elements = try arena.alloc(ir.LocalId, 1);
    elements[0] = 1;
    const server_instructions = [_]ir.Instruction{
        try buildReceiveCall(arena, 0), // site ordinal 0 — clean
        .{ .const_int = .{ .dest = 1, .value = 3 } },
        .{ .list_init = .{ .dest = 2, .elements = elements, .element_type = .i64 } },
        try buildReceiveCall(arena, 3), // site ordinal 1 — list live across
        .{ .list_len_check = .{ .dest = 4, .scrutinee = 2, .expected_len = 0 } },
        .{ .tail_call = .{ .name = "Server.loop", .args = &.{} } },
    };
    var functions = try arena.alloc(ir.Function, 2);
    functions[0] = try buildTestFunction(arena, 10, "Server.loop", 0, &.{}, &server_instructions, 5);
    functions[1] = try buildSpawnerFunction(arena, 11, 10);

    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };
    const inserted = try instrumentProvenReceiveSites(arena, &program);
    try testing.expectEqual(@as(u32, 1), inserted);
    const stream = program.functions[0].body[0].instructions;
    // reset, receive(clean), const, list, receive(dirty — NO reset), check, tail.
    try testing.expectEqualStrings(RESET_PRIMITIVE_BUILTIN_NAME, stream[0].call_builtin.name);
    try testing.expectEqualStrings("ProcessRuntime.receive_i64", stream[1].call_builtin.name);
    try testing.expect(stream[4].call_builtin.name.ptr != RESET_PRIMITIVE_BUILTIN_NAME.ptr);
    try testing.expectEqual(@as(u32, 1), countResetCalls(&program.functions[0]));
}

test "a receive inside a case arm of a spawn-only loop is proven and instrumented in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The adder_loop shape: case over a scalar, receive inside one arm.
    const arm_body = [_]ir.Instruction{
        try buildReceiveCall(arena, 2),
        .{ .tail_call = .{ .name = "Server.loop", .args = &.{} } },
    };
    const arms = try arena.alloc(ir.IrCaseArm, 1);
    arms[0] = .{
        .cond_instrs = &.{},
        .condition = 1,
        .body_instrs = try arena.dupe(ir.Instruction, &arm_body),
        .result = null,
    };
    const server_instructions = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0 } },
        .{ .binary_op = .{ .dest = 1, .op = .eq, .lhs = 0, .rhs = 0, .result_type = .bool_type } },
        .{ .case_block = .{ .dest = 3, .pre_instrs = &.{}, .arms = arms, .default_instrs = &.{}, .default_result = null } },
        .{ .ret = .{ .value = null } },
    };
    var functions = try arena.alloc(ir.Function, 2);
    functions[0] = try buildTestFunction(arena, 10, "Server.loop", 0, &.{}, &server_instructions, 4);
    functions[1] = try buildSpawnerFunction(arena, 11, 10);

    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };
    const inserted = try instrumentProvenReceiveSites(arena, &program);
    try testing.expectEqual(@as(u32, 1), inserted);
    // The reset landed INSIDE the arm, right before the receive.
    const rebuilt_arm = program.functions[0].body[0].instructions[2].case_block.arms[0];
    try testing.expectEqualStrings(RESET_PRIMITIVE_BUILTIN_NAME, rebuilt_arm.body_instrs[0].call_builtin.name);
    try testing.expectEqualStrings("ProcessRuntime.receive_i64", rebuilt_arm.body_instrs[1].call_builtin.name);
}

test "a closure reaching the spawn builtin through a share_value alias is still sanctioned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const server_instructions = [_]ir.Instruction{
        try buildReceiveCall(arena, 0),
        .{ .tail_call = .{ .name = "Server.loop", .args = &.{} } },
    };
    // The real IR shape: the builder wraps the spawn's closure argument in a
    // per-argument `share_value` before the builtin call.
    const args = try arena.alloc(ir.LocalId, 2);
    args[0] = 1; // the ALIAS, not the make_closure dest
    args[1] = 2;
    const modes = try arena.alloc(ir.ValueMode, 2);
    @memset(modes, .share);
    const spawner_instructions = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 10, .captures = &.{} } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 1 } },
        .{ .call_builtin = .{ .dest = 3, .name = "ProcessRuntime.spawn_process_at", .args = args, .arg_modes = modes, .result_type = .u64 } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    };
    var functions = try arena.alloc(ir.Function, 2);
    functions[0] = try buildTestFunction(arena, 10, "Server.loop", 0, &.{}, &server_instructions, 1);
    functions[1] = try buildTestFunction(arena, 11, "Spawner.run", 0, &.{}, &spawner_instructions, 4);

    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };
    const inserted = try instrumentProvenReceiveSites(arena, &program);
    try testing.expectEqual(@as(u32, 1), inserted);
}

test "a closure entry passed as an ordinary call argument is not a sanctioned spawn reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const server_instructions = [_]ir.Instruction{
        try buildReceiveCall(arena, 0),
        .{ .tail_call = .{ .name = "Server.loop", .args = &.{} } },
    };
    // The closure flows into a NON-spawn call (the plain `Process.spawn(&f/0)`
    // library-function shape, deferral (i)) — conservatively rejected.
    const args = try arena.alloc(ir.LocalId, 1);
    args[0] = 0;
    const modes = try arena.alloc(ir.ValueMode, 1);
    @memset(modes, .share);
    const spawner_instructions = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 10, .captures = &.{} } },
        .{ .call_named = .{ .dest = 1, .name = "Process.spawn", .args = args, .arg_modes = modes } },
        .{ .ret = .{ .value = null } },
    };
    var functions = try arena.alloc(ir.Function, 2);
    functions[0] = try buildTestFunction(arena, 10, "Server.loop", 0, &.{}, &server_instructions, 1);
    functions[1] = try buildTestFunction(arena, 11, "Spawner.run", 0, &.{}, &spawner_instructions, 2);

    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };
    const inserted = try instrumentProvenReceiveSites(arena, &program);
    try testing.expectEqual(@as(u32, 0), inserted);
}

test "a program without receive primitives is untouched (the gate-OFF fast path)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const instructions = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 42 } },
        .{ .ret = .{ .value = 0 } },
    };
    var functions = try arena.alloc(ir.Function, 1);
    functions[0] = try buildTestFunction(arena, 1, "Plain.main", 0, &.{}, &instructions, 1);
    const original_body_pointer = functions[0].body.ptr;

    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };
    const inserted = try instrumentProvenReceiveSites(arena, &program);
    try testing.expectEqual(@as(u32, 0), inserted);
    // Not even the block slices were rebuilt.
    try testing.expectEqual(original_body_pointer, program.functions[0].body.ptr);
}
