#!/bin/bash

gpg_flash_rom() {
	if [ "$1" = "replace" ]; then
		[ -e /.gnupg/pubring.gpg ] && rm /.gnupg/pubring.gpg
		[ -e /.gnupg/pubring.kbx ] && rm /.gnupg/pubring.kbx
		[ -e /.gnupg/trustdb.gpg ] && rm /.gnupg/trustdb.gpg
	fi

	cat "$PUBKEY" | gpg --import || [ $? -eq 2 ]
	gpg --list-keys --fingerprint --with-colons | sed -E -n -e 's/^fpr:::::::::([0-9A-F]+):$/\1:6:/p' | gpg --import-ownertrust
	gpg --update-trust

	if cbfs.sh -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/pubring.kbx"; then
		cbfs.sh -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/pubring.kbx"
		if cbfs.sh -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/pubring.gpg"; then
			cbfs.sh -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/pubring.gpg"
			[ -e /.gnupg/pubring.gpg ] && rm /.gnupg/pubring.gpg
		fi
	fi

	if [ -e /.gnupg/pubring.kbx ]; then
		cbfs.sh -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/pubring.kbx" -f /.gnupg/pubring.kbx
		[ -e /.gnupg/pubring.gpg ] && rm /.gnupg/pubring.gpg
	fi
	if [ -e /.gnupg/pubring.gpg ]; then
		cbfs.sh -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/pubring.gpg" -f /.gnupg/pubring.gpg
	fi

	if cbfs.sh -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/trustdb.gpg"; then
		cbfs.sh -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/trustdb.gpg"
	fi
	if [ -e /.gnupg/trustdb.gpg ]; then
		cbfs.sh -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/trustdb.gpg" -f /.gnupg/trustdb.gpg
	fi

	if cbfs.sh -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/otrust.txt"; then
		cbfs.sh -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/otrust.txt"
	fi

	if cbfs.sh -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/etc/config.user"; then
		cbfs.sh -o /tmp/gpg-gui.rom -d "heads/initrd/etc/config.user"
	fi
	if [ -e /etc/config.user ]; then
		cbfs.sh -o /tmp/gpg-gui.rom -a "heads/initrd/etc/config.user" -f /etc/config.user
	fi
	if /bin/flash.sh /tmp/gpg-gui.rom; then
		whiptail_type $BG_COLOR_MAIN_MENU --title 'ROM Flashed Successfully' \
			--msgbox "The GPG key has been added and the BIOS flashed successfully.\n\nPress Enter to reboot" 0 80
		/bin/reboot.sh
	else
		whiptail_error --title 'ROM Flash Failed' \
			--msgbox "Failed to flash the BIOS.\n\nYour system may be in an inconsistent state." 0 80
	fi
}

gpg_post_gen_mgmt() {
	GPG_GEN_KEY=$(grep -A1 pub /tmp/gpg_card_edit_output | tail -n1 | sed -nr 's/^([ ])*//p')
	gpg --export --armor $GPG_GEN_KEY >"/tmp/${GPG_GEN_KEY}.asc"
	if (whiptail_warning --title 'Add Public Key to USB disk?' \
		--yesno "Would you like to copy the GPG public key you generated to a USB disk?\n\nYou may need it, if you want to use it outside of Heads later.\n\nThe file will show up as ${GPG_GEN_KEY}.asc" 0 80); then
		mount_usb
		mount -o remount,rw /media
		cp "/tmp/${GPG_GEN_KEY}.asc" "/media/${GPG_GEN_KEY}.asc"
		if [ $? -eq 0 ]; then
			whiptail_type $BG_COLOR_MAIN_MENU --title "The GPG Key Copied Successfully" \
				--msgbox "${GPG_GEN_KEY}.asc copied successfully." 0 80
		else
			whiptail_error --title 'ERROR: Copy Failed' \
				--msgbox "Unable to copy ${GPG_GEN_KEY}.asc to /media" 0 80
		fi
		umount /media
	fi
	if (whiptail --title 'Add Public Key to Running BIOS?' \
		--yesno "Would you like to add the GPG public key you generated to the BIOS?\n\nThis makes it a trusted key used to sign files in /boot\n\n" 0 80); then
		/bin/flash.sh -r /tmp/gpg-gui.rom
		if [ ! -s /tmp/gpg-gui.rom ]; then
			whiptail_error --title 'ERROR: BIOS Read Failed!' \
				--msgbox "Unable to read BIOS" 0 80
			exit 1
		fi
		PUBKEY="/tmp/${GPG_GEN_KEY}.asc"
		gpg_flash_rom
	fi
}

gpg_add_key_reflash() {
	if (whiptail --title 'GPG public key required' \
		--yesno "This requires you insert a USB drive containing:\n* Your GPG public key (*.key or *.asc)\n\nAfter you select this file, this program will copy and reflash your BIOS\n\nDo you want to proceed?" 0 80); then
		mount_usb
		if grep -q /media /proc/mounts; then
			find /media -name '*.key' >/tmp/filelist.txt
			find /media -name '*.asc' >>/tmp/filelist.txt
			file_selector "/tmp/filelist.txt" "Choose your GPG public key"
			if [ "$FILE" = "" ]; then
				return 1
			fi
			PUBKEY=$FILE

			/bin/flash.sh -r /tmp/gpg-gui.rom
			if [ ! -s /tmp/gpg-gui.rom ]; then
				whiptail_error --title 'ERROR: BIOS Read Failed!' \
					--msgbox "Unable to read BIOS" 0 80
				return 1
			fi

			if (whiptail --title 'Update ROM?' \
				--yesno "This will reflash your BIOS with the updated version\n\nDo you want to proceed?" 0 80); then
				gpg_flash_rom
			fi
		fi
	fi
	return 1
}

gpg_add_key_to_standalone_rom() {
	if (whiptail --title 'ROM and GPG public key required' \
		--yesno "This requires you insert a USB drive containing:\n* Your GPG public key (*.key or *.asc)\n* Your BIOS image (*.rom)\n\nAfter you select these files, this program will reflash your BIOS\n\nDo you want to proceed?" 0 80); then
		mount_usb
		if grep -q /media /proc/mounts; then
			find /media -name '*.key' >/tmp/filelist.txt
			find /media -name '*.asc' >>/tmp/filelist.txt
			file_selector "/tmp/filelist.txt" "Choose your GPG public key"
			if [ "$FILE" == "" ]; then
				return 1
			fi
			PUBKEY=$FILE

			find /media -name '*.rom' >/tmp/filelist.txt
			file_selector "/tmp/filelist.txt" "Choose the ROM to load your key onto"
			if [ "$FILE" == "" ]; then
				return 1
			fi
			cp "$FILE" /tmp/gpg-gui.rom

			if (whiptail_warning --title 'Flash ROM?' \
				--yesno "This will replace your old ROM with the selected ROM\n\nDo you want to proceed?" 0 80); then
				gpg_flash_rom
			fi
		fi
	fi
	return 1
}

gpg_replace_key_reflash() {
	[ -e /.gnupg/pubring.gpg ] && rm /.gnupg/pubring.gpg
	[ -e /.gnupg/pubring.kbx ] && rm /.gnupg/pubring.kbx
	[ -e /.gnupg/trustdb.gpg ] && rm /.gnupg/trustdb.gpg
	gpg_add_key_reflash
}

# Reset Nitrokey 3 Secrets app PIN to factory default.
# $1: admin PIN for the NK3 Secrets app (before factory reset of OpenPGP card)
gpg_reset_nk3_secret_app() {
	TRACE_FUNC
	local admin_pin="$1"
	if [ "$DONGLE_BRAND" = "Nitrokey 3" ] && [ -x /bin/hotp_verification ]; then
		STATUS "Resetting Nitrokey 3 Secrets app (physical touch will be required)"
		for attempt in 1 2 3; do
			if hotp_verification reset "${admin_pin}"; then
				STATUS_OK "Nitrokey 3 Secrets app reset"
				return 0
			else
				error_code=$?
				if [ $error_code -eq 3 ] && [ $attempt -lt 3 ]; then
					whiptail_warning --msgbox "$DONGLE_BRAND requires physical presence: touch the dongle when requested" 0 80 --title "$DONGLE_BRAND secrets app reset attempt: $attempt/3"
				else
					DEBUG "NK3 Secrets app reset failed with error $error_code"
					return 1
				fi
			fi
		done
	fi
}

# Factory-reset the OpenPGP smartcard and set key attributes for the given
# algorithm.  Uses the default admin PIN (12345678) for the reset operation;
# if the card has a custom admin PIN, the caller should prompt the user.
# $1: key algorithm -- "RSA" or "p256"
# $2: RSA key length in bits (only used when algo is RSA)
# $3: optional card admin PIN override (defaults to ADMIN_PIN_DEF=12345678)
gpg_card_factory_reset() {
	TRACE_FUNC
	local algo="$1"
	local rsa_key_length="$2"
	local card_admin_pin="${3:-12345678}"

	STATUS "Factory resetting $DONGLE_BRAND OpenPGP smartcard"
	{
		echo admin         # admin menu
		echo factory-reset # factory reset smartcard
		echo y             # confirm
		echo yes           # confirm
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback \
		--passphrase-file <(echo -n "$card_admin_pin") --card-edit \
		>/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG factory-reset output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		return 1
	fi

	# Reset Nitrokey Storage AES keys if applicable
	if [ "$DONGLE_BRAND" = "Nitrokey Storage" ] && [ -x /bin/hotp_verification ]; then
		STATUS "Resetting Nitrokey Storage AES keys"
		hotp_verification regenerate "${card_admin_pin}"
		STATUS_OK "Nitrokey Storage AES keys reset"
	fi

	STATUS_OK "OpenPGP smartcard factory reset"

	# Toggle forced sig (good security practice, forcing PIN request for each signature request)
	if gpg --card-status | grep "Signature PIN" | grep -q "not forced"; then
		STATUS "Enabling forced signature PIN on smartcard"
		{
			echo admin            # admin menu
			echo forcesig         # toggle forcesig
			echo "${card_admin_pin}"
		} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback --card-edit \
			>/tmp/gpg_card_edit_output 2>&1
		TRACE_FUNC
		DEBUG "GPG forcesig toggle output: $(cat /tmp/gpg_card_edit_output)"
		if [ $? -ne 0 ]; then
			WARN "Could not enable forced signature PIN; continuing anyway"
		else
			STATUS_OK "Forced signature PIN enabled"
		fi
	fi

	# Set key attributes on the card
	if [ "$algo" = "p256" ]; then
		STATUS "Setting NIST P-256 key attributes on $DONGLE_BRAND"
		{
			echo admin
			echo key-attr
			echo 2                # ECC
			echo 3                # P-256
			echo "${card_admin_pin}"
			echo 2                # ECC
			echo 3                # P-256
			echo "${card_admin_pin}"
			echo 2                # ECC
			echo 3                # P-256
			echo "${card_admin_pin}"
		} | DO_WITH_DEBUG gpg --expert --command-fd=0 --status-fd=1 --pinentry-mode=loopback --card-edit \
			>/tmp/gpg_card_edit_output 2>&1
		TRACE_FUNC
		DEBUG "GPG p256 key-attr output: $(cat /tmp/gpg_card_edit_output)"
		if [ $? -ne 0 ]; then
			return 1
		fi
		STATUS_OK "NIST P-256 key attributes set"
	elif [ "$algo" = "RSA" ]; then
		STATUS "Setting RSA ${rsa_key_length}-bit key attributes on $DONGLE_BRAND"
		{
			echo admin
			echo key-attr
			echo 1                 # RSA
			echo "${rsa_key_length}"
			echo "${card_admin_pin}"
			echo 1                 # RSA
			echo "${rsa_key_length}"
			echo "${card_admin_pin}"
			echo 1                 # RSA
			echo "${rsa_key_length}"
			echo "${card_admin_pin}"
		} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback --card-edit \
			>/tmp/gpg_card_edit_output 2>&1
		TRACE_FUNC
		DEBUG "GPG RSA key-attr output: $(cat /tmp/gpg_card_edit_output)"
		if [ $? -ne 0 ]; then
			return 1
		fi
		STATUS_OK "RSA ${rsa_key_length}-bit key attributes set"
	else
		DIE "Unknown GPG algorithm: $algo"
	fi
}

# Set OpenPGP card identity (name, login/email) from parsed GPG key metadata.
# $1: full name (will be split into surname/given by set_card_identity logic)
# $2: email address
# $3: card admin PIN
gpg_set_card_identity() {
	TRACE_FUNC
	local gpg_name="$1"
	local gpg_email="$2"
	local card_admin_pin="$3"
	local set_name=0 set_login=0
	local surname given

	[ -n "$gpg_name" ] && [ "$gpg_name" != "OEM Key" ] && set_name=1
	# Skip login if email matches auto-generated OEM default pattern
	if [ -n "$gpg_email" ]; then
		case "$gpg_email" in
		oem-*@example.com)
			# OEM default email -- do not set login
			;;
		*)
			set_login=1
			;;
		esac
	fi

	if [ "$set_name" -eq 0 ] && [ "$set_login" -eq 0 ]; then
		DEBUG "No custom identity to set on smartcard"
		return
	fi

	if [ "$set_name" -eq 1 ]; then
		case "$gpg_name" in
		*" "*)
			given="${gpg_name% *}"
			surname="${gpg_name##* }"
			;;
		*)
			surname="$gpg_name"
			given=""
			;;
		esac
		DEBUG "Will set cardholder name: surname='$surname' given='$given'"
	fi

	STATUS "Setting identity fields on OpenPGP smartcard"
	{
		echo "admin"
		if [ "$set_name" -eq 1 ]; then
			echo "name"
			echo "${surname}"
			echo "${given}"
		fi
		if [ "$set_login" -eq 1 ]; then
			echo "login"
			echo "${gpg_email}"
		fi
		echo "quit"
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=2 --pinentry-mode=loopback \
		--passphrase-file <(printf '%s' "$card_admin_pin") --card-edit \
		>/tmp/gpg_card_edit_output 2>&1 ||
		DIE "Failed to set identity fields on OpenPGP smartcard"

	local summary=""
	[ "$set_name" -eq 1 ] && summary="${given:+$given }${surname}"
	[ "$set_login" -eq 1 ] && summary="${summary:+$summary, }${gpg_email}"
	STATUS_OK "Card identity set: $summary"
}

# Change GPG PIN on the OpenPGP smartcard.
# $1: PIN type -- 1 = user PIN, 3 = admin PIN
# $2: old (current) PIN
# $3: new PIN
gpg_card_change_pin() {
	TRACE_FUNC
	local pin_type="$1"
	local old_pin="$2"
	local new_pin="$3"
	{
		echo admin       # admin menu
		echo passwd      # change PIN
		echo "${pin_type}" # 1 = user PIN, 3 = admin PIN
		echo "${old_pin}" # old PIN
		echo "${new_pin}" # new PIN
		echo "${new_pin}" # confirm new PIN
		echo q           # quit
		echo q
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=2 --pinentry-mode=loopback --card-edit \
		>/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG PIN change output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		return 1
	fi
	TRACE_FUNC
}

# Move subkeys from the local keyring to the OpenPGP smartcard.
# Assumes the card has been factory-reset and configured with correct key-attr.
# $1: key identifier (email or fingerprint for --edit-key)
# $2: subkey passphrase (local keyring passphrase)
# $3: card admin PIN (smartcard admin PIN, defaults to 12345678 after factory reset)
gpg_keytocard_subkeys() {
	TRACE_FUNC
	local key_id="$1"
	local subkey_pin="$2"
	local card_pin="${3:-12345678}"

	# Ensure USB and smartcard are accessible
	enable_usb
	enable_usb_storage
	STATUS "Accessing $DONGLE_BRAND OpenPGP smartcard"
	gpg --card-status >/dev/null 2>&1 || {
		DEBUG "gpg --card-status failed in gpg_keytocard_subkeys"
		return 1
	}
	DEBUG "Smartcard accessible for keytocard via gpg --card-status"

	STATUS "Moving subkeys to $DONGLE_BRAND"
	{
		echo "key 1"            # Toggle on Signature key in --edit-key mode on local keyring
		echo "keytocard"        # Move Signature key to smartcard
		echo "1"                # Select Signature key key slot on smartcard
		echo "${subkey_pin}"    # Local keyring Subkey PIN
		echo "${card_pin}"      # Smartcard Admin PIN (prompted once; scdaemon caches it)
		echo "key 1"            # Toggle off Signature key
		echo "key 2"            # Toggle on Encryption key
		echo "keytocard"        # Move Encryption key to smartcard
		echo "2"                # Select Encryption key key slot on smartcard
		echo "${subkey_pin}"    # Local keyring Subkey PIN (card PIN already cached by scdaemon)
		echo "key 2"            # Toggle off Encryption key
		echo "key 3"            # Toggle on Authentication key
		echo "keytocard"        # Move Authentication key to smartcard
		echo "3"                # Select Authentication key slot on smartcard
		echo "${subkey_pin}"    # Local keyring Subkey PIN (card PIN still cached by scdaemon)
		echo "key 3"            # Toggle off Authentication key
		echo "save"             # Save changes and commit to keyring
	} | DO_WITH_DEBUG gpg --expert --command-fd=0 --status-fd=1 --pinentry-mode=loopback \
		--edit-key "$key_id" \
		>/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG keytocard output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		DEBUG "keytocard failed"
		return 1
	fi
	STATUS_OK "Subkeys moved to smartcard"
	DEBUG "keytocard completed successfully, subkeys now on $DONGLE_BRAND"

	TRACE_FUNC
}

# Reprovision an OpenPGP smartcard from a GPG key backup on a LUKS-encrypted
# USB drive.  Detects key type (RSA vs ECC) from the imported key, mounts the
# LUKS private partition to import privkey.sec, mounts the public partition to
# import pubkey.asc, factory-resets the smartcard, moves subkeys via keytocard,
# sets the card identity, and offers to flash the public key and config to the
# running BIOS via gpg_flash_rom.
reprovision_smartcard_from_backup() {
	TRACE_FUNC
	local admin_pin key_algo rsa_key_length key_name key_email key_comment
	local card_admin_pin identity_summary key_id uid_line uid_decoded
	local mapper_dev parent_disk pub_partition
	local algo_code bit_len

	# Detect dongle branding early -- needed for whiptail messages and
	# Nitrokey Storage AES key reset in factory_reset_and_configure.
	enable_usb
	detect_usb_security_dongle_branding
	DEBUG "Dongle brand: $DONGLE_BRAND"

	# Clear stale GPG agent and scdaemon state before accessing the card.
	# This matches the OEM pattern at oem-factory-reset.sh line 1178-1180:
	# kill scdaemon first so the next gpg --card-status starts fresh.
	killall gpg-agent scdaemon >/dev/null 2>&1 || true

	# Verify smartcard is accessible before asking the user for backup info
	STATUS "Checking for $DONGLE_BRAND smartcard"
	if ! gpg --card-status >/dev/null 2>&1; then
		INPUT "No $DONGLE_BRAND smartcard detected. Insert the card and press Enter to retry, or Ctrl+C to cancel." ignored
		if ! gpg --card-status >/dev/null 2>&1; then
			DEBUG "$DONGLE_BRAND smartcard not detected"
			whiptail_error --title 'ERROR: No Smartcard' \
				--msgbox "No $DONGLE_BRAND OpenPGP smartcard was detected.\n\nPlease insert your smartcard and try again." 0 80
			return 1
		fi
	fi
	DEBUG "Smartcard accessible: gpg --card-status succeeded"
	STATUS_OK "$DONGLE_BRAND smartcard accessible"

	# Collect backup passphrase (Admin PIN used during OEM factory reset)
	while [ -z "$admin_pin" ]; do
		INPUT "Enter GPG key backup passphrase:" -r -s admin_pin
	done
	DEBUG "Backup passphrase collected (${#admin_pin} chars)"

	# Phase 1: wipe ~/.gnupg and initialize an empty keyring.
	# This ensures a clean state for the backup import -- no stale keys,
	# no stale trustdb, no card stubs from a previous session.
	rm -f /.gnupg/*.kbx /.gnupg/*.gpg /.gnupg/trustdb.gpg 2>/dev/null || true
	gpg --list-keys >/dev/null 2>&1
	DEBUG "Wiped ~/.gnupg keyring, initialized empty"

	# Phase 2: mount the LUKS private partition (read-only).
	# mount-usb.sh with --pass auto-detects the LUKS partition.
	enable_usb
	enable_usb_storage
	STATUS "Mounting GPG key backup (LUKS private partition)"
	if ! mount-usb.sh --mode ro --mountpoint /media --pass "$admin_pin"; then
		DEBUG "Could not mount backup LUKS partition"
		whiptail_error --title 'ERROR: Backup Mount Failed' \
			--msgbox "Could not mount the backup USB drive.\n\nVerify that the correct backup drive is inserted\nand the passphrase is correct." 0 80
		return 1
	fi
	DEBUG "LUKS partition mounted at /media"
	STATUS_OK "Backup LUKS partition mounted"

	# Verify the private key backup file exists
	if [ ! -f /media/privkey.sec ]; then
		umount /media 2>/dev/null || true
		WARN "privkey.sec not found on backup drive -- not a valid GPG key backup"
		whiptail_error --title 'ERROR: No Backup Found' \
			--msgbox "No privkey.sec found on this drive.\n\nThis does not appear to be a valid\nGPG key backup drive." 0 80
		return 1
	fi

	# Phase 3: import the private key (master + subkeys) into ~/.gnupg.
	# --import-options restore brings in the full key material.
	STATUS "Importing GPG keys from backup"
	if ! gpg --pinentry-mode=loopback --passphrase-file <(printf '%s' "$admin_pin") \
		--import-options restore --import /media/privkey.sec >/dev/null 2>/tmp/gpg_import_err; then
		umount /media 2>/dev/null || true
		ERROR="$(cat /tmp/gpg_import_err)"
		WARN "GPG key import from backup failed: $(head -3 /tmp/gpg_import_err 2>/dev/null)"
		whiptail_error --title 'ERROR: Key Import Failed' \
			--msgbox "Failed to import GPG keys from backup.\n\n${ERROR}" 0 80
		return 1
	fi
	DEBUG "privkey.sec imported into ~/.gnupg successfully"
	STATUS_OK "GPG keys imported"

	# Phase 4: detect key type and extract identity from the now-imported key.
	# gpg --with-colons field layout:
	#   pub: ... :<bit_len>:<algo>:<key_id>: ...
	#   uid: ... :<escaped_uid>: ...
	algo_code="$(gpg --with-colons --list-keys 2>/dev/null | grep '^pub:' | cut -d: -f4)"
	bit_len="$(gpg --with-colons --list-keys 2>/dev/null | grep '^pub:' | cut -d: -f3)"
	uid_line="$(gpg --with-colons --list-keys 2>/dev/null | grep '^uid:' | head -1 | cut -d: -f10)"

	case "$algo_code" in
	1)
		key_algo="RSA"
		rsa_key_length="${bit_len:-3072}"
		DEBUG "Detected RSA ${rsa_key_length}-bit key from backup"
		;;
	19)
		key_algo="p256"
		DEBUG "Detected ECC P-256 key from backup"
		;;
	*)
		umount /media 2>/dev/null || true
		WARN "Unrecognized GPG algorithm code $algo_code from backup key"
		whiptail_error --title 'ERROR: Unknown Key Type' \
			--msgbox "Could not detect the key type from the backup\n(algorithm $algo_code).\n\nThe backup file may be corrupted." 0 80
		return 1
		;;
	esac

	# Parse UID: "Real Name (Comment) <email@example.com>"
	if echo "$uid_line" | grep -q '('; then
		key_name="$(echo "$uid_line" | sed 's/ (.*//')"
		key_comment="$(echo "$uid_line" | sed 's/.*(//;s/).*//')"
	else
		key_name="$uid_line"
		key_comment=""
	fi
	key_email="$(echo "$uid_line" | grep -o '<[^>]*>' | tr -d '<>')"
	[ -z "$key_name" ] && key_name="$uid_line"

	# Determine the key identifier for --edit-key operations
	if [ -n "$key_email" ]; then
		key_id="$key_email"
	else
		key_id="$(gpg --list-secret-keys --with-colons 2>/dev/null | grep '^sec:' | cut -d: -f5)"
		[ -z "$key_id" ] && {
			umount /media 2>/dev/null || true
			DIE "Could not determine key ID from imported backup"
		}
	fi
	DEBUG "Using key_id=$key_id (${key_email:+from email, }${key_email:-from fingerprint})"
	local key_fpr
	key_fpr="$(gpg --with-colons --list-keys 2>/dev/null | grep '^fpr' | cut -d: -f10 | head -1)" || \
		DEBUG "Fingerprint extraction returned non-zero, continuing without it"
	DEBUG "Key fingerprint: ${key_fpr:-<none>}"

	identity_summary="${key_name}"
	[ -n "$key_comment" ] && identity_summary="${identity_summary} (${key_comment})"
	[ -n "$key_email" ] && identity_summary="${identity_summary} <${key_email}>"
	[ -n "$key_fpr" ] && identity_summary="${identity_summary}\n    Fingerprint: ${key_fpr}"
	DEBUG "Backup key identity: name='$key_name' email='$key_email' comment='$key_comment' fingerprint='$key_fpr'"

	# Dongle compatibility check (ECC key on RSA-only dongles)
	DEBUG "Checking $DONGLE_BRAND compatibility with $key_algo key"
	if [ "$key_algo" = "p256" ]; then
		DEBUG "ECC key detected on RSA-only compatible dongle; showing warning"
		case "$DONGLE_BRAND" in
		"Nitrokey Pro" | "Nitrokey Storage" | "Librem Key")
			if ! whiptail_warning --title 'Dongle Compatibility Warning' \
				--yesno "The backed-up key is ECC P-256, but your $DONGLE_BRAND\nmay have limited ECC support.\n\nProceeding may fail.\n\nDo you want to continue?" 0 80; then
				DEBUG "User aborted: ECC key incompatible with dongle"
				umount /media 2>/dev/null || true
				return 1
			fi
			DEBUG "User accepted ECC compatibility risk"
			;;
		esac
	else
		DEBUG "RSA key -- no dongle compatibility concern"
	fi

	# Confirm with user before making changes
	DEBUG "Showing reprovision confirmation dialog to user"
	if ! whiptail_warning --title 'Reprovision Smartcard' \
		--yesno "This will:\n\n  * ERASE all keys on your $DONGLE_BRAND\n  * Import GPG key: $identity_summary\n    (${key_algo}$([ "$key_algo" = "RSA" ] && echo " ${rsa_key_length}-bit"))\n  * Copy subkeys to the smartcard\n\nDo you want to continue?" 0 80; then
		DEBUG "User declined reprovision via confirmation dialog"
		umount /media 2>/dev/null || true
		return 1
	fi
	DEBUG "User confirmed reprovision; proceeding with factory reset"

	# Re-verify the smartcard is still present before wiping it
	STATUS "Verifying $DONGLE_BRAND smartcard is still present"
	if ! gpg --card-status >/dev/null 2>&1; then
		umount /media 2>/dev/null || true
		WARN "$DONGLE_BRAND smartcard disappeared after user confirmation"
		whiptail_error --title 'ERROR: Smartcard Not Found' \
			--msgbox "The $DONGLE_BRAND smartcard is no longer detected.\n\nCheck the connection and try again." 0 80
		return 1
	fi
	DEBUG "Smartcard detected: gpg --card-status succeeded"
	STATUS_OK "$DONGLE_BRAND smartcard still accessible"

	# Phase 5: factory-reset the smartcard and configure key attributes.
	# First attempt uses the default admin PIN; if the card has a custom PIN,
	# prompt the user and retry.
	# Reset NK3 Secrets app before factory reset, matching OEM pattern
	# (oem-factory-reset.sh line 1228: reset_nk3_secret_app before key gen).
	card_admin_pin="12345678"   # ADMIN_PIN_DEF
	release_scdaemon
	gpg_reset_nk3_secret_app "$card_admin_pin" || \
		DEBUG "NK3 Secrets app reset failed (non-fatal; HOTP configured later)"

	local factory_reset_ok="n"
	for attempt in 1 2; do
		DEBUG "Factory reset attempt $attempt with admin PIN (${#card_admin_pin} chars)"
		if gpg_card_factory_reset "$key_algo" "$rsa_key_length" "$card_admin_pin"; then
			factory_reset_ok="y"
			DEBUG "Smartcard factory reset succeeded on attempt $attempt"
			break
		fi
		if [ "$attempt" -eq 1 ]; then
			WARN "Factory reset with default admin PIN failed; the card may have a custom PIN."
			card_admin_pin=""
			DEBUG "Default admin PIN failed; prompting for custom admin PIN"
			while [ -z "$card_admin_pin" ]; do
				INPUT "Enter the current $DONGLE_BRAND admin PIN:" -r -s card_admin_pin
			done
		fi
	done
	if [ "$factory_reset_ok" != "y" ]; then
		umount /media 2>/dev/null || true
		ERROR="$(tail -n 3 /tmp/gpg_card_edit_output 2>/dev/null | fold -s)"
		WARN "Smartcard factory reset failed after retry with correct admin PIN"
		whiptail_error --title 'ERROR: Factory Reset Failed' \
			--msgbox "Could not factory reset the $DONGLE_BRAND smartcard.\n\n${ERROR}\n\nCheck that the admin PIN is correct." 0 80
		return 1
	fi

	# After factory reset, the card admin PIN is back to default.
	card_admin_pin="12345678"

	# Phase 6: move subkeys from the local keyring to the smartcard.
	DEBUG "Starting keytocard with key_id=$key_id, admin_pin=${#admin_pin} chars, card_admin_pin=${#card_admin_pin} chars"
	if ! gpg_keytocard_subkeys "$key_id" "$admin_pin" "$card_admin_pin"; then
		umount /media 2>/dev/null || true
		ERROR="$(cat /tmp/gpg_card_edit_output)"
		WARN "GPG keytocard operation failed: $(head -3 /tmp/gpg_card_edit_output 2>/dev/null)"
		whiptail_error --title 'ERROR: Keytocard Failed' \
			--msgbox "Failed to move subkeys to smartcard.\n\n${ERROR}" 0 80
		return 1
	fi

	# Phase 7: set card identity from the backup key's UID
	gpg_set_card_identity "$key_name" "$key_email" "$card_admin_pin"

	# Phase 7b: prompt for custom PINs if desired.
	# After factory reset the card is at OpenPGP defaults:
	# admin PIN=12345678, user PIN=123456.
	# For NK3, the Admin PIN also serves as the Secrets App PIN.
	local pin_label_admin="GPG Admin PIN"
	[ "$DONGLE_BRAND" = "Nitrokey 3" ] && pin_label_admin="NK3 Secrets app PIN / GPG Admin PIN"
	if whiptail_warning --title 'Set Custom PINs?' \
		--yesno "The card is currently using factory-default PINs\n(Admin: 12345678, User: 123456).\n\nWould you like to set custom PINs?" 0 80; then
		local new_admin_pin new_user_pin
		NOTE "${pin_label_admin}: management tasks on $DONGLE_BRAND, 3 attempts max.\nRecommended: 2 diceware words (6-25 chars)"
		while [ -z "$new_admin_pin" ]; do
			INPUT "Enter new ${pin_label_admin} (6-25 chars):" -r -s new_admin_pin
		done
		if ! gpg_card_change_pin 3 "12345678" "$new_admin_pin"; then
			ERROR="$(cat /tmp/gpg_card_edit_output | fold -s)"
			whiptail_error --title 'ERROR: Admin PIN Change Failed' \
				--msgbox "Could not change the Admin PIN.\n\n${ERROR}" 0 80
			umount /media 2>/dev/null || true
			return 1
		fi
		STATUS_OK "${pin_label_admin} changed"

		# Also set NK3 Secrets app PIN to match the new Admin PIN
		# (hotp_verification reset <pin> sets the Secrets app PIN)
		release_scdaemon
		gpg_reset_nk3_secret_app "$new_admin_pin" || \
			DEBUG "NK3 Secrets app PIN update failed -- HOTP will need the default PIN (12345678)"

		NOTE "GPG User PIN: signing /boot and encryption, 3 attempts max.\nRecommended: 2 diceware words (6-25 chars)"
		while [ -z "$new_user_pin" ]; do
			INPUT "Enter new GPG User PIN (6-25 chars):" -r -s new_user_pin
		done
		if ! gpg_card_change_pin 1 "123456" "$new_user_pin"; then
			ERROR="$(cat /tmp/gpg_card_edit_output | fold -s)"
			whiptail_error --title 'ERROR: User PIN Change Failed' \
				--msgbox "Could not change the User PIN.\n\n${ERROR}" 0 80
			umount /media 2>/dev/null || true
			return 1
		fi
		STATUS_OK "GPG User PIN changed"
	else
		DEBUG "User declined custom PINs; keeping factory defaults"
	fi

	# Phase 8: save the LUKS mapper name so we can derive the public
	# partition device, then unmount the LUKS partition.
	mapper_dev="$(ls /dev/mapper/usb_mount_* 2>/dev/null | head -1)"
	umount /media 2>/dev/null || true
	if [ -n "$mapper_dev" ]; then
		# Extract partition name from mapper (e.g. usb_mount_sdb1 -> sdb1)
		# and derive parent disk (e.g. /dev/sdb) + public partition (/dev/sdb2).
		local part_name
		part_name="$(basename "$mapper_dev" | sed 's/^usb_mount_//')"
		parent_disk="$(echo "/dev/$part_name" | sed -E 's/(p?)[0-9]+$//')"
		pub_partition="${parent_disk}2"
		DEBUG "mapper_dev=$mapper_dev part_name=$part_name parent_disk=$parent_disk pub_partition=${pub_partition:-none}"
		cryptsetup close "$(basename "$mapper_dev")" 2>/dev/null || true
	else
		# Fallback: try mounting the first non-LUKS USB device
		pub_partition=""
	fi

	# Phase 9: mount the public partition and import pubkey.asc.
	# Validate against the key already in ~/.gnupg; re-import is idempotent
	# so exit code 2 (unchanged) is a normal result.
	enable_usb
	enable_usb_storage
	STATUS "Mounting GPG key backup (public partition)"
	if [ -n "$pub_partition" ]; then
		DEBUG "Mounting public partition via explicit device: $pub_partition"
		if ! mount-usb.sh --device "$pub_partition" --mode ro --mountpoint /media; then
			DEBUG "Could not mount public partition at $pub_partition"
		fi
		STATUS_OK "Public partition mounted"
	else
		DEBUG "No explicit public device; falling back to auto-detection"
		mount-usb.sh --mode ro --mountpoint /media 2>/dev/null ||
			DEBUG "Could not auto-detect public partition"
	fi

	STATUS "Importing public key from backup"
	if [ -f /media/pubkey.asc ]; then
		gpg --import </media/pubkey.asc || [ $? -eq 2 ]
		PUBKEY=/media/pubkey.asc
		DEBUG "pubkey.asc found on public partition at /media/pubkey.asc"
		STATUS_OK "Public key imported"
	else
		# Fallback: export from the keyring (public key is already there
		# from the privkey.sec import)
		gpg --export --armor "$key_id" >/tmp/reprovision_pubkey.asc 2>/dev/null || {
			umount /media 2>/dev/null || true
			DIE "Failed to export public key for ROM flash"
		}
		PUBKEY=/tmp/reprovision_pubkey.asc
		DEBUG "pubkey.asc not found; exporting public key from imported keyring"
	fi

	# Establish ultimate trust on the key (needed for gpg_flash_rom + boot)
	gpg --list-keys --fingerprint --with-colons 2>/dev/null | \
		sed -E -n -e 's/^fpr:::::::::([0-9A-F]+):$/\1:6:/p' | \
		gpg --import-ownertrust >/dev/null 2>&1
	gpg --update-trust >/dev/null 2>&1
	DEBUG "Public key trusted in ~/.gnupg keyring"

	# Phase 10: set CONFIG_HAVE_GPG_KEY_BACKUP so future boots know a
	# backup exists, and offer to flash the public key + config to ROM.
	set_user_config "CONFIG_HAVE_GPG_KEY_BACKUP" "y"
	DEBUG "Set CONFIG_HAVE_GPG_KEY_BACKUP=y in /etc/config.user"
	combine_configs

	STATUS_OK "Smartcard reprovisioned"

	# QEMU guard: skip ROM flash in QEMU (no internal flashing support).
	# Match qemu-* pattern per oem-factory-reset.sh lines 1357-1362.
	if [[ "$CONFIG_BOARD_NAME" == qemu-* ]]; then
		WARN "Skipping flash of GPG key to ROM: running in QEMU without internal flashing support."
		WARN "Extract the public key and inject it into the firmware image as documented in boards/qemu*/*.md."
		NOTE "The public key is in the keyring for this session but will be lost on\nreboot. Use an external GPG injection step (PUBKEY_ASC=... inject_gpg)\nto persist it across boots. See doc/qemu.md."
	else
		DEBUG "Offering ROM flash to user"
		if whiptail_warning --title 'Flash Key to BIOS?' \
			--yesno "The public key is now in the local keyring for this session,\nbut will be lost on reboot unless you flash it to the ROM.\n\nThis will persist the public key and GPG backup setting.\n\nFlash to ROM now?" 0 80; then
			DEBUG "User accepted ROM flash; reading BIOS"
			[ -f /tmp/gpg-gui.rom ] && rm -f /tmp/gpg-gui.rom
			/bin/flash.sh -r /tmp/gpg-gui.rom
			if [ ! -s /tmp/gpg-gui.rom ]; then
				WARN "Could not read running BIOS for ROM flash"
				whiptail_error --title 'ERROR: BIOS Read Failed' \
					--msgbox "Unable to read the running BIOS.\n\nThe key is in the local keyring but will be lost on reboot." 0 80
			else
				gpg_flash_rom
				# gpg_flash_rom handles flash + reboot on success
			fi
		else
			DEBUG "User declined ROM flash"
		fi
	fi

	DEBUG "Running cleanup: unmounting partitions and closing LUKS mappings"
	# Cleanup: unmount public partition and close any orphaned LUKS mappings
	umount /media 2>/dev/null || true
	for dev in /dev/mapper/usb_mount_*; do
		[ -e "$dev" ] && cryptsetup close "$(basename "$dev")" 2>/dev/null || true
	done

	# Clear stale card stubs so gpg discovers the new card-resident keys
	release_scdaemon
	find "${GNUPGHOME:-$HOME/.gnupg}/private-keys-v1.d" \
		-name '*.key' -delete >/dev/null 2>&1 || true

	# Offer reboot unless gpg_flash_rom already handled it.
	DEBUG "Offering reboot to finalize provisioning"
	if whiptail_warning --title 'Reboot?' \
		--yesno "The $DONGLE_BRAND smartcard has been reprovisioned\nfrom the GPG key backup.\n\nYou should reboot to finalize and then update /boot signatures\nvia Options -> Update checksums and sign all files in /boot.\n\nReboot now?" 0 80; then
		DEBUG "User accepted reboot"
		/bin/reboot.sh
	fi
	DEBUG "User declined reboot"

	TRACE_FUNC
}
