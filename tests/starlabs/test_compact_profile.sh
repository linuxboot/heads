#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

grep -F 'modules-$(CONFIG_PCIUTILS_LIB_ONLY) += pciutils' \
	"$repo_root/modules/pciutils" >/dev/null
grep -F 'busybox_build_name := busybox-compact' \
	"$repo_root/modules/busybox" >/dev/null
grep -F 'busybox_depends := $(musl_dep)' \
	"$repo_root/modules/busybox" >/dev/null
grep -F 'CONFIG_LSPCI=y' "$repo_root/modules/busybox" >/dev/null

for applet in ARP I2CGET PING TLS WGET UDHCPC; do
	grep -qw "$applet" "$repo_root/modules/busybox"
done

grep -F 'if [ "$CONFIG_BRAND_NAME" = "Heads" ] && [ -x /bin/qrenc ]; then' \
	"$repo_root/initrd/bin/kexec-boot.sh" >/dev/null
grep -F 'elif [ ! -x /bin/totp ]; then' \
	"$repo_root/initrd/bin/gui-init.sh" >/dev/null
grep -F 'if [ -x /bin/cryptsetup ]; then' \
	"$repo_root/initrd/bin/gui-init.sh" >/dev/null
grep -F 'if [ -x /bin/cryptsetup ]; then' \
	"$repo_root/initrd/bin/oem-factory-reset.sh" >/dev/null
grep -F '[ "$CONFIG_TPM" = "y" ] && [ -x /bin/totp ]' \
	"$repo_root/initrd/etc/gui_functions.sh" >/dev/null

while IFS=: read -r config size; do
	if [[ "$config" != *starlabs_qemu.config ]] && (( size <= 0x800000 )); then
		echo "$config does not provide more than 8 MiB of CBFS space" >&2
		exit 1
	fi
	if (( size > 0x1000000 )); then
		echo "$config exceeds the 16 MiB CBFS decode window" >&2
		exit 1
	fi
done < <(grep -H '^CONFIG_CBFS_SIZE=' \
	"$repo_root"/config/coreboot-starlabs_*.config | \
	sed 's/:CONFIG_CBFS_SIZE=/:/')

while IFS= read -r config; do
	grep -q '^CONFIG_BOOTSPLASH=y' "$config" || {
		echo "$config does not enable the coreboot bootsplash" >&2
		exit 1
	}
	if grep -q '^CONFIG_IFD_BIN_PATH=.*\$(' "$config"; then
		echo "$config uses a symbolic IFD path" >&2
		exit 1
	fi
done < <(find "$repo_root/config" -maxdepth 1 -type f \
	-name 'coreboot-starlabs_*.config' ! -name '*_qemu.config' | sort)

if grep -R -q '^export CONFIG_CBFS_VIA_FLASHPROG=y' \
	"$repo_root/boards/starlabs"; then
	echo "Star Labs boards must keep CBFS in the memory-mapped window" >&2
	exit 1
fi

echo "Star Labs compact profile tests passed"
