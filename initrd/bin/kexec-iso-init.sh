#!/bin/bash
# Boot from signed ISO file on USB media
#
# This script handles booting from ISO files stored on USB storage.
# It works by mounting the ISO, detecting boot mechanisms supported by
# the ISO's initrd, injecting appropriate kernel parameters, and
# executing kexec to boot the OS.
#
# Detection approach:
# 1. Mount the ISO as a loopback device
# 2. Extract and scan the initrd for supported boot mechanisms
# 3. Fall back to scanning *.cfg files if initrd detection yields nothing
# 4. If no known boot-from-ISO mechanism is found, warn and guide user
#
# Supported boot mechanisms (detected in initrd or config):
# - iso-scan/findiso: Dracut-based (Ubuntu, Debian Live, Tails, etc.)
# - live-media: Dracut live-media parameter
# - boot=live: Debian Live / Fedora Live
# - boot=casper: Ubuntu Casper
# - nixos: NixOS
# - anaconda: Fedora/RHEL Anaconda (block device required)
# - overlay: OverlayFS support
# - toram: Load-to-RAM support
#
# If no mechanism is detected, the user is warned that the ISO may not
# support booting from ISO file on USB, and is given alternative options:
# - Write ISO directly to USB with dd
# - Use Ventoy in USB emulation mode
# - Boot from real DVD drive
#
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

DEV_UUID=$(blkid $DEV | tail -1 | tr " " "\n" | grep UUID | cut -d\" -f2)

# Scan an initrd for supported filesystems and boot mechanisms.
# This function unpacks the initrd and searches for:
# - Kernel modules (*.ko/*.ko.xz) -> supported filesystems
# - Scripts and configs (*.sh, *.conf, init, scripts/*) -> boot mechanisms
#
# Supported filesystems detected: ext4, vfat, exfat, ntfs, btrfs, xfs
# Supported boot mechanisms detected: iso-scan, live-media, boot-live,
#   casper, nixos, anaconda, overlay, toram, device
#
# Results are stored in global variables:
# - supported_fses: Space-separated list of supported filesystem types
# - supported_boot: Space-separated list of supported boot mechanisms
scan_initramfs() {
	local path="$1"
	local tmpdir=""
	local boot_content=""

	[ -r "$path" ] || return 1

	tmpdir=$(mktemp -d)
	/bin/bash /bin/unpack_initramfs.sh "$path" "$tmpdir" 2>/dev/null || true

	if [ -d "$tmpdir" ] && [ "$(ls -A "$tmpdir" 2>/dev/null)" ]; then
		while read ko; do
			name=$(basename "$ko")
			case "$name" in
			ext4*) supported_fses="${supported_fses}ext4 " ;;
			vfat* | msdos*) supported_fses="${supported_fses}vfat " ;;
			exfat*) supported_fses="${supported_fses}exfat " ;;
			ntfs*) supported_fses="${supported_fses}ntfs " ;;
			btrfs*) supported_fses="${supported_fses}btrfs " ;;
			xfs*) supported_fses="${supported_fses}xfs " ;;
			esac
		done < <(find "$tmpdir" -type f \( -name "*.ko" -o -name "*.ko.xz" \) 2>/dev/null)

		boot_content=$(find "$tmpdir" -type f \( -name "*.sh" -o -name "*.conf" -o -name "*.cfg" -o -name "init" -o -name "*.txt" -o -path "*/scripts/*" -o -path "*/conf/*" \) -print 2>/dev/null | xargs cat 2>/dev/null) || boot_content=""
		rm -rf "$tmpdir"
	else
		rm -rf "$tmpdir"
		boot_content=$(strings "$path" 2>/dev/null) || true
	fi

	for pattern in "iso.scan|findiso" "live.media|live-media" "boot=live|rd.live.image|rd.live.squash" "boot.casper|casper" "nixos" "inst.stage2|inst.repo" "overlay|overlayfs" "toram" "CDLABEL|img_dev|check_dev"; do
		case "$pattern" in
		iso.scan|findiso) label="iso-scan" ;;
		live.media|live-media) label="live-media" ;;
		boot=live|rd.live.image|rd.live.squash) label="boot-live" ;;
		boot.casper|casper) label="casper" ;;
		nixos) label="nixos" ;;
		inst.stage2|inst.repo) label="anaconda" ;;
		overlay|overlayfs) label="overlay" ;;
		toram) label="toram" ;;
		CDLABEL|img_dev|check_dev) label="device" ;;
		esac
		echo "$boot_content" | grep -qEi "$pattern" &&
			supported_boot="${supported_boot}${label} " || true
	done
}

# Detect if the mounted ISO is an installer ISO (not a live/bootable ISO).
# Installer ISOs (like Debian DVD installer) do not support booting from
# ISO file on USB - they only work with physical CD/DVD or PXE boot.
#
# Detection checks for:
# - /boot/install* directory (installer content)
# - /boot/isolinux or /boot/grub (boot configs, but no live boot)
# - /boot/install.amd/vmlinuz and initrd.gz (installer kernel/initrd)
#
# Detect boot mechanisms supported by the ISO's initrd.
# This function:
# 1. Parses all *.cfg files to find initrd paths
# 2. For each initrd, calls scan_initramfs() to extract supported features
# 3. Outputs two lines: "fs:..." and "boot:..." with detected support
#
# This is the primary detection method - scanning initrd content directly
# provides the most accurate picture of what the ISO can do.
detect_initrd_boot_support() {
	local supported_fses=""
	local supported_boot=""
	local initrd_paths=""

	for cfg in $(find /boot -name '*.cfg' -type f 2>/dev/null); do
		[ -r "$cfg" ] || continue
		while IFS= read -r entry; do
			[ -z "$entry" ] && continue
			initrd_field=$(echo "$entry" | tr '|' '\n' | grep '^initrd' | tail -1) || continue
			[ -z "$initrd_field" ] && continue
			initrd_val=$(echo "$initrd_field" | sed 's/^initrd //') || continue
			[ -z "$initrd_val" ] && continue
			for init in $(echo "$initrd_val" | tr ',' ' '); do
				[ -z "$init" ] && continue
				case " $initrd_paths " in
				*" $init "*) continue ;;
				esac
				initrd_paths="${initrd_paths}${init} "
			done
		done < <(/bin/bash /bin/kexec-parse-boot.sh /boot "$cfg" 2>/dev/null || true)
	done

	[ -z "$initrd_paths" ] && return 0

	for ipath in $initrd_paths; do
		full_path="/boot/${ipath#/}"
		[ -r "$full_path" ] && scan_initramfs "$full_path"
	done

	[ -n "$supported_fses" ] && echo "fs:$supported_fses"
	[ -n "$supported_boot" ] && echo "boot:$supported_boot"
	return 0
}

# Fallback detection: scan *.cfg files for boot parameters.
# This is used when initrd detection fails or yields no results.
# It greps through boot config files (GRUB, syslinux, ISOLINUX) for
# known boot parameters that indicate ISO-on-USB support.
#
# This method is less accurate than initrd scanning but can provide
# hints when initrd extraction fails.
extract_boot_params_from_cfg() {
	for cfg in $(find /boot -name '*.cfg' -type f 2>/dev/null); do
		[ -r "$cfg" ] || continue
		if ! grep -qE '^[^#]*(linux|menuentry|label|append)[[:space:]]' "$cfg" 2>/dev/null; then
			continue
		fi
		local boot_params=""
		while IFS= read -r line; do
			case "$line" in
			*boot=live* | *rd.live.image* | *rd.live.squashimg=*)
				if ! echo "$boot_params" | grep -q "boot-live"; then
					boot_params="${boot_params}boot-live "
				fi
				;;
			*iso-scan/filename=* | *findiso=*)
				if ! echo "$boot_params" | grep -q "iso-scan"; then
					boot_params="${boot_params}iso-scan "
				fi
				;;
			*live-media=* | *live.media=*)
				if ! echo "$boot_params" | grep -q "live-media"; then
					boot_params="${boot_params}live-media "
				fi
				;;
			*boot=casper* | *casper*)
				if ! echo "$boot_params" | grep -q "casper"; then
					boot_params="${boot_params}casper "
				fi
				;;
			*inst.stage2=* | *inst.repo=*)
				if ! echo "$boot_params" | grep -q "anaconda"; then
					boot_params="${boot_params}anaconda "
				fi
				;;
			*nixos*)
				if ! echo "$boot_params" | grep -q "nixos"; then
					boot_params="${boot_params}nixos "
				fi
				;;
			*overlay=* | *overlayfs*)
				if ! echo "$boot_params" | grep -q "overlay"; then
					boot_params="${boot_params}overlay "
				fi
				;;
			*toram*)
				if ! echo "$boot_params" | grep -q "toram"; then
					boot_params="${boot_params}toram "
				fi
				;;
			*CDLABEL=* | *img_dev=* | *check_dev*)
				if ! echo "$boot_params" | grep -q "device"; then
					boot_params="${boot_params}device "
				fi
				;;
			esac
		done <"$cfg"
		[ -n "$boot_params" ] && echo "cfg:$boot_params" && return 0
	done
	return 1
}

# ============================================================================
# Main detection flow
# ============================================================================
# Step 1: Scan initrd for supported boot mechanisms
# Step 2: If no boot method found, fall back to cfg file scanning
# Step 3: Check USB filesystem compatibility
# Step 4: If no known mechanism found, warn user with guidance
# ============================================================================

STATUS "Detecting USB filesystem and boot method support..."
SUPPORTED_FSES=""
SUPPORTED_BOOT=""
CFG_BOOT=""
DETECTED_METHODS=""

tmp_support=$(detect_initrd_boot_support 2>/dev/null) || tmp_support=""
SUPPORTED_FSES=$(echo "$tmp_support" | grep "^fs:" | sed 's/^fs://') || SUPPORTED_FSES=""
SUPPORTED_BOOT=$(echo "$tmp_support" | grep "^boot:" | sed 's/^boot://') || SUPPORTED_BOOT=""
DEBUG "SUPPORTED_FSES='$SUPPORTED_FSES'"
DEBUG "SUPPORTED_BOOT from initrd='$SUPPORTED_BOOT'"

DEBUG "Scanning *.cfg files to augment initrd results..."
CFG_BOOT=$(extract_boot_params_from_cfg 2>/dev/null | grep "^cfg:" | sed 's/^cfg://') || CFG_BOOT=""
DEBUG "CFG_BOOT='$CFG_BOOT'"

if [ -n "$SUPPORTED_BOOT" ] && [ -n "$CFG_BOOT" ]; then
	SUPPORTED_BOOT="$SUPPORTED_BOOT $CFG_BOOT"
	DEBUG "Combined boot methods: $SUPPORTED_BOOT"
elif [ -z "$SUPPORTED_BOOT" ] && [ -n "$CFG_BOOT" ]; then
	SUPPORTED_BOOT="$CFG_BOOT"
	DEBUG "Using cfg boot methods: $SUPPORTED_BOOT"
fi

if [ -n "$SUPPORTED_FSES" ]; then
	DEBUG "Initrd supports USB filesystems: $SUPPORTED_FSES"
	DEV_FSTYPE=$(blkid "$DEV" 2>/dev/null | tail -1 | grep -oE 'TYPE="[^"]+"' | sed 's/TYPE="//;s/"$//') || DEV_FSTYPE=""
	DEBUG "USB device filesystem type: '$DEV_FSTYPE'"
	if [ -n "$DEV_FSTYPE" ] && ! echo "$SUPPORTED_FSES" | grep -q "$DEV_FSTYPE" 2>/dev/null; then
		WARN "USB filesystem ($DEV_FSTYPE) may not be supported by this ISO's initrd"
		DEBUG "Supported filesystems: $SUPPORTED_FSES"
	fi || true
fi

if [ -n "$SUPPORTED_BOOT" ]; then
	DETECTED_METHODS="$SUPPORTED_BOOT"
	DEBUG "Detected boot methods: $DETECTED_METHODS"
fi

DEBUG "DETECTED_METHODS='$DETECTED_METHODS'"
if [ -z "$DETECTED_METHODS" ]; then
	WARN "ISO may not boot from USB file: no supported boot method detected"
	if [ -x /bin/whiptail ]; then
		if ! whiptail_warning --title 'ISO BOOT NOT SUPPORTED' --yesno \
			"This ISO does not support booting from ISO file on USB.\n\nThe initrd does not include boot-from-ISO mechanisms (no live-boot, casper, fromiso, iso-scan, anaconda, or nixos support detected).\n\nTo use this ISO, write the hybrid image directly to a USB flash drive:\n\nLinux: sudo cp image.iso /dev/sdX (Be cautious!)\nWindows/Mac: Use Rufus, select DD mode (NOT ISO mode)\n\nWrite to whole-disk device (NOT a partition, e.g. /dev/sdX not /dev/sdX1),\nthen boot from USB device directly (not as ISO file).\n\nSee Debian wiki: https://wiki.debian.org/DebianInstall" \
			0 80; then
			DIE "ISO boot cancelled - initrd does not support USB file boot"
		fi
	else
		ERROR "ISO initrd has no boot-from-ISO support (no live-boot/casper/iso-scan)"
		ERROR "Write hybrid image to USB: Linux: cp iso /dev/sdX | Win/Mac: Rufus DD mode"
		INPUT "Try anyway? [y/N]:" -n 1 response
		[ "$response" != "y" ] && [ "$response" != "Y" ] && DIE "ISO boot cancelled"
	fi
fi

# ============================================================================
# Boot parameter injection
# ============================================================================
# Inject all known boot-from-ISO parameters. The ISO's initrd will use
# whichever parameters it understands and ignore the rest.
#
# Parameters injected (covering all major boot systems):
# - findiso, fromiso, iso-scan/filename: Dracut standard
# - img_dev, img_loop: additional Dracut variants
# - iso: alternative parameter
# - live-media, live-media-path: live-boot parameters
# - boot=live, boot=casper: casper/live-boot parameters
# ============================================================================

ISO_DEV="/dev/disk/by-uuid/$DEV_UUID"
ISO_PATH_ABS="/$ISO_PATH"

base_params="findiso=$ISO_DEV/$ISO_PATH fromiso=$ISO_DEV/$ISO_PATH iso-scan/filename=$ISO_PATH_ABS img_dev=$ISO_DEV img_loop=$ISO_PATH iso=$DEV_UUID/$ISO_PATH"

add_params=""
if echo "$DETECTED_METHODS" | grep -q "casper"; then
	add_params="$add_params boot=casper live-media-path=casper"
fi
if echo "$DETECTED_METHODS" | grep -q "boot-live"; then
	add_params="$add_params boot=live"
fi
if echo "$DETECTED_METHODS" | grep -q "live-media"; then
	add_params="$add_params live-media=$ISO_DEV/$ISO_PATH"
fi

ADD="$base_params $add_params"
DEBUG "Injecting boot params: $ADD"
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
