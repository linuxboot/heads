#!/bin/bash
# Re-run default boot path from recovery shell with GUI-equivalent checks
# (linuxboot/heads#2265 diagnostics).
#
# Mirrors gui-init.sh attempt_default_boot():
#   mount_boot -> verify_global_hashes -> kexec-select-boot.sh -b /boot -c grub.cfg -g
# kexec-boot.sh emits kexec_diag_state() before kexec -l, so GUI and recovery
# runs produce comparable debug.log state (tty/console/fb/vtcon/kexec_loaded).
set -e -o pipefail
. /tmp/config
. /etc/functions.sh
. /etc/gui_functions.sh

TRACE_FUNC

usage() {
	DIE "Usage: $0 [-b /boot] [-c grub.cfg]"
}

bootdir="/boot"
config="grub.cfg"

while getopts "b:c:" arg; do
	case "$arg" in
	b) bootdir="$OPTARG" ;;
	c) config="$OPTARG" ;;
	*) usage ;;
	esac
done

DEBUG "kexec-default-boot: bootdir=$bootdir config=$config"

# Ensure /boot is mounted before hash verification and kexec.
# gui-init.sh mount_boot() handles interactive UI; recovery uses direct mount.
if ! grep -q " ${bootdir} " /proc/mounts 2>/dev/null; then
	DEBUG "kexec-default-boot: $bootdir not mounted, attempting mount"
	if [ -n "${CONFIG_BOOT_DEV:-}" ]; then
		mount -o ro "$CONFIG_BOOT_DEV" "$bootdir" \
			|| DIE "Unable to mount $bootdir from $CONFIG_BOOT_DEV"
	else
		mount -o ro "$bootdir" \
			|| DIE "Unable to mount $bootdir"
	fi
fi

# Same gate as gui-init.sh attempt_default_boot(): verify /boot hashes first.
verify_global_hashes

# Skip TPM DUK unseal/injection in recovery; use default boot entry as-is.
# Print kexec command and ask confirmation before loading.
KEXEC_BOOT_CONFIRM=y DO_WITH_DEBUG kexec-select-boot.sh -b "$bootdir" -c "$config" -g -n

