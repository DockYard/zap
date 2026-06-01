## Windows-argv follow-up (#343) cross-link fixture.
##
## Iterates the process command-line arguments and prints each on its own
## line, exercising the runtime's `System.arg_count`/`System.arg_at` path —
## which routes through `getArgv()` -> `RuntimeOs.argv()`, the seam arm whose
## Windows implementation now tokenizes the PEB `CommandLine` WTF-16 string
## (CommandLineToArgvW quote/backslash rules) and transcodes it to UTF-8.
## Used to confirm a real args-reading Zap program cross-links as
## `x86_64-windows-gnu` `PE32+` (and, where a Windows host / wine is
## available, prints its arguments correctly).
##
## Expected stdout for `... -- alpha "beta gamma" delta`:
##
##     argc=3
##     alpha
##     beta gamma
##     delta

pub struct ArgvEcho {
  pub fn print_from(index :: i64, count :: i64) -> i64 {
    if index < count {
      IO.puts(System.arg_at(index))
      ArgvEcho.print_from(index + 1, count)
    } else {
      0
    }
  }
}

fn main(_args :: [String]) -> u8 {
  count = System.arg_count()
  IO.puts("argc=#{count}")
  ArgvEcho.print_from(0, count)
  0
}
