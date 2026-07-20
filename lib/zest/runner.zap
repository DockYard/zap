@doc = """
  Discovers and runs Zest test structs.

  `use Zest.Runner` expands into a test runner `main/1` that discovers
  Zap source files from configured glob patterns, reflects their structs,
  runs the discovered Zest cases in seeded order, and then prints the
  summary.
  """

pub struct Zest.Runner {
  @doc = """
    Imports `Zest.Runner` and generates a `main/1` test entry point.

    Options are normalized through `Zest.Runner.options/1`. The supported
    option keys are `:pattern` and `:patterns`; either may contain a single
    glob string or a list of glob strings. When no pattern is configured,
    the runner uses `test/**/*_test.zap`.
    """

  pub macro __using__(opts :: Expr) -> Expr {
    normalized_options = options(opts)
    glob_patterns = patterns(normalized_options)
    source_paths = list_flatten(for pattern <- glob_patterns {
      Path.glob(pattern)
    })
    source_structs = list_flatten(for source_path <- source_paths {
      SourceGraph.structs(source_path)
    })
    test_structs = for s <- source_structs, Struct.has_function?(s, "zest_run_selected_case", 1) and Struct.has_function?(s, "zest_case_count", 0) {
      s
    }
    total_case_count = build_total_case_count(test_structs, 0, list_length(test_structs))
    selected_suite_scans = for s <- test_structs {
      quote {
        if :zig.Zest.enter_selected_suite(unquote(s).zest_case_count()) {
          unquote(s).zest_run_selected_case(:zig.Zest.selected_suite_index())
        }
      }
    }

    quote {
      import Zest.Runner

      @doc = """
        Generated Zest test runner entry point.
        """

      pub fn main(_args :: [String]) -> u8 {
        Zest.Runner.configure()
        zest_run_discovered_cases(:zig.Zest.start_position(), zest_total_case_count())
        Zest.Runner.run()
      }

      fn zest_total_case_count() -> i64 {
        unquote(total_case_count)
      }

      fn zest_run_discovered_cases(position :: i64, total_count :: i64) -> String {
        if position >= total_count {
          "ok"
        } else {
          :zig.Zest.begin_shuffle_pass(position, total_count)
          unquote_splicing(selected_suite_scans)
          :zig.Zest.end_shuffle_pass()
          zest_run_discovered_cases(position + 1, total_count)
        }
      }
    }
  }

  # Builds the total-case-count expression for the half-open range
  # [start_index, end_index) of `test_structs` by divide and conquer, so
  # the macro recursion depth stays at log2(count) instead of count. A
  # linear one-struct-per-level recursion hits the comptime dispatch
  # recursion limit as soon as the suite reaches that many test structs;
  # the balanced split keeps discovery scalable to arbitrarily large
  # suites.
  macro build_total_case_count(test_structs :: Expr, start_index :: Expr, end_index :: Expr) -> Expr {
    if start_index >= end_index {
      quote { 0 }
    } else {
      if start_index + 1 == end_index {
        test_struct = list_at(test_structs, start_index)

        quote {
          unquote(test_struct).zest_case_count()
        }
      } else {
        midpoint = (start_index + end_index) / 2
        left_count = build_total_case_count(test_structs, start_index, midpoint)
        right_count = build_total_case_count(test_structs, midpoint, end_index)

        quote {
          unquote(left_count) + unquote(right_count)
        }
      }
    }
  }

  @doc = """
    Normalizes runner options to a list.

    `nil` and `[]` become an empty list, an existing option list is returned
    as-is, and a single non-list option is wrapped in a one-element list.
    """

  pub macro options(opts :: Expr) -> Expr {
    if opts == nil {
      []
    } else {
      if opts == [] {
        []
      } else {
        if list_length(opts) == 0 {
          [opts]
        } else {
          opts
        }
      }
    }
  }

  @doc = """
    Parses Zest runtime options from CLI arguments and applies them
    to the test tracker. If `--seed <integer>` is present, sets the
    seed explicitly for reproducible ordering. Otherwise the tracker
    generates a seed from the system clock.

    If `--timeout <milliseconds>` is present, sets a per-test
    timeout. Tests exceeding the timeout are marked as failed
    with a yellow "T" indicator.

    If `--timings` is present, the summary prints every test case
    duration in execution order. If `--slowest <count>` is present,
    the summary prints the slowest `count` test cases.

    Call this before running any tests to ensure the seed and
    reporting options are set.
    """

  pub fn configure() -> Atom {
    parse_cli_args(0, System.arg_count())
  }

  @doc = """
    Prints the test summary with counts and exits with a
    failure code if any tests failed.

    Call this as the last line of the test runner's `main`
    function. It invokes `:zig.Zest.summary()` which outputs
    the final report to stdout, including the seed used for
    test ordering, and maps any nonzero failure count to exit
    code `1`.

    ## Examples

        pub fn main(_args :: [String]) -> u8 {
          Zest.Runner.configure()
          Test.MyTest.run()
          Zest.Runner.run()
        }
    """

  pub fn run() -> u8 {
    failures = :zig.Zest.summary()
    if failures == 0 {
      0
    } else {
      1
    }
  }

  @doc = """
    Recursively scans CLI arguments for Zest runtime options and applies
    each to the test tracker.
    """

  pub fn parse_cli_args(index :: i64, count :: i64) -> Atom {
    if index >= count {
      :ok
    } else {
      if System.arg_at(index) == "--seed" {
        if index + 1 < count {
          set_seed_from_arg(System.arg_at(index + 1))
          parse_cli_args(index + 2, count)
        } else {
          :ok
        }
      } else {
        if System.arg_at(index) == "--timeout" {
          if index + 1 < count {
            set_timeout_from_arg(System.arg_at(index + 1))
            parse_cli_args(index + 2, count)
          } else {
            :ok
          }
        } else {
          if System.arg_at(index) == "--timings" {
            :zig.Zest.enable_timings()
            parse_cli_args(index + 1, count)
          } else {
            if System.arg_at(index) == "--slowest" {
              if index + 1 < count {
                set_slowest_limit_from_arg(System.arg_at(index + 1))
                parse_cli_args(index + 2, count)
              } else {
                :ok
              }
            } else {
              if System.arg_at(index) == "--resume-after" {
                if index + 1 < count {
                  set_resume_after_from_arg(System.arg_at(index + 1))
                  parse_cli_args(index + 2, count)
                } else {
                  :ok
                }
              } else {
                if System.arg_at(index) == "--supervised" {
                  :zig.Zest.enable_supervised()
                  parse_cli_args(index + 1, count)
                } else {
                  parse_cli_args(index + 1, count)
                }
              }
            }
          }
        }
      }
    }
  }

  fn set_seed_from_arg(value :: String) -> Atom {
    set_seed_from_optional(Integer.parse(value))
  }

  fn set_seed_from_optional(nil) -> Atom {
    :ok
  }

  fn set_seed_from_optional(seed :: i64) -> Atom {
    :zig.Zest.set_seed(seed)
    :ok
  }

  fn set_timeout_from_arg(value :: String) -> Atom {
    set_timeout_from_optional(Integer.parse(value))
  }

  fn set_timeout_from_optional(nil) -> Atom {
    :ok
  }

  fn set_timeout_from_optional(timeout :: i64) -> Atom {
    :zig.Zest.set_timeout(timeout)
    :ok
  }

  fn set_resume_after_from_arg(value :: String) -> Atom {
    set_resume_after_from_optional(Integer.parse(value))
  }

  fn set_resume_after_from_optional(nil) -> Atom {
    :ok
  }

  fn set_resume_after_from_optional(ordinal :: i64) -> Atom {
    :zig.Zest.set_resume_after(ordinal)
    :ok
  }

  fn set_slowest_limit_from_arg(value :: String) -> Atom {
    set_slowest_limit_from_optional(Integer.parse(value))
  }

  fn set_slowest_limit_from_optional(nil) -> Atom {
    :ok
  }

  fn set_slowest_limit_from_optional(limit :: i64) -> Atom {
    :zig.Zest.set_slowest_limit(limit)
    :ok
  }

  macro patterns(options :: Expr) -> Expr {
    pattern_groups = for option <- options {
      option_patterns(option)
    }
    flattened_patterns = list_flatten(pattern_groups)

    if flattened_patterns == [] {
      ["test/**/*_test.zap"]
    } else {
      flattened_patterns
    }
  }

  macro option_patterns(option :: Expr) -> Expr {
    if elem(option, 0) == :pattern {
      pattern_values(elem(option, 1))
    } else {
      if elem(option, 0) == :patterns {
        pattern_values(elem(option, 1))
      } else {
        []
      }
    }
  }

  macro pattern_values(value :: Expr) -> Expr {
    if value == [] {
      []
    } else {
      if list_length(value) == 0 {
        [value]
      } else {
        value
      }
    }
  }

}
