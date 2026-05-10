# List

A `List` in Zap is a homogeneous sequence backed by a single contiguous
runtime buffer. The literal syntax is `[1, 2, 3]`; the generic type spelling is
`List(i64)`, `List(String)`, and so on.

Zap has one sequence type: indexed reads, append-at-end operations, and list
literals all use `List(T)`.

## Construction and Destructuring

```zap
xs = [1, 2, 3]
[]                         # the empty list

values = List.new_filled(4, 0 :: i64)
scratch = List.new_empty(32) :: List(i64)
```

`new_filled/2` allocates a list with a populated length. `new_empty/1`
allocates a list with reserved capacity and length `0`, which is useful when
you will build the list with `push/2`.

Head/tail patterns still describe sequence shape, not storage layout:

```zap
pub fn sum([] :: [i64]) -> i64 {
  0
}

pub fn sum([head | tail] :: [i64]) -> i64 {
  head + sum(tail)
}
```

The first clause binds the empty case; the second binds the first element and
the remaining list. The runtime representation is still flat-buffer-backed.

## Indexed Access

```zap
xs = [10, 20, 30]

List.length(xs)            # => 3
List.capacity(xs)          # reserved slots in the backing buffer
List.get(xs, 1)            # => 20
List.at(xs, 2)             # => 30
List.set(xs, 1, 99)        # => [10, 99, 30]
```

`get/2` and `at/2` are aliases. `at!/2` performs the same read after an
explicit bounds check and raises on an invalid index.

## Value Semantics and Mutation

List operations are value-semantic: `set/3`, `push/2`, `pop/1`, and `append/2`
return a list value and do not expose mutation to user code.

Under the hood, Zap uses copy-on-write. When a list buffer is uniquely owned,
the runtime may update it in place and return the same handle. When it is
shared, the runtime clones first so existing observers keep their original
view.

```zap
values = List.new_filled(3, 0 :: i64)
values = List.set(values, 1, 42 :: i64)
values = List.push(values, 7 :: i64)

popped = List.pop(values)
shorter = popped.0
removed = popped.1
```

This is the same surface contract for scalar lists, string lists, nested lists,
and lists containing ARC-managed values.

## Building Lists Efficiently

When you are growing a list in order, prefer `new_empty/1` plus `push/2`:

```zap
pub fn collect_evens(xs :: [i64]) -> [i64] {
  collect_evens_loop(xs, 0, List.length(xs), List.new_empty(List.length(xs)))
}

fn collect_evens_loop(xs :: [i64], index :: i64, total :: i64, acc :: [i64]) -> [i64] {
  if index < total {
    value = List.get(xs, index)
    next_acc = if Integer.even?(value) {
      List.push(acc, value)
    } else {
      acc
    }
    collect_evens_loop(xs, index + 1, total, next_acc)
  } else {
    acc
  }
}
```

In practice you would usually write that as `Enum.filter(xs, &Integer.even?/1)`
or `List.filter(xs, &Integer.even?/1)`. The explicit version shows the
flat-buffer-friendly pattern: iterate by index and append to the end.

## Concatenation

Two lists join with `append/2`, `concat/2`, or the `<>` operator through
`Concatenable`:

```zap
List.append([1, 2], [3, 4])    # => [1, 2, 3, 4]
List.concat([1, 2], [3, 4])    # => [1, 2, 3, 4]
[1, 2] <> [3, 4]               # => [1, 2, 3, 4]
```

`append/2` can reuse the left buffer when it is uniquely owned and has enough
capacity. Otherwise it allocates a new buffer and copies the elements.

## Querying and Slicing

```zap
List.empty?([])                # => true
List.head([1, 2, 3])           # => 1
List.tail([1, 2, 3])           # => [2, 3]
List.last([1, 2, 3])           # => 3
List.contains?([1, 2, 3], 2)   # => true
List.take([1, 2, 3, 4], 2)     # => [1, 2]
List.drop([1, 2, 3, 4], 2)     # => [3, 4]
List.reverse([1, 2, 3])        # => [3, 2, 1]
List.uniq([1, 1, 2, 3, 2])     # => [1, 2, 3]
```

`tail/1`, `take/2`, and `drop/2` return fresh list values containing the
selected elements.

## Bang Versions

Functions that should only be called with a non-empty or in-bounds list have
bang variants:

```zap
List.head!([1, 2, 3])          # => 1
List.last!([1, 2, 3])          # => 3
List.at!([10, 20, 30], 1)      # => 20
```

Use them when the precondition has already been established. Otherwise use the
non-bang versions or make the check explicit.

## See Also

- `Enum` — operations that work on every enumerable, including lists
- `Range` — when you want integer iteration without materializing a list
- `Map` — when you need keyed access instead of positional access
