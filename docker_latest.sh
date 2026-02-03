#!/bin/bash

# Inform the user that the latest published Docker image is being used
echo "Using the latest Docker image: tlaurion/heads-dev-env:latest"
DOCKER_IMAGE="tlaurion/heads-dev-env:latest"
# Check if Docker is installed
if ! command -v docker >/dev/null 2>&1; then
	echo "Error: Docker is not installed or not in PATH. Install Docker to use this script." >&2
	exit 1
fi

# Source shared docker helper functions
source "$(dirname "$0")/docker/common.sh"


# Execute the docker run command with the provided parameters
# Delegate to shared run_docker so all docker_* scripts share identical device/X11/KVM handling
run_docker "$DOCKER_IMAGE" "$@"
