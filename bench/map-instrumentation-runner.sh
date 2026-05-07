#!/usr/bin/env bash
# ============================================================================
# map-instrumentation-runner.sh
#
# Phase B2 of docs/map-workload-instrumentation-plan.md.
#
# Drives the instrumented `zap` toolchain across every workload listed in
# §7 of the plan, capturing one map-instrumentation.json per workload into
# bench/map-instrumentation-data/. Builds a STATUS.md describing what ran,
# what got skipped, and why.
#
# After the per-workload sweep completes, runs the Phase B3 aggregator
# against the harvested JSONs to produce aggregate.{json,md}.
#
# This script is idempotent: re-running it cleans the per-workload
# zap-out / .zap-cache directories of every covered workload before
# rebuilding, so each run produces a fresh end-to-end measurement.
#
# ----------------------------------------------------------------------------
# Layout
# ----------------------------------------------------------------------------
#   ZAP_REPO   -- /Users/bcardarella/projects/zap
#   ZAP_BIN    -- $ZAP_REPO/zig-out/bin/zap (must be built with
#                 -Dinstrument-map=true ahead of time)
#   DATA_DIR   -- $ZAP_REPO/bench/map-instrumentation-data
#   STATUS_LOG -- $DATA_DIR/STATUS.md
#   LANG_BENCH -- ~/projects/lang-benches  (CLBG-style workloads)
#
# Each workload writes its summary to $DATA_DIR/<workload-name>.json. If a
# workload does not allocate any Map cells (very common for the small Zap
# example programs), no JSON is produced and we record `no-map-activity`
# as the status.
#
# Usage:
#   bench/map-instrumentation-runner.sh
#
# Exit code: 0 iff every workload either produced JSON or was correctly
# classified as `no-map-activity`/`skipped`. Non-zero only on
# infrastructure errors (missing instrumented binary, etc.).
# ============================================================================

set -uo pipefail

ZAP_REPO="/Users/bcardarella/projects/zap"
ZAP_BIN="$ZAP_REPO/zig-out/bin/zap"
DATA_DIR="$ZAP_REPO/bench/map-instrumentation-data"
STATUS_LOG="$DATA_DIR/STATUS.md"
LANG_BENCH="$HOME/projects/lang-benches"
AGGREGATOR="$ZAP_REPO/bench/map-instrumentation-aggregator.sh"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ ! -x "$ZAP_BIN" ]]; then
    echo "error: instrumented zap binary not found at $ZAP_BIN" >&2
    echo "       run 'zig build -Dinstrument-map=true' first" >&2
    exit 2
fi

# Use `grep -c` (counts then exits non-zero only on no match) to avoid
# the SIGPIPE-induced false negative we'd get from `grep -q` under
# `set -o pipefail` -- `grep -q` exits as soon as the first match lands,
# which closes the pipe and makes `strings` fail with SIGPIPE.
match_count=$(strings "$ZAP_BIN" 2>/dev/null | grep -c "INSTRUMENT_MAP_DEFAULT: bool = true" || true)
if [[ "${match_count:-0}" == "0" ]]; then
    echo "error: $ZAP_BIN does not contain the rewritten INSTRUMENT_MAP_DEFAULT" >&2
    echo "       rebuild with: zig build -Dinstrument-map=true" >&2
    exit 2
fi

mkdir -p "$DATA_DIR"

# Wipe stale per-workload outputs so the aggregator sees only this run's data.
# Keep fixtures/ (used by the aggregator's smoke tests) and the STATUS.md
# header we are about to overwrite. We do not preserve aggregate.{json,md}
# from a previous run because the aggregator regenerates them.
find "$DATA_DIR" -maxdepth 1 -type f \( -name "*.json" -o -name "*.jsonl" \) \
    ! -name "aggregate.json" -delete

# Begin a fresh STATUS.md.
{
    printf '# Phase B2 Map Workload Instrumentation Status\n\n'
    printf '_Run started: %s_\n\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'Instrumented zap binary: `%s`\n\n' "$ZAP_BIN"
    printf '| Workload | Status | Wall (s) | Instances | by_class S/W/V | Notes |\n'
    printf '| --- | --- | ---: | ---: | --- | --- |\n'
} > "$STATUS_LOG"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Append a row to the STATUS.md table.
record_status() {
    local name="$1" status="$2" wall_s="$3" instances="$4" by_class="$5" notes="$6"
    printf '| %s | %s | %s | %s | %s | %s |\n' \
        "$name" "$status" "$wall_s" "$instances" "$by_class" "$notes" >> "$STATUS_LOG"
}

# Validate a workload JSON file (jq must succeed on its summary fields).
# Returns 0 if valid; prints reason on stderr otherwise.
validate_json() {
    local file="$1"
    if ! jq -e '
        (.workload | type == "string")
        and (.summary | type == "object")
        and (.summary.total_instances | type == "number")
        and (.summary.by_class.S.count | type == "number")
        and (.summary.by_class.W.count | type == "number")
        and (.summary.by_class.V.count | type == "number")
    ' "$file" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Format the by_class S/W/V triple from a workload JSON.
extract_by_class() {
    local file="$1"
    jq -r '
        .summary.by_class as $c
        | "\($c.S.count)/\($c.W.count)/\($c.V.count)"
    ' "$file" 2>/dev/null
}

extract_total_instances() {
    local file="$1"
    jq -r '.summary.total_instances' "$file" 2>/dev/null
}

# Run a workload that builds via `zap build` then executes the resulting
# binary with optional stdin redirection and CLI args. Captures the JSON
# into $DATA_DIR/<output_name>.json.
#
# Args:
#   $1 friendly_name  -- e.g. "k-nucleotide"
#   $2 output_name    -- basename for the JSON file (no extension)
#   $3 work_dir       -- absolute path to the project (contains build.zap)
#   $4 target         -- zap build target name (e.g. "k_nucleotide")
#   $5 binary_name    -- name of the produced binary under zap-out/bin/
#   $6 stdin_file     -- absolute path to stdin file, or empty for none
#   $7 cli_args       -- additional CLI args (string, may be empty)
run_build_and_exec_workload() {
    local friendly_name="$1"
    local output_name="$2"
    local work_dir="$3"
    local target="$4"
    local binary_name="$5"
    local stdin_file="$6"
    local cli_args="$7"

    echo
    echo "=== $friendly_name ==="
    if [[ ! -d "$work_dir" ]]; then
        echo "  skip: work_dir missing: $work_dir"
        record_status "$friendly_name" "skipped" "0" "0" "0/0/0" "work_dir missing: $work_dir"
        return 0
    fi

    rm -rf "$work_dir/zap-out" "$work_dir/.zap-cache"

    local out_json="$DATA_DIR/$output_name.json"
    local build_log; build_log="$(mktemp)"
    local run_log;   run_log="$(mktemp)"

    # Build phase.
    local build_status=0
    ( cd "$work_dir" && "$ZAP_BIN" build "$target" ) > "$build_log" 2>&1 || build_status=$?
    if (( build_status != 0 )); then
        local err
        err="$(tail -n 5 "$build_log" | tr '\n' ' ' | sed 's/|/_/g')"
        echo "  build failed (exit $build_status): $err"
        record_status "$friendly_name" "build-failed" "0" "0" "0/0/0" "$err"
        rm -f "$build_log" "$run_log"
        return 0
    fi

    local bin_path="$work_dir/zap-out/bin/$binary_name"
    if [[ ! -x "$bin_path" ]]; then
        echo "  build produced no binary at $bin_path"
        record_status "$friendly_name" "build-failed" "0" "0" "0/0/0" "no binary at $bin_path"
        rm -f "$build_log" "$run_log"
        return 0
    fi

    # Run phase.
    local run_status=0
    local t0 t1 wall_s
    t0=$(date +%s)
    if [[ -n "$stdin_file" ]]; then
        if [[ -n "$cli_args" ]]; then
            ZAP_INSTRUMENT_OUT="$out_json" "$bin_path" $cli_args < "$stdin_file" > "$run_log" 2>&1 || run_status=$?
        else
            ZAP_INSTRUMENT_OUT="$out_json" "$bin_path"           < "$stdin_file" > "$run_log" 2>&1 || run_status=$?
        fi
    else
        if [[ -n "$cli_args" ]]; then
            ZAP_INSTRUMENT_OUT="$out_json" "$bin_path" $cli_args > "$run_log" 2>&1 || run_status=$?
        else
            ZAP_INSTRUMENT_OUT="$out_json" "$bin_path"           > "$run_log" 2>&1 || run_status=$?
        fi
    fi
    t1=$(date +%s)
    wall_s=$((t1 - t0))

    if (( run_status != 0 )); then
        local err
        err="$(tail -n 5 "$run_log" | tr '\n' ' ' | sed 's/|/_/g')"
        echo "  run failed (exit $run_status): $err"
        record_status "$friendly_name" "run-failed" "$wall_s" "0" "0/0/0" "exit=$run_status: $err"
        rm -f "$build_log" "$run_log"
        return 0
    fi

    if [[ ! -f "$out_json" ]]; then
        echo "  no JSON written -- workload allocated zero Map cells"
        record_status "$friendly_name" "no-map-activity" "$wall_s" "0" "0/0/0" "no Map allocations"
        rm -f "$build_log" "$run_log"
        return 0
    fi

    if ! validate_json "$out_json"; then
        echo "  produced JSON failed schema validation: $out_json"
        record_status "$friendly_name" "invalid-json" "$wall_s" "0" "0/0/0" "schema validation failed"
        rm -f "$build_log" "$run_log"
        return 0
    fi

    local instances by_class
    instances=$(extract_total_instances "$out_json")
    by_class=$(extract_by_class "$out_json")
    echo "  ok: instances=$instances by_class(S/W/V)=$by_class wall=${wall_s}s"
    record_status "$friendly_name" "ok" "$wall_s" "$instances" "$by_class" ""
    rm -f "$build_log" "$run_log"
    return 0
}

# Self-build workload: instrumented `zap build` IS the workload, exercising
# the host compiler's own Map usage. Run against the hello example so the
# work it does is bounded but realistic.
run_self_build_workload() {
    local friendly_name="selfbuild_compile_hello"
    local work_dir="$ZAP_REPO/examples/hello"
    local out_json="$DATA_DIR/$friendly_name.json"

    echo
    echo "=== $friendly_name ==="
    rm -rf "$work_dir/zap-out" "$work_dir/.zap-cache"

    local run_log; run_log="$(mktemp)"
    local t0 t1 wall_s run_status=0
    t0=$(date +%s)
    ( cd "$work_dir" && ZAP_INSTRUMENT_OUT="$out_json" "$ZAP_BIN" build hello ) \
        > "$run_log" 2>&1 || run_status=$?
    t1=$(date +%s)
    wall_s=$((t1 - t0))

    if (( run_status != 0 )); then
        local err; err="$(tail -n 5 "$run_log" | tr '\n' ' ' | sed 's/|/_/g')"
        echo "  build failed (exit $run_status): $err"
        record_status "$friendly_name" "build-failed" "$wall_s" "0" "0/0/0" "$err"
        rm -f "$run_log"
        return 0
    fi

    if [[ ! -f "$out_json" ]]; then
        echo "  no JSON written -- compile pipeline allocated zero Map cells"
        record_status "$friendly_name" "no-map-activity" "$wall_s" "0" "0/0/0" "compiler did not allocate Map cells"
        rm -f "$run_log"
        return 0
    fi

    if ! validate_json "$out_json"; then
        echo "  produced JSON failed schema validation: $out_json"
        record_status "$friendly_name" "invalid-json" "$wall_s" "0" "0/0/0" "schema validation failed"
        rm -f "$run_log"
        return 0
    fi

    local instances by_class
    instances=$(extract_total_instances "$out_json")
    by_class=$(extract_by_class "$out_json")
    echo "  ok: instances=$instances by_class(S/W/V)=$by_class wall=${wall_s}s"
    record_status "$friendly_name" "ok" "$wall_s" "$instances" "$by_class" ""
    rm -f "$run_log"
    return 0
}

# ---------------------------------------------------------------------------
# CLBG benchmarks (lang-benches)
# ---------------------------------------------------------------------------

run_build_and_exec_workload \
    "k-nucleotide" "k-nucleotide" \
    "$LANG_BENCH/k-nucleotide" "k_nucleotide" "k_nucleotide" \
    "$LANG_BENCH/k-nucleotide/input.fasta" ""

run_build_and_exec_workload \
    "fannkuch-redux" "fannkuch-redux" \
    "$LANG_BENCH/fannkuch-redux" "fannkuch_redux" "fannkuch_redux" \
    "" "10"

run_build_and_exec_workload \
    "spectral-norm" "spectral-norm" \
    "$LANG_BENCH/spectral-norm" "spectral_norm" "spectral_norm" \
    "" "500"

run_build_and_exec_workload \
    "binary-trees" "binary-trees" \
    "$LANG_BENCH/binarytrees" "binarytrees" "binarytrees" \
    "" "10"

# ---------------------------------------------------------------------------
# examples/*
# ---------------------------------------------------------------------------

# Skip examples/{deps,multifile,snake}? snake is interactive. multifile and
# deps build fine as bin targets. Skip snake explicitly because it requires
# a terminal.
declare -A EXAMPLE_TARGETS=(
    ["attributes"]="attributes"
    ["binary_patterns"]="binary_patterns"
    ["case_expr"]="case_expr"
    ["cli"]="cli"
    ["computed_attributes"]="computed_attributes"
    ["ctfe_basics"]="ctfe_basics"
    ["default_params"]="default_params"
    ["deps"]="deps"
    ["double_macro"]="double_macro"
    ["env_config"]="env_config"
    ["error_pipe"]="error_pipe"
    ["factorial"]="factorial"
    ["fibonacci"]="fibonacci"
    ["guards"]="guards"
    ["hello"]="hello"
    ["math_struct"]="math_struct"
    ["multifile"]="multifile"
    ["pattern_matching"]="pattern_matching"
    ["pipes"]="pipes"
    ["tail_call"]="tail_call"
    ["types"]="types"
    ["unless_macro"]="unless_macro"
    ["when_macro"]="when_macro"
)

# Examples that require interactive input or are otherwise unsuitable.
declare -A EXAMPLE_SKIP=(
    ["snake"]="interactive (requires terminal)"
)

for ex_name in $(printf '%s\n' "${!EXAMPLE_TARGETS[@]}" | LC_ALL=C sort); do
    target="${EXAMPLE_TARGETS[$ex_name]}"
    work_dir="$ZAP_REPO/examples/$ex_name"
    binary_name="$target"

    # Some example targets produce binaries with names different from the
    # target -- check after build by reading zap-out/bin/*. For now assume
    # binary_name == target_name (this matches all current examples).
    run_build_and_exec_workload \
        "example_$ex_name" "example_$ex_name" \
        "$work_dir" "$target" "$binary_name" "" ""
done

for ex_name in "${!EXAMPLE_SKIP[@]}"; do
    record_status "example_$ex_name" "skipped" "0" "0" "0/0/0" "${EXAMPLE_SKIP[$ex_name]}"
done

# ---------------------------------------------------------------------------
# bench/map-workloads/* (Phase B1 differential tests). Currently absent.
# ---------------------------------------------------------------------------

if [[ -d "$ZAP_REPO/bench/map-workloads" ]]; then
    for d in "$ZAP_REPO/bench/map-workloads"/*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        # Each map-workload directory is expected to be a buildable Zap
        # project with a build.zap and a bin target named `name`.
        run_build_and_exec_workload \
            "mapworkload_$name" "mapworkload_$name" \
            "$d" "$name" "$name" "" ""
    done
else
    record_status "mapworkloads_directory" "skipped" "0" "0" "0/0/0" \
        "bench/map-workloads/ does not exist (Phase B1 not yet landed)"
fi

# ---------------------------------------------------------------------------
# Self-build of stdlib (compile pipeline as workload)
# ---------------------------------------------------------------------------

run_self_build_workload

# ---------------------------------------------------------------------------
# Aggregator
# ---------------------------------------------------------------------------

echo
echo "=== running aggregator ==="
"$AGGREGATOR" "$DATA_DIR"

{
    printf '\n_Run completed: %s_\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
} >> "$STATUS_LOG"

echo
echo "STATUS log: $STATUS_LOG"
echo "aggregate:   $DATA_DIR/aggregate.json + aggregate.md"
