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

detect_initrd_boot_support() {
	local supported_fses=""
	local supported_boot=""
	local found=0

	for path in $(find /boot -name 'initrd*' -type f 2>/dev/null | head -5); do
		[ -r "$path" ] || continue
		tmpdir=$(mktemp -d)
		/bin/bash /bin/unpack_initramfs.sh "$path" "$tmpdir" 2>/dev/null

		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "\.ko\.xz.*ext4|ext4\.ko"; then
			supported_fses="${supported_fses}ext4 "
			found=1
		fi
		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "\.ko\.xz.*vfat|vfat\.ko"; then
			supported_fses="${supported_fses}vfat "
			found=1
		fi
		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "\.ko\.xz.*exfat|exfat\.ko"; then
			supported_fses="${supported_fses}exfat "
			found=1
		fi

		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "iso.scan|findiso"; then
			supported_boot="${supported_boot}iso-scan/findiso "
		fi
		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "live.media|live-media"; then
			supported_boot="${supported_boot}live-media= "
		fi
		if find "$tmpdir" -type f 2>/dev/null | grep -qE "boot=live|rd.live.image|rd.live.squash"; then
			supported_boot="${supported_boot}boot=live "
		fi
		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "boot.casper|casper"; then
			supported_boot="${supported_boot}boot=casper "
		fi
		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "nixos"; then
			supported_boot="${supported_boot}nixos "
		fi
		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "inst.stage2|inst.repo"; then
			supported_boot="${supported_boot}anaconda "
		fi
		rm -rf "$tmpdir"
	done

	if [ -n "$supported_fses" ]; then
		echo "fs:$supported_fses"
	fi
	if [ -n "$supported_boot" ]; then
		echo "boot:$supported_boot"
	fi
}

extract_grub_boot_params() {
	for cfg in $(find /boot -name 'grub.cfg' -type f 2>/dev/null); do
		[ -r "$cfg" ] || continue
		local boot_params=""
		while IFS= read -r line; do
			case "$line" in
			*boot=live* | *rd.live.image* | *rd.live.squashimg=*)
				boot_params="${boot_params}boot=live "
				;;
			esac
		done <"$cfg"
		[ -n "$boot_params" ] && echo "grub:$boot_params" && return 0
	done
	return 1
}

STATUS "Detecting USB filesystem and boot method support..."
SUPPORTED_FSES=""
SUPPORTED_BOOT=""
GRUB_BOOT=""
DETECTED_METHODS=""

SUPPORTED_FSES=$(detect_initrd_boot_support 2>/dev/null | grep "^fs:" | sed 's/^fs://')
GRUB_BOOT=$(extract_grub_boot_params 2>/dev/null | grep "^grub:" | sed 's/^grub://')

if [ -n "$SUPPORTED_FSES" ]; then
	DEBUG "Initrd supports USB filesystems: $SUPPORTED_FSES"
	DEV_FSTYPE=$(blkid $DEV | tail -1 | grep -oE "TYPE="[^"]+" | sed 's/TYPE="//')
	if ! echo "$SUPPORTED_FSES" | grep -q "$DEV_FSTYPE"; then
		WARN "USB filesystem ($DEV_FSTYPE) may not be supported by this ISO's initrd"
		DEBUG "Supported filesystems: $SUPPORTED_FSES"
	fi
fi

if [ -z "$SUPPORTED_FSES" ]; then
	WARN "Could not detect filesystem support in ISO initrd"
	DEBUG "USB boot may fail if ISO initrd does not support your USB stick filesystem"
fi

STATUS "Detecting boot method..."
if [ -n "$SUPPORTED_BOOT" ]; then
	DETECTED_METHODS="$SUPPORTED_BOOT"
	DEBUG "Initrd supports boot methods: $DETECTED_METHODS"
else
	if [ -n "$GRUB_BOOT" ]; then
		DETECTED_METHODS="$GRUB_BOOT"
		DEBUG "GRUB config indicates boot methods: $DETECTED_METHODS"
	fi
fi

if [ -z "$DETECTED_METHODS" ]; then
	WARN "ISO may not boot from USB file: no supported boot method detected"
	if [ -x /bin/whiptail ]; then
		if ! whiptail_warning --title 'ISO BOOT COMPATIBILITY WARNING' --yesno \
			"ISO boot from USB file may not work.\n\nThis ISO does not appear to support booting from ISO file on USB stick.\n\nKnown compatible ISOs: Ubuntu, Debian Live, Tails, NixOS, Fedora Workstation, PureOS, Kicksecure.\n\nFor this ISO, try:\n- Use distribution USB creation tool (Ventoy, Rufus, etc)\n- Write ISO directly to USB with dd\n- Report to upstream that ISO should support USB file boot\n\nDo you want to try anyway?" \
			0 80; then
			DIE "ISO boot cancelled - unsupported ISO on USB file"
		fi
	else
		INPUT "ISO may not support USB file boot. Try anyway? [y/N]:" -n 1 response
		[ "$response" != "y" ] && [ "$response" != "Y" ] && DIE "ISO boot cancelled - unsupported ISO on USB file"
	fi
fi

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
