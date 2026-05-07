# Phase B2 Map Workload Instrumentation Status

_Run started: 2026-05-07T15:09:34Z_

Instrumented zap binary: `/Users/bcardarella/projects/zap/zig-out/bin/zap`

| Workload | Status | Wall (s) | Instances | by_class S/W/V | Notes |
| --- | --- | ---: | ---: | --- | --- |
| k-nucleotide | ok | 5 | 8750004 | 8750004/0/0 |  |
| fannkuch-redux | no-map-activity | 1 | 0 | 0/0/0 | no Map allocations |
| spectral-norm | no-map-activity | 1 | 0 | 0/0/0 | no Map allocations |
| binary-trees | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_attributes | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_binary_patterns | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_case_expr | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_cli | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_computed_attributes | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_ctfe_basics | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_default_params | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_deps | no-map-activity | 1 | 0 | 0/0/0 | no Map allocations |
| example_double_macro | no-map-activity | 1 | 0 | 0/0/0 | no Map allocations |
| example_env_config | no-map-activity | 1 | 0 | 0/0/0 | no Map allocations |
| example_error_pipe | no-map-activity | 1 | 0 | 0/0/0 | no Map allocations |
| example_factorial | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_fibonacci | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_guards | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_hello | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_math_struct | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_multifile | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_pattern_matching | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_pipes | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_tail_call | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_types | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_unless_macro | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_when_macro | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_snake | skipped | 0 | 0 | 0/0/0 | interactive (requires terminal) |
| mapworkload_read_mostly | ok | 0 | 180 | 180/0/0 |  |
| mapworkload_versioned | ok | 0 | 480 | 240/40/200 |  |
| mapworkload_working_dict | ok | 0 | 540 | 540/0/0 |  |
| selfbuild_compile_hello | no-map-activity | 7 | 0 | 0/0/0 | compiler did not allocate Map cells |

_Run completed: 2026-05-07T15:13:19Z_
