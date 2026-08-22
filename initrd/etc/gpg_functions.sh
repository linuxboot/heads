#!/bin/bash

gpg_flash_rom() {
	if [ "$1" = "replace" ]; then
		[ -e /.gnupg/pubring.gpg ] && rm /.gnupg/pubring.gpg
		[ -e /.gnupg/pubring.kbx ] && rm /.gnupg/pubring.kbx
		[ -e /.gnupg/trustdb.gpg ] && rm /.gnupg/trustdb.gpg
	fi

	cat "$PUBKEY" | gpg --import
	gpg --list-keys --fingerprint --with-colons | sed -E -n -e 's/^fpr:::::::::([0-9A-Fa-f]+):$/\1:6:/p' | gpg --import-ownertrust
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
		mount_usb || return 1
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
		mount_usb || true
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
			if whiptail --title 'Update ROM?' \
				--yesno "This will reflash your BIOS with the updated version\n\nDo you want to proceed?" 0 80; then
				gpg_flash_rom
			fi
		fi
		umount /media 2>/dev/null || true
	fi
}

gpg_add_key_to_standalone_rom() {
	if (whiptail --title 'ROM and GPG public key required' \
		--yesno "This requires you insert a USB drive containing:\n* Your GPG public key (*.key or *.asc)\n* Your BIOS image (*.rom)\n\nAfter you select these files, this program will reflash your BIOS\n\nDo you want to proceed?" 0 80); then
		mount_usb || true
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

# --- Reprovision flow shared functions ---

gpg_reset_nk3_secret_app() {
	# Reset Nitrokey 3 Secrets app PIN.
	# $1: admin PIN (default 12345678 or user-chosen)
	TRACE_FUNC
	local admin_pin="$1"
	local error_code
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
					return $error_code
				fi
			fi
		done
	fi
	return 0
}

gpg_card_factory_reset() {
	# Factory-reset card, set key attributes.
	# $1: algo (RSA or p256)
	# $2: rsa_key_length (bits, for RSA only)
	# $3: card_admin_pin (default 12345678)
	TRACE_FUNC
	local algo="$1"
	local rsa_key_length="$2"
	local card_admin_pin="${3:-12345678}"
	local rc
	local admin_pin_file=/tmp/secret/gpg_admin_pin

	STATUS "Factory resetting $DONGLE_BRAND OpenPGP smartcard"
	mkdir -p /tmp/secret
	printf '%s' "$card_admin_pin" >"$admin_pin_file"
	chmod 600 "$admin_pin_file" 2>/dev/null || true
	{
		echo admin         # admin menu
		echo factory-reset # factory reset smartcard
		echo y             # confirm
		echo yes           # confirm
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback \
		--passphrase-file "$admin_pin_file" --card-edit \
		>/tmp/gpg_card_edit_output 2>&1
	rc=$?
	shred -n 10 -z -u "$admin_pin_file" 2>/dev/null || rm -f "$admin_pin_file"
	TRACE_FUNC
	DEBUG "GPG factory-reset output: $(cat /tmp/gpg_card_edit_output)"
	if [ $rc -ne 0 ]; then
		return 1
	fi

	# After factory reset the card admin PIN is back to default 12345678
	card_admin_pin="12345678"

	if [ "$DONGLE_BRAND" = "Nitrokey Storage" ] && [ -x /bin/hotp_verification ]; then
		STATUS "Resetting Nitrokey Storage AES keys"
		hotp_verification regenerate "${card_admin_pin}"
		STATUS_OK "Nitrokey Storage AES keys reset"
	fi

	STATUS_OK "OpenPGP smartcard factory reset"

	if gpg --card-status | grep "Signature PIN" | grep -q "not forced"; then
		STATUS "Enabling forced signature PIN on smartcard"
		{
			echo admin
			echo forcesig
			echo "${card_admin_pin}"
		} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback --card-edit \
			>/tmp/gpg_card_edit_output 2>&1
		rc=$?
		TRACE_FUNC
		DEBUG "GPG forcesig toggle output: $(cat /tmp/gpg_card_edit_output)"
		if [ $rc -ne 0 ]; then
			WARN "Could not enable forced signature PIN on smartcard"
			return 1
		else
			STATUS_OK "Forced signature PIN enabled"
		fi
	fi

	if [ "$algo" = "p256" ]; then
		STATUS "Setting NIST P-256 key attributes on $DONGLE_BRAND"
		{
			echo admin
			echo key-attr
			echo 2
			echo 3
			echo "${card_admin_pin}"
			echo 2
			echo 3
			echo "${card_admin_pin}"
			echo 2
			echo 3
			echo "${card_admin_pin}"
		} | DO_WITH_DEBUG gpg --expert --command-fd=0 --status-fd=1 --pinentry-mode=loopback --card-edit \
			>/tmp/gpg_card_edit_output 2>&1
		rc=$?
		TRACE_FUNC
		DEBUG "GPG p256 key-attr output: $(cat /tmp/gpg_card_edit_output)"
		if [ $rc -ne 0 ]; then
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
		} | DO_WITH_DEBUG gpg --expert --command-fd=0 --status-fd=1 --pinentry-mode=loopback --card-edit \
			>/tmp/gpg_card_edit_output 2>&1
		rc=$?
		TRACE_FUNC
		DEBUG "GPG RSA key-attr output: $(cat /tmp/gpg_card_edit_output)"
		if [ $rc -ne 0 ]; then
			return 1
		fi
		STATUS_OK "RSA ${rsa_key_length}-bit key attributes set"
	else
		DIE "Unknown GPG algorithm: $algo"
	fi
}

gpg_set_card_identity() {
	# Set cardholder name and login on OpenPGP smartcard.
	# $1: gpg_name (cardholder name, empty or "OEM Key" to skip)
	# $2: gpg_email (login, oem-*@example.com to skip)
	# $3: card_admin_pin (default 12345678)
	TRACE_FUNC
	local gpg_name="$1"
	local gpg_email="$2"
	local card_admin_pin="$3"
	local set_name=0 set_login=0
	local surname given
	local pin_file=/tmp/secret/gpg_admin_pin
	local rc

	[ -n "$gpg_name" ] && [ "$gpg_name" != "OEM Key" ] && set_name=1
	if [ -n "$gpg_email" ]; then
		case "$gpg_email" in
		oem-*@example.com) ;;
		*) set_login=1 ;;
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
	mkdir -p /tmp/secret
	printf '%s' "$card_admin_pin" >"$pin_file"
	chmod 600 "$pin_file" 2>/dev/null || true
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
		--passphrase-file "$pin_file" --card-edit \
		>/tmp/gpg_card_edit_output 2>&1 || {
			rc=$?
			shred -n 10 -z -u "$pin_file" 2>/dev/null || rm -f "$pin_file"
			return $rc
		}
	shred -n 10 -z -u "$pin_file" 2>/dev/null || rm -f "$pin_file"

	local summary=""
	[ "$set_name" -eq 1 ] && summary="${given:+$given }${surname}"
	[ "$set_login" -eq 1 ] && summary="${summary:+$summary, }${gpg_email}"
	STATUS_OK "Card identity set: $summary"
}

gpg_card_change_pin() {
	# Change GPG PIN (user or admin) on OpenPGP smartcard.
	# $1: pin_type (1 = user PIN, 3 = admin PIN)
	# $2: old_pin (current PIN value)
	# $3: new_pin (new PIN value)
	TRACE_FUNC
	local pin_type="$1"
	local old_pin="$2"
	local new_pin="$3"
	local rc
	{
		echo admin
		echo passwd
		echo "${pin_type}"
		echo "${old_pin}"
		echo "${new_pin}"
		echo "${new_pin}"
		echo q
		echo q
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=2 --pinentry-mode=loopback --card-edit \
		>/tmp/gpg_card_edit_output 2>&1
	rc=$?
	TRACE_FUNC
	DEBUG "GPG PIN change output: $(cat /tmp/gpg_card_edit_output)"
	if [ $rc -ne 0 ]; then
		return 1
	fi
	TRACE_FUNC
}

gpg_keytocard_subkeys() {
	# Move subkeys from local keyring to OpenPGP smartcard.
	# Pipe sends key 1/2/3 toggle -> keytocard -> slot -> subkey_pin -> card_pin
	# for each of sign/encrypt/auth slots, then save.
	# $1: key_id (email or fingerprint for --edit-key)
	# $2: subkey_pin (passphrase for local keyring subkeys)
	# $3: card_pin (default 12345678, admin PIN for smartcard)
	TRACE_FUNC
	local key_id="$1"
	local subkey_pin="$2"
	local card_pin="${3:-12345678}"
	local rc

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
		echo "key 1"
		echo "keytocard"
		echo "1"
		echo "${subkey_pin}"
		echo "${card_pin}"
		echo "key 1"
		echo "key 2"
		echo "keytocard"
		echo "2"
		echo "${subkey_pin}"
		echo "key 2"
		echo "key 3"
		echo "keytocard"
		echo "3"
		echo "${subkey_pin}"
		echo "key 3"
		echo "save"
	} | DO_WITH_DEBUG gpg --expert --command-fd=0 --status-fd=1 --pinentry-mode=loopback \
		--edit-key "$key_id" \
		>/tmp/gpg_card_edit_output 2>&1
	rc=$?
	TRACE_FUNC
	DEBUG "GPG keytocard output: $(cat /tmp/gpg_card_edit_output)"
	if [ $rc -ne 0 ]; then
		DEBUG "keytocard failed"
		return 1
	fi
	STATUS_OK "Subkeys moved to smartcard"
	DEBUG "keytocard completed successfully, subkeys now on $DONGLE_BRAND"

	TRACE_FUNC
}

_luks_cleanup() {
	# Unmount /media and close all LUKS usb_mount mappings.
	# Idempotent -- safe to call multiple times.
	umount /media 2>/dev/null || true
	for d in /dev/mapper/usb_mount_*; do
		[ -e "$d" ] && cryptsetup close "$(basename "$d")" 2>/dev/null || true
	done
	# Wipe reprovision temp secrets so error paths (and DIE) do not leave
	# PIN material behind, and drop the throwaway import keyring.
	for f in /tmp/secret/gpg_pin /tmp/secret/backup_pass \
		/tmp/secret/gpg_admin_pin /tmp/secret/gpg_backup_passphrase; do
		[ -e "$f" ] || continue
		shred -n 10 -z -u "$f" 2>/dev/null || rm -f "$f"
	done
	rm -rf /tmp/reprovision_gnupghome 2>/dev/null || true
	# Remove any master secret key material from the live keyring so it is
	# not left on disk on ANY exit path (success or error).  Idempotent.
	find "${GNUPGHOME:-$HOME/.gnupg}/private-keys-v1.d" \
		-name '*.key' -delete 2>/dev/null || true
}

reprovision_smartcard_from_backup() {
	TRACE_FUNC
	local admin_pin key_algo rsa_key_length key_name key_email key_comment
	local card_admin_pin key_id uid_line
	local algo_code bit_len tpm_counter_ok
	local reprovision_gnupghome=/tmp/reprovision_gnupghome
	local backup_pin_file=/tmp/secret/gpg_backup_passphrase

	enable_usb
	detect_usb_security_dongle_branding
	DEBUG "Dongle brand: $DONGLE_BRAND"

	STATUS "Checking for $DONGLE_BRAND smartcard"
	gpg --card-status >/dev/null 2>&1 || {
		whiptail_error --title 'ERROR: No Smartcard' \
			--msgbox "Please insert your $DONGLE_BRAND USB Security dongle." 0 80
		return 1
	}
	STATUS_OK "$DONGLE_BRAND smartcard accessible"

	while [ -z "$admin_pin" ]; do
		INPUT "Enter GPG key backup passphrase:" -r -s admin_pin
		[ -z "$admin_pin" ] && whiptail_error --title 'ERROR: Empty Passphrase' \
			--msgbox "The backup passphrase cannot be empty.\n\nEnter the passphrase that was used during\nOEM Factory Reset to create the backup." 0 80
	done
	DEBUG "Backup passphrase collected (${#admin_pin} chars)"

	# Phase 2: mount the LUKS private partition (read-only).
	enable_usb
	enable_usb_storage
	# Loading usb-storage.ko can reset the USB subsystem, making scdaemon's
	# existing CCID connection stale.  Kill it so the next gpg call starts
	# fresh (matching the OEM pattern in oem-factory-reset.sh).
	release_scdaemon
	mkdir -p /tmp/secret
	printf '%s' "$admin_pin" >/tmp/secret/backup_pass
	chmod 600 /tmp/secret/backup_pass 2>/dev/null || true
	STATUS "Mounting GPG key backup (LUKS private partition)"
	if ! mount-usb.sh --mode ro --mountpoint /media --pass-file /tmp/secret/backup_pass; then
		shred -n 10 -z -u /tmp/secret/backup_pass 2>/dev/null || rm -f /tmp/secret/backup_pass
		DEBUG "Could not mount backup LUKS partition"
		whiptail_error --title 'ERROR: Backup Mount Failed' \
			--msgbox "Could not mount the backup USB drive.\n\nVerify that the correct backup drive is inserted\nand the passphrase is correct." 0 80
		return 1
	fi
	shred -n 10 -z -u /tmp/secret/backup_pass 2>/dev/null || rm -f /tmp/secret/backup_pass
	DEBUG "LUKS partition mounted at /media"
	STATUS_OK "Backup LUKS partition mounted"

	if [ ! -f /media/privkey.sec ]; then
		_luks_cleanup
		WARN "privkey.sec not found on backup drive -- not a valid GPG key backup"
		whiptail_error --title 'ERROR: No Backup Found' \
			--msgbox "No privkey.sec found on this drive.\n\nThis does not appear to be a valid\nGPG key backup drive." 0 80
		return 1
	fi

	# Phase 3: import the private key (master + subkeys) into a throwaway
	# GNUPGHOME.  The running (ROM-loaded) keyring is left untouched until
	# the user confirms the destructive reprovision, so a bad passphrase or
	# import error can never leave an empty live keyring behind.
	mkdir -p "$reprovision_gnupghome"
	chmod 700 "$reprovision_gnupghome" 2>/dev/null || true
	mkdir -p /tmp/secret
	printf '%s' "$admin_pin" >"$backup_pin_file"
	chmod 600 "$backup_pin_file" 2>/dev/null || true
	STATUS "Importing GPG keys from backup"
	if ! GNUPGHOME="$reprovision_gnupghome" gpg --pinentry-mode=loopback \
		--passphrase-file "$backup_pin_file" \
		--import-options restore --import /media/privkey.sec >/dev/null 2>/tmp/gpg_import_err; then
		shred -n 10 -z -u "$backup_pin_file" 2>/dev/null || rm -f "$backup_pin_file"
		_luks_cleanup
		ERROR="$(cat /tmp/gpg_import_err)"
		WARN "GPG key import from backup failed: $(head -3 /tmp/gpg_import_err 2>/dev/null)"
		whiptail_error --title 'ERROR: Key Import Failed' \
			--msgbox "Failed to import GPG keys from backup.\n\n${ERROR}" 0 80
		return 1
	fi
	shred -n 10 -z -u "$backup_pin_file" 2>/dev/null || rm -f "$backup_pin_file"
	DEBUG "privkey.sec imported into throwaway keyring successfully"
	STATUS_OK "GPG keys imported"

	# Phase 4: detect key type and extract identity from the imported key.
	algo_code="$(GNUPGHOME="$reprovision_gnupghome" gpg --with-colons --list-keys 2>/dev/null | grep '^pub:' | cut -d: -f4 | head -1)" || true
	bit_len="$(GNUPGHOME="$reprovision_gnupghome" gpg --with-colons --list-keys 2>/dev/null | grep '^pub:' | cut -d: -f3 | head -1)" || true
	uid_line="$(GNUPGHOME="$reprovision_gnupghome" gpg --with-colons --list-keys 2>/dev/null | grep '^uid:' | head -1 | cut -d: -f10)" || true

	case "$algo_code" in
	1)
		key_algo="RSA"
		rsa_key_length="$bit_len"
		DEBUG "Detected RSA ${rsa_key_length}-bit key from backup"
		;;
	19)
		key_algo="p256"
		rsa_key_length=""
		DEBUG "Detected NIST P-256 key from backup"
		;;
	*)
		_luks_cleanup
		whiptail_error --title 'ERROR: Unknown Key Type' \
			--msgbox "Could not detect the key type from the backup\n(algorithm $algo_code).\n\nThe backup file may be corrupted." 0 80
		return 1
		;;
	esac

	if echo "$uid_line" | grep -q '('; then
		key_name="$(echo "$uid_line" | sed 's/ (.*//')"
		key_comment="$(echo "$uid_line" | sed 's/.*(//;s/).*//')"
	else
		key_name="$uid_line"
		key_comment=""
	fi
	# UID format is "Given Surname (comment) <email>"; strip any leftover
	# <email> portion from key_name so it never lands in the cardholder
	# name fields when no comment parens were present.
	key_name="$(echo "$key_name" | sed 's/ *<[^>]*>$//')"
	key_email="$(echo "$uid_line" | grep -o '<[^>]*>' | tr -d '<>' | head -1)" || true
	[ -z "$key_name" ] && key_name="$uid_line"

	if [ -n "$key_email" ]; then
		key_id="$key_email"
	else
		key_id="$(GNUPGHOME="$reprovision_gnupghome" gpg --list-secret-keys --with-colons 2>/dev/null | grep '^sec:' | cut -d: -f5 | head -1)" || true
		[ -z "$key_id" ] && {
			_luks_cleanup
			DIE "Could not determine key ID from imported backup"
		}
	fi
	DEBUG "Using key_id=$key_id (${key_email:+from email, }${key_email:-from fingerprint})"

	local key_fpr
	key_fpr="$(GNUPGHOME="$reprovision_gnupghome" gpg --with-colons --list-keys 2>/dev/null | grep '^fpr' | cut -d: -f10 | head -1)" || \
		DEBUG "Fingerprint extraction returned non-zero, continuing without it"

	DEBUG "Key fingerprint: $key_fpr"
	DEBUG "Backup key identity: name='$key_name' email='$key_email' comment='$key_comment' fingerprint='$key_fpr'"

	DEBUG "Checking $DONGLE_BRAND compatibility with $key_algo key"
	DEBUG "$key_algo key -- no dongle compatibility concern"

	DEBUG "Showing reprovision confirmation dialog to user"
	if ! whiptail_warning --title "Reprovision Smartcard" \
		--yesno "This will:\n\n  * ERASE all keys on your $DONGLE_BRAND\n  * Import GPG key: $key_name${key_comment:+ ($key_comment)}${key_email:+ <$key_email>}\n    Fingerprint: $key_fpr\n    (${key_algo}${rsa_key_length:+ $rsa_key_length-bit})\n  * Copy subkeys to the smartcard\n\nDo you want to continue?" 0 80; then
		_luks_cleanup
		DEBUG "User declined reprovision"
		return 1
	fi
	DEBUG "User confirmed reprovision; proceeding with factory reset"

	# Phase 4b: swap the validated backup keyring into the live keyring now
	# that the user confirmed the destructive reprovision.  Deferred so a bad
	# passphrase/import or a declined confirmation never leaves the running
	# keyring empty or polluted.
	rm -rf /.gnupg
	mkdir -p /.gnupg
	cp -a "$reprovision_gnupghome"/. /.gnupg/ 2>/dev/null || {
		_luks_cleanup
		DIE "Failed to activate imported keyring"
	}
	chmod 700 /.gnupg 2>/dev/null || true
	rm -rf "$reprovision_gnupghome" 2>/dev/null || true
	DEBUG "Activated imported keyring in ~/.gnupg"

	# Phase 5: factory-reset the smartcard and configure key attributes.
	card_admin_pin="12345678"
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
			while [ -z "$card_admin_pin" ]; do
				INPUT "Enter the current $DONGLE_BRAND admin PIN:" -r -s card_admin_pin
			done
			release_scdaemon
			gpg_reset_nk3_secret_app "$card_admin_pin" || \
				DEBUG "NK3 Secrets app reset with custom PIN also failed (non-fatal)"
		fi
	done
	if [ "$factory_reset_ok" != "y" ]; then
		_luks_cleanup
		ERROR="$(tail -n 3 /tmp/gpg_card_edit_output 2>/dev/null | fold -s)"
		WARN "Smartcard factory reset failed after retry with correct admin PIN"
		whiptail_error --title 'ERROR: Factory Reset Failed' \
			--msgbox "Could not factory reset the $DONGLE_BRAND smartcard.\n\n${ERROR}\n\nCheck that the admin PIN is correct." 0 80
		return 1
	fi

	card_admin_pin="12345678"

	# Phase 6: move subkeys from the local keyring to the smartcard.
	DEBUG "Starting keytocard with key_id=$key_id, admin_pin=${#admin_pin} chars, card_admin_pin=${#card_admin_pin} chars"
	if ! gpg_keytocard_subkeys "$key_id" "$admin_pin" "$card_admin_pin"; then
		_luks_cleanup
		ERROR="$(cat /tmp/gpg_card_edit_output)"
		WARN "GPG keytocard operation failed: $(head -3 /tmp/gpg_card_edit_output 2>/dev/null)"
		whiptail_error --title 'ERROR: Keytocard Failed' \
			--msgbox "Failed to move subkeys to smartcard.\n\n${ERROR}" 0 80
		return 1
	fi

	# Phase 7: set card identity from the backup key's UID
	gpg_set_card_identity "$key_name" "$key_email" "$card_admin_pin" || WARN "Could not set smartcard identity"

	# Phase 7b: prompt for custom PINs if desired.
	local pin_label_admin="GPG Admin PIN"
	[ "$DONGLE_BRAND" = "Nitrokey 3" ] && pin_label_admin="NK3 Secrets app PIN / GPG Admin PIN"

	if whiptail_warning --title "Set Custom PINs?" \
		--yesno "The card is currently using factory-default PINs\n(Admin: 12345678, User: 123456).\n\nWould you like to set custom PINs?" 0 80; then
		local new_admin_pin="" new_user_pin=""
		NOTE "${pin_label_admin}: for GPG card admin operations, 8-64 chars."
		while :; do
			INPUT "Enter new ${pin_label_admin} (8-64 chars):" -r -s new_admin_pin
			if [ -n "$new_admin_pin" ] && [ ${#new_admin_pin} -ge 8 ] && [ ${#new_admin_pin} -le 64 ]; then
				break
			fi
			NOTE "Invalid length: must be 8-64 chars."
		done
		if ! gpg_card_change_pin 3 "12345678" "$new_admin_pin"; then
			ERROR="$(cat /tmp/gpg_card_edit_output | fold -s)"
			whiptail_error --title 'ERROR: Admin PIN Change Failed' \
				--msgbox "Could not change the Admin PIN.\n\n${ERROR}" 0 80
			_luks_cleanup
			return 1
		fi

		release_scdaemon
		if gpg_reset_nk3_secret_app "$new_admin_pin"; then
			STATUS_OK "${pin_label_admin} changed"
		else
			WARN "GPG Admin PIN changed, but the NK3 Secrets app PIN update failed."
			WARN "HOTP will need the default PIN (12345678) until the Secrets app is reset."
		fi

		NOTE "GPG User PIN: signing /boot and encryption, 3 attempts max.\nRecommended: 2 diceware words (6-25 chars)"
		while :; do
			INPUT "Enter new GPG User PIN (6-25 chars):" -r -s new_user_pin
			if [ -n "$new_user_pin" ] && [ ${#new_user_pin} -ge 6 ] && [ ${#new_user_pin} -le 25 ]; then
				break
			fi
			NOTE "Invalid length: must be 6-25 chars."
		done
		if ! gpg_card_change_pin 1 "123456" "$new_user_pin"; then
			ERROR="$(cat /tmp/gpg_card_edit_output | fold -s)"
			whiptail_error --title 'ERROR: User PIN Change Failed' \
				--msgbox "Could not change the User PIN.\n\n${ERROR}" 0 80
			_luks_cleanup
			return 1
		fi
		STATUS_OK "GPG User PIN changed"
		printf '%s' "$new_user_pin" >/tmp/secret/gpg_pin
		chmod 600 /tmp/secret/gpg_pin 2>/dev/null || true
	else
		DEBUG "User declined custom PINs; keeping factory defaults"
		printf '%s' "123456" >/tmp/secret/gpg_pin
		chmod 600 /tmp/secret/gpg_pin 2>/dev/null || true
	fi

	# Phase 8: sign /boot so hashes exist on next boot.
	STATUS "Signing /boot files for next boot"
	detect_boot_device
	if mount -o remount,rw /boot 2>/tmp/sign_err; then
		# Preserve the existing manifests until the new set is signed and
		# passes verification, so a signing/verification failure cannot
		# leave /boot without valid boot signatures.
		local old_manifest_dir=/tmp/boot_manifests_backup
		rm -rf "$old_manifest_dir"
		mkdir -p "$old_manifest_dir"
		for f in /boot/kexec*.txt /boot/kexec.sig; do
			[ -e "$f" ] || continue
			cp -a "$f" "$old_manifest_dir/" 2>/dev/null || true
		done

		# Do not attempt counter creation when the TPM state is known
		# inconsistent (tpm_reset_required): the owner passphrase is unknown
		# and the counter cannot be created, so prompting for it would be a
		# dead end.  The reset-TPM guidance below then tells the user what
		# to do next (mirrors generate_totp_hotp / prompt_update_checksums).
		if [ "$CONFIG_TPM" = "y" ] && [ "$CONFIG_IGNORE_ROLLBACK" != "y" ] && ! tpm_reset_required; then
			tpmr.sh counter_create -pwdc '' -la -3135106223 >/tmp/counter || true
			local tpm_counter
			tpm_counter="$(cut -d: -f1 </tmp/counter 2>/dev/null)"
			if [ -n "$tpm_counter" ]; then
				increment_tpm_counter "$tpm_counter" || true
				sha256sum /tmp/counter-"$tpm_counter" >/boot/kexec_rollback.txt 2>/dev/null || true
				tpm_counter_ok="y"
			fi
		fi

		# Generate fresh kexec_hashes.txt and kexec_tree.txt in a subshell.
		# Pattern matches generate_checksums() in oem-factory-reset.sh:
		# cd /boot must be a standalone statement (not &&-chained through a
		# pipe) so that print_tree inherits the /boot working directory.
		(
			hash_pipeline_exit=0
			cd /boot
			find ./ -type f ! -path './kexec*' -print0 |
				xargs -0 sha256sum >/boot/kexec_hashes.txt 2>/dev/null ||
				hash_pipeline_exit=$?
			print_tree >/boot/kexec_tree.txt
			exit $hash_pipeline_exit
		) || DEBUG "Hash generation produced warnings"

		# Remove stale default manifests BEFORE collecting the files to sign,
		# so they are not included in (and invalidated by) the new signature.
		rm -f /boot/kexec_default.*.txt 2>/dev/null
		local param_files=()
		for f in /boot/kexec*.txt; do
			[ -e "$f" ] || continue
			param_files+=("$(basename "$f")")
		done
		local sign_ok="n"
		if (cd /boot && sha256sum "${param_files[@]}" 2>/dev/null | \
			gpg --detach-sign --pinentry-mode loopback \
				--passphrase-file /tmp/secret/gpg_pin \
				--digest-algo SHA256 -a -o /boot/kexec.sig 2>/tmp/sign_err); then
			if check_config /boot >/dev/null 2>/tmp/sign_err; then
				DEBUG "/boot signed and verified successfully"
				sign_ok="y"
				STATUS_OK "/boot files signed and ready"
			else
				WARN "/boot verification failed: $(head -3 /tmp/sign_err 2>/dev/null)"
			fi
		else
			WARN "/boot signing failed: $(head -3 /tmp/sign_err 2>/dev/null)"
		fi

		if [ "$sign_ok" != "y" ]; then
			# Restore the previous (valid) manifests so /boot is not left
			# without boot signatures, and do not proceed to flash/reboot.
			rm -f /boot/kexec*.txt /boot/kexec.sig 2>/dev/null
			cp -a "$old_manifest_dir"/. /boot/ 2>/dev/null || true
			rm -rf "$old_manifest_dir"
			mount -o ro,remount /boot 2>/dev/null || true
			_luks_cleanup
			WARN "Boot signature update failed; the smartcard was reprovisioned but /boot"
			WARN "signatures were NOT updated and no ROM flash will be performed."
			WARN "Re-sign /boot via Options -> Update checksums and sign all files in /boot."
			return 1
		fi
		rm -rf "$old_manifest_dir"
		mount -o ro,remount /boot 2>/dev/null || true
	else
		WARN "/boot not writable; skipping signing"
	fi

	# Phase 9: close LUKS and export public key from keyring.
	_luks_cleanup

	STATUS "Exporting public key for ROM flash"
	gpg --export --armor "$key_id" >/tmp/reprovision_pubkey.asc 2>/dev/null || {
		_luks_cleanup
		DIE "Failed to export public key for ROM flash"
	}
	PUBKEY=/tmp/reprovision_pubkey.asc
	DEBUG "Public key exported to $PUBKEY"

	# Establish ultimate trust on the key (needed for gpg_flash_rom + boot)
	gpg --list-keys --fingerprint --with-colons 2>/dev/null | \
		sed -E -n -e 's/^fpr:::::::::([0-9A-Fa-f]+):$/\1:6:/p' | \
		gpg --import-ownertrust >/dev/null 2>&1
	gpg --update-trust >/dev/null 2>&1
	DEBUG "Public key trusted in ~/.gnupg keyring"

	# Phase 10: set CONFIG_HAVE_GPG_KEY_BACKUP so future boots know a
	# backup exists, and offer to flash the public key + config to ROM.
	set_user_config "CONFIG_HAVE_GPG_KEY_BACKUP" "y"
	DEBUG "Set CONFIG_HAVE_GPG_KEY_BACKUP=y in /etc/config.user"
	combine_configs

	STATUS_OK "Smartcard reprovisioned"

	if [ "$CONFIG_TPM" = "y" ] && [ "$CONFIG_IGNORE_ROLLBACK" != "y" ] && [ "$tpm_counter_ok" != "y" ]; then
		WARN "TPM rollback counter was not created. Reset the TPM from"
		WARN "Options -> TPM/TOTP/HOTP Options -> Reset the TPM before"
		WARN "the next boot to avoid being dropped into recovery shell."
	fi

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
			fi
		else
			DEBUG "User declined ROM flash"
		fi
	fi

	DEBUG "Running cleanup: unmounting partitions and closing LUKS mappings"
	_luks_cleanup

	release_scdaemon
	find "${GNUPGHOME:-$HOME/.gnupg}/private-keys-v1.d" \
		-name '*.key' -delete >/dev/null 2>&1 || true

	shred -n 10 -z -u /tmp/secret/gpg_pin 2>/dev/null || rm -f /tmp/secret/gpg_pin
	DEBUG "Offering reboot to finalize provisioning"
	# Phase 8 already signs /boot, so re-signing is only needed after a TPM
	# reset (which regenerates the rollback counter and invalidates the
	# signatures).  Mirror the TPM-reset warning condition above.
	local reboot_msg
	if [ "$CONFIG_TPM" = "y" ] && [ "$CONFIG_IGNORE_ROLLBACK" != "y" ] && [ "$tpm_counter_ok" != "y" ]; then
		reboot_msg="The $DONGLE_BRAND smartcard has been reprovisioned\nfrom the GPG key backup.\n\nYou should reboot to finalize. After resetting the TPM,\nre-sign /boot via Options -> Update checksums and sign all files in /boot.\n\nReboot now?"
	else
		reboot_msg="The $DONGLE_BRAND smartcard has been reprovisioned\nfrom the GPG key backup.\n\nYou should reboot to finalize.\n\nReboot now?"
	fi
	if whiptail_warning --title 'Reboot?' --yesno "$reboot_msg" 0 80; then
		DEBUG "User accepted reboot"
		/bin/reboot.sh
	fi
	DEBUG "User declined reboot"

	unset admin_pin card_admin_pin
	TRACE_FUNC
}
