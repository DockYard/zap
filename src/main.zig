const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const zap = @import("zap");
const compiler = zap.compiler;
const ir = zap.ir;
const build_cache = zap.build_cache;
const zir_backend = zap.zir_backend;
const zir_builder = zap.zir_builder;
const zig_lib_archive = @import("zig_lib_archive");
const env = zap.env;

/// Global Io instance for main thread operations.
var global_io: Io = std.Options.debug_io;

/// The live process environment map, captured from `std.process.Init` at
/// startup. Phase 4.c uses it as the seam to thread the runtime leak-report
/// knobs (`ZAP_ERROR_FORMAT` / `ZAP_LEAKS_FATAL`) into a child binary `zap
/// run` spawns: `propagateLeakReportEnv` `.put()`s into this map and
/// `runBinary` passes it as the child's `environ_map`. Null until `main`
/// binds it (host tests that call helpers without going through `main` keep
/// the inherited-environment behavior).
var global_env_map: ?*std.process.Environ.Map = null;

var manifest_daemon_request_counter: u64 = 0;

extern "c" fn mkfifo(pathname: [*:0]const u8, mode: std.c.mode_t) c_int;

fn stderrProgressEnabled() bool {
    std.Io.File.stderr().enableAnsiEscapeCodes(global_io) catch return false;
    return true;
}

fn profileEnabled() bool {
    return std.c.getenv("ZAP_PROFILE") != null;
}

var incremental_trace_enabled_override: ?bool = null;

fn setIncrementalTraceEnabledOverride(enabled: ?bool) void {
    incremental_trace_enabled_override = enabled;
}

fn incrementalTraceEnabled() bool {
    if (incremental_trace_enabled_override) |enabled| return enabled;
    return std.c.getenv("ZAP_INCREMENTAL_TRACE") != null or
        std.c.getenv("ZAP_TRACE_INCREMENTAL") != null;
}

fn incrementalTrace(comptime format: []const u8, args: anytype) void {
    if (!incrementalTraceEnabled()) return;
    std.debug.print("\n[incremental trace] " ++ format ++ "\n", args);
}

fn applyIncrementalTraceFlag(enabled: bool) void {
    if (!enabled) return;
    setIncrementalTraceEnabledOverride(true);
    compiler.setIncrementalTraceEnabledOverride(true);
}

fn clearIncrementalTraceFlag(enabled: bool) void {
    if (!enabled) return;
    compiler.setIncrementalTraceEnabledOverride(null);
    setIncrementalTraceEnabledOverride(null);
}

const ProfileTimer = struct {
    last_ns: i128,

    fn nowNs() i128 {
        var timestamp: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &timestamp);
        return @as(i128, timestamp.sec) * 1_000_000_000 + @as(i128, timestamp.nsec);
    }

    fn start() ProfileTimer {
        return .{ .last_ns = nowNs() };
    }

    fn lapMs(self: *ProfileTimer) u64 {
        const now_ns = nowNs();
        const elapsed_ms = @as(u64, @intCast(@divTrunc(now_ns - self.last_ns, 1_000_000)));
        self.last_ns = now_ns;
        return elapsed_ms;
    }
};

fn profileLap(
    timer: *?ProfileTimer,
    comptime label_format: []const u8,
    args: anytype,
) void {
    if (timer.*) |*active_timer| {
        std.debug.print("\n[daemon stage ", .{});
        std.debug.print(label_format, args);
        std.debug.print("] ms={d}\n", .{active_timer.lapMs()});
    }
}

/// Classify `argv[1]` as a Zig toolchain subcommand the embedded Zig
/// compiler (`libzap_compiler.a`) can service in-process. Returns 0
/// when argv[1] is not such a subcommand. See `zap_fork_classify_subtool`
/// in the Zig fork (`src/zir_api.zig`).
extern "c" fn zap_fork_classify_subtool(
    argc: c_int,
    argv: [*]const [*:0]const u8,
) callconv(.c) c_int;

/// Run the Zig toolchain subcommand identified by `argv[1]` in-process
/// and return its exit code. See `zap_fork_run_subtool` in the Zig
/// fork.
extern "c" fn zap_fork_run_subtool(
    argc: c_int,
    argv: [*]const [*:0]const u8,
) callconv(.c) c_int;

pub fn main(init: std.process.Init) !void {
    // Use Io and allocator from Init — no manual setup needed.
    global_io = init.io;
    // Phase 4.c: capture the live env map so `zap run` can thread the
    // leak-report knobs into the child binary it spawns (see
    // `propagateLeakReportEnv` / `runBinary`).
    global_env_map = init.environ_map;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Zig toolchain subcommand forwarding.
    //
    // Zig's cross-compilation pipeline builds CRT/libc/compiler_rt and
    // links objects by having the running executable re-invoke itself
    // as `<self_exe> clang|-cc1|-cc1as|ld.lld|lld-link|wasm-ld|ar ...`.
    // When `-Dtarget=` selects a foreign target (e.g. a Linux ELF
    // target from a macOS host), `libzap_compiler.a` re-spawns THIS
    // binary with one of those subcommands. The embedded Zig compiler
    // can service them in-process; we must recognize them up front and
    // dispatch into the fork, exactly as the Zig CLI's own `mainArgs`
    // does — otherwise the spawned child is a no-op and the cross
    // build silently produces no artifact.
    //
    // This runs before ANY other argument handling (including the
    // `args.len < 2` check) because these invocations are not normal
    // Zap CLI usage: argv[1] is a Zig tool name, not a Zap command,
    // and the process exists solely to run that tool. The raw
    // null-terminated process argv is used so the tool entry points
    // see exactly the layout Zig produced.
    if (args.len >= 2) {
        const subtool_arena = init.arena.allocator();
        const c_argv = try subtool_arena.alloc([*:0]const u8, args.len);
        for (args, 0..) |a, i| {
            c_argv[i] = (try subtool_arena.dupeZ(u8, a)).ptr;
        }
        const argc: c_int = @intCast(args.len);
        if (zap_fork_classify_subtool(argc, c_argv.ptr) != 0) {
            const code = zap_fork_run_subtool(argc, c_argv.ptr);
            std.process.exit(@truncate(@as(u32, @bitCast(code))));
        }
    }

    if (args.len < 2) {
        printUsage();
        std.process.exit(0);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        std.process.exit(0);
    } else if (std.mem.eql(u8, command, "build")) {
        try cmdBuild(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "run")) {
        try cmdRun(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "test")) {
        try cmdTest(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "init")) {
        try cmdInit(allocator);
    } else if (std.mem.eql(u8, command, "deps")) {
        try cmdDeps(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "doc")) {
        try cmdDoc(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "explain")) {
        try cmdExplain(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "addr2line")) {
        try cmdAddr2line(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "__manifest-incremental-daemon")) {
        if (args.len != 3) {
            std.process.exit(2);
        }
        runManifestIncrementalDaemon(allocator, args[2]) catch |err| {
            std.debug.print("Error: manifest incremental daemon failed to start: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
    } else if (std.mem.eql(u8, command, "__manifest-incremental-daemon-shutdown-all")) {
        shutdownManifestDaemonsInCwd(allocator) catch |err| {
            std.debug.print("Error: manifest incremental daemon shutdown failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
    } else {
        // stderr writer removed in 0.16
        std.debug.print("Error: unknown command: {s}\n\nRun 'zap --help' for usage.\n", .{command});
        std.process.exit(1);
    }
}

fn printUsage() void {
    // stderr writer removed in 0.16
    std.debug.print(
        \\Usage: zap <command> [options]
        \\
        \\Commands:
        \\  build [target]    Build the specified target (defaults to :default)
        \\  run [target]      Build and run the specified bin target (defaults to :default)
        \\  run <file.zap>    Compile and run a single-file script (top-level main/1)
        \\  test [options]    Run the test suite
        \\  init              Scaffold a new project in the current directory
        \\  doc [options]     Generate documentation from @doc attributes
        \\  deps update       Re-resolve all dependencies and rewrite zap.lock
        \\  deps update <name> Re-resolve a single dependency
        \\  explain Zxxxx     Print the long-form explanation for a diagnostic code
        \\  addr2line <bin> <addr>...  Symbolize crash-report addresses against a
        \\                    (possibly stripped) binary + its .dSYM/split-debug
        \\                    artifact and .zap-symbols sidecar
        \\
        \\Build flags (Zig build-system syntax; one shared pipeline for
        \\build + run, manifest + script — the CLI overrides the manifest):
        \\  -Doptimize=<mode> Debug | ReleaseSafe | ReleaseFast | ReleaseSmall
        \\  -Dmemory=<Type>   Memory manager (e.g. Memory.ARC, Memory.Arena;
        \\                    script mode: stdlib managers only)
        \\  -Dtarget=<triple> Cross-compile target (e.g. x86_64-linux-gnu)
        \\  -Dcpu=<cpu>       Target CPU model/features (e.g. baseline, apple_m1)
        \\  -Druntime-concurrency=<on|off>
        \\                    Comptime concurrency-runtime gate (default off:
        \\                    zero cost — no kernel linked, no zap_proc_*
        \\                    symbols; overrides Zap.Manifest.runtime_concurrency)
        \\  -Druntime-tracing=<on|off>
        \\                    Comptime message-flow trace gate (default off:
        \\                    zero trace instructions in the kernel; requires
        \\                    runtime-concurrency on; overrides
        \\                    Zap.Manifest.runtime_tracing)
        \\  -D<key>=<value>   Custom build option (read via System.get_build_opt)
        \\
        \\Options:
        \\  --build-file <path>  Use a specific build file (default: build.zap)
        \\  --zap-lib-dir <dir>  Use a specific Zap stdlib directory (overrides ZAP_LIB_DIR)
        \\  --watch, -w       Watch source files and rebuild on changes
        \\  --trace-incremental
        \\                    Print incremental invalidation and backend selection trace
        \\  --collect-arc-stats Compile ARC counter increments into the generated runtime
        \\  --seed <integer>  Set the test seed for deterministic ordering
        \\  --timings         Print every Zest test case duration
        \\  --slowest <count> Print the slowest Zest test cases
        \\  -- <args...>      Pass arguments to the program or test binary
        \\
        \\Script mode (zap run <file.zap>): -D flags precede the script path
        \\and are consumed there; every token after the path forwards to
        \\main/1 verbatim (including -D-looking tokens and a literal --).
        \\
        \\Examples:
        \\  zap build
        \\  zap run
        \\  zap build my_app -Doptimize=ReleaseFast
        \\  zap run my_app -- arg1 arg2
        \\  zap build --watch
        \\  zap run -w
        \\  zap test --seed 12345
        \\  zap test --watch --trace-incremental
        \\  zap test --watch
        \\  zap test -- --list
        \\  zap doc
        \\  zap doc --no-deps
        \\  zap init
        \\  zap run script.zap arg1 arg2
        \\  zap run -Doptimize=ReleaseFast -Dmemory=Memory.Arena script.zap -- arg1
        \\  zap build -Dtarget=aarch64-linux-gnu -Dcpu=baseline my_app
        \\
    , .{});
}

// ---------------------------------------------------------------------------
// Command: build
// ---------------------------------------------------------------------------

fn cmdBuild(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var parsed = try parseTargetArgs(allocator, args);
    defer parsed.deinit(allocator);
    applyIncrementalTraceFlag(parsed.trace_incremental);
    defer clearIncrementalTraceFlag(parsed.trace_incremental);

    const target = parsed.target orelse "default";

    const project_root = try discoverBuildFile(allocator, parsed.build_file);
    defer allocator.free(project_root);
    if (parsed.watch) {
        try watchAndRebuild(allocator, project_root, target, parsed.build_opts, parsed.build_overrides, .none, &.{}, parsed.collect_arc_stats, parsed.zap_lib_dir);
        return;
    }

    const artifact = try buildTarget(allocator, project_root, target, parsed.build_opts, parsed.build_overrides, parsed.collect_arc_stats, parsed.zap_lib_dir);
    artifact.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Command: run
// ---------------------------------------------------------------------------

/// On-disk classification of the first positional given to `zap run`.
/// Path semantics win whenever the positional resolves to something
/// that exists on disk; otherwise it is treated as a manifest target
/// name (today's behavior, fully unchanged).
const RunPositionalKind = union(enum) {
    /// No positional, or the positional is not an existing on-disk
    /// path — preserve today's manifest-target behavior verbatim.
    manifest,
    /// The positional is a directory containing `build.zap`, or a file
    /// literally named `build.zap` — the existing manifest flow.
    manifest_path,
    /// The positional is an existing regular file (symlinks resolved)
    /// that is NOT named `build.zap` — single-file script mode. The
    /// payload is the index into `args` of that positional so the
    /// caller can forward everything after it to `main/1`.
    script: struct {
        path: []const u8,
        arg_index: usize,
    },
};

/// Locate the first positional argument (the would-be manifest target
/// / script path) without disturbing `parseTargetArgs`, skipping
/// recognized build flags and the values they consume, and stopping at
/// an explicit `--`. Returns the index into `args` of that positional,
/// or null when there is none before `--`.
///
/// The value-consuming set here MUST mirror EXACTLY the two-token flags
/// `parseTargetArgs` (and the manifest-side `manifestLeadingFlagEnd` /
/// `buildFlagScanSkip` scanners) recognize: `--build-file`,
/// `--zap-lib-dir`, `--seed`, `--slowest`. Phase 4 collapsed every build option to
/// the single Zig-style `-D<key>=<value>` token form and DELETED the
/// old two-token script spellings (`-O <mode>`, `--memory <name>`,
/// `--target <triple>`) entirely — none are recognized by any other
/// scanner. Treating a now-unrecognized token like `--target` /
/// `--memory` / `-O` as value-consuming here would skip it AND swallow
/// the following token (the actual script path), mis-dispatching
/// `zap run --target ./s.zap` to the manifest path with a confusing
/// "unexpected argument" instead of running the script. Per the
/// locked position contract only `-D…`, `--zap-lib-dir`, boolean build
/// flags such as `--watch`/`--trace-incremental`, and the dedicated
/// test-runner options are recognized leading flags; any other
/// dash-token is just a normal flag/positional and must not consume
/// the next token.
fn firstPositionalIndex(args: []const []const u8) ?usize {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) return null;
        if (std.mem.eql(u8, arg, "--build-file") or
            std.mem.eql(u8, arg, "--zap-lib-dir") or
            std.mem.eql(u8, arg, "--seed") or
            std.mem.eql(u8, arg, "--slowest"))
        {
            i += 1; // value-consuming: skip the flag's value too
            continue;
        }
        if (std.mem.eql(u8, arg, "--watch") or
            std.mem.eql(u8, arg, "-w") or
            std.mem.eql(u8, arg, "--trace-incremental") or
            std.mem.eql(u8, arg, "--collect-arc-stats") or
            std.mem.eql(u8, arg, "--no-deps") or
            std.mem.eql(u8, arg, "--timings") or
            std.mem.startsWith(u8, arg, "-D"))
        {
            continue;
        }
        // First non-flag token is the positional.
        return i;
    }
    return null;
}

/// Classify the first positional. Precedence: if it resolves to an
/// existing on-disk file or directory, path semantics decide; only when
/// nothing exists on disk does it fall back to manifest-target
/// behavior. Symlinks are resolved before the file-vs-`build.zap`
/// decision so a symlinked script is still treated as a script.
fn classifyRunPositional(allocator: std.mem.Allocator, args: []const []const u8) !RunPositionalKind {
    const idx = firstPositionalIndex(args) orelse return .manifest;
    const raw = args[idx];

    // Resolve symlinks first; a path that does not exist falls through
    // to manifest-target semantics (unchanged behavior).
    const real = std.Io.Dir.cwd().realPathFileAlloc(global_io, raw, allocator) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .manifest,
        else => |real_path_err| return real_path_err,
    };
    defer allocator.free(real);

    const stat = std.Io.Dir.cwd().statFile(global_io, real, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .manifest,
        else => |stat_err| return stat_err,
    };
    switch (stat.kind) {
        .directory => {
            // A directory positional only changes nothing today; if it
            // contains build.zap it is the manifest project, otherwise
            // still manifest (discoverBuildFile will surface the
            // error). Either way: existing flow.
            return .manifest_path;
        },
        .file => {
            if (std.mem.eql(u8, std.fs.path.basename(real), "build.zap")) {
                return .manifest_path;
            }
            return .{ .script = .{ .path = raw, .arg_index = idx } };
        },
        else => return .manifest,
    }
}

fn cmdRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Dispatch: an existing regular file that is not `build.zap`
    // (symlinks resolved) is a single-file script. Everything else —
    // no positional, a dir, a `build.zap` file, or a non-existent
    // positional — stays on the manifest path with byte-identical
    // behavior.
    switch (try classifyRunPositional(allocator, args)) {
        .script => |s| return cmdRunScript(allocator, args, s.path, s.arg_index),
        .manifest, .manifest_path => {},
    }

    // Manifest path. The Zig-style `-D<key>=<value>` build flags are
    // single self-contained tokens, so positional classification above
    // already located the target/script unambiguously (no value-token
    // can shadow it). `parseTargetArgs` parses the SAME `-D` flags
    // through the SAME shared `parseBuildOverrides`, and `buildTarget`
    // applies them with the SAME `applyBuildOverrides` step the script
    // path uses — one pipeline, no script-mode special case.
    var parsed = try parseTargetArgs(allocator, args);
    defer parsed.deinit(allocator);
    applyIncrementalTraceFlag(parsed.trace_incremental);
    defer clearIncrementalTraceFlag(parsed.trace_incremental);

    // Phase 4.c: thread the leak-report knobs to the runtime of the program
    // we will run (same seam as the script path) — the spawned binary
    // inherits this process's `ZAP_ERROR_FORMAT` / `ZAP_LEAKS_FATAL`.
    propagateLeakReportEnv(parsed.build_overrides) catch |err| failLeakReportEnvPropagation(err);

    const target = parsed.target orelse "default";

    const project_root = try discoverBuildFile(allocator, parsed.build_file);
    defer allocator.free(project_root);
    if (parsed.watch) {
        try watchAndRebuild(allocator, project_root, target, parsed.build_opts, parsed.build_overrides, .program, parsed.run_args, parsed.collect_arc_stats, parsed.zap_lib_dir);
        return;
    }

    const artifact = try buildTarget(allocator, project_root, target, parsed.build_opts, parsed.build_overrides, parsed.collect_arc_stats, parsed.zap_lib_dir);
    defer artifact.deinit(allocator);

    if (artifact.kind != .bin) {
        std.debug.print("Error: target :{s} is {s}, not runnable\n", .{ target, @tagName(artifact.kind) });
        std.process.exit(1);
    }

    // A `-Dtarget=`/manifest `target:` that cross-compiled for a
    // FOREIGN arch/OS produces a binary this host cannot exec. The
    // cross-build succeeded; `zap run` here behaves like `zap build`
    // (report the artifact, exit 0) instead of attempting to run it
    // (which would only yield a cryptic `error.InvalidExe`) — for BOTH
    // the watch and the one-shot run path. A bare `-Dcpu=` keeps
    // `artifact.target == null` and stays host-runnable.
    if (!targetIsHostRunnable(artifact.target)) {
        std.debug.print(
            "Cross-compiled for '{s}': binary written to {s}\n" ++
                "  (not executed — it targets a foreign architecture/OS this host cannot run; " ++
                "the cross build itself succeeded)\n",
            .{ artifact.target.?, artifact.path },
        );
        std.process.exit(0);
    }

    // Normal run: build, run, exit with the binary's exit code
    const exit_code = compiler.runBinaryWithEnv(allocator, global_io, artifact.path, parsed.run_args, global_env_map) catch |err| {
        std.debug.print("Error running program: {}\n", .{err});
        std.process.exit(1);
    };
    std.process.exit(exit_code);
}

// ---------------------------------------------------------------------------
// Command: run <script.zap> (single-file script mode)
// ---------------------------------------------------------------------------

/// Resolve the user-global BASE directory under which script build
/// artifacts are placed. NEVER the script's own directory — this is
/// the core no-litter invariant. Precedence (highest wins):
///   1. `ZAP_SCRIPT_CACHE_DIR` — explicit override (deterministic
///      tests, sandboxes).
///   2. `XDG_CACHE_HOME`
///   3. `HOME`/.cache
///   4. OS temp dir (`TMPDIR`, else `/tmp`)
///
/// This returns ONLY the base; the uniform `zap/scripts/<content-key>`
/// suffix is appended by `scriptArtifactDirForKey` so the on-disk
/// layout is identical across every precedence source (the
/// content-addressed skip-recompile contract depends on a stable,
/// source-independent layout — a per-source suffix would make the
/// key dir location vary with where the cache root came from).
fn resolveScriptCacheRoot(alloc: std.mem.Allocator) ![]const u8 {
    if (env.getenv("ZAP_SCRIPT_CACHE_DIR")) |override| {
        return alloc.dupe(u8, override);
    }
    if (env.getenv("XDG_CACHE_HOME")) |xdg| {
        if (xdg.len > 0) return alloc.dupe(u8, xdg);
    }
    if (env.getenv("HOME")) |home| {
        if (home.len > 0) return std.fs.path.join(alloc, &.{ home, ".cache" });
    }
    const tmp = env.getenv("TMPDIR") orelse "/tmp";
    return alloc.dupe(u8, tmp);
}

/// The content-addressed script artifact directory for `content_key`:
/// `<resolveScriptCacheRoot()>/zap/scripts/<content_key>`. The
/// directory (and its parents) is created. This is process-shared and
/// stable: two invocations with the same content key resolve to the
/// SAME directory, which is exactly what makes the skip-recompile fast
/// path possible while still keeping every byte out of the script's
/// own directory.
fn scriptArtifactDirForKey(alloc: std.mem.Allocator, content_key: []const u8) ![]const u8 {
    const root = try resolveScriptCacheRoot(alloc);
    const dir = try std.fs.path.join(alloc, &.{ root, "zap", "scripts", content_key });
    try std.Io.Dir.cwd().createDirPath(global_io, dir);
    return dir;
}

/// A private, process-unique STAGING directory under the same cache
/// root, used to compile a fresh artifact before it is atomically
/// published into its content-key directory. Concurrent runs that
/// race on the same content key each stage in their own directory and
/// then atomically rename the finished binary into place, so no run
/// ever observes a half-written executable.
var script_stage_seq: std.atomic.Value(u64) = .init(0);

fn makeScriptStagingDir(alloc: std.mem.Allocator) ![]const u8 {
    const root = try resolveScriptCacheRoot(alloc);
    // Monotonic clock + a process-private atomic sequence + the PID
    // keep concurrent runs and back-to-back invocations from sharing
    // a staging directory without pulling in a CSPRNG.
    const ts = std.Io.Timestamp.now(global_io, .awake);
    const seq = script_stage_seq.fetchAdd(1, .monotonic);
    const pid = std.c.getpid();
    const unique = try std.fmt.allocPrint(alloc, "{d}-{d}-{d}", .{ pid, ts.nanoseconds, seq });
    // Staging lives under `zap/.staging` — a SIBLING of
    // `zap/scripts`, NOT inside it — so the content-key directory
    // namespace under `zap/scripts/<key>` stays pristine (a staging
    // entry there would be indistinguishable from a key dir). It is
    // still under the same cache root, so publishing into
    // `zap/scripts/<key>` is a same-filesystem atomic rename.
    const dir = try std.fs.path.join(alloc, &.{ root, "zap", ".staging", unique });
    try std.Io.Dir.cwd().createDirPath(global_io, dir);
    return dir;
}

/// Enforce the single-file script contract on the parsed script. D1:
/// the script is exempt from one-struct-per-file / name=path
/// validation (it is one synthetic module). D4: the carve-out applies
/// ONLY to a literal top-level `fn main`/`pub fn main` of arity 1.
/// Returns an owned diagnostic string on violation, null when valid.
fn enforceScriptContract(
    alloc: std.mem.Allocator,
    parser: *const zap.Parser,
) !?[]const u8 {
    const hoisted = parser.hoisted_script_functions.items;
    if (hoisted.len == 0) {
        return try alloc.dupe(
            u8,
            "script must define a top-level `fn main(args :: [String])` — " ++
                "no top-level function was found",
        );
    }
    if (hoisted.len > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "a script may define exactly one top-level function (its `main/1` entry point); " ++
                "found {d}. Move the others inside a `pub struct` in the same file.",
            .{hoisted.len},
        );
    }

    const main_fn = hoisted[0];
    const name = parser.interner.get(main_fn.name);
    if (!std.mem.eql(u8, name, "main")) {
        return try std.fmt.allocPrint(
            alloc,
            "the script's single top-level function must be named `main`, found `{s}`. " ++
                "Either rename it to `main` or move it inside a `pub struct`.",
            .{name},
        );
    }
    if (main_fn.clauses.len == 0 or main_fn.clauses[0].params.len != 1) {
        const got: usize = if (main_fn.clauses.len == 0) 0 else main_fn.clauses[0].params.len;
        return try std.fmt.allocPrint(
            alloc,
            "the script's top-level `main` must take exactly one argument " ++
                "(`fn main(args :: [String])`), found arity {d}.",
            .{got},
        );
    }
    return null;
}

/// Decide whether a binary built for `target_triple` can be EXECUTED on
/// this host. A `zap run` (script or manifest) builds *and runs* the
/// artifact; a binary cross-compiled for a foreign architecture/OS
/// cannot be exec'd here (the kernel rejects it — historically surfaced
/// as a cryptic `error.InvalidExe`), so the caller must report the
/// produced artifact instead of attempting to run it.
///
/// `target_triple` is the post-override `config.target`:
///   * `null` ⇒ native build ⇒ always runnable (a bare `-Dcpu=` keeps
///     `target` null; CPU only refines features, never arch/OS — the
///     arch-safety invariant — so a CPU-only build stays host-runnable).
///   * non-null ⇒ parse `arch-os-abi`. The binary is runnable iff BOTH
///     the resolved arch AND OS equal the host's. ABI/libc differences
///     (e.g. `*-linux-gnu` vs `*-linux-musl` on a Linux host) do not by
///     themselves stop the kernel from exec'ing a binary, so only
///     arch+OS are compared; an unparseable triple is treated as
///     not-runnable (fail safe — the build step itself already
///     rejected genuinely invalid triples upstream, so reaching here
///     with a non-null triple means it built for *something* foreign).
fn targetIsHostRunnable(target_triple: ?[]const u8) bool {
    const triple = target_triple orelse return true;

    var iter = std.mem.tokenizeAny(u8, triple, "-");
    const arch_str = iter.next() orelse return false;
    const os_str = iter.next() orelse return false;

    const arch = std.meta.stringToEnum(std.Target.Cpu.Arch, arch_str) orelse return false;
    const os_tag = std.meta.stringToEnum(std.Target.Os.Tag, os_str) orelse return false;

    return arch == builtin.target.cpu.arch and os_tag == builtin.target.os.tag;
}

/// The Zig-style optimize mode names accepted by script mode's `-O`
/// flag, in declaration order, each paired with the `BuildConfig`
/// optimize value it selects. Single source of truth so the parser,
/// the diagnostic, and the help text never drift.
const SCRIPT_OPTIMIZE_MODES = [_]struct {
    name: []const u8,
    value: zap.builder.BuildConfig.Optimize,
}{
    .{ .name = "Debug", .value = .debug },
    .{ .name = "ReleaseSafe", .value = .release_safe },
    .{ .name = "ReleaseFast", .value = .release_fast },
    .{ .name = "ReleaseSmall", .value = .release_small },
};

/// The stdlib memory managers accepted by script mode's `--memory`
/// flag. Script mode is single-file with no dependency graph, so only
/// these built-in managers are resolvable; any other (third-party or
/// misspelled) name is rejected. Single source of truth shared by the
/// parser, the diagnostic, and the help text.
const SCRIPT_MEMORY_MANAGERS = [_][]const u8{
    "Memory.ARC",
    "Memory.ORC",
    "Memory.Arena",
    "Memory.NoOp",
    "Memory.Leak",
    "Memory.Tracking",
    "Memory.GC",
};

/// Pure helper: map a Zig-style optimize mode name (`Debug`,
/// `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`) to the matching
/// `BuildConfig.Optimize`. Returns `null` for any unrecognized name so
/// the caller can emit a precise diagnostic instead of silently
/// falling back. Matching is exact (case-sensitive) — only the Zig
/// spelling is accepted, keeping `zap run -O ...` consistent with
/// `zig build -O...`.
fn parseScriptOptimizeMode(name: []const u8) ?zap.builder.BuildConfig.Optimize {
    for (SCRIPT_OPTIMIZE_MODES) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.value;
    }
    return null;
}

const BuildOptimizePolicy = struct {
    frontend_optimize_mode: compiler.FrontendOptimizeMode,
    frontend_policy_tag: u64,
    backend_optimize_mode: u8,
    memory_driver_optimize: zap.memory_driver.ZapForkOptimize,
};

fn buildOptimizePolicy(
    frontend_optimize_mode: compiler.FrontendOptimizeMode,
    backend_optimize_mode: u8,
    memory_driver_optimize: zap.memory_driver.ZapForkOptimize,
) BuildOptimizePolicy {
    return .{
        .frontend_optimize_mode = frontend_optimize_mode,
        .frontend_policy_tag = frontend_optimize_mode.cacheTag(),
        .backend_optimize_mode = backend_optimize_mode,
        .memory_driver_optimize = memory_driver_optimize,
    };
}

fn optimizePolicyForBuildConfig(optimize: zap.builder.BuildConfig.Optimize) BuildOptimizePolicy {
    return switch (optimize) {
        .debug => buildOptimizePolicy(.debug, 0, .Debug),
        .release_safe => buildOptimizePolicy(.release_safe, 1, .ReleaseSafe),
        .release_fast => buildOptimizePolicy(.release_fast, 2, .ReleaseFast),
        .release_small => buildOptimizePolicy(.release_small, 3, .ReleaseSmall),
    };
}

/// Pure helper: return `true` iff `name` is one of the stdlib memory
/// managers script mode supports. Script mode has no dependency
/// mechanism and no project source root, so a third-party or
/// misspelled manager cannot be resolved — the caller rejects anything
/// this returns `false` for with a clear, list-the-valid-names error.
fn validateScriptMemoryManager(name: []const u8) bool {
    for (SCRIPT_MEMORY_MANAGERS) |valid| {
        if (std.mem.eql(u8, name, valid)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Unified Zig-style `-D<key>=<value>` build-flag pipeline
//
// Zap drives Zig's build pipeline, so Zap mirrors Zig's build-system
// flag SYNTAX (`-D<name>=<value>`) and its standard build flags. There
// is exactly ONE parser + ONE per-field override step shared by every
// entrypoint: `zap build <target>`, `zap run <target>` (manifest), and
// `zap run <file.zap>` (script). The pipeline is uniform:
//
//   BuildConfig (build.zap CTFE  OR  synthetic scriptManifest)
//     -> applyBuildOverrides(&config, parseBuildOverrides(...))
//     -> compileAndLink(...)              (the single shared tail)
//
// The CLI is the ultimate source of truth: a set `-D` value overrides
// the manifest/synthetic field; an unset `-D` keeps the base value.
// Every standard flag is per-field, so there is no special-casing.
// ---------------------------------------------------------------------------

/// Typed, parsed `-D` overrides. Every field is optional: `null` means
/// "the flag was not given" so `applyBuildOverrides` preserves the
/// manifest/synthetic base value (CLI-wins-when-present semantics). All
/// string payloads are slices into `args` (process-lifetime), never
/// copied — `applyBuildOverrides` stores them directly into the
/// `BuildConfig` which lives for the build.
const BuildOverrides = struct {
    optimize: ?zap.builder.BuildConfig.Optimize = null,
    /// Memory manager type name (e.g. "Memory.Arena", or a
    /// project/third-party type on the manifest path). Resolution and
    /// (script-mode) stdlib-only validation happen in
    /// `applyBuildOverrides` so the registry parser stays purely
    /// syntactic.
    memory: ?[]const u8 = null,
    /// Zig target triple (e.g. "aarch64-linux-gnu"). Empty string is
    /// rejected by the parser (missing value).
    target: ?[]const u8 = null,
    /// Zig CPU model/feature string (e.g. "baseline", "apple_m1").
    cpu: ?[]const u8 = null,
    /// Phase 0 — DWARF foundation: per-mode debug-info policy
    /// override. `-Ddebug-info=<full|split|none>` lets the user
    /// force a specific policy regardless of optimize mode. `full`
    /// embeds DWARF in the artifact AND publishes a sibling debug
    /// artifact (`.dSYM` on Mach-O); `split` is the build-time
    /// pairing of stripped main binary + sibling debug artifact;
    /// `none` strips and suppresses any sibling. Null leaves the
    /// per-optimize-mode default in place: Debug / ReleaseSafe
    /// behave as `full` (embedded DWARF + sibling); ReleaseFast /
    /// ReleaseSmall behave as `split` (stripped binary + sibling)
    /// per Phase 0 Gap E.
    debug_info: ?DebugInfoOverride = null,
    /// Phase 0 — DWARF foundation: `-Dframe-pointers=on|off`
    /// override. Frame pointers unlock `perf` / `samply` /
    /// stack-walking-via-FP without DWARF unwinder tables; they
    /// cost ~1-3% in optimized builds. Null defers to the
    /// per-mode default: on in Debug / ReleaseSafe, off in
    /// ReleaseFast / ReleaseSmall. Threaded into the per-mode
    /// `DebugInfoPolicyResolution` returned by
    /// `resolveDebugInfoPolicy`.
    frame_pointers: ?bool = null,
    /// Phase 4.a — unified diagnostics: `-Derror-format=text|json`
    /// (also accepted as the `--error-format=<...>` long flag). `text`
    /// is the human renderer; `json` emits the stable LSP-projectable
    /// canonical Error IR schema on stdout for LSP / CI / `zap fix`.
    /// Null leaves the default (`text`).
    ///
    /// Phase 4.c also threads this to the RUNTIME leak reporter: when a
    /// run target uses `Memory.Tracking`, `-Derror-format=json` makes the
    /// deinit-time leak report emit its machine-readable projection
    /// (the runtime reads `ZAP_ERROR_FORMAT`, which the run path sets in
    /// the child environment from this field).
    error_format: ?zap.diagnostics.OutputFormat = null,
    /// Phase 4.c — leak subsystem CI mode: `-Dleaks-fatal`. Under
    /// `Memory.Tracking`, any surviving leak at program exit forces a
    /// non-zero process exit (distinct code `7`) so a CI run fails on a
    /// leak. Wired to the runtime via the `ZAP_LEAKS_FATAL` env var the
    /// run path sets in the child environment. No effect under
    /// non-tracking managers (they do not detect leaks). Default off.
    leaks_fatal: bool = false,
    /// P2-J1 — `-Druntime-concurrency=on|off`: per-build override of the
    /// manifest's `runtime_concurrency` comptime gate. `on` links the
    /// per-target concurrency kernel object and enables the runtime
    /// bootstrap; `off` forces the zero-cost posture. Null defers to the
    /// manifest field (default `false`).
    runtime_concurrency: ?bool = null,
    /// P6-J6 — `-Druntime-tracing=on|off`: per-build override of the
    /// manifest's `runtime_tracing` comptime trace gate. `on` compiles the
    /// concurrency kernel with the message-flow trace points and the
    /// bounded in-memory trace ring; `off` forces the zero-cost posture
    /// (no trace instruction on any send/receive/spawn/exit/signal path).
    /// Requires the concurrency gate ON. Null defers to the manifest
    /// field (default `false`).
    runtime_tracing: ?bool = null,
};

/// Phase 0 — DWARF foundation: parsed `-Ddebug-info` flag value.
/// Distinct from the on-disk `zir_backend.DebugInfoPolicy` enum
/// because this layer additionally understands `split` — a build-
/// time concept that affects sidecar emission, not the in-binary
/// DWARF stripping decision.
pub const DebugInfoOverride = enum {
    full,
    split,
    none,
};

/// Phase 0 — DWARF foundation: the resolved policy a single
/// `compileAndLink` invocation observes. Encodes the in-binary
/// stripping decision, whether the build pipeline should produce a
/// sibling split-debug artifact, whether the shipped binary keeps
/// its debug-map after dsymutil has run, and the frame-pointer
/// retention.
pub const DebugInfoPolicyResolution = struct {
    /// In-binary DWARF policy passed through to the fork via
    /// `zir_backend.CompileOptions.debug_info_policy`. `null`
    /// keeps the V1 ABI (legacy Debug-only behavior); a non-null
    /// value forces the V2 ABI.
    in_binary: ?zir_backend.DebugInfoPolicy,
    /// True when the build should produce a split-debug sibling
    /// artifact next to the main binary. Mach-O: emit `.dSYM`; ELF:
    /// emit `.dwo` / `.dwp` keyed by build-id for `debuginfod`. Per
    /// Phase 0 Gap E this is true for every mode by default
    /// (`-Ddebug-info=none` suppresses it). Distinguishes "compile
    /// with DWARF" from "ship a sibling": Debug / ReleaseSafe set
    /// both; the eventual ship-with-embedded-DWARF behavior is
    /// gated separately by `ship_with_embedded_dwarf`.
    want_split_debug: bool,
    /// True when the SHIPPED binary should retain its DWARF debug-
    /// map (Debug / ReleaseSafe defaults plus the explicit
    /// `-Ddebug-info=full` override) so lldb / atos can walk DWARF
    /// directly out of the binary without consulting the sibling.
    /// False for the release-mode defaults and the explicit
    /// `-Ddebug-info=split` override — both compile WITH DWARF
    /// (`in_binary = .full`) so dsymutil can extract a sibling, and
    /// then `stripDarwinDebugMapOrExit` removes the debug-map from
    /// the published binary so the shipped artifact matches the
    /// split-debug contract (stripped main + sibling .dSYM).
    /// `-Ddebug-info=none` resolves to false here too: there is no
    /// sibling and no debug-map.
    ship_with_embedded_dwarf: bool,
    /// True when the build should keep frame pointers on every
    /// function so `perf` / `samply` / async-signal-safe crash
    /// printers can walk the stack without unwinder tables.
    frame_pointers: bool,
};

/// Phase 0 — DWARF foundation: resolve the effective debug-info
/// policy for a given optimize mode + CLI overrides.
///
/// Order of precedence:
///   1. Explicit `-Ddebug-info=<...>` value wins for the in-binary
///      stripping decision.
///   2. Explicit `-Dframe-pointers=<on|off>` wins for the
///      frame-pointer decision.
///   3. Optimize-mode defaults fill in everything else (see the
///      Phase 0 spec table):
///        * Debug, ReleaseSafe -> full DWARF, FP on, no split.
///        * ReleaseFast, ReleaseSmall -> strip in-binary DWARF,
///          emit a sibling split-debug artifact, FP off.
///
/// The output is consumed by both `compileAndLink` (it sets
/// `CompileOptions.debug_info_policy`) and the dSYM-bundling code
/// path (which honors `want_split_debug`).
/// Project a `BuildConfig.DebugInfo` override (parsed from
/// `-Ddebug-info=`) to the tri-state cache-key byte that
/// `BuildCacheOptions.debug_info_tag` / `ScriptContentKeyControls`
/// fold into the artifact hash. The byte must round-trip — flipping
/// the flag must produce a distinct cache key — so the encoding is
/// pinned here (0 = unset, 1 = full, 2 = split, 3 = none) and the
/// raw bytes are folded with no further transformation.
pub fn debugInfoCacheTagFor(override: ?zap.builder.BuildConfig.DebugInfo) u8 {
    return switch (override orelse return 0) {
        .full => 1,
        .split => 2,
        .none => 3,
    };
}

/// Project a `BuildConfig.frame_pointers` override (parsed from
/// `-Dframe-pointers=on|off`) to the cache-key byte
/// `BuildCacheOptions.frame_pointers_tag` /
/// `ScriptContentKeyControls` fold in. 0 = unset (use per-mode
/// default at resolve time), 1 = on, 2 = off.
pub fn framePointersCacheTagFor(override: ?bool) u8 {
    return switch (override orelse return 0) {
        true => 1,
        false => 2,
    };
}

pub fn resolveDebugInfoPolicy(
    optimize: zap.builder.BuildConfig.Optimize,
    override: ?DebugInfoOverride,
    frame_pointers_override: ?bool,
) DebugInfoPolicyResolution {
    const debug_or_safe = switch (optimize) {
        .debug, .release_safe => true,
        .release_fast, .release_small => false,
    };
    // Compile-time DWARF emission is on for every mode EXCEPT explicit
    // `-Ddebug-info=none`. The release-mode defaults intentionally
    // compile with `in_binary = .full` so `dsymutil` can read the
    // Mach-O debug-map (STABS / `N_OSO`) and extract a sibling `.dSYM`;
    // the post-link strip pass then removes the debug-map from the
    // published binary so the shipped artifact matches the split
    // contract (stripped main + sibling .dSYM). If we asked the fork
    // to strip at compile time (the `.none` policy), the debug-map
    // never reaches the binary and dsymutil produces an empty dSYM —
    // the spec-defined split shape never materializes. The compile-
    // then-strip sequence is implemented by
    // `generateDarwinDebugSymbolsOrExit` (dsymutil pass) followed by
    // `stripDarwinDebugMapOrExit` (Mach-O post-link `strip -S`),
    // driven by `want_split_debug` on the resolved policy.
    const in_binary: zir_backend.DebugInfoPolicy = blk: {
        if (override) |ov| {
            break :blk switch (ov) {
                .full, .split => .full,
                .none => .none,
            };
        }
        // Per-mode default: every mode keeps in-binary DWARF emission
        // enabled. Debug / ReleaseSafe ship that DWARF verbatim;
        // ReleaseFast / ReleaseSmall ship a sibling-only artifact via
        // the post-link strip pass, but the COMPILER still needs the
        // DWARF in the `.o` files for dsymutil's extraction step.
        break :blk .full;
    };
    const want_split: bool = blk: {
        if (override) |ov| {
            break :blk switch (ov) {
                .split => true,
                .full, .none => false,
            };
        }
        // Per-mode default per the Phase 0 spec table
        // (`docs/error-system-research-brief.md`, Part VI.B #13 &
        // Part VIII): Debug / ReleaseSafe embed DWARF in the binary
        // AND publish a redundant sibling for offline tools;
        // ReleaseFast / ReleaseSmall publish the sibling and let the
        // post-link strip remove the debug-map from the binary.
        // Either way `want_split_debug` drives sibling publication —
        // its meaning ("publish a sibling debug artifact alongside
        // the main binary") is the same in both branches; only the
        // post-strip toggle on `needsDarwinDebugMapStripAfterDsymutil`
        // distinguishes the embedded-DWARF default from the strip-
        // and-ship default.
        break :blk true;
    };
    // The SHIPPED binary keeps an embedded debug-map when:
    //   * Debug / ReleaseSafe default (in-binary DWARF is the
    //     primary lookup path; the sibling is a redundant offline
    //     copy).
    //   * Explicit `-Ddebug-info=full` (the user opted in to
    //     embedded DWARF regardless of optimize mode).
    // It does NOT keep embedded DWARF when:
    //   * Release-mode defaults (Gap E ships the split-debug shape
    //     by default — sibling is the privileged copy).
    //   * Explicit `-Ddebug-info=split` (the user opted in to the
    //     stripped-main-binary contract).
    //   * Explicit `-Ddebug-info=none` (no DWARF anywhere).
    const ship_with_embedded_dwarf: bool = blk: {
        if (override) |ov| {
            break :blk switch (ov) {
                .full => true,
                .split, .none => false,
            };
        }
        break :blk debug_or_safe;
    };
    const frame_pointers: bool = frame_pointers_override orelse debug_or_safe;
    return .{
        .in_binary = in_binary,
        .want_split_debug = want_split,
        .ship_with_embedded_dwarf = ship_with_embedded_dwarf,
        .frame_pointers = frame_pointers,
    };
}

/// Result of the single `-D` parser: the typed overrides, or an owned,
/// fully-formatted diagnostic (no trailing newline) describing the
/// first malformed/unknown flag. The caller surfaces `.err` uniformly
/// (print + non-zero exit) for every entrypoint.
const ParsedBuildOverrides = union(enum) {
    ok: BuildOverrides,
    err: []const u8,
};

/// The recognized `-D` keys. Mirroring Zig's build-system standard
/// flags (`-Doptimize`, `-Dtarget`, `-Dcpu`) plus Zap's `-Dmemory`.
/// Single source of truth shared by the parser and the unknown-key
/// diagnostic so adding a Zig flag is one array entry. The full
/// human-readable list (used in the unknown-key error) is derived from
/// this so it can never drift.
const BUILD_FLAG_KEYS = [_][]const u8{
    "optimize",
    "memory",
    "target",
    "cpu",
    "debug-info",
    "frame-pointers",
    "error-format",
    "leaks-fatal",
    "runtime-concurrency",
    "runtime-tracing",
};

/// Format the supported-keys list for diagnostics straight from
/// `BUILD_FLAG_KEYS` (no drift possible). Allocated in `alloc`.
fn supportedBuildKeysList(alloc: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (BUILD_FLAG_KEYS, 0..) |key, idx| {
        if (idx != 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, key);
    }
    return buf.toOwnedSlice(alloc);
}

/// THE single pure parser for the Zig-style `-D<key>=<value>` build
/// flags, shared verbatim by `zap build`, `zap run` (manifest), and
/// `zap run` (script). Scans only `args[0..leading_end]` (the flag
/// region before the target/script path); tokens at or past
/// `leading_end` are never inspected (script-mode forwards them to
/// `main/1` verbatim, including `-D`-looking ones). Each `-D` flag is
/// a single self-contained token `-D<key>=<value>`. A `-D` with no
/// `=`, an empty value, an unknown key, or an invalid `-Doptimize`
/// value yields a precise `.err` (allocated in `alloc`). Non-`-D`
/// tokens are ignored here (other flags/positionals are handled by
/// `parseTargetArgs` / the script split). Filesystem-free.
/// Shared classifier for the three `-D` scans over the build-flag
/// region (`parseBuildOverrides`, `manifestBuildOptOverridePath`,
/// `isRecognizedBuildFlagError`). Given the current index, returns the
/// next index to inspect when `args[i]` is NOT a `-D` token to process,
/// or `null` when `args[i]` is a candidate `-D` flag the caller must
/// handle itself.
///
/// Returns the program-args boundary (`end`) on `--` so a forwarded
/// program argument is never treated as a build flag, and skips a
/// value-consuming flag together with its value (`--seed -Dx=1` must
/// not parse `-Dx=1` as a build override). Mirrors `parseTargetArgs`'s
/// own value-consuming flag handling so all four scans agree.
fn buildFlagScanSkip(args: []const []const u8, i: usize, end: usize) ?usize {
    const a = args[i];
    if (std.mem.eql(u8, a, "--")) return end; // program-args boundary
    if (std.mem.eql(u8, a, "--build-file") or
        std.mem.eql(u8, a, "--zap-lib-dir") or
        std.mem.eql(u8, a, "--seed") or
        std.mem.eql(u8, a, "--slowest"))
    {
        return i + 2; // skip the flag AND its value token
    }
    if (!std.mem.startsWith(u8, a, "-D")) return i + 1;
    return null; // a `-D` candidate — caller processes it
}

fn parseBuildOverrides(
    alloc: std.mem.Allocator,
    args: []const []const u8,
    leading_end: usize,
) error{OutOfMemory}!ParsedBuildOverrides {
    var overrides: BuildOverrides = .{};

    const end = @min(leading_end, args.len);
    var i: usize = 0;
    while (i < end) {
        if (buildFlagScanSkip(args, i, end)) |next| {
            i = next;
            continue;
        }
        const a = args[i];
        i += 1;

        const kv = a[2..];

        // Phase 4.c: `-Dleaks-fatal` is a boolean *presence* flag — the CI
        // spelling the brief calls `--leaks-fatal`. A bare `-Dleaks-fatal`
        // (no `=value`) means "on"; the `-Dleaks-fatal=on|off|true|false`
        // value form is also accepted (handled in the key dispatch below).
        // Allowing the valueless form is the one deliberate exception to the
        // otherwise-mandatory `-D<key>=<value>` syntax, and only for this
        // boolean toggle.
        if (std.mem.eql(u8, kv, "leaks-fatal")) {
            overrides.leaks_fatal = true;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse {
            return .{ .err = try std.fmt.allocPrint(
                alloc,
                "build flag '{s}' is missing a value — use -D<key>=<value> (supported keys: {s})",
                .{ a, try supportedBuildKeysList(alloc) },
            ) };
        };
        const key = kv[0..eq];
        const value = kv[eq + 1 ..];

        if (value.len == 0) {
            return .{ .err = try std.fmt.allocPrint(
                alloc,
                "build flag -D{s}= has an empty value",
                .{key},
            ) };
        }

        if (std.mem.eql(u8, key, "optimize")) {
            overrides.optimize = parseScriptOptimizeMode(value) orelse {
                return .{ .err = try std.fmt.allocPrint(
                    alloc,
                    "unknown optimize mode '{s}' (valid modes: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)",
                    .{value},
                ) };
            };
        } else if (std.mem.eql(u8, key, "memory")) {
            overrides.memory = value;
        } else if (std.mem.eql(u8, key, "target")) {
            overrides.target = value;
        } else if (std.mem.eql(u8, key, "cpu")) {
            overrides.cpu = value;
        } else if (std.mem.eql(u8, key, "debug-info")) {
            // Phase 0 — DWARF foundation: explicit override of the
            // per-mode debug-info policy.
            overrides.debug_info = if (std.mem.eql(u8, value, "full"))
                .full
            else if (std.mem.eql(u8, value, "split"))
                .split
            else if (std.mem.eql(u8, value, "none"))
                .none
            else
                return .{ .err = try std.fmt.allocPrint(
                    alloc,
                    "unknown -Ddebug-info value '{s}' (valid: full, split, none)",
                    .{value},
                ) };
        } else if (std.mem.eql(u8, key, "frame-pointers")) {
            // Phase 0 — DWARF foundation: explicit override of the
            // per-mode frame-pointer policy.
            overrides.frame_pointers = if (std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true"))
                true
            else if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "false"))
                false
            else
                return .{ .err = try std.fmt.allocPrint(
                    alloc,
                    "unknown -Dframe-pointers value '{s}' (valid: on, off)",
                    .{value},
                ) };
        } else if (std.mem.eql(u8, key, "error-format")) {
            // Phase 4.a — unified diagnostics: select the human text renderer
            // or the stable LSP-projectable JSON schema.
            overrides.error_format = if (std.mem.eql(u8, value, "text"))
                .text
            else if (std.mem.eql(u8, value, "json"))
                .json
            else
                return .{ .err = try std.fmt.allocPrint(
                    alloc,
                    "unknown -Derror-format value '{s}' (valid: text, json)",
                    .{value},
                ) };
        } else if (std.mem.eql(u8, key, "leaks-fatal")) {
            // Phase 4.c: the `-Dleaks-fatal=on|off` value form (the bare
            // `-Dleaks-fatal` presence form is handled above before the
            // `=` split).
            overrides.leaks_fatal = if (std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true"))
                true
            else if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "false"))
                false
            else
                return .{ .err = try std.fmt.allocPrint(
                    alloc,
                    "unknown -Dleaks-fatal value '{s}' (valid: on, off)",
                    .{value},
                ) };
        } else if (std.mem.eql(u8, key, "runtime-concurrency")) {
            // P2-J1: per-build override of the manifest's comptime
            // concurrency gate.
            overrides.runtime_concurrency = if (std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true"))
                true
            else if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "false"))
                false
            else
                return .{ .err = try std.fmt.allocPrint(
                    alloc,
                    "unknown -Druntime-concurrency value '{s}' (valid: on, off)",
                    .{value},
                ) };
        } else if (std.mem.eql(u8, key, "runtime-tracing")) {
            // P6-J6: per-build override of the manifest's comptime
            // message-flow trace gate.
            overrides.runtime_tracing = if (std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true"))
                true
            else if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "false"))
                false
            else
                return .{ .err = try std.fmt.allocPrint(
                    alloc,
                    "unknown -Druntime-tracing value '{s}' (valid: on, off)",
                    .{value},
                ) };
        } else {
            return .{ .err = try std.fmt.allocPrint(
                alloc,
                "unknown build flag key '{s}' in '{s}' (supported keys: {s})",
                .{ key, a, try supportedBuildKeysList(alloc) },
            ) };
        }
    }

    return .{ .ok = overrides };
}

/// THE single per-field override step. Overlays each SET `-D` value
/// onto `config` so the CLI is the ultimate source of truth; an unset
/// override leaves the manifest/synthetic base value untouched. Used
/// identically by the manifest path (after `build.zap` CTFE) and the
/// script path (after the synthetic `scriptManifest`), which is what
/// makes this the only flag pipeline.
///
/// `-Dmemory=` sets `config.memory_manager.type_name` and CLEARS
/// `adapter_source_path` so the existing memory driver re-resolves the
/// overridden manager exactly as it would a manifest `memory:` value
/// (stdlib by convention; project/third-party via the dep graph on the
/// manifest path). Script-mode stdlib-only validation is the caller's
/// responsibility (`validateScriptMemoryManager`) — done before this
/// call so manifest mode keeps third-party support.
fn applyBuildOverrides(config: *zap.builder.BuildConfig, overrides: BuildOverrides) void {
    if (overrides.optimize) |opt| config.optimize = opt;
    if (overrides.memory) |mgr| {
        config.memory_manager = .{ .type_name = mgr, .adapter_source_path = null };
    }
    if (overrides.target) |t| config.target = t;
    if (overrides.cpu) |c| config.cpu = c;
    // Phase 0 — DWARF foundation: thread the per-mode debug-info and
    // frame-pointer overrides into the BuildConfig so every downstream
    // consumer (compile, dSYM bundling, manifest cache) sees a single
    // source of truth.
    if (overrides.debug_info) |dbg| {
        config.debug_info = switch (dbg) {
            .full => .full,
            .split => .split,
            .none => .none,
        };
    }
    if (overrides.frame_pointers) |fp| config.frame_pointers = fp;
    // `-Druntime-concurrency=` overrides the manifest's comptime concurrency
    // gate per-field, exactly like every other `-D` flag. An explicit override
    // is honored verbatim (marked explicit so the opt-out default does not
    // second-guess it).
    if (overrides.runtime_concurrency) |gate| {
        config.runtime_concurrency = gate;
        config.runtime_concurrency_explicit = true;
    }
    // Concurrency is opt-out: with the gate left unspecified, resolve it from
    // the (now-final) target's capability — ON where the kernel can run, OFF on
    // targets it cannot host. Runs after the target override lands above.
    resolveConcurrencyGate(config);
    // P6-J6: `-Druntime-tracing=` overrides the manifest's comptime
    // trace gate per-field. Its "requires concurrency" validation runs
    // after ALL overrides land (`validateRuntimeTracingGate`), so the
    // check sees the final resolved pair.
    if (overrides.runtime_tracing) |trace_gate| config.runtime_tracing = trace_gate;

    // Phase 4.a — unified diagnostics: install the process-wide
    // diagnostic-output policy as a single source of truth read by the
    // central `compiler.emitDiagnostics` funnel. The format comes from
    // `-Derror-format`; the security tier (brief VI.B #9) is derived from the
    // FINAL optimize mode so a release build strips absolute paths to basename
    // and suppresses internal-only detail, while Debug/ReleaseSafe stay
    // developer-facing.
    installDiagnosticOutputPolicy(config, overrides);
}

/// Map the resolved build config + overrides onto the process-wide
/// diagnostic-output policy. Factored out so both the manifest and script
/// override paths install an identical policy. The tier is derived from the
/// optimize mode via the shared `error_format.defaultTierForMode`, which is
/// the same dev-vs-release fold the runtime crash printer's path-stripping
/// policy uses — one tier vocabulary across compile-time and runtime.
/// Map an optional `-Doptimize` override to a Zig `OptimizeMode`, defaulting to
/// Debug when unset (Phase 4.b). Used by the early diagnostic-policy install in
/// `cmdRunScript` — before the full `BuildConfig` exists — so the parse-error
/// path's security tier matches what the later config-based install computes.
fn optimizeModeForOverride(optimize: ?zap.builder.BuildConfig.Optimize) std.builtin.OptimizeMode {
    return switch (optimize orelse .debug) {
        .debug => .Debug,
        .release_safe => .ReleaseSafe,
        .release_fast => .ReleaseFast,
        .release_small => .ReleaseSmall,
    };
}

fn installDiagnosticOutputPolicy(config: *const zap.builder.BuildConfig, overrides: BuildOverrides) void {
    const optimize_mode: std.builtin.OptimizeMode = switch (config.optimize) {
        .debug => .Debug,
        .release_safe => .ReleaseSafe,
        .release_fast => .ReleaseFast,
        .release_small => .ReleaseSmall,
    };
    zap.diagnostics.setOutputPolicy(.{
        .format = overrides.error_format orelse .text,
        .tier = zap.error_format.defaultTierForMode(optimize_mode),
    });
}

/// Pure parser for the script-mode `--zap-lib-dir <dir>` leading flag
/// only (the Zap stdlib locator — NOT a `-D` build option). Scans
/// `args[0..leading_end]` and returns the override path (slice into
/// `args`) or a diagnostic on a missing value. `-D` flags and any
/// other leading token are ignored here; they are parsed by the
/// shared `parseBuildOverrides`. Kept separate because `--zap-lib-dir`
/// is two-token and not part of the Zig build-flag surface.
const ScriptLibDir = union(enum) {
    ok: ?[]const u8,
    err: []const u8,
};

fn parseScriptLibDirFlag(
    alloc: std.mem.Allocator,
    args: []const []const u8,
    leading_end: usize,
) error{OutOfMemory}!ScriptLibDir {
    const end = @min(leading_end, args.len);
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--zap-lib-dir")) {
            i += 1;
            if (i >= end) {
                return .{ .err = try alloc.dupe(u8, "--zap-lib-dir requires a path") };
            }
            return .{ .ok = args[i] };
        }
    }
    return .{ .ok = null };
}

fn leadingFlagPresent(args: []const []const u8, leading_end: usize, flag: []const u8) bool {
    const end = @min(leading_end, args.len);
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return true;
    }
    return false;
}

/// Single-file script mode: compile and run a bare `.zap` file with a
/// top-level `main/1`. No `build.zap`, no manifest CTFE, no project
/// paths, no dependencies — the script is one synthetic module
/// compiled against the stdlib only. `script_path` is the on-disk file;
/// `script_arg_index` is its position in `args`.
///
/// Flag-position contract (production-locked, mirrors `zig run` /
/// `cargo run`): ALL leading flags — the Zig-style `-D<key>=<value>`
/// build flags (`-Doptimize`, `-Dmemory`, `-Dtarget`, `-Dcpu`) and
/// the `--zap-lib-dir <dir>` stdlib locator, plus boolean build flags
/// such as `--trace-incremental` — MUST precede the script path and
/// are CONSUMED there (never forwarded). EVERYTHING after the script
/// path is forwarded VERBATIM to `main/1`'s `[String]` — there are NO
/// reserved post-path tokens: a `-D`-looking token, any leading dashes,
/// and a literal `--` are all passed through unchanged. The post-path
/// region is opaque passthrough.
fn cmdRunScript(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    script_path: []const u8,
    script_arg_index: usize,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // ----- Argument split -------------------------------------------------
    // Recognized leading flags may appear before the script path and
    // are CONSUMED here (never forwarded to `main/1`): the
    // `--zap-lib-dir <dir>` stdlib locator and the Zig-style
    // `-D<key>=<value>` build flags (`-Doptimize`, `-Dmemory`,
    // `-Dtarget`, `-Dcpu`), plus `--trace-incremental`. They are
    // parsed by the SAME shared parsers every entrypoint uses
    // (`parseScriptLibDirFlag` + `parseBuildOverrides`). Everything
    // AFTER the script path is
    // forwarded to `main/1` verbatim (including `-D`-looking tokens
    // and a literal `--`). Build defaults come from the synthetic
    // `scriptManifest`; `applyBuildOverrides` overlays any `-D`.
    const lib_dir_flag = parseScriptLibDirFlag(alloc, args, script_arg_index) catch {
        std.debug.print("Error: out of memory parsing script flags\n", .{});
        std.process.exit(1);
    };
    const zap_lib_dir_override: ?[]const u8 = switch (lib_dir_flag) {
        .err => |msg| {
            std.debug.print("Error: {s}\n", .{msg});
            std.process.exit(1);
        },
        .ok => |path| path,
    };
    const parsed_overrides = parseBuildOverrides(alloc, args, script_arg_index) catch {
        std.debug.print("Error: out of memory parsing build flags\n", .{});
        std.process.exit(1);
    };
    const overrides: BuildOverrides = switch (parsed_overrides) {
        .err => |msg| {
            std.debug.print("Error: {s}\n", .{msg});
            std.process.exit(1);
        },
        .ok => |ov| ov,
    };
    const trace_incremental = leadingFlagPresent(args, script_arg_index, "--trace-incremental");
    applyIncrementalTraceFlag(trace_incremental);
    defer clearIncrementalTraceFlag(trace_incremental);

    // Phase 4.b: install the diagnostic output policy EARLY — before the
    // script contract-parse below — so a `-Derror-format=json` on a script
    // with a SYNTAX error still emits JSON. The contract parse runs before the
    // full `BuildConfig` exists (which the later `installDiagnosticOutputPolicy`
    // needs for the tier), so derive the tier from the parsed `-Doptimize`
    // override directly. The later full install overwrites this idempotently
    // for the success path; the parse-error path exits before reaching it.
    zap.diagnostics.setOutputPolicy(.{
        .format = overrides.error_format orelse .text,
        .tier = zap.error_format.defaultTierForMode(optimizeModeForOverride(overrides.optimize)),
    });

    // Phase 4.c: thread the leak-report knobs to the RUNTIME of the program
    // we are about to compile + run. The runtime's deinit-time leak reporter
    // (active under `Memory.Tracking`) reads `ZAP_ERROR_FORMAT` /
    // `ZAP_LEAKS_FATAL`; set them in THIS process's environment now so the
    // child binary `runBinary` spawns inherits them. Set before any compile
    // or run work so the eventual spawn always sees them.
    propagateLeakReportEnv(overrides) catch |err| failLeakReportEnvPropagation(err);

    // Script mode is single-file with no dependency graph, so a
    // `-Dmemory=` value MUST be a stdlib manager — reject third-party
    // names here (manifest mode keeps third-party support). Same
    // diagnostic the legacy script `--memory` produced.
    if (overrides.memory) |mgr| {
        if (!validateScriptMemoryManager(mgr)) {
            std.debug.print(
                "Error: unsupported memory manager '{s}' — script mode is single-file with no dependency graph and supports only the stdlib managers: Memory.ARC, Memory.ORC, Memory.Arena, Memory.NoOp, Memory.Leak, Memory.Tracking, Memory.GC\n",
                .{mgr},
            );
            std.process.exit(1);
        }
    }

    // Position contract (production-locked): the script-path region is
    // OPAQUE PASSTHROUGH. EVERY token after the script path forwards to
    // `main/1` VERBATIM and in order — there are NO reserved post-path
    // tokens. A `-D`-looking token and a literal `--` are passed
    // through unchanged (NOT consumed, NOT a separator), exactly like
    // `zig run script.zig -- ...` treats everything after the file.
    var forwarded: std.ArrayListUnmanaged([]const u8) = .empty;
    {
        var i: usize = script_arg_index + 1;
        while (i < args.len) : (i += 1) {
            try forwarded.append(alloc, args[i]);
        }
    }

    // ----- Read the script ------------------------------------------------
    const script_source = std.Io.Dir.cwd().readFileAlloc(global_io, script_path, alloc, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: could not read script '{s}': {}\n", .{ script_path, err });
        std.process.exit(1);
    };

    // ----- Script contract enforcement (post-parse, NOT in the generic
    // parser). Parse once with the script carve-out enabled so we can
    // inspect the hoisted top-level function(s) before the full
    // compile. D1: no one-struct-per-file validation is run over the
    // script unit. ---------------------------------------------------------
    {
        var contract_parser = try zap.Parser.initScript(alloc, script_source);
        defer contract_parser.deinit();
        const program = contract_parser.parseProgram() catch {
            // Phase 4.b: route the script's parser errors through the UNIFIED
            // renderer / `--error-format=json` path (was a bare-string minimal
            // printer that bypassed both). Same visual language as every other
            // compile diagnostic; JSON consumers see parser errors too.
            try compiler.emitScriptParseErrors(alloc, contract_parser.errors.items, script_path, script_source);
            std.process.exit(1);
        };
        _ = program;
        if (try enforceScriptContract(alloc, &contract_parser)) |msg| {
            std.debug.print("Error: {s}\n", .{msg});
            std.process.exit(1);
        }
    }

    // ----- Resolve the stdlib (flag > env > exe-relative > cwd) -----------
    // Single-file script mode has no project root, so the project-root
    // stdlib tier never applies — pass `null` for it explicitly.
    const zap_lib_dir = resolveZapLibDir(alloc, zap_lib_dir_override, null) catch {
        std.debug.print("Error: could not resolve Zap stdlib directory\n", .{});
        std.process.exit(1);
    };
    const zap_lib = zap_lib_dir orelse {
        std.debug.print("Error: could not locate the Zap stdlib (set ZAP_LIB_DIR or pass --zap-lib-dir)\n", .{});
        std.process.exit(1);
    };

    // Detect zig lib dir (same fallback chain as the manifest path).
    // Precedence: explicit/trusted (env or exe-relative fork stdlib) → the
    // embedded fork stdlib extracted to the cache → only then a system Zig.
    // The embedded fork stdlib MUST outrank a system Zig because the latter
    // is upstream and lacks the fork-only `std.debug` dSYM fallback the crash
    // reporter needs to resolve backtraces to Zap source.
    const zig_lib_dir = resolveZigLibDir(alloc) catch |err| {
        std.debug.print("Error: could not resolve Zig lib: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // ----- Assemble source roots (stdlib ONLY — no project, no deps) ------
    // This is also what structurally forbids external packages in
    // script mode (D4): there is no dependency mechanism and no project
    // source root, so any `use`/`import` that does not resolve from the
    // stdlib or the script's own structs fails discovery with a clear
    // "Struct not found" diagnostic.
    var source_roots: std.ArrayListUnmanaged(zap.discovery.SourceRoot) = .empty;
    try source_roots.append(alloc, .{ .name = "zap_stdlib", .path = zap_lib });
    {
        const zap_subdir = try std.fs.path.join(alloc, &.{ zap_lib, "zap" });
        _ = try appendOptionalSourceRoot(alloc, &source_roots, "zap_stdlib", zap_subdir);
    }

    // ----- Assemble source units: ALL stdlib + the ONE synthetic unit ----
    // The synthetic unit is the script's own source parsed with
    // `script_mode = true`, so its literal top-level `main/1` is
    // hoisted into the reserved `__ZapScriptMain` wrapper while its
    // own structs/protocols/impls compile as normal modules.
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    zap.builder.readStdlibSourceUnits(alloc, zap_lib, &source_units) catch |err| {
        std.debug.print("Error: could not read Zap stdlib sources: {}\n", .{err});
        std.process.exit(1);
    };
    try source_units.append(alloc, .{
        .file_path = script_path,
        .source = script_source,
        .script_mode = true,
    });

    // ----- Synthetic manifest BASE + the single shared override step --
    // `scriptManifest` produces the script-mode defaults (Debug,
    // Memory.ARC, native target/cpu) — the synthetic stand-in for
    // `build.zap` CTFE. `applyBuildOverrides` then overlays the parsed
    // `-D` flags per-field, EXACTLY as the manifest path does, so the
    // CLI is the ultimate source of truth and there is one pipeline.
    var config = zap.builder.scriptManifest(
        alloc,
        zap.Parser.SCRIPT_WRAPPER_STRUCT_NAME,
    ) catch {
        std.debug.print("Error: could not synthesize script manifest\n", .{});
        std.process.exit(1);
    };
    applyBuildOverrides(&config, overrides);
    const script_optimize_policy = optimizePolicyForBuildConfig(config.optimize);

    // ----- Content-addressed skip-recompile key -------------------------
    // The artifact directory's previously-random component is replaced
    // by a strong content key over the script source, the resolved
    // stdlib identity, the running-compiler identity, and the
    // post-override build controls (optimize/frontend policy/memory/
    // target/cpu — read off `config`, the single source of truth,
    // mirroring exactly what `computeBuildCacheKey` folds in for the
    // manifest path). An
    // UNCHANGED script therefore resolves to the SAME directory across
    // invocations, enabling a true no-recompile fast path, while a
    // change to ANY input yields a distinct directory (no stale-binary
    // false hit). Identity-digest failures are HARD errors: a silent zero
    // digest would collapse distinct stdlibs/compilers into one key.
    const stdlib_identity_digest = hashStdlibIdentity(alloc, zap_lib) catch |err| {
        std.debug.print("Error: could not hash Zap stdlib identity for the script cache key: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const script_cache_root_for_identity = resolveScriptCacheRoot(alloc) catch |err| {
        std.debug.print("Error: could not resolve script cache root for the toolchain identity cache: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const script_toolchain_cache_dir = std.fs.path.join(alloc, &.{ script_cache_root_for_identity, "zap", "toolchains" }) catch {
        std.debug.print("Error: out of memory resolving the toolchain identity cache directory\n", .{});
        std.process.exit(1);
    };
    const compiler_identity_digest = hashCompilerIdentity(alloc, script_toolchain_cache_dir) catch |err| {
        std.debug.print("Error: could not hash compiler identity for the script cache key: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const zig_lib_identity_digest = hashZigLibIdentity(alloc, script_toolchain_cache_dir, zig_lib_dir) catch |err| {
        std.debug.print("Error: could not hash Zig lib identity for the script cache key: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const content_key = computeScriptContentKey(alloc, script_source, stdlib_identity_digest, compiler_identity_digest, zig_lib_identity_digest, .{
        .optimize = config.optimize,
        .frontend_policy_tag = script_optimize_policy.frontend_policy_tag,
        .memory_manager_name = if (config.memory_manager) |m| m.type_name else "",
        .target = config.target orelse "",
        .cpu = config.cpu orelse "",
        .debug_info_tag = debugInfoCacheTagFor(config.debug_info),
        .frame_pointers_tag = framePointersCacheTagFor(config.frame_pointers),
        .runtime_concurrency = config.runtime_concurrency,
        .concurrency_kernel_key = scriptConcurrencyKernelKey(
            alloc,
            config,
            zap_lib,
            zig_lib_dir,
            compiler_identity_digest,
            zig_lib_identity_digest,
            script_optimize_policy.memory_driver_optimize,
        ),
    }) catch {
        std.debug.print("Error: out of memory computing the script content key\n", .{});
        std.process.exit(1);
    };

    // The stable content-key directory (`<cache root>/zap/scripts/<key>`)
    // and the published binary path within it. NEVER the script's own
    // directory — the core no-litter invariant is preserved.
    const key_dir = scriptArtifactDirForKey(alloc, content_key) catch |err| {
        std.debug.print("Error: could not create script artifact directory: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const artifact_filename = buildArtifactFilename(alloc, config) catch {
        std.debug.print("Error: out of memory resolving script artifact filename\n", .{});
        std.process.exit(1);
    };
    const published_path = try std.fs.path.join(alloc, &.{ key_dir, artifact_filename });

    // ----- Fast path: a valid cached binary for this exact key ----------
    // If the published binary already exists for this content key, the
    // frontend + backend + link are skipped ENTIRELY — we just run it.
    // The detectable `[script-cache hit]` marker goes to stderr (via
    // std.debug.print, mirroring the manifest path's `[cached]`
    // signal), so the script's own stdout is never polluted. The
    // run-or-report contract (foreign-target reporting, arg
    // forwarding, exit-code propagation) is identical to a fresh
    // build because both paths go through `runScriptArtifactAndExit`.
    switch (cachedArtifactAccess(published_path) catch |err| {
        std.debug.print("Error: could not access cached script artifact {s}: {s}\n", .{ published_path, @errorName(err) });
        std.process.exit(1);
    }) {
        .present => {
            const debug_symbols_ready = artifactHasRequiredDebugSymbols(alloc, config, published_path) catch |err| {
                std.debug.print("Error: could not validate cached script debug symbols for {s}: {s}\n", .{ published_path, @errorName(err) });
                std.process.exit(1);
            };
            const symbol_table_sidecar_ready = artifactHasRequiredSymbolTableSidecar(alloc, published_path) catch |err| {
                std.debug.print("Error: could not validate cached script symbol table sidecar for {s}: {s}\n", .{ published_path, @errorName(err) });
                std.process.exit(1);
            };
            if (!debug_symbols_ready) {
                std.debug.print("[script-cache miss] {s} debug symbols missing\n", .{published_path});
            } else if (!symbol_table_sidecar_ready) {
                std.debug.print("[script-cache miss] {s} symbol table sidecar missing\n", .{published_path});
            } else {
                std.debug.print("[script-cache hit] {s}\n", .{published_path});
                runScriptArtifactAndExit(allocator, config.target, published_path, forwarded.items);
            }
        },
        .missing => {},
    }

    // ----- Miss: compile into a PRIVATE staging dir, then publish -------
    // Concurrent identical runs race to produce the same content key;
    // each compiles into its own process-unique staging directory and
    // then atomically renames the finished binary into the shared
    // content-key directory, so no run ever observes a half-written
    // executable (the atomic-publish race-safety guarantee). The
    // staging dir also keeps the fork's intermediate `.zap-cache`
    // out of the script's directory, exactly as before.
    const staging_dir = makeScriptStagingDir(alloc) catch |err| {
        std.debug.print("Error: could not create script staging directory: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // `compileProjectFrontend` derives compilation order from
    // `ctx.struct_programs` when `struct_order` is null — exactly the
    // whole-program path. No import-driven discovery is needed because
    // every stdlib unit plus the single script unit is supplied
    // directly. The script's own module is exempt from
    // one-struct-per-file validation by never running that loop here
    // (D1).
    const artifact = try compileAndLinkOrIce(allocator, alloc, "Z9100", .{
        .config = config,
        .source_roots = source_roots.items,
        .source_units = source_units.items,
        .struct_order = null,
        .level_boundaries = null,
        .manifest_result_hash = 0,
        .cache_source = script_source,
        .target_name = "script",
        .build_opts = .empty,
        .zap_lib_dir = zap_lib_dir,
        .zig_lib_dir = zig_lib_dir,
        .compiler_identity_digest = compiler_identity_digest,
        .zig_lib_identity_digest = zig_lib_identity_digest,
        // The stdlib source-tree root (parent of `lib/`) is the
        // convention root the memory driver uses; identical to the
        // invariant `buildTarget` relies on.
        .project_root = std.fs.path.dirname(zap_lib) orelse zap_lib,
        .collect_arc_stats = false,
        // Cross target/cpu live on `config` (script mode: native, or
        // the `-Dtarget=`/`-Dcpu=` overrides applied above);
        // `compileAndLink` reads them off `config` — one channel.
        .layout = .{ .script = .{ .base_dir = staging_dir } },
    });
    defer artifact.deinit(allocator);

    if (artifact.kind != .bin) {
        std.debug.print("Error: script did not produce a runnable binary\n", .{});
        std.process.exit(1);
    }

    publishScriptArtifactToCache(
        alloc,
        config,
        "script",
        artifact.path,
        published_path,
        staging_dir,
    ) catch |err| {
        std.debug.print("Error: script artifact publish failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Run the published binary (identical run-or-report contract as
    // the fast path — one shared tail, no duplication).
    runScriptArtifactAndExit(allocator, config.target, published_path, forwarded.items);
}

const LeakReportEnvPropagationError = error{
    LeakReportEnvUnavailable,
    OutOfMemory,
};

fn leakReportEnvPropagationRequested(overrides: BuildOverrides) bool {
    if (overrides.error_format) |fmt| {
        if (fmt == .json) return true;
    }
    return overrides.leaks_fatal;
}

/// Phase 4.c — propagate the leak-report knobs (`-Derror-format=json`,
/// `-Dleaks-fatal`) into THIS process's environment so the child binary that
/// `runBinary` spawns inherits them. The runtime's deinit-time leak reporter
/// (active only under `Memory.Tracking`) reads `ZAP_ERROR_FORMAT` /
/// `ZAP_LEAKS_FATAL`; threading them via env is the seam that does not
/// require widening `runBinary`'s signature (it inherits the parent
/// environment). A no-op when neither knob is set, so a normal run touches
/// no environment. Propagation failures are surfaced before any child artifact
/// is spawned so requested runtime leak-report behavior cannot silently fall
/// back to the default text/non-fatal policy.
fn propagateLeakReportEnv(overrides: BuildOverrides) LeakReportEnvPropagationError!void {
    if (!leakReportEnvPropagationRequested(overrides)) return;

    // Put the knobs into the live process env map captured at startup; the
    // child binary `runBinary` spawns is given this exact map as its
    // `environ_map`, so it observes the keys. Mutating the `std`-managed env
    // map (rather than libc `setenv`) is portable and is the same map the
    // spawn path consumes — no reliance on a captured `std.os.environ`
    // snapshot.
    const env_map = global_env_map orelse return error.LeakReportEnvUnavailable;
    if (overrides.error_format) |fmt| {
        if (fmt == .json) {
            try env_map.put("ZAP_ERROR_FORMAT", "json");
        }
    }
    if (overrides.leaks_fatal) {
        try env_map.put("ZAP_LEAKS_FATAL", "1");
    }
}

fn failLeakReportEnvPropagation(err: LeakReportEnvPropagationError) noreturn {
    switch (err) {
        error.LeakReportEnvUnavailable => std.debug.print(
            "Error: leak-report environment propagation was requested, but the process environment map is unavailable\n",
            .{},
        ),
        error.OutOfMemory => std.debug.print(
            "Error: out of memory propagating leak-report environment\n",
            .{},
        ),
    }
    std.process.exit(1);
}

/// Shared, non-returning tail for BOTH the script cache-hit fast path
/// and the freshly-built miss path: enforce the foreign-target
/// reporting contract, otherwise run the binary forwarding args to
/// `main/1` and propagate its exit code. Centralised so the cached
/// and fresh paths can NEVER diverge on the run contract.
///
/// `target` is the post-override `config.target` (null ⇒ native host
/// ⇒ runnable; a foreign `arch-os-abi` triple ⇒ report + exit 0,
/// exactly as `zap build -Dtarget=<foreign>` and Phase 4 established —
/// unchanged whether the artifact was just built or served from cache).
fn runScriptArtifactAndExit(
    allocator: std.mem.Allocator,
    target: ?[]const u8,
    binary_path: []const u8,
    forwarded_args: []const []const u8,
) noreturn {
    // A `-Dtarget=` that cross-compiled the script for a FOREIGN
    // arch/OS produces a binary the host kernel cannot exec. The
    // cross-build itself SUCCEEDED — running it would only yield a
    // cryptic `error.InvalidExe`. Report the produced artifact and
    // exit 0 (the requested work — a cross build — completed), exactly
    // as `zap build -Dtarget=<foreign>` would. A bare `-Dcpu=` keeps
    // `config.target == null` and stays host-runnable, so this never
    // triggers on a CPU-only refinement.
    if (!targetIsHostRunnable(target)) {
        std.debug.print(
            "Cross-compiled for '{s}': binary written to {s}\n" ++
                "  (not executed — it targets a foreign architecture/OS this host cannot run; " ++
                "the cross build itself succeeded)\n",
            .{ target.?, binary_path },
        );
        std.process.exit(0);
    }

    // Run the produced binary, forwarding the script's args to
    // `main/1` (OS argv → `[String]`), and propagate its exit code —
    // mirrors the manifest run path exactly (reuses `runBinary`).
    const exit_code = compiler.runBinaryWithEnv(allocator, global_io, binary_path, forwarded_args, global_env_map) catch |err| {
        std.debug.print("Error running script: {}\n", .{err});
        std.process.exit(1);
    };
    std.process.exit(exit_code);
}

// ---------------------------------------------------------------------------
// Command: test
// ---------------------------------------------------------------------------

fn appendTestRunArgs(
    allocator: std.mem.Allocator,
    test_run_args: *std.ArrayListUnmanaged([]const u8),
    seed: ?[]const u8,
    timings: bool,
    slowest: ?[]const u8,
    forwarded_args: []const []const u8,
) !void {
    if (seed) |seed_value| {
        try test_run_args.append(allocator, "--seed");
        try test_run_args.append(allocator, seed_value);
    }
    if (timings) {
        try test_run_args.append(allocator, "--timings");
    }
    if (slowest) |slowest_value| {
        try test_run_args.append(allocator, "--slowest");
        try test_run_args.append(allocator, slowest_value);
    }
    for (forwarded_args) |arg| {
        try test_run_args.append(allocator, arg);
    }
}

const SingleFileTestInfo = struct {
    struct_order: []const []const u8,
    test_struct_names: []const []const u8,
};

fn structUsesZestCase(struct_decl: zap.ast.StructDecl, interner: *const zap.ast.StringInterner) bool {
    for (struct_decl.items) |item| {
        if (item != .use_decl) continue;
        const use_decl = item.use_decl;
        if (use_decl.struct_path.parts.len != 2) continue;
        if (!std.mem.eql(u8, interner.get(use_decl.struct_path.parts[0]), "Zest")) continue;
        if (!std.mem.eql(u8, interner.get(use_decl.struct_path.parts[1]), "Case")) continue;
        return true;
    }
    return false;
}

fn makeSingleFileTestRunnerSource(allocator: std.mem.Allocator, test_struct_names: []const []const u8) ![]const u8 {
    var generated: std.Io.Writer.Allocating = .init(allocator);
    errdefer generated.deinit();

    try generated.writer.writeAll(
        \\pub struct TestRunner {
        \\  pub fn main(_args :: [String]) -> u8 {
        \\    Zest.Runner.configure()
        \\
    );
    for (test_struct_names) |struct_name| {
        try generated.writer.print("    {s}.run()\n", .{struct_name});
    }
    try generated.writer.writeAll(
        \\    Zest.Runner.run()
        \\  }
        \\}
        \\
    );

    return try generated.toOwnedSlice();
}

fn singleFileTestInfo(
    allocator: std.mem.Allocator,
    test_path: []const u8,
    test_source: []const u8,
) !SingleFileTestInfo {
    var interner = zap.ast.StringInterner.init(allocator);
    defer interner.deinit();
    var parser = zap.Parser.initWithSharedInterner(allocator, test_source, &interner, 0);
    defer parser.deinit();

    const program = parser.parseProgram() catch {
        try compiler.emitScriptParseErrors(allocator, parser.errors.items, test_path, test_source);
        return error.ParseFailed;
    };

    var order: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer order.deinit(allocator);
    var test_struct_names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer test_struct_names.deinit(allocator);
    for (program.structs) |struct_decl| {
        const struct_name = try struct_decl.name.toDottedString(allocator, &interner);
        try order.append(allocator, struct_name);
        if (structUsesZestCase(struct_decl, &interner)) {
            try test_struct_names.append(allocator, struct_name);
        }
    }
    try order.append(allocator, "TestRunner");
    return .{
        .struct_order = try order.toOwnedSlice(allocator),
        .test_struct_names = try test_struct_names.toOwnedSlice(allocator),
    };
}

fn cmdTestScript(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    test_path: []const u8,
    test_arg_index: usize,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try parseTargetArgs(alloc, args[0..test_arg_index]);
    defer parsed.deinit(alloc);
    if (parsed.build_file != null) {
        std.debug.print("Error: --build-file is not valid with single-file zap test\n", .{});
        std.process.exit(1);
    }
    if (parsed.watch) {
        std.debug.print("Error: --watch is not supported with single-file zap test\n", .{});
        std.process.exit(1);
    }
    if (parsed.no_deps) {
        std.debug.print("Error: --no-deps is not valid with single-file zap test\n", .{});
        std.process.exit(1);
    }

    applyIncrementalTraceFlag(parsed.trace_incremental);
    defer clearIncrementalTraceFlag(parsed.trace_incremental);
    propagateLeakReportEnv(parsed.build_overrides) catch |err| failLeakReportEnvPropagation(err);

    if (parsed.build_overrides.memory) |mgr| {
        if (!validateScriptMemoryManager(mgr)) {
            std.debug.print(
                "Error: unsupported memory manager '{s}' — single-file test mode has no dependency graph and supports only the stdlib managers: Memory.ARC, Memory.ORC, Memory.Arena, Memory.NoOp, Memory.Leak, Memory.Tracking, Memory.GC\n",
                .{mgr},
            );
            std.process.exit(1);
        }
    }

    var test_run_args: std.ArrayListUnmanaged([]const u8) = .empty;
    try appendTestRunArgs(
        alloc,
        &test_run_args,
        parsed.seed,
        parsed.timings,
        parsed.slowest,
        args[test_arg_index + 1 ..],
    );

    const test_source = std.Io.Dir.cwd().readFileAlloc(global_io, test_path, alloc, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: could not read test file '{s}': {}\n", .{ test_path, err });
        std.process.exit(1);
    };
    const test_info = singleFileTestInfo(alloc, test_path, test_source) catch |err| switch (err) {
        error.ParseFailed => std.process.exit(1),
        else => return err,
    };

    const zap_lib_dir = resolveZapLibDir(alloc, parsed.zap_lib_dir, null) catch {
        std.debug.print("Error: could not resolve Zap stdlib directory\n", .{});
        std.process.exit(1);
    };
    const zap_lib = zap_lib_dir orelse {
        std.debug.print("Error: could not locate the Zap stdlib (set ZAP_LIB_DIR or pass --zap-lib-dir)\n", .{});
        std.process.exit(1);
    };

    const zig_lib_dir = resolveZigLibDir(alloc) catch |err| {
        std.debug.print("Error: could not resolve Zig lib: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var source_roots: std.ArrayListUnmanaged(zap.discovery.SourceRoot) = .empty;
    try source_roots.append(alloc, .{ .name = "zap_stdlib", .path = zap_lib });
    {
        const zap_subdir = try std.fs.path.join(alloc, &.{ zap_lib, "zap" });
        _ = try appendOptionalSourceRoot(alloc, &source_roots, "zap_stdlib", zap_subdir);
    }

    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    zap.builder.readStdlibSourceUnits(alloc, zap_lib, &source_units) catch |err| {
        std.debug.print("Error: could not read Zap stdlib sources: {}\n", .{err});
        std.process.exit(1);
    };
    try source_units.append(alloc, .{
        .file_path = test_path,
        .source = test_source,
    });
    const runner_source = try makeSingleFileTestRunnerSource(alloc, test_info.test_struct_names);
    try source_units.append(alloc, .{
        .file_path = "<zap single-file test runner>",
        .source = runner_source,
    });

    var config = zap.builder.scriptManifest(alloc, "TestRunner") catch {
        std.debug.print("Error: could not synthesize single-file test manifest\n", .{});
        std.process.exit(1);
    };
    config.name = "zap_test";
    applyBuildOverrides(&config, parsed.build_overrides);
    const test_optimize_policy = optimizePolicyForBuildConfig(config.optimize);

    const stdlib_identity_digest = hashStdlibIdentity(alloc, zap_lib) catch |err| {
        std.debug.print("Error: could not hash Zap stdlib identity for the test cache key: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const script_cache_root_for_identity = resolveScriptCacheRoot(alloc) catch |err| {
        std.debug.print("Error: could not resolve script cache root for the toolchain identity cache: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const script_toolchain_cache_dir = std.fs.path.join(alloc, &.{ script_cache_root_for_identity, "zap", "toolchains" }) catch {
        std.debug.print("Error: out of memory resolving the toolchain identity cache directory\n", .{});
        std.process.exit(1);
    };
    const compiler_identity_digest = hashCompilerIdentity(alloc, script_toolchain_cache_dir) catch |err| {
        std.debug.print("Error: could not hash compiler identity for the test cache key: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const zig_lib_identity_digest = hashZigLibIdentity(alloc, script_toolchain_cache_dir, zig_lib_dir) catch |err| {
        std.debug.print("Error: could not hash Zig lib identity for the test cache key: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const cache_source = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ test_source, runner_source });
    const content_key = computeScriptContentKey(alloc, cache_source, stdlib_identity_digest, compiler_identity_digest, zig_lib_identity_digest, .{
        .optimize = config.optimize,
        .frontend_policy_tag = test_optimize_policy.frontend_policy_tag,
        .memory_manager_name = if (config.memory_manager) |m| m.type_name else "",
        .target = config.target orelse "",
        .cpu = config.cpu orelse "",
        .debug_info_tag = debugInfoCacheTagFor(config.debug_info),
        .frame_pointers_tag = framePointersCacheTagFor(config.frame_pointers),
        .runtime_concurrency = config.runtime_concurrency,
        .concurrency_kernel_key = scriptConcurrencyKernelKey(
            alloc,
            config,
            zap_lib,
            zig_lib_dir,
            compiler_identity_digest,
            zig_lib_identity_digest,
            test_optimize_policy.memory_driver_optimize,
        ),
    }) catch {
        std.debug.print("Error: out of memory computing the test content key\n", .{});
        std.process.exit(1);
    };

    const key_dir = scriptArtifactDirForKey(alloc, content_key) catch |err| {
        std.debug.print("Error: could not create test artifact directory: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const artifact_filename = buildArtifactFilename(alloc, config) catch {
        std.debug.print("Error: out of memory resolving test artifact filename\n", .{});
        std.process.exit(1);
    };
    const published_path = try std.fs.path.join(alloc, &.{ key_dir, artifact_filename });

    switch (cachedArtifactAccess(published_path) catch |err| {
        std.debug.print("Error: could not access cached test artifact {s}: {s}\n", .{ published_path, @errorName(err) });
        std.process.exit(1);
    }) {
        .present => {
            const debug_symbols_ready = artifactHasRequiredDebugSymbols(alloc, config, published_path) catch |err| {
                std.debug.print("Error: could not validate cached test debug symbols for {s}: {s}\n", .{ published_path, @errorName(err) });
                std.process.exit(1);
            };
            const symbol_table_sidecar_ready = artifactHasRequiredSymbolTableSidecar(alloc, published_path) catch |err| {
                std.debug.print("Error: could not validate cached test symbol table sidecar for {s}: {s}\n", .{ published_path, @errorName(err) });
                std.process.exit(1);
            };
            if (!debug_symbols_ready) {
                std.debug.print("[script-cache miss] {s} debug symbols missing\n", .{published_path});
            } else if (!symbol_table_sidecar_ready) {
                std.debug.print("[script-cache miss] {s} symbol table sidecar missing\n", .{published_path});
            } else {
                std.debug.print("[script-cache hit] {s}\n", .{published_path});
                runScriptArtifactAndExit(allocator, config.target, published_path, test_run_args.items);
            }
        },
        .missing => {},
    }

    const staging_dir = makeScriptStagingDir(alloc) catch |err| {
        std.debug.print("Error: could not create test staging directory: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const artifact = try compileAndLinkOrIce(allocator, alloc, "Z9102", .{
        .config = config,
        .source_roots = source_roots.items,
        .source_units = source_units.items,
        .struct_order = test_info.struct_order,
        .level_boundaries = null,
        .manifest_result_hash = 0,
        .cache_source = cache_source,
        .target_name = "test",
        .build_opts = parsed.build_opts,
        .zap_lib_dir = zap_lib_dir,
        .zig_lib_dir = zig_lib_dir,
        .compiler_identity_digest = compiler_identity_digest,
        .zig_lib_identity_digest = zig_lib_identity_digest,
        .project_root = std.fs.path.dirname(zap_lib) orelse zap_lib,
        .collect_arc_stats = parsed.collect_arc_stats,
        .layout = .{ .script = .{ .base_dir = staging_dir } },
    });
    defer artifact.deinit(allocator);

    if (artifact.kind != .bin) {
        std.debug.print("Error: single-file test did not produce a runnable binary\n", .{});
        std.process.exit(1);
    }

    publishScriptArtifactToCache(
        alloc,
        config,
        "test",
        artifact.path,
        published_path,
        staging_dir,
    ) catch |err| {
        std.debug.print("Error: test artifact publish failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    runScriptArtifactAndExit(allocator, config.target, published_path, test_run_args.items);
}

fn buildPipelineRunArgs(
    allocator: std.mem.Allocator,
    run_step: zap.builder.BuildConfig.Run,
    forwarded_args: []const []const u8,
) ![]const []const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer args.deinit(allocator);

    for (run_step.args) |arg| {
        try args.append(allocator, arg);
    }
    if (run_step.forward_args) {
        for (forwarded_args) |arg| {
            try args.append(allocator, arg);
        }
    }
    return try args.toOwnedSlice(allocator);
}

const PipelineRunMode = enum {
    tests,
};

fn pipelineError(comptime message: []const u8, args: anytype) noreturn {
    std.debug.print("Error: invalid build pipeline: " ++ message ++ "\n", args);
    std.process.exit(1);
}

fn runPipelineArtifactAndExit(
    allocator: std.mem.Allocator,
    artifact: BuildArtifact,
    run_args: []const []const u8,
    mode: PipelineRunMode,
) noreturn {
    if (artifact.kind != .bin) {
        pipelineError("run step requires a bin artifact, got {s}", .{@tagName(artifact.kind)});
    }

    if (!targetIsHostRunnable(artifact.target)) {
        switch (mode) {
            .tests => std.debug.print(
                "Error: cannot run tests — they were cross-compiled for '{s}', " ++
                    "a foreign architecture/OS this host cannot execute.\n" ++
                    "  The test binary was written to {s}; run it on a matching target " ++
                    "(or drop -Dtarget= to test natively).\n",
                .{ artifact.target.?, artifact.path },
            ),
        }
        std.process.exit(1);
    }

    switch (mode) {
        .tests => std.debug.print("Running tests\n", .{}),
    }
    // Phase B: per-test hard-failure isolation is ON by default — the
    // supervisor re-spawns past any test that `@panic`s/faults/hangs so one
    // hard failure no longer aborts the whole run. Set `ZAP_ZEST_NO_ISOLATE`
    // to opt out and run the binary directly (a single un-supervised process).
    const isolate = std.c.getenv("ZAP_ZEST_NO_ISOLATE") == null;
    const exit_code = if (isolate)
        superviseTestRun(allocator, artifact.path, run_args, global_env_map) catch |err| {
            switch (mode) {
                .tests => std.debug.print("Error running tests: {}\n", .{err}),
            }
            std.process.exit(1);
        }
    else
        compiler.runBinaryWithEnv(allocator, global_io, artifact.path, run_args, global_env_map) catch |err| {
            switch (mode) {
                .tests => std.debug.print("Error running tests: {}\n", .{err}),
            }
            std.process.exit(1);
        };
    std.process.exit(exit_code);
}

fn executePipelineAfterInitialCompile(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    collect_arc_stats: bool,
    zap_lib_dir_override: ?[]const u8,
    initial_artifact: BuildArtifact,
    pipeline: zap.builder.BuildConfig.Pipeline,
    forwarded_args: []const []const u8,
    mode: PipelineRunMode,
) !void {
    var unused_initial_artifact: ?BuildArtifact = initial_artifact;
    defer if (unused_initial_artifact) |artifact| artifact.deinit(allocator);

    const execution_pipeline = try cloneBuildPipeline(allocator, pipeline);
    defer freeBuildPipeline(allocator, execution_pipeline);

    var current_artifact: ?BuildArtifact = null;
    defer if (current_artifact) |artifact| artifact.deinit(allocator);

    for (execution_pipeline.steps) |step| {
        switch (step) {
            .compile => {
                if (current_artifact) |artifact| artifact.deinit(allocator);
                current_artifact = null;

                if (unused_initial_artifact) |artifact| {
                    current_artifact = artifact;
                    unused_initial_artifact = null;
                } else {
                    current_artifact = try buildTarget(
                        allocator,
                        project_root,
                        target_name,
                        build_opts,
                        build_overrides,
                        collect_arc_stats,
                        zap_lib_dir_override,
                    );
                }
            },
            .run => |run_step| {
                const artifact = current_artifact orelse
                    pipelineError("run step appeared before a compile step", .{});
                const run_args = try buildPipelineRunArgs(allocator, run_step, forwarded_args);
                defer allocator.free(run_args);
                runPipelineArtifactAndExit(allocator, artifact, run_args, mode);
            },
        }
    }
    pipelineError("completed without a run step", .{});
}

/// Phase B (docs/phase-b-test-isolation-design.md): the last `##ZEST-BEGIN <n>`
/// in a shard's captured stderr that has no matching `##ZEST-END <n>` — i.e. the
/// global ordinal the child was running when it died. `null` when every BEGIN
/// was terminated (the shard ran its tests to completion). Crash-report lines
/// and other stderr are ignored (only the markers move `pending`).
fn zestCrashedOrdinal(stderr_bytes: []const u8) ?i64 {
    var pending: ?i64 = null;
    var lines = std.mem.splitScalar(u8, stderr_bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "##ZEST-BEGIN ")) {
            const rest = std.mem.trim(u8, line["##ZEST-BEGIN ".len..], " \r\t");
            pending = std.fmt.parseInt(i64, rest, 10) catch continue;
        } else if (std.mem.startsWith(u8, line, "##ZEST-END ")) {
            pending = null;
        }
    }
    return pending;
}

/// Forward a shard's captured stderr to the real stderr, dropping the internal
/// `##ZEST-BEGIN`/`##ZEST-END` marker lines so the user sees crash reports and
/// any genuine diagnostics but not the supervisor's bookkeeping.
fn reemitShardStderr(stderr_bytes: []const u8) void {
    var lines = std.mem.splitScalar(u8, stderr_bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "##ZEST-BEGIN ") or std.mem.startsWith(u8, line, "##ZEST-END ")) continue;
        if (line.len == 0) continue;
        std.debug.print("{s}\n", .{line});
    }
}

/// Running totals the supervisor aggregates across shards for the unified
/// final summary (each shard's own human summary is suppressed under
/// `--supervised`).
const ShardTally = struct {
    completed: u64 = 0, // total `##ZEST-END` markers = tests that finished
    failures: u64 = 0, // summed from surviving shards' `##ZEST-SUMMARY`
    assertions: u64 = 0,
    assertion_failures: u64 = 0,
    timeouts: u64 = 0,

    /// Fold one shard's captured stderr into the totals: count its terminated
    /// ordinals (completed tests) and, if it survived to print a
    /// `##ZEST-SUMMARY <tests> <failures> <assertions> <afailures> <timeouts>`,
    /// add its failure/assertion counts.
    fn accumulate(self: *ShardTally, stderr_bytes: []const u8) void {
        var lines = std.mem.splitScalar(u8, stderr_bytes, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "##ZEST-END ")) {
                self.completed += 1;
            } else if (std.mem.startsWith(u8, line, "##ZEST-SUMMARY ")) {
                var fields = std.mem.tokenizeScalar(u8, line["##ZEST-SUMMARY ".len..], ' ');
                const t = fields.next();
                _ = t; // the shard's test count is derived from ##ZEST-END instead
                const f = fields.next() orelse continue;
                const a = fields.next() orelse continue;
                const af = fields.next() orelse continue;
                const to = fields.next() orelse continue;
                self.failures += std.fmt.parseInt(u64, f, 10) catch 0;
                self.assertions += std.fmt.parseInt(u64, a, 10) catch 0;
                self.assertion_failures += std.fmt.parseInt(u64, af, 10) catch 0;
                self.timeouts += std.fmt.parseInt(u64, to, 10) catch 0;
            }
        }
    }
};

/// Phase B supervisor: run the Zest test binary with per-test hard-failure
/// isolation. The child runs with `--supervised` (checkpoint markers) and its
/// stderr captured to a temp file; stdout stays live. On a clean exit the
/// single shard IS the whole run. On an abnormal exit (a signal/abort, or an
/// exit with an unterminated `##ZEST-BEGIN`) the crashing ordinal is recorded
/// as a hard failure and the binary is re-spawned with `--resume-after <n>` to
/// continue past it — so one `@panic`/fault loses at most that one test.
/// Returns the process exit code (0 iff every shard passed and nothing crashed).
fn superviseTestRun(
    allocator: std.mem.Allocator,
    bin_path: []const u8,
    base_args: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
) !u8 {
    const stderr_path = ".zap-zest-shard.stderr";
    defer std.Io.Dir.cwd().deleteFile(global_io, stderr_path) catch {};

    // Pin ONE seed for the whole run so every shard shuffles identically —
    // otherwise a re-spawned child would default to a fresh clock-based seed,
    // giving a different ordinal→case mapping, and `--resume-after <n>` would
    // skip the wrong tests (and re-run the crashing one). Honor the user's
    // `--seed` if they passed one; otherwise derive a fresh per-run seed here
    // and pass it to every shard (Zest prints it, so the run stays
    // reproducible).
    const has_user_seed = for (base_args) |a| {
        if (std.mem.eql(u8, a, "--seed")) break true;
    } else false;
    var seed_buf: [24]u8 = undefined;
    const pinned_seed: ?[]const u8 = if (has_user_seed) null else blk: {
        var timestamp: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &timestamp);
        const seed_bits: u64 = @bitCast(@as(i64, timestamp.sec) *% 1_000_000_000 +% @as(i64, timestamp.nsec));
        break :blk try std.fmt.bufPrint(&seed_buf, "{d}", .{seed_bits & 0x7FFF_FFFF_FFFF_FFFF});
    };

    var resume_after: i64 = -1;
    var hard_failures: usize = 0;
    var worst_exit: u8 = 0;
    var tally: ShardTally = .{};

    while (true) {
        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        defer args.deinit(allocator);
        for (base_args) |a| try args.append(allocator, a);
        try args.append(allocator, "--supervised");
        if (pinned_seed) |seed_value| {
            try args.append(allocator, "--seed");
            try args.append(allocator, seed_value);
        }
        var resume_buf: [24]u8 = undefined;
        if (resume_after >= 0) {
            try args.append(allocator, "--resume-after");
            try args.append(allocator, try std.fmt.bufPrint(&resume_buf, "{d}", .{resume_after}));
        }

        const stderr_file = try std.Io.Dir.cwd().createFile(global_io, stderr_path, .{ .read = true });
        const term = compiler.spawnTestShard(allocator, global_io, bin_path, args.items, environ_map, stderr_file) catch |err| {
            stderr_file.close(global_io);
            std.debug.print("Error running test shard: {}\n", .{err});
            return 1;
        };
        stderr_file.close(global_io);

        const stderr_bytes = std.Io.Dir.cwd().readFileAlloc(global_io, stderr_path, allocator, .limited(64 * 1024 * 1024)) catch &.{};
        defer if (stderr_bytes.len > 0) allocator.free(stderr_bytes);
        const crashed = zestCrashedOrdinal(stderr_bytes);
        reemitShardStderr(stderr_bytes);
        tally.accumulate(stderr_bytes);

        if (crashed == null) {
            // The shard ran its remaining tests to completion.
            if (term == .exited and term.exited > worst_exit) worst_exit = term.exited;
            if (term != .exited) {
                // Abnormal exit AFTER the last test (teardown/summary) — count
                // it, but there is nothing left to resume.
                hard_failures += 1;
            }
            break;
        }

        const crashed_ordinal = crashed.?;
        hard_failures += 1;
        std.debug.print(
            "\n\x1b[1;31m⚡ test #{d} crashed ({any}) — isolated as a hard failure, resuming\x1b[0m\n",
            .{ crashed_ordinal, term },
        );
        resume_after = crashed_ordinal;
        worst_exit = 1;
    }

    // One unified summary for the whole run: completed tests (##ZEST-END
    // across every shard) PLUS the crashed tests, and the failures/assertions
    // the surviving shards reported. A crash counts both as a run test and as a
    // failure.
    const total_tests = tally.completed + hard_failures;
    const total_failures = tally.failures + hard_failures;
    if (pinned_seed) |seed_value| {
        std.debug.print("\nSeed: {s}\n", .{seed_value});
    }
    std.debug.print("{d} tests, {d} failures", .{ total_tests, total_failures });
    if (hard_failures > 0) {
        std.debug.print(" (\x1b[1;31m{d} crashed — isolated\x1b[0m)", .{hard_failures});
    }
    if (tally.timeouts > 0) {
        std.debug.print(" ({d} timed out)", .{tally.timeouts});
    }
    std.debug.print("\n{d} assertions, {d} failures\n", .{ tally.assertions, tally.assertion_failures });

    if (total_failures > 0) return 1;
    return worst_exit;
}

test "Phase B: zestCrashedOrdinal returns the unterminated BEGIN ordinal" {
    // A begin with no matching end => that test crashed mid-run.
    try std.testing.expectEqual(@as(?i64, 1), zestCrashedOrdinal(
        "##ZEST-BEGIN 0\n##ZEST-END 0\n##ZEST-BEGIN 1\n",
    ));
    // A trailing crash report after the begin must not disturb the result.
    try std.testing.expectEqual(@as(?i64, 2), zestCrashedOrdinal(
        "##ZEST-BEGIN 2\n** (runtime_error) boom\n  Foo.bar/0 at x.zap:1\n",
    ));
}

test "Phase B: zestCrashedOrdinal returns null when every BEGIN is terminated" {
    try std.testing.expectEqual(@as(?i64, null), zestCrashedOrdinal(
        "##ZEST-BEGIN 0\n##ZEST-END 0\n##ZEST-BEGIN 1\n##ZEST-END 1\n",
    ));
    try std.testing.expectEqual(@as(?i64, null), zestCrashedOrdinal("no markers at all\n"));
}

test "Phase B: ShardTally.accumulate folds END counts and SUMMARY fields" {
    var tally: ShardTally = .{};
    // A shard that ran two tests to completion and reported a summary.
    tally.accumulate("##ZEST-BEGIN 0\n##ZEST-END 0\n##ZEST-BEGIN 1\n##ZEST-END 1\n##ZEST-SUMMARY 2 1 5 1 0\n");
    // A second (dying) shard: one completed test, no summary.
    tally.accumulate("##ZEST-BEGIN 2\n##ZEST-END 2\n##ZEST-BEGIN 3\n");
    try std.testing.expectEqual(@as(u64, 3), tally.completed); // three ##ZEST-END total
    try std.testing.expectEqual(@as(u64, 1), tally.failures); // only the surviving shard's summary
    try std.testing.expectEqual(@as(u64, 5), tally.assertions);
    try std.testing.expectEqual(@as(u64, 1), tally.assertion_failures);
    try std.testing.expectEqual(@as(u64, 0), tally.timeouts);
}

fn cmdTest(allocator: std.mem.Allocator, args: []const []const u8) !void {
    switch (try classifyRunPositional(allocator, args)) {
        .script => |s| return cmdTestScript(allocator, args, s.path, s.arg_index),
        .manifest, .manifest_path => {},
    }

    var parsed = try parseTargetArgs(allocator, args);
    defer parsed.deinit(allocator);
    applyIncrementalTraceFlag(parsed.trace_incremental);
    defer clearIncrementalTraceFlag(parsed.trace_incremental);

    const project_root = try discoverBuildFile(allocator, parsed.build_file);
    defer allocator.free(project_root);

    // Build run_args: forward --seed to the test binary if provided
    var test_run_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer test_run_args.deinit(allocator);
    try appendTestRunArgs(allocator, &test_run_args, parsed.seed, parsed.timings, parsed.slowest, parsed.run_args);

    if (parsed.watch) {
        try watchAndRebuild(allocator, project_root, "test", parsed.build_opts, parsed.build_overrides, .tests, test_run_args.items, parsed.collect_arc_stats, parsed.zap_lib_dir);
        return;
    }

    const artifact = try buildTarget(allocator, project_root, "test", parsed.build_opts, parsed.build_overrides, parsed.collect_arc_stats, parsed.zap_lib_dir);
    if (artifact.pipeline) |pipeline| {
        try executePipelineAfterInitialCompile(
            allocator,
            project_root,
            "test",
            parsed.build_opts,
            parsed.build_overrides,
            parsed.collect_arc_stats,
            parsed.zap_lib_dir,
            artifact,
            pipeline,
            test_run_args.items,
            .tests,
        );
        return;
    }
    defer artifact.deinit(allocator);

    // `zap test` exists to RUN the test binary. A foreign cross
    // target produces a test binary this host cannot exec, so the
    // requested action genuinely cannot complete — fail LOUDLY with an
    // actionable diagnostic naming the target (NOT a cryptic
    // `error.InvalidExe` from blindly exec'ing a foreign binary). A
    // bare `-Dcpu=` keeps `artifact.target == null` and is fine.
    if (!targetIsHostRunnable(artifact.target)) {
        std.debug.print(
            "Error: cannot run tests — they were cross-compiled for '{s}', " ++
                "a foreign architecture/OS this host cannot execute.\n" ++
                "  The test binary was written to {s}; run it on a matching target " ++
                "(or drop -Dtarget= to test natively).\n",
            .{ artifact.target.?, artifact.path },
        );
        std.process.exit(1);
    }

    // Run the built test binary under the Phase B per-test hard-failure
    // supervisor by default (`ZAP_ZEST_NO_ISOLATE` opts out; same gate as the
    // pipeline path).
    std.debug.print("Running tests\n", .{});
    const exit_code = if (std.c.getenv("ZAP_ZEST_NO_ISOLATE") == null)
        superviseTestRun(allocator, artifact.path, test_run_args.items, global_env_map) catch |err| {
            std.debug.print("Error running tests: {}\n", .{err});
            std.process.exit(1);
        }
    else
        compiler.runBinary(allocator, global_io, artifact.path, test_run_args.items) catch |err| {
            std.debug.print("Error running tests: {}\n", .{err});
            std.process.exit(1);
        };
    std.process.exit(exit_code);
}

// ---------------------------------------------------------------------------
// Command: doc
// ---------------------------------------------------------------------------

fn cmdDoc(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var parsed = try parseTargetArgs(allocator, args);
    defer parsed.deinit(allocator);
    applyIncrementalTraceFlag(parsed.trace_incremental);
    defer clearIncrementalTraceFlag(parsed.trace_incremental);

    const target = parsed.target orelse "doc";

    const project_root = try discoverBuildFile(allocator, parsed.build_file);
    defer allocator.free(project_root);

    // Build the target as a regular binary and run its `main/1`. The
    // doc pipeline lives in Zap source — `Zap.Doc.Runner` (or any
    // user-defined doc-runner referenced from `build.zap`) calls
    // `Zap.Doc.Builder`'s `write_docs_to/1` to render and write
    // pages. The Zig CLI is just a thin shell around build+run, so
    // the same machinery that powers `zap test` powers `zap doc`.
    const artifact = try buildTarget(allocator, project_root, target, parsed.build_opts, parsed.build_overrides, parsed.collect_arc_stats, parsed.zap_lib_dir);
    defer artifact.deinit(allocator);

    // `zap doc` exists to RUN the doc generator. A foreign cross
    // target produces a generator this host cannot exec, so the
    // requested action cannot complete — fail LOUDLY (not a cryptic
    // `error.InvalidExe`). A bare `-Dcpu=` keeps `target == null`.
    if (!targetIsHostRunnable(artifact.target)) {
        std.debug.print(
            "Error: cannot generate docs — the doc generator was cross-compiled for '{s}', " ++
                "a foreign architecture/OS this host cannot execute.\n" ++
                "  Drop -Dtarget= to generate docs natively.\n",
            .{artifact.target.?},
        );
        std.process.exit(1);
    }

    const exit_code = compiler.runBinaryWithEnv(allocator, global_io, artifact.path, parsed.run_args, global_env_map) catch |err| {
        std.debug.print("Error running doc generator: {}\n", .{err});
        std.process.exit(1);
    };
    std.process.exit(exit_code);
}

// ---------------------------------------------------------------------------
// Command: init
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Command: deps
// ---------------------------------------------------------------------------

fn cmdDeps(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // stderr writer removed in 0.16

    if (args.len == 0) {
        std.debug.print("Usage: zap deps update [name]\n", .{});
        std.process.exit(1);
    }

    if (!std.mem.eql(u8, args[0], "update")) {
        std.debug.print("Error: unknown deps command: {s}\n\nUsage: zap deps update [name]\n", .{args[0]});
        std.process.exit(1);
    }

    // The first positional after `update` is an optional dependency
    // name. Any `--zap-lib-dir <dir>` override may appear anywhere in
    // the argument list, so parse it out without disturbing the
    // existing positional handling.
    var specific_dep: ?[]const u8 = null;
    var zap_lib_dir_override: ?[]const u8 = null;
    {
        var arg_index: usize = 1;
        while (arg_index < args.len) : (arg_index += 1) {
            const dep_arg = args[arg_index];
            if (std.mem.eql(u8, dep_arg, "--zap-lib-dir")) {
                arg_index += 1;
                if (arg_index < args.len) {
                    zap_lib_dir_override = args[arg_index];
                } else {
                    std.debug.print("Error: --zap-lib-dir requires a path\n", .{});
                    std.process.exit(1);
                }
            } else if (specific_dep == null) {
                specific_dep = dep_arg;
            } else {
                std.debug.print("Error: unexpected argument: {s}\n", .{dep_arg});
                std.process.exit(1);
            }
        }
    }

    const project_root = try discoverBuildFile(allocator, null);
    const build_file_path = try std.fs.path.join(allocator, &.{ project_root, "build.zap" });
    const build_source = std.Io.Dir.cwd().readFileAlloc(global_io, build_file_path, allocator, .limited(10 * 1024 * 1024)) catch {
        std.debug.print("Error: could not read build.zap\n", .{});
        std.process.exit(1);
    };

    const zap_lib_dir = resolveZapLibDir(allocator, zap_lib_dir_override, project_root) catch {
        std.debug.print("Error: could not resolve Zap stdlib directory\n", .{});
        std.process.exit(1);
    };
    const config = zap.builder.ctfeManifest(allocator, build_source, "default", null, .empty, zap_lib_dir) catch {
        std.debug.print("Error: could not evaluate build.zap manifest via CTFE\n", .{});
        std.process.exit(1);
    };

    var existing_lockfile: ?zap.lockfile.OwnedLockfile = null;
    defer if (existing_lockfile) |*lockfile| lockfile.deinit();
    const read_result = try zap.lockfile.readLockfile(allocator, project_root);
    switch (read_result) {
        .absent => {},
        .present => |lockfile| existing_lockfile = lockfile,
    }

    var lock_entries: std.ArrayListUnmanaged(zap.lockfile.LockEntry) = .empty;
    defer lock_entries.deinit(allocator);

    for (config.deps) |dep| {
        // If specific dep requested, skip others
        if (specific_dep) |name| {
            if (!std.mem.eql(u8, dep.name, name)) {
                // Keep existing lock entry for skipped deps
                if (existing_lockfile) |*lockfile| {
                    if (zap.lockfile.findEntry(lockfile.entries, dep.name)) |entry| {
                        try lock_entries.append(allocator, entry);
                    }
                }
                continue;
            }
        }

        switch (dep.source) {
            .path => |dep_path| {
                try lock_entries.append(allocator, .{
                    .name = dep.name,
                    .source_type = "path",
                    .url = dep_path,
                    .resolved_ref = "-",
                    .commit = "-",
                    .integrity = "-",
                });
                std.debug.print("  {s}: path dep (not locked)\n", .{dep.name});
            },
            .git => |git| {
                const ref = git.tag orelse git.branch orelse git.rev;
                std.debug.print("  {s}: fetching from {s}...\n", .{ dep.name, git.url });

                const result = zap.lockfile.fetchGitDep(
                    allocator,
                    dep.name,
                    git.url,
                    ref,
                    null, // force re-fetch by not passing locked commit
                ) catch {
                    std.debug.print("Error: failed to fetch dep `{s}`\n", .{dep.name});
                    std.process.exit(1);
                };

                try lock_entries.append(allocator, .{
                    .name = dep.name,
                    .source_type = "git",
                    .url = git.url,
                    .resolved_ref = ref orelse "-",
                    .commit = result.commit,
                    .integrity = result.integrity,
                });
                std.debug.print("  {s}: resolved to {s}\n", .{ dep.name, result.commit });
            },
        }
    }

    try zap.lockfile.writeLockfile(allocator, project_root, lock_entries.items);
    std.debug.print("Updated zap.lock\n", .{});
}

// ---------------------------------------------------------------------------
// Command: init
// ---------------------------------------------------------------------------

/// `zap explain Zxxxx` — print the long-form explanation for a stable
/// diagnostic code. The explanation content lives in Zap source
/// (`lib/error_catalog.zap`); this command is a thin reader that resolves
/// the stdlib directory, loads that catalog, and renders the matching
/// `[Zxxxx]` record. Codes with no catalog entry print a helpful
/// "not registered yet" message rather than failing — the catalog is
/// expected to grow over time while the scaffold stays stable.
fn cmdExplain(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Locate the requested code and an optional --zap-lib-dir override.
    var code_arg: ?[]const u8 = null;
    var lib_dir_flag: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--zap-lib-dir")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --zap-lib-dir requires a directory argument\n", .{});
                std.process.exit(2);
            }
            lib_dir_flag = args[i + 1];
            i += 1;
        } else if (code_arg == null) {
            code_arg = arg;
        }
    }

    const code = code_arg orelse {
        std.debug.print(
            "Usage: zap explain Zxxxx\n\nPrint the long-form explanation for a diagnostic code (e.g. `zap explain Z1003`).\n",
            .{},
        );
        std.process.exit(2);
    };

    if (!zap.error_codes.isValidCode(code)) {
        std.debug.print(
            "Error: `{s}` is not a valid diagnostic code — codes are written `Z<digits>`, e.g. `Z1003`.\n",
            .{code},
        );
        std.process.exit(2);
    }

    const lib_dir = resolveZapLibDir(allocator, lib_dir_flag, null) catch |err| {
        std.debug.print(
            "Error: could not resolve the Zap stdlib directory: {s}\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    } orelse {
        std.debug.print(
            "Error: could not locate the Zap stdlib directory (set ZAP_LIB_DIR or pass --zap-lib-dir).\n",
            .{},
        );
        std.process.exit(1);
    };
    defer allocator.free(lib_dir);

    const catalog_path = try std.fs.path.join(allocator, &.{ lib_dir, "error_catalog.zap" });
    defer allocator.free(catalog_path);

    const catalog_source = std.Io.Dir.cwd().readFileAlloc(global_io, catalog_path, allocator, .limited(4 * 1024 * 1024)) catch {
        std.debug.print(
            "{s}: no explanation catalog found (expected `{s}`).\n",
            .{ code, catalog_path },
        );
        std.process.exit(1);
    };
    defer allocator.free(catalog_source);

    var entry_arena = std.heap.ArenaAllocator.init(allocator);
    defer entry_arena.deinit();

    const entry = (try zap.error_codes.findCatalogEntry(entry_arena.allocator(), catalog_source, code)) orelse {
        std.debug.print(
            "{s}: no explanation registered for this code yet.\n" ++
                "  The diagnostic-code catalog (`lib/error_catalog.zap`) grows over time;\n" ++
                "  this code is valid but does not have a long-form entry.\n",
            .{code},
        );
        std.process.exit(0);
    };

    printCatalogEntry(entry);
}

fn printCatalogEntry(entry: zap.error_codes.CatalogEntry) void {
    std.debug.print("{s}", .{entry.code});
    if (entry.title.len > 0) {
        std.debug.print(" — {s}", .{entry.title});
    }
    std.debug.print("\n", .{});
    if (entry.explanation.len > 0) {
        std.debug.print("\n{s}\n", .{entry.explanation});
    }
    if (entry.repro.len > 0) {
        std.debug.print("\nMinimal repro:\n  {s}\n", .{entry.repro});
    }
    if (entry.fix.len > 0) {
        std.debug.print("\nFix:\n  {s}\n", .{entry.fix});
    }
}

// ---------------------------------------------------------------------------
// Command: addr2line
//
// Offline post-mortem symbolizer. Resolves machine addresses — typically the
// `0x<addr>` frames a release crash report prints when the stripped binary
// can't symbolize itself — against a (possibly stripped, possibly
// cross-compiled) Zap binary plus its split-debug artifact (`.dSYM` /
// embedded DWARF) and `.zap-symbols` sidecar, printing the same
// `Struct.local/arity at file.zap:line` rendering as the in-process printer.
//
// All the debug-info machinery lives in `zap.addr2line.Resolver` (which
// reuses the fork's `std.debug` DWARF reader + the in-repo `zap_symbol_table`
// Reader); this command is the thin CLI wrapper, mirroring `cmdExplain`.
// ---------------------------------------------------------------------------

const Addr2LineUsage =
    \\Usage: zap addr2line <binary> [<addr>...] [--load-address <addr>]
    \\
    \\Symbolize one or more addresses against a (possibly stripped) Zap binary
    \\using its split-debug artifact (.dSYM / embedded DWARF) and .zap-symbols
    \\sidecar. Addresses are STATIC image virtual addresses (the space a Zap
    \\crash report's `0x<addr>` frames already use). With no addresses on the
    \\command line, addresses are read one per line from stdin.
    \\
    \\Options:
    \\  --load-address <addr>, -l <addr>
    \\        Runtime load base of the binary's first text segment. When the
    \\        input addresses are raw ASLR-slid runtime addresses (e.g. from a
    \\        non-Zap tool), pass the segment's runtime base so the slide is
    \\        subtracted before lookup. Omit for static addresses.
    \\
    \\Each address resolves to one of:
    \\  0x<addr> Struct.local/arity at file.zap:line   (full Zap symbol)
    \\  0x<addr> <mangled> at file.zap:line             (no sidecar entry)
    \\  0x<addr> ?? at ??:0                             (no debug info)
    \\
    \\Line granularity: file:line is statement-level — the dSYM/DWARF line
    \\program carries a row per statement, so a crash-frame address resolves to
    \\the exact raising statement, not just the enclosing function's decl line.
    \\This relies on feeding the STATIC CALL-SITE address the crash report emits
    \\(the report already biases each return address one byte back into the
    \\calling statement before de-sliding it). Passing a function's symbol-table
    \\ENTRY address instead (e.g. straight from `nm`) resolves to the function
    \\prologue's line — correct DWARF, but the prologue, not a call site.
    \\
;

const Addr2LineStdinMaxBytes = 4 * 1024 * 1024;

/// Parse a `0x`-prefixed hex or bare decimal address. Tolerates surrounding
/// whitespace (so stdin lines and copy-pasted report fragments work).
fn parseAddress(raw: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
        return std.fmt.parseInt(u64, trimmed[2..], 16) catch null;
    }
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

fn readAddr2LineStdin(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limit: std.Io.Limit,
) std.Io.Reader.LimitedAllocError![]u8 {
    return reader.allocRemaining(allocator, limit);
}

test "P4J2: addr2line stdin read returns true empty input" {
    var reader = std.Io.Reader.fixed("");
    const data = try readAddr2LineStdin(std.testing.allocator, &reader, .limited(Addr2LineStdinMaxBytes));
    defer std.testing.allocator.free(data);

    try std.testing.expectEqual(@as(usize, 0), data.len);
}

test "P4J2: addr2line stdin read propagates allocation failure" {
    var reader = std.Io.Reader.fixed("0x10\n");
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.OutOfMemory,
        readAddr2LineStdin(failing_allocator.allocator(), &reader, .limited(Addr2LineStdinMaxBytes)),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: addr2line stdin read propagates stream limit failure" {
    var reader = std.Io.Reader.fixed("0x1234\n");

    try std.testing.expectError(
        error.StreamTooLong,
        readAddr2LineStdin(std.testing.allocator, &reader, .limited(3)),
    );
}

test "P4J2: addr2line stdin read propagates read failure" {
    var reader = std.Io.Reader.failing;

    try std.testing.expectError(
        error.ReadFailed,
        readAddr2LineStdin(std.testing.allocator, &reader, .limited(Addr2LineStdinMaxBytes)),
    );
}

fn cmdAddr2line(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var binary_path: ?[]const u8 = null;
    var load_address: ?u64 = null;
    var address_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer address_args.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--load-address") or std.mem.eql(u8, arg, "-l")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: {s} requires an address argument\n", .{arg});
                std.process.exit(2);
            }
            i += 1;
            load_address = parseAddress(args[i]) orelse {
                std.debug.print("Error: `{s}` is not a valid address for {s}\n", .{ args[i], arg });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{Addr2LineUsage});
            std.process.exit(0);
        } else if (binary_path == null) {
            binary_path = arg;
        } else {
            try address_args.append(allocator, arg);
        }
    }

    const binary = binary_path orelse {
        std.debug.print("{s}", .{Addr2LineUsage});
        std.process.exit(2);
    };

    // Collect the address strings: from the command line, or — when none were
    // given — one per line from stdin (so a captured report can be piped in).
    var addresses: std.ArrayListUnmanaged(u64) = .empty;
    defer addresses.deinit(allocator);

    if (address_args.items.len > 0) {
        for (address_args.items) |raw| {
            const addr = parseAddress(raw) orelse {
                std.debug.print("Error: `{s}` is not a valid address (use 0x<hex> or <decimal>)\n", .{raw});
                std.process.exit(2);
            };
            try addresses.append(allocator, addr);
        }
    } else {
        var stdin_read_buf: [4096]u8 = undefined;
        // Streaming (not positional): stdin is typically a pipe/tty with no
        // seek, so positional reads would fail.
        var stdin_reader = std.Io.File.stdin().readerStreaming(global_io, &stdin_read_buf);
        const data = readAddr2LineStdin(allocator, &stdin_reader.interface, .limited(Addr2LineStdinMaxBytes)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.ReadFailed => {
                std.debug.print("Error: failed to read addresses from stdin: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            },
            error.StreamTooLong => {
                std.debug.print("Error: stdin address input exceeds the {d} byte limit\n", .{Addr2LineStdinMaxBytes});
                std.process.exit(2);
            },
        };
        defer allocator.free(data);
        var lines = std.mem.tokenizeAny(u8, data, "\r\n");
        while (lines.next()) |line| {
            if (parseAddress(line)) |addr| try addresses.append(allocator, addr);
        }
        if (addresses.items.len == 0) {
            std.debug.print("Error: no addresses given (pass them as arguments or pipe them on stdin)\n\n{s}", .{Addr2LineUsage});
            std.process.exit(2);
        }
    }

    var resolver = zap.addr2line.Resolver.open(allocator, global_io, binary) catch |err| switch (err) {
        error.InvalidBinary => {
            std.debug.print("Error: could not open `{s}` as a debug-info-bearing binary.\n", .{binary});
            std.process.exit(1);
        },
        error.UnsupportedObjectFormat => {
            std.debug.print("Error: this build of `zap` cannot symbolize the object format of `{s}`.\n", .{binary});
            std.process.exit(1);
        },
        error.OutOfMemory => return err,
    };
    defer resolver.deinit();

    if (!resolver.hasSidecar()) {
        std.debug.print(
            "note: no `{s}.zap-symbols` sidecar found — reporting mangled linker names.\n",
            .{binary},
        );
    }

    // A per-call arena backs the DWARF source-path strings for each frame.
    var text_arena = std.heap.ArenaAllocator.init(allocator);
    defer text_arena.deinit();

    for (addresses.items) |runtime_addr| {
        // Translate a runtime (ASLR-slid) address to a static image address
        // when a load base was supplied; otherwise the input is already
        // static (a Zap report prints static addresses).
        const static_addr = if (load_address) |base|
            (if (runtime_addr >= base) runtime_addr - base else runtime_addr)
        else
            runtime_addr;

        const frame = resolver.resolve(text_arena.allocator(), static_addr);
        printAddr2LineFrame(frame);
    }
}

/// Render one resolved frame in the crash-report style:
/// `0x<addr> Struct.local/arity at file.zap:line`. Falls back to the mangled
/// name when the sidecar has no entry, and to `??` markers when DWARF is
/// unavailable, so every input address produces exactly one output line.
fn printAddr2LineFrame(frame: zap.addr2line.Frame) void {
    std.debug.print("0x{x} ", .{frame.address});

    if (frame.zap) |z| {
        if (z.zap_struct) |struct_name| {
            std.debug.print("{s}.", .{struct_name});
        }
        std.debug.print("{s}/{d}", .{ z.zap_local, z.zap_arity });
    } else if (frame.mangled) |mangled| {
        std.debug.print("{s}", .{mangled});
    } else {
        std.debug.print("??", .{});
    }

    if (frame.source) |loc| {
        const file_name = if (loc.file_name.len > 0) loc.file_name else "??";
        std.debug.print(" at {s}:{d}", .{ file_name, loc.line });
    } else {
        std.debug.print(" at ??:0", .{});
    }
    std.debug.print("\n", .{});
}

const InitDirectoryStatus = enum {
    empty,
    not_empty,
};

fn initDirectoryStatusWithIo(dir: std.Io.Dir, io: std.Io) std.Io.Dir.Iterator.Error!InitDirectoryStatus {
    var iter = dir.iterate();
    return if (try iter.next(io)) |_| .not_empty else .empty;
}

fn initDirectoryStatus(dir: std.Io.Dir) std.Io.Dir.Iterator.Error!InitDirectoryStatus {
    return initDirectoryStatusWithIo(dir, global_io);
}

test "P4J2: init directory status preserves true empty directory" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);
    var dir = try std.Io.Dir.cwd().openDir(global_io, tmp_path, .{ .iterate = true });
    defer dir.close(global_io);

    try std.testing.expectEqual(InitDirectoryStatus.empty, try initDirectoryStatus(dir));
}

test "P4J2: init directory status reports true non-empty directory" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "existing.txt", .data = "present" });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);
    var dir = try std.Io.Dir.cwd().openDir(global_io, tmp_path, .{ .iterate = true });
    defer dir.close(global_io);

    try std.testing.expectEqual(InitDirectoryStatus.not_empty, try initDirectoryStatus(dir));
}

fn failInitDirectoryRead(
    userdata: ?*anyopaque,
    dir_reader: *std.Io.Dir.Reader,
    buffer: []std.Io.Dir.Entry,
) std.Io.Dir.Reader.Error!usize {
    _ = userdata;
    _ = dir_reader;
    _ = buffer;
    return error.AccessDenied;
}

test "P4J2: init directory status propagates iterator failure" {
    var vtable = std.Io.failing.vtable.*;
    vtable.dirRead = failInitDirectoryRead;
    const failing_io: std.Io = .{
        .userdata = null,
        .vtable = &vtable,
    };
    const dir: std.Io.Dir = .{ .handle = 0 };

    try std.testing.expectError(error.AccessDenied, initDirectoryStatusWithIo(dir, failing_io));
}

fn cmdInit(allocator: std.mem.Allocator) !void {
    // Check directory is empty
    var dir = std.Io.Dir.cwd().openDir(global_io, ".", .{ .iterate = true }) catch {
        // stderr writer removed in 0.16
        std.debug.print("Error: cannot open current directory\n", .{});
        std.process.exit(1);
    };
    defer dir.close(global_io);

    switch (initDirectoryStatus(dir) catch |err| {
        std.debug.print("Error: cannot read current directory: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    }) {
        .empty => {},
        .not_empty => {
            // stderr writer removed in 0.16
            std.debug.print("Error: directory is not empty\n", .{});
            std.process.exit(1);
        },
    }

    // Derive names from directory
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(cwd_path);
    const dir_name = std.fs.path.basename(cwd_path);

    // Convert to snake_case project name (handle kebab-case)
    const project_name = try toSnakeCase(allocator, dir_name);
    defer allocator.free(project_name);

    // Convert to PascalCase struct name
    const struct_name = try toPascalCase(allocator, project_name);
    defer allocator.free(struct_name);

    // Generate files
    try std.Io.Dir.cwd().createDirPath(global_io, "lib");
    try std.Io.Dir.cwd().createDirPath(global_io, "test");

    // .gitignore
    try writeFile(".gitignore",
        \\.zap-cache/
        \\zap-out/
        \\
    );

    // README.md
    const readme = try std.fmt.allocPrint(allocator,
        \\# {s}
        \\
        \\## Build
        \\
        \\    zap build
        \\
        \\## Run
        \\
        \\    zap run
        \\
        \\## Test
        \\
        \\    zap test
        \\
    , .{project_name});
    defer allocator.free(readme);
    try writeFile("README.md", readme);

    // build.zap
    const build_zap = try std.fmt.allocPrint(allocator,
        \\pub struct {s}.Builder {{
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {{
        \\    case env.target {{
        \\      :{s} -> {s}(env)
        \\      :test -> test(env)
        \\      _default -> {s}(env)
        \\    }}
        \\  }}
        \\
        \\  fn {s}(env :: Zap.Env) -> Zap.Manifest {{
        \\    %Zap.Manifest{{
        \\      name: "{s}",
        \\      version: "0.1.0",
        \\      kind: :bin,
        \\      root: &{s}.main/1,
        \\      paths: ["lib/**/*.zap"],
        \\      # :debug | :release_safe | :release_fast | :release_small
        \\      optimize: :release_safe
        \\    }}
        \\  }}
        \\
        \\  fn test(env :: Zap.Env) -> Zap.Manifest {{
        \\    %Zap.Manifest{{
        \\      name: "{s}_test",
        \\      version: "0.1.0",
        \\      kind: :bin,
        \\      root: &{s}Test.main/1,
        \\      paths: ["lib/**/*.zap", "test/**/*.zap"],
        \\      optimize: :debug,
        \\      pipeline: %Zap.Build.Pipeline{{
        \\        steps: [%Zap.Build.Step{{compile: %Zap.Build.Compile{{}}}}, %Zap.Build.Step{{run: %Zap.Build.Run{{forward_args: true}}}}]
        \\      }}
        \\    }}
        \\  }}
        \\}}
        \\
    , .{ struct_name, project_name, project_name, project_name, project_name, project_name, struct_name, project_name, struct_name });
    defer allocator.free(build_zap);
    try writeFile("build.zap", build_zap);

    // lib/<project_name>.zap
    const lib_path = try std.fmt.allocPrint(allocator, "lib/{s}.zap", .{project_name});
    defer allocator.free(lib_path);
    const lib_source = try std.fmt.allocPrint(allocator,
        \\pub struct {s} {{
        \\  pub fn main(_args :: [String]) -> u8 {{
        \\    IO.puts("Howdy!")
        \\    0
        \\  }}
        \\}}
        \\
    , .{struct_name});
    defer allocator.free(lib_source);
    try writeFile(lib_path, lib_source);

    // test/<project_name>_test.zap
    const test_path = try std.fmt.allocPrint(allocator, "test/{s}_test.zap", .{project_name});
    defer allocator.free(test_path);
    const test_source = try std.fmt.allocPrint(allocator,
        \\pub struct {s}Test {{
        \\  pub fn main(_args :: [String]) -> u8 {{
        \\    IO.puts("Test Suite TBD")
        \\    0
        \\  }}
        \\}}
        \\
    , .{struct_name});
    defer allocator.free(test_source);
    try writeFile(test_path, test_source);

    std.debug.print("Created project '{s}'\n\n  zap build\n  zap run\n  zap run test\n", .{project_name});
}

// ---------------------------------------------------------------------------
// Zap lib dir detection
// ---------------------------------------------------------------------------

/// Hard-error surface for the Zap stdlib resolver. `InvalidZapLibDir`
/// means an explicit `--zap-lib-dir` flag or `ZAP_LIB_DIR` env var was
/// provided but the directory does not contain `kernel.zap`, so it is
/// not a usable Zap stdlib root. The caller must surface this rather
/// than silently falling through to a lower-precedence source — an
/// explicit override that is wrong is a configuration error, not a
/// hint.
const ZapLibDirError = error{
    InvalidZapLibDir,
    ZapLibDirAccessFailed,
    ZapLibDirCanonicalizeFailed,
    ZapLibDirResolveFailed,
    OutOfMemory,
};

const ZapLibDirProbeError = error{
    ZapLibDirAccessFailed,
    OutOfMemory,
};

fn isMissingZapLibPathError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.NotDir => true,
        else => false,
    };
}

fn zapLibDirAccessError(err: anyerror) ZapLibDirProbeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ZapLibDirAccessFailed,
    };
}

/// Pure precedence resolver for the Zap stdlib directory.
///
/// Highest precedence wins, returning the first non-null source in
/// order: explicit `--zap-lib-dir` flag, `ZAP_LIB_DIR` env var,
/// executable-relative walk-up result, then the cwd `./lib` fallback.
/// This function performs NO IO and NO validation; it is the
/// unit-testable core that the IO-touching `resolveZapLibDir` composes
/// after it has validated and materialised each candidate.
fn chooseZapLibDir(
    flag: ?[]const u8,
    env_val: ?[]const u8,
    project_relative: ?[]const u8,
    exe_relative: ?[]const u8,
    cwd_fallback: ?[]const u8,
) ?[]const u8 {
    if (flag) |f| return f;
    if (env_val) |e| return e;
    if (project_relative) |p| return p;
    if (exe_relative) |x| return x;
    if (cwd_fallback) |c| return c;
    return null;
}

/// Returns true when `dir` is a usable Zap stdlib root, i.e. it
/// directly contains a readable `kernel.zap`. Used to validate explicit
/// flag/env overrides before accepting them.
fn zapLibDirContainsKernel(allocator: std.mem.Allocator, dir: []const u8) ZapLibDirProbeError!bool {
    const kernel_path = std.fs.path.join(allocator, &.{ dir, "kernel.zap" }) catch return error.OutOfMemory;
    defer allocator.free(kernel_path);
    std.Io.Dir.cwd().access(global_io, kernel_path, .{}) catch |err| {
        if (isMissingZapLibPathError(err)) return false;
        return zapLibDirAccessError(err);
    };
    return true;
}

/// Resolve the executable-relative Zap stdlib directory.
///
/// The executable path is first canonicalised through realpath so that
/// an installed binary symlinked into `PATH` resolves to its real
/// install prefix (and a dev `zig-out/bin/zap` checkout, whose realpath
/// is already canonical, is a safe no-op). The resolver then walks up
/// from the real executable directory looking for a `lib/` directory
/// that contains `kernel.zap`. Returns null when no such directory is
/// found. Executable path, realpath, allocation, and access failures are
/// infrastructure errors and are returned to the caller rather than being
/// treated as lower-precedence absence.
fn resolveExeRelativeZapLibDir(allocator: std.mem.Allocator) ZapLibDirError!?[]const u8 {
    const exe_path = std.process.executablePathAlloc(global_io, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ZapLibDirResolveFailed,
    };
    defer allocator.free(exe_path);

    // Canonicalise through realpath so symlinked install locations
    // resolve to their real prefix. realpath of an already-canonical
    // dev path is a safe no-op. Failure here is not semantic absence: it
    // means the executable location could not be trusted as a discovery
    // root, so the resolver must surface it.
    //
    // `realPathFileAlloc` returns a sentinel-terminated `[:0]u8` whose
    // backing allocation is `len + 1` bytes; it must be freed through
    // the sentinel slice (freeing a coerced `[]const u8` would
    // under-count by one byte and trip the testing allocator).
    const real_exe_path_z = std.Io.Dir.cwd().realPathFileAlloc(global_io, exe_path, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ZapLibDirCanonicalizeFailed,
    };
    defer allocator.free(real_exe_path_z);
    const real_exe_path: []const u8 = real_exe_path_z;

    var dir_path = std.fs.path.dirname(real_exe_path);
    while (dir_path) |dp| {
        const lib_dir = std.fs.path.join(allocator, &.{ dp, "lib" }) catch return error.OutOfMemory;
        const contains_kernel = zapLibDirContainsKernel(allocator, lib_dir) catch |err| {
            allocator.free(lib_dir);
            return err;
        };
        if (contains_kernel) {
            return lib_dir;
        }
        allocator.free(lib_dir);
        dir_path = std.fs.path.dirname(dp);
    }

    return null;
}

/// Generalized Zap stdlib resolver.
///
/// Precedence (highest wins): explicit `--zap-lib-dir` flag value, the
/// `ZAP_LIB_DIR` environment variable, the project-root stdlib working
/// tree (`<project_root>/lib` when it directly contains `kernel.zap`),
/// the realpath-resolved executable-relative walk-up, then the cwd
/// `./lib` fallback.
///
/// The project-root tier exists because a project that is itself a Zap
/// stdlib source tree is authoritative: it is the code under
/// edit/test and is independently registered as a `project` source
/// root by the discovery setup. Letting a lower-precedence
/// exe-relative *installed copy* (e.g. `zig-out/lib`) win there would
/// both (a) silently compile/test a stale snapshot instead of the
/// developer's edits and (b) leave discovery scanning two physical
/// copies of every stdlib file, tripping "struct already defined".
/// Pass `null` for `project_root` when there is genuinely no project
/// (single-file script mode); ordinary app projects are unaffected
/// because their `lib/` is their own code, not a stdlib (no
/// `kernel.zap`), so this tier is skipped and exe-relative still wins.
///
/// When the explicit flag or the env var is set but does not point at a
/// directory containing `kernel.zap`, this is a hard `InvalidZapLibDir`
/// error — an explicit override that is wrong is a configuration
/// mistake and must not silently fall through to a lower-precedence
/// source. Returns a caller-owned duplicate of the resolved directory,
/// or null when no source resolves and no override was given. The
/// returned path is always the `lib/` directory itself (never its
/// parent), so `dirname(resolved)` remains a valid source-tree-root
/// derivation.
fn resolveZapLibDir(allocator: std.mem.Allocator, flag: ?[]const u8, project_root: ?[]const u8) ZapLibDirError!?[]const u8 {
    // 1. Explicit `--zap-lib-dir` flag — validated; wrong is fatal.
    if (flag) |flag_dir| {
        if (!(try zapLibDirContainsKernel(allocator, flag_dir))) {
            zap.diagnostics.emitStderrFmt(
                "Error: --zap-lib-dir '{s}' is not a valid Zap stdlib directory (no kernel.zap found)\n",
                .{flag_dir},
            );
            return error.InvalidZapLibDir;
        }
        return allocator.dupe(u8, flag_dir) catch return error.OutOfMemory;
    }

    // 2. `ZAP_LIB_DIR` environment variable — validated; wrong is fatal.
    if (env.getenv("ZAP_LIB_DIR")) |env_dir| {
        if (!(try zapLibDirContainsKernel(allocator, env_dir))) {
            zap.diagnostics.emitStderrFmt(
                "Error: ZAP_LIB_DIR '{s}' is not a valid Zap stdlib directory (no kernel.zap found)\n",
                .{env_dir},
            );
            return error.InvalidZapLibDir;
        }
        return allocator.dupe(u8, env_dir) catch return error.OutOfMemory;
    }

    // 3. Project-root stdlib working tree. When the project being built
    //    is itself a Zap stdlib source tree (its own `lib/` directly
    //    contains `kernel.zap`), that working tree is authoritative —
    //    see the function doc for why this must outrank the
    //    exe-relative installed copy. Skipped for callers without a
    //    project root and for ordinary app projects whose `lib/` is not
    //    a stdlib.
    var project_relative: ?[]const u8 = null;
    defer if (project_relative) |p| allocator.free(p);
    if (project_root) |root| {
        const proj_lib = std.fs.path.join(allocator, &.{ root, "lib" }) catch return error.OutOfMemory;
        const contains_kernel = zapLibDirContainsKernel(allocator, proj_lib) catch |err| {
            allocator.free(proj_lib);
            return err;
        };
        if (contains_kernel) {
            project_relative = proj_lib;
        } else {
            allocator.free(proj_lib);
        }
    }

    // 4. Executable-relative walk-up (symlinks resolved via realpath).
    const exe_relative = try resolveExeRelativeZapLibDir(allocator);
    defer if (exe_relative) |x| allocator.free(x);

    // 5. cwd `./lib` fallback (unchanged from the legacy behavior):
    //    accepted only when `./lib/kernel.zap` is present.
    var cwd_fallback: ?[]const u8 = null;
    defer if (cwd_fallback) |c| allocator.free(c);
    if (std.Io.Dir.cwd().access(global_io, "lib/kernel.zap", .{})) |_| {
        cwd_fallback = allocator.dupe(u8, "lib") catch return error.OutOfMemory;
    } else |err| {
        if (!isMissingZapLibPathError(err)) return zapLibDirAccessError(err);
    }

    const chosen = chooseZapLibDir(null, null, project_relative, exe_relative, cwd_fallback) orelse return null;
    return allocator.dupe(u8, chosen) catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Build pipeline
// ---------------------------------------------------------------------------

const BuildArtifact = struct {
    path: []const u8,
    kind: zap.builder.BuildConfig.Kind,
    /// The effective cross-compile target the artifact was built for
    /// (post-override `config.target`): `null` ⇒ native host build, a
    /// non-null `arch-os-abi` triple ⇒ cross build. The `run` paths
    /// (`zap run` script + manifest, watch mode) consult this via
    /// `targetIsHostRunnable` so a binary cross-compiled for a foreign
    /// arch/OS is reported rather than exec'd (which would fail with a
    /// cryptic `error.InvalidExe`). Owned by the caller's `allocator`
    /// (durable dup, like `path`); freed alongside the artifact. `null`
    /// is the native sentinel and allocates nothing.
    target: ?[]const u8,
    /// Optional manifest pipeline copied out of the manifest/config
    /// arena. Cached and daemon-backed artifacts carry this too, so a
    /// pipeline override survives every build path.
    pipeline: ?zap.builder.BuildConfig.Pipeline = null,

    /// Free both owned allocations (`path` and, when non-null,
    /// `target`). Use this everywhere the whole artifact is discarded
    /// so the `target` dup can never be leaked by a site that only
    /// remembered to free `path`. When only `path` ownership is
    /// transferred out (watch mode moves it into `output_path`), free
    /// `target` directly with `freeTargetOnly` instead.
    fn deinit(self: BuildArtifact, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        if (self.target) |t| gpa.free(t);
        if (self.pipeline) |pipeline| freeBuildPipeline(gpa, pipeline);
    }

    /// Free metadata dups, for the watch-mode site that moves `path`
    /// ownership into a longer-lived `output_path` variable.
    fn freeTargetOnly(self: BuildArtifact, gpa: std.mem.Allocator) void {
        if (self.target) |t| gpa.free(t);
        if (self.pipeline) |pipeline| freeBuildPipeline(gpa, pipeline);
    }
};

fn startProgressNode(
    progress: ?*zap.progress.Reporter,
    parent: ?zap.progress.Node,
    label: []const u8,
) ?zap.progress.Node {
    if (parent) |parent_node| {
        return parent_node.start(label, .{}) catch {
            if (progress) |reporter| reporter.stage("{s}", .{label});
            return null;
        };
    }
    const reporter = progress orelse return null;
    return reporter.start(label, .{}) catch {
        reporter.stage("{s}", .{label});
        return null;
    };
}

fn progressNodeParent(progress: ?*zap.progress.Reporter, parent: ?zap.progress.Node) ?zap.progress.Node {
    if (parent) |node| return node;
    if (progress) |reporter| return reporter.rootNode();
    return null;
}

fn updateProgressNodeCurrentItem(
    progress: ?*zap.progress.Reporter,
    node: ?zap.progress.Node,
    item: []const u8,
    comptime fallback_format: []const u8,
    fallback_args: anytype,
) void {
    if (node) |progress_node| {
        progress_node.updateCurrentItem(item);
    } else if (progress) |reporter| {
        reporter.stage(fallback_format, fallback_args);
    }
}

fn finishProgressNode(node: ?zap.progress.Node, result: zap.progress.NodeResult) void {
    if (node) |progress_node| progress_node.finish(result);
}

const ScopedProgressNode = struct {
    progress: ?*zap.progress.Reporter,
    node: ?zap.progress.Node,
    result: zap.progress.NodeResult = .failed,

    fn start(
        progress: ?*zap.progress.Reporter,
        parent: ?zap.progress.Node,
        label: []const u8,
    ) ScopedProgressNode {
        return .{
            .progress = progress,
            .node = startProgressNode(progress, parent, label),
        };
    }

    fn updateCurrentItem(
        self: *ScopedProgressNode,
        item: []const u8,
        comptime fallback_format: []const u8,
        fallback_args: anytype,
    ) void {
        updateProgressNodeCurrentItem(self.progress, self.node, item, fallback_format, fallback_args);
    }

    fn cacheHit(self: *ScopedProgressNode, label: []const u8, item: []const u8) void {
        if (self.node) |node| node.cacheHit(label, item);
    }

    fn cacheMiss(self: *ScopedProgressNode, label: []const u8, item: []const u8) void {
        if (self.node) |node| node.cacheMiss(label, item);
    }

    fn succeed(self: *ScopedProgressNode) void {
        self.result = .succeeded;
        self.finish();
    }

    fn skip(self: *ScopedProgressNode) void {
        self.result = .skipped;
        self.finish();
    }

    fn finish(self: *ScopedProgressNode) void {
        finishProgressNode(self.node, self.result);
        self.node = null;
    }

    fn deinit(self: *ScopedProgressNode) void {
        self.finish();
    }
};

fn makeBuildArtifact(
    allocator: std.mem.Allocator,
    path: []const u8,
    kind: zap.builder.BuildConfig.Kind,
    target: ?[]const u8,
    pipeline: ?zap.builder.BuildConfig.Pipeline,
) !BuildArtifact {
    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);

    const target_copy = if (target) |target_value|
        try allocator.dupe(u8, target_value)
    else
        null;
    errdefer if (target_copy) |target_value| allocator.free(target_value);

    const pipeline_copy = try cloneOptionalBuildPipeline(allocator, pipeline);
    errdefer if (pipeline_copy) |pipeline_value| freeBuildPipeline(allocator, pipeline_value);

    return .{
        .path = path_copy,
        .kind = kind,
        .target = target_copy,
        .pipeline = pipeline_copy,
    };
}

fn targetTripleUsesDarwinDebugMap(target: []const u8) bool {
    return std.mem.indexOf(u8, target, "macos") != null or
        std.mem.indexOf(u8, target, "darwin") != null or
        std.mem.indexOf(u8, target, "ios") != null or
        std.mem.indexOf(u8, target, "tvos") != null or
        std.mem.indexOf(u8, target, "watchos") != null or
        std.mem.indexOf(u8, target, "visionos") != null;
}

fn hostUsesDarwinDebugMap() bool {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => true,
        else => false,
    };
}

/// Project a `BuildConfig.debug_info` override to the in-process
/// `DebugInfoOverride` enum that `resolveDebugInfoPolicy` consumes.
/// One central conversion site removes the four near-duplicate
/// `switch` blocks that used to live at every call site and keeps the
/// override → resolution projection consistent across the dSYM gate,
/// the post-strip gate, `compileAndLink`, `cmdRunScript`, and the
/// manifest build path.
fn debugInfoOverrideFor(config: zap.builder.BuildConfig) ?DebugInfoOverride {
    return if (config.debug_info) |dbg| switch (dbg) {
        .full => @as(DebugInfoOverride, .full),
        .split => @as(DebugInfoOverride, .split),
        .none => @as(DebugInfoOverride, .none),
    } else null;
}

fn needsDarwinDebugSymbols(config: zap.builder.BuildConfig) bool {
    if (config.kind != .bin) return false;
    // Phase 0 — DWARF foundation, Gap E. The spec table
    // (`docs/error-system-research-brief.md`, Part VI.B #13 & Part
    // VIII) ships a sibling `.dSYM` for EVERY optimize mode by
    // default on Mach-O. Debug / ReleaseSafe embed DWARF in the
    // binary AND publish the sibling (`policy != .none`).
    // ReleaseFast / ReleaseSmall compile with full DWARF so dsymutil
    // can read the debug-map, publish the sibling
    // (`want_split_debug = true`), then a downstream post-link strip
    // removes the debug-map from the published binary. Both branches
    // collapse into "the resolution either keeps in-binary DWARF or
    // asks for a sibling split artifact". The only mode that
    // suppresses publication is `-Ddebug-info=none`, which yields
    // `policy == .none` AND `want_split_debug == false` — a stripped
    // binary with no shipped DWARF.
    const resolution = resolveDebugInfoPolicy(
        config.optimize,
        debugInfoOverrideFor(config),
        config.frame_pointers,
    );
    const policy = resolution.in_binary orelse return false;
    const wants_bundle = policy != .none or resolution.want_split_debug;
    if (!wants_bundle) return false;
    if (config.target) |target| return targetTripleUsesDarwinDebugMap(target);
    return hostUsesDarwinDebugMap();
}

/// True when the build needs a Mach-O post-link strip pass to satisfy
/// the split-debug contract: the binary must end up without its
/// DWARF debug-map after `dsymutil` has already extracted the sibling
/// `.dSYM`. Driven by the resolved policy: post-strip when the build
/// publishes a sibling (`want_split_debug = true`) AND the shipped
/// binary is NOT supposed to retain its embedded DWARF
/// (`ship_with_embedded_dwarf = false`). That is true for the
/// explicit `-Ddebug-info=split` override AND for the per-mode
/// defaults of ReleaseFast / ReleaseSmall (Gap E: the spec table
/// ships the sibling-on-stripped-binary contract by default in
/// release modes, not only when the user passes the flag
/// explicitly). The Debug / ReleaseSafe defaults intentionally do
/// NOT take this branch: their binaries keep the debug-map so native
/// lldb / atos resolution works without consulting the dSYM, and the
/// sibling is published as a redundant offline copy. The explicit
/// `-Ddebug-info=full` override pulls every mode back into that
/// "keep embedded DWARF" shape.
fn needsDarwinDebugMapStripAfterDsymutil(config: zap.builder.BuildConfig) bool {
    if (config.kind != .bin) return false;
    const resolution = resolveDebugInfoPolicy(
        config.optimize,
        debugInfoOverrideFor(config),
        config.frame_pointers,
    );
    if (!resolution.want_split_debug) return false;
    if (resolution.ship_with_embedded_dwarf) return false;
    if (config.target) |target| return targetTripleUsesDarwinDebugMap(target);
    return hostUsesDarwinDebugMap();
}

fn debugSymbolBundlePath(alloc: std.mem.Allocator, artifact_path: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}.dSYM", .{artifact_path});
}

const CachedArtifactAccessResult = enum {
    present,
    missing,
};

fn isMissingPathAccessError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.NotDir => true,
        else => false,
    };
}

fn cachedArtifactAccess(path: []const u8) !CachedArtifactAccessResult {
    std.Io.Dir.cwd().access(global_io, path, .{}) catch |err| {
        if (isMissingPathAccessError(err)) return .missing;
        return err;
    };
    return .present;
}

const ArtifactStagingCleanupError = error{
    ArtifactStagingCleanupAccessFailed,
    ArtifactStagingCleanupFailed,
};

fn cleanupRequiredPublishedArtifactStaging(
    artifact_label: []const u8,
    staging_dir: []const u8,
) ArtifactStagingCleanupError!void {
    // `deleteTree` deliberately treats an already-missing initial path as
    // success. For private script/test staging directories that is not a safe
    // success signal: the publish phase owns this path and must prove cleanup
    // happened before the artifact is reported or run.
    switch (cachedArtifactAccess(staging_dir) catch |err| {
        std.debug.print(
            "Error: could not access {s} artifact staging directory {s} before cleanup: {s}\n",
            .{ artifact_label, staging_dir, @errorName(err) },
        );
        return error.ArtifactStagingCleanupAccessFailed;
    }) {
        .present => {},
        .missing => {
            std.debug.print(
                "Error: {s} artifact staging directory disappeared before required cleanup: {s}\n",
                .{ artifact_label, staging_dir },
            );
            return error.ArtifactStagingCleanupFailed;
        },
    }

    std.Io.Dir.cwd().deleteTree(global_io, staging_dir) catch |err| {
        std.debug.print(
            "Error: could not remove {s} artifact staging directory {s}: {s}\n",
            .{ artifact_label, staging_dir, @errorName(err) },
        );
        return error.ArtifactStagingCleanupFailed;
    };

    // A missing result after a confirmed-present cleanup target is the only
    // benign missing race here: the staged tree is gone. Any surviving target,
    // or an inability to verify its absence, leaves cache-root state uncertain.
    switch (cachedArtifactAccess(staging_dir) catch |err| {
        std.debug.print(
            "Error: could not verify {s} artifact staging cleanup for {s}: {s}\n",
            .{ artifact_label, staging_dir, @errorName(err) },
        );
        return error.ArtifactStagingCleanupAccessFailed;
    }) {
        .missing => {},
        .present => {
            std.debug.print(
                "Error: {s} artifact staging directory still exists after required cleanup: {s}\n",
                .{ artifact_label, staging_dir },
            );
            return error.ArtifactStagingCleanupFailed;
        },
    }
}

test "cached artifact access treats not-directory path components as missing" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "artifact-parent", .data = "not a directory" });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const cached_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "artifact-parent/app" });
    defer allocator.free(cached_artifact_path);

    try std.testing.expectEqual(CachedArtifactAccessResult.missing, try cachedArtifactAccess(cached_artifact_path));
}

test "cached artifact access propagates non-missing access failures" {
    const allocator = std.testing.allocator;

    const too_long_prefix = try allocator.alloc(u8, std.fs.max_path_bytes + 1);
    defer allocator.free(too_long_prefix);
    @memset(too_long_prefix, 'a');
    const cached_artifact_path = try std.fmt.allocPrint(allocator, "{s}/abcd/app", .{too_long_prefix});
    defer allocator.free(cached_artifact_path);

    try std.testing.expectError(error.NameTooLong, cachedArtifactAccess(cached_artifact_path));
}

test "cached artifact access propagates symlink-loop access failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink(global_io, "artifact", "artifact", .{});

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const cached_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "artifact" });
    defer allocator.free(cached_artifact_path);

    try std.testing.expectError(error.SymLinkLoop, cachedArtifactAccess(cached_artifact_path));
}

fn artifactHasRequiredDebugSymbols(
    alloc: std.mem.Allocator,
    config: zap.builder.BuildConfig,
    artifact_path: []const u8,
) !bool {
    if (!needsDarwinDebugSymbols(config)) return true;
    const dsym_path = try debugSymbolBundlePath(alloc, artifact_path);
    defer alloc.free(dsym_path);
    return switch (try cachedArtifactAccess(dsym_path)) {
        .present => true,
        .missing => false,
    };
}

fn darwinDebugSymbolTestConfig() zap.builder.BuildConfig {
    return .{
        .name = "probe",
        .version = "0.0.0",
        .kind = .bin,
        .optimize = .debug,
        .target = "aarch64-macos-none",
    };
}

test "artifact debug symbol check reports missing dSYM bundle as false" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "app" });
    defer allocator.free(artifact_path);

    try std.testing.expect(!(try artifactHasRequiredDebugSymbols(allocator, darwinDebugSymbolTestConfig(), artifact_path)));
}

test "artifact debug symbol check accepts present dSYM bundle" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "app.dSYM");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "app" });
    defer allocator.free(artifact_path);

    try std.testing.expect(try artifactHasRequiredDebugSymbols(allocator, darwinDebugSymbolTestConfig(), artifact_path));
}

test "artifact debug symbol check propagates dSYM access failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink(global_io, "app.dSYM", "app.dSYM", .{});

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "app" });
    defer allocator.free(artifact_path);

    try std.testing.expectError(error.SymLinkLoop, artifactHasRequiredDebugSymbols(allocator, darwinDebugSymbolTestConfig(), artifact_path));
}

fn symbolTableSidecarPath(alloc: std.mem.Allocator, artifact_path: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}.zap-symbols", .{artifact_path});
}

fn symbolTableSidecarFileAccess(path: []const u8) !CachedArtifactAccessResult {
    const stat = std.Io.Dir.cwd().statFile(global_io, path, .{}) catch |err| {
        if (isMissingPathAccessError(err)) return .missing;
        return err;
    };
    return if (stat.kind == .file) .present else .missing;
}

fn artifactHasRequiredSymbolTableSidecar(
    alloc: std.mem.Allocator,
    artifact_path: []const u8,
) !bool {
    const sidecar_path = try symbolTableSidecarPath(alloc, artifact_path);
    defer alloc.free(sidecar_path);
    return switch (try symbolTableSidecarFileAccess(sidecar_path)) {
        .present => true,
        .missing => false,
    };
}

test "artifact symbol table sidecar check requires a regular file" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "app" });
    defer allocator.free(artifact_path);

    try std.testing.expect(!(try artifactHasRequiredSymbolTableSidecar(allocator, artifact_path)));

    const sidecar_path = try symbolTableSidecarPath(allocator, artifact_path);
    defer allocator.free(sidecar_path);
    try std.Io.Dir.cwd().createDirPath(global_io, sidecar_path);
    try std.testing.expect(!(try artifactHasRequiredSymbolTableSidecar(allocator, artifact_path)));

    try std.Io.Dir.cwd().deleteTree(global_io, sidecar_path);
    try std.Io.Dir.cwd().writeFile(global_io, .{ .sub_path = sidecar_path, .data = "symbols" });
    try std.testing.expect(try artifactHasRequiredSymbolTableSidecar(allocator, artifact_path));
}

fn copyFileCwd(source_path: []const u8, destination_path: []const u8) !void {
    std.Io.Dir.cwd().copyFile(
        source_path,
        std.Io.Dir.cwd(),
        destination_path,
        global_io,
        .{ .make_path = true, .replace = true },
    ) catch |err| return err;
}

fn copyTreeCwd(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    switch (try cachedArtifactAccess(destination_path)) {
        .present => try std.Io.Dir.cwd().deleteTree(global_io, destination_path),
        .missing => {},
    }
    try std.Io.Dir.cwd().createDirPath(global_io, destination_path);

    var source_dir = try std.Io.Dir.cwd().openDir(global_io, source_path, .{ .iterate = true });
    defer source_dir.close(global_io);
    var destination_dir = try std.Io.Dir.cwd().openDir(global_io, destination_path, .{});
    defer destination_dir.close(global_io);

    var walker = try std.Io.Dir.walk(source_dir, allocator);
    defer walker.deinit();
    while (try walker.next(global_io)) |entry| {
        switch (entry.kind) {
            .directory => try destination_dir.createDirPath(global_io, entry.path),
            .file => {
                if (std.fs.path.dirname(entry.path)) |parent| {
                    try destination_dir.createDirPath(global_io, parent);
                }
                try source_dir.copyFile(entry.path, destination_dir, entry.path, global_io, .{ .replace = true });
            },
            else => {},
        }
    }
}

fn installCachedManifestArtifact(
    allocator: std.mem.Allocator,
    snapshot: build_cache.Snapshot,
) !void {
    if (!std.mem.eql(u8, snapshot.cached_artifact_path, snapshot.output_path)) {
        try copyFileCwd(snapshot.cached_artifact_path, snapshot.output_path);
    }
    if (snapshot.debug_symbols_required) {
        const cached_dsym_path = try debugSymbolBundlePath(allocator, snapshot.cached_artifact_path);
        defer allocator.free(cached_dsym_path);
        const output_dsym_path = try debugSymbolBundlePath(allocator, snapshot.output_path);
        defer allocator.free(output_dsym_path);
        try copyTreeCwd(allocator, cached_dsym_path, output_dsym_path);
    }
}

fn publishManifestArtifactToCache(
    allocator: std.mem.Allocator,
    config: zap.builder.BuildConfig,
    output_path: []const u8,
    cached_artifact_path: []const u8,
) !void {
    if (!std.mem.eql(u8, output_path, cached_artifact_path)) {
        try copyFileCwd(output_path, cached_artifact_path);
    }
    if (needsDarwinDebugSymbols(config)) {
        const output_dsym_path = try debugSymbolBundlePath(allocator, output_path);
        defer allocator.free(output_dsym_path);
        const cached_dsym_path = try debugSymbolBundlePath(allocator, cached_artifact_path);
        defer allocator.free(cached_dsym_path);
        try copyTreeCwd(allocator, output_dsym_path, cached_dsym_path);
    }
}

const DarwinDebugSymbolError = error{
    OutOfMemory,
    DsymutilFailed,
    DebugSymbolAccessFailed,
    DebugSymbolCleanupFailed,
    DebugSymbolPublishFailed,
};

fn printProcessOutput(stdout: []const u8, stderr: []const u8) void {
    if (stdout.len > 0) std.debug.print("dsymutil stdout:\n{s}\n", .{stdout});
    if (stderr.len > 0) std.debug.print("dsymutil stderr:\n{s}\n", .{stderr});
}

fn generateDarwinDebugSymbols(
    alloc: std.mem.Allocator,
    artifact_path: []const u8,
    progress: ?*zap.progress.Reporter,
) DarwinDebugSymbolError!void {
    if (progress) |reporter| reporter.stage("Debug symbols: resolving output bundle", .{});
    const dsym_path = try debugSymbolBundlePath(alloc, artifact_path);
    defer alloc.free(dsym_path);
    if (progress) |reporter| reporter.stage("Debug symbols: running dsymutil", .{});
    const result = std.process.run(alloc, global_io, .{
        .argv = &.{ "dsymutil", artifact_path, "-o", dsym_path },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    }) catch |err| {
        std.debug.print("Error: failed to run dsymutil for {s}: {}\n", .{ artifact_path, err });
        return error.DsymutilFailed;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        std.debug.print("Error: dsymutil failed for {s}\n", .{artifact_path});
        printProcessOutput(result.stdout, result.stderr);
        return error.DsymutilFailed;
    }

    if (progress) |reporter| reporter.stage("Debug symbols: verifying output bundle", .{});
    switch (cachedArtifactAccess(dsym_path) catch |err| {
        std.debug.print("Error: could not access dsymutil output {s}: {s}\n", .{ dsym_path, @errorName(err) });
        return error.DebugSymbolAccessFailed;
    }) {
        .present => {},
        .missing => {
            std.debug.print("Error: dsymutil did not create {s}\n", .{dsym_path});
            printProcessOutput(result.stdout, result.stderr);
            return error.DsymutilFailed;
        },
    }
}

fn generateDarwinDebugSymbolsOrExit(
    alloc: std.mem.Allocator,
    config: zap.builder.BuildConfig,
    artifact_path: []const u8,
    progress: ?*zap.progress.Reporter,
) void {
    if (!needsDarwinDebugSymbols(config)) return;
    generateDarwinDebugSymbols(alloc, artifact_path, progress) catch |err| {
        if (err == error.OutOfMemory) {
            std.debug.print("Error: out of memory generating debug symbols for {s}\n", .{artifact_path});
        }
        std.process.exit(1);
    };
    // Phase 0 Gap D: when the user asked for `-Ddebug-info=split`,
    // the Mach-O contract is "stripped main binary + sibling .dSYM".
    // The binary still carries the DWARF debug-map (`__debug` /
    // STAB symbols) needed for dsymutil's extraction pass; now that
    // the dSYM exists, strip those bytes so the published binary
    // matches the documented split shape.
    if (needsDarwinDebugMapStripAfterDsymutil(config)) {
        stripDarwinDebugMapOrExit(alloc, artifact_path, progress);
    }
}

/// Strip the DWARF debug-map from a Mach-O artifact after dsymutil
/// has already extracted the sibling `.dSYM`. Uses Apple's `strip
/// -S` which removes the STAB debug entries the debug-map relies on
/// while leaving the binary fully linkable / runnable. Any failure
/// is a hard error — silently leaving the debug-map in place defeats
/// the split contract (the binary would still let lldb walk DWARF
/// directly from the `.o` files, defeating the privacy / size
/// argument for split shipping).
fn stripDarwinDebugMap(
    alloc: std.mem.Allocator,
    artifact_path: []const u8,
    progress: ?*zap.progress.Reporter,
) DarwinDebugSymbolError!void {
    if (progress) |reporter| reporter.stage("Debug symbols: stripping debug-map for split artifact", .{});
    const result = std.process.run(alloc, global_io, .{
        .argv = &.{ "strip", "-S", artifact_path },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        std.debug.print("Error: failed to run strip -S for {s}: {}\n", .{ artifact_path, err });
        return error.DebugSymbolPublishFailed;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        std.debug.print("Error: strip -S failed for {s}\n", .{artifact_path});
        printProcessOutput(result.stdout, result.stderr);
        return error.DebugSymbolPublishFailed;
    }
}

fn stripDarwinDebugMapOrExit(
    alloc: std.mem.Allocator,
    artifact_path: []const u8,
    progress: ?*zap.progress.Reporter,
) void {
    stripDarwinDebugMap(alloc, artifact_path, progress) catch |err| {
        std.debug.print(
            "Error: post-dsymutil strip failed for split artifact {s}: {s}\n",
            .{ artifact_path, @errorName(err) },
        );
        std.process.exit(1);
    };
}

fn cleanupRedundantStagedDebugSymbols(staged_dsym_path: []const u8) DarwinDebugSymbolError!void {
    // The staged `.dSYM` lives under a process-private staging directory and
    // was already observed before this cleanup phase. Missing before cleanup
    // is therefore not a benign race; it means the cache-root publish state is
    // no longer under this process's control.
    switch (cachedArtifactAccess(staged_dsym_path) catch |err| {
        std.debug.print(
            "Error: could not access redundant staged script debug symbols {s} before cleanup: {s}\n",
            .{ staged_dsym_path, @errorName(err) },
        );
        return error.DebugSymbolAccessFailed;
    }) {
        .present => {},
        .missing => {
            std.debug.print(
                "Error: redundant staged script debug symbols disappeared before required cleanup: {s}\n",
                .{staged_dsym_path},
            );
            return error.DebugSymbolCleanupFailed;
        },
    }

    std.Io.Dir.cwd().deleteTree(global_io, staged_dsym_path) catch |err| {
        std.debug.print(
            "Error: could not remove redundant staged script debug symbols {s}: {s}\n",
            .{ staged_dsym_path, @errorName(err) },
        );
        return error.DebugSymbolCleanupFailed;
    };

    // Once the target was confirmed present, a post-cleanup missing result is
    // the safe terminal state. A surviving path or unverifiable path remains a
    // required cleanup failure and must stop artifact reporting/execution.
    switch (cachedArtifactAccess(staged_dsym_path) catch |err| {
        std.debug.print(
            "Error: could not verify redundant staged script debug symbol cleanup for {s}: {s}\n",
            .{ staged_dsym_path, @errorName(err) },
        );
        return error.DebugSymbolAccessFailed;
    }) {
        .missing => {},
        .present => {
            std.debug.print(
                "Error: redundant staged script debug symbols still exist after required cleanup: {s}\n",
                .{staged_dsym_path},
            );
            return error.DebugSymbolCleanupFailed;
        },
    }
}

/// Publish the freshly-built `.dSYM` debug-symbol bundle from the staging
/// directory into the shared content-key cache location, race-safely against
/// concurrent invocations on the SAME script.
///
/// Race-safety strategy — sound because the script cache is CONTENT-KEYED
/// (the published path is derived from a hash that covers script source +
/// compiler identity + relevant flags, so the same path implies the same
/// dSYM bytes):
///
/// 1. **Cache hit:** if the published dSYM bundle already exists at function
///    entry, return success immediately. The existing bundle is byte-equivalent
///    to the one we just staged for the same key — overwriting it is both
///    wasteful and racy (`deleteTree` then `rename` is a TOCTOU window that
///    triggers `error.DirNotEmpty` when a concurrent publisher repopulates
///    the destination). Required cleanup removes the redundant staged copy
///    before the artifact may be reported or run.
///
/// 2. **Atomic publish with race-loss acceptance:** otherwise, attempt
///    `rename(staged, published)` directly (no preceding deletion).
///    - On success: we won the race, the bundle is now atomically in place.
///    - On `error.DirNotEmpty`: a concurrent publisher won the race and
///      populated the destination directory between our existence check
///      and the rename — POSIX `rename` cannot atomically replace a
///      nonempty directory, so this is the only race-loss error variant
///      that surfaces for a directory rename. Return success — the
///      content-key invariant guarantees the winning bundle has the same
///      bytes ours would have. Required cleanup removes our staged copy
///      before the artifact may be reported or run.
///    - On cleanup failure: surface as `error.DebugSymbolCleanupFailed`.
///    - On any other error: surface as `error.DebugSymbolPublishFailed`.
///
/// This is the standard "if it's already there, or it gets there, we're good"
/// idiom for content-keyed atomic publishes.
fn publishScriptDebugSymbolsIfNeeded(
    alloc: std.mem.Allocator,
    config: zap.builder.BuildConfig,
    staged_artifact_path: []const u8,
    published_artifact_path: []const u8,
) DarwinDebugSymbolError!void {
    if (!needsDarwinDebugSymbols(config)) return;

    const staged_dsym_path = try debugSymbolBundlePath(alloc, staged_artifact_path);
    defer alloc.free(staged_dsym_path);
    switch (cachedArtifactAccess(staged_dsym_path) catch |err| {
        std.debug.print("Error: could not access staged script debug symbols {s}: {s}\n", .{ staged_dsym_path, @errorName(err) });
        return error.DebugSymbolAccessFailed;
    }) {
        .present => {},
        .missing => {
            std.debug.print("Error: Debug script artifact did not produce required debug symbols: {s}\n", .{staged_dsym_path});
            return error.DebugSymbolPublishFailed;
        },
    }

    const published_dsym_path = try debugSymbolBundlePath(alloc, published_artifact_path);
    defer alloc.free(published_dsym_path);

    // (1) Cache hit — the destination already holds an identical bundle
    // (content-keyed cache). Skip the publish entirely, but require removal
    // of the now-redundant staged copy so the cache root cannot accumulate
    // leaked staging artifacts after a successful publish.
    switch (cachedArtifactAccess(published_dsym_path) catch |err| {
        std.debug.print("Error: could not access published script debug symbols {s}: {s}\n", .{ published_dsym_path, @errorName(err) });
        return error.DebugSymbolAccessFailed;
    }) {
        .present => {
            try cleanupRedundantStagedDebugSymbols(staged_dsym_path);
            return;
        },
        .missing => {},
    }

    // (2) Atomic publish. POSIX `rename` cannot atomically replace a
    // NONEMPTY directory with another directory and reports
    // `error.DirNotEmpty` in that race-loss case — a concurrent publisher
    // beat us with byte-identical content for this content-key. Accept
    // only after required cleanup removes the redundant staged bundle.
    std.Io.Dir.cwd().rename(staged_dsym_path, std.Io.Dir.cwd(), published_dsym_path, global_io) catch |err| switch (err) {
        error.DirNotEmpty => {
            try cleanupRedundantStagedDebugSymbols(staged_dsym_path);
            return;
        },
        else => {
            std.debug.print("Error: could not publish script debug symbols to {s}: {}\n", .{ published_dsym_path, err });
            return error.DebugSymbolPublishFailed;
        },
    };
}

const SymbolTableSidecarPublishError = error{
    OutOfMemory,
    SymbolTableSidecarAccessFailed,
    SymbolTableSidecarMissing,
    SymbolTableSidecarPublishFailed,
};

/// Publish the `.zap-symbols` reversible-symbol sidecar from the staging
/// directory to the content-key directory, next to the published binary.
///
/// The ZIR backend writes `<staged_artifact>.zap-symbols` when emitting a
/// `.bin` (see `zir_backend.want_sidecar`). The crash reporter
/// (`src/runtime.zig`) loads `<exe>.zap-symbols` at the first `raise` to map
/// mangled frames back to Zap symbols, so the sidecar must travel with the
/// binary into its stable cache location.
///
/// Race-safety mirrors the binary publish path: rename the staged sidecar
/// directly into the published location. Unlike the dSYM directory case, a
/// POSIX file `rename` atomically REPLACES an existing destination, so a
/// concurrent winner with byte-identical content is just silently overwritten
/// and a stale regular file at the destination cannot survive a fresh publish.
///
/// The sidecar is a required part of the script/test artifact contract:
/// missing staged output, access failures, allocation failures, and publish
/// failures all surface to the caller so the command cannot report a
/// successful binary whose crash-symbol sidecar is absent or unusable.
fn publishScriptSymbolTableSidecar(
    alloc: std.mem.Allocator,
    staged_artifact_path: []const u8,
    published_artifact_path: []const u8,
) SymbolTableSidecarPublishError!void {
    const staged = try symbolTableSidecarPath(alloc, staged_artifact_path);
    defer alloc.free(staged);
    switch (symbolTableSidecarFileAccess(staged) catch |err| {
        std.debug.print("Error: could not access staged script symbol table sidecar {s}: {s}\n", .{ staged, @errorName(err) });
        return error.SymbolTableSidecarAccessFailed;
    }) {
        .present => {},
        .missing => {
            std.debug.print("Error: script artifact did not produce required symbol table sidecar: {s}\n", .{staged});
            return error.SymbolTableSidecarMissing;
        },
    }

    const published = try symbolTableSidecarPath(alloc, published_artifact_path);
    defer alloc.free(published);

    // Atomic publish. POSIX `rename` of a file atomically REPLACES an
    // existing destination, so a concurrent publisher that beat us with
    // byte-identical content simply gets its copy replaced with our
    // (identical) copy. A pre-existing stale regular file is replaced too.
    std.Io.Dir.cwd().rename(staged, std.Io.Dir.cwd(), published, global_io) catch |err| {
        std.debug.print("Error: could not publish script symbol table sidecar to {s}: {s}\n", .{ published, @errorName(err) });
        return error.SymbolTableSidecarPublishFailed;
    };
}

const ScriptArtifactPublishError = DarwinDebugSymbolError ||
    SymbolTableSidecarPublishError ||
    ArtifactStagingCleanupError ||
    error{ScriptArtifactPublishFailed};

fn publishScriptArtifactToCache(
    alloc: std.mem.Allocator,
    config: zap.builder.BuildConfig,
    artifact_label: []const u8,
    staged_artifact_path: []const u8,
    published_artifact_path: []const u8,
    staging_dir: []const u8,
) ScriptArtifactPublishError!void {
    // Atomically publish the freshly-built binary into the shared
    // content-key directory. `rename` within the same cache root is atomic on
    // POSIX, so a concurrent run either sees the old absent state and builds
    // its own, or the fully-written final binary — never a partial file. A
    // racing publisher that already moved an identical binary into place is
    // fine: the rename replaces it with a byte-identical result for the same
    // key.
    std.Io.Dir.cwd().rename(staged_artifact_path, std.Io.Dir.cwd(), published_artifact_path, global_io) catch |err| {
        // A cross-device rename cannot happen here because staging and key
        // dirs share the cache root. Any failure is a real publish failure,
        // not a fallback opportunity.
        std.debug.print(
            "Error: could not publish {s} artifact to the cache: {s}\n",
            .{ artifact_label, @errorName(err) },
        );
        return error.ScriptArtifactPublishFailed;
    };

    publishScriptDebugSymbolsIfNeeded(alloc, config, staged_artifact_path, published_artifact_path) catch |err| {
        if (err == error.OutOfMemory) {
            std.debug.print("Error: out of memory publishing {s} debug symbols\n", .{artifact_label});
        }
        return err;
    };

    // Publish the `<artifact>.zap-symbols` sidecar alongside the binary so the
    // Phase 2 crash reporter can resolve mangled frames to Zap symbols at
    // runtime. The sidecar is emitted into the staging dir by the ZIR backend;
    // without this publish it would be discarded with the staging tree, so a
    // script/test artifact is not complete until the required sidecar is also
    // present.
    publishScriptSymbolTableSidecar(alloc, staged_artifact_path, published_artifact_path) catch |err| {
        if (err == error.OutOfMemory) {
            std.debug.print("Error: out of memory publishing {s} symbol table sidecar\n", .{artifact_label});
        }
        return err;
    };

    // Cleanup is part of the publish contract: once the binary and required
    // sidecars are visible in the content-key directory, the private staging
    // tree must be removed before the caller may report or run the artifact.
    try cleanupRequiredPublishedArtifactStaging(artifact_label, staging_dir);
}

test "P4J2: script symbol table sidecar publish installs the staged sidecar" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "staged");
    try tmp_dir.dir.createDirPath(global_io, "published");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const staged_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "staged", "app" });
    defer allocator.free(staged_artifact_path);
    const published_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "published", "app" });
    defer allocator.free(published_artifact_path);
    const staged_sidecar_path = try symbolTableSidecarPath(allocator, staged_artifact_path);
    defer allocator.free(staged_sidecar_path);
    const published_sidecar_path = try symbolTableSidecarPath(allocator, published_artifact_path);
    defer allocator.free(published_sidecar_path);

    try std.Io.Dir.cwd().writeFile(global_io, .{ .sub_path = staged_sidecar_path, .data = "symbols" });

    try publishScriptSymbolTableSidecar(allocator, staged_artifact_path, published_artifact_path);

    try std.testing.expectEqual(CachedArtifactAccessResult.missing, try symbolTableSidecarFileAccess(staged_sidecar_path));
    try std.testing.expectEqual(CachedArtifactAccessResult.present, try symbolTableSidecarFileAccess(published_sidecar_path));
    const published_bytes = try std.Io.Dir.cwd().readFileAlloc(global_io, published_sidecar_path, allocator, .limited(64));
    defer allocator.free(published_bytes);
    try std.testing.expectEqualStrings("symbols", published_bytes);
}

test "P4J2: script symbol table sidecar publish replaces an existing sidecar" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "staged");
    try tmp_dir.dir.createDirPath(global_io, "published");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const staged_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "staged", "app" });
    defer allocator.free(staged_artifact_path);
    const published_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "published", "app" });
    defer allocator.free(published_artifact_path);
    const staged_sidecar_path = try symbolTableSidecarPath(allocator, staged_artifact_path);
    defer allocator.free(staged_sidecar_path);
    const published_sidecar_path = try symbolTableSidecarPath(allocator, published_artifact_path);
    defer allocator.free(published_sidecar_path);

    try std.Io.Dir.cwd().writeFile(global_io, .{ .sub_path = staged_sidecar_path, .data = "fresh" });
    try std.Io.Dir.cwd().writeFile(global_io, .{ .sub_path = published_sidecar_path, .data = "stale" });

    try publishScriptSymbolTableSidecar(allocator, staged_artifact_path, published_artifact_path);

    const published_bytes = try std.Io.Dir.cwd().readFileAlloc(global_io, published_sidecar_path, allocator, .limited(64));
    defer allocator.free(published_bytes);
    try std.testing.expectEqualStrings("fresh", published_bytes);
}

test "P4J2: script symbol table sidecar publish rejects missing staged sidecar" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const staged_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "staged", "app" });
    defer allocator.free(staged_artifact_path);
    const published_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "published", "app" });
    defer allocator.free(published_artifact_path);

    try std.testing.expectError(
        error.SymbolTableSidecarMissing,
        publishScriptSymbolTableSidecar(allocator, staged_artifact_path, published_artifact_path),
    );
}

test "P4J2: script symbol table sidecar publish preserves allocation failures" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.OutOfMemory,
        publishScriptSymbolTableSidecar(failing_allocator.allocator(), "staged/app", "published/app"),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: script symbol table sidecar publish maps staged access failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "staged");
    try tmp_dir.dir.symLink(global_io, "app.zap-symbols", "staged/app.zap-symbols", .{});

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const staged_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "staged", "app" });
    defer allocator.free(staged_artifact_path);
    const published_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "published", "app" });
    defer allocator.free(published_artifact_path);

    try std.testing.expectError(
        error.SymbolTableSidecarAccessFailed,
        publishScriptSymbolTableSidecar(allocator, staged_artifact_path, published_artifact_path),
    );
}

test "P4J2: script symbol table sidecar publish maps rename failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "staged");
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "published", .data = "not a directory" });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const staged_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "staged", "app" });
    defer allocator.free(staged_artifact_path);
    const published_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "published", "app" });
    defer allocator.free(published_artifact_path);
    const staged_sidecar_path = try symbolTableSidecarPath(allocator, staged_artifact_path);
    defer allocator.free(staged_sidecar_path);
    try std.Io.Dir.cwd().writeFile(global_io, .{ .sub_path = staged_sidecar_path, .data = "symbols" });

    try std.testing.expectError(
        error.SymbolTableSidecarPublishFailed,
        publishScriptSymbolTableSidecar(allocator, staged_artifact_path, published_artifact_path),
    );
    try std.testing.expectEqual(CachedArtifactAccessResult.present, try symbolTableSidecarFileAccess(staged_sidecar_path));
}

test "P4J2: script artifact publish propagates required staging cleanup failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "staging/run");
    try tmp_dir.dir.createDirPath(global_io, "published");
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "staging/run/app", .data = "binary" });
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "staging/run/app.zap-symbols", .data = "symbols" });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const staged_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "staging", "run", "app" });
    defer allocator.free(staged_artifact_path);
    const published_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "published", "app" });
    defer allocator.free(published_artifact_path);
    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_path, "staging", "run" });
    defer allocator.free(staging_dir);
    const staging_parent = try std.fs.path.join(allocator, &.{ tmp_path, "staging" });
    defer allocator.free(staging_parent);

    try std.Io.Dir.cwd().setFilePermissions(global_io, staging_parent, std.Io.File.Permissions.fromMode(0o555), .{});
    defer std.Io.Dir.cwd().setFilePermissions(global_io, staging_parent, std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

    const config = zap.builder.BuildConfig{
        .name = "probe",
        .version = "0.0.0",
        .kind = .bin,
        .optimize = .debug,
        .target = "aarch64-linux-gnu",
    };

    try std.testing.expectError(
        error.ArtifactStagingCleanupFailed,
        publishScriptArtifactToCache(
            allocator,
            config,
            "script",
            staged_artifact_path,
            published_artifact_path,
            staging_dir,
        ),
    );
    try std.testing.expectEqual(CachedArtifactAccessResult.present, try cachedArtifactAccess(published_artifact_path));
    try std.testing.expect(try artifactHasRequiredSymbolTableSidecar(allocator, published_artifact_path));
}

test "P4J2: script dSYM publish propagates redundant staged cleanup failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "staging/run/app.dSYM/Contents");
    try tmp_dir.dir.createDirPath(global_io, "published/app.dSYM/Contents");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const staged_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "staging", "run", "app" });
    defer allocator.free(staged_artifact_path);
    const published_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "published", "app" });
    defer allocator.free(published_artifact_path);
    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_path, "staging", "run" });
    defer allocator.free(staging_dir);

    try std.Io.Dir.cwd().setFilePermissions(global_io, staging_dir, std.Io.File.Permissions.fromMode(0o555), .{});
    defer std.Io.Dir.cwd().setFilePermissions(global_io, staging_dir, std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

    try std.testing.expectError(
        error.DebugSymbolCleanupFailed,
        publishScriptDebugSymbolsIfNeeded(
            allocator,
            darwinDebugSymbolTestConfig(),
            staged_artifact_path,
            published_artifact_path,
        ),
    );
}

fn buildOverrideIdentity(overrides: BuildOverrides) build_cache.OverrideIdentity {
    return .{
        .optimize = if (overrides.optimize) |opt| @intFromEnum(opt) else null,
        .memory = overrides.memory,
        .target = overrides.target,
        .cpu = overrides.cpu,
        .runtime_concurrency = overrides.runtime_concurrency,
        // P6-J6: the trace-gate override joins the identity for the same
        // reason (it selects a different kernel object).
        .runtime_tracing = overrides.runtime_tracing,
        // P2-R1 (D6): thread the `-Ddebug-info=`/`-Dframe-pointers=`
        // overrides into the manifest invocation identity so two builds
        // differing only in those flags do not false-hit the snapshot.
        .debug_info = if (overrides.debug_info) |debug_info| @intFromEnum(debug_info) else null,
        .frame_pointers = overrides.frame_pointers,
    };
}

fn buildOptIdentityEntries(
    alloc: std.mem.Allocator,
    build_opts: std.StringHashMapUnmanaged([]const u8),
) error{OutOfMemory}![]build_cache.BuildOpt {
    var entries: std.ArrayListUnmanaged(build_cache.BuildOpt) = .empty;
    var iterator = build_opts.iterator();
    while (iterator.next()) |entry| {
        try entries.append(alloc, .{
            .key = entry.key_ptr.*,
            .value = entry.value_ptr.*,
        });
    }
    return entries.toOwnedSlice(alloc);
}

fn computeManifestInvocationIdentity(
    alloc: std.mem.Allocator,
    build_source: []const u8,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    collect_arc_stats: bool,
    zap_lib_dir: ?[]const u8,
    zig_lib_dir: []const u8,
    compiler_identity_digest: build_cache.ToolchainDigest,
    zig_lib_identity_digest: build_cache.ToolchainDigest,
) !build_cache.InvocationIdentity {
    const build_opt_identity_entries = buildOptIdentityEntries(alloc, build_opts) catch return error.OutOfMemory;
    defer alloc.free(build_opt_identity_entries);
    return build_cache.hashInvocationIdentity(alloc, .{
        .build_source = build_source,
        .project_root = project_root,
        .target_name = target_name,
        .build_opts = build_opt_identity_entries,
        .overrides = buildOverrideIdentity(build_overrides),
        .collect_arc_stats = collect_arc_stats,
        .zap_lib_dir = zap_lib_dir,
        .zig_lib_dir = zig_lib_dir,
        .zig_lib_identity_digest = zig_lib_identity_digest,
        .compiler_identity_digest = compiler_identity_digest,
    });
}

fn buildCacheKindFromConfig(kind: zap.builder.BuildConfig.Kind) build_cache.ArtifactKind {
    return switch (kind) {
        .bin => .bin,
        .lib => .lib,
        .obj => .obj,
    };
}

fn configKindFromBuildCache(kind: build_cache.ArtifactKind) zap.builder.BuildConfig.Kind {
    return switch (kind) {
        .bin => .bin,
        .lib => .lib,
        .obj => .obj,
    };
}

fn buildCachePipelineFromConfig(
    alloc: std.mem.Allocator,
    pipeline: ?zap.builder.BuildConfig.Pipeline,
) !?build_cache.Pipeline {
    const config_pipeline = pipeline orelse return null;
    const steps = try alloc.alloc(build_cache.PipelineStep, config_pipeline.steps.len);
    var initialized_count: usize = 0;
    errdefer {
        for (steps[0..initialized_count]) |step| {
            switch (step) {
                .compile => {},
                .run => |run_step| {
                    for (run_step.args) |arg| alloc.free(arg);
                    alloc.free(run_step.args);
                },
            }
        }
        alloc.free(steps);
    }

    for (config_pipeline.steps, 0..) |step, index| {
        steps[index] = switch (step) {
            .compile => .compile,
            .run => |run_step| .{ .run = .{
                .args = try cloneStringSlice(alloc, run_step.args),
                .forward_args = run_step.forward_args,
            } },
        };
        initialized_count += 1;
    }
    return .{ .steps = steps };
}

fn configPipelineFromBuildCache(
    allocator: std.mem.Allocator,
    pipeline: ?build_cache.Pipeline,
) !?zap.builder.BuildConfig.Pipeline {
    const cache_pipeline = pipeline orelse return null;
    const steps = try allocator.alloc(zap.builder.BuildConfig.Step, cache_pipeline.steps.len);
    var initialized_count: usize = 0;
    errdefer {
        for (steps[0..initialized_count]) |step| {
            switch (step) {
                .compile => {},
                .run => |run_step| {
                    for (run_step.args) |arg| allocator.free(arg);
                    allocator.free(run_step.args);
                },
            }
        }
        allocator.free(steps);
    }

    for (cache_pipeline.steps, 0..) |step, index| {
        steps[index] = switch (step) {
            .compile => .{ .compile = .{} },
            .run => |run_step| .{ .run = .{
                .args = try cloneStringSlice(allocator, run_step.args),
                .forward_args = run_step.forward_args,
            } },
        };
        initialized_count += 1;
    }
    return .{ .steps = steps };
}

fn tryManifestSnapshotHit(
    artifact_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    snapshot_path: []const u8,
    invocation_identity: build_cache.InvocationIdentity,
    progress: ?*zap.progress.Reporter,
    progress_node: ?zap.progress.Node,
) !?BuildArtifact {
    var stable_snapshot = build_cache.readStableSnapshot(scratch_allocator, snapshot_path) catch |err| switch (err) {
        error.FileNotFound => {
            if (progress_node) |node| node.cacheMiss("snapshot", "snapshot_missing");
            incrementalTrace("manifest-snapshot result=miss reason=snapshot_missing path={s}", .{snapshot_path});
            return null;
        },
        else => {
            incrementalTrace(
                "manifest-snapshot result=error reason={s} path={s}",
                .{ @errorName(err), snapshot_path },
            );
            return err;
        },
    };
    defer stable_snapshot.deinit(scratch_allocator);

    var validation_stats: build_cache.ValidationStats = .{};
    switch (try build_cache.validateSnapshot(scratch_allocator, stable_snapshot.snapshot, .{
        .invocation_identity = invocation_identity,
        .snapshot_mtime_nanos = stable_snapshot.mtime_nanos,
        .stats = &validation_stats,
    })) {
        .valid => {},
        .miss => {
            if (progress_node) |node| {
                if (build_cache.validationMissDetailAlloc(scratch_allocator, validation_stats)) |miss_detail| {
                    defer scratch_allocator.free(miss_detail);
                    node.cacheMiss("snapshot", miss_detail);
                } else |_| {
                    node.cacheMiss("snapshot", build_cache.validationMissReasonLabel(validation_stats.miss_reason));
                }
            }
            if (build_cache.validationMissDetailAlloc(scratch_allocator, validation_stats)) |miss_detail| {
                defer scratch_allocator.free(miss_detail);
                incrementalTrace(
                    "manifest-snapshot result=miss reason={s} path={s}",
                    .{ miss_detail, snapshot_path },
                );
            } else |_| {
                incrementalTrace(
                    "manifest-snapshot result=miss reason={s} path={s}",
                    .{ build_cache.validationMissReasonLabel(validation_stats.miss_reason), snapshot_path },
                );
            }
            return null;
        },
    }

    installCachedManifestArtifact(scratch_allocator, stable_snapshot.snapshot) catch |err| {
        incrementalTrace(
            "manifest-snapshot result=error reason=install_failed:{s} path={s}",
            .{ @errorName(err), snapshot_path },
        );
        return err;
    };

    if (progress_node) |node| node.cacheHit("snapshot", snapshot_path);
    incrementalTrace(
        "manifest-snapshot result=hit path={s} output={s}",
        .{ snapshot_path, stable_snapshot.snapshot.output_path },
    );
    if (progress) |reporter| {
        reporter.event("[cached] {s}\n", .{stable_snapshot.snapshot.output_path});
    } else {
        std.debug.print("[cached] {s}\n", .{stable_snapshot.snapshot.output_path});
    }
    const path = try artifact_allocator.dupe(u8, stable_snapshot.snapshot.output_path);
    errdefer artifact_allocator.free(path);
    const target = if (stable_snapshot.snapshot.target) |target_path| blk: {
        break :blk try artifact_allocator.dupe(u8, target_path);
    } else null;
    errdefer if (target) |target_value| artifact_allocator.free(target_value);
    const pipeline = try configPipelineFromBuildCache(artifact_allocator, stable_snapshot.snapshot.pipeline);
    errdefer if (pipeline) |pipeline_value| freeBuildPipeline(artifact_allocator, pipeline_value);
    return .{
        .path = path,
        .kind = configKindFromBuildCache(stable_snapshot.snapshot.kind),
        .target = target,
        .pipeline = pipeline,
    };
}

test "manifest snapshot hit propagates stable snapshot read allocation failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const snapshot_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/target.build-plan" });
    defer allocator.free(snapshot_path);

    const invocation_identity = testBuildCacheDigest(1);
    const snapshot: build_cache.Snapshot = .{
        .invocation_identity = invocation_identity,
        .cache_key_hex = "abcd",
        .cached_artifact_path = ".zap-cache/o/abcd/app",
        .output_path = "zap-out/bin/app",
        .kind = .bin,
        .debug_symbols_required = false,
    };
    try build_cache.writeSnapshotAtomic(allocator, snapshot_path, snapshot);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        tryManifestSnapshotHit(
            allocator,
            failing_allocator.allocator(),
            snapshot_path,
            invocation_identity,
            null,
            null,
        ),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "manifest snapshot hit propagates cached artifact installation failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(global_io, ".zap-cache/o/abcd") catch return error.Unexpected;
    tmp_dir.dir.writeFile(global_io, .{ .sub_path = ".zap-cache/o/abcd/app", .data = "binary" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(global_io, .{ .sub_path = "zap-out", .data = "not a directory" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const snapshot_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/target.build-plan" });
    defer allocator.free(snapshot_path);
    const cached_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/o/abcd/app" });
    defer allocator.free(cached_artifact_path);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "zap-out/bin/app" });
    defer allocator.free(output_path);

    const invocation_identity = testBuildCacheDigest(1);
    const snapshot: build_cache.Snapshot = .{
        .invocation_identity = invocation_identity,
        .cache_key_hex = "abcd",
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = .bin,
        .debug_symbols_required = false,
    };
    try build_cache.writeSnapshotAtomic(allocator, snapshot_path, snapshot);

    try std.testing.expectError(
        error.NotDir,
        tryManifestSnapshotHit(
            allocator,
            allocator,
            snapshot_path,
            invocation_identity,
            null,
            null,
        ),
    );
}

const MANIFEST_EVAL_CACHE_MAGIC: u32 = 0x5a_4d_45_31; // "ZME1"
const MANIFEST_EVAL_CACHE_VERSION: u16 = 1;
const MAX_MANIFEST_EVAL_CACHE_BYTES: usize = 4 * 1024 * 1024;

const CachedManifestEval = struct {
    arena: std.heap.ArenaAllocator,
    eval: zap.builder.ManifestEval,

    fn deinit(self: *CachedManifestEval) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn manifestEvalCachePath(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    target_name: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.manifest-eval", .{ cache_dir, target_name });
}

fn tryReadManifestEvalCache(
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    path: []const u8,
    invocation_identity: build_cache.InvocationIdentity,
) !?CachedManifestEval {
    return readManifestEvalCache(allocator, scratch_allocator, path, invocation_identity) catch |err| {
        switch (err) {
            error.FileNotFound,
            error.StaleManifestEvalCache,
            => {
                incrementalTrace(
                    "manifest-eval-cache result=miss reason={s} path={s}",
                    .{ @errorName(err), path },
                );
                return null;
            },
            else => {
                incrementalTrace(
                    "manifest-eval-cache result=error reason={s} path={s}",
                    .{ @errorName(err), path },
                );
                return err;
            },
        }
    };
}

fn readManifestEvalCache(
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    path: []const u8,
    invocation_identity: build_cache.InvocationIdentity,
) !CachedManifestEval {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(global_io, path, scratch_allocator, .limited(MAX_MANIFEST_EVAL_CACHE_BYTES));
    defer scratch_allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    if (try reader.takeInt(u32, .little) != MANIFEST_EVAL_CACHE_MAGIC) return error.InvalidManifestEvalCache;
    if (try reader.takeInt(u16, .little) != MANIFEST_EVAL_CACHE_VERSION) return error.InvalidManifestEvalCache;

    var stored_identity: build_cache.InvocationIdentity = undefined;
    try reader.readSliceAll(&stored_identity);
    if (!std.mem.eql(u8, stored_identity[0..], invocation_identity[0..])) return error.StaleManifestEvalCache;

    var cache_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer cache_arena.deinit();
    const cache_allocator = cache_arena.allocator();

    const config = try readManifestEvalBuildConfig(cache_allocator, &reader);
    const dependencies = try readManifestEvalCtDependencies(cache_allocator, &reader);
    const result_hash = try reader.takeInt(u64, .little);
    if (reader.seek != reader.end) return error.InvalidManifestEvalCache;

    const dependencies_valid = try zap.ctfe.PersistentCache.validateDependencies(scratch_allocator, dependencies, null, null);
    if (!dependencies_valid) {
        return error.StaleManifestEvalCache;
    }

    incrementalTrace("manifest-eval-cache result=hit path={s}", .{path});
    return .{
        .arena = cache_arena,
        .eval = .{
            .config = config,
            .dependencies = dependencies,
            .result_hash = result_hash,
        },
    };
}

fn writeManifestEvalCache(
    allocator: std.mem.Allocator,
    path: []const u8,
    invocation_identity: build_cache.InvocationIdentity,
    manifest_eval: zap.builder.ManifestEval,
) !void {
    try writeManifestEvalCacheWithWriter(allocator, path, invocation_identity, manifest_eval, ManifestEvalCacheFileWriter{});
}

fn writeRequiredManifestEvalCache(
    allocator: std.mem.Allocator,
    path: []const u8,
    invocation_identity: build_cache.InvocationIdentity,
    manifest_eval: zap.builder.ManifestEval,
) IncrementalError!void {
    return writeRequiredManifestEvalCacheWithWriter(allocator, path, invocation_identity, manifest_eval, ManifestEvalCacheFileWriter{});
}

fn writeRequiredManifestEvalCacheWithWriter(
    allocator: std.mem.Allocator,
    path: []const u8,
    invocation_identity: build_cache.InvocationIdentity,
    manifest_eval: zap.builder.ManifestEval,
    file_writer: anytype,
) IncrementalError!void {
    writeManifestEvalCacheWithWriter(allocator, path, invocation_identity, manifest_eval, file_writer) catch |err| {
        incrementalTrace(
            "manifest-eval-cache result=write_failed reason={s} path={s}",
            .{ @errorName(err), path },
        );
        return incrementalErrorOrStatus(err, error.CacheMetadataError);
    };
}

const ManifestEvalCacheFileWriter = struct {
    fn writeFileAtomic(
        _: ManifestEvalCacheFileWriter,
        allocator: std.mem.Allocator,
        path: []const u8,
        contents: []const u8,
    ) !void {
        try build_cache.writeFileAtomic(allocator, path, contents);
    }
};

const ManifestEvalCacheSerializer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    fn init(allocator: std.mem.Allocator) ManifestEvalCacheSerializer {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ManifestEvalCacheSerializer) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    fn written(self: *const ManifestEvalCacheSerializer) []const u8 {
        return self.bytes.items;
    }

    fn writeAll(self: *ManifestEvalCacheSerializer, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }

    fn writeByte(self: *ManifestEvalCacheSerializer, byte: u8) !void {
        try self.bytes.append(self.allocator, byte);
    }

    fn writeInt(
        self: *ManifestEvalCacheSerializer,
        comptime Int: type,
        value: Int,
        endian: std.builtin.Endian,
    ) !void {
        var bytes: [@sizeOf(Int)]u8 = undefined;
        std.mem.writeInt(Int, &bytes, value, endian);
        try self.writeAll(&bytes);
    }
};

fn writeManifestEvalCacheWithWriter(
    allocator: std.mem.Allocator,
    path: []const u8,
    invocation_identity: build_cache.InvocationIdentity,
    manifest_eval: zap.builder.ManifestEval,
    file_writer: anytype,
) !void {
    var serialized = ManifestEvalCacheSerializer.init(allocator);
    defer serialized.deinit();

    try serialized.writeInt(u32, MANIFEST_EVAL_CACHE_MAGIC, .little);
    try serialized.writeInt(u16, MANIFEST_EVAL_CACHE_VERSION, .little);
    try serialized.writeAll(&invocation_identity);
    try writeManifestEvalBuildConfig(&serialized, manifest_eval.config);
    try writeManifestEvalCtDependencies(&serialized, manifest_eval.dependencies);
    try serialized.writeInt(u64, manifest_eval.result_hash, .little);

    try file_writer.writeFileAtomic(allocator, path, serialized.written());
    incrementalTrace("manifest-eval-cache result=write path={s}", .{path});
}

fn writeManifestEvalString(writer: *ManifestEvalCacheSerializer, value: []const u8) !void {
    const len = std.math.cast(u32, value.len) orelse return error.ManifestEvalCacheTooLarge;
    try writer.writeInt(u32, len, .little);
    try writer.writeAll(value);
}

fn readManifestEvalString(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]const u8 {
    const len = try reader.takeInt(u32, .little);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try reader.readSliceAll(out);
    return out;
}

fn writeManifestEvalOptionalString(writer: *ManifestEvalCacheSerializer, value: ?[]const u8) !void {
    try writer.writeByte(if (value != null) 1 else 0);
    if (value) |some| try writeManifestEvalString(writer, some);
}

fn readManifestEvalOptionalString(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]const u8 {
    return switch (try reader.takeInt(u8, .little)) {
        0 => null,
        1 => try readManifestEvalString(allocator, reader),
        else => error.InvalidManifestEvalCache,
    };
}

fn writeManifestEvalBool(writer: *ManifestEvalCacheSerializer, value: bool) !void {
    try writer.writeByte(if (value) 1 else 0);
}

fn readManifestEvalBool(reader: *std.Io.Reader) !bool {
    return switch (try reader.takeInt(u8, .little)) {
        0 => false,
        1 => true,
        else => error.InvalidManifestEvalCache,
    };
}

fn writeManifestEvalStringSlice(writer: *ManifestEvalCacheSerializer, values: []const []const u8) !void {
    const count = std.math.cast(u32, values.len) orelse return error.ManifestEvalCacheTooLarge;
    try writer.writeInt(u32, count, .little);
    for (values) |value| try writeManifestEvalString(writer, value);
}

fn readManifestEvalStringSlice(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]const []const u8 {
    const count = try reader.takeInt(u32, .little);
    const values = try allocator.alloc([]const u8, count);
    for (values) |*value| {
        value.* = try readManifestEvalString(allocator, reader);
    }
    return values;
}

fn readManifestEvalBuildKind(reader: *std.Io.Reader) !zap.builder.BuildConfig.Kind {
    return switch (try reader.takeInt(u8, .little)) {
        @intFromEnum(zap.builder.BuildConfig.Kind.bin) => .bin,
        @intFromEnum(zap.builder.BuildConfig.Kind.lib) => .lib,
        @intFromEnum(zap.builder.BuildConfig.Kind.obj) => .obj,
        else => error.InvalidManifestEvalCache,
    };
}

fn readManifestEvalOptimize(reader: *std.Io.Reader) !zap.builder.BuildConfig.Optimize {
    return switch (try reader.takeInt(u8, .little)) {
        @intFromEnum(zap.builder.BuildConfig.Optimize.debug) => .debug,
        @intFromEnum(zap.builder.BuildConfig.Optimize.release_safe) => .release_safe,
        @intFromEnum(zap.builder.BuildConfig.Optimize.release_fast) => .release_fast,
        @intFromEnum(zap.builder.BuildConfig.Optimize.release_small) => .release_small,
        else => error.InvalidManifestEvalCache,
    };
}

fn writeManifestEvalOptionalDebugInfo(
    writer: *ManifestEvalCacheSerializer,
    value: ?zap.builder.BuildConfig.DebugInfo,
) !void {
    try writer.writeByte(if (value != null) 1 else 0);
    if (value) |some| try writer.writeByte(@intFromEnum(some));
}

fn readManifestEvalOptionalDebugInfo(reader: *std.Io.Reader) !?zap.builder.BuildConfig.DebugInfo {
    return switch (try reader.takeInt(u8, .little)) {
        0 => null,
        1 => switch (try reader.takeInt(u8, .little)) {
            @intFromEnum(zap.builder.BuildConfig.DebugInfo.full) => .full,
            @intFromEnum(zap.builder.BuildConfig.DebugInfo.split) => .split,
            @intFromEnum(zap.builder.BuildConfig.DebugInfo.none) => .none,
            else => error.InvalidManifestEvalCache,
        },
        else => error.InvalidManifestEvalCache,
    };
}

fn writeManifestEvalOptionalBool(writer: *ManifestEvalCacheSerializer, value: ?bool) !void {
    try writer.writeByte(if (value != null) 1 else 0);
    if (value) |some| try writeManifestEvalBool(writer, some);
}

fn readManifestEvalOptionalBool(reader: *std.Io.Reader) !?bool {
    return switch (try reader.takeInt(u8, .little)) {
        0 => null,
        1 => try readManifestEvalBool(reader),
        else => error.InvalidManifestEvalCache,
    };
}

fn writeManifestEvalBuildConfigDeps(
    writer: *ManifestEvalCacheSerializer,
    deps: []const zap.builder.BuildConfig.Dep,
) !void {
    const count = std.math.cast(u32, deps.len) orelse return error.ManifestEvalCacheTooLarge;
    try writer.writeInt(u32, count, .little);
    for (deps) |dep| {
        try writeManifestEvalString(writer, dep.name);
        switch (dep.source) {
            .path => |path| {
                try writer.writeByte(1);
                try writeManifestEvalString(writer, path);
            },
            .git => |git| {
                try writer.writeByte(2);
                try writeManifestEvalString(writer, git.url);
                try writeManifestEvalOptionalString(writer, git.tag);
                try writeManifestEvalOptionalString(writer, git.branch);
                try writeManifestEvalOptionalString(writer, git.rev);
            },
        }
        try writeManifestEvalOptionalString(writer, dep.local_override);
    }
}

fn readManifestEvalBuildConfigDeps(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ![]const zap.builder.BuildConfig.Dep {
    const count = try reader.takeInt(u32, .little);
    const deps = try allocator.alloc(zap.builder.BuildConfig.Dep, count);
    for (deps) |*dep| {
        const name = try readManifestEvalString(allocator, reader);
        const source: zap.builder.BuildConfig.DepSource = switch (try reader.takeInt(u8, .little)) {
            1 => .{ .path = try readManifestEvalString(allocator, reader) },
            2 => .{ .git = .{
                .url = try readManifestEvalString(allocator, reader),
                .tag = try readManifestEvalOptionalString(allocator, reader),
                .branch = try readManifestEvalOptionalString(allocator, reader),
                .rev = try readManifestEvalOptionalString(allocator, reader),
            } },
            else => return error.InvalidManifestEvalCache,
        };
        dep.* = .{
            .name = name,
            .source = source,
            .local_override = try readManifestEvalOptionalString(allocator, reader),
        };
    }
    return deps;
}

fn writeManifestEvalBuildOpts(
    writer: *ManifestEvalCacheSerializer,
    build_opts: std.StringHashMapUnmanaged([]const u8),
) !void {
    const count = std.math.cast(u32, build_opts.count()) orelse return error.ManifestEvalCacheTooLarge;
    try writer.writeInt(u32, count, .little);
    var iterator = build_opts.iterator();
    while (iterator.next()) |entry| {
        try writeManifestEvalString(writer, entry.key_ptr.*);
        try writeManifestEvalString(writer, entry.value_ptr.*);
    }
}

fn readManifestEvalBuildOpts(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !std.StringHashMapUnmanaged([]const u8) {
    var build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    const count = try reader.takeInt(u32, .little);
    try build_opts.ensureUnusedCapacity(allocator, count);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const key = try readManifestEvalString(allocator, reader);
        const value = try readManifestEvalString(allocator, reader);
        build_opts.putAssumeCapacity(key, value);
    }
    return build_opts;
}

fn writeManifestEvalMemoryManager(
    writer: *ManifestEvalCacheSerializer,
    memory_manager: ?zap.builder.BuildConfig.MemoryManager,
) !void {
    try writer.writeByte(if (memory_manager != null) 1 else 0);
    const manager = memory_manager orelse return;
    try writeManifestEvalString(writer, manager.type_name);
    try writeManifestEvalOptionalString(writer, manager.adapter_source_path);
}

fn readManifestEvalMemoryManager(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !?zap.builder.BuildConfig.MemoryManager {
    return switch (try reader.takeInt(u8, .little)) {
        0 => null,
        1 => .{
            .type_name = try readManifestEvalString(allocator, reader),
            .adapter_source_path = try readManifestEvalOptionalString(allocator, reader),
        },
        else => error.InvalidManifestEvalCache,
    };
}

fn writeManifestEvalDocGroups(
    writer: *ManifestEvalCacheSerializer,
    doc_groups: []const zap.builder.BuildConfig.DocGroup,
) !void {
    const count = std.math.cast(u32, doc_groups.len) orelse return error.ManifestEvalCacheTooLarge;
    try writer.writeInt(u32, count, .little);
    for (doc_groups) |group| {
        try writeManifestEvalString(writer, group.name);
        try writeManifestEvalStringSlice(writer, group.pages);
    }
}

fn readManifestEvalDocGroups(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ![]const zap.builder.BuildConfig.DocGroup {
    const count = try reader.takeInt(u32, .little);
    const groups = try allocator.alloc(zap.builder.BuildConfig.DocGroup, count);
    for (groups) |*group| {
        group.* = .{
            .name = try readManifestEvalString(allocator, reader),
            .pages = try readManifestEvalStringSlice(allocator, reader),
        };
    }
    return groups;
}

fn writeManifestEvalBuildConfig(
    writer: *ManifestEvalCacheSerializer,
    config: zap.builder.BuildConfig,
) !void {
    try writeManifestEvalString(writer, config.name);
    try writeManifestEvalString(writer, config.version);
    try writer.writeByte(@intFromEnum(config.kind));
    try writeManifestEvalOptionalString(writer, config.root);
    try writeManifestEvalOptionalString(writer, config.asset_name);
    try writer.writeByte(@intFromEnum(config.optimize));
    try writeManifestEvalOptionalDebugInfo(writer, config.debug_info);
    try writeManifestEvalOptionalBool(writer, config.frame_pointers);
    try writeManifestEvalOptionalString(writer, config.target);
    try writeManifestEvalOptionalString(writer, config.cpu);
    try writeManifestEvalStringSlice(writer, config.paths);
    try writeManifestEvalBuildConfigDeps(writer, config.deps);
    try writeManifestEvalBuildOpts(writer, config.build_opts);
    try writeManifestEvalMemoryManager(writer, config.memory_manager);
    try writer.writeInt(i64, config.test_timeout, .little);
    try writeManifestEvalOptionalString(writer, config.error_style);
    try writeManifestEvalBool(writer, config.multiline_errors);
    try writeManifestEvalOptionalString(writer, config.source_url);
    try writeManifestEvalOptionalString(writer, config.landing_page);
    try writeManifestEvalDocGroups(writer, config.doc_groups);
    try writeDaemonPipeline(writer, config.pipeline);
}

fn readManifestEvalBuildConfig(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !zap.builder.BuildConfig {
    return .{
        .name = try readManifestEvalString(allocator, reader),
        .version = try readManifestEvalString(allocator, reader),
        .kind = try readManifestEvalBuildKind(reader),
        .root = try readManifestEvalOptionalString(allocator, reader),
        .asset_name = try readManifestEvalOptionalString(allocator, reader),
        .optimize = try readManifestEvalOptimize(reader),
        .debug_info = try readManifestEvalOptionalDebugInfo(reader),
        .frame_pointers = try readManifestEvalOptionalBool(reader),
        .target = try readManifestEvalOptionalString(allocator, reader),
        .cpu = try readManifestEvalOptionalString(allocator, reader),
        .paths = try readManifestEvalStringSlice(allocator, reader),
        .deps = try readManifestEvalBuildConfigDeps(allocator, reader),
        .build_opts = try readManifestEvalBuildOpts(allocator, reader),
        .memory_manager = try readManifestEvalMemoryManager(allocator, reader),
        .test_timeout = try reader.takeInt(i64, .little),
        .error_style = try readManifestEvalOptionalString(allocator, reader),
        .multiline_errors = try readManifestEvalBool(reader),
        .source_url = try readManifestEvalOptionalString(allocator, reader),
        .landing_page = try readManifestEvalOptionalString(allocator, reader),
        .doc_groups = try readManifestEvalDocGroups(allocator, reader),
        .pipeline = try readDaemonPipeline(allocator, reader),
    };
}

fn writeManifestEvalCtDependencies(
    writer: *ManifestEvalCacheSerializer,
    dependencies: []const zap.ctfe.CtDependency,
) !void {
    const count = std.math.cast(u32, dependencies.len) orelse return error.ManifestEvalCacheTooLarge;
    try writer.writeInt(u32, count, .little);
    for (dependencies) |dependency| {
        switch (dependency) {
            .file => |file| {
                try writer.writeByte(1);
                try writeManifestEvalString(writer, file.path);
                try writer.writeInt(u64, file.content_hash, .little);
            },
            .env_var => |env_var| {
                try writer.writeByte(2);
                try writeManifestEvalString(writer, env_var.name);
                try writer.writeInt(u64, env_var.value_hash, .little);
                try writeManifestEvalBool(writer, env_var.present);
            },
            .glob => |glob_dep| {
                try writer.writeByte(3);
                try writeManifestEvalString(writer, glob_dep.pattern);
                try writer.writeInt(u64, glob_dep.result_hash, .little);
            },
            .reflected_struct => |reflected_struct| {
                try writer.writeByte(4);
                try writeManifestEvalString(writer, reflected_struct.struct_name);
                try writer.writeInt(u64, reflected_struct.interface_hash, .little);
            },
            .reflected_source => |reflected_source| {
                try writer.writeByte(5);
                try writeManifestEvalStringSlice(writer, reflected_source.paths);
                try writer.writeInt(u64, reflected_source.graph_hash, .little);
            },
        }
    }
}

fn readManifestEvalCtDependencies(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ![]const zap.ctfe.CtDependency {
    const count = try reader.takeInt(u32, .little);
    const dependencies = try allocator.alloc(zap.ctfe.CtDependency, count);
    for (dependencies) |*dependency| {
        dependency.* = switch (try reader.takeInt(u8, .little)) {
            1 => .{ .file = .{
                .path = try readManifestEvalString(allocator, reader),
                .content_hash = try reader.takeInt(u64, .little),
            } },
            2 => .{ .env_var = .{
                .name = try readManifestEvalString(allocator, reader),
                .value_hash = try reader.takeInt(u64, .little),
                .present = try readManifestEvalBool(reader),
            } },
            3 => .{ .glob = .{
                .pattern = try readManifestEvalString(allocator, reader),
                .result_hash = try reader.takeInt(u64, .little),
            } },
            4 => .{ .reflected_struct = .{
                .struct_name = try readManifestEvalString(allocator, reader),
                .interface_hash = try reader.takeInt(u64, .little),
            } },
            5 => .{ .reflected_source = .{
                .paths = try readManifestEvalStringSlice(allocator, reader),
                .graph_hash = try reader.takeInt(u64, .little),
            } },
            else => return error.InvalidManifestEvalCache,
        };
    }
    return dependencies;
}

/// The on-disk artifact filename for `config` — `<name>` for a binary,
/// `<name>.a` for a static lib, `<name>.o` for an object, where
/// `<name>` is the manifest `asset_name` (when non-empty) else the
/// manifest `name`. SINGLE source of truth shared by `compileAndLink`
/// (which writes it) and the script skip-recompile fast path (which
/// must look for the exact same filename in the content-key dir); a
/// second copy of this rule would be a silent divergence risk.
fn buildArtifactFilename(
    alloc: std.mem.Allocator,
    config: zap.builder.BuildConfig,
) ![]const u8 {
    const output_name = if (config.asset_name) |an|
        if (an.len > 0) an else config.name
    else
        config.name;
    return switch (config.kind) {
        .bin => alloc.dupe(u8, output_name),
        .lib => std.fmt.allocPrint(alloc, "{s}.a", .{output_name}),
        .obj => std.fmt.allocPrint(alloc, "{s}.o", .{output_name}),
    };
}

/// Runtime-source startup-prologue rewrite shape. Only executable
/// binary outputs have a generated entry point that the final artifact
/// is guaranteed to run before runtime-managed memory can be touched.
/// Object outputs may contain a generated `main` function, but the
/// object artifact has no executable entry boundary, so dispatchers
/// must keep their lazy startup fallback compiled in.
fn hasGeneratedExecutableStartupPrologue(kind: zap.builder.BuildConfig.Kind) bool {
    return kind == .bin;
}

const SourceRootResolutionOptions = struct {
    write_lockfile: bool = true,
    print_local_overrides: bool = true,
};

const SourceRootLockfileWriter = struct {
    fn writeLockfile(
        _: SourceRootLockfileWriter,
        allocator: std.mem.Allocator,
        project_root: []const u8,
        entries: []const zap.lockfile.LockEntry,
    ) !void {
        try zap.lockfile.writeLockfile(allocator, project_root, entries);
    }
};

const ManifestSources = struct {
    allocator: std.mem.Allocator,
    source_roots: []const zap.discovery.SourceRoot,
    source_units: []const compiler.SourceUnit,
    owned_source_paths: []const []const u8,
    struct_order: ?[]const []const u8,
    level_boundaries: ?[]const u32,
    source_file_to_struct: std.StringHashMap([]const u8),
    source_file_to_structs: std.StringHashMap([]const []const u8),
    source_file_imports: std.StringHashMap([]const []const u8),
    source_file_imported_by: std.StringHashMap([]const []const u8),
    source_file_compile_after_globs: std.StringHashMap([]const []const u8),
    source_file_compile_after_files: std.StringHashMap([]const []const u8),
    mapped_files: []compiler.MappedFile,

    fn deinit(self: *ManifestSources) void {
        const allocator = self.allocator;
        for (self.mapped_files) |*mapped_file| mapped_file.deinit(global_io);
        allocator.free(self.mapped_files);
        allocator.free(self.source_units);
        for (self.owned_source_paths) |source_path| allocator.free(source_path);
        allocator.free(self.owned_source_paths);
        if (self.struct_order) |struct_order| freeOwnedStringSlice(allocator, struct_order);
        if (self.level_boundaries) |level_boundaries| allocator.free(level_boundaries);
        deinitOwnedStringValueMap(allocator, &self.source_file_to_struct);
        deinitOwnedStringSliceMap(allocator, &self.source_file_to_structs);
        deinitOwnedStringSliceMap(allocator, &self.source_file_imports);
        deinitOwnedStringSliceMap(allocator, &self.source_file_imported_by);
        deinitOwnedStringSliceMap(allocator, &self.source_file_compile_after_globs);
        deinitOwnedStringSliceMap(allocator, &self.source_file_compile_after_files);
    }
};

fn freeOwnedStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn deinitOwnedStringValueMap(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap([]const u8),
) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn deinitOwnedStringSliceMap(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap([]const []const u8),
) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeOwnedStringSlice(allocator, entry.value_ptr.*);
    }
    map.deinit();
}

const ComputedIncrementalHashes = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(u64),
    root_present: bool = false,
    root_hash: u64 = 0,

    fn deinit(self: *ComputedIncrementalHashes) void {
        freeOwnedModuleHashKeys(self.allocator, &self.modules);
        self.modules.deinit();
    }
};

fn emittedIncrementalGraphChanged(
    previous_root_present: bool,
    previous_root_hash: u64,
    previous_modules: *const std.StringHashMap(u64),
    current_hashes: *const ComputedIncrementalHashes,
) bool {
    if (previous_root_present != current_hashes.root_present) return true;
    if (previous_root_present and previous_root_hash != current_hashes.root_hash) return true;
    if (previous_modules.count() != current_hashes.modules.count()) return true;

    var current_iter = current_hashes.modules.iterator();
    while (current_iter.next()) |entry| {
        const previous_hash = previous_modules.get(entry.key_ptr.*) orelse return true;
        if (previous_hash != entry.value_ptr.*) return true;
    }

    return false;
}

const IncrementalModuleSelection = struct {
    struct_names: []const []const u8,
    include_root: bool,
};

const PreparedIncrementalBackendPlan = struct {
    selection: IncrementalModuleSelection,
    invalidation: zir_backend.SelectedUpdateInvalidationPolicy,
};

const OwnedIncrementalModuleSelection = struct {
    struct_names: []const []const u8,
    include_root: bool,

    fn deinit(self: OwnedIncrementalModuleSelection, allocator: std.mem.Allocator) void {
        for (self.struct_names) |struct_name| allocator.free(struct_name);
        allocator.free(self.struct_names);
    }
};

fn traceIncrementalModuleSelection(
    comptime label: []const u8,
    selection: IncrementalModuleSelection,
) void {
    if (!incrementalTraceEnabled()) return;
    incrementalTrace(
        "backend-selection label={s} modules={d} include_root={}",
        .{ label, selection.struct_names.len, selection.include_root },
    );
    for (selection.struct_names) |struct_name| {
        incrementalTrace("backend-selection-item label={s} module={s}", .{ label, struct_name });
    }
}

fn traceOwnedIncrementalModuleSelection(
    comptime label: []const u8,
    selection: OwnedIncrementalModuleSelection,
) void {
    if (!incrementalTraceEnabled()) return;
    incrementalTrace(
        "backend-selection label={s} modules={d} include_root={}",
        .{ label, selection.struct_names.len, selection.include_root },
    );
    for (selection.struct_names) |struct_name| {
        incrementalTrace("backend-selection-item label={s} module={s}", .{ label, struct_name });
    }
}

fn incrementalModuleNameByte(byte: u8) u8 {
    return if (byte == '.') '_' else byte;
}

fn incrementalModuleNamesEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (incrementalModuleNameByte(left_byte) != incrementalModuleNameByte(right_byte)) return false;
    }
    return true;
}

fn moduleMapContainsIncrementalName(module_names: *std.StringHashMap(void), struct_name: []const u8) bool {
    if (module_names.contains(struct_name)) return true;
    var iter = module_names.iterator();
    while (iter.next()) |entry| {
        if (incrementalModuleNamesEqual(entry.key_ptr.*, struct_name)) return true;
    }
    return false;
}

fn moduleHashesContainIncrementalName(module_hashes: *const std.StringHashMap(u64), struct_name: []const u8) bool {
    if (module_hashes.contains(struct_name)) return true;
    var iter = module_hashes.iterator();
    while (iter.next()) |entry| {
        if (incrementalModuleNamesEqual(entry.key_ptr.*, struct_name)) return true;
    }
    return false;
}

fn normalizeIncrementalModuleName(allocator: std.mem.Allocator, struct_name: []const u8) ![]const u8 {
    const normalized = try allocator.dupe(u8, struct_name);
    for (normalized) |*byte| {
        byte.* = incrementalModuleNameByte(byte.*);
    }
    return normalized;
}

fn normalizeIncrementalSelectionForBackend(
    allocator: std.mem.Allocator,
    selection: IncrementalModuleSelection,
) !OwnedIncrementalModuleSelection {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var normalized_names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (normalized_names.items) |name| allocator.free(name);
        normalized_names.deinit(allocator);
    }

    for (selection.struct_names) |struct_name| {
        const normalized = try normalizeIncrementalModuleName(allocator, struct_name);
        errdefer allocator.free(normalized);
        if (seen.contains(normalized)) {
            allocator.free(normalized);
            continue;
        }
        try normalized_names.append(allocator, normalized);
        try seen.put(normalized, {});
    }

    return .{
        .struct_names = try normalized_names.toOwnedSlice(allocator),
        .include_root = selection.include_root,
    };
}

fn appendIncrementalSelectionStruct(
    allocator: std.mem.Allocator,
    selected_structs: *std.StringHashMap(void),
    ordered_structs: *std.ArrayListUnmanaged([]const u8),
    struct_name: []const u8,
) !void {
    if (moduleMapContainsIncrementalName(selected_structs, struct_name)) return;
    try selected_structs.put(struct_name, {});
    try ordered_structs.append(allocator, struct_name);
}

fn mergeIncrementalSelections(
    allocator: std.mem.Allocator,
    first: IncrementalModuleSelection,
    second: IncrementalModuleSelection,
) !IncrementalModuleSelection {
    var selected_structs = std.StringHashMap(void).init(allocator);
    defer selected_structs.deinit();
    var ordered_structs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer ordered_structs.deinit(allocator);

    for (first.struct_names) |struct_name| {
        try appendIncrementalSelectionStruct(allocator, &selected_structs, &ordered_structs, struct_name);
    }
    for (second.struct_names) |struct_name| {
        try appendIncrementalSelectionStruct(allocator, &selected_structs, &ordered_structs, struct_name);
    }

    return .{
        .struct_names = try ordered_structs.toOwnedSlice(allocator),
        .include_root = first.include_root or second.include_root,
    };
}

fn filterIncrementalSelectionToCurrentModules(
    allocator: std.mem.Allocator,
    selection: IncrementalModuleSelection,
    current_hashes: *const ComputedIncrementalHashes,
) !IncrementalModuleSelection {
    var selected_structs = std.StringHashMap(void).init(allocator);
    defer selected_structs.deinit();
    var ordered_structs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer ordered_structs.deinit(allocator);

    for (selection.struct_names) |struct_name| {
        if (!moduleHashesContainIncrementalName(&current_hashes.modules, struct_name)) continue;
        try appendIncrementalSelectionStruct(allocator, &selected_structs, &ordered_structs, struct_name);
    }

    return .{
        .struct_names = try ordered_structs.toOwnedSlice(allocator),
        .include_root = selection.include_root and current_hashes.root_present,
    };
}

fn validateIncrementalHashTopology(
    previous_root_present: bool,
    previous_modules: *const std.StringHashMap(u64),
    current_hashes: *const ComputedIncrementalHashes,
) !void {
    if (previous_root_present and !current_hashes.root_present) {
        return error.ContextInvalidated;
    }

    var old_iter = previous_modules.iterator();
    while (old_iter.next()) |entry| {
        if (!current_hashes.modules.contains(entry.key_ptr.*)) {
            return error.ContextInvalidated;
        }
    }

    var current_iter = current_hashes.modules.iterator();
    while (current_iter.next()) |entry| {
        if (!previous_modules.contains(entry.key_ptr.*)) {
            return error.ContextInvalidated;
        }
    }
}

fn selectChangedIncrementalModulesFromHashes(
    allocator: std.mem.Allocator,
    previous_root_present: bool,
    previous_root_hash: u64,
    previous_modules: *const std.StringHashMap(u64),
    current_hashes: *const ComputedIncrementalHashes,
) !IncrementalModuleSelection {
    var selected_structs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer selected_structs.deinit(allocator);

    try validateIncrementalHashTopology(previous_root_present, previous_modules, current_hashes);
    const include_root = current_hashes.root_present and
        (!previous_root_present or previous_root_hash != current_hashes.root_hash);

    var current_iter = current_hashes.modules.iterator();
    while (current_iter.next()) |entry| {
        const old_hash = previous_modules.get(entry.key_ptr.*) orelse return error.ContextInvalidated;
        if (old_hash != entry.value_ptr.*) {
            try selected_structs.append(allocator, entry.key_ptr.*);
        }
    }

    return IncrementalModuleSelection{
        .struct_names = try selected_structs.toOwnedSlice(allocator),
        .include_root = include_root,
    };
}

fn selectAffectedIncrementalModulesFromFunctions(
    allocator: std.mem.Allocator,
    program: ir.Program,
    affected_function_ids: []const ir.FunctionId,
) !IncrementalModuleSelection {
    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(allocator);
    defer affected_functions.deinit();
    for (affected_function_ids) |function_id| {
        try affected_functions.put(function_id, {});
    }

    var selected_structs = std.StringHashMap(void).init(allocator);
    defer selected_structs.deinit();
    var ordered_structs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer ordered_structs.deinit(allocator);

    var include_root = false;
    for (program.functions) |function| {
        if (!affected_functions.contains(function.id)) continue;
        const is_entry = if (program.entry) |entry_id| function.id == entry_id else false;
        if (is_entry or function.struct_name == null) {
            include_root = true;
            continue;
        }
        try appendIncrementalSelectionStruct(
            allocator,
            &selected_structs,
            &ordered_structs,
            function.struct_name.?,
        );
    }

    return .{
        .struct_names = try ordered_structs.toOwnedSlice(allocator),
        .include_root = include_root,
    };
}

fn selectAllIncrementalModulesFromHashes(
    allocator: std.mem.Allocator,
    current_hashes: *const ComputedIncrementalHashes,
) !IncrementalModuleSelection {
    var ordered_structs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer ordered_structs.deinit(allocator);

    var iter = current_hashes.modules.iterator();
    while (iter.next()) |entry| {
        try ordered_structs.append(allocator, entry.key_ptr.*);
    }

    return .{
        .struct_names = try ordered_structs.toOwnedSlice(allocator),
        .include_root = current_hashes.root_present,
    };
}

fn selectPreparedIncrementalBackendModules(
    allocator: std.mem.Allocator,
    result: *const compiler.CompileResult,
    previous_root_present: bool,
    previous_root_hash: u64,
    previous_modules: *const std.StringHashMap(u64),
    current_hashes: *const ComputedIncrementalHashes,
) !IncrementalModuleSelection {
    if (result.incremental_backend_force_full) {
        try validateIncrementalHashTopology(previous_root_present, previous_modules, current_hashes);
        return selectAllIncrementalModulesFromHashes(allocator, current_hashes);
    }

    const direct_backend_selection = try selectChangedIncrementalModulesFromHashes(
        allocator,
        previous_root_present,
        previous_root_hash,
        previous_modules,
        current_hashes,
    );
    defer allocator.free(direct_backend_selection.struct_names);

    const affected_function_backend_selection = try selectAffectedIncrementalModulesFromFunctions(
        allocator,
        result.ir_program,
        result.incremental_backend_affected_function_ids,
    );
    defer allocator.free(affected_function_backend_selection.struct_names);

    const merged_backend_selection = try mergeIncrementalSelections(
        allocator,
        direct_backend_selection,
        affected_function_backend_selection,
    );
    defer allocator.free(merged_backend_selection.struct_names);

    return filterIncrementalSelectionToCurrentModules(
        allocator,
        merged_backend_selection,
        current_hashes,
    );
}

fn selectPreparedIncrementalBackendPlan(
    allocator: std.mem.Allocator,
    result: *const compiler.CompileResult,
    previous_root_present: bool,
    previous_root_hash: u64,
    previous_modules: *const std.StringHashMap(u64),
    current_hashes: *const ComputedIncrementalHashes,
) !PreparedIncrementalBackendPlan {
    const selection = try selectPreparedIncrementalBackendModules(
        allocator,
        result,
        previous_root_present,
        previous_root_hash,
        previous_modules,
        current_hashes,
    );

    return .{
        .selection = selection,
        .invalidation = if (result.incremental_backend_force_full)
            .force_all_source_hashes
        else
            .compare_source_hashes,
    };
}

fn hashDeepValue(hasher: anytype, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool,
        .int,
        .comptime_int,
        .@"enum",
        .error_set,
        => std.hash.autoHash(hasher, value),
        .float => {
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits: Bits = @bitCast(value);
            hasher.update(std.mem.asBytes(&bits));
        },
        .optional => {
            if (value) |payload| {
                hasher.update(&.{1});
                hashDeepValue(hasher, payload);
            } else {
                hasher.update(&.{0});
            }
        },
        .pointer => |info| switch (info.size) {
            .one => hashDeepValue(hasher, value.*),
            .slice => {
                for (value) |item| hashDeepValue(hasher, item);
                hashDeepValue(hasher, value.len);
            },
            .many, .c => @compileError("incremental hashing cannot hash unknown-length pointers"),
        },
        .array => {
            for (value) |item| hashDeepValue(hasher, item);
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                hashDeepValue(hasher, @field(value, field.name));
            }
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("incremental hashing requires tagged unions");
            const tag = std.meta.activeTag(value);
            hashDeepValue(hasher, tag);
            inline for (info.fields) |field| {
                if (@field(Tag, field.name) == tag) {
                    if (field.type != void) hashDeepValue(hasher, @field(value, field.name));
                    return;
                }
            }
            unreachable;
        },
        .void, .null => {},
        else => @compileError("unsupported incremental hash type: " ++ @typeName(T)),
    }
}

fn mixIncrementalHash(seed: u64, tag: []const u8, value: anytype) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(tag);
    hashDeepValue(&hasher, value);
    return hasher.final();
}

fn mixIncrementalHashBytes(seed: u64, tag: []const u8, bytes: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(tag);
    hasher.update(bytes);
    return hasher.final();
}

const StableIrHashContext = struct {
    by_id: std.AutoHashMapUnmanaged(ir.FunctionId, *const ir.Function) = .empty,

    fn init(allocator: std.mem.Allocator, program: ir.Program) !StableIrHashContext {
        var ctx: StableIrHashContext = .{};
        errdefer ctx.deinit(allocator);
        for (program.functions) |*function| {
            try ctx.by_id.put(allocator, function.id, function);
        }
        return ctx;
    }

    fn deinit(self: *StableIrHashContext, allocator: std.mem.Allocator) void {
        self.by_id.deinit(allocator);
    }

    fn functionById(self: *const StableIrHashContext, id: ir.FunctionId) ?*const ir.Function {
        return self.by_id.get(id);
    }

    fn sourceClauseFunction(
        self: *const StableIrHashContext,
        group_id: ir.FunctionId,
        clause_index: u32,
    ) ?*const ir.Function {
        var iter = self.by_id.iterator();
        while (iter.next()) |entry| {
            const function = entry.value_ptr.*;
            if (function.source_group_id == group_id and function.source_clause_index == clause_index) {
                return function;
            }
        }
        return null;
    }
};

fn hashStableFunctionRef(
    hasher: anytype,
    ctx: *const StableIrHashContext,
    id: ir.FunctionId,
) void {
    if (ctx.functionById(id)) |function| {
        hasher.update("fn-ref-name");
        hasher.update(function.name);
        if (function.is_closure and function.captures.len > 0) {
            hasher.update("captured-closure-id");
            std.hash.autoHash(hasher, id);
        }
    } else {
        hasher.update("fn-ref-id");
        std.hash.autoHash(hasher, id);
    }
}

fn hashStableCallDirect(
    hasher: anytype,
    value: ir.CallDirect,
    ctx: *const StableIrHashContext,
) void {
    hasher.update("CallDirect");
    hashStableIrValue(hasher, value.dest, ctx);
    if (value.clause_index) |clause_index| {
        if (ctx.sourceClauseFunction(value.function, clause_index)) |function| {
            hasher.update("source-clause-name");
            hasher.update(function.name);
        } else {
            hashStableFunctionRef(hasher, ctx, value.function);
        }
        hashStableIrValue(hasher, clause_index, ctx);
    } else {
        hashStableFunctionRef(hasher, ctx, value.function);
    }
    hashStableIrValue(hasher, value.args, ctx);
    hashStableIrValue(hasher, value.arg_modes, ctx);
}

fn hashStableCallDispatch(
    hasher: anytype,
    value: ir.CallDispatch,
    ctx: *const StableIrHashContext,
) void {
    hasher.update("CallDispatch");
    hashStableIrValue(hasher, value.dest, ctx);
    hashStableFunctionRef(hasher, ctx, value.group_id);
    hashStableIrValue(hasher, value.args, ctx);
    hashStableIrValue(hasher, value.arg_modes, ctx);
}

fn hashStableMakeClosure(
    hasher: anytype,
    value: ir.MakeClosure,
    ctx: *const StableIrHashContext,
) void {
    hasher.update("MakeClosure");
    hashStableIrValue(hasher, value.dest, ctx);
    hashStableFunctionRef(hasher, ctx, value.function);
    hashStableIrValue(hasher, value.captures, ctx);
}

fn hashStableInstruction(
    hasher: anytype,
    value: ir.Instruction,
    ctx: *const StableIrHashContext,
) void {
    const tag = std.meta.activeTag(value);
    hashStableIrValue(hasher, tag, ctx);
    switch (value) {
        .call_direct => |payload| hashStableCallDirect(hasher, payload, ctx),
        .call_dispatch => |payload| hashStableCallDispatch(hasher, payload, ctx),
        .make_closure => |payload| hashStableMakeClosure(hasher, payload, ctx),
        inline else => |payload| hashStableIrValue(hasher, payload, ctx),
    }
}

fn hashStableParam(
    hasher: anytype,
    value: ir.Param,
    ctx: *const StableIrHashContext,
) void {
    hasher.update("Param");
    hashStableIrValue(hasher, value.name, ctx);
    hashStableIrValue(hasher, value.type_expr, ctx);
}

fn hashStableFunction(
    hasher: anytype,
    value: ir.Function,
    ctx: *const StableIrHashContext,
) void {
    hasher.update("Function");
    if (value.is_closure and value.captures.len > 0) {
        hasher.update("captured-closure-id");
        hashStableIrValue(hasher, value.id, ctx);
    }
    hashStableIrValue(hasher, value.name, ctx);
    if (value.source_clause_index) |clause_index| {
        hashStableIrValue(hasher, clause_index, ctx);
    }
    hashStableIrValue(hasher, value.debug_source_path, ctx);
    hashStableIrValue(hasher, value.debug_line, ctx);
    hashStableIrValue(hasher, value.debug_column, ctx);
    hashStableIrValue(hasher, value.struct_name, ctx);
    hashStableIrValue(hasher, value.local_name, ctx);
    hashStableIrValue(hasher, value.arity, ctx);
    hashStableIrValue(hasher, value.params, ctx);
    hashStableIrValue(hasher, value.return_type, ctx);
    hashStableIrValue(hasher, value.body, ctx);
    hashStableIrValue(hasher, value.is_closure, ctx);
    hashStableIrValue(hasher, value.captures, ctx);
    hashStableIrValue(hasher, value.local_count, ctx);
    hashStableIrValue(hasher, value.defaults, ctx);
    hashStableIrValue(hasher, value.loopify, ctx);
    hashStableIrValue(hasher, value.param_conventions, ctx);
    hashStableIrValue(hasher, value.local_ownership, ctx);
    hashStableIrValue(hasher, value.result_convention, ctx);
}

fn hashStableIrValue(
    hasher: anytype,
    value: anytype,
    ctx: *const StableIrHashContext,
) void {
    const T = @TypeOf(value);
    if (T == ir.Function) {
        hashStableFunction(hasher, value, ctx);
        return;
    }
    if (T == ir.Param) {
        hashStableParam(hasher, value, ctx);
        return;
    }
    if (T == ir.Instruction) {
        hashStableInstruction(hasher, value, ctx);
        return;
    }
    if (T == ir.CallDirect) {
        hashStableCallDirect(hasher, value, ctx);
        return;
    }
    if (T == ir.CallDispatch) {
        hashStableCallDispatch(hasher, value, ctx);
        return;
    }
    if (T == ir.MakeClosure) {
        hashStableMakeClosure(hasher, value, ctx);
        return;
    }

    switch (@typeInfo(T)) {
        .bool,
        .int,
        .comptime_int,
        .@"enum",
        .error_set,
        => std.hash.autoHash(hasher, value),
        .float => {
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits: Bits = @bitCast(value);
            hasher.update(std.mem.asBytes(&bits));
        },
        .optional => {
            if (value) |payload| {
                hasher.update(&.{1});
                hashStableIrValue(hasher, payload, ctx);
            } else {
                hasher.update(&.{0});
            }
        },
        .pointer => |info| switch (info.size) {
            .one => hashStableIrValue(hasher, value.*, ctx),
            .slice => {
                for (value) |item| hashStableIrValue(hasher, item, ctx);
                hashStableIrValue(hasher, value.len, ctx);
            },
            .many, .c => @compileError("incremental hashing cannot hash unknown-length pointers"),
        },
        .array => {
            for (value) |item| hashStableIrValue(hasher, item, ctx);
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                hashStableIrValue(hasher, @field(value, field.name), ctx);
            }
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("incremental hashing requires tagged unions");
            const tag = std.meta.activeTag(value);
            hashStableIrValue(hasher, tag, ctx);
            inline for (info.fields) |field| {
                if (@field(Tag, field.name) == tag) {
                    if (field.type != void) hashStableIrValue(hasher, @field(value, field.name), ctx);
                    return;
                }
            }
            unreachable;
        },
        .void, .null => {},
        else => @compileError("unsupported incremental hash type: " ++ @typeName(T)),
    }
}

fn mixStableIrHash(
    seed: u64,
    tag: []const u8,
    value: anytype,
    ctx: *const StableIrHashContext,
) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(tag);
    hashStableIrValue(&hasher, value, ctx);
    return hasher.final();
}

fn moduleHashSlot(
    allocator: std.mem.Allocator,
    modules: *std.StringHashMap(u64),
    name: []const u8,
) !*u64 {
    if (modules.getPtr(name)) |slot| return slot;

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    try modules.put(owned_name, mixIncrementalHashBytes(0, "module", name));
    return modules.getPtr(owned_name) orelse unreachable;
}

const TypeDefOwnerName = struct {
    name: []const u8,
    owned: bool,

    fn deinit(self: TypeDefOwnerName, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.name);
    }
};

fn typeDefOwnerName(
    allocator: std.mem.Allocator,
    type_name: []const u8,
) !TypeDefOwnerName {
    if (std.mem.lastIndexOf(u8, type_name, ".")) |dot_index| {
        const owner = try allocator.dupe(u8, type_name[0..dot_index]);
        for (owner) |*ch| {
            if (ch.* == '.') ch.* = '_';
        }
        return .{ .name = owner, .owned = true };
    }
    return .{ .name = type_name, .owned = false };
}

fn computeIncrementalHashes(
    allocator: std.mem.Allocator,
    program: ir.Program,
) !ComputedIncrementalHashes {
    var hashes: ComputedIncrementalHashes = .{
        .allocator = allocator,
        .modules = std.StringHashMap(u64).init(allocator),
    };
    errdefer hashes.deinit();

    var stable_ctx = try StableIrHashContext.init(allocator, program);
    defer stable_ctx.deinit(allocator);

    for (program.functions) |func| {
        const is_entry = if (program.entry) |entry_id| func.id == entry_id else false;
        if (is_entry or func.struct_name == null) {
            hashes.root_present = true;
            hashes.root_hash = mixStableIrHash(hashes.root_hash, "root-fn", func, &stable_ctx);
            continue;
        }

        const slot = try moduleHashSlot(allocator, &hashes.modules, func.struct_name.?);
        slot.* = mixStableIrHash(slot.*, "fn", func, &stable_ctx);
    }

    for (program.type_defs) |type_def| {
        const owner = try typeDefOwnerName(allocator, type_def.name);
        defer owner.deinit(allocator);
        const slot = try moduleHashSlot(allocator, &hashes.modules, owner.name);
        slot.* = mixStableIrHash(slot.*, "type", type_def, &stable_ctx);
    }

    return hashes;
}

fn computeSourceTopologyHash(manifest_sources: *const ManifestSources) u64 {
    var hash: u64 = 0;
    for (manifest_sources.source_units) |source_unit| {
        hash = mixIncrementalHashBytes(hash, "source-path", source_unit.file_path);
        if (source_unit.primary_struct_name) |struct_name| {
            hash = mixIncrementalHashBytes(hash, "source-struct", struct_name);
        } else {
            hash = mixIncrementalHashBytes(hash, "source-struct", "");
        }
        if (manifest_sources.source_file_to_structs.get(source_unit.file_path)) |structs| {
            for (structs) |struct_name| {
                hash = mixIncrementalHashBytes(hash, "source-struct-member", struct_name);
            }
        }
        if (manifest_sources.source_file_imports.get(source_unit.file_path)) |imports| {
            for (imports) |imported_struct| {
                hash = mixIncrementalHashBytes(hash, "source-import", imported_struct);
            }
        }
        if (manifest_sources.source_file_compile_after_globs.get(source_unit.file_path)) |patterns| {
            hash = mixIncrementalHashBytes(hash, "compile-after-globs", source_unit.file_path);
            for (patterns) |pattern| {
                hash = mixIncrementalHashBytes(hash, "compile-after-pattern", pattern);
            }
        }
        if (manifest_sources.source_file_compile_after_files.get(source_unit.file_path)) |matched_files| {
            for (matched_files) |matched_file| {
                hash = mixIncrementalHashBytes(hash, "compile-after-match", matched_file);
            }
        }
    }
    if (manifest_sources.struct_order) |struct_order| {
        for (struct_order) |struct_name| {
            hash = mixIncrementalHashBytes(hash, "order", struct_name);
        }
    }
    if (manifest_sources.level_boundaries) |level_boundaries| {
        for (level_boundaries) |boundary| {
            hash = mixIncrementalHash(hash, "level", boundary);
        }
    }
    return hash;
}

fn freeOwnedModuleHashKeys(allocator: std.mem.Allocator, module_hashes: *std.StringHashMap(u64)) void {
    var iter = module_hashes.iterator();
    while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
}

const OptionalSourceRootSkipReason = enum {
    missing,
    not_directory,
};

fn optionalSourceRootSkipReason(err: anyerror) ?OptionalSourceRootSkipReason {
    return switch (err) {
        error.FileNotFound => .missing,
        error.NotDir => .not_directory,
        else => null,
    };
}

fn optionalDirectorySkipReason(path: []const u8) !?OptionalSourceRootSkipReason {
    var dir = std.Io.Dir.cwd().openDir(global_io, path, .{}) catch |err| {
        if (optionalSourceRootSkipReason(err)) |reason| return reason;
        return err;
    };
    dir.close(global_io);
    return null;
}

fn appendImmediateSubdirectoryRootsFromOpenDir(
    alloc: std.mem.Allocator,
    source_roots: *std.ArrayListUnmanaged(zap.discovery.SourceRoot),
    root_name: []const u8,
    root_path: []const u8,
    dir: *std.Io.Dir,
) !void {
    var it = dir.iterate();
    while (try it.next(global_io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const subdir = try std.fs.path.join(alloc, &.{ root_path, entry.name });
        try source_roots.append(alloc, .{ .name = root_name, .path = subdir });
    }
}

fn appendImmediateSubdirectoryRoots(
    alloc: std.mem.Allocator,
    source_roots: *std.ArrayListUnmanaged(zap.discovery.SourceRoot),
    root_name: []const u8,
    root_path: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(global_io, root_path, .{ .iterate = true });
    defer dir.close(global_io);
    try appendImmediateSubdirectoryRootsFromOpenDir(alloc, source_roots, root_name, root_path, &dir);
}

fn appendOptionalSourceRoot(
    alloc: std.mem.Allocator,
    source_roots: *std.ArrayListUnmanaged(zap.discovery.SourceRoot),
    root_name: []const u8,
    root_path: []const u8,
) !?OptionalSourceRootSkipReason {
    var dir = std.Io.Dir.cwd().openDir(global_io, root_path, .{}) catch |err| {
        if (optionalSourceRootSkipReason(err)) |reason| return reason;
        return err;
    };
    defer dir.close(global_io);

    try source_roots.append(alloc, .{ .name = root_name, .path = root_path });
    return null;
}

fn appendOptionalSourceRootWithSubdirs(
    alloc: std.mem.Allocator,
    source_roots: *std.ArrayListUnmanaged(zap.discovery.SourceRoot),
    root_name: []const u8,
    root_path: []const u8,
) !?OptionalSourceRootSkipReason {
    var dir = std.Io.Dir.cwd().openDir(global_io, root_path, .{ .iterate = true }) catch |err| {
        if (optionalSourceRootSkipReason(err)) |reason| return reason;
        return err;
    };
    defer dir.close(global_io);

    try source_roots.append(alloc, .{ .name = root_name, .path = root_path });
    try appendImmediateSubdirectoryRootsFromOpenDir(alloc, source_roots, root_name, root_path, &dir);
    return null;
}

fn appendPackageSourceRoots(
    alloc: std.mem.Allocator,
    source_roots: *std.ArrayListUnmanaged(zap.discovery.SourceRoot),
    root_name: []const u8,
    package_dir: []const u8,
) !void {
    const lib_dir = try std.fs.path.join(alloc, &.{ package_dir, "lib" });
    const selected_root = if (try optionalDirectorySkipReason(lib_dir) == null) lib_dir else package_dir;
    try source_roots.append(alloc, .{ .name = root_name, .path = selected_root });
    try appendImmediateSubdirectoryRoots(alloc, source_roots, root_name, selected_root);
}

fn appendProjectSourceRoots(
    alloc: std.mem.Allocator,
    source_roots: *std.ArrayListUnmanaged(zap.discovery.SourceRoot),
    project_root: []const u8,
) !void {
    const lib_dir = try std.fs.path.join(alloc, &.{ project_root, "lib" });
    _ = try appendOptionalSourceRootWithSubdirs(alloc, source_roots, "project", lib_dir);

    const test_dir = try std.fs.path.join(alloc, &.{ project_root, "test" });
    _ = try appendOptionalSourceRootWithSubdirs(alloc, source_roots, "project", test_dir);

    const tools_dir = try std.fs.path.join(alloc, &.{ project_root, "tools" });
    _ = try appendOptionalSourceRootWithSubdirs(alloc, source_roots, "project", tools_dir);

    try source_roots.append(alloc, .{ .name = "project", .path = project_root });
}

fn appendZapStdlibSourceRoots(
    alloc: std.mem.Allocator,
    source_roots: *std.ArrayListUnmanaged(zap.discovery.SourceRoot),
    zap_lib_dir: ?[]const u8,
) !void {
    const zap_lib = zap_lib_dir orelse return;
    try source_roots.append(alloc, .{ .name = "zap_stdlib", .path = zap_lib });
    const zap_subdir = try std.fs.path.join(alloc, &.{ zap_lib, "zap" });
    _ = try appendOptionalSourceRoot(alloc, source_roots, "zap_stdlib", zap_subdir);
}

fn lockEntryChanged(previous: zap.lockfile.LockEntry, current: zap.lockfile.LockEntry) bool {
    return !std.mem.eql(u8, previous.name, current.name) or
        !std.mem.eql(u8, previous.source_type, current.source_type) or
        !std.mem.eql(u8, previous.url, current.url) or
        !std.mem.eql(u8, previous.resolved_ref, current.resolved_ref) or
        !std.mem.eql(u8, previous.commit, current.commit) or
        !std.mem.eql(u8, previous.integrity, current.integrity);
}

fn lockEntryMissingOrChanged(previous: ?zap.lockfile.LockEntry, current: zap.lockfile.LockEntry) bool {
    const previous_entry = previous orelse return true;
    return lockEntryChanged(previous_entry, current);
}

fn resolveManifestSourceRoots(
    alloc: std.mem.Allocator,
    project_root: []const u8,
    config: zap.builder.BuildConfig,
    zap_lib_dir: ?[]const u8,
    options: SourceRootResolutionOptions,
) ![]const zap.discovery.SourceRoot {
    return resolveManifestSourceRootsWithLockfileWriter(
        alloc,
        project_root,
        config,
        zap_lib_dir,
        options,
        SourceRootLockfileWriter{},
    );
}

fn resolveManifestSourceRootsWithLockfileWriter(
    alloc: std.mem.Allocator,
    project_root: []const u8,
    config: zap.builder.BuildConfig,
    zap_lib_dir: ?[]const u8,
    options: SourceRootResolutionOptions,
    lockfile_writer: anytype,
) ![]const zap.discovery.SourceRoot {
    var source_roots: std.ArrayListUnmanaged(zap.discovery.SourceRoot) = .empty;
    try appendProjectSourceRoots(alloc, &source_roots, project_root);

    var lockfile: ?zap.lockfile.OwnedLockfile = null;
    defer if (lockfile) |*owned| owned.deinit();
    var lockfile_present = false;
    const read_result = try zap.lockfile.readLockfile(alloc, project_root);
    switch (read_result) {
        .absent => {},
        .present => |owned| {
            lockfile = owned;
            lockfile_present = true;
        },
    }
    var new_lock_entries: std.ArrayListUnmanaged(zap.lockfile.LockEntry) = .empty;
    defer new_lock_entries.deinit(alloc);
    var lockfile_changed = false;

    var git_requests: std.ArrayListUnmanaged(zap.lockfile.GitDepRequest) = .empty;
    defer git_requests.deinit(alloc);
    for (config.deps) |dep| {
        if (dep.local_override != null) continue;
        switch (dep.source) {
            .git => |git| {
                const locked = if (lockfile) |*owned|
                    zap.lockfile.findEntry(owned.entries, dep.name)
                else
                    null;
                try git_requests.append(alloc, .{
                    .name = dep.name,
                    .url = git.url,
                    .ref = git.tag orelse git.branch orelse git.rev,
                    .locked = locked,
                });
            },
            else => {},
        }
    }

    const git_results = zap.lockfile.fetchGitDepsParallel(alloc, git_requests.items) catch |err| {
        switch (err) {
            error.LockfileCommitMismatch, error.LockfileIntegrityMismatch, error.LockfileSourceDrift => {
                std.debug.print("Error: locked git dependency validation failed: {s}\n", .{@errorName(err)});
                return err;
            },
            else => {},
        }
        std.debug.print("Error: failed to fetch git dependencies: {s}\n", .{@errorName(err)});
        return error.GitDependencyFetchFailed;
    };
    var git_result_index: usize = 0;

    for (config.deps) |dep| {
        const dep_name = try std.fmt.allocPrint(alloc, "dep:{s}", .{dep.name});
        const locked = if (lockfile) |*owned|
            zap.lockfile.findEntry(owned.entries, dep.name)
        else
            null;

        if (dep.local_override) |override_path| {
            const dep_dir = try std.fs.path.join(alloc, &.{ project_root, override_path });
            try appendPackageSourceRoots(alloc, &source_roots, dep_name, dep_dir);
            const new_lock_entry = zap.lockfile.LockEntry{
                .name = dep.name,
                .source_type = "path",
                .url = override_path,
                .resolved_ref = "-",
                .commit = "-",
                .integrity = "-",
            };
            try new_lock_entries.append(alloc, new_lock_entry);
            if (lockEntryMissingOrChanged(locked, new_lock_entry)) lockfile_changed = true;
            if (options.print_local_overrides) {
                std.debug.print("  {s}: local override -> {s}\n", .{ dep.name, override_path });
            }
            continue;
        }

        switch (dep.source) {
            .path => |dep_path| {
                const dep_dir = try std.fs.path.join(alloc, &.{ project_root, dep_path });
                try appendPackageSourceRoots(alloc, &source_roots, dep_name, dep_dir);
                const new_lock_entry = zap.lockfile.LockEntry{
                    .name = dep.name,
                    .source_type = "path",
                    .url = dep_path,
                    .resolved_ref = "-",
                    .commit = "-",
                    .integrity = "-",
                };
                try new_lock_entries.append(alloc, new_lock_entry);
                if (lockEntryMissingOrChanged(locked, new_lock_entry)) lockfile_changed = true;
            },
            .git => |git| {
                if (git_result_index >= git_results.len) return error.GitDependencyFetchFailed;
                const result = git_results[git_result_index];
                git_result_index += 1;

                try appendPackageSourceRoots(alloc, &source_roots, dep_name, result.path);

                const ref = git.tag orelse git.branch orelse git.rev;
                const new_lock_entry = zap.lockfile.LockEntry{
                    .name = dep.name,
                    .source_type = "git",
                    .url = git.url,
                    .resolved_ref = ref orelse "-",
                    .commit = result.commit,
                    .integrity = result.integrity,
                };
                try new_lock_entries.append(alloc, new_lock_entry);
                if (lockEntryMissingOrChanged(locked, new_lock_entry)) lockfile_changed = true;
            },
        }
    }

    if (lockfile) |owned| {
        if (owned.entries.len != new_lock_entries.items.len) lockfile_changed = true;
    }

    if (options.write_lockfile and (!lockfile_present or lockfile_changed)) {
        try lockfile_writer.writeLockfile(alloc, project_root, new_lock_entries.items);
    }

    try appendZapStdlibSourceRoots(alloc, &source_roots, zap_lib_dir);
    return source_roots.items;
}

fn sourceRootShouldScanRecursively(root: zap.discovery.SourceRoot) bool {
    const basename = std.fs.path.basename(root.path);
    return std.mem.eql(u8, basename, "lib") or
        std.mem.eql(u8, basename, "test") or
        std.mem.eql(u8, basename, "tools") or
        std.mem.startsWith(u8, root.name, "dep:") or
        std.mem.eql(u8, root.name, "zap_stdlib");
}

fn deinitOwnedPathSet(alloc: std.mem.Allocator, paths: *std.StringHashMap(void)) void {
    var iter = paths.iterator();
    while (iter.next()) |entry| {
        alloc.free(entry.key_ptr.*);
    }
    paths.deinit();
}

fn deinitOwnedPathList(alloc: std.mem.Allocator, paths: *std.ArrayListUnmanaged([]const u8)) void {
    for (paths.items) |path| {
        if (path.len > 0) alloc.free(path);
    }
    paths.deinit(alloc);
}

fn appendUniqueOwnedSourcePath(
    alloc: std.mem.Allocator,
    source_files: *std.ArrayListUnmanaged([]const u8),
    discovered: *std.StringHashMap(void),
    owned_full_path: []const u8,
) !bool {
    const full_path = owned_full_path;
    var full_path_owned = true;
    defer if (full_path_owned) alloc.free(full_path);

    const key = try std.fs.path.resolve(alloc, &.{full_path});
    var key_owned = true;
    defer if (key_owned) alloc.free(key);

    if (discovered.contains(key)) return false;

    try discovered.put(key, {});
    key_owned = false;
    errdefer {
        if (discovered.remove(key)) {
            alloc.free(key);
        }
    }

    try source_files.append(alloc, full_path);
    full_path_owned = false;
    return true;
}

fn appendImmediateProjectZapFiles(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    source_files: *std.ArrayListUnmanaged([]const u8),
    discovered: *std.StringHashMap(void),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(global_io, root_path, .{ .iterate = true });
    defer dir.close(global_io);
    var it = dir.iterate();
    while (try it.next(global_io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
        if (std.mem.eql(u8, entry.name, "build.zap")) continue;
        const file_path = try std.fs.path.join(alloc, &.{ root_path, entry.name });
        _ = try appendUniqueOwnedSourcePath(alloc, source_files, discovered, file_path);
    }
}

/// Strip a leading `./` (or repeated `././`) and any leading slash from a
/// path so two paths can be compared on equal footing regardless of whether
/// the caller addressed them relative to cwd or as a bare project-relative
/// path. Mirrors the normalization `zap.glob.match` applies internally.
fn normalizeRelativePathForMatch(path: []const u8) []const u8 {
    var rest = path;
    while (std.mem.startsWith(u8, rest, "./")) rest = rest[2..];
    if (std.mem.eql(u8, rest, ".")) rest = rest[1..];
    while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    return rest;
}

/// Decide whether a `.zap` file discovered under a PROJECT source root falls
/// within the manifest's declared `paths` globs.
///
/// The supplementary protocol/impl scan (`appendProtocolAndImplSourceFiles`)
/// walks every `.zap` file under the project's recursive roots so that
/// protocols and impls are globally visible to monomorphization and vtable
/// population — even when they are not reachable through the entry point's
/// import graph. Left unconstrained, that walk over-collects: `test/` holds
/// script-mode subprocess fixtures (top-level `fn main`, `try`/`rescue`,
/// `@code`) that the integration suite runs as standalone `zap run`
/// processes, and those are illegal at project-mode top level. The manifest
/// already states the real corpus via `paths` (e.g. `test/**/*_test.zap`),
/// so the supplementary scan must honor that same contract for the project
/// root rather than compiling every file under it.
///
/// When the manifest declares no `paths` at all, there is no explicit scope
/// to honor, so every project file is contributed (the historical behavior),
/// keeping protocols/impls visible for manifests that rely purely on
/// import-graph discovery. Dependency and stdlib roots are NEVER filtered by
/// this rule — a library's protocols/impls are governed by the library, not
/// by the consuming project's `paths`.
fn projectSourceFileMatchesManifestPaths(
    alloc: std.mem.Allocator,
    manifest_paths: []const []const u8,
    project_root: []const u8,
    file_path: []const u8,
) !bool {
    if (manifest_paths.len == 0) return true;

    const normalized_root = normalizeRelativePathForMatch(project_root);
    const normalized_file = normalizeRelativePathForMatch(file_path);

    _ = alloc;

    // Reduce the file path to a project-relative path so it can be matched
    // against the manifest globs, which are themselves project-relative.
    // Every candidate reaches this function via a source root that was
    // produced by joining `project_root` with a subdirectory, so the file
    // always shares the project-root prefix; the non-prefixed branch is a
    // defensive fallback that matches against the full normalized path.
    const relative_file = blk: {
        if (normalized_root.len == 0) break :blk normalized_file;
        if (std.mem.startsWith(u8, normalized_file, normalized_root)) {
            const after_root = normalized_file[normalized_root.len..];
            if (after_root.len > 0 and after_root[0] == '/') break :blk after_root[1..];
            if (after_root.len == 0) break :blk after_root;
        }
        break :blk normalized_file;
    };

    for (manifest_paths) |pattern| {
        if (zap.glob.match(pattern, relative_file)) return true;
    }
    return false;
}

fn appendProtocolAndImplSourceFiles(
    alloc: std.mem.Allocator,
    source_roots: []const zap.discovery.SourceRoot,
    project_root: []const u8,
    manifest_paths: []const []const u8,
    source_files: *std.ArrayListUnmanaged([]const u8),
) !void {
    var discovered = std.StringHashMap(void).init(alloc);
    defer deinitOwnedPathSet(alloc, &discovered);
    for (source_files.items) |source_file| {
        const key = try std.fs.path.resolve(alloc, &.{source_file});
        errdefer alloc.free(key);
        if (discovered.contains(key)) {
            alloc.free(key);
            continue;
        }
        try discovered.put(key, {});
    }
    for (source_roots) |root| {
        const is_project_root = std.mem.eql(u8, root.name, "project");
        if (sourceRootShouldScanRecursively(root)) {
            if (is_project_root) {
                // Honor the manifest `paths` scope for the project's own
                // recursive roots; dependency and stdlib roots scan fully.
                var scanned: std.ArrayListUnmanaged([]const u8) = .empty;
                var scanned_seen = std.StringHashMap(void).init(alloc);
                defer deinitOwnedPathList(alloc, &scanned);
                defer deinitOwnedPathSet(alloc, &scanned_seen);
                try scanZapFilesRecursive(alloc, root.path, &scanned, &scanned_seen);
                var index: usize = 0;
                while (index < scanned.items.len) {
                    const candidate = scanned.items[index];
                    if (!try projectSourceFileMatchesManifestPaths(alloc, manifest_paths, project_root, candidate)) {
                        index += 1;
                        continue;
                    }
                    _ = scanned.orderedRemove(index);
                    _ = try appendUniqueOwnedSourcePath(alloc, source_files, &discovered, candidate);
                }
                continue;
            }
            try scanZapFilesRecursive(alloc, root.path, source_files, &discovered);
            continue;
        }
        if (is_project_root) {
            try appendImmediateProjectZapFiles(alloc, root.path, source_files, &discovered);
        }
    }
}

fn canonicalPathAlloc(alloc: std.mem.Allocator, file_path: []const u8) std.Io.Dir.RealPathFileAllocError![]const u8 {
    const canonical_path_z = try std.Io.Dir.cwd().realPathFileAlloc(global_io, file_path, alloc);
    defer alloc.free(canonical_path_z);
    return try alloc.dupe(u8, canonical_path_z[0..canonical_path_z.len]);
}

fn cloneStringSliceDeep(alloc: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const cloned = try alloc.alloc([]const u8, values.len);
    var cloned_count: usize = 0;
    errdefer {
        for (cloned[0..cloned_count]) |value| alloc.free(value);
        alloc.free(cloned);
    }
    for (values, 0..) |value, index| {
        cloned[index] = try alloc.dupe(u8, value);
        cloned_count = index + 1;
    }
    return cloned;
}

fn putOwnedStringValueIfAbsent(
    alloc: std.mem.Allocator,
    map: *std.StringHashMap([]const u8),
    key: []const u8,
    value: []const u8,
) !void {
    if (map.contains(key)) return;

    const owned_key = try alloc.dupe(u8, key);
    errdefer alloc.free(owned_key);
    const owned_value = try alloc.dupe(u8, value);
    errdefer alloc.free(owned_value);

    try map.put(owned_key, owned_value);
}

fn putOwnedStringSliceIfAbsent(
    alloc: std.mem.Allocator,
    map: *std.StringHashMap([]const []const u8),
    key: []const u8,
    values: []const []const u8,
) !void {
    if (map.contains(key)) return;

    const owned_key = try alloc.dupe(u8, key);
    errdefer alloc.free(owned_key);
    const owned_values = try cloneStringSliceDeep(alloc, values);
    errdefer freeOwnedStringSlice(alloc, owned_values);

    try map.put(owned_key, owned_values);
}

fn putPathSliceWithCanonical(
    alloc: std.mem.Allocator,
    map: *std.StringHashMap([]const []const u8),
    file_path: []const u8,
    values: []const []const u8,
) !void {
    const canonical_path = try canonicalPathAlloc(alloc, file_path);
    defer alloc.free(canonical_path);

    try putOwnedStringSliceIfAbsent(alloc, map, file_path, values);
    if (std.mem.eql(u8, canonical_path, file_path)) {
        return;
    }
    try putOwnedStringSliceIfAbsent(alloc, map, canonical_path, values);
}

fn putPathVoidWithCanonical(
    alloc: std.mem.Allocator,
    map: *std.StringHashMap(void),
    file_path: []const u8,
) !void {
    const canonical_path = try canonicalPathAlloc(alloc, file_path);
    errdefer alloc.free(canonical_path);

    var additional_count: usize = if (map.contains(file_path)) 0 else 1;
    const should_insert_canonical = !std.mem.eql(u8, canonical_path, file_path) and !map.contains(canonical_path);
    if (should_insert_canonical) additional_count += 1;

    try map.ensureUnusedCapacity(@intCast(additional_count));
    map.putAssumeCapacity(file_path, {});
    if (std.mem.eql(u8, canonical_path, file_path) or !should_insert_canonical) {
        alloc.free(canonical_path);
    } else {
        map.putAssumeCapacity(canonical_path, {});
    }
}

fn putPathStringWithCanonical(
    alloc: std.mem.Allocator,
    map: *std.StringHashMap([]const u8),
    file_path: []const u8,
    value: []const u8,
) !void {
    const canonical_path = try canonicalPathAlloc(alloc, file_path);
    defer alloc.free(canonical_path);

    try putOwnedStringValueIfAbsent(alloc, map, file_path, value);
    if (std.mem.eql(u8, canonical_path, file_path)) {
        return;
    }
    try putOwnedStringValueIfAbsent(alloc, map, canonical_path, value);
}

fn copyGraphListMap(
    alloc: std.mem.Allocator,
    destination: *std.StringHashMap([]const []const u8),
    source: *const std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
) !void {
    var iter = source.iterator();
    while (iter.next()) |entry| {
        try putPathSliceWithCanonical(alloc, destination, entry.key_ptr.*, entry.value_ptr.items);
    }
}

const StderrDiscoveryDiagnosticPrinter = struct {
    fn print(_: StderrDiscoveryDiagnosticPrinter, comptime format: []const u8, args: anytype) !void {
        std.debug.print(format, args);
    }
};

fn printStructNotFoundDiscoveryDiagnostic(
    alloc: std.mem.Allocator,
    printer: anytype,
    struct_name: []const u8,
) !void {
    const expected_path = try zap.discovery.structNameToRelPath(alloc, struct_name);
    defer alloc.free(expected_path);

    try printer.print("Error: Struct `{s}` not found — expected {s} in one of the source roots\n", .{ struct_name, expected_path });
}

fn discoverManifestSources(
    alloc: std.mem.Allocator,
    project_root: []const u8,
    config: zap.builder.BuildConfig,
    source_roots: []const zap.discovery.SourceRoot,
    progress: ?*zap.progress.Reporter,
) !ManifestSources {
    if (config.root == null) {
        std.debug.print("Error: build.zap must specify a root entry point\n", .{});
        return error.MissingRoot;
    }

    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    var source_files_transferred = false;
    errdefer if (!source_files_transferred) deinitOwnedPathList(alloc, &source_files);
    var explicit_source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer deinitOwnedPathList(alloc, &explicit_source_files);
    var source_file_to_struct = std.StringHashMap([]const u8).init(alloc);
    errdefer deinitOwnedStringValueMap(alloc, &source_file_to_struct);
    var source_file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    errdefer deinitOwnedStringSliceMap(alloc, &source_file_to_structs);
    var source_file_imports = std.StringHashMap([]const []const u8).init(alloc);
    errdefer deinitOwnedStringSliceMap(alloc, &source_file_imports);
    var source_file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    errdefer deinitOwnedStringSliceMap(alloc, &source_file_imported_by);
    var source_file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    errdefer deinitOwnedStringSliceMap(alloc, &source_file_compile_after_globs);
    var source_file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    errdefer deinitOwnedStringSliceMap(alloc, &source_file_compile_after_files);
    var struct_order: std.ArrayListUnmanaged([]const u8) = .empty;
    var struct_order_transferred = false;
    errdefer if (!struct_order_transferred) {
        for (struct_order.items) |struct_name| alloc.free(struct_name);
        struct_order.deinit(alloc);
    };
    var level_boundaries: std.ArrayListUnmanaged(u32) = .empty;
    var level_boundaries_transferred = false;
    errdefer if (!level_boundaries_transferred) level_boundaries.deinit(alloc);

    for (config.paths) |pattern| {
        try globCollectFiles(alloc, project_root, pattern, &explicit_source_files);
    }

    if (progress) |reporter| reporter.stage("Discovery: resolving source graph", .{});

    const root_spec = config.root.?;
    const slash_pos = std.mem.findScalar(u8, root_spec, '/');
    const name_part = if (slash_pos) |pos| root_spec[0..pos] else root_spec;
    const last_dot = std.mem.findScalarLast(u8, name_part, '.');
    const entry_struct = if (last_dot) |pos| name_part[0..pos] else name_part;

    var discovery_err_info: zap.discovery.ErrorInfo = .{};
    var file_graph = zap.discovery.discoverWithSourceFiles(
        alloc,
        entry_struct,
        source_roots,
        &zap.discovery.BUILTIN_TYPE_NAMES,
        explicit_source_files.items,
        &discovery_err_info,
    ) catch |err| switch (err) {
        error.StructNotFound => {
            if (discovery_err_info.unresolved_struct) |mod| {
                try printStructNotFoundDiscoveryDiagnostic(alloc, StderrDiscoveryDiagnosticPrinter{}, mod);
            } else if (discovery_err_info.boundary_struct) |mod| {
                std.debug.print("Error: Struct `{s}` is private (struct without pub) in {s} — cannot be accessed from {s}\n", .{
                    mod,
                    discovery_err_info.boundary_dep orelse "?",
                    discovery_err_info.boundary_from orelse "?",
                });
            } else {
                std.debug.print("Error: Struct not found during discovery\n", .{});
            }
            return error.DiscoveryFailed;
        },
        error.CircularDependency => {
            std.debug.print("Error: Circular struct dependency detected\n", .{});
            return error.DiscoveryFailed;
        },
        error.ReadError => {
            std.debug.print("Error: could not read source file\n", .{});
            return error.DiscoveryFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.debug.print("Error: file discovery failed\n", .{});
            return error.DiscoveryFailed;
        },
    };
    defer file_graph.deinit();

    {
        var iter = file_graph.file_to_struct.iterator();
        while (iter.next()) |entry| {
            try putPathStringWithCanonical(alloc, &source_file_to_struct, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    try copyGraphListMap(alloc, &source_file_to_structs, &file_graph.file_to_structs);
    try copyGraphListMap(alloc, &source_file_imports, &file_graph.file_imports);
    try copyGraphListMap(alloc, &source_file_imported_by, &file_graph.file_imported_by);
    try copyGraphListMap(alloc, &source_file_compile_after_globs, &file_graph.file_compile_after_globs);
    try copyGraphListMap(alloc, &source_file_compile_after_files, &file_graph.file_compile_after_files);

    for (file_graph.topo_order.items) |file_path| {
        const owned_file_path = try alloc.dupe(u8, file_path);
        var file_path_transferred = false;
        errdefer if (!file_path_transferred) alloc.free(owned_file_path);
        try source_files.append(alloc, owned_file_path);
        file_path_transferred = true;
    }

    try appendProtocolAndImplSourceFiles(alloc, source_roots, project_root, config.paths, &source_files);

    var file_index: usize = 0;
    var struct_count: u32 = 0;
    for (file_graph.level_boundaries.items) |file_boundary| {
        while (file_index < file_boundary) : (file_index += 1) {
            const file_path = file_graph.topo_order.items[file_index];
            for (file_graph.structsForFile(file_path)) |struct_name| {
                const owned_struct_name = try alloc.dupe(u8, struct_name);
                var struct_name_transferred = false;
                errdefer if (!struct_name_transferred) alloc.free(owned_struct_name);
                try struct_order.append(alloc, owned_struct_name);
                struct_name_transferred = true;
                struct_count += 1;
            }
        }
        if (struct_count > 0 and
            (level_boundaries.items.len == 0 or level_boundaries.items[level_boundaries.items.len - 1] != struct_count))
        {
            try level_boundaries.append(alloc, struct_count);
        }
    }

    {
        var seen = std.StringHashMap(void).init(alloc);
        defer deinitOwnedPathSet(alloc, &seen);
        var deduped: std.ArrayListUnmanaged([]const u8) = .empty;
        var deduped_transferred = false;
        errdefer if (!deduped_transferred) deinitOwnedPathList(alloc, &deduped);
        for (source_files.items) |*source_file_slot| {
            const source_file = source_file_slot.*;
            const key = try canonicalPathAlloc(alloc, source_file);
            if (!seen.contains(key)) {
                try seen.put(key, {});
                try deduped.append(alloc, source_file);
                source_file_slot.* = &.{};
            } else {
                alloc.free(key);
                alloc.free(source_file);
                source_file_slot.* = &.{};
            }
        }
        source_files.deinit(alloc);
        source_files = deduped;
        deduped_transferred = true;
    }

    if (source_files.items.len == 0) {
        std.debug.print("Error: no .zap source files found\n", .{});
        return error.NoSourceFiles;
    }

    if (progress) |reporter| reporter.stage("Sources: reading {d} files", .{source_files.items.len});

    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    var source_units_transferred = false;
    errdefer if (!source_units_transferred) source_units.deinit(alloc);
    var mapped_files: std.ArrayListUnmanaged(compiler.MappedFile) = .empty;
    var mapped_files_transferred = false;
    errdefer if (!mapped_files_transferred) {
        for (mapped_files.items) |*mapped_file| mapped_file.deinit(global_io);
        mapped_files.deinit(alloc);
    };

    var validation_failed = false;
    for (source_files.items) |source_file| {
        if (std.mem.eql(u8, std.fs.path.basename(source_file), "build.zap")) continue;

        const mapped = try compiler.mmapSourceFile(global_io, source_file, alloc);
        try mapped_files.append(alloc, mapped);
        try source_units.append(alloc, .{
            .file_path = source_file,
            .source = mapped.bytes(),
            .primary_struct_name = source_file_to_struct.get(source_file),
        });

        const is_dep_file = blk: {
            const norm_source_file = if (std.mem.startsWith(u8, source_file, "./")) source_file[2..] else source_file;
            for (source_roots) |root| {
                if (std.mem.startsWith(u8, root.name, "dep:") or
                    std.mem.eql(u8, root.name, "zap_stdlib"))
                {
                    const norm_root = if (std.mem.startsWith(u8, root.path, "./"))
                        root.path[2..]
                    else
                        root.path;
                    const root_slash = try std.fmt.allocPrint(alloc, "{s}/", .{norm_root});
                    defer alloc.free(root_slash);
                    if (std.mem.startsWith(u8, norm_source_file, root_slash)) break :blk true;
                }
            }
            break :blk false;
        };
        if (is_dep_file) continue;

        const lib_rel = blk: {
            const norm_source_file = if (std.mem.startsWith(u8, source_file, "./")) source_file[2..] else source_file;
            for (source_roots) |root| {
                const norm_root = if (std.mem.startsWith(u8, root.path, "./"))
                    root.path[2..]
                else
                    root.path;
                const root_slash = try std.fmt.allocPrint(alloc, "{s}/", .{norm_root});
                defer alloc.free(root_slash);
                if (std.mem.startsWith(u8, norm_source_file, root_slash)) {
                    break :blk norm_source_file[root_slash.len..];
                }
            }

            const rel_path = if (std.mem.startsWith(u8, source_file, project_root))
                std.mem.trimStart(u8, source_file[project_root.len..], "/")
            else
                source_file;

            if (std.mem.startsWith(u8, rel_path, "lib/")) break :blk rel_path[4..];
            if (std.mem.startsWith(u8, rel_path, "./")) break :blk rel_path[2..];
            break :blk rel_path;
        };

        if (try compiler.validateOneStructPerFile(alloc, mapped.bytes(), lib_rel)) |err_msg| {
            std.debug.print("Error: {s}\n", .{err_msg});
            validation_failed = true;
        }
    }
    if (validation_failed) return error.ValidationFailed;

    const owned_source_paths = try source_files.toOwnedSlice(alloc);
    source_files_transferred = true;
    errdefer {
        for (owned_source_paths) |source_path| alloc.free(source_path);
        alloc.free(owned_source_paths);
    }
    const owned_source_units = try source_units.toOwnedSlice(alloc);
    source_units_transferred = true;
    errdefer alloc.free(owned_source_units);
    const owned_mapped_files = try mapped_files.toOwnedSlice(alloc);
    mapped_files_transferred = true;
    errdefer {
        for (owned_mapped_files) |*mapped_file| mapped_file.deinit(global_io);
        alloc.free(owned_mapped_files);
    }
    const owned_struct_order = if (struct_order.items.len > 0) blk: {
        const slice = try struct_order.toOwnedSlice(alloc);
        struct_order_transferred = true;
        break :blk slice;
    } else null;
    errdefer if (owned_struct_order) |order| freeOwnedStringSlice(alloc, order);
    const owned_level_boundaries = if (level_boundaries.items.len > 0) blk: {
        const slice = try level_boundaries.toOwnedSlice(alloc);
        level_boundaries_transferred = true;
        break :blk slice;
    } else null;
    errdefer if (owned_level_boundaries) |boundaries| alloc.free(boundaries);

    return .{
        .allocator = alloc,
        .source_roots = source_roots,
        .source_units = owned_source_units,
        .owned_source_paths = owned_source_paths,
        .struct_order = owned_struct_order,
        .level_boundaries = owned_level_boundaries,
        .source_file_to_struct = source_file_to_struct,
        .source_file_to_structs = source_file_to_structs,
        .source_file_imports = source_file_imports,
        .source_file_imported_by = source_file_imported_by,
        .source_file_compile_after_globs = source_file_compile_after_globs,
        .source_file_compile_after_files = source_file_compile_after_files,
        .mapped_files = owned_mapped_files,
    };
}

/// Build a target. Returns the output artifact path and target kind.
fn buildTarget(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    collect_arc_stats: bool,
    zap_lib_dir_override: ?[]const u8,
) !BuildArtifact {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builder = zap.builder;
    // stderr writer removed in 0.16
    var progress = zap.progress.Reporter.init("Compiling", stderrProgressEnabled());
    const progress_reporter: ?*zap.progress.Reporter = if (progress.enabled) &progress else null;
    defer progress.finish();
    const progress_root = progressNodeParent(progress_reporter, null);

    var plan_node = ScopedProgressNode.start(progress_reporter, progress_root, "Plan target");
    defer plan_node.deinit();
    plan_node.updateCurrentItem(target_name, "Planning target :{s}", .{target_name});
    plan_node.succeed();

    // Read build.zap
    var read_manifest_node = ScopedProgressNode.start(progress_reporter, progress_root, "Read manifest");
    defer read_manifest_node.deinit();
    const build_file_path = try std.fs.path.join(alloc, &.{ project_root, "build.zap" });
    read_manifest_node.updateCurrentItem(build_file_path, "Manifest: reading build.zap", .{});
    const build_source = std.Io.Dir.cwd().readFileAlloc(global_io, build_file_path, alloc, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error reading build.zap: {}\n", .{err});
        std.process.exit(1);
    };
    read_manifest_node.succeed();

    // Resolve zap lib dir for stdlib (flag > env > exe-relative > cwd).
    var toolchain_node = ScopedProgressNode.start(progress_reporter, progress_root, "Resolve toolchain");
    defer toolchain_node.deinit();
    var zap_stdlib_node = ScopedProgressNode.start(progress_reporter, toolchain_node.node, "Zap stdlib");
    defer zap_stdlib_node.deinit();
    const zap_lib_dir = resolveZapLibDir(alloc, zap_lib_dir_override, project_root) catch {
        std.debug.print("Error: could not resolve Zap stdlib directory\n", .{});
        std.process.exit(1);
    };
    if (zap_lib_dir) |dir| zap_stdlib_node.updateCurrentItem(dir, "Toolchain: resolving Zap stdlib", .{});
    zap_stdlib_node.succeed();

    // Detect zig lib dir before CTFE so the manifest artifact snapshot
    // can validate an early cache hit without constructing the full
    // build plan.
    var zig_stdlib_node = ScopedProgressNode.start(progress_reporter, toolchain_node.node, "Zig stdlib");
    defer zig_stdlib_node.deinit();
    // Precedence: trusted (env or exe-relative fork stdlib) → embedded fork
    // stdlib → system Zig last (see the script-mode call site for why the
    // embedded fork stdlib must outrank a system install).
    const zig_lib_dir = resolveZigLibDir(alloc) catch |err| {
        std.debug.print("Error: could not resolve Zig lib: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    zig_stdlib_node.updateCurrentItem(zig_lib_dir, "Toolchain: resolving Zig stdlib", .{});
    zig_stdlib_node.succeed();

    const toolchain_cache_dir = ".zap-cache/toolchain";
    var compiler_identity_node = ScopedProgressNode.start(progress_reporter, toolchain_node.node, "Compiler identity");
    defer compiler_identity_node.deinit();
    const compiler_identity_digest = hashCompilerIdentity(alloc, toolchain_cache_dir) catch |err| {
        std.debug.print("Error: could not hash compiler identity for the manifest cache key: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const zig_lib_identity_digest = hashZigLibIdentity(alloc, toolchain_cache_dir, zig_lib_dir) catch |err| {
        std.debug.print("Error: could not hash Zig lib identity for the manifest cache key: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    compiler_identity_node.succeed();
    toolchain_node.succeed();
    const manifest_invocation_identity = computeManifestInvocationIdentity(
        alloc,
        build_source,
        project_root,
        target_name,
        build_opts,
        build_overrides,
        collect_arc_stats,
        zap_lib_dir,
        zig_lib_dir,
        compiler_identity_digest,
        zig_lib_identity_digest,
    ) catch return error.OutOfMemory;

    const backend_cache_dir = ".zap-cache";
    const manifest_snapshot_path = build_cache.snapshotPath(alloc, backend_cache_dir, target_name) catch return error.OutOfMemory;
    const manifest_eval_cache_path = manifestEvalCachePath(alloc, backend_cache_dir, target_name) catch return error.OutOfMemory;
    var manifest_cache_node = ScopedProgressNode.start(progress_reporter, progress_root, "Check manifest cache");
    defer manifest_cache_node.deinit();
    manifest_cache_node.updateCurrentItem(manifest_snapshot_path, "Manifest: checking cache", .{});
    if (try tryManifestSnapshotHit(allocator, alloc, manifest_snapshot_path, manifest_invocation_identity, progress_reporter, manifest_cache_node.node)) |artifact| {
        manifest_cache_node.succeed();
        switch (try warmManifestDaemon(
            alloc,
            manifest_invocation_identity,
            project_root,
            target_name,
            build_opts,
            build_overrides,
            collect_arc_stats,
            zap_lib_dir_override,
        )) {
            .sent, .pending_request => {},
        }
        return artifact;
    }
    manifest_cache_node.succeed();

    var daemon_node = ScopedProgressNode.start(progress_reporter, progress_root, "Manifest daemon");
    defer daemon_node.deinit();
    daemon_node.updateCurrentItem("querying incremental daemon", "Manifest: querying incremental daemon", .{});
    switch (try tryManifestDaemonBuild(
        allocator,
        alloc,
        manifest_invocation_identity,
        project_root,
        target_name,
        build_opts,
        build_overrides,
        collect_arc_stats,
        zap_lib_dir_override,
        daemon_node.node,
    )) {
        .artifact => |artifact| {
            daemon_node.succeed();
            if (try tryManifestSnapshotHit(allocator, alloc, manifest_snapshot_path, manifest_invocation_identity, progress_reporter, null)) |validated_artifact| {
                artifact.deinit(allocator);
                return validated_artifact;
            }

            artifact.deinit(allocator);
            var stale_node = ScopedProgressNode.start(progress_reporter, progress_root, "Manifest daemon");
            defer stale_node.deinit();
            const fallback_message = manifestDaemonFallbackMessage(.stale_artifact);
            stale_node.updateCurrentItem(fallback_message, "Manifest: {s}", .{fallback_message});
            stale_node.succeed();
        },
        .fallback => |fallback_reason| {
            const fallback_message = manifestDaemonFallbackMessage(fallback_reason);
            daemon_node.updateCurrentItem(fallback_message, "Manifest: {s}", .{fallback_message});
            daemon_node.skip();
        },
    }

    // Extract manifest from build.zap via CTFE.
    // Compiles build.zap to IR and evaluates manifest/1 at compile time.
    var manifest_eval_node = ScopedProgressNode.start(progress_reporter, progress_root, "Evaluate manifest");
    defer manifest_eval_node.deinit();
    var cached_manifest_eval: ?CachedManifestEval = null;
    defer if (cached_manifest_eval) |*cached| cached.deinit();
    manifest_eval_node.updateCurrentItem(manifest_eval_cache_path, "Manifest: checking eval cache", .{});
    const manifest_eval = if (try tryReadManifestEvalCache(
        allocator,
        alloc,
        manifest_eval_cache_path,
        manifest_invocation_identity,
    )) |cached_eval| blk: {
        cached_manifest_eval = cached_eval;
        manifest_eval_node.updateCurrentItem(manifest_eval_cache_path, "Manifest: using cached evaluation", .{});
        break :blk cached_manifest_eval.?.eval;
    } else blk: {
        manifest_eval_node.updateCurrentItem(build_file_path, "Manifest: evaluating build.zap", .{});
        const evaluated = builder.ctfeManifestDetailedWithProgress(alloc, build_source, target_name, build_overrides.target, build_opts, zap_lib_dir, progress_reporter) catch |err| {
            std.debug.print("Error: failed to evaluate build.zap manifest via CTFE: {}\n", .{err});
            std.process.exit(1);
        };
        writeRequiredManifestEvalCache(alloc, manifest_eval_cache_path, manifest_invocation_identity, evaluated) catch |err| {
            std.debug.print("Error: could not write manifest evaluation cache entry: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        break :blk evaluated;
    };
    manifest_eval_node.succeed();
    // The CLI is the ultimate per-field source of truth: overlay the
    // parsed `-D` build flags onto the manifest-produced config. This
    // is the SAME single override step the script path applies, so
    // there is exactly one flag pipeline. Unset flags preserve the
    // manifest values; `config.target`/`config.cpu` (manifest default
    // or `-Dtarget=`/`-Dcpu=`) drive the cross-compile path below.
    var config = manifest_eval.config;
    applyBuildOverrides(&config, build_overrides);

    var sources_node = ScopedProgressNode.start(progress_reporter, progress_root, "Resolve sources");
    defer sources_node.deinit();
    var source_roots_node = ScopedProgressNode.start(progress_reporter, sources_node.node, "Source roots");
    defer source_roots_node.deinit();
    const source_roots = resolveManifestSourceRoots(alloc, project_root, config, zap_lib_dir, .{}) catch |err| {
        std.debug.print("Error: source-root resolution failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    source_roots_node.succeed();
    var source_discovery_node = ScopedProgressNode.start(progress_reporter, sources_node.node, "Discover sources");
    defer source_discovery_node.deinit();
    var manifest_sources = discoverManifestSources(alloc, project_root, config, source_roots, progress_reporter) catch |err| {
        std.debug.print("Error: source discovery failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer manifest_sources.deinit();
    source_discovery_node.succeed();
    sources_node.succeed();

    var compile_tail_node = ScopedProgressNode.start(progress_reporter, progress_root, "Compile/link");
    defer compile_tail_node.deinit();
    const artifact = try compileAndLinkOrIce(allocator, alloc, "Z9101", .{
        .config = config,
        .source_roots = manifest_sources.source_roots,
        .source_units = manifest_sources.source_units,
        .struct_order = manifest_sources.struct_order,
        .level_boundaries = manifest_sources.level_boundaries,
        .manifest_result_hash = manifest_eval.result_hash,
        .cache_source = build_source,
        .target_name = target_name,
        .build_opts = build_opts,
        .zap_lib_dir = zap_lib_dir,
        .zig_lib_dir = zig_lib_dir,
        .compiler_identity_digest = compiler_identity_digest,
        .zig_lib_identity_digest = zig_lib_identity_digest,
        .project_root = project_root,
        .collect_arc_stats = collect_arc_stats,
        .layout = .manifest,
        .progress = progress_reporter,
        .progress_parent = compile_tail_node.node,
        .manifest_cache = .{
            .invocation_identity = manifest_invocation_identity,
            .snapshot_path = manifest_snapshot_path,
            .build_file_path = build_file_path,
            .dependencies = manifest_eval.dependencies,
        },
    });
    compile_tail_node.succeed();
    switch (try warmManifestDaemon(
        alloc,
        manifest_invocation_identity,
        project_root,
        target_name,
        build_opts,
        build_overrides,
        collect_arc_stats,
        zap_lib_dir_override,
    )) {
        .sent, .pending_request => {},
    }
    return artifact;
}

/// How and where build artifacts and compilation caches are written.
/// The manifest path keeps the historical cwd-relative `zap-out/` +
/// `.zap-cache/` layout for installed artifacts and cache storage. The
/// script path MUST never write next to the user's script — it routes
/// everything to a process-private temp directory.
const OutputLayout = union(enum) {
    /// Historical manifest behavior: cwd-relative `zap-out/<kind>` for
    /// the installed artifact and `.zap-cache` for backend/CTFE caches.
    manifest,
    /// Script behavior: every path rooted under `base_dir` (an
    /// absolute, process-private temp directory created by the script
    /// path).
    script: struct {
        base_dir: []const u8,
    },
};

const CompileAndLinkInputs = struct {
    config: zap.builder.BuildConfig,
    source_roots: []const zap.discovery.SourceRoot,
    source_units: []const compiler.SourceUnit,
    struct_order: ?[]const []const u8,
    level_boundaries: ?[]const u32,
    /// Manifest CTFE result hash (script path passes 0 — there is no
    /// manifest CTFE; the synthetic config is fully determined by the
    /// script source which is already folded into the cache key).
    manifest_result_hash: u64,
    /// Bytes folded into the compilation cache key alongside every
    /// source unit. Manifest path: the `build.zap` source. Script path:
    /// the script's own source.
    cache_source: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    zap_lib_dir: ?[]const u8,
    zig_lib_dir: []const u8,
    compiler_identity_digest: build_cache.ToolchainDigest,
    zig_lib_identity_digest: build_cache.ToolchainDigest,
    project_root: []const u8,
    collect_arc_stats: bool,
    // Cross-compile target/cpu are NOT separate inputs: they live on
    // `config` (manifest value overlaid by `-Dtarget=`/`-Dcpu=`), the
    // single source of truth. `compileAndLink` reads `config.target`
    // / `config.cpu` directly so there is no second target channel.
    layout: OutputLayout,
    progress: ?*zap.progress.Reporter = null,
    progress_parent: ?zap.progress.Node = null,
    manifest_cache: ?ManifestCacheInputs = null,
};

const ManifestCacheInputs = struct {
    invocation_identity: build_cache.InvocationIdentity,
    snapshot_path: []const u8,
    build_file_path: []const u8,
    dependencies: []const zap.ctfe.CtDependency,
};

const ManifestCacheKeyFailureStage = enum {
    active_manager_source_hash,
    build_input_hash,
    hex_encoding,
};

const ManifestCacheKeyFailure = struct {
    stage: ManifestCacheKeyFailureStage = .build_input_hash,
    active_manager_source_path: ?[]const u8 = null,
};

fn emitManifestCacheKeyFailureDiagnostic(failure: ManifestCacheKeyFailure, err: anyerror) void {
    switch (failure.stage) {
        .active_manager_source_hash => {
            if (failure.active_manager_source_path) |source_path| {
                zap.diagnostics.emitStderrFmt(
                    "Error: could not hash active memory manager source for manifest cache key ({s}): {s}\n",
                    .{ source_path, @errorName(err) },
                );
            } else {
                zap.diagnostics.emitStderrFmt(
                    "Error: could not hash active memory manager source for manifest cache key: {s}\n",
                    .{@errorName(err)},
                );
            }
        },
        .build_input_hash => zap.diagnostics.emitStderrFmt(
            "Error: could not hash manifest cache key inputs: {s}\n",
            .{@errorName(err)},
        ),
        .hex_encoding => zap.diagnostics.emitStderrFmt(
            "Error: could not encode manifest cache key digest: {s}\n",
            .{@errorName(err)},
        ),
    }
}

fn computeManifestCacheKeyHex(
    alloc: std.mem.Allocator,
    inputs: CompileAndLinkInputs,
    config: zap.builder.BuildConfig,
    active_manager_source_path: []const u8,
    /// P2-J1: content-address key of the concurrency kernel object
    /// (`concurrency_driver.kernelCacheKeyHex`) when
    /// `config.runtime_concurrency` is ON; "" when OFF.
    concurrency_kernel_key: []const u8,
    failure: ?*ManifestCacheKeyFailure,
) ![]const u8 {
    if (failure) |failure_info| failure_info.* = .{
        .stage = .active_manager_source_hash,
        .active_manager_source_path = active_manager_source_path,
    };
    const active_manager_source_digest = try hashActiveManagerSource(alloc, active_manager_source_path);
    const optimize_policy = optimizePolicyForBuildConfig(config.optimize);
    if (failure) |failure_info| failure_info.* = .{ .stage = .build_input_hash };
    const cache_digest = try computeBuildCacheKey(alloc, inputs.cache_source, inputs.source_units, inputs.target_name, .{
        .manifest_result_hash = inputs.manifest_result_hash,
        .active_manager_source_digest = active_manager_source_digest,
        .compiler_identity_digest = inputs.compiler_identity_digest,
        .zig_lib_identity_digest = inputs.zig_lib_identity_digest,
        .collect_arc_stats = inputs.collect_arc_stats,
        .optimize = config.optimize,
        .frontend_policy_tag = optimize_policy.frontend_policy_tag,
        .memory_manager_name = if (config.memory_manager) |m| m.type_name else "",
        .target = config.target orelse "",
        .cpu = config.cpu orelse "",
        .debug_info_tag = debugInfoCacheTagFor(config.debug_info),
        .frame_pointers_tag = framePointersCacheTagFor(config.frame_pointers),
        .runtime_concurrency = config.runtime_concurrency,
        .concurrency_kernel_key = concurrency_kernel_key,
    });
    if (failure) |failure_info| failure_info.* = .{ .stage = .hex_encoding };
    return digestHexAlloc(alloc, cache_digest);
}

fn writeManifestCacheMetadata(
    alloc: std.mem.Allocator,
    inputs: CompileAndLinkInputs,
    config: zap.builder.BuildConfig,
    output_path: []const u8,
    cached_artifact_path: []const u8,
    cache_key_hex: []const u8,
    active_manager_source_path: []const u8,
) !void {
    if (inputs.manifest_cache == null) return;
    if (inputs.progress) |reporter| reporter.stage("Cache: refreshing manifest snapshot", .{});
    try refreshManifestSnapshot(alloc, inputs, config, output_path, cached_artifact_path, cache_key_hex, active_manager_source_path);
}

/// Shared compile-and-link tail consumed by BOTH the manifest path
/// (`buildTarget`) and the single-file script path (`runScript`).
///
/// This is the verbatim former tail of `buildTarget` — memory-driver
/// resolve → frontend compile → root→IR-entry mangle → `zir_backend`
/// → return artifact — parameterized over the few inputs that differ
/// between the two callers (notably the output/cache `OutputLayout`).
/// The manifest path passes `.layout = .manifest`, which preserves the
/// exact cwd-relative `zap-out/`+`.zap-cache/` behavior. The script
/// path passes `.layout = .{ .script = .{ .base_dir = <tmp> } }` so
/// nothing is ever written next to the user's file.
/// True when `err` is a front-end compile failure that ALREADY emitted a
/// user-facing diagnostic (parse / collect / macro / desugar / typecheck / HIR
/// / IR). Such errors are the user's code being wrong — NOT a compiler bug — so
/// they must propagate as-is (the diagnostic is already on screen) and never be
/// re-reported as an ICE. Every OTHER error (`OutOfMemory`, link/system
/// failures, the incremental-graph internal-invariant violations, any
/// unexpected error) is a genuine internal failure that `compileAndLinkOrIce`
/// routes through the structured ICE path.
fn isUserDiagnosedCompileError(err: anyerror) bool {
    return switch (err) {
        error.ParseFailed,
        error.CollectFailed,
        error.MacroExpansionFailed,
        error.DesugarFailed,
        error.TypeCheckFailed,
        error.HirFailed,
        error.IrFailed,
        error.FrontendError,
        => true,
        else => false,
    };
}

/// `compileAndLink`, but any INTERNAL failure (anything that is not a
/// user-diagnosed front-end error per `isUserDiagnosedCompileError`) is lowered
/// into a structured `domain=ice` diagnostic and the process exits — instead of
/// a bare `error: OutOfMemory` + Zig stack trace escaping `main` (Phase 4.b:
/// "nothing internal ever reaches the user as a bare string"). A user-diagnosed
/// error propagates unchanged (its diagnostic is already shown). `ice_code` is
/// the stable `Z9xxx` band code identifying the call site.
fn compileAndLinkOrIce(
    allocator: std.mem.Allocator,
    alloc: std.mem.Allocator,
    ice_code: []const u8,
    inputs: CompileAndLinkInputs,
) !BuildArtifact {
    return compileAndLink(allocator, alloc, inputs) catch |err| {
        if (isUserDiagnosedCompileError(err)) return err;
        try compiler.emitIceFromError(alloc, "compile_and_link", ice_code, "code generation / link failed", err);
        std.process.exit(1);
    };
}

const CwdRequiredDirCreator = struct {
    fn createDirPath(_: *CwdRequiredDirCreator, dir: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(global_io, dir);
    }
};

fn prepareRequiredOutputCacheDirsWithCreator(
    creator: anytype,
    backend_cache_dir: []const u8,
    out_dir: []const u8,
) !void {
    try creator.createDirPath(backend_cache_dir);
    try creator.createDirPath(out_dir);
}

fn prepareRequiredOutputCacheDirs(
    backend_cache_dir: []const u8,
    out_dir: []const u8,
) !void {
    var creator = CwdRequiredDirCreator{};
    try prepareRequiredOutputCacheDirsWithCreator(&creator, backend_cache_dir, out_dir);
}

fn compileAndLink(
    allocator: std.mem.Allocator,
    alloc: std.mem.Allocator,
    inputs: CompileAndLinkInputs,
) !BuildArtifact {
    const builder = zap.builder;
    const config = inputs.config;
    const target_name = inputs.target_name;
    const project_root = inputs.project_root;
    const zap_lib_dir = inputs.zap_lib_dir;
    const zig_lib_dir = inputs.zig_lib_dir;
    const collect_arc_stats = inputs.collect_arc_stats;
    const progress = inputs.progress;
    // Single source of truth for cross-compilation: the (already
    // override-applied) `BuildConfig`. `target` null ⇒ native host
    // ⇒ `zir_compilation_create`; non-null ⇒ the cross path. `cpu`
    // refines the target's CPU model/features and is threaded into
    // both the user-binary compile and the memory-manager `.o` so
    // every object is built for the same machine.
    const compile_target = config.target;
    const compile_cpu = config.cpu;
    const optimize_policy = optimizePolicyForBuildConfig(config.optimize);

    // The CTFE/`@target` target is the ACTUAL compilation target —
    // `config.target` (the override-applied cross triple, null ⇒ native).
    // `inputs.target_name` is only a cache/identity LABEL (e.g. the literal
    // `"script"` in script mode), so it must NOT drive `@target`: using it
    // would leave `@target.os` unresolvable under `zap run`. The native
    // sentinel `"default"` resolves to the host triple in `target_triple`
    // and `ctfe.hashCompileOptions`. This single value feeds both the CTFE
    // cache key and the `@target` intrinsic — one channel, `config.target`.
    const ctfe_target = compile_target orelse "default";

    const external_progress_parent = inputs.progress_parent != null;
    const compile_parent_node = if (inputs.progress_parent) |parent_node|
        parent_node
    else
        startProgressNode(progress, progressNodeParent(progress, null), "Compile/link");
    var compile_parent_succeeded = false;
    defer if (!external_progress_parent) {
        finishProgressNode(compile_parent_node, if (compile_parent_succeeded) .succeeded else .failed);
    };

    var memory_adapter_node = ScopedProgressNode.start(progress, compile_parent_node, "Memory adapter");
    defer memory_adapter_node.deinit();
    const memory_adapter_eval = builder.evaluateMemoryManagerAdapterFromSources(
        alloc,
        inputs.source_roots,
        inputs.source_units,
        config.memory_manager,
        target_name,
        inputs.build_opts,
    ) catch |err| {
        std.debug.print("Error: failed to evaluate Memory.Manager adapter: {}\n", .{err});
        std.process.exit(1);
    };
    const manifest_memory_manager = memory_adapter_eval.manager orelse {
        std.debug.print("Error: manifest did not select a Memory.Manager adapter\n", .{});
        std.process.exit(1);
    };
    memory_adapter_node.updateCurrentItem(manifest_memory_manager.type_name, "Memory: resolving manifest adapter", .{});
    memory_adapter_node.succeed();
    const effective_manifest_hash = builder.hashManifestWithMemoryAdapter(
        inputs.manifest_result_hash,
        memory_adapter_eval.result_hash,
    );

    // Determine output path from manifest (needed for cache check)
    const output_name = if (config.asset_name) |an|
        if (an.len > 0) an else config.name
    else
        config.name;
    // The published filename is derived through the shared
    // `buildArtifactFilename` helper so the script skip-recompile
    // fast path and this writer can never disagree on the name.

    // Resolve the layout-specific output/cache directories. The
    // `manifest` arm reproduces the historical cwd-relative literals
    // exactly; the `script` arm roots every path under the
    // process-private temp dir so the script's own directory is never
    // touched.
    const out_dir_kind_suffix: []const u8 = switch (config.kind) {
        .bin => "bin",
        .lib => "lib",
        .obj => "obj",
    };
    const out_dir: []const u8 = switch (inputs.layout) {
        .manifest => switch (config.kind) {
            .bin => "zap-out/bin",
            .lib => "zap-out/lib",
            .obj => "zap-out/obj",
        },
        .script => |s| try std.fs.path.join(alloc, &.{ s.base_dir, "zap-out", out_dir_kind_suffix }),
    };
    const backend_cache_dir: []const u8 = switch (inputs.layout) {
        .manifest => ".zap-cache",
        .script => |s| try std.fs.path.join(alloc, &.{ s.base_dir, "zap-cache" }),
    };
    const ctfe_cache_dir = try std.fs.path.join(alloc, &.{ backend_cache_dir, "ctfe" });
    const memory_cache_dir = try std.fs.path.join(alloc, &.{ backend_cache_dir, "memory" });

    var output_cache_node = ScopedProgressNode.start(progress, compile_parent_node, "Output/cache preparation");
    defer output_cache_node.deinit();
    output_cache_node.updateCurrentItem(out_dir, "Cache: preparing output directories", .{});
    try prepareRequiredOutputCacheDirs(backend_cache_dir, out_dir);

    const output_filename = try buildArtifactFilename(alloc, config);
    const output_path = try std.fs.path.join(alloc, &.{ out_dir, output_filename });
    output_cache_node.updateCurrentItem(output_path, "Cache: preparing output directories", .{});
    output_cache_node.succeed();

    // Determine lib_mode from manifest kind
    const lib_mode = config.kind == .lib;

    // ------------------------------------------------------------------
    // Memory Manager ABI v1.0 — Phase 6 needs `declared_caps` BEFORE the
    // front-end so codegen elision can drop retain/release IR
    // materialization under managers that don't declare REFCOUNT_V1.
    // The resolution is therefore hoisted above the front-end compile;
    // the resolved object path is still consumed later when the ZIR
    // backend assembles the link line.
    // ------------------------------------------------------------------

    // Map the manifest optimize to the fork primitive's enum. v1.0 of the
    // Memory Manager ABI does not yet thread optimize through HIR/codegen,
    // so we match Zap's selection so debug/safe/fast produce a manager
    // built with the same optimization level as the rest of the binary.
    const driver_optimize = optimize_policy.memory_driver_optimize;

    var driver_diag_buf: [4096]u8 = undefined;
    var driver_diag: zap.memory_driver.DriverDiagnostic = .{ .buffer = &driver_diag_buf };

    // `resolveZapLibDir` always returns the stdlib `lib/` directory
    // itself (the validated flag/env dir, or the exe-relative/cwd `lib`
    // join — never its parent); the source tree root is the parent of
    // that directory, used for convention-resolved stdlib memory
    // manager backend sources.
    const zap_source_tree_root: []const u8 = if (zap_lib_dir) |lib_dir|
        (std.fs.path.dirname(lib_dir) orelse project_root)
    else
        project_root;

    const memory_driver_source_roots = sourceRootsForMemoryDriver(alloc, inputs.source_roots) catch return error.OutOfMemory;
    const memory_driver_options: zap.memory_driver.ResolveOptions = .{
        .adapter = .{
            .type_name = manifest_memory_manager.type_name,
            .adapter_source_path = manifest_memory_manager.adapter_source_path,
        },
        .source_roots = memory_driver_source_roots,
        .project_root = project_root,
        .zap_source_root = zap_source_tree_root,
        .cache_dir = memory_cache_dir,
        .zig_lib_dir = zig_lib_dir,
        .compiler_identity_digest = inputs.compiler_identity_digest,
        .zig_lib_identity_digest = inputs.zig_lib_identity_digest,
        .optimize = driver_optimize,
        // Thread the build's cross-compile target through so the
        // manager `.o` is built for the same target as the final
        // binary. Null means "native"; a non-null triple flows
        // through `parseTargetTriple` into the fork primitive's
        // `ZapForkTarget`.
        .target = compile_target,
        // Same CPU as the user binary so every object in the link
        // agrees on the target machine. Null/"" ⇒ default CPU.
        .cpu = compile_cpu,
        .progress = progress,
    };

    var manager_source_node = ScopedProgressNode.start(progress, compile_parent_node, "Manager source");
    defer manager_source_node.deinit();
    var source_selection = zap.memory_driver.resolveManagerSource(
        alloc,
        memory_driver_options,
        &driver_diag,
    ) catch |err| {
        std.debug.print("Error: memory manager source resolution failed: {s}\n", .{@errorName(err)});
        if (driver_diag.text().len > 0) {
            std.debug.print("  {s}\n", .{driver_diag.text()});
        }
        std.process.exit(1);
    };
    defer zap.memory_driver.freeManagerSourceSelection(alloc, &source_selection);
    manager_source_node.updateCurrentItem(source_selection.active_manager_source_path, "Memory: locating manager backend", .{});
    manager_source_node.succeed();

    // ------------------------------------------------------------------
    // P2-J1 — concurrency gate. When `runtime_concurrency` resolved ON,
    // the concurrency kernel unit (`src/runtime/concurrency/`, rooted at
    // `abi.zig`) is compiled per target through the same fork primitive
    // as manager sources and its object is linked into the binary. The
    // kernel's content-address key is computed HERE (cheap: a source
    // digest, no compile) so it participates in the artifact cache key;
    // the object compile itself happens after an artifact-cache miss,
    // mirroring the manager's source-selection/object split.
    // ------------------------------------------------------------------
    const runtime_concurrency_enabled = config.runtime_concurrency;
    validateRuntimeTracingGate(config);
    const concurrency_kernel_source_dir = try std.fs.path.join(
        alloc,
        &.{ zap_source_tree_root, zap.concurrency_driver.KERNEL_UNIT_RELATIVE_DIR },
    );
    const concurrency_cache_dir = try std.fs.path.join(alloc, &.{ backend_cache_dir, "concurrency" });
    const concurrency_kernel_options: zap.concurrency_driver.KernelResolveOptions = .{
        .kernel_source_dir = concurrency_kernel_source_dir,
        .cache_dir = concurrency_cache_dir,
        .zig_lib_dir = zig_lib_dir,
        .compiler_identity_digest = inputs.compiler_identity_digest,
        .zig_lib_identity_digest = inputs.zig_lib_identity_digest,
        .optimize = driver_optimize,
        .target = compile_target,
        .cpu = compile_cpu,
        .progress = progress,
        .runtime_tracing = config.runtime_tracing,
    };
    var concurrency_kernel_key_storage: [64]u8 = undefined;
    const concurrency_kernel_key: []const u8 = if (runtime_concurrency_enabled) blk: {
        var kernel_diag_buf: [4096]u8 = undefined;
        var kernel_diag: zap.memory_driver.DriverDiagnostic = .{ .buffer = &kernel_diag_buf };
        concurrency_kernel_key_storage = zap.concurrency_driver.kernelCacheKeyHex(
            alloc,
            concurrency_kernel_options,
            &kernel_diag,
        ) catch |err| {
            std.debug.print("Error: concurrency kernel resolution failed: {s}\n", .{@errorName(err)});
            if (kernel_diag.text().len > 0) {
                std.debug.print("  {s}\n", .{kernel_diag.text()});
            }
            std.process.exit(1);
        };
        break :blk &concurrency_kernel_key_storage;
    } else "";

    // Compilation caching: hash the cache source (build.zap or the
    // script source) + all Zap sources + target name, the selected
    // backend source, the running compiler identity, and EVERY build
    // control that changes the emitted artifact — including the
    // (post-override) optimize mode, frontend policy, memory manager,
    // cross target, cpu, and the P2-J1 concurrency gate + kernel key.
    // Folding these controls means flipping any
    // `-D` flag invalidates the cache (and is the exact key Phase 5's
    // content-addressed script skip-recompile attaches to: see
    // `cacheKeyControls`).
    var input_hash_node = ScopedProgressNode.start(progress, compile_parent_node, "Build input hashing");
    defer input_hash_node.deinit();
    var cache_inputs = inputs;
    cache_inputs.manifest_result_hash = effective_manifest_hash;
    var cache_key_failure: ManifestCacheKeyFailure = .{};
    const cache_key_hex = computeManifestCacheKeyHex(
        alloc,
        cache_inputs,
        config,
        source_selection.active_manager_source_path,
        concurrency_kernel_key,
        &cache_key_failure,
    ) catch |err| {
        emitManifestCacheKeyFailureDiagnostic(cache_key_failure, err);
        std.process.exit(1);
    };
    input_hash_node.updateCurrentItem(cache_key_hex, "Cache: hashing build inputs", .{});
    input_hash_node.succeed();
    const cached_manifest_artifact_path: ?[]const u8 = if (inputs.manifest_cache != null)
        try build_cache.artifactPath(alloc, backend_cache_dir, cache_key_hex, output_filename)
    else
        null;

    if (inputs.manifest_cache != null) {
        var artifact_cache_node = ScopedProgressNode.start(progress, compile_parent_node, "Artifact cache check");
        defer artifact_cache_node.deinit();
        const cache_valid = blk: {
            const cached_path = cached_manifest_artifact_path orelse break :blk false;
            artifact_cache_node.updateCurrentItem(cached_path, "Cache: checking artifact", .{});
            switch (cachedArtifactAccess(cached_path) catch |err| {
                std.debug.print("Error: could not access cached artifact {s}: {s}\n", .{ cached_path, @errorName(err) });
                std.process.exit(1);
            }) {
                .present => {},
                .missing => break :blk false,
            }
            const debug_symbols_ready = artifactHasRequiredDebugSymbols(alloc, config, cached_path) catch |err| {
                std.debug.print("Error: could not validate debug symbol cache state for {s}: {s}\n", .{ cached_path, @errorName(err) });
                std.process.exit(1);
            };
            if (!debug_symbols_ready) break :blk false;
            break :blk true;
        };

        if (cache_valid) {
            const cached_path = cached_manifest_artifact_path.?;
            artifact_cache_node.cacheHit("artifact", cached_path);
            const snapshot_for_install: build_cache.Snapshot = .{
                .invocation_identity = inputs.manifest_cache.?.invocation_identity,
                .cache_key_hex = cache_key_hex,
                .cached_artifact_path = cached_path,
                .output_path = output_path,
                .kind = buildCacheKindFromConfig(config.kind),
                .target = config.target,
                .debug_symbols_required = needsDarwinDebugSymbols(config),
                .pipeline = try buildCachePipelineFromConfig(alloc, config.pipeline),
            };
            installCachedManifestArtifact(alloc, snapshot_for_install) catch |err| {
                std.debug.print("Error: could not install cached artifact: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            artifact_cache_node.succeed();
            var snapshot_node = ScopedProgressNode.start(progress, compile_parent_node, "Snapshot write");
            defer snapshot_node.deinit();
            snapshot_node.updateCurrentItem(inputs.manifest_cache.?.snapshot_path, "Cache: refreshing manifest snapshot", .{});
            refreshManifestSnapshot(alloc, inputs, config, output_path, cached_path, cache_key_hex, source_selection.active_manager_source_path) catch |err| {
                std.debug.print("Error: could not refresh manifest artifact snapshot: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            snapshot_node.succeed();
            if (progress) |reporter| {
                reporter.event("[cached] {s}\n", .{output_path});
            } else {
                std.debug.print("[cached] {s}\n", .{output_path});
            }
            compile_parent_succeeded = true;
            return try makeBuildArtifact(allocator, output_path, config.kind, compile_target, config.pipeline);
        }
        if (cached_manifest_artifact_path) |cached_path| {
            artifact_cache_node.cacheMiss("artifact", cached_path);
        } else {
            artifact_cache_node.cacheMiss("artifact", output_filename);
        }
        artifact_cache_node.succeed();
    }

    driver_diag.written = 0;
    if (driver_diag.buffer.len > 0) driver_diag.buffer[0] = 0;
    var manager_object_node = ScopedProgressNode.start(progress, compile_parent_node, "Manager object");
    defer manager_object_node.deinit();
    var resolved_manager = zap.memory_driver.resolve(
        alloc,
        memory_driver_options,
        &driver_diag,
    ) catch |err| {
        std.debug.print("Error: memory manager resolution failed: {s}\n", .{@errorName(err)});
        if (driver_diag.text().len > 0) {
            std.debug.print("  {s}\n", .{driver_diag.text()});
        }
        std.process.exit(1);
    };
    defer zap.memory_driver.freeResolved(alloc, &resolved_manager);
    manager_object_node.updateCurrentItem(resolved_manager.active_manager_source_path, "Memory: building manager object", .{});
    manager_object_node.succeed();

    // P2-J1: with the gate ON, produce (or content-address-reuse) the
    // per-target concurrency kernel object now that the artifact cache
    // missed — the same fork primitive and cache discipline as the
    // manager object above.
    var resolved_concurrency_kernel: ?zap.concurrency_driver.ResolvedKernel = null;
    defer if (resolved_concurrency_kernel) |*resolved_kernel|
        zap.concurrency_driver.freeResolvedKernel(alloc, resolved_kernel);
    if (runtime_concurrency_enabled) {
        var kernel_object_node = ScopedProgressNode.start(progress, compile_parent_node, "Concurrency kernel object");
        defer kernel_object_node.deinit();
        var kernel_diag_buf: [4096]u8 = undefined;
        var kernel_diag: zap.memory_driver.DriverDiagnostic = .{ .buffer = &kernel_diag_buf };
        resolved_concurrency_kernel = zap.concurrency_driver.resolveKernelObject(
            alloc,
            concurrency_kernel_options,
            &kernel_diag,
        ) catch |err| {
            std.debug.print("Error: concurrency kernel compilation failed: {s}\n", .{@errorName(err)});
            if (kernel_diag.text().len > 0) {
                std.debug.print("  {s}\n", .{kernel_diag.text()});
            }
            std.process.exit(1);
        };
        kernel_object_node.updateCurrentItem(
            resolved_concurrency_kernel.?.object_path,
            "Concurrency: building kernel object",
            .{},
        );
        kernel_object_node.succeed();
    }

    // P3-J3: the driver-backed per-spawn manager resolver + registry accumulator
    // (docs/memory-manager-abi.md §10.5). Threaded into the frontend pipeline so
    // the spawn-manager pass resolves each `spawn(f, .{ .manager = X })` site's
    // comptime manager to a reclamation model + registry index via the SAME
    // adapter/driver path the manifest default took. Its `registrations` (the
    // DISTINCT non-manifest managers) are read AFTER the frontend to drive the
    // ZIR backend's `zap_manager_registry` generation + the runtime multi-manager
    // gate. Empty for every build with no `.manager` spawn — the zero-cost path.
    // Lives across both the frontend (resolver runs during monomorphize) and the
    // backend compile below; the resolver captures its address.
    var spawn_manager_accumulator = SpawnManagerAccumulator{
        .alloc = alloc,
        .source_roots = inputs.source_roots,
        .source_units = inputs.source_units,
        .target_name = target_name,
        .build_opts = inputs.build_opts,
        .driver_options_template = memory_driver_options,
        .manifest_backend_source_path = resolved_manager.active_manager_source_path,
    };

    // Compile through frontend
    // Use per-file pipeline for import-driven discovery, legacy pipeline for glob
    var frontend_node = ScopedProgressNode.start(progress, compile_parent_node, "Frontend compile");
    defer frontend_node.deinit();
    var result = compileProjectFrontend(alloc, inputs.source_units, .{
        .show_progress = progress != null,
        .progress = progress,
        .progress_context = "Frontend",
        .lib_mode = lib_mode,
        .frontend_optimize_mode = optimize_policy.frontend_optimize_mode,
        .struct_order = inputs.struct_order,
        .level_boundaries = inputs.level_boundaries,
        .cache_dir = ctfe_cache_dir,
        .ctfe_target = ctfe_target,
        .ctfe_optimize = @tagName(config.optimize),
        .io = global_io,
        .declared_caps = resolved_manager.declared_caps,
        .spawn_manager_resolver = spawn_manager_accumulator.resolver(),
    }) catch |err| {
        if (isUserDiagnosedCompileError(err)) {
            std.process.exit(1);
        }
        return err;
    };
    frontend_node.succeed();

    // Resolve the manifest root to an IR function ID.
    // so the ZIR backend knows which function is the entry point.
    // IR naming: struct parts joined by "_", then "__" before function name, then "__" arity.
    // For example, &Test.TestHelper.main/1 maps to Test_TestHelper__main__1.
    var entry_node = ScopedProgressNode.start(progress, compile_parent_node, "Entry resolution");
    defer entry_node.deinit();
    if (config.root) |root| {
        entry_node.updateCurrentItem(root, "Entry: resolving {s}", .{root});
        // Extract the arity suffix from the canonical root name.
        const arity_str = if (std.mem.findScalarLast(u8, root, '/')) |slash|
            root[slash + 1 ..]
        else
            "0";
        const without_arity = if (std.mem.findScalarLast(u8, root, '/')) |slash|
            root[0..slash]
        else
            root;
        // Split on last dot: struct prefix vs function name
        // "Test.TestHelper.main" -> struct="Test.TestHelper", func="main"
        var mangled: std.ArrayListUnmanaged(u8) = .empty;
        if (std.mem.findScalarLast(u8, without_arity, '.')) |last_dot| {
            const struct_part = without_arity[0..last_dot];
            const func_part = without_arity[last_dot + 1 ..];
            // Struct parts: dots become single underscores
            for (struct_part) |c| {
                try mangled.append(alloc, if (c == '.') '_' else c);
            }
            // Double underscore separator between struct and function
            try mangled.appendSlice(alloc, "__");
            try mangled.appendSlice(alloc, func_part);
            // Arity suffix
            try mangled.appendSlice(alloc, "__");
            try mangled.appendSlice(alloc, arity_str);
        } else {
            // No dot — bare function name with arity
            try mangled.appendSlice(alloc, without_arity);
            try mangled.appendSlice(alloc, "__");
            try mangled.appendSlice(alloc, arity_str);
        }
        const mangled_name = mangled.items;
        for (result.ir_program.functions) |func| {
            if (std.mem.eql(u8, func.name, mangled_name)) {
                result.ir_program.entry = func.id;
                break;
            }
        }
    }
    entry_node.succeed();

    // Map optimize mode from manifest
    const optimize_mode: u8 = optimize_policy.backend_optimize_mode;

    // Phase 0 — DWARF foundation: resolve the per-mode debug-info
    // policy ONCE here (single source of truth for the build path)
    // from `config.optimize` + the CLI `-Ddebug-info` /
    // `-Dframe-pointers` overrides already overlaid onto `config`.
    const debug_info_resolution = blk: {
        const override: ?DebugInfoOverride = if (config.debug_info) |dbg| switch (dbg) {
            .full => @as(DebugInfoOverride, .full),
            .split => @as(DebugInfoOverride, .split),
            .none => @as(DebugInfoOverride, .none),
        } else null;
        break :blk resolveDebugInfoPolicy(config.optimize, override, config.frame_pointers);
    };

    // Memory manager resolution happened above (Phase 6 needs the
    // resulting `declared_caps` before the front-end). The object path
    // and capability bitmask flow into the ZIR backend below.

    // Compile through ZIR backend (zig_lib_dir already resolved above)
    const output_mode_val: u8 = switch (config.kind) {
        .bin => 0,
        .lib => 1,
        .obj => 2,
    };
    const has_generated_executable_startup_prologue = hasGeneratedExecutableStartupPrologue(config.kind);
    var backend_node = ScopedProgressNode.start(progress, compile_parent_node, "ZIR/backend/link");
    defer backend_node.deinit();
    zir_backend.compile(alloc, result.ir_program, .{
        .zig_lib_dir = zig_lib_dir,
        .cache_dir = backend_cache_dir,
        .global_cache_dir = backend_cache_dir,
        .output_path = output_path,
        .name = output_name,
        .runtime_source = compiler.getRuntimeSourceForRuntimeControls(
            resolved_manager.declared_caps,
            resolved_manager.refcount_sized_extension,
            .{
                .memory_startup_prologue_emitted = has_generated_executable_startup_prologue,
                .collect_arc_stats = collect_arc_stats,
                // P2-J1: flips the runtime's comptime concurrency gate;
                // the kernel object below resolves the resulting
                // `zap_proc_*` extern references.
                .runtime_concurrency = runtime_concurrency_enabled,
                // P3-J3: flips the runtime's comptime per-spawn manager gate
                // (`RUNTIME_MULTI_MANAGER_DEFAULT`) when the build resolved at
                // least one NON-manifest spawn manager, arming per-process
                // `currentManagerCore` dispatch + the startup
                // `@import("zap_manager_registry")` the ZIR backend generates
                // below. OFF (no `.manager` spawn) keeps the comptime-bound
                // manifest `active_manager` direct calls — byte-identical to pre-J3.
                .multi_manager = spawn_manager_accumulator.registrations.items.len > 0,
            },
        ),
        .output_mode = output_mode_val,
        .optimize_mode = optimize_mode,
        .target = compile_target,
        // Same CPU as the manager `.o` (resolved below) so every
        // object in the final link agrees on the target machine.
        .cpu = compile_cpu,
        .analysis_context = if (result.analysis_context) |*ctx| ctx else null,
        .arc_ownership = if (result.arc_ownership) |*ownership| ownership else null,
        // Capability bitmask from the resolved manager's `.zapmem`
        // core vtable. Threaded into ZIR codegen so Phase 6 can elide
        // retain/release calls when the active manager omits
        // `REFCOUNT_V1`, and Phase 4 can branch the per-cell layout
        // on the same bit. Phase 3's only obligation is to keep the
        // wire intact end-to-end.
        .declared_caps = resolved_manager.declared_caps,
        .active_manager_source_path = resolved_manager.active_manager_source_path,
        // P3-J3: the DISTINCT non-manifest per-spawn managers (registry index
        // ≥ 1). The ZIR backend links each backend as a `zap_spawn_manager_<index>`
        // sibling module and synthesizes the `zap_manager_registry` module the
        // gated runtime imports at startup. Empty ⇒ single-manager binary
        // (nothing generated; the multi-manager gate above stays OFF).
        .spawn_managers = spawn_manager_accumulator.registrations.items,
        // P2-J1: the content-addressed kernel object spliced into the
        // link line when the concurrency gate is ON; null keeps the
        // zero-cost OFF posture.
        .concurrency_kernel_object_path = if (resolved_concurrency_kernel) |resolved_kernel|
            resolved_kernel.object_path
        else
            null,
        // P2-J2: the gate itself, threaded into ZIR emission (root-
        // process entry rerouting).
        .runtime_concurrency = runtime_concurrency_enabled,
        .progress = progress,
        // Zig 0.16 error formatting options from manifest
        .error_style = config.error_style,
        .multiline_errors = config.multiline_errors,
        // Phase 0 — DWARF foundation: force the in-binary DWARF
        // policy resolved above so Debug + ReleaseSafe keep DWARF
        // and ReleaseFast + ReleaseSmall strip it. Setting `null`
        // would fall back to the V1 ABI (Debug-only DWARF) and
        // skip the ReleaseSafe coverage Phase 0 promises.
        .debug_info_policy = debug_info_resolution.in_binary,
        // Phase 0 — DWARF foundation, Gap C: thread the per-mode
        // frame-pointer policy into the V3 ABI so Debug + ReleaseSafe
        // keep FP for stack-walking and ReleaseFast + ReleaseSmall
        // omit it for the ~1-3% win. The
        // `-Dframe-pointers=on|off` CLI flag flows through the same
        // resolution so the user override actually reaches codegen.
        .frame_pointer_policy = zir_backend.FramePointerPolicy.fromOptional(debug_info_resolution.frame_pointers),
    }) catch |err| {
        // stderr writer removed in 0.16. The error name discriminates
        // EmitFailed (Zap-side ZIR builder failures) from
        // CompilationFailed (Sema/AIR/LLVM diagnostics that already
        // printed their own message), which is genuinely useful when
        // the compile path is silently dropping diagnostics.
        std.debug.print("Error: compilation failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    backend_node.succeed();

    if (needsDarwinDebugSymbols(config)) {
        var debug_symbols_node = ScopedProgressNode.start(progress, compile_parent_node, "Debug symbols");
        defer debug_symbols_node.deinit();
        generateDarwinDebugSymbolsOrExit(alloc, config, output_path, progress);
        debug_symbols_node.succeed();
    }
    if (cached_manifest_artifact_path) |cached_path| {
        var publish_node = ScopedProgressNode.start(progress, compile_parent_node, "Artifact publish");
        defer publish_node.deinit();
        publish_node.updateCurrentItem(cached_path, "Cache: publishing content-addressed artifact", .{});
        publishManifestArtifactToCache(alloc, config, output_path, cached_path) catch |err| {
            std.debug.print("Error: could not publish manifest artifact cache entry: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        publish_node.succeed();
    }

    // Save the manifest artifact snapshot atomically for manifest
    // builds. Script builds pass no `manifest_cache`, so this shared
    // helper writes no cwd metadata for script mode.
    var snapshot_node = if (inputs.manifest_cache != null)
        ScopedProgressNode.start(progress, compile_parent_node, "Snapshot write")
    else
        ScopedProgressNode{ .progress = progress, .node = null };
    defer snapshot_node.deinit();
    if (inputs.manifest_cache) |manifest_cache| {
        snapshot_node.updateCurrentItem(manifest_cache.snapshot_path, "Cache: refreshing manifest snapshot", .{});
    }
    writeManifestCacheMetadata(alloc, inputs, config, output_path, cached_manifest_artifact_path orelse output_path, cache_key_hex, resolved_manager.active_manager_source_path) catch |err| {
        std.debug.print("Error: could not write manifest cache metadata: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    snapshot_node.succeed();

    // Return a durable copy of the output path
    const artifact = try makeBuildArtifact(allocator, output_path, config.kind, compile_target, config.pipeline);
    compile_parent_succeeded = true;
    return artifact;
}

/// P3-J3 driver-backed per-spawn manager resolver + registry accumulator
/// (`docs/memory-manager-abi.md` §10.5). Injected into the frontend pipeline as
/// a `monomorphize.SpawnManagerResolver`; the spawn-manager pass calls
/// `resolveCallback` for each `spawn(f, .{ .manager = X })` site's comptime
/// manager type. Resolution reuses the EXACT path the manifest default takes —
/// scope-graph adapter resolution (`builder.evaluateMemoryManagerAdapterFromSources`)
/// → package backend + `.zapmem` validation (`memory_driver.resolve`) →
/// `declared_caps` → `memory_elision.reclamationModel` — so the compiler never
/// hardcodes a manager name. Per-spawn managers resolve with
/// `gate_target_support = false` (unsound target×model combos stay LINKABLE; the
/// soundness check becomes a runtime spawn error). The DISTINCT non-manifest
/// managers accumulate into `registrations` (registry indices 1..; the manifest
/// default is index 0 = `zap_active_manager`), which the ZIR backend turns into
/// the linked `zap_spawn_manager_<index>` sibling modules + the
/// `zap_manager_registry` module. All allocation uses the build arena, freed
/// wholesale when `buildTarget` returns.
const SpawnManagerAccumulator = struct {
    alloc: std.mem.Allocator,
    source_roots: []const zap.discovery.SourceRoot,
    source_units: []const compiler.SourceUnit,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    driver_options_template: zap.memory_driver.ResolveOptions,
    /// The manifest default manager's resolved backend source path. A spawn site
    /// naming the SAME manager resolves to registry index 0 (no separate slot).
    manifest_backend_source_path: []const u8,

    /// Dedup cache keyed by the surface manager type name (e.g. "Memory.Arena"):
    /// a repeated spawn under the same manager returns its cached model + index
    /// without re-running the heavy adapter/driver resolution.
    resolved: std.ArrayListUnmanaged(ResolvedEntry) = .empty,
    /// The NON-manifest managers (registry index ≥ 1) the ZIR backend must link
    /// and register. Empty ⇒ a single-manager binary (the multi-manager gate
    /// stays OFF).
    registrations: std.ArrayListUnmanaged(zir_backend.SpawnManagerRegistration) = .empty,

    const ResolvedEntry = struct {
        type_name: []const u8,
        model: zap.hir.ReclamationModel,
        registry_index: u32,
    };

    /// The injected resolver view over this accumulator. Valid only while the
    /// accumulator is live (its address is captured), which spans the frontend
    /// compile that runs the spawn-manager pass.
    fn resolver(self: *SpawnManagerAccumulator) zap.monomorphize.SpawnManagerResolver {
        return .{ .context = self, .resolveFn = resolveCallback };
    }

    fn resolveCallback(
        context: *anyopaque,
        manager_type_name: []const u8,
    ) zap.monomorphize.SpawnManagerResolveError!zap.monomorphize.ResolvedSpawnManager {
        const self: *SpawnManagerAccumulator = @ptrCast(@alignCast(context));
        return self.resolveManager(manager_type_name);
    }

    fn resolveManager(
        self: *SpawnManagerAccumulator,
        manager_type_name: []const u8,
    ) zap.monomorphize.SpawnManagerResolveError!zap.monomorphize.ResolvedSpawnManager {
        // Dedup: a manager seen at a prior spawn site is resolved exactly once.
        for (self.resolved.items) |entry| {
            if (std.mem.eql(u8, entry.type_name, manager_type_name)) {
                return .{ .model = entry.model, .registry_index = entry.registry_index };
            }
        }

        // Scope-graph adapter resolution: the manager type name → its declaring
        // `impl Memory.Manager for X` source file (the adapter source path). This
        // is the SAME resolver the manifest default uses, so nothing is hardcoded.
        const adapter_eval = zap.builder.evaluateMemoryManagerAdapterFromSources(
            self.alloc,
            self.source_roots,
            self.source_units,
            .{ .type_name = manager_type_name, .adapter_source_path = null },
            self.target_name,
            self.build_opts,
        ) catch |err| {
            std.debug.print(
                "Error: could not resolve adapter for per-spawn memory manager '{s}': {s}\n",
                .{ manager_type_name, @errorName(err) },
            );
            return error.ManagerResolutionFailed;
        };
        const adapter = adapter_eval.manager orelse {
            std.debug.print(
                "Error: per-spawn memory manager '{s}' does not implement Memory.Manager\n",
                .{manager_type_name},
            );
            return error.ManagerResolutionFailed;
        };
        const adapter_source_path = adapter.adapter_source_path orelse {
            std.debug.print(
                "Error: per-spawn memory manager '{s}' has no resolvable adapter source path\n",
                .{manager_type_name},
            );
            return error.ManagerResolutionFailed;
        };

        // Package backend + `.zapmem` validation → declared_caps. The unsound
        // target×model gate is disabled here (§10.5): the backend stays linkable
        // and a bad combo faults only if a process actually spawns it.
        var driver_diag_buffer: [4096]u8 = undefined;
        var driver_diag: zap.memory_driver.DriverDiagnostic = .{ .buffer = &driver_diag_buffer };
        var options = self.driver_options_template;
        options.adapter = .{ .type_name = adapter.type_name, .adapter_source_path = adapter_source_path };
        options.gate_target_support = false;

        const resolved_manager = zap.memory_driver.resolve(self.alloc, options, &driver_diag) catch |err| {
            std.debug.print(
                "Error: per-spawn memory manager '{s}' resolution failed: {s}\n  {s}\n",
                .{ manager_type_name, @errorName(err), driver_diag.text() },
            );
            return error.ManagerResolutionFailed;
        };

        const model = zap.memory_elision.reclamationModel(resolved_manager.declared_caps);

        // Registry index assignment: the manifest default is slot 0 (already
        // linked as `zap_active_manager`); every DISTINCT non-manifest manager
        // gets the next dense slot (1..) and a registration for the ZIR backend.
        const registry_index: u32 = blk: {
            if (std.mem.eql(u8, resolved_manager.active_manager_source_path, self.manifest_backend_source_path)) {
                break :blk 0;
            }
            const new_index: u32 = @intCast(self.registrations.items.len + 1);
            const backend_path_copy = self.alloc.dupe(u8, resolved_manager.active_manager_source_path) catch return error.OutOfMemory;
            self.registrations.append(self.alloc, .{
                .index = new_index,
                .backend_source_path = backend_path_copy,
            }) catch return error.OutOfMemory;
            break :blk new_index;
        };

        const type_name_copy = self.alloc.dupe(u8, manager_type_name) catch return error.OutOfMemory;
        self.resolved.append(self.alloc, .{
            .type_name = type_name_copy,
            .model = model,
            .registry_index = registry_index,
        }) catch return error.OutOfMemory;

        return .{ .model = model, .registry_index = registry_index };
    }
};

/// Deep-copy a spawn-manager registration slice into `allocator` (each
/// `backend_source_path` too), so it can outlive the build arena that produced
/// it — used to persist a rebuild's discovered set on the incremental state and
/// to hand it off across a context recreation.
fn dupeSpawnManagerRegistrations(
    allocator: std.mem.Allocator,
    registrations: []const zir_backend.SpawnManagerRegistration,
) ![]const zir_backend.SpawnManagerRegistration {
    if (registrations.len == 0) return &.{};
    const out = try allocator.alloc(zir_backend.SpawnManagerRegistration, registrations.len);
    errdefer allocator.free(out);
    var filled: usize = 0;
    errdefer for (out[0..filled]) |registration| allocator.free(registration.backend_source_path);
    for (registrations, 0..) |registration, index| {
        out[index] = .{
            .index = registration.index,
            .backend_source_path = try allocator.dupe(u8, registration.backend_source_path),
        };
        filled = index + 1;
    }
    return out;
}

/// Free a spawn-manager registration slice previously produced by
/// `dupeSpawnManagerRegistrations`. Safe on the empty slice.
fn freeSpawnManagerRegistrations(
    allocator: std.mem.Allocator,
    registrations: []const zir_backend.SpawnManagerRegistration,
) void {
    if (registrations.len == 0) return;
    for (registrations) |registration| allocator.free(registration.backend_source_path);
    allocator.free(registrations);
}

/// Whether two spawn-manager registration sets are identical (same registry
/// indices bound to the same backend source paths, in order). The resolver
/// assigns indices deterministically, so a stable set compares equal across
/// rebuilds; a differing set means the persistent context (pinned to its
/// manager family at creation) must be rebuilt.
fn spawnManagerRegistrationsEqual(
    a: []const zir_backend.SpawnManagerRegistration,
    b: []const zir_backend.SpawnManagerRegistration,
) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.index != right.index) return false;
        if (!std.mem.eql(u8, left.backend_source_path, right.backend_source_path)) return false;
    }
    return true;
}

fn compileProjectFrontend(
    alloc: std.mem.Allocator,
    source_units: []const compiler.SourceUnit,
    options: compiler.CompileOptions,
) !compiler.CompileResult {
    var ctx = try compiler.collectAllFromUnits(alloc, source_units, options);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(alloc);
    try compiler.appendStructCompileOrderNames(alloc, &names, options.struct_order, ctx.struct_programs);

    return try compiler.compileStructByStruct(alloc, &ctx, names.items, options);
}

/// Translate the per-build accumulated `zap.discovery.SourceRoot` slice
/// into the `zap.memory_driver.SourceRoot` shape used by the Memory
/// Manager ABI driver. The driver lives one module-level deeper than
/// `discovery.zig` to keep dependency direction clean, so it can't
/// import discovery's struct directly.
fn sourceRootsForMemoryDriver(
    alloc: std.mem.Allocator,
    discovery_roots: []const zap.discovery.SourceRoot,
) ![]const zap.memory_driver.SourceRoot {
    const out = try alloc.alloc(zap.memory_driver.SourceRoot, discovery_roots.len);
    for (discovery_roots, 0..) |root, i| {
        out[i] = .{ .name = root.name, .path = root.path };
    }
    return out;
}

fn refreshManifestSnapshot(
    alloc: std.mem.Allocator,
    inputs: CompileAndLinkInputs,
    config: zap.builder.BuildConfig,
    output_path: []const u8,
    cached_artifact_path: []const u8,
    cache_key_hex: []const u8,
    active_manager_source_path: []const u8,
) !void {
    const manifest_cache = inputs.manifest_cache orelse return;

    var files: std.ArrayListUnmanaged(build_cache.FileFingerprint) = .empty;
    var directories: std.ArrayListUnmanaged(build_cache.DirectoryFingerprint) = .empty;
    var env_vars: std.ArrayListUnmanaged(build_cache.EnvFingerprint) = .empty;
    var globs: std.ArrayListUnmanaged(build_cache.GlobFingerprint) = .empty;

    try appendFileFingerprint(alloc, &files, manifest_cache.build_file_path);
    for (inputs.source_units) |source_unit| {
        try appendFileFingerprint(alloc, &files, source_unit.file_path);
    }
    try appendFileFingerprint(alloc, &files, active_manager_source_path);
    // P2-J1: a gated-on artifact links the concurrency kernel object, so
    // the snapshot fast path must MISS when any kernel source changes —
    // fingerprint every `.zig` file of the kernel unit, exactly as the
    // manager backend source is fingerprinted above. Gate OFF adds
    // nothing (the artifact contains no kernel code).
    if (config.runtime_concurrency) {
        const zap_source_tree_root: []const u8 = if (inputs.zap_lib_dir) |lib_dir|
            (std.fs.path.dirname(lib_dir) orelse inputs.project_root)
        else
            inputs.project_root;
        const kernel_source_dir = try std.fs.path.join(
            alloc,
            &.{ zap_source_tree_root, zap.concurrency_driver.KERNEL_UNIT_RELATIVE_DIR },
        );
        try appendKernelSourceFingerprints(alloc, &files, kernel_source_dir);
    }

    try appendDirectoryFingerprint(alloc, &directories, inputs.project_root, false);
    for ([_][]const u8{ "lib", "test", "tools" }) |relative_root| {
        const path = try std.fs.path.join(alloc, &.{ inputs.project_root, relative_root });
        try appendDirectoryFingerprint(alloc, &directories, path, true);
    }
    for (inputs.source_roots) |source_root| {
        const recursive = !std.mem.eql(u8, source_root.path, inputs.project_root);
        try appendDirectoryFingerprint(alloc, &directories, source_root.path, recursive);
    }
    for (config.paths) |pattern| {
        const base = try globBaseDirectory(alloc, inputs.project_root, pattern);
        try appendDirectoryFingerprint(alloc, &directories, base, true);
    }

    for (manifest_cache.dependencies) |dependency| {
        switch (dependency) {
            .file => |file| {
                if (file.content_hash == 0) {
                    try appendAbsentFileFingerprint(alloc, &files, file.path);
                } else {
                    try appendFileFingerprint(alloc, &files, file.path);
                }
            },
            .env_var => |env_var| {
                try appendManifestEnvFingerprint(
                    alloc,
                    &env_vars,
                    env_var.name,
                    env_var.present,
                    env_var.value_hash,
                );
            },
            .glob => |glob_dep| {
                try appendManifestGlobFingerprint(
                    alloc,
                    &globs,
                    glob_dep.pattern,
                    glob_dep.result_hash,
                );
            },
            .reflected_struct, .reflected_source => {
                // Build-manifest reflection is conservatively covered
                // by the explicit source file fingerprints and the
                // source-root directory fingerprints above. If any file
                // or relevant listing that can change the reflected
                // graph changes, validation misses before CTFE is
                // skipped.
            },
        }
    }

    const snapshot: build_cache.Snapshot = .{
        .invocation_identity = manifest_cache.invocation_identity,
        .cache_key_hex = cache_key_hex,
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = buildCacheKindFromConfig(config.kind),
        .target = config.target,
        .debug_symbols_required = needsDarwinDebugSymbols(config),
        .pipeline = try buildCachePipelineFromConfig(alloc, config.pipeline),
        .files = files.items,
        .directories = directories.items,
        .env_vars = env_vars.items,
        .globs = globs.items,
    };
    try build_cache.writeSnapshotAtomic(alloc, manifest_cache.snapshot_path, snapshot);
}

fn appendFileFingerprint(
    alloc: std.mem.Allocator,
    files: *std.ArrayListUnmanaged(build_cache.FileFingerprint),
    path: []const u8,
) !void {
    for (files.items) |existing| {
        if (std.mem.eql(u8, existing.path, path)) return;
    }
    const fingerprint = try build_cache.fileFingerprint(alloc, path);
    errdefer alloc.free(fingerprint.path);
    try files.append(alloc, fingerprint);
}

/// P2-J1: fingerprint every `.zig` source of the concurrency kernel
/// unit (recursively, deterministic order) into a gated-on manifest
/// snapshot. A missing/unreadable kernel unit is a hard error here —
/// the build that just linked its object proved the unit readable, so
/// failure means the tree mutated mid-build.
fn appendKernelSourceFingerprints(
    alloc: std.mem.Allocator,
    files: *std.ArrayListUnmanaged(build_cache.FileFingerprint),
    kernel_source_dir: []const u8,
) !void {
    var relative_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(global_io, kernel_source_dir, .{ .iterate = true });
    defer dir.close(global_io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(global_io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try relative_paths.append(alloc, try alloc.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, relative_paths.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    for (relative_paths.items) |relative_path| {
        const full_path = try std.fs.path.join(alloc, &.{ kernel_source_dir, relative_path });
        try appendFileFingerprint(alloc, files, full_path);
    }
}

fn appendAbsentFileFingerprint(
    alloc: std.mem.Allocator,
    files: *std.ArrayListUnmanaged(build_cache.FileFingerprint),
    path: []const u8,
) !void {
    for (files.items) |existing| {
        if (std.mem.eql(u8, existing.path, path)) return;
    }
    const fingerprint: build_cache.FileFingerprint = .{
        .path = try alloc.dupe(u8, path),
        .present = false,
        .content_digest = [_]u8{0} ** @sizeOf(build_cache.FileDigest),
        .size = 0,
        .inode = 0,
        .mtime_nanos = 0,
        .ctime_nanos = 0,
    };
    errdefer alloc.free(fingerprint.path);
    try files.append(alloc, fingerprint);
}

fn appendDirectoryFingerprint(
    alloc: std.mem.Allocator,
    directories: *std.ArrayListUnmanaged(build_cache.DirectoryFingerprint),
    path: []const u8,
    recursive: bool,
) !void {
    for (directories.items) |existing| {
        if (existing.recursive == recursive and std.mem.eql(u8, existing.path, path)) return;
    }
    const fingerprint = try build_cache.directoryFingerprint(alloc, path, recursive);
    errdefer alloc.free(fingerprint.path);
    try directories.append(alloc, fingerprint);
}

fn appendManifestEnvFingerprint(
    alloc: std.mem.Allocator,
    env_vars: *std.ArrayListUnmanaged(build_cache.EnvFingerprint),
    name: []const u8,
    present: bool,
    value_hash: u64,
) !void {
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    try env_vars.append(alloc, .{
        .name = owned_name,
        .present = present,
        .value_hash = value_hash,
    });
}

fn appendManifestGlobFingerprint(
    alloc: std.mem.Allocator,
    globs: *std.ArrayListUnmanaged(build_cache.GlobFingerprint),
    pattern: []const u8,
    result_hash: u64,
) !void {
    const owned_pattern = try alloc.dupe(u8, pattern);
    errdefer alloc.free(owned_pattern);
    try globs.append(alloc, .{
        .pattern = owned_pattern,
        .result_hash = result_hash,
    });
}

fn globBaseDirectory(
    alloc: std.mem.Allocator,
    project_root: []const u8,
    pattern: []const u8,
) ![]const u8 {
    var base_end: usize = 0;
    for (pattern, 0..) |c, index| {
        if (c == '*' or c == '?') break;
        if (c == '/') base_end = index + 1;
    }
    const base_rel = if (base_end > 0) pattern[0..base_end] else ".";
    if (std.fs.path.isAbsolute(base_rel)) return alloc.dupe(u8, base_rel);
    if (std.mem.eql(u8, base_rel, ".")) return alloc.dupe(u8, project_root);
    return std.fs.path.join(alloc, &.{ project_root, base_rel });
}

fn collectMemoryAdapterSourceUnits(
    alloc: std.mem.Allocator,
    source_roots: []const zap.discovery.SourceRoot,
) ![]const compiler.SourceUnit {
    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer source_files.deinit(alloc);
    var transferred_source_file_count: usize = 0;
    errdefer {
        for (source_files.items[transferred_source_file_count..]) |file_path| {
            alloc.free(file_path);
        }
    }

    var discovered = std.StringHashMap(void).init(alloc);
    defer deinitOwnedPathSet(alloc, &discovered);
    for (source_roots) |root| {
        if (!sourceRootShouldScanRecursively(root)) continue;
        try scanZapFilesRecursive(alloc, root.path, &source_files, &discovered);
    }

    var units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    errdefer {
        for (units.items) |unit| {
            alloc.free(unit.file_path);
            alloc.free(unit.source);
        }
        units.deinit(alloc);
    }
    for (source_files.items, 0..) |file_path, index| {
        const source = try std.Io.Dir.cwd().readFileAlloc(global_io, file_path, alloc, .limited(10 * 1024 * 1024));
        errdefer alloc.free(source);
        try units.append(alloc, .{
            .file_path = file_path,
            .source = source,
        });
        transferred_source_file_count = index + 1;
    }
    return try units.toOwnedSlice(alloc);
}

const BUILD_CACHE_DIGEST_LEN: usize = @sizeOf(build_cache.CacheDigest);
const BuildCacheDigest = build_cache.CacheDigest;

fn digestHexAlloc(alloc: std.mem.Allocator, digest: BuildCacheDigest) ![]const u8 {
    var hex_buf: [BUILD_CACHE_DIGEST_LEN * 2]u8 = undefined;
    for (digest, 0..) |byte, index| {
        hex_buf[index * 2] = std.fmt.digitToChar(byte >> 4, .lower);
        hex_buf[index * 2 + 1] = std.fmt.digitToChar(byte & 0xf, .lower);
    }
    return try alloc.dupe(u8, &hex_buf);
}

fn zeroBuildCacheDigest() BuildCacheDigest {
    return [_]u8{0} ** @sizeOf(BuildCacheDigest);
}

fn testBuildCacheDigest(byte: u8) BuildCacheDigest {
    return [_]u8{byte} ** @sizeOf(BuildCacheDigest);
}

/// Compute a build cache key using the full SHA-256 digest. Artifact
/// directories are named with the 64-character lower-hex encoding of this
/// digest, matching Zig's collision-resistant object-cache model.
const BuildCacheOptions = struct {
    manifest_result_hash: u64,
    active_manager_source_digest: BuildCacheDigest = zeroBuildCacheDigest(),
    /// Identity digest of the running compiler binary. Manifest artifact
    /// cache hits can skip memory-manager validation, so compiler,
    /// runtime, ABI, and backend changes must force a rebuild.
    compiler_identity_digest: BuildCacheDigest = zeroBuildCacheDigest(),
    /// Identity digest of the resolved Zig lib directory. The path alone
    /// is not enough: an override can mutate contents in place.
    zig_lib_identity_digest: BuildCacheDigest = zeroBuildCacheDigest(),
    collect_arc_stats: bool = false,
    /// The post-override build controls. Folding all four into the key
    /// means flipping ANY `-D` flag (or a manifest change to one)
    /// invalidates the artifact — the exact contract Phase 5's
    /// content-addressed script skip-recompile relies on. Defaults
    /// keep the key stable for a plain unflagged build.
    optimize: zap.builder.BuildConfig.Optimize = .debug,
    /// Stable identity of the selected frontend pass policy. This is folded
    /// separately from `optimize` so future policy changes under the same
    /// backend optimize mode cannot reuse stale artifacts.
    frontend_policy_tag: u64 = compiler.FrontendOptimizeMode.debug.cacheTag(),
    /// Selected memory manager type name ("" when none — never happens
    /// for a real build, but keeps the unit-testable struct total).
    memory_manager_name: []const u8 = "",
    /// Cross target triple ("" ⇒ native) and CPU ("" ⇒ default CPU).
    target: []const u8 = "",
    cpu: []const u8 = "",
    /// Phase 0 — DWARF foundation: encoded `-Ddebug-info=` override
    /// (0 = unset / mode default, 1 = full, 2 = split, 3 = none) so a
    /// flag flip invalidates the artifact. Without this, a Debug
    /// build with `-Ddebug-info=none` would cache-hit an earlier
    /// Debug build that kept full DWARF — silently producing the
    /// wrong artifact for the requested policy.
    debug_info_tag: u8 = 0,
    /// Phase 0 — DWARF foundation, Gap C: encoded `-Dframe-pointers=`
    /// override (0 = unset / mode default, 1 = on, 2 = off). Same
    /// rationale as `debug_info_tag` — flipping the FP flag must
    /// produce a different artifact, not a stale cache hit on a
    /// binary whose prologue does not match the request.
    frame_pointers_tag: u8 = 0,
    /// P2-J1: the resolved `runtime_concurrency` gate. Flipping the
    /// gate changes the emitted runtime (marker rewrite) and the link
    /// line (kernel object present/absent), so it must produce a
    /// different artifact, never a stale cache hit.
    runtime_concurrency: bool = false,
    /// P2-J1: content-address key of the concurrency kernel object
    /// (`concurrency_driver.kernelCacheKeyHex`) when the gate is ON,
    /// "" when OFF. Folding it means editing any kernel source under
    /// `src/runtime/concurrency/` invalidates cached gated-on binaries
    /// even when the compiler binary itself is unchanged.
    concurrency_kernel_key: []const u8 = "",

    const Section = extern struct {
        magic: u32,
        version: u16,
        runtime_flags: u16,
    };

    const MAGIC: u32 = 0x5a_43_4b_31; // "ZCK1"
    const VERSION: u16 = 1;
    const ARC_STATS_FLAG: u16 = 0x0001;

    /// Magic + version for the build-control sub-section so a future
    /// change to what is folded in is self-describing in the stream.
    const CONTROL_MAGIC: u32 = 0x5a_42_43_31; // "ZBC1"
    /// Increment when the artifact cache correctness contract changes. Version
    /// 6 folds the Phase 0 debug-info and frame-pointer override tags
    /// into artifact identity. Version 7 (Phase 0 Gap E) flips the
    /// ReleaseFast / ReleaseSmall *default* policy resolution to
    /// the split-debug shape (compile with DWARF, sibling `.dSYM`,
    /// post-link strip): the optimize tag is the same byte, the
    /// `debug_info_tag` for the unflagged build is still 0, but the
    /// resolved binary content (stripped vs. embedded DWARF, sibling
    /// present vs. absent) changes — so a version bump invalidates
    /// every pre-Gap-E ReleaseFast / Small artifact that would
    /// otherwise satisfy a cache hit with a fresh request that now
    /// expects the new shape. Version 8 (P2-J1) folds the
    /// `runtime_concurrency` gate and the concurrency kernel object
    /// key into artifact identity.
    const CONTROL_VERSION: u16 = 8;

    fn runtimeFlags(self: BuildCacheOptions) u16 {
        var flags: u16 = 0;
        if (self.collect_arc_stats) flags |= ARC_STATS_FLAG;
        return flags;
    }

    fn updateHasher(self: BuildCacheOptions, hasher: *std.crypto.hash.sha2.Sha256) void {
        hasher.update(std.mem.asBytes(&self.manifest_result_hash));
        hasher.update(&self.active_manager_source_digest);
        hasher.update(&self.compiler_identity_digest);
        hasher.update(&self.zig_lib_identity_digest);

        // Build-control sub-section — ALWAYS folded in so the optimize
        // mode, frontend policy, memory manager, cross target, and cpu
        // are part of every cache key (no early-out can skip these).
        const control_magic = CONTROL_MAGIC;
        const control_version = CONTROL_VERSION;
        hasher.update(std.mem.asBytes(&control_magic));
        hasher.update(std.mem.asBytes(&control_version));
        const optimize_tag: u8 = @intFromEnum(self.optimize);
        hasher.update(std.mem.asBytes(&optimize_tag));
        hasher.update(std.mem.asBytes(&self.frontend_policy_tag));
        // Length-prefix each string so "ab"+"c" can't collide with
        // "a"+"bc".
        for ([_][]const u8{ self.memory_manager_name, self.target, self.cpu }) |s| {
            const len: u64 = s.len;
            hasher.update(std.mem.asBytes(&len));
            hasher.update(s);
        }
        // Phase 0 — DWARF foundation: fold the debug-info and
        // frame-pointer override tags. Both are tri-state bytes
        // (0 = mode default, 1+ = explicit override) so flipping a
        // `-Ddebug-info=` or `-Dframe-pointers=` flag invalidates
        // the artifact instead of cache-hitting a binary whose
        // policy does not match the request.
        hasher.update(std.mem.asBytes(&self.debug_info_tag));
        hasher.update(std.mem.asBytes(&self.frame_pointers_tag));
        // P2-J1: fold the concurrency gate and the kernel-object key
        // (length-prefixed, "" when the gate is OFF).
        const concurrency_gate_byte: u8 = if (self.runtime_concurrency) 1 else 0;
        hasher.update(std.mem.asBytes(&concurrency_gate_byte));
        const kernel_key_len: u64 = self.concurrency_kernel_key.len;
        hasher.update(std.mem.asBytes(&kernel_key_len));
        hasher.update(self.concurrency_kernel_key);

        const runtime_flags = self.runtimeFlags();
        if (runtime_flags == 0) return;

        const section = Section{
            .magic = MAGIC,
            .version = VERSION,
            .runtime_flags = runtime_flags,
        };
        hasher.update(std.mem.asBytes(&section));
    }
};

fn hashActiveManagerSource(alloc: std.mem.Allocator, source_path: []const u8) !BuildCacheDigest {
    const source = try std.Io.Dir.cwd().readFileAlloc(global_io, source_path, alloc, .limited(10 * 1024 * 1024));
    defer alloc.free(source);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashUpdateLenPrefixed(&hasher, source_path);
    hashUpdateLenPrefixed(&hasher, source);
    return hasher.finalResult();
}

fn computeBuildCacheKey(
    alloc: std.mem.Allocator,
    build_source: []const u8,
    source_units: []const compiler.SourceUnit,
    target_name: []const u8,
    options: BuildCacheOptions,
) !BuildCacheDigest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashUpdateLenPrefixed(&hasher, build_source);
    // Hash each source file individually. Every variable-width field is
    // length-prefixed so adjacent path/source bytes cannot collide by
    // shifting a boundary.
    const sorted_units = try alloc.dupe(compiler.SourceUnit, source_units);
    defer alloc.free(sorted_units);
    std.mem.sort(compiler.SourceUnit, sorted_units, {}, struct {
        fn lessThan(_: void, left: compiler.SourceUnit, right: compiler.SourceUnit) bool {
            const path_order = std.mem.order(u8, left.file_path, right.file_path);
            if (path_order != .eq) return path_order == .lt;
            return std.mem.lessThan(u8, left.source, right.source);
        }
    }.lessThan);
    for (sorted_units) |unit| {
        hashUpdateLenPrefixed(&hasher, unit.file_path);
        hashUpdateLenPrefixed(&hasher, unit.source);
    }
    hashUpdateLenPrefixed(&hasher, target_name);
    options.updateHasher(&hasher);
    return hasher.finalResult();
}

// ---------------------------------------------------------------------------
// Phase 5: content-addressed script skip-recompile key
//
// The script artifact directory's previously-random component is
// replaced by a strong content key so an UNCHANGED script re-runs with
// NO recompilation and NOTHING written next to it. The key MUST fold in
// every input that can change the emitted binary; anything omitted
// would risk a stale-binary false hit. It deliberately reuses the SAME
// full-SHA-256 construction as `computeBuildCacheKey` /
// `BuildCacheOptions.updateHasher` so the script and manifest paths
// agree on cache-key semantics (a flipped `-D` flag invalidates both).
//
// Inputs (each length-prefixed so "ab"+"c" can't collide with
// "a"+"bc"):
//   * the resolved script source bytes,
//   * a stdlib IDENTITY hash — the resolved stdlib dir path plus the
//     path+content of every `.zap` file beneath it (so two different
//     stdlibs, even byte-identical ones at different paths, never
//     false-hit each other),
//   * a compiler IDENTITY hash — the running executable's own bytes
//     (rebuild the Zap compiler ⇒ new key ⇒ no stale-binary reuse;
//     this is the content-addressed tool-identity approach used by
//     hermetic build systems, robust without a hand-maintained
//     version string),
//   * the post-override optimize mode, frontend policy tag,
//     memory-manager type name, cross target triple, and cpu string
//     (read off the synthetic `BuildConfig` AFTER `applyBuildOverrides`,
//     the single source of truth — exactly the controls
//     `computeBuildCacheKey` folds in).
// ---------------------------------------------------------------------------

const SCRIPT_CONTENT_KEY_MAGIC: u32 = 0x5a_53_43_31; // "ZSC1"
/// Bumped to v3 with Phase 0 (Gap C): the script content key now folds
/// the `-Ddebug-info=` and `-Dframe-pointers=` CLI overrides so a
/// flag flip on the same source invalidates the cached artifact.
/// Earlier v2 keys were policy-blind and would silently cache-hit
/// the wrong prologue or DWARF policy.
/// Bumped to v4 with P2-J1: the key now folds the
/// `runtime_concurrency` gate and the concurrency kernel object key so
/// a `-Druntime-concurrency=` flip (or a kernel-source edit under a
/// gated-on script) invalidates the cached artifact.
const SCRIPT_CONTENT_KEY_VERSION: u16 = 4;

fn hashUpdateLenPrefixed(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    const len: u64 = bytes.len;
    hasher.update(std.mem.asBytes(&len));
    hasher.update(bytes);
}

fn stdlibIdentityError(err: anyerror) error{ OutOfMemory, StdlibUnreadable } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.StdlibUnreadable,
    };
}

/// Stable IDENTITY hash of the resolved Zap stdlib at `stdlib_dir`:
/// the absolute directory path plus every `.zap` file's path and
/// contents, folded in a deterministic (sorted) order. Two stdlibs
/// with different contents — OR identical contents at a different
/// path — produce different hashes, so a `--zap-lib-dir`/`ZAP_LIB_DIR`
/// switch can never false-hit a cached binary built against another
/// stdlib. Returns a hard error on any IO failure (a silent 0 would
/// collapse distinct stdlibs into one key — a correctness hole, never
/// acceptable here).
fn hashStdlibIdentity(alloc: std.mem.Allocator, stdlib_dir: []const u8) !BuildCacheDigest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const magic = SCRIPT_CONTENT_KEY_MAGIC;
    const version = SCRIPT_CONTENT_KEY_VERSION;
    hasher.update(std.mem.asBytes(&magic));
    hasher.update(std.mem.asBytes(&version));

    // The resolved directory IS part of identity (path-sensitive on
    // purpose): same contents at a different path is still a distinct
    // stdlib for caching.
    const abs_dir = try std.fs.path.resolve(alloc, &.{stdlib_dir});
    defer alloc.free(abs_dir);
    hashUpdateLenPrefixed(&hasher, abs_dir);

    // Collect every `.zap` path beneath the stdlib root, sort for a
    // filesystem-order-independent digest, then fold path+contents.
    var dir = std.Io.Dir.cwd().openDir(global_io, stdlib_dir, .{ .iterate = true }) catch |err|
        return stdlibIdentityError(err);
    defer dir.close(global_io);

    var rel_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (rel_paths.items) |p| alloc.free(p);
        rel_paths.deinit(alloc);
    }
    {
        var walker = try std.Io.Dir.walk(dir, alloc);
        defer walker.deinit();
        while (walker.next(global_io) catch |err| return stdlibIdentityError(err)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zap")) continue;
            const rel_path = try alloc.dupe(u8, entry.path);
            errdefer alloc.free(rel_path);
            try rel_paths.append(alloc, rel_path);
        }
    }
    std.mem.sort([]const u8, rel_paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var file_count: u64 = rel_paths.items.len;
    hasher.update(std.mem.asBytes(&file_count));
    for (rel_paths.items) |rel| {
        hashUpdateLenPrefixed(&hasher, rel);
        const contents = dir.readFileAlloc(global_io, rel, alloc, .limited(16 * 1024 * 1024)) catch |err|
            return stdlibIdentityError(err);
        defer alloc.free(contents);
        hashUpdateLenPrefixed(&hasher, contents);
    }

    return hasher.finalResult();
}

/// Stable IDENTITY hash of the resolved Zig lib directory. The first
/// run records sorted path/stat/content-hash entries in a persistent
/// toolchain manifest; unchanged later runs validate path/listing/stat
/// metadata and reuse the recorded per-file content hashes instead of
/// rereading the entire Zig lib.
fn hashZigLibIdentity(
    alloc: std.mem.Allocator,
    cache_dir: []const u8,
    zig_lib_dir: []const u8,
) build_cache.ToolchainIdentityError!BuildCacheDigest {
    return build_cache.zigLibIdentityDigest(alloc, cache_dir, zig_lib_dir, null);
}

/// Content-addressed IDENTITY hash of the running Zap compiler: a
/// digest of the executable's own bytes. Rebuilding the compiler (any
/// codegen/runtime/stdlib-embed change) yields a different binary and
/// therefore a different key, so a script is correctly recompiled
/// against the new compiler instead of reusing a stale artifact. This
/// is the hermetic-build-system tool-identity approach (content over a
/// brittle hand-maintained version string). A hard error on failure —
/// silently dropping compiler identity from the key would risk a
/// stale-binary false hit across compiler versions.
fn hashCompilerIdentity(
    alloc: std.mem.Allocator,
    cache_dir: []const u8,
) build_cache.ToolchainIdentityError!BuildCacheDigest {
    return build_cache.compilerIdentityDigest(alloc, cache_dir, null);
}

/// The post-override build controls folded into the script content
/// key. Read off the synthetic `BuildConfig` AFTER
/// `applyBuildOverrides` so the CLI `-D` flags are reflected — these
/// are exactly the controls `computeBuildCacheKey`/`BuildCacheOptions`
/// fold in for the manifest path, kept in lockstep so the two paths'
/// cache semantics never drift.
const ScriptContentKeyControls = struct {
    optimize: zap.builder.BuildConfig.Optimize,
    frontend_policy_tag: u64 = compiler.FrontendOptimizeMode.debug.cacheTag(),
    memory_manager_name: []const u8,
    target: []const u8,
    cpu: []const u8,
    /// Phase 0 — DWARF foundation: encoded `-Ddebug-info=` override
    /// (0 = unset / mode default, 1 = full, 2 = split, 3 = none).
    /// Mirror of `BuildCacheOptions.debug_info_tag` so the script
    /// and manifest caches agree on the policy contract.
    debug_info_tag: u8 = 0,
    /// Phase 0 — DWARF foundation, Gap C: encoded `-Dframe-pointers=`
    /// override (0 = unset / mode default, 1 = on, 2 = off). Mirror
    /// of `BuildCacheOptions.frame_pointers_tag`.
    frame_pointers_tag: u8 = 0,
    /// P2-J1: the resolved `runtime_concurrency` gate. Mirror of
    /// `BuildCacheOptions.runtime_concurrency` — flipping
    /// `-Druntime-concurrency=` on the same script must produce a
    /// distinct artifact (different runtime rewrite + link line).
    runtime_concurrency: bool = false,
    /// P2-J1: content-address key of the concurrency kernel object
    /// when the gate is ON, "" when OFF. Mirror of
    /// `BuildCacheOptions.concurrency_kernel_key` — editing a kernel
    /// source under `src/runtime/concurrency/` must invalidate cached
    /// gated-on script artifacts (the stdlib identity hash covers only
    /// `.zap` files, and the compiler identity covers only the
    /// executable's own bytes).
    concurrency_kernel_key: []const u8 = "",
};

/// Resolve the opt-out concurrency default. Concurrency is ON unless you opt
/// out: when neither the manifest nor `-Druntime-concurrency=` set the gate
/// (`runtime_concurrency_explicit == false`), it resolves to whether the target
/// can host the kernel — ON for fiber-capable arch + supported OS
/// (aarch64/x86_64 on macOS/Linux), silently OFF elsewhere (single-threaded
/// wasm, unported OSes). An EXPLICIT setting is left untouched, so an explicit
/// `true` on an unsupported target still reaches `validateKernelTargetSupport`
/// and errors loudly. Must run after the target override has landed.
fn resolveConcurrencyGate(config: *zap.builder.BuildConfig) void {
    if (!config.runtime_concurrency_explicit) {
        config.runtime_concurrency = zap.concurrency_driver.kernelTargetSupported(config.target);
    }
}

/// P6-J6: `runtime_tracing` instruments the concurrency kernel, so it is
/// meaningless — and a likely misconfiguration — without the concurrency
/// runtime. Fail the build with an actionable diagnostic rather than
/// silently ignoring the flag. Runs after ALL overrides land, so it sees
/// the final resolved (manifest + `-D`) pair on every build path
/// (manifest, script, and watch).
fn validateRuntimeTracingGate(config: zap.builder.BuildConfig) void {
    if (config.runtime_tracing and !config.runtime_concurrency) {
        std.debug.print(
            "Error: runtime_tracing requires the concurrency runtime. " ++
                "Set `runtime_concurrency: true` in the Zap.Manifest (or -Druntime-concurrency=on) " ++
                "alongside `runtime_tracing: true` (or -Druntime-tracing=on).\n",
            .{},
        );
        std.process.exit(1);
    }
}

/// P2-J1: resolve the concurrency-kernel content key for a script-mode
/// content key: "" when the gate is OFF; otherwise the same
/// `kernelCacheKeyHex` the compile tail folds into the manifest cache
/// key, computed over `<dirname(zap_lib)>/src/runtime/concurrency`.
/// Exits with a diagnostic on failure (a gated-on script whose kernel
/// unit cannot be read cannot build either). Allocated in `alloc`.
fn scriptConcurrencyKernelKey(
    alloc: std.mem.Allocator,
    config: zap.builder.BuildConfig,
    zap_lib: []const u8,
    zig_lib_dir: []const u8,
    compiler_identity_digest: BuildCacheDigest,
    zig_lib_identity_digest: BuildCacheDigest,
    driver_optimize: zap.memory_driver.ZapForkOptimize,
) []const u8 {
    validateRuntimeTracingGate(config);
    if (!config.runtime_concurrency) return "";
    const zap_source_root = std.fs.path.dirname(zap_lib) orelse ".";
    const kernel_source_dir = std.fs.path.join(
        alloc,
        &.{ zap_source_root, zap.concurrency_driver.KERNEL_UNIT_RELATIVE_DIR },
    ) catch {
        std.debug.print("Error: out of memory resolving the concurrency kernel source directory\n", .{});
        std.process.exit(1);
    };
    var kernel_diag_buf: [4096]u8 = undefined;
    var kernel_diag: zap.memory_driver.DriverDiagnostic = .{ .buffer = &kernel_diag_buf };
    const key = zap.concurrency_driver.kernelCacheKeyHex(alloc, .{
        .kernel_source_dir = kernel_source_dir,
        // Key computation reads sources only; the object cache dir is
        // resolved later by the shared compile tail.
        .cache_dir = "",
        .zig_lib_dir = zig_lib_dir,
        .compiler_identity_digest = compiler_identity_digest,
        .zig_lib_identity_digest = zig_lib_identity_digest,
        .optimize = driver_optimize,
        .target = config.target,
        .cpu = config.cpu,
        .runtime_tracing = config.runtime_tracing,
    }, &kernel_diag) catch |err| {
        std.debug.print("Error: concurrency kernel resolution failed: {s}\n", .{@errorName(err)});
        if (kernel_diag.text().len > 0) {
            std.debug.print("  {s}\n", .{kernel_diag.text()});
        }
        std.process.exit(1);
    };
    return alloc.dupe(u8, &key) catch {
        std.debug.print("Error: out of memory computing the concurrency kernel key\n", .{});
        std.process.exit(1);
    };
}

/// Compute the hex content key for a script. Same full-SHA-256
/// construction as `computeBuildCacheKey` so the script and manifest
/// caches share key semantics. The result names the artifact directory
/// `<cache root>/zap/scripts/<key>`. Allocated in `alloc`.
fn computeScriptContentKey(
    alloc: std.mem.Allocator,
    script_source: []const u8,
    stdlib_identity_digest: BuildCacheDigest,
    compiler_identity_digest: BuildCacheDigest,
    zig_lib_identity_digest: BuildCacheDigest,
    controls: ScriptContentKeyControls,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const magic = SCRIPT_CONTENT_KEY_MAGIC;
    const version = SCRIPT_CONTENT_KEY_VERSION;
    hasher.update(std.mem.asBytes(&magic));
    hasher.update(std.mem.asBytes(&version));

    hashUpdateLenPrefixed(&hasher, script_source);
    hasher.update(&stdlib_identity_digest);
    hasher.update(&compiler_identity_digest);
    hasher.update(&zig_lib_identity_digest);

    const optimize_tag: u8 = @intFromEnum(controls.optimize);
    hasher.update(std.mem.asBytes(&optimize_tag));
    hasher.update(std.mem.asBytes(&controls.frontend_policy_tag));
    hashUpdateLenPrefixed(&hasher, controls.memory_manager_name);
    hashUpdateLenPrefixed(&hasher, controls.target);
    hashUpdateLenPrefixed(&hasher, controls.cpu);
    // Phase 0 — DWARF foundation: fold the debug-info and frame-
    // pointer override tags so flipping either flag produces a
    // distinct cache key.
    hasher.update(std.mem.asBytes(&controls.debug_info_tag));
    hasher.update(std.mem.asBytes(&controls.frame_pointers_tag));
    // P2-J1: fold the concurrency gate + kernel-object key (mirror of
    // `BuildCacheOptions.updateHasher`).
    const concurrency_gate_byte: u8 = if (controls.runtime_concurrency) 1 else 0;
    hasher.update(std.mem.asBytes(&concurrency_gate_byte));
    hashUpdateLenPrefixed(&hasher, controls.concurrency_kernel_key);

    return digestHexAlloc(alloc, hasher.finalResult());
}

// ---------------------------------------------------------------------------
// Watch mode
// ---------------------------------------------------------------------------

fn freeOwnedPathSlice(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn deinitDiscoveredWatchPaths(allocator: std.mem.Allocator, discovered: *std.StringHashMap(void)) void {
    var iter = discovered.iterator();
    while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
    discovered.deinit();
}

fn appendWatchPathWithOwnedKey(
    allocator: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]const u8),
    discovered: *std.StringHashMap(void),
    path: []const u8,
    key: []const u8,
) !void {
    if (discovered.contains(key)) {
        allocator.free(key);
        return;
    }
    var key_inserted = false;
    errdefer if (!key_inserted) allocator.free(key);
    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    discovered.put(key, {}) catch |err| {
        return err;
    };
    key_inserted = true;
    errdefer {
        _ = discovered.remove(key);
        allocator.free(key);
    }
    try paths.append(allocator, path_copy);
}

fn appendWatchPath(
    allocator: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]const u8),
    discovered: *std.StringHashMap(void),
    path: []const u8,
) !void {
    const key = try canonicalPathAlloc(allocator, path);
    try appendWatchPathWithOwnedKey(allocator, paths, discovered, path, key);
}

fn appendWatchPathAllowMissingFile(
    allocator: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]const u8),
    discovered: *std.StringHashMap(void),
    path: []const u8,
) !void {
    const key = canonicalPathAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, path),
        else => return err,
    };
    try appendWatchPathWithOwnedKey(allocator, paths, discovered, path, key);
}

fn collectWatchEntriesRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    paths: *std.ArrayListUnmanaged([]const u8),
    discovered: *std.StringHashMap(void),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(global_io, dir_path, .{ .iterate = true });
    defer dir.close(global_io);
    try collectWatchEntriesFromOpenDir(allocator, dir_path, dir, paths, discovered);
}

fn collectOptionalProjectWatchEntriesRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    paths: *std.ArrayListUnmanaged([]const u8),
    discovered: *std.StringHashMap(void),
) !void {
    var dir = std.Io.Dir.cwd().openDir(global_io, dir_path, .{ .iterate = true }) catch |err| {
        if (optionalSourceRootSkipReason(err) != null) return;
        return err;
    };
    defer dir.close(global_io);
    try collectWatchEntriesFromOpenDir(allocator, dir_path, dir, paths, discovered);
}

fn collectWatchEntriesFromOpenDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    dir: std.Io.Dir,
    paths: *std.ArrayListUnmanaged([]const u8),
    discovered: *std.StringHashMap(void),
) !void {
    try appendWatchPath(allocator, paths, discovered, dir_path);

    var walker = try std.Io.Dir.walk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(global_io)) |entry| {
        if (entry.basename.len > 0 and entry.basename[0] == '.') {
            if (entry.kind == .directory) walker.leave(global_io);
            continue;
        }

        switch (entry.kind) {
            .directory => {
                const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
                defer allocator.free(full_path);
                try appendWatchPath(allocator, paths, discovered, full_path);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.basename, ".zap")) continue;
                const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
                defer allocator.free(full_path);
                try appendWatchPath(allocator, paths, discovered, full_path);
            },
            else => {},
        }
    }
}

const WatchSnapshotSetupError = InteractiveWatchSetupError;

const WatchSnapshotInitError = WatchSnapshotSetupError || error{
    WatchManifestMissing,
};

const WatchSnapshotFallbackReason = enum {
    missing_manifest,
};

const WatchSnapshotInitFailureAction = union(enum) {
    use_project_only: WatchSnapshotFallbackReason,
    propagate_setup_error: WatchSnapshotSetupError,
};

fn watchSnapshotSetupErrorOrStatus(err: anyerror, status: WatchSnapshotSetupError) WatchSnapshotSetupError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => status,
    };
}

fn watchSnapshotBuildManifestReadError(err: anyerror) WatchSnapshotInitError {
    return switch (err) {
        error.FileNotFound => error.WatchManifestMissing,
        else => watchSnapshotSetupErrorOrStatus(err, error.ReadError),
    };
}

fn classifyWatchSnapshotInitFailure(err: WatchSnapshotInitError) WatchSnapshotInitFailureAction {
    return switch (err) {
        error.WatchManifestMissing => .{ .use_project_only = .missing_manifest },
        else => |setup_err| .{ .propagate_setup_error = setup_err },
    };
}

fn refreshWatchSnapshotInitError(err: WatchSnapshotInitError) WatchSnapshotSetupError {
    return switch (classifyWatchSnapshotInitFailure(err)) {
        .use_project_only => error.ReadError,
        .propagate_setup_error => |setup_err| setup_err,
    };
}

fn collectProjectWatchPathsWithoutManifest(
    allocator: std.mem.Allocator,
    project_root: []const u8,
) WatchSnapshotSetupError![]const []const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var discovered = std.StringHashMap(void).init(allocator);
    defer deinitDiscoveredWatchPaths(allocator, &discovered);

    const build_zap_path = try std.fs.path.join(allocator, &.{ project_root, "build.zap" });
    defer allocator.free(build_zap_path);
    appendWatchPathAllowMissingFile(allocator, &paths, &discovered, build_zap_path) catch |err|
        return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);

    for ([_][]const u8{ "lib", "test", "tools" }) |dir_name| {
        const dir_path = try std.fs.path.join(allocator, &.{ project_root, dir_name });
        defer allocator.free(dir_path);
        collectOptionalProjectWatchEntriesRecursive(allocator, dir_path, &paths, &discovered) catch |err|
            return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);
    }

    return try paths.toOwnedSlice(allocator);
}

/// Collect watch inputs from the same manifest source roots used by the
/// build itself. Directories are included alongside `.zap` files so
/// additions and deletions in nested source roots are observed by the
/// polling watcher.
fn collectWatchPaths(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    zap_lib_dir_override: ?[]const u8,
    extra_watch_path: ?[]const u8,
) WatchSnapshotInitError![]const []const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const build_zap_path = try std.fs.path.join(alloc, &.{ project_root, "build.zap" });
    const build_source = std.Io.Dir.cwd().readFileAlloc(global_io, build_zap_path, alloc, .limited(10 * 1024 * 1024)) catch |err|
        return watchSnapshotBuildManifestReadError(err);
    const zap_lib_dir = resolveZapLibDir(alloc, zap_lib_dir_override, project_root) catch |err|
        return watchSnapshotSetupErrorOrStatus(err, error.ToolchainError);
    const manifest_eval = zap.builder.ctfeManifestDetailed(alloc, build_source, target_name, build_overrides.target, build_opts, zap_lib_dir) catch |err|
        return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);
    var config = manifest_eval.config;
    applyBuildOverrides(&config, build_overrides);
    const source_roots = resolveManifestSourceRoots(alloc, project_root, config, zap_lib_dir, .{
        .write_lockfile = true,
        .print_local_overrides = false,
    }) catch |err| return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var discovered = std.StringHashMap(void).init(allocator);
    defer deinitDiscoveredWatchPaths(allocator, &discovered);
    appendWatchPath(allocator, &paths, &discovered, build_zap_path) catch |err|
        return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);
    for (source_roots) |root| {
        collectWatchEntriesRecursive(allocator, root.path, &paths, &discovered) catch |err|
            return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);
    }
    if (extra_watch_path) |path| {
        appendWatchPath(allocator, &paths, &discovered, path) catch |err|
            return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);
    }
    return try paths.toOwnedSlice(allocator);
}

fn collectWatchPathsFromSourceRoots(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    source_roots: []const zap.discovery.SourceRoot,
    extra_watch_path: ?[]const u8,
) WatchSnapshotSetupError![]const []const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var discovered = std.StringHashMap(void).init(allocator);
    defer deinitDiscoveredWatchPaths(allocator, &discovered);

    const build_zap_path = try std.fs.path.join(allocator, &.{ project_root, "build.zap" });
    defer allocator.free(build_zap_path);
    appendWatchPath(allocator, &paths, &discovered, build_zap_path) catch |err|
        return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);
    for (source_roots) |root| {
        collectWatchEntriesRecursive(allocator, root.path, &paths, &discovered) catch |err|
            return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);
    }
    if (extra_watch_path) |path| {
        appendWatchPath(allocator, &paths, &discovered, path) catch |err|
            return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);
    }
    return try paths.toOwnedSlice(allocator);
}

test "collectWatchEntriesRecursive propagates missing required root" {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var discovered = std.StringHashMap(void).init(std.testing.allocator);
    defer deinitDiscoveredWatchPaths(std.testing.allocator, &discovered);

    try std.testing.expectError(
        error.FileNotFound,
        collectWatchEntriesRecursive(
            std.testing.allocator,
            "missing-required-watch-root",
            &paths,
            &discovered,
        ),
    );
}

/// Recursively collect all .zap files under a directory using the
/// std.Io.Dir.Walker API (Zig 0.16) for efficient selective tree traversal.
/// Skips hidden directories (starting with '.') and non-.zap files.
/// Recursively walk `dir_path` and append every `.zap` file (except
/// `build.zap`) that isn't already in `discovered`. Used to surface
/// stdlib files in nested directories — including protocol/impl files
/// that have no struct declaration and therefore aren't reachable
/// through the import-driven file graph.
fn scanZapFilesRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    results: *std.ArrayListUnmanaged([]const u8),
    discovered: *std.StringHashMap(void),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(global_io, dir_path, .{ .iterate = true });
    defer dir.close(global_io);
    var walker = try std.Io.Dir.walk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(global_io)) |entry| {
        if (entry.basename.len > 0 and entry.basename[0] == '.') {
            if (entry.kind == .directory) walker.leave(global_io);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zap")) continue;
        if (std.mem.eql(u8, entry.basename, "build.zap")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        _ = try appendUniqueOwnedSourcePath(allocator, results, discovered, full_path);
    }
}

/// Get the mtime of a file as an Io.Timestamp, or null if the file cannot be stat'd.
/// Uses Zig 0.16's std.Io.Timestamp for portable, resolution-aware time comparison.
fn getFileMtime(path: []const u8) ?std.Io.Timestamp {
    const file_stat = std.Io.Dir.cwd().statFile(global_io, path, .{}) catch return null;
    return file_stat.mtime;
}

const WatchRunMode = enum {
    none,
    program,
    tests,
};

fn cloneOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |some| try allocator.dupe(u8, some) else null;
}

fn cloneStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, values.len);
    var cloned_count: usize = 0;
    errdefer {
        for (cloned[0..cloned_count]) |value| allocator.free(value);
        allocator.free(cloned);
    }
    for (values, 0..) |value, index| {
        cloned[index] = try allocator.dupe(u8, value);
        cloned_count += 1;
    }
    return cloned;
}

fn cloneBuildConfigDeps(
    allocator: std.mem.Allocator,
    deps: []const zap.builder.BuildConfig.Dep,
) ![]const zap.builder.BuildConfig.Dep {
    const cloned = try allocator.alloc(zap.builder.BuildConfig.Dep, deps.len);
    for (deps, 0..) |dep, index| {
        cloned[index] = .{
            .name = try allocator.dupe(u8, dep.name),
            .source = switch (dep.source) {
                .path => |path| .{ .path = try allocator.dupe(u8, path) },
                .git => |git| .{ .git = .{
                    .url = try allocator.dupe(u8, git.url),
                    .tag = try cloneOptionalString(allocator, git.tag),
                    .branch = try cloneOptionalString(allocator, git.branch),
                    .rev = try cloneOptionalString(allocator, git.rev),
                } },
            },
            .local_override = try cloneOptionalString(allocator, dep.local_override),
        };
    }
    return cloned;
}

fn cloneBuildConfigBuildOpts(
    allocator: std.mem.Allocator,
    build_opts: std.StringHashMapUnmanaged([]const u8),
) !std.StringHashMapUnmanaged([]const u8) {
    var cloned: std.StringHashMapUnmanaged([]const u8) = .empty;
    try cloned.ensureUnusedCapacity(allocator, @intCast(build_opts.count()));
    var iter = build_opts.iterator();
    while (iter.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const value = try allocator.dupe(u8, entry.value_ptr.*);
        cloned.putAssumeCapacity(key, value);
    }
    return cloned;
}

fn cloneBuildConfigDocGroups(
    allocator: std.mem.Allocator,
    doc_groups: []const zap.builder.BuildConfig.DocGroup,
) ![]const zap.builder.BuildConfig.DocGroup {
    const cloned = try allocator.alloc(zap.builder.BuildConfig.DocGroup, doc_groups.len);
    for (doc_groups, 0..) |group, index| {
        cloned[index] = .{
            .name = try allocator.dupe(u8, group.name),
            .pages = try cloneStringSlice(allocator, group.pages),
        };
    }
    return cloned;
}

fn cloneBuildPipeline(
    allocator: std.mem.Allocator,
    pipeline: zap.builder.BuildConfig.Pipeline,
) !zap.builder.BuildConfig.Pipeline {
    const steps = try allocator.alloc(zap.builder.BuildConfig.Step, pipeline.steps.len);
    var initialized_count: usize = 0;
    errdefer {
        for (steps[0..initialized_count]) |step| {
            switch (step) {
                .compile => {},
                .run => |run_step| {
                    for (run_step.args) |arg| allocator.free(arg);
                    allocator.free(run_step.args);
                },
            }
        }
        allocator.free(steps);
    }

    for (pipeline.steps, 0..) |step, index| {
        steps[index] = switch (step) {
            .compile => .{ .compile = .{} },
            .run => |run_step| .{ .run = .{
                .args = try cloneStringSlice(allocator, run_step.args),
                .forward_args = run_step.forward_args,
            } },
        };
        initialized_count += 1;
    }
    return .{ .steps = steps };
}

fn cloneOptionalBuildPipeline(
    allocator: std.mem.Allocator,
    pipeline: ?zap.builder.BuildConfig.Pipeline,
) !?zap.builder.BuildConfig.Pipeline {
    return if (pipeline) |some| try cloneBuildPipeline(allocator, some) else null;
}

fn freeBuildPipeline(
    allocator: std.mem.Allocator,
    pipeline: zap.builder.BuildConfig.Pipeline,
) void {
    for (pipeline.steps) |step| {
        switch (step) {
            .compile => {},
            .run => |run_step| {
                for (run_step.args) |arg| allocator.free(arg);
                allocator.free(run_step.args);
            },
        }
    }
    allocator.free(pipeline.steps);
}

fn cloneBuildConfig(
    allocator: std.mem.Allocator,
    config: zap.builder.BuildConfig,
) !zap.builder.BuildConfig {
    return .{
        .name = try allocator.dupe(u8, config.name),
        .version = try allocator.dupe(u8, config.version),
        .kind = config.kind,
        .root = try cloneOptionalString(allocator, config.root),
        .asset_name = try cloneOptionalString(allocator, config.asset_name),
        .optimize = config.optimize,
        .debug_info = config.debug_info,
        .frame_pointers = config.frame_pointers,
        .target = try cloneOptionalString(allocator, config.target),
        .cpu = try cloneOptionalString(allocator, config.cpu),
        .paths = try cloneStringSlice(allocator, config.paths),
        .deps = try cloneBuildConfigDeps(allocator, config.deps),
        .build_opts = try cloneBuildConfigBuildOpts(allocator, config.build_opts),
        .memory_manager = if (config.memory_manager) |manager| .{
            .type_name = try allocator.dupe(u8, manager.type_name),
            .adapter_source_path = try cloneOptionalString(allocator, manager.adapter_source_path),
        } else null,
        .runtime_concurrency = config.runtime_concurrency,
        .test_timeout = config.test_timeout,
        .error_style = try cloneOptionalString(allocator, config.error_style),
        .multiline_errors = config.multiline_errors,
        .source_url = try cloneOptionalString(allocator, config.source_url),
        .landing_page = try cloneOptionalString(allocator, config.landing_page),
        .doc_groups = try cloneBuildConfigDocGroups(allocator, config.doc_groups),
        .pipeline = try cloneOptionalBuildPipeline(allocator, config.pipeline),
    };
}

fn cloneSourceRoots(
    allocator: std.mem.Allocator,
    roots: []const zap.discovery.SourceRoot,
) ![]const zap.discovery.SourceRoot {
    const cloned = try allocator.alloc(zap.discovery.SourceRoot, roots.len);
    for (roots, 0..) |root, index| {
        cloned[index] = .{
            .name = try allocator.dupe(u8, root.name),
            .path = try allocator.dupe(u8, root.path),
        };
    }
    return cloned;
}

fn cloneCtDependencies(
    allocator: std.mem.Allocator,
    dependencies: []const zap.ctfe.CtDependency,
) ![]const zap.ctfe.CtDependency {
    const cloned = try allocator.alloc(zap.ctfe.CtDependency, dependencies.len);
    for (dependencies, 0..) |dependency, index| {
        cloned[index] = switch (dependency) {
            .file => |file| .{ .file = .{
                .path = try allocator.dupe(u8, file.path),
                .content_hash = file.content_hash,
            } },
            .env_var => |env_var| .{ .env_var = .{
                .name = try allocator.dupe(u8, env_var.name),
                .value_hash = env_var.value_hash,
                .present = env_var.present,
            } },
            .glob => |glob| .{ .glob = .{
                .pattern = try allocator.dupe(u8, glob.pattern),
                .result_hash = glob.result_hash,
            } },
            .reflected_struct => |reflected_struct| .{ .reflected_struct = .{
                .struct_name = try allocator.dupe(u8, reflected_struct.struct_name),
                .interface_hash = reflected_struct.interface_hash,
            } },
            .reflected_source => |reflected_source| .{ .reflected_source = .{
                .paths = try cloneStringSlice(allocator, reflected_source.paths),
                .graph_hash = reflected_source.graph_hash,
            } },
        };
    }
    return cloned;
}

const PinnedManifestState = struct {
    arena: std.heap.ArenaAllocator,
    config: zap.builder.BuildConfig,
    build_source: []const u8,
    dependencies: []const zap.ctfe.CtDependency,
    result_hash: u64,
    source_roots: []const zap.discovery.SourceRoot,
    zap_lib_dir: ?[]const u8,
};

fn clonePinnedManifestState(
    allocator: std.mem.Allocator,
    config: zap.builder.BuildConfig,
    build_source: []const u8,
    dependencies: []const zap.ctfe.CtDependency,
    result_hash: u64,
    source_roots: []const zap.discovery.SourceRoot,
    zap_lib_dir: ?[]const u8,
) !PinnedManifestState {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    return .{
        .arena = arena,
        .config = try cloneBuildConfig(arena_allocator, config),
        .build_source = try arena_allocator.dupe(u8, build_source),
        .dependencies = try cloneCtDependencies(arena_allocator, dependencies),
        .result_hash = result_hash,
        .source_roots = try cloneSourceRoots(arena_allocator, source_roots),
        .zap_lib_dir = try cloneOptionalString(arena_allocator, zap_lib_dir),
    };
}

const IncrementalInitError = build_cache.ToolchainIdentityError || error{
    ReadError,
    ManifestError,
    ToolchainError,
    MemoryManagerError,
    BackendError,
    OutOfMemory,
};

const IncrementalError = error{
    ReadError,
    ManifestError,
    DiscoveryError,
    FrontendError,
    ContextInvalidated,
    BackendContextInvalidated,
    IncrementalError,
    BackendError,
    CacheMetadataError,
    OutOfMemory,
    /// P3-J3: `rebuild`'s resolver-wired frontend discovered a per-spawn manager
    /// set (docs/memory-manager-abi.md §10.5) that differs from the one the
    /// persistent context was created with. The context bakes in the manager
    /// family (sibling modules + `zap_manager_registry` + `multi_manager`
    /// runtime rewrite), so it must be recreated bound to the discovered set —
    /// `establishIncrementalWatchState` retries with `discovered_spawn_managers`.
    /// Never produced by a single-manager build (the resolver is never called).
    SpawnManagerSetChanged,
};

const InteractiveWatchSetupError = IncrementalInitError || IncrementalError;

const InteractiveWatchSetupFailureDisposition = enum {
    retry_after_change,
    fail_command,
};

const InteractiveWatchRebuildFailureAction = enum {
    wait_for_next_change,
    rebuild_fresh_context,
};

fn incrementalInitErrorOrStatus(err: anyerror, status: IncrementalInitError) IncrementalInitError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => status,
    };
}

fn incrementalErrorOrStatus(err: anyerror, status: IncrementalError) IncrementalError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => status,
    };
}

fn incrementalBackendErrorOrStatus(err: anyerror, status: IncrementalError) IncrementalError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PreparedUpdateAbortFailed => error.BackendContextInvalidated,
        else => status,
    };
}

fn incrementalToolchainIdentityError(err: build_cache.ToolchainIdentityError) IncrementalInitError {
    return err;
}

fn classifyInteractiveWatchSetupFailure(
    err: InteractiveWatchSetupError,
) InteractiveWatchSetupFailureDisposition {
    return switch (err) {
        error.FrontendError,
        error.ContextInvalidated,
        error.SpawnManagerSetChanged,
        error.ReadError,
        error.ManifestError,
        error.DiscoveryError,
        => .retry_after_change,

        error.OutOfMemory,
        error.ToolchainError,
        error.ZigLibCanonicalizationFailed,
        error.ZigLibIdentityManifestReadFailed,
        error.ZigLibIdentityManifestStatUnavailable,
        error.ZigLibIdentityManifestWriteFailed,
        error.ZigLibDirectoryOpenFailed,
        error.ZigLibDirectoryWalkFailed,
        error.ZigLibFileStatUnavailable,
        error.ZigLibFileOpenFailed,
        error.ZigLibFileHashUnavailable,
        error.CompilerExecutablePathUnavailable,
        error.CompilerExecutableCanonicalizationFailed,
        error.CompilerIdentityManifestReadFailed,
        error.CompilerIdentityManifestStatUnavailable,
        error.CompilerIdentityManifestWriteFailed,
        error.CompilerFileStatUnavailable,
        error.CompilerFileNotRegular,
        error.CompilerFileHashUnavailable,
        error.ToolchainIdentityFileTooLarge,
        error.MemoryManagerError,
        error.BackendError,
        error.BackendContextInvalidated,
        error.IncrementalError,
        error.CacheMetadataError,
        => .fail_command,
    };
}

fn failInteractiveWatchSetupOnSevereError(err: InteractiveWatchSetupError) InteractiveWatchSetupError!void {
    switch (classifyInteractiveWatchSetupFailure(err)) {
        .retry_after_change => {},
        .fail_command => return err,
    }
}

fn classifyInteractiveWatchRebuildFailure(
    err: IncrementalError,
) InteractiveWatchSetupError!InteractiveWatchRebuildFailureAction {
    if (err == error.BackendContextInvalidated) {
        return .rebuild_fresh_context;
    }

    switch (classifyInteractiveWatchSetupFailure(err)) {
        .retry_after_change => {},
        .fail_command => return err,
    }

    return switch (err) {
        error.ContextInvalidated => .rebuild_fresh_context,
        // P3-J3: a spawn-manager set change requires a fresh context bound to the
        // new manager family (the retry inside `establishIncrementalWatchState`
        // supplies the discovered set on recreation).
        error.SpawnManagerSetChanged => .rebuild_fresh_context,
        else => .wait_for_next_change,
    };
}

fn resolveIncrementalZigLibDir(alloc: std.mem.Allocator) IncrementalInitError![]const u8 {
    return resolveZigLibDir(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ToolchainError,
    };
}

test "incremental watch error classifiers preserve OOM and status buckets" {
    try std.testing.expectEqual(
        @as(IncrementalInitError, error.OutOfMemory),
        incrementalInitErrorOrStatus(error.OutOfMemory, error.ToolchainError),
    );
    try std.testing.expectEqual(
        @as(IncrementalInitError, error.ToolchainError),
        incrementalInitErrorOrStatus(error.FileNotFound, error.ToolchainError),
    );
    try std.testing.expectEqual(
        @as(IncrementalError, error.OutOfMemory),
        incrementalErrorOrStatus(error.OutOfMemory, error.CacheMetadataError),
    );
    try std.testing.expectEqual(
        @as(IncrementalError, error.CacheMetadataError),
        incrementalErrorOrStatus(error.AccessDenied, error.CacheMetadataError),
    );
    try std.testing.expectEqual(
        @as(IncrementalError, error.ContextInvalidated),
        incrementalErrorOrStatus(error.FileNotFound, error.ContextInvalidated),
    );
    try std.testing.expectEqual(
        @as(IncrementalError, error.BackendError),
        incrementalErrorOrStatus(error.CompilationFailed, error.BackendError),
    );
    try std.testing.expectEqual(
        @as(IncrementalError, error.BackendContextInvalidated),
        incrementalBackendErrorOrStatus(error.PreparedUpdateAbortFailed, error.BackendError),
    );
    try std.testing.expectEqual(
        @as(IncrementalError, error.BackendError),
        incrementalBackendErrorOrStatus(error.CompilationFailed, error.BackendError),
    );
    try std.testing.expectEqual(
        @as(IncrementalError, error.OutOfMemory),
        incrementalBackendErrorOrStatus(error.OutOfMemory, error.BackendError),
    );
    try std.testing.expectEqual(
        @as(IncrementalInitError, error.CompilerFileStatUnavailable),
        incrementalToolchainIdentityError(error.CompilerFileStatUnavailable),
    );
    try std.testing.expectEqual(
        @as(IncrementalInitError, error.ZigLibCanonicalizationFailed),
        incrementalToolchainIdentityError(error.ZigLibCanonicalizationFailed),
    );
}

test "interactive watch setup classification fails severe infrastructure errors" {
    const severe_errors = [_]InteractiveWatchSetupError{
        error.OutOfMemory,
        error.BackendError,
        error.IncrementalError,
        error.CacheMetadataError,
        error.ToolchainError,
        error.BackendContextInvalidated,
        error.ZigLibCanonicalizationFailed,
        error.ZigLibIdentityManifestReadFailed,
        error.ZigLibIdentityManifestStatUnavailable,
        error.ZigLibIdentityManifestWriteFailed,
        error.ZigLibDirectoryOpenFailed,
        error.ZigLibDirectoryWalkFailed,
        error.ZigLibFileStatUnavailable,
        error.ZigLibFileOpenFailed,
        error.ZigLibFileHashUnavailable,
        error.CompilerExecutablePathUnavailable,
        error.CompilerExecutableCanonicalizationFailed,
        error.CompilerIdentityManifestReadFailed,
        error.CompilerIdentityManifestStatUnavailable,
        error.CompilerIdentityManifestWriteFailed,
        error.CompilerFileStatUnavailable,
        error.CompilerFileNotRegular,
        error.CompilerFileHashUnavailable,
        error.ToolchainIdentityFileTooLarge,
        error.MemoryManagerError,
    };

    for (severe_errors) |err| {
        try std.testing.expectEqual(
            InteractiveWatchSetupFailureDisposition.fail_command,
            classifyInteractiveWatchSetupFailure(err),
        );
        try std.testing.expectError(err, failInteractiveWatchSetupOnSevereError(err));
    }
}

test "interactive watch setup classification retries user-editable input failures" {
    const retryable_errors = [_]InteractiveWatchSetupError{
        error.ReadError,
        error.ManifestError,
        error.DiscoveryError,
        error.FrontendError,
        error.ContextInvalidated,
    };

    for (retryable_errors) |err| {
        try std.testing.expectEqual(
            InteractiveWatchSetupFailureDisposition.retry_after_change,
            classifyInteractiveWatchSetupFailure(err),
        );
        try failInteractiveWatchSetupOnSevereError(err);
    }
}

test "interactive watch rebuild classification fails severe infrastructure errors" {
    const severe_errors = [_]IncrementalError{
        error.OutOfMemory,
        error.BackendError,
        error.IncrementalError,
        error.CacheMetadataError,
    };

    for (severe_errors) |err| {
        try std.testing.expectError(
            err,
            classifyInteractiveWatchRebuildFailure(err),
        );
    }
}

test "interactive watch rebuild classification preserves retry actions" {
    const wait_for_next_change_errors = [_]IncrementalError{
        error.ReadError,
        error.ManifestError,
        error.DiscoveryError,
        error.FrontendError,
    };

    for (wait_for_next_change_errors) |err| {
        try std.testing.expectEqual(
            InteractiveWatchRebuildFailureAction.wait_for_next_change,
            try classifyInteractiveWatchRebuildFailure(err),
        );
    }

    try std.testing.expectEqual(
        InteractiveWatchRebuildFailureAction.rebuild_fresh_context,
        try classifyInteractiveWatchRebuildFailure(error.ContextInvalidated),
    );
    try std.testing.expectEqual(
        InteractiveWatchRebuildFailureAction.rebuild_fresh_context,
        try classifyInteractiveWatchRebuildFailure(error.BackendContextInvalidated),
    );
}

test "incremental watch init propagates allocator OOM" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.OutOfMemory,
        IncrementalWatchState.init(
            failing_allocator.allocator(),
            ".",
            "default",
            .empty,
            .{},
            false,
            null,
            null,
            &.{},
        ),
    );
}

/// Persistent state for incremental watch-mode compilation.
///
/// Holds a Zig ZirContext that persists across rebuilds so the Zig compiler's
/// incremental Sema can diff prev_zir vs new_zir and only re-analyze changed
/// code. The frontend (parse→IR) is re-run fully on each change, but the
/// expensive backend (Sema→codegen→link) is incremental.
///
/// Watch-mode pins the active memory manager for the lifetime of the
/// watch session: `init` resolves the manager once, caches its
/// `declared_caps` bitmask in `declared_caps`, and threads that value
/// into every subsequent `rebuild`. The cache mirrors the spec's
/// single-manager-per-binary invariant — a watch session does NOT
/// re-resolve between rebuilds, even if the user edits `build.zap`'s
/// `memory:` field. Editing `memory:` requires bouncing the watcher,
/// which `watchAndRebuild` already does by tearing down the
/// IncrementalWatchState on `build.zap` change.
const IncrementalWatchState = struct {
    zir_ctx: *zir_builder.ZirContext,
    /// Duped backend compile options that outlive buildTarget's arena.
    zig_lib_dir: []const u8,
    output_path: []const u8,
    output_name: []const u8,
    output_mode: u8,
    optimize_mode: u8,
    frontend_optimize_mode: compiler.FrontendOptimizeMode,
    kind: zap.builder.BuildConfig.Kind,
    target: ?[]const u8,
    lib_mode: bool,
    has_generated_executable_startup_prologue: bool,
    collect_arc_stats: bool,
    link_libc: bool,
    compiler_identity_digest: BuildCacheDigest,
    zig_lib_identity_digest: BuildCacheDigest,
    allocator: std.mem.Allocator,
    /// Pinned manifest/config data. `rebuildManifestDaemonState` tears this
    /// state down when `build.zap` changes, so ordinary source edits can reuse
    /// the evaluated manifest without rerunning manifest CTFE.
    manifest_arena: std.heap.ArenaAllocator,
    manifest_config: zap.builder.BuildConfig,
    manifest_build_source: []const u8,
    manifest_dependencies: []const zap.ctfe.CtDependency,
    manifest_result_hash: u64,
    manifest_source_roots: []const zap.discovery.SourceRoot,
    manifest_zap_lib_dir: ?[]const u8,
    /// Whether the context has had at least one successful inject+update.
    baseline_established: bool = false,
    /// Persistent Zap frontend cache. Owns parsed AST and final
    /// expanded/desugared per-struct AST across daemon rebuilds.
    frontend_state: compiler.FrontendIncrementalState,
    /// Hash of source graph shape: ordered source files, primary struct mapping,
    /// and dependency levels. A change means selective in-place update cannot
    /// prove module identity stability and must rebuild a fresh context.
    source_topology_hash: u64 = 0,
    /// Last successful emitted-root hash.
    root_module_hash: u64 = 0,
    root_module_hash_present: bool = false,
    /// Last successful per-Zap-struct emitted module hashes. Keys are owned by
    /// `allocator`.
    module_hashes: std.StringHashMap(u64),
    /// Hash of the Zap-level Memory.Manager adapter evaluation that selected
    /// the active backend. A change invalidates the persistent Zig context
    /// because runtime source, capabilities, and backend imports are pinned
    /// when the context is created.
    memory_adapter_result_hash: u64,
    /// Resolved memory manager's capability bitmask. Cached in `init`
    /// from `zap.memory_driver.resolve` and threaded into every
    /// `compileProjectFrontend` / `injectAndUpdate` call so Phase 6
    /// codegen elision uses the same bitmask the initial backend
    /// context was created with. The cache means a watch session
    /// services every rebuild against the same capability surface
    /// without re-resolving the manager — the manifest's `memory:`
    /// field is pinned for the lifetime of the watcher (see
    /// `watchAndRebuild` for the teardown-on-build.zap-change flow).
    declared_caps: u64,
    /// Validated REFCOUNT_V1 v1.1 sized-extension availability.
    refcount_sized_extension: bool,
    /// Resolved active manager backend source path. Owned by `allocator`;
    /// freed in `deinit`.
    active_manager_source_path: []const u8,
    /// Content identity of `active_manager_source_path` at context creation.
    /// The manager object and generated runtime are pinned to this source; a
    /// later content change requires rebuilding the persistent Zig context.
    active_manager_source_digest: BuildCacheDigest,
    /// P2-J1: the resolved `runtime_concurrency` gate, pinned for the
    /// watch session exactly like the memory manager (the kernel object
    /// and rewritten runtime were baked into the persistent Zig context
    /// at `init`; a manifest gate flip tears the session down through
    /// the same build.zap-change flow).
    runtime_concurrency: bool,
    /// P2-J1: content-address key of the pinned kernel object ("" when
    /// the gate is OFF). Owned by `allocator`; freed in `deinit`. Folded
    /// into the rebuild metadata cache key so gated-on watch artifacts
    /// are keyed to the exact kernel sources they linked.
    concurrency_kernel_key: []const u8,
    /// P3-J3: the NON-manifest per-spawn managers this persistent context was
    /// CREATED with (registry index ≥ 1; docs/memory-manager-abi.md §10.5). The
    /// context bakes in each `zap_spawn_manager_<index>` sibling module + the
    /// `zap_manager_registry` module + the `multi_manager` runtime rewrite, so a
    /// change to this set requires a fresh context (surfaced as
    /// `ContextInvalidated` by `rebuild`). Empty for every single-manager binary
    /// — then this whole axis is inert and the context is byte-identical to
    /// pre-J3. Owned by `allocator`; freed in `deinit`.
    spawn_managers: []const zir_backend.SpawnManagerRegistration = &.{},
    /// P3-J3: the per-spawn manager set the MOST RECENT `rebuild` discovered
    /// (via the resolver-wired frontend). When it differs from `spawn_managers`
    /// the context is stale; `rebuild` records the new set here and returns
    /// `ContextInvalidated` so `rebuildManifestDaemonState` can recreate the
    /// context bound to it. Owned by `allocator`; freed in `deinit`.
    discovered_spawn_managers: []const zir_backend.SpawnManagerRegistration = &.{},

    fn deinit(self: *IncrementalWatchState) void {
        zir_backend.destroyContext(self.zir_ctx);
        self.frontend_state.deinit();
        freeOwnedModuleHashKeys(self.allocator, &self.module_hashes);
        self.module_hashes.deinit();
        self.allocator.free(self.zig_lib_dir);
        self.allocator.free(self.output_path);
        self.allocator.free(self.output_name);
        if (self.target) |target| self.allocator.free(target);
        self.allocator.free(self.active_manager_source_path);
        self.allocator.free(self.concurrency_kernel_key);
        freeSpawnManagerRegistrations(self.allocator, self.spawn_managers);
        freeSpawnManagerRegistrations(self.allocator, self.discovered_spawn_managers);
        self.manifest_arena.deinit();
    }

    /// Create incremental state by deriving the same config buildTarget uses.
    ///
    /// Watch mode pins one memory manager for the lifetime of the
    /// session. `init` re-runs the same `zap.memory_driver.resolve`
    /// flow `buildTarget` uses, then caches the resolved
    /// `declared_caps`, `refcount_sized_extension`, and active source
    /// path. Stdlib and project/dependency managers flow through the
    /// same path; the cached metadata drives codegen elision and the
    /// runtime-source rewrite so every rebuild produces a binary against
    /// the manager the manifest resolved at `init` time.
    fn init(
        allocator: std.mem.Allocator,
        project_root: []const u8,
        target_name: []const u8,
        build_opts: std.StringHashMapUnmanaged([]const u8),
        build_overrides: BuildOverrides,
        collect_arc_stats: bool,
        zap_lib_dir_override: ?[]const u8,
        progress: ?*zap.progress.Reporter,
        // P3-J3: the NON-manifest per-spawn managers to bake into the persistent
        // context (empty on first creation; populated by a prior `rebuild`'s
        // discovery when a context is recreated for a multi-manager binary).
        spawn_managers: []const zir_backend.SpawnManagerRegistration,
    ) IncrementalInitError!IncrementalWatchState {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Re-derive build config (same logic as buildTarget) — INCLUDING
        // the single shared `applyBuildOverrides` step so a watch
        // session honors `-Doptimize=`/`-Dmemory=`/`-Dtarget=`/`-Dcpu=`
        // on every rebuild exactly as a one-shot build does.
        if (progress) |reporter| reporter.stage("Planning target :{s}", .{target_name});
        if (progress) |reporter| reporter.stage("Manifest: reading build.zap", .{});
        const build_file_path = std.fs.path.join(alloc, &.{ project_root, "build.zap" }) catch return error.OutOfMemory;
        const build_source = std.Io.Dir.cwd().readFileAlloc(global_io, build_file_path, alloc, .limited(10 * 1024 * 1024)) catch |err| {
            std.debug.print("Error: watch-mode build.zap read failed: {s}\n", .{@errorName(err)});
            return incrementalInitErrorOrStatus(err, error.ReadError);
        };
        if (progress) |reporter| reporter.stage("Toolchain: resolving Zap stdlib", .{});
        const zap_lib_dir = resolveZapLibDir(alloc, zap_lib_dir_override, project_root) catch |err|
            return incrementalInitErrorOrStatus(err, error.ToolchainError);
        const manifest_eval = zap.builder.ctfeManifestDetailedWithProgress(alloc, build_source, target_name, build_overrides.target, build_opts, zap_lib_dir, progress) catch |err| {
            std.debug.print("Error: watch-mode manifest evaluation failed: {s}\n", .{@errorName(err)});
            return incrementalInitErrorOrStatus(err, error.ManifestError);
        };
        var config = manifest_eval.config;
        applyBuildOverrides(&config, build_overrides);
        const compile_target: ?[]const u8 = config.target;
        const compile_cpu: ?[]const u8 = config.cpu;
        const optimize_policy = optimizePolicyForBuildConfig(config.optimize);

        if (progress) |reporter| reporter.stage("Toolchain: resolving Zig stdlib", .{});
        // Trusted detection → embedded fork stdlib → system Zig last resort.
        const zig_lib_dir = try resolveIncrementalZigLibDir(alloc);
        const toolchain_cache_dir = ".zap-cache/toolchain";
        if (progress) |reporter| reporter.stage("Toolchain: checking compiler identity", .{});
        const compiler_identity_digest = hashCompilerIdentity(alloc, toolchain_cache_dir) catch |err|
            return incrementalToolchainIdentityError(err);
        const zig_lib_identity_digest = hashZigLibIdentity(alloc, toolchain_cache_dir, zig_lib_dir) catch |err|
            return incrementalToolchainIdentityError(err);

        if (progress) |reporter| reporter.stage("Sources: resolving roots", .{});
        const watch_source_roots = resolveManifestSourceRoots(alloc, project_root, config, zap_lib_dir, .{
            .write_lockfile = true,
            .print_local_overrides = false,
        }) catch |err| {
            std.debug.print("Error: watch-mode source-root resolution failed: {s}\n", .{@errorName(err)});
            return incrementalInitErrorOrStatus(err, error.ManifestError);
        };

        if (progress) |reporter| reporter.stage("Memory: resolving manifest adapter", .{});
        const memory_source_units = collectMemoryAdapterSourceUnits(alloc, watch_source_roots) catch |err| {
            std.debug.print("Error: watch-mode memory adapter source discovery failed: {s}\n", .{@errorName(err)});
            return incrementalInitErrorOrStatus(err, error.ManifestError);
        };
        const memory_adapter_eval = zap.builder.evaluateMemoryManagerAdapterFromSources(
            alloc,
            watch_source_roots,
            memory_source_units,
            config.memory_manager,
            target_name,
            build_opts,
        ) catch |err| {
            std.debug.print("Error: watch-mode Memory.Manager adapter evaluation failed: {}\n", .{err});
            return incrementalInitErrorOrStatus(err, error.ManifestError);
        };
        const manifest_memory_manager = memory_adapter_eval.manager orelse return error.ManifestError;

        // Resolve the active memory manager — mirror `buildTarget`'s
        // flow so the watch-session uses the same active manager source,
        // validation object, and capability bitmask that a non-watch
        // build would. The driver_optimize/driver target arguments mirror
        // `buildTarget` to keep validation identical across build modes.
        const driver_optimize = optimize_policy.memory_driver_optimize;
        const zap_source_tree_root: []const u8 = if (zap_lib_dir) |lib_dir|
            (std.fs.path.dirname(lib_dir) orelse project_root)
        else
            project_root;
        var driver_diag_buf: [4096]u8 = undefined;
        var driver_diag: zap.memory_driver.DriverDiagnostic = .{ .buffer = &driver_diag_buf };
        var resolved_manager = zap.memory_driver.resolve(
            alloc,
            .{
                .adapter = .{
                    .type_name = manifest_memory_manager.type_name,
                    .adapter_source_path = manifest_memory_manager.adapter_source_path,
                },
                .source_roots = sourceRootsForMemoryDriver(alloc, watch_source_roots) catch |err|
                    return incrementalInitErrorOrStatus(err, error.MemoryManagerError),
                .project_root = project_root,
                .zap_source_root = zap_source_tree_root,
                .cache_dir = ".zap-cache/memory",
                .zig_lib_dir = zig_lib_dir,
                .compiler_identity_digest = compiler_identity_digest,
                .zig_lib_identity_digest = zig_lib_identity_digest,
                .optimize = driver_optimize,
                .target = compile_target,
                .cpu = compile_cpu,
                .progress = progress,
            },
            &driver_diag,
        ) catch |err| {
            std.debug.print(
                "Error: watch-mode memory manager resolution failed: {s}\n",
                .{@errorName(err)},
            );
            if (driver_diag.text().len > 0) {
                std.debug.print("  {s}\n", .{driver_diag.text()});
            }
            return incrementalInitErrorOrStatus(err, error.MemoryManagerError);
        };
        defer zap.memory_driver.freeResolved(alloc, &resolved_manager);
        const active_manager_source_digest = hashActiveManagerSource(alloc, resolved_manager.active_manager_source_path) catch |err|
            return incrementalInitErrorOrStatus(err, error.MemoryManagerError);

        // Watch mode supports every manager that produces a valid
        // `.zapmem` section:
        // the resolved `declared_caps` flows into `compiler.getRuntimeSource`
        // (so the embedded runtime collapses inline `ArcHeader` fields
        // and `refcount_v1_active` branches under managers that omit
        // `REFCOUNT_V1`), into `compileProjectFrontend` (so the
        // arc_materialize pass elides retain/release IR for non-REFCOUNT_V1
        // managers), and into `zir_compilation` (so ZIR codegen sees
        // the same bitmask the front-end used). Phase 6 plumbed the
        // bitmask through both code paths; this constructor just caches
        // it so every subsequent `rebuild` reuses the same value.
        const declared_caps = resolved_manager.declared_caps;
        const refcount_sized_extension = resolved_manager.refcount_sized_extension;
        const active_manager_source_path_owned = allocator.dupe(u8, resolved_manager.active_manager_source_path) catch return error.OutOfMemory;
        errdefer allocator.free(active_manager_source_path_owned);

        // P2-J1: resolve the concurrency kernel object when the gate is
        // ON — mirroring `buildTarget`'s flow — and pin its identity for
        // the watch session (the object path is baked into the
        // persistent Zig context's link inputs below).
        const runtime_concurrency_enabled = config.runtime_concurrency;
        validateRuntimeTracingGate(config);
        var resolved_concurrency_kernel: ?zap.concurrency_driver.ResolvedKernel = null;
        defer if (resolved_concurrency_kernel) |*resolved_kernel|
            zap.concurrency_driver.freeResolvedKernel(alloc, resolved_kernel);
        if (runtime_concurrency_enabled) {
            const concurrency_kernel_source_dir = std.fs.path.join(
                alloc,
                &.{ zap_source_tree_root, zap.concurrency_driver.KERNEL_UNIT_RELATIVE_DIR },
            ) catch return error.OutOfMemory;
            var kernel_diag_buf: [4096]u8 = undefined;
            var kernel_diag: zap.memory_driver.DriverDiagnostic = .{ .buffer = &kernel_diag_buf };
            resolved_concurrency_kernel = zap.concurrency_driver.resolveKernelObject(
                alloc,
                .{
                    .kernel_source_dir = concurrency_kernel_source_dir,
                    .cache_dir = ".zap-cache/concurrency",
                    .zig_lib_dir = zig_lib_dir,
                    .compiler_identity_digest = compiler_identity_digest,
                    .zig_lib_identity_digest = zig_lib_identity_digest,
                    .optimize = driver_optimize,
                    .target = compile_target,
                    .cpu = compile_cpu,
                    .progress = progress,
                    .runtime_tracing = config.runtime_tracing,
                },
                &kernel_diag,
            ) catch |err| {
                std.debug.print(
                    "Error: watch-mode concurrency kernel resolution failed: {s}\n",
                    .{@errorName(err)},
                );
                if (kernel_diag.text().len > 0) {
                    std.debug.print("  {s}\n", .{kernel_diag.text()});
                }
                return incrementalInitErrorOrStatus(err, error.BackendError);
            };
        }
        const concurrency_kernel_key_owned: []const u8 = if (resolved_concurrency_kernel) |resolved_kernel|
            (allocator.dupe(u8, &resolved_kernel.cache_key_hex) catch return error.OutOfMemory)
        else
            (allocator.dupe(u8, "") catch return error.OutOfMemory);
        errdefer allocator.free(concurrency_kernel_key_owned);

        const output_name_raw = if (config.asset_name) |an| (if (an.len > 0) an else config.name) else config.name;
        const out_dir: []const u8 = switch (config.kind) {
            .bin => "zap-out/bin",
            .lib => "zap-out/lib",
            .obj => "zap-out/obj",
        };
        const output_filename = switch (config.kind) {
            .bin => output_name_raw,
            .lib => std.fmt.allocPrint(alloc, "{s}.a", .{output_name_raw}) catch return error.OutOfMemory,
            .obj => std.fmt.allocPrint(alloc, "{s}.o", .{output_name_raw}) catch return error.OutOfMemory,
        };
        const output_path = std.fs.path.join(alloc, &.{ out_dir, output_filename }) catch return error.OutOfMemory;

        const output_mode_val: u8 = switch (config.kind) {
            .bin => 0,
            .lib => 1,
            .obj => 2,
        };
        const has_generated_executable_startup_prologue = hasGeneratedExecutableStartupPrologue(config.kind);
        const optimize_mode_val: u8 = optimize_policy.backend_optimize_mode;

        // Dupe strings into the persistent allocator
        const zig_lib_duped = allocator.dupe(u8, zig_lib_dir) catch return error.OutOfMemory;
        errdefer allocator.free(zig_lib_duped);
        const output_path_duped = allocator.dupe(u8, output_path) catch return error.OutOfMemory;
        errdefer allocator.free(output_path_duped);
        const output_name_duped = allocator.dupe(u8, output_name_raw) catch return error.OutOfMemory;
        errdefer allocator.free(output_name_duped);
        const target_duped: ?[]const u8 = if (compile_target) |target_value|
            (allocator.dupe(u8, target_value) catch return error.OutOfMemory)
        else
            null;
        errdefer if (target_duped) |target_value| allocator.free(target_value);

        // Create persistent ZirContext. The runtime source is rewritten
        // against `declared_caps` so the generated runtime matches the
        // resolved manager's capability surface — Phase 6 inline-header
        // layout and codegen elision both consult this value.
        if (progress) |reporter| reporter.stage("ZIR: creating Zig compilation", .{});
        // Phase 0 — DWARF foundation: resolve the per-mode debug-info
        // policy ONCE here so the persistent context's `root_strip`
        // matches every subsequent `injectAndUpdate`. Watch sessions
        // hold this context across many rebuilds; baking the policy
        // in at creation time means a `-Ddebug-info=` override applied
        // at startup persists for the lifetime of the daemon.
        const watch_dbg_resolution = blk: {
            const override: ?DebugInfoOverride = if (config.debug_info) |dbg| switch (dbg) {
                .full => @as(DebugInfoOverride, .full),
                .split => @as(DebugInfoOverride, .split),
                .none => @as(DebugInfoOverride, .none),
            } else null;
            break :blk resolveDebugInfoPolicy(config.optimize, override, config.frame_pointers);
        };
        const ctx = zir_backend.createContext(allocator, .{
            .zig_lib_dir = zig_lib_duped,
            .cache_dir = ".zap-cache",
            .global_cache_dir = ".zap-cache",
            .output_path = output_path_duped,
            .name = output_name_duped,
            .runtime_source = compiler.getRuntimeSourceForRuntimeControls(
                declared_caps,
                refcount_sized_extension,
                .{
                    .memory_startup_prologue_emitted = has_generated_executable_startup_prologue,
                    .collect_arc_stats = collect_arc_stats,
                    .runtime_concurrency = runtime_concurrency_enabled,
                    // P3-J3: arm the per-process manager gate when this context is
                    // being created for a multi-manager binary (mirrors the direct
                    // `compileAndLink` path). Empty ⇒ OFF ⇒ byte-identical to pre-J3.
                    .multi_manager = spawn_managers.len > 0,
                },
            ),
            .output_mode = output_mode_val,
            .optimize_mode = optimize_mode_val,
            .target = compile_target,
            .cpu = compile_cpu,
            .link_libc = true,
            .incremental = true,
            .declared_caps = declared_caps,
            .active_manager_source_path = active_manager_source_path_owned,
            // P3-J3: the per-spawn manager backends the ZIR backend links as
            // `zap_spawn_manager_<index>` sibling modules + the generated
            // `zap_manager_registry` module (docs/memory-manager-abi.md §10.5).
            .spawn_managers = spawn_managers,
            .concurrency_kernel_object_path = if (resolved_concurrency_kernel) |resolved_kernel|
                resolved_kernel.object_path
            else
                null,
            // P2-J2: the gate itself, threaded into ZIR emission (root-
            // process entry rerouting).
            .runtime_concurrency = runtime_concurrency_enabled,
            .debug_info_policy = watch_dbg_resolution.in_binary,
            .frame_pointer_policy = zir_backend.FramePointerPolicy.fromOptional(watch_dbg_resolution.frame_pointers),
        }) catch |err| return incrementalInitErrorOrStatus(err, error.BackendError);
        errdefer zir_backend.destroyContext(ctx);

        const pinned_manifest = clonePinnedManifestState(
            allocator,
            config,
            build_source,
            manifest_eval.dependencies,
            manifest_eval.result_hash,
            watch_source_roots,
            zap_lib_dir,
        ) catch |err| return incrementalInitErrorOrStatus(err, error.ManifestError);

        return .{
            .zir_ctx = ctx,
            .zig_lib_dir = zig_lib_duped,
            .output_path = output_path_duped,
            .output_name = output_name_duped,
            .output_mode = output_mode_val,
            .optimize_mode = optimize_mode_val,
            .frontend_optimize_mode = optimize_policy.frontend_optimize_mode,
            .kind = config.kind,
            .target = target_duped,
            .lib_mode = config.kind == .lib,
            .has_generated_executable_startup_prologue = has_generated_executable_startup_prologue,
            .collect_arc_stats = collect_arc_stats,
            .link_libc = true,
            .compiler_identity_digest = compiler_identity_digest,
            .zig_lib_identity_digest = zig_lib_identity_digest,
            .allocator = allocator,
            .manifest_arena = pinned_manifest.arena,
            .manifest_config = pinned_manifest.config,
            .manifest_build_source = pinned_manifest.build_source,
            .manifest_dependencies = pinned_manifest.dependencies,
            .manifest_result_hash = pinned_manifest.result_hash,
            .manifest_source_roots = pinned_manifest.source_roots,
            .manifest_zap_lib_dir = pinned_manifest.zap_lib_dir,
            .frontend_state = compiler.FrontendIncrementalState.init(allocator),
            .module_hashes = std.StringHashMap(u64).init(allocator),
            .memory_adapter_result_hash = memory_adapter_eval.result_hash,
            .declared_caps = declared_caps,
            .refcount_sized_extension = refcount_sized_extension,
            .active_manager_source_path = active_manager_source_path_owned,
            .active_manager_source_digest = active_manager_source_digest,
            .runtime_concurrency = runtime_concurrency_enabled,
            .concurrency_kernel_key = concurrency_kernel_key_owned,
            // P3-J3: pin the manager family this context was created with, so
            // `rebuild` can detect a spawn-manager set change and force a fresh
            // context. Deep-copied into the persistent allocator.
            .spawn_managers = dupeSpawnManagerRegistrations(allocator, spawn_managers) catch return error.OutOfMemory,
        };
    }

    fn replaceStoredIncrementalHashes(
        self: *IncrementalWatchState,
        current_hashes: *const ComputedIncrementalHashes,
        source_topology_hash: u64,
    ) !void {
        var next_hashes = std.StringHashMap(u64).init(self.allocator);
        errdefer {
            freeOwnedModuleHashKeys(self.allocator, &next_hashes);
            next_hashes.deinit();
        }

        var iter = current_hashes.modules.iterator();
        while (iter.next()) |entry| {
            const owned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
            next_hashes.put(owned_key, entry.value_ptr.*) catch |err| {
                self.allocator.free(owned_key);
                return err;
            };
        }

        freeOwnedModuleHashKeys(self.allocator, &self.module_hashes);
        self.module_hashes.deinit();
        self.module_hashes = next_hashes;
        self.root_module_hash_present = current_hashes.root_present;
        self.root_module_hash = current_hashes.root_hash;
        self.source_topology_hash = source_topology_hash;
    }

    fn backendOptions(
        self: *IncrementalWatchState,
        allocator: std.mem.Allocator,
        result: *compiler.CompileResult,
        progress: ?*zap.progress.Reporter,
    ) zir_backend.CompileOptions {
        _ = allocator;
        // Phase 0 — DWARF foundation: resolve the per-mode debug-info
        // policy for this rebuild from the manifest config that
        // pinned the daemon (`manifest_config` carries the user's
        // `-Ddebug-info=` override after `applyBuildOverrides`). The
        // resolution runs once per rebuild so each incremental update
        // produces a binary with the same DWARF policy as the initial
        // build — `IncrementalWatchState` itself only exists for the
        // lifetime of a single manifest, so the resolution is stable.
        const dbg_resolution = blk: {
            const override: ?DebugInfoOverride = if (self.manifest_config.debug_info) |dbg| switch (dbg) {
                .full => @as(DebugInfoOverride, .full),
                .split => @as(DebugInfoOverride, .split),
                .none => @as(DebugInfoOverride, .none),
            } else null;
            break :blk resolveDebugInfoPolicy(
                self.manifest_config.optimize,
                override,
                self.manifest_config.frame_pointers,
            );
        };
        return .{
            .zig_lib_dir = self.zig_lib_dir,
            .cache_dir = ".zap-cache",
            .global_cache_dir = ".zap-cache",
            .output_path = self.output_path,
            .name = self.output_name,
            .runtime_source = compiler.getRuntimeSourceForRuntimeControls(
                self.declared_caps,
                self.refcount_sized_extension,
                .{
                    .memory_startup_prologue_emitted = self.has_generated_executable_startup_prologue,
                    .collect_arc_stats = self.collect_arc_stats,
                    .runtime_concurrency = self.runtime_concurrency,
                },
            ),
            .output_mode = self.output_mode,
            .optimize_mode = self.optimize_mode,
            .link_libc = self.link_libc,
            .incremental = true,
            .analysis_context = if (result.analysis_context) |*ctx| ctx else null,
            .arc_ownership = if (result.arc_ownership) |*ownership| ownership else null,
            .declared_caps = self.declared_caps,
            .active_manager_source_path = self.active_manager_source_path,
            // P2-J1: rebuilds reuse the persistent context created at
            // `init`, whose link inputs already carry the kernel object;
            // `backendOptions` feeds `injectAndUpdate` (never a fresh
            // `createContext`), so no object path is re-registered here.
            // P2-J2: the gate itself still travels — ZIR emission needs
            // it on every rebuild (root-process entry rerouting).
            .runtime_concurrency = self.runtime_concurrency,
            .progress = progress,
            .debug_info_policy = dbg_resolution.in_binary,
            .frame_pointer_policy = zir_backend.FramePointerPolicy.fromOptional(dbg_resolution.frame_pointers),
        };
    }

    /// Run an incremental rebuild: full frontend re-compile, then a selected
    /// injected-ZIR update on the persistent Zig context. Normal selected
    /// updates preserve Zig's compare-hash invalidation; only frontend
    /// force-full/structural updates request full source-hash invalidation.
    fn rebuild(
        self: *IncrementalWatchState,
        allocator: std.mem.Allocator,
        project_root: []const u8,
        target_name: []const u8,
        build_opts: std.StringHashMapUnmanaged([]const u8),
        build_overrides: BuildOverrides,
        changed_paths: []const []const u8,
        zap_lib_dir_override: ?[]const u8,
        progress: ?*zap.progress.Reporter,
    ) IncrementalError!void {
        _ = zap_lib_dir_override;
        var profile_timer: ?ProfileTimer = if (profileEnabled()) ProfileTimer.start() else null;

        var build_arena = std.heap.ArenaAllocator.init(allocator);
        defer build_arena.deinit();
        const alloc = build_arena.allocator();
        for (changed_paths) |changed_path| {
            incrementalTrace("watch-changed-path path={s}", .{changed_path});
        }

        // Re-read build config and sources (same as buildTarget),
        // INCLUDING the single shared `applyBuildOverrides` step so an
        // incremental rebuild keeps the CLI `-D` overrides in effect.
        if (progress) |reporter| reporter.stage("Planning target :{s}", .{target_name});
        if (progress) |reporter| reporter.stage("Manifest: using pinned build.zap evaluation", .{});
        const build_file_path = try std.fs.path.join(alloc, &.{ project_root, "build.zap" });
        const build_source = self.manifest_build_source;
        const zap_lib_dir = self.manifest_zap_lib_dir;
        const config = self.manifest_config;
        const source_roots = self.manifest_source_roots;

        if (progress) |reporter| reporter.stage("Sources: resolving roots", .{});
        var manifest_sources = discoverManifestSources(alloc, project_root, config, source_roots, progress) catch |err|
            return incrementalErrorOrStatus(err, error.DiscoveryError);
        defer manifest_sources.deinit();
        profileLap(&profile_timer, "planning", .{});

        const current_source_topology_hash = computeSourceTopologyHash(&manifest_sources);
        if (self.baseline_established and current_source_topology_hash != self.source_topology_hash) {
            return error.ContextInvalidated;
        }

        if (progress) |reporter| reporter.stage("Memory: validating pinned manager", .{});
        const memory_source_units = collectMemoryAdapterSourceUnits(alloc, source_roots) catch |err|
            return incrementalErrorOrStatus(err, error.ManifestError);
        const memory_adapter_eval = zap.builder.evaluateMemoryManagerAdapterFromSources(
            alloc,
            source_roots,
            memory_source_units,
            config.memory_manager,
            target_name,
            build_opts,
        ) catch |err| return incrementalErrorOrStatus(err, error.ManifestError);
        _ = memory_adapter_eval.manager orelse return error.ManifestError;
        if (memory_adapter_eval.result_hash != self.memory_adapter_result_hash) {
            return error.ContextInvalidated;
        }
        const current_active_manager_source_digest = hashActiveManagerSource(alloc, self.active_manager_source_path) catch |err|
            return incrementalErrorOrStatus(err, error.ContextInvalidated);
        if (!std.mem.eql(u8, current_active_manager_source_digest[0..], self.active_manager_source_digest[0..])) {
            return error.ContextInvalidated;
        }
        profileLap(&profile_timer, "memory validation", .{});

        // P3-J3: the driver-backed per-spawn manager resolver + accumulator,
        // mirroring the direct `compileAndLink` path (docs/memory-manager-abi.md
        // §10.5). Wired into the incremental frontend below so the spawn-manager
        // pass resolves each `spawn(f, .{ .manager = X })` site. The discovered
        // NON-manifest managers are reconciled AFTER the frontend against the set
        // the persistent context was created with; a difference forces a fresh
        // context (`SpawnManagerSetChanged`). For a single-manager binary NO
        // managed-spawn site exists, the resolver is never called, and the
        // accumulator stays empty — the incremental path is byte-identical to
        // pre-J3. The driver `ResolveOptions` template mirrors `init`'s manifest
        // resolution so a per-spawn manager resolves the same way the manifest
        // default did.
        const rebuild_optimize_policy = optimizePolicyForBuildConfig(config.optimize);
        const rebuild_zap_source_tree_root: []const u8 = if (self.manifest_zap_lib_dir) |lib_dir|
            (std.fs.path.dirname(lib_dir) orelse project_root)
        else
            project_root;
        const rebuild_memory_driver_source_roots = sourceRootsForMemoryDriver(alloc, self.manifest_source_roots) catch return error.OutOfMemory;
        var spawn_manager_accumulator = SpawnManagerAccumulator{
            .alloc = alloc,
            .source_roots = self.manifest_source_roots,
            .source_units = manifest_sources.source_units,
            .target_name = target_name,
            .build_opts = build_opts,
            .driver_options_template = .{
                .adapter = .{ .type_name = "", .adapter_source_path = null },
                .source_roots = rebuild_memory_driver_source_roots,
                .project_root = project_root,
                .zap_source_root = rebuild_zap_source_tree_root,
                .cache_dir = ".zap-cache/memory",
                .zig_lib_dir = self.zig_lib_dir,
                .compiler_identity_digest = self.compiler_identity_digest,
                .zig_lib_identity_digest = self.zig_lib_identity_digest,
                .optimize = rebuild_optimize_policy.memory_driver_optimize,
                .target = self.target,
                .cpu = config.cpu,
                .progress = progress,
            },
            .manifest_backend_source_path = self.active_manager_source_path,
        };

        if (progress) |reporter| reporter.stage("Frontend: compiling Zap sources", .{});
        var frontend_prepared = self.frontend_state.prepare(alloc, manifest_sources.source_units, .{
            .file_to_structs = &manifest_sources.source_file_to_structs,
            .file_imported_by = &manifest_sources.source_file_imported_by,
            .file_compile_after_globs = &manifest_sources.source_file_compile_after_globs,
            .file_compile_after_files = &manifest_sources.source_file_compile_after_files,
        }, .{
            .show_progress = progress != null,
            .progress = progress,
            .progress_context = "Frontend",
            .lib_mode = self.lib_mode,
            .frontend_optimize_mode = self.frontend_optimize_mode,
            .struct_order = manifest_sources.struct_order,
            .level_boundaries = manifest_sources.level_boundaries,
            .cache_dir = ".zap-cache/ctfe",
            .ctfe_target = target_name,
            .ctfe_optimize = @tagName(config.optimize),
            .io = global_io,
            // Threading the cached `declared_caps` here is the key
            // Phase 6 plumbing: `compileProjectFrontend` forwards it
            // to `arc_materialize.materializeAnalysisArcOps`, which
            // decides whether to emit retain/release/reset IR for
            // each function. Defaulting to 0 (as the previous watch
            // code did) would strip every refcount op even under a
            // REFCOUNT_V1 manager and silently leak every Arc cell.
            .declared_caps = self.declared_caps,
            .spawn_manager_resolver = spawn_manager_accumulator.resolver(),
        }) catch |err| return incrementalErrorOrStatus(err, error.FrontendError);
        defer frontend_prepared.deinit();
        var result = frontend_prepared.result;
        profileLap(&profile_timer, "frontend", .{});

        // P3-J3: reconcile the discovered per-spawn manager set with the one the
        // persistent context was created with. A difference (a spawn site added,
        // removed, or retargeted to a different manager) means the context — which
        // baked in the `zap_spawn_manager_<index>` sibling modules, the
        // `zap_manager_registry` module, and the `multi_manager` runtime rewrite —
        // is stale. Record the discovered set (into the persistent allocator so it
        // survives this build arena) and force a fresh context bound to it; the
        // retry in `establishIncrementalWatchState` supplies it to `init`.
        if (!spawnManagerRegistrationsEqual(spawn_manager_accumulator.registrations.items, self.spawn_managers)) {
            const discovered = dupeSpawnManagerRegistrations(self.allocator, spawn_manager_accumulator.registrations.items) catch return error.OutOfMemory;
            freeSpawnManagerRegistrations(self.allocator, self.discovered_spawn_managers);
            self.discovered_spawn_managers = discovered;
            return error.SpawnManagerSetChanged;
        }

        // Resolve entry point
        if (config.root) |root| {
            const arity_str = if (std.mem.findScalarLast(u8, root, '/')) |slash| root[slash + 1 ..] else "0";
            const without_arity = if (std.mem.findScalarLast(u8, root, '/')) |slash| root[0..slash] else root;
            var mangled: std.ArrayListUnmanaged(u8) = .empty;
            if (std.mem.findScalarLast(u8, without_arity, '.')) |last_dot| {
                const struct_part = without_arity[0..last_dot];
                const func_part = without_arity[last_dot + 1 ..];
                for (struct_part) |c| {
                    try mangled.append(alloc, if (c == '.') '_' else c);
                }
                try mangled.appendSlice(alloc, "__");
                try mangled.appendSlice(alloc, func_part);
                try mangled.appendSlice(alloc, "__");
                try mangled.appendSlice(alloc, arity_str);
            } else {
                try mangled.appendSlice(alloc, without_arity);
                try mangled.appendSlice(alloc, "__");
                try mangled.appendSlice(alloc, arity_str);
            }
            for (result.ir_program.functions) |func| {
                if (std.mem.eql(u8, func.name, mangled.items)) {
                    result.ir_program.entry = func.id;
                    break;
                }
            }
        }

        var current_hashes = computeIncrementalHashes(alloc, result.ir_program) catch return error.OutOfMemory;
        defer current_hashes.deinit();
        profileLap(&profile_timer, "incremental hashes", .{});

        for (changed_paths) |changed_path| {
            if (std.mem.eql(u8, changed_path, self.active_manager_source_path)) {
                return error.ContextInvalidated;
            }
        }

        const prepared_update = self.baseline_established;
        const backend_plan = if (prepared_update)
            selectPreparedIncrementalBackendPlan(
                alloc,
                &result,
                self.root_module_hash_present,
                self.root_module_hash,
                &self.module_hashes,
                &current_hashes,
            ) catch |err| return incrementalErrorOrStatus(err, error.ContextInvalidated)
        else
            PreparedIncrementalBackendPlan{
                .selection = .{ .struct_names = &.{}, .include_root = false },
                .invalidation = .compare_source_hashes,
            };
        const backend_selection = backend_plan.selection;
        const backend_module_selection = normalizeIncrementalSelectionForBackend(alloc, backend_selection) catch |err|
            return incrementalErrorOrStatus(err, error.ContextInvalidated);
        defer backend_module_selection.deinit(alloc);
        const needs_backend_update = !prepared_update or
            backend_module_selection.include_root or
            backend_module_selection.struct_names.len > 0;
        if (incrementalTraceEnabled()) {
            incrementalTrace(
                "backend-selection prepared={} force_full={} invalidation={s} affected_functions={d}",
                .{
                    prepared_update,
                    result.incremental_backend_force_full,
                    @tagName(backend_plan.invalidation),
                    result.incremental_backend_affected_function_ids.len,
                },
            );
            traceIncrementalModuleSelection("final-filtered", backend_selection);
            traceOwnedIncrementalModuleSelection("normalized-backend", backend_module_selection);
            incrementalTrace(
                "rebuild-summary changed_paths={d} frontend_changed_structs={d} frontend_invalidated_structs={d} changed_roots={d} affected_functions={d} force_full={} selected_modules={d} include_root={} invalidation={s} backend_update={}",
                .{
                    changed_paths.len,
                    frontend_prepared.changed_struct_names.len,
                    frontend_prepared.invalidated_struct_names.len,
                    frontend_prepared.changed_graph_roots.len,
                    result.incremental_backend_affected_function_ids.len,
                    result.incremental_backend_force_full,
                    backend_module_selection.struct_names.len,
                    backend_module_selection.include_root,
                    @tagName(backend_plan.invalidation),
                    needs_backend_update,
                },
            );
        }
        if (profileEnabled()) {
            std.debug.print(
                "\n[incremental backend] prepared={} force_full={} invalidation={s} affected_functions={d} selected_modules={d} include_root={}\n",
                .{
                    prepared_update,
                    result.incremental_backend_force_full,
                    @tagName(backend_plan.invalidation),
                    result.incremental_backend_affected_function_ids.len,
                    backend_module_selection.struct_names.len,
                    backend_module_selection.include_root,
                },
            );
            for (backend_module_selection.struct_names) |struct_name| {
                std.debug.print("[incremental backend] selected {s}\n", .{struct_name});
            }
        }

        // Source edits must publish artifacts from the current affected ZIR
        // modules. Zap keeps the persistent Zig compilation context and prepares
        // only the modules whose stable emitted IR changed. The invalidation
        // policy is explicit: ordinary selected updates preserve Zig's
        // old-ZIR/new-ZIR compare-hash path, while structural force-full updates
        // ask the fork to mark every source hash in the prepared files stale.
        if (prepared_update and needs_backend_update) {
            if (progress) |reporter| reporter.stage("Backend: preparing incremental update", .{});
            zir_backend.prepareSelectedUpdate(
                alloc,
                self.zir_ctx,
                backend_module_selection.struct_names,
                backend_module_selection.include_root,
                backend_plan.invalidation,
            ) catch |err| {
                zir_backend.abortUpdate(self.zir_ctx) catch |abort_err| {
                    std.debug.print(
                        "Error: failed to abort prepared incremental update after prepare failure ({s}); context must be discarded: {s}\n",
                        .{ @errorName(err), @errorName(abort_err) },
                    );
                    return error.BackendContextInvalidated;
                };
                return incrementalBackendErrorOrStatus(err, error.BackendError);
            };
            profileLap(&profile_timer, "backend prepare", .{});

            const backend_options = self.backendOptions(alloc, &result, progress);
            if (progress) |reporter| reporter.stage("Backend: compiling ZIR and linking", .{});
            zir_backend.injectPreparedSelectedAndUpdate(
                alloc,
                result.ir_program,
                self.zir_ctx,
                backend_options,
                backend_module_selection.struct_names,
                backend_module_selection.include_root,
            ) catch |err| return incrementalBackendErrorOrStatus(err, error.BackendError);
            profileLap(&profile_timer, "backend incremental update", .{});
        } else if (!prepared_update) {
            const backend_options = self.backendOptions(alloc, &result, progress);
            if (progress) |reporter| reporter.stage("Backend: compiling ZIR and linking", .{});
            zir_backend.injectAndUpdate(alloc, result.ir_program, self.zir_ctx, backend_options) catch |err|
                return incrementalErrorOrStatus(err, error.BackendError);
            profileLap(&profile_timer, "backend full update", .{});
        }

        try frontend_prepared.commit();
        try self.replaceStoredIncrementalHashes(&current_hashes, current_source_topology_hash);
        profileLap(&profile_timer, "commit hashes", .{});

        if (needs_backend_update) {
            generateDarwinDebugSymbolsOrExit(alloc, config, self.output_path, progress);
        }
        profileLap(&profile_timer, "debug symbols", .{});

        const manifest_invocation_identity = computeManifestInvocationIdentity(
            alloc,
            build_source,
            project_root,
            target_name,
            build_opts,
            build_overrides,
            self.collect_arc_stats,
            zap_lib_dir,
            self.zig_lib_dir,
            self.compiler_identity_digest,
            self.zig_lib_identity_digest,
        ) catch |err| return incrementalErrorOrStatus(err, error.CacheMetadataError);
        const manifest_snapshot_path = build_cache.snapshotPath(alloc, ".zap-cache", target_name) catch |err|
            return incrementalErrorOrStatus(err, error.CacheMetadataError);
        const metadata_inputs = CompileAndLinkInputs{
            .config = config,
            .source_roots = manifest_sources.source_roots,
            .source_units = manifest_sources.source_units,
            .struct_order = manifest_sources.struct_order,
            .level_boundaries = manifest_sources.level_boundaries,
            .manifest_result_hash = zap.builder.hashManifestWithMemoryAdapter(
                self.manifest_result_hash,
                self.memory_adapter_result_hash,
            ),
            .cache_source = build_source,
            .target_name = target_name,
            .build_opts = build_opts,
            .zap_lib_dir = zap_lib_dir,
            .zig_lib_dir = self.zig_lib_dir,
            .compiler_identity_digest = self.compiler_identity_digest,
            .zig_lib_identity_digest = self.zig_lib_identity_digest,
            .project_root = project_root,
            .collect_arc_stats = self.collect_arc_stats,
            .layout = .manifest,
            .progress = progress,
            .manifest_cache = .{
                .invocation_identity = manifest_invocation_identity,
                .snapshot_path = manifest_snapshot_path,
                .build_file_path = build_file_path,
                .dependencies = self.manifest_dependencies,
            },
        };
        const cache_key_hex = computeManifestCacheKeyHex(alloc, metadata_inputs, config, self.active_manager_source_path, self.concurrency_kernel_key, null) catch |err|
            return incrementalErrorOrStatus(err, error.CacheMetadataError);
        const output_filename = buildArtifactFilename(alloc, config) catch |err|
            return incrementalErrorOrStatus(err, error.CacheMetadataError);
        const cached_artifact_path = build_cache.artifactPath(alloc, ".zap-cache", cache_key_hex, output_filename) catch |err|
            return incrementalErrorOrStatus(err, error.CacheMetadataError);
        publishManifestArtifactToCache(alloc, config, self.output_path, cached_artifact_path) catch |err|
            return incrementalErrorOrStatus(err, error.CacheMetadataError);
        writeManifestCacheMetadata(alloc, metadata_inputs, config, self.output_path, cached_artifact_path, cache_key_hex, self.active_manager_source_path) catch |err|
            return incrementalErrorOrStatus(err, error.CacheMetadataError);
        profileLap(&profile_timer, "manifest metadata", .{});

        self.baseline_established = true;
    }
};

fn runWatchBuiltArtifact(
    allocator: std.mem.Allocator,
    target_name: []const u8,
    artifact_path: []const u8,
    artifact_kind: zap.builder.BuildConfig.Kind,
    artifact_target: ?[]const u8,
    run_mode: WatchRunMode,
    run_args: []const []const u8,
) void {
    switch (run_mode) {
        .none => return,
        .program, .tests => {},
    }

    if (artifact_kind != .bin) {
        std.debug.print("Error: target :{s} is {s}, not runnable\n", .{ target_name, @tagName(artifact_kind) });
        return;
    }

    if (!targetIsHostRunnable(artifact_target)) {
        if (artifact_target) |target| {
            switch (run_mode) {
                .tests => std.debug.print(
                    "Error: cannot run tests — they were cross-compiled for '{s}', " ++
                        "a foreign architecture/OS this host cannot execute.\n" ++
                        "  The test binary was written to {s}; run it on a matching target " ++
                        "(or drop -Dtarget= to test natively).\n",
                    .{ target, artifact_path },
                ),
                .program => std.debug.print(
                    "Cross-compiled for '{s}': binary written to {s}\n" ++
                        "  (not executed - it targets a foreign architecture/OS this host cannot run)\n",
                    .{ target, artifact_path },
                ),
                .none => unreachable,
            }
        }
        return;
    }

    if (run_mode == .tests) {
        std.debug.print("Running tests\n", .{});
    }

    const exit_code = compiler.runBinaryWithEnv(allocator, global_io, artifact_path, run_args, global_env_map) catch |err| {
        switch (run_mode) {
            .tests => std.debug.print("Error running tests: {}\n", .{err}),
            .program => std.debug.print("Error running program: {}\n", .{err}),
            .none => unreachable,
        }
        return;
    };
    if (exit_code != 0) {
        switch (run_mode) {
            .tests => std.debug.print("Tests exited with code {d}\n", .{exit_code}),
            .program => std.debug.print("Program exited with code {d}\n", .{exit_code}),
            .none => unreachable,
        }
    }
}

fn runWatchPipelineArtifact(
    allocator: std.mem.Allocator,
    target_name: []const u8,
    state: *const IncrementalWatchState,
    pipeline: zap.builder.BuildConfig.Pipeline,
    run_mode: WatchRunMode,
    forwarded_args: []const []const u8,
) void {
    var compiled = false;
    var ran = false;
    for (pipeline.steps) |step| {
        switch (step) {
            .compile => compiled = true,
            .run => |run_step| {
                if (!compiled) {
                    std.debug.print("Error: invalid build pipeline: run step appeared before a compile step\n", .{});
                    return;
                }
                const run_args = buildPipelineRunArgs(allocator, run_step, forwarded_args) catch {
                    std.debug.print("Error: out of memory preparing build pipeline run arguments\n", .{});
                    return;
                };
                defer allocator.free(run_args);
                runWatchBuiltArtifact(
                    allocator,
                    target_name,
                    state.output_path,
                    state.kind,
                    state.target,
                    run_mode,
                    run_args,
                );
                ran = true;
            },
        }
    }
    if (!ran) {
        std.debug.print("Error: invalid build pipeline: completed without a run step\n", .{});
    }
}

fn runWatchArtifact(
    allocator: std.mem.Allocator,
    target_name: []const u8,
    state: *const IncrementalWatchState,
    run_mode: WatchRunMode,
    run_args: []const []const u8,
) void {
    switch (run_mode) {
        .none => return,
        .program, .tests => {},
    }

    if (state.manifest_config.pipeline) |pipeline| {
        runWatchPipelineArtifact(allocator, target_name, state, pipeline, run_mode, run_args);
        return;
    }

    runWatchBuiltArtifact(
        allocator,
        target_name,
        state.output_path,
        state.kind,
        state.target,
        run_mode,
        run_args,
    );
}

const WatchPathKind = enum {
    missing,
    file,
    directory,
    other,
};

const WatchPathFingerprint = struct {
    kind: WatchPathKind,
    size: u64 = 0,
    inode: u64 = 0,
    mtime_nanos: i128 = 0,
    ctime_nanos: i128 = 0,
    content_digest: build_cache.FileDigest = [_]u8{0} ** @sizeOf(build_cache.FileDigest),
    listing_hash: u64 = 0,
};

fn watchPathFingerprint(
    allocator: std.mem.Allocator,
    path: []const u8,
    previous: ?WatchPathFingerprint,
) !WatchPathFingerprint {
    const stat = std.Io.Dir.cwd().statFile(global_io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .kind = .missing },
        else => return err,
    };

    return switch (stat.kind) {
        .file => blk: {
            if (previous) |previous_fingerprint| {
                if (previous_fingerprint.kind == .file and
                    previous_fingerprint.size == stat.size and
                    previous_fingerprint.inode == @as(u64, @intCast(stat.inode)) and
                    previous_fingerprint.mtime_nanos == stat.mtime.nanoseconds and
                    previous_fingerprint.ctime_nanos == stat.ctime.nanoseconds)
                {
                    break :blk previous_fingerprint;
                }
            }
            const fingerprint = try build_cache.fileFingerprint(allocator, path);
            defer allocator.free(fingerprint.path);
            break :blk .{
                .kind = .file,
                .size = fingerprint.size,
                .inode = fingerprint.inode,
                .mtime_nanos = fingerprint.mtime_nanos,
                .ctime_nanos = fingerprint.ctime_nanos,
                .content_digest = fingerprint.content_digest,
            };
        },
        .directory => blk: {
            const fingerprint = try build_cache.directoryFingerprint(allocator, path, false);
            defer allocator.free(fingerprint.path);
            break :blk .{
                .kind = .directory,
                .size = stat.size,
                .inode = @intCast(stat.inode),
                .mtime_nanos = stat.mtime.nanoseconds,
                .ctime_nanos = stat.ctime.nanoseconds,
                .listing_hash = fingerprint.listing_hash,
            };
        },
        else => .{
            .kind = .other,
            .size = stat.size,
            .inode = @intCast(stat.inode),
            .mtime_nanos = stat.mtime.nanoseconds,
            .ctime_nanos = stat.ctime.nanoseconds,
        },
    };
}

fn watchPathFingerprintsEqual(
    previous: WatchPathFingerprint,
    current: WatchPathFingerprint,
) bool {
    return watchPathFingerprintContentEqual(previous, current) and
        previous.size == current.size and
        previous.inode == current.inode and
        previous.mtime_nanos == current.mtime_nanos and
        previous.ctime_nanos == current.ctime_nanos;
}

fn watchPathFingerprintContentEqual(
    previous: WatchPathFingerprint,
    current: WatchPathFingerprint,
) bool {
    if (previous.kind != current.kind) return false;
    return switch (previous.kind) {
        .missing => true,
        .file => std.mem.eql(u8, previous.content_digest[0..], current.content_digest[0..]),
        .directory => previous.listing_hash == current.listing_hash,
        .other => previous.size == current.size and
            previous.inode == current.inode and
            previous.mtime_nanos == current.mtime_nanos and
            previous.ctime_nanos == current.ctime_nanos,
    };
}

const WatchSnapshot = struct {
    paths: []const []const u8,
    fingerprints: []WatchPathFingerprint,

    fn init(
        allocator: std.mem.Allocator,
        project_root: []const u8,
        target_name: []const u8,
        build_opts: std.StringHashMapUnmanaged([]const u8),
        build_overrides: BuildOverrides,
        zap_lib_dir_override: ?[]const u8,
        extra_watch_path: ?[]const u8,
    ) WatchSnapshotInitError!WatchSnapshot {
        const paths = try collectWatchPaths(allocator, project_root, target_name, build_opts, build_overrides, zap_lib_dir_override, extra_watch_path);
        errdefer freeOwnedPathSlice(allocator, paths);

        const fingerprints = try allocator.alloc(WatchPathFingerprint, paths.len);
        errdefer allocator.free(fingerprints);
        for (paths, 0..) |path, index| {
            fingerprints[index] = watchPathFingerprint(allocator, path, null) catch |err|
                return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);
        }
        return .{ .paths = paths, .fingerprints = fingerprints };
    }

    fn initProjectOnly(
        allocator: std.mem.Allocator,
        project_root: []const u8,
    ) WatchSnapshotSetupError!WatchSnapshot {
        const paths = try collectProjectWatchPathsWithoutManifest(allocator, project_root);
        errdefer freeOwnedPathSlice(allocator, paths);

        const fingerprints = try allocator.alloc(WatchPathFingerprint, paths.len);
        errdefer allocator.free(fingerprints);
        for (paths, 0..) |path, index| {
            fingerprints[index] = watchPathFingerprint(allocator, path, null) catch |err|
                return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);
        }
        return .{ .paths = paths, .fingerprints = fingerprints };
    }

    fn initFromSourceRoots(
        allocator: std.mem.Allocator,
        project_root: []const u8,
        source_roots: []const zap.discovery.SourceRoot,
        extra_watch_path: ?[]const u8,
    ) WatchSnapshotSetupError!WatchSnapshot {
        const paths = try collectWatchPathsFromSourceRoots(allocator, project_root, source_roots, extra_watch_path);
        errdefer freeOwnedPathSlice(allocator, paths);

        const fingerprints = try allocator.alloc(WatchPathFingerprint, paths.len);
        errdefer allocator.free(fingerprints);
        for (paths, 0..) |path, index| {
            fingerprints[index] = watchPathFingerprint(allocator, path, null) catch |err|
                return watchSnapshotSetupErrorOrStatus(err, error.ManifestError);
        }
        return .{ .paths = paths, .fingerprints = fingerprints };
    }

    fn deinit(self: *WatchSnapshot, allocator: std.mem.Allocator) void {
        freeOwnedPathSlice(allocator, self.paths);
        allocator.free(self.fingerprints);
        self.* = .{ .paths = &.{}, .fingerprints = &.{} };
    }

    fn changedPaths(self: *WatchSnapshot, allocator: std.mem.Allocator) ![]const []const u8 {
        var changed_paths: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer changed_paths.deinit(allocator);
        for (self.paths, 0..) |path, index| {
            const current_fingerprint = try watchPathFingerprint(allocator, path, self.fingerprints[index]);
            if (!watchPathFingerprintContentEqual(self.fingerprints[index], current_fingerprint)) {
                try changed_paths.append(allocator, path);
                self.fingerprints[index] = current_fingerprint;
            } else if (!watchPathFingerprintsEqual(self.fingerprints[index], current_fingerprint)) {
                self.fingerprints[index] = current_fingerprint;
            }
        }
        return try changed_paths.toOwnedSlice(allocator);
    }
};

test "watch snapshot detects same-size file content edits" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "bool.zap", .data = "aaaa" });

    const tmp_path = tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "bool.zap" });
    defer allocator.free(file_path);

    const paths = try allocator.alloc([]const u8, 1);
    paths[0] = try allocator.dupe(u8, file_path);
    errdefer freeOwnedPathSlice(allocator, paths);

    const fingerprints = try allocator.alloc(WatchPathFingerprint, 1);
    errdefer allocator.free(fingerprints);
    fingerprints[0] = try watchPathFingerprint(allocator, file_path, null);

    var snapshot: WatchSnapshot = .{
        .paths = paths,
        .fingerprints = fingerprints,
    };
    defer snapshot.deinit(allocator);

    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "bool.zap", .data = "bbbb" });

    const changed_paths = try snapshot.changedPaths(allocator);
    defer allocator.free(changed_paths);

    try std.testing.expectEqual(@as(usize, 1), changed_paths.len);
    try std.testing.expectEqualStrings(file_path, changed_paths[0]);
}

test "watch snapshot changedPaths preserves OutOfMemory" {
    const allocator = std.testing.allocator;
    const paths = try allocator.alloc([]const u8, 1);
    paths[0] = try allocator.dupe(u8, "missing-watch-input.zap");
    errdefer freeOwnedPathSlice(allocator, paths);

    const fingerprints = try allocator.alloc(WatchPathFingerprint, 1);
    errdefer allocator.free(fingerprints);
    fingerprints[0] = .{ .kind = .file };

    var snapshot: WatchSnapshot = .{
        .paths = paths,
        .fingerprints = fingerprints,
    };
    defer snapshot.deinit(allocator);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, snapshot.changedPaths(failing_allocator.allocator()));
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(WatchPathKind.file, snapshot.fingerprints[0].kind);
}

test "watch snapshot init failure falls back only for missing manifest sentinel" {
    switch (classifyWatchSnapshotInitFailure(error.WatchManifestMissing)) {
        .use_project_only => |reason| try std.testing.expectEqual(WatchSnapshotFallbackReason.missing_manifest, reason),
        .propagate_setup_error => return error.TestExpectedEqual,
    }

    const propagated_errors = [_]WatchSnapshotInitError{
        error.ReadError,
        error.ManifestError,
        error.ToolchainError,
        error.CacheMetadataError,
        error.OutOfMemory,
    };

    for (propagated_errors) |expected_err| {
        switch (classifyWatchSnapshotInitFailure(expected_err)) {
            .use_project_only => return error.TestExpectedEqual,
            .propagate_setup_error => |actual_err| try std.testing.expectEqual(expected_err, actual_err),
        }
    }
}

test "watch snapshot project-only fallback records absent build manifest" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(project_root);

    const build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    try std.testing.expectError(
        error.WatchManifestMissing,
        WatchSnapshot.init(allocator, project_root, "default", build_opts, .{}, null, null),
    );

    var snapshot = try WatchSnapshot.initProjectOnly(allocator, project_root);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), snapshot.paths.len);
    try std.testing.expectEqualStrings("build.zap", std.fs.path.basename(snapshot.paths[0]));
    try std.testing.expectEqual(WatchPathKind.missing, snapshot.fingerprints[0].kind);
}

test "watch snapshot source-root canonicalization failure propagates setup error" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "build.zap", .data = "" });
    tmp_dir.dir.symLink(global_io, "loop", "loop", .{}) catch return error.SkipZigTest;

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(project_root);
    const loop_path = try std.fs.path.join(allocator, &.{ project_root, "loop" });
    defer allocator.free(loop_path);
    const source_roots = [_]zap.discovery.SourceRoot{.{
        .name = "project",
        .path = loop_path,
    }};

    try std.testing.expectError(
        error.ManifestError,
        WatchSnapshot.initFromSourceRoots(allocator, project_root, &source_roots, null),
    );
}

fn refreshWatchSnapshot(
    snapshot: *WatchSnapshot,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    zap_lib_dir_override: ?[]const u8,
    extra_watch_path: ?[]const u8,
) !void {
    const new_snapshot = WatchSnapshot.init(allocator, project_root, target_name, build_opts, build_overrides, zap_lib_dir_override, extra_watch_path) catch |err|
        return refreshWatchSnapshotInitError(err);
    snapshot.deinit(allocator);
    snapshot.* = new_snapshot;
}

fn refreshWatchSnapshotFromSourceRoots(
    snapshot: *WatchSnapshot,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    source_roots: []const zap.discovery.SourceRoot,
    extra_watch_path: ?[]const u8,
) !void {
    const new_snapshot = try WatchSnapshot.initFromSourceRoots(allocator, project_root, source_roots, extra_watch_path);
    snapshot.deinit(allocator);
    snapshot.* = new_snapshot;
}

const MANIFEST_DAEMON_DIR = ".zap-cache/daemon";
const MANIFEST_DAEMON_REQUEST_MAGIC: u32 = 0x5a_44_52_31; // "ZDR1"
const MANIFEST_DAEMON_RESPONSE_MAGIC: u32 = 0x5a_44_53_31; // "ZDS1"
const MANIFEST_DAEMON_PROTOCOL_VERSION: u16 = 5;
const MANIFEST_DAEMON_IDLE_TIMEOUT_MS: i32 = 5 * 60 * 1000;
const MANIFEST_DAEMON_REQUEST_DISPATCH_TIMEOUT_MS: i64 = 2 * 1000;
const MANIFEST_DAEMON_REQUEST_HEADER_LEN: usize = 7;

const ManifestDaemonRequestMode = enum(u8) {
    warm = 1,
    build = 2,
    shutdown = 3,
};

fn manifestDaemonRequestRequiresSourceRecheck(
    mode: ManifestDaemonRequestMode,
    had_incremental_state: bool,
    changed_path_count: usize,
) bool {
    // A freshly-created daemon state only owns a Zig compilation context.
    // It has not injected Zap ZIR, linked an artifact, or published metadata
    // yet. The first request must therefore run the normal rebuild path so the
    // daemon's backend state and manifest snapshot are tied to the same source
    // bytes before either warm or build requests can reuse it.
    if (!had_incremental_state) return true;
    return mode == .build or changed_path_count > 0;
}

const ManifestDaemonRequest = struct {
    mode: ManifestDaemonRequestMode,
    invocation_identity: build_cache.InvocationIdentity,
    response_path: ?[]const u8,
    progress_path: ?[]const u8,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    collect_arc_stats: bool,
    trace_enabled: bool,
    zap_lib_dir_override: ?[]const u8,
};

const ManifestDaemonResponseStatus = enum(u8) {
    ok = 0,
    failed = 1,
};

const ManifestDaemonResponse = union(enum) {
    ok: BuildArtifact,
    failed: []const u8,
};

fn deinitManifestDaemonBuildOverrides(allocator: std.mem.Allocator, overrides: BuildOverrides) void {
    if (overrides.memory) |memory| allocator.free(memory);
    if (overrides.target) |target| allocator.free(target);
    if (overrides.cpu) |cpu| allocator.free(cpu);
}

fn deinitManifestDaemonBuildOpts(
    allocator: std.mem.Allocator,
    build_opts: std.StringHashMapUnmanaged([]const u8),
) void {
    var mutable_build_opts = build_opts;
    var iterator = mutable_build_opts.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    mutable_build_opts.deinit(allocator);
}

fn deinitManifestDaemonRequest(allocator: std.mem.Allocator, request: ManifestDaemonRequest) void {
    if (request.response_path) |response_path| allocator.free(response_path);
    if (request.progress_path) |progress_path| allocator.free(progress_path);
    allocator.free(request.project_root);
    allocator.free(request.target_name);
    deinitManifestDaemonBuildOpts(allocator, request.build_opts);
    deinitManifestDaemonBuildOverrides(allocator, request.build_overrides);
    if (request.zap_lib_dir_override) |zap_lib_dir_override| allocator.free(zap_lib_dir_override);
}

fn deinitManifestDaemonResponse(allocator: std.mem.Allocator, response: ManifestDaemonResponse) void {
    switch (response) {
        .ok => |artifact| artifact.deinit(allocator),
        .failed => |message| allocator.free(message),
    }
}

const ManifestDaemonFallbackReason = enum {
    daemon_unavailable,
    stale_artifact,
};

const ManifestDaemonBuildResult = union(enum) {
    artifact: BuildArtifact,
    fallback: ManifestDaemonFallbackReason,
};

const ManifestDaemonWarmResult = enum {
    sent,
    pending_request,
};

const ManifestDaemonState = struct {
    invocation_identity: ?build_cache.InvocationIdentity = null,
    incremental_state: ?IncrementalWatchState = null,
    watch_snapshot: ?WatchSnapshot = null,

    fn deinit(self: *ManifestDaemonState, allocator: std.mem.Allocator) void {
        if (self.watch_snapshot) |*snapshot| snapshot.deinit(allocator);
        if (self.incremental_state) |*state| state.deinit();
        self.* = .{};
    }
};

fn manifestDaemonIdentityHexAlloc(alloc: std.mem.Allocator, invocation_identity: build_cache.InvocationIdentity) ![]const u8 {
    return digestHexAlloc(alloc, invocation_identity);
}

fn manifestDaemonEndpointPath(alloc: std.mem.Allocator, invocation_identity: build_cache.InvocationIdentity) ![]const u8 {
    const identity_hex = try manifestDaemonIdentityHexAlloc(alloc, invocation_identity);
    defer alloc.free(identity_hex);
    return std.fmt.allocPrint(alloc, "{s}/{s}.fifo", .{ MANIFEST_DAEMON_DIR, identity_hex });
}

fn manifestDaemonLogPath(alloc: std.mem.Allocator, invocation_identity: build_cache.InvocationIdentity) ![]const u8 {
    const identity_hex = try manifestDaemonIdentityHexAlloc(alloc, invocation_identity);
    defer alloc.free(identity_hex);
    return std.fmt.allocPrint(alloc, "{s}/{s}.log", .{ MANIFEST_DAEMON_DIR, identity_hex });
}

fn manifestDaemonPidPath(alloc: std.mem.Allocator, invocation_identity: build_cache.InvocationIdentity) ![]const u8 {
    const identity_hex = try manifestDaemonIdentityHexAlloc(alloc, invocation_identity);
    defer alloc.free(identity_hex);
    return std.fmt.allocPrint(alloc, "{s}/{s}.pid", .{ MANIFEST_DAEMON_DIR, identity_hex });
}

fn manifestDaemonPidPathFromEndpointPath(alloc: std.mem.Allocator, endpoint_path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, endpoint_path, ".fifo")) {
        return std.fmt.allocPrint(alloc, "{s}.pid", .{endpoint_path[0 .. endpoint_path.len - ".fifo".len]});
    }
    return std.fmt.allocPrint(alloc, "{s}.pid", .{endpoint_path});
}

fn manifestDaemonStartLockPath(alloc: std.mem.Allocator, invocation_identity: build_cache.InvocationIdentity) ![]const u8 {
    const identity_hex = try manifestDaemonIdentityHexAlloc(alloc, invocation_identity);
    defer alloc.free(identity_hex);
    return std.fmt.allocPrint(alloc, "{s}/{s}.start-lock", .{ MANIFEST_DAEMON_DIR, identity_hex });
}

fn manifestDaemonRequestPath(alloc: std.mem.Allocator, invocation_identity: build_cache.InvocationIdentity, request_id: u64) ![]const u8 {
    const identity_hex = try manifestDaemonIdentityHexAlloc(alloc, invocation_identity);
    defer alloc.free(identity_hex);
    return std.fmt.allocPrint(alloc, "{s}/{s}.{x:0>16}.req", .{ MANIFEST_DAEMON_DIR, identity_hex, request_id });
}

fn manifestDaemonRequestAckPath(alloc: std.mem.Allocator, request_path: []const u8) ![]const u8 {
    if (!std.mem.endsWith(u8, request_path, ".req")) return error.InvalidDaemonProtocol;
    return std.fmt.allocPrint(alloc, "{s}.ack", .{request_path[0 .. request_path.len - ".req".len]});
}

fn manifestDaemonResponsePath(alloc: std.mem.Allocator, invocation_identity: build_cache.InvocationIdentity, request_id: u64) ![]const u8 {
    const identity_hex = try manifestDaemonIdentityHexAlloc(alloc, invocation_identity);
    defer alloc.free(identity_hex);
    return std.fmt.allocPrint(alloc, "{s}/{s}.{x:0>16}.resp", .{ MANIFEST_DAEMON_DIR, identity_hex, request_id });
}

fn manifestDaemonProgressPath(alloc: std.mem.Allocator, invocation_identity: build_cache.InvocationIdentity, request_id: u64) ![]const u8 {
    const identity_hex = try manifestDaemonIdentityHexAlloc(alloc, invocation_identity);
    defer alloc.free(identity_hex);
    return std.fmt.allocPrint(alloc, "{s}/{s}.{x:0>16}.progress", .{ MANIFEST_DAEMON_DIR, identity_hex, request_id });
}

const MANIFEST_DAEMON_PROGRESS_MAGIC: u32 = 0x5a_44_50_31; // "ZDP1"
const MANIFEST_DAEMON_PROGRESS_VERSION: u16 = 1;
const MANIFEST_DAEMON_PROGRESS_HEADER_LEN: usize = 11;

const ManifestDaemonProgressSetupError = error{
    OutOfMemory,
    ManifestDaemonProgressSetupFailed,
};

const ManifestDaemonProgressWriterError = ManifestDaemonProgressSetupError || error{
    ManifestDaemonProgressRecordTooLarge,
    ManifestDaemonProgressWriteFailed,
};

const ManifestDaemonProgressApplyError = std.mem.Allocator.Error || zap.progress.ProgressError || error{
    InvalidDaemonProgress,
};

const ManifestDaemonProgressPollError = ManifestDaemonProgressApplyError || error{
    ManifestDaemonProgressReadFailed,
};

fn manifestDaemonProgressSetupError(err: anyerror) ManifestDaemonProgressSetupError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ManifestDaemonProgressSetupFailed,
    };
}

fn manifestDaemonProgressWriteError(err: anyerror) ManifestDaemonProgressWriterError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ManifestDaemonProgressRecordTooLarge => error.ManifestDaemonProgressRecordTooLarge,
        else => error.ManifestDaemonProgressWriteFailed,
    };
}

const ManifestDaemonProgressTag = enum(u8) {
    stage = 1,
    begin = 2,
    update_label = 3,
    update_current_item = 4,
    set_completed_count = 5,
    complete_one = 6,
    finish = 7,
    cache_event = 8,
    output = 9,
};

const ManifestDaemonProgressEvent = union(ManifestDaemonProgressTag) {
    stage: []const u8,
    begin: struct {
        parent_id: zap.progress.NodeId,
        node_id: zap.progress.NodeId,
        label: []const u8,
        options: zap.progress.NodeOptions,
    },
    update_label: struct {
        node_id: zap.progress.NodeId,
        label: []const u8,
    },
    update_current_item: struct {
        node_id: zap.progress.NodeId,
        current_item: []const u8,
    },
    set_completed_count: struct {
        node_id: zap.progress.NodeId,
        completed_count: usize,
    },
    complete_one: zap.progress.NodeId,
    finish: struct {
        node_id: zap.progress.NodeId,
        result: zap.progress.NodeResult,
    },
    cache_event: struct {
        node_id: zap.progress.NodeId,
        kind: zap.progress.CacheEventKind,
        label: []const u8,
        item: []const u8,
    },
    output: []const u8,
};

const ProgressPayloadReader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn take(self: *ProgressPayloadReader, len: usize) ![]const u8 {
        if (self.index > self.bytes.len) return error.InvalidDaemonProgress;
        if (len > self.bytes.len - self.index) return error.InvalidDaemonProgress;
        const out = self.bytes[self.index..][0..len];
        self.index += len;
        return out;
    }

    fn takeU8(self: *ProgressPayloadReader) !u8 {
        return (try self.take(1))[0];
    }

    fn takeU32(self: *ProgressPayloadReader) !u32 {
        const bytes = try self.take(4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn takeU64(self: *ProgressPayloadReader) !u64 {
        const bytes = try self.take(8);
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    fn takeString(self: *ProgressPayloadReader) ![]const u8 {
        const len = try self.takeU32();
        return try self.take(len);
    }

    fn takeNodeId(self: *ProgressPayloadReader) !zap.progress.NodeId {
        return .{
            .index = try self.takeU8(),
            .generation = try self.takeU32(),
        };
    }

    fn takeNodeOptions(self: *ProgressPayloadReader) !zap.progress.NodeOptions {
        const has_estimated_total = try self.takeU8();
        const estimated_total: ?usize = switch (has_estimated_total) {
            0 => null,
            1 => std.math.cast(usize, try self.takeU64()) orelse return error.InvalidDaemonProgress,
            else => return error.InvalidDaemonProgress,
        };
        return .{ .estimated_total = estimated_total };
    }

    fn finish(self: *ProgressPayloadReader) !void {
        if (self.index != self.bytes.len) return error.InvalidDaemonProgress;
    }
};

fn writeManifestDaemonProgressString(writer: *std.Io.Writer, value: []const u8) !void {
    const len = std.math.cast(u32, value.len) orelse return error.ManifestDaemonProgressRecordTooLarge;
    try writer.writeInt(u32, len, .little);
    try writer.writeAll(value);
}

fn writeManifestDaemonProgressNodeId(writer: *std.Io.Writer, node_id: zap.progress.NodeId) !void {
    try writer.writeByte(node_id.index);
    try writer.writeInt(u32, node_id.generation, .little);
}

fn writeManifestDaemonProgressNodeOptions(writer: *std.Io.Writer, options: zap.progress.NodeOptions) !void {
    try writer.writeByte(if (options.estimated_total != null) 1 else 0);
    if (options.estimated_total) |estimated_total| {
        try writer.writeInt(u64, @intCast(estimated_total), .little);
    }
}

fn writeManifestDaemonProgressResult(writer: *std.Io.Writer, result: zap.progress.NodeResult) !void {
    try writer.writeByte(switch (result) {
        .succeeded => 0,
        .failed => 1,
        .skipped => 2,
        .cancelled => 3,
    });
}

fn readManifestDaemonProgressResult(reader: *ProgressPayloadReader) !zap.progress.NodeResult {
    return switch (try reader.takeU8()) {
        0 => .succeeded,
        1 => .failed,
        2 => .skipped,
        3 => .cancelled,
        else => error.InvalidDaemonProgress,
    };
}

fn writeManifestDaemonProgressCacheKind(writer: *std.Io.Writer, kind: zap.progress.CacheEventKind) !void {
    try writer.writeByte(switch (kind) {
        .hit => 0,
        .miss => 1,
    });
}

fn readManifestDaemonProgressCacheKind(reader: *ProgressPayloadReader) !zap.progress.CacheEventKind {
    return switch (try reader.takeU8()) {
        0 => .hit,
        1 => .miss,
        else => error.InvalidDaemonProgress,
    };
}

fn writeManifestDaemonProgressPayload(writer: *std.Io.Writer, event: ManifestDaemonProgressEvent) !void {
    switch (event) {
        .stage => |message| try writeManifestDaemonProgressString(writer, message),
        .output => |message| try writeManifestDaemonProgressString(writer, message),
        .begin => |begin| {
            try writeManifestDaemonProgressNodeId(writer, begin.parent_id);
            try writeManifestDaemonProgressNodeId(writer, begin.node_id);
            try writeManifestDaemonProgressString(writer, begin.label);
            try writeManifestDaemonProgressNodeOptions(writer, begin.options);
        },
        .update_label => |update| {
            try writeManifestDaemonProgressNodeId(writer, update.node_id);
            try writeManifestDaemonProgressString(writer, update.label);
        },
        .update_current_item => |update| {
            try writeManifestDaemonProgressNodeId(writer, update.node_id);
            try writeManifestDaemonProgressString(writer, update.current_item);
        },
        .set_completed_count => |update| {
            try writeManifestDaemonProgressNodeId(writer, update.node_id);
            try writer.writeInt(u64, @intCast(update.completed_count), .little);
        },
        .complete_one => |node_id| try writeManifestDaemonProgressNodeId(writer, node_id),
        .finish => |finish| {
            try writeManifestDaemonProgressNodeId(writer, finish.node_id);
            try writeManifestDaemonProgressResult(writer, finish.result);
        },
        .cache_event => |cache_event| {
            try writeManifestDaemonProgressNodeId(writer, cache_event.node_id);
            try writeManifestDaemonProgressCacheKind(writer, cache_event.kind);
            try writeManifestDaemonProgressString(writer, cache_event.label);
            try writeManifestDaemonProgressString(writer, cache_event.item);
        },
    }
}

fn manifestDaemonProgressTag(event: ManifestDaemonProgressEvent) ManifestDaemonProgressTag {
    return switch (event) {
        .stage => .stage,
        .output => .output,
        .begin => .begin,
        .update_label => .update_label,
        .update_current_item => .update_current_item,
        .set_completed_count => .set_completed_count,
        .complete_one => .complete_one,
        .finish => .finish,
        .cache_event => .cache_event,
    };
}

fn writeManifestDaemonProgressRecord(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    event: ManifestDaemonProgressEvent,
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try writeManifestDaemonProgressPayload(&payload.writer, event);

    try writer.writeInt(u32, MANIFEST_DAEMON_PROGRESS_MAGIC, .little);
    try writer.writeInt(u16, MANIFEST_DAEMON_PROGRESS_VERSION, .little);
    try writer.writeByte(@intFromEnum(manifestDaemonProgressTag(event)));
    const payload_len = std.math.cast(u32, payload.written().len) orelse return error.ManifestDaemonProgressRecordTooLarge;
    try writer.writeInt(u32, payload_len, .little);
    try writer.writeAll(payload.written());
}

fn serializeManifestDaemonProgressRecord(allocator: std.mem.Allocator, event: ManifestDaemonProgressEvent) ![]const u8 {
    var record: std.Io.Writer.Allocating = .init(allocator);
    errdefer record.deinit();
    try writeManifestDaemonProgressRecord(allocator, &record.writer, event);
    return try record.toOwnedSlice();
}

fn readManifestDaemonProgressPayload(tag: ManifestDaemonProgressTag, payload: []const u8) !ManifestDaemonProgressEvent {
    var reader: ProgressPayloadReader = .{ .bytes = payload };
    const event: ManifestDaemonProgressEvent = switch (tag) {
        .stage => .{ .stage = try reader.takeString() },
        .output => .{ .output = try reader.takeString() },
        .begin => .{ .begin = .{
            .parent_id = try reader.takeNodeId(),
            .node_id = try reader.takeNodeId(),
            .label = try reader.takeString(),
            .options = try reader.takeNodeOptions(),
        } },
        .update_label => .{ .update_label = .{
            .node_id = try reader.takeNodeId(),
            .label = try reader.takeString(),
        } },
        .update_current_item => .{ .update_current_item = .{
            .node_id = try reader.takeNodeId(),
            .current_item = try reader.takeString(),
        } },
        .set_completed_count => .{ .set_completed_count = .{
            .node_id = try reader.takeNodeId(),
            .completed_count = std.math.cast(usize, try reader.takeU64()) orelse return error.InvalidDaemonProgress,
        } },
        .complete_one => .{ .complete_one = try reader.takeNodeId() },
        .finish => .{ .finish = .{
            .node_id = try reader.takeNodeId(),
            .result = try readManifestDaemonProgressResult(&reader),
        } },
        .cache_event => .{ .cache_event = .{
            .node_id = try reader.takeNodeId(),
            .kind = try readManifestDaemonProgressCacheKind(&reader),
            .label = try reader.takeString(),
            .item = try reader.takeString(),
        } },
    };
    try reader.finish();
    return event;
}

fn readManifestDaemonProgressRecord(bytes: []const u8, consumed_len: *usize) !?ManifestDaemonProgressEvent {
    consumed_len.* = 0;
    if (bytes.len < MANIFEST_DAEMON_PROGRESS_HEADER_LEN) return null;

    const magic = std.mem.readInt(u32, bytes[0..4], .little);
    if (magic != MANIFEST_DAEMON_PROGRESS_MAGIC) return error.InvalidDaemonProgress;
    const version = std.mem.readInt(u16, bytes[4..6], .little);
    if (version != MANIFEST_DAEMON_PROGRESS_VERSION) return error.InvalidDaemonProgress;
    const tag: ManifestDaemonProgressTag = switch (bytes[6]) {
        1 => .stage,
        2 => .begin,
        3 => .update_label,
        4 => .update_current_item,
        5 => .set_completed_count,
        6 => .complete_one,
        7 => .finish,
        8 => .cache_event,
        9 => .output,
        else => return error.InvalidDaemonProgress,
    };
    const payload_len = std.mem.readInt(u32, bytes[7..11], .little);
    const payload_len_usize = std.math.cast(usize, payload_len) orelse return error.InvalidDaemonProgress;
    const record_len = std.math.add(usize, MANIFEST_DAEMON_PROGRESS_HEADER_LEN, payload_len_usize) catch return error.InvalidDaemonProgress;
    if (bytes.len < record_len) return null;

    consumed_len.* = record_len;
    return try readManifestDaemonProgressPayload(tag, bytes[MANIFEST_DAEMON_PROGRESS_HEADER_LEN..record_len]);
}

fn manifestDaemonProgressNodeKey(node_id: zap.progress.NodeId) u64 {
    return (@as(u64, node_id.generation) << 8) | node_id.index;
}

const ManifestDaemonProgressWriter = struct {
    allocator: std.mem.Allocator,
    file: ?std.Io.File,
    failure: ?ManifestDaemonProgressWriterError = null,

    fn init(allocator: std.mem.Allocator, progress_path: []const u8) ManifestDaemonProgressSetupError!ManifestDaemonProgressWriter {
        if (std.fs.path.dirname(progress_path)) |dir| {
            std.Io.Dir.cwd().createDirPath(global_io, dir) catch |err| return manifestDaemonProgressSetupError(err);
        }
        const file = std.Io.Dir.cwd().createFile(global_io, progress_path, .{ .truncate = false }) catch |err| return manifestDaemonProgressSetupError(err);
        return .{
            .allocator = allocator,
            .file = file,
        };
    }

    fn deinit(self: *ManifestDaemonProgressWriter) void {
        if (self.file) |file| file.close(global_io);
        self.file = null;
    }

    fn sink(self: *ManifestDaemonProgressWriter) zap.progress.EventSink {
        return .{
            .context = self,
            .stageFn = stage,
            .outputFn = output,
            .beginFn = begin,
            .updateLabelFn = updateLabel,
            .updateCurrentItemFn = updateCurrentItem,
            .setCompletedCountFn = setCompletedCount,
            .completeOneFn = completeOne,
            .finishFn = finish,
            .cacheEventFn = cacheEvent,
        };
    }

    fn write(self: *ManifestDaemonProgressWriter, event: ManifestDaemonProgressEvent) void {
        if (self.failure != null) return;
        const file = self.file orelse {
            self.failure = error.ManifestDaemonProgressWriteFailed;
            return;
        };
        const record = serializeManifestDaemonProgressRecord(self.allocator, event) catch |err| {
            self.failure = manifestDaemonProgressWriteError(err);
            return;
        };
        defer self.allocator.free(record);
        file.writeStreamingAll(global_io, record) catch {
            self.failure = error.ManifestDaemonProgressWriteFailed;
        };
    }

    fn check(self: *const ManifestDaemonProgressWriter) ManifestDaemonProgressWriterError!void {
        if (self.failure) |err| return err;
    }

    fn fromContext(context: *anyopaque) *ManifestDaemonProgressWriter {
        return @ptrCast(@alignCast(context));
    }

    fn stage(context: *anyopaque, message: []const u8) void {
        fromContext(context).write(.{ .stage = message });
    }

    fn output(context: *anyopaque, message: []const u8) void {
        fromContext(context).write(.{ .output = message });
    }

    fn begin(
        context: *anyopaque,
        parent_id: zap.progress.NodeId,
        node_id: zap.progress.NodeId,
        label: []const u8,
        options: zap.progress.NodeOptions,
    ) void {
        fromContext(context).write(.{ .begin = .{
            .parent_id = parent_id,
            .node_id = node_id,
            .label = label,
            .options = options,
        } });
    }

    fn updateLabel(context: *anyopaque, node_id: zap.progress.NodeId, label: []const u8) void {
        fromContext(context).write(.{ .update_label = .{
            .node_id = node_id,
            .label = label,
        } });
    }

    fn updateCurrentItem(context: *anyopaque, node_id: zap.progress.NodeId, current_item: []const u8) void {
        fromContext(context).write(.{ .update_current_item = .{
            .node_id = node_id,
            .current_item = current_item,
        } });
    }

    fn setCompletedCount(context: *anyopaque, node_id: zap.progress.NodeId, completed_count: usize) void {
        fromContext(context).write(.{ .set_completed_count = .{
            .node_id = node_id,
            .completed_count = completed_count,
        } });
    }

    fn completeOne(context: *anyopaque, node_id: zap.progress.NodeId) void {
        fromContext(context).write(.{ .complete_one = node_id });
    }

    fn finish(context: *anyopaque, node_id: zap.progress.NodeId, result: zap.progress.NodeResult) void {
        fromContext(context).write(.{ .finish = .{
            .node_id = node_id,
            .result = result,
        } });
    }

    fn cacheEvent(
        context: *anyopaque,
        node_id: zap.progress.NodeId,
        kind: zap.progress.CacheEventKind,
        label: []const u8,
        item: []const u8,
    ) void {
        fromContext(context).write(.{ .cache_event = .{
            .node_id = node_id,
            .kind = kind,
            .label = label,
            .item = item,
        } });
    }
};

const ManifestDaemonProgressPoller = struct {
    allocator: std.mem.Allocator,
    string_arena: std.heap.ArenaAllocator,
    fd: std.posix.fd_t,
    parent_node: ?zap.progress.Node,
    read_offset: usize = 0,
    pending_bytes: std.ArrayListUnmanaged(u8) = .empty,
    nodes: std.AutoHashMap(u64, zap.progress.Node),
    node_order: std.ArrayListUnmanaged(u64) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        progress_path: []const u8,
        parent_node: ?zap.progress.Node,
    ) ManifestDaemonProgressSetupError!ManifestDaemonProgressPoller {
        const fd = std.posix.openat(std.posix.AT.FDCWD, progress_path, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
        }, 0) catch |err| return manifestDaemonProgressSetupError(err);
        return .{
            .allocator = allocator,
            .string_arena = std.heap.ArenaAllocator.init(allocator),
            .fd = fd,
            .parent_node = parent_node,
            .nodes = std.AutoHashMap(u64, zap.progress.Node).init(allocator),
        };
    }

    fn deinit(self: *ManifestDaemonProgressPoller) void {
        closeFd(self.fd, false);
        self.finishRemaining(.cancelled);
        self.node_order.deinit(self.allocator);
        self.pending_bytes.deinit(self.allocator);
        self.nodes.deinit();
        self.string_arena.deinit();
    }

    fn poll(self: *ManifestDaemonProgressPoller) ManifestDaemonProgressPollError!void {
        try self.readAvailable();
        try self.consumePending();
    }

    fn readAvailable(self: *ManifestDaemonProgressPoller) ManifestDaemonProgressPollError!void {
        var buffer: [8192]u8 = undefined;
        while (true) {
            const bytes_read = try preadManifestDaemonProgress(self.fd, &buffer, self.read_offset);
            if (bytes_read == 0) return;
            try self.pending_bytes.appendSlice(self.allocator, buffer[0..bytes_read]);
            self.read_offset += bytes_read;
            if (bytes_read < buffer.len) return;
        }
    }

    fn consumePending(self: *ManifestDaemonProgressPoller) ManifestDaemonProgressPollError!void {
        var consumed_total: usize = 0;
        while (consumed_total < self.pending_bytes.items.len) {
            var consumed_len: usize = 0;
            const event = try readManifestDaemonProgressRecord(self.pending_bytes.items[consumed_total..], &consumed_len) orelse break;
            try self.apply(event);
            consumed_total += consumed_len;
        }

        if (consumed_total == 0) return;
        if (consumed_total == self.pending_bytes.items.len) {
            self.pending_bytes.clearRetainingCapacity();
            return;
        }

        const remaining_len = self.pending_bytes.items.len - consumed_total;
        std.mem.copyForwards(u8, self.pending_bytes.items[0..remaining_len], self.pending_bytes.items[consumed_total..]);
        self.pending_bytes.shrinkRetainingCapacity(remaining_len);
    }

    fn apply(self: *ManifestDaemonProgressPoller, event: ManifestDaemonProgressEvent) ManifestDaemonProgressApplyError!void {
        switch (event) {
            .stage => |message| {
                const node = self.parent_node orelse return error.InvalidDaemonProgress;
                const owned_message = try self.dupeString(message);
                node.updateCurrentItem(owned_message);
            },
            .output => |message| {
                const node = self.parent_node orelse return error.InvalidDaemonProgress;
                const owned_message = try self.dupeString(message);
                node.output(owned_message);
            },
            .begin => |begin| {
                const maybe_parent = if (begin.parent_id.index == 0)
                    self.parent_node
                else
                    self.nodes.get(manifestDaemonProgressNodeKey(begin.parent_id));
                const parent = maybe_parent orelse return error.InvalidDaemonProgress;
                const owned_label = try self.dupeString(begin.label);
                const local_node = try parent.start(owned_label, begin.options);
                const key = manifestDaemonProgressNodeKey(begin.node_id);
                if (self.nodes.get(key) != null) {
                    local_node.finish(.cancelled);
                    return error.InvalidDaemonProgress;
                }
                self.nodes.put(key, local_node) catch |err| {
                    local_node.finish(.cancelled);
                    return err;
                };
                self.node_order.append(self.allocator, key) catch |err| {
                    if (self.nodes.fetchRemove(key)) |entry| entry.value.finish(.cancelled);
                    return err;
                };
            },
            .update_label => |update| {
                const node = self.nodes.get(manifestDaemonProgressNodeKey(update.node_id)) orelse return error.InvalidDaemonProgress;
                const owned_label = try self.dupeString(update.label);
                node.updateLabel(owned_label);
            },
            .update_current_item => |update| {
                const node = self.nodes.get(manifestDaemonProgressNodeKey(update.node_id)) orelse return error.InvalidDaemonProgress;
                const owned_current_item = try self.dupeString(update.current_item);
                node.updateCurrentItem(owned_current_item);
            },
            .set_completed_count => |update| {
                const node = self.nodes.get(manifestDaemonProgressNodeKey(update.node_id)) orelse return error.InvalidDaemonProgress;
                node.setCompletedCount(update.completed_count);
            },
            .complete_one => |node_id| {
                const node = self.nodes.get(manifestDaemonProgressNodeKey(node_id)) orelse return error.InvalidDaemonProgress;
                node.completeOne();
            },
            .finish => |finish| {
                const key = manifestDaemonProgressNodeKey(finish.node_id);
                const entry = self.nodes.fetchRemove(key) orelse return error.InvalidDaemonProgress;
                entry.value.finish(finish.result);
            },
            .cache_event => |cache_event| {
                const node = self.nodes.get(manifestDaemonProgressNodeKey(cache_event.node_id)) orelse return error.InvalidDaemonProgress;
                const owned_label = try self.dupeString(cache_event.label);
                const owned_item = try self.dupeString(cache_event.item);
                switch (cache_event.kind) {
                    .hit => node.cacheHit(owned_label, owned_item),
                    .miss => node.cacheMiss(owned_label, owned_item),
                }
            },
        }
    }

    fn dupeString(self: *ManifestDaemonProgressPoller, value: []const u8) ![]const u8 {
        return try self.string_arena.allocator().dupe(u8, value);
    }

    fn finishRemaining(self: *ManifestDaemonProgressPoller, result: zap.progress.NodeResult) void {
        var remaining = self.node_order.items.len;
        while (remaining > 0) {
            remaining -= 1;
            const key = self.node_order.items[remaining];
            if (self.nodes.fetchRemove(key)) |entry| entry.value.finish(result);
        }
        self.node_order.clearRetainingCapacity();
    }
};

fn preadManifestDaemonProgress(fd: std.posix.fd_t, buffer: []u8, offset: usize) !usize {
    while (true) {
        const rc = std.posix.system.pread(fd, buffer.ptr, buffer.len, @intCast(offset));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.ManifestDaemonProgressReadFailed,
        }
    }
}

test "manifest daemon progress records round trip structured events" {
    const allocator = std.testing.allocator;
    const remote_parent: zap.progress.NodeId = .{ .index = 0, .generation = 1 };
    const remote_node: zap.progress.NodeId = .{ .index = 7, .generation = 42 };
    const bytes = try serializeManifestDaemonProgressRecord(allocator, .{ .begin = .{
        .parent_id = remote_parent,
        .node_id = remote_node,
        .label = "Frontend compile",
        .options = .{ .estimated_total = 12 },
    } });
    defer allocator.free(bytes);

    var consumed_len: usize = 0;
    const event = (try readManifestDaemonProgressRecord(bytes, &consumed_len)).?;
    try std.testing.expectEqual(bytes.len, consumed_len);
    switch (event) {
        .begin => |begin| {
            try std.testing.expectEqual(remote_parent, begin.parent_id);
            try std.testing.expectEqual(remote_node, begin.node_id);
            try std.testing.expectEqualStrings("Frontend compile", begin.label);
            try std.testing.expectEqual(@as(?usize, 12), begin.options.estimated_total);
        },
        else => return error.UnexpectedProgressEvent,
    }
}

test "manifest daemon progress parser waits for complete records" {
    const allocator = std.testing.allocator;
    const bytes = try serializeManifestDaemonProgressRecord(allocator, .{ .stage = "Backend: compiling ZIR and linking" });
    defer allocator.free(bytes);

    var consumed_len: usize = 123;
    try std.testing.expect((try readManifestDaemonProgressRecord(bytes[0 .. bytes.len - 1], &consumed_len)) == null);
    try std.testing.expectEqual(@as(usize, 0), consumed_len);

    const event = (try readManifestDaemonProgressRecord(bytes, &consumed_len)).?;
    try std.testing.expectEqual(bytes.len, consumed_len);
    switch (event) {
        .stage => |message| try std.testing.expectEqualStrings("Backend: compiling ZIR and linking", message),
        else => return error.UnexpectedProgressEvent,
    }
}

test "manifest daemon progress records round trip direct output events" {
    const allocator = std.testing.allocator;
    const bytes = try serializeManifestDaemonProgressRecord(allocator, .{ .output = "Zig: semantic analysis, codegen, link\n" });
    defer allocator.free(bytes);

    var consumed_len: usize = 0;
    const event = (try readManifestDaemonProgressRecord(bytes, &consumed_len)).?;
    try std.testing.expectEqual(bytes.len, consumed_len);
    switch (event) {
        .output => |message| try std.testing.expectEqualStrings("Zig: semantic analysis, codegen, link\n", message),
        else => return error.UnexpectedProgressEvent,
    }
}

test "P4J2: manifest daemon request reports requested progress setup failure" {
    const allocator = std.testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xd5);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);

    const request_path = try manifestDaemonRequestPath(allocator, invocation_identity, 0x1237);
    defer allocator.free(request_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, request_path) catch {};

    const response_path = try manifestDaemonResponsePath(allocator, invocation_identity, 0x1237);
    defer allocator.free(response_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, response_path) catch {};
    std.Io.Dir.cwd().deleteFile(global_io, response_path) catch {};

    const blocker_path = try std.fmt.allocPrint(allocator, "{s}/p4j2-progress-blocker-d5", .{MANIFEST_DAEMON_DIR});
    defer allocator.free(blocker_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, blocker_path) catch {};
    std.Io.Dir.cwd().deleteFile(global_io, blocker_path) catch {};
    try writeFile(blocker_path, "not a directory");

    const progress_path = try std.fmt.allocPrint(allocator, "{s}/stream.progress", .{blocker_path});
    defer allocator.free(progress_path);

    const build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    try writeManifestDaemonRequestFile(
        allocator,
        request_path,
        .build,
        invocation_identity,
        response_path,
        progress_path,
        ".",
        "default",
        build_opts,
        .{},
        false,
        false,
        null,
    );

    var daemon_state: ManifestDaemonState = .{};
    defer daemon_state.deinit(allocator);

    try std.testing.expect(!try handleManifestDaemonRequestFile(allocator, request_path, &daemon_state));

    const response = try readManifestDaemonResponseFile(allocator, allocator, response_path);
    defer deinitManifestDaemonResponse(allocator, response);
    switch (response) {
        .failed => |message| try std.testing.expectEqualStrings("ManifestDaemonProgressSetupFailed", message),
        .ok => return error.ExpectedManifestDaemonProgressSetupFailure,
    }
}

test "P4J2: manifest daemon progress apply propagates event allocation failure" {
    const allocator = std.testing.allocator;
    const progress_path = try std.fmt.allocPrint(allocator, "{s}/p4j2-progress-alloc-failure.progress", .{MANIFEST_DAEMON_DIR});
    defer allocator.free(progress_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, progress_path) catch {};
    std.Io.Dir.cwd().deleteFile(global_io, progress_path) catch {};
    try truncateManifestDaemonProgress(progress_path);

    var reporter = zap.progress.Reporter.init("Compiling", false);
    const root_node = reporter.rootNode();

    var fixed_buffer: [0]u8 = .{};
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    var poller = try ManifestDaemonProgressPoller.init(fixed_allocator.allocator(), progress_path, root_node);
    defer poller.deinit();

    try std.testing.expectError(
        error.OutOfMemory,
        poller.apply(.{ .stage = "Planning target :default" }),
    );
}

test "P4J2: manifest daemon progress apply propagates node start failure" {
    const allocator = std.testing.allocator;
    const progress_path = try std.fmt.allocPrint(allocator, "{s}/p4j2-progress-node-failure.progress", .{MANIFEST_DAEMON_DIR});
    defer allocator.free(progress_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, progress_path) catch {};
    std.Io.Dir.cwd().deleteFile(global_io, progress_path) catch {};
    try truncateManifestDaemonProgress(progress_path);

    var reporter = zap.progress.Reporter.init("Compiling", false);
    const root_node = reporter.rootNode();
    while (true) {
        _ = root_node.start("reserved progress slot", .{}) catch |err| {
            try std.testing.expectEqual(error.ProgressNodeCapacityExceeded, err);
            break;
        };
    }

    var poller = try ManifestDaemonProgressPoller.init(allocator, progress_path, root_node);
    defer poller.deinit();

    try std.testing.expectError(
        error.ProgressNodeCapacityExceeded,
        poller.apply(.{ .begin = .{
            .parent_id = .{ .index = 0, .generation = 1 },
            .node_id = .{ .index = 7, .generation = 42 },
            .label = "overflowing progress node",
            .options = .{},
        } }),
    );
}

test "manifest daemon request names are tied to full invocation identities" {
    var identity: build_cache.InvocationIdentity = undefined;
    @memset(&identity, 0xab);

    const identity_hex = try manifestDaemonIdentityHexAlloc(std.testing.allocator, identity);
    defer std.testing.allocator.free(identity_hex);

    const matching_name = try std.fmt.allocPrint(std.testing.allocator, "{s}.1234567890abcdef.req", .{identity_hex});
    defer std.testing.allocator.free(matching_name);
    try std.testing.expect(manifestDaemonRequestNameMatchesIdentity(matching_name, identity));
    const request_identity = parseManifestDaemonInvocationIdentityFromRequestName(matching_name).?;
    try std.testing.expectEqualSlices(u8, &identity, &request_identity);

    const endpoint_name = try std.fmt.allocPrint(std.testing.allocator, "{s}.fifo", .{identity_hex});
    defer std.testing.allocator.free(endpoint_name);
    try std.testing.expect(!manifestDaemonRequestNameMatchesIdentity(endpoint_name, identity));
    const endpoint_identity = parseManifestDaemonInvocationIdentityFromEndpointName(endpoint_name).?;
    try std.testing.expectEqualSlices(u8, &identity, &endpoint_identity);

    var other_identity = identity;
    other_identity[0] = 0xac;
    try std.testing.expect(!manifestDaemonRequestNameMatchesIdentity(matching_name, other_identity));
}

test "manifest daemon request header parser identifies warm build and shutdown modes" {
    inline for (.{
        .{ @as(u8, 1), ManifestDaemonRequestMode.warm },
        .{ @as(u8, 2), ManifestDaemonRequestMode.build },
        .{ @as(u8, 3), ManifestDaemonRequestMode.shutdown },
    }) |case| {
        var bytes: [MANIFEST_DAEMON_REQUEST_HEADER_LEN]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], MANIFEST_DAEMON_REQUEST_MAGIC, .little);
        std.mem.writeInt(u16, bytes[4..6], MANIFEST_DAEMON_PROTOCOL_VERSION, .little);
        bytes[6] = case[0];
        try std.testing.expectEqual(case[1], try readManifestDaemonRequestModeHeader(&bytes));
    }
}

test "manifest daemon response reader rejects trailing bytes" {
    const allocator = std.testing.allocator;
    const run_args = [_][]const u8{"--list"};
    const steps = [_]zap.builder.BuildConfig.Step{
        .{ .compile = .{} },
        .{ .run = .{ .args = &run_args, .forward_args = true } },
    };
    const pipeline: zap.builder.BuildConfig.Pipeline = .{ .steps = &steps };

    var serialized: std.Io.Writer.Allocating = .init(allocator);
    defer serialized.deinit();
    try serialized.writer.writeInt(u32, MANIFEST_DAEMON_RESPONSE_MAGIC, .little);
    try serialized.writer.writeInt(u16, MANIFEST_DAEMON_PROTOCOL_VERSION, .little);
    try serialized.writer.writeByte(@intFromEnum(ManifestDaemonResponseStatus.ok));
    try serialized.writer.writeByte(0);
    try writeDaemonOptionalString(&serialized.writer, "native-target");
    try writeDaemonString(&serialized.writer, "zig-out/bin/app");
    try writeDaemonPipeline(&serialized.writer, @as(?zap.builder.BuildConfig.Pipeline, pipeline));
    try serialized.writer.writeAll("trailing");

    var reader: std.Io.Reader = .fixed(serialized.written());
    try std.testing.expectError(
        error.InvalidDaemonProtocol,
        readManifestDaemonResponse(allocator, &reader),
    );
}

test "manifest daemon request reader rejects trailing bytes" {
    const allocator = std.testing.allocator;

    var invocation_identity: build_cache.InvocationIdentity = undefined;
    @memset(&invocation_identity, 0xbc);

    var build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer build_opts.deinit(allocator);
    try build_opts.put(allocator, "profile", "dev");

    var serialized: std.Io.Writer.Allocating = .init(allocator);
    defer serialized.deinit();
    try writeManifestDaemonRequest(
        &serialized.writer,
        .build,
        invocation_identity,
        "response.zapd",
        "progress.zapd",
        "/tmp/project",
        "app",
        build_opts,
        .{
            .memory = "Memory.ARC",
            .target = "aarch64-macos-none",
            .cpu = "apple_m1",
        },
        true,
        true,
        "/opt/zap/lib",
    );
    try serialized.writer.writeAll("trailing");

    var reader: std.Io.Reader = .fixed(serialized.written());
    try std.testing.expectError(
        error.InvalidDaemonProtocol,
        readManifestDaemonRequest(allocator, &reader),
    );
}

test "P4J2: manifest eval cache required write preserves serialization OOM" {
    const allocator = std.testing.allocator;

    const NoopManifestEvalCacheFileWriter = struct {
        fn writeFileAtomic(
            _: @This(),
            file_allocator: std.mem.Allocator,
            path: []const u8,
            contents: []const u8,
        ) !void {
            _ = file_allocator;
            _ = path;
            _ = contents;
        }
    };

    var identity: build_cache.InvocationIdentity = undefined;
    @memset(&identity, 0x42);
    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.OutOfMemory,
        writeRequiredManifestEvalCacheWithWriter(
            failing_allocator.allocator(),
            "unused.manifest-eval",
            identity,
            .{
                .config = .{
                    .name = "zap_test",
                    .version = "1.2.3",
                    .kind = .bin,
                },
                .dependencies = &.{},
                .result_hash = 0,
            },
            NoopManifestEvalCacheFileWriter{},
        ),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: manifest eval cache required write maps install failures to cache metadata errors" {
    const allocator = std.testing.allocator;

    const FailingManifestEvalCacheFileWriter = struct {
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

    var identity: build_cache.InvocationIdentity = undefined;
    @memset(&identity, 0x42);
    var file_writer = FailingManifestEvalCacheFileWriter{};

    try std.testing.expectError(
        error.CacheMetadataError,
        writeRequiredManifestEvalCacheWithWriter(
            allocator,
            "unused.manifest-eval",
            identity,
            .{
                .config = .{
                    .name = "zap_test",
                    .version = "1.2.3",
                    .kind = .bin,
                },
                .dependencies = &.{},
                .result_hash = 0,
            },
            &file_writer,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), file_writer.calls);
    try std.testing.expect(file_writer.bytes_len > 0);
}

test "manifest eval cache round trips full manifest config" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const cache_path = try std.fs.path.join(allocator, &.{ tmp_path, "default.manifest-eval" });
    defer allocator.free(cache_path);

    var identity: build_cache.InvocationIdentity = undefined;
    @memset(&identity, 0x42);

    var build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer build_opts.deinit(allocator);
    try build_opts.put(allocator, "feature", "enabled");
    try build_opts.put(allocator, "profile", "ci");

    const paths = [_][]const u8{ "lib/**/*.zap", "test/**/*.zap" };
    const deps = [_]zap.builder.BuildConfig.Dep{
        .{
            .name = "local_dep",
            .source = .{ .path = "../dep" },
            .local_override = "../dep-dev",
        },
        .{
            .name = "git_dep",
            .source = .{ .git = .{
                .url = "https://example.invalid/zap.git",
                .tag = "v1.2.3",
                .branch = null,
                .rev = "abcdef",
            } },
            .local_override = null,
        },
    };
    const doc_pages = [_][]const u8{ "README.md", "docs/guide.md" };
    const doc_groups = [_]zap.builder.BuildConfig.DocGroup{
        .{ .name = "Guide", .pages = &doc_pages },
    };
    const run_args = [_][]const u8{ "--list", "--color" };
    const steps = [_]zap.builder.BuildConfig.Step{
        .{ .compile = .{} },
        .{ .run = .{ .args = &run_args, .forward_args = false } },
    };

    const config: zap.builder.BuildConfig = .{
        .name = "zap_test",
        .version = "1.2.3",
        .kind = .bin,
        .root = "Main.main/0",
        .asset_name = "zap-custom-test",
        .optimize = .release_safe,
        .debug_info = .split,
        .frame_pointers = false,
        .target = "aarch64-macos",
        .cpu = "apple_m1",
        .paths = &paths,
        .deps = &deps,
        .build_opts = build_opts,
        .memory_manager = .{
            .type_name = "Memory.ARC",
            .adapter_source_path = "lib/memory/arc.zap",
        },
        .test_timeout = 1234,
        .error_style = "long",
        .multiline_errors = true,
        .source_url = "https://example.invalid/repo",
        .landing_page = "README.md",
        .doc_groups = &doc_groups,
        .pipeline = .{ .steps = &steps },
    };
    try writeManifestEvalCache(allocator, cache_path, identity, .{
        .config = config,
        .dependencies = &.{},
        .result_hash = 0xfeed_beef,
    });

    var cached = try readManifestEvalCache(allocator, allocator, cache_path, identity);
    defer cached.deinit();

    try std.testing.expectEqualStrings("zap_test", cached.eval.config.name);
    try std.testing.expectEqualStrings("1.2.3", cached.eval.config.version);
    try std.testing.expectEqual(zap.builder.BuildConfig.Kind.bin, cached.eval.config.kind);
    try std.testing.expectEqualStrings("Main.main/0", cached.eval.config.root.?);
    try std.testing.expectEqualStrings("zap-custom-test", cached.eval.config.asset_name.?);
    try std.testing.expectEqual(zap.builder.BuildConfig.Optimize.release_safe, cached.eval.config.optimize);
    try std.testing.expectEqual(zap.builder.BuildConfig.DebugInfo.split, cached.eval.config.debug_info.?);
    try std.testing.expectEqual(false, cached.eval.config.frame_pointers.?);
    try std.testing.expectEqualStrings("aarch64-macos", cached.eval.config.target.?);
    try std.testing.expectEqualStrings("apple_m1", cached.eval.config.cpu.?);
    try std.testing.expectEqualStrings("lib/**/*.zap", cached.eval.config.paths[0]);
    try std.testing.expectEqualStrings("test/**/*.zap", cached.eval.config.paths[1]);
    try std.testing.expectEqualStrings("local_dep", cached.eval.config.deps[0].name);
    try std.testing.expectEqualStrings("../dep", cached.eval.config.deps[0].source.path);
    try std.testing.expectEqualStrings("../dep-dev", cached.eval.config.deps[0].local_override.?);
    try std.testing.expectEqualStrings("git_dep", cached.eval.config.deps[1].name);
    try std.testing.expectEqualStrings("https://example.invalid/zap.git", cached.eval.config.deps[1].source.git.url);
    try std.testing.expectEqualStrings("v1.2.3", cached.eval.config.deps[1].source.git.tag.?);
    try std.testing.expectEqualStrings("abcdef", cached.eval.config.deps[1].source.git.rev.?);
    try std.testing.expectEqualStrings("enabled", cached.eval.config.build_opts.get("feature").?);
    try std.testing.expectEqualStrings("ci", cached.eval.config.build_opts.get("profile").?);
    try std.testing.expectEqualStrings("Memory.ARC", cached.eval.config.memory_manager.?.type_name);
    try std.testing.expectEqualStrings("lib/memory/arc.zap", cached.eval.config.memory_manager.?.adapter_source_path.?);
    try std.testing.expectEqual(@as(i64, 1234), cached.eval.config.test_timeout);
    try std.testing.expectEqualStrings("long", cached.eval.config.error_style.?);
    try std.testing.expect(cached.eval.config.multiline_errors);
    try std.testing.expectEqualStrings("https://example.invalid/repo", cached.eval.config.source_url.?);
    try std.testing.expectEqualStrings("README.md", cached.eval.config.landing_page.?);
    try std.testing.expectEqualStrings("Guide", cached.eval.config.doc_groups[0].name);
    try std.testing.expectEqualStrings("docs/guide.md", cached.eval.config.doc_groups[0].pages[1]);
    try std.testing.expectEqual(@as(usize, 2), cached.eval.config.pipeline.?.steps.len);
    try std.testing.expectEqualStrings("--list", cached.eval.config.pipeline.?.steps[1].run.args[0]);
    try std.testing.expect(!cached.eval.config.pipeline.?.steps[1].run.forward_args);
    try std.testing.expectEqual(@as(u64, 0xfeed_beef), cached.eval.result_hash);
}

test "manifest eval cache rejects mismatched invocation identity" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const cache_path = try std.fs.path.join(allocator, &.{ tmp_path, "default.manifest-eval" });
    defer allocator.free(cache_path);

    var identity: build_cache.InvocationIdentity = undefined;
    @memset(&identity, 0x42);
    var other_identity = identity;
    other_identity[0] = 0x43;

    try writeManifestEvalCache(allocator, cache_path, identity, .{
        .config = .{
            .name = "zap_test",
            .version = "1.2.3",
            .kind = .bin,
        },
        .dependencies = &.{},
        .result_hash = 0,
    });

    try std.testing.expectError(
        error.StaleManifestEvalCache,
        readManifestEvalCache(allocator, allocator, cache_path, other_identity),
    );
}

test "manifest eval cache lookup returns null for missing entry" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const cache_path = try std.fs.path.join(allocator, &.{ tmp_path, "missing.manifest-eval" });
    defer allocator.free(cache_path);

    var identity: build_cache.InvocationIdentity = undefined;
    @memset(&identity, 0x42);

    try std.testing.expect((try tryReadManifestEvalCache(allocator, allocator, cache_path, identity)) == null);
}

test "manifest eval cache lookup propagates malformed entry errors" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "default.manifest-eval", .data = "not a manifest eval cache" });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const cache_path = try std.fs.path.join(allocator, &.{ tmp_path, "default.manifest-eval" });
    defer allocator.free(cache_path);

    var identity: build_cache.InvocationIdentity = undefined;
    @memset(&identity, 0x42);

    try std.testing.expectError(
        error.InvalidManifestEvalCache,
        tryReadManifestEvalCache(allocator, allocator, cache_path, identity),
    );
}

test "manifest eval cache rejects trailing garbage" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const cache_path = try std.fs.path.join(allocator, &.{ tmp_path, "default.manifest-eval" });
    defer allocator.free(cache_path);

    var identity: build_cache.InvocationIdentity = undefined;
    @memset(&identity, 0x42);

    try writeManifestEvalCache(allocator, cache_path, identity, .{
        .config = .{
            .name = "zap_test",
            .version = "1.2.3",
            .kind = .bin,
        },
        .dependencies = &.{},
        .result_hash = 0x1234_5678,
    });

    const cache_bytes = try std.Io.Dir.cwd().readFileAlloc(global_io, cache_path, allocator, .limited(MAX_MANIFEST_EVAL_CACHE_BYTES));
    defer allocator.free(cache_bytes);
    const corrupt_bytes = try allocator.alloc(u8, cache_bytes.len + 4);
    defer allocator.free(corrupt_bytes);
    @memcpy(corrupt_bytes[0..cache_bytes.len], cache_bytes);
    @memcpy(corrupt_bytes[cache_bytes.len..], "junk");

    try std.Io.Dir.cwd().writeFile(global_io, .{
        .sub_path = cache_path,
        .data = corrupt_bytes,
    });

    var cached = readManifestEvalCache(allocator, allocator, cache_path, identity) catch |err| {
        try std.testing.expectEqual(error.InvalidManifestEvalCache, err);
        return;
    };
    cached.deinit();
    try std.testing.expect(false);
}

test "manifest eval cache invalidates when CTFE file dependency changes" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "manifest-input.txt", .data = "one" });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const cache_path = try std.fs.path.join(allocator, &.{ tmp_path, "default.manifest-eval" });
    defer allocator.free(cache_path);
    const dep_path = try std.fs.path.join(allocator, &.{ tmp_path, "manifest-input.txt" });
    defer allocator.free(dep_path);

    var identity: build_cache.InvocationIdentity = undefined;
    @memset(&identity, 0x42);
    const dependencies = [_]zap.ctfe.CtDependency{
        .{ .file = .{
            .path = dep_path,
            .content_hash = std.hash.Wyhash.hash(0, "one"),
        } },
    };

    try writeManifestEvalCache(allocator, cache_path, identity, .{
        .config = .{
            .name = "zap_test",
            .version = "1.2.3",
            .kind = .bin,
        },
        .dependencies = &dependencies,
        .result_hash = 0,
    });

    var cached = try readManifestEvalCache(allocator, allocator, cache_path, identity);
    cached.deinit();

    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "manifest-input.txt", .data = "two" });
    try std.testing.expectError(
        error.StaleManifestEvalCache,
        readManifestEvalCache(allocator, allocator, cache_path, identity),
    );
}

test "manifest eval cache lookup propagates CTFE dependency validation OOM" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dependency_content = try allocator.alloc(u8, 4096);
    defer allocator.free(dependency_content);
    @memset(dependency_content, 'x');
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "manifest-input.txt", .data = dependency_content });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const cache_path = try std.fs.path.join(allocator, &.{ tmp_path, "default.manifest-eval" });
    defer allocator.free(cache_path);
    const dep_path = try std.fs.path.join(allocator, &.{ tmp_path, "manifest-input.txt" });
    defer allocator.free(dep_path);

    var identity: build_cache.InvocationIdentity = undefined;
    @memset(&identity, 0x42);
    const dependencies = [_]zap.ctfe.CtDependency{
        .{ .file = .{
            .path = dep_path,
            .content_hash = std.hash.Wyhash.hash(0, dependency_content),
        } },
    };

    try writeManifestEvalCache(allocator, cache_path, identity, .{
        .config = .{
            .name = "zap_test",
            .version = "1.2.3",
            .kind = .bin,
        },
        .dependencies = &dependencies,
        .result_hash = 0,
    });

    const cache_bytes = try std.Io.Dir.cwd().readFileAlloc(global_io, cache_path, allocator, .limited(MAX_MANIFEST_EVAL_CACHE_BYTES));
    defer allocator.free(cache_bytes);
    const scratch_bytes = try allocator.alloc(u8, cache_bytes.len + 1024);
    defer allocator.free(scratch_bytes);
    var scratch_allocator = std.heap.FixedBufferAllocator.init(scratch_bytes);

    try std.testing.expectError(
        error.OutOfMemory,
        tryReadManifestEvalCache(allocator, scratch_allocator.allocator(), cache_path, identity),
    );
}

fn manifestDaemonNowMs() i64 {
    return Io.Timestamp.now(global_io, .awake).toMilliseconds();
}

fn nextManifestDaemonRequestId(invocation_identity: build_cache.InvocationIdentity) u64 {
    const counter = manifest_daemon_request_counter;
    manifest_daemon_request_counter +%= 1;

    const pid = std.posix.system.getpid();
    const now_ns = Io.Timestamp.now(global_io, .real).toNanoseconds();
    const seed = std.mem.readInt(u64, invocation_identity[0..8], .little);
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(&invocation_identity);
    hasher.update(std.mem.asBytes(&counter));
    hasher.update(std.mem.asBytes(&pid));
    hasher.update(std.mem.asBytes(&now_ns));
    return hasher.final();
}

fn writeDaemonString(writer: anytype, value: []const u8) !void {
    try writer.writeInt(u32, @intCast(value.len), .little);
    try writer.writeAll(value);
}

fn writeDaemonOptionalString(writer: anytype, value: ?[]const u8) !void {
    try writer.writeByte(if (value != null) 1 else 0);
    if (value) |some| try writeDaemonString(writer, some);
}

fn readDaemonString(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]const u8 {
    const len = try reader.takeInt(u32, .little);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try reader.readSliceAll(out);
    return out;
}

fn readDaemonOptionalString(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]const u8 {
    const present = try reader.takeInt(u8, .little);
    return switch (present) {
        0 => null,
        1 => try readDaemonString(allocator, reader),
        else => error.InvalidDaemonProtocol,
    };
}

fn writeDaemonPipeline(writer: anytype, pipeline: ?zap.builder.BuildConfig.Pipeline) !void {
    try writer.writeByte(if (pipeline != null) 1 else 0);
    const concrete_pipeline = pipeline orelse return;
    try writer.writeInt(u32, @intCast(concrete_pipeline.steps.len), .little);
    for (concrete_pipeline.steps) |step| {
        switch (step) {
            .compile => try writer.writeByte(1),
            .run => |run_step| {
                try writer.writeByte(2);
                try writer.writeByte(if (run_step.forward_args) 1 else 0);
                try writer.writeInt(u32, @intCast(run_step.args.len), .little);
                for (run_step.args) |arg| {
                    try writeDaemonString(writer, arg);
                }
            },
        }
    }
}

fn readDaemonPipeline(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?zap.builder.BuildConfig.Pipeline {
    const present = try reader.takeInt(u8, .little);
    switch (present) {
        0 => return null,
        1 => {},
        else => return error.InvalidDaemonProtocol,
    }

    var steps: std.ArrayListUnmanaged(zap.builder.BuildConfig.Step) = .empty;
    var initialized_count: usize = 0;
    errdefer {
        for (steps.items[0..initialized_count]) |step| {
            switch (step) {
                .compile => {},
                .run => |run_step| {
                    for (run_step.args) |arg| allocator.free(arg);
                    allocator.free(run_step.args);
                },
            }
        }
        steps.deinit(allocator);
    }

    const step_count = try reader.takeInt(u32, .little);
    var step_index: u32 = 0;
    while (step_index < step_count) : (step_index += 1) {
        const tag = try reader.takeInt(u8, .little);
        switch (tag) {
            1 => {
                try steps.append(allocator, .{ .compile = .{} });
                initialized_count += 1;
            },
            2 => {
                const forward_args_tag = try reader.takeInt(u8, .little);
                const forward_args = switch (forward_args_tag) {
                    0 => false,
                    1 => true,
                    else => return error.InvalidDaemonProtocol,
                };
                var args: std.ArrayListUnmanaged([]const u8) = .empty;
                var args_transferred = false;
                errdefer {
                    if (!args_transferred) {
                        for (args.items) |arg| allocator.free(arg);
                        args.deinit(allocator);
                    }
                }
                const arg_count = try reader.takeInt(u32, .little);
                var arg_index: u32 = 0;
                while (arg_index < arg_count) : (arg_index += 1) {
                    const arg = try readDaemonString(allocator, reader);
                    errdefer allocator.free(arg);
                    try args.append(allocator, arg);
                }
                const owned_args = try args.toOwnedSlice(allocator);
                args_transferred = true;
                errdefer {
                    for (owned_args) |arg| allocator.free(arg);
                    allocator.free(owned_args);
                }
                try steps.append(allocator, .{ .run = .{
                    .args = owned_args,
                    .forward_args = forward_args,
                } });
                initialized_count += 1;
            },
            else => return error.InvalidDaemonProtocol,
        }
    }

    return .{ .steps = try steps.toOwnedSlice(allocator) };
}

fn exerciseReadDaemonPipelineRunArgsAllocationFailures(allocator: std.mem.Allocator) !void {
    const bytes = [_]u8{
        1, // pipeline present
        1, 0, 0, 0, // one step
        2, // run step
        1, // forward args
        1, 0, 0, 0, // one arg
        6,   0,   0,   0, // arg byte length
        's', 'e', 'r', 'v',
        'e', 'r',
    };
    var reader: std.Io.Reader = .fixed(&bytes);
    const pipeline = (try readDaemonPipeline(allocator, &reader)).?;
    defer freeBuildPipeline(allocator, pipeline);

    try testing.expectEqual(@as(usize, 1), pipeline.steps.len);
    try testing.expect(pipeline.steps[0] == .run);
    try testing.expect(pipeline.steps[0].run.forward_args);
    try testing.expectEqual(@as(usize, 1), pipeline.steps[0].run.args.len);
    try testing.expectEqualStrings("server", pipeline.steps[0].run.args[0]);
}

test "P4J2: readDaemonPipeline frees decoded run arg when args append fails" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseReadDaemonPipelineRunArgsAllocationFailures,
        .{},
    );
}

fn writeDaemonBuildOverrides(writer: *std.Io.Writer, overrides: BuildOverrides) !void {
    try writer.writeByte(if (overrides.optimize != null) 1 else 0);
    if (overrides.optimize) |optimize| {
        try writer.writeByte(@intFromEnum(optimize));
    }
    try writeDaemonOptionalString(writer, overrides.memory);
    try writeDaemonOptionalString(writer, overrides.target);
    try writeDaemonOptionalString(writer, overrides.cpu);
}

fn readDaemonBuildOverrides(allocator: std.mem.Allocator, reader: *std.Io.Reader) !BuildOverrides {
    var overrides: BuildOverrides = .{};
    errdefer deinitManifestDaemonBuildOverrides(allocator, overrides);

    const has_optimize = try reader.takeInt(u8, .little);
    switch (has_optimize) {
        0 => {},
        1 => {
            const tag = try reader.takeInt(u8, .little);
            overrides.optimize = switch (tag) {
                @intFromEnum(zap.builder.BuildConfig.Optimize.debug) => .debug,
                @intFromEnum(zap.builder.BuildConfig.Optimize.release_safe) => .release_safe,
                @intFromEnum(zap.builder.BuildConfig.Optimize.release_fast) => .release_fast,
                @intFromEnum(zap.builder.BuildConfig.Optimize.release_small) => .release_small,
                else => return error.InvalidDaemonProtocol,
            };
        },
        else => return error.InvalidDaemonProtocol,
    }
    overrides.memory = try readDaemonOptionalString(allocator, reader);
    overrides.target = try readDaemonOptionalString(allocator, reader);
    overrides.cpu = try readDaemonOptionalString(allocator, reader);
    return overrides;
}

fn writeManifestDaemonRequest(
    writer: *std.Io.Writer,
    mode: ManifestDaemonRequestMode,
    invocation_identity: build_cache.InvocationIdentity,
    response_path: ?[]const u8,
    progress_path: ?[]const u8,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    collect_arc_stats: bool,
    trace_enabled: bool,
    zap_lib_dir_override: ?[]const u8,
) !void {
    try writer.writeInt(u32, MANIFEST_DAEMON_REQUEST_MAGIC, .little);
    try writer.writeInt(u16, MANIFEST_DAEMON_PROTOCOL_VERSION, .little);
    try writer.writeByte(@intFromEnum(mode));
    try writer.writeAll(&invocation_identity);
    try writer.writeByte(if (collect_arc_stats) 1 else 0);
    try writer.writeByte(if (trace_enabled) 1 else 0);
    try writeDaemonOptionalString(writer, response_path);
    try writeDaemonOptionalString(writer, progress_path);
    try writeDaemonString(writer, project_root);
    try writeDaemonString(writer, target_name);
    try writeDaemonOptionalString(writer, zap_lib_dir_override);
    try writeDaemonBuildOverrides(writer, build_overrides);

    try writer.writeInt(u32, @intCast(build_opts.count()), .little);
    var iterator = build_opts.iterator();
    while (iterator.next()) |entry| {
        try writeDaemonString(writer, entry.key_ptr.*);
        try writeDaemonString(writer, entry.value_ptr.*);
    }
}

fn readManifestDaemonRequestPayload(allocator: std.mem.Allocator, reader: *std.Io.Reader) !ManifestDaemonRequest {
    if (try reader.takeInt(u32, .little) != MANIFEST_DAEMON_REQUEST_MAGIC) return error.InvalidDaemonProtocol;
    if (try reader.takeInt(u16, .little) != MANIFEST_DAEMON_PROTOCOL_VERSION) return error.InvalidDaemonProtocol;
    const mode_tag = try reader.takeInt(u8, .little);
    const mode: ManifestDaemonRequestMode = switch (mode_tag) {
        1 => .warm,
        2 => .build,
        3 => .shutdown,
        else => return error.InvalidDaemonProtocol,
    };
    var invocation_identity: build_cache.InvocationIdentity = undefined;
    try reader.readSliceAll(&invocation_identity);
    const collect_arc_stats_tag = try reader.takeInt(u8, .little);
    const collect_arc_stats = switch (collect_arc_stats_tag) {
        0 => false,
        1 => true,
        else => return error.InvalidDaemonProtocol,
    };
    const trace_enabled_tag = try reader.takeInt(u8, .little);
    const trace_enabled = switch (trace_enabled_tag) {
        0 => false,
        1 => true,
        else => return error.InvalidDaemonProtocol,
    };
    const response_path = try readDaemonOptionalString(allocator, reader);
    errdefer if (response_path) |response_path_value| allocator.free(response_path_value);
    const progress_path = try readDaemonOptionalString(allocator, reader);
    errdefer if (progress_path) |progress_path_value| allocator.free(progress_path_value);
    const project_root = try readDaemonString(allocator, reader);
    errdefer allocator.free(project_root);
    const target_name = try readDaemonString(allocator, reader);
    errdefer allocator.free(target_name);
    const zap_lib_dir_override = try readDaemonOptionalString(allocator, reader);
    errdefer if (zap_lib_dir_override) |zap_lib_dir_override_value| allocator.free(zap_lib_dir_override_value);
    const build_overrides = try readDaemonBuildOverrides(allocator, reader);
    errdefer deinitManifestDaemonBuildOverrides(allocator, build_overrides);

    var build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer deinitManifestDaemonBuildOpts(allocator, build_opts);
    const build_opt_count = try reader.takeInt(u32, .little);
    var index: u32 = 0;
    while (index < build_opt_count) : (index += 1) {
        const key = try readDaemonString(allocator, reader);
        errdefer allocator.free(key);
        const value = try readDaemonString(allocator, reader);
        errdefer allocator.free(value);
        if (build_opts.contains(key)) return error.InvalidDaemonProtocol;
        try build_opts.put(allocator, key, value);
    }

    return .{
        .mode = mode,
        .invocation_identity = invocation_identity,
        .response_path = response_path,
        .progress_path = progress_path,
        .project_root = project_root,
        .target_name = target_name,
        .build_opts = build_opts,
        .build_overrides = build_overrides,
        .collect_arc_stats = collect_arc_stats,
        .trace_enabled = trace_enabled,
        .zap_lib_dir_override = zap_lib_dir_override,
    };
}

fn readManifestDaemonRequest(allocator: std.mem.Allocator, reader: *std.Io.Reader) !ManifestDaemonRequest {
    const request = try readManifestDaemonRequestPayload(allocator, reader);
    errdefer deinitManifestDaemonRequest(allocator, request);
    if (reader.seek != reader.end) return error.InvalidDaemonProtocol;
    return request;
}

fn writeManifestDaemonOkResponse(writer: *std.Io.Writer, state: *const IncrementalWatchState) !void {
    try writer.writeInt(u32, MANIFEST_DAEMON_RESPONSE_MAGIC, .little);
    try writer.writeInt(u16, MANIFEST_DAEMON_PROTOCOL_VERSION, .little);
    try writer.writeByte(@intFromEnum(ManifestDaemonResponseStatus.ok));
    try writer.writeByte(switch (state.kind) {
        .bin => 0,
        .lib => 1,
        .obj => 2,
    });
    try writeDaemonOptionalString(writer, state.target);
    try writeDaemonString(writer, state.output_path);
    try writeDaemonPipeline(writer, state.manifest_config.pipeline);
}

fn writeManifestDaemonErrorResponse(writer: *std.Io.Writer, message: []const u8) !void {
    try writer.writeInt(u32, MANIFEST_DAEMON_RESPONSE_MAGIC, .little);
    try writer.writeInt(u16, MANIFEST_DAEMON_PROTOCOL_VERSION, .little);
    try writer.writeByte(@intFromEnum(ManifestDaemonResponseStatus.failed));
    try writeDaemonString(writer, message);
}

fn readManifestDaemonResponsePayload(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !ManifestDaemonResponse {
    if (try reader.takeInt(u32, .little) != MANIFEST_DAEMON_RESPONSE_MAGIC) return error.InvalidDaemonProtocol;
    if (try reader.takeInt(u16, .little) != MANIFEST_DAEMON_PROTOCOL_VERSION) return error.InvalidDaemonProtocol;
    const status_tag = try reader.takeInt(u8, .little);
    const status: ManifestDaemonResponseStatus = switch (status_tag) {
        0 => .ok,
        1 => .failed,
        else => return error.InvalidDaemonProtocol,
    };
    return switch (status) {
        .ok => blk: {
            const kind_tag = try reader.takeInt(u8, .little);
            const kind: zap.builder.BuildConfig.Kind = switch (kind_tag) {
                0 => .bin,
                1 => .lib,
                2 => .obj,
                else => return error.InvalidDaemonProtocol,
            };
            const target = try readDaemonOptionalString(allocator, reader);
            errdefer if (target) |target_value| allocator.free(target_value);

            const path = try readDaemonString(allocator, reader);
            errdefer allocator.free(path);

            const pipeline = try readDaemonPipeline(allocator, reader);
            errdefer if (pipeline) |pipeline_value| freeBuildPipeline(allocator, pipeline_value);

            break :blk .{ .ok = .{
                .path = path,
                .kind = kind,
                .target = target,
                .pipeline = pipeline,
            } };
        },
        .failed => blk: {
            const message = try readDaemonString(allocator, reader);
            errdefer allocator.free(message);
            break :blk .{ .failed = message };
        },
    };
}

fn readManifestDaemonResponse(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !ManifestDaemonResponse {
    const response = try readManifestDaemonResponsePayload(allocator, reader);
    errdefer deinitManifestDaemonResponse(allocator, response);
    if (reader.seek != reader.end) return error.InvalidDaemonProtocol;
    return response;
}

const ManifestDaemonEndpoint = struct {
    read_fd: std.posix.fd_t,
    keepalive_write_fd: std.posix.fd_t,

    fn deinit(self: ManifestDaemonEndpoint) void {
        closeFd(self.read_fd, true);
        closeFd(self.keepalive_write_fd, true);
    }
};

fn closeFd(fd: std.posix.fd_t, nonblocking: bool) void {
    const file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = nonblocking },
    };
    file.close(global_io);
}

fn manifestDaemonPathExists(path: []const u8) !bool {
    std.Io.Dir.cwd().access(global_io, path, .{}) catch |err| {
        if (isMissingPathAccessError(err)) return false;
        return err;
    };
    return true;
}

fn deleteManifestDaemonFileIfPresent(path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(global_io, path) catch |err| {
        if (isMissingPathAccessError(err)) return;
        return err;
    };
}

test "P4J2: manifest daemon path existence preserves missing and present states" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);

    const missing_path = try std.fs.path.join(allocator, &.{ tmp_path, "missing.fifo" });
    defer allocator.free(missing_path);
    try testing.expect(!(try manifestDaemonPathExists(missing_path)));

    const present_path = try std.fs.path.join(allocator, &.{ tmp_path, "present.fifo" });
    defer allocator.free(present_path);
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "present.fifo", .data = "" });
    try testing.expect(try manifestDaemonPathExists(present_path));
}

test "P4J2: manifest daemon path existence treats not-directory components as missing" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "endpoint-parent", .data = "not a directory" });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const endpoint_path = try std.fs.path.join(allocator, &.{ tmp_path, "endpoint-parent/daemon.fifo" });
    defer allocator.free(endpoint_path);

    try testing.expect(!(try manifestDaemonPathExists(endpoint_path)));
}

test "P4J2: manifest daemon path existence propagates non-missing access failures" {
    const allocator = testing.allocator;

    const too_long_prefix = try allocator.alloc(u8, std.fs.max_path_bytes + 1);
    defer allocator.free(too_long_prefix);
    @memset(too_long_prefix, 'a');
    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/daemon.fifo", .{too_long_prefix});
    defer allocator.free(endpoint_path);

    try testing.expectError(error.NameTooLong, manifestDaemonPathExists(endpoint_path));
}

fn isBenignManifestDaemonEndpointOpenError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.NoDevice,
        error.WouldBlock,
        error.BrokenPipe,
        error.ConnectionRefused,
        => true,
        else => false,
    };
}

fn openManifestDaemonEndpointForWrite(endpoint_path: []const u8) !std.posix.fd_t {
    return std.posix.openat(std.posix.AT.FDCWD, endpoint_path, .{
        .ACCMODE = .WRONLY,
        .NONBLOCK = true,
        .CLOEXEC = true,
    }, 0);
}

fn createManifestDaemonFifo(allocator: std.mem.Allocator, endpoint_path: []const u8) !void {
    const endpoint_path_z = try allocator.dupeZ(u8, endpoint_path);
    defer allocator.free(endpoint_path_z);

    const rc = mkfifo(endpoint_path_z.ptr, 0o600);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return,
        .EXIST => {
            const stat = std.Io.Dir.cwd().statFile(global_io, endpoint_path, .{}) catch return error.DaemonEndpointUnavailable;
            if (stat.kind == .named_pipe) return;
            std.Io.Dir.cwd().deleteFile(global_io, endpoint_path) catch return error.DaemonEndpointUnavailable;
            const retry_rc = mkfifo(endpoint_path_z.ptr, 0o600);
            switch (std.posix.errno(retry_rc)) {
                .SUCCESS => return,
                else => return error.DaemonEndpointUnavailable,
            }
        },
        else => return error.DaemonEndpointUnavailable,
    }
}

fn openManifestDaemonEndpointForRead(allocator: std.mem.Allocator, endpoint_path: []const u8) !ManifestDaemonEndpoint {
    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);
    try createManifestDaemonFifo(allocator, endpoint_path);

    const read_fd = try std.posix.openat(std.posix.AT.FDCWD, endpoint_path, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .CLOEXEC = true,
    }, 0);
    errdefer closeFd(read_fd, true);

    const keepalive_write_fd = try openManifestDaemonEndpointForWrite(endpoint_path);
    errdefer closeFd(keepalive_write_fd, true);

    return .{
        .read_fd = read_fd,
        .keepalive_write_fd = keepalive_write_fd,
    };
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[index..].ptr, bytes.len - index);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const written: usize = @intCast(rc);
                if (written == 0) return error.DaemonEndpointUnavailable;
                index += written;
            },
            .INTR => {},
            .AGAIN => global_io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {},
            else => return error.DaemonEndpointUnavailable,
        }
    }
}

fn notifyManifestDaemon(endpoint_path: []const u8, request_path: []const u8) !void {
    const write_fd = try openManifestDaemonEndpointForWrite(endpoint_path);
    defer closeFd(write_fd, true);
    try writeAllFd(write_fd, request_path);
    try writeAllFd(write_fd, "\n");
}

fn waitForManifestDaemon(allocator: std.mem.Allocator, endpoint_path: []const u8) !bool {
    var attempts: usize = 0;
    while (attempts < 80) : (attempts += 1) {
        if (try manifestDaemonEndpointIsLive(allocator, endpoint_path)) return true;
        global_io.sleep(std.Io.Duration.fromMilliseconds(25), .awake) catch {};
    }
    return false;
}

fn waitForManifestDaemonEndpointRemoval(endpoint_path: []const u8) !bool {
    var attempts: usize = 0;
    while (attempts < 80) : (attempts += 1) {
        if (!try manifestDaemonPathExists(endpoint_path)) return true;
        global_io.sleep(std.Io.Duration.fromMilliseconds(25), .awake) catch {};
    }
    return !(try manifestDaemonPathExists(endpoint_path));
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn parseManifestDaemonInvocationIdentityHex(hex: []const u8) ?build_cache.InvocationIdentity {
    if (hex.len != @sizeOf(build_cache.InvocationIdentity) * 2) return null;

    var identity: build_cache.InvocationIdentity = undefined;
    for (&identity, 0..) |*byte, index| {
        const high = hexValue(hex[index * 2]) orelse return null;
        const low = hexValue(hex[index * 2 + 1]) orelse return null;
        byte.* = (high << 4) | low;
    }
    return identity;
}

fn parseManifestDaemonInvocationIdentityFromEndpointName(name: []const u8) ?build_cache.InvocationIdentity {
    const suffix = ".fifo";
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    return parseManifestDaemonInvocationIdentityHex(name[0 .. name.len - suffix.len]);
}

fn parseManifestDaemonInvocationIdentityFromRequestName(name: []const u8) ?build_cache.InvocationIdentity {
    if (!std.mem.endsWith(u8, name, ".req")) return null;
    const dot_index = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    return parseManifestDaemonInvocationIdentityHex(name[0..dot_index]);
}

fn parseManifestDaemonInvocationIdentityFromAckName(name: []const u8) ?build_cache.InvocationIdentity {
    if (!std.mem.endsWith(u8, name, ".ack")) return null;
    const dot_index = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    return parseManifestDaemonInvocationIdentityHex(name[0..dot_index]);
}

fn manifestDaemonRequestArtifactNameMatchesIdentity(name: []const u8, invocation_identity: build_cache.InvocationIdentity, suffix: []const u8) bool {
    if (!std.mem.endsWith(u8, name, suffix)) return false;

    var identity_hex_buffer: [@sizeOf(build_cache.InvocationIdentity) * 2]u8 = undefined;
    for (invocation_identity, 0..) |byte, index| {
        identity_hex_buffer[index * 2] = std.fmt.digitToChar(byte >> 4, .lower);
        identity_hex_buffer[index * 2 + 1] = std.fmt.digitToChar(byte & 0xf, .lower);
    }
    if (!std.mem.startsWith(u8, name, &identity_hex_buffer)) return false;
    if (name.len <= identity_hex_buffer.len + suffix.len) return false;
    return name[identity_hex_buffer.len] == '.';
}

fn manifestDaemonRequestNameMatchesIdentity(name: []const u8, invocation_identity: build_cache.InvocationIdentity) bool {
    return manifestDaemonRequestArtifactNameMatchesIdentity(name, invocation_identity, ".req");
}

fn manifestDaemonRequestAckNameMatchesIdentity(name: []const u8, invocation_identity: build_cache.InvocationIdentity) bool {
    return manifestDaemonRequestArtifactNameMatchesIdentity(name, invocation_identity, ".ack");
}

fn readManifestDaemonRequestModeHeader(bytes: []const u8) !ManifestDaemonRequestMode {
    if (bytes.len < MANIFEST_DAEMON_REQUEST_HEADER_LEN) return error.InvalidDaemonProtocol;

    var reader: std.Io.Reader = .fixed(bytes[0..MANIFEST_DAEMON_REQUEST_HEADER_LEN]);
    if (try reader.takeInt(u32, .little) != MANIFEST_DAEMON_REQUEST_MAGIC) return error.InvalidDaemonProtocol;
    if (try reader.takeInt(u16, .little) != MANIFEST_DAEMON_PROTOCOL_VERSION) return error.InvalidDaemonProtocol;
    return switch (try reader.takeInt(u8, .little)) {
        1 => .warm,
        2 => .build,
        3 => .shutdown,
        else => error.InvalidDaemonProtocol,
    };
}

fn readManifestDaemonRequestModeFromFile(path: []const u8) !ManifestDaemonRequestMode {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);
    defer closeFd(fd, false);

    var header: [MANIFEST_DAEMON_REQUEST_HEADER_LEN]u8 = undefined;
    var offset: usize = 0;
    while (offset < header.len) {
        const bytes_read = try std.posix.read(fd, header[offset..]);
        if (bytes_read == 0) return error.InvalidDaemonProtocol;
        offset += bytes_read;
    }
    return readManifestDaemonRequestModeHeader(&header);
}

const ManifestDaemonPendingRequestStatus = enum {
    none,
    unacknowledged,
    acknowledged,
};

fn manifestDaemonPendingRequestStatus(
    allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    mode_filter: ?ManifestDaemonRequestMode,
) !ManifestDaemonPendingRequestStatus {
    var dir = std.Io.Dir.cwd().openDir(global_io, MANIFEST_DAEMON_DIR, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .none,
        else => |open_err| return open_err,
    };
    defer dir.close(global_io);

    var saw_unacknowledged = false;
    var iterator = dir.iterate();
    while (try iterator.next(global_io)) |entry| {
        if (!manifestDaemonRequestNameMatchesIdentity(entry.name, invocation_identity)) continue;

        const request_path = try std.fs.path.join(allocator, &.{ MANIFEST_DAEMON_DIR, entry.name });
        defer allocator.free(request_path);

        if (mode_filter) |expected_mode| {
            const request_mode = try readManifestDaemonRequestModeFromFile(request_path);
            if (request_mode != expected_mode) continue;
        }

        const ack_path = try manifestDaemonRequestAckPath(allocator, request_path);
        defer allocator.free(ack_path);
        if (try manifestDaemonPathExists(ack_path)) return .acknowledged;
        saw_unacknowledged = true;
    }

    return if (saw_unacknowledged) .unacknowledged else .none;
}

fn manifestDaemonHasPendingRequest(
    allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    mode_filter: ?ManifestDaemonRequestMode,
) !bool {
    const status = try manifestDaemonPendingRequestStatus(allocator, invocation_identity, mode_filter);
    return status != .none;
}

fn deleteManifestDaemonPendingRequestEntryIfMatched(
    allocator: std.mem.Allocator,
    daemon_dir: []const u8,
    invocation_identity: build_cache.InvocationIdentity,
    entry_name: []const u8,
) !void {
    if (!manifestDaemonRequestNameMatchesIdentity(entry_name, invocation_identity) and
        !manifestDaemonRequestAckNameMatchesIdentity(entry_name, invocation_identity)) return;
    const request_path = try std.fs.path.join(allocator, &.{ daemon_dir, entry_name });
    defer allocator.free(request_path);
    try deleteManifestDaemonFileIfPresent(request_path);
}

fn deleteManifestDaemonPendingRequestsFromIterator(
    allocator: std.mem.Allocator,
    daemon_dir: []const u8,
    invocation_identity: build_cache.InvocationIdentity,
    iterator: anytype,
) !void {
    while (try iterator.next(global_io)) |entry| {
        try deleteManifestDaemonPendingRequestEntryIfMatched(allocator, daemon_dir, invocation_identity, entry.name);
    }
}

fn deleteManifestDaemonPendingRequestsInDir(
    allocator: std.mem.Allocator,
    daemon_dir: []const u8,
    invocation_identity: build_cache.InvocationIdentity,
) !void {
    var dir = std.Io.Dir.cwd().openDir(global_io, daemon_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => |open_err| return open_err,
    };
    defer dir.close(global_io);

    var iterator = dir.iterate();
    try deleteManifestDaemonPendingRequestsFromIterator(allocator, daemon_dir, invocation_identity, &iterator);
}

fn deleteManifestDaemonPendingRequests(
    allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
) !void {
    try deleteManifestDaemonPendingRequestsInDir(allocator, MANIFEST_DAEMON_DIR, invocation_identity);
}

fn cleanupManifestDaemonOrphanRequestArtifact(
    allocator: std.mem.Allocator,
    artifact_name: []const u8,
) !void {
    const invocation_identity =
        parseManifestDaemonInvocationIdentityFromRequestName(artifact_name) orelse
        parseManifestDaemonInvocationIdentityFromAckName(artifact_name) orelse
        return;
    const endpoint_path = try manifestDaemonEndpointPath(allocator, invocation_identity);
    defer allocator.free(endpoint_path);
    if (try manifestDaemonPathExists(endpoint_path)) return;

    const daemon_artifact_path = try std.fs.path.join(allocator, &.{ MANIFEST_DAEMON_DIR, artifact_name });
    defer allocator.free(daemon_artifact_path);
    try deleteManifestDaemonFileIfPresent(daemon_artifact_path);
}

fn cleanupManifestDaemonOrphanRequests(allocator: std.mem.Allocator) !void {
    var dir = std.Io.Dir.cwd().openDir(global_io, MANIFEST_DAEMON_DIR, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => |open_err| return open_err,
    };
    defer dir.close(global_io);

    var iterator = dir.iterate();
    while (try iterator.next(global_io)) |entry| {
        try cleanupManifestDaemonOrphanRequestArtifact(allocator, entry.name);
    }
}

fn writeManifestDaemonPidFile(
    allocator: std.mem.Allocator,
    pid_path: []const u8,
    pid: std.posix.pid_t,
) !void {
    const pid_text = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(pid_text);
    try build_cache.writeFileAtomic(allocator, pid_path, pid_text);
}

fn readManifestDaemonPid(allocator: std.mem.Allocator, pid_path: []const u8) !std.posix.pid_t {
    const pid_text = try std.Io.Dir.cwd().readFileAlloc(global_io, pid_path, allocator, .limited(128));
    defer allocator.free(pid_text);
    const trimmed = std.mem.trim(u8, pid_text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidDaemonPid;
    return std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch error.InvalidDaemonPid;
}

fn manifestDaemonProcessIsAlive(pid: std.posix.pid_t) !bool {
    if (pid <= 0) return false;
    const no_signal: std.posix.SIG = @enumFromInt(0);
    std.posix.kill(pid, no_signal) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => |probe_err| return probe_err,
    };
    return true;
}

fn manifestDaemonEndpointIsLive(allocator: std.mem.Allocator, endpoint_path: []const u8) !bool {
    const pid_path = try manifestDaemonPidPathFromEndpointPath(allocator, endpoint_path);
    defer allocator.free(pid_path);

    const pid = readManifestDaemonPid(allocator, pid_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.InvalidDaemonPid => return false,
        else => |read_pid_err| return read_pid_err,
    };
    if (!try manifestDaemonProcessIsAlive(pid)) return false;

    const write_fd = openManifestDaemonEndpointForWrite(endpoint_path) catch |err| {
        if (isBenignManifestDaemonEndpointOpenError(err)) return false;
        return err;
    };
    closeFd(write_fd, true);
    return true;
}

fn cleanupManifestDaemonEndpointFiles(
    allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    endpoint_path: []const u8,
) !void {
    const pid_path = try manifestDaemonPidPath(allocator, invocation_identity);
    defer allocator.free(pid_path);
    try deleteManifestDaemonPendingRequests(allocator, invocation_identity);
    try deleteManifestDaemonFileIfPresent(pid_path);
    try deleteManifestDaemonFileIfPresent(endpoint_path);
}

fn signalManifestDaemonProcess(pid: std.posix.pid_t, signal: std.posix.SIG) !void {
    std.posix.kill(pid, signal) catch |err| switch (err) {
        error.ProcessNotFound => return,
        else => |kill_err| return kill_err,
    };
}

const ManifestDaemonSignalFn = *const fn (std.posix.pid_t, std.posix.SIG) anyerror!void;

fn waitForManifestDaemonProcessExit(pid: std.posix.pid_t) !bool {
    var attempts: usize = 0;
    while (attempts < 80) : (attempts += 1) {
        if (!try manifestDaemonProcessIsAlive(pid)) return true;
        try global_io.sleep(std.Io.Duration.fromMilliseconds(25), .awake);
    }
    return !(try manifestDaemonProcessIsAlive(pid));
}

fn terminateManifestDaemonEndpoint(
    allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    endpoint_path: []const u8,
) !void {
    try terminateManifestDaemonEndpointWithSignal(allocator, invocation_identity, endpoint_path, signalManifestDaemonProcess);
}

fn terminateManifestDaemonEndpointWithSignal(
    allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    endpoint_path: []const u8,
    signal_process: ManifestDaemonSignalFn,
) !void {
    const pid_path = try manifestDaemonPidPath(allocator, invocation_identity);
    defer allocator.free(pid_path);
    const pid = readManifestDaemonPid(allocator, pid_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.InvalidDaemonPid => {
            try cleanupManifestDaemonEndpointFiles(allocator, invocation_identity, endpoint_path);
            return;
        },
        else => |read_pid_err| return read_pid_err,
    };

    if (try manifestDaemonProcessIsAlive(pid)) {
        try signal_process(pid, .TERM);
        if (!try waitForManifestDaemonProcessExit(pid)) {
            try signal_process(pid, .KILL);
            if (!try waitForManifestDaemonProcessExit(pid)) return error.DaemonTerminationFailed;
        }
    }

    try cleanupManifestDaemonEndpointFiles(allocator, invocation_identity, endpoint_path);
}

fn shutdownManifestDaemonEndpoint(
    allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    endpoint_path: []const u8,
) !void {
    if (!try manifestDaemonEndpointIsLive(allocator, endpoint_path)) {
        try cleanupManifestDaemonEndpointFiles(allocator, invocation_identity, endpoint_path);
        return;
    }

    const build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    const request_path = try sendManifestDaemonRequest(
        allocator,
        endpoint_path,
        .shutdown,
        invocation_identity,
        null,
        null,
        ".",
        "",
        build_opts,
        .{},
        false,
        false,
        null,
    );
    defer allocator.free(request_path);

    if (!try waitForManifestDaemonEndpointRemoval(endpoint_path)) {
        try terminateManifestDaemonEndpoint(allocator, invocation_identity, endpoint_path);
    }
}

fn shutdownManifestDaemonsInCwd(allocator: std.mem.Allocator) !void {
    var dir = std.Io.Dir.cwd().openDir(global_io, MANIFEST_DAEMON_DIR, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(global_io);

    var iterator = dir.iterate();
    while (try iterator.next(global_io)) |entry| {
        const invocation_identity = parseManifestDaemonInvocationIdentityFromEndpointName(entry.name) orelse continue;
        const endpoint_path = try std.fs.path.join(allocator, &.{ MANIFEST_DAEMON_DIR, entry.name });
        defer allocator.free(endpoint_path);
        try shutdownManifestDaemonEndpoint(allocator, invocation_identity, endpoint_path);
    }

    try cleanupManifestDaemonOrphanRequests(allocator);
}

fn truncateManifestDaemonLog(log_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);
    var log_file = try std.Io.Dir.cwd().createFile(global_io, log_path, .{ .truncate = true });
    log_file.close(global_io);
}

fn truncateManifestDaemonProgress(progress_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);
    var progress_file = try std.Io.Dir.cwd().createFile(global_io, progress_path, .{ .truncate = true });
    progress_file.close(global_io);
}

fn printManifestDaemonLog(allocator: std.mem.Allocator, log_path: []const u8) void {
    const log_bytes = std.Io.Dir.cwd().readFileAlloc(global_io, log_path, allocator, .limited(2 * 1024 * 1024)) catch return;
    defer allocator.free(log_bytes);
    if (log_bytes.len > 0) {
        std.debug.print("{s}", .{log_bytes});
        if (log_bytes[log_bytes.len - 1] != '\n') std.debug.print("\n", .{});
    }
}

fn childCloseFd(fd: std.posix.fd_t) void {
    _ = std.posix.system.close(fd);
}

fn childDup2(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) bool {
    while (true) {
        switch (std.posix.errno(std.posix.system.dup2(old_fd, new_fd))) {
            .SUCCESS => return true,
            .INTR => continue,
            else => return false,
        }
    }
}

fn spawnDetachedManifestDaemon(
    exe_path: [:0]const u8,
    endpoint_path: [:0]const u8,
    stderr_fd: std.posix.fd_t,
    dev_null_fd: std.posix.fd_t,
) !std.posix.pid_t {
    const pid_result = std.posix.system.fork();
    switch (std.posix.errno(pid_result)) {
        .SUCCESS => {},
        .AGAIN, .NOSYS => return error.DaemonForkUnavailable,
        .NOMEM => return error.OutOfMemory,
        else => return error.DaemonForkFailed,
    }

    const pid: std.posix.pid_t = @intCast(pid_result);
    if (pid != 0) return pid;

    defer comptime unreachable;

    if (std.posix.errno(std.posix.system.setsid()) != .SUCCESS) std.c._exit(127);
    if (!childDup2(dev_null_fd, std.posix.STDIN_FILENO)) std.c._exit(127);
    if (!childDup2(dev_null_fd, std.posix.STDOUT_FILENO)) std.c._exit(127);
    if (!childDup2(stderr_fd, std.posix.STDERR_FILENO)) std.c._exit(127);

    if (dev_null_fd > std.posix.STDERR_FILENO) childCloseFd(dev_null_fd);
    if (stderr_fd > std.posix.STDERR_FILENO and stderr_fd != dev_null_fd) childCloseFd(stderr_fd);

    const daemon_arg: [*:0]const u8 = "__manifest-incremental-daemon";
    var argv = [_:null]?[*:0]const u8{
        exe_path.ptr,
        daemon_arg,
        endpoint_path.ptr,
    };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    _ = std.posix.system.execve(exe_path.ptr, &argv, envp);
    std.c._exit(127);
}

fn spawnManifestDaemon(
    allocator: std.mem.Allocator,
    endpoint_path: []const u8,
    log_path: []const u8,
) !void {
    std.Io.Dir.cwd().deleteFile(global_io, endpoint_path) catch |err| {
        if (!isMissingPathAccessError(err)) return err;
    };

    const exe_path = try std.process.executablePathAlloc(global_io, allocator);
    defer allocator.free(exe_path);

    const endpoint_path_z = try allocator.dupeZ(u8, endpoint_path);
    defer allocator.free(endpoint_path_z);

    var log_file = try std.Io.Dir.cwd().createFile(global_io, log_path, .{ .truncate = false });
    defer log_file.close(global_io);

    const dev_null_fd = try std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    }, 0);
    defer closeFd(dev_null_fd, false);

    const child_pid = try spawnDetachedManifestDaemon(exe_path, endpoint_path_z, log_file.handle, dev_null_fd);

    const pid_path = manifestDaemonPidPathFromEndpointPath(allocator, endpoint_path) catch |err| {
        std.posix.kill(child_pid, .TERM) catch {};
        return err;
    };
    defer allocator.free(pid_path);
    writeManifestDaemonPidFile(allocator, pid_path, child_pid) catch |err| {
        std.posix.kill(child_pid, .TERM) catch {};
        return err;
    };

    if (!try waitForManifestDaemon(allocator, endpoint_path)) {
        std.posix.kill(child_pid, .TERM) catch {};
        return error.DaemonStartUnavailable;
    }
}

fn startManifestDaemon(
    allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    endpoint_path: []const u8,
    log_path: []const u8,
) !void {
    if (try manifestDaemonEndpointIsLive(allocator, endpoint_path)) {
        return;
    } else {
        try cleanupManifestDaemonEndpointFiles(allocator, invocation_identity, endpoint_path);
    }

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);

    const lock_path = try manifestDaemonStartLockPath(allocator, invocation_identity);
    defer allocator.free(lock_path);

    if (std.Io.Dir.cwd().createDir(global_io, lock_path, .default_dir)) |_| {
        defer std.Io.Dir.cwd().deleteTree(global_io, lock_path) catch {};
        try spawnManifestDaemon(allocator, endpoint_path, log_path);
        return;
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |create_lock_err| return create_lock_err,
    }

    if (try waitForManifestDaemon(allocator, endpoint_path)) return;
    std.Io.Dir.cwd().deleteTree(global_io, lock_path) catch |err| {
        if (!isMissingPathAccessError(err)) return err;
    };
    if (std.Io.Dir.cwd().createDir(global_io, lock_path, .default_dir)) |_| {
        defer std.Io.Dir.cwd().deleteTree(global_io, lock_path) catch {};
        try spawnManifestDaemon(allocator, endpoint_path, log_path);
        return;
    } else |err| switch (err) {
        error.PathAlreadyExists => {
            if (try waitForManifestDaemon(allocator, endpoint_path)) return;
            return error.DaemonStartUnavailable;
        },
        else => |create_lock_err| return create_lock_err,
    }
}

fn manifestDaemonFallbackMessage(reason: ManifestDaemonFallbackReason) []const u8 {
    return switch (reason) {
        .daemon_unavailable => "daemon unavailable; rebuilding",
        .stale_artifact => "daemon result stale; rebuilding",
    };
}

fn manifestDaemonBuildFallbackFromWaitError(err: anyerror) ?ManifestDaemonFallbackReason {
    return switch (err) {
        error.DaemonRequestNotAcknowledged,
        error.DaemonEndpointUnavailable,
        => .daemon_unavailable,
        else => null,
    };
}

fn cleanupManifestDaemonBuildFallbackWithSignal(
    allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    endpoint_path: []const u8,
    wait_error: anyerror,
    signal_process: ManifestDaemonSignalFn,
) !void {
    if (wait_error == error.DaemonEndpointUnavailable and !try manifestDaemonEndpointIsLive(allocator, endpoint_path)) {
        try cleanupManifestDaemonEndpointFiles(allocator, invocation_identity, endpoint_path);
        return;
    }

    try terminateManifestDaemonEndpointWithSignal(allocator, invocation_identity, endpoint_path, signal_process);
}

fn cleanupManifestDaemonBuildFallback(
    allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    endpoint_path: []const u8,
    wait_error: anyerror,
) !void {
    try cleanupManifestDaemonBuildFallbackWithSignal(
        allocator,
        invocation_identity,
        endpoint_path,
        wait_error,
        signalManifestDaemonProcess,
    );
}

fn writeManifestDaemonRequestFile(
    allocator: std.mem.Allocator,
    request_path: []const u8,
    mode: ManifestDaemonRequestMode,
    invocation_identity: build_cache.InvocationIdentity,
    response_path: ?[]const u8,
    progress_path: ?[]const u8,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    collect_arc_stats: bool,
    trace_enabled: bool,
    zap_lib_dir_override: ?[]const u8,
) !void {
    var serialized: std.Io.Writer.Allocating = .init(allocator);
    defer serialized.deinit();
    try writeManifestDaemonRequest(
        &serialized.writer,
        mode,
        invocation_identity,
        response_path,
        progress_path,
        project_root,
        target_name,
        build_opts,
        build_overrides,
        collect_arc_stats,
        trace_enabled,
        zap_lib_dir_override,
    );
    try build_cache.writeFileAtomic(allocator, request_path, serialized.written());
}

fn sendManifestDaemonRequest(
    allocator: std.mem.Allocator,
    endpoint_path: []const u8,
    mode: ManifestDaemonRequestMode,
    invocation_identity: build_cache.InvocationIdentity,
    response_path: ?[]const u8,
    progress_path: ?[]const u8,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    collect_arc_stats: bool,
    trace_enabled: bool,
    zap_lib_dir_override: ?[]const u8,
) ![]const u8 {
    const request_id = nextManifestDaemonRequestId(invocation_identity);
    const request_path = try manifestDaemonRequestPath(allocator, invocation_identity, request_id);
    errdefer allocator.free(request_path);
    errdefer std.Io.Dir.cwd().deleteFile(global_io, request_path) catch {};

    try writeManifestDaemonRequestFile(
        allocator,
        request_path,
        mode,
        invocation_identity,
        response_path,
        progress_path,
        project_root,
        target_name,
        build_opts,
        build_overrides,
        collect_arc_stats,
        trace_enabled,
        zap_lib_dir_override,
    );
    try notifyManifestDaemon(endpoint_path, request_path);
    return request_path;
}

fn readManifestDaemonResponseFile(
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    response_path: []const u8,
) !ManifestDaemonResponse {
    const response_bytes = try std.Io.Dir.cwd().readFileAlloc(global_io, response_path, scratch_allocator, .limited(64 * 1024));
    defer scratch_allocator.free(response_bytes);
    var reader: std.Io.Reader = .fixed(response_bytes);
    return readManifestDaemonResponse(allocator, &reader);
}

fn waitForManifestDaemonResponse(
    artifact_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    endpoint_path: []const u8,
    request_path: []const u8,
    response_path: []const u8,
    progress_poller: ?*ManifestDaemonProgressPoller,
) !ManifestDaemonResponse {
    const ack_path = try manifestDaemonRequestAckPath(scratch_allocator, request_path);
    defer scratch_allocator.free(ack_path);

    var request_acknowledged = false;
    var dispatch_wait_started_ms: ?i64 = null;

    while (true) {
        if (progress_poller) |poller| try poller.poll();

        if (try manifestDaemonPathExists(response_path)) {
            if (progress_poller) |poller| try poller.poll();
            return readManifestDaemonResponseFile(artifact_allocator, scratch_allocator, response_path);
        }

        if (!request_acknowledged) {
            if (try manifestDaemonPathExists(ack_path)) {
                request_acknowledged = true;
            }
        }

        if (!request_acknowledged) {
            const pending_warm_status = try manifestDaemonPendingRequestStatus(scratch_allocator, invocation_identity, .warm);
            if (pending_warm_status == .acknowledged) {
                dispatch_wait_started_ms = null;
            } else {
                const now_ms = manifestDaemonNowMs();
                if (dispatch_wait_started_ms == null) dispatch_wait_started_ms = now_ms;
                if (now_ms - dispatch_wait_started_ms.? >= MANIFEST_DAEMON_REQUEST_DISPATCH_TIMEOUT_MS) {
                    return error.DaemonRequestNotAcknowledged;
                }
            }
        }

        if (!try manifestDaemonEndpointIsLive(scratch_allocator, endpoint_path)) {
            return error.DaemonEndpointUnavailable;
        }

        global_io.sleep(std.Io.Duration.fromMilliseconds(25), .awake) catch {};
    }
}

fn warmManifestDaemon(
    allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    collect_arc_stats: bool,
    zap_lib_dir_override: ?[]const u8,
) !ManifestDaemonWarmResult {
    const endpoint_path = try manifestDaemonEndpointPath(allocator, invocation_identity);
    defer allocator.free(endpoint_path);
    const log_path = try manifestDaemonLogPath(allocator, invocation_identity);
    defer allocator.free(log_path);

    try startManifestDaemon(allocator, invocation_identity, endpoint_path, log_path);
    if (try manifestDaemonHasPendingRequest(allocator, invocation_identity, null)) return .pending_request;
    const request_path = try sendManifestDaemonRequest(
        allocator,
        endpoint_path,
        .warm,
        invocation_identity,
        null,
        null,
        project_root,
        target_name,
        build_opts,
        build_overrides,
        collect_arc_stats,
        false,
        zap_lib_dir_override,
    );
    defer allocator.free(request_path);
    return .sent;
}

fn tryManifestDaemonBuild(
    artifact_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    invocation_identity: build_cache.InvocationIdentity,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    collect_arc_stats: bool,
    zap_lib_dir_override: ?[]const u8,
    progress_node: ?zap.progress.Node,
) !ManifestDaemonBuildResult {
    // Escape hatch: `ZAP_NO_MANIFEST_DAEMON` forces the direct (non-daemon)
    // build path. Useful for CI determinism, debugging, and any build the
    // persistent single-manager daemon context cannot serve incrementally.
    if (std.c.getenv("ZAP_NO_MANIFEST_DAEMON") != null) {
        return .{ .fallback = .daemon_unavailable };
    }

    const endpoint_path = try manifestDaemonEndpointPath(scratch_allocator, invocation_identity);
    defer scratch_allocator.free(endpoint_path);
    const log_path = try manifestDaemonLogPath(scratch_allocator, invocation_identity);
    defer scratch_allocator.free(log_path);
    const request_id = nextManifestDaemonRequestId(invocation_identity);
    const response_path = try manifestDaemonResponsePath(scratch_allocator, invocation_identity, request_id);
    defer {
        std.Io.Dir.cwd().deleteFile(global_io, response_path) catch {};
        scratch_allocator.free(response_path);
    }
    const progress_path: ?[]const u8 = if (progress_node != null)
        try manifestDaemonProgressPath(scratch_allocator, invocation_identity, request_id)
    else
        null;
    defer if (progress_path) |path| {
        std.Io.Dir.cwd().deleteFile(global_io, path) catch {};
        scratch_allocator.free(path);
    };

    try truncateManifestDaemonLog(log_path);
    switch (manifestDaemonBuildQueuePolicy(try manifestDaemonHasPendingRequest(scratch_allocator, invocation_identity, .warm))) {
        .send_immediately => {},
        .queue_after_pending_warm => {
            if (progress_node) |node| node.updateCurrentItem("waiting for background warm daemon");
        },
    }
    try startManifestDaemon(scratch_allocator, invocation_identity, endpoint_path, log_path);
    if (progress_path) |path| {
        try truncateManifestDaemonProgress(path);
    }

    var progress_poller: ?ManifestDaemonProgressPoller = if (progress_path) |path|
        try ManifestDaemonProgressPoller.init(scratch_allocator, path, progress_node)
    else
        null;
    defer if (progress_poller) |*poller| poller.deinit();

    if (progress_node) |node| node.updateCurrentItem("querying incremental daemon");
    const request_path = try sendManifestDaemonRequest(
        scratch_allocator,
        endpoint_path,
        .build,
        invocation_identity,
        response_path,
        progress_path,
        project_root,
        target_name,
        build_opts,
        build_overrides,
        collect_arc_stats,
        incrementalTraceEnabled(),
        zap_lib_dir_override,
    );
    defer scratch_allocator.free(request_path);

    if (progress_node) |node| node.updateCurrentItem("waiting for daemon build");
    const response = waitForManifestDaemonResponse(
        artifact_allocator,
        scratch_allocator,
        invocation_identity,
        endpoint_path,
        request_path,
        response_path,
        if (progress_poller) |*poller| poller else null,
    ) catch |err| {
        if (manifestDaemonBuildFallbackFromWaitError(err)) |fallback_reason| {
            try cleanupManifestDaemonBuildFallback(scratch_allocator, invocation_identity, endpoint_path, err);
            return .{ .fallback = fallback_reason };
        }
        return err;
    };
    switch (response) {
        .ok => |artifact| {
            if (progress_poller) |*poller| try poller.poll();
            if (incrementalTraceEnabled()) printManifestDaemonLog(scratch_allocator, log_path);
            return .{ .artifact = artifact };
        },
        .failed => |message| {
            if (progress_poller) |*poller| {
                try poller.poll();
                poller.finishRemaining(.failed);
            }
            if (progress_node) |node| node.handoffExternalOutput(.clear);
            printManifestDaemonLog(scratch_allocator, log_path);
            std.debug.print("Error: incremental daemon build failed: {s}\n", .{message});
            std.process.exit(1);
        },
    }
}

fn ensureManifestDaemonState(
    daemon_state: *ManifestDaemonState,
    allocator: std.mem.Allocator,
    request: ManifestDaemonRequest,
    progress_reporter: ?*zap.progress.Reporter,
) !*IncrementalWatchState {
    if (daemon_state.invocation_identity) |identity| {
        if (!std.mem.eql(u8, &identity, &request.invocation_identity)) return error.InvalidDaemonRequest;
    } else {
        daemon_state.invocation_identity = request.invocation_identity;
    }

    if (daemon_state.incremental_state == null) {
        daemon_state.incremental_state = try establishIncrementalWatchState(
            allocator,
            request.project_root,
            request.target_name,
            request.build_opts,
            request.build_overrides,
            request.collect_arc_stats,
            request.zap_lib_dir_override,
            progress_reporter,
        );
        const extra_watch_path = daemon_state.incremental_state.?.active_manager_source_path;
        daemon_state.watch_snapshot = WatchSnapshot.initFromSourceRoots(
            allocator,
            request.project_root,
            daemon_state.incremental_state.?.manifest_source_roots,
            extra_watch_path,
        ) catch |err| {
            daemon_state.incremental_state.?.deinit();
            daemon_state.incremental_state = null;
            return err;
        };
    }

    return &daemon_state.incremental_state.?;
}

fn rebuildManifestDaemonState(
    daemon_state: *ManifestDaemonState,
    allocator: std.mem.Allocator,
    request: ManifestDaemonRequest,
    progress_reporter: ?*zap.progress.Reporter,
) !*IncrementalWatchState {
    const had_incremental_state = daemon_state.incremental_state != null;
    var state = try ensureManifestDaemonState(daemon_state, allocator, request, progress_reporter);

    var changed_paths: []const []const u8 = &.{};
    if (daemon_state.watch_snapshot) |*snapshot| {
        changed_paths = try snapshot.changedPaths(allocator);
    }
    defer allocator.free(changed_paths);

    var build_zap_changed = false;
    for (changed_paths) |changed_path| {
        if (std.mem.eql(u8, std.fs.path.basename(changed_path), "build.zap")) {
            build_zap_changed = true;
            break;
        }
    }

    if (build_zap_changed) {
        if (daemon_state.watch_snapshot) |*snapshot| snapshot.deinit(allocator);
        daemon_state.watch_snapshot = null;
        state.deinit();
        daemon_state.incremental_state = null;
        state = try ensureManifestDaemonState(daemon_state, allocator, request, progress_reporter);
    } else if (manifestDaemonRequestRequiresSourceRecheck(request.mode, had_incremental_state, changed_paths.len)) {
        state.rebuild(
            allocator,
            request.project_root,
            request.target_name,
            request.build_opts,
            request.build_overrides,
            changed_paths,
            request.zap_lib_dir_override,
            progress_reporter,
        ) catch |err| switch (err) {
            error.ContextInvalidated,
            error.BackendContextInvalidated,
            // P3-J3: an edit changed the per-spawn manager set; the persistent
            // context is pinned to its manager family, so tear it down and
            // recreate. `ensureManifestDaemonState` → `establishIncrementalWatchState`
            // rediscovers the set and binds the fresh context to it (its retry
            // loop handles the empty→discovered transition).
            error.SpawnManagerSetChanged,
            => {
                if (daemon_state.watch_snapshot) |*snapshot| snapshot.deinit(allocator);
                daemon_state.watch_snapshot = null;
                state.deinit();
                daemon_state.incremental_state = null;
                state = try ensureManifestDaemonState(daemon_state, allocator, request, progress_reporter);
            },
            else => return err,
        };
    }

    if (daemon_state.watch_snapshot) |*snapshot| {
        try refreshWatchSnapshotFromSourceRoots(
            snapshot,
            allocator,
            request.project_root,
            state.manifest_source_roots,
            state.active_manager_source_path,
        );
    }

    return state;
}

fn writeManifestDaemonResponseFile(
    allocator: std.mem.Allocator,
    response_path: []const u8,
    state: *const IncrementalWatchState,
) !void {
    var serialized: std.Io.Writer.Allocating = .init(allocator);
    defer serialized.deinit();
    try writeManifestDaemonOkResponse(&serialized.writer, state);
    try build_cache.writeFileAtomic(allocator, response_path, serialized.written());
}

fn writeManifestDaemonErrorFile(
    allocator: std.mem.Allocator,
    response_path: []const u8,
    message: []const u8,
) !void {
    var serialized: std.Io.Writer.Allocating = .init(allocator);
    defer serialized.deinit();
    try writeManifestDaemonErrorResponse(&serialized.writer, message);
    try build_cache.writeFileAtomic(allocator, response_path, serialized.written());
}

fn reportManifestDaemonRequestError(
    allocator: std.mem.Allocator,
    message_allocator: std.mem.Allocator,
    request: ManifestDaemonRequest,
    err: anyerror,
) !void {
    if (request.mode == .build and request.response_path != null) {
        const message = std.fmt.allocPrint(message_allocator, "{s}", .{@errorName(err)}) catch @errorName(err);
        try writeManifestDaemonErrorFile(allocator, request.response_path.?, message);
    } else {
        std.debug.print("Error: manifest incremental daemon warm failed: {s}\n", .{@errorName(err)});
    }
}

fn writeManifestDaemonRequestAckFile(allocator: std.mem.Allocator, request_path: []const u8) ![]const u8 {
    const ack_path = try manifestDaemonRequestAckPath(allocator, request_path);
    errdefer allocator.free(ack_path);
    try build_cache.writeFileAtomic(allocator, ack_path, "ack\n");
    return ack_path;
}

fn handleManifestDaemonRequestFile(
    allocator: std.mem.Allocator,
    request_path: []const u8,
    daemon_state: *ManifestDaemonState,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const request_allocator = arena.allocator();

    const request_bytes = try std.Io.Dir.cwd().readFileAlloc(global_io, request_path, request_allocator, .limited(128 * 1024));
    defer std.Io.Dir.cwd().deleteFile(global_io, request_path) catch {};

    var reader: std.Io.Reader = .fixed(request_bytes);
    const request = try readManifestDaemonRequest(request_allocator, &reader);
    const ack_path = try writeManifestDaemonRequestAckFile(allocator, request_path);
    defer {
        std.Io.Dir.cwd().deleteFile(global_io, ack_path) catch {};
        allocator.free(ack_path);
    }
    if (request.mode == .shutdown) return true;

    setIncrementalTraceEnabledOverride(request.trace_enabled);
    compiler.setIncrementalTraceEnabledOverride(request.trace_enabled);
    defer {
        compiler.setIncrementalTraceEnabledOverride(null);
        setIncrementalTraceEnabledOverride(null);
    }

    var progress_writer: ?ManifestDaemonProgressWriter = null;
    if (request.progress_path) |progress_path| {
        progress_writer = ManifestDaemonProgressWriter.init(allocator, progress_path) catch |err| {
            try reportManifestDaemonRequestError(allocator, request_allocator, request, err);
            return false;
        };
    }
    defer if (progress_writer) |*writer| writer.deinit();

    var progress_reporter: ?zap.progress.Reporter = if (progress_writer) |*writer|
        zap.progress.Reporter.initWithEventSink("Compiling", false, 100, writer.sink())
    else
        null;

    const state = rebuildManifestDaemonState(
        daemon_state,
        allocator,
        request,
        if (progress_reporter) |*reporter| reporter else null,
    ) catch |err| {
        try reportManifestDaemonRequestError(allocator, request_allocator, request, err);
        return false;
    };

    if (progress_writer) |*writer| {
        writer.check() catch |err| {
            try reportManifestDaemonRequestError(allocator, request_allocator, request, err);
            return false;
        };
    }

    if (request.mode == .build) {
        const response_path = request.response_path orelse return error.InvalidDaemonProtocol;
        try writeManifestDaemonResponseFile(allocator, response_path, state);
    }

    return false;
}

const ManifestDaemonEndpointProcessResult = struct {
    read_any: bool,
    shutdown_requested: bool,
};

const ManifestDaemonBuildQueuePolicy = enum {
    send_immediately,
    queue_after_pending_warm,
};

fn manifestDaemonBuildQueuePolicy(has_pending_warm_request: bool) ManifestDaemonBuildQueuePolicy {
    if (has_pending_warm_request) return .queue_after_pending_warm;
    return .send_immediately;
}

fn processManifestDaemonEndpoint(
    allocator: std.mem.Allocator,
    endpoint: ManifestDaemonEndpoint,
    daemon_state: *ManifestDaemonState,
    pending_line: *std.ArrayListUnmanaged(u8),
) !ManifestDaemonEndpointProcessResult {
    var read_buffer: [4096]u8 = undefined;
    var read_any = false;

    while (true) {
        const bytes_read = std.posix.read(endpoint.read_fd, &read_buffer) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (bytes_read == 0) break;
        read_any = true;

        for (read_buffer[0..bytes_read]) |byte| {
            if (byte == '\n') {
                if (pending_line.items.len > 0) {
                    const request_path = try allocator.dupe(u8, pending_line.items);
                    defer allocator.free(request_path);
                    pending_line.clearRetainingCapacity();
                    const shutdown_requested = handleManifestDaemonRequestFile(allocator, request_path, daemon_state) catch |err| blk: {
                        std.debug.print("Error: manifest incremental daemon request failed: {s}\n", .{@errorName(err)});
                        break :blk false;
                    };
                    if (shutdown_requested) return .{
                        .read_any = true,
                        .shutdown_requested = true,
                    };
                }
            } else {
                try pending_line.append(allocator, byte);
                if (pending_line.items.len > std.fs.max_path_bytes) return error.InvalidDaemonProtocol;
            }
        }
    }

    return .{
        .read_any = read_any,
        .shutdown_requested = false,
    };
}

fn runManifestIncrementalDaemon(allocator: std.mem.Allocator, endpoint_path: []const u8) !void {
    const endpoint = try openManifestDaemonEndpointForRead(allocator, endpoint_path);
    defer endpoint.deinit();
    const pid_path = try manifestDaemonPidPathFromEndpointPath(allocator, endpoint_path);
    defer allocator.free(pid_path);

    var daemon_state: ManifestDaemonState = .{};
    defer daemon_state.deinit(allocator);
    var pending_line: std.ArrayListUnmanaged(u8) = .empty;
    defer pending_line.deinit(allocator);
    var last_activity_ms = manifestDaemonNowMs();

    var loop_error: ?anyerror = null;
    while (true) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = endpoint.read_fd,
            .events = std.c.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&poll_fds, 250) catch |err| {
            loop_error = err;
            break;
        };
        if (ready > 0) {
            const result = processManifestDaemonEndpoint(allocator, endpoint, &daemon_state, &pending_line) catch |err| {
                loop_error = err;
                break;
            };
            if (result.read_any) {
                last_activity_ms = manifestDaemonNowMs();
            }
            if (result.shutdown_requested) break;
        }

        const idle_ms = manifestDaemonNowMs() - last_activity_ms;
        if (idle_ms >= MANIFEST_DAEMON_IDLE_TIMEOUT_MS) {
            break;
        }
    }

    try deleteManifestDaemonFileIfPresent(endpoint_path);
    try deleteManifestDaemonFileIfPresent(pid_path);
    if (loop_error) |err| return err;
}

fn establishIncrementalWatchState(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    collect_arc_stats: bool,
    zap_lib_dir_override: ?[]const u8,
    progress_reporter: ?*zap.progress.Reporter,
) InteractiveWatchSetupError!IncrementalWatchState {
    // P3-J3: the manager family we (re)create the persistent context with. A
    // fresh session starts empty (single-manager assumption); the retry below
    // rebinds it to whatever the initial resolver-wired build DISCOVERS, so a
    // multi-manager binary converges on a correctly-bound context. Owned across
    // iterations.
    var attempt_spawn_managers: []const zir_backend.SpawnManagerRegistration = &.{};
    defer freeSpawnManagerRegistrations(allocator, attempt_spawn_managers);

    // The initial build may discover a per-spawn manager set differing from what
    // the context was created with (`SpawnManagerSetChanged`); recreate the
    // context bound to the discovered set and retry. The resolver assigns
    // registry indices deterministically, so this converges in ONE retry — a
    // second change would be a bug and propagates as a hard failure.
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var state = try IncrementalWatchState.init(allocator, project_root, target_name, build_opts, build_overrides, collect_arc_stats, zap_lib_dir_override, progress_reporter, attempt_spawn_managers);
        state.rebuild(allocator, project_root, target_name, build_opts, build_overrides, &.{}, zap_lib_dir_override, progress_reporter) catch |err| {
            if (err == error.SpawnManagerSetChanged and attempt == 0) {
                const discovered = dupeSpawnManagerRegistrations(allocator, state.discovered_spawn_managers) catch {
                    state.deinit();
                    return error.OutOfMemory;
                };
                state.deinit();
                freeSpawnManagerRegistrations(allocator, attempt_spawn_managers);
                attempt_spawn_managers = discovered;
                continue;
            }
            state.deinit();
            std.debug.print("Initial incremental build failed ({s})\n", .{@errorName(err)});
            return err;
        };
        return state;
    }
}

/// Watch source files for changes and rebuild (and optionally re-run) on change.
/// This function loops forever until the process is killed (e.g. Ctrl+C).
///
/// Uses Zig 0.16's Io.Timestamp for portable mtime comparison. Watch mode
/// establishes the persistent incremental context before the first user-visible
/// build, so the next edit can immediately diff against that baseline.
fn watchAndRebuild(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    run_mode: WatchRunMode,
    run_args: []const []const u8,
    collect_arc_stats: bool,
    zap_lib_dir_override: ?[]const u8,
) !void {
    const poll_duration = std.Io.Duration.fromMilliseconds(500);

    var watch_snapshot = WatchSnapshot.init(allocator, project_root, target_name, build_opts, build_overrides, zap_lib_dir_override, null) catch |err| blk: {
        switch (classifyWatchSnapshotInitFailure(err)) {
            .use_project_only => |reason| {
                std.debug.print("Error: manifest-based watch input collection unavailable ({s}); watching project files until the manifest is restored\n", .{@tagName(reason)});
                break :blk WatchSnapshot.initProjectOnly(allocator, project_root) catch |project_only_err| {
                    try failInteractiveWatchSetupOnSevereError(project_only_err);
                    return project_only_err;
                };
            },
            .propagate_setup_error => |setup_err| {
                try failInteractiveWatchSetupOnSevereError(setup_err);
                return setup_err;
            },
        }
    };
    defer watch_snapshot.deinit(allocator);

    var incr_state: ?IncrementalWatchState = null;
    {
        var initial_progress = zap.progress.Reporter.init("Compiling", stderrProgressEnabled());
        defer initial_progress.finish();
        const initial_progress_reporter: ?*zap.progress.Reporter = if (initial_progress.enabled) &initial_progress else null;
        incr_state = establishIncrementalWatchState(allocator, project_root, target_name, build_opts, build_overrides, collect_arc_stats, zap_lib_dir_override, initial_progress_reporter) catch |err| blk: {
            std.debug.print("Initial incremental setup failed ({s})\n", .{@errorName(err)});
            try failInteractiveWatchSetupOnSevereError(err);
            break :blk null;
        };
    }
    defer if (incr_state) |*s| s.deinit();

    if (incr_state) |*state| {
        runWatchArtifact(allocator, target_name, state, run_mode, run_args);
        try refreshWatchSnapshot(&watch_snapshot, allocator, project_root, target_name, build_opts, build_overrides, zap_lib_dir_override, state.active_manager_source_path);
    }
    std.debug.print("\n[watching for changes...]\n", .{});

    while (true) {
        global_io.sleep(poll_duration, .awake) catch {};

        const changed_paths = watch_snapshot.changedPaths(allocator) catch |err| {
            std.debug.print("Error: watch change detection failed: {s}\n", .{@errorName(err)});
            return err;
        };
        defer allocator.free(changed_paths);

        if (changed_paths.len > 0) {
            // Clear terminal screen
            const stdout = std.Io.File.stdout();
            stdout.writeStreamingAll(global_io, "\x1b[2J\x1b[H") catch {};

            // Check if build.zap itself changed — if so, tear down incremental
            // state since the manifest may have changed
            var build_zap_changed = false;
            for (changed_paths) |cp| {
                if (std.mem.eql(u8, std.fs.path.basename(cp), "build.zap")) {
                    build_zap_changed = true;
                    break;
                }
            }
            if (build_zap_changed) {
                if (incr_state) |*s| {
                    s.deinit();
                    incr_state = null;
                }
            }

            // Try incremental rebuild if state exists
            var rebuild_succeeded = false;
            var should_establish_state = incr_state == null;
            if (incr_state) |*state| {
                var progress = zap.progress.Reporter.init("Compiling", stderrProgressEnabled());
                const progress_reporter: ?*zap.progress.Reporter = if (progress.enabled) &progress else null;
                defer progress.finish();

                rebuild_succeeded = blk: {
                    state.rebuild(allocator, project_root, target_name, build_opts, build_overrides, changed_paths, zap_lib_dir_override, progress_reporter) catch |err| {
                        if (err == error.ContextInvalidated or err == error.BackendContextInvalidated) {
                            std.debug.print("Incremental context invalidated; rebuilding from a fresh context\n", .{});
                        } else {
                            std.debug.print("Incremental build failed ({s})\n", .{@errorName(err)});
                        }
                        const action = classifyInteractiveWatchRebuildFailure(err) catch |severe_err| {
                            return severe_err;
                        };
                        switch (action) {
                            .wait_for_next_change => {},
                            .rebuild_fresh_context => {
                                state.deinit();
                                incr_state = null;
                                should_establish_state = true;
                            },
                        }
                        break :blk false;
                    };
                    break :blk true;
                };
            }

            if (incr_state == null and should_establish_state) {
                {
                    var progress = zap.progress.Reporter.init("Compiling", stderrProgressEnabled());
                    defer progress.finish();
                    const progress_reporter: ?*zap.progress.Reporter = if (progress.enabled) &progress else null;
                    incr_state = establishIncrementalWatchState(allocator, project_root, target_name, build_opts, build_overrides, collect_arc_stats, zap_lib_dir_override, progress_reporter) catch |err| blk: {
                        std.debug.print("Incremental setup failed ({s})\n", .{@errorName(err)});
                        try failInteractiveWatchSetupOnSevereError(err);
                        break :blk null;
                    };
                }
                rebuild_succeeded = incr_state != null;
            }

            if (rebuild_succeeded) {
                if (incr_state) |*state| {
                    runWatchArtifact(allocator, target_name, state, run_mode, run_args);
                }
            }
            if (rebuild_succeeded or incr_state != null) {
                const extra_watch_path = if (incr_state) |*state| state.active_manager_source_path else null;
                try refreshWatchSnapshot(&watch_snapshot, allocator, project_root, target_name, build_opts, build_overrides, zap_lib_dir_override, extra_watch_path);
            }
            std.debug.print("\n[watching for changes...]\n", .{});
        }
    }
}

/// Result from an async build task in watch mode (used for first non-incremental build).
const WatchBuildResult = struct {
    output_path: ?[]const u8 = null,
    failed: bool = false,
};

/// Task function for async watch builds. Returns a WatchBuildResult
/// suitable for use with Io.Future.
fn watchBuildTask(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    build_overrides: BuildOverrides,
    collect_arc_stats: bool,
    zap_lib_dir_override: ?[]const u8,
) WatchBuildResult {
    const artifact = buildTarget(allocator, project_root, target_name, build_opts, build_overrides, collect_arc_stats, zap_lib_dir_override) catch |err| {
        std.debug.print("Build error: {}\n", .{err});
        return .{ .failed = true };
    };
    // `path` ownership transfers into `WatchBuildResult.output_path`;
    // free just the `target` dup so it isn't leaked per rebuild.
    artifact.freeTargetOnly(allocator);
    return .{ .output_path = artifact.path };
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const ParsedArgs = struct {
    target: ?[]const u8,
    build_file: ?[]const u8,
    /// Every `-D<key>=<value>` collected verbatim for CTFE: the
    /// manifest reads these through `System.get_build_opt(name)`
    /// (Zap's analogue of Zig's `b.option`). Includes the recognized
    /// build-system keys too, so `System.get_build_opt("optimize")`
    /// keeps returning the requested mode.
    build_opts: std.StringHashMapUnmanaged([]const u8),
    /// The recognized Zig-style build flags parsed by the SINGLE
    /// shared `parseBuildOverrides`. Applied per-field onto the
    /// `BuildConfig` after `build.zap` CTFE so the CLI is the ultimate
    /// source of truth (an unset flag preserves the manifest value).
    build_overrides: BuildOverrides = .{},
    run_args: []const []const u8,
    seed: ?[]const u8 = null,
    timings: bool = false,
    slowest: ?[]const u8 = null,
    watch: bool = false,
    trace_incremental: bool = false,
    collect_arc_stats: bool = false,
    no_deps: bool = false,
    /// Explicit `--zap-lib-dir <dir>` override for the Zap stdlib root.
    /// Null when the flag is absent, in which case resolution falls
    /// through to `ZAP_LIB_DIR`, then exe-relative, then cwd.
    zap_lib_dir: ?[]const u8 = null,

    fn deinit(self: *ParsedArgs, allocator: std.mem.Allocator) void {
        self.build_opts.deinit(allocator);
    }
};

fn parseTargetArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParsedArgs {
    var result = ParsedArgs{
        .target = null,
        .build_file = null,
        .build_opts = .empty,
        .run_args = &.{},
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is program args
            if (i + 1 < args.len) {
                result.run_args = args[i + 1 ..];
            }
            break;
        } else if (std.mem.eql(u8, arg, "--build-file")) {
            i += 1;
            if (i < args.len) {
                result.build_file = args[i];
            } else {
                // stderr writer removed in 0.16
                std.debug.print("Error: --build-file requires a path\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--zap-lib-dir")) {
            i += 1;
            if (i < args.len) {
                result.zap_lib_dir = args[i];
            } else {
                std.debug.print("Error: --zap-lib-dir requires a path\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
            result.watch = true;
        } else if (std.mem.eql(u8, arg, "--trace-incremental")) {
            result.trace_incremental = true;
        } else if (std.mem.eql(u8, arg, "--collect-arc-stats")) {
            result.collect_arc_stats = true;
        } else if (std.mem.eql(u8, arg, "--no-deps")) {
            result.no_deps = true;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i < args.len) {
                result.seed = args[i];
            } else {
                std.debug.print("Error: --seed requires a value\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--timings")) {
            result.timings = true;
        } else if (std.mem.eql(u8, arg, "--slowest")) {
            i += 1;
            if (i < args.len) {
                result.slowest = args[i];
            } else {
                std.debug.print("Error: --slowest requires a value\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-D")) {
            // Collect EVERY -Dkey=value verbatim for the manifest's
            // `System.get_build_opt` (Zap's analogue of Zig's
            // `b.option`) — recognized build-system keys included, so
            // `System.get_build_opt("optimize")` still works. The
            // recognized subset is ALSO captured into
            // `build_overrides` below by the shared parser; that is
            // the authoritative per-field override.
            const kv = arg[2..];
            if (std.mem.findScalar(u8, kv, '=')) |eq| {
                try result.build_opts.put(allocator, kv[0..eq], kv[eq + 1 ..]);
            } else {
                try result.build_opts.put(allocator, kv, "true");
            }
        } else if (result.target == null) {
            result.target = arg;
        } else {
            // stderr writer removed in 0.16
            std.debug.print("Error: unexpected argument: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    // Capture the recognized Zig-style build flags through the SINGLE
    // shared parser. Scan only the leading region (everything before
    // the first positional/`--`) so a post-`--` program arg that
    // looks like `-Doptimize=...` is never mis-parsed as a build flag.
    // On the manifest path an unrecognized `-D` key is NOT fatal here
    // (it already went to `build_opts` for `System.get_build_opt`,
    // mirroring Zig's `b.option`); only a malformed value for a
    // RECOGNIZED key (e.g. a bad `-Doptimize=`) is reported.
    const leading_end = manifestLeadingFlagEnd(args);
    const parsed_overrides = parseBuildOverrides(allocator, args, leading_end) catch
        return error.OutOfMemory;
    switch (parsed_overrides) {
        .ok => |ov| result.build_overrides = ov,
        .err => |msg| {
            // Only surface diagnostics for malformed RECOGNIZED-key
            // values; a bare unknown key is a manifest build option
            // (Zig parity) and must not abort the manifest build.
            if (isRecognizedBuildFlagError(args, leading_end)) {
                std.debug.print("Error: {s}\n", .{msg});
                std.process.exit(1);
            }
        },
    }

    return result;
}

/// Index of the program-args boundary in `args` — the position of the
/// first `--` (everything after which is forwarded verbatim to the
/// program in `zap run <script> -- ...`), or `args.len` when there is
/// no `--`.
///
/// This is the end of the build-flag region scanned by the shared
/// `parseBuildOverrides`. Crucially the boundary is `--`, NOT the
/// first positional target: `zap build <target> -Dtarget=...` and
/// `zap run <target> -Dcpu=...` are valid and historically supported
/// (HEAD's linear arg scan collected `-D` from anywhere before `--`,
/// e.g. the documented `zap build my_app -Doptimize=release_fast`).
/// Stopping at the first positional silently dropped every recognized
/// `-D` override placed after `<target>`, which for `-Dtarget=`/
/// `-Dcpu=` is a silent wrong-arch/wrong-config build — the worst
/// possible failure mode. The positional target itself is harmlessly
/// ignored by `parseBuildOverrides` (its `!startsWith("-D") continue`),
/// so the region only needs to exclude post-`--` program args. Value-
/// consuming flags (`--build-file`, `--zap-lib-dir`, `--seed`, `--slowest`) still
/// skip their value so a `--seed --` value cannot be misread as the
/// program-args boundary; `parseBuildOverrides` independently skips the
/// same flag/value pairs so a value like `--seed -Dx=1` is never
/// mis-parsed as a build flag.
fn manifestLeadingFlagEnd(args: []const []const u8) usize {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) return i;
        if (std.mem.eql(u8, arg, "--build-file") or
            std.mem.eql(u8, arg, "--zap-lib-dir") or
            std.mem.eql(u8, arg, "--seed") or
            std.mem.eql(u8, arg, "--slowest"))
        {
            i += 1; // value-consuming: skip the value too
            continue;
        }
        // Every other token (recognized flags, `-D` flags, AND the
        // positional target) stays inside the build-flag region. Only
        // `--` (handled above) or running out of args ends it.
    }
    return args.len;
}

/// True iff the first malformed `-D` token in the leading region
/// targets a RECOGNIZED build-system key (`optimize`/`memory`/etc.).
/// Used by the manifest path to decide whether a `parseBuildOverrides`
/// `.err` is a real user error (bad value for a known flag → abort) or
/// merely an unknown custom key destined for `System.get_build_opt`
/// (Zig `b.option` parity → ignore here). A `-D<key>` with no `=` is a
/// bare manifest build option (→ ignore) ONLY when `<key>` is
/// unrecognized; a recognized build flag with no value (`-Doptimize`,
/// `-Dmemory`, …) is a missing-required-value error (→ abort). The lone
/// `leaks-fatal` recognized key has a valid bare presence form and is
/// excluded from the valueless-error check.
fn isRecognizedBuildFlagError(args: []const []const u8, leading_end: usize) bool {
    const end = @min(leading_end, args.len);
    var i: usize = 0;
    while (i < end) {
        if (buildFlagScanSkip(args, i, end)) |next| {
            i = next;
            continue;
        }
        const a = args[i];
        i += 1;
        const kv = a[2..];
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse {
            // A `-D<key>` with no `=value`. For an UNRECOGNIZED key this
            // is a bare manifest build option (Zig `b.option` parity) and
            // is NOT an error — `parseBuildOverrides` would have returned
            // `.err` only because the key is unknown, and that case must
            // not abort the manifest build. But a RECOGNIZED build flag
            // (`-Doptimize`, `-Dmemory`, …) genuinely REQUIRES its value:
            // the valueless form is the "build flag is missing a value"
            // error `parseBuildOverrides` reports, so classify it as a
            // recognized-flag error here so the manifest path surfaces
            // the precise diagnostic instead of falling through to a
            // confusing "Unknown target" panic. `leaks-fatal` is the one
            // recognized key whose bare form is VALID (a presence toggle),
            // so it never reaches here as an `.err` and is excluded.
            for (BUILD_FLAG_KEYS) |recognized| {
                if (std.mem.eql(u8, recognized, "leaks-fatal")) continue;
                if (std.mem.eql(u8, kv, recognized)) return true;
            }
            continue;
        };
        const key = kv[0..eq];
        for (BUILD_FLAG_KEYS) |recognized| {
            if (std.mem.eql(u8, key, recognized)) {
                // A recognized key is present; if its value parses
                // cleanly the parser would not have returned `.err`,
                // so reaching here means THIS is the offending flag.
                if (std.mem.eql(u8, key, "optimize")) {
                    return parseScriptOptimizeMode(kv[eq + 1 ..]) == null;
                }
                // memory/target/cpu only fail on an empty value.
                return kv[eq + 1 ..].len == 0;
            }
        }
    }
    return false;
}

const testing = std.testing;

test "P4J2: embedded Zig lib absence remains optional for system fallback" {
    const resolved = try resolveZigLibDirFromCandidates(.absent, .absent, .{ .found = "/system/zig/lib" });
    try testing.expectEqualStrings("/system/zig/lib", resolved);
}

test "P4J2: trusted Zig lib failure blocks embedded and system fallback" {
    try testing.expectError(
        error.ZigLibDirAccessFailed,
        resolveZigLibDirFromCandidates(
            .{ .failed = error.ZigLibDirAccessFailed },
            .{ .found = "/embedded/zig/lib" },
            .{ .found = "/system/zig/lib" },
        ),
    );
}

test "P4J2: embedded Zig lib extraction failure blocks system fallback" {
    try testing.expectError(
        error.EmbeddedZigLibArchiveExtractFailed,
        resolveZigLibDirFromCandidates(
            .absent,
            .{ .failed = error.EmbeddedZigLibArchiveExtractFailed },
            .{ .found = "/system/zig/lib" },
        ),
    );
}

test "P4J2: system Zig lib failure propagates after prior absence" {
    try testing.expectError(
        error.ZigLibDirCanonicalizeFailed,
        resolveZigLibDirFromCandidates(
            .absent,
            .absent,
            .{ .failed = error.ZigLibDirCanonicalizeFailed },
        ),
    );
}

test "P4J2: trusted Zig lib success preserves precedence over broken lower tiers" {
    const resolved = try resolveZigLibDirFromCandidates(
        .{ .found = "/trusted/zig/lib" },
        .{ .failed = error.EmbeddedZigLibArchiveExtractFailed },
        .{ .failed = error.ZigLibDirAccessFailed },
    );
    try testing.expectEqualStrings("/trusted/zig/lib", resolved);
}

test "P4J2: empty embedded Zig lib archive is classified as absent" {
    const resolved = try resolveEmbeddedZigLibDirFromArchive(testing.allocator, null, "");
    try testing.expectEqual(@as(?[]const u8, null), resolved);
}

test "P4J2: embedded Zig lib cache root failure is required infrastructure" {
    try testing.expectError(
        error.EmbeddedZigLibCacheUnavailable,
        resolveEmbeddedZigLibDirFromArchive(testing.allocator, null, "not empty"),
    );
}

test "P4J2: embedded Zig lib decompressor init failure frees caller buffer" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_home = try tmp_dir.dir.realPathFileAlloc(global_io, ".", testing.allocator);
    defer testing.allocator.free(cache_home);

    try testing.expectError(
        error.EmbeddedZigLibArchiveDecompressFailed,
        extractEmbeddedZigLibFromArchive(testing.allocator, cache_home, "not an xz archive"),
    );
}

test "P4J2: output/cache preparation propagates backend cache mkdir failure" {
    var creator = FailingRequiredDirCreator{
        .fail_on_call = 1,
        .failure = error.AccessDenied,
    };

    try testing.expectError(
        error.AccessDenied,
        prepareRequiredOutputCacheDirsWithCreator(&creator, ".zap-cache", "zap-out/bin"),
    );
    try testing.expectEqual(@as(usize, 1), creator.calls);
}

test "P4J2: output/cache preparation propagates output mkdir failure" {
    var creator = FailingRequiredDirCreator{
        .fail_on_call = 2,
        .failure = error.PathAlreadyExists,
    };

    try testing.expectError(
        error.PathAlreadyExists,
        prepareRequiredOutputCacheDirsWithCreator(&creator, ".zap-cache", "zap-out/bin"),
    );
    try testing.expectEqual(@as(usize, 2), creator.calls);
}

const FailingRequiredDirCreator = struct {
    fail_on_call: usize,
    failure: anyerror,
    calls: usize = 0,

    fn createDirPath(self: *FailingRequiredDirCreator, path: []const u8) anyerror!void {
        _ = path;
        self.calls += 1;
        if (self.calls == self.fail_on_call) return self.failure;
    }
};

const BufferDiscoveryDiagnosticPrinter = struct {
    allocator: std.mem.Allocator,
    buffer: *std.ArrayListUnmanaged(u8),

    fn print(self: BufferDiscoveryDiagnosticPrinter, comptime format: []const u8, args: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const NoopDiscoveryDiagnosticPrinter = struct {
    fn print(_: NoopDiscoveryDiagnosticPrinter, comptime format: []const u8, args: anytype) !void {
        _ = format;
        _ = args;
    }
};

test "discovery missing-struct diagnostic renders expected path and frees allocation" {
    var captured: std.ArrayListUnmanaged(u8) = .empty;
    defer captured.deinit(testing.allocator);

    try printStructNotFoundDiscoveryDiagnostic(
        testing.allocator,
        BufferDiscoveryDiagnosticPrinter{
            .allocator = testing.allocator,
            .buffer = &captured,
        },
        "App.HttpServer",
    );

    try testing.expectEqualStrings(
        "Error: Struct `App.HttpServer` not found — expected app/http_server.zap in one of the source roots\n",
        captured.items,
    );
}

test "discovery missing-struct diagnostic propagates expected-path OOM" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    try testing.expectError(
        error.OutOfMemory,
        printStructNotFoundDiscoveryDiagnostic(
            failing_allocator.allocator(),
            NoopDiscoveryDiagnosticPrinter{},
            "App",
        ),
    );
}

test "discoverManifestSources preserves discovery OutOfMemory" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const config = zap.builder.BuildConfig{
        .name = "app",
        .version = "0.1.0",
        .kind = .bin,
        .root = "App.main/0",
    };

    try testing.expectError(
        error.OutOfMemory,
        discoverManifestSources(
            failing_allocator.allocator(),
            ".",
            config,
            &.{},
            null,
        ),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "discoverManifestSources owns graph-derived paths and metadata" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "lib");
    try tmp_dir.dir.writeFile(global_io, .{
        .sub_path = "lib/app.zap",
        .data =
        \\pub struct App {
        \\  pub fn main() {
        \\  }
        \\}
        \\
        ,
    });

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(project_root);
    const lib_dir = try std.fs.path.join(allocator, &.{ project_root, "lib" });
    defer allocator.free(lib_dir);
    const expected_app_path = try std.fs.path.join(allocator, &.{ lib_dir, "app.zap" });
    defer allocator.free(expected_app_path);

    const paths = [_][]const u8{"lib/**/*.zap"};
    const config = zap.builder.BuildConfig{
        .name = "app",
        .version = "0.1.0",
        .kind = .bin,
        .root = "App.main/0",
        .paths = &paths,
    };
    const source_roots = [_]zap.discovery.SourceRoot{
        .{ .name = "project", .path = lib_dir },
    };

    var manifest_sources = try discoverManifestSources(
        allocator,
        project_root,
        config,
        &source_roots,
        null,
    );
    defer manifest_sources.deinit();

    var churn: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (churn.items) |allocation| allocator.free(allocation);
        churn.deinit(allocator);
    }
    for (0..128) |_| {
        const allocation = try allocator.alloc(u8, expected_app_path.len);
        @memset(allocation, 'x');
        try churn.append(allocator, allocation);
    }

    try testing.expectEqual(@as(usize, 1), manifest_sources.source_units.len);
    try testing.expectEqualStrings(expected_app_path, manifest_sources.source_units[0].file_path);
    try testing.expectEqualStrings("App", manifest_sources.source_units[0].primary_struct_name.?);
    try testing.expectEqualStrings("App", manifest_sources.source_file_to_struct.get(expected_app_path).?);
    const structs = manifest_sources.source_file_to_structs.get(expected_app_path).?;
    try testing.expectEqual(@as(usize, 1), structs.len);
    try testing.expectEqualStrings("App", structs[0]);

    const canonical = try canonicalPathAlloc(allocator, manifest_sources.source_units[0].file_path);
    defer allocator.free(canonical);
    try testing.expectEqualStrings(expected_app_path, canonical);
}

test "canonical path propagation preserves OutOfMemory" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    try temporary_directory.dir.writeFile(global_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {}",
    });

    const file_path = try temporary_directory.dir.realPathFileAlloc(global_io, "app.zap", testing.allocator);
    defer testing.allocator.free(file_path);

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    try testing.expectError(
        error.OutOfMemory,
        canonicalPathAlloc(failing_allocator.allocator(), file_path),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: canonical path propagation reports canonicalization failures" {
    try testing.expectError(
        error.FileNotFound,
        canonicalPathAlloc(testing.allocator, "missing/p4j2/main-canonical-input.zap"),
    );
}

test "incremental module hashes own module-name keys" {
    var hashes: ComputedIncrementalHashes = .{
        .allocator = testing.allocator,
        .modules = std.StringHashMap(u64).init(testing.allocator),
    };
    defer hashes.deinit();

    const borrowed_name = try testing.allocator.dupe(u8, "Example");
    defer testing.allocator.free(borrowed_name);

    const slot = try moduleHashSlot(testing.allocator, &hashes.modules, borrowed_name);
    slot.* = 123;

    var iter = hashes.modules.iterator();
    const entry = iter.next().?;
    try testing.expect(entry.key_ptr.*.ptr != borrowed_name.ptr);
    try testing.expectEqual(@as(u64, 123), hashes.modules.get("Example").?);
}

test "incremental backend update decision follows emitted graph hashes" {
    var previous_modules = std.StringHashMap(u64).init(testing.allocator);
    defer previous_modules.deinit();
    try previous_modules.put("Bool", 100);
    try previous_modules.put("TestRunner", 200);

    var current_hashes: ComputedIncrementalHashes = .{
        .allocator = testing.allocator,
        .modules = std.StringHashMap(u64).init(testing.allocator),
        .root_present = true,
        .root_hash = 300,
    };
    defer current_hashes.modules.deinit();
    try current_hashes.modules.put("Bool", 100);
    try current_hashes.modules.put("TestRunner", 200);

    try testing.expect(!emittedIncrementalGraphChanged(true, 300, &previous_modules, &current_hashes));

    try current_hashes.modules.put("Bool", 101);
    try testing.expect(emittedIncrementalGraphChanged(true, 300, &previous_modules, &current_hashes));
}

test "incremental backend selection identifies changed modules and root" {
    var previous_modules = std.StringHashMap(u64).init(testing.allocator);
    defer previous_modules.deinit();
    try previous_modules.put("Bool", 100);
    try previous_modules.put("TestRunner", 200);

    var current_hashes: ComputedIncrementalHashes = .{
        .allocator = testing.allocator,
        .modules = std.StringHashMap(u64).init(testing.allocator),
        .root_present = true,
        .root_hash = 300,
    };
    defer current_hashes.modules.deinit();
    try current_hashes.modules.put("Bool", 101);
    try current_hashes.modules.put("TestRunner", 200);

    const changed_bool = try selectChangedIncrementalModulesFromHashes(
        testing.allocator,
        true,
        300,
        &previous_modules,
        &current_hashes,
    );
    defer testing.allocator.free(changed_bool.struct_names);
    try testing.expect(!changed_bool.include_root);
    try testing.expectEqual(@as(usize, 1), changed_bool.struct_names.len);
    try testing.expectEqualStrings("Bool", changed_bool.struct_names[0]);

    current_hashes.root_hash = 301;
    current_hashes.modules.getPtr("Bool").?.* = 100;
    const changed_root = try selectChangedIncrementalModulesFromHashes(
        testing.allocator,
        true,
        300,
        &previous_modules,
        &current_hashes,
    );
    defer testing.allocator.free(changed_root.struct_names);
    try testing.expect(changed_root.include_root);
    try testing.expectEqual(@as(usize, 0), changed_root.struct_names.len);
}

fn testIncrementalFunction(
    function_id: ir.FunctionId,
    name: []const u8,
    struct_name: ?[]const u8,
) ir.Function {
    return .{
        .id = function_id,
        .name = name,
        .struct_name = struct_name,
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &.{},
        .is_closure = false,
        .captures = &.{},
    };
}

fn selectionContainsModuleName(module_names: []const []const u8, expected_name: []const u8) bool {
    for (module_names) |module_name| {
        if (std.mem.eql(u8, module_name, expected_name)) return true;
    }
    return false;
}

fn expectIncrementalModulesExactly(
    actual_names: []const []const u8,
    expected_names: []const []const u8,
) !void {
    try testing.expectEqual(expected_names.len, actual_names.len);
    for (expected_names) |expected_name| {
        try testing.expect(selectionContainsModuleName(actual_names, expected_name));
    }
    for (actual_names) |actual_name| {
        try testing.expect(selectionContainsModuleName(expected_names, actual_name));
    }
}

const OwnedPreparedIncrementalBackendPlan = struct {
    selection: OwnedIncrementalModuleSelection,
    invalidation: zir_backend.SelectedUpdateInvalidationPolicy,

    fn deinit(self: OwnedPreparedIncrementalBackendPlan, allocator: std.mem.Allocator) void {
        self.selection.deinit(allocator);
    }
};

fn preparedBackendPlanForTest(
    result: *const compiler.CompileResult,
    previous_root_present: bool,
    previous_root_hash: u64,
    previous_modules: *const std.StringHashMap(u64),
    current_hashes: *const ComputedIncrementalHashes,
) !OwnedPreparedIncrementalBackendPlan {
    const plan = try selectPreparedIncrementalBackendPlan(
        testing.allocator,
        result,
        previous_root_present,
        previous_root_hash,
        previous_modules,
        current_hashes,
    );
    defer testing.allocator.free(plan.selection.struct_names);
    return .{
        .selection = try normalizeIncrementalSelectionForBackend(testing.allocator, plan.selection),
        .invalidation = plan.invalidation,
    };
}

test "prepared incremental backend selection keeps Bool body changes precise" {
    var previous_modules = std.StringHashMap(u64).init(testing.allocator);
    defer previous_modules.deinit();
    try previous_modules.put("Bool", 100);
    try previous_modules.put("Zap_BoolTest", 200);
    try previous_modules.put("CompileAfterRunner", 300);

    var current_hashes: ComputedIncrementalHashes = .{
        .allocator = testing.allocator,
        .modules = std.StringHashMap(u64).init(testing.allocator),
    };
    defer current_hashes.modules.deinit();
    try current_hashes.modules.put("Bool", 101);
    try current_hashes.modules.put("Zap_BoolTest", 200);
    try current_hashes.modules.put("CompileAfterRunner", 300);

    const functions = [_]ir.Function{
        testIncrementalFunction(1, "Bool__negate__1", "Bool"),
        testIncrementalFunction(2, "Zap_BoolTest__test_negate__0", "Zap.BoolTest"),
        testIncrementalFunction(3, "CompileAfterRunner__run__0", "CompileAfterRunner"),
    };
    const affected_functions = [_]ir.FunctionId{1};
    const result: compiler.CompileResult = .{
        .ir_program = .{ .functions = &functions, .type_defs = &.{}, .entry = null },
        .incremental_backend_affected_function_ids = &affected_functions,
    };

    const backend_plan = try preparedBackendPlanForTest(&result, false, 0, &previous_modules, &current_hashes);
    defer backend_plan.deinit(testing.allocator);

    try testing.expectEqual(zir_backend.SelectedUpdateInvalidationPolicy.compare_source_hashes, backend_plan.invalidation);
    try testing.expect(!backend_plan.selection.include_root);
    try expectIncrementalModulesExactly(backend_plan.selection.struct_names, &.{"Bool"});
}

test "prepared incremental backend selection keeps caller modules precise" {
    var previous_modules = std.StringHashMap(u64).init(testing.allocator);
    defer previous_modules.deinit();
    try previous_modules.put("Bool", 100);
    try previous_modules.put("Zap_BoolTest", 200);

    var current_hashes: ComputedIncrementalHashes = .{
        .allocator = testing.allocator,
        .modules = std.StringHashMap(u64).init(testing.allocator),
    };
    defer current_hashes.modules.deinit();
    try current_hashes.modules.put("Bool", 100);
    try current_hashes.modules.put("Zap_BoolTest", 200);

    const functions = [_]ir.Function{
        testIncrementalFunction(1, "Bool__negate__1", "Bool"),
        testIncrementalFunction(2, "Zap_BoolTest__test_negate__0", "Zap.BoolTest"),
    };
    const affected_functions = [_]ir.FunctionId{2};
    const result: compiler.CompileResult = .{
        .ir_program = .{ .functions = &functions, .type_defs = &.{}, .entry = null },
        .incremental_backend_affected_function_ids = &affected_functions,
    };

    const backend_plan = try preparedBackendPlanForTest(&result, false, 0, &previous_modules, &current_hashes);
    defer backend_plan.deinit(testing.allocator);

    try testing.expectEqual(zir_backend.SelectedUpdateInvalidationPolicy.compare_source_hashes, backend_plan.invalidation);
    try testing.expect(!backend_plan.selection.include_root);
    try expectIncrementalModulesExactly(backend_plan.selection.struct_names, &.{"Zap_BoolTest"});
}

test "prepared incremental backend force full selects all current modules and root" {
    var previous_modules = std.StringHashMap(u64).init(testing.allocator);
    defer previous_modules.deinit();
    try previous_modules.put("Bool", 100);
    try previous_modules.put("Zap_BoolTest", 200);

    var current_hashes: ComputedIncrementalHashes = .{
        .allocator = testing.allocator,
        .modules = std.StringHashMap(u64).init(testing.allocator),
        .root_present = true,
        .root_hash = 300,
    };
    defer current_hashes.modules.deinit();
    try current_hashes.modules.put("Bool", 101);
    try current_hashes.modules.put("Zap_BoolTest", 201);

    const functions = [_]ir.Function{
        testIncrementalFunction(1, "Bool__negate__1", "Bool"),
        testIncrementalFunction(2, "Zap_BoolTest__test_negate__0", "Zap.BoolTest"),
    };
    const result: compiler.CompileResult = .{
        .ir_program = .{ .functions = &functions, .type_defs = &.{}, .entry = null },
        .incremental_backend_force_full = true,
    };

    const backend_plan = try preparedBackendPlanForTest(&result, true, 299, &previous_modules, &current_hashes);
    defer backend_plan.deinit(testing.allocator);

    try testing.expectEqual(zir_backend.SelectedUpdateInvalidationPolicy.force_all_source_hashes, backend_plan.invalidation);
    try testing.expect(backend_plan.selection.include_root);
    try expectIncrementalModulesExactly(backend_plan.selection.struct_names, &.{ "Bool", "Zap_BoolTest" });
}

test "prepared incremental backend entry functions include root" {
    var previous_modules = std.StringHashMap(u64).init(testing.allocator);
    defer previous_modules.deinit();
    try previous_modules.put("App", 100);

    var current_hashes: ComputedIncrementalHashes = .{
        .allocator = testing.allocator,
        .modules = std.StringHashMap(u64).init(testing.allocator),
        .root_present = true,
        .root_hash = 200,
    };
    defer current_hashes.modules.deinit();
    try current_hashes.modules.put("App", 100);

    const functions = [_]ir.Function{
        testIncrementalFunction(1, "App__main__0", "App"),
    };
    const affected_functions = [_]ir.FunctionId{1};
    const result: compiler.CompileResult = .{
        .ir_program = .{ .functions = &functions, .type_defs = &.{}, .entry = 1 },
        .incremental_backend_affected_function_ids = &affected_functions,
    };

    const backend_plan = try preparedBackendPlanForTest(&result, true, 200, &previous_modules, &current_hashes);
    defer backend_plan.deinit(testing.allocator);

    try testing.expectEqual(zir_backend.SelectedUpdateInvalidationPolicy.compare_source_hashes, backend_plan.invalidation);
    try testing.expect(backend_plan.selection.include_root);
    try expectIncrementalModulesExactly(backend_plan.selection.struct_names, &.{});
}

test "prepared incremental backend direct root hash changes use compare-hash invalidation" {
    var previous_modules = std.StringHashMap(u64).init(testing.allocator);
    defer previous_modules.deinit();
    try previous_modules.put("App", 100);

    var current_hashes: ComputedIncrementalHashes = .{
        .allocator = testing.allocator,
        .modules = std.StringHashMap(u64).init(testing.allocator),
        .root_present = true,
        .root_hash = 301,
    };
    defer current_hashes.modules.deinit();
    try current_hashes.modules.put("App", 100);

    const functions = [_]ir.Function{
        testIncrementalFunction(1, "App__main__0", "App"),
    };
    const result: compiler.CompileResult = .{
        .ir_program = .{ .functions = &functions, .type_defs = &.{}, .entry = null },
    };

    const backend_plan = try preparedBackendPlanForTest(&result, true, 300, &previous_modules, &current_hashes);
    defer backend_plan.deinit(testing.allocator);

    try testing.expectEqual(zir_backend.SelectedUpdateInvalidationPolicy.compare_source_hashes, backend_plan.invalidation);
    try testing.expect(backend_plan.selection.include_root);
    try expectIncrementalModulesExactly(backend_plan.selection.struct_names, &.{});
}

test "manifest daemon build requests recheck sources even without watcher hits" {
    try testing.expect(manifestDaemonRequestRequiresSourceRecheck(.build, false, 0));
    try testing.expect(manifestDaemonRequestRequiresSourceRecheck(.warm, false, 0));
    try testing.expect(manifestDaemonRequestRequiresSourceRecheck(.build, true, 0));
    try testing.expect(manifestDaemonRequestRequiresSourceRecheck(.warm, true, 1));
    try testing.expect(!manifestDaemonRequestRequiresSourceRecheck(.warm, true, 0));
}

test "manifest daemon build requests queue behind pending warm baselines" {
    try testing.expectEqual(ManifestDaemonBuildQueuePolicy.send_immediately, manifestDaemonBuildQueuePolicy(false));
    try testing.expectEqual(ManifestDaemonBuildQueuePolicy.queue_after_pending_warm, manifestDaemonBuildQueuePolicy(true));
}

test "manifest daemon pending request status reflects dispatch acknowledgements" {
    const allocator = testing.allocator;

    var invocation_identity: build_cache.InvocationIdentity = undefined;
    @memset(&invocation_identity, 0x9a);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);

    const request_path = try manifestDaemonRequestPath(allocator, invocation_identity, 0x1234);
    defer allocator.free(request_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, request_path) catch {};

    const build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    try writeManifestDaemonRequestFile(
        allocator,
        request_path,
        .warm,
        invocation_identity,
        null,
        null,
        ".",
        "",
        build_opts,
        .{},
        false,
        false,
        null,
    );

    try testing.expectEqual(
        ManifestDaemonPendingRequestStatus.unacknowledged,
        try manifestDaemonPendingRequestStatus(allocator, invocation_identity, .warm),
    );

    const ack_path = try writeManifestDaemonRequestAckFile(allocator, request_path);
    defer allocator.free(ack_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, ack_path) catch {};

    try testing.expectEqual(
        ManifestDaemonPendingRequestStatus.acknowledged,
        try manifestDaemonPendingRequestStatus(allocator, invocation_identity, .warm),
    );
}

test "P4J2: manifest daemon absence remains a typed benign fallback" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xd1);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);
    try deleteManifestDaemonPendingRequests(allocator, invocation_identity);

    try testing.expectEqual(
        ManifestDaemonPendingRequestStatus.none,
        try manifestDaemonPendingRequestStatus(allocator, invocation_identity, .warm),
    );
    try testing.expect(!(try manifestDaemonHasPendingRequest(allocator, invocation_identity, .warm)));
    try testing.expectEqual(
        @as(?ManifestDaemonFallbackReason, ManifestDaemonFallbackReason.daemon_unavailable),
        manifestDaemonBuildFallbackFromWaitError(error.DaemonEndpointUnavailable),
    );
    try testing.expectEqual(
        @as(?ManifestDaemonFallbackReason, ManifestDaemonFallbackReason.daemon_unavailable),
        manifestDaemonBuildFallbackFromWaitError(error.DaemonRequestNotAcknowledged),
    );
    try testing.expectEqual(
        @as(?ManifestDaemonFallbackReason, null),
        manifestDaemonBuildFallbackFromWaitError(error.InvalidDaemonProtocol),
    );
}

test "P4J2: manifest daemon pending request cleanup ignores missing daemon dir" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xd5);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const missing_daemon_dir = try std.fs.path.join(allocator, &.{ tmp_path, "missing-daemon-dir" });
    defer allocator.free(missing_daemon_dir);

    try deleteManifestDaemonPendingRequestsInDir(allocator, missing_daemon_dir, invocation_identity);
}

test "P4J2: manifest daemon pending request cleanup propagates open failure" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xd6);

    const too_long_prefix = try allocator.alloc(u8, std.fs.max_path_bytes + 1);
    defer allocator.free(too_long_prefix);
    @memset(too_long_prefix, 'a');

    try testing.expectError(
        error.NameTooLong,
        deleteManifestDaemonPendingRequestsInDir(allocator, too_long_prefix, invocation_identity),
    );
}

const FailingManifestDaemonPendingRequestIterator = struct {
    fn next(self: *@This(), io: Io) !?Io.Dir.Entry {
        _ = self;
        _ = io;
        return error.NameTooLong;
    }
};

test "P4J2: manifest daemon pending request cleanup propagates iteration failure" {
    var iterator: FailingManifestDaemonPendingRequestIterator = .{};
    try testing.expectError(
        error.NameTooLong,
        deleteManifestDaemonPendingRequestsFromIterator(testing.allocator, MANIFEST_DAEMON_DIR, testBuildCacheDigest(0xd7), &iterator),
    );
}

test "P4J2: manifest daemon pending request cleanup propagates allocation failure" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xd8);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);

    const request_path = try manifestDaemonRequestPath(allocator, invocation_identity, 0xd800);
    defer allocator.free(request_path);
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = std.fs.path.basename(request_path), .data = "pending\n" });

    var fixed_buffer: [0]u8 = .{};
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    try testing.expectError(
        error.OutOfMemory,
        deleteManifestDaemonPendingRequestsInDir(fixed_allocator.allocator(), tmp_path, invocation_identity),
    );
}

test "P4J2: manifest daemon pending request cleanup propagates delete failure" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xd9);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);

    const request_path = try manifestDaemonRequestPath(allocator, invocation_identity, 0xd900);
    defer allocator.free(request_path);
    try tmp_dir.dir.createDir(global_io, std.fs.path.basename(request_path), .default_dir);

    try testing.expectError(
        error.IsDir,
        deleteManifestDaemonPendingRequestsInDir(allocator, tmp_path, invocation_identity),
    );
}

test "P4J2: manifest daemon pending request cleanup deletes matching request and ack files" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xda);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);

    const request_path = try manifestDaemonRequestPath(allocator, invocation_identity, 0xda00);
    defer allocator.free(request_path);
    const ack_path = try manifestDaemonRequestAckPath(allocator, request_path);
    defer allocator.free(ack_path);

    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = std.fs.path.basename(request_path), .data = "pending\n" });
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = std.fs.path.basename(ack_path), .data = "ack\n" });

    const tmp_request_path = try std.fs.path.join(allocator, &.{ tmp_path, std.fs.path.basename(request_path) });
    defer allocator.free(tmp_request_path);
    const tmp_ack_path = try std.fs.path.join(allocator, &.{ tmp_path, std.fs.path.basename(ack_path) });
    defer allocator.free(tmp_ack_path);

    try deleteManifestDaemonPendingRequestsInDir(allocator, tmp_path, invocation_identity);

    try testing.expect(!(try manifestDaemonPathExists(tmp_request_path)));
    try testing.expect(!(try manifestDaemonPathExists(tmp_ack_path)));
}

test "P4J2: manifest daemon endpoint cleanup propagates path allocation failure" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const endpoint_path = try std.fs.path.join(allocator, &.{ tmp_path, "missing-endpoint.fifo" });
    defer allocator.free(endpoint_path);

    var fixed_buffer: [0]u8 = .{};
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&fixed_buffer);

    try testing.expectError(
        error.OutOfMemory,
        cleanupManifestDaemonEndpointFiles(fixed_allocator.allocator(), testBuildCacheDigest(0xdb), endpoint_path),
    );
}

test "P4J2: manifest daemon endpoint cleanup propagates endpoint delete failure" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xdc);

    const too_long_prefix = try allocator.alloc(u8, std.fs.max_path_bytes + 1);
    defer allocator.free(too_long_prefix);
    @memset(too_long_prefix, 'a');
    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/daemon.fifo", .{too_long_prefix});
    defer allocator.free(endpoint_path);

    try testing.expectError(
        error.NameTooLong,
        cleanupManifestDaemonEndpointFiles(allocator, invocation_identity, endpoint_path),
    );
}

test "P4J2: manifest daemon termination cleans stale endpoint when pid metadata is missing" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xdd);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);
    const endpoint_path = try manifestDaemonEndpointPath(allocator, invocation_identity);
    defer allocator.free(endpoint_path);
    const pid_path = try manifestDaemonPidPath(allocator, invocation_identity);
    defer allocator.free(pid_path);
    defer deleteManifestDaemonFileIfPresent(endpoint_path) catch {};
    defer deleteManifestDaemonFileIfPresent(pid_path) catch {};
    try deleteManifestDaemonFileIfPresent(endpoint_path);
    try deleteManifestDaemonFileIfPresent(pid_path);

    try writeFile(endpoint_path, "stale endpoint\n");

    try terminateManifestDaemonEndpoint(allocator, invocation_identity, endpoint_path);

    try testing.expect(!(try manifestDaemonPathExists(endpoint_path)));
    try testing.expect(!(try manifestDaemonPathExists(pid_path)));
}

fn denyManifestDaemonSignalForTest(pid: std.posix.pid_t, signal: std.posix.SIG) anyerror!void {
    _ = pid;
    _ = signal;
    return error.PermissionDenied;
}

var manifest_daemon_signal_called_for_test = false;

fn failIfManifestDaemonSignalCalledForTest(pid: std.posix.pid_t, signal: std.posix.SIG) anyerror!void {
    _ = pid;
    _ = signal;
    manifest_daemon_signal_called_for_test = true;
    return error.UnexpectedSignal;
}

test "P4J2: manifest daemon termination preserves endpoint metadata on kill failure" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xde);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);
    const endpoint_path = try manifestDaemonEndpointPath(allocator, invocation_identity);
    defer allocator.free(endpoint_path);
    const pid_path = try manifestDaemonPidPath(allocator, invocation_identity);
    defer allocator.free(pid_path);
    defer deleteManifestDaemonFileIfPresent(endpoint_path) catch {};
    defer deleteManifestDaemonFileIfPresent(pid_path) catch {};
    try deleteManifestDaemonFileIfPresent(endpoint_path);
    try deleteManifestDaemonFileIfPresent(pid_path);

    try writeFile(endpoint_path, "live endpoint\n");
    try writeManifestDaemonPidFile(allocator, pid_path, std.posix.system.getpid());

    try testing.expectError(
        error.PermissionDenied,
        terminateManifestDaemonEndpointWithSignal(allocator, invocation_identity, endpoint_path, denyManifestDaemonSignalForTest),
    );
    try testing.expect(try manifestDaemonPathExists(endpoint_path));
    try testing.expect(try manifestDaemonPathExists(pid_path));
}

test "P4J2: manifest daemon fallback cleanup treats unavailable endpoint as stale metadata" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xdf);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);
    const endpoint_path = try manifestDaemonEndpointPath(allocator, invocation_identity);
    defer allocator.free(endpoint_path);
    const pid_path = try manifestDaemonPidPath(allocator, invocation_identity);
    defer allocator.free(pid_path);
    defer deleteManifestDaemonFileIfPresent(endpoint_path) catch {};
    defer deleteManifestDaemonFileIfPresent(pid_path) catch {};
    try deleteManifestDaemonFileIfPresent(endpoint_path);
    try deleteManifestDaemonFileIfPresent(pid_path);

    try writeManifestDaemonPidFile(allocator, pid_path, std.posix.system.getpid());

    manifest_daemon_signal_called_for_test = false;
    try cleanupManifestDaemonBuildFallbackWithSignal(
        allocator,
        invocation_identity,
        endpoint_path,
        error.DaemonEndpointUnavailable,
        failIfManifestDaemonSignalCalledForTest,
    );

    try testing.expect(!manifest_daemon_signal_called_for_test);
    try testing.expect(!(try manifestDaemonPathExists(endpoint_path)));
    try testing.expect(!(try manifestDaemonPathExists(pid_path)));
}

test "P4J2: manifest daemon fallback cleanup propagates live endpoint termination failure" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xe0);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);
    const endpoint_path = try manifestDaemonEndpointPath(allocator, invocation_identity);
    defer allocator.free(endpoint_path);
    const pid_path = try manifestDaemonPidPath(allocator, invocation_identity);
    defer allocator.free(pid_path);
    defer deleteManifestDaemonFileIfPresent(endpoint_path) catch {};
    defer deleteManifestDaemonFileIfPresent(pid_path) catch {};
    try deleteManifestDaemonFileIfPresent(endpoint_path);
    try deleteManifestDaemonFileIfPresent(pid_path);

    try writeFile(endpoint_path, "live endpoint\n");
    try writeManifestDaemonPidFile(allocator, pid_path, std.posix.system.getpid());

    try testing.expectError(
        error.PermissionDenied,
        cleanupManifestDaemonBuildFallbackWithSignal(
            allocator,
            invocation_identity,
            endpoint_path,
            error.DaemonEndpointUnavailable,
            denyManifestDaemonSignalForTest,
        ),
    );
    try testing.expect(try manifestDaemonPathExists(endpoint_path));
    try testing.expect(try manifestDaemonPathExists(pid_path));
}

fn reapedChildPidForManifestDaemonTest() !std.posix.pid_t {
    const pid_result = std.posix.system.fork();
    switch (std.posix.errno(pid_result)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    const pid: std.posix.pid_t = @intCast(pid_result);
    if (pid == 0) {
        std.c._exit(0);
    }

    var status: c_int = 0;
    while (true) {
        const wait_result = std.c.waitpid(pid, &status, 0);
        switch (std.posix.errno(wait_result)) {
            .SUCCESS => return pid,
            .INTR => continue,
            else => return error.SkipZigTest,
        }
    }
}

test "P4J2: manifest daemon signal treats ESRCH as an exited-process race" {
    const pid = try reapedChildPidForManifestDaemonTest();

    try signalManifestDaemonProcess(pid, .TERM);
    try testing.expect(!(try manifestDaemonProcessIsAlive(pid)));
}

test "P4J2: manifest daemon endpoint removal wait treats true absence as removed" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);

    const endpoint_path = try std.fs.path.join(allocator, &.{ tmp_path, "missing-daemon.fifo" });
    defer allocator.free(endpoint_path);

    try testing.expect(try waitForManifestDaemonEndpointRemoval(endpoint_path));
}

test "P4J2: manifest daemon endpoint removal wait propagates access failures" {
    const allocator = testing.allocator;

    const too_long_prefix = try allocator.alloc(u8, std.fs.max_path_bytes + 1);
    defer allocator.free(too_long_prefix);
    @memset(too_long_prefix, 'a');
    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/daemon.fifo", .{too_long_prefix});
    defer allocator.free(endpoint_path);

    try testing.expectError(error.NameTooLong, waitForManifestDaemonEndpointRemoval(endpoint_path));
}

test "P4J2: manifest daemon orphan cleanup deletes request after confirmed endpoint absence" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xe1);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);

    const endpoint_path = try manifestDaemonEndpointPath(allocator, invocation_identity);
    defer allocator.free(endpoint_path);
    std.Io.Dir.cwd().deleteFile(global_io, endpoint_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => |delete_err| return delete_err,
    };

    const request_path = try manifestDaemonRequestPath(allocator, invocation_identity, 0xe100);
    defer allocator.free(request_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, request_path) catch {};
    std.Io.Dir.cwd().deleteFile(global_io, request_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => |delete_err| return delete_err,
    };
    try writeFile(request_path, "orphan\n");

    try cleanupManifestDaemonOrphanRequestArtifact(allocator, std.fs.path.basename(request_path));

    try testing.expect(!(try manifestDaemonPathExists(request_path)));
}

test "P4J2: manifest daemon orphan cleanup preserves request when endpoint exists" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xe2);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);

    const endpoint_path = try manifestDaemonEndpointPath(allocator, invocation_identity);
    defer allocator.free(endpoint_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, endpoint_path) catch {};
    std.Io.Dir.cwd().deleteFile(global_io, endpoint_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => |delete_err| return delete_err,
    };
    try writeFile(endpoint_path, "");

    const request_path = try manifestDaemonRequestPath(allocator, invocation_identity, 0xe200);
    defer allocator.free(request_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, request_path) catch {};
    std.Io.Dir.cwd().deleteFile(global_io, request_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => |delete_err| return delete_err,
    };
    try writeFile(request_path, "pending\n");

    try cleanupManifestDaemonOrphanRequestArtifact(allocator, std.fs.path.basename(request_path));

    try testing.expect(try manifestDaemonPathExists(request_path));
}

test "P4J2: manifest daemon orphan cleanup preserves request on endpoint access failure" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xe3);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);

    const endpoint_path = try manifestDaemonEndpointPath(allocator, invocation_identity);
    defer allocator.free(endpoint_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, endpoint_path) catch {};
    std.Io.Dir.cwd().deleteFile(global_io, endpoint_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => |delete_err| return delete_err,
    };
    try std.Io.Dir.cwd().symLink(global_io, std.fs.path.basename(endpoint_path), endpoint_path, .{});

    const request_path = try manifestDaemonRequestPath(allocator, invocation_identity, 0xe300);
    defer allocator.free(request_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, request_path) catch {};
    std.Io.Dir.cwd().deleteFile(global_io, request_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => |delete_err| return delete_err,
    };
    try writeFile(request_path, "pending\n");

    try testing.expectError(
        error.SymLinkLoop,
        cleanupManifestDaemonOrphanRequestArtifact(allocator, std.fs.path.basename(request_path)),
    );
    try testing.expect(try manifestDaemonPathExists(request_path));
}

test "P4J2: manifest daemon pending request scan propagates allocation failure" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xd2);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);
    const request_path = try manifestDaemonRequestPath(allocator, invocation_identity, 0x1235);
    defer allocator.free(request_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, request_path) catch {};

    const build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    try writeManifestDaemonRequestFile(
        allocator,
        request_path,
        .warm,
        invocation_identity,
        null,
        null,
        ".",
        "",
        build_opts,
        .{},
        false,
        false,
        null,
    );

    var fixed_buffer: [0]u8 = .{};
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    try testing.expectError(
        error.OutOfMemory,
        manifestDaemonPendingRequestStatus(fixed_allocator.allocator(), invocation_identity, null),
    );
}

test "P4J2: manifest daemon pending request scan propagates protocol failure" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xd3);

    try std.Io.Dir.cwd().createDirPath(global_io, MANIFEST_DAEMON_DIR);
    const request_path = try manifestDaemonRequestPath(allocator, invocation_identity, 0x1236);
    defer allocator.free(request_path);
    defer std.Io.Dir.cwd().deleteFile(global_io, request_path) catch {};
    try writeFile(request_path, "not a daemon request");

    try testing.expectError(
        error.InvalidDaemonProtocol,
        manifestDaemonPendingRequestStatus(allocator, invocation_identity, .warm),
    );
}

test "P4J2: manifest daemon build propagates path allocation failure" {
    const allocator = testing.allocator;
    const invocation_identity = testBuildCacheDigest(0xd4);
    const build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;

    var fixed_buffer: [0]u8 = .{};
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    try testing.expectError(
        error.OutOfMemory,
        tryManifestDaemonBuild(
            allocator,
            fixed_allocator.allocator(),
            invocation_identity,
            ".",
            "default",
            build_opts,
            .{},
            false,
            null,
            null,
        ),
    );
}

// ---------------------------------------------------------------------------
// Phase 4: unified Zig-style `-D<key>=<value>` build-flag pipeline
//
// `parseBuildOverrides` is the SINGLE pure parser shared by every
// entrypoint (`zap build`, `zap run` manifest, `zap run` script). It
// recognizes the Zig-build-style standard flags plus Zap's `-Dmemory`,
// captures them into a typed `BuildOverrides`, and rejects an
// unrecognized `-D` key with a clear keys-list error.
// `applyBuildOverrides` overlays the parsed values onto a `BuildConfig`
// per-field so the CLI is the ultimate source of truth (an unset flag
// preserves the manifest/synthetic default). All filesystem-free, so
// `zig build test` exercises them without spawning a process.
// ---------------------------------------------------------------------------

test "parseBuildOverrides: -Doptimize maps every Zig mode name to the enum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "Debug", zap.builder.BuildConfig.Optimize.debug },
        .{ "ReleaseSafe", zap.builder.BuildConfig.Optimize.release_safe },
        .{ "ReleaseFast", zap.builder.BuildConfig.Optimize.release_fast },
        .{ "ReleaseSmall", zap.builder.BuildConfig.Optimize.release_small },
    }) |pair| {
        const arg = "-Doptimize=" ++ pair[0];
        const r = try parseBuildOverrides(a, &.{arg}, 1);
        switch (r) {
            .ok => |ov| try testing.expectEqual(pair[1], ov.optimize.?),
            .err => return error.UnexpectedError,
        }
    }
}

test "parseBuildOverrides: unset flags stay null (no silent defaults)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try parseBuildOverrides(a, &.{}, 0);
    switch (r) {
        .ok => |ov| {
            try testing.expect(ov.optimize == null);
            try testing.expect(ov.memory == null);
            try testing.expect(ov.target == null);
            try testing.expect(ov.cpu == null);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseBuildOverrides: captures memory/target/cpu values verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try parseBuildOverrides(a, &.{
        "-Dmemory=Memory.Arena",
        "-Dtarget=aarch64-linux-gnu",
        "-Dcpu=baseline",
        "-Doptimize=ReleaseFast",
    }, 4);
    switch (r) {
        .ok => |ov| {
            try testing.expectEqualStrings("Memory.Arena", ov.memory.?);
            try testing.expectEqualStrings("aarch64-linux-gnu", ov.target.?);
            try testing.expectEqualStrings("baseline", ov.cpu.?);
            try testing.expectEqual(zap.builder.BuildConfig.Optimize.release_fast, ov.optimize.?);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseBuildOverrides: -Druntime-concurrency parses on/off/true/false and rejects junk (P2-J1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Unset ⇒ null (the manifest field decides).
    switch (try parseBuildOverrides(a, &.{}, 0)) {
        .ok => |ov| try testing.expect(ov.runtime_concurrency == null),
        .err => return error.UnexpectedError,
    }

    const truthy_spellings = [_][]const u8{ "-Druntime-concurrency=on", "-Druntime-concurrency=true" };
    for (truthy_spellings) |flag| {
        switch (try parseBuildOverrides(a, &.{flag}, 1)) {
            .ok => |ov| try testing.expectEqual(@as(?bool, true), ov.runtime_concurrency),
            .err => return error.UnexpectedError,
        }
    }
    const falsy_spellings = [_][]const u8{ "-Druntime-concurrency=off", "-Druntime-concurrency=false" };
    for (falsy_spellings) |flag| {
        switch (try parseBuildOverrides(a, &.{flag}, 1)) {
            .ok => |ov| try testing.expectEqual(@as(?bool, false), ov.runtime_concurrency),
            .err => return error.UnexpectedError,
        }
    }

    switch (try parseBuildOverrides(a, &.{"-Druntime-concurrency=maybe"}, 1)) {
        .ok => return error.UnexpectedSuccess,
        .err => |msg| try testing.expect(std.mem.indexOf(u8, msg, "runtime-concurrency") != null),
    }
}

test "applyBuildOverrides: -Druntime-concurrency overrides the manifest gate (P2-J1)" {
    var config: zap.builder.BuildConfig = .{
        .name = "app",
        .version = "0.0.0",
        .kind = .bin,
    };
    try testing.expect(!config.runtime_concurrency);

    applyBuildOverrides(&config, .{ .runtime_concurrency = true });
    try testing.expect(config.runtime_concurrency);

    // Null override leaves the (now-true) manifest value untouched.
    applyBuildOverrides(&config, .{});
    try testing.expect(config.runtime_concurrency);

    applyBuildOverrides(&config, .{ .runtime_concurrency = false });
    try testing.expect(!config.runtime_concurrency);
}

test "resolveConcurrencyGate: opt-out default resolves from target capability" {
    // Unspecified gate + host (fiber-capable arch, supported OS) -> ON by
    // default. This is the opt-out posture: concurrency is available unless you
    // turn it off.
    var host_config: zap.builder.BuildConfig = .{ .name = "app", .version = "0.0.0", .kind = .bin };
    applyBuildOverrides(&host_config, .{});
    try testing.expect(!host_config.runtime_concurrency_explicit);
    try testing.expect(host_config.runtime_concurrency);

    // Unspecified gate + single-threaded wasm -> silently OFF (the kernel needs
    // stackful fibers wasm cannot provide). No error: the program just builds
    // without concurrency.
    var wasm_config: zap.builder.BuildConfig = .{ .name = "app", .version = "0.0.0", .kind = .bin };
    applyBuildOverrides(&wasm_config, .{ .target = "wasm32-wasi" });
    try testing.expect(!wasm_config.runtime_concurrency);

    // Explicit false stays off even on a capable host (opt-out honored).
    var off_config: zap.builder.BuildConfig = .{ .name = "app", .version = "0.0.0", .kind = .bin };
    applyBuildOverrides(&off_config, .{ .runtime_concurrency = false });
    try testing.expect(off_config.runtime_concurrency_explicit);
    try testing.expect(!off_config.runtime_concurrency);
}

test "parseBuildOverrides: only scans the leading region (leading_end)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The token after `leading_end` must be ignored entirely (it is the
    // script path / forwarded arg region), even if it looks like `-D`.
    const r = try parseBuildOverrides(a, &.{
        "-Doptimize=Debug",
        "script.zap",
        "-Doptimize=ReleaseFast",
    }, 1);
    switch (r) {
        .ok => |ov| try testing.expectEqual(zap.builder.BuildConfig.Optimize.debug, ov.optimize.?),
        .err => return error.UnexpectedError,
    }
}

test "parseBuildOverrides: unknown -D key is rejected with a keys list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try parseBuildOverrides(a, &.{"-Dnonsense=1"}, 1);
    switch (r) {
        .ok => return error.ExpectedError,
        .err => |msg| {
            try testing.expect(std.mem.indexOf(u8, msg, "nonsense") != null);
            try testing.expect(std.mem.indexOf(u8, msg, "optimize") != null);
            try testing.expect(std.mem.indexOf(u8, msg, "memory") != null);
            try testing.expect(std.mem.indexOf(u8, msg, "target") != null);
            try testing.expect(std.mem.indexOf(u8, msg, "cpu") != null);
        },
    }
}

test "parseBuildOverrides: -D with no '=' (missing value) is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try parseBuildOverrides(a, &.{"-Doptimize"}, 1);
    switch (r) {
        .ok => return error.ExpectedError,
        .err => |msg| try testing.expect(std.mem.indexOf(u8, msg, "optimize") != null),
    }
}

test "parseBuildOverrides: invalid -Doptimize value lists the valid modes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try parseBuildOverrides(a, &.{"-Doptimize=ReleaseTurbo"}, 1);
    switch (r) {
        .ok => return error.ExpectedError,
        .err => |msg| {
            try testing.expect(std.mem.indexOf(u8, msg, "ReleaseTurbo") != null);
            try testing.expect(std.mem.indexOf(u8, msg, "Debug") != null);
        },
    }
}

test "parseBuildOverrides: empty -D value is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try parseBuildOverrides(a, &.{"-Dmemory="}, 1);
    switch (r) {
        .ok => return error.ExpectedError,
        .err => |msg| try testing.expect(std.mem.indexOf(u8, msg, "memory") != null),
    }
}

test "applyBuildOverrides: CLI optimize wins over the manifest value" {
    var config = zap.builder.BuildConfig{
        .name = "x",
        .version = "0",
        .kind = .bin,
        .optimize = .release_fast,
    };
    applyBuildOverrides(&config, .{ .optimize = .debug });
    try testing.expectEqual(zap.builder.BuildConfig.Optimize.debug, config.optimize);
}

test "applyBuildOverrides: unset optimize preserves the manifest value" {
    var config = zap.builder.BuildConfig{
        .name = "x",
        .version = "0",
        .kind = .bin,
        .optimize = .release_small,
    };
    applyBuildOverrides(&config, .{});
    try testing.expectEqual(zap.builder.BuildConfig.Optimize.release_small, config.optimize);
}

test "applyBuildOverrides: CLI memory replaces the manifest manager, unset preserves it" {
    var config = zap.builder.BuildConfig{
        .name = "x",
        .version = "0",
        .kind = .bin,
        .memory_manager = .{ .type_name = "Memory.ARC", .adapter_source_path = "build.zap" },
    };
    applyBuildOverrides(&config, .{ .memory = "Memory.Arena" });
    try testing.expectEqualStrings("Memory.Arena", config.memory_manager.?.type_name);
    // The adapter source path must be cleared so the memory driver
    // re-resolves the overridden manager exactly like a manifest value.
    try testing.expect(config.memory_manager.?.adapter_source_path == null);

    var config2 = zap.builder.BuildConfig{
        .name = "x",
        .version = "0",
        .kind = .bin,
        .memory_manager = .{ .type_name = "Memory.ARC", .adapter_source_path = "build.zap" },
    };
    applyBuildOverrides(&config2, .{});
    try testing.expectEqualStrings("Memory.ARC", config2.memory_manager.?.type_name);
}

test "applyBuildOverrides: CLI target/cpu win, unset preserves manifest defaults" {
    var config = zap.builder.BuildConfig{
        .name = "x",
        .version = "0",
        .kind = .bin,
        .target = "x86_64-linux-gnu",
        .cpu = "x86_64_v2",
    };
    applyBuildOverrides(&config, .{ .target = "aarch64-linux-gnu", .cpu = "apple_m1" });
    try testing.expectEqualStrings("aarch64-linux-gnu", config.target.?);
    try testing.expectEqualStrings("apple_m1", config.cpu.?);

    var config2 = zap.builder.BuildConfig{
        .name = "x",
        .version = "0",
        .kind = .bin,
        .target = "x86_64-linux-gnu",
        .cpu = "x86_64_v2",
    };
    applyBuildOverrides(&config2, .{});
    try testing.expectEqualStrings("x86_64-linux-gnu", config2.target.?);
    try testing.expectEqualStrings("x86_64_v2", config2.cpu.?);
}

test "applyBuildOverrides: multiple flags applied together, each per-field" {
    var config = zap.builder.BuildConfig{
        .name = "x",
        .version = "0",
        .kind = .bin,
        .optimize = .debug,
        .memory_manager = .{ .type_name = "Memory.ARC" },
        .target = null,
        .cpu = null,
    };
    applyBuildOverrides(&config, .{
        .optimize = .release_fast,
        .memory = "Memory.NoOp",
        .target = "wasm32-wasi",
        .cpu = "generic",
    });
    try testing.expectEqual(zap.builder.BuildConfig.Optimize.release_fast, config.optimize);
    try testing.expectEqualStrings("Memory.NoOp", config.memory_manager.?.type_name);
    try testing.expectEqualStrings("wasm32-wasi", config.target.?);
    try testing.expectEqualStrings("generic", config.cpu.?);
}

test "validateScriptMemoryManager still gates script-mode -Dmemory to stdlib only" {
    // Reused unchanged by the script entrypoint so a third-party
    // `-Dmemory=` in script mode is rejected (no dependency graph).
    try testing.expect(validateScriptMemoryManager("Memory.Arena"));
    try testing.expect(!validateScriptMemoryManager("MyApp.CustomArena"));
}

test "propagateLeakReportEnv: no requested env propagation is a no-op" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const previous_global_env_map = global_env_map;
    global_env_map = &env_map;
    defer global_env_map = previous_global_env_map;

    try propagateLeakReportEnv(.{});
    try propagateLeakReportEnv(.{ .error_format = .text });

    try testing.expectEqual(@as(std.process.Environ.Map.Size, 0), env_map.count());
}

test "propagateLeakReportEnv: writes requested leak-report env vars" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const previous_global_env_map = global_env_map;
    global_env_map = &env_map;
    defer global_env_map = previous_global_env_map;

    try propagateLeakReportEnv(.{
        .error_format = .json,
        .leaks_fatal = true,
    });

    try testing.expectEqualStrings("json", env_map.get("ZAP_ERROR_FORMAT").?);
    try testing.expectEqualStrings("1", env_map.get("ZAP_LEAKS_FATAL").?);
}

test "propagateLeakReportEnv: requested propagation requires an env map" {
    const previous_global_env_map = global_env_map;
    global_env_map = null;
    defer global_env_map = previous_global_env_map;

    try testing.expectError(
        error.LeakReportEnvUnavailable,
        propagateLeakReportEnv(.{ .error_format = .json }),
    );
}

test "propagateLeakReportEnv: returns env-map mutation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var env_map = std.process.Environ.Map.init(failing_allocator.allocator());
    defer env_map.deinit();

    const previous_global_env_map = global_env_map;
    global_env_map = &env_map;
    defer global_env_map = previous_global_env_map;

    try testing.expectError(
        error.OutOfMemory,
        propagateLeakReportEnv(.{ .leaks_fatal = true }),
    );
    try testing.expectEqual(@as(std.process.Environ.Map.Size, 0), env_map.count());
}

test "appendTestRunArgs forwards seed before explicit test args" {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(testing.allocator);

    try appendTestRunArgs(testing.allocator, &args, "12345", false, null, &.{ "--only", "math" });

    try testing.expectEqual(@as(usize, 4), args.items.len);
    try testing.expectEqualStrings("--seed", args.items[0]);
    try testing.expectEqualStrings("12345", args.items[1]);
    try testing.expectEqualStrings("--only", args.items[2]);
    try testing.expectEqualStrings("math", args.items[3]);
}

test "appendTestRunArgs preserves forwarded test args without a seed" {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(testing.allocator);

    try appendTestRunArgs(testing.allocator, &args, null, false, null, &.{ "--list", "--verbose" });

    try testing.expectEqual(@as(usize, 2), args.items.len);
    try testing.expectEqualStrings("--list", args.items[0]);
    try testing.expectEqualStrings("--verbose", args.items[1]);
}

test "appendTestRunArgs forwards timing options before explicit test args" {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(testing.allocator);

    try appendTestRunArgs(testing.allocator, &args, null, true, "7", &.{"--list"});

    try testing.expectEqual(@as(usize, 4), args.items.len);
    try testing.expectEqualStrings("--timings", args.items[0]);
    try testing.expectEqualStrings("--slowest", args.items[1]);
    try testing.expectEqualStrings("7", args.items[2]);
    try testing.expectEqualStrings("--list", args.items[3]);
}

test "parseTargetArgs captures Zest timing flags" {
    var parsed = try parseTargetArgs(testing.allocator, &.{ "--timings", "--slowest", "12" });
    defer parsed.deinit(testing.allocator);

    try testing.expect(parsed.timings);
    try testing.expectEqualStrings("12", parsed.slowest.?);
    try testing.expect(parsed.target == null);
}

test "parseTargetArgs captures incremental trace flag" {
    var parsed = try parseTargetArgs(testing.allocator, &.{ "--trace-incremental", "app" });
    defer parsed.deinit(testing.allocator);

    try testing.expect(parsed.trace_incremental);
    try testing.expectEqualStrings("app", parsed.target.?);
}

test "buildPipelineRunArgs appends forwarded runtime args when requested" {
    const run_step: zap.builder.BuildConfig.Run = .{
        .args = &.{ "--only", "math" },
        .forward_args = true,
    };

    const args = try buildPipelineRunArgs(testing.allocator, run_step, &.{ "--seed", "123" });
    defer testing.allocator.free(args);

    try testing.expectEqual(@as(usize, 4), args.len);
    try testing.expectEqualStrings("--only", args[0]);
    try testing.expectEqualStrings("math", args[1]);
    try testing.expectEqualStrings("--seed", args[2]);
    try testing.expectEqualStrings("123", args[3]);
}

test "buildPipelineRunArgs omits forwarded runtime args when disabled" {
    const run_step: zap.builder.BuildConfig.Run = .{
        .args = &.{"--list"},
        .forward_args = false,
    };

    const args = try buildPipelineRunArgs(testing.allocator, run_step, &.{ "--seed", "123" });
    defer testing.allocator.free(args);

    try testing.expectEqual(@as(usize, 1), args.len);
    try testing.expectEqualStrings("--list", args[0]);
}

// ---------------------------------------------------------------------------
// Phase 4: script-mode build-flag helpers (legacy pure helpers reused by
// the unified `-D` parser: `parseScriptOptimizeMode` name->enum mapping
// and `validateScriptMemoryManager` stdlib-only validation).
//
// These are pure, filesystem-free helpers unit-tested by `zig build
// test` without spawning a process or touching disk.
// ---------------------------------------------------------------------------

test "parseScriptOptimizeMode: maps all four Zig mode names to the matching enum" {
    try testing.expectEqual(zap.builder.BuildConfig.Optimize.debug, parseScriptOptimizeMode("Debug").?);
    try testing.expectEqual(zap.builder.BuildConfig.Optimize.release_safe, parseScriptOptimizeMode("ReleaseSafe").?);
    try testing.expectEqual(zap.builder.BuildConfig.Optimize.release_fast, parseScriptOptimizeMode("ReleaseFast").?);
    try testing.expectEqual(zap.builder.BuildConfig.Optimize.release_small, parseScriptOptimizeMode("ReleaseSmall").?);
}

test "parseScriptOptimizeMode: unknown mode names return null (no silent fallback)" {
    try testing.expect(parseScriptOptimizeMode("debug") == null); // case-sensitive: Zig spelling only
    try testing.expect(parseScriptOptimizeMode("release_fast") == null);
    try testing.expect(parseScriptOptimizeMode("Fast") == null);
    try testing.expect(parseScriptOptimizeMode("") == null);
    try testing.expect(parseScriptOptimizeMode("ReleaseTurbo") == null);
}

test "optimizePolicyForBuildConfig maps frontend backend and memory optimize modes" {
    const cases = [_]struct {
        build: zap.builder.BuildConfig.Optimize,
        frontend: compiler.FrontendOptimizeMode,
        backend: u8,
        memory: zap.memory_driver.ZapForkOptimize,
    }{
        .{ .build = .debug, .frontend = .debug, .backend = 0, .memory = .Debug },
        .{ .build = .release_safe, .frontend = .release_safe, .backend = 1, .memory = .ReleaseSafe },
        .{ .build = .release_fast, .frontend = .release_fast, .backend = 2, .memory = .ReleaseFast },
        .{ .build = .release_small, .frontend = .release_small, .backend = 3, .memory = .ReleaseSmall },
    };

    for (cases) |case| {
        const policy = optimizePolicyForBuildConfig(case.build);
        try testing.expectEqual(case.frontend, policy.frontend_optimize_mode);
        try testing.expectEqual(case.frontend.cacheTag(), policy.frontend_policy_tag);
        try testing.expectEqual(case.backend, policy.backend_optimize_mode);
        try testing.expectEqual(case.memory, policy.memory_driver_optimize);
    }
}

test "validateScriptMemoryManager: accepts exactly the seven stdlib managers" {
    try testing.expect(validateScriptMemoryManager("Memory.ARC"));
    // P3-J6: the ORC-over-ARC cyclic manager (REFCOUNTED reclamation model,
    // shares ARC's specialization; adds a Bacon–Rajan cycle collector).
    try testing.expect(validateScriptMemoryManager("Memory.ORC"));
    try testing.expect(validateScriptMemoryManager("Memory.Arena"));
    try testing.expect(validateScriptMemoryManager("Memory.NoOp"));
    try testing.expect(validateScriptMemoryManager("Memory.Leak"));
    try testing.expect(validateScriptMemoryManager("Memory.Tracking"));
    // Phase 5: the conservative tracing-GC manager (TRACED reclamation model).
    try testing.expect(validateScriptMemoryManager("Memory.GC"));
}

test "validateScriptMemoryManager: rejects third-party / unknown managers" {
    // Script mode is single-file with no dependency graph, so only
    // the stdlib managers are resolvable.
    try testing.expect(!validateScriptMemoryManager("MyApp.CustomArena"));
    try testing.expect(!validateScriptMemoryManager("Memory.Custom"));
    try testing.expect(!validateScriptMemoryManager("memory.arc"));
    try testing.expect(!validateScriptMemoryManager("ARC"));
    try testing.expect(!validateScriptMemoryManager(""));
    try testing.expect(!validateScriptMemoryManager("Memory"));
}

test "computeBuildCacheKey includes manifest result hash" {
    const build_source = "pub struct App.Builder {}";
    const units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/app.zap", .source = "pub struct App {}" },
    };
    const target_name = "default";

    const first = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{ .manifest_result_hash = 111 });
    const second = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{ .manifest_result_hash = 222 });

    try testing.expect(!std.mem.eql(u8, first[0..], second[0..]));
}

test "P4J2: manifest cache key records active manager source hash failures" {
    const allocator = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const missing_manager_source_path = try std.fs.path.join(allocator, &.{ tmp_path, "missing_manager.zap" });
    defer allocator.free(missing_manager_source_path);

    const config: zap.builder.BuildConfig = .{
        .name = "app",
        .version = "0.0.0",
        .kind = .bin,
    };
    const inputs: CompileAndLinkInputs = .{
        .config = config,
        .source_roots = &.{},
        .source_units = &.{},
        .struct_order = null,
        .level_boundaries = null,
        .manifest_result_hash = 0,
        .cache_source = "",
        .target_name = "default",
        .build_opts = .empty,
        .zap_lib_dir = null,
        .zig_lib_dir = "",
        .compiler_identity_digest = zeroBuildCacheDigest(),
        .zig_lib_identity_digest = zeroBuildCacheDigest(),
        .project_root = tmp_path,
        .collect_arc_stats = false,
        .layout = .manifest,
    };

    var failure: ManifestCacheKeyFailure = .{};
    try testing.expectError(
        error.FileNotFound,
        computeManifestCacheKeyHex(
            allocator,
            inputs,
            config,
            missing_manager_source_path,
            "",
            &failure,
        ),
    );
    try testing.expectEqual(ManifestCacheKeyFailureStage.active_manager_source_hash, failure.stage);
    try testing.expectEqualStrings(missing_manager_source_path, failure.active_manager_source_path.?);
}

test "P4J2: manifest cache key failure diagnostics name the failing stage" {
    var captured: std.ArrayListUnmanaged(u8) = .empty;
    defer captured.deinit(testing.allocator);
    const previous_capture = zap.diagnostics.installStderrCapture(.{
        .list = &captured,
        .allocator = testing.allocator,
    });
    defer _ = zap.diagnostics.installStderrCapture(previous_capture);

    emitManifestCacheKeyFailureDiagnostic(.{
        .stage = .active_manager_source_hash,
        .active_manager_source_path = "lib/memory/arc.zap",
    }, error.FileNotFound);
    emitManifestCacheKeyFailureDiagnostic(.{ .stage = .build_input_hash }, error.OutOfMemory);
    emitManifestCacheKeyFailureDiagnostic(.{ .stage = .hex_encoding }, error.OutOfMemory);

    try testing.expectEqualStrings(
        "Error: could not hash active memory manager source for manifest cache key (lib/memory/arc.zap): FileNotFound\n" ++
            "Error: could not hash manifest cache key inputs: OutOfMemory\n" ++
            "Error: could not encode manifest cache key digest: OutOfMemory\n",
        captured.items,
    );
}

test "computeBuildCacheKey includes source contents" {
    const build_source = "pub struct App.Builder {}";
    const first_units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/bool.zap", .source = "pub fn negate(true) -> Bool { false }" },
    };
    const second_units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/bool.zap", .source = "pub fn negate(true) -> Bool { true }" },
    };
    const target_name = "test";
    const manifest_hash: u64 = 111;

    const first_key = try computeBuildCacheKey(testing.allocator, build_source, &first_units, target_name, .{
        .manifest_result_hash = manifest_hash,
    });
    const second_key = try computeBuildCacheKey(testing.allocator, build_source, &second_units, target_name, .{
        .manifest_result_hash = manifest_hash,
    });

    try testing.expect(!std.mem.eql(u8, first_key[0..], second_key[0..]));
}

test "computeBuildCacheKey length-prefixes source unit fields" {
    const first_units = [_]compiler.SourceUnit{
        .{ .file_path = "ab", .source = "c" },
    };
    const second_units = [_]compiler.SourceUnit{
        .{ .file_path = "a", .source = "bc" },
    };
    const target_name = "test";
    const manifest_hash: u64 = 111;

    const first_key = try computeBuildCacheKey(testing.allocator, "", &first_units, target_name, .{
        .manifest_result_hash = manifest_hash,
    });
    const second_key = try computeBuildCacheKey(testing.allocator, "", &second_units, target_name, .{
        .manifest_result_hash = manifest_hash,
    });

    try testing.expect(!std.mem.eql(u8, first_key[0..], second_key[0..]));
}

test "computeBuildCacheKey is stable across source discovery order" {
    const build_source = "pub struct App.Builder {}";
    const first_units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/b.zap", .source = "pub struct B {}" },
        .{ .file_path = "lib/a.zap", .source = "pub struct A {}" },
    };
    const second_units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/a.zap", .source = "pub struct A {}" },
        .{ .file_path = "lib/b.zap", .source = "pub struct B {}" },
    };

    const first_key = try computeBuildCacheKey(testing.allocator, build_source, &first_units, "test", .{
        .manifest_result_hash = 111,
    });
    const second_key = try computeBuildCacheKey(testing.allocator, build_source, &second_units, "test", .{
        .manifest_result_hash = 111,
    });

    try testing.expectEqual(first_key, second_key);
}

test "Phase 2 ARC stats: build cache key separates runtime collection shape" {
    const build_source = "pub struct App.Builder {}";
    const units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/app.zap", .source = "pub struct App {}" },
    };
    const target_name = "default";
    const manifest_hash: u64 = 111;

    const default_key = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{
        .manifest_result_hash = manifest_hash,
        .collect_arc_stats = false,
    });
    const stats_key = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{
        .manifest_result_hash = manifest_hash,
        .collect_arc_stats = true,
    });

    try testing.expect(!std.mem.eql(u8, default_key[0..], stats_key[0..]));
}

test "computeBuildCacheKey includes active manager source hash" {
    const build_source = "pub struct App.Builder {}";
    const units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/app.zap", .source = "pub struct App {}" },
    };
    const target_name = "default";
    const manifest_hash: u64 = 111;

    const first_key = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{
        .manifest_result_hash = manifest_hash,
        .active_manager_source_digest = testBuildCacheDigest(1),
    });
    const second_key = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{
        .manifest_result_hash = manifest_hash,
        .active_manager_source_digest = testBuildCacheDigest(2),
    });

    try testing.expect(!std.mem.eql(u8, first_key[0..], second_key[0..]));
}

test "computeBuildCacheKey includes compiler identity hash" {
    const build_source = "pub struct App.Builder {}";
    const units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/app.zap", .source = "pub struct App {}" },
    };
    const target_name = "default";
    const manifest_hash: u64 = 111;

    const first_key = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{
        .manifest_result_hash = manifest_hash,
        .compiler_identity_digest = testBuildCacheDigest(1),
    });
    const second_key = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{
        .manifest_result_hash = manifest_hash,
        .compiler_identity_digest = testBuildCacheDigest(2),
    });

    try testing.expect(!std.mem.eql(u8, first_key[0..], second_key[0..]));
}

test "computeBuildCacheKey includes Zig lib identity hash" {
    const build_source = "pub struct App.Builder {}";
    const units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/app.zap", .source = "pub struct App {}" },
    };
    const target_name = "default";
    const manifest_hash: u64 = 111;

    const first_key = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{
        .manifest_result_hash = manifest_hash,
        .zig_lib_identity_digest = testBuildCacheDigest(1),
    });
    const second_key = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{
        .manifest_result_hash = manifest_hash,
        .zig_lib_identity_digest = testBuildCacheDigest(2),
    });

    try testing.expect(!std.mem.eql(u8, first_key[0..], second_key[0..]));
}

test "computeBuildCacheKey includes frontend policy tag separately from optimize" {
    const build_source = "pub struct App.Builder {}";
    const units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/app.zap", .source = "pub struct App {}" },
    };
    const target_name = "default";
    const manifest_hash: u64 = 111;

    const first_key = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{
        .manifest_result_hash = manifest_hash,
        .optimize = .debug,
        .frontend_policy_tag = compiler.FrontendOptimizeMode.debug.cacheTag(),
    });
    const second_key = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, .{
        .manifest_result_hash = manifest_hash,
        .optimize = .debug,
        .frontend_policy_tag = compiler.FrontendOptimizeMode.release_fast.cacheTag(),
    });

    try testing.expect(!std.mem.eql(u8, first_key[0..], second_key[0..]));
}

test "Phase5 content key: every input flips the key (no silent collision)" {
    const a = testing.allocator;
    const base_controls: ScriptContentKeyControls = .{
        .optimize = .debug,
        .frontend_policy_tag = compiler.FrontendOptimizeMode.debug.cacheTag(),
        .memory_manager_name = "Memory.ARC",
        .target = "",
        .cpu = "",
    };

    const k_base = try computeScriptContentKey(a, "fn main(_ :: [String]) { }", testBuildCacheDigest(0xAA), testBuildCacheDigest(0xBB), testBuildCacheDigest(0xCC), base_controls);
    defer a.free(k_base);

    // Script source change ⇒ different key.
    const k_src = try computeScriptContentKey(a, "fn main(_ :: [String]) { IO.puts(\"x\") }", testBuildCacheDigest(0xAA), testBuildCacheDigest(0xBB), testBuildCacheDigest(0xCC), base_controls);
    defer a.free(k_src);
    try testing.expect(!std.mem.eql(u8, k_base, k_src));

    // Stdlib identity change ⇒ different key (no false hit across
    // stdlibs).
    const k_lib = try computeScriptContentKey(a, "fn main(_ :: [String]) { }", testBuildCacheDigest(0xAC), testBuildCacheDigest(0xBB), testBuildCacheDigest(0xCC), base_controls);
    defer a.free(k_lib);
    try testing.expect(!std.mem.eql(u8, k_base, k_lib));

    // Compiler identity change ⇒ different key (rebuilt compiler must
    // not reuse a stale binary).
    const k_cc = try computeScriptContentKey(a, "fn main(_ :: [String]) { }", testBuildCacheDigest(0xAA), testBuildCacheDigest(0xBC), testBuildCacheDigest(0xCC), base_controls);
    defer a.free(k_cc);
    try testing.expect(!std.mem.eql(u8, k_base, k_cc));

    // Zig lib identity change ⇒ different key (mutating the toolchain
    // support library in place must invalidate script artifacts).
    const k_zig_lib = try computeScriptContentKey(a, "fn main(_ :: [String]) { }", testBuildCacheDigest(0xAA), testBuildCacheDigest(0xBB), testBuildCacheDigest(0xCD), base_controls);
    defer a.free(k_zig_lib);
    try testing.expect(!std.mem.eql(u8, k_base, k_zig_lib));

    // Each post-override build control flips the key independently.
    const k_opt = try computeScriptContentKey(a, "fn main(_ :: [String]) { }", testBuildCacheDigest(0xAA), testBuildCacheDigest(0xBB), testBuildCacheDigest(0xCC), .{
        .optimize = .release_fast,
        .frontend_policy_tag = compiler.FrontendOptimizeMode.release_fast.cacheTag(),
        .memory_manager_name = "Memory.ARC",
        .target = "",
        .cpu = "",
    });
    defer a.free(k_opt);
    try testing.expect(!std.mem.eql(u8, k_base, k_opt));

    const k_policy = try computeScriptContentKey(a, "fn main(_ :: [String]) { }", testBuildCacheDigest(0xAA), testBuildCacheDigest(0xBB), testBuildCacheDigest(0xCC), .{
        .optimize = .debug,
        .frontend_policy_tag = compiler.FrontendOptimizeMode.release_fast.cacheTag(),
        .memory_manager_name = "Memory.ARC",
        .target = "",
        .cpu = "",
    });
    defer a.free(k_policy);
    try testing.expect(!std.mem.eql(u8, k_base, k_policy));

    const k_mem = try computeScriptContentKey(a, "fn main(_ :: [String]) { }", testBuildCacheDigest(0xAA), testBuildCacheDigest(0xBB), testBuildCacheDigest(0xCC), .{
        .optimize = .debug,
        .frontend_policy_tag = compiler.FrontendOptimizeMode.debug.cacheTag(),
        .memory_manager_name = "Memory.Arena",
        .target = "",
        .cpu = "",
    });
    defer a.free(k_mem);
    try testing.expect(!std.mem.eql(u8, k_base, k_mem));

    const k_tgt = try computeScriptContentKey(a, "fn main(_ :: [String]) { }", testBuildCacheDigest(0xAA), testBuildCacheDigest(0xBB), testBuildCacheDigest(0xCC), .{
        .optimize = .debug,
        .frontend_policy_tag = compiler.FrontendOptimizeMode.debug.cacheTag(),
        .memory_manager_name = "Memory.ARC",
        .target = "x86_64-linux-musl",
        .cpu = "",
    });
    defer a.free(k_tgt);
    try testing.expect(!std.mem.eql(u8, k_base, k_tgt));

    const k_cpu = try computeScriptContentKey(a, "fn main(_ :: [String]) { }", testBuildCacheDigest(0xAA), testBuildCacheDigest(0xBB), testBuildCacheDigest(0xCC), .{
        .optimize = .debug,
        .frontend_policy_tag = compiler.FrontendOptimizeMode.debug.cacheTag(),
        .memory_manager_name = "Memory.ARC",
        .target = "",
        .cpu = "baseline",
    });
    defer a.free(k_cpu);
    try testing.expect(!std.mem.eql(u8, k_base, k_cpu));
}

test "Phase5 content key: identical inputs are stable (cache HIT is possible)" {
    const a = testing.allocator;
    const controls: ScriptContentKeyControls = .{
        .optimize = .release_safe,
        .frontend_policy_tag = compiler.FrontendOptimizeMode.release_safe.cacheTag(),
        .memory_manager_name = "Memory.Tracking",
        .target = "aarch64-linux-musl",
        .cpu = "baseline",
    };
    const k1 = try computeScriptContentKey(a, "fn main(_ :: [String]) { }", testBuildCacheDigest(0x12), testBuildCacheDigest(0x56), testBuildCacheDigest(0x9A), controls);
    defer a.free(k1);
    const k2 = try computeScriptContentKey(a, "fn main(_ :: [String]) { }", testBuildCacheDigest(0x12), testBuildCacheDigest(0x56), testBuildCacheDigest(0x9A), controls);
    defer a.free(k2);
    // Determinism is the whole point: same inputs ⇒ same key ⇒ the
    // skip-recompile fast path can find the prior artifact.
    try testing.expectEqualStrings(k1, k2);
    try testing.expectEqual(@as(usize, BUILD_CACHE_DIGEST_LEN * 2), k1.len);
}

test "Phase5 content key: control length-prefixing prevents boundary collisions" {
    const a = testing.allocator;
    // ("ab","") must NOT collide with ("a","b") for adjacent string
    // controls — length-prefixing guarantees this.
    const k_ab = try computeScriptContentKey(a, "s", testBuildCacheDigest(1), testBuildCacheDigest(2), testBuildCacheDigest(3), .{
        .optimize = .debug,
        .memory_manager_name = "ab",
        .target = "",
        .cpu = "",
    });
    defer a.free(k_ab);
    const k_a_b = try computeScriptContentKey(a, "s", testBuildCacheDigest(1), testBuildCacheDigest(2), testBuildCacheDigest(3), .{
        .optimize = .debug,
        .memory_manager_name = "a",
        .target = "b",
        .cpu = "",
    });
    defer a.free(k_a_b);
    try testing.expect(!std.mem.eql(u8, k_ab, k_a_b));
}

test "Phase 0 Gap C: script content key folds debug-info and frame-pointer overrides" {
    // Phase 0 — DWARF foundation. The historical key was policy-blind:
    // running `zap run -Doptimize=ReleaseSafe -Dframe-pointers=on` and
    // then `... -Dframe-pointers=off` on the same source would land in
    // the same cache slot, silently producing a binary whose prologue
    // did not match the user's request. Gap C bumps the script key
    // version and folds both tags. This test pins that contract so a
    // future refactor cannot silently regress it.
    const a = testing.allocator;
    const base_controls: ScriptContentKeyControls = .{
        .optimize = .release_safe,
        .frontend_policy_tag = compiler.FrontendOptimizeMode.release_safe.cacheTag(),
        .memory_manager_name = "Memory.ARC",
        .target = "",
        .cpu = "",
    };
    const k_base = try computeScriptContentKey(a, "fn main(_ :: [String]) -> u8 { 0 }", testBuildCacheDigest(0x10), testBuildCacheDigest(0x20), testBuildCacheDigest(0x30), base_controls);
    defer a.free(k_base);

    // `-Ddebug-info=full` flips the key.
    var dbg_controls = base_controls;
    dbg_controls.debug_info_tag = debugInfoCacheTagFor(.full);
    const k_dbg_full = try computeScriptContentKey(a, "fn main(_ :: [String]) -> u8 { 0 }", testBuildCacheDigest(0x10), testBuildCacheDigest(0x20), testBuildCacheDigest(0x30), dbg_controls);
    defer a.free(k_dbg_full);
    try testing.expect(!std.mem.eql(u8, k_base, k_dbg_full));

    // `-Ddebug-info=split` is a distinct key from `=full`.
    var dbg_split = base_controls;
    dbg_split.debug_info_tag = debugInfoCacheTagFor(.split);
    const k_dbg_split = try computeScriptContentKey(a, "fn main(_ :: [String]) -> u8 { 0 }", testBuildCacheDigest(0x10), testBuildCacheDigest(0x20), testBuildCacheDigest(0x30), dbg_split);
    defer a.free(k_dbg_split);
    try testing.expect(!std.mem.eql(u8, k_dbg_full, k_dbg_split));

    // `-Ddebug-info=none` is distinct from both.
    var dbg_none = base_controls;
    dbg_none.debug_info_tag = debugInfoCacheTagFor(.none);
    const k_dbg_none = try computeScriptContentKey(a, "fn main(_ :: [String]) -> u8 { 0 }", testBuildCacheDigest(0x10), testBuildCacheDigest(0x20), testBuildCacheDigest(0x30), dbg_none);
    defer a.free(k_dbg_none);
    try testing.expect(!std.mem.eql(u8, k_dbg_full, k_dbg_none));
    try testing.expect(!std.mem.eql(u8, k_dbg_split, k_dbg_none));

    // `-Dframe-pointers=on` flips the key (the regression Gap C closed).
    var fp_on_controls = base_controls;
    fp_on_controls.frame_pointers_tag = framePointersCacheTagFor(true);
    const k_fp_on = try computeScriptContentKey(a, "fn main(_ :: [String]) -> u8 { 0 }", testBuildCacheDigest(0x10), testBuildCacheDigest(0x20), testBuildCacheDigest(0x30), fp_on_controls);
    defer a.free(k_fp_on);
    try testing.expect(!std.mem.eql(u8, k_base, k_fp_on));

    // `-Dframe-pointers=off` is distinct from `=on` and from the
    // unset (mode-default) base — the prologue actually differs in
    // each case.
    var fp_off_controls = base_controls;
    fp_off_controls.frame_pointers_tag = framePointersCacheTagFor(false);
    const k_fp_off = try computeScriptContentKey(a, "fn main(_ :: [String]) -> u8 { 0 }", testBuildCacheDigest(0x10), testBuildCacheDigest(0x20), testBuildCacheDigest(0x30), fp_off_controls);
    defer a.free(k_fp_off);
    try testing.expect(!std.mem.eql(u8, k_fp_on, k_fp_off));
    try testing.expect(!std.mem.eql(u8, k_base, k_fp_off));
}

test "Phase 0 Gap C: BuildCacheOptions folds debug-info and frame-pointer overrides" {
    // Manifest path mirror of the script test above — the manifest and
    // script paths must agree on cache semantics.
    const build_source = "pub struct App.Builder {}";
    const units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/app.zap", .source = "pub struct App {}" },
    };
    const target_name = "default";

    const base: BuildCacheOptions = .{
        .manifest_result_hash = 0xAB,
        .optimize = .release_safe,
        .frontend_policy_tag = compiler.FrontendOptimizeMode.release_safe.cacheTag(),
    };
    const k_base = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, base);

    var with_dbg = base;
    with_dbg.debug_info_tag = debugInfoCacheTagFor(.full);
    const k_dbg = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, with_dbg);
    try testing.expect(!std.mem.eql(u8, k_base[0..], k_dbg[0..]));

    var with_fp = base;
    with_fp.frame_pointers_tag = framePointersCacheTagFor(true);
    const k_fp = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, with_fp);
    try testing.expect(!std.mem.eql(u8, k_base[0..], k_fp[0..]));
    try testing.expect(!std.mem.eql(u8, k_dbg[0..], k_fp[0..]));

    var both = base;
    both.debug_info_tag = debugInfoCacheTagFor(.full);
    both.frame_pointers_tag = framePointersCacheTagFor(false);
    const k_both = try computeBuildCacheKey(testing.allocator, build_source, &units, target_name, both);
    try testing.expect(!std.mem.eql(u8, k_dbg[0..], k_both[0..]));
    try testing.expect(!std.mem.eql(u8, k_fp[0..], k_both[0..]));
}

test "Phase 0 Gap C: debugInfoCacheTagFor and framePointersCacheTagFor projections" {
    // Pin the wire encoding — these bytes ARE the cache-key contract.
    try testing.expectEqual(@as(u8, 0), debugInfoCacheTagFor(null));
    try testing.expectEqual(@as(u8, 1), debugInfoCacheTagFor(.full));
    try testing.expectEqual(@as(u8, 2), debugInfoCacheTagFor(.split));
    try testing.expectEqual(@as(u8, 3), debugInfoCacheTagFor(.none));

    try testing.expectEqual(@as(u8, 0), framePointersCacheTagFor(null));
    try testing.expectEqual(@as(u8, 1), framePointersCacheTagFor(true));
    try testing.expectEqual(@as(u8, 2), framePointersCacheTagFor(false));
}

test "Phase5 stdlib identity: content AND path sensitive, deterministic (no false hit across stdlibs)" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two stdlib-shaped dirs with the SAME relative file but DIFFERENT
    // contents ⇒ different identity hash.
    tmp.dir.createDirPath(global_io, "libA") catch return error.Unexpected;
    tmp.dir.createDirPath(global_io, "libB") catch return error.Unexpected;
    tmp.dir.writeFile(global_io, .{ .sub_path = "libA/kernel.zap", .data = "pub struct Kernel { fn a() {} }" }) catch return error.Unexpected;
    tmp.dir.writeFile(global_io, .{ .sub_path = "libB/kernel.zap", .data = "pub struct Kernel { fn b() {} }" }) catch return error.Unexpected;

    const path_a = tmp.dir.realPathFileAlloc(global_io, "libA", a) catch return error.Unexpected;
    defer a.free(path_a);
    const path_b = tmp.dir.realPathFileAlloc(global_io, "libB", a) catch return error.Unexpected;
    defer a.free(path_b);

    const h_a = try hashStdlibIdentity(a, path_a);
    const h_b = try hashStdlibIdentity(a, path_b);
    // Different contents ⇒ different identity (no false hit across
    // distinct stdlibs).
    try testing.expect(!std.mem.eql(u8, h_a[0..], h_b[0..]));
    // Deterministic: same dir hashed twice ⇒ identical (so an
    // unchanged stdlib keeps the same key ⇒ cache HIT possible).
    try testing.expectEqual(h_a, try hashStdlibIdentity(a, path_a));

    // Byte-identical contents at a DIFFERENT path ⇒ still a DIFFERENT
    // identity (path is part of identity on purpose: a copied stdlib
    // is a distinct stdlib for caching, never a silent false hit).
    tmp.dir.createDirPath(global_io, "libC") catch return error.Unexpected;
    tmp.dir.writeFile(global_io, .{ .sub_path = "libC/kernel.zap", .data = "pub struct Kernel { fn a() {} }" }) catch return error.Unexpected;
    const path_c = tmp.dir.realPathFileAlloc(global_io, "libC", a) catch return error.Unexpected;
    defer a.free(path_c);
    const h_c = try hashStdlibIdentity(a, path_c);
    try testing.expect(!std.mem.eql(u8, h_a[0..], h_c[0..]));
}

test "P4J2: stdlib identity propagates resolve OutOfMemory" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.createDirPath(global_io, "stdlib") catch return error.Unexpected;
    const stdlib_path = tmp.dir.realPathFileAlloc(global_io, "stdlib", a) catch return error.Unexpected;
    defer a.free(stdlib_path);

    var failing_allocator = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        hashStdlibIdentity(failing_allocator.allocator(), stdlib_path),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

fn expectTinyStdlibIdentityHash(allocator: std.mem.Allocator, stdlib_path: []const u8) !void {
    _ = try hashStdlibIdentity(allocator, stdlib_path);
}

test "P4J2: stdlib identity preserves OutOfMemory during walk and reads" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.createDirPath(global_io, "stdlib/nested") catch return error.Unexpected;
    tmp.dir.writeFile(global_io, .{
        .sub_path = "stdlib/kernel.zap",
        .data = "pub struct Kernel { fn root() {} }",
    }) catch return error.Unexpected;
    tmp.dir.writeFile(global_io, .{
        .sub_path = "stdlib/nested/extra.zap",
        .data = "pub struct Extra { fn nested() {} }",
    }) catch return error.Unexpected;

    const stdlib_path = tmp.dir.realPathFileAlloc(global_io, "stdlib", a) catch return error.Unexpected;
    defer a.free(stdlib_path);

    try testing.checkAllAllocationFailures(
        a,
        expectTinyStdlibIdentityHash,
        .{stdlib_path},
    );
}

test "Zig lib identity: content AND path sensitive, deterministic" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.createDirPath(std.Options.debug_io, "zig_a/std") catch return error.Unexpected;
    tmp.dir.createDirPath(std.Options.debug_io, "zig_b/std") catch return error.Unexpected;
    tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig_a/std/start.zig", .data = "pub const a = 1;" }) catch return error.Unexpected;
    tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig_b/std/start.zig", .data = "pub const a = 1;" }) catch return error.Unexpected;

    const root = tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", a) catch return error.Unexpected;
    defer a.free(root);
    const path_a = try std.fs.path.join(a, &.{ root, "zig_a" });
    defer a.free(path_a);
    const path_b = try std.fs.path.join(a, &.{ root, "zig_b" });
    defer a.free(path_b);

    const cache_dir = try std.fs.path.join(a, &.{ root, ".zap-cache" });
    defer a.free(cache_dir);

    const h_a = try hashZigLibIdentity(a, cache_dir, path_a);
    try testing.expectEqual(h_a, try hashZigLibIdentity(a, cache_dir, path_a));
    const h_b = try hashZigLibIdentity(a, cache_dir, path_b);
    try testing.expect(!std.mem.eql(u8, h_a[0..], h_b[0..]));

    tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig_a/std/start.zig", .data = "pub const a = 2;" }) catch return error.Unexpected;
    const h_changed = try hashZigLibIdentity(a, cache_dir, path_a);
    try testing.expect(!std.mem.eql(u8, h_a[0..], h_changed[0..]));
}

test "Phase 7e: object manifest kind does not guarantee executable startup prologue" {
    try testing.expect(hasGeneratedExecutableStartupPrologue(.bin));
    try testing.expect(!hasGeneratedExecutableStartupPrologue(.lib));
    try testing.expect(!hasGeneratedExecutableStartupPrologue(.obj));
}

test "Phase 2 ARC stats: parse build flag for runtime counter collection" {
    var parsed = try parseTargetArgs(testing.allocator, &.{ "app", "--collect-arc-stats" });
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("app", parsed.target.?);
    try testing.expect(parsed.collect_arc_stats);
}

test "Phase 0 Gap E: per-mode dSYM defaults follow the spec table" {
    // Phase 0 — DWARF foundation, Gap E. The error-system research
    // brief (`docs/error-system-research-brief.md`, Part VI.B #13 &
    // Part VIII) is unambiguous: every optimize mode ships a Mach-O
    // sibling `.dSYM` by default. Debug / ReleaseSafe embed DWARF in
    // the binary AND publish the sibling so lldb / atos / addr2line
    // / Phase 2's panic printer have offline-resolvable symbols.
    // ReleaseFast / ReleaseSmall default to the equivalent of
    // `-Ddebug-info=split`: compile with DWARF, dsymutil extracts the
    // sibling, then the post-link strip removes the debug-map from
    // the shipped binary. The full default matrix:
    //
    //   Mode          | Override | Bundle dSYM | Post-strip binary
    //   ------------- | -------- | ----------- | -----------------
    //   Debug         | (none)   | yes         | no
    //   ReleaseSafe   | (none)   | yes         | no
    //   ReleaseFast   | (none)   | yes         | yes  <- new in Gap E
    //   ReleaseSmall  | (none)   | yes         | yes  <- new in Gap E
    //
    //   Mode          | Override               | Bundle dSYM | Post-strip
    //   ------------- | ---------------------- | ----------- | ----------
    //   any           | -Ddebug-info=full      | yes         | no
    //   any           | -Ddebug-info=split     | yes         | yes
    //   any           | -Ddebug-info=none      | no          | no
    const debug_macos = zap.builder.BuildConfig{
        .name = "probe",
        .version = "0.0.0",
        .kind = .bin,
        .optimize = .debug,
        .target = "aarch64-macos-none",
    };

    // Per-mode defaults (no `-Ddebug-info=` override).
    try testing.expect(needsDarwinDebugSymbols(debug_macos));
    try testing.expect(!needsDarwinDebugMapStripAfterDsymutil(debug_macos));

    var release_safe_macos = debug_macos;
    release_safe_macos.optimize = .release_safe;
    try testing.expect(needsDarwinDebugSymbols(release_safe_macos));
    try testing.expect(!needsDarwinDebugMapStripAfterDsymutil(release_safe_macos));

    var release_fast_macos = debug_macos;
    release_fast_macos.optimize = .release_fast;
    try testing.expect(needsDarwinDebugSymbols(release_fast_macos));
    try testing.expect(needsDarwinDebugMapStripAfterDsymutil(release_fast_macos));

    var release_small_macos = debug_macos;
    release_small_macos.optimize = .release_small;
    try testing.expect(needsDarwinDebugSymbols(release_small_macos));
    try testing.expect(needsDarwinDebugMapStripAfterDsymutil(release_small_macos));

    // Explicit `-Ddebug-info=full` keeps DWARF in the binary AND
    // publishes the sibling (matches Debug-style behavior in every
    // optimize mode); it must NOT trigger the post-strip.
    var release_fast_full = release_fast_macos;
    release_fast_full.debug_info = .full;
    try testing.expect(needsDarwinDebugSymbols(release_fast_full));
    try testing.expect(!needsDarwinDebugMapStripAfterDsymutil(release_fast_full));

    var debug_full = debug_macos;
    debug_full.debug_info = .full;
    try testing.expect(needsDarwinDebugSymbols(debug_full));
    try testing.expect(!needsDarwinDebugMapStripAfterDsymutil(debug_full));

    // Explicit `-Ddebug-info=none` strips and suppresses the sibling
    // in every mode (privacy regression guard: a user who asked for
    // a stripped binary MUST NOT ship the matching DWARF).
    var debug_none = debug_macos;
    debug_none.debug_info = .none;
    try testing.expect(!needsDarwinDebugSymbols(debug_none));
    try testing.expect(!needsDarwinDebugMapStripAfterDsymutil(debug_none));

    var release_safe_none = release_safe_macos;
    release_safe_none.debug_info = .none;
    try testing.expect(!needsDarwinDebugSymbols(release_safe_none));
    try testing.expect(!needsDarwinDebugMapStripAfterDsymutil(release_safe_none));

    var release_fast_none = release_fast_macos;
    release_fast_none.debug_info = .none;
    try testing.expect(!needsDarwinDebugSymbols(release_fast_none));
    try testing.expect(!needsDarwinDebugMapStripAfterDsymutil(release_fast_none));

    var release_small_none = release_small_macos;
    release_small_none.debug_info = .none;
    try testing.expect(!needsDarwinDebugSymbols(release_small_none));
    try testing.expect(!needsDarwinDebugMapStripAfterDsymutil(release_small_none));

    // Explicit `-Ddebug-info=split` pulls every mode into the
    // dSYM-emitting path AND triggers the post-dsymutil strip so the
    // published binary matches the split contract.
    var debug_split = debug_macos;
    debug_split.debug_info = .split;
    try testing.expect(needsDarwinDebugSymbols(debug_split));
    try testing.expect(needsDarwinDebugMapStripAfterDsymutil(debug_split));

    var release_safe_split = release_safe_macos;
    release_safe_split.debug_info = .split;
    try testing.expect(needsDarwinDebugSymbols(release_safe_split));
    try testing.expect(needsDarwinDebugMapStripAfterDsymutil(release_safe_split));

    var release_fast_split = release_fast_macos;
    release_fast_split.debug_info = .split;
    try testing.expect(needsDarwinDebugSymbols(release_fast_split));
    try testing.expect(needsDarwinDebugMapStripAfterDsymutil(release_fast_split));

    var release_small_split = release_small_macos;
    release_small_split.debug_info = .split;
    try testing.expect(needsDarwinDebugSymbols(release_small_split));
    try testing.expect(needsDarwinDebugMapStripAfterDsymutil(release_small_split));

    // Non-Darwin targets never bundle a dSYM regardless of policy.
    // The equivalent ELF / PE artifact (`.dwo` / `.dwp` / `.pdb`) is
    // produced by the toolchain's own split-debug machinery — see
    // `resolveDebugInfoPolicy` for the `want_split_debug` field that
    // future platform wiring will read.
    var debug_linux = debug_macos;
    debug_linux.target = "aarch64-linux-gnu";
    try testing.expect(!needsDarwinDebugSymbols(debug_linux));
    var debug_linux_split = debug_linux;
    debug_linux_split.debug_info = .split;
    try testing.expect(!needsDarwinDebugSymbols(debug_linux_split));
    try testing.expect(!needsDarwinDebugMapStripAfterDsymutil(debug_linux_split));
    var release_fast_linux = debug_linux;
    release_fast_linux.optimize = .release_fast;
    try testing.expect(!needsDarwinDebugSymbols(release_fast_linux));
    try testing.expect(!needsDarwinDebugMapStripAfterDsymutil(release_fast_linux));

    // Static-library outputs never bundle a dSYM (no executable
    // to attach the debug map to).
    var debug_library = debug_macos;
    debug_library.kind = .lib;
    try testing.expect(!needsDarwinDebugSymbols(debug_library));
    var release_fast_library = release_fast_macos;
    release_fast_library.kind = .lib;
    try testing.expect(!needsDarwinDebugSymbols(release_fast_library));
    try testing.expect(!needsDarwinDebugMapStripAfterDsymutil(release_fast_library));
}

test "Darwin debug symbols: native target follows host platform" {
    const native_debug = zap.builder.BuildConfig{
        .name = "probe",
        .version = "0.0.0",
        .kind = .bin,
        .optimize = .debug,
        .target = null,
    };
    try testing.expectEqual(hostUsesDarwinDebugMap(), needsDarwinDebugSymbols(native_debug));
}

test "Darwin debug symbols: bundle path is next to the artifact" {
    const dsym_path = try debugSymbolBundlePath(testing.allocator, "zap-out/bin/probe");
    defer testing.allocator.free(dsym_path);
    try testing.expectEqualStrings("zap-out/bin/probe.dSYM", dsym_path);
}

test "Phase 0 Gap C: resolveDebugInfoPolicy frame_pointers matrix (4 modes x 3 overrides)" {
    // Phase 0 spec table (per `docs/error-system-research-brief.md`
    // §VI.B #13): FP on in Debug / ReleaseSafe; FP off in
    // ReleaseFast / ReleaseSmall. A `-Dframe-pointers=on` override
    // pins FP on regardless of mode; `-Dframe-pointers=off` pins FP
    // off regardless of mode. `null` (no flag) keeps the per-mode
    // default. The resolver's `.frame_pointers` field is a definite
    // `bool` after applying defaults, never `null` — so callers
    // always pass a concrete policy to the V3 ABI.
    const Optimize = zap.builder.BuildConfig.Optimize;
    const cases = [_]struct {
        optimize: Optimize,
        override: ?bool,
        expected_frame_pointers: bool,
    }{
        // Per-mode default rows (null override).
        .{ .optimize = .debug, .override = null, .expected_frame_pointers = true },
        .{ .optimize = .release_safe, .override = null, .expected_frame_pointers = true },
        .{ .optimize = .release_fast, .override = null, .expected_frame_pointers = false },
        .{ .optimize = .release_small, .override = null, .expected_frame_pointers = false },
        // Force-on rows (-Dframe-pointers=on).
        .{ .optimize = .debug, .override = true, .expected_frame_pointers = true },
        .{ .optimize = .release_safe, .override = true, .expected_frame_pointers = true },
        .{ .optimize = .release_fast, .override = true, .expected_frame_pointers = true },
        .{ .optimize = .release_small, .override = true, .expected_frame_pointers = true },
        // Force-off rows (-Dframe-pointers=off).
        .{ .optimize = .debug, .override = false, .expected_frame_pointers = false },
        .{ .optimize = .release_safe, .override = false, .expected_frame_pointers = false },
        .{ .optimize = .release_fast, .override = false, .expected_frame_pointers = false },
        .{ .optimize = .release_small, .override = false, .expected_frame_pointers = false },
    };
    for (cases) |case| {
        const resolution = resolveDebugInfoPolicy(case.optimize, null, case.override);
        try testing.expectEqual(case.expected_frame_pointers, resolution.frame_pointers);
    }
}

test "Phase 0 Gap C: FramePointerPolicy.fromOptional projects bool to the V3 ABI byte" {
    // `null` keeps Zig's per-module default (the V1/V2 path); a
    // definite `true` / `false` maps to the explicit V3 byte. Cover
    // each branch so the ABI projection cannot silently flip.
    try testing.expectEqual(zir_backend.FramePointerPolicy.default, zir_backend.FramePointerPolicy.fromOptional(null));
    try testing.expectEqual(zir_backend.FramePointerPolicy.keep, zir_backend.FramePointerPolicy.fromOptional(true));
    try testing.expectEqual(zir_backend.FramePointerPolicy.omit, zir_backend.FramePointerPolicy.fromOptional(false));

    // The raw ABI bytes are the C boundary; document them via the
    // test so a future enum-reorder triggers a CI-visible failure
    // instead of a silently mis-typed contract.
    try testing.expectEqual(@as(u8, 0), @intFromEnum(zir_backend.FramePointerPolicy.default));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(zir_backend.FramePointerPolicy.keep));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(zir_backend.FramePointerPolicy.omit));
}

fn expectSourceRoot(
    roots: []const zap.discovery.SourceRoot,
    name: []const u8,
    path: []const u8,
) !void {
    for (roots) |root| {
        if (std.mem.eql(u8, root.name, name) and std.mem.eql(u8, root.path, path)) return;
    }
    return error.ExpectedSourceRootMissing;
}

test "manifest source roots include project lib test tools and immediate subdirectories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "lib/list");
    try tmp_dir.dir.createDirPath(global_io, "test/support");
    try tmp_dir.dir.createDirPath(global_io, "tools/zap");

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(project_root);

    var roots: std.ArrayListUnmanaged(zap.discovery.SourceRoot) = .empty;
    try appendProjectSourceRoots(allocator, &roots, project_root);

    const lib_dir = try std.fs.path.join(allocator, &.{ project_root, "lib" });
    defer allocator.free(lib_dir);
    const lib_subdir = try std.fs.path.join(allocator, &.{ project_root, "lib", "list" });
    defer allocator.free(lib_subdir);
    const test_dir = try std.fs.path.join(allocator, &.{ project_root, "test" });
    defer allocator.free(test_dir);
    const test_subdir = try std.fs.path.join(allocator, &.{ project_root, "test", "support" });
    defer allocator.free(test_subdir);
    const tools_dir = try std.fs.path.join(allocator, &.{ project_root, "tools" });
    defer allocator.free(tools_dir);
    const tools_subdir = try std.fs.path.join(allocator, &.{ project_root, "tools", "zap" });
    defer allocator.free(tools_subdir);

    try expectSourceRoot(roots.items, "project", lib_dir);
    try expectSourceRoot(roots.items, "project", lib_subdir);
    try expectSourceRoot(roots.items, "project", test_dir);
    try expectSourceRoot(roots.items, "project", test_subdir);
    try expectSourceRoot(roots.items, "project", tools_dir);
    try expectSourceRoot(roots.items, "project", tools_subdir);
    try expectSourceRoot(roots.items, "project", project_root);
}

test "manifest source roots skip absent optional project roots with typed reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    const missing_lib = try std.fs.path.join(allocator, &.{ project_root, "lib" });

    try testing.expectEqual(OptionalSourceRootSkipReason.missing, try optionalDirectorySkipReason(missing_lib));

    var roots: std.ArrayListUnmanaged(zap.discovery.SourceRoot) = .empty;
    try appendProjectSourceRoots(allocator, &roots, project_root);

    try testing.expectEqual(@as(usize, 1), roots.items.len);
    try testing.expectEqualStrings("project", roots.items[0].name);
    try testing.expectEqualStrings(project_root, roots.items[0].path);
}

test "manifest source roots classify optional file root as not_directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(global_io, .{
        .sub_path = "lib",
        .data = "not a directory",
    });

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    const lib_path = try std.fs.path.join(allocator, &.{ project_root, "lib" });

    try testing.expectEqual(OptionalSourceRootSkipReason.not_directory, try optionalDirectorySkipReason(lib_path));
}

test "required project source scans propagate missing root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    const missing_root = try std.fs.path.join(allocator, &.{ project_root, "missing" });

    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    var discovered = std.StringHashMap(void).init(allocator);
    try testing.expectError(
        error.FileNotFound,
        appendImmediateProjectZapFiles(allocator, missing_root, &source_files, &discovered),
    );

    try testing.expectError(
        error.FileNotFound,
        scanZapFilesRecursive(allocator, missing_root, &source_files, &discovered),
    );
}

test "required project source scans free duplicate owned paths" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(global_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {}",
    });

    const allocator = testing.allocator;
    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(project_root);
    const app_path = try std.fs.path.join(allocator, &.{ project_root, "app.zap" });
    defer allocator.free(app_path);

    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer deinitOwnedPathList(allocator, &source_files);

    var discovered = std.StringHashMap(void).init(allocator);
    defer deinitOwnedPathSet(allocator, &discovered);
    const key = try std.fs.path.resolve(allocator, &.{app_path});
    var key_owned = true;
    defer if (key_owned) allocator.free(key);
    try discovered.put(key, {});
    key_owned = false;

    try appendImmediateProjectZapFiles(allocator, project_root, &source_files, &discovered);
    try scanZapFilesRecursive(allocator, project_root, &source_files, &discovered);
    try testing.expectEqual(@as(usize, 0), source_files.items.len);
}

fn exerciseAppendImmediateProjectZapFilesAllocationFailures(
    allocator: std.mem.Allocator,
    project_root: []const u8,
) !void {
    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer deinitOwnedPathList(allocator, &source_files);
    var discovered = std.StringHashMap(void).init(allocator);
    defer deinitOwnedPathSet(allocator, &discovered);
    try appendImmediateProjectZapFiles(allocator, project_root, &source_files, &discovered);
}

test "appendImmediateProjectZapFiles cleans owned paths on allocation failures" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(global_io, .{
        .sub_path = "app.zap",
        .data = "pub struct App {}",
    });

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", testing.allocator);
    defer testing.allocator.free(project_root);
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseAppendImmediateProjectZapFilesAllocationFailures,
        .{project_root},
    );
}

fn exerciseScanZapFilesRecursiveAllocationFailures(
    allocator: std.mem.Allocator,
    project_root: []const u8,
) !void {
    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer deinitOwnedPathList(allocator, &source_files);
    var discovered = std.StringHashMap(void).init(allocator);
    defer deinitOwnedPathSet(allocator, &discovered);
    try scanZapFilesRecursive(allocator, project_root, &source_files, &discovered);
}

test "scanZapFilesRecursive cleans owned paths on allocation failures" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(global_io, "lib/nested");
    try tmp_dir.dir.writeFile(global_io, .{
        .sub_path = "lib/app.zap",
        .data = "pub struct App {}",
    });
    try tmp_dir.dir.writeFile(global_io, .{
        .sub_path = "lib/nested/dep.zap",
        .data = "pub struct Dep {}",
    });

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, "lib", testing.allocator);
    defer testing.allocator.free(project_root);
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseScanZapFilesRecursiveAllocationFailures,
        .{project_root},
    );
}

fn exerciseAppendFileFingerprintAllocationFailures(allocator: std.mem.Allocator) !void {
    var files: std.ArrayListUnmanaged(build_cache.FileFingerprint) = .empty;
    defer {
        for (files.items) |fingerprint| allocator.free(fingerprint.path);
        files.deinit(allocator);
    }
    try appendFileFingerprint(allocator, &files, "missing-p4j2-file.zap");
}

fn exerciseAppendAbsentFileFingerprintAllocationFailures(allocator: std.mem.Allocator) !void {
    var files: std.ArrayListUnmanaged(build_cache.FileFingerprint) = .empty;
    defer {
        for (files.items) |fingerprint| allocator.free(fingerprint.path);
        files.deinit(allocator);
    }
    try appendAbsentFileFingerprint(allocator, &files, "missing-p4j2-absent.zap");
}

fn exerciseAppendDirectoryFingerprintAllocationFailures(allocator: std.mem.Allocator) !void {
    var directories: std.ArrayListUnmanaged(build_cache.DirectoryFingerprint) = .empty;
    defer {
        for (directories.items) |fingerprint| allocator.free(fingerprint.path);
        directories.deinit(allocator);
    }
    try appendDirectoryFingerprint(allocator, &directories, "missing-p4j2-dir", false);
}

fn exerciseAppendManifestEnvFingerprintAllocationFailures(allocator: std.mem.Allocator) !void {
    var env_vars: std.ArrayListUnmanaged(build_cache.EnvFingerprint) = .empty;
    defer {
        for (env_vars.items) |fingerprint| allocator.free(fingerprint.name);
        env_vars.deinit(allocator);
    }

    try appendManifestEnvFingerprint(allocator, &env_vars, "P4J2_ENV", true, 0x1234);

    try testing.expectEqual(@as(usize, 1), env_vars.items.len);
    try testing.expectEqualStrings("P4J2_ENV", env_vars.items[0].name);
    try testing.expect(env_vars.items[0].present);
    try testing.expectEqual(@as(u64, 0x1234), env_vars.items[0].value_hash);
}

fn exerciseAppendManifestGlobFingerprintAllocationFailures(allocator: std.mem.Allocator) !void {
    var globs: std.ArrayListUnmanaged(build_cache.GlobFingerprint) = .empty;
    defer {
        for (globs.items) |fingerprint| allocator.free(fingerprint.pattern);
        globs.deinit(allocator);
    }

    try appendManifestGlobFingerprint(allocator, &globs, "lib/**/*.zap", 0x5678);

    try testing.expectEqual(@as(usize, 1), globs.items.len);
    try testing.expectEqualStrings("lib/**/*.zap", globs.items[0].pattern);
    try testing.expectEqual(@as(u64, 0x5678), globs.items[0].result_hash);
}

test "manifest fingerprint append helpers clean owned paths on allocation failures" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseAppendFileFingerprintAllocationFailures,
        .{},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseAppendAbsentFileFingerprintAllocationFailures,
        .{},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseAppendDirectoryFingerprintAllocationFailures,
        .{},
    );
}

test "P4J2: manifest dependency append helpers clean env and glob payloads on allocation failures" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseAppendManifestEnvFingerprintAllocationFailures,
        .{},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseAppendManifestGlobFingerprintAllocationFailures,
        .{},
    );
}

fn exerciseCollectMemoryAdapterSourceUnitsAllocationFailures(
    allocator: std.mem.Allocator,
    source_root_path: []const u8,
) !void {
    const source_roots = [_]zap.discovery.SourceRoot{
        .{ .name = "zap_stdlib", .path = source_root_path },
    };
    const units = try collectMemoryAdapterSourceUnits(allocator, &source_roots);
    defer {
        for (units) |unit| {
            allocator.free(unit.file_path);
            allocator.free(unit.source);
        }
        allocator.free(units);
    }
}

test "collectMemoryAdapterSourceUnits cleans owned sources on allocation failures" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(global_io, .{
        .sub_path = "adapter.zap",
        .data = "pub struct Adapter {}",
    });

    const source_root_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", testing.allocator);
    defer testing.allocator.free(source_root_path);
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseCollectMemoryAdapterSourceUnitsAllocationFailures,
        .{source_root_path},
    );
}

test "manifest path glob expansion propagates missing base directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    var results: std.ArrayListUnmanaged([]const u8) = .empty;

    try testing.expectError(
        error.FileNotFound,
        globCollectFiles(allocator, project_root, "missing/**/*.zap", &results),
    );
}

test "manifest source roots include path deps, local overrides, and stdlib roots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "lib");
    try tmp_dir.dir.createDirPath(global_io, "deps/math/lib/extra");
    try tmp_dir.dir.createDirPath(global_io, "override/logging/src");
    try tmp_dir.dir.createDirPath(global_io, "stdlib/zap");

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(project_root);
    const zap_lib_dir = try std.fs.path.join(allocator, &.{ project_root, "stdlib" });
    defer allocator.free(zap_lib_dir);

    const deps = [_]zap.builder.BuildConfig.Dep{
        .{ .name = "math", .source = .{ .path = "deps/math" } },
        .{ .name = "logging", .source = .{ .path = "deps/logging" }, .local_override = "override/logging" },
    };
    const config = zap.builder.BuildConfig{
        .name = "app",
        .version = "0.1.0",
        .kind = .bin,
        .root = "App.main/0",
        .deps = &deps,
    };

    const roots = try resolveManifestSourceRoots(allocator, project_root, config, zap_lib_dir, .{
        .write_lockfile = false,
        .print_local_overrides = false,
    });

    const math_lib = try std.fs.path.join(allocator, &.{ project_root, "deps", "math", "lib" });
    defer allocator.free(math_lib);
    const math_extra = try std.fs.path.join(allocator, &.{ project_root, "deps", "math", "lib", "extra" });
    defer allocator.free(math_extra);
    const logging_root = try std.fs.path.join(allocator, &.{ project_root, "override", "logging" });
    defer allocator.free(logging_root);
    const logging_src = try std.fs.path.join(allocator, &.{ project_root, "override", "logging", "src" });
    defer allocator.free(logging_src);
    const zap_subdir = try std.fs.path.join(allocator, &.{ zap_lib_dir, "zap" });
    defer allocator.free(zap_subdir);

    try expectSourceRoot(roots, "dep:math", math_lib);
    try expectSourceRoot(roots, "dep:math", math_extra);
    try expectSourceRoot(roots, "dep:logging", logging_root);
    try expectSourceRoot(roots, "dep:logging", logging_src);
    try expectSourceRoot(roots, "zap_stdlib", zap_lib_dir);
    try expectSourceRoot(roots, "zap_stdlib", zap_subdir);
}

const FailingSourceRootLockfileWriter = struct {
    fn writeLockfile(
        _: FailingSourceRootLockfileWriter,
        _: std.mem.Allocator,
        _: []const u8,
        _: []const zap.lockfile.LockEntry,
    ) !void {
        return error.TestLockfileWriteFailed;
    }
};

test "manifest source roots propagate required lockfile write failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "deps/math/lib");

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(project_root);

    const deps = [_]zap.builder.BuildConfig.Dep{
        .{ .name = "math", .source = .{ .path = "deps/math" } },
    };
    const config = zap.builder.BuildConfig{
        .name = "app",
        .version = "0.1.0",
        .kind = .bin,
        .root = "App.main/0",
        .deps = &deps,
    };

    try testing.expectError(
        error.TestLockfileWriteFailed,
        resolveManifestSourceRootsWithLockfileWriter(
            allocator,
            project_root,
            config,
            null,
            .{
                .write_lockfile = true,
                .print_local_overrides = false,
            },
            FailingSourceRootLockfileWriter{},
        ),
    );
}

test "manifest source roots propagate malformed lockfile reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(global_io, .{
        .sub_path = "zap.lock",
        .data = "invalid lockfile line\n",
    });

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(project_root);

    const config = zap.builder.BuildConfig{
        .name = "app",
        .version = "0.1.0",
        .kind = .bin,
        .root = "App.main/0",
    };

    try testing.expectError(
        error.InvalidLockfile,
        resolveManifestSourceRoots(allocator, project_root, config, null, .{
            .write_lockfile = false,
            .print_local_overrides = false,
        }),
    );
}

test "lockfile entry changed detection compares source and integrity fields" {
    const original = zap.lockfile.LockEntry{
        .name = "dep",
        .source_type = "git",
        .url = "https://example.invalid/old.git",
        .resolved_ref = "v1.0.0",
        .commit = "1234567890abcdef",
        .integrity = "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };

    try testing.expect(!lockEntryChanged(original, original));
    try testing.expect(lockEntryChanged(original, .{
        .name = "dep",
        .source_type = "path",
        .url = "deps/dep",
        .resolved_ref = "-",
        .commit = "1234567890abcdef",
        .integrity = "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }));
    try testing.expect(lockEntryChanged(original, .{
        .name = "dep",
        .source_type = "git",
        .url = "https://example.invalid/new.git",
        .resolved_ref = "v1.0.0",
        .commit = "1234567890abcdef",
        .integrity = "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }));
    try testing.expect(lockEntryChanged(original, .{
        .name = "dep",
        .source_type = "git",
        .url = "https://example.invalid/old.git",
        .resolved_ref = "v2.0.0",
        .commit = "1234567890abcdef",
        .integrity = "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }));
    try testing.expect(lockEntryChanged(original, .{
        .name = "dep",
        .source_type = "git",
        .url = "https://example.invalid/old.git",
        .resolved_ref = "v1.0.0",
        .commit = "1234567890abcdef",
        .integrity = "sha256-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    }));
}

test "manifest source-root recursive scan policy covers protocol and impl roots" {
    try testing.expect(sourceRootShouldScanRecursively(.{ .name = "project", .path = "lib" }));
    try testing.expect(sourceRootShouldScanRecursively(.{ .name = "project", .path = "test" }));
    try testing.expect(sourceRootShouldScanRecursively(.{ .name = "project", .path = "tools" }));
    try testing.expect(sourceRootShouldScanRecursively(.{ .name = "dep:math", .path = "vendor/math" }));
    try testing.expect(sourceRootShouldScanRecursively(.{ .name = "zap_stdlib", .path = "stdlib" }));
    try testing.expect(!sourceRootShouldScanRecursively(.{ .name = "project", .path = "." }));
}

test "project source file honors manifest paths globs for the supplementary protocol/impl scan" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const project_root = "/work/project";
    const manifest_paths = [_][]const u8{"test/**/*_test.zap"};

    // A real Zest module under the manifest glob is in scope.
    try testing.expect(try projectSourceFileMatchesManifestPaths(
        allocator,
        &manifest_paths,
        project_root,
        "/work/project/test/option_test.zap",
    ));
    // A nested real Zest module still matches `**`.
    try testing.expect(try projectSourceFileMatchesManifestPaths(
        allocator,
        &manifest_paths,
        project_root,
        "/work/project/test/support/nested_test.zap",
    ));
    // A script-mode fixture (top-level `fn main`) is OUT of scope: it does
    // not end in `_test.zap`, so the manifest glob never selects it. This is
    // exactly the `test/fixtures/` over-collection the scan must exclude.
    try testing.expect(!try projectSourceFileMatchesManifestPaths(
        allocator,
        &manifest_paths,
        project_root,
        "/work/project/test/fixtures/raise_cross_fn/cross_fn_catch.zap",
    ));
    // A non-test helper under `test/` that is not a `_test.zap` module is
    // also excluded from the supplementary scan; real modules that need it
    // pull it in through the explicit import graph instead.
    try testing.expect(!try projectSourceFileMatchesManifestPaths(
        allocator,
        &manifest_paths,
        project_root,
        "/work/project/test/result_helper.zap",
    ));
    // Relative project roots (the live `zap test` invocation passes
    // a relative "./test" path through the source roots) match identically.
    try testing.expect(try projectSourceFileMatchesManifestPaths(
        allocator,
        &manifest_paths,
        ".",
        "./test/option_test.zap",
    ));
    try testing.expect(!try projectSourceFileMatchesManifestPaths(
        allocator,
        &manifest_paths,
        ".",
        "./test/fixtures/raise_cross_fn/cross_fn_catch.zap",
    ));

    // An empty manifest `paths` list means "no explicit scope" — the
    // supplementary scan must fall back to contributing every project file
    // so a manifest that relies purely on import-graph discovery keeps its
    // protocols/impls globally visible.
    const no_paths = [_][]const u8{};
    try testing.expect(try projectSourceFileMatchesManifestPaths(
        allocator,
        &no_paths,
        project_root,
        "/work/project/test/fixtures/raise_cross_fn/cross_fn_catch.zap",
    ));
}

// ---------------------------------------------------------------------------
// `zap run` dispatch + foreign-target run-vs-report — pure helper unit
// tests. `firstPositionalIndex` locates the script/target positional and
// MUST mirror exactly the value-consuming flags `parseTargetArgs`
// recognizes (`--build-file`/`--zap-lib-dir`/`--seed`/`--slowest`);
// a regression
// that re-adds a removed two-token flag (`-O`/`--memory`/`--target`)
// would swallow the script path and mis-dispatch (the locked position
// contract: only `-D…`, `--zap-lib-dir`, boolean build flags, and
// explicit test-runner options are recognized leading flags).
// `targetIsHostRunnable`
// decides the run-vs-report split for a cross-built artifact. Both are
// filesystem-free and exercised by `zig build test` without spawning a
// process.
// ---------------------------------------------------------------------------

test "firstPositionalIndex: bare script path is the first positional" {
    try testing.expectEqual(@as(?usize, 0), firstPositionalIndex(&.{"s.zap"}));
}

test "firstPositionalIndex: -D and boolean flags do not consume the next token" {
    // `-D<key>=<value>` is a single self-contained token and the
    // boolean flags take no value, so the script path right after them
    // is still correctly identified as the positional.
    try testing.expectEqual(
        @as(?usize, 3),
        firstPositionalIndex(&.{ "-Doptimize=Debug", "-Dmemory=Memory.Arena", "--watch", "s.zap" }),
    );
    try testing.expectEqual(
        @as(?usize, 1),
        firstPositionalIndex(&.{ "--collect-arc-stats", "s.zap" }),
    );
    try testing.expectEqual(
        @as(?usize, 1),
        firstPositionalIndex(&.{ "--trace-incremental", "s.zap" }),
    );
}

test "firstPositionalIndex: recognized two-token flags skip their value" {
    // EXACTLY the flags `parseTargetArgs` treats as value-consuming.
    try testing.expectEqual(
        @as(?usize, 2),
        firstPositionalIndex(&.{ "--zap-lib-dir", "/some/lib", "s.zap" }),
    );
    try testing.expectEqual(
        @as(?usize, 4),
        firstPositionalIndex(&.{ "--build-file", "b.zap", "--seed", "7", "s.zap" }),
    );
    try testing.expectEqual(
        @as(?usize, 3),
        firstPositionalIndex(&.{ "--slowest", "10", "--timings", "s.zap" }),
    );
}

test "firstPositionalIndex: removed -O/--memory/--target are NOT value-consuming (no script-path swallow)" {
    // Regression guard for the dispatch defect: Phase 4 deleted the
    // two-token `-O`/`--memory`/`--target` spellings. If they were
    // (wrongly) still treated as value-consuming, the token AFTER them
    // — the real script path — would be skipped and dispatch would
    // fall to the manifest path. The positional must be the dash-token
    // itself (index 0): it is just an unrecognized flag, NOT a
    // value-consuming one, so it never swallows `s.zap`.
    try testing.expectEqual(@as(?usize, 0), firstPositionalIndex(&.{ "--target", "s.zap" }));
    try testing.expectEqual(@as(?usize, 0), firstPositionalIndex(&.{ "--memory", "s.zap" }));
    try testing.expectEqual(@as(?usize, 0), firstPositionalIndex(&.{ "-O", "s.zap" }));
}

test "firstPositionalIndex: `--` before any positional yields null (no script/target)" {
    try testing.expectEqual(@as(?usize, null), firstPositionalIndex(&.{ "--", "x", "y" }));
    try testing.expectEqual(@as(?usize, null), firstPositionalIndex(&.{}));
    try testing.expectEqual(@as(?usize, null), firstPositionalIndex(&.{"--watch"}));
}

test "firstPositionalIndex: post-positional tokens never re-trigger flag skipping" {
    // Once the positional (script path) is found its index is returned
    // immediately; everything after it is the opaque forward region and
    // is never re-scanned for flags here.
    try testing.expectEqual(
        @as(?usize, 0),
        firstPositionalIndex(&.{ "s.zap", "--zap-lib-dir", "ignored", "--", "-Dx=1" }),
    );
}

test "P4J2: classifyRunPositional treats true absence as manifest" {
    const kind = try classifyRunPositional(testing.allocator, &.{"missing/p4j2/run-target"});
    switch (kind) {
        .manifest => {},
        else => return error.TestExpectedEqual,
    }
}

test "P4J2: classifyRunPositional propagates canonicalization OutOfMemory" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    try testing.expectError(
        error.OutOfMemory,
        classifyRunPositional(failing_allocator.allocator(), &.{"src/main.zig"}),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: classifyRunPositional propagates canonicalization filesystem errors" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink(global_io, "loop.zap", "loop.zap", .{});
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    const loop_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "loop.zap" });
    defer testing.allocator.free(loop_path);

    try testing.expectError(
        error.SymLinkLoop,
        classifyRunPositional(testing.allocator, &.{loop_path}),
    );
}

test "leadingFlagPresent scans only the pre-script region" {
    const args = &.{ "--trace-incremental", "s.zap", "--trace-incremental" };

    try testing.expect(leadingFlagPresent(args, 1, "--trace-incremental"));
    try testing.expect(!leadingFlagPresent(args, 0, "--trace-incremental"));
}

test "makeSingleFileTestRunnerSource calls selected Zest case structs" {
    const runner = try makeSingleFileTestRunnerSource(
        testing.allocator,
        &.{ "Tmp.FirstCase", "Tmp.SecondCase" },
    );
    defer testing.allocator.free(runner);

    try testing.expect(std.mem.indexOf(
        u8,
        runner,
        "Zest.Runner.configure()",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        runner,
        "Tmp.FirstCase.run()",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        runner,
        "Tmp.SecondCase.run()",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        runner,
        "Zest.Runner.run()",
    ) != null);
}

test "targetIsHostRunnable: null target (native, incl. bare -Dcpu) is always runnable" {
    try testing.expect(targetIsHostRunnable(null));
}

test "targetIsHostRunnable: the exact host triple is runnable" {
    const host = std.fmt.comptimePrint("{s}-{s}-none", .{
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
    });
    try testing.expect(targetIsHostRunnable(host));
}

test "targetIsHostRunnable: a foreign arch or OS is NOT runnable (report-not-exec)" {
    // Foreign arch (host OS) and foreign OS (host arch) must both be
    // rejected so the caller reports the artifact instead of exec'ing
    // a binary the kernel cannot run.
    const foreign_arch = if (builtin.target.cpu.arch == .aarch64)
        "x86_64-linux-musl"
    else
        "aarch64-linux-musl";
    try testing.expect(!targetIsHostRunnable(foreign_arch));
    try testing.expect(!targetIsHostRunnable("wasm32-wasi"));
    // Unparseable / nonsense triple fails safe (not runnable).
    try testing.expect(!targetIsHostRunnable("bogus-not-a-target"));
}

test "targetIsHostRunnable: ABI/libc difference alone does not block exec (only arch+OS compared)" {
    // On a Linux host `*-linux-gnu` vs `*-linux-musl` differ only in
    // libc; the kernel still execs either, so only arch+OS are
    // compared. This assertion is host-OS-specific, so it only runs
    // when the test host actually IS Linux.
    if (builtin.target.os.tag == .linux) {
        const same_arch = @tagName(builtin.target.cpu.arch);
        const gnu = std.fmt.comptimePrint("{s}-linux-gnu", .{same_arch});
        const musl = std.fmt.comptimePrint("{s}-linux-musl", .{same_arch});
        try testing.expect(targetIsHostRunnable(gnu));
        try testing.expect(targetIsHostRunnable(musl));
    }
}

// ---------------------------------------------------------------------------
// Zap stdlib resolver — precedence helper unit tests
// ---------------------------------------------------------------------------

test "chooseZapLibDir: explicit flag wins over every lower precedence source" {
    const chosen = chooseZapLibDir(
        "/from/flag/lib",
        "/from/env/lib",
        "/from/project/lib",
        "/from/exe/lib",
        "/from/cwd/lib",
    );
    try testing.expectEqualStrings("/from/flag/lib", chosen.?);
}

test "chooseZapLibDir: env wins when flag is absent" {
    const chosen = chooseZapLibDir(
        null,
        "/from/env/lib",
        "/from/project/lib",
        "/from/exe/lib",
        "/from/cwd/lib",
    );
    try testing.expectEqualStrings("/from/env/lib", chosen.?);
}

test "chooseZapLibDir: project-relative wins over exe-relative and cwd when flag/env absent" {
    const chosen = chooseZapLibDir(
        null,
        null,
        "/from/project/lib",
        "/from/exe/lib",
        "/from/cwd/lib",
    );
    try testing.expectEqualStrings("/from/project/lib", chosen.?);
}

test "chooseZapLibDir: exe-relative wins when flag, env, and project are absent" {
    const chosen = chooseZapLibDir(
        null,
        null,
        null,
        "/from/exe/lib",
        "/from/cwd/lib",
    );
    try testing.expectEqualStrings("/from/exe/lib", chosen.?);
}

test "chooseZapLibDir: cwd fallback wins when all higher sources are absent" {
    const chosen = chooseZapLibDir(
        null,
        null,
        null,
        null,
        "/from/cwd/lib",
    );
    try testing.expectEqualStrings("/from/cwd/lib", chosen.?);
}

test "chooseZapLibDir: returns null when no source resolves" {
    try testing.expect(chooseZapLibDir(null, null, null, null, null) == null);
}

test "resolveZapLibDir: invalid explicit flag dir without kernel.zap is a hard error" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    try testing.expectError(
        error.InvalidZapLibDir,
        resolveZapLibDir(testing.allocator, tmp_path, null),
    );
}

test "P4J2: resolveZapLibDir preserves OutOfMemory while validating explicit dir" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    tmp_dir.dir.writeFile(global_io, .{ .sub_path = "kernel.zap", .data = "" }) catch
        return error.SkipZigTest;
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var fixed_buffer: [0]u8 = .{};
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    try testing.expectError(
        error.OutOfMemory,
        resolveZapLibDir(fixed_allocator.allocator(), tmp_path, null),
    );
}

test "P4J2: resolveZapLibDir reports access failure while validating explicit dir" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    tmp_dir.dir.symLink(global_io, "kernel.zap", "kernel.zap", .{}) catch
        return error.SkipZigTest;
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    try testing.expectError(
        error.ZapLibDirAccessFailed,
        resolveZapLibDir(testing.allocator, tmp_path, null),
    );
}

fn exerciseResolveExeRelativeZapLibDirAllocationFailures(allocator: std.mem.Allocator) !void {
    const resolved = try resolveExeRelativeZapLibDir(allocator);
    defer if (resolved) |dir| allocator.free(dir);
}

test "P4J2: resolveExeRelativeZapLibDir preserves allocation failures" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseResolveExeRelativeZapLibDirAllocationFailures,
        .{},
    );
}

test "resolveZapLibDir: valid explicit flag dir containing kernel.zap is accepted" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    tmp_dir.dir.writeFile(global_io, .{ .sub_path = "kernel.zap", .data = "" }) catch
        return error.SkipZigTest;
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const resolved = try resolveZapLibDir(testing.allocator, tmp_path, null);
    defer if (resolved) |r| testing.allocator.free(r);
    try testing.expect(resolved != null);
    try testing.expectEqualStrings(tmp_path, resolved.?);
}

test "resolveZapLibDir: no flag, no env behaves like the legacy exe-walk/cwd path" {
    // With no override and (in the test environment) no ZAP_LIB_DIR, the
    // resolver must still produce the in-repo `lib` directory because the
    // test runner's cwd is the project root containing `lib/kernel.zap`.
    // This guards the "behavior identical to today when flag/env absent"
    // regression requirement. A `null` project_root means the
    // project-root tier never applies, so this is byte-for-byte the
    // legacy exe-walk/cwd path.
    const resolved = try resolveZapLibDir(testing.allocator, null, null);
    defer if (resolved) |r| testing.allocator.free(r);
    try testing.expect(resolved != null);
    const kernel_path = try std.fs.path.join(testing.allocator, &.{ resolved.?, "kernel.zap" });
    defer testing.allocator.free(kernel_path);
    try std.Io.Dir.cwd().access(global_io, kernel_path, .{});
}

test "resolveZapLibDir: project-root stdlib working tree wins over exe-relative copy" {
    // A project that is itself a Zap stdlib source tree (its own
    // `lib/kernel.zap` exists) is authoritative: the resolver must
    // return that working-tree `lib/`, never a lower-precedence
    // exe-relative installed copy. This is what keeps `zap test` /
    // `zap build` run from inside the stdlib repo compiling the edited
    // tree, and stops discovery from scanning two physical copies of
    // every stdlib file (the "struct already defined" regression).
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    tmp_dir.dir.createDirPath(global_io, "lib") catch return error.SkipZigTest;
    tmp_dir.dir.writeFile(global_io, .{ .sub_path = "lib/kernel.zap", .data = "" }) catch
        return error.SkipZigTest;
    const proj_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", testing.allocator);
    defer testing.allocator.free(proj_root);

    const resolved = try resolveZapLibDir(testing.allocator, null, proj_root);
    defer if (resolved) |r| testing.allocator.free(r);
    try testing.expect(resolved != null);

    const expected = try std.fs.path.join(testing.allocator, &.{ proj_root, "lib" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, resolved.?);
}

test "resolveZapLibDir: ordinary project lib without kernel.zap does not hijack resolution" {
    // An ordinary app project's `lib/` holds the app's own code, not a
    // stdlib, so the project-root tier must be skipped — resolution
    // falls through to exe-relative / cwd exactly as before. Guards
    // against the project tier over-reaching beyond genuine stdlib
    // source trees.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    tmp_dir.dir.createDirPath(global_io, "lib") catch return error.SkipZigTest;
    // Note: a `lib/` with NO `kernel.zap`.
    const proj_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", testing.allocator);
    defer testing.allocator.free(proj_root);

    const resolved = try resolveZapLibDir(testing.allocator, null, proj_root);
    defer if (resolved) |r| testing.allocator.free(r);
    // Whatever resolves (exe-relative or cwd `./lib`), it must NOT be
    // the kernel-less project lib.
    if (resolved) |r| {
        const proj_lib = try std.fs.path.join(testing.allocator, &.{ proj_root, "lib" });
        defer testing.allocator.free(proj_lib);
        try testing.expect(!std.mem.eql(u8, proj_lib, r));
    }
}

test "parseTargetArgs: captures --zap-lib-dir and leaves other fields unchanged" {
    var parsed = try parseTargetArgs(testing.allocator, &.{ "app", "--zap-lib-dir", "/custom/lib" });
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("app", parsed.target.?);
    try testing.expectEqualStrings("/custom/lib", parsed.zap_lib_dir.?);
    // Untouched fields keep their defaults.
    try testing.expect(parsed.build_file == null);
    try testing.expect(parsed.seed == null);
    try testing.expect(parsed.watch == false);
    // No `-D` flags given ⇒ every override stays unset so the
    // manifest values win for this build.
    try testing.expect(parsed.build_overrides.optimize == null);
    try testing.expect(parsed.build_overrides.memory == null);
    try testing.expect(parsed.build_overrides.target == null);
    try testing.expect(parsed.build_overrides.cpu == null);
    try testing.expect(parsed.collect_arc_stats == false);
    try testing.expect(parsed.no_deps == false);
    try testing.expect(parsed.run_args.len == 0);
}

test "parseTargetArgs: absence of --zap-lib-dir is identical to the baseline parse" {
    // Baseline: the exact existing ARC-stats parse case must be byte-for-byte
    // unchanged when the new flag is absent.
    var parsed = try parseTargetArgs(testing.allocator, &.{ "app", "--collect-arc-stats" });
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("app", parsed.target.?);
    try testing.expect(parsed.collect_arc_stats);
    try testing.expect(parsed.zap_lib_dir == null);
}

// ---------------------------------------------------------------------------
// Build file discovery
// ---------------------------------------------------------------------------

const BuildFileAccessStatus = enum {
    present,
    missing,
};

fn buildFileAccessStatus(path: []const u8) !BuildFileAccessStatus {
    std.Io.Dir.cwd().access(global_io, path, .{}) catch |err| {
        if (isMissingPathAccessError(err)) return .missing;
        return err;
    };
    return .present;
}

/// Find build.zap and return the project root directory.
fn discoverBuildFile(allocator: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    if (override) |path| {
        switch (try buildFileAccessStatus(path)) {
            .present => {},
            .missing => {
                // stderr writer removed in 0.16
                std.debug.print("Error: build file not found: {s}\n", .{path});
                std.process.exit(1);
            },
        }
        // Project root is the directory containing the build file
        if (std.fs.path.dirname(path)) |dir| {
            return try allocator.dupe(u8, dir);
        }
        return try allocator.dupe(u8, ".");
    }

    // Default: look for build.zap in cwd
    switch (try buildFileAccessStatus("build.zap")) {
        .present => {},
        .missing => {
            // stderr writer removed in 0.16
            std.debug.print("Error: no build.zap found in current directory\n", .{});
            std.process.exit(1);
        },
    }

    return try allocator.dupe(u8, ".");
}

test "build file access treats absent and not-directory paths as missing" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "parent", .data = "not a directory" });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const absent_path = try std.fs.path.join(allocator, &.{ tmp_path, "missing-build.zap" });
    defer allocator.free(absent_path);
    const not_directory_path = try std.fs.path.join(allocator, &.{ tmp_path, "parent/build.zap" });
    defer allocator.free(not_directory_path);

    try std.testing.expectEqual(BuildFileAccessStatus.missing, try buildFileAccessStatus(absent_path));
    try std.testing.expectEqual(BuildFileAccessStatus.missing, try buildFileAccessStatus(not_directory_path));
}

test "build file access propagates non-missing path failures" {
    const allocator = std.testing.allocator;
    const too_long_prefix = try allocator.alloc(u8, std.fs.max_path_bytes + 1);
    defer allocator.free(too_long_prefix);
    @memset(too_long_prefix, 'a');
    const build_file_path = try std.fmt.allocPrint(allocator, "{s}/build.zap", .{too_long_prefix});
    defer allocator.free(build_file_path);

    try std.testing.expectError(error.NameTooLong, buildFileAccessStatus(build_file_path));
}

test "build file access propagates symlink-loop failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink(global_io, "build.zap", "build.zap", .{});

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(tmp_path);
    const build_file_path = try std.fs.path.join(allocator, &.{ tmp_path, "build.zap" });
    defer allocator.free(build_file_path);

    try std.testing.expectError(error.SymLinkLoop, buildFileAccessStatus(build_file_path));
}

// ---------------------------------------------------------------------------
// Glob-based source file collection
// ---------------------------------------------------------------------------

/// Match a file path against a simple glob pattern.
/// Supports: `*` (any non-/ chars), `**` (any path depth), literal chars.
fn globMatch(pattern: []const u8, path: []const u8) bool {
    return zap.glob.match(pattern, path);
}

/// Collect .zap files matching a glob pattern, relative to project_root.
/// Always excludes build.zap.
fn globCollectFiles(
    alloc: std.mem.Allocator,
    project_root: []const u8,
    pattern: []const u8,
    results: *std.ArrayListUnmanaged([]const u8),
) !void {
    // Determine the base directory (everything before the first wildcard)
    var base_end: usize = 0;
    for (pattern, 0..) |c, i| {
        if (c == '*' or c == '?') break;
        if (c == '/') base_end = i + 1;
    }

    const base_rel = if (base_end > 0) pattern[0..base_end] else ".";
    const sub_pattern = if (base_end > 0) pattern[base_end..] else pattern;
    const has_double_star = std.mem.find(u8, sub_pattern, "**") != null;

    const base_dir = if (std.mem.eql(u8, base_rel, "."))
        try alloc.dupe(u8, project_root)
    else
        try std.fs.path.join(alloc, &.{ project_root, base_rel });
    defer alloc.free(base_dir);

    try walkAndMatch(alloc, base_dir, base_dir, sub_pattern, project_root, has_double_star, results);
}

fn walkAndMatch(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    base_dir: []const u8,
    pattern: []const u8,
    project_root: []const u8,
    recurse: bool,
    results: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(global_io, dir_path, .{ .iterate = true });
    defer dir.close(global_io);
    var iter = dir.iterate();

    while (try iter.next(global_io)) |entry| {
        const full_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        var full_path_owned = true;
        defer if (full_path_owned) alloc.free(full_path);

        if (entry.kind == .directory and recurse) {
            try walkAndMatch(alloc, full_path, base_dir, pattern, project_root, recurse, results);
        }

        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;

        // Build path relative to base_dir for matching against sub_pattern
        const match_path = if (std.mem.startsWith(u8, dir_path, base_dir) and dir_path.len > base_dir.len)
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path[base_dir.len + 1 ..], entry.name })
        else
            try alloc.dupe(u8, entry.name);
        defer alloc.free(match_path);

        // Strip leading "./" from pattern for matching
        const clean_pattern = if (std.mem.startsWith(u8, pattern, "./"))
            pattern[2..]
        else
            pattern;

        if (!globMatch(clean_pattern, match_path)) continue;

        // Always exclude build.zap in the project root
        if (std.mem.eql(u8, std.fs.path.basename(full_path), "build.zap")) {
            const dir_of_file = std.fs.path.dirname(full_path) orelse ".";
            if (std.mem.eql(u8, dir_of_file, project_root)) continue;
        }

        // Avoid duplicates
        var dup = false;
        for (results.items) |existing| {
            if (std.mem.eql(u8, existing, full_path)) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            try results.append(alloc, full_path);
            full_path_owned = false;
        }
    }
}

test "globMatch basics" {
    // Exact match
    try std.testing.expect(globMatch("foo.zap", "foo.zap"));
    try std.testing.expect(!globMatch("foo.zap", "bar.zap"));

    // Single * matches filename chars but not /
    try std.testing.expect(globMatch("*.zap", "foo.zap"));
    try std.testing.expect(globMatch("*.zap", "bar.zap"));
    try std.testing.expect(!globMatch("*.zap", "lib/foo.zap"));

    // ** matches across directories
    try std.testing.expect(globMatch("**/*.zap", "foo.zap"));
    try std.testing.expect(globMatch("**/*.zap", "lib/foo.zap"));
    try std.testing.expect(globMatch("**/*.zap", "lib/sub/foo.zap"));

    // Prefixed glob
    try std.testing.expect(globMatch("lib/**/*.zap", "lib/foo.zap"));
    try std.testing.expect(globMatch("lib/**/*.zap", "lib/sub/foo.zap"));
    try std.testing.expect(!globMatch("lib/**/*.zap", "test/foo.zap"));

    // Specific file
    try std.testing.expect(globMatch("./hello.zap", "hello.zap"));
    try std.testing.expect(!globMatch("./hello.zap", "other.zap"));
}

test "globCollectFiles frees skipped paths during recursive collection" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "lib/nested");
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "build.zap", .data = "pub struct Build {}" });
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "lib/nested/target.zap", .data = "pub struct Target {}" });
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "lib/nested/other.zap", .data = "pub struct Other {}" });
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "lib/readme.txt", .data = "not zap" });

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(project_root);

    var results: std.ArrayListUnmanaged([]const u8) = .empty;
    defer deinitOwnedPathList(allocator, &results);

    try globCollectFiles(allocator, project_root, "lib/**/target.zap", &results);
    try globCollectFiles(allocator, project_root, "lib/**/target.zap", &results);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expect(std.mem.endsWith(u8, results.items[0], "lib/nested/target.zap"));
}

fn exerciseGlobCollectFilesAllocationFailures(
    allocator: std.mem.Allocator,
    project_root: []const u8,
) !void {
    var results: std.ArrayListUnmanaged([]const u8) = .empty;
    defer deinitOwnedPathList(allocator, &results);

    try globCollectFiles(allocator, project_root, "**/*.zap", &results);
}

test "globCollectFiles cleans owned paths on allocation failures" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(global_io, "lib/nested");
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "build.zap", .data = "pub struct Build {}" });
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "app.zap", .data = "pub struct App {}" });
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "lib/nested/dep.zap", .data = "pub struct Dep {}" });
    try tmp_dir.dir.writeFile(global_io, .{ .sub_path = "lib/nested/skip.txt", .data = "not zap" });

    const project_root = try tmp_dir.dir.realPathFileAlloc(global_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(project_root);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseGlobCollectFilesAllocationFailures,
        .{project_root},
    );
}

// ---------------------------------------------------------------------------
// String utilities
// ---------------------------------------------------------------------------

fn toSnakeCase(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    for (input) |c| {
        if (c == '-') {
            try result.append(allocator, '_');
        } else {
            try result.append(allocator, c);
        }
    }
    return try result.toOwnedSlice(allocator);
}

fn toPascalCase(allocator: std.mem.Allocator, snake: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var capitalize_next = true;
    for (snake) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else {
            if (capitalize_next and c >= 'a' and c <= 'z') {
                try result.append(allocator, c - 32);
            } else {
                try result.append(allocator, c);
            }
            capitalize_next = false;
        }
    }
    return try result.toOwnedSlice(allocator);
}

const EmbeddedZigLibError = error{
    EmbeddedZigLibArchiveUnavailable,
    EmbeddedZigLibCacheUnavailable,
    EmbeddedZigLibCacheAccessFailed,
    EmbeddedZigLibCacheDeleteFailed,
    EmbeddedZigLibCacheCreateFailed,
    EmbeddedZigLibCacheOpenFailed,
    EmbeddedZigLibArchiveDecompressFailed,
    EmbeddedZigLibArchiveExtractFailed,
    EmbeddedZigLibDigestWriteFailed,
    OutOfMemory,
};

const ZigLibDirResolutionError = EmbeddedZigLibError || zir_backend.ZigLibDirProbeError || error{
    ZigLibDirNotFound,
};

const ZigLibProbe = union(enum) {
    absent,
    found: []const u8,
    failed: zir_backend.ZigLibDirProbeError,
};

const EmbeddedZigLibProbe = union(enum) {
    absent,
    found: []const u8,
    failed: EmbeddedZigLibError,
};

fn isMissingEmbeddedZigLibCachePathError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.NotDir => true,
        else => false,
    };
}

fn embeddedZigLibErrorOrStatus(err: anyerror, status: EmbeddedZigLibError) EmbeddedZigLibError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => status,
    };
}

fn resolveZigLibDirFromCandidates(
    trusted_zig_lib: ZigLibProbe,
    embedded_zig_lib: EmbeddedZigLibProbe,
    system_zig_lib: ZigLibProbe,
) ZigLibDirResolutionError![]const u8 {
    switch (trusted_zig_lib) {
        .absent => {},
        .found => |zig_lib_dir| return zig_lib_dir,
        .failed => |err| return err,
    }
    switch (embedded_zig_lib) {
        .absent => {},
        .found => |zig_lib_dir| return zig_lib_dir,
        .failed => |err| return err,
    }
    switch (system_zig_lib) {
        .absent => {},
        .found => |zig_lib_dir| return zig_lib_dir,
        .failed => |err| return err,
    }
    return error.ZigLibDirNotFound;
}

fn resolveZigLibDir(allocator: std.mem.Allocator) ZigLibDirResolutionError![]const u8 {
    if (try zir_backend.detectZigLibDir(allocator)) |zig_lib_dir| return zig_lib_dir;
    if (try resolveEmbeddedZigLibDir(allocator)) |zig_lib_dir| return zig_lib_dir;
    if (try zir_backend.detectZigLibDirSystemFallback(allocator)) |zig_lib_dir| return zig_lib_dir;
    return error.ZigLibDirNotFound;
}

fn resolveEmbeddedZigLibDir(allocator: std.mem.Allocator) EmbeddedZigLibError!?[]const u8 {
    return resolveEmbeddedZigLibDirFromArchive(allocator, env.getenv("HOME"), zig_lib_archive.data);
}

fn resolveEmbeddedZigLibDirFromArchive(
    allocator: std.mem.Allocator,
    home: ?[]const u8,
    archive_data: []const u8,
) EmbeddedZigLibError!?[]const u8 {
    if (archive_data.len == 0) return null;
    return try extractEmbeddedZigLibFromArchive(allocator, home, archive_data);
}

fn extractEmbeddedZigLib(allocator: std.mem.Allocator) EmbeddedZigLibError![]const u8 {
    return extractEmbeddedZigLibFromArchive(allocator, env.getenv("HOME"), zig_lib_archive.data);
}

fn extractEmbeddedZigLibFromArchive(
    allocator: std.mem.Allocator,
    home: ?[]const u8,
    archive_data: []const u8,
) EmbeddedZigLibError![]const u8 {
    if (archive_data.len == 0) return error.EmbeddedZigLibArchiveUnavailable;
    const cache_home = home orelse return error.EmbeddedZigLibCacheUnavailable;

    const lib_dir = try std.fs.path.join(allocator, &.{ cache_home, ".cache", "zap", "zig-lib" });
    errdefer allocator.free(lib_dir);

    // Content-addressed staleness: the cache is valid only when it was
    // extracted from THIS compiler binary's embedded archive. Keying the
    // "already extracted" check on the mere PRESENCE of `std/std.zig` is a
    // bug — a cache left over from an older binary whose `zig_lib.tar` had
    // a different file set (notably one missing the `libc` tree, which made
    // every `*-linux-musl` cross-build fail with `crt1.c FileNotFound`)
    // would be reused forever, so a corrected bundle could never take
    // effect. Instead store a digest of the embedded archive in a marker
    // file and re-extract whenever it is absent or does not match.
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive_data, &digest, .{});
    var digest_hex: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&digest_hex, "{x}", .{&digest}) catch unreachable;

    const digest_marker = try std.fs.path.join(allocator, &.{ lib_dir, ".zap_bundle_digest" });
    defer allocator.free(digest_marker);
    const std_marker = try std.fs.path.join(allocator, &.{ lib_dir, "std", "std.zig" });
    defer allocator.free(std_marker);

    // Fast path: the std tree is present AND the digest marker matches this
    // binary's embedded archive — the cache is current, reuse it as-is.
    if (std.Io.Dir.cwd().access(global_io, std_marker, .{})) |_| {
        if (std.Io.Dir.cwd().readFileAlloc(global_io, digest_marker, allocator, .limited(256))) |existing| {
            defer allocator.free(existing);
            if (std.mem.eql(u8, std.mem.trim(u8, existing, " \n\r\t"), &digest_hex)) {
                return lib_dir;
            }
        } else |err| {
            if (!isMissingEmbeddedZigLibCachePathError(err)) {
                return embeddedZigLibErrorOrStatus(err, error.EmbeddedZigLibCacheAccessFailed);
            }
        }
    } else |err| {
        if (!isMissingEmbeddedZigLibCachePathError(err)) {
            return embeddedZigLibErrorOrStatus(err, error.EmbeddedZigLibCacheAccessFailed);
        }
    }

    // Stale or absent: wipe any prior extraction so files removed from the
    // archive do not linger, then extract this binary's archive fresh. The
    // cache is fully regenerable, so deleting it is safe.
    std.Io.Dir.cwd().deleteTree(global_io, lib_dir) catch |err| {
        if (!isMissingEmbeddedZigLibCachePathError(err)) {
            return embeddedZigLibErrorOrStatus(err, error.EmbeddedZigLibCacheDeleteFailed);
        }
    };
    std.Io.Dir.cwd().createDirPath(global_io, lib_dir) catch |err| {
        return embeddedZigLibErrorOrStatus(err, error.EmbeddedZigLibCacheCreateFailed);
    };

    var dir = std.Io.Dir.cwd().openDir(global_io, lib_dir, .{}) catch |err| {
        return embeddedZigLibErrorOrStatus(err, error.EmbeddedZigLibCacheOpenFailed);
    };
    defer dir.close(global_io);

    // The embedded archive (`zig_lib_archive.data`) is XZ-compressed at build
    // time (`build.zig`) to keep the `zap` binary small — the bundled std/c/
    // libc trees are header-heavy text that compresses ~9:1. Decompress it on
    // the fly and feed the *decompressed* byte stream into `std.tar.extract`,
    // so the full, unmodified file set lands on disk exactly as before. The
    // reader chain is:
    //
    //   fixed(compressed bytes) -> xz.Decompress -> tar.extract
    //
    // After successful init, `xz.Decompress` owns `decompress_buffer` and grows
    // it with `allocator` as LZMA2 dictionaries require (XZ blocks declare
    // their own dictionary size); `decompress.deinit()` frees it. On init
    // failure, ownership remains here and the catch path frees it. The
    // decompressed `std.Io.Reader` is exposed as `decompress.reader`. NB:
    // `xz.Decompress` resolves its parent via `@fieldParentPtr("reader", ...)`,
    // so the `decompress` value must not be moved after `init` — keep it in
    // this stable local and pass `&decompress.reader` to the extractor.
    var compressed_reader = std.Io.Reader.fixed(archive_data);
    const decompress_buffer = allocator.alloc(u8, 64 * 1024) catch return error.OutOfMemory;
    var decompress = std.compress.xz.Decompress.init(&compressed_reader, allocator, decompress_buffer) catch |err| {
        allocator.free(decompress_buffer);
        return embeddedZigLibErrorOrStatus(err, error.EmbeddedZigLibArchiveDecompressFailed);
    };
    defer decompress.deinit();
    std.tar.extract(global_io, dir, &decompress.reader, .{}) catch |err| {
        return embeddedZigLibErrorOrStatus(err, error.EmbeddedZigLibArchiveExtractFailed);
    };

    // Stamp the digest marker last so a crash mid-extract leaves an
    // unmarked (therefore stale-on-next-run) tree rather than a marked
    // partial one.
    writeFile(digest_marker, &digest_hex) catch |err| {
        return embeddedZigLibErrorOrStatus(err, error.EmbeddedZigLibDigestWriteFailed);
    };

    return lib_dir;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const io = global_io;
    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.debug.print("Error writing {s}: {}\n", .{ path, err });
        return err;
    };
    defer file.close(global_io);
    file.writeStreamingAll(io, content) catch |err| {
        std.debug.print("Error writing {s}: {}\n", .{ path, err });
        return err;
    };
}
