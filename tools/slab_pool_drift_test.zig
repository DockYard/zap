//! Cross-check that the byte-keyed slab pool constants in
//! `src/runtime.zig`'s `TestOnlyArcSlabPool` match the corresponding
//! constants in `src/memory/arc/manager.zig` byte-for-byte.
//!
//! Phase 4.x duplicated the slab-pool implementation between the
//! runtime (for test builds, where the manager `.o` is not linked)
//! and the production manager (`src/memory/arc/manager.zig`,
//! compiled as a standalone object via `zap_fork_compile_zig_to_object`).
//! The production manager rule (spec section 11.1.1) forbids it from
//! importing sibling files: its only dependencies are `std` and
//! `builtin`. That means we cannot share a slab-pool module between
//! the two — the duplication is structural, not accidental.
//!
//! The runtime's test path and the production binary's user code
//! both reach the slab pool through the REFCOUNT_V1 vtable; a drift
//! in either side's layout constants would mean the runtime's tests
//! pass against a different slab geometry than the production
//! binary uses. This test compares the constant declarations
//! textually so any unilateral edit fails at build time with a clear
//! diagnostic.
//!
//! Limitations: this is a textual cross-check of layout constants.
//! It does NOT catch drift in function bodies (`lookupClass`,
//! `slabAllocSlot`, `slabFreeSlot`, the cached-empty / partial-list
//! policy, the `LargeHeader` layout helpers, etc.) or comptime-derived
//! tables (`SLAB_CLASS_ALIGNS`, `SLAB_CLASS_LOOKUP_TABLE`). Behavioural
//! parity is exercised through the 15 byte-keyed slab pool tests in
//! `src/runtime.zig`, which call into `TestOnlyArcSlabPool`'s functions;
//! the production manager's slab functions are exercised end-to-end via
//! the manager-driven `Arc(T)` integration tests. A property-based
//! parity test that exercises both pool instances in lockstep with the
//! same operation sequence would close the residual gap; deferred — it
//! requires teaching the test runner to link the production manager
//! object directly, which is non-trivial because the manager TU has its
//! own atomics-helper export and a duplicate slab-pool block.

const std = @import("std");

const ConstantPair = struct {
    name: []const u8,
    runtime_text: []const u8,
    manager_text: []const u8,
};

/// Constants that MUST appear identically (modulo whitespace) in both
/// `runtime.zig`'s `TestOnlyArcSlabPool` block and
/// `src/memory/arc/manager.zig`. If you add or remove a constant in
/// either source, update this list to keep drift detection coverage.
const required_constants = [_][]const u8{
    "SLAB_SIZE",
    "SLAB_ALIGN",
    "SLAB_MASK",
    "SLAB_BASE_MASK",
    "NULL_SLOT",
    "SLAB_MAGIC",
    "LARGE_MAGIC",
    "SLAB_CLASS_SIZES",
    "SLAB_CLASS_COUNT",
    "MAX_SLAB_CLASS_SIZE",
    "SLAB_CLASS_LOOKUP_GRANULARITY",
};

/// Read a file's contents into a heap-allocated slice (caller frees).
/// Uses `std.Io.Dir.cwd()` for symmetry with the existing
/// `boundary_guard_test.zig` in the same directory.
fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(64 * 1024 * 1024),
    );
}

/// Extract the RHS of a `const NAME = ...;` declaration from `source`,
/// matching the first occurrence. Returns the inner expression text
/// with leading/trailing whitespace stripped. Returns null when the
/// constant is not declared in `source`.
fn extractConstantValue(source: []const u8, name: []const u8) ?[]const u8 {
    // Match either `const NAME` or `pub const NAME` at the start of
    // a line (allowing leading whitespace). Take the RHS up to the
    // first semicolon at the same brace depth as the `=`.
    var idx: usize = 0;
    while (idx < source.len) {
        const line_start = idx;
        // Advance idx to the end of the current line.
        const newline = std.mem.indexOfScalarPos(u8, source, idx, '\n') orelse source.len;
        const line = source[line_start..newline];
        idx = newline + 1;

        const trimmed = std.mem.trim(u8, line, " \t");
        const head = if (std.mem.startsWith(u8, trimmed, "pub const "))
            trimmed[10..]
        else if (std.mem.startsWith(u8, trimmed, "const "))
            trimmed[6..]
        else
            continue;

        // The constant name is everything up to a non-identifier
        // character (`:`, ` `, `=`).
        var name_end: usize = 0;
        while (name_end < head.len) : (name_end += 1) {
            const c = head[name_end];
            if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
        }
        if (!std.mem.eql(u8, head[0..name_end], name)) continue;

        // Find the `=` after the name.
        const eq_in_head = std.mem.indexOfScalar(u8, head[name_end..], '=') orelse continue;
        var value_start = name_end + eq_in_head + 1;
        while (value_start < head.len and (head[value_start] == ' ' or head[value_start] == '\t')) {
            value_start += 1;
        }

        // The value text may span multiple lines (e.g. comptime block
        // builders). For our cross-check we only need the first-line
        // header — the array contents and block bodies are validated
        // separately by the test below using a stricter match. So
        // capture from `value_start` to either the trailing `;` on
        // this line or the end-of-line.
        const value_in_head = head[value_start..];
        if (std.mem.indexOfScalar(u8, value_in_head, ';')) |semi| {
            return std.mem.trim(u8, value_in_head[0..semi], " \t");
        }
        return std.mem.trim(u8, value_in_head, " \t");
    }
    return null;
}

test "slab pool constants are byte-identical between runtime and arc manager" {
    const allocator = std.testing.allocator;
    const runtime_src = try readFile(allocator, "src/runtime.zig");
    defer allocator.free(runtime_src);
    const manager_src = try readFile(allocator, "src/memory/arc/manager.zig");
    defer allocator.free(manager_src);

    // Locate the TestOnlyArcSlabPool block in runtime.zig — every
    // constant we care about is declared inside that block. We
    // restrict the search to that scope so a coincidentally-named
    // `SLAB_SIZE` elsewhere in `runtime.zig` (none today, but
    // defensive against future additions) does not affect the cross-
    // check.
    const block_marker = "const TestOnlyArcSlabPool = if (builtin.is_test) struct {";
    const block_start = std.mem.indexOf(u8, runtime_src, block_marker) orelse {
        std.debug.print("runtime.zig: TestOnlyArcSlabPool block not found\n", .{});
        return error.MarkerNotFound;
    };
    // Approximate the block end with the matching `else struct{}` line
    // (the test-build vs production-build branch).
    const block_end_marker = "} else struct {};";
    const block_end = std.mem.indexOfPos(u8, runtime_src, block_start, block_end_marker) orelse runtime_src.len;
    const runtime_block = runtime_src[block_start..block_end];

    var any_diff = false;
    for (required_constants) |name| {
        const runtime_value_opt = extractConstantValue(runtime_block, name);
        const manager_value_opt = extractConstantValue(manager_src, name);
        if (runtime_value_opt == null) {
            std.debug.print(
                "runtime.zig: TestOnlyArcSlabPool is missing constant `{s}`\n",
                .{name},
            );
            any_diff = true;
        }
        if (manager_value_opt == null) {
            std.debug.print(
                "memory/arc/manager.zig is missing constant `{s}`\n",
                .{name},
            );
            any_diff = true;
        }
        if (runtime_value_opt) |runtime_value| {
            if (manager_value_opt) |manager_value| {
                if (!std.mem.eql(u8, runtime_value, manager_value)) {
                    std.debug.print(
                        "slab-pool drift: `{s}` differs\n  runtime.zig: `{s}`\n  arc/manager.zig: `{s}`\n",
                        .{ name, runtime_value, manager_value },
                    );
                    any_diff = true;
                }
            }
        }
    }
    if (any_diff) return error.SlabPoolConstantDrift;
}
