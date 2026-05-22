# Phase 2.f GP1 acceptance: an unmatched `case` (no clause matches the
# scrutinee) is an unrecoverable abort. It must route through the SAME
# unified crash path as `raise`/`@panic`/contracts — a `** (match_error)`
# header plus a symbolized Zap backtrace — NOT the legacy bare
# `panic: <msg>` + exit(1) that produced no backtrace.
#
# The match fails two Zap frames deep (`main` -> `classify`) so the
# captured backtrace shows distinct Zap symbols with Zap source
# locations.
#
# Expected (Debug, default ZAP_BACKTRACE=short):
#   ** (match_error) no matching clause ...
#     MatchCrash.classify/1 at phase_2f_gp1_match_fail.zap:<line>
#     ...
#
# This fixture aborts non-zero; it never reaches the `0` return.

pub struct MatchCrash {
  pub fn classify(value :: Integer) -> String {
    case value {
      1 -> "one"
      2 -> "two"
    }
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(MatchCrash.classify(99))
  0
}
