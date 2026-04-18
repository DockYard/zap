var ZAP_SEARCH_DATA = [
{"module":"Atom","type":"module","name":"Atom","summary":"Functions for working with atoms.","url":"modules/Atom.html"},
{"module":"Atom","type":"function","name":"to_string/1","summary":"Converts an atom to its string representation (the name\nwithout the leading colon).","url":"modules/Atom.html#to_string-1"},
{"module":"Bool","type":"module","name":"Bool","summary":"Functions for working with boolean values.","url":"modules/Bool.html"},
{"module":"Bool","type":"function","name":"to_string/1","summary":"Converts a boolean to its string representation.","url":"modules/Bool.html#to_string-1"},
{"module":"Bool","type":"function","name":"negate/1","summary":"Returns the logical negation of a boolean.","url":"modules/Bool.html#negate-1"},
{"module":"Enum","type":"module","name":"Enum","summary":"Functions for enumerating and transforming collections.","url":"modules/Enum.html"},
{"module":"Enum","type":"function","name":"map/2","summary":"Transforms each element by applying the callback function.","url":"modules/Enum.html#map-2"},
{"module":"Enum","type":"function","name":"filter/2","summary":"Keeps only elements for which the predicate returns true.","url":"modules/Enum.html#filter-2"},
{"module":"Enum","type":"function","name":"reject/2","summary":"Removes elements for which the predicate returns true.","url":"modules/Enum.html#reject-2"},
{"module":"Enum","type":"function","name":"reduce/3","summary":"Folds the list into a single value using an accumulator.","url":"modules/Enum.html#reduce-3"},
{"module":"Enum","type":"function","name":"each/2","summary":"Applies the callback to each element for side effects.","url":"modules/Enum.html#each-2"},
{"module":"Enum","type":"function","name":"find/3","summary":"Returns the first element for which the predicate returns true.","url":"modules/Enum.html#find-3"},
{"module":"Enum","type":"function","name":"any?/2","summary":"Returns true if the predicate returns true for any element.","url":"modules/Enum.html#any?-2"},
{"module":"Enum","type":"function","name":"all?/2","summary":"Returns true if the predicate returns true for all elements.","url":"modules/Enum.html#all?-2"},
{"module":"Enum","type":"function","name":"count/2","summary":"Counts elements for which the predicate returns true.","url":"modules/Enum.html#count-2"},
{"module":"Enum","type":"function","name":"sum/1","summary":"Returns the sum of all elements.","url":"modules/Enum.html#sum-1"},
{"module":"Enum","type":"function","name":"product/1","summary":"Returns the product of all elements.","url":"modules/Enum.html#product-1"},
{"module":"Enum","type":"function","name":"max/1","summary":"Returns the maximum element.","url":"modules/Enum.html#max-1"},
{"module":"Enum","type":"function","name":"min/1","summary":"Returns the minimum element.","url":"modules/Enum.html#min-1"},
{"module":"Enum","type":"function","name":"sort/2","summary":"Sorts the list using a comparator function.","url":"modules/Enum.html#sort-2"},
{"module":"Enum","type":"function","name":"flat_map/2","summary":"Maps each element to a list and flattens the results\ninto a single list.","url":"modules/Enum.html#flat_map-2"},
{"module":"Enum","type":"function","name":"take/2","summary":"Returns the first `count` elements from the list.","url":"modules/Enum.html#take-2"},
{"module":"Enum","type":"function","name":"drop/2","summary":"Drops the first `count` elements from the list.","url":"modules/Enum.html#drop-2"},
{"module":"Enum","type":"function","name":"reverse/1","summary":"Reverses the order of elements in the list.","url":"modules/Enum.html#reverse-1"},
{"module":"Enum","type":"function","name":"member?/2","summary":"Returns true if the list contains the given value.","url":"modules/Enum.html#member?-2"},
{"module":"Enum","type":"function","name":"at/2","summary":"Returns the element at the given zero-based index.","url":"modules/Enum.html#at-2"},
{"module":"Enum","type":"function","name":"concat/2","summary":"Concatenates two lists into a single list.","url":"modules/Enum.html#concat-2"},
{"module":"Enum","type":"function","name":"uniq/1","summary":"Returns a new list with duplicate values removed.","url":"modules/Enum.html#uniq-1"},
{"module":"Enum","type":"function","name":"empty?/1","summary":"Returns true if the list has no elements.","url":"modules/Enum.html#empty?-1"},
{"module":"File","type":"module","name":"File","summary":"Functions for reading and writing files.","url":"modules/File.html"},
{"module":"File","type":"function","name":"read/1","summary":"Reads the entire contents of a file as a string.","url":"modules/File.html#read-1"},
{"module":"File","type":"function","name":"write/2","summary":"Writes a string to a file, creating it if it doesn't exist\nand overwriting if it does.","url":"modules/File.html#write-2"},
{"module":"File","type":"function","name":"exists?/1","summary":"Returns true if the file exists at the given path.","url":"modules/File.html#exists?-1"},
{"module":"Float","type":"module","name":"Float","summary":"Functions for working with floating-point numbers.","url":"modules/Float.html"},
{"module":"Float","type":"function","name":"to_string/1","summary":"Converts a floating-point number to its string representation.","url":"modules/Float.html#to_string-1"},
{"module":"Float","type":"function","name":"abs/1","summary":"Returns the absolute value of a float.","url":"modules/Float.html#abs-1"},
{"module":"Float","type":"function","name":"max/2","summary":"Returns the larger of two floats.","url":"modules/Float.html#max-2"},
{"module":"Float","type":"function","name":"min/2","summary":"Returns the smaller of two floats.","url":"modules/Float.html#min-2"},
{"module":"Float","type":"function","name":"parse/1","summary":"Parses a string into a float.","url":"modules/Float.html#parse-1"},
{"module":"Float","type":"function","name":"round/1","summary":"Rounds a float to the nearest integer value, returned as a float.","url":"modules/Float.html#round-1"},
{"module":"Float","type":"function","name":"floor/1","summary":"Returns the largest integer value less than or equal to the\ngiven float, returned as a float.","url":"modules/Float.html#floor-1"},
{"module":"Float","type":"function","name":"ceil/1","summary":"Returns the smallest integer value greater than or equal to\nthe given float, returned as a float.","url":"modules/Float.html#ceil-1"},
{"module":"Float","type":"function","name":"truncate/1","summary":"Truncates a float toward zero, removing the fractional part.","url":"modules/Float.html#truncate-1"},
{"module":"Float","type":"function","name":"to_integer/1","summary":"Converts a float to an integer by truncating toward zero.","url":"modules/Float.html#to_integer-1"},
{"module":"Float","type":"function","name":"clamp/3","summary":"Clamps a float to be within the given range.","url":"modules/Float.html#clamp-3"},
{"module":"Float","type":"function","name":"floor_to_integer/1","summary":"Floors a float and converts directly to an integer in one step.","url":"modules/Float.html#floor_to_integer-1"},
{"module":"Float","type":"function","name":"ceil_to_integer/1","summary":"Ceils a float and converts directly to an integer in one step.","url":"modules/Float.html#ceil_to_integer-1"},
{"module":"Float","type":"function","name":"round_to_integer/1","summary":"Rounds a float and converts directly to an integer in one step.","url":"modules/Float.html#round_to_integer-1"},
{"module":"Function","type":"module","name":"Function","summary":"Utilities for working with first-class function values.","url":"modules/Function.html"},
{"module":"Function","type":"macro","name":"identity/1","summary":"Returns the value unchanged.","url":"modules/Function.html#identity-1"},
{"module":"IO","type":"module","name":"IO","summary":"Functions for standard input/output operations.","url":"modules/IO.html"},
{"module":"IO","type":"function","name":"puts/1","summary":"Prints a value to standard output followed by a newline.","url":"modules/IO.html#puts-1"},
{"module":"IO","type":"function","name":"print_str/1","summary":"Prints a value to standard output without a trailing newline.","url":"modules/IO.html#print_str-1"},
{"module":"Integer","type":"module","name":"Integer","summary":"Functions for working with integers.","url":"modules/Integer.html"},
{"module":"Integer","type":"function","name":"to_string/1","summary":"Converts an integer to its string representation.","url":"modules/Integer.html#to_string-1"},
{"module":"Integer","type":"function","name":"abs/1","summary":"Returns the absolute value of an integer.","url":"modules/Integer.html#abs-1"},
{"module":"Integer","type":"function","name":"max/2","summary":"Returns the larger of two integers.","url":"modules/Integer.html#max-2"},
{"module":"Integer","type":"function","name":"min/2","summary":"Returns the smaller of two integers.","url":"modules/Integer.html#min-2"},
{"module":"Integer","type":"function","name":"parse/1","summary":"Parses a string into an integer.","url":"modules/Integer.html#parse-1"},
{"module":"Integer","type":"function","name":"remainder/2","summary":"Computes the remainder of integer division.","url":"modules/Integer.html#remainder-2"},
{"module":"Integer","type":"function","name":"pow/2","summary":"Raises `base` to the power of `exponent`.","url":"modules/Integer.html#pow-2"},
{"module":"Integer","type":"function","name":"clamp/3","summary":"Clamps a value to be within the given range.","url":"modules/Integer.html#clamp-3"},
{"module":"Integer","type":"function","name":"digits/1","summary":"Returns the number of digits in an integer.","url":"modules/Integer.html#digits-1"},
{"module":"Integer","type":"function","name":"count_digits/1","summary":"","url":"modules/Integer.html#count_digits-1"},
{"module":"Integer","type":"function","name":"to_float/1","summary":"Converts an integer to a floating-point number.","url":"modules/Integer.html#to_float-1"},
{"module":"Integer","type":"function","name":"count_leading_zeros/1","summary":"Returns the number of leading zeros in the binary representation.","url":"modules/Integer.html#count_leading_zeros-1"},
{"module":"Integer","type":"function","name":"count_trailing_zeros/1","summary":"Returns the number of trailing zeros in the binary representation.","url":"modules/Integer.html#count_trailing_zeros-1"},
{"module":"Integer","type":"function","name":"popcount/1","summary":"Returns the number of set bits (ones) in the binary representation.","url":"modules/Integer.html#popcount-1"},
{"module":"Integer","type":"function","name":"byte_swap/1","summary":"Reverses the byte order of an integer.","url":"modules/Integer.html#byte_swap-1"},
{"module":"Integer","type":"function","name":"bit_reverse/1","summary":"Reverses all bits in the binary representation.","url":"modules/Integer.html#bit_reverse-1"},
{"module":"Integer","type":"function","name":"add_sat/2","summary":"Adds two integers with saturation.","url":"modules/Integer.html#add_sat-2"},
{"module":"Integer","type":"function","name":"sub_sat/2","summary":"Subtracts two integers with saturation.","url":"modules/Integer.html#sub_sat-2"},
{"module":"Integer","type":"function","name":"mul_sat/2","summary":"Multiplies two integers with saturation.","url":"modules/Integer.html#mul_sat-2"},
{"module":"Integer","type":"function","name":"band/2","summary":"Bitwise AND of two integers.","url":"modules/Integer.html#band-2"},
{"module":"Integer","type":"function","name":"bor/2","summary":"Bitwise OR of two integers.","url":"modules/Integer.html#bor-2"},
{"module":"Integer","type":"function","name":"bxor/2","summary":"Bitwise XOR (exclusive OR) of two integers.","url":"modules/Integer.html#bxor-2"},
{"module":"Integer","type":"function","name":"bnot/1","summary":"Bitwise NOT (complement) of an integer.","url":"modules/Integer.html#bnot-1"},
{"module":"Integer","type":"function","name":"bsl/2","summary":"Bitwise shift left.","url":"modules/Integer.html#bsl-2"},
{"module":"Integer","type":"function","name":"bsr/2","summary":"Bitwise shift right (arithmetic).","url":"modules/Integer.html#bsr-2"},
{"module":"Integer","type":"function","name":"sign/1","summary":"Returns the sign of an integer: -1 for negative, 0 for zero,\n1 for positive.","url":"modules/Integer.html#sign-1"},
{"module":"Integer","type":"function","name":"even?/1","summary":"Returns true if the integer is even.","url":"modules/Integer.html#even?-1"},
{"module":"Integer","type":"function","name":"odd?/1","summary":"Returns true if the integer is odd.","url":"modules/Integer.html#odd?-1"},
{"module":"Integer","type":"function","name":"gcd/2","summary":"Computes the greatest common divisor of two integers\nusing the Euclidean algorithm.","url":"modules/Integer.html#gcd-2"},
{"module":"Integer","type":"function","name":"lcm/2","summary":"Computes the least common multiple of two integers.","url":"modules/Integer.html#lcm-2"},
{"module":"Kernel","type":"module","name":"Kernel","summary":"The default module imported into every Zap module.","url":"modules/Kernel.html"},
{"module":"Kernel","type":"macro","name":"if/2","summary":"Conditional expression with a single branch.","url":"modules/Kernel.html#if-2"},
{"module":"Kernel","type":"macro","name":"if/3","summary":"Conditional expression with both branches.","url":"modules/Kernel.html#if-3"},
{"module":"Kernel","type":"macro","name":"unless/2","summary":"Negated conditional.","url":"modules/Kernel.html#unless-2"},
{"module":"Kernel","type":"macro","name":"and/2","summary":"Short-circuit logical AND.","url":"modules/Kernel.html#and-2"},
{"module":"Kernel","type":"macro","name":"or/2","summary":"Short-circuit logical OR.","url":"modules/Kernel.html#or-2"},
{"module":"Kernel","type":"macro","name":"fn/1","summary":"Declaration macro for function definitions.","url":"modules/Kernel.html#fn-1"},
{"module":"Kernel","type":"macro","name":"struct/1","summary":"Declaration macro for struct definitions.","url":"modules/Kernel.html#struct-1"},
{"module":"Kernel","type":"macro","name":"union/1","summary":"Declaration macro for union/enum definitions.","url":"modules/Kernel.html#union-1"},
{"module":"Kernel","type":"macro","name":"sigil_s/2","summary":"String sigil with interpolation support.","url":"modules/Kernel.html#sigil_s-2"},
{"module":"Kernel","type":"macro","name":"sigil_S/2","summary":"Raw string sigil without interpolation.","url":"modules/Kernel.html#sigil_S-2"},
{"module":"Kernel","type":"macro","name":"sigil_w/2","summary":"Word list sigil with interpolation support.","url":"modules/Kernel.html#sigil_w-2"},
{"module":"Kernel","type":"macro","name":"sigil_W/2","summary":"Word list sigil without interpolation.","url":"modules/Kernel.html#sigil_W-2"},
{"module":"Kernel","type":"macro","name":"|>/2","summary":"Pipe operator.","url":"modules/Kernel.html#|>-2"},
{"module":"List","type":"module","name":"List","summary":"Functions for working with lists.","url":"modules/List.html"},
{"module":"List","type":"function","name":"empty?/1","summary":"Returns `true` if the list has no elements.","url":"modules/List.html#empty?-1"},
{"module":"List","type":"function","name":"length/1","summary":"Returns the number of elements in the list.","url":"modules/List.html#length-1"},
{"module":"List","type":"function","name":"head/1","summary":"Returns the first element of the list.","url":"modules/List.html#head-1"},
{"module":"List","type":"function","name":"tail/1","summary":"Returns the list without its first element.","url":"modules/List.html#tail-1"},
{"module":"List","type":"function","name":"at/2","summary":"Returns the element at the given zero-based index.","url":"modules/List.html#at-2"},
{"module":"List","type":"function","name":"last/1","summary":"Returns the last element of the list.","url":"modules/List.html#last-1"},
{"module":"List","type":"function","name":"contains?/2","summary":"Returns `true` if the list contains the given value.","url":"modules/List.html#contains?-2"},
{"module":"List","type":"function","name":"reverse/1","summary":"Reverses the order of elements.","url":"modules/List.html#reverse-1"},
{"module":"List","type":"function","name":"prepend/2","summary":"Prepends a value to the front of a list.","url":"modules/List.html#prepend-2"},
{"module":"List","type":"function","name":"append/2","summary":"Appends a value to the end of a list.","url":"modules/List.html#append-2"},
{"module":"List","type":"function","name":"concat/2","summary":"Concatenates two lists.","url":"modules/List.html#concat-2"},
{"module":"List","type":"function","name":"take/2","summary":"Takes the first `count` elements.","url":"modules/List.html#take-2"},
{"module":"List","type":"function","name":"drop/2","summary":"Drops the first `count` elements.","url":"modules/List.html#drop-2"},
{"module":"List","type":"function","name":"uniq/1","summary":"Returns a new list with duplicates removed.","url":"modules/List.html#uniq-1"},
{"module":"Map","type":"module","name":"Map","summary":"Functions for working with maps.","url":"modules/Map.html"},
{"module":"Map","type":"function","name":"get/3","summary":"Returns the value for the given key, or the default if\nthe key is not found.","url":"modules/Map.html#get-3"},
{"module":"Map","type":"function","name":"has_key?/2","summary":"Returns `true` if the map contains the given key.","url":"modules/Map.html#has_key?-2"},
{"module":"Map","type":"function","name":"size/1","summary":"Returns the number of entries in the map.","url":"modules/Map.html#size-1"},
{"module":"Map","type":"function","name":"empty?/1","summary":"Returns `true` if the map has no entries.","url":"modules/Map.html#empty?-1"},
{"module":"Map","type":"function","name":"put/3","summary":"Returns a new map with the key set to the given value.","url":"modules/Map.html#put-3"},
{"module":"Map","type":"function","name":"delete/2","summary":"Returns a new map with the given key removed.","url":"modules/Map.html#delete-2"},
{"module":"Map","type":"function","name":"merge/2","summary":"Merges two maps.","url":"modules/Map.html#merge-2"},
{"module":"Map","type":"function","name":"keys/1","summary":"Returns a list of all keys in the map.","url":"modules/Map.html#keys-1"},
{"module":"Map","type":"function","name":"values/1","summary":"Returns a list of all values in the map.","url":"modules/Map.html#values-1"},
{"module":"Math","type":"module","name":"Math","summary":"Mathematical functions for floating-point computation.","url":"modules/Math.html"},
{"module":"Math","type":"function","name":"pi/0","summary":"Returns the ratio of a circle's circumference to its diameter.","url":"modules/Math.html#pi-0"},
{"module":"Math","type":"function","name":"e/0","summary":"Returns Euler's number, the base of natural logarithms.","url":"modules/Math.html#e-0"},
{"module":"Math","type":"function","name":"sqrt/1","summary":"Returns the square root of a number.","url":"modules/Math.html#sqrt-1"},
{"module":"Math","type":"function","name":"sin/1","summary":"Returns the sine of an angle in radians.","url":"modules/Math.html#sin-1"},
{"module":"Math","type":"function","name":"cos/1","summary":"Returns the cosine of an angle in radians.","url":"modules/Math.html#cos-1"},
{"module":"Math","type":"function","name":"tan/1","summary":"Returns the tangent of an angle in radians.","url":"modules/Math.html#tan-1"},
{"module":"Math","type":"function","name":"exp/1","summary":"Returns e raised to the given power.","url":"modules/Math.html#exp-1"},
{"module":"Math","type":"function","name":"exp2/1","summary":"Returns 2 raised to the given power.","url":"modules/Math.html#exp2-1"},
{"module":"Math","type":"function","name":"log/1","summary":"Returns the natural logarithm (base e) of a number.","url":"modules/Math.html#log-1"},
{"module":"Math","type":"function","name":"log2/1","summary":"Returns the base-2 logarithm of a number.","url":"modules/Math.html#log2-1"},
{"module":"Math","type":"function","name":"log10/1","summary":"Returns the base-10 logarithm of a number.","url":"modules/Math.html#log10-1"},
{"module":"String","type":"module","name":"String","summary":"Functions for working with UTF-8 encoded strings.","url":"modules/String.html"},
{"module":"String","type":"function","name":"length/1","summary":"Returns the byte length of a string.","url":"modules/String.html#length-1"},
{"module":"String","type":"function","name":"byte_at/2","summary":"Returns the byte at the given index as a single-character string.","url":"modules/String.html#byte_at-2"},
{"module":"String","type":"function","name":"contains/2","summary":"Returns `true` if `haystack` contains `needle` as a substring.","url":"modules/String.html#contains-2"},
{"module":"String","type":"function","name":"starts_with/2","summary":"Returns `true` if the string starts with the given prefix.","url":"modules/String.html#starts_with-2"},
{"module":"String","type":"function","name":"ends_with/2","summary":"Returns `true` if the string ends with the given suffix.","url":"modules/String.html#ends_with-2"},
{"module":"String","type":"function","name":"trim/1","summary":"Removes leading and trailing whitespace from a string.","url":"modules/String.html#trim-1"},
{"module":"String","type":"function","name":"slice/3","summary":"Returns a substring from `start` (inclusive) to `end` (exclusive).","url":"modules/String.html#slice-3"},
{"module":"String","type":"function","name":"to_atom/1","summary":"Converts a string to an atom, creating it if it doesn't exist.","url":"modules/String.html#to_atom-1"},
{"module":"String","type":"function","name":"to_existing_atom/1","summary":"Converts a string to an existing atom.","url":"modules/String.html#to_existing_atom-1"},
{"module":"String","type":"function","name":"upcase/1","summary":"Converts all characters to uppercase.","url":"modules/String.html#upcase-1"},
{"module":"String","type":"function","name":"downcase/1","summary":"Converts all characters to lowercase.","url":"modules/String.html#downcase-1"},
{"module":"String","type":"function","name":"reverse/1","summary":"Reverses the bytes of a string.","url":"modules/String.html#reverse-1"},
{"module":"String","type":"function","name":"replace/3","summary":"Replaces all occurrences of `pattern` with `replacement`.","url":"modules/String.html#replace-3"},
{"module":"String","type":"function","name":"index_of/2","summary":"Returns the index of the first occurrence of `needle` in the\nstring, or -1 if not found.","url":"modules/String.html#index_of-2"},
{"module":"String","type":"function","name":"pad_leading/3","summary":"Pads the string on the left to reach the target length using\nthe given padding character.","url":"modules/String.html#pad_leading-3"},
{"module":"String","type":"function","name":"pad_trailing/3","summary":"Pads the string on the right to reach the target length using\nthe given padding character.","url":"modules/String.html#pad_trailing-3"},
{"module":"String","type":"function","name":"repeat/2","summary":"Repeats a string the given number of times.","url":"modules/String.html#repeat-2"},
{"module":"String","type":"function","name":"to_integer/1","summary":"Parses a string into an integer.","url":"modules/String.html#to_integer-1"},
{"module":"String","type":"function","name":"to_float/1","summary":"Parses a string into a float.","url":"modules/String.html#to_float-1"},
{"module":"String","type":"function","name":"capitalize/1","summary":"Capitalizes the first character and lowercases the rest.","url":"modules/String.html#capitalize-1"},
{"module":"String","type":"function","name":"trim_leading/1","summary":"Removes leading whitespace from a string.","url":"modules/String.html#trim_leading-1"},
{"module":"String","type":"function","name":"trim_trailing/1","summary":"Removes trailing whitespace from a string.","url":"modules/String.html#trim_trailing-1"},
{"module":"String","type":"function","name":"count/2","summary":"Counts non-overlapping occurrences of a substring.","url":"modules/String.html#count-2"},
{"module":"System","type":"module","name":"System","summary":"Functions for interacting with the operating system.","url":"modules/System.html"},
{"module":"System","type":"function","name":"arg_count/0","summary":"Returns the number of command-line arguments passed to the program.","url":"modules/System.html#arg_count-0"},
{"module":"System","type":"function","name":"arg_at/1","summary":"Returns the command-line argument at the given index.","url":"modules/System.html#arg_at-1"},
{"module":"System","type":"function","name":"get_env/1","summary":"Reads an environment variable by name.","url":"modules/System.html#get_env-1"},
{"module":"System","type":"function","name":"get_build_opt/1","summary":"Reads a build-time option by name.","url":"modules/System.html#get_build_opt-1"},
{"module":"Zest","type":"module","name":"Zest","summary":"Zest test framework.","url":"modules/Zest.html"},
{"module":"Zest","type":"function","name":"assert/1","summary":"Asserts that a boolean value is `true`.","url":"modules/Zest.html#assert-1"},
{"module":"Zest","type":"function","name":"assert/2","summary":"Asserts that a boolean value is `true` with a custom message.","url":"modules/Zest.html#assert-2"},
{"module":"Zest","type":"function","name":"reject/1","summary":"Asserts that a boolean value is `false`.","url":"modules/Zest.html#reject-1"},
{"module":"Zest","type":"function","name":"reject/2","summary":"Asserts that a boolean value is `false` with a custom message.","url":"modules/Zest.html#reject-2"},
{"module":"Zest.Case","type":"module","name":"Zest.Case","summary":"Test case DSL for the Zest test framework.","url":"modules/Zest.Case.html"},
{"module":"Zest.Case","type":"function","name":"begin_test/0","summary":"Wraps `begin_test` for explicit use.","url":"modules/Zest.Case.html#begin_test-0"},
{"module":"Zest.Case","type":"function","name":"end_test/0","summary":"Wraps `end_test` for explicit use.","url":"modules/Zest.Case.html#end_test-0"},
{"module":"Zest.Case","type":"function","name":"print_result/0","summary":"Wraps `print_result` for explicit use.","url":"modules/Zest.Case.html#print_result-0"},
{"module":"Zest.Case","type":"function","name":"assert/1","summary":"Asserts that a boolean value is `true`.","url":"modules/Zest.Case.html#assert-1"},
{"module":"Zest.Case","type":"function","name":"reject/1","summary":"Asserts that a boolean value is `false`.","url":"modules/Zest.Case.html#reject-1"},
{"module":"Zest.Case","type":"macro","name":"describe/2","summary":"Groups related tests under a descriptive label.","url":"modules/Zest.Case.html#describe-2"},
{"module":"Zest.Case","type":"macro","name":"test/2","summary":"Defines a test case without context.","url":"modules/Zest.Case.html#test-2"},
{"module":"Zest.Case","type":"macro","name":"setup/1","summary":"Declares setup code that runs before each test with context.","url":"modules/Zest.Case.html#setup-1"},
{"module":"Zest.Case","type":"macro","name":"teardown/1","summary":"Declares teardown code that runs after each test.","url":"modules/Zest.Case.html#teardown-1"},
{"module":"Zest.Runner","type":"module","name":"Zest.Runner","summary":"Finalizes test execution and prints the summary report.","url":"modules/Zest.Runner.html"},
{"module":"Zest.Runner","type":"function","name":"configure/0","summary":"Parses `--seed` and `--timeout` from CLI arguments and applies\nthem to the test tracker.","url":"modules/Zest.Runner.html#configure-0"},
{"module":"Zest.Runner","type":"function","name":"run/0","summary":"Prints the test summary with counts and exits with a\nfailure code if any tests failed.","url":"modules/Zest.Runner.html#run-0"},
{"module":"Zest.Runner","type":"function","name":"parse_cli_args/2","summary":"Recursively scans CLI arguments for `--seed <value>` and\n`--timeout <milliseconds>`, applying each to the test tracker.","url":"modules/Zest.Runner.html#parse_cli_args-2"}
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
             item.module.toLowerCase().indexOf(q) !== -1 ||
             item.summary.toLowerCase().indexOf(q) !== -1;
    }).slice(0, 20);
    searchResults.innerHTML = matches.map(function(item, i) {
      return '<li data-url="' + basePath + item.url + '"' + (i === 0 ? ' class="selected"' : '') + '>' +
        '<div class="result-name">' + escapeHtml(item.name) + '</div>' +
        '<div class="result-module">' + escapeHtml(item.module) + ' &middot; ' + item.type + '</div>' +
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
