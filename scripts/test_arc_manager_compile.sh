#!/bin/bash
# Real-Zig smoke test for the production ARC memory-manager source.
#
# Compiles `src/memory/arc/manager.zig` with the system `zig` compiler
# (treating it as a standalone object file, exactly as the Zig-fork
# primitive `zap_fork_compile_zig_to_object` would in production) and
# verifies the resulting object:
#
#   1. Exports the mandatory `zap_memory_section` symbol (spec section
#      3.2 + 10.5 — the runtime's weak-extern bootstrap depends on it).
#   2. Contains a `.zapmem` (ELF) or `__zapmem` (Mach-O) section in the
#      expected location.
#   3. Is accepted by `src/memory/driver.zig`'s symbol/section validator
#      (the same code path the build driver uses at link time).
#
# This is the Phase 4 ARC counterpart of `test_manager_compile.sh`, which
# covers `src/memory/no_op/manager.zig`. The Phase 4 integration test in
# `src/memory/driver.zig` ("Phase 4 integration: ARC manager resolves
# end-to-end (no short-circuit)") uses a synthesized object whose section
# layout mimics this manager but does NOT compile the actual source. The
# script below closes that gap by exercising the real source through the
# real system `zig`, catching drift between what we think the manager
# emits and what the toolchain actually produces.
#
# Usage:
#   ./scripts/test_arc_manager_compile.sh
#
# Exit codes:
#   0 — symbol found and section present
#   1 — symbol missing or section absent (test failure)
#   2 — toolchain not available or build failed (environment issue)

set -euo pipefail

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if ! command -v zig &>/dev/null; then
    echo "ERROR: 'zig' not found in PATH." >&2
    exit 2
fi

if ! command -v nm &>/dev/null; then
    echo "ERROR: 'nm' not found in PATH." >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANAGER_SRC="$PROJECT_ROOT/src/memory/arc/manager.zig"

if [ ! -f "$MANAGER_SRC" ]; then
    echo "ERROR: Manager source not found at $MANAGER_SRC" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Compile the manager into an object file
# ---------------------------------------------------------------------------

TMPDIR_PATH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_PATH"' EXIT

OBJECT_PATH="$TMPDIR_PATH/manager.o"

echo ">>> Compiling $MANAGER_SRC..."
zig build-obj "$MANAGER_SRC" -O ReleaseSafe -femit-bin="$OBJECT_PATH" 2>&1 | tee "$TMPDIR_PATH/build.log"

if [ ! -f "$OBJECT_PATH" ]; then
    echo "ERROR: Object file was not produced. See build log above." >&2
    exit 2
fi

OBJ_SIZE=$(du -h "$OBJECT_PATH" | cut -f1)
echo ">>> Object compiled: $OBJECT_PATH ($OBJ_SIZE)"

# ---------------------------------------------------------------------------
# Symbol check via `nm`
# ---------------------------------------------------------------------------

# Match either `zap_memory_section` (ELF / COFF) or `_zap_memory_section`
# (Mach-O — the loader prefixes external C symbols with an underscore).
echo ">>> Checking symbol table for 'zap_memory_section' via nm..."

if nm "$OBJECT_PATH" 2>/dev/null | grep -Eq '(^| )_?zap_memory_section( |$)'; then
    SYMBOL_LINE=$(nm "$OBJECT_PATH" 2>/dev/null | grep -E '(^| )_?zap_memory_section( |$)' | head -1)
    echo "    OK: symbol present — $SYMBOL_LINE"
else
    echo "ERROR: 'zap_memory_section' is missing from the object's symbol table." >&2
    echo "       Full nm output for reference:" >&2
    nm "$OBJECT_PATH" >&2 || true
    exit 1
fi

# ---------------------------------------------------------------------------
# Driver-side symbol check
#
# Builds a tiny Zig program that imports `src/memory/driver.zig` and
# calls `assertExportsManagerSymbol` on the freshly-compiled object.
# This is the stronger check: it validates the actual code path the
# build driver uses at link time, not just that `nm` finds the symbol.
# ---------------------------------------------------------------------------

echo ">>> Validating object via driver.assertExportsManagerSymbol..."

# Zig forbids cross-module file imports, so the probe must live next to
# `driver.zig`. We drop it in a temp file inside `src/memory/` and clean
# up on exit. The script's outer `trap` only removes its tmpdir; the
# probe is on a separate cleanup line so a failure mid-script does not
# leave debris in the source tree.
PROBE_SRC="$PROJECT_ROOT/src/memory/__arc_driver_check_probe.zig"
PROBE_BIN="$TMPDIR_PATH/driver_check"
trap 'rm -f "$PROBE_SRC"; rm -rf "$TMPDIR_PATH"' EXIT
cat > "$PROBE_SRC" <<'EOF'
const std = @import("std");
const driver = @import("driver.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: {s} <object-path>\n", .{args[0]});
        std.process.exit(2);
    }
    const object_path = args[1];

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        object_path,
        allocator,
        .limited(64 * 1024 * 1024),
    );
    defer allocator.free(bytes);

    var diag_buf: [1024]u8 = undefined;
    var diag: driver.DriverDiagnostic = .{ .buffer = &diag_buf };
    driver.assertExportsManagerSymbolForTest("real_arc", bytes, &diag) catch |err| {
        std.debug.print("driver rejected object: {} - {s}\n", .{ err, diag.text() });
        std.process.exit(1);
    };
    std.debug.print("driver accepted object: zap_memory_section present\n", .{});
}
EOF

# Build the driver-check program. Both the probe and `driver.zig` sit in
# the same directory, so the import resolves without extra config.
if zig build-exe "$PROBE_SRC" -femit-bin="$PROBE_BIN" 2>"$TMPDIR_PATH/driver_build.log"; then
    if "$PROBE_BIN" "$OBJECT_PATH"; then
        echo "    OK: driver.assertExportsManagerSymbol accepted the object"
    else
        echo "ERROR: driver.assertExportsManagerSymbol rejected the object" >&2
        rm -f "$PROBE_SRC"
        exit 1
    fi
else
    echo "ERROR: could not build driver-check probe — see log:" >&2
    cat "$TMPDIR_PATH/driver_build.log" >&2
    rm -f "$PROBE_SRC"
    exit 2
fi
rm -f "$PROBE_SRC"

# ---------------------------------------------------------------------------
# Section presence check
# ---------------------------------------------------------------------------

UNAME_S=$(uname -s)
echo ">>> Checking for .zapmem / __zapmem section (host: $UNAME_S)..."

case "$UNAME_S" in
    Darwin)
        # Mach-O: use otool to list sections inside __DATA.
        if command -v otool &>/dev/null; then
            if otool -l "$OBJECT_PATH" | grep -q '__zapmem'; then
                echo "    OK: Mach-O __zapmem section present"
            else
                echo "ERROR: __zapmem section not found in Mach-O object." >&2
                otool -l "$OBJECT_PATH" | grep -A2 'sectname' >&2 || true
                exit 1
            fi
        else
            echo "    SKIP: 'otool' not available; section content not validated"
        fi
        ;;
    Linux)
        # ELF: prefer readelf or objdump.
        if command -v readelf &>/dev/null; then
            if readelf -S "$OBJECT_PATH" | grep -q '\.zapmem'; then
                echo "    OK: ELF .zapmem section present"
            else
                echo "ERROR: .zapmem section not found in ELF object." >&2
                readelf -S "$OBJECT_PATH" >&2 || true
                exit 1
            fi
        elif command -v objdump &>/dev/null; then
            if objdump -h "$OBJECT_PATH" | grep -q '\.zapmem'; then
                echo "    OK: ELF .zapmem section present"
            else
                echo "ERROR: .zapmem section not found in ELF object." >&2
                objdump -h "$OBJECT_PATH" >&2 || true
                exit 1
            fi
        else
            echo "    SKIP: neither 'readelf' nor 'objdump' available; section content not validated"
        fi
        ;;
    *)
        echo "    SKIP: section validation not implemented for $UNAME_S"
        ;;
esac

# ---------------------------------------------------------------------------
# REFCOUNT_V1 declaration check
#
# The ARC manager differs from the NoOp manager in exactly one
# observable way at the section level: `declared_caps` carries the
# REFCOUNT_V1 bit (0x1) instead of 0. Read the section payload and
# assert the bit is set. The meta header layout is:
#
#   offset 0   u32   magic ("ZMEM")
#   offset 4   u16   abi_major
#   offset 6   u16   abi_minor
#   offset 8   u16   size
#   offset 10  u16   _reserved2
#   offset 12  u32   desc_count
#   offset 16  u64   declared_caps   <-- the byte we want
#   offset 24  u32   core_vtable_offset
#   offset 28  u32   reserved
#
# `objcopy` is the most portable way to extract the section bytes on
# both ELF and Mach-O hosts.
# ---------------------------------------------------------------------------

echo ">>> Verifying REFCOUNT_V1 bit (0x1) in declared_caps..."

SECTION_PAYLOAD="$TMPDIR_PATH/zapmem.bin"

extract_section() {
    case "$UNAME_S" in
        Darwin)
            # Use `otool -lv` to read the section's file offset and
            # size from the LC_SEGMENT_64 / section_64 metadata, then
            # `dd` the raw bytes straight out of the object file. This
            # preserves byte order — `otool -s` reformats the bytes
            # into big-endian 32-bit-word hex words for display and
            # breaks little-endian field reads.
            if command -v otool &>/dev/null; then
                local lv
                lv=$(otool -lv "$OBJECT_PATH" 2>/dev/null) || return 1
                local sect_offset sect_size
                sect_offset=$(printf '%s\n' "$lv" \
                    | awk '
                        $1=="sectname" && $2=="__zapmem" { in_sect=1; next }
                        in_sect && $1=="offset" { print $2; exit }
                    ')
                sect_size=$(printf '%s\n' "$lv" \
                    | awk '
                        $1=="sectname" && $2=="__zapmem" { in_sect=1; next }
                        in_sect && $1=="size" { print $2; exit }
                    ')
                if [ -n "$sect_offset" ] && [ -n "$sect_size" ]; then
                    # `size` is a hex value like `0x0000000000000058`;
                    # arithmetic context coerces it to decimal.
                    dd if="$OBJECT_PATH" of="$SECTION_PAYLOAD" \
                        bs=1 skip="$sect_offset" count=$((sect_size)) 2>/dev/null
                    if [ -s "$SECTION_PAYLOAD" ]; then return 0; fi
                fi
            fi
            ;;
        *)
            if command -v objcopy &>/dev/null; then
                if objcopy -O binary -j .zapmem "$OBJECT_PATH" "$SECTION_PAYLOAD" 2>/dev/null; then
                    if [ -s "$SECTION_PAYLOAD" ]; then return 0; fi
                fi
            fi
            ;;
    esac
    return 1
}

if extract_section; then
    # 16 bytes into the payload is `declared_caps`. We read 8 bytes
    # little-endian and check that bit 0 is set.
    DECLARED_CAPS_LSB=$(od -A n -j 16 -N 1 -t u1 "$SECTION_PAYLOAD" | tr -d ' \n')
    if [ -z "$DECLARED_CAPS_LSB" ]; then
        echo "ERROR: failed to read declared_caps byte from section payload." >&2
        exit 1
    fi
    if [ $((DECLARED_CAPS_LSB & 1)) -eq 1 ]; then
        echo "    OK: REFCOUNT_V1 bit set (declared_caps lsb = $DECLARED_CAPS_LSB)"
    else
        echo "ERROR: REFCOUNT_V1 bit NOT set (declared_caps lsb = $DECLARED_CAPS_LSB)." >&2
        echo "       Expected the ARC manager to declare REFCOUNT_V1 (bit 0)." >&2
        exit 1
    fi
else
    echo "    SKIP: section extraction unavailable on this host; declared_caps check skipped"
fi

echo ""
echo ">>> ARC manager compilation smoke test PASSED."
