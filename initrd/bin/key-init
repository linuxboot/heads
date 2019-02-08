#!/bin/ash
set -e -o pipefail
. /etc/functions

# Post processing of keys

# Import user's keys
gpg --import /.gnupg/keys/*.key  /.gnupg/keys/*.asc 2>/dev/null || true

# Import trusted distro keys allowed for ISO signing
gpg --homedir=/etc/distro/ --import /etc/distro/keys/* 2>/dev/null || true
#Set distro keys trust level to ultimate (trust anything that was signed with these keys)
gpg --homedir=/etc/distro/ --list-keys --fingerprint --with-colons|sed -E -n -e 's/^fpr:::::::::([0-9A-F]+):$/\1:6:/p' |gpg --homedir=/etc/distro/ --import-ownertrust 2>/dev/null || true
gpg --homedir=/etc/distro/ --update-trust 2>/dev/null || true

# Add user's keys to the list of trusted keys for ISO signing
gpg --export | gpg --homedir=/etc/distro/ --import 2>/dev/null || true
