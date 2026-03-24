# Zap Self-Contained Binary — Implementation Plan

## Goal

Ship a **single `zap` binary** (+ bundled `lib/` directory) that can compile
`.zap` source files to native binaries by lowering to Zig IR. The entire Zig
compiler (Sema, codegen, linker) and stdlib are statically linked or bundled
— no external `zig` installation required.

## Current State (March 2026)

**Working end-to-end:**
- Zap source → IR → ZIR (via 47 C-ABI functions) → `libzig_compiler.a` →
  native ARM64 Mach-O binaries
- All 71 IR instruction types have handlers (3 with workarounds)
- Return type inference, runtime integration, body-tracked control flow
- Verified: `def main() do end`, `def main() do 20 + 22 end`,
  `def main() do 10 * 5 - 8 end`

**Not working:**
- Two separate binaries (`zap` text-codegen vs `zap-zir` ZIR backend)
- `zir_compile.zig` hardcodes `zig_lib_dir` to `~/.asdf/installs/zig/0.15.2/lib`
- Runtime module registered via file path, not embedded source
- `field_set` is a no-op (missing `field_ptr`/`store` C-ABI)
- `alloc_owned` emits a marker struct, not real allocation
- `optional_unwrap` uses `if_else` workaround, not proper null-check

---

## Phase 1: Complete C-ABI Gaps

These are missing builder functions in the Zig fork that prevent certain Zap
features from compiling correctly via ZIR.

### 1.1 — Add `field_ptr` + `store` to C-ABI builder

**Problem:** `field_set` in `src/zir_builder.zig:863-908` is a no-op. Mutation
requires two ZIR instructions: `field_ptr` (get pointer to struct field) then
`store` (write value through pointer). Neither is exposed via C-ABI.

**Files to modify:**

| File | Change |
|------|--------|
| `~/projects/zig/src/zir_builder.zig` | Add `FuncBody.addFieldPtr(object: Ref, field: []const u8) -> Ref` and `FuncBody.addStore(ptr: Ref, value: Ref) -> void` methods |
| `~/projects/zig/src/zir_api.zig` | Add `zir_builder_emit_field_ptr(handle, object, field_ptr, field_len) -> u32` and `zir_builder_emit_store(handle, ptr_ref, value_ref) -> i32` C-ABI exports |
| `~/projects/zap/src/zir_builder.zig` | Add `extern "c"` declarations for both functions; replace `field_set` no-op (lines 863-908) with `field_ptr` + `store` call sequence |

**Implementation details:**

In `zir_builder.zig` (Zig fork):
```zig
pub fn addFieldPtr(body: *FuncBody, object: Zir.Inst.Ref, field: []const u8) !Zir.Inst.Ref {
    // Emit Zir.Inst.Tag.field_ptr with .pl_node data
    // Payload: { object_ref, field_name_string_index }
    // Returns a pointer-type Ref
}

pub fn addStore(body: *FuncBody, ptr: Zir.Inst.Ref, value: Zir.Inst.Ref) !void {
    // Emit Zir.Inst.Tag.store with .bin data { lhs=ptr, rhs=value }
    // No return value (void instruction)
}
```

In `zir_builder.zig` (Zap):
```zig
.field_set => |fs| {
    const obj_ref = self.refForLocal(fs.object) catch return;
    const val_ref = self.refForLocal(fs.value) catch return;
    const ptr = zir_builder_emit_field_ptr(self.handle, obj_ref, fs.field.ptr, @intCast(fs.field.len));
    if (ptr == error_ref) return error.EmitFailed;
    if (zir_builder_emit_store(self.handle, ptr, val_ref) != 0) return error.EmitFailed;
},
```

**Test:** Write a Zap program that mutates a struct field and compile via ZIR:
```
def main() do
  s = {name: "hello", count: 0}
  s.count = 42
  Kernel.println(s.count)
end
```

**Build and verify:**
```bash
cd ~/projects/zig && zig build lib -Denable-llvm
cd ~/projects/zap && zig build zir-compile -Denable-zir-backend=true -Dllvm-lib-path=$HOME/llvm-20-native/lib
./zig-out/bin/zap-zir examples/field_set_test.zap --zig-lib-dir ~/.asdf/installs/zig/0.15.2/lib
```

### 1.2 — Add `is_non_null` + `optional_payload` to C-ABI builder

**Problem:** `optional_unwrap` in `src/zir_builder.zig:1184-1231` uses a
`cmp_eq(source, null)` + `if_else` workaround. The correct ZIR pattern is:

1. `is_non_null` — test if value is non-null (returns bool)
2. `condbr` — branch on result
3. `optional_payload_safe` — extract the inner value in the non-null branch
4. panic call in the null branch

**Files to modify:**

| File | Change |
|------|--------|
| `~/projects/zig/src/zir_builder.zig` | Add `FuncBody.addIsNonNull(operand: Ref) -> Ref` and `FuncBody.addOptionalPayloadSafe(operand: Ref) -> Ref` |
| `~/projects/zig/src/zir_api.zig` | Add `zir_builder_emit_is_non_null(handle, operand) -> u32` and `zir_builder_emit_optional_payload(handle, operand) -> u32` |
| `~/projects/zap/src/zir_builder.zig` | Add extern declarations; rewrite `optional_unwrap` (lines 1184-1231) to use body-tracked `if_else_bodies` with `is_non_null` condition, `optional_payload` in then-branch, panic in else-branch |

**Implementation in Zap:**
```zig
.optional_unwrap => |ou| {
    const source_ref = self.refForLocal(ou.source) catch return;
    const is_nonnull = zir_builder_emit_is_non_null(self.handle, source_ref);
    if (is_nonnull == error_ref) return error.EmitFailed;

    // Then branch: extract payload
    zir_builder_begin_capture(self.handle);
    const payload = zir_builder_emit_optional_payload(self.handle, source_ref);
    var then_len: u32 = 0;
    const then_ptr = zir_builder_end_capture(self.handle, &then_len);
    // ... copy then_ptr ...

    // Else branch: panic
    zir_builder_begin_capture(self.handle);
    // ... emit panic call ...
    var else_len: u32 = 0;
    const else_ptr = zir_builder_end_capture(self.handle, &else_len);

    const ref = zir_builder_emit_if_else_bodies(
        self.handle, is_nonnull,
        then_insts.ptr, then_insts.len, payload,
        else_insts.ptr, else_insts.len, void_ref,
    );
    if (ref == error_ref) return error.EmitFailed;
    try self.setLocal(ou.dest, ref);
},
```

**Test:** Zap program with optional unwrapping:
```
def maybe_value(x) do
  case x do
    nil -> :error
    val -> val
  end
end
```

### 1.3 — Design `alloc_owned` for ARC allocation

**Problem:** `alloc_owned` in `src/zir_builder.zig:1434-1474` emits a marker
struct `{.__arc_type = "TypeName"}` instead of real heap allocation. The core
issue: `Arc(T)` is generic over a Zig comptime type, but the IR only has a
string type name.

**Design options:**

**Option A (recommended): Non-generic runtime helper**

Add to `src/runtime.zig`:
```zig
pub const ArcRuntime = struct {
    pub fn allocAny(comptime T: type, allocator: Allocator, value: T) *ArcInner(T) {
        const inner = allocator.create(ArcInner(T)) catch @panic("OOM");
        inner.* = .{ .header = ArcHeader.init(), .value = value };
        return inner;
    }
};
```

Then in ZIR builder, emit:
```
@import("zap_runtime").ArcRuntime.allocAny(@TypeOf(value), allocator, value)
```

This works because `@TypeOf(value)` is available at comptime in ZIR — we don't
need the string type name.

**Option B: Emit typed struct definitions into ZIR**

Create a `zir_builder_emit_struct_type()` C-ABI function that defines a named
struct type in ZIR. Then use that type ref for `Arc(T).init()`. This is more
correct but requires significant builder additions.

**Recommendation:** Start with Option A. It solves the immediate problem and
doesn't require new C-ABI builder functions — just a runtime helper.

**Files to modify:**

| File | Change |
|------|--------|
| `~/projects/zap/src/runtime.zig` | Add `ArcRuntime.allocAny` helper |
| `~/projects/zap/src/zir_builder.zig` | Replace `alloc_owned` handler (lines 1434-1474) with `@import("zap_runtime").ArcRuntime.allocAny(@TypeOf(val), allocator, val)` call chain |

**Test:** Zap program that allocates a heap value and accesses it:
```
def main() do
  x = Arc.new({name: "hello"})
  Kernel.println(x.name)
end
```

---

## Phase 2: Zig Library Directory Bundling

The Zig compiler requires access to `lib/std/std.zig` and related source files
at compile time. Zig itself does **not** embed these — it ships a `lib/`
directory alongside the binary and discovers it at runtime via relative path
search (`introspect.zig`).

Zap will follow the same approach.

### 2.1 — Copy Zig's `lib/` into Zap's distribution

The Zap distribution will have this layout:
```
zap-v0.1.0-aarch64-macos/
├── bin/
│   └── zap              # The self-contained binary
└── lib/
    └── zig/             # Zig's standard library + compiler runtime
        ├── std/
        │   └── std.zig
        ├── compiler_rt/
        ├── c/
        ├── libc/
        └── ...
```

**Action:** Create a build script or Makefile target that:
1. Copies `~/projects/zig/lib/` into the distribution
2. Excludes test data files (`.gz`, `.tar`, `.zst`, `.txt.`)
3. Blanks out test `.zig` files (replace with empty files)
4. Preserves essential dirs: `std/`, `compiler_rt/`, `c/`, `libc/`, `include/`

**Files to create:**

| File | Purpose |
|------|---------|
| `scripts/bundle-lib.sh` | Shell script to copy and strip Zig's lib/ directory |

**Script contents:**
```bash
#!/bin/bash
set -euo pipefail
ZIG_SRC="${1:-$HOME/projects/zig}"
DEST="${2:-dist/lib/zig}"

rm -rf "$DEST"
mkdir -p "$DEST"

# Copy essential directories
for dir in std compiler_rt c libc include; do
    cp -r "$ZIG_SRC/lib/$dir" "$DEST/"
done

# Copy root files
cp "$ZIG_SRC/lib/c.zig" "$DEST/"
cp "$ZIG_SRC/lib/compiler_rt.zig" "$DEST/"

# Strip test data
find "$DEST" \( -name "*.gz" -o -name "*.tar" -o -name "*.zst" \) -delete

echo "Bundled Zig lib to $DEST ($(du -sh "$DEST" | cut -f1))"
```

### 2.2 — Implement Zig lib directory discovery in Zap

Replace the hardcoded path in `zir_compile.zig:55`:
```zig
var zig_lib_dir: []const u8 = "/Users/bcardarella/.asdf/installs/zig/0.15.2/lib";
```

With a discovery function that:
1. Checks `ZAP_ZIG_LIB_DIR` environment variable
2. Checks `--zig-lib-dir` CLI flag (already supported)
3. Searches relative to executable: `../lib/zig/std/std.zig`
4. Falls back to system Zig installation via `detectZigLibDir()` (already in
   `zir_backend.zig:93-122`)

**Files to modify:**

| File | Change |
|------|--------|
| `src/zir_compile.zig` | Replace hardcoded path with discovery chain |
| `src/zir_backend.zig` | Extend `detectZigLibDir()` to check relative-to-exe path first and add `ZAP_ZIG_LIB_DIR` env var check |

**Implementation in `zir_backend.zig`:**
```zig
pub fn detectZigLibDir(allocator: Allocator) ?[]const u8 {
    // 1. Environment variable override
    if (std.process.getEnvVarOwned(allocator, "ZAP_ZIG_LIB_DIR")) |dir| {
        return dir;
    } else |_| {}

    // 2. Relative to self executable: ../lib/zig/std/std.zig
    if (std.fs.selfExePathAlloc(allocator)) |exe_path| {
        defer allocator.free(exe_path);
        const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
        const candidates = [_][]const u8{
            // bin/zap -> lib/zig/ (standard install layout)
            std.fs.path.join(allocator, &.{ exe_dir, "..", "lib", "zig" }) catch continue,
            // bin/zap -> lib/ (flat layout)
            std.fs.path.join(allocator, &.{ exe_dir, "..", "lib" }) catch continue,
        };
        for (candidates) |candidate| {
            const check = std.fs.path.join(allocator, &.{ candidate, "std", "std.zig" }) catch continue;
            defer allocator.free(check);
            std.fs.cwd().access(check, .{}) catch continue;
            return allocator.dupe(u8, candidate) catch continue;
        }
    } else |_| {}

    // 3. Fall back to system zig installation (existing logic)
    // ... existing candidate list ...
}
```

**Test:** Build `zap-zir`, place Zig `lib/` next to it, verify it compiles
without `--zig-lib-dir`:
```bash
mkdir -p test-dist/bin test-dist/lib/zig
cp zig-out/bin/zap-zir test-dist/bin/zap
cp -r ~/.asdf/installs/zig/0.15.2/lib/std test-dist/lib/zig/
test-dist/bin/zap examples/hello.zap
```

---

## Phase 3: Embedded Runtime Module

Currently `src/zir_compile.zig:172-178` locates `runtime.zig` via file path
relative to `@src().file`. This breaks when the binary runs from a different
location. The runtime source must be either embedded or bundled.

### 3.1 — Add in-memory module source API to Zig fork

Add a C-ABI function that registers a module from an in-memory source buffer
instead of a file path.

**Files to modify:**

| File | Change |
|------|--------|
| `~/projects/zig/src/zir_api.zig` | Add `zir_compilation_add_module_source(ctx, name, source_ptr, source_len) -> i32` |
| `~/projects/zig/src/zir_api.zig` | Implement: write source to a temp file in the compilation's local cache dir, then call existing `addModule` logic with that path |

**Why a temp file?** The Zig compiler's module loading (`Compilation.zig`,
`Package.Module`) expects filesystem paths throughout. Writing to cache is
simpler than modifying the file abstraction layer. The cache dir already exists
from `zir_compilation_create()`.

**Implementation:**
```zig
export fn zir_compilation_add_module_source(
    ctx: *ZirContext,
    name: [*:0]const u8,
    source_ptr: [*]const u8,
    source_len: u32,
) callconv(.c) i32 {
    // Write source to <local_cache_dir>/<name>.zig
    const cache_dir = ctx.compilation.dirs.local_cache;
    const file_name = std.fmt.allocPrint(ctx.arena, "{s}.zig", .{std.mem.span(name)}) catch return -1;
    const file = cache_dir.createFile(file_name, .{}) catch return -1;
    defer file.close();
    file.writeAll(source_ptr[0..source_len]) catch return -1;

    // Get the full path and register as a module
    const full_path = cache_dir.realpathAlloc(ctx.arena, file_name) catch return -1;
    const path_z = ctx.arena.dupeZ(u8, full_path) catch return -1;
    return zir_compilation_add_module(ctx, name, path_z);
}
```

### 3.2 — Embed runtime source in Zap binary

**Files to modify:**

| File | Change |
|------|--------|
| `src/zir_compile.zig` | Replace file-path runtime discovery with `@embedFile("runtime.zig")` + `zir_compilation_add_module_source()` call |
| `src/zir_builder.zig` | Add extern declaration for `zir_compilation_add_module_source` |

**Implementation in `zir_compile.zig`:**
```zig
const runtime_source = @embedFile("runtime.zig");

// Register the embedded runtime module
extern "c" fn zir_compilation_add_module_source(
    ctx: *ZirContext,
    name: [*:0]const u8,
    source_ptr: [*]const u8,
    source_len: u32,
) i32;

// In main():
if (zir_compilation_add_module_source(ctx, "zap_runtime", runtime_source.ptr, runtime_source.len) != 0) {
    try stdout.print("ERROR: Failed to register runtime module\n", .{});
    std.process.exit(1);
}
```

**Also embed the stdlib prelude:**
```zig
const stdlib_source = @embedFile("stdlib.zig");
// Register similarly if needed
```

**Test:** Build `zap-zir`, move it to `/tmp/`, verify it still compiles programs
that call `Kernel.println()` without the Zap source tree being present.

---

## Phase 4: Unify CLI into Single Binary

Merge the text-codegen `zap` and ZIR-backend `zap-zir` into a single `zap`
binary that uses ZIR as the default compilation path.

### 4.1 — Make ZIR the default compilation backend

**Files to modify:**

| File | Change |
|------|--------|
| `build.zig` | Remove the separate `zir-compile` step; make the main `zap` target always link `libzig_compiler.a` |
| `build.zig` | Remove `-Denable-zir-backend` option (always enabled) |
| `build.zig` | Keep `-Dllvm-lib-path` option for LLVM library location |
| `src/main.zig` | Replace the text codegen path with ZIR backend calls |
| `src/zir_compile.zig` | **Delete** — functionality moves into `main.zig` |

### 4.2 — Restructure `main.zig` compilation flow

The current `main.zig` runs:
1. Parse → Collect → Macro → Desugar → Type check → HIR → IR
2. Text codegen → write `.zig` → shell out to `zig build`

Replace step 2 with:
1. Parse → Collect → Macro → Desugar → Type check → HIR → IR *(unchanged)*
2. ZIR builder → inject → Sema → codegen → link *(from zir_compile.zig)*

**Specific changes in `main.zig`:**

```zig
// After IR lowering (existing code), replace codegen.generate() with:

// Detect zig lib dir
const zig_lib = zir_backend.detectZigLibDir(allocator) orelse {
    stderr.print("Error: cannot find Zig lib directory\n", .{});
    std.process.exit(1);
};

// Create compilation context
const ctx = zir_compilation_create(zig_lib_z, cache_z, cache_z, output_z, name_z)
    orelse { ... };
defer zir_compilation_destroy(ctx);

// Register embedded runtime
const runtime_source = @embedFile("runtime.zig");
_ = zir_compilation_add_module_source(ctx, "zap_runtime", runtime_source.ptr, runtime_source.len);

// Build ZIR and compile
zir_builder.buildAndInject(allocator, ir_program, ctx, null) catch { ... };
if (zir_compilation_update(ctx) != 0) { ... };
```

### 4.3 — Keep `--emit-zig` as debug flag

The text codegen path (`codegen.zig`) remains useful for debugging. Keep it
behind `--emit-zig` flag — when passed, print generated Zig source to stdout
instead of compiling via ZIR.

**In `main.zig`:**
```zig
if (emit_zig) {
    // Existing text codegen path — writes to stdout
    var gen = codegen.ZigCodegen.init(allocator, ...);
    gen.generate(ir_program);
    stdout.print("{s}", .{gen.output()});
} else {
    // ZIR compilation path (default)
    // ... as above ...
}
```

### 4.4 — Integrate `zap run` with ZIR backend

The `zap run` command (compile + execute) currently shells out to `zig build
run`. Replace with:

1. Compile via ZIR backend to `zap-out/bin/<name>`
2. Execute the resulting binary directly via `std.process.Child`

**In `main.zig` run handler:**
```zig
// After successful ZIR compilation to output_path:
var child = std.process.Child.init(.{
    .argv = &.{output_path},
    .allocator = allocator,
});
const term = try child.spawnAndWait();
std.process.exit(term.Exited);
```

### 4.5 — Update `build.zig` for unified binary

Remove the conditional ZIR backend and make it the only path:

```zig
// Remove:
//   const enable_zir = b.option(bool, "enable-zir-backend", ...);
//   if (enable_zir) { ... separate zir-compile step ... }

// Instead: always link libzig_compiler.a for the main "zap" binary
const zig_compiler_lib = b.option(
    []const u8,
    "zig-compiler-lib",
    "Path to libzig_compiler.a",
) orelse "../zig/zig-out/lib/libzig_compiler.a";

exe.addObjectFile(.{ .cwd_relative = zig_compiler_lib });

// Link LLVM libs (required)
const llvm_lib_path = b.option(
    []const u8,
    "llvm-lib-path",
    "Path to LLVM static libraries",
) orelse blk: {
    // Try well-known paths
    break :blk detectLlvmLibPath() orelse
        @panic("LLVM lib path required: pass -Dllvm-lib-path=...");
};
addLlvmLibs(exe, llvm_lib_path);
```

**Build command simplifies to:**
```bash
zig build -Dllvm-lib-path=$HOME/llvm-20-native/lib
# Produces: zig-out/bin/zap (single binary, ~100MB+)
```

---

## Phase 5: Build System and Distribution

### 5.1 — Streamline the Zig fork build

Create a build script that builds `libzig_compiler.a` from the fork with the
correct options.

**File to create:** `scripts/build-zig-lib.sh`

```bash
#!/bin/bash
set -euo pipefail

ZIG_FORK="${1:-$HOME/projects/zig}"
LLVM_PREFIX="${2:-$HOME/llvm-20}"

echo "Building libzig_compiler.a from $ZIG_FORK..."

cd "$ZIG_FORK"

# Ensure cmake config exists
if [ ! -f build/config.h ]; then
    echo "Running cmake to generate config.h..."
    mkdir -p build && cd build
    cmake .. -DCMAKE_PREFIX_PATH="$LLVM_PREFIX" -GNinja
    cd ..
fi

# Build the library
zig build lib -Denable-llvm -Dstatic-llvm -Dconfig_h=build/config.h

echo "Built: $ZIG_FORK/zig-out/lib/libzig_compiler.a"
ls -lh "$ZIG_FORK/zig-out/lib/libzig_compiler.a"
```

### 5.2 — Create distribution packaging script

**File to create:** `scripts/dist.sh`

```bash
#!/bin/bash
set -euo pipefail

VERSION="${1:-dev}"
ARCH="$(uname -m)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
DIST="zap-${VERSION}-${ARCH}-${OS}"

echo "Building Zap distribution: $DIST"

# Step 1: Build the binary
zig build -Doptimize=ReleaseFast -Dllvm-lib-path="${LLVM_LIB_PATH:-$HOME/llvm-20-native/lib}"

# Step 2: Create distribution directory
rm -rf "dist/$DIST"
mkdir -p "dist/$DIST/bin"
cp zig-out/bin/zap "dist/$DIST/bin/"

# Step 3: Bundle Zig lib directory
./scripts/bundle-lib.sh "$HOME/projects/zig" "dist/$DIST/lib/zig"

# Step 4: Create tarball
cd dist
tar czf "$DIST.tar.gz" "$DIST"
echo "Distribution: dist/$DIST.tar.gz ($(du -sh "$DIST.tar.gz" | cut -f1))"
```

### 5.3 — Add `build.zig` install step for lib directory

When running `zig build install`, also install the bundled lib:

```zig
// In build.zig:
const install_lib = b.addInstallDirectory(.{
    .source_dir = .{ .cwd_relative = "dist/lib/zig" },
    .install_dir = .lib,
    .install_subdir = "zig",
});
b.getInstallStep().dependOn(&install_lib.step);
```

---

## Phase 6: Multi-File Compilation

Currently the ZIR pipeline only compiles a single `main` function. Real Zap
programs have multiple modules and functions.

### 6.1 — Emit all functions from IR program

The `ZirDriver.buildProgram()` already iterates all functions:
```zig
pub fn buildProgram(self: *ZirDriver, program: ir.Program) !void {
    for (program.functions) |func| {
        try self.emitFunction(func);
    }
}
```

**Verify:** This works for multi-function programs by testing:
```
def add(a, b) do a + b end
def main() do Kernel.println(add(20, 22)) end
```

If functions beyond `main` are not emitted as declarations in the ZIR root
struct, the fork's `zir_builder.zig` `endFunction()` must be checked — each
function needs its own `declaration` entry in the root struct_decl.

### 6.2 — Multi-module compilation

For programs split across multiple `.zap` files, each module needs its own
ZIR compilation unit or be merged into a single unit.

**Approach:** Compile all `.zap` files in a project into a single ZIR
compilation unit. The collector and macro engine already handle multi-file
discovery. The IR program already contains all functions from all modules.

**Verify:** The existing `buildProgram()` handles this if `ir_program.functions`
contains functions from all modules.

### 6.3 — Handle `@import` across Zap modules

If Zap modules need to reference each other via `@import`, each module needs
to be registered as a separate compilation module via
`zir_compilation_add_module()` or `zir_compilation_add_module_source()`.

**Design decision needed:** Do Zap modules map 1:1 to Zig modules, or does
the Zap compiler merge everything into one Zig module?

- **Single module (recommended for now):** All Zap code compiles to one ZIR
  unit. Internal function calls use `decl_val` within the same struct. Simpler,
  sufficient for most programs.
- **Multi-module (future):** Each Zap module becomes a separate Zig module.
  Requires module dependency graph in `zir_compilation_add_module()`.

---

## Phase 7: Cross-Compilation Support

Currently `zir_compilation_create()` in the fork hardcodes the native target.

### 7.1 — Add target triple to compilation API

**Files to modify:**

| File | Change |
|------|--------|
| `~/projects/zig/src/zir_api.zig` | Add `target` parameter to `zir_compilation_create()` or add `zir_compilation_set_target(ctx, triple)` |
| `~/projects/zap/src/zir_compile.zig` | Pass `--target` flag through to compilation context |

**Implementation:**
```c
// Option A: Add to create
ZirContext* zir_compilation_create(
    const char* zig_lib_dir,
    const char* local_cache_dir,
    const char* global_cache_dir,
    const char* output_path,
    const char* root_name,
    const char* target_triple  // NEW: null = native
);

// Option B: Separate call
int zir_compilation_set_target(ZirContext* ctx, const char* triple);
```

**Targets to support:**
- `aarch64-macos` (current default)
- `x86_64-linux-gnu`
- `x86_64-macos`
- `aarch64-linux-gnu`
- `wasm32-wasi` (works without LLVM)

### 7.2 — Add `--target` flag to Zap CLI

```
zap build --target x86_64-linux-gnu examples/hello.zap
```

---

## Phase 8: Testing Strategy

### 8.1 — ZIR integration test suite

Create a test suite that compiles Zap programs via ZIR and verifies the output
binary produces correct results.

**File to create:** `src/zir_integration_tests.zig`

**Test structure:**
```zig
fn compileAndRun(source: []const u8, expected_output: []const u8) !void {
    // 1. Run Zap frontend pipeline on source
    // 2. Build ZIR via C-ABI
    // 3. Inject and compile to temp binary
    // 4. Execute binary, capture stdout
    // 5. Assert output matches expected
}

test "ZIR: hello world" {
    try compileAndRun(
        \\def main() do
        \\  Kernel.println("hello")
        \\end
    , "hello\n");
}

test "ZIR: arithmetic" {
    try compileAndRun(
        \\def main() do
        \\  Kernel.println(20 + 22)
        \\end
    , "42\n");
}

test "ZIR: multi-function" { ... }
test "ZIR: pattern matching" { ... }
test "ZIR: closures" { ... }
test "ZIR: binary patterns" { ... }
test "ZIR: field mutation" { ... }  // After Phase 1.1
test "ZIR: optional unwrap" { ... }  // After Phase 1.2
test "ZIR: ARC allocation" { ... }  // After Phase 1.3
```

### 8.2 — Regression test: text codegen parity

Ensure every test in `src/integration_tests.zig` that compiles successfully
via text codegen also compiles and produces the same result via ZIR.

**Approach:** Extract test programs from integration_tests.zig, compile each
via both paths, diff the binary outputs.

### 8.3 — Build system test

Verify the full distribution works:
```bash
# Build distribution
./scripts/dist.sh test

# Extract to clean location
cd /tmp && tar xzf /path/to/zap-test-*.tar.gz

# Verify compilation without any Zig installation
unset ZIG_LIB_DIR
export PATH="/tmp/zap-test-aarch64-macos/bin:$PATH"
echo 'def main() do Kernel.println(42) end' > /tmp/test.zap
zap run /tmp/test.zap
# Expected output: 42
```

---

## Phase 9: Cleanup and Polish

### 9.1 — Remove legacy text codegen as default

Once ZIR backend is validated across all test programs:
- Remove `codegen.zig` from the default build (keep as optional debug tool)
- Remove `.zap-cache/` write logic from the default path
- Remove `zig build` subprocess invocation from main.zig

### 9.2 — Update `zir-plan.md`

Replace `zir-plan.md` with this plan or archive it. The original plan's phases
are complete — its "What's broken" section is stale.

### 9.3 — Update README.md

- Installation instructions: download tarball, add `bin/` to PATH
- Remove requirement for external Zig installation
- Document `ZAP_ZIG_LIB_DIR` environment variable
- Document `--zig-lib-dir` flag for custom stdlib location
- Document `--emit-zig` debug flag

### 9.4 — Error messages and diagnostics

Improve error reporting for common failure modes:
- "Cannot find Zig lib directory — set ZAP_ZIG_LIB_DIR or pass --zig-lib-dir"
- "Compilation failed" → print Zig error bundle with source locations
- "ZIR injection failed" → suggest `--emit-zig` for debugging

---

## Implementation Order

```
Phase 1.1  field_ptr + store C-ABI          (1-2 days)
Phase 1.2  is_non_null + optional_payload   (1-2 days)
Phase 1.3  alloc_owned runtime helper       (1 day)
    ↓
Phase 3.1  In-memory module source API      (1 day)
Phase 3.2  Embed runtime in binary          (0.5 day)
    ↓
Phase 2.1  Bundle Zig lib/ directory        (0.5 day)
Phase 2.2  Lib directory discovery          (1 day)
    ↓
Phase 4.1  ZIR as default backend           (1 day)
Phase 4.2  Restructure main.zig             (1-2 days)
Phase 4.3  Keep --emit-zig debug flag       (0.5 day)
Phase 4.4  zap run with ZIR                 (0.5 day)
Phase 4.5  Update build.zig                 (1 day)
    ↓
Phase 5    Build/distribution scripts       (1 day)
Phase 6    Multi-file verification          (1-2 days)
Phase 8    Testing                          (2-3 days)
Phase 9    Cleanup and polish               (1-2 days)
    ↓
Phase 7    Cross-compilation (future)       (2-3 days)
```

**Critical path:** Phases 3 → 2 → 4 are the core of "single binary."
Phase 1 fixes real bugs but doesn't block the architectural goal.
Phase 7 is future work — native target is sufficient for initial release.

---

## File Change Summary

### Zig Fork (`~/projects/zig`)

| File | Action | Phase |
|------|--------|-------|
| `src/zir_builder.zig` | Add `addFieldPtr`, `addStore`, `addIsNonNull`, `addOptionalPayloadSafe` | 1.1, 1.2 |
| `src/zir_api.zig` | Add 5 C-ABI exports: `field_ptr`, `store`, `is_non_null`, `optional_payload`, `add_module_source` | 1.1, 1.2, 3.1 |

### Zap (`~/projects/zap`)

| File | Action | Phase |
|------|--------|-------|
| `src/zir_builder.zig` | Add 5 extern declarations; rewrite `field_set`, `optional_unwrap`, `alloc_owned` handlers | 1.1, 1.2, 1.3 |
| `src/runtime.zig` | Add `ArcRuntime.allocAny` helper | 1.3 |
| `src/zir_backend.zig` | Extend `detectZigLibDir()` with exe-relative search and env var | 2.2 |
| `src/zir_compile.zig` | **Delete** — absorbed into main.zig | 4.2 |
| `src/main.zig` | Replace text codegen default with ZIR backend; keep `--emit-zig` | 4.2, 4.3 |
| `build.zig` | Remove conditional ZIR backend; always link libzig_compiler.a | 4.5 |
| `scripts/build-zig-lib.sh` | **New** — builds libzig_compiler.a from fork | 5.1 |
| `scripts/bundle-lib.sh` | **New** — copies/strips Zig lib/ for distribution | 2.1 |
| `scripts/dist.sh` | **New** — creates release tarball | 5.2 |
| `src/zir_integration_tests.zig` | **New** — end-to-end ZIR compilation tests | 8.1 |
| `zir-plan.md` | **Archive/delete** — superseded by this plan | 9.2 |
