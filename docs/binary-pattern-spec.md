# Binary Pattern Matching Specification

## Overview

Binary pattern matching enables extracting and constructing raw binary data — bytes, integers of arbitrary width, floats, bitstrings, and UTF-encoded text — using a declarative syntax. This is the same model Elixir/Erlang uses, adapted to use Zap's native types and lowered to Zig's type-safe pointer and bit operations.

## Syntax

### Binary Literals (Construction)

```zap
<<1, 2, 3>>                          # 3-byte binary: [1, 2, 3]
<<72, 101, 108, 108, 111>>           # "Hello" as bytes
<<0xFF, 0x00>>                       # hex bytes
```

### Binary Patterns (Destructuring)

```zap
<<a, b, c>> = some_binary            # extract 3 bytes (each u8)
<<header::u16, body::String>> = data # 16-bit int + rest as String
<<_::u8, payload::String>> = packet  # skip first byte
```

## Segment Specifiers

Each segment in a `<<>>` expression has the form:

```
value :: type - endianness
```

Or with explicit size for String segments:

```
value :: String-size(n)
```

All specifiers except `value` are optional. A bare value with no specifier defaults to `::u8`.

### Type Specifiers

Zap's existing types are used directly. No parallel type system.

#### Integer Types

Any Zig-compatible integer type. Signedness and size are encoded in the type name.

| Type | Bits | Signed | Description |
|------|------|--------|-------------|
| `u8` | 8 | No | Single byte (default) |
| `i8` | 8 | Yes | Signed byte |
| `u16` | 16 | No | Unsigned 16-bit |
| `i16` | 16 | Yes | Signed 16-bit |
| `u32` | 32 | No | Unsigned 32-bit |
| `i32` | 32 | Yes | Signed 32-bit |
| `u64` | 64 | No | Unsigned 64-bit |
| `i64` | 64 | Yes | Signed 64-bit |
| `u1` | 1 | No | Single bit |
| `u4` | 4 | No | Nibble |

Zig supports arbitrary bit-width integers, so `u3`, `u13`, `i24` etc. are all valid.

#### Float Types

| Type | Bits | Description |
|------|------|-------------|
| `f16` | 16 | Half precision |
| `f32` | 32 | Single precision |
| `f64` | 64 | Double precision |

#### String Type

| Type | Default size | Description |
|------|-------------|-------------|
| `String` | rest of input | Raw byte sequence (`[]const u8`) |
| `String-size(n)` | n bytes | Fixed-size byte sequence |

#### UTF Types

| Type | Description |
|------|-------------|
| `utf8` | One UTF-8 encoded codepoint (1-4 bytes) |
| `utf16` | One UTF-16 encoded codepoint (2 or 4 bytes) |
| `utf32` | One UTF-32 encoded codepoint (4 bytes) |

### Endianness Modifier

Applies to integer and float types. Default is `big` (network byte order).

| Modifier | Description |
|----------|-------------|
| `big` | Big-endian / network byte order (default) |
| `little` | Little-endian |
| `native` | Platform native endianness |

```zap
<<port::u16-big>>       # network byte order (default)
<<val::u32-little>>     # little-endian
<<ts::i64-native>>      # platform native
```

### Size Modifier (String only)

String segments consume the rest of the input by default. Use `size(n)` for fixed-size:

```zap
<<header::String-size(4), rest::String>> = data
```

Size can be a previously-bound variable:

```zap
<<length::u16, body::String-size(length), rest::String>> = packet
```

## Pattern Matching Examples

### Individual Bytes

```zap
def decode(<<a, b, c>>) do
  {a, b, c}
end
```

Matches exactly 3 bytes. Each variable binds to a `u8`.

### Fixed-Width Integer Fields

```zap
def parse_header(<<version::u4, type::u4, length::u16, body::String>>) do
  {version, type, length, body}
end
```

Extracts a 4-bit version, 4-bit type, 16-bit length, and the remaining bytes.

### Variable-Length Body

```zap
def parse_packet(<<length::u16, body::String-size(length), rest::String>>) do
  {body, rest}
end
```

The `length` field determines how many bytes `body` captures. `rest` gets everything after.

### String Prefix Matching

```zap
def parse_method(<<"GET "::String, path::String>>) do
  {:get, path}
end

def parse_method(<<"POST "::String, path::String>>) do
  {:post, path}
end
```

String literals in binary patterns match their UTF-8 byte representation.

### Signed Integers

```zap
def parse_temperature(<<temp::i16-big>>) do
  temp  # can be negative
end
```

### Float Extraction

```zap
def parse_coordinate(<<lat::f64, lon::f64>>) do
  {lat, lon}
end
```

### UTF-8 Codepoints

```zap
def first_char(<<codepoint::utf8, rest::String>>) do
  {codepoint, rest}
end
```

Matches one UTF-8 encoded codepoint (1-4 bytes depending on the character).

### Bitwise Flags

```zap
def parse_flags(<<syn::u1, ack::u1, fin::u1, _reserved::u5>>) do
  {syn, ack, fin}
end
```

Individual bit extraction using Zig's arbitrary-width integer types.

## Binary Construction

### Building Binaries

```zap
header = <<version::u4, type::u4, length::u16>>
packet = <<header::String, body::String>>
```

### Integer Encoding

```zap
<<port::u16-big>>          # encode port as 2 bytes big-endian
<<0xDEADBEEF::u32-big>>   # 4-byte constant
```

### UTF-8 Encoding

```zap
<<codepoint::utf8>>       # encode a codepoint as 1-4 UTF-8 bytes
```

## Guards on Binary Patterns

```zap
def classify(<<header::u8, _::String>>) when header < 128 do
  :ascii
end

def classify(<<header::u8, _::String>>) when header >= 128 do
  :extended
end
```

## Zig Lowering

### Individual Byte Extraction

```zap
<<a, b, c>> = data
```

Lowers to:

```zig
const a = data[0];
const b = data[1];
const c = data[2];
```

### Multi-Byte Integer (Big-Endian)

```zap
<<port::u16-big>> = data
```

Lowers to:

```zig
const port = std.mem.readInt(u16, data[0..2], .big);
```

### Multi-Byte Integer (Little-Endian)

```zap
<<val::u32-little>> = data
```

Lowers to:

```zig
const val = std.mem.readInt(u32, data[0..4], .little);
```

### Signed Integers

```zap
<<temp::i16-big>> = data
```

Lowers to:

```zig
const temp = std.mem.readInt(i16, data[0..2], .big);
```

### Float Extraction

```zap
<<lat::f64>> = data
```

Lowers to:

```zig
const lat: f64 = @bitCast(std.mem.readInt(u64, data[0..8], .big));
```

### String Slice (Rest)

```zap
<<header::String-size(4), rest::String>> = data
```

Lowers to:

```zig
const header = data[0..4];
const rest = data[4..];
```

### Variable-Length String Slice

```zap
<<length::u16, body::String-size(length)>> = data
```

Lowers to:

```zig
const length = std.mem.readInt(u16, data[0..2], .big);
const body = data[2..][0..length];
```

### Bit-Level Extraction

```zap
<<flag::u1, type::u3, value::u4>> = byte
```

Lowers to:

```zig
const bits = data[0];
const flag: u1 = @truncate(bits >> 7);
const type_: u3 = @truncate(bits >> 4);
const value: u4 = @truncate(bits);
```

### UTF-8 Decoding

```zap
<<codepoint::utf8, rest::String>> = data
```

Lowers to:

```zig
const len = std.unicode.utf8ByteSequenceLength(data[0]) catch 1;
const codepoint = std.unicode.utf8Decode(data[0..len]) catch 0xFFFD;
const rest = data[len..];
```

### Binary Construction

```zap
<<port::u16-big>>
```

Lowers to:

```zig
var buf: [2]u8 = undefined;
std.mem.writeInt(u16, &buf, port, .big);
```

### Pattern Match in Function Head

```zap
def parse(<<type::u8, length::u16, body::String-size(length)>>) do
  {type, body}
end
```

Lowers to a function that validates minimum length, then extracts fields:

```zig
fn parse(data: []const u8) ... {
    if (data.len < 3) @panic("binary match failed");
    const type_ = data[0];
    const length = std.mem.readInt(u16, data[1..3], .big);
    if (data.len < 3 + length) @panic("binary match failed");
    const body = data[3..][0..length];
    ...
}
```

## Defaults Summary

| Context | Default |
|---------|---------|
| Bare value (no specifier) | `u8` |
| Endianness | `big` |
| String size | rest of input |

## Implementation Order

1. Parser: `<<>>` syntax for patterns and expressions, segment specifiers with Zap types
2. AST: `BinaryPattern`, `BinaryExpr`, `BinarySegment` with type, endianness, size fields
3. HIR: Binary match/construct nodes
4. IR: Binary extraction instructions (`bin_match_int`, `bin_match_float`, `bin_match_string`, `bin_match_utf8`)
5. IR: Binary construction instructions (`bin_build`)
6. Codegen: Zig lowering for all extraction and construction cases
7. Decision tree: Binary patterns in function dispatch and case expressions
8. Tests: Full coverage for each segment type and specifier combination
