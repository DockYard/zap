# Map

**Implements:** `Concatenable`, `Enumerable`, `Membership`, `Updatable`

Functions for working with maps.

Maps in Zap are immutable key-value collections that support
any key and value types. The compiler specializes map operations
at compile time based on the concrete types used.

## Examples

    m = %{name: "Alice", age: 30}
    Map.get(m, :name, "")    # => "Alice"
    Map.has_key?(m, :name)   # => true
    Map.size(m)              # => 2

## Functions

### get/3

```zap
fn get(map :: ?, lookup_key :: key, default :: value) -> value
```

Returns the value for the given key, or the default if
the key is not found.

## Examples

    Map.get(%{a: 1, b: 2}, :a, 0)  # => 1
    Map.get(%{a: 1}, :z, 99)        # => 99

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L29)

---

### has_key?/2

```zap
fn has_key?(map :: ?, lookup_key :: key) -> Bool
```

Returns `true` if the map contains the given key.

## Examples

    Map.has_key?(%{a: 1, b: 2}, :a)  # => true
    Map.has_key?(%{a: 1}, :z)         # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L42)

---

### has_key/2

```zap
fn has_key(map :: ?, lookup_key :: key) -> Bool
```

Returns `true` if the map contains the given key.
Convenience alias for `has_key?` exposed without the predicate
suffix so call sites that prefer the explicit identifier form
still resolve.

## Examples

    Map.has_key(%{a: 1, b: 2}, :a)  # => true
    Map.has_key(%{a: 1}, :z)         # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L58)

---

### size/1

```zap
fn size(map :: ?) -> i64
```

Returns the number of entries in the map.

## Examples

    Map.size(%{a: 1, b: 2, c: 3})  # => 3
    Map.size(%{})                    # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L71)

---

### empty?/1

```zap
fn empty?(map :: ?) -> Bool
```

Returns `true` if the map has no entries.

## Examples

    Map.empty?(%{})       # => true
    Map.empty?(%{a: 1})  # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L84)

---

### put/3

```zap
fn put(map :: ?, new_key :: key, new_value :: value) -> ?
```

Returns a new map with the key set to the given value.
If the key already exists, its value is updated.

## Examples

    Map.put(%{a: 1}, :b, 2)  # => %{a: 1, b: 2}
    Map.put(%{a: 1}, :a, 9)  # => %{a: 9}

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L98)

---

### delete/2

```zap
fn delete(map :: ?, remove_key :: key) -> ?
```

Returns a new map with the given key removed.
Returns the map unchanged if the key doesn't exist.

## Examples

    Map.delete(%{a: 1, b: 2}, :a)  # => %{b: 2}
    Map.delete(%{a: 1}, :z)         # => %{a: 1}

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L112)

---

### merge/2

```zap
fn merge(map_a :: ?, map_b :: ?) -> ?
```

Merges two maps. Keys from the second map override keys
from the first.

## Examples

    Map.merge(%{a: 1, b: 2}, %{b: 9, c: 3})
    # => %{a: 1, b: 9, c: 3}

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L126)

---

### keys/1

```zap
fn keys(map :: ?) -> [key]
```

Returns a list of all keys in the map.

## Examples

    Map.keys(%{a: 1, b: 2})  # => [:a, :b]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L138)

---

### values/1

```zap
fn values(map :: ?) -> [value]
```

Returns a list of all values in the map.

## Examples

    Map.values(%{a: 1, b: 2})  # => [1, 2]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L150)

---

### get!/3

```zap
fn get!(map :: ?, lookup_key :: key, default :: value) -> value
```

Returns the value for the given key.
Raises if the key is not found.

## Examples

    Map.get!(%{a: 1, b: 2}, :a)  # => 1
    Map.get!(%{a: 1}, :z)        # raises

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/map.zap#L164)

---

