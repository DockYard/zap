pub protocol Enumerable {
  fn reduce(collection, accumulator, callback :: (accumulator, member -> {Atom, accumulator})) -> {Atom, accumulator}
}
