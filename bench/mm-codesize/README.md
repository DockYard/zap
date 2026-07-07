# E4 — manager-monomorphization code size (P3-J2)

`e4_mm_codesize.zap` is the E4 gate probe: a spawn-reachable-shaped allocating
subgraph (`driver → build_list → build_list_from → sum_list → sum_from`). A model
specialization emits/elides header ops (retain/release/free) per reclamation
model while keeping the body identical, so compiling this same source under
different manifest managers reproduces exactly what a specialization emits.

## Reproduce

```sh
export XDG_CACHE_HOME=$(mktemp -d)          # isolate the script cache
ZAP=./zig-out/bin/zap

# REFCOUNTED (ARC) vs BULK_OR_NEVER (Arena) emission of the same subgraph:
$ZAP run -Dmemory=Memory.ARC   -Doptimize=ReleaseFast bench/mm-codesize/e4_mm_codesize.zap
$ZAP run -Dmemory=Memory.Arena -Doptimize=ReleaseFast bench/mm-codesize/e4_mm_codesize.zap

# __TEXT,__text per build (find the two cached `script` binaries under
# $XDG_CACHE_HOME/zap/scripts/*/script):
size -m <binary> | grep __text

# Per-function sizes (use -O Debug so functions stay distinct), via
# `nm -n <binary>` sorted-address deltas.
```

Full numbers, the 1/2/4-model post-ICF projection, the Darwin-ICF caveat, and the
verdict are in `docs/concurrency-bench-results.md` § "E4 — manager-monomorphization
code size". The whole-program `__text` delta (ARC vs Arena, ReleaseFast) is
+3,692 B (+1.65%); the isolated spawn-reachable user subgraph delta is 536 B, of
which the two allocating functions are byte-identical (ICF-foldable to ×1).
