@doc = """
  A `Stage` that collapses runs of consecutive equal items, emitting an item
  only when it differs from the one immediately before it.

  `DedupeStage(element)` is the stage behind `Stream.dedupe/1`. It remembers
  the previous item as an `Option(element)` — `None` before the first item —
  and reconstructs a fresh stage on every step.
  """

pub struct DedupeStage(element) {
  last :: Option(element)
}

@doc = """
  The dedupe `Stage` behaviour: emit an item only when it is not equal to the
  previous emitted item.
  """

pub impl Stage(element, element) for DedupeStage(element) {
  @doc = """
    Emits the item when it differs from the previous one (always for the first
    item), otherwise emits nothing; in both cases remembers the item.
    """

  pub fn step(stage :: unique DedupeStage(element), item :: element) -> {Atom, [element], DedupeStage(element)} {
    DedupeStage.consider(stage.last, item)
  }

  @doc = """
    Emits nothing on flush — dedupe holds only the previous item.
    """

  pub fn flush(_stage :: unique DedupeStage(element)) -> [element] {
    ([] :: [element])
  }

  fn consider(last :: Option(element), item :: element) -> {Atom, [element], DedupeStage(element)} {
    case last {
      Option.None -> {:cont, [item], %DedupeStage(element){last: Option.Some(item)}}
      Option.Some(previous) ->
        if previous == item {
          {:cont, ([] :: [element]), %DedupeStage(element){last: Option.Some(item)}}
        } else {
          {:cont, [item], %DedupeStage(element){last: Option.Some(item)}}
        }
    }
  }
}
