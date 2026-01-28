#!/bin/bash

#locally build docker name is linuxboot/heads:dev-env
DOCKER_IMAGE="linuxboot/heads:dev-env"

# Check if Nix is installed
if ! command -v nix &>/dev/null; then
	echo "Nix is not installed or not in the PATH. Please install Nix before running this script."
	echo "Refer to the README.md at the root of the repository for installation instructions."
	exit 1
fi

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
	echo "Docker is not installed or not in the PATH. Please install Docker before running this script."
	echo "Refer to the README.md at the root of the repository for installation instructions."
	exit 1
fi

# Inform the user about the Docker image being used
echo "!!! This ./docker_local_dev.sh script is for developers usage only. !!!"
echo ""
echo "Using the last locally built Docker image when flake.nix/flake.lock was modified and repo was dirty: linuxboot/heads:dev-env"
echo "!!! Warning: Using anything other than the published Docker image might lead to non-reproducible builds. !!!"
echo ""
echo "For using the latest published Docker image, refer to ./docker_latest.sh."
echo "For producing reproducible builds as CircleCI, refer to ./docker_repro.sh."
echo ""

# Source shared docker helper functions
source "$(dirname "$0")/docker/common.sh"

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
