#!/usr/bin/env bash
# Phase B1.4 — Map workload differential test runner.
#
# Builds and runs each Phase B1 micro-benchmark with the instrumented
# `zap` binary, validates the resulting `map-instrumentation.json`
# against the per-workload classification expectations defined in
# `docs/map-workload-instrumentation-plan.md` §11, and prints a
# PASS/FAIL line for each. Exits 0 only if every workload's actual
# classifier output matches its expected pattern. The script is the
# end-to-end smoke test for the W/S/V classifier — if any expectation
# fails, the classifier or its hooks have regressed and Phase B
# downstream work cannot be trusted.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
zap_bin="$repo_root/zig-out/bin/zap"
workloads_dir="$repo_root/bench/map-workloads"

red=$'\033[31m'
green=$'\033[32m'
yellow=$'\033[33m'
reset=$'\033[0m'

if [[ ! -x "$zap_bin" ]]; then
  echo "${red}FAIL${reset}: $zap_bin is missing or not executable. Build first with: zig build -Dinstrument-map=true" >&2
  exit 1
fi

# Verify the host compiler was built with `-Dinstrument-map=true`. The
# build flag rewrites `INSTRUMENT_MAP_DEFAULT` from `false` to `true`
# inside the embedded user-binary runtime source, which is the load-
# bearing piece of plumbing that turns instrumentation on for every
# Zap binary the host produces. Without it, every workload run will
# emit an empty / no-op JSON file regardless of what the classifier
# logic does.
# Note: cannot pipe `strings | grep -q` with `set -o pipefail` — grep
# closes the pipe on first match and `strings` exits 141 (SIGPIPE),
# which `pipefail` treats as the pipeline result. Buffer the strings
# output to a temporary first.
host_compiler_strings_dump="$(strings "$zap_bin")"
if ! grep -q "INSTRUMENT_MAP_DEFAULT: bool = true" <<<"$host_compiler_strings_dump"; then
  echo "${red}FAIL${reset}: $zap_bin was built without -Dinstrument-map=true." >&2
  echo "Rebuild with: zig build -Dinstrument-map=true" >&2
  exit 1
fi
unset host_compiler_strings_dump

# Per-workload expectations. Each entry encodes:
#   subdir      — directory under bench/map-workloads/
#   target      — the `zap build <target>` argument
#   bin_name    — the produced binary in zap-out/bin/<bin_name>
#   description — human-readable label printed alongside the result
#   expectation — a function name (defined below) that takes a JSON
#                 path and prints any failure reason; an empty string
#                 means the expectation passed.
expectations=(
  "working_dict|working_dict|working_dict|Pure working-dict (S-dominated)|expect_working_dict"
  "versioned|versioned|versioned|Persistent-versioned (V signal)|expect_versioned"
  "read_mostly|read_mostly|read_mostly|Read-mostly (no V, no mutations after build)|expect_read_mostly"
)

# JSON probes — each grep pulls a single field out of the summary's
# emitted text so the runner does not pull in jq. The format is
# stable: every workload writes a hand-formatted JSON via the
# instrumentation runtime, so a string-level match is reliable.
json_field_int() {
  local file="$1"
  local key="$2"
  grep -oE "\"$key\":[[:space:]]*[0-9]+" "$file" | head -1 | sed -E "s/.*: *([0-9]+)/\1/"
}

json_class_count() {
  local file="$1"
  local class="$2"
  grep -oE "\"$class\":[[:space:]]*\\{\"count\":[[:space:]]*[0-9]+,[[:space:]]*\"frac\":[[:space:]]*[0-9]+\\.[0-9]+\\}" "$file" | head -1 | sed -E "s/.*\"count\": *([0-9]+).*/\1/"
}

json_class_frac() {
  local file="$1"
  local class="$2"
  grep -oE "\"$class\":[[:space:]]*\\{\"count\":[[:space:]]*[0-9]+,[[:space:]]*\"frac\":[[:space:]]*[0-9]+\\.[0-9]+\\}" "$file" | head -1 | sed -E "s/.*\"frac\": *([0-9]+\\.[0-9]+).*/\1/"
}

json_lineage_class() {
  local file="$1"
  local class="$2"
  awk -v cls="\"$class\"" '
    /by_lineage_class/ { in_block = 1; next }
    in_block && $0 ~ /\}/ { in_block = 0 }
    in_block && index($0, cls) {
      gsub(/[",]/, "")
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { print $i; exit }
    }
  ' "$file"
}

# B1.1 — pure working-dict. Expect overwhelmingly class S, zero V
# instances, every lineage classified W (a single working dict that
# never escaped its caller's scope).
expect_working_dict() {
  local file="$1"
  local s_frac
  s_frac=$(json_class_frac "$file" S)
  local v_lin
  v_lin=$(json_lineage_class "$file" V)
  local v_count
  v_count=$(json_class_count "$file" V)
  awk -v sf="$s_frac" 'BEGIN { exit !(sf+0 >= 0.95) }' || { echo "by_class.S.frac=$s_frac < 0.95"; return; }
  if [[ "${v_lin:-1}" -ne 0 ]]; then echo "by_lineage_class.V=$v_lin (expected 0)"; return; fi
  if [[ "${v_count:-1}" -ne 0 ]]; then echo "by_class.V.count=$v_count (expected 0)"; return; fi
}

# B1.2 — persistent-versioned. Expect a real V signal, a non-zero
# post-share mutation count, and at least one lineage classified V.
expect_versioned() {
  local file="$1"
  local v_frac
  v_frac=$(json_class_frac "$file" V)
  local post_share
  post_share=$(json_field_int "$file" post_share_mutation_count)
  local v_lin
  v_lin=$(json_lineage_class "$file" V)
  awk -v vf="$v_frac" 'BEGIN { exit !(vf+0 >= 0.30) }' || { echo "by_class.V.frac=$v_frac < 0.30"; return; }
  if [[ "${post_share:-0}" -eq 0 ]]; then echo "post_share_mutation_count=$post_share (expected > 0)"; return; fi
  if [[ "${v_lin:-0}" -lt 1 ]]; then echo "by_lineage_class.V=$v_lin (expected >= 1)"; return; fi
}

# B1.3 — read-mostly. Build phase is working-dict (no parking), read
# phase fires no mutations. Expect zero V instances, zero post-share
# mutations, and a final-map `gets` count >= 100 in the JSONL detail.
expect_read_mostly() {
  local file="$1"
  local v_count
  v_count=$(json_class_count "$file" V)
  local post_share
  post_share=$(json_field_int "$file" post_share_mutation_count)
  if [[ "${v_count:-1}" -ne 0 ]]; then echo "by_class.V.count=$v_count (expected 0)"; return; fi
  if [[ "${post_share:-1}" -ne 0 ]]; then echo "post_share_mutation_count=$post_share (expected 0)"; return; fi
  local jsonl="${file%.json}.jsonl"
  if [[ -f "$jsonl" ]]; then
    local max_gets
    max_gets=$(grep -oE '"gets":[0-9]+' "$jsonl" | sed -E 's/.*://' | sort -n | tail -1)
    if [[ -z "${max_gets:-}" || "${max_gets:-0}" -lt 100 ]]; then
      echo "max gets across instances=$max_gets (expected >= 100)"
      return
    fi
  fi
}

run_workload() {
  local entry="$1"
  IFS='|' read -r subdir target bin_name description expectation <<<"$entry"
  local dir="$workloads_dir/$subdir"
  local json="$dir/instrumentation.json"
  local jsonl="$dir/map-instrumentation.jsonl"

  printf "%-12s  %-50s  " "$subdir" "$description"

  if [[ ! -d "$dir" ]]; then
    printf "${red}FAIL${reset}  workload directory missing: %s\n" "$dir"
    return 1
  fi

  rm -rf "$dir/zap-out" "$dir/.zap-cache" "$dir/zap.lock" "$json" "$jsonl"
  if ! (cd "$dir" && "$zap_bin" build "$target" >/dev/null 2>&1); then
    printf "${red}FAIL${reset}  zap build %s failed\n" "$target"
    return 1
  fi
  local bin="$dir/zap-out/bin/$bin_name"
  if [[ ! -x "$bin" ]]; then
    printf "${red}FAIL${reset}  binary missing: %s\n" "$bin"
    return 1
  fi
  if ! (cd "$dir" && ZAP_INSTRUMENT_OUT="$json" ZAP_INSTRUMENT_DETAIL=1 "$bin" >/dev/null 2>&1); then
    printf "${red}FAIL${reset}  binary execution failed\n"
    return 1
  fi
  if [[ ! -s "$json" ]]; then
    printf "${red}FAIL${reset}  instrumentation.json missing or empty\n"
    return 1
  fi

  local reason
  reason=$("$expectation" "$json")
  if [[ -n "$reason" ]]; then
    printf "${red}FAIL${reset}  %s\n" "$reason"
    return 1
  fi
  printf "${green}PASS${reset}\n"
  return 0
}

failures=0
total=0
for entry in "${expectations[@]}"; do
  total=$((total + 1))
  if ! run_workload "$entry"; then
    failures=$((failures + 1))
  fi
done

echo
if [[ $failures -eq 0 ]]; then
  echo "${green}All $total workloads passed.${reset}"
  exit 0
fi
echo "${red}$failures of $total workloads failed.${reset}"
exit 1
