#!/bin/bash
# Boot from a local disk installation

# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh
# shellcheck disable=SC1091
. /tmp/config

mount_boot()
{
	TRACE_FUNC
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

	if ! confirm_totp "Boot mode"; then
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
		# shellcheck disable=SC2093
		exec /bin/usb-init
		continue
	fi

	if [ "$totp_confirm" = "m" ]; then
		# Try to select a kernel from the menu
		mount_boot
		DO_WITH_DEBUG kexec-select-boot.sh -m -b /boot -c "grub.cfg"
		continue
	fi

	if [ "$totp_confirm" = "y" ] || [ -n "$totp_confirm" ]; then
		# Try to boot the default
		mount_boot
		DO_WITH_DEBUG kexec-select-boot.sh -b /boot -c "grub.cfg" \
		|| recovery "Failed default boot"
	fi

done

recovery "Something failed during boot"
