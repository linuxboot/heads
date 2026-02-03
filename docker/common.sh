#!/bin/bash

# Shared common Docker helpers for Heads dev scripts
# This file is intended to be sourced from the various docker_*.sh scripts.

usage() {
	echo "Usage: $0 [OPTIONS] -- [COMMAND]"
	echo "Options:"
	echo "  CPUS=N  Set the number of CPUs"
	echo "  V=1     Enable verbose mode"
	echo "Environment variables (opt-ins / opt-outs):"
	echo "  HEADS_DISABLE_USB=1   Disable automatic USB passthrough (default: enabled when /dev/bus/usb exists)"
	echo "  HEADS_X11_XAUTH=1      Explicitly mount \$HOME/.Xauthority into the container for X11 auth"
	echo "Command:"
	echo "  The command to run inside the Docker container, e.g., make BOARD=BOARD_NAME"
}

set -euo pipefail

# Track whether we will supply Xauthority into the container (1 when used)
DOCKER_XAUTH_USED=0

# Kill GPG toolstack related processes that may hold USB devices
kill_usb_processes() {
	if [ -d /dev/bus/usb ]; then
		if sudo lsof /dev/bus/usb/00*/0* 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r ps -p | grep -E 'scdaemon|pcscd' >/dev/null; then
			echo "Killing GPG toolstack related processes using USB devices..."
			sudo lsof /dev/bus/usb/00*/0* 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r ps -p | grep -E 'scdaemon|pcscd' | awk '{print $1}' | xargs -r sudo kill -9
		fi
	fi
}

# Build Docker run options based on available host capabilities
build_docker_opts() {
	local opts="-e DISPLAY=${DISPLAY:-} --network host --rm -ti"

	# USB passthrough: enable by default when host USB buses are present.
	# To explicitly disable, set HEADS_DISABLE_USB=1 in the environment before invoking the wrapper.
	if [ -d "/dev/bus/usb" ]; then
		if [ "${HEADS_DISABLE_USB:-0}" = "1" ]; then
			echo "--->Host USB present; USB passthrough disabled by HEADS_DISABLE_USB=1" >&2
		else
			opts="${opts} --device=/dev/bus/usb:/dev/bus/usb"
			echo "--->USB passthrough enabled; to disable set HEADS_DISABLE_USB=1 in your environment" >&2
		fi
	fi

	# Add KVM device if available
	if [ -e "/dev/kvm" ]; then
		opts="${opts} --device=/dev/kvm:/dev/kvm"
		echo "--->Host KVM device found; enabling /dev/kvm passthrough in container" >&2
	elif [ -e "/proc/kvm" ]; then
		# /proc/kvm present but /dev/kvm missing means kernel module not loaded
		echo "--->Host reports KVM available (/proc/kvm present) but /dev/kvm is missing; ensure kvm module is loaded and /dev/kvm exists" >&2
	fi

	# X11 forwarding: mount socket + programmatic Xauthority when available
	if [ -d "/tmp/.X11-unix" ]; then
		opts="${opts} -v /tmp/.X11-unix:/tmp/.X11-unix"
		# Preferred: create a host-side xauth file containing the cookie for $DISPLAY
		if command -v xauth >/dev/null 2>&1; then
			XAUTH_HOST="/tmp/.docker.xauth-$(id -u)"
			# Create file if missing and try to populate it from the host's Xauthority/cookie
			if [ ! -f "${XAUTH_HOST}" ]; then
				touch "${XAUTH_HOST}" || true
				xauth nlist "${DISPLAY}" 2>/dev/null | sed -e 's/^..../ffff/' | xauth -f "${XAUTH_HOST}" nmerge - 2>/dev/null || true
			fi
			if [ -s "${XAUTH_HOST}" ]; then
				DOCKER_XAUTH_USED=1
				opts="${opts} -v ${XAUTH_HOST}:${XAUTH_HOST}:ro -e XAUTHORITY=${XAUTH_HOST}"
				echo "--->Using programmatic Xauthority ${XAUTH_HOST} for X11 auth" >&2
			elif [ -f "${HOME}/.Xauthority" ]; then
				DOCKER_XAUTH_USED=1
				opts="${opts} -v ${HOME}/.Xauthority:/root/.Xauthority:ro -e XAUTHORITY=/root/.Xauthority"
				echo "--->Falling back to mounting ${HOME}/.Xauthority into container for X11 auth" >&2
			else
				echo "--->X11 socket present but no Xauthority found; GUI may fail. For X11: install xauth or provide $HOME/.Xauthority; for Wayland: bind $XDG_RUNTIME_DIR and forward WAYLAND_DISPLAY/pipewire as needed. If you accept the risk, you may run 'xhost +SI:localuser:root' manually." >&2
			fi
		else
			# xauth not available: try mounting $HOME/.Xauthority as a fallback
			if [ -f "${HOME}/.Xauthority" ]; then
				opts="${opts} -v ${HOME}/.Xauthority:/root/.Xauthority:ro -e XAUTHORITY=/root/.Xauthority"
				echo "--->Mounting ${HOME}/.Xauthority into container for X11 auth (xauth not available)" >&2
			else
				echo "--->X11 socket present but xauth not available and ${HOME}/.Xauthority not found; GUI may fail. Install xauth or provide $HOME/.Xauthority; for Wayland, bind $XDG_RUNTIME_DIR and forward WAYLAND_DISPLAY if needed." >&2
			fi
		fi
	else
		if [ "${HEADS_X11_XAUTH:-0}" != "0" ]; then
			if [ -f "${HOME}/.Xauthority" ]; then
				opts="${opts} -v ${HOME}/.Xauthority:/root/.Xauthority:ro -e XAUTHORITY=/root/.Xauthority"
				echo "--->HEADS_X11_XAUTH=1: mounting ${HOME}/.Xauthority into container" >&2
			else
				echo "--->HEADS_X11_XAUTH=1 set but ${HOME}/.Xauthority not found; GUI may fail. Install xauth or use Wayland bindings as appropriate." >&2
			fi
		fi
	fi

	# If host xhost does not list LOCAL, warn the user about enabling access only when
	# we did NOT supply an Xauthority cookie. We do NOT modify xhost automatically (security).
	if [ "${DOCKER_XAUTH_USED:-0}" = "0" ] && command -v xhost >/dev/null 2>&1 && ! xhost | grep -q "LOCAL:"; then
		# We do not run 'xhost' for the user. If the developer understands the risk and
		# wants to allow GUI access via xhost, they can run:
		#   xhost +SI:localuser:root
		# We recommend using programmatic Xauthority (xauth) instead, which this script
		# already attempts (preferred, non-invasive approach).
		echo "--->X11 auth may be strict; no automatic 'xhost' changes are performed. Provide Xauthority (install xauth) or run 'xhost +SI:localuser:root' manually if you accept the security risk." >&2
	fi
	# Return the constructed docker run options
	echo "${opts}"
}

# Common run helper
run_docker() {
	local image="$1"; shift
	local opts host_workdir container_workdir summary parts
	opts=$(build_docker_opts)
	host_workdir="$(pwd)"
	# Always mount the repository into the same path inside the container. This
	# preserves absolute paths in generated build artifacts and ensures
	# reproducible builds, which is the behavior preserved on origin/master.
	container_workdir="${host_workdir}"

	# Build a short summary for the developer instead of dumping a huge command line.
	parts=()
	case "${opts}" in
		*"/dev/kvm"*) parts+=("KVM=on") ;;
		*) parts+=("KVM=off") ;;
	esac
	case "${opts}" in
		*"/dev/bus/usb"*) parts+=("USB=on") ;;
		*) parts+=("USB=off") ;;
	esac
	case "${opts}" in
		*"/tmp/.X11-unix"*) parts+=("X11=on") ;;
		*) parts+=("X11=off") ;;
	esac
	summary="---> Running container with: ${parts[*]} ; mount ${host_workdir} -> ${container_workdir}"
	echo "${summary}" >&2

	# Print the full docker command (developer-oriented output)
	echo "---> Full docker command: docker run ${opts} -v ${host_workdir}:${container_workdir} -w ${container_workdir} ${image} -- $*" >&2

	# shellcheck disable=SC2086
	exec docker run ${opts} -v "${host_workdir}:${container_workdir}" -w "${container_workdir}" "${image}" -- "$@"
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
