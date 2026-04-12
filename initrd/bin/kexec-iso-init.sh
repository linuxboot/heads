#!/bin/bash
# Boot ISO file from USB media (ext4/fat/exfat USB stick)
# Tests ISO initrd for boot capability: USB, loop, filesystem, and boot quirk
#
# References:
# - https://wiki.archlinux.org/title/ISO_Spring_(%27Loop%27_device)
# - https://a1ive.github.io/grub2_loopback.html
#
# ISO Boot Requirements:
# 1. Initrd must support USB storage (load usb-storage module)
# 2. Initrd must support loopback (for mounting ISO file)
# 3. Initrd must have filesystem drivers (ext4, vfat, exfat for USB stick)
# 4. Initrd must have boot quirk script to find ISO on USB:
#    - findiso= (Debian, NixOS)
#    - iso-scan/filename= (Ubuntu)
#    - live-media= (Tails, Ubuntu variants)
#    - boot=casper (Ubuntu/Debian Live)
#    - inst.stage2= (Fedora)
#
# Known good ISOs (tested working 2026-04):
# | Distribution | Boot Param | USB FS | Status |
# |------------|----------|---------|--------|
# | Ubuntu Desktop | iso-scan/filename | ext4/vfat/exfat | works |
# | Debian Live (kde/xfce) | findiso | ext4/vfat/exfat | works |
# | Tails 7.6 | live-media=removable | ext4/vfat | works |
# | Tails exfat ISO | live-media=removable | exfat | works |
# | Fedora Workstation | boot=casper | ext4/vfat | works |
# | NixOS | findiso | ext4/vfat/exfat | works |
# | PureOS | boot=casper | ext4/vfat/exfat | works |
#
# Known bad ISOs (workaround: use dd or distribution tool):
# - Debian DVD: `dd if=debian.iso of=/dev/sdX` (hybrid ISO works)
# - Fedora Silverblue: Fedora Media Writer (anaconda, not ISO file boot)
# - Tails on exfat USB: Use Tails exfat-support ISO instead
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

STATUS "Mounting ISO and booting"
mount -t iso9660 -o loop $MOUNTED_ISO_PATH /boot ||
	DIE '$MOUNTED_ISO_PATH: Unable to mount /boot'

detect_iso_boot_method() {
	local method=""
	local found=0

	for path in $(find /boot -name 'initrd*' -type f 2>/dev/null | head -5); do
		[ -r "$path" ] || continue
		tmpdir=$(mktemp -d)
		/bin/bash /bin/unpack_initramfs.sh "$path" "$tmpdir" 2>/dev/null

		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "iso.scan|findiso"; then
			method="${method}iso-scan/findiso "
			found=1
		fi
		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "live.media|live-media"; then
			method="${method}live-media= "
			found=1
		fi
		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "inst.stage2|inst\.stage2"; then
			method="${method}inst.stage2= "
			found=1
		fi
		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "boot.casper|live-boot|casper"; then
			method="${method}boot=casper "
			found=1
		fi
		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "nixos"; then
			method="${method}nixos "
			found=1
		fi
		rm -rf "$tmpdir"
	done

	if [ $found -eq 0 ]; then
		return 1
	fi
	echo "$method"
	return 0
}

STATUS "Detecting ISO boot method..."
BOOT_METHODS=$(detect_iso_boot_method) || BOOT_METHODS=""

if [ -n "$BOOT_METHODS" ]; then
	STATUS_OK "Detected boot methods: $BOOT_METHODS"
else
	NOTE "No built-in ISO boot support in initrd; checking GRUB config..."

	for cfg in $(find /boot -name '*.cfg' -type f 2>/dev/null); do
		[ -r "$cfg" ] || continue
		# Check for true ISO boot params
		if grep -qE "iso.scan|findiso|live.media=|boot=casper" "$cfg" 2>/dev/null; then
			NOTE "GRUB config found with boot parameters"
			BOOT_METHODS="${BOOT_METHODS}grub "
			break
		fi
		# inst.stage2= is anaconda-specific - does NOT support ISO file boot
		# It requires exact USB LABEL match, which we can't provide
		# Fedora Silverblue uses this and will fail
		if grep -qE "inst.stage2=" "$cfg" 2>/dev/null; then
			NOTE "WARNING: inst.stage2= found (anaconda) - not ISO file boot"
			NOTE "This requires exact USB label match and won't work with ISO file"
		fi
	done

	if [ -n "$BOOT_METHODS" ]; then
		STATUS_OK "Found boot support: $BOOT_METHODS"
	else
		WARN "ISO may not boot from USB file: no boot support in initrd"
		if [ -x /bin/whiptail ]; then
			if ! whiptail_warning --title 'ISO BOOT COMPATIBILITY WARNING' --yesno \
				"ISO boot from USB file may not work.\n\nThis ISO does not have iso-scan/findiso/live-media in its initrd - it was designed for CD/DVD or dd-to-USB.\n\nKernel parameters passed externally may not be sufficient.\n\nTry:\n- Use distribution-specific ISO (e.g., Debian hd-media)\n- Write ISO directly to USB with dd\n- Use a live USB image\n\nDo you want to proceed anyway?" \
				0 80; then
				DIE "ISO boot cancelled - unsupported ISO on USB file"
			fi
		else
			NOTE "This ISO does not have iso-scan in initrd"
			NOTE "Try: dd ISO to USB, or use live USB image"
			INPUT "Proceed with boot anyway? (y/N):" -n 1 response
			if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
				DIE "ISO boot cancelled - unsupported ISO on USB file"
			fi
		fi
	fi
fi

# Detect USB stick filesystem and validate initrd supports it
DEV_UUID=$(blkid $DEV | tail -1 | tr " " "\n" | grep UUID | cut -d\" -f2)
ISO_LABEL=$(blkid $MOUNTED_ISO_PATH | tr " " "\n" | grep LABEL | cut -d\" -f2 || echo "")
[ -z "$ISO_LABEL" ] && ISO_LABEL="${ISO_PATH%.iso}"

USB_FS=$(blkid $DEV | grep -oE 'TYPE="[^"]+' | cut -d'"' -f2 || echo "unknown")
NOTE "USB stick filesystem: $USB_FS"

# Check if ISO initrd supports reading from this filesystem using strings
# (unpack_initramfs.sh may fail on some initrd formats, use strings as fallback)
fs_supported=""
for path in $(find /boot -name 'initrd*' -type f 2>/dev/null | grep -v '/install/' | head -3); do
	[ -r "$path" ] || continue

	initrd_content=$(strings "$path" 2>/dev/null)

	if echo "$initrd_content" | grep -q "ext4.ko"; then
		has_ext4=yes
		DEBUG "ISO initrd has ext4.ko"
	else
		has_ext4=no
	fi
	if echo "$initrd_content" | grep -q "vfat.ko"; then
		has_vfat=yes
		DEBUG "ISO initrd has vfat.ko"
	else
		has_vfat=no
	fi
	if echo "$initrd_content" | grep -q "exfat.ko"; then
		has_exfat=yes
		DEBUG "ISO initrd has exfat.ko"
	else
		has_exfat=no
	fi
	if echo "$initrd_content" | grep -qE "findiso|live.media|boot.casper"; then
		DEBUG "ISO initrd has ISO boot quirk built-in"
	fi

	DEBUG "ISO initrd FS support: ext4=$has_ext4 vfat=$has_vfat exfat=$has_exfat"

	case "$USB_FS" in
	ext4 | ext3 | ext2)
		[ "$has_ext4" = "yes" ] && fs_supported="yes"
		;;
	vfat | fat32 | fat16)
		[ "$has_vfat" = "yes" ] && fs_supported="yes"
		;;
	exfat)
		[ "$has_exfat" = "yes" ] && fs_supported="yes"
		;;
	*)
		fs_supported="unknown"
		;;
	esac
	[ -n "$fs_supported" ] && break
done

if [ "$fs_supported" != "yes" ]; then
	WARN "ISO initrd may not support reading from $USB_FS filesystem"
	if [ "$USB_FS" = "exfat" ]; then
		NOTE "Tails does not include exfat support in initrd (use ext4 or vfat USB)"
	fi
fi

INFO "Using UUID=$DEV_UUID ISO_LABEL=$ISO_LABEL for boot params"

ADD="fromiso=/dev/disk/by-uuid/$DEV_UUID/$ISO_PATH img_dev=/dev/disk/by-uuid/$DEV_UUID iso-scan/filename=/${ISO_PATH} img_loop=$ISO_PATH findiso=/${ISO_PATH} boot=live boot=casper fromiso=/${ISO_PATH} isoboot=/${ISO_PATH} bootfromiso=/${ISO_PATH} archisobasedir= live-media=removable live-media=toram inst.stage2=hd:LABEL=${ISO_LABEL} inst.stage2=hd:UUID=$DEV_UUID nixos=boot-configuration nixos.backend=external nixos.system=/boot/nixos/system initrd=boot/initrdyes"
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
