#!/bin/bash

# Determine an initial Docker image (allow override via DOCKER_LATEST_IMAGE)
DOCKER_IMAGE="${DOCKER_LATEST_IMAGE:-tlaurion/heads-dev-env:latest}"

# Source shared docker helper functions
# shellcheck source=docker/common.sh
source "$(dirname "$0")/docker/common.sh"

# Resolve pinned digest (env var preferred, repository file fallback), and prompt if using unpinned :latest
DOCKER_IMAGE="$(resolve_docker_image "$DOCKER_IMAGE" "DOCKER_LATEST_DIGEST" "DOCKER_LATEST_DIGEST" "1")"
# If resolve_docker_image returned empty for any reason, abort
if [ -z "${DOCKER_IMAGE}" ]; then
  echo "Error: failed to resolve Docker image; aborting." >&2
  exit 1
fi

# Check if Docker is installed
if ! command -v docker >/dev/null 2>&1; then
	echo "Error: Docker is not installed or not in PATH. Install Docker to use this script." >&2
	exit 1
fi

# Only perform host-side side-effects when executed directly (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Clean up host processes holding USB devices first (if applicable)
  kill_usb_processes

  # Execute the docker run command with the provided parameters
  # Delegate to shared run_docker so all docker_* scripts share identical device/X11/KVM handling
  run_docker "$DOCKER_IMAGE" "$@"
fi
