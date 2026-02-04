#!/bin/bash

# Source shared docker helper functions
# shellcheck source=docker/common.sh
source "$(dirname "$0")/docker/common.sh"

# Determine an initial Docker image (allow override via DOCKER_LATEST_IMAGE)
DOCKER_IMAGE="${DOCKER_LATEST_IMAGE:-tlaurion/heads-dev-env:latest}"

usage() {
  cat <<'USAGE'
Usage: ./docker_latest.sh [COMMAND...]

Run the maintainer "latest" image (or a pinned digest if configured).

Environment:
  DOCKER_LATEST_IMAGE=...       Override the image/tag to run
  DOCKER_LATEST_DIGEST=...      Pin to a specific digest (sha256:...)
  HEADS_ALLOW_UNPINNED_LATEST=1 Allow unpinned :latest without prompting
  HEADS_DISABLE_USB=1           Disable USB passthrough
  HEADS_X11_XAUTH=1             Force mounting ~/.Xauthority

Examples:
  ./docker_latest.sh
  DOCKER_LATEST_DIGEST=sha256:... ./docker_latest.sh
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

trap 'echo "Script interrupted. Exiting..."; exit 1' SIGINT

# Resolve pinned digest (env var preferred, repository file fallback), and prompt if using unpinned :latest
DOCKER_IMAGE="$(resolve_docker_image "$DOCKER_IMAGE" "DOCKER_LATEST_DIGEST" "DOCKER_LATEST_DIGEST" "1")"
# If resolve_docker_image returned empty for any reason, abort
if [ -z "${DOCKER_IMAGE}" ]; then
  echo "Error: failed to resolve Docker image; aborting." >&2
  exit 1
fi
echo "Using latest image: $DOCKER_IMAGE" >&2
echo "" >&2

# Only perform host-side side-effects when executed directly (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  require_docker || exit $?
  # Clean up host processes holding USB devices first (if applicable)
  kill_usb_processes

  # Execute the docker run command with the provided parameters
  # Delegate to shared run_docker so all docker_* scripts share identical device/X11/KVM handling
  run_docker "$DOCKER_IMAGE" "$@"
fi
