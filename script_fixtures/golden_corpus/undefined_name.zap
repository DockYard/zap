# Golden corpus — an undefined name with a did-you-mean fix-it (domain=name).
#
# `greetng/0` is a typo for the sibling `greeting/0`; the renderer attaches a
# `did you mean greeting/0?` suggestion (a MachineApplicable-style fix-it).
pub struct UndefinedName {
  pub fn greet() -> String {
    greetng()
  }

  pub fn greeting() -> String {
    "hello"
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(UndefinedName.greet())
  0
}
