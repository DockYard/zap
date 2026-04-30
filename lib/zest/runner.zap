pub struct Zest.Runner {
  @structdoc = """
    Discovers and runs Zest test structs.

    `use Zest.Runner` expands into a test runner `main/1` that discovers
    Zap source files from configured glob patterns, reflects their structs,
    invokes each discovered struct's `run/0`, and then prints the summary.
    """

  @requires = [:read_file, :reflect_source]

  @fndoc = """
    Imports `Zest.Runner` and generates a `main/1` test entry point.

    Options are normalized through `Zest.Runner.options/1`. The supported
    option keys are `:pattern` and `:patterns`; either may contain a single
    glob string or a list of glob strings. When no pattern is configured,
    the runner uses `test/**/*_test.zap`.
    """

  pub macro __using__(_opts :: Expr) -> Expr {
    _options = options(_opts)
    _patterns = patterns(_options)
    _source_paths = __zap_list_flatten__(for _pattern <- _patterns {
      Path.glob(_pattern)
    })
    _source_structs = __zap_list_flatten__(for _source_path <- _source_paths {
      __zap_source_graph_structs__(_source_path)
    })
    _test_structs = for _struct <- _source_structs, has_run?(_struct) {
      _struct
    }
    _run_calls = for _struct <- _test_structs {
      quote {
        unquote(_struct).run()
      }
    }

    quote {
      import Zest.Runner

      pub fn main(_args :: [String]) -> String {
        Zest.Runner.configure()
        unquote_splicing(_run_calls)
        Zest.Runner.run()
      }
    }
  }

  @fndoc = """
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
        if __zap_list_len__(opts) == 0 {
          [opts]
        } else {
          opts
        }
      }
    }
  }

  @fndoc = """
    Parses `--seed` and `--timeout` from CLI arguments and applies
    them to the test tracker. If `--seed <integer>` is present,
    sets the seed explicitly for reproducible ordering. Otherwise
    the tracker generates a seed from the system clock.

    If `--timeout <milliseconds>` is present, sets a per-test
    timeout. Tests exceeding the timeout are marked as failed
    with a yellow "T" indicator.

    Call this before running any tests to ensure the seed and
    timeout are set.
    """

  pub fn configure() -> Atom {
    parse_cli_args(0, System.arg_count())
  }

  @fndoc = """
    Prints the test summary with counts and exits with a
    failure code if any tests failed.

    Call this as the last line of the test runner's `main`
    function. It invokes `:zig.Zest.summary()` which
    outputs the final report to stdout, including the seed
    used for test ordering.

    ## Examples

        pub fn main(_args :: [String]) -> String {
          Zest.Runner.configure()
          Test.MyTest.run()
          Zest.Runner.run()
        }
    """

  pub fn run() -> String {
    :zig.Zest.summary()
    "done"
  }

  @fndoc = """
    Recursively scans CLI arguments for `--seed <value>` and
    `--timeout <milliseconds>`, applying each to the test tracker.
    """

  pub fn parse_cli_args(index :: i64, count :: i64) -> Atom {
    if index >= count {
      :ok
    } else {
      if System.arg_at(index) == "--seed" {
        if index + 1 < count {
          :zig.Zest.set_seed(Integer.parse(System.arg_at(index + 1)))
          parse_cli_args(index + 2, count)
        } else {
          :ok
        }
      } else {
        if System.arg_at(index) == "--timeout" {
          if index + 1 < count {
            :zig.Zest.set_timeout(Integer.parse(System.arg_at(index + 1)))
            parse_cli_args(index + 2, count)
          } else {
            :ok
          }
        } else {
          parse_cli_args(index + 1, count)
        }
      }
    }
  }

  macro patterns(options :: Expr) -> Expr {
    _pattern_groups = for _option <- options {
      option_patterns(_option)
    }
    _patterns = __zap_list_flatten__(_pattern_groups)

    if _patterns == [] {
      ["test/**/*_test.zap"]
    } else {
      _patterns
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
      if __zap_list_len__(value) == 0 {
        [value]
      } else {
        value
      }
    }
  }

  @requires = [:reflect_source]
  macro has_run?(struct_ref :: Expr) -> Expr {
    _matches = for _function <- __zap_struct_functions__(struct_ref), __zap_map_get__(_function, :name, "") == "run" and __zap_map_get__(_function, :arity, -1) == 0 {
      _function
    }

    __zap_list_len__(_matches) > 0
  }

}
