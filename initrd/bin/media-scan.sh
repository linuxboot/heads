#!/bin/bash
# Scan for USB installation options
set -e -o pipefail
. /etc/functions.sh
. /etc/gui_functions.sh
. /tmp/config

TRACE_FUNC

#Booting from external media should be authenticated if supported
gpg_auth || DIE "GPG authentication failed"

# Unmount any previous boot device
if grep -q /boot /proc/mounts ; then
	umount /boot \
		|| DIE "Unable to unmount /boot"
fi

available_partitions="$(blkid | while read line; do echo $line | awk -F ":" {'print $1'}; done )"

if [ "$1" == "usb" ]; then
	# Mount the USB boot device, probing whole disks first so a dd-written
	# hybrid ISO (iso9660 on the whole device) is found before partitions.
	mount_usb --whole-disk || DIE "Unable to mount /media"
elif $(echo $available_partitions | grep -q "$1"); then
	if grep -q /media /proc/mounts; then
		umount /media \
			|| DIE "Unable to unmount /media"
	fi
	mount "$1" /media \
		|| DIE "Unable to mount $1 to /media"
fi

# Get USB boot device
USB_BOOT_DEV=$(grep "/media" /etc/mtab | cut -f 1 -d' ')

retried_whole_disk="n"

# Check for ISO first
get_menu_option() {
	if [ -x /bin/whiptail ]; then
		MENU_OPTIONS=""
		n=0
		while read option
		do
			n=`expr $n + 1`
			option=$(echo $option | tr " " "_")
			MENU_OPTIONS="$MENU_OPTIONS $n ${option}"
		done < /tmp/iso_menu.txt

		MENU_OPTIONS="$MENU_OPTIONS b Back"

		whiptail_type $BG_COLOR_MAIN_MENU --title "Select your ISO boot option" \
			--menu "Choose the ISO boot option [1-$n]:" 0 80 8 \
			-- $MENU_OPTIONS \
			2>/tmp/whiptail || exit 0

		option_index=$(cat /tmp/whiptail)
	else
		STATUS "Select your ISO boot option:"
		n=0
		while read option
		do
			n=`expr $n + 1`
			echo "$n. $option"
		done < /tmp/iso_menu.txt

		INPUT "Choose the ISO boot option [1-$n, a to abort]:" -r option_index
	fi

	# Empty occurs when aborting fbwhiptail with esc-esc
	if [ -z "$option_index" ] || [ "$option_index" = "b" ]; then
		exit 0
	fi

	option=`head -n $option_index /tmp/iso_menu.txt | tail -1`

	if [ -z "$option" ]; then
		DIE "Failed to find menu option $option_index"
	fi
}

while true; do
	# create ISO menu options - search recursively for ISO files
	find /media -name "*.iso" -type f 2>/dev/null | sort -r > /tmp/iso_menu.txt || true
	if [ `cat /tmp/iso_menu.txt | wc -l` -gt 0 ]; then
		while true; do
			option=""
			option_index=""
			option_confirm=""
			while [ -z "$option" -a "$option_index" != "s" ]
			do
				get_menu_option
			done

			MOUNTED_ISO="$option"
			ISO="${option:7}" # remove /media/ to get device relative path
			DO_WITH_DEBUG kexec-iso-init.sh "$MOUNTED_ISO" "$ISO" "$USB_BOOT_DEV" && break
		done
	fi

	# No *.iso files on media, try ordinary bootable USB

	if [ "$CONFIG_RESTRICTED_BOOT" = y ]; then
		DIE "No ISO files found, bootable USB not allowed with Restricted Boot."
	fi

	WARN "Could not find any ISO, trying bootable USB"
	# Attempt to pull verified config from device.
	# Unlike the ISO-file path (kexec-iso-init.sh), do NOT pass -s here.
	# -s is kexec-select-boot.sh's skip_confirm flag: with it, user_select()
	# calls do_boot() directly and confirm_menu_option() never runs, so the
	# full kexec command line is never shown. Omitting -s makes the dd'ed
	# bootable-USB path show the same boot confirmation (and Edit [e]) as
	# the ISO boot path.
	if [ -x /bin/whiptail ]; then
		# -s (skip_confirm) intentionally omitted: confirm before booting.
		if DO_WITH_DEBUG kexec-select-boot.sh -b /media -c "*.cfg" -u -g; then
			break
		fi
	else
		# -s (skip_confirm) intentionally omitted: confirm before booting.
		if DO_WITH_DEBUG kexec-select-boot.sh -b /media -c "*.cfg" -u; then
			break
		fi
	fi
	# The whole disk was mounted (e.g. a dd-written hybrid ISO) but
	# yielded no boot entries. Retry once with the default
	# partitions-only mount in case the bootable filesystem is on a
	# partition instead.
	if [ "$retried_whole_disk" = "n" ] && is_whole_disk "$USB_BOOT_DEV"; then
		retried_whole_disk="y"
		umount /media 2>/dev/null || true
		if ! mount-usb.sh; then
			DIE "No bootable filesystem found on USB media"
		fi
		USB_BOOT_DEV=$(grep "/media" /etc/mtab | cut -f 1 -d' ')
		continue
	fi
	DIE "Something failed in selecting boot"
done
