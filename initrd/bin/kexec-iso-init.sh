#!/bin/bash
# Boot from signed ISO
#
# Design overview
# ---------------
# This script implements layered ISO boot for Heads (in execution order):
#   Layer 1 — initramfs compatibility check (verifies the ISO's initrd
#             can read the USB filesystem and has a framebuffer driver
#             before offering boot options)
#   Layer 2 — loopback.cfg fast path (parse GRUB ${iso_path} / ${isofile}
#             variables from the ISO's standard USB-boot config)
#   Layer 3 — kexec-select-boot.sh (interactive boot menu, called at the
#             end of this script — the user picks a kernel/initrd entry)
#
# The layered approach (loopback.cfg resolution, universal fallback params)
# was inspired by u-root's boot/iso implementation:
#   https://github.com/u-root/u-root/pull/3578
#
# The fallback ADD params below apply when Layer 2 finds no GRUB variables
# in the loopback.cfg.  These params are universal — every common Linux
# initramfs framework finds the ISO via at least one of them.
#
# ADD parameter set (fallback, used when loopback.cfg has no GRUB vars):
#
#   iso-scan/filename=/$ISO_PATH    Ubuntu casper, Fedora dracut
#   findiso=/$ISO_PATH              Debian live-boot, NixOS stage-1
#   img_dev=/dev/disk/by-uuid/UUID  block device containing the ISO
#   img_loop=$ISO_PATH              loopback file path (relative)
#   iso=$DEV_UUID/$ISO_PATH         UUID/path alternative
#   live-media=/dev/disk/by-uuid/UUID  device filter (casper, live-boot)
#
# Each initramfs framework picks what it understands and ignores the rest.
# Unrecognised kernel parameters are passed to userspace harmlessly.
#
# Changes from origin/master
# ---------------------------
# origin/master ADD was:
#   fromiso=/dev/disk/by-uuid/UUID/ISO  img_dev=...  iso-scan/filename=...
#   img_loop=...  iso=...
#
# Our ADD adds:
#   findiso=/$ISO_PATH       — covers NixOS (not supported by origin/master)
#   live-media=$ISO_DEV      — device filter for casper/live-boot
#
# Our ADD removes:
#   fromiso=...              — conflicts with findiso in Debian live-boot's
#                              check_dev(): fromiso mounts the ISO, then
#                              findiso looks for the ISO file inside the
#                              mounted ISO (not found), unmounts it, leaving
#                              orphaned loop devices that get re-scanned →
#                              infinite loop.  findiso alone covers Debian.
#
# Origin/master used fromiso= as the only Debian live-boot path.  We
# replaced it with findiso= which Debian live-boot also supports, and
# which additionally covers NixOS.
#
# Layer 1 per-initrd markers
# ---------------------------
# Each unique initrd referenced by any boot entry gets an independent
# [OK] or [!] marker in /tmp/kexec_initrd_compat.txt (filesystem).
# Framebuffer markers are written to /tmp/kexec_fb_compat.txt.
# The per-initrd flag (initrd_supports_fs) is tracked separately from the
# global "any_supported" flag so that every initrd always gets an entry —
# no silent skips.  ALL initrds are checked (no early break) so the
# compat file is complete.  The global flag only controls whether a
# whiptail warning is shown.
#
# Minor changes from origin/master
# ---------------------------------
# - STATUS messages: "Mounting ISO as loopback" (was "Mounting ISO and
#   booting"), added "Checking USB filesystem compatibility" and
#   "Passing boot parameters so the OS can find the ISO"
# - Variable quoting: "$ADD_FILE" "$REMOVE_FILE" "$paramsdir" (was bare)
# - Syntax: $(...) instead of backticks for DEV_UUID
# - Removed stale "# Call kexec and indicate that hashes have been verified" comment
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
	if ! gpgv.sh --homedir=/etc/distro/ "$ISOSIG" "$MOUNTED_ISO_PATH"; then
		WARN "ISO signature verification failed: $ISOSIG"
		WARN "See Recovery Shell wall message for instructions to sign or boot unsigned"
		DIE "ISO signature verification failed"
	else
		STATUS_OK "ISO signature verified"
		# Skip unsigned warning — jump past the unsigned block
		skip_unsigned_warning="y"
	fi
fi

if [ "$skip_unsigned_warning" != "y" ]; then
	# No valid signature — prompt user with warning
	WARN "No signature found for ISO"
	if [ -x /bin/whiptail ]; then
		if ! whiptail_warning --title 'UNSIGNED ISO WARNING' --yesno \
			"WARNING: UNSIGNED ISO DETECTED\n\nThe selected ISO file:\n$MOUNTED_ISO_PATH\n\nDoes not have a detached signature.\nIntegrity and authenticity cannot be verified.\n\nCancel to Recovery Shell for instructions on signing this ISO\nwith your GPG key, or boot unsigned now.\n\nBoot unsigned?" \
			0 80; then
			DIE "Unsigned ISO boot cancelled by user"
		fi
	else
		WARN "The selected ISO file does not have a detached signature"
		WARN "Integrity and authenticity of the ISO cannot be verified"
		WARN "Abort and sign from Recovery Shell (see wall message for instructions)"
		INPUT "Do you want to proceed anyway? (y/N):" -n 1 response
		if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
			DIE "Unsigned ISO boot cancelled by user"
		fi
	fi
	NOTE "Proceeding with unsigned ISO boot"
fi

STATUS "Mounting ISO as loopback"
mount -t iso9660 -o loop "$MOUNTED_ISO_PATH" /boot \
	|| DIE '$MOUNTED_ISO_PATH: Unable to mount /boot'
STATUS_OK "ISO mounted at /boot"

DEV_UUID=$(blkid "$DEV" | tail -1 | tr " " "\n" | grep UUID | cut -d\" -f2)

# ---------------------------------------------------------------------------
# Layer 1: initramfs compatibility check (filesystem + framebuffer)
# ---------------------------------------------------------------------------
STATUS "Checking initramfs compatibility with ISO boot environment"
# Before proposing boot options, verify the ISO's initramfs contains a kernel
# module for the USB filesystem type, and a framebuffer driver (efifb) that can
# drive the display after kexec without DRM/KMS reinit.  If the initrd can't
# read the partition where the ISO lives, or can't drive the display, the boot
# will fail or be blind after kexec.
#
# We find initrd paths by parsing the ISO's boot configs — the same way
# kexec-select-boot.sh enumerates boot entries.  GRUB/syslinux configs
# specify initrd via "initrd /path" directives, so we extract those paths
# rather than searching the entire ISO filesystem tree.
#
# Multiple entries may reference different initrds (e.g., text vs graphical
# installer).  We check ALL unique initrds and accept if ANY one has the
# needed USB filesystem module.  This handles hybrid ISOs where one initrd
# supports ext4 and another doesn't.
#
# The kernel module for a filesystem almost always matches the blkid
# TYPE (ext4 → ext4.ko, btrfs → btrfs.ko).  Only vfat/msdos differ
# (kernel module is "fat"), handled by initrd_fs_type_to_kmod().
# No hardcoded module list — any filesystem type is supported.

# Map blkid filesystem type to kernel module name.
# The kernel module for a filesystem is almost always the same as the
# blkid TYPE string (ext4 → ext4, btrfs → btrfs, xfs → xfs).
# Only vfat/msdos are exceptions (kernel module is "fat", not "vfat").
initrd_fs_type_to_kmod() {
	case "$1" in
	vfat|msdos)	echo "fat" ;;
	*)		echo "$1" ;;
	esac
}

check_initrd_compat() {
	local dev="$1"
	local bootdir="$2"

	local fstype
	# BusyBox blkid doesn't support -o value consistently — parse TYPE from full output
	fstype=$(blkid "$dev" 2>/dev/null | tr ' ' '\n' | sed -n 's/^TYPE="\(.*\)"$/\1/p')
	# blkid on a whole disk (e.g. /dev/sda) returns no TYPE — scan /dev for partitions
	if [ -z "$fstype" ]; then
		local devbase="${dev#/dev/}"
		for part in /dev/${devbase}*; do
			[ "$part" = "$dev" ] && continue
			[ -b "$part" ] || continue
			fstype=$(blkid "$part" 2>/dev/null | tr ' ' '\n' | sed -n 's/^TYPE="\(.*\)"$/\1/p')
			[ -n "$fstype" ] && DEBUG "Layer 1: resolved $dev -> $part ($fstype)" && break
		done
	fi
	# Still no TYPE? The USB is already mounted by media-scan.sh — check /proc/mounts
	if [ -z "$fstype" ]; then
		fstype=$(awk -v dev="$dev" 'index($1, dev) == 1 { print $3; exit }' /proc/mounts 2>/dev/null)
		[ -n "$fstype" ] && DEBUG "Layer 1: resolved $dev via /proc/mounts ($fstype)"
	fi
	# No filesystem detected — skip check (can't determine what module to look for)
	[ -z "$fstype" ] && DEBUG "Layer 1: no filesystem type for $dev (skipping)" && return 0
	DEBUG "Layer 1: USB device $dev filesystem=$fstype"
	DEBUG "Layer 1: USB drive is $fstype - verifying initramfs module support"
	echo "$fstype" > /tmp/kexec_usb_fstype

	case "$fstype" in
	squashfs|iso9660|udf)
		# Read-only filesystems: kernel has built-in support, no module needed
		DEBUG "Layer 1: skip $fstype (read-only, built-in kernel support)"
		return 0
	esac

	local kernel_mod
	kernel_mod=$(initrd_fs_type_to_kmod "$fstype")
	DEBUG "Layer 1: kernel module needed for $fstype: $kernel_mod"

	# Find initrd from parsed boot entries — walk .cfg files the same way
	# kexec-select-boot.sh does, extract initrd paths from the pipe-delimited output.
	local entries_file
	entries_file=$(mktemp -p /tmp -t iso_initrd_entries.XXXXXX)
	while IFS= read -r cfg; do
		[ -f "$cfg" ] || continue
		case "$cfg" in *EFI*|*efi*|*x86_64-efi*) continue ;; esac
		kexec-parse-boot.sh "$bootdir" "$cfg" >>"$entries_file" 2>/dev/null || true
	done < <(find "$bootdir" -name '*.cfg' -type f 2>/dev/null)

	# Collect all unique initrd paths from parsed boot entries
	# Entries are pipe-delimited: name|type|kernel|initrd <path>|append <params>
	# Field 4 starts with "initrd " if the entry has an initrd.
	local initrd_paths=""
	while IFS= read -r entry; do
		[ -z "$entry" ] && continue
		local entry_field4 initrd_relpath
		entry_field4=$(echo "$entry" | cut -d\| -f4)
		case "$entry_field4" in
			initrd\ *)
				initrd_relpath="${entry_field4#initrd }"
				# Dedup: skip if already in list
				[ -f "$bootdir/$initrd_relpath" ] || continue
				case " $initrd_paths " in
					*" $initrd_relpath "*) ;;
					*) initrd_paths="$initrd_paths $initrd_relpath" ;;
				esac
				;;
		esac
	done < "$entries_file"
	rm -f "$entries_file"
	# No initrd referenced by any boot entry — nothing to check
	[ -z "$initrd_paths" ] && DEBUG "Layer 1: no initrd paths in boot entries" && return 0

	# Check all initrds — return OK if ANY has the needed USB fs module.
	# Each initrd gets its own [OK]/[!] marker independently in the compat file.
	# The per-initrd flag (initrd_supports_fs) is independent of the global
	# "any_supported" flag — every initrd always gets an entry in the compat file
	# (no silent skips), and ALL initrds are processed (no early break on first OK).
	local any_supported="n"
	local fs_compat_file="/tmp/kexec_initrd_compat.txt"
	local fb_compat_file="/tmp/kexec_fb_compat.txt"
	: > "$fs_compat_file"
	: > "$fb_compat_file"
	local initrd_relpath initrd_abspath
	for initrd_relpath in $initrd_paths; do
		initrd_abspath="$bootdir/$initrd_relpath"
		DEBUG "Layer 1: checking initrd=$initrd_abspath"
		local unpack_dir
		unpack_dir=$(mktemp -p /tmp -d)
		unpack_initramfs.sh "$initrd_abspath" "$unpack_dir" 2>/dev/null || true
		if [ -z "$(ls -A "$unpack_dir" 2>/dev/null)" ]; then
			DEBUG "Layer 1: unpack_dir empty — initrd may be corrupt or unsupported format"
		fi

		local initrd_supports_fs=""	# ""=can't verify, "[OK]"=verified ok, "[!]"=verified not ok
		local initrd_supports_fb=""
		local ko_files
		ko_files=$(find "$unpack_dir" -name "*.ko*" -type f 2>/dev/null | head -1) || true
		if [ -z "$ko_files" ]; then
			# No loadable kernel modules in this initrd at all.
			# Can't verify one way or the other — the driver might
			# be built into the kernel or this could be a minimal
			# initrd that doesn't need the USB fs.  Write no marker.
			DEBUG "Layer 1: $initrd_relpath no modules (cannot verify)"
		else
			# Initrd has loadable modules — check if it has the
			# kernel module for the USB filesystem ($kernel_mod).
			# Use variable capture instead of pipe with grep -q: with
			# set -e -o pipefail, grep -q terminates find via SIGPIPE,
			# and pipefail propagates find's non-zero exit (141) instead
			# of grep's success (0), making the if condition fail.
			local ko_match
			ko_match=$(find "$unpack_dir" -name "*.ko*" 2>/dev/null | grep "${kernel_mod}" 2>/dev/null | head -1) || true
			if [ -n "$ko_match" ]; then
				initrd_supports_fs="[OK]"
				DEBUG "Layer 1: $initrd_relpath has module $kernel_mod"
			elif grep -q "${kernel_mod}" "$unpack_dir/lib/modules/"*/modules.builtin 2>/dev/null; then
				initrd_supports_fs="[OK]"
				DEBUG "Layer 1: $initrd_relpath has $kernel_mod built-in (modules.builtin)"
			else
				# Has modules but not the needed one — definite fail
				initrd_supports_fs="[!]"
				DEBUG "Layer 1: $initrd_relpath has modules but no $kernel_mod"
			fi

			# Check for DRM/KMS display drivers in the initrd.  These
			# reinitialize the display after kexec and make the booted
			# OS visible regardless of efifb availability.  All major
			# distributions ship at least one (i915, nouveau, amdgpu,
			# bochs, virtio-gpu, etc.) as loadable .ko modules.
			# If none found and the initrd has other .ko files, the
			# ISO is likely a minimal distribution without display
			# support (e.g. CorePlus/TinyCore).
			local fb_drivers="i915\|nouveau\|amdgpu\|radeon\|bochs\|virtio-gpu\|cirrus\|qxl\|mgag200\|ast"
			local fb_match
			fb_match=$(find "$unpack_dir" -name "*.ko*" 2>/dev/null | grep -E "$fb_drivers" 2>/dev/null | head -1) || true
			if [ -n "$fb_match" ]; then
				initrd_supports_fb="[OK]"
				DEBUG "Layer 1: $initrd_relpath has DRM/KMS driver ($(basename $fb_match))"
			else
				initrd_supports_fb="[!]"
				DEBUG "Layer 1: $initrd_relpath has modules but no DRM/KMS driver"
			fi
		fi

		# Write per-initrd markers to compat files.
		if [ -n "$initrd_supports_fs" ]; then
			echo "${initrd_relpath#/} $initrd_supports_fs" >> "$fs_compat_file"
			[ "$initrd_supports_fs" = "[OK]" ] && [ "$any_supported" = "n" ] && any_supported="y"
		fi
		if [ -n "$initrd_supports_fb" ]; then
			echo "${initrd_relpath#/} $initrd_supports_fb" >> "$fb_compat_file"
		fi
		rm -rf "$unpack_dir"
	done

	# Dump compat file contents to debug log so users can see per-initrd markers
	if [ -s "$fs_compat_file" ]; then
		while IFS= read -r line; do DEBUG "Layer 1: fs compat: $line"; done < "$fs_compat_file"
	fi
	if [ -s "$fb_compat_file" ]; then
		while IFS= read -r line; do DEBUG "Layer 1: fb compat: $line"; done < "$fb_compat_file"
	fi

	# At least one initrd verifiably supports the USB filesystem —
	# proceed without warning.
	[ "$any_supported" = "y" ] && return 0

	# No initrd confirmed support.  The [!] markers (or absence of
	# markers for no-module initrds) will inform the user in the menu.
	# We still proceed since unverifiable initrds may work fine.
	DEBUG "Layer 1: no initrd has $kernel_mod as .ko (likely built-in kernel support)"
}

check_initrd_compat "$DEV" "/boot"
STATUS_OK "Initramfs compatibility check complete"

# If no initrd confirmed support for the USB filesystem, warn the user
# that this ISO is designed for direct USB writing rather than kexec boot
fs_compat_file="/tmp/kexec_initrd_compat.txt"
if [ -s "$fs_compat_file" ] && ! grep -qF '[OK]' "$fs_compat_file"; then
	_fstype=$(cat /tmp/kexec_usb_fstype 2>/dev/null || echo "USB")
	if [ -x /bin/whiptail ]; then
		if ! whiptail_warning --title 'USB Compatibility Warning' --yesno \
			"No Verified Compatible Boot Option\n\nNone of this ISO's initramfs images contain\n${_fstype} support.\n\nThis ISO is likely designed to be written directly to a\nUSB drive (hybrid ISO).  Use the upstream recommended\nmethod to create a bootable USB instead.\n\nYou may still attempt to boot - the ${_fstype} module may\nbe built into the kernel rather than loaded from initramfs.\n\nProceed anyway?" \
			0 80; then
			DIE "Incompatible ISO boot cancelled by user"
		fi
	else
		WARN "No boot option confirmed compatible with ${_fstype} filesystem"
		WARN "The ISO was likely designed for direct USB writing - use the upstream method to create a bootable USB"
		INPUT "Proceed anyway? (y/N):" -n 1 response
		if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
			DIE "Incompatible ISO boot cancelled by user"
		fi
	fi
fi

# If no initrd confirmed a display driver (i915, nouveau, etc.), warn
# that the screen may be blank after kexec — the kernel boots but has
# no way to show output on the display without a KMS or fbdev driver.
fb_compat_file="/tmp/kexec_fb_compat.txt"
if [ -s "$fb_compat_file" ] && ! grep -qF '[OK]' "$fb_compat_file"; then
	if [ -x /bin/whiptail ]; then
		if ! whiptail_warning --title 'Display Driver Warning' --yesno \
			"Unverified Display Support\n\nThe ISO's initramfs does not contain a\ndisplay driver for your hardware.\n\nThe screen may be blank after boot even\nif the operating system starts normally.\n\nThis is expected for minimal distributions\nsuch as CorePlus/TinyCore.\n\nProceed anyway?" \
			0 80; then
			DIE "Boot cancelled by user"
		fi
	else
		WARN "ISO has no display driver - screen may be blank after boot"
		WARN "This is expected for minimal distributions such as CorePlus/TinyCore"
		INPUT "Proceed anyway? (y/N):" -n 1 response
		if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
			DIE "Boot cancelled by user"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# Layer 2: loopback.cfg fast path
# ---------------------------------------------------------------------------
# loopback.cfg is the ISO 9660 standard for declaring boot entries on a
# hybrid ISO.  If the ISO ships one, its GRUB variables (${iso_path},
# ${isofile}) tell us the kernel parameters needed to find and mount the
# ISO from USB.  This approach is borrowed from u-root's boot/iso support.
ADD=""
REMOVE=""

for lb_cfg in "boot/grub/loopback.cfg" "boot/grub2/loopback.cfg"; do
	if [ -r "/boot/$lb_cfg" ]; then
		DEBUG "Layer 2: found $lb_cfg"
		STATUS "ISO supports USB boot - reading boot configuration"

		option_file="/tmp/kexec_options.txt"
		scan_boot_options "/boot" "$lb_cfg" "$option_file" 2>/dev/null || true

		if [ -s "$option_file" ]; then
			while IFS= read -r entry; do
				[ -z "$entry" ] && continue
				append_field=$(echo "$entry" | tr '|' '\n' | grep '^append' | head -1) || true
				if [ -n "$append_field" ]; then
					append_val=$(echo "$append_field" | sed 's/^append //')
					GRUB_VARS_FOUND="n"
					# GRUB supports two variable syntaxes: ${var} and $var.
					# Loopback.cfg entries typically use ${iso_path} or ${isofile};
					# check both forms and substitute the actual ISO path.
					resolved="$append_val"
					for var_name in iso_path isofile; do
						for grub_var_ref in '${'$var_name'}' '$'$var_name; do
							if echo "$resolved" | grep -qF "$grub_var_ref"; then
								resolved="${resolved//$grub_var_ref/$ISO_PATH}"
								GRUB_VARS_FOUND="y"
							fi
						done
					done
				if [ "$GRUB_VARS_FOUND" = "y" ]; then
					DEBUG "Layer 2: resolved GRUB vars: $append_val -> $resolved"
					ADD="$resolved"
				fi
				fi
			done <"$option_file"
			rm -f "$option_file"
		fi

		if [ -z "$ADD" ]; then
			DEBUG "Layer 2: loopback.cfg found but no boot entries with GRUB vars"
		else
			STATUS_OK "Layer 2: loopback.cfg boot params resolved"
		fi
		break
	fi
done

# Layer 2 resolved nothing — build fallback ADD params with all common
# ISO boot methods, both relative and device-by-UUID paths, so the ISO
# initrd can find the ISO regardless of distribution.
# Each framework picks what it recognises:
#   iso-scan/filename= — Ubuntu casper, Fedora dracut, Kicksecure
#   findiso=           — Debian live-boot, NixOS stage-1
#   img_dev=           — block device (generic)
#   img_loop=          — loopback file path (generic)
#   iso=               — UUID/path alternative (generic)
#   live-media=        — casper (Ubuntu, PureOS), live-boot (Debian)
#
# Parameters NOT injected (with rationale):
#   fromiso=           — conflicts with findiso in Debian live-boot's
#                        check_dev() causing infinite loop device storm.
#                        Replaced by findiso= which covers Debian too.
#   live-media-path=   — distro-specific default differs (casper vs live),
#                        leaving it unset lets each distro use its own default
if [ -z "$ADD" ]; then
	ISO_DEV="/dev/disk/by-uuid/$DEV_UUID"
	# iso-scan/filename must use the path relative to the block device root
	# (/$ISO_PATH), not an absolute host path — after kexec the initrd
	# scans block devices and looks for $ISO_PATH on each one.
	ADD="iso-scan/filename=/$ISO_PATH findiso=/$ISO_PATH img_dev=$ISO_DEV img_loop=$ISO_PATH iso=$DEV_UUID/$ISO_PATH live-media=$ISO_DEV"
	STATUS_OK "Fallback ISO boot params injected"
else
	STATUS_OK "Using loopback.cfg ISO boot params"
fi

paramsdir="/media/kexec_iso/$ISO_PATH"
check_config "$paramsdir"

ADD_FILE=/tmp/kexec/kexec_iso_add.txt
if [ -r "$ADD_FILE" ]; then
	NEW_ADD=$(cat "$ADD_FILE")
	ADD=$(eval "echo \"$NEW_ADD\"")
fi
STATUS "Passing boot parameters so the OS can find the ISO on the USB drive"
DEBUG "ISO kernel argument additions: $ADD"

REMOVE_FILE=/tmp/kexec/kexec_iso_remove.txt
if [ -r "$REMOVE_FILE" ]; then
	NEW_REMOVE=$(cat "$REMOVE_FILE")
	REMOVE=$(eval "echo \"$NEW_REMOVE\"")
fi
DEBUG "ISO kernel argument suppressions: $REMOVE"

DO_WITH_DEBUG kexec-select-boot.sh -b /boot -d /media -p "$paramsdir" \
	-a "$ADD" -r "$REMOVE" -c "*.cfg" -u -i

DIE "Something failed in selecting boot"
