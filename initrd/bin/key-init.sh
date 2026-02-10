#!/bin/bash
set -e -o pipefail
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh
# shellcheck source=initrd/etc/gui_functions.sh
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
	# This is legacy location for user's keys. cbfs-init.sh takes for granted that keyring and trustdb are in /.gnupg
	#  oem-factory-reset.sh generates keyring and trustdb which cbfs-init.sh dumps to /.gnupg
	# TODO: Remove individual key imports. This is still valid for distro keys only below.
	DEBUG "Importing user's keys from  /.gnupg/keys/*.key under /.gnupg user's keyring"
	gpg --import /.gnupg/keys/*.key  /.gnupg/keys/*.asc 2>/dev/null || warn "Importing user's keys failed"
else
	DEBUG "No /.gnupg/keys directory found"
fi

# Import trusted distro keys allowed for ISO signing
DEBUG "Importing distro keys from /etc/distro/keys/ under /etc/distro/ keyring"
gpg --homedir=/etc/distro/ --import /etc/distro/keys/* 2>/dev/null || warn "Importing distro keys failed"
#Set distro keys trust level to ultimate (trust anything that was signed with these keys)
gpg --homedir=/etc/distro/ --list-keys --fingerprint --with-colons|sed -E -n -e 's/^fpr:::::::::([0-9A-F]+):$/\1:6:/p' |gpg --homedir=/etc/distro/ --import-ownertrust 2>/dev/null || warn "Setting distro keys ultimate trust failed"
gpg --homedir=/etc/distro/ --update-trust 2>/dev/null || warn "Updating distro keys trust failed"

# Add user's keys to the list of trusted keys for ISO signing
DEBUG "Running gpg --export | gpg --homedir=/etc/distro/ --import"
gpg --export | gpg --homedir=/etc/distro/ --import 2>/dev/null || warn "Adding user's keys to distro keys failed"
