var ZAP_SEARCH_DATA = [
{"struct":"Atom","type":"struct","name":"Atom","summary":"Functions for working with atoms.","url":"structs/Atom.html"},
{"struct":"Bool","type":"struct","name":"Bool","summary":"Functions for working with boolean values.","url":"structs/Bool.html"},
{"struct":"Enum","type":"struct","name":"Enum","summary":"Functions for enumerating and transforming collections.","url":"structs/Enum.html"},
{"struct":"File","type":"struct","name":"File","summary":"Functions for reading and writing files.","url":"structs/File.html"},
{"struct":"Float","type":"struct","name":"Float","summary":"Functions for working with floating-point numbers.","url":"structs/Float.html"},
{"struct":"Function","type":"struct","name":"Function","summary":"Utilities for working with first-class function values.","url":"structs/Function.html"},
{"struct":"Integer","type":"struct","name":"Integer","summary":"Functions for working with integers.","url":"structs/Integer.html"},
{"struct":"IO","type":"struct","name":"IO","summary":"Functions for standard input/output operations.","url":"structs/IO.html"},
{"struct":"Kernel","type":"struct","name":"Kernel","summary":"The default struct imported into every Zap struct.","url":"structs/Kernel.html"},
{"struct":"List","type":"struct","name":"List","summary":"Functions for working with lists.","url":"structs/List.html"},
{"struct":"Map","type":"struct","name":"Map","summary":"Functions for working with maps.","url":"structs/Map.html"},
{"struct":"Markdown","type":"struct","name":"Markdown","summary":"Render the subset of Markdown the Zap documentation generator emits\ninto HTML strings.","url":"structs/Markdown.html"},
{"struct":"Math","type":"struct","name":"Math","summary":"Mathematical functions for numeric computation.","url":"structs/Math.html"},
{"struct":"Path","type":"struct","name":"Path","summary":"Functions for manipulating file system paths.","url":"structs/Path.html"},
{"struct":"Range","type":"struct","name":"Range","summary":"A range of integers with a start, end, and step.","url":"structs/Range.html"},
{"struct":"SourceGraph","type":"struct","name":"SourceGraph","summary":"Compile-time access to source-level declarations.","url":"structs/SourceGraph.html"},
{"struct":"String","type":"struct","name":"String","summary":"Functions for working with UTF-8 encoded strings.","url":"structs/String.html"},
{"struct":"Struct","type":"struct","name":"Struct","summary":"Compile-time helpers for reflected struct declarations.","url":"structs/Struct.html"},
{"struct":"System","type":"struct","name":"System","summary":"Functions for interacting with the operating system.","url":"structs/System.html"},
{"struct":"Zap.Dep","type":"struct","name":"Zap.Dep","summary":"Dependency declaration used by `Zap.Manifest`.","url":"structs/Zap.Dep.html"},
{"struct":"Zap.Doc","type":"struct","name":"Zap.Doc","summary":"Zap-side documentation generator.","url":"structs/Zap.Doc.html"},
{"struct":"Zap.Doc.Builder","type":"struct","name":"Zap.Doc.Builder","summary":"Compile-time entry point for the Zap-side documentation generator.","url":"structs/Zap.Doc.Builder.html"},
{"struct":"Zap.DocsRunner","type":"struct","name":"Zap.DocsRunner","summary":"Top-level entry point for `zap doc` against Zap's own stdlib.","url":"structs/Zap.DocsRunner.html"},
{"struct":"Zap.Env","type":"struct","name":"Zap.Env","summary":"Build environment passed to `Zap.Builder.manifest/1`.","url":"structs/Zap.Env.html"},
{"struct":"Zap.Manifest","type":"struct","name":"Zap.Manifest","summary":"Project manifest returned by `Zap.Builder.manifest/1`.","url":"structs/Zap.Manifest.html"},
{"struct":"Zest","type":"struct","name":"Zest","summary":"Zest test framework.","url":"structs/Zest.html"},
{"struct":"Zest.Case","type":"struct","name":"Zest.Case","summary":"Test case DSL for the Zest test framework.","url":"structs/Zest.Case.html"},
{"struct":"Zest.Runner","type":"struct","name":"Zest.Runner","summary":"Discovers and runs Zest test structs.","url":"structs/Zest.Runner.html"},
{"struct":"Arithmetic","type":"protocol","name":"Arithmetic","summary":"Protocol for types that support arithmetic operations.","url":"structs/Arithmetic.html"},
{"struct":"Comparator","type":"protocol","name":"Comparator","summary":"Protocol for types that support comparison.","url":"structs/Comparator.html"},
{"struct":"Concatenable","type":"protocol","name":"Concatenable","summary":"Protocol for types that support concatenation via the `<>` operator.","url":"structs/Concatenable.html"},
{"struct":"Enumerable","type":"protocol","name":"Enumerable","summary":"Protocol for types that can be iterated.","url":"structs/Enumerable.html"},
{"struct":"Membership","type":"protocol","name":"Membership","summary":"Protocol for types that can answer \"is value in this collection?\".","url":"structs/Membership.html"},
{"struct":"Stringable","type":"protocol","name":"Stringable","summary":"Protocol for types that can be converted to a `String`.","url":"structs/Stringable.html"},
{"struct":"Updatable","type":"protocol","name":"Updatable","summary":"Protocol for types that support functional update via `%{coll | key: value}`.","url":"structs/Updatable.html"},
{"struct":"IO.Mode","type":"union","name":"IO.Mode","summary":"Terminal input mode used by `IO.mode/1` and `IO.mode/2`.","url":"structs/IO.Mode.html"},
{"struct":"Atom","type":"function","name":"to_string/1","summary":"Converts an atom to its string representation (the name\nwithout the leading colon).","url":"structs/Atom.html#to_string-1"},
{"struct":"Bool","type":"function","name":"to_string/1","summary":"Converts a boolean to its string representation.","url":"structs/Bool.html#to_string-1"},
{"struct":"Bool","type":"function","name":"negate/1","summary":"Returns the logical negation of a boolean.","url":"structs/Bool.html#negate-1"},
{"struct":"Enum","type":"function","name":"to_list/1","summary":"Converts an enumerable collection to a list.","url":"structs/Enum.html#to_list-1"},
{"struct":"Enum","type":"function","name":"reverse/1","summary":"Reverses the order of elements in the enumerable collection.","url":"structs/Enum.html#reverse-1"},
{"struct":"Enum","type":"function","name":"each/2","summary":"Applies the callback to each element for side effects.","url":"structs/Enum.html#each-2"},
{"struct":"Enum","type":"function","name":"sort/2","summary":"Sorts the enumerable values using a comparator function.","url":"structs/Enum.html#sort-2"},
{"struct":"Enum","type":"function","name":"count/2","summary":"Counts elements for which the predicate returns true.","url":"structs/Enum.html#count-2"},
{"struct":"Enum","type":"function","name":"reject/2","summary":"Removes elements for which the predicate returns true.","url":"structs/Enum.html#reject-2"},
{"struct":"Enum","type":"function","name":"reduce/3","summary":"Folds the collection into a single value using an accumulator.","url":"structs/Enum.html#reduce-3"},
{"struct":"Enum","type":"function","name":"flat_map/2","summary":"Maps each element to a list and flattens the results\ninto a single list.","url":"structs/Enum.html#flat_map-2"},
{"struct":"Enum","type":"function","name":"take/2","summary":"Returns the first `count` elements from the enumerable collection.","url":"structs/Enum.html#take-2"},
{"struct":"Enum","type":"function","name":"at/3","summary":"Returns the element at the given zero-based index.","url":"structs/Enum.html#at-3"},
{"struct":"Enum","type":"function","name":"all?/2","summary":"Returns true if the predicate returns true for all elements.","url":"structs/Enum.html#all?-2"},
{"struct":"Enum","type":"function","name":"sum/1","summary":"Returns the sum of all elements.","url":"structs/Enum.html#sum-1"},
{"struct":"Enum","type":"function","name":"map/2","summary":"Transforms each element by applying the callback function.","url":"structs/Enum.html#map-2"},
{"struct":"Enum","type":"function","name":"member?/2","summary":"Returns true if the enumerable collection contains the given value.","url":"structs/Enum.html#member?-2"},
{"struct":"Enum","type":"function","name":"filter/2","summary":"Keeps only elements for which the predicate returns true.","url":"structs/Enum.html#filter-2"},
{"struct":"Enum","type":"function","name":"find/3","summary":"Returns the first element for which the predicate returns true.","url":"structs/Enum.html#find-3"},
{"struct":"Enum","type":"function","name":"product/1","summary":"Returns the product of all elements.","url":"structs/Enum.html#product-1"},
{"struct":"Enum","type":"function","name":"drop/2","summary":"Drops the first `count` elements from the enumerable collection\nand returns the remaining elements as a list.","url":"structs/Enum.html#drop-2"},
{"struct":"Enum","type":"function","name":"empty?/1","summary":"Returns true if the enumerable collection has no elements.","url":"structs/Enum.html#empty?-1"},
{"struct":"Enum","type":"function","name":"any?/2","summary":"Returns true if the predicate returns true for any element.","url":"structs/Enum.html#any?-2"},
{"struct":"Enum","type":"function","name":"uniq/1","summary":"Returns a new list with duplicate values removed.","url":"structs/Enum.html#uniq-1"},
{"struct":"Enum","type":"function","name":"concat/2","summary":"Concatenates two enumerable collections into a single list.","url":"structs/Enum.html#concat-2"},
{"struct":"Enum","type":"function","name":"min/1","summary":"Returns the minimum element.","url":"structs/Enum.html#min-1"},
{"struct":"Enum","type":"function","name":"max/1","summary":"Returns the maximum element.","url":"structs/Enum.html#max-1"},
{"struct":"File","type":"function","name":"write/2","summary":"Writes a string to a file, creating it if it doesn't exist\nand overwriting if it does.","url":"structs/File.html#write-2"},
{"struct":"File","type":"function","name":"rmdir/1","summary":"Removes an empty directory.","url":"structs/File.html#rmdir-1"},
{"struct":"File","type":"function","name":"cp/2","summary":"Copies a file.","url":"structs/File.html#cp-2"},
{"struct":"File","type":"function","name":"dir?/1","summary":"Returns true if the path is a directory.","url":"structs/File.html#dir?-1"},
{"struct":"File","type":"function","name":"read/1","summary":"Reads the entire contents of a file as a string.","url":"structs/File.html#read-1"},
{"struct":"File","type":"function","name":"rename/2","summary":"Renames or moves a file.","url":"structs/File.html#rename-2"},
{"struct":"File","type":"function","name":"regular?/1","summary":"Returns true if the path is a regular file.","url":"structs/File.html#regular?-1"},
{"struct":"File","type":"function","name":"mkdir/1","summary":"Creates a directory.","url":"structs/File.html#mkdir-1"},
{"struct":"File","type":"function","name":"rm/1","summary":"Deletes a file.","url":"structs/File.html#rm-1"},
{"struct":"File","type":"function","name":"exists?/1","summary":"Returns true if the file exists at the given path.","url":"structs/File.html#exists?-1"},
{"struct":"File","type":"function","name":"read!/1","summary":"Reads the entire contents of a file.","url":"structs/File.html#read!-1"},
{"struct":"Float","type":"function","name":"to_string/1","summary":"Converts a floating-point number to its string representation.","url":"structs/Float.html#to_string-1"},
{"struct":"Float","type":"function","name":"ceil_to_integer/1","summary":"Ceils a float and converts directly to an integer in one step.","url":"structs/Float.html#ceil_to_integer-1"},
{"struct":"Float","type":"function","name":"truncate/1","summary":"Truncates a float toward zero, removing the fractional part.","url":"structs/Float.html#truncate-1"},
{"struct":"Float","type":"function","name":"abs/1","summary":"Returns the absolute value of a float.","url":"structs/Float.html#abs-1"},
{"struct":"Float","type":"function","name":"clamp/3","summary":"Clamps a float to be within the given range.","url":"structs/Float.html#clamp-3"},
{"struct":"Float","type":"function","name":"round_to_integer/1","summary":"Rounds a float and converts directly to an integer in one step.","url":"structs/Float.html#round_to_integer-1"},
{"struct":"Float","type":"function","name":"ceil/1","summary":"Returns the smallest integer value greater than or equal to the given float.","url":"structs/Float.html#ceil-1"},
{"struct":"Float","type":"function","name":"max/2","summary":"Returns the larger of two floats.","url":"structs/Float.html#max-2"},
{"struct":"Float","type":"function","name":"round/1","summary":"Rounds a float to the nearest integer value, returned as a float.","url":"structs/Float.html#round-1"},
{"struct":"Float","type":"function","name":"to_integer/1","summary":"Converts a float to an integer by truncating toward zero.","url":"structs/Float.html#to_integer-1"},
{"struct":"Float","type":"function","name":"floor_to_integer/1","summary":"Floors a float and converts directly to an integer in one step.","url":"structs/Float.html#floor_to_integer-1"},
{"struct":"Float","type":"function","name":"floor/1","summary":"Returns the largest integer value less than or equal to the given float.","url":"structs/Float.html#floor-1"},
{"struct":"Float","type":"function","name":"min/2","summary":"Returns the smaller of two floats.","url":"structs/Float.html#min-2"},
{"struct":"Float","type":"function","name":"parse/1","summary":"Parses a string into a float.","url":"structs/Float.html#parse-1"},
{"struct":"Integer","type":"function","name":"to_string/1","summary":"Converts an integer to its string representation.","url":"structs/Integer.html#to_string-1"},
{"struct":"Integer","type":"function","name":"pow/2","summary":"Raises `base` to the power of `exponent`.","url":"structs/Integer.html#pow-2"},
{"struct":"Integer","type":"function","name":"bsl/2","summary":"Bitwise shift left.","url":"structs/Integer.html#bsl-2"},
{"struct":"Integer","type":"function","name":"abs/1","summary":"Returns the absolute value of an integer.","url":"structs/Integer.html#abs-1"},
{"struct":"Integer","type":"function","name":"bor/2","summary":"Bitwise OR of two integers.","url":"structs/Integer.html#bor-2"},
{"struct":"Integer","type":"function","name":"clamp/3","summary":"Clamps a value to be within the given range.","url":"structs/Integer.html#clamp-3"},
{"struct":"Integer","type":"function","name":"odd?/1","summary":"Returns true if the integer is odd.","url":"structs/Integer.html#odd?-1"},
{"struct":"Integer","type":"function","name":"lcm/2","summary":"Computes the least common multiple of two integers.","url":"structs/Integer.html#lcm-2"},
{"struct":"Integer","type":"function","name":"bit_reverse/1","summary":"Reverses all bits in the binary representation.","url":"structs/Integer.html#bit_reverse-1"},
{"struct":"Integer","type":"function","name":"even?/1","summary":"Returns true if the integer is even.","url":"structs/Integer.html#even?-1"},
{"struct":"Integer","type":"function","name":"min/2","summary":"Returns the smaller of two integers.","url":"structs/Integer.html#min-2"},
{"struct":"Integer","type":"function","name":"bnot/1","summary":"Bitwise NOT of an integer.","url":"structs/Integer.html#bnot-1"},
{"struct":"Integer","type":"function","name":"parse/1","summary":"Parses a string into an integer.","url":"structs/Integer.html#parse-1"},
{"struct":"Integer","type":"function","name":"add_sat/2","summary":"Adds two integers with saturation.","url":"structs/Integer.html#add_sat-2"},
{"struct":"Integer","type":"function","name":"digits/1","summary":"Returns the number of decimal digits in an integer.","url":"structs/Integer.html#digits-1"},
{"struct":"Integer","type":"function","name":"gcd/2","summary":"Computes the greatest common divisor of two integers.","url":"structs/Integer.html#gcd-2"},
{"struct":"Integer","type":"function","name":"sub_sat/2","summary":"Subtracts two integers with saturation.","url":"structs/Integer.html#sub_sat-2"},
{"struct":"Integer","type":"function","name":"band/2","summary":"Bitwise AND of two integers.","url":"structs/Integer.html#band-2"},
{"struct":"Integer","type":"function","name":"bxor/2","summary":"Bitwise XOR of two integers.","url":"structs/Integer.html#bxor-2"},
{"struct":"Integer","type":"function","name":"count_trailing_zeros/1","summary":"Returns the number of trailing zeros in the binary representation.","url":"structs/Integer.html#count_trailing_zeros-1"},
{"struct":"Integer","type":"function","name":"popcount/1","summary":"Returns the number of set bits in the binary representation.","url":"structs/Integer.html#popcount-1"},
{"struct":"Integer","type":"function","name":"sign/1","summary":"Returns the sign of an integer.","url":"structs/Integer.html#sign-1"},
{"struct":"Integer","type":"function","name":"max/2","summary":"Returns the larger of two integers.","url":"structs/Integer.html#max-2"},
{"struct":"Integer","type":"function","name":"to_float/1","summary":"Converts an integer to a 64-bit floating-point number.","url":"structs/Integer.html#to_float-1"},
{"struct":"Integer","type":"function","name":"count_leading_zeros/1","summary":"Returns the number of leading zeros in the binary representation.","url":"structs/Integer.html#count_leading_zeros-1"},
{"struct":"Integer","type":"function","name":"byte_swap/1","summary":"Reverses the byte order of an integer.","url":"structs/Integer.html#byte_swap-1"},
{"struct":"Integer","type":"function","name":"mul_sat/2","summary":"Multiplies two integers with saturation.","url":"structs/Integer.html#mul_sat-2"},
{"struct":"Integer","type":"function","name":"remainder/2","summary":"Computes the remainder of integer division.","url":"structs/Integer.html#remainder-2"},
{"struct":"Integer","type":"function","name":"count_digits/1","summary":"Counts decimal digits in an integer value.","url":"structs/Integer.html#count_digits-1"},
{"struct":"Integer","type":"function","name":"bsr/2","summary":"Bitwise shift right.","url":"structs/Integer.html#bsr-2"},
{"struct":"IO","type":"function","name":"puts/1","summary":"    Prints a value to standard output followed by a newline.","url":"structs/IO.html#puts-1"},
{"struct":"IO","type":"function","name":"get_char/0","summary":"Reads a single character from standard input.","url":"structs/IO.html#get_char-0"},
{"struct":"IO","type":"function","name":"mode/1","summary":"Switches the terminal input mode.","url":"structs/IO.html#mode-1"},
{"struct":"IO","type":"function","name":"try_get_char/0","summary":"Non-blocking read of a single character from standard input.","url":"structs/IO.html#try_get_char-0"},
{"struct":"IO","type":"function","name":"warn/1","summary":"Prints a message to standard error followed by a newline.","url":"structs/IO.html#warn-1"},
{"struct":"IO","type":"function","name":"print_str/1","summary":"Prints a value to standard output without a trailing newline.","url":"structs/IO.html#print_str-1"},
{"struct":"IO","type":"function","name":"gets/0","summary":"Reads a line from standard input.","url":"structs/IO.html#gets-0"},
{"struct":"IO","type":"function","name":"mode/2","summary":"Switches terminal mode, runs the callback, then restores\nnormal mode automatically.","url":"structs/IO.html#mode-2"},
{"struct":"Kernel","type":"function","name":"to_string/1","summary":"Converts any value to its string representation.","url":"structs/Kernel.html#to_string-1"},
{"struct":"Kernel","type":"function","name":"sleep/1","summary":"Suspends the current process for the given number of milliseconds.","url":"structs/Kernel.html#sleep-1"},
{"struct":"Kernel","type":"function","name":"is_nil?/1","summary":"Returns true if the value is nil.","url":"structs/Kernel.html#is_nil?-1"},
{"struct":"Kernel","type":"function","name":"is_float?/1","summary":"Returns true if the value is a float type (f16, f32, f64, f80, f128).","url":"structs/Kernel.html#is_float?-1"},
{"struct":"Kernel","type":"function","name":"is_boolean?/1","summary":"Returns true if the value is a boolean.","url":"structs/Kernel.html#is_boolean?-1"},
{"struct":"Kernel","type":"function","name":"is_tuple?/1","summary":"Returns true if the value is a tuple.","url":"structs/Kernel.html#is_tuple?-1"},
{"struct":"Kernel","type":"function","name":"is_number?/1","summary":"Returns true if the value is a number (integer or float).","url":"structs/Kernel.html#is_number?-1"},
{"struct":"Kernel","type":"function","name":"inspect/1","summary":"Print a value's string representation to stdout, followed by a newline.","url":"structs/Kernel.html#inspect-1"},
{"struct":"Kernel","type":"function","name":"raise/1","summary":"Raises a runtime error with the provided message.","url":"structs/Kernel.html#raise-1"},
{"struct":"Kernel","type":"function","name":"is_map?/1","summary":"Returns true if the value is a map.","url":"structs/Kernel.html#is_map?-1"},
{"struct":"Kernel","type":"function","name":"is_list?/1","summary":"Returns true if the value is a list.","url":"structs/Kernel.html#is_list?-1"},
{"struct":"Kernel","type":"function","name":"is_integer?/1","summary":"Returns true if the value is an integer type (i8, i16, i32, i64, i128, u8, u16, u32, u64, u128).","url":"structs/Kernel.html#is_integer?-1"},
{"struct":"Kernel","type":"function","name":"is_struct?/1","summary":"Returns true if the value is a struct.","url":"structs/Kernel.html#is_struct?-1"},
{"struct":"Kernel","type":"function","name":"is_string?/1","summary":"Returns true if the value is a string.","url":"structs/Kernel.html#is_string?-1"},
{"struct":"Kernel","type":"function","name":"is_atom?/1","summary":"Returns true if the value is an atom.","url":"structs/Kernel.html#is_atom?-1"},
{"struct":"List","type":"function","name":"contains?/2","summary":"Returns `true` if the list contains the given value.","url":"structs/List.html#contains?-2"},
{"struct":"List","type":"function","name":"append/2","summary":"Appends a value to the end of a list.","url":"structs/List.html#append-2"},
{"struct":"List","type":"function","name":"at/2","summary":"Returns the element at the given zero-based index.","url":"structs/List.html#at-2"},
{"struct":"List","type":"function","name":"reverse/1","summary":"Reverses the order of elements.","url":"structs/List.html#reverse-1"},
{"struct":"List","type":"function","name":"last!/1","summary":"Returns the last element of the list.","url":"structs/List.html#last!-1"},
{"struct":"List","type":"function","name":"drop/2","summary":"Drops the first `count` elements.","url":"structs/List.html#drop-2"},
{"struct":"List","type":"function","name":"empty?/1","summary":"Returns `true` if the list has no elements.","url":"structs/List.html#empty?-1"},
{"struct":"List","type":"function","name":"last/1","summary":"Returns the last element of the list.","url":"structs/List.html#last-1"},
{"struct":"List","type":"function","name":"take/2","summary":"Takes the first `count` elements.","url":"structs/List.html#take-2"},
{"struct":"List","type":"function","name":"uniq/1","summary":"Returns a new list with duplicates removed.","url":"structs/List.html#uniq-1"},
{"struct":"List","type":"function","name":"length/1","summary":"Returns the number of elements in the list.","url":"structs/List.html#length-1"},
{"struct":"List","type":"function","name":"concat/2","summary":"Concatenates two lists.","url":"structs/List.html#concat-2"},
{"struct":"List","type":"function","name":"tail/1","summary":"Returns the list without its first element.","url":"structs/List.html#tail-1"},
{"struct":"List","type":"function","name":"head!/1","summary":"Returns the first element of the list.","url":"structs/List.html#head!-1"},
{"struct":"List","type":"function","name":"at!/2","summary":"Returns the element at the given zero-based index.","url":"structs/List.html#at!-2"},
{"struct":"List","type":"function","name":"prepend/2","summary":"Prepends a value to the front of a list.","url":"structs/List.html#prepend-2"},
{"struct":"List","type":"function","name":"head/1","summary":"Returns the first element of the list.","url":"structs/List.html#head-1"},
{"struct":"Map","type":"function","name":"values/1","summary":"Returns a list of all values in the map.","url":"structs/Map.html#values-1"},
{"struct":"Map","type":"function","name":"has_key?/2","summary":"Returns `true` if the map contains the given key.","url":"structs/Map.html#has_key?-2"},
{"struct":"Map","type":"function","name":"put/3","summary":"Returns a new map with the key set to the given value.","url":"structs/Map.html#put-3"},
{"struct":"Map","type":"function","name":"get/3","summary":"Returns the value for the given key, or the default if\nthe key is not found.","url":"structs/Map.html#get-3"},
{"struct":"Map","type":"function","name":"has_key/2","summary":"Returns `true` if the map contains the given key.","url":"structs/Map.html#has_key-2"},
{"struct":"Map","type":"function","name":"get!/3","summary":"Returns the value for the given key.","url":"structs/Map.html#get!-3"},
{"struct":"Map","type":"function","name":"empty?/1","summary":"Returns `true` if the map has no entries.","url":"structs/Map.html#empty?-1"},
{"struct":"Map","type":"function","name":"delete/2","summary":"Returns a new map with the given key removed.","url":"structs/Map.html#delete-2"},
{"struct":"Map","type":"function","name":"merge/2","summary":"Merges two maps.","url":"structs/Map.html#merge-2"},
{"struct":"Map","type":"function","name":"keys/1","summary":"Returns a list of all keys in the map.","url":"structs/Map.html#keys-1"},
{"struct":"Map","type":"function","name":"size/1","summary":"Returns the number of entries in the map.","url":"structs/Map.html#size-1"},
{"struct":"Markdown","type":"function","name":"render_line/5","summary":"","url":"structs/Markdown.html#render_line-5"},
{"struct":"Markdown","type":"function","name":"open_code_block/4","summary":"","url":"structs/Markdown.html#open_code_block-4"},
{"struct":"Markdown","type":"function","name":"is_atom_start_byte?/1","summary":"","url":"structs/Markdown.html#is_atom_start_byte?-1"},
{"struct":"Markdown","type":"function","name":"is_digit_byte?/1","summary":"","url":"structs/Markdown.html#is_digit_byte?-1"},
{"struct":"Markdown","type":"function","name":"escape_html/1","summary":"","url":"structs/Markdown.html#escape_html-1"},
{"struct":"Markdown","type":"function","name":"is_alpha_byte?/1","summary":"","url":"structs/Markdown.html#is_alpha_byte?-1"},
{"struct":"Markdown","type":"function","name":"scan_atom_end/3","summary":"","url":"structs/Markdown.html#scan_atom_end-3"},
{"struct":"Markdown","type":"function","name":"is_ident_continue?/1","summary":"","url":"structs/Markdown.html#is_ident_continue?-1"},
{"struct":"Markdown","type":"function","name":"render_code_line/2","summary":"Render a single line of code, applying Zap syntax highlighting\nwhen the surrounding fenced block is tagged `language-zap`,\n`zap`, `elixir`, or has no tag (the doc generator's default).","url":"structs/Markdown.html#render_code_line-2"},
{"struct":"Markdown","type":"function","name":"trim_each/2","summary":"","url":"structs/Markdown.html#trim_each-2"},
{"struct":"Markdown","type":"function","name":"to_html/1","summary":"Render `markdown` as HTML.","url":"structs/Markdown.html#to_html-1"},
{"struct":"Markdown","type":"function","name":"inline_try_link_paren/5","summary":"","url":"structs/Markdown.html#inline_try_link_paren-5"},
{"struct":"Markdown","type":"function","name":"highlight_walk/4","summary":"","url":"structs/Markdown.html#highlight_walk-4"},
{"struct":"Markdown","type":"function","name":"strip_indent4/1","summary":"","url":"structs/Markdown.html#strip_indent4-1"},
{"struct":"Markdown","type":"function","name":"two_char_op?/2","summary":"","url":"structs/Markdown.html#two_char_op?-2"},
{"struct":"Markdown","type":"function","name":"highlight_number/4","summary":"","url":"structs/Markdown.html#highlight_number-4"},
{"struct":"Markdown","type":"function","name":"is_table_separator?/1","summary":"","url":"structs/Markdown.html#is_table_separator?-1"},
{"struct":"Markdown","type":"function","name":"highlight_zap_line/1","summary":"Highlight one line of Zap source as HTML, wrapping classified\ntokens in `<span class=\"hl-...\">` so the bundled stylesheet can\ncolor them.","url":"structs/Markdown.html#highlight_zap_line-1"},
{"struct":"Markdown","type":"function","name":"escape_one_no_quote/1","summary":"","url":"structs/Markdown.html#escape_one_no_quote-1"},
{"struct":"Markdown","type":"function","name":"classify_after_close/4","summary":"Continue line classification after a code-block close.","url":"structs/Markdown.html#classify_after_close-4"},
{"struct":"Markdown","type":"function","name":"render_paragraph_line/4","summary":"","url":"structs/Markdown.html#render_paragraph_line-4"},
{"struct":"Markdown","type":"function","name":"find_link_url_close/3","summary":"","url":"structs/Markdown.html#find_link_url_close-3"},
{"struct":"Markdown","type":"function","name":"inline_try_link/5","summary":"When the cursor sits on `[`, scan ahead for a `](...)` close to\nclassify this as a Markdown inline link and emit `<a href=\"url\">text</a>`.","url":"structs/Markdown.html#inline_try_link-5"},
{"struct":"Markdown","type":"function","name":"zap_lang?/1","summary":"","url":"structs/Markdown.html#zap_lang?-1"},
{"struct":"Markdown","type":"function","name":"two_char_op_compare?/2","summary":"","url":"structs/Markdown.html#two_char_op_compare?-2"},
{"struct":"Markdown","type":"function","name":"is_table_header?/2","summary":"A pipe-table header is detected by the next line being a separator\nrow (`| --- | --- |`).","url":"structs/Markdown.html#is_table_header?-2"},
{"struct":"Markdown","type":"function","name":"classify_line/4","summary":"Recognize the line's block kind for non-code modes and dispatch.","url":"structs/Markdown.html#classify_line-4"},
{"struct":"Markdown","type":"function","name":"render_table_cells/3","summary":"","url":"structs/Markdown.html#render_table_cells-3"},
{"struct":"Markdown","type":"function","name":"render_lines/4","summary":"Walk the input line by line, tracking which block construct is\ncurrently open and emitting the right close/open tags as the line\nshape changes.","url":"structs/Markdown.html#render_lines-4"},
{"struct":"Markdown","type":"function","name":"is_upper_byte?/1","summary":"","url":"structs/Markdown.html#is_upper_byte?-1"},
{"struct":"Markdown","type":"function","name":"is_indented_code_line?/1","summary":"A line qualifies as part of an indented code block when its first\nfour characters are spaces (or a tab).","url":"structs/Markdown.html#is_indented_code_line?-1"},
{"struct":"Markdown","type":"function","name":"render_heading/2","summary":"","url":"structs/Markdown.html#render_heading-2"},
{"struct":"Markdown","type":"function","name":"is_list_item?/1","summary":"","url":"structs/Markdown.html#is_list_item?-1"},
{"struct":"Markdown","type":"function","name":"list_item_text/1","summary":"","url":"structs/Markdown.html#list_item_text-1"},
{"struct":"Markdown","type":"function","name":"is_pipe_row?/1","summary":"","url":"structs/Markdown.html#is_pipe_row?-1"},
{"struct":"Markdown","type":"function","name":"escape_one/1","summary":"","url":"structs/Markdown.html#escape_one-1"},
{"struct":"Markdown","type":"function","name":"render_list_item/4","summary":"","url":"structs/Markdown.html#render_list_item-4"},
{"struct":"Markdown","type":"function","name":"escape_html_no_quotes/1","summary":"HTML-escape only `&`, `<`, `>` — leave `\"` alone.","url":"structs/Markdown.html#escape_html_no_quotes-1"},
{"struct":"Markdown","type":"function","name":"is_zap_int_type?/1","summary":"","url":"structs/Markdown.html#is_zap_int_type?-1"},
{"struct":"Markdown","type":"function","name":"scan_number_end/3","summary":"","url":"structs/Markdown.html#scan_number_end-3"},
{"struct":"Markdown","type":"function","name":"find_link_text_close/3","summary":"","url":"structs/Markdown.html#find_link_text_close-3"},
{"struct":"Markdown","type":"function","name":"single_char_op?/1","summary":"","url":"structs/Markdown.html#single_char_op?-1"},
{"struct":"Markdown","type":"function","name":"escape_inline/1","summary":"","url":"structs/Markdown.html#escape_inline-1"},
{"struct":"Markdown","type":"function","name":"inline_walk/5","summary":"","url":"structs/Markdown.html#inline_walk-5"},
{"struct":"Markdown","type":"function","name":"highlight_op_or_passthrough/4","summary":"","url":"structs/Markdown.html#highlight_op_or_passthrough-4"},
{"struct":"Markdown","type":"function","name":"escape_no_quotes_walk/4","summary":"","url":"structs/Markdown.html#escape_no_quotes_walk-4"},
{"struct":"Markdown","type":"function","name":"highlight_word/4","summary":"","url":"structs/Markdown.html#highlight_word-4"},
{"struct":"Markdown","type":"function","name":"is_zap_float_type?/1","summary":"","url":"structs/Markdown.html#is_zap_float_type?-1"},
{"struct":"Markdown","type":"function","name":"open_table/4","summary":"","url":"structs/Markdown.html#open_table-4"},
{"struct":"Markdown","type":"function","name":"is_zap_keyword_misc?/1","summary":"","url":"structs/Markdown.html#is_zap_keyword_misc?-1"},
{"struct":"Markdown","type":"function","name":"strip_pipes/1","summary":"","url":"structs/Markdown.html#strip_pipes-1"},
{"struct":"Markdown","type":"function","name":"parse_pipe_cells/1","summary":"Split a pipe-row into its cells, dropping the leading and trailing\npipe characters.","url":"structs/Markdown.html#parse_pipe_cells-1"},
{"struct":"Markdown","type":"function","name":"escape_chars/4","summary":"","url":"structs/Markdown.html#escape_chars-4"},
{"struct":"Markdown","type":"function","name":"highlight_atom/4","summary":"","url":"structs/Markdown.html#highlight_atom-4"},
{"struct":"Markdown","type":"function","name":"is_lower_byte?/1","summary":"","url":"structs/Markdown.html#is_lower_byte?-1"},
{"struct":"Markdown","type":"function","name":"close_block/2","summary":"","url":"structs/Markdown.html#close_block-2"},
{"struct":"Markdown","type":"function","name":"is_zap_primitive_type?/1","summary":"Recognise the small set of words the legacy syntax highlighter\nclassified as primitive types — the integer / float widths plus\n`Bool`, `String`, `Atom`, `Nil`, `Never`, and `Expr`.","url":"structs/Markdown.html#is_zap_primitive_type?-1"},
{"struct":"Markdown","type":"function","name":"is_zap_keyword?/1","summary":"","url":"structs/Markdown.html#is_zap_keyword?-1"},
{"struct":"Markdown","type":"function","name":"find_string_end/3","summary":"","url":"structs/Markdown.html#find_string_end-3"},
{"struct":"Markdown","type":"function","name":"render_inline/1","summary":"Render a single inline run: HTML-escape body text, but recognize\nbacktick-delimited code spans and wrap them as `<code>`.","url":"structs/Markdown.html#render_inline-1"},
{"struct":"Markdown","type":"function","name":"render_table_row/2","summary":"","url":"structs/Markdown.html#render_table_row-2"},
{"struct":"Markdown","type":"function","name":"highlight_string/4","summary":"","url":"structs/Markdown.html#highlight_string-4"},
{"struct":"Markdown","type":"function","name":"is_zap_keyword_more?/1","summary":"","url":"structs/Markdown.html#is_zap_keyword_more?-1"},
{"struct":"Markdown","type":"function","name":"is_blank_line?/1","summary":"","url":"structs/Markdown.html#is_blank_line?-1"},
{"struct":"Markdown","type":"function","name":"is_zap_builtin?/1","summary":"","url":"structs/Markdown.html#is_zap_builtin?-1"},
{"struct":"Markdown","type":"function","name":"scan_word_end/3","summary":"","url":"structs/Markdown.html#scan_word_end-3"},
{"struct":"Markdown","type":"function","name":"two_char_op_more?/2","summary":"","url":"structs/Markdown.html#two_char_op_more?-2"},
{"struct":"Markdown","type":"function","name":"highlight_after_atom_check/5","summary":"","url":"structs/Markdown.html#highlight_after_atom_check-5"},
{"struct":"Math","type":"function","name":"tan/1","summary":"Returns the tangent of an angle in radians.","url":"structs/Math.html#tan-1"},
{"struct":"Math","type":"function","name":"log2/1","summary":"Returns the base-2 logarithm of a number.","url":"structs/Math.html#log2-1"},
{"struct":"Math","type":"function","name":"log10/1","summary":"Returns the base-10 logarithm of a number.","url":"structs/Math.html#log10-1"},
{"struct":"Math","type":"function","name":"sin/1","summary":"Returns the sine of an angle in radians.","url":"structs/Math.html#sin-1"},
{"struct":"Math","type":"function","name":"pi/0","summary":"Returns the ratio of a circle's circumference to its diameter.","url":"structs/Math.html#pi-0"},
{"struct":"Math","type":"function","name":"exp2/1","summary":"Returns 2 raised to the given power.","url":"structs/Math.html#exp2-1"},
{"struct":"Math","type":"function","name":"e/0","summary":"Returns Euler's number, the base of natural logarithms.","url":"structs/Math.html#e-0"},
{"struct":"Math","type":"function","name":"sqrt/1","summary":"Returns the square root of a number.","url":"structs/Math.html#sqrt-1"},
{"struct":"Math","type":"function","name":"cos/1","summary":"Returns the cosine of an angle in radians.","url":"structs/Math.html#cos-1"},
{"struct":"Math","type":"function","name":"exp/1","summary":"Returns e raised to the given power.","url":"structs/Math.html#exp-1"},
{"struct":"Math","type":"function","name":"log/1","summary":"Returns the natural logarithm (base e) of a number.","url":"structs/Math.html#log-1"},
{"struct":"Path","type":"function","name":"extname/1","summary":"Returns the file extension including the dot.","url":"structs/Path.html#extname-1"},
{"struct":"Path","type":"function","name":"join/2","summary":"Joins two path segments with a separator.","url":"structs/Path.html#join-2"},
{"struct":"Path","type":"function","name":"basename/1","summary":"Returns the last component of a path.","url":"structs/Path.html#basename-1"},
{"struct":"Path","type":"function","name":"glob/1","summary":"Returns paths matching a glob pattern as a sorted list of strings.","url":"structs/Path.html#glob-1"},
{"struct":"Path","type":"function","name":"dirname/1","summary":"Returns the directory component of a path.","url":"structs/Path.html#dirname-1"},
{"struct":"String","type":"function","name":"contains?/2","summary":"Returns `true` if `haystack` contains `needle` as a substring.","url":"structs/String.html#contains?-2"},
{"struct":"String","type":"function","name":"reverse/1","summary":"Reverses the bytes of a string.","url":"structs/String.html#reverse-1"},
{"struct":"String","type":"function","name":"index_of/2","summary":"Returns the index of the first occurrence of `needle` in the\nstring, or -1 if not found.","url":"structs/String.html#index_of-2"},
{"struct":"String","type":"function","name":"trim_trailing/1","summary":"Removes trailing whitespace from a string.","url":"structs/String.html#trim_trailing-1"},
{"struct":"String","type":"function","name":"join/2","summary":"Joins a list of strings with a separator.","url":"structs/String.html#join-2"},
{"struct":"String","type":"function","name":"to_existing_atom/1","summary":"Converts a string to an existing atom.","url":"structs/String.html#to_existing_atom-1"},
{"struct":"String","type":"function","name":"slice/3","summary":"Returns a substring from `start` (inclusive) to `end` (exclusive).","url":"structs/String.html#slice-3"},
{"struct":"String","type":"function","name":"count/2","summary":"Counts non-overlapping occurrences of a substring.","url":"structs/String.html#count-2"},
{"struct":"String","type":"function","name":"starts_with?/2","summary":"Returns `true` if the string starts with the given prefix.","url":"structs/String.html#starts_with?-2"},
{"struct":"String","type":"function","name":"downcase/1","summary":"Converts all characters to lowercase.","url":"structs/String.html#downcase-1"},
{"struct":"String","type":"function","name":"to_integer/1","summary":"Parses a string into an integer.","url":"structs/String.html#to_integer-1"},
{"struct":"String","type":"function","name":"trim_leading/1","summary":"Removes leading whitespace from a string.","url":"structs/String.html#trim_leading-1"},
{"struct":"String","type":"function","name":"replace/3","summary":"Replaces all occurrences of `pattern` with `replacement`.","url":"structs/String.html#replace-3"},
{"struct":"String","type":"function","name":"ends_with?/2","summary":"Returns `true` if the string ends with the given suffix.","url":"structs/String.html#ends_with?-2"},
{"struct":"String","type":"function","name":"trim/1","summary":"Removes leading and trailing whitespace from a string.","url":"structs/String.html#trim-1"},
{"struct":"String","type":"function","name":"upcase/1","summary":"Converts all characters to uppercase.","url":"structs/String.html#upcase-1"},
{"struct":"String","type":"function","name":"repeat/2","summary":"Repeats a string the given number of times.","url":"structs/String.html#repeat-2"},
{"struct":"String","type":"function","name":"pad_trailing/3","summary":"Pads the string on the right to reach the target length using\nthe given padding character.","url":"structs/String.html#pad_trailing-3"},
{"struct":"String","type":"function","name":"length/1","summary":"Returns the byte length of a string.","url":"structs/String.html#length-1"},
{"struct":"String","type":"function","name":"to_float/1","summary":"Parses a string into a float.","url":"structs/String.html#to_float-1"},
{"struct":"String","type":"function","name":"pad_leading/3","summary":"Pads the string on the left to reach the target length using\nthe given padding character.","url":"structs/String.html#pad_leading-3"},
{"struct":"String","type":"function","name":"byte_at/2","summary":"Returns the byte at the given index as a single-character string.","url":"structs/String.html#byte_at-2"},
{"struct":"String","type":"function","name":"capitalize/1","summary":"Capitalizes the first character and lowercases the rest.","url":"structs/String.html#capitalize-1"},
{"struct":"String","type":"function","name":"to_atom/1","summary":"Converts a string to an atom, creating it if it doesn't exist.","url":"structs/String.html#to_atom-1"},
{"struct":"String","type":"function","name":"split/2","summary":"Splits a string by a delimiter, returning a list of strings.","url":"structs/String.html#split-2"},
{"struct":"System","type":"function","name":"arg_at/1","summary":"Returns the command-line argument at the given index.","url":"structs/System.html#arg_at-1"},
{"struct":"System","type":"function","name":"arg_count/0","summary":"Returns the number of command-line arguments passed to the program.","url":"structs/System.html#arg_count-0"},
{"struct":"System","type":"function","name":"get_env/1","summary":"Reads an environment variable by name.","url":"structs/System.html#get_env-1"},
{"struct":"System","type":"function","name":"cwd/0","summary":"Returns the current working directory.","url":"structs/System.html#cwd-0"},
{"struct":"System","type":"function","name":"get_build_opt/1","summary":"Reads a build-time option by name.","url":"structs/System.html#get_build_opt-1"},
{"struct":"Zap.Doc","type":"function","name":"implements_link/1","summary":"","url":"structs/Zap.Doc.html#implements_link-1"},
{"struct":"Zap.Doc","type":"function","name":"topbar/4","summary":"Render the sticky top-bar — brand cluster on the left, command-K\nsearch trigger in the center, theme toggle + GitHub link cluster\non the right.","url":"structs/Zap.Doc.html#topbar-4"},
{"struct":"Zap.Doc","type":"function","name":"layout/3","summary":"","url":"structs/Zap.Doc.html#layout-3"},
{"struct":"Zap.Doc","type":"function","name":"render_toc_items/2","summary":"","url":"structs/Zap.Doc.html#render_toc_items-2"},
{"struct":"Zap.Doc","type":"function","name":"filter_members_walk/3","summary":"","url":"structs/Zap.Doc.html#filter_members_walk-3"},
{"struct":"Zap.Doc","type":"function","name":"render_signature_return_trimmed/1","summary":"","url":"structs/Zap.Doc.html#render_signature_return_trimmed-1"},
{"struct":"Zap.Doc","type":"function","name":"function_header/3","summary":"","url":"structs/Zap.Doc.html#function_header-3"},
{"struct":"Zap.Doc","type":"function","name":"list_concat_strings/2","summary":"","url":"structs/Zap.Doc.html#list_concat_strings-2"},
{"struct":"Zap.Doc","type":"function","name":"kind_category_label/1","summary":"Map a kind atom to its sidebar group label.","url":"structs/Zap.Doc.html#kind_category_label-1"},
{"struct":"Zap.Doc","type":"function","name":"summary_table/3","summary":"Wrap a sequence of pre-rendered summary rows in the\n`<h2>` + `<table class=\"summary\">` shell.","url":"structs/Zap.Doc.html#summary_table-3"},
{"struct":"Zap.Doc","type":"function","name":"render_typed_param/2","summary":"","url":"structs/Zap.Doc.html#render_typed_param-2"},
{"struct":"Zap.Doc","type":"function","name":"sort_names_alpha/1","summary":"Recursively pull `:name` from each summary, accumulating into a\nlist of strings.","url":"structs/Zap.Doc.html#sort_names_alpha-1"},
{"struct":"Zap.Doc","type":"function","name":"insert_member_walk/3","summary":"","url":"structs/Zap.Doc.html#insert_member_walk-3"},
{"struct":"Zap.Doc","type":"function","name":"file_eq_or_gt?/3","summary":"","url":"structs/Zap.Doc.html#file_eq_or_gt?-3"},
{"struct":"Zap.Doc","type":"function","name":"compose_member_detail/9","summary":"","url":"structs/Zap.Doc.html#compose_member_detail-9"},
{"struct":"Zap.Doc","type":"function","name":"strip_dot_slash/1","summary":"Strip a leading `./` prefix that the macro-eval source-id resolver\nsometimes attaches to relative paths.","url":"structs/Zap.Doc.html#strip_dot_slash-1"},
{"struct":"Zap.Doc","type":"function","name":"escape_one_lt/1","summary":"","url":"structs/Zap.Doc.html#escape_one_lt-1"},
{"struct":"Zap.Doc","type":"function","name":"render_index_links/2","summary":"","url":"structs/Zap.Doc.html#render_index_links-2"},
{"struct":"Zap.Doc","type":"function","name":"scan_top_level_if/4","summary":"","url":"structs/Zap.Doc.html#scan_top_level_if-4"},
{"struct":"Zap.Doc","type":"function","name":"collect_implemented_protocols/3","summary":"Walk the flat impl manifest and collect protocol names whose\n`:target` matches `module_name`.","url":"structs/Zap.Doc.html#collect_implemented_protocols-3"},
{"struct":"Zap.Doc","type":"function","name":"escape_one/1","summary":"","url":"structs/Zap.Doc.html#escape_one-1"},
{"struct":"Zap.Doc","type":"function","name":"line_lt_or_eq?/4","summary":"","url":"structs/Zap.Doc.html#line_lt_or_eq?-4"},
{"struct":"Zap.Doc","type":"function","name":"render_return_type/1","summary":"","url":"structs/Zap.Doc.html#render_return_type-1"},
{"struct":"Zap.Doc","type":"function","name":"escape_one_quote/1","summary":"","url":"structs/Zap.Doc.html#escape_one_quote-1"},
{"struct":"Zap.Doc","type":"function","name":"is_if_at?/3","summary":"","url":"structs/Zap.Doc.html#is_if_at?-3"},
{"struct":"Zap.Doc","type":"function","name":"topbar_right/1","summary":"","url":"structs/Zap.Doc.html#topbar_right-1"},
{"struct":"Zap.Doc","type":"function","name":"render_arrow_segment/1","summary":"","url":"structs/Zap.Doc.html#render_arrow_segment-1"},
{"struct":"Zap.Doc","type":"function","name":"split_top_level_commas/1","summary":"Split a comma-separated string at top-level commas, respecting\nparen/bracket/brace depth.","url":"structs/Zap.Doc.html#split_top_level_commas-1"},
{"struct":"Zap.Doc","type":"function","name":"filter_members_by_module/2","summary":"Filter a flat function/macro manifest down to only the entries\nwhose `:module` field equals `module_name`.","url":"structs/Zap.Doc.html#filter_members_by_module-2"},
{"struct":"Zap.Doc","type":"function","name":"render_signatures_walk/2","summary":"","url":"structs/Zap.Doc.html#render_signatures_walk-2"},
{"struct":"Zap.Doc","type":"function","name":"render_struct_card/1","summary":"","url":"structs/Zap.Doc.html#render_struct_card-1"},
{"struct":"Zap.Doc","type":"function","name":"sort_members_walk/2","summary":"","url":"structs/Zap.Doc.html#sort_members_walk-2"},
{"struct":"Zap.Doc","type":"function","name":"sort_names_walk/2","summary":"","url":"structs/Zap.Doc.html#sort_names_walk-2"},
{"struct":"Zap.Doc","type":"function","name":"sidebar_item/3","summary":"Render a complete per-function detail block — the section that\nappears under \"Function Details\" on each module page.","url":"structs/Zap.Doc.html#sidebar_item-3"},
{"struct":"Zap.Doc","type":"function","name":"member_detail_for_module/5","summary":"","url":"structs/Zap.Doc.html#member_detail_for_module-5"},
{"struct":"Zap.Doc","type":"function","name":"rich_signature_assemble/3","summary":"","url":"structs/Zap.Doc.html#rich_signature_assemble-3"},
{"struct":"Zap.Doc","type":"function","name":"toc_item/2","summary":"Render a single anchor in the right-rail \"On this page\" list.","url":"structs/Zap.Doc.html#toc_item-2"},
{"struct":"Zap.Doc","type":"function","name":"first_sentence_walk/3","summary":"","url":"structs/Zap.Doc.html#first_sentence_walk-3"},
{"struct":"Zap.Doc","type":"function","name":"render_signature_params/1","summary":"Render the parameter list of a signature.","url":"structs/Zap.Doc.html#render_signature_params-1"},
{"struct":"Zap.Doc","type":"function","name":"render_search_index/5","summary":"Compose the full search-index JSON document.","url":"structs/Zap.Doc.html#render_search_index-5"},
{"struct":"Zap.Doc","type":"function","name":"render_index_page/8","summary":"Compose the docs landing page.","url":"structs/Zap.Doc.html#render_index_page-8"},
{"struct":"Zap.Doc","type":"function","name":"render_struct_search_entries/3","summary":"Walk a list of struct/protocol/union summaries, accumulating JSON search entries.","url":"structs/Zap.Doc.html#render_struct_search_entries-3"},
{"struct":"Zap.Doc","type":"function","name":"topbar_left/3","summary":"","url":"structs/Zap.Doc.html#topbar_left-3"},
{"struct":"Zap.Doc","type":"function","name":"render_signatures/1","summary":"Split a newline-joined block of bare signature strings (the\n`:signatures_joined` value baked at compile time by\n`Zap.Doc.Builder`) and render each one through the rich-signature\nrenderer.","url":"structs/Zap.Doc.html#render_signatures-1"},
{"struct":"Zap.Doc","type":"function","name":"list_concat_two/2","summary":"","url":"structs/Zap.Doc.html#list_concat_two-2"},
{"struct":"Zap.Doc","type":"function","name":"string_lt_walk?/5","summary":"","url":"structs/Zap.Doc.html#string_lt_walk?-5"},
{"struct":"Zap.Doc","type":"function","name":"page_open/3","summary":"Open the HTML document — `<!DOCTYPE>`, `<html>`, `<head>` (CSS\nlink, title, base-path meta), and `<body>`.","url":"structs/Zap.Doc.html#page_open-3"},
{"struct":"Zap.Doc","type":"function","name":"summary_row/3","summary":"Render the header row at the top of a function or macro detail\nblock: an `<h3>` with the qualified name and a muted `/arity`\nspan, a small kind badge (`fn` for functions, `macro` for\nmacros), a flex-spacer, and a `#`-prefixed anchor link that\ndeep-links back to this entry.","url":"structs/Zap.Doc.html#summary_row-3"},
{"struct":"Zap.Doc","type":"function","name":"render_variant_rows/3","summary":"","url":"structs/Zap.Doc.html#render_variant_rows-3"},
{"struct":"Zap.Doc","type":"function","name":"render_module_member_rows/3","summary":"Render summary rows for the subset of `members` whose `:module`\nfield equals `module_name`.","url":"structs/Zap.Doc.html#render_module_member_rows-3"},
{"struct":"Zap.Doc","type":"function","name":"escape_one_gt/1","summary":"","url":"structs/Zap.Doc.html#escape_one_gt-1"},
{"struct":"Zap.Doc","type":"function","name":"kind_category_label_union/1","summary":"","url":"structs/Zap.Doc.html#kind_category_label_union-1"},
{"struct":"Zap.Doc","type":"function","name":"render_signature_params_walk/3","summary":"","url":"structs/Zap.Doc.html#render_signature_params_walk-3"},
{"struct":"Zap.Doc","type":"function","name":"rich_signature_with_open/2","summary":"","url":"structs/Zap.Doc.html#rich_signature_with_open-2"},
{"struct":"Zap.Doc","type":"function","name":"member_lt?/2","summary":"Order two member maps for the per-page table sort.","url":"structs/Zap.Doc.html#member_lt?-2"},
{"struct":"Zap.Doc","type":"function","name":"render_default_landing/4","summary":"Default landing-page body used when no `landing_md` is supplied.","url":"structs/Zap.Doc.html#render_default_landing-4"},
{"struct":"Zap.Doc","type":"function","name":"render_summary_page/13","summary":"Compose a complete HTML page for a single module summary.","url":"structs/Zap.Doc.html#render_summary_page-13"},
{"struct":"Zap.Doc","type":"function","name":"render_right_rail/2","summary":"Render the right-rail \"On this page\" TOC from the sorted function\nand macro lists.","url":"structs/Zap.Doc.html#render_right_rail-2"},
{"struct":"Zap.Doc","type":"function","name":"render_summary_rows_from_members/2","summary":"Render summary table rows from a list of member maps already\nfiltered to one module's entries.","url":"structs/Zap.Doc.html#render_summary_rows_from_members-2"},
{"struct":"Zap.Doc","type":"function","name":"string_eq_walk?/4","summary":"","url":"structs/Zap.Doc.html#string_eq_walk?-4"},
{"struct":"Zap.Doc","type":"function","name":"escape_html/1","summary":"","url":"structs/Zap.Doc.html#escape_html-1"},
{"struct":"Zap.Doc","type":"function","name":"anchor_id/2","summary":"Render the \"Implements\" row when a type satisfies one or more\nprotocols.","url":"structs/Zap.Doc.html#anchor_id-2"},
{"struct":"Zap.Doc","type":"function","name":"sort_members_by_source_line/1","summary":"Sort a list of member maps by `:source_line` ascending.","url":"structs/Zap.Doc.html#sort_members_by_source_line-1"},
{"struct":"Zap.Doc","type":"function","name":"compose_function_search_entry/5","summary":"Compose one function/macro JSON search-index entry from already-typed\nfields.","url":"structs/Zap.Doc.html#compose_function_search_entry-5"},
{"struct":"Zap.Doc","type":"function","name":"render_required_rows/3","summary":"","url":"structs/Zap.Doc.html#render_required_rows-3"},
{"struct":"Zap.Doc","type":"function","name":"page_title/1","summary":"Render the page title — the `<h1 class=\"page-title\">` element.","url":"structs/Zap.Doc.html#page_title-1"},
{"struct":"Zap.Doc","type":"function","name":"first_sentence/1","summary":"Extract the first sentence of a doc body for the summary table\ncell.","url":"structs/Zap.Doc.html#first_sentence-1"},
{"struct":"Zap.Doc","type":"function","name":"string_eq?/2","summary":"True when two strings are byte-equal.","url":"structs/Zap.Doc.html#string_eq?-2"},
{"struct":"Zap.Doc","type":"function","name":"list_contains?/2","summary":"Return true when `needle` appears in `items`.","url":"structs/Zap.Doc.html#list_contains?-2"},
{"struct":"Zap.Doc","type":"function","name":"toc_section_label/1","summary":"Build the `<li class=\"toc-section\">Label</li>` divider used inside\nthe right-rail to group items under \"Functions\" and \"Macros\"\nheadings.","url":"structs/Zap.Doc.html#toc_section_label-1"},
{"struct":"Zap.Doc","type":"function","name":"topbar_center/0","summary":"","url":"structs/Zap.Doc.html#topbar_center-0"},
{"struct":"Zap.Doc","type":"function","name":"page_close/1","summary":"Close the document — search modal, `app.js` script tag, `</body>`,\n`</html>`.","url":"structs/Zap.Doc.html#page_close-1"},
{"struct":"Zap.Doc","type":"function","name":"split_top_level_walk/6","summary":"","url":"structs/Zap.Doc.html#split_top_level_walk-6"},
{"struct":"Zap.Doc","type":"function","name":"source_link/4","summary":"Render a `[Source]` link pointing at the function's declaration\nin the project's repository.","url":"structs/Zap.Doc.html#source_link-4"},
{"struct":"Zap.Doc","type":"function","name":"render_function_search_entries/3","summary":"Walk a list of function/macro flat-summaries, accumulating JSON search entries.","url":"structs/Zap.Doc.html#render_function_search_entries-3"},
{"struct":"Zap.Doc","type":"function","name":"struct_page/8","summary":"","url":"structs/Zap.Doc.html#struct_page-8"},
{"struct":"Zap.Doc","type":"function","name":"json_escape/1","summary":"Escape a string for safe inclusion as a JSON string literal.","url":"structs/Zap.Doc.html#json_escape-1"},
{"struct":"Zap.Doc","type":"function","name":"function_search_entry/2","summary":"Render a `:module` + `:name` + `:arity` flat-summary entry as a JSON search entry.","url":"structs/Zap.Doc.html#function_search_entry-2"},
{"struct":"Zap.Doc","type":"function","name":"insert_member_by_line/2","summary":"","url":"structs/Zap.Doc.html#insert_member_by_line-2"},
{"struct":"Zap.Doc","type":"function","name":"insert_name_alpha/3","summary":"","url":"structs/Zap.Doc.html#insert_name_alpha-3"},
{"struct":"Zap.Doc","type":"function","name":"implements_row/1","summary":"Render the \"Implements\" row when a type satisfies one or more\nprotocols.","url":"structs/Zap.Doc.html#implements_row-1"},
{"struct":"Zap.Doc","type":"function","name":"manifest_names/2","summary":"","url":"structs/Zap.Doc.html#manifest_names-2"},
{"struct":"Zap.Doc","type":"function","name":"matching_close_paren/4","summary":"Walk a signature string from `index` looking for the close paren\nthat matches the open paren the caller already consumed.","url":"structs/Zap.Doc.html#matching_close_paren-4"},
{"struct":"Zap.Doc","type":"function","name":"render_member_details_sorted/5","summary":"Render function detail blocks from a list of member maps already\nfiltered+sorted to one module's entries.","url":"structs/Zap.Doc.html#render_member_details_sorted-5"},
{"struct":"Zap.Doc","type":"function","name":"search_modal/0","summary":"","url":"structs/Zap.Doc.html#search_modal-0"},
{"struct":"Zap.Doc","type":"function","name":"render_struct_cards/2","summary":"","url":"structs/Zap.Doc.html#render_struct_cards-2"},
{"struct":"Zap.Doc","type":"function","name":"breadcrumb/2","summary":"Render the breadcrumb above a module title.","url":"structs/Zap.Doc.html#breadcrumb-2"},
{"struct":"Zap.Doc","type":"function","name":"rich_signature_block/1","summary":"Render one signature string as the structured `<div class=\"signature\">`\nblock the legacy generator emitted: `<span class=\"sig-name\">`,\n`<span class=\"sig-paren\">(</span>`, typed-param pills, the\narrow `<span class=\"sig-arrow\">→</span>`, and the return-type pill.","url":"structs/Zap.Doc.html#rich_signature_block-1"},
{"struct":"Zap.Doc","type":"function","name":"right_rail/1","summary":"Wrap pre-rendered TOC items in the right-rail aside, returning the\nempty string when the page has no anchorable entries (data-only\nstructs like `Range`).","url":"structs/Zap.Doc.html#right_rail-1"},
{"struct":"Zap.Doc","type":"function","name":"file_lt_or_eq?/4","summary":"","url":"structs/Zap.Doc.html#file_lt_or_eq?-4"},
{"struct":"Zap.Doc","type":"function","name":"render_sidebar_items/4","summary":"","url":"structs/Zap.Doc.html#render_sidebar_items-4"},
{"struct":"Zap.Doc","type":"function","name":"render_arrow_with_guard/2","summary":"","url":"structs/Zap.Doc.html#render_arrow_with_guard-2"},
{"struct":"Zap.Doc","type":"function","name":"function_details_section/2","summary":"Wrap a sequence of pre-rendered function detail blocks under a\n`<h2>` heading (`Function Details` / `Macro Details`).","url":"structs/Zap.Doc.html#function_details_section-2"},
{"struct":"Zap.Doc","type":"function","name":"string_lt?/2","summary":"True when `left` sorts strictly before `right` lexicographically by\nbyte order.","url":"structs/Zap.Doc.html#string_lt?-2"},
{"struct":"Zap.Doc","type":"function","name":"render_kind_extras/4","summary":"Render kind-specific summary tables that don't fit\n`module_main_content`'s hardcoded Functions/Macros slots.","url":"structs/Zap.Doc.html#render_kind_extras-4"},
{"struct":"Zap.Doc","type":"function","name":"kind_category_label_protocol/1","summary":"","url":"structs/Zap.Doc.html#kind_category_label_protocol-1"},
{"struct":"Zap.Doc","type":"function","name":"render_one_param/1","summary":"","url":"structs/Zap.Doc.html#render_one_param-1"},
{"struct":"Zap.Doc","type":"function","name":"write_pages_to/14","summary":"Render every summary list to disk under `out_dir` and return the\ntotal number of pages written.","url":"structs/Zap.Doc.html#write_pages_to-14"},
{"struct":"Zap.Doc","type":"function","name":"module_main_content/9","summary":"Render the entire left sidebar — three potential groups\n(`Structs`, `Protocols`, `Unions`), each only emitted when its\nmembers list is non-empty.","url":"structs/Zap.Doc.html#module_main_content-9"},
{"struct":"Zap.Doc","type":"function","name":"member_row_for_module/2","summary":"Render a single `summary_row` for `member` if `member[:module]`\nequals `module_name`, otherwise return the empty string.","url":"structs/Zap.Doc.html#member_row_for_module-2"},
{"struct":"Zap.Doc","type":"function","name":"strip_trailing_comma_newline/1","summary":"Strip the trailing `,\\n` separator left on each per-entry\nstring by `*_search_entry`.","url":"structs/Zap.Doc.html#strip_trailing_comma_newline-1"},
{"struct":"Zap.Doc","type":"function","name":"render_signature_guard/1","summary":"","url":"structs/Zap.Doc.html#render_signature_guard-1"},
{"struct":"Zap.Doc","type":"function","name":"sidebar/7","summary":"","url":"structs/Zap.Doc.html#sidebar-7"},
{"struct":"Zap.Doc","type":"function","name":"escape_chars/4","summary":"","url":"structs/Zap.Doc.html#escape_chars-4"},
{"struct":"Zap.Doc","type":"function","name":"signature_block/1","summary":"Render a single signature block — the bordered code panel that\nholds the typed call form (`name(p :: T, ...) -> R [if guard]`).","url":"structs/Zap.Doc.html#signature_block-1"},
{"struct":"Zap.Doc","type":"function","name":"struct_search_entry/2","summary":"Render one struct/protocol/union summary as a JSON entry.","url":"structs/Zap.Doc.html#struct_search_entry-2"},
{"struct":"Zap.Doc","type":"function","name":"write_summary_pages/15","summary":"Iterate `summaries`, render each as a full HTML page, and write\n`<out_dir>/<name>.html`.","url":"structs/Zap.Doc.html#write_summary_pages-15"},
{"struct":"Zap.Doc","type":"function","name":"render_module_member_details/6","summary":"Walk the flat function or macro manifest, filter by `:module` to\nkeep only entries belonging to `module_name`, and emit a\n`<div class=\"function-detail\">` block per match — header with\nname/arity/anchor + Markdown-rendered doc body.","url":"structs/Zap.Doc.html#render_module_member_details-6"},
{"struct":"Zap.Doc","type":"function","name":"index_of_top_level_guard/1","summary":"Locate the top-level ` if ` token that introduces a clause guard,\nskipping nested-paren occurrences so a function-type parameter\n`(T) -> R if pred` doesn't confuse the scanner.","url":"structs/Zap.Doc.html#index_of_top_level_guard-1"},
{"struct":"Zap.Doc","type":"function","name":"tagline/1","summary":"Render an italic-serif tagline below the title from the first\nsentence of a module's `@doc` body.","url":"structs/Zap.Doc.html#tagline-1"},
{"struct":"Zap.Doc","type":"function","name":"render_index_section/3","summary":"Render one section of the index page: a heading plus a `<ul>` of\nlinks, one per name.","url":"structs/Zap.Doc.html#render_index_section-3"},
{"struct":"Zap.Doc","type":"function","name":"render_struct_card_summary/1","summary":"","url":"structs/Zap.Doc.html#render_struct_card_summary-1"},
{"struct":"Zap.Doc","type":"function","name":"render_summary_rows/2","summary":"Compose a complete struct/protocol/union reference page from its\nparts.","url":"structs/Zap.Doc.html#render_summary_rows-2"},
{"struct":"Zap.Doc","type":"function","name":"render_signature_return/1","summary":"Render the trailing portion of a signature after the close paren:\nthe `-> ReturnType [if guard]` segment.","url":"structs/Zap.Doc.html#render_signature_return-1"},
{"struct":"Zap.Doc","type":"function","name":"function_detail/5","summary":"","url":"structs/Zap.Doc.html#function_detail-5"},
{"struct":"Zap.Doc","type":"function","name":"sidebar_group/4","summary":"Render one collapsible sidebar group — the chevron-button header\nplus the `<ul>` of struct items.","url":"structs/Zap.Doc.html#sidebar_group-4"},
{"struct":"Zap.Doc","type":"function","name":"line_eq_or_gt?/3","summary":"","url":"structs/Zap.Doc.html#line_eq_or_gt?-3"},
{"struct":"Zap.DocsRunner","type":"function","name":"main/1","summary":"Render every reflected module to `docs/<name>.html` and write `style.css` + `app.js`.","url":"structs/Zap.DocsRunner.html#main-1"},
{"struct":"Zest","type":"function","name":"assert/2","summary":"Asserts that a boolean value is `true` with a custom message.","url":"structs/Zest.html#assert-2"},
{"struct":"Zest","type":"function","name":"reject/2","summary":"Asserts that a boolean value is `false` with a custom message.","url":"structs/Zest.html#reject-2"},
{"struct":"Zest","type":"function","name":"reject/1","summary":"Asserts that a boolean value is `false`.","url":"structs/Zest.html#reject-1"},
{"struct":"Zest","type":"function","name":"assert/1","summary":"Asserts that a boolean value is `true`.","url":"structs/Zest.html#assert-1"},
{"struct":"Zest.Case","type":"function","name":"print_result/0","summary":"Wraps `print_result` for explicit use.","url":"structs/Zest.Case.html#print_result-0"},
{"struct":"Zest.Case","type":"function","name":"begin_test/0","summary":"Wraps `begin_test` for explicit use.","url":"structs/Zest.Case.html#begin_test-0"},
{"struct":"Zest.Case","type":"function","name":"reject/1","summary":"Asserts that a boolean value is `false`.","url":"structs/Zest.Case.html#reject-1"},
{"struct":"Zest.Case","type":"function","name":"end_test/0","summary":"Wraps `end_test` for explicit use.","url":"structs/Zest.Case.html#end_test-0"},
{"struct":"Zest.Case","type":"function","name":"assert/1","summary":"Asserts that a boolean value is `true`.","url":"structs/Zest.Case.html#assert-1"},
{"struct":"Zest.Runner","type":"function","name":"parse_cli_args/2","summary":"Recursively scans CLI arguments for `--seed <value>` and\n`--timeout <milliseconds>`, applying each to the test tracker.","url":"structs/Zest.Runner.html#parse_cli_args-2"},
{"struct":"Zest.Runner","type":"function","name":"configure/0","summary":"Parses `--seed` and `--timeout` from CLI arguments and applies\nthem to the test tracker.","url":"structs/Zest.Runner.html#configure-0"},
{"struct":"Zest.Runner","type":"function","name":"run/0","summary":"Prints the test summary with counts and exits with a\nfailure code if any tests failed.","url":"structs/Zest.Runner.html#run-0"},
{"struct":"Function","type":"macro","name":"identity/1","summary":"Returns the value unchanged.","url":"structs/Function.html#identity-1"},
{"struct":"Kernel","type":"macro","name":"or/2","summary":"Short-circuit logical OR.","url":"structs/Kernel.html#or-2"},
{"struct":"Kernel","type":"macro","name":"and/2","summary":"Short-circuit logical AND.","url":"structs/Kernel.html#and-2"},
{"struct":"Kernel","type":"macro","name":"sigil_W/2","summary":"Word list sigil without interpolation.","url":"structs/Kernel.html#sigil_W-2"},
{"struct":"Kernel","type":"macro","name":"sigil_w/2","summary":"Word list sigil with interpolation support.","url":"structs/Kernel.html#sigil_w-2"},
{"struct":"Kernel","type":"macro","name":"fn/1","summary":"Declaration macro for function definitions.","url":"structs/Kernel.html#fn-1"},
{"struct":"Kernel","type":"macro","name":"struct/1","summary":"Declaration macro for struct definitions.","url":"structs/Kernel.html#struct-1"},
{"struct":"Kernel","type":"macro","name":"union/1","summary":"Declaration macro for union/enum definitions.","url":"structs/Kernel.html#union-1"},
{"struct":"Kernel","type":"macro","name":"if/3","summary":"Conditional expression with both branches.","url":"structs/Kernel.html#if-3"},
{"struct":"Kernel","type":"macro","name":"sigil_s/2","summary":"String sigil with interpolation support.","url":"structs/Kernel.html#sigil_s-2"},
{"struct":"Kernel","type":"macro","name":"|>/2","summary":"Pipe operator.","url":"structs/Kernel.html#|>-2"},
{"struct":"Kernel","type":"macro","name":"<>/2","summary":"Concatenation operator.","url":"structs/Kernel.html#<>-2"},
{"struct":"Kernel","type":"macro","name":"if/2","summary":"Conditional expression with a single branch.","url":"structs/Kernel.html#if-2"},
{"struct":"Kernel","type":"macro","name":"unless/2","summary":"Negated conditional.","url":"structs/Kernel.html#unless-2"},
{"struct":"Kernel","type":"macro","name":"sigil_S/2","summary":"Raw string sigil without interpolation.","url":"structs/Kernel.html#sigil_S-2"},
{"struct":"SourceGraph","type":"macro","name":"protocols/1","summary":"Returns protocol references declared in the exact source paths\nprovided.","url":"structs/SourceGraph.html#protocols-1"},
{"struct":"SourceGraph","type":"macro","name":"impls/1","summary":"Returns public protocol-impl entries declared in the supplied\nsource paths.","url":"structs/SourceGraph.html#impls-1"},
{"struct":"SourceGraph","type":"macro","name":"structs/1","summary":"Returns struct references declared in the exact source paths provided.","url":"structs/SourceGraph.html#structs-1"},
{"struct":"SourceGraph","type":"macro","name":"unions/1","summary":"Returns union references declared in the exact source paths\nprovided.","url":"structs/SourceGraph.html#unions-1"},
{"struct":"Struct","type":"macro","name":"info/1","summary":"Returns struct-level metadata for a reflected struct as a compile-time\nmap: `:name`, `:source_file` (project-relative path), `:is_private`,\nand `:doc` (the struct's `@doc` attribute, heredoc-stripped, or\nempty when missing).","url":"structs/Struct.html#info-1"},
{"struct":"Struct","type":"macro","name":"has_function?/3","summary":"Returns true when a reflected struct exposes a public function with\nthe given name and arity.","url":"structs/Struct.html#has_function?-3"},
{"struct":"Struct","type":"macro","name":"macros/1","summary":"Returns the public macros declared on a reflected struct, with the\nsame map shape as `functions/1`.","url":"structs/Struct.html#macros-1"},
{"struct":"Struct","type":"macro","name":"functions/1","summary":"Returns the public functions declared on a reflected struct.","url":"structs/Struct.html#functions-1"},
{"struct":"Struct","type":"macro","name":"union_variants/1","summary":"Returns the variants of a reflected union as a list of compile-time\nmaps with `:name` and `:signature` (the rendered Zap-syntax form,\n`Variant` for bare variants and `Variant :: TypeExpr` for typed\npayloads).","url":"structs/Struct.html#union_variants-1"},
{"struct":"Struct","type":"macro","name":"protocol_required_functions/1","summary":"Returns the required functions a protocol declares as a list of\ncompile-time maps with `:name` and `:signature`.","url":"structs/Struct.html#protocol_required_functions-1"},
{"struct":"Zap.Doc.Builder","type":"macro","name":"patterns/1","summary":"Pull the `:paths` (or `:path`) glob list out of the use options.","url":"structs/Zap.Doc.Builder.html#patterns-1"},
{"struct":"Zap.Doc.Builder","type":"macro","name":"options/1","summary":"Normalize the option list passed to `use Zap.Doc.Builder`.","url":"structs/Zap.Doc.Builder.html#options-1"},
{"struct":"Zap.Doc.Builder","type":"macro","name":"pattern_values/1","summary":"","url":"structs/Zap.Doc.Builder.html#pattern_values-1"},
{"struct":"Zap.Doc.Builder","type":"macro","name":"option_patterns/1","summary":"","url":"structs/Zap.Doc.Builder.html#option_patterns-1"},
{"struct":"Zest.Case","type":"macro","name":"test/2","summary":"Defines a test case without context.","url":"structs/Zest.Case.html#test-2"},
{"struct":"Zest.Case","type":"macro","name":"setup/1","summary":"Declares setup code that runs before each test with context.","url":"structs/Zest.Case.html#setup-1"},
{"struct":"Zest.Case","type":"macro","name":"describe/2","summary":"Groups related tests under a descriptive label.","url":"structs/Zest.Case.html#describe-2"},
{"struct":"Zest.Case","type":"macro","name":"teardown/1","summary":"Declares teardown code that runs after each test.","url":"structs/Zest.Case.html#teardown-1"},
{"struct":"Zest.Runner","type":"macro","name":"options/1","summary":"Normalizes runner options to a list.","url":"structs/Zest.Runner.html#options-1"}
]
;
/* Zap Documentation */
(function() {
  'use strict';

  // Theme — dark is default per design; toggle persists user choice.
  // No system-preference sniffing.
  var toggle = document.getElementById('theme-toggle');
  var html = document.documentElement;
  var saved = localStorage.getItem('zap-docs-theme');
  html.setAttribute('data-theme', saved === 'light' ? 'light' : 'dark');
  if (toggle) {
    toggle.addEventListener('click', function() {
      var current = html.getAttribute('data-theme');
      var next = current === 'dark' ? 'light' : 'dark';
      html.setAttribute('data-theme', next);
      localStorage.setItem('zap-docs-theme', next);
    });
  }

  // Sidebar group collapse — chevron toggles on header click, state persists.
  var groupState = {};
  try { groupState = JSON.parse(localStorage.getItem('zap-docs-sidebar') || '{}'); } catch (e) {}
  document.querySelectorAll('.sidebar-group').forEach(function(group) {
    var key = group.getAttribute('data-group') || '';
    if (groupState[key] === true) group.setAttribute('data-collapsed', 'true');
    var header = group.querySelector('.sidebar-group-header');
    if (header) {
      header.addEventListener('click', function() {
        var collapsed = group.getAttribute('data-collapsed') === 'true';
        if (collapsed) group.removeAttribute('data-collapsed');
        else group.setAttribute('data-collapsed', 'true');
        groupState[key] = !collapsed;
        try { localStorage.setItem('zap-docs-sidebar', JSON.stringify(groupState)); } catch (e) {}
      });
    }
  });

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

  function rankScore(haystack, needle) {
    if (haystack.startsWith(needle)) return 0;
    if (haystack.indexOf(needle) !== -1) return 1;
    return 2;
  }

  function doSearch(query) {
    if (!searchData || !query) { searchResults.innerHTML = ''; return; }
    var q = query.toLowerCase();
    var scored = [];
    for (var i = 0; i < searchData.length; i++) {
      var item = searchData[i];
      var bestScore = Math.min(
        rankScore(item.name.toLowerCase(), q),
        rankScore(item.struct.toLowerCase(), q),
        item.summary ? rankScore(item.summary.toLowerCase(), q) : 2
      );
      if (bestScore < 2) scored.push({ item: item, score: bestScore });
    }
    scored.sort(function(a, b) { return a.score - b.score; });
    var matches = scored.slice(0, 12).map(function(x) { return x.item; });
    searchResults.innerHTML = matches.map(function(item, i) {
      var typeLabel = (item.type || '').toUpperCase();
      var label = item.struct && item.type === 'function' || item.type === 'macro'
        ? item.struct + '.' + item.name
        : item.name;
      var selected = i === 0;
      return '<li data-url="' + basePath + item.url + '"' + (selected ? ' class="selected"' : '') + '>' +
        '<span class="result-type">' + escapeHtml(typeLabel) + '</span>' +
        '<span class="result-name">' + escapeHtml(label) + '</span>' +
        (item.summary ? '<span class="result-summary">' + escapeHtml(item.summary) + '</span>' : '<span class="result-summary"></span>') +
        '<span class="result-enter">' + (selected ? '↵' : '') + '</span>' +
        '</li>';
    }).join('');
    selectedIndex = matches.length > 0 ? 0 : -1;
  }

  function updateSelectionStyles() {
    var items = searchResults.querySelectorAll('li');
    items.forEach(function(li, i) {
      li.className = i === selectedIndex ? 'selected' : '';
      var enter = li.querySelector('.result-enter');
      if (enter) enter.textContent = i === selectedIndex ? '↵' : '';
    });
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
        updateSelectionStyles();
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        selectedIndex = Math.max(selectedIndex - 1, 0);
        updateSelectionStyles();
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
