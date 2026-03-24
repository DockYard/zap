#!/bin/bash
set -euo pipefail

# Copy and strip Zig's lib/ directory for distribution.
#
# Usage: ./scripts/bundle-lib.sh [ZIG_SRC] [DEST]
#   ZIG_SRC — path to the Zig source tree   (default: $HOME/projects/zig)
#   DEST    — destination directory          (default: dist/lib/zig)

ZIG_SRC="${1:-$HOME/projects/zig}"
DEST="${2:-dist/lib/zig}"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

ZIG_LIB="$ZIG_SRC/lib"

if [ ! -d "$ZIG_LIB" ]; then
    echo "ERROR: Zig lib directory not found: $ZIG_LIB" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Clean previous output
# ---------------------------------------------------------------------------

if [ -d "$DEST" ]; then
    echo ">>> Removing existing destination: $DEST"
    rm -rf "$DEST"
fi

mkdir -p "$DEST"

# ---------------------------------------------------------------------------
# Copy essential directories
# ---------------------------------------------------------------------------

ESSENTIAL_DIRS=(std compiler_rt c libc include)

for dir in "${ESSENTIAL_DIRS[@]}"; do
    src="$ZIG_LIB/$dir"
    if [ -d "$src" ]; then
        echo ">>> Copying $dir/ ..."
        cp -a "$src" "$DEST/$dir"
    else
        echo "WARNING: directory not found, skipping: $src" >&2
    fi
done

# ---------------------------------------------------------------------------
# Copy root files
# ---------------------------------------------------------------------------

ROOT_FILES=(c.zig compiler_rt.zig)

for f in "${ROOT_FILES[@]}"; do
    src="$ZIG_LIB/$f"
    if [ -f "$src" ]; then
        echo ">>> Copying $f"
        cp -a "$src" "$DEST/$f"
    else
        echo "WARNING: root file not found, skipping: $src" >&2
    fi
done

# ---------------------------------------------------------------------------
# Strip test data files (.gz, .tar, .zst, .txt)
# ---------------------------------------------------------------------------

echo ">>> Stripping test data files (.gz, .tar, .zst, .txt) ..."

DATA_EXTENSIONS=("*.gz" "*.tar" "*.zst" "*.txt")
STRIPPED_DATA=0

for ext in "${DATA_EXTENSIONS[@]}"; do
    while IFS= read -r -d '' f; do
        rm -f "$f"
        STRIPPED_DATA=$((STRIPPED_DATA + 1))
    done < <(find "$DEST" -type f -name "$ext" -print0 2>/dev/null)
done

echo "    Removed $STRIPPED_DATA test data files."

# ---------------------------------------------------------------------------
# Blank out test .zig files in non-essential paths
#
# We look for *test*.zig files outside of the core std/, compiler_rt/, c/,
# libc/, and include/ trees that are clearly part of the runtime. Inside
# those trees we only blank files whose path contains a "test" directory
# component (e.g. std/testing/ is kept, but std/some/test/foo.zig is blanked).
# ---------------------------------------------------------------------------

echo ">>> Blanking test .zig files ..."

BLANKED=0

while IFS= read -r -d '' f; do
    # Skip files that are part of the standard library's own testing infra
    # (std/testing.zig, std/testing/*.zig) — those are needed at runtime.
    case "$f" in
        */std/testing.zig|*/std/testing/*) continue ;;
    esac

    : > "$f"
    BLANKED=$((BLANKED + 1))
done < <(find "$DEST" -type f -iname '*test*.zig' -print0 2>/dev/null)

echo "    Blanked $BLANKED test .zig files."

# ---------------------------------------------------------------------------
# Size summary
# ---------------------------------------------------------------------------

TOTAL_SIZE=$(du -sh "$DEST" | cut -f1)
FILE_COUNT=$(find "$DEST" -type f | wc -l | tr -d ' ')

echo ""
echo ">>> Bundle complete."
echo "    Destination:  $DEST"
echo "    Total size:   $TOTAL_SIZE"
echo "    Total files:  $FILE_COUNT"
