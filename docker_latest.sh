#!/bin/bash

# Inform the user that the latest published Docker image is being used
echo "Using the latest Docker image: tlaurion/heads-dev-env:latest"
DOCKER_IMAGE="tlaurion/heads-dev-env:latest"

# Function to display usage information
usage() {
	echo "Usage: $0 [OPTIONS] -- [COMMAND]"
	echo "Options:"
	echo "  CPUS=N  Set the number of CPUs"
	echo "  V=1     Enable verbose mode"
	echo "Command:"
	echo "  The command to run inside the Docker container, e.g., make BOARD=BOARD_NAME"
}

# Function to kill GPG toolstack related processes using USB devices
kill_usb_processes() {
	# check if scdaemon or pcscd processes are using USB devices
	if [ -d /dev/bus/usb ]; then
		if sudo lsof /dev/bus/usb/00*/0* 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r ps -p | grep -E 'scdaemon|pcscd' >/dev/null; then
			echo "Killing GPG toolstack related processes using USB devices..."
			sudo lsof /dev/bus/usb/00*/0* 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r ps -p | grep -E 'scdaemon|pcscd' | awk '{print $1}' | xargs -r sudo kill -9
		fi
	fi
}

# Handle Ctrl-C (SIGINT) to exit gracefully
trap "echo 'Script interrupted. Exiting...'; exit 1" SIGINT

# Check if --help or -h is provided
for arg in "$@"; do
	if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
		usage
		exit 0
	fi
done

# Kill processes using USB devices
kill_usb_processes

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
