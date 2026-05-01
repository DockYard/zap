# Enum

## Functions

### map/2

```zap
pub fn map(list :: [element], callback :: (element) -> result) -> [result]
```

Transforms each element by applying the callback function.

## Examples

    Enum.map([1, 2, 3], fn(x) { x * 2 })  # => [2, 4, 6]
    Enum.map([], fn(x) { x + 1 })          # => []

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L26)

---

### filter/2

```zap
pub fn filter(list :: [element], predicate :: (element) -> Bool) -> [element]
```

Keeps only elements for which the predicate returns true.

## Examples

    Enum.filter([1, 2, 3, 4], fn(x) { x > 2 })  # => [3, 4]
    Enum.filter([1, 2, 3], fn(x) { x > 10 })     # => []

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L39)

---

### reject/2

```zap
pub fn reject(list :: [element], predicate :: (element) -> Bool) -> [element]
```

Removes elements for which the predicate returns true.
The opposite of `filter/2`.

## Examples

    Enum.reject([1, 2, 3, 4], fn(x) { x > 2 })  # => [1, 2]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L52)

---

### reduce/3

```zap
pub fn reduce(list :: [element], initial :: element, callback :: (element, element) -> element) -> element
```

Folds the collection into a single value using an accumulator.
The callback receives `(accumulator, element)` and returns
the new accumulator.

Dispatches through the Enumerable protocol — works with any
collection type that implements Enumerable.

## Examples

    Enum.reduce([1, 2, 3], 0, fn(acc, x) { acc + x })  # => 6
    Enum.reduce([2, 3, 4], 1, fn(acc, x) { acc * x })   # => 24

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L70)

---

### reduce_map/3

```zap
pub fn reduce_map(map :: ?, initial :: i64, callback :: (i64, i64) -> i64) -> i64
```

Folds map values into a single value using an accumulator.
The callback receives `(accumulator, value)` and returns
the new accumulator.

## Examples

    Enum.reduce_map(%{a: 1, b: 2, c: 3}, 0, fn(acc, val) { acc + val })
    # => 6

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L85)

---

### each/2

```zap
pub fn each(list :: [element], callback :: (element) -> element) -> [element]
```

Applies the callback to each element for side effects.
Returns the original list unchanged.

## Examples

    Enum.each([1, 2, 3], fn(x) { IO.puts(Integer.to_string(x)) })

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L98)

---

### find/3

```zap
pub fn find(list :: [element], default :: element, predicate :: (element) -> Bool) -> element
```

Returns the first element for which the predicate returns true.
Returns the default value if no element matches.

## Examples

    Enum.find([1, 2, 3, 4], 0, fn(x) { x > 2 })  # => 3
    Enum.find([1, 2], 0, fn(x) { x > 10 })        # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L112)

---

### any?/2

```zap
pub fn any?(list :: [element], predicate :: (element) -> Bool) -> Bool
```

Returns true if the predicate returns true for any element.

## Examples

    Enum.any?([1, 2, 3], fn(x) { x > 2 })   # => true
    Enum.any?([1, 2, 3], fn(x) { x > 10 })  # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L125)

---

### all?/2

```zap
pub fn all?(list :: [element], predicate :: (element) -> Bool) -> Bool
```

Returns true if the predicate returns true for all elements.

## Examples

    Enum.all?([2, 4, 6], fn(x) { x > 0 })   # => true
    Enum.all?([2, 4, 6], fn(x) { x > 3 })   # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L138)

---

### count/2

```zap
pub fn count(list :: [element], predicate :: (element) -> Bool) -> i64
```

Counts elements for which the predicate returns true.

## Examples

    Enum.count([1, 2, 3, 4, 5], fn(x) { x > 2 })  # => 3

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L150)

---

### sum/1

```zap
pub fn sum(list :: [i64]) -> i64
```

Returns the sum of all elements.

## Examples

    Enum.sum([1, 2, 3, 4])  # => 10
    Enum.sum([])             # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L163)

---

### product/1

```zap
pub fn product(list :: [i64]) -> i64
```

Returns the product of all elements.
Returns 1 for an empty list.

## Examples

    Enum.product([2, 3, 4])  # => 24
    Enum.product([])         # => 1

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L177)

---

### max/1

```zap
pub fn max(list :: [i64]) -> i64
```

Returns the maximum element.
Returns 0 for an empty list.

## Examples

    Enum.max([3, 1, 4, 1, 5])  # => 5

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L190)

---

### min/1

```zap
pub fn min(list :: [i64]) -> i64
```

Returns the minimum element.
Returns 0 for an empty list.

## Examples

    Enum.min([3, 1, 4, 1, 5])  # => 1

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L203)

---

### sort/2

```zap
pub fn sort(list :: [element], comparator :: (element, element) -> Bool) -> [element]
```

Sorts the list using a comparator function.
The comparator returns true if the first argument should
come before the second.

## Examples

    Enum.sort([3, 1, 2], fn(a, b) { a < b })  # => [1, 2, 3]
    Enum.sort([3, 1, 2], fn(a, b) { a > b })  # => [3, 2, 1]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L218)

---

### flat_map/2

```zap
pub fn flat_map(list :: [element], callback :: (element) -> [element]) -> [element]
```

Maps each element to a list and flattens the results
into a single list.

## Examples

    Enum.flat_map([1, 2, 3], fn(x) { [x, x * 10] })
    # => [1, 10, 2, 20, 3, 30]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L232)

---

### take/2

```zap
pub fn take(list :: [element], count :: i64) -> [element]
```

Returns the first `count` elements from the list.

If `count` exceeds the list length, returns the entire list.

## Examples

    Enum.take([1, 2, 3, 4, 5], 3)  # => [1, 2, 3]
    Enum.take([1, 2], 5)            # => [1, 2]
    Enum.take([1, 2, 3], 0)         # => []

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L248)

---

### drop/2

```zap
pub fn drop(list :: [element], count :: i64) -> [element]
```

Drops the first `count` elements from the list.

If `count` exceeds the list length, returns an empty list.

## Examples

    Enum.drop([1, 2, 3, 4, 5], 2)  # => [3, 4, 5]
    Enum.drop([1, 2], 5)            # => []
    Enum.drop([1, 2, 3], 0)         # => [1, 2, 3]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L264)

---

### reverse/1

```zap
pub fn reverse(list :: [element]) -> [element]
```

Reverses the order of elements in the list.

## Examples

    Enum.reverse([1, 2, 3])  # => [3, 2, 1]
    Enum.reverse([])          # => []

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L277)

---

### member?/2

```zap
pub fn member?(list :: [element], value :: element) -> Bool
```

Returns true if the list contains the given value.

## Examples

    Enum.member?([1, 2, 3], 2)  # => true
    Enum.member?([1, 2, 3], 5)  # => false
    Enum.member?([], 1)          # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L291)

---

### at/2

```zap
pub fn at(list :: [element], index :: i64) -> element
```

Returns the element at the given zero-based index.
Returns 0 if the index is out of bounds.

## Examples

    Enum.at([10, 20, 30], 1)  # => 20
    Enum.at([10, 20, 30], 0)  # => 10

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L305)

---

### concat/2

```zap
pub fn concat(first :: [element], second :: [element]) -> [element]
```

Concatenates two lists into a single list.

## Examples

    Enum.concat([1, 2], [3, 4])  # => [1, 2, 3, 4]
    Enum.concat([], [1, 2])       # => [1, 2]
    Enum.concat([1, 2], [])       # => [1, 2]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L319)

---

### uniq/1

```zap
pub fn uniq(list :: [element]) -> [element]
```

Returns a new list with duplicate values removed.
Preserves the order of first occurrences.

## Examples

    Enum.uniq([1, 2, 2, 3, 1])  # => [1, 2, 3]
    Enum.uniq([1, 1, 1])         # => [1]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L333)

---

### empty?/1

```zap
pub fn empty?(list :: [element]) -> Bool
```

Returns true if the list has no elements.

## Examples

    Enum.empty?([])        # => true
    Enum.empty?([1, 2, 3]) # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/enum.zap#L346)

---

