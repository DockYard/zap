# Golden corpus — an attributed memory leak report (domain=leak).
#
# Run under `-Dmemory=Memory.Tracking`: `%Outer{cause: Some(%Inner{})}`
# heap-promotes the boxed `%Inner{}`, which is then abandoned (never consumed
# or walked), so it survives to `core.deinit` and is reported through the
# unified renderer with its Zap type, size, refcount, allocation-site
# backtrace, and a deterministic per-type summary.

@code Z9601
pub error Inner {}

@code Z9602
pub error Outer {}

fn main(_args :: [String]) -> u8 {
  leaked = %Outer{cause: Option.Some(%Inner{})}
  IO.puts("done")
  0
}
