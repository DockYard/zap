#!/bin/bash
# Real-Zig smoke test for the memory-manager compilation pipeline.
#
# Compiles `src/memory/no_op/manager.zig` with the system `zig` compiler
# (treating it as a standalone object file, exactly as the Zig-fork
# primitive `zap_fork_compile_zig_to_object` would) and verifies the
# resulting object:
#
#   1. Exports the mandatory `zap_memory_section` symbol (spec section
#      3.2 + 10.5 — the runtime's weak-extern bootstrap depends on it).
#   2. Contains a `.zapmem` (ELF) or `__zapmem` (Mach-O) section in the
#      expected location.
#
# This catches drift between the synthesizer expectations baked into
# `src/memory/driver.zig`'s mocks and what the real Zig compiler emits.
# The standard test suite (`zig build test`) uses synthesized objects
# because the fork primitive is gated behind `builtin.is_test`; this
# script complements that with a real-toolchain validation.
#
# Usage:
#   ./scripts/test_manager_compile.sh
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
MANAGER_SRC="$PROJECT_ROOT/src/memory/no_op/manager.zig"

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
PROBE_SRC="$PROJECT_ROOT/src/memory/__driver_check_probe.zig"
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
    driver.assertExportsManagerSymbolForTest("real_no_op", bytes, &diag) catch |err| {
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

echo ""
echo ">>> Manager compilation smoke test PASSED."
