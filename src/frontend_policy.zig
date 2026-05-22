const std = @import("std");

const FRONTEND_POLICY_TAG_MAGIC: u64 = 0x5a_46_50_4f; // "ZFPO"
const FRONTEND_PASS_POLICY_TAG_MAGIC: u64 = 0x5a_46_50_50; // "ZFPP"
const FRONTEND_POLICY_TAG_VERSION: u8 = 2;

pub const FrontendVerifierMode = enum(u8) {
    /// Run the existing frontend verifier surface exactly as today.
    full,
};

pub const FrontendPassPolicy = struct {
    run_region_solver: bool = true,
    run_lambda_specialization: bool = true,
    run_perceus_reuse: bool = true,
    run_arc_optimizer: bool = true,
    run_contification: bool = true,
    elide_borrowed_pass_through: bool = true,
    rewrite_unchecked_uniqueness: bool = true,
    verifier_mode: FrontendVerifierMode = .full,

    pub fn full() FrontendPassPolicy {
        return .{};
    }

    pub fn debug() FrontendPassPolicy {
        return .{
            .run_region_solver = false,
            .run_lambda_specialization = false,
            .run_perceus_reuse = false,
            .run_arc_optimizer = false,
            .run_contification = false,
            .elide_borrowed_pass_through = false,
            .rewrite_unchecked_uniqueness = false,
            .verifier_mode = .full,
        };
    }

    pub fn payload(self: FrontendPassPolicy) u64 {
        var bits: u64 = 0;
        if (self.run_region_solver) bits |= @as(u64, 1) << 0;
        if (self.run_lambda_specialization) bits |= @as(u64, 1) << 1;
        if (self.run_perceus_reuse) bits |= @as(u64, 1) << 2;
        if (self.run_arc_optimizer) bits |= @as(u64, 1) << 3;
        if (self.run_contification) bits |= @as(u64, 1) << 4;
        if (self.elide_borrowed_pass_through) bits |= @as(u64, 1) << 5;
        if (self.rewrite_unchecked_uniqueness) bits |= @as(u64, 1) << 6;
        bits |= @as(u64, @intFromEnum(self.verifier_mode)) << 8;
        return bits;
    }

    pub fn cacheTag(self: FrontendPassPolicy) u64 {
        return (FRONTEND_PASS_POLICY_TAG_MAGIC << 32) |
            (@as(u64, FRONTEND_POLICY_TAG_VERSION) << 24) |
            self.payload();
    }
};

pub const FrontendOptimizeMode = enum(u8) {
    debug,
    release_safe,
    release_fast,
    release_small,

    pub fn passPolicy(self: FrontendOptimizeMode) FrontendPassPolicy {
        return switch (self) {
            .debug => FrontendPassPolicy.debug(),
            .release_safe, .release_fast, .release_small => FrontendPassPolicy.full(),
        };
    }

    /// Phase 1.5 — per-optimize-mode arithmetic-overflow policy. In Debug
    /// and ReleaseSafe builds, integer arithmetic that overflows traps
    /// (the safe-mode checked arithmetic tags emit a safety check that
    /// routes to the runtime's `** (arithmetic_error) ...` abort). In
    /// ReleaseFast and ReleaseSmall builds, integer arithmetic wraps
    /// (two's-complement), matching Zig's optimize-mode model. This
    /// predicate is the single source of truth for that decision — the
    /// ZIR builder consults it when choosing checked vs wrapping
    /// arithmetic tags (`add` vs `addwrap`, etc.).
    pub fn arithmeticOverflowTraps(self: FrontendOptimizeMode) bool {
        return switch (self) {
            .debug, .release_safe => true,
            .release_fast, .release_small => false,
        };
    }

    pub fn cacheTag(self: FrontendOptimizeMode) u64 {
        return (FRONTEND_POLICY_TAG_MAGIC << 32) |
            (@as(u64, FRONTEND_POLICY_TAG_VERSION) << 24) |
            (@as(u64, @intFromEnum(self)) << 16) |
            self.passPolicy().payload();
    }
};

test "debug frontend policy disables optimization-only passes" {
    const policy = FrontendOptimizeMode.debug.passPolicy();
    try std.testing.expect(!policy.run_region_solver);
    try std.testing.expect(!policy.run_lambda_specialization);
    try std.testing.expect(!policy.run_perceus_reuse);
    try std.testing.expect(!policy.run_arc_optimizer);
    try std.testing.expect(!policy.run_contification);
    try std.testing.expect(!policy.elide_borrowed_pass_through);
    try std.testing.expect(!policy.rewrite_unchecked_uniqueness);
    try std.testing.expectEqual(FrontendVerifierMode.full, policy.verifier_mode);
}

test "release frontend policies preserve full pass set" {
    const modes = [_]FrontendOptimizeMode{
        .release_safe,
        .release_fast,
        .release_small,
    };

    for (modes) |mode| {
        const policy = mode.passPolicy();
        try std.testing.expect(policy.run_region_solver);
        try std.testing.expect(policy.run_lambda_specialization);
        try std.testing.expect(policy.run_perceus_reuse);
        try std.testing.expect(policy.run_arc_optimizer);
        try std.testing.expect(policy.run_contification);
        try std.testing.expect(policy.elide_borrowed_pass_through);
        try std.testing.expect(policy.rewrite_unchecked_uniqueness);
        try std.testing.expectEqual(FrontendVerifierMode.full, policy.verifier_mode);
    }
}

test "frontend policy tags separate debug from release policy" {
    try std.testing.expectEqual(FrontendOptimizeMode.debug.cacheTag(), FrontendOptimizeMode.debug.cacheTag());
    try std.testing.expect(FrontendOptimizeMode.debug.passPolicy().cacheTag() != FrontendOptimizeMode.release_fast.passPolicy().cacheTag());
    try std.testing.expectEqual(FrontendOptimizeMode.release_safe.passPolicy().cacheTag(), FrontendOptimizeMode.release_fast.passPolicy().cacheTag());
    try std.testing.expectEqual(FrontendOptimizeMode.release_fast.passPolicy().cacheTag(), FrontendOptimizeMode.release_small.passPolicy().cacheTag());
    try std.testing.expect(FrontendOptimizeMode.debug.cacheTag() != FrontendOptimizeMode.release_safe.cacheTag());
    try std.testing.expect(FrontendOptimizeMode.release_safe.cacheTag() != FrontendOptimizeMode.release_fast.cacheTag());
    try std.testing.expect(FrontendOptimizeMode.release_fast.cacheTag() != FrontendOptimizeMode.release_small.cacheTag());
}
