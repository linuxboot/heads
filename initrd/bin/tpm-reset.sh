#!/bin/sh
. /etc/functions.sh

echo '*****'
echo '***** WARNING: This will erase all keys and secrets from the TPM'
echo '*****'

stty -echo
printf "\nNew TPM owner password: "
read -r  key_password


if [ -z "$key_password" ]; then
	die "Empty owner password is not allowed"
fi

printf "Repeat owner password: "
read -r key_password2

stty echo
printf "\n\n"


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
