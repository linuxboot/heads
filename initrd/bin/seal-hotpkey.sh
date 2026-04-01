#!/bin/bash
# Retrieve the sealed TOTP secret and initialize a USB Security dongle with it

. /etc/functions.sh
. /etc/gui_functions.sh

HOTP_SECRET="/tmp/secret/hotp.key"
HOTP_COUNTER="/boot/kexec_hotp_counter"

mount_boot() {
	TRACE_FUNC
	# Mount local disk if it is not already mounted
	if ! grep -q /boot /proc/mounts; then
		if ! mount -o ro /boot; then
			whiptail_error --title 'ERROR' \
				--msgbox "Couldn't mount /boot.\n\nCheck the /boot device in configuration settings, or perform an OEM reset." 0 80
			return 1
		fi
	fi
}

TRACE_FUNC

if [ "$CONFIG_TPM" = "y" ]; then
	DEBUG "Sealing HOTP secret reuses TOTP sealed secret..."
	tpmr.sh unseal 4d47 0,1,2,3,4,7 312 "$HOTP_SECRET" ||
		DIE "Unable to unseal HOTP secret"
else
	# without a TPM, generate a secret based on the SHA-256 of the ROM
	secret_from_rom_hash >"$HOTP_SECRET" || DIE "Reading ROM failed"
fi

# Store counter in file instead of TPM for now, as it conflicts with Heads
# config TPM counter as TPM 1.2 can only increment one counter between reboots
# get current value of HOTP counter in TPM, create if absent
mount_boot || exit 1

#check_tpm_counter $HOTP_COUNTER hotp \
#|| DIE "Unable to find/create TPM counter"
#counter="$TPM_COUNTER"
#
#counter_value=$(read_tpm_counter $counter | cut -f2 -d ' ' | awk 'gsub("^000e","")')
#if [ "$counter_value" == "" ]; then
#  DIE "Unable to read HOTP counter"
#fi

#counter_value=$(printf "%d" 0x${counter_value})

counter_value=1

enable_usb

# Detect branding after USB is up so lsusb can see the device.
DONGLE_BRAND="$(detect_usb_security_dongle_branding)"
export DONGLE_BRAND
DEBUG "$DONGLE_BRAND detected via USB VID:PID"

TRACE_FUNC

# Make sure no conflicting GPG related services are running, gpg-agent will respawn
DO_WITH_DEBUG killall gpg-agent scdaemon >/dev/null 2>&1 || true

# While making sure the key is inserted, capture the status so we can check how
# many PIN attempts remain
if ! hotp_token_info="$(hotp_verification info)"; then
	INPUT "Insert your $DONGLE_BRAND and press Enter to configure it"
	if ! hotp_token_info="$(hotp_verification info)"; then
		# don't leak key on failure
		shred -n 10 -z -u "$HOTP_SECRET" 2>/dev/null
		DIE "Unable to find $DONGLE_BRAND"
	fi
fi

# Re-detect branding now that the dongle is confirmed present.
DONGLE_BRAND="$(detect_usb_security_dongle_branding)"
export DONGLE_BRAND
DEBUG "$DONGLE_BRAND detected via USB VID:PID"

# Truncate the secret if it is longer than the maximum HOTP secret
truncate_max_bytes 20 "$HOTP_SECRET"

TRACE_FUNC

# Check when the signing key was created to consider trying the default PIN
# (Note: we must avoid using gpg --card-status here as the Nitrokey firmware
# locks up, https://github.com/Nitrokey/nitrokey-pro-firmware/issues/54)
gpg_key_create_time="$(gpg --list-keys --with-colons | grep -m 1 '^pub:' | cut -d: -f6)"
gpg_key_create_time="${gpg_key_create_time:-0}"
DEBUG "Signature key was created at $(date -d "@$gpg_key_create_time")"
now_date="$(date '+%s')"

# Get the number of HOTP related PIN retry attempts remaining.
# NK3 uses "Secrets app PIN counter"; all pre-NK3 devices use "Card counters: Admin".
if [ "$DONGLE_BRAND" = "Nitrokey 3" ]; then
	admin_pin_retries=$(echo "$hotp_token_info" | grep "Secrets app PIN counter:" | cut -d ':' -f 2 | tr -d ' ')
	prompt_message="Secrets app"
else
	admin_pin_retries=$(echo "$hotp_token_info" | grep "Card counters: Admin" | grep -o 'Admin [0-9]*' | grep -o '[0-9]*')
	prompt_message="GPG Admin"
fi

admin_pin_retries="${admin_pin_retries:-0}"
DEBUG "HOTP related PIN retry counter is $admin_pin_retries"
# Show dongle firmware version with color coding so users know when to upgrade
hotpkey_fw_display "$hotp_token_info" "$DONGLE_BRAND"

# Re-query and display the current PIN retry counter before each manual prompt.
# prompt_message is already set for the device type (NK3 vs older), reuse it.
show_pin_retries() {
	local info
	info="$(hotp_verification info 2>/dev/null)" || true
	if [ "$prompt_message" = "Secrets app" ]; then
		admin_pin_retries=$(echo "$info" | grep "Secrets app PIN counter:" | cut -d ':' -f 2 | tr -d ' ')
	else
		admin_pin_retries=$(echo "$info" | grep "Card counters: Admin" | grep -o 'Admin [0-9]*' | grep -o '[0-9]*')
	fi
	admin_pin_retries="${admin_pin_retries:-0}"
	STATUS "$DONGLE_BRAND $prompt_message PIN retries remaining: $(pin_color "$admin_pin_retries")${admin_pin_retries}\033[0m"
}

# Try using factory default admin PIN for 1 month following OEM reset to ease
# initial setup.  But don't do it forever to encourage changing the PIN and
# so PIN attempts are not consumed by the default attempt.
admin_pin="12345678"
month_secs="$((30 * 24 * 60 * 60))"
admin_pin_status=1
if [ "$((now_date - gpg_key_create_time))" -gt "$month_secs" ]; then
	# Remind what the default PIN was in case it still hasn't been changed
	DEBUG "Not trying default PIN ($admin_pin)"
# Never consume an attempt if there are less than 3 attempts left, otherwise
# attempting the default PIN could cause an unexpected lockout before getting a
# chance to enter the correct PIN
elif [ "$admin_pin_retries" -lt 3 ]; then
	DEBUG "Not trying default PIN ($admin_pin): only $admin_pin_retries attempt(s) left"
else
	STATUS "Trying $prompt_message PIN to seal HOTP secret on $DONGLE_BRAND"
	# NK3 requires physical touch confirmation for the initialize operation
	if [ "$DONGLE_BRAND" = "Nitrokey 3" ]; then
		NOTE "Nitrokey 3 requires physical presence: touch the dongle when prompted"
	fi
	#TODO: silence the output of hotp_initialize once https://github.com/Nitrokey/nitrokey-hotp-verification/issues/41 is fixed
	#hotp_initialize "$admin_pin" $HOTP_SECRET $counter_value "$DONGLE_BRAND" >/dev/null 2>&1
	hotp_initialize "$admin_pin" $HOTP_SECRET $counter_value "$DONGLE_BRAND"
	admin_pin_status="$?"
fi

if [ "$admin_pin_status" -ne 0 ]; then

	# prompt user for PIN; re-query counter before each attempt so the user
	# sees the decremented count after a wrong PIN (same pattern as kexec-sign-config.sh)
	for tries in 1 2 3; do
		show_pin_retries
		if [ "$tries" -eq 1 ]; then
			INPUT "Enter your $DONGLE_BRAND $prompt_message PIN (attempt $tries/3):" -r -s admin_pin
		else
			INPUT "Wrong PIN - re-enter your $DONGLE_BRAND $prompt_message PIN (attempt $tries/3):" -r -s admin_pin
		fi
		if hotp_initialize "$admin_pin" $HOTP_SECRET $counter_value "$DONGLE_BRAND"; then
			break
		fi
		if [ "$tries" -eq 3 ]; then
			# don't leak key on failure
			shred -n 10 -z -u "$HOTP_SECRET" 2>/dev/null
			case "$DONGLE_BRAND" in
			"Nitrokey Pro" | "Nitrokey Storage" | "Nitrokey 3")
				DIE "Setting HOTP secret on $DONGLE_BRAND failed after 3 attempts. To reset $prompt_message PIN: redo Re-Ownership, or use Nitrokey App 2, or contact Nitrokey support."
				;;
			"Librem Key")
				DIE "Setting HOTP secret on $DONGLE_BRAND failed after 3 attempts. To reset $prompt_message PIN: redo Re-Ownership or contact Purism support."
				;;
			*)
				DIE "Setting HOTP secret failed after 3 attempts"
				;;
			esac
		fi
	done
else
	# Default PIN was accepted — security reminder, not a fatal error.
	# NOTE prints blank lines before/after and is always visible; no INPUT needed.
	NOTE "Default $prompt_message PIN detected.  Change it via Options --> OEM Factory Reset / Re-Ownership."
fi

# HOTP key no longer needed
shred -n 10 -z -u "$HOTP_SECRET" 2>/dev/null

# Make sure our counter is incremented ahead of the next check
#increment_tpm_counter $counter > /dev/null \
#|| DIE "Unable to increment tpm counter"
#increment_tpm_counter $counter > /dev/null \
#|| DIE "Unable to increment tpm counter"

mount -o remount,rw /boot

counter_value=$(expr $counter_value + 1)
echo $counter_value >$HOTP_COUNTER ||
	DIE "Unable to create hotp counter file"

#sha256sum /tmp/counter-$counter > $HOTP_COUNTER \
#|| DIE "Unable to create hotp counter file"
mount -o remount,ro /boot

STATUS_OK "$DONGLE_BRAND initialized successfully"

exit 0
