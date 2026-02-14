#!/bin/bash
set -o pipefail

# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

BOOT_MENU_OPTIONS=/tmp/basic-autoboot-options

scan_boot_options /boot "grub.cfg" "$BOOT_MENU_OPTIONS"
if [ -s "$BOOT_MENU_OPTIONS" ]; then
	kexec-boot.sh -b /boot -e "$(head -1 "$BOOT_MENU_OPTIONS")"
fi
