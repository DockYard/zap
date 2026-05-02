# Enum

Functions for enumerating and transforming collections.

Enum provides higher-order functions that operate on any value
implementing the `Enumerable` protocol. Functions that produce a
collection materialize their result as a list.

## Examples

    Enum.map([1, 2, 3], fn(x) { x * 2 })       # => [2, 4, 6]
    Enum.filter(1..5, fn(x) { x > 2 })          # => [3, 4, 5]
    Enum.reduce(%{a: 1, b: 2}, 0, fn(acc, entry) {
      case entry {
        {_key, value} -> acc + value
      }
    })                                         # => 3

## Functions

### to_list/1

```zap
fn to_list(collection :: Enumerable) -> [element]
```

Converts an enumerable collection to a list.

## Examples

    Enum.to_list(1..3)   # => [1, 2, 3]
    Enum.to_list("ab")   # => ["a", "b"]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L29)

---

### map/2

```zap
fn map(collection :: Enumerable, callback :: (element) -> mapped) -> [mapped]
```

Transforms each element by applying the callback function.

## Examples

    Enum.map([1, 2, 3], fn(x) { x * 2 })  # => [2, 4, 6]
    Enum.map(1..3, fn(x) { x * 2 })       # => [2, 4, 6]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L42)

---

### filter/2

```zap
fn filter(collection :: Enumerable, predicate :: (element) -> Bool) -> [element]
```

Keeps only elements for which the predicate returns true.

## Examples

    Enum.filter([1, 2, 3, 4], fn(x) { x > 2 })  # => [3, 4]
    Enum.filter(1..5, fn(x) { x > 3 })          # => [4, 5]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L55)

---

### reject/2

```zap
fn reject(collection :: Enumerable, predicate :: (element) -> Bool) -> [element]
```

Removes elements for which the predicate returns true.
The opposite of `filter/2`.

## Examples

    Enum.reject([1, 2, 3, 4], fn(x) { x > 2 })  # => [1, 2]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L68)

---

### reduce/3

```zap
fn reduce(collection :: Enumerable, initial :: accumulator, callback :: (accumulator, element) -> accumulator) -> accumulator
```

Folds the collection into a single value using an accumulator.
The callback receives `(accumulator, element)` and returns
the new accumulator.

Dispatches through the Enumerable protocol — works with any
collection type that implements Enumerable.

## Examples

    Enum.reduce([1, 2, 3], 0, fn(acc, x) { acc + x })  # => 6
    Enum.reduce(1..4, 0, fn(acc, x) { acc + x })       # => 10

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L86)

---

### each/2

```zap
fn each(collection :: Enumerable, callback :: (element) -> result) -> Nil
```

Applies the callback to each element for side effects.
Returns `nil` after the collection has been exhausted.

## Examples

    Enum.each([1, 2, 3], fn(x) { IO.puts(Integer.to_string(x)) })

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L99)

---

### find/3

```zap
fn find(collection :: Enumerable, default :: element, predicate :: (element) -> Bool) -> element
```

Returns the first element for which the predicate returns true.
Returns the default value if no element matches.

## Examples

    Enum.find([1, 2, 3, 4], 0, fn(x) { x > 2 })  # => 3
    Enum.find(1..2, 0, fn(x) { x > 10 })         # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L113)

---

### any?/2

```zap
fn any?(collection :: Enumerable, predicate :: (element) -> Bool) -> Bool
```

Returns true if the predicate returns true for any element.

## Examples

    Enum.any?([1, 2, 3], fn(x) { x > 2 })   # => true
    Enum.any?(1..3, fn(x) { x > 10 })       # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L126)

---

### all?/2

```zap
fn all?(collection :: Enumerable, predicate :: (element) -> Bool) -> Bool
```

Returns true if the predicate returns true for all elements.

## Examples

    Enum.all?([2, 4, 6], fn(x) { x > 0 })   # => true
    Enum.all?(1..3, fn(x) { x > 2 })        # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L139)

---

### count/2

```zap
fn count(collection :: Enumerable, predicate :: (element) -> Bool) -> i64
```

Counts elements for which the predicate returns true.

## Examples

    Enum.count([1, 2, 3, 4, 5], fn(x) { x > 2 })  # => 3

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L151)

---

### sum/1

```zap
fn sum(collection :: Enumerable) -> i64
```

Returns the sum of all elements.

## Examples

    Enum.sum([1, 2, 3, 4])  # => 10
    Enum.sum([])             # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L164)

---

### product/1

```zap
fn product(collection :: Enumerable) -> i64
```

Returns the product of all elements.
Returns 1 for an empty collection.

## Examples

    Enum.product([2, 3, 4])  # => 24
    Enum.product([])         # => 1

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L178)

---

### max/1

```zap
fn max(collection :: Enumerable) -> i64
```

Returns the maximum element.
Returns 0 for an empty collection.

## Examples

    Enum.max([3, 1, 4, 1, 5])  # => 5

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L191)

---

### min/1

```zap
fn min(collection :: Enumerable) -> i64
```

Returns the minimum element.
Returns 0 for an empty collection.

## Examples

    Enum.min([3, 1, 4, 1, 5])  # => 1

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L204)

---

### sort/2

```zap
fn sort(collection :: Enumerable, comparator :: (element, element) -> Bool) -> [element]
```

Sorts the enumerable values using a comparator function.
The comparator returns true if the first argument should
come before the second.

## Examples

    Enum.sort([3, 1, 2], fn(a, b) { a < b })  # => [1, 2, 3]
    Enum.sort(1..3, fn(a, b) { a > b })       # => [3, 2, 1]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L219)

---

### flat_map/2

```zap
fn flat_map(collection :: Enumerable, callback :: (element) -> [mapped]) -> [mapped]
```

Maps each element to a list and flattens the results
into a single list.

## Examples

    Enum.flat_map([1, 2, 3], fn(x) { [x, x * 10] })
    # => [1, 10, 2, 20, 3, 30]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L233)

---

### take/2

```zap
fn take(collection :: Enumerable, count :: i64) -> [element]
```

Returns the first `count` elements from the enumerable collection.

If `count` exceeds the collection length, returns the entire
collection as a list.

## Examples

    Enum.take([1, 2, 3, 4, 5], 3)  # => [1, 2, 3]
    Enum.take(1..5, 3)             # => [1, 2, 3]
    Enum.take([1, 2, 3], 0)        # => []

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L250)

---

### drop/2

```zap
fn drop(collection :: Enumerable, count :: i64) -> [element]
```

Drops the first `count` elements from the enumerable collection
and returns the remaining elements as a list.

If `count` exceeds the collection length, returns an empty list.

## Examples

    Enum.drop([1, 2, 3, 4, 5], 2)  # => [3, 4, 5]
    Enum.drop(1..5, 2)             # => [3, 4, 5]
    Enum.drop([1, 2, 3], 0)        # => [1, 2, 3]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L267)

---

### reverse/1

```zap
fn reverse(collection :: Enumerable) -> [element]
```

Reverses the order of elements in the enumerable collection.

## Examples

    Enum.reverse([1, 2, 3])  # => [3, 2, 1]
    Enum.reverse(1..3)       # => [3, 2, 1]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L280)

---

### member?/2

```zap
fn member?(collection :: Enumerable, value :: element) -> Bool
```

Returns true if the enumerable collection contains the given value.

## Examples

    Enum.member?([1, 2, 3], 2)  # => true
    Enum.member?(1..3, 5)       # => false
    Enum.member?([], 1)         # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L294)

---

### at/3

```zap
fn at(collection :: Enumerable, index :: i64, default :: element) -> element
```

Returns the element at the given zero-based index.
Returns `default` if the index is out of bounds.

## Examples

    Enum.at([10, 20, 30], 1, 0)  # => 20
    Enum.at(["a"], 2, "none")  # => "none"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L308)

---

### concat/2

```zap
fn concat(first :: Enumerable, second :: Enumerable) -> [element]
```

Concatenates two enumerable collections into a single list.

## Examples

    Enum.concat([1, 2], [3, 4])  # => [1, 2, 3, 4]
    Enum.concat(1..2, 3..4)      # => [1, 2, 3, 4]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L321)

---

### uniq/1

```zap
fn uniq(collection :: Enumerable) -> [element]
```

Returns a new list with duplicate values removed.
Preserves the order of first occurrences.

## Examples

    Enum.uniq([1, 2, 2, 3, 1])  # => [1, 2, 3]
    Enum.uniq(1..3)             # => [1, 2, 3]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L335)

---

### empty?/1

```zap
fn empty?(collection :: Enumerable) -> Bool
```

Returns true if the enumerable collection has no elements.

## Examples

    Enum.empty?([])    # => true
    Enum.empty?(1..3)  # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L348)

---

