const std = @import("std");
const builtin = @import("builtin");

// Pre-built dependency version — update when releasing new zap-deps
const zap_deps_version = "v0.15.2-zap.1";
const zap_deps_base_url = "https://github.com/DockYard/zig/releases/download/" ++ zap_deps_version;
const host_triple = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi);
const default_deps_dir = "zap-deps/" ++ host_triple;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module — no native deps needed
    const mod = b.addModule("zap", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // -----------------------------------------------------------------------
    // Setup step: download pre-built deps
    // -----------------------------------------------------------------------
    const setup_step = b.step("setup", "Download pre-built zap dependencies for " ++ host_triple);
    const setup_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        "set -e && " ++
            "echo 'Downloading zap-deps for " ++ host_triple ++ "...' && " ++
            "curl -L -o zap-deps-" ++ host_triple ++ ".tar.xz " ++
            zap_deps_base_url ++ "/zap-deps-" ++ host_triple ++ ".tar.xz && " ++
            "mkdir -p zap-deps && " ++
            "tar xJf zap-deps-" ++ host_triple ++ ".tar.xz -C zap-deps && " ++
            "rm zap-deps-" ++ host_triple ++ ".tar.xz && " ++
            "echo 'Done! You can now run: zig build'",
    });
    setup_step.dependOn(&setup_cmd.step);

    // -----------------------------------------------------------------------
    // Test steps (no native deps needed)
    // -----------------------------------------------------------------------
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // -----------------------------------------------------------------------
    // Dependency paths
    // -----------------------------------------------------------------------
    const user_lib = b.option([]const u8, "zap-compiler-lib", "Path to libzap_compiler.a");
    const user_llvm = b.option([]const u8, "llvm-lib-path", "Path to LLVM library directory with native .a files");

    const zig_compiler_lib_path = user_lib orelse default_deps_dir ++ "/libzap_compiler.a";
    const llvm_lib_path: ?[]const u8 = user_llvm orelse default_deps_dir ++ "/llvm-libs";

    // If using defaults and deps don't exist, fail with a helpful message
    if (user_lib == null) {
        std.Io.Dir.cwd().access(b.graph.io, zig_compiler_lib_path, .{}) catch {
            const fail = b.addSystemCommand(&.{
                "sh", "-c",
                "printf '\\n" ++
                    "Error: zap-deps not found.\\n" ++
                    "\\n" ++
                    "Run:\\n" ++
                    "  zig build setup\\n" ++
                    "\\n" ++
                    "This downloads the pre-built dependencies for " ++ host_triple ++ ".\\n" ++
                    "\\n' >&2 && exit 1",
            });
            b.getInstallStep().dependOn(&fail.step);
            const run_step = b.step("run", "Run the app");
            run_step.dependOn(&fail.step);
            const zir_test_step = b.step("zir-test", "Run ZIR integration tests");
            zir_test_step.dependOn(&fail.step);
            return;
        };
    }

    // -----------------------------------------------------------------------
    // Zig stdlib embedding
    // -----------------------------------------------------------------------
    const zig_lib_dir = b.option([]const u8, "zig-lib-dir", "Path to Zig lib directory (contains std/)") orelse
        detectBuildZigLibDir(b);

    const tar_step = b.addSystemCommand(&.{ "tar", "-cf" });
    const tar_output = tar_step.addOutputFileArg("zig_lib.tar");
    tar_step.addArg("-C");
    tar_step.addArg(zig_lib_dir);
    tar_step.addArgs(&.{ "std", "compiler_rt", "compiler_rt.zig", "c.zig", "c" });

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(tar_output, "zig_lib.tar");
    const wrapper_source = wf.add("zig_lib_archive.zig",
        \\pub const data = @embedFile("zig_lib.tar");
        \\
    );

    // -----------------------------------------------------------------------
    // Executable
    // -----------------------------------------------------------------------
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

    exe.root_module.addAnonymousImport("zig_lib_archive", .{
        .root_source_file = wrapper_source,
    });

    exe.root_module.addObjectFile(.{ .cwd_relative = zig_compiler_lib_path });

    if (llvm_lib_path) |lib_path| {
        exe.root_module.addLibraryPath(.{ .cwd_relative = lib_path });

        // Clang libraries from LLVM 21 (zig-bootstrap 0.16.0)
        const clang_libs = [_][]const u8{
            "clangFrontendTool",           "clangCodeGen",                "clangFrontend",
            "clangDriver",                 "clangSerialization",          "clangSema",
            "clangStaticAnalyzerFrontend", "clangStaticAnalyzerCheckers", "clangStaticAnalyzerCore",
            "clangAnalysis",               "clangASTMatchers",            "clangAST",
            "clangParse",                  "clangAPINotes",               "clangBasic",
            "clangEdit",                   "clangLex",
            "clangRewriteFrontend",        "clangRewrite",                "clangCrossTU",
            "clangIndex",                  "clangToolingCore",            "clangExtractAPI",
            "clangSupport",                "clangInstallAPI",
        };
        for (clang_libs) |lib_name| {
            exe.root_module.linkSystemLibrary(lib_name, .{ .preferred_link_mode = .static });
        }

        const lld_libs = [_][]const u8{
            "lldMinGW", "lldELF", "lldCOFF", "lldWasm", "lldMachO", "lldCommon",
        };
        for (lld_libs) |lib_name| {
            exe.root_module.linkSystemLibrary(lib_name, .{ .preferred_link_mode = .static });
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
            exe.root_module.linkSystemLibrary(lib_name, .{ .preferred_link_mode = .static });
        }

        exe.root_module.linkSystemLibrary("z", .{});
        exe.root_module.linkSystemLibrary("zstd", .{});
        exe.root_module.linkSystemLibrary("xml2", .{});
        exe.root_module.linkSystemLibrary("c++", .{ .use_pkg_config = .no });
    }

    b.installArtifact(exe);

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
    const zir_test_step = b.step("zir-test", "Run ZIR integration tests");
    zir_test_step.dependOn(&run_zir_tests.step);
    zir_test_step.dependOn(b.getInstallStep());
}

fn detectBuildZigLibDir(b: *std.Build) []const u8 {
    return b.graph.zig_lib_directory.path orelse {
        const zig_exe = b.graph.zig_exe;
        const bin_dir = std.fs.path.dirname(zig_exe) orelse ".";
        const parent_dir = std.fs.path.dirname(bin_dir) orelse ".";
        return b.fmt("{s}/lib", .{parent_dir});
    };
}
