# Diagnosing `error.OutOfMemory` During Zig Mach-O Linking When Parsing `libSystem.tbd`

## Background and symptom profile

Your compile pipeline successfully reaches code generation, then fails inside Zig’s Mach-O link step while processing the Darwin system library stub (`libSystem.tbd`). The most important forensic detail is that codegen completes and the failure occurs after Zig transitions into its linker “flush” work (i.e., after the `.o` is emitted and the linker begins consuming inputs). This aligns with Zig’s architecture: for Mach-O outputs, Zig’s linker must classify input files (object, archive, dylib, or text-based stub) and then parse them to build the final image. citeturn20view0turn28view0

Two characteristics you highlighted are especially diagnostic:

- The failure is signaled as `error.OutOfMemory`.
- The error bundle ends up empty (no human-readable linker diagnostics).

In Zig, both of these can happen even when the *machine* has free RAM, because `error.OutOfMemory` is (a) used when an allocator reports allocation failure and (b) can be triggered by OS-level “out of memory” conditions that are not “physical RAM exhausted” (e.g., virtual memory mapping limits), and because Zig’s linker diagnostics system intentionally sets a flag when it cannot allocate memory for error reporting—yielding an “empty” error list that still represents a real allocation failure. citeturn32view0turn29search4

## How Zig’s Mach-O linker actually reaches `libSystem.tbd`

### `libSystem` discovery and why `.tbd` is encountered

In Zig’s Mach-O pipeline, `libSystem` is treated as a system dependency that must be located and added to the link inputs. The code path that resolves `libSystem` explicitly probes for `libSystem` in library search directories using the extensions `.tbd`, `.dylib`, and also the bare name (no extension). citeturn20view0turn19view2

Apple’s `.tbd` files are “text-based stub libraries” (a compact representation of dylib interfaces, used in SDKs), and they are YAML-like in structure. This is well-established in ecosystem documentation and in Zig’s own bug reports about `.tbd` YAML parsing behavior. citeturn10search12turn13view0

### “Classifying input file … libSystem.tbd” is not the same as parsing it

In Zig’s Mach-O linker, the string `classifying input file {path}` is produced by `MachO.classifyInputFile`. That function identifies the file type by reading a Mach-O header, or an archive magic, and if neither matches it treats the input as a `.tbd` stub and registers it as such. Importantly, this step does **not** do full `.tbd` YAML parsing; it merely decides “this is a TBD-like thing” if it is not an object/archive/dylib. citeturn20view0turn19view0

So, if your logs stop at:

> classifying input file … libSystem.tbd

…the actual allocation failure might still be occurring immediately *afterward*, when the `.tbd` is parsed into typed structures and its exports are loaded into linker state.

### Where `.tbd` parsing and export ingestion happen

For Mach-O dylib entries tagged as `.tbd`, Zig’s linker uses the `tapi` (“text-based API”) subsystem to load and parse the stub. The flow (as implemented in Zig’s Mach-O dylib parser) is:

- `Dylib.parseTbd` calls `LibStub.loadFromFile(gpa, file)`
- `LibStub.loadFromFile` reads the entire file into a buffer, YAML-loads it, then tries to parse it as Tbd v4/v3 shapes
- `Dylib.parseTbd` iterates `exports`/`reexports` blocks and calls `addExport` for each symbol, building the dylib export set used for symbol resolution citeturn28view0turn15view0

This stage is where a large number of allocations can occur: the YAML representation, typed node allocation (often arena-backed), conversion/duplication of strings/arrays, and then linker export table population.

## Why `error.OutOfMemory` can look “spurious” and why diagnostics can be empty

### Zig linker diagnostics treat allocation failure specially

Zig’s linker keeps diagnostics in a `Diags` structure. It includes a `Flags` bitfield with `alloc_failure_occurred`. When an error message would require allocation and that allocation fails, Zig sets the alloc-failure flag (logging “memory allocation failure”) rather than attempting to allocate more error strings. citeturn31view0turn32view0

This means an end state like “no messages, but link failed” is consistent with:

1. An allocation failure occurs (for any reason).
2. The linker attempts to report it (or report something else) but can’t allocate storage for the diagnostic.
3. The diagnostics system flips `alloc_failure_occurred` and subsequent reporting is suppressed or becomes no-ops. citeturn32view0turn31view0

In practical terms: an empty error bundle does **not** imply the linker had “no idea what happened.” It can mean “we ran out of allocatable memory (or the allocator returned OOM) and couldn’t even allocate the diagnostic text.”

### “Out of memory” does not necessarily mean “RAM exhausted”

You already identified one classic Zig-shaped pitfall: allocator calls can return `error.OutOfMemory` due to OS resource limits that are *not* overall physical memory exhaustion.

A canonical example is when allocations are backed by `mmap` and the process hits a kernel limit on the number of memory mappings; the Zig issue about this behavior explains how `mmap` can return `ENOMEM` when “maximum number of mappings would have been exceeded,” which then surfaces as `error.OutOfMemory`. citeturn29search4

While your current host is macOS and your earlier fix replaced a `page_allocator`-heavy pattern, the general lesson remains: `error.OutOfMemory` often means “the allocator failed,” and the allocator can fail for constraints other than “machine lacks RAM.” citeturn29search4

## Plausible root causes that are specific to `.tbd` parsing and `libSystem.tbd`

### A file-stat failure can trigger a gigantic allocation attempt

One code pattern inside `LibStub.loadFromFile` is particularly high-risk:

- It tries `file.stat()`.
- If `stat` fails, it falls back to using `std.math.maxInt(u32)` as a “filesize.”
- It then allocates a buffer of `filesize` and tries to `preadAll` into it. citeturn15view0

If `file.stat()` fails for any reason (bad file descriptor, transient OS error, being handed a non-regular file, etc.), Zig will attempt to allocate ~4 GiB (`maxInt(u32)` bytes), which is very likely to fail quickly and return `error.OutOfMemory` even on systems with plenty of free RAM (especially if the process address space is constrained or memory is fragmented). citeturn15view0

This is a strong candidate because it produces *exactly* the “spurious OOM” shape you described: fast failure, not correlated with actual compilation scale, and potentially no diagnostic text (because reporting may allocate too). citeturn32view0turn28view0

What would make `stat()` fail here?

- A closed/invalid file handle being stored and later reused when parsing stubs (especially plausible in custom embedding/fork scenarios where lifetime rules differ).
- Hitting a per-process file descriptor limit or other OS resource exhaustion such that `stat` fails intermittently.
- Passing a handle that is not a “real file” in the way `stat` expects (less likely on macOS for SDK files, but still possible in bespoke file-handle abstractions). citeturn15view0

### Legitimate high allocation volume in YAML + export ingestion

Even if `stat()` succeeds, the `.tbd` parse flow reads the whole file, loads it into a YAML representation, parses it into typed structures, then iterates and appends exports. citeturn15view0turn28view0

This can be memory-intensive if:

- The YAML loader duplicates large amounts of data (strings, scalar values).
- `libSystem.tbd` is large and includes many targets/architectures, and the matcher mistakenly admits more blocks than intended (multiplying exports ingested).
- Exports are not deduplicated and the same symbol list appears in multiple blocks that all pass the target filter, causing repeated insertion attempts. citeturn28view0turn27view0

Zig’s Mach-O dylib `.tbd` code contains notable compatibility logic that hints at format variation across macOS eras, including changes in target tags (`macosx` → `macos`) and special cases like “zippered” platform tags. This is useful context because it shows the matcher is intentionally permissive in some paths to support older SDK variants—permissiveness that can also broaden the matching surface if assumptions don’t line up with what’s in a specific SDK’s stub. citeturn27view0

### YAML edge cases are a known source of `.tbd` trouble in Zig

Zig has historically had `.tbd` failures attributable to YAML parsing limitations. One concrete example: `.tbd` YAML with valid-but-unindented lists was not handled by Zig’s `.tbd` YAML parser, yielding “unknown filetype” / parse failures until the YAML handling was improved. citeturn13view0

Separately, there are still modern reports of `.tbd` parse failures (e.g., `UnexpectedToken`) under certain build configurations, demonstrating that `.tbd` parsing remains a correctness-sensitive component. citeturn14search5

While these examples are not “OOM,” they support the broader conclusion: `.tbd` parsing is complex, format-variant, and a plausible locus for bugs that can lead to runaway allocation or pathological behavior. citeturn13view0turn14search5

## A diagnostic strategy that maximizes signal with minimal changes

### Determine whether you are in “alloc failure diagnostics mode”

Before assuming the OOM is “spurious,” explicitly check whether Zig’s linker diagnostics are recording an allocation failure flag. The `Diags` structure has `flags.alloc_failure_occurred` specifically for this purpose. If it is set, it explains the “0 messages” outcome and reframes the issue as “some allocation failed, and error reporting also couldn’t allocate.” citeturn32view0turn31view0

### Confirm whether parsing reaches `parseTbd` (not just classification)

`classifying input file …` comes from `MachO.classifyInputFile`. Actual `.tbd` parsing begins later and logs the stub parse as `parsing dylib from stub: {path}`. If you can enable/see that log line, you can disambiguate:

- If you **never** see `parsing dylib from stub`, focus on what happens between classification and parse dispatch (file handle storage, queueing, and parse scheduling).
- If you **do** see it and then OOM, focus on `LibStub.loadFromFile` and the YAML/export ingestion path. citeturn20view0turn28view0

### Instrument the single highest-risk branch: the `stat()` fallback in `LibStub.loadFromFile`

Given the 4 GiB fallback behavior, a minimal, high-leverage instrumentation is:

- Log the error from `file.stat()` if it fails.
- Log the resulting chosen `filesize` value.
- Short-circuit: if `stat()` fails, return an I/O error rather than allocating `maxInt(u32)`.

This transforms a confusing OOM into a specific I/O failure with a concrete errno-like root cause (EBADF, permission issues, etc.). Such a change is strongly justified because “assume 4 GiB” is not a safe fallback in real systems. citeturn15view0turn32view0

### Validate whether target matching is over-admitting export blocks

Because `.tbd` export ingestion loops over all documents/blocks and includes those that match the target filter, one debugging approach is to log:

- How many `lib_stub.inner` documents exist
- Which ones match `matchesTargetTbd`
- How many total symbols are being appended

This helps test the hypothesis that the matcher is accidentally including many non-host-target export lists. The existence of special-case logic for historical macOS target tags and “zippered” platforms makes this a realistic failure mode when SDKs differ from expectations. citeturn27view0turn28view0

### Use a linker-path workaround to isolate `.tbd` parsing

If available in your Zig build, using the system linker (Apple `ld64`) can isolate whether the problem is in Zig’s self-hosted `.tbd` parsing/linking stack versus elsewhere in your pipeline. Historically, Zig has had a mode to invoke the system linker on macOS via an environment variable (`ZIG_SYSTEM_LINKER_HACK`) rather than using its own link implementation. citeturn11search32

Even if this mechanism has changed in newer Zig versions, the general experimental idea remains useful: pick a configuration that bypasses Zig’s `.tbd` YAML parser and see whether the OOM disappears. citeturn13view0turn14search1

## Implications for your ZIR injection pipeline

The evidence you provided that LLVM codegen completes, plus the fact that the failure is triggered during system library processing, suggests the ZIR injection itself is *not* the direct cause—at least not in the “your generated IR is malformed” sense. In Zig’s Mach-O flow, the `.tbd` parsing and system library resolution are mostly orthogonal to how the root module was produced; they are driven by target configuration and link setup (e.g., “resolve libSystem”). citeturn20view0turn28view0

However, ZIR injection (and any custom embedding) can still influence this problem indirectly by altering:

- Resource lifetimes (especially file handle lifetimes) in the `Compilation` wrapper.
- Allocator selection and allocator lifetime (e.g., using an allocator that is prematurely torn down or wrapped in ways that make some allocations fail).
- Concurrency and scheduling in the link phase.

The “4 GiB allocation on stat failure” pattern is particularly compatible with a lifetime bug: an invalid handle causes `stat()` to fail, which triggers the catastrophic fallback. citeturn15view0turn32view0
