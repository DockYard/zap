//! Compile-Time Function Execution (CTFE)
//!
//! A typed IR interpreter that executes Zap IR at compile time.
//! Uses a recursive tree-walker over structured IR (not flat CFG).
//!
//! Two value layers:
//!   - CtValue: interpreter-internal values during execution
//!   - ConstValue: stable compiler-facing results exported from CTFE

const std = @import("std");
const ir = @import("ir.zig");
const ast = @import("ast.zig");
const env = @import("env.zig");
const glob = @import("glob.zig");
const build_cache = @import("build_cache.zig");

const VALUE_TRAVERSAL_INLINE_STACK_CAPACITY = 128;
const MAX_VALUE_TRAVERSAL_DEPTH = 4096;
const MAX_VALUE_TRAVERSAL_NODES = 1_000_000;

pub const ValueTraversalError = error{
    ValueTraversalDepthExceeded,
    ValueTraversalBudgetExceeded,
    OutOfMemory,
};

fn InlineTraversalStack(comptime T: type) type {
    return struct {
        inline_items: [VALUE_TRAVERSAL_INLINE_STACK_CAPACITY]T = undefined,
        len: usize = 0,
        spill: std.ArrayListUnmanaged(T) = .empty,

        const Self = @This();

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.spill.deinit(allocator);
        }

        fn push(self: *Self, allocator: std.mem.Allocator, item: T) error{OutOfMemory}!void {
            if (self.len < self.inline_items.len) {
                self.inline_items[self.len] = item;
            } else {
                try self.spill.append(allocator, item);
            }
            self.len += 1;
        }

        fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            if (self.len > self.inline_items.len) {
                self.len -= 1;
                const item = self.spill.items[self.spill.items.len - 1];
                self.spill.items.len -= 1;
                return item;
            }
            self.len -= 1;
            return self.inline_items[self.len];
        }
    };
}

const ValueTraversalBudget = struct {
    visited_nodes: usize = 0,

    fn visit(self: *ValueTraversalBudget, depth: usize) ValueTraversalError!void {
        if (depth > MAX_VALUE_TRAVERSAL_DEPTH) return error.ValueTraversalDepthExceeded;
        if (self.visited_nodes >= MAX_VALUE_TRAVERSAL_NODES) return error.ValueTraversalBudgetExceeded;
        self.visited_nodes += 1;
    }

    fn ensureChildren(self: *ValueTraversalBudget, depth: usize, child_count: usize) ValueTraversalError!void {
        if (child_count == 0) return;
        if (depth >= MAX_VALUE_TRAVERSAL_DEPTH) return error.ValueTraversalDepthExceeded;
        const remaining_nodes = MAX_VALUE_TRAVERSAL_NODES - self.visited_nodes;
        if (child_count > remaining_nodes) return error.ValueTraversalBudgetExceeded;
    }
};

fn checkedChildCount(count: usize, multiplier: usize) ValueTraversalError!usize {
    return std.math.mul(usize, count, multiplier) catch return error.ValueTraversalBudgetExceeded;
}

// ============================================================
// Symbolic Memory Model
//
// Aggregates created during CTFE are tracked via AllocId to preserve
// a clear separation between interpreter memory and host memory.
// Values are stored by-value (no pointer indirection) but each
// allocation is registered for provenance tracking.
// ============================================================

pub const AllocId = u32;

pub const AllocationRecord = struct {
    id: AllocId,
    kind: AllocKind,
    /// Source location (function + instruction) that created this allocation
    source_function: ?ir.FunctionId = null,
};

pub const AllocKind = enum {
    tuple,
    list,
    map,
    struct_val,
    union_val,
    closure,
    string_concat,
};

pub const AllocationStore = struct {
    next_id: AllocId = 1,
    records: std.ArrayListUnmanaged(AllocationRecord) = .empty,

    pub fn alloc(self: *AllocationStore, allocator: std.mem.Allocator, kind: AllocKind, source_fn: ?ir.FunctionId) std.mem.Allocator.Error!AllocId {
        const id = self.next_id;
        try self.records.append(allocator, .{
            .id = id,
            .kind = kind,
            .source_function = source_fn,
        });
        self.next_id += 1;
        return id;
    }

    pub fn deinit(self: *AllocationStore, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
    }

    pub fn count(self: *const AllocationStore) u32 {
        return self.next_id - 1;
    }
};

// ============================================================
// CtValue — interpreter-internal value type
// ============================================================

pub const CtValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
    atom: []const u8,
    nil,
    void,
    consumed,
    reuse_token: CtReuseToken,
    tuple: CtTupleValue,
    list: CtListValue,
    map: CtMapValue,
    struct_val: CtStructValue,
    union_val: CtUnionValue,
    enum_val: CtEnumValue,
    optional: CtOptional,
    closure: CtClosureValue,

    pub const CtMapEntry = struct {
        key: CtValue,
        value: CtValue,
    };

    pub const CtTupleValue = struct {
        alloc_id: AllocId,
        elems: []const CtValue,
    };

    pub const CtListValue = struct {
        alloc_id: AllocId,
        elems: []const CtValue,
    };

    pub const CtMapValue = struct {
        alloc_id: AllocId,
        entries: []const CtMapEntry,
    };

    pub const CtReuseToken = struct {
        alloc_id: AllocId,
        kind: AllocKind,
    };

    pub const CtStructValue = struct {
        alloc_id: AllocId,
        type_name: []const u8,
        fields: []const CtFieldValue,
    };

    pub const CtFieldValue = struct {
        name: []const u8,
        value: CtValue,
    };

    pub const CtUnionValue = struct {
        alloc_id: AllocId,
        type_name: []const u8,
        variant: []const u8,
        payload: *const CtValue,
    };

    pub const CtEnumValue = struct {
        type_name: []const u8,
        variant: []const u8,
    };

    pub const CtOptional = struct {
        value: ?*const CtValue,
    };

    pub const CtClosureValue = struct {
        alloc_id: AllocId,
        function_id: ir.FunctionId,
        captures: []const CtValue,
    };

    /// Evaluate truthiness for condition checks.
    pub fn isTruthy(self: CtValue) bool {
        return switch (self) {
            .bool_val => |b| b,
            .nil => false,
            .void => false,
            .consumed => false,
            .reuse_token => false,
            .int => |i| i != 0,
            .optional => |o| o.value != null,
            else => true,
        };
    }

    /// Value equality for matching and comparisons.
    pub fn eql(self: CtValue, other: CtValue) ValueTraversalError!bool {
        return self.eqlWithAllocator(std.heap.page_allocator, other);
    }

    pub fn eqlWithAllocator(self: CtValue, allocator: std.mem.Allocator, other: CtValue) ValueTraversalError!bool {
        const CompareFrame = struct {
            left: CtValue,
            right: CtValue,
            depth: usize,
        };
        const SequenceFrame = struct {
            left: []const CtValue,
            right: []const CtValue,
            index: usize,
            depth: usize,
        };
        const MapSearchFrame = struct {
            left: []const CtValue.CtMapEntry,
            right: []const CtValue.CtMapEntry,
            left_index: usize,
            right_index: usize,
            depth: usize,
        };
        const StructSearchFrame = struct {
            left: []const CtValue.CtFieldValue,
            right: []const CtValue.CtFieldValue,
            left_index: usize,
            right_index: usize,
            depth: usize,
        };
        const EqlFrame = union(enum) {
            compare: CompareFrame,
            sequence_next: SequenceFrame,
            sequence_after_value: SequenceFrame,
            map_search: MapSearchFrame,
            map_after_key: MapSearchFrame,
            map_after_value: MapSearchFrame,
            struct_search: StructSearchFrame,
            struct_after_value: StructSearchFrame,
        };

        var budget = ValueTraversalBudget{};
        var stack = InlineTraversalStack(EqlFrame){};
        defer stack.deinit(allocator);

        try stack.push(allocator, .{ .compare = .{ .left = self, .right = other, .depth = 1 } });
        var last_result = false;

        while (stack.pop()) |frame| {
            switch (frame) {
                .compare => |pair| {
                    try budget.visit(pair.depth);
                    const left_tag = std.meta.activeTag(pair.left);
                    const right_tag = std.meta.activeTag(pair.right);
                    if (left_tag != right_tag) {
                        last_result = false;
                        continue;
                    }

                    switch (pair.left) {
                        .int => |left_value| last_result = left_value == pair.right.int,
                        .float => |left_value| last_result = left_value == pair.right.float,
                        .string => |left_value| last_result = std.mem.eql(u8, left_value, pair.right.string),
                        .bool_val => |left_value| last_result = left_value == pair.right.bool_val,
                        .atom => |left_value| last_result = std.mem.eql(u8, left_value, pair.right.atom),
                        .nil, .void, .consumed => last_result = true,
                        .reuse_token => |left_value| {
                            const right_value = pair.right.reuse_token;
                            last_result = left_value.alloc_id == right_value.alloc_id and left_value.kind == right_value.kind;
                        },
                        .tuple => |left_value| {
                            const right_value = pair.right.tuple;
                            if (left_value.elems.len != right_value.elems.len) return false;
                            try budget.ensureChildren(pair.depth, left_value.elems.len);
                            try stack.push(allocator, .{ .sequence_next = .{
                                .left = left_value.elems,
                                .right = right_value.elems,
                                .index = 0,
                                .depth = pair.depth,
                            } });
                        },
                        .list => |left_value| {
                            const right_value = pair.right.list;
                            if (left_value.elems.len != right_value.elems.len) return false;
                            try budget.ensureChildren(pair.depth, left_value.elems.len);
                            try stack.push(allocator, .{ .sequence_next = .{
                                .left = left_value.elems,
                                .right = right_value.elems,
                                .index = 0,
                                .depth = pair.depth,
                            } });
                        },
                        .map => |left_value| {
                            const right_value = pair.right.map;
                            if (left_value.entries.len != right_value.entries.len) return false;
                            try budget.ensureChildren(pair.depth, try checkedChildCount(left_value.entries.len, 2));
                            try stack.push(allocator, .{ .map_search = .{
                                .left = left_value.entries,
                                .right = right_value.entries,
                                .left_index = 0,
                                .right_index = 0,
                                .depth = pair.depth,
                            } });
                        },
                        .struct_val => |left_value| {
                            const right_value = pair.right.struct_val;
                            if (!std.mem.eql(u8, left_value.type_name, right_value.type_name)) return false;
                            if (left_value.fields.len != right_value.fields.len) return false;
                            try budget.ensureChildren(pair.depth, left_value.fields.len);
                            try stack.push(allocator, .{ .struct_search = .{
                                .left = left_value.fields,
                                .right = right_value.fields,
                                .left_index = 0,
                                .right_index = 0,
                                .depth = pair.depth,
                            } });
                        },
                        .enum_val => |left_value| {
                            const right_value = pair.right.enum_val;
                            last_result = std.mem.eql(u8, left_value.type_name, right_value.type_name) and
                                std.mem.eql(u8, left_value.variant, right_value.variant);
                        },
                        .union_val => |left_value| {
                            const right_value = pair.right.union_val;
                            if (!std.mem.eql(u8, left_value.type_name, right_value.type_name) or
                                !std.mem.eql(u8, left_value.variant, right_value.variant))
                            {
                                return false;
                            }
                            try budget.ensureChildren(pair.depth, 1);
                            try stack.push(allocator, .{ .compare = .{
                                .left = left_value.payload.*,
                                .right = right_value.payload.*,
                                .depth = pair.depth + 1,
                            } });
                        },
                        .optional => |left_value| {
                            const right_value = pair.right.optional;
                            if (left_value.value == null and right_value.value == null) {
                                last_result = true;
                            } else if (left_value.value != null and right_value.value != null) {
                                try budget.ensureChildren(pair.depth, 1);
                                try stack.push(allocator, .{ .compare = .{
                                    .left = left_value.value.?.*,
                                    .right = right_value.value.?.*,
                                    .depth = pair.depth + 1,
                                } });
                            } else {
                                last_result = false;
                            }
                        },
                        .closure => last_result = false,
                    }
                },
                .sequence_next => |sequence| {
                    if (sequence.index >= sequence.left.len) {
                        last_result = true;
                        continue;
                    }
                    try stack.push(allocator, .{ .sequence_after_value = sequence });
                    try stack.push(allocator, .{ .compare = .{
                        .left = sequence.left[sequence.index],
                        .right = sequence.right[sequence.index],
                        .depth = sequence.depth + 1,
                    } });
                },
                .sequence_after_value => |sequence| {
                    if (!last_result) return false;
                    try stack.push(allocator, .{ .sequence_next = .{
                        .left = sequence.left,
                        .right = sequence.right,
                        .index = sequence.index + 1,
                        .depth = sequence.depth,
                    } });
                },
                .map_search => |search| {
                    if (search.left_index >= search.left.len) {
                        last_result = true;
                        continue;
                    }
                    if (search.right_index >= search.right.len) return false;
                    try stack.push(allocator, .{ .map_after_key = search });
                    try stack.push(allocator, .{ .compare = .{
                        .left = search.left[search.left_index].key,
                        .right = search.right[search.right_index].key,
                        .depth = search.depth + 1,
                    } });
                },
                .map_after_key => |search| {
                    if (last_result) {
                        try stack.push(allocator, .{ .map_after_value = search });
                        try stack.push(allocator, .{ .compare = .{
                            .left = search.left[search.left_index].value,
                            .right = search.right[search.right_index].value,
                            .depth = search.depth + 1,
                        } });
                    } else {
                        try stack.push(allocator, .{ .map_search = .{
                            .left = search.left,
                            .right = search.right,
                            .left_index = search.left_index,
                            .right_index = search.right_index + 1,
                            .depth = search.depth,
                        } });
                    }
                },
                .map_after_value => |search| {
                    if (last_result) {
                        try stack.push(allocator, .{ .map_search = .{
                            .left = search.left,
                            .right = search.right,
                            .left_index = search.left_index + 1,
                            .right_index = 0,
                            .depth = search.depth,
                        } });
                    } else {
                        try stack.push(allocator, .{ .map_search = .{
                            .left = search.left,
                            .right = search.right,
                            .left_index = search.left_index,
                            .right_index = search.right_index + 1,
                            .depth = search.depth,
                        } });
                    }
                },
                .struct_search => |search| {
                    if (search.left_index >= search.left.len) {
                        last_result = true;
                        continue;
                    }
                    var candidate_index = search.right_index;
                    while (candidate_index < search.right.len and
                        !std.mem.eql(u8, search.left[search.left_index].name, search.right[candidate_index].name))
                    {
                        candidate_index += 1;
                    }
                    if (candidate_index >= search.right.len) return false;
                    try stack.push(allocator, .{ .struct_after_value = .{
                        .left = search.left,
                        .right = search.right,
                        .left_index = search.left_index,
                        .right_index = candidate_index,
                        .depth = search.depth,
                    } });
                    try stack.push(allocator, .{ .compare = .{
                        .left = search.left[search.left_index].value,
                        .right = search.right[candidate_index].value,
                        .depth = search.depth + 1,
                    } });
                },
                .struct_after_value => |search| {
                    if (last_result) {
                        try stack.push(allocator, .{ .struct_search = .{
                            .left = search.left,
                            .right = search.right,
                            .left_index = search.left_index + 1,
                            .right_index = 0,
                            .depth = search.depth,
                        } });
                    } else {
                        try stack.push(allocator, .{ .struct_search = .{
                            .left = search.left,
                            .right = search.right,
                            .left_index = search.left_index,
                            .right_index = search.right_index + 1,
                            .depth = search.depth,
                        } });
                    }
                },
            }
        }

        return last_result;
    }

    /// Compare for ordering (lt/gt/lte/gte). Returns null if incomparable.
    pub fn compare(self: CtValue, other: CtValue) ?std.math.Order {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return null;

        return switch (self) {
            .int => |a| std.math.order(a, other.int),
            .float => |a| std.math.order(a, other.float),
            .string => |a| std.mem.order(u8, a, other.string),
            .atom => |a| std.mem.order(u8, a, other.atom),
            else => null,
        };
    }

    /// Hash a CtValue for memoization cache keys.
    pub fn hash(self: CtValue, allocator: std.mem.Allocator) ValueTraversalError!u64 {
        var hasher = std.hash.Wyhash.init(0);
        try self.hashInto(allocator, &hasher);
        return hasher.final();
    }

    fn hashInto(self: CtValue, allocator: std.mem.Allocator, hasher: *std.hash.Wyhash) ValueTraversalError!void {
        const HashValueFrame = struct {
            value: CtValue,
            depth: usize,
        };
        const HashFrame = union(enum) {
            value: HashValueFrame,
            bytes: []const u8,
        };

        var budget = ValueTraversalBudget{};
        var stack = InlineTraversalStack(HashFrame){};
        defer stack.deinit(allocator);

        try stack.push(allocator, .{ .value = .{ .value = self, .depth = 1 } });

        while (stack.pop()) |frame| {
            switch (frame) {
                .bytes => |bytes| hasher.update(bytes),
                .value => |value_frame| {
                    try budget.visit(value_frame.depth);
                    const tag_byte = [_]u8{@intFromEnum(std.meta.activeTag(value_frame.value))};
                    hasher.update(&tag_byte);
                    switch (value_frame.value) {
                        .int => |value| hasher.update(std.mem.asBytes(&value)),
                        .float => |value| hasher.update(std.mem.asBytes(&value)),
                        .string => |value| hasher.update(value),
                        .bool_val => |value| hasher.update(&[_]u8{@intFromBool(value)}),
                        .atom => |value| hasher.update(value),
                        .nil, .void, .consumed => {},
                        .reuse_token => |reuse_token| {
                            hasher.update(std.mem.asBytes(&reuse_token.alloc_id));
                            hasher.update(&[_]u8{@intFromEnum(reuse_token.kind)});
                        },
                        .tuple => |tuple_value| {
                            try budget.ensureChildren(value_frame.depth, tuple_value.elems.len);
                            var index = tuple_value.elems.len;
                            while (index > 0) {
                                index -= 1;
                                try stack.push(allocator, .{ .value = .{
                                    .value = tuple_value.elems[index],
                                    .depth = value_frame.depth + 1,
                                } });
                            }
                        },
                        .list => |list_value| {
                            try budget.ensureChildren(value_frame.depth, list_value.elems.len);
                            var index = list_value.elems.len;
                            while (index > 0) {
                                index -= 1;
                                try stack.push(allocator, .{ .value = .{
                                    .value = list_value.elems[index],
                                    .depth = value_frame.depth + 1,
                                } });
                            }
                        },
                        .map => |map_value| {
                            try budget.ensureChildren(value_frame.depth, try checkedChildCount(map_value.entries.len, 2));
                            var index = map_value.entries.len;
                            while (index > 0) {
                                index -= 1;
                                const entry = map_value.entries[index];
                                try stack.push(allocator, .{ .value = .{ .value = entry.value, .depth = value_frame.depth + 1 } });
                                try stack.push(allocator, .{ .value = .{ .value = entry.key, .depth = value_frame.depth + 1 } });
                            }
                        },
                        .struct_val => |struct_value| {
                            hasher.update(struct_value.type_name);
                            try budget.ensureChildren(value_frame.depth, struct_value.fields.len);
                            var index = struct_value.fields.len;
                            while (index > 0) {
                                index -= 1;
                                const field = struct_value.fields[index];
                                try stack.push(allocator, .{ .value = .{ .value = field.value, .depth = value_frame.depth + 1 } });
                                try stack.push(allocator, .{ .bytes = field.name });
                            }
                        },
                        .union_val => |union_value| {
                            hasher.update(union_value.type_name);
                            hasher.update(union_value.variant);
                            try budget.ensureChildren(value_frame.depth, 1);
                            try stack.push(allocator, .{ .value = .{
                                .value = union_value.payload.*,
                                .depth = value_frame.depth + 1,
                            } });
                        },
                        .enum_val => |enum_value| {
                            hasher.update(enum_value.type_name);
                            hasher.update(enum_value.variant);
                        },
                        .optional => |optional_value| {
                            if (optional_value.value) |child_value| {
                                try budget.ensureChildren(value_frame.depth, 1);
                                try stack.push(allocator, .{ .value = .{
                                    .value = child_value.*,
                                    .depth = value_frame.depth + 1,
                                } });
                            }
                        },
                        .closure => |closure_value| {
                            hasher.update(std.mem.asBytes(&closure_value.function_id));
                            try budget.ensureChildren(value_frame.depth, closure_value.captures.len);
                            var index = closure_value.captures.len;
                            while (index > 0) {
                                index -= 1;
                                try stack.push(allocator, .{ .value = .{
                                    .value = closure_value.captures[index],
                                    .depth = value_frame.depth + 1,
                                } });
                            }
                        },
                    }
                },
            }
        }
    }
};

fn initCtValueSlots(values: []CtValue) void {
    for (values) |*value| {
        value.* = .void;
    }
}

fn initCtMapEntries(entries: []CtValue.CtMapEntry) void {
    for (entries) |*entry| {
        entry.* = .{
            .key = .void,
            .value = .void,
        };
    }
}

fn initCtFieldValues(fields: []CtValue.CtFieldValue) void {
    for (fields) |*field| {
        field.* = .{
            .name = "",
            .value = .void,
        };
    }
}

fn freeUncommittedCtValueSlots(
    alloc: std.mem.Allocator,
    values: []CtValue,
    initialized_count: usize,
) void {
    std.debug.assert(initialized_count <= values.len);
    for (values[0..initialized_count]) |*value| {
        value.* = .void;
    }
    if (values.len > 0) alloc.free(values);
}

fn freeUncommittedCtMapEntries(
    alloc: std.mem.Allocator,
    entries: []CtValue.CtMapEntry,
    initialized_count: usize,
) void {
    std.debug.assert(initialized_count <= entries.len);
    for (entries[0..initialized_count]) |*entry| {
        entry.* = .{
            .key = .void,
            .value = .void,
        };
    }
    if (entries.len > 0) alloc.free(entries);
}

fn freeUncommittedCtFieldValues(
    alloc: std.mem.Allocator,
    fields: []CtValue.CtFieldValue,
    initialized_count: usize,
) void {
    std.debug.assert(initialized_count <= fields.len);
    for (fields[0..initialized_count]) |*field| {
        field.* = .{
            .name = "",
            .value = .void,
        };
    }
    if (fields.len > 0) alloc.free(fields);
}

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

    fn deinit(self: ExtractedStructRefName, alloc: std.mem.Allocator) void {
        switch (self) {
            .borrowed => {},
            .owned => |name| alloc.free(name),
        }
    }
};

fn deinitOwnedCtValueSlice(alloc: std.mem.Allocator, values: []const CtValue) void {
    for (values) |value| {
        deinitOwnedCtValue(alloc, value);
    }
}

fn deinitOwnedCtMapEntries(alloc: std.mem.Allocator, entries: []const CtValue.CtMapEntry) void {
    for (entries) |entry| {
        deinitOwnedCtValue(alloc, entry.key);
        deinitOwnedCtValue(alloc, entry.value);
    }
}

fn deinitOwnedCtFieldValues(alloc: std.mem.Allocator, fields: []const CtValue.CtFieldValue) void {
    for (fields) |field| {
        deinitOwnedCtValue(alloc, field.value);
    }
}

fn deinitOwnedCtValue(alloc: std.mem.Allocator, value: CtValue) void {
    switch (value) {
        .tuple => |tuple_value| {
            deinitOwnedCtValueSlice(alloc, tuple_value.elems);
            if (tuple_value.elems.len > 0) alloc.free(tuple_value.elems);
        },
        .list => |list_value| {
            deinitOwnedCtValueSlice(alloc, list_value.elems);
            if (list_value.elems.len > 0) alloc.free(list_value.elems);
        },
        .map => |map_value| {
            deinitOwnedCtMapEntries(alloc, map_value.entries);
            if (map_value.entries.len > 0) alloc.free(map_value.entries);
        },
        .struct_val => |struct_value| {
            deinitOwnedCtFieldValues(alloc, struct_value.fields);
            if (struct_value.fields.len > 0) alloc.free(struct_value.fields);
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
        .union_val,
        .enum_val,
        .optional,
        .closure,
        => {},
    }
}

fn deinitMemoizedCtValueSlice(alloc: std.mem.Allocator, values: []const CtValue) void {
    for (values) |value| {
        deinitMemoizedCtValue(alloc, value);
    }
}

fn deinitMemoizedCtMapEntries(alloc: std.mem.Allocator, entries: []const CtValue.CtMapEntry) void {
    for (entries) |entry| {
        deinitMemoizedCtValue(alloc, entry.key);
        deinitMemoizedCtValue(alloc, entry.value);
    }
}

fn deinitMemoizedCtFieldValues(alloc: std.mem.Allocator, fields: []const CtValue.CtFieldValue) void {
    for (fields) |field| {
        alloc.free(field.name);
        deinitMemoizedCtValue(alloc, field.value);
    }
}

fn deinitMemoizedCtValue(alloc: std.mem.Allocator, value: CtValue) void {
    switch (value) {
        .string, .atom => |bytes| alloc.free(bytes),
        .tuple => |tuple_value| {
            deinitMemoizedCtValueSlice(alloc, tuple_value.elems);
            alloc.free(tuple_value.elems);
        },
        .list => |list_value| {
            deinitMemoizedCtValueSlice(alloc, list_value.elems);
            alloc.free(list_value.elems);
        },
        .map => |map_value| {
            deinitMemoizedCtMapEntries(alloc, map_value.entries);
            alloc.free(map_value.entries);
        },
        .struct_val => |struct_value| {
            alloc.free(struct_value.type_name);
            deinitMemoizedCtFieldValues(alloc, struct_value.fields);
            alloc.free(struct_value.fields);
        },
        .union_val => |union_value| {
            alloc.free(union_value.type_name);
            alloc.free(union_value.variant);
            deinitMemoizedCtValue(alloc, union_value.payload.*);
            alloc.destroy(union_value.payload);
        },
        .enum_val => |enum_value| {
            alloc.free(enum_value.type_name);
            alloc.free(enum_value.variant);
        },
        .optional => |optional_value| {
            if (optional_value.value) |payload| {
                deinitMemoizedCtValue(alloc, payload.*);
                alloc.destroy(payload);
            }
        },
        .closure => |closure_value| {
            deinitMemoizedCtValueSlice(alloc, closure_value.captures);
            alloc.free(closure_value.captures);
        },
        .int,
        .float,
        .bool_val,
        .nil,
        .void,
        .consumed,
        .reuse_token,
        => {},
    }
}

fn cloneCtValueForMemo(alloc: std.mem.Allocator, value: CtValue) ValueTraversalError!CtValue {
    const CloneFrame = struct {
        source: CtValue,
        dest: *CtValue,
        depth: usize,
    };

    var budget = ValueTraversalBudget{};
    var stack = InlineTraversalStack(CloneFrame){};
    defer stack.deinit(alloc);

    var cloned_root: CtValue = .void;
    errdefer deinitMemoizedCtValue(alloc, cloned_root);
    try stack.push(alloc, .{ .source = value, .dest = &cloned_root, .depth = 1 });

    while (stack.pop()) |frame| {
        try budget.visit(frame.depth);
        switch (frame.source) {
            .int => |int_value| frame.dest.* = .{ .int = int_value },
            .float => |float_value| frame.dest.* = .{ .float = float_value },
            .string => |string_value| frame.dest.* = .{ .string = try alloc.dupe(u8, string_value) },
            .bool_val => |bool_value| frame.dest.* = .{ .bool_val = bool_value },
            .atom => |atom_value| frame.dest.* = .{ .atom = try alloc.dupe(u8, atom_value) },
            .nil => frame.dest.* = .nil,
            .void => frame.dest.* = .void,
            .consumed => frame.dest.* = .consumed,
            .reuse_token => |reuse_token| frame.dest.* = .{ .reuse_token = reuse_token },
            .tuple => |tuple_value| {
                try budget.ensureChildren(frame.depth, tuple_value.elems.len);
                const cloned_elems = try alloc.alloc(CtValue, tuple_value.elems.len);
                initCtValueSlots(cloned_elems);
                frame.dest.* = .{ .tuple = .{ .alloc_id = tuple_value.alloc_id, .elems = cloned_elems } };
                var index = tuple_value.elems.len;
                while (index > 0) {
                    index -= 1;
                    try stack.push(alloc, .{
                        .source = tuple_value.elems[index],
                        .dest = &cloned_elems[index],
                        .depth = frame.depth + 1,
                    });
                }
            },
            .list => |list_value| {
                try budget.ensureChildren(frame.depth, list_value.elems.len);
                const cloned_elems = try alloc.alloc(CtValue, list_value.elems.len);
                initCtValueSlots(cloned_elems);
                frame.dest.* = .{ .list = .{ .alloc_id = list_value.alloc_id, .elems = cloned_elems } };
                var index = list_value.elems.len;
                while (index > 0) {
                    index -= 1;
                    try stack.push(alloc, .{
                        .source = list_value.elems[index],
                        .dest = &cloned_elems[index],
                        .depth = frame.depth + 1,
                    });
                }
            },
            .map => |map_value| {
                try budget.ensureChildren(frame.depth, try checkedChildCount(map_value.entries.len, 2));
                const cloned_entries = try alloc.alloc(CtValue.CtMapEntry, map_value.entries.len);
                initCtMapEntries(cloned_entries);
                frame.dest.* = .{ .map = .{ .alloc_id = map_value.alloc_id, .entries = cloned_entries } };
                var index = map_value.entries.len;
                while (index > 0) {
                    index -= 1;
                    try stack.push(alloc, .{
                        .source = map_value.entries[index].value,
                        .dest = &cloned_entries[index].value,
                        .depth = frame.depth + 1,
                    });
                    try stack.push(alloc, .{
                        .source = map_value.entries[index].key,
                        .dest = &cloned_entries[index].key,
                        .depth = frame.depth + 1,
                    });
                }
            },
            .struct_val => |struct_value| {
                try budget.ensureChildren(frame.depth, struct_value.fields.len);
                const cloned_type_name = try alloc.dupe(u8, struct_value.type_name);
                var type_name_transferred = false;
                errdefer if (!type_name_transferred) alloc.free(cloned_type_name);

                const cloned_fields = try alloc.alloc(CtValue.CtFieldValue, struct_value.fields.len);
                var fields_transferred = false;
                errdefer if (!fields_transferred) alloc.free(cloned_fields);
                initCtFieldValues(cloned_fields);

                frame.dest.* = .{ .struct_val = .{
                    .alloc_id = struct_value.alloc_id,
                    .type_name = cloned_type_name,
                    .fields = cloned_fields,
                } };
                type_name_transferred = true;
                fields_transferred = true;

                var index = struct_value.fields.len;
                while (index > 0) {
                    index -= 1;
                    cloned_fields[index].name = try alloc.dupe(u8, struct_value.fields[index].name);
                    try stack.push(alloc, .{
                        .source = struct_value.fields[index].value,
                        .dest = &cloned_fields[index].value,
                        .depth = frame.depth + 1,
                    });
                }
            },
            .union_val => |union_value| {
                try budget.ensureChildren(frame.depth, 1);
                const cloned_type_name = try alloc.dupe(u8, union_value.type_name);
                var type_name_transferred = false;
                errdefer if (!type_name_transferred) alloc.free(cloned_type_name);

                const cloned_variant = try alloc.dupe(u8, union_value.variant);
                var variant_transferred = false;
                errdefer if (!variant_transferred) alloc.free(cloned_variant);

                const cloned_payload = try alloc.create(CtValue);
                cloned_payload.* = .void;
                var payload_transferred = false;
                errdefer if (!payload_transferred) alloc.destroy(cloned_payload);

                frame.dest.* = .{ .union_val = .{
                    .alloc_id = union_value.alloc_id,
                    .type_name = cloned_type_name,
                    .variant = cloned_variant,
                    .payload = cloned_payload,
                } };
                type_name_transferred = true;
                variant_transferred = true;
                payload_transferred = true;
                try stack.push(alloc, .{
                    .source = union_value.payload.*,
                    .dest = cloned_payload,
                    .depth = frame.depth + 1,
                });
            },
            .enum_val => |enum_value| {
                const cloned_type_name = try alloc.dupe(u8, enum_value.type_name);
                var type_name_transferred = false;
                errdefer if (!type_name_transferred) alloc.free(cloned_type_name);

                const cloned_variant = try alloc.dupe(u8, enum_value.variant);
                frame.dest.* = .{ .enum_val = .{
                    .type_name = cloned_type_name,
                    .variant = cloned_variant,
                } };
                type_name_transferred = true;
            },
            .optional => |optional_value| {
                if (optional_value.value) |payload| {
                    try budget.ensureChildren(frame.depth, 1);
                    const cloned_payload = try alloc.create(CtValue);
                    cloned_payload.* = .void;
                    frame.dest.* = .{ .optional = .{ .value = cloned_payload } };
                    try stack.push(alloc, .{
                        .source = payload.*,
                        .dest = cloned_payload,
                        .depth = frame.depth + 1,
                    });
                } else {
                    frame.dest.* = .{ .optional = .{ .value = null } };
                }
            },
            .closure => |closure_value| {
                try budget.ensureChildren(frame.depth, closure_value.captures.len);
                const cloned_captures = try alloc.alloc(CtValue, closure_value.captures.len);
                initCtValueSlots(cloned_captures);
                frame.dest.* = .{ .closure = .{
                    .alloc_id = closure_value.alloc_id,
                    .function_id = closure_value.function_id,
                    .captures = cloned_captures,
                } };
                var index = closure_value.captures.len;
                while (index > 0) {
                    index -= 1;
                    try stack.push(alloc, .{
                        .source = closure_value.captures[index],
                        .dest = &cloned_captures[index],
                        .depth = frame.depth + 1,
                    });
                }
            },
        }
    }

    return cloned_root;
}

fn mapEntryKeyMatchesField(key: CtValue, field_name: []const u8) bool {
    return switch (key) {
        .string => |key_name| std.mem.eql(u8, key_name, field_name),
        .atom => |key_name| std.mem.eql(u8, key_name, field_name),
        else => false,
    };
}

fn rebuildMapEntriesForFieldSet(
    alloc: std.mem.Allocator,
    original_entries: []const CtValue.CtMapEntry,
    field_name: []const u8,
    replacement_value: CtValue,
) std.mem.Allocator.Error![]CtValue.CtMapEntry {
    var matching_index: ?usize = null;
    for (original_entries, 0..) |entry, index| {
        if (mapEntryKeyMatchesField(entry.key, field_name)) {
            matching_index = index;
            break;
        }
    }

    const replacement_entry_count = if (matching_index == null)
        std.math.add(usize, original_entries.len, 1) catch return error.OutOfMemory
    else
        original_entries.len;
    const replacement_entries = try alloc.alloc(CtValue.CtMapEntry, replacement_entry_count);
    errdefer alloc.free(replacement_entries);

    @memcpy(replacement_entries[0..original_entries.len], original_entries);
    if (matching_index) |index| {
        replacement_entries[index].value = replacement_value;
    } else {
        replacement_entries[original_entries.len] = .{
            .key = .{ .string = field_name },
            .value = replacement_value,
        };
    }

    return replacement_entries;
}

fn appendOwnedCtValue(
    alloc: std.mem.Allocator,
    values: *std.ArrayListUnmanaged(CtValue),
    value: CtValue,
) std.mem.Allocator.Error!void {
    errdefer deinitOwnedCtValue(alloc, value);
    try values.append(alloc, value);
}

fn finishOwnedCtValueList(
    alloc: std.mem.Allocator,
    allocation_store: *AllocationStore,
    source_fn: ?ir.FunctionId,
    values: *std.ArrayListUnmanaged(CtValue),
) std.mem.Allocator.Error!CtValue {
    const result_elems = try values.toOwnedSlice(alloc);
    errdefer {
        deinitOwnedCtValueSlice(alloc, result_elems);
        if (result_elems.len > 0) alloc.free(result_elems);
    }

    const alloc_id = try allocation_store.alloc(alloc, .list, source_fn);
    return .{ .list = .{ .alloc_id = alloc_id, .elems = result_elems } };
}

fn finishBorrowedCtValueList(
    alloc: std.mem.Allocator,
    allocation_store: *AllocationStore,
    source_fn: ?ir.FunctionId,
    elems: []const CtValue,
) std.mem.Allocator.Error!CtValue {
    var elems_transferred = false;
    errdefer if (!elems_transferred and elems.len > 0) {
        alloc.free(elems);
    };

    const alloc_id = try allocation_store.alloc(alloc, .list, source_fn);
    elems_transferred = true;
    return .{ .list = .{ .alloc_id = alloc_id, .elems = elems } };
}

// ============================================================
// ConstValue — compiler-facing stable export
// ============================================================

pub const ConstValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
    atom: []const u8,
    nil,
    void,
    tuple: []const ConstValue,
    list: []const ConstValue,
    map: []const ConstMapEntry,
    struct_val: ConstStructValue,

    pub const ConstMapEntry = struct {
        key: ConstValue,
        value: ConstValue,
    };

    pub const ConstStructValue = struct {
        type_name: []const u8,
        fields: []const ConstFieldValue,
    };

    pub const ConstFieldValue = struct {
        name: []const u8,
        value: ConstValue,
    };
};

/// Convert a CtValue (interpreter-internal) to a ConstValue (compiler-facing).
/// Deep-copies all data. Closures and union values cannot be exported.
pub fn exportValue(alloc: std.mem.Allocator, val: CtValue) ExportError!ConstValue {
    const ExportFrame = struct {
        source: CtValue,
        dest: *ConstValue,
        depth: usize,
    };

    var budget = ValueTraversalBudget{};
    var stack = InlineTraversalStack(ExportFrame){};
    defer stack.deinit(alloc);

    var exported_root: ConstValue = .void;
    errdefer deinitConstValue(alloc, exported_root);
    try stack.push(alloc, .{ .source = val, .dest = &exported_root, .depth = 1 });

    while (stack.pop()) |frame| {
        try budget.visit(frame.depth);
        switch (frame.source) {
            .int => |value| frame.dest.* = .{ .int = value },
            .float => |value| frame.dest.* = .{ .float = value },
            .string => |value| frame.dest.* = .{ .string = try alloc.dupe(u8, value) },
            .bool_val => |value| frame.dest.* = .{ .bool_val = value },
            .atom => |value| frame.dest.* = .{ .atom = try alloc.dupe(u8, value) },
            .nil => frame.dest.* = .nil,
            .void => frame.dest.* = .void,
            .consumed, .reuse_token, .union_val, .closure => return error.CannotExport,
            .tuple => |tuple_value| {
                try budget.ensureChildren(frame.depth, tuple_value.elems.len);
                const exported_elems = try alloc.alloc(ConstValue, tuple_value.elems.len);
                initConstValueSlots(exported_elems);
                frame.dest.* = .{ .tuple = exported_elems };
                var index = tuple_value.elems.len;
                while (index > 0) {
                    index -= 1;
                    try stack.push(alloc, .{
                        .source = tuple_value.elems[index],
                        .dest = &exported_elems[index],
                        .depth = frame.depth + 1,
                    });
                }
            },
            .list => |list_value| {
                try budget.ensureChildren(frame.depth, list_value.elems.len);
                const exported_elems = try alloc.alloc(ConstValue, list_value.elems.len);
                initConstValueSlots(exported_elems);
                frame.dest.* = .{ .list = exported_elems };
                var index = list_value.elems.len;
                while (index > 0) {
                    index -= 1;
                    try stack.push(alloc, .{
                        .source = list_value.elems[index],
                        .dest = &exported_elems[index],
                        .depth = frame.depth + 1,
                    });
                }
            },
            .map => |map_value| {
                try budget.ensureChildren(frame.depth, try checkedChildCount(map_value.entries.len, 2));
                const exported_entries = try alloc.alloc(ConstValue.ConstMapEntry, map_value.entries.len);
                initConstMapEntries(exported_entries);
                frame.dest.* = .{ .map = exported_entries };
                var index = map_value.entries.len;
                while (index > 0) {
                    index -= 1;
                    try stack.push(alloc, .{
                        .source = map_value.entries[index].value,
                        .dest = &exported_entries[index].value,
                        .depth = frame.depth + 1,
                    });
                    try stack.push(alloc, .{
                        .source = map_value.entries[index].key,
                        .dest = &exported_entries[index].key,
                        .depth = frame.depth + 1,
                    });
                }
            },
            .struct_val => |struct_value| {
                try budget.ensureChildren(frame.depth, struct_value.fields.len);
                const exported_type_name = try alloc.dupe(u8, struct_value.type_name);
                var struct_transferred = false;
                errdefer if (!struct_transferred) alloc.free(exported_type_name);
                const exported_fields = try alloc.alloc(ConstValue.ConstFieldValue, struct_value.fields.len);
                initConstFieldValues(exported_fields);
                frame.dest.* = .{ .struct_val = .{
                    .type_name = exported_type_name,
                    .fields = exported_fields,
                } };
                struct_transferred = true;
                var index = struct_value.fields.len;
                while (index > 0) {
                    index -= 1;
                    exported_fields[index].name = try alloc.dupe(u8, struct_value.fields[index].name);
                    try stack.push(alloc, .{
                        .source = struct_value.fields[index].value,
                        .dest = &exported_fields[index].value,
                        .depth = frame.depth + 1,
                    });
                }
            },
            .enum_val => |enum_value| frame.dest.* = .{ .atom = try alloc.dupe(u8, enum_value.variant) },
            .optional => |optional_value| {
                if (optional_value.value) |child_value| {
                    try budget.ensureChildren(frame.depth, 1);
                    try stack.push(alloc, .{
                        .source = child_value.*,
                        .dest = frame.dest,
                        .depth = frame.depth + 1,
                    });
                } else {
                    frame.dest.* = .nil;
                }
            },
        }
    }

    return exported_root;
}

pub const ExportError = error{
    CannotExport,
    ValueTraversalDepthExceeded,
    ValueTraversalBudgetExceeded,
    OutOfMemory,
};

// ============================================================
// Capabilities
// ============================================================

pub const Capability = enum(u3) {
    pure = 0,
    read_file = 1,
    read_env = 2,
    reflect_struct = 3,
    reflect_source = 4,
};

pub const CapabilitySet = struct {
    flags: u8 = 0,

    pub fn has(self: CapabilitySet, cap: Capability) bool {
        return (self.flags & (@as(u8, 1) << @intFromEnum(cap))) != 0;
    }

    pub fn with(self: CapabilitySet, cap: Capability) CapabilitySet {
        return .{ .flags = self.flags | (@as(u8, 1) << @intFromEnum(cap)) };
    }

    /// True iff every capability in `self` is also in `other`. Used for
    /// caller/callee attenuation: a callee whose declared capabilities
    /// are a subset of the caller's may be invoked.
    pub fn isSubsetOf(self: CapabilitySet, other: CapabilitySet) bool {
        return (self.flags & ~other.flags) == 0;
    }

    /// Map an atom name (without the leading `:`) to its capability.
    /// Returns null when the name is not a known capability so callers
    /// can surface a precise diagnostic at the source location of the
    /// offending attribute value.
    pub fn capabilityFromAtomName(name: []const u8) ?Capability {
        if (std.mem.eql(u8, name, "pure")) return .pure;
        if (std.mem.eql(u8, name, "read_file")) return .read_file;
        if (std.mem.eql(u8, name, "read_env")) return .read_env;
        if (std.mem.eql(u8, name, "reflect_struct")) return .reflect_struct;
        if (std.mem.eql(u8, name, "reflect_source")) return .reflect_source;
        return null;
    }

    pub const pure_only = CapabilitySet{};
    pub const build = CapabilitySet{ .flags = 0b1_1111 }; // pure + read_file + read_env + reflection
};

// ============================================================
// Dependencies
// ============================================================

pub const CtDependency = union(enum) {
    file: struct {
        path: []const u8,
        content_hash: u64,
    },
    env_var: struct {
        name: []const u8,
        value_hash: u64,
        present: bool,
    },
    glob: struct {
        pattern: []const u8,
        result_hash: u64,
    },
    reflected_struct: struct {
        struct_name: []const u8,
        interface_hash: u64,
    },
    reflected_source: struct {
        paths: []const []const u8,
        graph_hash: u64,
    },

    /// Deep-copy this dependency into allocator-owned storage. The returned
    /// dependency must be released with `deinitOwned`.
    pub fn cloneOwned(self: CtDependency, alloc: std.mem.Allocator) !CtDependency {
        return cloneDependency(alloc, self);
    }

    /// Free payload storage owned by a cloned or cached dependency.
    pub fn deinitOwned(self: CtDependency, alloc: std.mem.Allocator) void {
        deinitCachedDependency(alloc, self);
    }
};

/// Errors that mean persistent dependency validation could not complete.
pub const DependencyValidationError =
    std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.AccessError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.Iterator.Error ||
    SourcePathCanonicalizationError ||
    ValueTraversalError;

const SourcePathCanonicalizationError = error{
    OutOfMemory,
    SourcePathCanonicalizationFailed,
};

pub const CtEvalResult = struct {
    value: ConstValue,
    dependencies: []const CtDependency,
    result_hash: u64,

    /// Free the deep-exported value and owned dependency slice returned by
    /// `Interpreter.evalAndExport` or `PersistentCache.load`.
    pub fn deinit(self: CtEvalResult, alloc: std.mem.Allocator) void {
        deinitConstValue(alloc, self.value);
        for (self.dependencies) |dependency| {
            dependency.deinitOwned(alloc);
        }
        alloc.free(self.dependencies);
    }
};

/// Free all allocations owned by a deep-exported `ConstValue`.
pub fn deinitConstValue(alloc: std.mem.Allocator, value: ConstValue) void {
    switch (value) {
        .string, .atom => |bytes| alloc.free(bytes),
        .tuple, .list => |items| {
            for (items) |item| deinitConstValue(alloc, item);
            alloc.free(items);
        },
        .map => |entries| {
            for (entries) |entry| {
                deinitConstValue(alloc, entry.key);
                deinitConstValue(alloc, entry.value);
            }
            alloc.free(entries);
        },
        .struct_val => |struct_value| {
            alloc.free(struct_value.type_name);
            for (struct_value.fields) |field| {
                alloc.free(field.name);
                deinitConstValue(alloc, field.value);
            }
            alloc.free(struct_value.fields);
        },
        .int, .float, .bool_val, .nil, .void => {},
    }
}

fn initConstValueSlots(values: []ConstValue) void {
    for (values) |*value| {
        value.* = .void;
    }
}

fn initConstMapEntries(entries: []ConstValue.ConstMapEntry) void {
    for (entries) |*entry| {
        entry.* = .{
            .key = .void,
            .value = .void,
        };
    }
}

fn initConstFieldValues(fields: []ConstValue.ConstFieldValue) void {
    for (fields) |*field| {
        field.* = .{
            .name = &.{},
            .value = .void,
        };
    }
}

fn deinitCachedDependency(alloc: std.mem.Allocator, dependency: CtDependency) void {
    switch (dependency) {
        .file => |file| alloc.free(file.path),
        .env_var => |env_var| alloc.free(env_var.name),
        .glob => |glob_dep| alloc.free(glob_dep.pattern),
        .reflected_struct => |reflected_struct| alloc.free(reflected_struct.struct_name),
        .reflected_source => |reflected_source| {
            for (reflected_source.paths) |path| alloc.free(path);
            alloc.free(reflected_source.paths);
        },
    }
}

fn deinitLiveDependency(alloc: std.mem.Allocator, dependency: CtDependency) void {
    switch (dependency) {
        .reflected_struct => |reflected_struct| alloc.free(reflected_struct.struct_name),
        .reflected_source => |reflected_source| alloc.free(reflected_source.paths),
        .file, .env_var, .glob => {},
    }
}

fn clearLiveDependencies(alloc: std.mem.Allocator, dependencies: *std.ArrayListUnmanaged(CtDependency)) void {
    for (dependencies.items) |dependency| {
        deinitLiveDependency(alloc, dependency);
    }
    dependencies.clearRetainingCapacity();
}

fn deinitLiveDependencies(alloc: std.mem.Allocator, dependencies: *std.ArrayListUnmanaged(CtDependency)) void {
    for (dependencies.items) |dependency| {
        deinitLiveDependency(alloc, dependency);
    }
    dependencies.deinit(alloc);
    dependencies.* = .empty;
}

fn deinitCachedEvalResult(alloc: std.mem.Allocator, result: CtEvalResult) void {
    result.deinit(alloc);
}

fn cloneDependency(alloc: std.mem.Allocator, dep: CtDependency) !CtDependency {
    return switch (dep) {
        .file => |f| .{ .file = .{
            .path = try alloc.dupe(u8, f.path),
            .content_hash = f.content_hash,
        } },
        .env_var => |ev| .{ .env_var = .{
            .name = try alloc.dupe(u8, ev.name),
            .value_hash = ev.value_hash,
            .present = ev.present,
        } },
        .glob => |g| .{ .glob = .{
            .pattern = try alloc.dupe(u8, g.pattern),
            .result_hash = g.result_hash,
        } },
        .reflected_struct => |rm| .{ .reflected_struct = .{
            .struct_name = try alloc.dupe(u8, rm.struct_name),
            .interface_hash = rm.interface_hash,
        } },
        .reflected_source => |rs| blk: {
            const paths = try alloc.alloc([]const u8, rs.paths.len);
            var path_count: usize = 0;
            errdefer {
                for (paths[0..path_count]) |path| {
                    alloc.free(path);
                }
                alloc.free(paths);
            }
            for (rs.paths, 0..) |path, i| {
                paths[i] = try alloc.dupe(u8, path);
                path_count += 1;
            }
            break :blk .{ .reflected_source = .{
                .paths = paths,
                .graph_hash = rs.graph_hash,
            } };
        },
    };
}

fn cloneDependencies(alloc: std.mem.Allocator, deps: []const CtDependency) ![]const CtDependency {
    const cloned = try alloc.alloc(CtDependency, deps.len);
    var cloned_count: usize = 0;
    errdefer {
        for (cloned[0..cloned_count]) |dependency| {
            deinitCachedDependency(alloc, dependency);
        }
        alloc.free(cloned);
    }
    for (deps, 0..) |dep, i| {
        cloned[i] = try cloneDependency(alloc, dep);
        cloned_count += 1;
    }
    return cloned;
}

fn hashGlobMatches(matches: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (matches) |matched_path| {
        const path_len: u64 = @intCast(matched_path.len);
        hasher.update(std.mem.asBytes(&path_len));
        hasher.update(matched_path);
    }
    return hasher.final();
}

// ============================================================
// Diagnostics
// ============================================================

pub const CtfeErrorKind = enum {
    step_limit_exceeded,
    recursion_limit_exceeded,
    unsupported_instruction,
    host_io_failure,
    type_error,
    use_after_consume,
    division_by_zero,
    arithmetic_overflow,
    capability_violation,
    match_failure,
    undefined_function,
    index_out_of_bounds,
    value_traversal_limit_exceeded,
};

pub const CtfeFrame = struct {
    function_name: []const u8,
    function_id: ir.FunctionId,
    instruction_index: usize,
    source_span: ?ast.SourceSpan = null,
};

pub const CtfeError = struct {
    message: []const u8,
    kind: CtfeErrorKind,
    call_stack: []const CtfeFrame,
    /// Optional context: which attribute triggered this evaluation
    attribute_context: ?AttributeContext = null,

    pub const AttributeContext = struct {
        attr_name: []const u8,
        struct_name: []const u8,
    };
};

fn deinitCtfeError(alloc: std.mem.Allocator, err: CtfeError) void {
    if (err.message.len > 0) alloc.free(err.message);
    if (err.call_stack.len > 0) alloc.free(err.call_stack);
    if (err.attribute_context) |ctx| {
        if (ctx.attr_name.len > 0) alloc.free(ctx.attr_name);
        if (ctx.struct_name.len > 0) alloc.free(ctx.struct_name);
    }
}

fn deinitCtfeErrorEntries(alloc: std.mem.Allocator, errors: []const CtfeError) void {
    for (errors) |err| {
        deinitCtfeError(alloc, err);
    }
}

fn deinitClonedCtfeErrors(alloc: std.mem.Allocator, errors: []const CtfeError) void {
    deinitCtfeErrorEntries(alloc, errors);
    alloc.free(errors);
}

fn cloneCtfeError(alloc: std.mem.Allocator, err: CtfeError) !CtfeError {
    var cloned = CtfeError{
        .message = &.{},
        .kind = err.kind,
        .call_stack = &.{},
        .attribute_context = null,
    };
    errdefer deinitCtfeError(alloc, cloned);

    cloned.call_stack = try alloc.dupe(CtfeFrame, err.call_stack);
    cloned.message = try alloc.dupe(u8, err.message);
    if (err.attribute_context) |ctx| {
        cloned.attribute_context = .{
            .attr_name = try alloc.dupe(u8, ctx.attr_name),
            .struct_name = &.{},
        };
        cloned.attribute_context.?.struct_name = try alloc.dupe(u8, ctx.struct_name);
    }

    return cloned;
}

fn cloneCtfeErrors(alloc: std.mem.Allocator, errors: []const CtfeError) ![]const CtfeError {
    const cloned = try alloc.alloc(CtfeError, errors.len);
    var initialized_count: usize = 0;
    errdefer {
        deinitCtfeErrorEntries(alloc, cloned[0..initialized_count]);
        alloc.free(cloned);
    }
    for (errors, 0..) |err, i| {
        cloned[i] = try cloneCtfeError(alloc, err);
        initialized_count += 1;
    }
    return cloned;
}

/// Format a CTFE error as a rich multi-line diagnostic string.
/// Produces output like:
///   error: compile-time evaluation exceeded step limit
///     while evaluating `Config.generate/0`
///     called from attribute `@config` in `App`
///     help: possible infinite recursion or unexpectedly large compile-time loop
pub fn formatCtfeError(alloc: std.mem.Allocator, err: CtfeError) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    // Writer shim for Zig 0.16 (ArrayListUnmanaged no longer has .writer())
    const Writer = struct {
        list: *std.ArrayListUnmanaged(u8),
        a: std.mem.Allocator,
        pub fn print(self_w: @This(), comptime fmt_str: []const u8, args: anytype) !void {
            const s = try std.fmt.allocPrint(self_w.a, fmt_str, args);
            defer self_w.a.free(s);
            try self_w.list.appendSlice(self_w.a, s);
        }
        pub fn writeAll(self_w: @This(), data: []const u8) !void {
            try self_w.list.appendSlice(self_w.a, data);
        }
        pub fn writeByte(self_w: @This(), byte: u8) !void {
            try self_w.list.append(self_w.a, byte);
        }
    };
    const w = Writer{ .list = &buf, .a = alloc };

    // Main error line
    try w.print("error: {s}\n", .{err.message});

    // Call stack (innermost first)
    if (err.call_stack.len > 0) {
        var i: usize = err.call_stack.len;
        while (i > 0) {
            i -= 1;
            const frame = err.call_stack[i];
            if (i == err.call_stack.len - 1) {
                try w.print("  while evaluating `{s}`", .{frame.function_name});
            } else {
                try w.print("  called from `{s}`", .{frame.function_name});
            }
            if (frame.source_span) |span| {
                if (span.line > 0) {
                    try w.print(" at {d}:{d}", .{ span.line, span.col });
                } else {
                    try w.print(" at span {d}..{d}", .{ span.start, span.end });
                }
            }
            try w.writeByte('\n');
        }
    }

    // Attribute context
    if (err.attribute_context) |ctx| {
        try w.print("  for attribute `@{s}` in `{s}`\n", .{ ctx.attr_name, ctx.struct_name });
    }

    // Help text based on error kind
    switch (err.kind) {
        .step_limit_exceeded => try w.writeAll("  help: possible infinite recursion or unexpectedly large compile-time loop\n"),
        .recursion_limit_exceeded => try w.writeAll("  help: recursion depth exceeded — simplify the compile-time computation or increase the limit\n"),
        .capability_violation => try w.print("  help: declare the required capability or remove the compile-time {s}\n", .{
            if (std.mem.find(u8, err.message, "read_file")) |_| "file access" else if (std.mem.find(u8, err.message, "read_env")) |_| "env access" else if (std.mem.find(u8, err.message, "reflect_struct")) |_| "reflection" else "effect",
        }),
        .use_after_consume => try w.writeAll("  help: a moved or released value was read again during compile-time evaluation\n"),
        .division_by_zero => try w.writeAll("  help: ensure the divisor is non-zero at compile time\n"),
        .arithmetic_overflow => try w.writeAll("  help: the computation overflows its integer type (e.g. minInt / -1) — adjust the operands\n"),
        .undefined_function => try w.writeAll("  help: the function may not exist or may not be visible at compile time\n"),
        .match_failure => try w.writeAll("  help: no clause matched the compile-time value — add a catch-all clause\n"),
        .host_io_failure => try w.writeAll("  help: check that the compile-time file access is valid and repeatable\n"),
        .type_error => try w.writeAll("  help: compile-time values must have compatible types\n"),
        .value_traversal_limit_exceeded => try w.writeAll("  help: simplify the compile-time value or reduce its nesting/size\n"),
        else => {},
    }

    return buf.toOwnedSlice(alloc);
}

/// Emit all CTFE errors to stderr using the diagnostic format.
pub fn emitCtfeErrors(alloc: std.mem.Allocator, errors: []const CtfeError) void {
    for (errors) |err| {
        const formatted = formatCtfeError(alloc, err) catch {
            std.debug.print("ctfe error: {s}\n", .{err.message});
            continue;
        };
        std.debug.print("{s}", .{formatted});
        alloc.free(formatted);
    }
}

// ============================================================
// Interpreter
// ============================================================

pub const CacheKey = struct {
    function_id: ir.FunctionId,
    function_hash: u64,
    args_hash: u64,
    capability_flags: u8,
    /// Combined hash of target triple + optimize mode + compile options
    options_hash: u64 = 0,
};

fn deinitMemoCache(alloc: std.mem.Allocator, memo_cache: *std.AutoHashMapUnmanaged(CacheKey, CtValue)) void {
    var iterator = memo_cache.iterator();
    while (iterator.next()) |entry| {
        deinitMemoizedCtValue(alloc, entry.value_ptr.*);
    }
    memo_cache.deinit(alloc);
    memo_cache.* = .empty;
}

/// Schema version for cache invalidation when interpreter semantics change.
pub const CTFE_SCHEMA_VERSION: u32 = 1;
pub const MAX_CONST_EXPR_RECURSION_DEPTH: u32 = 2048;

/// Build a complete options hash from compile-relevant settings.
pub fn hashCompileOptions(target: []const u8, optimize: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(target);
    hasher.update(optimize);
    hasher.update(std.mem.asBytes(&CTFE_SCHEMA_VERSION));
    return hasher.final();
}

fn hashBuildOptions(build_opts: std.StringHashMapUnmanaged([]const u8)) u64 {
    var combined: u64 = 0;
    var count: u32 = 0;
    var iter = build_opts.iterator();
    while (iter.next()) |entry| {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(entry.key_ptr.*);
        hasher.update(entry.value_ptr.*);
        combined ^= hasher.final();
        count += 1;
    }

    var final_hasher = std.hash.Wyhash.init(0);
    final_hasher.update(std.mem.asBytes(&combined));
    final_hasher.update(std.mem.asBytes(&count));
    final_hasher.update(std.mem.asBytes(&CTFE_SCHEMA_VERSION));
    return final_hasher.final();
}

fn hashEvaluationOptions(explicit_compile_options_hash: u64, build_opts: std.StringHashMapUnmanaged([]const u8)) u64 {
    const build_opts_hash = hashBuildOptions(build_opts);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&explicit_compile_options_hash));
    hasher.update(std.mem.asBytes(&build_opts_hash));
    hasher.update(std.mem.asBytes(&CTFE_SCHEMA_VERSION));
    return hasher.final();
}

fn hashLocalIds(hasher: *std.hash.Wyhash, locals: []const ir.LocalId) void {
    for (locals) |local_id| hasher.update(std.mem.asBytes(&local_id));
}

fn hashZigType(hasher: *std.hash.Wyhash, ty: ir.ZigType) void {
    const tag = std.meta.activeTag(ty);
    hasher.update(&[_]u8{@intFromEnum(tag)});
    switch (ty) {
        .tuple => |items| for (items) |item| hashZigType(hasher, item),
        .list => |item| hashZigType(hasher, item.*),
        .map => |m| {
            hashZigType(hasher, m.key.*);
            hashZigType(hasher, m.value.*);
        },
        .struct_ref => |name| hasher.update(name),
        .function => |fn_ty| {
            for (fn_ty.params) |param| hashZigType(hasher, param);
            hashZigType(hasher, fn_ty.return_type.*);
        },
        .tagged_union => |name| hasher.update(name),
        .optional => |item| hashZigType(hasher, item.*),
        .ptr => |item| hashZigType(hasher, item.*),
        else => {},
    }
}

fn hashLiteralValueForIr(hasher: *std.hash.Wyhash, value: ir.LiteralValue) void {
    const tag = std.meta.activeTag(value);
    hasher.update(&[_]u8{@intFromEnum(tag)});
    switch (value) {
        .int => |v| hasher.update(std.mem.asBytes(&v)),
        .float => |v| hasher.update(std.mem.asBytes(&v)),
        .bool_val => |v| hasher.update(&[_]u8{@intFromBool(v)}),
        .string => |v| hasher.update(v),
    }
}

fn hashInstruction(hasher: *std.hash.Wyhash, instr: ir.Instruction) void {
    const tag = std.meta.activeTag(instr);
    hasher.update(&[_]u8{@intFromEnum(tag)});
    switch (instr) {
        .const_int => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.value));
            if (v.type_hint) |hint| hashZigType(hasher, hint);
        },
        .const_float => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.value));
            if (v.type_hint) |hint| hashZigType(hasher, hint);
        },
        .const_string => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.value);
        },
        .const_bool => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(&[_]u8{@intFromBool(v.value)});
        },
        .const_atom => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.value);
        },
        .const_nil => |dest| hasher.update(std.mem.asBytes(&dest)),
        .local_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .borrow_value => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .copy_value => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .local_set => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.value));
        },
        .move_value => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .share_value => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .param_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.index));
        },
        .tuple_init => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            for (v.elements) |elem| hasher.update(std.mem.asBytes(&elem));
        },
        .list_init => |li| {
            hasher.update(std.mem.asBytes(&li.dest));
            for (li.elements) |elem| hasher.update(std.mem.asBytes(&elem));
        },
        .list_cons => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.head));
            hasher.update(std.mem.asBytes(&v.tail));
        },
        .map_init => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            for (v.entries) |entry| {
                hasher.update(std.mem.asBytes(&entry.key));
                hasher.update(std.mem.asBytes(&entry.value));
            }
        },
        .struct_init => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.type_name);
            for (v.fields) |field| {
                hasher.update(field.name);
                hasher.update(std.mem.asBytes(&field.value));
            }
        },
        .union_init => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.union_type);
            hasher.update(v.variant_name);
            hasher.update(std.mem.asBytes(&v.value));
        },
        .box_as_protocol => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.value));
            hasher.update(v.protocol_name);
            hasher.update(v.target_type_name);
            hashZigType(hasher, v.value_zig_type);
        },
        .protocol_dispatch => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.receiver));
            hasher.update(v.protocol_name);
            hasher.update(v.method_name);
            hasher.update(std.mem.asBytes(&v.method_index));
            hasher.update(std.mem.asBytes(&v.arity));
            for (v.args) |arg| hasher.update(std.mem.asBytes(&arg));
            for (v.arg_modes) |mode| hasher.update(std.mem.asBytes(&mode));
            hashZigType(hasher, v.return_type);
        },
        .protocol_box_unbox => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.box));
            hasher.update(v.protocol_name);
            hasher.update(v.target_type_name);
            hashZigType(hasher, v.target_zig_type);
        },
        .protocol_box_vtable_eq => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.box));
            hasher.update(v.protocol_name);
            hasher.update(v.target_type_name);
        },
        .enum_literal => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.type_name);
            hasher.update(v.variant);
        },
        .field_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.object));
            hasher.update(v.field);
        },
        .field_set => |v| {
            hasher.update(std.mem.asBytes(&v.object));
            hasher.update(v.field);
            hasher.update(std.mem.asBytes(&v.value));
        },
        .index_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.object));
            hasher.update(std.mem.asBytes(&v.index));
        },
        .list_len_check => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(std.mem.asBytes(&v.expected_len));
            hasher.update(std.mem.asBytes(&v.minimum));
        },
        .list_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.list));
            hasher.update(std.mem.asBytes(&v.index));
        },
        .list_is_not_empty => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.list));
        },
        .list_head, .list_tail => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.list));
            hasher.update(std.mem.asBytes(&v.start_index));
        },
        .map_has_key => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.map));
            hasher.update(std.mem.asBytes(&v.key));
        },
        .map_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.map));
            hasher.update(std.mem.asBytes(&v.key));
            hasher.update(std.mem.asBytes(&v.default));
        },
        .binary_op => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(&[_]u8{@intFromEnum(v.op)});
            hasher.update(std.mem.asBytes(&v.lhs));
            hasher.update(std.mem.asBytes(&v.rhs));
        },
        .unary_op => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(&[_]u8{@intFromEnum(v.op)});
            hasher.update(std.mem.asBytes(&v.operand));
        },
        .call_direct => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.function));
            hashLocalIds(hasher, v.args);
        },
        .call_named => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.name);
            hashLocalIds(hasher, v.args);
            for (v.arg_modes) |mode| hasher.update(&[_]u8{@intFromEnum(mode)});
        },
        .try_call_named => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.name);
            hashLocalIds(hasher, v.args);
            for (v.arg_modes) |mode| hasher.update(&[_]u8{@intFromEnum(mode)});
            // The handler and success continuation bodies are part of the
            // instruction's identity: two try_call_named instructions
            // differing only in those bodies (or their result/payload
            // bindings) must hash distinctly, or a CTFE memo cache returns
            // the wrong cached comptime result.
            hasher.update(std.mem.asBytes(&v.input_local));
            for (v.handler_instrs) |nested| hashInstruction(hasher, nested);
            if (v.handler_result) |hr| hasher.update(std.mem.asBytes(&hr));
            for (v.success_instrs) |nested| hashInstruction(hasher, nested);
            if (v.success_result) |sr| hasher.update(std.mem.asBytes(&sr));
            if (v.payload_local) |pl| hasher.update(std.mem.asBytes(&pl));
        },
        .call_closure => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.callee));
            hashLocalIds(hasher, v.args);
            for (v.arg_modes) |mode| hasher.update(&[_]u8{@intFromEnum(mode)});
        },
        .call_dispatch => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.group_id));
            hashLocalIds(hasher, v.args);
        },
        .call_builtin => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(v.name);
            hashLocalIds(hasher, v.args);
            for (v.arg_modes) |mode| hasher.update(&[_]u8{@intFromEnum(mode)});
        },
        .tail_call => |v| {
            hasher.update(v.name);
            hashLocalIds(hasher, v.args);
        },
        .error_catch => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            hasher.update(std.mem.asBytes(&v.catch_value));
        },
        .unwrap_error_union => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .if_expr => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.condition));
            for (v.then_instrs) |nested| hashInstruction(hasher, nested);
            if (v.then_result) |res| hasher.update(std.mem.asBytes(&res));
            for (v.else_instrs) |nested| hashInstruction(hasher, nested);
            if (v.else_result) |res| hasher.update(std.mem.asBytes(&res));
        },
        .guard_block => |v| {
            hasher.update(std.mem.asBytes(&v.condition));
            for (v.body) |nested| hashInstruction(hasher, nested);
        },
        .case_block => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            for (v.pre_instrs) |nested| hashInstruction(hasher, nested);
            for (v.arms) |arm| {
                hasher.update(std.mem.asBytes(&arm.condition));
                for (arm.cond_instrs) |nested| hashInstruction(hasher, nested);
                for (arm.body_instrs) |nested| hashInstruction(hasher, nested);
                if (arm.result) |res| hasher.update(std.mem.asBytes(&res));
            }
            for (v.default_instrs) |nested| hashInstruction(hasher, nested);
            if (v.default_result) |res| hasher.update(std.mem.asBytes(&res));
        },
        .branch => |v| hasher.update(std.mem.asBytes(&v.target)),
        .cond_branch => |v| {
            hasher.update(std.mem.asBytes(&v.condition));
            hasher.update(std.mem.asBytes(&v.then_target));
            hasher.update(std.mem.asBytes(&v.else_target));
        },
        .switch_tag => |v| {
            hasher.update(std.mem.asBytes(&v.scrutinee));
            for (v.cases) |case| {
                hasher.update(case.tag);
                hasher.update(std.mem.asBytes(&case.target));
            }
            hasher.update(std.mem.asBytes(&v.default));
        },
        .switch_literal => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            for (v.cases) |case| {
                hashLiteralValueForIr(hasher, case.value);
                for (case.body_instrs) |nested| hashInstruction(hasher, nested);
                if (case.result) |res| hasher.update(std.mem.asBytes(&res));
            }
            for (v.default_instrs) |nested| hashInstruction(hasher, nested);
            if (v.default_result) |res| hasher.update(std.mem.asBytes(&res));
        },
        .switch_return => |v| {
            hasher.update(std.mem.asBytes(&v.scrutinee_param));
            for (v.cases) |case| {
                hashLiteralValueForIr(hasher, case.value);
                for (case.body_instrs) |nested| hashInstruction(hasher, nested);
                if (case.return_value) |rv| hasher.update(std.mem.asBytes(&rv));
            }
            for (v.default_instrs) |nested| hashInstruction(hasher, nested);
            if (v.default_result) |dr| hasher.update(std.mem.asBytes(&dr));
        },
        .union_switch_return => |v| {
            hasher.update(std.mem.asBytes(&v.scrutinee_param));
            for (v.cases) |case| {
                hasher.update(case.variant_name);
                for (case.field_bindings) |binding| {
                    hasher.update(binding.field_name);
                    hasher.update(std.mem.asBytes(&binding.local_index));
                }
                for (case.body_instrs) |nested| hashInstruction(hasher, nested);
                if (case.return_value) |rv| hasher.update(std.mem.asBytes(&rv));
            }
        },
        .union_switch => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            for (v.cases) |case| {
                hasher.update(case.variant_name);
                for (case.field_bindings) |binding| {
                    hasher.update(binding.field_name);
                    hasher.update(std.mem.asBytes(&binding.local_index));
                }
                for (case.body_instrs) |nested| hashInstruction(hasher, nested);
                if (case.return_value) |rv| hasher.update(std.mem.asBytes(&rv));
            }
            // The catch-all `_` prong is part of the instruction's identity:
            // two union_switches differing only in `else_instrs`/`else_result`
            // must hash distinctly, or a CTFE memo cache returns the wrong
            // cached comptime result.
            hasher.update(std.mem.asBytes(&v.has_else));
            for (v.else_instrs) |nested| hashInstruction(hasher, nested);
            if (v.else_result) |er| hasher.update(std.mem.asBytes(&er));
        },
        .optional_dispatch => |v| {
            hasher.update(std.mem.asBytes(&v.scrutinee_param));
            hasher.update(std.mem.asBytes(&v.payload_local));
            for (v.nil_instrs) |nested| hashInstruction(hasher, nested);
            if (v.nil_result) |nr| hasher.update(std.mem.asBytes(&nr));
            for (v.struct_instrs) |nested| hashInstruction(hasher, nested);
            if (v.struct_result) |sr| hasher.update(std.mem.asBytes(&sr));
        },
        .match_atom => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(v.atom_name);
        },
        .match_variant_tag => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(v.variant_name);
        },
        .variant_payload_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(v.variant_name);
        },
        .match_int => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(std.mem.asBytes(&v.value));
        },
        .match_float => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(std.mem.asBytes(&v.value));
        },
        .match_string => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(v.expected);
        },
        .match_type => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hashZigType(hasher, v.expected_type);
        },
        .match_fail, .match_error_return, .ret_raise => {},
        .ret => |v| if (v.value) |value| hasher.update(std.mem.asBytes(&value)),
        .cond_return => |v| {
            hasher.update(std.mem.asBytes(&v.condition));
            if (v.value) |value| hasher.update(std.mem.asBytes(&value));
        },
        .case_break => |v| if (v.value) |value| hasher.update(std.mem.asBytes(&value)),
        .jump => |v| {
            hasher.update(std.mem.asBytes(&v.target));
            if (v.bind_dest) |dest| hasher.update(std.mem.asBytes(&dest));
            if (v.value) |value| hasher.update(std.mem.asBytes(&value));
        },
        .make_closure => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.function));
            hashLocalIds(hasher, v.captures);
        },
        .capture_get => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.index));
        },
        .optional_unwrap => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            hasher.update(std.mem.asBytes(&v.safety_check));
        },
        .bin_len_check => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.scrutinee));
            hasher.update(std.mem.asBytes(&v.min_len));
        },
        .bin_read_int => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            hasher.update(std.mem.asBytes(&v.bits));
            hasher.update(&[_]u8{@intFromEnum(v.endianness)});
            hasher.update(&[_]u8{@intFromBool(v.signed)});
        },
        .bin_read_float => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            hasher.update(std.mem.asBytes(&v.bits));
            hasher.update(&[_]u8{@intFromEnum(v.endianness)});
        },
        .bin_slice => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            if (v.length) |len| switch (len) {
                .static => |s| hasher.update(std.mem.asBytes(&s)),
                .dynamic => |d| hasher.update(std.mem.asBytes(&d)),
            };
        },
        .bin_read_utf8 => |v| {
            hasher.update(std.mem.asBytes(&v.dest_codepoint));
            hasher.update(std.mem.asBytes(&v.dest_len));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .bin_match_prefix => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            hasher.update(v.expected);
        },
        .retain => |v| hasher.update(std.mem.asBytes(&v.value)),
        .release => |v| {
            hasher.update(std.mem.asBytes(&v.value));
            hasher.update(std.mem.asBytes(&v.kind));
            if (v.protocol_name) |name| hasher.update(name);
        },
        .reset => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
        },
        .reuse_alloc => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            if (v.token) |t| hasher.update(std.mem.asBytes(&t));
            hasher.update(std.mem.asBytes(&v.constructor_tag));
            hashZigType(hasher, v.dest_type);
        },
        .int_widen, .float_widen => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hasher.update(std.mem.asBytes(&v.source));
            hashZigType(hasher, v.dest_type);
        },
        .typed_undef => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            hashZigType(hasher, v.ty);
        },
        .phi => |v| {
            hasher.update(std.mem.asBytes(&v.dest));
            for (v.sources) |src| {
                hasher.update(std.mem.asBytes(&src.from_block));
                hasher.update(std.mem.asBytes(&src.value));
            }
        },
        .set_safety => {},
        .dbg_stmt => |v| {
            hasher.update(std.mem.asBytes(&v.line));
            hasher.update(std.mem.asBytes(&v.column));
        },
        .dbg_var => |v| {
            hasher.update(std.mem.asBytes(&v.value));
            hasher.update(std.mem.asBytes(&v.is_ptr));
            hasher.update(v.name);
        },
    }
}

fn hashFunctionIdentity(func: *const ir.Function) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(func.name);
    hasher.update(std.mem.asBytes(&func.arity));
    hashZigType(&hasher, func.return_type);
    hasher.update(std.mem.asBytes(&func.local_count));
    hasher.update(&[_]u8{@intFromBool(func.is_closure)});
    for (func.params) |param| {
        hasher.update(param.name);
        hashZigType(&hasher, param.type_expr);
    }
    for (func.captures) |capture| {
        hasher.update(capture.name);
        hashZigType(&hasher, capture.type_expr);
        hasher.update(&[_]u8{@intFromEnum(capture.ownership)});
    }
    for (func.body) |block| {
        hasher.update(std.mem.asBytes(&block.label));
        for (block.instructions) |instr| hashInstruction(&hasher, instr);
    }
    return hasher.final();
}

pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    function_by_name: std.StringHashMapUnmanaged(ir.FunctionId),
    step_budget: u64,
    steps_remaining: u64,
    recursion_limit: u32,
    const_expr_recursion_limit: u32,
    const_expr_depth: u32,
    allocation_store: AllocationStore,
    persistent_cache: ?PersistentCache = null,
    capabilities: CapabilitySet,
    dependencies: std.ArrayListUnmanaged(CtDependency),
    call_stack: std.ArrayListUnmanaged(CtfeFrame),
    errors: std.ArrayListUnmanaged(CtfeError),
    memo_cache: std.AutoHashMapUnmanaged(CacheKey, CtValue),
    scope_graph: ?*scope.ScopeGraph,
    interner: ?*const ast.StringInterner,
    current_struct_scope: ?scope.ScopeId = null,
    build_opts: std.StringHashMapUnmanaged([]const u8) = .empty,
    compile_options_hash: u64 = 0,
    current_attribute_context: ?CtfeError.AttributeContext = null,

    pub fn init(
        allocator: std.mem.Allocator,
        program: *const ir.Program,
    ) std.mem.Allocator.Error!Interpreter {
        var interp = Interpreter{
            .allocator = allocator,
            .program = program,
            .function_by_name = .empty,
            .step_budget = 1_000_000,
            .steps_remaining = 1_000_000,
            .recursion_limit = 256,
            .const_expr_recursion_limit = MAX_CONST_EXPR_RECURSION_DEPTH,
            .const_expr_depth = 0,
            .capabilities = CapabilitySet.pure_only,
            .dependencies = .empty,
            .call_stack = .empty,
            .errors = .empty,
            .memo_cache = .empty,
            .allocation_store = .{},
            .scope_graph = null,
            .interner = null,
            .current_struct_scope = null,
            .current_attribute_context = null,
        };
        errdefer interp.function_by_name.deinit(allocator);

        // Build name -> id index (use func.id, NOT array index)
        for (program.functions) |func| {
            try interp.function_by_name.put(allocator, func.name, func.id);
        }
        return interp;
    }

    pub fn deinit(self: *Interpreter) void {
        self.function_by_name.deinit(self.allocator);
        deinitLiveDependencies(self.allocator, &self.dependencies);
        self.call_stack.deinit(self.allocator);
        deinitCtfeErrorEntries(self.allocator, self.errors.items);
        self.errors.deinit(self.allocator);
        deinitMemoCache(self.allocator, &self.memo_cache);
        self.allocation_store.deinit(self.allocator);
    }

    /// Evaluate a function by ID with given arguments.
    pub fn evalFunction(
        self: *Interpreter,
        function_id: ir.FunctionId,
        args: []const CtValue,
    ) CtfeInterpretError!CtValue {
        if (self.call_stack.items.len >= self.recursion_limit) {
            try self.emitError(.recursion_limit_exceeded, "recursion limit exceeded");
            return error.CtfeFailure;
        }
        const is_top_level_eval = self.call_stack.items.len == 0;

        // Look up function by ID (not array index) — function IDs may not
        // match array indices when generic stubs or monomorphized copies are present.
        const func = blk: {
            for (self.program.functions) |*f| {
                if (f.id == function_id) break :blk f;
            }
            try self.emitError(.undefined_function, "invalid function id");
            return error.CtfeFailure;
        };

        // Memoization: check in-process cache
        const args_hash = self.hashArgs(args) catch |err| return self.traversalFailure(err);
        const cache_key = CacheKey{
            .function_id = function_id,
            .function_hash = hashFunctionIdentity(func),
            .args_hash = args_hash,
            .capability_flags = self.capabilities.flags,
            .options_hash = hashEvaluationOptions(self.compile_options_hash, self.build_opts),
        };
        if (self.memo_cache.get(cache_key)) |cached| {
            return cached;
        }

        // Persistent cache: check disk cache (top-level calls only)
        if (self.persistent_cache) |*pc| {
            if (is_top_level_eval) {
                const pk = PersistentCache.cacheKeyFor(
                    func.name,
                    cache_key.function_hash,
                    cache_key.args_hash,
                    cache_key.capability_flags,
                    cache_key.options_hash,
                );
                const maybe_cached_result = pc.load(self.allocator, pk) catch |err| return self.persistentCacheLoadFailure(err);
                if (maybe_cached_result) |cached_result| {
                    defer deinitCachedEvalResult(self.allocator, cached_result);
                    const dependencies_valid = PersistentCache.validateDependencies(self.allocator, cached_result.dependencies, self.scope_graph, self.interner) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ValueTraversalDepthExceeded,
                        error.ValueTraversalBudgetExceeded,
                        => |traversal_err| return self.traversalFailure(traversal_err),
                        else => {
                            try self.emitErrorFmt(.host_io_failure, "persistent CTFE cache dependency validation failed: {s}", .{@errorName(err)});
                            return error.CtfeFailure;
                        },
                    };
                    if (dependencies_valid) {
                        const imported = importConstValue(self.allocator, cached_result.value) catch |err| return self.traversalFailure(err);
                        defer deinitOwnedCtValue(self.allocator, imported);
                        return try self.putMemoizedCtValue(cache_key, imported);
                    }
                }
            }
        }

        var frame = Frame.init(self.allocator, func, args) catch return error.OutOfMemory;
        defer frame.deinit(self.allocator);

        try self.call_stack.append(self.allocator, .{
            .function_name = func.name,
            .function_id = function_id,
            .instruction_index = 0,
            .source_span = self.resolveFunctionSourceSpan(func),
        });
        defer _ = self.call_stack.pop();

        if (func.body.len == 0) return .void;
        const result = try self.execFunctionBlocks(func, &frame);

        // Store in memo cache
        _ = try self.putMemoizedCtValue(cache_key, result);

        // Store in persistent cache (top-level calls only)
        if (self.persistent_cache) |*pc| {
            if (is_top_level_eval) {
                const exported = exportValue(self.allocator, result) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ValueTraversalDepthExceeded,
                    error.ValueTraversalBudgetExceeded,
                    => |traversal_err| return self.traversalFailure(traversal_err),
                    error.CannotExport => return result,
                };
                defer deinitConstValue(self.allocator, exported);

                const pk = PersistentCache.cacheKeyFor(
                    func.name,
                    cache_key.function_hash,
                    cache_key.args_hash,
                    cache_key.capability_flags,
                    cache_key.options_hash,
                );
                const result_hash = hashConstValue(self.allocator, exported) catch |err| return self.traversalFailure(err);
                pc.store(self.allocator, pk, .{
                    .value = exported,
                    .dependencies = self.dependencies.items,
                    .result_hash = result_hash,
                }) catch |err| return self.persistentCacheStoreFailure(err);
            }
        }

        return result;
    }

    fn putMemoizedCtValue(
        self: *Interpreter,
        cache_key: CacheKey,
        value: CtValue,
    ) CtfeInterpretError!CtValue {
        const memoized_value = cloneCtValueForMemo(self.allocator, value) catch |err| return self.traversalFailure(err);
        errdefer deinitMemoizedCtValue(self.allocator, memoized_value);

        if (self.memo_cache.getPtr(cache_key)) |existing_value| {
            deinitMemoizedCtValue(self.allocator, existing_value.*);
            existing_value.* = memoized_value;
            return memoized_value;
        }

        try self.memo_cache.putNoClobber(self.allocator, cache_key, memoized_value);
        return memoized_value;
    }

    /// Evaluate a function by name.
    pub fn evalByName(
        self: *Interpreter,
        name: []const u8,
        args: []const CtValue,
    ) CtfeInterpretError!CtValue {
        const func_id = self.function_by_name.get(name) orelse {
            try self.emitError(.undefined_function, name);
            return error.CtfeFailure;
        };
        return self.evalFunction(func_id, args);
    }

    /// Evaluate and export: accepts ConstValue args, returns CtEvalResult.
    /// This is the production API for CTFE evaluation.
    pub fn evalAndExport(
        self: *Interpreter,
        function_id: ir.FunctionId,
        args: []const ConstValue,
        caps: CapabilitySet,
    ) CtfeInterpretError!CtEvalResult {
        self.capabilities = caps;
        clearLiveDependencies(self.allocator, &self.dependencies);
        self.steps_remaining = self.step_budget;

        // Import ConstValue args to CtValue
        const ct_args = self.allocator.alloc(CtValue, args.len) catch return error.OutOfMemory;
        initCtValueSlots(ct_args);
        defer {
            deinitOwnedCtValueSlice(self.allocator, ct_args);
            self.allocator.free(ct_args);
        }
        for (args, 0..) |arg, i| {
            ct_args[i] = importConstValue(self.allocator, arg) catch |err| return self.traversalFailure(err);
        }

        const result = try self.evalFunction(function_id, ct_args);
        const exported = exportValue(self.allocator, result) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTraversalDepthExceeded => return self.traversalFailure(error.ValueTraversalDepthExceeded),
            error.ValueTraversalBudgetExceeded => return self.traversalFailure(error.ValueTraversalBudgetExceeded),
            error.CannotExport => return error.CtfeFailure,
        };
        errdefer deinitConstValue(self.allocator, exported);
        const dependencies = cloneDependencies(self.allocator, self.dependencies.items) catch return error.OutOfMemory;
        errdefer {
            for (dependencies) |dependency| {
                deinitCachedDependency(self.allocator, dependency);
            }
            self.allocator.free(dependencies);
        }
        const result_hash = hashConstValue(self.allocator, exported) catch |err| return self.traversalFailure(err);

        return .{
            .value = exported,
            .dependencies = dependencies,
            .result_hash = result_hash,
        };
    }

    fn hashConstValue(allocator: std.mem.Allocator, val: ConstValue) ValueTraversalError!u64 {
        var hasher = std.hash.Wyhash.init(0);
        try hashConstValueInto(allocator, &hasher, val);
        return hasher.final();
    }

    fn hashConstValueInto(allocator: std.mem.Allocator, hasher: *std.hash.Wyhash, val: ConstValue) ValueTraversalError!void {
        const HashValueFrame = struct {
            value: ConstValue,
            depth: usize,
        };
        const HashFrame = union(enum) {
            value: HashValueFrame,
            bytes: []const u8,
        };

        var budget = ValueTraversalBudget{};
        var stack = InlineTraversalStack(HashFrame){};
        defer stack.deinit(allocator);

        try stack.push(allocator, .{ .value = .{ .value = val, .depth = 1 } });

        while (stack.pop()) |frame| {
            switch (frame) {
                .bytes => |bytes| hasher.update(bytes),
                .value => |value_frame| {
                    try budget.visit(value_frame.depth);
                    switch (value_frame.value) {
                        .int => |value| hasher.update(std.mem.asBytes(&value)),
                        .float => |value| hasher.update(std.mem.asBytes(&value)),
                        .string => |value| hasher.update(value),
                        .bool_val => |value| hasher.update(&[_]u8{@intFromBool(value)}),
                        .atom => |value| hasher.update(value),
                        .nil, .void => {},
                        .tuple => |elems| {
                            try budget.ensureChildren(value_frame.depth, elems.len);
                            var index = elems.len;
                            while (index > 0) {
                                index -= 1;
                                try stack.push(allocator, .{ .value = .{
                                    .value = elems[index],
                                    .depth = value_frame.depth + 1,
                                } });
                            }
                        },
                        .list => |elems| {
                            try budget.ensureChildren(value_frame.depth, elems.len);
                            var index = elems.len;
                            while (index > 0) {
                                index -= 1;
                                try stack.push(allocator, .{ .value = .{
                                    .value = elems[index],
                                    .depth = value_frame.depth + 1,
                                } });
                            }
                        },
                        .map => |entries| {
                            try budget.ensureChildren(value_frame.depth, try checkedChildCount(entries.len, 2));
                            var index = entries.len;
                            while (index > 0) {
                                index -= 1;
                                try stack.push(allocator, .{ .value = .{ .value = entries[index].value, .depth = value_frame.depth + 1 } });
                                try stack.push(allocator, .{ .value = .{ .value = entries[index].key, .depth = value_frame.depth + 1 } });
                            }
                        },
                        .struct_val => |struct_value| {
                            hasher.update(struct_value.type_name);
                            try budget.ensureChildren(value_frame.depth, struct_value.fields.len);
                            var index = struct_value.fields.len;
                            while (index > 0) {
                                index -= 1;
                                try stack.push(allocator, .{ .value = .{
                                    .value = struct_value.fields[index].value,
                                    .depth = value_frame.depth + 1,
                                } });
                                try stack.push(allocator, .{ .bytes = struct_value.fields[index].name });
                            }
                        },
                    }
                },
            }
        }
    }

    /// Execute a sequence of instructions. Returns the result value.
    fn execInstructions(
        self: *Interpreter,
        instrs: []const ir.Instruction,
        frame: *Frame,
    ) CtfeInterpretError!CtValue {
        return self.execInstructionsFrom(instrs, frame, 0);
    }

    fn execInstructionsFrom(
        self: *Interpreter,
        instrs: []const ir.Instruction,
        frame: *Frame,
        start_index: usize,
    ) CtfeInterpretError!CtValue {
        for (instrs[start_index..], start_index..) |instr, idx| {
            if (self.steps_remaining == 0) {
                try self.emitError(.step_limit_exceeded, "step limit exceeded");
                return error.CtfeFailure;
            }
            self.steps_remaining -= 1;
            self.setCurrentInstructionIndex(idx);

            const result = try self.execOneInstruction(instr, frame);
            switch (result) {
                .continued => continue,
                .returned => |val| return val,
                .broke => |val| return val orelse .void,
                .jumped => |target| {
                    frame.predecessor_block_label = frame.current_block_label;
                    frame.current_block_label = target;
                    return try self.execFunctionBlocksFromCurrent(frame);
                },
            }
        }
        return .void;
    }

    /// Execute a single instruction.
    fn execOneInstruction(
        self: *Interpreter,
        instr: ir.Instruction,
        frame: *Frame,
    ) CtfeInterpretError!ExecResult {
        switch (instr) {
            // === Constants ===
            .const_int => |ci| {
                frame.setLocal(ci.dest, .{ .int = ci.value });
                return .continued;
            },
            .const_float => |cf| {
                frame.setLocal(cf.dest, .{ .float = cf.value });
                return .continued;
            },
            .const_string => |cs| {
                frame.setLocal(cs.dest, .{ .string = cs.value });
                return .continued;
            },
            .const_bool => |cb| {
                frame.setLocal(cb.dest, .{ .bool_val = cb.value });
                return .continued;
            },
            .const_atom => |ca| {
                frame.setLocal(ca.dest, .{ .atom = ca.value });
                return .continued;
            },
            .const_nil => |dest| {
                frame.setLocal(dest, .nil);
                return .continued;
            },

            // === Locals ===
            .local_get => |lg| {
                frame.setLocal(lg.dest, try self.readLocal(frame, lg.source));
                return .continued;
            },
            .borrow_value => |bv| {
                // Phase C: a borrow-alias has the same value semantics
                // as `.local_get` at compile time — no runtime retain
                // is observable inside the CTFE interpreter, so the
                // alias simply copies the source's value handle.
                frame.setLocal(bv.dest, try self.readLocal(frame, bv.source));
                return .continued;
            },
            .copy_value => |cv| {
                // Phase C: a copy of an ARC owner also has plain
                // value-aliasing semantics inside CTFE — refcount
                // bookkeeping is a runtime concept that the
                // interpreter does not model.
                frame.setLocal(cv.dest, try self.readLocal(frame, cv.source));
                return .continued;
            },
            .local_set => |ls| {
                frame.setLocal(ls.dest, try self.readLocal(frame, ls.value));
                return .continued;
            },
            .param_get => |pg| {
                frame.setLocal(pg.dest, try self.readParam(frame, pg.index));
                return .continued;
            },
            .move_value => |mv| {
                // Move semantics: copy value and invalidate source
                const val = try self.readLocal(frame, mv.source);
                frame.setLocal(mv.dest, val);
                frame.setLocal(mv.source, .consumed); // source is consumed
                return .continued;
            },
            .share_value => |sv| {
                // Share semantics: copy value, source remains valid
                frame.setLocal(sv.dest, try self.readLocal(frame, sv.source));
                return .continued;
            },

            // === Arithmetic ===
            .binary_op => |op| {
                const result = try self.evalBinaryOp(op, frame);
                frame.setLocal(op.dest, result);
                return .continued;
            },
            .unary_op => |op| {
                const result = try self.evalUnaryOp(op, frame);
                frame.setLocal(op.dest, result);
                return .continued;
            },

            // === Aggregates ===
            .tuple_init => |ti| {
                const elems = try self.collectLocals(ti.elements, frame);
                var elems_transferred = false;
                errdefer if (!elems_transferred) {
                    freeUncommittedCtValueSlots(self.allocator, elems, elems.len);
                };
                const alloc_id = try self.allocIdForDest(frame, ti.dest, .tuple);
                try self.setAggregateLocal(ti.dest, frame, .{ .tuple = .{ .alloc_id = alloc_id, .elems = elems } });
                elems_transferred = true;
                return .continued;
            },
            .list_init => |li| {
                const elems = try self.collectLocals(li.elements, frame);
                var elems_transferred = false;
                errdefer if (!elems_transferred) {
                    freeUncommittedCtValueSlots(self.allocator, elems, elems.len);
                };
                const alloc_id = try self.allocIdForDest(frame, li.dest, .list);
                try self.setAggregateLocal(li.dest, frame, .{ .list = .{ .alloc_id = alloc_id, .elems = elems } });
                elems_transferred = true;
                return .continued;
            },
            .list_cons => |lc| {
                const head_val = try self.readLocal(frame, lc.head);
                const tail_val = try self.readLocal(frame, lc.tail);
                const elems = try self.allocator.alloc(CtValue, 2);
                var initialized_elem_count: usize = 0;
                var elems_transferred = false;
                errdefer if (!elems_transferred) {
                    freeUncommittedCtValueSlots(self.allocator, elems, initialized_elem_count);
                };
                elems[0] = head_val;
                initialized_elem_count += 1;
                elems[1] = tail_val;
                initialized_elem_count += 1;
                const alloc_id = try self.allocIdForDest(frame, lc.dest, .tuple);
                try self.setAggregateLocal(lc.dest, frame, .{ .tuple = .{ .alloc_id = alloc_id, .elems = elems } });
                elems_transferred = true;
                return .continued;
            },
            .map_init => |mi| {
                const entries = try self.allocator.alloc(CtValue.CtMapEntry, mi.entries.len);
                var initialized_entry_count: usize = 0;
                var entries_transferred = false;
                errdefer if (!entries_transferred) {
                    freeUncommittedCtMapEntries(self.allocator, entries, initialized_entry_count);
                };
                for (mi.entries, 0..) |entry, i| {
                    entries[i] = .{
                        .key = try self.readLocal(frame, entry.key),
                        .value = try self.readLocal(frame, entry.value),
                    };
                    initialized_entry_count += 1;
                }
                const alloc_id = try self.allocIdForDest(frame, mi.dest, .map);
                try self.setAggregateLocal(mi.dest, frame, .{ .map = .{ .alloc_id = alloc_id, .entries = entries } });
                entries_transferred = true;
                return .continued;
            },
            .struct_init => |si| {
                const fields = try self.allocator.alloc(CtValue.CtFieldValue, si.fields.len);
                var initialized_field_count: usize = 0;
                var fields_transferred = false;
                errdefer if (!fields_transferred) {
                    freeUncommittedCtFieldValues(self.allocator, fields, initialized_field_count);
                };
                for (si.fields, 0..) |field, i| {
                    fields[i] = .{
                        .name = field.name,
                        .value = try self.readLocal(frame, field.value),
                    };
                    initialized_field_count += 1;
                }
                const alloc_id = try self.allocIdForDest(frame, si.dest, .struct_val);
                try self.setAggregateLocal(si.dest, frame, .{ .struct_val = .{
                    .alloc_id = alloc_id,
                    .type_name = si.type_name,
                    .fields = fields,
                } });
                fields_transferred = true;
                return .continued;
            },
            .union_init => |ui| {
                const payload = try self.allocator.create(CtValue);
                var payload_initialized = false;
                var payload_transferred = false;
                errdefer if (!payload_transferred) {
                    if (payload_initialized) payload.* = .void;
                    self.allocator.destroy(payload);
                };
                payload.* = try self.readLocal(frame, ui.value);
                payload_initialized = true;
                const alloc_id = try self.allocIdForDest(frame, ui.dest, .union_val);
                try self.setAggregateLocal(ui.dest, frame, .{ .union_val = .{
                    .alloc_id = alloc_id,
                    .type_name = ui.union_type,
                    .variant = ui.variant_name,
                    .payload = payload,
                } });
                payload_transferred = true;
                return .continued;
            },
            .enum_literal => |el| {
                frame.setLocal(el.dest, .{ .enum_val = .{
                    .type_name = el.type_name,
                    .variant = el.variant,
                } });
                return .continued;
            },

            // === Access ===
            .field_get => |fg| {
                const result = try self.evalFieldGet(fg, frame);
                frame.setLocal(fg.dest, result);
                return .continued;
            },
            .index_get => |ig| {
                const result = try self.evalIndexGet(ig, frame);
                frame.setLocal(ig.dest, result);
                return .continued;
            },
            .list_get => |lg| {
                const result = try self.evalListGet(lg, frame);
                frame.setLocal(lg.dest, result);
                return .continued;
            },
            .list_is_not_empty => |lne| {
                const list_val = try self.readLocal(frame, lne.list);
                const is_not_empty: bool = switch (list_val) {
                    .list => |l| l.elems.len > 0,
                    .nil => false,
                    else => true,
                };
                frame.setLocal(lne.dest, .{ .bool_val = is_not_empty });
                return .continued;
            },
            .list_head => |lh| {
                const list_val = try self.readLocal(frame, lh.list);
                switch (list_val) {
                    .list => |l| {
                        if (l.elems.len == 0) {
                            try self.emitError(.index_out_of_bounds, "list_head on empty list");
                            return error.CtfeFailure;
                        }
                        frame.setLocal(lh.dest, l.elems[0]);
                    },
                    .tuple => |t| {
                        if (t.elems.len == 0) {
                            try self.emitError(.index_out_of_bounds, "list_head on empty tuple-backed list cell");
                            return error.CtfeFailure;
                        }
                        frame.setLocal(lh.dest, t.elems[0]);
                    },
                    else => {
                        try self.emitError(.type_error, "list_head on non-list value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },
            .list_tail => |lt| {
                const list_val = try self.readLocal(frame, lt.list);
                switch (list_val) {
                    .list => |l| {
                        const start: usize = lt.start_index;
                        if (start >= l.elems.len) {
                            frame.setLocal(lt.dest, .nil);
                        } else {
                            const tail_elems = try self.allocator.alloc(CtValue, l.elems.len - start);
                            @memcpy(tail_elems, l.elems[start..]);
                            frame.setLocal(lt.dest, .{ .list = .{ .alloc_id = l.alloc_id, .elems = tail_elems } });
                        }
                    },
                    .tuple => |t| {
                        if (t.elems.len < 2) {
                            try self.emitError(.index_out_of_bounds, "list_tail on tuple-backed list cell with no tail");
                            return error.CtfeFailure;
                        }
                        frame.setLocal(lt.dest, t.elems[1]);
                    },
                    else => {
                        try self.emitError(.type_error, "list_tail on non-list value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },
            .map_has_key => |mhk| {
                const map_val = try self.readLocal(frame, mhk.map);
                const key_val = try self.readLocal(frame, mhk.key);
                switch (map_val) {
                    .map => |mv| {
                        var found = false;
                        for (mv.entries) |entry| {
                            if (entry.key.eqlWithAllocator(self.allocator, key_val) catch |err| return self.traversalFailure(err)) {
                                found = true;
                                break;
                            }
                        }
                        frame.setLocal(mhk.dest, .{ .bool_val = found });
                    },
                    else => {
                        try self.emitError(.type_error, "map_has_key on non-map value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },
            .map_get => |mg| {
                const map_val = try self.readLocal(frame, mg.map);
                const key_val = try self.readLocal(frame, mg.key);
                switch (map_val) {
                    .map => |mv| {
                        var result: ?CtValue = null;
                        for (mv.entries) |entry| {
                            if (entry.key.eqlWithAllocator(self.allocator, key_val) catch |err| return self.traversalFailure(err)) {
                                result = entry.value;
                                break;
                            }
                        }
                        if (result) |val| {
                            frame.setLocal(mg.dest, val);
                        } else {
                            frame.setLocal(mg.dest, try self.readLocal(frame, mg.default));
                        }
                    },
                    else => {
                        try self.emitError(.type_error, "map_get on non-map value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },
            .list_len_check => |lc| {
                const obj = try self.readLocal(frame, lc.scrutinee);
                const result: bool = switch (obj) {
                    .list => |l| if (lc.minimum) l.elems.len >= lc.expected_len else l.elems.len == lc.expected_len,
                    .tuple => |t| if (lc.minimum) t.elems.len >= lc.expected_len else t.elems.len == lc.expected_len,
                    else => false,
                };
                frame.setLocal(lc.dest, .{ .bool_val = result });
                return .continued;
            },
            .optional_unwrap => |ou| {
                const val = try self.readLocal(frame, ou.source);
                switch (val) {
                    .optional => |o| {
                        if (o.value) |v| {
                            frame.setLocal(ou.dest, v.*);
                        } else {
                            try self.emitError(.type_error, "unwrap of nil optional");
                            return error.CtfeFailure;
                        }
                    },
                    .nil => {
                        try self.emitError(.type_error, "unwrap of nil");
                        return error.CtfeFailure;
                    },
                    else => frame.setLocal(ou.dest, val),
                }
                return .continued;
            },

            // === Structured control flow ===
            .if_expr => |ie| return self.execIfExpr(ie, frame),
            .case_block => |cb| return self.execCaseBlock(cb, frame),
            .switch_literal => |sl| return self.execSwitchLiteral(sl, frame),
            .switch_return => |sr| return self.execSwitchReturn(sr, frame),
            .union_switch_return => |usr| return self.execUnionSwitchReturn(usr, frame),
            .union_switch => |us| return self.execUnionSwitch(us, frame),
            .optional_dispatch => |od| return self.execOptionalDispatch(od, frame),
            .branch => |b| return .{ .jumped = b.target },
            .cond_branch => |cb| {
                const cond = try self.readLocal(frame, cb.condition);
                return .{ .jumped = if (cond.isTruthy()) cb.then_target else cb.else_target };
            },
            .switch_tag => |st| {
                const scrutinee = try self.readLocal(frame, st.scrutinee);
                const tag = switch (scrutinee) {
                    .union_val => |uv| uv.variant,
                    .enum_val => |ev| ev.variant,
                    .atom => |a| a,
                    else => {
                        try self.emitError(.type_error, "switch_tag on non-tagged value");
                        return error.CtfeFailure;
                    },
                };
                for (st.cases) |case| {
                    if (std.mem.eql(u8, tag, case.tag)) return .{ .jumped = case.target };
                }
                return .{ .jumped = st.default };
            },
            .guard_block => |gb| {
                if ((try self.readLocal(frame, gb.condition)).isTruthy()) {
                    for (gb.body, 0..) |body_instr, body_idx| {
                        self.setCurrentInstructionIndex(body_idx);
                        const r = try self.execOneInstruction(body_instr, frame);
                        switch (r) {
                            .continued => {},
                            .returned => |v| return .{ .returned = v },
                            .broke => |v| return .{ .broke = v },
                            .jumped => |target| return .{ .jumped = target },
                        }
                    }
                }
                return .continued;
            },

            // === Calls ===
            .call_direct => |cd| {
                const result = try self.execCallDirect(cd, frame);
                frame.setLocal(cd.dest, result);
                return .continued;
            },
            .call_named => |cn| {
                const result = try self.execCallNamed(cn, frame);
                frame.setLocal(cn.dest, result);
                return .continued;
            },
            .try_call_named => |tcn| {
                // try_call_named behaves like call_named at CTFE level;
                // the error union semantics are handled by error_catch.
                const result = try self.execCallNamed(.{
                    .dest = tcn.dest,
                    .name = tcn.name,
                    .args = tcn.args,
                    .arg_modes = tcn.arg_modes,
                }, frame);
                frame.setLocal(tcn.dest, result);
                return .continued;
            },
            .error_catch => |ec| {
                // At CTFE, if source holds a value, pass it through;
                // error handling is structural — catch_value is the fallback.
                const source_val = try self.readLocal(frame, ec.source);
                frame.setLocal(ec.dest, source_val);
                return .continued;
            },
            .unwrap_error_union => |ueu| {
                // Phase 3.b: at CTFE a raising call cannot have produced an
                // error (a comptime raise is rejected at the call), so the
                // source already holds the payload — pass it through.
                const source_val = try self.readLocal(frame, ueu.source);
                frame.setLocal(ueu.dest, source_val);
                return .continued;
            },
            .call_builtin => |cb| {
                const result = try self.execCallBuiltin(cb, frame);
                frame.setLocal(cb.dest, result);
                return .continued;
            },
            .tail_call => |tc| {
                const result = try self.execTailCall(tc, frame);
                return .{ .returned = result };
            },

            // === Return / break ===
            .ret => |r| {
                return .{ .returned = if (r.value) |v| try self.readLocal(frame, v) else .void };
            },
            .cond_return => |cr| {
                if ((try self.readLocal(frame, cr.condition)).isTruthy()) {
                    return .{ .returned = if (cr.value) |v| try self.readLocal(frame, v) else .void };
                }
                return .continued;
            },
            .case_break => |cb| {
                return .{ .broke = if (cb.value) |v| try self.readLocal(frame, v) else null };
            },

            // === Match ===
            .match_atom => |ma| {
                const scrutinee = try self.readLocal(frame, ma.scrutinee);
                const matches = switch (scrutinee) {
                    .atom => |a| std.mem.eql(u8, a, ma.atom_name),
                    else => false,
                };
                frame.setLocal(ma.dest, .{ .bool_val = matches });
                return .continued;
            },
            .match_variant_tag => |mvt| {
                // CTFE evaluates tagged-union scrutinees as
                // `union_val` CtValues carrying the variant name;
                // comparing the name matches the runtime activeTag
                // check. Enum CtValues compare via their variant
                // field; atom fallback mirrors `match_atom`'s
                // liberal handling for hand-built fixtures.
                const scrutinee = try self.readLocal(frame, mvt.scrutinee);
                const matches = switch (scrutinee) {
                    .union_val => |uv| std.mem.eql(u8, uv.variant, mvt.variant_name),
                    .enum_val => |ev| std.mem.eql(u8, ev.variant, mvt.variant_name),
                    .atom => |a| std.mem.eql(u8, a, mvt.variant_name),
                    else => false,
                };
                frame.setLocal(mvt.dest, .{ .bool_val = matches });
                return .continued;
            },
            .variant_payload_get => |vpg| {
                // Extract the variant's payload value from a CTFE
                // union_val CtValue. Enum values (nullary variants
                // with no payload) yield nil, as do non-union
                // scrutinees — a guard_block precedes this in the
                // emitted IR so unreachable extraction is harmless.
                const scrutinee = try self.readLocal(frame, vpg.scrutinee);
                const payload: CtValue = switch (scrutinee) {
                    .union_val => |uv| uv.payload.*,
                    else => .nil,
                };
                frame.setLocal(vpg.dest, payload);
                return .continued;
            },
            .match_int => |mi| {
                const scrutinee = try self.readLocal(frame, mi.scrutinee);
                const matches = switch (scrutinee) {
                    .int => |v| v == mi.value,
                    else => false,
                };
                frame.setLocal(mi.dest, .{ .bool_val = matches });
                return .continued;
            },
            .match_float => |mf| {
                const scrutinee = try self.readLocal(frame, mf.scrutinee);
                const matches = switch (scrutinee) {
                    .float => |v| v == mf.value,
                    else => false,
                };
                frame.setLocal(mf.dest, .{ .bool_val = matches });
                return .continued;
            },
            .match_string => |ms| {
                const scrutinee = try self.readLocal(frame, ms.scrutinee);
                const matches = switch (scrutinee) {
                    .string => |v| std.mem.eql(u8, v, ms.expected),
                    else => false,
                };
                frame.setLocal(ms.dest, .{ .bool_val = matches });
                return .continued;
            },
            .match_type => |mt| {
                const scrutinee = try self.readLocal(frame, mt.scrutinee);
                const matches = matchesZigType(scrutinee, mt.expected_type);
                frame.setLocal(mt.dest, .{ .bool_val = matches });
                return .continued;
            },
            .match_fail => |mf| {
                if (mf.message_local) |ml| {
                    // Panic expression — surface the actual message
                    const msg_val = self.readLocal(frame, ml) catch {
                        try self.emitError(.match_failure, mf.message);
                        return error.CtfeFailure;
                    };
                    const msg = switch (msg_val) {
                        .string => |s| s,
                        else => mf.message,
                    };
                    try self.emitError(.match_failure, msg);
                } else {
                    try self.emitError(.match_failure, "no matching clause at compile time");
                }
                return error.CtfeFailure;
            },
            .match_error_return => {
                try self.emitError(.match_failure, "no matching clause at compile time (try variant)");
                return error.CtfeFailure;
            },
            // Phase 3.b: a propagating `raise` cannot be evaluated at compile
            // time — a comptime raise is a compile error, mirroring the
            // match-error-return CTFE rejection above.
            .ret_raise => {
                try self.emitError(.match_failure, "`raise` cannot propagate at compile time");
                return error.CtfeFailure;
            },

            // === ARC (ownership-aware at compile time) ===
            .retain => |ret| {
                // Retain increments reference count. At CTFE, values are by-value
                // so this is a semantic check: the value should not be void/moved.
                // No actual count tracking needed with by-value semantics.
                _ = try self.readLocal(frame, ret.value);
                return .continued;
            },
            .release => |rel| {
                // Release decrements reference count. At CTFE, mark the value
                // as consumed (void) to catch use-after-release errors.
                _ = try self.readLocal(frame, rel.value);
                frame.setLocal(rel.value, .consumed);
                return .continued;
            },
            .reset => |rst| {
                // Perceus reset: if RC=1, make memory available for reuse.
                // At CTFE, the source value is consumed and a reuse token is produced.
                const source = try self.readLocal(frame, rst.source);
                frame.setLocal(rst.dest, if (getReuseInfo(source)) |rt| .{ .reuse_token = rt } else .nil);
                frame.setLocal(rst.source, .consumed);
                return .continued;
            },
            .reuse_alloc => |ra| {
                // Perceus reuse: validate and consume the token if present.
                if (ra.token) |token_local| {
                    const token = try self.readLocal(frame, token_local);
                    switch (token) {
                        .reuse_token => |rt| {
                            frame.setLocal(token_local, .consumed);
                            frame.setLocal(ra.dest, .{ .reuse_token = rt });
                        },
                        .nil => {},
                        else => {
                            try self.emitError(.type_error, "reuse_alloc expects a reuse token or nil");
                            return error.CtfeFailure;
                        },
                    }
                } else {
                    frame.setLocal(ra.dest, .void);
                }
                return .continued;
            },

            // === Closures ===
            .make_closure => |mc| {
                const caps = try self.collectLocals(mc.captures, frame);
                const alloc_id = try self.allocIdForDest(frame, mc.dest, .closure);
                frame.setLocal(mc.dest, .{ .closure = .{
                    .alloc_id = alloc_id,
                    .function_id = mc.function,
                    .captures = caps,
                } });
                return .continued;
            },
            .capture_get => |cg| {
                frame.setLocal(cg.dest, try self.readCaptured(frame, cg.index));
                return .continued;
            },
            .call_closure => |cc| {
                const callee = try self.readLocal(frame, cc.callee);
                switch (callee) {
                    .closure => |cl| {
                        const args = try self.collectLocals(cc.args, frame);
                        // Save and set captures on the new frame
                        const result = try self.evalClosureCall(cl.function_id, args, cl.captures);
                        frame.setLocal(cc.dest, result);
                    },
                    else => {
                        try self.emitError(.type_error, "call_closure on non-closure value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },

            // === field_set (copy-on-write) ===
            .field_set => |fs| {
                const obj = try self.readLocal(frame, fs.object);
                switch (obj) {
                    .struct_val => |sv| {
                        const new_fields = self.allocator.alloc(CtValue.CtFieldValue, sv.fields.len) catch return error.OutOfMemory;
                        var new_fields_committed = false;
                        errdefer if (!new_fields_committed) self.allocator.free(new_fields);
                        for (sv.fields, 0..) |field, i| {
                            if (std.mem.eql(u8, field.name, fs.field)) {
                                new_fields[i] = .{ .name = field.name, .value = try self.readLocal(frame, fs.value) };
                            } else {
                                new_fields[i] = field;
                            }
                        }
                        frame.setLocal(fs.object, .{ .struct_val = .{
                            .alloc_id = sv.alloc_id,
                            .type_name = sv.type_name,
                            .fields = new_fields,
                        } });
                        new_fields_committed = true;
                    },
                    .map => |mv| {
                        const replacement_value = try self.readLocal(frame, fs.value);
                        const replacement_entries = rebuildMapEntriesForFieldSet(
                            self.allocator,
                            mv.entries,
                            fs.field,
                            replacement_value,
                        ) catch return error.OutOfMemory;
                        var replacement_entries_committed = false;
                        errdefer if (!replacement_entries_committed) self.allocator.free(replacement_entries);
                        frame.setLocal(fs.object, .{ .map = .{ .alloc_id = mv.alloc_id, .entries = replacement_entries } });
                        replacement_entries_committed = true;
                    },
                    else => {
                        try self.emitError(.type_error, "field_set on non-struct/map value");
                        return error.CtfeFailure;
                    },
                }
                return .continued;
            },

            // === Binary pattern matching ===
            .bin_len_check => |blc| {
                const val = try self.readLocal(frame, blc.scrutinee);
                const bytes = getBinaryBytes(val);
                frame.setLocal(blc.dest, .{ .bool_val = if (bytes) |b| b.len >= blc.min_len else false });
                return .continued;
            },
            .bin_read_int => |bri| {
                const source = getBinaryBytes(try self.readLocal(frame, bri.source)) orelse {
                    try self.emitError(.type_error, "bin_read_int on non-binary value");
                    return error.CtfeFailure;
                };
                const offset = try self.resolveOffset(bri.offset, frame);
                const byte_count: usize = (@as(usize, bri.bits) + 7) / 8;
                if (offset + byte_count > source.len) {
                    try self.emitError(.index_out_of_bounds, "binary read out of bounds");
                    return error.CtfeFailure;
                }
                const bytes = source[offset..][0..byte_count];
                var result: i64 = 0;
                for (bytes) |b| {
                    if (bri.endianness == .little) {
                        // Will handle below
                    }
                    result = (result << 8) | @as(i64, b);
                }
                if (bri.endianness == .little) {
                    result = 0;
                    for (0..byte_count) |i| {
                        result |= @as(i64, bytes[i]) << @intCast(i * 8);
                    }
                }
                if (bri.signed and byte_count > 0) {
                    const sign_bit = @as(u6, @intCast(bri.bits - 1));
                    const mask = @as(i64, 1) << sign_bit;
                    if (result & mask != 0) {
                        result = result - (@as(i64, 1) << @as(u6, @intCast(bri.bits)));
                    }
                }
                frame.setLocal(bri.dest, .{ .int = result });
                return .continued;
            },
            .bin_read_float => |brf| {
                const source = getBinaryBytes(try self.readLocal(frame, brf.source)) orelse {
                    try self.emitError(.type_error, "bin_read_float on non-binary value");
                    return error.CtfeFailure;
                };
                const offset = try self.resolveOffset(brf.offset, frame);
                if (brf.bits == 64) {
                    if (offset + 8 > source.len) {
                        try self.emitError(.index_out_of_bounds, "binary read out of bounds");
                        return error.CtfeFailure;
                    }
                    var buf: [8]u8 = undefined;
                    @memcpy(&buf, source[offset..][0..8]);
                    const val: f64 = @bitCast(std.mem.readInt(u64, &buf, if (brf.endianness == .little) .little else .big));
                    frame.setLocal(brf.dest, .{ .float = val });
                } else {
                    if (offset + 4 > source.len) {
                        try self.emitError(.index_out_of_bounds, "binary read out of bounds");
                        return error.CtfeFailure;
                    }
                    var buf: [4]u8 = undefined;
                    @memcpy(&buf, source[offset..][0..4]);
                    const val: f32 = @bitCast(std.mem.readInt(u32, &buf, if (brf.endianness == .little) .little else .big));
                    frame.setLocal(brf.dest, .{ .float = @floatCast(val) });
                }
                return .continued;
            },
            .bin_slice => |bs| {
                const source = getBinaryBytes(try self.readLocal(frame, bs.source)) orelse {
                    try self.emitError(.type_error, "bin_slice on non-binary value");
                    return error.CtfeFailure;
                };
                const offset = try self.resolveOffset(bs.offset, frame);
                if (offset > source.len) {
                    try self.emitError(.index_out_of_bounds, "binary slice offset out of bounds");
                    return error.CtfeFailure;
                }
                if (bs.length) |len_offset| {
                    const length = try self.resolveOffset(len_offset, frame);
                    const end = offset + length;
                    if (end > source.len) {
                        try self.emitError(.index_out_of_bounds, "binary slice length out of bounds");
                        return error.CtfeFailure;
                    }
                    frame.setLocal(bs.dest, .{ .string = source[offset..end] });
                } else {
                    frame.setLocal(bs.dest, .{ .string = source[offset..] });
                }
                return .continued;
            },
            .bin_read_utf8 => |bru| {
                const source = getBinaryBytes(try self.readLocal(frame, bru.source)) orelse {
                    try self.emitError(.type_error, "bin_read_utf8 on non-binary value");
                    return error.CtfeFailure;
                };
                const offset = try self.resolveOffset(bru.offset, frame);
                if (offset >= source.len) {
                    try self.emitError(.index_out_of_bounds, "binary read_utf8 out of bounds");
                    return error.CtfeFailure;
                }
                const byte_len = std.unicode.utf8ByteSequenceLength(source[offset]) catch {
                    try self.emitError(.type_error, "invalid UTF-8 sequence");
                    return error.CtfeFailure;
                };
                if (offset + byte_len > source.len) {
                    try self.emitError(.index_out_of_bounds, "incomplete UTF-8 sequence");
                    return error.CtfeFailure;
                }
                const codepoint = std.unicode.utf8Decode(source[offset..][0..byte_len]) catch {
                    try self.emitError(.type_error, "invalid UTF-8 codepoint");
                    return error.CtfeFailure;
                };
                frame.setLocal(bru.dest_codepoint, .{ .int = @intCast(codepoint) });
                frame.setLocal(bru.dest_len, .{ .int = @intCast(byte_len) });
                return .continued;
            },
            .bin_match_prefix => |bmp| {
                const source = getBinaryBytes(try self.readLocal(frame, bmp.source)) orelse {
                    frame.setLocal(bmp.dest, .{ .bool_val = false });
                    return .continued;
                };
                // Compare at the segment's byte offset, not always at byte 0,
                // mirroring the runtime helper (audit ir-1--01).
                const offset = try self.resolveOffset(bmp.offset, frame);
                const matches = offset <= source.len and
                    std.mem.startsWith(u8, source[offset..], bmp.expected);
                frame.setLocal(bmp.dest, .{ .bool_val = matches });
                return .continued;
            },

            // === Numeric widening (identity at CTFE — values are untyped) ===
            .int_widen, .float_widen => |nw| {
                frame.setLocal(nw.dest, try self.readLocal(frame, nw.source));
                return .continued;
            },

            // === dispatch and jump ===
            .call_dispatch => |cd| {
                // Dynamic dispatch by group_id — resolve to function by ID
                const args = try self.collectLocals(cd.args, frame);
                // Use evalFunction which does ID-based lookup (not array index)
                const result = try self.evalFunction(cd.group_id, args);
                frame.setLocal(cd.dest, result);
                return .continued;
            },
            .jump => |j| {
                // In structured IR, jump binds a value to a dest local
                if (j.bind_dest) |dest| {
                    if (j.value) |value| {
                        frame.setLocal(dest, try self.readLocal(frame, value));
                    }
                }
                return .continued;
            },

            // === Safety (no-op at CTFE) ===
            .set_safety => return .continued,

            // === Debug info (no-op at CTFE; metadata only — DWARF
            //     emission happens in the ZIR backend) ===
            .dbg_stmt, .dbg_var => return .continued,

            // === Dead instructions (never emitted by IR builder) ===
            .phi,
            => {
                try self.emitError(.unsupported_instruction, "unsupported instruction in CTFE");
                return error.CtfeFailure;
            },

            // === Runtime-only (Phase 1.2.5.c construction-site
            //     auto-boxing) ===
            //
            // `box_as_protocol` allocates a heap cell, retains it,
            // and binds it to a per-impl vtable constant — all of
            // which require a runtime memory manager and a linked
            // synthetic vtable file. CTFE has neither. The IR
            // construction-site detector runs after CTFE in the
            // compilation pipeline (CTFE consumes the unmonomorphized
            // HIR-shaped program; construction-site detection is an
            // IR-build pass), so a well-formed pipeline never feeds
            // a `box_as_protocol` to the interpreter — the explicit
            // reject keeps the contract honest if that invariant
            // ever drifts.
            .box_as_protocol => {
                try self.emitError(
                    .unsupported_instruction,
                    "protocol existential boxing is a runtime operation; cannot evaluate at compile time",
                );
                return error.CtfeFailure;
            },

            // Phase 1.2.5.d: dispatch + downcast against a protocol
            // existential. Both ops require resolving a vtable
            // function pointer or comparing against an emitted
            // vtable instance constant — neither exists at CTFE
            // time. Same justification as `.box_as_protocol`: the
            // pipeline never feeds these into the interpreter.
            .protocol_dispatch => {
                try self.emitError(
                    .unsupported_instruction,
                    "protocol dispatch is a runtime operation; cannot evaluate at compile time",
                );
                return error.CtfeFailure;
            },
            .protocol_box_unbox => {
                try self.emitError(
                    .unsupported_instruction,
                    "protocol existential downcast is a runtime operation; cannot evaluate at compile time",
                );
                return error.CtfeFailure;
            },
            .protocol_box_vtable_eq => {
                try self.emitError(
                    .unsupported_instruction,
                    "protocol existential vtable test is a runtime operation; cannot evaluate at compile time",
                );
                return error.CtfeFailure;
            },

            // Phase 3.a: typed-undefined placeholder for the statically-dead
            // normal-completion edge of a `try`/`rescue` landing pad. It only
            // appears in IR-lowered runtime control flow (the IR builder emits
            // it in `lowerTryRescue`), never in a comptime-evaluated function,
            // so the pipeline never feeds it to the interpreter. Reject loudly
            // if that invariant ever drifts rather than fabricating a value.
            .typed_undef => {
                try self.emitError(
                    .unsupported_instruction,
                    "typed-undefined placeholder is a runtime dead-edge value; cannot evaluate at compile time",
                );
                return error.CtfeFailure;
            },
        }
    }

    // --------------------------------------------------------
    // Binary operations
    // --------------------------------------------------------

    fn evalBinaryOp(self: *Interpreter, op: ir.BinaryOp, frame: *const Frame) CtfeInterpretError!CtValue {
        const lhs = try self.readLocal(frame, op.lhs);
        const rhs = try self.readLocal(frame, op.rhs);

        switch (op.op) {
            .add => return self.numericOp(lhs, rhs, .add),
            .sub => return self.numericOp(lhs, rhs, .sub),
            .mul => return self.numericOp(lhs, rhs, .mul),
            .div => {
                // Check division by zero and the minInt / -1 signed-overflow
                // corner. Both are illegal behavior for the raw `@divTrunc`
                // in `numericOp` (a compile-time crash in safe compiler
                // builds), so they are turned into clean CTFE diagnostics
                // here, mirroring the runtime `Kernel.divInteger` guard so a
                // comptime `1 / 0` / `minInt / -1` behaves like its runtime
                // counterpart (both error) instead of panicking the compiler.
                switch (rhs) {
                    .int => |v| {
                        if (v == 0) {
                            try self.emitError(.division_by_zero, "division by zero");
                            return error.CtfeFailure;
                        }
                        if (v == -1 and lhs == .int and lhs.int == std.math.minInt(i64)) {
                            try self.emitError(.arithmetic_overflow, "integer overflow in division (minInt / -1)");
                            return error.CtfeFailure;
                        }
                    },
                    .float => |v| if (v == 0.0) {
                        try self.emitError(.division_by_zero, "division by zero");
                        return error.CtfeFailure;
                    },
                    else => {},
                }
                return self.numericOp(lhs, rhs, .div);
            },
            .rem_op => {
                switch (rhs) {
                    .int => |v| {
                        if (v == 0) {
                            try self.emitError(.division_by_zero, "remainder by zero");
                            return error.CtfeFailure;
                        }
                        if (v == -1 and lhs == .int and lhs.int == std.math.minInt(i64)) {
                            try self.emitError(.arithmetic_overflow, "integer overflow in remainder (minInt rem -1)");
                            return error.CtfeFailure;
                        }
                    },
                    else => {},
                }
                return self.numericOp(lhs, rhs, .rem_op);
            },
            .eq, .string_eq, .tuple_eq => return .{ .bool_val = lhs.eqlWithAllocator(self.allocator, rhs) catch |err| return self.traversalFailure(err) },
            .neq, .string_neq, .tuple_neq => return .{ .bool_val = !(lhs.eqlWithAllocator(self.allocator, rhs) catch |err| return self.traversalFailure(err)) },
            .lt => {
                const ord = lhs.compare(rhs) orelse {
                    try self.emitError(.type_error, "incomparable types");
                    return error.CtfeFailure;
                };
                return .{ .bool_val = ord == .lt };
            },
            .gt => {
                const ord = lhs.compare(rhs) orelse {
                    try self.emitError(.type_error, "incomparable types");
                    return error.CtfeFailure;
                };
                return .{ .bool_val = ord == .gt };
            },
            .lte => {
                const ord = lhs.compare(rhs) orelse {
                    try self.emitError(.type_error, "incomparable types");
                    return error.CtfeFailure;
                };
                return .{ .bool_val = ord != .gt };
            },
            .gte => {
                const ord = lhs.compare(rhs) orelse {
                    try self.emitError(.type_error, "incomparable types");
                    return error.CtfeFailure;
                };
                return .{ .bool_val = ord != .lt };
            },
            .bool_and => return .{ .bool_val = lhs.isTruthy() and rhs.isTruthy() },
            .bool_or => return .{ .bool_val = lhs.isTruthy() or rhs.isTruthy() },
            .concat => return self.evalConcat(lhs, rhs),
            .in_list => {
                switch (rhs) {
                    .list => |list| {
                        for (list.elems) |elem| {
                            if (lhs.eqlWithAllocator(self.allocator, elem) catch |err| return self.traversalFailure(err)) return .{ .bool_val = true };
                        }
                        return .{ .bool_val = false };
                    },
                    else => {
                        try self.emitError(.type_error, "'in' requires a list on the right-hand side");
                        return error.CtfeFailure;
                    },
                }
            },
            .in_range => {
                // Range membership: check value is between start/end and on step boundary
                switch (rhs) {
                    .struct_val => |sv| {
                        const val = switch (lhs) {
                            .int => |v| v,
                            else => return .{ .bool_val = false },
                        };
                        var start: i64 = 0;
                        var end_val: i64 = 0;
                        var step: i64 = 1;
                        for (sv.fields) |field| {
                            if (std.mem.eql(u8, field.name, "start")) start = if (field.value == .int) field.value.int else 0;
                            if (std.mem.eql(u8, field.name, "end")) end_val = if (field.value == .int) field.value.int else 0;
                            if (std.mem.eql(u8, field.name, "step")) step = if (field.value == .int) field.value.int else 1;
                        }
                        const min_v = @min(start, end_val);
                        const max_v = @max(start, end_val);
                        if (val < min_v or val > max_v) return .{ .bool_val = false };
                        if (step == 0) return .{ .bool_val = false };
                        return .{ .bool_val = @rem(val - start, step) == 0 };
                    },
                    else => return .{ .bool_val = false },
                }
            },
        }
    }

    fn numericOp(self: *Interpreter, lhs: CtValue, rhs: CtValue, op: ir.BinaryOp.Op) CtfeInterpretError!CtValue {
        switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| {
                    // Guard the integer division/remainder edge cases even
                    // when reached directly (not only via `evalBinaryOp`):
                    // raw `@divTrunc`/`@rem` are illegal behavior on a zero
                    // divisor or `minInt / -1` and would panic the compiler.
                    if (op == .div or op == .rem_op) {
                        if (b == 0) {
                            try self.emitError(.division_by_zero, if (op == .div) "division by zero" else "remainder by zero");
                            return error.CtfeFailure;
                        }
                        if (b == -1 and a == std.math.minInt(i64)) {
                            try self.emitError(.arithmetic_overflow, "integer overflow");
                            return error.CtfeFailure;
                        }
                    }
                    return .{ .int = switch (op) {
                        .add => a +% b,
                        .sub => a -% b,
                        .mul => a *% b,
                        .div => @divTrunc(a, b),
                        .rem_op => @rem(a, b),
                        else => unreachable,
                    } };
                },
                else => {},
            },
            .float => |a| switch (rhs) {
                .float => |b| return .{ .float = switch (op) {
                    .add => a + b,
                    .sub => a - b,
                    .mul => a * b,
                    .div => a / b,
                    .rem_op => @rem(a, b),
                    else => unreachable,
                } },
                else => {},
            },
            else => {},
        }
        try self.emitError(.type_error, "numeric operation on non-numeric types");
        return error.CtfeFailure;
    }

    fn evalUnaryOp(self: *Interpreter, op: ir.UnaryOp, frame: *const Frame) CtfeInterpretError!CtValue {
        const operand = try self.readLocal(frame, op.operand);
        switch (op.op) {
            .negate => switch (operand) {
                .int => |v| return .{ .int = -%v },
                .float => |v| return .{ .float = -v },
                else => {
                    try self.emitError(.type_error, "negate on non-numeric type");
                    return error.CtfeFailure;
                },
            },
            .bool_not => return .{ .bool_val = !operand.isTruthy() },
        }
    }

    fn evalConcat(self: *Interpreter, lhs: CtValue, rhs: CtValue) CtfeInterpretError!CtValue {
        switch (lhs) {
            .string => |a| switch (rhs) {
                .string => |b| {
                    const result = self.allocator.alloc(u8, a.len + b.len) catch return error.OutOfMemory;
                    @memcpy(result[0..a.len], a);
                    @memcpy(result[a.len..], b);
                    return .{ .string = result };
                },
                else => {},
            },
            .list => |a| switch (rhs) {
                .list => |b| {
                    const result = self.allocator.alloc(CtValue, a.elems.len + b.elems.len) catch return error.OutOfMemory;
                    @memcpy(result[0..a.elems.len], a.elems);
                    @memcpy(result[a.elems.len..], b.elems);
                    return finishBorrowedCtValueList(self.allocator, &self.allocation_store, self.currentFunctionId(), result);
                },
                else => {},
            },
            else => {},
        }
        try self.emitError(.type_error, "concat on incompatible types");
        return error.CtfeFailure;
    }

    // --------------------------------------------------------
    // Access operations
    // --------------------------------------------------------

    fn evalFieldGet(self: *Interpreter, fg: ir.FieldGet, frame: *const Frame) CtfeInterpretError!CtValue {
        const obj = try self.readLocal(frame, fg.object);
        switch (obj) {
            .struct_val => |sv| {
                for (sv.fields) |field| {
                    if (std.mem.eql(u8, field.name, fg.field)) {
                        return field.value;
                    }
                }
                try self.emitError(.type_error, "field not found");
                return error.CtfeFailure;
            },
            .map => |mv| {
                for (mv.entries) |entry| {
                    switch (entry.key) {
                        .string => |k| if (std.mem.eql(u8, k, fg.field)) return entry.value,
                        .atom => |k| if (std.mem.eql(u8, k, fg.field)) return entry.value,
                        else => {},
                    }
                }
                try self.emitError(.type_error, "key not found in map");
                return error.CtfeFailure;
            },
            else => {
                try self.emitError(.type_error, "field_get on non-struct/map value");
                return error.CtfeFailure;
            },
        }
    }

    fn evalIndexGet(self: *Interpreter, ig: ir.IndexGet, frame: *const Frame) CtfeInterpretError!CtValue {
        const obj = try self.readLocal(frame, ig.object);
        switch (obj) {
            .tuple => |t| {
                if (ig.index >= t.elems.len) {
                    try self.emitError(.index_out_of_bounds, "tuple index out of bounds");
                    return error.CtfeFailure;
                }
                return t.elems[ig.index];
            },
            else => {
                try self.emitError(.type_error, "index_get on non-tuple value");
                return error.CtfeFailure;
            },
        }
    }

    fn evalListGet(self: *Interpreter, lg: ir.ListGet, frame: *const Frame) CtfeInterpretError!CtValue {
        const obj = try self.readLocal(frame, lg.list);
        switch (obj) {
            .list => |l| {
                if (lg.index >= l.elems.len) {
                    try self.emitError(.index_out_of_bounds, "list index out of bounds");
                    return error.CtfeFailure;
                }
                return l.elems[lg.index];
            },
            else => {
                try self.emitError(.type_error, "list_get on non-list value");
                return error.CtfeFailure;
            },
        }
    }

    // --------------------------------------------------------
    // Structured control flow
    // --------------------------------------------------------

    fn execIfExpr(self: *Interpreter, ie: ir.IfExpr, frame: *Frame) CtfeInterpretError!ExecResult {
        const cond = try self.readLocal(frame, ie.condition);
        if (cond.isTruthy()) {
            const val = try self.execBranch(ie.then_instrs, ie.then_result, frame);
            frame.setLocal(ie.dest, val);
        } else {
            const val = try self.execBranch(ie.else_instrs, ie.else_result, frame);
            frame.setLocal(ie.dest, val);
        }
        return .continued;
    }

    fn execCaseBlock(self: *Interpreter, cb: ir.CaseBlock, frame: *Frame) CtfeInterpretError!ExecResult {
        // Execute pre-instructions (decision tree with match + case_break)
        for (cb.pre_instrs, 0..) |instr, idx| {
            self.setCurrentInstructionIndex(idx);
            const r = try self.execOneInstruction(instr, frame);
            switch (r) {
                .continued => {},
                .returned => |v| return .{ .returned = v },
                .broke => |val| {
                    // case_break from decision tree: set dest and exit
                    frame.setLocal(cb.dest, val orelse .nil);
                    return .continued;
                },
                .jumped => |target| return .{ .jumped = target },
            }
        }
        // Try each arm
        for (cb.arms) |arm| {
            for (arm.cond_instrs, 0..) |instr, idx| {
                self.setCurrentInstructionIndex(idx);
                const r = try self.execOneInstruction(instr, frame);
                switch (r) {
                    .continued => {},
                    .returned => |v| return .{ .returned = v },
                    .broke => {},
                    .jumped => |target| return .{ .jumped = target },
                }
            }
            if ((try self.readLocal(frame, arm.condition)).isTruthy()) {
                const val = try self.execBranch(arm.body_instrs, arm.result, frame);
                frame.setLocal(cb.dest, val);
                return .continued;
            }
        }
        // Default
        const val = try self.execBranch(cb.default_instrs, cb.default_result, frame);
        frame.setLocal(cb.dest, val);
        return .continued;
    }

    fn execSwitchLiteral(self: *Interpreter, sl: ir.SwitchLiteral, frame: *Frame) CtfeInterpretError!ExecResult {
        const scrutinee = try self.readLocal(frame, sl.scrutinee);
        for (sl.cases) |case| {
            if (matchLiteralValue(scrutinee, case.value)) {
                const val = try self.execBranch(case.body_instrs, case.result, frame);
                frame.setLocal(sl.dest, val);
                return .continued;
            }
        }
        // Default
        const val = try self.execBranch(sl.default_instrs, sl.default_result, frame);
        frame.setLocal(sl.dest, val);
        return .continued;
    }

    fn execSwitchReturn(self: *Interpreter, sr: ir.SwitchReturn, frame: *Frame) CtfeInterpretError!ExecResult {
        const scrutinee = try self.readParam(frame, sr.scrutinee_param);
        for (sr.cases) |case| {
            if (matchLiteralValue(scrutinee, case.value)) {
                for (case.body_instrs, 0..) |instr, idx| {
                    self.setCurrentInstructionIndex(idx);
                    const r = try self.execOneInstruction(instr, frame);
                    switch (r) {
                        .returned => |v| return .{ .returned = v },
                        .continued => {},
                        .broke => {},
                        .jumped => |target| return .{ .jumped = target },
                    }
                }
                return .{ .returned = if (case.return_value) |rv| try self.readLocal(frame, rv) else .void };
            }
        }
        // Default
        for (sr.default_instrs, 0..) |instr, idx| {
            self.setCurrentInstructionIndex(idx);
            const r = try self.execOneInstruction(instr, frame);
            switch (r) {
                .returned => |v| return .{ .returned = v },
                .continued => {},
                .broke => {},
                .jumped => |target| return .{ .jumped = target },
            }
        }
        return .{ .returned = if (sr.default_result) |dr| try self.readLocal(frame, dr) else .void };
    }

    fn execOptionalDispatch(self: *Interpreter, od: ir.OptionalDispatch, frame: *Frame) CtfeInterpretError!ExecResult {
        const scrutinee = try self.readParam(frame, od.scrutinee_param);
        const is_nil = switch (scrutinee) {
            .nil => true,
            .optional => |opt| opt.value == null,
            else => false,
        };

        const branch = if (is_nil) od.nil_instrs else od.struct_instrs;
        const result_local = if (is_nil) od.nil_result else od.struct_result;

        if (!is_nil) {
            // Bind the unwrapped payload so any read of the optional
            // param via `param_get` resolves to the underlying value.
            const payload = switch (scrutinee) {
                .optional => |opt| if (opt.value) |p| p.* else CtValue.nil,
                else => scrutinee,
            };
            frame.setLocal(od.payload_local, payload);
        }

        for (branch, 0..) |instr, idx| {
            self.setCurrentInstructionIndex(idx);
            const r = try self.execOneInstruction(instr, frame);
            switch (r) {
                .returned => |v| return .{ .returned = v },
                .continued => {},
                .broke => {},
                .jumped => |target| return .{ .jumped = target },
            }
        }
        return .{ .returned = if (result_local) |rl| try self.readLocal(frame, rl) else .void };
    }

    fn execUnionSwitchReturn(self: *Interpreter, usr: ir.UnionSwitchReturn, frame: *Frame) CtfeInterpretError!ExecResult {
        const scrutinee = try self.readParam(frame, usr.scrutinee_param);
        switch (scrutinee) {
            .union_val => |uv| {
                for (usr.cases) |case| {
                    if (std.mem.eql(u8, case.variant_name, uv.variant)) {
                        // Bind fields to locals
                        for (case.field_bindings) |binding| {
                            const payload_struct = uv.payload.*;
                            switch (payload_struct) {
                                .struct_val => |sv| {
                                    for (sv.fields) |field| {
                                        if (std.mem.eql(u8, field.name, binding.field_name)) {
                                            frame.setLocal(binding.local_index, field.value);
                                            break;
                                        }
                                    }
                                },
                                else => frame.setLocal(binding.local_index, payload_struct),
                            }
                        }
                        // Execute body
                        for (case.body_instrs, 0..) |instr, idx| {
                            self.setCurrentInstructionIndex(idx);
                            const r = try self.execOneInstruction(instr, frame);
                            switch (r) {
                                .returned => |v| return .{ .returned = v },
                                .continued => {},
                                .broke => {},
                                .jumped => |target| return .{ .jumped = target },
                            }
                        }
                        return .{ .returned = if (case.return_value) |rv| try self.readLocal(frame, rv) else .void };
                    }
                }
                try self.emitError(.match_failure, "no matching union variant");
                return error.CtfeFailure;
            },
            .struct_val => |sv| {
                // Direct struct dispatch (not a union wrapper)
                for (usr.cases) |case| {
                    if (std.mem.eql(u8, case.variant_name, sv.type_name)) {
                        for (case.field_bindings) |binding| {
                            for (sv.fields) |field| {
                                if (std.mem.eql(u8, field.name, binding.field_name)) {
                                    frame.setLocal(binding.local_index, field.value);
                                    break;
                                }
                            }
                        }
                        for (case.body_instrs, 0..) |instr, idx| {
                            self.setCurrentInstructionIndex(idx);
                            const r = try self.execOneInstruction(instr, frame);
                            switch (r) {
                                .returned => |v| return .{ .returned = v },
                                .continued => {},
                                .broke => {},
                                .jumped => |target| return .{ .jumped = target },
                            }
                        }
                        return .{ .returned = if (case.return_value) |rv| try self.readLocal(frame, rv) else .void };
                    }
                }
                try self.emitError(.match_failure, "no matching struct type");
                return error.CtfeFailure;
            },
            else => {
                try self.emitError(.type_error, "union_switch_return on non-union value");
                return error.CtfeFailure;
            },
        }
    }

    fn execUnionSwitch(self: *Interpreter, us: ir.UnionSwitch, frame: *Frame) CtfeInterpretError!ExecResult {
        const scrutinee = try self.readLocal(frame, us.scrutinee);
        switch (scrutinee) {
            .union_val => |uv| {
                for (us.cases) |case| {
                    if (std.mem.eql(u8, case.variant_name, uv.variant)) {
                        // Bind fields to locals
                        for (case.field_bindings) |binding| {
                            const payload_struct = uv.payload.*;
                            switch (payload_struct) {
                                .struct_val => |sv| {
                                    for (sv.fields) |field| {
                                        if (std.mem.eql(u8, field.name, binding.field_name)) {
                                            frame.setLocal(binding.local_index, field.value);
                                            break;
                                        }
                                    }
                                },
                                else => frame.setLocal(binding.local_index, payload_struct),
                            }
                        }
                        // Execute body
                        for (case.body_instrs, 0..) |instr, idx| {
                            self.setCurrentInstructionIndex(idx);
                            const r = try self.execOneInstruction(instr, frame);
                            switch (r) {
                                .returned => |v| return .{ .returned = v },
                                .continued => {},
                                .broke => {},
                                .jumped => |target| return .{ .jumped = target },
                            }
                        }
                        const result = if (case.return_value) |rv| try self.readLocal(frame, rv) else .void;
                        frame.setLocal(us.dest, result);
                        return .continued;
                    }
                }
                // No explicit variant matched: fall into the catch-all `_`
                // prong (`else_instrs` / `else_result`) when present, exactly
                // like the runtime `union_switch` lowering. Only when there
                // is no catch-all is this a genuine match failure.
                if (us.has_else) {
                    const result = try self.execBranch(us.else_instrs, us.else_result, frame);
                    frame.setLocal(us.dest, result);
                    return .continued;
                }
                try self.emitError(.match_failure, "no matching union variant");
                return error.CtfeFailure;
            },
            .struct_val => |sv| {
                for (us.cases) |case| {
                    if (std.mem.eql(u8, case.variant_name, sv.type_name)) {
                        for (case.field_bindings) |binding| {
                            for (sv.fields) |field| {
                                if (std.mem.eql(u8, field.name, binding.field_name)) {
                                    frame.setLocal(binding.local_index, field.value);
                                    break;
                                }
                            }
                        }
                        for (case.body_instrs, 0..) |instr, idx| {
                            self.setCurrentInstructionIndex(idx);
                            const r = try self.execOneInstruction(instr, frame);
                            switch (r) {
                                .returned => |v| return .{ .returned = v },
                                .continued => {},
                                .broke => {},
                                .jumped => |target| return .{ .jumped = target },
                            }
                        }
                        const result = if (case.return_value) |rv| try self.readLocal(frame, rv) else .void;
                        frame.setLocal(us.dest, result);
                        return .continued;
                    }
                }
                // Catch-all `_` prong, as on the union_val path above.
                if (us.has_else) {
                    const result = try self.execBranch(us.else_instrs, us.else_result, frame);
                    frame.setLocal(us.dest, result);
                    return .continued;
                }
                try self.emitError(.match_failure, "no matching struct type");
                return error.CtfeFailure;
            },
            else => {
                try self.emitError(.type_error, "union_switch on non-union value");
                return error.CtfeFailure;
            },
        }
    }

    /// Helper: execute instructions then read the result local.
    fn execBranch(
        self: *Interpreter,
        instrs: []const ir.Instruction,
        result_local: ?ir.LocalId,
        frame: *Frame,
    ) CtfeInterpretError!CtValue {
        for (instrs, 0..) |instr, idx| {
            if (self.steps_remaining == 0) {
                try self.emitError(.step_limit_exceeded, "step limit exceeded");
                return error.CtfeFailure;
            }
            self.steps_remaining -= 1;
            self.setCurrentInstructionIndex(idx);
            const r = try self.execOneInstruction(instr, frame);
            switch (r) {
                .continued => {},
                .returned => |v| return v,
                .broke => |v| return v orelse .void,
                .jumped => |target| {
                    frame.predecessor_block_label = frame.current_block_label;
                    frame.current_block_label = target;
                    return try self.execFunctionBlocksFromCurrent(frame);
                },
            }
        }
        return if (result_local) |rl| try self.readLocal(frame, rl) else .void;
    }

    fn findBlockByLabel(func: *const ir.Function, label: ir.LabelId) ?*const ir.Block {
        for (func.body) |*block| {
            if (block.label == label) return block;
        }
        return null;
    }

    fn applyPhiInstructions(
        self: *Interpreter,
        instrs: []const ir.Instruction,
        frame: *Frame,
        predecessor: ?ir.LabelId,
    ) CtfeInterpretError!usize {
        var idx: usize = 0;
        while (idx < instrs.len) : (idx += 1) {
            switch (instrs[idx]) {
                .phi => |phi| {
                    const pred = predecessor orelse {
                        try self.emitError(.type_error, "phi reached without predecessor block");
                        return error.CtfeFailure;
                    };
                    var matched = false;
                    for (phi.sources) |src| {
                        if (src.from_block == pred) {
                            frame.setLocal(phi.dest, try self.readLocal(frame, src.value));
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) {
                        try self.emitError(.type_error, "phi missing source for predecessor block");
                        return error.CtfeFailure;
                    }
                },
                else => return idx,
            }
        }
        return idx;
    }

    fn execFunctionBlocksFromCurrent(self: *Interpreter, frame: *Frame) CtfeInterpretError!CtValue {
        const function_id = frame.function_id;
        // Look up function by ID, not array index
        const func = blk: {
            for (self.program.functions) |*f| {
                if (f.id == function_id) break :blk f;
            }
            try self.emitError(.undefined_function, "invalid function id");
            return error.CtfeFailure;
        };
        while (true) {
            const current_label = frame.current_block_label orelse {
                try self.emitError(.type_error, "missing current block label");
                return error.CtfeFailure;
            };
            const block = findBlockByLabel(func, current_label) orelse {
                try self.emitError(.undefined_function, "block label not found");
                return error.CtfeFailure;
            };
            const start_index = try self.applyPhiInstructions(block.instructions, frame, frame.predecessor_block_label);
            return try self.execInstructionsFrom(block.instructions, frame, start_index);
        }
    }

    fn execFunctionBlocks(self: *Interpreter, func: *const ir.Function, frame: *Frame) CtfeInterpretError!CtValue {
        frame.current_block_label = func.body[0].label;
        frame.predecessor_block_label = null;
        return self.execFunctionBlocksFromCurrent(frame);
    }

    // --------------------------------------------------------
    // Calls
    // --------------------------------------------------------

    fn execCallDirect(self: *Interpreter, cd: ir.CallDirect, frame: *const Frame) CtfeInterpretError!CtValue {
        const args = try self.collectLocals(cd.args, frame);
        defer self.allocator.free(args);
        return self.evalFunction(cd.function, args);
    }

    fn execCallNamed(self: *Interpreter, cn: ir.CallNamed, frame: *const Frame) CtfeInterpretError!CtValue {
        const args = try self.collectLocals(cn.args, frame);
        defer self.allocator.free(args);
        const func_id = self.function_by_name.get(cn.name) orelse {
            try self.emitError(.undefined_function, cn.name);
            return error.CtfeFailure;
        };
        return self.evalFunction(func_id, args);
    }

    fn execCallBuiltin(self: *Interpreter, cb: ir.CallBuiltin, frame: *const Frame) CtfeInterpretError!CtValue {
        const args = try self.collectLocals(cb.args, frame);
        defer self.allocator.free(args);

        // Reflection intrinsics
        if (std.mem.eql(u8, cb.name, "source_graph_structs")) {
            return self.builtinSourceGraphStructs(args);
        }
        if (std.mem.eql(u8, cb.name, "struct_functions")) {
            return self.builtinReflectedStructFunctions(args);
        }
        if (std.mem.eql(u8, cb.name, "struct_put_attribute")) {
            return self.builtinStructPutAttribute(args);
        }
        if (std.mem.eql(u8, cb.name, "struct_get_attribute")) {
            return self.builtinStructGetAttribute(args);
        }
        if (std.mem.eql(u8, cb.name, "struct_register_attribute")) {
            return self.builtinStructRegisterAttribute(args);
        }
        if (std.mem.eql(u8, cb.name, "map_get")) {
            return self.builtinMapGet(args);
        }

        // File read intrinsic
        if (std.mem.eql(u8, cb.name, "File.read") or
            std.mem.endsWith(u8, cb.name, "__File__read") or
            std.mem.eql(u8, cb.name, ":zig.file_read"))
        {
            return self.builtinFileRead(args);
        }

        // Filesystem glob primitive. Zap stdlib APIs wrap this in Zap code.
        if (std.mem.eql(u8, cb.name, "Prim.glob")) {
            return self.builtinPrimitiveGlob(args);
        }

        // Env read intrinsic
        if (std.mem.eql(u8, cb.name, "System.get_env") or
            std.mem.eql(u8, cb.name, ":zig.get_env"))
        {
            return self.builtinGetEnv(args);
        }

        // Build opt read intrinsic
        if (std.mem.eql(u8, cb.name, "System.get_build_opt") or
            std.mem.eql(u8, cb.name, ":zig.get_build_opt"))
        {
            return self.builtinGetBuildOpt(args);
        }

        // Pure type conversion builtins
        if (std.mem.eql(u8, cb.name, ":zig.atom_name")) {
            return self.builtinAtomName(args);
        }
        if (std.mem.eql(u8, cb.name, ":zig.i64_to_string")) {
            return self.builtinI64ToString(args);
        }
        if (std.mem.eql(u8, cb.name, ":zig.f64_to_string")) {
            return self.builtinF64ToString(args);
        }
        if (std.mem.eql(u8, cb.name, ":zig.to_atom") or
            std.mem.eql(u8, cb.name, ":zig.to_existing_atom"))
        {
            return self.builtinToAtom(args);
        }
        if (std.mem.eql(u8, cb.name, ":zig.inspect")) {
            return self.builtinInspect(args);
        }

        // Side-effect builtins: no-op at compile time, return the argument
        if (std.mem.eql(u8, cb.name, ":zig.println") or
            std.mem.eql(u8, cb.name, ":zig.print_str"))
        {
            return if (args.len > 0) args[0] else .nil;
        }

        // Runtime-only builtins
        if (std.mem.eql(u8, cb.name, ":zig.arg_count") or
            std.mem.eql(u8, cb.name, ":zig.arg_at"))
        {
            try self.emitError(.capability_violation, "command-line arguments are not available at compile time");
            return error.CtfeFailure;
        }

        try self.emitError(.unsupported_instruction, cb.name);
        return error.CtfeFailure;
    }

    fn builtinAtomName(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "atom_name expects 1 argument");
            return error.CtfeFailure;
        }
        return switch (args[0]) {
            .atom => |a| .{ .string = a },
            else => {
                try self.emitError(.type_error, "atom_name expects an atom argument");
                return error.CtfeFailure;
            },
        };
    }

    fn builtinI64ToString(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "i64_to_string expects 1 argument");
            return error.CtfeFailure;
        }
        return switch (args[0]) {
            .int => |v| .{ .string = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch return error.OutOfMemory },
            else => {
                try self.emitError(.type_error, "i64_to_string expects an integer argument");
                return error.CtfeFailure;
            },
        };
    }

    fn builtinF64ToString(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "f64_to_string expects 1 argument");
            return error.CtfeFailure;
        }
        return switch (args[0]) {
            .float => |v| .{ .string = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch return error.OutOfMemory },
            else => {
                try self.emitError(.type_error, "f64_to_string expects a float argument");
                return error.CtfeFailure;
            },
        };
    }

    fn builtinToAtom(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "to_atom expects 1 argument");
            return error.CtfeFailure;
        }
        return switch (args[0]) {
            .string => |s| .{ .atom = s },
            else => {
                try self.emitError(.type_error, "to_atom expects a string argument");
                return error.CtfeFailure;
            },
        };
    }

    fn builtinInspect(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "inspect expects 1 argument");
            return error.CtfeFailure;
        }
        const s = formatCtValue(self.allocator, args[0]) catch |err| return self.traversalFailure(err);
        return .{ .string = s };
    }

    fn builtinMapGet(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 3) {
            try self.emitError(.type_error, "map_get expects 3 arguments");
            return error.CtfeFailure;
        }

        const default_value = args[2];
        if (args[0] != .map) return default_value;

        for (args[0].map.entries) |entry| {
            if (entry.key.eqlWithAllocator(self.allocator, args[1]) catch |err| return self.traversalFailure(err)) {
                return entry.value;
            }
        }
        return default_value;
    }

    // --------------------------------------------------------
    // File/env intrinsics
    // --------------------------------------------------------

    fn builtinFileRead(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.capabilities.has(.read_file)) {
            try self.emitError(.capability_violation, "File.read requires read_file capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "File.read expects 1 argument (path)");
            return error.CtfeFailure;
        }

        const path = switch (args[0]) {
            .string => |s| s,
            else => {
                try self.emitError(.type_error, "File.read expects a string path");
                return error.CtfeFailure;
            },
        };

        // Read the file
        const content = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, self.allocator, .limited(10 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                // Record dependency on absent file
                try self.recordDependency(.{
                    .file = .{ .path = path, .content_hash = 0 },
                });
                return .nil;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.emitErrorFmt(.host_io_failure, "File.read failed for `{s}`: {s}", .{ path, @errorName(err) });
                return error.CtfeFailure;
            },
        };
        errdefer self.allocator.free(content);

        // Record dependency with content hash
        const content_hash = std.hash.Wyhash.hash(0, content);
        try self.recordDependency(.{
            .file = .{ .path = path, .content_hash = content_hash },
        });

        return .{ .string = content };
    }

    fn builtinPrimitiveGlob(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.capabilities.has(.read_file)) {
            try self.emitError(.capability_violation, ":zig.Prim.glob requires read_file capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, ":zig.Prim.glob expects 1 argument (pattern)");
            return error.CtfeFailure;
        }

        const pattern_value = unwrapCtAstLiteral(args[0]);
        const pattern = switch (pattern_value) {
            .string => |s| s,
            else => {
                try self.emitError(.type_error, ":zig.Prim.glob expects a string pattern");
                return error.CtfeFailure;
            },
        };

        const matches = glob.collect(self.allocator, std.Options.debug_io, pattern, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.emitErrorFmt(.host_io_failure, ":zig.Prim.glob failed for `{s}`: {s}", .{ pattern, @errorName(err) });
                return error.CtfeFailure;
            },
        };
        errdefer glob.freeMatches(self.allocator, matches);
        const result_items = self.allocator.alloc(CtValue, matches.len) catch return error.OutOfMemory;
        errdefer self.allocator.free(result_items);
        for (matches, 0..) |matched_path, index| {
            result_items[index] = .{ .string = matched_path };
        }

        try self.recordDependency(.{
            .glob = .{
                .pattern = pattern,
                .result_hash = hashGlobMatches(matches),
            },
        });

        const alloc_id = try self.allocation_store.alloc(self.allocator, .list, self.currentFunctionId());
        self.allocator.free(matches);
        return .{ .list = .{ .alloc_id = alloc_id, .elems = result_items } };
    }

    fn builtinGetEnv(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.capabilities.has(.read_env)) {
            try self.emitError(.capability_violation, "System.get_env requires read_env capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "System.get_env expects 1 argument (name)");
            return error.CtfeFailure;
        }

        const name = switch (args[0]) {
            .string => |s| s,
            .atom => |a| a,
            else => {
                try self.emitError(.type_error, "System.get_env expects a string name");
                return error.CtfeFailure;
            },
        };

        // Read the env var
        const value: ?[]const u8 = env.getenvRuntime(name);

        if (value) |v| {
            const val_copy = self.allocator.dupe(u8, v) catch return error.OutOfMemory;
            errdefer self.allocator.free(val_copy);
            const value_hash = std.hash.Wyhash.hash(0, v);
            try self.recordDependency(.{
                .env_var = .{ .name = name, .value_hash = value_hash, .present = true },
            });
            return .{ .string = val_copy };
        } else {
            // Record dependency on absent env var
            try self.recordDependency(.{
                .env_var = .{ .name = name, .value_hash = 0, .present = false },
            });
            return .nil;
        }
    }

    fn builtinGetBuildOpt(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) {
            try self.emitError(.type_error, "System.get_build_opt expects 1 argument (name)");
            return error.CtfeFailure;
        }

        const name = switch (args[0]) {
            .string => |s| s,
            .atom => |a| a,
            else => {
                try self.emitError(.type_error, "System.get_build_opt expects a string name");
                return error.CtfeFailure;
            },
        };

        if (self.build_opts.get(name)) |v| {
            return .{ .string = v };
        }
        return .nil;
    }

    // --------------------------------------------------------
    // Reflection intrinsics
    // --------------------------------------------------------

    fn hasReflectionCapability(self: *const Interpreter) bool {
        return self.capabilities.has(.reflect_source) or self.capabilities.has(.reflect_struct);
    }

    fn builtinSourceGraphStructs(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.hasReflectionCapability()) {
            try self.emitError(.capability_violation, "source_graph_structs requires reflect_source capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "source_graph_structs expects 1 argument");
            return error.CtfeFailure;
        }

        const graph = self.scope_graph orelse {
            try self.emitError(.unsupported_instruction, "no scope graph available for reflection");
            return error.CtfeFailure;
        };
        const interner = self.interner orelse {
            try self.emitError(.unsupported_instruction, "no string interner available for reflection");
            return error.CtfeFailure;
        };

        const path_filter = try self.extractPathFilter(args[0]);
        var path_filter_transferred = false;
        errdefer if (!path_filter_transferred) self.allocator.free(path_filter);

        const graph_hash = computeSourceReflectionHash(self.allocator, graph, interner, path_filter) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SourcePathCanonicalizationFailed => {
                try self.emitError(.host_io_failure, "source reflection path canonicalization failed");
                return error.CtfeFailure;
            },
        };
        try self.dependencies.append(self.allocator, .{
            .reflected_source = .{
                .paths = path_filter,
                .graph_hash = graph_hash,
            },
        });
        path_filter_transferred = true;

        var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
        errdefer {
            deinitOwnedCtValueSlice(self.allocator, result_list.items);
            result_list.deinit(self.allocator);
        }
        for (graph.structs.items) |struct_entry| {
            const source_id = struct_entry.decl.meta.span.source_id orelse continue;
            const path = graph.sourcePathById(source_id) orelse continue;
            if (!(pathFilterContains(self.allocator, path_filter, path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.SourcePathCanonicalizationFailed => {
                    try self.emitError(.host_io_failure, "source reflection path canonicalization failed");
                    return error.CtfeFailure;
                },
            })) continue;
            const struct_ref = try self.makeStructRef(struct_entry, path, source_id);
            try appendOwnedCtValue(self.allocator, &result_list, struct_ref);
        }

        return finishOwnedCtValueList(self.allocator, &self.allocation_store, self.currentFunctionId(), &result_list);
    }

    fn builtinReflectedStructFunctions(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.hasReflectionCapability()) {
            try self.emitError(.capability_violation, "struct_functions requires reflect_source capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "struct_functions expects 1 argument");
            return error.CtfeFailure;
        }

        const graph = self.scope_graph orelse {
            try self.emitError(.unsupported_instruction, "no scope graph available for reflection");
            return error.CtfeFailure;
        };
        const interner = self.interner orelse {
            try self.emitError(.unsupported_instruction, "no string interner available for reflection");
            return error.CtfeFailure;
        };

        const struct_name_ref = (try self.extractStructRefName(args[0])) orelse {
            try self.emitError(.type_error, "struct_functions expects a reflected struct, atom, or string");
            return error.CtfeFailure;
        };
        defer struct_name_ref.deinit(self.allocator);
        const struct_name = struct_name_ref.bytes();
        const struct_scope_id = self.findStructScopeByName(graph, struct_name) orelse {
            try self.emitError(.undefined_function, "struct not found for reflection");
            return error.CtfeFailure;
        };

        const iface_hash = computeStructInterfaceHash(self.allocator, graph, struct_scope_id, self.interner, struct_name) catch |err| return self.traversalFailure(err);
        try self.recordReflectedStructDependency(struct_name, iface_hash);

        var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
        errdefer {
            deinitOwnedCtValueSlice(self.allocator, result_list.items);
            result_list.deinit(self.allocator);
        }
        const struct_scope = graph.getScope(struct_scope_id);
        var family_iter = struct_scope.function_families.iterator();
        while (family_iter.next()) |entry| {
            const family = &graph.families.items[entry.value_ptr.*];
            if (family.visibility != .public) continue;
            const name_str = interner.get(family.name);
            const function_ref = try self.makeFunctionRef(name_str, family.arity, family.visibility);
            try appendOwnedCtValue(self.allocator, &result_list, function_ref);
        }

        return finishOwnedCtValueList(self.allocator, &self.allocation_store, self.currentFunctionId(), &result_list);
    }

    fn putExportedStructAttribute(
        allocator: std.mem.Allocator,
        graph: *scope.ScopeGraph,
        struct_entry: *scope.StructEntry,
        name_id: ast.StringId,
        exported: ConstValue,
    ) std.mem.Allocator.Error!void {
        var exported_transferred = false;
        errdefer if (!exported_transferred) deinitConstValue(allocator, exported);

        graph.putStructAttribute(struct_entry, name_id, exported) catch return error.OutOfMemory;
        exported_transferred = true;
    }

    fn builtinStructPutAttribute(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 2) return .nil;
        const graph = self.scope_graph orelse return .nil;
        const interner = self.interner orelse return .nil;
        const scope_id = self.current_struct_scope orelse return .nil;
        const struct_entry = graph.findStructByScope(scope_id) orelse return .nil;
        const name = extractAttributeName(args[0]) orelse return .nil;
        const name_id = interner.lookupExisting(name) orelse return .nil;
        const value = unwrapCtAstLiteral(args[1]);
        const exported = exportValue(graph.allocator, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTraversalDepthExceeded => return self.traversalFailure(error.ValueTraversalDepthExceeded),
            error.ValueTraversalBudgetExceeded => return self.traversalFailure(error.ValueTraversalBudgetExceeded),
            error.CannotExport => return .nil,
        };
        putExportedStructAttribute(graph.allocator, graph, struct_entry, name_id, exported) catch return error.OutOfMemory;
        return .nil;
    }

    fn builtinStructGetAttribute(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) return .nil;
        const graph = self.scope_graph orelse return .nil;
        const interner = self.interner orelse return .nil;
        const scope_id = self.current_struct_scope orelse return .nil;
        const struct_entry = graph.findStructByScope(scope_id) orelse return .nil;
        const name = extractAttributeName(args[0]) orelse return .nil;
        const name_id = interner.lookupExisting(name) orelse return .nil;
        var value = graph.getStructAttribute(struct_entry, name_id) catch return error.OutOfMemory;
        if (value) |*attribute_value| {
            defer attribute_value.deinit(self.allocator);
            return importConstValue(self.allocator, attribute_value.value) catch |err| return self.traversalFailure(err);
        }
        return .nil;
    }

    fn builtinStructRegisterAttribute(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (args.len != 1) return .nil;
        const graph = self.scope_graph orelse return .nil;
        const interner = self.interner orelse return .nil;
        const scope_id = self.current_struct_scope orelse return .nil;
        const struct_entry = graph.findStructByScope(scope_id) orelse return .nil;
        const name = extractAttributeName(args[0]) orelse return .nil;
        const name_id = interner.lookupExisting(name) orelse return .nil;
        graph.registerAccumulatingAttribute(struct_entry, name_id) catch return error.OutOfMemory;
        return .nil;
    }

    fn extractAttributeName(value: CtValue) ?[]const u8 {
        const unwrapped = unwrapCtAstLiteral(value);
        return switch (unwrapped) {
            .atom => |raw| if (raw.len > 0 and raw[0] == ':') raw[1..] else raw,
            .string => |name| name,
            else => null,
        };
    }

    fn extractPathFilter(self: *Interpreter, value: CtValue) CtfeInterpretError![]const []const u8 {
        return switch (value) {
            .string => |path| blk: {
                const paths = try self.allocator.alloc([]const u8, 1);
                paths[0] = path;
                break :blk paths;
            },
            .atom => |path| blk: {
                const paths = try self.allocator.alloc([]const u8, 1);
                paths[0] = path;
                break :blk paths;
            },
            .list => |list| blk: {
                const paths = try self.allocator.alloc([]const u8, list.elems.len);
                errdefer self.allocator.free(paths);
                for (list.elems, 0..) |elem, i| {
                    paths[i] = switch (elem) {
                        .string => |path| path,
                        .atom => |path| path,
                        else => {
                            try self.emitError(.type_error, "source_graph_structs path list must contain strings");
                            return error.CtfeFailure;
                        },
                    };
                }
                break :blk paths;
            },
            else => {
                try self.emitError(.type_error, "source_graph_structs expects a string path or list of string paths");
                return error.CtfeFailure;
            },
        };
    }

    fn extractStructRefName(self: *Interpreter, value: CtValue) CtfeInterpretError!?ExtractedStructRefName {
        return switch (value) {
            .string => |name| .{ .borrowed = name },
            .atom => |name| .{ .borrowed = name },
            .tuple => |tuple| blk: {
                if (tuple.elems.len != 3) break :blk null;
                if (tuple.elems[0] != .atom or !std.mem.eql(u8, tuple.elems[0].atom, "__aliases__")) break :blk null;
                if (tuple.elems[2] != .list) break :blk null;
                var buffer: std.ArrayListUnmanaged(u8) = .empty;
                errdefer buffer.deinit(self.allocator);
                for (tuple.elems[2].list.elems, 0..) |part, index| {
                    if (part != .atom) {
                        buffer.deinit(self.allocator);
                        break :blk null;
                    }
                    if (index > 0) try buffer.append(self.allocator, '.');
                    try buffer.appendSlice(self.allocator, part.atom);
                }
                break :blk .{ .owned = try buffer.toOwnedSlice(self.allocator) };
            },
            .map => |map| blk: {
                for (map.entries) |entry| {
                    if (entry.key == .atom and std.mem.eql(u8, entry.key.atom, "name")) {
                        if (entry.value == .string) break :blk .{ .borrowed = entry.value.string };
                        if (entry.value == .atom) break :blk .{ .borrowed = entry.value.atom };
                    }
                }
                break :blk null;
            },
            else => null,
        };
    }

    fn makeStructRef(
        self: *Interpreter,
        struct_entry: scope.StructEntry,
        path: []const u8,
        source_id: u32,
    ) CtfeInterpretError!CtValue {
        _ = path;
        _ = source_id;

        const tuple_elems = try self.allocator.alloc(CtValue, 3);
        initCtValueSlots(tuple_elems);
        var tuple_elems_transferred = false;
        errdefer if (!tuple_elems_transferred) {
            deinitOwnedCtValueSlice(self.allocator, tuple_elems);
            self.allocator.free(tuple_elems);
        };

        const parts = try self.allocator.alloc(CtValue, struct_entry.name.parts.len);
        initCtValueSlots(parts);
        var parts_transferred = false;
        errdefer if (!parts_transferred) {
            deinitOwnedCtValueSlice(self.allocator, parts);
            self.allocator.free(parts);
        };
        for (struct_entry.name.parts, 0..) |part, index| {
            parts[index] = .{ .atom = self.interner.?.get(part) };
        }

        const empty_list_id = try self.allocation_store.alloc(self.allocator, .list, self.currentFunctionId());
        const parts_list_id = try self.allocation_store.alloc(self.allocator, .list, self.currentFunctionId());
        tuple_elems[0] = .{ .atom = "__aliases__" };
        tuple_elems[1] = .{ .list = .{ .alloc_id = empty_list_id, .elems = &.{} } };
        tuple_elems[2] = .{ .list = .{ .alloc_id = parts_list_id, .elems = parts } };
        parts_transferred = true;

        const tuple_id = try self.allocation_store.alloc(self.allocator, .tuple, self.currentFunctionId());
        tuple_elems_transferred = true;
        return .{ .tuple = .{ .alloc_id = tuple_id, .elems = tuple_elems } };
    }

    fn makeFunctionRef(
        self: *Interpreter,
        name: []const u8,
        arity: u32,
        visibility: ast.FunctionDecl.Visibility,
    ) CtfeInterpretError!CtValue {
        const entries = try self.allocator.alloc(CtValue.CtMapEntry, 3);
        errdefer self.allocator.free(entries);
        entries[0] = .{ .key = .{ .atom = "name" }, .value = .{ .string = name } };
        entries[1] = .{ .key = .{ .atom = "arity" }, .value = .{ .int = @intCast(arity) } };
        entries[2] = .{ .key = .{ .atom = "visibility" }, .value = .{ .atom = @tagName(visibility) } };
        const alloc_id = try self.allocation_store.alloc(self.allocator, .map, self.currentFunctionId());
        return .{ .map = .{ .alloc_id = alloc_id, .entries = entries } };
    }

    fn builtinStructFunctions(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.capabilities.has(.reflect_struct)) {
            try self.emitError(.capability_violation, "struct function reflection requires reflect_struct capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "struct function reflection expects 1 argument");
            return error.CtfeFailure;
        }

        const mod_name_str = switch (args[0]) {
            .atom => |a| a,
            .string => |s| s,
            else => {
                try self.emitError(.type_error, "struct function reflection expects atom or string argument");
                return error.CtfeFailure;
            },
        };

        const graph = self.scope_graph orelse {
            try self.emitError(.unsupported_instruction, "no scope graph available for reflection");
            return error.CtfeFailure;
        };

        // Find struct scope
        const mod_scope_id = self.findStructScopeByName(graph, mod_name_str) orelse {
            try self.emitError(.undefined_function, "struct not found for reflection");
            return error.CtfeFailure;
        };

        // Record dependency with interface hash
        const iface_hash = computeStructInterfaceHash(self.allocator, graph, mod_scope_id, self.interner, mod_name_str) catch |err| return self.traversalFailure(err);
        try self.recordReflectedStructDependency(mod_name_str, iface_hash);

        // Collect public functions from this struct's scope
        const mod_scope = graph.getScope(mod_scope_id);
        var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
        errdefer {
            deinitOwnedCtValueSlice(self.allocator, result_list.items);
            result_list.deinit(self.allocator);
        }

        var family_iter = mod_scope.function_families.iterator();
        while (family_iter.next()) |entry| {
            const family = &graph.families.items[entry.value_ptr.*];
            if (family.visibility == .public) {
                const name_str = if (self.interner) |int| int.get(family.name) else "?";
                const tuple_elems = self.allocator.alloc(CtValue, 2) catch return error.OutOfMemory;
                initCtValueSlots(tuple_elems);
                var tuple_elems_transferred = false;
                errdefer if (!tuple_elems_transferred) {
                    deinitOwnedCtValueSlice(self.allocator, tuple_elems);
                    self.allocator.free(tuple_elems);
                };
                tuple_elems[0] = .{ .atom = name_str };
                tuple_elems[1] = .{ .int = @intCast(family.arity) };
                const alloc_id = try self.allocation_store.alloc(self.allocator, .tuple, self.currentFunctionId());
                tuple_elems_transferred = true;
                try appendOwnedCtValue(self.allocator, &result_list, .{ .tuple = .{ .alloc_id = alloc_id, .elems = tuple_elems } });
            }
        }

        return finishOwnedCtValueList(self.allocator, &self.allocation_store, self.currentFunctionId(), &result_list);
    }

    fn builtinStructAttributes(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.capabilities.has(.reflect_struct)) {
            try self.emitError(.capability_violation, "struct attribute reflection requires reflect_struct capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "struct attribute reflection expects 1 argument");
            return error.CtfeFailure;
        }

        const mod_name_str = switch (args[0]) {
            .atom => |a| a,
            .string => |s| s,
            else => {
                try self.emitError(.type_error, "struct attribute reflection expects atom or string argument");
                return error.CtfeFailure;
            },
        };

        const graph = self.scope_graph orelse {
            try self.emitError(.unsupported_instruction, "no scope graph available for reflection");
            return error.CtfeFailure;
        };

        // Record dependency with interface hash
        const mod_scope_id = self.findStructScopeByName(graph, mod_name_str);
        const iface_hash = if (mod_scope_id) |sid| blk: {
            break :blk computeStructInterfaceHash(self.allocator, graph, sid, self.interner, mod_name_str) catch |err| return self.traversalFailure(err);
        } else 0;
        try self.recordReflectedStructDependency(mod_name_str, iface_hash);

        // Find struct entry and collect its attributes
        var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
        errdefer {
            deinitOwnedCtValueSlice(self.allocator, result_list.items);
            result_list.deinit(self.allocator);
        }
        for (graph.structs.items) |mod_entry| {
            if (self.structNameMatches(mod_entry.name, mod_name_str)) {
                for (mod_entry.attributes.items) |attr| {
                    const name_str = if (self.interner) |int| int.get(attr.name) else "?";
                    const tuple_elems = self.allocator.alloc(CtValue, 2) catch return error.OutOfMemory;
                    initCtValueSlots(tuple_elems);
                    var tuple_elems_transferred = false;
                    errdefer if (!tuple_elems_transferred) {
                        deinitOwnedCtValueSlice(self.allocator, tuple_elems);
                        self.allocator.free(tuple_elems);
                    };
                    tuple_elems[0] = .{ .atom = name_str };
                    // Include computed value if available, otherwise nil
                    if (attr.computed_value) |cv| {
                        tuple_elems[1] = importConstValue(self.allocator, cv) catch |err| return self.traversalFailure(err);
                    } else {
                        tuple_elems[1] = .nil;
                    }
                    const alloc_id = try self.allocation_store.alloc(self.allocator, .tuple, self.currentFunctionId());
                    tuple_elems_transferred = true;
                    try appendOwnedCtValue(self.allocator, &result_list, .{ .tuple = .{ .alloc_id = alloc_id, .elems = tuple_elems } });
                }
                break;
            }
        }

        return finishOwnedCtValueList(self.allocator, &self.allocation_store, self.currentFunctionId(), &result_list);
    }

    fn builtinStructTypes(self: *Interpreter, args: []const CtValue) CtfeInterpretError!CtValue {
        if (!self.capabilities.has(.reflect_struct)) {
            try self.emitError(.capability_violation, "struct type reflection requires reflect_struct capability");
            return error.CtfeFailure;
        }
        if (args.len != 1) {
            try self.emitError(.type_error, "struct type reflection expects 1 argument");
            return error.CtfeFailure;
        }

        const mod_name_str = switch (args[0]) {
            .atom => |a| a,
            .string => |s| s,
            else => {
                try self.emitError(.type_error, "struct type reflection expects atom or string argument");
                return error.CtfeFailure;
            },
        };

        const graph = self.scope_graph orelse {
            try self.emitError(.unsupported_instruction, "no scope graph available for reflection");
            return error.CtfeFailure;
        };

        // Record dependency with interface hash
        const mod_scope_id = self.findStructScopeByName(graph, mod_name_str) orelse {
            try self.recordReflectedStructDependency(mod_name_str, 0);
            return .{ .list = .{ .alloc_id = 0, .elems = &.{} } };
        };
        const iface_hash = computeStructInterfaceHash(self.allocator, graph, mod_scope_id, self.interner, mod_name_str) catch |err| return self.traversalFailure(err);
        try self.recordReflectedStructDependency(mod_name_str, iface_hash);

        var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
        errdefer result_list.deinit(self.allocator);
        for (graph.types.items) |type_entry| {
            // Check if type belongs to this struct by matching scope
            if (self.structNameMatchesByScope(graph, type_entry.scope_id, mod_name_str)) {
                const name_str = if (self.interner) |int| int.get(type_entry.name) else "?";
                result_list.append(self.allocator, .{ .atom = name_str }) catch return error.OutOfMemory;
            }
        }

        const result_elems = result_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        errdefer if (result_elems.len > 0) self.allocator.free(result_elems);
        const alloc_id = try self.allocation_store.alloc(self.allocator, .list, self.currentFunctionId());
        return .{ .list = .{ .alloc_id = alloc_id, .elems = result_elems } };
    }

    fn findStructScopeByName(self: *Interpreter, graph: *const scope.ScopeGraph, name_str: []const u8) ?scope.ScopeId {
        for (graph.structs.items) |mod_entry| {
            if (self.structNameMatches(mod_entry.name, name_str)) {
                return mod_entry.scope_id;
            }
        }
        return null;
    }

    fn structNameMatches(self: *Interpreter, name: ast.StructName, target: []const u8) bool {
        const int = self.interner orelse return false;
        // Build the full name from parts and compare
        if (name.parts.len == 1) {
            return std.mem.eql(u8, int.get(name.parts[0]), target);
        }
        // Multi-part: join with "."
        var buf: [256]u8 = undefined;
        var pos: usize = 0;
        for (name.parts, 0..) |part, i| {
            if (i > 0) {
                if (pos < buf.len) {
                    buf[pos] = '.';
                    pos += 1;
                }
            }
            const s = int.get(part);
            const end = @min(pos + s.len, buf.len);
            @memcpy(buf[pos..end], s[0 .. end - pos]);
            pos = end;
        }
        return std.mem.eql(u8, buf[0..pos], target);
    }

    fn structNameMatchesByScope(self: *Interpreter, graph: *const scope.ScopeGraph, type_scope_id: scope.ScopeId, mod_name_str: []const u8) bool {
        // Walk up from type's scope to find the struct
        var sid = type_scope_id;
        while (true) {
            for (graph.structs.items) |mod_entry| {
                if (mod_entry.scope_id == sid) {
                    return self.structNameMatches(mod_entry.name, mod_name_str);
                }
            }
            const s = graph.getScope(sid);
            if (s.parent) |parent_id| {
                sid = parent_id;
            } else break;
        }
        return false;
    }

    fn importConstValue(allocator: std.mem.Allocator, cv: ConstValue) ValueTraversalError!CtValue {
        const ImportFrame = struct {
            source: ConstValue,
            dest: *CtValue,
            depth: usize,
        };

        var budget = ValueTraversalBudget{};
        var stack = InlineTraversalStack(ImportFrame){};
        defer stack.deinit(allocator);

        var imported_root: CtValue = .void;
        errdefer deinitOwnedCtValue(allocator, imported_root);
        try stack.push(allocator, .{ .source = cv, .dest = &imported_root, .depth = 1 });

        while (stack.pop()) |frame| {
            try budget.visit(frame.depth);
            switch (frame.source) {
                .int => |value| frame.dest.* = .{ .int = value },
                .float => |value| frame.dest.* = .{ .float = value },
                .string => |value| frame.dest.* = .{ .string = value },
                .bool_val => |value| frame.dest.* = .{ .bool_val = value },
                .atom => |value| frame.dest.* = .{ .atom = value },
                .nil => frame.dest.* = .nil,
                .void => frame.dest.* = .void,
                .tuple => |elems| {
                    try budget.ensureChildren(frame.depth, elems.len);
                    const imported_elems = try allocator.alloc(CtValue, elems.len);
                    initCtValueSlots(imported_elems);
                    frame.dest.* = .{ .tuple = .{ .alloc_id = 0, .elems = imported_elems } };
                    var index = elems.len;
                    while (index > 0) {
                        index -= 1;
                        try stack.push(allocator, .{
                            .source = elems[index],
                            .dest = &imported_elems[index],
                            .depth = frame.depth + 1,
                        });
                    }
                },
                .list => |elems| {
                    try budget.ensureChildren(frame.depth, elems.len);
                    const imported_elems = try allocator.alloc(CtValue, elems.len);
                    initCtValueSlots(imported_elems);
                    frame.dest.* = .{ .list = .{ .alloc_id = 0, .elems = imported_elems } };
                    var index = elems.len;
                    while (index > 0) {
                        index -= 1;
                        try stack.push(allocator, .{
                            .source = elems[index],
                            .dest = &imported_elems[index],
                            .depth = frame.depth + 1,
                        });
                    }
                },
                .map => |entries| {
                    try budget.ensureChildren(frame.depth, try checkedChildCount(entries.len, 2));
                    const imported_entries = try allocator.alloc(CtValue.CtMapEntry, entries.len);
                    initCtMapEntries(imported_entries);
                    frame.dest.* = .{ .map = .{ .alloc_id = 0, .entries = imported_entries } };
                    var index = entries.len;
                    while (index > 0) {
                        index -= 1;
                        try stack.push(allocator, .{
                            .source = entries[index].value,
                            .dest = &imported_entries[index].value,
                            .depth = frame.depth + 1,
                        });
                        try stack.push(allocator, .{
                            .source = entries[index].key,
                            .dest = &imported_entries[index].key,
                            .depth = frame.depth + 1,
                        });
                    }
                },
                .struct_val => |struct_value| {
                    try budget.ensureChildren(frame.depth, struct_value.fields.len);
                    const imported_fields = try allocator.alloc(CtValue.CtFieldValue, struct_value.fields.len);
                    initCtFieldValues(imported_fields);
                    frame.dest.* = .{ .struct_val = .{
                        .alloc_id = 0,
                        .type_name = struct_value.type_name,
                        .fields = imported_fields,
                    } };
                    var index = struct_value.fields.len;
                    while (index > 0) {
                        index -= 1;
                        imported_fields[index].name = struct_value.fields[index].name;
                        try stack.push(allocator, .{
                            .source = struct_value.fields[index].value,
                            .dest = &imported_fields[index].value,
                            .depth = frame.depth + 1,
                        });
                    }
                },
            }
        }

        return imported_root;
    }

    fn evalClosureCall(
        self: *Interpreter,
        function_id: ir.FunctionId,
        args: []const CtValue,
        captures: []const CtValue,
    ) CtfeInterpretError!CtValue {
        if (self.call_stack.items.len >= self.recursion_limit) {
            try self.emitError(.recursion_limit_exceeded, "recursion limit exceeded");
            return error.CtfeFailure;
        }

        // Look up function by ID, not array index
        const func = blk: {
            for (self.program.functions) |*f| {
                if (f.id == function_id) break :blk f;
            }
            try self.emitError(.undefined_function, "invalid closure function id");
            return error.CtfeFailure;
        };
        var frame = Frame.init(self.allocator, func, args) catch return error.OutOfMemory;
        defer frame.deinit(self.allocator);
        frame.captures = captures;

        try self.call_stack.append(self.allocator, .{
            .function_name = func.name,
            .function_id = function_id,
            .instruction_index = 0,
            .source_span = self.resolveFunctionSourceSpan(func),
        });
        defer _ = self.call_stack.pop();

        if (func.body.len == 0) return .void;
        return self.execInstructions(func.body[0].instructions, &frame);
    }

    fn execTailCall(self: *Interpreter, tc: ir.TailCall, frame: *const Frame) CtfeInterpretError!CtValue {
        const args = try self.collectLocals(tc.args, frame);
        defer self.allocator.free(args);
        const func_id = self.function_by_name.get(tc.name) orelse {
            try self.emitError(.undefined_function, tc.name);
            return error.CtfeFailure;
        };
        return self.evalFunction(func_id, args);
    }

    // --------------------------------------------------------
    // Helpers
    // --------------------------------------------------------

    fn collectLocals(self: *Interpreter, locals: []const ir.LocalId, frame: *const Frame) CtfeInterpretError![]CtValue {
        const result = self.allocator.alloc(CtValue, locals.len) catch return error.OutOfMemory;
        errdefer self.allocator.free(result);
        for (locals, 0..) |local_id, i| {
            result[i] = try self.readLocal(frame, local_id);
        }
        return result;
    }

    fn recordDependency(self: *Interpreter, dependency: CtDependency) CtfeInterpretError!void {
        try self.dependencies.append(self.allocator, dependency);
    }

    fn recordReflectedStructDependency(
        self: *Interpreter,
        struct_name: []const u8,
        interface_hash: u64,
    ) CtfeInterpretError!void {
        const owned_struct_name = self.allocator.dupe(u8, struct_name) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_struct_name);
        try self.dependencies.append(self.allocator, .{
            .reflected_struct = .{
                .struct_name = owned_struct_name,
                .interface_hash = interface_hash,
            },
        });
    }

    fn emitError(self: *Interpreter, kind: CtfeErrorKind, message: []const u8) !void {
        const message_copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(message_copy);
        try self.emitOwnedError(kind, message_copy);
    }

    fn emitErrorFmt(self: *Interpreter, kind: CtfeErrorKind, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, format, args);
        errdefer self.allocator.free(message);
        try self.emitOwnedError(kind, message);
    }

    fn emitOwnedError(self: *Interpreter, kind: CtfeErrorKind, owned_message: []const u8) !void {
        const stack_copy = try self.allocator.alloc(CtfeFrame, self.call_stack.items.len);
        errdefer self.allocator.free(stack_copy);
        @memcpy(stack_copy, self.call_stack.items);

        var attribute_context: ?CtfeError.AttributeContext = null;
        errdefer if (attribute_context) |ctx| {
            self.allocator.free(ctx.attr_name);
            self.allocator.free(ctx.struct_name);
        };
        if (self.current_attribute_context) |ctx| {
            const attr_name = try self.allocator.dupe(u8, ctx.attr_name);
            errdefer self.allocator.free(attr_name);
            const struct_name = try self.allocator.dupe(u8, ctx.struct_name);
            attribute_context = .{
                .attr_name = attr_name,
                .struct_name = struct_name,
            };
        }

        try self.errors.append(self.allocator, .{
            .message = owned_message,
            .kind = kind,
            .call_stack = stack_copy,
            .attribute_context = attribute_context,
        });
    }

    fn traversalFailure(self: *Interpreter, err: ValueTraversalError) CtfeInterpretError {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTraversalDepthExceeded => {
                self.emitError(.value_traversal_limit_exceeded, "compile-time value traversal depth exceeded") catch return error.OutOfMemory;
                return error.CtfeFailure;
            },
            error.ValueTraversalBudgetExceeded => {
                self.emitError(.value_traversal_limit_exceeded, "compile-time value traversal budget exceeded") catch return error.OutOfMemory;
                return error.CtfeFailure;
            },
        }
    }

    fn persistentCacheLoadFailure(self: *Interpreter, err: PersistentCache.LoadError) CtfeInterpretError {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailure => {
                self.emitError(.host_io_failure, "persistent CTFE cache read failed") catch return error.OutOfMemory;
                return error.CtfeFailure;
            },
            error.CorruptEntry => {
                self.emitError(.host_io_failure, "persistent CTFE cache entry is corrupt") catch return error.OutOfMemory;
                return error.CtfeFailure;
            },
            error.HostIoFailure => {
                self.emitError(.host_io_failure, "persistent CTFE cache host I/O failed") catch return error.OutOfMemory;
                return error.CtfeFailure;
            },
        }
    }

    fn persistentCacheStoreFailure(self: *Interpreter, err: PersistentCache.StoreError) CtfeInterpretError {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTraversalDepthExceeded,
            error.ValueTraversalBudgetExceeded,
            => |traversal_err| return self.traversalFailure(traversal_err),
            error.SerializationFailure => {
                self.emitError(.host_io_failure, "persistent CTFE cache serialization failed") catch return error.OutOfMemory;
                return error.CtfeFailure;
            },
            error.HostIoFailure => {
                self.emitError(.host_io_failure, "persistent CTFE cache store host I/O failed") catch return error.OutOfMemory;
                return error.CtfeFailure;
            },
        }
    }

    fn currentFunctionId(self: *const Interpreter) ?ir.FunctionId {
        if (self.call_stack.items.len > 0) {
            return self.call_stack.items[self.call_stack.items.len - 1].function_id;
        }
        return null;
    }

    fn readLocal(self: *Interpreter, frame: *const Frame, id: ir.LocalId) CtfeInterpretError!CtValue {
        const value = frame.getLocal(id);
        if (value == .consumed) {
            try self.emitError(.use_after_consume, "value was used after move/release");
            return error.CtfeFailure;
        }
        return value;
    }

    fn readParam(self: *Interpreter, frame: *const Frame, index: u32) CtfeInterpretError!CtValue {
        const value = frame.getParam(index);
        if (value == .consumed) {
            try self.emitError(.use_after_consume, "parameter was used after move/release");
            return error.CtfeFailure;
        }
        return value;
    }

    fn readCaptured(self: *Interpreter, frame: *const Frame, index: u32) CtfeInterpretError!CtValue {
        const value = frame.getCaptured(index);
        if (value == .consumed) {
            try self.emitError(.use_after_consume, "captured value was used after move/release");
            return error.CtfeFailure;
        }
        return value;
    }

    fn setCurrentInstructionIndex(self: *Interpreter, index: usize) void {
        if (self.call_stack.items.len == 0) return;
        self.call_stack.items[self.call_stack.items.len - 1].instruction_index = index;
    }

    fn resolveFunctionSourceSpan(self: *const Interpreter, func: *const ir.Function) ?ast.SourceSpan {
        const graph = self.scope_graph orelse return null;
        const interner = self.interner orelse return null;

        const target_name = baseFunctionName(func.name);
        var fallback: ?ast.SourceSpan = null;

        for (graph.families.items) |family| {
            if (family.scope_id != func.scope_id) continue;
            if (!std.mem.eql(u8, interner.get(family.name), target_name)) continue;
            if (family.clauses.items.len == 0) continue;

            const clause_ref = family.clauses.items[0];
            const clause_span = clause_ref.decl.clauses[clause_ref.clause_index].meta.span;
            if (family.arity == func.arity) return clause_span;
            if (fallback == null) fallback = clause_span;
        }

        return fallback;
    }

    fn hashArgs(self: *Interpreter, args: []const CtValue) ValueTraversalError!u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (args) |arg| try arg.hashInto(self.allocator, &hasher);
        return hasher.final();
    }

    fn getBinaryBytes(val: CtValue) ?[]const u8 {
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    fn getReuseInfo(val: CtValue) ?CtValue.CtReuseToken {
        return switch (val) {
            .tuple => |tv| .{ .alloc_id = tv.alloc_id, .kind = .tuple },
            .list => |lv| .{ .alloc_id = lv.alloc_id, .kind = .list },
            .map => |mv| .{ .alloc_id = mv.alloc_id, .kind = .map },
            .struct_val => |sv| .{ .alloc_id = sv.alloc_id, .kind = .struct_val },
            .union_val => |uv| .{ .alloc_id = uv.alloc_id, .kind = .union_val },
            .closure => |cl| .{ .alloc_id = cl.alloc_id, .kind = .closure },
            else => null,
        };
    }

    fn allocIdForDest(self: *Interpreter, frame: *const Frame, dest: ir.LocalId, kind: AllocKind) std.mem.Allocator.Error!AllocId {
        const existing = frame.getLocal(dest);
        return switch (existing) {
            .reuse_token => |rt| if (rt.kind == kind) rt.alloc_id else try self.allocation_store.alloc(self.allocator, kind, self.currentFunctionId()),
            else => try self.allocation_store.alloc(self.allocator, kind, self.currentFunctionId()),
        };
    }

    fn setAggregateLocal(
        self: *Interpreter,
        dest: ir.LocalId,
        frame: *Frame,
        value: CtValue,
    ) CtfeInterpretError!void {
        if (dest >= frame.locals.len) {
            try self.emitErrorFmt(.unsupported_instruction, "aggregate destination local {d} out of range", .{dest});
            return error.CtfeFailure;
        }
        frame.setLocal(dest, value);
    }

    fn isReusableValue(val: CtValue) bool {
        return switch (val) {
            .tuple, .list, .map, .struct_val, .union_val, .closure => true,
            else => false,
        };
    }

    fn resolveOffset(self: *Interpreter, offset: ir.BinOffset, frame: *const Frame) CtfeInterpretError!usize {
        return switch (offset) {
            .static => |v| @intCast(v),
            .dynamic => |local_id| {
                const val = try self.readLocal(frame, local_id);
                return switch (val) {
                    .int => |v| if (v >= 0) @intCast(v) else 0,
                    else => 0,
                };
            },
        };
    }

    fn matchLiteralValue(val: CtValue, lit: ir.LiteralValue) bool {
        return switch (lit) {
            .int => |v| switch (val) {
                .int => |cv| cv == v,
                else => false,
            },
            .float => |v| switch (val) {
                .float => |cv| cv == v,
                else => false,
            },
            .string => |v| switch (val) {
                .string => |cv| std.mem.eql(u8, cv, v),
                else => false,
            },
            .bool_val => |v| switch (val) {
                .bool_val => |cv| cv == v,
                else => false,
            },
        };
    }

    fn matchesZigType(val: CtValue, expected: ir.ZigType) bool {
        return switch (expected) {
            .i64 => val == .int,
            .f64 => val == .float,
            .string => val == .string,
            .bool_type => val == .bool_val,
            .atom => val == .atom,
            .nil => val == .nil,
            .void => val == .void,
            .any => true,
            else => false,
        };
    }
};

/// Compute a deterministic hash of a struct's public interface.
/// Hashes public function families (sorted by name+arity) and struct attribute names/values.
fn computeStructInterfaceHash(
    allocator: std.mem.Allocator,
    graph: *const scope.ScopeGraph,
    mod_scope_id: scope.ScopeId,
    interner: ?*const ast.StringInterner,
    mod_name_str: []const u8,
) ValueTraversalError!u64 {
    var hasher = std.hash.Wyhash.init(0);

    // Hash struct name for disambiguation
    hasher.update(mod_name_str);

    // Hash public function families from this struct's scope
    const mod_scope = graph.getScope(mod_scope_id);
    var family_iter = mod_scope.function_families.iterator();
    // Collect and hash family entries (order-independent via commutative accumulation)
    var family_hash: u64 = 0;
    while (family_iter.next()) |entry| {
        const family = &graph.families.items[entry.value_ptr.*];
        if (family.visibility == .public) {
            var fh = std.hash.Wyhash.init(0);
            const name_str = if (interner) |int| int.get(family.name) else "";
            fh.update(name_str);
            fh.update(std.mem.asBytes(&family.arity));
            family_hash ^= fh.final(); // XOR for order independence
        }
    }
    hasher.update(std.mem.asBytes(&family_hash));

    // Hash struct attributes
    var attr_hash: u64 = 0;
    for (graph.structs.items) |mod_entry| {
        if (mod_entry.scope_id == mod_scope_id) {
            for (mod_entry.attributes.items) |attr| {
                var ah = std.hash.Wyhash.init(0);
                const attr_name = if (interner) |int| int.get(attr.name) else "";
                ah.update(attr_name);
                if (attr.computed_value) |cv| {
                    const cv_hash = try Interpreter.hashConstValue(allocator, cv);
                    ah.update(std.mem.asBytes(&cv_hash));
                }
                attr_hash ^= ah.final();
            }
            break;
        }
    }
    hasher.update(std.mem.asBytes(&attr_hash));

    return hasher.final();
}

fn computeSourceReflectionHash(
    alloc: std.mem.Allocator,
    graph: *const scope.ScopeGraph,
    interner: *const ast.StringInterner,
    paths: []const []const u8,
) SourcePathCanonicalizationError!u64 {
    var aggregate_hash: u64 = 0;
    var matched_count: u64 = 0;

    for (graph.structs.items) |struct_entry| {
        const source_id = struct_entry.decl.meta.span.source_id orelse continue;
        const path = graph.sourcePathById(source_id) orelse continue;
        if (!try pathFilterContains(alloc, paths, path)) continue;

        var struct_hasher = std.hash.Wyhash.init(0);
        struct_hasher.update(normalizeSourcePath(path));
        for (struct_entry.name.parts) |part| {
            struct_hasher.update(interner.get(part));
            struct_hasher.update(".");
        }
        aggregate_hash ^= struct_hasher.final();
        matched_count += 1;
    }

    var final_hasher = std.hash.Wyhash.init(0);
    final_hasher.update(std.mem.asBytes(&matched_count));
    final_hasher.update(std.mem.asBytes(&aggregate_hash));
    return final_hasher.final();
}

fn pathFilterContains(alloc: std.mem.Allocator, paths: []const []const u8, path: []const u8) SourcePathCanonicalizationError!bool {
    for (paths) |candidate| {
        if (try sourcePathsEqual(alloc, candidate, path)) return true;
    }
    return false;
}

fn sourcePathsEqual(alloc: std.mem.Allocator, left: []const u8, right: []const u8) SourcePathCanonicalizationError!bool {
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

fn canonicalSourcePath(alloc: std.mem.Allocator, path: []const u8) SourcePathCanonicalizationError![]const u8 {
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SourcePathCanonicalizationFailed,
    };
    defer alloc.free(real_path);
    return alloc.dupe(u8, real_path) catch return error.OutOfMemory;
}

fn unwrapCtAstLiteral(value: CtValue) CtValue {
    if (value != .tuple or value.tuple.elems.len != 3) return value;
    if (value.tuple.elems[2] != .nil) return value;
    const form = value.tuple.elems[0];
    return switch (form) {
        .int, .float, .string, .bool_val, .nil => form,
        .atom => |name| blk: {
            if (name.len > 0 and name[0] == ':') {
                break :blk CtValue{ .atom = name[1..] };
            }
            break :blk value;
        },
        else => value,
    };
}

fn baseFunctionName(function_name: []const u8) []const u8 {
    const core_name = if (std.mem.find(u8, function_name, "__default_")) |idx|
        function_name[0..idx]
    else
        function_name;

    return if (std.mem.findLast(u8, core_name, "__")) |idx|
        core_name[idx + 2 ..]
    else
        core_name;
}

fn appendFormatCtValue(
    alloc: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    comptime fmt: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    const formatted = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(formatted);
    try buf.appendSlice(alloc, formatted);
}

/// Format a CtValue as a human-readable inspect string.
fn formatCtValue(alloc: std.mem.Allocator, val: CtValue) ValueTraversalError![]const u8 {
    const FormatValueFrame = struct {
        value: CtValue,
        depth: usize,
    };
    const FormatSequenceFrame = struct {
        elems: []const CtValue,
        index: usize,
        depth: usize,
        close: u8,
    };
    const FormatMapFrame = struct {
        entries: []const CtValue.CtMapEntry,
        index: usize,
        depth: usize,
    };
    const FormatFrame = union(enum) {
        value: FormatValueFrame,
        sequence: FormatSequenceFrame,
        map: FormatMapFrame,
        literal: []const u8,
    };

    var budget = ValueTraversalBudget{};
    var stack = InlineTraversalStack(FormatFrame){};
    defer stack.deinit(alloc);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    try stack.push(alloc, .{ .value = .{ .value = val, .depth = 1 } });

    while (stack.pop()) |frame| {
        switch (frame) {
            .literal => |literal| try buf.appendSlice(alloc, literal),
            .sequence => |sequence| {
                if (sequence.index >= sequence.elems.len) {
                    try buf.append(alloc, sequence.close);
                    continue;
                }

                if (sequence.index > 0) try buf.appendSlice(alloc, ", ");
                try stack.push(alloc, .{ .sequence = .{
                    .elems = sequence.elems,
                    .index = sequence.index + 1,
                    .depth = sequence.depth,
                    .close = sequence.close,
                } });
                try stack.push(alloc, .{ .value = .{
                    .value = sequence.elems[sequence.index],
                    .depth = sequence.depth + 1,
                } });
            },
            .map => |map| {
                if (map.index >= map.entries.len) {
                    try buf.append(alloc, '}');
                    continue;
                }

                if (map.index > 0) try buf.appendSlice(alloc, ", ");
                const entry = map.entries[map.index];
                try stack.push(alloc, .{ .map = .{
                    .entries = map.entries,
                    .index = map.index + 1,
                    .depth = map.depth,
                } });
                try stack.push(alloc, .{ .value = .{ .value = entry.value, .depth = map.depth + 1 } });
                try stack.push(alloc, .{ .literal = " => " });
                try stack.push(alloc, .{ .value = .{ .value = entry.key, .depth = map.depth + 1 } });
            },
            .value => |value_frame| {
                try budget.visit(value_frame.depth);
                switch (value_frame.value) {
                    .int => |value| try appendFormatCtValue(alloc, &buf, "{d}", .{value}),
                    .float => |value| try appendFormatCtValue(alloc, &buf, "{d}", .{value}),
                    .string => |value| {
                        try buf.append(alloc, '"');
                        try buf.appendSlice(alloc, value);
                        try buf.append(alloc, '"');
                    },
                    .bool_val => |value| try buf.appendSlice(alloc, if (value) "true" else "false"),
                    .atom => |value| {
                        try buf.append(alloc, ':');
                        try buf.appendSlice(alloc, value);
                    },
                    .nil => try buf.appendSlice(alloc, "nil"),
                    .void => try buf.appendSlice(alloc, "void"),
                    .consumed => try buf.appendSlice(alloc, "<consumed>"),
                    .reuse_token => try buf.appendSlice(alloc, "<reuse-token>"),
                    .tuple => |tuple_value| {
                        try budget.ensureChildren(value_frame.depth, tuple_value.elems.len);
                        try buf.append(alloc, '{');
                        try stack.push(alloc, .{ .sequence = .{
                            .elems = tuple_value.elems,
                            .index = 0,
                            .depth = value_frame.depth,
                            .close = '}',
                        } });
                    },
                    .list => |list_value| {
                        try budget.ensureChildren(value_frame.depth, list_value.elems.len);
                        try buf.append(alloc, '[');
                        try stack.push(alloc, .{ .sequence = .{
                            .elems = list_value.elems,
                            .index = 0,
                            .depth = value_frame.depth,
                            .close = ']',
                        } });
                    },
                    .map => |map_value| {
                        try budget.ensureChildren(value_frame.depth, try checkedChildCount(map_value.entries.len, 2));
                        try buf.appendSlice(alloc, "%{");
                        try stack.push(alloc, .{ .map = .{
                            .entries = map_value.entries,
                            .index = 0,
                            .depth = value_frame.depth,
                        } });
                    },
                    .struct_val => |struct_value| try appendFormatCtValue(alloc, &buf, "%{s}{{...}}", .{struct_value.type_name}),
                    .union_val => |union_value| try appendFormatCtValue(alloc, &buf, "{s}.{s}(...)", .{ union_value.type_name, union_value.variant }),
                    .enum_val => |enum_value| try appendFormatCtValue(alloc, &buf, "{s}.{s}", .{ enum_value.type_name, enum_value.variant }),
                    .optional => |optional_value| {
                        if (optional_value.value) |child_value| {
                            try budget.ensureChildren(value_frame.depth, 1);
                            try stack.push(alloc, .{ .value = .{
                                .value = child_value.*,
                                .depth = value_frame.depth + 1,
                            } });
                        } else {
                            try buf.appendSlice(alloc, "nil");
                        }
                    },
                    .closure => try buf.appendSlice(alloc, "#Function<closure>"),
                }
            },
        }
    }

    return buf.toOwnedSlice(alloc);
}

// ============================================================
// Frame
// ============================================================

pub const Frame = struct {
    function_id: ir.FunctionId,
    function_name: []const u8,
    locals: []CtValue,
    params: []const CtValue,
    captures: []const CtValue,
    current_block_label: ?ir.LabelId = null,
    predecessor_block_label: ?ir.LabelId = null,

    pub fn init(allocator: std.mem.Allocator, func: *const ir.Function, args: []const CtValue) !Frame {
        const local_count = if (func.local_count > 0) func.local_count else blk: {
            // Fallback: scan instructions for max local id
            var max: u32 = 0;
            for (func.body) |block| {
                max = @max(max, scanMaxLocal(block.instructions));
            }
            break :blk max + 1;
        };
        const locals = try allocator.alloc(CtValue, local_count);
        @memset(locals, .void);
        return .{
            .function_id = func.id,
            .function_name = func.name,
            .locals = locals,
            .params = args,
            .captures = &.{},
            .current_block_label = null,
            .predecessor_block_label = null,
        };
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.locals);
    }

    pub fn getLocal(self: *const Frame, id: ir.LocalId) CtValue {
        if (id >= self.locals.len) return .void;
        return self.locals[id];
    }

    pub fn setLocal(self: *Frame, id: ir.LocalId, val: CtValue) void {
        if (id < self.locals.len) {
            self.locals[id] = val;
        }
    }

    pub fn getParam(self: *const Frame, index: u32) CtValue {
        if (index >= self.params.len) return .void;
        return self.params[index];
    }

    pub fn getCaptured(self: *const Frame, index: u32) CtValue {
        if (index >= self.captures.len) return .void;
        return self.captures[index];
    }
};

/// Scan instructions recursively for the maximum LocalId used.
fn scanMaxLocal(instrs: []const ir.Instruction) u32 {
    var max: u32 = 0;
    for (instrs) |instr| {
        switch (instr) {
            .const_int => |ci| max = @max(max, ci.dest),
            .const_float => |cf| max = @max(max, cf.dest),
            .const_string => |cs| max = @max(max, cs.dest),
            .const_bool => |cb| max = @max(max, cb.dest),
            .const_atom => |ca| max = @max(max, ca.dest),
            .const_nil => |dest| max = @max(max, dest),
            .local_get => |lg| max = @max(max, @max(lg.dest, lg.source)),
            .local_set => |ls| max = @max(max, @max(ls.dest, ls.value)),
            .param_get => |pg| max = @max(max, pg.dest),
            .binary_op => |op| max = @max(max, @max(op.dest, @max(op.lhs, op.rhs))),
            .unary_op => |op| max = @max(max, @max(op.dest, op.operand)),
            .if_expr => |ie| {
                max = @max(max, ie.dest);
                max = @max(max, scanMaxLocal(ie.then_instrs));
                max = @max(max, scanMaxLocal(ie.else_instrs));
            },
            .case_block => |cb| {
                max = @max(max, cb.dest);
                max = @max(max, scanMaxLocal(cb.pre_instrs));
                max = @max(max, scanMaxLocal(cb.default_instrs));
                for (cb.arms) |arm| {
                    max = @max(max, scanMaxLocal(arm.cond_instrs));
                    max = @max(max, scanMaxLocal(arm.body_instrs));
                }
            },
            .switch_literal => |sl| {
                max = @max(max, @max(sl.dest, sl.scrutinee));
                for (sl.cases) |c| max = @max(max, scanMaxLocal(c.body_instrs));
                max = @max(max, scanMaxLocal(sl.default_instrs));
            },
            .switch_return => |sr| {
                for (sr.cases) |c| max = @max(max, scanMaxLocal(c.body_instrs));
                max = @max(max, scanMaxLocal(sr.default_instrs));
            },
            .union_switch => |us| {
                max = @max(max, @max(us.dest, us.scrutinee));
                for (us.cases) |c| max = @max(max, scanMaxLocal(c.body_instrs));
                // The catch-all `_` prong sizes the CTFE frame too: a local
                // defined only inside `else_instrs` would otherwise overflow
                // the `locals` array at `frame.setLocal` during evaluation.
                if (us.has_else) max = @max(max, scanMaxLocal(us.else_instrs));
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| max = @max(max, scanMaxLocal(c.body_instrs));
            },
            .try_call_named => |tcn| {
                max = @max(max, tcn.dest);
                max = @max(max, scanMaxLocal(tcn.handler_instrs));
                max = @max(max, scanMaxLocal(tcn.success_instrs));
            },
            .optional_dispatch => |od| {
                max = @max(max, od.payload_local);
                max = @max(max, scanMaxLocal(od.nil_instrs));
                max = @max(max, scanMaxLocal(od.struct_instrs));
            },
            .guard_block => |gb| {
                max = @max(max, scanMaxLocal(gb.body));
            },
            .ret => |r| if (r.value) |v| {
                max = @max(max, v);
            },
            else => {},
        }
    }
    return max;
}

// ============================================================
// ExecResult — internal control flow signal
// ============================================================

const ExecResult = union(enum) {
    continued,
    returned: CtValue,
    broke: ?CtValue,
    jumped: ir.LabelId,
};

pub const CtfeInterpretError = error{
    CtfeFailure,
    OutOfMemory,
};

// ============================================================
// Bridge: ConstValue → AST Expr (for attribute substitution)
// ============================================================

const ConstValueExprBuildGuard = struct {
    allocator: std.mem.Allocator,
    expr_nodes: std.ArrayListUnmanaged(*ast.Expr) = .empty,
    expr_slices: std.ArrayListUnmanaged([]*const ast.Expr) = .empty,
    map_field_slices: std.ArrayListUnmanaged([]ast.MapField) = .empty,
    struct_field_slices: std.ArrayListUnmanaged([]ast.StructField) = .empty,
    name_part_slices: std.ArrayListUnmanaged([]ast.StringId) = .empty,
    active: bool = true,

    fn deinit(self: *ConstValueExprBuildGuard) void {
        if (self.active) {
            for (self.expr_slices.items) |slice| {
                self.allocator.free(slice);
            }
            for (self.map_field_slices.items) |slice| {
                self.allocator.free(slice);
            }
            for (self.struct_field_slices.items) |slice| {
                self.allocator.free(slice);
            }
            for (self.name_part_slices.items) |slice| {
                self.allocator.free(slice);
            }
            for (self.expr_nodes.items) |expr| {
                self.allocator.destroy(expr);
            }
        }

        self.expr_nodes.deinit(self.allocator);
        self.expr_slices.deinit(self.allocator);
        self.map_field_slices.deinit(self.allocator);
        self.struct_field_slices.deinit(self.allocator);
        self.name_part_slices.deinit(self.allocator);
    }

    fn release(self: *ConstValueExprBuildGuard) void {
        self.active = false;
    }

    fn createExpr(self: *ConstValueExprBuildGuard) std.mem.Allocator.Error!*ast.Expr {
        const expr = try self.allocator.create(ast.Expr);
        errdefer self.allocator.destroy(expr);
        try self.expr_nodes.append(self.allocator, expr);
        return expr;
    }

    fn allocExprSlice(self: *ConstValueExprBuildGuard, len: usize) std.mem.Allocator.Error![]*const ast.Expr {
        const slice = try self.allocator.alloc(*const ast.Expr, len);
        errdefer self.allocator.free(slice);
        try self.expr_slices.append(self.allocator, slice);
        return slice;
    }

    fn allocMapFields(self: *ConstValueExprBuildGuard, len: usize) std.mem.Allocator.Error![]ast.MapField {
        const slice = try self.allocator.alloc(ast.MapField, len);
        errdefer self.allocator.free(slice);
        try self.map_field_slices.append(self.allocator, slice);
        return slice;
    }

    fn allocStructFields(self: *ConstValueExprBuildGuard, len: usize) std.mem.Allocator.Error![]ast.StructField {
        const slice = try self.allocator.alloc(ast.StructField, len);
        errdefer self.allocator.free(slice);
        try self.struct_field_slices.append(self.allocator, slice);
        return slice;
    }

    fn allocNameParts(self: *ConstValueExprBuildGuard, len: usize) std.mem.Allocator.Error![]ast.StringId {
        const slice = try self.allocator.alloc(ast.StringId, len);
        errdefer self.allocator.free(slice);
        try self.name_part_slices.append(self.allocator, slice);
        return slice;
    }
};

/// Free an expression tree returned by `constValueToExpr`.
///
/// The tree owns only the AST nodes and slices produced by the ConstValue
/// conversion. Interned string ids and source-independent scalar metadata are
/// borrowed and are not freed here.
pub fn deinitConstValueExpr(alloc: std.mem.Allocator, expr: *const ast.Expr) void {
    deinitConvertedConstValueExpr(alloc, expr);
}

fn deinitConvertedConstValueExpr(alloc: std.mem.Allocator, expr: *const ast.Expr) void {
    const mutable = @constCast(expr);
    switch (mutable.*) {
        .int_literal,
        .float_literal,
        .string_literal,
        .atom_literal,
        .bool_literal,
        .nil_literal,
        => {},
        .tuple => |tuple_expr| {
            for (tuple_expr.elements) |element| {
                deinitConvertedConstValueExpr(alloc, element);
            }
            alloc.free(tuple_expr.elements);
        },
        .list => |list_expr| {
            for (list_expr.elements) |element| {
                deinitConvertedConstValueExpr(alloc, element);
            }
            alloc.free(list_expr.elements);
        },
        .map => |map_expr| {
            for (map_expr.fields) |field| {
                deinitConvertedConstValueExpr(alloc, field.key);
                deinitConvertedConstValueExpr(alloc, field.value);
            }
            alloc.free(map_expr.fields);
        },
        .struct_expr => |struct_expr| {
            for (struct_expr.fields) |field| {
                deinitConvertedConstValueExpr(alloc, field.value);
            }
            alloc.free(struct_expr.fields);
            alloc.free(struct_expr.struct_name.parts);
        },
        else => unreachable,
    }
    alloc.destroy(mutable);
}

pub fn constValueToExpr(
    alloc: std.mem.Allocator,
    val: ConstValue,
    interner: *ast.StringInterner,
) !*const ast.Expr {
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };
    const ConvertFrame = struct {
        source: ConstValue,
        dest: *ast.Expr,
        depth: usize,
    };

    var budget = ValueTraversalBudget{};
    var stack = InlineTraversalStack(ConvertFrame){};
    defer stack.deinit(alloc);
    var guard = ConstValueExprBuildGuard{ .allocator = alloc };
    defer guard.deinit();

    const root_expr = try guard.createExpr();
    try stack.push(alloc, .{ .source = val, .dest = root_expr, .depth = 1 });

    while (stack.pop()) |frame| {
        try budget.visit(frame.depth);
        frame.dest.* = switch (frame.source) {
            .int => |value| .{ .int_literal = .{ .meta = meta, .value = value } },
            .float => |value| .{ .float_literal = .{ .meta = meta, .value = value } },
            .string => |value| .{ .string_literal = .{ .meta = meta, .value = try interner.intern(value) } },
            .bool_val => |value| .{ .bool_literal = .{ .meta = meta, .value = value } },
            .atom => |value| .{ .atom_literal = .{ .meta = meta, .value = try interner.intern(value) } },
            .nil => .{ .nil_literal = .{ .meta = meta } },
            .void => .{ .nil_literal = .{ .meta = meta } },
            .tuple => |elems| blk: {
                try budget.ensureChildren(frame.depth, elems.len);
                const converted = try guard.allocExprSlice(elems.len);
                var index = elems.len;
                while (index > 0) {
                    index -= 1;
                    const child_expr = try guard.createExpr();
                    converted[index] = child_expr;
                    try stack.push(alloc, .{
                        .source = elems[index],
                        .dest = child_expr,
                        .depth = frame.depth + 1,
                    });
                }
                break :blk .{ .tuple = .{ .meta = meta, .elements = converted } };
            },
            .list => |elems| blk: {
                try budget.ensureChildren(frame.depth, elems.len);
                const converted = try guard.allocExprSlice(elems.len);
                var index = elems.len;
                while (index > 0) {
                    index -= 1;
                    const child_expr = try guard.createExpr();
                    converted[index] = child_expr;
                    try stack.push(alloc, .{
                        .source = elems[index],
                        .dest = child_expr,
                        .depth = frame.depth + 1,
                    });
                }
                break :blk .{ .list = .{ .meta = meta, .elements = converted } };
            },
            .map => |entries| blk: {
                try budget.ensureChildren(frame.depth, try checkedChildCount(entries.len, 2));
                const converted = try guard.allocMapFields(entries.len);
                var index = entries.len;
                while (index > 0) {
                    index -= 1;
                    const key_expr = try guard.createExpr();
                    const value_expr = try guard.createExpr();
                    converted[index] = .{ .key = key_expr, .value = value_expr };
                    try stack.push(alloc, .{
                        .source = entries[index].value,
                        .dest = value_expr,
                        .depth = frame.depth + 1,
                    });
                    try stack.push(alloc, .{
                        .source = entries[index].key,
                        .dest = key_expr,
                        .depth = frame.depth + 1,
                    });
                }
                break :blk .{ .map = .{ .meta = meta, .fields = converted } };
            },
            .struct_val => |struct_value| blk: {
                try budget.ensureChildren(frame.depth, struct_value.fields.len);
                const converted = try guard.allocStructFields(struct_value.fields.len);
                var index = struct_value.fields.len;
                while (index > 0) {
                    index -= 1;
                    const value_expr = try guard.createExpr();
                    converted[index] = .{
                        .name = try interner.intern(struct_value.fields[index].name),
                        .value = value_expr,
                    };
                    try stack.push(alloc, .{
                        .source = struct_value.fields[index].value,
                        .dest = value_expr,
                        .depth = frame.depth + 1,
                    });
                }
                const name_parts = try guard.allocNameParts(1);
                name_parts[0] = try interner.intern(struct_value.type_name);
                break :blk .{ .struct_expr = .{
                    .meta = meta,
                    .struct_name = .{ .parts = name_parts, .span = .{ .start = 0, .end = 0 } },
                    .update_source = null,
                    .fields = converted,
                } };
            },
        };
    }

    guard.release();
    return root_expr;
}

// ============================================================
// Computed Attribute Evaluation
// ============================================================

const scope = @import("scope.zig");
const target_caps = @import("target_caps.zig");

/// The resolved compilation target the gating pass intersects each
/// declaration's `@available_on` requirement against
/// (`docs/target-capability-model-plan.md`, Phase 2). `caps` is the target's
/// supported capability set (`target_caps.capabilitiesForTarget`); `label` is
/// the human triple shown in the diagnostic (`unavailable on \`wasm32-wasi\``).
///
/// Null `caps` (a target whose atoms did not resolve to a `std.Target`, or a
/// caller that did not supply a target — bare HIR unit tests) disables gating
/// entirely: NO declaration is ever marked `gated_out`, so behavior is
/// unchanged. On native, `caps` holds every capability, so every
/// `@available_on` requirement is a subset and nothing is gated — the
/// zero-impact regression-anchor guarantee.
pub const GatingTarget = struct {
    caps: ?target_caps.TargetCapabilitySet,
    label: []const u8,
};

/// A diagnostic produced by the AST-based `@available_on` gate pass (an
/// unknown capability atom or a malformed attribute value). Surfaced through
/// the caller's diagnostic engine at the attribute's span.
pub const GateDiagnostic = struct {
    message: []const u8,
    span: ast.SourceSpan,
};

/// Apply the `@available_on` capability gate across the whole scope graph
/// DIRECTLY FROM THE AST, BEFORE type-checking and independent of IR-based CTFE
/// value computation (`docs/target-capability-model-plan.md`, Phase 2).
///
/// Why AST-based and pre-typecheck: the gate marker (`gated_out`) must be set
/// BEFORE name resolution runs, because resolution is where the
/// `target_capability` diagnostic is emitted. The per-struct compile path
/// type-checks each struct (resolving references) before the IR-based CTFE
/// attribute pass runs, so an IR-based gate would mark the family too late. The
/// `@available_on` value is a literal atom (or a list of atom literals) — no
/// interpreter, no IR, no `call_named` is needed to read it — so this pass
/// resolves the required capabilities straight from the attribute's `value`
/// AST and sets `gated_out` on every struct / function family / macro family.
///
/// Idempotent and target-keyed: each entry's `gated_out` is reset then
/// recomputed, so a re-run for a different target produces the correct marker.
/// A null-caps `target` disables gating (no entry is ever gated). Unknown /
/// malformed capability atoms append a `GateDiagnostic` to `diagnostics`.
//
// ZAP_TARGET_GATE_DECISION_BEGIN
// Everything between this sentinel and ZAP_TARGET_GATE_DECISION_END is the
// `@available_on` gate DECISION path. The capability-not-name audit
// (`src/target_capability_audit.zig`) scans this region and FAILS the build if
// an OS-name string literal (`"wasi"`, `"windows"`, …) appears here: the gate
// must decide availability from the capability BITSET
// (`TargetCapabilitySet.firstMissingFrom`), never by comparing an OS name.
// OS-name facts live ONLY in `src/target_caps.zig`'s capability-derivation
// layer (where reading `std.Target` os/arch to COMPUTE the bitset is correct).
pub fn gateAvailableOn(
    alloc: std.mem.Allocator,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
    target: GatingTarget,
    diagnostics: *std.ArrayListUnmanaged(GateDiagnostic),
) std.mem.Allocator.Error!void {
    for (graph.structs.items) |*mod_entry| {
        mod_entry.gated_out = null;
        for (mod_entry.attributes.items) |*attr| {
            if (try gateFromAttrAst(alloc, attr, interner, target, diagnostics)) |g| {
                mod_entry.gated_out = g;
            }
        }
    }
    for (graph.families.items) |*family| {
        family.gated_out = null;
        for (family.attributes.items) |*attr| {
            if (try gateFromAttrAst(alloc, attr, interner, target, diagnostics)) |g| {
                family.gated_out = g;
            }
        }
    }
    // A macro is compile-time-only: it always runs on the host and has no
    // runtime reference that could be "unavailable on a target", so a
    // macro-level `@available_on` is a category error — silently ignoring it
    // would be a footgun (the author would believe the feature is gated when
    // it is not). The capability a macro's EXPANSION needs is gated correctly
    // and automatically: the expanded `:zig.`/def reference flows through name
    // resolution and trips the gate there (verified). So we REJECT a
    // macro-level `@available_on` with a precise diagnostic redirecting the
    // author to gate the runtime API instead. (`@available_on` is still
    // *accepted* on `def`/`struct` — only the meaningless macro placement is an
    // error; this is distinct from the retired `@requires`, which the collector
    // rejects outright on macros.)
    for (graph.macro_families.items) |*macro_family| {
        for (macro_family.attributes.items) |*attr| {
            if (!std.mem.eql(u8, interner.get(attr.name), "available_on")) continue;
            const span = if (attr.value) |v| v.getMeta().span else ast.SourceSpan{ .start = 0, .end = 0 };
            try diagnostics.append(alloc, .{
                .message = "`@available_on` cannot gate a macro — a macro runs at compile time and has no per-target runtime form. Gate the runtime API the macro expands to (its `def`/`:zig.` call is gated automatically), or move `@available_on` to a `def`/`struct`.",
                .span = span,
            });
        }
    }
}

/// Compute the `@available_on` gate for one attribute straight from its AST
/// `value` expression. Returns the `GatedOut` marker when the attribute is
/// `@available_on` and the target lacks a required capability; null otherwise
/// (not `@available_on`, available, or malformed — the malformed case having
/// appended its own diagnostic). The value AST is a `list` of `atom_literal`s
/// (the call-form parser shape) or a bare `atom_literal` (the valued form).
fn gateFromAttrAst(
    alloc: std.mem.Allocator,
    attr: *const scope.Attribute,
    interner: *const ast.StringInterner,
    target: GatingTarget,
    diagnostics: *std.ArrayListUnmanaged(GateDiagnostic),
) std.mem.Allocator.Error!?scope.GatedOut {
    if (!std.mem.eql(u8, interner.get(attr.name), "available_on")) return null;
    const value_expr = attr.value orelse return null;
    const span = value_expr.getMeta().span;

    var required = target_caps.TargetCapabilitySet{};
    switch (value_expr.*) {
        .list => |l| {
            if (l.elements.len == 0) {
                try diagnostics.append(alloc, .{ .message = "`@available_on` requires at least one capability atom, e.g. `@available_on(:processes)`", .span = span });
                return null;
            }
            for (l.elements) |elem| {
                const cap = try capabilityFromAtomExpr(alloc, elem, interner, diagnostics) orelse return null;
                required = required.with(cap);
            }
        },
        .atom_literal => |a| {
            const cap = target_caps.capabilityFromAtomName(interner.get(a.value)) orelse {
                try appendUnknownCapDiagnostic(alloc, interner.get(a.value), span, diagnostics);
                return null;
            };
            required = required.with(cap);
        },
        else => {
            try diagnostics.append(alloc, .{ .message = "`@available_on` value must be a capability atom or a list of capability atoms", .span = span });
            return null;
        },
    }

    const tcaps = target.caps orelse return null;
    const missing = required.firstMissingFrom(tcaps) orelse return null;
    return .{ .missing_cap = missing.atomName(), .target_label = target.label };
}

/// Resolve a single `@available_on` list element (an `atom_literal`) to its
/// capability, appending a precise diagnostic for a non-atom element or an
/// unknown capability atom.
fn capabilityFromAtomExpr(
    alloc: std.mem.Allocator,
    expr: *const ast.Expr,
    interner: *const ast.StringInterner,
    diagnostics: *std.ArrayListUnmanaged(GateDiagnostic),
) std.mem.Allocator.Error!?target_caps.TargetCapability {
    switch (expr.*) {
        .atom_literal => |a| {
            const name = interner.get(a.value);
            if (target_caps.capabilityFromAtomName(name)) |cap| return cap;
            try appendUnknownCapDiagnostic(alloc, name, expr.getMeta().span, diagnostics);
            return null;
        },
        else => {
            try diagnostics.append(alloc, .{ .message = "`@available_on` arguments must be capability atoms, e.g. `@available_on(:processes, :signals)`", .span = expr.getMeta().span });
            return null;
        },
    }
}

fn appendUnknownCapDiagnostic(
    alloc: std.mem.Allocator,
    name: []const u8,
    span: ast.SourceSpan,
    diagnostics: *std.ArrayListUnmanaged(GateDiagnostic),
) std.mem.Allocator.Error!void {
    const msg = try std.fmt.allocPrint(
        alloc,
        "unknown capability `:{s}` in `@available_on` — valid capabilities are `:filesystem`, `:processes`, `:signals`, `:network`, `:threads`, `:terminal`, `:backtrace`",
        .{name},
    );
    try diagnostics.append(alloc, .{ .message = msg, .span = span });
}
// ZAP_TARGET_GATE_DECISION_END

/// Evaluate computed attributes across all structs.
///
/// Walks struct and function attributes looking for those whose values
/// are function calls (zero-argument). For each, resolves the callee to
/// an IR function, evaluates it via CTFE, and stores the result as
/// `computed_value` on the attribute.
///
/// This runs after IR lowering — the full IR program is available.
pub fn evaluateComputedAttributes(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
    cache_dir: ?[]const u8,
    compile_options_hash: u64,
) EvalAttrError!EvalAttrResult {
    var interp = try Interpreter.init(alloc, program);
    defer interp.deinit();
    interp.scope_graph = graph;
    interp.interner = interner;
    interp.compile_options_hash = compile_options_hash;
    if (!try enableComputedAttributePersistentCache(&interp, cache_dir)) {
        return finishEvalAttrResult(alloc, &interp, 0, 0);
    }

    var evaluated: u32 = 0;
    var failed: u32 = 0;

    // Walk struct-level attributes
    for (graph.structs.items) |*mod_entry| {
        for (mod_entry.attributes.items) |*attr| {
            if (attr.computed_value != null) continue; // already computed
            if (try evaluateAttributeForResult(alloc, &interp, attr, mod_entry.name, interner)) {
                evaluated += 1;
            } else {
                failed += 1;
            }
        }
    }

    // Walk function-level attributes
    for (graph.families.items) |*family| {
        // Find the enclosing struct for name mangling
        const mod_name = findStructForScope(graph, family.scope_id);
        for (family.attributes.items) |*attr| {
            if (attr.computed_value != null) continue;
            if (try evaluateAttributeForResult(alloc, &interp, attr, mod_name, interner)) {
                evaluated += 1;
            } else {
                failed += 1;
            }
        }
    }

    return finishEvalAttrResult(alloc, &interp, evaluated, failed);
}

pub const EvalAttrResult = struct {
    evaluated: u32,
    failed: u32,
    errors: []const CtfeError,
};

pub const EvalAttrError = error{
    OutOfMemory,
};

fn finishEvalAttrResult(
    alloc: std.mem.Allocator,
    interp: *const Interpreter,
    evaluated: u32,
    failed: u32,
) EvalAttrError!EvalAttrResult {
    return .{
        .evaluated = evaluated,
        .failed = failed,
        .errors = try cloneCtfeErrors(alloc, interp.errors.items),
    };
}

fn enableComputedAttributePersistentCache(
    interp: *Interpreter,
    cache_dir: ?[]const u8,
) EvalAttrError!bool {
    const dir = cache_dir orelse return true;
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir) catch |err| {
        try interp.emitErrorFmt(
            .host_io_failure,
            "persistent CTFE cache setup failed for `{s}`: {s}",
            .{ dir, @errorName(err) },
        );
        return false;
    };
    interp.persistent_cache = PersistentCache.init(dir);
    return true;
}

/// Evaluate computed attributes in dependency order.
///
/// Like `evaluateComputedAttributes`, but processes structs in the given
/// topological order. Results from earlier structs are stored before
/// later structs are evaluated, ensuring that cross-struct attribute
/// references resolve correctly.
pub fn evaluateStructAttributesInOrder(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
    struct_order: []const []const u8,
    cache_dir: ?[]const u8,
    compile_options_hash: u64,
) EvalAttrError!EvalAttrResult {
    var interp = try Interpreter.init(alloc, program);
    defer interp.deinit();
    interp.scope_graph = graph;
    interp.interner = interner;
    interp.compile_options_hash = compile_options_hash;
    if (!try enableComputedAttributePersistentCache(&interp, cache_dir)) {
        return finishEvalAttrResult(alloc, &interp, 0, 0);
    }

    var evaluated: u32 = 0;
    var failed: u32 = 0;

    // Process structs in dependency order
    for (struct_order) |mod_name| {
        // Find the struct entry matching this name
        for (graph.structs.items) |*mod_entry| {
            if (structNameMatchesStr(mod_entry.name, mod_name, interner)) {
                // Evaluate struct-level attributes
                for (mod_entry.attributes.items) |*attr| {
                    if (attr.computed_value != null) continue;
                    if (try evaluateAttributeForResult(alloc, &interp, attr, mod_entry.name, interner)) {
                        evaluated += 1;
                    } else {
                        failed += 1;
                    }
                }

                // Evaluate function-level attributes in this struct
                for (graph.families.items) |*family| {
                    if (family.scope_id == mod_entry.scope_id) {
                        for (family.attributes.items) |*attr| {
                            if (attr.computed_value != null) continue;
                            if (try evaluateAttributeForResult(alloc, &interp, attr, mod_entry.name, interner)) {
                                evaluated += 1;
                            } else {
                                failed += 1;
                            }
                        }
                    }
                }
                break;
            }
        }
    }

    // Also process any structs not in the order list (stdlib, etc.)
    for (graph.structs.items) |*mod_entry| {
        for (mod_entry.attributes.items) |*attr| {
            if (attr.computed_value != null) continue;
            if (try evaluateAttributeForResult(alloc, &interp, attr, mod_entry.name, interner)) {
                evaluated += 1;
            } else {
                failed += 1;
            }
        }
    }

    return finishEvalAttrResult(alloc, &interp, evaluated, failed);
}

/// Evaluate computed attributes for a single struct against the struct IR that
/// has just been lowered. This is used by the true struct-by-struct compiler
/// loop so later structs can observe earlier computed values without trying to
/// evaluate structs whose IR does not exist yet.
pub fn evaluateComputedAttributesForStruct(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
    struct_name: []const u8,
    cache_dir: ?[]const u8,
    compile_options_hash: u64,
) EvalAttrError!EvalAttrResult {
    var interp = try Interpreter.init(alloc, program);
    defer interp.deinit();
    interp.scope_graph = graph;
    interp.interner = interner;
    interp.compile_options_hash = compile_options_hash;
    if (!try enableComputedAttributePersistentCache(&interp, cache_dir)) {
        return finishEvalAttrResult(alloc, &interp, 0, 0);
    }

    var evaluated: u32 = 0;
    var failed: u32 = 0;

    for (graph.structs.items) |*mod_entry| {
        if (!structNameMatchesStr(mod_entry.name, struct_name, interner)) continue;

        for (mod_entry.attributes.items) |*attr| {
            if (attr.computed_value != null) continue;
            if (try evaluateAttributeForResult(alloc, &interp, attr, mod_entry.name, interner)) {
                evaluated += 1;
            } else {
                failed += 1;
            }
        }

        for (graph.families.items) |*family| {
            if (family.scope_id != mod_entry.scope_id) continue;
            for (family.attributes.items) |*attr| {
                if (attr.computed_value != null) continue;
                if (try evaluateAttributeForResult(alloc, &interp, attr, mod_entry.name, interner)) {
                    evaluated += 1;
                } else {
                    failed += 1;
                }
            }
        }

        break;
    }

    return finishEvalAttrResult(alloc, &interp, evaluated, failed);
}

fn structNameMatchesStr(name: ast.StructName, target: []const u8, interner: *const ast.StringInterner) bool {
    if (name.parts.len == 1) {
        return std.mem.eql(u8, interner.get(name.parts[0]), target);
    }
    // Multi-part: join with "."
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    for (name.parts, 0..) |part, i| {
        if (i > 0 and pos < buf.len) {
            buf[pos] = '.';
            pos += 1;
        }
        const s = interner.get(part);
        const end = @min(pos + s.len, buf.len);
        @memcpy(buf[pos..end], s[0 .. end - pos]);
        pos = end;
    }
    return std.mem.eql(u8, buf[0..pos], target);
}

fn evaluateAttributeForResult(
    alloc: std.mem.Allocator,
    interp: *Interpreter,
    attr: *scope.Attribute,
    mod_name: ?ast.StructName,
    interner: *const ast.StringInterner,
) EvalAttrError!bool {
    tryEvalAttribute(alloc, interp, attr, mod_name, interner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotComputable,
        error.CtfeFailed,
        => return false,
    };
    return true;
}

/// Try to evaluate a single attribute's value via CTFE.
/// Handles recursively evaluable constant expressions and compile-time calls.
fn tryEvalAttribute(
    alloc: std.mem.Allocator,
    interp: *Interpreter,
    attr: *scope.Attribute,
    mod_name: ?ast.StructName,
    interner: *const ast.StringInterner,
) !void {
    const value_expr = attr.value orelse return error.NotComputable;

    const prev_context = interp.current_attribute_context;
    defer interp.current_attribute_context = prev_context;
    const struct_name_str = if (mod_name) |mn| try structNameToString(alloc, mn, interner) else null;
    defer if (struct_name_str) |name| alloc.free(name);
    if (mod_name) |mn| {
        _ = mn;
        interp.current_attribute_context = .{
            .attr_name = interner.get(attr.name),
            .struct_name = struct_name_str.?,
        };
    } else {
        interp.current_attribute_context = .{
            .attr_name = interner.get(attr.name),
            .struct_name = "<unknown>",
        };
    }

    var temp_scope = ConstExprTempScope.init(alloc);
    defer temp_scope.deinit();

    const attribute_allocator = if (interp.scope_graph) |graph| graph.allocator else alloc;
    const ct_value = try evaluateConstExpr(&temp_scope, interp, value_expr, mod_name, interner);
    const exported = exportValue(attribute_allocator, ct_value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ValueTraversalDepthExceeded => return attrTraversalFailure(interp, error.ValueTraversalDepthExceeded),
        error.ValueTraversalBudgetExceeded => return attrTraversalFailure(interp, error.ValueTraversalBudgetExceeded),
        error.CannotExport => return error.CtfeFailed,
    };
    attr.setComputedValueOwned(attribute_allocator, exported);
}

/// Convert a literal AST expression to a CtValue for use as a CTFE argument.
/// Returns null for non-literal expressions.
fn astLiteralToCtValue(expr: *const ast.Expr, interner: *const ast.StringInterner) ?CtValue {
    return switch (expr.*) {
        .int_literal => |v| .{ .int = v.value },
        .float_literal => |v| .{ .float = v.value },
        .string_literal => |v| .{ .string = interner.get(v.value) },
        .atom_literal => |v| .{ .atom = interner.get(v.value) },
        .bool_literal => |v| .{ .bool_val = v.value },
        .nil_literal => .nil,
        else => null,
    };
}

fn importComputedConstValue(alloc: std.mem.Allocator, interp: *Interpreter, cv: ConstValue) AttrEvalInternalError!CtValue {
    return Interpreter.importConstValue(alloc, cv) catch |err| return attrTraversalFailure(interp, err);
}

// Const-expression CtValues returned from evaluateConstExpr are valid only
// while this scope lives. Aggregate payloads, concatenated strings, imported
// aggregate wrappers, and dotted type names are allocated here; allocation
// records remain interpreter-owned so Interpreter.deinit can release them.
const ConstExprTempScope = struct {
    arena: std.heap.ArenaAllocator,

    fn init(backing_allocator: std.mem.Allocator) ConstExprTempScope {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    fn deinit(self: *ConstExprTempScope) void {
        self.arena.deinit();
    }

    fn allocator(self: *ConstExprTempScope) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn allocId(
        self: *ConstExprTempScope,
        interp: *Interpreter,
        kind: AllocKind,
    ) std.mem.Allocator.Error!AllocId {
        _ = self;
        return interp.allocation_store.alloc(interp.allocator, kind, interp.currentFunctionId());
    }
};

fn evaluateConstExpr(
    temp_scope: *ConstExprTempScope,
    interp: *Interpreter,
    expr: *const ast.Expr,
    mod_name: ?ast.StructName,
    interner: *const ast.StringInterner,
) AttrEvalInternalError!CtValue {
    if (interp.const_expr_depth >= interp.const_expr_recursion_limit) {
        try interp.emitError(.recursion_limit_exceeded, "constant expression recursion limit exceeded");
        return error.CtfeFailed;
    }
    interp.const_expr_depth += 1;
    defer interp.const_expr_depth -= 1;

    if (astLiteralToCtValue(expr, interner)) |lit| return lit;

    const alloc = temp_scope.allocator();
    return switch (expr.*) {
        .tuple => |t| blk: {
            const elems = alloc.alloc(CtValue, t.elements.len) catch return error.OutOfMemory;
            initCtValueSlots(elems);
            for (t.elements, 0..) |elem, i| {
                elems[i] = try evaluateConstExpr(temp_scope, interp, elem, mod_name, interner);
            }
            const alloc_id = try temp_scope.allocId(interp, .tuple);
            break :blk .{ .tuple = .{ .alloc_id = alloc_id, .elems = elems } };
        },
        .list => |l| blk: {
            const elems = alloc.alloc(CtValue, l.elements.len) catch return error.OutOfMemory;
            initCtValueSlots(elems);
            for (l.elements, 0..) |elem, i| {
                elems[i] = try evaluateConstExpr(temp_scope, interp, elem, mod_name, interner);
            }
            const alloc_id = try temp_scope.allocId(interp, .list);
            break :blk .{ .list = .{ .alloc_id = alloc_id, .elems = elems } };
        },
        .map => |m| blk: {
            const entries = alloc.alloc(CtValue.CtMapEntry, m.fields.len) catch return error.OutOfMemory;
            initCtMapEntries(entries);
            for (m.fields, 0..) |field, i| {
                entries[i].key = try evaluateConstExpr(temp_scope, interp, field.key, mod_name, interner);
                entries[i].value = try evaluateConstExpr(temp_scope, interp, field.value, mod_name, interner);
            }
            const alloc_id = try temp_scope.allocId(interp, .map);
            break :blk .{ .map = .{ .alloc_id = alloc_id, .entries = entries } };
        },
        .struct_expr => |s| blk: {
            if (s.update_source != null) return error.NotComputable;
            const fields = alloc.alloc(CtValue.CtFieldValue, s.fields.len) catch return error.OutOfMemory;
            initCtFieldValues(fields);
            const type_name = try structNameToString(alloc, s.struct_name, interner);
            for (s.fields, 0..) |field, i| {
                fields[i] = .{
                    .name = interner.get(field.name),
                    .value = try evaluateConstExpr(temp_scope, interp, field.value, mod_name, interner),
                };
            }
            const alloc_id = try temp_scope.allocId(interp, .struct_val);
            break :blk .{ .struct_val = .{ .alloc_id = alloc_id, .type_name = type_name, .fields = fields } };
        },
        .struct_ref => |s| blk: {
            const graph = interp.scope_graph orelse return error.NotComputable;
            if (!try isKnownTypeReference(alloc, graph, s.name, interner)) return error.NotComputable;
            const type_name = try structNameToString(alloc, s.name, interner);
            break :blk try buildTypeReferenceValue(temp_scope, interp, type_name);
        },
        .function_ref => |function_ref| blk: {
            const graph = interp.scope_graph orelse return error.NotComputable;
            const target_struct_name = function_ref.struct_name orelse (mod_name orelse return error.NotComputable);
            const target_scope = graph.findStructScope(target_struct_name) orelse return error.NotComputable;
            const narrowed_arity = narrowedFunctionArity(function_ref.arity);
            if (graph.resolveFamilyAllowingDefaults(target_scope, function_ref.function, narrowed_arity) == null) return error.NotComputable;
            const type_name = try structNameToString(alloc, target_struct_name, interner);
            break :blk try buildFunctionReferenceValue(temp_scope, interp, type_name, interner.get(function_ref.function), narrowed_arity);
        },
        .attr_ref => |ar| blk: {
            const graph = interp.scope_graph orelse return error.NotComputable;
            const current_struct = mod_name orelse return error.NotComputable;
            for (graph.structs.items) |mod_entry| {
                if (!std.meta.eql(mod_entry.name, current_struct)) continue;
                for (mod_entry.attributes.items) |attr| {
                    if (attr.name != ar.name) continue;
                    if (attr.computed_value) |cv| {
                        break :blk try importComputedConstValue(alloc, interp, cv);
                    }
                    return error.NotComputable;
                }
            }
            return error.NotComputable;
        },
        .binary_op => |b| try evaluateConstBinaryOp(temp_scope, interp, b, mod_name, interner),
        .unary_op => |u| try evaluateConstUnaryOp(temp_scope, interp, u, mod_name, interner),
        .type_annotated => |ta| try evaluateConstExpr(temp_scope, interp, ta.expr, mod_name, interner),
        .call => |call| blk: {
            const callee_name = (try resolveCalleeName(alloc, call.callee, mod_name, interner)) orelse
                return error.NotComputable;
            defer callee_name.deinit(alloc);

            const func_id = interp.function_by_name.get(callee_name.bytes) orelse
                return error.NotComputable;

            var ct_args: std.ArrayListUnmanaged(CtValue) = .empty;
            defer ct_args.deinit(alloc);
            for (call.args) |arg| {
                const arg_value = try evaluateConstExpr(temp_scope, interp, arg, mod_name, interner);
                try ct_args.append(alloc, arg_value);
            }

            interp.steps_remaining = interp.step_budget;
            const result = interp.evalFunction(func_id, ct_args.items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CtfeFailure => return error.CtfeFailed,
            };
            break :blk result;
        },
        else => error.NotComputable,
    };
}

fn evaluateConstBinaryOp(
    temp_scope: *ConstExprTempScope,
    interp: *Interpreter,
    op: ast.BinaryOp,
    mod_name: ?ast.StructName,
    interner: *const ast.StringInterner,
) AttrEvalInternalError!CtValue {
    const alloc = temp_scope.allocator();
    const lhs = try evaluateConstExpr(temp_scope, interp, op.lhs, mod_name, interner);
    const rhs = try evaluateConstExpr(temp_scope, interp, op.rhs, mod_name, interner);

    return switch (op.op) {
        .add => switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| .{ .int = a +% b },
                else => error.NotComputable,
            },
            .float => |a| switch (rhs) {
                .float => |b| .{ .float = a + b },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
        .sub => switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| .{ .int = a -% b },
                else => error.NotComputable,
            },
            .float => |a| switch (rhs) {
                .float => |b| .{ .float = a - b },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
        .mul => switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| .{ .int = a *% b },
                else => error.NotComputable,
            },
            .float => |a| switch (rhs) {
                .float => |b| .{ .float = a * b },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
        .div => switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| blk: {
                    // A zero divisor and the `minInt / -1` overflow corner are
                    // illegal behavior for raw `@divTrunc` (a compiler panic in
                    // safe builds); surface them as clean attribute-folding
                    // diagnostics instead, matching the IR-interpreter and
                    // runtime div/rem guards.
                    if (b == 0) {
                        try interp.emitError(.division_by_zero, "division by zero");
                        return error.CtfeFailed;
                    }
                    if (b == -1 and a == std.math.minInt(i64)) {
                        try interp.emitError(.arithmetic_overflow, "integer overflow in division (minInt / -1)");
                        return error.CtfeFailed;
                    }
                    break :blk .{ .int = @divTrunc(a, b) };
                },
                else => error.NotComputable,
            },
            .float => |a| switch (rhs) {
                .float => |b| blk: {
                    if (b == 0.0) {
                        try interp.emitError(.division_by_zero, "division by zero");
                        return error.CtfeFailed;
                    }
                    break :blk .{ .float = a / b };
                },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
        .rem_op => switch (lhs) {
            .int => |a| switch (rhs) {
                .int => |b| blk: {
                    if (b == 0) {
                        try interp.emitError(.division_by_zero, "remainder by zero");
                        return error.CtfeFailed;
                    }
                    if (b == -1 and a == std.math.minInt(i64)) {
                        try interp.emitError(.arithmetic_overflow, "integer overflow in remainder (minInt rem -1)");
                        return error.CtfeFailed;
                    }
                    break :blk .{ .int = @rem(a, b) };
                },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
        .equal => .{ .bool_val = lhs.eqlWithAllocator(alloc, rhs) catch |err| return attrTraversalFailure(interp, err) },
        .not_equal => .{ .bool_val = !(lhs.eqlWithAllocator(alloc, rhs) catch |err| return attrTraversalFailure(interp, err)) },
        .less => blk: {
            const ord = lhs.compare(rhs) orelse return error.NotComputable;
            break :blk .{ .bool_val = ord == .lt };
        },
        .greater => blk: {
            const ord = lhs.compare(rhs) orelse return error.NotComputable;
            break :blk .{ .bool_val = ord == .gt };
        },
        .less_equal => blk: {
            const ord = lhs.compare(rhs) orelse return error.NotComputable;
            break :blk .{ .bool_val = ord != .gt };
        },
        .greater_equal => blk: {
            const ord = lhs.compare(rhs) orelse return error.NotComputable;
            break :blk .{ .bool_val = ord != .lt };
        },
        .and_op => .{ .bool_val = lhs.isTruthy() and rhs.isTruthy() },
        .or_op => .{ .bool_val = lhs.isTruthy() or rhs.isTruthy() },
        .concat => switch (lhs) {
            .string => |a| switch (rhs) {
                .string => |b| blk: {
                    const result = alloc.alloc(u8, a.len + b.len) catch return error.OutOfMemory;
                    @memcpy(result[0..a.len], a);
                    @memcpy(result[a.len..], b);
                    break :blk .{ .string = result };
                },
                else => error.NotComputable,
            },
            .list => |a| switch (rhs) {
                .list => |b| blk: {
                    const result = alloc.alloc(CtValue, a.elems.len + b.elems.len) catch return error.OutOfMemory;
                    @memcpy(result[0..a.elems.len], a.elems);
                    @memcpy(result[a.elems.len..], b.elems);
                    const alloc_id = try temp_scope.allocId(interp, .list);
                    break :blk .{ .list = .{ .alloc_id = alloc_id, .elems = result } };
                },
                else => error.NotComputable,
            },
            else => error.NotComputable,
        },
        .in_op => switch (rhs) {
            .list => |list| blk: {
                for (list.elems) |elem| {
                    if (lhs.eqlWithAllocator(alloc, elem) catch |err| return attrTraversalFailure(interp, err)) break :blk .{ .bool_val = true };
                }
                break :blk .{ .bool_val = false };
            },
            else => error.NotComputable,
        },
        .not_in_op => switch (rhs) {
            .list => |list| blk: {
                for (list.elems) |elem| {
                    if (lhs.eqlWithAllocator(alloc, elem) catch |err| return attrTraversalFailure(interp, err)) break :blk .{ .bool_val = false };
                }
                break :blk .{ .bool_val = true };
            },
            else => error.NotComputable,
        },
    };
}

fn evaluateConstUnaryOp(
    temp_scope: *ConstExprTempScope,
    interp: *Interpreter,
    op: ast.UnaryOp,
    mod_name: ?ast.StructName,
    interner: *const ast.StringInterner,
) AttrEvalInternalError!CtValue {
    const operand = try evaluateConstExpr(temp_scope, interp, op.operand, mod_name, interner);
    return switch (op.op) {
        .negate => switch (operand) {
            .int => |v| .{ .int = -%v },
            .float => |v| .{ .float = -v },
            else => error.NotComputable,
        },
        .not_op => .{ .bool_val = !operand.isTruthy() },
    };
}

const AttrEvalInternalError = error{
    NotComputable,
    CtfeFailed,
    OutOfMemory,
};

fn attrTraversalFailure(interp: *Interpreter, err: ValueTraversalError) AttrEvalInternalError {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ValueTraversalDepthExceeded => {
            interp.emitError(.value_traversal_limit_exceeded, "compile-time value traversal depth exceeded") catch return error.OutOfMemory;
            return error.CtfeFailed;
        },
        error.ValueTraversalBudgetExceeded => {
            interp.emitError(.value_traversal_limit_exceeded, "compile-time value traversal budget exceeded") catch return error.OutOfMemory;
            return error.CtfeFailed;
        },
    }
}

/// Resolve a callee AST expression to a mangled IR function name.
/// Handles: bare `func()` and `Struct.func()` forms.
fn resolveCalleeName(
    alloc: std.mem.Allocator,
    callee: *const ast.Expr,
    mod_name: ?ast.StructName,
    interner: *const ast.StringInterner,
) std.mem.Allocator.Error!?ResolvedCalleeName {
    switch (callee.*) {
        // Bare call: func() → Struct__func
        .var_ref => |vr| {
            const func_name = interner.get(vr.name);
            if (mod_name) |mn| {
                const prefix = try structNameToPrefix(alloc, mn, interner);
                defer prefix.deinit(alloc);
                return .{
                    .bytes = try std.fmt.allocPrint(alloc, "{s}__{s}", .{ prefix.bytes, func_name }),
                    .owned = true,
                };
            }
            return .{ .bytes = func_name, .owned = false };
        },
        // Qualified call: Struct.func() → Struct__func
        .field_access => |fa| {
            // object should be a struct_ref or var_ref
            const field_name = interner.get(fa.field);
            switch (fa.object.*) {
                .struct_ref => |mr| {
                    const prefix = try structNameToPrefix(alloc, mr.name, interner);
                    defer prefix.deinit(alloc);
                    return .{
                        .bytes = try std.fmt.allocPrint(alloc, "{s}__{s}", .{ prefix.bytes, field_name }),
                        .owned = true,
                    };
                },
                .var_ref => |vr| {
                    const obj_name = interner.get(vr.name);
                    return .{
                        .bytes = try std.fmt.allocPrint(alloc, "{s}__{s}", .{ obj_name, field_name }),
                        .owned = true,
                    };
                },
                else => return null,
            }
        },
        else => return null,
    }
}

const ResolvedCalleeName = struct {
    bytes: []const u8,
    owned: bool,

    fn deinit(self: ResolvedCalleeName, alloc: std.mem.Allocator) void {
        if (self.owned) alloc.free(self.bytes);
    }
};

const StructNamePrefix = struct {
    bytes: []const u8,
    owned: bool,

    fn deinit(self: StructNamePrefix, alloc: std.mem.Allocator) void {
        if (self.owned) alloc.free(self.bytes);
    }
};

/// Convert an ast.StructName to a prefix string, matching IR builder convention.
/// Single-part: "IO". Multi-part: "IO_File".
fn structNameToPrefix(
    alloc: std.mem.Allocator,
    name: ast.StructName,
    interner: *const ast.StringInterner,
) std.mem.Allocator.Error!StructNamePrefix {
    if (name.parts.len == 1) {
        return .{ .bytes = interner.get(name.parts[0]), .owned = false };
    }
    return .{ .bytes = try name.joinedWith(alloc, interner, "_"), .owned = true };
}

fn structNameToString(
    alloc: std.mem.Allocator,
    name: ast.StructName,
    interner: *const ast.StringInterner,
) ![]const u8 {
    return name.toDottedString(alloc, interner);
}

fn narrowedFunctionArity(raw_arity: u32) u8 {
    return @as(u8, @truncate(raw_arity));
}

fn buildTypeReferenceValue(
    temp_scope: *ConstExprTempScope,
    interp: *Interpreter,
    type_name: []const u8,
) !CtValue {
    const alloc = temp_scope.allocator();
    const fields = try alloc.alloc(CtValue.CtFieldValue, 1);
    fields[0] = .{
        .name = "name",
        .value = .{ .atom = type_name },
    };
    const alloc_id = try temp_scope.allocId(interp, .struct_val);
    return .{ .struct_val = .{
        .alloc_id = alloc_id,
        .type_name = "Type",
        .fields = fields,
    } };
}

fn buildFunctionReferenceValue(
    temp_scope: *ConstExprTempScope,
    interp: *Interpreter,
    type_name: []const u8,
    function_name: []const u8,
    arity: u8,
) !CtValue {
    const alloc = temp_scope.allocator();
    const fields = try alloc.alloc(CtValue.CtFieldValue, 3);
    fields[0] = .{
        .name = "struct",
        .value = try buildTypeReferenceValue(temp_scope, interp, type_name),
    };
    fields[1] = .{
        .name = "name",
        .value = .{ .atom = function_name },
    };
    fields[2] = .{
        .name = "arity",
        .value = .{ .int = arity },
    };
    const alloc_id = try temp_scope.allocId(interp, .struct_val);
    return .{ .struct_val = .{
        .alloc_id = alloc_id,
        .type_name = "Function",
        .fields = fields,
    } };
}

fn isKnownTypeReference(
    alloc: std.mem.Allocator,
    graph: *const scope.ScopeGraph,
    name: ast.StructName,
    interner: *const ast.StringInterner,
) !bool {
    if (name.parts.len == 1 and isBuiltinTypeReferenceName(interner.get(name.parts[0]))) return true;
    if (graph.findStructScope(name) != null) return true;

    const dotted_name = try structNameToString(alloc, name, interner);
    defer alloc.free(dotted_name);
    for (graph.types.items) |type_entry| {
        if (std.mem.eql(u8, interner.get(type_entry.name), dotted_name)) return true;
    }
    return false;
}

fn isBuiltinTypeReferenceName(name: []const u8) bool {
    const builtins = [_][]const u8{
        "Term",
        "Bool",
        "String",
        "Atom",
        "Nil",
        "Void",
        "Never",
        "i128",
        "i64",
        "i32",
        "i16",
        "i8",
        "u128",
        "u64",
        "u32",
        "u16",
        "u8",
        "f128",
        "f80",
        "f64",
        "f32",
        "f16",
        "usize",
        "isize",
    };
    for (&builtins) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return false;
}

fn structNamesEqual(left: ast.StructName, right: ast.StructName) bool {
    if (left.parts.len != right.parts.len) return false;
    for (left.parts, right.parts) |left_part, right_part| {
        if (left_part != right_part) return false;
    }
    return true;
}

/// Find the enclosing struct name for a scope, walking up the scope tree.
fn findStructForScope(graph: *const scope.ScopeGraph, scope_id: scope.ScopeId) ?ast.StructName {
    // Check if this scope directly belongs to a struct
    for (graph.structs.items) |mod_entry| {
        if (mod_entry.scope_id == scope_id) return mod_entry.name;
    }
    // Walk up parent scopes
    const s = graph.getScope(scope_id);
    if (s.parent) |parent_id| {
        return findStructForScope(graph, parent_id);
    }
    return null;
}

fn findStructScopeByNameForCache(
    graph: *const scope.ScopeGraph,
    interner: *const ast.StringInterner,
    struct_name: []const u8,
) ?scope.ScopeId {
    for (graph.structs.items) |mod_entry| {
        if (structNameMatchesStr(mod_entry.name, struct_name, interner)) {
            return mod_entry.scope_id;
        }
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn makeTestProgram(functions: []const ir.Function) ir.Program {
    return .{
        .functions = functions,
        .type_defs = &.{},
        .entry = null,
    };
}

test "Interpreter.init propagates OOM while populating function name index" {
    const function = ir.Function{
        .id = 42,
        .name = "indexed_function",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{},
        .is_closure = false,
        .captures = &.{},
        .local_count = 0,
    };
    const functions = [_]ir.Function{function};
    const program = makeTestProgram(&functions);

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, Interpreter.init(failing_allocator.allocator(), &program));
    try testing.expect(failing_allocator.has_induced_failure);
}

test "AllocationStore.alloc propagates OOM without reserving an id" {
    var allocation_store = AllocationStore{};
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    try testing.expectError(error.OutOfMemory, allocation_store.alloc(failing_allocator.allocator(), .list, null));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(u32, 0), allocation_store.count());
}

fn reserveAllocationStoreCapacity(
    alloc: std.mem.Allocator,
    allocation_store: *AllocationStore,
    capacity: usize,
) !void {
    std.debug.assert(allocation_store.records.items.len == 0);
    std.debug.assert(allocation_store.records.capacity == 0);
    allocation_store.records = try std.ArrayListUnmanaged(AllocationRecord).initCapacity(alloc, capacity);
}

test "P4J2: interpreter list concat frees result buffer when allocation store fails" {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const lhs_elems = [_]CtValue{.{ .int = 1 }};
    const rhs_elems = [_]CtValue{.{ .int = 2 }};
    const lhs = CtValue{ .list = .{ .alloc_id = 1, .elems = &lhs_elems } };
    const rhs = CtValue{ .list = .{ .alloc_id = 2, .elems = &rhs_elems } };

    failing_allocator.fail_index = failing_allocator.alloc_index + 1;

    try testing.expectError(error.OutOfMemory, interp.evalConcat(lhs, rhs));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(u32, 0), interp.allocation_store.count());
}

test "P4J2: constant-expression list concat frees payloads when allocation store fails" {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    try reserveAllocationStoreCapacity(alloc, &interp.allocation_store, 2);

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    interp.interner = &interner;

    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };
    const lhs = ast.Expr{ .int_literal = .{ .meta = meta, .value = 1 } };
    const rhs = ast.Expr{ .int_literal = .{ .meta = meta, .value = 2 } };
    const lhs_elements = [_]*const ast.Expr{&lhs};
    const rhs_elements = [_]*const ast.Expr{&rhs};
    const lhs_list = ast.Expr{ .list = .{ .meta = meta, .elements = &lhs_elements } };
    const rhs_list = ast.Expr{ .list = .{ .meta = meta, .elements = &rhs_elements } };
    const op = ast.BinaryOp{
        .meta = meta,
        .op = .concat,
        .lhs = &lhs_list,
        .rhs = &rhs_list,
    };

    var temp_scope = ConstExprTempScope.init(testing.allocator);
    defer temp_scope.deinit();
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try testing.expectError(error.OutOfMemory, evaluateConstBinaryOp(&temp_scope, &interp, op, null, &interner));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 2), interp.allocation_store.records.items.len);
}

test "P4J2: type reference builder frees fields when allocation store fails" {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    var temp_scope = ConstExprTempScope.init(testing.allocator);
    defer temp_scope.deinit();
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try testing.expectError(error.OutOfMemory, buildTypeReferenceValue(&temp_scope, &interp, "App"));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(u32, 0), interp.allocation_store.count());
}

test "P4J2: function reference builder frees nested type when allocation store fails" {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    try reserveAllocationStoreCapacity(alloc, &interp.allocation_store, 2);
    interp.allocation_store.records.appendAssumeCapacity(.{
        .id = 1,
        .kind = .list,
        .source_function = null,
    });
    interp.allocation_store.next_id = 2;

    var temp_scope = ConstExprTempScope.init(testing.allocator);
    defer temp_scope.deinit();
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try testing.expectError(
        error.OutOfMemory,
        buildFunctionReferenceValue(&temp_scope, &interp, "App", "run", 0),
    );
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 2), interp.allocation_store.records.items.len);
}

test "P4J2: computed attribute export releases temporary aggregate value" {
    const alloc = testing.allocator;

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);

    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    const struct_scope = try graph.createScope(0, .struct_scope);

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const app_id = try interner.intern("App");
    const config_id = try interner.intern("config");

    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const app_name = ast.StructName{ .parts = &.{app_id}, .span = span };
    var app_decl = ast.StructDecl{
        .meta = .{ .span = span },
        .name = app_name,
        .items = &.{},
    };
    try graph.registerStruct(app_name, struct_scope, &app_decl);

    var first_expr = ast.Expr{ .int_literal = .{
        .meta = .{ .span = span },
        .value = 1,
    } };
    var second_expr = ast.Expr{ .int_literal = .{
        .meta = .{ .span = span },
        .value = 2,
    } };
    const list_elements = [_]*const ast.Expr{ &first_expr, &second_expr };
    var list_expr = ast.Expr{ .list = .{
        .meta = .{ .span = span },
        .elements = &list_elements,
    } };
    try graph.structs.items[0].attributes.append(alloc, .{
        .name = config_id,
        .value = &list_expr,
    });

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    defer deinitClonedCtfeErrors(alloc, result.errors);

    try testing.expectEqual(@as(u32, 1), result.evaluated);
    try testing.expectEqual(@as(u32, 0), result.failed);
    try testing.expect(graph.structs.items[0].attributes.items[0].computed_value.? == .list);
}

test "P4J2: type reference builder frees owned name when allocation store fails" {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    var temp_scope = ConstExprTempScope.init(testing.allocator);
    defer temp_scope.deinit();
    const owned_type_name = try temp_scope.allocator().dupe(u8, "App");
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try testing.expectError(error.OutOfMemory, buildTypeReferenceValue(&temp_scope, &interp, owned_type_name));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(u32, 0), interp.allocation_store.count());
}

test "P4J2: function reference builder frees owned name when parent allocation store fails" {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    try reserveAllocationStoreCapacity(alloc, &interp.allocation_store, 1);

    var temp_scope = ConstExprTempScope.init(testing.allocator);
    defer temp_scope.deinit();
    const owned_type_name = try temp_scope.allocator().dupe(u8, "App");
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try testing.expectError(
        error.OutOfMemory,
        buildFunctionReferenceValue(&temp_scope, &interp, owned_type_name, "run", 0),
    );
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 1), interp.allocation_store.records.items.len);
}

test "P4J2: isKnownTypeReference frees dotted name on registered type match and miss" {
    const alloc = testing.allocator;

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const outer_id = try interner.intern("Outer");
    const inner_id = try interner.intern("Inner");
    const dotted_id = try interner.intern("Outer.Inner");
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const struct_name = ast.StructName{ .parts = &.{ outer_id, inner_id }, .span = span };

    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();
    const type_scope = try graph.createScope(0, .struct_scope);
    const dummy_type_expr = ast.TypeExpr{ .never = .{ .meta = .{ .span = span } } };
    _ = try graph.registerType(dotted_id, type_scope, .{ .type_alias = &dummy_type_expr }, &.{});

    try testing.expect(try isKnownTypeReference(alloc, &graph, struct_name, &interner));

    var miss_graph = try scope.ScopeGraph.init(alloc);
    defer miss_graph.deinit();
    try testing.expect(!try isKnownTypeReference(alloc, &miss_graph, struct_name, &interner));
}

test "P4J2: isKnownTypeReference propagates dotted name allocation failure" {
    const alloc = testing.allocator;

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const outer_id = try interner.intern("Outer");
    const inner_id = try interner.intern("Inner");
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const struct_name = ast.StructName{ .parts = &.{ outer_id, inner_id }, .span = span };

    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        isKnownTypeReference(failing_allocator.allocator(), &graph, struct_name, &interner),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

// ============================================================
// Persistent CTFE Cache
// ============================================================

pub const PersistentCache = struct {
    cache_dir: []const u8,

    pub const LoadError = error{
        OutOfMemory,
        HostIoFailure,
        ReadFailure,
        CorruptEntry,
    };

    pub const StoreError = error{
        OutOfMemory,
        HostIoFailure,
        SerializationFailure,
        ValueTraversalDepthExceeded,
        ValueTraversalBudgetExceeded,
    };

    pub fn init(cache_dir: []const u8) PersistentCache {
        return .{ .cache_dir = cache_dir };
    }

    /// Generate a cache key for a function evaluation.
    pub fn cacheKeyFor(function_name: []const u8, function_hash: u64, args_hash: u64, capability_flags: u8, options_hash: u64) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(function_name);
        hasher.update(std.mem.asBytes(&function_hash));
        hasher.update(std.mem.asBytes(&args_hash));
        hasher.update(&[_]u8{capability_flags});
        hasher.update(std.mem.asBytes(&options_hash));
        hasher.update("ctfe_v2"); // schema version
        return hasher.final();
    }

    fn entryPath(self: *const PersistentCache, alloc: std.mem.Allocator, key: u64) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(alloc, "{s}/{x:0>16}.ctfe", .{ self.cache_dir, key });
    }

    fn mapLoadReadError(err: std.Io.Dir.ReadFileAllocError) LoadError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ConnectionResetByPeer,
            error.FileTooBig,
            error.InputOutput,
            error.IsDir,
            error.NotOpenForReading,
            error.SocketUnconnected,
            error.StreamTooLong,
            => error.ReadFailure,
            else => error.HostIoFailure,
        };
    }

    fn mapDeserializeError(err: DeserializeError) LoadError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TrailingData,
            error.UnexpectedEndOfData,
            error.ValueTraversalDepthExceeded,
            error.ValueTraversalBudgetExceeded,
            => error.CorruptEntry,
        };
    }

    fn mapSerializeError(err: SerializeError) StoreError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ValueTraversalDepthExceeded,
            error.ValueTraversalBudgetExceeded,
            => |traversal_err| traversal_err,
            error.UnexpectedEndOfData => error.SerializationFailure,
        };
    }

    fn mapStoreWriteError(err: anyerror) StoreError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.HostIoFailure,
        };
    }

    /// Try to load a cached result. Returns null only when the entry is absent.
    pub fn load(self: *const PersistentCache, alloc: std.mem.Allocator, key: u64) LoadError!?CtEvalResult {
        const path = try self.entryPath(alloc, key);
        defer alloc.free(path);

        const data = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, alloc, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |read_err| return mapLoadReadError(read_err),
        };
        defer alloc.free(data);

        return deserializeResult(alloc, data) catch |err| return mapDeserializeError(err);
    }

    /// Store a result in the persistent cache.
    pub fn store(self: *const PersistentCache, alloc: std.mem.Allocator, key: u64, result: CtEvalResult) StoreError!void {
        return self.storeWithFileWriter(alloc, key, result, PersistentCacheFileWriter{});
    }

    fn storeWithFileWriter(
        self: *const PersistentCache,
        alloc: std.mem.Allocator,
        key: u64,
        result: CtEvalResult,
        file_writer: anytype,
    ) StoreError!void {
        const path = try self.entryPath(alloc, key);
        defer alloc.free(path);

        const data = serializeResult(alloc, result) catch |err| return mapSerializeError(err);
        defer alloc.free(data);

        file_writer.writeFileAtomic(alloc, path, data) catch |err| return mapStoreWriteError(err);
    }

    const PersistentCacheFileWriter = struct {
        fn writeFileAtomic(
            _: PersistentCacheFileWriter,
            alloc: std.mem.Allocator,
            path: []const u8,
            contents: []const u8,
        ) !void {
            try build_cache.writeFileAtomic(alloc, path, contents);
        }
    };

    fn readFileDependencyContent(alloc: std.mem.Allocator, path: []const u8) DependencyValidationError!?[]u8 {
        return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, alloc, .limited(10 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound,
            error.NotDir,
            error.IsDir,
            => return null,
            else => |validation_err| return validation_err,
        };
    }

    /// Validate that all dependencies in a cached result are still current.
    pub fn validateDependencies(
        alloc: std.mem.Allocator,
        deps: []const CtDependency,
        graph: ?*const scope.ScopeGraph,
        interner: ?*const ast.StringInterner,
    ) DependencyValidationError!bool {
        for (deps) |dep| {
            switch (dep) {
                .file => |f| {
                    const content = (try readFileDependencyContent(alloc, f.path)) orelse return false;
                    defer alloc.free(content);
                    const current_hash = std.hash.Wyhash.hash(0, content);
                    if (current_hash != f.content_hash) return false;
                },
                .env_var => |ev| {
                    const current = env.getenvRuntime(ev.name);
                    if (ev.present and current == null) return false;
                    if (!ev.present and current != null) return false;
                    if (current) |v| {
                        const current_hash = std.hash.Wyhash.hash(0, v);
                        if (current_hash != ev.value_hash) return false;
                    }
                },
                .glob => |g| {
                    const matches = try glob.collect(alloc, std.Options.debug_io, g.pattern, .{});
                    defer glob.freeMatches(alloc, matches);
                    const current_hash = hashGlobMatches(matches);
                    if (current_hash != g.result_hash) return false;
                },
                .reflected_struct => |rm| {
                    const current_graph = graph orelse return false;
                    const current_interner = interner orelse return false;
                    const mod_scope_id = findStructScopeByNameForCache(current_graph, current_interner, rm.struct_name) orelse return false;
                    const current_hash = computeStructInterfaceHash(alloc, current_graph, mod_scope_id, current_interner, rm.struct_name) catch |err| switch (err) {
                        error.OutOfMemory,
                        error.ValueTraversalDepthExceeded,
                        error.ValueTraversalBudgetExceeded,
                        => |validation_err| return validation_err,
                    };
                    if (current_hash != rm.interface_hash) return false;
                },
                .reflected_source => |rs| {
                    const current_graph = graph orelse return false;
                    const current_interner = interner orelse return false;
                    const current_hash = try computeSourceReflectionHash(alloc, current_graph, current_interner, rs.paths);
                    if (current_hash != rs.graph_hash) return false;
                },
            }
        }
        return true;
    }
};

// Tag bytes for ConstValue serialization
const CONST_TAG_INT: u8 = 1;
const CONST_TAG_FLOAT: u8 = 2;
const CONST_TAG_STRING: u8 = 3;
const CONST_TAG_BOOL: u8 = 4;
const CONST_TAG_ATOM: u8 = 5;
const CONST_TAG_NIL: u8 = 6;
const CONST_TAG_VOID: u8 = 7;
const CONST_TAG_TUPLE: u8 = 8;
const CONST_TAG_LIST: u8 = 9;
const CONST_TAG_MAP: u8 = 10;
const CONST_TAG_STRUCT: u8 = 11;

// Dependency serialization tags
const DEP_TAG_FILE: u8 = 1;
const DEP_TAG_ENV_VAR: u8 = 2;
const DEP_TAG_REFLECTED_STRUCT: u8 = 3;
const DEP_TAG_REFLECTED_SOURCE: u8 = 4;
const DEP_TAG_GLOB: u8 = 5;

fn serializeDependencyInto(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), dep: CtDependency) !void {
    switch (dep) {
        .file => |f| {
            try buf.append(alloc, DEP_TAG_FILE);
            const path_len: u32 = @intCast(f.path.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&path_len));
            try buf.appendSlice(alloc, f.path);
            try buf.appendSlice(alloc, std.mem.asBytes(&f.content_hash));
        },
        .env_var => |ev| {
            try buf.append(alloc, DEP_TAG_ENV_VAR);
            const name_len: u32 = @intCast(ev.name.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&name_len));
            try buf.appendSlice(alloc, ev.name);
            try buf.appendSlice(alloc, std.mem.asBytes(&ev.value_hash));
            try buf.append(alloc, @intFromBool(ev.present));
        },
        .glob => |g| {
            try buf.append(alloc, DEP_TAG_GLOB);
            const pattern_len: u32 = @intCast(g.pattern.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&pattern_len));
            try buf.appendSlice(alloc, g.pattern);
            try buf.appendSlice(alloc, std.mem.asBytes(&g.result_hash));
        },
        .reflected_struct => |rm| {
            try buf.append(alloc, DEP_TAG_REFLECTED_STRUCT);
            const name_len: u32 = @intCast(rm.struct_name.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&name_len));
            try buf.appendSlice(alloc, rm.struct_name);
            try buf.appendSlice(alloc, std.mem.asBytes(&rm.interface_hash));
        },
        .reflected_source => |rs| {
            try buf.append(alloc, DEP_TAG_REFLECTED_SOURCE);
            const path_count: u32 = @intCast(rs.paths.len);
            try buf.appendSlice(alloc, std.mem.asBytes(&path_count));
            for (rs.paths) |path| {
                const path_len: u32 = @intCast(path.len);
                try buf.appendSlice(alloc, std.mem.asBytes(&path_len));
                try buf.appendSlice(alloc, path);
            }
            try buf.appendSlice(alloc, std.mem.asBytes(&rs.graph_hash));
        },
    }
}

fn deserializeDependency(alloc: std.mem.Allocator, data: []const u8, pos: *usize) SerializeError!CtDependency {
    if (pos.* >= data.len) return error.UnexpectedEndOfData;
    const tag = data[pos.*];
    pos.* += 1;

    return switch (tag) {
        DEP_TAG_FILE => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const path_len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            if (pos.* + path_len > data.len) return error.UnexpectedEndOfData;
            const path = try alloc.dupe(u8, data[pos.*..][0..path_len]);
            errdefer alloc.free(path);
            pos.* += path_len;
            if (pos.* + 8 > data.len) return error.UnexpectedEndOfData;
            const content_hash = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .file = .{ .path = path, .content_hash = content_hash } };
        },
        DEP_TAG_ENV_VAR => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const name_len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            if (pos.* + name_len > data.len) return error.UnexpectedEndOfData;
            const name = try alloc.dupe(u8, data[pos.*..][0..name_len]);
            errdefer alloc.free(name);
            pos.* += name_len;
            if (pos.* + 9 > data.len) return error.UnexpectedEndOfData;
            const value_hash = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            const present = data[pos.*] != 0;
            pos.* += 1;
            return .{ .env_var = .{ .name = name, .value_hash = value_hash, .present = present } };
        },
        DEP_TAG_GLOB => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const pattern_len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            if (pos.* + pattern_len > data.len) return error.UnexpectedEndOfData;
            const pattern = try alloc.dupe(u8, data[pos.*..][0..pattern_len]);
            errdefer alloc.free(pattern);
            pos.* += pattern_len;
            if (pos.* + 8 > data.len) return error.UnexpectedEndOfData;
            const result_hash = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .glob = .{ .pattern = pattern, .result_hash = result_hash } };
        },
        DEP_TAG_REFLECTED_STRUCT => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const name_len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            if (pos.* + name_len > data.len) return error.UnexpectedEndOfData;
            const struct_name = try alloc.dupe(u8, data[pos.*..][0..name_len]);
            errdefer alloc.free(struct_name);
            pos.* += name_len;
            if (pos.* + 8 > data.len) return error.UnexpectedEndOfData;
            const interface_hash = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .reflected_struct = .{ .struct_name = struct_name, .interface_hash = interface_hash } };
        },
        DEP_TAG_REFLECTED_SOURCE => {
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            const path_count = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const paths = try alloc.alloc([]const u8, path_count);
            var initialized_path_count: usize = 0;
            errdefer {
                for (paths[0..initialized_path_count]) |path| {
                    alloc.free(path);
                }
                alloc.free(paths);
            }
            for (paths) |*path_slot| {
                if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
                const path_len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
                pos.* += 4;
                if (pos.* + path_len > data.len) return error.UnexpectedEndOfData;
                path_slot.* = try alloc.dupe(u8, data[pos.*..][0..path_len]);
                initialized_path_count += 1;
                pos.* += path_len;
            }
            if (pos.* + 8 > data.len) return error.UnexpectedEndOfData;
            const graph_hash = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .reflected_source = .{ .paths = paths, .graph_hash = graph_hash } };
        },
        else => return error.UnexpectedEndOfData,
    };
}

fn appendSerializedLength(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), len: usize) SerializeError!void {
    if (len > std.math.maxInt(u32)) return error.ValueTraversalBudgetExceeded;
    const serialized_len: u32 = @intCast(len);
    try buf.appendSlice(alloc, std.mem.asBytes(&serialized_len));
}

fn appendLengthPrefixedBytes(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), bytes: []const u8) SerializeError!void {
    try appendSerializedLength(alloc, buf, bytes.len);
    try buf.appendSlice(alloc, bytes);
}

fn ensureDeserializeAvailable(data: []const u8, pos: usize, len: usize) SerializeError!void {
    if (pos > data.len or len > data.len - pos) return error.UnexpectedEndOfData;
}

fn readSerializedU32(data: []const u8, pos: *usize) SerializeError!u32 {
    try ensureDeserializeAvailable(data, pos.*, 4);
    const value = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return value;
}

fn readSerializedBytes(alloc: std.mem.Allocator, data: []const u8, pos: *usize, len: usize) SerializeError![]const u8 {
    try ensureDeserializeAvailable(data, pos.*, len);
    const bytes = try alloc.dupe(u8, data[pos.*..][0..len]);
    pos.* += len;
    return bytes;
}

fn serializeConstValue(alloc: std.mem.Allocator, val: ConstValue) SerializeError![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    try serializeConstValueInto(alloc, &buf, val);
    return buf.toOwnedSlice(alloc);
}

fn serializeConstValueInto(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), val: ConstValue) SerializeError!void {
    const SerializeValueFrame = struct {
        value: ConstValue,
        depth: usize,
    };
    const SerializeFrame = union(enum) {
        value: SerializeValueFrame,
        field_name: []const u8,
    };

    var budget = ValueTraversalBudget{};
    var stack = InlineTraversalStack(SerializeFrame){};
    defer stack.deinit(alloc);

    try stack.push(alloc, .{ .value = .{ .value = val, .depth = 1 } });

    while (stack.pop()) |frame| {
        switch (frame) {
            .field_name => |name| try appendLengthPrefixedBytes(alloc, buf, name),
            .value => |value_frame| {
                try budget.visit(value_frame.depth);
                switch (value_frame.value) {
                    .int => |value| {
                        try buf.append(alloc, CONST_TAG_INT);
                        try buf.appendSlice(alloc, std.mem.asBytes(&value));
                    },
                    .float => |value| {
                        try buf.append(alloc, CONST_TAG_FLOAT);
                        try buf.appendSlice(alloc, std.mem.asBytes(&value));
                    },
                    .string => |value| {
                        try buf.append(alloc, CONST_TAG_STRING);
                        try appendLengthPrefixedBytes(alloc, buf, value);
                    },
                    .bool_val => |value| {
                        try buf.append(alloc, CONST_TAG_BOOL);
                        try buf.append(alloc, @intFromBool(value));
                    },
                    .atom => |value| {
                        try buf.append(alloc, CONST_TAG_ATOM);
                        try appendLengthPrefixedBytes(alloc, buf, value);
                    },
                    .nil => try buf.append(alloc, CONST_TAG_NIL),
                    .void => try buf.append(alloc, CONST_TAG_VOID),
                    .tuple => |elems| {
                        try budget.ensureChildren(value_frame.depth, elems.len);
                        try buf.append(alloc, CONST_TAG_TUPLE);
                        try appendSerializedLength(alloc, buf, elems.len);
                        var index = elems.len;
                        while (index > 0) {
                            index -= 1;
                            try stack.push(alloc, .{ .value = .{
                                .value = elems[index],
                                .depth = value_frame.depth + 1,
                            } });
                        }
                    },
                    .list => |elems| {
                        try budget.ensureChildren(value_frame.depth, elems.len);
                        try buf.append(alloc, CONST_TAG_LIST);
                        try appendSerializedLength(alloc, buf, elems.len);
                        var index = elems.len;
                        while (index > 0) {
                            index -= 1;
                            try stack.push(alloc, .{ .value = .{
                                .value = elems[index],
                                .depth = value_frame.depth + 1,
                            } });
                        }
                    },
                    .map => |entries| {
                        try budget.ensureChildren(value_frame.depth, try checkedChildCount(entries.len, 2));
                        try buf.append(alloc, CONST_TAG_MAP);
                        try appendSerializedLength(alloc, buf, entries.len);
                        var index = entries.len;
                        while (index > 0) {
                            index -= 1;
                            try stack.push(alloc, .{ .value = .{ .value = entries[index].value, .depth = value_frame.depth + 1 } });
                            try stack.push(alloc, .{ .value = .{ .value = entries[index].key, .depth = value_frame.depth + 1 } });
                        }
                    },
                    .struct_val => |struct_value| {
                        try budget.ensureChildren(value_frame.depth, struct_value.fields.len);
                        try buf.append(alloc, CONST_TAG_STRUCT);
                        try appendLengthPrefixedBytes(alloc, buf, struct_value.type_name);
                        try appendSerializedLength(alloc, buf, struct_value.fields.len);
                        var index = struct_value.fields.len;
                        while (index > 0) {
                            index -= 1;
                            try stack.push(alloc, .{ .value = .{
                                .value = struct_value.fields[index].value,
                                .depth = value_frame.depth + 1,
                            } });
                            try stack.push(alloc, .{ .field_name = struct_value.fields[index].name });
                        }
                    },
                }
            },
        }
    }
}

fn deserializeConstValue(alloc: std.mem.Allocator, data: []const u8, pos: *usize) SerializeError!ConstValue {
    const DeserializeValueFrame = struct {
        dest: *ConstValue,
        depth: usize,
        is_root: bool = false,
    };
    const DeserializeStructFieldFrame = struct {
        fields: []ConstValue.ConstFieldValue,
        index: usize,
        depth: usize,
    };
    const DeserializeFrame = union(enum) {
        value: DeserializeValueFrame,
        struct_field: DeserializeStructFieldFrame,
    };

    var budget = ValueTraversalBudget{};
    var stack = InlineTraversalStack(DeserializeFrame){};
    defer stack.deinit(alloc);

    var result: ConstValue = .void;
    var result_initialized = false;
    errdefer if (result_initialized) deinitConstValue(alloc, result);
    try stack.push(alloc, .{ .value = .{ .dest = &result, .depth = 1, .is_root = true } });

    while (stack.pop()) |frame| {
        switch (frame) {
            .value => |value_frame| {
                try budget.visit(value_frame.depth);
                try ensureDeserializeAvailable(data, pos.*, 1);
                const tag = data[pos.*];
                pos.* += 1;

                switch (tag) {
                    CONST_TAG_INT => {
                        try ensureDeserializeAvailable(data, pos.*, 8);
                        const value = std.mem.readInt(i64, data[pos.*..][0..8], .little);
                        pos.* += 8;
                        value_frame.dest.* = .{ .int = value };
                        if (value_frame.is_root) result_initialized = true;
                    },
                    CONST_TAG_FLOAT => {
                        try ensureDeserializeAvailable(data, pos.*, 8);
                        const value: f64 = @bitCast(std.mem.readInt(u64, data[pos.*..][0..8], .little));
                        pos.* += 8;
                        value_frame.dest.* = .{ .float = value };
                        if (value_frame.is_root) result_initialized = true;
                    },
                    CONST_TAG_STRING => {
                        const len: usize = try readSerializedU32(data, pos);
                        value_frame.dest.* = .{ .string = try readSerializedBytes(alloc, data, pos, len) };
                        if (value_frame.is_root) result_initialized = true;
                    },
                    CONST_TAG_BOOL => {
                        try ensureDeserializeAvailable(data, pos.*, 1);
                        const value = data[pos.*] != 0;
                        pos.* += 1;
                        value_frame.dest.* = .{ .bool_val = value };
                        if (value_frame.is_root) result_initialized = true;
                    },
                    CONST_TAG_ATOM => {
                        const len: usize = try readSerializedU32(data, pos);
                        value_frame.dest.* = .{ .atom = try readSerializedBytes(alloc, data, pos, len) };
                        if (value_frame.is_root) result_initialized = true;
                    },
                    CONST_TAG_NIL => {
                        value_frame.dest.* = .nil;
                        if (value_frame.is_root) result_initialized = true;
                    },
                    CONST_TAG_VOID => {
                        value_frame.dest.* = .void;
                        if (value_frame.is_root) result_initialized = true;
                    },
                    CONST_TAG_TUPLE => {
                        const len: usize = try readSerializedU32(data, pos);
                        try budget.ensureChildren(value_frame.depth, len);
                        const elems = try alloc.alloc(ConstValue, len);
                        initConstValueSlots(elems);
                        value_frame.dest.* = .{ .tuple = elems };
                        if (value_frame.is_root) result_initialized = true;
                        var index = len;
                        while (index > 0) {
                            index -= 1;
                            try stack.push(alloc, .{ .value = .{
                                .dest = &elems[index],
                                .depth = value_frame.depth + 1,
                            } });
                        }
                    },
                    CONST_TAG_LIST => {
                        const len: usize = try readSerializedU32(data, pos);
                        try budget.ensureChildren(value_frame.depth, len);
                        const elems = try alloc.alloc(ConstValue, len);
                        initConstValueSlots(elems);
                        value_frame.dest.* = .{ .list = elems };
                        if (value_frame.is_root) result_initialized = true;
                        var index = len;
                        while (index > 0) {
                            index -= 1;
                            try stack.push(alloc, .{ .value = .{
                                .dest = &elems[index],
                                .depth = value_frame.depth + 1,
                            } });
                        }
                    },
                    CONST_TAG_MAP => {
                        const entry_count: usize = try readSerializedU32(data, pos);
                        try budget.ensureChildren(value_frame.depth, try checkedChildCount(entry_count, 2));
                        const entries = try alloc.alloc(ConstValue.ConstMapEntry, entry_count);
                        initConstMapEntries(entries);
                        value_frame.dest.* = .{ .map = entries };
                        if (value_frame.is_root) result_initialized = true;
                        var index = entry_count;
                        while (index > 0) {
                            index -= 1;
                            try stack.push(alloc, .{ .value = .{
                                .dest = &entries[index].value,
                                .depth = value_frame.depth + 1,
                            } });
                            try stack.push(alloc, .{ .value = .{
                                .dest = &entries[index].key,
                                .depth = value_frame.depth + 1,
                            } });
                        }
                    },
                    CONST_TAG_STRUCT => {
                        const name_len: usize = try readSerializedU32(data, pos);
                        const type_name = try readSerializedBytes(alloc, data, pos, name_len);
                        var type_name_transferred = false;
                        errdefer if (!type_name_transferred) alloc.free(type_name);
                        const field_count: usize = try readSerializedU32(data, pos);
                        try budget.ensureChildren(value_frame.depth, field_count);
                        const fields = try alloc.alloc(ConstValue.ConstFieldValue, field_count);
                        var fields_transferred = false;
                        errdefer if (!fields_transferred) alloc.free(fields);
                        initConstFieldValues(fields);
                        value_frame.dest.* = .{ .struct_val = .{ .type_name = type_name, .fields = fields } };
                        type_name_transferred = true;
                        fields_transferred = true;
                        if (value_frame.is_root) result_initialized = true;
                        if (field_count > 0) {
                            try stack.push(alloc, .{ .struct_field = .{
                                .fields = fields,
                                .index = 0,
                                .depth = value_frame.depth,
                            } });
                        }
                    },
                    else => return error.UnexpectedEndOfData,
                }
            },
            .struct_field => |field_frame| {
                const name_len: usize = try readSerializedU32(data, pos);
                const field_name = try readSerializedBytes(alloc, data, pos, name_len);
                field_frame.fields[field_frame.index].name = field_name;
                if (field_frame.index + 1 < field_frame.fields.len) {
                    try stack.push(alloc, .{ .struct_field = .{
                        .fields = field_frame.fields,
                        .index = field_frame.index + 1,
                        .depth = field_frame.depth,
                    } });
                }
                try stack.push(alloc, .{ .value = .{
                    .dest = &field_frame.fields[field_frame.index].value,
                    .depth = field_frame.depth + 1,
                } });
            },
        }
    }

    return result;
}

const SerializeError = error{
    UnexpectedEndOfData,
    ValueTraversalDepthExceeded,
    ValueTraversalBudgetExceeded,
    OutOfMemory,
};

const DeserializeError = SerializeError || error{
    TrailingData,
};

fn serializeResult(alloc: std.mem.Allocator, result: CtEvalResult) SerializeError![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    // Magic + version
    try buf.appendSlice(alloc, "CTFE");
    try buf.append(alloc, 2); // version 2: full dependency serialization
    // Value
    try serializeConstValueInto(alloc, &buf, result.value);
    // Result hash
    try buf.appendSlice(alloc, std.mem.asBytes(&result.result_hash));
    // Dependencies
    const dep_count: u32 = @intCast(result.dependencies.len);
    try buf.appendSlice(alloc, std.mem.asBytes(&dep_count));
    for (result.dependencies) |dep| {
        try serializeDependencyInto(alloc, &buf, dep);
    }
    return buf.toOwnedSlice(alloc);
}

fn deserializeResult(alloc: std.mem.Allocator, data: []const u8) DeserializeError!CtEvalResult {
    if (data.len < 5) return error.UnexpectedEndOfData;
    if (!std.mem.eql(u8, data[0..4], "CTFE")) return error.UnexpectedEndOfData;
    if (data[4] != 2) return error.UnexpectedEndOfData; // version 2
    var pos: usize = 5;
    const value = try deserializeConstValue(alloc, data, &pos);
    errdefer deinitConstValue(alloc, value);
    if (pos + 8 > data.len) return error.UnexpectedEndOfData;
    const result_hash = std.mem.readInt(u64, data[pos..][0..8], .little);
    pos += 8;
    // Dependencies
    if (pos + 4 > data.len) return error.UnexpectedEndOfData;
    const dep_count = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;
    const deps = try alloc.alloc(CtDependency, dep_count);
    var initialized_dep_count: usize = 0;
    errdefer {
        for (deps[0..initialized_dep_count]) |dependency| {
            deinitCachedDependency(alloc, dependency);
        }
        alloc.free(deps);
    }
    for (0..dep_count) |i| {
        deps[i] = try deserializeDependency(alloc, data, &pos);
        initialized_dep_count += 1;
    }
    if (pos != data.len) return error.TrailingData;
    return .{
        .value = value,
        .dependencies = deps,
        .result_hash = result_hash,
    };
}

/// Create an arena-backed allocator for interpreter tests.
/// The interpreter makes many small allocations (collectLocals, struct fields,
/// error stacks) that are logically tied to the evaluation lifetime. Using an
/// arena mirrors production behavior (GPA+ArenaAllocator freed at process exit).
fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.page_allocator);
}

fn expectComputedAttributeCacheSetupHostIoFailure(result: EvalAttrResult) !void {
    try testing.expectEqual(@as(u32, 0), result.evaluated);
    try testing.expectEqual(@as(u32, 0), result.failed);
    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(CtfeErrorKind.host_io_failure, result.errors[0].kind);
    try testing.expect(std.mem.indexOf(u8, result.errors[0].message, "persistent CTFE cache setup failed") != null);
}

test "CtValue.isTruthy" {
    try testing.expect((CtValue{ .bool_val = true }).isTruthy());
    try testing.expect(!(CtValue{ .bool_val = false }).isTruthy());
    try testing.expect(!(@as(CtValue, .nil)).isTruthy());
    try testing.expect(!(@as(CtValue, .void)).isTruthy());
    try testing.expect((CtValue{ .int = 1 }).isTruthy());
    try testing.expect(!(CtValue{ .int = 0 }).isTruthy());
    try testing.expect((CtValue{ .int = -1 }).isTruthy());
    try testing.expect((CtValue{ .string = "hello" }).isTruthy());
    try testing.expect((CtValue{ .atom = "ok" }).isTruthy());
}

test "CtValue.eql" {
    try testing.expect(try (CtValue{ .int = 42 }).eql(.{ .int = 42 }));
    try testing.expect(!(try (CtValue{ .int = 42 }).eql(.{ .int = 43 })));
    try testing.expect(try (CtValue{ .string = "abc" }).eql(.{ .string = "abc" }));
    try testing.expect(!(try (CtValue{ .string = "abc" }).eql(.{ .string = "def" })));
    try testing.expect(try (CtValue{ .bool_val = true }).eql(.{ .bool_val = true }));
    try testing.expect(!(try (CtValue{ .bool_val = true }).eql(.{ .bool_val = false })));
    try testing.expect(try (CtValue{ .atom = "ok" }).eql(.{ .atom = "ok" }));
    try testing.expect(!(try (CtValue{ .atom = "ok" }).eql(.{ .atom = "error" })));
    try testing.expect(try (@as(CtValue, .nil)).eql(.nil));
    try testing.expect(try (@as(CtValue, .void)).eql(.void));
    // Cross-type inequality
    try testing.expect(!(try (CtValue{ .int = 0 }).eql(.nil)));
    try testing.expect(!(try (CtValue{ .int = 1 }).eql(.{ .bool_val = true })));
}

test "CtValue.compare" {
    try testing.expectEqual(std.math.Order.lt, (CtValue{ .int = 1 }).compare(.{ .int = 2 }).?);
    try testing.expectEqual(std.math.Order.gt, (CtValue{ .int = 2 }).compare(.{ .int = 1 }).?);
    try testing.expectEqual(std.math.Order.eq, (CtValue{ .int = 5 }).compare(.{ .int = 5 }).?);
    try testing.expectEqual(std.math.Order.lt, (CtValue{ .float = 1.0 }).compare(.{ .float = 2.0 }).?);
    // Incomparable types
    try testing.expect((CtValue{ .int = 1 }).compare(.{ .string = "a" }) == null);
}

test "exportValue scalars" {
    const alloc = testing.allocator;
    {
        const result = try exportValue(alloc, .{ .int = 42 });
        try testing.expectEqual(@as(i64, 42), result.int);
    }
    {
        const result = try exportValue(alloc, .{ .bool_val = true });
        try testing.expect(result.bool_val);
    }
    {
        const result = try exportValue(alloc, .nil);
        try testing.expect(result == .nil);
    }
    {
        const result = try exportValue(alloc, .{ .string = "hello" });
        try testing.expectEqualStrings("hello", result.string);
        alloc.free(result.string);
    }
    {
        const result = try exportValue(alloc, .{ .atom = "ok" });
        try testing.expectEqualStrings("ok", result.atom);
        alloc.free(result.atom);
    }
}

test "exportValue tuple" {
    const alloc = testing.allocator;
    const elems = [_]CtValue{ .{ .int = 1 }, .{ .int = 2 } };
    const result = try exportValue(alloc, .{ .tuple = .{ .alloc_id = 1, .elems = &elems } });
    defer alloc.free(result.tuple);
    try testing.expectEqual(@as(usize, 2), result.tuple.len);
    try testing.expectEqual(@as(i64, 1), result.tuple[0].int);
    try testing.expectEqual(@as(i64, 2), result.tuple[1].int);
}

test "exportValue closure fails" {
    const alloc = testing.allocator;
    const result = exportValue(alloc, .{ .closure = .{
        .alloc_id = 1,
        .function_id = 0,
        .captures = &.{},
    } });
    try testing.expectError(error.CannotExport, result);
}

test "constValueToExpr: tuple" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    const cv = ConstValue{ .tuple = &.{
        .{ .int = 1 },
        .{ .int = 2 },
        .{ .int = 3 },
    } };
    const expr = try constValueToExpr(alloc, cv, &interner);
    try testing.expect(expr.* == .tuple);
    try testing.expectEqual(@as(usize, 3), expr.tuple.elements.len);
    try testing.expectEqual(@as(i64, 1), expr.tuple.elements[0].int_literal.value);
}

test "constValueToExpr: list" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    const cv = ConstValue{ .list = &.{
        .{ .int = 10 },
        .{ .int = 20 },
    } };
    const expr = try constValueToExpr(alloc, cv, &interner);
    try testing.expect(expr.* == .list);
    try testing.expectEqual(@as(usize, 2), expr.list.elements.len);
    try testing.expectEqual(@as(i64, 10), expr.list.elements[0].int_literal.value);
}

test "constValueToExpr: map" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    const cv = ConstValue{ .map = &.{
        .{ .key = .{ .atom = "name" }, .value = .{ .string = "zap" } },
    } };
    const expr = try constValueToExpr(alloc, cv, &interner);
    try testing.expect(expr.* == .map);
    try testing.expectEqual(@as(usize, 1), expr.map.fields.len);
    try testing.expect(expr.map.fields[0].key.* == .atom_literal);
    try testing.expect(expr.map.fields[0].value.* == .string_literal);
}

test "constValueToExpr: struct_val" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    const cv = ConstValue{ .struct_val = .{
        .type_name = "Config",
        .fields = &.{
            .{ .name = "port", .value = .{ .int = 8080 } },
        },
    } };
    const expr = try constValueToExpr(alloc, cv, &interner);
    try testing.expect(expr.* == .struct_expr);
    try testing.expectEqual(@as(usize, 1), expr.struct_expr.fields.len);
    try testing.expectEqual(@as(i64, 8080), expr.struct_expr.fields[0].value.int_literal.value);
}

test "constValueToExpr: nested list of tuples" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    const cv = ConstValue{ .list = &.{
        .{ .tuple = &.{ .{ .int = 1 }, .{ .int = 2 } } },
    } };
    const expr = try constValueToExpr(alloc, cv, &interner);
    try testing.expect(expr.* == .list);
    try testing.expect(expr.list.elements[0].* == .tuple);
    try testing.expectEqual(@as(usize, 2), expr.list.elements[0].tuple.elements.len);
}

fn exerciseConstValueToExprNestedAllocationFailures(
    allocator: std.mem.Allocator,
    value: ConstValue,
) !void {
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();

    const expr = try constValueToExpr(allocator, value, &interner);
    defer deinitConvertedConstValueExpr(allocator, expr);

    try testing.expect(expr.* == .struct_expr);
    try testing.expectEqual(@as(usize, 2), expr.struct_expr.fields.len);
}

test "constValueToExpr frees partial nested aggregate AST on allocation failure" {
    const tuple_items = [_]ConstValue{
        .{ .atom = "key" },
        .{ .int = 2 },
    };
    const list_items = [_]ConstValue{
        .{ .tuple = &tuple_items },
        .{ .string = "value" },
    };
    const map_entries = [_]ConstValue.ConstMapEntry{
        .{
            .key = .{ .atom = "items" },
            .value = .{ .list = &list_items },
        },
        .{
            .key = .{ .string = "other" },
            .value = .{ .tuple = &tuple_items },
        },
    };
    const fields = [_]ConstValue.ConstFieldValue{
        .{
            .name = "payload",
            .value = .{ .map = &map_entries },
        },
        .{
            .name = "tail",
            .value = .{ .list = &list_items },
        },
    };
    const value = ConstValue{ .struct_val = .{
        .type_name = "NestedExpr",
        .fields = &fields,
    } };

    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseConstValueToExprNestedAllocationFailures,
        .{value},
    );
}

test "importConstValue: aggregates round-trip" {
    const alloc = testing.allocator;
    // Test tuple round-trip through export→import
    const ct_tuple = CtValue{ .tuple = .{ .alloc_id = 1, .elems = &.{ .{ .int = 1 }, .{ .int = 2 } } } };
    const exported = try exportValue(alloc, ct_tuple);
    defer alloc.free(exported.tuple);
    const imported = try Interpreter.importConstValue(alloc, exported);
    defer alloc.free(imported.tuple.elems);
    try testing.expect(imported == .tuple);
    try testing.expectEqual(@as(usize, 2), imported.tuple.elems.len);
    try testing.expectEqual(@as(i64, 1), imported.tuple.elems[0].int);
}

fn exerciseImportConstValueNestedAllocationFailures(allocator: std.mem.Allocator, value: ConstValue) !void {
    const imported = try Interpreter.importConstValue(allocator, value);
    defer deinitOwnedCtValue(allocator, imported);

    try testing.expect(imported == .struct_val);
    try testing.expectEqual(@as(usize, 2), imported.struct_val.fields.len);
}

test "importConstValue frees partial nested aggregate roots on allocation failure" {
    const tuple_items = [_]ConstValue{
        .{ .atom = "key" },
        .{ .int = 2 },
    };
    const list_items = [_]ConstValue{
        .{ .tuple = &tuple_items },
        .{ .string = "value" },
    };
    const map_entries = [_]ConstValue.ConstMapEntry{
        .{
            .key = .{ .atom = "items" },
            .value = .{ .list = &list_items },
        },
        .{
            .key = .{ .string = "other" },
            .value = .{ .tuple = &tuple_items },
        },
    };
    const fields = [_]ConstValue.ConstFieldValue{
        .{
            .name = "payload",
            .value = .{ .map = &map_entries },
        },
        .{
            .name = "tail",
            .value = .{ .list = &list_items },
        },
    };
    const value = ConstValue{ .struct_val = .{
        .type_name = "NestedImport",
        .fields = &fields,
    } };

    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseImportConstValueNestedAllocationFailures,
        .{value},
    );
}

fn nestedCtListForTraversalTest(alloc: std.mem.Allocator, list_depth: usize) !CtValue {
    const nodes = try alloc.alloc(CtValue, list_depth + 1);
    nodes[list_depth] = .{ .int = 1 };
    var index = list_depth;
    while (index > 0) {
        index -= 1;
        nodes[index] = .{ .list = .{
            .alloc_id = @intCast(index + 1),
            .elems = nodes[index + 1 .. index + 2],
        } };
    }
    return nodes[0];
}

fn nestedCtTupleForTraversalTest(alloc: std.mem.Allocator, tuple_depth: usize) !CtValue {
    const nodes = try alloc.alloc(CtValue, tuple_depth + 1);
    nodes[tuple_depth] = .{ .int = 1 };
    var index = tuple_depth;
    while (index > 0) {
        index -= 1;
        nodes[index] = .{ .tuple = .{
            .alloc_id = @intCast(index + 1),
            .elems = nodes[index + 1 .. index + 2],
        } };
    }
    return nodes[0];
}

fn nestedCtMapForTraversalTest(alloc: std.mem.Allocator, map_depth: usize) !CtValue {
    if (map_depth == 0) return .{ .int = 1 };

    const nodes = try alloc.alloc(CtValue, map_depth + 1);
    const entries = try alloc.alloc(CtValue.CtMapEntry, map_depth);
    nodes[map_depth] = .{ .int = 1 };

    var index = map_depth;
    while (index > 0) {
        index -= 1;
        entries[index] = .{
            .key = .{ .atom = "k" },
            .value = nodes[index + 1],
        };
        nodes[index] = .{ .map = .{
            .alloc_id = @intCast(index + 1),
            .entries = entries[index .. index + 1],
        } };
    }
    return nodes[0];
}

fn nestedCtOptionalForTraversalTest(alloc: std.mem.Allocator, optional_depth: usize) !CtValue {
    const nodes = try alloc.alloc(CtValue, optional_depth + 1);
    nodes[optional_depth] = .{ .int = 1 };
    var index = optional_depth;
    while (index > 0) {
        index -= 1;
        nodes[index] = .{ .optional = .{ .value = &nodes[index + 1] } };
    }
    return nodes[0];
}

fn nestedConstListForTraversalTest(alloc: std.mem.Allocator, list_depth: usize) !ConstValue {
    const nodes = try alloc.alloc(ConstValue, list_depth + 1);
    nodes[list_depth] = .{ .int = 1 };
    var index = list_depth;
    while (index > 0) {
        index -= 1;
        nodes[index] = .{ .list = nodes[index + 1 .. index + 2] };
    }
    return nodes[0];
}

fn appendNestedConstListSerializationForTraversalTest(
    alloc: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    list_depth: usize,
) !void {
    for (0..list_depth) |_| {
        try buf.append(alloc, CONST_TAG_LIST);
        try appendSerializedLength(alloc, buf, 1);
    }
    try buf.append(alloc, CONST_TAG_INT);
    const value: i64 = 1;
    try buf.appendSlice(alloc, std.mem.asBytes(&value));
}

test "exportValue rejects CtValue nesting beyond traversal depth" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try nestedCtListForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, exportValue(alloc, root));
}

test "CtValue.eqlWithAllocator rejects nesting beyond traversal depth" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const left = try nestedCtListForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    const right = try nestedCtListForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, left.eqlWithAllocator(alloc, right));
}

test "CtValue.eqlWithAllocator propagates traversal stack OOM" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const spill_depth = VALUE_TRAVERSAL_INLINE_STACK_CAPACITY + 8;
    const left = try nestedCtListForTraversalTest(alloc, spill_depth);
    const right = try nestedCtListForTraversalTest(alloc, spill_depth);

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, left.eqlWithAllocator(failing_allocator.allocator(), right));
    try testing.expect(failing_allocator.has_induced_failure);
}

test "CtValue.eql propagates traversal errors" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const left = try nestedCtListForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    const right = try nestedCtListForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, left.eql(right));
}

test "CtValue.hash rejects nesting beyond traversal depth" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try nestedCtListForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, root.hash(alloc));
}

test "ConstValue hash rejects nesting beyond traversal depth" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try nestedConstListForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, Interpreter.hashConstValue(alloc, root));
}

test "constValueToExpr rejects nesting beyond traversal depth" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    const root = try nestedConstListForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, constValueToExpr(alloc, root, &interner));
}

test "importConstValue rejects nesting beyond traversal depth" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try nestedConstListForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, Interpreter.importConstValue(alloc, root));
}

test "serializeConstValue rejects nesting beyond traversal depth" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try nestedConstListForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, serializeConstValue(alloc, root));
}

test "deserializeConstValue rejects nesting beyond traversal depth" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(alloc);
    try appendNestedConstListSerializationForTraversalTest(alloc, &data, MAX_VALUE_TRAVERSAL_DEPTH);

    var pos: usize = 0;
    try testing.expectError(error.ValueTraversalDepthExceeded, deserializeConstValue(alloc, data.items, &pos));
}

test "formatCtValue preserves aggregate inspect output" {
    const alloc = testing.allocator;
    const display_list_elems = [_]CtValue{ .{ .string = "two" }, .{ .atom = "ok" } };
    const optional_list_elems = [_]CtValue{ .{ .bool_val = true }, .nil };
    const optional_payload = CtValue{ .list = .{
        .alloc_id = 2,
        .elems = &optional_list_elems,
    } };
    const optional_some = CtValue{ .optional = .{ .value = &optional_payload } };
    const map_entries = [_]CtValue.CtMapEntry{
        .{ .key = .{ .atom = "name" }, .value = optional_some },
        .{ .key = .{ .string = "count" }, .value = .{ .int = 2 } },
    };
    const tuple_elems = [_]CtValue{
        .{ .int = 1 },
        .{ .list = .{ .alloc_id = 1, .elems = &display_list_elems } },
        .{ .map = .{ .alloc_id = 3, .entries = &map_entries } },
        .{ .optional = .{ .value = null } },
    };
    const root = CtValue{ .tuple = .{ .alloc_id = 4, .elems = &tuple_elems } };

    const formatted = try formatCtValue(alloc, root);
    defer alloc.free(formatted);

    try testing.expectEqualStrings(
        "{1, [\"two\", :ok], %{:name => [true, nil], \"count\" => 2}, nil}",
        formatted,
    );
}

test "formatCtValue rejects deeply nested tuple inspect formatting" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try nestedCtTupleForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, formatCtValue(alloc, root));
}

test "formatCtValue rejects deeply nested list inspect formatting" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try nestedCtListForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, formatCtValue(alloc, root));
}

test "formatCtValue rejects deeply nested map inspect formatting" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try nestedCtMapForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, formatCtValue(alloc, root));
}

test "formatCtValue rejects deeply nested optional inspect formatting" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try nestedCtOptionalForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    try testing.expectError(error.ValueTraversalDepthExceeded, formatCtValue(alloc, root));
}

test "builtinInspect reports traversal diagnostic for deep inspect formatting" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try nestedCtOptionalForTraversalTest(alloc, MAX_VALUE_TRAVERSAL_DEPTH);
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    try testing.expectError(error.CtfeFailure, interp.builtinInspect(&.{root}));
    try testing.expectEqual(@as(usize, 1), interp.errors.items.len);
    try testing.expectEqual(CtfeErrorKind.value_traversal_limit_exceeded, interp.errors.items[0].kind);
    try testing.expect(std.mem.indexOf(u8, interp.errors.items[0].message, "depth") != null);
}

test "interpreter: constants" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: binary_op add" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "add_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } },
                .{ .const_int = .{ .dest = 1, .value = 32 } },
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: if_expr true branch" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "if_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_bool = .{ .dest = 0, .value = true } },
                .{ .if_expr = .{
                    .dest = 1,
                    .condition = 0,
                    .then_instrs = &.{
                        .{ .const_int = .{ .dest = 2, .value = 100 } },
                    },
                    .then_result = 2,
                    .else_instrs = &.{
                        .{ .const_int = .{ .dest = 3, .value = 200 } },
                    },
                    .else_result = 3,
                } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 100), result.int);
}

test "interpreter: if_expr false branch" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "if_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_bool = .{ .dest = 0, .value = false } },
                .{ .if_expr = .{
                    .dest = 1,
                    .condition = 0,
                    .then_instrs = &.{
                        .{ .const_int = .{ .dest = 2, .value = 100 } },
                    },
                    .then_result = 2,
                    .else_instrs = &.{
                        .{ .const_int = .{ .dest = 3, .value = 200 } },
                    },
                    .else_result = 3,
                } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 200), result.int);
}

test "interpreter: param_get" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "identity",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalByName("identity", &.{.{ .int = 99 }});
    try testing.expectEqual(@as(i64, 99), result.int);
}

test "interpreter: call_direct between functions" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    // Function 0: returns 7
    const inner = ir.Function{
        .id = 0,
        .name = "inner",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 7 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    // Function 1: calls inner and adds 3
    const outer = ir.Function{
        .id = 1,
        .name = "outer",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .call_direct = .{ .dest = 0, .function = 0, .args = &.{}, .arg_modes = &.{} } },
                .{ .const_int = .{ .dest = 1, .value = 3 } },
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{ inner, outer };
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(1, &.{});
    try testing.expectEqual(@as(i64, 10), result.int);
}

test "interpreter: call_named" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const callee = ir.Function{
        .id = 0,
        .name = "helper",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .const_int = .{ .dest = 1, .value = 1 } },
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const caller = ir.Function{
        .id = 1,
        .name = "main",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 5 } },
                .{ .call_named = .{ .dest = 1, .name = "helper", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{ callee, caller };
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalByName("main", &.{});
    try testing.expectEqual(@as(i64, 6), result.int);
}

test "interpreter: struct_init and field_get" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "struct_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .const_string = .{ .dest = 1, .value = "hello" } },
                .{ .struct_init = .{
                    .dest = 2,
                    .type_name = "MyStruct",
                    .fields = &.{
                        .{ .name = "x", .value = 0 },
                        .{ .name = "y", .value = 1 },
                    },
                } },
                .{ .field_get = .{ .dest = 3, .object = 2, .field = "x" } },
                .{ .ret = .{ .value = 3 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: step budget exceeded" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    // Recursive function that will exceed step budget
    const func = ir.Function{
        .id = 0,
        .name = "infinite",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .call_named = .{ .dest = 0, .name = "infinite", .args = &.{}, .arg_modes = &.{} } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.step_budget = 100;
    interp.steps_remaining = 100;
    interp.recursion_limit = 1000; // high limit so step budget hits first

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expect(interp.errors.items.len > 0);
}

test "interpreter: recursion limit exceeded" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "infinite",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .call_named = .{ .dest = 0, .name = "infinite", .args = &.{}, .arg_modes = &.{} } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.recursion_limit = 5;
    interp.step_budget = 1_000_000;
    interp.steps_remaining = 1_000_000;

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expect(interp.errors.items.len > 0);
    try testing.expectEqual(CtfeErrorKind.recursion_limit_exceeded, interp.errors.items[0].kind);
}

test "interpreter: switch_return dispatch" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    // Function that switches on param 0 (integer)
    const func = ir.Function{
        .id = 0,
        .name = "dispatch",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .switch_return = .{
                    .scrutinee_param = 0,
                    .cases = &.{
                        .{
                            .value = .{ .int = 1 },
                            .body_instrs = &.{
                                .{ .const_int = .{ .dest = 0, .value = 100 } },
                            },
                            .return_value = 0,
                        },
                        .{
                            .value = .{ .int = 2 },
                            .body_instrs = &.{
                                .{ .const_int = .{ .dest = 0, .value = 200 } },
                            },
                            .return_value = 0,
                        },
                    },
                    .default_instrs = &.{
                        .{ .const_int = .{ .dest = 0, .value = 999 } },
                    },
                    .default_result = 0,
                } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const r1 = try interp.evalFunction(0, &.{.{ .int = 1 }});
    try testing.expectEqual(@as(i64, 100), r1.int);

    interp.steps_remaining = interp.step_budget;
    const r2 = try interp.evalFunction(0, &.{.{ .int = 2 }});
    try testing.expectEqual(@as(i64, 200), r2.int);

    interp.steps_remaining = interp.step_budget;
    const r3 = try interp.evalFunction(0, &.{.{ .int = 99 }});
    try testing.expectEqual(@as(i64, 999), r3.int);
}

test "interpreter: branch between blocks" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "branch_blocks",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{
            .{ .label = 0, .instructions = &.{.{ .branch = .{ .target = 1 } }} },
            .{ .label = 1, .instructions = &.{ .{ .const_int = .{ .dest = 0, .value = 42 } }, .{ .ret = .{ .value = 0 } } } },
        },
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: cond_branch between blocks" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "cond_branch_blocks",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{
            .{ .label = 0, .instructions = &.{
                .{ .const_bool = .{ .dest = 0, .value = true } },
                .{ .cond_branch = .{ .condition = 0, .then_target = 1, .else_target = 2 } },
            } },
            .{ .label = 1, .instructions = &.{ .{ .const_int = .{ .dest = 1, .value = 42 } }, .{ .ret = .{ .value = 1 } } } },
            .{ .label = 2, .instructions = &.{ .{ .const_int = .{ .dest = 1, .value = 0 } }, .{ .ret = .{ .value = 1 } } } },
        },
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: switch_tag dispatch" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const payload = try alloc.create(CtValue);
    payload.* = .{ .int = 42 };
    const union_value = CtValue{ .union_val = .{ .alloc_id = 1, .type_name = "Option", .variant = "some", .payload = payload } };
    const func = ir.Function{
        .id = 0,
        .name = "switch_tag_blocks",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .any }},
        .return_type = .i64,
        .body = &.{
            .{ .label = 0, .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .switch_tag = .{ .scrutinee = 0, .cases = &.{.{ .tag = "some", .target = 1 }}, .default = 2 } },
            } },
            .{ .label = 1, .instructions = &.{ .{ .const_int = .{ .dest = 1, .value = 42 } }, .{ .ret = .{ .value = 1 } } } },
            .{ .label = 2, .instructions = &.{ .{ .const_int = .{ .dest = 1, .value = 0 } }, .{ .ret = .{ .value = 1 } } } },
        },
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{union_value});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: phi selects predecessor value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "phi_blocks",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{
            .{ .label = 0, .instructions = &.{
                .{ .const_bool = .{ .dest = 0, .value = true } },
                .{ .cond_branch = .{ .condition = 0, .then_target = 1, .else_target = 2 } },
            } },
            .{ .label = 1, .instructions = &.{ .{ .const_int = .{ .dest = 1, .value = 42 } }, .{ .branch = .{ .target = 3 } } } },
            .{ .label = 2, .instructions = &.{ .{ .const_int = .{ .dest = 2, .value = 0 } }, .{ .branch = .{ .target = 3 } } } },
            .{ .label = 3, .instructions = &.{
                .{ .phi = .{ .dest = 3, .sources = &.{ .{ .from_block = 1, .value = 1 }, .{ .from_block = 2, .value = 2 } } } },
                .{ .ret = .{ .value = 3 } },
            } },
        },
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);
}

test "interpreter: division by zero" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "div_zero",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } },
                .{ .const_int = .{ .dest = 1, .value = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .div, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.division_by_zero, interp.errors.items[0].kind);
}

test "interpreter: remainder by zero" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "rem_zero",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } },
                .{ .const_int = .{ .dest = 1, .value = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .rem_op, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.division_by_zero, interp.errors.items[0].kind);
}

// ctfe-1--05 / CT-02 (IR interpreter): `minInt / -1` is signed-overflow
// illegal behavior for raw `@divTrunc`; the interpreter must surface a clean
// `arithmetic_overflow` diagnostic, NOT panic the compiler process. Before the
// guard this hand-built IR `@divTrunc(minInt, -1)` crashed `numericOp`.
test "interpreter: minInt / -1 is a clean overflow diagnostic, not a panic" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "div_overflow",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = std.math.minInt(i64) } },
                .{ .const_int = .{ .dest = 1, .value = -1 } },
                .{ .binary_op = .{ .dest = 2, .op = .div, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.arithmetic_overflow, interp.errors.items[0].kind);
}

test "interpreter: minInt rem -1 is a clean overflow diagnostic, not a panic" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "rem_overflow",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = std.math.minInt(i64) } },
                .{ .const_int = .{ .dest = 1, .value = -1 } },
                .{ .binary_op = .{ .dest = 2, .op = .rem_op, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.arithmetic_overflow, interp.errors.items[0].kind);
}

// ctfe-2--01 / CT-02 (attribute constant-folder): the same `minInt / -1`
// (and `minInt rem -1`) overflow corner reached through `evaluateConstBinaryOp`
// — the path that folds struct/build.zap attribute expressions — must produce a
// clean `error.CtfeFailed` diagnostic, NOT panic the compiler.
fn constIntExpr(alloc: std.mem.Allocator, value: i64) !*const ast.Expr {
    const e = try alloc.create(ast.Expr);
    e.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = value } };
    return e;
}

fn evalConstBinop(alloc: std.mem.Allocator, op: ast.BinaryOp.Op, lhs: i64, rhs: i64) AttrEvalInternalError!CtValue {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interner = ast.StringInterner.init(alloc);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.interner = &interner;
    const binop = ast.BinaryOp{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .op = op,
        .lhs = try constIntExpr(alloc, lhs),
        .rhs = try constIntExpr(alloc, rhs),
    };
    var temp_scope = ConstExprTempScope.init(alloc);
    defer temp_scope.deinit();
    return evaluateConstBinaryOp(&temp_scope, &interp, binop, null, &interner);
}

test "attribute folder: division by zero is a clean diagnostic, not a panic" {
    var arena = testArena();
    defer arena.deinit();
    try testing.expectError(error.CtfeFailed, evalConstBinop(arena.allocator(), .div, 10, 0));
}

test "attribute folder: minInt / -1 is a clean diagnostic, not a panic" {
    var arena = testArena();
    defer arena.deinit();
    try testing.expectError(error.CtfeFailed, evalConstBinop(arena.allocator(), .div, std.math.minInt(i64), -1));
}

test "attribute folder: minInt rem -1 is a clean diagnostic, not a panic" {
    var arena = testArena();
    defer arena.deinit();
    try testing.expectError(error.CtfeFailed, evalConstBinop(arena.allocator(), .rem_op, std.math.minInt(i64), -1));
}

test "attribute folder: ordinary minInt / 2 folds to the right value" {
    var arena = testArena();
    defer arena.deinit();
    const result = try evalConstBinop(arena.allocator(), .div, std.math.minInt(i64), 2);
    try testing.expectEqual(@as(i64, std.math.minInt(i64) / 2), result.int);
}

// Sanity: an ordinary minInt / 2 still evaluates (the guard is precise to the
// -1 overflow corner, not all minInt divisions).
test "interpreter: minInt / 2 evaluates normally" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "div_minint_two",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = std.math.minInt(i64) } },
                .{ .const_int = .{ .dest = 1, .value = 2 } },
                .{ .binary_op = .{ .dest = 2, .op = .div, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, std.math.minInt(i64) / 2), result.int);
}

test "interpreter: error records failing instruction index" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "div_idx",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } },
                .{ .const_int = .{ .dest = 1, .value = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .div, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(@as(usize, 1), interp.errors.items.len);
    try testing.expectEqual(@as(usize, 1), interp.errors.items[0].call_stack.len);
    try testing.expectEqual(@as(usize, 2), interp.errors.items[0].call_stack[0].instruction_index);
}

test "interpreter: error captures function source span provenance" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const fn_name = try interner.intern("div_idx");

    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();

    const mod_scope = try graph.createScope(0, .struct_scope);
    const family_id = try graph.createFamily(mod_scope, fn_name, 0, .public);

    const clause_span = ast.SourceSpan{ .start = 10, .end = 20, .line = 7, .col = 3 };
    const clauses = try alloc.alloc(ast.FunctionClause, 1);
    clauses[0] = .{
        .meta = .{ .span = clause_span },
        .params = &.{},
        .return_type = null,
        .refinement = null,
        .body = &.{},
    };
    const decl = try alloc.create(ast.FunctionDecl);
    decl.* = .{
        .meta = .{ .span = clause_span },
        .name = fn_name,
        .clauses = clauses,
        .visibility = .public,
    };
    try graph.getFamilyMut(family_id).clauses.append(alloc, .{ .decl = decl, .clause_index = 0 });

    const func = ir.Function{
        .id = 0,
        .name = "div_idx",
        .scope_id = mod_scope,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } },
                .{ .const_int = .{ .dest = 1, .value = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .div, .lhs = 0, .rhs = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const program = makeTestProgram(&.{func});

    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.scope_graph = &graph;
    interp.interner = &interner;

    try testing.expectError(error.CtfeFailure, interp.evalFunction(0, &.{}));
    try testing.expect(interp.errors.items[0].call_stack[0].source_span != null);
    try testing.expectEqual(@as(u32, 7), interp.errors.items[0].call_stack[0].source_span.?.line);
    try testing.expectEqual(@as(u32, 3), interp.errors.items[0].call_stack[0].source_span.?.col);
}

test "interpreter: match_atom" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "match_fn",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .atom }},
        .return_type = .bool_type,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .match_atom = .{ .dest = 1, .scrutinee = 0, .atom_name = "ok" } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const r1 = try interp.evalFunction(0, &.{.{ .atom = "ok" }});
    try testing.expect(r1.bool_val);

    interp.steps_remaining = interp.step_budget;
    const r2 = try interp.evalFunction(0, &.{.{ .atom = "error" }});
    try testing.expect(!r2.bool_val);
}

test "interpreter: tuple_init and index_get" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "tuple_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } },
                .{ .const_int = .{ .dest = 1, .value = 20 } },
                .{ .tuple_init = .{ .dest = 2, .elements = &.{ 0, 1 } } },
                .{ .index_get = .{ .dest = 3, .object = 2, .index = 1 } },
                .{ .ret = .{ .value = 3 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 20), result.int);
}

test "CapabilitySet" {
    const pure = CapabilitySet.pure_only;
    try testing.expect(!pure.has(.read_file));
    try testing.expect(!pure.has(.read_env));

    const build = CapabilitySet.build;
    try testing.expect(build.has(.pure));
    try testing.expect(build.has(.read_file));
    try testing.expect(build.has(.read_env));
    try testing.expect(build.has(.reflect_struct));

    const with_reflect = pure.with(.reflect_struct);
    try testing.expect(with_reflect.has(.reflect_struct));
    try testing.expect(!with_reflect.has(.read_file));

    const with_source_reflect = pure.with(.reflect_source);
    try testing.expect(with_source_reflect.has(.reflect_source));
    try testing.expect(!with_source_reflect.has(.read_file));
}

test "reflection: source path matching handles normalized and canonical paths" {
    const alloc = testing.allocator;

    try testing.expect(try sourcePathsEqual(alloc, "./app.zap", "app.zap"));
    try testing.expect(try sourcePathsEqual(alloc, "src/ctfe.zig", "src/../src/ctfe.zig"));
    try testing.expect(!try sourcePathsEqual(alloc, "src/ctfe.zig", "src/main.zig"));

    const normalized_paths = [_][]const u8{"./app.zap"};
    try testing.expect(try pathFilterContains(alloc, &normalized_paths, "app.zap"));
    const canonical_paths = [_][]const u8{"src/../src/ctfe.zig"};
    try testing.expect(try pathFilterContains(alloc, &canonical_paths, "src/ctfe.zig"));
    const existing_paths = [_][]const u8{ "src/discovery.zig", "src/ctfe.zig" };
    try testing.expect(!try pathFilterContains(alloc, &existing_paths, "src/main.zig"));
}

test "reflection: source path matching propagates canonicalization OOM" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    try testing.expectError(
        error.OutOfMemory,
        sourcePathsEqual(failing_allocator.allocator(), "src/ctfe.zig", "src/../src/ctfe.zig"),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: reflection source path matching propagates canonicalization failure" {
    try testing.expectError(
        error.SourcePathCanonicalizationFailed,
        sourcePathsEqual(testing.allocator, "missing/p4j2/source-left.zap", "missing/p4j2/source-right.zap"),
    );
}

test "reflection: source reflection hash filters paths and propagates matching OOM" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const app_id = try interner.intern("App");
    const other_id = try interner.intern("Other");
    const canonical_id = try interner.intern("Canonical");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "app.zap", .data = "pub struct App {\n}\n" });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "other.zap", .data = "pub struct Other {\n}\n" });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "canonical.zap", .data = "pub struct Canonical {\n}\n" });
    try tmp_dir.dir.createDirPath(std.Options.debug_io, "nested");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    const app_path = try std.fs.path.join(alloc, &.{ tmp_path, "app.zap" });
    const app_path_with_dot = try std.fmt.allocPrint(alloc, "{s}/./app.zap", .{tmp_path});
    const other_path = try std.fs.path.join(alloc, &.{ tmp_path, "other.zap" });
    const canonical_path = try std.fs.path.join(alloc, &.{ tmp_path, "canonical.zap" });
    const canonical_surface_path = try std.fmt.allocPrint(alloc, "{s}/nested/../canonical.zap", .{tmp_path});

    var graph = try scope.ScopeGraph.init(alloc);
    try graph.registerSourceFile(0, app_path);
    try graph.registerSourceFile(1, other_path);
    try graph.registerSourceFile(2, canonical_surface_path);

    const app_scope = try graph.createScope(0, .struct_scope);
    const app_decl = try alloc.create(ast.StructDecl);
    app_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 3, .source_id = 0 } },
        .name = .{ .parts = &.{app_id}, .span = .{ .start = 0, .end = 3, .source_id = 0 } },
        .items = &.{},
    };
    try graph.registerStruct(app_decl.name, app_scope, app_decl);

    const other_scope = try graph.createScope(0, .struct_scope);
    const other_decl = try alloc.create(ast.StructDecl);
    other_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 5, .source_id = 1 } },
        .name = .{ .parts = &.{other_id}, .span = .{ .start = 0, .end = 5, .source_id = 1 } },
        .items = &.{},
    };
    try graph.registerStruct(other_decl.name, other_scope, other_decl);

    const canonical_scope = try graph.createScope(0, .struct_scope);
    const canonical_decl = try alloc.create(ast.StructDecl);
    canonical_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 3, .source_id = 2 } },
        .name = .{ .parts = &.{canonical_id}, .span = .{ .start = 0, .end = 3, .source_id = 2 } },
        .items = &.{},
    };
    try graph.registerStruct(canonical_decl.name, canonical_scope, canonical_decl);

    const app_hash = try computeSourceReflectionHash(alloc, &graph, &interner, &.{app_path});
    const normalized_app_hash = try computeSourceReflectionHash(alloc, &graph, &interner, &.{app_path_with_dot});
    const other_hash = try computeSourceReflectionHash(alloc, &graph, &interner, &.{other_path});
    const canonical_hash = try computeSourceReflectionHash(alloc, &graph, &interner, &.{canonical_path});
    try testing.expectEqual(app_hash, normalized_app_hash);
    try testing.expect(app_hash != other_hash);
    try testing.expect(canonical_hash != app_hash);

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        computeSourceReflectionHash(failing_allocator.allocator(), &graph, &interner, &.{canonical_path}),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: extractPathFilter frees owned slice on invalid list element" {
    const alloc = testing.allocator;

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const elems = [_]CtValue{
        .{ .string = "app.zap" },
        .{ .int = 1 },
    };
    const filter_value = CtValue{ .list = .{ .alloc_id = 0, .elems = &elems } };

    try testing.expectError(error.CtfeFailure, interp.extractPathFilter(filter_value));
    try testing.expectEqual(@as(usize, 1), interp.errors.items.len);
    try testing.expectEqual(CtfeErrorKind.type_error, interp.errors.items[0].kind);
}

test "P4J2: source_graph_structs frees path filter before dependency transfer on hash failure" {
    var graph_arena = testArena();
    defer graph_arena.deinit();
    const graph_alloc = graph_arena.allocator();

    var interner = ast.StringInterner.init(graph_alloc);
    const app_id = try interner.intern("App");

    var graph = try scope.ScopeGraph.init(graph_alloc);
    try graph.registerSourceFile(0, "missing/p4j2/source.zap");
    const app_scope = try graph.createScope(0, .struct_scope);
    const app_decl = try graph_alloc.create(ast.StructDecl);
    app_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 3, .source_id = 0 } },
        .name = .{ .parts = &.{app_id}, .span = .{ .start = 0, .end = 3, .source_id = 0 } },
        .items = &.{},
    };
    try graph.registerStruct(app_decl.name, app_scope, app_decl);

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(testing.allocator, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only.with(.reflect_source);
    interp.scope_graph = &graph;
    interp.interner = &interner;

    try testing.expectError(error.CtfeFailure, interp.builtinSourceGraphStructs(&.{.{ .string = "missing/p4j2/filter.zap" }}));
    try testing.expectEqual(@as(usize, 0), interp.dependencies.items.len);
    try testing.expectEqual(@as(usize, 1), interp.errors.items.len);
    try testing.expectEqual(CtfeErrorKind.host_io_failure, interp.errors.items[0].kind);
}

test "P4J2: source_graph_structs frees path filter when dependency append fails" {
    var graph_arena = testArena();
    defer graph_arena.deinit();
    const graph_alloc = graph_arena.allocator();

    var interner = ast.StringInterner.init(graph_alloc);
    var graph = try scope.ScopeGraph.init(graph_alloc);

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var interp = try Interpreter.init(failing_allocator.allocator(), &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only.with(.reflect_source);
    interp.scope_graph = &graph;
    interp.interner = &interner;

    try testing.expectError(error.OutOfMemory, interp.builtinSourceGraphStructs(&.{.{ .string = "app.zap" }}));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), interp.dependencies.items.len);
}

test "P4J2: Interpreter.deinit frees reflected-source live dependency filter slice" {
    const alloc = testing.allocator;

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    var interp_initialized = true;
    defer if (interp_initialized) interp.deinit();

    const paths = try alloc.alloc([]const u8, 2);
    var paths_transferred = false;
    errdefer if (!paths_transferred) alloc.free(paths);
    paths[0] = "lib/config.zap";
    paths[1] = "lib/runtime.zap";

    try interp.dependencies.append(alloc, .{
        .reflected_source = .{ .paths = paths, .graph_hash = 0x1234 },
    });
    paths_transferred = true;

    interp.deinit();
    interp_initialized = false;
}

test "P4J2: CTFE extractStructRefName returns owned alias names" {
    const alloc = testing.allocator;

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const parts = [_]CtValue{
        .{ .atom = "Outer" },
        .{ .atom = "Inner" },
    };
    const tuple_elems = [_]CtValue{
        .{ .atom = "__aliases__" },
        .nil,
        .{ .list = .{ .alloc_id = 0, .elems = &parts } },
    };
    const alias_ref = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &tuple_elems } };

    const extracted_optional = try interp.extractStructRefName(alias_ref);
    try testing.expect(extracted_optional != null);
    const extracted = extracted_optional.?;
    defer extracted.deinit(alloc);

    try testing.expect(extracted == .owned);
    try testing.expectEqualStrings("Outer.Inner", extracted.bytes());
}

test "P4J2: CTFE extractStructRefName frees partial alias buffer on malformed tuple" {
    const alloc = testing.allocator;

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const parts = [_]CtValue{
        .{ .atom = "Outer" },
        .{ .string = "not-an-alias-segment" },
    };
    const tuple_elems = [_]CtValue{
        .{ .atom = "__aliases__" },
        .nil,
        .{ .list = .{ .alloc_id = 0, .elems = &parts } },
    };
    const malformed_alias_ref = CtValue{ .tuple = .{ .alloc_id = 0, .elems = &tuple_elems } };

    const extracted = try interp.extractStructRefName(malformed_alias_ref);
    try testing.expect(extracted == null);
}

test "P4J2: CTFE reflected-struct live dependencies own struct names" {
    const alloc = testing.allocator;

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    var interp_initialized = true;
    defer if (interp_initialized) interp.deinit();

    const owned_input_name = try alloc.dupe(u8, "Outer.Inner");
    defer alloc.free(owned_input_name);

    try interp.recordReflectedStructDependency(owned_input_name, 0x1234);
    try testing.expectEqual(@as(usize, 1), interp.dependencies.items.len);
    try testing.expect(interp.dependencies.items[0] == .reflected_struct);
    try testing.expectEqualStrings("Outer.Inner", interp.dependencies.items[0].reflected_struct.struct_name);
    try testing.expect(interp.dependencies.items[0].reflected_struct.struct_name.ptr != owned_input_name.ptr);

    interp.deinit();
    interp_initialized = false;
}

fn exerciseBuiltinStructTypesAllocationFailures(
    allocator: std.mem.Allocator,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
) !void {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(allocator, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only.with(.reflect_struct);
    interp.scope_graph = graph;
    interp.interner = interner;

    const result = try interp.builtinStructTypes(&.{.{ .string = "App" }});
    defer deinitOwnedCtValue(allocator, result);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 12), result.list.elems.len);
    try testing.expect(result.list.elems[0] == .atom);
    try testing.expectEqualStrings("Type00", result.list.elems[0].atom);
    try testing.expect(result.list.elems[11] == .atom);
    try testing.expectEqualStrings("Type11", result.list.elems[11].atom);
}

test "P4J2: Struct.types frees result list on allocation failure" {
    var graph_arena = testArena();
    defer graph_arena.deinit();
    const graph_alloc = graph_arena.allocator();

    var interner = ast.StringInterner.init(graph_alloc);
    const app_id = try interner.intern("App");

    var graph = try scope.ScopeGraph.init(graph_alloc);
    const app_scope = try graph.createScope(0, .struct_scope);
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const app_decl = try graph_alloc.create(ast.StructDecl);
    app_decl.* = .{
        .meta = .{ .span = span },
        .name = .{ .parts = &.{app_id}, .span = span },
        .items = &.{},
    };
    try graph.registerStruct(app_decl.name, app_scope, app_decl);

    const dummy_type_expr = try graph_alloc.create(ast.TypeExpr);
    dummy_type_expr.* = .{ .never = .{ .meta = .{ .span = span } } };
    const type_names = [_][]const u8{
        "Type00",
        "Type01",
        "Type02",
        "Type03",
        "Type04",
        "Type05",
        "Type06",
        "Type07",
        "Type08",
        "Type09",
        "Type10",
        "Type11",
    };
    for (type_names) |type_name| {
        const type_id = try interner.intern(type_name);
        _ = try graph.registerType(type_id, app_scope, .{ .type_alias = dummy_type_expr }, &.{});
    }

    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseBuiltinStructTypesAllocationFailures,
        .{ &graph, &interner },
    );
}

fn initP4J2ReflectionListFixture(
    alloc: std.mem.Allocator,
    graph: *scope.ScopeGraph,
    interner: *ast.StringInterner,
) !void {
    const app_id = try interner.intern("App");
    const main_id = try interner.intern("main");
    const config_id = try interner.intern("config");

    try graph.registerSourceFile(0, "app.zap");
    const app_scope = try graph.createScope(0, .struct_scope);
    const span = ast.SourceSpan{ .start = 0, .end = 3, .source_id = 0 };
    const app_decl = try alloc.create(ast.StructDecl);
    app_decl.* = .{
        .meta = .{ .span = span },
        .name = .{ .parts = &.{app_id}, .span = span },
        .items = &.{},
    };
    try graph.registerStruct(app_decl.name, app_scope, app_decl);
    _ = try graph.createFamily(app_scope, main_id, 1, .public);

    const computed_values = try alloc.alloc(ConstValue, 2);
    computed_values[0] = .{ .atom = "enabled" };
    computed_values[1] = .{ .int = 42 };
    try graph.structs.items[0].attributes.append(alloc, .{
        .name = config_id,
        .computed_value = .{ .list = computed_values },
    });
}

fn exerciseBuiltinSourceGraphStructsAllocationFailures(
    allocator: std.mem.Allocator,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
) !void {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(allocator, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only.with(.reflect_source);
    interp.scope_graph = graph;
    interp.interner = interner;

    const result = try interp.builtinSourceGraphStructs(&.{.{ .string = "app.zap" }});
    defer deinitOwnedCtValue(allocator, result);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.elems.len);
    try testing.expect(result.list.elems[0] == .tuple);
}

test "P4J2: SourceGraph.structs frees owned result list on allocation failure" {
    var graph_arena = testArena();
    defer graph_arena.deinit();
    const graph_alloc = graph_arena.allocator();

    var interner = ast.StringInterner.init(graph_alloc);
    var graph = try scope.ScopeGraph.init(graph_alloc);
    try initP4J2ReflectionListFixture(graph_alloc, &graph, &interner);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseBuiltinSourceGraphStructsAllocationFailures,
        .{ &graph, &interner },
    );
}

fn exerciseBuiltinReflectedStructFunctionsAllocationFailures(
    allocator: std.mem.Allocator,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
) !void {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(allocator, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only.with(.reflect_source);
    interp.scope_graph = graph;
    interp.interner = interner;

    const result = try interp.builtinReflectedStructFunctions(&.{.{ .string = "App" }});
    defer deinitOwnedCtValue(allocator, result);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.elems.len);
    try testing.expect(result.list.elems[0] == .map);
}

test "P4J2: reflected Struct.functions frees owned result list on allocation failure" {
    var graph_arena = testArena();
    defer graph_arena.deinit();
    const graph_alloc = graph_arena.allocator();

    var interner = ast.StringInterner.init(graph_alloc);
    var graph = try scope.ScopeGraph.init(graph_alloc);
    try initP4J2ReflectionListFixture(graph_alloc, &graph, &interner);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseBuiltinReflectedStructFunctionsAllocationFailures,
        .{ &graph, &interner },
    );
}

fn exerciseBuiltinStructFunctionsAllocationFailures(
    allocator: std.mem.Allocator,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
) !void {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(allocator, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only.with(.reflect_struct);
    interp.scope_graph = graph;
    interp.interner = interner;

    const result = try interp.builtinStructFunctions(&.{.{ .string = "App" }});
    defer deinitOwnedCtValue(allocator, result);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.elems.len);
    try testing.expect(result.list.elems[0] == .tuple);
}

test "P4J2: Struct.functions frees owned result list on allocation failure" {
    var graph_arena = testArena();
    defer graph_arena.deinit();
    const graph_alloc = graph_arena.allocator();

    var interner = ast.StringInterner.init(graph_alloc);
    var graph = try scope.ScopeGraph.init(graph_alloc);
    try initP4J2ReflectionListFixture(graph_alloc, &graph, &interner);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseBuiltinStructFunctionsAllocationFailures,
        .{ &graph, &interner },
    );
}

fn exerciseBuiltinStructAttributesAllocationFailures(
    allocator: std.mem.Allocator,
    graph: *scope.ScopeGraph,
    interner: *const ast.StringInterner,
) !void {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(allocator, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only.with(.reflect_struct);
    interp.scope_graph = graph;
    interp.interner = interner;

    const result = try interp.builtinStructAttributes(&.{.{ .string = "App" }});
    defer deinitOwnedCtValue(allocator, result);

    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.elems.len);
    try testing.expect(result.list.elems[0] == .tuple);
}

test "P4J2: Struct.attributes frees owned result list on allocation failure" {
    var graph_arena = testArena();
    defer graph_arena.deinit();
    const graph_alloc = graph_arena.allocator();

    var interner = ast.StringInterner.init(graph_alloc);
    var graph = try scope.ScopeGraph.init(graph_alloc);
    try initP4J2ReflectionListFixture(graph_alloc, &graph, &interner);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseBuiltinStructAttributesAllocationFailures,
        .{ &graph, &interner },
    );
}

test "reflection: SourceGraph.structs filters by source path" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const app_id = try interner.intern("App");

    var graph = try scope.ScopeGraph.init(alloc);
    try graph.registerSourceFile(0, "./app.zap");
    const app_scope = try graph.createScope(0, .struct_scope);

    const app_decl = try alloc.create(ast.StructDecl);
    app_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 3, .source_id = 0 } },
        .name = .{ .parts = &.{app_id}, .span = .{ .start = 0, .end = 3, .source_id = 0 } },
        .items = &.{},
    };
    try graph.registerStruct(app_decl.name, app_scope, app_decl);

    const func = ir.Function{
        .id = 0,
        .name = "reflect_structs",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "app.zap" } },
                .{ .call_builtin = .{ .dest = 1, .name = "source_graph_structs", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only.with(.reflect_source);
    interp.scope_graph = &graph;
    interp.interner = &interner;

    const result = try interp.evalFunction(0, &.{});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.elems.len);
    try testing.expect(result.list.elems[0] == .tuple);
    const struct_ref = result.list.elems[0].tuple;
    try testing.expectEqual(@as(usize, 3), struct_ref.elems.len);
    try testing.expect(struct_ref.elems[0] == .atom);
    try testing.expectEqualStrings("__aliases__", struct_ref.elems[0].atom);
    try testing.expect(struct_ref.elems[2] == .list);
    try testing.expectEqual(@as(usize, 1), struct_ref.elems[2].list.elems.len);
    try testing.expect(struct_ref.elems[2].list.elems[0] == .atom);
    try testing.expectEqualStrings("App", struct_ref.elems[2].list.elems[0].atom);
    try testing.expectEqual(@as(usize, 1), interp.dependencies.items.len);
    try testing.expect(interp.dependencies.items[0] == .reflected_source);
}

test "reflection: Struct.functions returns public function refs" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const app_id = try interner.intern("App");
    const main_id = try interner.intern("main");

    var graph = try scope.ScopeGraph.init(alloc);
    const app_scope = try graph.createScope(0, .struct_scope);
    const app_decl = try alloc.create(ast.StructDecl);
    app_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 3, .source_id = 0 } },
        .name = .{ .parts = &.{app_id}, .span = .{ .start = 0, .end = 3, .source_id = 0 } },
        .items = &.{},
    };
    try graph.registerStruct(app_decl.name, app_scope, app_decl);
    _ = try graph.createFamily(app_scope, main_id, 1, .public);

    const func = ir.Function{
        .id = 0,
        .name = "reflect_functions",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "App" } },
                .{ .call_builtin = .{ .dest = 1, .name = "struct_functions", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only.with(.reflect_source);
    interp.scope_graph = &graph;
    interp.interner = &interner;

    const result = try interp.evalFunction(0, &.{});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.elems.len);
    try testing.expect(result.list.elems[0] == .map);

    var found_name = false;
    var found_arity = false;
    for (result.list.elems[0].map.entries) |entry| {
        if (entry.key == .atom and std.mem.eql(u8, entry.key.atom, "name")) {
            try testing.expect(entry.value == .string);
            try testing.expectEqualStrings("main", entry.value.string);
            found_name = true;
        }
        if (entry.key == .atom and std.mem.eql(u8, entry.key.atom, "arity")) {
            try testing.expect(entry.value == .int);
            try testing.expectEqual(@as(i64, 1), entry.value.int);
            found_arity = true;
        }
    }
    try testing.expect(found_name);
    try testing.expect(found_arity);
}

test "P4J2: reflected source append guards free constructed values on allocation failure" {
    var setup_arena = testArena();
    defer setup_arena.deinit();
    const setup_alloc = setup_arena.allocator();

    var interner = ast.StringInterner.init(setup_alloc);
    const app_id = try interner.intern("App");

    var graph = try scope.ScopeGraph.init(setup_alloc);
    try graph.registerSourceFile(0, "app.zap");
    const app_scope = try graph.createScope(0, .struct_scope);
    const app_decl = try setup_alloc.create(ast.StructDecl);
    app_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 3, .source_id = 0 } },
        .name = .{ .parts = &.{app_id}, .span = .{ .start = 0, .end = 3, .source_id = 0 } },
        .items = &.{},
    };
    try graph.registerStruct(app_decl.name, app_scope, app_decl);

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.interner = &interner;

    const struct_ref = try interp.makeStructRef(graph.structs.items[0], "app.zap", 0);
    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try testing.expectError(error.OutOfMemory, appendOwnedCtValue(alloc, &result_list, struct_ref));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), result_list.items.len);
}

test "P4J2: reflected function append guard frees constructed map on allocation failure" {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const function_ref = try interp.makeFunctionRef("main", 1, .public);
    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try testing.expectError(error.OutOfMemory, appendOwnedCtValue(alloc, &result_list, function_ref));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), result_list.items.len);
}

test "P4J2: struct reflection append guard frees tuple and imported value on allocation failure" {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const computed_values = [_]ConstValue{.{ .int = 1 }};
    const imported_value = try Interpreter.importConstValue(alloc, .{ .list = &computed_values });
    const tuple_elems = try alloc.alloc(CtValue, 2);
    initCtValueSlots(tuple_elems);
    tuple_elems[0] = .{ .atom = "docs" };
    tuple_elems[1] = imported_value;
    const tuple_id = try interp.allocation_store.alloc(alloc, .tuple, interp.currentFunctionId());
    const tuple_value = CtValue{ .tuple = .{ .alloc_id = tuple_id, .elems = tuple_elems } };
    var result_list: std.ArrayListUnmanaged(CtValue) = .empty;
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try testing.expectError(error.OutOfMemory, appendOwnedCtValue(alloc, &result_list, tuple_value));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), result_list.items.len);
}

test "P4J2: Struct.put_attribute frees exported value when scope append fails" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();

    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();

    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const struct_name_id: ast.StringId = 1;
    const attr_name_id: ast.StringId = 2;
    const struct_name = ast.StructName{ .parts = &[_]ast.StringId{struct_name_id}, .span = span };
    var struct_decl = ast.StructDecl{
        .meta = .{ .span = span },
        .name = struct_name,
    };
    const struct_scope = try graph.createScope(graph.prelude_scope, .struct_scope);
    try graph.structs.append(alloc, .{
        .name = struct_name,
        .scope_id = struct_scope,
        .decl = &struct_decl,
    });

    const exported = try exportValue(alloc, .{ .string = "owned" });
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try testing.expectError(
        error.OutOfMemory,
        Interpreter.putExportedStructAttribute(alloc, &graph, &graph.structs.items[0], attr_name_id, exported),
    );
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), graph.structs.items[0].attributes.items.len);
}

test "P4J2: accumulating struct attribute import frees only shallow wrapper" {
    const alloc = testing.allocator;
    var graph = try scope.ScopeGraph.init(alloc);
    defer graph.deinit();

    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const struct_name_id: ast.StringId = 10;
    const attr_name_id: ast.StringId = 11;
    const struct_name = ast.StructName{ .parts = &[_]ast.StringId{struct_name_id}, .span = span };
    var struct_decl = ast.StructDecl{
        .meta = .{ .span = span },
        .name = struct_name,
    };
    const struct_scope = try graph.createScope(graph.prelude_scope, .struct_scope);
    try graph.structs.append(alloc, .{
        .name = struct_name,
        .scope_id = struct_scope,
        .decl = &struct_decl,
    });

    try graph.registerAccumulatingAttribute(&graph.structs.items[0], attr_name_id);
    try Interpreter.putExportedStructAttribute(
        alloc,
        &graph,
        &graph.structs.items[0],
        attr_name_id,
        try exportValue(alloc, .{ .string = "first" }),
    );
    try Interpreter.putExportedStructAttribute(
        alloc,
        &graph,
        &graph.structs.items[0],
        attr_name_id,
        try exportValue(alloc, .{ .string = "second" }),
    );

    const maybe_attribute_value = try graph.getStructAttribute(&graph.structs.items[0], attr_name_id);
    try testing.expect(maybe_attribute_value != null);
    var attribute_value = maybe_attribute_value.?;
    defer attribute_value.deinit(alloc);

    const imported = try Interpreter.importConstValue(alloc, attribute_value.value);
    defer deinitOwnedCtValue(alloc, imported);

    try testing.expect(imported == .list);
    try testing.expectEqual(@as(usize, 2), imported.list.elems.len);
    try testing.expectEqualStrings("first", imported.list.elems[0].string);
    try testing.expectEqualStrings("second", imported.list.elems[1].string);
}

test "P4J2: constant-call argument append frees aggregate value on allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();

    const arg_elements = try alloc.alloc(CtValue, 2);
    initCtValueSlots(arg_elements);
    arg_elements[0] = .{ .int = 1 };
    arg_elements[1] = .{ .int = 2 };
    const arg_value = CtValue{ .list = .{ .alloc_id = 0, .elems = arg_elements } };
    var ct_args: std.ArrayListUnmanaged(CtValue) = .empty;
    defer ct_args.deinit(alloc);
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try testing.expectError(error.OutOfMemory, appendOwnedCtValue(alloc, &ct_args, arg_value));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), ct_args.items.len);
}

test "P4J2: constant-call evalFunction releases temporary argument backing storage" {
    var setup_arena = testArena();
    defer setup_arena.deinit();
    const setup_alloc = setup_arena.allocator();

    var interner = ast.StringInterner.init(setup_alloc);
    const app_id = try interner.intern("App");
    const compute_id = try interner.intern("compute");
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const app_name = ast.StructName{ .parts = &.{app_id}, .span = span };

    const first_expr = try setup_alloc.create(ast.Expr);
    first_expr.* = .{ .int_literal = .{
        .meta = .{ .span = span },
        .value = 1,
    } };
    const second_expr = try setup_alloc.create(ast.Expr);
    second_expr.* = .{ .int_literal = .{
        .meta = .{ .span = span },
        .value = 2,
    } };
    const list_expr = try setup_alloc.create(ast.Expr);
    list_expr.* = .{ .list = .{
        .meta = .{ .span = span },
        .elements = &.{ first_expr, second_expr },
    } };
    const callee_expr = try setup_alloc.create(ast.Expr);
    callee_expr.* = .{ .var_ref = .{
        .meta = .{ .span = span },
        .name = compute_id,
    } };
    const call_expr = try setup_alloc.create(ast.Expr);
    call_expr.* = .{ .call = .{
        .meta = .{ .span = span },
        .callee = callee_expr,
        .args = &.{list_expr},
    } };

    const compute_fn = ir.Function{
        .id = 0,
        .name = "App__compute",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "values", .type_expr = .any }},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{compute_fn};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(testing.allocator, &program);
    defer interp.deinit();

    var temp_scope = ConstExprTempScope.init(testing.allocator);
    defer temp_scope.deinit();
    const result = try evaluateConstExpr(&temp_scope, &interp, call_expr, app_name, &interner);
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.elems.len);
}

test "interpreter: make_closure and call_closure" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    // Function 0: closure body — returns captured value + arg
    const closure_body = ir.Function{
        .id = 0,
        .name = "closure_body",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "y", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .capture_get = .{ .dest = 0, .index = 0 } }, // captured x
                .{ .param_get = .{ .dest = 1, .index = 0 } }, // arg y
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = true,
        .captures = &.{.{ .name = "x", .type_expr = .i64, .ownership = .shared }},
        .local_count = 3,
    };
    // Function 1: creates closure capturing x=10, calls it with y=5
    const outer = ir.Function{
        .id = 1,
        .name = "outer",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 10 } }, // x = 10
                .{ .make_closure = .{ .dest = 1, .function = 0, .captures = &.{0} } },
                .{ .const_int = .{ .dest = 2, .value = 5 } }, // y = 5
                .{ .call_closure = .{
                    .dest = 3,
                    .callee = 1,
                    .args = &.{2},
                    .arg_modes = &.{.share},
                    .return_type = .i64,
                } },
                .{ .ret = .{ .value = 3 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{ closure_body, outer };
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(1, &.{});
    try testing.expectEqual(@as(i64, 15), result.int); // 10 + 5
}

test "computed attribute cache setup reports mkdir host I/O failure" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "blocked",
        .data = "not a directory",
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    const blocked_cache_dir = try std.fs.path.join(alloc, &.{ tmp_path, "blocked", "ctfe" });

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var graph = try scope.ScopeGraph.init(alloc);
    var interner = ast.StringInterner.init(alloc);

    const all_result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, blocked_cache_dir, 0);
    try expectComputedAttributeCacheSetupHostIoFailure(all_result);

    const struct_order = [_][]const u8{};
    const ordered_result = try evaluateStructAttributesInOrder(alloc, &program, &graph, &interner, &struct_order, blocked_cache_dir, 0);
    try expectComputedAttributeCacheSetupHostIoFailure(ordered_result);

    const struct_result = try evaluateComputedAttributesForStruct(alloc, &program, &graph, &interner, "Foo", blocked_cache_dir, 0);
    try expectComputedAttributeCacheSetupHostIoFailure(struct_result);
}

test "computed attribute cache setup propagates OOM while recording mkdir failure" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "blocked",
        .data = "not a directory",
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    const blocked_cache_dir = try std.fs.path.join(alloc, &.{ tmp_path, "blocked", "ctfe" });

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var graph = try scope.ScopeGraph.init(alloc);
    var interner = ast.StringInterner.init(alloc);

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        evaluateComputedAttributes(failing_allocator.allocator(), &program, &graph, &interner, blocked_cache_dir, 0),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "evaluateComputedAttributes: call expression" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build an IR function: Foo__compute returns 42
    const compute_fn = ir.Function{
        .id = 0,
        .name = "Foo__compute",
        .scope_id = 1,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{compute_fn};
    const program = makeTestProgram(&functions);

    // Build a scope graph with a struct "Foo" and an attribute @config = compute()
    var graph = try scope.ScopeGraph.init(alloc);

    // Create struct scope (child of prelude)
    const mod_scope = try graph.createScope(0, .struct_scope);

    // Intern strings
    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const config_id = try interner.intern("config");
    const compute_id = try interner.intern("compute");

    // Build the AST call expression: compute()
    const callee_expr = try alloc.create(ast.Expr);
    callee_expr.* = .{ .var_ref = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = compute_id,
    } };
    const call_expr = try alloc.create(ast.Expr);
    call_expr.* = .{ .call = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .callee = callee_expr,
        .args = &.{},
    } };

    // Create a stub struct decl (needed for StructEntry)
    const mod_decl = try alloc.create(ast.StructDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    // Register the struct with the attribute
    try graph.structs.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });

    // Add the @config attribute with call expression value
    graph.structs.items[0].attributes.append(alloc, .{
        .name = config_id,
        .value = call_expr,
    }) catch {};

    // Run CTFE evaluation
    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 1), result.evaluated);
    try testing.expectEqual(@as(u32, 0), result.failed);

    // Verify the computed value was stored
    const attr = &graph.structs.items[0].attributes.items[0];
    try testing.expect(attr.computed_value != null);
    try testing.expectEqual(@as(i64, 42), attr.computed_value.?.int);
}

test "evaluateComputedAttributes: failing attribute records attribute context" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const compute_fn = ir.Function{
        .id = 0,
        .name = "Foo__compute",
        .scope_id = 1,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .const_int = .{ .dest = 1, .value = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .div, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{compute_fn};
    const program = makeTestProgram(&functions);

    var graph = try scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .struct_scope);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const config_id = try interner.intern("config");
    const compute_id = try interner.intern("compute");

    const callee_expr = try alloc.create(ast.Expr);
    callee_expr.* = .{ .var_ref = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = compute_id,
    } };
    const call_expr = try alloc.create(ast.Expr);
    call_expr.* = .{ .call = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .callee = callee_expr,
        .args = &.{},
    } };

    const mod_decl = try alloc.create(ast.StructDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.structs.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.structs.items[0].attributes.append(alloc, .{
        .name = config_id,
        .value = call_expr,
    }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 0), result.evaluated);
    try testing.expectEqual(@as(u32, 1), result.failed);
    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expect(result.errors[0].attribute_context != null);
    try testing.expectEqualStrings("config", result.errors[0].attribute_context.?.attr_name);
    try testing.expectEqualStrings("Foo", result.errors[0].attribute_context.?.struct_name);
}

test "evaluateComputedAttributes: binary expression value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);

    var graph = try scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .struct_scope);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const config_id = try interner.intern("config");

    const lhs = try alloc.create(ast.Expr);
    lhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 40 } };
    const rhs = try alloc.create(ast.Expr);
    rhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 2 } };
    const expr = try alloc.create(ast.Expr);
    expr.* = .{ .binary_op = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .op = .add,
        .lhs = lhs,
        .rhs = rhs,
    } };

    const mod_decl = try alloc.create(ast.StructDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.structs.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.structs.items[0].attributes.append(alloc, .{
        .name = config_id,
        .value = expr,
    }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 1), result.evaluated);
    try testing.expectEqual(@as(u32, 0), result.failed);
    try testing.expectEqual(@as(i64, 42), graph.structs.items[0].attributes.items[0].computed_value.?.int);
}

test "evaluateComputedAttributes: call expression with computed args" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const compute_fn = ir.Function{
        .id = 0,
        .name = "Foo__compute",
        .scope_id = 1,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{compute_fn};
    const program = makeTestProgram(&functions);

    var graph = try scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .struct_scope);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const config_id = try interner.intern("config");
    const compute_id = try interner.intern("compute");

    const lhs = try alloc.create(ast.Expr);
    lhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 40 } };
    const rhs = try alloc.create(ast.Expr);
    rhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 2 } };
    const arg_expr = try alloc.create(ast.Expr);
    arg_expr.* = .{ .binary_op = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .op = .add,
        .lhs = lhs,
        .rhs = rhs,
    } };

    const callee_expr = try alloc.create(ast.Expr);
    callee_expr.* = .{ .var_ref = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = compute_id,
    } };
    const call_expr = try alloc.create(ast.Expr);
    call_expr.* = .{ .call = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .callee = callee_expr,
        .args = &.{arg_expr},
    } };

    const mod_decl = try alloc.create(ast.StructDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.structs.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.structs.items[0].attributes.append(alloc, .{
        .name = config_id,
        .value = call_expr,
    }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 1), result.evaluated);
    try testing.expectEqual(@as(u32, 0), result.failed);
    try testing.expectEqual(@as(i64, 42), graph.structs.items[0].attributes.items[0].computed_value.?.int);
}

test "evaluateComputedAttributes: attr_ref can use earlier computed attribute" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);

    var graph = try scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .struct_scope);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const base_id = try interner.intern("base");
    const config_id = try interner.intern("config");

    const base_expr = try alloc.create(ast.Expr);
    base_expr.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 40 } };

    const attr_ref_expr = try alloc.create(ast.Expr);
    attr_ref_expr.* = .{ .attr_ref = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = base_id,
    } };
    const rhs = try alloc.create(ast.Expr);
    rhs.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 2 } };
    const config_expr = try alloc.create(ast.Expr);
    config_expr.* = .{ .binary_op = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .op = .add,
        .lhs = attr_ref_expr,
        .rhs = rhs,
    } };

    const mod_decl = try alloc.create(ast.StructDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.structs.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.structs.items[0].attributes.append(alloc, .{ .name = base_id, .value = base_expr }) catch {};
    graph.structs.items[0].attributes.append(alloc, .{ .name = config_id, .value = config_expr }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 2), result.evaluated);
    try testing.expectEqual(@as(u32, 0), result.failed);
    try testing.expectEqual(@as(i64, 42), graph.structs.items[0].attributes.items[1].computed_value.?.int);
}

test "tryEvalAttribute: literal int value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);

    var graph = try scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .struct_scope);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const port_id = try interner.intern("port");

    // Build literal expression: 8080
    const lit_expr = try alloc.create(ast.Expr);
    lit_expr.* = .{ .int_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = 8080 } };

    const mod_decl = try alloc.create(ast.StructDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.structs.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.structs.items[0].attributes.append(alloc, .{
        .name = port_id,
        .value = lit_expr,
    }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 1), result.evaluated);

    const attr = &graph.structs.items[0].attributes.items[0];
    try testing.expect(attr.computed_value != null);
    try testing.expectEqual(@as(i64, 8080), attr.computed_value.?.int);
}

test "tryEvalAttribute: literal string value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);

    var graph = try scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .struct_scope);

    var interner = ast.StringInterner.init(alloc);
    const foo_id = try interner.intern("Foo");
    const name_id = try interner.intern("app_name");
    const val_id = try interner.intern("myapp");

    const lit_expr = try alloc.create(ast.Expr);
    lit_expr.* = .{ .string_literal = .{ .meta = .{ .span = .{ .start = 0, .end = 0 } }, .value = val_id } };

    const mod_decl = try alloc.create(ast.StructDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };

    try graph.structs.append(alloc, .{
        .name = .{ .parts = &.{foo_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.structs.items[0].attributes.append(alloc, .{
        .name = name_id,
        .value = lit_expr,
    }) catch {};

    const result = try evaluateComputedAttributes(alloc, &program, &graph, &interner, null, 0);
    try testing.expectEqual(@as(u32, 1), result.evaluated);

    const attr = &graph.structs.items[0].attributes.items[0];
    try testing.expect(attr.computed_value != null);
    try testing.expectEqualStrings("myapp", attr.computed_value.?.string);
}

test "evaluateConstExpr: struct_ref produces Type value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);

    var graph = try scope.ScopeGraph.init(alloc);
    const app_scope = try graph.createScope(0, .struct_scope);

    var interner = ast.StringInterner.init(alloc);
    const app_id = try interner.intern("App");

    const app_decl = try alloc.create(ast.StructDecl);
    app_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{app_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };
    try graph.registerStruct(app_decl.name, app_scope, app_decl);

    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.scope_graph = &graph;
    interp.interner = &interner;

    const expr = try alloc.create(ast.Expr);
    expr.* = .{ .struct_ref = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = app_decl.name,
    } };

    var temp_scope = ConstExprTempScope.init(alloc);
    defer temp_scope.deinit();
    const result = try evaluateConstExpr(&temp_scope, &interp, expr, app_decl.name, &interner);
    try testing.expect(result == .struct_val);
    try testing.expectEqualStrings("Type", result.struct_val.type_name);
    try testing.expectEqual(@as(usize, 1), result.struct_val.fields.len);
    try testing.expectEqualStrings("name", result.struct_val.fields[0].name);
    try testing.expect(result.struct_val.fields[0].value == .atom);
    try testing.expectEqualStrings("App", result.struct_val.fields[0].value.atom);
}

test "evaluateConstExpr rejects excessive AST recursion depth" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const Parser = @import("parser.zig").Parser;
    var parser = try Parser.init(alloc, "1 + (2 + (3 + 4))");
    defer parser.deinit();
    const expr = try parser.parseExpr();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.const_expr_recursion_limit = 2;

    var temp_scope = ConstExprTempScope.init(alloc);
    defer temp_scope.deinit();
    try testing.expectError(error.CtfeFailed, evaluateConstExpr(&temp_scope, &interp, expr, null, parser.interner));
    try testing.expect(interp.errors.items.len > 0);
    try testing.expectEqual(CtfeErrorKind.recursion_limit_exceeded, interp.errors.items[0].kind);
    try testing.expect(std.mem.indexOf(u8, interp.errors.items[0].message, "constant expression recursion limit exceeded") != null);
}

test "evaluateConstExpr: qualified callee name allocation OOM propagates" {
    var arena = testArena();
    defer arena.deinit();
    const setup_alloc = arena.allocator();

    var interner = ast.StringInterner.init(setup_alloc);
    const app_id = try interner.intern("App");
    const compute_id = try interner.intern("compute");
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const app_parts = [_]ast.StringId{app_id};
    const app_name = ast.StructName{ .parts = &app_parts, .span = span };

    const object_expr = try setup_alloc.create(ast.Expr);
    object_expr.* = .{ .struct_ref = .{
        .meta = .{ .span = span },
        .name = app_name,
    } };
    const callee_expr = try setup_alloc.create(ast.Expr);
    callee_expr.* = .{ .field_access = .{
        .meta = .{ .span = span },
        .object = object_expr,
        .field = compute_id,
    } };
    const call_expr = try setup_alloc.create(ast.Expr);
    call_expr.* = .{ .call = .{
        .meta = .{ .span = span },
        .callee = callee_expr,
        .args = &.{},
    } };

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(setup_alloc, &program);
    defer interp.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var temp_scope = ConstExprTempScope.init(failing_allocator.allocator());
    defer temp_scope.deinit();
    try testing.expectError(
        error.OutOfMemory,
        evaluateConstExpr(&temp_scope, &interp, call_expr, app_name, &interner),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "evaluateConstExpr: unresolved callee remains not computable" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const app_id = try interner.intern("App");
    const compute_id = try interner.intern("compute");
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const app_parts = [_]ast.StringId{app_id};
    const app_name = ast.StructName{ .parts = &app_parts, .span = span };

    const object_expr = try alloc.create(ast.Expr);
    object_expr.* = .{ .int_literal = .{
        .meta = .{ .span = span },
        .value = 1,
    } };
    const callee_expr = try alloc.create(ast.Expr);
    callee_expr.* = .{ .field_access = .{
        .meta = .{ .span = span },
        .object = object_expr,
        .field = compute_id,
    } };
    const call_expr = try alloc.create(ast.Expr);
    call_expr.* = .{ .call = .{
        .meta = .{ .span = span },
        .callee = callee_expr,
        .args = &.{},
    } };

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    var temp_scope = ConstExprTempScope.init(alloc);
    defer temp_scope.deinit();
    try testing.expectError(error.NotComputable, evaluateConstExpr(&temp_scope, &interp, call_expr, app_name, &interner));
}

test "evaluateConstExpr: constant-call evalFunction OOM propagates" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const app_id = try interner.intern("App");
    const compute_id = try interner.intern("compute");
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const app_name = ast.StructName{ .parts = &.{app_id}, .span = span };

    const callee_expr = try alloc.create(ast.Expr);
    callee_expr.* = .{ .var_ref = .{
        .meta = .{ .span = span },
        .name = compute_id,
    } };
    const call_expr = try alloc.create(ast.Expr);
    call_expr.* = .{ .call = .{
        .meta = .{ .span = span },
        .callee = callee_expr,
        .args = &.{},
    } };

    const func = ir.Function{
        .id = 0,
        .name = "App__compute",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &.{},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_allocator = interp.allocator;
    interp.allocator = failing_allocator.allocator();
    defer interp.allocator = original_allocator;

    var temp_scope = ConstExprTempScope.init(alloc);
    defer temp_scope.deinit();
    try testing.expectError(error.OutOfMemory, evaluateConstExpr(&temp_scope, &interp, call_expr, app_name, &interner));
    try testing.expect(failing_allocator.has_induced_failure);
}

test "evaluateConstExpr: constant-call semantic failure maps to CtfeFailed" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const app_id = try interner.intern("App");
    const compute_id = try interner.intern("compute");
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const app_name = ast.StructName{ .parts = &.{app_id}, .span = span };

    const callee_expr = try alloc.create(ast.Expr);
    callee_expr.* = .{ .var_ref = .{
        .meta = .{ .span = span },
        .name = compute_id,
    } };
    const call_expr = try alloc.create(ast.Expr);
    call_expr.* = .{ .call = .{
        .meta = .{ .span = span },
        .callee = callee_expr,
        .args = &.{},
    } };

    const func = ir.Function{
        .id = 0,
        .name = "App__compute",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .const_int = .{ .dest = 1, .value = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .div, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    var temp_scope = ConstExprTempScope.init(alloc);
    defer temp_scope.deinit();
    try testing.expectError(error.CtfeFailed, evaluateConstExpr(&temp_scope, &interp, call_expr, app_name, &interner));
    try testing.expectEqual(@as(usize, 1), interp.errors.items.len);
    try testing.expectEqual(CtfeErrorKind.division_by_zero, interp.errors.items[0].kind);
}

test "evaluateConstExpr: function_ref produces Function value with narrowed arity" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);

    var graph = try scope.ScopeGraph.init(alloc);
    const app_scope = try graph.createScope(0, .struct_scope);

    var interner = ast.StringInterner.init(alloc);
    const app_id = try interner.intern("App");
    const target_id = try interner.intern("target");

    const app_decl = try alloc.create(ast.StructDecl);
    app_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{app_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };
    try graph.registerStruct(app_decl.name, app_scope, app_decl);
    _ = try graph.createFamily(app_scope, target_id, 44, .public);

    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.scope_graph = &graph;
    interp.interner = &interner;

    const expr = try alloc.create(ast.Expr);
    expr.* = .{ .function_ref = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .struct_name = null,
        .function = target_id,
        .arity = 300,
    } };

    var temp_scope = ConstExprTempScope.init(alloc);
    defer temp_scope.deinit();
    const result = try evaluateConstExpr(&temp_scope, &interp, expr, app_decl.name, &interner);
    try testing.expect(result == .struct_val);
    try testing.expectEqualStrings("Function", result.struct_val.type_name);
    try testing.expectEqual(@as(usize, 3), result.struct_val.fields.len);
    try testing.expectEqualStrings("struct", result.struct_val.fields[0].name);
    try testing.expect(result.struct_val.fields[0].value == .struct_val);
    try testing.expectEqualStrings("Type", result.struct_val.fields[0].value.struct_val.type_name);
    try testing.expectEqualStrings("name", result.struct_val.fields[1].name);
    try testing.expect(result.struct_val.fields[1].value == .atom);
    try testing.expectEqualStrings("target", result.struct_val.fields[1].value.atom);
    try testing.expectEqualStrings("arity", result.struct_val.fields[2].name);
    try testing.expect(result.struct_val.fields[2].value == .int);
    try testing.expectEqual(@as(i64, 44), result.struct_val.fields[2].value.int);
}

test "interpreter: field_set on struct" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "field_set_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .const_int = .{ .dest = 1, .value = 2 } },
                .{ .struct_init = .{
                    .dest = 2,
                    .type_name = "S",
                    .fields = &.{
                        .{ .name = "a", .value = 0 },
                        .{ .name = "b", .value = 1 },
                    },
                } },
                .{ .const_int = .{ .dest = 3, .value = 99 } },
                .{ .field_set = .{ .object = 2, .field = "b", .value = 3 } },
                .{ .field_get = .{ .dest = 4, .object = 2, .field = "b" } },
                .{ .ret = .{ .value = 4 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 99), result.int);
}

fn exerciseFieldSetMapReplacementAllocations(allocator: std.mem.Allocator) !void {
    const original_list_elems = try allocator.alloc(CtValue, 1);
    defer allocator.free(original_list_elems);
    original_list_elems[0] = .{ .int = 7 };

    const original_entries = try allocator.alloc(CtValue.CtMapEntry, 1);
    defer allocator.free(original_entries);
    original_entries[0] = .{
        .key = .{ .atom = "existing" },
        .value = .{ .list = .{ .alloc_id = 1, .elems = original_list_elems } },
    };

    const replacement_entries = try rebuildMapEntriesForFieldSet(
        allocator,
        original_entries,
        "added",
        .{ .int = 99 },
    );
    defer allocator.free(replacement_entries);

    try testing.expectEqual(@as(usize, 1), original_entries.len);
    try testing.expectEqual(@as(usize, 1), original_entries[0].value.list.elems.len);
    try testing.expectEqual(@as(i64, 7), original_entries[0].value.list.elems[0].int);

    try testing.expectEqual(@as(usize, 2), replacement_entries.len);
    try testing.expectEqualStrings("existing", replacement_entries[0].key.atom);
    try testing.expectEqual(@as(i64, 7), replacement_entries[0].value.list.elems[0].int);
    try testing.expectEqualStrings("added", replacement_entries[1].key.string);
    try testing.expectEqual(@as(i64, 99), replacement_entries[1].value.int);
}

test "P4J2: field_set map replacement uses exact slice and preserves original on OOM" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseFieldSetMapReplacementAllocations,
        .{},
    );
}

fn expectAggregateConstructorAllocIdFailureCleansPayload(
    instruction: ir.Instruction,
    source_values: []const CtValue,
    local_count: u32,
) !void {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(testing.allocator, &program);
    defer interp.deinit();

    const function = ir.Function{
        .id = 0,
        .name = "aggregate_constructor_alloc_id_failure_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{},
        .is_closure = false,
        .captures = &.{},
        .local_count = local_count,
    };
    var frame = try Frame.init(testing.allocator, &function, &.{});
    defer frame.deinit(testing.allocator);

    for (source_values, 0..) |source_value, index| {
        frame.setLocal(@intCast(index), source_value);
    }

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const original_allocator = interp.allocator;
    interp.allocator = failing_allocator.allocator();
    defer interp.allocator = original_allocator;

    try testing.expectError(error.OutOfMemory, interp.execOneInstruction(instruction, &frame));
    try testing.expect(failing_allocator.has_induced_failure);
}

fn expectAggregateConstructorCtfeFailureCleansPayload(
    instruction: ir.Instruction,
    source_values: []const CtValue,
    local_count: u32,
    expected_error_kind: CtfeErrorKind,
) !void {
    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(testing.allocator, &program);
    defer interp.deinit();

    const function = ir.Function{
        .id = 0,
        .name = "aggregate_constructor_read_failure_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{},
        .is_closure = false,
        .captures = &.{},
        .local_count = local_count,
    };
    var frame = try Frame.init(testing.allocator, &function, &.{});
    defer frame.deinit(testing.allocator);

    for (source_values, 0..) |source_value, index| {
        frame.setLocal(@intCast(index), source_value);
    }

    try testing.expectError(error.CtfeFailure, interp.execOneInstruction(instruction, &frame));
    try testing.expectEqual(@as(usize, 1), interp.errors.items.len);
    try testing.expectEqual(expected_error_kind, interp.errors.items[0].kind);
}

test "P4J2: aggregate constructors clean payload when alloc id allocation fails" {
    const nested_list_elems = try testing.allocator.alloc(CtValue, 1);
    nested_list_elems[0] = .{ .int = 11 };
    const nested_list = CtValue{ .list = .{ .alloc_id = 77, .elems = nested_list_elems } };
    defer deinitOwnedCtValue(testing.allocator, nested_list);

    const tuple_elements = [_]ir.LocalId{0};
    try expectAggregateConstructorAllocIdFailureCleansPayload(
        .{ .tuple_init = .{ .dest = 1, .elements = &tuple_elements } },
        &.{nested_list},
        2,
    );

    const list_elements = [_]ir.LocalId{0};
    try expectAggregateConstructorAllocIdFailureCleansPayload(
        .{ .list_init = .{ .dest = 1, .elements = &list_elements } },
        &.{.{ .int = 1 }},
        2,
    );

    try expectAggregateConstructorAllocIdFailureCleansPayload(
        .{ .list_cons = .{ .dest = 2, .head = 0, .tail = 1 } },
        &.{ .{ .int = 1 }, .nil },
        3,
    );

    const map_entries = [_]ir.MapEntry{.{ .key = 0, .value = 1 }};
    try expectAggregateConstructorAllocIdFailureCleansPayload(
        .{ .map_init = .{ .dest = 2, .entries = &map_entries } },
        &.{ .{ .atom = "key" }, .{ .int = 1 } },
        3,
    );

    const struct_fields = [_]ir.StructFieldInit{.{ .name = "field", .value = 0 }};
    try expectAggregateConstructorAllocIdFailureCleansPayload(
        .{ .struct_init = .{ .dest = 1, .type_name = "Box", .fields = &struct_fields } },
        &.{.{ .int = 1 }},
        2,
    );

    try expectAggregateConstructorAllocIdFailureCleansPayload(
        .{ .union_init = .{ .dest = 1, .union_type = "Maybe", .variant_name = "Some", .value = 0 } },
        &.{.{ .int = 1 }},
        2,
    );
}

test "P4J2: aggregate constructors clean payload when local read fails" {
    const map_entries = [_]ir.MapEntry{.{ .key = 0, .value = 1 }};
    try expectAggregateConstructorCtfeFailureCleansPayload(
        .{ .map_init = .{ .dest = 2, .entries = &map_entries } },
        &.{ .consumed, .{ .int = 1 } },
        3,
        .use_after_consume,
    );

    const struct_fields = [_]ir.StructFieldInit{.{ .name = "field", .value = 0 }};
    try expectAggregateConstructorCtfeFailureCleansPayload(
        .{ .struct_init = .{ .dest = 1, .type_name = "Box", .fields = &struct_fields } },
        &.{.consumed},
        2,
        .use_after_consume,
    );

    try expectAggregateConstructorCtfeFailureCleansPayload(
        .{ .union_init = .{ .dest = 1, .union_type = "Maybe", .variant_name = "Some", .value = 0 } },
        &.{.consumed},
        2,
        .use_after_consume,
    );
}

test "P4J2: aggregate constructor cleans payload when local transfer fails" {
    const list_elements = [_]ir.LocalId{0};
    try expectAggregateConstructorCtfeFailureCleansPayload(
        .{ .list_init = .{ .dest = 2, .elements = &list_elements } },
        &.{.{ .int = 1 }},
        1,
        .unsupported_instruction,
    );
}

test "interpreter: field_set appends map key" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "field_set_map_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "existing" } },
                .{ .const_int = .{ .dest = 1, .value = 7 } },
                .{ .map_init = .{
                    .dest = 2,
                    .entries = &.{
                        .{ .key = 0, .value = 1 },
                    },
                } },
                .{ .const_int = .{ .dest = 3, .value = 99 } },
                .{ .field_set = .{ .object = 2, .field = "added", .value = 3 } },
                .{ .field_get = .{ .dest = 4, .object = 2, .field = "added" } },
                .{ .ret = .{ .value = 4 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 99), result.int);
}

test "interpreter: bin_len_check" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "bin_fn",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "data", .type_expr = .string }},
        .return_type = .bool_type,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .bin_len_check = .{ .dest = 1, .scrutinee = 0, .min_len = 3 } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const r1 = try interp.evalFunction(0, &.{.{ .string = "hello" }});
    try testing.expect(r1.bool_val); // 5 >= 3

    interp.steps_remaining = interp.step_budget;
    const r2 = try interp.evalFunction(0, &.{.{ .string = "ab" }});
    try testing.expect(!r2.bool_val); // 2 < 3
}

test "interpreter: bin_match_prefix" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "prefix_fn",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "data", .type_expr = .string }},
        .return_type = .bool_type,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .bin_match_prefix = .{ .dest = 1, .source = 0, .offset = .{ .static = 0 }, .expected = "hel" } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const r1 = try interp.evalFunction(0, &.{.{ .string = "hello" }});
    try testing.expect(r1.bool_val);

    interp.steps_remaining = interp.step_budget;
    const r2 = try interp.evalFunction(0, &.{.{ .string = "world" }});
    try testing.expect(!r2.bool_val);
}

test "interpreter: bin_slice" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "slice_fn",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "data", .type_expr = .string }},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .bin_slice = .{ .dest = 1, .source = 0, .offset = .{ .static = 6 }, .length = null } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{.{ .string = "hello world" }});
    try testing.expectEqualStrings("world", result.string);
}

test "memoization: cache hit on second call" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "expensive",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .const_int = .{ .dest = 1, .value = 1 } },
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    // First call — executes function body, consumes steps
    const r1 = try interp.evalFunction(0, &.{.{ .int = 10 }});
    try testing.expectEqual(@as(i64, 11), r1.int);
    const steps_after_first = interp.steps_remaining;

    // Second call with same args — should hit cache, no steps consumed
    const r2 = try interp.evalFunction(0, &.{.{ .int = 10 }});
    try testing.expectEqual(@as(i64, 11), r2.int);
    try testing.expectEqual(steps_after_first, interp.steps_remaining);

    // Third call with different args — cache miss, steps consumed
    const r3 = try interp.evalFunction(0, &.{.{ .int = 20 }});
    try testing.expectEqual(@as(i64, 21), r3.int);
    try testing.expect(interp.steps_remaining < steps_after_first);
}

test "memoization: insertion OOM propagates" {
    const func = ir.Function{
        .id = 0,
        .name = "memo_insert_oom",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 7 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(testing.allocator, &program);
    defer interp.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    const original_allocator = interp.allocator;
    interp.allocator = failing_allocator.allocator();
    defer interp.allocator = original_allocator;

    try testing.expectError(error.OutOfMemory, interp.evalFunction(0, &.{}));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(u32, 0), interp.memo_cache.count());
}

fn memoOwnershipTestKey() CacheKey {
    return .{
        .function_id = 0,
        .function_hash = 0x1111,
        .args_hash = 0x2222,
        .capability_flags = CapabilitySet.pure_only.flags,
        .options_hash = 0x3333,
    };
}

test "memoization: cache replacement and teardown free memo-owned payloads" {
    const alloc = testing.allocator;
    const program = makeTestProgram(&.{});
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const original_fields = [_]CtValue.CtFieldValue{
        .{ .name = "label", .value = .{ .string = "original" } },
        .{ .name = "state", .value = .{ .atom = "ready" } },
    };
    const original_value = CtValue{ .struct_val = .{
        .alloc_id = 0,
        .type_name = "OriginalMemoValue",
        .fields = &original_fields,
    } };
    const original_memoized = try interp.putMemoizedCtValue(memoOwnershipTestKey(), original_value);
    try testing.expectEqualStrings("OriginalMemoValue", original_memoized.struct_val.type_name);
    try testing.expectEqualStrings("original", original_memoized.struct_val.fields[0].value.string);

    const replacement_elems = [_]CtValue{
        .{ .string = "replacement" },
        .{ .atom = "done" },
    };
    const replacement_value = CtValue{ .list = .{
        .alloc_id = 0,
        .elems = &replacement_elems,
    } };
    const replacement_memoized = try interp.putMemoizedCtValue(memoOwnershipTestKey(), replacement_value);

    try testing.expectEqual(@as(u32, 1), interp.memo_cache.count());
    try testing.expect(replacement_memoized == .list);
    try testing.expectEqualStrings("replacement", replacement_memoized.list.elems[0].string);
    try testing.expectEqualStrings("done", replacement_memoized.list.elems[1].atom);
}

fn exerciseMemoizeCtValueAllocationFailures(allocator: std.mem.Allocator) !void {
    const program = makeTestProgram(&.{});
    var interp = try Interpreter.init(allocator, &program);
    defer interp.deinit();

    const optional_payload = CtValue{ .string = "payload" };
    const union_payload = CtValue{ .atom = "some" };
    const captures = [_]CtValue{
        .{ .string = "captured" },
        .{ .optional = .{ .value = &optional_payload } },
    };
    const fields = [_]CtValue.CtFieldValue{
        .{ .name = "name", .value = .{ .string = "memo" } },
        .{ .name = "variant", .value = .{ .union_val = .{
            .alloc_id = 0,
            .type_name = "Maybe",
            .variant = "some",
            .payload = &union_payload,
        } } },
        .{ .name = "callback", .value = .{ .closure = .{
            .alloc_id = 0,
            .function_id = 0,
            .captures = &captures,
        } } },
    };
    const value = CtValue{ .struct_val = .{
        .alloc_id = 0,
        .type_name = "MemoAllocationFailureValue",
        .fields = &fields,
    } };

    _ = try interp.putMemoizedCtValue(memoOwnershipTestKey(), value);
}

test "memoization: insert frees partial memo-owned clone on allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseMemoizeCtValueAllocationFailures,
        .{},
    );
}

test "CtValue.hash consistency" {
    const a = CtValue{ .int = 42 };
    const b = CtValue{ .int = 42 };
    const c = CtValue{ .int = 43 };
    try testing.expectEqual(try a.hash(testing.allocator), try b.hash(testing.allocator));
    try testing.expect(try a.hash(testing.allocator) != try c.hash(testing.allocator));

    const s1 = CtValue{ .string = "hello" };
    const s2 = CtValue{ .string = "hello" };
    const s3 = CtValue{ .string = "world" };
    try testing.expectEqual(try s1.hash(testing.allocator), try s2.hash(testing.allocator));
    try testing.expect(try s1.hash(testing.allocator) != try s3.hash(testing.allocator));
}

test "persistent cache: serialize/deserialize round-trip" {
    const alloc = testing.allocator;

    // Test integer
    {
        const result = CtEvalResult{
            .value = .{ .int = 42 },
            .dependencies = &.{},
            .result_hash = 12345,
        };
        const data = try serializeResult(alloc, result);
        defer alloc.free(data);
        const restored = try deserializeResult(alloc, data);
        try testing.expectEqual(@as(i64, 42), restored.value.int);
        try testing.expectEqual(@as(u64, 12345), restored.result_hash);
    }

    // Test string
    {
        const result = CtEvalResult{
            .value = .{ .string = "hello" },
            .dependencies = &.{},
            .result_hash = 67890,
        };
        const data = try serializeResult(alloc, result);
        defer alloc.free(data);
        const restored = try deserializeResult(alloc, data);
        try testing.expectEqualStrings("hello", restored.value.string);
        alloc.free(restored.value.string);
    }

    // Test bool
    {
        const result = CtEvalResult{
            .value = .{ .bool_val = true },
            .dependencies = &.{},
            .result_hash = 0,
        };
        const data = try serializeResult(alloc, result);
        defer alloc.free(data);
        const restored = try deserializeResult(alloc, data);
        try testing.expect(restored.value.bool_val);
    }

    // Test nil
    {
        const result = CtEvalResult{
            .value = .nil,
            .dependencies = &.{},
            .result_hash = 0,
        };
        const data = try serializeResult(alloc, result);
        defer alloc.free(data);
        const restored = try deserializeResult(alloc, data);
        try testing.expect(restored.value == .nil);
    }
}

test "persistent cache load returns null for absent entry only" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(cache_dir);

    const cache = PersistentCache.init(cache_dir);
    const loaded = try cache.load(alloc, 0xabc);
    try testing.expect(loaded == null);
}

test "persistent cache load propagates allocation failure" {
    const cache = PersistentCache.init(".zap-cache/ctfe");
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    try testing.expectError(error.OutOfMemory, cache.load(failing_allocator.allocator(), 0xabc));
    try testing.expect(failing_allocator.has_induced_failure);
}

test "persistent cache load classifies oversized reads" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(cache_dir);
    const cache = PersistentCache.init(cache_dir);
    const key: u64 = 0x1234;
    const cache_path = try cache.entryPath(alloc, key);
    defer alloc.free(cache_path);

    const large_data = try alloc.alloc(u8, 1024 * 1024 + 1);
    defer alloc.free(large_data);
    @memset(large_data, 'x');
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = cache_path,
        .data = large_data,
    });

    try testing.expectError(error.ReadFailure, cache.load(alloc, key));
}

test "persistent cache load classifies corrupt serialized entries" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(cache_dir);
    const cache = PersistentCache.init(cache_dir);
    const key: u64 = 0x5678;
    const cache_path = try cache.entryPath(alloc, key);
    defer alloc.free(cache_path);

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = cache_path,
        .data = "not a ctfe cache entry",
    });

    try testing.expectError(error.CorruptEntry, cache.load(alloc, key));
}

test "persistent cache load classifies trailing garbage as corrupt entry" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(cache_dir);
    const cache = PersistentCache.init(cache_dir);
    const key: u64 = 0x9abc;
    const cache_path = try cache.entryPath(alloc, key);
    defer alloc.free(cache_path);

    const result = CtEvalResult{
        .value = .{ .string = "cached" },
        .dependencies = &.{},
        .result_hash = 0xfeed_beef,
    };
    const data = try serializeResult(alloc, result);
    defer alloc.free(data);

    const corrupt_data = try alloc.alloc(u8, data.len + 4);
    defer alloc.free(corrupt_data);
    @memcpy(corrupt_data[0..data.len], data);
    @memcpy(corrupt_data[data.len..], "junk");

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = cache_path,
        .data = corrupt_data,
    });

    const loaded = cache.load(alloc, key) catch |err| {
        try testing.expectEqual(error.CorruptEntry, err);
        return;
    };
    if (loaded) |cached_result| {
        deinitCachedEvalResult(alloc, cached_result);
    }
    try testing.expect(false);
}

fn expectTruncatedDependencyDeserializeCleansPayloads(dependency: CtDependency) !void {
    const alloc = testing.allocator;
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(alloc);

    try serializeDependencyInto(alloc, &data, dependency);
    var pos: usize = 0;
    try testing.expectError(
        error.UnexpectedEndOfData,
        deserializeDependency(alloc, data.items[0 .. data.items.len - 1], &pos),
    );
}

test "deserializeDependency frees payloads on truncated trailing fields" {
    try expectTruncatedDependencyDeserializeCleansPayloads(.{
        .file = .{ .path = "lib/config.zap", .content_hash = 0x1111 },
    });
    try expectTruncatedDependencyDeserializeCleansPayloads(.{
        .env_var = .{ .name = "DATABASE_URL", .value_hash = 0x2222, .present = true },
    });
    try expectTruncatedDependencyDeserializeCleansPayloads(.{
        .glob = .{ .pattern = "lib/**/*.zap", .result_hash = 0x3333 },
    });
    try expectTruncatedDependencyDeserializeCleansPayloads(.{
        .reflected_struct = .{ .struct_name = "Config", .interface_hash = 0x4444 },
    });

    const reflected_paths = [_][]const u8{ "lib/config.zap", "lib/runtime.zap" };
    try expectTruncatedDependencyDeserializeCleansPayloads(.{
        .reflected_source = .{ .paths = &reflected_paths, .graph_hash = 0x5555 },
    });
}

test "deserializeConstValue frees partial aggregate on truncated data" {
    const alloc = testing.allocator;
    const values = [_]ConstValue{
        .{ .string = "first" },
        .{ .string = "second" },
    };
    const value = ConstValue{ .list = &values };
    const data = try serializeConstValue(alloc, value);
    defer alloc.free(data);

    var pos: usize = 0;
    try testing.expectError(
        error.UnexpectedEndOfData,
        deserializeConstValue(alloc, data[0 .. data.len - 1], &pos),
    );
}

test "deserializeConstValue frees struct type name when field count is truncated" {
    const alloc = testing.allocator;
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(alloc);

    try data.append(alloc, CONST_TAG_STRUCT);
    try appendLengthPrefixedBytes(alloc, &data, "CacheEntry");

    var pos: usize = 0;
    try testing.expectError(error.UnexpectedEndOfData, deserializeConstValue(alloc, data.items, &pos));
}

test "deserializeResult frees value and dependencies when dependency payload is truncated" {
    const alloc = testing.allocator;
    const deps = [_]CtDependency{
        .{ .file = .{ .path = "lib/config.zap", .content_hash = 0x1234 } },
        .{ .env_var = .{ .name = "DATABASE_URL", .value_hash = 0x5678, .present = true } },
    };
    const result = CtEvalResult{
        .value = .{ .string = "cached" },
        .dependencies = &deps,
        .result_hash = 0x9999,
    };
    const data = try serializeResult(alloc, result);
    defer alloc.free(data);

    try testing.expectError(error.UnexpectedEndOfData, deserializeResult(alloc, data[0 .. data.len - 1]));
}

test "deserializeResult rejects trailing garbage" {
    const alloc = testing.allocator;
    const result = CtEvalResult{
        .value = .{ .string = "cached" },
        .dependencies = &.{},
        .result_hash = 0x1234,
    };
    const data = try serializeResult(alloc, result);
    defer alloc.free(data);

    const corrupt_data = try alloc.alloc(u8, data.len + 4);
    defer alloc.free(corrupt_data);
    @memcpy(corrupt_data[0..data.len], data);
    @memcpy(corrupt_data[data.len..], "junk");

    const restored = deserializeResult(alloc, corrupt_data) catch |err| {
        try testing.expectEqual(error.TrailingData, err);
        return;
    };
    deinitCachedEvalResult(alloc, restored);
    try testing.expect(false);
}

test "cloneDependency frees reflected_source paths on allocation failure" {
    const paths = [_][]const u8{ "lib/config.zap", "lib/runtime.zap" };
    const dependency = CtDependency{
        .reflected_source = .{ .paths = &paths, .graph_hash = 0x7777 },
    };
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });

    try testing.expectError(error.OutOfMemory, cloneDependency(failing_allocator.allocator(), dependency));
    try testing.expect(failing_allocator.has_induced_failure);
}

test "cloneDependencies frees partial dependency array on allocation failure" {
    const reflected_paths = [_][]const u8{ "lib/config.zap", "lib/runtime.zap" };
    const deps = [_]CtDependency{
        .{ .file = .{ .path = "build.zap", .content_hash = 0x1111 } },
        .{ .reflected_source = .{ .paths = &reflected_paths, .graph_hash = 0x2222 } },
    };
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 4 });

    try testing.expectError(error.OutOfMemory, cloneDependencies(failing_allocator.allocator(), &deps));
    try testing.expect(failing_allocator.has_induced_failure);
}

test "persistent cache store propagates serialization allocation failure" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(cache_dir);
    const cache = PersistentCache.init(cache_dir);
    const result = CtEvalResult{
        .value = .{ .int = 42 },
        .dependencies = &.{},
        .result_hash = 42,
    };

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, cache.store(failing_allocator.allocator(), 0x42, result));
    try testing.expect(failing_allocator.has_induced_failure);
}

test "persistent cache store preserves existing entry when atomic publish fails" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(cache_dir);
    const cache = PersistentCache.init(cache_dir);
    const key: u64 = 0x5151;
    const existing_result = CtEvalResult{
        .value = .{ .int = 1 },
        .dependencies = &.{},
        .result_hash = 1,
    };
    const replacement_result = CtEvalResult{
        .value = .{ .int = 2 },
        .dependencies = &.{},
        .result_hash = 2,
    };
    try cache.store(alloc, key, existing_result);

    const replacement_bytes = try serializeResult(alloc, replacement_result);
    defer alloc.free(replacement_bytes);

    const FailingAtomicWriter = struct {
        calls: usize = 0,
        bytes_len: usize = 0,

        fn writeFileAtomic(
            self: *@This(),
            file_allocator: std.mem.Allocator,
            path: []const u8,
            contents: []const u8,
        ) !void {
            _ = file_allocator;
            _ = path;
            self.calls += 1;
            self.bytes_len = contents.len;
            return error.AccessDenied;
        }
    };

    var writer = FailingAtomicWriter{};
    try testing.expectError(
        error.HostIoFailure,
        cache.storeWithFileWriter(alloc, key, replacement_result, &writer),
    );
    try testing.expectEqual(@as(usize, 1), writer.calls);
    try testing.expectEqual(replacement_bytes.len, writer.bytes_len);

    const loaded_result = (try cache.load(alloc, key)).?;
    defer deinitCachedEvalResult(alloc, loaded_result);
    try testing.expectEqual(@as(i64, 1), loaded_result.value.int);
    try testing.expectEqual(@as(u64, 1), loaded_result.result_hash);
}

test "persistent cache store propagates directory creation failure" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "blocked",
        .data = "not a directory",
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(tmp_path);
    const blocked_cache_dir = try std.fs.path.join(alloc, &.{ tmp_path, "blocked", "ctfe" });
    defer alloc.free(blocked_cache_dir);

    const cache = PersistentCache.init(blocked_cache_dir);
    const result = CtEvalResult{
        .value = .{ .int = 42 },
        .dependencies = &.{},
        .result_hash = 42,
    };

    try testing.expectError(error.HostIoFailure, cache.store(alloc, 0x42, result));
}

test "persistent cache store propagates entry create failure" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(cache_dir);
    const cache = PersistentCache.init(cache_dir);
    const key: u64 = 0;
    const cache_path = try cache.entryPath(alloc, key);
    defer alloc.free(cache_path);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, cache_path);

    const result = CtEvalResult{
        .value = .{ .int = 42 },
        .dependencies = &.{},
        .result_hash = 42,
    };

    try testing.expectError(error.HostIoFailure, cache.store(alloc, key, result));
}

test "persistent cache key includes option hash" {
    const key_a = PersistentCache.cacheKeyFor("manifest", 999, 123, CapabilitySet.build.flags, 111);
    const key_b = PersistentCache.cacheKeyFor("manifest", 999, 123, CapabilitySet.build.flags, 222);

    try testing.expect(key_a != key_b);
}

test "function identity hash changes when function body changes" {
    const func_a = ir.Function{
        .id = 0,
        .name = "f",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{ .{ .const_int = .{ .dest = 0, .value = 1 } }, .{ .ret = .{ .value = 0 } } },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const func_b = ir.Function{
        .id = 0,
        .name = "f",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{ .{ .const_int = .{ .dest = 0, .value = 2 } }, .{ .ret = .{ .value = 0 } } },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };

    try testing.expect(hashFunctionIdentity(&func_a) != hashFunctionIdentity(&func_b));
}

test "persistent cache key includes function identity hash" {
    const key_a = PersistentCache.cacheKeyFor("manifest", 111, 123, CapabilitySet.build.flags, 999);
    const key_b = PersistentCache.cacheKeyFor("manifest", 222, 123, CapabilitySet.build.flags, 999);

    try testing.expect(key_a != key_b);
}

fn persistentCacheKeyForEvalTest(interp: *Interpreter, func: *const ir.Function, args: []const CtValue) !u64 {
    const args_hash = try interp.hashArgs(args);
    return PersistentCache.cacheKeyFor(
        func.name,
        hashFunctionIdentity(func),
        args_hash,
        interp.capabilities.flags,
        hashEvaluationOptions(interp.compile_options_hash, interp.build_opts),
    );
}

const FreedAllocationTracker = struct {
    const FreedRange = struct {
        start: usize,
        len: usize,
    };

    backing_allocator: std.mem.Allocator,
    freed_ranges: [4096]FreedRange = undefined,
    freed_range_count: usize = 0,
    overflowed: bool = false,

    fn init(backing_allocator: std.mem.Allocator) FreedAllocationTracker {
        return .{ .backing_allocator = backing_allocator };
    }

    fn allocator(self: *FreedAllocationTracker) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *FreedAllocationTracker = @ptrCast(@alignCast(ctx));
        const memory = self.backing_allocator.rawAlloc(len, alignment, return_address) orelse return null;
        self.forgetReallocatedRange(@intFromPtr(memory), len);
        return memory;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *FreedAllocationTracker = @ptrCast(@alignCast(ctx));
        const resized = self.backing_allocator.rawResize(memory, alignment, new_len, return_address);
        if (resized) self.forgetReallocatedRange(@intFromPtr(memory.ptr), new_len);
        return resized;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *FreedAllocationTracker = @ptrCast(@alignCast(ctx));
        const remapped = self.backing_allocator.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        self.forgetReallocatedRange(@intFromPtr(remapped), new_len);
        return remapped;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *FreedAllocationTracker = @ptrCast(@alignCast(ctx));
        self.rememberFreedRange(memory);
        self.backing_allocator.rawFree(memory, alignment, return_address);
    }

    fn rememberFreedRange(self: *FreedAllocationTracker, memory: []u8) void {
        if (memory.len == 0) return;
        if (self.freed_range_count == self.freed_ranges.len) {
            self.overflowed = true;
            return;
        }
        self.freed_ranges[self.freed_range_count] = .{
            .start = @intFromPtr(memory.ptr),
            .len = memory.len,
        };
        self.freed_range_count += 1;
    }

    fn forgetReallocatedRange(self: *FreedAllocationTracker, start: usize, len: usize) void {
        if (len == 0) return;
        var index: usize = 0;
        while (index < self.freed_range_count) {
            const range = self.freed_ranges[index];
            if (rangesOverlap(start, len, range.start, range.len)) {
                self.freed_range_count -= 1;
                self.freed_ranges[index] = self.freed_ranges[self.freed_range_count];
            } else {
                index += 1;
            }
        }
    }

    fn wasFreed(self: *const FreedAllocationTracker, bytes: []const u8) bool {
        if (bytes.len == 0) return false;
        const start = @intFromPtr(bytes.ptr);
        for (self.freed_ranges[0..self.freed_range_count]) |range| {
            if (rangeContains(range.start, range.len, start, bytes.len)) return true;
        }
        return false;
    }

    fn rangesOverlap(left_start: usize, left_len: usize, right_start: usize, right_len: usize) bool {
        const left_end = left_start + left_len;
        const right_end = right_start + right_len;
        return left_start < right_end and right_start < left_end;
    }

    fn rangeContains(range_start: usize, range_len: usize, value_start: usize, value_len: usize) bool {
        const range_end = range_start + range_len;
        const value_end = value_start + value_len;
        return range_start <= value_start and value_end <= range_end;
    }
};

test "persistent cache: top-level eval stores result" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const cache = PersistentCache.init(cache_dir);
    const func = ir.Function{
        .id = 0,
        .name = "top_level_store",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const program = makeTestProgram(&.{func});
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.persistent_cache = cache;

    const cache_key = try persistentCacheKeyForEvalTest(&interp, &func, &.{});
    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 42), result.int);

    const cached_result = (try cache.load(alloc, cache_key)).?;
    defer deinitCachedEvalResult(alloc, cached_result);
    try testing.expectEqual(@as(i64, 42), cached_result.value.int);
    try testing.expectEqual(@as(usize, 0), cached_result.dependencies.len);
    try testing.expect(cached_result.result_hash != 0);
}

test "persistent cache: hit memoizes owned value independent of loaded result" {
    var tracker = FreedAllocationTracker.init(testing.allocator);
    const alloc = tracker.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(cache_dir);
    const cache = PersistentCache.init(cache_dir);
    const func = ir.Function{
        .id = 0,
        .name = "persistent_hit_lifetime",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "body-result" } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const program = makeTestProgram(&.{func});
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.persistent_cache = cache;

    const cache_key = try persistentCacheKeyForEvalTest(&interp, &func, &.{});
    const cached_fields = [_]ConstValue.ConstFieldValue{
        .{ .name = "label", .value = .{ .string = "cached-result" } },
        .{ .name = "state", .value = .{ .atom = "ready" } },
    };
    const cached_result = CtEvalResult{
        .value = .{ .struct_val = .{
            .type_name = "CachedPersistentValue",
            .fields = &cached_fields,
        } },
        .dependencies = &.{},
        .result_hash = 0xfeed_beef,
    };
    try cache.store(alloc, cache_key, cached_result);

    const result = try interp.evalFunction(0, &.{});
    try testing.expect(result == .struct_val);
    try testing.expectEqualStrings("CachedPersistentValue", result.struct_val.type_name);
    try testing.expectEqualStrings("label", result.struct_val.fields[0].name);
    try testing.expectEqualStrings("cached-result", result.struct_val.fields[0].value.string);
    try testing.expectEqualStrings("state", result.struct_val.fields[1].name);
    try testing.expectEqualStrings("ready", result.struct_val.fields[1].value.atom);

    try testing.expectEqual(@as(u32, 1), interp.memo_cache.count());
    try testing.expect(!tracker.wasFreed(result.struct_val.type_name));
    try testing.expect(!tracker.wasFreed(result.struct_val.fields[0].name));
    try testing.expect(!tracker.wasFreed(result.struct_val.fields[0].value.string));
    try testing.expect(!tracker.wasFreed(result.struct_val.fields[1].name));
    try testing.expect(!tracker.wasFreed(result.struct_val.fields[1].value.atom));
    try testing.expect(!tracker.overflowed);
}

test "persistent cache: nested eval does not store nested result" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const cache = PersistentCache.init(cache_dir);
    const inner = ir.Function{
        .id = 0,
        .name = "nested_store_inner",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 7 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const outer = ir.Function{
        .id = 1,
        .name = "nested_store_outer",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .call_direct = .{ .dest = 0, .function = 0, .args = &.{}, .arg_modes = &.{} } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{ inner, outer };
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.persistent_cache = cache;

    const outer_cache_key = try persistentCacheKeyForEvalTest(&interp, &outer, &.{});
    const inner_cache_key = try persistentCacheKeyForEvalTest(&interp, &inner, &.{});
    const result = try interp.evalFunction(1, &.{});
    try testing.expectEqual(@as(i64, 7), result.int);

    const cached_outer = (try cache.load(alloc, outer_cache_key)).?;
    defer deinitCachedEvalResult(alloc, cached_outer);
    try testing.expectEqual(@as(i64, 7), cached_outer.value.int);
    try testing.expect(try cache.load(alloc, inner_cache_key) == null);
}

test "persistent cache: top-level store failure propagates from evalFunction" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const func = ir.Function{
        .id = 0,
        .name = "top_level_store_failure",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 99 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const program = makeTestProgram(&.{func});
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const cache_dir = try std.fs.path.join(alloc, &.{ tmp_path, "ctfe-cache" });
    const cache = PersistentCache.init(cache_dir);
    interp.persistent_cache = cache;

    const stale_dependency = CtDependency{ .file = .{ .path = "ctfe-store-failure-missing-dependency", .content_hash = 0 } };
    const stale_result = CtEvalResult{
        .value = .{ .int = 1 },
        .dependencies = &.{stale_dependency},
        .result_hash = 1,
    };
    const cache_key = try persistentCacheKeyForEvalTest(&interp, &func, &.{});
    try cache.store(alloc, cache_key, stale_result);
    try std.Io.Dir.cwd().setFilePermissions(std.Options.debug_io, cache_dir, std.Io.File.Permissions.fromMode(0o555), .{});
    defer std.Io.Dir.cwd().setFilePermissions(std.Options.debug_io, cache_dir, std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

    try testing.expectError(error.CtfeFailure, interp.evalFunction(0, &.{}));
    try testing.expectEqual(@as(usize, 1), interp.errors.items.len);
    try testing.expectEqual(CtfeErrorKind.host_io_failure, interp.errors.items[0].kind);
    try testing.expect(std.mem.indexOf(u8, interp.errors.items[0].message, "persistent CTFE cache store host I/O failed") != null);

    const preserved_result = (try cache.load(alloc, cache_key)).?;
    defer deinitCachedEvalResult(alloc, preserved_result);
    try testing.expectEqual(@as(i64, 1), preserved_result.value.int);
    try testing.expectEqual(@as(u64, 1), preserved_result.result_hash);
}

test "capability enforcement: File.read without read_file" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    // Function that calls File.read builtin
    const func = ir.Function{
        .id = 0,
        .name = "read_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "test.txt" } },
                .{ .call_builtin = .{ .dest = 1, .name = "File.read", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only; // NO read_file

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expect(interp.errors.items.len > 0);
    try testing.expectEqual(CtfeErrorKind.capability_violation, interp.errors.items[0].kind);
}

test "capability enforcement: System.get_env without read_env" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "env_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "HOME" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_env", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.pure_only;

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.capability_violation, interp.errors.items[0].kind);
}

test "dependency tracking: env read records dependency" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "env_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "CTFE_TEST_VAR" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_env", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.build; // has read_env

    _ = try interp.evalFunction(0, &.{});
    // Should have recorded an env_var dependency
    try testing.expect(interp.dependencies.items.len > 0);
    try testing.expect(interp.dependencies.items[0] == .env_var);
}

test "File.read returns nil and records dependency for missing file" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.build;

    const missing_path = ".zig-cache/ctfe-gap9-definitely-missing-file.txt";
    const result = try interp.builtinFileRead(&.{.{ .string = missing_path }});

    try testing.expect(result == .nil);
    try testing.expectEqual(@as(usize, 1), interp.dependencies.items.len);
    try testing.expect(interp.dependencies.items[0] == .file);
    try testing.expectEqualStrings(missing_path, interp.dependencies.items[0].file.path);
    try testing.expectEqual(@as(u64, 0), interp.dependencies.items[0].file.content_hash);
}

test "File.read propagates read allocation OOM" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.build;

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_allocator = interp.allocator;
    interp.allocator = failing_allocator.allocator();
    defer interp.allocator = original_allocator;

    try testing.expectError(error.OutOfMemory, interp.builtinFileRead(&.{.{ .string = "src/ctfe.zig" }}));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), interp.dependencies.items.len);
}

test "P4J2: Prim.glob propagates collection OutOfMemory" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.build;

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_allocator = interp.allocator;
    interp.allocator = failing_allocator.allocator();
    defer interp.allocator = original_allocator;

    try testing.expectError(error.OutOfMemory, interp.builtinPrimitiveGlob(&.{.{ .string = "src/ctfe.zig" }}));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), interp.dependencies.items.len);
}

test "P4J2: Prim.glob reports filesystem failures as host IO failure" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink(std.Options.debug_io, "loop.zap", "loop.zap", .{});
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    const loop_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "loop.zap" });
    defer testing.allocator.free(loop_path);

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.build;

    try testing.expectError(error.CtfeFailure, interp.builtinPrimitiveGlob(&.{.{ .string = loop_path }}));
    try testing.expectEqual(@as(usize, 1), interp.errors.items.len);
    try testing.expectEqual(CtfeErrorKind.host_io_failure, interp.errors.items[0].kind);
    try testing.expectEqual(@as(usize, 0), interp.dependencies.items.len);
}

test "dependency tracking propagates append OOM" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const functions = [_]ir.Function{};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.build;

    const env_name = "CTFE_GAP9_DEPENDENCY_APPEND_OOM_SHOULD_NOT_EXIST_1D6B7035";
    if (env.getenvRuntime(env_name) != null) return error.SkipZigTest;

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_allocator = interp.allocator;
    interp.allocator = failing_allocator.allocator();
    defer interp.allocator = original_allocator;

    try testing.expectError(error.OutOfMemory, interp.builtinGetEnv(&.{.{ .string = env_name }}));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), interp.dependencies.items.len);
}

test "ownership: use after move fails" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "move_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .move_value = .{ .dest = 1, .source = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.use_after_consume, interp.errors.items[0].kind);
}

test "ownership: use after release fails" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "release_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .release = .{ .value = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.use_after_consume, interp.errors.items[0].kind);
}

test "ownership: binary_op on moved value fails" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "move_binary_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 40 } },
                .{ .move_value = .{ .dest = 1, .source = 0 } },
                .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.use_after_consume, interp.errors.items[0].kind);
}

test "ownership: retain on moved value fails" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "retain_move_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .move_value = .{ .dest = 1, .source = 0 } },
                .{ .retain = .{ .value = 0 } },
                .{ .ret = .{ .value = null } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.use_after_consume, interp.errors.items[0].kind);
}

test "ownership: reset returns reuse token for aggregate and reuse_alloc consumes it" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "reuse_token_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .bool_type,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .list_init = .{ .dest = 1, .elements = &.{0} } },
                .{ .reset = .{ .dest = 2, .source = 1 } },
                .{ .reuse_alloc = .{ .dest = 3, .token = 2, .constructor_tag = 0, .dest_type = .any } },
                .{ .local_get = .{ .dest = 4, .source = 2 } },
                .{ .ret = .{ .value = 4 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.use_after_consume, interp.errors.items[0].kind);
}

test "ownership: reuse_alloc rejects non-token value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "bad_reuse_token_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .reuse_alloc = .{ .dest = 1, .token = 0, .constructor_tag = 0, .dest_type = .any } },
                .{ .ret = .{ .value = null } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, result);
    try testing.expectEqual(CtfeErrorKind.type_error, interp.errors.items[0].kind);
}

test "symbolic memory: reuse preserves alloc id for matching aggregate kind" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "reuse_preserve_alloc_id_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .list_init = .{ .dest = 1, .elements = &.{0} } },
                .{ .reset = .{ .dest = 2, .source = 1 } },
                .{ .reuse_alloc = .{ .dest = 3, .token = 2, .constructor_tag = 0, .dest_type = .any } },
                .{ .list_init = .{ .dest = 3, .elements = &.{0} } },
                .{ .ret = .{ .value = 3 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(u32, 1), interp.allocation_store.count());
    try testing.expectEqual(@as(AllocId, 1), result.list.alloc_id);
}

test "symbolic memory: reuse falls back to fresh alloc for mismatched kind" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "reuse_kind_mismatch_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .list_init = .{ .dest = 1, .elements = &.{0} } },
                .{ .reset = .{ .dest = 2, .source = 1 } },
                .{ .reuse_alloc = .{ .dest = 3, .token = 2, .constructor_tag = 0, .dest_type = .any } },
                .{ .tuple_init = .{ .dest = 3, .elements = &.{0} } },
                .{ .ret = .{ .value = 3 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expect(result == .tuple);
    try testing.expectEqual(@as(u32, 2), interp.allocation_store.count());
    try testing.expectEqual(@as(AllocId, 2), result.tuple.alloc_id);
}

test "symbolic memory: fresh aggregate allocations get distinct alloc ids" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "alloc_ids_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .list_init = .{ .dest = 1, .elements = &.{0} } },
                .{ .list_init = .{ .dest = 2, .elements = &.{0} } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    _ = try interp.evalFunction(0, &.{});
    try testing.expect(interp.allocation_store.count() >= 2);
}

fn exerciseEvalAndExportAggregateArgAllocationFailures(
    allocator: std.mem.Allocator,
    env_name: []const u8,
    aggregate_arg: ConstValue,
) !void {
    const func = ir.Function{
        .id = 0,
        .name = "export_aggregate_arg_cleanup_fn",
        .scope_id = 0,
        .arity = 2,
        .params = &.{
            .{ .name = "env_name", .type_expr = .string },
            .{ .name = "value", .type_expr = .any },
        },
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_env", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .param_get = .{ .dest = 2, .index = 1 } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(allocator, &program);
    defer interp.deinit();

    const result = try interp.evalAndExport(
        0,
        &.{ .{ .string = env_name }, aggregate_arg },
        CapabilitySet.build,
    );
    defer deinitCachedEvalResult(allocator, result);

    try testing.expect(result.value == .tuple);
    try testing.expectEqual(@as(usize, 2), result.value.tuple.len);
    try testing.expectEqual(@as(i64, 41), result.value.tuple[0].int);
    try testing.expect(result.value.tuple[1] == .list);
    try testing.expectEqual(@as(usize, 1), result.dependencies.len);
    try testing.expect(result.dependencies[0] == .env_var);
}

test "evalAndExport frees imported aggregate args on allocation failure" {
    const env_name = "CTFE_P4J2_EVAL_AND_EXPORT_ARG_CLEANUP_DOES_NOT_EXIST_0D0448E8";
    if (env.getenvRuntime(env_name) != null) return error.SkipZigTest;

    const list_items = [_]ConstValue{
        .{ .atom = "nested" },
        .{ .int = 42 },
    };
    const tuple_items = [_]ConstValue{
        .{ .int = 41 },
        .{ .list = &list_items },
    };
    const aggregate_arg = ConstValue{ .tuple = &tuple_items };

    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseEvalAndExportAggregateArgAllocationFailures,
        .{ env_name, aggregate_arg },
    );
}

test "evalAndExport returns CtEvalResult" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "export_fn",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .i64 }},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalAndExport(0, &.{.{ .int = 99 }}, CapabilitySet.pure_only);
    try testing.expectEqual(@as(i64, 99), result.value.int);
    try testing.expect(result.result_hash != 0);
}

test "evalAndExport copies dependency slice out of interpreter storage" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const func = ir.Function{
        .id = 0,
        .name = "export_dep_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "CTFE_TEST_VAR" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_env", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalAndExport(0, &.{}, CapabilitySet.build);
    try testing.expect(result.dependencies.len > 0);
    try testing.expect(result.dependencies[0] == .env_var);
    try testing.expect(result.dependencies.ptr != interp.dependencies.items.ptr);
}

test "rich diagnostics: formatCtfeError" {
    const alloc = testing.allocator;
    const err = CtfeError{
        .message = "step limit exceeded",
        .kind = .step_limit_exceeded,
        .call_stack = &.{
            .{ .function_name = "Config__generate", .function_id = 0, .instruction_index = 0, .source_span = .{ .start = 10, .end = 20, .line = 12, .col = 4 } },
        },
        .attribute_context = .{ .attr_name = "config", .struct_name = "App" },
    };
    const formatted = try formatCtfeError(alloc, err);
    defer alloc.free(formatted);
    // Verify it contains the key pieces
    try testing.expect(std.mem.find(u8, formatted, "step limit exceeded") != null);
    try testing.expect(std.mem.find(u8, formatted, "Config__generate") != null);
    try testing.expect(std.mem.find(u8, formatted, "12:4") != null);
    try testing.expect(std.mem.find(u8, formatted, "@config") != null);
    try testing.expect(std.mem.find(u8, formatted, "App") != null);
    try testing.expect(std.mem.find(u8, formatted, "help:") != null);
}

fn exerciseCloneCtfeErrorsAllocationFailures(allocator: std.mem.Allocator) !void {
    const source_errors = [_]CtfeError{
        .{
            .message = "first failure",
            .kind = .type_error,
            .call_stack = &.{
                .{ .function_name = "First__run", .function_id = 1, .instruction_index = 2, .source_span = .{ .start = 3, .end = 4 } },
            },
            .attribute_context = .{ .attr_name = "doc", .struct_name = "First" },
        },
        .{
            .message = "second failure",
            .kind = .host_io_failure,
            .call_stack = &.{
                .{ .function_name = "Second__run", .function_id = 5, .instruction_index = 8, .source_span = .{ .start = 13, .end = 21 } },
            },
            .attribute_context = .{ .attr_name = "config", .struct_name = "Second" },
        },
    };

    const cloned_errors = try cloneCtfeErrors(allocator, &source_errors);
    defer deinitClonedCtfeErrors(allocator, cloned_errors);

    try testing.expectEqual(@as(usize, 2), cloned_errors.len);
    try testing.expectEqualStrings("first failure", cloned_errors[0].message);
    try testing.expectEqualStrings("Second", cloned_errors[1].attribute_context.?.struct_name);
}

test "cloneCtfeErrors frees partial clones on allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseCloneCtfeErrorsAllocationFailures,
        .{},
    );
}

test "cache key includes explicit compile options hash" {
    var build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer build_opts.deinit(testing.allocator);

    const native_debug = hashEvaluationOptions(hashCompileOptions("native", "debug"), build_opts);
    const wasm_debug = hashEvaluationOptions(hashCompileOptions("wasm32", "debug"), build_opts);

    try testing.expect(native_debug != wasm_debug);
}

test "validateDependencies: no deps returns true" {
    const alloc = testing.allocator;
    try testing.expect(try PersistentCache.validateDependencies(alloc, &.{}, null, null));
}

test "validateDependencies: env_var absent stays absent" {
    const alloc = testing.allocator;
    // A dependency on an env var that was absent — should validate if still absent
    const deps = [_]CtDependency{
        .{ .env_var = .{ .name = "CTFE_TEST_NONEXISTENT_VAR_12345", .value_hash = 0, .present = false } },
    };
    try testing.expect(try PersistentCache.validateDependencies(alloc, &deps, null, null));
}

test "validateDependencies: file read OOM propagates" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "dependency.txt", .data = "current" });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(tmp_path);
    const dependency_path = try std.fs.path.join(alloc, &.{ tmp_path, "dependency.txt" });
    defer alloc.free(dependency_path);

    const deps = [_]CtDependency{
        .{ .file = .{ .path = dependency_path, .content_hash = std.hash.Wyhash.hash(0, "current") } },
    };
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        PersistentCache.validateDependencies(failing_allocator.allocator(), &deps, null, null),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "validateDependencies: missing file invalidates cached result" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(tmp_path);
    const dependency_path = try std.fs.path.join(alloc, &.{ tmp_path, "missing.txt" });
    defer alloc.free(dependency_path);

    const deps = [_]CtDependency{
        .{ .file = .{ .path = dependency_path, .content_hash = 0 } },
    };
    try testing.expect(!try PersistentCache.validateDependencies(alloc, &deps, null, null));
}

test "P4J2: validateDependencies oversized file dependency propagates StreamTooLong" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var file = try tmp_dir.dir.createFile(std.Options.debug_io, "too-large.txt", .{});
    errdefer file.close(std.Options.debug_io);
    try file.setLength(std.Options.debug_io, 10 * 1024 * 1024 + 1);
    file.close(std.Options.debug_io);

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(tmp_path);
    const dependency_path = try std.fs.path.join(alloc, &.{ tmp_path, "too-large.txt" });
    defer alloc.free(dependency_path);

    const deps = [_]CtDependency{
        .{ .file = .{ .path = dependency_path, .content_hash = 0 } },
    };
    try testing.expectError(
        error.StreamTooLong,
        PersistentCache.validateDependencies(alloc, &deps, null, null),
    );
}

test "validateDependencies: glob collection OOM propagates" {
    const deps = [_]CtDependency{
        .{ .glob = .{ .pattern = "build.zig", .result_hash = 0 } },
    };
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        PersistentCache.validateDependencies(failing_allocator.allocator(), &deps, null, null),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: validateDependencies glob collection propagates filesystem errors" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink(std.Options.debug_io, "loop.zap", "loop.zap", .{});
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(tmp_path);
    const dependency_path = try std.fs.path.join(alloc, &.{ tmp_path, "loop.zap" });
    defer alloc.free(dependency_path);

    const deps = [_]CtDependency{
        .{ .glob = .{ .pattern = dependency_path, .result_hash = 0 } },
    };
    try testing.expectError(
        error.SymLinkLoop,
        PersistentCache.validateDependencies(alloc, &deps, null, null),
    );
}

test "validateDependencies: reflected_struct invalidates without graph" {
    const alloc = testing.allocator;
    const deps = [_]CtDependency{
        .{ .reflected_struct = .{ .struct_name = "Test", .interface_hash = 0 } },
    };
    try testing.expect(!try PersistentCache.validateDependencies(alloc, &deps, null, null));
}

test "validateDependencies: reflected_struct validates against matching graph" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = try scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .struct_scope);
    var interner = ast.StringInterner.init(alloc);
    const test_id = try interner.intern("Test");

    const mod_decl = try alloc.create(ast.StructDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{test_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };
    try graph.structs.append(alloc, .{
        .name = .{ .parts = &.{test_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });

    const iface_hash = try computeStructInterfaceHash(alloc, &graph, mod_scope, &interner, "Test");
    const deps = [_]CtDependency{
        .{ .reflected_struct = .{ .struct_name = "Test", .interface_hash = iface_hash } },
    };
    try testing.expect(try PersistentCache.validateDependencies(alloc, &deps, &graph, &interner));
}

test "validateDependencies: reflected_struct invalidates on interface change" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = try scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .struct_scope);
    var interner = ast.StringInterner.init(alloc);
    const test_id = try interner.intern("Test");
    const config_id = try interner.intern("config");

    const mod_decl = try alloc.create(ast.StructDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{test_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };
    try graph.structs.append(alloc, .{
        .name = .{ .parts = &.{test_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });
    graph.structs.items[0].attributes.append(alloc, .{
        .name = config_id,
        .computed_value = .{ .int = 1 },
    }) catch {};

    const iface_hash = try computeStructInterfaceHash(alloc, &graph, mod_scope, &interner, "Test");
    const deps = [_]CtDependency{
        .{ .reflected_struct = .{ .struct_name = "Test", .interface_hash = iface_hash } },
    };

    graph.structs.items[0].attributes.items[0].computed_value = .{ .int = 2 };
    try testing.expect(!try PersistentCache.validateDependencies(alloc, &deps, &graph, &interner));
}

test "validateDependencies: reflected_struct hash OOM propagates" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = try scope.ScopeGraph.init(alloc);
    const mod_scope = try graph.createScope(0, .struct_scope);
    var interner = ast.StringInterner.init(alloc);
    const test_id = try interner.intern("Test");
    const attr_id = try interner.intern("large");

    const mod_decl = try alloc.create(ast.StructDecl);
    mod_decl.* = .{
        .meta = .{ .span = .{ .start = 0, .end = 0 } },
        .name = .{ .parts = &.{test_id}, .span = .{ .start = 0, .end = 0 } },
        .items = &.{},
    };
    try graph.structs.append(alloc, .{
        .name = .{ .parts = &.{test_id}, .span = .{ .start = 0, .end = 0 } },
        .scope_id = mod_scope,
        .decl = mod_decl,
    });

    const tuple_values = try alloc.alloc(ConstValue, VALUE_TRAVERSAL_INLINE_STACK_CAPACITY + 1);
    for (tuple_values) |*value| {
        value.* = .{ .int = 1 };
    }
    try graph.structs.items[0].attributes.append(alloc, .{
        .name = attr_id,
        .computed_value = .{ .tuple = tuple_values },
    });

    const deps = [_]CtDependency{
        .{ .reflected_struct = .{ .struct_name = "Test", .interface_hash = 0 } },
    };
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        PersistentCache.validateDependencies(failing_allocator.allocator(), &deps, &graph, &interner),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "builtin: string concat" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "hello" } },
                .{ .const_string = .{ .dest = 1, .value = " world" } },
                .{ .binary_op = .{ .dest = 2, .lhs = 0, .rhs = 1, .op = .concat } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("hello world", result.string);
}

test "builtin: list concat" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 1 } },
                .{ .list_init = .{ .dest = 1, .elements = &.{0} } },
                .{ .const_int = .{ .dest = 2, .value = 2 } },
                .{ .list_init = .{ .dest = 3, .elements = &.{2} } },
                .{ .binary_op = .{ .dest = 4, .lhs = 1, .rhs = 3, .op = .concat } },
                .{ .ret = .{ .value = 4 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.elems.len);
    try testing.expectEqual(@as(i64, 1), result.list.elems[0].int);
    try testing.expectEqual(@as(i64, 2), result.list.elems[1].int);
}

test "builtin: atom_name" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_atom = .{ .dest = 0, .value = "hello" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.atom_name", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("hello", result.string);
}

test "builtin: i64_to_string" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 42 } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.i64_to_string", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("42", result.string);
}

test "builtin: to_atom" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .atom,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "world" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.to_atom", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("world", result.atom);
}

test "builtin: println is no-op" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "hello" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.println", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("hello", result.string);
}

test "serialize/deserialize map round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]ConstValue.ConstMapEntry{
        .{ .key = .{ .atom = "name" }, .value = .{ .string = "zap" } },
        .{ .key = .{ .atom = "version" }, .value = .{ .int = 1 } },
    };
    const original = ConstValue{ .map = &entries };
    const data = try serializeConstValue(alloc, original);
    var pos: usize = 0;
    const restored = try deserializeConstValue(alloc, data, &pos);
    try testing.expect(restored == .map);
    try testing.expectEqual(@as(usize, 2), restored.map.len);
    try testing.expectEqualStrings("name", restored.map[0].key.atom);
    try testing.expectEqualStrings("zap", restored.map[0].value.string);
    try testing.expectEqualStrings("version", restored.map[1].key.atom);
    try testing.expectEqual(@as(i64, 1), restored.map[1].value.int);
}

test "serialize/deserialize struct round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const fields = [_]ConstValue.ConstFieldValue{
        .{ .name = "host", .value = .{ .string = "localhost" } },
        .{ .name = "port", .value = .{ .int = 8080 } },
        .{ .name = "debug", .value = .{ .bool_val = true } },
    };
    const original = ConstValue{ .struct_val = .{
        .type_name = "Config",
        .fields = &fields,
    } };
    const data = try serializeConstValue(alloc, original);
    var pos: usize = 0;
    const restored = try deserializeConstValue(alloc, data, &pos);
    try testing.expect(restored == .struct_val);
    try testing.expectEqualStrings("Config", restored.struct_val.type_name);
    try testing.expectEqual(@as(usize, 3), restored.struct_val.fields.len);
    try testing.expectEqualStrings("host", restored.struct_val.fields[0].name);
    try testing.expectEqualStrings("localhost", restored.struct_val.fields[0].value.string);
    try testing.expectEqualStrings("port", restored.struct_val.fields[1].name);
    try testing.expectEqual(@as(i64, 8080), restored.struct_val.fields[1].value.int);
    try testing.expectEqualStrings("debug", restored.struct_val.fields[2].name);
    try testing.expect(restored.struct_val.fields[2].value.bool_val);
}

test "serialize/deserialize nested struct with list" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const paths = [_]ConstValue{ .{ .string = "lib/**/*.zap" }, .{ .string = "test/**/*.zap" } };
    const fields = [_]ConstValue.ConstFieldValue{
        .{ .name = "name", .value = .{ .string = "my_app" } },
        .{ .name = "version", .value = .{ .string = "0.1.0" } },
        .{ .name = "kind", .value = .{ .atom = "bin" } },
        .{ .name = "paths", .value = .{ .list = &paths } },
    };
    const original = ConstValue{ .struct_val = .{
        .type_name = "Zap_Manifest",
        .fields = &fields,
    } };
    const data = try serializeConstValue(alloc, original);
    var pos: usize = 0;
    const restored = try deserializeConstValue(alloc, data, &pos);
    try testing.expect(restored == .struct_val);
    try testing.expectEqualStrings("Zap_Manifest", restored.struct_val.type_name);
    try testing.expectEqual(@as(usize, 4), restored.struct_val.fields.len);
    const restored_paths = restored.struct_val.fields[3].value;
    try testing.expect(restored_paths == .list);
    try testing.expectEqual(@as(usize, 2), restored_paths.list.len);
    try testing.expectEqualStrings("lib/**/*.zap", restored_paths.list[0].string);
    try testing.expectEqualStrings("test/**/*.zap", restored_paths.list[1].string);
}

test "serializeResult/deserializeResult struct round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const fields = [_]ConstValue.ConstFieldValue{
        .{ .name = "name", .value = .{ .string = "my_app" } },
        .{ .name = "port", .value = .{ .int = 3000 } },
    };
    const eval_result = CtEvalResult{
        .value = .{ .struct_val = .{
            .type_name = "AppConfig",
            .fields = &fields,
        } },
        .dependencies = &.{},
        .result_hash = 99999,
    };
    const data = try serializeResult(alloc, eval_result);
    const restored = try deserializeResult(alloc, data);
    try testing.expect(restored.value == .struct_val);
    try testing.expectEqualStrings("AppConfig", restored.value.struct_val.type_name);
    try testing.expectEqual(@as(usize, 2), restored.value.struct_val.fields.len);
    try testing.expectEqualStrings("my_app", restored.value.struct_val.fields[0].value.string);
    try testing.expectEqual(@as(i64, 3000), restored.value.struct_val.fields[1].value.int);
    try testing.expectEqual(@as(u64, 99999), restored.result_hash);
}

test "dependency serialization: file dep round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const deps = [_]CtDependency{
        .{ .file = .{ .path = "lib/config.zap", .content_hash = 0xDEADBEEF } },
    };
    const eval_result = CtEvalResult{
        .value = .{ .int = 42 },
        .dependencies = &deps,
        .result_hash = 100,
    };
    const data = try serializeResult(alloc, eval_result);
    const restored = try deserializeResult(alloc, data);
    try testing.expectEqual(@as(usize, 1), restored.dependencies.len);
    try testing.expect(restored.dependencies[0] == .file);
    try testing.expectEqualStrings("lib/config.zap", restored.dependencies[0].file.path);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), restored.dependencies[0].file.content_hash);
}

test "dependency serialization: env_var dep round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const deps = [_]CtDependency{
        .{ .env_var = .{ .name = "DATABASE_URL", .value_hash = 0x12345678, .present = true } },
    };
    const eval_result = CtEvalResult{
        .value = .nil,
        .dependencies = &deps,
        .result_hash = 0,
    };
    const data = try serializeResult(alloc, eval_result);
    const restored = try deserializeResult(alloc, data);
    try testing.expectEqual(@as(usize, 1), restored.dependencies.len);
    try testing.expect(restored.dependencies[0] == .env_var);
    try testing.expectEqualStrings("DATABASE_URL", restored.dependencies[0].env_var.name);
    try testing.expectEqual(@as(u64, 0x12345678), restored.dependencies[0].env_var.value_hash);
    try testing.expect(restored.dependencies[0].env_var.present);
}

test "dependency serialization: reflected_struct dep round-trip" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const deps = [_]CtDependency{
        .{ .reflected_struct = .{ .struct_name = "Config", .interface_hash = 0xABCD } },
    };
    const eval_result = CtEvalResult{
        .value = .{ .bool_val = true },
        .dependencies = &deps,
        .result_hash = 1,
    };
    const data = try serializeResult(alloc, eval_result);
    const restored = try deserializeResult(alloc, data);
    try testing.expectEqual(@as(usize, 1), restored.dependencies.len);
    try testing.expect(restored.dependencies[0] == .reflected_struct);
    try testing.expectEqualStrings("Config", restored.dependencies[0].reflected_struct.struct_name);
    try testing.expectEqual(@as(u64, 0xABCD), restored.dependencies[0].reflected_struct.interface_hash);
}

test "dependency serialization: multiple mixed deps" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const deps = [_]CtDependency{
        .{ .file = .{ .path = "build.zap", .content_hash = 111 } },
        .{ .env_var = .{ .name = "MIX_ENV", .value_hash = 222, .present = false } },
        .{ .reflected_struct = .{ .struct_name = "App.Config", .interface_hash = 333 } },
    };
    const eval_result = CtEvalResult{
        .value = .{ .string = "ok" },
        .dependencies = &deps,
        .result_hash = 999,
    };
    const data = try serializeResult(alloc, eval_result);
    const restored = try deserializeResult(alloc, data);
    try testing.expectEqual(@as(usize, 3), restored.dependencies.len);
    // file
    try testing.expect(restored.dependencies[0] == .file);
    try testing.expectEqualStrings("build.zap", restored.dependencies[0].file.path);
    try testing.expectEqual(@as(u64, 111), restored.dependencies[0].file.content_hash);
    // env_var
    try testing.expect(restored.dependencies[1] == .env_var);
    try testing.expectEqualStrings("MIX_ENV", restored.dependencies[1].env_var.name);
    try testing.expect(!restored.dependencies[1].env_var.present);
    // reflected_struct
    try testing.expect(restored.dependencies[2] == .reflected_struct);
    try testing.expectEqualStrings("App.Config", restored.dependencies[2].reflected_struct.struct_name);
    try testing.expectEqual(@as(u64, 333), restored.dependencies[2].reflected_struct.interface_hash);
}

test "builtin: get_build_opt returns value" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "optimize" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_build_opt", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.build_opts.put(alloc, "optimize", "release_fast") catch {};

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqualStrings("release_fast", result.string);
}

test "builtin: get_build_opt returns nil for missing key" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "test_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "nonexistent" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_build_opt", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expect(result == .nil);
}

test "capability: build caps allow env read" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "env_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_string = .{ .dest = 0, .value = "CTFE_TEST_NONEXISTENT_VAR_999" } },
                .{ .call_builtin = .{ .dest = 1, .name = ":zig.get_env", .args = &.{0}, .arg_modes = &.{.share} } },
                .{ .ret = .{ .value = 1 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.build; // has all caps

    // Should succeed (returns nil for nonexistent var, but no error)
    const env_result = try interp.evalFunction(0, &.{});
    try testing.expect(env_result == .nil);
    try testing.expectEqual(@as(usize, 0), interp.errors.items.len);
}

test "capability: runtime-only builtins fail at compile time" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 0,
        .name = "arg_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .call_builtin = .{ .dest = 0, .name = ":zig.arg_count", .args = &.{}, .arg_modes = &.{} } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();
    interp.capabilities = CapabilitySet.build;

    const arg_result = interp.evalFunction(0, &.{});
    try testing.expectError(error.CtfeFailure, arg_result);
    try testing.expectEqual(CtfeErrorKind.capability_violation, interp.errors.items[0].kind);
}

// GAP-P1-05: a comptime-evaluated `case` over a union whose runtime value
// matches none of the explicit variants must fall into the catch-all `_`
// prong (`else_instrs` / `else_result`) instead of raising a spurious
// "no matching union variant" compile error. Pre-fix `execUnionSwitch`
// ignored `else_instrs`, so this errored on valid code.
test "GAP-P1-05: comptime union_switch falls into else_instrs on no match" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    // fn pick():
    //   %0 = const_int 7
    //   %1 = union_init MyUnion.VariantB(%0)   // not in explicit cases
    //   union_switch %1 {
    //     case VariantA -> { %3 = const_int 1; result %3 }
    //     _ -> { %4 = const_int 999; result %4 }
    //   } -> %2
    //   ret %2
    const case_body = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 3, .value = 1 } },
    };
    const cases = [_]ir.UnionCase{.{
        .variant_name = "VariantA",
        .field_bindings = &.{},
        .body_instrs = &case_body,
        .return_value = 3,
    }};
    const else_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 4, .value = 999 } },
    };

    const func = ir.Function{
        .id = 0,
        .name = "pick",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .const_int = .{ .dest = 0, .value = 7 } },
                .{ .union_init = .{
                    .dest = 1,
                    .union_type = "MyUnion",
                    .variant_name = "VariantB",
                    .value = 0,
                } },
                .{ .union_switch = .{
                    .dest = 2,
                    .scrutinee = 1,
                    .cases = &cases,
                    .else_instrs = &else_instrs,
                    .else_result = 4,
                    .has_else = true,
                } },
                .{ .ret = .{ .value = 2 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
    };
    const functions = [_]ir.Function{func};
    const program = makeTestProgram(&functions);
    var interp = try Interpreter.init(alloc, &program);
    defer interp.deinit();

    const result = try interp.evalFunction(0, &.{});
    try testing.expectEqual(@as(i64, 999), result.int);
}

fn hashOneInstruction(instr: ir.Instruction) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashInstruction(&hasher, instr);
    return hasher.final();
}

// GAP-P1-06: two `union_switch` instructions that differ ONLY in their
// catch-all `_` prong (`else_instrs` / `else_result`) must hash to
// distinct values, or a CTFE memoization cache keyed on this hash returns
// the wrong cached comptime result. Pre-fix `hashInstruction` omitted the
// else prong entirely, so these collided.
test "GAP-P1-06: union_switch hash distinguishes else_instrs" {
    const shared_case = [_]ir.UnionCase{.{
        .variant_name = "SomeVariant",
        .field_bindings = &.{},
        .body_instrs = &.{.{ .const_int = .{ .dest = 5, .value = 1 } }},
        .return_value = 5,
    }};

    const else_a = [_]ir.Instruction{.{ .const_int = .{ .dest = 6, .value = 100 } }};
    const else_b = [_]ir.Instruction{.{ .const_int = .{ .dest = 6, .value = 200 } }};

    const switch_a = ir.Instruction{ .union_switch = .{
        .dest = 0,
        .scrutinee = 1,
        .cases = &shared_case,
        .else_instrs = &else_a,
        .else_result = 6,
        .has_else = true,
    } };
    const switch_b = ir.Instruction{ .union_switch = .{
        .dest = 0,
        .scrutinee = 1,
        .cases = &shared_case,
        .else_instrs = &else_b,
        .else_result = 6,
        .has_else = true,
    } };

    try testing.expect(hashOneInstruction(switch_a) != hashOneInstruction(switch_b));

    // A union_switch with no catch-all must also differ from one that has
    // one, even when the explicit cases are identical.
    const switch_no_else = ir.Instruction{ .union_switch = .{
        .dest = 0,
        .scrutinee = 1,
        .cases = &shared_case,
    } };
    try testing.expect(hashOneInstruction(switch_a) != hashOneInstruction(switch_no_else));
}

// GAP-P1-06 (try-body coverage): two `try_call_named` instructions that
// differ ONLY in their handler/success continuation bodies must hash to
// distinct values. Pre-fix `hashInstruction` hashed only the call shape
// (dest/name/args/modes), so differing bodies collided.
test "GAP-P1-06: try_call_named hash distinguishes handler/success bodies" {
    const handler_a = [_]ir.Instruction{.{ .const_int = .{ .dest = 2, .value = 1 } }};
    const handler_b = [_]ir.Instruction{.{ .const_int = .{ .dest = 2, .value = 9 } }};

    const try_a = ir.Instruction{ .try_call_named = .{
        .dest = 0,
        .name = "step__try",
        .args = &.{1},
        .arg_modes = &.{.move},
        .input_local = 1,
        .handler_instrs = &handler_a,
        .handler_result = 2,
    } };
    const try_b = ir.Instruction{ .try_call_named = .{
        .dest = 0,
        .name = "step__try",
        .args = &.{1},
        .arg_modes = &.{.move},
        .input_local = 1,
        .handler_instrs = &handler_b,
        .handler_result = 2,
    } };

    try testing.expect(hashOneInstruction(try_a) != hashOneInstruction(try_b));
}
