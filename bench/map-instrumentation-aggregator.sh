#!/usr/bin/env bash
# ============================================================================
# map-instrumentation-aggregator.sh
#
# Phase B3 of docs/map-workload-instrumentation-plan.md.
#
# Standalone aggregator/analyzer for per-workload Map instrumentation
# JSON files. Reads every *.json file in an input directory, validates
# the §6 schema, computes weighted cross-workload metrics, and emits
# both an aggregate.json (machine-readable) and aggregate.md (human-
# readable) report. Includes an automatic representation recommendation
# derived from §8 of the plan.
#
# Dependencies: bash, jq (>= 1.6).
#
# Usage:
#   ./bench/map-instrumentation-aggregator.sh [INPUT_DIR]
#     INPUT_DIR defaults to ./bench/map-instrumentation-data
#
# Output (written into INPUT_DIR):
#   aggregate.json  -- combined cross-workload summary
#   aggregate.md    -- human-readable markdown report with recommendation
#
# ----------------------------------------------------------------------------
# Input schema (per workload file, from runtime.zig renderInstrumentationSummaryJson)
# ----------------------------------------------------------------------------
# {
#   "workload": "<string>",
#   "binary":   "<string>",
#   "duration_ns": <u64>,
#   "summary": {
#     "total_instances": <u64>,
#     "total_lineages":  <u64>,
#     "by_class": {
#       "S": {"count": <u64>, "frac": <f64>},
#       "W": {"count": <u64>, "frac": <f64>},
#       "V": {"count": <u64>, "frac": <f64>}
#     },
#     "by_lineage_class": {"S": <u64>, "W": <u64>, "V": <u64>},
#     "size_histogram": {
#       "0": <u64>, "1-7": <u64>, "8-31": <u64>,
#       "32-127": <u64>, "128-1023": <u64>, "1024+": <u64>
#     },
#     "peak_concurrent_versions_histogram": {
#       "1": <u64>, "2": <u64>, "3-5": <u64>, "6-20": <u64>, "21+": <u64>
#     },
#     "post_share_mutation_count": <u64>,
#     "total_node_clones": <u64>,
#     "top_callsites_by_instance_count": [
#       {"site": "<string>", "count": <u64>}, ...
#     ]
#   }
# }
#
# Optional sidecar: <name>.jsonl containing per-instance records, used
# when present to compute the more accurate `total_ops` weight.
#
# ----------------------------------------------------------------------------
# Output schema (aggregate.json)
# ----------------------------------------------------------------------------
# {
#   "generated_at_utc": "<ISO-8601>",
#   "input_dir":        "<absolute path>",
#   "workload_count":   <u64>,
#   "skipped_files":    [{"file": "<path>", "reason": "<why>"}, ...],
#   "workloads": [
#     {
#       "workload": "<string>",
#       "file":     "<path>",
#       "weight_total_ops": <u64>,
#       "weight_source":    "summary.total_ops" | "jsonl_sidecar" | "total_instances_fallback",
#       "total_instances":  <u64>,
#       "total_lineages":   <u64>,
#       "class_S_fraction": <f64>,
#       "class_W_fraction": <f64>,
#       "class_V_fraction": <f64>,
#       "class_W_or_S_fraction":      <f64>,
#       "lineage_pcv1_fraction":      <f64>,
#       "small_map_fraction_lt32":    <f64>,
#       "large_map_fraction_ge128":   <f64>,
#       "post_share_mutation_count":  <u64>,
#       "total_node_clones":          <u64>,
#       "duration_ns":                <u64>
#     }, ...
#   ],
#   "aggregate": {
#     "total_weight_ops": <u64>,
#     "class_S_fraction": <f64>,
#     "class_W_fraction": <f64>,
#     "class_V_fraction": <f64>,
#     "class_W_or_S_fraction":   <f64>,
#     "lineage_pcv1_fraction":   <f64>,
#     "small_map_fraction_lt32": <f64>,
#     "large_map_fraction_ge128":<f64>
#   },
#   "recommendation": {
#     "choice":     "Dense COW" | "HAMT-plus-make_mut" |
#                   "Dense COW + chunked-COW fallback for large maps" |
#                   "Dense COW default + opt-in PersistentMap",
#     "rule":       "<rule label from plan §8>",
#     "rationale":  "<text with explicit numbers and thresholds>",
#     "thresholds": { "<name>": {"observed": <f64>, "required": "<expr>", "delta": <f64>}, ... }
#   }
# }
# ============================================================================

set -euo pipefail

INPUT_DIR="${1:-./bench/map-instrumentation-data}"

if [[ ! -d "$INPUT_DIR" ]]; then
    echo "error: input directory does not exist: $INPUT_DIR" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "error: this script requires jq (jq 1.6+). Install jq first." >&2
    exit 2
fi

# Resolve absolute path portably.
ABS_INPUT_DIR="$(cd "$INPUT_DIR" && pwd -P)"

# Deterministic output path. Top-level outputs only; do not recurse into
# fixtures/ or other subdirectories.
OUT_JSON="$ABS_INPUT_DIR/aggregate.json"
OUT_MD="$ABS_INPUT_DIR/aggregate.md"

# Use a stable timestamp (UTC) for byte-identical output across runs *of
# the same input set*. The aggregator records the time the report was
# generated; for full byte-stability across runs the caller can set
# ZAP_AGGREGATOR_TIMESTAMP.
GENERATED_AT="${ZAP_AGGREGATOR_TIMESTAMP:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

# Collect candidate files: top-level *.json in INPUT_DIR, sorted by name
# (deterministic order). Exclude aggregate.json itself.
mapfile -t CANDIDATES < <(
    find "$ABS_INPUT_DIR" -maxdepth 1 -type f -name '*.json' \
        ! -name 'aggregate.json' -print | LC_ALL=C sort
)

# ----------------------------------------------------------------------------
# Validation: ensure each file matches the §6 schema. Skip malformed ones.
# ----------------------------------------------------------------------------
SCHEMA_FILTER='
def is_nonneg_int: type == "number" and . == (.|floor) and . >= 0;
def is_count_obj: type == "object"
    and (.count // null) | (. != null and is_nonneg_int);

# Returns null when the file is well-formed; otherwise a string reason.
. as $root
| if (.workload // null | type) != "string" then "missing workload"
  elif (.summary // null | type) != "object" then "missing summary"
  else
    .summary as $s
    | if ($s.total_instances // null) == null or
         ($s.total_instances | type) != "number" then "summary.total_instances missing or not a number"
      elif ($s.total_lineages // null) == null then "summary.total_lineages missing"
      elif ($s.by_class // null | type) != "object" then "summary.by_class missing"
      elif ($s.by_class.S // null | type) != "object" then "summary.by_class.S missing"
      elif ($s.by_class.W // null | type) != "object" then "summary.by_class.W missing"
      elif ($s.by_class.V // null | type) != "object" then "summary.by_class.V missing"
      elif ($s.by_lineage_class // null | type) != "object" then "summary.by_lineage_class missing"
      elif ($s.size_histogram // null | type) != "object" then "summary.size_histogram missing"
      elif ($s.peak_concurrent_versions_histogram // null | type) != "object" then "summary.peak_concurrent_versions_histogram missing"
      else null
      end
  end
'

VALID_FILES=()
SKIPPED_JSON='[]'

for f in "${CANDIDATES[@]:-}"; do
    [[ -z "$f" ]] && continue
    # Parse + validate.
    if ! reason=$(jq -r "$SCHEMA_FILTER" "$f" 2>/dev/null); then
        echo "skip: $f (invalid JSON)" >&2
        SKIPPED_JSON=$(jq --arg file "$f" --arg reason "invalid JSON" \
            '. + [{"file": $file, "reason": $reason}]' <<<"$SKIPPED_JSON")
        continue
    fi
    if [[ "$reason" != "null" ]]; then
        echo "skip: $f ($reason)" >&2
        SKIPPED_JSON=$(jq --arg file "$f" --arg reason "$reason" \
            '. + [{"file": $file, "reason": $reason}]' <<<"$SKIPPED_JSON")
        continue
    fi
    VALID_FILES+=("$f")
done

if [[ ${#VALID_FILES[@]} -eq 0 ]]; then
    echo "error: no valid workload JSON files found in $ABS_INPUT_DIR" >&2
    # Still emit an empty aggregate so downstream tooling has a stable
    # artifact path.
    jq -n \
        --arg generated_at "$GENERATED_AT" \
        --arg input_dir "$ABS_INPUT_DIR" \
        --argjson skipped "$SKIPPED_JSON" \
        '{
            generated_at_utc: $generated_at,
            input_dir: $input_dir,
            workload_count: 0,
            skipped_files: $skipped,
            workloads: [],
            aggregate: null,
            recommendation: {
                choice: "Dense COW",
                rule: "default-no-data",
                rationale: "No valid workload files found; defaulting to Dense COW per plan §8 industrial signal.",
                thresholds: {}
            }
        }' > "$OUT_JSON"
    cat > "$OUT_MD" <<EOF
# Map Workload Instrumentation Aggregate

_Generated: $GENERATED_AT_

No valid workload JSON files were found in \`$ABS_INPUT_DIR\`.

**Recommendation:** Dense COW (default with no data — industrial signal per plan §8).
EOF
    exit 0
fi

# ----------------------------------------------------------------------------
# Per-workload extraction. For each file:
#   - read summary fields
#   - compute weight = summary.total_ops if present
#                    else sum of puts+deletes+merges+gets from sibling .jsonl
#                    else total_instances (fallback)
#   - compute fractions
# Emit a JSON array of per-workload records.
# ----------------------------------------------------------------------------

PER_WORKLOAD_JSON='[]'

for f in "${VALID_FILES[@]}"; do
    base="${f%.json}"
    sidecar="${base}.jsonl"

    # Determine total_ops weight.
    weight_source="total_instances_fallback"
    weight_ops=""

    summary_total_ops=$(jq -r '.summary.total_ops // empty' "$f")
    if [[ -n "$summary_total_ops" ]]; then
        weight_ops="$summary_total_ops"
        weight_source="summary.total_ops"
    elif [[ -f "$sidecar" ]]; then
        # Sum puts+deletes+merges+gets across all jsonl records.
        weight_ops=$(jq -s '
            map((.puts // 0) + (.deletes // 0) + (.merges // 0) + (.gets // 0))
            | add // 0
        ' "$sidecar")
        weight_source="jsonl_sidecar"
    else
        weight_ops=$(jq -r '.summary.total_instances' "$f")
        weight_source="total_instances_fallback"
    fi

    # Compute fractions deterministically.
    workload_record=$(jq \
        --arg file "$f" \
        --argjson weight_ops "$weight_ops" \
        --arg weight_source "$weight_source" \
        '
        .summary as $s
        | ($s.total_instances | tonumber) as $ti
        | (if $ti > 0 then $ti else 1 end) as $denom_inst
        | ($s.by_class.S.count // 0) as $sS
        | ($s.by_class.W.count // 0) as $sW
        | ($s.by_class.V.count // 0) as $sV
        | ($s.by_lineage_class.S // 0) as $lS
        | ($s.by_lineage_class.W // 0) as $lW
        | ($s.by_lineage_class.V // 0) as $lV
        | ($lS + $lW + $lV) as $total_lineages_sum
        | (if $total_lineages_sum > 0 then $total_lineages_sum else 1 end) as $denom_lin
        | (($s.peak_concurrent_versions_histogram["1"] // 0)) as $pcv1
        | (
            ($s.peak_concurrent_versions_histogram["1"]    // 0)
          + ($s.peak_concurrent_versions_histogram["2"]    // 0)
          + ($s.peak_concurrent_versions_histogram["3-5"]  // 0)
          + ($s.peak_concurrent_versions_histogram["6-20"] // 0)
          + ($s.peak_concurrent_versions_histogram["21+"]  // 0)
        ) as $pcv_total
        | (if $pcv_total > 0 then $pcv_total else 1 end) as $denom_pcv
        | (
            ($s.size_histogram["0"]    // 0)
          + ($s.size_histogram["1-7"]  // 0)
          + ($s.size_histogram["8-31"] // 0)
        ) as $small_lt32
        | (
            ($s.size_histogram["128-1023"] // 0)
          + ($s.size_histogram["1024+"]    // 0)
        ) as $large_ge128
        | {
            workload:        (.workload // "unknown"),
            file:            $file,
            weight_total_ops: $weight_ops,
            weight_source:    $weight_source,
            total_instances:  $ti,
            total_lineages:   ($s.total_lineages // ($lS + $lW + $lV)),
            class_S_count:    $sS,
            class_W_count:    $sW,
            class_V_count:    $sV,
            class_S_fraction: ( ($sS / $denom_inst) ),
            class_W_fraction: ( ($sW / $denom_inst) ),
            class_V_fraction: ( ($sV / $denom_inst) ),
            class_W_or_S_fraction: ( (($sS + $sW) / $denom_inst) ),
            lineage_pcv1_fraction: ( ($pcv1 / $denom_pcv) ),
            small_map_fraction_lt32:  ( ($small_lt32 / $denom_inst) ),
            large_map_fraction_ge128: ( ($large_ge128 / $denom_inst) ),
            post_share_mutation_count: ($s.post_share_mutation_count // 0),
            total_node_clones:        ($s.total_node_clones // 0),
            duration_ns:              (.duration_ns // 0)
        }
        ' "$f")

    PER_WORKLOAD_JSON=$(jq --argjson rec "$workload_record" '. + [$rec]' <<<"$PER_WORKLOAD_JSON")
done

# Sort workloads deterministically by workload name then file path.
PER_WORKLOAD_JSON=$(jq 'sort_by(.workload, .file)' <<<"$PER_WORKLOAD_JSON")

# ----------------------------------------------------------------------------
# Cross-workload aggregation, weighted by total_ops.
# Each fraction = sum(weight_i * fraction_i) / sum(weight_i).
# ----------------------------------------------------------------------------
AGGREGATE_JSON=$(jq '
    (map(.weight_total_ops) | add) as $W_total
    | (if $W_total > 0 then $W_total else 1 end) as $denom
    | {
        total_weight_ops: $W_total,
        class_S_fraction:         ( (map(.weight_total_ops * .class_S_fraction)         | add // 0) / $denom ),
        class_W_fraction:         ( (map(.weight_total_ops * .class_W_fraction)         | add // 0) / $denom ),
        class_V_fraction:         ( (map(.weight_total_ops * .class_V_fraction)         | add // 0) / $denom ),
        class_W_or_S_fraction:    ( (map(.weight_total_ops * .class_W_or_S_fraction)    | add // 0) / $denom ),
        lineage_pcv1_fraction:    ( (map(.weight_total_ops * .lineage_pcv1_fraction)    | add // 0) / $denom ),
        small_map_fraction_lt32:  ( (map(.weight_total_ops * .small_map_fraction_lt32)  | add // 0) / $denom ),
        large_map_fraction_ge128: ( (map(.weight_total_ops * .large_map_fraction_ge128) | add // 0) / $denom )
    }
' <<<"$PER_WORKLOAD_JSON")

# ----------------------------------------------------------------------------
# Recommendation logic from plan §8.
#
# Decision tree (in order):
#  1. class_V_fraction < 0.05
#       -> Dense COW (essentially zero persistent-versioning observed)
#       NOTE: lineage_pcv1_fraction is NOT a condition. Zap's IR-level
#       ARC keeps prior locals alive within the function frame, so
#       peak_concurrent_versions=2 is the norm even for textbook
#       working-dict patterns. class_V_fraction is the direct
#       measurement of the question we care about; lineage_pcv1 is a
#       noisy proxy that gates on Zap's per-frame ARC discipline,
#       not on the workload's persistent-versioning behavior.
#  2. class_V_fraction >= 0.30
#       -> HAMT-plus-make_mut
#  3. class_V_fraction in [0.05, 0.30)
#     AND small_map_fraction_lt32 >= 0.50  (proxy: small maps dominate)
#       -> Dense COW + chunked-COW fallback for large maps
#  4. class_V_fraction in [0.05, 0.30)
#     AND large_map_fraction_ge128 >= 0.05 (bimodal: tiny W + a few big V)
#       -> Dense COW default + opt-in PersistentMap
#  5. else (genuinely ambiguous)
#       -> Dense COW (industrial signal default)
# ----------------------------------------------------------------------------

RECOMMENDATION_JSON=$(jq '
    .class_S_fraction        as $S
    | .class_W_fraction      as $W
    | .class_V_fraction      as $V
    | .class_W_or_S_fraction as $WS
    | .lineage_pcv1_fraction as $PCV1
    | .small_map_fraction_lt32  as $SMALL
    | .large_map_fraction_ge128 as $LARGE
    | if ($V < 0.05) then
        {
            choice: "Dense COW",
            rule:   "rule-1-class-V-essentially-zero",
            rationale: (
                "class_V_fraction = " + ($V|tostring) +
                " (< 0.05 by " + ((0.05 - $V)|tostring) + "). " +
                "Persistent-versioning is essentially absent; Dense COW " +
                "is the right default per plan §8. " +
                "(class_W_or_S_fraction = " + ($WS|tostring) +
                ", lineage_pcv1_fraction = " + ($PCV1|tostring) +
                " are informational only — Zap IR-level ARC keeps prior " +
                "locals alive within a function frame, so peak_concurrent_" +
                "versions >= 2 even for textbook working-dict patterns.)"
            ),
            thresholds: {
                class_V_fraction:      { observed: $V,     required: "< 0.05",  delta: (0.05 - $V) },
                class_W_or_S_fraction: { observed: $WS,    required: "informational", delta: ($WS - 0.80) },
                lineage_pcv1_fraction: { observed: $PCV1,  required: "informational", delta: ($PCV1 - 0.90) }
            }
        }
      elif ($V >= 0.30) then
        {
            choice: "HAMT-plus-make_mut",
            rule:   "rule-2-class-V-dominates",
            rationale: (
                "class_V_fraction = " + ($V|tostring) +
                " (>= 0.30 by " + (($V - 0.30)|tostring) + "). " +
                "Versioning is widespread; HAMT-plus-make_mut is the safer " +
                "representation per plan §8 row 2."
            ),
            thresholds: {
                class_V_fraction: { observed: $V, required: ">= 0.30", delta: ($V - 0.30) }
            }
        }
      elif ($V >= 0.05) and ($V < 0.30) and ($SMALL >= 0.50) then
        {
            choice: "Dense COW + chunked-COW fallback for large maps",
            rule:   "rule-3-moderate-V-small-dominant",
            rationale: (
                "class_V_fraction = " + ($V|tostring) +
                " (in [0.05, 0.30) by " + (($V - 0.05)|tostring) + " above 0.05); " +
                "small_map_fraction_lt32 = " + ($SMALL|tostring) +
                " (>= 0.50 by " + (($SMALL - 0.50)|tostring) + "). " +
                "Most V-class shared maps are small; compose Dense COW with " +
                "chunked-COW fallback for >32-entry maps per plan §8 row 3."
            ),
            thresholds: {
                class_V_fraction:        { observed: $V,     required: "in [0.05, 0.30)", delta: ($V - 0.05) },
                small_map_fraction_lt32: { observed: $SMALL, required: ">= 0.50",         delta: ($SMALL - 0.50) }
            }
        }
      elif ($V >= 0.05) and ($V < 0.30) and ($LARGE >= 0.05) then
        {
            choice: "Dense COW default + opt-in PersistentMap",
            rule:   "rule-4-bimodal-tiny-and-large",
            rationale: (
                "class_V_fraction = " + ($V|tostring) +
                " (in [0.05, 0.30) by " + (($V - 0.05)|tostring) + " above 0.05); " +
                "large_map_fraction_ge128 = " + ($LARGE|tostring) +
                " (>= 0.05 by " + (($LARGE - 0.05)|tostring) + "); " +
                "small_map_fraction_lt32 = " + ($SMALL|tostring) +
                ". Bimodal distribution: many tiny W maps plus a non-trivial " +
                "tail of large V maps — Dense COW default with opt-in " +
                "PersistentMap per plan §8 row 4."
            ),
            thresholds: {
                class_V_fraction:         { observed: $V,     required: "in [0.05, 0.30)", delta: ($V - 0.05) },
                large_map_fraction_ge128: { observed: $LARGE, required: ">= 0.05",         delta: ($LARGE - 0.05) }
            }
        }
      else
        {
            choice: "Dense COW",
            rule:   "rule-5-default-ambiguous",
            rationale: (
                "Data is genuinely ambiguous: " +
                "class_W_or_S_fraction = " + ($WS|tostring) + ", " +
                "class_V_fraction = "      + ($V|tostring)  + ", " +
                "lineage_pcv1_fraction = " + ($PCV1|tostring) + ", " +
                "small_map_fraction_lt32 = " + ($SMALL|tostring) + ", " +
                "large_map_fraction_ge128 = " + ($LARGE|tostring) + ". " +
                "Defaulting to Dense COW per plan §8 industrial signal."
            ),
            thresholds: {
                class_W_or_S_fraction:    { observed: $WS,    required: ">= 0.80 (rule 1)", delta: ($WS - 0.80) },
                class_V_fraction:         { observed: $V,     required: ">= 0.30 (rule 2)", delta: ($V - 0.30) },
                lineage_pcv1_fraction:    { observed: $PCV1,  required: ">= 0.90 (rule 1)", delta: ($PCV1 - 0.90) },
                small_map_fraction_lt32:  { observed: $SMALL, required: ">= 0.50 (rule 3)", delta: ($SMALL - 0.50) },
                large_map_fraction_ge128: { observed: $LARGE, required: ">= 0.05 (rule 4)", delta: ($LARGE - 0.05) }
            }
        }
      end
' <<<"$AGGREGATE_JSON")

# ----------------------------------------------------------------------------
# Compose final aggregate.json.
# ----------------------------------------------------------------------------
WORKLOAD_COUNT=$(jq 'length' <<<"$PER_WORKLOAD_JSON")

jq -n \
    --arg generated_at "$GENERATED_AT" \
    --arg input_dir "$ABS_INPUT_DIR" \
    --argjson workload_count "$WORKLOAD_COUNT" \
    --argjson skipped "$SKIPPED_JSON" \
    --argjson workloads "$PER_WORKLOAD_JSON" \
    --argjson aggregate "$AGGREGATE_JSON" \
    --argjson recommendation "$RECOMMENDATION_JSON" \
    '{
        generated_at_utc: $generated_at,
        input_dir:        $input_dir,
        workload_count:   $workload_count,
        skipped_files:    $skipped,
        workloads:        $workloads,
        aggregate:        $aggregate,
        recommendation:   $recommendation
    }' > "$OUT_JSON"

# ----------------------------------------------------------------------------
# Compose human-readable aggregate.md.
# ----------------------------------------------------------------------------
{
    printf '# Map Workload Instrumentation Aggregate\n\n'
    printf '_Generated: %s_  \n' "$GENERATED_AT"
    printf '_Input directory: `%s`_  \n' "$ABS_INPUT_DIR"
    printf '_Workloads aggregated: %s_\n\n' "$WORKLOAD_COUNT"

    # Skipped files section, only if any.
    skipped_count=$(jq 'length' <<<"$SKIPPED_JSON")
    if [[ "$skipped_count" != "0" ]]; then
        printf '## Skipped files\n\n'
        printf '| File | Reason |\n| --- | --- |\n'
        jq -r '.[] | "| `\(.file)` | \(.reason) |"' <<<"$SKIPPED_JSON"
        printf '\n'
    fi

    # Per-workload table.
    printf '## Per-workload metrics\n\n'
    printf '| Workload | Weight (ops) | Weight source | Instances | Lineages | %%S | %%W | %%V | %%W+S | %%pcv=1 | %%size<32 | %%size>=128 |\n'
    printf '| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n'
    jq -r '
        .[] |
        "| \(.workload) " +
        "| \(.weight_total_ops) " +
        "| \(.weight_source) " +
        "| \(.total_instances) " +
        "| \(.total_lineages) " +
        "| \(.class_S_fraction        | . * 10000 | round / 100) " +
        "| \(.class_W_fraction        | . * 10000 | round / 100) " +
        "| \(.class_V_fraction        | . * 10000 | round / 100) " +
        "| \(.class_W_or_S_fraction   | . * 10000 | round / 100) " +
        "| \(.lineage_pcv1_fraction   | . * 10000 | round / 100) " +
        "| \(.small_map_fraction_lt32 | . * 10000 | round / 100) " +
        "| \(.large_map_fraction_ge128| . * 10000 | round / 100) |"
    ' <<<"$PER_WORKLOAD_JSON"
    printf '\n'

    # Aggregate (weighted) table.
    printf '## Aggregate (weighted by total Map ops)\n\n'
    printf '| Metric | Value |\n| --- | ---: |\n'
    jq -r '
        "| Total weight (ops) | \(.total_weight_ops) |",
        "| class_S_fraction | \(.class_S_fraction) |",
        "| class_W_fraction | \(.class_W_fraction) |",
        "| class_V_fraction | \(.class_V_fraction) |",
        "| class_W_or_S_fraction | \(.class_W_or_S_fraction) |",
        "| lineage_pcv1_fraction | \(.lineage_pcv1_fraction) |",
        "| small_map_fraction_lt32 | \(.small_map_fraction_lt32) |",
        "| large_map_fraction_ge128 | \(.large_map_fraction_ge128) |"
    ' <<<"$AGGREGATE_JSON"
    printf '\n'

    # Recommendation.
    printf '## Recommendation\n\n'
    jq -r '
        "**Choice:** " + .choice + "  ",
        "**Rule:** `" + .rule + "`  ",
        "",
        "**Rationale:** " + .rationale,
        "",
        "### Thresholds",
        "",
        "| Threshold | Observed | Required | Delta |",
        "| --- | ---: | --- | ---: |",
        ( .thresholds | to_entries[] | "| " + .key + " | " + (.value.observed|tostring) + " | " + .value.required + " | " + (.value.delta|tostring) + " |" )
    ' <<<"$RECOMMENDATION_JSON"
    printf '\n'
} > "$OUT_MD"

echo "wrote $OUT_JSON"
echo "wrote $OUT_MD"
