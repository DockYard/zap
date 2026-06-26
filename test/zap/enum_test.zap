pub struct Zap.EnumTest {
  use Zest.Case

  describe("Enum struct") {
    test("map doubles values") {
      result = Enum.map([1, 2, 3], double)
      assert(List.head(result) == 2)
      assert(List.last(result) == 6)
      assert(List.length(result) == 3)
    }

    test("map empty list") {
      assert(List.empty?(Enum.map([], double)))
    }

    test("filter keeps matching") {
      result = Enum.filter([1, 2, 3, 4, 5], greater_than_three)
      assert(List.length(result) == 2)
      assert(List.head(result) == 4)
    }

    test("filter none match") {
      assert(List.empty?(Enum.filter([1, 2, 3], greater_than_ten)))
    }

    test("reject removes matching") {
      result = Enum.reject([1, 2, 3, 4, 5], greater_than_three)
      assert(List.length(result) == 3)
      assert(List.last(result) == 3)
    }

    test("reduce sum") {
      assert(Enum.reduce([1, 2, 3, 4], 0, add) == 10)
    }

    test("reduce product") {
      assert(Enum.reduce([2, 3, 4], 1, mul) == 24)
    }

    test("reduce empty") {
      assert(Enum.reduce([], 42, add) == 42)
    }

    test("reduce strings via concat") {
      assert(Enum.reduce(["a", "b", "c"], "", concat_str) == "abc")
    }

    test("sort strings by length") {
      result = Enum.sort(["ccc", "a", "bb"], str_less_than)
      assert(List.head(result) == "a")
      assert(List.last(result) == "ccc")
    }

    test("flat_map strings") {
      result = Enum.flat_map(["hi", "yo"], double_str)
      assert(List.length(result) == 4)
      assert(List.head(result) == "hi")
    }

    test("find first match") {
      assert(Enum.find([1, 2, 3, 4], 0, greater_than_two) == 3)
    }

    test("find list exits early leak-free") {
      assert_no_leaks {
        assert(Enum.find([1, 2, 3, 4], 0, greater_than_one) == 2)
      }
    }

    test("find no match returns default") {
      assert(Enum.find([1, 2], 99, greater_than_ten) == 99)
    }

    test("any? with match") {
      assert(Enum.any?([1, 2, 3], greater_than_two))
    }

    test("any? list exits early leak-free") {
      assert_no_leaks {
        assert(Enum.any?([1, 2, 3], greater_than_one))
      }
    }

    test("any? without match") {
      reject(Enum.any?([1, 2, 3], greater_than_ten))
    }

    test("all? true") {
      assert(Enum.all?([2, 4, 6], is_positive))
    }

    test("all? false") {
      reject(Enum.all?([2, 4, 6], greater_than_three))
    }

    test("all? list exits early leak-free") {
      assert_no_leaks {
        reject(Enum.all?([1, 2, 3], greater_than_one))
      }
    }

    test("count matching") {
      assert(Enum.count([1, 2, 3, 4, 5], greater_than_two) == 3)
    }

    test("count none") {
      assert(Enum.count([1, 2, 3], greater_than_ten) == 0)
    }

    test("sum") {
      assert(Enum.sum([1, 2, 3, 4]) == 10)
    }

    test("sum empty") {
      assert(Enum.sum([]) == 0)
    }

    test("product") {
      assert(Enum.product([2, 3, 4]) == 24)
    }

    test("product empty") {
      assert(Enum.product([]) == 1)
    }

    test("max") {
      assert(Enum.max([3, 1, 4, 1, 5]) == 5)
    }

    test("min") {
      assert(Enum.min([3, 1, 4, 1, 5]) == 1)
    }

    test("first list") {
      assert(Enum.first([10, 20, 30]) == 10)
    }

    test("first list abandons iterator state leak-free") {
      assert_no_leaks {
        assert(Enum.first([10, 20, 30]) == 10)
      }
    }

    test("first range") {
      assert(Enum.first(5..15) == 5)
    }

    test("first with default falls through on empty list") {
      assert(Enum.first([] :: [i64], -1) == -1)
    }

    test("first with default returns first element when present") {
      assert(Enum.first([42, 99], -1) == 42)
    }

    test("last list") {
      assert(Enum.last([10, 20, 30]) == 30)
    }

    test("last range step 1") {
      assert(Enum.last(5..15) == 15)
    }

    test("last range step doesn't divide evenly") {
      assert(Enum.last(1..10:3) == 10)
      assert(Enum.last(1..10:2) == 9)
    }

    test("last descending range") {
      assert(Enum.last(10..1) == 1)
    }

    test("last with default falls through on empty list") {
      assert(Enum.last([] :: [i64], -1) == -1)
    }

    test("count list") {
      assert(Enum.count([10, 20, 30]) == 3)
    }

    test("count larger list through Enumerable") {
      assert(Enum.count([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32]) == 32)
    }

    test("shared list iterator state advances independently") {
      assert(shared_list_iterator_state_advances_independently())
    }

    test("list iterator state satisfies List API") {
      assert_no_leaks {
        assert(list_iterator_state_satisfies_list_api())
      }
    }

    test("count range step 1") {
      assert(Enum.count(1..10) == 10)
    }

    test("count range step doesn't divide evenly") {
      assert(Enum.count(1..10:3) == 4)
      assert(Enum.count(1..10:2) == 5)
    }

    test("count descending range") {
      assert(Enum.count(10..1) == 10)
    }

    test("count empty list") {
      assert(Enum.count([] :: [i64]) == 0)
    }

    test("sum range step 1 matches walk") {
      assert(Enum.sum(1..10) == 55)
    }

    test("sum range with step") {
      assert(Enum.sum(1..10:3) == 22)
      assert(Enum.sum(1..10:2) == 25)
    }

    test("sum descending range") {
      assert(Enum.sum(10..1) == 55)
    }

    test("sort ascending") {
      result = Enum.sort([3, 1, 4, 1, 5], less_than)
      assert(List.head(result) == 1)
      assert(List.last(result) == 5)
    }

    test("sort descending") {
      result = Enum.sort([3, 1, 4, 1, 5], greater_than)
      assert(List.head(result) == 5)
      assert(List.last(result) == 1)
    }

    test("sort handles larger unsorted input with duplicates") {
      result = Enum.sort([9, 1, 8, 2, 7, 3, 6, 4, 5, 0, 9, 2], less_than)
      assert(List.length(result) == 12)
      assert(List.head(result) == 0)
      assert(List.at(result, 1) == 1)
      assert(List.at(result, 2) == 2)
      assert(List.at(result, 3) == 2)
      assert(List.last(result) == 9)
    }

    test("each walks larger ranges and returns Nil") {
      assert_no_leaks {
        assert(enum_each_i64_callback_returns_nil())
        assert(enum_each_nil_callback_returns_nil())
      }
    }

    test("map with anonymous function") {
      result = Enum.map([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })
      assert(List.head(result) == 2)
      assert(List.last(result) == 6)
    }

    test("map works with ranges through Enumerable") {
      result = Enum.map(1..3, fn(x :: i64) -> i64 { x * 2 })
      assert(List.length(result) == 3)
      assert(List.head(result) == 2)
      assert(List.last(result) == 6)
    }

    test("map works with strings through Enumerable") {
      result = Enum.map("ab", fn(char :: String) -> String { char <> "!" })
      assert(List.length(result) == 2)
      assert(List.head(result) == "a!")
      assert(List.last(result) == "b!")
    }

    test("filter with anonymous function") {
      result = Enum.filter([1, 2, 3, 4, 5], fn(x :: i64) -> Bool { x > 3 })
      assert(List.length(result) == 2)
    }

    test("filter works with ranges through Enumerable") {
      result = Enum.filter(1..5, fn(x :: i64) -> Bool { x > 3 })
      assert(List.length(result) == 2)
      assert(List.head(result) == 4)
      assert(List.last(result) == 5)
    }

    test("reduce with anonymous function") {
      assert(Enum.reduce([1, 2, 3, 4], 0, fn(acc :: i64, x :: i64) -> i64 { acc + x }) == 10)
    }

    test("reduce works with ranges through Enumerable") {
      assert(Enum.reduce(1..4, 0, fn(acc :: i64, x :: i64) -> i64 { acc + x }) == 10)
    }

    test("reduce works with maps through Enumerable") {
      result = Enum.reduce(%{a: 10, b: 20, c: 30}, 0, fn(acc :: i64, entry :: {Atom, i64}) -> i64 {
        case entry {
          {_key, value} -> acc + value
        }
      })

      assert(result == 60)
    }

    test("count map through Enumerable") {
      assert(Enum.count(%{a: 1, b: 2, c: 3}) == 3)
    }

    test("first map abandons iterator state") {
      entry = Enum.first(%{a: 10, b: 20})

      case entry {
        {key, value} -> assert((key == :a and value == 10) or (key == :b and value == 20))
      }
    }

    test("first map abandons iterator state leak-free") {
      assert_no_leaks {
        entry = Enum.first(%{a: 10, b: 20})

        case entry {
          {key, value} -> assert((key == :a and value == 10) or (key == :b and value == 20))
        }
      }
    }

    test("find map exits early leak-free") {
      assert_no_leaks {
        entry = Enum.find(%{a: 10, b: 20}, {:none, 0}, fn(entry :: {Atom, i64}) -> Bool {
          case entry {
            {_key, value} -> value > 0
          }
        })

        case entry {
          {key, value} -> assert((key == :a and value == 10) or (key == :b and value == 20))
        }
      }
    }

    test("shared map iterator state advances independently") {
      assert(shared_map_iterator_state_advances_independently())
    }

    test("map iterator state satisfies Map API") {
      assert_no_leaks {
        assert(map_iterator_state_satisfies_map_api())
      }
    }

    test("sort with anonymous comparator") {
      result = Enum.sort([3, 1, 2], fn(a :: i64, b :: i64) -> Bool { a < b })
      assert(List.head(result) == 1)
      assert(List.last(result) == 3)
    }

    test("take first three") {
      result = Enum.take([1, 2, 3, 4, 5], 3)
      assert(List.length(result) == 3)
      assert(List.head(result) == 1)
      assert(List.last(result) == 3)
    }

    test("take list exits early leak-free") {
      assert_no_leaks {
        result = Enum.take([1, 2, 3, 4, 5], 2)
        assert(List.length(result) == 2)
      }
    }

    test("take works with ranges through Enumerable") {
      result = Enum.take(1..5, 3)
      assert(List.length(result) == 3)
      assert(List.head(result) == 1)
      assert(List.last(result) == 3)
    }

    test("take more than available") {
      result = Enum.take([1, 2], 5)
      assert(List.length(result) == 2)
    }

    test("take zero") {
      assert(List.empty?(Enum.take([1, 2, 3], 0)))
    }

    test("drop two") {
      result = Enum.drop([1, 2, 3, 4, 5], 2)
      assert(List.length(result) == 3)
      assert(List.head(result) == 3)
    }

    test("drop more than available") {
      assert(List.empty?(Enum.drop([1, 2], 5)))
    }

    test("drop zero") {
      assert(List.length(Enum.drop([1, 2, 3], 0)) == 3)
    }

    test("reverse") {
      result = Enum.reverse([1, 2, 3])
      assert(List.head(result) == 3)
      assert(List.last(result) == 1)
      assert(List.length(result) == 3)
    }

    test("reverse empty") {
      assert(List.empty?(Enum.reverse([])))
    }

    test("member? found") {
      assert(Enum.member?([1, 2, 3], 2))
    }

    test("member? list exits early leak-free") {
      assert_no_leaks {
        assert(Enum.member?([1, 2, 3], 2))
      }
    }

    test("member? not found") {
      reject(Enum.member?([1, 2, 3], 5))
    }

    test("member? empty") {
      reject(Enum.member?([], 1))
    }

    test("at index") {
      assert(Enum.at([10, 20, 30], 1, 0) == 20)
    }

    test("at first") {
      assert(Enum.at([10, 20, 30], 0, 0) == 10)
    }

    test("at list exits early leak-free") {
      assert_no_leaks {
        assert(Enum.at([10, 20, 30], 0, 0) == 10)
      }
    }

    test("at last") {
      assert(Enum.at([10, 20, 30], 2, 0) == 30)
    }

    test("at returns typed default") {
      assert(Enum.at(["a"], 2, "none") == "none")
    }

    test("concat two lists") {
      result = Enum.concat([1, 2], [3, 4])
      assert(List.length(result) == 4)
      assert(List.head(result) == 1)
      assert(List.last(result) == 4)
    }

    test("concat with empty first") {
      result = Enum.concat([], [1, 2])
      assert(List.length(result) == 2)
      assert(List.head(result) == 1)
    }

    test("concat with empty second") {
      result = Enum.concat([1, 2], [])
      assert(List.length(result) == 2)
      assert(List.last(result) == 2)
    }

    test("uniq removes duplicates") {
      result = Enum.uniq([1, 2, 2, 3, 1])
      assert(List.length(result) == 3)
      assert(List.head(result) == 1)
    }

    test("uniq all same") {
      assert(List.length(Enum.uniq([1, 1, 1])) == 1)
    }

    test("uniq no duplicates") {
      assert(List.length(Enum.uniq([1, 2, 3])) == 3)
    }

    test("empty? on empty") {
      assert(Enum.empty?([]))
    }

    test("empty? on non-empty") {
      reject(Enum.empty?([1, 2, 3]))
    }

    test("empty? works with ranges through Enumerable") {
      reject(Enum.empty?(5..1))
      reject(Enum.empty?(1..3))
    }
  }

  fn shared_list_iterator_state_advances_independently() -> Bool {
    case Enumerable.next([10, 20, 30]) {
      {:cont, _, state} -> shared_list_iterator_state_values_match(state)
      {:done, _, _} -> false
    }
  }

  fn shared_list_iterator_state_values_match(state :: unique Enumerable(i64)) -> Bool {
    state_alias = state
    first_value = next_list_iterator_value(state)
    alias_value = next_list_iterator_value(state_alias)

    first_value == 20 and alias_value == 20
  }

  fn next_list_iterator_value(state :: unique Enumerable(i64)) -> i64 {
    case Enumerable.next(state) {
      {:cont, value, next_state} -> dispose_enumerable_and_return(next_state, value)
      {:done, _, _} -> -1
    }
  }

  fn list_iterator_state_satisfies_list_api() -> Bool {
    case Enumerable.next([10, 20, 30, 40]) {
      {:cont, 10, state} -> list_iterator_state_satisfies_list_api_state(state)
      {:cont, _, _} -> false
      {:done, _, _} -> false
    }
  }

  fn list_iterator_state_satisfies_list_api_state(state :: List(i64)) -> Bool {
    tail = List.tail(state)
    pushed = List.push(state, 50)
    replaced = List.set(state, 1, 99)

    state_ok = List.length(state) == 3 and List.head(state) == 20 and List.get(state, 1) == 30 and List.last(state) == 40
    tail_ok = List.length(tail) == 2 and List.head(tail) == 30 and List.last(tail) == 40
    pushed_ok = List.length(pushed) == 4 and List.last(pushed) == 50
    replaced_ok = List.length(replaced) == 3 and List.get(replaced, 1) == 99 and List.get(state, 1) == 30

    state_ok and tail_ok and pushed_ok and replaced_ok
  }

  fn shared_map_iterator_state_advances_independently() -> Bool {
    case Enumerable.next(%{a: 10, b: 20, c: 30}) {
      {:cont, _, state} -> shared_map_iterator_state_entries_match(state)
      {:done, _, _} -> false
    }
  }

  fn shared_map_iterator_state_entries_match(state :: unique Enumerable({Atom, i64})) -> Bool {
    state_alias = state
    first_entry = next_map_iterator_entry(state)
    alias_entry = next_map_iterator_entry(state_alias)

    case first_entry {
      {first_key, first_value} -> case alias_entry {
        {alias_key, alias_value} -> first_key == alias_key and first_value == alias_value and (first_value == 20 or first_value == 30)
      }
    }
  }

  fn next_map_iterator_entry(state :: unique Enumerable({Atom, i64})) -> {Atom, i64} {
    case Enumerable.next(state) {
      {:cont, entry, next_state} -> dispose_enumerable_and_return(next_state, entry)
      {:done, _, _} -> {:nil, 0}
    }
  }

  fn dispose_enumerable_and_return(state :: unique Enumerable(element), value :: result) -> result {
    Enumerable.dispose(state)
    value
  }

  fn map_iterator_state_satisfies_map_api() -> Bool {
    case Enumerable.next(%{a: 10, b: 20, c: 30}) {
      {:cont, first_entry, state} -> map_iterator_state_satisfies_map_api_state(first_entry, state)
      {:done, _, _} -> false
    }
  }

  fn map_iterator_state_satisfies_map_api_state(first_entry :: {Atom, i64}, state :: %{Atom -> i64}) -> Bool {
    inserted = Map.put(state, :z, 99)
    merged = Map.merge(state, %{z: 99})

    case first_entry {
      {first_key, _} ->
        map_iterator_state_satisfies_map_api_result(first_key, state, inserted, merged)
    }
  }

  fn map_iterator_state_satisfies_map_api_result(first_key :: Atom, state :: %{Atom -> i64}, inserted :: %{Atom -> i64}, merged :: %{Atom -> i64}) -> Bool {
    state_ok = Map.size(state) == 2 and map_iterator_remaining_keys_match(first_key, state)
    lists_ok = List.length(Map.keys(state)) == 2 and List.length(Map.values(state)) == 2
    inserted_ok = Map.size(inserted) == 3 and Map.has_key?(inserted, :z) and reject_key_from_state(:z, state)
    merged_ok = Map.size(merged) == 3 and Map.has_key?(merged, :z)

    state_ok and lists_ok and inserted_ok and merged_ok
  }

  fn map_iterator_remaining_keys_match(first_key :: Atom, state :: %{Atom -> i64}) -> Bool {
    case first_key {
      :a -> reject_key_from_state(:a, state) and Map.get(state, :b, 0) == 20 and Map.get(state, :c, 0) == 30
      :b -> Map.get(state, :a, 0) == 10 and reject_key_from_state(:b, state) and Map.get(state, :c, 0) == 30
      :c -> Map.get(state, :a, 0) == 10 and Map.get(state, :b, 0) == 20 and reject_key_from_state(:c, state)
      _ -> false
    }
  }

  fn reject_key_from_state(key :: Atom, state :: %{Atom -> i64}) -> Bool {
    not Map.has_key?(state, key)
  }

  fn enum_each_i64_callback_returns_nil() -> Bool {
    enum_each_result_is_nil(Enum.each(1..128, fn(value :: i64) -> i64 { value + 1 }))
  }

  fn enum_each_nil_callback_returns_nil() -> Bool {
    enum_each_result_is_nil(Enum.each(1..128, assert_enum_each_value_in_range))
  }

  fn enum_each_result_is_nil(_ignored_enum_each_result :: Nil) -> Bool {
    true
  }

  fn assert_enum_each_value_in_range(value :: i64) -> Nil {
    assert(value >= 1)
    assert(value <= 128)
    nil
  }

  fn double(x :: i64) -> i64 {
    x * 2
  }

  fn add(acc :: i64, x :: i64) -> i64 {
    acc + x
  }

  fn mul(acc :: i64, x :: i64) -> i64 {
    acc * x
  }

  fn greater_than_two(x :: i64) -> Bool {
    x > 2
  }

  fn greater_than_one(x :: i64) -> Bool {
    x > 1
  }

  fn greater_than_three(x :: i64) -> Bool {
    x > 3
  }

  fn greater_than_ten(x :: i64) -> Bool {
    x > 10
  }

  fn is_positive(x :: i64) -> Bool {
    x > 0
  }

  fn less_than(a :: i64, b :: i64) -> Bool {
    a < b
  }

  fn greater_than(a :: i64, b :: i64) -> Bool {
    a > b
  }

  fn concat_str(acc :: String, x :: String) -> String {
    acc <> x
  }

  fn str_less_than(a :: String, b :: String) -> Bool {
    String.length(a) < String.length(b)
  }

  fn double_str(s :: String) -> [String] {
    [s, s]
  }
}
