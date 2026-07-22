@doc = """
  The lazy element-wise pairing produced by `Stream.zip/2`: an
  `Enumerable({a, b})` that pulls one element from each of two boxed sources per
  `next` and yields them as a tuple.

  `Stream.Zip(a, b)` holds the two sources (`left` and `right`) as boxed `Enumerable`
  fields. Each `next` pulls `left`, then `right`; when both yield it emits
  `{a, b}` and threads both advanced sources forward. As soon as EITHER source
  reports `:done`, the zip ends and disposes BOTH sources — the exhausted one
  and the still-live one — each exactly once. On the right-terminated path the
  element already pulled from `left` is released, since it can never be paired.
  Nothing is pulled until demanded, so `Stream.zip` composes with bounded
  consumers (`Enum.take`, `Stream.take`) that pull only the pairs they need.
  """

pub struct Stream.Zip(a, b) {
  left :: Enumerable(a)
  right :: Enumerable(b)
}

@doc = """
  The `Enumerable({a, b})` behaviour of a `Stream.Zip`: pull one from each source per
  `next`, ending — and disposing both sources — the moment either is exhausted.
  """

pub impl Enumerable({a, b}) for Stream.Zip(a, b) {
  @doc = """
    Pulls `left` then `right`: yields `{a, b}` when both continue; ends and
    disposes both sources the moment either reports `:done`.
    """

  pub fn next(self :: unique Stream.Zip(a, b)) -> {Atom, {a, b}, Stream.Zip(a, b)} {
    Stream.Zip.pull(self.left, self.right)
  }

  @doc = """
    Disposes an unconsumed zip: releases both source iteration states without
    pulling either.
    """

  pub fn dispose(self :: unique Stream.Zip(a, b)) -> Nil {
    Stream.Zip.dispose_parts(self.left, self.right)
  }

  fn dispose_parts(left :: unique Enumerable(a), right :: unique Enumerable(b)) -> Nil {
    Enumerable.dispose(left)
    Enumerable.dispose(right)
    nil
  }

  fn pull(left :: unique Enumerable(a), right :: unique Enumerable(b)) -> {Atom, {a, b}, Stream.Zip(a, b)} {
    case Enumerable.next(left) {
      {:done, _manufactured_left, left_done} -> Stream.Zip.left_exhausted(left_done, right)
      {:cont, value_left, left_next} -> Stream.Zip.pull_right(left_next, right, value_left)
    }
  }

  fn left_exhausted(left_done :: unique Enumerable(a), right :: unique Enumerable(b)) -> {Atom, {a, b}, Stream.Zip(a, b)} {
    Enumerable.dispose(left_done)
    Enumerable.dispose(right)
    Stream.Zip.emit_done()
  }

  fn pull_right(left_next :: unique Enumerable(a), right :: unique Enumerable(b), value_left :: a) -> {Atom, {a, b}, Stream.Zip(a, b)} {
    case Enumerable.next(right) {
      {:done, _manufactured_right, right_done} -> Stream.Zip.right_exhausted(left_next, right_done, value_left)
      {:cont, value_right, right_next} -> {:cont, {value_left, value_right}, %Stream.Zip(a, b){left: left_next, right: right_next}}
    }
  }

  fn right_exhausted(left_next :: unique Enumerable(a), right_done :: unique Enumerable(b), value_left :: a) -> {Atom, {a, b}, Stream.Zip(a, b)} {
    Stream.Zip.drop_value(value_left)
    Enumerable.dispose(left_next)
    Enumerable.dispose(right_done)
    Stream.Zip.emit_done()
  }

  fn drop_value(_value :: a) -> Nil {
    nil
  }

  # Manufacture the ignored `{a, b}` value for the terminal `:done` triple from
  # two single-element-type empty lists (`[a]`, `[b]`). This mirrors how
  # `Stream.Transform`/`Stream.Unfold` manufacture a terminal element via an empty source, but
  # never annotates a list with the two-type-variable tuple element `[{a, b}]`,
  # which the monomorphizer specializes generic unions (e.g. `Option`) over.
  fn emit_done() -> {Atom, {a, b}, Stream.Zip(a, b)} {
    case Enumerable.next(([] :: [a])) {
      {_atom_left, manufactured_left, spent_left} -> Stream.Zip.emit_done_left(manufactured_left, spent_left)
    }
  }

  fn emit_done_left(manufactured_left :: a, spent_left :: unique Enumerable(a)) -> {Atom, {a, b}, Stream.Zip(a, b)} {
    Enumerable.dispose(spent_left)
    case Enumerable.next(([] :: [b])) {
      {_atom_right, manufactured_right, spent_right} -> Stream.Zip.emit_done_right(manufactured_left, manufactured_right, spent_right)
    }
  }

  fn emit_done_right(manufactured_left :: a, manufactured_right :: b, spent_right :: unique Enumerable(b)) -> {Atom, {a, b}, Stream.Zip(a, b)} {
    Enumerable.dispose(spent_right)
    {:done, {manufactured_left, manufactured_right}, %Stream.Zip(a, b){left: ([] :: [a]), right: ([] :: [b])}}
  }
}
