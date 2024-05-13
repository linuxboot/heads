#! /usr/bin/env bash

TEMPLATE="$1"
RESULT="$2"
BOARD_BUILD="$3"
BRAND_NAME="$4"

repo="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
# For both coreboot and Linux, the config file is in a board-
# specific build directory, but the build occurs from the
# parent of that directory.
module_dir="$(realpath "$(dirname "$2")/..")"

# Use relative paths since the config may be part of the ROM
# artifacts, and relative paths won't depend on the workspace
# absolute path.
board_build_rel="$(realpath --relative-to "$module_dir" "$BOARD_BUILD")"
repo_rel="$(realpath --relative-to "$module_dir" "$repo")"

echo "board_build_rel=$board_build_rel"
echo "repo_rel=$repo_rel"

sed -e "s!@BOARD_BUILD_DIR@!${board_build_rel}!g" \
    -e "s!@BLOB_DIR@!${repo_rel}/blobs!g" \
    -e "s!@BRAND_DIR@!${repo_rel}/branding/$BRAND_NAME!g" \
    -e "s!@BRAND_NAME@!$BRAND_NAME!g" \
    "$TEMPLATE" > "$RESULT"
