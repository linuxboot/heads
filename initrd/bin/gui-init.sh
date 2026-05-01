#!/bin/bash
# Boot from a local disk installation

BOARD_NAME=${CONFIG_BOARD_NAME:-${CONFIG_BOARD}}
MAIN_MENU_TITLE="${BOARD_NAME} | $CONFIG_BRAND_NAME Boot Menu"
export BG_COLOR_MAIN_MENU="normal"

. /etc/functions.sh
. /etc/gui_functions.sh
. /etc/luks-functions.sh
. /tmp/config

# Detect the terminal this gui-init session is running on.  The user
# interacting with gui-init (via whiptail) is the source of truth for the
# "active" terminal — prompts, GPG/pinentry, and input all go to/from there.
# $(tty) works here because cttyhack (exec'd by /init) has already replaced
# fd0/1/2 with the correct console device before launching this script.
# Fall back to /sys/class/tty/console/active (last entry = preferred console,
# same source used by systemd and busybox cttyhack) when tty is unavailable.
detect_heads_tty

# skip_to_menu is set if the user selects "continue to the main menu" from any
# error, so we will indeed go to the main menu even if other errors occur.  It's
# reset when we reach the main menu so the user can retry from the main menu and
# # see errors again.
skip_to_menu="false"
INTEGRITY_GATE_REQUIRED="n"

mount_boot() {
	TRACE_FUNC
	# Mount local disk if it is not already mounted
	while ! grep -q /boot /proc/mounts; do
		# try to mount if CONFIG_BOOT_DEV exists
		if [ -e "$CONFIG_BOOT_DEV" ]; then
			if mount -o ro "$CONFIG_BOOT_DEV" /boot; then
				continue
			fi
		fi

		# CONFIG_BOOT_DEV doesn't exist or couldn't be mounted, so give user options.
		# LUKS_PARTITION_DETECTED is set by detect_boot_device (via mount_possible_boot_device)
		# when it skips a LUKS partition -- reuse that result to distinguish
		# "OS installed without separate /boot" from "no OS found at all".
		BG_COLOR_MAIN_MENU="error"
		local boot_msg
		if [ "${LUKS_PARTITION_DETECTED:-n}" = "y" ]; then
			boot_msg="An encrypted OS was detected but no separate /boot partition was found.\n\n$CONFIG_BRAND_NAME requires a separate, unencrypted /boot partition.\n\nMost OS installers do not create this layout by default. Only DVD/live\nISOs that detect legacy boot (BIOS/CSM mode) will offer the correct\npartition scheme. Use 'Boot from USB' to boot a live ISO and reinstall\nyour OS with a separate /boot partition.\n\nHow would you like to proceed?"
		else
			boot_msg="No bootable OS was found on any disk.\n\n$CONFIG_BRAND_NAME requires a separate, unencrypted /boot partition\ncontaining grub configuration files.\n\nIf you are installing an OS for the first time, use 'Boot from USB' to\nboot a live ISO. Only DVD/live ISOs that detect legacy boot (BIOS/CSM)\nwill offer the correct partition scheme with a separate /boot.\n\nHow would you like to proceed?"
		fi
		whiptail_error --title "ERROR: No /boot Partition Found" \
			--menu "$boot_msg" 0 80 4 \
			'u' ' Boot from USB' \
			'b' ' Select a new boot device' \
			'm' ' Continue to the main menu' \
			'x' ' Exit to recovery shell' \
			2>/tmp/whiptail || recovery "GUI menu failed"

		option=$(cat /tmp/whiptail)
		case "$option" in
		u)
			exec /bin/usb-init.sh
			;;
		b)
			if config-gui.sh boot_device_select; then
				# update CONFIG_BOOT_DEV
				# shellcheck source=/dev/null
				. /tmp/config
				BG_COLOR_MAIN_MENU="normal"
			fi
			;;
		m)
			skip_to_menu="true"
			break
			;;
		*)
			recovery "User requested recovery shell"
			;;
		esac
	done
}

verify_global_hashes() {
	TRACE_FUNC
	# Check the hashes of all the files, ignoring signatures for now
	check_config /boot force
	TMP_HASH_FILE="/tmp/kexec/kexec_hashes.txt"
	TMP_TREE_FILE="/tmp/kexec/kexec_tree.txt"
	TMP_PACKAGE_TRIGGER_PRE="/tmp/kexec/kexec_package_trigger_pre.txt"
	TMP_PACKAGE_TRIGGER_POST="/tmp/kexec/kexec_package_trigger_post.txt"

	if verify_checksums /boot; then
		return 0
	elif [[ ! -f "$TMP_HASH_FILE" || ! -f "$TMP_TREE_FILE" ]]; then
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
		CHANGED_FILES=$(grep -v 'OK$' /tmp/hash_output | cut -f1 -d ':' | tee -a /tmp/hash_output_mismatches)
		CHANGED_FILES_COUNT=$(wc -l /tmp/hash_output_mismatches | cut -f1 -d ' ')

		# if files changed before package manager started, show stern warning
		if [ -f "$TMP_PACKAGE_TRIGGER_PRE" ]; then
			PRE_CHANGED_FILES=$(grep '^CHANGED_FILES' "$TMP_PACKAGE_TRIGGER_POST" | cut -f 2 -d '=' | tr -d '"')
			TEXT="The following files failed the verification process BEFORE package updates ran:\n${PRE_CHANGED_FILES}\n\nCompare against the files $CONFIG_BRAND_NAME has detected have changed:\n${CHANGED_FILES}\n\nThis could indicate a compromise!\n\nWould you like to update your checksums anyway?"

		# if files changed after package manager started, probably caused by package manager
		elif [ -f "$TMP_PACKAGE_TRIGGER_POST" ]; then
			LAST_PACKAGE_LIST=$(grep -E "^(Install|Remove|Upgrade|Reinstall):" "$TMP_PACKAGE_TRIGGER_POST")
			UPDATE_INITRAMFS_PACKAGE=$(grep '^UPDATE_INITRAMFS_PACKAGE' "$TMP_PACKAGE_TRIGGER_POST" | cut -f 2 -d '=' | tr -d '"')

			if [ "$UPDATE_INITRAMFS_PACKAGE" != "" ]; then
				TEXT="The following files failed the verification process AFTER package updates ran:\n${CHANGED_FILES}\n\nThis is likely due to package triggers in$UPDATE_INITRAMFS_PACKAGE.\n\nYou will need to update your checksums for all files in /boot.\n\nWould you like to update your checksums now?"
			else
				TEXT="The following files failed the verification process AFTER package updates ran:\n${CHANGED_FILES}\n\nThis might be due to the following package updates:\n$LAST_PACKAGE_LIST.\n\nYou will need to update your checksums for all files in /boot.\n\nWould you like to update your checksums now?"
			fi

		else
			if [ $CHANGED_FILES_COUNT -gt 10 ]; then
				# drop to console to show full file list
				whiptail_error --title 'ERROR: Boot Hash Mismatch' \
					--msgbox "${CHANGED_FILES_COUNT} files failed the verification process!\\n\nThis could indicate a compromise!\n\nHit OK to review the list of files.\n\nType \"q\" to exit the list and return." 0 80

				echo "Type \"q\" to exit the list and return." >>/tmp/hash_output_mismatches
				less /tmp/hash_output_mismatches
				#move outdated hash mismatch list
				mv /tmp/hash_output_mismatches /tmp/hash_output_mismatch_old
				TEXT="${CHANGED_FILES_COUNT} files failed the verification process.\n\nThis could indicate a compromise!\n\nWould you like to investigate discrepancies or update your checksums now?"
			else
				TEXT="The following files failed the verification process:\n\n${CHANGED_FILES}\n\nThis could indicate a compromise!\n\nWould you like to investigate discrepancies or update your checksums now?"
			fi
		fi

		local menu_text
		menu_text="$TEXT"
		while true; do
			TRACE_FUNC
			whiptail_error --title 'ERROR: Boot Hash Mismatch' \
				--menu "$menu_text\n\nChoose an action:" 0 80 3 \
				'i' ' Investigate discrepancies -->' \
				'u' ' Update checksums now' \
				'm' ' Return to main menu' \
				2>/tmp/whiptail || {
				BG_COLOR_MAIN_MENU="error"
				return 1
			}

			option=$(cat /tmp/whiptail)
			case "$option" in
			i)
				investigate_integrity_discrepancies
				;;
			u)
				if update_checksums; then
					BG_COLOR_MAIN_MENU="normal"
					return 0
				else
					whiptail_error --title 'ERROR' \
						--msgbox "Failed to update checksums / sign default config" 0 80
				fi
				;;
			m | *)
				BG_COLOR_MAIN_MENU="error"
				return 1
				;;
			esac
		done
	fi
}

prompt_update_checksums() {
	TRACE_FUNC
	# Signing /boot with -r increments the TPM rollback counter.  If the counter
	# is broken or absent (tpm_reset_required), the increment will fail and DIE.
	# The user must reset the TPM first; that flow re-creates the counter.
	if [ "$CONFIG_TPM" = "y" ] && tpm_reset_required; then
		whiptail_error --title 'TPM Reset Required' \
			--msgbox "Cannot sign /boot: TPM state is inconsistent.\n\nReset the TPM first (Options -> TPM/TOTP/HOTP Options -> Reset the TPM), then update checksums." 0 80
		return 1
	fi
	if (whiptail_warning --title 'Update Checksums and sign all files in /boot' \
		--yesno "You have chosen to update the checksums and sign all of the files in /boot.\n\nThis means that you trust that these files have not been tampered with.\n\nYou will need your GPG key available, and this change will modify your disk.\n\nDo you want to continue?" 0 80); then
		if update_checksums; then
			return 0
		else
			whiptail_error --title 'ERROR' \
				--msgbox "Failed to update checksums / sign default config" 0 80
			return 1
		fi
	fi
	return 1
}

gate_reseal_with_integrity_report() {
	TRACE_FUNC
	local token_ok="y"
	if tpm_reset_required; then
		debug_tpm_reset_required_state
		whiptail_error --title 'ERROR: TPM Reset Required' \
			--msgbox "TPM state is inconsistent for sealing/unsealing operations.\n\nReset the TPM first (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)." 0 80
		return 1
	fi

	if [ "$INTEGRITY_GATE_REQUIRED" != "y" ]; then
		DEBUG "Skipping integrity gate: no TOTP/HOTP failure context"
		return 0
	fi

	INTEGRITY_REPORT_HASH_STATE="UNKNOWN"
	report_integrity_measurements
	local report_rc=$?
	DEBUG "gate_reseal_with_integrity_report: report_integrity_measurements rc=$report_rc"
	DEBUG "gate_reseal_with_integrity_report: INTEGRITY_REPORT_HASH_STATE=$INTEGRITY_REPORT_HASH_STATE"
	if [ "$INTEGRITY_REPORT_HASH_STATE" != "OK" ]; then
		DEBUG "returned from integrity report, now running investigation"
		if ! investigate_integrity_discrepancies; then
			DEBUG "investigation indicated problem, aborting gate"
			return 1
		fi

		DEBUG "gate_reseal_with_integrity_report: about to verify detached signature"
		DEBUG "ls -l /boot/kexec.sig: $(ls -l /boot/kexec.sig 2>/dev/null || echo missing)"
		if ! detached_kexec_signature_valid /boot; then
			DEBUG "detached_kexec_signature_valid failed"
			local sig_fail_msg
			sig_fail_msg="Cannot proceed with sealing new secrets because /boot/kexec.sig could not be verified with your current keyring.\n\nTreat /boot as untrusted and recover ownership first."
			whiptail_error --title 'ERROR: Signature Verification Failed' \
				--msgbox "$sig_fail_msg" 0 80
			return 1
		fi
	else
		DEBUG "gate_reseal_with_integrity_report: integrity is OK, skipping investigation and detached signature verification"
	fi

	if [ -x /bin/hotp_verification ]; then
		token_ok="n"
		while [ "$token_ok" != "y" ]; do
			enable_usb
			# wait_for_gpg_card already called release_scdaemon on success,
			# starting the NK3 CCID teardown.  This safety call covers the
			# case where scdaemon was restarted between then and now.
			release_scdaemon
			DEBUG "gate_reseal_with_integrity_report: checking HOTP token presence"
			STATUS "Checking $DONGLE_BRAND presence before sealing"
			if hotp_verification info >/dev/null 2>&1; then
				STATUS_OK "$DONGLE_BRAND present and accessible"
				token_ok="y"
				break
			fi
			DEBUG "gate_reseal_with_integrity_report: HOTP token not accessible"
			if ! whiptail_warning --title "$DONGLE_BRAND Required" \
				--yes-button "Retry" --no-button "Abort" \
				--yesno "Your $DONGLE_BRAND must be present before sealing new secrets.\n\nInsert the dongle and choose Retry, or Abort." 0 80; then
				return 1
			fi
		done
	fi

	if ! whiptail_warning --title 'Integrity Gate Passed' \
		--yesno "Integrity checks completed.\n\nProceed with TOTP/HOTP reseal action?" 0 80; then
		return 1
	fi
	INTEGRITY_GATE_REQUIRED="n"
	return 0
}

generate_totp_hotp() {
	TRACE_FUNC
	tpm_owner_passphrase="$1" # May be empty, will prompt if needed and empty
	if [ "$CONFIG_TPM" = "y" ] && tpm_reset_required; then
		debug_tpm_reset_required_state
		whiptail_error --title 'ERROR: TPM Reset Required' \
			--msgbox "Cannot generate a new TPM-backed TOTP/HOTP secret while TPM state is inconsistent.\n\nReset the TPM first (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)." 0 80
		return 1
	fi
	if [ "$CONFIG_TPM" != "y" ] && [ -x /bin/hotp_verification ]; then
		# If we don't have a TPM, but we have a HOTP USB Security dongle
		TRACE_FUNC
		/bin/seal-hotpkey.sh ||
			DIE "Failed to generate HOTP secret"
	elif /bin/seal-totp.sh "$BOARD_NAME" "$tpm_owner_passphrase"; then
		if [ -x /bin/hotp_verification ]; then
			# If we have a TPM and a HOTP USB Security dongle
			if [ "$CONFIG_TOTP_SKIP_QRCODE" != y ]; then
				INPUT "Once you have scanned the QR code, press Enter to configure your $DONGLE_BRAND"
			fi
			TRACE_FUNC
			/bin/seal-hotpkey.sh || DIE "Failed to generate HOTP secret"
		else
			if [ "$CONFIG_TOTP_SKIP_QRCODE" != y ]; then
				INPUT "Once you have scanned the QR code, press Enter to continue"
			fi
		fi
		clear
	else
		# seal-totp.sh already printed an explanatory error (e.g. missing
		# primary handle) and guided the user to reset the TPM.  Don't add
		# confusing generic warnings here, just propagate failure.
		return 1
	fi
}

prompt_missing_gpg_key_action() {
	TRACE_FUNC
	local retry_label retry_msg
	if [ "$CONFIG_HAVE_GPG_KEY_BACKUP" = "y" ]; then
		retry_label=" Retry (insert $DONGLE_BRAND or backup USB drive)"
		retry_msg="Cannot sign /boot because no private GPG signing key is available ($DONGLE_BRAND not inserted, wiped, or key not set up).\n\nInsert your $DONGLE_BRAND or backup USB drive and retry.\n\nHow would you like to proceed?"
	else
		retry_label=" Retry (after connecting $DONGLE_BRAND)"
		retry_msg="Cannot sign /boot because no private GPG signing key is available ($DONGLE_BRAND not inserted, wiped, or key not set up).\n\nInsert your $DONGLE_BRAND and retry.\n\nHow would you like to proceed?"
	fi
	whiptail_error --title "ERROR: GPG signing key unavailable" \
		--menu "$retry_msg" 0 80 4 \
		'r' "$retry_label" \
		'F' ' OEM Factory Reset / Re-Ownership' \
		'm' ' Return to main menu' \
		'x' ' Exit to recovery shell' \
		2>/tmp/whiptail || recovery "GUI menu failed"

	option=$(cat /tmp/whiptail)
	case "$option" in
	r)
		return 0
		;;
	F)
		oem-factory-reset.sh
		;;
	x)
		recovery "User requested recovery shell"
		;;
	m | *)
		return 1
		;;
	esac
}

update_totp() {
	TRACE_FUNC
	# update the TOTP code
	date=$(date "+%Y-%m-%d %H:%M:%S %Z")
	tries=0
	if [ "$CONFIG_TPM" != "y" ]; then
		TOTP="NO TPM"
	else
		TOTP=$(HEADS_NONFATAL_UNSEAL=y unseal-totp.sh)
		if [ $? -ne 0 ]; then
			local totp_menu_text
			INTEGRITY_GATE_REQUIRED="y"
			BG_COLOR_MAIN_MENU="error"
			if [ "$skip_to_menu" = "true" ]; then
				return 1 # Already asked to skip to menu from a prior error
			fi

			DEBUG "TPM state at TOTP failure:"
			DEBUG "$(pcrs)"

			totp_menu_text=$(
				cat <<EOF
ERROR: $CONFIG_BRAND_NAME couldn't generate the TOTP code.

After OEM Factory Reset / Re-Ownership, this is expected on first boot
until you generate a new HOTP/TOTP secret.

If you have just completed a factory reset, or just reflashed your BIOS,
you should generate a new HOTP/TOTP secret.

If this is the first time the system has booted, you should reset the TPM
and set your own passphrase.

If you have not just reflashed your BIOS, THIS COULD INDICATE TAMPERING!

How would you like to proceed?
EOF
			)
			whiptail_error --title "ERROR: TOTP Generation Failed!" \
				--menu "$totp_menu_text" 0 80 4 \
				'g' ' Generate new HOTP/TOTP secret' \
				'p' ' Reset the TPM' \
				'i' ' Ignore error and continue to main menu' \
				'x' ' Exit to recovery shell' \
				2>/tmp/whiptail || recovery "GUI menu failed"

			option=$(cat /tmp/whiptail)
			case "$option" in
			g)
				if tpm_reset_required; then
					debug_tpm_reset_required_state
					whiptail_error --title 'ERROR: TPM Reset Required' \
						--msgbox "Cannot generate a new TPM-backed TOTP/HOTP secret while TPM state is inconsistent.\n\nReset the TPM first (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)." 0 80
					return 1
				elif gate_reseal_with_integrity_report && (whiptail_warning --title 'Generate new TOTP/HOTP secret' \
					--yesno "This will erase your old secret and replace it with a new one!\n\nDo you want to proceed?" 0 80); then
					if generate_totp_hotp; then
						update_totp || true
						BG_COLOR_MAIN_MENU="normal"
						reseal_tpm_disk_decryption_key || prompt_missing_gpg_key_action
					fi
				fi
				;;
			i)
				skip_to_menu="true"
				return 1
				;;
			p)
				if gate_reseal_with_integrity_report && reset_tpm && update_totp && BG_COLOR_MAIN_MENU="normal"; then
					reseal_tpm_disk_decryption_key || prompt_missing_gpg_key_action
				fi
				;;
			x)
				recovery "User requested recovery shell"
				;;
			esac
		else
			INTEGRITY_GATE_REQUIRED="n"
		fi
	fi
}

update_hotp() {
	TRACE_FUNC
	HOTP="Unverified"
	if [ ! -x /bin/hotp_verification ]; then
		HOTP='N/A'
		return
	fi

	local hotp_token_info hotp_exit attempt

	# Ensure dongle is present; capture info for PIN counter display
	STATUS "Checking $DONGLE_BRAND presence"
	if ! hotp_token_info="$(hotp_verification info)"; then
		if [ "$skip_to_menu" = "true" ]; then
			return 1 # Already asked to skip to menu from a prior error
		fi
		if ! whiptail_warning \
			--title "WARNING: Please Insert Your $DONGLE_BRAND" \
			--yes-button "Retry" --no-button "Skip" \
			--yesno "Your $DONGLE_BRAND was not detected.\n\nPlease insert your $DONGLE_BRAND" 0 80; then
			HOTP="Error checking code, Insert $DONGLE_BRAND and retry"
			BG_COLOR_MAIN_MENU="warning"
			return
		fi
		if ! hotp_token_info="$(hotp_verification info)"; then
			HOTP="Error checking code, Insert $DONGLE_BRAND and retry"
			BG_COLOR_MAIN_MENU="warning"
			return
		fi
	fi

	# Show dongle firmware version with color coding so users know when to upgrade
	hotpkey_fw_display "$hotp_token_info" "$DONGLE_BRAND"

	# Unseal HOTP secret from TPM once; if this fails don't proceed at all
	HOTP=$(HEADS_NONFATAL_UNSEAL=y unseal-hotp.sh)
	if [ -z "$HOTP" ]; then
		WARN "Unable to unseal HOTP secret from TPM"
		HOTP="Error checking code, Insert $DONGLE_BRAND and retry"
		BG_COLOR_MAIN_MENU="warning"
		return
	fi

	# Try HOTP check up to 3 times.
	# Retries handle transient USB/timing failures; a definitive code mismatch
	# (exit 4 or 7) breaks immediately since the same code won't verify again.
	# PIN retry count is shown only before a retry so normal boots stay silent.
	for attempt in 1 2 3; do
		# Don't output HOTP codes to screen, so as to make replay attacks harder
		STATUS "Verifying HOTP code"
		hotp_verification check "$HOTP"
		hotp_exit=$?
		case "$hotp_exit" in
		0)
			HOTP="Success"
			BG_COLOR_MAIN_MENU="normal"
			STATUS_OK "HOTP code verified"
			return
			;;
		4 | 7) # 4: code incorrect, 7: not a valid HOTP code — no point retrying same code
			HOTP="Invalid code"
			BG_COLOR_MAIN_MENU="error"
			break
			;;
		6) # EXIT_SLOT_NOT_PROGRAMMED — sealing was never completed or failed mid-way
			HOTP="HOTP slot not configured"
			BG_COLOR_MAIN_MENU="warning"
			break
			;;
		*)
			# Transient error (USB glitch etc.) — retry if attempts remain
			if [ "$attempt" -lt 3 ]; then
				WARN "HOTP check failed (attempt $attempt/3), retrying"
			else
				HOTP="Error checking code, Insert $DONGLE_BRAND and retry"
				BG_COLOR_MAIN_MENU="warning"
			fi
			;;
		esac
	done

	if [[ "$HOTP" = "HOTP slot not configured" ]]; then
		WARN "$DONGLE_BRAND HOTP slot is not configured"
		STATUS "Verify TOTP against your phone to confirm TPM is intact, then press Escape to continue"
		show_totp_until_esc
		whiptail_warning --title "HOTP Not Configured" \
			--menu "The HOTP slot on your $DONGLE_BRAND is not configured.\n\nThis can happen if HOTP sealing was interrupted (connection error, dongle removed during setup).\n\nPlease generate a new TOTP/HOTP secret to configure it." 0 80 2 \
			'g' ' Generate new TOTP/HOTP secret' \
			'x' ' Exit to recovery shell' \
			2>/tmp/whiptail || recovery "GUI menu failed"

		option=$(cat /tmp/whiptail)
		case "$option" in
		g)
			if gate_reseal_with_integrity_report && (whiptail_warning --title 'Generate new TOTP/HOTP secret' \
				--yesno "This will erase your old secret and replace it with a new one!\n\nDo you want to proceed?" 0 80); then
				if generate_totp_hotp; then
					update_totp || true
					HOTP=$(HEADS_NONFATAL_UNSEAL=y unseal-hotp.sh)
					[ -n "$HOTP" ] && hotp_verification check "$HOTP" >/dev/null 2>&1 && HOTP="Success"
					BG_COLOR_MAIN_MENU="normal"
					reseal_tpm_disk_decryption_key || prompt_missing_gpg_key_action
				fi
			fi
			;;
		x)
			recovery "User requested recovery shell"
			;;
		esac
		return
	elif [[ "$HOTP" = "Invalid code" ]]; then
		INTEGRITY_GATE_REQUIRED="y"
		STATUS "HOTP failed - verify TOTP against your phone to confirm TPM integrity, then press Escape to continue"
		show_totp_until_esc
		local hotp_error_msg
		hotp_error_msg="ERROR: $CONFIG_BRAND_NAME couldn't validate the HOTP code.\n\nIf you just reflashed your BIOS, you should generate a new TOTP/HOTP secret.\n\nIf you have not just reflashed your BIOS, THIS COULD INDICATE TAMPERING!\n\nHow would you like to proceed?"
		whiptail_error --title "ERROR: HOTP Validation Failed!" \
			--menu "$hotp_error_msg" 0 80 3 \
			'g' ' Generate new TOTP/HOTP secret' \
			'i' ' Ignore error and continue to main menu' \
			'x' ' Exit to recovery shell' \
			2>/tmp/whiptail || recovery "GUI menu failed"

		option=$(cat /tmp/whiptail)
		case "$option" in
		g)
			if gate_reseal_with_integrity_report && (whiptail_warning --title 'Generate new TOTP/HOTP secret' \
				--yesno "This will erase your old secret and replace it with a new one!\n\nDo you want to proceed?" 0 80); then
				if generate_totp_hotp; then
					update_totp || true
					HOTP=$(HEADS_NONFATAL_UNSEAL=y unseal-hotp.sh)
					[ -n "$HOTP" ] && hotp_verification check "$HOTP" >/dev/null 2>&1 && HOTP="Success"
					BG_COLOR_MAIN_MENU="normal"
					reseal_tpm_disk_decryption_key || prompt_missing_gpg_key_action
				fi
			fi
			;;
		i)
			return 1
			;;
		x)
			recovery "User requested recovery shell"
			;;
		esac
	elif [[ "$HOTP" = "Error checking code"* ]]; then
		INTEGRITY_GATE_REQUIRED="y"
		STATUS "HOTP verification failed after 3 retries - verify TOTP against your phone to confirm TPM integrity, then press Escape to continue"
		show_totp_until_esc
		whiptail_warning --title "HOTP Verification Failed" \
			--menu "The $DONGLE_BRAND could not be verified after multiple attempts.\n\nThis may indicate a USB connection issue or dongle problem.\n\nPlease insert your $DONGLE_BRAND and try again, or verify TOTP to continue." 0 80 2 \
			'r' ' Retry HOTP verification' \
			'i' ' Ignore and continue to main menu' \
			2>/tmp/whiptail || recovery "GUI menu failed"
		option=$(cat /tmp/whiptail)
		case "$option" in
		r) update_hotp ;;
		i) INTEGRITY_GATE_REQUIRED="n" ;;
		esac
	else
		INTEGRITY_GATE_REQUIRED="n"
	fi
}

clean_boot_check() {
	TRACE_FUNC
	# assume /boot mounted
	if ! grep -q /boot /proc/mounts; then
		return
	fi

	# check for any kexec files in /boot
	kexec_files=$(find /boot -name kexec*.txt)
	[ ! -z "$kexec_files" ] && return

	#check for GPG key in keyring
	GPG_KEY_COUNT=$(gpg -k 2>/dev/null | wc -l)
	[ $GPG_KEY_COUNT -ne 0 ] && return

	# check for USB security token
	if [ -x /bin/hotp_verification ]; then
		if ! gpg --card-status >/dev/null; then
			return
		fi
	fi

	# OS is installed, no kexec files present, no GPG keys in keyring, security token present
	# prompt user to run OEM factory reset
	oem-factory-reset.sh \
		"Clean Boot Detected - Perform OEM Factory Reset / Re-Ownership?"
}

check_gpg_key() {
	TRACE_FUNC
	GPG_KEY_COUNT=$(gpg -k 2>/dev/null | wc -l)
	if [ $GPG_KEY_COUNT -eq 0 ]; then
		BG_COLOR_MAIN_MENU="error"
		if [ "$skip_to_menu" = "true" ]; then
			return 1 # Already asked to skip to menu from a prior error
		fi
		local gpg_error_msg
		gpg_error_msg="ERROR: $CONFIG_BRAND_NAME couldn't find any GPG keys in your keyring.\n\nIf this is the first time the system has booted, you should add a public GPG key to the BIOS now.\n\nIf you just reflashed a new BIOS, you'll need to add at least one public key to the keyring.\n\nIf you have not just reflashed your BIOS, THIS COULD INDICATE TAMPERING!\n\nHow would you like to proceed?"
		whiptail_error --title "ERROR: GPG keyring empty!" \
			--menu "$gpg_error_msg" 0 80 4 \
			'g' ' Add a GPG key to the running BIOS' \
			'F' ' OEM Factory Reset / Re-Ownership' \
			'i' ' Ignore error and continue to main menu' \
			'x' ' Exit to recovery shell' \
			2>/tmp/whiptail || recovery "GUI menu failed"

		option=$(cat /tmp/whiptail)
		case "$option" in
		g)
			gpg-gui.sh && BG_COLOR_MAIN_MENU="normal"
			;;
		i)
			skip_to_menu="true"
			return 1
			;;
		F)
			oem-factory-reset.sh
			;;

		x)
			recovery "User requested recovery shell"
			;;
		esac
	fi
}

prompt_auto_default_boot() {
	TRACE_FUNC
	if pause_automatic_boot; then
		STATUS "Attempting default boot"
		attempt_default_boot
	fi
}

show_main_menu() {
	TRACE_FUNC
	date=$(date "+%Y-%m-%d %H:%M:%S %Z")
	whiptail_type $BG_COLOR_MAIN_MENU --title "$MAIN_MENU_TITLE" \
		--menu "$date\nTOTP: $TOTP | HOTP: $HOTP" 0 80 10 \
		'd' ' Default boot' \
		'r' ' Refresh TOTP/HOTP' \
		'o' ' Options -->' \
		's' ' System Info' \
		'p' ' Power Off' \
		2>/tmp/whiptail || recovery "GUI menu failed"

	option=$(cat /tmp/whiptail)
	case "$option" in
	d)
		attempt_default_boot
		;;
	r)
		update_totp && update_hotp
		;;
	o)
		show_options_menu
		;;
	s)
		show_system_info
		;;
	p)
		poweroff.sh
		;;
	esac
}

show_options_menu() {
	TRACE_FUNC
	whiptail_type $BG_COLOR_MAIN_MENU --title "$CONFIG_BRAND_NAME Options" \
		--menu "" 0 80 10 \
		'b' ' Boot Options -->' \
		't' ' TPM/TOTP/HOTP Options -->' \
		'i' ' Investigate integrity discrepancies -->' \
		'h' ' Change system time' \
		'u' ' Update checksums and sign all files in /boot' \
		'c' ' Change configuration settings -->' \
		'f' ' Flash/Update the BIOS -->' \
		'g' ' GPG Options -->' \
		'F' ' OEM Factory Reset / Re-Ownership -->' \
		'C' ' Reencrypt LUKS container -->' \
		'P' ' Change LUKS Disk Recovery Key passphrase ->' \
		'R' ' Check/Update file hashes on root disk -->' \
		'x' ' Exit to recovery shell' \
		'r' ' <-- Return to main menu' \
		2>/tmp/whiptail || recovery "GUI menu failed"

	option=$(cat /tmp/whiptail)
	case "$option" in
	b)
		show_boot_options_menu
		;;
	t)
		show_tpm_totp_hotp_options_menu
		;;
	i)
		investigate_integrity_discrepancies
		;;
	h)
		change-time.sh
		;;
	u)
		prompt_update_checksums
		;;
	c)
		config-gui.sh
		;;
	f)
		flash-gui.sh
		;;
	g)
		gpg-gui.sh
		;;
	F)
		oem-factory-reset.sh
		;;
	C)
		luks_reencrypt
		luks_secrets_cleanup
		;;
	P)
		luks_change_passphrase
		luks_secrets_cleanup
		;;
	R)
		root-hashes-gui.sh
		;;
	x)
		recovery "User requested recovery shell"
		;;
	r) ;;
	esac
}

show_boot_options_menu() {
	TRACE_FUNC
	whiptail_type $BG_COLOR_MAIN_MENU --title "Boot Options" \
		--menu "Select A Boot Option" 0 80 10 \
		'm' ' Show OS boot menu' \
		'u' ' USB boot' \
		'i' ' Ignore tampering and force a boot (Unsafe!)' \
		'r' ' <-- Return to main menu' \
		2>/tmp/whiptail || recovery "GUI menu failed"

	option=$(cat /tmp/whiptail)
	case "$option" in
	m)
		# select a kernel from the menu
		select_os_boot_option
		;;
	u)
		exec /bin/usb-init.sh
		;;
	i)
		force_unsafe_boot
		;;
	r) ;;
	esac
}

show_tpm_totp_hotp_options_menu() {
	TRACE_FUNC
	whiptail_type $BG_COLOR_MAIN_MENU --title "TPM/TOTP/HOTP Options" \
		--menu "Select An Option" 0 80 10 \
		'g' ' Generate new TOTP/HOTP secret' \
		'r' ' Reset the TPM' \
		't' ' TOTP/HOTP does not match after refresh, troubleshoot' \
		'm' ' <-- Return to main menu' \
		2>/tmp/whiptail || recovery "GUI menu failed"

	option=$(cat /tmp/whiptail)
	case "$option" in
	g)
		if gate_reseal_with_integrity_report && generate_totp_hotp; then
			reseal_tpm_disk_decryption_key || prompt_missing_gpg_key_action
			# If reseal did not reboot (no LUKS devices), refresh display so
			# the user sees the new TOTP/HOTP state without a manual 'r'
			update_totp && update_hotp || true
		fi
		;;
	r)
		if gate_reseal_with_integrity_report && reset_tpm; then
			reseal_tpm_disk_decryption_key || prompt_missing_gpg_key_action
		fi
		;;
	t)
		prompt_totp_mismatch
		;;
	m) ;;
	esac
}

prompt_totp_mismatch() {
	TRACE_FUNC
	if (whiptail_warning --title "TOTP/HOTP code mismatched" \
		--yesno "TOTP/HOTP code mismatches could indicate TPM tampering or clock drift.\n\nThe current UTC time is: $(date "+%Y-%m-%d %H:%M:%S")\nIf this is incorrect, set the correct time and check TOTP/HOTP again.\n\nDo you want to change the time?" 0 80); then
		change-time.sh
	fi
}

reset_tpm() {
	TRACE_FUNC
	if [ "$CONFIG_TPM" = "y" ]; then
		if (whiptail_warning --title 'Reset the TPM' \
			--yesno "This will clear the TPM and replace its Owner passphrase with a new one!\n\nDo you want to proceed?" 0 80); then

			if ! prompt_new_owner_password; then
				INPUT "Press Enter to return to the menu..."
				return 1
			fi

			tpmr.sh reset "$tpm_owner_passphrase"

			# now that the TPM is reset, remove invalid TPM counter files
			mount_boot
			mount -o rw,remount /boot
			#TODO: this is really problematic, we should really remove the primary handle hash

			STATUS "Removing rollback and primary handle hashes under /boot"

			DEBUG "Removing /boot/kexec_rollback.txt and /boot/kexec_primhdl_hash.txt"
			rm -f /boot/kexec_rollback.txt
			rm -f /boot/kexec_primhdl_hash.txt

			# create Heads TPM counter before any others
			check_tpm_counter /boot/kexec_rollback.txt "" "$tpm_owner_passphrase" ||
				DIE "Unable to find/create tpm counter"

			TRACE_FUNC

			TPM_COUNTER=$(cut -d: -f1 </tmp/counter)
			DEBUG "TPM_COUNTER: $TPM_COUNTER"
			#TPM_COUNTER can be empty

			increment_tpm_counter "$TPM_COUNTER" "$tpm_owner_passphrase" || {
				WARN "Unable to increment tpm counter"
				return 1
			}

			DO_WITH_DEBUG sha256sum /tmp/counter-$TPM_COUNTER >/boot/kexec_rollback.txt ||
				DIE "Unable to create rollback file"

			TRACE_FUNC
			# As a countermeasure for existing primary handle hash, we will now force sign /boot without it.
			# NOTE: At seal time, PCR5 is IGNORED (not measured) - only used on HOTP board variants. So USB
			# modules loading here don't affect DUK seal. GPG card needs USB to be enabled first.
			enable_usb
			wait_for_gpg_card || true
			while true; do
				GPG_KEY_COUNT=$(gpg -K 2>/dev/null | wc -l)
				if [ "$GPG_KEY_COUNT" -eq 0 ]; then
					prompt_missing_gpg_key_action || return 1
					wait_for_gpg_card || true
				else
					if ! update_checksums; then
						whiptail_error --title 'ERROR' \
							--msgbox "Failed to update checksums / sign default config" 0 80
						return 1
					fi
					break
				fi
			done
			mount -o ro,remount /boot

			# Reset completed and reseal prerequisites were rebuilt.
			# Clear stale preflight marker before generating fresh TOTP/HOTP.
			clear_tpm_reset_required

			if ! generate_totp_hotp "$tpm_owner_passphrase"; then
				return 1
			fi

			if [ -s /boot/kexec_key_devices.txt ] || [ -s /boot/kexec_key_lvm.txt ]; then
				reseal_tpm_disk_decryption_key || prompt_missing_gpg_key_action
			fi
		fi
	fi
}

select_os_boot_option() {
	TRACE_FUNC
	mount_boot
	if verify_global_hashes; then
		DO_WITH_DEBUG kexec-select-boot.sh -m -b /boot -c "grub.cfg" -g
	fi
}

attempt_default_boot() {
	TRACE_FUNC
	mount_boot

	if ! verify_global_hashes; then
		return
	fi
	DEFAULT_FILE=$(find /boot/kexec_default.*.txt 2>/dev/null | head -1)
	if [ -r "$DEFAULT_FILE" ]; then
		TRACE_FUNC
		DO_WITH_DEBUG kexec-select-boot.sh -b /boot -c "grub.cfg" -g ||
			recovery "Failed default boot"
	elif (whiptail_warning --title 'No Default Boot Option Configured' \
		--yesno "There is no default boot option configured yet.\nWould you like to load a menu of boot options?\nOtherwise you will return to the main menu." 0 80); then
		TRACE_FUNC
		DO_WITH_DEBUG kexec-select-boot.sh -m -b /boot -c "grub.cfg" -g
	fi
}

force_unsafe_boot() {
	TRACE_FUNC
	if [ "$CONFIG_RESTRICTED_BOOT" = y ]; then
		whiptail_error --title 'ERROR: Restricted Boot Enabled' --msgbox "Restricted Boot is Enabled, forced boot not allowed.\n\nPress OK to return to the Main Menu" 0 80
		return
	fi
	# Run the menu selection in "force" mode, bypassing hash checks
	if (whiptail_warning --title 'Unsafe Forced Boot Selected!' \
		--yesno "WARNING: You have chosen to skip all tamper checks and boot anyway.\n\nThis is an unsafe option!\n\nDo you want to proceed?" 0 80); then
		mount_boot && kexec-select-boot.sh -m -b /boot -c "grub.cfg" -g -f
	fi
}

# gui-init start
TRACE_FUNC

if [ -x /bin/hotp_verification ]; then
	enable_usb
fi

# Detect dongle branding from USB VID:PID -- must run AFTER enable_usb so lsusb
# can see the dongle (NK3 enumerates ~1 second after USB module load).
detect_usb_security_dongle_branding

if detect_boot_device; then
	# /boot device with installed OS found
	clean_boot_check
else
	# can't determine /boot device or no OS installed,
	# so fall back to interactive selection
	mount_boot
fi

# Fail early on rollback-counter inconsistencies before presenting TOTP/HOTP
# recovery prompts. This avoids guiding users into reseal flows when TPM
# rollback state is already invalid.
rollback_preflight_failed="n"
if ! preflight_rollback_counter_before_reseal /boot/kexec_rollback.txt "" return; then
	rollback_preflight_failed="y"
	BG_COLOR_MAIN_MENU="error"
	preflight_error_msg="$(cat /tmp/rollback_preflight_error 2>/dev/null)"
	if [ -z "$preflight_error_msg" ]; then
		preflight_error_msg="TPM rollback counter state could not be validated."
	fi
	[ -n "$preflight_error_msg" ] && DEBUG "Rollback preflight failure: $preflight_error_msg"

	# Show the actual diagnostic directly so the user knows exactly why.
	# Strip the "Reset TPM from GUI..." action guidance that fail_preflight appends
	# since the menu already offers those actions.
	preflight_reason="${preflight_error_msg%%. Reset TPM from GUI*}"
	[ -z "$preflight_reason" ] && preflight_reason="TPM rollback counter state could not be validated."

	preflight_menu_text=$(
		cat <<EOF
Cannot verify TPM rollback protection.

$preflight_reason

Possible causes:
 - TPM was reset or replaced
 - /boot disk was swapped or restored
 - TPM state tampering occurred

WARNING: If none of the above were intentional, treat /boot as
UNTRUSTED. A disk or TPM swap attack cannot be ruled out.
Verify integrity before trusting any boot files.

Recommended first step:
 - Show integrity report (TOTP/HOTP + /boot)

Choose an action:
EOF
	)
	_preflight_report_shown="n"
	while [ "$rollback_preflight_failed" = "y" ]; do
		# After the user has seen the integrity report, drop the recommendation
		# and mark it shown so oem-factory-reset.sh skips it.
		if [ "$_preflight_report_shown" = "y" ]; then
			_menu_text=$(printf '%s' "$preflight_menu_text" | sed '/^Recommended first step:/,/^$/d')
		else
			_menu_text="$preflight_menu_text"
		fi
		whiptail_error --title 'ERROR: TPM State Inconsistent' \
			--menu "$_menu_text" 26 80 4 \
			'i' ' Show integrity report -->' \
			'o' ' OEM Factory Reset / Re-Ownership -->' \
			't' ' Reset the TPM' \
			'm' ' Continue to main menu' \
			2>/tmp/whiptail || recovery "GUI menu failed"

		option=$(cat /tmp/whiptail)
		case "$option" in
		i)
			report_integrity_measurements
			_preflight_report_shown="y"
			export INTEGRITY_REPORT_ALREADY_SHOWN=1
			;;
		o)
			INTEGRITY_REPORT_ALREADY_SHOWN=1 oem-factory-reset.sh
			if preflight_rollback_counter_before_reseal /boot/kexec_rollback.txt "" return; then
				rollback_preflight_failed="n"
				BG_COLOR_MAIN_MENU="normal"
			fi
			;;
		t)
			if reset_tpm && preflight_rollback_counter_before_reseal /boot/kexec_rollback.txt "" return; then
				rollback_preflight_failed="n"
				BG_COLOR_MAIN_MENU="normal"
			fi
			;;
		m | *)
			break
			;;
		esac
		if [ "$rollback_preflight_failed" = "y" ]; then
			preflight_error_msg="$(cat /tmp/rollback_preflight_error 2>/dev/null)"
			[ -n "$preflight_error_msg" ] && DEBUG "Rollback preflight failure: $preflight_error_msg"
		fi
	done
fi

# detect whether any GPG keys exist in the keyring, if not, initialize that first
if [ "$rollback_preflight_failed" != "y" ]; then
	check_gpg_key
	# Even if GPG init fails, still try to update TOTP/HOTP so the main menu can
	# show the correct status.
	update_totp && update_hotp

	if [ "$HOTP" = "Success" -a -n "$CONFIG_AUTO_BOOT_TIMEOUT" ]; then
		prompt_auto_default_boot
	fi
fi

while true; do
	TRACE_FUNC
	skip_to_menu="false"
	show_main_menu
done

recovery "Something failed during boot"
