#!/bin/bash

# Use the pinned digest from the repository file for reproducible builds
DOCKER_IMAGE="tlaurion/heads-dev-env"

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

# Validate that image is pinned to a digest (not an unpinned tag)
if [[ ! "${DOCKER_IMAGE}" =~ @sha256:[0-9a-f]{64} ]]; then
  echo "Error: Reproducible builds require pinned digest (@sha256:...), but got: $DOCKER_IMAGE" >&2
  exit 1
fi

# Extract digest for CircleCI validation
DIGEST=$(echo "$DOCKER_IMAGE" | sed 's/.*@//')
VERSION=$(grep '^# Version:' "$(dirname "$0")/docker/DOCKER_REPRO_DIGEST" 2>/dev/null | sed 's/# Version: //' | head -n1)
if [ -z "$VERSION" ]; then VERSION="unknown"; fi

# Cross-validate with .circleci/config.yml (use POSIX grep, not -P)
CIRCLECI_DIGEST=$(sed -n 's/.*tlaurion\/heads-dev-env@\([^ ]*\).*/\1/p' "$(dirname "$0")/.circleci/config.yml" | head -n1)
if [ -z "$CIRCLECI_DIGEST" ]; then
  echo "Warning: Could not find repro image digest in .circleci/config.yml" >&2
elif [ "$DIGEST" != "$CIRCLECI_DIGEST" ]; then
  echo "Error: Digest in resolved image ($DIGEST) does not match the digest used in .circleci/config.yml ($CIRCLECI_DIGEST)" >&2
  exit 1
fi
echo "Reproducible build (matched .circleci/config.yml): $DOCKER_IMAGE" >&2
echo "" >&2


# Only perform host-side side-effects when executed directly (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Ensure Docker CLI is available before attempting to run the container
  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: Docker is not installed or not in PATH. Please install Docker to use docker_repro.sh." >&2
    exit 127
  fi

  # Clean up host processes holding USB devices first (if applicable)
  kill_usb_processes
  run_docker "$DOCKER_IMAGE" "$@"
fi
