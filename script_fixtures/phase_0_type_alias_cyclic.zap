# Phase 0: a non-productive cyclic alias (`type A = B; type B = A`) must
# produce a CLEAN compile diagnostic, never an infinite loop or stack
# overflow. The alias expansion never reaches a concrete type, so the
# resolver must detect the cycle and report it.
#
# This is a NEGATIVE fixture: it is expected to FAIL to compile with a
# "cyclic type alias" diagnostic.

type A = B
type B = A

pub struct User {
  pub fn use_it(value :: A) -> A {
    value
  }
}

fn main(_args :: [String]) -> u8 {
  0
}
