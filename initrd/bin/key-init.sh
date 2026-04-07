#!/bin/bash
set -e -o pipefail
. /etc/functions.sh
. /etc/gui_functions.sh

TRACE_FUNC

# Post processing of keys

# Good system clock is required for GPG to work properly.
# if system year is less then 2024, prompt user to set correct time
if [ "$(date +%Y)" -lt 2024 ]; then
	if whiptail_warning --title "System Time Incorrect" \
		--yesno "The system time is incorrect. Please set the correct time." \
		0 80 --yes-button Continue --no-button Skip --clear; then
		change-time.sh
	fi
fi

# Import user's keys if they exist
if [ -d /.gnupg/keys ]; then
	# This is legacy location for user's keys. cbfs-init takes for granted that keyring and trustdb are in /.gnupg
	#  oem-factory-reset.sh generates keyring and trustdb which cbfs-init dumps to /.gnupg
	# TODO: Remove individual key imports. This is still valid for distro keys only below.
	STATUS "Importing user GPG keys"
	gpg --import /.gnupg/keys/*.key  /.gnupg/keys/*.asc 2>/dev/null || WARN "Importing user's keys failed"
fi

# Import OS distribution signing keys used to authenticate ISO boots
STATUS "Loading OS distribution signing keys for ISO boot authentication"
gpg --homedir=/etc/distro/ --import /etc/distro/keys/* 2>/dev/null || WARN "Importing distro keys failed"
#Set distro keys trust level to ultimate (trust anything that was signed with these keys)
gpg --homedir=/etc/distro/ --list-keys --fingerprint --with-colons|sed -E -n -e 's/^fpr:::::::::([0-9A-F]+):$/\1:6:/p' |gpg --homedir=/etc/distro/ --import-ownertrust 2>/dev/null || WARN "Setting distro keys ultimate trust failed"
gpg --homedir=/etc/distro/ --update-trust 2>/dev/null || WARN "Updating distro keys trust failed"

# Add user's key so self-signed ISOs can also be booted from USB
STATUS "Adding user GPG key as trusted for ISO signing"
gpg --export | gpg --homedir=/etc/distro/ --import 2>/dev/null || WARN "Adding user's keys to distro keys failed"
