#!/bin/bash
# Scan for USB installation options
set -e -o pipefail
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh
# shellcheck source=initrd/etc/gui_functions.sh
. /etc/gui_functions.sh
 # shellcheck disable=SC1091
 . /tmp/config

TRACE_FUNC

#Booting from external media should be authenticated if supported
gpg_auth || die "GPG authentication failed"

# Unmount any previous boot device
if grep -q /boot /proc/mounts ; then
	umount /boot \
		|| die "Unable to unmount /boot"
fi

available_partitions="$(blkid | while read -r line; do echo "$line" | awk -F ":" '{print $1}'; done )"

if [ "$1" == "usb" ]; then
	# Mount the USB boot device
	mount_usb || die "Unable to mount /media"
elif echo "$available_partitions" | grep -q "$1"; then
	if grep -q /media /proc/mounts; then
		umount /media \
			|| die "Unable to unmount /media"
	fi
	mount "$1" /media \
		|| die "Unable to mount $1 to /media"
fi

# Get USB boot device
USB_BOOT_DEV=$(grep "/media" /etc/mtab | cut -f 1 -d' ')

# Check for ISO first
get_menu_option() {
	if [ -x /bin/whiptail ]; then
		MENU_OPTIONS=""
		n=0
		while read -r option
		do
			n=$((n + 1))
			option=$(echo "$option" | tr " " "_")
			MENU_OPTIONS="$MENU_OPTIONS $n ${option}"
		done < /tmp/iso_menu.txt

		MENU_OPTIONS="$MENU_OPTIONS a Abort"

		# shellcheck disable=SC2086
		whiptail_type $BG_COLOR_MAIN_MENU --title "Select your ISO boot option" \
			--menu "Choose the ISO boot option [1-$n]:" 0 80 8 \
			-- $MENU_OPTIONS \
			2>/tmp/whiptail || die "Aborting boot attempt"

		option_index=$(cat /tmp/whiptail)
	else
		echo "+++ Select your ISO boot option:"
		n=0
		while read -r option
		do
			n=$((n + 1))
			echo "$n. $option"
		done < /tmp/iso_menu.txt

		read -r \
			-p "Choose the ISO boot option [1-$n, a to abort]: " \
			option_index
	fi

	# Empty occurs when aborting fbwhiptail with esc-esc
	if [ -z "$option_index" ] || [ "$option_index" = "a" ]; then
		die "Aborting boot attempt"
	fi

	option=$(head -n "$option_index" /tmp/iso_menu.txt | tail -1)

	if [ -z "$option" ]; then
		die "Failed to find menu option $option_index"
	fi
}

# create ISO menu options - search recursively for ISO files
find /media -name "*.iso" -type f 2>/dev/null | sort -r > /tmp/iso_menu.txt || true
if [ "$(wc -l < /tmp/iso_menu.txt)" -gt 0 ]; then
	while [ -z "$option" ] && [ "$option_index" != "s" ]
	do
		get_menu_option
	done

	MOUNTED_ISO="$option"
	ISO="${option:7}" # remove /media/ to get device relative path
	DO_WITH_DEBUG kexec-iso-init.sh "$MOUNTED_ISO" "$ISO" "$USB_BOOT_DEV"

	die "Something failed in iso init"
fi

# No *.iso files on media, try ordinary bootable USB

if [ "$CONFIG_RESTRICTED_BOOT" = y ]; then
	die "No ISO files found, bootable USB not allowed with Restricted Boot."
fi

echo "!!! Could not find any ISO, trying bootable USB"
# Attempt to pull verified config from device
if [ -x /bin/whiptail ]; then
	DO_WITH_DEBUG kexec-select-boot.sh -b /media -c "*.cfg" -u -g -s
else
	DO_WITH_DEBUG kexec-select-boot.sh -b /media -c "*.cfg" -u -s
fi

die "Something failed in selecting boot"
