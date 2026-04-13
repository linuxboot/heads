#!/bin/bash
# Boot ISO file from USB media (ext4/fat/exfat USB stick)
#
# References:
# - https://wiki.archlinux.org/title/ISO_Spring_(%27Loop%27_device)
# - https://a1ive.github.io/grub2_loopback.html
#
# Boot Methods: Pass iso-scan/filename=, fromiso=, img_loop=, etc. via kexec.
# The ISO initrd picks what it needs. Hybrid ISOs (MBR sig 0x55AA) can boot from USB file.
#
# Known compatible: Ubuntu, Debian Live, Tails, NixOS, Fedora Workstation Live,
#   PureOS, Kicksecure (Dracut-based, boot=live, iso-scan)
# Known incompatible: Fedora Silverblue, Fedora Server, Qubes OS (Anaconda-based,
#   inst.stage2= requires block device or dd). Use dd or distribution media tool.
#
# See: https://github.com/linuxboot/heads/issues/2008
set -e -o pipefail
. /etc/functions.sh
. /etc/gui_functions.sh
. /tmp/config

TRACE_FUNC

MOUNTED_ISO_PATH="$1"
ISO_PATH="$2"
DEV="$3"

STATUS "Verifying ISO"
# Verify the signature on the hashes
ISOSIG="$MOUNTED_ISO_PATH.sig"
if ! [ -r "$ISOSIG" ]; then
	ISOSIG="$MOUNTED_ISO_PATH.asc"
fi

ISO_PATH="${ISO_PATH##/}"

if [ -r "$ISOSIG" ]; then
	# Signature found, verify it
	gpgv.sh --homedir=/etc/distro/ "$ISOSIG" "$MOUNTED_ISO_PATH" ||
		DIE 'ISO signature failed'
	STATUS_OK "ISO signature verified"
else
	# No signature found, prompt user with warning
	WARN "No signature found for ISO"
	if [ -x /bin/whiptail ]; then
		if ! whiptail_warning --title 'UNSIGNED ISO WARNING' --yesno \
			"WARNING: UNSIGNED ISO DETECTED\n\nThe selected ISO file:\n$MOUNTED_ISO_PATH\n\nDoes not have a detached signature (.sig or .asc file).\n\n\nThis means the integrity and authenticity of the ISO cannot be verified.\nBooting unsigned ISOs is potentially unsafe.\n\nDo you want to proceed with booting this unsigned ISO?" \
			0 80; then
			DIE "Unsigned ISO boot cancelled by user"
		fi
	else
		WARN "The selected ISO file does not have a detached signature"
		WARN "Integrity and authenticity of the ISO cannot be verified"
		WARN "Booting unsigned ISOs is potentially unsafe"
		INPUT "Do you want to proceed anyway? (y/N):" -n 1 response
		if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
			DIE "Unsigned ISO boot cancelled by user"
		fi
	fi
	NOTE "Proceeding with unsigned ISO boot"
fi

check_hybrid_iso() {
	local iso_path="$1"
	local mbr_sig

	[ -r "$iso_path" ] || return 1
	mbr_sig=$(dd if="$iso_path" bs=1 skip=510 count=2 2>/dev/null | xxd -p)
	DEBUG "check_hybrid_iso: mbr_sig=$mbr_sig"
	if [ "$mbr_sig" = "55aa" ]; then
		echo "hybrid"
	else
		echo "cdrom"
	fi
}

STATUS "Checking ISO boot capability..."
ISO_BOOT_TYPE=$(check_hybrid_iso "$MOUNTED_ISO_PATH")
DEBUG "ISO boot type: $ISO_BOOT_TYPE"

STATUS "Mounting ISO and booting"
mount -t iso9660 -o loop $MOUNTED_ISO_PATH /boot ||
	DIE '$MOUNTED_ISO_PATH: Unable to mount /boot'

DEV_UUID=$(blkid $DEV | tail -1 | tr " " "\n" | grep UUID | cut -d\" -f2)
ADD="fromiso=/dev/disk/by-uuid/$DEV_UUID/$ISO_PATH img_dev=/dev/disk/by-uuid/$DEV_UUID iso-scan/filename=/${ISO_PATH} img_loop=$ISO_PATH iso=$DEV_UUID/$ISO_PATH"
REMOVE=""

paramsdir="/media/kexec_iso/$ISO_PATH"
check_config $paramsdir

ADD_FILE=/tmp/kexec/kexec_iso_add.txt
if [ -r $ADD_FILE ]; then
	NEW_ADD=$(cat $ADD_FILE)
	ADD=$(eval "echo \"$NEW_ADD\"")
fi
DEBUG "Overriding ISO kernel arguments with additions: $ADD"

REMOVE_FILE=/tmp/kexec/kexec_iso_remove.txt
if [ -r $REMOVE_FILE ]; then
	NEW_REMOVE=$(cat $REMOVE_FILE)
	REMOVE=$(eval "echo \"$NEW_REMOVE\"")
fi
DEBUG "Overriding ISO kernel arguments with suppressions: $REMOVE"

# Call kexec and indicate that hashes have been verified
DO_WITH_DEBUG kexec-select-boot.sh -b /boot -d /media -p "$paramsdir" \
	-a "$ADD" -r "$REMOVE" -c "*.cfg" -u -i

DIE "Something failed in selecting boot"
