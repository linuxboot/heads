#!/bin/bash
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

echo '*****'
echo '***** WARNING: This will erase all keys and secrets from the TPM'
echo '*****'

prompt_new_owner_password

tpm_owner_password="${tpm_owner_password:-}" # Ensure variable is assigned
tpmr.sh reset "$tpm_owner_password"
