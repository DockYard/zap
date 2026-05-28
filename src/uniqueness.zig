const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");
const uniqueness_interprocedural = @import("uniqueness_interprocedural.zig");
const uniqueness_signature = @import("uniqueness_signature.zig");

// ============================================================
// uniqueness — static-uniqueness analysis (Phase 3 of the dense-map plan).
//
// Pipeline placement (per docs/dense-map-implementation-plan.md §1.5):
//
//     ... → arc_liveness                    (last-use side table)
//          → arc_param_convention           (.borrowed → .owned promotion)
//             → arc_ownership.rewriteOwnedConsumeBuiltinSites  (Phase 4)
//                → arc_ownership.classifyAndNormalize          (borrow/copy)
//                   → arc_ownership.rewriteOwnedConsumeSites   (Phase E.9.2)
//                      → uniqueness  (THIS PASS — produces "uniqueness"
//                                       side table for codegen + verifier)
//                         → arc_verifier  (V1–uniqueness)
//                            → arc_drop_insertion
//                               → ...
//
// Why uniqueness exists:
//
// Phase 4 (commit 0b41035) made the rc-1 fast path fire on every
// owned-mutating call to `Map.put`/`.delete`/`.merge` and
// `List.set`/`.push`/`.pop`/`.append` whose receiver is at last
// use. The fast path mutates the buffer in place and avoids the
// deep-retain clone that the shared (rc>1) path requires. But the
// runtime still pays a per-call cost: every `Map.put` enters the
// Zig runtime, atomically loads `header.ref_count` (.acquire), tests
// `count() == 1`, and branches. On 2-billion-call write-saturated
// workloads (fannkuch-redux Phase 6 port), the load+compare+branch
// adds ~32% to wall time.
//
// uniqueness closes that gap by proving — at the IR level — that a given
// owned-mutating call site receives a refcount-1 cell. When uniqueness
// holds, the codegen can emit a runtime variant that mutates in
// place WITHOUT loading the refcount: `Map.put_owned_unchecked`,
// `List.set_owned_unchecked`, etc. These are zero-branch, in-place
// mutations.
//
// Soundness:
//
// uniqueness is a refinement of Phase 4's last-use predicate. Every uniqueness call
// site is also a last-use site (the receiver is dead after the call,
// so the move_value fired); the converse does not hold (last use
// alone does not prove the cell never had its refcount bumped before
// the call).
//
// Concretely, uniqueness proves `definitely_unique` along a forward dataflow:
//
//   * A local L is `unique` immediately after:
//     - A fresh allocation that returns rc=1 (Map.new, List.new_*,
//       any owned-mutating call's result, ...).
//     - A `move_value` from a `unique` source.
//
//   * A local L is `not unique` after any of:
//     - `share_value` (the source's refcount transiently went to 2;
//       even after a paired release the source's owns count returns
//       to 1, but the analysis observes the transient share at the
//       call site, where the receiver might still be aliased).
//     - `copy_value` (the runtime emits an explicit retain; both
//       source and dest refer to the same cell with refcount >= 2).
//     - Storage in any aggregate (`list_cons`, `map_init`,
//       `tuple_init`, `struct_init`, `union_init`, `list_init`).
//       The aggregate now holds a strong reference to L's cell,
//       so any later mutation through L is on a shared cell.
//     - Function parameter (`param_get`): the caller's refcount is
//       opaque to the callee; conservatively NOT unique.
//
// The analysis runs forward through every instruction stream
// (top-level body and nested arms), maintaining a per-LocalId
// `definitely_unique` bitset. At each owned-mutating call site, we
// snapshot whether the receiver slot is unique. The result is a
// per-call-site predicate keyed by the call's InstructionId.
//
// Two-edge call chain:
//
// User code calls `Map.put` (a Zap fn in `lib/map.zap`) which
// forwards to `:zig.Map.put` (a `call_builtin` to the runtime).
// uniqueness must hold at the user's call site OR at the wrapper's
// call_builtin to enable the unchecked variant. Since the analysis
// is per-function, we report uniqueness at every owned-mutating
// call site (regardless of whether it's `call_named` or
// `call_builtin`); the codegen layer that consumes uniqueness picks the
// site at which to emit the `_owned_unchecked` form.
//
// Conservative defaults: when in doubt, uniqueness is FALSE. A wrong TRUE
// would produce undefined behavior in the unchecked runtime variant
// (mutate a shared cell). A wrong FALSE costs only the runtime check
// (the existing Phase 4 path).
//
// ============================================================

/// Per-call-site per-arg uniqueness witness. Recorded only for call
/// sites whose callee resolves to a known program function (i.e.,
/// `call_named` / `call_direct` / `try_call_named` / `tail_call` whose
/// name maps to a `FunctionId`). Used by the interprocedural fixpoint
/// to demote callee slots whose caller passed a non-unique argument.
///
/// `target` is the resolved callee FunctionId. `per_arg` is `true` for
/// each arg index whose value was provably unique at the call site
/// (snapshot of `unique` BEFORE the call's own effect runs).
pub const ArgUniqueness = struct {
    target: ir.FunctionId,
    per_arg: []bool,
};

/// Output of `analyzeUniqueness`. Maps owned-mutating call sites to
/// whether the receiver is provably uniquely owned at the call.
///
/// Keyed by the `InstructionId` of the owned-mutating call (the
/// `call_builtin`, `call_named`, `call_direct`, or `try_call_named`
/// instruction itself). The InstructionId mirrors the depth-first
/// traversal order used by `arc_liveness.assignInstructionIds`, so
/// the verifier and codegen can resolve their site queries by the
/// same id space the rest of the ARC pipeline uses.
///
/// Absence from the map means "not an owned-mutating call site" or
/// "could not be analysed" — both are equivalent to uniqueness = false (the
/// verifier rejects unchecked variants whose call site is absent;
/// the codegen falls back to the checked variant).
pub const Uniqueness = struct {
    /// Per-call-site uniqueness predicate. `true` means the receiver
    /// is provably unique at the call; `false` (or absence) means the
    /// caller cannot prove uniqueness and the checked runtime variant
    /// must fire.
    sites: std.AutoHashMapUnmanaged(arc_liveness.InstructionId, bool) = .empty,

    /// Per-call-site per-arg uniqueness, recorded only when the
    /// dataflow is run with `record_arg_sites = true`. Used by the
    /// interprocedural fixpoint (`uniqueness_interprocedural.analyzeProgram`)
    /// to drive per-callee parameter demotion. Empty (and unused) for
    /// the per-function rewrite pass.
    arg_sites: std.AutoHashMapUnmanaged(arc_liveness.InstructionId, ArgUniqueness) = .empty,

    pub fn deinit(self: *Uniqueness, allocator: std.mem.Allocator) void {
        self.sites.deinit(allocator);
        var iter = self.arg_sites.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.value_ptr.per_arg);
        }
        self.arg_sites.deinit(allocator);
    }

    /// Look up the predicate for a specific owned-mutating call site.
    /// Returns `false` for sites that are absent from the map (the
    /// safe default — the call site was not classified as unique).
    pub fn isUnique(self: *const Uniqueness, instr_id: arc_liveness.InstructionId) bool {
        return self.sites.get(instr_id) orelse false;
    }
};

/// Run the uniqueness forward dataflow on `function` and produce a per-
/// owned-mutating-call uniqueness predicate.
///
/// `program` is consulted only to resolve the callee's
/// `param_conventions` for `call_named`/`call_direct` sites: when the
/// receiver slot's convention is `.owned`, the call consumes the
/// receiver's `+1` and the result is fresh-rc=1, so the result is
/// unique by construction. Without a program reference (e.g. test
/// scaffolding), the analysis still classifies fresh-allocation and
/// `call_builtin` results conservatively.
///
/// The pass does NOT mutate the IR. It only produces the side table.
pub fn analyzeUniqueness(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: ?*const ir.Program,
) !Uniqueness {
    return analyzeUniquenessFull(allocator, function, program, null, null, null);
}

/// Variant of `analyzeUniqueness` that consults a whole-program
/// uniqueness fixpoint when classifying `param_get` instructions.
/// When `fixpoint` is non-null and reports the parameter slot as
/// proven unique-on-entry, the dest of the `param_get` is treated as
/// `definitely_unique`. Otherwise the conservative default applies.
///
/// This is the integration seam for the interprocedural uniqueness fixpoint
/// (see `uniqueness_interprocedural.zig`). The compiler driver runs the
/// fixpoint once per program, then calls this variant for every
/// function so each per-function analysis sees the proven entry
/// uniqueness.
pub fn analyzeUniquenessWithFixpoint(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: ?*const ir.Program,
    fixpoint: ?*const uniqueness_interprocedural.ProgramUniqueness,
) !Uniqueness {
    return analyzeUniquenessFull(allocator, function, program, fixpoint, null, null);
}

/// Phase 2.5 — full uniqueness dataflow with the complete set of optional
/// inputs. Threads the whole-program fixpoint, the uniqueness_signature
/// `ProgramSignatures` table, and the per-function `ArcOwnership`
/// table into the dataflow.
///
/// `signatures` (when non-null) lets the dataflow synthesize per-
/// component uniqueness for the dest of a call whose callee returns a
/// tuple with PU/AL component witnesses. Combined with `ownership`'s
/// last-use queries, this propagates per-component uniqueness through
/// the destructure-then-tail-call pattern used by fannkuch's
/// `count_flips`/`advance_perm`/`rotate_loop` helpers.
///
/// `ownership` (when non-null) lets the dataflow recognise the
/// `index_get(t, i) + retain` destructure idiom as a uniqueness-
/// preserving move when the parent tuple `t` is at last-use during
/// the destructure sequence. Without `ownership`, extracted locals
/// remain conservatively non-unique even when they descend from a
/// tuple_pending tuple.
///
/// All three optional inputs default to "no extra information"; the
/// pass falls back to the legacy intraprocedural behaviour when each
/// is null.
pub fn analyzeUniquenessFull(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: ?*const ir.Program,
    fixpoint: ?*const uniqueness_interprocedural.ProgramUniqueness,
    signatures: ?*const uniqueness_signature.ProgramSignatures,
    ownership: ?*const arc_liveness.ArcOwnership,
) !Uniqueness {
    return analyzeUniquenessFullEx(allocator, function, program, fixpoint, signatures, ownership, false);
}

/// Extended variant of `analyzeUniquenessFull` that additionally lets the
/// caller request per-call-site per-arg uniqueness recording in the
/// returned `Uniqueness.arg_sites` map.
///
/// `record_arg_sites = true` is used exclusively by the interprocedural
/// fixpoint (`uniqueness_interprocedural.analyzeProgram`) which needs
/// per-arg uniqueness at every resolvable call site to drive per-callee
/// parameter demotion. The per-function rewrite pass (codegen / verifier)
/// passes `false` and pays no overhead.
pub fn analyzeUniquenessFullEx(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: ?*const ir.Program,
    fixpoint: ?*const uniqueness_interprocedural.ProgramUniqueness,
    signatures: ?*const uniqueness_signature.ProgramSignatures,
    ownership: ?*const arc_liveness.ArcOwnership,
    record_arg_sites: bool,
) !Uniqueness {
    var analyzer = Analyzer{
        .allocator = allocator,
        .function = function,
        .program = program,
        .fixpoint = fixpoint,
        .signatures = signatures,
        .ownership = ownership,
        .record_arg_sites = record_arg_sites,
        .unique = .empty,
        .tuple_pending = .empty,
        .extracted = .empty,
        .next_id = 0,
        .result = .{},
    };
    defer {
        analyzer.unique.deinit(allocator);
        analyzer.deinitTuplePending();
        analyzer.deinitExtracted();
    }

    errdefer analyzer.result.deinit(allocator);

    for (function.body) |block| {
        try analyzer.walkStream(block.instructions);
    }

    return analyzer.result;
}

/// Phase 2.5 — per-tuple deferred classification record. One entry
/// per `tuple_init` (or call dest synthesized from a callee's
/// `return_components`) whose components carry per-slot uniqueness
/// information.
///
/// `components_unique[i]` is `true` iff component `i` was definitely-
/// unique at construction time (the source local was in the
/// `unique` set when `tuple_init` ran, or the synthesized callee
/// witness identified an arg that was unique at the call site).
///
/// `extracted` records every `(local, component_index)` pair extracted
/// from this tuple via `index_get` BEFORE the tuple's last-use. When
/// the tuple's last-use fires, every recorded extracted local
/// inherits its component's uniqueness — modelling the
/// `index_get + retain` destructure idiom whose paired retain (on the
/// extracted local) and implicit release-on-scope-exit (of the parent
/// tuple) cancel, leaving the extracted local as the sole owner.
const TuplePendingEntry = struct {
    components_unique: []bool,
    extracted: std.ArrayListUnmanaged(ExtractedRef),
    /// True once a sink/escape has dissolved this entry. Subsequent
    /// extractions or last-use events are no-ops.
    escaped: bool = false,
};

const ExtractedRef = struct {
    local: ir.LocalId,
    component_idx: usize,
};

/// Phase 2.5 — reverse mapping for extracted locals. When an
/// `index_get(t, i)` adds an entry to `tuple_pending[t].extracted`,
/// it ALSO adds an entry here: `extracted[L] = (source_tuple = t,
/// component_idx = i)`. This lets later sinks (e.g. `share_value` on
/// L, storage of L in another aggregate) trace back to t and dissolve
/// t's pending entry as appropriate.
const ExtractedSource = struct {
    source_tuple: ir.LocalId,
    component_idx: usize,
};

const Analyzer = struct {
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: ?*const ir.Program,
    /// Optional whole-program uniqueness fixpoint. When non-null, the
    /// `param_get` handler consults this for the function's parameter
    /// slots: a slot proven unique-on-entry by the fixpoint causes
    /// the `param_get`'s dest to be marked `definitely_unique` so
    /// downstream owned-mutating calls fed by an alias of that slot
    /// observe the parameter's proven uniqueness.
    fixpoint: ?*const uniqueness_interprocedural.ProgramUniqueness,
    /// Optional whole-program uniqueness signatures (Phase 2.1). When
    /// non-null, the dataflow synthesizes a `tuple_pending` entry on
    /// the dest of any call whose callee's `return_components` table
    /// records a per-component witness. Each component is classified
    /// as unique iff the witness arg was unique at the call site.
    signatures: ?*const uniqueness_signature.ProgramSignatures,
    /// Optional per-function ARC ownership (last-use side table).
    /// When non-null, the dataflow uses `isLastUseAt` to decide
    /// whether an `index_get + retain` destructure can promote the
    /// extracted local's uniqueness from its parent tuple's pending
    /// entry. The promotion fires at the parent tuple's last-use
    /// instruction (typically the LAST `index_get` of the destructure
    /// sequence — at that point the tuple has no further uses, so
    /// every previously extracted local takes over the +1 the
    /// implicit scope-exit release would otherwise reclaim from the
    /// tuple).
    ownership: ?*const arc_liveness.ArcOwnership,
    /// When true, every call site whose callee resolves to a program
    /// function records a per-arg uniqueness snapshot in
    /// `result.arg_sites`. This is the input the interprocedural
    /// fixpoint consumes to demote callee parameter slots whose
    /// arguments are not unique at one of their call sites.
    ///
    /// The per-function rewrite pass (codegen / verifier) sets this
    /// to false; only the interprocedural fixpoint enables it.
    record_arg_sites: bool,
    /// Set of LocalIds proven `definitely_unique` at the current
    /// program point. Updated by `applyEffect` as the walker visits
    /// each instruction in depth-first order.
    unique: std.AutoHashMapUnmanaged(ir.LocalId, void),
    /// Phase 2.5 — per-tuple deferred classification map. Keyed by
    /// the tuple's dest LocalId; the value records per-component
    /// uniqueness flags and the list of locals extracted via
    /// `index_get` from this tuple.
    tuple_pending: std.AutoHashMapUnmanaged(ir.LocalId, TuplePendingEntry),
    /// Phase 2.5 — reverse map: extracted LocalId → its source tuple
    /// and component index. Used by sinks to find the parent tuple
    /// when an extracted local escapes (e.g., gets stored in another
    /// aggregate) before its parent tuple's last-use fires.
    extracted: std.AutoHashMapUnmanaged(ir.LocalId, ExtractedSource),
    /// Running InstructionId, mirrored from the depth-first traversal
    /// order used by `arc_liveness.assignInstructionIds`. Both walks
    /// must agree on id assignment so the verifier and codegen can
    /// cross-reference their per-instruction queries.
    next_id: arc_liveness.InstructionId,
    /// Output table — populated during the walk.
    result: Uniqueness,

    fn deinitTuplePending(self: *Analyzer) void {
        var iter = self.tuple_pending.valueIterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.components_unique);
            entry.extracted.deinit(self.allocator);
        }
        self.tuple_pending.deinit(self.allocator);
    }

    fn deinitExtracted(self: *Analyzer) void {
        self.extracted.deinit(self.allocator);
    }

    /// Phase 2.5 — drop a pending entry (free its slice and list).
    fn removePending(self: *Analyzer, tuple_local: ir.LocalId) void {
        if (self.tuple_pending.fetchRemove(tuple_local)) |kv| {
            self.allocator.free(kv.value.components_unique);
            var entry = kv.value;
            entry.extracted.deinit(self.allocator);
        }
    }

    /// Phase 2.5 — mark a tuple_pending entry as escaped. All
    /// extracted refs lose their backlink (so a later last-use of the
    /// tuple cannot promote them), and the entry is removed.
    fn escapePending(self: *Analyzer, tuple_local: ir.LocalId) void {
        if (self.tuple_pending.getPtr(tuple_local)) |entry| {
            // Drop reverse-mapping entries for all extracted locals so
            // their later use doesn't suggest a still-pending source.
            for (entry.extracted.items) |ref| {
                _ = self.extracted.remove(ref.local);
            }
            // Remove (frees the slice + list).
            self.removePending(tuple_local);
        }
    }

    /// Phase 2.5 — when an extracted local is consumed by a sink (e.g.
    /// stored in another aggregate, captured into a closure, passed
    /// to a non-PU call), the parent tuple's pending entry is
    /// invalidated for promotion: an alias to the same cell now
    /// exists outside the destructure scope, so the implicit scope-
    /// exit release of the parent tuple won't restore uniqueness.
    /// Drop the parent's pending entry and the reverse-mapping for
    /// every extracted local under it.
    fn escapeIfExtractedLocal(self: *Analyzer, local: ir.LocalId) void {
        const src = self.extracted.get(local) orelse return;
        self.escapePending(src.source_tuple);
    }

    /// Phase 2.5 — when a tuple_pending tuple's last-use fires (i.e.
    /// the IR has no further references to the tuple), every
    /// extracted local takes over the parent's component uniqueness.
    /// The runtime contract that justifies this:
    ///
    ///   1. At `tuple_init`, components with `components_unique[i] ==
    ///      true` had refcount-1 cells.
    ///   2. After `tuple_init`, the tuple holds a +1 to each
    ///      component's cell. The original element local is dead;
    ///      the cell is still rc=1 (now owned through the tuple).
    ///   3. `index_get(t, i)` lowers to `elem_val_imm` (a borrow);
    ///      the paired `retain` after each ARC-managed extraction
    ///      bumps the cell to rc=2.
    ///   4. The parent tuple's scope-exit release decrements every
    ///      component cell back to rc=1 — the extracted local is now
    ///      the sole owner.
    ///   5. Since the tuple is at last-use AT the destructure
    ///      sequence's terminal instruction, the implicit release
    ///      will fire shortly. Subsequent uniqueness sites observe rc=1
    ///      cells, so the extracted local is unique.
    ///
    /// Without a per-function `ArcOwnership`, the dataflow can't
    /// query last-use; this function is a no-op in that case.
    fn promoteExtractedAt(
        self: *Analyzer,
        tuple_local: ir.LocalId,
        my_id: arc_liveness.InstructionId,
    ) error{OutOfMemory}!void {
        const ownership = self.ownership orelse return;
        const entry = self.tuple_pending.getPtr(tuple_local) orelse return;
        if (entry.escaped) return;
        if (!ownership.isLastUseAt(tuple_local, my_id)) return;
        for (entry.extracted.items) |ref| {
            if (ref.component_idx < entry.components_unique.len and entry.components_unique[ref.component_idx]) {
                try self.unique.put(self.allocator, ref.local, {});
            }
            _ = self.extracted.remove(ref.local);
        }
        self.removePending(tuple_local);
    }

    /// Phase 2.5 — propagate a `tuple_pending` membership through an
    /// alias-form instruction. When `source` is a tuple_pending dest,
    /// the alias's `dest` becomes a new tuple_pending entry pointing
    /// at the same component table. Pure aliasing does not change
    /// component uniqueness or resolve the deferred entry — only true
    /// sinks (last-use, escape) do.
    ///
    /// We MOVE ownership of the slice + list from `source` to `dest`:
    /// the source key is removed and the data is re-keyed under
    /// `dest`. The reverse-mapping `extracted` entries also rewire to
    /// point at `dest` (so a later sink on an extracted local resolves
    /// to the new key).
    fn propagateTuplePending(self: *Analyzer, dest: ir.LocalId, source: ir.LocalId) error{OutOfMemory}!void {
        if (dest == source) return;
        const kv = self.tuple_pending.fetchRemove(source) orelse return;
        // Remove any prior pending at dest first.
        self.removePending(dest);
        try self.tuple_pending.put(self.allocator, dest, kv.value);
        // Update reverse-mapping for every extracted local.
        for (kv.value.extracted.items) |ref| {
            try self.extracted.put(self.allocator, ref.local, .{
                .source_tuple = dest,
                .component_idx = ref.component_idx,
            });
        }
    }

    /// Phase 2.5 — `borrow_value` does NOT consume its source: the
    /// source can have further uses after the borrow. Both source
    /// and the borrow's dest see the same underlying tuple. We
    /// therefore COPY the pending entry's component flags into a
    /// fresh entry under `dest`, preserving the source entry. The
    /// dest's entry has its own (initially empty) `extracted` list;
    /// extractions through the borrow append to the dest's list, and
    /// the parent (the borrow) can be promoted at the borrow's
    /// last-use independently of the source. Note this is more
    /// permissive than the source's promotion alone, but soundness
    /// holds: the runtime contract for an index_get from a borrow
    /// is identical to an index_get from the source — both lower to
    /// `elem_val_imm` and the paired retain bumps the cell's
    /// refcount. The borrow's lifetime is bounded by the source's,
    /// so the source's eventual scope-exit release fires the
    /// component cell's refcount decrement that uniqueness relies on.
    fn copyTuplePending(self: *Analyzer, dest: ir.LocalId, source: ir.LocalId) error{OutOfMemory}!void {
        if (dest == source) return;
        const src_entry = self.tuple_pending.getPtr(source) orelse return;
        if (src_entry.escaped) return;
        const flags_copy = try self.allocator.alloc(bool, src_entry.components_unique.len);
        @memcpy(flags_copy, src_entry.components_unique);
        // Replace any prior pending at dest first.
        self.removePending(dest);
        try self.tuple_pending.put(self.allocator, dest, .{
            .components_unique = flags_copy,
            .extracted = .empty,
        });
    }

    /// Phase 2.5 — propagate an `extracted` membership through an
    /// alias-form instruction. When `source` is an extracted local
    /// (from some pending tuple), the alias's `dest` inherits the
    /// same parent-tuple linkage. The parent's pending entry's
    /// `extracted` list is also patched: the original `source` ref
    /// is replaced with `dest` so the parent's last-use promotion
    /// finds the renamed local. The original `source` is removed
    /// from the reverse map so a subsequent operation on `source`
    /// doesn't incorrectly trigger an escape.
    ///
    /// If `source` is not in `extracted`, this is a no-op.
    fn propagateExtractedAlias(self: *Analyzer, dest: ir.LocalId, source: ir.LocalId) error{OutOfMemory}!void {
        if (dest == source) return;
        const kv = self.extracted.fetchRemove(source) orelse return;
        // Patch the parent's extracted list: replace source with dest.
        if (self.tuple_pending.getPtr(kv.value.source_tuple)) |entry| {
            for (entry.extracted.items) |*ref| {
                if (ref.local == source) {
                    ref.local = dest;
                }
            }
        }
        try self.extracted.put(self.allocator, dest, kv.value);
    }

    /// Phase 2.5 — snapshot per-arg uniqueness at the call site.
    /// Returns a freshly-allocated bool slice; caller frees.
    fn snapshotArgUnique(
        self: *Analyzer,
        args: []const ir.LocalId,
    ) error{OutOfMemory}![]bool {
        const result = try self.allocator.alloc(bool, args.len);
        for (args, 0..) |arg, i| {
            result[i] = self.unique.contains(arg);
        }
        return result;
    }

    fn walkStream(
        self: *Analyzer,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!void {
        for (stream) |*instr| {
            const my_id = self.next_id;
            self.next_id += 1;
            try self.classifyCallSiteIfApplicable(instr, my_id);
            try self.applyEffect(instr, my_id);
            // Phase 2.5 — after the effect runs, this instruction has
            // committed any new pending entries / extracted refs.
            // If the instruction was the LAST USE of a still-pending
            // tuple, promote every extracted local from that tuple.
            // We iterate a snapshot of the keys because
            // `promoteExtractedAt` mutates `tuple_pending`.
            try self.promoteAtLastUse(my_id);
            try self.walkChildren(instr);
        }
    }

    /// Phase 2.5 — for every still-pending tuple whose last-use
    /// fires AT `my_id`, promote its extracted locals' uniqueness.
    /// Iterates a snapshot of the pending keys because the helper
    /// mutates the map.
    fn promoteAtLastUse(
        self: *Analyzer,
        my_id: arc_liveness.InstructionId,
    ) error{OutOfMemory}!void {
        if (self.ownership == null) return;
        if (self.tuple_pending.count() == 0) return;
        // Snapshot keys to avoid invalidation during iteration.
        var keys = std.ArrayListUnmanaged(ir.LocalId).empty;
        defer keys.deinit(self.allocator);
        var it = self.tuple_pending.keyIterator();
        while (it.next()) |k| try keys.append(self.allocator, k.*);
        for (keys.items) |k| try self.promoteExtractedAt(k, my_id);
    }

    fn walkChildren(
        self: *Analyzer,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!void {
        // The forward dataflow inside a structural arm starts from
        // the parent stream's current `unique` set. Different arms of
        // an if/switch can leave different sets; for the purposes of
        // uniqueness (which is a per-call-site predicate, not a join-set
        // predicate), we walk every arm but reset the uniqueness set
        // back to the parent's snapshot after each arm so that
        // subsequent instructions in the parent stream observe the
        // pre-branch state. This is conservative — a local that
        // becomes unique inside one arm but not another would be
        // tracked as still-unique inside the arm and reset at the
        // arm boundary, which is correct for any owned-mutating call
        // site INSIDE the arm.
        switch (instr.*) {
            .if_expr => |ie| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(ie.then_instrs);
                try self.restore(&snap);
                try self.walkStream(ie.else_instrs);
                try self.restore(&snap);
            },
            .case_block => |cb| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(cb.pre_instrs);
                const post_pre = try self.snapshot();
                defer post_pre.deinit(self.allocator);
                for (cb.arms) |arm| {
                    try self.walkStream(arm.cond_instrs);
                    try self.walkStream(arm.body_instrs);
                    try self.restore(&post_pre);
                }
                try self.walkStream(cb.default_instrs);
                try self.restore(&snap);
            },
            .switch_literal => |sl| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (sl.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
                try self.walkStream(sl.default_instrs);
                try self.restore(&snap);
            },
            .switch_return => |sr| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (sr.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
                try self.walkStream(sr.default_instrs);
                try self.restore(&snap);
            },
            .union_switch => |us| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (us.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
            },
            .union_switch_return => |usr| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (usr.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
            },
            .try_call_named => |tcn| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(tcn.handler_instrs);
                try self.restore(&snap);
                try self.walkStream(tcn.success_instrs);
                try self.restore(&snap);
            },
            .guard_block => |gb| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(gb.body);
                try self.restore(&snap);
            },
            .optional_dispatch => |od| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(od.nil_instrs);
                try self.restore(&snap);
                try self.walkStream(od.struct_instrs);
                try self.restore(&snap);
            },
            else => {},
        }
    }

    fn snapshot(self: *Analyzer) error{OutOfMemory}!Snapshot {
        var copy: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
        var iter = self.unique.keyIterator();
        while (iter.next()) |k| {
            try copy.put(self.allocator, k.*, {});
        }
        return Snapshot{ .set = copy };
    }

    fn restore(
        self: *Analyzer,
        snap: *const Snapshot,
    ) error{OutOfMemory}!void {
        self.unique.clearRetainingCapacity();
        var iter = snap.set.keyIterator();
        while (iter.next()) |k| {
            try self.unique.put(self.allocator, k.*, {});
        }
    }

    /// Before applying the instruction's effect to the dataflow set,
    /// classify whether this instruction is an owned-mutating call
    /// site. If so, snapshot the receiver's uniqueness as observed
    /// in the PRE-call dataflow state and store it in the result map.
    ///
    /// When `record_arg_sites` is enabled, additionally snapshot per-arg
    /// uniqueness for every call site that resolves to a known program
    /// function. The interprocedural fixpoint consumes this to demote
    /// callee parameter slots whose argument was non-unique at the call.
    ///
    /// Why classify pre-effect: uniqueness asks "was the receiver unique when
    /// it entered the call?" The call's own effect (consume the
    /// receiver, produce a fresh result) is applied AFTER this
    /// classification; classifying after-effect would describe the
    /// call's result, not its receiver.
    fn classifyCallSiteIfApplicable(
        self: *Analyzer,
        instr: *const ir.Instruction,
        my_id: arc_liveness.InstructionId,
    ) error{OutOfMemory}!void {
        if (self.callSiteOwnedMutating(instr)) |slot_and_recv| {
            const is_unique = self.unique.contains(slot_and_recv.receiver);
            try self.result.sites.put(self.allocator, my_id, is_unique);
        }

        if (self.record_arg_sites) {
            if (self.callSiteArgs(instr)) |info| {
                const per_arg = try self.allocator.alloc(bool, info.args.len);
                for (info.args, 0..) |arg, idx| {
                    per_arg[idx] = self.unique.contains(arg);
                }
                try self.result.arg_sites.put(self.allocator, my_id, .{
                    .target = info.target,
                    .per_arg = per_arg,
                });
            }
        }
    }

    const CallSiteInfo = struct {
        receiver: ir.LocalId,
    };

    /// Args-info for a call site whose callee resolves to a known
    /// program function. Used only when `record_arg_sites` is true.
    const CallSiteArgsInfo = struct {
        target: ir.FunctionId,
        args: []const ir.LocalId,
    };

    /// For any call site that resolves to a known program function,
    /// return the target FunctionId and the args slice. This covers
    /// the callee-bound demotion case — even non-owned-mutating calls
    /// can demote a callee's slot if their arg isn't unique at the
    /// call site.
    fn callSiteArgs(
        self: *const Analyzer,
        instr: *const ir.Instruction,
    ) ?CallSiteArgsInfo {
        switch (instr.*) {
            .call_named => |cn| {
                const target = self.lookupByName(cn.name) orelse return null;
                return .{ .target = target, .args = cn.args };
            },
            .call_direct => |cd| {
                return .{ .target = cd.function, .args = cd.args };
            },
            .try_call_named => |tcn| {
                const target = self.lookupByName(tcn.name) orelse return null;
                return .{ .target = target, .args = tcn.args };
            },
            .tail_call => |tc| {
                const target = self.lookupByName(tc.name) orelse return null;
                return .{ .target = target, .args = tc.args };
            },
            else => return null,
        }
    }

    fn lookupByName(self: *const Analyzer, name: []const u8) ?ir.FunctionId {
        const program = self.program orelse return null;
        for (program.functions) |func| {
            if (std.mem.eql(u8, func.name, name)) return func.id;
            if (func.local_name.len != 0 and std.mem.eql(u8, func.local_name, name)) return func.id;
        }
        return null;
    }

    /// If `instr` is an owned-mutating call site, return the receiver
    /// LocalId at the receiver slot. Otherwise null.
    ///
    /// Recognised shapes:
    ///   * `call_builtin` whose name matches `ownedMutatingBuiltinSlot`
    ///     (the post-monomorph runtime intrinsic).
    ///   * `call_named` / `try_call_named` whose name matches the
    ///     builtin pattern (used by tests and any future direct-name
    ///     wrappers).
    ///   * `call_named` / `call_direct` to a Zap function whose
    ///     param_conventions contain at least one `.owned` slot AND
    ///     `result_convention == .owned`. The first `.owned` slot is
    ///     treated as the receiver. This covers:
    ///       - `lib/list.zap`'s `List.set`/`push`/etc.
    ///         where slot 0 is the receiver
    ///       - `k-nucleotide`'s `count_kmers_loop` where the map
    ///         accumulator is at slot 4 (after seq/n/k/i)
    ///     The `.owned` + `.owned` pair is the contract established
    ///     by `arc_param_convention.inferConventions`: the caller
    ///     transferred a +1, the callee consumes it via an owned-
    ///     mutating builtin (or self-recursive accumulator), and the
    ///     result is a fresh +1.
    fn callSiteOwnedMutating(
        self: *Analyzer,
        instr: *const ir.Instruction,
    ) ?CallSiteInfo {
        switch (instr.*) {
            .call_builtin => |cb| {
                const slot = arc_liveness.ownedMutatingBuiltinSlot(cb.name) orelse return null;
                if (slot >= cb.args.len) return null;
                return .{ .receiver = cb.args[slot] };
            },
            .call_named => |cn| {
                if (arc_liveness.ownedMutatingBuiltinSlot(cn.name)) |slot| {
                    if (slot >= cn.args.len) return null;
                    return .{ .receiver = cn.args[slot] };
                }
                if (self.calleeOwnedReceiverSlot(cn.name)) |slot| {
                    if (slot >= cn.args.len) return null;
                    return .{ .receiver = cn.args[slot] };
                }
                return null;
            },
            .call_direct => |cd| {
                const callee = self.lookupFunction(cd.function) orelse return null;
                if (arc_liveness.ownedMutatingBuiltinSlot(callee.name)) |slot| {
                    if (slot >= cd.args.len) return null;
                    return .{ .receiver = cd.args[slot] };
                }
                if (calleeFunctionOwnedReceiverSlot(callee)) |slot| {
                    if (slot >= cd.args.len) return null;
                    return .{ .receiver = cd.args[slot] };
                }
                return null;
            },
            .try_call_named => |tcn| {
                if (arc_liveness.ownedMutatingBuiltinSlot(tcn.name)) |slot| {
                    if (slot >= tcn.args.len) return null;
                    return .{ .receiver = tcn.args[slot] };
                }
                if (self.calleeOwnedReceiverSlot(tcn.name)) |slot| {
                    if (slot >= tcn.args.len) return null;
                    return .{ .receiver = tcn.args[slot] };
                }
                return null;
            },
            else => return null,
        }
    }

    fn lookupFunctionName(self: *const Analyzer, function_id: ir.FunctionId) ?[]const u8 {
        const program = self.program orelse return null;
        for (program.functions) |func| {
            if (func.id == function_id) return func.name;
        }
        return null;
    }

    fn lookupFunction(self: *const Analyzer, function_id: ir.FunctionId) ?*const ir.Function {
        const program = self.program orelse return null;
        for (program.functions) |*func| {
            if (func.id == function_id) return func;
        }
        return null;
    }

    /// Look up the callee by name and return its owned-receiver slot
    /// index when the function has the `.owned` slot + `.owned` result
    /// convention pair. Returns null when the program reference is
    /// absent (test scaffolding), the name doesn't match, or the
    /// function isn't an owned-mutating Zap-fn wrapper.
    fn calleeOwnedReceiverSlot(self: *const Analyzer, name: []const u8) ?usize {
        const program = self.program orelse return null;
        for (program.functions) |*func| {
            if (std.mem.eql(u8, func.name, name)) {
                return calleeFunctionOwnedReceiverSlot(func);
            }
        }
        return null;
    }

    /// Apply the dataflow transfer function for `instr`. Updates
    /// `self.unique` in place. The contract is forward-dataflow:
    /// after this call, `self.unique` contains the LocalIds that
    /// are proven `definitely_unique` IMMEDIATELY AFTER `instr`
    /// executes.
    ///
    /// Effect rules (see top-of-file documentation for the why):
    ///
    ///   Sets dest unique:
    ///     * Fresh allocations: aggregate inits (the cell is freshly
    ///       allocated by the IR builder, so refcount = 1 by
    ///       construction; this matches the runtime's `bufferAlloc`
    ///       contract).
    ///     * Owned-mutating call results (`call_builtin` /
    ///       `call_named` / `call_direct` matching the owned-
    ///       mutating builtin pattern): the runtime contract is
    ///       "result is a buffer with refcount = 1" — either the
    ///       rc-1 fast path returned the same cell (now unique
    ///       because we consumed our share), or the shared path
    ///       returned a fresh clone. Both are unique.
    ///     * `move_value` from a unique source: dest takes over the
    ///       source's +1; source is no longer the live owner.
    ///
    ///   Clears (or fails to set) dest unique:
    ///     * `share_value`, `copy_value`: the value's refcount went
    ///       up; both source and dest see the bumped count.
    ///     * `borrow_value`: dest is a borrow, not an owner.
    ///     * `param_get`: callers are responsible for the refcount;
    ///       conservatively NOT unique.
    ///     * Storage in aggregates: any LocalId stored as part of
    ///       a `list_cons`, `map_init`, `tuple_init`, `struct_init`,
    ///       `union_init`, `list_init` element loses uniqueness —
    ///       the aggregate now holds a permanent retain.
    ///
    /// Locals not explicitly handled (control flow, releases,
    /// retains, returns): no effect on uniqueness.
    fn applyEffect(
        self: *Analyzer,
        instr: *const ir.Instruction,
        my_id: arc_liveness.InstructionId,
    ) error{OutOfMemory}!void {
        switch (instr.*) {
            // ----- Producers of unique values -----
            .tuple_init => |ti| {
                // Phase 2.5 — record per-component uniqueness in a
                // pending entry instead of unconditionally clearing
                // every element. The pending entry resolves at the
                // tuple's last-use (uniqueness flows to extracted
                // locals) or at any escape sink (uniqueness is
                // dropped). The element locals themselves DO lose
                // their `unique` bit here — they're no longer
                // first-class owners; ownership has transferred to
                // the new tuple cell.
                var unique_flags = try self.allocator.alloc(bool, ti.elements.len);
                for (ti.elements, 0..) |elem, i| {
                    unique_flags[i] = self.unique.contains(elem);
                    _ = self.unique.remove(elem);
                    // If an element is itself an extracted local from
                    // another tuple_pending, the storage into this
                    // outer tuple is an escape of the inner pending
                    // entry — drop the inner pending so a later
                    // last-use on it doesn't try to promote locals
                    // that have since aliased into this outer tuple.
                    self.escapeIfExtractedLocal(elem);
                    // If an element is itself a pending tuple, that
                    // entire pending entry escapes (the inner tuple
                    // is now stored as a component of the outer; its
                    // own components can no longer be promoted).
                    self.escapePending(elem);
                }
                // Replace any prior pending entry at the dest.
                self.removePending(ti.dest);
                try self.tuple_pending.put(self.allocator, ti.dest, .{
                    .components_unique = unique_flags,
                    .extracted = .empty,
                });
                try self.unique.put(self.allocator, ti.dest, {});
            },
            .list_init => |li| {
                for (li.elements) |elem| {
                    _ = self.unique.remove(elem);
                    self.escapeIfExtractedLocal(elem);
                    self.escapePending(elem);
                }
                try self.unique.put(self.allocator, li.dest, {});
            },
            .list_cons => |lc| {
                // Phase F gap #2 — path-sensitive escape suppression
                // on the tail. The runtime's `List.cons` (commit
                // fb32ef1) has an rc-1 in-place fast path: when the
                // tail's cell is at refcount 1 the cons mutates the
                // tail's buffer directly, returning the same cell as
                // `lc.dest`. The compiler-side counterpart is to
                // recognise that when the tail local is at last-use
                // path-sensitively, any tuple_pending state on it is
                // NOT defeated by the cons (no new alias is created;
                // the cell flows through). Mirrors the Phase 1.4 /
                // 2.2 last-use refinements in
                // `arc_ownership.shouldMoveIntoOwnedConsume` and
                // `shouldMoveIntoAggregate`. Without this gate, the
                // tail's pending entry is dissolved before
                // `walkStream`'s `promoteAtLastUse` fires at this
                // same instruction id, so extracted-from-tail locals
                // never inherit their component's uniqueness — the
                // exact pattern the `acc = [x | acc]` accumulator
                // hits when the accumulator is a destructured tuple
                // component.
                const tail_at_last_use = if (self.ownership) |o|
                    o.isLastUseAt(lc.tail, my_id)
                else
                    false;

                _ = self.unique.remove(lc.head);
                _ = self.unique.remove(lc.tail);
                self.escapeIfExtractedLocal(lc.head);
                self.escapePending(lc.head);
                if (!tail_at_last_use) {
                    // Not at last-use: the cons retains a new alias
                    // to the tail's cell, so any pending entry on
                    // the tail loses its sole-owner guarantee.
                    // Dissolve the pending entry (preserves the
                    // pre-fix semantics for non-last-use cases).
                    self.escapeIfExtractedLocal(lc.tail);
                    self.escapePending(lc.tail);
                }
                try self.unique.put(self.allocator, lc.dest, {});
            },
            .map_init => |mi| {
                for (mi.entries) |entry| {
                    _ = self.unique.remove(entry.key);
                    _ = self.unique.remove(entry.value);
                    self.escapeIfExtractedLocal(entry.key);
                    self.escapeIfExtractedLocal(entry.value);
                    self.escapePending(entry.key);
                    self.escapePending(entry.value);
                }
                try self.unique.put(self.allocator, mi.dest, {});
            },
            .struct_init => |si| {
                for (si.fields) |f| {
                    _ = self.unique.remove(f.value);
                    self.escapeIfExtractedLocal(f.value);
                    self.escapePending(f.value);
                }
                try self.unique.put(self.allocator, si.dest, {});
            },
            .union_init => |ui| {
                _ = self.unique.remove(ui.value);
                self.escapeIfExtractedLocal(ui.value);
                self.escapePending(ui.value);
                try self.unique.put(self.allocator, ui.dest, {});
            },
            .make_closure => |mc| {
                // Capturing into a closure is an unconditional
                // escape — components of any captured tuple_pending
                // can't be promoted afterwards.
                for (mc.captures) |cap| {
                    _ = self.unique.remove(cap);
                    self.escapeIfExtractedLocal(cap);
                    self.escapePending(cap);
                }
            },

            // Owned-mutating call results are unique by runtime contract
            // (see top-of-file). Non-mutating calls are conservatively
            // not classified as unique.
            .call_builtin => |cb| {
                // Phase 2.5 — every arg passed to a builtin escapes the
                // arg's tuple_pending entry (the builtin may store it).
                for (cb.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                if (arc_liveness.ownedMutatingBuiltinSlot(cb.name) != null) {
                    if (cb.args.len > 0) {
                        // The receiver was consumed by the move_value
                        // that fed args[0]; clear its bit here so any
                        // stale alias doesn't leak forward.
                        const slot = arc_liveness.ownedMutatingBuiltinSlot(cb.name).?;
                        if (slot < cb.args.len) {
                            _ = self.unique.remove(cb.args[slot]);
                        }
                    }
                    try self.unique.put(self.allocator, cb.dest, {});
                } else if (arc_liveness.consBuiltinTailSlot(cb.name)) |tail_slot| {
                    // `:zig.List.cons(head, tail)` — the rc-1 in-place
                    // fast path: when the cons tail is at last-use, the
                    // runtime mutates the tail's refcount-1 buffer in
                    // place and returns the same cell as the dest. The
                    // dest therefore inherits the tail's uniqueness.
                    // This is the per-instruction counterpart of the
                    // `list_cons` IR-node rc-1 gate above, and the
                    // soundness condition for the cons-tail-preserves-
                    // uniqueness signature: the dest is unique ONLY when
                    // the tail was unique AND at its last use here.
                    //
                    // Not at last-use → the cons retains a fresh alias to
                    // the tail's cell (rc>=2), so the dest is not unique.
                    const tail_unique_at_last_use = blk: {
                        if (tail_slot >= cb.args.len) break :blk false;
                        const tail = cb.args[tail_slot];
                        if (!self.unique.contains(tail)) break :blk false;
                        const o = self.ownership orelse break :blk false;
                        break :blk o.isLastUseAt(tail, my_id);
                    };
                    if (tail_slot < cb.args.len) {
                        // The tail's uniqueness flows into the dest (or is
                        // lost); either way the tail local is no longer a
                        // first-class owner after the cons.
                        _ = self.unique.remove(cb.args[tail_slot]);
                    }
                    if (tail_unique_at_last_use) {
                        try self.unique.put(self.allocator, cb.dest, {});
                    } else {
                        _ = self.unique.remove(cb.dest);
                    }
                } else if (arc_liveness.isFreshAllocatorBuiltin(cb.name)) {
                    // Fresh allocator: runtime contract is rc=1 by
                    // construction. The dest is unique on every reach.
                    try self.unique.put(self.allocator, cb.dest, {});
                } else {
                    // Other call_builtin results: conservatively not
                    // unique (we don't know the runtime's refcount
                    // contract for arbitrary builtins).
                    _ = self.unique.remove(cb.dest);
                }
            },
            .call_named => |cn| {
                const pre = try self.snapshotArgUnique(cn.args);
                defer self.allocator.free(pre);
                for (cn.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                try self.applyCalleeEffect(cn.name, cn.args, cn.dest, pre);
            },
            .call_direct => |cd| {
                const pre = try self.snapshotArgUnique(cd.args);
                defer self.allocator.free(pre);
                for (cd.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                const callee = self.lookupFunction(cd.function);
                if (callee) |func| {
                    try self.applyCalleeEffectWithFunction(func, cd.args, cd.dest, pre);
                } else {
                    _ = self.unique.remove(cd.dest);
                }
            },
            .try_call_named => |tcn| {
                const pre = try self.snapshotArgUnique(tcn.args);
                defer self.allocator.free(pre);
                for (tcn.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                try self.applyCalleeEffect(tcn.name, tcn.args, tcn.dest, pre);
            },
            .tail_call => |tc| {
                // Tail-calls also consume their args; their pending
                // entries dissolve.
                for (tc.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
            },
            .call_closure => |cc| {
                for (cc.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                _ = self.unique.remove(cc.dest);
            },
            .call_dispatch => |cd| {
                for (cd.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                _ = self.unique.remove(cd.dest);
            },

            // ----- Move transfers uniqueness -----
            .move_value => |mv| {
                // Phase 2.5 — pending propagation: a tuple_pending or
                // extracted-from-pending alias re-keys to the dest.
                try self.propagateTuplePending(mv.dest, mv.source);
                try self.propagateExtractedAlias(mv.dest, mv.source);
                if (self.unique.contains(mv.source)) {
                    _ = self.unique.remove(mv.source);
                    try self.unique.put(self.allocator, mv.dest, {});
                } else {
                    // Move from a non-unique source — dest is also
                    // not unique. Clear in case a stale entry from a
                    // prior alias is sitting in the set.
                    _ = self.unique.remove(mv.dest);
                }
            },

            // ----- Shares / copies / borrows clear uniqueness -----
            .share_value => |sv| {
                // share_value{dest, source}: emits a retain on source.
                // Both source and dest now refer to a cell with
                // refcount >= 2 — neither is unique afterwards.
                _ = self.unique.remove(sv.source);
                _ = self.unique.remove(sv.dest);
                // share_value escapes any pending entry on the source —
                // the source has been retained into another owner
                // position (the share's dest), so the cell is now rc>=2
                // and components can no longer be promoted on the
                // source's last-use.
                self.escapeIfExtractedLocal(sv.source);
                self.escapePending(sv.source);
            },
            .copy_value => |cv| {
                // copy_value: emits a runtime retain on `source`,
                // bumping the cell's refcount to >= 2. After this
                // point neither `source` nor `dest` are uniquely
                // owned — both refer to a cell with multiple owners.
                //
                // Phase 2.2 audit: the previous handler removed
                // ONLY dest, leaving source unique. That was unsound
                // for uniqueness — a downstream consume site fed by the
                // (still-unique-marked) source would emit
                // `*_owned_unchecked` over a refcount-2 cell, which
                // panics on the runtime's rc==1 fast path assertion.
                // Mirroring `share_value`'s "both removed" semantics
                // matches the runtime contract.
                _ = self.unique.remove(cv.source);
                _ = self.unique.remove(cv.dest);
                // copy_value escapes the pending entry the same way
                // share_value does — the cell now exists at >=2 owners.
                self.escapeIfExtractedLocal(cv.source);
                self.escapePending(cv.source);
            },
            .borrow_value => |bv| {
                // borrow_value: dest is a borrow, never an owner.
                _ = self.unique.remove(bv.dest);
                // Phase 2.5 — borrow_value does NOT consume its source,
                // so the pending entry must remain at the source while
                // also linking dest. Copy semantics (rather than move)
                // preserves the source's pending so subsequent borrows
                // and the source's own last-use still see it.
                try self.copyTuplePending(bv.dest, bv.source);
            },

            // ----- Local aliasing transfers uniqueness on the source-
            // unique path. `arc_liveness.applyOwnsEffect` treats both
            // as ownership transfers (Phase E.9 step 5: local_set is a
            // move from source to dest; local_get is a fresh alias
            // that the classifier elsewhere upgrades to a move when
            // the source is at last use). uniqueness mirrors that contract:
            // when the source is provably unique, the dest takes over
            // the uniqueness; otherwise the dest is conservatively
            // not classified.
            .local_get => |lg| {
                try self.propagateTuplePending(lg.dest, lg.source);
                try self.propagateExtractedAlias(lg.dest, lg.source);
                if (self.unique.contains(lg.source)) {
                    _ = self.unique.remove(lg.source);
                    try self.unique.put(self.allocator, lg.dest, {});
                } else {
                    _ = self.unique.remove(lg.dest);
                }
            },
            .local_set => |ls| {
                try self.propagateTuplePending(ls.dest, ls.value);
                try self.propagateExtractedAlias(ls.dest, ls.value);
                if (self.unique.contains(ls.value)) {
                    _ = self.unique.remove(ls.value);
                    try self.unique.put(self.allocator, ls.dest, {});
                } else {
                    _ = self.unique.remove(ls.dest);
                }
            },
            .param_get => |pg| {
                // Interprocedural uniqueness (A1): consult the fixpoint when
                // available. A slot proven `unique_on_entry` by the
                // whole-program fixpoint guarantees every reachable
                // caller passed a refcount=1 cell, so the param's
                // first observation in this function is unique.
                //
                // Without the fixpoint we conservatively treat every
                // parameter as potentially shared (the original
                // intraprocedural default).
                if (self.fixpoint) |fp| {
                    if (fp.isUniqueOnEntry(self.function.id, pg.index)) {
                        try self.unique.put(self.allocator, pg.dest, {});
                    } else {
                        _ = self.unique.remove(pg.dest);
                    }
                } else {
                    _ = self.unique.remove(pg.dest);
                }
            },

            // ----- Move/share/copy/borrow into a sink local -----
            // These are handled specifically in arms above; these
            // arms below handle the alias-form propagation for
            // tuple_pending.

            // ----- Returns: when the value is a pending tuple,
            //       leave it alone — Phase 2.1's signature mechanism
            //       handles cross-function propagation. The dataflow
            //       does not need to clear the pending entry; the
            //       function ends here. -----

            // ----- Index_get: project per-component uniqueness from a
            //       tuple_pending source. The dest is recorded as an
            //       extracted ref; promotion to `unique` fires at the
            //       parent tuple's last-use (modelling the
            //       index_get + retain destructure idiom). -----
            .index_get => |ig| {
                _ = self.unique.remove(ig.dest);
                if (self.tuple_pending.getPtr(ig.object)) |entry| {
                    if (entry.escaped) return;
                    if (ig.index < entry.components_unique.len) {
                        try entry.extracted.append(self.allocator, .{
                            .local = ig.dest,
                            .component_idx = ig.index,
                        });
                        try self.extracted.put(self.allocator, ig.dest, .{
                            .source_tuple = ig.object,
                            .component_idx = ig.index,
                        });
                    }
                }
            },
            .list_tail => |lt| {
                const source_unique = self.unique.contains(lt.list);
                try self.result.sites.put(self.allocator, my_id, source_unique);
                if (lt.consume_source) {
                    _ = self.unique.remove(lt.list);
                }
                try self.unique.put(self.allocator, lt.dest, {});
            },

            // ----- Control flow / non-data-producing instructions -----
            .release,
            .retain,
            .ret,
            .cond_return,
            .switch_tag,
            .branch,
            .cond_branch,
            .jump,
            .match_fail,
            .match_error_return,
            .case_break,
            .set_safety,
            => {},

            // ----- Other instructions: no effect on uniqueness -----
            // The set of instruction tags above is exhaustive for the
            // ARC pipeline's existing test corpus. New IR opcodes
            // that produce values should explicitly opt in here.
            else => {},
        }
    }

    /// Apply the per-callee dataflow effect. Recognises three shapes:
    ///   1. Builtin-name match (`ownedMutatingBuiltinSlot(name) != null`).
    ///   2. Zap-fn convention match (any `.owned` slot + `.owned` result).
    ///   3. Zap-fn fresh-allocator wrapper (no `.owned` slots, but body
    ///      is a thin forward to a fresh-allocator builtin like
    ///      `List:i64.new_filled`). The result is unique by the
    ///      runtime's allocation contract.
    /// All three shapes mark the call's dest as unique.
    ///
    /// Phase 2.5 — additionally, when `signatures` is non-null and the
    /// callee resolves to a function whose `return_components` table
    /// records per-component PU witnesses, synthesise a `tuple_pending`
    /// entry on `dest`. Each component's `unique` flag is `true` iff
    /// the witness arg was unique at the call site (queried from
    /// `pre_arg_unique`). Downstream `index_get(dest, i) + retain`
    /// destructure idioms can then promote the extracted local at the
    /// tuple's last-use.
    fn applyCalleeEffect(
        self: *Analyzer,
        name: []const u8,
        args: []const ir.LocalId,
        dest: ir.LocalId,
        pre_arg_unique: []const bool,
    ) error{OutOfMemory}!void {
        if (arc_liveness.ownedMutatingBuiltinSlot(name)) |slot| {
            if (slot < args.len) {
                _ = self.unique.remove(args[slot]);
            }
            try self.unique.put(self.allocator, dest, {});
            try self.synthesizeReturnPendingByName(name, args, dest, pre_arg_unique);
            return;
        }
        if (self.calleeOwnedReceiverSlot(name)) |slot| {
            if (slot < args.len) {
                _ = self.unique.remove(args[slot]);
            }
            try self.unique.put(self.allocator, dest, {});
            try self.synthesizeReturnPendingByName(name, args, dest, pre_arg_unique);
            return;
        }
        if (self.calleeIsFreshAllocatorWrapper(name)) {
            try self.unique.put(self.allocator, dest, {});
            return;
        }
        // Non-mutating call: result not classified.
        _ = self.unique.remove(dest);
        try self.synthesizeReturnPendingByName(name, args, dest, pre_arg_unique);
    }

    fn applyCalleeEffectWithFunction(
        self: *Analyzer,
        function: *const ir.Function,
        args: []const ir.LocalId,
        dest: ir.LocalId,
        pre_arg_unique: []const bool,
    ) error{OutOfMemory}!void {
        if (arc_liveness.ownedMutatingBuiltinSlot(function.name)) |slot| {
            if (slot < args.len) {
                _ = self.unique.remove(args[slot]);
            }
            try self.unique.put(self.allocator, dest, {});
            try self.synthesizeReturnPendingByFunction(function.id, args, dest, pre_arg_unique);
            return;
        }
        if (calleeFunctionOwnedReceiverSlot(function)) |slot| {
            if (slot < args.len) {
                _ = self.unique.remove(args[slot]);
            }
            try self.unique.put(self.allocator, dest, {});
            try self.synthesizeReturnPendingByFunction(function.id, args, dest, pre_arg_unique);
            return;
        }
        if (functionIsFreshAllocatorWrapperWithProgram(function, self.program)) {
            try self.unique.put(self.allocator, dest, {});
            return;
        }
        _ = self.unique.remove(dest);
        try self.synthesizeReturnPendingByFunction(function.id, args, dest, pre_arg_unique);
    }

    /// Phase 2.5 — synthesize a `tuple_pending` entry on the call's
    /// dest using the callee's `return_components` table (when
    /// available). Each component's witness names a parameter slot of
    /// the callee whose uniqueness preserves through that component;
    /// the synthesized component's `unique` flag is the corresponding
    /// `pre_arg_unique[witness]`.
    fn synthesizeReturnPendingByName(
        self: *Analyzer,
        name: []const u8,
        args: []const ir.LocalId,
        dest: ir.LocalId,
        pre_arg_unique: []const bool,
    ) error{OutOfMemory}!void {
        const sigs = self.signatures orelse return;
        const program = self.program orelse return;
        const target_id: ir.FunctionId = blk: {
            for (program.functions) |func| {
                if (std.mem.eql(u8, func.name, name)) break :blk func.id;
            }
            return;
        };
        try self.synthesizeReturnPendingFromSig(sigs, target_id, args, dest, pre_arg_unique);
    }

    fn synthesizeReturnPendingByFunction(
        self: *Analyzer,
        function_id: ir.FunctionId,
        args: []const ir.LocalId,
        dest: ir.LocalId,
        pre_arg_unique: []const bool,
    ) error{OutOfMemory}!void {
        const sigs = self.signatures orelse return;
        try self.synthesizeReturnPendingFromSig(sigs, function_id, args, dest, pre_arg_unique);
    }

    fn synthesizeReturnPendingFromSig(
        self: *Analyzer,
        sigs: *const uniqueness_signature.ProgramSignatures,
        function_id: ir.FunctionId,
        args: []const ir.LocalId,
        dest: ir.LocalId,
        pre_arg_unique: []const bool,
    ) error{OutOfMemory}!void {
        const sig = sigs.forFunction(function_id) orelse return;
        if (sig.return_components.len == 0) return;
        // Only synthesize if at least one component has a witness.
        var has_witness = false;
        for (sig.return_components) |opt| {
            if (opt != null) {
                has_witness = true;
                break;
            }
        }
        if (!has_witness) return;
        var flags = try self.allocator.alloc(bool, sig.return_components.len);
        for (sig.return_components, 0..) |opt, i| {
            flags[i] = false;
            if (opt) |arg_idx_u8| {
                const arg_idx: usize = @intCast(arg_idx_u8);
                if (arg_idx < args.len and arg_idx < pre_arg_unique.len) {
                    flags[i] = pre_arg_unique[arg_idx];
                }
            }
        }
        // If no component is actually unique, skip (no payoff).
        var any_unique = false;
        for (flags) |f| {
            if (f) {
                any_unique = true;
                break;
            }
        }
        if (!any_unique) {
            self.allocator.free(flags);
            return;
        }
        self.removePending(dest);
        try self.tuple_pending.put(self.allocator, dest, .{
            .components_unique = flags,
            .extracted = .empty,
        });
    }

    /// Look up the callee by name and decide whether it is a thin
    /// fresh-allocator wrapper. Returns false when the program
    /// reference is absent (test scaffolding) or the name doesn't
    /// match.
    fn calleeIsFreshAllocatorWrapper(self: *const Analyzer, name: []const u8) bool {
        const program = self.program orelse return false;
        for (program.functions) |*func| {
            if (std.mem.eql(u8, func.name, name)) {
                return functionIsFreshAllocatorWrapperWithProgram(func, program);
            }
        }
        return false;
    }
};

/// uniqueness (Phase 1.4): is `function` a thin Zap-fn wrapper around a
/// runtime fresh-allocator intrinsic? The pattern:
///
///     pub fn new_filled(size :: i64, init :: i64) -> List(i64) {
///       :zig.List.new_filled(size, init)
///     }
///
/// lowers to a body containing exactly one owned-bearing call —
/// `call_builtin name=List:i64.new_filled` — followed by a `ret`
/// of that call's dest. Such wrappers inherit the runtime's "fresh
/// allocation, refcount=1" contract; the uniqueness dataflow treats their
/// result as `definitely_unique`.
///
/// The check is structural: walk every instruction in the function's
/// body. The wrapper is fresh when its body contains EXACTLY ONE
/// allocator-producing call site (either a `call_builtin` that passes
/// `arc_liveness.isFreshAllocatorBuiltin`, or a `call_named`/`call_direct`
/// whose target is ITSELF a fresh-allocator wrapper) and zero other
/// non-fresh calls. Transitive recognition is essential for benchmark
/// patterns like `ones(n) -> List.new_filled(n, 1.0)` where the user
/// wraps the runtime allocator in a thin Zap helper — without
/// transitive recognition, every such wrapper's caller observes a
/// non-unique result and the uniqueness fixpoint cascades demotions
/// through the rest of the program.
///
/// The function's `result_convention == .owned` is also required, since
/// only ARC-managed returns participate in uniqueness analysis.
///
/// We don't require the ret to literally be `value=allocator_dest`
/// because the IR builder may emit local_set/move chains between the
/// call and the ret. The single-call invariant plus `result_convention
/// == .owned` is sufficient.
///
/// Recursion safety: cycles among Zap-fn wrappers (e.g. mutual
/// recursion that ends up calling List.new_filled at some depth) are
/// not legitimate fresh-allocator chains — fresh allocator semantics
/// require a syntactically-bounded call depth. The recursion depth is
/// capped at a small constant; chains exceeding the cap are rejected
/// (the safe default). The cap also prevents stack overflow on
/// pathological IR shapes.
pub fn functionIsFreshAllocatorWrapper(function: *const ir.Function) bool {
    return functionIsFreshAllocatorWrapperWithProgram(function, null);
}

/// Transitive variant: when `program` is non-null, calls to other Zap
/// functions are followed and recognised as fresh when the callee is
/// itself a fresh-allocator wrapper. Without `program`, only direct
/// `call_builtin` to a runtime allocator counts (the legacy behaviour).
pub fn functionIsFreshAllocatorWrapperWithProgram(
    function: *const ir.Function,
    program: ?*const ir.Program,
) bool {
    return functionIsFreshAllocatorWrapperWithDepth(function, program, 0);
}

/// Maximum chain depth for transitive fresh-allocator recognition.
/// In practice the deepest legitimate chain is 1–2 hops (user wrapper
/// around runtime intrinsic). The cap defends against pathological IR
/// shapes and recursive cycles.
const FRESH_ALLOCATOR_MAX_DEPTH: usize = 8;

fn functionIsFreshAllocatorWrapperWithDepth(
    function: *const ir.Function,
    program: ?*const ir.Program,
    depth: usize,
) bool {
    if (function.result_convention != .owned) return false;
    if (depth >= FRESH_ALLOCATOR_MAX_DEPTH) return false;
    var allocator_count: usize = 0;
    var other_call_count: usize = 0;
    var ctx = AllocatorWrapperScan{
        .allocator_count = &allocator_count,
        .other_call_count = &other_call_count,
        .program = program,
        .depth = depth,
    };
    for (function.body) |block| {
        scanAllocatorWrapperStream(block.instructions, &ctx);
    }
    return allocator_count == 1 and other_call_count == 0;
}

const AllocatorWrapperScan = struct {
    allocator_count: *usize,
    other_call_count: *usize,
    /// Optional program reference. When non-null, `call_named` /
    /// `call_direct` targets are resolved and (transitively) checked
    /// via `functionIsFreshAllocatorWrapperWithDepth`. When null, every
    /// non-builtin call counts as "other".
    program: ?*const ir.Program = null,
    /// Current recursion depth. Passed to nested calls so transitive
    /// chains observe the same cap.
    depth: usize = 0,
};

fn lookupProgramFunctionByName(program: *const ir.Program, name: []const u8) ?*const ir.Function {
    for (program.functions) |*func| {
        if (std.mem.eql(u8, func.name, name)) return func;
    }
    return null;
}

fn lookupProgramFunctionById(program: *const ir.Program, function_id: ir.FunctionId) ?*const ir.Function {
    for (program.functions) |*func| {
        if (func.id == function_id) return func;
    }
    return null;
}

fn scanAllocatorWrapperStream(
    stream: []const ir.Instruction,
    ctx: *AllocatorWrapperScan,
) void {
    for (stream) |*instr| {
        switch (instr.*) {
            .call_builtin => |cb| {
                if (arc_liveness.isFreshAllocatorBuiltin(cb.name)) {
                    ctx.allocator_count.* += 1;
                } else {
                    ctx.other_call_count.* += 1;
                }
            },
            // For Zap function calls, follow the chain when the program
            // is available: a call to another fresh-allocator wrapper
            // counts as an allocator call, not an "other" call. This
            // is the transitive recognition that lets benchmark
            // helpers like `ones(n) -> List.new_filled(n, 1.0)` flow
            // through to callers as fresh allocations.
            .call_named => |cn| {
                if (ctx.program) |program| {
                    if (lookupProgramFunctionByName(program, cn.name)) |target| {
                        if (functionIsFreshAllocatorWrapperWithDepth(target, ctx.program, ctx.depth + 1)) {
                            ctx.allocator_count.* += 1;
                            continue;
                        }
                    }
                }
                ctx.other_call_count.* += 1;
            },
            .call_direct => |cd| {
                if (ctx.program) |program| {
                    if (lookupProgramFunctionById(program, cd.function)) |target| {
                        if (functionIsFreshAllocatorWrapperWithDepth(target, ctx.program, ctx.depth + 1)) {
                            ctx.allocator_count.* += 1;
                            continue;
                        }
                    }
                }
                ctx.other_call_count.* += 1;
            },
            .try_call_named, .call_dispatch, .call_closure, .tail_call => {
                ctx.other_call_count.* += 1;
            },
            .if_expr => |ie| {
                scanAllocatorWrapperStream(ie.then_instrs, ctx);
                scanAllocatorWrapperStream(ie.else_instrs, ctx);
            },
            .case_block => |cb| {
                scanAllocatorWrapperStream(cb.pre_instrs, ctx);
                for (cb.arms) |arm| {
                    scanAllocatorWrapperStream(arm.cond_instrs, ctx);
                    scanAllocatorWrapperStream(arm.body_instrs, ctx);
                }
                scanAllocatorWrapperStream(cb.default_instrs, ctx);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| scanAllocatorWrapperStream(c.body_instrs, ctx);
                scanAllocatorWrapperStream(sl.default_instrs, ctx);
            },
            .switch_return => |sr| {
                for (sr.cases) |c| scanAllocatorWrapperStream(c.body_instrs, ctx);
                scanAllocatorWrapperStream(sr.default_instrs, ctx);
            },
            .union_switch => |us| {
                for (us.cases) |c| scanAllocatorWrapperStream(c.body_instrs, ctx);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| scanAllocatorWrapperStream(c.body_instrs, ctx);
            },
            .guard_block => |gb| scanAllocatorWrapperStream(gb.body, ctx),
            .optional_dispatch => |od| {
                scanAllocatorWrapperStream(od.nil_instrs, ctx);
                scanAllocatorWrapperStream(od.struct_instrs, ctx);
            },
            else => {},
        }
    }
}

/// Return the index of the first `.owned` parameter slot when
/// `function` has at least one such slot AND `result_convention == .owned`.
/// Returns null otherwise. The `.owned` + `.owned` pair is the
/// contract established by `arc_param_convention.inferConventions`:
/// the caller transferred a +1 into the slot, the callee consumes it
/// (either by forwarding to an owned-mutating builtin or by
/// self-recursive accumulator passing), and the result is a fresh +1.
fn calleeFunctionOwnedReceiverSlot(function: *const ir.Function) ?usize {
    if (function.result_convention != .owned) return null;
    for (function.param_conventions, 0..) |conv, idx| {
        if (conv == .owned) return idx;
    }
    return null;
}

const Snapshot = struct {
    set: std.AutoHashMapUnmanaged(ir.LocalId, void),

    fn deinit(self: *const Snapshot, allocator: std.mem.Allocator) void {
        var mut = self.*;
        mut.set.deinit(allocator);
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Build a minimal `ir.Function` for hand-rolled uniqueness analysis tests.
/// Caller owns the slices and is responsible for freeing them.
fn buildTestFunction(
    arena: std.mem.Allocator,
    name: []const u8,
    instructions: []const ir.Instruction,
    local_count: u32,
) !ir.Function {
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, instructions),
    };
    const ownership = try arena.alloc(ir.OwnershipClass, local_count);
    for (ownership) |*o| o.* = .owned;
    return ir.Function{
        .id = 0,
        .name = name,
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
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

test "uniqueness: fresh-alloc receiver immediately mutated is unique" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}            -- fresh allocation, unique
    //   [1] const_int %1 = 0
    //   [2] const_int %2 = 0
    //   [3] move_value %3 <- %0          -- transfer uniqueness
    //   [4] call_builtin "Map.put" args=[%3, %1, %2] dest=%4
    //
    // Expected: uniqueness holds at the call_builtin (id 4). Receiver %3 is
    // unique because it was move_value'd from a fresh map_init.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    var function = try buildTestFunction(arena, "fresh_alloc_then_put", &instrs, 5);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    // The call_builtin is at id 4 (the 5th instruction in the stream).
    try testing.expect(u.isUnique(4));
}

test "uniqueness: receiver parked via list_cons before mutation is NOT unique" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}             -- fresh allocation, unique
    //   [1] const_nil %1                  -- trivial nil tail
    //   [2] list_cons %2 = [%0 | %1]     -- aggregate retain on %0
    //   [3] const_int %3 = 0
    //   [4] const_int %4 = 0
    //   [5] move_value %5 <- %0          -- but %0 is no longer unique
    //   [6] call_builtin "Map.put" args=[%5, %3, %4] dest=%6
    //
    // Expected: uniqueness fails at the call_builtin (id 6). Receiver %5 was
    // sourced from %0, which lost uniqueness when stored in the
    // list_cons at id 2.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 5;
    args[1] = 3;
    args[2] = 4;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_nil = 1 },
        .{ .list_cons = .{ .dest = 2, .head = 0, .tail = 1 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .const_int = .{ .dest = 4, .value = 0 } },
        .{ .move_value = .{ .dest = 5, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 6,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    var function = try buildTestFunction(arena, "parked_then_put", &instrs, 7);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    // The call_builtin is at id 6.
    try testing.expect(!u.isUnique(6));
}

test "uniqueness: result of owned-mutating call is unique (chains)" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}
    //   [1] const_int %1 = 0
    //   [2] const_int %2 = 0
    //   [3] move_value %3 <- %0
    //   [4] call_builtin "Map.put" args=[%3, %1, %2] dest=%4
    //   [5] const_int %5 = 1
    //   [6] const_int %6 = 1
    //   [7] move_value %7 <- %4
    //   [8] call_builtin "Map.put" args=[%7, %5, %6] dest=%8
    //
    // Expected: uniqueness holds at BOTH calls (id 4 and id 8). The second
    // call's receiver %7 is unique because it was move_value'd from
    // %4, the result of an owned-mutating call (which is unique by
    // runtime contract).
    const args1 = try arena.alloc(ir.LocalId, 3);
    args1[0] = 3;
    args1[1] = 1;
    args1[2] = 2;
    const arg_modes1 = try arena.alloc(ir.ValueMode, 3);
    arg_modes1[0] = .move;
    arg_modes1[1] = .borrow;
    arg_modes1[2] = .borrow;
    const args2 = try arena.alloc(ir.LocalId, 3);
    args2[0] = 7;
    args2[1] = 5;
    args2[2] = 6;
    const arg_modes2 = try arena.alloc(ir.ValueMode, 3);
    arg_modes2[0] = .move;
    arg_modes2[1] = .borrow;
    arg_modes2[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = args1,
            .arg_modes = arg_modes1,
        } },
        .{ .const_int = .{ .dest = 5, .value = 1 } },
        .{ .const_int = .{ .dest = 6, .value = 1 } },
        .{ .move_value = .{ .dest = 7, .source = 4 } },
        .{ .call_builtin = .{
            .dest = 8,
            .name = "Map.put",
            .args = args2,
            .arg_modes = arg_modes2,
        } },
    };
    var function = try buildTestFunction(arena, "chained_puts", &instrs, 9);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    try testing.expect(u.isUnique(4));
    try testing.expect(u.isUnique(8));
}

test "uniqueness: function-parameter receiver is NOT unique" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Simulated body of `Map.put` (lib/map.zap) — receives the map
    // as parameter index 0 and forwards to :zig.Map.put.
    //
    //   [0] param_get %0 = param[0]      -- map parameter
    //   [1] param_get %1 = param[1]      -- key parameter
    //   [2] param_get %2 = param[2]      -- value parameter
    //   [3] move_value %3 <- %0          -- but %0 is a parameter, not unique
    //   [4] call_builtin ":zig.Map.put" args=[%3, %1, %2] dest=%4
    //
    // Expected: uniqueness fails at id 4 — the receiver %3's source is a
    // parameter, whose refcount the callee cannot prove. The user-
    // facing wrapper's call site must use the checked variant.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .param_get = .{ .dest = 2, .index = 2 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    var function = try buildTestFunction(arena, "param_then_put", &instrs, 5);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    try testing.expect(!u.isUnique(4));
}

test "uniqueness: receiver share_value'd to a borrowed call then mutated is NOT unique" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}                  -- fresh, unique
    //   [1] share_value %1 <- %0              -- transient share, %0 no longer unique
    //   [2] call_builtin "Map.size" args=[%1] dest=%2  -- borrowed call, no consume
    //   [3] release %1
    //   [4] const_int %3 = 0
    //   [5] const_int %4 = 0
    //   [6] move_value %5 <- %0               -- %0 was already cleared by share_value
    //   [7] call_builtin "Map.put" args=[%5, %3, %4] dest=%5
    //
    // Expected: uniqueness fails at id 7 — %0 lost uniqueness at the share_value.
    // (Runtime: the share path saw refcount=2, which decreased to 1 after
    // the release at id 3 — but the analysis is conservative and treats
    // the transient bump as "permanently" non-unique.)
    const size_args = try arena.alloc(ir.LocalId, 1);
    size_args[0] = 1;
    const size_modes = try arena.alloc(ir.ValueMode, 1);
    size_modes[0] = .share;
    const put_args = try arena.alloc(ir.LocalId, 3);
    put_args[0] = 5;
    put_args[1] = 3;
    put_args[2] = 4;
    const put_modes = try arena.alloc(ir.ValueMode, 3);
    put_modes[0] = .move;
    put_modes[1] = .borrow;
    put_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 2,
            .name = "Map.size",
            .args = size_args,
            .arg_modes = size_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .const_int = .{ .dest = 4, .value = 0 } },
        .{ .move_value = .{ .dest = 5, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 6,
            .name = "Map.put",
            .args = put_args,
            .arg_modes = put_modes,
        } },
    };
    var function = try buildTestFunction(arena, "shared_then_put", &instrs, 7);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    // The Map.put call_builtin is at id 7.
    try testing.expect(!u.isUnique(7));
}

test "uniqueness: copy_value clears uniqueness on dest" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}
    //   [1] copy_value %1 <- %0           -- emits retain; both refer to refcount>=2 cell
    //   [2] const_int %2 = 0
    //   [3] const_int %3 = 0
    //   [4] move_value %4 <- %1           -- %1 is not unique
    //   [5] call_builtin "Map.put" args=[%4, %2, %3] dest=%5
    //
    // Expected: uniqueness fails at id 5.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 4;
    args[1] = 2;
    args[2] = 3;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .copy_value = .{ .dest = 1, .source = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .move_value = .{ .dest = 4, .source = 1 } },
        .{ .call_builtin = .{
            .dest = 5,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    var function = try buildTestFunction(arena, "copy_then_put", &instrs, 6);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    try testing.expect(!u.isUnique(5));
}

test "uniqueness: List.set and List.push fresh-alloc chain is unique" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream simulating `let mut list = List.new(...); List.set(list, 0, 42)` after
    // Phase 4's move-on-last-use rewrite:
    //
    //   [0] call_builtin "List.new_filled" -> %0       -- runtime returns rc=1
    //   [1] const_int %1 = 0
    //   [2] const_int %2 = 42
    //   [3] move_value %3 <- %0
    //   [4] call_builtin "List.set" args=[%3, %1, %2] dest=%4
    //
    // Expected: uniqueness holds at id 4. List.new_filled is not in the
    // owned-mutating list (it's a constructor), but List.new_filled
    // returns rc=1 by contract. We ALSO need to recognize allocator-
    // style call_builtin results as unique. For the analysis to be
    // useful in real Zap programs the producer-classification has to
    // be expansive enough to cover these constructors.
    //
    // For this phase, recognising List.new_filled as a unique-result
    // builtin is OPTIONAL — the analysis is conservative and falls
    // back to false. The important contract is: AFTER an owned-
    // mutating call, the result IS unique. So this test focuses on
    // the chain List.set -> List.push:
    //
    //   [5] move_value %5 <- %4
    //   [6] const_int %6 = 99
    //   [7] call_builtin "List.push" args=[%5, %6] dest=%7
    //
    // uniqueness must hold at id 7 (the List.push receives the result of
    // an owned-mutating List.set, so uniqueness holds by chain-reasoning).
    const set_args = try arena.alloc(ir.LocalId, 3);
    set_args[0] = 3;
    set_args[1] = 1;
    set_args[2] = 2;
    const set_modes = try arena.alloc(ir.ValueMode, 3);
    set_modes[0] = .move;
    set_modes[1] = .borrow;
    set_modes[2] = .borrow;
    const push_args = try arena.alloc(ir.LocalId, 2);
    push_args[0] = 5;
    push_args[1] = 6;
    const push_modes = try arena.alloc(ir.ValueMode, 2);
    push_modes[0] = .move;
    push_modes[1] = .borrow;
    const ctor_args = try arena.alloc(ir.LocalId, 0);
    const ctor_modes = try arena.alloc(ir.ValueMode, 0);
    const instrs = [_]ir.Instruction{
        .{ .call_builtin = .{
            .dest = 0,
            .name = "List.new_filled",
            .args = ctor_args,
            .arg_modes = ctor_modes,
        } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 42 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "List.set",
            .args = set_args,
            .arg_modes = set_modes,
        } },
        .{ .move_value = .{ .dest = 5, .source = 4 } },
        .{ .const_int = .{ .dest = 6, .value = 99 } },
        .{ .call_builtin = .{
            .dest = 7,
            .name = "List.push",
            .args = push_args,
            .arg_modes = push_modes,
        } },
    };
    var function = try buildTestFunction(arena, "list_chain", &instrs, 8);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    // List.push at id 7 — uniqueness holds because its source is the
    // result of an owned-mutating List.set.
    try testing.expect(u.isUnique(7));
}

test "uniqueness: list_tail records unique source and unique suffix" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const instrs = [_]ir.Instruction{
        .{ .list_init = .{ .dest = 0, .elements = &.{} } },
        .{ .list_tail = .{ .dest = 1, .list = 0, .element_type = .i64 } },
        .{ .move_value = .{ .dest = 2, .source = 1 } },
        .{ .const_int = .{ .dest = 3, .value = 9 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "List.push",
            .args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{ 2, 3 }),
            .arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{ .move, .borrow }),
        } },
    };
    var function = try buildTestFunction(arena, "list_tail_unique", &instrs, 5);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    try testing.expect(u.isUnique(1));
    try testing.expect(u.isUnique(4));
}

test "uniqueness: non-owned-mutating call sites are absent from the result" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}
    //   [1] share_value %1 <- %0
    //   [2] call_builtin "Map.size" args=[%1] dest=%2
    //
    // Expected: id 2 is NOT in the uniqueness result map (Map.size
    // is not owned-mutating). isUnique returns false for absent ids.
    const args = try arena.alloc(ir.LocalId, 1);
    args[0] = 1;
    const arg_modes = try arena.alloc(ir.ValueMode, 1);
    arg_modes[0] = .share;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 2,
            .name = "Map.size",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    var function = try buildTestFunction(arena, "map_size_only", &instrs, 3);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    try testing.expect(!u.isUnique(2));
    try testing.expect(!u.sites.contains(2));
}

/// Phase 2.5 — synthesize a minimal `ArcOwnership` for tests that
/// need to drive `isLastUseAt` queries. Records the `(local, id)`
/// pairs the caller specifies as last-use sites without invoking the
/// real backward dataflow.
fn buildSyntheticOwnership(
    arena: std.mem.Allocator,
    pairs: []const struct { local: ir.LocalId, id: arc_liveness.InstructionId },
) !arc_liveness.ArcOwnership {
    _ = arena;
    var ownership: arc_liveness.ArcOwnership = .{};
    for (pairs) |p| {
        const key = (@as(u64, @intCast(p.local)) << 32) | @as(u64, @intCast(p.id));
        try ownership.last_use_sites.put(testing.allocator, key, {});
    }
    return ownership;
}

test "uniqueness: tuple element extracted at parent's last-use is unique (Phase 2.5)" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}                  -- fresh, unique
    //   [1] tuple_init %1 = {%0}              -- pending entry: comp[0]=true
    //   [2] index_get %2 = %1[0]              -- last-use of %1
    //                                           -> %2 promoted to unique
    //   [3] const_int %3 = 0
    //   [4] const_int %4 = 0
    //   [5] move_value %5 <- %2               -- %2 is unique, transfer
    //   [6] call_builtin "Map.put" args=[%5,%3,%4] dest=%6
    //
    // Expected: uniqueness holds at id 6.
    const tuple_elems = try arena.alloc(ir.LocalId, 1);
    tuple_elems[0] = 0;
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 5;
    args[1] = 3;
    args[2] = 4;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .tuple_init = .{ .dest = 1, .elements = tuple_elems } },
        .{ .index_get = .{ .dest = 2, .object = 1, .index = 0 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .const_int = .{ .dest = 4, .value = 0 } },
        .{ .move_value = .{ .dest = 5, .source = 2 } },
        .{ .call_builtin = .{
            .dest = 6,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    var function = try buildTestFunction(arena, "tuple_destructure", &instrs, 7);

    // The tuple at %1 has its last-use at instruction id 2 (the index_get).
    var ownership = try buildSyntheticOwnership(arena, &.{
        .{ .local = 1, .id = 2 },
    });
    defer ownership.deinit(testing.allocator);

    var u = try analyzeUniquenessFull(testing.allocator, &function, null, null, null, &ownership);
    defer u.deinit(testing.allocator);

    // uniqueness holds at id 6.
    try testing.expect(u.isUnique(6));
}

test "uniqueness: tuple stored in list ALs all components after storage (Phase 2.5)" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}                  -- fresh, unique
    //   [1] tuple_init %1 = {%0}              -- pending entry
    //   [2] const_nil %2
    //   [3] list_cons %3 = [%1 | %2]          -- ESCAPES %1's pending
    //   [4] index_get %4 = %1[0]              -- pending escaped, no promotion
    //   [5] const_int %5 = 0
    //   [6] const_int %6 = 0
    //   [7] move_value %7 <- %4               -- %4 not unique
    //   [8] call_builtin "Map.put" args=[%7,%5,%6] dest=%8
    //
    // Expected: uniqueness fails at id 8 — the tuple's pending entry was
    // dissolved at the list_cons; the index_get afterwards extracts
    // a non-unique component.
    const tuple_elems = try arena.alloc(ir.LocalId, 1);
    tuple_elems[0] = 0;
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 7;
    args[1] = 5;
    args[2] = 6;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .tuple_init = .{ .dest = 1, .elements = tuple_elems } },
        .{ .const_nil = 2 },
        .{ .list_cons = .{ .dest = 3, .head = 1, .tail = 2 } },
        .{ .index_get = .{ .dest = 4, .object = 1, .index = 0 } },
        .{ .const_int = .{ .dest = 5, .value = 0 } },
        .{ .const_int = .{ .dest = 6, .value = 0 } },
        .{ .move_value = .{ .dest = 7, .source = 4 } },
        .{ .call_builtin = .{
            .dest = 8,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    var function = try buildTestFunction(arena, "tuple_in_list", &instrs, 9);

    // The tuple at %1's "last-use" would be the index_get at id 4 if
    // it survived; with list_cons-induced escape, last-use info should
    // not matter. Provide a synthetic ownership where the tuple's
    // last-use is at the index_get; the test verifies escape wins.
    var ownership = try buildSyntheticOwnership(arena, &.{
        .{ .local = 1, .id = 4 },
    });
    defer ownership.deinit(testing.allocator);

    var u = try analyzeUniquenessFull(testing.allocator, &function, null, null, null, &ownership);
    defer u.deinit(testing.allocator);

    try testing.expect(!u.isUnique(8));
}

test "uniqueness: callee tuple-return per-component uniqueness propagates (Phase 2.5)" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Define a callee `id_pair(p) -> {p}` whose signature has
    // return_components[0] = some(0). The caller calls it, then
    // destructures, and uses the extracted local.
    //
    // Caller's stream:
    //   [0] map_init %0 = {}                       -- fresh, unique
    //   [1] move_value %1 <- %0                    -- transfer to the call arg
    //   [2] call_named "id_pair" args=[%1] dest=%2 -- call dest synthesizes pending
    //   [3] index_get %3 = %2[0]                   -- last-use of %2 → %3 unique
    //   [4] const_int %4 = 0
    //   [5] const_int %5 = 0
    //   [6] move_value %6 <- %3                    -- %3 is unique
    //   [7] call_builtin "Map.put" args=[%6,%4,%5] dest=%7
    //
    // Expected: uniqueness holds at id 7.

    // Build the callee function.
    const callee_id: ir.FunctionId = 1;
    const callee_param_conv = try arena.alloc(ir.ParamConvention, 1);
    callee_param_conv[0] = .owned;
    const callee_blocks = try arena.alloc(ir.Block, 1);
    callee_blocks[0] = .{ .label = 0, .instructions = &.{} };
    const callee_ownership = try arena.alloc(ir.OwnershipClass, 0);
    const callee_params = try arena.alloc(ir.Param, 1);
    callee_params[0] = .{ .name = "p", .type_expr = .void };
    const callee = ir.Function{
        .id = callee_id,
        .name = "id_pair",
        .scope_id = 0,
        .arity = 1,
        .params = callee_params,
        .return_type = .void,
        .body = callee_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 0,
        .param_conventions = callee_param_conv,
        .local_ownership = callee_ownership,
        .result_convention = .owned,
    };

    // Build the caller function.
    const caller_call_args = try arena.alloc(ir.LocalId, 1);
    caller_call_args[0] = 1;
    const put_args = try arena.alloc(ir.LocalId, 3);
    put_args[0] = 6;
    put_args[1] = 4;
    put_args[2] = 5;
    const put_modes = try arena.alloc(ir.ValueMode, 3);
    put_modes[0] = .move;
    put_modes[1] = .borrow;
    put_modes[2] = .borrow;
    const caller_instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .call_named = .{
            .dest = 2,
            .name = "id_pair",
            .args = caller_call_args,
            .arg_modes = &.{},
        } },
        .{ .index_get = .{ .dest = 3, .object = 2, .index = 0 } },
        .{ .const_int = .{ .dest = 4, .value = 0 } },
        .{ .const_int = .{ .dest = 5, .value = 0 } },
        .{ .move_value = .{ .dest = 6, .source = 3 } },
        .{ .call_builtin = .{
            .dest = 7,
            .name = "Map.put",
            .args = put_args,
            .arg_modes = put_modes,
        } },
    };
    var caller = try buildTestFunction(arena, "caller", &caller_instrs, 8);
    caller.id = 0;

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = caller;
    functions[1] = callee;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    // Build a minimal ProgramSignatures table that records:
    //   * id_pair's params[0] = preserves_uniqueness with witness 0
    //   * id_pair's return_components = [some(0)]
    var signatures = uniqueness_signature.ProgramSignatures.init(testing.allocator);
    defer signatures.deinit(testing.allocator);
    {
        const arena_alloc = signatures.arena.allocator();
        const params = try arena_alloc.alloc(uniqueness_signature.ParamSig, 1);
        params[0] = uniqueness_signature.ParamSig.preservesUniqueness(0);
        const rc = try arena_alloc.alloc(?u8, 1);
        rc[0] = 0;
        try signatures.by_function.put(testing.allocator, callee_id, .{
            .params = params,
            .return_components = rc,
        });
    }

    // The call dest %2's last-use is at the index_get (id 3 in the
    // caller's instruction stream).
    var ownership = try buildSyntheticOwnership(arena, &.{
        .{ .local = 2, .id = 3 },
    });
    defer ownership.deinit(testing.allocator);

    var u = try analyzeUniquenessFull(testing.allocator, &caller, &program, null, &signatures, &ownership);
    defer u.deinit(testing.allocator);

    try testing.expect(u.isUnique(7));
}

test "uniqueness: param_get becomes unique when fixpoint says unique-on-entry" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Wrapper function shape — Map.put forwarder. Slot 0 is .owned.
    //   [0] param_get %0 <- param[0]    -- map parameter
    //   [1] move_value %1 <- %0
    //   [2] const_int %2 = 0
    //   [3] const_int %3 = 0
    //   [4] call_builtin "Map.put" args=[%1, %2, %3] dest=%4
    //   [5] ret %4
    //
    // Without fixpoint: uniqueness fails at id 4 (param_get clears uniqueness;
    // %1's source is non-unique; the original conservative behaviour).
    //
    // With fixpoint (slot 0 unique-on-entry): uniqueness holds at id 4.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 1;
    args[1] = 2;
    args[2] = 3;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .ret = .{ .value = 4 } },
    };
    const conventions = [_]ir.ParamConvention{.owned};
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &instrs),
    };
    const ownership = try arena.alloc(ir.OwnershipClass, 5);
    for (ownership) |*o| o.* = .owned;
    const params = try arena.alloc(ir.Param, 1);
    params[0] = .{ .name = "m", .type_expr = .void };
    const function = ir.Function{
        .id = 0,
        .name = "wrapper",
        .scope_id = 0,
        .arity = 1,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = try arena.dupe(ir.ParamConvention, &conventions),
        .local_ownership = ownership,
        .result_convention = .owned,
    };

    // Without fixpoint: uniqueness should fail.
    {
        var u = try analyzeUniqueness(testing.allocator, &function, null);
        defer u.deinit(testing.allocator);
        try testing.expect(!u.isUnique(4));
    }

    // With fixpoint that says slot 0 is unique-on-entry: uniqueness holds.
    {
        var fixpoint: uniqueness_interprocedural.ProgramUniqueness = .{};
        defer fixpoint.deinit(testing.allocator);
        const slots = try testing.allocator.alloc(bool, 1);
        slots[0] = true;
        try fixpoint.by_function.put(testing.allocator, 0, slots);

        var u = try analyzeUniquenessWithFixpoint(testing.allocator, &function, null, &fixpoint);
        defer u.deinit(testing.allocator);
        try testing.expect(u.isUnique(4));
    }
}

test "uniqueness: list_cons whose tail is at last-use produces a unique dest" {
    // Phase F gap-analysis item #2 — the `acc = [x | acc]` accumulator
    // pattern. When the local feeding `list_cons.tail` is at last-use
    // path-sensitively (so the runtime's rc-1 in-place fast path from
    // commit `fb32ef1` can fire), the analyzer must still classify
    // `lc.dest` as unique so the downstream `List.push`/`List.set`
    // chain hits its own owned-mutating fast paths. Without this,
    // long-running accumulators built via `[x | acc]` would force the
    // checked variants at every iteration and the rc-1 in-place fast
    // path would never realise as a uniqueness witness on its result.
    //
    // Stream (mirroring the IR after `shouldMoveIntoAggregate` has
    // lowered the `.local_get` for the tail to `.move_value`):
    //   [0] list_init %0 = []                  -- fresh, unique tail-seed
    //   [1] const_int %1 = 7                   -- new head element
    //   [2] move_value %2 <- %0                -- tail at last-use
    //   [3] list_cons %3 = [%1 | %2]           -- consumes %2
    //   [4] const_int %4 = 11                  -- next push element
    //   [5] move_value %5 <- %3                -- transfer dest's uniqueness
    //   [6] call_builtin "List.push" args=[%5, %4] dest=%6
    //
    // Expected: uniqueness holds at id 6 — the List.push receiver %5
    // was move_value'd from %3 (`lc.dest`), and `lc.dest` is unique by
    // runtime contract (rc-1 in-place when tail was rc=1, fresh-rc-1
    // deep clone otherwise).
    //
    // This test pins the dest-is-unique outcome; the path-sensitive
    // escape suppression that the matching fix introduces affects
    // tuple_pending state on the tail rather than the dest's
    // uniqueness directly, but the regression guard ensures the
    // accumulator chain stays sound across future refactors of the
    // `.list_cons` handler.
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const push_args = try arena.alloc(ir.LocalId, 2);
    push_args[0] = 5;
    push_args[1] = 4;
    const push_modes = try arena.alloc(ir.ValueMode, 2);
    push_modes[0] = .move;
    push_modes[1] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .list_init = .{ .dest = 0, .elements = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 7 } },
        .{ .move_value = .{ .dest = 2, .source = 0 } },
        .{ .list_cons = .{ .dest = 3, .head = 1, .tail = 2 } },
        .{ .const_int = .{ .dest = 4, .value = 11 } },
        .{ .move_value = .{ .dest = 5, .source = 3 } },
        .{ .call_builtin = .{
            .dest = 6,
            .name = "List.push",
            .args = push_args,
            .arg_modes = push_modes,
        } },
    };
    var function = try buildTestFunction(arena, "list_cons_tail_last_use", &instrs, 7);

    // Record %2 as at last-use at the `list_cons` instruction (id 3).
    var ownership = try buildSyntheticOwnership(arena, &.{
        .{ .local = 2, .id = 3 },
    });
    defer ownership.deinit(testing.allocator);

    var u = try analyzeUniquenessFull(testing.allocator, &function, null, null, null, &ownership);
    defer u.deinit(testing.allocator);

    // List.push at id 6 must observe a unique receiver.
    try testing.expect(u.isUnique(6));
}
