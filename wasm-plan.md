# WASM Compilation Plan: Filesystem Adapter

## Goal

Compile Zap programs to WebAssembly without any divergent compilation paths. The compiler uses a single filesystem interface for all file operations. On native platforms, this interface delegates to the OS filesystem. On WASM, it serves files from an in-memory virtual filesystem pre-populated at compile time.

## Architecture

### Filesystem Adapter Interface

All file I/O in the compiler flows through a `FileSystem` adapter. The adapter has two implementations:

1. **NativeFS** — delegates to `std.Io.Dir`, `std.Io.File`, and OS-level operations. Used on macOS, Linux, and other native targets.

2. **VirtualFS** — serves files from an in-memory tree. Files are pre-populated at build time from the project's source tree. No OS filesystem access. Used on WASM.

The compiler never calls `std.Io.Dir.cwd()` directly. Every file read, directory scan, file existence check, and path resolution goes through the adapter.

### Adapter API

```
FileSystem
  readFile(path) -> []const u8
  writeFile(path, content) -> void
  access(path) -> bool
  openDir(path) -> DirHandle
  iterate(dir) -> Iterator
  realPath(path) -> []const u8
  createDirPath(path) -> void
  rename(from, to) -> void
  stat(path) -> Stat
```

The API mirrors the subset of `std.Io.Dir` and `std.Io.File` that the compiler actually uses. No extra abstraction — just the operations Zap needs.

### VirtualFS Pre-Population

For WASM builds, the VirtualFS is populated at Zig compile time using `@embedFile`:

1. The build system (build.zig) collects all `.zap` source files from the project and its dependencies.
2. Each file's path and content are embedded into the binary as comptime data.
3. At runtime initialization, the VirtualFS builds an in-memory tree from the embedded data.
4. The compiler reads from this tree identically to how it would read from disk.

This means the WASM binary is fully self-contained — no file system access, no network requests, no WASI fd_open calls for source files.

### Where the Adapter Is Used

Every file access point in the compiler must go through the adapter. Current direct filesystem calls that need migration:

**Source file reading (main.zig):**
- `std.Io.Dir.cwd().readFileAlloc` for build.zap
- `compiler.mmapSourceFile` for source units
- `std.Io.Dir.cwd().access` for file existence checks

**Discovery (discovery.zig):**
- `std.Io.Dir.cwd().readFileAlloc` for scanning source files
- `std.Io.Dir.cwd().access` for struct resolution

**Cache (main.zig):**
- `.zap-cache/` directory: hash files, compilation artifacts
- On WASM, caching can be in-memory or disabled

**Lockfile (lockfile.zig):**
- Reading/writing `zap.lock`
- Git dependency fetching (not applicable on WASM)

**Zig lib dir (zir_backend.zig, main.zig):**
- Detecting and reading the Zig standard library
- On WASM, the Zig stdlib is embedded via `zig_lib_archive`

**Watch mode (main.zig):**
- File mtime polling for `--watch`
- Not applicable on WASM

### Adapter Selection

The adapter is selected at compile time via `comptime`:

```zig
const FileSystem = if (builtin.os.tag == .wasi or builtin.cpu.arch == .wasm32)
    VirtualFS
else
    NativeFS;
```

No runtime branching. The compiler is monomorphized for the target platform. On native, the `VirtualFS` code is never compiled. On WASM, the `NativeFS` code is never compiled.

### Runtime Considerations

The Zap runtime (`src/runtime.zig`) also uses filesystem operations:

- `Prelude.file_read` / `Prelude.file_write` / `Prelude.file_exists` — these are user-facing Zap functions (`File.read`, `File.write`, `File.exists`). On WASM, these should go through the VirtualFS adapter.
- `stdoutWrite` / `stdoutPrint` — stdout on WASM can use WASI's `fd_write` or be buffered to a JavaScript callback.
- `getArgv` — WASI provides `args_get`. The existing `else` branch returns empty, which is safe.
- `getenv` — WASI provides `environ_get`. The existing `env.zig` wrapper handles this.

### Build System Integration

For a WASM build, the user runs:

```sh
zap build --target wasm32-wasi
```

The build system:
1. Discovers all source files via the import graph (already working)
2. Embeds them into the binary via `@embedFile` or a tar archive
3. Compiles the runtime with WASI-compatible implementations
4. Produces a `.wasm` binary

The resulting `.wasm` can run in:
- **wasmtime/wasmer** — full WASI runtime, stdout works, args work
- **Browser** — via a JavaScript shim that provides fd_write, args, etc.

### Implementation Order

1. **Define the FileSystem adapter interface** in a new `src/fs.zig` struct
2. **Implement NativeFS** — thin wrapper around `std.Io.Dir` operations
3. **Migrate all direct filesystem calls** in main.zig, discovery.zig, lockfile.zig, zir_backend.zig, and runtime.zig to use the adapter
4. **Implement VirtualFS** — in-memory tree with comptime-populated data
5. **Update build.zig** to embed source files for WASM targets
6. **Fix WASM output path** — add `.wasm` extension for WASM targets
7. **Fix the fork's WASM linker** — investigate why `zir_compilation_update` succeeds but doesn't produce output
8. **Test with wasmtime** — verify the `.wasm` binary runs correctly

### Non-Goals

- **Browser runtime** — out of scope for initial WASM support. WASI is the target.
- **Network filesystem** — the adapter is for local/embedded files only.
- **Hot reloading on WASM** — watch mode is native-only.
- **Divergent compilation paths** — the compiler has ONE path. The adapter is the only difference.
