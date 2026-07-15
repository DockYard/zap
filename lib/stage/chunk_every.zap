@doc = """
  A `Stage` that batches items into consecutive groups of a fixed size,
  emitting each full group as a single `[element]` output.

  `ChunkEveryStage(element)` is the stage behind `Stream.chunk_every/2`. It
  buffers items in explicit list state; a completed group is emitted and the
  buffer reset, and `flush` emits the final partial group (if any).
  """

pub struct ChunkEveryStage(element) {
  count :: i64
  buffer :: [element]
}

@doc = """
  The chunking `Stage` behaviour: accumulate items, emitting a group each time
  the buffer fills, and the final partial group on flush.
  """

pub impl Stage(element, [element]) for ChunkEveryStage(element) {
  @doc = """
    Appends the item to the buffer; when the buffer reaches the chunk size,
    emits it as one group and resets, otherwise emits nothing.
    """

  pub fn step(stage :: unique ChunkEveryStage(element), item :: element) -> {Atom, [[element]], ChunkEveryStage(element)} {
    ChunkEveryStage.absorb(stage.count, stage.buffer, item)
  }

  @doc = """
    Emits the final partial group when the buffer is non-empty, otherwise
    nothing.
    """

  pub fn flush(stage :: unique ChunkEveryStage(element)) -> [[element]] {
    ChunkEveryStage.drain(stage.count, stage.buffer)
  }

  fn absorb(count :: i64, buffer :: [element], item :: element) -> {Atom, [[element]], ChunkEveryStage(element)} {
    filled = List.concat(buffer, [item])
    if List.length(filled) >= count {
      ChunkEveryStage.emit_group(count, filled)
    } else {
      ChunkEveryStage.keep(count, filled)
    }
  }

  fn emit_group(count :: i64, group :: [element]) -> {Atom, [[element]], ChunkEveryStage(element)} {
    {:cont, [group], %ChunkEveryStage(element){count: count, buffer: ([] :: [element])}}
  }

  fn keep(count :: i64, buffer :: [element]) -> {Atom, [[element]], ChunkEveryStage(element)} {
    {:cont, ([] :: [[element]]), %ChunkEveryStage(element){count: count, buffer: buffer}}
  }

  fn drain(_count :: i64, buffer :: [element]) -> [[element]] {
    if List.length(buffer) == 0 {
      ([] :: [[element]])
    } else {
      [buffer]
    }
  }
}
