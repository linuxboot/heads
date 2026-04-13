#!/bin/bash
# Boot ISO file from USB media (ext4/fat/exfat USB stick)
#
# References:
# - https://wiki.archlinux.org/title/ISO_Spring_(%27Loop%27_device)
# - https://a1ive.github.io/grub2_loopback.html
#
# Boot Methods (detected via initrd strings analysis):
# - Dracut-based: iso-scan/filename=, findiso=, live-media=, boot=casper
#   Works: Ubuntu, Debian Live, Tails, NixOS, Fedora Workstation Live, PureOS
# - Anaconda-based: inst.stage2=hd:LABEL=, inst.repo=hd:LABEL=
#   Requires block device (CD-ROM or dd'd USB) - CANNOT boot from ISO file
#   Examples: Fedora Silverblue, Fedora Server, Qubes OS, Kicksecure
#
# Anaconda ISOs require: dd if=image.iso of=/dev/sdX or distribution media tool.
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

if [ "$ISO_BOOT_TYPE" != "hybrid" ]; then
	DEBUG "Non-hybrid ISO detected (CD-ROM only)"
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
		if find "$tmpdir" -type f 2>/dev/null | xargs strings 2>/dev/null | grep -qE "inst.repo"; then
			method="${method}inst.repo= "
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

resolve_grub_vars() {
	local params="$1"
	local iso_path="$2"
	local resolved=""

	resolved="${params//\$\{iso_path\}/$iso_path}"
	resolved="${resolved//\$\{isofile\}/$iso_path}"
	resolved="${resolved//\$iso_path/$iso_path}"
	resolved="${resolved//\$isofile/$iso_path}"

	echo "$resolved"
}

inspect_iso_boot_config() {
	local grub_cfg="$1"
	local iso_path="$2"
	local boot_params=""

	[ -f "$grub_cfg" ] || return 1

	while IFS= read -r line; do
		case "$line" in
		*inst.stage2=*)
			params="${line##*inst.stage2=}"
			params="${params%% *}"
			[ -n "$params" ] && boot_params="${boot_params} inst.stage2=${params}"
			;;
		*inst.repo=*)
			params="${line##*inst.repo=}"
			params="${params%% *}"
			[ -n "$params" ] && boot_params="${boot_params} inst.repo=${params}"
			;;
		*live-media=*)
			params="${line##*live-media=}"
			params="${params%% *}"
			[ -n "$params" ] && boot_params="${boot_params} live-media=${params}"
			;;
		*iso-scan/filename=* | *findiso=*)
			params="${line##*iso-scan/filename=}"
			[ "$params" = "$line" ] && params="${line##*findiso=}"
			params="${params%% *}"
			[ -n "$params" ] && boot_params="${boot_params} iso-scan/filename=${params}"
			;;
		*boot=casper*)
			boot_params="${boot_params} boot=casper"
			;;
		esac
	done <"$grub_cfg"

	if [ -n "$iso_path" ]; then
		boot_params=$(resolve_grub_vars "$boot_params" "$iso_path")
	fi

	echo "$boot_params"
	return 0
}

STATUS "Detecting ISO boot method..."
BOOT_METHODS=$(detect_iso_boot_method) || BOOT_METHODS=""
EXTRACTED_PARAMS=""

if [ -n "$BOOT_METHODS" ]; then
	DEBUG "Detected boot methods: $BOOT_METHODS"
else
	DEBUG "No built-in ISO boot support in initrd; checking GRUB config..."

	for cfg in $(find /boot -name '*.cfg' -type f 2>/dev/null); do
		[ -r "$cfg" ] || continue
		if grep -qE "iso.scan|findiso|live.media=|boot=casper" "$cfg" 2>/dev/null; then
			BOOT_METHODS="${BOOT_METHODS}grub "
			break
		fi
		if grep -qE "inst.repo=|inst.stage2=" "$cfg" 2>/dev/null; then
			BOOT_METHODS="${BOOT_METHODS}anaconda "
		fi
	done

	if [ -n "$BOOT_METHODS" ]; then
		DEBUG "Found boot support: $BOOT_METHODS"
	else
		WARN "ISO may not boot from USB file: no boot support in initrd"
		if [ -x /bin/whiptail ]; then
			if ! whiptail_warning --title 'ISO BOOT COMPATIBILITY WARNING' --yesno \
				"ISO boot from USB file may not work.\n\nThis ISO does not have iso-scan/findiso/live-media in its initrd - it was designed for CD/DVD or dd-to-USB.\n\nKernel parameters passed externally may not be sufficient.\n\nTry:\n- Use distribution-specific ISO (e.g., Debian hd-media)\n- Write ISO directly to USB with dd\n- Use a live USB image\n\nDo you want to proceed anyway?" \
				0 80; then
				DIE "ISO boot cancelled - unsupported ISO on USB file"
			fi
		else
			INPUT "Proceed with boot anyway? [y/N]:" -n 1 response
			[ "$response" != "y" ] && [ "$response" != "Y" ] && DIE "ISO boot cancelled - unsupported ISO on USB file"
		fi
	fi
fi

if echo "$BOOT_METHODS" | grep -qE "anaconda|inst.repo|inst.stage2"; then
	DEBUG "Anaconda-based ISO detected (inst.stage2=)"
fi

if [ -z "$BOOT_METHODS" ]; then
	for cfg in $(find /boot -name '*.cfg' -type f 2>/dev/null); do
		EXTRACTED_PARAMS=$(inspect_iso_boot_config "$cfg" "/${ISO_PATH}")
		[ -n "$EXTRACTED_PARAMS" ] && break
	done
	DEBUG "Extracted boot params from GRUB: $EXTRACTED_PARAMS"
fi

# Detect USB stick filesystem and validate initrd supports it
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
