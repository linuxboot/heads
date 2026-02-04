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

echo "=== Docker Image Reproducibility Check ===" >&2
# Source shared helpers and delegate to centralized reproducibility checker
# shellcheck source=docker/common.sh
source "$(dirname "$0")/common.sh"
# Ensure docker is available
require_docker || exit $?
# Resolve local and remote images (remote uses shared defaulting logic)
local_image="${1:-linuxboot/heads:dev-env}"
remote_image=$(resolve_repro_remote_image "${2:-}")
# Delegate to the refactored checker which prefers image ID / config digest comparison
compare_image_reproducibility "${local_image}" "${remote_image}"
exit $? 

