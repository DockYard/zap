# Zap benchmarks

Single-thread micro-benchmarks comparing Zap against peer native compilers
(C / Rust / Zig). Each benchmark lives in `bench/<benchmark>/<lang>/` as a
self-contained source tree. The harness builds every implementation in
release mode, runs each `RUNS` times, validates byte-identical output
against the C reference, and emits a JSON results file plus an HTML
report.

## What's covered

| benchmark      | exercises                                                          |
|----------------|--------------------------------------------------------------------|
| `binary-trees` | recursive struct construction (heap-promote), multi-clause `nil/T` dispatch, indirect-storage field auto-deref |

The Zap implementations rely on codegen paths that landed in the recent
recursive-struct + loopification work — `FieldStorage.indirect`,
`ArcRuntime.allocAny` heap promotion, optional dispatch, and the SCC
recursion analysis. Each peer (C, Rust, Zig) uses the same arena
allocator strategy so timing comparisons stay focused on the language
rather than free-list contention.

## Running

```sh
# defaults: depth 18, 3 runs per implementation
bench/run.sh

# explicit:
bench/run.sh 21 5

# render HTML from every JSON under bench/results/
bench/render.sh
open bench/results/index.html
```

`run.sh` honours these env vars:

* `ZAP`   — path to the `zap` binary (default: `zig-out/bin/zap`).
* `ZIG`   — path to a Zig 0.16 compiler (default: `zig` on `$PATH`).
* `CARGO` — path to `cargo` (default: `cargo`).
* `CC`    — C compiler (default: `clang`).

## Output validation

Before timing any run, the harness diffs every implementation's stdout
against the C reference. A divergence aborts the harness — a "fast but
wrong" implementation can't claim a win. The reference output for
binary-trees follows the Computer Language Benchmarks Game format:

```
stretch tree of depth N+1	 check: ...
2^(N-d+4)	 trees of depth d	 check: ...
...
long lived tree of depth N	 check: ...
```

## Adding a new benchmark

1. Create `bench/<name>/{c,rust,zig,zap}/` with a self-contained
   implementation in each language. All four must read `BENCH_DEPTH`
   (or whatever input parameter the benchmark needs) the same way.
2. Add build + run blocks to `run.sh` mirroring the existing
   binary-trees flow.
3. Add a row to the table above documenting which codegen paths the
   benchmark exercises.
