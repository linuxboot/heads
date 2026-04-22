#!/bin/bash
# Simulate cache invalidation by changing hash files
# This mimics what happens when .circleci/config.yml was in the hash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Simulating Cache Invalidation ==="
echo "This modifies hash files to force cache miss (like config change)"
echo ""

cd "$HEADS_ROOT"

# Backup existing hashes
mkdir -p tmpDir
if [ -f tmpDir/musl-cross-make.sha256sums ]; then
    cp tmpDir/musl-cross-make.sha256sums tmpDir/musl-cross-make.sha256sums.bak
fi

# Modify hash by adding a comment (changes hash value)
echo "# CACHE_INVALIDATED" >> tmpDir/musl-cross-make.sha256sums

echo "Modified musl-cross-make hash file"
echo "New hash content:"
cat tmpDir/musl-cross-make.sha256sums
echo ""

# Now run make - should rebuild because key changed
echo "=== Running make with invalidated cache key ==="
echo "Expected: Full rebuild (cache miss)"
echo ""

if [ -x crossgcc/x86/bin/x86_64-linux-musl-gcc ]; then
    echo "Note: crossgcc exists but hash changed - will rebuild"
    echo "Running: make BOARD=novacustom-nv4x_adl musl-cross-make"
    
    output=$(make BOARD=novacustom-nv4x_adl musl-cross-make 2>&1 | tail -20)
    echo "$output"
    
    if echo "$output" | grep -q "CONFIG musl-cross-make"; then
        echo ""
        echo "✓ REBUILT as expected (cache invalidation worked)"
    fi
fi

# Restore original hash
if [ -f tmpDir/musl-cross-make.sha256sums.bak ]; then
    mv tmpDir/musl-cross-make.sha256sums.bak tmpDir/musl-cross-make.sha256sums
    echo ""
    echo "Restored original hash file"
fi