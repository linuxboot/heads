#!/bin/bash

# Extract the Docker image version from the CircleCI config file
DOCKER_IMAGE=$(grep -oP '^\s*-?\s*image:\s*\K(tlaurion/heads-dev-env:[^\s]+)' .circleci/config.yml | head -n 1)

# Check if the Docker image was found
if [ -z "$DOCKER_IMAGE" ]; then
  echo "Error: Docker image not found in .circleci/config.yml" >&2
  exit 1
fi

# Source shared docker helper functions (use the docker/ path where common.sh lives)
# shellcheck source=docker/common.sh
source "$(dirname "$0")/docker/common.sh"

# Resolve pinned digest (env var preferred, repository file fallback), and prompt if using unpinned :latest
DOCKER_IMAGE="$(resolve_docker_image "$DOCKER_IMAGE" "DOCKER_REPRO_DIGEST" "DOCKER_REPRO_DIGEST" "1")"
# If resolve_docker_image returned empty for any reason, abort
if [ -z "${DOCKER_IMAGE}" ]; then
  echo "Error: failed to resolve Docker image; aborting." >&2
  exit 1
fi


# Only perform host-side side-effects when executed directly (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Clean up host processes holding USB devices first (if applicable)
  kill_usb_processes
  run_docker "$DOCKER_IMAGE" "$@"
fi
