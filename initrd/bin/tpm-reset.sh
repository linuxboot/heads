#!/bin/bash
. /etc/functions.sh

echo '*****'
echo '***** WARNING: This will erase all keys and secrets from the TPM'
echo '*****'

prompt_new_owner_password

tpmr.sh reset "$tpm_owner_password"
