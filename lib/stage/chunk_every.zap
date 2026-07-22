@doc = """
  A `Stage` that batches items into consecutive groups of a fixed size,
  emitting each full group as a single `[element]` output.

  `Stage.ChunkEvery(element)` is the stage behind `Stream.chunk_every/2`. It
  buffers items in explicit list state; a completed group is emitted and the
  buffer reset, and `flush` emits the final partial group (if any).
  """

pub struct Stage.ChunkEvery(element) {
  count :: i64
  buffer :: [element]
}

@doc = """
  The chunking `Stage` behaviour: accumulate items, emitting a group each time
  the buffer fills, and the final partial group on flush.
  """

pub impl Stage(element, [element]) for Stage.ChunkEvery(element) {
  @doc = """
    Appends the item to the buffer; when the buffer reaches the chunk size,
    emits it as one group and resets, otherwise emits nothing.
    """

  pub fn step(stage :: unique Stage.ChunkEvery(element), item :: element) -> {Atom, [[element]], Stage.ChunkEvery(element)} {
    Stage.ChunkEvery.absorb(stage.count, stage.buffer, item)
  }

  @doc = """
    Emits the final partial group when the buffer is non-empty, otherwise
    nothing.
    """

  pub fn flush(stage :: unique Stage.ChunkEvery(element)) -> [[element]] {
    Stage.ChunkEvery.drain(stage.count, stage.buffer)
  }

  fn absorb(count :: i64, buffer :: [element], item :: element) -> {Atom, [[element]], Stage.ChunkEvery(element)} {
    filled = List.concat(buffer, [item])
    if List.length(filled) >= count {
      Stage.ChunkEvery.emit_group(count, filled)
    } else {
      Stage.ChunkEvery.keep(count, filled)
    }
  }

  fn emit_group(count :: i64, group :: [element]) -> {Atom, [[element]], Stage.ChunkEvery(element)} {
    {:cont, [group], %Stage.ChunkEvery(element){count: count, buffer: ([] :: [element])}}
  }

  fn keep(count :: i64, buffer :: [element]) -> {Atom, [[element]], Stage.ChunkEvery(element)} {
    {:cont, ([] :: [[element]]), %Stage.ChunkEvery(element){count: count, buffer: buffer}}
  }

  fn drain(_count :: i64, buffer :: [element]) -> [[element]] {
    if List.length(buffer) == 0 {
      ([] :: [[element]])
    } else {
      [buffer]
    }
  }
}
