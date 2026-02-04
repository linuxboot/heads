#!/bin/bash

#locally build docker name is linuxboot/heads:dev-env
DOCKER_IMAGE="linuxboot/heads:dev-env"

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
	echo "Docker is not installed or not in the PATH. Please install Docker before running this script."
	echo "Refer to the README.md at the root of the repository for installation instructions."
	exit 1
fi

# Inform the user succinctly about the Docker image being used
echo "Developer helper: ./docker_local_dev.sh (local image: linuxboot/heads:dev-env)"
echo "Rebuilds local image when flake.nix/flake.lock have uncommitted changes. Opt-out: HEADS_SKIP_DOCKER_REBUILD=1"
echo "For published images use: ./docker_latest.sh; for reproducible builds use: ./docker_repro.sh"
echo ""

# Source shared docker helper functions
# shellcheck source=docker/common.sh
source "$(dirname "$0")/docker/common.sh"

# Ensure Nix and flakes are present and enabled (prompt/install if needed)
ensure_nix_and_flakes || { echo "Nix and flakes are required for docker local development; aborting." >&2; exit 1; }

# Rebuild the local image from flake.nix/flake.lock when uncommitted changes are present.
# Opt-out with HEADS_SKIP_DOCKER_REBUILD=1
maybe_rebuild_local_image "$DOCKER_IMAGE"

# Only perform host-side side-effects when executed directly (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # If USB passthrough is possible, clean up host processes that may hold tokens (interactive abort allowed).
  kill_usb_processes

  # Execute the docker run command with the provided parameters
  # Delegate to shared run_docker so all docker_* scripts share identical device/X11/KVM handling
  run_docker "$DOCKER_IMAGE" "$@"
fi
