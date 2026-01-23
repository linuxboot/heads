#!/bin/bash

# Shared common Docker helpers for Heads dev scripts
# This file is intended to be sourced from the various docker_*.sh scripts.

usage() {
	echo "Usage: $0 [OPTIONS] -- [COMMAND]"
	echo "Options:"
	echo "  CPUS=N  Set the number of CPUs"
	echo "  V=1     Enable verbose mode"
	echo "Command:"
	echo "  The command to run inside the Docker container, e.g., make BOARD=BOARD_NAME"
}

# Kill GPG toolstack related processes that may hold USB devices
kill_usb_processes() {
	if [ -d /dev/bus/usb ]; then
		if sudo lsof /dev/bus/usb/00*/0* 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r ps -p | grep -E 'scdaemon|pcscd' >/dev/null; then
			echo "Killing GPG toolstack related processes using USB devices..."
			sudo lsof /dev/bus/usb/00*/0* 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r ps -p | grep -E 'scdaemon|pcscd' | awk '{print $1}' | xargs -r sudo kill -9
		fi
	fi
}

# Handle Ctrl-C (SIGINT) to exit gracefully for all scripts that source this file
trap "echo 'Script interrupted. Exiting...'; exit 1" SIGINT

# Handle simple help flags in scripts that source this file
for arg in "$@"; do
	if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
		usage
		exit 0
	fi
done

# Run the USB cleanup common action
kill_usb_processes

# Informational reminder printed by each docker wrapper
echo "----"
echo "Usage reminder: The minimal command is 'make BOARD=XYZ', where additional options, including 'V=1' or 'CPUS=N' are optional."
echo "For more advanced QEMU testing options, refer to targets/qemu.md and boards/qemu-*/*.config."
echo
echo "Type exit within docker image to get back to host if launched interactively!"
echo "----"
echo
