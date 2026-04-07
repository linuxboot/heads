#!/bin/bash
# Automated setup of TPM, GPG keys, and disk

# TODO: Find a stronger mechanism for passing GPG commands that avoids the
#       brittle --command-fd loop behavior. The current approach using
#       "quit" relies on internal GPG behavior (keyedit.c:1510-1513, :2227-2229)
#       and may break in future GPG versions.

set -o pipefail

## External files sourced
. /etc/functions.sh
. /etc/gui_functions.sh
. /etc/gpg_functions.sh
. /etc/luks-functions.sh
. /tmp/config

# Reset background color - may be inherited as "error" from TPM error menu
BG_COLOR_MAIN_MENU="normal"

# Allow firmware display in OEM reset context (flag may have been set during integrity report)
rm -f /tmp/hotpkey_fw_shown

TRACE_FUNC

# use TERM to exit on error
trap "exit 1" TERM
export TOP_PID=$$

## Static local variables

CLEAR="--clear"
CONTINUE="--yes-button Continue"
CANCEL="--no-button Cancel"
HEIGHT="0"
WIDTH="80"

# Default values
USER_PIN_DEF=123456
ADMIN_PIN_DEF=12345678
TPM_PASS_DEF=12345678
GPG_GEN_KEY_IN_MEMORY="n"
GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD="n"
GPG_EXPORT=0

#Circumvent Librem Key/Nitrokey HOTP firmware bug https://github.com/osresearch/heads/issues/1167
MAX_HOTP_GPG_PIN_LENGTH=25

# What are the Security components affected by custom passphrases
CUSTOM_PASS_AFFECTED_COMPONENTS=""

# Default GPG Algorithm is RSA (key length set by RSA_KEY_LENGTH below)
# NIST P-256 also supported for Nitrokey 3 (chose NIST P-256 when RSA was not generated into secrets app)
GPG_ALGO="RSA"
# Default RSA key length is 3072 bits for OEM key gen
# 4096 are way longer to generate in smartcard
RSA_KEY_LENGTH=3072

# If we use complex generated passphrases, we will really try hard to make the
# user record them
MAKE_USER_RECORD_PASSPHRASES=

# Function to handle --mode parameter
handle_mode() {
	TRACE_FUNC
	local mode=$1
	case $mode in
	oem)
		DEBUG "OEM mode selected"
		CUSTOM_SINGLE_PASS=$(generate_passphrase --number_words 2 --max_length $MAX_HOTP_GPG_PIN_LENGTH)
		USER_PIN=$CUSTOM_SINGLE_PASS
		ADMIN_PIN=$CUSTOM_SINGLE_PASS
		TPM_PASS=$CUSTOM_SINGLE_PASS
		# User doesn't know this passphrase, really badger them to record it
		MAKE_USER_RECORD_PASSPHRASES=y

		title_text="OEM Factory Reset Mode"
		;;
	user)
		DEBUG "User mode selected"
		USER_PIN=$(generate_passphrase --number_words 2 --max_length $MAX_HOTP_GPG_PIN_LENGTH)
		ADMIN_PIN=$(generate_passphrase --number_words 2 --max_length $MAX_HOTP_GPG_PIN_LENGTH)
		TPM_PASS=$ADMIN_PIN
		# User doesn't know this passphrase, really badger them to record it
		MAKE_USER_RECORD_PASSPHRASES=y

		title_text="User Re-Ownership Mode"
		;;
	*)
		WARN "Unknown oem-factory-reset.sh launched mode, setting PINs to weak defaults"
		USER_PIN=$USER_PIN_DEF
		ADMIN_PIN=$ADMIN_PIN_DEF
		TPM_PASS=$ADMIN_PIN_DEF
		;;
	esac
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
	key="$1"
	case $key in
	--mode)
		MODE="$2"
		shift # past argument
		shift # past value
		;;
	*)
		shift # past unrecognized argument
		;;
	esac
done

# Handle the --mode parameter if provided
if [[ -n "$MODE" ]]; then
	handle_mode "$MODE"
fi

#Override RSA_KEY_LENGTH to 2048 bits for Canokey under qemu testing boards until canokey fixes
if [[ "$CONFIG_BOARD_NAME" == qemu-* ]] && [[ "$DONGLE_BRAND" == "Canokey" ]]; then
	DEBUG "Overriding RSA_KEY_LENGTH to 2048 bits for Canokey under qemu testing boards"
	RSA_KEY_LENGTH=2048
fi

GPG_USER_NAME="OEM Key"
GPG_KEY_NAME=$(date +%Y%m%d%H%M%S)
GPG_USER_MAIL="oem-${GPG_KEY_NAME}@example.com"
GPG_USER_COMMENT="OEM-generated key"
SKIP_BOOT="n"

## functions

DIE() {
	local msg=$1
	if [ -n "$msg" ]; then
		WARN "$msg"
	fi
	kill -s TERM $TOP_PID
	exit 1
}

local_whiptail_error() {
	TRACE_FUNC
	local msg=$1
	if [ "$msg" = "" ]; then
		DIE "whiptail error: An error msg is required"
	fi
	whiptail_error --msgbox "${msg}\n\n" $HEIGHT $WIDTH --title "Error"
}

whiptail_error_die() {
	local_whiptail_error "$@"
	DIE
}

mount_boot() {
	TRACE_FUNC
	# Mount local disk if it is not already mounted.
	# Added so that 'o' can be typed early at boot to enter directly into OEM Factory Reset
	if ! grep -q /boot /proc/mounts; then
		# try to mount if CONFIG_BOOT_DEV exists
		if [ -e "$CONFIG_BOOT_DEV" ]; then
			mount -o ro $CONFIG_BOOT_DEV /boot || DIE "Failed to mount $CONFIG_BOOT_DEV. Please change boot device under Configuration > Boot Device"
		fi
	fi
}

reset_nk3_secret_app() {
	TRACE_FUNC

	# Reset Nitrokey 3 Secrets app PIN with $ADMIN_PIN (default 12345678, or customised)
	if [ "$DONGLE_BRAND" = "Nitrokey 3" ] && [ -x /bin/hotp_verification ]; then
		STATUS "Resetting Nitrokey 3 Secrets app (physical touch will be required)"
		# TODO: change message when https://github.com/Nitrokey/nitrokey-hotp-verification/issues/41 is fixed
		# Reset Nitrokey 3 secret app with PIN
		# Do 3 attempts to reset Nitrokey 3 Secrets app if return code is 3 (no touch)
		for attempt in 1 2 3; do
			if hotp_verification reset "${ADMIN_PIN}"; then
				STATUS_OK "Nitrokey 3 Secrets app reset"
				return 0
			else
				error_code=$?
				if [ $error_code -eq 3 ] && [ $attempt -lt 3 ]; then
					whiptail_warning --msgbox "Nitrokey 3 requires physical presence: touch the dongle when requested" $HEIGHT $WIDTH --title "Nk3 secrets app reset attempt: $attempt/3"
				else
					whiptail_error_die "Nitrokey 3's Secrets app reset failed with error:$error_code. Contact Nitrokey support"
				fi
			fi
		done
	fi
}

#Generate a gpg master key: no expiration date, ${RSA_KEY_LENGTH} bits
#This key will be used to sign 3 subkeys: encryption, authentication and signing
#The master key and subkeys will be copied to backup, and the subkeys moved from memory keyring to the smartcard
generate_inmemory_RSA_master_and_subkeys() {
	TRACE_FUNC

	STATUS "Generating RSA ${RSA_KEY_LENGTH}-bit master key for $DONGLE_BRAND"
	# Generate GPG master key
	{
		echo "Key-Type: RSA"                     # RSA key
		echo "Key-Length: ${RSA_KEY_LENGTH}"     # RSA key length
		echo "Key-Usage: sign"                   # RSA key usage
		echo "Name-Real: ${GPG_USER_NAME}"       # User name
		echo "Name-Comment: ${GPG_USER_COMMENT}" # User comment
		echo "Name-Email: ${GPG_USER_MAIL}"      # User email
		echo "Expire-Date: 0"                    # No expiration date
		echo "Passphrase: ${ADMIN_PIN}"          # Admin PIN
		echo "%commit"                           # Commit changes
	} | DO_WITH_DEBUG gpg --expert --batch --command-fd=0 --status-fd=1 --pinentry-mode=loopback --generate-key >/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG on-card RSA key generation output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		ERROR=$(cat /tmp/gpg_card_edit_output)
		whiptail_error_die "GPG Key generation failed!\n\n$ERROR"
	fi

	STATUS "Generating RSA signing subkey for $DONGLE_BRAND"
	# Add signing subkey
	{
		echo addkey            # add key in --edit-key mode
		echo 4                 # RSA (sign only)
		echo ${RSA_KEY_LENGTH} # Signing key size set to RSA_KEY_LENGTH
		echo 0                 # No expiration date
		echo ${ADMIN_PIN}      # Local keyring admin pin (passphrase requested before key creation, no confirm prompt)
		echo save              # save changes and commit to keyring
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback --edit-key "${GPG_USER_MAIL}" \
		>/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG RSA signing subkey output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		ERROR=$(cat /tmp/gpg_card_edit_output)
		whiptail_error_die "GPG Key signing subkey generation failed!\n\n$ERROR"
	fi

	STATUS "Generating RSA encryption subkey for $DONGLE_BRAND"
	#Add encryption subkey
	{
		echo addkey            # add key in --edit-key mode
		echo 6                 # RSA (encrypt only)
		echo ${RSA_KEY_LENGTH} # Encryption key size set to RSA_KEY_LENGTH
		echo 0                 # No expiration date
		echo ${ADMIN_PIN}      # Local keyring admin pin (passphrase requested before key creation, no confirm prompt)
		echo save              # save changes and commit to keyring
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback --edit-key "${GPG_USER_MAIL}" \
		>/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG RSA encryption subkey output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		ERROR=$(cat /tmp/gpg_card_edit_output)
		whiptail_error_die "GPG Key encryption subkey generation failed!\n\n$ERROR"
	fi

	STATUS "Generating RSA authentication subkey for $DONGLE_BRAND"
	#Add authentication subkey
	{
		#Authentication subkey needs gpg in expert mode to select RSA custom mode (8)
		# in order to disable encryption and signing capabilities of subkey
		# and then enable authentication capability
		echo addkey            # add key in --edit-key mode
		echo 8                 # RSA (set your own capabilities)
		echo S                 # disable sign capability
		echo E                 # disable encryption capability
		echo A                 # enable authentication capability
		echo Q                 # Quit
		echo ${RSA_KEY_LENGTH} # Authentication key size set to RSA_KEY_LENGTH
		echo 0                 # No expiration date
		echo ${ADMIN_PIN}      # Local keyring admin pin (passphrase requested before key creation, no confirm prompt)
		echo save              # save changes and commit to keyring
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback --expert --edit-key "${GPG_USER_MAIL}" \
		>/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG RSA authentication subkey output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		ERROR=$(cat /tmp/gpg_card_edit_output)
		whiptail_error_die "GPG Key authentication subkey generation failed!\n\n$ERROR"
	fi
}

#Generate a gpg master key: no expiration date, NIST P-256 key (ECC)
#This key will be used to sign 3 subkeys: encryption, authentication and signing
#The master key and subkeys will be copied to backup, and the subkeys moved from memory keyring to the smartcard
generate_inmemory_p256_master_and_subkeys() {
	TRACE_FUNC

	STATUS "Generating NIST P-256 master key for $DONGLE_BRAND"
	DEBUG "GPG batch key generation: Key-Type=ECDSA, Key-Curve=nistp256, Key-Usage=cert"
	{
		echo "Key-Type: ECDSA"                   # ECDSA key
		echo "Key-Curve: nistp256"               # ECDSA key curve
		echo "Key-Usage: cert"                   # ECDSA key usage
		echo "Name-Real: ${GPG_USER_NAME}"       # User name
		echo "Name-Comment: ${GPG_USER_COMMENT}" # User comment
		echo "Name-Email: ${GPG_USER_MAIL}"      # User email
		echo "Passphrase: ${ADMIN_PIN}"          # Local keyring admin pin
		echo "Expire-Date: 0"                    # No expiration date
		echo "%commit"                           # Commit changes
	} | DO_WITH_DEBUG gpg --expert --batch --command-fd=0 --status-fd=1 --pinentry-mode=loopback --generate-key \
		>/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG p256 master key generation output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		ERROR=$(cat /tmp/gpg_card_edit_output)
		whiptail_error_die "GPG NIST P-256 Key generation failed!\n\n$ERROR"
	fi

	#Keep Master key fingerprint for add key calls
	MASTER_KEY_FP=$(gpg --list-secret-keys --with-colons | grep fpr | cut -d: -f10)

	STATUS "Generating NIST P-256 signing subkey for $DONGLE_BRAND"
	{
		echo addkey       # add key in --edit-key mode
		echo 11           # ECC own set capability
		echo Q            # sign already present, do not modify
		echo 3            # P-256
		echo 0            # No validity/expiration date
		echo ${ADMIN_PIN} # Local keyring admin pin
		echo save         # save changes and commit to keyring
	} | DO_WITH_DEBUG gpg --expert --command-fd=0 --status-fd=1 --pinentry-mode=loopback --edit-key ${MASTER_KEY_FP} >/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG p256 signing subkey output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		ERROR_MSG=$(cat /tmp/gpg_card_edit_output)
		whiptail_error_die "Failed to add ECC nistp256 signing key to master key\n\n${ERROR_MSG}"
	fi

	STATUS "Generating NIST P-256 encryption subkey for $DONGLE_BRAND"
	{
		echo addkey
		echo 12           # ECC own set capability
		echo 3            # P-256
		echo 0            # No validity/expiration date
		echo ${ADMIN_PIN} # Local keyring admin pin
		echo save         # save changes and commit to keyring
	} | DO_WITH_DEBUG gpg --expert --command-fd=0 --status-fd=1 --pinentry-mode=loopback --edit-key ${MASTER_KEY_FP} >/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG p256 encryption subkey output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		ERROR_MSG=$(cat /tmp/gpg_card_edit_output)
		whiptail_error_die "Failed to add ECC nistp256 encryption key to master key\n\n${ERROR_MSG}"
	fi

	STATUS "Generating NIST P-256 authentication subkey for $DONGLE_BRAND"
	{
		echo addkey       # add key in --edit-key mode
		echo 11           # ECC own set capability
		echo S            # deactivate sign
		echo A            # activate auth
		echo Q            # Quit
		echo 3            # P-256
		echo 0            # no expiration
		echo ${ADMIN_PIN} # Local keyring admin pin
		echo save         # save changes and commit to keyring
	} | DO_WITH_DEBUG gpg --expert --command-fd=0 --status-fd=1 --pinentry-mode=loopback --edit-key ${MASTER_KEY_FP} >/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG p256 authentication subkey output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		ERROR_MSG=$(cat /tmp/gpg_card_edit_output)
		whiptail_error_die "Failed to add ECC nistp256 authentication key to master key\n\n${ERROR_MSG}"
	fi

}

#Function to move current gpg keyring subkeys to card (keytocard)
# This is aimed to be used after having generated master key and subkeys in memory and having backed up them to a LUKS container
# This function will keytocard the subkeys from the master key in the keyring
# The master key will be kept in the keyring
# The master key was already used to sign the subkeys, so it is not needed anymore
# Delete the master key from the keyring once key to card is done (already backed up on LUKS private partition)
keytocard_subkeys_to_smartcard() {
	TRACE_FUNC

	#make sure usb ready and USB Security dongle ready to communicate with
	enable_usb
	enable_usb_storage
	STATUS "Accessing $DONGLE_BRAND OpenPGP smartcard"
	gpg --card-status >/dev/null 2>&1 || DIE "Error getting GPG card status"

	gpg_key_factory_reset

	STATUS "Moving subkeys to $DONGLE_BRAND"
	{
		echo "key 1"            #Toggle on Signature key in --edit-key mode on local keyring
		echo "keytocard"        #Move Signature key to smartcard
		echo "1"                #Select Signature key key slot on smartcard
		echo "${ADMIN_PIN}"     #Local keyring Subkey PIN
		echo "${ADMIN_PIN_DEF}" #Smartcard Admin PIN (prompted once; scdaemon caches it for subsequent keytocard ops)
		echo "key 1"            #Toggle off Signature key
		echo "key 2"            #Toggle on Encryption key
		echo "keytocard"        #Move Encryption key to smartcard
		echo "2"                #Select Encryption key key slot on smartcard
		echo "${ADMIN_PIN}"     #Local keyring Subkey PIN (card PIN already cached by scdaemon)
		echo "key 2"            #Toggle off Encryption key
		echo "key 3"            #Toggle on Authentication key
		echo "keytocard"        #Move Authentication key to smartcard
		echo "3"                #Select Authentication key slot on smartcard
		echo "${ADMIN_PIN}"     #Local keyring Subkey PIN (card PIN still cached by scdaemon)
		echo "key 3"            #Toggle off Authentication key
		echo "save"             #Save changes and commit to keyring
	} | DO_WITH_DEBUG gpg --expert --command-fd=0 --status-fd=1 --pinentry-mode=loopback --edit-key "${GPG_USER_MAIL}" \
		>/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG keytocard output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		ERROR=$(cat /tmp/gpg_card_edit_output)
		whiptail_error_die "GPG Key moving subkeys to smartcard failed!\n\n$ERROR"
	fi
	STATUS_OK "Subkeys moved to smartcard"

	TRACE_FUNC
}

#Whiptail prompt to insert to be wiped thumb drive
prompt_insert_to_be_wiped_thumb_drive() {
	TRACE_FUNC
	#Whiptail warning about having only desired to be wiped thumb drive inserted
	whiptail_warning --title 'WARNING: Please insert the thumb drive to be wiped' \
		--msgbox "The thumb drive will be WIPED next.\n\nPlease connect only the thumb drive to be wiped and disconnect others." 0 80 ||
		DIE "Error displaying warning about having only desired to be wiped thumb drive inserted"
}

set_card_identity() {
	TRACE_FUNC

	# Determine which fields we have custom values for
	local set_name=0 set_login=0
	local surname given

	# Name: skip if still the OEM default
	if [ "$GPG_USER_NAME" != "OEM Key" ] && [ -n "$GPG_USER_NAME" ]; then
		set_name=1
		# OpenPGP card stores surname and given name separately;
		# gpg displays them as "given surname"
		if [[ "$GPG_USER_NAME" == *" "* ]]; then
			given="${GPG_USER_NAME% *}"
			surname="${GPG_USER_NAME##* }"
		else
			surname="$GPG_USER_NAME"
			given=""
		fi
		DEBUG "Will set cardholder name: surname='$surname' given='$given'"
	else
		DEBUG "Skipping cardholder name: no custom name set"
	fi

	# Login: skip if still the auto-generated OEM default (oem-*@example.com)
	if [ -n "$GPG_USER_MAIL" ] && [[ "$GPG_USER_MAIL" != oem-*@example.com ]]; then
		set_login=1
		DEBUG "Will set login data: '$GPG_USER_MAIL'"
	else
		DEBUG "Skipping login data: no custom email set"
	fi

	[ "$set_name" -eq 0 ] && [ "$set_login" -eq 0 ] && return

	STATUS "Setting identity fields on OpenPGP smartcard"
	{
		echo "admin"
		if [ "$set_name" -eq 1 ]; then
			echo "name"
			echo "${surname}"
			echo "${given}"
			# scdaemon caches the admin PIN from the preceding keytocard/generate
			# session; name and login do not re-prompt for it
		fi
		if [ "$set_login" -eq 1 ]; then
			echo "login"
			echo "${GPG_USER_MAIL}"
			# scdaemon admin PIN still cached; no re-prompt needed
		fi
		echo "quit"
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=2 --pinentry-mode=loopback --card-edit ||
		DIE "Failed to set identity fields on OpenPGP smartcard"

	local summary=""
	[ "$set_name" -eq 1 ] && summary="${given:+$given }${surname}"
	[ "$set_login" -eq 1 ] && summary="${summary:+$summary, }${GPG_USER_MAIL}"
	STATUS_OK "Card identity set: $summary"
	#TODO: set card `url` field and GPG key preferred keyserver after uploading to keys.openpgp.org
	# Two separate operations needed:
	#   1. card `url`  — set via gpg --card-edit admin → url → <fetch_url>
	#   2. key `keyserver` preference — set via gpg --edit-key → keyserver → <url> → save
	#      (applies to both on-card and in-memory key paths)
	# Requires: network access in initrd, curl, and user email verification on keyserver.
	# Note: keys.openpgp.org hides UID until owner verifies email — upload works but key
	# is not searchable by email until verified from a normal OS session after provisioning.
}

#export master key and subkeys to thumbdrive's private LUKS contained partition
export_master_key_subkeys_and_revocation_key_to_private_LUKS_container() {
	TRACE_FUNC

	#Sanity check on passed arguments
	while [ $# -gt 0 ]; do
		case "$1" in
		--mode)
			mode="$2"
			shift
			shift
			;;
		--device)
			device="$2"
			shift
			shift
			;;
		--mountpoint)
			mountpoint="$2"
			shift
			shift
			;;
		--pass)
			pass="${2}"
			shift
			shift
			;;
		*)
			DIE "Error: unknown argument: $1"
			;;
		esac
	done

	mount-usb.sh --mode "$mode" --device "$device" --mountpoint "$mountpoint" --pass "$pass" || DIE "Error mounting thumb drive's private partition"

	#Export master key and subkeys to thumb drive
	STATUS "Exporting master key and subkeys to backup LUKS container"

	if gpg --export-secret-key --armor --pinentry-mode loopback --passphrase="${pass}" "${GPG_USER_MAIL}" >"$mountpoint"/privkey.sec 2>/tmp/gpg_export_err; then
		DEBUG "GPG master key export succeeded"
	else
		DEBUG "GPG master key export failed: $(cat /tmp/gpg_export_err)"
		DIE "Error exporting master key to private LUKS container's partition"
	fi
	if gpg --export-secret-subkeys --armor --pinentry-mode loopback --passphrase="${pass}" "${GPG_USER_MAIL}" >"$mountpoint"/subkeys.sec 2>/tmp/gpg_export_err; then
		DEBUG "GPG subkeys export succeeded"
	else
		DEBUG "GPG subkeys export failed: $(cat /tmp/gpg_export_err)"
		DIE "Error exporting subkeys to private LUKS container's partition"
	fi
	#copy whole keyring to thumb drive, including revocation key and trust database
	cp -af ~/.gnupg "$mountpoint"/.gnupg || DIE "Error copying whole keyring to private LUKS container's partition"
	#Unmount private LUKS container's mount point
	umount "$mountpoint" || DIE "Error unmounting private LUKS container's mount point"
	STATUS_OK "Master key and subkeys backed up to USB"

	TRACE_FUNC
}

#Export public key to thumb drive's public partition
export_public_key_to_thumbdrive_public_partition() {
	TRACE_FUNC

	#Sanity check on passed arguments
	while [ $# -gt 0 ]; do
		case "$1" in
		--mode)
			mode="$2"
			shift
			shift
			;;
		--device)
			device="$2"
			shift
			shift
			;;
		--mountpoint)
			mountpoint="$2"
			shift
			shift
			;;
		*)
			DIE "Error: unknown argument: $1"
			;;
		esac
	done

	#pass non-empty arguments to --pass, --mountpoint, --device, --mode
	mount-usb.sh --device "$device" --mode "$mode" --mountpoint "$mountpoint" || DIE "Error mounting thumb drive's public partition"
	#TODO: reuse "Obtain GPG key ID" so that pubkey on public thumb drive partition is named after key ID
	STATUS "Exporting public key to USB"
	if gpg --export --armor "${GPG_USER_MAIL}" >"$mountpoint"/pubkey.asc 2>/tmp/gpg_export_err; then
		DEBUG "GPG public key export succeeded"
	else
		DEBUG "GPG public key export failed: $(cat /tmp/gpg_export_err)"
		DIE "Error exporting public key to thumb drive's public partition"
	fi
	umount "$mountpoint" || DIE "Error unmounting thumb drive's public partition"
	STATUS_OK "Public key exported to USB"

	TRACE_FUNC
}

# Select thumb drive and LUKS container size for GPG key export
# Sets variables containing selections:
# - thumb_drive
# - thumb_drive_luks_percent
select_thumb_drive_for_key_material() {
	TRACE_FUNC

	#enable usb storage
	enable_usb
	enable_usb_storage

	prompt_insert_to_be_wiped_thumb_drive

	#loop until user chooses a disk
	thumb_drive=""
	while [ -z "$thumb_drive" ]; do
		#list usb storage devices
		list_usb_storage disks >/tmp/usb_disk_list
		# Abort if:
		# - no disks found (prevent file_selector's nonsense prompt)
		# - file_selector fails for any reason
		# - user aborts (file_selector succeeds but FILE is empty)
		if [ $(cat /tmp/usb_disk_list | wc -l) -gt 0 ] &&
			file_selector --show-size "/tmp/usb_disk_list" "Select USB device to partition" &&
			[ -n "$FILE" ]; then
			# Obtain size of thumb drive to be wiped with fdisk
			disk_size_bytes="$(blockdev --getsize64 "$FILE")"
			if [ "$disk_size_bytes" -lt "$((128 * 1024 * 1024))" ]; then
				WARN "Thumb drive size is less than 128MB!"
				WARN "LUKS container needs to be at least 8MB!"
				WARN "If the next operation fails, try with a bigger thumb drive"
			fi

			select_luks_container_size_percent
			thumb_drive_luks_percent="$(cat /tmp/luks_container_size_percent)"

			if ! confirm_thumb_drive_format "$FILE" "$thumb_drive_luks_percent"; then
				INFO "Thumb drive wipe aborted by user"
				continue
			fi

			#User chose and confirmed a thumb drive and its size to be wiped
			thumb_drive=$FILE
		else
			#No USB storage device detected
			WARN "No USB storage device detected! Aborting OEM Factory Reset / Re-Ownership"
			sleep 3
			DIE "No USB storage device detected! User decided to not wipe any thumb drive"
		fi
	done
}

#Wipe a thumb drive and export master key and subkeys to it
# $1 - thumb drive block device
# $2 - LUKS container percentage [1-99]
wipe_thumb_drive_and_copy_gpg_key_material() {
	TRACE_FUNC

	local thumb_drive thumb_drive_luks_percent
	thumb_drive="$1"
	thumb_drive_luks_percent="$2"

	#Wipe thumb drive with a LUKS container of size $(cat /tmp/luks_container_size_percent)
	prepare_thumb_drive "$thumb_drive" "$thumb_drive_luks_percent" "${ADMIN_PIN}"
	#Export master key and subkeys to thumb drive first partition
	export_master_key_subkeys_and_revocation_key_to_private_LUKS_container --mode rw --device "$thumb_drive"1 --mountpoint /media --pass "${ADMIN_PIN}"
	#Export public key to thumb drive's public partition
	export_public_key_to_thumbdrive_public_partition --mode rw --device "$thumb_drive"2 --mountpoint /media

	TRACE_FUNC
}

gpg_key_factory_reset() {
	TRACE_FUNC

	#enable usb storage
	enable_usb

	# Factory reset GPG card
	STATUS "GPG factory reset of $DONGLE_BRAND OpenPGP smartcard"
	{
		echo admin         # admin menu
		echo factory-reset # factory reset smartcard
		echo y             # confirm
		echo yes           # confirm
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback --card-edit \
		>/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG factory-reset output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		ERROR=$(cat /tmp/gpg_card_edit_output)
		whiptail_error_die "GPG Key factory reset failed!\n\n$ERROR"
	fi

	# If Nitrokey Storage is inserted, reset AES keys as well
	if [ "$DONGLE_BRAND" = "Nitrokey Storage" ] && [ -x /bin/hotp_verification ]; then
		STATUS "Resetting Nitrokey Storage AES keys"
		hotp_verification regenerate ${ADMIN_PIN_DEF}
		STATUS_OK "Nitrokey Storage AES keys reset"
	fi

	# Toggle forced sig (good security practice, forcing PIN request for each signature request)
	if gpg --card-status | grep "Signature PIN" | grep -q "not forced"; then
		STATUS "Enabling forced signature PIN on smartcard"
		{
			echo admin            # admin menu
			echo forcesig         # toggle forcesig
			echo ${ADMIN_PIN_DEF} # local keyring PIN
		} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback --card-edit \
			>/tmp/gpg_card_edit_output 2>&1
		TRACE_FUNC
		DEBUG "GPG forcesig toggle output: $(cat /tmp/gpg_card_edit_output)"
		if [ $? -ne 0 ]; then
			ERROR=$(cat /tmp/gpg_card_edit_output)
			whiptail_error_die "GPG Key forcesig toggle on failed!\n\n$ERROR"
		fi
		STATUS_OK "Forced signature PIN enabled"
	fi

	# use NIST P-256 for key generation if requested
	if [ "$GPG_ALGO" = "p256" ]; then
		STATUS "Setting NIST-P256 key attributes on $DONGLE_BRAND"
		{
			echo admin            # admin menu
			echo key-attr         # key attributes
			echo 2                # ECC
			echo 3                # P-256
			echo ${ADMIN_PIN_DEF} # local keyring PIN
			echo 2                # ECC
			echo 3                # P-256
			echo ${ADMIN_PIN_DEF} # local keyring PIN
			echo 2                # ECC
			echo 3                # P-256
			echo ${ADMIN_PIN_DEF} # local keyring PIN
		} | DO_WITH_DEBUG gpg --expert --command-fd=0 --status-fd=1 --pinentry-mode=loopback --card-edit \
			>/tmp/gpg_card_edit_output 2>&1
		TRACE_FUNC
		DEBUG "GPG NIST-P256 key-attr output: $(cat /tmp/gpg_card_edit_output)"
		if [ $? -ne 0 ]; then
			ERROR=$(cat /tmp/gpg_card_edit_output)
			whiptail_error_die "Setting key to NIST-P256 in $DONGLE_BRAND failed."
		fi
		STATUS_OK "NIST-P256 key attributes set on $DONGLE_BRAND"
	# fallback to RSA key generation by default
	elif [ "$GPG_ALGO" = "RSA" ]; then
		STATUS "Setting RSA ${RSA_KEY_LENGTH}-bit key attributes on $DONGLE_BRAND (may take a minute)"
		# Set RSA key length
		{
			echo admin
			echo key-attr
			echo 1                 # RSA
			echo ${RSA_KEY_LENGTH} #Signing key size set to RSA_KEY_LENGTH
			echo ${ADMIN_PIN_DEF}  #Local keyring PIN
			echo 1                 # RSA
			echo ${RSA_KEY_LENGTH} #Encryption key size set to RSA_KEY_LENGTH
			echo ${ADMIN_PIN_DEF}  #Local keyring PIN
			echo 1                 # RSA
			echo ${RSA_KEY_LENGTH} #Authentication key size set to RSA_KEY_LENGTH
			echo ${ADMIN_PIN_DEF}  #Local keyring PIN
		} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback --card-edit \
			>/tmp/gpg_card_edit_output 2>&1
		TRACE_FUNC
		DEBUG "GPG RSA key-attr output: $(cat /tmp/gpg_card_edit_output)"
		if [ $? -ne 0 ]; then
			ERROR=$(cat /tmp/gpg_card_edit_output)
			whiptail_error_die "Setting key attributed to RSA ${RSA_KEY_LENGTH} bits in $DONGLE_BRAND failed."
		fi
		STATUS_OK "RSA ${RSA_KEY_LENGTH}-bit key attributes set on $DONGLE_BRAND"
	else
		#Unknown GPG_ALGO
		whiptail_error_die "Unknown GPG_ALGO: $GPG_ALGO"
	fi

	TRACE_FUNC
}

generate_OEM_gpg_keys() {
	TRACE_FUNC

	#This function simply generates subkeys in smartcard following smarcard config from gpg_key_factory_reset
	if [ "$GPG_ALGO" = "RSA" ]; then
		STATUS "Generating RSA ${RSA_KEY_LENGTH}-bit keys on $DONGLE_BRAND"
	else
		STATUS "Generating NIST P-256 keys on $DONGLE_BRAND"
	fi
	{
		echo admin               # admin menu
		echo generate            # generate keys
		echo n                   # Do not export keys
		echo ${ADMIN_PIN_DEF}    # Default admin PIN since we just factory reset
		echo ${USER_PIN_DEF}     # Default user PIN since we just factory reset
		echo 0                   # No key expiration
		echo ${GPG_USER_NAME}    # User name
		echo ${GPG_USER_MAIL}    # User email
		echo ${GPG_USER_COMMENT} # User comment
		echo ${USER_PIN_DEF}     # Default user PIN since we just factory reset
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=2 --pinentry-mode=loopback --card-edit \
		>/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG on-card key generation output: $(cat /tmp/gpg_card_edit_output)"
	#This outputs to console \
	# "gpg: checking the trustdb"
	# "gpg: 3 marginal(s) needed, 1 complete(s) needed, PGP trust model"
	# "gpg: depth: 0 valid: 1 signed: 0 trust: 0-, 0q, 0n, 0m, 0f, 1u"
	#TODO: Suppress this output to console (stdout shown in DEBUG mode)?
	if [ $? -ne 0 ]; then
		ERROR=$(cat /tmp/gpg_card_edit_output)
		whiptail_error_die "GPG Key automatic keygen failed!\n\n$ERROR"
	fi
	STATUS_OK "GPG keys generated on $DONGLE_BRAND"

	TRACE_FUNC
}

gpg_key_change_pin() {
	TRACE_FUNC

	# 1 = user PIN, 3 = admin PIN
	PIN_TYPE=$1
	PIN_ORIG=${2}
	PIN_NEW=${3}
	# Change PIN
	{
		echo admin       # admin menu
		echo passwd      # change PIN
		echo ${PIN_TYPE} # 1 = user PIN, 3 = admin PIN
		echo ${PIN_ORIG} # old PIN
		echo ${PIN_NEW}  # new PIN
		echo ${PIN_NEW}  # confirm new PIN
		echo q           # quit
		echo q
	} | DO_WITH_DEBUG gpg --command-fd=0 --status-fd=2 --pinentry-mode=loopback --card-edit \
		>/tmp/gpg_card_edit_output 2>&1
	TRACE_FUNC
	DEBUG "GPG PIN change output: $(cat /tmp/gpg_card_edit_output)"
	if [ $? -ne 0 ]; then
		ERROR=$(cat /tmp/gpg_card_edit_output | fold -s)
		whiptail_error_die "GPG Key PIN change failed!\n\n$ERROR"
	fi

	TRACE_FUNC
}

generate_checksums() {
	TRACE_FUNC

	# ensure /boot mounted
	if ! grep -q /boot /proc/mounts; then
		mount -o rw /boot || whiptail_error_die "Unable to mount /boot"
	else
		mount -o remount,rw /boot || whiptail_error_die "Unable to mount /boot"
	fi

	#Check if previous LUKS TPM Disk Unlock Key was set
	if [ -e /boot/kexec_key_devices.txt ]; then
		TPM_DISK_ENCRYPTION_KEY_SET=1
	fi

	# clear any existing checksums/signatures
	rm /boot/kexec* 2>/dev/null

	# create Heads TPM counter
	if [ "$CONFIG_TPM" = "y" ]; then
		if [ "$CONFIG_IGNORE_ROLLBACK" != "y" ]; then
			tpmr.sh counter_create \
				-pwdc "${TPM_PASS:-}" \
				-la -3135106223 |
				tee /tmp/counter >/dev/null 2>&1 ||
				whiptail_error_die "Unable to create TPM counter"
			TPM_COUNTER=$(cut -d: -f1 </tmp/counter)

			[ -n "$TPM_COUNTER" ] || whiptail_error_die "Unable to parse TPM counter id"

			# increment TPM counter so /tmp/counter-$TPM_COUNTER is populated,
			# then persist rollback metadata under /boot for next-boot preflight.
			increment_tpm_counter "$TPM_COUNTER" ||
				whiptail_error_die "Unable to increment TPM counter"

			[ -s /tmp/counter-"$TPM_COUNTER" ] ||
				whiptail_error_die "TPM counter increment did not produce counter state for rollback file"

			# create rollback file
			sha256sum /tmp/counter-"$TPM_COUNTER" >/boot/kexec_rollback.txt 2>/dev/null ||
				whiptail_error_die "Unable to create rollback file"
		fi

		# If HOTP is enabled from board config, create HOTP counter
		if [ -x /bin/hotp_verification ]; then
			## needs to exist for initial call to unseal-hotp.sh
			echo "0" >/boot/kexec_hotp_counter
		fi
	fi

	# set default boot option only if no LUKS TPM Disk Unlock Key previously set
	if [ -z "$TPM_DISK_ENCRYPTION_KEY_SET" ]; then
		set_default_boot_option
	fi

	STATUS "Generating /boot file hashes"
	(
		set -e -o pipefail
		cd /boot
		find ./ -type f ! -path './kexec*' -print0 |
			xargs -0 sha256sum >/boot/kexec_hashes.txt 2>/dev/null
		print_tree >/boot/kexec_tree.txt
	)
	[ $? -eq 0 ] || whiptail_error_die "Error generating kexec hashes"
	STATUS_OK "/boot file hashes generated"

	# Collect relative basenames so sha256sum output is path-independent and
	# matches what check_config produces when verifying (also uses cd+relative).
	param_files=()
	for f in /boot/kexec*.txt; do
		[ -e "$f" ] || continue
		param_files+=("$(basename "$f")")
	done
	[ ${#param_files[@]} -eq 0 ] &&
		whiptail_error_die "No kexec parameter files to sign"

	if [ "$GPG_GEN_KEY_IN_MEMORY" = "y" -a "$GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD" = "n" ]; then
		#The local keyring used to generate in memory subkeys is still valid since no key has been moved to smartcard
		#Local keyring passwd is ADMIN_PIN. We need to set USER_PIN to ADMIN_PIN to be able to sign next in this boot session
		DEBUG "Setting GPG User PIN to GPG Admin PIN so local keyring can be used to detach-sign kexec files next"
		USER_PIN=$ADMIN_PIN
	fi

	DEBUG "oem-factory-reset.sh: ${#param_files[@]} file(s) to sign (relative): ${param_files[*]}"
	DEBUG "oem-factory-reset.sh: signing with USER_PIN='$USER_PIN' (length=${#USER_PIN})"
	TRACE_FUNC

	if (cd /boot && sha256sum "${param_files[@]}") 2>/dev/null | gpg --detach-sign \
		--pinentry-mode loopback \
		--passphrase-file <(echo -n "$USER_PIN") \
		--digest-algo SHA256 \
		-a \
		>/boot/kexec.sig 2>/tmp/error; then
		DEBUG "oem-factory-reset.sh: signing succeeded, running check_config /boot"
		# successful - update the validated params
		if ! check_config /boot >/dev/null 2>/tmp/error; then
			cat /tmp/error
			ret=1
		else
			STATUS_OK "/boot files signed and verified"
			ret=0
		fi
	else
		DEBUG "oem-factory-reset.sh: signing failed: $(cat /tmp/error)"
		cat /tmp/error
		ret=1
	fi

	# done writing to /boot, switch back to RO
	mount -o ro,remount /boot

	if [ $ret = 1 ]; then
		ERROR=$(tail -n 1 /tmp/error | fold -s)
		whiptail_error_die "Error signing kexec boot files:\n\n$ERROR"
	fi

	TRACE_FUNC
}

set_default_boot_option() {
	TRACE_FUNC

	option_file="/tmp/kexec_options.txt"
	tmp_menu_file="/tmp/kexec/kexec_menu.txt"
	hash_file="/boot/kexec_default_hashes.txt"

	mkdir -p /tmp/kexec/
	rm $option_file 2>/dev/null
	# parse boot options from grub.cfg
	for i in $(find /boot -name "grub.cfg"); do
		kexec-parse-boot.sh "/boot" "$i" >>$option_file
	done
	# FC29/30+ may use BLS format grub config files
	# https://fedoraproject.org/wiki/Changes/BootLoaderSpecByDefault
	# only parse these if $option_file is still empty
	if [ ! -s $option_file ] && [ -d "/boot/loader/entries" ]; then
		for i in $(find /boot -name "grub.cfg"); do
			kexec-parse-bls.sh "/boot" "$i" "/boot/loader/entries" >>$option_file
		done
	fi
	[ ! -s $option_file ] &&
		whiptail_error_die "Failed to parse any boot options"

	# sort boot options
	sort -r $option_file | uniq >$tmp_menu_file

	## save first option as default
	entry=$(head -n 1 $tmp_menu_file | tail -1)

	# clear existing default configs
	rm "/boot/kexec_default.*.txt" 2>/dev/null

	# get correct index for entry
	index=$(grep -n "$entry" $option_file | cut -f1 -d ':')

	# write new config
	echo "$entry" >/boot/kexec_default.$index.txt

	# validate boot option
	(cd /boot && /bin/kexec-boot.sh -b "/boot" -e "$entry" -f |
		xargs sha256sum >$hash_file 2>/dev/null) ||
		whiptail_error_die "Failed to create hashes of boot files"

	TRACE_FUNC
}

usb_security_token_capabilities_check() {
	TRACE_FUNC

	enable_usb

	# Always detect dongle branding from USB VID:PID — never read a stored file.
	detect_usb_security_dongle_branding
	DEBUG "USB Security dongle detected: $DONGLE_BRAND"
	# Only show generic "Detected" if no specific brand was identified
	if [ "$DONGLE_BRAND" = "USB Security dongle" ]; then
		INFO "Detected $DONGLE_BRAND"
	else
		# Specific brand detected - firmware version will be shown below
		:
	fi
	STATUS "Checking $DONGLE_BRAND capabilities"

	# ... first set board config preference
	if [ -n "$CONFIG_GPG_ALGO" ]; then
		GPG_ALGO=$CONFIG_GPG_ALGO
		DEBUG "Setting GPG_ALGO to (board-)configured: $CONFIG_GPG_ALGO"
	fi
	# ... overwrite with usb-token capability
	# Nitrokey chose NIST P-256 when RSA was not generated into secrets app - TODO: review with lago changes
	# Canokey and other dongles use default RSA (see default GPG_ALGO above)
	if [ "$DONGLE_BRAND" = "Nitrokey 3" ]; then
		GPG_ALGO="p256"
		DEBUG "Nitrokey 3 detected: Setting GPG_ALGO to: $GPG_ALGO"
	fi

	# Show firmware version for USB Security dongle
	# Also capture firmware version for timing guidance in key generation message
	# Wait for gpg card to be ready before hotp_verification
	wait_for_gpg_card
	DONGLE_FW_VERSION=""
	if [ -x /bin/hotp_verification ]; then
		if hotp_token_info="$(hotp_verification info 2>/dev/null)"; then
			hotpkey_fw_display "$hotp_token_info" "$DONGLE_BRAND"
			# Capture firmware version for timing guidance
			if echo "$hotp_token_info" | grep -q "Firmware Nitrokey 3:"; then
				DONGLE_FW_VERSION="$(echo "$hotp_token_info" | grep "Firmware Nitrokey 3:" | sed 's/.*: *//')"
			elif echo "$hotp_token_info" | grep -q "Firmware:"; then
				DONGLE_FW_VERSION="$(echo "$hotp_token_info" | grep "Firmware:" | sed 's/.*: *//')"
				case "$DONGLE_FW_VERSION" in v*) ;; *) DONGLE_FW_VERSION="v$DONGLE_FW_VERSION" ;; esac
			fi
			DEBUG "Dongle firmware version: $DONGLE_FW_VERSION"
		fi
	fi
}

# usb_security_token_capabilities_check now handles all USB Security dongle logic

## main script start

# check for args
if [ -z "$title_text" ]; then
	title_text="OEM Factory Reset / Re-Ownership"
fi
if [ "$2" != "" ]; then
	bg_color=$2
else
	bg_color=""
fi

# show warning prompt
if [ "$CONFIG_TPM" = "y" ]; then
	TPM_STR="          * ERASE the TPM and own it with a passphrase\n"
else
	TPM_STR=""
fi
if ! whiptail_warning --yesno "
        This operation will automatically:\n
$TPM_STR
          * ERASE any keys or PINs on the GPG smart card,\n
            reset it to a factory state, generate new keys\n
            and optionally set custom PIN(s)\n
          * Add the new GPG key to the firmware and reflash it\n
          * Sign all of the files in /boot with the new GPG key\n\n
        It requires that you already have an OS installed on a\n
        dedicated /boot partition. Do you wish to continue?" \
	$HEIGHT $WIDTH $CONTINUE $CANCEL $CLEAR --title "$title_text"; then
	exit 1
fi

#Make sure /boot is mounted if board config defines default
mount_boot
# Show integrity report only when prior Heads trust metadata exists and it
# has not already been shown to the user (e.g. when called from the report menu).
if [ "${INTEGRITY_REPORT_ALREADY_SHOWN:-0}" = "1" ]; then
	DEBUG "Skipping integrity report in OEM Factory Reset: already shown to user before this call"
elif has_prior_boot_trust_metadata /boot/kexec_rollback.txt; then
	report_integrity_measurements
else
	DEBUG "Skipping integrity report in OEM Factory Reset: no prior /boot trust metadata detected (fresh first-ownership path)"
fi

# Clear the screen
clear

#Prompt user for use of default configuration options
TRACE_FUNC
INPUT "Would you like to use default configuration options? If N, you will be prompted for each option [Y/n]:" -n 1 use_defaults

if [ "$use_defaults" == "n" -o "$use_defaults" == "N" ]; then
	#Give general guidance to user on how to answer prompts
	STATUS "Factory Reset / Re-Ownership Questionnaire"
	INFO "The following questionnaire will help you configure the security components of your system"
	INFO "Each prompt requires a single letter answer (Y/n)"
	INFO "Pressing Enter selects the default answer for each prompt"
	TRACE_FUNC
	DEBUG "Showing passphrase guidance: QR code from diceware.dmuth.org"
	qrenc "https://diceware.dmuth.org/"
	NOTE "Scan the QR code above for passphrase guidance (diceware.dmuth.org):"

	# Re-ownership of LUKS encrypted Disk: key, content and passphrase
	INPUT "Would you like to change the current LUKS Disk Recovery Key passphrase? (Highly recommended if you didn't install the OS yourself) [y/N]:" -n 1 prompt_output
	if [ "$prompt_output" == "y" \
		-o "$prompt_output" == "Y" ]; then
		luks_new_Disk_Recovery_Key_passphrase_desired=1
		NOTE "Disk Recovery Key Passphrase: required to unlock disk, setup TPM Disk Unlock Key, access data from any computer, unsafe boot. DO NOT FORGET. Recommended: 6 words"
	fi

	INPUT "Would you like to re-encrypt LUKS container and generate new LUKS Disk Recovery Key? (Highly recommended if you didn't install the OS yourself) [y/N]:" -n 1 prompt_output
	if [ "$prompt_output" == "y" \
		-o "$prompt_output" == "Y" ]; then
		TRACE_FUNC
		test_luks_current_disk_recovery_key_passphrase
		luks_new_Disk_Recovery_Key_desired=1
		if [ "$luks_new_Disk_Recovery_Key_passphrase_desired" != "1" ]; then
			NOTE "Disk Recovery Key Passphrase: required to unlock disk, setup TPM Disk Unlock Key, access data from any computer, unsafe boot. DO NOT FORGET. Recommended: 6 words"
		fi
	fi

	#Prompt to ask if user wants to generate GPG key material in memory or on smartcard
	INPUT "Would you like to format an encrypted USB Thumb drive to store GPG key material? (Required to enable GPG authentication) [y/N]:" -n 1 prompt_output
	if [ "$prompt_output" == "y" \
		-o "$prompt_output" == "Y" ] \
		; then
		GPG_GEN_KEY_IN_MEMORY="y"
		INFO "Master key and subkeys will be generated in memory and backed up to a dedicated LUKS container"
		INPUT "Would you like in-memory generated subkeys to be copied to $DONGLE_BRAND's OpenPGP smartcard? (Highly recommended) [Y/n]:" -n 1 prompt_output
		if [ "$prompt_output" == "n" \
			-o "$prompt_output" == "N" ]; then
			NOTE "Subkeys will NOT be copied to $DONGLE_BRAND's OpenPGP smartcard"
			NOTE "Your GPG key material backup thumb drive should be cloned to a second thumb drive for redundancy for production environments"
			GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD="n"
		else
			INFO "Subkeys will be copied to $DONGLE_BRAND's OpenPGP smartcard"
			NOTE "Please keep your GPG key material backup thumb drive safe"
			GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD="y"
		fi
	else
		INFO "GPG key material will be generated on $DONGLE_BRAND's OpenPGP smartcard without backup"
		GPG_GEN_KEY_IN_MEMORY="n"
		GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD="n"
	fi

	# Dynamic messages to be given to user in terms of security components that will be applied
	#  based on previous answers
	CUSTOM_PASS_AFFECTED_COMPONENTS="\n"
	# Adapt message to be given to user in terms of security components that will be applied.
	if [ -n "$luks_new_Disk_Recovery_Key_passphrase_desired" -o -n "$luks_new_Disk_Recovery_Key_passphrase" ]; then
		CUSTOM_PASS_AFFECTED_COMPONENTS+="LUKS Disk Recovery Key passphrase\n"
	fi
	if [ "$CONFIG_TPM" = "y" ]; then
		CUSTOM_PASS_AFFECTED_COMPONENTS+="TPM Owner Passphrase\n"
	fi
	if [ "$GPG_GEN_KEY_IN_MEMORY" = "y" ]; then
		if [ "$DONGLE_BRAND" = "Nitrokey 3" ]; then
			CUSTOM_PASS_AFFECTED_COMPONENTS+="GPG Key material backup passphrase (Same as NK3 Secrets app PIN / GPG Admin PIN)\n"
		else
			CUSTOM_PASS_AFFECTED_COMPONENTS+="GPG Key material backup passphrase (Same as GPG Admin PIN)\n"
		fi
	fi
	if [ "$DONGLE_BRAND" = "Nitrokey 3" ]; then
		CUSTOM_PASS_AFFECTED_COMPONENTS+="NK3 Secrets app PIN / GPG Admin PIN\n"
	else
		CUSTOM_PASS_AFFECTED_COMPONENTS+="GPG Admin PIN\n"
	fi
	# Only show GPG User PIN as affected component if GPG_GEN_KEY_IN_MEMORY not requested or GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD is
	if [ "$GPG_GEN_KEY_IN_MEMORY" = "n" -o "$GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD" = "y" ]; then
		CUSTOM_PASS_AFFECTED_COMPONENTS+="GPG User PIN\n"
	fi

	# Inform user of security components affected for the following prompts
	INFO "The following Security Components will be configured with defaults or further chosen PINs/passphrases: $CUSTOM_PASS_AFFECTED_COMPONENTS"

	# Prompt to change default passphrases
	INPUT "Would you like to set a single custom passphrase to all previously stated security components? [y/N]:" -n 1 prompt_output
	if [ "$prompt_output" == "y" \
		-o "$prompt_output" == "Y" ]; then
		INFO "The chosen passphrase must be between 8 and $MAX_HOTP_GPG_PIN_LENGTH characters in length."
		while [[ ${#CUSTOM_SINGLE_PASS} -lt 8 ]] || [[ ${#CUSTOM_SINGLE_PASS} -gt $MAX_HOTP_GPG_PIN_LENGTH ]]; do
			INPUT "Enter the passphrase (8-${MAX_HOTP_GPG_PIN_LENGTH} chars):" -r CUSTOM_SINGLE_PASS
		done
		TPM_PASS=${CUSTOM_SINGLE_PASS}
		USER_PIN=${CUSTOM_SINGLE_PASS}
		ADMIN_PIN=${CUSTOM_SINGLE_PASS}

		# Only set if user said desired
		if [ -n "$luks_new_Disk_Recovery_Key_passphrase_desired" ]; then
			luks_new_Disk_Recovery_Key_passphrase=${CUSTOM_SINGLE_PASS}
		fi

		# The user knows this passphrase, we don't need to badger them to
		# record it
		MAKE_USER_RECORD_PASSPHRASES=
	else
		INPUT "Would you like to set distinct PINs/passphrases to configure previously stated security components? [y/N]:" -n 1 prompt_output
		if [ "$prompt_output" == "y" \
			-o "$prompt_output" == "Y" ]; then
			INFO "TPM Owner Passphrase and GPG Admin PIN must be at least 8 chars, GPG User PIN at least 6 chars."
			if [ "$CONFIG_TPM" = "y" ]; then
				NOTE "TPM Owner Passphrase: sets TPM ownership. Recommended: 2 words"
				while [[ ${#TPM_PASS} -lt 8 ]]; do
					INPUT "Enter desired TPM Owner Passphrase (min 8 chars):" -r TPM_PASS
				done
			fi
			if [ "$DONGLE_BRAND" = "Nitrokey 3" ]; then
				NOTE "NK3 Secrets app PIN / GPG Admin PIN: seals HOTP measurements and manages OpenPGP card. 3 attempts max. DO NOT FORGET. Recommended: 2 words"
				while [[ ${#ADMIN_PIN} -lt 6 ]] || [[ ${#ADMIN_PIN} -gt $MAX_HOTP_GPG_PIN_LENGTH ]]; do
					INPUT "Enter desired NK3 Secrets app PIN / GPG Admin PIN (6-${MAX_HOTP_GPG_PIN_LENGTH} chars):" -r ADMIN_PIN
				done
			else
				NOTE "GPG Admin PIN: management tasks on USB Security dongle, seal measurements under HOTP. 3 attempts max, locks Admin out. DO NOT FORGET. Recommended: 2 words"
				while [[ ${#ADMIN_PIN} -lt 6 ]] || [[ ${#ADMIN_PIN} -gt $MAX_HOTP_GPG_PIN_LENGTH ]]; do
					INPUT "Enter desired GPG Admin PIN (6-${MAX_HOTP_GPG_PIN_LENGTH} chars):" -r ADMIN_PIN
				done
			fi
			#USER PIN not required in case of GPG_GEN_KEY_IN_MEMORY not requested of if GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD is
			# That is, if keys were NOT generated in memory (on smartcard only) or
			#  if keys were generated in memory but are to be moved from local keyring to smartcard
			if [ "$GPG_GEN_KEY_IN_MEMORY" = "n" -o "$GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD" = "y" ]; then
				NOTE "GPG User PIN: sign/encrypt content, sign hashes under Heads. 3 attempts max. DO NOT FORGET. Recommended: 2 words"
				while [[ ${#USER_PIN} -lt 6 ]] || [[ ${#USER_PIN} -gt $MAX_HOTP_GPG_PIN_LENGTH ]]; do
					INPUT "Enter desired GPG User PIN (6-${MAX_HOTP_GPG_PIN_LENGTH} chars):" -r USER_PIN
				done
			fi
			# The user knows these passphrases, we don't need to
			# badger them to record them
			MAKE_USER_RECORD_PASSPHRASES=
		fi
	fi

	if [ -n "$luks_new_Disk_Recovery_Key_passphrase_desired" -a -z "$luks_new_Disk_Recovery_Key_passphrase" ]; then
		# We catch here if changing LUKS Disk Recovery Key passphrase was desired
		#  but yet undone. This is if not being covered by the single passphrase
		NOTE "Disk Recovery Key Passphrase: required to unlock disk, setup TPM Disk Unlock Key, access data from any computer, unsafe boot. DO NOT FORGET. Recommended: 6 words"
		while [[ ${#luks_new_Disk_Recovery_Key_passphrase} -lt 8 ]]; do
			INPUT "Enter desired replacement for current LUKS Disk Recovery Key passphrase (min 8 chars):" -r luks_new_Disk_Recovery_Key_passphrase
		done
		#We test that current LUKS Disk Recovery Key passphrase is known prior of going further
		TRACE_FUNC
		test_luks_current_disk_recovery_key_passphrase
	fi

	# Prompt to change default GnuPG key information
	INPUT "Would you like to set custom user information for the GnuPG key? [y/N]:" -n 1 prompt_output
	if [ "$prompt_output" == "y" \
		-o "$prompt_output" == "Y" ]; then
		INFO "We will generate a GnuPG (PGP) keypair identifiable as: Real Name (Comment) email@address.org"

		INPUT "Enter your Real Name (optional):" -r GPG_USER_NAME

		INPUT "Enter your email@address.org:" -r GPG_USER_MAIL
		while ! $(expr "$GPG_USER_MAIL" : '.*@' >/dev/null); do
			INPUT "Invalid email - enter your email@address.org:" -r GPG_USER_MAIL
		done

		while true; do
			INPUT "Enter Comment (1-60 chars, distinguishes this key, e.g. its purpose):" -r GPG_USER_COMMENT
			if [[ ${#GPG_USER_COMMENT} -ge 1 && ${#GPG_USER_COMMENT} -le 60 ]]; then
				break
			fi
			WARN "Comment must be 1-60 characters long. Please try again."
		done
	fi

	if [ "$GPG_GEN_KEY_IN_MEMORY" = "y" ]; then
		select_thumb_drive_for_key_material
	fi
fi

# If nothing is stored in custom variables, we set them to their defaults
if [ "$TPM_PASS" == "" ]; then TPM_PASS=${TPM_PASS_DEF}; fi
if [ "$USER_PIN" == "" ]; then USER_PIN=${USER_PIN_DEF}; fi
if [ "$ADMIN_PIN" == "" ]; then ADMIN_PIN=${ADMIN_PIN_DEF}; fi

## sanity check the USB, GPG key, and boot device before proceeding further

if [ "$GPG_GEN_KEY_IN_MEMORY" = "n" ]; then
	# Prompt to insert USB drive if desired
	INPUT "Would you like to export your public key to a USB drive? [y/N]:" -n 1 prompt_output
	if [ "$prompt_output" == "y" \
		-o "$prompt_output" == "Y" ] \
		; then
		GPG_EXPORT=1
		# mount USB over /media only if not already mounted
		if ! grep -q /media /proc/mounts; then
			# mount USB in rw
			if ! mount-usb.sh --mode rw 2>/tmp/error; then
				ERROR=$(tail -n 1 /tmp/error | fold -s)
				whiptail_error_die "Unable to mount USB on /media:\n\n${ERROR}"
			fi
		else
			#/media already mounted, make sure it is in r+w mode
			if ! mount -o remount,rw /media 2>/tmp/error; then
				ERROR=$(tail -n 1 /tmp/error | fold -s)
				whiptail_error_die "Unable to remount in read+write USB on /media:\n\n${ERROR}"
			fi
		fi
	else
		GPG_EXPORT=0
		# needed for USB Security dongle below and is ensured via mount-usb.sh in case of GPG_EXPORT=1
		enable_usb
	fi
fi

# ensure USB Security dongle connected if GPG_GEN_KEY_IN_MEMORY=n or if GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD=y
if [ "$GPG_GEN_KEY_IN_MEMORY" = "n" -o "$GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD" = "y" ]; then
	enable_usb
	if ! gpg --card-status >/dev/null 2>&1; then
		local_whiptail_error "Can't access USB Security dongle; \nPlease remove and reinsert, then press Enter."
		if ! gpg --card-status >/dev/null 2>/tmp/error; then
			ERROR=$(tail -n 1 /tmp/error | fold -s)
			whiptail_error_die "Unable to detect USB Security dongle:\n\n${ERROR}"
		fi
	fi

	#Now that USB Security dongle is detected, we can check its capabilities and limitations
	usb_security_token_capabilities_check

	# Adjust RSA key size based on dongle capabilities
	# Yubikey: Uses faster onboard crypto, can handle 4096-bit RSA in reasonable time
	# - Source: Yubikey 5 Series technical manual (~5s for 4096-bit RSA key gen)
	# - Source: Yubico forum shows RSA-2048 at ~475ms, 4096-bit ~1-2s (https://forum.yubico.com/viewtopic9d4a.html?p=4515)
	# Other dongles (Librem Key, Nitrokey Pro/Storage): Use slower STM32 chip
	# - Source: Nitrokey Pro uses STM32F4, RSA is software-based, very slow
	# - Source: User testing shows ~10 min for 3072-bit RSA on Librem Key v0.10
	# TODO: This 4096-bit change for Yubikey is untested - user requested to add with source verification
	if [ "$DONGLE_BRAND" = "Yubikey" ]; then
		DEBUG "Yubikey detected: using 4096-bit RSA key length (faster onboard crypto)"
		RSA_KEY_LENGTH=4096
	elif [ "$DONGLE_BRAND" = "Canokey" ]; then
		# Canokey has limited RSA key size support, use 2048-bit for reliability
		DEBUG "Canokey detected: using 2048-bit RSA key length (limited key size support)"
		RSA_KEY_LENGTH=2048
	fi
fi

assert_signable

# Action time...

# clear gpg-agent and scdaemon cache so that next gpg calls don't have stale state
# scdaemon holds exclusive CCID lock to dongle - must be killed to allow fresh card access
killall gpg-agent scdaemon >/dev/null 2>&1 || true
# clear local keyring
rm -rf /.gnupg/*.kbx /.gnupg/*.gpg >/dev/null 2>&1 || true

# detect and set /boot device
STATUS "Detecting and setting boot device"
if ! detect_boot_device; then
	SKIP_BOOT="y"
else
	STATUS "Boot device set to $CONFIG_BOOT_DEV"
fi

# update configs
if [[ "$SKIP_BOOT" == "n" ]]; then
	replace_config /etc/config.user "CONFIG_BOOT_DEV" "$CONFIG_BOOT_DEV"
	combine_configs
fi

if [ -n "$luks_new_Disk_Recovery_Key_desired" -a -n "$luks_new_Disk_Recovery_Key_passphrase_desired" ]; then
	#Reencryption of disk, LUKS Disk Recovery Key and LUKS Disk Recovery Key passphrase change is requested
	luks_reencrypt
	luks_change_passphrase
elif [ -n "$luks_new_Disk_Recovery_Key_desired" -a -z "$luks_new_Disk_Recovery_Key_passphrase_desired" ]; then
	#Reencryption of disk was requested but not passphrase change
	luks_reencrypt
elif [ -z "$luks_new_Disk_Recovery_Key_desired" -a -n "$luks_new_Disk_Recovery_Key_passphrase_desired" ]; then
	#Passphrase change is requested without disk reencryption
	luks_change_passphrase
fi

## reset TPM and set passphrase
if [ "$CONFIG_TPM" = "y" ]; then
	STATUS "Resetting TPM"
	tpmr.sh reset "$TPM_PASS" >/dev/null 2>/tmp/error
fi
if [ $? -ne 0 ]; then
	ERROR=$(tail -n 1 /tmp/error | fold -s)
	whiptail_error_die "Error resetting TPM:\n\n${ERROR}"
fi

# clear local keyring
rm /.gnupg/*.gpg 2>/dev/null
rm /.gnupg/*.kbx 2>/dev/null
# initialize gpg wth empty keyring
gpg --list-keys >/dev/null 2>&1

#Generate keys in memory and copy to smartcard
if [ "$GPG_GEN_KEY_IN_MEMORY" = "y" ]; then
	# Reset Nitrokey 3 Secrets app before generating keys in memory
	reset_nk3_secret_app
	if [ "$GPG_ALGO" == "RSA" ]; then
		# Generate GPG master key
		generate_inmemory_RSA_master_and_subkeys
	elif [ "$GPG_ALGO" == "p256" ]; then
		generate_inmemory_p256_master_and_subkeys
	else
		DIE "Unsupported GPG_ALGO: $GPG_ALGO"
	fi
	wipe_thumb_drive_and_copy_gpg_key_material "$thumb_drive" "$thumb_drive_luks_percent"
	set_user_config "CONFIG_HAVE_GPG_KEY_BACKUP" "y"
	if [ "$GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD" = "y" ]; then
		keytocard_subkeys_to_smartcard
	fi
else
	#enable usb storage
	enable_usb
	#Reset Nitrokey 3 secret app
	reset_nk3_secret_app
	#Generate GPG key and subkeys on smartcard only
	if [ "$GPG_ALGO" = "RSA" ]; then
		DEBUG "RSA key length: $RSA_KEY_LENGTH bits"
		if [ "$RSA_KEY_LENGTH" -ge 3072 ]; then
			# Provide firmware-aware timing guidance
			# Old Nitrokey Pro/Pro 2 firmware (< v0.15) and Librem Key (any version)
			# have slower RSA key generation (around 10 minutes for 3072-bit)
			# Yubikey uses faster onboard crypto, reasonable time even at 4096-bit
			timing_msg=""
			if [ "$DONGLE_BRAND" = "Yubikey" ]; then
				# Yubikey handles 4096-bit RSA quickly (~5 seconds)
				timing_msg="may take a minute or two"
			elif [ "$DONGLE_BRAND" = "Librem Key" ]; then
				timing_msg="may take several minutes (up to 10 minutes on older USB Security dongles)"
			elif [ "$DONGLE_BRAND" = "Nitrokey Pro" ] || [ "$DONGLE_BRAND" = "Nitrokey Storage" ]; then
				# Check if older firmware (before v0.15 had optimizations)
				if [ -n "$DONGLE_FW_VERSION" ]; then
					if [ "$(printf '%s\n' "$DONGLE_FW_VERSION" "v0.15" | sort -V | head -1)" != "v0.15" ]; then
						timing_msg="may take several minutes (up to 10 minutes on older USB Security dongles)"
					else
						timing_msg="may take several minutes"
					fi
				else
					timing_msg="may take several minutes"
				fi
			else
				timing_msg="may take several minutes"
			fi
			NOTE "RSA ${RSA_KEY_LENGTH}-bit key generation on $DONGLE_BRAND ${timing_msg} - please be patient"
		fi
	fi
	gpg_key_factory_reset
	generate_OEM_gpg_keys
fi

# Set identity fields on the OpenPGP smartcard from collected identity info
if [ "$GPG_GEN_KEY_IN_MEMORY" = "n" ] || [ "$GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD" = "y" ]; then
	set_card_identity
fi

# Obtain GPG key ID without printing trustdb maintenance chatter to console
GPG_GEN_KEY=$(gpg --list-keys --with-colons 2>/dev/null | grep "^fpr" | cut -d: -f10 | head -n1)
#Where to export the public key
PUBKEY="/tmp/${GPG_GEN_KEY}.asc"

# export pubkey to file
if ! gpg --export --armor "$GPG_GEN_KEY" >"${PUBKEY}" 2>/tmp/error; then
	ERROR=$(tail -n 1 /tmp/error | fold -s)
	whiptail_error_die "GPG Key gpg export to file failed!\n\n$ERROR"
fi

#Applying custom GPG PINs to the smartcard if they were provided
if [ "$GPG_GEN_KEY_IN_MEMORY" = "n" -o "$GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD" = "y" ]; then
	#Only apply smartcard PIN change if smartcard only or if keytocard op is expected next
	if [ "${USER_PIN}" != "${USER_PIN_DEF}" -o "${ADMIN_PIN}" != "${ADMIN_PIN_DEF}" ]; then
		if [ "$DONGLE_BRAND" = "Nitrokey 3" ]; then
			STATUS "Changing default NK3 Secrets app PIN / GPG Admin PIN"
		else
			STATUS "Changing default GPG Admin PIN"
		fi
		gpg_key_change_pin "3" "${ADMIN_PIN_DEF}" "${ADMIN_PIN}"
		if [ "$DONGLE_BRAND" = "Nitrokey 3" ]; then
			STATUS_OK "NK3 Secrets app PIN / GPG Admin PIN changed"
		else
			STATUS_OK "GPG Admin PIN changed"
		fi
		STATUS "Changing default GPG User PIN"
		gpg_key_change_pin "1" "${USER_PIN_DEF}" "${USER_PIN}"
		STATUS_OK "GPG User PIN changed"
	fi
fi

## export pubkey to USB
# Note: The thumb drive's public partition was already exported in
# wipe_thumb_drive_and_copy_gpg_key_material(). This block is for exporting
# to a DIFFERENT USB drive if user wants a separate copy (not the thumb drive).
if [ "$GPG_EXPORT" != "0" ]; then
	# The thumb drive is already unmounted at this point, so /media is not mounted
	# Only attempt export if /media is actually mounted (different drive inserted)
	if grep -q /media /proc/mounts 2>/dev/null; then
		STATUS "Exporting generated key to USB"
		if ! cp "${PUBKEY}" "/media/${GPG_GEN_KEY}.asc" 2>/tmp/error; then
			ERROR=$(tail -n 1 /tmp/error | fold -s)
			whiptail_error_die "Key export error: unable to copy ${GPG_GEN_KEY}.asc to /media:\n\n$ERROR"
		fi
		mount -o remount,ro /media 2>/dev/null
		umount /media 2>/dev/null || true
	else
		INFO "Skipping separate USB export - public key already saved to thumb drive's public partition"
	fi
fi

# ensure key imported locally
if ! cat "$PUBKEY" | DO_WITH_DEBUG gpg --import >/dev/null 2>/tmp/error; then
	ERROR=$(tail -n 1 /tmp/error | fold -s)
	whiptail_error_die "Error importing GPG key:\n\n$ERROR"
fi
# update /.gnupg/trustdb.gpg to ultimately trust all user provided public keys
if ! gpg --list-keys --fingerprint --with-colons 2>/dev/null |
	sed -E -n -e 's/^fpr:::::::::([0-9A-F]+):$/\1:6:/p' |
	gpg --import-ownertrust >/dev/null 2>/tmp/error; then
	ERROR=$(tail -n 1 /tmp/error | fold -s)
	whiptail_error_die "Error importing GPG ownertrust:\n\n$ERROR"
fi
if ! gpg --update-trust >/dev/null 2>/tmp/error; then
	ERROR=$(tail -n 1 /tmp/error | fold -s)
	whiptail_error_die "Error updating GPG ownertrust:\n\n$ERROR"
fi

# Do not attempt to flash the key to ROM if we are running in QEMU based on CONFIG_BOARD_NAME matching glob pattern containing qemu-*
# We check for qemu-* instead of ^qemu- because CONFIG_BOARD_NAME could be renamed to UNTESTED-qemu-* in a probable future
if [[ "$CONFIG_BOARD_NAME" == qemu-* ]]; then
	WARN "Skipping flash of GPG key to ROM because we are running in QEMU without internal flashing support."
	WARN "Please review boards/qemu*/qemu*.md documentation to extract public key from raw disk and inject at build time"
	WARN "Also review boards/qemu*/qemu*.config to tweak CONFIG_* options you might need to turn on/off manually at build time"
else
	#We are not running in QEMU, so flash the key to ROM

	## flash generated key to ROM
	# read current firmware; show all output and capture stderr for errors
	if echo "$CONFIG_FLASH_OPTIONS" | grep -q -- '--progress'; then
		STATUS "Reading current firmware (progress shown below)..."
	else
		STATUS "Reading current firmware... (this may take up to two minutes)"
	fi
	if ! /bin/flash.sh -r /tmp/oem-setup.rom 2> >(tee /tmp/error >&2); then
		ERROR=$(tail -n 1 /tmp/error | fold -s)
		whiptail_error_die "Error reading current firmware:\n\n$ERROR"
	fi
	if [ ! -s /tmp/oem-setup.rom ]; then
		ERROR=$(tail -n 1 /tmp/error | fold -s)
		whiptail_error_die "Error reading current firmware:\n\n$ERROR"
	fi

	# clear any existing heads/gpg files from current firmware
	for i in $(cbfs.sh -o /tmp/oem-setup.rom -l | grep -e "heads/"); do
		cbfs.sh -o /tmp/oem-setup.rom -d "$i"
	done
	# add heads/gpg files to current firmware

	if [ -e /.gnupg/pubring.kbx ]; then
		cbfs.sh -o /tmp/oem-setup.rom -a "heads/initrd/.gnupg/pubring.kbx" -f /.gnupg/pubring.kbx
		if [ -e /.gnupg/pubring.gpg ]; then
			rm /.gnupg/pubring.gpg
		fi
	elif [ -e /.gnupg/pubring.gpg ]; then
		cbfs.sh -o /tmp/oem-setup.rom -a "heads/initrd/.gnupg/pubring.gpg" -f /.gnupg/pubring.gpg
	fi
	if [ -e /.gnupg/trustdb.gpg ]; then
		cbfs.sh -o /tmp/oem-setup.rom -a "heads/initrd/.gnupg/trustdb.gpg" -f /.gnupg/trustdb.gpg
	fi

	# persist user config changes (boot device)
	if [ -e /etc/config.user ]; then
		cbfs.sh -o /tmp/oem-setup.rom -a "heads/initrd/etc/config.user" -f /etc/config.user
	fi

	# flash updated firmware image
	STATUS "Adding generated key to firmware and re-flashing"
	if ! /bin/flash.sh /tmp/oem-setup.rom 2>/tmp/error; then
		ERROR=$(tail -n 1 /tmp/error | fold -s)
		whiptail_error_die "Error flashing updated firmware image:\n\n$ERROR"
	fi
fi

## sign files in /boot and generate checksums
if [[ "$SKIP_BOOT" == "n" ]]; then
	STATUS "Updating checksums and signing all files in /boot"
	generate_checksums
fi

# passphrases set to be empty first
passphrases=""

# Prepare whiptail output of configured secrets
if [ -n "$luks_new_Disk_Recovery_Key_passphrase" -o -n "$luks_new_Disk_Recovery_Key_passphrase_desired" ]; then
	passphrases+="LUKS Disk Recovery Key passphrase: ${luks_new_Disk_Recovery_Key_passphrase}\n"
fi

if [ "$CONFIG_TPM" = "y" ]; then
	passphrases+="TPM Owner Passphrase: ${TPM_PASS}\n"
fi

#if nk3 detected, we add the NK3 Secrets App PIN
if [ "$DONGLE_BRAND" = "Nitrokey 3" ]; then
	passphrases+="Nitrokey 3 Secrets app PIN: ${ADMIN_PIN}\n"
fi

#GPG PINs output
passphrases+="GPG Admin PIN: ${ADMIN_PIN}\n"
#USER PIN was configured if GPG_GEN_KEY_IN_MEMORY is not active or if GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD is active
if [ "$GPG_GEN_KEY_IN_MEMORY" = "n" -o "$GPG_GEN_KEY_IN_MEMORY_COPY_TO_SMARTCARD" = "y" ]; then
	passphrases+="GPG User PIN: ${USER_PIN}\n"
fi

#If user decided to generate keys in memory, we add the thumb drive passphrase
if [ "$GPG_GEN_KEY_IN_MEMORY" = "y" ]; then
	passphrases+="GPG key material backup passphrase: ${ADMIN_PIN}\n"
fi

# Show configured secrets in whiptail and loop until user confirms qr code was scanned
while true; do
	whiptail_type $BG_COLOR_MAIN_MENU --msgbox "$(echo -e "$passphrases" | fold -w $((WIDTH - 5)))" \
		$HEIGHT $WIDTH --title "Configured secrets"
	if [ "$MAKE_USER_RECORD_PASSPHRASES" != y ]; then
		# Passphrases were user-supplied or not complex, we do not need to
		# badger the user to record them
		break
	fi
	#Tell user to scan the QR code containing all configured secrets
	STATUS "Scan the QR code below to save the secrets to a secure location"
	qrenc "$(echo -e "$passphrases")"
	# Prompt user to confirm scanning of qrcode on console prompt not whiptail: y/n
	INPUT "Please confirm you have scanned the QR code above and/or written down the secrets? [y/N]:" -n 1 prompt_output
	if [ "$prompt_output" == "y" -o "$prompt_output" == "Y" ]; then
		break
	fi
done

## all done -- reboot
if [ "${CONFIG_TPM_DISK_UNLOCK_KEY:-n}" = "y" ]; then
	boot_next_steps="Then open: Options -> Boot Options -> Show OS boot menu
and set a new default boot option.
This step also configures/reseals the TPM Disk Unlock Key (DUK).
"
else
	boot_next_steps="Then open: Options -> Boot Options -> Show OS boot menu
and set a new default boot option.
"
fi

completion_msg="OEM Factory Reset / Re-Ownership has completed successfully

After rebooting, you will need to generate new TOTP/HOTP secrets
when prompted in order to complete the setup process.

${boot_next_steps}
Press Enter to reboot."

whiptail --msgbox "${completion_msg}" \
	$HEIGHT $WIDTH --title "OEM Factory Reset / Re-Ownership Complete"

# Clean LUKS secrets
luks_secrets_cleanup
unset luks_passphrase_changed
unset tpm_owner_passphrase_changed

# Clean any stale files in /media from previous sessions (only when not mounted)
# This removes residual files from previous runs when /media wasn't mounted
if ! grep -q /media /proc/mounts 2>/dev/null; then
	rm -rf /media/* 2>/dev/null || true
fi

# Ensure /media is unmounted before reboot to prevent USB drive corruption
# Force unmount /media and close any LUKS mappings that might block it
umount /media 2>/dev/null || true
# Close any remaining LUKS mappings (these can block umount)
for dev in /dev/mapper/usb_mount_*; do
	[ -e "$dev" ] && cryptsetup close "$(basename "$dev")" 2>/dev/null || true
done
# Sync to ensure all writes are flushed
sync
# Final attempt to unmount after closing LUKS
umount /media 2>/dev/null || true

reboot.sh
