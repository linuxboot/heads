#!/bin/bash
# This will unseal and unecncrypt the drive encryption key from the TPM
# The TOTP secret will be shown to the user on each encryption attempt.
# It will then need to be bundled into initrd that is booted with Qubes.
set -e -o pipefail
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

TPM_INDEX=3
TPM_SIZE=312

TRACE_FUNC

# Verify TPM primary handle early to provide clear errors for disk-unseal flows
if [ "$CONFIG_TPM" = "y" ]; then
	if ! tpmr.sh verify-primary >/dev/null 2>&1; then
		rc=$?
		case "$rc" in
			2)
				die "No TPM primary handle. Unseal aborted"
				;;
			3)
				die "TPM primary handle hash mismatch. Unseal aborted"
				;;
			*)
				die "TPM primary handle verification failed (code $rc)"
				;;
		esac
	fi
fi

mkdir -p /tmp/secret

key_file="$1"

if [ -z "$key_file" ]; then
	key_file="/tmp/secret/secret.key"
fi

DEBUG "CONFIG_TPM: $CONFIG_TPM"
DEBUG "CONFIG_TPM2_TOOLS: $CONFIG_TPM2_TOOLS"
DEBUG "Show PCRs"
DEBUG "$(pcrs)"

for _ in 1 2 3; do
	# Show updating timestamp/TOTP until user presses Esc to continue to the
	# passphrase prompt. This gives the user context while they prepare to
	# type the LUKS passphrase.
	show_totp_until_esc

	read -r -s -p $'\nEnter LUKS TPM Disk Unlock Key passphrase (blank to abort): ' tpm_password
	echo
	if [ -z "$tpm_password" ]; then
		die "Aborting unseal disk encryption key"
	fi

	if DO_WITH_DEBUG --mask-position 6 \
		tpmr.sh unseal "$TPM_INDEX" "0,1,2,3,4,5,6,7" "$TPM_SIZE" \
		"$key_file" "$tpm_password"; then
		exit 0
	fi

	warn "Unable to unseal LUKS Disk Unlock Key from TPM"
done

die "Retry count exceeded..."
