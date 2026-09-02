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
# Clear cached tarballs and .canary build stamps (modeled on the Makefile
# real.remove_canary_files-extract_patch_rebuild_what_changed helper), so
# module tarballs are re-downloaded and hash-verified AND coreboot forks
# re-enter their build to produce the crossgcc toolchain tarballs that
# seed the mirror.  Compiled artifacts are left intact — only the stamps
# and cached sources that gate re-fetch are removed.
rm -rf packages/*/*
find build -type f -name ".canary" -delete 2>/dev/null || true
echo
echo "Downloading packages..."
# Discover all boards dynamically and fetch every module tarball.
# 'make BOARD=X packages' triggers the 'packages:' target defined by
# define_module (Makefile:571) for every versioned module that board
# enables.  Tarballs are cached by filename in packages/<arch>/, so
# redundant downloads for boards sharing tarballs cost only Make
# setup overhead (~2s each).
# A board that fails (e.g. dead upstream URL) is reported but does not
# abort seeding the remaining boards.
failed=0
boards=()
for cfg in boards/*/[!.]*.config; do
	[ -f "$cfg" ] || continue
	boards+=("$(basename "$(dirname "$cfg")")")
done
for board in "${boards[@]}"; do
	echo "  make BOARD=$board packages"
	# Redirect stdin from /dev/null so make/wget cannot consume the
	# script's stdin — under set -e + if ! that can cause bash to
	# misparse the loop and produce an intermittent syntax error.
	if ! make BOARD="$board" packages </dev/null; then
		echo "  WARNING: $board failed to fetch all packages" >&2
		failed=$((failed+1))
	fi
done
[ "$failed" -eq 0 ] || echo "Warning: $failed board(s) failed to fetch all packages" >&2
echo
echo "Copying to mirror directory..."
mkdir -p "$ARG_MIRROR_DIR"
for arch_dir in packages/*/; do
	[ -d "$arch_dir" ] || continue
	cp "$arch_dir"* "$ARG_MIRROR_DIR/" 2>/dev/null || true
done
