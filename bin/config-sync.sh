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
#   BUILD_CONFIG            consumed build .config to compare against
#   VALIDATE_BUILD_CONFIG   set to 1 to compare against BUILD_CONFIG
#   REQUIRE_BUILD_CONFIG    with VALIDATE_BUILD_CONFIG, fail/warn if missing
#   WARN_BUILD_CONFIG       set to 1 to warn instead of fail on validation drift
#   BOARD_BUILD_DIR, BRAND_NAME  template substitution inputs
#   BLOB_DIR, BRAND_DIR         template substitution inputs
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

fail_build_config() {
	if [ "${WARN_BUILD_CONFIG:-0}" = "1" ]; then
		echo "WARN: $*" >&2
		return 0
	fi
	echo "FAIL-SAFE: $*" >&2
	exit 1
}

validate_build_config=0
if [ "${VALIDATE_BUILD_CONFIG:-0}" = "1" ]; then
	if [ -z "${BUILD_CONFIG:-}" ] || [ ! -f "$BUILD_CONFIG" ]; then
		if [ "${REQUIRE_BUILD_CONFIG:-0}" = "1" ]; then
			fail_build_config "$CONFIG_PATH: consumed build config missing (${BUILD_CONFIG:-unset})"
		fi
	else
		validate_build_config=1
	fi
fi

if [ "$validate_build_config" = "1" ]; then
	module_dir="$(realpath "$(dirname "$BUILD_CONFIG")/..")"
	case "$MODE" in
		linux-*)
			expected="$tmp/expected.config"
			expected_obj="$tmp/expected-obj"
			mkdir -p "$expected_obj"
			cp "$CONFIG_PATH" "$expected"
			if [ -n "${BOARD_BUILD_DIR:-}" ]; then
				sed -i "s!@BOARD_BUILD_DIR@!$(realpath --relative-to "$module_dir" "$BOARD_BUILD_DIR")!g" "$expected"
			fi
			if [ -n "${BLOB_DIR:-}" ]; then
				sed -i "s!@BLOB_DIR@!$(realpath --relative-to "$module_dir" "$BLOB_DIR")!g" "$expected"
			fi
			if [ -n "${BRAND_DIR:-}" ]; then
				sed -i "s!@BRAND_DIR@!$(realpath --relative-to "$module_dir" "$BRAND_DIR")!g" "$expected"
			fi
			if [ -n "${BRAND_NAME:-}" ]; then
				sed -i "s!@BRAND_NAME@!${BRAND_NAME}!g" "$expected"
			fi
			cp "$expected" "$expected_obj/.config"
			make -C "$SRC_DIR" O="$expected_obj" ARCH="${ARCH:-}" CROSS_COMPILE="${CROSS:-}" olddefconfig >/dev/null
			if ! cmp -s "$expected_obj/.config" "$BUILD_CONFIG"; then
				fail_build_config "$CONFIG_PATH differs from consumed build config $BUILD_CONFIG"
			fi
			;;
		coreboot-*)
			expected="$tmp/expected.config"
			cp "$CONFIG_PATH" "$expected"
			if [ -n "${BOARD_BUILD_DIR:-}" ]; then
				sed -i "s!@BOARD_BUILD_DIR@!$(realpath --relative-to "$module_dir" "$BOARD_BUILD_DIR")!g" "$expected"
			fi
			if [ -n "${BLOB_DIR:-}" ]; then
				sed -i "s!@BLOB_DIR@!$(realpath --relative-to "$module_dir" "$BLOB_DIR")!g" "$expected"
			fi
			if [ -n "${BRAND_DIR:-}" ]; then
				sed -i "s!@BRAND_DIR@!$(realpath --relative-to "$module_dir" "$BRAND_DIR")!g" "$expected"
			fi
			if [ -n "${BRAND_NAME:-}" ]; then
				sed -i "s!@BRAND_NAME@!${BRAND_NAME}!g" "$expected"
			fi
			expected_norm="$tmp/expected.norm"
			build_norm="$tmp/build.norm"
			normalize_coreboot_config "$expected" >"$expected_norm"
			normalize_coreboot_config "$BUILD_CONFIG" >"$build_norm"
			if ! cmp -s "$expected_norm" "$build_norm"; then
				fail_build_config "$CONFIG_PATH differs from consumed build config $BUILD_CONFIG"
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
	if [ -e "$OUTPUT_PATH" ]; then
		chown --reference="$OUTPUT_PATH" "$staged" 2>/dev/null || true
	fi && \
	chmod 0644 "$staged" && \
	mv "$staged" "$OUTPUT_PATH" || \
	{ rm -f "${staged:-}"; exit 1; }
fi
