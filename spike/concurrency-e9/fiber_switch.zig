//! E9 spike benchmark (concurrency campaign, job S0.3).
//!
//! THROWAWAY SPIKE CODE — see README.md. Measures the raw stackful fiber
//! substrate the bespoke Zap scheduler will be built on after E1
//! disqualified both fork `std.Io` backends: raw context switching with the
//! same stack layout and entry trampoline `Io/Dispatch.zig` / `Io/Uring.zig`
//! use internally (argument block at the top of the stack, naked entry that
//! forwards sp as the first parameter).
//!
//! FORK BUG found while building this spike (full detail in README.md and
//! the E9 section of docs/concurrency-bench-results.md): the fork's
//! `std.Io.fiber.contextSwitch` declares `.x30 = true` in its clobber set,
//! but the Zig LLVM backend emits the clobber as `~{x30}` and LLVM's AArch64
//! register is named `lr` (clang translates user clobber "x30" to "lr"; Zig
//! does not), so the clobber is silently dropped. At -OReleaseFast LLVM then
//! keeps live pointers in x30 across the switch, and a resumed fiber sees
//! whatever the *other* fiber left in x30 — this spike's ping-pong
//! degenerates into garbage control flow, and it is the most plausible root
//! cause of E1's optimized-build Dispatch segfaults. Because this job may
//! not modify fork sources, the benchmark below uses a spike-local copy of
//! the primitive whose only change is that the switch saves/restores x30 in
//! a fourth `Context` word, which is correct under either compiler behavior
//! (costs one extra instruction; the proper fork fix — mapping the clobber
//! to `~{lr}` — would make even that unnecessary).
//!
//! Build (asdf zig 0.16.0 binary against the fork's std):
//!   zig build-exe --zig-lib-dir $HOME/projects/zig/lib -OReleaseFast fiber_switch.zig
//! Run (one measurement at a time):
//!   ./fiber_switch <pingpong|spawn|stack> [ops] [reps] [warmup]

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

comptime {
    if (!std.Io.fiber.supported) @compileError("fibers unsupported on this architecture");
}

/// Spike-local copy of the fork's `std.Io.fiber.Context` extended with an
/// x30 slot (see the FORK BUG note in the file doc comment).
const FiberContext = switch (builtin.cpu.arch) {
    .aarch64 => extern struct {
        sp: u64,
        fp: u64,
        pc: u64,
        lr: u64,
    },
    .x86_64 => extern struct {
        rsp: u64,
        rbp: u64,
        rip: u64,
        unused: u64 = 0,
    },
    else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
};

const FiberSwitch = extern struct { old: *FiberContext, new: *FiberContext };

/// Spike-local copy of the fork's `std.Io.fiber.contextSwitch`. The aarch64
/// asm is identical except that it additionally stores the current x30 into
/// `old` and loads `new`'s saved x30, so no register the compiler may treat
/// as preserved carries stale state across the switch. The x86_64 asm is an
/// unmodified copy (LLVM recognizes all the x86 clobber names, so the fork
/// primitive is not known to miscompile there); it is retained only so the
/// spike still compiles on x86_64 — E9 measurements are aarch64/Darwin.
inline fn fiberContextSwitch(s: *const FiberSwitch) *const FiberSwitch {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ ldp x0, x2, [x1]
            \\ ldr x3, [x2, #16]
            \\ mov x4, sp
            \\ stp x4, fp, [x0]
            \\ adr x5, 0f
            \\ stp x5, x30, [x0, #16]
            \\ ldp x4, fp, [x2]
            \\ ldr x30, [x2, #24]
            \\ mov sp, x4
            \\ br x3
            \\0:
            : [received_message] "={x1}" (-> *const FiberSwitch),
            : [message_to_send] "{x1}" (s),
            : .{
              .x0 = true,
              .x1 = true,
              .x2 = true,
              .x3 = true,
              .x4 = true,
              .x5 = true,
              .x6 = true,
              .x7 = true,
              .x8 = true,
              .x9 = true,
              .x10 = true,
              .x11 = true,
              .x12 = true,
              .x13 = true,
              .x14 = true,
              .x15 = true,
              .x16 = true,
              .x17 = true,
              .x19 = true,
              .x20 = true,
              .x21 = true,
              .x22 = true,
              .x23 = true,
              .x24 = true,
              .x25 = true,
              .x26 = true,
              .x27 = true,
              .x28 = true,
              .x30 = true,
              .z0 = true,
              .z1 = true,
              .z2 = true,
              .z3 = true,
              .z4 = true,
              .z5 = true,
              .z6 = true,
              .z7 = true,
              .z8 = true,
              .z9 = true,
              .z10 = true,
              .z11 = true,
              .z12 = true,
              .z13 = true,
              .z14 = true,
              .z15 = true,
              .z16 = true,
              .z17 = true,
              .z18 = true,
              .z19 = true,
              .z20 = true,
              .z21 = true,
              .z22 = true,
              .z23 = true,
              .z24 = true,
              .z25 = true,
              .z26 = true,
              .z27 = true,
              .z28 = true,
              .z29 = true,
              .z30 = true,
              .z31 = true,
              .p0 = true,
              .p1 = true,
              .p2 = true,
              .p3 = true,
              .p4 = true,
              .p5 = true,
              .p6 = true,
              .p7 = true,
              .p8 = true,
              .p9 = true,
              .p10 = true,
              .p11 = true,
              .p12 = true,
              .p13 = true,
              .p14 = true,
              .p15 = true,
              .fpcr = true,
              .fpsr = true,
              .ffr = true,
              .memory = true,
            }),
        .x86_64 => asm volatile (
            \\ movq 0(%%rsi), %%rax
            \\ movq 8(%%rsi), %%rcx
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx)
            \\0:
            : [received_message] "={rsi}" (-> *const FiberSwitch),
            : [message_to_send] "{rsi}" (s),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rbx = true,
              .rsi = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = true,
              .r14 = true,
              .r15 = true,
              .mm0 = true,
              .mm1 = true,
              .mm2 = true,
              .mm3 = true,
              .mm4 = true,
              .mm5 = true,
              .mm6 = true,
              .mm7 = true,
              .zmm0 = true,
              .zmm1 = true,
              .zmm2 = true,
              .zmm3 = true,
              .zmm4 = true,
              .zmm5 = true,
              .zmm6 = true,
              .zmm7 = true,
              .zmm8 = true,
              .zmm9 = true,
              .zmm10 = true,
              .zmm11 = true,
              .zmm12 = true,
              .zmm13 = true,
              .zmm14 = true,
              .zmm15 = true,
              .zmm16 = true,
              .zmm17 = true,
              .zmm18 = true,
              .zmm19 = true,
              .zmm20 = true,
              .zmm21 = true,
              .zmm22 = true,
              .zmm23 = true,
              .zmm24 = true,
              .zmm25 = true,
              .zmm26 = true,
              .zmm27 = true,
              .zmm28 = true,
              .zmm29 = true,
              .zmm30 = true,
              .zmm31 = true,
              .fpsr = true,
              .fpcr = true,
              .mxcsr = true,
              .rflags = true,
              .dirflag = true,
              .memory = true,
            }),
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    };
}

const default_round_trips = 1_000_000;
const default_spawn_count = 1_000_000;
const default_stack_creates = 100_000;
const default_repetitions = 5;

const Benchmark = enum { pingpong, spawn, stack };

/// Usable stack bytes per fiber, excluding the guard page. Far beyond what
/// these fiber bodies need; the size only matters for the `stack` benchmark,
/// where creation cost itself is measured.
const fiber_stack_size = 256 * 1024;

/// Io-independent monotonic nanosecond clock (CLOCK_UPTIME_RAW), same
/// convention as the E1 spike, so timing never routes through any Io
/// implementation.
fn nowNanoseconds() u64 {
    var ts: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.UPTIME_RAW, &ts) == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const FiberRole = enum {
    /// Drives `round_trips` full round trips against the pong fiber, then
    /// switches back to the main context.
    ping,
    /// Echoes control back to the ping fiber forever.
    pong,
    /// Immediately returns control to the main context (spawn-floor body).
    immediate_exit,
};

/// Argument block placed at the top of each fiber stack, mirroring how
/// `Io/Dispatch.zig` places its `AsyncClosure` above the initial stack
/// pointer.
const FiberArgs = struct {
    role: FiberRole,
    self_context: *FiberContext,
    partner_context: *FiberContext,
    exit_context: *FiberContext,
    round_trips: usize,
    /// Incremented by the fiber body on every resume; lets the benchmark
    /// assert (outside the timed region) that the switches really happened.
    wake_count: usize,
};

const FiberStack = struct {
    mapping: []align(std.heap.page_size_min) u8,

    /// mmap an anonymous private region with one PROT_NONE guard page at the
    /// low end (stacks grow downward). The fork's Dispatch/Uring backends
    /// allocate fiber stacks from the general allocator without guard pages;
    /// the guard page here is the minimal correctness addition for raw
    /// fibers whose overflow would otherwise silently corrupt adjacent
    /// mappings.
    fn create() !FiberStack {
        const page_size = std.heap.pageSize();
        const mapping = try posix.mmap(
            null,
            fiber_stack_size + page_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        if (std.c.mprotect(@ptrCast(mapping.ptr), page_size, .{}) != 0)
            return error.GuardPageProtectFailed;
        return .{ .mapping = mapping };
    }

    fn destroy(stack: FiberStack) void {
        posix.munmap(stack.mapping);
    }

    /// The fiber argument block lives at the top of the stack, 16-byte
    /// aligned; the initial stack pointer is the argument block address and
    /// the fiber's frames grow downward from it (the exact layout
    /// `Io/Dispatch.zig` uses for `AsyncClosure`).
    fn argsPointer(stack: FiberStack) *FiberArgs {
        const top = @intFromPtr(stack.mapping.ptr) + stack.mapping.len;
        return @ptrFromInt(std.mem.alignBackward(usize, top - @sizeOf(FiberArgs), 16));
    }
};

/// One-way switch: saves the current cpu state into `old` and resumes `new`.
inline fn switchContext(old: *FiberContext, new: *FiberContext) void {
    const message: FiberSwitch = .{ .old = old, .new = new };
    _ = fiberContextSwitch(&message);
}

/// First-switch trampoline (mirrors `Io/Dispatch.zig` `AsyncClosure.entry`):
/// a fiber's initial context points here with sp = the argument block, so
/// the trampoline moves sp into the first parameter register and branches to
/// `fiberMain`; the switch that resumed this fiber leaves its
/// `*const FiberSwitch` message in the second parameter register (x1/rsi).
fn fiberEntry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ mov x0, sp
            \\ b %[call]
            :
            : [call] "X" (&fiberMain),
        ),
        .x86_64 => asm volatile (
            \\ leaq 8(%%rsp), %%rdi
            \\ jmp %[call:P]
            :
            : [call] "X" (&fiberMain),
        ),
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    }
}

fn fiberMain(
    args: *FiberArgs,
    first_message: *const FiberSwitch,
) callconv(.withStackAlign(.c, 16)) noreturn {
    _ = first_message;
    args.wake_count +%= 1;
    switch (args.role) {
        .ping => {
            var remaining = args.round_trips;
            while (remaining > 0) : (remaining -= 1) {
                switchContext(args.self_context, args.partner_context);
                args.wake_count +%= 1;
            }
        },
        .pong => while (true) {
            switchContext(args.self_context, args.partner_context);
            args.wake_count +%= 1;
        },
        .immediate_exit => {},
    }
    // Hand control back to the main context; the fiber is dead afterwards
    // and must never be resumed (the loop guards against a stray resume).
    while (true) switchContext(args.self_context, args.exit_context);
}

/// Initial fiber context (mirrors `Io/Dispatch.zig` `concurrent`): pc at the
/// naked trampoline, sp at the argument block (x86_64 leaves the 8-byte
/// return-address slot the trampoline compensates for), fp zeroed to
/// terminate frame-pointer walks.
fn initFiberContext(context: *FiberContext, args: *FiberArgs) void {
    context.* = switch (builtin.cpu.arch) {
        .aarch64 => .{
            .sp = @intFromPtr(args),
            .fp = 0,
            .pc = @intFromPtr(&fiberEntry),
            .lr = 0,
        },
        .x86_64 => .{
            .rsp = @intFromPtr(args) - 8,
            .rbp = 0,
            .rip = @intFromPtr(&fiberEntry),
        },
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    };
}

const Sample = struct {
    total_ns: u64,
    /// For `pingpong` this counts one-way switches (2 * round_trips + 2);
    /// for `spawn`/`stack` it counts operations.
    op_count: usize,

    fn perOpNs(sample: Sample) f64 {
        return @as(f64, @floatFromInt(sample.total_ns)) /
            @as(f64, @floatFromInt(sample.op_count));
    }
};

/// Two fibers ping-pong control `round_trips` times. Timed region contains
/// exactly `2 * round_trips + 2` one-way switches: main -> ping (1),
/// ping <-> pong (2 per round trip), final ping -> main (1). Per-op number
/// is one one-way context switch; a message round trip is 2x that.
fn benchPingPong(ping_stack: FiberStack, pong_stack: FiberStack, round_trips: usize) Sample {
    var main_context: FiberContext = undefined;
    var ping_context: FiberContext = undefined;
    var pong_context: FiberContext = undefined;

    const ping_args = ping_stack.argsPointer();
    const pong_args = pong_stack.argsPointer();
    ping_args.* = .{
        .role = .ping,
        .self_context = &ping_context,
        .partner_context = &pong_context,
        .exit_context = &main_context,
        .round_trips = round_trips,
        .wake_count = 0,
    };
    pong_args.* = .{
        .role = .pong,
        .self_context = &pong_context,
        .partner_context = &ping_context,
        .exit_context = &main_context,
        .round_trips = 0,
        .wake_count = 0,
    };
    initFiberContext(&ping_context, ping_args);
    initFiberContext(&pong_context, pong_args);

    const start_ns = nowNanoseconds();
    switchContext(&main_context, &ping_context);
    const total_ns = nowNanoseconds() - start_ns;

    // Prove the switches really happened (this caught the fork's dropped
    // x30 clobber): ping is resumed once at entry plus once per round trip;
    // pong is resumed exactly once per round trip.
    if (ping_args.wake_count != round_trips + 1 or pong_args.wake_count != round_trips)
        std.debug.panic("pingpong executed wrong switch count: ping={d} pong={d} expected={d}/{d}", .{
            ping_args.wake_count, pong_args.wake_count, round_trips + 1, round_trips,
        });
    return .{ .total_ns = total_ns, .op_count = 2 * round_trips + 2 };
}

/// Pooled-stack spawn floor: per op, initialize a fresh fiber context on a
/// reused stack, switch into it, and let it immediately switch back — the
/// floor for spawn -> run-to-completion -> return of a trivial process when
/// stacks are pooled (context init + 2 one-way switches).
fn benchSpawnFloor(stack: FiberStack, spawn_count: usize) Sample {
    var main_context: FiberContext = undefined;
    var task_context: FiberContext = undefined;
    const args = stack.argsPointer();

    var completed_tasks: usize = 0;
    const start_ns = nowNanoseconds();
    var index: usize = 0;
    while (index < spawn_count) : (index += 1) {
        args.* = .{
            .role = .immediate_exit,
            .self_context = &task_context,
            .partner_context = &task_context,
            .exit_context = &main_context,
            .round_trips = 0,
            .wake_count = 0,
        };
        initFiberContext(&task_context, args);
        switchContext(&main_context, &task_context);
        completed_tasks += args.wake_count;
    }
    const total_ns = nowNanoseconds() - start_ns;

    if (completed_tasks != spawn_count)
        std.debug.panic("spawn floor executed {d} tasks, expected {d}", .{ completed_tasks, spawn_count });
    return .{ .total_ns = total_ns, .op_count = spawn_count };
}

/// Fresh-stack cost (the anti-pooling reference): per op, mmap a stack,
/// protect the guard page, fault in the top page by writing the argument
/// block (as any real spawn would), and unmap.
fn benchStackCreate(op_count: usize) Sample {
    var checksum: usize = 0;
    const start_ns = nowNanoseconds();
    var index: usize = 0;
    while (index < op_count) : (index += 1) {
        const stack = FiberStack.create() catch |err|
            std.debug.panic("stack create: {s}", .{@errorName(err)});
        const args = stack.argsPointer();
        args.round_trips = index;
        checksum +%= args.round_trips;
        stack.destroy();
    }
    const total_ns = nowNanoseconds() - start_ns;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .total_ns = total_ns, .op_count = op_count };
}

fn runBenchmark(
    benchmark: Benchmark,
    ping_stack: FiberStack,
    pong_stack: FiberStack,
    op_count: usize,
) Sample {
    return switch (benchmark) {
        .pingpong => benchPingPong(ping_stack, pong_stack, op_count),
        .spawn => benchSpawnFloor(ping_stack, op_count),
        .stack => benchStackCreate(op_count),
    };
}

fn usageAndExit() noreturn {
    std.debug.print("usage: fiber_switch <pingpong|spawn|stack> [ops] [reps] [warmup]\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    // `Init.Minimal` hands over argv without start.zig constructing an
    // implicit Io instance — this spike uses no Io at all.
    var args_iterator: std.process.Args.Iterator = .init(init.args);
    _ = args_iterator.next(); // program name

    const benchmark_arg = args_iterator.next() orelse usageAndExit();
    const benchmark = std.meta.stringToEnum(Benchmark, benchmark_arg) orelse usageAndExit();

    const default_ops: usize = switch (benchmark) {
        .pingpong => default_round_trips,
        .spawn => default_spawn_count,
        .stack => default_stack_creates,
    };
    const op_count = if (args_iterator.next()) |ops_arg|
        try std.fmt.parseInt(usize, ops_arg, 10)
    else
        default_ops;
    const repetitions = if (args_iterator.next()) |reps_arg|
        try std.fmt.parseInt(usize, reps_arg, 10)
    else
        default_repetitions;
    const warmup_override: ?usize = if (args_iterator.next()) |warmup_arg|
        try std.fmt.parseInt(usize, warmup_arg, 10)
    else
        null;

    std.debug.print(
        "bench={s} ops={d} reps={d} stack_bytes={d}\n",
        .{ @tagName(benchmark), op_count, repetitions, fiber_stack_size },
    );

    // Benchmark stacks are created once, outside all timed regions (the
    // `stack` benchmark creates its own inside the timed loop).
    const ping_stack = try FiberStack.create();
    defer ping_stack.destroy();
    const pong_stack = try FiberStack.create();
    defer pong_stack.destroy();

    // Warmup: one unrecorded pass at a tenth of the workload.
    const warmup_ops = warmup_override orelse @max(op_count / 10, 1000);
    if (warmup_ops > 0) _ = runBenchmark(benchmark, ping_stack, pong_stack, warmup_ops);

    var per_op_samples: [64]f64 = undefined;
    std.debug.assert(repetitions <= per_op_samples.len);
    for (0..repetitions) |rep| {
        const sample = runBenchmark(benchmark, ping_stack, pong_stack, op_count);
        per_op_samples[rep] = sample.perOpNs();
        std.debug.print(
            "  rep {d}: total_ns={d} per_op_ns={d:.2}\n",
            .{ rep + 1, sample.total_ns, sample.perOpNs() },
        );
    }

    const timed = per_op_samples[0..repetitions];
    std.mem.sort(f64, timed, {}, std.sort.asc(f64));
    const median = if (repetitions % 2 == 1)
        timed[repetitions / 2]
    else
        (timed[repetitions / 2 - 1] + timed[repetitions / 2]) / 2.0;
    switch (benchmark) {
        .pingpong => std.debug.print(
            "RESULT bench=pingpong median_oneway_ns={d:.2} min_oneway_ns={d:.2} median_rtt_ns={d:.2} min_rtt_ns={d:.2}\n",
            .{ median, timed[0], median * 2.0, timed[0] * 2.0 },
        ),
        .spawn, .stack => std.debug.print(
            "RESULT bench={s} median_per_op_ns={d:.2} min_per_op_ns={d:.2}\n",
            .{ @tagName(benchmark), median, timed[0] },
        ),
    }
}
