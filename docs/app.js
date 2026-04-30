var ZAP_SEARCH_DATA = [
{"struct":"Atom","type":"struct","name":"Atom","summary":"Functions for working with atoms.","url":"structs/Atom.html"},
{"struct":"Atom","type":"function","name":"to_string/1","summary":"Converts an atom to its string representation (the name\nwithout the leading colon).","url":"structs/Atom.html#to_string-1"},
{"struct":"Bool","type":"struct","name":"Bool","summary":"Functions for working with boolean values.","url":"structs/Bool.html"},
{"struct":"Bool","type":"function","name":"to_string/1","summary":"Converts a boolean to its string representation.","url":"structs/Bool.html#to_string-1"},
{"struct":"Bool","type":"function","name":"negate/1","summary":"Returns the logical negation of a boolean.","url":"structs/Bool.html#negate-1"},
{"struct":"Enum","type":"struct","name":"Enum","summary":"Functions for enumerating and transforming collections.","url":"structs/Enum.html"},
{"struct":"Enum","type":"function","name":"map/2","summary":"Transforms each element by applying the callback function.","url":"structs/Enum.html#map-2"},
{"struct":"Enum","type":"function","name":"filter/2","summary":"Keeps only elements for which the predicate returns true.","url":"structs/Enum.html#filter-2"},
{"struct":"Enum","type":"function","name":"reject/2","summary":"Removes elements for which the predicate returns true.","url":"structs/Enum.html#reject-2"},
{"struct":"Enum","type":"function","name":"reduce/3","summary":"Folds the list into a single value using an accumulator.","url":"structs/Enum.html#reduce-3"},
{"struct":"Enum","type":"function","name":"each/2","summary":"Applies the callback to each element for side effects.","url":"structs/Enum.html#each-2"},
{"struct":"Enum","type":"function","name":"find/3","summary":"Returns the first element for which the predicate returns true.","url":"structs/Enum.html#find-3"},
{"struct":"Enum","type":"function","name":"any?/2","summary":"Returns true if the predicate returns true for any element.","url":"structs/Enum.html#any?-2"},
{"struct":"Enum","type":"function","name":"all?/2","summary":"Returns true if the predicate returns true for all elements.","url":"structs/Enum.html#all?-2"},
{"struct":"Enum","type":"function","name":"count/2","summary":"Counts elements for which the predicate returns true.","url":"structs/Enum.html#count-2"},
{"struct":"Enum","type":"function","name":"sum/1","summary":"Returns the sum of all elements.","url":"structs/Enum.html#sum-1"},
{"struct":"Enum","type":"function","name":"product/1","summary":"Returns the product of all elements.","url":"structs/Enum.html#product-1"},
{"struct":"Enum","type":"function","name":"max/1","summary":"Returns the maximum element.","url":"structs/Enum.html#max-1"},
{"struct":"Enum","type":"function","name":"min/1","summary":"Returns the minimum element.","url":"structs/Enum.html#min-1"},
{"struct":"Enum","type":"function","name":"sort/2","summary":"Sorts the list using a comparator function.","url":"structs/Enum.html#sort-2"},
{"struct":"Enum","type":"function","name":"flat_map/2","summary":"Maps each element to a list and flattens the results\ninto a single list.","url":"structs/Enum.html#flat_map-2"},
{"struct":"Enum","type":"function","name":"take/2","summary":"Returns the first `count` elements from the list.","url":"structs/Enum.html#take-2"},
{"struct":"Enum","type":"function","name":"drop/2","summary":"Drops the first `count` elements from the list.","url":"structs/Enum.html#drop-2"},
{"struct":"Enum","type":"function","name":"reverse/1","summary":"Reverses the order of elements in the list.","url":"structs/Enum.html#reverse-1"},
{"struct":"Enum","type":"function","name":"member?/2","summary":"Returns true if the list contains the given value.","url":"structs/Enum.html#member?-2"},
{"struct":"Enum","type":"function","name":"at/2","summary":"Returns the element at the given zero-based index.","url":"structs/Enum.html#at-2"},
{"struct":"Enum","type":"function","name":"concat/2","summary":"Concatenates two lists into a single list.","url":"structs/Enum.html#concat-2"},
{"struct":"Enum","type":"function","name":"uniq/1","summary":"Returns a new list with duplicate values removed.","url":"structs/Enum.html#uniq-1"},
{"struct":"Enum","type":"function","name":"empty?/1","summary":"Returns true if the list has no elements.","url":"structs/Enum.html#empty?-1"},
{"struct":"File","type":"struct","name":"File","summary":"Functions for reading and writing files.","url":"structs/File.html"},
{"struct":"File","type":"function","name":"read/1","summary":"Reads the entire contents of a file as a string.","url":"structs/File.html#read-1"},
{"struct":"File","type":"function","name":"write/2","summary":"Writes a string to a file, creating it if it doesn't exist\nand overwriting if it does.","url":"structs/File.html#write-2"},
{"struct":"File","type":"function","name":"exists?/1","summary":"Returns true if the file exists at the given path.","url":"structs/File.html#exists?-1"},
{"struct":"Float","type":"struct","name":"Float","summary":"Functions for working with floating-point numbers.","url":"structs/Float.html"},
{"struct":"Float","type":"function","name":"to_string/1","summary":"Converts a floating-point number to its string representation.","url":"structs/Float.html#to_string-1"},
{"struct":"Float","type":"function","name":"abs/1","summary":"Returns the absolute value of a float.","url":"structs/Float.html#abs-1"},
{"struct":"Float","type":"function","name":"max/2","summary":"Returns the larger of two floats.","url":"structs/Float.html#max-2"},
{"struct":"Float","type":"function","name":"min/2","summary":"Returns the smaller of two floats.","url":"structs/Float.html#min-2"},
{"struct":"Float","type":"function","name":"parse/1","summary":"Parses a string into a float.","url":"structs/Float.html#parse-1"},
{"struct":"Float","type":"function","name":"round/1","summary":"Rounds a float to the nearest integer value, returned as a float.","url":"structs/Float.html#round-1"},
{"struct":"Float","type":"function","name":"floor/1","summary":"Returns the largest integer value less than or equal to the\ngiven float, returned as a float.","url":"structs/Float.html#floor-1"},
{"struct":"Float","type":"function","name":"ceil/1","summary":"Returns the smallest integer value greater than or equal to\nthe given float, returned as a float.","url":"structs/Float.html#ceil-1"},
{"struct":"Float","type":"function","name":"truncate/1","summary":"Truncates a float toward zero, removing the fractional part.","url":"structs/Float.html#truncate-1"},
{"struct":"Float","type":"function","name":"to_integer/1","summary":"Converts a float to an integer by truncating toward zero.","url":"structs/Float.html#to_integer-1"},
{"struct":"Float","type":"function","name":"clamp/3","summary":"Clamps a float to be within the given range.","url":"structs/Float.html#clamp-3"},
{"struct":"Float","type":"function","name":"floor_to_integer/1","summary":"Floors a float and converts directly to an integer in one step.","url":"structs/Float.html#floor_to_integer-1"},
{"struct":"Float","type":"function","name":"ceil_to_integer/1","summary":"Ceils a float and converts directly to an integer in one step.","url":"structs/Float.html#ceil_to_integer-1"},
{"struct":"Float","type":"function","name":"round_to_integer/1","summary":"Rounds a float and converts directly to an integer in one step.","url":"structs/Float.html#round_to_integer-1"},
{"struct":"Function","type":"struct","name":"Function","summary":"Utilities for working with first-class function values.","url":"structs/Function.html"},
{"struct":"Function","type":"macro","name":"identity/1","summary":"Returns the value unchanged.","url":"structs/Function.html#identity-1"},
{"struct":"IO","type":"struct","name":"IO","summary":"Functions for standard input/output operations.","url":"structs/IO.html"},
{"struct":"IO","type":"function","name":"puts/1","summary":"Prints a value to standard output followed by a newline.","url":"structs/IO.html#puts-1"},
{"struct":"IO","type":"function","name":"print_str/1","summary":"Prints a value to standard output without a trailing newline.","url":"structs/IO.html#print_str-1"},
{"struct":"Integer","type":"struct","name":"Integer","summary":"Functions for working with integers.","url":"structs/Integer.html"},
{"struct":"Integer","type":"function","name":"to_string/1","summary":"Converts an integer to its string representation.","url":"structs/Integer.html#to_string-1"},
{"struct":"Integer","type":"function","name":"abs/1","summary":"Returns the absolute value of an integer.","url":"structs/Integer.html#abs-1"},
{"struct":"Integer","type":"function","name":"max/2","summary":"Returns the larger of two integers.","url":"structs/Integer.html#max-2"},
{"struct":"Integer","type":"function","name":"min/2","summary":"Returns the smaller of two integers.","url":"structs/Integer.html#min-2"},
{"struct":"Integer","type":"function","name":"parse/1","summary":"Parses a string into an integer.","url":"structs/Integer.html#parse-1"},
{"struct":"Integer","type":"function","name":"remainder/2","summary":"Computes the remainder of integer division.","url":"structs/Integer.html#remainder-2"},
{"struct":"Integer","type":"function","name":"pow/2","summary":"Raises `base` to the power of `exponent`.","url":"structs/Integer.html#pow-2"},
{"struct":"Integer","type":"function","name":"clamp/3","summary":"Clamps a value to be within the given range.","url":"structs/Integer.html#clamp-3"},
{"struct":"Integer","type":"function","name":"digits/1","summary":"Returns the number of digits in an integer.","url":"structs/Integer.html#digits-1"},
{"struct":"Integer","type":"function","name":"count_digits/1","summary":"","url":"structs/Integer.html#count_digits-1"},
{"struct":"Integer","type":"function","name":"to_float/1","summary":"Converts an integer to a floating-point number.","url":"structs/Integer.html#to_float-1"},
{"struct":"Integer","type":"function","name":"count_leading_zeros/1","summary":"Returns the number of leading zeros in the binary representation.","url":"structs/Integer.html#count_leading_zeros-1"},
{"struct":"Integer","type":"function","name":"count_trailing_zeros/1","summary":"Returns the number of trailing zeros in the binary representation.","url":"structs/Integer.html#count_trailing_zeros-1"},
{"struct":"Integer","type":"function","name":"popcount/1","summary":"Returns the number of set bits (ones) in the binary representation.","url":"structs/Integer.html#popcount-1"},
{"struct":"Integer","type":"function","name":"byte_swap/1","summary":"Reverses the byte order of an integer.","url":"structs/Integer.html#byte_swap-1"},
{"struct":"Integer","type":"function","name":"bit_reverse/1","summary":"Reverses all bits in the binary representation.","url":"structs/Integer.html#bit_reverse-1"},
{"struct":"Integer","type":"function","name":"add_sat/2","summary":"Adds two integers with saturation.","url":"structs/Integer.html#add_sat-2"},
{"struct":"Integer","type":"function","name":"sub_sat/2","summary":"Subtracts two integers with saturation.","url":"structs/Integer.html#sub_sat-2"},
{"struct":"Integer","type":"function","name":"mul_sat/2","summary":"Multiplies two integers with saturation.","url":"structs/Integer.html#mul_sat-2"},
{"struct":"Integer","type":"function","name":"band/2","summary":"Bitwise AND of two integers.","url":"structs/Integer.html#band-2"},
{"struct":"Integer","type":"function","name":"bor/2","summary":"Bitwise OR of two integers.","url":"structs/Integer.html#bor-2"},
{"struct":"Integer","type":"function","name":"bxor/2","summary":"Bitwise XOR (exclusive OR) of two integers.","url":"structs/Integer.html#bxor-2"},
{"struct":"Integer","type":"function","name":"bnot/1","summary":"Bitwise NOT (complement) of an integer.","url":"structs/Integer.html#bnot-1"},
{"struct":"Integer","type":"function","name":"bsl/2","summary":"Bitwise shift left.","url":"structs/Integer.html#bsl-2"},
{"struct":"Integer","type":"function","name":"bsr/2","summary":"Bitwise shift right (arithmetic).","url":"structs/Integer.html#bsr-2"},
{"struct":"Integer","type":"function","name":"sign/1","summary":"Returns the sign of an integer: -1 for negative, 0 for zero,\n1 for positive.","url":"structs/Integer.html#sign-1"},
{"struct":"Integer","type":"function","name":"even?/1","summary":"Returns true if the integer is even.","url":"structs/Integer.html#even?-1"},
{"struct":"Integer","type":"function","name":"odd?/1","summary":"Returns true if the integer is odd.","url":"structs/Integer.html#odd?-1"},
{"struct":"Integer","type":"function","name":"gcd/2","summary":"Computes the greatest common divisor of two integers\nusing the Euclidean algorithm.","url":"structs/Integer.html#gcd-2"},
{"struct":"Integer","type":"function","name":"lcm/2","summary":"Computes the least common multiple of two integers.","url":"structs/Integer.html#lcm-2"},
{"struct":"Kernel","type":"struct","name":"Kernel","summary":"The default struct imported into every Zap struct.","url":"structs/Kernel.html"},
{"struct":"Kernel","type":"macro","name":"if/2","summary":"Conditional expression with a single branch.","url":"structs/Kernel.html#if-2"},
{"struct":"Kernel","type":"macro","name":"if/3","summary":"Conditional expression with both branches.","url":"structs/Kernel.html#if-3"},
{"struct":"Kernel","type":"macro","name":"unless/2","summary":"Negated conditional.","url":"structs/Kernel.html#unless-2"},
{"struct":"Kernel","type":"macro","name":"and/2","summary":"Short-circuit logical AND.","url":"structs/Kernel.html#and-2"},
{"struct":"Kernel","type":"macro","name":"or/2","summary":"Short-circuit logical OR.","url":"structs/Kernel.html#or-2"},
{"struct":"Kernel","type":"macro","name":"fn/1","summary":"Declaration macro for function definitions.","url":"structs/Kernel.html#fn-1"},
{"struct":"Kernel","type":"macro","name":"struct/1","summary":"Declaration macro for struct definitions.","url":"structs/Kernel.html#struct-1"},
{"struct":"Kernel","type":"macro","name":"union/1","summary":"Declaration macro for union/enum definitions.","url":"structs/Kernel.html#union-1"},
{"struct":"Kernel","type":"macro","name":"sigil_s/2","summary":"String sigil with interpolation support.","url":"structs/Kernel.html#sigil_s-2"},
{"struct":"Kernel","type":"macro","name":"sigil_S/2","summary":"Raw string sigil without interpolation.","url":"structs/Kernel.html#sigil_S-2"},
{"struct":"Kernel","type":"macro","name":"sigil_w/2","summary":"Word list sigil with interpolation support.","url":"structs/Kernel.html#sigil_w-2"},
{"struct":"Kernel","type":"macro","name":"sigil_W/2","summary":"Word list sigil without interpolation.","url":"structs/Kernel.html#sigil_W-2"},
{"struct":"Kernel","type":"macro","name":"|>/2","summary":"Pipe operator.","url":"structs/Kernel.html#|>-2"},
{"struct":"List","type":"struct","name":"List","summary":"Functions for working with lists.","url":"structs/List.html"},
{"struct":"List","type":"function","name":"empty?/1","summary":"Returns `true` if the list has no elements.","url":"structs/List.html#empty?-1"},
{"struct":"List","type":"function","name":"length/1","summary":"Returns the number of elements in the list.","url":"structs/List.html#length-1"},
{"struct":"List","type":"function","name":"head/1","summary":"Returns the first element of the list.","url":"structs/List.html#head-1"},
{"struct":"List","type":"function","name":"tail/1","summary":"Returns the list without its first element.","url":"structs/List.html#tail-1"},
{"struct":"List","type":"function","name":"at/2","summary":"Returns the element at the given zero-based index.","url":"structs/List.html#at-2"},
{"struct":"List","type":"function","name":"last/1","summary":"Returns the last element of the list.","url":"structs/List.html#last-1"},
{"struct":"List","type":"function","name":"contains?/2","summary":"Returns `true` if the list contains the given value.","url":"structs/List.html#contains?-2"},
{"struct":"List","type":"function","name":"reverse/1","summary":"Reverses the order of elements.","url":"structs/List.html#reverse-1"},
{"struct":"List","type":"function","name":"prepend/2","summary":"Prepends a value to the front of a list.","url":"structs/List.html#prepend-2"},
{"struct":"List","type":"function","name":"append/2","summary":"Appends a value to the end of a list.","url":"structs/List.html#append-2"},
{"struct":"List","type":"function","name":"concat/2","summary":"Concatenates two lists.","url":"structs/List.html#concat-2"},
{"struct":"List","type":"function","name":"take/2","summary":"Takes the first `count` elements.","url":"structs/List.html#take-2"},
{"struct":"List","type":"function","name":"drop/2","summary":"Drops the first `count` elements.","url":"structs/List.html#drop-2"},
{"struct":"List","type":"function","name":"uniq/1","summary":"Returns a new list with duplicates removed.","url":"structs/List.html#uniq-1"},
{"struct":"Map","type":"struct","name":"Map","summary":"Functions for working with maps.","url":"structs/Map.html"},
{"struct":"Map","type":"function","name":"get/3","summary":"Returns the value for the given key, or the default if\nthe key is not found.","url":"structs/Map.html#get-3"},
{"struct":"Map","type":"function","name":"has_key?/2","summary":"Returns `true` if the map contains the given key.","url":"structs/Map.html#has_key?-2"},
{"struct":"Map","type":"function","name":"size/1","summary":"Returns the number of entries in the map.","url":"structs/Map.html#size-1"},
{"struct":"Map","type":"function","name":"empty?/1","summary":"Returns `true` if the map has no entries.","url":"structs/Map.html#empty?-1"},
{"struct":"Map","type":"function","name":"put/3","summary":"Returns a new map with the key set to the given value.","url":"structs/Map.html#put-3"},
{"struct":"Map","type":"function","name":"delete/2","summary":"Returns a new map with the given key removed.","url":"structs/Map.html#delete-2"},
{"struct":"Map","type":"function","name":"merge/2","summary":"Merges two maps.","url":"structs/Map.html#merge-2"},
{"struct":"Map","type":"function","name":"keys/1","summary":"Returns a list of all keys in the map.","url":"structs/Map.html#keys-1"},
{"struct":"Map","type":"function","name":"values/1","summary":"Returns a list of all values in the map.","url":"structs/Map.html#values-1"},
{"struct":"Math","type":"struct","name":"Math","summary":"Mathematical functions for floating-point computation.","url":"structs/Math.html"},
{"struct":"Math","type":"function","name":"pi/0","summary":"Returns the ratio of a circle's circumference to its diameter.","url":"structs/Math.html#pi-0"},
{"struct":"Math","type":"function","name":"e/0","summary":"Returns Euler's number, the base of natural logarithms.","url":"structs/Math.html#e-0"},
{"struct":"Math","type":"function","name":"sqrt/1","summary":"Returns the square root of a number.","url":"structs/Math.html#sqrt-1"},
{"struct":"Math","type":"function","name":"sin/1","summary":"Returns the sine of an angle in radians.","url":"structs/Math.html#sin-1"},
{"struct":"Math","type":"function","name":"cos/1","summary":"Returns the cosine of an angle in radians.","url":"structs/Math.html#cos-1"},
{"struct":"Math","type":"function","name":"tan/1","summary":"Returns the tangent of an angle in radians.","url":"structs/Math.html#tan-1"},
{"struct":"Math","type":"function","name":"exp/1","summary":"Returns e raised to the given power.","url":"structs/Math.html#exp-1"},
{"struct":"Math","type":"function","name":"exp2/1","summary":"Returns 2 raised to the given power.","url":"structs/Math.html#exp2-1"},
{"struct":"Math","type":"function","name":"log/1","summary":"Returns the natural logarithm (base e) of a number.","url":"structs/Math.html#log-1"},
{"struct":"Math","type":"function","name":"log2/1","summary":"Returns the base-2 logarithm of a number.","url":"structs/Math.html#log2-1"},
{"struct":"Math","type":"function","name":"log10/1","summary":"Returns the base-10 logarithm of a number.","url":"structs/Math.html#log10-1"},
{"struct":"String","type":"struct","name":"String","summary":"Functions for working with UTF-8 encoded strings.","url":"structs/String.html"},
{"struct":"String","type":"function","name":"length/1","summary":"Returns the byte length of a string.","url":"structs/String.html#length-1"},
{"struct":"String","type":"function","name":"byte_at/2","summary":"Returns the byte at the given index as a single-character string.","url":"structs/String.html#byte_at-2"},
{"struct":"String","type":"function","name":"contains/2","summary":"Returns `true` if `haystack` contains `needle` as a substring.","url":"structs/String.html#contains-2"},
{"struct":"String","type":"function","name":"starts_with/2","summary":"Returns `true` if the string starts with the given prefix.","url":"structs/String.html#starts_with-2"},
{"struct":"String","type":"function","name":"ends_with/2","summary":"Returns `true` if the string ends with the given suffix.","url":"structs/String.html#ends_with-2"},
{"struct":"String","type":"function","name":"trim/1","summary":"Removes leading and trailing whitespace from a string.","url":"structs/String.html#trim-1"},
{"struct":"String","type":"function","name":"slice/3","summary":"Returns a substring from `start` (inclusive) to `end` (exclusive).","url":"structs/String.html#slice-3"},
{"struct":"String","type":"function","name":"to_atom/1","summary":"Converts a string to an atom, creating it if it doesn't exist.","url":"structs/String.html#to_atom-1"},
{"struct":"String","type":"function","name":"to_existing_atom/1","summary":"Converts a string to an existing atom.","url":"structs/String.html#to_existing_atom-1"},
{"struct":"String","type":"function","name":"upcase/1","summary":"Converts all characters to uppercase.","url":"structs/String.html#upcase-1"},
{"struct":"String","type":"function","name":"downcase/1","summary":"Converts all characters to lowercase.","url":"structs/String.html#downcase-1"},
{"struct":"String","type":"function","name":"reverse/1","summary":"Reverses the bytes of a string.","url":"structs/String.html#reverse-1"},
{"struct":"String","type":"function","name":"replace/3","summary":"Replaces all occurrences of `pattern` with `replacement`.","url":"structs/String.html#replace-3"},
{"struct":"String","type":"function","name":"index_of/2","summary":"Returns the index of the first occurrence of `needle` in the\nstring, or -1 if not found.","url":"structs/String.html#index_of-2"},
{"struct":"String","type":"function","name":"pad_leading/3","summary":"Pads the string on the left to reach the target length using\nthe given padding character.","url":"structs/String.html#pad_leading-3"},
{"struct":"String","type":"function","name":"pad_trailing/3","summary":"Pads the string on the right to reach the target length using\nthe given padding character.","url":"structs/String.html#pad_trailing-3"},
{"struct":"String","type":"function","name":"repeat/2","summary":"Repeats a string the given number of times.","url":"structs/String.html#repeat-2"},
{"struct":"String","type":"function","name":"to_integer/1","summary":"Parses a string into an integer.","url":"structs/String.html#to_integer-1"},
{"struct":"String","type":"function","name":"to_float/1","summary":"Parses a string into a float.","url":"structs/String.html#to_float-1"},
{"struct":"String","type":"function","name":"capitalize/1","summary":"Capitalizes the first character and lowercases the rest.","url":"structs/String.html#capitalize-1"},
{"struct":"String","type":"function","name":"trim_leading/1","summary":"Removes leading whitespace from a string.","url":"structs/String.html#trim_leading-1"},
{"struct":"String","type":"function","name":"trim_trailing/1","summary":"Removes trailing whitespace from a string.","url":"structs/String.html#trim_trailing-1"},
{"struct":"String","type":"function","name":"count/2","summary":"Counts non-overlapping occurrences of a substring.","url":"structs/String.html#count-2"},
{"struct":"System","type":"struct","name":"System","summary":"Functions for interacting with the operating system.","url":"structs/System.html"},
{"struct":"System","type":"function","name":"arg_count/0","summary":"Returns the number of command-line arguments passed to the program.","url":"structs/System.html#arg_count-0"},
{"struct":"System","type":"function","name":"arg_at/1","summary":"Returns the command-line argument at the given index.","url":"structs/System.html#arg_at-1"},
{"struct":"System","type":"function","name":"get_env/1","summary":"Reads an environment variable by name.","url":"structs/System.html#get_env-1"},
{"struct":"System","type":"function","name":"get_build_opt/1","summary":"Reads a build-time option by name.","url":"structs/System.html#get_build_opt-1"},
{"struct":"Zest","type":"struct","name":"Zest","summary":"Zest test framework.","url":"structs/Zest.html"},
{"struct":"Zest","type":"function","name":"assert/1","summary":"Asserts that a boolean value is `true`.","url":"structs/Zest.html#assert-1"},
{"struct":"Zest","type":"function","name":"assert/2","summary":"Asserts that a boolean value is `true` with a custom message.","url":"structs/Zest.html#assert-2"},
{"struct":"Zest","type":"function","name":"reject/1","summary":"Asserts that a boolean value is `false`.","url":"structs/Zest.html#reject-1"},
{"struct":"Zest","type":"function","name":"reject/2","summary":"Asserts that a boolean value is `false` with a custom message.","url":"structs/Zest.html#reject-2"},
{"struct":"Zest.Case","type":"struct","name":"Zest.Case","summary":"Test case DSL for the Zest test framework.","url":"structs/Zest.Case.html"},
{"struct":"Zest.Case","type":"function","name":"begin_test/0","summary":"Wraps `begin_test` for explicit use.","url":"structs/Zest.Case.html#begin_test-0"},
{"struct":"Zest.Case","type":"function","name":"end_test/0","summary":"Wraps `end_test` for explicit use.","url":"structs/Zest.Case.html#end_test-0"},
{"struct":"Zest.Case","type":"function","name":"print_result/0","summary":"Wraps `print_result` for explicit use.","url":"structs/Zest.Case.html#print_result-0"},
{"struct":"Zest.Case","type":"function","name":"assert/1","summary":"Asserts that a boolean value is `true`.","url":"structs/Zest.Case.html#assert-1"},
{"struct":"Zest.Case","type":"function","name":"reject/1","summary":"Asserts that a boolean value is `false`.","url":"structs/Zest.Case.html#reject-1"},
{"struct":"Zest.Case","type":"macro","name":"describe/2","summary":"Groups related tests under a descriptive label.","url":"structs/Zest.Case.html#describe-2"},
{"struct":"Zest.Case","type":"macro","name":"test/2","summary":"Defines a test case without context.","url":"structs/Zest.Case.html#test-2"},
{"struct":"Zest.Case","type":"macro","name":"setup/1","summary":"Declares setup code that runs before each test with context.","url":"structs/Zest.Case.html#setup-1"},
{"struct":"Zest.Case","type":"macro","name":"teardown/1","summary":"Declares teardown code that runs after each test.","url":"structs/Zest.Case.html#teardown-1"},
{"struct":"Zest.Runner","type":"struct","name":"Zest.Runner","summary":"Finalizes test execution and prints the summary report.","url":"structs/Zest.Runner.html"},
{"struct":"Zest.Runner","type":"function","name":"configure/0","summary":"Parses `--seed` and `--timeout` from CLI arguments and applies\nthem to the test tracker.","url":"structs/Zest.Runner.html#configure-0"},
{"struct":"Zest.Runner","type":"function","name":"run/0","summary":"Prints the test summary with counts and exits with a\nfailure code if any tests failed.","url":"structs/Zest.Runner.html#run-0"},
{"struct":"Zest.Runner","type":"function","name":"parse_cli_args/2","summary":"Recursively scans CLI arguments for `--seed <value>` and\n`--timeout <milliseconds>`, applying each to the test tracker.","url":"structs/Zest.Runner.html#parse_cli_args-2"}
];
/* Zap Documentation */
(function() {
  'use strict';

  // Dark mode
  var toggle = document.getElementById('theme-toggle');
  var html = document.documentElement;
  var saved = localStorage.getItem('zap-docs-theme');
  if (saved) {
    html.setAttribute('data-theme', saved);
  } else if (window.matchMedia('(prefers-color-scheme: dark)').matches) {
    html.setAttribute('data-theme', 'dark');
  }
  if (toggle) {
    toggle.addEventListener('click', function() {
      var current = html.getAttribute('data-theme');
      var next = current === 'dark' ? 'light' : 'dark';
      html.setAttribute('data-theme', next);
      localStorage.setItem('zap-docs-theme', next);
    });
  }

  // Base path from meta tag
  var baseMeta = document.querySelector('meta[name="zap-docs-base"]');
  var basePath = baseMeta ? baseMeta.getAttribute('content') : '';

  // Search — data is inlined by the doc generator as ZAP_SEARCH_DATA
  var searchData = (typeof ZAP_SEARCH_DATA !== 'undefined') ? ZAP_SEARCH_DATA : null;
  var searchModal = document.getElementById('search-modal');
  var searchInput = document.getElementById('search-modal-input');
  var searchResults = document.getElementById('search-results');
  var sidebarInput = document.getElementById('search-input');
  var selectedIndex = -1;

  function openSearch() {
    searchModal.hidden = false;
    searchInput.value = '';
    searchResults.innerHTML = '';
    selectedIndex = -1;
    searchInput.focus();
  }

  function closeSearch() {
    searchModal.hidden = true;
  }

  function doSearch(query) {
    if (!searchData || !query) { searchResults.innerHTML = ''; return; }
    var q = query.toLowerCase();
    var matches = searchData.filter(function(item) {
      return item.name.toLowerCase().indexOf(q) !== -1 ||
             item.struct.toLowerCase().indexOf(q) !== -1 ||
             item.summary.toLowerCase().indexOf(q) !== -1;
    }).slice(0, 20);
    searchResults.innerHTML = matches.map(function(item, i) {
      return '<li data-url="' + basePath + item.url + '"' + (i === 0 ? ' class="selected"' : '') + '>' +
        '<div class="result-name">' + escapeHtml(item.name) + '</div>' +
        '<div class="result-struct">' + escapeHtml(item.struct) + ' &middot; ' + item.type + '</div>' +
        (item.summary ? '<div class="result-summary">' + escapeHtml(item.summary) + '</div>' : '') +
        '</li>';
    }).join('');
    selectedIndex = matches.length > 0 ? 0 : -1;
  }

  function escapeHtml(s) {
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  // Keyboard shortcuts
  document.addEventListener('keydown', function(e) {
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
      e.preventDefault();
      if (searchModal.hidden) openSearch(); else closeSearch();
    }
    if (e.key === 'Escape' && !searchModal.hidden) closeSearch();
    if (!searchModal.hidden) {
      var items = searchResults.querySelectorAll('li');
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        selectedIndex = Math.min(selectedIndex + 1, items.length - 1);
        items.forEach(function(li, i) { li.className = i === selectedIndex ? 'selected' : ''; });
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        selectedIndex = Math.max(selectedIndex - 1, 0);
        items.forEach(function(li, i) { li.className = i === selectedIndex ? 'selected' : ''; });
      }
      if (e.key === 'Enter' && selectedIndex >= 0 && selectedIndex < items.length) {
        e.preventDefault();
        window.location.href = items[selectedIndex].getAttribute('data-url');
      }
    }
  });

  if (searchInput) {
    searchInput.addEventListener('input', function() { doSearch(this.value); });
  }
  if (sidebarInput) {
    sidebarInput.addEventListener('focus', function() { openSearch(); });
  }
  var backdrop = document.querySelector('.search-backdrop');
  if (backdrop) {
    backdrop.addEventListener('click', closeSearch);
  }
  if (searchResults) {
    searchResults.addEventListener('click', function(e) {
      var li = e.target.closest('li');
      if (li) window.location.href = li.getAttribute('data-url');
    });
  }

  // Scroll spy for TOC
  var tocLinks = document.querySelectorAll('.toc a');
  if (tocLinks.length > 0) {
    var observer = new IntersectionObserver(function(entries) {
      entries.forEach(function(entry) {
        if (entry.isIntersecting) {
          tocLinks.forEach(function(link) {
            link.parentElement.classList.remove('active');
            if (link.getAttribute('href') === '#' + entry.target.id) {
              link.parentElement.classList.add('active');
            }
          });
        }
      });
    }, { rootMargin: '-20% 0px -70% 0px' });
    document.querySelectorAll('.function-detail').forEach(function(el) {
      observer.observe(el);
    });
  }

  // Copy buttons on code blocks
  document.querySelectorAll('pre').forEach(function(pre) {
    var btn = document.createElement('button');
    btn.className = 'copy-btn';
    btn.textContent = 'Copy';
    btn.addEventListener('click', function() {
      var code = pre.querySelector('code');
      navigator.clipboard.writeText(code ? code.textContent : pre.textContent);
      btn.textContent = 'Copied!';
      setTimeout(function() { btn.textContent = 'Copy'; }, 2000);
    });
    pre.style.position = 'relative';
    pre.appendChild(btn);
  });
})();
