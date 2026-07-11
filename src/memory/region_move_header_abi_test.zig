//! Cross-manager region-move header ABI drift test (P6-R1).
//!
//! The `LargeHeader` preamble — field layout, `LARGE_MAGIC` value, and the
//! `largeLeadingFor` placement rule — is deliberately BYTE-IDENTICAL between
//! the ARC and ORC managers (`src/memory/arc/manager.zig` /
//! `src/memory/orc/manager.zig`): the same-model O(1) region-move send
//! re-parents a detached large block between ANY two refcounted-model
//! processes, so the adopting manager reads the header the detaching manager
//! wrote. Each manager compiles standalone, so the definition is MIRRORED,
//! not shared — and a mirrored definition can drift. This test is the drift
//! gate: any divergence in size, alignment, field names/offsets/sizes, the
//! magic value, or the header-placement rule fails `zig build test` before
//! it can corrupt a cross-manager move.

const std = @import("std");
const arc = @import("arc/manager.zig");
const orc = @import("orc/manager.zig");

test "ARC and ORC LargeHeader layouts are byte-identical (the cross-manager region-move ABI)" {
    // Whole-struct geometry.
    try std.testing.expectEqual(@sizeOf(arc.LargeHeader), @sizeOf(orc.LargeHeader));
    try std.testing.expectEqual(@alignOf(arc.LargeHeader), @alignOf(orc.LargeHeader));

    // Field-by-field: same names, in the same order, at the same offsets,
    // with the same sizes. (Field TYPES cannot be compared for identity —
    // the intrusive links are `?*LargeHeader` of each manager's own struct —
    // so size + offset is the byte-layout witness.)
    const arc_fields = @typeInfo(arc.LargeHeader).@"struct".fields;
    const orc_fields = @typeInfo(orc.LargeHeader).@"struct".fields;
    comptime std.debug.assert(arc_fields.len == orc_fields.len);
    inline for (arc_fields, orc_fields) |arc_field, orc_field| {
        try std.testing.expectEqualStrings(arc_field.name, orc_field.name);
        try std.testing.expectEqual(
            @offsetOf(arc.LargeHeader, arc_field.name),
            @offsetOf(orc.LargeHeader, orc_field.name),
        );
        try std.testing.expectEqual(@sizeOf(arc_field.type), @sizeOf(orc_field.type));
    }
}

test "ARC and ORC agree on the large-block magic and the header placement rule" {
    try std.testing.expectEqual(arc.LARGE_MAGIC, orc.LARGE_MAGIC);

    // The placement rule decides where the adopting manager finds the header
    // relative to the user pointer, for every alignment the container cells
    // request — sub-header, exact-header, and super-header alignments.
    const representative_alignments = [_]u32{ 1, 2, 4, 8, 16, 32, 64, 128, 4096, 16384 };
    for (representative_alignments) |alignment| {
        try std.testing.expectEqual(arc.largeLeadingFor(alignment), orc.largeLeadingFor(alignment));
    }
}
