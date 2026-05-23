# Golden corpus — a runtime raise crash report WITH a cross-function error
# return trace (ERT chain).
#
# The raise happens three Zap frames deep (`main` -> `outermost` -> `middle`
# -> `deepest`), so the crash report carries the `** (kaboom_error) ...` header
# with its symbolized backtrace AND an `error return trace:` listing the frames
# the unrecovered error unwound through.

@code Z9501
pub error KaboomError {
  detail :: String

  pub fn message(self :: KaboomError) -> String {
    self.detail
  }
}

pub struct Chain {
  pub fn deepest() -> Never {
    raise %KaboomError{detail: "kaboom from the deepest frame"}
  }

  pub fn middle() -> Never {
    Chain.deepest()
  }

  pub fn outermost() -> Never {
    Chain.middle()
  }
}

fn main(_args :: [String]) -> u8 {
  Chain.outermost()
  0
}
