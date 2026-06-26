#!/bin/bash
# Boot from signed ISO
#
# Design overview
# ---------------
# This script implements ISO boot for Heads.  Execution order:
#
#   1. Signature verification  --  Check for .sig / .asc on the ISO file.
#      Unsigned ISOs prompt the user before proceeding.
#
#   2. Mount ISO  --  Loopback-mount the ISO at /boot.
#
#   3. loopback.cfg  --  Read boot/grub/loopback.cfg (cheap ~2 KB).
#      If found, offers a fast-path gate: 'Verify USB modules' (runs step 5)
#      or 'Boot ISO now' (skips step 5).  If resolvable GRUB variables
#      (\${iso_path}) are stripped and universal params provide the ISO path.
#      Only when no loopback.cfg exists does step 4 (probing gate) fire.
#
#   4. Probing gate  --  When no loopback.cfg found, offer three choices:
#      Probe (run step 5), Skip checks (no step 5), Cancel.
#
#   5. Initramfs compat  --  Unpack initramfs, check for USB filesystem
#      modules and isoboot keywords.  Display driver detection runs against
#      the decompressed kernel (built-in drivers bind before initramfs).
#      Writes per-initrd markers for the boot menu.  Runs when user chose
#      'Probe' (probing gate) or 'Deep scan' (fast-path gate).
#
#   6. Boot param injection  --  When step 3 found no GRUB vars, inject
#      universal fallback ADD params covering all common initramfs
#      frameworks (iso-scan/filename=, findiso=, img_dev=, img_loop=,
#      iso=, live-media=).
#
#   7. kexec-select-boot  --  Interactive boot menu with [OK]/[~]/[X]
#      compatibility markers (when step 5 ran) or no markers.
#
# Based on u-root's boot/iso approach:
#   https://github.com/u-root/u-root/pull/3578
#
# Fallback ADD params (used when step 3 finds no GRUB variables):
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
set -e
set -o pipefail 2>/dev/null || true
. /etc/functions.sh
. /etc/gui_functions.sh
. /tmp/config

TRACE_FUNC

# Cleanup handler: unmount ISO and remove temp files on any exit path.
# Appends to existing at_exit handlers rather than replacing them.
_iso_cleanup() {
	local rc=$?
	TRACE_FUNC
	DEBUG "Cleanup: exit code $rc"
	umount /boot 2>/dev/null && DEBUG "Cleanup: unmounting /boot" || true
	rm -f /tmp/kexec_initramfs_compat.txt /tmp/kexec_display_driver.txt \
		/tmp/kexec_isoboot.txt /tmp/kexec_usb_fstype \
		/tmp/kexec_supported_fstypes.txt \
		/tmp/kexec_initrd_kernel_map.txt /tmp/kexec_display_kernels.txt \
		/tmp/kexec_options.txt /tmp/iso_initrd_entries.* \
		/tmp/whiptail /tmp/vmlinux.*
	DEBUG "Cleanup: done"
	return $rc
}
# Prepend our cleanup to any existing EXIT trap without replacing it.
_iso_cleanup_old_trap=$(trap -p EXIT 2>/dev/null | sed "s/.*'//;s/'.*//;s/^trap -- //;s/ EXIT\$//") || true
if [ -n "$_iso_cleanup_old_trap" ]; then
	trap "{ _iso_cleanup; $_iso_cleanup_old_trap; }" EXIT
else
	trap _iso_cleanup EXIT
fi

# Extract filesystem type (TYPE="...") from blkid output.
# blkid emits space-separated KEY="value" pairs; this pipeline
# splits on spaces and extracts the TYPE value.
_get_blkid_fstype() {
	blkid "$1" 2>/dev/null | tr ' ' '\n' | sed -n 's/^TYPE="\(.*\)"$/\1/p'
}

# Source guard: when _HEADS_TEST=y, only load function definitions, skip main body
# Guard placed at end-of-functions marker below; here we wrap the Step 1-2
# body that sits ahead of the function definitions.
if [ -z "$_HEADS_TEST" ]; then

MOUNTED_ISO_PATH="$1"
ISO_PATH="$2"
DEV="$3"

STATUS "Verifying ISO signature"
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
		STATUS_OK "Signature verified"
		# Skip unsigned warning  --  jump past the unsigned block
		skip_unsigned_warning="y"
	fi
fi

if [ "$skip_unsigned_warning" != "y" ]; then
	# No valid signature  --  prompt user with warning
	WARN "No signature found for ISO"
	if [ -x /bin/whiptail ]; then
		if ! whiptail_warning --title 'UNSIGNED ISO WARNING' --yesno \
			"WARNING: UNSIGNED ISO DETECTED\n\nThe selected ISO file:\n$(basename "$MOUNTED_ISO_PATH")\n\nDoes not have a detached signature. Integrity and authenticity cannot be verified.\n\nCancel to Recovery Shell for instructions on signing this ISO with your GPG key, or boot unsigned now.\n\nBoot unsigned?" \
			0 80; then
			WARN "ISO not signed.  Recovery Shell: use GPG to sign the ISO, then retry."
			recovery
		fi
	else
		WARN "The selected ISO file does not have a detached signature"
		WARN "Integrity and authenticity of the ISO cannot be verified"
		WARN "Only Recovery Shell grants access to GPG sign the ISO"
		INPUT "Proceed anyway? (y/N = cancel):" -n 1 response
		if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
			WARN "From recovery shell: gpg --detach-sign /media/iso-path.iso"
			recovery
		fi
	fi
fi

if [ "$skip_unsigned_warning" != "y" ]; then
	NOTE "Proceeding with unsigned ISO boot"
fi

STATUS "Mounting ISO"
mount -t iso9660 -o loop "$MOUNTED_ISO_PATH" /boot \
	|| DIE '$MOUNTED_ISO_PATH: Unable to mount /boot'
STATUS_OK "ISO mounted at /boot"

DEV_UUID=$(blkid "$DEV" | tail -1 | tr " " "\n" | grep UUID | cut -d\" -f2)
[ -z "$DEV_UUID" ] && DEV_UUID="$DEV" && DEBUG "Step 2: no UUID for $DEV, using raw device path $DEV_UUID"

# Detect USB filesystem type for the fast-path gate warning.
# The ISO's initramfs must have the kernel module for the USB filesystem
# (e.g. exfat.ko for exfat).  Use the same detection chain as
# check_initramfs_compat: blkid -> partition scan -> /proc/mounts.
# At this point, media-scan.sh has already mounted the USB, so
# /proc/mounts is the most reliable source (works for whole-disk
# filesystems, partitioned disks, and loopback mounts alike).
USB_FSTYPE=$(_get_blkid_fstype "$DEV")
if [ -z "$USB_FSTYPE" ]; then
	_usb_base="${DEV#/dev/}"
	for _part in /dev/${_usb_base}*; do
		[ "$_part" = "$DEV" ] && continue
		[ -b "$_part" ] || continue
		USB_FSTYPE=$(_get_blkid_fstype "$_part")
		[ -n "$USB_FSTYPE" ] && break
	done
fi
# Last resort: already mounted by media-scan.sh at /media
if [ -z "$USB_FSTYPE" ]; then
	USB_FSTYPE=$(awk -v dev="$DEV" 'index($1, dev) == 1 { print $3; exit }' /proc/mounts 2>/dev/null)
fi
[ -z "$USB_FSTYPE" ] && USB_FSTYPE="unknown"

# ---------------------------------------------------------------------------
# Step 5 helper functions (defined at top level, called from probe path)
# ---------------------------------------------------------------------------
# Before proposing boot options, verify the ISO's initramfs contains a kernel
# module for the USB filesystem type that can drive the display after kexec
# without DRM/KMS reinit.  If the initrd can't read the partition where the
# ISO lives, or can't drive the display, the boot will fail or be blind after
# kexec.
#
# We find initrd paths by parsing the ISO's boot configs -- the same way
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
# TYPE (ext4 -> ext4.ko, btrfs -> btrfs.ko).  Only vfat/msdos differ
# (kernel module is "fat"), handled by initrd_fs_type_to_kmod().
# No hardcoded module list -- any filesystem type is supported.

fi  # end of _HEADS_TEST guard around Step 1-2

# Checks USB modules, decompresses kernels for display driver symbols,
# writes compat files for boot_marker().  The initrd-scanning and
# kernel-compat logic is in _check_initramfs_compat() so the test
# harness can call it directly instead of duplicating the code.
check_initramfs_compat() {
	TRACE_FUNC
	local bootdir="$2"
	local kernel_mod entries_file
	# Derive kernel module name from USB filesystem type for fs check
	kernel_mod=$(initrd_fs_type_to_kmod "$USB_FSTYPE" 2>/dev/null)
	[ -z "$kernel_mod" ] && kernel_mod="$USB_FSTYPE"
	# Scan boot entries to discover kernel/initrd paths
	entries_file=$(mktemp -p /tmp -t iso_initrd_entries_final.XXXXXX)
	trap 'rm -f "$entries_file"' RETURN
	scan_boot_options "$bootdir" "*.cfg" "$entries_file" 2>/dev/null || true
	_check_initramfs_compat "$bootdir" "$kernel_mod" "$entries_file"
	rm -f "$entries_file"
}

# Parse a pipe-delimited boot entry into global variables.
# Shared between production code and test harness.
# Sets: entry_name, entry_type, entry_kernel, entry_initrd, entry_append, entry_params
# Entry format: name|kexectype|kernel|field4|field5
_parse_entry() {
	local entry="$1"
	entry_name=$(echo "$entry" | cut -d'|' -f1)
	entry_type=$(echo "$entry" | cut -d'|' -f2)
	local rest
	rest=$(echo "$entry" | cut -d'|' -f3-)
	entry_kernel=""; entry_initrd=""; entry_append=""; entry_params=""
	local old_ifs="$IFS"; IFS='|'
	local entry_vmlinuz_path=""
	local entry_module_count=0
	for part in $rest; do
		case "$part" in
			kernel*) entry_kernel="${part#kernel }" ;;
			initrd*) entry_initrd="${part#initrd }" ;;
			module*)
				entry_module_count=$((entry_module_count + 1))
				[ "$entry_module_count" -eq 1 ] && {
					entry_vmlinuz_path="${part#module }"
					entry_vmlinuz_path="${entry_vmlinuz_path%% *}"
				}
				;;
			append*) entry_append="${part#append }" ;;
		esac
	done
	if [ "$entry_type" = "xen" ] && [ -n "$entry_vmlinuz_path" ]; then
		entry_kernel="$entry_vmlinuz_path"
		local first_module_value
		first_module_value=$(echo "$rest" | cut -d'|' -f2)
		entry_params="${first_module_value#module }"
		entry_params="${entry_params#* }"
		[ "$entry_params" = "${first_module_value#module }" ] && entry_params=""
		[ -z "$entry_append" ] && entry_append="$entry_params"
	fi
	if [ "$entry_type" = "xen" ]; then
		local initrd_raw
		# BusyBox lacks rev, use sed to extract last | delimited field.
		initrd_raw=$(echo "$rest" | sed 's/.*|//')
		[ -z "$entry_initrd" ] && entry_initrd="${initrd_raw#module }"
	else
		[ -z "$entry_initrd" ] && [ -z "$entry_kernel" ] && entry_kernel="$entry_vmlinuz_path"
	fi
	IFS="$old_ifs"
}

# Shared initramfs scanning + kernel compat upgrade.
# Used by check_initramfs_compat() above and by the test harness directly.
# Args: bootdir  kernel_mod  entries_file
# Writes: /tmp/kexec_initramfs_compat.txt, /tmp/kexec_display_driver.txt,
#   /tmp/kexec_isoboot.txt, /tmp/kexec_supported_fstypes.txt
_check_initramfs_compat() {
	local bootdir="$1" kernel_mod="$2" entries_file="$3"
	local initramfs_paths initramfs_relpath
	while IFS= read -r initramfs_relpath; do
		initramfs_paths="$initramfs_paths $initramfs_relpath"
	done < <(collect_initramfs_paths "$bootdir" "$entries_file")
	[ -z "$initramfs_paths" ] && DEBUG "Step 5: no initrd paths in boot entries" && return 0

	local any_supported="n"
	local fs_compat_file="/tmp/kexec_initramfs_compat.txt"
	local display_driver_file="/tmp/kexec_display_driver.txt"
	local isoboot_compat_file="/tmp/kexec_isoboot.txt"
	: > "$fs_compat_file"
	: > "$display_driver_file"
	: > "$isoboot_compat_file"
	: > /tmp/kexec_supported_fstypes.txt

	STATUS "Checking initramfs modules and kernel drivers"
	for initramfs_relpath in $initramfs_paths; do
		local initramfs_abspath="$bootdir/${initramfs_relpath#/}"
		DEBUG "Step 5: checking initrd=$initramfs_abspath"
		local unpack_dir
		unpack_dir=$(mktemp -p /tmp -d)
		DEBUG "Step 5: unpacking ${initramfs_relpath#/}"
		unpack_initramfs.sh "$initramfs_abspath" "$unpack_dir" 2>/dev/null || true
		if [ -z "$(ls -A "$unpack_dir" 2>/dev/null)" ]; then
			DEBUG "Step 5: unpack_dir empty -- initrd may be corrupt or unsupported format"
		fi
		local initramfs_supports_fs="" display_driver_status="" initramfs_isoboot=""
		
		
		initramfs_isoboot="$(_check_initramfs_can_isoboot "$unpack_dir")"
		if [ -n "$initramfs_isoboot" ]; then
			echo "${initramfs_relpath#/} [OK]" >> "$isoboot_compat_file"
		else
			echo "${initramfs_relpath#/} [!]" >> "$isoboot_compat_file"
		fi
		# Phase 2: USB filesystem module
		initramfs_supports_fs="$(check_initramfs_for_module "$unpack_dir" "$kernel_mod")" || true
		# Phase 3: Display driver — set initial degraded marker.
		# The actual driver is determined by kernel symbol detection
		# in the second pass (built-in vesafb/vesadrm/simpledrm binds
		# before initramfs).  This initial marker says "display may
		# work after DRM reinit" — the second pass upgrades to
		# [OK]:graphics (driver) when a built-in driver is found.
		display_driver_status="[~]:drm"
		case "$initramfs_supports_fs" in
			OK)	initramfs_supports_fs="[OK]"
				DEBUG "Step 5: $initramfs_relpath has module $kernel_mod" ;;
			"!")	initramfs_supports_fs="[!]"
				DEBUG "Step 5: $initramfs_relpath has modules but no $kernel_mod" ;;
			"")	DEBUG "Step 5: $initramfs_relpath no modules (cannot verify)" ;;
		esac
		if [ -n "$initramfs_supports_fs" ]; then
			echo "${initramfs_relpath#/} $initramfs_supports_fs" >> "$fs_compat_file"
			[ "$initramfs_supports_fs" = "[OK]" ] && [ "$any_supported" = "n" ] && any_supported="y"
		fi
		# Check all USB-capable filesystems Heads supports.
		# This drives the "Reformat your USB as..." suggestion in the
		# filesystem warning dialog.  Any fs the initramfs has a module for
		# is a candidate  --  the user can reformat their USB to match.
		for _chk_fs in exfat ext4 vfat; do
			_chk_kmod=$(initrd_fs_type_to_kmod "$_chk_fs" 2>/dev/null)
			[ -z "$_chk_kmod" ] && _chk_kmod="$_chk_fs"
			[ "$(check_initramfs_for_module "$unpack_dir" "$_chk_kmod" 2>/dev/null)" = "OK" ] && echo "$_chk_fs" >> /tmp/kexec_supported_fstypes.txt
		done
		if [ -n "$display_driver_status" ]; then
			echo "${initramfs_relpath#/} $display_driver_status" >> "$display_driver_file"
		fi

		rm -rf "$unpack_dir"
	done

	# Build initrd->kernel mapping from entries_file.
	# Inline parsing (no _parse_entry call  --  this code runs in the initrd
	# where every fork/exec adds measurable overhead during step 5).
	# Entry format: name|kexectype|kernel|field4|field5
	# field4: initrd <path> or module <path>
	# field5: append <params> or module <path> (Xen)
	while IFS= read -r entry; do
		[ -z "$entry" ] && continue
		entry_type=$(echo "$entry" | cut -d\| -f2)
		entry_initrd="" entry_kernel=""
		entry_field4=$(echo "$entry" | cut -d\| -f4)
		entry_field5=$(echo "$entry" | cut -d\| -f5)
		if [ "$entry_type" = "xen" ]; then
			# Xen: kernel in field4 (first module), initrd in field5
			entry_kernel="${entry_field4#module }"; entry_kernel="${entry_kernel%% *}"
			entry_initrd="${entry_field5#module }"; entry_initrd="${entry_initrd%% *}"
		else
			entry_kernel=$(echo "$entry" | cut -d\| -f3 | sed 's/^kernel //' | xargs)
			case "$entry_field4" in
				initrd*) entry_initrd="${entry_field4#initrd }" ;;
				module*) entry_initrd="${entry_field4#module }"; entry_initrd="${entry_initrd%% *}" ;;
			esac
		fi
		[ -z "$entry_initrd" ] && continue
		entry_initrd="${entry_initrd#/}"
		[ -z "$entry_kernel" ] && continue
		entry_kernel="${entry_kernel#/}"
		echo "$entry_initrd $bootdir/$entry_kernel"
	done < "$entries_file" | sort -u > "/tmp/kexec_initrd_kernel_map.txt"
	DEBUG "Step 5: kernel map: $(paste -sd, /tmp/kexec_initrd_kernel_map.txt 2>/dev/null)"

	: > "/tmp/kexec_display_kernels.txt"
	while IFS= read -r pair; do
		[ -z "$pair" ] && continue
		local kernel_path=$(echo "$pair" | cut -d' ' -f2)
		[ -z "$kernel_path" ] && continue
		# Skip if already checked (e.g., vmlinuz symlink pointing
		# to a versioned kernel also in the map).
		grep -qF "$kernel_path " "/tmp/kexec_display_kernels.txt" 2>/dev/null && continue
		# Only check kernel files that exist.  Qubes Xen entries
		# may reference symlinks that are missing on ISO boot.
		[ -f "$kernel_path" ] || { DEBUG "Step 5: kernel $kernel_path not found, skipping fb check"; continue; }
		local kernel_display_result=""
		# Guard with || true: set -e + check_kernel_for_fb can
		# exit non-zero on malformed kernels (Xen multiboot, etc.)
		kernel_display_result=$(check_kernel_for_fb "$kernel_path" || true)
		# Result format: "OK:<symbol>" (e.g. "OK:vesadrm", "OK:simpledrm_probe")
		#   = kernel has a display driver; "" = not found;
		#   "!" = decompression failed (unsupported format), skip upgrade.
		case "$kernel_display_result" in
			OK:*)
				local _driver_sym="${kernel_display_result#OK:}"
				DEBUG "Step 5: kernel $kernel_path has $_driver_sym"
				echo "$kernel_path $_driver_sym" >> "/tmp/kexec_display_kernels.txt" ;;
			"")
				DEBUG "Step 5: kernel $kernel_path no display driver support" ;;
			*)
				DEBUG "Step 5: kernel $kernel_path decompression failed ($kernel_display_result)" ;;
		esac
	done < "/tmp/kexec_initrd_kernel_map.txt"

	while IFS= read -r pair; do
		[ -z "$pair" ] && continue
		local initramfs_relpath=$(echo "$pair" | cut -d' ' -f1)
		local kernel_path=$(echo "$pair" | cut -d' ' -f2)
		local _driver_sym
		_driver_sym=$(grep "$kernel_path " "/tmp/kexec_display_kernels.txt" 2>/dev/null | head -1 | cut -d' ' -f2)
		if [ -n "$_driver_sym" ]; then
			# Upgrade marker from generic "[~]:drm" or "[!]" to
			# "[OK]:graphics (<driver>)" showing the actual driver symbol.
			# boot_marker() sees "[OK]:*" as "working" display.
			# initramfs_relpath is from GRUB/ISO parsing, same source
			# as the display_driver_file -- no user input, BRE
			# metacharacters like `.` in the path match exactly.
			sed -i "s|^$initramfs_relpath \[~]:drm|$initramfs_relpath [OK]:graphics ($_driver_sym)|" "$display_driver_file"
			sed -i "s|^$initramfs_relpath \[!]|$initramfs_relpath [OK]:graphics ($_driver_sym)|" "$display_driver_file"
		fi
	done < "/tmp/kexec_initrd_kernel_map.txt"

	# Kernel-level filesystem fallback: when NO initramfs has the USB
	# filesystem as a .ko (check_initramfs_for_module returned "!" above),
	# check if the ISO kernel has the driver compiled in.  This handles
	# distros that ship CONFIG_EXFAT_FS=y (Ubuntu 26.04, NixOS 25.11)
	# or CONFIG_EXT4_FS=y built-in (Fedora, Qubes) -- the .ko is not
	# shipped because the driver is in-kernel, not in initramfs.
	if [ "$any_supported" != "y" ] && [ -s "/tmp/kexec_usb_fstype" ]; then
		local _kernel_fs _kernel_kmod
		_kernel_fs=$(cat /tmp/kexec_usb_fstype 2>/dev/null)
		_kernel_kmod=$(initrd_fs_type_to_kmod "$_kernel_fs" 2>/dev/null)
		[ -z "$_kernel_kmod" ] && _kernel_kmod="$_kernel_fs"
		while IFS= read -r _kernel_pair; do
			[ -z "$_kernel_pair" ] && continue
			local _kernel_vmlinuz=$(echo "$_kernel_pair" | cut -d' ' -f2)
			[ -z "$_kernel_vmlinuz" ] && continue
			[ -f "$_kernel_vmlinuz" ] || continue
			[ "$(_check_kernel_for_fs_builtin "$_kernel_vmlinuz" "$_kernel_kmod")" = "OK" ] || continue
			DEBUG "Step 5: kernel $_kernel_vmlinuz has $_kernel_kmod built-in (not in initramfs)"
			any_supported="y"
			echo "$_kernel_fs" >> /tmp/kexec_supported_fstypes.txt
			sed -i 's| \[!\]| [OK]|g' "$fs_compat_file"
			break
		done < "/tmp/kexec_initrd_kernel_map.txt"
	fi

	rm -f "/tmp/kexec_initrd_kernel_map.txt" "/tmp/kexec_display_kernels.txt"

	STATUS_OK "Initramfs modules and kernel drivers verified"

	# Dump compat file contents to debug log so users can see per-initrd markers
	if [ -s "$fs_compat_file" ]; then
		while IFS= read -r line; do DEBUG "Step 5: fs compat: $line"; done < "$fs_compat_file"
	fi
	if [ -s "$display_driver_file" ]; then
		while IFS= read -r line; do DEBUG "Step 5: kernel display driver: $line"; done < "$display_driver_file"
	fi
	if [ -s "$isoboot_compat_file" ]; then
		while IFS= read -r line; do DEBUG "Step 5: isoboot compat: $line"; done < "$isoboot_compat_file"
	fi

	# At least one initrd verifiably supports the USB filesystem --
	# proceed without warning.
	[ "$any_supported" = "y" ] && return 0

	# No initrd confirmed support.  The [!] markers (or absence of
	# markers for no-module initrds) will inform the user in the menu.
	# We still proceed since unverifiable initrds may work fine.
	DEBUG "Step 5: no initrd has $kernel_mod as .ko (likely built-in kernel support)"
}

# Show a compatibility warning.  In whiptail mode, Cancel exits the script.
# In console mode, returns 0 (proceed) or 1 (caller decides abort vs exit).
# Show a compatibility warning dialog.
# Called with --info as first arg: msgbox (single OK, no proceed).
# Called without --info: yesno (Proceed/Cancel, user can continue).
# See ADR 0004 for the rationale.
_warn_compat() {
	local _wc_mode="yesno" title body response
	TRACE_FUNC
	if [ "$1" = "--info" ]; then
		_wc_mode="msgbox"
		title="$2"
		body="$3"
		shift 3
	else
		title="$1"
		body="$2"
		shift 2
	fi

	if [ -x /bin/whiptail ]; then
		if [ "$_wc_mode" = "msgbox" ]; then
			whiptail_warning --title "$title" --msgbox "$body" 0 80
			DEBUG "Info acknowledged: $title"
		else
			if ! whiptail_warning --title "$title" --yesno "$body" 0 80; then
				DEBUG "Warning cancelled: $title"
			exit 3   # unsigned ISO: recovery for signing instructions
			fi
			DEBUG "Warning accepted: $title"
		fi
	else
		for msg in "$@"; do
			WARN "$msg"
		done
		INPUT "Proceed anyway? (y/N):" -n 1 response
		if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
			DEBUG "Warning accepted: $title"
			return 0
		fi
		DEBUG "Warning refused: $title"
		return 1
	fi
}

# Run step 5: initramfs compat check + unified guidance.
# Expects $DEV and /boot to be set.  Writes compat files for boot_marker().
# All checks run unconditionally; results collected first, then shown in a
# single unified dialog so the user sees the full picture before deciding.
#   - Isoboot: advisory note when initramfs has no isoboot keywords
#   - USB filesystem: reformat guidance when module missing
#   - Display driver: kernel config guidance when fbdev/simpledrm absent
_run_step_5() {
	TRACE_FUNC
	DEBUG "Step 5: running initramfs compatibility check"
	check_initramfs_compat "$DEV" "/boot"
	DEBUG "Step 5: compat check completed"

	# Extract ISO filename for user-facing messages
	local _iso_name
	_iso_name="$(basename "${MOUNTED_ISO_PATH:-$ISO_PATH}" 2>/dev/null || echo "this ISO")"

	local _warn_body="" _warn_title=""
	local _has_fs_warn="n" _has_display_warn="n"
	local _fs_compat_file="/tmp/kexec_initramfs_compat.txt"
	local _display_driver_file="/tmp/kexec_display_driver.txt"

	# Step 5: isoboot check -- when no initramfs has isoboot keywords
	# keywords, suggest dd as alternative.  Advisory only: false
	# negatives are possible (initramfs may handle findiso via
	# compiled binary or squashfs rather than unpacked scripts).
	# When isoboot is missing, reformatting USB will not help  -- 
	# the ISO cannot loopback-mount itself from any filesystem.
	local _iso_boot_note=""
	local _iso_boot_required="n"
	local _iso_boot_f="/tmp/kexec_isoboot.txt"
	# Step 5: isoboot check -- when the ISO's initramfs has no
	# isoboot keywords (findiso, iso-scan, casper, live-media, etc.),
	# the ISO likely cannot boot from a USB file.  Examples: Debian DVD
	# installer (cdrom-detect scans for physical CDROM, not USB files),
	# openSUSE Tumbleweed DVD (kiwi linuxrc scans by LABEL, not path).
	# Show informational msgbox (no proceed path) -- the user must write
	# the ISO to a dedicated USB drive with dd/Rufus instead.
	if [ -s "$_iso_boot_f" ] && ! grep -qF '[OK]' "$_iso_boot_f"; then
		DEBUG "Step 5: isoboot keywords not found (advisory)"
		_iso_boot_note="$_iso_name: This ISO cannot boot from USB: it is an installer image (iso9660 only), not a hybrid/live ISO designed for USB boot.\n\nFlash it to a dedicated USB drive with dd, Rufus, Fedora Media Writer, or upstream recommended tooling."
		_iso_boot_required="y"
	fi

	# Step 5: filesystem check
	# Three sub-cases, all leading to the same unified dialog:
	#   1. Installer ISO (no isoboot): reformatting USB won't help;
	#      the ISO needs dd/Rufus/Fedora Media Writer to a dedicated drive.
	#   2. Supported fs exists: tell user which filesystem to reformat
	#      their existing USB drive to, OR use a dedicated drive.
	#   3. No supported fs at all: only option is dedicated USB drive.
	# The _dedicated_usb_guidance is shared across all three for consistent wording.
	if [ -s "$_fs_compat_file" ] && ! grep -qF '[OK]' "$_fs_compat_file"; then
		_has_fs_warn="y"
		DEBUG "Step 5: filesystem warning -- no initrd has the USB fs module"
		local _fstype _good_fs _fs_line
		_fstype=$(cat /tmp/kexec_usb_fstype 2>/dev/null || echo "USB")
		_good_fs=""
		for _fs in ext4 vfat exfat; do
			grep -qF "$_fs" /tmp/kexec_supported_fstypes.txt 2>/dev/null && _good_fs="$_good_fs $_fs"
		done
		# vfat (FAT32) has a 4 GiB minus 1 byte file size limit (4,294,967,295).
		# If the ISO exceeds this and vfat is the only reformat option,
		# drop vfat from the recommendation -- the file won't fit.
		if echo "$_good_fs" | grep -q 'vfat'; then
			local _iso_size
			_iso_size=$(stat -c %s "$MOUNTED_ISO_PATH" 2>/dev/null || echo 0)
			if [ "$_iso_size" -gt 4294967295 ] 2>/dev/null; then
				_good_fs=" $(echo "$_good_fs" | sed 's/vfat//')"
				_good_fs="$(echo "$_good_fs" | xargs)"
				DEBUG "Step 5: ISO exceeds 4 GiB ($_iso_size bytes), cannot recommend vfat"
			fi
		fi
		rm -f /tmp/kexec_supported_fstypes.txt
		local _dedicated_usb_guidance="Flash it to a dedicated USB drive with dd, Rufus, Fedora Media Writer, or upstream recommended tooling."
		if [ "$_iso_boot_required" = "y" ]; then
			_fs_line="$_iso_name: This is an installer image, not a live system. $_dedicated_usb_guidance"
		elif [ -n "$_good_fs" ]; then
			_fs_line="$_iso_name: Your USB is formatted as $_fstype, but this ISO cannot access $_fstype during boot.\n\nReformat your USB drive as$_good_fs and try again, or $_dedicated_usb_guidance"
		else
			_fs_line="$_iso_name: Your USB is formatted as $_fstype. No filesystem driver is available for this ISO during boot.\n\n$_dedicated_usb_guidance"
		fi
		_warn_body="$_fs_line"
	fi

	# Step 5: display check
	# This means the target kernel has no fbdev/simpledrm built-in AND
	# no DRM/KMS drivers are in any initramfs.  After kexec the display
	# stays blank until the rootfs loads native GPU drivers (10-30s).
	# User is advised to report to distro with per-kernel-version CONFIG
	# guidance.  DUK does NOT apply to live ISO boot -- user has no
	# safety net (contrast with installed-OS boot where TPM DUK can
	# decouple LUKS unlock from display, see doc/boot-process.md:414).
	if [ -s "$_display_driver_file" ] && ! grep -qF '[OK]' "$_display_driver_file" && ! grep -qF '[~]:drm' "$_display_driver_file"; then
		_has_display_warn="y"
		DEBUG "Step 5: display warning -- no kernel display driver found"
		local _display_warning="$_iso_name: This kernel has no built-in display driver.\nReport to the distribution:\n- Enable CONFIG_FB_VESA=y (vesafb, works on all kernel versions)\n- Or enable CONFIG_DRM_SIMPLEDRM=y + CONFIG_SYSFB_SIMPLEFB=y (simpledrm, 6.x+)\n\nAfter kexec the display stays blank until the native GPU driver\nloads from the live system (10-30s). TPM Disk Unlock Key (DUK)\ndoes not apply to live ISO boot.\n\nCheck [OK]/[~]/[X] markers in the boot menu to see which ISO\nentries have display support."
		if [ "$_has_fs_warn" = "y" ]; then
			_warn_body="$_warn_body\n\n$_display_warning"
		else
			_warn_body="$_display_warning"
		fi
	fi
	# Firmware utility detection: initramfs has no .ko files at all
	# (display_driver_file empty, isoboot_compat has entries).
	# Samsung SSD firmware updater is the prime example -- not a Linux
	# bootable ISO.  These ISOs cannot run under Heads because they
	# rely on vendor-specific display/framework unavailable on coreboot.
	# User needs to either:
	#   - Run the update from a standard BIOS system (not Heads)
	#   - Extract the firmware payload and flash from Linux using
	#     vendor-supported tools or community extraction scripts
	#   - Check if the upstream provides a standalone Linux flasher
	# Checking isoboot_compat (not fs_compat) because when there are
	# zero .ko files neither compat check writes entries; only the
	# isoboot scan runs unconditionally.
	if [ ! -s "$_display_driver_file" ] && [ -s "$_iso_boot_f" ] && [ "$_iso_boot_required" = "y" ] && [ "$_has_display_warn" != "y" ]; then
		_has_display_warn="y"
		local _firmware_warning="$_iso_name: This is a firmware utility, not a standard Linux bootable ISO.\n\nIt cannot boot under Heads. To apply the firmware update, use a standard BIOS system, or extract the firmware payload and flash from Linux with vendor-supported tooling."
		_warn_body="$_firmware_warning"
		_iso_boot_note=""
	fi

	# Show unified dialog with ALL collected results (isoboot, USB fs,
	# display).  Dialog fires when ANY check has a finding, so the user
	# sees the full picture before deciding to proceed or cancel.
	#
	# Dialog type (msgbox vs yesno) is determined by _iso_boot_required:
	#   y = msgbox (single OK button, no proceed path)
	#       -- ISO cannot boot from USB file at all (installer, firmware
	#          utility).  User must dd to dedicated USB drive.
	#   n = yesno (Proceed / Cancel)
	#       -- ISO may boot but has degraded filesystem or display.
	#          User takes the risk knowingly.
	if [ "$_has_fs_warn" = "y" ] || [ "$_has_display_warn" = "y" ] || [ -n "$_iso_boot_note" ]; then
		_warn_title="Boot Compatibility"
		# Append isoboot note if no filesystem warning already covers it.
		if [ -n "$_iso_boot_note" ] && [ "$_has_fs_warn" != "y" ]; then
			_warn_body="${_warn_body:+$_warn_body\n\n}$_iso_boot_note"
		fi
		# When the ISO needs dd mode, the _iso_boot_note or _fs_line above
		# already explains what to do.  No "Proceed?" prompt -- the user
		# needs a different USB drive, not to proceed with this one.
		if [ "$_iso_boot_required" = "y" ]; then
			_warn_body="$_warn_body\n\nPress ENTER to return and select another ISO."
		else
			_warn_body="$_warn_body\n\nProceed with current USB format anyway?"
		fi
		if [ "$_iso_boot_required" = "y" ]; then
			_warn_compat --info "$_warn_title" "$_warn_body"
			DEBUG "Step 5: ISO cannot boot from USB file, returning to ISO selection"
			exit 2
		else
			_warn_compat "$_warn_title" "$_warn_body" \
				"Boot compatibility issue detected" \
				|| DIE "Boot compatibility check failed - cannot proceed"
		fi
	else
		if [ ! -s "$_fs_compat_file" ]; then
			DEBUG "Step 5: no filesystem compat entries written; USB fs could not be verified"
		else
			DEBUG "Step 5: filesystem check passed"
		fi
		if [ ! -s "$_display_driver_file" ]; then
			DEBUG "Step 5: no framebuffer compat entries written; display could not be verified"
		else
			DEBUG "Step 5: display check passed"
		fi
		if [ -z "$_iso_boot_note" ]; then
			DEBUG "Step 5: isoboot check passed"
		fi
	fi
}

# Strip GRUB variable references (\${iso_path}, \${isofile}) from a kernel
# command-line string.  GRUB variables are undefined in kexec context —
# passing them literally to the kernel is a security risk.  Our universal
# fallback provides all ISO-finding parameters with correct absolute paths.
# Used by step 3 (loopback.cfg) parsing.
_strip_grub_vars() {
	local append_val="$1"
	local stripped="$append_val"
	TRACE_FUNC
	# Remove any word containing $ (unresolved GRUB variable references)
	stripped=$(echo "$stripped" | sed 's/[^ ]*\$[^ ]*//g' | xargs)
	if [ "$stripped" != "$append_val" ]; then
		DEBUG "Step 3: stripped GRUB vars: $append_val -> $stripped"
	else
		DEBUG "Step 3: no GRUB variables found in append string: $append_val"
	fi
	echo "$stripped"
}

# Build the universal fallback ADD param string with all common ISO boot
# methods.  Used when loopback.cfg has no resolvable GRUB variables.
_build_universal_add() {
	local iso_path="$1" dev_uuid="$2"
	local iso_dev iso_id result
	TRACE_FUNC
	if echo "$dev_uuid" | grep -q '^/dev/'; then
		iso_dev="$dev_uuid"
		iso_id="${dev_uuid#/dev/}"
		DEBUG "Step 6: raw device path (no UUID)"
	else
		iso_dev="/dev/disk/by-uuid/$dev_uuid"
		iso_id="$dev_uuid"
		DEBUG "Step 6: UUID path"
	fi
	# Universal ADD: covers all initramfs frameworks.
	# iso-scan/filename=  --  casper (Ubuntu, PureOS), dracut (Fedora)
	# findiso=             --  live-boot (Debian, Tails, NixOS)
	# img_dev= / img_loop= / iso=  --  generic fallbacks
	# live-media=          --  device filter (casper + live-boot)
	# NOTE: Appended after ISO's loopback.cfg params so the ISO's own
	# values take precedence for first-match parsers.  See call site.
	# Both approaches work as long as paths are absolute — the ordering
	# only matters when the ISO and Heads disagree on a param value.
	result="iso-scan/filename=/$iso_path findiso=/$iso_path img_dev=$iso_dev img_loop=/$iso_path iso=$iso_id/$iso_path live-media=$iso_dev"
	DEBUG "Step 6: $result"
	printf '%s\n' "$result"
}

# Choose the STATUS line text based on the resolved boot path.
# Args: fast_path  add_source ("grub"/"fallback"/"")
_choose_status_line() {
	TRACE_FUNC
	local fast_path="$1" add_source="$2"
	local msg
	if [ "$fast_path" = "probe" ]; then
		msg="Verification completed"
	elif [ "$fast_path" = "y" ]; then
		if [ "$add_source" = "grub" ]; then
			msg="Found loopback.cfg - boot parameters resolved"
		elif [ "$add_source" = "fallback" ]; then
			msg="Found GRUB boot config - using universal fallback"
		else
			msg="Found GRUB boot config - skipping compatibility check"
		fi
	elif [ "$fast_path" = "skip" ]; then
		msg="Compatibility checks skipped by user request"
	else
		msg="Verification completed"
	fi
	DEBUG "_choose_status_line: $msg"
	echo "$msg"
}

# Build USB filesystem compatibility message for gate dialogs.
_usb_fs_compat_msg() {
	case "$USB_FSTYPE" in
		ext4)		echo "USB filesystem ext4 is commonly supported." ;;
		exfat)		echo "USB filesystem exFAT can work, but verify compatibility is recommended." ;;
		vfat)		echo "USB filesystem FAT32 -- supported for ISOs under 4 GiB. For larger ISOs, use ext4." ;;
		ntfs|xfs|btrfs) echo "USB filesystem $USB_FSTYPE is unlikely to work. Use ext4 instead." ;;
		"")		echo "USB filesystem unknown. Verify compatibility is recommended." ;;
		*)		echo "USB filesystem $USB_FSTYPE may not be fully supported." ;;
	esac
}

# Source guard: when _HEADS_TEST=y, only load function definitions, skip main body.
# All function definitions are above; only main body code remains below.
[ -n "$_HEADS_TEST" ] && return 0 2>/dev/null || true

# Step 3: loopback.cfg fast path
# ---------------------------------------------------------------------------
# loopback.cfg is the ISO 9660 standard for declaring boot entries on a
# hybrid ISO.  We check it FIRST because it's a cheap file read (~2 KB)
# vs. unpacking the entire initramfs (200+ MB).
#
# If found with resolvable GRUB variables (${iso_path}, ${isofile}), the
# resolved params become the boot ADD params and step 5 (initramfs compat)
# is skipped entirely.  We scan the raw loopback.cfg FIRST (before calling
# kexec-parse-boot.sh) to catch GRUB variables before the parser's eval
# (line 100) expands them to empty.
#
# If no GRUB vars are found, the fast-path/probing gate below lets the
# user decide whether to run the expensive step 5 scan.
FAST_PATH="n"
ADD=""
ADD_SOURCE=""  # "grub" when from raw/parser, "fallback" when from universal params
REMOVE=""

for lb_cfg in "boot/grub/loopback.cfg" "boot/grub2/loopback.cfg"; do
	if [ -r "/boot/$lb_cfg" ]; then
		DEBUG "Step 3: found $lb_cfg"
		FAST_PATH="y"

		# Step A: Parse raw loopback.cfg for GRUB variable references.
		# We strip them — they're undefined in kexec context and would be
		# passed literally to the kernel (security risk).  Universal
		# fallback provides all ISO-finding params with absolute paths.
		_raw_vars_found="n"
		for _raw_var in '${iso_path}' '${isofile}' '$iso_path' '$isofile'; do
			if grep -qF "$_raw_var" "/boot/$lb_cfg" 2>/dev/null; then
				_raw_vars_found="y"
				break
			fi
		done
		if [ "$_raw_vars_found" = "y" ]; then
			DEBUG "Step 3: raw loopback.cfg has GRUB variable references"
			# Extract kernel params from the first linux/multiboot line.
			# Input format: "linux /path/to/vmlinuz param1 param2 ..."
			# After extraction: _grub_cmd="linux", _kernel_path="/path/to/vmlinuz",
			#   _kernel_append="param1 param2 ..."
			_raw_line=$(grep -m1 -E '^[ 	]*linux[ 	]+|^[ 	]*linux16[ 	]+|^[ 	]*linuxefi[ 	]+|^[ 	]*multiboot[ 	]+' "/boot/$lb_cfg" 2>/dev/null)
			if [ -n "$_raw_line" ]; then
				# Squash whitespace, strip leading space, use parameter expansion.
				_line="$(echo "$_raw_line" | tr -s ' 	' ' ')"
				_line="${_line# }"
				_grub_cmd="${_line%% *}"
				_after_cmd="${_line#$_grub_cmd }"
				_after_cmd="${_after_cmd# }"
				_kernel_path="${_after_cmd%% *}"
				_kernel_append="${_after_cmd#$_kernel_path }"
				_kernel_append="${_kernel_append# }"
				DEBUG "Step 3: raw loopback.cfg GRUB vars: $_kernel_append"
				if [ -n "$_kernel_append" ]; then
					resolved_raw="$(_strip_grub_vars "$_kernel_append")"
					if [ "$resolved_raw" != "$_kernel_append" ]; then
						# Strip GRUB --- separator and tail from resolved ADD
						#  --  those params (e.g. quiet splash) already exist in
						# the boot entry's original kernel cmdline.  Only the
						# iso-scan/filename= findiso= etc before --- are new.
						# Handle both " --- " and leading "---" (when the variable
						# before --- was stripped, --- becomes position 0).
						resolved_raw=$(echo "$resolved_raw" | sed 's/ --- .*$//;s/^--- //' | xargs)
						DEBUG "Step 3: raw loopback.cfg GRUB vars: $_kernel_append -> $resolved_raw"
						ADD="$resolved_raw"
						ADD_SOURCE="grub"
					fi
				fi
			fi
		fi
		if [ -z "$ADD" ]; then
			DEBUG "Step 3: raw loopback.cfg scan found no GRUB vars"
		fi

		# Step B: Parse entries for the boot menu (even if ADD already set).
		option_file="/tmp/kexec_options.txt"
		: > "$option_file"
		DO_WITH_DEBUG kexec-parse-boot.sh "/boot" "/boot/$lb_cfg" >>"$option_file"

		# Step C: Parser output is NOT usable for GRUB var resolution.
		# kexec-parse-boot.sh's eval (line 100) expands ${iso_path} and
		# $isofile to empty before we can inspect them.  The raw scan
		# (Step A) above already caught any resolvable variables directly
		# from the file content, before the parser could mangle them.
		# The parser is only needed for generating boot menu entries.
		rm -f "$option_file"

		if [ -z "$ADD" ]; then
			DEBUG "Step 3: loopback.cfg found but no GRUB vars detected"
		else
			DEBUG "Step 3: loopback.cfg GRUB vars resolved: $ADD"
		fi
		break
	fi
done
DEBUG "Step 3: FAST_PATH=$FAST_PATH ADD=${ADD:+set}"

# ---------------------------------------------------------------------------
# Fast-path gate (loopback.cfg found): offer deep scan option
# ---------------------------------------------------------------------------
# loopback.cfg is the ISO 9660 standard for USB boot support.  When found,
# we know the ISO declares USB boot capability.  However, Heads cannot
# guarantee compatibility without scanning the initramfs (filesystem
# modules, display drivers).  Offer a non-default deep scan option.
# This gate fires for ALL loopback.cfg ISOs  --  even those with resolved
# GRUB vars  --  because GRUB var resolution doesn't verify USB fs or display.
DEBUG "Step 4: fast-path gate"
if [ "$FAST_PATH" = "y" ]; then
	if [ -x /bin/whiptail ]; then
		# Build filesystem-specific warning message.
		# $USB_FSTYPE detected at step 2 via blkid $DEV.
		# ext4/vfat are universal in live ISO initramfs; exfat varies;
		# NTFS/XFS/btrfs are rarely included in initramfs.
	# Build gate message based on what loopback.cfg told us.
	# ADD_SOURCE="grub" when loopback.cfg had resolvable GRUB variables
	# (iso_path or isofile).  loopback.cfg is the primary USB boot
	# declaration; the filesystem is an assumption (unverified).
	_gate_msg="This ISO includes a USB boot configuration file (GRUB loopback.cfg)."
	# Add filesystem note as secondary (loopback.cfg takes priority)
	_fs_line=$(_usb_fs_compat_msg)
	whiptail_warning --title "USB boot readiness check" \
		--menu "$_gate_msg\n\n$_fs_line\n\nSuggested: Verify ISO compatibility first (~30-60s).\n\nChoose an option:" 0 80 2 \
			'd' 'Verify ISO compatibility (recommended)' \
			'p' 'Boot ISO now (skip verification)' \
			2>/tmp/whiptail  || _fast_choice=""
		_fast_choice=$(cat /tmp/whiptail 2>/dev/null || echo "")
		rm -f /tmp/whiptail
	else
		DEBUG "Step 4: whiptail unavailable, console prompt"
		WARN "USB boot config found. Verify compatibility (USB modules, display drivers) or boot immediately."
		INPUT "Verify compatibility? (V=verify/ENTER=boot):" -n 1 _response
		case "$_response" in
			v|V) _fast_choice="d" ;;
			*) _fast_choice="p" ;;
		esac
	fi

	# Cancel/Esc exits back to ISO selection, consistent with probing gate behavior.
	[ -z "$_fast_choice" ] && DEBUG "Step 4: user cancelled" && exit 1
	DEBUG "Fast path: user chose '$_fast_choice'"

	case "$_fast_choice" in
		d|D)
			DEBUG "Step 4: deep scan requested"
			_run_step_5
			DEBUG "Step 4: deep scan completed"
			FAST_PATH="probe"
			;;
		*)
			DEBUG "Step 4: proceeding without checks"
			;;
	esac
fi

# ---------------------------------------------------------------------------
# Probing gate: only shown when no loopback.cfg was found
# AND we haven't already run step 5 via deep scan (FAST_PATH=probe).
# ---------------------------------------------------------------------------
if [ "$FAST_PATH" != "y" ] && [ "$FAST_PATH" != "probe" ]; then
	DEBUG "Step 4: probing gate (no loopback.cfg)"
	# Build filesystem insight (shared function with fast-path gate)
	_probe_fs=$(_usb_fs_compat_msg)
	if [ -x /bin/whiptail ]; then
	whiptail_warning --title "USB boot readiness check" \
		--menu "This ISO does not include a USB boot configuration file (GRUB loopback.cfg).\nSome ISOs only work when written directly to a USB drive.\n\n$_probe_fs\n\nSuggested: Verify ISO compatibility first (~30-60s).\n\nChoose an option:" 0 80 3 \
			'd' 'Verify ISO compatibility (recommended)' \
			's' 'Boot ISO now (skip verification)' \
			'c' 'Cancel (return to ISO selection)' \
			2>/tmp/whiptail  || { DEBUG "Step 4: user cancelled"; exit 1; }
		_probe_choice=$(cat /tmp/whiptail)
		rm -f /tmp/whiptail
	else
		DEBUG "Step 4: whiptail unavailable, console prompt"
		WARN "No USB boot configuration file (GRUB loopback.cfg) found. Verify ISO compatibility (V) or boot now (S/C=cancel)."
		INPUT "Verify compatibility? (V=verify/S=boot/C=cancel):" -n 1 _response
		case "$_response" in
			v|V) _probe_choice="p" ;;
			s|S) _probe_choice="s" ;;
			*) DEBUG "Gate: user cancelled at console prompt" ; exit 1 ;;
		esac
	fi

	DEBUG "Gate: user chose '$_probe_choice'"
	case "$_probe_choice" in
		s|S)
			DEBUG "Step 4: skipping step 5"
			FAST_PATH="skip"
			;;
		c|C)
			DEBUG "Step 4: cancel"
			exit 1
			;;
		*)
			_run_step_5
			;;
	esac
fi

# Step 3 resolved nothing  --  build fallback ADD params with all common
# ISO boot methods, both relative and device-by-UUID paths, so the ISO
# initrd can find the ISO regardless of distribution.
# Each framework picks what it recognises:
#   iso-scan/filename=  --  Ubuntu casper, Fedora dracut, Kicksecure
#   findiso=            --  Debian live-boot, NixOS stage-1
#   img_dev=            --  block device (generic)
#   img_loop=           --  loopback file path (generic)
#   iso=                --  UUID/path alternative (generic)
#   live-media=         --  casper (Ubuntu, PureOS), live-boot (Debian)
#
# Always inject universal fallback params  --  loopback.cfg's linux line
# typically provides only iso-scan/filename= from ${iso_path}, but other
# initramfs frameworks (Debian live-boot findiso=, NixOS findiso=, etc.)
# need additional params.  Append to any existing ADD from GRUB vars.
_UNIVERSAL_ADD="$(_build_universal_add "$ISO_PATH" "$DEV_UUID")"
if [ -n "$ADD" ]; then
	# APPEND universal fallback params after ISO's own loopback.cfg
	# values so the ISO's own params take precedence (first-match
	# parsers use the first occurrence of a given parameter name).
	# Universal params serve as fallback for frameworks that the
	# ISO's loopback.cfg doesn't supply (e.g. findiso= for live-boot).
	ADD="$ADD $_UNIVERSAL_ADD"
	DEBUG "Step 6: boot parameters from GRUB vars + universal fallback"
else
	ADD="$_UNIVERSAL_ADD"
	DEBUG "Step 6: universal boot parameters only"
fi

# Print a status line about the resolved path before launching the boot menu.
# Uses _choose_status_line() to mirror the exact logic in the test helpers.
STATUS_LINE="$(_choose_status_line "$FAST_PATH" "$ADD_SOURCE")"
[ -n "$STATUS_LINE" ] && STATUS "$STATUS_LINE"

paramsdir="/media/kexec_iso/$ISO_PATH"
check_config "$paramsdir"

ADD_FILE=/tmp/kexec/kexec_iso_add.txt
if [ -r "$ADD_FILE" ]; then
	NEW_ADD=$(cat "$ADD_FILE")
	ADD=$(eval "echo \"$NEW_ADD\"")
	DEBUG "Step 6: user config overrides ADD: $ADD"
fi
STATUS "Setting boot parameters"
DEBUG "Step 6: ISO kernel argument additions: $ADD"

REMOVE_FILE=/tmp/kexec/kexec_iso_remove.txt
if [ -r "$REMOVE_FILE" ]; then
	NEW_REMOVE=$(cat "$REMOVE_FILE")
	REMOVE=$(eval "echo \"$NEW_REMOVE\"")
fi
DEBUG "Step 6: ISO kernel argument suppressions: $REMOVE"
STATUS_OK "Boot parameters set"

DEBUG "Step 7: launching boot menu (FAST_PATH=$FAST_PATH)"
DO_WITH_DEBUG kexec-select-boot.sh -b /boot -d /media -p "$paramsdir" \
	-a "$ADD" -r "$REMOVE" -c "*.cfg" -u -i

DIE "Something failed in selecting boot"
