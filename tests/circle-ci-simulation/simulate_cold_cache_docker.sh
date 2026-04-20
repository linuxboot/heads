#!/bin/bash
# Proper cold cache simulation - needs docker for clean environment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Cold Cache Simulation (using Docker) ==="
echo "This runs in clean container to simulate first CircleCI run"
echo ""

cd "$HEADS_ROOT"

# Run a clean build in docker - this simulates cold cache
echo "Running cold cache build in docker..."
docker run --rm -i --device=/dev/kvm \
  -v /home/user/heads-master:/home/user/heads-master \
  -w /home/user/heads-master \
  tlaurion/heads-dev-env@sha256:96f8f91c6464305c4a990d59f9ef93910c16c7fd0501a46b43b34a4600a368de \
  bash -c 'make BOARD=novacustom-nv4x_adl musl-cross-make 2>&1' | tee /tmp/cold_build.log

echo ""
echo "=== Cold Build Results ==="
grep -E "CONFIG musl-cross-make|MAKE musl-cross-make|DONE musl-cross-make|Using.*gcc" /tmp/cold_build.log || echo "Check /tmp/cold_build.log"

echo ""
echo "=== Second Run (warm cache) ==="
echo "Running again with build artifacts present..."
docker run --rm -i --device=/dev/kvm \
  -v /home/user/heads-master:/home/user/heads-master \
  -w /home/user/heads-master \
  tlaurion/heads-dev-env@sha256:96f8f91c6464305c4a990d59f9ef93910c16c7fd0501a46b43b34a4600a368de \
  make BOARD=novacustom-nv4x_adl musl-cross-make 2>&1 | tee /tmp/warm_build.log

echo ""
echo "=== Warm Build Results ==="
grep -E "Using.*gcc|Nothing to be done for 'musl-cross-make'" /tmp/warm_build.log && echo "✓ CACHE WORKS!" || echo "✗ Cache failed"