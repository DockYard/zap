#!/bin/bash
set -euo pipefail

# Build libzig_compiler.a from the Zig fork.
#
# Usage: ./scripts/build-zig-lib.sh [ZIG_FORK] [LLVM_PREFIX]
#   ZIG_FORK   — path to the Zig source tree   (default: $HOME/projects/zig)
#   LLVM_PREFIX — path to the LLVM installation (default: $HOME/llvm-20)

ZIG_FORK="${1:-$HOME/projects/zig}"
LLVM_PREFIX="${2:-$HOME/llvm-20}"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if ! command -v zig &>/dev/null; then
    echo "ERROR: 'zig' not found in PATH." >&2
    exit 1
fi

if ! command -v cmake &>/dev/null; then
    echo "ERROR: 'cmake' not found in PATH." >&2
    exit 1
fi

if [ ! -d "$ZIG_FORK" ]; then
    echo "ERROR: Zig fork directory not found: $ZIG_FORK" >&2
    exit 1
fi

if [ ! -d "$LLVM_PREFIX" ]; then
    echo "ERROR: LLVM prefix directory not found: $LLVM_PREFIX" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Ensure build/config.h exists (run cmake if not)
# ---------------------------------------------------------------------------

BUILD_DIR="$ZIG_FORK/build"

if [ ! -f "$BUILD_DIR/config.h" ]; then
    echo ">>> config.h not found — running cmake to generate it..."
    mkdir -p "$BUILD_DIR"
    cmake -S "$ZIG_FORK" -B "$BUILD_DIR" \
        -DCMAKE_PREFIX_PATH="$LLVM_PREFIX" \
        -DCMAKE_BUILD_TYPE=Release
    echo ">>> cmake configuration complete."
fi

if [ ! -f "$BUILD_DIR/config.h" ]; then
    echo "ERROR: config.h still missing after cmake. Check cmake output." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the library
# ---------------------------------------------------------------------------

echo ">>> Building libzig_compiler.a ..."
echo "    ZIG_FORK:    $ZIG_FORK"
echo "    LLVM_PREFIX: $LLVM_PREFIX"

cd "$ZIG_FORK"

zig build lib \
    -Denable-llvm \
    -Dstatic-llvm \
    -Dconfig_h="$BUILD_DIR/config.h"

# ---------------------------------------------------------------------------
# Report result
# ---------------------------------------------------------------------------

LIB_PATH="$ZIG_FORK/zig-out/lib/libzig_compiler.a"

if [ ! -f "$LIB_PATH" ]; then
    # Try alternate known location
    LIB_PATH="$(find "$ZIG_FORK/zig-out" -name 'libzig_compiler.a' 2>/dev/null | head -1)"
fi

if [ -z "$LIB_PATH" ] || [ ! -f "$LIB_PATH" ]; then
    echo "ERROR: libzig_compiler.a was not produced. Check build output." >&2
    exit 1
fi

LIB_SIZE=$(du -h "$LIB_PATH" | cut -f1)

echo ""
echo ">>> Build complete."
echo "    Output: $LIB_PATH"
echo "    Size:   $LIB_SIZE"
