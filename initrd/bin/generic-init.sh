#!/bin/bash
# Boot from a local disk installation

. /etc/functions.sh
. /tmp/config

mount_boot()
{
	# Mount local disk if it is not already mounted
	if ! grep -q /boot /proc/mounts ; then
		mount -o ro /boot \
			|| recovery "Unable to mount /boot"
	fi
}


# Confirm we have a good TOTP unseal and ask the user for next choice
while true; do
	echo "y) Default boot"
	echo "n) TOTP does not match"
	echo "r) Recovery boot"
	echo "u) USB boot"
	echo "m) Boot menu"

	if ! totp_confirm=$(confirm_totp "Boot mode"); then
		recovery 'Failed to unseal TOTP'
	fi

	if [ "$totp_confirm" = "r" ]; then
		recovery "User requested recovery shell"
	fi

	if [ "$totp_confirm" = "n" ]; then
		echo ""
		echo "To correct clock drift: 'date -s HH:MM:SS'"
		echo "and save it to the RTC: 'hwclock -w'"
		echo "then reboot and try again"
		echo ""
		recovery "TOTP mismatch"
	fi

	if [ "$totp_confirm" = "u" ]; then
		/bin/usb-init.sh
		continue
	fi

	if [ "$totp_confirm" = "m" ]; then
		# Try to select a kernel from the menu
		mount_boot
		kexec-select-boot -m -b /boot -c "grub.cfg"
		continue
	fi

	if [ "$totp_confirm" = "y" ] || [ -n "$totp_confirm" ]; then
		# Try to boot the default
		mount_boot
		kexec-select-boot -b /boot -c "grub.cfg" \
		|| recovery "Failed default boot"
	fi

done

recovery "Something failed during boot"
