#!/bin/bash
# Re-run the saved default boot path from the recovery shell (#2265).
# Mirrors gui-init.sh attempt_default_boot(): mount /boot, verify global
# hashes, then run kexec-select-boot.sh for /boot and grub.cfg.
# shellcheck disable=SC1091
set -e -o pipefail
. /tmp/config
. /etc/functions.sh
. /etc/gui_functions.sh

TRACE_FUNC

# gui-init.sh mount_boot() handles the interactive UI; recovery mounts directly.
if ! grep -q " /boot " /proc/mounts 2>/dev/null; then
	DEBUG "kexec-default-boot: /boot not mounted, attempting mount"
	if [ -n "${CONFIG_BOOT_DEV:-}" ]; then
		mount -o ro "$CONFIG_BOOT_DEV" /boot \
			|| DIE "Unable to mount /boot from $CONFIG_BOOT_DEV"
	else
		mount -o ro /boot \
			|| DIE "Unable to mount /boot"
	fi
fi

# Recovery may preserve another selector's cache. Start clean so references
# and signature metadata cannot come from a different boot directory.
rm -rf /tmp/kexec
check_config /boot

if ! verify_global_hashes; then
	DIE "Failed to verify global hashes for /boot"
fi

# Recovery wipes /tmp/secret, so skip DUK unseal/injection. Print the exact
# kexec command and require a typed confirmation before loading it.
KEXEC_BOOT_CONFIRM=y DO_WITH_DEBUG kexec-select-boot.sh -b /boot -c grub.cfg -g -n
