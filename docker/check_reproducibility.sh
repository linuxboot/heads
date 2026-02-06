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
  - docker CLI (required; to inspect local images and perform pulls)
  - Recommended (optional): `skopeo` (preferred for manifest inspection without pulling), `jq` + `curl` (fallback to query Docker Hub API). If these are missing the script will fall back to `docker pull` which may download large image layers.
  - Network access (to pull remote images or query registries)

USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

# Ensure docker is available
if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker not found in PATH" >&2
  exit 127
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

# Capture local RepoDigest (if any) and image ID for fallback comparisons
local_repo_digest=""
local_repo_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${local_image}" 2>/dev/null | cut -d'@' -f2 || true)
local_image_id=""
local_image_id=$(docker inspect --format='{{.Id}}' "${local_image}" 2>/dev/null || true)

echo "" >&2

# Get remote image digest
echo "Fetching remote image digest from: ${remote_image}" >&2

# Remote inspection strategy (in order of preference):
# 1) `skopeo inspect` (no full download)
# 2) Docker Hub API via `curl`+`jq` (for docker.io refs)
# 3) `docker pull` as a last resort (may download large layers)

remote_manifest_digest=""
remote_repo_digest=""
remote_image_id=""
remote_digest=""

# 1) skopeo (preferred)
if command -v skopeo >/dev/null 2>&1; then
  echo "  Attempting 'skopeo inspect' for ${remote_image} (no pull required)..." >&2
  remote_manifest_digest=$(skopeo inspect "docker://${remote_image}" 2>/dev/null | grep -o '"Digest":"[^" ]*' | head -n1 | cut -d'"' -f4 || true)
  if [ -n "${remote_manifest_digest}" ]; then
    echo "  Found manifest digest (skopeo): ${remote_manifest_digest}" >&2
  fi
fi

# 2) Docker Hub API (fallback, only for docker.io-style hosts)
if [ -z "${remote_manifest_digest}" ] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  echo "  Attempting Docker Hub API for ${remote_image} (requires jq)..." >&2
  repo_with_tag="${remote_image}"
  tag="${repo_with_tag##*:}"
  repo_path="${repo_with_tag%:*}"
  repo_path="${repo_path#docker.io/}"
  repo_path="${repo_path#registry-1.docker.io/}"
  remote_manifest_digest=$(curl -fsSL "https://hub.docker.com/v2/repositories/${repo_path}/tags/${tag}/" 2>/dev/null | jq -r '.digest // empty' || true)
  if [ -n "${remote_manifest_digest}" ]; then
    echo "  Found manifest digest (Docker Hub API): ${remote_manifest_digest}" >&2
  fi
fi

# If we have a manifest digest and the local image exposes a RepoDigest, compare those
if [ -n "${remote_manifest_digest}" ]; then
  remote_digest="${remote_manifest_digest}"
  if [ -n "${local_repo_digest}" ]; then
    if [ "${local_repo_digest##*:}" = "${remote_manifest_digest##*:}" ]; then
      echo "✓ SUCCESS: Manifest digest match (no pull required)" >&2
      echo "=== End Reproducibility Check ===" >&2
      echo "" >&2
      exit 0
    else
      echo "Manifest digest mismatch: local ${local_repo_digest##*:} vs remote ${remote_manifest_digest##*:}" >&2
      echo "Falling back to docker pull to compare image IDs..." >&2
    fi
  fi
fi

# 3) Final fallback: pull the image locally to inspect RepoDigest/image ID
echo "  Pulling image locally to inspect (progress will be shown)..." >&2
if docker pull "${remote_image}" 2>&1 | sed -u 's/^/    /'; then
  remote_repo_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${remote_image}" 2>/dev/null || true)
  if [ -n "${remote_repo_digest}" ]; then
    remote_repo_digest="${remote_repo_digest##*@}"
    echo "  Found remote RepoDigest: ${remote_repo_digest}" >&2
    remote_digest="${remote_repo_digest}"
  fi
  remote_image_id=$(docker inspect --format='{{.Id}}' "${remote_image}" 2>/dev/null || true)
  if [ -n "${remote_image_id}" ]; then
    echo "  Found remote image ID: ${remote_image_id}" >&2
    if [ -z "${remote_digest}" ]; then
      remote_digest="${remote_image_id}"
    fi
  fi
else
  echo "Error: Could not pull remote image '${remote_image}'" >&2
  exit 1
fi


# Decide comparison mode and values based on available identifiers
# Prefer manifest digest comparison when both sides have RepoDigest available
comparison_left=""
comparison_right=""
comparison_desc=""
if [ -n "${local_repo_digest}" ] && [ -n "${remote_repo_digest}" ]; then
  comparison_left="${local_repo_digest##*:}"
  comparison_right="${remote_repo_digest##*:}"
  comparison_desc="manifest digest"
elif [ -n "${local_image_id}" ] && [ -n "${remote_image_id}" ]; then
  comparison_left="${local_image_id##*:}"
  comparison_right="${remote_image_id##*:}"
  comparison_desc="image ID"
elif [ -n "${local_repo_digest}" ] && [ -n "${remote_image_id}" ]; then
  # Local has manifest digest but remote only has image ID - fall back to comparing image IDs if possible
  comparison_left="${local_digest_hex}"
  comparison_right="${remote_image_id##*:}"
  comparison_desc="mixed (local manifest vs remote image ID)"
else
  # As a last resort, compare local image ID with remote manifest/image id normalized value
  comparison_left="${local_digest_hex}"
  comparison_right="${remote_digest##*:}"
  comparison_desc="best-effort"
fi

# Print comparison summary
echo "" >&2
echo "=== Comparison ===" >&2
echo "Local:  ${local_image}" >&2
echo "        ${comparison_left}  (${comparison_desc})" >&2
echo "" >&2
echo "Remote: ${remote_image}" >&2
echo "        ${comparison_right}  (${comparison_desc})" >&2
echo "" >&2

# Compare and report
if [ "${comparison_left}" = "${comparison_right}" ]; then
  echo "✓ SUCCESS: ${comparison_desc^} match!" >&2
  echo "  Your local build is reproducible and identical to ${remote_image} (matched by ${comparison_desc})." >&2
  echo "" >&2
  exit 0
else
  echo "✗ MISMATCH: ${comparison_desc^} differ" >&2
  echo "" >&2
  echo "This may be expected if:" >&2
  echo "  - Nix/flake.lock versions differ from the remote build" >&2
  echo "  - There are uncommitted changes in flake.nix" >&2
  echo "  - Different Nix dependencies are resolved locally vs remotely" >&2
  echo "" >&2
  # Provide helpful hints
  if [ "${comparison_desc}" = "manifest digest" ]; then
    echo "Hint: local build has a different manifest digest; ensure flake.lock matches the one used to build the published image." >&2
  else
    echo "Hint: comparing by image ID or best-effort. If you intended exact manifest matching, ensure the local image has a RepoDigest (pull the published image) before comparing." >&2
  fi
  echo "" >&2
  exit 1
fi

