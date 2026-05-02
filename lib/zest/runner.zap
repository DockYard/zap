@doc = """
  Discovers and runs Zest test structs.

  `use Zest.Runner` expands into a test runner `main/1` that discovers
  Zap source files from configured glob patterns, reflects their structs,
  invokes each discovered struct's `run/0`, and then prints the summary.
  """

pub struct Zest.Runner {
  @doc = """
    Imports `Zest.Runner` and generates a `main/1` test entry point.

    Options are normalized through `Zest.Runner.options/1`. The supported
    option keys are `:pattern` and `:patterns`; either may contain a single
    glob string or a list of glob strings. When no pattern is configured,
    the runner uses `test/**/*_test.zap`.
    """

  pub macro __using__(_opts :: Expr) -> Expr {
    _options = options(_opts)
    _patterns = patterns(_options)
    _source_paths = list_flatten(for _pattern <- _patterns {
      Path.glob(_pattern)
    })
    _source_structs = list_flatten(for _source_path <- _source_paths {
      SourceGraph.structs(_source_path)
    })
    _test_structs = for _struct <- _source_structs, Struct.has_function?(_struct, "run", 0) {
      _struct
    }
    _run_calls = for _struct <- _test_structs {
      quote {
        unquote(_struct).run()
      }
    }

    quote {
      import Zest.Runner

      @doc = "Generated Zest test runner entry point."

      pub fn main(_args :: [String]) -> String {
        Zest.Runner.configure()
        unquote_splicing(_run_calls)
        Zest.Runner.run()
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

  @doc = """
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

  @doc = """
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
    _patterns = list_flatten(_pattern_groups)

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
      if list_length(value) == 0 {
        [value]
      } else {
        value
      }
    }
  }

}
