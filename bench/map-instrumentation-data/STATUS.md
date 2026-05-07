# Phase B2 Map Workload Instrumentation Status

_Run started: 2026-05-07T14:56:08Z_

Instrumented zap binary: `/Users/bcardarella/projects/zap/zig-out/bin/zap`

| Workload | Status | Wall (s) | Instances | by_class S/W/V | Notes |
| --- | --- | ---: | ---: | --- | --- |
| k-nucleotide | ok | 5 | 8750004 | 8750004/0/0 |  |
| fannkuch-redux | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| spectral-norm | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| binary-trees | no-map-activity | 1 | 0 | 0/0/0 | no Map allocations |
| example_attributes | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_binary_patterns | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_case_expr | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_cli | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_computed_attributes | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_ctfe_basics | no-map-activity | 1 | 0 | 0/0/0 | no Map allocations |
| example_default_params | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_deps | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_double_macro | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_env_config | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_error_pipe | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_factorial | no-map-activity | 1 | 0 | 0/0/0 | no Map allocations |
| example_fibonacci | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_guards | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_hello | no-map-activity | 1 | 0 | 0/0/0 | no Map allocations |
| example_math_struct | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_multifile | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_pattern_matching | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_pipes | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_tail_call | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_types | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_unless_macro | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_when_macro | no-map-activity | 0 | 0 | 0/0/0 | no Map allocations |
| example_snake | skipped | 0 | 0 | 0/0/0 | interactive (requires terminal) |
| mapworkload_read_mostly | build-failed | 0 | 0 | 0/0/0 | zir_api: error count: 1 .zap-cache/zap_structs/ReadMostly.zig:1:1: error: expected type 'i8', found 'i64' .zap-cache/zap_structs/ReadMostly.zig:1:1: note: signed 8-bit int cannot represent all possible signed 64-bit values .zap-cache/zap_structs/Integer.zig:1:1: note: parameter type declared here Error: compilation failed: CompilationFailed  |
| mapworkload_versioned | ok | 0 | 480 | 240/40/200 |  |
| mapworkload_working_dict | ok | 1 | 540 | 540/0/0 |  |
| selfbuild_compile_hello | no-map-activity | 6 | 0 | 0/0/0 | compiler did not allocate Map cells |

_Run completed: 2026-05-07T15:00:05Z_
