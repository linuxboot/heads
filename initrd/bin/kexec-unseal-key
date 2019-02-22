#!/bin/sh
# This will unseal and unecncrypt the drive encryption key from the TPM
# The TOTP secret will be shown to the user on each encryption attempt.
# It will then need to be bundled into initrd that is booted with Qubes.
set -e -o pipefail

TPM_INDEX=3
TPM_SIZE=312

. /etc/functions
mkdir -p /tmp/secret

sealed_file="/tmp/secret/sealed.key"
key_file="$1"

if [ -z "$key_file" ]; then
	key_file="/tmp/secret/secret.key"
fi

tpm nv_readvalue \
	-in "$TPM_INDEX" \
	-sz "$TPM_SIZE" \
	-of "$sealed_file" \
|| die "Unable to read key from TPM NVRAM"

for tries in 1 2 3; do
	read -s -p "Enter unlock password (blank to abort): " tpm_password
	echo

	if [ -z "$tpm_password" ]; then
		die "Aborting unseal disk encryption key"
	fi

	if tpm unsealfile \
		-if "$sealed_file" \
		-of "$key_file" \
		-pwdd "$tpm_password" \
		-hk 40000000 \
	; then
		# should be okay if this fails
		shred -n 10 -z -u /tmp/secret/sealed 2> /dev/null || true
		exit 0
	fi

	pcrs
	warn "Unable to unseal disk encryption key"
done

die "Retry count exceeded..."
