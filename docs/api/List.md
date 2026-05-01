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
pub fn empty?(list :: [element]) -> Bool
```

Returns `true` if the list has no elements.

## Examples

    List.empty?([])        # => true
    List.empty?([1, 2, 3]) # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L28)

---

### length/1

```zap
pub fn length(list :: [element]) -> i64
```

Returns the number of elements in the list.

## Examples

    List.length([1, 2, 3])  # => 3
    List.length([])         # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L41)

---

### head/1

```zap
pub fn head(list :: [element]) -> element
```

Returns the first element of the list.
Returns 0 for an empty list.

## Examples

    List.head([10, 20, 30])  # => 10

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L54)

---

### tail/1

```zap
pub fn tail(list :: [element]) -> [element]
```

Returns the list without its first element.

## Examples

    List.tail([10, 20, 30])  # => [20, 30]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L66)

---

### at/2

```zap
pub fn at(list :: [element], index :: i64) -> element
```

Returns the element at the given zero-based index.
Returns 0 if the index is out of bounds.

## Examples

    List.at([10, 20, 30], 1)  # => 20

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L79)

---

### last/1

```zap
pub fn last(list :: [element]) -> element
```

Returns the last element of the list.
Returns 0 for an empty list.

## Examples

    List.last([1, 2, 3])  # => 3

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L92)

---

### contains?/2

```zap
pub fn contains?(list :: [element], value :: element) -> Bool
```

Returns `true` if the list contains the given value.

## Examples

    List.contains?([1, 2, 3], 2)  # => true
    List.contains?([1, 2, 3], 5)  # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L105)

---

### reverse/1

```zap
pub fn reverse(list :: [element]) -> [element]
```

Reverses the order of elements.

## Examples

    List.reverse([1, 2, 3])  # => [3, 2, 1]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L117)

---

### prepend/2

```zap
pub fn prepend(list :: [element], value :: element) -> [element]
```

Prepends a value to the front of a list.

## Examples

    List.prepend([2, 3], 1)  # => [1, 2, 3]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L129)

---

### append/2

```zap
pub fn append(list :: [element], value :: element) -> [element]
```

Appends a value to the end of a list. O(n).

## Examples

    List.append([1, 2], 3)  # => [1, 2, 3]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L141)

---

### concat/2

```zap
pub fn concat(first :: [element], second :: [element]) -> [element]
```

Concatenates two lists.

## Examples

    List.concat([1, 2], [3, 4])  # => [1, 2, 3, 4]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L153)

---

### take/2

```zap
pub fn take(list :: [element], count :: i64) -> [element]
```

Takes the first `count` elements.

## Examples

    List.take([1, 2, 3, 4, 5], 3)  # => [1, 2, 3]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L165)

---

### drop/2

```zap
pub fn drop(list :: [element], count :: i64) -> [element]
```

Drops the first `count` elements.

## Examples

    List.drop([1, 2, 3, 4, 5], 2)  # => [3, 4, 5]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L177)

---

### uniq/1

```zap
pub fn uniq(list :: [element]) -> [element]
```

Returns a new list with duplicates removed.
Preserves the order of first occurrences.

## Examples

    List.uniq([1, 2, 2, 3, 1])  # => [1, 2, 3]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L190)

---

### head!/1

```zap
pub fn head!(list :: [element]) -> element
```

Returns the first element of the list.
Raises if the list is empty.

## Examples

    List.head!([10, 20])  # => 10
    List.head!([])        # raises

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L204)

---

### last!/1

```zap
pub fn last!(list :: [element]) -> element
```

Returns the last element of the list.
Raises if the list is empty.

## Examples

    List.last!([1, 2, 3])  # => 3
    List.last!([])         # raises

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L223)

---

### at!/2

```zap
pub fn at!(list :: [element], index :: i64) -> element
```

Returns the element at the given zero-based index.
Raises if the index is out of bounds.

## Examples

    List.at!([10, 20, 30], 1)  # => 20
    List.at!([10, 20], 5)      # raises

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/list.zap#L242)

---

