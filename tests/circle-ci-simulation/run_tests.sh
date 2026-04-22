#!/bin/bash
# Main test runner

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo "CircleCI Simulation Tests"
echo "============================================"
echo ""

# Test 1: Cache hash generation
echo "=== Test 1: Cache Hash Generation ==="
"$SCRIPT_DIR/test_cache_hash.sh"
echo ""

# Test 2: Musl-cross-make skip (only if crossgcc exists)
echo "=== Test 2: Musl-Cross-Make Skip ==="
if [ -x "crossgcc/x86/bin/x86_64-linux-musl-gcc" ]; then
    "$SCRIPT_DIR/test_musl_skip.sh"
else
    echo "Skipping: crossgcc not found"
    echo "Run a full build first, then re-run tests"
fi
echo ""

echo "============================================"
echo "All tests complete"
echo "============================================"