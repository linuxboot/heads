#!/bin/bash

# Extract the Docker image version from the CircleCI config file
DOCKER_IMAGE=$(grep -oP '^\s*-?\s*image:\s*\K(tlaurion/heads-dev-env:[^\s]+)' .circleci/config.yml | head -n 1)

# Check if the Docker image was found
if [ -z "$DOCKER_IMAGE" ]; then
	echo "Error: Docker image not found in .circleci/config.yml"
	exit 1
fi

# Inform the user about the versioned CircleCI Docker image being used
echo "Using CircleCI Docker image: $DOCKER_IMAGE"

# Source shared docker helper functions
source "$(dirname "$0")/common.sh"

# Inform the user about entering the Docker container
echo "----"
echo "Usage reminder: The minimal command is 'make BOARD=XYZ', where additional options, including 'V=1' or 'CPUS=N' are optional."
echo "For more advanced QEMU testing options, refer to targets/qemu.md and boards/qemu-*/*.config."
echo
echo "Type exit within docker image to get back to host if launched interactively!"
echo "----"
echo

# Execute the docker run command with the provided parameters
if [ -d "/dev/bus/usb" ]; then
	echo "--->Launching container with access to host's USB buses (some USB devices were connected to host)..."
	docker run --device=/dev/bus/usb:/dev/bus/usb -e DISPLAY=$DISPLAY --network host --rm -ti -v $(pwd):$(pwd) -w $(pwd) $DOCKER_IMAGE -- "$@"
else
	echo "--->Launching container without access to host's USB buses (no USB devices was connected to host)..."
	docker run -e DISPLAY=$DISPLAY --network host --rm -ti -v $(pwd):$(pwd) -w $(pwd) $DOCKER_IMAGE -- "$@"
fi
