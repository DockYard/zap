#!/usr/bin/env bash
# CLBG baseline snapshot for the Zap concurrency campaign (job S0.1).
# Zap-only rows (ARC + Arena), same sizes and acquisition protocol as
# ~/projects/lang-benches/scripts/run-all.sh, but timing only the Zap
# binaries since this is a Zap-vs-future-Zap baseline (E2 reference).
set -euo pipefail

LB=/Users/bcardarella/projects/lang-benches
OUT="$1"   # output dir for hyperfine JSON
mkdir -p "$OUT"

# Fresh, isolated script cache: `zap run`'s content-addressed cache is
# NOT keyed on the compiler binary, so a stale cache could silently
# resolve binaries produced by an older compiler. A fresh
# XDG_CACHE_HOME guarantees every binary below was compiled by the
# just-built HEAD compiler.
export XDG_CACHE_HOME="$OUT/xdg-cache"
mkdir -p "$XDG_CACHE_HOME"

export ZAP_BIN=/Users/bcardarella/projects/zap/zig-out/bin/zap
# shellcheck source=/dev/null
source "$LB/scripts/zap-script-bin.sh"

WARMUPS=2
RUNS=10

run_bench() {
  local bench_dir="$1" source_file="$2" json_name="$3"; shift 3
  # Remaining args: either "<N>" (argv bench) or "--stdin <fixture>".
  local -a resolve_spec=("$@")
  local suffix
  if [[ "${1:-}" == "--stdin" ]]; then
    suffix="< $2 > /dev/null"
  else
    suffix="$1 > /dev/null"
  fi

  echo "=== $json_name ==="
  local zbin_arc zbin_arena
  zbin_arc="$(resolve_zap_script_binary "$bench_dir" "$source_file" "Memory.ARC" "${resolve_spec[@]}")"
  zbin_arena="$(resolve_zap_script_binary "$bench_dir" "$source_file" "Memory.Arena" "${resolve_spec[@]}")"
  echo "  ARC   binary: $zbin_arc"
  echo "  Arena binary: $zbin_arena"

  ( cd "$bench_dir" && hyperfine \
      --warmup "$WARMUPS" --runs "$RUNS" \
      --export-json "$OUT/$json_name.json" \
      --command-name "Zap (ARC)"   "$zbin_arc $suffix" \
      --command-name "Zap (Arena)" "$zbin_arena $suffix" )
}

run_bench "$LB/nbody"          nbody.zap          nbody          5000000
run_bench "$LB/mandelbrot"     mandelbrot.zap     mandelbrot     8000
run_bench "$LB/binarytrees"    binarytrees.zap    binarytrees    21
run_bench "$LB/fannkuch-redux" fannkuch_redux.zap fannkuch-redux 11
run_bench "$LB/spectral-norm"  spectral_norm.zap  spectral-norm  2500
run_bench "$LB/k-nucleotide"   k_nucleotide.zap   k-nucleotide   --stdin input.fasta

echo "All baseline runs complete: $OUT"
