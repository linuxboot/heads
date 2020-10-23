#!/bin/sh
# Generic configurable boot script via kexec
set -e -o pipefail
. /tmp/config
. /etc/functions

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
		i) valid_hash="y"; valid_rollback="y" ;;
		g) gui_menu="y" ;;
		f) force_boot="y"; valid_hash="y"; valid_rollback="y" ;;
		s) skip_confirm="y" ;;
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

verify_global_hashes()
{
	echo "+++ Checking verified boot hash file "
	# Check the hashes of all the files
	if cd $bootdir && sha256sum -c "$TMP_HASH_FILE" > /tmp/hash_output ; then
		echo "+++ Verified boot hashes "
		valid_hash='y'
		valid_global_hash='y'
	else
		if [ "$gui_menu" = "y" ]; then
			CHANGED_FILES=$(grep -v 'OK$' /tmp/hash_output | cut -f1 -d ':')
			whiptail $BG_COLOR_ERROR --title 'ERROR: Boot Hash Mismatch' \
				--msgbox "The following files failed the verification process:\n${CHANGED_FILES}\nExiting to a recovery shell" 16 60
		fi
		die "$TMP_HASH_FILE: boot hash mismatch"
	fi
}

verify_rollback_counter()
{
	TPM_COUNTER=`grep counter $TMP_ROLLBACK_FILE | cut -d- -f2`
	if [ -z "$TPM_COUNTER" ]; then
		die "$TMP_ROLLBACK_FILE: TPM counter not found?"
	fi

	read_tpm_counter $TPM_COUNTER \
	|| die "Failed to read TPM counter"

	sha256sum -c $TMP_ROLLBACK_FILE \
	|| die "Invalid TPM counter state"

	valid_rollback="y"
}

first_menu="y"
get_menu_option() {
	num_options=`cat $TMP_MENU_FILE | wc -l`
	if [ $num_options -eq 0 ]; then
		die "No boot options"
	fi

	if [ $num_options -eq 1 -a $first_menu = "y" ]; then
		option_index=1
	elif [ "$gui_menu" = "y" ]; then
		MENU_OPTIONS=""
		n=0
		while read option
		do
			parse_option
			n=`expr $n + 1`
			name=$(echo $name | tr " " "_")
			kernel=$(echo $kernel | cut -f2 -d " ")
			MENU_OPTIONS="$MENU_OPTIONS $n ${name}_[$kernel]"
		done < $TMP_MENU_FILE

		whiptail --clear --title "Select your boot option" \
			--menu "Choose the boot option [1-$n, a to abort]:" 20 120 8 \
			-- $MENU_OPTIONS \
			2>/tmp/whiptail || die "Aborting boot attempt"

		option_index=$(cat /tmp/whiptail)
	else
		echo "+++ Select your boot option:"
		n=0
		while read option
		do
			parse_option
			n=`expr $n + 1`
			echo "$n. $name [$kernel]"
		done < $TMP_MENU_FILE

		read \
			-p "Choose the boot option [1-$n, a to abort]: " \
			option_index

		if [ "$option_index" = "a" ]; then
			die "Aborting boot attempt"
		fi
	fi
	first_menu="n"

	option=`head -n $option_index $TMP_MENU_FILE | tail -1`
	parse_option
}

confirm_menu_option() {
	if [ "$gui_menu" = "y" ]; then
		whiptail --clear --title "Confirm boot details" \
			--menu "Confirm the boot details for $name:\n\n$option\n\n" 20 120 8 \
			-- 'y' "Boot $name" 'd' "Make $name the default" \
			2>/tmp/whiptail || die "Aborting boot attempt"

		option_confirm=$(cat /tmp/whiptail)
	else
		echo "+++ Please confirm the boot details for $name:"
		echo $option

		read \
			-n 1 \
			-p "Confirm selection by pressing 'y', make default with 'd': " \
			option_confirm
		echo
	fi
}

parse_option() {
	name=`echo $option | cut -d\| -f1`
	kernel=`echo $option | cut -d\| -f3`
}

scan_options() {
	echo "+++ Scanning for unsigned boot options"
	option_file="/tmp/kexec_options.txt"
	if [ -r $option_file ]; then rm $option_file; fi
	for i in `find $bootdir -name "$config"`; do
		kexec-parse-boot "$bootdir" "$i" >> $option_file
	done
	# FC29/30+ may use BLS format grub config files
	# https://fedoraproject.org/wiki/Changes/BootLoaderSpecByDefault
	# only parse these if $option_file is still empty
	if [ ! -s $option_file ] && [ -d "$bootdir/loader/entries" ]; then
		for i in `find $bootdir -name "$config"`; do
			kexec-parse-bls "$bootdir" "$i" "$bootdir/loader/entries" >> $option_file
		done
	fi
	if [ ! -s $option_file ]; then
		die "Failed to parse any boot options"
	fi
	if [ "$unique" = 'y' ]; then
		sort -r $option_file | uniq > $TMP_MENU_FILE
	else
		cp $option_file $TMP_MENU_FILE
	fi
}

save_default_option() {
	read \
		-n 1 \
		-p "Saving a default will modify the disk. Proceed? (Y/n): " \
		default_confirm
	echo

	[ "$default_confirm" = "" ] && default_confirm="y"
	if [[ "$default_confirm" = "y" || "$default_confirm" = "Y" ]]; then
		if kexec-save-default \
			-b "$bootdir" \
			-d "$paramsdev" \
			-p "$paramsdir" \
			-i "$option_index" \
		; then
			echo "+++ Saved defaults to device"
			sleep 2
			default_failed="n"
			force_menu="n"
			return
		else
			echo "Failed to save defaults"
		fi
	fi

	option_confirm="n"
}

default_select() {
	# Attempt boot with expected parameters

	# Check that entry matches that which is expected from menu
	default_index=`basename "$TMP_DEFAULT_FILE" | cut -d. -f 2`

	# Check to see if entries have changed - useful for detecting grub update
	expectedoption=`cat $TMP_DEFAULT_FILE`
	option=`head -n $default_index $TMP_MENU_FILE | tail -1`
	if [ "$option" != "$expectedoption" ]; then
		if [ "$gui_menu" = "y" ]; then
			whiptail $BG_COLOR_ERROR --title 'ERROR: Boot Entry Has Changed' \
				--msgbox "The list of boot entries has changed\n\nPlease set a new default" 16 60
		fi
		warn "!!! Boot entry has changed - please set a new default"
		return
	fi
	parse_option

	# Enforce that default option hashes are valid
	echo "+++ Checking verified default boot hash file "
	# Check the hashes of all the files
	if cd $bootdir && sha256sum -c "$TMP_DEFAULT_HASH_FILE" > /tmp/hash_output ; then
		echo "+++ Verified default boot hashes "
		valid_hash='y'
	else
		if [ "$gui_menu" = "y" ]; then
			CHANGED_FILES=$(grep -v 'OK$' /tmp/hash_output | cut -f1 -d ':')
			whiptail $BG_COLOR_ERROR --title 'ERROR: Default Boot Hash Mismatch' \
				--msgbox "The following files failed the verification process:\n${CHANGED_FILES}\nExiting to a recovery shell" 16 60
		fi
		die "!!! $TMP_DEFAULT_HASH_FILE: default boot hash mismatch"
	fi

	echo "+++ Executing default boot for $name:"
	do_boot
	warn "Failed to boot default option"
}

user_select() {
	# No default expected boot parameters, ask user

	option_confirm=""
	while [ "$option_confirm" != "y" -a "$option_confirm" != "d" ]
	do
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
			# rerun primary boot loop to boot the new default option
			continue
		else
			echo "+++ Rebooting to start the new default option"
			sleep 2
			reboot \
			|| die "!!! Failed to reboot system"
		fi
	fi

	do_boot
}

do_boot()
{
	if [ "$CONFIG_BOOT_REQ_ROLLBACK" = "y" -a "$valid_rollback" = "n" ]; then
		die "!!! Missing required rollback counter state"
	fi

	if [ "$CONFIG_BOOT_REQ_HASH" = "y" -a "$valid_hash" = "n" ]; then
		die "!!! Missing required boot hashes"
	fi

	if [ "$CONFIG_TPM" = "y" \
		-a -r "$TMP_KEY_DEVICES" ]; then
		INITRD=`kexec-boot -b "$bootdir" -e "$option" -i` \
		|| die "!!! Failed to extract the initrd from boot option"
		if [ -z "$INITRD" ]; then
			die "!!! No initrd file found in boot option"
		fi

		kexec-insert-key $INITRD \
		|| die "!!! Failed to insert disk key into a new initrd"

		kexec-boot -b "$bootdir" -e "$option" \
			-a "$add" -r "$remove" -o "/tmp/secret/initrd.cpio" \
		|| die "!!! Failed to boot w/ options: $option"
	else
		kexec-boot -b "$bootdir" -e "$option" -a "$add" -r "$remove" \
		|| die "!!! Failed to boot w/ options: $option"
	fi
}

while true; do
	if [ "$force_boot" = "y" ]; then
	  check_config $paramsdir force
	else
	  check_config $paramsdir
	fi
	TMP_DEFAULT_FILE=`find /tmp/kexec/kexec_default.*.txt 2>/dev/null | head -1` || true
	TMP_MENU_FILE="/tmp/kexec/kexec_menu.txt"
	TMP_HASH_FILE="/tmp/kexec/kexec_hashes.txt"
	TMP_DEFAULT_HASH_FILE="/tmp/kexec/kexec_default_hashes.txt"
	TMP_ROLLBACK_FILE="/tmp/kexec/kexec_rollback.txt"
	TMP_KEY_DEVICES="/tmp/kexec/kexec_key_devices.txt"
	TMP_KEY_LVM="/tmp/kexec/kexec_key_lvm.txt"

# Allow a way for users to ignore warnings and boot into their systems
# even if hashes don't match
	if [ "$force_boot" = "y" ]; then
		scan_options
		# Remove boot splash and make background red in the event of a forced boot
		add="$add vt.default_red=0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff"
		remove="$remove splash quiet"
		user_select
	fi

	if [ "$CONFIG_TPM" = "y" \
		-a ! -r "$TMP_KEY_DEVICES" ]; then
		# Extend PCR4 as soon as possible
		tpm extend -ix 4 -ic generic \
		|| die "Failed to extend PCR 4"
	fi

	# if no saved options, scan the boot directory and generate
	if [ ! -r "$TMP_MENU_FILE" ]; then
		scan_options
	fi

	if [ "$CONFIG_TPM" = "y" ]; then
		# Optionally enforce device file hashes
		if [ -r "$TMP_HASH_FILE" ]; then
			valid_global_hash="n"

			verify_global_hashes

			if [ "$valid_global_hash" = "n" ]; then
				die "Failed to verify global hashes"
			fi
		fi

		if [ -r "$TMP_ROLLBACK_FILE" ]; then
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

die "!!! Shouldn't get here""
