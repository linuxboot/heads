#!/bin/bash
# Generic configurable boot script via kexec
set -e -o pipefail
. /tmp/config
. /etc/functions.sh
. /etc/gui_functions.sh

TRACE_FUNC

add=""
remove=""
config="*.cfg"
unique="n"
valid_hash="n"
valid_global_hash="n"
valid_rollback="n"
force_menu="n"
gui_menu="n"
force_boot="n"
skip_confirm="n"
# Source guard: when _HEADS_TEST=y, skip argument processing and main body.
# The getopts loop below runs during sourcing even with empty args;
# check the guard first to avoid interfering with the caller's positional
# parameters (e.g. the test harness passes --iso-dir to the test script).
if [ -z "$_HEADS_TEST" ]; then
while getopts "b:d:p:a:r:c:uimgfs" arg; do
	case $arg in
	b) bootdir="$OPTARG" ;;
	d) paramsdev="$OPTARG" ;;
	p) paramsdir="$OPTARG" ;;
	a) add="$OPTARG" ;;
	r) remove="$OPTARG" ;;
	c) config="$OPTARG" ;;
	u) unique="y" ;;
	m) force_menu="y" ;;
	i)
		valid_hash="y"
		valid_rollback="y"
		;;
	g) gui_menu="y" ;;
	f)
		force_boot="y"
		valid_hash="y"
		valid_rollback="y"
		;;
	s) skip_confirm="y" ;;
	esac
done
fi

# Source guard: when _HEADS_TEST=y, skip argument processing and main body.
# Only function definitions are loaded. Must be here (before arg validation)
# because the getopts loop above runs during sourcing even with empty args.
if [ -z "$_HEADS_TEST" ]; then
	if [ -z "$bootdir" ]; then
		DIE "Usage: $0 -b /boot"
	fi

	if [ -z "$paramsdev" ]; then
		paramsdev="$bootdir"
	fi

	if [ -z "$paramsdir" ]; then
		paramsdir="$bootdir"
	fi

	bootdir="${bootdir%%/}"
	paramsdev="${paramsdev%%/}"
	paramsdir="${paramsdir%%/}"
fi

PRIMHASH_FILE="$paramsdir/kexec_primhdl_hash.txt"
if [ "$CONFIG_TPM2_TOOLS" = "y" ]; then
	if [ -s "$PRIMHASH_FILE" ]; then
		sha256sum -c "$PRIMHASH_FILE" >/dev/null 2>&1 ||
			{
				WARN "Hash of TPM2 primary key handle mismatch - if you have not intentionally regenerated the TPM2 primary key, your system may have been compromised"
				DEBUG "Hash of TPM2 primary key handle mismatched for $PRIMHASH_FILE"
				DEBUG "Contents of $PRIMHASH_FILE:"
				DEBUG "$(cat $PRIMHASH_FILE)"
				DIE "Hash of TPM2 primary key handle mismatch ($PRIMHASH_FILE). If you did not intentionally regenerate the TPM2 primary key, this may indicate compromise."
			}
	else
		WARN "Hash of TPM2 primary key handle does not exist - rebuild it by setting a default OS to boot: Options -> Boot Options -> Show OS Boot Menu -> pick OS -> Make default"
		default_failed="y"
		DEBUG "Hash of TPM2 primary key handle does not exist under $PRIMHASH_FILE"
	fi
fi

verify_rollback_counter() {
	TRACE_FUNC
	TPM_COUNTER=$(grep counter $TMP_ROLLBACK_FILE | cut -d- -f2)

	if [ -z "$TPM_COUNTER" ]; then
		DIE "$TMP_ROLLBACK_FILE: TPM counter not found. Please reset TPM through the Heads menu: Options -> TPM/TOTP/HOTP Options -> Reset the TPM"
	fi

	read_tpm_counter $TPM_COUNTER >/dev/null 2>&1 ||
		DIE "Failed to read TPM counter. Please reset TPM through the Heads menu: Options -> TPM/TOTP/HOTP Options -> Reset the TPM"

	sha256sum -c $TMP_ROLLBACK_FILE >/dev/null 2>&1 ||
		DIE "Invalid TPM counter state. Please reset TPM through the Heads menu: Options -> TPM/TOTP/HOTP Options -> Reset the TPM"

	valid_rollback="y"
}

# Build the compat marker legend shown once per session.
# Aligned with boot_marker() three-state scheme:
#   [OK] = ready (USB+display confirmed, continuous display or DRM reinit)
#   [~]  = degraded (any caveat: DRM-only brief blank, USB fs missing, or GPU mismatch)
#   [X]  = no display (no display driver, system runs but screen stays blank)
#   (none) = not checked (compat skipped or no loadable modules to verify)
build_legend() {
	local has_caution="n"
	if [ -r "/tmp/kexec_initramfs_compat.txt" ] && grep -qF '[!]' /tmp/kexec_initramfs_compat.txt 2>/dev/null; then
		has_caution="y"
	elif [ -r "/tmp/kexec_display_driver.txt" ] && grep -qF '[!]' /tmp/kexec_display_driver.txt 2>/dev/null; then
		has_caution="y"
	elif [ -r "/tmp/kexec_display_driver.txt" ] && grep -qF '[~]' /tmp/kexec_display_driver.txt 2>/dev/null; then
		has_caution="y"
	fi
	if [ "$has_caution" = "y" ]; then
		printf '\033[0;32m[OK]\033[0m=ready  \033[1;33m[~]\033[0m=degraded  \033[0;31m[X]\033[0m=no display  (none)=not checked'
	else
		printf '\033[0;32m[OK]\033[0m=ready  (none)=not checked'
	fi
}

first_menu="y"
get_menu_option() {
	num_options=$(cat $TMP_MENU_FILE | wc -l)
	if [ $num_options -eq 0 ]; then
		DIE "No boot options"
	fi

	if [ $num_options -eq 1 -a $first_menu = "y" ]; then
		option_index=1
	fi
	if [ ! -f /tmp/kexec_compat_shown ]; then
		if [ -f /tmp/kexec_initramfs_compat.txt ]; then
			STATUS "$(build_legend)"
		else
			STATUS "Compatibility not checked -- entries may still work"
		fi
		touch /tmp/kexec_compat_shown
	fi
	if [ "$gui_menu" = "y" ]; then
		MENU_OPTIONS=()
		n=0
		# Show kernel/initrd in menu as "[OK] name (params) [kernel | initrd]"
		# Log to debug.log so remote troubleshooting can see exact menu format.
		# Long store paths (NixOS) collapse to basename; short paths keep directory context
		while read option; do
			parse_option
			n=$((n + 1))
			local marker target display_params optline
			marker=$(boot_marker)
			target=$(fmt_boot_target)
			display_params=$(fmt_display_params "$params")
			if [ -n "$display_params" ]; then
				optline="$name ($display_params) $target"
			else
				optline="$name $target"
			fi
			if [ -n "$marker" ]; then
				MENU_OPTIONS+=("$n" "$marker $optline")
			else
				MENU_OPTIONS+=("$n" "$optline")
			fi
			DEBUG "Step 7: menu entry [$n] $marker $optline"
		done <$TMP_MENU_FILE
		if [ -n "$add" ]; then
			MENU_OPTIONS+=("b" "Select different ISO")
		fi

		if [ -n "$add" ]; then
			local menu_prompt="Choose the boot option [1-$n, a to abort, b to select different ISO]:"
		else
			local menu_prompt="Choose the boot option [1-$n, a to abort]:"
		fi
		whiptail_type $BG_COLOR_MAIN_MENU --title "Select your boot option" \
			--menu "$menu_prompt" 0 80 8 \
			-- "${MENU_OPTIONS[@]}" \
			2>/tmp/whiptail || option_index="a"

		option_index=$(cat /tmp/whiptail)
	else
		STATUS "Select your boot option:"
		n=0
		while read option; do
			parse_option
			n=$((n + 1))
			# Write directly to HEADS_TTY (bypasses stdout buffering).
			# DO_WITH_DEBUG pipes stdout through tee for debug logging,
			# making it fully buffered — the last option would appear
			# after the INPUT prompt if written to stdout.
			local marker target display_params optline
			marker=$(boot_marker)
			target=$(fmt_boot_target)
			display_params=$(fmt_display_params "$params")
			if [ -n "$marker" ]; then
				optline="$n. $marker $name ${display_params:+($display_params)} $target"
			else
				optline="$n. $name ${display_params:+($display_params)} $target"
			fi
			printf '%s\n' "$optline" >"${HEADS_TTY:-/dev/stderr}"
			DEBUG "Step 7: CLI menu: $optline"
		done <$TMP_MENU_FILE

		if [ -n "$add" ]; then
			INPUT "Choose the boot option [1-$n, a to abort, b for different ISO]:" -r option_index
		else
			INPUT "Choose the boot option [1-$n, a to abort]:" -r option_index
		fi
	fi

	if [ "$option_index" = "a" ]; then
		STATUS "Boot aborted by user"
		exit 1
	fi
	if [ "$option_index" = "b" ] && [ -n "$add" ]; then
		STATUS "Returning to ISO selection"
		exit 2
	fi
	first_menu="n"

	option=$(head -n $option_index $TMP_MENU_FILE | tail -1)
	parse_option
}

confirm_menu_option() {
	# Show full kernel/initrd/params in the confirmation dialog.
	# Cancel/Esc returns to the menu (option_confirm="b") instead of aborting,
	# so users can change their selection without restarting the boot flow.
	# The full cmdline combines the entry's parsed params with the global ADD
	# params (injected by kexec-iso-init.sh for ISO boot).
		if [ "$gui_menu" = "y" ]; then
			default_text="Make default"
			[[ "$CONFIG_TPM_NO_LUKS_DISK_UNLOCK" = "y" ]] && default_text="${default_text} and boot"
			# Build final cmdline preview using shared function so it
			# exactly matches what kexec-boot.sh will execute.
			local folded_cmdline
			folded_cmdline=$(_build_final_cmdline "$params" "$add" "$CONFIG_BOOT_KERNEL_REMOVE" "$CONFIG_BOOT_KERNEL_ADD")
			folded_cmdline=$(echo "$folded_cmdline" | fold -s -w 78)
			whiptail_warning --title "Confirm boot details" \
				--menu "$name\n\nKernel: $kernel\nInitramfs: ${initrd:--}\nOriginal kernel cmdline: ${params:--}\n${CONFIG_BOOT_KERNEL_ADD:+Board adds: $CONFIG_BOOT_KERNEL_ADD\n}${CONFIG_BOOT_KERNEL_REMOVE:+Board removes: $CONFIG_BOOT_KERNEL_REMOVE\n}${add:+ISO params: $add\n}\nFinal kernel cmdline:\n$folded_cmdline\n" 0 80 8 \
				-- 'y' "Boot" 'd' "${default_text}" 'b' "Back to menu" \
				2>/tmp/whiptail && option_confirm=$(cat /tmp/whiptail) || option_confirm="b"
	else
		STATUS "  Confirm boot details for $name:"
		STATUS "    Kernel: $kernel"
		STATUS "    Initramfs: ${initrd:--}"
		STATUS "    Original kernel cmdline: ${params:--}"
		[ -n "$CONFIG_BOOT_KERNEL_ADD" ] && STATUS "    Board adds: $CONFIG_BOOT_KERNEL_ADD"
		[ -n "$CONFIG_BOOT_KERNEL_REMOVE" ] && STATUS "    Board removes: $CONFIG_BOOT_KERNEL_REMOVE"
		[ -n "$add" ] && STATUS "    ISO params: $add"
		# Build final cmdline using shared function (matches kexec-boot.sh)
		local _final_cmdline
		_final_cmdline=$(_build_final_cmdline "$params" "$add" "$CONFIG_BOOT_KERNEL_REMOVE" "$CONFIG_BOOT_KERNEL_ADD")
		STATUS "    Final kernel cmdline: $_final_cmdline"
		INPUT "Boot (Y), make default (d), back to menu (b) [Y/d/b]:" -n 1 option_confirm
		[ -z "$option_confirm" ] && option_confirm="y"
		return 0
	fi
}

parse_option() {
	# Parse pipe-delimited boot entry into shell variables.
	# Entry format: entry_name|kexectype|field3|field4|field5
	#
	# Most entries:  name|linux|vmlinuz-path params|initrd initrd-path|append ...
	# Xen entries:   name|xen|xen.gz params|module vmlinuz-path kernel-params|module initrd-path
	#
	# For display purposes, "kernel" is always the Linux kernel path
	# (for Xen entries, extracted from field4, not the hypervisor in field3).
	name=$(echo $option | cut -d\| -f1)
	kexectype=$(echo $option | cut -d\| -f2)
	field4=$(echo $option | cut -d\| -f4)

	if [ "$kexectype" = "xen" ]; then
		# Xen multiboot: hypervisor at field3 (ignored), kernel at field4.
		# Extract the vmlinuz path, stripping "module " prefix and kernel params.
		kernel=$(echo "$field4" | sed 's/^module //' | cut -d' ' -f1 | sed 's|^/*||')
	else
		kernel=$(echo $option | cut -d\| -f3 | sed 's/^kernel //')
	fi

	initrd=""; params=""
	case "$field4" in
		initrd*) initrd="${field4#initrd }"; params=$(echo $option | cut -d\| -f5 | sed 's/append //' | xargs) ;;
		append*) params=$(echo "$field4" | sed 's/^append //' | xargs) ;;
		module*)
			if [ "$kexectype" = "xen" ]; then
				# field5 is the initramfs module path (no params).
				initrd=$(echo $option | cut -d\| -f5 | sed 's/^module //')
				initrd="${initrd%% *}"
				# Kernel params are after the vmlinuz path in field4.
				params=$(echo "$field4" | sed 's/^module //' | cut -d' ' -f2- | xargs)
			else
				# Non-Xen multiboot: field4 is the initramfs path.
				initrd="${field4#module }"
				initrd="${initrd%% *}"
			fi
			;;
		*) ;;
	esac
	LOG "parse_option: name='$name' kernel='$kernel' initrd='$initrd' params='${params:0:80}...'"
}

# Return a marker showing how well this boot entry is expected to work.
# Combines two checks from step 5 (initramfs compat):
#   - USB filesystem module support (/tmp/kexec_initramfs_compat.txt)
#   - Display driver support     (/tmp/kexec_display_driver.txt)
#
# Display failure dominates: if Heads confirms modules exist but none
# is a display driver, the entry is marked [X] regardless of filesystem
# status.  A blank screen means the user loses visibility entirely;
# filesystem issues are less severe because Heads can still try
# alternative modules.
#
# Three-state marker (user-facing, ANSI colored in CLI mode):
#   [OK] (green)  --  ready
#     Both filesystem and display drivers confirmed present (fbdev
#     OR DRM/KMS).  Display comes back after kexec, either continuously
#     (fbdev) or after DRM reinit (brief blank, near-invisible on
#     modern hardware).  Either way the entry is safe to boot.
#
#   [~]  (yellow)  --  degraded
#     Any single caveat: (a) Display could not be verified (initramfs
#     has no loadable modules  --  all drivers may be built into the
#     kernel), (b) filesystem module is missing for this USB fstype,
#     or (c) DRM driver found but not the specific one the board needs.
#     The entry will likely boot but with uncertainty or a brief blank.
#
#   [X]  (red)  --  no display
#     Initramfs has loadable modules but none of them is a DRM/KMS or
#     fbdev display driver.  After kexec the screen stays blank until
#     the target OS loads its own graphics driver from rootfs.
#     Still usable over serial console or TPM auto-unlock.
#
#   (none)  --  not checked
#     Neither filesystem nor display modules exist in this initramfs.
#     All drivers are built into the kernel  --  Heads can't verify
#     but the entry will likely work.
#
# CLI mode colors:  green [OK], yellow [~], red [X].
boot_marker() {
	local fs_status="" display_status="" display_outcome="" combined_outcome=""
	local color_green="" color_yellow="" color_red="" color_reset=""
	[ "$gui_menu" != "y" ] && {
		color_green=$'\033[0;32m'
		color_yellow=$'\033[1;33m'
		color_red=$'\033[0;31m'
		color_reset=$'\033[0m'
	}
	[ -z "$initrd" ] && { DEBUG "boot_marker: no initrd for '$name'"; return; }
	[ ! -r "/tmp/kexec_initramfs_compat.txt" ] && { DEBUG "boot_marker: no compat file for '$name'"; return; }

	local initramfs_path
	initramfs_path=$(echo "$initrd" | sed 's|^/*||')

	# Read filesystem compatibility status (written by step 5).
	# initramfs_path is from GRUB/ISO parsing, same source as the
	# file content  --  no user input, BRE metacharacters like `.`
	# in the path match the exact same `.` written to the file.
	fs_status=$(grep "^$initramfs_path " /tmp/kexec_initramfs_compat.txt 2>/dev/null | head -1 | cut -d' ' -f2)

	# Read display driver status (written by step 5), if available
	if [ -r "/tmp/kexec_display_driver.txt" ]; then
		display_status=$(grep "^$initramfs_path " /tmp/kexec_display_driver.txt 2>/dev/null | head -1 | cut -d' ' -f2-)
	fi

	LOG "boot_marker: name='$name' initrd=$initramfs_path fs=$fs_status display=$display_status"

	# -------- Display outcome (priority axis) --------
	# DEBUG messages include initramfs_path so test output shows which entry
	# generated each marker  --  required for diagnosing per-entry results.
	# Display failure is most severe: user loses visibility entirely.
	# Filesystem issues are secondary.
	# 
	# Confirmed display ([OK]:* or [OK]) = display will come back after
	# kexec, either continuously (fbdev) or after DRM/KMS reinit (brief
	# blank).  Both are fine  --  the fbdev-vs-DRM distinction is internal
	# only, not a user-facing degradation.
	# 
	# 
	# "!" / "[X]" = modules present but no compatible driver -> unusable.
	# ""  = no modules at all -> unknown (drivers may be built into kernel).
	# "[OK]" / "[OK]:*" = confirmed display + fs -> working.
	# "[~]:drm" or similar "[~]:*" = DRM found, brief blank -> degraded.
	# Any other value = treated as unusable (unknown marker type).
	case "$display_status" in
		"")
			display_outcome="unknown"
			DEBUG "boot_marker: '$name' initrd=$initramfs_path display=unknown"
			;;
		"[OK]"|'[OK]:'*)
			display_outcome="working"
			DEBUG "boot_marker: '$name' initrd=$initramfs_path display=working [OK]"
			;;
		'[~]'|'[~]:'*)
			display_outcome="degraded"
			DEBUG "boot_marker: '$name' initrd=$initramfs_path display=degraded -> [~]"
			;;
		*)
			display_outcome="unusable"
			DEBUG "boot_marker: '$name' initrd=$initramfs_path display=unusable -> [X]"
			;;
	esac

	# -------- Combine display + filesystem into final marker --------
	# Priority: display failure > display uncertainty > filesystem issues
	case "$display_outcome" in
		"unusable")
			combined_outcome="[X]"
			;;
		"unknown")
			# No display information for this initrd  --  either no modules
			# at all (can't verify) or the compat file lacks an entry.
			# Display is handled by the kernel's built-in driver (detected
			# via kernel symbol probing), not initramfs modules.
			case "$fs_status" in
				"")	combined_outcome="" ;;  # no info at all -> blank
				*)	combined_outcome="[~]" ;; # fs known but display unknown -> caution
			esac
			;;
		"working")
			case "$fs_status" in
				"[OK]"|"")
					combined_outcome="[OK]"  # display confirmed + fs OK -> safe
					;;
				*)	combined_outcome="[~]"  # display works but fs missing -> degraded
					;;
			esac
			;;
		"degraded")
			combined_outcome="[~]"  # DRM-only: brief blank after kexec -> caution
			;;
	esac
	DEBUG "boot_marker: '$name' initrd=$initramfs_path display=$display_outcome fs=$fs_status -> $combined_outcome"

	# Apply ANSI colors for CLI mode
	case "$combined_outcome" in
		"[OK]")	combined_outcome="${color_green}[OK]${color_reset}" ;;
		"[~]")	combined_outcome="${color_yellow}[~]${color_reset}" ;;
		"[X]")	combined_outcome="${color_red}[X]${color_reset}" ;;
	esac

	echo "$combined_outcome"
}

# Strip ISO-finding boot parameters for display only.
# The full params remain in the entry passed to kexec-boot.sh.
# These params are injected by kexec-iso-init.sh via -a and would
# clutter the menu if shown redundantly.  Only affects menu display.
fmt_display_params() {
	local display_params="$1"
	[ -z "$display_params" ] && echo "" && return
	echo "$display_params" | sed \
		-e 's|iso-scan/filename=[^ ]*| |g' \
		-e 's|findiso=[^ ]*| |g' \
		-e 's|fromiso=[^ ]*| |g' \
		-e 's|img_dev=[^ ]*| |g' \
		-e 's|img_loop=[^ ]*| |g' \
		-e 's|iso=[^ ]*| |g' \
		-e 's|live-media=[^ ]*| |g' \
		-e 's|  *| |g' \
		-e 's|^ ||' \
		-e 's| $||' | xargs
}

# Format kernel/initrd for menu display: "[path | path]"
# Keeps directory context for short paths (live/vmlinuz) but falls back to
# basename for unreasonably long store paths (NixOS /nix/store/.../bzImage).
# 35-char threshold: typical paths like "boot/x86_64/loader/linux" fit;
# NixOS store paths with hashes exceed it.
fmt_boot_target() {
	local k i
	k=$(echo "$kernel" | sed 's|^/*||')
	[ -z "$k" ] && k="$kernel"
	[ "${#k}" -gt 35 ] && k=$(basename "$k")
	i=$(echo "$initrd" | sed 's|^/*||')
	[ "${#i}" -gt 35 ] && i=$(basename "$i")
	if [ -n "$i" ]; then echo "[$k | $i]"; else echo "[$k]"; fi
}

scan_options() {
	DEBUG "Step 7: scanning boot options"
	STATUS "Scanning boot options"
	option_file="/tmp/kexec_options.txt"
	scan_boot_options "$bootdir" "$config" "$option_file"
	if [ ! -s $option_file ]; then
		DIE "Failed to parse any boot options"
	fi
		# Sort entries by name so users can scan the menu alphabetically.
		# When -u (unique) is set, strip --- markers from append params first
		# so entries differing only by GRUB's bootloader separator get deduped.
		mkdir -p "$(dirname "$TMP_MENU_FILE")" 2>/dev/null || true
		if [ "$unique" = 'y' ]; then
			sed 's/|append \([^|]*\)---[^|]*/|append \1/g' "$option_file" | awk -F'|' '!seen[$1]++' >"$TMP_MENU_FILE"
		else
			cp "$option_file" "$TMP_MENU_FILE"
		fi
		DEBUG "Step 7: wrote menu to $TMP_MENU_FILE ($(wc -l < "$TMP_MENU_FILE" 2>/dev/null || echo 0) entries)"
		STATUS_OK "Boot options scanned"
		DEBUG "Step 7: parsed boot options for user selection"
		# Option entries are already logged as echo_entry by kexec-parse-boot.sh;
		# no need to dump them again here.
}

save_default_option() {
	if [ "$gui_menu" != "y" ]; then
		INPUT "Saving a default will modify the disk. Proceed? (Y/n):" -n 1 default_confirm
	fi

	[ "$default_confirm" = "" ] && default_confirm="y"
	if [[ "$default_confirm" = "y" || "$default_confirm" = "Y" ]]; then
		if kexec-save-default.sh \
			-b "$bootdir" \
			-d "$paramsdev" \
			-p "$paramsdir" \
			-i "$option_index" \
			; then
			STATUS_OK "Saved defaults to device"

			default_failed="n"
			force_menu="n"
			return
		else
			WARN "Failed to save defaults"
		fi
	fi

	option_confirm="n"
}

default_select() {
	# Attempt boot with expected parameters

	# Check that entry matches that which is expected from menu
	default_index=$(basename "$TMP_DEFAULT_FILE" | cut -d. -f 2)

	# Check to see if entries have changed - useful for detecting grub update
	expectedoption=$(cat $TMP_DEFAULT_FILE)
	option=$(head -n $default_index $TMP_MENU_FILE | tail -1)
	if [ "$option" != "$expectedoption" ]; then
		if [ "$gui_menu" = "y" ]; then
			whiptail_error --title 'ERROR: Boot Entry Has Changed' \
				--msgbox "The list of boot entries has changed\n\nPlease set a new default" 0 80
		fi
		WARN "Boot entry has changed - please set a new default"
		return
	fi
	parse_option

	if [ "$CONFIG_BASIC" != "y" ]; then
		# Enforce that default option hashes are valid
		STATUS "Checking verified default boot hash file"
		# Check the hashes of all the files
		if (cd $bootdir && sha256sum -c "$TMP_DEFAULT_HASH_FILE" >/tmp/hash_output); then
			STATUS_OK "Verified default boot hashes"
			valid_hash='y'
		else
			if [ "$gui_menu" = "y" ]; then
				CHANGED_FILES=$(grep -v 'OK$' /tmp/hash_output | cut -f1 -d ':')
				whiptail_error --title 'ERROR: Default Boot Hash Mismatch' \
					--msgbox "The following files failed the verification process:\n${CHANGED_FILES}\nExiting to a recovery shell" 0 80
			fi
		fi
	fi

	STATUS "Executing default boot for $name"
	do_boot
	WARN "Failed to boot default option"
}

user_select() {
	# No default expected boot parameters, ask user

	option_confirm=""
	while [ "$option_confirm" != "y" -a "$option_confirm" != "d" ]; do
		get_menu_option
		# In force boot mode, no need offer the option to set a default, just boot
		if [[ "$force_boot" = "y" || "$skip_confirm" = "y" ]]; then
			do_boot
		else
			confirm_menu_option
		fi

		if [ "$option_confirm" = 'd' ]; then
			save_default_option
		fi
	done

	if [ "$option_confirm" = "d" ]; then
		if [ ! -r "$TMP_KEY_DEVICES" ]; then
			# continue below to boot the new default option
			true
		else
			NOTE "Rebooting to start the new default option"
			reboot.sh
		fi
	fi

	do_boot
}

do_boot() {
	if [ "$CONFIG_BASIC" != y ] && [ "$CONFIG_BOOT_REQ_ROLLBACK" = "y" ] && [ "$valid_rollback" = "n" ]; then
		DIE "Missing required rollback counter state"
	fi

	if [ "$CONFIG_BASIC" != y ] && [ "$CONFIG_BOOT_REQ_HASH" = "y" ] && [ "$valid_hash" = "n" ]; then
		DIE "Missing required boot hashes"
	fi

	if [ "$CONFIG_BASIC" != y ] && [ "$CONFIG_TPM" = "y" ] && [ -r "$TMP_KEY_DEVICES" ] && [ "$force_boot" != "y" ]; then
		INITRD=$(kexec-boot.sh -b "$bootdir" -e "$option" -i) ||
			DIE "Failed to extract the initrd from boot option"
		if [ -z "$INITRD" ]; then
			DIE "No initrd file found in boot option"
		fi

		kexec-insert-key.sh $INITRD ||
			DIE "Failed to prepare TPM Disk Unlock Key for boot"

		kexec-boot.sh -b "$bootdir" -e "$option" \
			-a "$add" -r "$remove" -o "/tmp/secret/initrd.cpio" ||
			DIE "Failed to boot w/ options: $option"
	else
		kexec-boot.sh -b "$bootdir" -e "$option" -a "$add" -r "$remove" ||
			DIE "Failed to boot w/ options: $option"
	fi
}

# Source guard: when _HEADS_TEST=y, only load function definitions, skip main body
[ -n "$_HEADS_TEST" ] && return 0 2>/dev/null || true

while true; do
	DEBUG "Step 7: top of boot menu loop"
	if [ "$force_boot" = "y" -o "$CONFIG_BASIC" = "y" ]; then
		DO_WITH_DEBUG check_config $paramsdir force
	else
		DO_WITH_DEBUG check_config $paramsdir
	fi
	TMP_DEFAULT_FILE=$(find /tmp/kexec/kexec_default.*.txt 2>/dev/null | head -1) || true
	TMP_MENU_FILE="/tmp/kexec/kexec_menu.txt"
	TMP_HASH_FILE="/tmp/kexec/kexec_hashes.txt"
	TMP_TREE_FILE="/tmp/kexec/kexec_tree.txt"
	TMP_DEFAULT_HASH_FILE="/tmp/kexec/kexec_default_hashes.txt"
	TMP_ROLLBACK_FILE="/tmp/kexec/kexec_rollback.txt"
	TMP_KEY_DEVICES="/tmp/kexec/kexec_key_devices.txt"
	TMP_KEY_LVM="/tmp/kexec/kexec_key_lvm.txt"

	# Allow a way for users to ignore warnings and boot into their systems
	# even if hashes don't match
	if [ "$force_boot" = "y" ]; then
		scan_options
		if [ "$CONFIG_BASIC" != "y" ]; then
			# Remove boot splash and make background red in the event of a forced boot
			add="$add vt.default_red=0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff"
			remove="$remove splash quiet"
		fi
		user_select
	fi

	if [ "$CONFIG_TPM" = "y" ]; then
		if [ ! -r "$TMP_KEY_DEVICES" ]; then
			# Extend PCR4 as soon as possible
			TRACE_FUNC
			INFO "TPM: Extending PCR[4] with content of string 'generic' to prevent secret unsealing"
			tpmr.sh extend -ix 4 -ic generic ||
				DIE "Failed to extend TPM PCR[4]"
		fi
	fi

	if [ "$CONFIG_BASIC" != "y" ]; then
		# Optionally enforce device file hashes
		if [ -r "$TMP_HASH_FILE" ]; then
			valid_global_hash="n"

			# verify_global_hashes() is defined in gui_functions.sh (not in
			# this script).  The function returns 0 on success (hashes match,
			# or user chose to update), and 1 on failure (user returned to
			# menu, or whiptail failed).  Use && to set valid_global_hash
			# only when the function succeeds.
			verify_global_hashes && valid_global_hash="y"

			if [ "$valid_global_hash" = "n" ]; then
				DIE "Failed to verify global hashes"
			fi
		fi

		if [ "$CONFIG_IGNORE_ROLLBACK" != "y" -a -r "$TMP_ROLLBACK_FILE" ]; then
			# in the case of iso boot with a rollback file, do not assume valid
			valid_rollback="n"

			verify_rollback_counter
		fi
	fi

	# if no saved options, scan the boot directory and generate.
	# Must run AFTER verify_global_hashes because check_config (called
	# inside verify_global_hashes) does rm -rf /tmp/kexec/* which
	# would delete the menu file if it were created before the check.
	if [ ! -r "$TMP_MENU_FILE" ]; then
		scan_options
	fi

	if [ "$default_failed" != "y" \
		-a "$force_menu" = "n" \
		-a -r "$TMP_DEFAULT_FILE" \
		-a -r "$TMP_DEFAULT_HASH_FILE" ] \
		; then
		default_select
		default_failed="y"
	else
		user_select
	fi
done

DIE "Shouldn't get here"
