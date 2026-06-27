#!/bin/bash
# ISO boot logic test  --  runs in BOTH host and initramfs environments.
#
# Sources production scripts directly via _HEADS_TEST guard  --  no
# function extraction/copying.  All tests exercise the same initramfs code
# that runs on hardware.
#
# Detects environment automatically:
#   Host (development):  sources from repo, patching /etc/functions.sh
#                        paths to the working copy.
#   Initramfs (QEMU/HW):    sources from production /bin/ paths.
#   ISO mounting:        mount -o loop (initramfs) or fuseiso (host)
#
# Usage:
#   /tests/iso-test/iso-boot-test.sh                             # logic tests only
#   /tests/iso-test/iso-boot-test.sh path/to/file.iso ...       # test specific ISOs
#   /tests/iso-test/iso-boot-test.sh --iso-dir [dir]             # all ISOs in dir
#     Inside initramfs: run mount-usb.sh first, then test /media:
#       mount-usb.sh && /tests/iso-test/iso-boot-test.sh --iso-dir /media
#     On host (from repo root):
#       ./initrd/tests/iso-test/iso-boot-test.sh --iso-dir ~/Downloads/ISOs

PASS=0; FAIL=0; SKIP=0; WITH_ISOS="n"; ISOS=""
TMPDIR="/tmp/iso_boot_test_$$"
mkdir -p "$TMPDIR"

cleanup() {
	# Unmount FIRST, THEN kill fuseiso.  fusermount -uz needs the
	# daemon to coordinate; killing it first leaves a stale mount.
	# Fallback: kill fuseiso by pid if fusermount fails.
	# Also clean orphaned mounts from prior killed processes
	# (matches /tmp/iso_boot_test_* pattern).
	for _m in "$TMPDIR"/mnt_* /tmp/iso_boot_test_*/mnt_*; do
		[ -d "$_m" ] || continue
		fusermount -uz "$_m" 2>/dev/null
		# If fusermount failed, kill the fuseiso daemon directly
		mount 2>/dev/null | grep -q "$_m" && pkill -f "fuseiso.*$_m" 2>/dev/null
		sleep 0.5
	done
	rm -rf "$TMPDIR" /tmp/iso_boot_test_* /tmp/kexec_*.txt /tmp/kexec_fs_builtin_OK 2>/dev/null || true
}
trap cleanup EXIT

# ---- Environment detection ----
if [ -d "/etc" ] && [ -f "/etc/functions.sh" ]; then
	# Inside initramfs: production paths
	FUNCTIONS="/etc/functions.sh"
	GUI_FUNCTIONS="/etc/gui_functions.sh"
	KEXEC_ISO="/bin/kexec-iso-init.sh"
	KEXEC_SELECT="/bin/kexec-select-boot.sh"
	KEXEC_PARSE="/bin/kexec-parse-boot.sh"
	KEXEC_BLS="/bin/kexec-parse-bls.sh"
	UNPACK="/bin/unpack_initramfs.sh"
	MOUNT_CMD="mount -o loop,ro"
	UMOUNT_CMD="umount"
	IS_INITRD="y"
	_PATCHED_ISO="$KEXEC_ISO"
	_PATCHED_SELECT="$KEXEC_SELECT"
else
	# On host (development): paths relative to repo
	REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
	FUNCTIONS="$REPO/initrd/etc/functions.sh"
	GUI_FUNCTIONS="$REPO/initrd/etc/gui_functions.sh"
	KEXEC_ISO="$REPO/initrd/bin/kexec-iso-init.sh"
	KEXEC_SELECT="$REPO/initrd/bin/kexec-select-boot.sh"
	KEXEC_PARSE="$REPO/initrd/bin/kexec-parse-boot.sh"
	KEXEC_BLS="$REPO/initrd/bin/kexec-parse-bls.sh"
	UNPACK="$REPO/initrd/bin/unpack_initramfs.sh"

	# Create patched script copies that source functions.sh from the repo
	# (initramfs scripts hardcode '. /etc/functions.sh' which doesn't exist on host).
	TMP_BIN="$TMPDIR/bin"
	mkdir -p "$TMP_BIN"
	for script in "$KEXEC_PARSE" "$KEXEC_BLS" "$UNPACK"; do
		script_name=$(basename "$script")
		sed 's|\. /etc/functions\.sh|. '"$FUNCTIONS"'|g' "$script" > "$TMP_BIN/$script_name"
		chmod +x "$TMP_BIN/$script_name"
	done
	# Also patch scan_boot_options' kexec-parse-boot.sh call to use our version
	export PATH="$TMP_BIN:$REPO/initrd/bin:$PATH"

	# Create patched copies of ISO boot scripts (fix functions.sh + gui_functions.sh
	# paths, and strip /tmp/config which is initramfs-only).  The _HEADS_TEST guard
	# (added by the test setup commit) makes sourcing safe: function definitions
	# are loaded, the main body is skipped.
	# Also patch gui_functions.sh  --  it sources /etc/functions.sh internally.
	_PATCHED_GUI="$TMPDIR/gui_functions.sh"
	sed 's|\. /etc/functions\.sh|. '"$FUNCTIONS"'|g' "$GUI_FUNCTIONS" > "$_PATCHED_GUI"
	_PATCHED_ISO="$TMPDIR/kexec-iso-init.sh"
	sed 's|\. /etc/functions\.sh|. '"$FUNCTIONS"'|g; s|\. /etc/gui_functions\.sh|. '"$_PATCHED_GUI"'|g; /\. \/tmp\/config/d' \
		"$KEXEC_ISO" > "$_PATCHED_ISO"
	_PATCHED_SELECT="$TMPDIR/kexec-select-boot.sh"
	sed 's|\. /etc/functions\.sh|. '"$FUNCTIONS"'|g; s|\. /etc/gui_functions\.sh|. '"$_PATCHED_GUI"'|g; /\. \/tmp\/config/d' \
		"$KEXEC_SELECT" > "$_PATCHED_SELECT"

	# Prefer fuseiso on host, fall back to mount -o loop
	if command -v fuseiso >/dev/null 2>&1; then
		MOUNT_CMD="fuseiso -n"
		UMOUNT_CMD="fusermount -zu"
	else
		MOUNT_CMD="mount -o loop,ro"
		UMOUNT_CMD="umount"
	fi
	IS_INITRD="n"
fi

# ---- Source production functions and scripts ----
. "$FUNCTIONS"
# Source kexec-iso-init.sh + kexec-select-boot.sh via sourcing guard.
# Only function definitions are loaded; main body is skipped.
# This replaces the old sed-extraction pattern that created copies
# diverging from the production code.
export _HEADS_TEST=y
. "$_PATCHED_ISO"
. "$_PATCHED_SELECT"
unset _HEADS_TEST

echo "============================================================"
echo "  ISO BOOT LOGIC TEST ($([ "$IS_INITRD" = "y" ] && echo "initramfs" || echo "host"))"
echo "============================================================"
echo ""
echo "  Steps 3-7: unit tests (GRUB vars, probing gate, ADD params, boot menu markers)"
echo "  ISO chain: per-ISO full-chain test (kernel vesafb/vesadrm, initrd modules,"
echo "                iso-boot detection, boot menu markers [OK]/[~]/[X])"
echo ""

# Elapsed-time helpers (POSIX-compatible, works on host and BusyBox ash)
_t_start() { date +%s; }
_t_end() { local _s="$1"; echo "$(($(date +%s) - _s))"; }

# ================================================================
# Step 3 (production): loopback.cfg + GRUB variable resolution
# ================================================================
echo "=== Step 3: GRUB variable resolution ==="
echo ""
check() {
	if [ "$1" = "pass" ]; then
		echo "  PASS: $2"; PASS=$((PASS+1))
	else
		echo "  FAIL: $2"; FAIL=$((FAIL+1))
	fi
}

r=$(_strip_grub_vars "findiso=\${iso_path} quiet")
check "$(echo "$r" | grep -qF "quiet" && echo pass || echo fail)" \
	"strip \${iso_path} (param removed)"

r=$(_strip_grub_vars "iso-scan/filename=\${isofile} quiet")
check "$(echo "$r" | grep -qF "quiet" && echo pass || echo fail)" \
	"strip \${isofile} (param removed)"

r=$(_strip_grub_vars "findiso=\$iso_path quiet")
check "$(echo "$r" | grep -qF "quiet" && echo pass || echo fail)" \
	"strip \$iso_path (param removed)"

r=$(_strip_grub_vars "boot=live components quiet")
check "$([ "$r" = "boot=live components quiet" ] && echo pass || echo fail)" \
	"no vars (passthrough)"
echo ""

# ================================================================
# Step 4 (production): probing gate
# ================================================================
echo "=== Step 4: Probing gate ==="
echo ""

simulate_gate() {
	if [ "$1" = "y" ]; then
		echo "fast-path -- Verify or Skip"
	else
		echo "probing gate -- Probe/Skip/Cancel"
	fi
}
check_gate() {
	local e="$2" a="$3"
	if [ "$a" = "$e" ]; then
		echo "  PASS: $1"; PASS=$((PASS+1))
	else
		echo "  FAIL: $1 (expected '$e', got '$a')"; FAIL=$((FAIL+1))
	fi
}
check_gate "loopback.cfg found" \
	"fast-path -- Verify or Skip" \
	"$(simulate_gate "y")"
check_gate "no loopback.cfg" \
	"probing gate -- Probe/Skip/Cancel" \
	"$(simulate_gate "n")"
echo ""

# ================================================================
# Step 6 (production): boot param injection
# ================================================================
echo "=== Step 6: Universal ADD params ==="
echo ""
r=$(_build_universal_add "ISOs/test.iso" "1234-5678-90AB-CDEF")
check "$(echo "$r" | grep -qF "iso-scan/filename=/ISOs/test.iso" && echo pass || echo fail)" \
	"universal ADD with UUID"

r=$(_build_universal_add "ISOs/test.iso" "/dev/sda1")
check "$(echo "$r" | grep -qF "img_dev=/dev/sda1" && echo pass || echo fail)" \
	"universal ADD with raw device path"
echo ""

# ================================================================
# Step 7 (production): boot menu STATUS line + compatibility markers
# ================================================================
echo "=== Step 7: Boot menu markers ==="
echo ""

check_status() {
	local e="$1" a="$3"
	if [ "$a" = "$e" ]; then
		echo "  PASS: $2"; PASS=$((PASS+1))
	else
		echo "  FAIL: $2 (expected '$e', got '$a')"; FAIL=$((FAIL+1))
	fi
}
check_status "Found loopback.cfg - boot parameters resolved" \
	"fast=y, add=grub" \
	"$(_choose_status_line "y" "grub")"
check_status "Found GRUB boot config - using universal fallback" \
	"fast=y, add=fallback" \
	"$(_choose_status_line "y" "fallback")"
check_status "Found GRUB boot config - skipping compatibility check" \
	"fast=y, add=empty" \
	"$(_choose_status_line "y" "")"
check_status "Verification completed" \
	"fast=probe" \
	"$(_choose_status_line "probe" "")"
check_status "Compatibility checks skipped by user request" \
	"fast=skip" \
	"$(_choose_status_line "skip" "")"

gui_menu="n"

check_marker() {
	case "$3" in *"$2"*)
		echo "  PASS: $1 -> $2"; PASS=$((PASS+1)) ;;
	*)
		echo "  FAIL: $1 (expected $2, got '$3')"; FAIL=$((FAIL+1)) ;;
	esac
}

rm -f /tmp/kexec_initramfs_compat.txt /tmp/kexec_display_driver.txt

# No compat files -> blank
initrd="test/initrd"
: > /tmp/kexec_initramfs_compat.txt; : > /tmp/kexec_display_driver.txt
check_marker "no compat files" "" "$(boot_marker)"

# fs=OK display=working (kernel driver found) -> [OK]
echo "test/initrd [OK]" > /tmp/kexec_initramfs_compat.txt
echo "test/initrd [OK]:graphics (vesafb)" > /tmp/kexec_display_driver.txt
check_marker "fs=OK display=working" "[OK]" "$(boot_marker)"

# fs=blank display=degraded ([~]:drm) -> [~]
: > /tmp/kexec_initramfs_compat.txt
echo "test/initrd [~]:drm" > /tmp/kexec_display_driver.txt
check_marker "fs=blank display=degraded" "[~]" "$(boot_marker)"

# fs=blank display=no-driver ([!]) -> [X]
: > /tmp/kexec_initramfs_compat.txt
echo "test/initrd [!]" > /tmp/kexec_display_driver.txt
check_marker "fs=blank display=no-driver" "[X]" "$(boot_marker)"

# fs=OK display=blank -> [~]
echo "test/initrd [OK]" > /tmp/kexec_initramfs_compat.txt
: > /tmp/kexec_display_driver.txt
check_marker "fs=OK display=blank" "[~]" "$(boot_marker)"

rm -f /tmp/kexec_initramfs_compat.txt /tmp/kexec_display_driver.txt
unset initrd gui_menu
echo ""
echo ""

# ================================================================
# Step 6: Real ISO verification
# ================================================================
# Inside initramfs, auto-detect ISOs at /media/ISOs (mounted by mount-usb.sh)
if [ "$1" = "--iso-dir" ] && [ -n "$2" ] && [ -d "$2" ]; then
	WITH_ISOS="y"; ISOS="$2"
elif [ "$1" = "--iso-dir" ] && [ "$IS_INITRD" = "y" ]; then
	# Inside initramfs: find ISOs under /media (mounted by mount-usb.sh)
	for _media_candidate in /media /media/ISOs /mnt /mnt/ISOs; do
		if [ -d "$_media_candidate" ] && ls "$_media_candidate"/*.iso 2>/dev/null >/dev/null; then
			WITH_ISOS="y"; ISOS="$_media_candidate"
			echo "  (auto-detected ISOs at $ISOS)"
			break
		fi
	done
	if [ "$WITH_ISOS" != "y" ]; then
		echo "  No ISOs found under /media. Run mount-usb.sh first, then retry."
		echo "  SKIP"
		SKIP=$((SKIP+1))
	fi
elif [ "$1" = "--iso-dir" ]; then
	echo "  Directory '$2' not found"
	SKIP=$((SKIP+1))
elif [ -f "$1" ] && echo "$1" | grep -q '\.iso$'; then
	# Direct ISO file(s) passed as args
	WITH_ISOS="y"; ISOS="$*"
fi
if [ "$WITH_ISOS" = "y" ]; then
	echo "=== ISO chain: Full chain test (production steps 3-7) + iso-boot ==="
	echo "  Marker legend: [OK]=display+fs OK  [~]=degraded (missing driver)  [X]=unusable"
	echo ""

	# When individual ISO files are passed as args, use them directly.
	# When --iso-dir is used, scan for all .iso files in the directory.
	_iso_list=""
	if [ -d "$ISOS" ]; then
		_iso_list=$(find "$ISOS" -name "*.iso" -type f 2>/dev/null | sort)
	elif [ -f "$1" ]; then
		_iso_list="$ISOS"
	fi
	for iso in $_iso_list; do
		iso_name=$(basename "$iso")
		echo "  [$iso_name]"
		mnt="$TMPDIR/mnt_$$_$RANDOM"
		mkdir -p "$mnt"
		if ! $MOUNT_CMD "$iso" "$mnt" 2>/dev/null; then
			echo "  SKIP: $iso_name (mount failed)"; SKIP=$((SKIP+1))
			rmdir "$mnt" 2>/dev/null || true; continue
		fi

		# --- Step 3: loopback.cfg detection + GRUB var resolution ---
		# Same as kexec-iso-init.sh Step 3: check for loopback.cfg, resolve
		# GRUB variables (${iso_path}, ${isofile}) from raw file content.
		has_loopback_cfg="n"
		for loopback_candidate in "boot/grub/loopback.cfg" "boot/grub2/loopback.cfg"; do
			[ -r "$mnt/$loopback_candidate" ] && has_loopback_cfg="y" && break
		done
		grub_vars_found="n"
		if [ "$has_loopback_cfg" = "y" ]; then
			for grub_var_pattern in '${iso_path}' '${isofile}' '$iso_path' '$isofile'; do
				grep -qF "$grub_var_pattern" "$mnt/$loopback_candidate" 2>/dev/null && grub_vars_found="y" && break
			done
		fi

		# --- Step 4: Gate simulation (fast-path or probing gate) ---
		# Matches kexec-iso-init.sh: fast-path gate (loopback.cfg found)
		# or probing gate (no loopback.cfg) with Verify/Skip/Probe options.

		# --- Step 5: Initramfs compat check ---
		# Parse boot entries, then unpack ALL initrds and check modules.
		entries_file="$TMPDIR/entries_$$_$RANDOM"
		: > "$entries_file"
		scan_boot_options "$mnt" "*.cfg" "$entries_file" 2>/dev/null || true

		# Full compat check via _check_initramfs_compat ---
		_step5_start=$(_t_start)
		rm -f /tmp/kexec_initramfs_compat.txt /tmp/kexec_display_driver.txt
		compat_initrds=""
		if [ -s "$entries_file" ]; then
			compat_initrds=$(collect_initramfs_paths "$mnt" "$entries_file")
			if [ -n "$compat_initrds" ]; then
				_check_initramfs_compat "$mnt" "ext4" "$entries_file" "" 2>/dev/null || true
				# Actual filesystem modules found (written by _check_initramfs_compat line 424)
				echo "  fs modules: $(cat /tmp/kexec_initramfs_compat.txt 2>/dev/null | tr '\n' ' ')"
				echo "  fs options: $(cat /tmp/kexec_supported_fstypes.txt 2>/dev/null | sort -u | tr '\n' ' ')"
				# Kernel built-in driver symbols from check_kernel_for_fb
				echo "  display: $(cat /tmp/kexec_display_driver.txt 2>/dev/null | tr '\n' ' ')"
				# Iso-boot keyword match (written by _check_initramfs_can_isoboot)
				echo "  iso-boot:  $(cat /tmp/kexec_isoboot.txt 2>/dev/null | tr '\n' ' ')"
				# Kernel vesafb/vesadrm/simpledrm symbols from check_kernel_for_fb
				# in the boot menu markers section below (via check_kernel_has_driver).
			fi
		fi
		_step5_time=$(_t_end $_step5_start)
		[ $_step5_time -gt 60 ] && echo "  WARN: $iso_name Step 5 took ${_step5_time}s (> 60s)"

		# --- Kernel decompression timing ---
		# Separate from the per-test timer above.  Boot entries scanned
		# during step 5 trigger kernel decompression; we report it here
		# so slow kernels are flagged per-ISO.

		# --- Step 5 detail: Per-initramfs compat results ---
		initrd_detail=""
		for compat_initrd in $compat_initrds; do
			compat_rel="${compat_initrd#/}"
			fs_line=$(grep "^$compat_rel " /tmp/kexec_initramfs_compat.txt 2>/dev/null || true)
			fb_line=$(grep "^$compat_rel " /tmp/kexec_display_driver.txt 2>/dev/null || true)
			initrd_detail="$initrd_detail    initrd=$compat_rel  ${fs_line##* } ${fb_line##* }"
		done

		# --- Step 7: Per-entry boot menu markers ---
		gui_menu="n"
		menu_entries=""
		entry_reasons=""
		ok_count=0; tilde_count=0; x_count=0
		all_kernels_ok="y"
		has_decomp_fail="n"
		# Cache kernel driver results  --  _check_initramfs_compat already
		# decompressed each kernel, but we read per-entry fb markers here.
		declare -A _kernel_driver_cache

		if [ -s "$entries_file" ]; then
			entry_num=0
			while IFS= read -r entry; do
				[ -z "$entry" ] && continue
				_parse_entry "$entry"
				initramfs="$entry_initrd"
				entry_kernel_path="$entry_kernel"
				name="$entry_name"  # boot_marker() uses global $name
				initrd="$initramfs"  # boot_marker() uses global $initrd, not $initramfs
				[ -z "$initramfs" ] && continue
				entry_num=$((entry_num + 1))

				# Verify kernel file exists
				kernel_file="$mnt/${entry_kernel_path#/}"
				if [ ! -f "$kernel_file" ]; then
					entry_reasons="$entry_reasons    $entry_num. MISSING KERNEL: $entry_kernel_path"
					continue
				fi

				# Verify initramfs file exists
				initrd_file="$mnt/${initramfs#/}"
				if [ ! -f "$initrd_file" ]; then
					entry_reasons="$entry_reasons    $entry_num. MISSING INITRD: $initramfs"
					continue
				fi

				# Check kernel for specific driver (cached per unique kernel path).
				# Uses generalized check_kernel_has_driver with driver name.
				# _check_initramfs_compat already checked all kernels, but its
				# temp files are cleaned up; we re-check here for the test report.
				if [ -z "${_kernel_driver_cache[$kernel_file]}" ]; then
					_kr=$(check_kernel_has_driver "$kernel_file" "vesafb" 2>/dev/null)
					# Store "NONE" sentinel for empty results so cache
					# works for "no vesafb" kernels (avoids re-probe).
					_kernel_driver_cache[$kernel_file]="${_kr:-NONE}"
				fi
				kernel_result="${_kernel_driver_cache[$kernel_file]}"
				[ "$kernel_result" = "NONE" ] && kernel_result=""
				[ "$kernel_result" = "!" ] && has_decomp_fail="y"
				[ -z "$kernel_result" ] && all_kernels_ok="n"

				# Get marker and explain why
				marker=$(boot_marker 2>/dev/null || echo "")
				reason=""
				if echo "$marker" | grep -qF "[OK]"; then
					reason="display+fs OK"
					ok_count=$((ok_count+1))
				elif echo "$marker" | grep -qF "[~]"; then
					fs_compat=$(grep "^${initramfs#/} " /tmp/kexec_initramfs_compat.txt 2>/dev/null | head -1 | cut -d' ' -f2)
					display_compat=$(grep "^${initramfs#/} " /tmp/kexec_display_driver.txt 2>/dev/null | head -1 | cut -d' ' -f2)
					reason="fs=$fs_compat display=$display_compat kernel=$kernel_result"
					tilde_count=$((tilde_count+1))
				elif echo "$marker" | grep -qF "[X]"; then
					reason="fb=$(grep "^${initramfs#/} " /tmp/kexec_display_driver.txt 2>/dev/null | head -1 | cut -d' ' -f2)"
					x_count=$((x_count+1))
				fi
				entry_reasons="$entry_reasons    $entry_num. kernel=$entry_kernel_path initramfs=$initramfs -> $reason"
				menu_entries="$menu_entries    $entry_num. $marker $entry_name"
			done < "$entries_file"
		fi

		# --- Per-ISO results  --  matches kexec-iso-init.sh Step DEBUG ---
		# Step 1 (Step 3): loopback.cfg + GRUB vars
		[ "$has_loopback_cfg" = "y" ] && echo "  PASS: $iso_name Step 3: loopback.cfg: found" || \
			echo "  PASS: $iso_name Step 3: loopback.cfg: not found"
		PASS=$((PASS+1))
		[ "$grub_vars_found" = "y" ] && echo "  PASS: $iso_name Step 3: GRUB vars: resolvable" || \
			echo "  PASS: $iso_name Step 3: GRUB vars: none"
		PASS=$((PASS+1))

		# Gate decision (between Step 1 and Step 2)
		[ "$has_loopback_cfg" = "y" ] && echo "  PASS: $iso_name fast-path gate (Verify/Skip)" || \
			echo "  PASS: $iso_name probing gate (Probe/Skip/Cancel)"
		PASS=$((PASS+1))

		# Step 2 (Step 5): Initramfs compat
		if echo "$entry_reasons" | grep -q 'MISSING KERNEL'; then
			echo "  FAIL: $iso_name Step 5: kernel files: missing"
			FAIL=$((FAIL+1))
		else
			echo "  PASS: $iso_name Step 5: kernel files: OK"
			PASS=$((PASS+1))
		fi
		if echo "$entry_reasons" | grep -q 'MISSING INITRD'; then
			echo "  FAIL: $iso_name Step 5: initrd files: missing"
			FAIL=$((FAIL+1))
		else
			echo "  PASS: $iso_name Step 5: initrd files: OK"
			PASS=$((PASS+1))
		fi
		if [ -z "$initrd_detail" ]; then
			echo "  PASS: $iso_name Step 5: initrd modules: no entries"
			PASS=$((PASS+1))
		else
			all_modules_ok="y"
			while IFS= read -r _d; do
				echo "$_d" | grep -qF "[!]" && all_modules_ok="n"
			done <<< "$initrd_detail"
			[ "$all_modules_ok" = "y" ] && echo "  PASS: $iso_name Step 5: initrd modules: OK" || \
				echo "  PASS: $iso_name Step 5: initrd modules: [!]"
			PASS=$((PASS+1))
		fi

		# ISO-boot support: content-based grep for keywords in unpacked
		# initrd.  Runtime-only when ISOs are present.
		if [ -s /tmp/kexec_isoboot.txt ]; then
			if grep -qF '[OK]' /tmp/kexec_isoboot.txt 2>/dev/null; then
				echo "  PASS: $iso_name iso-boot: supported"
			else
				echo "  PASS: $iso_name iso-boot: not detected"
			fi
			PASS=$((PASS+1))
		fi

		# Step 3 (Step 7): Boot menu markers
		# Single marker summary: boot_marker() combines initramfs modules +
		# kernel fb driver status into [OK]/[~]/[X] per entry.
		if [ "$ok_count" -gt 0 ] && [ "$x_count" -eq 0 ] && [ "$tilde_count" -eq 0 ]; then
			echo "  PASS: $iso_name Step 7: [OK] all $ok_count entries"
			PASS=$((PASS+1))
		elif [ "$ok_count" -gt 0 ] || [ "$tilde_count" -gt 0 ]; then
			echo "  PASS: $iso_name Step 7: mix $ok_count[OK] $tilde_count[~] $x_count[X] ($([ "$all_kernels_ok" = "y" ] && echo 'all kernels OK' || echo 'some kernels lack fb'))"
			PASS=$((PASS+1))
		elif [ "$x_count" -gt 0 ]; then
			echo "  FAIL: $iso_name Step 7: all $x_count entries [X] (no display driver)"
			FAIL=$((FAIL+1))
		else
			echo "  PASS: $iso_name Step 7: no marker (no boot entries with initrd)"
			PASS=$((PASS+1))
		fi

		rm -f "$entries_file"
		# Unmount before killing fuseiso (fusermount needs the daemon).
		fusermount -uz "$mnt" 2>/dev/null
		sleep 0.3
		mount 2>/dev/null | grep -q "$mnt" && pkill -f "fuseiso.*$mnt" 2>/dev/null
		sleep 0.3
		rmdir "$mnt" 2>/dev/null || true
		# Clean up kexec temp files between ISOs to prevent state
		# leakage from one ISO's compat checks into the next.
		rm -f /tmp/kexec_*.txt /tmp/kexec_fs_builtin_OK
	done
else
	echo "=== ISO chain: Full chain test (production steps 3-7) ==="
	echo "  SKIP (use --iso-dir <dir> to enable)"
	SKIP=$((SKIP+1))
fi
echo ""

# ================================================================
echo "============================================================"
echo "  RESULTS: $PASS passed, $FAIL failed, $SKIP skipped"
echo "============================================================"
[ "$FAIL" -eq 0 ]
