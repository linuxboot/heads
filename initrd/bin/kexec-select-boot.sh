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

PRIMHASH_FILE="$paramsdir/kexec_primhdl_hash.txt"
if [ "$CONFIG_TPM2_TOOLS" = "y" ]; then
	if [ -s "$PRIMHASH_FILE" ]; then
		#PRIMHASH_FILE (normally /boot/kexec_primhdl_hash.txt) exists and is not empty
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
		#TODO: Simplify/Automatize TPM2 firmware upgrade process. Today: upgrade, reboot, reseal(type TPM owner passphrase), resign, boot
		default_failed="y"
		DEBUG "Hash of TPM2 primary key handle does not exist under $PRIMHASH_FILE"
	fi
fi

verify_global_hashes() {
	STATUS "Checking verified boot hash file"
	# Check the hashes of all the files
	if verify_checksums "$bootdir" "$gui_menu"; then
		STATUS_OK "Verified boot hashes"
		valid_hash='y'
		valid_global_hash='y'
	else
		if [ "$gui_menu" = "y" ]; then
			CHANGED_FILES=$(grep -v 'OK$' /tmp/hash_output | cut -f1 -d ':')
			whiptail_error --title 'ERROR: Boot Hash Mismatch' \
				--msgbox "The following files failed the verification process:\n${CHANGED_FILES}\nExiting to a recovery shell" 0 80
		fi
		DIE "$TMP_HASH_FILE: boot hash mismatch"
	fi
	# If user enables it, check root hashes before boot as well
	if [[ "$CONFIG_ROOT_CHECK_AT_BOOT" = "y" && "$force_menu" == "n" ]]; then
		if root-hashes-gui.sh -c; then
			STATUS_OK "Verified root hashes, continuing boot"
			# if user re-signs, it wipes out saved options, so scan the boot directory and generate
			if [ ! -r "$TMP_MENU_FILE" ]; then
				scan_options
			fi
		else
			# root-hashes-gui.sh handles the GUI error menu, just DIE here
			if [ "$gui_menu" = "y" ]; then
				whiptail_error --title 'ERROR: Root Hash Mismatch' \
					--msgbox "The root hash check failed!\nExiting to a recovery shell" 0 80
			fi
			DIE "root hash mismatch, see /tmp/hash_output_mismatches for details"
		fi
	fi
}

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

first_menu="y"
get_menu_option() {
	num_options=$(cat $TMP_MENU_FILE | wc -l)
	if [ $num_options -eq 0 ]; then
		DIE "No boot options"
	fi

	if [ $num_options -eq 1 -a $first_menu = "y" ]; then
		option_index=1
	elif [ "$gui_menu" = "y" ]; then
		MENU_OPTIONS=()
		n=0
		while read option; do
			parse_option
			n=$(expr $n + 1)
			MENU_OPTIONS+=("$n" "$name")
		done <$TMP_MENU_FILE

		whiptail_type $BG_COLOR_MAIN_MENU --title "Select your boot option" \
			--menu "Choose the boot option [1-$n, a to abort]:" 0 80 8 \
			-- "${MENU_OPTIONS[@]}" \
			2>/tmp/whiptail || DIE "Aborting boot attempt"

		option_index=$(cat /tmp/whiptail)
	else
		STATUS "Select your boot option:"
		n=0
		while read option; do
			parse_option
			n=$(expr $n + 1)
			# Use the same device routing as INPUT so option lines and the
			# prompt share the same unbuffered fd (HEADS_TTY when in gui-init
			# context, stderr otherwise).  Writing to stdout is wrong here
			# because DO_WITH_DEBUG pipes stdout through tee for debug logging,
			# making it fully buffered — the last option would appear after the
			# INPUT prompt.
			printf '%d. %s [%s]\n' "$n" "$name" "$kernel" >"${HEADS_TTY:-/dev/stderr}"
		done <$TMP_MENU_FILE

		INPUT "Choose the boot option [1-$n, a to abort]:" -r option_index

		if [ "$option_index" = "a" ]; then
			DIE "Aborting boot attempt"
		fi
	fi
	first_menu="n"

	option=$(head -n $option_index $TMP_MENU_FILE | tail -1)
	parse_option
}

confirm_menu_option() {
	if [ "$gui_menu" = "y" ]; then
		default_text="Make default"
		[[ "$CONFIG_TPM_NO_LUKS_DISK_UNLOCK" = "y" ]] && default_text="${default_text} and boot"
		whiptail_warning --title "Confirm boot details" \
			--menu "Confirm the boot details for $name:\n\n$(echo $kernel | fold -s -w 80) \n\n" 0 80 8 \
			-- 'd' "${default_text}" 'y' "Boot one time" \
			2>/tmp/whiptail || DIE "Aborting boot attempt"

		option_confirm=$(cat /tmp/whiptail)
	else
		STATUS "Confirm boot details for $name:"
		INFO "$option"

		INPUT "Confirm selection by pressing 'y', make default with 'd':" -n 1 option_confirm
	fi
}

parse_option() {
	name=$(echo $option | cut -d\| -f1)
	kernel=$(echo $option | cut -d\| -f3)
}

scan_options() {
	STATUS "Scanning for unsigned boot options"
	option_file="/tmp/kexec_options.txt"
	scan_boot_options "$bootdir" "$config" "$option_file"
	if [ ! -s $option_file ]; then
		DIE "Failed to parse any boot options"
	fi
	if [ "$unique" = 'y' ]; then
		sort -r $option_file | uniq >$TMP_MENU_FILE
	else
		cp $option_file $TMP_MENU_FILE
	fi
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

while true; do
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
			INFO "TPM: Extending PCR[4] to prevent further secret unsealing"
			tpmr.sh extend -ix 4 -ic generic ||
				DIE "Failed to extend TPM PCR[4]"
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
				DIE "Failed to verify global hashes"
			fi
		fi

		if [ "$CONFIG_IGNORE_ROLLBACK" != "y" -a -r "$TMP_ROLLBACK_FILE" ]; then
			# in the case of iso boot with a rollback file, do not assume valid
			valid_rollback="n"

			verify_rollback_counter
		fi
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
