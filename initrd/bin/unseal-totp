#!/bin/sh
# Retrieve the sealed file from the NVRAM, unseal it and compute the totp

. /etc/functions

TOTP_SEALED="/tmp/secret/totp.sealed"
TOTP_SECRET="/tmp/secret/totp.key"

tpm nv_readvalue \
	-in 4d47 \
	-sz 312 \
	-of "$TOTP_SEALED" \
|| die "Unable to retrieve sealed file from TPM NV"

tpm unsealfile  \
	-hk 40000000 \
	-if "$TOTP_SEALED" \
	-of "$TOTP_SECRET" \
|| die "Unable to unseal totp secret"

shred -n 10 -z -u "$TOTP_SEALED" 2> /dev/null

if ! totp -q < "$TOTP_SECRET"; then
	shred -n 10 -z -u "$TOTP_SECRET" 2> /dev/null
	die 'Unable to compute TOTP hash?'
fi

shred -n 10 -z -u "$TOTP_SECRET" 2> /dev/null
exit 0
