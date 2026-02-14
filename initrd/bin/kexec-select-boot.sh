#!/bin/bash
# Generic configurable boot script via kexec
set -e -o pipefail
 # shellcheck disable=SC1091
 . /tmp/config
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh
# shellcheck source=initrd/etc/gui_functions.sh
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
		*) die "Invalid option: $arg" ;;
	esac
done

if [ -z "$bootdir" ]; then
	die "Usage: $0 -b /boot"
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

PRIMHASH_FILE="$paramsdir/kexec_primhdl_hash.txt"
if [ "$CONFIG_TPM2_TOOLS" = "y" ]; then
	if [ -s "$PRIMHASH_FILE" ]; then
		#PRIMHASH_FILE (normally /boot/kexec_primhdl_hash.txt) exists and is not empty
		sha256sum -c "$PRIMHASH_FILE" >/dev/null 2>&1 ||
			{
				echo "FATAL: Hash of TPM2 primary key handle mismatch!"
				warn "If you have not intentionally regenerated TPM2 primary key,"
				warn "your system may have been compromised"
				DEBUG "Hash of TPM2 primary key handle mismatched for $PRIMHASH_FILE"
				DEBUG "Contents of $PRIMHASH_FILE:"
				DEBUG "$(cat "$PRIMHASH_FILE")"
			}
	else
		warn "Hash of TPM2 primary key handle does not exist"
		warn "Please rebuild the TPM2 primary key handle hash by setting a default OS to boot."
		warn "Select Options-> Boot Options -> Show OS Boot Menu -> <Pick OS> -> Make default"
		#TODO: Simplify/Automatize TPM2 firmware upgrade process. Today: upgrade, reboot, reseal(type TPM Owner Password), resign, boot
		default_failed="y"
		DEBUG "Hash of TPM2 primary key handle does not exist under $PRIMHASH_FILE"
	fi
fi

verify_global_hashes() {
	TRACE_FUNC
	INFO "+++ Checking verified boot hash file "
	# Check the hashes of all the files
	if verify_checksums "$bootdir" "$gui_menu"; then
		INFO "+++ Verified boot hashes "
		valid_hash='y'
		valid_global_hash='y'
	else
		if [ "$gui_menu" = "y" ]; then
			CHANGED_FILES=$(grep -v 'OK$' /tmp/hash_output | cut -f1 -d ':')
			whiptail_error --title 'ERROR: Boot Hash Mismatch' \
				--msgbox "The following files failed the verification process:\n${CHANGED_FILES}\nExiting to a recovery shell" 0 80
		fi
		die "$TMP_HASH_FILE: boot hash mismatch"
	fi
	# If user enables it, check root hashes before boot as well
	if [[ "$CONFIG_ROOT_CHECK_AT_BOOT" = "y" && "$force_menu" == "n" ]]; then
		if root-hashes-gui.sh -c; then
			echo "+++ Verified root hashes, continuing boot "
			# if user re-signs, it wipes out saved options, so scan the boot directory and generate
			if [ ! -r "$TMP_MENU_FILE" ]; then
				scan_options
			fi
		else
			# root-hashes-gui.sh handles the GUI error menu, just die here
			if [ "$gui_menu" = "y" ]; then
				whiptail_error --title 'ERROR: Root Hash Mismatch' \
					--msgbox "The root hash check failed!\nExiting to a recovery shell" 0 80
			fi
			die "root hash mismatch, see /tmp/hash_output_mismatches for details"
		fi
	fi
}

verify_rollback_counter() {
	TRACE_FUNC
	TPM_COUNTER=$(grep counter $TMP_ROLLBACK_FILE | cut -d- -f2)

	if [ -z "$TPM_COUNTER" ]; then
		die "$TMP_ROLLBACK_FILE: TPM counter not found. Please reset TPM through the Heads menu: Options -> TPM/TOTP/HOTP Options -> Reset the TPM"
	fi

	read_tpm_counter "$TPM_COUNTER" >/dev/null 2>&1 ||
		die "Failed to read TPM counter. Please reset TPM through the Heads menu: Options -> TPM/TOTP/HOTP Options -> Reset the TPM"

	sha256sum -c "$TMP_ROLLBACK_FILE" >/dev/null 2>&1 ||
		die "Invalid TPM counter state. Please reset TPM through the Heads menu: Options -> TPM/TOTP/HOTP Options -> Reset the TPM"

	valid_rollback="y"
}

first_menu="y"
get_menu_option() {
	TRACE_FUNC
	num_options=$(wc -l < "$TMP_MENU_FILE")
	if [ "$num_options" -eq 0 ]; then
		die "No boot options"
	fi

	if [ "$num_options" -eq 1 ] && [ "$first_menu" = "y" ]; then
		option_index=1
	elif [ "$gui_menu" = "y" ]; then
		MENU_OPTIONS=""
		n=0
		while read -r option; do
			parse_option
			n=$((n + 1))
			name=$(echo "$name" | tr " " "_")
			MENU_OPTIONS="$MENU_OPTIONS $n ${name} "
		done <$TMP_MENU_FILE

		# shellcheck disable=SC2086
		whiptail --title "Select your boot option" \
			--menu "Choose the boot option [1-$n, a to abort]:" 0 80 8 \
			$MENU_OPTIONS \
			2>/tmp/whiptail || die "Aborting boot attempt"

		option_index=$(cat /tmp/whiptail)
	else
		echo "+++ Select your boot option:"
		n=0
		while read -r option; do
			parse_option
			n=$((n + 1))
			echo "$n. $name [$kernel]"
		done <$TMP_MENU_FILE

		read -r \
			-p "Choose the boot option [1-$n, a to abort]: " \
			option_index

		if [ "$option_index" = "a" ]; then
			die "Aborting boot attempt"
		fi
	fi
	first_menu="n"

	option=$(head -n "$option_index" "$TMP_MENU_FILE" | tail -1)
	parse_option
}

confirm_menu_option() {
	TRACE_FUNC
	if [ "$gui_menu" = "y" ]; then
		default_text="Make default"
		[[ "$CONFIG_TPM_NO_LUKS_DISK_UNLOCK" = "y" ]] && default_text="${default_text} and boot"
		whiptail_warning --title "Confirm boot details" \
			--menu "Confirm the boot details for $name:\n\n$(echo "$kernel" | fold -s -w 80) \n\n" 0 80 8 \
			-- 'd' "${default_text}" 'y' "Boot one time" \
			2>/tmp/whiptail || die "Aborting boot attempt"

		option_confirm=$(cat /tmp/whiptail)
	else
		echo "+++ Please confirm the boot details for $name:"
		echo "$option"

		read -r \
			-n 1 \
			-p "Confirm selection by pressing 'y', make default with 'd': " \
			option_confirm
		echo
	fi
}

parse_option() {
	TRACE_FUNC
	name=$(echo "$option" | cut -d\| -f1)
	kernel=$(echo "$option" | cut -d\| -f3)
}

scan_options() {
	TRACE_FUNC
	INFO "+++ Scanning for unsigned boot options"
	option_file="/tmp/kexec_options.txt"
	scan_boot_options "$bootdir" "$config" "$option_file"
	if [ ! -s $option_file ]; then
		die "Failed to parse any boot options"
	fi
	if [ "$unique" = 'y' ]; then
		sort -r $option_file | uniq >$TMP_MENU_FILE
	else
		cp $option_file $TMP_MENU_FILE
	fi
}

save_default_option() {
	TRACE_FUNC
	option_confirm="n"
	if [ "$gui_menu" != "y" ]; then
		read -r \
			-n 1 \
			-p "Saving a default will modify the disk. Proceed? (Y/n): " \
			default_confirm
		echo
	fi

	[ "$default_confirm" = "" ] && default_confirm="y"
	DEBUG "save_default_option: default_confirm='$default_confirm'"
	if [[ "$default_confirm" = "y" || "$default_confirm" = "Y" ]]; then
		DEBUG "save_default_option: invoking kexec-save-default.sh"
		if kexec-save-default.sh \
			-b "$bootdir" \
			-d "$paramsdev" \
			-p "$paramsdir" \
			-i "$option_index" \
			; then
			echo "+++ Saved defaults to device"

			default_failed="n"
			force_menu="n"
			option_confirm="d"
			return
		else
			DEBUG "save_default_option: kexec-save-default.sh failed with status $?"
			echo "Failed to save defaults"
		fi
	fi
}

default_select() {
	TRACE_FUNC
	# Attempt boot with expected parameters

	# Check that entry matches that which is expected from menu
	default_index=$(basename "$TMP_DEFAULT_FILE" | cut -d. -f 2)

	# Check to see if entries have changed - useful for detecting grub update
	expectedoption=$(cat "$TMP_DEFAULT_FILE")
	option=$(head -n "$default_index" "$TMP_MENU_FILE" | tail -1)
	if [ "$option" != "$expectedoption" ]; then
		if [ "$gui_menu" = "y" ]; then
			whiptail_error --title 'ERROR: Boot Entry Has Changed' \
				--msgbox "The list of boot entries has changed\n\nPlease set a new default" 0 80
		fi
		warn "Boot entry has changed - please set a new default"
		return
	fi
	parse_option

	if [ "$CONFIG_BASIC" != "y" ]; then
		# Enforce that default option hashes are valid
		INFO "+++ Checking verified default boot hash file "
		# Check the hashes of all the files
		if (cd "$bootdir" && sha256sum -c "$TMP_DEFAULT_HASH_FILE" >/tmp/hash_output); then
			echo "+++ Verified default boot hashes "
			valid_hash='y'
		else
			if [ "$gui_menu" = "y" ]; then
				CHANGED_FILES=$(grep -v 'OK$' /tmp/hash_output | cut -f1 -d ':')
				whiptail_error --title 'ERROR: Default Boot Hash Mismatch' \
					--msgbox "The following files failed the verification process:\n${CHANGED_FILES}\nExiting to a recovery shell" 0 80
			fi
		fi
	fi

	echo "+++ Executing default boot for $name:"
	do_boot
	warn "Failed to boot default option"
}

do_boot() {
	TRACE_FUNC
	# Boot validation checks
	DEBUG "do_boot: option_index='$option_index' name='$name'"
	if [ "$CONFIG_BASIC" != y ] && [ "$CONFIG_BOOT_REQ_HASH" = "y" ] && [ "$valid_hash" = "n" ]; then
		die "!!! Missing required boot hashes"
	fi

	if [ "$CONFIG_BASIC" != y ] && [ "$CONFIG_TPM" = "y" ] && [ -r "$TMP_KEY_DEVICES" ]; then
		INITRD=$(kexec-boot.sh -b "$bootdir" -e "$option" -i) ||
			die "!!! Failed to extract the initrd from boot option"
		if [ -z "$INITRD" ]; then
			die "!!! No initrd file found in boot option"
		fi

		kexec-insert-key.sh "$INITRD" ||
			die "!!! Failed to prepare TPM Disk Unlock Key for boot"

		DEBUG "do_boot: kexec with injected initrd"
		kexec-boot.sh -b "$bootdir" -e "$option" \
			-a "$add" -r "$remove" -o "/tmp/secret/initrd.cpio" ||
			die "!!! Failed to boot w/ options: $option"
	else
		DEBUG "do_boot: kexec without injected initrd"
		kexec-boot.sh -b "$bootdir" -e "$option" -a "$add" -r "$remove" ||
			die "!!! Failed to boot w/ options: $option"
	fi
}

user_select() {
	TRACE_FUNC
	# No default expected boot parameters, ask user

	option_confirm=""
	while [ "$option_confirm" != "y" ] && [ "$option_confirm" != "d" ]; do
		DEBUG "user_select: option_confirm='$option_confirm' force_boot='$force_boot' skip_confirm='$skip_confirm'"
		get_menu_option
		DEBUG "user_select: selected option_index='$option_index' name='$name'"
		# In force boot mode, no need offer the option to set a default, just boot
		if [[ "$force_boot" = "y" || "$skip_confirm" = "y" ]]; then
			DEBUG "user_select: booting without confirmation"
			do_boot
		else
			confirm_menu_option
			DEBUG "user_select: option_confirm after confirm='$option_confirm'"
		fi

		if [ "$option_confirm" = "d" ]; then
			DEBUG "user_select: saving default for option_index='$option_index'"
			save_default_option
			DEBUG "user_select: option_confirm after save='$option_confirm'"
		fi
	done

	# After loop, check if we saved a default and decide whether to reboot or boot
	if [ "$option_confirm" = "d" ]; then
		DEBUG "user_select: default saved; TMP_KEY_DEVICES exists=$(test -r "$TMP_KEY_DEVICES" && echo y || echo n)"
		if [ ! -r "$TMP_KEY_DEVICES" ]; then
			# continue below to boot the new default option
			true
		else
			NOTE "Rebooting to start the new default option"
			reboot.sh
			exit 0
		fi
	fi

	DEBUG "user_select: proceeding to do_boot with option_confirm='$option_confirm'"
	do_boot
}

while true; do
	TRACE_FUNC
	if [ "$force_boot" = "y" ] || [ "$CONFIG_BASIC" = "y" ]; then
		DO_WITH_DEBUG check_config "$paramsdir" force
	else
		DO_WITH_DEBUG check_config "$paramsdir"
	fi
	TMP_DEFAULT_FILE=$(find /tmp/kexec/kexec_default.*.txt 2>/dev/null | head -1) || true
	TMP_MENU_FILE="/tmp/kexec/kexec_menu.txt"
	TMP_HASH_FILE="/tmp/kexec/kexec_hashes.txt"
	TMP_TREE_FILE="/tmp/kexec/kexec_tree.txt"
	TMP_DEFAULT_HASH_FILE="/tmp/kexec/kexec_default_hashes.txt"
	TMP_ROLLBACK_FILE="/tmp/kexec/kexec_rollback.txt"
	TMP_KEY_DEVICES="/tmp/kexec/kexec_key_devices.txt"

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
			INFO "TPM: Extending PCR[4] to prevent further secret unsealing"
			tpmr.sh extend -ix 4 -ic generic ||
				die "Failed to extend TPM PCR[4]"
		fi
	fi

	# if no saved options, scan the boot directory and generate
	if [ ! -r "$TMP_MENU_FILE" ]; then
		scan_options
	fi

	if [ "$CONFIG_BASIC" != "y" ]; then
		# Optionally enforce device file hashes
		if [ -r "$TMP_HASH_FILE" ]; then
			valid_global_hash="n"

			verify_global_hashes

			if [ "$valid_global_hash" = "n" ]; then
				die "Failed to verify global hashes"
			fi
		fi

		if [ "$CONFIG_IGNORE_ROLLBACK" != "y" ] && [ -r "$TMP_ROLLBACK_FILE" ]; then
			# in the case of iso boot with a rollback file, do not assume valid
			# shellcheck disable=SC2034
			valid_rollback="n"

			verify_rollback_counter
		fi
	fi

	if [ "$default_failed" != "y" ] && \
		[ "$force_menu" = "n" ] && \
		[ -r "$TMP_DEFAULT_FILE" ] && \
		[ -r "$TMP_DEFAULT_HASH_FILE" ]; then
		default_select
		default_failed="y"
	else
		TRACE_FUNC
		DEBUG "About to call user_select"
		user_select
	fi
	TRACE_FUNC
	DEBUG "Loop iteration ended, looping back"
done

die "!!! Shouldn't get here"
