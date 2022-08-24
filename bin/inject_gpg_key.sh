#! /usr/bin/env bash

set -e

function usage() {
	cat <<USAGE_END
usage:
	$0 [options...] <pureboot.rom> <pubkey.asc>
	$0 --help

parameters:
	-v|--verbose: Show verbose messages
	--cbfstool <path>: Specify location of cbfstool (otherwise look in PATH)
	--keep: Keep temporary GPG directory (use --verbose to see location)
	<pureboot.rom>: Path to a ROM whose GPG keyring will be replaced.
	<pubkey.asc>: GPG public key to store in the ROM.  The entire keychain is
		replaced.
	--help: Show this help
USAGE_END
}

VERBOSE=
KEEP=
PUREBOOT_ROM=
PUBKEY_ASC=
CBFSTOOL=

function log() {
	echo "$@" >&2
}

function verb() {
	if [ -n "$VERBOSE" ]; then
		log "$@"
	fi
}

function die() {
	log "$@"
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		--help)
			usage
			exit 0
			;;
		--cbfstool)
			CBFSTOOL="$2"
			shift
			shift
			;;
		-v|--verbose)
			VERBOSE=y
			shift
			;;
		--keep)
			KEEP=y
			shift
			;;
		--)
			shift
			break
			;;
		*)
			break
			;;
	esac
done

if [ -z "$CBFSTOOL" ]; then
	if ! command -v cbfstool &>/dev/null; then
		die "cbfstool is not present in PATH, install or specify with --cbfstool"
	fi
	CBFSTOOL=cbfstool
else
	if [ ! -x "$CBFSTOOL" ]; then
		die "$CBFSTOOL is not executable, check argument to --cbfstool"
	fi
fi

PUREBOOT_ROM="$1"
PUBKEY_ASC="$2"

log "Inserting $PUBKEY_ASC into $PUREBOOT_ROM..."

GPG_HOME="$(mktemp --tmpdir --directory "tmp-$(basename "$0")-XXX")"
verb "Creating GPG keyring in $GPG_HOME"
if [ -z "$KEEP" ]; then
	trap 'rm -rf -- "$GPG_HOME"' EXIT
fi

function gpg_with_args() {
	# Set the GPG home directory with --homedir.  This will use a keyring in
	# that directory and also will avoid loading any user config that could
	# interfere.
	gpg --homedir "$GPG_HOME" "$@"
}

verb "Importing $PUBKEY_ASC"
gpg_with_args --import <"$PUBKEY_ASC"
# Trust this key, it is the only one in this keyring
verb "Trusting user-specified keys"
gpg_with_args --list-keys --fingerprint --with-colons | sed -E -n -e 's/^fpr:::::::::([0-9A-F]+):$/\1:6:/p' | gpg_with_args --import-ownertrust
gpg_with_args --update-trust

verb "Cleaning existing keyring from $PUREBOOT_ROM"
for gpgfile in pubring.kbx pubring.gpg trustdb.gpg; do
	if "$CBFSTOOL" "$PUREBOOT_ROM" print | grep -q "^heads/initrd/.gnupg/$gpgfile "; then
		verb "Found heads/initrd/.gnupg/$gpgfile, removing"
		"$CBFSTOOL" "$PUREBOOT_ROM" remove -n "heads/initrd/.gnupg/$gpgfile"
	fi
done

verb "Adding new keyring to $PUREBOOT_ROM"
for gpgfile in pubring.kbx trustdb.gpg; do
	"$CBFSTOOL" "$PUREBOOT_ROM" add -f "$GPG_HOME/$gpgfile" -n "heads/initrd/.gnupg/$gpgfile" -t raw
done

# Nothing is currently done with otrust.txt or config.user, if they were
# present they are kept.
log "Success"
