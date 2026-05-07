#!/usr/bin/env bash
# ============================================================================
# map-instrumentation-aggregator-test.sh
#
# Smoke tests for bench/map-instrumentation-aggregator.sh. Runs the
# aggregator against each fixture in isolation and verifies the
# expected recommendation rule fires.
#
# Exits 0 on success, non-zero on any test failure.
# ============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
AGGREGATOR="$REPO_ROOT/bench/map-instrumentation-aggregator.sh"
FIXTURE_DIR="$REPO_ROOT/bench/map-instrumentation-data/fixtures"

if [[ ! -x "$AGGREGATOR" ]]; then
    echo "error: aggregator not executable at $AGGREGATOR" >&2
    exit 2
fi
if [[ ! -d "$FIXTURE_DIR" ]]; then
    echo "error: fixture directory missing: $FIXTURE_DIR" >&2
    exit 2
fi

# Each entry: fixture-name|expected-choice|expected-rule
declare -a CASES=(
    "w_dominant|Dense COW|rule-1-class-W-or-S-dominates"
    "v_dominant|HAMT-plus-make_mut|rule-2-class-V-dominates"
    "mixed_small|Dense COW + chunked-COW fallback for large maps|rule-3-moderate-V-small-dominant"
    "mixed_bimodal|Dense COW default + opt-in PersistentMap|rule-4-bimodal-tiny-and-large"
    "ambiguous|Dense COW|rule-5-default-ambiguous"
)

pass=0
fail=0
for entry in "${CASES[@]}"; do
    IFS='|' read -r name expected_choice expected_rule <<<"$entry"
    fixture="$FIXTURE_DIR/workload_${name}.json"
    if [[ ! -f "$fixture" ]]; then
        echo "FAIL  $name  (fixture missing: $fixture)"
        fail=$((fail + 1))
        continue
    fi

    tmpdir=$(mktemp -d)
    cp "$fixture" "$tmpdir/"
    ZAP_AGGREGATOR_TIMESTAMP="2026-05-07T00:00:00Z" \
        bash "$AGGREGATOR" "$tmpdir" >/dev/null 2>&1

    actual_choice=$(jq -r '.recommendation.choice' "$tmpdir/aggregate.json")
    actual_rule=$(jq -r '.recommendation.rule' "$tmpdir/aggregate.json")

    if [[ "$actual_choice" == "$expected_choice" && "$actual_rule" == "$expected_rule" ]]; then
        echo "PASS  $name  ->  $actual_choice  ($actual_rule)"
        pass=$((pass + 1))
    else
        echo "FAIL  $name"
        echo "  expected: $expected_choice / $expected_rule"
        echo "  actual:   $actual_choice / $actual_rule"
        echo "  aggregate: $(jq -c '.aggregate' "$tmpdir/aggregate.json")"
        fail=$((fail + 1))
    fi
    rm -rf "$tmpdir"
done

# Determinism check: the same input should produce byte-identical output
# across two consecutive runs.
tmpdir=$(mktemp -d)
cp "$FIXTURE_DIR"/*.json "$tmpdir/"
ZAP_AGGREGATOR_TIMESTAMP="2026-05-07T00:00:00Z" \
    bash "$AGGREGATOR" "$tmpdir" >/dev/null 2>&1
sha_json_1=$(shasum "$tmpdir/aggregate.json" | awk '{print $1}')
sha_md_1=$(shasum "$tmpdir/aggregate.md" | awk '{print $1}')
ZAP_AGGREGATOR_TIMESTAMP="2026-05-07T00:00:00Z" \
    bash "$AGGREGATOR" "$tmpdir" >/dev/null 2>&1
sha_json_2=$(shasum "$tmpdir/aggregate.json" | awk '{print $1}')
sha_md_2=$(shasum "$tmpdir/aggregate.md" | awk '{print $1}')
if [[ "$sha_json_1" == "$sha_json_2" && "$sha_md_1" == "$sha_md_2" ]]; then
    echo "PASS  determinism (byte-identical aggregate.json + aggregate.md across reruns)"
    pass=$((pass + 1))
else
    echo "FAIL  determinism"
    echo "  json: $sha_json_1 vs $sha_json_2"
    echo "  md:   $sha_md_1 vs $sha_md_2"
    fail=$((fail + 1))
fi
rm -rf "$tmpdir"

# Schema validation: malformed inputs should be skipped, not crash.
tmpdir=$(mktemp -d)
cp "$FIXTURE_DIR/workload_w_dominant.json" "$tmpdir/"
echo "not json {" > "$tmpdir/bad_invalid.json"
echo '{"workload": "no-summary"}' > "$tmpdir/bad_missing_summary.json"
ZAP_AGGREGATOR_TIMESTAMP="2026-05-07T00:00:00Z" \
    bash "$AGGREGATOR" "$tmpdir" >/dev/null 2>&1
skipped_count=$(jq '.skipped_files | length' "$tmpdir/aggregate.json")
workload_count=$(jq '.workload_count' "$tmpdir/aggregate.json")
if [[ "$skipped_count" == "2" && "$workload_count" == "1" ]]; then
    echo "PASS  malformed-input skipping ($skipped_count skipped, $workload_count valid)"
    pass=$((pass + 1))
else
    echo "FAIL  malformed-input skipping ($skipped_count skipped, $workload_count valid)"
    fail=$((fail + 1))
fi
rm -rf "$tmpdir"

echo ""
echo "Smoke test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
