#!/bin/bash
# Wipe the sealed TOTP/HOTP secret. TPM1 overwrites the blob with all zeros;
# TPM2 evicts the object. TPM1 deletion needs authorization, so the blob is
# overwritten instead. Wiping the secret will cause the next boot to prompt
# to regenerate the secret.

. /etc/functions.sh

TPM_NVRAM_SPACE=4d47
TPM_SIZE=312

if [ "$CONFIG_TPM" = "y" ]; then
	tpmr.sh destroy "$TPM_NVRAM_SPACE" "$TPM_SIZE" \
		|| DIE "Unable to wipe sealed secret"
fi
