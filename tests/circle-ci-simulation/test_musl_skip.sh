#!/bin/bash
# Test that musl-cross-make skips rebuild when crossgcc exists

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Testing Musl-Cross-Make Skip Logic ==="

cd "$HEADS_ROOT"

# Check if crossgcc exists
CROSSGCC_BIN="crossgcc/x86/bin/x86_64-linux-musl-gcc"

if [ -x "$CROSSGCC_BIN" ]; then
    echo "✓ crossgcc exists: $CROSSGCC_BIN"

    # Run make with musl-cross-make target
    echo ""
    echo "Running: make BOARD=novacustom-nv4x_adl musl-cross-make"
    echo ""

    output=$(make BOARD=novacustom-nv4x_adl musl-cross-make 2>&1)

    echo "$output"

    if echo "$output" | grep -q "Nothing to be done"; then
        echo ""
        echo "✓ TEST PASSED: musl-cross-make skipped (cache hit)"
        exit 0
    elif echo "$output" | grep -q "Using .*gcc"; then
        echo ""
        echo "✓ TEST PASSED: using existing compiler"
        exit 0
    else
        echo ""
        echo "✗ TEST FAILED: musl-cross-make rebuilt when crossgcc exists"
        exit 1
    fi
else
    echo "✗ crossgcc not found: $CROSSGCC_BIN"
    echo "Cannot test skip logic - build from scratch instead"
    echo ""
    echo "Run ./simulate_cold_cache.sh first to ensure build completes"
    exit 1
fi