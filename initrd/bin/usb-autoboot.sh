#!/bin/bash
set -o pipefail

# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh
# shellcheck source=initrd/etc/gui_functions.sh
. /etc/gui_functions.sh

# Automatically boot to a bootable USB medium if present.  This is for
# unattended boot; there is no UI.
# There are three possible results:
# * Automatic boot occurs - script does not return (kexec happens)
# * User interrupted automatic boot - script returns 0.  Skip normal boot and go
#   to the boot menu (don't prompt for two automatic boots).
# * No automatic boot was attempted - script returns nonzero.  Continue with
#   normal automatic boot.

# These may die for failure, nonzero exit is correct (USB boot wasn't possible)
enable_usb
enable_usb_storage

mkdir -p /media

parse_boot_options()
{
	BOOTDIR="$1"
	while IFS= read -r -d '' i; do
		kexec-parse-boot.sh "$BOOTDIR" "$i"
	done < <(find "$BOOTDIR" -name '*.cfg' -print0)
}

# Look for any bootable USB medium.
list_usb_storage >/tmp/usb-autoboot-usb-storage
while read -u 4 -r USB_BLOCK_DEVICE; do
	mount "$USB_BLOCK_DEVICE" /media || continue
	USB_DEFAULT_BOOT="$(parse_boot_options /media | head -1)"
	if [ -n "$USB_DEFAULT_BOOT" ]; then
		# Boot automatically, unless the user interrupts.
		echo -e "\n\n"
		echo "Found bootable USB: $(echo "$USB_DEFAULT_BOOT" | cut -d '|' -f 1)"
		if ! pause_automatic_boot; then
			# User interrupted, go to boot menu
			umount /media
			exit 0
		fi
		echo -e "\n\nBooting from USB...\n\n"
		kexec-boot.sh -b /media -e "$USB_DEFAULT_BOOT"
		# If kexec-boot returned, the boot obviously did not occur,
		# return nonzero below so the normal OS boot will continue.
	fi
	umount /media
done 4</tmp/usb-autoboot-usb-storage

# No bootable USB medium found
exit 1
