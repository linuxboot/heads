#!/bin/bash
# Simulates cold cache by removing build artifacts

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Simulating Cold Cache ==="
echo "This removes build artifacts to simulate first CircleCI run"

# Check if we have sudo/root for install cleanup
if [ "$(id -u)" -ne 0 ]; then
    echo "Warning: Not running as root. Install directory may have permission issues."
fi

cd "$HEADS_ROOT"

# Remove musl-cross-make build artifacts
echo "Removing musl-cross-make build artifacts..."
rm -rf build/x86/musl-cross-make-* 2>/dev/null || true

# Remove crossgcc (compiler tree)
echo "Removing crossgcc..."
rm -rf crossgcc/x86 2>/dev/null || true

# Remove install (sysroot)
echo "Removing install..."
if [ "$(id -u)" -eq 0 ]; then
    rm -rf install/x86 2>/dev/null || true
else
    echo "Warning: Skipping install/ (need root for owned-by-root files)"
fi

# Remove packages
echo "Removing packages..."
rm -rf packages/x86 2>/dev/null || true

echo "=== Cold cache simulation complete ==="
echo "Next 'make' will rebuild everything from scratch"