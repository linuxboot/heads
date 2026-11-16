#!/usr/bin/env bash
#
# Shared implementation for the save_in_* config helpers.
#
# Copies the committed config (placeholders intact) into a throwaway obj tree
# under /tmp, runs oldconfig/olddefconfig/savedefconfig there, and writes the
# result back only when it differs.  The build .config is never touched, and
# no temporary file is left under the source/build tree (which CircleCI
# caches).
#
# Required environment:
#   MODE          linux-olddefconfig | linux-oldconfig | linux-savedefconfig
#                 coreboot-olddefconfig | coreboot-savedefconfig
#                 coreboot-defconfig-in-place
#   CONFIG_PATH   committed config to read
#   OUTPUT_PATH   file to update
#   SRC_DIR       linux/coreboot source tree
# Optional:
#   ARCH, CROSS   Linux only
#
set -euo pipefail

: "${MODE:?}" "${CONFIG_PATH:?}" "${OUTPUT_PATH:?}" "${SRC_DIR:?}"

tmp="$(mktemp -d /tmp/heads-config.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

cp "$CONFIG_PATH" "$tmp/.config"

run_linux() {
	make -C "$SRC_DIR" \
		O="$tmp" \
		ARCH="${ARCH:-}" \
		CROSS_COMPILE="${CROSS:-}" \
		"$@"
}

run_coreboot() {
	make -C "$SRC_DIR" \
		obj="$tmp" \
		DOTCONFIG="$tmp/.config" \
		"$@"
}

case "$MODE" in
	linux-olddefconfig)
		run_linux olddefconfig
		out="$tmp/.config"
		;;
	linux-oldconfig)
		run_linux oldconfig
		out="$tmp/.config"
		;;
	linux-savedefconfig)
		run_linux savedefconfig
		out="$tmp/defconfig"
		;;
	coreboot-olddefconfig)
		run_coreboot olddefconfig
		out="$tmp/.config"
		;;
	coreboot-savedefconfig)
		run_coreboot DEFCONFIG="$tmp/defconfig" savedefconfig
		out="$tmp/defconfig"
		;;
	coreboot-defconfig-in-place)
		run_coreboot olddefconfig
		run_coreboot DEFCONFIG="$tmp/defconfig" savedefconfig
		out="$tmp/defconfig"
		;;
	*)
		echo "config-sync: unknown MODE: $MODE" >&2
		exit 1
		;;
esac

if ! cmp -s "$out" "$OUTPUT_PATH"; then
	cp "$out" "$OUTPUT_PATH.tmp" && \
	mv "$OUTPUT_PATH.tmp" "$OUTPUT_PATH" || \
	{ rm -f "$OUTPUT_PATH.tmp"; exit 1; }
fi
