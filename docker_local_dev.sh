#!/bin/bash
#
# Run Heads build in Docker using locally built image from flake.nix
# This is for developers only - uses the local flake.nix/flake.lock to build the Docker image
# WARNING: This may produce non-reproducible builds compared to the published images
#

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly DOCKER_IMAGE="linuxboot/heads:dev-env"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Check if required commands are available
check_requirements() {
	local cmd
	for cmd in nix docker; do
		if ! command -v "${cmd}" &>/dev/null; then
			echo "Error: '${cmd}' is not installed or not in PATH" >&2
			echo "Please refer to the README.md at the root of the repository for installation instructions." >&2
			return 1
		fi
	done
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

# Build Docker image if flake.nix or flake.lock have uncommitted changes
rebuild_docker_image() {
	if [ -z "$(git status --porcelain | grep -E 'flake\.nix|flake\.lock')" ]; then
		echo "Git repository is clean. Using the previously built Docker image."
		sleep 1
		return 0
	fi

	cat << EOF
**Warning: Uncommitted changes detected in flake.nix or flake.lock.**
The Docker image will be rebuilt. If this was not intended, please Ctrl-C now,
commit your changes, and rerun this script.

EOF

	sleep 2

	echo "Building the Docker image from flake.nix..."
	nix --extra-experimental-features nix-command --extra-experimental-features flakes \
		--print-build-logs --verbose develop --ignore-environment --command true
	nix --extra-experimental-features nix-command --extra-experimental-features flakes \
		--print-build-logs --verbose build .#dockerImage && docker load <result
}

# Ensure local dev image exists; if not, guide user and build it
ensure_local_image() {
	if ! docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1; then
		cat << EOF
The local developer Docker image '${DOCKER_IMAGE}' is not present.

Please build the local image following the instructions in README.md:
- Section: Development environment / Local Docker image
- Command (run from repo root):
	nix --print-build-logs --verbose develop --ignore-environment --command true
	nix --print-build-logs --verbose build .#dockerImage && docker load <result

Attempting to build the image automatically now...
EOF

		echo "Building the Docker image from flake.nix..."
		nix --extra-experimental-features nix-command --extra-experimental-features flakes \
			--print-build-logs --verbose develop --ignore-environment --command true
		if nix --extra-experimental-features nix-command --extra-experimental-features flakes \
			--print-build-logs --verbose build .#dockerImage; then
			docker load <result || {
				echo "Error: 'docker load' failed. Ensure Docker is running and you have permissions." >&2
				exit 1
			}
		else
			echo "Error: Nix build failed for '.#dockerImage'." >&2
			echo "Refer to README.md for troubleshooting the local image build." >&2
			exit 1
		fi
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

# Check requirements
if ! check_requirements; then
	exit 1
fi

# Display developer warning
cat << EOF
!!! This ./docker_local_dev.sh script is for developers usage only. !!!

Using the last locally built Docker image from flake.nix/flake.lock: ${DOCKER_IMAGE}

!!! WARNING: Using anything other than the published Docker image might lead
to non-reproducible builds. !!!

For using the latest published Docker image, refer to ./docker_latest.sh.
For producing reproducible builds like CircleCI, refer to ./docker_repro.sh.

EOF

# Handle Ctrl-C gracefully
trap "echo 'Script interrupted. Exiting...'; exit 130" SIGINT

# Rebuild Docker image if needed
rebuild_docker_image

# Ensure local image exists (handles first-time setup)
ensure_local_image

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
