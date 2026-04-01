#!/bin/bash
. /etc/functions.sh

NOTE "This will erase all keys and secrets from the TPM"

prompt_new_owner_password

tpmr.sh reset "$tpm_owner_password"
