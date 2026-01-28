#!/bin/bash

# Inform the user that the latest published Docker image is being used
echo "Using the latest Docker image: tlaurion/heads-dev-env:latest"
DOCKER_IMAGE="tlaurion/heads-dev-env:latest"

# Source shared docker helper functions
source "$(dirname "$0")/docker/common.sh"


# Execute the docker run command with the provided parameters
if [ -d "/dev/bus/usb" ]; then
	echo "--->Launching container with access to host's USB buses (some USB devices were connected to host)..."
	docker run --device=/dev/bus/usb:/dev/bus/usb -e DISPLAY=$DISPLAY --network host --rm -ti -v $(pwd):$(pwd) -w $(pwd) $DOCKER_IMAGE -- "$@"
else
	echo "--->Launching container without access to host's USB buses (no USB devices was connected to host)..."
	docker run -e DISPLAY=$DISPLAY --network host --rm -ti -v $(pwd):$(pwd) -w $(pwd) $DOCKER_IMAGE -- "$@"
fi
