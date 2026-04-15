#!/bin/bash
# Boot from signed ISO
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

	echo "$boot_content" | grep -qEi "iso.scan|findiso" &&
		supported_boot="${supported_boot}iso-scan/findiso " || true
	echo "$boot_content" | grep -qEi "live.media|live-media" &&
		supported_boot="${supported_boot}live-media= " || true
	echo "$boot_content" | grep -qEi "boot=live|rd.live.image|rd.live.squash" &&
		supported_boot="${supported_boot}boot=live " || true
	echo "$boot_content" | grep -qEi "boot.casper|casper" &&
		supported_boot="${supported_boot}boot=casper " || true
	echo "$boot_content" | grep -qEi "nixos" &&
		supported_boot="${supported_boot}nixos " || true
	echo "$boot_content" | grep -qEi "inst.stage2|inst.repo" &&
		supported_boot="${supported_boot}anaconda " || true
}

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
				boot_params="${boot_params}boot=live "
				;;
			*iso-scan/filename=* | *findiso=*)
				boot_params="${boot_params}iso-scan/findiso "
				;;
			*live-media=* | *live.media=*)
				boot_params="${boot_params}live-media= "
				;;
			*boot=casper* | *casper*)
				boot_params="${boot_params}boot=casper "
				;;
			*inst.stage2=* | *inst.repo=*)
				boot_params="${boot_params}anaconda "
				;;
			*nixos*)
				boot_params="${boot_params}nixos "
				;;
			esac
		done <"$cfg"
		[ -n "$boot_params" ] && echo "cfg:$boot_params" && return 0
	done
	return 1
}

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

if [ -z "$SUPPORTED_BOOT" ]; then
	DEBUG "No boot method in initrd, scanning *.cfg files..."
	CFG_BOOT=$(extract_boot_params_from_cfg 2>/dev/null | grep "^cfg:" | sed 's/^cfg://') || CFG_BOOT=""
	DEBUG "CFG_BOOT='$CFG_BOOT'"
else
	DEBUG "Boot method found in initrd, skipping cfg extraction"
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
	DEBUG "Initrd supports boot methods: $DETECTED_METHODS"
elif [ -n "$CFG_BOOT" ]; then
	DETECTED_METHODS="$CFG_BOOT"
	DEBUG "Boot config (*.cfg) indicates boot methods: $DETECTED_METHODS"
fi

DEBUG "DETECTED_METHODS='$DETECTED_METHODS'"
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
