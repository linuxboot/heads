#! /usr/bin/env bash

set -eo pipefail

usage() {
cat >&2 <<USAGE_END
$0 <mirror-directory>

Downloads all current package artifacts needed to build Heads and copies them
to a mirror directory, for seeding a package mirror.

Parameters:
  <mirror-directory>: Path to a directory where the packages are placed.
  Created if it does not already exist.
USAGE_END
}

ARGS_DONE=
while [[ $# -ge 1 ]] && [ -z "$ARGS_DONE" ]; do
	case "$1" in
		--)
			ARGS_DONE=y
			shift
			;;
		--help)
			usage
			exit 0
			;;
		--*)
			echo "unknown parameter: $1" >&2
			usage
			exit 1
			;;
		*)
			ARGS_DONE=y
			;;
	esac
done

if [[ $# -ne 1 ]]; then
	usage
	exit 1
fi

ARG_MIRROR_DIR="$(realpath "$1")"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo
echo "Cleaning build to download all packages..."
# fetch packages for representative boards
rm -rf build/x86 build/ppc64
rm -rf packages/x86 packages/ppc64
echo
echo "Downloading packages..."
make packages BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp
make packages BOARD=talos-2 # newt, PPC
make packages BOARD=librem_l1um_v2 # TPM2
make packages BOARD=librem_l1um # coreboot 4.11
make packages BOARD=x230-maximized # io386
echo
echo "Copying to mirror directory..."
mkdir -p "$ARG_MIRROR_DIR"
cp packages/x86/* packages/ppc64/* "$ARG_MIRROR_DIR/"
