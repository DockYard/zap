pub const borrowed_closure_arg =
    \\pub module Test {
    \\  opaque Handle = String
    \\
    \\  pub fn run(use_fn :: (borrowed Handle -> Handle), handle :: Handle) -> Handle {
    \\    use_fn(handle)
    \\  }
    \\}
;

pub const shared_closure_arg =
    \\pub module Test {
    \\  opaque Handle = String
    \\
    \\  pub fn run(use_fn :: (shared Handle -> Handle), handle :: Handle) -> Handle {
    \\    use_fn(handle)
    \\  }
    \\}
;

pub const switch_dispatch =
    \\pub module Foo {
    \\  pub fn inc(x :: i64) -> i64 {
    \\    x + 1
    \\  }
    \\
    \\  pub fn dec(x :: i64) -> i64 {
    \\    x - 1
    \\  }
    \\
    \\  pub fn apply(f :: (i64 -> i64), value :: i64) -> i64 {
    \\    f(value)
    \\  }
    \\
    \\  pub fn choose(flag :: Bool) -> (i64 -> i64) {
    \\    if flag {
    \\      inc
    \\    } else {
    \\      dec
    \\    }
    \\  }
    \\
    \\  pub fn run(flag :: Bool) -> i64 {
    \\    apply(choose(flag), 10)
    \\  }
    \\}
;

pub const non_escaping_closure =
    \\pub module Foo {
    \\  pub fn run(x :: i64) -> i64 {
    \\    f = fn(y :: i64) -> i64 {
    \\      x + y
    \\    }
    \\    f(2)
    \\  }
    \\}
;
