# List

A `List` in Zap is a singly-linked list of homogeneous elements. The literal
syntax is `[1, 2, 3]`, and the cons pattern is `[head | tail]`.

Because lists are linked, the access patterns are asymmetric: `head/1` and
`prepend/2` are O(1); `last/1`, `append/2`, and `at/2` are O(n). When you
need fast random access or constant-time append, a different shape (an array
or a map keyed by index) is the right tool. When you need cheap structural
sharing and pattern matching, lists are the right tool.

## Construction and destructuring

```zap
xs = [1, 2, 3]
[head | tail] = xs       # head = 1, tail = [2, 3]
[]                       # the empty list
```

Pattern matching extends to function clauses:

```zap
pub fn sum([] :: [i64]) -> i64 {
  0
}

pub fn sum([head | tail] :: [i64]) -> i64 {
  head + sum(tail)
}
```

The first clause binds the empty case; the second binds head and tail and
recurses. Zap's overload resolver picks the right clause without you writing
a `case` body.

## Two shapes of operations

`List` exposes the operations that need to know about the linked structure
of a list — `head/1`, `tail/1`, `prepend/2`, `append/2`, `concat/2`, plus
the bang versions for known-non-empty lists.

`Enum` exposes the operations that work on any enumerable — `map/2`,
`filter/2`, `reduce/3`, `take/2`, `drop/2`, etc. They work on lists too,
because `List` implements `Enumerable`.

If a function exists in both modules, prefer the `Enum` version when you
might generalize later, and the `List` version when you specifically want
the list-shape behavior.

## Bang versions

Functions that fail on the empty list come in pairs:

```zap
List.head([1, 2, 3])     # => 1
List.head([])            # => raises

List.head!([1, 2, 3])    # => 1
List.head!([])           # => raises (same)
```

The convention: a trailing `!` means "this function trusts you that the
input meets its precondition; if not, it raises." Use it when you've just
checked emptiness or when the type system has narrowed the input. Use the
non-bang version when you have a sensible default to provide.

## Building lists efficiently

Prepending is cheap (`O(1)`); appending is expensive (`O(n)`). Build lists
by prepending and reverse at the end:

```zap
pub fn collect_evens(xs :: [i64]) -> [i64] {
  collect_evens_loop(xs, [])
}

fn collect_evens_loop([] :: [i64], acc :: [i64]) -> [i64] {
  List.reverse(acc)
}

fn collect_evens_loop([head | tail] :: [i64], acc :: [i64]) -> [i64] {
  if Integer.even?(head) {
    collect_evens_loop(tail, [head | acc])
  } else {
    collect_evens_loop(tail, acc)
  }
}
```

In practice you'd write that as `Enum.filter(xs, &Integer.even?/1)`. The
hand-written version is what `Enum.filter` becomes after lowering.

## Concatenation

Two lists join with `concat/2` or the `<>` operator (via `Concatenable`):

```zap
List.concat([1, 2], [3, 4])    # => [1, 2, 3, 4]
[1, 2] <> [3, 4]               # => [1, 2, 3, 4]
```

`concat/2` walks the left list and prepends each element to the right list,
so it's `O(left)`. Don't use it inside an inner loop over the right list.

## Querying

```zap
List.length([1, 2, 3])         # => 3
List.empty?([])                # => true
List.contains?([1, 2, 3], 2)   # => true
List.uniq([1, 1, 2, 3, 2])     # => [1, 2, 3]
List.reverse([1, 2, 3])        # => [3, 2, 1]
```

`length/1` walks the whole list — there is no cached length. If you find
yourself calling `length` repeatedly in a loop, restructure to count once.

## See also

- `Enum` — operations that work on every enumerable, including lists
- `Range` — when you want a list-of-integers but don't want to materialize it
- `Map` — when you need keyed access instead of positional
