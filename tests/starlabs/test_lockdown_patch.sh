#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
patch_file="$repo_root/patches/coreboot-starlabs_2607/0003-soc-intel-lockdown-Allow-locking-down-SPI-and-LPC-in.patch"
lock_script="$repo_root/initrd/bin/lock_chip.sh"
board_configs=(
	"$repo_root/boards/starlabs/physical-intel.config"
	"$repo_root/boards/starlabs/compact-intel.config"
)

grep -F '+	depends on BOOTMEDIA_LOCK_CONTROLLER && BOOTMEDIA_LOCK_WHOLE_RO' \
	"$patch_file" >/dev/null
grep -F '+int fast_spi_flash_write_protect(const struct region *region)' \
	"$patch_file" >/dev/null
grep -F '+	return fast_spi_ctrlr_protect_region(region, WRITE_PROTECT);' \
	"$patch_file" >/dev/null
grep -F '+		if (reg == expected) {' "$patch_file" >/dev/null
grep -F '+	if (reg != expected) {' "$patch_file" >/dev/null
grep -F '+	if (!CONFIG(SOC_INTEL_COMMON_SPI_LOCKDOWN_SMM))' \
	"$patch_file" >/dev/null
grep -F '+		outb(status < 0 ? -status : 0, APM_STS);' "$patch_file" >/dev/null
grep -F '+		if (status) {' "$patch_file" >/dev/null

if grep -F 'die("Unable to restore SPI boot-media protection before lockdown' \
	"$patch_file" >/dev/null; then
	echo "Deferred SPI lockdown can still halt inside SMM" >&2
	exit 1
fi

grep -F '	APM_STS=${CONFIG_FINALIZE_PLATFORM_LOCKING_APM_STS:-}' \
	"$lock_script" >/dev/null
grep -F '			DIE "Chipset write protection failed (status $FINALIZE_STATUS)"' \
	"$lock_script" >/dev/null
grep -F 'if ! io386 -o b -b x "$APM_STS" 0xff; then' "$lock_script" >/dev/null
grep -F 'if ! io386 -o b -b x "$APM_CNT" "$FIN_CODE"; then' "$lock_script" >/dev/null
grep -F 'if ! FINALIZE_STATUS=$(io386 -i b "$APM_STS"); then' "$lock_script" >/dev/null
grep -F "''|*[!0-9]*)" "$lock_script" >/dev/null

for board_config in "${board_configs[@]}"; do
	grep -F 'export CONFIG_FINALIZE_PLATFORM_LOCKING_APM_CNT=0xb2' \
		"$board_config" >/dev/null
	grep -F 'export CONFIG_FINALIZE_PLATFORM_LOCKING_APM_STS=0xb3' \
		"$board_config" >/dev/null
	grep -F 'export CONFIG_FINALIZE_PLATFORM_LOCKING_CODE=0xcb' \
		"$board_config" >/dev/null
done

if grep -F $'\tAPM_STS=0xb3' "$lock_script" >/dev/null; then
	echo "Shared lock script still hardcodes the Star Labs status port" >&2
	exit 1
fi

protect_line=$(grep -n -F '+		status = fast_spi_flash_write_protect(&bootmedia);' \
	"$patch_file" | cut -d: -f1)
dlock_line=$(grep -n -F '+	fast_spi_pr_dlock();' "$patch_file" | cut -d: -f1)
flockdn_line=$(grep -n -F '+	fast_spi_lock_bar();' "$patch_file" | cut -d: -f1)

if [ -z "$protect_line" ] || [ -z "$dlock_line" ] || [ -z "$flockdn_line" ] || \
	[ "$protect_line" -ge "$dlock_line" ] || [ "$dlock_line" -ge "$flockdn_line" ]; then
	echo "Deferred SPI lockdown does not restore protection before DLOCK/FLOCKDN" >&2
	exit 1
fi

echo "Star Labs deferred-lock patch tests passed"
