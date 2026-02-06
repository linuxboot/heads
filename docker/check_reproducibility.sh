#!/bin/bash
# Helper to compare local Docker image digest with remote docker.io
# Usage: ./docker/check_reproducibility.sh [local_image] [remote_image]
# Example:
#   ./docker/check_reproducibility.sh linuxboot/heads:dev-env tlaurion/heads-dev-env:latest

set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage: $0 [local_image] [remote_image]

Compare a local Docker image digest with a remote docker.io image.

Arguments:
  local_image   Local image to check (default: linuxboot/heads:dev-env)
  remote_image  Remote docker.io image to compare against (default: ${HEADS_MAINTAINER_DOCKER_IMAGE}:latest, where HEADS_MAINTAINER_DOCKER_IMAGE defaults to tlaurion/heads-dev-env)

Environment:
  HEADS_MAINTAINER_DOCKER_IMAGE  Override the canonical maintainer's image repository (default: tlaurion/heads-dev-env)

Examples:
  ./docker/check_reproducibility.sh
  ./docker/check_reproducibility.sh linuxboot/heads:dev-env tlaurion/heads-dev-env:latest
  ./docker/check_reproducibility.sh linuxboot/heads:dev-env tlaurion/heads-dev-env:v0.2.7
  HEADS_MAINTAINER_DOCKER_IMAGE="myuser/heads-dev-env" ./docker/check_reproducibility.sh

Requirements:
  - docker CLI (to inspect local images)
  - Network access (to pull remote images for digest comparison)

USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

# Respect HEADS_MAINTAINER_DOCKER_IMAGE environment variable for fork maintainers
HEADS_MAINTAINER_DOCKER_IMAGE="${HEADS_MAINTAINER_DOCKER_IMAGE:-tlaurion/heads-dev-env}"

local_image="${1:-linuxboot/heads:dev-env}"
remote_image="${2:-${HEADS_MAINTAINER_DOCKER_IMAGE}:latest}"

echo "=== Docker Image Reproducibility Check ===" >&2
echo "" >&2

# Get local image digest
echo "Fetching local image digest from: ${local_image}" >&2
local_digest=$(docker inspect --format='{{.Id}}' "${local_image}" 2>/dev/null || true)
if [ -z "${local_digest}" ]; then
  echo "Error: Local image '${local_image}' not found" >&2
  exit 1
fi

# Normalize to just the hex part
local_digest_hex="${local_digest##*:}"
echo "  Found: ${local_digest}" >&2
echo "" >&2

# Get remote image digest
echo "Fetching remote image digest from: ${remote_image}" >&2

# Try skopeo first (if available, doesn't require full image pull)
# For comparison, both local and remote must use image ID (not manifest digest)
remote_digest=""
if command -v skopeo >/dev/null 2>&1; then
  echo "  Attempting with skopeo to check manifest..." >&2
  # Skopeo returns manifest digest; for consistent comparison, fall through to docker pull
  # which gives us the image ID (same format as local docker inspect)
fi

# Pull the image and inspect it locally for image ID
if [ -z "${remote_digest}" ]; then
  echo "  Pulling image locally to inspect..." >&2
  if docker pull "${remote_image}" >/dev/null 2>&1; then
    remote_digest=$(docker inspect --format='{{.Id}}' "${remote_image}" 2>/dev/null || true)
    if [ -n "${remote_digest}" ]; then
      echo "  Found: ${remote_digest}" >&2
    fi
  else
    echo "Error: Could not pull remote image '${remote_image}'" >&2
    exit 1
  fi
fi

if [ -z "${remote_digest}" ]; then
  echo "Error: Failed to retrieve remote digest" >&2
  exit 1
fi

# Normalize to just the hex part
remote_digest_hex="${remote_digest##*:}"

echo "" >&2
echo "=== Comparison ===" >&2
echo "Local:  ${local_image}" >&2
echo "        ${local_digest_hex}" >&2
echo "" >&2
echo "Remote: ${remote_image}" >&2
echo "        ${remote_digest_hex}" >&2
echo "" >&2

# Compare
if [ "${local_digest_hex}" = "${remote_digest_hex}" ]; then
  echo "✓ SUCCESS: Digests match!" >&2
  echo "  Your local build is reproducible and identical to ${remote_image}" >&2
  echo "" >&2
  exit 0
else
  echo "✗ MISMATCH: Digests differ" >&2
  echo "" >&2
  echo "This is expected if:" >&2
  echo "  - Nix/flake.lock versions differ from the remote build" >&2
  echo "  - There are uncommitted changes in flake.nix" >&2
  echo "  - Different Nix dependencies are resolved locally vs remotely" >&2
  echo "" >&2
  exit 1
fi

