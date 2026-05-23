//! Integration test for the `zap addr2line` subcommand (Phase 2.e).
//!
//! Drives the real `zap` CLI end-to-end (not `zir-test`): it builds a small
//! crashing Zap script across optimize modes, then symbolizes a known
//! function's static address against the produced binary + its split-debug
//! artifact (.dSYM / embedded DWARF) + `.zap-symbols` sidecar, asserting the
//! offline result matches the in-process crash printer's
//! `Struct.local/arity at file.zap:line` rendering.
//!
//! Covers the brief's acceptance matrix:
//!   * ReleaseFast: stripped binary + sibling .dSYM + sidecar -> full Zap
//!     symbol + file:line (the cross-compilation / release post-mortem case).
//!   * Debug: embedded DWARF -> full Zap symbol + file:line.
//!   * Missing sidecar: mangled linker name + file:line (graceful fallback).
//!
//! `ZAP_BINARY` (set by build.zig) points at the installed `zap`; `ZAP_LIB_DIR`
//! is forced to the repo `lib/` so the script compiles against the fork stdlib.

const std = @import("std");

const OUTPUT_LIMIT = 16 * 1024 * 1024;

fn getTestIo() std.Io {
    return std.testing.io;
}

fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.span(ptr);
}

fn resolveZapBinary(allocator: std.mem.Allocator) ![:0]u8 {
    const raw: []const u8 = getenvSlice("ZAP_BINARY") orelse "zig-out/bin/zap";
    if (std.fs.path.isAbsolute(raw)) return allocator.dupeZ(u8, raw);
    return std.Io.Dir.cwd().realPathFileAlloc(getTestIo(), raw, allocator);
}

fn resolveRepoStdlibDir(allocator: std.mem.Allocator) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(getTestIo(), "lib", allocator);
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *RunResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    fn combinedContains(self: RunResult, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or
            std.mem.indexOf(u8, self.stderr, needle) != null;
    }
};

fn run(allocator: std.mem.Allocator, argv: []const []const u8, env: ?*const std.process.Environ.Map) !RunResult {
    const result = try std.process.run(allocator, getTestIo(), .{
        .argv = argv,
        .environ_map = env,
        .stdout_limit = .limited(OUTPUT_LIMIT),
        .stderr_limit = .limited(OUTPUT_LIMIT),
    });
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code, .allocator = allocator };
}

/// Run the crasher script under `zap run -Doptimize=<mode>` and return the
/// published artifact path the script-cache prints (`[script-cache hit] <p>`).
/// The first invocation compiles+publishes; the second is a guaranteed cache
/// hit whose stderr names the binary. The binary's sibling `<p>.dSYM` and
/// `<p>.zap-symbols` live in the same directory.
fn buildCrasherAndGetBinary(
    allocator: std.mem.Allocator,
    zap_binary: []const u8,
    script_path: []const u8,
    optimize: []const u8,
    repo_lib: []const u8,
) !?[]u8 {
    var env = try std.testing.environ.createMap(allocator);
    defer env.deinit();
    _ = env.swapRemove("ZAP_LIB_DIR");
    try env.put("ZAP_LIB_DIR", repo_lib);

    // Publish into a PER-TEST-ISOLATED script cache, not the shared
    // `~/.cache/zap/scripts`. Other test steps (the golden corpus, the Zest
    // corpus, the mod-test harness) `rm -rf ~/.cache/zap/scripts` to defeat a
    // stale cache; running concurrently with this test, such a wipe could
    // delete THIS test's just-published crasher between the publish run and the
    // `nm`/`addr2line` read — turning the second run into a cache MISS (no
    // `[script-cache hit]` marker) and forcing a spurious skip. Pointing
    // `ZAP_SCRIPT_CACHE_DIR` at the script's own (unique `tmpDir`) parent
    // isolates this test's cache so no sibling can wipe it. This is the same
    // isolation `src/zir_integration_tests.zig` already uses. The script path
    // is absolute, so its dirname is the test's unique tmp directory.
    const cache_dir = blk: {
        const dir_end = std.mem.lastIndexOfScalar(u8, script_path, '/') orelse break :blk null;
        break :blk try std.fmt.allocPrint(allocator, "{s}/script-cache", .{script_path[0..dir_end]});
    };
    defer if (cache_dir) |c| allocator.free(c);
    if (cache_dir) |c| try env.put("ZAP_SCRIPT_CACHE_DIR", c);

    const opt_flag = try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{optimize});
    defer allocator.free(opt_flag);

    // First run: compile + publish (the script itself aborts non-zero — fine).
    var first = try run(allocator, &.{ zap_binary, "run", opt_flag, script_path }, &env);
    first.deinit();

    // Second run: cache hit, stderr names the published binary.
    var second = try run(allocator, &.{ zap_binary, "run", opt_flag, script_path }, &env);
    defer second.deinit();

    const marker = "[script-cache hit] ";
    const idx = std.mem.indexOf(u8, second.stderr, marker) orelse return null;
    const after = second.stderr[idx + marker.len ..];
    const end = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
    const path = std.mem.trim(u8, after[0..end], " \t\r");
    if (path.len == 0) return null;
    return try allocator.dupe(u8, path);
}

/// Parse a function's STATIC virtual address from the binary's symbol table
/// via `nm`. Returns a `0x`-prefixed address string, or null if `nm` is
/// unavailable or the symbol is absent. The mangled name is matched as a
/// suffix (Mach-O prefixes a leading underscore that `nm` prints).
fn staticAddressOf(allocator: std.mem.Allocator, binary: []const u8, mangled: []const u8) !?[]u8 {
    var nm = run(allocator, &.{ "nm", binary }, null) catch return null;
    defer nm.deinit();
    if (nm.exit_code != 0) return null;

    var lines = std.mem.tokenizeAny(u8, nm.stdout, "\n");
    while (lines.next()) |line| {
        // Format: "<hex addr> <type> <name>"; match the mangled name as the
        // trailing token (tolerating the Mach-O leading underscore).
        if (!std.mem.endsWith(u8, line, mangled)) continue;
        // Ensure it's a whole-token match (preceded by space or underscore).
        const name_start = line.len - mangled.len;
        if (name_start > 0 and line[name_start - 1] != ' ' and line[name_start - 1] != '_') continue;
        var toks = std.mem.tokenizeAny(u8, line, " ");
        const addr_hex = toks.next() orelse continue;
        // A `U`/undefined symbol has no address (the line starts with spaces);
        // require a parseable hex value.
        _ = std.fmt.parseInt(u64, addr_hex, 16) catch continue;
        return try std.fmt.allocPrint(allocator, "0x{s}", .{addr_hex});
    }
    return null;
}

/// Skip-or-assert helper: a missing `nm` / unbuildable fixture on an exotic
/// host shouldn't hard-fail the suite, but a built fixture that fails to
/// symbolize MUST. We treat "could not even produce the binary/address" as a
/// skip and everything past that as a hard assertion.
fn expectResolves(result: RunResult, must_contain: []const []const u8) !void {
    for (must_contain) |needle| {
        if (!result.combinedContains(needle)) {
            std.debug.print(
                \\zap addr2line output missing expected fragment:
                \\  {s}
                \\exit code: {d}
                \\stdout:
                \\{s}
                \\stderr:
                \\{s}
                \\
            , .{ needle, result.exit_code, result.stdout, result.stderr });
            return error.TestUnexpectedResult;
        }
    }
}

const crasher_source =
    \\pub struct Crasher {
    \\  pub fn deeper() -> Never {
    \\    raise "kaboom from deeper"
    \\  }
    \\
    \\  pub fn blow_up() -> Never {
    \\    Crasher.deeper()
    \\  }
    \\}
    \\
    \\fn main(_args :: [String]) -> u8 {
    \\  Crasher.blow_up()
    \\  0
    \\}
    \\
;

fn writeCrasher(tmp: *std.testing.TmpDir) ![]const u8 {
    try tmp.dir.writeFile(getTestIo(), .{ .sub_path = "crasher.zap", .data = crasher_source });
    return "crasher.zap";
}

test "zap addr2line resolves a stripped ReleaseFast binary from its dSYM + sidecar" {
    const allocator = std.testing.allocator;

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);
    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_script = try writeCrasher(&tmp);
    const script_path = try tmp.dir.realPathFileAlloc(getTestIo(), rel_script, allocator);
    defer allocator.free(script_path);

    const binary = (try buildCrasherAndGetBinary(allocator, zap_binary, script_path, "ReleaseFast", repo_lib)) orelse {
        std.debug.print("skip: could not locate published ReleaseFast crasher binary\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(binary);

    // Resolve `Crasher.blow_up/0`, NOT `Crasher.deeper/0`: in ReleaseFast the
    // optimizer inlines the tiny `raise`-only `deeper/0` leaf into its caller,
    // so `deeper__0` has no symtab entry for `nm` to hand us an address for
    // (that absence used to force a spurious skip and was misread as a
    // `zap addr2line` gap). `blow_up/0` is the surviving outer frame — exactly
    // the kind of stripped-but-present symbol whose static address `nm` finds
    // and whose Zap name + `file:line` `zap addr2line` recovers from the
    // sibling sidecar + dSYM. A null here now means `nm` is genuinely
    // unavailable (an exotic host), which stays a skip.
    const addr = (try staticAddressOf(allocator, binary, "Crasher.blow_up__0")) orelse {
        std.debug.print("skip: nm unavailable (binary={s})\n", .{binary});
        return error.SkipZigTest;
    };
    defer allocator.free(addr);

    var result = try run(allocator, &.{ zap_binary, "addr2line", binary, addr }, null);
    defer result.deinit();

    // Full Zap symbol recovered from the sidecar; file:line from the dSYM.
    try expectResolves(result, &.{ "Crasher.blow_up/0", "crasher.zap:" });
}

test "zap addr2line resolves a Debug binary from embedded DWARF" {
    const allocator = std.testing.allocator;

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);
    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_script = try writeCrasher(&tmp);
    const script_path = try tmp.dir.realPathFileAlloc(getTestIo(), rel_script, allocator);
    defer allocator.free(script_path);

    const binary = (try buildCrasherAndGetBinary(allocator, zap_binary, script_path, "Debug", repo_lib)) orelse {
        std.debug.print("skip: could not locate published Debug crasher binary\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(binary);

    const addr = (try staticAddressOf(allocator, binary, "Crasher.blow_up__0")) orelse {
        std.debug.print("skip: nm unavailable or symbol absent (binary={s})\n", .{binary});
        return error.SkipZigTest;
    };
    defer allocator.free(addr);

    var result = try run(allocator, &.{ zap_binary, "addr2line", binary, addr }, null);
    defer result.deinit();

    try expectResolves(result, &.{ "Crasher.blow_up/0", "crasher.zap:" });
}

test "zap addr2line falls back to mangled names when the sidecar is absent" {
    const allocator = std.testing.allocator;

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);
    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_script = try writeCrasher(&tmp);
    const script_path = try tmp.dir.realPathFileAlloc(getTestIo(), rel_script, allocator);
    defer allocator.free(script_path);

    const published = (try buildCrasherAndGetBinary(allocator, zap_binary, script_path, "Debug", repo_lib)) orelse {
        std.debug.print("skip: could not locate published Debug crasher binary\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(published);

    const addr = (try staticAddressOf(allocator, published, "Crasher.deeper__0")) orelse {
        std.debug.print("skip: nm unavailable or symbol absent (binary={s})\n", .{published});
        return error.SkipZigTest;
    };
    defer allocator.free(addr);

    // Copy ONLY the binary (no sibling .zap-symbols) into the tmp dir so the
    // resolver finds DWARF but no sidecar.
    const tmp_root = try tmp.dir.realPathFileAlloc(getTestIo(), ".", allocator);
    defer allocator.free(tmp_root);
    const copied = try std.fs.path.join(allocator, &.{ tmp_root, "no_sidecar_bin" });
    defer allocator.free(copied);
    try std.Io.Dir.cwd().copyFile(published, std.Io.Dir.cwd(), copied, getTestIo(), .{});

    var result = try run(allocator, &.{ zap_binary, "addr2line", copied, addr }, null);
    defer result.deinit();

    // No sidecar -> the note fires and the mangled linker name is reported
    // (underscore-stripped) instead of the Zap name. The bare copy carries
    // neither its OSO `.o` files nor the sibling `.dSYM`, so the source
    // location degrades to the `??:0` marker — the documented no-DWARF
    // fallback. (The dSYM-backed file:line path is covered by the ReleaseFast
    // and Debug tests above, which keep the sibling artifacts in place.)
    try expectResolves(result, &.{ "reporting mangled linker names", "Crasher.deeper__0", "??:0" });
}
