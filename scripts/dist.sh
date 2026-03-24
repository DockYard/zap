#!/bin/bash
set -euo pipefail

# Create a release tarball for Zap.
#
# Usage: ./scripts/dist.sh [VERSION]
#   VERSION — version string (default: "dev")
#
# Environment:
#   LLVM_LIB_PATH — path to LLVM lib directory
#                    (default: $HOME/llvm-20-native/lib)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="${1:-dev}"
LLVM_LIB_PATH="${LLVM_LIB_PATH:-$HOME/llvm-20-native/lib}"

# ---------------------------------------------------------------------------
# Detect platform
# ---------------------------------------------------------------------------

ARCH="$(uname -m)"
OS="$(uname -s)"

# Normalise OS name to lowercase
OS_LOWER="$(echo "$OS" | tr '[:upper:]' '[:lower:]')"

DIST_NAME="zap-${VERSION}-${ARCH}-${OS_LOWER}"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if ! command -v zig &>/dev/null; then
    echo "ERROR: 'zig' not found in PATH." >&2
    exit 1
fi

if [ ! -d "$LLVM_LIB_PATH" ]; then
    echo "ERROR: LLVM lib directory not found: $LLVM_LIB_PATH" >&2
    echo "       Set LLVM_LIB_PATH to the correct location." >&2
    exit 1
fi

if [ ! -f "$PROJECT_ROOT/build.zig" ]; then
    echo "ERROR: build.zig not found in project root: $PROJECT_ROOT" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the zap binary (ReleaseFast)
# ---------------------------------------------------------------------------

echo ">>> Building zap binary (ReleaseFast) ..."
echo "    LLVM_LIB_PATH: $LLVM_LIB_PATH"

cd "$PROJECT_ROOT"

zig build -Doptimize=ReleaseFast

ZAP_BIN="$PROJECT_ROOT/zig-out/bin/zap"

if [ ! -f "$ZAP_BIN" ]; then
    echo "ERROR: zap binary not found at $ZAP_BIN after build." >&2
    exit 1
fi

echo "    Binary built: $ZAP_BIN"

# ---------------------------------------------------------------------------
# Create distribution directory
# ---------------------------------------------------------------------------

DIST_DIR="$PROJECT_ROOT/dist/$DIST_NAME"

if [ -d "$DIST_DIR" ]; then
    echo ">>> Removing existing dist directory: $DIST_DIR"
    rm -rf "$DIST_DIR"
fi

mkdir -p "$DIST_DIR/bin"

echo ">>> Copying binary to $DIST_DIR/bin/zap"
cp "$ZAP_BIN" "$DIST_DIR/bin/zap"

# ---------------------------------------------------------------------------
# Bundle Zig lib
# ---------------------------------------------------------------------------

echo ">>> Bundling Zig standard library ..."
"$SCRIPT_DIR/bundle-lib.sh" "${ZIG_SRC:-$HOME/projects/zig}" "$DIST_DIR/lib/zig"

# ---------------------------------------------------------------------------
# Create tarball
# ---------------------------------------------------------------------------

TARBALL="$PROJECT_ROOT/dist/${DIST_NAME}.tar.gz"

echo ">>> Creating tarball: $TARBALL"
cd "$PROJECT_ROOT/dist"
tar czf "${DIST_NAME}.tar.gz" "$DIST_NAME"

# ---------------------------------------------------------------------------
# Distribution info
# ---------------------------------------------------------------------------

TARBALL_SIZE=$(du -h "$TARBALL" | cut -f1)
BIN_SIZE=$(du -h "$DIST_DIR/bin/zap" | cut -f1)

echo ""
echo ">>> Distribution complete."
echo "    Version:  $VERSION"
echo "    Arch:     $ARCH"
echo "    OS:       $OS_LOWER"
echo "    Binary:   $BIN_SIZE"
echo "    Tarball:  $TARBALL ($TARBALL_SIZE)"
echo "    Contents: $DIST_DIR/"
