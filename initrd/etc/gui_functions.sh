#!/bin/bash
# Shell functions for common operations using fbwhiptail
. /etc/functions.sh

# Pause for the configured timeout before booting automatically.  Returns 0 to
# continue with automatic boot, nonzero if user interrupted.
pause_automatic_boot() {
	TRACE_FUNC
	if IFS= read -t "$CONFIG_AUTO_BOOT_TIMEOUT" -s -n 1 -r -p \
		$'Automatic boot in '"$CONFIG_AUTO_BOOT_TIMEOUT"$' seconds unless interrupted by keypress...\n'; then
		return 1 # Interrupt automatic boot
	fi
	return 0 # Continue with automatic boot
}

mount_usb() {
	TRACE_FUNC
	# Unmount any previous USB device
	if grep -q /media /proc/mounts; then
		umount /media || DIE "Unable to unmount /media"
	fi
	# Mount the USB boot device
	mount-usb.sh && USB_FAILED=0 || ([ $? -eq 5 ] && exit 1 || USB_FAILED=1)
	if [ $USB_FAILED -ne 0 ]; then
		whiptail_error --title 'USB Drive Missing' \
			--msgbox "Insert your USB drive and press Enter to continue." 0 80
		mount-usb.sh && USB_FAILED=0 || ([ $? -eq 5 ] && exit 1 || USB_FAILED=1)
		if [ $USB_FAILED -ne 0 ]; then
			whiptail_error --title 'ERROR: Mounting /media Failed' \
				--msgbox "Unable to mount USB device" 0 80
			exit 1
		fi
	fi
}

# -- Display related functions --

# Rebuild "$@" into global _WHIPTAIL_ARGS, wrapping the body text argument
# (the one immediately following --msgbox, --yesno, --menu, --inputbox, etc.)
# through printf '%b' | fold -s -w 75 so \n escapes are expanded and long
# lines fit inside an 80-column dialog.  All other arguments are passed
# through unchanged.  Callers must not be called recursively.
_whiptail_preprocess_args() {
	_WHIPTAIL_ARGS=()
	local _wrap_next=0 _arg
	for _arg in "$@"; do
		if [ "$_wrap_next" = 1 ]; then
			# fold -s breaks at spaces, preserving word boundaries.
			# BusyBox fold -s also handles unbreakable tokens by
			# falling back to character-level fold at the width
			# limit, so no separate fallback is needed.
			_WHIPTAIL_ARGS+=("$(printf '%b' "$_arg" | fold -s -w 75)")
			_wrap_next=0
		else
			_WHIPTAIL_ARGS+=("$_arg")
			case "$_arg" in
			--msgbox | --yesno | --menu | --inputbox | --passwordbox | --checklist | --radiolist)
				_wrap_next=1
				;;
			esac
		fi
	done
}

# Produce a whiptail prompt with 'warning' background, works for fbwhiptail and newt
whiptail_warning() {
	TRACE_FUNC
	_whiptail_preprocess_args "$@"
	if [ -x /bin/fbwhiptail ]; then
		DEBUG "whiptail_warning: whiptail $BG_COLOR_WARNING $*"
		whiptail $BG_COLOR_WARNING "${_WHIPTAIL_ARGS[@]}"
	else
		DEBUG "whiptail_warning: NEWT_COLORS=root=,$TEXT_BG_COLOR_WARNING whiptail $*"
		env NEWT_COLORS="root=,$TEXT_BG_COLOR_WARNING" whiptail "${_WHIPTAIL_ARGS[@]}"
	fi
}

# Produce a whiptail prompt with 'error' background, works for fbwhiptail and newt
whiptail_error() {
	TRACE_FUNC
	_whiptail_preprocess_args "$@"
	if [ -x /bin/fbwhiptail ]; then
		DEBUG "whiptail_error: whiptail $BG_COLOR_ERROR $*"
		whiptail $BG_COLOR_ERROR "${_WHIPTAIL_ARGS[@]}"
	else
		DEBUG "whiptail_error: NEWT_COLORS=root=,$TEXT_BG_COLOR_ERROR whiptail $*"
		env NEWT_COLORS="root=,$TEXT_BG_COLOR_ERROR" whiptail "${_WHIPTAIL_ARGS[@]}"
	fi
}

# Produce a whiptail prompt of the given type - 'error', 'warning', or 'normal'
whiptail_type() {
	TRACE_FUNC
	local TYPE="$1"
	shift
	DEBUG "whiptail_type: type=$TYPE args=$*"
	case "$TYPE" in
	error)
		whiptail_error "$@"
		;;
	warning)
		whiptail_warning "$@"
		;;
	normal)
		_whiptail_preprocess_args "$@"
		DEBUG "whiptail_type: whiptail $*"
		whiptail "${_WHIPTAIL_ARGS[@]}"
		;;
	esac
}

# Create display text for a size in bytes in either MB or GB, unit selected
# automatically, rounded to nearest
display_size() {
	TRACE_FUNC
	local size_bytes unit_divisor unit_symbol
	size_bytes="$1"

	# If it's less than 1 GB, display MB
	if [ "$((size_bytes))" -lt "$((1024 * 1024 * 1024))" ]; then
		unit_divisor=$((1024 * 1024))
		unit_symbol="MB"
	else
		unit_divisor=$((1024 * 1024 * 1024))
		unit_symbol="GB"
	fi

	# Divide by the unit divisor and round to nearest
	echo "$(((size_bytes + unit_divisor / 2) / unit_divisor)) $unit_symbol"
}

# Create display text for the size of a block device using MB or GB, rounded to
# nearest
display_block_device_size() {
	TRACE_FUNC
	local block_dev disk_size_bytes
	block_dev="$1"

	# Obtain size of thumb drive to be wiped with fdisk
	if ! disk_size_bytes="$(blockdev --getsize64 "$block_dev")"; then
		exit 1
	fi

	display_size "$disk_size_bytes"
}

# Display a menu to select a file from a list.  Pass the name of a file
# containing the list.
# --show-size: Append sizes of files listed.  Currently only supports block
#   devices.
# $1: Name of file listing files that can be chosen (one per line)
# $2: Optional prompt message
# $3: Optional prompt title
#
# Success: Sets FILE with the selected file
# User aborted: Exits successfully with FILE empty
# No entries in list: Displays error and exits unsuccessfully
file_selector() {
	TRACE_FUNC

	local FILE_LIST MENU_MSG MENU_TITLE CHOICE_ARGS SHOW_SIZE OPTION_SIZE option_index

	FILE=""

	if [ "$1" = "--show-size" ]; then
		SHOW_SIZE=y
		shift
	fi

	FILE_LIST=$1
	MENU_MSG=${2:-"Choose the file"}
	MENU_TITLE=${3:-"Select your File"}

	CHOICE_ARGS=()
	n=0
	while read option; do
		n="$((++n))"

		if [ "$SHOW_SIZE" = "y" ] && OPTION_SIZE="$(display_block_device_size "$option")"; then
			option="$option - $OPTION_SIZE"
		fi
		CHOICE_ARGS+=("$n" "$option")
	done <"$FILE_LIST"

	if [ "${#CHOICE_ARGS[@]}" -eq 0 ]; then
		whiptail_error --title 'ERROR: No Files Found' \
			--msgbox "No Files found matching the pattern. Aborting." 0 80
		exit 1
	fi

	CHOICE_ARGS+=(a Abort)

	# create file menu options
	option_index=""
	while [ -z "$option_index" ]; do
		whiptail --title "${MENU_TITLE}" \
			--menu "${MENU_MSG}:" 20 120 8 \
			-- "${CHOICE_ARGS[@]}" \
			2>/tmp/whiptail || DIE "Aborting"

		option_index=$(cat /tmp/whiptail)

		if [ "$option_index" != "a" ]; then
			FILE="$(head -n "$option_index" "$FILE_LIST" | tail -1)"
		fi
	done
}

show_system_info() {
	TRACE_FUNC
	# ensure EC_VER is populated; this mirrors the behaviour of the
	# init script which exports EC_VER early, but calling the helper
	# here makes the GUI menu self‑contained.
	if [ -z "$EC_VER" ]; then
		EC_VER=$(ec_version)
	fi
	battery_status="$(print_battery_state)"

	memtotal=$(cat /proc/meminfo | grep 'MemTotal' | tr -s ' ' | cut -f2 -d ' ')
	memtotal=$((${memtotal} / 1024 / 1024 + 1))
	cpustr=$(cat /proc/cpuinfo | grep 'model name' | uniq | sed -r 's/\(R\)//;s/\(TM\)//;s/CPU //;s/model name.*: //')
	kernel=$(uname -s -r)

	local ec_ver_line=""
	[ -n "$EC_VER" ] && ec_ver_line="
	EC_VER: ${EC_VER}"

	local disk_info="$(disk_info_sysfs)"
	DEBUG "disk_info=\n${disk_info}"

	local msgbox="${BOARD_NAME}

	FW_VER: ${FW_VER}${ec_ver_line}
	Kernel: ${kernel}

	CPU: ${cpustr}
	Microcode: $(cat /proc/cpuinfo | grep microcode | uniq | cut -d':' -f2 | tr -d ' ')
	RAM: ${memtotal} GB
	$battery_status
	${disk_info}
	"

	local msgbox_rm_tabs=$(echo "$msgbox" | tr -d "\t")

	whiptail_type $BG_COLOR_MAIN_MENU --title 'System Info' \
		--msgbox "$msgbox_rm_tabs" 0 80
}

# Show measured integrity report including TOTP/HOTP status and /boot integrity.
report_integrity_measurements() {
	TRACE_FUNC
	local date_now hash_state msg menu_msg totp_state hotp_state signature_state sig_status sig_detail sig_guidance report_body report_option signing_key_state

	date_now=$(date "+%Y-%m-%d %H:%M:%S %Z")
	totp_state="N/A"
	hotp_state="N/A"
	DEBUG "integrity report generated at $date_now"
	STATUS "Preparing Measured Integrity Report - hashing and verifying /boot"

	# Detect USB dongle branding for integrity output. This may initialize USB
	# via detect_usb_security_dongle_branding().
	detect_usb_security_dongle_branding

	if [ "$CONFIG_TPM" = "y" ]; then
		totp_state="UNAVAILABLE"
		if [ "$CONFIG_TPM2_TOOLS" != "y" ] || [ -f /tmp/secret/primary.handle ]; then
			DEBUG "report_integrity_measurements: unsealing integrity TOTP from TPM"
			if HEADS_NONFATAL_UNSEAL=y tpmr.sh unseal 4d47 0,1,2,3,4,7 312 /tmp/secret/integrity_totp_key >/dev/null 2>&1; then
				truncate_max_bytes 20 /tmp/secret/integrity_totp_key >/dev/null 2>&1
				if totp </tmp/secret/integrity_totp_key >/tmp/secret/integrity_totp 2>/dev/null; then
					totp_state="$(cat /tmp/secret/integrity_totp 2>/dev/null)"
				else
					totp_state="ERROR"
				fi
			fi
		fi
		shred -n 10 -z -u /tmp/secret/integrity_totp_key /tmp/secret/integrity_totp 2>/dev/null
		DEBUG "report_integrity_measurements: totp_state=$totp_state"
	fi

	if [ -x /bin/hotp_verification ]; then
		STATUS "Checking $DONGLE_BRAND presence"
		local _hotp_info
		DEBUG "report_integrity_measurements: querying HOTP token info"
		if _hotp_info="$(hotp_verification info 2>/dev/null)"; then
			hotp_state="$DONGLE_BRAND PRESENT"
			hotpkey_fw_display "$_hotp_info" "$DONGLE_BRAND"
		elif [ "$DONGLE_BRAND" != "USB Security dongle" ]; then
			hotp_state="$DONGLE_BRAND INCOMPATIBLE"
			DEBUG "report_integrity_measurements: $DONGLE_BRAND detected but HOTP verification failed"
		else
			hotp_state="$DONGLE_BRAND MISSING"
			DEBUG "report_integrity_measurements: hotp_verification info failed, hotp_state=$hotp_state"
		fi
	fi

	# Detached signature trust must be established before any hash files are trusted.
	signature_state="UNVERIFIED"
	if [ ! -r /boot/kexec.sig ]; then
		signature_state="MISSING SIGNATURE FILE"
		hash_state="UNTRUSTED (DETACHED SIGNATURE MISSING)"
		DEBUG "report_integrity_measurements: /boot/kexec.sig is missing"
		sig_detail="/boot/kexec.sig does not exist - /boot files cannot be verified as authentic."
		sig_guidance="If unexpected, stop and restore a known-good /boot. If expected, choose: Investigate discrepancies -> Update checksums now."
	elif detached_kexec_signature_valid /boot; then
		signature_state="VERIFIED"
		# detached_kexec_signature_valid confirms trust of kexec*.txt; load those trusted references.
		check_config /boot force
		TMP_HASH_FILE="/tmp/kexec/kexec_hashes.txt"
		TMP_TREE_FILE="/tmp/kexec/kexec_tree.txt"
		if [ -r "$TMP_HASH_FILE" ] && [ -r "$TMP_TREE_FILE" ] && verify_checksums /boot n; then
			hash_state="OK"
		else
			hash_state="ALTERED OR UNKNOWN"
		fi
		sig_detail="ROM-fused public key authenticated /boot/kexec.sig - all /boot files match the signed hashes."
		sig_guidance="No signature fix needed."
	else
		sig_status="$(detached_kexec_signature_failure_status /boot)"
		case "$sig_status" in
		MALFORMED)
			signature_state="SIGNATURE FILE IS BROKEN"
			hash_state="UNTRUSTED (SIGNATURE FILE IS BROKEN)"
			sig_detail="/boot/kexec.sig cannot be parsed - the file appears corrupted or truncated."
			sig_guidance="If unexpected, stop and restore a known-good /boot. If expected, choose: Investigate discrepancies -> Update checksums now."
			;;
		BAD)
			signature_state="SIGNATURE DOES NOT MATCH BOOT FILES"
			hash_state="UNTRUSTED (SIGNATURE DOES NOT MATCH FILES)"
			sig_detail="The signature does not match the current /boot files - files may have been altered since last signed."
			sig_guidance="If unexpected, stop and investigate tampering. If expected, choose: Investigate discrepancies -> Update checksums now."
			;;
		UNKNOWN_KEY)
			local _signer_info
			_signer_info="$(detached_kexec_signature_signer_info)"
			signature_state="SIGNED BY UNTRUSTED KEY"
			hash_state="UNTRUSTED - content cannot be verified"
			if [ -n "$_signer_info" ]; then
				sig_detail="/boot was signed by an untrusted key (${_signer_info}). The files cannot be verified and must be treated as compromised. Possible causes: disk swap, /boot signed on a different machine, or firmware reflashed with a new key."
				sig_guidance="Only re-sign if you can independently confirm /boot is in expected state, knowing it was signed by ${_signer_info}. If in doubt, restore /boot from a trusted backup. Do NOT re-sign blindly - that would bless a potentially compromised /boot. For intentional re-ownership or a fresh OS install, perform OEM Factory Reset / Re-Ownership."
			else
				sig_detail="/boot was signed by an untrusted key (signer identity could not be determined). The files cannot be verified and must be treated as compromised. Possible causes: disk swap, /boot signed on a different machine, or firmware reflashed with a new key."
				sig_guidance="Treat /boot as compromised and restore from a trusted backup. Do NOT re-sign unverified files - that would bless a potentially compromised /boot. For intentional re-ownership or a fresh OS install, perform OEM Factory Reset / Re-Ownership."
			fi
			;;
		*)
			signature_state="SIGNATURE CHECK FAILED"
			hash_state="UNTRUSTED (DETACHED SIGNATURE INVALID)"
			sig_detail="The signature check failed for an unknown reason."
			sig_guidance="If this was NOT expected, stop and investigate. Only choose Update checksums after you trust the current /boot files."
			;;
		esac
		DEBUG "report_integrity_measurements: detached signature status=$sig_status detail=$(detached_kexec_signature_failure_detail_one_line)"
	fi
	INTEGRITY_REPORT_HASH_STATE="$hash_state"

	# Check signing key: try card immediately (USB already up); only prompt if not accessible.
	# wait_for_gpg_card sets global gpg_output to the card-status output on success.
	STATUS "Verifying signing key on $DONGLE_BRAND"
	# enable_usb is called internally by wait_for_gpg_card
	gpg_output=""
	local _card_detected=0
	if wait_for_gpg_card 2>/dev/null; then
		_card_detected=1
	else
		whiptail_type "$BG_COLOR_MAIN_MENU" --title 'Signing Card Check' \
			--msgbox "Please insert your $DONGLE_BRAND and press OK." 0 80
		if wait_for_gpg_card 2>/dev/null; then
			_card_detected=1
		fi
	fi

	# Determine signing key state from card-status output (gpg_output set by wait_for_gpg_card).
	local _card_sig_fpr _rom_fprs signing_key_guidance
	if [ "$_card_detected" -eq 0 ]; then
		signing_key_state="NO $DONGLE_BRAND DETECTED"
		signing_key_guidance="No $DONGLE_BRAND detected. Insert the correct dongle and retry, or perform OEM Factory Reset / Re-Ownership."
	else
		_card_sig_fpr=$(echo "$gpg_output" |
			awk -F: '/Signature key/ {gsub(/[[:space:]]/,"",$2); print $2; exit}')
		if [ -z "$_card_sig_fpr" ] || [ "$_card_sig_fpr" = "[none]" ]; then
			signing_key_state="DONGLE NOT PROVISIONED"
			signing_key_guidance="$DONGLE_BRAND is connected but has no signing key (unprovisioned). Provision the dongle with the signing subkey, or perform OEM Factory Reset / Re-Ownership to start fresh with a new key."
		else
			_rom_fprs=$(gpg --with-colons --list-keys 2>/dev/null |
				awk -F: '/^fpr/ {print $10}')
			if echo "$_rom_fprs" | grep -qF "$_card_sig_fpr"; then
				signing_key_state="DONGLE MATCHES ROM-TRUSTED KEY"
				signing_key_guidance=""
				STATUS_OK "Signing key verified on $DONGLE_BRAND"
			else
				signing_key_state="DONGLE KEY NOT ROM-TRUSTED"
				signing_key_guidance="$DONGLE_BRAND has a signing key that does not match this firmware's trusted key. OEM Factory Reset / Re-Ownership is required to establish new trusted ownership."
			fi
		fi
	fi
	DEBUG "report_integrity_measurements: signing_key_state=$signing_key_state card_sig_fpr=${_card_sig_fpr:-none}"

	# Build display-friendly variants of TOTP/HOTP state for the report
	local totp_display hotp_display
	case "$totp_state" in
	UNAVAILABLE)
		totp_display="SEALED SECRET UNAVAILABLE - Reseal required (expected after TPM reset, re-ownership, or firmware update)"
		;;
	ERROR)
		totp_display="ERROR - TOTP calculation failed"
		;;
	*)
		totp_display="$totp_state"
		;;
	esac
	case "$hotp_state" in
	*"MISSING")
		hotp_display="$DONGLE_BRAND NOT CONNECTED"
		;;
	*"PRESENT")
		hotp_display="$DONGLE_BRAND CONNECTED (presence confirmed)"
		;;
	*"INCOMPATIBLE")
		hotp_display="$DONGLE_BRAND INCOMPATIBLE ($DONGLE_BRAND does not support HOTP)"
		;;
	*)
		hotp_display="$hotp_state"
		;;
	esac

	local action_guidance
	if [ -n "$signing_key_guidance" ]; then
		action_guidance="$signing_key_guidance"
	else
		action_guidance="$sig_guidance"
	fi
	report_body="Date: $date_now\nTOTP: $totp_display\nHOTP: $hotp_display\n\nBoot signature (/boot/kexec.sig): $signature_state\n$sig_detail\nBoot files: $hash_state\n$DONGLE_BRAND key: $signing_key_state\n\nAction: $action_guidance"
	if [ "$hash_state" != "OK" ]; then
		report_body="$report_body\n\nIf /boot integrity is not OK, investigate before sealing new secrets or performing TPM reset or re-ownership."
	fi
	DEBUG "report_integrity_measurements: totp=$totp_state hotp=$hotp_state signature=$signature_state hash=$hash_state"
	DEBUG "report_integrity_measurements: signature_detail=$sig_detail"
	DEBUG "report_integrity_measurements: signature_guidance=$sig_guidance signing_key_guidance=$signing_key_guidance"
	DEBUG "report_integrity_measurements: INTEGRITY_REPORT_HASH_STATE=$INTEGRITY_REPORT_HASH_STATE"
	if [ "$totp_state" = "UNAVAILABLE" ] && [ "$hash_state" = "OK" ] && [ "$signing_key_state" = "DONGLE MATCHES ROM-TRUSTED KEY" ]; then
		DEBUG "report_integrity_measurements: TOTP unseal unavailable but /boot integrity is OK; reseal/update flows may proceed after user confirmation"
		report_body="$report_body\n\nNote: /boot is intact - generate a new HOTP/TOTP secret to restore real-time boot attestation."
	fi
	msg="Measured Integrity Report\n\n$report_body"
	# menu_msg omits the guidance paragraphs to keep the dialog within terminal height
	menu_msg="Measured Integrity Report\n\nDate: $date_now\nTOTP: $totp_display\nHOTP: $hotp_display\n\nBoot signature (/boot/kexec.sig): $signature_state\n$sig_detail\nBoot files: $hash_state\n$DONGLE_BRAND key: $signing_key_state\n\nChoose an action:"

	if [ "$hash_state" = "OK" ] && [ "$signing_key_state" = "DONGLE MATCHES ROM-TRUSTED KEY" ]; then
		whiptail_type $BG_COLOR_MAIN_MENU --title 'Measured Integrity Report' \
			--msgbox "$msg" 0 80
		return 0
	elif [ "$hash_state" = "OK" ] && [ "$signing_key_state" != "DONGLE MATCHES ROM-TRUSTED KEY" ]; then
		# /boot is intact but no private key - direct path is OEM Factory Reset / Re-Ownership
		while true; do
			whiptail_type "$BG_COLOR_MAIN_MENU" --title 'Measured Integrity Report' \
				--menu "$msg" 0 80 2 \
				'o' ' OEM Factory Reset / Re-Ownership -->' \
				'c' ' Continue to main menu' \
				2>/tmp/whiptail || return 0
			report_option=$(cat /tmp/whiptail)
			case "$report_option" in
			o)
				INTEGRITY_REPORT_ALREADY_SHOWN=1 oem-factory-reset.sh
				return 0
				;;
			c | *)
				return 0
				;;
			esac
		done
	fi

	if [ "$signing_key_state" = "DONGLE KEY NOT ROM-TRUSTED" ]; then
		while true; do
			whiptail_type $BG_COLOR_MAIN_MENU --title 'Measured Integrity Report' \
				--menu "$menu_msg" 0 80 4 \
				'i' ' Investigate discrepancies -->' \
				'r' ' Replace GPG key in current ROM and reflash' \
				'o' ' OEM Factory Reset / Re-Ownership' \
				'c' ' Continue' \
				2>/tmp/whiptail || return 0
			report_option=$(cat /tmp/whiptail)
			case "$report_option" in
			i)
				if investigate_integrity_discrepancies; then
					report_integrity_measurements
					return
				fi
				;;
			r)
				gpg_replace_key_reflash
				;;
			o)
				INTEGRITY_REPORT_ALREADY_SHOWN=1 oem-factory-reset.sh
				return 0
				;;
			*)
				return 0
				;;
			esac
		done
	else
		while true; do
			whiptail_type $BG_COLOR_MAIN_MENU --title 'Measured Integrity Report' \
				--menu "$menu_msg" 0 80 2 \
				'i' ' Investigate discrepancies -->' \
				'c' ' Continue' \
				2>/tmp/whiptail || return 0
			report_option=$(cat /tmp/whiptail)
			case "$report_option" in
			i)
				if investigate_integrity_discrepancies; then
					report_integrity_measurements
					return
				fi
				;;
			*)
				return 0
				;;
			esac
		done
	fi
}

investigate_integrity_discrepancies() {
	TRACE_FUNC
	local changed_files changed_count details sig_details sig_status
	local sig_trust_state investigation_option inv_msg

	# Signature trust must be established first. If detached signature is not
	# trusted, checksum success must not be treated as clean integrity.
	sig_trust_state="untrusted"
	if detached_kexec_signature_valid /boot; then
		sig_trust_state="trusted"
	fi
	DEBUG "investigate_integrity_discrepancies: signature trust state=$sig_trust_state"

	if [ "$sig_trust_state" = "trusted" ]; then
		check_config /boot force
		TMP_HASH_FILE="/tmp/kexec/kexec_hashes.txt"
		TMP_TREE_FILE="/tmp/kexec/kexec_tree.txt"
		if verify_checksums /boot y; then
			DEBUG "investigate_integrity_discrepancies: detached signature verified and verify_checksums returned success"
			whiptail_type $BG_COLOR_MAIN_MENU --title 'Integrity Investigation' \
				--msgbox 'No integrity discrepancies are currently detected for /boot.' 0 80
			return 0
		fi
		DEBUG "investigate_integrity_discrepancies: detached signature verified but verify_checksums reported discrepancies"
	else
		DEBUG "investigate_integrity_discrepancies: detached signature not trusted; treating /boot as untrusted regardless of checksum output"
	fi

	if [ "$sig_trust_state" = "trusted" ]; then
		changed_files=$(grep -v 'OK$' /tmp/hash_output 2>/dev/null | cut -f1 -d ':' | sed '/^$/d')
		if [ -z "$changed_files" ] && [ -r /tmp/hash_output ]; then
			changed_files=$(sed '/^$/d' /tmp/hash_output)
		fi
		DEBUG "investigate_integrity_discrepancies: raw changed_files list=$changed_files"
	else
		if [ ! -r /boot/kexec.sig ]; then
			sig_details="Signature file is missing"
		else
			sig_status="$(detached_kexec_signature_failure_status /boot)"
			sig_details="$(detached_kexec_signature_failure_detail_one_line)"
			[ -n "$sig_details" ] || sig_details="Signature verification failed"
			case "$sig_status" in
			MALFORMED)
				sig_details="Signature file is damaged or not a valid signature (${sig_details})"
				;;
			BAD)
				sig_details="Signature does not match current /boot files (${sig_details})"
				;;
			UNKNOWN_KEY)
				sig_details="Signature uses a key this firmware does not trust (${sig_details})"
				;;
			*)
				sig_details="Signature verification failed (${sig_details})"
				;;
			esac
		fi
		changed_files="Signature problem: $sig_details"
		DEBUG "investigate_integrity_discrepancies: signature issue details=$sig_details"
	fi

	if [ -z "$changed_files" ]; then
		whiptail_error --title 'Integrity Investigation' \
			--msgbox 'Integrity is not OK, but no detailed mismatch list is available.' 0 80
		return 1
	fi

	# details remains relative; user is told paths are under /boot
	details=$(printf '%s\n' "$changed_files" | sort -u)
	changed_count=$(printf '%s\n' "$details" | wc -l | tr -d ' ')
	DEBUG "integrity: changed_count=$changed_count"
	DEBUG "integrity: details=$details"

	if [ "$sig_trust_state" = "trusted" ]; then
		inv_msg="Integrity mismatches were detected.\n\nDetached signature on /boot/kexec.sig verified successfully.\n\nChoose an action:"
	else
		inv_msg="Integrity mismatches were detected.\n\nDetached signature on /boot/kexec.sig could not be verified.\n\nTreat /boot as untrusted unless you explicitly expected these changes.\n\nChoose an action:"
	fi

	while true; do
		whiptail_error --title 'Integrity Investigation' \
			--menu "$inv_msg" 0 80 5 \
			'd' ' Show mismatch details -->' \
			's' ' Show detached signed output -->' \
			'u' ' Update checksums now' \
			'r' ' Drop to recovery shell (view discrepancies)' \
			'c' ' Continue' \
			2>/tmp/whiptail || return 1

		investigation_option=$(cat /tmp/whiptail)
		case "$investigation_option" in
		s)
			show_detached_signed_kexec_output
			;;
		d)
			if [ "$changed_count" -gt 12 ]; then
				printf '%s\n' "$details" >/tmp/hash_output_mismatches
				echo 'Type "q" to exit the list and return.' >>/tmp/hash_output_mismatches
				whiptail_error --title 'Integrity Investigation' \
					--msgbox "${changed_count} discrepancy entries found.\n\nPress OK to review the full list." 0 80
				less /tmp/hash_output_mismatches
			else
				whiptail_error --title 'Integrity Investigation' \
					--msgbox "Discrepancy entries detected:\n\n${details}" 0 80
			fi
			;;
		r)
			local msg
			msg=$'Integrity discrepancies detected (paths are under /boot):\n\n'"${details}"$'\n\nTo investigate:\n 1. remount /boot read-write:\n    mount -o rw,remount /boot\n 2. edit files with vi (use :wq to save and exit) and save your changes\n 3. unsafe boot is still possible via the '"${CONFIG_BRAND_NAME}"$' menu: Options -> Boot Options -> Ignore tampering and force a boot\n    while /boot remains untrusted\n 4. run reboot when done; '"${CONFIG_BRAND_NAME}"$' will re-audit on next boot\n\nBe cautious. If unsure, reinstall and restore from backups.'
			recovery "$msg"
			;;
		u)
			# "Update checksums now" from the integrity investigation
			# whiptail menu.  If update_checksums set tpm_reset_required
			# (e.g. check_tpm_counter hit "out of resources"),
			# return 1 to exit the investigation loop and return to
			# the main menu instead of looping back here.
			prompt_update_checksums && return 0
			if tpm_reset_required; then
				return 1
			fi
			;;
		*)
			return 0
			;;
		esac
	done
}

detached_kexec_signature_valid() {
	TRACE_FUNC
	local boot_dir="$1"

	[ -n "$boot_dir" ] || boot_dir="/boot"
	boot_dir="${boot_dir%%/}"

	if [ "$CONFIG_BASIC" = "y" ]; then
		return 1
	fi

	if [ ! -r "$boot_dir/kexec.sig" ]; then
		DEBUG "detached_kexec_signature_valid: no $boot_dir/kexec.sig"
		return 1
	fi

	# Collect full paths once; derive relative names via ##*/ where needed.
	local kexec_txt_files=()
	for f in "$boot_dir"/kexec*.txt; do
		[ -e "$f" ] || continue
		kexec_txt_files+=("$f")
	done
	if [ ${#kexec_txt_files[@]} -eq 0 ]; then
		DEBUG "detached_kexec_signature_valid: no kexec*.txt files found under $boot_dir"
		return 1
	fi
	DEBUG "detached_kexec_signature_valid: ${#kexec_txt_files[@]} file(s) in $boot_dir: ${kexec_txt_files[*]##*/}"

	# Try relative filenames first (cd into boot_dir) to match the signing
	# path format used by this branch's kexec-sign-config.sh (staging dir + relative names).
	STATUS "Verifying /boot detached signature"
	DEBUG "detached_kexec_signature_valid: running (cd $boot_dir && sha256sum ${kexec_txt_files[*]##*/}) | gpgv.sh $boot_dir/kexec.sig"
	if (cd "$boot_dir" && sha256sum "${kexec_txt_files[@]##*/}") |
		gpgv.sh "$boot_dir/kexec.sig" - >/tmp/integrity_sigcheck 2>&1; then
		DEBUG "detached_kexec_signature_valid: signature valid (relative paths)"
		mkdir -p /tmp/kexec
		cp "$boot_dir"/kexec*.txt /tmp/kexec 2>/dev/null || true
		return 0
	fi
	DEBUG "detached_kexec_signature_valid: relative-path check failed; retrying with full paths (legacy format)"
	DEBUG "$(sed -n '1,20p' /tmp/integrity_sigcheck)"

	# Backwards compatibility: the previous kexec-sign-config.sh signed with full
	# paths (sha256sum /boot/kexec*.txt), not relative paths.  A firmware upgrade
	# must not invalidate an existing valid signature.
	DEBUG "detached_kexec_signature_valid: running sha256sum ${kexec_txt_files[*]} | gpgv.sh $boot_dir/kexec.sig"
	if sha256sum "${kexec_txt_files[@]}" |
		gpgv.sh "$boot_dir/kexec.sig" - >/tmp/integrity_sigcheck 2>&1; then
		DEBUG "detached_kexec_signature_valid: signature valid (full paths, legacy format)"
		mkdir -p /tmp/kexec
		cp "$boot_dir"/kexec*.txt /tmp/kexec 2>/dev/null || true
		return 0
	fi
	DEBUG "detached_kexec_signature_valid: both relative and full-path checks failed"
	DEBUG "$(sed -n '1,20p' /tmp/integrity_sigcheck)"
	return 1
}

detached_kexec_signature_failure_status() {
	TRACE_FUNC
	local boot_dir="$1"

	[ -n "$boot_dir" ] || boot_dir="/boot"
	if [ ! -r "$boot_dir/kexec.sig" ]; then
		echo "MISSING"
		return 0
	fi

	if grep -Eiq 'no valid openpgp data found' /tmp/integrity_sigcheck 2>/dev/null; then
		echo "MALFORMED"
		return 0
	fi
	if grep -Eiq 'bad signature' /tmp/integrity_sigcheck 2>/dev/null; then
		echo "BAD"
		return 0
	fi
	if grep -Eiq 'no public key|can.t check signature: no public key' /tmp/integrity_sigcheck 2>/dev/null; then
		echo "UNKNOWN_KEY"
		return 0
	fi

	echo "INVALID"
}

detached_kexec_signature_failure_detail_one_line() {
	TRACE_FUNC
	local line

	if [ ! -r /boot/kexec.sig ]; then
		echo "/boot/kexec.sig is missing"
		return 0
	fi

	line="$(grep -Eim1 'no valid openpgp data found|bad signature|no public key|can.t check signature' /tmp/integrity_sigcheck 2>/dev/null)"
	if [ -z "$line" ]; then
		line="$(sed -n '1p' /tmp/integrity_sigcheck 2>/dev/null)"
	fi

	echo "$line" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

detached_kexec_signature_signer_info() {
	# Parse gpgv output in /tmp/integrity_sigcheck to extract signer key fingerprint
	# and signing date. Returns empty string if not parseable.
	# gpgv output for unknown key:
	#   gpgv: Signature made Wed Mar 11 19:53:41 2026 UTC
	#   gpgv:                using RSA key 8E2364E3F305AACEDFFBB61C03E3D64DDA3E571B
	#   gpgv: Can't check signature: No public key
	local date_str key_id
	date_str="$(grep -im1 'signature made' /tmp/integrity_sigcheck 2>/dev/null |
		sed 's/.*[Ss]ignature made[[:space:]]*//' |
		sed 's/[[:space:]]*$//')"
	key_id="$(grep -im1 'using .* key' /tmp/integrity_sigcheck 2>/dev/null |
		sed 's/.*using [A-Za-z0-9]* key[[:space:]]*//' |
		sed 's/[[:space:]]*$//')"
	if [ -n "$key_id" ] && [ -n "$date_str" ]; then
		echo "fingerprint $key_id, signed on $date_str, owner unknown (key not in firmware keyring)"
	elif [ -n "$key_id" ]; then
		echo "fingerprint $key_id, date unknown, owner unknown (key not in firmware keyring)"
	fi
}

show_detached_signed_kexec_output() {
	TRACE_FUNC
	local signed_files signed_count

	signed_files=$(find /tmp/kexec/kexec*.txt 2>/dev/null | sort)
	if [ -z "$signed_files" ]; then
		whiptail_error --title 'Signed Output' \
			--msgbox 'No verified detached signed output is available to display.' 0 80
		return 1
	fi

	: >/tmp/integrity_signed_output
	for signed_file in $signed_files; do
		echo "===== $(basename "$signed_file") =====" >>/tmp/integrity_signed_output
		cat "$signed_file" >>/tmp/integrity_signed_output
		echo >>/tmp/integrity_signed_output
	done

	signed_count=$(wc -l </tmp/integrity_signed_output)
	if [ "$signed_count" -gt 20 ]; then
		echo 'Type "q" to exit the list and return.' >>/tmp/integrity_signed_output
		less /tmp/integrity_signed_output
	else
		whiptail_type $BG_COLOR_MAIN_MENU --title 'Signed Output' \
			--msgbox "$(cat /tmp/integrity_signed_output)" 0 80
	fi
}

# Get "Enable" or "Disable" to display in the configuration menu, based on a
# setting value
get_config_display_action() {
	TRACE_FUNC
	[ "$1" = "y" ] && echo "Disable" || echo "Enable"
}

# Invert a config value
invert_config() {
	TRACE_FUNC
	[ "$1" = "y" ] && echo "n" || echo "y"
}

# Get "Enable" or "Disable" for a config that internally is inverted (because it
# disables a behavior that is on by default).
get_inverted_config_display_action() {
	TRACE_FUNC
	get_config_display_action "$(invert_config "$1")"
}

# Verify all file hashes in /boot, interactively handle mismatches.
# Defined here so kexec-select-boot.sh (which sources gui_functions.sh)
# can call it without requiring gui-init.sh to be in scope.
# Returns 0 on success (hashes match, or user updated them), 1 on failure.
# Sets valid_hash='y' and valid_global_hash='y' on success for callers
# that check those variables (kexec-select-boot.sh:596).
# Dependencies: TRACE_FUNC, check_config, verify_checksums, update_checksums
# (functions.sh), whiptail_error, investigate_integrity_discrepancies
# (gui_functions.sh), BG_COLOR_MAIN_MENU (exported from gui-init.sh).
verify_global_hashes() {
	TRACE_FUNC
	#
	# Two call contexts, with different check_config semantics:
	#
	# Context A — gui-init.sh (attempt_default_boot / select_os_boot_option)
	#   /tmp/kexec/ is empty.  We call check_config /boot force here to
	#   populate it.  Because the caller is the GUI menu (not a verified
	#   boot path), we always pass "force" which copies the kexec files
	#   from /boot without verifying the GPG detached signature on them.
	#   The hash check STATUS will say
	#   "Verifying boot file checksums" (no "against signed boot hashes").
	#
	# Context B — kexec-select-boot.sh's main loop
	#   The main loop already called check_config $paramsdir (which
	#   verifies the GPG signature on the kexec*.txt files) before
	#   calling this function.  /tmp/kexec/ is already populated.
	#   Skipping check_config here avoids the destructive rm -rf
	#   /tmp/kexec/* + re-copy (which, if /boot/kexec.sig is absent,
	#   would leave /tmp/kexec/ empty and break the caller).
	#
	#   Whether GPG was actually verified is determined by the
	#   presence of /tmp/kexec/.gpg_verified — a marker file that
	#   check_config creates after a successful signature verification
	#   (and its own rm -rf /tmp/kexec/* step cleans up on the next
	#   call).  When present, the STATUS says
	#   "Verifying boot file checksums against signed boot hashes".
	#
	# Both files (kexec_hashes.txt and kexec_tree.txt) are required
	# before skipping check_config.  If only one is present (e.g. a
	# partial copy from a failed run), check_config will repopulate.
	#
	if [ ! -r /tmp/kexec/kexec_hashes.txt -o ! -r /tmp/kexec/kexec_tree.txt ]; then
		check_config /boot force
	fi
	TMP_HASH_FILE="/tmp/kexec/kexec_hashes.txt"
	TMP_TREE_FILE="/tmp/kexec/kexec_tree.txt"
	TMP_PACKAGE_TRIGGER_PRE="/tmp/kexec/kexec_package_trigger_pre.txt"
	TMP_PACKAGE_TRIGGER_POST="/tmp/kexec/kexec_package_trigger_post.txt"

	if [ -r /tmp/kexec/.gpg_verified ]; then
		STATUS "Verifying boot file checksums against signed boot hashes"
	else
		STATUS "Verifying boot file checksums"
	fi
	DEBUG "verify_global_hashes: checking /boot files against $TMP_HASH_FILE"
	if verify_checksums /boot; then
		DEBUG "verify_global_hashes: /boot files match checksums in $TMP_HASH_FILE"
		valid_hash="y"
		valid_global_hash="y"
		# If user enables it, check root hashes before boot as well
		if [[ "$CONFIG_ROOT_CHECK_AT_BOOT" = "y" && "$force_menu" == "n" ]]; then
			DEBUG "verify_global_hashes: checking root hashes"
			if root-hashes-gui.sh -c; then
				if [ -r /tmp/kexec/.gpg_verified ]; then
					STATUS_OK "Boot file and root checksums verified against signed boot hashes"
				else
					STATUS_OK "Boot file and root checksums verified"
				fi
			else
				# root-hashes-gui.sh handles the GUI error menu, just DIE here
				if [ "$gui_menu" = "y" ]; then
					whiptail_error --title 'ERROR: Root Hash Mismatch' \
						--msgbox "The root hash check failed!\nExiting to a recovery shell" 0 80
				fi
				DIE "root hash mismatch, see /tmp/hash_output_mismatches for details"
			fi
		else
			if [ -r /tmp/kexec/.gpg_verified ]; then
				STATUS_OK "Boot file checksums verified against signed boot hashes"
			else
				STATUS_OK "Boot file checksums verified"
			fi
		fi
		return 0
	elif [[ ! -f "$TMP_HASH_FILE" || ! -f "$TMP_TREE_FILE" ]]; then
		DEBUG "verify_global_hashes: missing hash or tree file"
		if (whiptail_error --title 'ERROR: Missing File!' \
			--yesno "One of the files containing integrity information for /boot is missing!\n\nIf you are setting up heads for the first time or upgrading from an older version, select Yes to create the missing files.\n\nOtherwise this could indicate a compromise and you should select No to return to the main menu.\n\nWould you like to create the missing files now?" 0 80); then
			if update_checksums; then
				BG_COLOR_MAIN_MENU="normal"
				return 0
			else
				whiptail_error --title 'ERROR' \
					--msgbox "Failed to update checksums / sign default config" 0 80
			fi
		fi
		BG_COLOR_MAIN_MENU="error"
		return 1
	else
		DEBUG "verify_global_hashes: hash mismatch, checking changed files"
		CHANGED_FILES=$(grep -v 'OK$' /tmp/hash_output | cut -f1 -d ':' | tee -a /tmp/hash_output_mismatches)
		CHANGED_FILES_COUNT=$(wc -l /tmp/hash_output_mismatches | cut -f1 -d ' ')
		DEBUG "verify_global_hashes: changed_files_count=$CHANGED_FILES_COUNT"

		# if files changed before package manager started, show stern warning
		if [ -f "$TMP_PACKAGE_TRIGGER_PRE" ]; then
			DEBUG "verify_global_hashes: PRE trigger found"
			PRE_CHANGED_FILES=$(grep '^CHANGED_FILES' "$TMP_PACKAGE_TRIGGER_POST" | cut -f 2 -d '=' | tr -d '"')
			TEXT="The following files failed the verification process BEFORE package updates ran:\n${PRE_CHANGED_FILES}\n\nCompare against the files $CONFIG_BRAND_NAME has detected have changed:\n${CHANGED_FILES}\n\nThis could indicate a compromise!\n\nWould you like to update your checksums anyway?"

		# if files changed after package manager started, probably caused by package manager
		elif [ -f "$TMP_PACKAGE_TRIGGER_POST" ]; then
			DEBUG "verify_global_hashes: POST trigger found"
			LAST_PACKAGE_LIST=$(grep -E "^(Install|Remove|Upgrade|Reinstall):" "$TMP_PACKAGE_TRIGGER_POST")
			UPDATE_INITRAMFS_PACKAGE=$(grep '^UPDATE_INITRAMFS_PACKAGE' "$TMP_PACKAGE_TRIGGER_POST" | cut -f 2 -d '=' | tr -d '"')

			if [ "$UPDATE_INITRAMFS_PACKAGE" != "" ]; then
				TEXT="The following files failed the verification process AFTER package updates ran:\n${CHANGED_FILES}\n\nThis is likely due to package triggers in$UPDATE_INITRAMFS_PACKAGE.\n\nYou will need to update your checksums for all files in /boot.\n\nWould you like to update your checksums now?"
			else
				TEXT="The following files failed the verification process AFTER package updates ran:\n${CHANGED_FILES}\n\nThis might be due to the following package updates:\n$LAST_PACKAGE_LIST.\n\nYou will need to update your checksums for all files in /boot.\n\nWould you like to update your checksums now?"
			fi

		else
			if [ $CHANGED_FILES_COUNT -gt 10 ]; then
				DEBUG "verify_global_hashes: no triggers, >10 changed files"
				# drop to console to show full file list
				whiptail_error --title 'ERROR: Boot Hash Mismatch' \
					--msgbox "${CHANGED_FILES_COUNT} files failed the verification process!\\n\nThis could indicate a compromise!\n\nHit OK to review the list of files.\n\nType \"q\" to exit the list and return." 0 80

				echo "Type \"q\" to exit the list and return." >>/tmp/hash_output_mismatches
				less /tmp/hash_output_mismatches
				#move outdated hash mismatch list
				mv /tmp/hash_output_mismatches /tmp/hash_output_mismatch_old
				TEXT="${CHANGED_FILES_COUNT} files failed the verification process.\n\nThis could indicate a compromise!\n\nWould you like to investigate discrepancies or update your checksums now?"
			else
				DEBUG "verify_global_hashes: no triggers, <=10 changed files"
				TEXT="The following files failed the verification process:\n\n${CHANGED_FILES}\n\nThis could indicate a compromise!\n\nWould you like to investigate discrepancies or update your checksums now?"
			fi
		fi

		local menu_text
		menu_text="$TEXT"
		DEBUG "verify_global_hashes: entering whiptail menu loop"
		while true; do
			TRACE_FUNC
			DEBUG "verify_global_hashes: showing whiptail menu"
			whiptail_error --title 'ERROR: Boot Hash Mismatch' \
				--menu "$menu_text\n\nChoose an action:" 0 80 3 \
				'i' ' Investigate discrepancies -->' \
				'u' ' Update checksums now' \
				'm' ' Return to main menu' \
				2>/tmp/whiptail || {
				DEBUG "verify_global_hashes: whiptail menu failed/returned non-zero"
				BG_COLOR_MAIN_MENU="error"
				return 1
			}

			option=$(cat /tmp/whiptail)
			DEBUG "verify_global_hashes: user chose '$option'"
			case "$option" in
			i)
				DEBUG "verify_global_hashes: investigating discrepancies"
				investigate_integrity_discrepancies
				;;
			u)
				DEBUG "verify_global_hashes: updating checksums"
				if update_checksums; then
					BG_COLOR_MAIN_MENU="normal"
					return 0
				else
					whiptail_error --title 'ERROR' \
						--msgbox "Failed to update checksums / sign default config" 0 80
				fi
				;;
			m | *)
				DEBUG "verify_global_hashes: returning to main menu"
				BG_COLOR_MAIN_MENU="error"
				return 1
				;;
			esac
		done
	fi
}
