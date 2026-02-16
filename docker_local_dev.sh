#!/bin/bash

# Source shared docker helper functions
# shellcheck source=docker/common.sh
source "$(dirname "$0")/docker/common.sh"

#locally build docker name is linuxboot/heads:dev-env
DOCKER_IMAGE="linuxboot/heads:dev-env"

usage() {
  cat <<'USAGE'
Usage: ./docker_local_dev.sh [COMMAND...]

Run the local dev image (linuxboot/heads:dev-env). If flake.nix/flake.lock are dirty,
rebuilds the image first.

Environment:
  HEADS_SKIP_DOCKER_REBUILD=1   Skip rebuild even if flake files changed
  HEADS_CHECK_REPRODUCIBILITY=1 Compare local image ID to maintainer image
  HEADS_CHECK_REPRODUCIBILITY_REMOTE=...  Override remote image for the check
  HEADS_DISABLE_USB=1           Disable USB passthrough
  HEADS_X11_XAUTH=1             Force mounting ~/.Xauthority

Nix (only when rebuild is required):
  HEADS_AUTO_INSTALL_NIX=1      Auto-install Nix (requires HEADS_NIX_INSTALLER_SHA256)
  HEADS_NIX_INSTALLER_SHA256=...  Expected sha256 for the installer
  HEADS_NIX_INSTALLER_VERSION=...  Use a pinned Nix installer version
  HEADS_NIX_INSTALLER_URL=...   Override installer URL
  HEADS_AUTO_ENABLE_FLAKES=1    Auto-enable flakes in nix.conf
  HEADS_SKIP_DISK_CHECK=1       Skip disk preflight check
  HEADS_MIN_DISK_GB=...         Override disk free threshold (GB)

Examples:
  ./docker_local_dev.sh
  HEADS_CHECK_REPRODUCIBILITY=1 ./docker_local_dev.sh
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

trap 'echo "Script interrupted. Exiting..."; exit 1' SIGINT

# Inform the user succinctly about the Docker image being used
echo "Developer helper: ./docker_local_dev.sh (local image: linuxboot/heads:dev-env)"
echo "Rebuilds local image when flake.nix/flake.lock have uncommitted changes. Opt-out: HEADS_SKIP_DOCKER_REBUILD=1"
echo "For published images use: ./docker_latest.sh; for reproducible builds use: ./docker_repro.sh"
echo ""

# Ensure docker is available
require_docker || exit $?

# Rebuild the local image from flake.nix/flake.lock when uncommitted changes are present.
# Nix is only required if rebuild is needed; ensure_nix_and_flakes is called from _build_nix_docker_image.
# Opt-out with HEADS_SKIP_DOCKER_REBUILD=1
maybe_rebuild_local_image "$DOCKER_IMAGE"
echo "Using local dev image: $DOCKER_IMAGE" >&2

# Optional: verify reproducibility against docker.io latest
# Requires HEADS_CHECK_REPRODUCIBILITY=1 and either skopeo or curl installed
if [ "${HEADS_CHECK_REPRODUCIBILITY:-0}" = "1" ]; then
  compare_image_reproducibility "$DOCKER_IMAGE" || {
    echo "Note: Reproducibility check failed (expected if Nix versions or flake.lock differs from maintainer build)" >&2
  }
fi

# Only perform host-side side-effects when executed directly (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # If USB passthrough is possible, clean up host processes that may hold tokens (interactive abort allowed).
  kill_usb_processes

  # Execute the docker run command with the provided parameters
  # Delegate to shared run_docker so all docker_* scripts share identical device/X11/KVM handling
  run_docker "$DOCKER_IMAGE" "$@"
fi
