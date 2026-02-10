#!/bin/bash
# Wipe the sealed TOTP/HOTP secret.  The secret is overwritten with all-0,
# rather than deleted, because deletion requires authorization.  Wiping the
# secret will cause the next boot to prompt to regenerate the secret.

# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

TPM_NVRAM_SPACE=4d47
TPM_SIZE=312

if [ "$CONFIG_TPM" = "y" ]; then
	tpmr.sh destroy "$TPM_NVRAM_SPACE" "$TPM_SIZE" \
		|| die "Unable to wipe sealed secret"
fi
