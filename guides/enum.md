# Enum

`Enum` is the ergonomic surface for everything that knows how to enumerate.
It works against the `Enumerable` protocol, so the same calls you use on a
list also work on ranges, maps, strings, and any user-defined type that
implements the protocol.

The library is materializing rather than streaming: anything that produces a
collection produces a list. There is no separate "lazy stream" type. If you
need a single value (`reduce`, `sum`, `count`), no list is built.

## Why a single `Enum` module

In Zap there is no method dispatch on values. `[1, 2, 3].map(...)` is not a
thing. Instead, `Enum.map([1, 2, 3], ...)` reaches into the value through the
`Enumerable` protocol and gets back `[2, 4, 6]`. One module, one set of
function names, every collection.

This matters because protocols are resolved at compile time. The cost of
`Enum.map(range, ...)` against a range is the same as a hand-written loop.

## Three families of operations

Most of `Enum` falls into three buckets.

### Transform — produce a new collection

`map/2`, `filter/2`, `reject/2`, `flat_map/2`, `take/2`, `drop/2`,
`reverse/1`, `uniq/1`, and `sort/2` all return a list.

```zap
Enum.map([1, 2, 3], fn(x) { x * 2 })
# => [2, 4, 6]

Enum.filter(1..10, fn(n) { Integer.even?(n) })
# => [2, 4, 6, 8, 10]

Enum.flat_map([[1, 2], [3, 4]], fn(xs) { xs })
# => [1, 2, 3, 4]
```

### Reduce — collapse to a single value

`reduce/3`, `sum/1`, `product/1`, `count/2`, `max/1`, `min/1`.

```zap
Enum.reduce([1, 2, 3, 4], 0, fn(acc, x) { acc + x })   # => 10
Enum.sum(1..10)                                        # => 55
Enum.count([1, 2, 3, 4], fn(x) { x > 2 })              # => 2
```

### Inspect — answer a question without building anything

`any?/2`, `all?/2`, `member?/2`, `empty?/1`, `find/3`, `at/3`.

```zap
Enum.any?([1, 2, 3], fn(x) { x > 10 })   # => false
Enum.all?(1..5, fn(x) { x > 0 })         # => true
Enum.find([1, 2, 3], -1, fn(x) { x > 1 }) # => 2
```

## Composition with pipes

`Enum` is designed to be piped. Write the steps in reading order; let the
shape of the data move through the pipeline.

```zap
1..100
|> Enum.filter(fn(n) { Integer.even?(n) })
|> Enum.map(fn(n) { n * n })
|> Enum.sum()
```

If a step in the middle returns something that does not match, use the catch
basin (`~>`) to short-circuit:

```zap
input
|> parse_number()
|> Enum.take(10)
~> {
  _ -> []
}
```

## `find/3` returns a value, not an option

Unlike Elixir or Rust, Zap does not have a built-in `Some(x)` / `None` type
for "lookup that might miss." `find/3` instead asks you to provide the
default up-front:

```zap
Enum.find([1, 2, 3], 0, fn(x) { x > 100 })  # => 0 (the default)
```

This makes the return type unambiguous and avoids the cost of allocating a
wrapper just to signal absence.

## Implementing `Enumerable` for your own type

If you have a type that conceptually has elements, you can give it the same
ergonomics by implementing the protocol:

```zap
pub impl Enumerable(i64) for MyCounter {
  pub fn next(state :: MyCounter) -> {Atom, i64, MyCounter} {
    case state.remaining {
      0 -> {:done, 0, state}
      _ -> {:next, state.value, %{state | remaining: state.remaining - 1, value: state.value + 1}}
    }
  }
}
```

After that, `Enum.map(my_counter, ...)` and `for x <- my_counter { ... }` work
the same as on any built-in collection.

## See also

- `for` comprehensions — same iteration model with destructuring
- `Range` — a lightweight numeric enumerable
- `List` — list-specific operations that are not part of the `Enumerable` surface
