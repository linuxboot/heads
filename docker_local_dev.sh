#!/bin/bash

# Check if Nix is installed
if ! command -v nix &> /dev/null; then
    echo "Nix is not installed or not in the PATH. Please install Nix before running this script."
    echo "Refer to the README.md at the root of the repository for installation instructions."
    exit 1
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed or not in the PATH. Please install Docker before running this script."
    echo "Refer to the README.md at the root of the repository for installation instructions."
    exit 1
fi

# Inform the user about the Docker image being used
echo "** This ./docker_local_dev.sh script is for developers usage only. **"
echo ""
echo "Using the last locally produced Docker image: linuxboot/heads:dev-env"
echo "Warning: Using anything other than the published Docker image might lead to non-reproducible builds."
echo ""
echo "For using the latest published Docker image, refer to ./docker_latest.sh."
echo "For producing reproducible builds as CircleCI, refer to ./docker_repro.sh."
echo ""
echo "---"

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
    echo "Killing any GPG toolstack related processes on host currently using USB devices..."
    sudo lsof /dev/bus/usb/00*/0* 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r ps -p | grep -E 'scdaemon|pcscd' | awk '{print $1}' | xargs -r sudo kill -9
    if [ $? -ne 0 ]; then
        echo "Failed to kill GPG toolstack related processes using USB devices. Please run the following command manually:"
        echo "sudo lsof /dev/bus/usb/00*/0* | awk 'NR>1 {print \$2}' | xargs -r ps -p | grep -E 'scdaemon|pcscd' | awk '{print \$1}' | xargs -r sudo kill -9"
        exit 1
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

# Check if the git repository is dirty and if flake.nix or flake.lock are part of the uncommitted changes
if [ -n "$(git status --porcelain | grep -E 'flake\.nix|flake\.lock')" ]; then
    echo "Warning: Uncommitted changes detected in flake.nix or flake.lock. The Docker image will be rebuilt."
    echo "If this was not intended, please commit your changes and rerun the script."
    echo "Building the Docker image from flake.nix..."
    nix --print-build-logs --verbose develop --ignore-environment --command true
    nix --print-build-logs --verbose build .#dockerImage && docker load < result
else
    echo "Git repository is clean. Using the previously built Docker image."
    echo "---"
    sleep 1
fi

# Kill processes using USB devices
kill_usb_processes

# Inform the user about entering the Docker container
echo "----"
echo "Usage reminder: The minimal command is 'make BOARD=XYZ', where additional options, including 'V=1' or 'CPUS=N' are optional."
echo "For more advanced QEMU testing options, refer to targets/qemu.md and boards/qemu-*/*.config."
echo "----"
echo "Entering the Docker container. Type 'exit' to return to the host shell."

# Execute the docker run command with the provided parameters
docker run --device=/dev/bus/usb:/dev/bus/usb -e DISPLAY=$DISPLAY --network host --rm -ti -v $(pwd):$(pwd) -w $(pwd) linuxboot/heads:dev-env -- "$@"
