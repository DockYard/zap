const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zap", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const zig_compiler_lib_path = b.option([]const u8, "zig-compiler-lib", "Path to libzig_compiler.a") orelse "../zig/zig-out/lib/libzig_compiler.a";

    // Zig library directory — needed to create the embedded stdlib archive.
    // Auto-detected from ZIG_LIB_DIR, exe-relative, or well-known paths.
    const zig_lib_dir = b.option([]const u8, "zig-lib-dir", "Path to Zig lib directory (contains std/)") orelse
        detectBuildZigLibDir(b);

    // Create a tar archive of the Zig stdlib + compiler_rt for embedding.
    // This makes the zap binary fully self-contained — no external Zig install needed.
    const tar_step = b.addSystemCommand(&.{ "tar", "-cf" });
    const tar_output = tar_step.addOutputFileArg("zig_lib.tar");
    tar_step.addArg("-C");
    tar_step.addArg(zig_lib_dir);
    tar_step.addArgs(&.{ "std", "compiler_rt", "compiler_rt.zig", "c.zig", "c" });

    // Create a wrapper module that @embedFile's the tar archive.
    // The WriteFiles step places both files in the same generated directory
    // so the relative @embedFile path resolves correctly.
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(tar_output, "zig_lib.tar");
    const wrapper_source = wf.add("zig_lib_archive.zig",
        \\pub const data = @embedFile("zig_lib.tar");
        \\
    );

    const exe = b.addExecutable(.{
        .name = "zap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zap", .module = mod },
            },
        }),
    });

    // Add the embedded Zig lib archive as an importable module
    exe.root_module.addAnonymousImport("zig_lib_archive", .{
        .root_source_file = wrapper_source,
    });

    // Always link the Zig compiler library for ZIR-to-binary compilation.
    // Built via: cd ~/projects/zig && zig build lib -Denable-llvm=false
    exe.root_module.addObjectFile(.{ .cwd_relative = zig_compiler_lib_path });

    // When the Zig compiler library was built with LLVM, link against
    // LLVM/Clang/LLD static libraries. Optional — if not provided, LLVM
    // linking is skipped (sufficient for non-LLVM builds).
    const llvm_lib_path = b.option([]const u8, "llvm-lib-path", "Path to LLVM library directory with native .a files");
    if (llvm_lib_path) |lib_path| {
        exe.root_module.addLibraryPath(.{ .cwd_relative = lib_path });

        // Clang libraries
        const clang_libs = [_][]const u8{
            "clangFrontendTool",           "clangCodeGen",                "clangFrontend",
            "clangDriver",                 "clangSerialization",          "clangSema",
            "clangStaticAnalyzerFrontend", "clangStaticAnalyzerCheckers", "clangStaticAnalyzerCore",
            "clangAnalysis",               "clangASTMatchers",            "clangAST",
            "clangParse",                  "clangAPINotes",               "clangBasic",
            "clangEdit",                   "clangLex",                    "clangARCMigrate",
            "clangRewriteFrontend",        "clangRewrite",                "clangCrossTU",
            "clangIndex",                  "clangToolingCore",            "clangExtractAPI",
            "clangSupport",                "clangInstallAPI",
        };
        for (clang_libs) |lib_name| {
            exe.root_module.linkSystemLibrary(lib_name, .{});
        }

        // LLD libraries
        const lld_libs = [_][]const u8{
            "lldMinGW", "lldELF", "lldCOFF", "lldWasm", "lldMachO", "lldCommon",
        };
        for (lld_libs) |lib_name| {
            exe.root_module.linkSystemLibrary(lib_name, .{});
        }

        // LLVM libraries (matching Zig 0.15.2 build.zig order)
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
            "LLVMOrcShared",               "LLVMDWP",                   "LLVMDebugInfoLogicalView",
            "LLVMDebugInfoGSYM",           "LLVMOption",                "LLVMObjectYAML",
            "LLVMObjCopy",                 "LLVMMCA",                   "LLVMMCDisassembler",
            "LLVMLTO",                     "LLVMPasses",                "LLVMHipStdPar",
            "LLVMCFGuard",                 "LLVMCoroutines",            "LLVMipo",
            "LLVMVectorize",               "LLVMSandboxIR",             "LLVMLinker",
            "LLVMInstrumentation",         "LLVMFrontendOpenMP",        "LLVMFrontendOffloading",
            "LLVMFrontendOpenACC",         "LLVMFrontendHLSL",          "LLVMFrontendDriver",
            "LLVMFrontendAtomic",          "LLVMExtensions",            "Polly",
            "PollyISL",                    "LLVMDWARFLinkerParallel",   "LLVMDWARFLinkerClassic",
            "LLVMDWARFLinker",             "LLVMGlobalISel",            "LLVMMIRParser",
            "LLVMAsmPrinter",              "LLVMSelectionDAG",          "LLVMCodeGen",
            "LLVMTarget",                  "LLVMObjCARCOpts",           "LLVMCodeGenTypes",
            "LLVMCGData",                  "LLVMIRPrinter",             "LLVMInterfaceStub",
            "LLVMFileCheck",               "LLVMFuzzMutate",            "LLVMScalarOpts",
            "LLVMInstCombine",             "LLVMAggressiveInstCombine", "LLVMTransformUtils",
            "LLVMBitWriter",               "LLVMAnalysis",              "LLVMProfileData",
            "LLVMSymbolize",               "LLVMDebugInfoBTF",          "LLVMDebugInfoPDB",
            "LLVMDebugInfoMSF",            "LLVMDebugInfoCodeView",     "LLVMDebugInfoDWARF",
            "LLVMObject",                  "LLVMTextAPI",               "LLVMMCParser",
            "LLVMIRReader",                "LLVMAsmParser",             "LLVMMC",
            "LLVMBitReader",               "LLVMFuzzerCLI",             "LLVMCore",
            "LLVMRemarks",                 "LLVMBitstreamReader",       "LLVMBinaryFormat",
            "LLVMTargetParser",            "LLVMSupport",               "LLVMDemangle",
        };
        for (llvm_libs) |lib_name| {
            exe.root_module.linkSystemLibrary(lib_name, .{});
        }

        // System dependencies
        exe.root_module.linkSystemLibrary("z", .{});
        exe.root_module.linkSystemLibrary("zstd", .{});
        exe.root_module.linkSystemLibrary("xml2", .{});
        exe.root_module.linkSystemLibrary("c++", .{ .use_pkg_config = .no });
    }

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests. The exe module's only test
    // is `_ = @import("zap")` which is already covered by mod_tests. We
    // skip exe_tests here because it would require libzig_compiler.a at
    // link time, which isn't always available during development.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // ZIR integration tests — compile Zap programs via the ZIR pipeline
    // and verify the output. These invoke the `zap` binary as a subprocess,
    // so they depend on the binary being built and installed first.
    const zir_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zir_integration_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_zir_tests = b.addRunArtifact(zir_tests);
    run_zir_tests.setEnvironmentVariable("ZAP_BINARY", b.getInstallPath(.bin, "zap"));
    const zir_test_step = b.step("zir-test", "Run ZIR integration tests");
    zir_test_step.dependOn(&run_zir_tests.step);
    // Ensure the zap binary is built and installed before running ZIR tests
    zir_test_step.dependOn(b.getInstallStep());

    const phase9_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/phase9_validation_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_phase9_tests = b.addRunArtifact(phase9_tests);
    const phase9_test_step = b.step("phase9-test", "Run Phase 9 validation tests");
    phase9_test_step.dependOn(&run_phase9_tests.step);

    const phase9_bench = b.addExecutable(.{
        .name = "phase9-benchmarks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/phase9_benchmarks.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_phase9_bench = b.addRunArtifact(phase9_bench);
    const bench_step = b.step("bench", "Run Phase 9 benchmarks");
    bench_step.dependOn(&run_phase9_bench.step);
}

/// Auto-detect the Zig lib directory at build time.
/// Uses the Zig compiler's own lib directory — the same Zig that's running
/// the build has its lib/ alongside its binary.
fn detectBuildZigLibDir(b: *std.Build) []const u8 {
    return b.graph.zig_lib_directory.path orelse {
        // Fallback: derive from zig executable path
        const zig_exe = b.graph.zig_exe;
        const bin_dir = std.fs.path.dirname(zig_exe) orelse ".";
        const parent_dir = std.fs.path.dirname(bin_dir) orelse ".";
        return b.fmt("{s}/lib", .{parent_dir});
    };
}
