# List

Functions for working with lists.

Lists in Zap are singly-linked immutable cons cells using
nullable pointers. An empty list is `[]` (null), and a
non-empty list is a chain of cells each holding a head value
and a tail pointer.

## Examples

    List.length([1, 2, 3])         # => 3
    List.head([10, 20, 30])        # => 10
    List.reverse([1, 2, 3])        # => [3, 2, 1]

## Functions

### empty?/1

```zap
pub fn empty?(list :: [i64]) -> Bool
```

Returns `true` if the list has no elements.

## Examples

    List.empty?([])        # => true
    List.empty?([1, 2, 3]) # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L26)

---

### length/1

```zap
pub fn length(list :: [i64]) -> i64
```

Returns the number of elements in the list.

## Examples

    List.length([1, 2, 3])  # => 3
    List.length([])         # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L39)

---

### head/1

```zap
pub fn head(list :: [i64]) -> i64
```

Returns the first element of the list.
Returns 0 for an empty list.

## Examples

    List.head([10, 20, 30])  # => 10

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L52)

---

### tail/1

```zap
pub fn tail(list :: [i64]) -> [i64]
```

Returns the list without its first element.

## Examples

    List.tail([10, 20, 30])  # => [20, 30]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L64)

---

### at/2

```zap
pub fn at(list :: [i64], index :: i64) -> i64
```

Returns the element at the given zero-based index.
Returns 0 if the index is out of bounds.

## Examples

    List.at([10, 20, 30], 1)  # => 20

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L77)

---

### last/1

```zap
pub fn last(list :: [i64]) -> i64
```

Returns the last element of the list.
Returns 0 for an empty list.

## Examples

    List.last([1, 2, 3])  # => 3

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L90)

---

### contains?/2

```zap
pub fn contains?(list :: [i64], value :: i64) -> Bool
```

Returns `true` if the list contains the given value.

## Examples

    List.contains?([1, 2, 3], 2)  # => true
    List.contains?([1, 2, 3], 5)  # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L103)

---

### reverse/1

```zap
pub fn reverse(list :: [i64]) -> [i64]
```

Reverses the order of elements.

## Examples

    List.reverse([1, 2, 3])  # => [3, 2, 1]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L115)

---

### prepend/2

```zap
pub fn prepend(list :: [i64], value :: i64) -> [i64]
```

Prepends a value to the front of a list.

## Examples

    List.prepend([2, 3], 1)  # => [1, 2, 3]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L127)

---

### append/2

```zap
pub fn append(list :: [i64], value :: i64) -> [i64]
```

Appends a value to the end of a list. O(n).

## Examples

    List.append([1, 2], 3)  # => [1, 2, 3]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L139)

---

### concat/2

```zap
pub fn concat(first :: [i64], second :: [i64]) -> [i64]
```

Concatenates two lists.

## Examples

    List.concat([1, 2], [3, 4])  # => [1, 2, 3, 4]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L151)

---

### take/2

```zap
pub fn take(list :: [i64], count :: i64) -> [i64]
```

Takes the first `count` elements.

## Examples

    List.take([1, 2, 3, 4, 5], 3)  # => [1, 2, 3]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L163)

---

### drop/2

```zap
pub fn drop(list :: [i64], count :: i64) -> [i64]
```

Drops the first `count` elements.

## Examples

    List.drop([1, 2, 3, 4, 5], 2)  # => [3, 4, 5]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L175)

---

### uniq/1

```zap
pub fn uniq(list :: [i64]) -> [i64]
```

Returns a new list with duplicates removed.
Preserves the order of first occurrences.

## Examples

    List.uniq([1, 2, 2, 3, 1])  # => [1, 2, 3]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L188)

---

