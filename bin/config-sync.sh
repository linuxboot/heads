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
#   BUILD_CONFIG  consumed build .config to compare against
#   BOARD_BUILD_DIR, BRAND_NAME  Linux template substitution inputs
#   BLOB_DIR, BRAND_DIR         Linux template substitution inputs
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

# Ensure committed configs match the configuration actually consumed by the
# built module outputs (guards against stale cached .configured/.build stamps).
normalize_coreboot_config() {
	grep -v -E '^(CONFIG_LOCALVERSION|CONFIG_MAINBOARD_SMBIOS_PRODUCT_NAME|CONFIG_MAINBOARD_SMBIOS_MANUFACTURER)=' "$1" || true
}

if [ -n "${BUILD_CONFIG:-}" ] && [ -f "$BUILD_CONFIG" ]; then
	case "$MODE" in
		linux-*)
			expected="$tmp/expected.config"
			cp "$CONFIG_PATH" "$expected"
			if [ -n "${BOARD_BUILD_DIR:-}" ]; then
				sed -i "s!@BOARD_BUILD_DIR@!${BOARD_BUILD_DIR}!g" "$expected"
			fi
			if [ -n "${BLOB_DIR:-}" ]; then
				sed -i "s!@BLOB_DIR@!${BLOB_DIR}!g" "$expected"
			fi
			if [ -n "${BRAND_DIR:-}" ]; then
				sed -i "s!@BRAND_DIR@!${BRAND_DIR}!g" "$expected"
			fi
			if [ -n "${BRAND_NAME:-}" ]; then
				sed -i "s!@BRAND_NAME@!${BRAND_NAME}!g" "$expected"
			fi
			if ! cmp -s "$expected" "$BUILD_CONFIG"; then
				echo "FAIL-SAFE: $CONFIG_PATH differs from build config $BUILD_CONFIG" >&2
				exit 1
			fi
			;;
		coreboot-*)
			expected_norm="$tmp/expected.norm"
			build_norm="$tmp/build.norm"
			normalize_coreboot_config "$CONFIG_PATH" >"$expected_norm"
			normalize_coreboot_config "$BUILD_CONFIG" >"$build_norm"
			if ! cmp -s "$expected_norm" "$build_norm"; then
				echo "FAIL-SAFE: $CONFIG_PATH differs from build config $BUILD_CONFIG" >&2
				exit 1
			fi
			;;
	esac
fi

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
	staged="$(mktemp "${OUTPUT_PATH}.XXXXXX")" && \
	cp "$out" "$staged" && \
	mv "$staged" "$OUTPUT_PATH" || \
	{ rm -f "${staged:-}"; exit 1; }
fi
