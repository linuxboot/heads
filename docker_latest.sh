#!/bin/bash
#
# Run Heads build in Docker using the latest published image
# This is suitable for development and testing with the most up-to-date environment
#

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly DOCKER_IMAGE="tlaurion/heads-dev-env:latest"

# ============================================================================
# FUNCTIONS
# ============================================================================

usage() {
	cat << EOF
Usage: $0 [OPTIONS] -- [COMMAND]

Options:
  CPUS=N              Set the number of CPUs
  V=1                 Enable verbose mode
  -h, --help          Display this help message

Command:
  The command to run inside the Docker container (e.g., make BOARD=BOARD_NAME)

Examples:
  $0 make BOARD=qemu-coreboot-fbwhiptail-tpm2
  $0 make BOARD=t440p V=1

For more advanced QEMU testing options, refer to targets/qemu.md and boards/qemu-*/*.config
EOF
}

# Kill GPG toolstack related processes using USB devices
kill_usb_processes() {
	if [ ! -d "/dev/bus/usb" ]; then
		return 0
	fi

	if sudo lsof /dev/bus/usb/00*/0* 2>/dev/null | \
	   awk 'NR>1 {print $2}' | \
	   xargs -r ps -p | \
	   grep -E 'scdaemon|pcscd' >/dev/null 2>&1; then
		echo "Killing GPG toolstack related processes using USB devices..."
		sudo lsof /dev/bus/usb/00*/0* 2>/dev/null | \
			awk 'NR>1 {print $2}' | \
			xargs -r ps -p | \
			grep -E 'scdaemon|pcscd' | \
			awk '{print $1}' | \
			xargs -r sudo kill -9
	fi
}

# Build Docker run options based on available host capabilities
build_docker_opts() {
	local opts="-e DISPLAY=${DISPLAY} --network host --rm -ti"

	# Add USB device if available
	if [ -d "/dev/bus/usb" ]; then
		opts="${opts} --device=/dev/bus/usb:/dev/bus/usb"
		echo "--->Launching container with access to host's USB buses..." >&2
	else
		echo "--->Launching container without access to host's USB buses..." >&2
	fi

	# Add KVM device if available
	if [ -e "/dev/kvm" ]; then
		opts="${opts} --device=/dev/kvm:/dev/kvm"
	fi

	# Add X11 display support
	opts="${opts} -v /tmp/.X11-unix:/tmp/.X11-unix"

	# Add Xauthority if it exists
	if [ -f "${HOME}/.Xauthority" ]; then
		opts="${opts} -v ${HOME}/.Xauthority:/root/.Xauthority:ro"
	fi

	echo "${opts}"
}

# ============================================================================
# MAIN
# ============================================================================

# Handle help request
for arg in "$@"; do
	if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
		usage
		exit 0
	fi
done

echo "Using the latest Docker image: ${DOCKER_IMAGE}"

# Handle Ctrl-C gracefully
trap "echo 'Script interrupted. Exiting...'; exit 130" SIGINT

# Kill processes using USB devices
kill_usb_processes

# Display usage information
cat << EOF

----
Usage reminder: The minimal command is 'make BOARD=XYZ', where additional
options, including 'V=1' or 'CPUS=N' are optional.

For more advanced QEMU testing options, refer to:
  - targets/qemu.md
  - boards/qemu-*/*.config

Type 'exit' within the Docker container to return to the host.
----

EOF

# Build Docker options and execute
DOCKER_RUN_OPTS=$(build_docker_opts)

# shellcheck disable=SC2086
exec docker run ${DOCKER_RUN_OPTS} -v "$(pwd):$(pwd)" -w "$(pwd)" "${DOCKER_IMAGE}" -- "$@"
