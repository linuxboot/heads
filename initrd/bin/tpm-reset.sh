#!/bin/sh
. /etc/functions

echo '*****'
echo '***** WARNING: This will erase all keys and secrets from the TPM'
echo '*****'

read -s -p "New TPM owner password: " key_password
echo

if [ -z "$key_password" ]; then
	die "Empty owner password is not allowed"
fi

read -s -p "Repeat owner password: " key_password2
echo


if [ "$key_password" != "$key_password2" ]; then
	die "Key passwords do not match"
fi

# Make sure the TPM is ready to be reset
tpm physicalpresence -s
tpm physicalenable
tpm physicalsetdeactivated -c
tpm forceclear
tpm physicalenable
tpm takeown -pwdo "$key_password"

# And now turn it all back on
tpm physicalpresence -s
tpm physicalenable
tpm physicalsetdeactivated -c
