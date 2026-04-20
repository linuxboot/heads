#!/bin/bash
# Test cache key generation matches CircleCI behavior

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Testing Cache Hash Generation ==="

cd "$HEADS_ROOT"

# Create tmpDir in /tmp to simulate CircleCI behavior
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR"

# Generate hashes exactly like CircleCI does
echo "Generating musl-cross-make hash..."
find ./flake.lock modules/musl-cross-make* -type f | sort -h | xargs sha256sum > "$TMPDIR/musl-cross-make.sha256sums"

echo "Generating all modules hash..."
find ./Makefile ./flake.lock ./patches/ ./modules/ -type f | sort -h | xargs sha256sum > "$TMPDIR/all_modules_and_patches.sha256sums"

echo "Generating coreboot+musl hash..."
find ./flake.lock ./modules/coreboot ./modules/musl-cross-make* ./patches/coreboot* -type f | sort -h | xargs sha256sum > "$TMPDIR/coreboot_musl-cross-make.sha256sums"

echo ""
echo "=== Generated Hashes (in $TMPDIR) ==="
echo ""
echo "musl-cross-make.sha256sums:"
cat "$TMPDIR/musl-cross-make.sha256sums"
echo ""
echo "all_modules_and_patches.sha256sums (first 3 lines):"
head -3 "$TMPDIR/all_modules_and_patches.sha256sums"
echo ""
echo "coreboot_musl-cross-make.sha256sums:"
cat "$TMPDIR/coreboot_musl-cross-make.sha256sums"

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "=== NOTE: CircleCI uses these hashes to construct cache keys ==="
echo "Key format: {arch}-{layer}-nix-docker-heads-{hash}-{CACHE_VERSION}"
echo "CACHE_VERSION is set in CircleCI project settings"