# Map

Functions for working with maps.

Maps in Zap are immutable key-value collections. Keys are
atoms (interned identifiers), values are integers. Maps use
a flat array representation optimized for small collections.

## Examples

    m = %{name: "Alice", age: 30}
    Map.get(m, :name, 0)     # => atom ID for "Alice"
    Map.has_key?(m, :name)   # => true
    Map.size(m)              # => 2

## Functions

### get/3

```zap
pub fn get(map :: ?, key :: Atom, default :: i64) -> i64
```

Returns the value for the given key, or the default if
the key is not found.

## Examples

    Map.get(%{a: 1, b: 2}, :a, 0)  # => 1
    Map.get(%{a: 1}, :z, 99)        # => 99

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L27)

---

### has_key?/2

```zap
pub fn has_key?(map :: ?, key :: Atom) -> Bool
```

Returns `true` if the map contains the given key.

## Examples

    Map.has_key?(%{a: 1, b: 2}, :a)  # => true
    Map.has_key?(%{a: 1}, :z)         # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L40)

---

### size/1

```zap
pub fn size(map :: ?) -> i64
```

Returns the number of entries in the map.

## Examples

    Map.size(%{a: 1, b: 2, c: 3})  # => 3
    Map.size(%{})                    # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L53)

---

### empty?/1

```zap
pub fn empty?(map :: ?) -> Bool
```

Returns `true` if the map has no entries.

## Examples

    Map.empty?(%{})       # => true
    Map.empty?(%{a: 1})  # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L66)

---

### put/3

```zap
pub fn put(map :: ?, key :: Atom, value :: i64) -> ?
```

Returns a new map with the key set to the given value.
If the key already exists, its value is updated.

## Examples

    Map.put(%{a: 1}, :b, 2)  # => %{a: 1, b: 2}
    Map.put(%{a: 1}, :a, 9)  # => %{a: 9}

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L80)

---

### delete/2

```zap
pub fn delete(map :: ?, key :: Atom) -> ?
```

Returns a new map with the given key removed.
Returns the map unchanged if the key doesn't exist.

## Examples

    Map.delete(%{a: 1, b: 2}, :a)  # => %{b: 2}
    Map.delete(%{a: 1}, :z)         # => %{a: 1}

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L94)

---

### merge/2

```zap
pub fn merge(map_a :: ?, map_b :: ?) -> ?
```

Merges two maps. Keys from the second map override keys
from the first.

## Examples

    Map.merge(%{a: 1, b: 2}, %{b: 9, c: 3})
    # => %{a: 1, b: 9, c: 3}

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L108)

---

### keys/1

```zap
pub fn keys(map :: ?) -> [i64]
```

Returns a list of all keys in the map.

## Examples

    Map.keys(%{a: 1, b: 2})  # => [:a, :b]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L120)

---

### values/1

```zap
pub fn values(map :: ?) -> [i64]
```

Returns a list of all values in the map.

## Examples

    Map.values(%{a: 1, b: 2})  # => [1, 2]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L132)

---

