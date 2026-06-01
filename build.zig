const std = @import("std");
const builtin = @import("builtin");

// Pre-built dependency version — update when releasing new zap-deps
const zap_deps_version = "v0.16.0-zap.1";
const zap_deps_base_url = "https://github.com/DockYard/zig/releases/download/" ++ zap_deps_version;
const host_triple = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi);
const default_deps_dir_relative = "zap-deps/" ++ host_triple;
const default_zig_fork_root_relative = "../zig";
const default_zig_bootstrap_llvm_lib_path_relative = "../zig-bootstrap/out/host/lib";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // Map workload instrumentation flag
    //
    // When set true, the runtime compiles in HAMT Map(K,V) instrumentation
    // hooks: per-instance lifetime records, lineage tracking, and a JSON
    // exit handler that emits aggregate workload statistics. When false
    // (the default), every hook is comptime-eliminated and the runtime is
    // bit-identical to the unflagged build. See
    // `docs/map-workload-instrumentation-plan.md`.
    // -----------------------------------------------------------------------
    const instrument_map = b.option(
        bool,
        "instrument-map",
        "Compile in Map(K,V) workload instrumentation (default false)",
    ) orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "instrument_map", instrument_map);

    // ----------------------------------------------------------------
    // `zap_active_manager` stub for the host test build
    //
    // `runtime.zig` declares `const active_manager = @import("zap_active_manager");`
    // at top level so every Zap user binary resolves the active
    // manager's Zig source as a sibling module. The host `zig build
    // test` flow loads `runtime.zig` as part of the `zap` Zig module
    // (no user-binary build pipeline involved), so it needs the same
    // import to resolve cleanly here — Zig 0.16 does NOT elide
    // top-level `@import` decls during semantic analysis even when
    // the bound name is unused.
    //
    // The host test build keeps the runtime's source-level
    // `active_manager_source_available == false` marker, so runtime hot
    // paths bind the test-only ARC fallback state and do not call into
    // this import. Production user binaries instead register the selected
    // adapter's package `src/.../manager.zig` backend through
    // `zir_compilation_add_struct`;
    // see `src/zir_backend.zig:createContext`.
    // ----------------------------------------------------------------

    // Library import unit — no native deps needed
    const mod = b.addModule("zap", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addOptions("build_options", build_options);
    mod.addAnonymousImport("zap_active_manager", .{
        .root_source_file = b.path("src/zap_active_manager_stub.zig"),
    });
    // -----------------------------------------------------------------------
    // Setup step: download pre-built deps
    // -----------------------------------------------------------------------
    const setup_step = b.step("setup", "Download pre-built LLVM dependencies for " ++ host_triple);
    const setup_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        "set -e && " ++
            "echo 'Downloading zap-deps for " ++ host_triple ++ "...' && " ++
            "curl -L -o zap-deps-" ++ host_triple ++ ".tar.xz " ++
            zap_deps_base_url ++ "/zap-deps-" ++ host_triple ++ ".tar.xz && " ++
            "mkdir -p zap-deps && " ++
            "tar xJf zap-deps-" ++ host_triple ++ ".tar.xz -C zap-deps && " ++
            "rm zap-deps-" ++ host_triple ++ ".tar.xz && " ++
            "echo 'Done! Build the sibling Zig fork, then run: zig build'",
    });
    setup_step.dependOn(&setup_cmd.step);

    // -----------------------------------------------------------------------
    // Test steps (no native deps needed)
    // -----------------------------------------------------------------------
    // Optional name substring filter for the primary module test binary,
    // forwarded to Zig's test runner. Pass `-Dtest-filter=<substring>` to
    // run only matching tests (e.g. iterating on one feature) without
    // recompiling the whole suite every run. Absent (the default), every
    // test runs.
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose name contains this substring");
    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const boundary_guard_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/boundary_guard_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_boundary_guard_tests = b.addRunArtifact(boundary_guard_tests);
    test_step.dependOn(&run_boundary_guard_tests.step);

    // Cross-check that the byte-keyed slab pool's layout constants in
    // `src/runtime.zig`'s `TestOnlyArcSlabPool` block agree byte-for-
    // byte with the production manager (`src/memory/arc/manager.zig`).
    // Phase 4.x duplicated the pool implementation because the
    // manager (compiled by `zap_fork_compile_zig_to_object` as a
    // standalone object) cannot share Zig modules with the runtime —
    // this test fails the build when either side drifts unilaterally.
    const slab_pool_drift_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/slab_pool_drift_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_slab_pool_drift_tests = b.addRunArtifact(slab_pool_drift_tests);
    test_step.dependOn(&run_slab_pool_drift_tests.step);

    // Phase 2.a crash reporter: the `.zap-symbols` sidecar format and the
    // `ZapSymbolInfo` C-ABI are declared in three files that cannot import
    // one another (`src/zap_symbol_table.zig`, `src/runtime.zig`, and the
    // fork's `src/zir_api.zig`). This test reads all three as text and fails
    // the build if the load-bearing format constants or the C-ABI field
    // order drift apart.
    const zap_symbol_abi_drift_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zap_symbol_abi_drift_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_zap_symbol_abi_drift_tests = b.addRunArtifact(zap_symbol_abi_drift_tests);
    test_step.dependOn(&run_zap_symbol_abi_drift_tests.step);

    // Phase 4.a unified diagnostics: the shared visual-format spec
    // (`src/error_format.zig`) and its runtime mirror (`RuntimeFormat` in
    // `src/runtime.zig`) cannot share a Zig `@import` (runtime.zig is injected
    // standalone). This test reads both as text and fails the build if any
    // mirrored format constant, SGR escape, or the security-tier fold drifts,
    // so the compile renderer and the async-signal-safe crash printer keep one
    // visual language.
    const error_format_drift_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/error_format_drift_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_error_format_drift_tests = b.addRunArtifact(error_format_drift_tests);
    test_step.dependOn(&run_error_format_drift_tests.step);

    // -----------------------------------------------------------------------
    // runtime_os seam backends. The three `src/runtime_os/*.zig` files are
    // real, separately-compilable Zig — they are `@embedFile`'d into the
    // compiler and their bodies spliced into the embedded runtime by
    // `compiler.zig`'s `rewriteRuntimeSource`, but they must also stand
    // alone so each backend type-checks against its own target's std.
    //
    //   * posix.zig  — type-checked AND its `test {}` blocks run natively
    //     (the native regression anchor is the host target here).
    //   * wasi.zig   — compile-only check for `wasm32-wasi` (the host can
    //     type-check the wasm target but cannot run the artifact).
    //   * windows.zig — compile-only check for `x86_64-windows-gnu`.
    //
    // A drift between a backend body and the splice markers, or a std-API
    // break for any target, fails `zig build test` here rather than only
    // surfacing at a cross-compile attempt.
    const runtime_os_posix_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime_os/posix.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_runtime_os_posix_tests = b.addRunArtifact(runtime_os_posix_tests);
    test_step.dependOn(&run_runtime_os_posix_tests.step);

    const runtime_os_wasi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime_os/wasi.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi }),
            .optimize = optimize,
        }),
    });
    // Cross-target: depend on the compile (type-check) only, never the run.
    test_step.dependOn(&runtime_os_wasi_tests.step);

    const runtime_os_windows_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime_os/windows.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
                .abi = .gnu,
            }),
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_step.dependOn(&runtime_os_windows_tests.step);

    // Runtime OS-portability grep-gate (campaign lock-in). Scans the
    // embedded `src/runtime.zig` and FAILS the build if a raw `std.c.` /
    // `std.posix.` / `std.os.` call appears OUTSIDE the allowlisted regions
    // (the `runtime_os` seam, the Domain-B crash region, `test {}` blocks,
    // the `builtin.is_test` slab-pool scaffold, and a short enumerated list
    // of comptime irreducibles). A new raw per-OS call added to the general
    // runtime body — which would ship into every Zap user binary on every
    // target — fails here in the normal `zig build test` gate with a precise
    // `runtime.zig:<line>` message. It is a native test (it reads source
    // bytes via `@embedFile`; the host target is fine).
    const runtime_os_portability_gate = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime_os_portability_gate.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_runtime_os_portability_gate = b.addRunArtifact(runtime_os_portability_gate);
    test_step.dependOn(&run_runtime_os_portability_gate.step);

    // -----------------------------------------------------------------------
    // Dependency paths
    // -----------------------------------------------------------------------
    const user_lib = b.option([]const u8, "zap-compiler-lib", "Path to libzap_compiler.a");
    const user_llvm = b.option([]const u8, "llvm-lib-path", "Path to LLVM library directory with native .a files");
    const default_zig_fork_root = b.pathFromRoot(default_zig_fork_root_relative);
    const default_zig_bootstrap_llvm_lib_path = b.pathFromRoot(default_zig_bootstrap_llvm_lib_path_relative);
    const default_deps_dir = b.pathFromRoot(default_deps_dir_relative);
    const default_deps_llvm_lib_path = b.pathJoin(&.{ default_deps_dir, "llvm-libs" });
    const zig_fork_root = b.option([]const u8, "zig-fork-root", "Path to Zap's Zig fork root") orelse default_zig_fork_root;

    const local_zig_compiler_lib_path = b.fmt("{s}/zig-out/lib/libzap_compiler.a", .{zig_fork_root});
    const zig_compiler_lib_path = user_lib orelse local_zig_compiler_lib_path;
    const llvm_lib_path: ?[]const u8 = user_llvm orelse blk: {
        if (pathExists(b, default_zig_bootstrap_llvm_lib_path)) {
            break :blk default_zig_bootstrap_llvm_lib_path;
        }
        break :blk default_deps_llvm_lib_path;
    };

    if (!pathExists(b, zig_compiler_lib_path)) {
        const fail = b.addSystemCommand(&.{
            "sh", "-c",
            b.fmt(
                "printf '\\n" ++
                    "Error: Zap requires libzap_compiler.a from the local Zig fork.\\n" ++
                    "\\n" ++
                    "Expected:\\n" ++
                    "  {s}\\n" ++
                    "\\n" ++
                    "Build it with:\\n" ++
                    "  cd {s} && zig build lib --search-prefix ../zig-bootstrap/out/host --search-prefix /opt/homebrew -Dstatic-llvm -Doptimize=ReleaseSafe -Dversion-string=0.16.0\\n" ++
                    "\\n" ++
                    "Or pass an explicit archive with:\\n" ++
                    "  zig build -Dzap-compiler-lib=/path/to/libzap_compiler.a\\n" ++
                    "\\n' >&2 && exit 1",
                .{ zig_compiler_lib_path, zig_fork_root },
            ),
        });
        b.getInstallStep().dependOn(&fail.step);
        test_step.dependOn(&fail.step);
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&fail.step);
        const zir_test_step = b.step("zir-test", "Run ZIR integration tests");
        zir_test_step.dependOn(&fail.step);
        return;
    }

    if (llvm_lib_path) |selected_llvm_lib_path| {
        if (!pathExists(b, selected_llvm_lib_path)) {
            const fail = b.addSystemCommand(&.{
                "sh", "-c",
                b.fmt(
                    "printf '\\n" ++
                        "Error: LLVM static library directory not found.\\n" ++
                        "\\n" ++
                        "Expected:\\n" ++
                        "  {s}\\n" ++
                        "\\n" ++
                        "Run `zig build setup` to install vendored LLVM libraries or pass:\\n" ++
                        "  -Dllvm-lib-path=/path/to/llvm/lib\\n" ++
                        "\\n' >&2 && exit 1",
                    .{selected_llvm_lib_path},
                ),
            });
            b.getInstallStep().dependOn(&fail.step);
            test_step.dependOn(&fail.step);
            const run_step = b.step("run", "Run the app");
            run_step.dependOn(&fail.step);
            const zir_test_step = b.step("zir-test", "Run ZIR integration tests");
            zir_test_step.dependOn(&fail.step);
            return;
        }
    }

    // -----------------------------------------------------------------------
    // Zig stdlib embedding
    // -----------------------------------------------------------------------
    // The embedded stdlib MUST be the Zap fork's `lib/`, not whatever Zig
    // happens to be building Zap. The fork carries stdlib changes the runtime
    // depends on (e.g. the `std.debug.MachOFile` dSYM fallback + linkage-name
    // reporting that let the Phase 2 crash reporter resolve `zap run`
    // backtraces to Zap source); an upstream/system Zig stdlib lacks them.
    // The fork root is already resolved above (from `-Dzig-fork-root`, the
    // `-Dzap-compiler-lib` tree, or the `../zig` default), so its sibling
    // `lib/` is the authoritative stdlib that matches `libzap_compiler.a`.
    // Fall back to the building Zig's lib only when the fork tree is absent
    // (e.g. a CI job handed a prebuilt archive without the fork checkout).
    const fork_zig_lib_dir = b.fmt("{s}/lib", .{zig_fork_root});
    const zig_lib_dir = b.option([]const u8, "zig-lib-dir", "Path to Zig lib directory (contains std/)") orelse
        (if (pathExists(b, b.pathJoin(&.{ fork_zig_lib_dir, "std", "std.zig" })))
            fork_zig_lib_dir
        else
            detectBuildZigLibDir(b));

    // Phase 2.f GP3 — the `zap` exe (and the CLI/addr2line test binaries that
    // exercise the same code) MUST be COMPILED against the fork's `std`, not
    // whatever Zig happens to be building Zap. `zap addr2line` and any
    // `std.debug`-using CLI path link the *building* Zig's `std` by default,
    // which lacks the fork's `std.debug.MachOFile` sibling-dSYM fallback +
    // linkage-name reporting — so a stripped-binary symbolization round-trip
    // only worked when `--zig-lib-dir ~/projects/zig/lib` was passed by hand.
    // Threading the fork lib dir as the compile-time `zig_lib_dir` makes the
    // installed `zap` binary carry the fix unconditionally. This is the same
    // tree already embedded for *user* binaries (Phase 2.a); GP3 extends it to
    // the `zap` exe's own `std`. Null when the fork tree is absent (CI prebuilt
    // archive without the fork checkout) — then the building Zig's std is used.
    const fork_zig_lib_dir_lazy: ?std.Build.LazyPath =
        if (pathExists(b, b.pathJoin(&.{ zig_lib_dir, "std", "std.zig" })))
            .{ .cwd_relative = zig_lib_dir }
        else
            null;

    const tar_step = b.addSystemCommand(&.{ "tar", "-cf" });
    const tar_output = tar_step.addOutputFileArg("zig_lib.tar");
    tar_step.addArg("-C");
    tar_step.addArg(zig_lib_dir);
    // Include every top-level compiler-runtime entry a user binary may link:
    // `compiler_rt.zig`, `ubsan_rt.zig` (the UBSan runtime, linked into Debug
    // and ReleaseSafe builds), `fuzzer.zig`, and `c.zig`, plus the `std`/`c`/
    // `compiler_rt` trees. Omitting `ubsan_rt.zig`/`fuzzer.zig` only worked
    // while resolution fell back to a full system Zig lib dir; now that the
    // embedded fork stdlib is authoritative it must be self-contained.
    //
    // `libc` is REQUIRED for cross-compilation to libc targets: a
    // `-Dtarget=<arch>-linux-musl` build sub-compiles musl's `crt1.o` and
    // `libc.a` from the bundled `libc/musl/**` sources against the bundled
    // `libc/include/**` headers (and `libc/glibc/**`, `libc/mingw/**`, etc.
    // for the other libc targets Zig supports). Without it the embedded
    // archive extracts a `libc`-less zig-lib and every libc cross-build
    // fails with `libc/musl/crt/crt1.c file_hash FileNotFound`. The bundle
    // claims to be authoritative/self-contained, so it must carry `libc`
    // exactly as a full Zig lib dir does — there is no system-libc fallback
    // for a foreign target.
    //
    // `include` is the compiler-provided C header set (`lib/include/**`:
    // `float.h`, `stddef.h`, `stdarg.h`, `x86intrin.h`, …). It is REQUIRED
    // whenever a libc cross-build sub-compiles C *source* that pulls in a
    // compiler-provided header. MinGW (the `*-windows-gnu` ABI) is the
    // sharp edge: Zig builds the mingw CRT (`crtexe.c`, `tlssup.c`,
    // `pesect.c`, …) from `libc/mingw/**`, and those translation units
    // `#include <float.h>` / `<x86intrin.h>` (via `windows.h` → `winnt.h`),
    // which resolve to `lib/include/`, NOT `lib/libc/include/`. With
    // `include` omitted the Windows final link dies with
    // `'x86intrin.h' file not found` / `'float.h' file not found` while
    // compiling the CRT. (Linux musl/glibc CRT objects do not reach these
    // headers, which is why the gap was invisible until the Windows
    // target.) A self-contained zig-lib must carry `include` exactly as a
    // full Zig lib dir does.
    tar_step.addArgs(&.{ "std", "compiler_rt", "compiler_rt.zig", "ubsan_rt.zig", "fuzzer.zig", "c.zig", "c", "libc", "include" });

    // The uncompressed `zig_lib.tar` above is ~244M (the bundled `std` + `c` +
    // `libc` trees are overwhelmingly header/source TEXT, which compresses
    // ~9:1). Embedding it verbatim via `@embedFile` pushes the `zap` binary to
    // ~466M. We therefore XZ-compress the tar at build time and decompress it
    // on extraction (`extractEmbeddedZigLib` in `src/main.zig`). This changes
    // ONLY the archive's *encoding* — the full, unmodified file set above is
    // still present byte-for-byte after decompression, so cross-compiling to
    // every libc target Zig supports (musl, glibc, MinGW/Windows, WASI, the
    // BSDs, every arch) keeps working. We do not strip, subset, or reorder any
    // part of the bundle; we only shrink the stored bytes.
    //
    // XZ is chosen over gzip/zstd because (a) it gives the best ratio on this
    // header-heavy text (~9:1 vs gzip's ~3-4:1), (b) the `xz` toolchain is
    // already proven in this build env (the `zap-deps-*.tar.xz` archives are
    // fetched and extracted with `tar xJf` elsewhere in this file), and (c) the
    // fork's `std.compress.xz.Decompress` round-trips the real archive. The
    // tar arg list above is kept as a plain `tar -cf` (no `-J`) so the
    // *contents* of the bundle are independent of the compressor; a dedicated
    // `xz` Run step performs the compression and its stdout is captured as the
    // embedded `zig_lib.tar.xz`. `--threads=0` parallelizes compression across
    // all cores (build-time only); `-9 --extreme` maximizes the ratio since the
    // archive is compressed exactly once per build but shipped in every binary
    // (this brings the embedded archive from ~244M down to ~25M). NB: the
    // multi-threaded encoder emits a multi-block XZ stream, which the fork's
    // `std.compress.xz.Decompress` decodes block-by-block — verified to
    // round-trip the real archive byte-for-byte on extraction.
    const xz_step = b.addSystemCommand(&.{ "xz", "--compress", "--stdout", "--threads=0", "-9", "--extreme" });
    xz_step.addFileArg(tar_output);
    const xz_output = xz_step.captureStdOut(.{ .basename = "zig_lib.tar.xz" });

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(xz_output, "zig_lib.tar.xz");
    const wrapper_source = wf.add("zig_lib_archive.zig",
        \\pub const data = @embedFile("zig_lib.tar.xz");
        \\
    );

    // -----------------------------------------------------------------------
    // Executable
    // -----------------------------------------------------------------------
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zap", .module = mod },
        },
    });
    exe_module.addOptions("build_options", build_options);
    const exe = b.addExecutable(.{
        .name = "zap",
        .root_module = exe_module,
        // GP3: compile the `zap` exe's own `std` from the fork lib dir so the
        // installed binary's `std.debug` carries the dSYM fallback fix.
        .zig_lib_dir = fork_zig_lib_dir_lazy,
    });

    exe.root_module.addAnonymousImport("zig_lib_archive", .{
        .root_source_file = wrapper_source,
    });

    applyNativeCompilerLinkage(exe.root_module, llvm_lib_path, zig_compiler_lib_path);

    // -----------------------------------------------------------------------
    // CLI unit tests (`src/main.zig`)
    //
    // `mod_tests` only covers `src/root.zig`'s module graph; the CLI
    // entry point (`src/main.zig`) is a separate executable root and was
    // therefore never test-compiled by `zig build test`. The CLI's
    // argument parsing and the Zap stdlib resolver live here, so the
    // unit tests in `src/main.zig` must run as part of the standard test
    // step. This target mirrors `exe_module` exactly — same `zap`
    // import, `build_options`, embedded Zig-lib archive, and native
    // compiler linkage — so the tests link and run against the real CLI
    // module graph.
    // -----------------------------------------------------------------------
    const main_tests_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zap", .module = mod },
        },
    });
    main_tests_module.addOptions("build_options", build_options);
    main_tests_module.addAnonymousImport("zig_lib_archive", .{
        .root_source_file = wrapper_source,
    });
    applyNativeCompilerLinkage(main_tests_module, llvm_lib_path, zig_compiler_lib_path);
    const main_tests = b.addTest(.{
        .root_module = main_tests_module,
        // GP3: mirror the exe — the CLI unit tests exercise the same
        // `std.debug`/addr2line paths, so they too compile against the fork std.
        .zig_lib_dir = fork_zig_lib_dir_lazy,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    b.installArtifact(exe);
    b.installDirectory(.{
        .source_dir = b.path("lib"),
        .install_dir = .prefix,
        .install_subdir = "lib",
    });
    b.installDirectory(.{
        .source_dir = b.path("src/memory"),
        .install_dir = .prefix,
        .install_subdir = "src/memory",
    });

    const cache_correctness_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/cache_correctness_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_cache_correctness_tests = b.addRunArtifact(cache_correctness_tests);
    run_cache_correctness_tests.setEnvironmentVariable("ZAP_BINARY", b.getInstallPath(.bin, "zap"));
    run_cache_correctness_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_cache_correctness_tests.step);

    // `zap addr2line` offline-symbolization integration test (Phase 2.e).
    // Drives the installed `zap` CLI to build a crashing script across
    // optimize modes and symbolize a known address against the produced
    // binary + its split-debug artifact + `.zap-symbols` sidecar.
    const zap_addr2line_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zap_addr2line_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_zap_addr2line_tests = b.addRunArtifact(zap_addr2line_tests);
    run_zap_addr2line_tests.setEnvironmentVariable("ZAP_BINARY", b.getInstallPath(.bin, "zap"));
    run_zap_addr2line_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_zap_addr2line_tests.step);

    // -----------------------------------------------------------------------
    // Run step
    // -----------------------------------------------------------------------
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // -----------------------------------------------------------------------
    // Examples step: build all examples/*/
    // -----------------------------------------------------------------------
    const examples_step = b.step("examples", "Build all examples");
    examples_step.dependOn(b.getInstallStep());

    if (std.Io.Dir.cwd().openDir(b.graph.io, "examples", .{ .iterate = true })) |dir_| {
        var dir = dir_;
        defer dir.close(b.graph.io);
        var it = dir.iterate();
        while (it.next(b.graph.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const example_build_file = b.fmt("examples/{s}/build.zap", .{entry.name});
            std.Io.Dir.cwd().access(b.graph.io, example_build_file, .{}) catch continue;
            // Each example dir has a build.zap with a target matching the dir name
            const example_run = b.addRunArtifact(exe);
            example_run.addArgs(&.{ "build", entry.name });
            example_run.setCwd(.{ .cwd_relative = b.fmt("examples/{s}", .{entry.name}) });
            examples_step.dependOn(&example_run.step);
        }
    } else |_| {
        // examples/ directory not found — skip
    }

    // -----------------------------------------------------------------------
    // Golden diagnostic corpus step (Phase 4.e): re-run every curated
    // diagnostic fixture through the freshly-built `zap` and diff the
    // normalized text + JSON render against the committed golden snapshots.
    // This is the primary regression benchmark for the whole error system; a
    // drift fails the step. Kept separate from `zig build test` because it
    // shells out to the script-mode CLI (the snapshots exercise the end-to-end
    // `zap run` diagnostic path, not the in-process unit harness).
    // -----------------------------------------------------------------------
    const golden_corpus_step = b.step("golden-corpus", "Run the Zap-native golden diagnostic corpus and diff against snapshots");
    const golden_corpus_cmd = b.addSystemCommand(&.{ "bash", "script_fixtures/run_golden_corpus.sh" });
    golden_corpus_cmd.step.dependOn(b.getInstallStep());
    golden_corpus_step.dependOn(&golden_corpus_cmd.step);

    // Phase 4.f abort-surface JSON acceptance: a SEMANTIC guard (distinct from
    // the byte-snapshot corpus) asserting each unrecoverable abort surface
    // (raise / safe-mode contract+arithmetic+index trap) emits a schema-v1
    // JSON record of the CORRECT `domain` under `--error-format=json`. A
    // snapshot alone would silently bless a regressed domain on the next
    // `--update`; this names the invariant.
    const abort_json_step = b.step("abort-json-acceptance", "Assert abort surfaces emit schema-v1 JSON with the correct domain under --error-format=json");
    const abort_json_cmd = b.addSystemCommand(&.{ "bash", "script_fixtures/run_phase_4f_panic_json.sh" });
    abort_json_cmd.step.dependOn(b.getInstallStep());
    abort_json_step.dependOn(&abort_json_cmd.step);

    // Phase D crash-handler portability acceptance: the Domain-B crash handler
    // now lives in the `runtime_os` seam, per-OS. This harness asserts the
    // portability matrix — native SIGSEGV + panic reports unchanged, WASI
    // recoverable-raise reports STILL render under wasmtime while a hardware
    // fault traps cleanly (the `supports_signals=false` degrade), and the
    // Windows VEH crash backend links as a PE32+ (running under wine where
    // available). It is a standalone step (matching the other acceptance
    // harnesses) so the crash-portability invariant is explicitly verifiable.
    const crash_portability_step = b.step("crash-portability-acceptance", "Assert the Phase-D crash handler is OS-portable: native reports unchanged, WASI degrades + recoverable reports render, Windows VEH links as PE32+");
    const crash_portability_cmd = b.addSystemCommand(&.{ "bash", "script_fixtures/run_phase_d_crash_portability.sh" });
    crash_portability_cmd.step.dependOn(b.getInstallStep());
    crash_portability_step.dependOn(&crash_portability_cmd.step);

    // Follow-up #342: the ARC and Tracking managers use atomics that are an
    // OPTIONAL target feature on wasm32 — ARC's refcount `@atomicRmw`
    // (`.monotonic`/`.acq_rel`) and Tracking's spinlock `@cmpxchgStrong`
    // (`.acquire`/`.monotonic`) + `@atomicStore` (`.release`). On single-threaded
    // wasm32-wasi LLVM lowers these ordered atomics to plain non-atomic
    // loads/stores, so neither a `+atomics` feature nor an ordering relaxation
    // is required — proven empirically here and gated henceforth: each fixture
    // genuinely drives the atomic refcount / spinlock path (the canonical
    // `[{String, i64}]` sort+each shape), runs NATIVELY under its manager, then
    // cross-builds `-Dtarget=wasm32-wasi`, links as a wasm MVP binary, and runs
    // under `wasmtime` with byte-identical output + exit 0 + no leak/double-free
    // (a miscompiled atomic would deadlock, corrupt the tracking table, or
    // prematurely free a refcounted value). Arena/Leak are spot-confirmed as the
    // atomics-free baseline. A standalone step (matching the other acceptance
    // harnesses) so the wasm-atomics invariant is explicitly verifiable.
    const wasm_atomic_managers_step = b.step("wasm-atomic-managers-acceptance", "Assert ARC (@atomicRmw) + Tracking (@cmpxchgStrong/@atomicStore) lower + run correctly on single-threaded wasm32-wasi under wasmtime");
    const wasm_atomic_managers_cmd = b.addSystemCommand(&.{ "bash", "script_fixtures/run_wasm_atomic_managers.sh" });
    wasm_atomic_managers_cmd.step.dependOn(b.getInstallStep());
    wasm_atomic_managers_step.dependOn(&wasm_atomic_managers_cmd.step);

    // FCC Phase 5 acceptance: the hardening / breadth / precision corpus for
    // first-class closures (aliased fn-returns, nested/cross-box closures,
    // mixed boxed+direct, the boxed-effect-precision cases). Each fixture runs
    // under BOTH managers asserting expected output + leak-freedom. A
    // standalone step (matching the other FCC acceptance harnesses) the
    // no-regression gate runs explicitly.
    const fcc_phase5_step = b.step("fcc-phase5-acceptance", "Run the FCC Phase 5 hardening/breadth/precision corpus under both managers");
    const fcc_phase5_cmd = b.addSystemCommand(&.{ "bash", "script_fixtures/run_fcc_phase5_acceptance.sh" });
    fcc_phase5_cmd.step.dependOn(b.getInstallStep());
    fcc_phase5_step.dependOn(&fcc_phase5_cmd.step);

    // CapMem Phase 4 custom-manager + verification matrix: the adapter-bounded
    // acceptance proof. Two custom (non-stdlib) managers whose names are
    // unknown to the compiler get codegen byte-identical to the stdlib managers
    // declaring the same `declared_caps` — proving codegen reads the caps bits,
    // never the manager name. Asserts all 6 managers' (ARC/Arena/NoOp/Leak/
    // Tracking + custom) contracts; custom BULK_OR_NEVER == Arena, custom
    // INDIVIDUAL_NO_REFCOUNT == Tracking. (The `zir-test` step adds the
    // build+run integration tests for the two custom managers.)
    const custom_manager_proof_step = b.step("custom-manager-proof", "Run the capability-driven memory model verification matrix (all 6 managers incl. the TRACED GC bounded-RSS proof) + custom-manager acceptance proof");
    const custom_manager_proof_cmd = b.addSystemCommand(&.{ "bash", "script_fixtures/run_custom_manager_proof.sh" });
    custom_manager_proof_cmd.step.dependOn(b.getInstallStep());
    custom_manager_proof_step.dependOn(&custom_manager_proof_cmd.step);

    // Memory.Tracking whole-corpus leak-FREEDOM gate. Asserts the corpus passes
    // 942/0 under Memory.Tracking AND the deinit leak report is EMPTY (zero
    // deinit survivors — no `leak summary` / `memory leak:` lines), with no
    // double-free / invalid-free / segfault. Locks down the two resolved
    // owner-model leaks (gap #302 recursive-struct `%LinkedNode{}`, task #323
    // `MapIter` cursor cell) as fixed: any re-introduced Tracking leak FAILS it.
    const tracking_leak_freedom_step = b.step("tracking-leak-freedom", "Assert the Memory.Tracking corpus is fully leak-free (942/0, zero deinit survivors)");
    const tracking_leak_freedom_cmd = b.addSystemCommand(&.{ "bash", "script_fixtures/run_tracking_leak_freedom.sh" });
    tracking_leak_freedom_cmd.step.dependOn(b.getInstallStep());
    tracking_leak_freedom_step.dependOn(&tracking_leak_freedom_cmd.step);

    // -----------------------------------------------------------------------
    // ZIR integration tests (need the built binary)
    // -----------------------------------------------------------------------
    const zir_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zir_integration_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_zir_tests = b.addRunArtifact(zir_tests);
    run_zir_tests.setEnvironmentVariable("ZAP_BINARY", b.getInstallPath(.bin, "zap"));
    run_zir_tests.step.dependOn(b.getInstallStep());
    const zir_test_step = b.step("zir-test", "Run ZIR integration tests");
    zir_test_step.dependOn(&run_zir_tests.step);
    zir_test_step.dependOn(b.getInstallStep());
}

/// Apply the native compiler-backend linkage (the prebuilt
/// `libzap_compiler.a` object plus the Clang/LLD/LLVM static libraries)
/// to `root_module`. Shared by the `zap` executable and the
/// `src/main.zig` unit-test target so both link against an identical
/// native module graph and do not drift.
fn applyNativeCompilerLinkage(
    root_module: *std.Build.Module,
    llvm_lib_path: ?[]const u8,
    zig_compiler_lib_path: []const u8,
) void {
    root_module.addObjectFile(.{ .cwd_relative = zig_compiler_lib_path });

    const lib_path = llvm_lib_path orelse return;
    root_module.addLibraryPath(.{ .cwd_relative = lib_path });

    // Clang libraries from LLVM 21 (zig-bootstrap 0.16.0)
    const clang_libs = [_][]const u8{
        "clangFrontendTool",           "clangCodeGen",                "clangFrontend",
        "clangDriver",                 "clangSerialization",          "clangSema",
        "clangStaticAnalyzerFrontend", "clangStaticAnalyzerCheckers", "clangStaticAnalyzerCore",
        "clangAnalysis",               "clangASTMatchers",            "clangAST",
        "clangParse",                  "clangAPINotes",               "clangBasic",
        "clangEdit",                   "clangLex",                    "clangRewriteFrontend",
        "clangRewrite",                "clangCrossTU",                "clangIndex",
        "clangToolingCore",            "clangExtractAPI",             "clangSupport",
        "clangInstallAPI",
    };
    for (clang_libs) |lib_name| {
        root_module.linkSystemLibrary(lib_name, .{ .preferred_link_mode = .static });
    }

    const lld_libs = [_][]const u8{
        "lldMinGW", "lldELF", "lldCOFF", "lldWasm", "lldMachO", "lldCommon",
    };
    for (lld_libs) |lib_name| {
        root_module.linkSystemLibrary(lib_name, .{ .preferred_link_mode = .static });
    }

    // LLVM 21 libraries (zig-bootstrap 0.16.0)
    const llvm_libs = [_][]const u8{
        "LLVMWindowsManifest",         "LLVMXRay",                  "LLVMLibDriver",
        "LLVMDlltoolDriver",           "LLVMTelemetry",             "LLVMTextAPIBinaryReader",
        "LLVMCoverage",                "LLVMLineEditor",            "LLVMXCoreDisassembler",
        "LLVMXCoreCodeGen",            "LLVMXCoreDesc",             "LLVMXCoreInfo",
        "LLVMX86TargetMCA",            "LLVMX86Disassembler",       "LLVMX86AsmParser",
        "LLVMX86CodeGen",              "LLVMX86Desc",               "LLVMX86Info",
        "LLVMWebAssemblyDisassembler", "LLVMWebAssemblyAsmParser",  "LLVMWebAssemblyCodeGen",
        "LLVMWebAssemblyUtils",        "LLVMWebAssemblyDesc",       "LLVMWebAssemblyInfo",
        "LLVMVEDisassembler",          "LLVMVEAsmParser",           "LLVMVECodeGen",
        "LLVMVEDesc",                  "LLVMVEInfo",                "LLVMSystemZDisassembler",
        "LLVMSystemZAsmParser",        "LLVMSystemZCodeGen",        "LLVMSystemZDesc",
        "LLVMSystemZInfo",             "LLVMSPIRVCodeGen",          "LLVMSPIRVDesc",
        "LLVMSPIRVInfo",               "LLVMSPIRVAnalysis",         "LLVMSparcDisassembler",
        "LLVMSparcAsmParser",          "LLVMSparcCodeGen",          "LLVMSparcDesc",
        "LLVMSparcInfo",               "LLVMRISCVTargetMCA",        "LLVMRISCVDisassembler",
        "LLVMRISCVAsmParser",          "LLVMRISCVCodeGen",          "LLVMRISCVDesc",
        "LLVMRISCVInfo",               "LLVMPowerPCDisassembler",   "LLVMPowerPCAsmParser",
        "LLVMPowerPCCodeGen",          "LLVMPowerPCDesc",           "LLVMPowerPCInfo",
        "LLVMNVPTXCodeGen",            "LLVMNVPTXDesc",             "LLVMNVPTXInfo",
        "LLVMMSP430Disassembler",      "LLVMMSP430AsmParser",       "LLVMMSP430CodeGen",
        "LLVMMSP430Desc",              "LLVMMSP430Info",            "LLVMMipsDisassembler",
        "LLVMMipsAsmParser",           "LLVMMipsCodeGen",           "LLVMMipsDesc",
        "LLVMMipsInfo",                "LLVMLoongArchDisassembler", "LLVMLoongArchAsmParser",
        "LLVMLoongArchCodeGen",        "LLVMLoongArchDesc",         "LLVMLoongArchInfo",
        "LLVMLanaiDisassembler",       "LLVMLanaiCodeGen",          "LLVMLanaiAsmParser",
        "LLVMLanaiDesc",               "LLVMLanaiInfo",             "LLVMHexagonDisassembler",
        "LLVMHexagonCodeGen",          "LLVMHexagonAsmParser",      "LLVMHexagonDesc",
        "LLVMHexagonInfo",             "LLVMBPFDisassembler",       "LLVMBPFAsmParser",
        "LLVMBPFCodeGen",              "LLVMBPFDesc",               "LLVMBPFInfo",
        "LLVMAVRDisassembler",         "LLVMAVRAsmParser",          "LLVMAVRCodeGen",
        "LLVMAVRDesc",                 "LLVMAVRInfo",               "LLVMARMDisassembler",
        "LLVMARMAsmParser",            "LLVMARMCodeGen",            "LLVMARMDesc",
        "LLVMARMUtils",                "LLVMARMInfo",               "LLVMAMDGPUTargetMCA",
        "LLVMAMDGPUDisassembler",      "LLVMAMDGPUAsmParser",       "LLVMAMDGPUCodeGen",
        "LLVMAMDGPUDesc",              "LLVMAMDGPUUtils",           "LLVMAMDGPUInfo",
        "LLVMAArch64Disassembler",     "LLVMAArch64AsmParser",      "LLVMAArch64CodeGen",
        "LLVMAArch64Desc",             "LLVMAArch64Utils",          "LLVMAArch64Info",
        "LLVMOrcDebugging",            "LLVMOrcJIT",                "LLVMWindowsDriver",
        "LLVMMCJIT",                   "LLVMJITLink",               "LLVMInterpreter",
        "LLVMExecutionEngine",         "LLVMRuntimeDyld",           "LLVMOrcTargetProcess",
        "LLVMOrcShared",               "LLVMDWP",                   "LLVMDWARFCFIChecker",
        "LLVMDebugInfoLogicalView",    "LLVMOption",                "LLVMObjCopy",
        "LLVMMCA",                     "LLVMMCDisassembler",        "LLVMLTO",
        "LLVMFrontendOpenACC",         "LLVMFrontendHLSL",          "LLVMFrontendDriver",
        "LLVMExtensions",              "LLVMPasses",                "LLVMHipStdPar",
        "LLVMCoroutines",              "LLVMCFGuard",               "LLVMipo",
        "LLVMInstrumentation",         "LLVMVectorize",             "LLVMSandboxIR",
        "LLVMLinker",                  "LLVMFrontendOpenMP",        "LLVMFrontendDirective",
        "LLVMFrontendAtomic",          "LLVMFrontendOffloading",    "LLVMObjectYAML",
        "LLVMDWARFLinkerParallel",     "LLVMDWARFLinkerClassic",    "LLVMDWARFLinker",
        "LLVMGlobalISel",              "LLVMMIRParser",             "LLVMAsmPrinter",
        "LLVMSelectionDAG",            "LLVMCodeGen",               "LLVMTarget",
        "LLVMObjCARCOpts",             "LLVMCodeGenTypes",          "LLVMCGData",
        "LLVMIRPrinter",               "LLVMInterfaceStub",         "LLVMFileCheck",
        "LLVMFuzzMutate",              "LLVMScalarOpts",            "LLVMInstCombine",
        "LLVMAggressiveInstCombine",   "LLVMTransformUtils",        "LLVMBitWriter",
        "LLVMAnalysis",                "LLVMProfileData",           "LLVMSymbolize",
        "LLVMDebugInfoBTF",            "LLVMDebugInfoPDB",          "LLVMDebugInfoMSF",
        "LLVMDebugInfoCodeView",       "LLVMDebugInfoGSYM",         "LLVMDebugInfoDWARF",
        "LLVMDebugInfoDWARFLowLevel",  "LLVMObject",                "LLVMTextAPI",
        "LLVMMCParser",                "LLVMIRReader",              "LLVMAsmParser",
        "LLVMMC",                      "LLVMBitReader",             "LLVMFuzzerCLI",
        "LLVMCore",                    "LLVMRemarks",               "LLVMBitstreamReader",
        "LLVMBinaryFormat",            "LLVMTargetParser",          "LLVMSupport",
        "LLVMDemangle",
    };
    for (llvm_libs) |lib_name| {
        root_module.linkSystemLibrary(lib_name, .{ .preferred_link_mode = .static });
    }

    root_module.linkSystemLibrary("z", .{});
    root_module.linkSystemLibrary("zstd", .{});
    root_module.linkSystemLibrary("xml2", .{});
    root_module.linkSystemLibrary("c++", .{ .use_pkg_config = .no });
}

fn pathExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}

fn detectBuildZigLibDir(b: *std.Build) []const u8 {
    return b.graph.zig_lib_directory.path orelse {
        const zig_exe = b.graph.zig_exe;
        const bin_dir = std.fs.path.dirname(zig_exe) orelse ".";
        const parent_dir = std.fs.path.dirname(bin_dir) orelse ".";
        return b.fmt("{s}/lib", .{parent_dir});
    };
}
