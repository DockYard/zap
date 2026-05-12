//! Spike build script for the in-process compile primitive driver.
//!
//! Builds `test_in_process_compile.zig` linked against
//! `libzap_compiler.a` plus the LLVM/Clang/LLD static libraries (the
//! same dependency stack the production `zap` binary uses).
//!
//! Run from the Zap project root:
//!   zig build -f spike/test_driver/build.zig in-process-compile
//!
//! Or from this directory with `zig build`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zap_compiler_lib = b.option(
        []const u8,
        "zap-compiler-lib",
        "Path to libzap_compiler.a",
    ) orelse "../../zap-deps/aarch64-macos-none/libzap_compiler.a";

    const llvm_lib_path = b.option(
        []const u8,
        "llvm-lib-path",
        "Path to LLVM lib directory",
    ) orelse "../../zap-deps/aarch64-macos-none/llvm-libs";

    const section_parser = b.createModule(.{
        .root_source_file = b.path("../../src/memory/section_parser.zig"),
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("test_in_process_compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("section_parser", section_parser);

    const exe = b.addExecutable(.{
        .name = "test_in_process_compile",
        .root_module = exe_mod,
    });

    exe.root_module.addObjectFile(.{ .cwd_relative = zap_compiler_lib });
    exe.root_module.addLibraryPath(.{ .cwd_relative = llvm_lib_path });

    // The full Clang/LLD/LLVM stack the Zap exe links against.
    const clang_libs = [_][]const u8{
        "clangFrontendTool",           "clangCodeGen",
        "clangFrontend",               "clangDriver",
        "clangSerialization",          "clangSema",
        "clangStaticAnalyzerFrontend", "clangStaticAnalyzerCheckers",
        "clangStaticAnalyzerCore",     "clangAnalysis",
        "clangASTMatchers",            "clangAST",
        "clangParse",                  "clangAPINotes",
        "clangBasic",                  "clangEdit",
        "clangLex",                    "clangRewriteFrontend",
        "clangRewrite",                "clangCrossTU",
        "clangIndex",                  "clangToolingCore",
        "clangExtractAPI",             "clangSupport",
        "clangInstallAPI",
    };
    for (clang_libs) |lib_name| {
        exe.root_module.linkSystemLibrary(lib_name, .{ .preferred_link_mode = .static });
    }

    const lld_libs = [_][]const u8{ "lldMinGW", "lldELF", "lldCOFF", "lldWasm", "lldMachO", "lldCommon" };
    for (lld_libs) |lib_name| {
        exe.root_module.linkSystemLibrary(lib_name, .{ .preferred_link_mode = .static });
    }

    const llvm_libs = [_][]const u8{
        "LLVMWindowsManifest",         "LLVMXRay",                   "LLVMLibDriver",
        "LLVMDlltoolDriver",           "LLVMTelemetry",              "LLVMTextAPIBinaryReader",
        "LLVMCoverage",                "LLVMLineEditor",             "LLVMXCoreDisassembler",
        "LLVMXCoreCodeGen",            "LLVMXCoreDesc",              "LLVMXCoreInfo",
        "LLVMX86TargetMCA",            "LLVMX86Disassembler",        "LLVMX86AsmParser",
        "LLVMX86CodeGen",              "LLVMX86Desc",                "LLVMX86Info",
        "LLVMWebAssemblyDisassembler", "LLVMWebAssemblyAsmParser",   "LLVMWebAssemblyCodeGen",
        "LLVMWebAssemblyUtils",        "LLVMWebAssemblyDesc",        "LLVMWebAssemblyInfo",
        "LLVMVEDisassembler",          "LLVMVEAsmParser",            "LLVMVECodeGen",
        "LLVMVEDesc",                  "LLVMVEInfo",                 "LLVMSystemZDisassembler",
        "LLVMSystemZAsmParser",        "LLVMSystemZCodeGen",         "LLVMSystemZDesc",
        "LLVMSystemZInfo",             "LLVMSPIRVCodeGen",           "LLVMSPIRVDesc",
        "LLVMSPIRVInfo",               "LLVMSPIRVAnalysis",          "LLVMSparcDisassembler",
        "LLVMSparcAsmParser",          "LLVMSparcCodeGen",           "LLVMSparcDesc",
        "LLVMSparcInfo",               "LLVMRISCVTargetMCA",         "LLVMRISCVDisassembler",
        "LLVMRISCVAsmParser",          "LLVMRISCVCodeGen",           "LLVMRISCVDesc",
        "LLVMRISCVInfo",               "LLVMPowerPCDisassembler",    "LLVMPowerPCAsmParser",
        "LLVMPowerPCCodeGen",          "LLVMPowerPCDesc",            "LLVMPowerPCInfo",
        "LLVMNVPTXCodeGen",            "LLVMNVPTXDesc",              "LLVMNVPTXInfo",
        "LLVMMSP430Disassembler",      "LLVMMSP430AsmParser",        "LLVMMSP430CodeGen",
        "LLVMMSP430Desc",              "LLVMMSP430Info",             "LLVMMipsDisassembler",
        "LLVMMipsAsmParser",           "LLVMMipsCodeGen",            "LLVMMipsDesc",
        "LLVMMipsInfo",                "LLVMLoongArchDisassembler",  "LLVMLoongArchAsmParser",
        "LLVMLoongArchCodeGen",        "LLVMLoongArchDesc",          "LLVMLoongArchInfo",
        "LLVMLanaiDisassembler",       "LLVMLanaiCodeGen",           "LLVMLanaiAsmParser",
        "LLVMLanaiDesc",               "LLVMLanaiInfo",              "LLVMHexagonDisassembler",
        "LLVMHexagonCodeGen",          "LLVMHexagonAsmParser",       "LLVMHexagonDesc",
        "LLVMHexagonInfo",             "LLVMBPFDisassembler",        "LLVMBPFAsmParser",
        "LLVMBPFCodeGen",              "LLVMBPFDesc",                "LLVMBPFInfo",
        "LLVMAVRDisassembler",         "LLVMAVRAsmParser",           "LLVMAVRCodeGen",
        "LLVMAVRDesc",                 "LLVMAVRInfo",                "LLVMARMDisassembler",
        "LLVMARMAsmParser",            "LLVMARMCodeGen",             "LLVMARMDesc",
        "LLVMARMUtils",                "LLVMARMInfo",                "LLVMAMDGPUTargetMCA",
        "LLVMAMDGPUDisassembler",      "LLVMAMDGPUAsmParser",        "LLVMAMDGPUCodeGen",
        "LLVMAMDGPUDesc",              "LLVMAMDGPUUtils",            "LLVMAMDGPUInfo",
        "LLVMAArch64Disassembler",     "LLVMAArch64AsmParser",       "LLVMAArch64CodeGen",
        "LLVMAArch64Desc",             "LLVMAArch64Utils",           "LLVMAArch64Info",
        "LLVMOrcDebugging",            "LLVMOrcJIT",                 "LLVMWindowsDriver",
        "LLVMMCJIT",                   "LLVMJITLink",                "LLVMInterpreter",
        "LLVMExecutionEngine",         "LLVMRuntimeDyld",            "LLVMOrcTargetProcess",
        "LLVMOrcShared",               "LLVMDWP",                    "LLVMDWARFCFIChecker",
        "LLVMDebugInfoLogicalView",    "LLVMOption",                 "LLVMObjCopy",
        "LLVMMCA",                     "LLVMMCDisassembler",         "LLVMLTO",
        "LLVMFrontendOpenACC",         "LLVMFrontendHLSL",           "LLVMFrontendDriver",
        "LLVMExtensions",              "LLVMPasses",                 "LLVMHipStdPar",
        "LLVMCoroutines",              "LLVMCFGuard",                "LLVMipo",
        "LLVMInstrumentation",         "LLVMVectorize",              "LLVMSandboxIR",
        "LLVMLinker",                  "LLVMFrontendOpenMP",         "LLVMFrontendDirective",
        "LLVMFrontendAtomic",          "LLVMFrontendOffloading",     "LLVMObjectYAML",
        "LLVMDWARFLinkerParallel",     "LLVMDWARFLinkerClassic",     "LLVMDWARFLinker",
        "LLVMGlobalISel",              "LLVMMIRParser",              "LLVMAsmPrinter",
        "LLVMSelectionDAG",            "LLVMCodeGen",                "LLVMTarget",
        "LLVMObjCARCOpts",             "LLVMCodeGenTypes",           "LLVMCGData",
        "LLVMIRPrinter",               "LLVMInterfaceStub",          "LLVMFileCheck",
        "LLVMFuzzMutate",              "LLVMScalarOpts",             "LLVMInstCombine",
        "LLVMAggressiveInstCombine",   "LLVMTransformUtils",         "LLVMBitWriter",
        "LLVMAnalysis",                "LLVMProfileData",            "LLVMSymbolize",
        "LLVMDebugInfoBTF",            "LLVMDebugInfoPDB",           "LLVMDebugInfoMSF",
        "LLVMDebugInfoCodeView",       "LLVMDebugInfoGSYM",          "LLVMDebugInfoDWARF",
        "LLVMDebugInfoDWARFLowLevel",  "LLVMObject",                 "LLVMTextAPI",
        "LLVMMCParser",                "LLVMIRReader",               "LLVMAsmParser",
        "LLVMMC",                      "LLVMBitReader",              "LLVMFuzzerCLI",
        "LLVMCore",                    "LLVMRemarks",                "LLVMBitstreamReader",
        "LLVMBinaryFormat",            "LLVMTargetParser",           "LLVMSupport",
        "LLVMDemangle",
    };
    for (llvm_libs) |lib_name| {
        exe.root_module.linkSystemLibrary(lib_name, .{ .preferred_link_mode = .static });
    }

    exe.root_module.linkSystemLibrary("zstd", .{});
    exe.root_module.linkSystemLibrary("z", .{});
    exe.root_module.linkSystemLibrary("c++", .{});

    if (target.result.os.tag.isDarwin()) {
        exe.root_module.linkSystemLibrary("xml2", .{});
    }

    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.cwd = b.path("../..");
    const run_step = b.step("in-process-compile", "Run the in-process compile spike");
    run_step.dependOn(&run.step);
}
